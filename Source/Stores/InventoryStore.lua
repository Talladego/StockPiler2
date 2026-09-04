----------------------------------------------------------------
-- StockPiler2 Stores/InventoryStore — tiered bag snapshot (L0–L3)
----------------------------------------------------------------

StockPiler2.Inventory = StockPiler2.Inventory or {}
local Inv = StockPiler2.Inventory

Inv._snapGen = 0
Inv._ready = false
Inv._countByUid = {}
Inv._slotIndex = { main = {}, craft = {} }
Inv._itemBySlot = { main = {}, craft = {} }
Inv._sampleByUid = {}
Inv._dirty = false
Inv._dirtyFull = false
Inv._needQueue = false

local function Bus()
    return StockPiler2.EventBus
end

local function Events()
    return StockPiler2.Events
end

function Inv.GetSnapshotMeta()
    local n = 0
    for _ in pairs(Inv._countByUid) do
        n = n + 1
    end
    return {
        snapGen = Inv._snapGen,
        ready = Inv._ready,
        uidCount = n,
        dirty = Inv._dirty,
        dirtyFull = Inv._dirtyFull,
    }
end

function Inv.GetSnapGen()
    return tonumber(Inv._snapGen) or 0
end

function Inv.CountByUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return 0
    end
    if Inv._ready ~= true then
        return 0
    end
    return tonumber(Inv._countByUid[uid]) or 0
end

function Inv.GetCountsCopy()
    local out = {}
    for uid, n in pairs(Inv._countByUid) do
        out[uid] = n
    end
    return out
end

local function BumpGen(reason)
    if StockPiler2.Scheduler and StockPiler2.Scheduler.IsInventorySideEffectsSuppressed
        and StockPiler2.Scheduler.IsInventorySideEffectsSuppressed()
    then
        return
    end
    Inv._snapGen = (tonumber(Inv._snapGen) or 0) + 1
    local E = Events()
    local B = Bus()
    if B and E and E.INVENTORY_SNAPSHOT then
        B.Fire(E.INVENTORY_SNAPSHOT, { snapGen = Inv._snapGen, reason = reason })
    end
end

local function SetSample(uid, item)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return
    end
    if type(item) == "table" then
        Inv._sampleByUid[uid] = item
    end
end

local function ClearSampleIfUnused(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return
    end
    if (tonumber(Inv._countByUid[uid]) or 0) <= 0 then
        Inv._sampleByUid[uid] = nil
    end
end

function Inv.AdjustUid(uid, delta, reason)
    uid = tonumber(uid) or 0
    delta = tonumber(delta) or 0
    if uid <= 0 or delta == 0 or Inv._ready ~= true then
        return false
    end
    local nextCount = (tonumber(Inv._countByUid[uid]) or 0) + delta
    if nextCount < 0 then
        Inv._dirtyFull = true
        nextCount = 0
    end
    if nextCount == 0 then
        Inv._countByUid[uid] = nil
        Inv._sampleByUid[uid] = nil
    else
        Inv._countByUid[uid] = nextCount
    end
    BumpGen(reason or "adjust")
    return true
end

function Inv.MarkDirty(opts)
    opts = type(opts) == "table" and opts or {}
    Inv._dirty = true
    if opts.full == true then
        Inv._dirtyFull = true
    end
    if opts.needQueue == true then
        Inv._needQueue = true
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.IsInventorySideEffectsSuppressed
        and StockPiler2.Scheduler.IsInventorySideEffectsSuppressed()
    then
        return
    end
    local E = Events()
    local B = Bus()
    if B and E and E.INVENTORY_DIRTY then
        B.Fire(E.INVENTORY_DIRTY, {
            reason = tostring(opts.reason or "unknown"),
            needQueue = Inv._needQueue == true,
        })
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueueBagFlush then
        StockPiler2.Scheduler.EnqueueBagFlush(opts.needQueue == true)
    end
end

function Inv.OnSlotUpdated(bagType, slot)
    bagType = tostring(bagType or "main")
    slot = tonumber(slot) or 0
    if slot <= 0 then
        Inv.MarkDirty({ reason = "slot-unknown", full = true })
        return false
    end
    if Inv._ready ~= true or Inv._dirtyFull == true then
        Inv.MarkDirty({ reason = "slot-not-ready" })
        return false
    end
    local BA = StockPiler2.BagAdapter
    if not BA then
        Inv.MarkDirty({ reason = "no-adapter", full = true })
        return false
    end
    local bagSlots = Inv._slotIndex[bagType]
    if type(bagSlots) ~= "table" then
        bagSlots = {}
        Inv._slotIndex[bagType] = bagSlots
    end
    local itemSlots = Inv._itemBySlot[bagType]
    if type(itemSlots) ~= "table" then
        itemSlots = {}
        Inv._itemBySlot[bagType] = itemSlots
    end
    local old = bagSlots[slot]
    if type(old) ~= "table" then
        old = { uid = 0, qty = 0 }
    end
    local newUid, newQty, item = BA.ReadSlot(bagType, slot)
    newUid = tonumber(newUid) or 0
    newQty = tonumber(newQty) or 0
    if old.uid == newUid then
        local delta = newQty - (tonumber(old.qty) or 0)
        if delta ~= 0 then
            Inv.AdjustUid(newUid, delta, "L0-slot")
        end
    else
        if (tonumber(old.uid) or 0) > 0 then
            Inv.AdjustUid(old.uid, -(tonumber(old.qty) or 0), "L0-slot-clear")
            ClearSampleIfUnused(old.uid)
        end
        if newUid > 0 then
            Inv.AdjustUid(newUid, newQty, "L0-slot-set")
        end
    end
    if newUid > 0 and newQty > 0 then
        bagSlots[slot] = { uid = newUid, qty = newQty }
        itemSlots[slot] = item
        SetSample(newUid, item)
        if type(item) == "table" and StockPiler2.Additives and StockPiler2.Additives.LearnFromItemData then
            StockPiler2.Additives.LearnFromItemData(item, "bag")
        end
    else
        bagSlots[slot] = nil
        itemSlots[slot] = nil
    end
    Inv._dirty = false
    return true
end

--- Apply engine updatedSlots list to L0 snapshot; fall back to full dirty on failure.
function Inv.ApplySlotUpdates(bagType, updatedSlots, reason)
    bagType = tostring(bagType or "main")
    reason = tostring(reason or "slot-updates")
    if type(updatedSlots) ~= "table" then
        Inv.MarkDirty({ reason = reason .. "-noslots", full = true })
        return false
    end
    local slots = {}
    local n = 0
    for i, v in ipairs(updatedSlots) do
        local slot = tonumber(v) or 0
        if slot > 0 then
            n = n + 1
            slots[n] = slot
        end
    end
    if n == 0 then
        for k, v in pairs(updatedSlots) do
            local slot = tonumber(k)
            if slot == nil or slot <= 0 then
                slot = tonumber(v) or 0
            end
            if slot > 0 then
                n = n + 1
                slots[n] = slot
            end
        end
    end
    if n == 0 then
        Inv.MarkDirty({ reason = reason .. "-empty", full = true })
        return false
    end
    for i = 1, n do
        if Inv.OnSlotUpdated(bagType, slots[i]) ~= true then
            return false
        end
    end
    return true
end

local function RebuildFromBags(forceRefresh)
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin(forceRefresh and "SnapshotItems" or "Flatten")
    end
    local BA = StockPiler2.BagAdapter
    local bags = forceRefresh and BA.FetchForce() or BA.FetchLight()
    local counts = {}
    local slotIndex = { main = {}, craft = {} }
    local itemBySlot = { main = {}, craft = {} }
    local sampleByUid = {}
    for i = 1, #bags do
        local entry = bags[i]
        BA.IterateSlots(entry, function(bagType, slot, item)
            local uid, qty = BA.SlotQty(item)
            if uid > 0 and qty > 0 then
                counts[uid] = (counts[uid] or 0) + qty
                local bagSlots = slotIndex[bagType]
                if type(bagSlots) ~= "table" then
                    bagSlots = {}
                    slotIndex[bagType] = bagSlots
                end
                bagSlots[slot] = { uid = uid, qty = qty }
                local items = itemBySlot[bagType]
                if type(items) ~= "table" then
                    items = {}
                    itemBySlot[bagType] = items
                end
                items[slot] = item
                if sampleByUid[uid] == nil then
                    sampleByUid[uid] = item
                end
            end
        end)
    end
    Inv._countByUid = counts
    Inv._slotIndex = slotIndex
    Inv._itemBySlot = itemBySlot
    Inv._sampleByUid = sampleByUid
    Inv._ready = true
    Inv._dirty = false
    Inv._dirtyFull = false
    BumpGen(forceRefresh and "L3-full" or "L2-light")
    if Perf and Perf.End then
        Perf.End(forceRefresh and "SnapshotItems" or "Flatten")
    end
    return true
end

function Inv.Flush(opts)
    opts = type(opts) == "table" and opts or {}
    local force = opts.force == true or Inv._dirtyFull == true or Inv._ready ~= true
    local rebuilt = false
    if force then
        RebuildFromBags(opts.forceEngine == true)
        rebuilt = true
    elseif Inv._dirty == true then
        -- MarkDirty without L0 — rebuild light once.
        RebuildFromBags(false)
        rebuilt = true
    end
    -- else: L0 already applied; skip full Flatten.
    if rebuilt and StockPiler2.Additives and StockPiler2.Additives.LearnFromSnapshotSamples then
        StockPiler2.Additives.LearnFromSnapshotSamples()
    end
    local needQueue = Inv._needQueue == true
    Inv._needQueue = false
    return needQueue
end

function Inv.ConsumeNeedQueue()
    local n = Inv._needQueue == true
    Inv._needQueue = false
    return n
end

function Inv.IsDirty()
    return Inv._dirty == true or Inv._dirtyFull == true
end

function Inv.RefreshAllIfNeeded(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.force == true or Inv._ready ~= true or Inv._dirtyFull == true then
        Inv.Flush({ force = true, forceEngine = opts.force == true })
        return true
    end
    if Inv._dirty == true then
        if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueueBagFlush then
            StockPiler2.Scheduler.EnqueueBagFlush(false)
        else
            Inv.Flush({ force = false })
        end
        return true
    end
    return false
end

function Inv.GetSnapshotItemCount()
    local n = 0
    for _ in pairs(Inv._countByUid) do
        n = n + 1
    end
    return n
end

function Inv.ForceFullRefresh()
    Inv._dirtyFull = true
    Inv.MarkDirty({ full = true, reason = "force" })
end

--- Snapshot-first iteration. Live FetchLight only when snapshot not ready.
function Inv.ForEachItem(fn)
    if type(fn) ~= "function" then
        return
    end
    if Inv._ready ~= true then
        Inv.Flush({ force = true })
    end
    if Inv._ready == true and type(Inv._itemBySlot) == "table" then
        for bagType, slots in pairs(Inv._itemBySlot) do
            if type(slots) == "table" then
                for _, item in pairs(slots) do
                    if type(item) == "table" then
                        fn(item)
                    end
                end
            end
        end
        return
    end
    local BA = StockPiler2.BagAdapter
    if not BA then
        return
    end
    local bags = BA.FetchLight()
    for i = 1, #bags do
        BA.IterateSlots(bags[i], function(_, _, item)
            fn(item)
        end)
    end
end

function Inv.FindSampleByUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local sample = Inv._sampleByUid[uid]
    if type(sample) == "table" then
        return sample
    end
    if type(Inv._itemBySlot) == "table" then
        for _, slots in pairs(Inv._itemBySlot) do
            if type(slots) == "table" then
                for _, item in pairs(slots) do
                    if type(item) == "table" and (tonumber(item.uniqueID) or 0) == uid then
                        Inv._sampleByUid[uid] = item
                        return item
                    end
                end
            end
        end
    end
    if type(GetDatabaseItemData) == "function" then
        local ok, data = StockPiler2.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return data
        end
    end
    return nil
end

function Inv.CountByUniqueId(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return 0, nil
    end
    if Inv._ready ~= true then
        Inv.Flush({ force = true })
    end
    local count = Inv.CountByUid(uid)
    if count <= 0 then
        return 0, nil
    end
    return count, Inv.FindSampleByUid(uid)
end

--- Bag count for a unique ID. Use this instead of tonumber(CountByUniqueId(...)):
--- WAR Lua passes every return value into an outer call, so tonumber(CountByUniqueId(uid))
--- becomes tonumber(count, sampleTable) and errors when a sample item exists.
function Inv.UniqueIdCount(uid)
    if Inv._ready ~= true then
        Inv.Flush({ force = true })
    end
    return Inv.CountByUid(tonumber(uid) or 0)
end

function Inv.CanUseCraftingItem(item)
    if type(item) ~= "table" then
        return false
    end
    if DataUtils and type(DataUtils.PlayerTradeSkillLevelIsEnoughForItem) == "function" then
        local ok, enough = StockPiler2.TryCallQuiet(
            "DataUtils.PlayerTradeSkillLevelIsEnoughForItem",
            DataUtils.PlayerTradeSkillLevelIsEnoughForItem,
            item
        )
        if ok then
            return enough == true
        end
    end
    local req = tonumber(item.craftingSkillRequirement) or 0
    if req <= 0 then
        return true
    end
    local cultType = tonumber(item.cultivationType) or 0
    local skillId = 4
    if cultType ~= 0 then
        if GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION then
            skillId = GameData.TradeSkills.CULTIVATION
        else
            skillId = 3
        end
    elseif GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY then
        skillId = GameData.TradeSkills.APOTHECARY
    end
    if GameData and GameData.Player and type(GameData.Player.tradeSkills) == "table" then
        local row = GameData.Player.tradeSkills[skillId]
        local level = type(row) == "table" and tonumber(row.level) or tonumber(row) or 0
        return level >= req
    end
    return true
end

function Inv.CanUseUniqueId(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return false
    end
    if Inv.CountByUid(uid) <= 0 then
        return false
    end
    local sample = Inv.FindSampleByUid(uid)
    if type(sample) == "table" then
        return Inv.CanUseCraftingItem(sample)
    end
    -- No sample: do not assume usable (skill-gated seeds were planted then failed).
    return false
end

----------------------------------------------------------------
-- Item tooltips (Potions / Watch icon hover)
----------------------------------------------------------------

local function CopyItemData(item)
    if type(item) ~= "table" then
        return nil
    end
    local function copyVal(v, depth)
        if type(v) ~= "table" then
            return v
        end
        if depth >= 4 then
            return nil
        end
        local out = {}
        for k, val in pairs(v) do
            local cv = copyVal(val, depth + 1)
            if cv ~= nil or type(val) ~= "table" then
                out[k] = cv
            end
        end
        return out
    end
    return copyVal(item, 0)
end

local function ItemDataHasUseBonus(itemData)
    if type(itemData) ~= "table" or type(itemData.bonus) ~= "table" then
        return false
    end
    local useType = 3
    if GameDefs and GameDefs.ITEMBONUS_USE then
        useType = GameDefs.ITEMBONUS_USE
    end
    for _, bonus in ipairs(itemData.bonus) do
        if type(bonus) == "table" and bonus.type == useType and bonus.reference and bonus.reference ~= 0 then
            return true
        end
    end
    return false
end

local function PreferRicherItemData(a, b)
    if a == nil then
        return b
    end
    if b == nil then
        return a
    end
    local aUse = ItemDataHasUseBonus(a)
    local bUse = ItemDataHasUseBonus(b)
    if aUse and not bUse then
        return a
    end
    if bUse and not aUse then
        return b
    end
    return a
end

--- CreateItemTooltip assumes bag-shaped fields; pad thin shells so pcall succeeds.
function Inv.NormalizeItemDataForTooltip(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    local data = CopyItemData(itemData)
    if type(data) ~= "table" then
        data = itemData
    end
    if data.timeLeftBeforeDecay == nil then
        data.timeLeftBeforeDecay = 0
    end
    if data.equipSlot == nil then
        data.equipSlot = 0
    end
    local stacks = tonumber(data.stackCount) or 0
    if stacks < 1 then
        data.stackCount = 1
    end
    if type(data.bonus) ~= "table" then
        data.bonus = {}
    end
    if type(data.flags) ~= "table" then
        data.flags = {}
    end
    if data.broken == nil then
        data.broken = false
    end
    if data.sellPrice == nil then
        data.sellPrice = 0
    end
    if data.repairPrice == nil then
        data.repairPrice = 0
    end
    if data.name == nil then
        data.name = L""
    end
    return data
end

function Inv.ItemDataHasUseBonus(itemData)
    return ItemDataHasUseBonus(itemData)
end

--- Prefer bag/sample with real Use-bonus over thin DB shells.
function Inv.ResolveTooltipItemData(entry, existing)
    local uid = 0
    if type(entry) == "table" then
        uid = tonumber(entry.uniqueID) or tonumber(entry.outputUid) or 0
        if uid <= 0 and type(entry.uniqueIDs) == "table" then
            uid = tonumber(entry.uniqueIDs[1]) or 0
        end
    end
    local best = nil
    if type(existing) == "table" then
        best = PreferRicherItemData(best, existing)
    end
    if uid > 0 then
        local count, sample = Inv.CountByUniqueId(uid)
        if count > 0 and type(sample) == "table" then
            best = PreferRicherItemData(best, sample)
        elseif type(sample) ~= "table" then
            local bagSample = Inv._sampleByUid[uid]
            if type(bagSample) == "table" then
                best = PreferRicherItemData(best, bagSample)
            end
        end
    end
    return best or existing
end

function Inv.ResolvePotionItemData(potionKey, uid, existing)
    uid = tonumber(uid) or 0
    if uid <= 0 and type(potionKey) == "string" then
        local fromKey = string.match(potionKey, "^uid:(%d+)")
        uid = tonumber(fromKey) or 0
    end
    if uid <= 0 then
        return existing
    end
    if type(existing) ~= "table" then
        local count, sample = Inv.CountByUniqueId(uid)
        if count > 0 then
            existing = sample
        end
    end
    if type(existing) ~= "table" then
        local sample = Inv._sampleByUid[uid]
        if type(sample) == "table" then
            existing = sample
        end
    end
    if type(existing) ~= "table" and StockPiler2.Items and StockPiler2.Items.AsItemData then
        existing = StockPiler2.Items.AsItemData(uid)
    end
    local entry = {
        id = potionKey or ("uid:" .. tostring(uid)),
        uniqueID = uid,
        uniqueIDs = { uid },
    }
    return Inv.ResolveTooltipItemData(entry, existing) or existing
end

--- Full stock item tooltip when itemData has Use-bonus (usually bags). Returns true if shown.
function Inv.ShowItemTooltip(itemData, anchorWindow, extraText)
    if type(itemData) ~= "table" or type(Tooltips) ~= "table"
        or type(Tooltips.CreateItemTooltip) ~= "function"
    then
        return false
    end
    if not ItemDataHasUseBonus(itemData) then
        return false
    end
    local data = Inv.NormalizeItemDataForTooltip(itemData)
    if type(data) ~= "table" then
        return false
    end
    if extraText ~= nil and extraText ~= L"" and type(extraText) == "string" then
        extraText = towstring(extraText)
    end
    if extraText == L"" then
        extraText = nil
    end
    local ok = StockPiler2.TryCall(
        "Tooltips.CreateItemTooltip",
        Tooltips.CreateItemTooltip,
        data,
        anchorWindow or SystemData.ActiveWindow.name,
        Tooltips.ANCHOR_WINDOW_RIGHT,
        true,
        extraText,
        nil,
        true
    )
    return ok == true
end
