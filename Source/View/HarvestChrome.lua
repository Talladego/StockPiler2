----------------------------------------------------------------
-- StockPiler2 HarvestChrome — footer action binding and click gate
----------------------------------------------------------------

StockPiler2.HarvestChrome = StockPiler2.HarvestChrome or {}
local HarvestChrome = StockPiler2.HarvestChrome

local HARVEST_WIN = "StockPiler2WindowHarvest"
local HARVEST_ACTION_WIN = "StockPiler2WindowHarvestAction"
local CULTIVATION_HARVEST_WIN = "CultivationWindowHarvest"

local function T(key, tokens)
    if StockPiler2.T then
        return StockPiler2.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

local function LogGrow(msg)
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("grow", msg)
    end
end

local function RestoreHarvestChrome(windowName)
    if windowName == nil or windowName == "" or not DoesWindowExist(windowName) then
        return
    end
    if ButtonSetText then
        ButtonSetText(windowName, T("ui.harvest"))
    end
    if ButtonSetPressedFlag then
        ButtonSetPressedFlag(windowName, false)
    end
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
        ok, err = StockPiler2.TryCall(
            "WindowSetGameActionData",
            WindowSetGameActionData,
            windowName,
            action,
            cult,
            L""
        )
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

local function ClearHarvestBindOnly()
    local Grow = StockPiler2.Grow
    if Grow._harvestActionBound ~= true then
        return false
    end
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
            ok = StockPiler2.TryCall(
                "WindowSetGameActionData.clear",
                WindowSetGameActionData,
                windowName,
                none,
                0,
                L""
            )
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

function HarvestChrome.EnsureHarvestActionBound()
    local Grow = StockPiler2.Grow
    if Grow._harvestActionBound == true and DoesWindowExist(HARVEST_WIN) then
        return true
    end
    if BindCultivationHarvestAction(HARVEST_WIN)
        or BindCultivationHarvestAction(HARVEST_ACTION_WIN)
        or BindCultivationHarvestAction(CULTIVATION_HARVEST_WIN)
    then
        Grow._harvestActionBound = true
        return true
    end
    Grow._harvestActionBound = false
    return false
end

function HarvestChrome.SetFooterHarvestClickable(enabled)
    local Grow = StockPiler2.Grow
    if not DoesWindowExist(HARVEST_WIN) then
        return
    end
    enabled = enabled == true
    if WindowSetHandleInput then
        WindowSetHandleInput(HARVEST_WIN, true)
    end
    if Grow._footerHarvestClickable == enabled then
        return
    end
    if ButtonSetDisabledFlag then
        ButtonSetDisabledFlag(HARVEST_WIN, not enabled)
    end
    if enabled then
        HarvestChrome.EnsureHarvestActionBound()
    else
        ClearHarvestBindOnly()
    end
    Grow._footerHarvestClickable = enabled
end

function HarvestChrome.ClearHarvestActionBound()
    local Grow = StockPiler2.Grow
    Grow._footerHarvestClickable = nil
    local cleared = ClearHarvestBindOnly()
    if DoesWindowExist(HARVEST_WIN) and WindowSetHandleInput then
        WindowSetHandleInput(HARVEST_WIN, true)
    end
    return cleared
end

function HarvestChrome.FireHarvestAction()
    if StockPiler2.Macro and StockPiler2.Macro.FireHarvestGameAction then
        if StockPiler2.Macro.FireHarvestGameAction() == true then
            LogGrow("FireHarvestAction ok via macro")
            return true
        end
    end
    HarvestChrome.EnsureHarvestActionBound()
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
    return tryWin(HARVEST_WIN, true)
        or tryWin(HARVEST_ACTION_WIN, true)
        or tryWin(CULTIVATION_HARVEST_WIN, true)
end
