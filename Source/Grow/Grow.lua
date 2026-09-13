----------------------------------------------------------------
-- StockPiler2 Grow — AutoGrow planting (one seed per orchestrator tick)
----------------------------------------------------------------

StockPiler2.Grow = StockPiler2.Grow or {}
local Grow = StockPiler2.Grow

local function T(key, tokens)
    if StockPiler2.T then
        return StockPiler2.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

Grow._pendingPlant = Grow._pendingPlant or {}
Grow._pendingPlantAt = Grow._pendingPlantAt or {}
Grow._pendingSeedUid = Grow._pendingSeedUid or {}
Grow._pendingPlantMeta = Grow._pendingPlantMeta or {}
-- Survives premature pending clear so late soil confirm still chats.
Grow._plantChatMeta = Grow._plantChatMeta or {}
Grow._plantFailCooldownUntil = Grow._plantFailCooldownUntil or {}
Grow._pendingAdditive = Grow._pendingAdditive or {}
Grow._pendingAdditiveAt = Grow._pendingAdditiveAt or {}
Grow._additiveCursor = Grow._additiveCursor or 1
Grow._additiveDirty = false
Grow._fillCursor = Grow._fillCursor or 1
Grow._lastSkipMsg = nil
Grow._cachedPlantJob = nil
Grow._plantQueueDirty = true
Grow._queueSnapGen = -1
Grow._tickPlantJobId = 0
Grow._tickPlantJobMemoTick = -1
Grow._tickPlantJob = nil
Grow._tickPlantJobProbed = false
Grow._seedCommitted = Grow._seedCommitted or {}
Grow._wavePlantedBySeed = Grow._wavePlantedBySeed or {}
Grow._lastPlantedSeedUid = 0
Grow._fillBlocked = false
Grow._plantWaitTicks = 0
Grow._jobProbed = false
Grow._lastChatHarvestWakeAt = 0
Grow._lastHarvestForceAt = 0
Grow._plantQuietUntil = 0
Grow._commitForceCleared = false
Grow._harvestOpLockUntil = 0
Grow._lastPreparedHarvestPlot = 0
Grow._harvestActionBound = false
Grow._footerHarvestClickable = nil
Grow._skillSkipByUid = Grow._skillSkipByUid or {}
Grow._skillSkipSnapGen = -1
Grow.PENDING_TTL_SEC = 10
-- PlantSeed can return ok while soil cache stays EMPTY for >1s; short grace
-- false-unconfirmed pending and dropped Plot-N planted chat (soil filled later).
Grow.PENDING_EMPTY_GRACE_SEC = 5.0
Grow.PLANT_CHAT_META_TTL_SEC = 30
Grow.UNCONFIRMED_PLANT_COOLDOWN_SEC = 6.0
-- After unconfirmed PlantSeed, pause all plots (not just the failing one).
Grow.UNCONFIRMED_GARDEN_QUIET_SEC = 8.0
Grow.CHAT_HARVEST_WAKE_DEBOUNCE_SEC = 1.5
Grow.HARVEST_FORCE_DEBOUNCE_SEC = 1.5
-- Quiet after plot-empty wake so replant does not stack on the engine harvest hitch.
Grow.POST_HARVEST_PLANT_DELAY_SEC = 0.75
Grow.HARVEST_OP_LOCK_SEC = 1.0

function Grow.SetFooterHarvestClickable(enabled)
    return StockPiler2.HarvestChrome.SetFooterHarvestClickable(enabled)
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

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function NotifyChat(msg)
    if StockPiler2.Debug and StockPiler2.Debug.Notify then
        StockPiler2.Debug.Notify(msg)
    elseif StockPiler2.Debug and StockPiler2.Debug.Print then
        StockPiler2.Debug.Print(msg)
    end
end

local function NotifyChatOnce(key, msg)
    if StockPiler2.Debug and StockPiler2.Debug.NotifyOnce then
        return StockPiler2.Debug.NotifyOnce(key, msg) == true
    end
    NotifyChat(msg)
    return true
end

local function ClearNotifyChatOnce(key)
    if StockPiler2.Debug and StockPiler2.Debug.ClearNotifyOnce then
        StockPiler2.Debug.ClearNotifyOnce(key)
    end
end

local function PlayUiSound(soundId)
    if StockPiler2.Debug and StockPiler2.Debug.PlayUiSound then
        StockPiler2.Debug.PlayUiSound(soundId)
    elseif type(PlaySound) == "function" and soundId ~= nil then
        pcall(PlaySound, soundId)
    end
end

local PLANT_REASON_LABEL = {
    potion_stock = "grow.reason.stock",
    seed_buffer = "grow.reason.buffer",
    surplus = "grow.reason.surplus",
}

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
    local coolUntil = tonumber(Grow._plantFailCooldownUntil[plotNum]) or 0
    if coolUntil > 0 then
        local now = NowSec()
        if now > 0 and now < coolUntil then
            return false
        end
        Grow._plantFailCooldownUntil[plotNum] = nil
    end
    local CA = StockPiler2.CultivatorAdapter
    if CA and CA.IsPlotLocked and CA.IsPlotLocked(plotNum) then
        return false
    end
    local plot = Grow.CachedPlot(plotNum)
    if type(plot) ~= "table" then
        return false
    end
    if plot.locked == true then
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

--- Seeds still in plots (pending/growing). Counts toward seed-buffer credit until
--- harvest success/fail or user uproot. SP2 never uproots.
function Grow.CountInGroundSeeds(seedUid)
    return CountPlotsForSeedUid(seedUid)
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

local function CurrentSnapGen()
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        return tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    return 0
end

local function SyncSkillSkipBlacklist()
    local snapGen = CurrentSnapGen()
    if Grow._skillSkipSnapGen ~= snapGen then
        Grow._skillSkipByUid = {}
        Grow._skillSkipSnapGen = snapGen
    end
end

local function IsSkillSkippedUid(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    SyncSkillSkipBlacklist()
    return Grow._skillSkipByUid[seedUid] == true
end

local function MarkSkillSkippedUid(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return
    end
    SyncSkillSkipBlacklist()
    Grow._skillSkipByUid[seedUid] = true
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
        local convertible = 0
        if Refine.SeedBufferConvertibleCount then
            convertible = tonumber(Refine.SeedBufferConvertibleCount(line, budget, refinable)) or 0
        elseif (tonumber(budget and budget.headroom) or 0) > 0 and refinable > 0 then
            convertible = refinable
        end
        if convertible > 0 then
            return true
        end
    end
    return false
end

--- True when any refinable buffer line has credit below buffer (SHORT).
local function AnyBufferShort(lines)
    local Refine = StockPiler2.Refine
    if type(Refine) ~= "table" or not Refine.GetSeedBudgetForSpec then
        return false
    end
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    for i = 1, #lines do
        local line = lines[i]
        local budget = Refine.GetSeedBudgetForSpec(line.spec, line.seedUid)
        local credit = tonumber(budget and budget.credit) or 0
        if credit < buffer then
            return true
        end
    end
    return false
end

local function BufferFlagsStructuralKey()
    -- garden / watch / buffer / outstanding — no snapGen (mid-refine deliveries).
    local gardenGen = 0
    if StockPiler2.Garden then
        if StockPiler2.Garden.GetPlanGen then
            gardenGen = tonumber(StockPiler2.Garden.GetPlanGen()) or 0
        elseif StockPiler2.Garden.GetGen then
            gardenGen = tonumber(StockPiler2.Garden.GetGen()) or 0
        end
    end
    local watchGen = 0
    if StockPiler2.Watch and StockPiler2.Watch.GetGen then
        watchGen = tonumber(StockPiler2.Watch.GetGen()) or 0
    end
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    local outstanding = 0
    local RP = StockPiler2.RefinePipeline
    if RP and RP.Snapshot then
        local snap = RP.Snapshot()
        if type(snap) == "table" then
            for _, n in pairs(snap) do
                outstanding = outstanding + (tonumber(n) or 0)
            end
        end
    end
    return tostring(gardenGen) .. ":" .. tostring(watchGen)
        .. ":" .. tostring(buffer) .. ":" .. tostring(outstanding)
end

local function BufferFlagsCacheKey()
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    -- Perf: planGen (plant/empty/lock) only for garden — stage-tick gardenGen used to
    -- rebuild BufferFlags → CollectAutoGrowSeedLines under Tick every growth stage.
    -- snapGen stays when garden has empties: pending/short are inventory-sensitive.
    -- Do not switch garden to GetGen().
    return tostring(snapGen) .. ":" .. BufferFlagsStructuralKey()
end

local function EnsureBufferFlagsCached()
    -- 0.4.125: while refine outstanding and garden full, reuse flags across snapGen
    -- bumps (seed deliveries). Rebuild when garden planGen / watch / outstanding change.
    local RP = StockPiler2.RefinePipeline
    local hasOut = RP and RP.HasOutstanding and RP.HasOutstanding() == true
    local fullGarden = not (Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true)
    if hasOut and fullGarden and type(Grow._bufferFlags) == "table" then
        local structKey = BufferFlagsStructuralKey()
        if Grow._bufferFlagsStructKey == structKey then
            return Grow._bufferFlags
        end
    end
    local key = BufferFlagsCacheKey()
    if Grow._bufferFlagsKey == key and type(Grow._bufferFlags) == "table" then
        return Grow._bufferFlags
    end
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Grow.BufferFlags")
    end
    local RS = StockPiler2.RecipeSpec
    -- Seed lines are structural-cached; CollectAutoGrowSeedLines should hit after prewarm.
    local lines = (RS and RS.CollectAutoGrowSeedLines and RS.CollectAutoGrowSeedLines()) or {}
    local flags = {
        pending = AnyBufferRefinePending(lines),
        short = AnyBufferShort(lines),
    }
    Grow._bufferFlagsKey = key
    Grow._bufferFlagsStructKey = BufferFlagsStructuralKey()
    Grow._bufferFlags = flags
    if Perf and Perf.End then
        Perf.End("Grow.BufferFlags")
    end
    return flags
end

--- True when BufferFlags match current snap/garden/watch key (Orch hold / diagnostics).
function Grow.AreBufferFlagsWarm()
    if type(Grow._bufferFlags) ~= "table" then
        return false
    end
    return Grow._bufferFlagsKey == BufferFlagsCacheKey()
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
    return EnsureBufferFlagsCached().pending == true
end

--- True when Seed Buffer is on and any watched refinable line is below buffer.
function Grow.HasAnyBufferShort()
    if not (StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true)
    then
        return false
    end
    local RS = StockPiler2.RecipeSpec
    if not (RS and RS.CollectAutoGrowSeedLines) then
        return false
    end
    return EnsureBufferFlagsCached().short == true
end

--- Seed Buffer off, or every watched buffer line is at/above target with no pending buffer refine.
function Grow.IsSeedBufferSatisfied()
    if not (StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true)
    then
        return true
    end
    if Grow.HasAnyBufferShort() == true then
        return false
    end
    if Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true then
        return false
    end
    return true
end

local function PickBufferGrowCandidate(lines, SM, Inv)
    local Refine = StockPiler2.Refine
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    local best = nil
    local bestWant = -1
    for i = 1, #lines do
        local line = lines[i]
        local seedHave, seedUid = SeedHaveForLine(line, SM, Inv)
        if seedUid > 0 and IsSkillSkippedUid(seedUid) then
            -- blacklisted for this snapGen
        elseif seedUid > 0 and not CanUseSeedUid(seedUid, Inv) then
            MarkSkillSkippedUid(seedUid)
        elseif seedUid > 0 and CanUseSeedUid(seedUid, Inv) then
            local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
            local avail = seedHave - committed
            local credit = seedHave
            if Refine and Refine.GetSeedBudgetForSpec then
                local budget = Refine.GetSeedBudgetForSpec(line.spec, seedUid)
                credit = tonumber(budget and budget.credit) or credit
            end
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
                                name = T("grow.seed_fallback"),
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
    if AnyBufferShort(lines) or AnyBufferRefinePending(lines) then
        return nil
    end
    local Refine = StockPiler2.Refine
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    local best = nil
    local bestSurplus = -1
    for i = 1, #lines do
        local line = lines[i]
        local seedHave, seedUid = SeedHaveForLine(line, SM, Inv)
        if seedUid > 0 and IsSkillSkippedUid(seedUid) then
            -- blacklisted for this snapGen
        elseif seedUid > 0 and not CanUseSeedUid(seedUid, Inv) then
            MarkSkillSkippedUid(seedUid)
        elseif seedUid > 0 then
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
                            name = T("grow.seed_fallback"),
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

--- Seed bag count for a resolved seed + spec (shared by focus/global pick).
local function SeedHaveForResolved(spec, seed, seedUid, SM, Inv)
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
    -- Eternal / Exceptional: stack stays while planting — credit a full plot wave.
    if SM and SM.EffectiveSeedCredit and seedUid > 0 then
        seedHave = SM.EffectiveSeedCredit(seedUid, seedHave)
    end
    return seedHave
end

--- Bottleneck score for a demand spec among focus watches: max bottleGap where
--- this spec is a limiting growable slot; also count of focus watches listing it.
local function FocusBottleneckForSpec(specKey, focus, demand)
    local RS = StockPiler2.RecipeSpec
    local MS = StockPiler2.MaterialSpec
    if type(focus) ~= "table" or type(focus.watches) ~= "table" or not RS or not MS or not MS.Key then
        return 0, 0
    end
    local bestGap = 0
    local shareCount = 0
    local demandHave = nil
    if type(demand) == "table" and type(demand[specKey]) == "table" then
        demandHave = tonumber(demand[specKey].have)
    end
    for i = 1, #focus.watches do
        local fw = focus.watches[i]
        local recipe = fw and fw.recipe
        local slots = recipe and recipe.slots
        if type(slots) == "table" then
            local craftsPossible = 0
            if RS.CountCraftsPossible then
                craftsPossible = math.max(0, math.floor((tonumber(RS.CountCraftsPossible(recipe)) or 0) + 0.5))
            end
            for j = 1, #slots do
                local slot = slots[j]
                local spec = slot and (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot) or slot.spec)
                if type(spec) == "table" and MS.Key(spec) == specKey then
                    shareCount = shareCount + 1
                    local perCraft = RS.EffectiveSpecPerCraft and RS.EffectiveSpecPerCraft(slot, slots) or 1
                    if perCraft < 1 then
                        perCraft = 1
                    end
                    local have = demandHave
                    if have == nil and RS.CountItemsMatchingSpec then
                        have = RS.CountItemsMatchingSpec(spec)
                    end
                    have = tonumber(have) or 0
                    local craftsHave = math.floor(have / perCraft)
                    -- Limiting slot: caps CountCraftsPossible (or short vs need).
                    local limiting = craftsHave <= craftsPossible
                    if limiting then
                        local gap = tonumber(fw.bottleGap) or 0
                        if gap > bestGap then
                            bestGap = gap
                        end
                    end
                    break
                end
            end
        end
    end
    return bestGap, shareCount
end

--- Build a plantable potion_stock job from a demand row, or nil.
local function JobFromDemandRow(row, SM, Inv)
    if type(row) ~= "table" then
        return nil
    end
    local deficit = tonumber(row.deficit) or 0
    local craftsShort = tonumber(row.craftsShort)
    if craftsShort == nil then
        craftsShort = deficit
    end
    local spec = row.spec
    if deficit <= 0 or craftsShort <= 0 or type(spec) ~= "table" or not SM.IsGrowableSpec(spec) then
        return nil
    end
    local seed = SM.ResolveSeedForSpec(spec)
    if type(seed) ~= "table" then
        return nil
    end
    local seedUid = tonumber(seed.uniqueID) or 0
    if seedUid <= 0 and type(seed.itemData) == "table" then
        seedUid = tonumber(seed.itemData.uniqueID) or 0
    end
    if seedUid <= 0 then
        return nil
    end
    if IsSkillSkippedUid(seedUid) then
        return nil
    end
    if not CanUseSeedUid(seedUid, Inv) then
        MarkSkillSkippedUid(seedUid)
        LogOnce("skill-" .. tostring(seedUid), "plant skip skill seedUid=" .. tostring(seedUid))
        return nil
    end
    local seedHave = SeedHaveForResolved(spec, seed, seedUid, SM, Inv)
    local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
    local avail = seedHave - committed
    local plantable = ComputePlantable(avail, deficit)
    if plantable <= 0 then
        return nil
    end
    local role = SpecRole(spec)
    return {
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
        plotCount = CountPlotsForSeedUid(seedUid),
        roleRank = RolePickRank(role),
    }
end

--- True when a potion_stock demand row still needs grow but cannot plant (no seeds)
--- while refinable plants sit in bags. Used to defer seed_buffer/surplus plant so Orch
--- can refine first (plant-first + buffer jobs otherwise fill plots and delay Shared close).
--- Mirrors JobFromDemandRow gates through plantable<=0; does not re-run BuildBalancedSpecDemand.
local function PotionStockNeedsRefineFirst(demand, SM, Inv)
    if type(demand) ~= "table" or type(SM) ~= "table" then
        return false
    end
    local Refine = StockPiler2.Refine
    if type(Refine) ~= "table" or not Refine.CountRefinablePlants then
        return false
    end
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
                    if seedUid <= 0 and type(seed.itemData) == "table" then
                        seedUid = tonumber(seed.itemData.uniqueID) or 0
                    end
                    if seedUid > 0 and not IsSkillSkippedUid(seedUid) and CanUseSeedUid(seedUid, Inv) then
                        local seedHave = SeedHaveForResolved(spec, seed, seedUid, SM, Inv)
                        local committed = tonumber(Grow._seedCommitted[seedUid]) or 0
                        local avail = seedHave - committed
                        local plantable = ComputePlantable(avail, deficit)
                        if plantable <= 0 then
                            local plantUid = tonumber(seed.plantUid) or 0
                            if plantUid > 0 and Refine.CountRefinablePlants(plantUid, spec) > 0 then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

local function PreferJob(candidate, best, bestScore, bestShare, bestCrafts, bestPlotCount, bestRoleRank, useFocusScore)
    if candidate == nil then
        return best, bestScore, bestShare, bestCrafts, bestPlotCount, bestRoleRank, false
    end
    local better = false
    if useFocusScore then
        local score = tonumber(candidate.bottleneckScore) or 0
        local share = tonumber(candidate.focusShare) or 999
        if best == nil then
            better = true
        elseif score > bestScore then
            better = true
        elseif score == bestScore then
            if share < bestShare then
                better = true
            elseif share == bestShare then
                local craftsShort = tonumber(candidate.craftsShort) or 0
                if craftsShort > bestCrafts then
                    better = true
                elseif craftsShort == bestCrafts then
                    if candidate.plotCount < bestPlotCount then
                        better = true
                    elseif candidate.plotCount == bestPlotCount and candidate.roleRank < bestRoleRank then
                        better = true
                    elseif candidate.plotCount == bestPlotCount and candidate.roleRank == bestRoleRank
                        and candidate.seedUid ~= (tonumber(Grow._lastPlantedSeedUid) or 0)
                        and best ~= nil
                        and (tonumber(best.seedUid) or 0) == (tonumber(Grow._lastPlantedSeedUid) or 0)
                    then
                        better = true
                    end
                end
            end
        end
        if better then
            return candidate, score, share, tonumber(candidate.craftsShort) or 0,
                candidate.plotCount, candidate.roleRank, true
        end
        return best, bestScore, bestShare, bestCrafts, bestPlotCount, bestRoleRank, false
    end

    local craftsShort = tonumber(candidate.craftsShort) or 0
    if best == nil then
        better = true
    elseif craftsShort > bestCrafts then
        better = true
    elseif craftsShort == bestCrafts then
        if candidate.plotCount < bestPlotCount then
            better = true
        elseif candidate.plotCount == bestPlotCount and candidate.roleRank < bestRoleRank then
            better = true
        elseif candidate.plotCount == bestPlotCount and candidate.roleRank == bestRoleRank
            and candidate.seedUid ~= (tonumber(Grow._lastPlantedSeedUid) or 0)
            and best ~= nil
            and (tonumber(best.seedUid) or 0) == (tonumber(Grow._lastPlantedSeedUid) or 0)
        then
            better = true
        end
    end
    if better then
        return candidate, bestScore, bestShare, craftsShort, candidate.plotCount, candidate.roleRank, true
    end
    return best, bestScore, bestShare, bestCrafts, bestPlotCount, bestRoleRank, false
end

function Grow.PickPlantCandidate()
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("PickPlantCandidate")
    end
    local RS = StockPiler2.RecipeSpec
    local SM = StockPiler2.SeedMap
    local Inv = StockPiler2.Inventory
    if type(RS) ~= "table" or not RS.BuildBalancedSpecDemand then
        if Perf and Perf.End then
            Perf.End("PickPlantCandidate")
        end
        return nil
    end
    if type(SM) ~= "table" or not SM.IsGrowableSpec or not SM.ResolveSeedForSpec then
        if Perf and Perf.End then
            Perf.End("PickPlantCandidate")
        end
        return nil
    end
    local demand = RS.BuildBalancedSpecDemand()
    local focus = nil
    local focusKeys = nil
    local hasFocus = false
    if RS.CollectAutoGrowFocus then
        focus = RS.CollectAutoGrowFocus()
        if type(focus) == "table" and type(focus.watches) == "table" and #focus.watches > 0 then
            hasFocus = true
            focusKeys = RS.FocusSpecKeys and RS.FocusSpecKeys(focus) or {}
        end
    end

    local function pickLoop(restrictKeys, useFocusScore)
        local best = nil
        local bestScore = -1
        local bestShare = 999
        local bestCrafts = -1
        local bestPlotCount = 999
        local bestRoleRank = 99
        for specKey, row in pairs(demand) do
            if restrictKeys == nil or restrictKeys[specKey] == true or restrictKeys[row.specKey] == true then
                local job = JobFromDemandRow(row, SM, Inv)
                if job ~= nil then
                    if useFocusScore then
                        local score, share = FocusBottleneckForSpec(job.specKey or specKey, focus, demand)
                        job.bottleneckScore = score
                        job.focusShare = share
                    end
                    best, bestScore, bestShare, bestCrafts, bestPlotCount, bestRoleRank =
                        PreferJob(job, best, bestScore, bestShare, bestCrafts, bestPlotCount, bestRoleRank, useFocusScore)
                end
            end
        end
        return best
    end

    local best = nil
    if hasFocus then
        best = pickLoop(focusKeys, true)
        if best ~= nil then
            best.pickMode = "focus"
            best.focusBottleGap = tonumber(focus.maxBottleGap) or 0
        end
    end
    if best == nil then
        best = pickLoop(nil, false)
        if best ~= nil then
            best.pickMode = hasFocus and "fallback" or "global"
        end
    end
    if best ~= nil then
        if Perf and Perf.End then
            Perf.End("PickPlantCandidate")
        end
        return best
    end
    -- No plantable potion deficit. Prefer refine into potion seeds over buffer/surplus
    -- plant: otherwise plant-first fills empty plots with seed_buffer and blocks refine
    -- until plots are full (Shared/yellow watches stall a full grow cycle).
    -- Do not revert to always returning buffer here — only defer when refine can unblock
    -- potion_stock; buffer-only play and seed-starved-with-no-refinable stay unchanged.
    if PotionStockNeedsRefineFirst(demand, SM, Inv) then
        if Perf and Perf.End then
            Perf.End("PickPlantCandidate")
        end
        return nil
    end
    if not (StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true)
    then
        if Perf and Perf.End then
            Perf.End("PickPlantCandidate")
        end
        return nil
    end
    if not RS.CollectAutoGrowSeedLines then
        if Perf and Perf.End then
            Perf.End("PickPlantCandidate")
        end
        return nil
    end
    local lines = RS.CollectAutoGrowSeedLines()
    best = PickBufferGrowCandidate(lines, SM, Inv)
    if best ~= nil then
        if Perf and Perf.End then
            Perf.End("PickPlantCandidate")
        end
        return best
    end
    local surplus = PickSurplusCandidate(lines, SM, Inv)
    if Perf and Perf.End then
        Perf.End("PickPlantCandidate")
    end
    return surplus
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
    Grow._pendingPlantMeta[plotNum] = nil
    -- opts.keepChatMeta: empty/grace clear — late soil fill may still need chat.
    if opts.keepChatMeta ~= true then
        Grow._plantChatMeta[plotNum] = nil
    end
end

local function ArmUnconfirmedPlantCooldown(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 then
        return
    end
    local now = NowSec()
    local sec = tonumber(Grow.UNCONFIRMED_PLANT_COOLDOWN_SEC) or 6.0
    local untilT = now + sec
    local cur = tonumber(Grow._plantFailCooldownUntil[plotNum]) or 0
    if untilT > cur then
        Grow._plantFailCooldownUntil[plotNum] = untilT
    end
    -- Garden-wide quiet so 4-plot round-robin cannot spam unconfirmed PlantSeed.
    local quietSec = tonumber(Grow.UNCONFIRMED_GARDEN_QUIET_SEC) or 8.0
    local quietUntil = now + quietSec
    local prevQuiet = tonumber(Grow._plantQuietUntil) or 0
    if quietUntil > prevQuiet then
        Grow._plantQuietUntil = quietUntil
    end
    LogOnce(
        "plant-unconfirmed-" .. tostring(plotNum),
        "plant-unconfirmed P" .. tostring(plotNum)
            .. " cooldown=" .. tostring(sec) .. "s"
            .. " quiet=" .. tostring(quietSec) .. "s"
    )
end

local function StashPlantChatMeta(plotNum, meta)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(meta) ~= "table" then
        return
    end
    Grow._plantChatMeta[plotNum] = {
        reason = meta.reason,
        name = meta.name,
        seedUid = meta.seedUid,
        at = NowSec(),
        chatted = false,
    }
end

local function NotifyPlantConfirmed(plotNum)
    plotNum = tonumber(plotNum) or 0
    local pendingMeta = Grow._pendingPlantMeta[plotNum]
    local stash = Grow._plantChatMeta[plotNum]
    local meta = pendingMeta
    if type(meta) ~= "table" then
        meta = stash
    end
    if type(meta) ~= "table" then
        return
    end
    -- Once per plant attempt (pending and/or late soil after premature clear).
    if meta.chatted == true then
        return
    end
    if type(stash) == "table" and stash.chatted == true then
        return
    end
    if meta == stash then
        local at = tonumber(stash.at) or 0
        local now = NowSec()
        local ttl = tonumber(Grow.PLANT_CHAT_META_TTL_SEC) or 30
        if at <= 0 or (now > 0 and at > 0 and (now - at) > ttl) then
            Grow._plantChatMeta[plotNum] = nil
            return
        end
    end
    meta.chatted = true
    if type(stash) == "table" then
        stash.chatted = true
    end
    if type(pendingMeta) == "table" then
        pendingMeta.chatted = true
    end
    local reasonRaw = tostring(meta.reason or "potion_stock")
    local reasonKey = PLANT_REASON_LABEL[reasonRaw]
    local reasonLabel = reasonKey and T(reasonKey) or towstring(reasonRaw)
    local seedName = meta.name
    if seedName == nil or seedName == L"" or seedName == "" then
        seedName = T("grow.seed_fallback")
    end
    NotifyChat(
        T("grow.planted", {
            plot = tostring(plotNum),
            name = seedName,
            reason = reasonLabel,
        })
    )
    LogGrow("plant-chat P" .. tostring(plotNum))
end

local function ApplyPendingClearForPlot(plotNum, plot)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(plot) ~= "table" then
        return
    end
    local pending = (tonumber(Grow._pendingPlant[plotNum]) or 0) > 0
    if Grow.NormalizeStage(plot.stage) ~= Grow.StageEmpty() then
        -- Soil has a plant: chat once (pending meta or stash after premature clear).
        if not pending then
            local stash = Grow._plantChatMeta[plotNum]
            if type(stash) == "table" then
                local plotSeed = tonumber(plot.seedUid) or 0
                local metaSeed = tonumber(stash.seedUid) or 0
                -- Stale stash from a failed attempt must not chat a different plant.
                if plotSeed > 0 and metaSeed > 0 and plotSeed ~= metaSeed then
                    Grow._plantChatMeta[plotNum] = nil
                    return
                end
            end
        end
        NotifyPlantConfirmed(plotNum)
        if pending then
            -- Release commit so the next PickPlantCandidate does not do
            -- seedHave - committed against a decremented bag.
            Grow.ClearPendingPlot(plotNum, { rollbackCommit = true })
            Grow.MaybeCompleteFillWave()
        end
        return
    end
    if not pending then
        return
    end
    -- Empty while pending: harvest/fail. Grace so post-plant empty frames don't clear.
    local at = tonumber(Grow._pendingPlantAt[plotNum]) or 0
    local now = NowSec()
    local grace = tonumber(Grow.PENDING_EMPTY_GRACE_SEC) or 5.0
    if at > 0 and (now - at) >= grace then
        -- Keep _plantChatMeta so a late soil fill still emits planted chat.
        Grow.ClearPendingPlot(plotNum, { rollbackCommit = true, keepChatMeta = true })
        ArmUnconfirmedPlantCooldown(plotNum)
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
    local function MaybeNotify(force)
        -- 0.4.159: per-frame SyncAll confirm must not re-notify every frame.
        -- Notify when garden gen advanced, a specific plot updated, or pending plant work.
        if force == true or Grow.HasPendingPlant() == true then
            Grow.MaybeNotifyHarvestReady()
            local Garden = StockPiler2.Garden
            if Garden and Garden.GetGen then
                Grow._lastHarvestNotifyGardenGen = tonumber(Garden.GetGen()) or 0
            end
            return
        end
        local Garden = StockPiler2.Garden
        local gen = 0
        if Garden and Garden.GetGen then
            gen = tonumber(Garden.GetGen()) or 0
        end
        if gen ~= (tonumber(Grow._lastHarvestNotifyGardenGen) or -1) then
            Grow._lastHarvestNotifyGardenGen = gen
            Grow.MaybeNotifyHarvestReady()
        end
    end
    if plotNum > 0 then
        HandleOne(plotNum, Grow.CachedPlot(plotNum))
        Grow.MarkAdditiveDue()
        MaybeNotify(true)
        if Grow._liveHarvestTip and Grow._liveHarvestTip.kind == "harvest" then
            Grow.SyncHarvestTipPlotsFromEngine()
            Grow.MaybeRefreshHarvestTooltip(true)
        end
        return
    end
    local Garden = StockPiler2.Garden
    local plots = Garden and Garden.GetPlotsCopy and Garden.GetPlotsCopy() or nil
    local hadPending = Grow.HasPendingPlant() == true
    if type(plots) ~= "table" then
        for pn, _ in pairs(Grow._pendingPlant) do
            HandleOne(pn, Grow.CachedPlot(pn))
        end
        for pn, _ in pairs(Grow._pendingAdditive) do
            Grow.ClearPendingAdditiveIfFilled(pn, Grow.CachedPlot(pn))
        end
        Grow.MarkAdditiveDue()
        MaybeNotify(hadPending)
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
    MaybeNotify(hadPending)
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
                Grow.ClearPendingPlot(plotNum, { rollbackCommit = true, keepChatMeta = true })
                ArmUnconfirmedPlantCooldown(plotNum)
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
--- opts.force=true — demand/job rebuild (harvest, demand change, wave end).
--- opts.keepPlanCache=true — with force: do not InvalidatePlanCache or ClearCountCaches
---   (harvest wake; Scheduler coalesced PlanRebuild owns the next full plan).
--- opts.jobOnly=true — dirty plant job only (seeds arrived from refine).
function Grow.InvalidatePlantQueue(opts)
    opts = type(opts) == "table" and opts or {}
    Grow._lastSkipMsg = nil
    -- 0.4.132: force-clear re-pick must not reuse tick-local memo from a nil first probe.
    Grow._tickPlantJobProbed = false
    Grow._tickPlantJob = nil
    if opts.force == true then
        -- Arm unconfirmed cooldown for pending-empty plots before wipe so force
        -- cannot erase protection and restart a PlantSeed spam storm.
        local CA = StockPiler2.CultivatorAdapter
        local n = CA and CA.NumPlots and CA.NumPlots() or 4
        for plotNum = 1, n do
            local pending = tonumber(Grow._pendingPlant[plotNum]) or 0
            if pending > 0 then
                local plot = Grow.CachedPlot(plotNum)
                local empty = type(plot) ~= "table"
                    or Grow.NormalizeStage(plot.stage) == Grow.StageEmpty()
                if empty then
                    ArmUnconfirmedPlantCooldown(plotNum)
                end
            end
        end
        Grow._plantQueueDirty = true
        Grow._cachedPlantJob = nil
        Grow._jobProbed = false
        Grow._seedCommitted = {}
        Grow._wavePlantedBySeed = {}
        Grow._pendingPlant = {}
        Grow._pendingPlantAt = {}
        Grow._pendingSeedUid = {}
        Grow._pendingPlantMeta = {}
        Grow._pendingAdditive = {}
        Grow._pendingAdditiveAt = {}
        Grow._additiveDirty = false
        Grow._fillBlocked = false
        Grow._plantWaitTicks = 0
        -- Do not clear _plantFailCooldownUntil / _plantQuietUntil on force.
        if opts.keepCommitForceCleared ~= true then
            Grow._commitForceCleared = false
        end
        -- keepPlanCache: leave RecipeSpec demand/seed-line caches warm for refine Collect*.
        if opts.keepPlanCache ~= true
            and StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.ClearCountCaches
        then
            StockPiler2.RecipeSpec.ClearCountCaches()
        end
        if opts.keepPlanCache ~= true
            and StockPiler2.Planner and StockPiler2.Planner.InvalidatePlanCache
        then
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
    if blocked == true then
        -- Do not reset an active wait on every no-job/refine-empty tick (stall loop).
        if Grow._fillBlocked == true then
            local cur = tonumber(Grow._plantWaitTicks) or 0
            local want = tonumber(waitTicks) or 5
            if want > cur then
                Grow._plantWaitTicks = want
            end
            return
        end
        Grow._fillBlocked = true
        Grow._plantWaitTicks = tonumber(waitTicks) or 5
        if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
            StockPiler2.Scheduler.SetAutoGrowIdle(true)
        end
        return
    end
    Grow._fillBlocked = false
    Grow._plantWaitTicks = 0
    Grow._jobProbed = false
    Grow._plantQueueDirty = true
    Grow._cachedPlantJob = nil
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
    local Inv = StockPiler2.Inventory
    local Garden = StockPiler2.Garden
    local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    -- Perf: planGen (plant/empty/lock), not stage-tick gardenGen — avoid re-Pick /
    -- BuildBalancedSpecDemand on every growth-stage tick under Orch.Tick.
    -- Do not switch this comparison back to Garden.GetGen().
    local gardenGen = 0
    if Garden then
        if Garden.GetPlanGen then
            gardenGen = tonumber(Garden.GetPlanGen()) or 0
        elseif Garden.GetGen then
            gardenGen = tonumber(Garden.GetGen()) or 0
        end
    end
    -- 0.4.132: one PickPlantCandidate per Orch.Tick (HasSeeds + TryPlant + Refine fill-block).
    local tickId = tonumber(Grow._tickPlantJobId) or 0
    if tickId > 0
        and Grow._tickPlantJobMemoTick == tickId
        and Grow._tickPlantJobProbed == true
    then
        return Grow._tickPlantJob
    end
    local function memoReturn(job)
        if tickId > 0 then
            Grow._tickPlantJobMemoTick = tickId
            Grow._tickPlantJob = job
            Grow._tickPlantJobProbed = true
        end
        return job
    end
    if Grow._plantQueueDirty ~= true then
        if type(Grow._cachedPlantJob) == "table" then
            local adjusted = AdjustJobForCommitted(Grow._cachedPlantJob)
            if adjusted ~= nil then
                return memoReturn(adjusted)
            end
            -- Committed seeds exhausted: re-pick another role/seed if plots still empty.
            if Grow.HasEmptyPlot() and not Grow.IsFillBlocked() then
                Grow._plantQueueDirty = true
                Grow._jobProbed = false
            else
                Grow._jobProbed = true
                return memoReturn(nil)
            end
        elseif Grow._jobProbed == true then
            -- Stay nil until explicitly dirtied (unblock / harvest / refine / demand).
            -- If gens unchanged, do not rebuild PickPlantCandidate (idle no-job spikes).
            if Grow._queueSnapGen == snapGen and Grow._queueGardenGen == gardenGen then
                return memoReturn(nil)
            end
            Grow._plantQueueDirty = true
            Grow._jobProbed = false
        end
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.BagWorkPending
        and StockPiler2.Scheduler.BagWorkPending() == true
        and type(Grow._cachedPlantJob) == "table"
        and Grow._plantQueueDirty ~= true
    then
        return memoReturn(AdjustJobForCommitted(Grow._cachedPlantJob))
    end
    local job = Grow.PickPlantCandidate()
    Grow._cachedPlantJob = job
    Grow._plantQueueDirty = false
    Grow._jobProbed = true
    Grow._queueSnapGen = snapGen
    Grow._queueGardenGen = gardenGen
    return memoReturn(AdjustJobForCommitted(job))
end

--- Call at start of Orchestrator.Tick so HasSeeds / TryPlant / Refine share one probe.
function Grow.BeginOrchTickPlantMemo()
    Grow._tickPlantJobId = (tonumber(Grow._tickPlantJobId) or 0) + 1
    Grow._tickPlantJobMemoTick = -1
    Grow._tickPlantJob = nil
    Grow._tickPlantJobProbed = false
end

--- True when a plant op is still outstanding on any plot.
function Grow.HasPendingPlant()
    local pending = Grow._pendingPlant
    if type(pending) ~= "table" then
        return false
    end
    for _, n in pairs(pending) do
        if (tonumber(n) or 0) > 0 then
            return true
        end
    end
    return false
end

function Grow.OnFillWaveComplete()
    -- 0.4.125: keep PlanSnapshot — last-plant used to InvalidatePlanCache and fuse a
    -- PlanRebuild into the seed-buffer refine hitch. Job/commit wipe still runs.
    Grow.InvalidatePlantQueue({ force = true, keepPlanCache = true })
    if StockPiler2.Refine and StockPiler2.Refine.ClearPostHarvestState then
        StockPiler2.Refine.ClearPostHarvestState()
    end
end

--- Wave end only when soil is full and no plant is still awaiting confirm.
--- HasEmptyPlot treats pending as filled, so the last TryPlant must not wipe
--- pending meta before soil confirm (that skipped Plot-N planted chat).
function Grow.MaybeCompleteFillWave()
    if Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true then
        return
    end
    if Grow.HasPendingPlant() == true then
        return
    end
    Grow.OnFillWaveComplete()
end

function Grow.OnDemandChanged()
    -- 0.4.135: keep Have/demand count caches — settings BumpGen does not change bags.
    -- ClearCountCaches forced cold WarmHave on every checkbox/chip PlanRebuild.
    Grow.InvalidatePlantQueue({ force = true, keepPlanCache = true })
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
        local plot = Grow.CachedPlot(plotNum)
        if type(plot) == "table" and Grow.IsPlotGrown(plot.stage) then
            ready[#ready + 1] = plotNum
        end
    end
    table.sort(ready)
    return ready
end

--- True when every non-empty plot is grown (ready to harvest); empty plots ignored.
function Grow.AllPlantedPlotsHarvestReady()
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    local planted = 0
    local ready = 0
    for plotNum = 1, n do
        local plot = Grow.CachedPlot(plotNum)
        if type(plot) == "table" then
            local stage = Grow.NormalizeStage(plot.stage)
            if stage ~= Grow.StageEmpty() then
                planted = planted + 1
                if Grow.IsPlotGrown(stage) then
                    ready = ready + 1
                end
            end
        end
    end
    return planted > 0 and ready == planted, ready, planted
end

--- Transition-only harvest-ready chat/sound (not on every footer CountReady).
--- Same gates as the Harvest button/macro: all planted plots ready AND CanHarvestNow.
--- 0.4.159: edge-only immediate footer sync; steady ready uses RequestFooterRefresh
--- so per-frame cultivation confirm does not Mark Footer xN000.
function Grow.MaybeNotifyHarvestReady()
    local allReady, readyN = Grow.AllPlantedPlotsHarvestReady()
    local canHarvest = Grow.CanHarvestNow and Grow.CanHarvestNow() == true
    local ready = allReady == true and canHarvest == true
    local wasReady = Grow._harvestReadyLatched == true
    if ready then
        if not wasReady then
            if StockPiler2Window and StockPiler2Window.SyncActionReadiness then
                StockPiler2Window.SyncActionReadiness({ immediate = true })
            end
        elseif StockPiler2Window and StockPiler2Window.RequestFooterRefresh then
            StockPiler2Window.RequestFooterRefresh()
        end
        Grow._harvestReadyLatched = true
        local printed = NotifyChatOnce(
            "harvest-ready",
            T("grow.harvest_ready", { count = tostring(readyN) })
        )
        if printed then
            local soundId = GameData and GameData.Sound and GameData.Sound.HELP_TIPS_NEW
            PlayUiSound(soundId)
        end
    else
        if wasReady and StockPiler2Window and StockPiler2Window.RequestFooterRefresh then
            StockPiler2Window.RequestFooterRefresh()
        end
        Grow._harvestReadyLatched = false
        ClearNotifyChatOnce("harvest-ready")
    end
end

--- True when any plot is planted and still mid-grow (not empty / grown / harvesting).
function Grow.HasPlotGrowing()
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    for plotNum = 1, n do
        local plot = Grow.CachedPlot(plotNum)
        if type(plot) == "table" then
            local stage = Grow.NormalizeStage(plot.stage)
            if stage ~= Grow.StageEmpty()
                and not Grow.IsPlotGrown(stage)
                and not Grow.IsPlotHarvesting(stage)
            then
                return true
            end
        end
    end
    return false
end

--- AutoGrow cannot plant/refine further and is not waiting on garden time or harvest.
--- Used for "your turn" chat when watches still need player actions (buy / skill gates).
function Grow.IsActionIdle()
    if Grow.IsEnabled() ~= true then
        return false
    end
    if Grow.HasPendingPlant() then
        return false
    end
    if Grow.HasPlotGrowing() then
        return false
    end
    local readyPlots = Grow.GetReadyHarvestPlots()
    if type(readyPlots) == "table" and #readyPlots > 0 then
        return false
    end
    if Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied() ~= true then
        return false
    end
    if Grow.HasEmptyPlot() then
        local job = Grow.GetPlantJob()
        if type(job) == "table" then
            local plantable = tonumber(job.plantable) or 0
            local seedHave = tonumber(job.seedHave) or 0
            if plantable > 0 or seedHave > 0 then
                return false
            end
        end
    end
    if Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true then
        return false
    end
    local Refine = StockPiler2.Refine
    if Refine and Refine.CollectIntents then
        local intents = Refine.CollectIntents()
        if type(intents) == "table" and #intents > 0 then
            return false
        end
    end
    return true
end

function Grow.CountReadyHarvestPlots()
    return #Grow.GetReadyHarvestPlots()
end

function Grow.HasHarvestInProgress()
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    for plotNum = 1, n do
        local plot = Grow.CachedPlot(plotNum)
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

function Grow.EnsureHarvestActionBound()
    return StockPiler2.HarvestChrome.EnsureHarvestActionBound()
end

function Grow.ClearHarvestActionBound()
    return StockPiler2.HarvestChrome.ClearHarvestActionBound()
end

function Grow.FireHarvestAction()
    return StockPiler2.HarvestChrome.FireHarvestAction()
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

--- True when a harvest can proceed (Cultivation, all planted plots grown, not brew-blocked).
--- Empty plots are ignored; button/macro stay lit mid-batch while remaining planted plots are ready.
function Grow.CanHarvestNow()
    local Caps = StockPiler2.TradeSkillCaps
    if Caps and Caps.HasCultivation and Caps.HasCultivation() ~= true then
        return false
    end
    if StockPiler2.Brew and StockPiler2.Brew.BlocksHarvest
        and StockPiler2.Brew.BlocksHarvest() == true
    then
        return false
    end
    local allReady = Grow.AllPlantedPlotsHarvestReady()
    return allReady == true
end

--- User chat for one plot harvest (main plant only; no byproducts).
function Grow.NotifyHarvestOutcome(plotNum, opts)
    opts = type(opts) == "table" and opts or {}
    plotNum = tonumber(plotNum) or 0
    if opts.critFail == true then
        NotifyChat(T("grow.harvest_crit_fail", { plot = tostring(plotNum) }))
        return
    end
    local count = tonumber(opts.count) or 0
    local name = opts.name
    if name == nil or name == L"" or name == "" then
        return
    end
    local uid = tonumber(opts.uniqueID) or 0
    if uid <= 0 and StockPiler2.SeedMap and StockPiler2.SeedMap.FindPlantUidByHarvestName then
        uid = tonumber(StockPiler2.SeedMap.FindPlantUidByHarvestName(name)) or 0
    end
    if StockPiler2.ItemChatLink then
        name = StockPiler2.ItemChatLink(uid, name)
    elseif type(name) == "string" then
        name = towstring(name)
    end
    NotifyChat(T("grow.harvest_outcome", {
        plot = tostring(plotNum),
        count = tostring(math.max(1, count)),
        name = name,
    }))
end

--- Prepare CurrentPlot + harvest watch; game-action button performs the craft.
function Grow.PrepareHarvestPlot(manual)
    -- 0.4.159: same-frame dedupe (hotbar hook + macro HarvestClick) and op-lock
    -- no-op before Perf.Begin — key-repeat was Marking PrepareHarvest x100.
    local frame = tonumber(StockPiler2.FrameCounter) or 0
    if frame > 0 and Grow._prepareHarvestFrame == frame then
        return true
    end
    local last = tonumber(Grow._lastPreparedHarvestPlot) or 0
    local lockUntil = tonumber(Grow._harvestOpLockUntil) or 0
    local now = NowSec()
    if last > 0 and lockUntil > 0 and now > 0 and now < lockUntil then
        local CA = StockPiler2.CultivatorAdapter
        local plot = CA and CA.ReadPlot and CA.ReadPlot(last) or Grow.CachedPlot(last)
        if type(plot) == "table"
            and (Grow.IsPlotGrown(plot.stage) or Grow.IsPlotHarvesting(plot.stage))
        then
            return true
        end
    end
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Grow.PrepareHarvest")
    end
    local function done()
        if Perf and Perf.End then
            Perf.End("Grow.PrepareHarvest")
        end
    end
    if Grow.CanHarvestNow and Grow.CanHarvestNow() ~= true then
        done()
        return false
    end
    Grow.EnsureHarvestActionBound()
    local ok, plotNum = Grow.SelectHarvestPlot(manual == true)
    if ok ~= true then
        done()
        return false
    end
    Grow.ArmHarvestOpLock(Grow.HARVEST_OP_LOCK_SEC)
    if frame > 0 then
        Grow._prepareHarvestFrame = frame
    end
    LogGrow(string.format(
        "harvest prepare P%d manual=%s ready=%d",
        tonumber(plotNum) or 0,
        tostring(manual == true),
        Grow.CountReadyHarvestPlots()
    ))
    done()
    return true
end

--- True while post-harvest plant quiet window is active (Orch must not probe/plant).
function Grow.IsPlantQuiet()
    local quietUntil = tonumber(Grow._plantQuietUntil) or 0
    if quietUntil <= 0 then
        return false
    end
    local now = NowSec()
    if now > 0 and now < quietUntil then
        return true
    end
    if now >= quietUntil then
        Grow._plantQuietUntil = 0
    end
    return false
end

--- Hold AutoGrow plant only during a uniform ready / mid-batch harvest wave:
--- at least one Grown plot and no mid-grow plots (empty + ready + harvesting only).
--- That keeps freed plots empty so CanHarvestNow stays true while you finish clicking.
--- Staggered gardens (ready + still growing + empty) must NOT hold: SP2 harvest is
--- already gated off by AllPlantedPlotsHarvestReady, and empties should still refill.
function Grow.ShouldHoldPlantForReadyHarvest()
    local ready = Grow.GetReadyHarvestPlots and Grow.GetReadyHarvestPlots() or nil
    if type(ready) ~= "table" or #ready <= 0 then
        return false
    end
    if Grow.HasPlotGrowing and Grow.HasPlotGrowing() == true then
        return false
    end
    return true
end

local function ArmHarvestStorm(plantDelay)
    local Sch = StockPiler2.Scheduler
    if not (Sch and Sch.BeginHarvestStorm) then
        return
    end
    plantDelay = tonumber(plantDelay) or (tonumber(Grow.POST_HARVEST_PLANT_DELAY_SEC) or 0.75)
    local stormSec = plantDelay
    local stormFloor = 1.5
    if Sch.HARVEST_STORM_MIN_SEC then
        stormFloor = tonumber(Sch.HARVEST_STORM_MIN_SEC) or 1.5
    end
    if stormSec < stormFloor then
        stormSec = stormFloor
    end
    Sch.BeginHarvestStorm(stormSec)
    return stormSec
end

--- Soft chat-only wake: quiet + clear block + WakeAutoGrow.
--- Does not force-invalidate (LearnBridge plot-empty owns that). Avoids dual
--- WakeAfterHarvest x2 stacking Planner/HasSeeds on the same harvest hitch.
function Grow.WakeAfterHarvestChat()
    local now = NowSec()
    local plantDelay = tonumber(Grow.POST_HARVEST_PLANT_DELAY_SEC) or 0.75
    -- Perf: quiet must be >= storm floor (1.5s). When quiet was 0.75s and storm 1.5s,
    -- Orch resumed plant/refine mid-storm (BufferFlags+CollectIntents) while bag/plan
    -- were still deferred. Do not shorten quiet below stormSec.
    local stormSec = ArmHarvestStorm(plantDelay) or math.max(plantDelay, 1.5)
    local quietUntil = now + stormSec
    local prevQuiet = tonumber(Grow._plantQuietUntil) or 0
    if quietUntil > prevQuiet then
        Grow._plantQuietUntil = quietUntil
    end
    Grow.ClearFillBlocked()
    if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
        StockPiler2.Scheduler.WakeAutoGrow()
    end
    -- If cultivation empty-edge never arrives, still force once (debounced).
    local forceDebounce = tonumber(Grow.HARVEST_FORCE_DEBOUNCE_SEC) or 1.5
    local lastForce = tonumber(Grow._lastHarvestForceAt) or 0
    if lastForce <= 0 or now <= 0 or (now - lastForce) >= forceDebounce then
        -- Defer force to next frame via plot-less wake only when no recent force.
        -- Prefer LearnBridge; this is a fallback after debounce window with no plot wake.
        Grow._chatHarvestNeedsForce = true
    end
end

--- After a plot becomes empty (cultivation): clear block, rebuild job, wake.
--- Always MarkRefineDue on force; Orch plant-first clears refine when plantable.
--- Per-plot wakes (P1–P4) share one force-invalidate + plant quiet window so replant
--- does not stack on the engine harvest hitch.
--- Perf: no sync HasSeeds/PickPlantCandidate on this hitch frame (0.4.95) — that used to
--- fuse WakeAfterHarvest → PickPlantCandidate → Harvest.Complete on empty-plot trails.
--- Orch probes after quiet. Do not reintroduce sync HasSeeds here.
--- opts.soft=true — quiet/wake only (same as WakeAfterHarvestChat).
function Grow.WakeAfterHarvest(plotNum, opts)
    opts = type(opts) == "table" and opts or {}
    if opts.soft == true then
        Grow.WakeAfterHarvestChat()
        return false
    end
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Grow.WakeAfterHarvest")
    end
    local function done()
        if Perf and Perf.End then
            Perf.End("Grow.WakeAfterHarvest")
        end
        return false
    end
    plotNum = tonumber(plotNum) or 0
    local now = NowSec()
    local plantDelay = tonumber(Grow.POST_HARVEST_PLANT_DELAY_SEC) or 0.75
    -- Quiet >= storm (see WakeAfterHarvestChat) — keep windows aligned.
    local stormSec = ArmHarvestStorm(plantDelay) or math.max(plantDelay, 1.5)
    local quietUntil = now + stormSec
    local prevQuiet = tonumber(Grow._plantQuietUntil) or 0
    if quietUntil > prevQuiet then
        Grow._plantQuietUntil = quietUntil
    end
    Grow._chatHarvestNeedsForce = false
    Grow.ClearFillBlocked()
    local forceDebounce = tonumber(Grow.HARVEST_FORCE_DEBOUNCE_SEC) or 1.5
    local lastForce = tonumber(Grow._lastHarvestForceAt) or 0
    local doForce = lastForce <= 0 or now <= 0 or (now - lastForce) >= forceDebounce
    if doForce then
        Grow._lastHarvestForceAt = now
        -- Keep PlanSnapshot: footer CanBrewNow / GetOrBuild must not sync-build mid-hitch.
        Grow.InvalidatePlantQueue({ force = true, keepPlanCache = true })
        if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueuePlanRebuild then
            StockPiler2.Scheduler.EnqueuePlanRebuild()
        end
        -- Do not sync HasSeeds/Pick on the hitch frame — Orch probes after plant quiet.
        if StockPiler2.Refine and StockPiler2.Refine.MarkRefineDue then
            StockPiler2.Refine.MarkRefineDue("harvest")
        end
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
        StockPiler2.Scheduler.WakeAutoGrow()
    end
    LogOnce(
        "harvest-wake-" .. tostring(plotNum),
        string.format(
            "harvest-wake P%s force=%s quiet=%.1f",
            tostring(plotNum > 0 and plotNum or "?"),
            tostring(doForce),
            stormSec
        )
    )
    return done()
end

function Grow.LogSkipPlant(reason)
    LogOnce("skip-" .. tostring(reason or "?"), "skip plant reason=" .. tostring(reason or "?"))
end

function Grow.TryPlantNextEmptyPlot(opId)
    if Grow._chatHarvestNeedsForce == true then
        local now = NowSec()
        local lastForce = tonumber(Grow._lastHarvestForceAt) or 0
        local forceDebounce = tonumber(Grow.HARVEST_FORCE_DEBOUNCE_SEC) or 1.5
        if lastForce > 0 and now > 0 and (now - lastForce) < forceDebounce then
            -- LearnBridge already forced this wave.
            Grow._chatHarvestNeedsForce = false
        else
            Grow._chatHarvestNeedsForce = false
            Grow.WakeAfterHarvest(0)
        end
    end
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsBrewSessionActive
        and StockPiler2.Orchestrator.IsBrewSessionActive() == true
    then
        return false
    end
    if not Grow.IsEnabled() then
        return false
    end
    local Sch = StockPiler2.Scheduler
    if Sch and Sch.ShouldDeferAutoGrowPlant then
        local deferPlant, deferReason = Sch.ShouldDeferAutoGrowPlant()
        if deferPlant == true then
            Grow.LogSkipPlant(tostring(deferReason or "scenario"))
            return false
        end
    end
    local quietUntil = tonumber(Grow._plantQuietUntil) or 0
    if quietUntil > 0 then
        local now = NowSec()
        if now > 0 and now < quietUntil then
            LogOnce("plant-quiet", string.format("plant quiet remaining=%.1fs", quietUntil - now))
            return false
        end
        Grow._plantQuietUntil = 0
    end
    if Grow.ShouldHoldPlantForReadyHarvest and Grow.ShouldHoldPlantForReadyHarvest() == true then
        LogOnce("plant-harvest-batch", "plant hold: ready harvest plot(s) remain")
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
        if type(live) == "table" then
            if live.locked == true then
                LogOnce("locked-live", "plant skip P" .. tostring(plotNum) .. " locked")
                if StockPiler2.Perf and StockPiler2.Perf.End then
                    StockPiler2.Perf.End("Grow.TryPlant")
                end
                return false
            end
            if Grow.NormalizeStage(live.stage) ~= Grow.StageEmpty() then
                LogOnce("not-empty-live", "plant skip P" .. tostring(plotNum) .. " live not empty")
                if StockPiler2.Perf and StockPiler2.Perf.End then
                    StockPiler2.Perf.End("Grow.TryPlant")
                end
                return false
            end
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
    -- Same-tick / same-job slot reuse (0.4.118): Prefer job stash when snapGen+seedUid
    -- still match; FindSeedSlot also memoizes by snap. Do not reuse across snapGen.
    local slot, item, backpackType = 0, nil, nil
    if CA.TrySeedSlotFromJob then
        slot, item, backpackType = CA.TrySeedSlotFromJob(job)
    end
    if slot <= 0 or type(item) ~= "table" then
        slot, item, backpackType = CA.FindSeedSlot(job.seedUid, seedKey)
        if slot > 0 and type(item) == "table" and CA.StashSeedSlotOnJob then
            local Inv = StockPiler2.Inventory
            local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
            local bagKey = nil
            if type(CA._seedSlotCache) == "table" then
                local cached = CA._seedSlotCache[tonumber(job.seedUid) or 0]
                if type(cached) == "table" then
                    bagKey = cached.bagKey
                end
            end
            CA.StashSeedSlotOnJob(job, job.seedUid, slot, bagKey, snapGen)
        end
    end
    if slot <= 0 or type(item) ~= "table" then
        if Grow.HasEmptyPlot() and Grow._commitForceCleared ~= true then
            LogGrow("empty+no seed slot; force clear inflated seed commits")
            Grow.InvalidatePlantQueue({ force = true, keepCommitForceCleared = true })
            Grow._commitForceCleared = true
            job = Grow.GetPlantJob()
            if type(job) == "table" then
                seedKey = job.seed.nameNarrow or ToNarrow(job.seed.name) or ToNarrow(job.seed.match)
                slot, item, backpackType = 0, nil, nil
                if CA.TrySeedSlotFromJob then
                    slot, item, backpackType = CA.TrySeedSlotFromJob(job)
                end
                if slot <= 0 or type(item) ~= "table" then
                    slot, item, backpackType = CA.FindSeedSlot(job.seedUid, seedKey)
                    if slot > 0 and type(item) == "table" and CA.StashSeedSlotOnJob then
                        local Inv = StockPiler2.Inventory
                        local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
                        local bagKey = nil
                        if type(CA._seedSlotCache) == "table" then
                            local cached = CA._seedSlotCache[tonumber(job.seedUid) or 0]
                            if type(cached) == "table" then
                                bagKey = cached.bagKey
                            end
                        end
                        CA.StashSeedSlotOnJob(job, job.seedUid, slot, bagKey, snapGen)
                    end
                end
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
    local seedName = T("grow.seed_fallback")
    if type(item) == "table" and item.name ~= nil and item.name ~= L"" then
        seedName = item.name
    elseif type(job.seed) == "table" and job.seed.name ~= nil and job.seed.name ~= L"" then
        seedName = job.seed.name
    end
    Grow._pendingPlantMeta[plotNum] = {
        reason = tostring(job.plantReason or "potion_stock"),
        name = seedName,
        seedUid = seedUid,
    }
    StashPlantChatMeta(plotNum, Grow._pendingPlantMeta[plotNum])
    if StockPiler2.Scheduler and StockPiler2.Scheduler.SuppressInventorySideEffects then
        StockPiler2.Scheduler.SuppressInventorySideEffects(2)
    end
    local ok, err = CA.PlantSeed(plotNum, slot, backpackType)
    if ok ~= true then
        Grow.ClearPendingPlot(plotNum)
        LogGrow("plant failed P" .. tostring(plotNum) .. " err=" .. tostring(err))
        NotifyChat(
            T("grow.plant_failed", {
                plot = tostring(plotNum),
                err = tostring(err or "unknown"),
            })
        )
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Grow.TryPlant")
        end
        return false
    end
    if StockPiler2.SeedMap and StockPiler2.SeedMap.NotePlantAttempt then
        StockPiler2.SeedMap.NotePlantAttempt(seedUid)
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
            -- Only persist when names/genus agree — never re-poison from a bad job.plantUid.
            local okPair = true
            if StockPiler2.SeedMap.PairLooksLikePlantAndSeed then
                okPair = StockPiler2.SeedMap.PairLooksLikePlantAndSeed(plantUid, seedUid) == true
            end
            if okPair then
                StockPiler2.SeedMap.LearnMapping(plantUid, seedUid, "plant", true)
            end
        end
    end
    -- Chat only when soil leaves EMPTY (confirm path below / cultivation events).
    -- PlantSeed can return ok without the plot accepting the seed.
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
    -- Chat only when soil leaves EMPTY. PlantSeed can return ok while the plot
    -- cache is still empty for seconds — do not run empty/grace clear here
    -- (that false-unconfirmed P1/P2 and dropped planted chat; soil filled later).
    if StockPiler2.Garden and StockPiler2.Garden.SyncPlot then
        StockPiler2.Garden.SyncPlot(plotNum)
    elseif StockPiler2.Garden and StockPiler2.Garden.OnCultivationUpdated then
        StockPiler2.Garden.OnCultivationUpdated()
    end
    local filled = Grow.CachedPlot(plotNum)
    if type(filled) == "table" and Grow.NormalizeStage(filled.stage) ~= Grow.StageEmpty() then
        NotifyPlantConfirmed(plotNum)
        if (tonumber(Grow._pendingPlant[plotNum]) or 0) > 0 then
            Grow.ClearPendingPlot(plotNum, { rollbackCommit = true })
        end
        Grow.MaybeCompleteFillWave()
    end
    Grow.ClearPendingAdditiveIfFilled(plotNum, filled)
    Grow.MarkAdditiveDue()
    -- Re-pick next plot for craftsShort / role fairness; keep seedCommitted.
    Grow._plantQueueDirty = true
    Grow._cachedPlantJob = nil
    Grow._jobProbed = false
    Grow._queueSnapGen = nil
    Grow._queueGardenGen = nil
    if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
        StockPiler2.Scheduler.WakeAutoGrow()
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
    local Sch = StockPiler2.Scheduler
    if Sch and Sch.ShouldDeferAutoGrowPlant then
        local deferPlant = Sch.ShouldDeferAutoGrowPlant()
        if deferPlant == true then
            return false
        end
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
            local ground = 0
            local headroom = 0
            local refinable = 0
            if StockPiler2.Refine and StockPiler2.Refine.GetSeedBudgetForSpec then
                local budget = StockPiler2.Refine.GetSeedBudgetForSpec(line.spec, line.seedUid)
                live = tonumber(budget and budget.live) or 0
                ground = tonumber(budget and budget.ground) or 0
                headroom = tonumber(budget and budget.headroom) or 0
            end
            if StockPiler2.Refine and StockPiler2.Refine.CountRefinablePlants then
                refinable = StockPiler2.Refine.CountRefinablePlants(line.plantUid, line.spec) or 0
            end
            emit(string.format(
                "  %s seedUid=%d plantUid=%d live=%d ground=%d headroom=%d refinable=%d",
                tostring(line.specKey),
                tonumber(line.seedUid) or 0,
                tonumber(line.plantUid) or 0,
                live,
                ground,
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
    local focus = RS.CollectAutoGrowFocus and RS.CollectAutoGrowFocus() or nil
    emit("--- focus ---")
    if type(focus) == "table" and type(focus.watches) == "table" and #focus.watches > 0 then
        emit(string.format(
            "  maxBottleGap=%s watches=%d",
            tostring(focus.maxBottleGap),
            #focus.watches
        ))
        for i = 1, #focus.watches do
            local fw = focus.watches[i]
            emit(string.format(
                "  [%d] %s bottleGap=%d stock=%d craftable=%d target=%d",
                i,
                ToNarrow(fw.name),
                tonumber(fw.bottleGap) or 0,
                tonumber(fw.stock) or 0,
                tonumber(fw.craftable) or 0,
                tonumber(fw.target) or 0
            ))
        end
    else
        emit("  (none)")
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
                seedHave = SeedHaveForResolved(row.spec, seed, seedUid, SM, Inv)
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
            "--- pick --- mode=%s seedUid=%d seeds=%d plantable=%d deficit=%d craftsShort=%d role=%s bottleneck=%s share=%s focusGap=%s",
            tostring(job.pickMode or job.plantReason or "?"),
            tonumber(job.seedUid) or 0,
            tonumber(job.seedHave) or 0,
            tonumber(job.plantable) or 0,
            tonumber(job.deficit) or 0,
            tonumber(job.craftsShort) or 0,
            tostring(job.role or "?"),
            tostring(job.bottleneckScore),
            tostring(job.focusShare),
            tostring(job.focusBottleGap)
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
        return T("grow.stage.empty")
    end
    local CS = GameData and GameData.CultivationStage
    if CS then
        if CS.GERMINATION ~= nil and stageNum == CS.GERMINATION then
            return T("grow.stage.germination")
        end
        if CS.SEEDLING ~= nil and stageNum == CS.SEEDLING then
            return T("grow.stage.seedling")
        end
        if CS.FLOWERING ~= nil and stageNum == CS.FLOWERING then
            return T("grow.stage.flowering")
        end
        if CS.GROWN ~= nil and stageNum == CS.GROWN then
            return T("grow.stage.ready")
        end
        if CS.HARVESTING ~= nil and stageNum == CS.HARVESTING then
            return T("grow.stage.harvesting")
        end
    end
    if stageNum == 1 then
        return T("grow.stage.germination")
    end
    if stageNum == 2 then
        return T("grow.stage.seedling")
    end
    if stageNum == 3 then
        return T("grow.stage.flowering")
    end
    if stageNum == 4 then
        return T("grow.stage.ready")
    end
    if stageNum == 5 then
        return T("grow.stage.harvesting")
    end
    return T("grow.stage.n", { n = tostring(stageNum) })
end

--- Short cultivation notes for a material spec (Watch status / tooltip).
--- Exact seed UIDs only (ResolveSeed + GetSeedUidsForPlant).
--- Do NOT PairLooksLikePlantAndSeed against plot seeds — that falsely tags
--- Extender plots onto Multiplier (and similar) when names/products are unrelated.
--- Do NOT FindSeedInBagsForPlantSpec — SeedMatchesGrowSpec can pollute seedSet.
function Grow.GrowingNotesForSpec(spec, opts)
    if type(spec) ~= "table" then
        return L""
    end
    opts = type(opts) == "table" and opts or {}
    local cacheOnly = opts.cacheOnly == true
    local SM = StockPiler2.SeedMap
    if not SM then
        return cacheOnly and nil or L""
    end

    local plantUid = 0
    if cacheOnly then
        -- Never FindPlantUidForSpec (account/bag walk). Cache miss → nil (caller keeps prior).
        if SM.FindPlantUidForHave then
            plantUid = tonumber(SM.FindPlantUidForHave(spec)) or 0
        end
        if plantUid <= 0 and SM.CachedPlantUidForSpec then
            plantUid = tonumber(SM.CachedPlantUidForSpec(spec)) or 0
        end
        if plantUid <= 0 then
            return nil
        end
    else
        if SM.FindPlantUidForSpec then
            plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
        end
        if plantUid <= 0 and SM.CachedPlantUidForSpec then
            plantUid = tonumber(SM.CachedPlantUidForSpec(spec)) or 0
        end
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
    if not cacheOnly and SM.ResolveSeedForSpec then
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
    -- Do not call FindSeedInBagsForPlantSpec here: SeedMatchesGrowSpec can accept a
    -- wrong bag spore when grows/GetPlantUidForSeed is polluted, which then lists
    -- Extender plots under Multiplier (and similar) in the Watch tooltip.

    local function seedMatches(plotSeed)
        plotSeed = tonumber(plotSeed) or 0
        if plotSeed <= 0 then
            return false
        end
        return seedSet[plotSeed] == true
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
                    or (plantUid > 0 and plotPlant > 0 and plotPlant == plantUid)
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

local HARVEST_TOOLTIP_ICON = 2486
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
    return T("grow.tip.seconds", { n = tostring(math.ceil(t)) })
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
            return T("grow.tip.timer_left", { status = status, time = text })
        end
    end
    local stageT = tonumber(plot.stageTimer) or 0
    local stageOn = plot.stageTimerOn
    if stageOn ~= false and stageT > 0 then
        local text = FormatSeconds(stageT, true)
        if text ~= L"" then
            return T("grow.tip.timer_stage", { status = status, time = text })
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
        return T("grow.tip.plot_n", { n = tostring(plotNum or "?") })
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
        return T("grow.tip.seed_uid", { uid = tostring(uid) })
    end
    return T("grow.tip.plot_n", { n = tostring(plotNum or "?") })
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
        { tonumber(types.SOIL) or 2, T("grow.tip.soil") },
        { tonumber(types.WATERCAN) or 3, T("grow.tip.water") },
        { tonumber(types.NUTRIENT) or 4, T("grow.tip.nutrient") },
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
                lines[#lines + 1] = T("grow.tip.icon_name", { icon = icon, name = name })
            else
                lines[#lines + 1] = T("grow.tip.additive", { kind = order[i][2], name = name })
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

function Grow._HarvestTooltipEnsureRows()
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

function Grow._HarvestTooltipGetPlotEntries()
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
                    seedText = T("grow.tip.icon_name", { icon = icon, name = name })
                end
                local entry = {
                    title = { text = T("grow.tip.plot_n", { n = tostring(plotNum) }) },
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
            text = T("grow.tip.no_plants"),
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
        applyTooltipTextRow(row, entry.text or T("grow.tip.no_plants"))
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

function Grow._HarvestTooltipApplyPlotRows(startRow)
    if not Tooltips or type(Tooltips.SetTooltipText) ~= "function" then
        return tonumber(startRow) or 1
    end
    startRow = tonumber(startRow) or 1
    local entries = Grow.GetPlotTooltipEntries()
    if #entries == 0 or (entries[1] and entries[1].noPlants == true) then
        Tooltips.SetTooltipText(startRow, 1, T("grow.tip.no_plants"), false)
        setTooltipBodyColor(startRow, 1)
        return startRow + 1
    end
    Tooltips.SetTooltipText(startRow, 1, T("grow.tip.growing_header"), false)
    setTooltipBodyColor(startRow, 1)
    startRow = startRow + 1
    for i = 1, #entries do
        startRow = ApplyPlotTooltipRow(startRow, entries[i])
    end
    return startRow
end

--- Multi-row harvest tooltip for the Watch footer Harvest button.
--- liveRefresh=true skips re-register (used while mouse stays over the button).
function Grow._HarvestTooltipShow(anchorWindow, anchor, liveRefresh)
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
        Tooltips.SetTooltipText(1, 1, T("grow.tip.title_icon", { icon = titleIcon }))
    else
        Tooltips.SetTooltipText(1, 1, T("grow.tip.title"))
    end
    local heading = (Tooltips and Tooltips.COLOR_HEADING) or { r = 255, g = 204, b = 102 }
    setTooltipRowColor(1, 1, heading)

    local Caps = StockPiler2.TradeSkillCaps
    local hasCult = Caps and Caps.HasCultivation and Caps.HasCultivation() == true
    if not hasCult then
        local text = T("grow.tip.need_cult")
        local gather = Caps and Caps.GatheringLabel and Caps.GatheringLabel()
        if gather ~= nil and gather ~= T("plan.fallback.cultivation") then
            text = text .. T("grow.tip.gathers_via", { gather = gather })
        end
        Tooltips.SetTooltipText(2, 1, text)
        local warn = (Tooltips and Tooltips.COLOR_WARNING) or { r = 220, g = 120, b = 120 }
        setTooltipRowColor(2, 1, warn)
        Tooltips.Finalize()
        Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)
        local tip = Grow._liveHarvestTip
        if tip and tip.anchor == anchorWindow then
            tip.fingerprint = Grow.HarvestTooltipFingerprint()
        end
        return
    end

    local readyN = Grow.CountReadyHarvestPlots and Grow.CountReadyHarvestPlots() or 0
    local brewBlocks = StockPiler2.Brew
        and StockPiler2.Brew.BlocksHarvest
        and StockPiler2.Brew.BlocksHarvest() == true
    if brewBlocks then
        Tooltips.SetTooltipText(2, 1, T("grow.tip.held_brew"))
    else
        local ready = (tonumber(readyN) or 0) > 0 and T("grow.tip.ready") or T("grow.tip.not_ready")
        Tooltips.SetTooltipText(2, 1, T("grow.tip.click_harvest", { ready = ready }))
    end
    setTooltipBodyColor(2, 1)

    local agOn = Grow.IsEnabled and Grow.IsEnabled() == true
    local ag = agOn and T("grow.tip.autogrow_on") or T("grow.tip.autogrow_off")
    local agIcon = agOn and L"<icon00057>" or L"<icon00058>"
    Tooltips.SetTooltipText(3, 1, T("grow.tip.autogrow_state", { icon = agIcon, state = ag }))
    setTooltipBodyColor(3, 1)

    local nextRow = 4
    local SM = StockPiler2.SeedMap
    if SM and SM.FormatHarvestTooltipRateLines then
        local seen = {}
        local CA = StockPiler2.CultivatorAdapter
        local n = CA and CA.NumPlots and CA.NumPlots() or 4
        local tipPlots = Grow._liveHarvestTip and Grow._liveHarvestTip.plots
        for plotNum = 1, n do
            local plot = type(tipPlots) == "table" and tipPlots[plotNum] or nil
            if type(plot) ~= "table" and CA and CA.ReadPlot then
                plot = CA.ReadPlot(plotNum)
            end
            local seedUid = 0
            local plantUid = 0
            if type(plot) == "table" then
                seedUid = tonumber(plot.seedUid) or 0
                plantUid = tonumber(plot.plantUid) or 0
                if seedUid <= 0 and type(plot.seed) == "table" then
                    seedUid = tonumber(plot.seed.uniqueID) or 0
                end
            end
            if seedUid > 0 and seen[seedUid] ~= true then
                seen[seedUid] = true
                local rateLines = SM.FormatHarvestTooltipRateLines(seedUid, plantUid)
                if type(rateLines) == "table" then
                    for ri = 1, #rateLines do
                        if rateLines[ri] and rateLines[ri] ~= "" then
                            Tooltips.SetTooltipText(nextRow, 1, towstring(rateLines[ri]), false)
                            setTooltipBodyColor(nextRow, 1)
                            nextRow = nextRow + 1
                        end
                    end
                end
            end
        end
    end

    Grow.ApplyPlotTooltipRows(nextRow)
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

function Grow._HarvestTooltipSyncPlotsFromEngine()
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

function Grow._HarvestTooltipRegisterLive(anchorWindow, anchorPoint)
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

function Grow._HarvestTooltipClearLive()
    local tip = Grow._liveHarvestTip
    if tip then
        tip.kind = nil
        tip.anchor = nil
        tip.anchorPoint = nil
        tip.fingerprint = nil
        tip.plots = nil
    end
end

function Grow._HarvestTooltipFingerprint()
    local parts = {}
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    local tipPlots = Grow._liveHarvestTip and Grow._liveHarvestTip.plots
    local seedParts = {}
    for plotNum = 1, n do
        local plot = type(tipPlots) == "table" and tipPlots[plotNum] or nil
        if type(plot) ~= "table" and CA and CA.ReadPlot then
            plot = CA.ReadPlot(plotNum)
        end
        if type(plot) == "table" then
            local stage = Grow.NormalizeStage(plot.stage)
            if stage ~= Grow.StageEmpty() then
                local seedUid = tonumber(plot.seedUid) or 0
                parts[#parts + 1] = plotNum .. ":"
                    .. tostring(stage) .. ":"
                    .. tostring(math.floor(tonumber(plot.totalTimer) or 0)) .. ":"
                    .. tostring(math.floor(tonumber(plot.stageTimer) or 0)) .. ":"
                    .. tostring(seedUid)
                if seedUid > 0 then
                    local hits = 0
                    local attempts = 0
                    local SM = StockPiler2.SeedMap
                    if SM and SM.CultSkillUpRate then
                        local rate, h, a = SM.CultSkillUpRate(seedUid)
                        hits = tonumber(h) or 0
                        attempts = tonumber(a) or 0
                        if rate == nil and SM.FormatHarvestRateLine then
                            -- Still fingerprint harvest attempts via rate line presence.
                            attempts = attempts
                        end
                    end
                    seedParts[#seedParts + 1] = tostring(seedUid) .. ":" .. tostring(hits) .. ":" .. tostring(attempts)
                end
            end
        end
    end
    parts[#parts + 1] = (Grow.IsEnabled and Grow.IsEnabled() == true) and "ag1" or "ag0"
    local Caps = StockPiler2.TradeSkillCaps
    local hasCult = Caps and Caps.HasCultivation and Caps.HasCultivation() == true
    parts[#parts + 1] = hasCult and "cult1" or "cult0"
    local readyN = Grow.CountReadyHarvestPlots and Grow.CountReadyHarvestPlots() or 0
    parts[#parts + 1] = ((tonumber(readyN) or 0) > 0) and "rdy" or "wait"
    local brewBlocks = StockPiler2.Brew
        and StockPiler2.Brew.BlocksHarvest
        and StockPiler2.Brew.BlocksHarvest() == true
    parts[#parts + 1] = brewBlocks and "brewHold" or "brewOk"
    if #seedParts > 0 then
        parts[#parts + 1] = "seeds=" .. table.concat(seedParts, ",")
    end
    return table.concat(parts, "|")
end

function Grow._HarvestTooltipMaybeRefresh(force)
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
function Grow._HarvestTooltipTickLive(timeElapsed)
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

-- One-release compatibility forwards; tooltip rendering is owned by HarvestTooltip.
function Grow.EnsureHarvestTooltipRows()
    return StockPiler2.HarvestTooltip.EnsureRows()
end

function Grow.GetPlotTooltipEntries()
    return StockPiler2.HarvestTooltip.GetPlotEntries()
end

function Grow.ApplyPlotTooltipRows(startRow)
    return StockPiler2.HarvestTooltip.ApplyPlotRows(startRow)
end

function Grow.ShowHarvestTooltip(anchorWindow, anchor, liveRefresh)
    return StockPiler2.HarvestTooltip.Show(anchorWindow, anchor, liveRefresh)
end

function Grow.RegisterHarvestLiveTooltip(anchorWindow, anchorPoint)
    return StockPiler2.HarvestTooltip.RegisterLive(anchorWindow, anchorPoint)
end

function Grow.SyncHarvestTipPlotsFromEngine()
    return StockPiler2.HarvestTooltip.SyncPlotsFromEngine()
end

function Grow.ClearHarvestLiveTooltip()
    return StockPiler2.HarvestTooltip.ClearLive()
end

function Grow.HarvestTooltipFingerprint()
    return StockPiler2.HarvestTooltip.Fingerprint()
end

function Grow.MaybeRefreshHarvestTooltip(force)
    return StockPiler2.HarvestTooltip.MaybeRefresh(force)
end

function Grow.TickHarvestLiveTooltip(timeElapsed)
    return StockPiler2.HarvestTooltip.TickLive(timeElapsed)
end
