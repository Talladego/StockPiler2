----------------------------------------------------------------
-- StockPiler2 Core/Orchestrator — phase FSM + command dispatch
----------------------------------------------------------------

StockPiler2.Orchestrator = StockPiler2.Orchestrator or {}
local Orch = StockPiler2.Orchestrator

Orch.Phase = "idle"
Orch._brewPhase = nil
Orch._lastOpId = 0
Orch._initialized = false

function Orch.GetPhase()
    return tostring(Orch.Phase or "idle")
end

--- Harvest lifecycle lives in Grow op-lock / harvest storm (Scheduler), not Orch phase.
function Orch.IsHarvestActive()
    if StockPiler2.Grow and StockPiler2.Grow.IsHarvestOpActive then
        return StockPiler2.Grow.IsHarvestOpActive() == true
    end
    return false
end

function Orch.IsBrewSessionActive()
    return Orch._brewPhase == "loading" or Orch._brewPhase == "loaded"
end

function Orch.OnAutoGrowDisabled()
    Orch.Phase = "idle"
    if StockPiler2.Grow and StockPiler2.Grow.ClearFillBlocked then
        StockPiler2.Grow.ClearFillBlocked()
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
        StockPiler2.Scheduler.SetAutoGrowIdle(true)
    end
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("orch", "autogrow-off->idle")
    end
end

local function HasAutoGrowWork()
    local Watch = StockPiler2.Watch
    if not Watch or not Watch.IsAutoGrowEnabled or Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local Grow = StockPiler2.Grow
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive() then
        return true
    end
    if Grow and Grow.IsFillBlocked and Grow.IsFillBlocked() then
        local RP = StockPiler2.RefinePipeline
        if RP and RP.HasOutstanding and RP.HasOutstanding() then
            return true
        end
        return false
    end
    local RP = StockPiler2.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() then
        return true
    end
    if Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() then
        return true
    end
    local Refine = StockPiler2.Refine
    if Refine and Refine._refineDirty == true then
        return true
    end
    -- Cheap gate: cached buffer pending (full ShouldAllowRefineNow only on refine path).
    if Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true then
        return true
    end
    return false
end

local function HasAutoBuyWork()
    return StockPiler2.Buy and StockPiler2.Buy.NeedsTick and StockPiler2.Buy.NeedsTick() == true
end

local function SetPhase(phase, reason)
    phase = tostring(phase or "idle")
    if Orch.Phase == phase then
        return
    end
    local prev = Orch.Phase
    Orch.Phase = phase
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("orch", string.format("%s->%s reason=%s", prev, phase, tostring(reason or "?")))
    end
    local B = StockPiler2.EventBus
    local E = StockPiler2.Events
    if B and E and E.PHASE_CHANGED then
        B.Fire(E.PHASE_CHANGED, { phase = phase, prev = prev, reason = reason })
    end
end

local function TryBuyTick(opId)
    if not HasAutoBuyWork() then
        return false
    end
    if StockPiler2.BuyExecutor and StockPiler2.BuyExecutor.Tick then
        if StockPiler2.BuyExecutor.Tick(opId) == true then
            SetPhase("buying", "auto")
            if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoBuy then
                StockPiler2.Scheduler.WakeAutoBuy()
            end
            return true
        end
    elseif StockPiler2.Buy and StockPiler2.Buy.OnTick then
        if StockPiler2.Buy.OnTick() == true then
            SetPhase("buying", "auto")
            return true
        end
    end
    return false
end

function Orch.NewOpId()
    if StockPiler2.Debug and StockPiler2.Debug.NextOpId then
        Orch._lastOpId = StockPiler2.Debug.NextOpId()
    else
        Orch._lastOpId = (tonumber(Orch._lastOpId) or 0) + 1
    end
    return Orch._lastOpId
end

function Orch.DispatchCommand(kind, payload)
    kind = tostring(kind or "")
    payload = type(payload) == "table" and payload or {}
    local opId = Orch.NewOpId()
    if kind == "harvest" then
        SetPhase("harvesting", "user-macro")
        if StockPiler2.GrowExecutor and StockPiler2.GrowExecutor.Harvest then
            StockPiler2.GrowExecutor.Harvest(opId)
        end
        if Orch.Phase == "harvesting" then
            SetPhase("idle", "harvest-done")
        end
        if StockPiler2.Scheduler then
            StockPiler2.Scheduler.EnqueueBagFlush(true)
        end
        return true
    elseif kind == "brew.perform" then
        if StockPiler2.BrewExecutor and StockPiler2.BrewExecutor.TryPerform then
            StockPiler2.BrewExecutor.TryPerform(opId)
        end
        return true
    end
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("work", "unknown cmd=" .. kind .. " opId=" .. tostring(opId))
    end
    return false
end

function Orch.Tick()
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("Orchestrator.Tick")
    end
    if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.BeginOrchTick then
        StockPiler2.RecipeSpec.BeginOrchTick()
    end
    -- 0.4.132: one GetPlantJob / PickPlantCandidate per Tick.
    if StockPiler2.Grow and StockPiler2.Grow.BeginOrchTickPlantMemo then
        StockPiler2.Grow.BeginOrchTickPlantMemo()
    end
    local autoGrowOn = StockPiler2.Watch and StockPiler2.Watch.IsAutoGrowEnabled
        and StockPiler2.Watch.IsAutoGrowEnabled() == true
    if not autoGrowOn then
        -- Reconcile is owned by Refine.OnUpdateProcessed (frame-gated).
        -- AutoBuy is independent of AutoGrow (vendor open + shortages).
        if TryBuyTick(Orch.NewOpId()) then
            if StockPiler2.Perf and StockPiler2.Perf.End then
                StockPiler2.Perf.End("Orchestrator.Tick")
            end
            return
        end
        if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
            SetPhase("idle", "autogrow-off")
        end
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Orchestrator.Tick")
        end
        return
    end
    if StockPiler2.Grow and StockPiler2.Grow.IsFillBlocked and StockPiler2.Grow.IsFillBlocked() then
        -- Still allow seed-buffer refine while planting is fill-blocked.
        local Refine = StockPiler2.Refine
        local bufferRefine = StockPiler2.Grow.HasPendingBufferRefine
            and StockPiler2.Grow.HasPendingBufferRefine() == true
        if bufferRefine and Refine and Refine.ShouldAllowRefineNow and Refine.ShouldAllowRefineNow() == true
            and Refine.RefineCheckDue and Refine.RefineCheckDue() == true
            and StockPiler2.RefineExecutor and StockPiler2.RefineExecutor.Tick
        then
            if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
                StockPiler2.Scheduler.SetAutoGrowIdle(false)
            end
            local opId = Orch.NewOpId()
            local ok = StockPiler2.RefineExecutor.Tick(opId, nil)
            if ok == true then
                SetPhase("refining", "seed-buffer")
                if StockPiler2.Grow.SetFillBlocked then
                    StockPiler2.Grow.SetFillBlocked(false)
                end
                if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
                    StockPiler2.Scheduler.WakeAutoGrow()
                end
                if StockPiler2.Perf and StockPiler2.Perf.End then
                    StockPiler2.Perf.End("Orchestrator.Tick")
                end
                return
            end
        end
        if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
            StockPiler2.Scheduler.SetAutoGrowIdle(true)
        end
        if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
            SetPhase("idle", "fill-blocked")
        end
        -- Fill-blocked grow: still allow AutoBuy if a vendor is open (under Tick trail).
        TryBuyTick(Orch.NewOpId())
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Orchestrator.Tick")
        end
        return
    end
    local needBuy = HasAutoBuyWork()
    -- Post-harvest plant quiet / harvest storm: return before HasAutoGrowWork so
    -- BufferFlags / seed-line probes do not run on held ticks (0.4.117). Keep fast
    -- ticks but do not probe/plant/refine/fill-block. Quiet alone used to end at
    -- 0.75s while storm lasted 1.5s — Orch then ran BufferFlags+CollectAutoGrowSeedLines
    -- +Refine.TryTick mid-storm. Also require storm when canPlant is false (soft wake
    -- before empties). Do not revert to probing HasAutoGrowWork first.
    local plantQuiet = StockPiler2.Grow
        and StockPiler2.Grow.IsPlantQuiet
        and StockPiler2.Grow.IsPlantQuiet() == true
    local harvestStorm = StockPiler2.Scheduler
        and StockPiler2.Scheduler.IsHarvestStormActive
        and StockPiler2.Scheduler.IsHarvestStormActive() == true
    if plantQuiet or harvestStorm then
        if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
            StockPiler2.Scheduler.SetAutoGrowIdle(false)
        end
        TryBuyTick(Orch.NewOpId())
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Orchestrator.Tick")
        end
        return
    end
    -- 0.4.126: brew session — skip AutoGrow probes (PickPlant / BufferFlags) mid-brew.
    -- Plant/refine already no-op when session active; still allow AutoBuy.
    if Orch.IsBrewSessionActive() == true then
        if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
            StockPiler2.Scheduler.SetAutoGrowIdle(false)
        end
        TryBuyTick(Orch.NewOpId())
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Orchestrator.Tick")
        end
        return
    end
    if not HasAutoGrowWork() then
        if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
            StockPiler2.Scheduler.SetAutoGrowIdle(true)
        end
        if needBuy then
            local opId = Orch.NewOpId()
            if TryBuyTick(opId) then
                if StockPiler2.Perf and StockPiler2.Perf.End then
                    StockPiler2.Perf.End("Orchestrator.Tick")
                end
                return
            end
        end
        if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
            SetPhase("idle", "idle-grow")
        end
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Orchestrator.Tick")
        end
        return
    end
    local refineDue = false
    local canPlant = false
    if StockPiler2.Grow and StockPiler2.Grow.HasEmptyPlot and StockPiler2.Grow.HasEmptyPlot() then
        canPlant = true
    end
    local hasSeeds = false
    if canPlant and StockPiler2.Grow and StockPiler2.Grow.HasSeedsForNextPlant then
        hasSeeds = StockPiler2.Grow.HasSeedsForNextPlant() == true
    end
    local opId = Orch.NewOpId()
    local needAdditives = StockPiler2.Grow and StockPiler2.Grow.NeedsCurrentStageAdditive
        and StockPiler2.Grow.NeedsCurrentStageAdditive() == true
    -- Stay in fast AutoGrow only when there is plantable work or additives.
    if (canPlant and hasSeeds) or needAdditives then
        if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
            StockPiler2.Scheduler.SetAutoGrowIdle(false)
        end
    end
    -- Plant-first: fill empty plots before any refine when seeds are ready.
    -- Skip plant (not refine) while Grown plots remain — mid-batch harvest gate.
    local holdHarvestBatch = StockPiler2.Grow
        and StockPiler2.Grow.ShouldHoldPlantForReadyHarvest
        and StockPiler2.Grow.ShouldHoldPlantForReadyHarvest() == true
    if canPlant and hasSeeds and holdHarvestBatch then
        if StockPiler2.Grow.LogSkipPlant then
            StockPiler2.Grow.LogSkipPlant("harvest-batch")
        end
        -- Stay awake so WakeAfterHarvest / last ready clear can plant promptly.
        if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
            StockPiler2.Scheduler.SetAutoGrowIdle(false)
        end
    elseif canPlant and hasSeeds then
        local Sch = StockPiler2.Scheduler
        local deferPlant, deferReason = false, nil
        if Sch and Sch.ShouldDeferAutoGrowPlant then
            deferPlant, deferReason = Sch.ShouldDeferAutoGrowPlant()
        end
        if deferPlant == true then
            -- Combat/scenario pause: soft skip — never fill-block (that stalled empty plots in RvR lake).
            if StockPiler2.Grow and StockPiler2.Grow.LogSkipPlant then
                StockPiler2.Grow.LogSkipPlant(tostring(deferReason or "combat"))
            end
            if Sch and Sch.SetAutoGrowIdle then
                Sch.SetAutoGrowIdle(false)
            end
        elseif StockPiler2.GrowExecutor and StockPiler2.GrowExecutor.Tick then
            local ok = StockPiler2.GrowExecutor.Tick(opId)
            if ok == true then
                SetPhase("planting", "auto")
                if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
                    StockPiler2.Scheduler.WakeAutoGrow()
                end
                if StockPiler2.Perf and StockPiler2.Perf.End then
                    StockPiler2.Perf.End("Orchestrator.Tick")
                end
                return
            end
            if StockPiler2.Grow and StockPiler2.Grow.LogSkipPlant then
                StockPiler2.Grow.LogSkipPlant("plant-failed")
            end
            if StockPiler2.Grow and StockPiler2.Grow.SetFillBlocked then
                StockPiler2.Grow.SetFillBlocked(true, 5)
            end
        end
    elseif needAdditives and StockPiler2.GrowExecutor and StockPiler2.GrowExecutor.TryAdditive then
        if StockPiler2.GrowExecutor.TryAdditive(opId) == true then
            SetPhase("planting", "additive")
            if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
                StockPiler2.Scheduler.WakeAutoGrow()
            end
            if StockPiler2.Perf and StockPiler2.Perf.End then
                StockPiler2.Perf.End("Orchestrator.Tick")
            end
            return
        end
    elseif canPlant and not hasSeeds and StockPiler2.Grow and StockPiler2.Grow.LogSkipPlant then
        StockPiler2.Grow.LogSkipPlant("no-job")
        local bufferPending = StockPiler2.Grow.HasPendingBufferRefine
            and StockPiler2.Grow.HasPendingBufferRefine() == true
        if bufferPending then
            -- Edge only: re-arm once per empty+buffer stretch so wait ticks throttle CollectIntents.
            if Orch._seedBufferRefineArmed ~= true
                and StockPiler2.Refine and StockPiler2.Refine.MarkRefineDue
            then
                Orch._seedBufferRefineArmed = true
                StockPiler2.Refine.MarkRefineDue("seed-buffer")
            end
            if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
                StockPiler2.Scheduler.SetAutoGrowIdle(false)
            end
        else
            Orch._seedBufferRefineArmed = false
            -- Buy-only remaining / buffer full: clear sticky fill-block (0.4.163).
            local bufferOk = StockPiler2.Grow.IsSeedBufferSatisfied
                and StockPiler2.Grow.IsSeedBufferSatisfied() == true
            if bufferOk then
                if StockPiler2.Grow.ClearFillBlocked then
                    StockPiler2.Grow.ClearFillBlocked()
                end
                if StockPiler2.Brew and StockPiler2.Brew.InvalidateCanBrewCache then
                    StockPiler2.Brew.InvalidateCanBrewCache()
                end
                if StockPiler2Window and StockPiler2Window.RequestFooterRefresh then
                    StockPiler2Window.RequestFooterRefresh()
                end
            end
            -- Empty plots but no plantable job: back off burst ticks until snap/garden/demand wake.
            if StockPiler2.Scheduler and StockPiler2.Scheduler.SetAutoGrowIdle then
                StockPiler2.Scheduler.SetAutoGrowIdle(true)
            end
        end
    else
        Orch._seedBufferRefineArmed = false
    end
    local Refine = StockPiler2.Refine
    if Refine and Refine.ShouldAllowRefineNow and Refine.ShouldAllowRefineNow() == true
        and Refine.RefineCheckDue and Refine.RefineCheckDue() == true
    then
        refineDue = true
    end
    if refineDue then
        if StockPiler2.RefineExecutor and StockPiler2.RefineExecutor.Tick then
            local ok = StockPiler2.RefineExecutor.Tick(opId, nil)
            if ok == true then
                SetPhase("refining", "auto")
                if StockPiler2.Grow and StockPiler2.Grow.MarkPlantJobDirty then
                    StockPiler2.Grow.MarkPlantJobDirty()
                end
                if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
                    StockPiler2.Scheduler.WakeAutoGrow()
                end
                if StockPiler2.Perf and StockPiler2.Perf.End then
                    StockPiler2.Perf.End("Orchestrator.Tick")
                end
                return
            end
            -- No issuable refine: re-probe plant; only fill-block when still no job.
            if canPlant and StockPiler2.Grow and StockPiler2.Grow.MarkPlantJobDirty then
                StockPiler2.Grow.MarkPlantJobDirty()
                if StockPiler2.Grow.HasSeedsForNextPlant then
                    hasSeeds = StockPiler2.Grow.HasSeedsForNextPlant() == true
                end
            end
            if canPlant and hasSeeds and not holdHarvestBatch then
                -- Inventory may have settled; try plant this tick instead of blocking.
                if StockPiler2.GrowExecutor and StockPiler2.GrowExecutor.Tick then
                    local planted = StockPiler2.GrowExecutor.Tick(opId)
                    if planted == true then
                        SetPhase("planting", "auto")
                        if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
                            StockPiler2.Scheduler.WakeAutoGrow()
                        end
                        if StockPiler2.Perf and StockPiler2.Perf.End then
                            StockPiler2.Perf.End("Orchestrator.Tick")
                        end
                        return
                    end
                end
            elseif canPlant and hasSeeds and holdHarvestBatch then
                -- Ready harvest batch still open; TryPlant would no-op — do not fill-block.
            elseif canPlant and not hasSeeds and StockPiler2.Grow then
                local bufferOk = StockPiler2.Grow.IsSeedBufferSatisfied
                    and StockPiler2.Grow.IsSeedBufferSatisfied() == true
                if bufferOk then
                    if StockPiler2.Grow.ClearFillBlocked then
                        StockPiler2.Grow.ClearFillBlocked()
                    end
                elseif StockPiler2.Grow.SetFillBlocked then
                    StockPiler2.Grow.SetFillBlocked(true, 5)
                end
            end
        end
    elseif canPlant and not hasSeeds and StockPiler2.Grow then
        local bufferOk = StockPiler2.Grow.IsSeedBufferSatisfied
            and StockPiler2.Grow.IsSeedBufferSatisfied() == true
        if bufferOk then
            if StockPiler2.Grow.ClearFillBlocked then
                StockPiler2.Grow.ClearFillBlocked()
            end
        elseif StockPiler2.Grow.SetFillBlocked then
            StockPiler2.Grow.SetFillBlocked(true, 5)
        end
    end
    -- After refine path: still try additives if plots are growing without them.
    if needAdditives and StockPiler2.GrowExecutor and StockPiler2.GrowExecutor.TryAdditive then
        if StockPiler2.GrowExecutor.TryAdditive(opId) == true then
            SetPhase("planting", "additive")
            if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
                StockPiler2.Scheduler.WakeAutoGrow()
            end
            if StockPiler2.Perf and StockPiler2.Perf.End then
                StockPiler2.Perf.End("Orchestrator.Tick")
            end
            return
        end
    end
    -- After grow/refine: one AutoBuy purchase if store open (SP1 tick order).
    if TryBuyTick(opId) then
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("Orchestrator.Tick")
        end
        return
    end
    if Orch.Phase ~= "idle" and not Orch.IsHarvestActive() and not Orch.IsBrewSessionActive() then
        SetPhase("idle", "tick-idle")
    end
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("Orchestrator.Tick")
    end
end

function Orch.DumpState(emit)
    emit = type(emit) == "function" and emit or function(msg) StockPiler2.Debug.Print(msg) end
    emit("=== StockPiler2 state ===")
    emit("phase=" .. Orch.GetPhase() .. " lastOpId=" .. tostring(Orch._lastOpId or 0))
    emit("harvestActive=" .. tostring(Orch.IsHarvestActive() == true))
    emit("brewPhase=" .. tostring(Orch._brewPhase or "none"))
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapshotMeta then
        local m = StockPiler2.Inventory.GetSnapshotMeta()
        emit(string.format("inventory snapGen=%d ready=%s dirty=%s", m.snapGen, tostring(m.ready), tostring(m.dirty)))
    end
    if StockPiler2.Garden then
        emit("gardenGen=" .. tostring(StockPiler2.Garden.GetGen and StockPiler2.Garden.GetGen() or 0))
    end
    if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Get then
        local plan = StockPiler2.PlanSnapshot.Get()
        if type(plan) == "table" then
            emit("planGen=" .. tostring(plan.planGen) .. " cacheKey=" .. tostring(plan.cacheKey))
        end
    end
    emit("=== end state ===")
end

function Orch.Initialize()
    if Orch._initialized == true then
        return
    end
    local E = StockPiler2.Events
    local B = StockPiler2.EventBus
    if not B or not E then
        return
    end
    Orch._initialized = true
    Orch._busTokens = Orch._busTokens or {}
    local tokens = Orch._busTokens
    tokens[#tokens + 1] = B.Subscribe(E.CMD_HARVEST, function()
        Orch.DispatchCommand("harvest", {})
    end)
    tokens[#tokens + 1] = B.Subscribe(E.CMD_BREW_PERFORM, function()
        Orch.DispatchCommand("brew.perform", {})
    end)
end

function Orch.Shutdown()
    local B = StockPiler2.EventBus
    local tokens = Orch._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Orch._busTokens = nil
    Orch._initialized = false
end
