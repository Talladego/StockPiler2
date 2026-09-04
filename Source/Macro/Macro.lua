----------------------------------------------------------------
-- StockPiler2 Macro — ActionBar Harvest / Brew macros
-- (WarTriage / GatherButton / SP1 pattern). Macros only; does
-- not hijack stock Cultivating / Apothecary craft skills.
----------------------------------------------------------------

StockPiler2.Macro = StockPiler2.Macro or {}
local Macro = StockPiler2.Macro

local MACRO_NAME = L"StockPiler2 Harvest"
local MACRO_TEXT = L"/script StockPiler2.Macro.HarvestClick()"
local MACRO_ICON = 2486 -- Abi_or_Mushroom01.dds (+ _disabled)

local BREW_MACRO_NAME = L"StockPiler2 Brew"
local BREW_MACRO_TEXT = L"/script StockPiler2.Macro.BrewClick()"
local BREW_MACRO_ICON = 10985 -- abi_de_elixirofmaddenedspeed.dds (+ _disabled)

local actionButtonHooksInstalled = false
local setActionDataHooked = false
local hotbarEventRegistered = false
local tooltipHookInstalled = false
local gameActionBindCache = {}

Macro.MacroId = 0
Macro.BrewMacroId = 0
Macro.MacroWarningState = { missing = false, unplaced = false, full = false }
Macro.BrewMacroWarningState = { missing = false, unplaced = false, full = false }

local function D(msg)
    if StockPiler2.D then
        StockPiler2.D("[Macro] " .. tostring(msg))
    end
end

local function Print(msg)
    if StockPiler2.Debug and StockPiler2.Debug.Print then
        StockPiler2.Debug.Print(msg)
    end
end

local function TryCall(context, fn, ...)
    if StockPiler2.TryCall then
        return StockPiler2.TryCall(context, fn, ...)
    end
    return pcall(fn, ...)
end

local function BindCacheKey(button)
    if not button then
        return nil
    end
    if type(button.GetName) == "function" then
        local name = button:GetName()
        if name ~= nil and name ~= "" then
            return name
        end
    end
    return button.m_Name
end

local function ClearGameActionBindCache()
    gameActionBindCache = {}
end

local function GameActionAlreadyBound(button, token)
    local key = BindCacheKey(button)
    if key == nil or token == nil then
        return false
    end
    return gameActionBindCache[key] == token
end

local function RememberGameActionBind(button, token)
    local key = BindCacheKey(button)
    if key ~= nil and token ~= nil then
        gameActionBindCache[key] = token
    end
end

local function ForgetGameActionBind(button)
    local key = BindCacheKey(button)
    if key ~= nil then
        gameActionBindCache[key] = nil
    end
end

local function ActionWindowName(button)
    if not button then
        return nil
    end
    if button.m_Name and button.m_Name ~= "" then
        return button.m_Name .. "Action"
    end
    if type(button.GetName) == "function" then
        local name = button:GetName()
        if name ~= nil and name ~= "" then
            return name .. "Action"
        end
    end
    return nil
end

local function setButtonEnabledVisual(button, canUse)
    canUse = canUse == true
    if type(button.UpdateEnabledState) == "function" then
        button:UpdateEnabledState(canUse, true, false)
        return
    end
    local win = button.m_Name
    if (win == nil or win == "") and type(button.GetName) == "function" then
        win = button:GetName()
    end
    if win and win ~= "" and ButtonSetDisabledFlag then
        ButtonSetDisabledFlag(win, not canUse)
    end
end

local function canHarvestMacro()
    return StockPiler2.Grow and StockPiler2.Grow.CanHarvestNow
        and StockPiler2.Grow.CanHarvestNow() == true
end

local function canBrewMacro()
    return StockPiler2.Brew and StockPiler2.Brew.CanBrewNow
        and StockPiler2.Brew.CanBrewNow() == true
end

local function GetMacroTable()
    if type(GetMacrosData) == "function" then
        return GetMacrosData()
    end
    if DataUtils and type(DataUtils.GetMacros) == "function" then
        return DataUtils.GetMacros()
    end
    return {}
end

local function NumMacroSlots()
    if EA_Window_Macro and tonumber(EA_Window_Macro.NUM_MACROS) then
        return tonumber(EA_Window_Macro.NUM_MACROS)
    end
    local macros = GetMacroTable()
    return #macros
end

local function MacroText(macroData)
    if type(macroData) ~= "table" then
        return L""
    end
    return macroData.text or macroData.macroText or macroData.body or macroData.command or L""
end

local function FindMacroSlot(name, text, cachedId)
    cachedId = tonumber(cachedId) or 0
    if cachedId > 0 then
        return cachedId
    end
    local macros = GetMacroTable()
    local limit = NumMacroSlots()
    for slot = 1, limit do
        local macro = macros[slot]
        if type(macro) == "table" then
            if MacroText(macro) == text then
                return slot
            end
            if macro.name == name then
                return slot
            end
        end
    end
    return nil
end

function Macro.GetMacroId()
    local slot = FindMacroSlot(MACRO_NAME, MACRO_TEXT, Macro.MacroId)
    if slot then
        Macro.MacroId = slot
    end
    return slot
end

function Macro.GetBrewMacroId()
    local slot = FindMacroSlot(BREW_MACRO_NAME, BREW_MACRO_TEXT, Macro.BrewMacroId)
    if slot then
        Macro.BrewMacroId = slot
    end
    return slot
end

function Macro.GetMacroSlots(macroId)
    macroId = tonumber(macroId) or 0
    local slots = {}
    if macroId <= 0 or not ActionBars or not ActionBars.m_Bars then
        return slots
    end
    for i = 1, #ActionBars.m_Bars do
        local bar = ActionBars.m_Bars[i]
        if bar and bar.m_Buttons then
            for j = 1, #bar.m_Buttons do
                local button = bar.m_Buttons[j]
                if button
                    and button.m_ActionType == GameData.PlayerActions.DO_MACRO
                    and button.m_ActionId == macroId
                then
                    slots[#slots + 1] = button.m_HotBarSlot
                end
            end
        end
    end
    return slots
end

local function SetMacroSlot(slot, name, text, iconId, kind)
    SetMacroData(name, text, iconId, slot)
    if EA_Window_Macro and EA_Window_Macro.UpdateDetails then
        TryCall("EA_Window_Macro.UpdateDetails", EA_Window_Macro.UpdateDetails, slot)
    end
    if kind == "brew" then
        Macro.BrewMacroId = slot
    else
        Macro.MacroId = slot
    end
end

function Macro.UpdateMacro()
    local macros = GetMacroTable()
    local limit = NumMacroSlots()

    local existing = Macro.GetMacroId()
    if existing then
        SetMacroSlot(existing, MACRO_NAME, MACRO_TEXT, MACRO_ICON)
        Macro.MacroWarningState.full = false
        Macro.MacroWarningState.missing = false
        return true
    end

    for slot = 1, limit do
        local macro = macros[slot]
        if type(macro) == "table" and MacroText(macro) == L"" and (macro.name == nil or macro.name == L"") then
            SetMacroSlot(slot, MACRO_NAME, MACRO_TEXT, MACRO_ICON)
            Print(L"<icon" .. towstring(tostring(MACRO_ICON)) .. L"> StockPiler2 Harvest macro created (slot "
                .. towstring(tostring(slot)) .. L"). Drag it to your action bar.")
            Macro.MacroWarningState.full = false
            Macro.MacroWarningState.missing = false
            return true
        end
    end

    if not Macro.MacroWarningState.full then
        Print(L"StockPiler2: could not create Harvest macro (no empty macro slot).")
        Macro.MacroWarningState.full = true
    end
    return false
end

function Macro.UpdateBrewMacro()
    local macros = GetMacroTable()
    local limit = NumMacroSlots()

    local existing = Macro.GetBrewMacroId()
    if existing then
        SetMacroSlot(existing, BREW_MACRO_NAME, BREW_MACRO_TEXT, BREW_MACRO_ICON, "brew")
        Macro.BrewMacroWarningState.full = false
        Macro.BrewMacroWarningState.missing = false
        return true
    end

    for slot = 1, limit do
        local macro = macros[slot]
        if type(macro) == "table" and MacroText(macro) == L"" and (macro.name == nil or macro.name == L"") then
            SetMacroSlot(slot, BREW_MACRO_NAME, BREW_MACRO_TEXT, BREW_MACRO_ICON, "brew")
            Print(L"<icon" .. towstring(tostring(BREW_MACRO_ICON)) .. L"> StockPiler2 Brew macro created (slot "
                .. towstring(tostring(slot)) .. L"). Drag it to your action bar.")
            Macro.BrewMacroWarningState.full = false
            Macro.BrewMacroWarningState.missing = false
            return true
        end
    end

    if not Macro.BrewMacroWarningState.full then
        Print(L"StockPiler2: could not create Brew macro (no empty macro slot).")
        Macro.BrewMacroWarningState.full = true
    end
    return false
end

local function CultivationTradeSkill()
    if GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION then
        return GameData.TradeSkills.CULTIVATION
    end
    return 3
end

local function ApothecaryTradeSkill()
    if GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY then
        return GameData.TradeSkills.APOTHECARY
    end
    return 4
end

local function PerformCraftingAction()
    if GameData and GameData.PlayerActions and GameData.PlayerActions.PERFORM_CRAFTING then
        return GameData.PlayerActions.PERFORM_CRAFTING
    end
    return 8
end

local function NonePlayerAction()
    if GameData and GameData.PlayerActions and GameData.PlayerActions.NONE ~= nil then
        return GameData.PlayerActions.NONE
    end
    return 0
end

local function bindHarvestGameAction(button)
    if not button or not button.m_Name or WindowSetGameActionData == nil then
        return false
    end
    local actionName = button.m_Name .. "Action"
    if not DoesWindowExist(actionName) then
        return false
    end
    local ok = TryCall(
        "WindowSetGameActionData", WindowSetGameActionData,
        actionName,
        PerformCraftingAction(),
        CultivationTradeSkill(),
        L""
    )
    return ok == true
end

local function bindHarvestGameActionForButton(button)
    if not button then
        return false
    end
    if GameActionAlreadyBound(button, "harvest") then
        return true
    end
    if button.m_Name and bindHarvestGameAction(button) then
        RememberGameActionBind(button, "harvest")
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = TryCall(
                "WindowSetGameActionData", WindowSetGameActionData,
                actionName,
                PerformCraftingAction(),
                CultivationTradeSkill(),
                L""
            )
            if ok == true then
                RememberGameActionBind(button, "harvest")
            end
            return ok == true
        end
    end
    return false
end

local function clearHarvestGameActionForButton(button)
    if not button or WindowSetGameActionData == nil then
        return false
    end
    local actionName = ActionWindowName(button)
    if actionName == nil or not DoesWindowExist(actionName) then
        return false
    end
    local ok = TryCall(
        "WindowSetGameActionData.clear", WindowSetGameActionData,
        actionName,
        NonePlayerAction(),
        0,
        L""
    )
    ForgetGameActionBind(button)
    return ok == true
end

local function bindBrewGameAction(button)
    if not button or not button.m_Name or WindowSetGameActionData == nil then
        return false
    end
    local actionName = button.m_Name .. "Action"
    if not DoesWindowExist(actionName) then
        return false
    end
    local ok = TryCall(
        "WindowSetGameActionData", WindowSetGameActionData,
        actionName,
        PerformCraftingAction(),
        ApothecaryTradeSkill(),
        L""
    )
    return ok == true
end

local function bindBrewGameActionForButton(button)
    if not button then
        return false
    end
    if GameActionAlreadyBound(button, "brew") then
        return true
    end
    if button.m_Name and bindBrewGameAction(button) then
        RememberGameActionBind(button, "brew")
        return true
    end
    if type(button.GetName) == "function" then
        local actionName = button:GetName() .. "Action"
        if WindowSetGameActionData and DoesWindowExist(actionName) then
            local ok = TryCall(
                "WindowSetGameActionData", WindowSetGameActionData,
                actionName,
                PerformCraftingAction(),
                ApothecaryTradeSkill(),
                L""
            )
            if ok == true then
                RememberGameActionBind(button, "brew")
            end
            return ok == true
        end
    end
    return false
end

function Macro.IsMacroButton(button)
    if not button or button.m_ActionType ~= GameData.PlayerActions.DO_MACRO then
        return false
    end
    local macroId = Macro.GetMacroId()
    return macroId ~= nil and button.m_ActionId == macroId
end

function Macro.IsBrewMacroButton(button)
    if not button or button.m_ActionType ~= GameData.PlayerActions.DO_MACRO then
        return false
    end
    local macroId = Macro.GetBrewMacroId()
    return macroId ~= nil and button.m_ActionId == macroId
end

--- Fire PERFORM_CRAFTING via a placed Harvest macro Action window.
function Macro.FireHarvestGameAction()
    if type(WindowGameAction) ~= "function" or not ActionBars or not ActionBars.BarAndButtonIdFromSlot then
        return false
    end
    local function tryButton(button)
        if not button or not button.m_Name then
            return false
        end
        local actionName = button.m_Name .. "Action"
        if not DoesWindowExist(actionName) then
            return false
        end
        if not bindHarvestGameActionForButton(button) then
            return false
        end
        local ok = TryCall("WindowGameAction", WindowGameAction, actionName)
        return ok == true
    end
    local macroId = Macro.GetMacroId()
    if not macroId then
        return false
    end
    local slots = Macro.GetMacroSlots(macroId) or {}
    for i = 1, #slots do
        local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
        local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
        if tryButton(button) then
            return true
        end
    end
    return false
end

local function clearPickupIfMouse(flags)
    if SystemData and SystemData.ButtonFlags
        and flags ~= SystemData.ButtonFlags.GAME_ACTION
        and ActionBars and ActionBars.SetPickupButton
    then
        ActionBars:SetPickupButton(nil)
    end
end

function Macro.ApplyButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = opts or {}
    local canUse = canHarvestMacro()
    setButtonEnabledVisual(button, canUse)
    if canUse then
        bindHarvestGameActionForButton(button)
    else
        clearHarvestGameActionForButton(button)
    end
end

function Macro.ApplyBrewButtonAppearance(button, opts)
    if not button then
        return
    end
    opts = opts or {}
    local canUse = canBrewMacro()
    setButtonEnabledVisual(button, canUse)
    -- Keep apo bind for chrome; activation uses Lua FirePerform.
    bindBrewGameActionForButton(button)
end

function Macro.RefreshMacroButtonAppearance()
    if Macro._refreshingAppearance == true then
        Macro._appearanceDirty = true
        return
    end
    if not ActionBars or not ActionBars.m_Bars then
        return
    end
    Macro._refreshingAppearance = true
    local ok, err = pcall(function()
        local canHarvest = canHarvestMacro()
        local canBrew = canBrewMacro()
        local appearanceKey = tostring(canHarvest) .. ":" .. tostring(canBrew)
        if Macro._lastAppearanceKey == appearanceKey then
            return
        end
        Macro._lastAppearanceKey = appearanceKey

        local macroId = Macro.GetMacroId()
        local brewId = Macro.GetBrewMacroId()

        if macroId then
            local slots = Macro.GetMacroSlots(macroId)
            if #slots == 0 then
                if not Macro.MacroWarningState.unplaced then
                    Print(L"<icon" .. towstring(tostring(MACRO_ICON))
                        .. L"> StockPiler2 Harvest macro is not on any action bar. Drag it from the macro list to a hotbar slot.")
                    Macro.MacroWarningState.unplaced = true
                end
            else
                Macro.MacroWarningState.unplaced = false
                for i = 1, #slots do
                    local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
                    local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
                    if button then
                        Macro.ApplyButtonAppearance(button)
                    end
                end
            end
        end

        if brewId then
            local slots = Macro.GetMacroSlots(brewId)
            if #slots == 0 then
                if not Macro.BrewMacroWarningState.unplaced then
                    Print(L"<icon" .. towstring(tostring(BREW_MACRO_ICON))
                        .. L"> StockPiler2 Brew macro is not on any action bar. Drag it from the macro list to a hotbar slot.")
                    Macro.BrewMacroWarningState.unplaced = true
                end
            else
                Macro.BrewMacroWarningState.unplaced = false
                for i = 1, #slots do
                    local hbar, buttonId = ActionBars:BarAndButtonIdFromSlot(slots[i])
                    local button = hbar and hbar.m_Buttons and hbar.m_Buttons[buttonId]
                    if button then
                        Macro.ApplyBrewButtonAppearance(button)
                    end
                end
            end
        end
    end)
    Macro._refreshingAppearance = false
    if ok ~= true then
        D("refresh failed: " .. tostring(err))
    end
    if Macro._appearanceDirty == true then
        Macro._appearanceDirty = false
        Macro._lastAppearanceKey = nil
        Macro.RefreshMacroButtonAppearance()
    end
end

--- Sync enabled visuals with footer canHarvest/canBrew (appearance-key short-circuits).
function Macro.SyncEnabledState()
    Macro.RefreshMacroButtonAppearance()
end

local function applySetActionDataAppearance(button, actionType, actionId)
    if not button then
        return
    end
    if actionType ~= GameData.PlayerActions.DO_MACRO then
        return
    end
    local harvestId = Macro.GetMacroId()
    local brewId = Macro.GetBrewMacroId()
    if harvestId ~= nil and actionId == harvestId then
        Macro.ApplyButtonAppearance(button)
        return
    end
    if brewId ~= nil and actionId == brewId then
        Macro.ApplyBrewButtonAppearance(button)
    end
end

local function installSetActionDataHook()
    if not ActionButton or type(ActionButton.SetActionData) ~= "function" then
        return
    end
    if setActionDataHooked then
        return
    end
    local orgSetActionData = ActionButton.SetActionData
    ActionButton.SetActionData = function(self, actionType, actionId)
        orgSetActionData(self, actionType, actionId)
        applySetActionDataAppearance(self, actionType, actionId)
    end
    setActionDataHooked = true
end

local function handleMacroHarvestActivation(flags)
    if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
        return "cursor"
    end
    local Grow = StockPiler2.Grow
    if Grow and Grow.CanHarvestNow then
        if Grow.CanHarvestNow() ~= true then
            clearPickupIfMouse(flags)
            return "blocked"
        end
    else
        local ready = Grow and Grow.CountReadyHarvestPlots and Grow.CountReadyHarvestPlots() or 0
        if (tonumber(ready) or 0) <= 0 then
            clearPickupIfMouse(flags)
            return "blocked"
        end
        if StockPiler2.Brew and StockPiler2.Brew.BlocksHarvest
            and StockPiler2.Brew.BlocksHarvest() == true
        then
            clearPickupIfMouse(flags)
            return "blocked"
        end
    end
    if Grow and Grow.PrepareHarvestPlot then
        if Grow.PrepareHarvestPlot(true) ~= true then
            clearPickupIfMouse(flags)
            return "blocked"
        end
    end
    return "go"
end

local function handleMacroBrewActivation(flags)
    if Cursor and Cursor.IconOnCursor and Cursor.IconOnCursor() then
        return "cursor"
    end
    if not canBrewMacro() then
        clearPickupIfMouse(flags)
        return "blocked"
    end
    if not (StockPiler2.Brew and StockPiler2.Brew.TryBrewClick) then
        clearPickupIfMouse(flags)
        return "blocked"
    end
    local result = StockPiler2.Brew.TryBrewClick()
    if result == "go" then
        return "go"
    end
    clearPickupIfMouse(flags)
    return "blocked"
end

local function installActionButtonHooks()
    if actionButtonHooksInstalled or not ActionButton then
        return
    end

    local orgOnLButtonUp = ActionButton.OnLButtonUp
    ActionButton.OnLButtonUp = function(self, flags, x, y)
        if Macro.IsMacroButton(self) then
            if not canHarvestMacro() then
                clearHarvestGameActionForButton(self)
                clearPickupIfMouse(flags)
                return
            end
            bindHarvestGameActionForButton(self)
            local result = handleMacroHarvestActivation(flags)
            if result == "cursor" or result == "go" then
                if orgOnLButtonUp then
                    orgOnLButtonUp(self, flags, x, y)
                end
                return
            end
            if result == "blocked" then
                return
            end
        elseif Macro.IsBrewMacroButton(self) then
            local result = handleMacroBrewActivation(flags)
            if result == "cursor" then
                if orgOnLButtonUp then
                    orgOnLButtonUp(self, flags, x, y)
                end
                return
            end
            if result == "go" then
                Macro._brewFired = true
                if StockPiler2.Brew and StockPiler2.Brew.FirePerform then
                    StockPiler2.Brew.FirePerform()
                end
                return
            end
            if result == "blocked" then
                return
            end
        end
        if orgOnLButtonUp then
            orgOnLButtonUp(self, flags, x, y)
        end
    end

    actionButtonHooksInstalled = true
end

local function installMacroTooltipHook()
    if tooltipHookInstalled or not Tooltips or type(Tooltips.CreateMacroTooltip) ~= "function" then
        return
    end
    local orgCreateMacroTooltip = Tooltips.CreateMacroTooltip
    Tooltips.CreateMacroTooltip = function(macroData, mouseoverWindow, anchor, extraText)
        local harvestId = Macro.GetMacroId()
        local brewId = Macro.GetBrewMacroId()
        local isHarvest = false
        local isBrew = false
        if type(macroData) == "table" then
            if harvestId and (macroData.slot == harvestId or macroData.index == harvestId or macroData.macroIndex == harvestId) then
                isHarvest = true
            elseif macroData.name == MACRO_NAME or MacroText(macroData) == MACRO_TEXT then
                isHarvest = true
            end
            if brewId and (macroData.slot == brewId or macroData.index == brewId or macroData.macroIndex == brewId) then
                isBrew = true
            elseif macroData.name == BREW_MACRO_NAME or MacroText(macroData) == BREW_MACRO_TEXT then
                isBrew = true
            end
        end
        if isHarvest then
            if StockPiler2.Grow and StockPiler2.Grow.ShowHarvestTooltip then
                StockPiler2.Grow.ShowHarvestTooltip(mouseoverWindow, anchor or Tooltips.ANCHOR_WINDOW_TOP)
            end
            return
        end
        if isBrew then
            if StockPiler2.Brew and StockPiler2.Brew.ShowBrewTooltip then
                StockPiler2.Brew.ShowBrewTooltip(mouseoverWindow, anchor or Tooltips.ANCHOR_WINDOW_TOP)
            end
            return
        end
        return orgCreateMacroTooltip(macroData, mouseoverWindow, anchor, extraText)
    end
    tooltipHookInstalled = true
end

function Macro.OnHotBarUpdated()
    ClearGameActionBindCache()
    Macro.SyncEnabledState()
end

function Macro.RegisterHotbarEventHandler()
    if hotbarEventRegistered or not SystemData or not SystemData.Events then
        return
    end
    if SystemData.Events.PLAYER_HOT_BAR_UPDATED then
        RegisterEventHandler(SystemData.Events.PLAYER_HOT_BAR_UPDATED, "StockPiler2.Macro.OnHotBarUpdated")
        hotbarEventRegistered = true
    end
end

function Macro.UnregisterHotbarEventHandler()
    if not hotbarEventRegistered or not SystemData or not SystemData.Events then
        return
    end
    if SystemData.Events.PLAYER_HOT_BAR_UPDATED then
        UnregisterEventHandler(SystemData.Events.PLAYER_HOT_BAR_UPDATED, "StockPiler2.Macro.OnHotBarUpdated")
    end
    hotbarEventRegistered = false
end

function Macro.HarvestClick()
    local Grow = StockPiler2.Grow
    if not Grow then
        return
    end
    if Grow.CanHarvestNow and Grow.CanHarvestNow() ~= true then
        return
    end
    if Grow.PrepareHarvestPlot and Grow.PrepareHarvestPlot(true) ~= true then
        return
    end
    if Macro.FireHarvestGameAction() then
        return
    end
    if Grow.FireHarvestAction then
        Grow.FireHarvestAction()
    end
end

function Macro.BrewClick()
    if Macro._brewFired == true then
        Macro._brewFired = false
        return
    end
    if not canBrewMacro() then
        Macro._brewFired = false
        return
    end
    local Brew = StockPiler2.Brew
    if not Brew or not Brew.TryBrewClick then
        Macro._brewFired = false
        return
    end
    local result = Brew.TryBrewClick()
    if result == "go" and Brew.FirePerform then
        Brew.FirePerform()
    end
    Macro._brewFired = false
end

function Macro.Initialize()
    if Macro._initialized then
        Macro.UpdateMacro()
        Macro.UpdateBrewMacro()
        Macro.RefreshMacroButtonAppearance()
        return
    end
    installSetActionDataHook()
    installActionButtonHooks()
    installMacroTooltipHook()
    Macro.UpdateMacro()
    Macro.UpdateBrewMacro()
    Macro.RegisterHotbarEventHandler()
    Macro.RefreshMacroButtonAppearance()
    Macro._initialized = true
    D("Initialize harvestId=" .. tostring(Macro.GetMacroId())
        .. " brewId=" .. tostring(Macro.GetBrewMacroId()))
end

function Macro.Shutdown()
    Macro.UnregisterHotbarEventHandler()
    Macro._initialized = false
end
