----------------------------------------------------------------
-- StockPiler2 Refine — plant→seed for buffer, plant-need, and resin convert
----------------------------------------------------------------

StockPiler2.Refine = StockPiler2.Refine or {}
local Refine = StockPiler2.Refine

Refine._pendingByPlant = Refine._pendingByPlant or {}
-- plantUid -> seedUid that last bumped pending (for orphan clear without SeedMap walk).
Refine._pendingSeedByPlant = Refine._pendingSeedByPlant or {}
Refine._lastLiveBySeed = Refine._lastLiveBySeed or {}
Refine._issuedSeedThisTick = nil
Refine._intentCacheKey = nil
Refine._intentCache = nil
Refine._refineWaitTicks = 0
Refine._refineDirty = false
Refine._refineDirtyReason = nil
Refine._reconcileSnapGen = -1
Refine._reconcileAllSnapGen = -2
Refine._reconcileAllDoneForSnap = false
Refine._reconcileAllLastResult = false
Refine._reconcileFrameId = 0
Refine._reconcileDoneForFrame = false
Refine._reconcileFrameResult = false
Refine._lastTryTickOnlyThrottle = false
Refine._outstandingAt = Refine._outstandingAt or {}
Refine._expireFlushTried = Refine._expireFlushTried or {}
Refine._bagIndexGen = -1
Refine._bagIndex = nil
Refine.OUTSTANDING_TTL_SEC = 30

local MAX_PENDING_PER_PLANT = 6
local MAX_OUTSTANDING_PER_SEED = 6

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function ToNarrow(value)
    if StockPiler2.ToNarrow then
        return StockPiler2.ToNarrow(value)
    end
    return tostring(value or "")
end

local function LogRefine(msg)
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("refine", msg)
    end
end

--- Drop pending throttle when outstanding was wiped without a successful
--- MaybeCompletePendingRefine (stuck expire / force reconcile).
local function ClearPendingForPlant(plantUid, seedUid, reason)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return false
    end
    local pending = tonumber(Refine._pendingByPlant[plantUid]) or 0
    if pending <= 0 then
        Refine._pendingSeedByPlant[plantUid] = nil
        return false
    end
    Refine._pendingByPlant[plantUid] = nil
    Refine._pendingSeedByPlant[plantUid] = nil
    LogRefine(string.format(
        "clear pending plantUid=%d seedUid=%d was=%d reason=%s",
        plantUid, tonumber(seedUid) or 0, pending, tostring(reason or "expire")
    ))
    return true
end

local function ClearPendingForSeed(seedUid, reason)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local SM = StockPiler2.SeedMap
    local plantUid = SM and SM.GetPlantUidForSeed and (tonumber(SM.GetPlantUidForSeed(seedUid)) or 0) or 0
    if plantUid <= 0 then
        -- Fall back to reverse map from IssueOne.
        local mappedPlant = nil
        for pUid, sUid in pairs(Refine._pendingSeedByPlant) do
            if tonumber(sUid) == seedUid then
                mappedPlant = tonumber(pUid) or 0
                break
            end
        end
        plantUid = mappedPlant or 0
    end
    if plantUid <= 0 then
        return false
    end
    return ClearPendingForPlant(plantUid, seedUid, reason)
end

local function ActivePendingRefinePlantUid()
    local SM = StockPiler2.SeedMap
    local pending = SM and SM._pendingRefine
    if type(pending) ~= "table" then
        return 0
    end
    return tonumber(pending.plantUid) or 0
end

local function OutstandingForPlant(plantUid, preferredSeedUid)
    plantUid = tonumber(plantUid) or 0
    preferredSeedUid = tonumber(preferredSeedUid) or 0
    local RP = StockPiler2.RefinePipeline
    if not RP or not RP.GetOutstanding then
        return 0
    end
    if preferredSeedUid > 0 then
        return tonumber(RP.GetOutstanding(preferredSeedUid)) or 0
    end
    local SM = StockPiler2.SeedMap
    local total = 0
    if SM and SM.GetSeedUidsForPlant then
        local uids = SM.GetSeedUidsForPlant(plantUid)
        if type(uids) == "table" then
            local i
            for i = 1, #uids do
                local seedUid = tonumber(uids[i]) or 0
                if seedUid > 0 then
                    total = total + (tonumber(RP.GetOutstanding(seedUid)) or 0)
                end
            end
        end
    end
    return total
end

--- Clear pending counters that outlived the outstanding ledger (AutoGrow deadlock).
--- Does not clear while outstanding > 0 or SeedMap still has an active pending refine.
local function ClearOrphanPending(reason)
    reason = tostring(reason or "orphan")
    local activePlant = ActivePendingRefinePlantUid()
    local cleared = false
    local plantUid, pending
    for plantUid, pending in pairs(Refine._pendingByPlant) do
        plantUid = tonumber(plantUid) or 0
        pending = tonumber(pending) or 0
        if plantUid > 0 and pending > 0 and plantUid ~= activePlant then
            local seedUid = tonumber(Refine._pendingSeedByPlant[plantUid]) or 0
            local outstanding = OutstandingForPlant(plantUid, seedUid)
            if outstanding <= 0 then
                if ClearPendingForPlant(plantUid, seedUid, reason) then
                    cleared = true
                end
            end
        end
    end
    return cleared
end

local function ReducePendingForSeed(seedUid, delivered)
    seedUid = tonumber(seedUid) or 0
    delivered = tonumber(delivered) or 0
    if seedUid <= 0 or delivered <= 0 then
        return
    end
    local SM = StockPiler2.SeedMap
    local plantUid = SM and SM.GetPlantUidForSeed and (tonumber(SM.GetPlantUidForSeed(seedUid)) or 0) or 0
    if plantUid <= 0 then
        for pUid, sUid in pairs(Refine._pendingSeedByPlant) do
            if tonumber(sUid) == seedUid then
                plantUid = tonumber(pUid) or 0
                break
            end
        end
    end
    if plantUid <= 0 then
        return
    end
    local pending = tonumber(Refine._pendingByPlant[plantUid]) or 0
    if pending <= 0 then
        Refine._pendingSeedByPlant[plantUid] = nil
        return
    end
    pending = pending - delivered
    if pending <= 0 then
        Refine._pendingByPlant[plantUid] = nil
        Refine._pendingSeedByPlant[plantUid] = nil
    else
        Refine._pendingByPlant[plantUid] = pending
    end
end

local function CraftingBackpackType()
    local CA = StockPiler2.CultivatorAdapter
    if CA and CA.CraftingBackpackType then
        return CA.CraftingBackpackType()
    end
    return 4
end

local function InventoryBackpackType()
    local CA = StockPiler2.CultivatorAdapter
    if CA and CA.InventoryBackpackType then
        return CA.InventoryBackpackType()
    end
    return 2
end

local function BackpackTypeForBagKey(bagKey)
    if bagKey == "craft" then
        return CraftingBackpackType()
    end
    return InventoryBackpackType()
end

local function CanRefineItem(item, plantUid, spec)
    if type(item) ~= "table" then
        return false
    end
    local MS = StockPiler2.MaterialSpec
    if type(spec) == "table" and MS and MS.ProductMatches then
        if not MS.ProductMatches(item, spec) then
            return false
        end
    elseif plantUid > 0 and (tonumber(item.uniqueID) or 0) ~= plantUid then
        return false
    end
    local SM = StockPiler2.SeedMap
    if SM and SM.ItemLooksLikeRefinablePlant then
        return SM.ItemLooksLikeRefinablePlant(item) == true
    end
    return item.isRefinable == true
end

function Refine.IsEnabled()
    return StockPiler2.Grow and StockPiler2.Grow.IsEnabled() == true
end

local function IntentCacheKey()
    local Watch = StockPiler2.Watch
    local RP = StockPiler2.RefinePipeline
    local Garden = StockPiler2.Garden
    -- Perf: use planGen (plant/empty/lock), not stage-tick Garden.GetGen — otherwise
    -- growth-stage updates invalidate CollectIntents under Tick (~60s). Matches
    -- BufferFlags / seed-line / plant-job keys. Do not revert to GetGen().
    -- 0.4.125: drop snapGen — every refine delivery used to bust CollectIntents /
    -- BuildBalancedSpecDemand on the next Orch Tick. Issue/reconcile bump RP.GetGen
    -- and InvalidateIntentCache already.
    local gardenGen = 0
    if Garden then
        if Garden.GetPlanGen then
            gardenGen = tonumber(Garden.GetPlanGen()) or 0
        elseif Garden.GetGen then
            gardenGen = tonumber(Garden.GetGen()) or 0
        end
    end
    return table.concat({
        tostring(Watch and Watch.GetGen and Watch.GetGen() or 0),
        tostring(RP and RP.GetGen and RP.GetGen() or 0),
        tostring(gardenGen),
    }, ":")
end

function Refine.InvalidateIntentCache()
    Refine._intentCacheKey = nil
    Refine._intentCache = nil
    Refine._lastCollectEmpty = false
    Refine._lastCollectKey = nil
end

function Refine.MarkRefineDue(reason)
    Refine._refineDirty = true
    reason = tostring(reason or "")
    if reason == "harvest" then
        Refine._refineDirtyReason = "harvest"
    elseif Refine._refineDirtyReason ~= "harvest" then
        -- Do not downgrade an armed harvest dirty to seed-buffer / throttle.
        Refine._refineDirtyReason = (reason ~= "" and reason) or "generic"
    end
end

function Refine.ClearPostHarvestState()
    Refine._refineDirty = false
    Refine._refineDirtyReason = nil
end

function Refine.RefineCheckDue()
    local wait = tonumber(Refine._refineWaitTicks) or 0
    if Refine._refineDirty == true then
        -- Harvest refill is urgent; seed-buffer dirty must honor wait throttle
        -- (Orch used to MarkRefineDue every no-job tick and bypass wait forever).
        if Refine._refineDirtyReason == "harvest" then
            return true
        end
        return wait <= 0
    end
    return wait <= 0
end

function Refine.DecayRefineWaitTicks()
    local wait = tonumber(Refine._refineWaitTicks) or 0
    if wait > 0 then
        Refine._refineWaitTicks = wait - 1
    end
end

--- Refine only when seeds are needed: empty plots with no plantable job, or post-harvest
--- buffer refill when plant cannot proceed. Never refine while a plant job is ready.
function Refine.ShouldAllowRefineNow()
    if Refine.IsEnabled() ~= true then
        return false, "disabled"
    end
    local Orch = StockPiler2.Orchestrator
    if Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() then
        return false, "brew-session"
    end
    local Grow = StockPiler2.Grow
    local bufferPending = Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true
    local empty = Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true
    if empty and Grow then
        local plantable = false
        local plantReason = nil
        local peekReason = nil
        if Grow.PeekSeedsForNextPlant then
            local ok, jobOrReason = Grow.PeekSeedsForNextPlant()
            if ok == true then
                plantable = true
                if type(jobOrReason) == "table" then
                    plantReason = tostring(jobOrReason.plantReason or "")
                end
            else
                peekReason = tostring(jobOrReason or "")
            end
        end
        -- Perf: PeekSeeds only — never HasSeeds/GetPlantJob from the refine gate.
        -- Rebuilding PickPlantCandidate here stacked under Tick+CollectIntents.
        -- Orch probes at tick top. plant-probe-pending: wait unless fill-blocked
        -- (then allow buffer refine). Do not call HasSeedsForNextPlant here.
        if not plantable and (peekReason == "dirty" or peekReason == "unprobed") then
            if not (Grow.IsFillBlocked and Grow.IsFillBlocked() == true) then
                return false, "plant-probe-pending"
            end
        end
        if plantable then
            -- Plant-first for potion/buffer jobs; surplus must not block seed-buffer refine.
            if bufferPending then
                if plantReason == "potion_stock" or plantReason == "seed_buffer" then
                    return false, "plant-first"
                end
            else
                return false, "plant-first"
            end
        end
    end
    if bufferPending then
        return true, "seed-buffer"
    end
    if Refine._refineDirtyReason == "harvest" or Refine._refineDirty == true then
        return true, "post-harvest"
    end
    if empty then
        return true, "pre-plant"
    end
    -- Full plots + stocked seeds: still convert surplus plants for Arboreal Resin.
    if Refine.HasActiveResinNeed and Refine.HasActiveResinNeed() == true then
        return true, "resin-need"
    end
    return false, "idle-grow"
end

--- One snapshot pass of refinable plant stacks for the current Inv.snapGen.
function Refine.EnsureBagIndex()
    local Inv = StockPiler2.Inventory
    local gen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    if Refine._bagIndexGen == gen and type(Refine._bagIndex) == "table" then
        return Refine._bagIndex
    end
    local index = {
        entries = {}, -- { bagKey, slot, item, plantUid, stack }
        byPlantUid = {}, -- plantUid -> { count, bestSlot, bestItem, bestBagKey, bestStack }
    }
    local BA = StockPiler2.BagAdapter
    local SM = StockPiler2.SeedMap
    if Inv and Inv.ForEachItem then
        -- Prefer snapshot item walk; recover bag/slot from _slotIndex when possible.
        local itemBySlot = Inv._itemBySlot
        if type(itemBySlot) == "table" then
            for bagKey, slots in pairs(itemBySlot) do
                if type(slots) == "table" then
                    for slot, item in pairs(slots) do
                        if type(item) == "table"
                            and SM and SM.ItemLooksLikeRefinablePlant
                            and SM.ItemLooksLikeRefinablePlant(item) == true
                        then
                            local plantUid = tonumber(item.uniqueID) or 0
                            local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                            if stack < 1 then
                                stack = 1
                            end
                            index.entries[#index.entries + 1] = {
                                bagKey = bagKey,
                                slot = slot,
                                item = item,
                                plantUid = plantUid,
                                stack = stack,
                            }
                            if plantUid > 0 then
                                local row = index.byPlantUid[plantUid]
                                if type(row) ~= "table" then
                                    row = {
                                        count = 0,
                                        bestSlot = 0,
                                        bestItem = nil,
                                        bestBagKey = nil,
                                        bestStack = 10000,
                                    }
                                    index.byPlantUid[plantUid] = row
                                end
                                row.count = row.count + stack
                                if stack < row.bestStack then
                                    row.bestStack = stack
                                    row.bestSlot = slot
                                    row.bestItem = item
                                    row.bestBagKey = bagKey
                                end
                            end
                        end
                    end
                end
            end
        end
    elseif BA and BA.FetchLight then
        local bags = BA.FetchLight()
        for i = 1, #bags do
            local entry = bags[i]
            BA.IterateSlots(entry, function(bagKey, slot, item)
                if SM and SM.ItemLooksLikeRefinablePlant and SM.ItemLooksLikeRefinablePlant(item) == true then
                    local plantUid = tonumber(item.uniqueID) or 0
                    local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                    if stack < 1 then
                        stack = 1
                    end
                    index.entries[#index.entries + 1] = {
                        bagKey = bagKey,
                        slot = slot,
                        item = item,
                        plantUid = plantUid,
                        stack = stack,
                    }
                end
            end)
        end
    end
    Refine._bagIndex = index
    Refine._bagIndexGen = gen
    return index
end

function Refine.FindRefinablePlantSlotForSpec(spec)
    if type(spec) ~= "table" then
        return 0, nil, CraftingBackpackType()
    end
    local index = Refine.EnsureBagIndex()
    local bestSlot = 0
    local bestItem = nil
    local bestBagKey = nil
    local bestStack = 10000
    for i = 1, #index.entries do
        local e = index.entries[i]
        if CanRefineItem(e.item, 0, spec) and e.stack < bestStack then
            bestStack = e.stack
            bestSlot = e.slot
            bestItem = e.item
            bestBagKey = e.bagKey
        end
    end
    if bestSlot > 0 then
        return bestSlot, bestItem, BackpackTypeForBagKey(bestBagKey)
    end
    return 0, nil, CraftingBackpackType()
end

function Refine.FindRefinablePlantSlot(plantUid, spec)
    plantUid = tonumber(plantUid) or 0
    if type(spec) == "table" then
        return Refine.FindRefinablePlantSlotForSpec(spec)
    end
    if plantUid <= 0 then
        return 0, nil, CraftingBackpackType()
    end
    local index = Refine.EnsureBagIndex()
    local row = index.byPlantUid[plantUid]
    if type(row) == "table" and (tonumber(row.bestSlot) or 0) > 0 then
        return row.bestSlot, row.bestItem, BackpackTypeForBagKey(row.bestBagKey)
    end
    return 0, nil, CraftingBackpackType()
end

function Refine.FindRefinablePlantSlotForSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0, nil, CraftingBackpackType()
    end
    local SM = StockPiler2.SeedMap
    local plantUid = SM and SM.GetPlantUidForSeed and (tonumber(SM.GetPlantUidForSeed(seedUid)) or 0) or 0
    if plantUid > 0 then
        local slot, item, bagType = Refine.FindRefinablePlantSlot(plantUid)
        if slot > 0 then
            return slot, item, bagType
        end
    end
    if not SM or not SM.ResolveSeedForPlantUid then
        return 0, nil, CraftingBackpackType()
    end
    local index = Refine.EnsureBagIndex()
    for i = 1, #index.entries do
        local e = index.entries[i]
        local uid = tonumber(e.plantUid) or 0
        if uid > 0 then
            local seed = SM.ResolveSeedForPlantUid(uid)
            if type(seed) == "table" and (tonumber(seed.uniqueID) or 0) == seedUid then
                return e.slot, e.item, BackpackTypeForBagKey(e.bagKey)
            end
        end
    end
    return 0, nil, CraftingBackpackType()
end

function Refine.CountRefinablePlantsForSpec(spec)
    if type(spec) ~= "table" then
        return 0
    end
    local index = Refine.EnsureBagIndex()
    local total = 0
    for i = 1, #index.entries do
        local e = index.entries[i]
        if CanRefineItem(e.item, 0, spec) then
            total = total + e.stack
        end
    end
    -- PlantUid fallback when ProductMatches misses EFFECT-less cult plants.
    local SM = StockPiler2.SeedMap
    local plantUid = 0
    if type(SM) == "table" then
        if SM.FindPlantUidForHave then
            plantUid = tonumber(SM.FindPlantUidForHave(spec)) or 0
        elseif SM.CachedPlantUidForSpec then
            plantUid = tonumber(SM.CachedPlantUidForSpec(spec)) or 0
        end
    end
    if plantUid > 0 then
        local byUid = Refine.CountRefinablePlants(plantUid)
        if byUid > total then
            total = byUid
        end
    end
    return total
end

function Refine.CountRefinablePlants(plantUid, spec)
    if type(spec) == "table" then
        return Refine.CountRefinablePlantsForSpec(spec)
    end
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return 0
    end
    local index = Refine.EnsureBagIndex()
    local row = index.byPlantUid[plantUid]
    return type(row) == "table" and (tonumber(row.count) or 0) or 0
end

--- Surplus plants held above brew-only need (extras grown/kept for resin convert).
local function DemandRowSurplus(row)
    if type(row) ~= "table" then
        return 0
    end
    local have = tonumber(row.have) or 0
    local brew = tonumber(row.brewAbsolute)
    if brew == nil then
        brew = tonumber(row.absolute) or 0
    end
    local surplus = have - brew
    if surplus < 0 then
        return 0
    end
    return surplus
end

local function GetSpecDemand()
    local RS = StockPiler2.RecipeSpec
    if type(RS) ~= "table" or not RS.BuildBalancedSpecDemand then
        return nil
    end
    return RS.BuildBalancedSpecDemand()
end

--- Highest-stack refinable slot matching spec (resin-need prefers richest feedstock).
function Refine.FindRefinablePlantSlotHighestForSpec(spec)
    if type(spec) ~= "table" then
        return 0, nil, CraftingBackpackType()
    end
    local index = Refine.EnsureBagIndex()
    local bestSlot = 0
    local bestItem = nil
    local bestBagKey = nil
    local bestStack = -1
    for i = 1, #index.entries do
        local e = index.entries[i]
        if CanRefineItem(e.item, 0, spec) and e.stack > bestStack then
            bestStack = e.stack
            bestSlot = e.slot
            bestItem = e.item
            bestBagKey = e.bagKey
        end
    end
    if bestSlot > 0 then
        return bestSlot, bestItem, BackpackTypeForBagKey(bestBagKey)
    end
    return 0, nil, CraftingBackpackType()
end

local function ResolveSeedPlantForSpec(spec, SM)
    local seedUid = 0
    local plantUid = 0
    if type(spec) ~= "table" or type(SM) ~= "table" then
        return seedUid, plantUid
    end
    local seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(spec)
    if type(seed) == "table" then
        seedUid = tonumber(seed.uniqueID) or 0
        if seedUid <= 0 and type(seed.itemData) == "table" then
            seedUid = tonumber(seed.itemData.uniqueID) or 0
        end
        plantUid = tonumber(seed.plantUid) or 0
    end
    if plantUid <= 0 and SM.FindPlantUidForSpec then
        plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
    end
    if seedUid <= 0 and plantUid > 0 and SM.PickBestSeedUid then
        local seedUids = SM.GetSeedUidsForPlant and SM.GetSeedUidsForPlant(plantUid) or {}
        seedUid = tonumber(SM.PickBestSeedUid(plantUid, seedUids, spec)) or 0
    end
    return seedUid, plantUid
end

local function PotionKeySetFromRow(row)
    local keys = {}
    if type(row) ~= "table" or type(row.watchDetails) ~= "table" then
        return keys
    end
    for i = 1, #row.watchDetails do
        local detail = row.watchDetails[i]
        if type(detail) == "table" and detail.potionKey ~= nil then
            keys[detail.potionKey] = true
        end
    end
    return keys
end

local function RowSharesPotionKeys(row, potionKeys)
    if type(row) ~= "table" or type(potionKeys) ~= "table" or type(row.watchDetails) ~= "table" then
        return false
    end
    for i = 1, #row.watchDetails do
        local detail = row.watchDetails[i]
        if type(detail) == "table" and detail.potionKey ~= nil and potionKeys[detail.potionKey] == true then
            return true
        end
    end
    return false
end

local function CandidateFromDemandRow(row, SM, tier, resinSkillLevel)
    if type(row) ~= "table" or type(row.spec) ~= "table" then
        return nil
    end
    if not (SM and SM.IsGrowableSpec and SM.IsGrowableSpec(row.spec)) then
        return nil
    end
    resinSkillLevel = tonumber(resinSkillLevel)
    if resinSkillLevel ~= nil then
        local plantLv = tonumber(row.spec.skillLevel) or 0
        if plantLv ~= resinSkillLevel then
            return nil
        end
    end
    local surplus = DemandRowSurplus(row)
    if surplus <= 0 then
        return nil
    end
    local seedUid, plantUid = ResolveSeedPlantForSpec(row.spec, SM)
    local refinable = Refine.CountRefinablePlants(plantUid, row.spec)
    if refinable <= 0 then
        return nil
    end
    local slot, item, bagType = Refine.FindRefinablePlantSlotHighestForSpec(row.spec)
    if slot <= 0 or type(item) ~= "table" then
        return nil
    end
    if plantUid <= 0 then
        plantUid = tonumber(item.uniqueID) or 0
    end
    -- Bag item must also match resin tier (Special Moment / wrong-tier stacks).
    if resinSkillLevel ~= nil then
        local itemLv = tonumber(item.craftingSkillRequirement)
            or tonumber(item.skillLevel)
            or tonumber(row.spec.skillLevel)
            or 0
        if itemLv ~= resinSkillLevel then
            return nil
        end
    end
    return {
        tier = tier,
        spec = row.spec,
        specKey = row.specKey,
        seedUid = seedUid,
        plantUid = plantUid,
        surplus = surplus,
        refinable = refinable,
        slot = slot,
        item = item,
        bagType = bagType,
        score = refinable,
    }
end

--- Pick plant to convert for Arboreal Resin: same-tier recipe surplus, then same-tier demand surplus.
--- Refine is 1:1 (plant → same-tier seed + same-tier resin); never burn orphans / wrong skill level.
--- @return table|nil pick with slot/item/plantUid/surplus/refinable
function Refine.PickPlantForResinConvert(resinSpec, resinDeficit, preferredPotionKeys)
    if type(resinSpec) ~= "table" then
        -- Compat: old call signature (deficit, preferredKeys) — refuse without resin tier.
        return nil
    end
    resinDeficit = tonumber(resinDeficit) or 0
    if resinDeficit <= 0 then
        return nil
    end
    local resinSkillLevel = tonumber(resinSpec.skillLevel) or 0
    if resinSkillLevel <= 0 then
        return nil
    end
    local SM = StockPiler2.SeedMap
    local demand = GetSpecDemand()
    if type(demand) ~= "table" then
        return nil
    end
    preferredPotionKeys = type(preferredPotionKeys) == "table" and preferredPotionKeys or {}

    local best = nil
    local function consider(cand)
        if type(cand) ~= "table" then
            return
        end
        if best == nil
            or cand.tier < best.tier
            or (cand.tier == best.tier and cand.score > best.score)
            or (cand.tier == best.tier and cand.score == best.score
                and (tonumber(cand.plantUid) or 0) < (tonumber(best.plantUid) or 0))
        then
            best = cand
        end
    end

    for _, row in pairs(demand) do
        local preferred = RowSharesPotionKeys(row, preferredPotionKeys)
            or (tonumber(row.byproductConvertExtra) or 0) > 0
        local tier = preferred and 1 or 2
        consider(CandidateFromDemandRow(row, SM, tier, resinSkillLevel))
    end

    if best ~= nil and type(SM) == "table" and best.seedUid <= 0 and best.plantUid > 0
        and SM.ResolveSeedForPlantUid
    then
        local resolved = SM.ResolveSeedForPlantUid(best.plantUid, best.spec)
        if type(resolved) == "table" then
            best.seedUid = tonumber(resolved.uniqueID) or 0
        end
    end
    return best
end

--- True when same-tier plant surplus can feed a resin convert (no orphan / wrong-level burns).
--- Optional resinSpec: check feedstock for that tier only; else any short byproduct row.
function Refine.HasResinConvertFeedstock(resinSpec)
    local SM = StockPiler2.SeedMap
    local demand = GetSpecDemand()
    if type(demand) ~= "table" or not SM then
        return false
    end
    if type(resinSpec) == "table" then
        local lv = tonumber(resinSpec.skillLevel) or 0
        if lv <= 0 then
            return false
        end
        for _, row in pairs(demand) do
            if CandidateFromDemandRow(row, SM, 2, lv) ~= nil then
                return true
            end
        end
        return false
    end
    for _, row in pairs(demand) do
        if type(row) == "table" and type(row.spec) == "table"
            and SM.IsHarvestByproduct and SM.IsHarvestByproduct(row.spec) == true
            and (tonumber(row.deficit) or 0) > 0
        then
            local lv = tonumber(row.spec.skillLevel) or 0
            if lv > 0 then
                for _, growRow in pairs(demand) do
                    if CandidateFromDemandRow(growRow, SM, 2, lv) ~= nil then
                        return true
                    end
                end
            end
        end
    end
    return false
end

--- Total convert-byproduct deficit across balanced demand (Arboreal Resin etc.).
function Refine.TotalResinDeficit()
    local SM = StockPiler2.SeedMap
    local demand = GetSpecDemand()
    if type(demand) ~= "table" or not SM or not SM.IsHarvestByproduct then
        return 0
    end
    local total = 0
    for _, row in pairs(demand) do
        if type(row) == "table" and type(row.spec) == "table"
            and SM.IsHarvestByproduct(row.spec) == true
        then
            local d = tonumber(row.deficit) or 0
            if d > total then
                total = d
            end
        end
    end
    return total
end

function Refine.HasActiveResinNeed()
    return Refine.TotalResinDeficit() > 0 and Refine.HasResinConvertFeedstock() == true
end

function Refine.LiveSeedCountForSpec(spec)
    if type(spec) ~= "table" then
        return 0
    end
    local SM = StockPiler2.SeedMap
    if SM and SM.CountSeedsInBagsForSpec then
        return tonumber(SM.CountSeedsInBagsForSpec(spec)) or 0
    end
    return 0
end

function Refine.GetSeedBudgetForSpec(spec, seedUid)
    seedUid = tonumber(seedUid) or 0
    -- Bag + in-ground count toward buffer until harvest outcome / user uproot.
    -- Planting moves bag→plot without changing credit; failed harvest or uproot
    -- drops ground with no bag refund → SHORT. Abort/logout refund keeps credit flat.
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    -- Prefer L0 CountByUid when seedUid known — ForSpec walks sample stackCounts
    -- that can stay stale after L0 deltas (mass-refine headroom stuck at buffer-1).
    local liveUid = 0
    if seedUid > 0 then
        liveUid = Refine.LiveSeedCount(seedUid)
    end
    local liveSpec = Refine.LiveSeedCountForSpec(spec)
    local live = liveUid
    if liveSpec > live then
        live = liveSpec
    end
    -- Do not write _lastLiveBySeed here — ForSpec under-count was stomping reconcile
    -- baselines (delivered live 1->N). Baseline only via TrackLiveSeed / ReconcileAll /
    -- GetSeedBudget(uid).
    local ground = 0
    if seedUid > 0 and StockPiler2.Grow and StockPiler2.Grow.CountInGroundSeeds then
        ground = tonumber(StockPiler2.Grow.CountInGroundSeeds(seedUid)) or 0
    end
    local RP = StockPiler2.RefinePipeline
    local outstanding = seedUid > 0 and RP and RP.GetOutstanding(seedUid) or 0
    local credit = live + ground + outstanding
    local headroom = buffer - credit
    if headroom < 0 then
        headroom = 0
    end
    return {
        live = live,
        ground = ground,
        credit = credit,
        headroom = headroom,
        buffer = buffer,
        outstanding = outstanding,
    }
end

function Refine.LiveSeedCount(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local Inv = StockPiler2.Inventory
    if Inv and Inv._ready == true and Inv.CountByUid then
        return Inv.CountByUid(seedUid)
    end
    if Inv and Inv.UniqueIdCount then
        return Inv.UniqueIdCount(seedUid)
    end
    return 0
end

function Refine.TrackLiveSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return
    end
    Refine._lastLiveBySeed[seedUid] = Refine.LiveSeedCount(seedUid)
end

function Refine.GetSeedBudget(seedUid)
    seedUid = tonumber(seedUid) or 0
    -- Bag + in-ground count toward buffer until harvest outcome / user uproot.
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    local live = Refine.LiveSeedCount(seedUid)
    Refine._lastLiveBySeed[seedUid] = live
    local ground = 0
    if seedUid > 0 and StockPiler2.Grow and StockPiler2.Grow.CountInGroundSeeds then
        ground = tonumber(StockPiler2.Grow.CountInGroundSeeds(seedUid)) or 0
    end
    local RP = StockPiler2.RefinePipeline
    local outstanding = RP and RP.GetOutstanding(seedUid) or 0
    local credit = live + ground + outstanding
    local headroom = buffer - credit
    if headroom < 0 then
        headroom = 0
    end
    return {
        live = live,
        ground = ground,
        credit = credit,
        headroom = headroom,
        buffer = buffer,
        outstanding = outstanding,
    }
end

function Refine.ReconcileAll()
    local RP = StockPiler2.RefinePipeline
    local Inv = StockPiler2.Inventory
    if not RP or not Inv then
        return false
    end
    -- No in-flight refine ledger: skip LiveSeedCount walk (was ReconcileAll xN trails
    -- while outstanding was empty or only one seed needed checking).
    if not (RP.HasOutstanding and RP.HasOutstanding() == true) then
        ClearOrphanPending("reconcile-idle")
        if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueuePlanRebuildAfterRefineClear then
            StockPiler2.Scheduler.EnqueuePlanRebuildAfterRefineClear()
        end
        return false
    end
    -- At most one full walk per UPDATE_PROCESSED frame (TryTick + OnInv + Expire used to stack).
    local frameId = tonumber(Refine._reconcileFrameId) or 0
    if frameId > 0
        and Refine._reconcileDoneForFrame == true
        and frameId == (tonumber(Refine._reconcileWalkedFrameId) or -1)
    then
        return Refine._reconcileFrameResult == true
    end
    -- One reconcile walk per inventory snapGen within that frame.
    local snapGen = Inv.GetSnapGen and Inv.GetSnapGen() or 0
    if snapGen == (tonumber(Refine._reconcileAllSnapGen) or -2)
        and Refine._reconcileAllDoneForSnap == true
    then
        return Refine._reconcileAllLastResult == true
    end
    local deliveredAny = false
    local marked = false
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("ReconcileAll")
        marked = true
    end
    -- Only seeds with outstanding counts — do not walk every historically tracked uid.
    local snap = RP.Snapshot and RP.Snapshot() or nil
    if type(snap) ~= "table" then
        if marked and StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("ReconcileAll")
        end
        return false
    end
    for seedUid, outstanding in pairs(snap) do
        seedUid = tonumber(seedUid) or 0
        outstanding = tonumber(outstanding) or 0
        if seedUid > 0 and outstanding > 0 then
            local live = Refine.LiveSeedCount(seedUid)
            local lastLive = tonumber(Refine._lastLiveBySeed[seedUid]) or 0
            if live > lastLive then
                local delivered = live - lastLive
                RP.Reconcile(seedUid, delivered)
                ReducePendingForSeed(seedUid, delivered)
                deliveredAny = true
                LogRefine(string.format(
                    "delivered seedUid=%d live %d->%d outstanding=%d",
                    seedUid, lastLive, live, RP.GetOutstanding(seedUid)
                ))
                if (RP.GetOutstanding(seedUid) or 0) <= 0 then
                    Refine._outstandingAt[seedUid] = nil
                    Refine._expireFlushTried[seedUid] = nil
                    ClearPendingForSeed(seedUid, "reconcile-zero")
                end
            end
            Refine._lastLiveBySeed[seedUid] = live
        end
    end
    ClearOrphanPending("reconcile-orphan")
    Refine._reconcileAllSnapGen = snapGen
    Refine._reconcileAllDoneForSnap = true
    Refine._reconcileAllLastResult = deliveredAny
    Refine._reconcileWalkedFrameId = frameId
    Refine._reconcileDoneForFrame = true
    Refine._reconcileFrameResult = deliveredAny
    if marked and StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("ReconcileAll")
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueuePlanRebuildAfterRefineClear then
        StockPiler2.Scheduler.EnqueuePlanRebuildAfterRefineClear()
    end
    return deliveredAny
end

--- Drop or repair ledger rows that never saw a live-seed increase.
function Refine.ExpireStuckOutstanding()
    ClearOrphanPending("expire-orphan")
    local RP = StockPiler2.RefinePipeline
    if not RP or not RP.Snapshot then
        return
    end
    local now = NowSec()
    local ttl = tonumber(Refine.OUTSTANDING_TTL_SEC) or 30
    local snap = RP.Snapshot()
    for seedUid, n in pairs(snap) do
        seedUid = tonumber(seedUid) or 0
        n = tonumber(n) or 0
        if seedUid > 0 and n > 0 then
            local at = tonumber(Refine._outstandingAt[seedUid]) or 0
            if at <= 0 then
                Refine._outstandingAt[seedUid] = now
            elseif (now - at) >= ttl then
                if Refine._expireFlushTried[seedUid] ~= true then
                    Refine._expireFlushTried[seedUid] = true
                    -- Coalesced bag work — avoid DataUtils.GetItems mid-tick.
                    if StockPiler2.Inventory and StockPiler2.Inventory.MarkDirty then
                        -- Soft dirty: light Flatten if L0 missed delivery — never force FetchForce.
                        StockPiler2.Inventory.MarkDirty({ reason = "refine-expire" })
                    elseif StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueueBagFlush then
                        StockPiler2.Scheduler.EnqueueBagFlush(false)
                    end
                    Refine.ReconcileAll()
                    if (RP.GetOutstanding(seedUid) or 0) <= 0 then
                        Refine._outstandingAt[seedUid] = nil
                        Refine._expireFlushTried[seedUid] = nil
                        ClearPendingForSeed(seedUid, "expire-delivered")
                    end
                else
                    LogRefine(string.format("expire stuck outstanding seedUid=%d n=%d", seedUid, n))
                    if RP.Reconcile then
                        RP.Reconcile(seedUid, n)
                    end
                    ClearPendingForSeed(seedUid, "expire-stuck")
                    Refine._outstandingAt[seedUid] = nil
                    Refine._expireFlushTried[seedUid] = nil
                end
            end
        end
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueuePlanRebuildAfterRefineClear then
        StockPiler2.Scheduler.EnqueuePlanRebuildAfterRefineClear()
    end
end

function Refine.CollectDemandLines()
    local lines = {}
    local allowed = Refine.ShouldAllowRefineNow()
    if allowed ~= true then
        return lines
    end
    local seen = {}
    local RS = StockPiler2.RecipeSpec
    local SM = StockPiler2.SeedMap
    local MS = StockPiler2.MaterialSpec
    if type(RS) ~= "table" or type(SM) ~= "table" or not RS.BuildBalancedSpecDemand then
        return lines
    end
    local demand = RS.BuildBalancedSpecDemand()
    for _, row in pairs(demand) do
        if type(row) == "table" and type(row.spec) == "table"
            and SM.IsGrowableSpec and SM.IsGrowableSpec(row.spec)
        then
            local spec = row.spec
            local productKey = (MS and MS.ProductKey and MS.ProductKey(spec))
                or row.specKey
                or ""
            if productKey ~= "" and seen[productKey] ~= true then
                seen[productKey] = true
                local seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(spec)
                local seedUid = 0
                local plantUid = 0
                if type(seed) == "table" then
                    seedUid = tonumber(seed.uniqueID) or 0
                    if seedUid <= 0 and type(seed.itemData) == "table" then
                        seedUid = tonumber(seed.itemData.uniqueID) or 0
                    end
                    plantUid = tonumber(seed.plantUid) or 0
                end
                if plantUid <= 0 and SM.FindPlantUidForSpec then
                    plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
                end
                if seedUid <= 0 and plantUid > 0 and SM.PickBestSeedUid then
                    local seedUids = SM.GetSeedUidsForPlant and SM.GetSeedUidsForPlant(plantUid) or {}
                    seedUid = tonumber(SM.PickBestSeedUid(plantUid, seedUids, spec)) or 0
                end
                if seedUid > 0 or plantUid > 0 then
                    lines[#lines + 1] = {
                        spec = spec,
                        specKey = productKey,
                        seedUid = seedUid,
                        plantUid = plantUid,
                        deficit = tonumber(row.deficit) or 0,
                    }
                end
            end
        end
    end
    return lines
end

--- Compatibility alias: demand-scoped lines (plant-need).
function Refine.CollectWatchedLines()
    return Refine.CollectDemandLines()
end

local function AppendRefineIntent(intents, SM, line, reason, uses, budget, opts)
    opts = type(opts) == "table" and opts or {}
    local spec = line.spec
    local seedUid = tonumber(line.seedUid) or 0
    local plantUid = tonumber(line.plantUid) or 0
    local slot, item, bagType = Refine.FindRefinablePlantSlotForSpec(spec)
    if slot <= 0 and plantUid > 0 then
        slot, item, bagType = Refine.FindRefinablePlantSlot(plantUid)
    end
    if slot <= 0 and seedUid > 0 then
        slot, item, bagType = Refine.FindRefinablePlantSlotForSeed(seedUid)
    end
    if type(item) == "table" and plantUid <= 0 then
        plantUid = tonumber(item.uniqueID) or 0
    end
    if seedUid <= 0 and type(item) == "table" and SM and SM.ResolveSeedForPlantUid then
        local resolved = SM.ResolveSeedForPlantUid(plantUid, spec)
        if type(resolved) == "table" then
            seedUid = tonumber(resolved.uniqueID) or seedUid
        end
    end
    intents[#intents + 1] = {
        reason = reason,
        spec = spec,
        seedUid = seedUid,
        plantUid = plantUid,
        uses = uses,
        headroom = budget and budget.headroom or 0,
        slot = slot,
        item = item,
        bagType = bagType,
        emergencyPlant = opts.emergencyPlant == true,
    }
end

--- Seed uid an empty plot would plant (cached job even when bag exhausted).
local function EmergencyPlantSeedUid()
    local Grow = StockPiler2.Grow
    if not (Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true) then
        return 0
    end
    local cached = Grow._cachedPlantJob
    if type(cached) == "table" then
        local uid = tonumber(cached.seedUid) or 0
        if uid > 0 then
            return uid
        end
    end
    if Grow.PeekSeedsForNextPlant then
        local ok, job = Grow.PeekSeedsForNextPlant()
        if ok == true and type(job) == "table" then
            return tonumber(job.seedUid) or 0
        end
    end
    return 0
end

function Refine.CollectIntents()
    if Refine.IsEnabled() ~= true then
        return {}
    end
    if Refine.ShouldAllowRefineNow() ~= true then
        return {}
    end
    local cacheKey = IntentCacheKey()
    local bufferOn = StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true
    cacheKey = cacheKey .. ":" .. (bufferOn and "1" or "0")
    if Refine._intentCacheKey == cacheKey and type(Refine._intentCache) == "table" then
        return Refine._intentCache
    end
    local intents = {}
    local SM = StockPiler2.SeedMap
    local RS = StockPiler2.RecipeSpec
    local seenBufferKey = {}
    local appendedBuffer = {}

    if bufferOn and RS and RS.CollectAutoGrowSeedLines then
        local bufferLines = RS.CollectAutoGrowSeedLines()
        for i = 1, #bufferLines do
            local line = bufferLines[i]
            local spec = line.spec
            local seedUid = tonumber(line.seedUid) or 0
            local plantUid = tonumber(line.plantUid) or 0
            local key = tostring(line.specKey or seedUid)
            if type(spec) == "table" and seenBufferKey[key] ~= true then
                seenBufferKey[key] = true
                local budget = Refine.GetSeedBudgetForSpec(spec, seedUid)
                local refinable = Refine.CountRefinablePlants(plantUid, spec)
                if budget.headroom > 0 and refinable > 0 then
                    local uses = math.min(budget.headroom, refinable, 5)
                    AppendRefineIntent(intents, SM, line, "seed-buffer", uses, budget)
                    appendedBuffer[key] = true
                    if seedUid > 0 then
                        appendedBuffer["uid:" .. tostring(seedUid)] = true
                    end
                end
            end
        end
    end

    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("CollectDemandLines")
    end
    local demandLines = Refine.CollectDemandLines()
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("CollectDemandLines")
    end
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("CollectIntents")
    end
    local emergencyUid = 0
    if bufferOn then
        emergencyUid = EmergencyPlantSeedUid()
    end
    for i = 1, #demandLines do
        local line = demandLines[i]
        local spec = line.spec
        local seedUid = tonumber(line.seedUid) or 0
        local plantUid = tonumber(line.plantUid) or 0
        local key = tostring(line.specKey or seedUid)
        if type(spec) == "table"
            and appendedBuffer[key] ~= true
            and (seedUid <= 0 or appendedBuffer["uid:" .. tostring(seedUid)] ~= true)
        then
            local budget = Refine.GetSeedBudgetForSpec(spec, seedUid)
            local refinable = Refine.CountRefinablePlants(plantUid, spec)
            local liveOk = (tonumber(budget.live) or 0) <= 0
                and (tonumber(budget.outstanding) or 0) <= 0
            local deficitOk = (tonumber(line.deficit) or 0) > 0 and refinable > 0
            if liveOk and deficitOk then
                local allow = false
                local emergency = false
                if not bufferOn then
                    allow = true
                else
                    local headroom = tonumber(budget.headroom) or 0
                    if headroom > 0 then
                        allow = true
                    elseif emergencyUid > 0 and seedUid == emergencyUid then
                        allow = true
                        emergency = true
                    end
                end
                if allow then
                    AppendRefineIntent(intents, SM, line, "plant-need", 1, budget, {
                        emergencyPlant = emergency,
                    })
                end
            end
        end
    end

    -- Convert surplus plants for Arboreal Resin (and other harvest byproducts).
    if SM and SM.IsHarvestByproduct and RS and RS.BuildBalancedSpecDemand then
        local demand = RS.BuildBalancedSpecDemand()
        if type(demand) == "table" then
            local resinSeen = {}
            for _, row in pairs(demand) do
                if type(row) == "table" and type(row.spec) == "table"
                    and SM.IsHarvestByproduct(row.spec) == true
                then
                    local deficit = tonumber(row.deficit) or 0
                    local resinKey = tostring(row.specKey or "")
                    if deficit > 0 and resinKey ~= "" and resinSeen[resinKey] ~= true then
                        resinSeen[resinKey] = true
                        local preferredKeys = PotionKeySetFromRow(row)
                        local pick = Refine.PickPlantForResinConvert(row.spec, deficit, preferredKeys)
                        if type(pick) == "table" and (tonumber(pick.slot) or 0) > 0 then
                            local uses = math.min(
                                deficit,
                                tonumber(pick.surplus) or 0,
                                tonumber(pick.refinable) or 0,
                                5
                            )
                            if uses > 0 then
                                intents[#intents + 1] = {
                                    reason = "resin-need",
                                    spec = pick.spec,
                                    seedUid = tonumber(pick.seedUid) or 0,
                                    plantUid = tonumber(pick.plantUid) or 0,
                                    uses = uses,
                                    headroom = 0,
                                    slot = pick.slot,
                                    item = pick.item,
                                    bagType = pick.bagType,
                                    emergencyPlant = false,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    local function ReasonPriority(reason)
        if reason == "plant-need" then
            return 0
        end
        if reason == "resin-need" then
            return 1
        end
        return 2
    end
    table.sort(intents, function(a, b)
        local pa = ReasonPriority(a.reason)
        local pb = ReasonPriority(b.reason)
        if pa ~= pb then
            return pa < pb
        end
        return (tonumber(a.seedUid) or 0) < (tonumber(b.seedUid) or 0)
    end)
    Refine._intentCacheKey = cacheKey
    Refine._intentCache = intents
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("CollectIntents")
    end
    return intents
end

function Refine.CanIssue(intent)
    if type(intent) ~= "table" then
        return false, "nil-intent"
    end
    local seedUid = tonumber(intent.seedUid) or 0
    local plantUid = tonumber(intent.plantUid) or 0
    if Refine._issuedSeedThisTick ~= nil and seedUid > 0 and Refine._issuedSeedThisTick == seedUid then
        return false, "duplicate-tick"
    end
    local RP = StockPiler2.RefinePipeline
    if RP and RP.GetOutstanding(seedUid) >= MAX_OUTSTANDING_PER_SEED then
        return false, "outstanding-throttle"
    end
    local pending = tonumber(Refine._pendingByPlant[plantUid]) or 0
    if pending >= MAX_PENDING_PER_PLANT then
        return false, "pending-throttle"
    end
    if (tonumber(intent.slot) or 0) <= 0 or type(intent.item) ~= "table" then
        return false, "no-slot"
    end
    if (tonumber(intent.uses) or 0) <= 0 then
        return false, "no-uses"
    end
    return true, nil
end

function Refine.IssueOne(intent, opId)
    local ok = Refine.CanIssue(intent)
    if ok ~= true then
        return false
    end
    if SendUseItem == nil or EA_Window_Backpack == nil or EA_Window_Backpack.GetCursorForBackpack == nil then
        LogRefine("issue blocked missing SendUseItem/GetCursorForBackpack")
        return false
    end
    local slot = tonumber(intent.slot) or 0
    local item = intent.item
    local bagType = tonumber(intent.bagType) or CraftingBackpackType()
    local plantUid = tonumber(intent.plantUid) or tonumber(item.uniqueID) or 0
    local seedUid = tonumber(intent.seedUid) or 0
    local uses = tonumber(intent.uses) or 1
    local reason = tostring(intent.reason or "refine")
    local pending = tonumber(Refine._pendingByPlant[plantUid]) or 0
    local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
    local maxUses = (reason == "seed-buffer" or reason == "resin-need") and 5 or 1
    uses = math.min(uses, stack, MAX_PENDING_PER_PLANT - pending, maxUses)
    -- Fresh uid budget: never issue more than remaining seed-buffer headroom
    -- (plant-need used to ignore ground credit and overshoot buffer).
    -- resin-need ignores buffer headroom (must convert when buffer is full).
    local bufferOn = StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true
    if seedUid > 0 and reason ~= "resin-need"
        and (reason == "seed-buffer" or (reason == "plant-need" and bufferOn))
    then
        local budget = Refine.GetSeedBudget(seedUid)
        local headroom = tonumber(budget and budget.headroom) or 0
        if reason == "plant-need" and intent.emergencyPlant == true then
            uses = math.min(uses, 1)
        elseif headroom < 1 then
            return false
        else
            uses = math.min(uses, headroom)
        end
    end
    if uses < 1 then
        return false
    end

    local SM = StockPiler2.SeedMap
    if SM and SM.BeginPendingRefine then
        SM.BeginPendingRefine(item)
    end
    Refine.TrackLiveSeed(seedUid)

    if StockPiler2.Scheduler and StockPiler2.Scheduler.SuppressInventorySideEffects then
        StockPiler2.Scheduler.SuppressInventorySideEffects(2)
    end

    local location = EA_Window_Backpack.GetCursorForBackpack(bagType)
    local sent = 0
    for _ = 1, uses do
        local ok, err = StockPiler2.TryCall("SendUseItem", SendUseItem, location, slot, 0, 0, 0)
        if ok ~= true then
            LogRefine(string.format(
                "issue failed plantUid=%d seedUid=%d err=%s",
                plantUid, seedUid, tostring(err)
            ))
            break
        end
        sent = sent + 1
        local RP = StockPiler2.RefinePipeline
        if RP and RP.Register then
            RP.Register(seedUid, plantUid)
            Refine._outstandingAt[seedUid] = NowSec()
            Refine._expireFlushTried[seedUid] = nil
        end
    end
    if sent <= 0 then
        return false
    end

    Refine._pendingByPlant[plantUid] = pending + sent
    if plantUid > 0 and seedUid > 0 then
        Refine._pendingSeedByPlant[plantUid] = seedUid
    end
    Refine._issuedSeedThisTick = seedUid
    -- Force reconcile on next snap advance (Issue bumps via bag flush / L0).
    Refine._reconcileSnapGen = -1
    Refine._reconcileAllDoneForSnap = false
    LogRefine(string.format(
        "%s plantUid=%d seedUid=%d uses=%d headroom=%d name=%s opId=%s",
        reason,
        plantUid,
        seedUid,
        sent,
        tonumber(intent.headroom) or 0,
        ToNarrow(item.name),
        tostring(opId or "?")
    ))
    if StockPiler2.Grow and StockPiler2.Grow.InvalidatePlantQueue then
        StockPiler2.Grow.InvalidatePlantQueue({ jobOnly = true })
    end
    -- Hold PlanRebuild until outstanding clears (0.4.125).
    local Sch = StockPiler2.Scheduler
    if Sch then
        Sch._planHeldForRefine = true
    end
    if Sch and Sch.EnqueueBagFlush then
        StockPiler2.Scheduler.EnqueueBagFlush(false)
    end
    Refine.InvalidateIntentCache()
    Refine._refineWaitTicks = (reason == "seed-buffer") and 2 or 5
    Refine._refineDirty = false
    Refine._refineDirtyReason = nil
    if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
        StockPiler2.Scheduler.WakeAutoGrow()
    end
    return true
end

function Refine.TryTick(opId)
    if Refine.IsEnabled() ~= true then
        return false
    end
    if Refine.ShouldAllowRefineNow() ~= true then
        return false
    end
    if Refine.RefineCheckDue() ~= true then
        return false
    end
    -- Unblock AutoGrow when pending outlived outstanding (no bag snap required).
    ClearOrphanPending("trytick-orphan")
    local cacheKey = IntentCacheKey()
    local bufferOn = StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true
    cacheKey = cacheKey .. ":" .. (bufferOn and "1" or "0")
    -- Negative / throttle-only result: skip Collect* when gens unchanged.
    if Refine._lastCollectEmpty == true
        and Refine._lastCollectKey == cacheKey
    then
        Refine._refineWaitTicks = math.max(tonumber(Refine._refineWaitTicks) or 0, 10)
        return false
    end
    if Refine._lastTryTickOnlyThrottle == true
        and type(Refine._intentCache) == "table"
        and Refine._intentCacheKey ~= nil
        and Refine._intentCacheKey == cacheKey
    then
        return false
    end
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("Refine.TryTick")
    end
    Refine._issuedSeedThisTick = nil
    -- Reconcile owned by OnUpdateProcessed (frame-gated); do not walk again here.
    local intents = Refine.CollectIntents()
    local onlyThrottle = #intents > 0
    for i = 1, #intents do
        local intent = intents[i]
        local ok, why = Refine.CanIssue(intent)
        if ok == true then
            onlyThrottle = false
            if Refine.IssueOne(intent, opId) == true then
                Refine._lastTryTickOnlyThrottle = false
                Refine._lastCollectEmpty = false
                Refine._lastCollectKey = nil
                if StockPiler2.Perf and StockPiler2.Perf.End then
                    StockPiler2.Perf.End("Refine.TryTick")
                end
                return true
            end
        elseif why == "pending-throttle" or why == "outstanding-throttle" then
            -- Do not clear pending or IssueOne here — that turned the throttle into
            -- uses=4 burst refine (Goldweed mass-refine). Expire TTL clears pending.
        else
            onlyThrottle = false
            if why == "no-slot" then
                LogRefine(string.format(
                    "skip %s seedUid=%d plantUid=%d no refinable plant in bags",
                    tostring(intent.reason or "?"),
                    tonumber(intent.seedUid) or 0,
                    tonumber(intent.plantUid) or 0
                ))
            end
        end
    end
    Refine._lastTryTickOnlyThrottle = onlyThrottle == true and #intents > 0
    Refine._lastCollectKey = cacheKey
    Refine._lastCollectEmpty = (#intents == 0) or (onlyThrottle == true)
    if Refine._refineDirty == true or Refine._refineDirtyReason == "harvest" then
        Refine.ClearPostHarvestState()
    end
    local Grow = StockPiler2.Grow
    -- Intents exist but only throttle gates: unlock AutoGrow; do not fill-block.
    if onlyThrottle == true then
        Refine.MarkRefineDue("throttle-clear")
        Refine._refineWaitTicks = 2
        if Grow and Grow.ClearFillBlocked then
            Grow.ClearFillBlocked()
        end
        if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
            StockPiler2.Scheduler.WakeAutoGrow()
        end
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Refine.TryTick")
        end
        return false
    end
    -- Empty intents: longer wait so idle Collect* does not rebuild every 5 ticks.
    if #intents == 0 then
        Refine._refineWaitTicks = 10
    else
        Refine._refineWaitTicks = 5
    end
    -- Do not fill-block when empty plots still have a plantable job — that starved replant
    -- after harvest when the seed buffer was already full (no refine intents).
    if Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() then
        local plantJob = nil
        if Grow.GetPlantJob then
            plantJob = Grow.GetPlantJob()
        end
        if plantJob ~= nil then
            if Grow.ClearFillBlocked then
                Grow.ClearFillBlocked()
            end
            -- Seeds ready: wait ticks only; never fill-block.
        elseif Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() then
            -- Refinable plants remain: keep AutoGrow awake for refine, not idle.
            if Grow.ClearFillBlocked then
                Grow.ClearFillBlocked()
            end
            Refine.MarkRefineDue("buffer-refine")
        elseif Grow.SetFillBlocked then
            Grow.SetFillBlocked(true, 5)
        end
    end
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("Refine.TryTick")
    end
    return false
end

function Refine.OnInventoryUpdated()
    -- Reconcile first; do not bust intent cache on every bag snap (Collect* was
    -- rebuilding mid-delivery storms). Invalidate only when a refine completes.
    Refine.ReconcileAll()
    local SM = StockPiler2.SeedMap
    if SM and SM.MaybeCompletePendingRefine then
        local result = SM.MaybeCompletePendingRefine()
        if type(result) == "table" then
            local seedUid = tonumber(result.seedUid) or 0
            local plantUid = tonumber(result.plantUid) or 0
            if plantUid > 0 then
                local pending = tonumber(Refine._pendingByPlant[plantUid]) or 0
                if pending > 1 then
                    Refine._pendingByPlant[plantUid] = pending - 1
                else
                    Refine._pendingByPlant[plantUid] = nil
                    Refine._pendingSeedByPlant[plantUid] = nil
                end
            end
            if seedUid > 0 then
                Refine.TrackLiveSeed(seedUid)
                -- Do not clear snap/frame gates for a second walk; TrackLiveSeed
                -- updates baseline. Next frame / next snap reconciles deliveries.
            end
            Refine.InvalidateIntentCache()
            Refine._lastTryTickOnlyThrottle = false
            if StockPiler2.Grow and StockPiler2.Grow.InvalidatePlantQueue then
                StockPiler2.Grow.InvalidatePlantQueue({ jobOnly = true })
            end
            -- 0.4.125: same hitch fusion as harvest Complete — move PlanRebuild /
            -- UiFlush off ReconcileAll + ApplySlots frame.
            local Sch = StockPiler2.Scheduler
            if Sch and Sch.SkipPlanThisFrame then
                Sch.SkipPlanThisFrame()
            end
            if Sch and Sch.SkipUiThisFrame then
                Sch.SkipUiThisFrame()
            end
            if Sch and Sch.EnqueuePlanRebuildAfterRefineClear then
                Sch.EnqueuePlanRebuildAfterRefineClear()
            end
        end
    end
end

function Refine.OnUpdateProcessed()
    -- New UPDATE_PROCESSED frame: allow one ReconcileAll walk this frame.
    Refine._reconcileFrameId = (tonumber(Refine._reconcileFrameId) or 0) + 1
    Refine._reconcileDoneForFrame = false

    -- Reconcile only when inventory snap advanced (or after Issue forced _reconcileSnapGen=-1).
    -- Polling every frame while HasOutstanding caused x1800 trail storms.
    local needWork = false
    local RP = StockPiler2.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() then
        needWork = true
    end
    if not needWork then
        local SM = StockPiler2.SeedMap
        if SM and type(SM._pendingRefine) == "table" then
            needWork = true
        end
    end
    if not needWork then
        for _, pending in pairs(Refine._pendingByPlant) do
            if (tonumber(pending) or 0) > 0 then
                needWork = true
                break
            end
        end
    end
    if needWork ~= true then
        return
    end

    local hadOutstanding = RP and RP.HasOutstanding and RP.HasOutstanding() == true
    local SM = StockPiler2.SeedMap
    local hadSeedPending = SM and type(SM._pendingRefine) == "table"
    Refine.ExpireStuckOutstanding()

    local Inv = StockPiler2.Inventory
    local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    if snapGen == (tonumber(Refine._reconcileSnapGen) or -1) then
        -- No new bag snap: still clear orphan pending so AutoGrow cannot wedge.
        if hadOutstanding ~= true and hadSeedPending ~= true then
            ClearOrphanPending("update-orphan")
        end
        return
    end
    Refine._reconcileSnapGen = snapGen

    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("Refine.OnUpdateProcessed")
    end
    Refine.OnInventoryUpdated()
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("Refine.OnUpdateProcessed")
    end
end

function Refine.DumpDiagnostics(emit)
    emit = type(emit) == "function" and emit or function() end
    local bufferOn = StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true
    emit("--- refine ---")
    emit("  enabled=" .. tostring(Refine.IsEnabled()))
    emit("  seedBufferEnabled=" .. tostring(bufferOn))
    local RS = StockPiler2.RecipeSpec
    local lines = {}
    if bufferOn and RS and RS.CollectAutoGrowSeedLines then
        lines = RS.CollectAutoGrowSeedLines()
        emit("  bufferLines=" .. tostring(#lines))
    else
        lines = Refine.CollectDemandLines()
        emit("  demandLines=" .. tostring(#lines))
    end
    if #lines == 0 then
        emit("  (no seed lines)")
    end
    for i = 1, #lines do
        local line = lines[i]
        local spec = line.spec
        local seedUid = tonumber(line.seedUid) or 0
        local plantUid = tonumber(line.plantUid) or 0
        local budget = type(spec) == "table"
            and Refine.GetSeedBudgetForSpec(spec, seedUid)
            or Refine.GetSeedBudget(seedUid)
        local refinable = type(spec) == "table"
            and Refine.CountRefinablePlants(plantUid, spec)
            or (plantUid > 0 and Refine.CountRefinablePlants(plantUid) or 0)
        emit(string.format(
            "  productKey=%s seedUid=%d plantUid=%d live=%d ground=%d outstanding=%d headroom=%d refinable=%d deficit=%d",
            tostring(line.specKey or "?"),
            seedUid,
            plantUid,
            tonumber(budget.live) or 0,
            tonumber(budget.ground) or 0,
            tonumber(budget.outstanding) or 0,
            tonumber(budget.headroom) or 0,
            refinable,
            tonumber(line.deficit) or 0
        ))
    end
    local pendingAny = false
    for plantUid, pending in pairs(Refine._pendingByPlant) do
        pending = tonumber(pending) or 0
        if pending > 0 then
            pendingAny = true
            emit(string.format(
                "  pendingByPlant plantUid=%d pending=%d",
                tonumber(plantUid) or 0,
                pending
            ))
        end
    end
    if pendingAny ~= true then
        emit("  pendingByPlant: (none)")
    end
    local intents = Refine.CollectIntents()
    if #intents == 0 then
        emit("  intents: (none)")
    else
        for i = 1, #intents do
            local intent = intents[i]
            local can, why = Refine.CanIssue(intent)
            emit(string.format(
                "  intent %s seedUid=%d plantUid=%d uses=%d slot=%d can=%s why=%s",
                tostring(intent.reason),
                tonumber(intent.seedUid) or 0,
                tonumber(intent.plantUid) or 0,
                tonumber(intent.uses) or 0,
                tonumber(intent.slot) or 0,
                tostring(can == true),
                tostring(why or "")
            ))
        end
    end
end
