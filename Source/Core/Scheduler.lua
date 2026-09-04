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

local function Now()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

function Sch.ShouldDeferHeavyWork()
    local player = GameData and GameData.Player
    if type(player) == "table" then
        if player.inCombat == true or player.isInRvRLake == true then
            return true, "combat-rvr"
        end
    end
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsHarvestActive then
        if StockPiler2.Orchestrator.IsHarvestActive() then
            return true, "harvest"
        end
    end
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsBrewSessionActive then
        if StockPiler2.Orchestrator.IsBrewSessionActive() then
            return true, "brew-session"
        end
    end
    return false, nil
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

local function FlushBagIfDue()
    if Sch._bagDue ~= true then
        return false
    end
    local defer, reason = Sch.ShouldDeferHeavyWork()
    if defer then
        Sch._bagAt = Now() + Sch.BAG_COALESCE_SEC
        if StockPiler2.Debug and StockPiler2.Debug.Enabled == true then
            StockPiler2.Debug.LogOp("perf", "defer bag-flush reason=" .. tostring(reason))
        end
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
    if Now() < (tonumber(Sch._planAt) or 0) then
        return false
    end
    Sch._planDue = false
    Sch._planAt = 0
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("PlanRebuild")
    end
    if StockPiler2.Planner then
        if StockPiler2.Planner.GetOrBuild then
            StockPiler2.Planner.GetOrBuild()
        elseif StockPiler2.Planner.Build then
            StockPiler2.Planner.Build()
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
        if not didHeavy and not Sch.BagWorkPending() and ShouldRunOrchestratorTick()
            and StockPiler2.Orchestrator and StockPiler2.Orchestrator.Tick then
            StockPiler2.Orchestrator.Tick()
        end
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
            if StockPiler2.Buy and StockPiler2.Buy.InvalidateJobsCache then
                StockPiler2.Buy.InvalidateJobsCache()
            end
            -- Do not ClearFillBlocked / WakeAutoGrow on every snap — that kept
            -- burst mode and forced Planner.Build after each snapGen bump.
            if StockPiler2.Grow and StockPiler2.Grow.MarkPlantJobDirty then
                StockPiler2.Grow.MarkPlantJobDirty()
            end
            if Sch.ShouldWakeAutoGrow() then
                Sch._autoGrowFast = true
                Sch.EnqueuePlanRebuild()
            elseif StockPiler2.Ui and StockPiler2.Ui.MarkWatchUiDirty then
                StockPiler2.Ui.MarkWatchUiDirty()
            end
        end)
        B.Subscribe(E.GARDEN_DIRTY, function()
            if Sch.ShouldWakeAutoGrow() then
                -- Already in fill burst with a coalesced plan pending: avoid WakeAutoGrow
                -- churn on every cultivation edge (still keep plan due via Enqueue if needed).
                if Sch._autoGrowFast == true
                    and Sch.IsPlanRebuildPending
                    and Sch.IsPlanRebuildPending() == true
                then
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
        end)
    end
end

function Sch.Shutdown()
    Sch._initialized = false
end
