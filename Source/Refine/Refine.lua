----------------------------------------------------------------
-- StockPiler2 Refine — plant→seed conversion for buffer + plant need
----------------------------------------------------------------

StockPiler2.Refine = StockPiler2.Refine or {}
local Refine = StockPiler2.Refine

Refine._pendingByPlant = Refine._pendingByPlant or {}
Refine._lastLiveBySeed = Refine._lastLiveBySeed or {}
Refine._issuedSeedThisTick = nil
Refine._intentCacheKey = nil
Refine._intentCache = nil
Refine._refineWaitTicks = 0
Refine._refineDirty = false
Refine._refineDirtyReason = nil
Refine._reconcileSnapGen = -1
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
    local Inv = StockPiler2.Inventory
    local Watch = StockPiler2.Watch
    local RP = StockPiler2.RefinePipeline
    return table.concat({
        tostring(Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0),
        tostring(Watch and Watch.GetGen and Watch.GetGen() or 0),
        tostring(RP and RP.GetGen and RP.GetGen() or 0),
    }, ":")
end

function Refine.InvalidateIntentCache()
    Refine._intentCacheKey = nil
    Refine._intentCache = nil
end

function Refine.MarkRefineDue(reason)
    Refine._refineDirty = true
    if reason == "harvest" then
        Refine._refineDirtyReason = "harvest"
    end
end

function Refine.ClearPostHarvestState()
    Refine._refineDirty = false
    Refine._refineDirtyReason = nil
end

function Refine.RefineCheckDue()
    if Refine._refineDirty == true then
        return true
    end
    return (tonumber(Refine._refineWaitTicks) or 0) <= 0
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
    local empty = Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true
    if empty and Grow then
        local plantable = false
        if Grow.PeekSeedsForNextPlant then
            local ok = Grow.PeekSeedsForNextPlant()
            if ok == true then
                plantable = true
            end
        end
        if not plantable and Grow.HasSeedsForNextPlant then
            plantable = Grow.HasSeedsForNextPlant() == true
        end
        if plantable then
            return false, "plant-first"
        end
    end
    if Refine._refineDirtyReason == "harvest" or Refine._refineDirty == true then
        return true, "post-harvest"
    end
    if empty then
        return true, "pre-plant"
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
    -- Live bag counts ignore in-ground plantings. Server refunds those seeds on
    -- abort/logout, so refining to buffer while plots grow can overstock.
    -- Later: credit pending/growing plots toward live if desired.
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    local live = Refine.LiveSeedCountForSpec(spec)
    if live <= 0 and seedUid > 0 then
        live = Refine.LiveSeedCount(seedUid)
    end
    if seedUid > 0 then
        Refine._lastLiveBySeed[seedUid] = live
    end
    local RP = StockPiler2.RefinePipeline
    local outstanding = seedUid > 0 and RP and RP.GetOutstanding(seedUid) or 0
    local credit = live + outstanding
    local headroom = buffer - credit
    if headroom < 0 then
        headroom = 0
    end
    return {
        live = live,
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
    -- Live bag counts ignore in-ground plantings. Server refunds those seeds on
    -- abort/logout, so refining to buffer while plots grow can overstock.
    -- Later: credit pending/growing plots toward live if desired.
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    local live = Refine.LiveSeedCount(seedUid)
    Refine._lastLiveBySeed[seedUid] = live
    local RP = StockPiler2.RefinePipeline
    local outstanding = RP and RP.GetOutstanding(seedUid) or 0
    local credit = live + outstanding
    local headroom = buffer - credit
    if headroom < 0 then
        headroom = 0
    end
    return {
        live = live,
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
    local hasOutstanding = RP.HasOutstanding and RP.HasOutstanding() == true
    local deliveredAny = false
    local marked = false
    if hasOutstanding and StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("ReconcileAll")
        marked = true
    end
    for seedUid, lastLive in pairs(Refine._lastLiveBySeed) do
        seedUid = tonumber(seedUid) or 0
        if seedUid > 0 then
            local live = Refine.LiveSeedCount(seedUid)
            lastLive = tonumber(lastLive) or 0
            if live > lastLive and RP.GetOutstanding and RP.GetOutstanding(seedUid) > 0 then
                local delivered = live - lastLive
                RP.Reconcile(seedUid, delivered)
                deliveredAny = true
                LogRefine(string.format(
                    "delivered seedUid=%d live %d->%d outstanding=%d",
                    seedUid, lastLive, live, RP.GetOutstanding(seedUid)
                ))
                if (RP.GetOutstanding(seedUid) or 0) <= 0 then
                    Refine._outstandingAt[seedUid] = nil
                    Refine._expireFlushTried[seedUid] = nil
                end
            end
            Refine._lastLiveBySeed[seedUid] = live
        end
    end
    if marked and StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("ReconcileAll")
    end
    return deliveredAny
end

--- Drop or repair ledger rows that never saw a live-seed increase.
function Refine.ExpireStuckOutstanding()
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
                    local Inv = StockPiler2.Inventory
                    if Inv and Inv.Flush then
                        Inv.Flush({ force = true })
                    end
                    Refine.ReconcileAll()
                    if (RP.GetOutstanding(seedUid) or 0) <= 0 then
                        Refine._outstandingAt[seedUid] = nil
                        Refine._expireFlushTried[seedUid] = nil
                    end
                else
                    LogRefine(string.format("expire stuck outstanding seedUid=%d n=%d", seedUid, n))
                    if RP.Reconcile then
                        RP.Reconcile(seedUid, n)
                    end
                    Refine._outstandingAt[seedUid] = nil
                    Refine._expireFlushTried[seedUid] = nil
                end
            end
        end
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
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("BuildBalancedSpecDemand")
    end
    local demand = RS.BuildBalancedSpecDemand()
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("BuildBalancedSpecDemand")
    end
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

local function AppendRefineIntent(intents, SM, line, reason, uses, budget)
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
    }
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
    local seenBuffer = {}

    if bufferOn and RS and RS.CollectAutoGrowSeedLines then
        if StockPiler2.Perf and StockPiler2.Perf.Begin then
            StockPiler2.Perf.Begin("CollectAutoGrowSeedLines")
        end
        local bufferLines = RS.CollectAutoGrowSeedLines()
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("CollectAutoGrowSeedLines")
        end
        for i = 1, #bufferLines do
            local line = bufferLines[i]
            local spec = line.spec
            local seedUid = tonumber(line.seedUid) or 0
            local plantUid = tonumber(line.plantUid) or 0
            local key = tostring(line.specKey or seedUid)
            if type(spec) == "table" and seenBuffer[key] ~= true then
                seenBuffer[key] = true
                local budget = Refine.GetSeedBudgetForSpec(spec, seedUid)
                local refinable = Refine.CountRefinablePlants(plantUid, spec)
                if budget.headroom > 0 and refinable > 0 then
                    local uses = math.min(budget.headroom, refinable, 1)
                    AppendRefineIntent(intents, SM, line, "seed-buffer", uses, budget)
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
    for i = 1, #demandLines do
        local line = demandLines[i]
        local spec = line.spec
        local seedUid = tonumber(line.seedUid) or 0
        local plantUid = tonumber(line.plantUid) or 0
        if type(spec) == "table" then
            local budget = Refine.GetSeedBudgetForSpec(spec, seedUid)
            local refinable = Refine.CountRefinablePlants(plantUid, spec)
            if budget.live <= 0 and budget.outstanding <= 0
                and (tonumber(line.deficit) or 0) > 0 and refinable > 0
            then
                AppendRefineIntent(intents, SM, line, "plant-need", 1, budget)
            end
        end
    end
    table.sort(intents, function(a, b)
        local pa = a.reason == "plant-need" and 0 or 1
        local pb = b.reason == "plant-need" and 0 or 1
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
    uses = math.min(uses, stack, MAX_PENDING_PER_PLANT - pending, 1)
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
    Refine._issuedSeedThisTick = seedUid
    -- Force reconcile on next snap advance (Issue bumps via bag flush / L0).
    Refine._reconcileSnapGen = -1
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
    if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueueBagFlush then
        StockPiler2.Scheduler.EnqueueBagFlush(false)
    end
    Refine.InvalidateIntentCache()
    Refine._refineWaitTicks = 5
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
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("Refine.TryTick")
    end
    Refine._issuedSeedThisTick = nil
    Refine.ReconcileAll()
    local intents = Refine.CollectIntents()
    for i = 1, #intents do
        local intent = intents[i]
        local ok, why = Refine.CanIssue(intent)
        if ok == true then
            if Refine.IssueOne(intent, opId) == true then
                if StockPiler2.Perf and StockPiler2.Perf.End then
                    StockPiler2.Perf.End("Refine.TryTick")
                end
                return true
            end
        elseif why == "no-slot" then
            LogRefine(string.format(
                "skip %s seedUid=%d plantUid=%d no refinable plant in bags",
                tostring(intent.reason or "?"),
                tonumber(intent.seedUid) or 0,
                tonumber(intent.plantUid) or 0
            ))
        end
    end
    if Refine._refineDirty == true or Refine._refineDirtyReason == "harvest" then
        Refine.ClearPostHarvestState()
    end
    Refine._refineWaitTicks = 5
    -- Do not fill-block when empty plots still have a plantable job — that starved replant
    -- after harvest when the seed buffer was already full (no refine intents).
    local Grow = StockPiler2.Grow
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
    Refine.InvalidateIntentCache()
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
                end
            end
            if seedUid > 0 then
                Refine.TrackLiveSeed(seedUid)
                Refine.ReconcileAll()
            end
            if StockPiler2.Grow and StockPiler2.Grow.InvalidatePlantQueue then
                StockPiler2.Grow.InvalidatePlantQueue({ jobOnly = true })
            end
        end
    end
end

function Refine.OnUpdateProcessed()
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

    Refine.ExpireStuckOutstanding()

    local Inv = StockPiler2.Inventory
    local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    if snapGen == (tonumber(Refine._reconcileSnapGen) or -1) then
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
            "  productKey=%s seedUid=%d plantUid=%d live=%d outstanding=%d headroom=%d refinable=%d deficit=%d",
            tostring(line.specKey or "?"),
            seedUid,
            plantUid,
            tonumber(budget.live) or 0,
            tonumber(budget.outstanding) or 0,
            tonumber(budget.headroom) or 0,
            refinable,
            tonumber(line.deficit) or 0
        ))
    end
    local intents = Refine.CollectIntents()
    if #intents == 0 then
        emit("  intents: (none)")
    else
        for i = 1, #intents do
            local intent = intents[i]
            local can = Refine.CanIssue(intent)
            emit(string.format(
                "  intent %s seedUid=%d plantUid=%d uses=%d slot=%d can=%s",
                tostring(intent.reason),
                tonumber(intent.seedUid) or 0,
                tonumber(intent.plantUid) or 0,
                tonumber(intent.uses) or 0,
                tonumber(intent.slot) or 0,
                tostring(can == true)
            ))
        end
    end
end
