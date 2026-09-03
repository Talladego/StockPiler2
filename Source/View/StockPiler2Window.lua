----------------------------------------------------------------
-- StockPiler2Window — settings-style chrome
----------------------------------------------------------------

StockPiler2Window = {}

StockPiler2Window.TABS_POTIONS = 1
StockPiler2Window.TABS_WATCH = 2
StockPiler2Window.TABS_MAX = 2
StockPiler2Window.SelectedTab = StockPiler2Window.TABS_POTIONS

local CLEAR_WATCHES_WIN = "StockPiler2WindowClearWatches"
local HARVEST_WIN = "StockPiler2WindowHarvest"

StockPiler2Window.Tabs = {
    [1] = {
        window = "SP2TabPotions",
        name = "StockPiler2WindowTabButtonsPotions",
        label = L"Potions",
        refresh = function()
            if StockPiler2TabPotions and StockPiler2TabPotions.Refresh then
                StockPiler2TabPotions.Refresh()
            end
        end,
    },
    [2] = {
        window = "SP2TabWatch",
        name = "StockPiler2WindowTabButtonsWatch",
        label = L"Watch",
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

function StockPiler2Window.RefreshFooterButtons()
    local onWatch = StockPiler2Window.SelectedTab == StockPiler2Window.TABS_WATCH
    local onPotions = StockPiler2Window.SelectedTab == StockPiler2Window.TABS_POTIONS
    if DoesWindowExist(CLEAR_WATCHES_WIN) then
        WindowSetShowing(CLEAR_WATCHES_WIN, onPotions)
    end
    if DoesWindowExist(HARVEST_WIN) then
        WindowSetShowing(HARVEST_WIN, onWatch)
        if onWatch then
            local ready = 0
            if StockPiler2.Grow and StockPiler2.Grow.CountReadyHarvestPlots then
                ready = tonumber(StockPiler2.Grow.CountReadyHarvestPlots()) or 0
            end
            local canHarvest = ready > 0
            ButtonSetDisabledFlag(HARVEST_WIN, not canHarvest)
            -- Disabled buttons still fire gameactionbutton if bound — bind/clear with ready state.
            if canHarvest then
                if StockPiler2.Grow and StockPiler2.Grow.EnsureHarvestActionBound then
                    StockPiler2.Grow.EnsureHarvestActionBound()
                end
            elseif StockPiler2.Grow and StockPiler2.Grow.ClearHarvestActionBound then
                StockPiler2.Grow.ClearHarvestActionBound()
            end
        elseif StockPiler2.Grow and StockPiler2.Grow.ClearHarvestActionBound then
            StockPiler2.Grow.ClearHarvestActionBound()
        end
    end
end

function StockPiler2Window.Initialize()
    if not DoesWindowExist("StockPiler2Window") then
        return
    end
    local version = StockPiler2.Version or L""
    if version ~= L"" then
        LabelSetText("StockPiler2WindowTitleBarText", L"StockPiler2 v" .. version)
    else
        LabelSetText("StockPiler2WindowTitleBarText", L"StockPiler2")
    end
    if DoesWindowExist(CLEAR_WATCHES_WIN) then
        ButtonSetText(CLEAR_WATCHES_WIN, L"Clear watches")
    end
    if DoesWindowExist(HARVEST_WIN) then
        ButtonSetText(HARVEST_WIN, L"Harvest")
        if StockPiler2.Grow and StockPiler2.Grow.EnsureHarvestActionBound then
            StockPiler2.Grow.EnsureHarvestActionBound()
        end
    end
    for _, tab in ipairs(StockPiler2Window.Tabs) do
        ButtonSetText(tab.name, tab.label)
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
    StockPiler2Window._repopulatePending = false
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
    StockPiler2.Ui.Print(L"Refreshed local bags (" .. towstring(tostring(n)) .. L" item stacks).")
end

function StockPiler2Window.OnClearWatches()
    local n = 0
    if StockPiler2.Catalog and StockPiler2.Catalog.ClearWatchList then
        n = tonumber(StockPiler2.Catalog.ClearWatchList()) or 0
    end
    StockPiler2.Ui.Print(L"Cleared " .. towstring(tostring(n)) .. L" watch(es) for this character.")
    if StockPiler2TabWatch and StockPiler2TabWatch.Refresh then
        StockPiler2TabWatch.Refresh()
    end
    StockPiler2Window.RefreshFooterButtons()
end

function StockPiler2Window.OnMouseOverClearWatches()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, L"Remove all watches for this character.")
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2Window.OnHarvestPrepare()
    local ready = 0
    if StockPiler2.Grow and StockPiler2.Grow.CountReadyHarvestPlots then
        ready = tonumber(StockPiler2.Grow.CountReadyHarvestPlots()) or 0
    end
    if ready <= 0 then
        return
    end
    if DoesWindowExist(HARVEST_WIN) and ButtonGetDisabledFlag(HARVEST_WIN) == true then
        return
    end
    -- Set CurrentPlot before the game action fires (often before OnLButtonUp).
    local prepared = false
    if StockPiler2.Grow and StockPiler2.Grow.PrepareHarvestPlot then
        prepared = StockPiler2.Grow.PrepareHarvestPlot(true) == true
    end
    if prepared and Sound and Sound.Play and Sound.CULTIVATING_HARVEST_CROP then
        Sound.Play(Sound.CULTIVATING_HARVEST_CROP)
    end
end

function StockPiler2Window.OnHarvest()
    -- Game action already fired; only refresh footer enable state.
    StockPiler2Window.RefreshFooterButtons()
end

function StockPiler2Window.OnMouseOverHarvest()
    local ready = 0
    if StockPiler2.Grow and StockPiler2.Grow.CountReadyHarvestPlots then
        ready = tonumber(StockPiler2.Grow.CountReadyHarvestPlots()) or 0
    end
    local tip = L"Harvest the next ready plot."
    if ready > 0 then
        tip = tip .. L" Ready: " .. towstring(tostring(ready)) .. L"."
    else
        tip = tip .. L" None ready."
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, tip)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
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
