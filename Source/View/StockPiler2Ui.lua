----------------------------------------------------------------
-- StockPiler2 View/Ui — window show/hide + chat print
----------------------------------------------------------------

StockPiler2.Ui = StockPiler2.Ui or {}

local function T(key, tokens)
    if StockPiler2.T then
        return StockPiler2.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

StockPiler2.Ui.WATCH_UI_MIN_INTERVAL_SEC = 5.0
StockPiler2.Ui._watchUiDirty = false
StockPiler2.Ui._watchUiFlushedAt = 0
StockPiler2.Ui._watchUiLastKey = nil
StockPiler2.Ui._watchUiLastKnowledgeGen = 0
StockPiler2.Ui._watchUiLastPlanGen = 0
StockPiler2.Ui._watchUiLastBrewKey = nil

function StockPiler2.Ui.Print(msg)
    if StockPiler2.Debug and StockPiler2.Debug.Print then
        StockPiler2.Debug.Print(msg)
    end
end

function StockPiler2.Ui.ToggleWindow()
    if not DoesWindowExist("StockPiler2Window") then
        StockPiler2.Ui.Print(T("ui.window_missing"))
        return
    end
    if WindowUtils and WindowUtils.ToggleShowing then
        WindowUtils.ToggleShowing("StockPiler2Window")
        return
    end
    local showing = WindowGetShowing("StockPiler2Window") == true
    WindowSetShowing("StockPiler2Window", not showing)
end

function StockPiler2.Ui.ShowWindow(tabId)
    if not DoesWindowExist("StockPiler2Window") then
        return
    end
    WindowSetShowing("StockPiler2Window", true)
    if tabId and StockPiler2Window and StockPiler2Window.SelectTab then
        StockPiler2Window.SelectTab(tabId)
    end
end

local function CurrentPlanGen()
    if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Get then
        local plan = StockPiler2.PlanSnapshot.Get()
        if type(plan) == "table" then
            return tonumber(plan.planGen) or 0
        end
    end
    return 0
end

--- Load/Brew row chrome fingerprint (phase + which watch). Must be in WatchContentKey
--- or FlushWatchUiIfDirty clears dirty without paint after RefreshBrewUi (same snap/plan).
local function BrewChromeKey()
    local Brew = StockPiler2.Brew
    if not Brew or not Brew.GetSession then
        return "idle"
    end
    local session = Brew.GetSession()
    if type(session) ~= "table" then
        return "idle"
    end
    return tostring(session.phase or "idle")
        .. ":" .. tostring(session.potionKey or "")
        .. ":" .. tostring(session.rowId or "")
end

local function WatchContentKey()
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    local planGen = CurrentPlanGen()
    local knowledgeGen = 0
    if StockPiler2.Knowledge and StockPiler2.Knowledge.GetGen then
        knowledgeGen = tonumber(StockPiler2.Knowledge.GetGen()) or 0
    end
    local watchGen = 0
    if StockPiler2.Watch and StockPiler2.Watch.GetGen then
        watchGen = tonumber(StockPiler2.Watch.GetGen()) or 0
    end
    local autoGrowOn = false
    if StockPiler2.Watch and StockPiler2.Watch.IsAutoGrowEnabled then
        autoGrowOn = StockPiler2.Watch.IsAutoGrowEnabled() == true
    end
    return tostring(snapGen)
        .. ":" .. tostring(planGen)
        .. ":" .. tostring(knowledgeGen)
        .. ":" .. tostring(watchGen)
        .. ":" .. tostring(autoGrowOn)
        .. ":" .. BrewChromeKey()
end

--- True when Watch would only rebind a stale PlanSnapshot (avoid burning the 5s clock).
local function IsWatchPlanStale()
    local Sch = StockPiler2.Scheduler
    if Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true then
        return true
    end
    local Planner = StockPiler2.Planner
    if not Planner or not Planner.CacheKeyFromGens then
        return false
    end
    local wantKey = Planner.CacheKeyFromGens()
    local plan = StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Get and StockPiler2.PlanSnapshot.Get()
    if type(plan) ~= "table" then
        -- No snapshot yet: allow flush (BuildVisibleList may keep prior listData).
        return false
    end
    return tostring(plan.cacheKey or "") ~= tostring(wantKey or "")
end

function StockPiler2.Ui.ClearWatchTipCaches()
    if StockPiler2TabWatch then
        StockPiler2TabWatch._statusTipCache = nil
        StockPiler2TabWatch._seedBufferTipCache = nil
    end
end

function StockPiler2.Ui.MarkWatchUiDirty()
    StockPiler2.Ui._watchUiDirty = true
end

function StockPiler2.Ui.RefreshIfOpen(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.force ~= true then
        StockPiler2.Ui.MarkWatchUiDirty()
        return
    end
    if DoesWindowExist("StockPiler2Window")
        and WindowGetShowing("StockPiler2Window") == true
        and StockPiler2Window
        and StockPiler2Window.RefreshActiveTab
    then
        StockPiler2Window.RefreshActiveTab()
    end
end

function StockPiler2.Ui.FlushWatchUiIfDirty()
    if StockPiler2.Ui._watchUiDirty ~= true then
        return
    end
    if not DoesWindowExist("StockPiler2Window")
        or WindowGetShowing("StockPiler2Window") ~= true
    then
        return
    end
    -- Hold paint during harvest storm / plant quiet; dirty stays for post-storm flush.
    -- Perf: without this, empty-plot UPDATE_PROCESSED painted UiFlush+WatchRows on the
    -- same hitch as CultivationUpdated/WakeAfterHarvest. Do not remove the hold —
    -- MarkWatchUiDirty still runs; first flush after storm/quiet picks it up.
    local Sch = StockPiler2.Scheduler
    -- Harvest Complete frame: SkipUiThisFrame holds paint so Complete does not fuse
    -- with UiFlush/WatchRows/Footer. Dirty stays for the next eligible flush.
    if Sch and Sch._skipUiThisFrame == true then
        return
    end
    if Sch and Sch.IsHarvestStormActive and Sch.IsHarvestStormActive() == true then
        return
    end
    if StockPiler2.Grow and StockPiler2.Grow.IsPlantQuiet
        and StockPiler2.Grow.IsPlantQuiet() == true
    then
        return
    end
    -- 0.4.143: during brew session still flush every 1s so live Stock/Status
    -- patches appear; Load/Brew chrome flips still flush immediately.
    local Orch = StockPiler2.Orchestrator
    local brewSessionHold = false
    if Orch and Orch.IsBrewSessionActive and Orch.IsBrewSessionActive() == true then
        local brewKeyHold = BrewChromeKey()
        if brewKeyHold == tostring(StockPiler2.Ui._watchUiLastBrewKey or "") then
            brewSessionHold = true
        end
    end
    -- Window open: catch-up paint when plan/knowledge advances. Interval rate-limits
    -- snap noise; while plan is stale, flush at most every 1s so live Stock overlay moves.
    local knowledgeGen = 0
    if StockPiler2.Knowledge and StockPiler2.Knowledge.GetGen then
        knowledgeGen = tonumber(StockPiler2.Knowledge.GetGen()) or 0
    end
    local planGen = CurrentPlanGen()
    local brewKey = BrewChromeKey()
    local contentKey = WatchContentKey()
    if StockPiler2.Ui._watchUiLastKey == contentKey then
        StockPiler2.Ui._watchUiDirty = false
        return
    end
    local now = 0
    if type(GetGameTime) == "function" then
        now = tonumber(GetGameTime()) or 0
    end
    local last = tonumber(StockPiler2.Ui._watchUiFlushedAt) or 0
    local knowledgeChanged = knowledgeGen ~= (tonumber(StockPiler2.Ui._watchUiLastKnowledgeGen) or 0)
    local planChanged = planGen ~= (tonumber(StockPiler2.Ui._watchUiLastPlanGen) or 0)
    -- Load→Brew / unload label must not wait on the 5s snap coalesce.
    local brewChanged = brewKey ~= tostring(StockPiler2.Ui._watchUiLastBrewKey or "")
    -- While plan lags bags (or brew session holds chrome-only), allow 1s paints for live overlay.
    local interval = StockPiler2.Ui.WATCH_UI_MIN_INTERVAL_SEC
    if brewSessionHold
        or (not knowledgeChanged and not planChanged and not brewChanged and IsWatchPlanStale())
    then
        interval = math.min(interval, 1.0)
    end
    if brewSessionHold and not brewChanged then
        -- Chrome unchanged: only the 1s cadence may paint; never block forever.
        if last > 0 and (now - last) < interval then
            return
        end
    elseif not knowledgeChanged
        and not planChanged
        and not brewChanged
        and last > 0
        and (now - last) < interval
    then
        return
    end
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("UiFlush")
    end
    StockPiler2.Ui._watchUiDirty = false
    StockPiler2.Ui._watchUiFlushedAt = now
    StockPiler2.Ui._watchUiLastKey = contentKey
    StockPiler2.Ui._watchUiLastKnowledgeGen = knowledgeGen
    StockPiler2.Ui._watchUiLastPlanGen = planGen
    StockPiler2.Ui._watchUiLastBrewKey = brewKey
    if StockPiler2Window and StockPiler2Window.RefreshActiveTab then
        StockPiler2Window.RefreshActiveTab()
    end
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("UiFlush")
    end
end

function StockPiler2.Ui.InitializeWindow()
    if StockPiler2Window and StockPiler2Window.Initialize then
        StockPiler2Window.Initialize()
    end
end

function StockPiler2.Ui.RegisterEventRefresh()
    if StockPiler2.Ui._eventsRegistered == true then
        return
    end
    local B = StockPiler2.EventBus
    local E = StockPiler2.Events
    if not B or not E then
        return
    end
    StockPiler2.Ui._busTokens = StockPiler2.Ui._busTokens or {}
    local tokens = StockPiler2.Ui._busTokens
    local function track(token)
        if token then
            tokens[#tokens + 1] = token
        end
    end
    local function markDirty()
        StockPiler2.Ui.MarkWatchUiDirty()
    end
    track(B.Subscribe(E.PLAN_UPDATED, function()
        StockPiler2.Ui.ClearWatchTipCaches()
        StockPiler2.Ui.MarkWatchUiDirty()
    end))
    track(B.Subscribe(E.PLAN_INVALIDATED, markDirty))
    track(B.Subscribe(E.INVENTORY_SNAPSHOT, markDirty))
    track(B.Subscribe(E.GARDEN_SNAPSHOT, markDirty))
    if E.KNOWLEDGE_UPDATED then
        track(B.Subscribe(E.KNOWLEDGE_UPDATED, markDirty))
    end
    if E.SESSION_LOADED then
        track(B.Subscribe(E.SESSION_LOADED, function()
            if StockPiler2TabWatch and StockPiler2TabWatch.RefreshSkillGates then
                StockPiler2TabWatch.RefreshSkillGates()
            end
            -- Scheduler owns the full open-window list refresh; keep lastKey clear here
            -- so a later dirty flush cannot no-op on a pre-login content key.
            StockPiler2.Ui._watchUiLastKey = nil
            StockPiler2.Ui._watchUiLastBrewKey = nil
            StockPiler2.Ui._watchUiFlushedAt = 0
            StockPiler2.Ui._watchUiLastPlanGen = 0
            StockPiler2.Ui.ClearWatchTipCaches()
            StockPiler2.Ui.MarkWatchUiDirty()
        end))
    end
    StockPiler2.Ui._eventsRegistered = true
end

function StockPiler2.Ui.UnregisterEventRefresh()
    local B = StockPiler2.EventBus
    local tokens = StockPiler2.Ui._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    StockPiler2.Ui._busTokens = nil
    StockPiler2.Ui._eventsRegistered = false
end
