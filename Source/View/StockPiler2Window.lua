----------------------------------------------------------------
-- StockPiler2Window — settings-style chrome
----------------------------------------------------------------

StockPiler2Window = {}

local function T(key, tokens)
    if StockPiler2.T then
        return StockPiler2.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

StockPiler2Window.TABS_POTIONS = 1
StockPiler2Window.TABS_WATCH = 2
StockPiler2Window.TABS_MAX = 2
StockPiler2Window.SelectedTab = StockPiler2Window.TABS_POTIONS

local CLEAR_WATCHES_WIN = "StockPiler2WindowClearWatches"
local HARVEST_WIN = "StockPiler2WindowHarvest"
local BREW_WIN = "StockPiler2WindowBrew"

StockPiler2Window.Tabs = {
    [1] = {
        window = "SP2TabPotions",
        name = "StockPiler2WindowTabButtonsPotions",
        labelKey = "ui.tab_potions",
        refresh = function()
            if StockPiler2TabPotions and StockPiler2TabPotions.Refresh then
                StockPiler2TabPotions.Refresh()
            end
        end,
    },
    [2] = {
        window = "SP2TabWatch",
        name = "StockPiler2WindowTabButtonsWatch",
        labelKey = "ui.tab_watch",
        refresh = function()
            if StockPiler2TabWatch and StockPiler2TabWatch.Refresh then
                StockPiler2TabWatch.Refresh()
            end
        end,
    },
}

function StockPiler2Window.OnInitialize()
    local selected = StockPiler2Window.SelectedTab or StockPiler2Window.TABS_POTIONS
    for index, tab in ipairs(StockPiler2Window.Tabs) do
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, index == selected)
        end
        if DoesWindowExist(tab.name) then
            ButtonSetPressedFlag(tab.name, index == selected)
        end
    end
end

--- Coalesce craft/cultivation footer storms to once per UPDATE_PROCESSED.
function StockPiler2Window.RequestFooterRefresh()
    StockPiler2Window._footerRefreshPending = true
end

--- Sync Harvest/Brew readiness: macros always; footer chrome only when window is open.
--- opts.immediate — apply Macro.RefreshMacroButtonAppearance now (notify/sound sync).
--- Returns canHarvest, canBrew.
function StockPiler2Window.SyncActionReadiness(opts)
    opts = type(opts) == "table" and opts or {}
    local immediate = opts.immediate == true
    local Perf = StockPiler2.Perf

    local windowOpen = DoesWindowExist("StockPiler2Window")
        and WindowGetShowing("StockPiler2Window") == true
    local onWatch = StockPiler2Window.SelectedTab == StockPiler2Window.TABS_WATCH
    local onPotions = StockPiler2Window.SelectedTab == StockPiler2Window.TABS_POTIONS

    -- Live readiness for macros even when the SP2 window is closed.
    local canHarvest = StockPiler2.Grow and StockPiler2.Grow.CanHarvestNow
        and StockPiler2.Grow.CanHarvestNow() == true
    local canBrew = StockPiler2.Brew and StockPiler2.Brew.CanBrewNow
        and StockPiler2.Brew.CanBrewNow() == true

    -- Early-out when nothing changed (craft-slot / cultivation storms).
    -- 0.4.144: do not Perf.Begin on no-ops — continuous Footer Marks glue the trail
    -- (Footer xN000) and drown real hitches in libperf summaries.
    if not immediate
        and StockPiler2Window._footerWindowOpen == windowOpen
        and StockPiler2Window._footerOnWatch == onWatch
        and StockPiler2Window._footerOnPotions == onPotions
        and StockPiler2Window._footerCanHarvest == canHarvest
        and StockPiler2Window._footerCanBrew == canBrew
    then
        local appearanceKey = tostring(canHarvest) .. ":" .. tostring(canBrew)
        if StockPiler2.Macro == nil
            or StockPiler2.Macro._lastAppearanceKey == nil
            or StockPiler2.Macro._lastAppearanceKey == appearanceKey
        then
            return canHarvest, canBrew
        end
    end

    if Perf and Perf.Begin then
        Perf.Begin("Footer")
    end

    if windowOpen then
        if DoesWindowExist(CLEAR_WATCHES_WIN) then
            WindowSetShowing(CLEAR_WATCHES_WIN, onPotions)
        end
        if DoesWindowExist(HARVEST_WIN) then
            WindowSetShowing(HARVEST_WIN, onWatch)
            if onWatch then
                if StockPiler2.Grow and StockPiler2.Grow.SetFooterHarvestClickable then
                    StockPiler2.Grow.SetFooterHarvestClickable(canHarvest)
                else
                    ButtonSetDisabledFlag(HARVEST_WIN, not canHarvest)
                end
            elseif StockPiler2.Grow and StockPiler2.Grow.ClearHarvestActionBound then
                StockPiler2.Grow.ClearHarvestActionBound()
            end
        end
        if DoesWindowExist(BREW_WIN) then
            WindowSetShowing(BREW_WIN, onWatch)
            if onWatch then
                ButtonSetDisabledFlag(BREW_WIN, not canBrew)
            end
        end
    end

    local prevOnWatch = StockPiler2Window._footerOnWatch
    local prevHarvest = StockPiler2Window._footerCanHarvest
    local prevBrew = StockPiler2Window._footerCanBrew
    StockPiler2Window._footerWindowOpen = windowOpen
    StockPiler2Window._footerOnWatch = onWatch
    StockPiler2Window._footerOnPotions = onPotions
    StockPiler2Window._footerCanHarvest = canHarvest
    StockPiler2Window._footerCanBrew = canBrew
    local readinessChanged = prevOnWatch ~= onWatch
        or prevHarvest ~= canHarvest
        or prevBrew ~= canBrew
    -- Resync when last hotbar appearance disagrees (closed-window lag / grey stick).
    -- Skip drift while brew is busy/loading — craft-slot storms otherwise spam Macro.Appearance.
    if not readinessChanged and StockPiler2.Macro then
        local skipDrift = false
        if StockPiler2.Brew then
            if StockPiler2.Brew.IsBusy and StockPiler2.Brew.IsBusy() == true then
                skipDrift = true
            else
                local session = StockPiler2.Brew.GetSession and StockPiler2.Brew.GetSession()
                if type(session) == "table" and session.phase == "loading" then
                    skipDrift = true
                end
            end
        end
        if not skipDrift then
            local appearanceKey = tostring(canHarvest) .. ":" .. tostring(canBrew)
            if StockPiler2.Macro._lastAppearanceKey ~= nil
                and StockPiler2.Macro._lastAppearanceKey ~= appearanceKey
            then
                readinessChanged = true
            end
        end
    end

    if readinessChanged or immediate then
        if StockPiler2.Macro then
            if immediate and StockPiler2.Macro.RefreshMacroButtonAppearance then
                StockPiler2.Macro._enabledSyncPending = false
                StockPiler2.Macro._pendingCanHarvest = nil
                StockPiler2.Macro._pendingCanBrew = nil
                StockPiler2.Macro.RefreshMacroButtonAppearance({
                    canHarvest = canHarvest,
                    canBrew = canBrew,
                })
            elseif StockPiler2.Macro.RequestEnabledSync then
                StockPiler2.Macro.RequestEnabledSync(canHarvest, canBrew)
            elseif StockPiler2.Macro.SyncEnabledState then
                StockPiler2.Macro.SyncEnabledState(canHarvest, canBrew)
            end
        end
    end

    if Perf and Perf.End then
        Perf.End("Footer")
    end
    return canHarvest, canBrew
end

function StockPiler2Window.FlushPendingFooterRefresh()
    if StockPiler2Window._footerRefreshPending ~= true then
        return
    end
    -- 0.4.130: hold Footer when harvest Complete / refine delivery armed SkipUi.
    -- Scheduler clears the flag after Watch flush; we run after Scheduler and peek
    -- a sticky hold so Footer does not fuse with ReconcileAll / Harvest.Complete.
    local Sch = StockPiler2.Scheduler
    if Sch and Sch._skipUiHoldFooter == true then
        return
    end
    -- 0.4.139: hold Footer for full harvest storm / plant quiet (mirror Watch).
    -- Keep pending so one flush runs after storm; brew job stays live.
    local brewJob = StockPiler2.Brew and type(StockPiler2.Brew._job) == "table"
    if not brewJob then
        if Sch and Sch.IsHarvestStormActive and Sch.IsHarvestStormActive() == true then
            return
        end
        if StockPiler2.Grow and StockPiler2.Grow.IsPlantQuiet
            and StockPiler2.Grow.IsPlantQuiet() == true
        then
            return
        end
    end
    StockPiler2Window._footerRefreshPending = false
    -- Always sync macros; chrome updates only when the window is open (inside Sync).
    StockPiler2Window.SyncActionReadiness()
    -- Frame-coalesced brew-ready chat/sound (was inline on every craft-slot RefreshBrewUi).
    if StockPiler2.Brew and StockPiler2.Brew.MaybeNotifyBrewReady then
        StockPiler2.Brew.MaybeNotifyBrewReady()
    end
end

function StockPiler2Window.RefreshFooterButtons()
    -- Route through coalesced path so craft/cultivation storms pay Footer once/frame.
    if StockPiler2Window.RequestFooterRefresh then
        StockPiler2Window.RequestFooterRefresh()
        return
    end
    StockPiler2Window.SyncActionReadiness()
end

function StockPiler2Window.Initialize()
    if not DoesWindowExist("StockPiler2Window") then
        return
    end
    local version = StockPiler2.Version or L""
    if version ~= L"" then
        LabelSetText("StockPiler2WindowTitleBarText", T("ui.title_version", { version = version }))
    else
        LabelSetText("StockPiler2WindowTitleBarText", T("ui.title"))
    end
    if DoesWindowExist(CLEAR_WATCHES_WIN) then
        ButtonSetText(CLEAR_WATCHES_WIN, T("ui.clear_watches"))
    end
    if DoesWindowExist(HARVEST_WIN) then
        ButtonSetText(HARVEST_WIN, T("ui.harvest"))
        if StockPiler2.Grow and StockPiler2.Grow.EnsureHarvestActionBound then
            StockPiler2.Grow.EnsureHarvestActionBound()
        end
    end
    if DoesWindowExist(BREW_WIN) then
        ButtonSetText(BREW_WIN, T("ui.brew"))
    end
    for _, tab in ipairs(StockPiler2Window.Tabs) do
        ButtonSetText(tab.name, T(tab.labelKey))
    end
    StockPiler2Window.SelectTab(StockPiler2Window.SelectedTab)
end

function StockPiler2Window.RefreshActiveTab()
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("RefreshWatch")
    end
    local tab = StockPiler2Window.Tabs[StockPiler2Window.SelectedTab]
    if tab and tab.refresh then
        tab.refresh()
    end
    StockPiler2Window.RefreshFooterButtons()
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("RefreshWatch")
    end
end

function StockPiler2Window.RequestListRepopulate()
    StockPiler2Window._repopulatePending = true
end

function StockPiler2Window.FlushPendingListRepopulate()
    if StockPiler2Window._repopulatePending ~= true then
        return
    end
    if not DoesWindowExist("StockPiler2Window") then
        return
    end
    if WindowGetShowing("StockPiler2Window") ~= true then
        return
    end
    -- Mark dirty only; Scheduler.OnUpdate flushes once per tick (no nested flush).
    StockPiler2Window._repopulatePending = false
    if StockPiler2.Ui and StockPiler2.Ui.MarkWatchUiDirty then
        StockPiler2.Ui.MarkWatchUiDirty()
        return
    end
    StockPiler2Window.RefreshActiveTab()
end

function StockPiler2Window.PrimeTabListsIfNeeded()
    if StockPiler2Window._tabListsPrimed == true then
        return
    end
    if not DoesWindowExist("StockPiler2Window") then
        return
    end
    if WindowGetShowing("StockPiler2Window") ~= true then
        return
    end
    StockPiler2Window._tabListsPrimed = true
    local selected = StockPiler2Window.SelectedTab or StockPiler2Window.TABS_POTIONS
    for index, tab in ipairs(StockPiler2Window.Tabs) do
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, true)
            if type(WindowForceProcessAnchors) == "function" then
                StockPiler2.Debug.TryCall("WindowForceProcessAnchors", WindowForceProcessAnchors, tab.window)
            end
        end
        if tab.refresh then
            tab.refresh()
        end
        if DoesWindowExist(tab.window) and index ~= selected then
            WindowSetShowing(tab.window, false)
        end
    end
    for index, tab in ipairs(StockPiler2Window.Tabs) do
        if DoesWindowExist(tab.name) then
            ButtonSetPressedFlag(tab.name, index == selected)
        end
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, index == selected)
        end
    end
    StockPiler2Window.RefreshFooterButtons()
end

function StockPiler2Window.OnShow()
    WindowUtils.OnShown()
    if StockPiler2.Inventory and StockPiler2.Inventory.RefreshAllIfNeeded then
        StockPiler2.Inventory.RefreshAllIfNeeded({ force = StockPiler2.Inventory.IsDirty and StockPiler2.Inventory.IsDirty() })
    end
    if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Invalidate then
        StockPiler2.PlanSnapshot.Invalidate()
    end
    -- Trade skills may have been missing at CreateWindow Initialize — refresh gates.
    if StockPiler2TabWatch and StockPiler2TabWatch.RefreshSkillGates then
        StockPiler2TabWatch.RefreshSkillGates()
    end
    -- ListBox row chrome may have been recreated; never skip the first paint after open.
    if StockPiler2TabWatch and StockPiler2TabWatch.ClearRowPaintCache then
        StockPiler2TabWatch.ClearRowPaintCache()
    end
    StockPiler2Window.PrimeTabListsIfNeeded()
    StockPiler2Window.RefreshActiveTab()
    StockPiler2Window.RequestListRepopulate()
end

function StockPiler2Window.OnClose()
    WindowSetShowing("StockPiler2Window", false)
end

function StockPiler2Window.OnRefresh()
    if StockPiler2.Inventory and StockPiler2.Inventory.RefreshAllIfNeeded then
        StockPiler2.Inventory.RefreshAllIfNeeded({ force = true })
    end
    StockPiler2Window.RefreshActiveTab()
    local n = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapshotItemCount then
        n = StockPiler2.Inventory.GetSnapshotItemCount()
    end
    StockPiler2.Ui.Print(T("ui.bags_refreshed", { count = tostring(n) }))
end

function StockPiler2Window.ConfirmClearWatches()
    local n = 0
    if StockPiler2.Catalog and StockPiler2.Catalog.ClearWatchList then
        n = tonumber(StockPiler2.Catalog.ClearWatchList()) or 0
    end
    StockPiler2.Ui.Print(T("ui.watches_cleared", { count = tostring(n) }))
    if StockPiler2TabWatch and StockPiler2TabWatch.Refresh then
        StockPiler2TabWatch.Refresh()
    end
    StockPiler2Window.RefreshFooterButtons()
end

function StockPiler2Window.OnClearWatches()
    local watches = StockPiler2.Watch and StockPiler2.Watch.GetWatches and StockPiler2.Watch.GetWatches() or nil
    local count = 0
    if type(watches) == "table" then
        for _ in pairs(watches) do
            count = count + 1
        end
    end
    if count <= 0 then
        StockPiler2.Ui.Print(T("ui.no_watches"))
        return
    end
    if type(DialogManager) == "table" and type(DialogManager.MakeTwoButtonDialog) == "function" then
        local yes = GetString and GetString(StringTables.Default.LABEL_YES) or T("ui.yes")
        local no = GetString and GetString(StringTables.Default.LABEL_NO) or T("ui.no")
        DialogManager.MakeTwoButtonDialog(
            T("ui.clear_watches_confirm", { count = tostring(count) }),
            yes,
            StockPiler2Window.ConfirmClearWatches,
            no,
            nil
        )
        return
    end
    StockPiler2Window.ConfirmClearWatches()
end

function StockPiler2Window.OnMouseOverClearWatches()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("ui.clear_watches_tip"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2Window.OnHarvestPrepare()
    if StockPiler2.Grow and StockPiler2.Grow.CanHarvestNow then
        if StockPiler2.Grow.CanHarvestNow() ~= true then
            return
        end
    else
        local ready = 0
        if StockPiler2.Grow and StockPiler2.Grow.CountReadyHarvestPlots then
            ready = tonumber(StockPiler2.Grow.CountReadyHarvestPlots()) or 0
        end
        if ready <= 0 then
            return
        end
    end
    if DoesWindowExist(HARVEST_WIN) and ButtonGetDisabledFlag(HARVEST_WIN) == true then
        return
    end
    -- Set CurrentPlot before the engine fires PERFORM_CRAFTING on this gameactionbutton.
    local prepared = false
    if StockPiler2.Grow and StockPiler2.Grow.PrepareHarvestPlot then
        prepared = StockPiler2.Grow.PrepareHarvestPlot(true) == true
    end
    if prepared then
        if Sound and Sound.Play and Sound.CULTIVATING_HARVEST_CROP then
            Sound.Play(Sound.CULTIVATING_HARVEST_CROP)
        end
    end
end

--- Native gameactionbutton fires harvest. CultivationUpdated refreshes enable state;
--- avoid L-up bind/clear (chrome thrash + CanHarvestNow / macro sync cost).
function StockPiler2Window.OnHarvest()
end

function StockPiler2Window.OnMouseOverHarvest()
    if StockPiler2.Grow and StockPiler2.Grow.ShowHarvestTooltip then
        StockPiler2.Grow.ShowHarvestTooltip(
            SystemData.ActiveWindow.name,
            Tooltips.ANCHOR_WINDOW_TOP
        )
        return
    end
    local ready = 0
    if StockPiler2.Grow and StockPiler2.Grow.CountReadyHarvestPlots then
        ready = tonumber(StockPiler2.Grow.CountReadyHarvestPlots()) or 0
    end
    local tip = T("ui.harvest_tip")
    if ready > 0 then
        tip = T("ui.harvest_tip_ready", { count = tostring(ready) })
    else
        tip = T("ui.harvest_tip_none")
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, tip)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2Window.OnBrew()
    if DoesWindowExist(BREW_WIN) and ButtonGetDisabledFlag(BREW_WIN) == true then
        return
    end
    if not StockPiler2.Brew then
        return
    end
    local result = nil
    if StockPiler2.Brew.TryBrewClick then
        result = StockPiler2.Brew.TryBrewClick()
    end
    if result == "go" and StockPiler2.Brew.FirePerform then
        StockPiler2.Brew.FirePerform()
    end
    StockPiler2Window.RefreshFooterButtons()
end

function StockPiler2Window.OnBrewRightClick()
    if StockPiler2.Brew and StockPiler2.Brew.ClearLoadedSession then
        StockPiler2.Brew.ClearLoadedSession()
    end
    StockPiler2Window.RefreshFooterButtons()
end

function StockPiler2Window.OnMouseOverBrew()
    if StockPiler2.Brew and StockPiler2.Brew.ShowBrewTooltip then
        StockPiler2.Brew.ShowBrewTooltip(
            SystemData.ActiveWindow.name,
            Tooltips.ANCHOR_WINDOW_TOP
        )
        return
    end
    Tooltips.CreateTextOnlyTooltip(
        SystemData.ActiveWindow.name,
        T("ui.brew_tip_fallback")
    )
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPiler2Window.SelectTab(tabNumber)
    tabNumber = tonumber(tabNumber)
    if tabNumber == nil or tabNumber < StockPiler2Window.TABS_POTIONS or tabNumber > StockPiler2Window.TABS_MAX then
        return
    end
    StockPiler2Window.SelectedTab = tabNumber
    local s = StockPiler2.Persistence.EnsureSettings()
    if type(s) == "table" then
        s.selectedTab = tabNumber
    end
    for index, tab in ipairs(StockPiler2Window.Tabs) do
        local selected = (index == tabNumber)
        ButtonSetPressedFlag(tab.name, selected)
        if DoesWindowExist(tab.window) then
            WindowSetShowing(tab.window, selected)
            if selected and type(WindowForceProcessAnchors) == "function" then
                StockPiler2.Debug.TryCall("WindowForceProcessAnchors", WindowForceProcessAnchors, tab.window)
            end
        end
    end
    StockPiler2Window.RefreshActiveTab()
    StockPiler2Window.RequestListRepopulate()
end

function StockPiler2Window.OnLButtonUpTab()
    local tabId = WindowGetId(SystemData.ActiveWindow.name)
    StockPiler2Window.SelectTab(tabId)
end
