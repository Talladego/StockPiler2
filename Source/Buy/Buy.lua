----------------------------------------------------------------
-- StockPiler2 Buy — AutoBuy from open NPC stores (non-growable mats)
----------------------------------------------------------------

StockPiler2.Buy = StockPiler2.Buy or {}
local Buy = StockPiler2.Buy

local BRASS_PER_GOLD = 10000
local MAX_PURCHASES_PER_VISIT = 80

Buy._jobsCache = nil
Buy._jobsSnapGen = nil
Buy._visitStoreOpen = false

local function ToNarrow(text)
    if StockPiler2.ToNarrow then
        return StockPiler2.ToNarrow(text)
    end
    return tostring(text or "")
end

local function LogBuyOp(msg)
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("buy", msg)
    elseif StockPiler2.D then
        StockPiler2.D("AutoBuy " .. tostring(msg))
    end
end

local function EmitBuyTrace(msg, force)
    if force ~= true and not (StockPiler2.Debug and StockPiler2.Debug.Enabled == true) then
        return
    end
    local text = "buy| " .. tostring(msg)
    if StockPiler2.Debug and StockPiler2.Debug.LogAlways then
        StockPiler2.Debug.LogAlways(text)
    elseif type(d) == "function" then
        d("StockPiler2| " .. text)
    end
end

local function LogBuyJobLines(jobs, force)
    jobs = type(jobs) == "table" and jobs or {}
    for i = 1, math.min(#jobs, 20) do
        local job = jobs[i]
        if type(job) == "table" then
            EmitBuyTrace(string.format(
                "  job #%d kind=%s specKey=%s have=%d need=%d deficit=%d name=%s",
                i,
                tostring(job.kind or "buy"),
                tostring(job.specKey or "?"),
                tonumber(job.have) or 0,
                tonumber(job.need) or 0,
                tonumber(job.deficit) or 0,
                ToNarrow(job.label or job.name or "?")
            ), force)
        end
    end
    if #jobs > 20 then
        EmitBuyTrace("  ... +" .. tostring(#jobs - 20) .. " more jobs", force)
    end
end

function Buy.IsEnabled()
    local Caps = StockPiler2.TradeSkillCaps
    if Caps and Caps.CanAutoBuy and Caps.CanAutoBuy() ~= true then
        return false
    end
    if StockPiler2.Watch and StockPiler2.Watch.IsAutoBuyEnabled then
        return StockPiler2.Watch.IsAutoBuyEnabled() == true
    end
    local row = StockPiler2.Watch and StockPiler2.Watch.CharacterRow and StockPiler2.Watch.CharacterRow()
    return type(row) == "table" and row.autoBuyEnabled == true
end

function Buy.GetReserveGold()
    if StockPiler2.Watch and StockPiler2.Watch.GetAutoBuyReserveGold then
        return StockPiler2.Watch.GetAutoBuyReserveGold()
    end
    local row = StockPiler2.Watch and StockPiler2.Watch.CharacterRow and StockPiler2.Watch.CharacterRow()
    local n = type(row) == "table" and tonumber(row.autoBuyReserveGold) or 10
    if n == nil or n < 1 then
        return 10
    end
    if n > 99 then
        return 99
    end
    return math.floor(n)
end

function Buy.GetBudgetGold()
    if StockPiler2.Watch and StockPiler2.Watch.GetAutoBuyBudgetGold then
        return StockPiler2.Watch.GetAutoBuyBudgetGold()
    end
    local row = StockPiler2.Watch and StockPiler2.Watch.CharacterRow and StockPiler2.Watch.CharacterRow()
    local n = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or 50
    if n == nil or n < 1 then
        return 50
    end
    if n > 999 then
        return 999
    end
    return math.floor(n)
end

function Buy.InvalidateJobsCache()
    Buy._jobsCache = nil
    Buy._jobsSnapGen = nil
end

----------------------------------------------------------------
-- Vendor learn (Cultivating + Apothecary crafting mats)
----------------------------------------------------------------

local function TradeSkillIds()
    local Caps = StockPiler2.TradeSkillCaps
    if Caps and Caps.CultivationId and Caps.ApothecaryId then
        return Caps.CultivationId(), Caps.ApothecaryId()
    end
    local cult = 3
    local apo = 4
    if GameData and GameData.TradeSkills then
        cult = tonumber(GameData.TradeSkills.CULTIVATION) or cult
        apo = tonumber(GameData.TradeSkills.APOTHECARY) or apo
    end
    return cult, apo
end

--- Vendor rows often have tradeSkill=0; cultivationType still marks Cultivating mats.
local function InferStoreTradeSkill(item)
    local ts = tonumber(item and item.tradeSkill) or 0
    if ts > 0 then
        return ts
    end
    if (tonumber(item and item.cultivationType) or 0) ~= 0 then
        local cult = TradeSkillIds()
        return cult
    end
    return 0
end

local function IsCraftTradeSkill(item)
    local ts = InferStoreTradeSkill(item)
    local Caps = StockPiler2.TradeSkillCaps
    if Caps and Caps.IsPotionCraftTradeSkill then
        return Caps.IsPotionCraftTradeSkill(ts) == true
    end
    if ts <= 0 then
        return false
    end
    local cult, apo = TradeSkillIds()
    return ts == cult or ts == apo
end

local function PlayerCanBuyItemTradeSkill(item)
    local ts = InferStoreTradeSkill(item)
    local Caps = StockPiler2.TradeSkillCaps
    if Caps and Caps.CanBuyTradeSkill then
        return Caps.CanBuyTradeSkill(ts) == true
    end
    return IsCraftTradeSkill(item)
end

local function VendorItemsTable()
    if StockPiler2.Knowledge and StockPiler2.Knowledge.GetTable then
        return StockPiler2.Knowledge.GetTable("vendorItems")
    end
    local acct = StockPiler2.Account
    if type(acct) ~= "table" then
        return nil
    end
    if type(acct.vendorItems) ~= "table" then
        acct.vendorItems = {}
    end
    return acct.vendorItems
end

--- Upsert Cult+Apo store rows into Account.items + vendorItems.
function Buy.LearnFromOpenStore()
    local VA = StockPiler2.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return 0
    end
    if VA.IsBuybackView and VA.IsBuybackView() then
        return 0
    end
    local list = VA.StoreRows and VA.StoreRows() or nil
    if type(list) ~= "table" then
        return 0
    end
    local store = VendorItemsTable()
    local n = 0
    local now = (type(GetGameTime) == "function" and tonumber(GetGameTime())) or 0
    local function consider(item)
        if type(item) ~= "table" or not IsCraftTradeSkill(item) then
            return
        end
        local uid = tonumber(item.uniqueID) or tonumber(item.id) or 0
        if uid <= 0 then
            return
        end
        if StockPiler2.Items and StockPiler2.Items.UpsertFromItemData then
            StockPiler2.Items.UpsertFromItemData(item, "vendor")
        end
        if type(store) == "table" then
            local key = tostring(uid)
            local isNew = store[key] == nil
            store[key] = {
                uniqueID = uid,
                tradeSkill = tonumber(item.tradeSkill) or 0,
                cultivationType = tonumber(item.cultivationType) or 0,
                iconNum = tonumber(item.iconNum) or 0,
                nameNarrow = ToNarrow(item.name),
                lastSeen = now,
                source = "store",
            }
            if isNew then
                n = n + 1
            end
        end
    end
    for _, item in ipairs(list) do
        consider(item)
    end
    for _, item in pairs(list) do
        consider(item)
    end
    if n > 0 and StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
        StockPiler2.Knowledge.Touch()
    end
    if n > 0 then
        LogBuyOp("learned vendor items +" .. tostring(n))
    end
    return n
end

----------------------------------------------------------------
-- Jobs
----------------------------------------------------------------

function Buy.CollectBuyJobs()
    local snapGen = StockPiler2.Inventory and tonumber(StockPiler2.Inventory.GetSnapGen and StockPiler2.Inventory.GetSnapGen())
        or tonumber(StockPiler2.Inventory and StockPiler2.Inventory._snapGen) or 0
    local Caps = StockPiler2.TradeSkillCaps
    local skillHash = Caps and Caps.LevelsHash and Caps.LevelsHash() or ""
    local cacheKey = tostring(snapGen) .. ":" .. skillHash
    if type(Buy._jobsCache) == "table" and Buy._jobsSnapGen == cacheKey then
        return Buy._jobsCache
    end
    local jobs = {}
    if StockPiler2.Planner and StockPiler2.Planner.CollectVendorBuyJobs then
        jobs = StockPiler2.Planner.CollectVendorBuyJobs() or {}
    end
    Buy._jobsCache = jobs
    Buy._jobsSnapGen = cacheKey
    return jobs
end

function Buy.DumpBuyPlan(opts)
    opts = type(opts) == "table" and opts or {}
    local force = opts.force == true
    if force and StockPiler2.Inventory and StockPiler2.Inventory.RefreshAllIfNeeded then
        StockPiler2.Inventory.RefreshAllIfNeeded({ force = true })
    end
    Buy.InvalidateJobsCache()
    local jobs = Buy.CollectBuyJobs()
    local Inv = StockPiler2.Inventory
    local snapDone = Inv and Inv._ready == true
    local snapGen = Inv and tonumber(Inv.GetSnapGen and Inv.GetSnapGen()) or 0
    EmitBuyTrace("=== buy plan ===", force)
    EmitBuyTrace(string.format(
        "enabled=%s reserveGold=%d budgetGold=%d storeOpen=%s snapshotReady=%s snapGen=%d",
        tostring(Buy.IsEnabled()),
        Buy.GetReserveGold(),
        Buy.GetBudgetGold(),
        tostring(StockPiler2.VendorAdapter and StockPiler2.VendorAdapter.IsStoreOpen
            and StockPiler2.VendorAdapter.IsStoreOpen()),
        tostring(snapDone),
        snapGen
    ), force)
    EmitBuyTrace("--- jobs (" .. tostring(#jobs) .. ") ---", force)
    if not snapDone then
        EmitBuyTrace("  (snapshot not ready — job list may be empty)", force)
    elseif #jobs == 0 then
        EmitBuyTrace("  (no vendor buy jobs)", force)
    else
        LogBuyJobLines(jobs, force)
    end
    if Buy.DumpOpenStoreRawRows then
        Buy.DumpOpenStoreRawRows(force)
    elseif Buy.DumpOpenStoreCultApoRows then
        Buy.DumpOpenStoreCultApoRows(force)
    end
    EmitBuyTrace("=== end buy plan ===", force)
end

----------------------------------------------------------------
-- Store match
----------------------------------------------------------------

local function HasAltCurrency(item)
    local alt = item and item.altCurrency
    if type(alt) ~= "table" then
        return false
    end
    if #alt > 0 then
        return true
    end
    for _ in pairs(alt) do
        return true
    end
    return false
end

local function PlayerCanUseStoreItem(item)
    if type(DataUtils) ~= "table" or type(DataUtils.PlayerCanUseItem) ~= "function" then
        return true
    end
    local ok, canUse = StockPiler2.TryCallQuiet("DataUtils.PlayerCanUseItem", DataUtils.PlayerCanUseItem, item)
    if not ok then
        return false
    end
    return canUse == true
end

--- Cheap: vendor scan must not call SeedMap / MaterialSpec (that froze buyplan).
local function IsGrowablePlantItem(item)
    if type(item) ~= "table" then
        return false
    end
    local cult = tonumber(item.cultivationType) or 0
    local seed = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local spore = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
    return cult == seed or cult == spore
end

local function TradeSkillDumpLabel(tradeSkillId)
    tradeSkillId = tonumber(tradeSkillId) or 0
    local cult, apo = TradeSkillIds()
    if tradeSkillId == cult then
        return "cult"
    end
    if tradeSkillId == apo then
        return "apo"
    end
    return tostring(tradeSkillId)
end

local function FirstItemKeyList(item)
    if type(item) ~= "table" then
        return ""
    end
    local names = {}
    for k, _ in pairs(item) do
        if type(k) == "string" then
            names[#names + 1] = k
        end
    end
    table.sort(names)
    local maxKeys = 24
    local out = ""
    for i = 1, math.min(#names, maxKeys) do
        if i > 1 then
            out = out .. ","
        end
        out = out .. names[i]
    end
    if #names > maxKeys then
        out = out .. ",+" .. tostring(#names - maxKeys)
    end
    return out
end

--- Debug: sample the open NPC store (unfiltered). Keep this cheap — chat-print of 170 rows disconnects.
function Buy.DumpOpenStoreRawRows(force)
    force = force == true
    local VA = StockPiler2.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        EmitBuyTrace("--- store raw (0) ---", force)
        EmitBuyTrace("  (store closed)", force)
        return
    end
    if VA.IsBuybackView and VA.IsBuybackView() then
        EmitBuyTrace("--- store raw (0) ---", force)
        EmitBuyTrace("  (buyback view — no sell list)", force)
        return
    end
    local list = VA.StoreRows and VA.StoreRows() or nil
    if type(list) ~= "table" then
        EmitBuyTrace("--- store raw (0) ---", force)
        EmitBuyTrace("  (no store rows type=" .. type(list) .. ")", force)
        return
    end
    local rows = {}
    local skipped = 0
    for k, item in pairs(list) do
        if type(item) ~= "table" then
            skipped = skipped + 1
        else
            rows[#rows + 1] = { key = k, item = item }
        end
    end
    table.sort(rows, function(a, b)
        local sa = tonumber(a.item.slotNum) or 0
        local sb = tonumber(b.item.slotNum) or 0
        if sa ~= sb then
            return sa < sb
        end
        return (tonumber(a.item.uniqueID) or 0) < (tonumber(b.item.uniqueID) or 0)
    end)
    EmitBuyTrace(string.format(
        "--- store raw (%d) skippedNonTable=%d ---",
        #rows,
        skipped
    ), force)
    if #rows == 0 then
        EmitBuyTrace("  (store table empty of item rows)", force)
        return
    end
    EmitBuyTrace("  keys=" .. FirstItemKeyList(rows[1].item), force)
    local maxLines = 20
    for i = 1, math.min(#rows, maxLines) do
        local wrap = rows[i]
        local item = wrap.item
        local ts = tonumber(item.tradeSkill) or 0
        local inferred = InferStoreTradeSkill(item)
        local craftingSkill = tonumber(item.craftingSkillRequirement) or 0
        local cultType = tonumber(item.cultivationType) or 0
        local itemType = tonumber(item.type) or tonumber(item.itemType) or 0
        local canbuy = item.canbuy ~= false and 1 or 0
        EmitBuyTrace(string.format(
            "  #%d slot=%s uid=%s ts=%s inf=%s(%s) req=%s ct=%s type=%s cost=%s canbuy=%d name=%s",
            i,
            tostring(tonumber(item.slotNum) or 0),
            tostring(tonumber(item.uniqueID) or tonumber(item.id) or 0),
            tostring(ts),
            tostring(inferred),
            TradeSkillDumpLabel(inferred),
            tostring(craftingSkill),
            tostring(cultType),
            tostring(itemType),
            tostring(tonumber(item.cost) or 0),
            canbuy,
            ToNarrow(item.name)
        ), force)
    end
    if #rows > maxLines then
        EmitBuyTrace("  ... +" .. tostring(#rows - maxLines) .. " more", force)
    end
end

--- Debug: list Cultivating + Apothecary craft mats on the open NPC store.
function Buy.DumpOpenStoreCultApoRows(force)
    Buy.DumpOpenStoreRawRows(force)
end

local function IsHarvestByproductItem(item)
    local MS = StockPiler2.MaterialSpec
    if not (MS and MS.FromItemDataCached) then
        return false
    end
    if not (StockPiler2.SeedMap and StockPiler2.SeedMap.IsHarvestByproduct) then
        return false
    end
    local spec = MS.FromItemDataCached(item, nil)
    return type(spec) == "table" and StockPiler2.SeedMap.IsHarvestByproduct(spec) == true
end

local function ItemMatchesJob(item, job)
    if type(item) ~= "table" or type(job) ~= "table" then
        return false
    end
    local Caps = StockPiler2.TradeSkillCaps
    local ts = InferStoreTradeSkill(item)
    if ts > 0 then
        if Caps and Caps.IsPotionCraftTradeSkill and Caps.IsPotionCraftTradeSkill(ts) ~= true then
            return false
        end
        if not (Caps and Caps.IsPotionCraftTradeSkill) and not IsCraftTradeSkill(item) then
            return false
        end
    elseif not (Caps and Caps.CanAutoBuy and Caps.CanAutoBuy() == true) then
        -- Vendor omitted tradeSkill (common); still require Cult or Apo to AutoBuy.
        return false
    end
    local canAutoGrow = Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true
    local growable = IsGrowablePlantItem(item)
    if growable then
        if canAutoGrow then
            return false
        end
        if not (Caps and Caps.CanAutoBuy and Caps.CanAutoBuy() == true) then
            return false
        end
    elseif ts > 0 and not PlayerCanBuyItemTradeSkill(item) then
        return false
    end
    if type(job.spec) ~= "table" or not (StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.Matches) then
        return false
    end
    return StockPiler2.MaterialSpec.Matches(item, job.spec) == true
end

function Buy.FindStoreMatch(job)
    local VA = StockPiler2.VendorAdapter
    local list = VA and VA.StoreRows and VA.StoreRows() or nil
    if type(list) ~= "table" or type(job) ~= "table" then
        return nil
    end
    local function consider(item)
        if type(item) == "table"
            and tonumber(item.slotNum)
            and item.canbuy ~= false
            and not HasAltCurrency(item)
            and (tonumber(item.cost) or 0) > 0
            and PlayerCanUseStoreItem(item)
            and ItemMatchesJob(item, job)
        then
            return item, tonumber(item.cost) or 0
        end
        return nil
    end
    for _, item in ipairs(list) do
        local matched, cost = consider(item)
        if matched then
            return matched, cost
        end
    end
    for _, item in pairs(list) do
        local matched, cost = consider(item)
        if matched then
            return matched, cost
        end
    end
    return nil
end

----------------------------------------------------------------
-- Visit state + TryBuyNext
----------------------------------------------------------------

local function BuyBlockedReason()
    if StockPiler2.Scheduler and StockPiler2.Scheduler.BagWorkPending
        and StockPiler2.Scheduler.BagWorkPending()
    then
        return "bag-work"
    end
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsBrewSessionActive
        and StockPiler2.Orchestrator.IsBrewSessionActive()
    then
        return "brew-busy"
    end
    if StockPiler2.ApothecaryAdapter and StockPiler2.ApothecaryAdapter.IsBusy
        and StockPiler2.ApothecaryAdapter.IsBusy()
    then
        return "brew-busy"
    end
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsHarvestActive
        and StockPiler2.Orchestrator.IsHarvestActive()
    then
        return "harvest-busy"
    end
    local Grow = StockPiler2.Grow
    if Grow and type(Grow._pendingPlant) == "table" then
        for _, n in pairs(Grow._pendingPlant) do
            if (tonumber(n) or 0) > 0 then
                return "plant-busy"
            end
        end
    end
    return nil
end

local function PlayerMoneyBrass()
    local VA = StockPiler2.VendorAdapter
    if VA and VA.GetPlayerMoneyBrass then
        return VA.GetPlayerMoneyBrass()
    end
    return 0
end

local function ChatVisitStop(reason)
    if Buy._visitChatted == true then
        return
    end
    Buy._visitChatted = true
    if reason ~= "nothing" then
        Buy._visitStopReason = reason
    end
    LogBuyOp(string.format(
        "stop reason=%s bought=%d spentBrass=%d",
        tostring(reason),
        tonumber(Buy._visitBought) or 0,
        tonumber(Buy._visitSpentBrass) or 0
    ))
end

local function ResetVisit()
    Buy._visitSpentBrass = 0
    Buy._visitBought = 0
    Buy._visitPurchases = 0
    Buy._visitStopReason = nil
    Buy._visitChatted = false
    Buy._visitSawMatch = false
    Buy._visitHadJobs = false
    Buy._visitAcquiredByKey = {}
    Buy._visitNoMatchKeys = {}
    Buy._visitSkipLogged = {}
    Buy._visitSnapshotSkipLogged = false
    Buy._visitBuybackSkipLogged = false
    Buy._visitMoneyBrass = PlayerMoneyBrass()
    Buy.InvalidateJobsCache()
end

local function LogVisitSkipOnce(key, msg)
    local logged = Buy._visitSkipLogged
    if type(logged) ~= "table" then
        logged = {}
        Buy._visitSkipLogged = logged
    end
    if logged[key] == true then
        return
    end
    logged[key] = true
    LogBuyOp("skip " .. msg)
end

local function JobAcquireKey(job, item)
    if type(job) ~= "table" then
        return nil
    end
    local key = job.specKey
    if type(key) == "string" and key ~= "" then
        return key
    end
    local uid = tonumber(item and (item.uniqueID or item.id)) or 0
    if uid > 0 then
        return "uid:" .. tostring(uid)
    end
    local name = ToNarrow(job.name or job.label or "")
    if name ~= "" then
        return "name:" .. name
    end
    return nil
end

local function VisitAcquired(key)
    if key == nil then
        return 0
    end
    local map = Buy._visitAcquiredByKey
    if type(map) ~= "table" then
        return 0
    end
    return tonumber(map[key]) or 0
end

local function NoteVisitAcquired(key, qty)
    qty = tonumber(qty) or 0
    if key == nil or qty <= 0 then
        return
    end
    local map = Buy._visitAcquiredByKey
    if type(map) ~= "table" then
        map = {}
        Buy._visitAcquiredByKey = map
    end
    map[key] = VisitAcquired(key) + qty
end

local function VisitMoneyBrass()
    local live = PlayerMoneyBrass()
    local tracked = tonumber(Buy._visitMoneyBrass)
    if tracked == nil then
        Buy._visitMoneyBrass = live
        return live
    end
    if live > 0 and live < tracked then
        Buy._visitMoneyBrass = live
        return live
    end
    return tracked
end

local function LogVisitStart(tag)
    local jobs = Buy.IsEnabled() and Buy.CollectBuyJobs() or {}
    LogBuyOp(string.format(
        "%s enabled=%s jobs=%d money=%d reserveGold=%d budgetGold=%d",
        tostring(tag or "visit-start"),
        tostring(Buy.IsEnabled()),
        type(jobs) == "table" and #jobs or 0,
        tonumber(Buy._visitMoneyBrass) or 0,
        Buy.GetReserveGold(),
        Buy.GetBudgetGold()
    ))
    if Buy.IsEnabled() and type(jobs) == "table" and #jobs > 0 then
        LogBuyJobLines(jobs, false)
    end
end

--- Clear reserved/budget visit stop so AutoBuy can continue (chips / resume).
--- Bag deficit is authoritative; wipe visit-acquired so we do not double-count.
function Buy.ClearMoneyGateStop(via)
    local stop = Buy._visitStopReason
    if stop ~= "reserved" and stop ~= "budget" then
        return false
    end
    Buy._visitStopReason = nil
    Buy._visitChatted = false
    Buy._visitSpentBrass = 0
    Buy._visitAcquiredByKey = {}
    Buy._visitSkipLogged = {}
    Buy._visitMoneyBrass = PlayerMoneyBrass()
    Buy.InvalidateJobsCache()
    LogBuyOp(string.format(
        "resume clear-stop was=%s via=%s money=%d reserveGold=%d",
        tostring(stop),
        tostring(via or "?"),
        tonumber(Buy._visitMoneyBrass) or 0,
        Buy.GetReserveGold()
    ))
    if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoBuy then
        StockPiler2.Scheduler.WakeAutoBuy()
    end
    return true
end

--- Observe store hide even when AutoBuy is not ticking (NeedsTick is open-only).
function Buy.PollStorePresence()
    if Buy._visitStoreOpen ~= true then
        return
    end
    local VA = StockPiler2.VendorAdapter
    if VA and VA.IsStoreOpen and VA.IsStoreOpen() == true then
        return
    end
    Buy.OnStoreUpdated()
end

function Buy.OnStoreUpdated()
    local VA = StockPiler2.VendorAdapter
    local showing = VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
    if showing then
        local wasOpen = Buy._visitStoreOpen == true
        local stop = Buy._visitStopReason
        local moneyStop = (stop == "reserved" or stop == "budget")
        if not wasOpen then
            Buy._visitStoreOpen = true
            ResetVisit()
            LogVisitStart("visit-start")
        elseif moneyStop then
            -- Stuck after reserved/budget: reopen/ShowStore never saw a close edge.
            ResetVisit()
            Buy._visitStoreOpen = true
            LogVisitStart("visit-resume")
        end
    elseif not showing and Buy._visitStoreOpen == true then
        Buy._visitStoreOpen = false
        if (tonumber(Buy._visitBought) or 0) > 0 then
            ChatVisitStop("bought")
        elseif Buy._visitHadJobs == true and Buy._visitSawMatch ~= true then
            ChatVisitStop("nothing")
        else
            LogBuyOp(string.format(
                "visit-end bought=%d spentBrass=%d",
                tonumber(Buy._visitBought) or 0,
                tonumber(Buy._visitSpentBrass) or 0
            ))
        end
        Buy.InvalidateJobsCache()
    end
end

--- After a successful BuyItem: do not Flatten / invalidate plan / rebuild jobs.
--- VisitAcquired already gates remaining qty this visit; bag slot events L0-update
--- counts; store-close InvalidateJobsCache + snap coalesce rebuild plan/jobs.
--- Per-purchase full MarkDirty + PlanSnapshot.Invalidate was Planner.Build +
--- Buy.TryBuyNext dominating perf summaries.
local function AfterPurchaseRefresh()
end

function Buy.TryBuyNext()
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Buy.TryBuyNext")
    end
    local function done(result)
        if Perf and Perf.End then
            Perf.End("Buy.TryBuyNext")
        end
        return result
    end
    if Buy._visitStopReason ~= nil then
        return done(false)
    end
    if not Buy.IsEnabled() then
        return done(false)
    end
    local VA = StockPiler2.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return done(false)
    end
    if VA.IsBuybackView and VA.IsBuybackView() then
        if Buy._visitBuybackSkipLogged ~= true then
            Buy._visitBuybackSkipLogged = true
            LogBuyOp("skip buyback-view")
        end
        return done(false)
    end
    local busy = BuyBlockedReason()
    if busy ~= nil then
        if Buy._lastBusyLog ~= busy then
            Buy._lastBusyLog = busy
            LogBuyOp("wait " .. busy)
        end
        return done(false)
    end
    Buy._lastBusyLog = nil

    local purchases = tonumber(Buy._visitPurchases) or 0
    if purchases >= MAX_PURCHASES_PER_VISIT then
        ChatVisitStop("cap")
        return done(false)
    end

    local jobs = Buy.CollectBuyJobs()
    if type(jobs) ~= "table" or #jobs == 0 then
        if StockPiler2.Inventory and StockPiler2.Inventory._ready ~= true then
            if Buy._visitSnapshotSkipLogged ~= true then
                Buy._visitSnapshotSkipLogged = true
                LogBuyOp("skip snapshot-not-ready")
            end
        end
        if (tonumber(Buy._visitBought) or 0) > 0 then
            ChatVisitStop("bought")
        end
        return done(false)
    end
    Buy._visitHadJobs = true

    local money = VisitMoneyBrass()
    local liveMoney = PlayerMoneyBrass()
    if liveMoney > 0 and liveMoney < money then
        money = liveMoney
        Buy._visitMoneyBrass = liveMoney
    end
    local reserve = Buy.GetReserveGold() * BRASS_PER_GOLD
    local budget = Buy.GetBudgetGold() * BRASS_PER_GOLD
    local spent = tonumber(Buy._visitSpentBrass) or 0
    local reserveBlock = false
    local budgetBlock = false

    for i = 1, #jobs do
        local job = jobs[i]
        local item, cost = Buy.FindStoreMatch(job)
        local acquireKey = JobAcquireKey(job, item)
        local bagDeficit = tonumber(job.deficit) or 0
        local remaining = math.max(0, bagDeficit - VisitAcquired(acquireKey))
        if remaining < 1 then
            if acquireKey ~= nil then
                LogVisitSkipOnce(
                    "acquired:" .. tostring(acquireKey),
                    string.format(
                        "acquired key=%s acquired=%d deficit=%d",
                        tostring(acquireKey),
                        VisitAcquired(acquireKey),
                        bagDeficit
                    )
                )
            end
        elseif type(item) ~= "table" and bagDeficit > 0 then
            local jobKey = tostring(job.specKey or job.kind or i)
            if type(Buy._visitNoMatchKeys) ~= "table" then
                Buy._visitNoMatchKeys = {}
            end
            Buy._visitNoMatchKeys[jobKey] = true
            LogVisitSkipOnce(
                "nomatch:" .. jobKey,
                string.format(
                    "no-match job=%s deficit=%d",
                    ToNarrow(job.name or job.label or jobKey),
                    bagDeficit
                )
            )
        elseif type(item) == "table" and (tonumber(cost) or 0) > 0 then
            Buy._visitSawMatch = true
            local vendorMax = 100
            local stackCount = tonumber(item.stackCount) or 1
            if stackCount > 1 then
                vendorMax = stackCount
            end
            local maxByReserve = math.floor((money - reserve) / cost)
            local maxByBudget = math.floor((budget - spent) / cost)
            local qty = math.min(remaining, vendorMax, maxByReserve, maxByBudget)
            if qty < 1 then
                if maxByReserve < 1 then
                    reserveBlock = true
                elseif maxByBudget < 1 then
                    budgetBlock = true
                end
            else
                local costTotal = cost * qty
                if money - costTotal < reserve then
                    reserveBlock = true
                else
                    local slotNum = tonumber(item.slotNum)
                    if slotNum == nil or acquireKey == nil then
                        LogBuyOp("skip bad-slot-or-key job=" .. ToNarrow(job.name or job.kind))
                        return done(false)
                    end
                    local ok, err = VA.BuyItem(item, qty)
                    if ok ~= true then
                        LogBuyOp(string.format(
                            "fail BuyItem slot=%d qty=%d err=%s",
                            slotNum,
                            qty,
                            tostring(err)
                        ))
                        return done(false)
                    end
                    Buy._visitSpentBrass = spent + costTotal
                    Buy._visitBought = (tonumber(Buy._visitBought) or 0) + qty
                    Buy._visitPurchases = purchases + 1
                    Buy._visitMoneyBrass = math.max(0, money - costTotal)
                    NoteVisitAcquired(acquireKey, qty)
                    AfterPurchaseRefresh()
                    LogBuyOp(string.format(
                        "purchase slot=%d qty=%d cost=%d name=%s remainingWas=%d spent=%d moneyLeft=%d",
                        slotNum,
                        qty,
                        costTotal,
                        ToNarrow(item.name or job.name or ""),
                        remaining,
                        tonumber(Buy._visitSpentBrass) or 0,
                        tonumber(Buy._visitMoneyBrass) or 0
                    ))
                    return done(true)
                end
            end
        end
    end

    if reserveBlock then
        ChatVisitStop("reserved")
    elseif budgetBlock then
        ChatVisitStop("budget")
    end
    return done(false)
end

function Buy.OnTick()
    Buy.OnStoreUpdated()
    local VA = StockPiler2.VendorAdapter
    if VA and VA.IsStoreOpen and VA.IsStoreOpen() and Buy.IsEnabled() then
        return Buy.TryBuyNext() == true
    end
    return false
end

function Buy.NeedsTick()
    if not Buy.IsEnabled() then
        return false
    end
    local VA = StockPiler2.VendorAdapter
    return VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
end
