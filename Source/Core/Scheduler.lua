----------------------------------------------------------------
-- StockPiler2 Core/Scheduler — coalesce heavy work, frame budgets
----------------------------------------------------------------

StockPiler2.Scheduler = StockPiler2.Scheduler or {}
local Sch = StockPiler2.Scheduler

Sch.BAG_COALESCE_SEC = 2.0
Sch.PLAN_MAX_WAIT_SEC = 0.5
-- While AutoGrow has work (empty plots / no-job thrash), coalesce plan rebuilds longer.
-- Perf: without this, empty-plot snaps pulled PlanRebuild every ~0.5s (WarmHave storms).
Sch.PLAN_COALESCE_WHEN_AWAKE_SEC = 3.0
-- Minimum gap between completed plan rebuilds (stops 0.5s reopen storms).
Sch.PLAN_MIN_GAP_SEC = 2.0
-- Cap how far awake/min-gap stretch can push a pending deadline (hot-path polls).
-- Perf: without this + opts.nudge, GetOrBuild(refresh=false) / Watch flush would stretch
-- _planAt forever (now+3s on every poll). Do not remove the cap or the nudge path.
Sch.PLAN_MAX_STRETCH_SEC = 6.0
Sch.AUTO_TICK_SEC = 1.0
Sch.AUTO_TICK_BURST_SEC = 1.5
Sch.AUTO_TICK_IDLE_SEC = 5.0
-- Floor for harvest-storm bag/plan/BrewUi defer (GatherButton harvests lack IsHarvestActive).
Sch.HARVEST_STORM_MIN_SEC = 1.5

Sch._bagDue = false
Sch._bagAt = 0
Sch._bagNeedQueue = false
Sch._planDue = false
Sch._planAt = 0
Sch._planFirstDueAt = 0
Sch._lastPlanBuiltAt = 0
Sch._autoAccum = 0
Sch._autoGrowFast = true
Sch._suppressInvTicks = 0
Sch._pendingBagFlushAfterSuppress = false
Sch._pendingBagNeedQueueAfterSuppress = false
Sch._pendingPlanAfterSuppress = false
Sch._suppressReenqueueCount = 0
Sch._initialized = false
Sch._lastDeferBagLogAt = 0
Sch._lastDeferBagReason = nil
Sch.DEFER_BAG_LOG_SEC = 5.0
Sch._sessionCraftBrewUiHold = false
Sch._harvestStormUntil = 0
Sch._brewUiDue = false
Sch._brewUiStormHeld = false

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

function Sch.BeginHarvestStorm(seconds)
    -- Perf: GatherButton / chat harvests do not arm Orch.IsHarvestActive, so bag Flatten
    -- and PlanRebuild used to run through the loot storm. Storm defers both for ~1.5s+.
    -- Do not remove without another IsHarvestActive arm for non-SP2 harvests.
    seconds = tonumber(seconds) or Sch.HARVEST_STORM_MIN_SEC or 1.5
    local minSec = tonumber(Sch.HARVEST_STORM_MIN_SEC) or 1.5
    if seconds < minSec then
        seconds = minSec
    end
    local untilT = Now() + seconds
    local cur = tonumber(Sch._harvestStormUntil) or 0
    if untilT > cur then
        Sch._harvestStormUntil = untilT
    end
end

function Sch.IsHarvestStormActive()
    local untilT = tonumber(Sch._harvestStormUntil) or 0
    if untilT <= 0 then
        return false
    end
    local now = Now()
    if now > 0 and now < untilT then
        return true
    end
    if now >= untilT then
        Sch._harvestStormUntil = 0
        -- Perf (0.4.101): post-storm only — do not arm BrewUi on this frame (would stack
        -- BrewUi+WatchRows with first Orch Pick/plant). Arm on next UPDATE_PROCESSED.
        -- Mid-storm hold / WakeAfterHarvest / quiet length unchanged.
        if Sch._brewUiStormHeld == true then
            Sch._brewUiStormHeld = false
            Sch._brewUiPostStormArm = true
        end
        -- Skip WarmHave PlanRebuild on the first post-storm plant Tick frame.
        if Sch.SkipPlanThisFrame then
            Sch.SkipPlanThisFrame()
        end
        -- Perf: MarkPlantJobDirty was skipped on snaps during storm — dirty once here so
        -- the first post-storm Orch Tick probes with a fresh job (avoids stale Peek /
        -- skipping BuildBalancedSpecDemand incorrectly). Do not remove.
        if StockPiler2.Grow and StockPiler2.Grow.MarkPlantJobDirty then
            StockPiler2.Grow.MarkPlantJobDirty()
        end
        -- Perf (0.4.118): prewarm demand on this plan-skipped frame so the following
        -- Orch plant hits _demandCache (snapGen:watchGen) instead of cold-building
        -- BuildBalancedSpecDemand on the plant hitch. Bag snap between here and plant
        -- correctly misses and rebuilds.
        if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.BuildBalancedSpecDemand then
            StockPiler2.RecipeSpec.BuildBalancedSpecDemand()
        end
    end
    return false
end

function Sch.MarkBrewUiDue()
    Sch._brewUiDue = true
end

--- Call once at the start of UPDATE_PROCESSED (before FlushBrewUiIfDue), not from
--- storm-expiry OnUpdate — otherwise BrewUi would still share the first plant Tick.
function Sch.PromotePostStormBrewUi()
    if Sch._brewUiPostStormArm == true then
        Sch._brewUiPostStormArm = false
        Sch._brewUiDue = true
    end
end

function Sch.FlushBrewUiIfDue()
    if Sch._brewUiDue ~= true then
        return false
    end
    local Brew = StockPiler2.Brew
    local jobActive = Brew and type(Brew._job) == "table"
    -- Keep holding while storm / session craft hold (unless a brew job needs live Tick).
    if not jobActive then
        if Sch.IsSessionCraftUiHeld and Sch.IsSessionCraftUiHeld() == true then
            return false
        end
        if Sch.IsHarvestStormActive and Sch.IsHarvestStormActive() == true then
            return false
        end
    end
    Sch._brewUiDue = false
    Sch._brewUiStormHeld = false
    if Brew and Brew.OnCraftingUpdated then
        Brew.OnCraftingUpdated()
        return true
    end
    return false
end

--- True when craft-slot Brew.OnCraftingUpdated should be deferred (storm or coalesce).
--- Always false when a brew job is active (needs ReconcileBoardIntegrity + Tick).
--- Perf: holding BrewUi during an active Brew._job stalls the brew state machine —
--- do not hold when type(Brew._job)=="table". Storm/session hold + once-per-frame
--- FlushBrewUiIfDue cuts BrewUi xN on loot trails.
function Sch.ShouldHoldBrewUi()
    local Brew = StockPiler2.Brew
    if Brew and type(Brew._job) == "table" then
        return false
    end
    if Sch.IsSessionCraftUiHeld and Sch.IsSessionCraftUiHeld() == true then
        return true
    end
    if Sch.IsHarvestStormActive and Sch.IsHarvestStormActive() == true then
        return true
    end
    return false
end

local function HarvestOrBrewDefer()
    -- Perf: harvest-storm must defer bag Flatten + PlanRebuild (not only Orch harvest
    -- op lock). Without storm, GatherButton loot ran BagFlush/Plan mid-hitch.
    if Sch.IsHarvestStormActive and Sch.IsHarvestStormActive() == true then
        return true, "harvest-storm"
    end
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

--- AutoGrow plant/additives — same combat/RvR/scenario gate as bag Flatten.
--- Cultivation often rejects AddCraftingItem in scenarios while pcall still succeeds;
--- without this gate Orch replants empties in a chat spam loop. Refine/AutoBuy stay up.
function Sch.ShouldDeferAutoGrowPlant()
    return PlayerCombatOrScenarioDefer()
end

--- Plan rebuild — NOT deferred in combat (AutoGrow + Watch need live plan).
--- Still deferred during harvest / brew loading|busy.
--- 0.4.125: also defer while seed-buffer refine is in flight (outstanding / pending).
--- 0.4.126: also defer while apo brew session is loading/loaded (not bag flush).
--- Keep _planDue armed; EnqueuePlanRebuild once when outstanding/session clears.
function Sch.ShouldDeferPlanRebuild()
    local defer, reason = HarvestOrBrewDefer()
    if defer then
        return true, reason
    end
    -- Plan-only: do NOT put brew-session in HarvestOrBrewDefer (that holds bag Flatten).
    local Orch = StockPiler2.Orchestrator
    if Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true then
        Sch._planHeldForBrew = true
        return true, "brew-session"
    end
    local RP = StockPiler2.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        Sch._planHeldForRefine = true
        return true, "refine-outstanding"
    end
    local SM = StockPiler2.SeedMap
    if SM and type(SM._pendingRefine) == "table" then
        Sch._planHeldForRefine = true
        return true, "refine-pending"
    end
    return false, nil
end

--- After refine outstanding/pending clears: arm one plan rebuild if we held during refine.
function Sch.EnqueuePlanRebuildAfterRefineClear()
    if Sch._planHeldForRefine ~= true then
        return
    end
    local RP = StockPiler2.RefinePipeline
    if RP and RP.HasOutstanding and RP.HasOutstanding() == true then
        return
    end
    local SM = StockPiler2.SeedMap
    if SM and type(SM._pendingRefine) == "table" then
        return
    end
    Sch._planHeldForRefine = false
    if Sch.EnqueuePlanRebuild then
        Sch.EnqueuePlanRebuild()
    end
end

--- After brew session leaves loading/loaded: arm one plan rebuild if we held mid-brew.
function Sch.EnqueuePlanRebuildAfterBrewClear()
    if Sch._planHeldForBrew ~= true then
        return
    end
    local Orch = StockPiler2.Orchestrator
    if Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true then
        return
    end
    Sch._planHeldForBrew = false
    if Sch.EnqueuePlanRebuild then
        Sch.EnqueuePlanRebuild()
    end
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
        if Sch._suppressInvTicks <= 0 then
            Sch._suppressInvTicks = 0
            Sch._suppressReenqueueCount = 0
            -- Publish any snap bumps deferred during Build before replaying enqueues.
            if StockPiler2.Inventory and StockPiler2.Inventory.FlushPendingSnapGen then
                StockPiler2.Inventory.FlushPendingSnapGen()
            end
            -- Replay enqueues that were deferred during Planner.Build suppress window.
            local needBag = Sch._pendingBagFlushAfterSuppress == true
            local needQueue = Sch._pendingBagNeedQueueAfterSuppress == true
            local needPlan = Sch._pendingPlanAfterSuppress == true
            Sch._pendingBagFlushAfterSuppress = false
            Sch._pendingBagNeedQueueAfterSuppress = false
            Sch._pendingPlanAfterSuppress = false
            if needBag then
                Sch.EnqueueBagFlush(needQueue)
            elseif needQueue then
                -- Plan-only via bag needQueue without a flush request.
                Sch._bagNeedQueue = true
            end
            if needPlan then
                Sch.EnqueuePlanRebuild()
            end
        end
    end
end

function Sch.BagWorkPending()
    return Sch._bagDue == true
end

function Sch.EnqueueBagFlush(needQueue)
    if Sch.IsInventorySideEffectsSuppressed() then
        Sch._pendingBagFlushAfterSuppress = true
        if needQueue == true then
            Sch._pendingBagNeedQueueAfterSuppress = true
        end
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

--- True when AutoGrow should wake for a reason other than empty plots alone
--- (additives, outstanding refine, refine dirty, buffer pending).
function Sch.ShouldWakeAutoGrowUrgent()
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
    local Refine = StockPiler2.Refine
    if Refine and Refine._refineDirty == true then
        return true
    end
    if Grow and Grow.HasPendingBufferRefine and Grow.HasPendingBufferRefine() == true then
        return true
    end
    return false
end

--- opts.nudge=true — hot-path (footer/Watch): arm only if not pending; never stretch.
--- Perf: stretch to max(awake 3s, min-gap) so a short first deadline cannot stick
--- through a harvest wave. nudge=true for GetOrBuild(refresh=false) / TabWatch so
--- polls do not push _planAt forever. PLAN_MAX_STRETCH caps the window.
--- 0.4.118: nudge also honors PLAN_MIN_GAP; Watch-open wait uses min-gap (not 0.5s).
--- Do not stretch on nudge; do not drop the stretch for wake/garden/bag callers.
function Sch.EnqueuePlanRebuild(opts)
    opts = type(opts) == "table" and opts or {}
    local nudge = opts.nudge == true
    if Sch.IsInventorySideEffectsSuppressed() then
        Sch._pendingPlanAfterSuppress = true
        Sch._suppressReenqueueCount = (tonumber(Sch._suppressReenqueueCount) or 0) + 1
        if Sch._suppressReenqueueCount >= 2
            and StockPiler2.Debug and StockPiler2.Debug.LogOp
        then
            StockPiler2.Debug.LogOp("perf", "suppress: plan rebuild deferred again (engine slots during Build)")
        end
        return
    end
    -- If a bag flush is already pending, arm needQueue and let FlushBagIfDue
    -- enqueue the rebuild after the flush (avoids build-then-flush-then-build).
    if Sch._bagDue == true then
        Sch._bagNeedQueue = true
        return
    end
    -- Hot-path polls: do not push a pending deadline out forever.
    if nudge == true and Sch._planDue == true and (tonumber(Sch._planAt) or 0) > 0 then
        return
    end
    local now = Now()
    local wait = tonumber(Sch.PLAN_MAX_WAIT_SEC) or 0.5
    local awake = Sch.ShouldWakeAutoGrow()
    -- Empty-plot AutoGrow used to pull _planAt earlier on every snap (+1 snapGen
    -- per rebuild). Use a longer first delay and never pull the deadline earlier.
    if awake and nudge ~= true then
        wait = tonumber(Sch.PLAN_COALESCE_WHEN_AWAKE_SEC) or 3.0
    end
    -- Watch window open: Status/tips coalesce to PLAN_MIN_GAP when AutoGrow is idle.
    -- Live Stock/Craftable come from Watch UI flush / PatchWatchRowsLiveCounts — do not
    -- use PLAN_MAX_WAIT (0.5s) here (0.4.118: that bypassed min-gap and storm-rebuilt).
    if not awake
        and DoesWindowExist("StockPiler2Window")
        and WindowGetShowing("StockPiler2Window") == true
    then
        local openWait = tonumber(Sch.PLAN_MIN_GAP_SEC) or 2.0
        if wait > openWait then
            wait = openWait
        end
    end
    local at = now + wait
    local minGap = tonumber(Sch.PLAN_MIN_GAP_SEC) or 2.0
    local lastBuilt = tonumber(Sch._lastPlanBuiltAt) or 0
    -- Apply min-gap to nudge too (0.4.118). Watch/footer polls used to fire PlanRebuild
    -- every ~0.5s while Stock was already live-patched. Keep nudge "do not stretch
    -- pending" early-return above; only clamp the first arm deadline.
    if lastBuilt > 0 and minGap > 0 then
        local gapAt = lastBuilt + minGap
        if gapAt > at then
            at = gapAt
        end
    end
    local firstDue = tonumber(Sch._planFirstDueAt) or 0
    if Sch._planDue ~= true or firstDue <= 0 then
        Sch._planFirstDueAt = now
        firstDue = now
    end
    local maxStretch = tonumber(Sch.PLAN_MAX_STRETCH_SEC) or 6.0
    if maxStretch > 0 and firstDue > 0 then
        local capAt = firstDue + maxStretch
        if at > capAt then
            at = capAt
        end
    end
    Sch._planDue = true
    if Sch._planAt <= 0 then
        Sch._planAt = at
    elseif at > Sch._planAt and nudge ~= true then
        -- Stretch to longer awake/min-gap deadline; never keep a stale short one.
        Sch._planAt = at
    end
end

function Sch.IsPlanRebuildPending()
    return Sch._planDue == true
end

--- Hold Brew.OnCraftingUpdated until first inventory snapshot after session load.
function Sch.BeginSessionCraftUiHold()
    Sch._sessionCraftBrewUiHold = true
end

function Sch.ClearSessionCraftUiHold()
    if Sch._sessionCraftBrewUiHold == true then
        Sch._sessionCraftBrewUiHold = false
        Sch._brewUiDue = true
    else
        Sch._sessionCraftBrewUiHold = false
    end
end

function Sch.IsSessionCraftUiHeld()
    return Sch._sessionCraftBrewUiHold == true
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
    -- Perf: LearnBridge harvest-complete (Snapshot/Complete) runs earlier on the same
    -- UPDATE_PROCESSED. Skipping plan this frame avoids LearnBridge+WarmHave fusion
    -- (~185–210ms). Do not remove — wake still enqueues; WarmHave moves to next frame.
    if Sch._skipPlanThisFrame == true then
        return false
    end
    local defer, reason = Sch.ShouldDeferPlanRebuild()
    if defer then
        -- Hold deadline; do not clear _planDue (SP1: flush/plan wait out harvest storm).
        -- Never collapse a longer awake/min-gap deadline to Now()+0.5.
        -- Do not revert to `_planAt = Now()+0.5` — that caused PlanRebuild every ~1s
        -- while IsHarvestActive flickered during harvesting stage.
        local holdAt = Now() + (tonumber(Sch.PLAN_MAX_WAIT_SEC) or 0.5)
        local cur = tonumber(Sch._planAt) or 0
        if holdAt > cur then
            Sch._planAt = holdAt
        end
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
                Sch._planFirstDueAt = 0
                return false
            end
        end
    end
    Sch._planDue = false
    Sch._planAt = 0
    Sch._planFirstDueAt = 0
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
    Sch._lastPlanBuiltAt = Now()
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

--- One-frame skip after harvest-complete attempt (LearnBridge runs before Scheduler
--- on the same UPDATE_PROCESSED). Prevents trail fusion:
--- LearnBridge.OnUpdate → Harvest.Snapshot/Complete → PlanRebuild → WarmHave (~185–210ms).
--- Do not remove: wake still EnqueuePlanRebuild; only moves WarmHave to the next frame.
function Sch.SkipPlanThisFrame()
    Sch._skipPlanThisFrame = true
end

--- One-frame skip after harvest-complete attempt: hold Watch paint so Complete does not
--- fuse with UiFlush/WatchRows/Footer on the same UPDATE_PROCESSED. Dirty stays;
--- FlushWatch runs on a later frame. Pair with SkipPlanThisFrame from LearnBridge.
function Sch.SkipUiThisFrame()
    Sch._skipUiThisFrame = true
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
    -- Expire harvest storm and arm BrewUi flush when the window ends.
    if Sch.IsHarvestStormActive then
        Sch.IsHarvestStormActive()
    end
    if Sch.FlushBrewUiIfDue then
        Sch.FlushBrewUiIfDue()
    end
    local didHeavy = false
    if FlushBagIfDue() then
        didHeavy = true
    end
    if not didHeavy and RebuildPlanIfDue() then
        didHeavy = true
    end
    -- Clear plan-skip after RebuildPlanIfDue had a chance to honor it this frame.
    Sch._skipPlanThisFrame = false
    -- Skip Watch paint on the same frame as bag flush / plan rebuild.
    -- Do not remove: every PlanRebuild frame used to also carry UiFlush+WatchRows.
    -- SkipUiThisFrame (harvest Complete): FlushWatchUiIfDirty returns with dirty held.
    if not didHeavy and StockPiler2.Ui and StockPiler2.Ui.FlushWatchUiIfDirty then
        StockPiler2.Ui.FlushWatchUiIfDirty()
    end
    -- Clear UI-skip after FlushWatch had a chance to honor it this frame.
    Sch._skipUiThisFrame = false
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
            -- During plant quiet / harvest storm, Wake already armed fast ticks; skip
            -- ShouldWakeAutoGrowUrgent (HasPendingBufferRefine → BufferFlags/seed lines)
            -- AND MarkPlantJobDirty (every loot snap was forcing GetPlantJob →
            -- BuildBalancedSpecDemand on first post-quiet Tick). Storm end dirties once
            -- in IsHarvestStormActive. Do not re-enable dirty/urgent-wake mid-storm.
            local plantQuiet = StockPiler2.Grow
                and StockPiler2.Grow.IsPlantQuiet
                and StockPiler2.Grow.IsPlantQuiet() == true
            local storm = Sch.IsHarvestStormActive and Sch.IsHarvestStormActive() == true
            if not plantQuiet and not storm then
                -- 0.4.122: vault/bank snaps used to MarkPlantJobDirty every move → BufferFlags
                -- with no plant work. Dirty only when AutoGrow actually has plant/additive/buffer.
                local Watch = StockPiler2.Watch
                local autoGrowOn = Watch and Watch.IsAutoGrowEnabled
                    and Watch.IsAutoGrowEnabled() == true
                local Grow = StockPiler2.Grow
                local hasPlantWork = false
                if autoGrowOn and Grow then
                    if Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true then
                        hasPlantWork = true
                    elseif Grow.NeedsCurrentStageAdditive
                        and Grow.NeedsCurrentStageAdditive() == true
                    then
                        hasPlantWork = true
                    elseif Grow.HasPendingBufferRefine
                        and Grow.HasPendingBufferRefine() == true
                    then
                        hasPlantWork = true
                    end
                end
                if hasPlantWork and Grow.MarkPlantJobDirty then
                    Grow.MarkPlantJobDirty()
                end
                if Sch.ShouldWakeAutoGrowUrgent and Sch.ShouldWakeAutoGrowUrgent() then
                    Sch._autoGrowFast = true
                end
            end
            if Sch.ClearSessionCraftUiHold then
                Sch.ClearSessionCraftUiHold()
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
            if Sch.BeginSessionCraftUiHold then
                Sch.BeginSessionCraftUiHold()
            end
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
                StockPiler2.Ui._watchUiLastBrewKey = nil
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
                -- Skip sync GetOrBuild when a coalesced rebuild is already enqueued
                -- (avoids login Flatten+Plan+WatchRows+Footer double work).
                local planPending = Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true
                if not planPending and StockPiler2.Planner and StockPiler2.Planner.GetOrBuild then
                    StockPiler2.Planner.GetOrBuild()
                end
                if StockPiler2Window.RequestFooterRefresh then
                    StockPiler2Window.RequestFooterRefresh()
                end
                if StockPiler2.Ui and StockPiler2.Ui.MarkWatchUiDirty then
                    StockPiler2.Ui.MarkWatchUiDirty()
                elseif StockPiler2Window.RefreshActiveTab then
                    StockPiler2Window.RefreshActiveTab()
                end
            elseif StockPiler2Window and StockPiler2Window.RequestFooterRefresh then
                StockPiler2Window.RequestFooterRefresh()
            elseif StockPiler2Window and StockPiler2Window.RefreshFooterButtons then
                StockPiler2Window.RefreshFooterButtons()
            end
        end)
    end
end

function Sch.Shutdown()
    Sch._initialized = false
end
