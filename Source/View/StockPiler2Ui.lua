----------------------------------------------------------------
-- StockPiler2 View/Ui — window show/hide + chat print
----------------------------------------------------------------

StockPiler2.Ui = StockPiler2.Ui or {}

StockPiler2.Ui.WATCH_UI_MIN_INTERVAL_SEC = 5.0
StockPiler2.Ui._watchUiDirty = false
StockPiler2.Ui._watchUiFlushedAt = 0
StockPiler2.Ui._watchUiLastKey = nil

function StockPiler2.Ui.Print(msg)
    if StockPiler2.Debug and StockPiler2.Debug.Print then
        StockPiler2.Debug.Print(msg)
    end
end

function StockPiler2.Ui.ToggleWindow()
    if not DoesWindowExist("StockPiler2Window") then
        StockPiler2.Ui.Print(L"StockPiler2 window is not loaded.")
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

local function WatchContentKey()
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    local planGen = 0
    if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Get then
        local plan = StockPiler2.PlanSnapshot.Get()
        if type(plan) == "table" then
            planGen = tonumber(plan.planGen) or 0
        end
    end
    local autoGrowOn = false
    if StockPiler2.Watch and StockPiler2.Watch.IsAutoGrowEnabled then
        autoGrowOn = StockPiler2.Watch.IsAutoGrowEnabled() == true
    end
    return tostring(snapGen) .. ":" .. tostring(planGen) .. ":" .. tostring(autoGrowOn)
end

--- True during harvest or AutoGrow fill wave — skip heavy Watch list rebuild.
local function IsWatchUiFillBurst()
    local Orch = StockPiler2.Orchestrator
    if Orch and Orch.IsHarvestActive and Orch.IsHarvestActive() == true then
        return true
    end
    local Grow = StockPiler2.Grow
    local Sch = StockPiler2.Scheduler
    local fast = Sch and Sch._autoGrowFast == true
    if not fast then
        return false
    end
    if Grow and Grow.HasEmptyPlot and Grow.HasEmptyPlot() == true then
        return true
    end
    if type(Grow) == "table" and type(Grow._pendingPlant) == "table" then
        for _, n in pairs(Grow._pendingPlant) do
            if (tonumber(n) or 0) > 0 then
                return true
            end
        end
    end
    return false
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
    -- Keep dirty; catch up once harvest/fill settles (footer stays light via cultivation bridge).
    if IsWatchUiFillBurst() then
        return
    end
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
    if last > 0 and (now - last) < StockPiler2.Ui.WATCH_UI_MIN_INTERVAL_SEC then
        return
    end
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("UiFlush")
    end
    StockPiler2.Ui._watchUiDirty = false
    StockPiler2.Ui._watchUiFlushedAt = now
    StockPiler2.Ui._watchUiLastKey = contentKey
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
    local B = StockPiler2.EventBus
    local E = StockPiler2.Events
    if not B or not E then
        return
    end
    local function markDirty()
        StockPiler2.Ui.MarkWatchUiDirty()
    end
    B.Subscribe(E.PLAN_UPDATED, markDirty)
    B.Subscribe(E.PLAN_INVALIDATED, markDirty)
    B.Subscribe(E.INVENTORY_SNAPSHOT, markDirty)
    B.Subscribe(E.GARDEN_SNAPSHOT, markDirty)
    if E.KNOWLEDGE_UPDATED then
        B.Subscribe(E.KNOWLEDGE_UPDATED, markDirty)
    end
end
