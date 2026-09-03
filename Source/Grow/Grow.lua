----------------------------------------------------------------
-- StockPiler2 Grow — AutoGrow planting (one seed per orchestrator tick)
----------------------------------------------------------------

StockPiler2.Grow = StockPiler2.Grow or {}
local Grow = StockPiler2.Grow

Grow._pendingPlant = Grow._pendingPlant or {}
Grow._pendingPlantAt = Grow._pendingPlantAt or {}
Grow._pendingSeedUid = Grow._pendingSeedUid or {}
Grow._pendingAdditive = Grow._pendingAdditive or {}
Grow._pendingAdditiveAt = Grow._pendingAdditiveAt or {}
Grow._additiveCursor = Grow._additiveCursor or 1
Grow._additiveDirty = false
Grow._fillCursor = Grow._fillCursor or 1
Grow._lastSkipMsg = nil
Grow._cachedPlantJob = nil
Grow._plantQueueDirty = true
Grow._queueSnapGen = -1
Grow._seedCommitted = Grow._seedCommitted or {}
Grow._wavePlantedBySeed = Grow._wavePlantedBySeed or {}
Grow._lastPlantedSeedUid = 0
Grow._fillBlocked = false
Grow._plantWaitTicks = 0
Grow._jobProbed = false
Grow._lastChatHarvestWakeAt = 0
Grow._commitForceCleared = false
Grow._harvestOpLockUntil = 0
Grow._lastPreparedHarvestPlot = 0
Grow._harvestActionBound = false
Grow.PENDING_TTL_SEC = 10
Grow.CHAT_HARVEST_WAKE_DEBOUNCE_SEC = 1.5
Grow.HARVEST_OP_LOCK_SEC = 1.5

local HARVEST_WIN = "StockPiler2WindowHarvest"
local HARVEST_ACTION_WIN = "StockPiler2WindowHarvestAction"
local CULTIVATION_HARVEST_WIN = "CultivationWindowHarvest"

local function RestoreHarvestChrome(windowName)
    if windowName == nil or windowName == "" or not DoesWindowExist(windowName) then
        return
    end
    if ButtonSetText then
        ButtonSetText(windowName, L"Harvest")
    end
end

-- Prefer underfilled recipe roles when craftsShort ties (lower = higher priority).
local ROLE_PICK_ORDER = {
    main = 1,
    stabilizer = 2,
    goldweed = 2,
    extender = 3,
    multiplier = 4,
    stimulant = 4,
    container = 5,
    ingredient = 6,
}

local function ToNarrow(value)
    if StockPiler2.ToNarrow then
        return StockPiler2.ToNarrow(value)
    end
    return tostring(value or "")
end

local function LogGrow(msg)
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("grow", msg)
    end
end

local function LogPlant(msg)
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("plant", msg)
    end
end

local function LogOnce(key, msg)
    if Grow._lastSkipMsg ~= key then
        Grow._lastSkipMsg = key
        LogGrow(msg)
    end
end

function Grow.StageEmpty()
    if GameData and GameData.CultivationStage and GameData.CultivationStage.EMPTY ~= nil then
        return GameData.CultivationStage.EMPTY
    end
    return 0
end

function Grow.NormalizeStage(stage)
    return tonumber(stage) or 0
end

function Grow.IsEnabled()
    return StockPiler2.Watch and StockPiler2.Watch.IsAutoGrowEnabled() == true
end

function Grow.AnyGrowDemand()
    local RS = StockPiler2.RecipeSpec
    local watches = StockPiler2.Watch and StockPiler2.Watch.GetWatches() or {}
    if type(RS) ~= "table" or type(watches) ~= "table" then
        return false
    end
    for watchKey, watch in pairs(watches) do
        if RS.ShouldAutoGrowPotion and RS.ShouldAutoGrowPotion(watchKey, watch) then
            return true
        end
    end
    return false
end

function Grow.CachedPlot(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return nil
    end
    local Garden = StockPiler2.Garden
    if Garden and type(Garden._plots) == "table" then
        local row = Garden._plots[plotNum]
        if type(row) == "table" then
            return row
        end
    end
    local CA = StockPiler2.CultivatorAdapter
    if CA and CA.ReadPlot then
        return CA.ReadPlot(plotNum)
    end
    return nil
end

function Grow.HasEmptyPlot()
    local CA = StockPiler2.CultivatorAdapter
    if not CA or not CA.NumPlots then
        return false
    end
    local n = CA.NumPlots()
    for plotNum = 1, n do
        if Grow.IsPlotEmpty(plotNum) then
            return true
        end
    end
    return false
end

function Grow.IsPlotEmpty(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return false
    end
    if (tonumber(Grow._pendingPlant[plotNum]) or 0) > 0 then
        return false
    end
    local plot = Grow.CachedPlot(plotNum)
    if type(plot) ~= "table" then
        return false
    end
    return Grow.NormalizeStage(plot.stage) == Grow.StageEmpty()
end

function Grow.FindNextEmptyPlot()
    local CA = StockPiler2.CultivatorAdapter
    if not CA then
        return 0
    end
    local n = CA.NumPlots()
    if n <= 0 then
        return 0
    end
    local start = tonumber(Grow._fillCursor) or 1
    if start < 1 or start > n then
        start = 1
    end
    for i = 0, n - 1 do
        local plotNum = ((start - 1 + i) % n) + 1
        if Grow.IsPlotEmpty(plotNum) then
            Grow._fillCursor = (plotNum % n) + 1
            return plotNum
        end
    end
    return 0
end

--- Seeds available to drop into empty plots while restocking (v1 ComputeSeedPlantable).
--- Buffer is for harvest/surplus reserve, not a hard gate when material deficit exists.
local function ComputePlantable(seedHave, plotsNeeded)
    seedHave = tonumber(seedHave) or 0
    plotsNeeded = tonumber(plotsNeeded) or 0
    if seedHave <= 0 or plotsNeeded <= 0 then
        return 0
    end
    if seedHave >= plotsNeeded then
        return plotsNeeded
    end
    return seedHave
end

local function SpecRole(spec)
    if type(spec) ~= "table" then
        return ""
    end
    return tostring(spec.role or "")
end

local function RolePickRank(role)
    return ROLE_PICK_ORDER[tostring(role or "")] or 99
end

--- Count plots already growing or planted this wave for a seedUid (fairness).
local function CountPlotsForSeedUid(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    local n = tonumber(Grow._wavePlantedBySeed[seedUid]) or 0
    local CA = StockPiler2.CultivatorAdapter
    local plots = CA and CA.NumPlots and CA.NumPlots() or 4
    for plotNum = 1, plots do
        -- Pending plots are already in _wavePlantedBySeed; only count established.
        if (tonumber(Grow._pendingPlant[plotNum]) or 0) <= 0 then
            local plot = Grow.CachedPlot(plotNum)
            if type(plot) == "table"
                and Grow.NormalizeStage(plot.stage) ~= Grow.StageEmpty()
                and (tonumber(plot.seedUid) or 0) == seedUid
            then
                n = n + 1
            end
        end
    end
    return n
end

local function SeedHaveForLine(line, SM, Inv)
    local seed = line.seed
    local seedUid = tonumber(line.seedUid) or 0
    local seedHave = 0
    if type(seed) == "table" then
        seedHave = tonumber(seed.count) or 0
    end
    if SM and SM.CountSeedsInBagsForSpec and type(line.spec) == "table" then
        local variantCount = SM.CountSeedsInBagsForSpec(line.spec)
        if variantCount > seedHave then
            seedHave = variantCount
        end
    elseif Inv and Inv.CountByUid and Inv._ready == true and seedUid > 0 then
        local bagCount = Inv.CountByUid(seedUid)
        if bagCount > seedHave then
            seedHave = bagCount
        end
    elseif Inv and Inv.UniqueIdCount and seedUid > 0 then
        local bagCount = Inv.UniqueIdCount(seedUid)
        if bagCount > seedHave then
            seedHave = bagCount
        end
    end
    return seedHave, seedUid
end

local function CanUseSeedUid(seedUid, Inv)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    if Inv and Inv.CanUseUniqueId and not Inv.CanUseUniqueId(seedUid) then
        return false
    end
    return true
end

local function AnyBufferRefinePending(lines)
    local Refine = StockPiler2.Refine
    if type(Refine) ~= "table" or not Refine.GetSeedBudgetForSpec then
        return false
    end
    for i = 1, #lines do
        local line = lines[i]
        local budget = Refine.GetSeedBudgetForSpec(line.spec, line.seedUid)
        local refinable = Refine.CountRefinablePlants
            and Refine.CountRefinablePlants(line.plantUid, line.spec) or 0
        if (tonumber(budget and budget.headroom) or 0) > 0 and refinable > 0 then
            return true
        end
    end
    return false
end

--- True when Seed Buffer is on and at least one watched line can refine for buffer.
function Grow.HasPendingBufferRefine()
    if not (StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true)
    then
        return false
    end
    local RS = StockPiler2.RecipeSpec
    if not (RS and RS.CollectAutoGrowSeedLines) then
        return false
    end
    return AnyBufferRefinePending(RS.CollectAutoGrowSeedLines())
end

local function PickBufferGrowCandidate(lines, SM, Inv)
    local Refine = StockPiler2.Refine
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    local best = nil
    local bestWant = -1
    for i = 1, #lines do
        local line = lines[i]
        local seedHave, seedUid = SeedHaveForLine(line, SM, Inv)
        if seedUid > 0 and CanUseSeedUid(seedUid, Inv) then
            local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
            local avail = seedHave - committed
            local live = seedHave
            local outstanding = 0
            if Refine and Refine.GetSeedBudgetForSpec then
                local budget = Refine.GetSeedBudgetForSpec(line.spec, seedUid)
                live = tonumber(budget and budget.live) or live
                outstanding = tonumber(budget and budget.outstanding) or 0
            end
            local credit = live + outstanding
            if avail > 0 and credit < buffer then
                local refinable = Refine and Refine.CountRefinablePlants
                    and Refine.CountRefinablePlants(line.plantUid, line.spec) or 0
                -- Never buffer-grow while refinable plants remain (burns buffer).
                if refinable <= 0 then
                    local want = buffer - credit
                    if want > bestWant then
                        bestWant = want
                        local seed = line.seed
                        if type(seed) ~= "table" then
                            seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(line.spec) or {
                                uniqueID = seedUid,
                                name = L"seed",
                                nameNarrow = "seed",
                            }
                        end
                        best = {
                            spec = line.spec,
                            specKey = line.specKey,
                            seed = seed,
                            seedUid = seedUid,
                            plantUid = tonumber(line.plantUid) or 0,
                            seedHave = seedHave,
                            plantable = math.min(avail, want),
                            deficit = want,
                            craftsShort = want,
                            role = SpecRole(line.spec),
                            plantReason = "seed_buffer",
                        }
                    end
                end
            end
        end
    end
    return best
end

local function PickSurplusCandidate(lines, SM, Inv)
    if AnyBufferRefinePending(lines) then
        return nil
    end
    local Refine = StockPiler2.Refine
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    local best = nil
    local bestSurplus = -1
    for i = 1, #lines do
        local line = lines[i]
        local seedHave, seedUid = SeedHaveForLine(line, SM, Inv)
        if seedUid > 0 and CanUseSeedUid(seedUid, Inv) then
            local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
            local live = seedHave
            if Refine and Refine.GetSeedBudgetForSpec then
                local budget = Refine.GetSeedBudgetForSpec(line.spec, seedUid)
                live = tonumber(budget and budget.live) or live
                if (tonumber(budget and budget.headroom) or 0) > 0 then
                    live = -1 -- skip: still short / outstanding refill
                end
            end
            if live >= 0 then
                local surplus = live - buffer - committed
                if surplus > bestSurplus and surplus > 0 then
                    bestSurplus = surplus
                    local seed = line.seed
                    if type(seed) ~= "table" then
                        seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(line.spec) or {
                            uniqueID = seedUid,
                            name = L"seed",
                            nameNarrow = "seed",
                        }
                    end
                    best = {
                        spec = line.spec,
                        specKey = line.specKey,
                        seed = seed,
                        seedUid = seedUid,
                        plantUid = tonumber(line.plantUid) or 0,
                        seedHave = seedHave,
                        plantable = surplus,
                        deficit = surplus,
                        craftsShort = surplus,
                        role = SpecRole(line.spec),
                        plantReason = "surplus",
                    }
                end
            end
        end
    end
    return best
end

function Grow.PickPlantCandidate()
    local RS = StockPiler2.RecipeSpec
    local SM = StockPiler2.SeedMap
    local Inv = StockPiler2.Inventory
    if type(RS) ~= "table" or not RS.BuildBalancedSpecDemand then
        return nil
    end
    if type(SM) ~= "table" or not SM.IsGrowableSpec or not SM.ResolveSeedForSpec then
        return nil
    end
    local demand = RS.BuildBalancedSpecDemand()
    local best = nil
    local bestCrafts = -1
    local bestPlotCount = 999
    local bestRoleRank = 99
    for _, row in pairs(demand) do
        if type(row) == "table" then
            local deficit = tonumber(row.deficit) or 0
            local craftsShort = tonumber(row.craftsShort)
            if craftsShort == nil then
                craftsShort = deficit
            end
            local spec = row.spec
            if deficit > 0 and craftsShort > 0 and type(spec) == "table" and SM.IsGrowableSpec(spec) then
                local seed = SM.ResolveSeedForSpec(spec)
                if type(seed) == "table" then
                    local seedUid = tonumber(seed.uniqueID) or 0
                    if seedUid > 0 and Inv and Inv.CanUseUniqueId
                        and not Inv.CanUseUniqueId(seedUid)
                    then
                        LogOnce("skill-" .. tostring(seedUid), "plant skip skill seedUid=" .. tostring(seedUid))
                    else
                        if seedUid <= 0 and type(seed.itemData) == "table" then
                            seedUid = tonumber(seed.itemData.uniqueID) or 0
                        end
                        local seedHave = tonumber(seed.count) or 0
                        if SM and SM.CountSeedsInBagsForSpec then
                            local variantCount = SM.CountSeedsInBagsForSpec(spec)
                            if variantCount > seedHave then
                                seedHave = variantCount
                            end
                        elseif Inv and Inv.CountByUid and Inv._ready == true and seedUid > 0 then
                            local bagCount = Inv.CountByUid(seedUid)
                            if bagCount > seedHave then
                                seedHave = bagCount
                            end
                        elseif Inv and Inv.UniqueIdCount and seedUid > 0 then
                            local bagCount = Inv.UniqueIdCount(seedUid)
                            if bagCount > seedHave then
                                seedHave = bagCount
                            end
                        end
                        local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
                        local avail = seedHave - committed
                        local plantable = ComputePlantable(avail, deficit)
                        if plantable > 0 then
                            local role = SpecRole(spec)
                            local plotCount = CountPlotsForSeedUid(seedUid)
                            local roleRank = RolePickRank(role)
                            local better = false
                            if craftsShort > bestCrafts then
                                better = true
                            elseif craftsShort == bestCrafts then
                                if plotCount < bestPlotCount then
                                    better = true
                                elseif plotCount == bestPlotCount and roleRank < bestRoleRank then
                                    better = true
                                elseif plotCount == bestPlotCount and roleRank == bestRoleRank
                                    and seedUid ~= (tonumber(Grow._lastPlantedSeedUid) or 0)
                                    and best ~= nil
                                    and (tonumber(best.seedUid) or 0) == (tonumber(Grow._lastPlantedSeedUid) or 0)
                                then
                                    better = true
                                end
                            end
                            if better then
                                bestCrafts = craftsShort
                                bestPlotCount = plotCount
                                bestRoleRank = roleRank
                                best = {
                                    spec = spec,
                                    specKey = row.specKey,
                                    seed = seed,
                                    seedUid = seedUid,
                                    plantUid = tonumber(seed.plantUid) or 0,
                                    seedHave = seedHave,
                                    plantable = plantable,
                                    deficit = deficit,
                                    craftsShort = craftsShort,
                                    role = role,
                                    plantReason = "potion_stock",
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    if best ~= nil then
        return best
    end
    if not (StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true)
    then
        return nil
    end
    if not RS.CollectAutoGrowSeedLines then
        return nil
    end
    local lines = RS.CollectAutoGrowSeedLines()
    best = PickBufferGrowCandidate(lines, SM, Inv)
    if best ~= nil then
        return best
    end
    return PickSurplusCandidate(lines, SM, Inv)
end

function Grow.ClearPendingPlot(plotNum, opts)
    plotNum = tonumber(plotNum) or 0
    opts = type(opts) == "table" and opts or {}
    if plotNum <= 0 then
        return
    end
    if opts.rollbackCommit == true then
        local seedUid = tonumber(Grow._pendingSeedUid[plotNum]) or 0
        if seedUid > 0 then
            local n = (tonumber(Grow._seedCommitted[seedUid]) or 0) - 1
            if n <= 0 then
                Grow._seedCommitted[seedUid] = nil
            else
                Grow._seedCommitted[seedUid] = n
            end
            local w = (tonumber(Grow._wavePlantedBySeed[seedUid]) or 0) - 1
            if w <= 0 then
                Grow._wavePlantedBySeed[seedUid] = nil
            else
                Grow._wavePlantedBySeed[seedUid] = w
            end
        end
    end
    Grow._pendingPlant[plotNum] = 0
    Grow._pendingPlantAt[plotNum] = nil
    Grow._pendingSeedUid[plotNum] = nil
end

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function ApplyPendingClearForPlot(plotNum, plot)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(plot) ~= "table" then
        return
    end
    if (tonumber(Grow._pendingPlant[plotNum]) or 0) <= 0 then
        return
    end
    if Grow.NormalizeStage(plot.stage) ~= Grow.StageEmpty() then
        -- Plant confirmed in soil — drop pending without rolling back commit.
        Grow.ClearPendingPlot(plotNum)
        return
    end
    -- Empty while pending: harvest/fail. Grace so post-plant empty frames don't clear.
    local at = tonumber(Grow._pendingPlantAt[plotNum]) or 0
    local now = NowSec()
    if at > 0 and (now - at) >= 1.0 then
        Grow.ClearPendingPlot(plotNum, { rollbackCommit = true })
        Grow._plantQueueDirty = true
        Grow._cachedPlantJob = nil
        Grow._jobProbed = false
    end
end

--- Clear pending on empty (after grace) or non-empty (plant confirmed).
--- plotNum<=0: walk all garden plots (SyncAll path).
function Grow.OnCultivationUpdated(plotNum)
    plotNum = tonumber(plotNum) or 0
    local function HandleOne(pn, row)
        ApplyPendingClearForPlot(pn, row)
        Grow.ClearPendingAdditiveIfFilled(pn, row)
    end
    if plotNum > 0 then
        HandleOne(plotNum, Grow.CachedPlot(plotNum))
        Grow.MarkAdditiveDue()
        if Grow._liveHarvestTip and Grow._liveHarvestTip.kind == "harvest" then
            Grow.SyncHarvestTipPlotsFromEngine()
            Grow.MaybeRefreshHarvestTooltip(true)
        end
        return
    end
    local Garden = StockPiler2.Garden
    local plots = Garden and Garden.GetPlotsCopy and Garden.GetPlotsCopy() or nil
    if type(plots) ~= "table" then
        for pn, _ in pairs(Grow._pendingPlant) do
            HandleOne(pn, Grow.CachedPlot(pn))
        end
        for pn, _ in pairs(Grow._pendingAdditive) do
            Grow.ClearPendingAdditiveIfFilled(pn, Grow.CachedPlot(pn))
        end
        Grow.MarkAdditiveDue()
        if Grow._liveHarvestTip and Grow._liveHarvestTip.kind == "harvest" then
            Grow.SyncHarvestTipPlotsFromEngine()
            Grow.MaybeRefreshHarvestTooltip(true)
        end
        return
    end
    for pn, row in pairs(plots) do
        HandleOne(pn, row)
    end
    Grow.MarkAdditiveDue()
    if Grow._liveHarvestTip and Grow._liveHarvestTip.kind == "harvest" then
        Grow.SyncHarvestTipPlotsFromEngine()
        Grow.MaybeRefreshHarvestTooltip(true)
    end
end

--- Expire pending on empty plots after PENDING_TTL_SEC (missed cultivation events).
function Grow.ExpireStalePending()
    local now = NowSec()
    local ttl = tonumber(Grow.PENDING_TTL_SEC) or 10
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    for plotNum = 1, n do
        local pending = tonumber(Grow._pendingPlant[plotNum]) or 0
        if pending > 0 then
            local plot = Grow.CachedPlot(plotNum)
            local empty = type(plot) == "table"
                and Grow.NormalizeStage(plot.stage) == Grow.StageEmpty()
            local at = tonumber(Grow._pendingPlantAt[plotNum]) or 0
            if empty and at > 0 and (now - at) >= ttl then
                LogGrow("pending TTL clear P" .. tostring(plotNum))
                Grow.ClearPendingPlot(plotNum, { rollbackCommit = true })
                Grow._plantQueueDirty = true
                Grow._cachedPlantJob = nil
                Grow._jobProbed = false
            elseif empty and at <= 0 then
                Grow._pendingPlantAt[plotNum] = now
            end
        end
    end
end

--- Soft in-wave call: keep plant-job cache; only force busts caches.
--- opts.force=true — demand/plan/job rebuild (harvest, demand change, wave end).
--- opts.jobOnly=true — dirty plant job only (seeds arrived from refine).
function Grow.InvalidatePlantQueue(opts)
    opts = type(opts) == "table" and opts or {}
    Grow._lastSkipMsg = nil
    if opts.force == true then
        Grow._plantQueueDirty = true
        Grow._cachedPlantJob = nil
        Grow._jobProbed = false
        Grow._seedCommitted = {}
        Grow._wavePlantedBySeed = {}
        Grow._pendingPlant = {}
        Grow._pendingPlantAt = {}
        Grow._pendingSeedUid = {}
        Grow._pendingAdditive = {}
        Grow._pendingAdditiveAt = {}
        Grow._additiveDirty = false
        Grow._fillBlocked = false
        Grow._plantWaitTicks = 0
        if opts.keepCommitForceCleared ~= true then
            Grow._commitForceCleared = false
        end
        if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.ClearCountCaches then
            StockPiler2.RecipeSpec.ClearCountCaches()
        end
        if StockPiler2.Planner and StockPiler2.Planner.InvalidatePlanCache then
            StockPiler2.Planner.InvalidatePlanCache()
        end
        return
    end
    if opts.jobOnly == true then
        Grow._plantQueueDirty = true
        Grow._cachedPlantJob = nil
        Grow._jobProbed = false
        Grow._fillBlocked = false
        Grow._plantWaitTicks = 0
        return
    end
    -- In-wave soft invalidate: leave job cache + seedCommitted intact.
end

function Grow.MarkPlantJobDirty()
    Grow.InvalidatePlantQueue({ jobOnly = true })
end

function Grow.SetFillBlocked(blocked, waitTicks)
    Grow._fillBlocked = blocked == true
    if Grow._fillBlocked then
        Grow._plantWaitTicks = tonumber(waitTicks) or 5
        if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
            StockPiler2.Scheduler.SetAutoGrowIdle(true)
        end
    else
        Grow._plantWaitTicks = 0
        Grow._jobProbed = false
        Grow._plantQueueDirty = true
        Grow._cachedPlantJob = nil
    end
end

function Grow.ClearFillBlocked()
    if Grow._fillBlocked == true or (tonumber(Grow._plantWaitTicks) or 0) > 0 then
        Grow._fillBlocked = false
        Grow._plantWaitTicks = 0
        Grow._jobProbed = false
        Grow._plantQueueDirty = true
        Grow._cachedPlantJob = nil
    end
end

function Grow.DecayPlantWaitTicks()
    local wait = tonumber(Grow._plantWaitTicks) or 0
    if wait > 0 then
        Grow._plantWaitTicks = wait - 1
        if Grow._plantWaitTicks <= 0 then
            Grow._fillBlocked = false
            Grow._jobProbed = false
            Grow._plantQueueDirty = true
            Grow._cachedPlantJob = nil
        end
    end
end

function Grow.IsFillBlocked()
    if Grow._fillBlocked == true then
        return true
    end
    return (tonumber(Grow._plantWaitTicks) or 0) > 0
end

local function AdjustJobForCommitted(job)
    if type(job) ~= "table" then
        return nil
    end
    local seedUid = tonumber(job.seedUid) or 0
    local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
    local seedHave = (tonumber(job.seedHave) or 0) - committed
    if seedHave <= 0 then
        return nil
    end
    local deficit = tonumber(job.deficit) or 0
    return {
        spec = job.spec,
        specKey = job.specKey,
        seed = job.seed,
        seedUid = seedUid,
        plantUid = tonumber(job.plantUid) or 0,
        seedHave = seedHave,
        plantable = ComputePlantable(seedHave, deficit),
        deficit = deficit,
        craftsShort = tonumber(job.craftsShort) or deficit,
        role = job.role,
        plantReason = job.plantReason,
    }
end

--- Cheap seed check: warm cache only — never rebuilds demand.
function Grow.PeekSeedsForNextPlant()
    if Grow._plantQueueDirty == true then
        return false, "dirty"
    end
    if type(Grow._cachedPlantJob) ~= "table" then
        if Grow._jobProbed == true then
            return false, "none"
        end
        return false, "unprobed"
    end
    local adjusted = AdjustJobForCommitted(Grow._cachedPlantJob)
    if adjusted == nil then
        return false, "exhausted"
    end
    return true, adjusted
end

function Grow.HasSeedsForNextPlant()
    local ok = Grow.PeekSeedsForNextPlant()
    if ok == true then
        return true
    end
    -- Only rebuild when dirty/unprobed and not fill-blocked.
    if Grow.IsFillBlocked() then
        return false
    end
    local job = Grow.GetPlantJob()
    return type(job) == "table" and (tonumber(job.seedHave) or 0) > 0
end

function Grow.GetPlantJob()
    if Grow._plantQueueDirty ~= true then
        if type(Grow._cachedPlantJob) == "table" then
            local adjusted = AdjustJobForCommitted(Grow._cachedPlantJob)
            if adjusted ~= nil then
                return adjusted
            end
            -- Committed seeds exhausted: re-pick another role/seed if plots still empty.
            if Grow.HasEmptyPlot() and not Grow.IsFillBlocked() then
                Grow._plantQueueDirty = true
                Grow._jobProbed = false
            else
                Grow._jobProbed = true
                return nil
            end
        elseif Grow._jobProbed == true then
            -- Stay nil until explicitly dirtied (unblock / harvest / refine / demand).
            return nil
        end
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.BagWorkPending
        and StockPiler2.Scheduler.BagWorkPending() == true
        and type(Grow._cachedPlantJob) == "table"
        and Grow._plantQueueDirty ~= true
    then
        return AdjustJobForCommitted(Grow._cachedPlantJob)
    end
    local job = Grow.PickPlantCandidate()
    Grow._cachedPlantJob = job
    Grow._plantQueueDirty = false
    Grow._jobProbed = true
    local Inv = StockPiler2.Inventory
    Grow._queueSnapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    return AdjustJobForCommitted(job)
end

function Grow.OnFillWaveComplete()
    Grow.InvalidatePlantQueue({ force = true })
    if StockPiler2.Refine and StockPiler2.Refine.ClearPostHarvestState then
        StockPiler2.Refine.ClearPostHarvestState()
    end
end

function Grow.OnDemandChanged()
    Grow.InvalidatePlantQueue({ force = true })
    Grow._lastSkipMsg = nil
    if not Grow.IsEnabled() then
        return
    end
    LogGrow("demand changed; ready to plant")
end

function Grow.StageGrown()
    if GameData and GameData.CultivationStage and GameData.CultivationStage.GROWN ~= nil then
        return GameData.CultivationStage.GROWN
    end
    return 4
end

function Grow.StageHarvesting()
    if GameData and GameData.CultivationStage and GameData.CultivationStage.HARVESTING ~= nil then
        return GameData.CultivationStage.HARVESTING
    end
    return 5
end

function Grow.IsPlotGrown(stageNum)
    return Grow.NormalizeStage(stageNum) == Grow.StageGrown()
end

function Grow.IsPlotHarvesting(stageNum)
    return Grow.NormalizeStage(stageNum) == Grow.StageHarvesting()
end

function Grow.GetReadyHarvestPlots()
    local ready = {}
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    for plotNum = 1, n do
        local plot = nil
        if CA and CA.ReadPlot then
            plot = CA.ReadPlot(plotNum)
        else
            plot = Grow.CachedPlot(plotNum)
        end
        if type(plot) == "table" and Grow.IsPlotGrown(plot.stage) then
            ready[#ready + 1] = plotNum
        end
    end
    table.sort(ready)
    return ready
end

function Grow.CountReadyHarvestPlots()
    return #Grow.GetReadyHarvestPlots()
end

function Grow.HasHarvestInProgress()
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    for plotNum = 1, n do
        local plot = nil
        if CA and CA.ReadPlot then
            plot = CA.ReadPlot(plotNum)
        else
            plot = Grow.CachedPlot(plotNum)
        end
        if type(plot) == "table" and Grow.IsPlotHarvesting(plot.stage) then
            return true
        end
    end
    return false
end

function Grow.ArmHarvestOpLock(seconds)
    seconds = tonumber(seconds) or Grow.HARVEST_OP_LOCK_SEC or 1.5
    if seconds < 0.5 then
        seconds = 0.5
    end
    local untilT = NowSec() + seconds
    local cur = tonumber(Grow._harvestOpLockUntil) or 0
    if untilT > cur then
        Grow._harvestOpLockUntil = untilT
    end
end

function Grow.IsHarvestOpActive()
    if Grow.HasHarvestInProgress() then
        return true
    end
    local now = NowSec()
    local lockUntil = tonumber(Grow._harvestOpLockUntil) or 0
    if lockUntil > 0 and now < lockUntil then
        return true
    end
    if lockUntil > 0 and now >= lockUntil then
        Grow._harvestOpLockUntil = 0
    end
    return false
end

local function BindCultivationHarvestAction(windowName)
    if WindowSetGameActionData == nil or windowName == nil or windowName == "" then
        return false
    end
    if not DoesWindowExist(windowName) then
        return false
    end
    local cult = GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION or 3
    local action = GameData and GameData.PlayerActions and GameData.PlayerActions.PERFORM_CRAFTING or 8
    local ok, err
    if StockPiler2.TryCall then
        ok, err = StockPiler2.TryCall("WindowSetGameActionData", WindowSetGameActionData, windowName, action, cult, L"")
    else
        ok, err = pcall(WindowSetGameActionData, windowName, action, cult, L"")
    end
    if ok ~= true then
        LogGrow("BindCultivationHarvestAction failed win=" .. tostring(windowName) .. " err=" .. tostring(err))
        return false
    end
    RestoreHarvestChrome(windowName)
    return true
end

function Grow.EnsureHarvestActionBound()
    -- Visible footer Harvest owns native gameactionbutton click (primary path).
    if BindCultivationHarvestAction(HARVEST_WIN) then
        Grow._harvestActionBound = true
        return true
    end
    if BindCultivationHarvestAction(HARVEST_ACTION_WIN) then
        Grow._harvestActionBound = true
        return true
    end
    if BindCultivationHarvestAction(CULTIVATION_HARVEST_WIN) then
        Grow._harvestActionBound = true
        return true
    end
    Grow._harvestActionBound = false
    return false
end

--- Disabled gameactionbutton still fires if bound — clear so no "plot not finished" craft.
function Grow.ClearHarvestActionBound()
    if WindowSetGameActionData == nil then
        Grow._harvestActionBound = false
        return false
    end
    local none = 0
    if GameData and GameData.PlayerActions and GameData.PlayerActions.NONE ~= nil then
        none = GameData.PlayerActions.NONE
    end
    local function clearWin(windowName)
        if not DoesWindowExist(windowName) then
            return false
        end
        local ok
        if StockPiler2.TryCall then
            ok = StockPiler2.TryCall("WindowSetGameActionData.clear", WindowSetGameActionData, windowName, none, 0, L"")
        else
            ok = pcall(WindowSetGameActionData, windowName, none, 0, L"")
        end
        RestoreHarvestChrome(windowName)
        return ok == true
    end
    local cleared = clearWin(HARVEST_WIN)
    clearWin(HARVEST_ACTION_WIN)
    Grow._harvestActionBound = false
    return cleared
end

--- Best-effort for orch/macros. Manual footer Harvest uses native gameactionbutton click.
--- WindowGameAction often pcall-succeeds without harvesting.
function Grow.FireHarvestAction()
    Grow.EnsureHarvestActionBound()
    if type(WindowGameAction) ~= "function" then
        LogGrow("FireHarvestAction no WindowGameAction")
        return false
    end
    local function tryWin(windowName, rebind)
        if windowName == nil or windowName == "" or not DoesWindowExist(windowName) then
            return false
        end
        if rebind == true then
            BindCultivationHarvestAction(windowName)
        end
        local child = windowName .. "Action"
        if DoesWindowExist(child) then
            local okChild, errChild
            if StockPiler2.TryCall then
                okChild, errChild = StockPiler2.TryCall("WindowGameAction", WindowGameAction, child)
            else
                okChild, errChild = pcall(WindowGameAction, child)
            end
            if okChild == true then
                LogGrow("FireHarvestAction ok win=" .. tostring(child))
                return true
            end
            LogGrow("FireHarvestAction fail win=" .. tostring(child) .. " err=" .. tostring(errChild))
        end
        local ok, err
        if StockPiler2.TryCall then
            ok, err = StockPiler2.TryCall("WindowGameAction", WindowGameAction, windowName)
        else
            ok, err = pcall(WindowGameAction, windowName)
        end
        if ok == true then
            LogGrow("FireHarvestAction ok win=" .. tostring(windowName))
            return true
        end
        LogGrow("FireHarvestAction fail win=" .. tostring(windowName) .. " err=" .. tostring(err))
        return false
    end
    if tryWin(HARVEST_WIN, true) then
        return true
    end
    if tryWin(HARVEST_ACTION_WIN, true) then
        return true
    end
    if tryWin(CULTIVATION_HARVEST_WIN, true) then
        return true
    end
    return false
end

function Grow.SelectHarvestPlot(manual)
    local ready = Grow.GetReadyHarvestPlots()
    if #ready == 0 then
        return false, 0, nil
    end
    table.sort(ready)

    local last = tonumber(Grow._lastPreparedHarvestPlot) or 0
    local skipLast = false
    if last > 0 then
        local CA = StockPiler2.CultivatorAdapter
        local lastPlot = CA and CA.ReadPlot and CA.ReadPlot(last) or Grow.CachedPlot(last)
        local stage = type(lastPlot) == "table" and Grow.NormalizeStage(lastPlot.stage) or -1
        local stillBusy = Grow.IsPlotGrown(stage) or Grow.IsPlotHarvesting(stage)
        local lockUntil = tonumber(Grow._harvestOpLockUntil) or 0
        local lockActive = lockUntil > 0 and NowSec() < lockUntil
        if stillBusy or lockActive then
            skipLast = true
        end
    end

    local CA = StockPiler2.CultivatorAdapter
    local pick = 0
    local plotData = nil
    for i = 1, #ready do
        local plotNum = ready[i]
        if not (skipLast and plotNum == last) then
            local live = CA and CA.ReadPlot and CA.ReadPlot(plotNum) or Grow.CachedPlot(plotNum)
            if type(live) == "table" and Grow.IsPlotGrown(live.stage) then
                pick = plotNum
                plotData = live
                break
            end
        end
    end
    -- Only the last-prepared plot remains ready: allow retry.
    if pick <= 0 and skipLast and last > 0 then
        for i = 1, #ready do
            if ready[i] == last then
                local live = CA and CA.ReadPlot and CA.ReadPlot(last) or Grow.CachedPlot(last)
                if type(live) == "table" and Grow.IsPlotGrown(live.stage) then
                    pick = last
                    plotData = live
                end
                break
            end
        end
    end
    if pick <= 0 or type(plotData) ~= "table" then
        return false, 0, nil
    end

    if GameData and GameData.Player and GameData.Player.Cultivation then
        GameData.Player.Cultivation.CurrentPlot = pick
    end
    local seedUid = tonumber(plotData.seedUid) or 0
    if StockPiler2.SeedMap and StockPiler2.SeedMap.BeginPendingHarvest then
        StockPiler2.SeedMap.BeginPendingHarvest(pick, {
            Seed = { uniqueID = seedUid },
        })
    end
    Grow._lastPreparedHarvestPlot = pick
    return true, pick, plotData
end

--- Prepare CurrentPlot + harvest watch; game-action button performs the craft.
function Grow.PrepareHarvestPlot(manual)
    if StockPiler2.Brew and StockPiler2.Brew.BlocksHarvest
        and StockPiler2.Brew.BlocksHarvest() == true
    then
        return false
    end
    Grow.EnsureHarvestActionBound()
    local ok, plotNum = Grow.SelectHarvestPlot(manual == true)
    if ok ~= true then
        return false
    end
    Grow.ArmHarvestOpLock(Grow.HARVEST_OP_LOCK_SEC)
    LogGrow(string.format(
        "harvest prepare P%d manual=%s ready=%d",
        tonumber(plotNum) or 0,
        tostring(manual == true),
        Grow.CountReadyHarvestPlots()
    ))
    return true
end

--- After a plot becomes empty (cultivation or CraftChat harvest): clear block, rebuild job, wake.
--- Marks refine due only when no plantable seed job exists (need buffer refill).
--- CraftChat often fires WakeAfterHarvest(0) repeatedly; debounce those during a fill wave.
function Grow.WakeAfterHarvest(plotNum)
    plotNum = tonumber(plotNum) or 0
    local now = NowSec()
    if plotNum <= 0 then
        local debounce = tonumber(Grow.CHAT_HARVEST_WAKE_DEBOUNCE_SEC) or 1.5
        local last = tonumber(Grow._lastChatHarvestWakeAt) or 0
        if last > 0 and now > 0 and (now - last) < debounce then
            Grow.ClearFillBlocked()
            if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
                StockPiler2.Scheduler.WakeAutoGrow()
            end
            return Grow.HasSeedsForNextPlant and Grow.HasSeedsForNextPlant() == true
        end
        Grow._lastChatHarvestWakeAt = now
    end
    Grow.ClearFillBlocked()
    Grow.InvalidatePlantQueue({ force = true })
    local plantable = false
    if Grow.HasSeedsForNextPlant then
        plantable = Grow.HasSeedsForNextPlant() == true
    end
    if not plantable and StockPiler2.Refine and StockPiler2.Refine.MarkRefineDue then
        StockPiler2.Refine.MarkRefineDue("harvest")
    elseif plantable and StockPiler2.Refine and StockPiler2.Refine.ClearPostHarvestState then
        StockPiler2.Refine.ClearPostHarvestState()
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
        StockPiler2.Scheduler.WakeAutoGrow()
    end
    LogOnce(
        "harvest-wake-" .. tostring(plotNum),
        string.format("harvest-wake P%s plantable=%s", tostring(plotNum > 0 and plotNum or "?"), tostring(plantable))
    )
    return plantable
end

function Grow.LogSkipPlant(reason)
    LogOnce("skip-" .. tostring(reason or "?"), "skip plant reason=" .. tostring(reason or "?"))
end

function Grow.TryPlantNextEmptyPlot(opId)
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsBrewSessionActive
        and StockPiler2.Orchestrator.IsBrewSessionActive() == true
    then
        return false
    end
    if not Grow.IsEnabled() then
        return false
    end
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("Grow.TryPlant")
    end
    if not Grow.AnyGrowDemand() then
        LogOnce("no-demand", "plant skip no auto-grow demand")
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Grow.TryPlant")
        end
        return false
    end
    if AddCraftingItem == nil then
        LogOnce("no-api", "plant skip AddCraftingItem missing")
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Grow.TryPlant")
        end
        return false
    end
    local plotNum = Grow.FindNextEmptyPlot()
    if plotNum <= 0 then
        LogOnce("no-empty", "plant skip no empty plots")
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Grow.TryPlant")
        end
        return false
    end
    local CA = StockPiler2.CultivatorAdapter
    if not CA or not CA.FindSeedSlot or not CA.PlantSeed then
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Grow.TryPlant")
        end
        return false
    end
    -- Live soil check: cache can lag mid-harvest; never pending/commit a non-empty plot.
    if CA.ReadPlot then
        local live = CA.ReadPlot(plotNum)
        if type(live) == "table" and Grow.NormalizeStage(live.stage) ~= Grow.StageEmpty() then
            LogOnce("not-empty-live", "plant skip P" .. tostring(plotNum) .. " live not empty")
            if StockPiler2.Perf and StockPiler2.Perf.End then
                StockPiler2.Perf.End("Grow.TryPlant")
            end
            return false
        end
    end
    local job = Grow.GetPlantJob()
    if job == nil and Grow.HasEmptyPlot() and Grow._commitForceCleared ~= true then
        LogGrow("empty+nil job; force clear inflated seed commits")
        Grow.InvalidatePlantQueue({ force = true, keepCommitForceCleared = true })
        Grow._commitForceCleared = true
        job = Grow.GetPlantJob()
    end
    if job == nil then
        if Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() then
            LogOnce("no-job-buffer-refine", "plant skip; seed-buffer refine pending")
            if StockPiler2.Refine and StockPiler2.Refine.MarkRefineDue then
                StockPiler2.Refine.MarkRefineDue("seed-buffer")
            end
            if Grow.SetFillBlocked then
                Grow.SetFillBlocked(false)
            end
        else
            LogOnce("no-job", "plant skip no plantable grow job (deficit/seeds/buffer)")
            Grow.SetFillBlocked(true, 5)
        end
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Grow.TryPlant")
        end
        return false
    end
    local seedKey = job.seed.nameNarrow or ToNarrow(job.seed.name) or ToNarrow(job.seed.match)
    local slot, item, backpackType = CA.FindSeedSlot(job.seedUid, seedKey)
    if slot <= 0 or type(item) ~= "table" then
        if Grow.HasEmptyPlot() and Grow._commitForceCleared ~= true then
            LogGrow("empty+no seed slot; force clear inflated seed commits")
            Grow.InvalidatePlantQueue({ force = true, keepCommitForceCleared = true })
            Grow._commitForceCleared = true
            job = Grow.GetPlantJob()
            if type(job) == "table" then
                seedKey = job.seed.nameNarrow or ToNarrow(job.seed.name) or ToNarrow(job.seed.match)
                slot, item, backpackType = CA.FindSeedSlot(job.seedUid, seedKey)
            end
        end
    end
    if slot <= 0 or type(item) ~= "table" then
        LogGrow(string.format(
            "plant skip no seed slot uid=%d key=%s have=%d buffer=%d",
            tonumber(job and job.seedUid) or 0,
            tostring(seedKey),
            tonumber(job and job.seedHave) or 0,
            StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
        ))
        Grow.SetFillBlocked(true, 5)
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Grow.TryPlant")
        end
        return false
    end
    local seedUid = tonumber(item.uniqueID) or job.seedUid
    if GameData and GameData.Player and GameData.Player.Cultivation then
        GameData.Player.Cultivation.CurrentPlot = plotNum
    end
    Grow._pendingPlant[plotNum] = (tonumber(Grow._pendingPlant[plotNum]) or 0) + 1
    Grow._pendingPlantAt[plotNum] = NowSec()
    Grow._pendingSeedUid[plotNum] = seedUid
    if StockPiler2.Scheduler and StockPiler2.Scheduler.SuppressInventorySideEffects then
        StockPiler2.Scheduler.SuppressInventorySideEffects(2)
    end
    local ok, err = CA.PlantSeed(plotNum, slot, backpackType)
    if ok ~= true then
        Grow.ClearPendingPlot(plotNum)
        LogGrow("plant failed P" .. tostring(plotNum) .. " err=" .. tostring(err))
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Grow.TryPlant")
        end
        return false
    end
    Grow._lastSkipMsg = nil
    Grow._commitForceCleared = false
    -- Persist seed/spore on plant so one-way harvest lines are known before harvest.
    if type(item) == "table" and StockPiler2.SeedMap then
        local plantUid = tonumber(job.plantUid) or 0
        if StockPiler2.SeedMap.RegisterFromItem then
            StockPiler2.SeedMap.RegisterFromItem(item, plantUid > 0 and plantUid or nil)
        elseif StockPiler2.Items and StockPiler2.Items.UpsertFromItemData then
            local cultType = tonumber(item.cultivationType) or 0
            local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
            local kind = (cultType == sporeType) and "spore" or "seed"
            StockPiler2.Items.UpsertFromItemData(item, kind)
        end
        if plantUid > 0 and seedUid > 0 and StockPiler2.SeedMap.LearnMapping then
            -- Job already knows plantUid; trust so one-way pairs learn on AutoGrow plant.
            StockPiler2.SeedMap.LearnMapping(plantUid, seedUid, "plant", true)
        end
    end
    LogPlant(string.format(
        "P%d %s uid=%d plantUid=%d reason=%s deficit=%d craftsShort=%d plantable=%d opId=%s",
        plotNum,
        seedKey ~= "" and seedKey or "?",
        seedUid,
        tonumber(job.plantUid) or 0,
        tostring(job.plantReason or "potion_stock"),
        tonumber(job.deficit) or 0,
        tonumber(job.craftsShort) or 0,
        tonumber(job.plantable) or 0,
        tostring(opId or "?")
    ))
    Grow._seedCommitted[seedUid] = (tonumber(Grow._seedCommitted[seedUid]) or 0) + 1
    Grow._wavePlantedBySeed[seedUid] = (tonumber(Grow._wavePlantedBySeed[seedUid]) or 0) + 1
    Grow._lastPlantedSeedUid = seedUid
    if StockPiler2.Refine and StockPiler2.Refine.ClearPostHarvestState then
        StockPiler2.Refine.ClearPostHarvestState()
    end
    if StockPiler2.Garden and StockPiler2.Garden.OnCultivationUpdated then
        StockPiler2.Garden.OnCultivationUpdated()
    end
    -- Re-pick next plot for craftsShort / role fairness; keep seedCommitted.
    Grow._plantQueueDirty = true
    Grow._cachedPlantJob = nil
    Grow._jobProbed = false
    if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
        StockPiler2.Scheduler.WakeAutoGrow()
    end
    Grow.MarkAdditiveDue()
    if not Grow.HasEmptyPlot() then
        Grow.OnFillWaveComplete()
    end
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("Grow.TryPlant")
    end
    return true
end

function Grow.MarkAdditiveDue()
    Grow._additiveDirty = true
end

function Grow.ClearPendingAdditive(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return
    end
    Grow._pendingAdditive[plotNum] = 0
    Grow._pendingAdditiveAt[plotNum] = nil
end

function Grow.ClearPendingAdditiveIfFilled(plotNum, row)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or (tonumber(Grow._pendingAdditive[plotNum]) or 0) <= 0 then
        return
    end
    local AD = StockPiler2.Additives
    if not AD or not AD.CultTypeForStage or not AD.PlotHasAdditive then
        return
    end
    local stage = Grow.NormalizeStage(type(row) == "table" and row.stage or 0)
    local cultType = AD.CultTypeForStage(stage)
    if cultType and AD.PlotHasAdditive(row, cultType) then
        Grow.ClearPendingAdditive(plotNum)
    end
end

--- True when a growing plot is missing the additive for its current stage.
function Grow.NeedsCurrentStageAdditive()
    if not Grow.IsEnabled() then
        return false
    end
    local AD = StockPiler2.Additives
    if not AD or not AD.IsEnabled or not AD.IsEnabled() then
        return false
    end
    if not AD.CultTypeForStage or not AD.PlotHasAdditive then
        return false
    end
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    for plotNum = 1, n do
        if (tonumber(Grow._pendingAdditive[plotNum]) or 0) < 1 then
            local plot = Grow.CachedPlot(plotNum)
            if type(plot) == "table" then
                local cultType = AD.CultTypeForStage(Grow.NormalizeStage(plot.stage))
                if cultType and not AD.PlotHasAdditive(plot, cultType) then
                    return true
                end
            end
        end
    end
    return false
end

--- Apply one Soil/Water/Nutrient for a plot whose stage matches an empty slot.
function Grow.TryApplyNextAdditive(opId)
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsBrewSessionActive
        and StockPiler2.Orchestrator.IsBrewSessionActive() == true
    then
        return false
    end
    if not Grow.IsEnabled() then
        return false
    end
    local AD = StockPiler2.Additives
    if not AD or not AD.IsEnabled or not AD.IsEnabled() then
        Grow._additiveDirty = false
        return false
    end
    if AddCraftingItem == nil then
        return false
    end
    local CA = StockPiler2.CultivatorAdapter
    if not CA or not CA.ApplyAdditive then
        return false
    end
    local plots = CA.NumPlots and CA.NumPlots() or 4
    if plots <= 0 then
        return false
    end
    local start = tonumber(Grow._additiveCursor) or 1
    if start < 1 or start > plots then
        start = 1
    end
    local now = NowSec()
    local ttl = tonumber(Grow.PENDING_TTL_SEC) or 10
    for i = 0, plots - 1 do
        local plotNum = ((start - 1 + i) % plots) + 1
        local pending = tonumber(Grow._pendingAdditive[plotNum]) or 0
        if pending > 0 then
            local at = tonumber(Grow._pendingAdditiveAt[plotNum]) or 0
            if at > 0 and (now - at) >= ttl then
                Grow.ClearPendingAdditive(plotNum)
                pending = 0
            end
        end
        if pending < 1 then
            local plot = Grow.CachedPlot(plotNum)
            if type(plot) == "table" then
                local stage = Grow.NormalizeStage(plot.stage)
                local cultType = AD.CultTypeForStage(stage)
                if cultType and not AD.PlotHasAdditive(plot, cultType) then
                    local slot, item, backpackType = AD.FindBestInCraftBag(cultType)
                    if slot > 0 and type(item) == "table" then
                        if GameData and GameData.Player and GameData.Player.Cultivation then
                            GameData.Player.Cultivation.CurrentPlot = plotNum
                        end
                        if StockPiler2.Scheduler and StockPiler2.Scheduler.SuppressInventorySideEffects then
                            StockPiler2.Scheduler.SuppressInventorySideEffects(2)
                        end
                        Grow._pendingAdditive[plotNum] = pending + 1
                        Grow._pendingAdditiveAt[plotNum] = now
                        local ok, err = CA.ApplyAdditive(plotNum, slot, backpackType)
                        if ok ~= true then
                            Grow.ClearPendingAdditive(plotNum)
                            LogGrow("additive failed P" .. tostring(plotNum)
                                .. " err=" .. tostring(err))
                            return false
                        end
                        Grow._additiveCursor = (plotNum % plots) + 1
                        Grow._additiveDirty = true
                        local info = AD.Classify(item)
                        local role = info and info.role or "?"
                        LogGrow("additive P" .. tostring(plotNum)
                            .. " role=" .. tostring(role)
                            .. " uid=" .. tostring(item.uniqueID)
                            .. " slot=" .. tostring(slot)
                            .. " opId=" .. tostring(opId or "?"))
                        if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
                            StockPiler2.Scheduler.WakeAutoGrow()
                        end
                        return true
                    end
                end
            end
        end
    end
    Grow._additiveDirty = false
    return false
end

function Grow.DumpDiagnostics(emit)
    emit = type(emit) == "function" and emit or function() end
    local RS = StockPiler2.RecipeSpec
    local SM = StockPiler2.SeedMap
    local Inv = StockPiler2.Inventory
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    local bufferOn = StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true
    emit("--- auto-grow ---")
    emit("  globalEnabled=" .. tostring(Grow.IsEnabled()))
    emit("  anyDemand=" .. tostring(Grow.AnyGrowDemand()))
    emit("  hasEmptyPlot=" .. tostring(Grow.HasEmptyPlot()))
    emit("  additivesEnabled=" .. tostring(
        StockPiler2.Additives and StockPiler2.Additives.IsEnabled
            and StockPiler2.Additives.IsEnabled() == true
    ))
    emit("  needsAdditive=" .. tostring(Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive()))
    emit("  additiveDirty=" .. tostring(Grow._additiveDirty == true))
    emit("  additivesKnown=" .. tostring(
        StockPiler2.Additives and StockPiler2.Additives.CountKnown
            and StockPiler2.Additives.CountKnown() or 0
    ))
    emit("  fillBlocked=" .. tostring(Grow.IsFillBlocked()))
    emit("  seedBuffer=" .. tostring(buffer))
    emit("  seedBufferEnabled=" .. tostring(bufferOn))
    emit("  plantQueueDirty=" .. tostring(Grow._plantQueueDirty == true))
    local cached = Grow._cachedPlantJob
    if type(cached) == "table" then
        emit(string.format(
            "  cachedJob reason=%s seedUid=%d plantable=%d",
            tostring(cached.plantReason or "?"),
            tonumber(cached.seedUid) or 0,
            tonumber(cached.plantable) or 0
        ))
    end
    if bufferOn and RS and RS.CollectAutoGrowSeedLines then
        emit("--- seed-buffer lines ---")
        local lines = RS.CollectAutoGrowSeedLines()
        if #lines == 0 then
            emit("  (none)")
        end
        for i = 1, #lines do
            local line = lines[i]
            local live = 0
            local headroom = 0
            local refinable = 0
            if StockPiler2.Refine and StockPiler2.Refine.GetSeedBudgetForSpec then
                local budget = StockPiler2.Refine.GetSeedBudgetForSpec(line.spec, line.seedUid)
                live = tonumber(budget and budget.live) or 0
                headroom = tonumber(budget and budget.headroom) or 0
            end
            if StockPiler2.Refine and StockPiler2.Refine.CountRefinablePlants then
                refinable = StockPiler2.Refine.CountRefinablePlants(line.plantUid, line.spec) or 0
            end
            emit(string.format(
                "  %s seedUid=%d plantUid=%d live=%d headroom=%d refinable=%d",
                tostring(line.specKey),
                tonumber(line.seedUid) or 0,
                tonumber(line.plantUid) or 0,
                live,
                headroom,
                refinable
            ))
        end
    end
    emit("--- watches ---")
    local watches = StockPiler2.Watch and StockPiler2.Watch.GetWatches() or {}
    local watchN = 0
    for watchKey, watch in pairs(watches) do
        watchN = watchN + 1
        local grow = RS and RS.ShouldAutoGrowPotion and RS.ShouldAutoGrowPotion(watchKey, watch)
        emit(string.format(
            "  key=%s enabled=%s autoGrow=%s target=%s shouldGrow=%s",
            tostring(watchKey),
            tostring(type(watch) == "table" and watch.enabled == true),
            tostring(type(watch) == "table" and watch.autoGrow ~= false),
            tostring(type(watch) == "table" and watch.targetStock or "?"),
            tostring(grow == true)
        ))
    end
    if watchN == 0 then
        emit("  (none)")
    end
    emit("--- spec demand ---")
    if not (RS and RS.BuildBalancedSpecDemand) then
        emit("  (RecipeSpec missing)")
        return
    end
    local demand = RS.BuildBalancedSpecDemand()
    local MS = StockPiler2.MaterialSpec
    local rowN = 0
    for specKey, row in pairs(demand) do
        rowN = rowN + 1
        local deficit = tonumber(row.deficit) or 0
        local growable = SM and SM.IsGrowableSpec and SM.IsGrowableSpec(row.spec) == true
        local productKey = (MS and MS.ProductKey and MS.ProductKey(row.spec)) or tostring(specKey)
        local seedUid = 0
        local seedHave = 0
        local plantable = 0
        local seedNote = "no-seed"
        if growable and SM.ResolveSeedForSpec then
            local seed = SM.ResolveSeedForSpec(row.spec)
            if type(seed) == "table" then
                seedUid = tonumber(seed.uniqueID) or 0
                if seedUid <= 0 and type(seed.itemData) == "table" then
                    seedUid = tonumber(seed.itemData.uniqueID) or 0
                end
                seedHave = tonumber(seed.count) or 0
                if SM.CountSeedsInBagsForSpec then
                    local variantCount = SM.CountSeedsInBagsForSpec(row.spec)
                    if variantCount > seedHave then
                        seedHave = variantCount
                    end
                elseif Inv and Inv.UniqueIdCount and seedUid > 0 then
                    local bagCount = Inv.UniqueIdCount(seedUid)
                    if bagCount > seedHave then
                        seedHave = bagCount
                    end
                end
                plantable = ComputePlantable(seedHave, deficit)
                seedNote = "resolved"
            else
                seedNote = "unresolved"
            end
        elseif not growable then
            seedNote = "not-growable"
        end
        local craftsShort = tonumber(row.craftsShort)
        if craftsShort == nil then
            craftsShort = deficit
        end
        emit(string.format(
            "  %s productKey=%s deficit=%d craftsShort=%d have=%d growable=%s seedUid=%d seeds=%d plantable=%d %s",
            tostring(specKey),
            tostring(productKey),
            deficit,
            craftsShort,
            tonumber(row.have) or 0,
            tostring(growable),
            seedUid,
            seedHave,
            plantable,
            seedNote
        ))
    end
    if rowN == 0 then
        emit("  (empty — check watch enabled + per-row AutoGrow + potion deficit)")
    end
    -- Fresh pick for diagnostics (avoid stale empty cache while fill-blocked).
    local job = Grow.PickPlantCandidate()
    if type(job) == "table" then
        emit(string.format(
            "--- pick --- seedUid=%d seeds=%d plantable=%d deficit=%d craftsShort=%d role=%s",
            tonumber(job.seedUid) or 0,
            tonumber(job.seedHave) or 0,
            tonumber(job.plantable) or 0,
            tonumber(job.deficit) or 0,
            tonumber(job.craftsShort) or 0,
            tostring(job.role or "?")
        ))
    else
        emit("--- pick --- (none)")
    end
    local CA = StockPiler2.CultivatorAdapter
    local plotN = CA and CA.NumPlots and CA.NumPlots() or 4
    for plotNum = 1, plotN do
        local pending = tonumber(Grow._pendingPlant[plotNum]) or 0
        if pending > 0 or not Grow.IsPlotEmpty(plotNum) then
            local plot = Grow.CachedPlot(plotNum)
            local stage = type(plot) == "table" and tonumber(plot.stage) or -1
            emit(string.format(
                "  pending P%d=%d stage=%d isPlotEmpty=%s",
                plotNum, pending, stage, tostring(Grow.IsPlotEmpty(plotNum))
            ))
        end
    end
end

local function StageLabel(stageNum)
    stageNum = Grow.NormalizeStage(stageNum)
    if stageNum == Grow.StageEmpty() then
        return L"Empty"
    end
    local CS = GameData and GameData.CultivationStage
    if CS then
        if CS.GERMINATION ~= nil and stageNum == CS.GERMINATION then
            return L"Germination"
        end
        if CS.SEEDLING ~= nil and stageNum == CS.SEEDLING then
            return L"Seedling"
        end
        if CS.FLOWERING ~= nil and stageNum == CS.FLOWERING then
            return L"Flowering"
        end
        if CS.GROWN ~= nil and stageNum == CS.GROWN then
            return L"Ready to harvest"
        end
        if CS.HARVESTING ~= nil and stageNum == CS.HARVESTING then
            return L"Harvesting"
        end
    end
    if stageNum == 1 then
        return L"Germination"
    end
    if stageNum == 2 then
        return L"Seedling"
    end
    if stageNum == 3 then
        return L"Flowering"
    end
    if stageNum == 4 then
        return L"Ready to harvest"
    end
    if stageNum == 5 then
        return L"Harvesting"
    end
    return L"Stage " .. towstring(tostring(stageNum))
end

--- Short cultivation notes for a material spec (Watch status / tooltip).
--- Matches any seed UID for the plant (dual-seed Mains), not only ResolveSeedForSpec's pick.
function Grow.GrowingNotesForSpec(spec)
    if type(spec) ~= "table" then
        return L""
    end
    local SM = StockPiler2.SeedMap
    if not SM then
        return L""
    end

    local plantUid = 0
    if SM.FindPlantUidForSpec then
        plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
    end
    if plantUid <= 0 and SM.CachedPlantUidForSpec then
        plantUid = tonumber(SM.CachedPlantUidForSpec(spec)) or 0
    end

    local seedSet = {}
    local function addSeed(uid)
        uid = tonumber(uid) or 0
        if uid > 0 then
            seedSet[uid] = true
        end
    end

    if plantUid > 0 and SM.GetSeedUidsForPlant then
        local uids = SM.GetSeedUidsForPlant(plantUid)
        if type(uids) == "table" then
            for i = 1, #uids do
                addSeed(uids[i])
            end
        end
    end
    if SM.ResolveSeedForSpec then
        local seed = SM.ResolveSeedForSpec(spec)
        if type(seed) == "table" then
            local uid = tonumber(seed.uniqueID) or 0
            if uid <= 0 and type(seed.itemData) == "table" then
                uid = tonumber(seed.itemData.uniqueID) or 0
            end
            addSeed(uid)
            if plantUid <= 0 then
                plantUid = tonumber(seed.plantUid) or tonumber(seed.producesPlantUid) or 0
            end
        end
    end
    if SM.FindSeedInBagsForPlantSpec then
        local inBags = SM.FindSeedInBagsForPlantSpec(spec)
        if type(inBags) == "table" then
            addSeed(inBags.uniqueID)
            if type(inBags.itemData) == "table" then
                addSeed(inBags.itemData.uniqueID)
            end
        end
    end

    local function seedMatches(plotSeed)
        plotSeed = tonumber(plotSeed) or 0
        if plotSeed <= 0 then
            return false
        end
        if seedSet[plotSeed] == true then
            return true
        end
        if plantUid > 0 and SM.PairLooksLikePlantAndSeed then
            return SM.PairLooksLikePlantAndSeed(plantUid, plotSeed) == true
        end
        return false
    end

    local hasAnySeed = false
    for _ in pairs(seedSet) do
        hasAnySeed = true
        break
    end
    if not hasAnySeed and plantUid <= 0 then
        return L""
    end

    local parts = {}
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    for plotNum = 1, n do
        local plot = Grow.CachedPlot(plotNum)
        if type(plot) == "table" then
            local plotSeed = tonumber(plot.seedUid) or 0
            local plotPlant = tonumber(plot.plantUid) or 0
            local stage = Grow.NormalizeStage(plot.stage)
            local pending = (tonumber(Grow._pendingPlant[plotNum]) or 0) > 0
            local pendingSeed = tonumber(Grow._pendingSeedUid[plotNum]) or 0
            if stage ~= Grow.StageEmpty() then
                if seedMatches(plotSeed)
                    or (plantUid > 0 and plotPlant == plantUid)
                then
                    parts[#parts + 1] = "P" .. tostring(plotNum) .. " " .. ToNarrow(StageLabel(stage))
                end
            elseif pending and seedMatches(pendingSeed) then
                parts[#parts + 1] = "P" .. tostring(plotNum) .. " planting"
            end
        end
    end
    if #parts == 0 then
        local job = Grow._cachedPlantJob
        if type(job) == "table" and seedMatches(job.seedUid) then
            parts[#parts + 1] = "next plant"
        end
    end
    if #parts == 0 then
        return L""
    end
    return towstring(table.concat(parts, ", "))
end

----------------------------------------------------------------
-- Harvest button tooltip (SP1 ShowHarvestTooltip slim port)
----------------------------------------------------------------

local HARVEST_TOOLTIP_ICON = 3317
local HARVEST_TOOLTIP_ROWS = 40

local function FormatTooltipIcon(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return L""
    end
    return towstring(string.format("<icon%05d>", iconNum))
end

local function FormatSeconds(t, condensed)
    t = tonumber(t) or 0
    if t <= 0 then
        return L""
    end
    if condensed then
        if TimeUtils and TimeUtils.FormatTimeCondensed then
            return TimeUtils.FormatTimeCondensed(t)
        end
    else
        if TimeUtils and TimeUtils.FormatTime then
            return TimeUtils.FormatTime(t)
        end
        if TimeUtils and TimeUtils.FormatTimeCondensed then
            return TimeUtils.FormatTimeCondensed(t)
        end
    end
    return towstring(tostring(math.ceil(t))) .. L"s"
end

--- Prefer TotalTimer (time to harvest / full completion); fall back to stage timer.
local function FormatPlotTimerStatus(stage, plot)
    local status = StageLabel(stage)
    if type(plot) ~= "table" then
        return status
    end
    local total = tonumber(plot.totalTimer) or 0
    local totalOn = plot.totalTimerOn
    if totalOn ~= false and total > 0 then
        local text = FormatSeconds(total, false)
        if text ~= L"" then
            return status .. L" - " .. text .. L" left"
        end
    end
    local stageT = tonumber(plot.stageTimer) or 0
    local stageOn = plot.stageTimerOn
    if stageOn ~= false and stageT > 0 then
        local text = FormatSeconds(stageT, true)
        if text ~= L"" then
            return status .. L" (" .. text .. L")"
        end
    end
    return status
end

local function ResolveSeedItemData(plot)
    if type(plot) ~= "table" then
        return nil
    end
    if type(plot.seed) == "table" and (plot.seed.rarity ~= nil or plot.seed.name ~= nil) then
        return plot.seed
    end
    local uid = tonumber(plot.seedUid) or 0
    if uid > 0 and StockPiler2.Items and StockPiler2.Items.AsItemData then
        local cached = StockPiler2.Items.AsItemData(uid)
        if type(cached) == "table" then
            return cached
        end
    end
    if uid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
        local _, sample = StockPiler2.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            return sample
        end
    end
    return type(plot.seed) == "table" and plot.seed or nil
end

local function PlantDisplayName(plot, plotNum)
    if type(plot) ~= "table" then
        return L"Plot " .. towstring(tostring(plotNum or "?"))
    end
    if plot.seedName ~= nil and plot.seedName ~= L"" then
        return plot.seedName
    end
    local seed = ResolveSeedItemData(plot)
    if type(seed) == "table" and seed.name ~= nil and seed.name ~= L"" then
        return seed.name
    end
    local uid = tonumber(plot.seedUid) or 0
    if uid > 0 then
        return L"Seed " .. towstring(tostring(uid))
    end
    return L"Plot " .. towstring(tostring(plotNum or "?"))
end

local function SeedIconNum(plot)
    if type(plot) ~= "table" then
        return 0
    end
    local icon = tonumber(plot.seedIconNum) or 0
    if icon > 0 then
        return icon
    end
    local seed = ResolveSeedItemData(plot)
    if type(seed) == "table" then
        return tonumber(seed.iconNum) or 0
    end
    return 0
end

local function ItemRarityColor(itemData)
    if itemData and DataUtils and DataUtils.GetItemRarityColor then
        local ok, color
        if StockPiler2.TryCallQuiet then
            ok, color = StockPiler2.TryCallQuiet("DataUtils.GetItemRarityColor", DataUtils.GetItemRarityColor, itemData)
        else
            ok, color = pcall(DataUtils.GetItemRarityColor, itemData)
        end
        if ok and type(color) == "table" then
            return color
        end
    end
    if DefaultColor and DefaultColor.WHITE then
        return DefaultColor.WHITE
    end
    return { r = 255, g = 255, b = 255 }
end

local function FormatPlotTooltipAdditiveLines(plot)
    local lines = {}
    if type(plot) ~= "table" or type(plot.additives) ~= "table" then
        return lines
    end
    local types = (GameData and GameData.CultivationTypes) or {}
    local order = {
        { tonumber(types.SOIL) or 2, L"Soil" },
        { tonumber(types.WATERCAN) or 3, L"Water" },
        { tonumber(types.NUTRIENT) or 4, L"Nutrient" },
    }
    for i = 1, #order do
        local slot = plot.additives[order[i][1]]
        if type(slot) == "table" and (slot.filled == true or (tonumber(slot.id) or 0) ~= 0) then
            local iconNum = tonumber(slot.iconNum) or 0
            if iconNum <= 0 and type(slot.item) == "table" then
                iconNum = tonumber(slot.item.iconNum) or 0
            end
            local icon = FormatTooltipIcon(iconNum)
            local name = slot.name
            if (name == nil or name == L"") and type(slot.item) == "table" then
                name = slot.item.name
            end
            if name == nil or name == L"" then
                name = order[i][2]
            end
            if icon ~= L"" then
                lines[#lines + 1] = icon .. L" " .. name
            else
                lines[#lines + 1] = order[i][2] .. L" " .. name
            end
        end
    end
    return lines
end

local function setTooltipRowColor(row, column, color)
    if not color or not Tooltips then
        return
    end
    if Tooltips.SetTooltipColor then
        Tooltips.SetTooltipColor(row, column, color.r or 255, color.g or 255, color.b or 255)
    elseif Tooltips.SetTooltipColorDef then
        Tooltips.SetTooltipColorDef(row, column, color)
    end
end

local function setTooltipBodyColor(row, column)
    if Tooltips and Tooltips.COLOR_BODY then
        setTooltipRowColor(row, column, Tooltips.COLOR_BODY)
    else
        setTooltipRowColor(row, column, { r = 255, g = 255, b = 255 })
    end
end

local function applyTooltipTextRow(row, text, color)
    Tooltips.SetTooltipText(row, 1, text or L"", false)
    if color then
        setTooltipRowColor(row, 1, color)
    else
        setTooltipBodyColor(row, 1)
    end
end

function Grow.EnsureHarvestTooltipRows()
    if Grow._harvestTooltipRowsReady == true then
        return true
    end
    if not DoesWindowExist("DefaultTooltip") or CreateWindowFromTemplate == nil then
        return false
    end
    local have = tonumber(Tooltips and Tooltips.NUM_ROWS) or 17
    for rowNum = have + 1, HARVEST_TOOLTIP_ROWS do
        local rowName = "DefaultTooltipRow" .. tostring(rowNum)
        if not DoesWindowExist(rowName) then
            local ok
            if StockPiler2.TryCall then
                ok = StockPiler2.TryCall(
                    "CreateWindowFromTemplate",
                    CreateWindowFromTemplate,
                    rowName,
                    "TooltipRow",
                    "DefaultTooltip"
                )
            else
                ok = pcall(CreateWindowFromTemplate, rowName, "TooltipRow", "DefaultTooltip")
            end
            if not ok or not DoesWindowExist(rowName) then
                return false
            end
            WindowClearAnchors(rowName)
            local prev = "DefaultTooltipRow" .. tostring(rowNum - 1)
            WindowAddAnchor(rowName, "bottomleft", prev, "topleft", 0, 5)
            WindowAddAnchor(rowName, "bottomright", prev, "topright", 0, 5)
        end
    end
    if Tooltips then
        local n = tonumber(Tooltips.NUM_ROWS) or 17
        if n < HARVEST_TOOLTIP_ROWS then
            Tooltips.NUM_ROWS = HARVEST_TOOLTIP_ROWS
        end
    end
    Grow._harvestTooltipRowsReady = true
    return true
end

function Grow.GetPlotTooltipEntries()
    local entries = {}
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    local anyGrowing = false
    local tipPlots = Grow._liveHarvestTip and Grow._liveHarvestTip.plots
    for plotNum = 1, n do
        local plot = nil
        if type(tipPlots) == "table" and type(tipPlots[plotNum]) == "table" then
            plot = tipPlots[plotNum]
        elseif CA and CA.ReadPlot then
            plot = CA.ReadPlot(plotNum)
        else
            plot = Grow.CachedPlot(plotNum)
        end
        if type(plot) == "table" then
            local stage = Grow.NormalizeStage(plot.stage)
            if stage ~= Grow.StageEmpty() then
                anyGrowing = true
                local seedData = ResolveSeedItemData(plot)
                local icon = FormatTooltipIcon(SeedIconNum(plot))
                local name = PlantDisplayName(plot, plotNum)
                local seedText = name
                if icon ~= L"" then
                    seedText = icon .. L" " .. name
                end
                local entry = {
                    title = { text = L"Plot " .. towstring(tostring(plotNum)) },
                    seed = {
                        text = seedText,
                        color = ItemRarityColor(seedData),
                    },
                    status = { text = FormatPlotTimerStatus(stage, plot) },
                }
                local additiveLines = FormatPlotTooltipAdditiveLines(plot)
                if #additiveLines > 0 then
                    entry.additives = { lines = additiveLines }
                end
                entries[#entries + 1] = entry
            end
        end
    end
    if not anyGrowing then
        entries[#entries + 1] = {
            noPlants = true,
            text = L"No plants growing.",
        }
    end
    return entries
end

local function ApplyPlotTooltipRow(row, entry)
    row = tonumber(row) or 1
    if type(entry) ~= "table" then
        return row + 1
    end
    if entry.noPlants == true then
        applyTooltipTextRow(row, entry.text or L"No plants growing.")
        return row + 1
    end
    if entry.title and entry.title.text and entry.title.text ~= L"" then
        local heading = entry.title.color
            or (Tooltips and Tooltips.COLOR_HEADING)
            or { r = 255, g = 204, b = 102 }
        applyTooltipTextRow(row, entry.title.text, heading)
        row = row + 1
    end
    if entry.seed and entry.seed.text and entry.seed.text ~= L"" then
        applyTooltipTextRow(row, entry.seed.text, entry.seed.color)
        row = row + 1
    end
    if type(entry.additives) == "table" and type(entry.additives.lines) == "table" then
        for i = 1, #entry.additives.lines do
            if entry.additives.lines[i] and entry.additives.lines[i] ~= L"" then
                applyTooltipTextRow(row, entry.additives.lines[i])
                row = row + 1
            end
        end
    end
    if entry.status and entry.status.text and entry.status.text ~= L"" then
        applyTooltipTextRow(row, entry.status.text)
        row = row + 1
    end
    return row
end

function Grow.ApplyPlotTooltipRows(startRow)
    if not Tooltips or type(Tooltips.SetTooltipText) ~= "function" then
        return tonumber(startRow) or 1
    end
    startRow = tonumber(startRow) or 1
    local entries = Grow.GetPlotTooltipEntries()
    if #entries == 0 or (entries[1] and entries[1].noPlants == true) then
        Tooltips.SetTooltipText(startRow, 1, L"No plants growing.", false)
        setTooltipBodyColor(startRow, 1)
        return startRow + 1
    end
    Tooltips.SetTooltipText(startRow, 1, L"Growing:", false)
    setTooltipBodyColor(startRow, 1)
    startRow = startRow + 1
    for i = 1, #entries do
        startRow = ApplyPlotTooltipRow(startRow, entries[i])
    end
    return startRow
end

--- Multi-row harvest tooltip for the Watch footer Harvest button.
--- liveRefresh=true skips re-register (used while mouse stays over the button).
function Grow.ShowHarvestTooltip(anchorWindow, anchor, liveRefresh)
    if not Tooltips or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    if anchorWindow == nil or anchorWindow == "" then
        return
    end
    if liveRefresh ~= true then
        Grow.RegisterHarvestLiveTooltip(anchorWindow, anchor or Tooltips.ANCHOR_WINDOW_TOP)
    end
    Grow.EnsureHarvestTooltipRows()
    Tooltips.CreateTextOnlyTooltip(anchorWindow)
    local titleIcon = FormatTooltipIcon(HARVEST_TOOLTIP_ICON)
    if titleIcon ~= L"" then
        Tooltips.SetTooltipText(1, 1, titleIcon .. L" StockPiler2 Harvest")
    else
        Tooltips.SetTooltipText(1, 1, L"StockPiler2 Harvest")
    end
    local heading = (Tooltips and Tooltips.COLOR_HEADING) or { r = 255, g = 204, b = 102 }
    setTooltipRowColor(1, 1, heading)

    local readyN = Grow.CountReadyHarvestPlots and Grow.CountReadyHarvestPlots() or 0
    local brewBlocks = StockPiler2.Brew
        and StockPiler2.Brew.BlocksHarvest
        and StockPiler2.Brew.BlocksHarvest() == true
    if brewBlocks then
        Tooltips.SetTooltipText(2, 1, L"Held: Brew is loaded or crafting.")
    else
        local ready = (tonumber(readyN) or 0) > 0 and L"ready" or L"not ready"
        Tooltips.SetTooltipText(2, 1, L"Click: harvest next grown plot (" .. ready .. L").")
    end
    setTooltipBodyColor(2, 1)

    local agOn = Grow.IsEnabled and Grow.IsEnabled() == true
    local ag = agOn and L"on" or L"off"
    local agIcon = agOn and L"<icon00057>" or L"<icon00058>"
    Tooltips.SetTooltipText(3, 1, agIcon .. L" AutoGrow is " .. ag .. L".")
    setTooltipBodyColor(3, 1)

    Grow.ApplyPlotTooltipRows(4)
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)

    local tip = Grow._liveHarvestTip
    if tip and tip.anchor == anchorWindow then
        tip.fingerprint = Grow.HarvestTooltipFingerprint()
    end
end

local function DecayTipTimer(plot, field, onField, elapsed)
    if type(plot) ~= "table" or plot[onField] ~= true then
        return false
    end
    local before = tonumber(plot[field]) or 0
    if before <= 0 then
        plot[onField] = false
        plot[field] = 0
        return false
    end
    local after = before - (tonumber(elapsed) or 0)
    if after < 0 then
        after = 0
    end
    plot[field] = after
    if after <= 0 then
        plot[onField] = false
    end
    return math.floor(after) < math.floor(before)
end

function Grow.SyncHarvestTipPlotsFromEngine()
    local tip = Grow._liveHarvestTip
    if not tip then
        tip = { plots = {} }
        Grow._liveHarvestTip = tip
    end
    tip.plots = tip.plots or {}
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    for plotNum = 1, n do
        if CA and CA.ReadPlot then
            tip.plots[plotNum] = CA.ReadPlot(plotNum)
        end
    end
end

function Grow.RegisterHarvestLiveTooltip(anchorWindow, anchorPoint)
    if anchorWindow == nil or anchorWindow == "" then
        Grow.ClearHarvestLiveTooltip()
        return
    end
    Grow._liveHarvestTip = Grow._liveHarvestTip or {}
    local tip = Grow._liveHarvestTip
    tip.kind = "harvest"
    tip.anchor = anchorWindow
    tip.anchorPoint = anchorPoint
    tip.fingerprint = nil
    Grow.SyncHarvestTipPlotsFromEngine()
end

function Grow.ClearHarvestLiveTooltip()
    local tip = Grow._liveHarvestTip
    if tip then
        tip.kind = nil
        tip.anchor = nil
        tip.anchorPoint = nil
        tip.fingerprint = nil
        tip.plots = nil
    end
end

function Grow.HarvestTooltipFingerprint()
    local parts = {}
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    local tipPlots = Grow._liveHarvestTip and Grow._liveHarvestTip.plots
    for plotNum = 1, n do
        local plot = type(tipPlots) == "table" and tipPlots[plotNum] or nil
        if type(plot) ~= "table" and CA and CA.ReadPlot then
            plot = CA.ReadPlot(plotNum)
        end
        if type(plot) == "table" then
            local stage = Grow.NormalizeStage(plot.stage)
            if stage ~= Grow.StageEmpty() then
                parts[#parts + 1] = plotNum .. ":"
                    .. tostring(stage) .. ":"
                    .. tostring(math.floor(tonumber(plot.totalTimer) or 0)) .. ":"
                    .. tostring(math.floor(tonumber(plot.stageTimer) or 0))
            end
        end
    end
    parts[#parts + 1] = (Grow.IsEnabled and Grow.IsEnabled() == true) and "ag1" or "ag0"
    local readyN = Grow.CountReadyHarvestPlots and Grow.CountReadyHarvestPlots() or 0
    parts[#parts + 1] = ((tonumber(readyN) or 0) > 0) and "rdy" or "wait"
    local brewBlocks = StockPiler2.Brew
        and StockPiler2.Brew.BlocksHarvest
        and StockPiler2.Brew.BlocksHarvest() == true
    parts[#parts + 1] = brewBlocks and "brewHold" or "brewOk"
    return table.concat(parts, "|")
end

function Grow.MaybeRefreshHarvestTooltip(force)
    local tip = Grow._liveHarvestTip
    if not tip or tip.kind ~= "harvest" or tip.anchor == nil or tip.anchor == "" then
        return
    end
    local mouse = SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    if mouse ~= tip.anchor then
        Grow.ClearHarvestLiveTooltip()
        return
    end
    local fp = Grow.HarvestTooltipFingerprint()
    if force ~= true and fp ~= nil and fp == tip.fingerprint then
        return
    end
    tip.fingerprint = fp
    Grow.ShowHarvestTooltip(tip.anchor, tip.anchorPoint, true)
end

--- Local countdown while harvest tip is open (engine timers only refresh on events).
function Grow.TickHarvestLiveTooltip(timeElapsed)
    local tip = Grow._liveHarvestTip
    if not tip or tip.kind ~= "harvest" or type(tip.plots) ~= "table" then
        return
    end
    local mouse = SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    if mouse ~= tip.anchor then
        Grow.ClearHarvestLiveTooltip()
        return
    end
    local elapsed = tonumber(timeElapsed) or 0
    if elapsed <= 0 then
        return
    end
    local changed = false
    for _, plot in pairs(tip.plots) do
        if DecayTipTimer(plot, "stageTimer", "stageTimerOn", elapsed) then
            changed = true
        end
        if DecayTipTimer(plot, "totalTimer", "totalTimerOn", elapsed) then
            changed = true
        end
    end
    if changed then
        Grow.MaybeRefreshHarvestTooltip(true)
    else
        Grow.MaybeRefreshHarvestTooltip(false)
    end
end
