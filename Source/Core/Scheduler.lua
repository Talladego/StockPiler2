----------------------------------------------------------------
-- StockPiler2 Core/Scheduler — coalesce heavy work, frame budgets
----------------------------------------------------------------

StockPiler2.Scheduler = StockPiler2.Scheduler or {}
local Sch = StockPiler2.Scheduler

Sch.BAG_COALESCE_SEC = 2.0
Sch.PLAN_MAX_WAIT_SEC = 0.5
-- While AutoGrow has work (empty plots / no-job thrash), coalesce plan rebuilds longer.
Sch.PLAN_COALESCE_WHEN_AWAKE_SEC = 3.0
Sch.AUTO_TICK_SEC = 1.0
Sch.AUTO_TICK_BURST_SEC = 1.5
Sch.AUTO_TICK_IDLE_SEC = 5.0

Sch._bagDue = false
Sch._bagAt = 0
Sch._bagNeedQueue = false
Sch._planDue = false
Sch._planAt = 0
Sch._autoAccum = 0
Sch._autoGrowFast = true
Sch._suppressInvTicks = 0
Sch._initialized = false
Sch._lastDeferBagLogAt = 0
Sch._lastDeferBagReason = nil
Sch.DEFER_BAG_LOG_SEC = 5.0

local function Now()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function PlayerCombatOrScenarioDefer()
    local player = GameData and GameData.Player
    if type(player) ~= "table" then
        return false, nil
    end
    if player.inCombat == true or player.isInRvRLake == true then
        return true, "combat-rvr"
    end
    if player.isInScenario == true then
        return true, "scenario"
    end
    return false, nil
end

local function HarvestOrBrewDefer()
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsHarvestActive then
        if StockPiler2.Orchestrator.IsHarvestActive() then
            return true, "harvest"
        end
    end
    local Orch = StockPiler2.Orchestrator
    if Orch and Orch._brewPhase == "loading" then
        return true, "brew-loading"
    end
    if StockPiler2.Brew and StockPiler2.Brew.IsBusy and StockPiler2.Brew.IsBusy() == true then
        return true, "brew-busy"
    end
    return false, nil
end

--- Expensive bag Flatten — deferred in combat/RvR/scenario (and harvest/brew busy).
function Sch.ShouldDeferBagFlush()
    local defer, reason = PlayerCombatOrScenarioDefer()
    if defer then
        return true, reason
    end
    return HarvestOrBrewDefer()
end

--- Plan rebuild — NOT deferred in combat (AutoGrow + Watch need live plan).
--- Still deferred during harvest / brew loading|busy.
function Sch.ShouldDeferPlanRebuild()
    return HarvestOrBrewDefer()
end

--- Compatibility: same as bag-flush defer (combat + harvest/brew).
function Sch.ShouldDeferHeavyWork()
    return Sch.ShouldDeferBagFlush()
end

--- True when bag flush is pending and should run before orch (not combat-held).
function Sch.BagFlushBlocksOrchestrator()
    if Sch._bagDue ~= true then
        return false
    end
    local deferBag = Sch.ShouldDeferBagFlush()
    -- Combat/scenario-held flush must not stall AutoGrow orch ticks.
    return deferBag ~= true
end

function Sch.IsInventorySideEffectsSuppressed()
    return (tonumber(Sch._suppressInvTicks) or 0) > 0
end

function Sch.SuppressInventorySideEffects(ticks)
    ticks = tonumber(ticks) or 2
    if ticks < 1 then
        ticks = 1
    end
    local cur = tonumber(Sch._suppressInvTicks) or 0
    if ticks > cur then
        Sch._suppressInvTicks = ticks
    end
end

local function DecaySuppressInventorySideEffects()
    local n = tonumber(Sch._suppressInvTicks) or 0
    if n > 0 then
        Sch._suppressInvTicks = n - 1
    end
end

function Sch.BagWorkPending()
    return Sch._bagDue == true
end

function Sch.EnqueueBagFlush(needQueue)
    if Sch.IsInventorySideEffectsSuppressed() then
        return
    end
    local now = Now()
    if Sch._bagDue == true then
        if needQueue == true then
            Sch._bagNeedQueue = true
        end
        return
    end
    Sch._bagDue = true
    Sch._bagAt = now + Sch.BAG_COALESCE_SEC
    if needQueue == true then
        Sch._bagNeedQueue = true
    end
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("perf", "enqueue bag-flush in " .. tostring(Sch.BAG_COALESCE_SEC) .. "s")
    end
end

function Sch.EnqueuePlanRebuild()
    if Sch.IsInventorySideEffectsSuppressed() then
        return
    end
    local now = Now()
    local wait = tonumber(Sch.PLAN_MAX_WAIT_SEC) or 0.5
    -- Empty-plot AutoGrow used to pull _planAt earlier on every snap (+1 snapGen
    -- per rebuild). Use a longer first delay and never pull the deadline earlier.
    if Sch.ShouldWakeAutoGrow() then
        wait = tonumber(Sch.PLAN_COALESCE_WHEN_AWAKE_SEC) or 3.0
    end
    Sch._planDue = true
    if Sch._planAt <= 0 then
        Sch._planAt = now + wait
    end
end

function Sch.IsPlanRebuildPending()
    return Sch._planDue == true
end

function Sch.ShouldWakeAutoGrow()
    local Watch = StockPiler2.Watch
    if not Watch or not Watch.IsAutoGrowEnabled or Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local Grow = StockPiler2.Grow
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive() then
        return true
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
    if Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true then
        return true
    end
    return false
end

function Sch.WakeAutoGrow()
    if StockPiler2.Grow and StockPiler2.Grow.ClearFillBlocked then
        StockPiler2.Grow.ClearFillBlocked()
    end
    Sch._autoGrowFast = true
end

function Sch.WakeAutoBuy()
    -- Nudge next auto tick so AutoBuy can purchase without waiting for idle interval.
    Sch._autoAccum = math.max(tonumber(Sch._autoAccum) or 0, Sch.AUTO_TICK_SEC)
end

function Sch.SetAutoGrowIdle(idle)
    Sch._autoGrowFast = idle ~= true
end

local function AutoTickIntervalSec()
    local Watch = StockPiler2.Watch
    if Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() then
        local Grow = StockPiler2.Grow
        if Grow and Grow.IsFillBlocked and Grow.IsFillBlocked() then
            return Sch.AUTO_TICK_IDLE_SEC
        end
        if Sch._autoGrowFast == true then
            if Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() then
                return Sch.AUTO_TICK_BURST_SEC
            end
            return Sch.AUTO_TICK_SEC
        end
        return Sch.AUTO_TICK_IDLE_SEC
    end
    return Sch.AUTO_TICK_SEC
end

local function LogDeferBagOnce(reason)
    if not (StockPiler2.Debug and StockPiler2.Debug.Enabled == true and StockPiler2.Debug.LogOp) then
        return
    end
    local now = Now()
    local lastAt = tonumber(Sch._lastDeferBagLogAt) or 0
    local lastReason = Sch._lastDeferBagReason
    local gap = tonumber(Sch.DEFER_BAG_LOG_SEC) or 5
    if reason == lastReason and lastAt > 0 and (now - lastAt) < gap then
        return
    end
    Sch._lastDeferBagLogAt = now
    Sch._lastDeferBagReason = reason
    StockPiler2.Debug.LogOp("perf", "defer bag-flush reason=" .. tostring(reason))
end

local function FlushBagIfDue()
    if Sch._bagDue ~= true then
        return false
    end
    local defer, reason = Sch.ShouldDeferBagFlush()
    if defer then
        Sch._bagAt = Now() + Sch.BAG_COALESCE_SEC
        LogDeferBagOnce(reason)
        return false
    end
    if Now() < (tonumber(Sch._bagAt) or 0) then
        return false
    end
    Sch._bagDue = false
    local Inv = StockPiler2.Inventory
    if not Inv or not Inv.Flush then
        return false
    end
    local needQueue = Sch._bagNeedQueue == true
    Sch._bagNeedQueue = false
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("BagFlush")
    end
    Inv.Flush({ forceEngine = false })
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("BagFlush")
    end
    if needQueue then
        Sch.EnqueuePlanRebuild()
    end
    return true
end

local function RebuildPlanIfDue()
    if Sch._planDue ~= true then
        return false
    end
    local defer, reason = Sch.ShouldDeferPlanRebuild()
    if defer then
        -- Hold deadline; do not clear _planDue (SP1: flush/plan wait out harvest storm).
        Sch._planAt = Now() + (tonumber(Sch.PLAN_MAX_WAIT_SEC) or 0.5)
        return false
    end
    if Now() < (tonumber(Sch._planAt) or 0) then
        return false
    end
    local Planner = StockPiler2.Planner
    local PS = StockPiler2.PlanSnapshot
    if Planner and Planner.CacheKeyFromGens and PS and PS.GetCacheKey then
        if PS.GetCacheKey() == Planner.CacheKeyFromGens() then
            local cached = PS.Get and PS.Get()
            if type(cached) == "table" then
                Sch._planDue = false
                Sch._planAt = 0
                return false
            end
        end
    end
    Sch._planDue = false
    Sch._planAt = 0
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("PlanRebuild")
    end
    if Planner then
        if Planner.GetOrBuild then
            Planner.GetOrBuild()
        elseif Planner.Build then
            Planner.Build()
        end
    end
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("PlanRebuild")
    end
    return true
end

local function HasAutoGrowWork()
    local Watch = StockPiler2.Watch
    if not Watch or not Watch.IsAutoGrowEnabled or Watch.IsAutoGrowEnabled() ~= true then
        return false
    end
    local Grow = StockPiler2.Grow
    -- Must match Orchestrator: Water/Nutrient stages need ticks after plots are full.
    if Grow and Grow.NeedsCurrentStageAdditive and Grow.NeedsCurrentStageAdditive() then
        return true
    end
    if Grow and Grow.IsFillBlocked and Grow.IsFillBlocked() then
        local RP = StockPiler2.RefinePipeline
        if RP and RP.HasOutstanding and RP.HasOutstanding() then
            return true
        end
        -- Still tick slowly so plant-wait cooldown can decay.
        return true
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
    -- Cheap gate: cached buffer pending (do not call full ShouldAllowRefineNow here).
    if Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true then
        return true
    end
    return false
end

local function ShouldRunOrchestratorTick()
    if Sch._skipOrchThisFrame == true then
        return false
    end
    local Watch = StockPiler2.Watch
    if Watch and Watch.IsAutoBuyEnabled and Watch.IsAutoBuyEnabled() == true then
        if StockPiler2.Buy and StockPiler2.Buy.NeedsTick and StockPiler2.Buy.NeedsTick() then
            return true
        end
    end
    if Watch and Watch.IsAutoGrowEnabled and Watch.IsAutoGrowEnabled() then
        return HasAutoGrowWork()
    end
    local RP = StockPiler2.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() then
        return true
    end
    if StockPiler2.Orchestrator then
        if StockPiler2.Orchestrator.IsHarvestActive
            and StockPiler2.Orchestrator.IsHarvestActive()
        then
            return true
        end
        if StockPiler2.Orchestrator.IsBrewSessionActive
            and StockPiler2.Orchestrator.IsBrewSessionActive()
        then
            return true
        end
    end
    return false
end

--- Fill-blocked + refine wait: decay ticks only — skip expensive Orch plant/refine rebuild.
local function ShouldSkipOrchIdleWait()
    local Grow = StockPiler2.Grow
    if not (Grow and Grow.IsFillBlocked and Grow.IsFillBlocked() == true) then
        return false
    end
    if StockPiler2.Buy and StockPiler2.Buy.NeedsTick and StockPiler2.Buy.NeedsTick() == true then
        return false
    end
    local Orch = StockPiler2.Orchestrator
    if Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true then
        return false
    end
    if Orch and Orch.IsHarvestActive and Orch.IsHarvestActive() == true then
        return false
    end
    local RP = StockPiler2.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        return false
    end
    local Refine = StockPiler2.Refine
    if Refine and Refine._refineDirty == true and Refine._refineDirtyReason == "harvest" then
        return false
    end
    local wait = Refine and tonumber(Refine._refineWaitTicks) or 0
    return wait > 0
end

--- One-frame skip after brew-learn drain (same UPDATE_PROCESSED hitch).
function Sch.SkipOrchThisFrame()
    Sch._skipOrchThisFrame = true
end

function Sch.OnUpdate(timeElapsed)
    if StockPiler2.Buy and StockPiler2.Buy.PollStorePresence then
        StockPiler2.Buy.PollStorePresence()
    end
    if StockPiler2.Grow and StockPiler2.Grow.ExpireStalePending then
        StockPiler2.Grow.ExpireStalePending()
    end
    if StockPiler2.Grow and StockPiler2.Grow.TickHarvestLiveTooltip then
        StockPiler2.Grow.TickHarvestLiveTooltip(timeElapsed)
    end
    if StockPiler2.Brew and StockPiler2.Brew.OnUpdate then
        StockPiler2.Brew.OnUpdate(timeElapsed)
    end
    if StockPiler2Window and StockPiler2Window.FlushPendingListRepopulate
        and DoesWindowExist("StockPiler2Window")
        and WindowGetShowing("StockPiler2Window") == true
    then
        StockPiler2Window.FlushPendingListRepopulate()
    end
    if StockPiler2.Brew and StockPiler2.Brew.TickBrewLiveTooltip then
        StockPiler2.Brew.TickBrewLiveTooltip(timeElapsed)
    end
    DecaySuppressInventorySideEffects()
    local didHeavy = false
    if FlushBagIfDue() then
        didHeavy = true
    end
    if not didHeavy and RebuildPlanIfDue() then
        didHeavy = true
    end
    if StockPiler2.Ui and StockPiler2.Ui.FlushWatchUiIfDirty then
        StockPiler2.Ui.FlushWatchUiIfDirty()
    end
    Sch._autoAccum = (tonumber(Sch._autoAccum) or 0) + (tonumber(timeElapsed) or 0)
    local tickSec = AutoTickIntervalSec()
    if Sch._autoAccum >= tickSec then
        Sch._autoAccum = Sch._autoAccum - tickSec
        -- Decay wait cooldowns even when orch is idle (otherwise Brew stays blocked).
        if StockPiler2.Refine and StockPiler2.Refine.DecayRefineWaitTicks then
            StockPiler2.Refine.DecayRefineWaitTicks()
        end
        if StockPiler2.Grow and StockPiler2.Grow.DecayPlantWaitTicks then
            StockPiler2.Grow.DecayPlantWaitTicks()
        end
        local skipOrch = Sch._skipOrchThisFrame == true or ShouldSkipOrchIdleWait()
        Sch._skipOrchThisFrame = false
        -- Combat-held bag flush must not block AutoGrow; only block when flush can run.
        local bagBlocksOrch = Sch.BagFlushBlocksOrchestrator and Sch.BagFlushBlocksOrchestrator() == true
        if not didHeavy and not skipOrch and not bagBlocksOrch and ShouldRunOrchestratorTick()
            and StockPiler2.Orchestrator and StockPiler2.Orchestrator.Tick then
            StockPiler2.Orchestrator.Tick()
        end
    else
        -- Learn drain may set skip mid-frame before the auto-tick interval elapses.
        Sch._skipOrchThisFrame = false
    end
end

function Sch.Initialize()
    if Sch._initialized == true then
        return
    end
    Sch._initialized = true
    local E = StockPiler2.Events
    local B = StockPiler2.EventBus
    if B and E then
        B.Subscribe(E.INVENTORY_DIRTY, function()
            -- coalesce already scheduled by InventoryStore.MarkDirty
        end)
        B.Subscribe(E.INVENTORY_SNAPSHOT, function()
            if StockPiler2.Buy and StockPiler2.Buy.OnInventorySnapshot then
                StockPiler2.Buy.OnInventorySnapshot()
            elseif StockPiler2.Buy and StockPiler2.Buy.InvalidateJobsCache then
                StockPiler2.Buy.InvalidateJobsCache()
            end
            -- Snap-only (SP1): update plant-job dirtiness / UI — do NOT EnqueuePlanRebuild.
            -- Plan rebuild is armed by bag flush needQueue, harvest wake, garden dirty, session.
            if StockPiler2.Grow and StockPiler2.Grow.MarkPlantJobDirty then
                StockPiler2.Grow.MarkPlantJobDirty()
            end
            if Sch.ShouldWakeAutoGrow() then
                Sch._autoGrowFast = true
            end
            if StockPiler2.Ui and StockPiler2.Ui.MarkWatchUiDirty then
                StockPiler2.Ui.MarkWatchUiDirty()
            end
        end)
        B.Subscribe(E.GARDEN_DIRTY, function()
            if Sch.ShouldWakeAutoGrow() then
                -- Already coalesced plan pending: skip Wake churn + re-enqueue.
                if Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true then
                    Sch._autoGrowFast = true
                    return
                end
                Sch.WakeAutoGrow()
                Sch.EnqueuePlanRebuild()
            elseif StockPiler2.Ui and StockPiler2.Ui.MarkWatchUiDirty then
                StockPiler2.Ui.MarkWatchUiDirty()
            end
        end)
        B.Subscribe(E.SESSION_LOADED, function()
            Sch.EnqueueBagFlush(true)
            if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Invalidate then
                StockPiler2.PlanSnapshot.Invalidate()
            end
            if Sch.EnqueuePlanRebuild then
                Sch.EnqueuePlanRebuild()
            end
            if StockPiler2TabWatch and StockPiler2TabWatch.RefreshSkillGates then
                StockPiler2TabWatch.RefreshSkillGates()
            end
            -- Window may stay open across reload (savesettings) without a second OnShow.
            -- Skill gates alone leave Watch stock/craftable/status from the pre-bag paint.
            if StockPiler2.Ui then
                StockPiler2.Ui._watchUiLastKey = nil
                StockPiler2.Ui._watchUiFlushedAt = 0
                if StockPiler2.Ui.MarkWatchUiDirty then
                    StockPiler2.Ui.MarkWatchUiDirty()
                end
            end
            if StockPiler2Window then
                StockPiler2Window._tabListsPrimed = false
            end
            if DoesWindowExist("StockPiler2Window")
                and WindowGetShowing("StockPiler2Window") == true
            then
                -- Session load: rebuild L0 from warm DataUtils; forceEngine only via ForceFullRefresh.
                if StockPiler2.Inventory and StockPiler2.Inventory.Flush then
                    StockPiler2.Inventory.Flush({ force = true, forceEngine = false })
                end
                if StockPiler2.Planner and StockPiler2.Planner.GetOrBuild then
                    StockPiler2.Planner.GetOrBuild()
                end
                if StockPiler2Window.RefreshActiveTab then
                    StockPiler2Window.RefreshActiveTab()
                elseif StockPiler2Window.RefreshFooterButtons then
                    StockPiler2Window.RefreshFooterButtons()
                end
            elseif StockPiler2Window and StockPiler2Window.RefreshFooterButtons then
                StockPiler2Window.RefreshFooterButtons()
            end
        end)
    end
end

function Sch.Shutdown()
    Sch._initialized = false
end
