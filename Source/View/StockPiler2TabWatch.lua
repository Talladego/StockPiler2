----------------------------------------------------------------
-- StockPiler2TabWatch — watched potion dashboard
-- Footer Clear watches / Harvest live on StockPiler2Window (Watch tab only).
----------------------------------------------------------------

StockPiler2TabWatch = {}
StockPiler2TabWatch.listData = {}
StockPiler2TabWatch.displayOrder = {}

local ICON_SCALE = 0.34
local TARGET_MAX = 200
local ENABLE_WIN = "SP2TabWatchEnable"
local ADDITIVES_WIN = "SP2TabWatchAdditives"
local AUTOBUY_WIN = "SP2TabWatchAutoBuy"
local SEED_BUFFER_ENABLE_WIN = "SP2TabWatchSeedBufferEnable"
local syncingUi = false
local STEPPER_BG = { 96, 86, 52 }

-- Traffic light: OK (green) / WARN (yellow) / BLOCK (red). Shared by Status, Stock, Craftable.
local COLOR_OK = { 180, 220, 180 }
local COLOR_WARN = { 255, 200, 120 }
local COLOR_BLOCK = { 220, 120, 120 }

local CRAFT_COLOR_BREW = { 140, 210, 140 }
local CRAFT_COLOR_LOAD = { 255, 220, 120 }
local CRAFT_COLOR_IDLE = { 140, 140, 140 }

local function SetButtonTextColorAll(windowName, r, g, b)
    if not windowName or not DoesWindowExist(windowName) or type(ButtonSetTextColor) ~= "function" then
        return
    end
    local states = { 0, 1, 2, 3, 4 }
    if Button and Button.ButtonState then
        states = {
            Button.ButtonState.NORMAL or 0,
            Button.ButtonState.HIGHLIGHTED or 1,
            Button.ButtonState.PRESSED or 2,
            Button.ButtonState.PRESSED_HIGHLIGHTED or 3,
            Button.ButtonState.DISABLED or 4,
        }
    end
    for i = 1, #states do
        StockPiler2.TryCall("ButtonSetTextColor", ButtonSetTextColor, windowName, states[i], r, g, b)
    end
end

local function ApplyRowBrewButton(loadWin, data)
    if not loadWin or not DoesWindowExist(loadWin) then
        return
    end
    local show = data.hasRecipe == true or data.canLoad == true or data.canBrew == true
        or (tonumber(data.craftable) or 0) > 0
    if not show then
        WindowSetShowing(loadWin, false)
        return
    end
    WindowSetShowing(loadWin, true)
    local state = "idle"
    if StockPiler2.Brew and StockPiler2.Brew.GetRowCraftUiState then
        state = StockPiler2.Brew.GetRowCraftUiState(data) or "idle"
    end
    if state == "loaded" then
        ButtonSetText(loadWin, L"Brew")
        ButtonSetDisabledFlag(loadWin, false)
        SetButtonTextColorAll(loadWin, CRAFT_COLOR_BREW[1], CRAFT_COLOR_BREW[2], CRAFT_COLOR_BREW[3])
    elseif state == "loading" then
        ButtonSetText(loadWin, L"Load")
        ButtonSetDisabledFlag(loadWin, true)
        SetButtonTextColorAll(loadWin, CRAFT_COLOR_LOAD[1], CRAFT_COLOR_LOAD[2], CRAFT_COLOR_LOAD[3])
    elseif state == "load" then
        ButtonSetText(loadWin, L"Load")
        ButtonSetDisabledFlag(loadWin, false)
        SetButtonTextColorAll(loadWin, CRAFT_COLOR_LOAD[1], CRAFT_COLOR_LOAD[2], CRAFT_COLOR_LOAD[3])
    else
        ButtonSetText(loadWin, L"Idle")
        ButtonSetDisabledFlag(loadWin, true)
        SetButtonTextColorAll(loadWin, CRAFT_COLOR_IDLE[1], CRAFT_COLOR_IDLE[2], CRAFT_COLOR_IDLE[3])
    end
end

local STATUS_COLORS = {
    no_target = { 180, 180, 180 },
    no_recipe = COLOR_BLOCK,
    potion_stocked = COLOR_OK,
    ready_to_craft = COLOR_OK,
    ready_to_craft_shared = COLOR_WARN,
    restocking = COLOR_WARN,
    enable_autogrow = COLOR_BLOCK,
    need_apothecary = COLOR_BLOCK,
    need_materials = COLOR_BLOCK, -- fallback if old plan cache
    buy_ingredients = COLOR_BLOCK,
    need_seeds = COLOR_WARN,
}

local function CanAutoGrowUi()
    local Caps = StockPiler2.TradeSkillCaps
    return Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true
end

local function CanAutoBuyUi()
    local Caps = StockPiler2.TradeSkillCaps
    return Caps and Caps.CanAutoBuy and Caps.CanAutoBuy() == true
end

local function RgbDef(rgb)
    if type(rgb) ~= "table" then
        return nil
    end
    return { r = rgb[1] or 255, g = rgb[2] or 255, b = rgb[3] or 255 }
end

local function CharRow()
    return StockPiler2.Watch and StockPiler2.Watch.CharacterRow() or nil
end

local function TintStepper(windowName)
    if windowName and DoesWindowExist(windowName) then
        WindowSetTintColor(windowName, STEPPER_BG[1], STEPPER_BG[2], STEPPER_BG[3])
    end
end

local function SetChipNumber(valueWin, chipWin, value)
    local text = towstring(tostring(value))
    if DoesWindowExist(valueWin) then
        LabelSetText(valueWin, L"")
        LabelSetText(valueWin, text)
        LabelSetTextColor(valueWin, 255, 255, 255)
        WindowSetShowing(valueWin, true)
    end
    if DoesWindowExist(chipWin) then
        WindowSetShowing(chipWin, true)
    end
end

local function SetIconTexture(iconWin, iconNum)
    if not DoesWindowExist(iconWin) then
        return
    end
    if iconNum and iconNum > 0 and type(GetIconData) == "function" then
        local ok, texture, x, y = StockPiler2.Debug.TryCallQuiet("GetIconData", GetIconData, iconNum)
        if ok and texture and texture ~= "" then
            DynamicImageSetTexture(iconWin, texture, x or 0, y or 0)
            if type(DynamicImageSetTextureScale) == "function" then
                DynamicImageSetTextureScale(iconWin, ICON_SCALE)
            end
            WindowSetShowing(iconWin, true)
            return
        end
    end
    DynamicImageSetTexture(iconWin, "", 0, 0)
    WindowSetShowing(iconWin, false)
end

local function ApplyStatusColor(labelWin, statusKey)
    local rgb = STATUS_COLORS[statusKey]
    if rgb == nil then
        LabelSetTextColor(labelWin, 255, 255, 255)
        return
    end
    LabelSetTextColor(labelWin, rgb[1], rgb[2], rgb[3])
end

local function UpdateEnableCheckbox()
    local row = CharRow()
    if not DoesWindowExist(ENABLE_WIN) then
        return
    end
    local can = CanAutoGrowUi()
    syncingUi = true
    ButtonSetCheckButtonFlag(ENABLE_WIN, true)
    ButtonSetPressedFlag(ENABLE_WIN, can and type(row) == "table" and row.autoGrowEnabled == true)
    ButtonSetDisabledFlag(ENABLE_WIN, not can)
    syncingUi = false
end

local function UpdateAdditivesCheckbox()
    local row = CharRow()
    if not DoesWindowExist(ADDITIVES_WIN) then
        return
    end
    local can = CanAutoGrowUi()
    syncingUi = true
    ButtonSetCheckButtonFlag(ADDITIVES_WIN, true)
    ButtonSetPressedFlag(ADDITIVES_WIN, can and type(row) == "table" and row.autoGrowAdditives == true)
    ButtonSetDisabledFlag(ADDITIVES_WIN, not can)
    syncingUi = false
end

local function UpdateAutoBuyCheckbox()
    local row = CharRow()
    if not DoesWindowExist(AUTOBUY_WIN) then
        return
    end
    local can = CanAutoBuyUi()
    syncingUi = true
    ButtonSetCheckButtonFlag(AUTOBUY_WIN, true)
    ButtonSetPressedFlag(AUTOBUY_WIN, can and type(row) == "table" and row.autoBuyEnabled == true)
    ButtonSetDisabledFlag(AUTOBUY_WIN, not can)
    syncingUi = false
end

local function UpdateSeedBufferEnableCheckbox()
    local row = CharRow()
    if not DoesWindowExist(SEED_BUFFER_ENABLE_WIN) then
        return
    end
    local can = CanAutoGrowUi()
    syncingUi = true
    ButtonSetCheckButtonFlag(SEED_BUFFER_ENABLE_WIN, true)
    local enabled = true
    if type(row) == "table" then
        enabled = row.growSeedBufferEnabled ~= false
    end
    ButtonSetPressedFlag(SEED_BUFFER_ENABLE_WIN, can and enabled)
    ButtonSetDisabledFlag(SEED_BUFFER_ENABLE_WIN, not can)
    syncingUi = false
end

local function UpdateSeedBufferLabel()
    local buf = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin() or 5
    SetChipNumber("SP2TabWatchSeedBufferChipValue", "SP2TabWatchSeedBufferChip", buf)
end

local function UpdateAutoBuyChips()
    local row = CharRow()
    local reserve = type(row) == "table" and tonumber(row.autoBuyReserveGold) or 10
    local budget = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or 50
    SetChipNumber("SP2TabWatchReserveChipValue", "SP2TabWatchReserveChip", reserve)
    SetChipNumber("SP2TabWatchBudgetChipValue", "SP2TabWatchBudgetChip", budget)
end

local function BuildVisibleList(opts)
    opts = type(opts) == "table" and opts or {}
    local Inv = StockPiler2.Inventory
    if Inv then
        if opts.forceInventory == true then
            if Inv.RefreshAllIfNeeded then
                Inv.RefreshAllIfNeeded({ force = true })
            end
        elseif Inv.IsDirty and Inv.IsDirty() and Inv.RefreshAllIfNeeded then
            Inv.RefreshAllIfNeeded()
        end
    end
    local plan = { rows = {} }
    if opts.forcePlan == true and StockPiler2.Planner and StockPiler2.Planner.Build then
        plan = StockPiler2.Planner.Build({ force = true }) or plan
    elseif StockPiler2.Planner and StockPiler2.Planner.GetOrBuild then
        plan = StockPiler2.Planner.GetOrBuild() or plan
    elseif StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Get then
        plan = StockPiler2.PlanSnapshot.Get() or plan
    end
    StockPiler2TabWatch.listData = plan.rows or {}
    StockPiler2TabWatch.displayOrder = {}
    for i = 1, #StockPiler2TabWatch.listData do
        StockPiler2TabWatch.displayOrder[i] = i
    end
end

function StockPiler2TabWatch.Initialize()
    LabelSetText("SP2TabWatchBannerTitle", L"Watch dashboard")
    LabelSetText(
        "SP2TabWatchBannerText",
        L"Enabled watches. Set Target#, toggle AutoGrow per potion. Planner balances cultivation by relative stock deficit."
    )
    LabelSetText("SP2TabWatchEnableLabel", L"Enable AutoGrow")
    LabelSetText("SP2TabWatchAdditivesLabel", L"Use Additives")
    LabelSetText("SP2TabWatchSeedBufferLabel", L"Seed buffer:")
    LabelSetText("SP2TabWatchAutoBuyLabel", L"AutoBuy")
    LabelSetText("SP2TabWatchReserveLabel", L"Reserve:")
    LabelSetText("SP2TabWatchBudgetLabel", L"Budget:")
    TintStepper("SP2TabWatchSeedBufferChipBg")
    TintStepper("SP2TabWatchReserveChipBg")
    TintStepper("SP2TabWatchBudgetChipBg")
    ButtonSetText("SP2TabWatchColPotion", L"Potion")
    ButtonSetText("SP2TabWatchColStock", L"Stock")
    ButtonSetText("SP2TabWatchColStatus", L"Status")
    ButtonSetText("SP2TabWatchColCraftable", L"Craftable")
    ButtonSetText("SP2TabWatchColTarget", L"Target")
    ButtonSetText("SP2TabWatchColPriority", L"AutoGrow")
    ButtonSetText("SP2TabWatchColBrew", L"Brew")
    UpdateEnableCheckbox()
    UpdateAdditivesCheckbox()
    UpdateAutoBuyCheckbox()
    UpdateSeedBufferEnableCheckbox()
    UpdateSeedBufferLabel()
    UpdateAutoBuyChips()
end

function StockPiler2TabWatch.Refresh(opts)
    opts = type(opts) == "table" and opts or {}
    if not DoesWindowExist("SP2TabWatch") then
        return
    end
    UpdateEnableCheckbox()
    UpdateAdditivesCheckbox()
    UpdateAutoBuyCheckbox()
    UpdateSeedBufferEnableCheckbox()
    UpdateSeedBufferLabel()
    UpdateAutoBuyChips()
    BuildVisibleList(opts)
    if DoesWindowExist("SP2TabWatchList") then
        ListBoxSetDisplayOrder("SP2TabWatchList", {})
        ListBoxSetDisplayOrder("SP2TabWatchList", StockPiler2TabWatch.displayOrder)
        StockPiler2TabWatch.UpdateRows()
    end
end

function StockPiler2TabWatch.UpdateRows()
    if SP2TabWatchList.PopulatorIndices == nil then
        return
    end
    for rowIndex, dataIndex in ipairs(SP2TabWatchList.PopulatorIndices) do
        local data = StockPiler2TabWatch.listData[dataIndex]
        if data then
            local rowName = "SP2TabWatchListRow" .. rowIndex
            if DefaultColor and DefaultColor.SetListRowTint then
                DefaultColor.SetListRowTint(rowName .. "Background", rowIndex, false)
            end
            SetIconTexture(rowName .. "Icon", data.iconNum)
            LabelSetText(rowName .. "Name", data.name or L"")
            LabelSetText(rowName .. "Status", data.statusText or L"")
            LabelSetText(rowName .. "Stock", data.stockText or towstring(tostring(data.potionHave or 0)))
            LabelSetText(rowName .. "Craftable", data.craftableText or L"-")
            LabelSetText(rowName .. "Target", data.targetText or towstring(tostring(data.target or 0)))
            TintStepper(rowName .. "TargetChipBg")
            ApplyStatusColor(rowName .. "Status", data.statusKey)
            local autoGrowWin = rowName .. "AutoGrow"
            if DoesWindowExist(autoGrowWin) then
                local can = CanAutoGrowUi()
                syncingUi = true
                ButtonSetCheckButtonFlag(autoGrowWin, true)
                ButtonSetPressedFlag(autoGrowWin, can and data.autoGrow == true)
                ButtonSetDisabledFlag(autoGrowWin, not can)
                syncingUi = false
            end
            -- Target chip always white (same as header chips)
            LabelSetTextColor(rowName .. "Target", 255, 255, 255)

            local target = tonumber(data.target) or 0
            local have = tonumber(data.potionHave) or 0
            local craftable = tonumber(data.craftable) or 0
            local stockColor = { 255, 255, 255 }
            if target > 0 then
                if have >= target then
                    stockColor = COLOR_OK
                elseif (have + craftable) >= target then
                    stockColor = COLOR_WARN
                else
                    stockColor = COLOR_BLOCK
                end
            end
            LabelSetTextColor(rowName .. "Stock", stockColor[1], stockColor[2], stockColor[3])

            local craftColor = COLOR_BLOCK
            if craftable > 0 then
                if data.craftableShared == true then
                    craftColor = COLOR_WARN
                else
                    craftColor = COLOR_OK
                end
            end
            LabelSetTextColor(rowName .. "Craftable", craftColor[1], craftColor[2], craftColor[3])

            ApplyRowBrewButton(rowName .. "Load", data)
        end
    end
end

local function BumpWatch()
    if StockPiler2.Watch then
        StockPiler2.Watch.BumpGen()
    end
    if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Invalidate then
        StockPiler2.PlanSnapshot.Invalidate()
    end
    if StockPiler2.Grow and StockPiler2.Grow.OnDemandChanged then
        StockPiler2.Grow.OnDemandChanged()
    end
end

local function NotifySettings(msg)
    if StockPiler2.Debug and StockPiler2.Debug.Notify then
        StockPiler2.Debug.Notify(msg)
    elseif StockPiler2.Debug and StockPiler2.Debug.Print then
        StockPiler2.Debug.Print(msg)
    end
end

local function OnOff(flag)
    return flag and L"ON" or L"OFF"
end

local function PotionLabel(data)
    if type(data) == "table" and data.name ~= nil and data.name ~= L"" then
        return data.name
    end
    return L"watch"
end

local function RowDataFromActiveChild()
    local win = SystemData.ActiveWindow and SystemData.ActiveWindow.name
    for _ = 1, 6 do
        if win == nil or win == "" or win == ENABLE_WIN then
            break
        end
        local rowIndex = WindowGetId(win)
        if rowIndex and rowIndex > 0 and DoesWindowExist("SP2TabWatchList") then
            local dataIndex = ListBoxGetDataIndex("SP2TabWatchList", rowIndex)
            local data = StockPiler2TabWatch.listData[dataIndex]
            if data then
                return data, win
            end
        end
        if type(WindowGetParent) == "function" then
            win = WindowGetParent(win)
        else
            break
        end
    end
    return nil, nil
end

function StockPiler2TabWatch.OnToggleEnabled()
    if syncingUi then
        return
    end
    if not CanAutoGrowUi() then
        UpdateEnableCheckbox()
        return
    end
    local row = CharRow()
    if type(row) ~= "table" then
        return
    end
    row.autoGrowEnabled = ButtonGetPressedFlag(ENABLE_WIN) == true
    NotifySettings(L"AutoGrow " .. OnOff(row.autoGrowEnabled))
    BumpWatch()
    if row.autoGrowEnabled == true then
        if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
            StockPiler2.Scheduler.WakeAutoGrow()
        end
    else
        if StockPiler2.Orchestrator and StockPiler2.Orchestrator.OnAutoGrowDisabled then
            StockPiler2.Orchestrator.OnAutoGrowDisabled()
        end
    end
    StockPiler2TabWatch.Refresh()
end

function StockPiler2TabWatch.OnToggleAdditives()
    if syncingUi then
        return
    end
    if not CanAutoGrowUi() then
        UpdateAdditivesCheckbox()
        return
    end
    local row = CharRow()
    if type(row) ~= "table" then
        return
    end
    row.autoGrowAdditives = ButtonGetPressedFlag(ADDITIVES_WIN) == true
    NotifySettings(L"Additives " .. OnOff(row.autoGrowAdditives))
    BumpWatch()
end

function StockPiler2TabWatch.OnToggleSeedBuffer()
    if syncingUi then
        return
    end
    if not CanAutoGrowUi() then
        UpdateSeedBufferEnableCheckbox()
        return
    end
    local row = CharRow()
    if type(row) ~= "table" then
        return
    end
    row.growSeedBufferEnabled = ButtonGetPressedFlag(SEED_BUFFER_ENABLE_WIN) == true
    NotifySettings(L"Seed buffer " .. OnOff(row.growSeedBufferEnabled))
    BumpWatch()
end

function StockPiler2TabWatch.OnToggleAutoBuy()
    if syncingUi then
        return
    end
    if not CanAutoBuyUi() then
        UpdateAutoBuyCheckbox()
        return
    end
    local row = CharRow()
    if type(row) ~= "table" then
        return
    end
    row.autoBuyEnabled = ButtonGetPressedFlag(AUTOBUY_WIN) == true
    NotifySettings(L"AutoBuy " .. OnOff(row.autoBuyEnabled))
    if StockPiler2.Buy and StockPiler2.Buy.InvalidateJobsCache then
        StockPiler2.Buy.InvalidateJobsCache()
    end
    if row.autoBuyEnabled == true and StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoBuy then
        StockPiler2.Scheduler.WakeAutoBuy()
    end
    BumpWatch()
end

local function ChipStep(flags)
    flags = tonumber(flags) or 0
    local shift = 4
    if SystemData and SystemData.ButtonFlags and SystemData.ButtonFlags.SHIFT then
        shift = tonumber(SystemData.ButtonFlags.SHIFT) or 4
    end
    if flags == shift then
        return 10
    end
    if type(bit) == "table" and type(bit.band) == "function" then
        if bit.band(flags, shift) ~= 0 then
            return 10
        end
    elseif shift > 0 and math.mod(math.floor(flags / shift), 2) == 1 then
        return 10
    end
    return 1
end

local CHIP_NOTIFY_LABEL = {
    growSeedBufferMin = L"Seed buffer",
    autoBuyReserveGold = L"Reserve",
    autoBuyBudgetGold = L"Budget",
}

local function AdjustChip(field, delta, lo, hi)
    local row = CharRow()
    if type(row) ~= "table" then
        return
    end
    local n = (tonumber(row[field]) or lo) + delta
    if n < lo then n = lo end
    if n > hi then n = hi end
    row[field] = n
    local label = CHIP_NOTIFY_LABEL[field]
    if label then
        NotifySettings(label .. L" = " .. towstring(tostring(n)))
    end
    BumpWatch()
    StockPiler2TabWatch.Refresh()
    if field == "autoBuyReserveGold" or field == "autoBuyBudgetGold" then
        if StockPiler2.Buy and StockPiler2.Buy.ClearMoneyGateStop then
            StockPiler2.Buy.ClearMoneyGateStop(field)
        elseif StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoBuy then
            StockPiler2.Scheduler.WakeAutoBuy()
        end
    end
end

function StockPiler2TabWatch.OnSeedBufferLButtonUp(flags)
    AdjustChip("growSeedBufferMin", ChipStep(flags), 4, 20)
end

function StockPiler2TabWatch.OnSeedBufferRButtonUp(flags)
    AdjustChip("growSeedBufferMin", -ChipStep(flags), 4, 20)
end

function StockPiler2TabWatch.OnReserveLButtonUp(flags)
    AdjustChip("autoBuyReserveGold", ChipStep(flags), 1, 99)
end

function StockPiler2TabWatch.OnReserveRButtonUp(flags)
    AdjustChip("autoBuyReserveGold", -ChipStep(flags), 1, 99)
end

function StockPiler2TabWatch.OnBudgetLButtonUp(flags)
    AdjustChip("autoBuyBudgetGold", ChipStep(flags), 1, 999)
end

function StockPiler2TabWatch.OnBudgetRButtonUp(flags)
    AdjustChip("autoBuyBudgetGold", -ChipStep(flags), 1, 999)
end

function StockPiler2TabWatch.OnToggleRowAutoGrow()
    if syncingUi then
        return
    end
    if not CanAutoGrowUi() then
        StockPiler2TabWatch.UpdateRows()
        return
    end
    local data, clickWin = RowDataFromActiveChild()
    if type(data) ~= "table" then
        return
    end
    local potionKey = data.potionRecipeKey or data.id
    if not potionKey or not StockPiler2.Catalog then
        return
    end
    local watch = StockPiler2.Catalog.EnsureWatch(potionKey)
    watch.autoGrow = ButtonGetPressedFlag(clickWin) == true
    NotifySettings(PotionLabel(data) .. L": AutoGrow " .. OnOff(watch.autoGrow))
    BumpWatch()
end

function StockPiler2TabWatch.OnTargetLButtonUp(flags)
    local data = RowDataFromActiveChild()
    if type(data) ~= "table" then
        return
    end
    local potionKey = data.potionRecipeKey or data.id
    local watch = StockPiler2.Catalog and StockPiler2.Catalog.EnsureWatch(potionKey)
    if type(watch) ~= "table" then
        return
    end
    local target = (tonumber(watch.targetStock) or 0) + ChipStep(flags)
    if target > TARGET_MAX then
        target = TARGET_MAX
    end
    watch.targetStock = target
    watch.enabled = true
    NotifySettings(PotionLabel(data) .. L": target = " .. towstring(tostring(target)))
    BumpWatch()
    StockPiler2TabWatch.Refresh()
end

function StockPiler2TabWatch.OnTargetRButtonUp(flags)
    local data = RowDataFromActiveChild()
    if type(data) ~= "table" then
        return
    end
    local potionKey = data.potionRecipeKey or data.id
    local watch = StockPiler2.Catalog and StockPiler2.Catalog.EnsureWatch(potionKey)
    if type(watch) ~= "table" then
        return
    end
    local target = (tonumber(watch.targetStock) or 0) - ChipStep(flags)
    if target < 0 then
        target = 0
    end
    watch.targetStock = target
    if target > 0 then
        watch.enabled = true
    end
    NotifySettings(PotionLabel(data) .. L": target = " .. towstring(tostring(target)))
    BumpWatch()
    StockPiler2TabWatch.Refresh()
end

function StockPiler2TabWatch.OnMouseOverEnabled()
    if not CanAutoGrowUi() then
        local Caps = StockPiler2.TradeSkillCaps
        local gather = Caps and Caps.GatheringLabel and Caps.GatheringLabel()
        local text = L"AutoGrow requires Cultivation."
        if gather ~= nil and gather ~= L"Cultivation" then
            text = text
                .. L" This character gathers via "
                .. gather
                .. L" — plant mats must be bought or grown on a Cultivator."
        end
        Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, text)
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
        return
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, L"Master AutoGrow switch. Per-potion AutoGrow boxes also need to be checked.")
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverAdditives()
    if not CanAutoGrowUi() then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            L"Additives require Cultivation (AutoGrow)."
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
        return
    end
    Tooltips.CreateTextOnlyTooltip(
        SystemData.ActiveWindow.name,
        L"Auto-apply best Soil / Water / Nutrient from the crafting bag at the matching grow stage."
    )
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverAutoBuy()
    if not CanAutoBuyUi() then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            L"AutoBuy requires Cultivation or Apothecary. It only buys those craft-mat types from an open NPC vendor."
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
        return
    end
    local text = L"While an NPC vendor is open, buy Cultivating and Apothecary craft-mat shortages for Watch targets."
    if CanAutoGrowUi() then
        text = text .. L" Growable plants stay with AutoGrow."
    else
        text = text .. L" Without Cultivation, plant and seed shortages can be bought at vendors."
    end
    text = text .. L" Independent of AutoGrow. Non-cult/apo store items are skipped."
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, text)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverSeedBufferEnable()
    if not CanAutoGrowUi() then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            L"Seed buffer requires Cultivation (AutoGrow)."
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
        return
    end
    Tooltips.CreateTextOnlyTooltip(
        SystemData.ActiveWindow.name,
        L"Keep a seed buffer for watched potion ingredients (refine, buffer-grow, surplus). Grow is not done while buffer is short."
    )
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
end

local function ToW(value)
    if value == nil then
        return L""
    end
    if type(value) == "string" then
        return towstring(value)
    end
    return towstring(tostring(value))
end

local function SeedSpecLabel(spec)
    local MS = StockPiler2.MaterialSpec
    if MS and MS.NeedLabelParts then
        local parts = MS.NeedLabelParts(spec)
        if type(parts) == "table" and parts.header and parts.header ~= L"" then
            return parts.header
        end
    end
    if MS and MS.NeedLabel then
        local label = MS.NeedLabel(spec)
        if label and label ~= L"" then
            return label
        end
    end
    return L"Watched seed"
end

local function CollectSeedBufferTooltipData()
    local RS = StockPiler2.RecipeSpec
    local Refine = StockPiler2.Refine
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin and StockPiler2.Watch.GetSeedBufferMin() or 5
    local enabled = StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled and StockPiler2.Watch.IsSeedBufferEnabled() == true
    local rows = {}
    local byKey = {}

    local lines = {}
    if RS and RS.CollectAutoGrowSeedLines then
        lines = RS.CollectAutoGrowSeedLines() or {}
    end

    for i = 1, #lines do
        local line = lines[i]
        local spec = line and line.spec
        if type(spec) == "table" then
            local seedUid = tonumber(line.seedUid) or 0
            local specKey = tostring(line.specKey or seedUid or i)
            if byKey[specKey] == nil then
                local live, ground, planned, credit = 0, 0, 0, 0
                if Refine and Refine.GetSeedBudgetForSpec then
                    local budget = Refine.GetSeedBudgetForSpec(spec, seedUid)
                    live = tonumber(budget and budget.live) or 0
                    ground = tonumber(budget and budget.ground) or 0
                    planned = tonumber(budget and budget.outstanding) or 0
                    credit = tonumber(budget and budget.credit) or (live + ground + planned)
                end
                local shortBy = math.max(0, (tonumber(buffer) or 0) - credit)
                local name = SeedSpecLabel(spec)
                byKey[specKey] = {
                    key = specKey,
                    spec = spec,
                    seedUid = seedUid,
                    name = name,
                    live = live,
                    ground = ground,
                    planned = planned,
                    total = credit,
                    shortBy = shortBy,
                }
                rows[#rows + 1] = byKey[specKey]
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.shortBy ~= b.shortBy then
            return a.shortBy > b.shortBy
        end
        return tostring(a.key) < tostring(b.key)
    end)

    local intentsByKey = {}
    if Refine and Refine.CollectIntents then
        local intents = Refine.CollectIntents() or {}
        for i = 1, #intents do
            local it = intents[i]
            local spec = it and it.spec
            if type(spec) == "table" then
                local seedUid = tonumber(it.seedUid) or 0
                local key = tostring((StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.ProductKey and StockPiler2.MaterialSpec.ProductKey(spec)) or seedUid or i)
                local rec = intentsByKey[key]
                if rec == nil then
                    rec = {
                        key = key,
                        name = SeedSpecLabel(spec),
                        spec = spec,
                        count = 0,
                        plantNeed = 0,
                        seedBuffer = 0,
                    }
                    intentsByKey[key] = rec
                end
                local uses = math.max(1, tonumber(it.uses) or 1)
                rec.count = rec.count + uses
                if it.reason == "plant-need" then
                    rec.plantNeed = rec.plantNeed + uses
                else
                    rec.seedBuffer = rec.seedBuffer + uses
                end
            end
        end
    end

    local intentRows = {}
    for _, rec in pairs(intentsByKey) do
        intentRows[#intentRows + 1] = rec
    end
    table.sort(intentRows, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        return tostring(a.key) < tostring(b.key)
    end)

    return {
        buffer = tonumber(buffer) or 5,
        enabled = enabled,
        watched = rows,
        intents = intentRows,
    }
end

function StockPiler2TabWatch.OnMouseOverSeedBuffer()
    local data = CollectSeedBufferTooltipData()
    if not StockPiler2RecipeTooltip or not StockPiler2RecipeTooltip.ShowColoredRows then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            L"Minimum seeds to keep in bags. L-click +1, R-click -1. Hold Shift for +/-10."
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
        return
    end

    local MS = StockPiler2.MaterialSpec
    local colorOk = RgbDef(COLOR_OK)
    local colorWarn = RgbDef(COLOR_WARN)
    local colorBlock = RgbDef(COLOR_BLOCK)
    local sepLine = (StockPiler2RecipeTooltip and StockPiler2RecipeTooltip.SEP_LINE)
        or L"----------------------------------------"

    local function AppendSep(rows)
        if StockPiler2RecipeTooltip and StockPiler2RecipeTooltip.AppendSeparator then
            StockPiler2RecipeTooltip.AppendSeparator(rows)
        else
            rows[#rows + 1] = { text = sepLine, kind = "separator" }
        end
    end

    local function SpecHeaderDetail(spec, fallbackName)
        local parts = MS and MS.NeedLabelParts and MS.NeedLabelParts(spec) or nil
        local header = parts and parts.header
        if header == nil or header == L"" then
            header = fallbackName or L"Watched seed"
        end
        local detail = parts and parts.detail or L""
        return header, detail
    end

    local rows = {
        { text = L"StockPiler2 Seed Buffer", kind = "title" },
        {
            text = L"Buffer: "
                .. towstring(tostring(data.buffer))
                .. L" ("
                .. (data.enabled and L"enabled" or L"disabled")
                .. L")",
            kind = data.enabled and "body" or "warning",
        },
        { text = L"Watched seeds", kind = "meta" },
    }

    -- Multi-line blocks (~3–4 rows each + seps); DefaultTooltip ~17 rows.
    local maxWatched = 4
    local maxIntents = 3

    if #data.watched == 0 then
        rows[#rows + 1] = { text = L"No growable watched seed lines found.", kind = "meta" }
    else
        local shown = math.min(#data.watched, maxWatched)
        for i = 1, shown do
            AppendSep(rows)
            local w = data.watched[i]
            local header, detail = SpecHeaderDetail(w.spec, w.name)
            rows[#rows + 1] = { text = ToW(header), kind = "ingredient" }
            if detail ~= nil and detail ~= L"" then
                rows[#rows + 1] = { text = ToW(detail), kind = "bonus" }
            end

            local liveText = towstring(tostring(w.live))
            if (tonumber(w.ground) or 0) > 0 then
                liveText = liveText .. L"+" .. towstring(tostring(w.ground)) .. L"g"
            end
            local statusText = L"live "
                .. liveText
                .. L" + planned "
                .. towstring(tostring(w.planned))
                .. L" / "
                .. towstring(tostring(data.buffer))
            local credit = tonumber(w.total) or ((tonumber(w.live) or 0) + (tonumber(w.ground) or 0) + (tonumber(w.planned) or 0))
            local shortBy = tonumber(w.shortBy) or 0
            local statusColor = colorOk
            if shortBy > 0 then
                statusText = statusText .. L" (SHORT by " .. towstring(tostring(shortBy)) .. L")"
                if credit <= 0 then
                    statusColor = colorBlock
                else
                    statusColor = colorWarn
                end
            else
                statusText = statusText .. L" (OK)"
            end
            rows[#rows + 1] = { text = statusText, kind = "body", color = statusColor }
        end
        if #data.watched > maxWatched then
            rows[#rows + 1] = {
                text = L"... +" .. towstring(tostring(#data.watched - maxWatched)) .. L" more watched lines",
                kind = "meta",
            }
        end
    end

    rows[#rows + 1] = { text = L"Planned refine", kind = "meta" }
    if #data.intents == 0 then
        rows[#rows + 1] = { text = L"No refine ops queued.", kind = "meta" }
    else
        local shown = math.min(#data.intents, maxIntents)
        for i = 1, shown do
            AppendSep(rows)
            local it = data.intents[i]
            local header, detail = SpecHeaderDetail(it.spec, it.name)
            rows[#rows + 1] = { text = ToW(header), kind = "ingredient" }
            if detail ~= nil and detail ~= L"" then
                rows[#rows + 1] = { text = ToW(detail), kind = "bonus" }
            end
            local reason = L"buffer"
            if it.plantNeed > 0 and it.seedBuffer > 0 then
                reason = L"need+buffer"
            elseif it.plantNeed > 0 then
                reason = L"need"
            end
            rows[#rows + 1] = {
                text = towstring(tostring(it.count)) .. L" queued (" .. reason .. L")",
                kind = "body",
            }
        end
        if #data.intents > maxIntents then
            rows[#rows + 1] = {
                text = L"... +" .. towstring(tostring(#data.intents - maxIntents)) .. L" more refine lines",
                kind = "meta",
            }
        end
    end

    rows[#rows + 1] = {
        text = L"Minimum seeds to keep in bags. L-click +1, R-click -1. Hold Shift for +/-10.",
        kind = "meta",
    }
    StockPiler2RecipeTooltip.ShowColoredRows(SystemData.ActiveWindow.name, rows, Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPiler2TabWatch.OnMouseOverReserve()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, L"Gold reserve for AutoBuy. L-click +1, R-click -1. Hold Shift for +/-10.")
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverBudget()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, L"AutoBuy budget per trip. L-click +1, R-click -1. Hold Shift for +/-10.")
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

local function ShowItemOrTextTooltip(itemData, title, line2, line3)
    if StockPiler2.Inventory and StockPiler2.Inventory.ShowItemTooltip then
        if StockPiler2.Inventory.ShowItemTooltip(itemData, SystemData.ActiveWindow.name, line2) then
            return
        end
    elseif itemData ~= nil and type(Tooltips.CreateItemTooltip) == "function" then
        local ok = StockPiler2.Debug.TryCall(
            "Tooltips.CreateItemTooltip",
            Tooltips.CreateItemTooltip,
            itemData,
            SystemData.ActiveWindow.name,
            Tooltips.ANCHOR_WINDOW_RIGHT,
            true
        )
        if ok then
            return
        end
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name)
    Tooltips.SetTooltipText(1, 1, title or L"Potion")
    local row = 2
    if line2 and line2 ~= L"" then
        Tooltips.SetTooltipText(row, 1, line2)
        row = row + 1
    end
    if line3 and line3 ~= L"" then
        Tooltips.SetTooltipText(row, 1, line3)
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverIcon()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local uid = tonumber(data.uniqueID) or 0
    local itemData = data.itemData
    if StockPiler2.Inventory and StockPiler2.Inventory.ResolvePotionItemData then
        itemData = StockPiler2.Inventory.ResolvePotionItemData(data.potionKey, uid, itemData)
        if itemData then
            data.itemData = itemData
        end
    end
    local line2 = L"Have " .. towstring(tostring(data.potionHave or 0))
        .. L" / Target " .. towstring(tostring(data.potionMin or data.target or 0))
    if data.statusText and data.statusText ~= L"" then
        line2 = line2 .. L"  |  " .. data.statusText
    end
    local line3 = data.statusDetail or L""
    local iLevel = 0
    if type(itemData) == "table" then
        iLevel = tonumber(itemData.iLevel) or tonumber(itemData.level) or 0
    end
    local effectKey = data.effectKey
    if (not effectKey or effectKey == "") and StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.ResolveEffectKeyForPotion then
        effectKey = StockPiler2.RecipeSpec.ResolveEffectKeyForPotion({
            potionKey = data.potionKey or data.potionBaseKey,
            outputUid = uid,
            effectKey = data.effectKey,
            recipeKeys = data.recipeSpecKey and { data.recipeSpecKey } or nil,
            activeRecipeKey = data.recipeSpecKey,
        }, {
            recipe = data.recipe,
            recipeKey = data.recipeSpecKey,
            itemData = itemData,
            stamp = false,
        })
    end
    if StockPiler2RecipeTooltip and StockPiler2RecipeTooltip.ShowPotionIconTooltip then
        StockPiler2RecipeTooltip.ShowPotionIconTooltip(SystemData.ActiveWindow.name, {
            name = data.name or L"Potion",
            uniqueID = uid,
            iconNum = data.iconNum,
            itemData = itemData,
            iLevel = iLevel,
            effectKey = effectKey,
            line2 = line2,
            line3 = line3 ~= L"" and line3 or nil,
        })
        return
    end
    ShowItemOrTextTooltip(
        itemData,
        data.name or L"Potion",
        line2,
        line3 ~= L"" and line3 or nil
    )
end

local function StatusTitleColor(statusKey)
    local rgb = STATUS_COLORS[statusKey or ""]
    local def = RgbDef(rgb)
    if def ~= nil then
        return def
    end
    if Tooltips and Tooltips.COLOR_HEADING then
        return Tooltips.COLOR_HEADING
    end
    return nil
end

local function GrowingNoteKind(notes)
    local n = string.lower(StockPiler2.ToNarrow and StockPiler2.ToNarrow(notes) or tostring(notes or ""))
    if string.find(n, "needs planting", 1, true)
        or string.find(n, "converting", 1, true)
        or string.find(n, "need seed", 1, true)
    then
        return "warning"
    end
    if string.find(n, "buy seeds", 1, true)
        or string.find(n, "buy plants", 1, true)
        or string.find(n, "autogrow off", 1, true)
        or string.find(n, "needs cultivation", 1, true)
    then
        return "negative"
    end
    if string.find(n, "ready to harvest", 1, true)
        or string.find(n, "growing", 1, true)
        or string.find(n, "germination", 1, true)
        or string.find(n, "seedling", 1, true)
        or string.find(n, "flowering", 1, true)
        or string.find(n, "planting", 1, true)
    then
        return "positive"
    end
    return "body"
end

local function TitleCaseStatusNote(notes)
    local narrow = StockPiler2.ToNarrow and StockPiler2.ToNarrow(notes) or tostring(notes or "")
    if narrow == "" then
        return notes
    end
    local lower = string.lower(narrow)
    if lower == "stocked" then
        return L"Stocked"
    end
    if lower == "buy seeds" then
        return L"Buy seeds"
    end
    if lower == "buy plants" then
        return L"Buy plants"
    end
    if lower == "needs planting" then
        return L"Needs planting"
    end
    if lower == "needs cultivation" then
        return L"Needs Cultivation"
    end
    if lower == "autogrow off for this watch" then
        return L"AutoGrow off for this watch"
    end
    -- Capitalize first character of the display string when it is ASCII.
    local first = string.sub(narrow, 1, 1)
    local rest = string.sub(narrow, 2)
    if first >= "a" and first <= "z" then
        return towstring(string.upper(first) .. rest)
    end
    return notes
end

--- Fit DefaultTooltip NUM_ROWS without dropping ingredient dividers (same as recipe tooltips).
local function TrimStatusTooltipRows(rows, limit)
    limit = tonumber(limit) or 17
    if type(rows) ~= "table" or #rows <= limit then
        return rows
    end

    local function isIngredientDivider(i)
        local prev = rows[i - 1]
        local nextRow = rows[i + 1]
        if not (nextRow and nextRow.kind == "ingredient") or not prev then
            return false
        end
        -- Between materials: ... Have/Need (or bonus) --- next ingredient
        if prev.kind == "stocked" or prev.kind == "bonus" or prev.kind == "effect"
            or prev.kind == "positive" or prev.kind == "negative"
        then
            return true
        end
        if prev.kind == "body" or prev.kind == "warning" then
            local t = StockPiler2.ToNarrow and StockPiler2.ToNarrow(prev.text) or tostring(prev.text or "")
            if string.find(t, "Have ", 1, true) then
                return true
            end
        end
        return false
    end

    -- Prefer dropping yield / success meta before any separators.
    for i = #rows, 1, -1 do
        if #rows <= limit then
            return rows
        end
        local r = rows[i]
        if r.kind == "meta" then
            local t = StockPiler2.ToNarrow and StockPiler2.ToNarrow(r.text) or tostring(r.text or "")
            if string.find(t, "Recipe yield", 1, true) then
                table.remove(rows, i)
            end
        end
    end
    for i = #rows, 1, -1 do
        if #rows <= limit then
            return rows
        end
        if rows[i].kind == "warning" then
            local t = StockPiler2.ToNarrow and StockPiler2.ToNarrow(rows[i].text) or tostring(rows[i].text or "")
            if string.find(t, "success", 1, true) then
                table.remove(rows, i)
            end
        end
    end

    -- Drop non-ingredient separators only (keep recipe-style --- between materials).
    while #rows > limit do
        local removed = false
        for i = #rows, 1, -1 do
            if rows[i].kind == "separator" and not isIngredientDivider(i) then
                table.remove(rows, i)
                removed = true
                break
            end
        end
        if not removed then
            break
        end
    end
    return rows
end

function StockPiler2TabWatch.OnMouseOverStatus()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    if not StockPiler2RecipeTooltip or not StockPiler2RecipeTooltip.ShowColoredRows then
        Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, data.statusText or L"Status")
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
        return
    end

    local rows = {
        {
            text = data.statusText or L"Status",
            kind = "title",
            color = StatusTitleColor(data.statusKey),
        },
    }

    local function appendMeta(text)
        if text and text ~= L"" then
            rows[#rows + 1] = { text = text, kind = "meta" }
        end
    end

    local slots = data.statusSlots
    local recipe = data.recipe or data.specRecipe
    local craftsNeeded = tonumber(data.craftsNeeded) or 0
    local deficit = tonumber(data.potionDeficit) or 0
    local yield = tonumber(data.recipeYield) or 0
    local fullSlots = nil
    if type(recipe) == "table"
        and StockPiler2.Planner
        and StockPiler2.Planner.BuildRecipeSlotTooltipEntries
        and (craftsNeeded > 0 or (type(slots) == "table" and #slots > 0))
    then
        fullSlots = StockPiler2.Planner.BuildRecipeSlotTooltipEntries(recipe, craftsNeeded, nil)
    end
    if type(fullSlots) == "table" and #fullSlots > 0 then
        slots = fullSlots
    end
    if type(slots) == "table" and #slots > 0 then
        if craftsNeeded > 0 and deficit > 0 then
            rows[#rows + 1] = {
                text = L"Need "
                    .. towstring(tostring(craftsNeeded))
                    .. L" crafts for "
                    .. towstring(tostring(deficit))
                    .. L" more of this potion.",
                kind = "body",
            }
            if yield > 0 then
                appendMeta(
                    L"Recipe yield "
                        .. towstring(tostring(yield))
                        .. L" is a best case; Potent / other rarities do not count."
                )
            end
            if data.statusKey == "enable_autogrow" then
                rows[#rows + 1] = {
                    text = L"Enable AutoGrow for this watch to plant short materials.",
                    kind = "warning",
                    color = RgbDef(COLOR_BLOCK),
                }
            elseif data.statusKey == "need_apothecary" then
                rows[#rows + 1] = {
                    text = L"Only Apothecaries can brew potions.",
                    kind = "warning",
                    color = RgbDef(COLOR_BLOCK),
                }
            elseif data.statusKey == "buy_ingredients" and not CanAutoGrowUi() then
                local st = string.lower(
                    StockPiler2.ToNarrow and StockPiler2.ToNarrow(data.statusText) or tostring(data.statusText or "")
                )
                if not string.find(st, "flask", 1, true) then
                    local Caps = StockPiler2.TradeSkillCaps
                    local text =
                        L"Cultivation is required to AutoGrow. Buy plants or seeds, or use a Cultivator character."
                    local gather = Caps and Caps.GatheringLabel and Caps.GatheringLabel()
                    if gather ~= nil and gather ~= L"Cultivation" then
                        text = L"This character gathers via "
                            .. gather
                            .. L" — plant mats must be bought or grown on a Cultivator."
                    end
                    rows[#rows + 1] = {
                        text = text,
                        kind = "warning",
                        color = RgbDef(COLOR_BLOCK),
                    }
                end
            end
            local RS = StockPiler2.RecipeSpec
            local uid = tonumber(data.uniqueID) or 0
            if RS and RS.ExpectedCraftsForDeficit and type(recipe) == "table" then
                local expectedCrafts, rate = RS.ExpectedCraftsForDeficit(deficit, recipe, uid)
                if rate ~= nil and rate < 0.99 and expectedCrafts and expectedCrafts > craftsNeeded then
                    local pct = math.floor(rate * 100 + 0.5)
                    rows[#rows + 1] = {
                        text = L"At "
                            .. towstring(tostring(pct))
                            .. L"% success -> ~"
                            .. towstring(tostring(expectedCrafts))
                            .. L" crafts expected.",
                        kind = "warning",
                    }
                end
            end
        elseif data.statusNeedLine and data.statusNeedLine ~= L"" then
            appendMeta(data.statusNeedLine)
        end

        rows[#rows + 1] = {
            text = (StockPiler2RecipeTooltip and StockPiler2RecipeTooltip.SEP_LINE)
                or L"----------------------------------------",
            kind = "separator",
        }

        local MS = StockPiler2.MaterialSpec
        local Grow = StockPiler2.Grow
        local colorOk = RgbDef(COLOR_OK)
        local colorWarn = RgbDef(COLOR_WARN)
        local colorBlock = RgbDef(COLOR_BLOCK)
        local slotShown = 0
        for i = 1, #slots do
            local entry = slots[i]
            if type(entry) == "table" and type(entry.spec) == "table" then
                if slotShown > 0 then
                    if StockPiler2RecipeTooltip and StockPiler2RecipeTooltip.AppendSeparator then
                        StockPiler2RecipeTooltip.AppendSeparator(rows)
                    else
                        rows[#rows + 1] = {
                            text = L"----------------------------------------",
                            kind = "separator",
                        }
                    end
                end
                slotShown = slotShown + 1

                local parts = MS and MS.NeedLabelParts and MS.NeedLabelParts(entry.spec) or nil
                local header = parts and parts.header
                    or (MS and MS.NeedLabel and MS.NeedLabel(entry.spec))
                    or L"material"
                local detail = parts and parts.detail or L""
                -- Recipe tooltip colors: ingredient = COLOR_ACTION (bright green),
                -- bonus = COLOR_HEADING (gold). No Buy/Plant verb prefixes.
                rows[#rows + 1] = {
                    text = header,
                    kind = "ingredient",
                    role = entry.role,
                }
                if detail ~= nil and detail ~= L"" then
                    rows[#rows + 1] = {
                        text = detail,
                        kind = "bonus",
                        role = entry.role,
                    }
                end

                local isBuyPath = entry.kind ~= "plant" and entry.kind ~= "convert"
                local stocked = entry.stocked == true or (tonumber(entry.deficit) or 0) <= 0
                local haveColor = colorOk
                if not stocked then
                    if entry.kind == "convert" then
                        -- Byproduct: yellow only while a plant-kind sibling can feed convert.
                        local feedable = false
                        for j = 1, #slots do
                            local sibling = slots[j]
                            if type(sibling) == "table" and sibling.kind == "plant" then
                                feedable = true
                                break
                            end
                        end
                        haveColor = feedable and colorWarn or colorBlock
                    else
                        haveColor = isBuyPath and colorBlock or colorWarn
                    end
                end
                local statusNote = nil
                local noteKind = stocked and "stocked" or "body"
                if entry.kind == "plant" and not stocked then
                    local notes = L""
                    if Grow and Grow.GrowingNotesForSpec then
                        notes = Grow.GrowingNotesForSpec(entry.spec) or L""
                    end
                    if notes == L"" then
                        if not CanAutoGrowUi() then
                            notes = L"Needs Cultivation"
                            haveColor = colorBlock
                        elseif data.autoGrow == true then
                            -- "Needs planting" is misleading when the seed-line itself is exhausted.
                            -- In that case the only way forward is to buy more seeds/plants.
                            local seedUid = 0
                            local SM = StockPiler2.SeedMap
                            if SM and SM.ResolveSeedForSpec then
                                local seed = SM.ResolveSeedForSpec(entry.spec)
                                if type(seed) == "table" then
                                    seedUid = tonumber(seed.uniqueID)
                                        or tonumber(seed.itemData and seed.itemData.uniqueID)
                                        or tonumber(seed.seedUid)
                                        or 0
                                end
                            end

                            local credit = 0
                            if seedUid > 0 and StockPiler2.Refine and StockPiler2.Refine.GetSeedBudgetForSpec then
                                local budget = StockPiler2.Refine.GetSeedBudgetForSpec(entry.spec, seedUid)
                                credit = tonumber(budget and budget.credit) or 0
                            end

                            if seedUid > 0 and credit <= 0 then
                                notes = L"Buy seeds"
                                haveColor = colorBlock
                            elseif seedUid <= 0 then
                                notes = L"Buy plants"
                                haveColor = colorBlock
                            else
                                notes = L"Needs planting"
                            end
                        else
                            notes = L"AutoGrow off for this watch"
                        end
                    end
                    statusNote = TitleCaseStatusNote(notes)
                    noteKind = GrowingNoteKind(notes)
                elseif stocked then
                    statusNote = L"Stocked"
                    noteKind = "stocked"
                end
                local haveText = L"Have "
                    .. towstring(tostring(entry.have or 0))
                    .. L" / Need "
                    .. towstring(tostring(entry.need or 0))
                if statusNote and statusNote ~= L"" then
                    haveText = haveText .. L" (" .. statusNote .. L")"
                end
                rows[#rows + 1] = {
                    text = haveText,
                    kind = noteKind,
                    color = haveColor,
                }
            end
        end
    elseif type(data.statusLines) == "table" and #data.statusLines > 0 then
        for i = 1, #data.statusLines do
            appendMeta(data.statusLines[i])
        end
    elseif data.statusDetail and data.statusDetail ~= L"" then
        appendMeta(data.statusDetail)
    end

    -- Engine DefaultTooltip max is Tooltips.NUM_ROWS (17); trim then clamp.
    local engineMax = (Tooltips and tonumber(Tooltips.NUM_ROWS)) or 17
    TrimStatusTooltipRows(rows, engineMax)
    StockPiler2RecipeTooltip.ShowColoredRows(
        SystemData.ActiveWindow.name,
        rows,
        Tooltips.ANCHOR_WINDOW_TOP,
        engineMax
    )
end

local function FormatTooltipNumber(n)
    n = tonumber(n) or 0
    local rounded = math.floor(n * 10 + 0.5) / 10
    if math.abs(rounded - math.floor(rounded + 0.5)) < 0.05 then
        return towstring(tostring(math.floor(rounded + 0.5)))
    end
    return towstring(string.format("%.1f", rounded))
end

local function ShowStockRowTooltip(data)
    if not StockPiler2RecipeTooltip or not StockPiler2RecipeTooltip.ShowColoredRows then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            L"Bag count in bags vs Target."
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
        return
    end
    local target = tonumber(data.target) or 0
    local have = tonumber(data.potionHave) or 0
    local craftable = tonumber(data.craftable) or 0
    local title = L"No target"
    local meta = L"Set a Target to track bag stock against it."
    local bodyKind = "body"
    if target > 0 then
        if have >= target then
            title = L"Fully stocked"
            meta = L"Green: bag stock is at or above Target."
        elseif (have + craftable) >= target then
            title = L"Need brewing"
            if data.craftableShared == true or data.statusKey == "ready_to_craft_shared" then
                meta = L"Yellow: covered, but shared mats are contested - AutoGrow continues until Craftable is green. Row Load/Brew can brew early; footer Brew waits for green."
            else
                meta = L"Green Ready: Stock + Craftable covers Target uncontested - use Brew."
            end
            bodyKind = "warning"
        else
            title = L"Need materials"
            meta = L"Red: Stock + Craftable is still short of Target - grow or buy mats."
            bodyKind = "warning"
        end
    end
    local rows = {
        { text = title, kind = "title" },
        {
            text = L"Stock "
                .. towstring(tostring(have))
                .. L" / Target "
                .. towstring(tostring(target)),
            kind = "body",
        },
        {
            text = L"Craftable " .. towstring(tostring(craftable)),
            kind = bodyKind,
        },
        { text = meta, kind = "meta" },
    }
    if target > 0 and have < target then
        local combined = have + craftable
        if combined >= target then
            rows[#rows + 1] = {
                text = L"Stock + Craftable covers Target.",
                kind = "meta",
            }
        else
            local short = target - combined
            rows[#rows + 1] = {
                text = L"Short by " .. towstring(tostring(short)) .. L" after Craftable.",
                kind = "warning",
            }
        end
    end
    StockPiler2RecipeTooltip.ShowColoredRows(
        SystemData.ActiveWindow.name,
        rows,
        Tooltips.ANCHOR_WINDOW_TOP
    )
end

function StockPiler2TabWatch.OnMouseOverStock()
    local data = RowDataFromActiveChild()
    if data then
        ShowStockRowTooltip(data)
    else
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            L"Bag count in bags vs Target."
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
    end
end

local function ShowCraftableHeaderTooltip()
    if not StockPiler2RecipeTooltip or not StockPiler2RecipeTooltip.ShowColoredRows then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            L"Craftable - best-case bottles if every brew is this potion. Yellow = shared mats contested."
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
        return
    end
    StockPiler2RecipeTooltip.ShowColoredRows(SystemData.ActiveWindow.name, {
        { text = L"Craftable", kind = "title" },
        {
            text = L"Best-case count if every brew output is this exact potion.",
            kind = "body",
        },
        {
            text = L"Green = mats covered. Yellow = shared mats contested. Red = zero craftable.",
            kind = "meta",
        },
        {
            text = L"Hover a row for that watch's observed success rate and expected bottles.",
            kind = "meta",
        },
    }, Tooltips.ANCHOR_WINDOW_TOP)
end

local function ShowCraftableRowTooltip(data)
    if not StockPiler2RecipeTooltip or not StockPiler2RecipeTooltip.ShowColoredRows then
        return
    end
    local contested = data.craftableShared == true
    local rows = {
        { text = L"Craftable", kind = "title" },
    }
    local craftable = tonumber(data.craftable) or 0
    local recipe = data.recipe or data.specRecipe
    local uid = tonumber(data.uniqueID) or 0
    local RS = StockPiler2.RecipeSpec
    local expected, rate, best, crafts = nil, nil, craftable, nil
    if RS and RS.ExpectedCraftableBottles and type(recipe) == "table" then
        expected, rate, best, crafts = RS.ExpectedCraftableBottles(recipe, uid)
        if best ~= nil then
            craftable = best
        end
    end
    if craftable > 0 or (crafts and crafts > 0) then
        local yield = tonumber(data.recipeYield)
        if (not yield or yield <= 0) and RS and RS.RecipeOutputYield and type(recipe) == "table" then
            yield = RS.RecipeOutputYield(recipe, uid)
        end
        local line = towstring(tostring(math.floor((craftable or 0) + 0.5))) .. L" best-case"
        if crafts and crafts > 0 and yield and yield > 0 then
            line = line
                .. L" ("
                .. towstring(tostring(crafts))
                .. L" crafts x "
                .. FormatTooltipNumber(yield)
                .. L" yield)"
        end
        rows[#rows + 1] = { text = line, kind = "body" }
    else
        rows[#rows + 1] = {
            text = L"No crafts possible with current bag materials.",
            kind = "body",
        }
    end

    if rate ~= nil then
        local pct = math.floor(rate * 100 + 0.5)
        local attempts = tonumber(recipe and recipe.brewAttempts) or 0
        local successes = 0
        if RS and RS.OutcomeForPotion then
            local oc = RS.OutcomeForPotion(recipe, uid)
            if type(oc) == "table" then
                successes = tonumber(oc.successes) or 0
            end
        end
        local rateLine = L"Success rate "
            .. towstring(tostring(pct))
            .. L"% for this potion"
        if attempts > 0 then
            rateLine = rateLine
                .. L" ("
                .. towstring(tostring(successes))
                .. L"/"
                .. towstring(tostring(attempts))
                .. L")"
        end
        rows[#rows + 1] = {
            text = rateLine,
            kind = rate < 0.5 and "warning" or "meta",
        }
        if expected ~= nil and craftable > 0 then
            rows[#rows + 1] = {
                text = L"~"
                    .. FormatTooltipNumber(expected)
                    .. L" expected of this potion from current mats",
                kind = rate < 0.5 and "warning" or "body",
            }
        end
    else
        rows[#rows + 1] = {
            text = L"No observed success rate yet - Craftable is best case only.",
            kind = "meta",
        }
        rows[#rows + 1] = {
            text = L"Potent / other rarities do not fill a different watch.",
            kind = "meta",
        }
    end

    if contested then
        rows[#rows + 1] = {
            text = L"Yellow: other short watches share materials and bag stock cannot cover all deficit craftable claims.",
            kind = "warning",
        }
        rows[#rows + 1] = {
            text = L"AutoGrow keeps filling shared plants until Craftable turns green. Row Load/Brew can brew early; footer Brew waits for uncontested Ready.",
            kind = "meta",
        }
    else
        rows[#rows + 1] = {
            text = L"Green: bag stock covers this short watch and any other short sharers - Brew can load.",
            kind = "meta",
        }
    end

    StockPiler2RecipeTooltip.ShowColoredRows(
        SystemData.ActiveWindow.name,
        rows,
        Tooltips.ANCHOR_WINDOW_TOP
    )
end

function StockPiler2TabWatch.OnMouseOverCraftable()
    local data = RowDataFromActiveChild()
    if data then
        ShowCraftableRowTooltip(data)
    else
        ShowCraftableHeaderTooltip()
    end
end

function StockPiler2TabWatch.OnMouseOverTarget()
    Tooltips.CreateTextOnlyTooltip(
        SystemData.ActiveWindow.name,
        L"Target stock. L-click +1, R-click -1. Hold Shift for +/-10."
    )
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverRowAutoGrow()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, L"Grow materials for this potion when AutoGrow is enabled.")
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnLoadRow()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    if not StockPiler2.Brew or not StockPiler2.Brew.OnRowCraftClick then
        return
    end
    local result = StockPiler2.Brew.OnRowCraftClick(data)
    if result == "go" and StockPiler2.Brew.FirePerform then
        StockPiler2.Brew.FirePerform()
    end
end

function StockPiler2TabWatch.OnLoadRowRightClick()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    if StockPiler2.Brew and StockPiler2.Brew.OnRowCraftRightClick then
        StockPiler2.Brew.OnRowCraftRightClick(data)
    end
end

function StockPiler2TabWatch.OnMouseOverLoad()
    local data = RowDataFromActiveChild()
    if StockPiler2.Brew and StockPiler2.Brew.ShowRowBrewTooltip then
        StockPiler2.Brew.ShowRowBrewTooltip(
            SystemData.ActiveWindow.name,
            data,
            Tooltips.ANCHOR_WINDOW_TOP
        )
        return
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, L"Load and brew this watch.")
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPiler2TabWatch.OnMouseOverCraftableHeader()
    ShowCraftableHeaderTooltip()
end

function StockPiler2TabWatch.OnCraftableHeaderClick()
end
