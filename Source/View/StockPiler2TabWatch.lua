----------------------------------------------------------------
-- StockPiler2TabWatch — watched potion dashboard
-- Footer Clear watches / Harvest live on StockPiler2Window (Watch tab only).
----------------------------------------------------------------

StockPiler2TabWatch = {}
StockPiler2TabWatch.listData = {}
StockPiler2TabWatch.displayOrder = {}

local function T(key, tokens)
    if StockPiler2.T then
        return StockPiler2.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

-- Engine gather label is wstring; compare/display via T so English TradeSkillCaps still match.
local CULT_NAME = T("plan.fallback.cultivation")

local ICON_SCALE = 0.34
local TARGET_MAX = 200
local ENABLE_WIN = "SP2TabWatchEnable"
local ADDITIVES_WIN = "SP2TabWatchAdditives"
local AUTOBUY_WIN = "SP2TabWatchAutoBuy"
local SEED_BUFFER_ENABLE_WIN = "SP2TabWatchSeedBufferEnable"
local COMBAT_PAUSE_WIN = "SP2TabWatchCombatPause"
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
        ButtonSetText(loadWin, T("watch.chip_brew"))
        ButtonSetDisabledFlag(loadWin, false)
        SetButtonTextColorAll(loadWin, CRAFT_COLOR_BREW[1], CRAFT_COLOR_BREW[2], CRAFT_COLOR_BREW[3])
    elseif state == "loading" then
        ButtonSetText(loadWin, T("watch.chip_load"))
        ButtonSetDisabledFlag(loadWin, true)
        SetButtonTextColorAll(loadWin, CRAFT_COLOR_LOAD[1], CRAFT_COLOR_LOAD[2], CRAFT_COLOR_LOAD[3])
    elseif state == "load" then
        ButtonSetText(loadWin, T("watch.chip_load"))
        ButtonSetDisabledFlag(loadWin, false)
        SetButtonTextColorAll(loadWin, CRAFT_COLOR_LOAD[1], CRAFT_COLOR_LOAD[2], CRAFT_COLOR_LOAD[3])
    else
        ButtonSetText(loadWin, T("watch.chip_idle"))
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
    need_skill = COLOR_BLOCK,
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

local function UpdateCombatPauseCheckbox()
    local row = CharRow()
    if not DoesWindowExist(COMBAT_PAUSE_WIN) then
        return
    end
    local can = CanAutoGrowUi()
    local paused = true
    if type(row) == "table" then
        paused = row.autoGrowPauseCombat ~= false
    end
    syncingUi = true
    ButtonSetCheckButtonFlag(COMBAT_PAUSE_WIN, true)
    ButtonSetPressedFlag(COMBAT_PAUSE_WIN, can and paused)
    ButtonSetDisabledFlag(COMBAT_PAUSE_WIN, not can)
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

--- Overlay live bag counts on plan rows so Stock/Craftable do not lag coalesce.
--- Safe Status flips (stocked / ready / seed-buffer) follow live deficit within ~1s;
--- buy/shared/plant statuses stay plan-owned until Planner.Build.
local function PatchPlanSnapshotLiveStatus(row)
    if type(row) ~= "table" then
        return
    end
    local PS = StockPiler2.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) ~= "table" or type(plan.rows) ~= "table" then
        return
    end
    local keyStr = tostring(row.potionRecipeKey or row.id or row.potionKey or "")
    local uid = tonumber(row.uniqueID) or 0
    if keyStr == "" and uid <= 0 then
        return
    end
    for i = 1, #plan.rows do
        local snap = plan.rows[i]
        if type(snap) == "table" then
            local snapKey = tostring(snap.potionRecipeKey or snap.id or snap.potionKey or "")
            local snapUid = tonumber(snap.uniqueID) or 0
            local match = (keyStr ~= "" and snapKey == keyStr)
                or (uid > 0 and snapUid == uid)
            if match then
                snap.potionHave = row.potionHave
                snap.potionDeficit = row.potionDeficit
                snap.craftable = row.craftable
                snap.statusKey = row.statusKey
                snap.statusText = row.statusText
                snap.statusLines = row.statusLines
                snap.craftableShared = row.craftableShared
                return
            end
        end
    end
end

local function ApplyLiveWatchStatus(row, recipe, deficit, have, craftable, target)
    local key = tostring(row.statusKey or "")
    local potionKey = row.potionRecipeKey or row.id or row.potionKey
    local RS = StockPiler2.RecipeSpec

    local function SeedBufferShort()
        if type(recipe) ~= "table" or type(RS) ~= "table" then
            return false
        end
        if not (RS.ShouldAutoGrowPotion and RS.ShouldAutoGrowPotion(potionKey, nil) == true) then
            return false
        end
        if not (StockPiler2.Watch
            and StockPiler2.Watch.IsSeedBufferEnabled
            and StockPiler2.Watch.IsSeedBufferEnabled() == true)
        then
            return false
        end
        return RS.WatchHasSeedBufferShort and RS.WatchHasSeedBufferShort(recipe) == true
    end

    local function ApplySeedBufferStatus()
        local buffer = StockPiler2.Watch.GetSeedBufferMin
            and StockPiler2.Watch.GetSeedBufferMin() or 5
        row.statusKey = "need_seeds"
        row.statusText = T("plan.status.seed_buffer")
        row.statusLines = {
            T("plan.line.seed_buffer_short", { buffer = tostring(buffer) }),
            T("plan.line.seed_buffer_grow"),
        }
        row.craftableShared = false
    end

    local function ApplyStockedStatus()
        row.statusKey = "potion_stocked"
        row.statusText = T("plan.status.potions_stocked")
        row.statusLines = { T("plan.line.bag_at_target") }
        row.craftableShared = false
    end

    local function ApplyReadyStatus()
        row.statusKey = "ready_to_craft"
        row.statusText = T("plan.status.ready_to_craft")
        row.craftableShared = false
        if StockPiler2.TradeSkillCaps and StockPiler2.TradeSkillCaps.CanBrewPotions
            and StockPiler2.TradeSkillCaps.CanBrewPotions() == true
        then
            row.statusLines = {
                T("plan.line.ready_open_apo"),
                T("plan.line.ready_rarities_note"),
            }
        else
            row.statusLines = {
                T("plan.line.ready_apo_only_covered"),
            }
        end
    end

    -- Only flip among stocked / ready / seed-buffer; leave buy/plant/skill to plan.
    local flippable = key == "ready_to_craft"
        or key == "ready_to_craft_shared"
        or key == "potion_stocked"
        or key == "need_seeds"
    if not flippable then
        return
    end

    if deficit <= 0 then
        if SeedBufferShort() then
            if key ~= "need_seeds" then
                ApplySeedBufferStatus()
            end
        elseif key ~= "potion_stocked" then
            ApplyStockedStatus()
        end
        return
    end

    -- Below target: stocked → ready when craftable still covers.
    if key == "potion_stocked" and target > 0
        and (have + (tonumber(craftable) or 0)) >= target
    then
        if SeedBufferShort() then
            ApplySeedBufferStatus()
        else
            ApplyReadyStatus()
        end
    end
end

local function PatchWatchRowsLiveCounts(rows)
    if type(rows) ~= "table" or #rows == 0 then
        return
    end
    local Inv = StockPiler2.Inventory
    local RS = StockPiler2.RecipeSpec
    if not Inv or not Inv.CountByUid then
        return
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local uid = tonumber(row.uniqueID) or 0
            if uid > 0 then
                local have = tonumber(Inv.CountByUid(uid)) or 0
                row.potionHave = have
                row.stockText = towstring(tostring(have))
                local min = tonumber(row.potionMin) or tonumber(row.target) or 0
                local deficit = math.max(0, min - have)
                row.potionDeficit = deficit
                local recipe = row.recipe or row.specRecipe
                local craftable = tonumber(row.craftable) or 0
                if type(recipe) == "table" and RS then
                    if RS.CraftsNeededForDeficit then
                        row.craftsNeeded = RS.CraftsNeededForDeficit(deficit, recipe)
                    end
                    if RS.CountPotionsCraftable then
                        craftable = tonumber(RS.CountPotionsCraftable(recipe)) or 0
                        craftable = math.max(0, math.floor(craftable + 0.5))
                        row.craftable = craftable
                        if craftable > 0 or row.hasRecipe then
                            row.craftableText = towstring(tostring(craftable))
                        end
                    end
                end
                local prevKey = tostring(row.statusKey or "")
                ApplyLiveWatchStatus(row, recipe, deficit, have, craftable, min)
                if tostring(row.statusKey or "") ~= prevKey then
                    PatchPlanSnapshotLiveStatus(row)
                end
            end
        end
    end
end

local function PlanTipCacheKey()
    local planGen = 0
    local cacheKey = ""
    if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Get then
        local plan = StockPiler2.PlanSnapshot.Get()
        if type(plan) == "table" then
            planGen = tonumber(plan.planGen) or 0
            cacheKey = tostring(plan.cacheKey or "")
        end
    end
    -- Match painted list (plan snapshot), not live gens — avoids tip rebuild from
    -- stale statusTipSlots while bags/garden advance during plan coalesce.
    return tostring(planGen) .. ":" .. cacheKey
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
    local prevList = StockPiler2TabWatch.listData
    local prevOrder = StockPiler2TabWatch.displayOrder
    local plan = nil
    if opts.forcePlan == true and StockPiler2.Planner and StockPiler2.Planner.Build then
        plan = StockPiler2.Planner.Build({ force = true })
    elseif StockPiler2.Planner and StockPiler2.Planner.GetOrBuild then
        plan = StockPiler2.Planner.GetOrBuild({ refresh = false })
    elseif StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Get then
        plan = StockPiler2.PlanSnapshot.Get()
    end
    local rows = type(plan) == "table" and plan.rows or nil
    -- Never blank the open Watch list when plan is pending/nil after Invalidate.
    if type(rows) ~= "table" or #rows == 0 then
        local keepPrev = type(prevList) == "table" and #prevList > 0
        if keepPrev then
            local keep = type(plan) ~= "table"
            if not keep then
                local watches = StockPiler2.Watch and StockPiler2.Watch.GetWatches
                    and StockPiler2.Watch.GetWatches()
                if type(watches) == "table" then
                    for _, w in pairs(watches) do
                        if type(w) == "table" and w.enabled == true then
                            keep = true
                            break
                        end
                    end
                end
            end
            if keep then
                PatchWatchRowsLiveCounts(prevList)
                StockPiler2TabWatch.listData = prevList
                StockPiler2TabWatch.displayOrder = prevOrder or {}
                if #StockPiler2TabWatch.displayOrder == 0 then
                    for i = 1, #prevList do
                        StockPiler2TabWatch.displayOrder[i] = i
                    end
                end
                return
            end
        end
        rows = {}
    end
    PatchWatchRowsLiveCounts(rows)
    StockPiler2TabWatch.listData = rows
    StockPiler2TabWatch.displayOrder = {}
    for i = 1, #StockPiler2TabWatch.listData do
        StockPiler2TabWatch.displayOrder[i] = i
    end
end

function StockPiler2TabWatch.Initialize()
    LabelSetText("SP2TabWatchBannerTitle", T("watch.banner_title"))
    LabelSetText("SP2TabWatchBannerText", T("watch.banner_text"))
    LabelSetText("SP2TabWatchEnableLabel", T("watch.enable_autogrow"))
    LabelSetText("SP2TabWatchAdditivesLabel", T("watch.use_additives"))
    LabelSetText("SP2TabWatchSeedBufferLabel", T("watch.seed_buffer_label"))
    LabelSetText("SP2TabWatchAutoBuyLabel", T("watch.autobuy_label"))
    LabelSetText("SP2TabWatchCombatPauseLabel", T("watch.combat_pause_label"))
    LabelSetText("SP2TabWatchReserveLabel", T("watch.reserve_label"))
    LabelSetText("SP2TabWatchBudgetLabel", T("watch.budget_label"))
    TintStepper("SP2TabWatchSeedBufferChipBg")
    TintStepper("SP2TabWatchReserveChipBg")
    TintStepper("SP2TabWatchBudgetChipBg")
    ButtonSetText("SP2TabWatchColPotion", T("watch.col.potion"))
    ButtonSetText("SP2TabWatchColStock", T("watch.col.stock"))
    ButtonSetText("SP2TabWatchColStatus", T("watch.col.status"))
    ButtonSetText("SP2TabWatchColCraftable", T("watch.col.craftable"))
    ButtonSetText("SP2TabWatchColTarget", T("watch.col.target"))
    ButtonSetText("SP2TabWatchColPriority", T("watch.col.autogrow"))
    ButtonSetText("SP2TabWatchColBrew", T("watch.col.brew"))
    StockPiler2TabWatch.RefreshSkillGates()
end

--- Re-apply Cultivation/Apothecary skill gates on checkboxes/chips.
--- Call after LOADING_END / SESSION_LOADED — Initialize often runs before tradeSkills exist.
function StockPiler2TabWatch.RefreshSkillGates()
    if not DoesWindowExist("SP2TabWatch") then
        return
    end
    local canGrow = CanAutoGrowUi()
    local canBuy = CanAutoBuyUi()
    local row = CharRow()
    local autoGrow = canGrow and type(row) == "table" and row.autoGrowEnabled == true
    local additives = canGrow and type(row) == "table" and row.autoGrowAdditives == true
    local autoBuy = canBuy and type(row) == "table" and row.autoBuyEnabled == true
    local combatPause = type(row) ~= "table" or row.autoGrowPauseCombat ~= false
    local seedBufOn = type(row) == "table" and row.growSeedBufferEnabled ~= false
    local seedBuf = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin and StockPiler2.Watch.GetSeedBufferMin() or 5
    local reserve = type(row) == "table" and tonumber(row.autoBuyReserveGold) or 10
    local budget = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or 50
    local gatesKey = table.concat({
        tostring(canGrow), tostring(canBuy), tostring(autoGrow), tostring(additives),
        tostring(autoBuy), tostring(combatPause), tostring(seedBufOn), tostring(seedBuf),
        tostring(reserve), tostring(budget),
    }, ":")
    if StockPiler2TabWatch._skillGatesKey == gatesKey then
        return
    end
    StockPiler2TabWatch._skillGatesKey = gatesKey
    local prev = StockPiler2TabWatch._lastCanAutoGrow
    StockPiler2TabWatch._lastCanAutoGrow = canGrow
    UpdateEnableCheckbox()
    UpdateAdditivesCheckbox()
    UpdateAutoBuyCheckbox()
    UpdateCombatPauseCheckbox()
    UpdateSeedBufferEnableCheckbox()
    UpdateSeedBufferLabel()
    UpdateAutoBuyChips()
    if prev == false and canGrow == true then
        if StockPiler2.Ui and StockPiler2.Ui.MarkWatchUiDirty then
            StockPiler2.Ui.MarkWatchUiDirty()
        end
    end
end

function StockPiler2TabWatch.Refresh(opts)
    opts = type(opts) == "table" and opts or {}
    if not DoesWindowExist("SP2TabWatch") then
        return
    end
    StockPiler2TabWatch.RefreshSkillGates()
    local prevOrder = StockPiler2TabWatch.displayOrder
    BuildVisibleList(opts)
    if not DoesWindowExist("SP2TabWatchList") then
        return
    end
    local order = StockPiler2TabWatch.displayOrder
    local orderChanged = type(prevOrder) ~= "table" or type(order) ~= "table"
        or #prevOrder ~= #order
    if not orderChanged and type(prevOrder) == "table" and type(order) == "table" then
        for i = 1, #order do
            if prevOrder[i] ~= order[i] then
                orderChanged = true
                break
            end
        end
    end
    if orderChanged then
        -- One ListBoxSetDisplayOrder triggers XML populationfunction (UpdateRows).
        StockPiler2TabWatch._rowPaintKey = {}
        StockPiler2TabWatch._rowIconNum = {}
        ListBoxSetDisplayOrder("SP2TabWatchList", order or {})
    else
        StockPiler2TabWatch.UpdateRows()
    end
end

--- Drop paint caches so the next UpdateRows cannot skip after ListBox chrome recreate.
function StockPiler2TabWatch.ClearRowPaintCache()
    StockPiler2TabWatch._rowPaintKey = {}
    StockPiler2TabWatch._rowIconNum = {}
end

--- Invalidate Load/Brew paint keys only — no paint. Pair with MarkWatchUiDirty.
--- Clears Watch content coalesce key so FlushWatchUiIfDirty cannot drop dirty when
--- only brew session phase changed (Load→Brew / unload).
function StockPiler2TabWatch.InvalidateBrewChrome()
    StockPiler2TabWatch._rowPaintKey = nil
    if StockPiler2.Ui then
        StockPiler2.Ui._watchUiLastKey = nil
        StockPiler2.Ui._watchUiLastBrewKey = nil
    end
end

function StockPiler2TabWatch.UpdateRows()
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("WatchRows")
    end
    local numVisible = tonumber(SP2TabWatchList.numVisibleRows) or 11
    local indices = SP2TabWatchList.PopulatorIndices
    local active = {}
    if type(indices) == "table" then
        for rowIndex, dataIndex in ipairs(indices) do
            active[rowIndex] = dataIndex
        end
    end
    StockPiler2TabWatch._rowPaintKey = StockPiler2TabWatch._rowPaintKey or {}
    local canGrow = CanAutoGrowUi()
    local listData = StockPiler2TabWatch.listData
    for rowIndex = 1, numVisible do
        local rowName = "SP2TabWatchListRow" .. rowIndex
        if not DoesWindowExist(rowName) then
            -- skip
        else
            local dataIndex = active[rowIndex]
            local data = dataIndex and type(listData) == "table" and listData[dataIndex] or nil
            if data then
                WindowSetShowing(rowName, true)
                -- Always retint: ListBox row recreate resets alpha to opaque white.
                if DefaultColor and DefaultColor.SetListRowTint then
                    DefaultColor.SetListRowTint(rowName .. "Background", rowIndex, false)
                end
                local brewState = "idle"
                if StockPiler2.Brew and StockPiler2.Brew.GetRowCraftUiState then
                    brewState = StockPiler2.Brew.GetRowCraftUiState(data) or "idle"
                end
                local paintKey = table.concat({
                    tostring(data.iconNum or 0),
                    tostring(data.name or ""),
                    tostring(data.statusText or ""),
                    tostring(data.stockText or data.potionHave or 0),
                    tostring(data.craftableText or ""),
                    tostring(data.targetText or data.target or 0),
                    tostring(data.statusKey or ""),
                    tostring(data.autoGrow == true),
                    tostring(data.craftableShared == true),
                    tostring(brewState),
                    tostring(canGrow),
                }, "|")
                if StockPiler2TabWatch._rowPaintKey[rowIndex] ~= paintKey then
                    local iconWin = rowName .. "Icon"
                    local lastIcon = StockPiler2TabWatch._rowIconNum
                    if type(lastIcon) ~= "table" then
                        lastIcon = {}
                        StockPiler2TabWatch._rowIconNum = lastIcon
                    end
                    if lastIcon[rowIndex] ~= data.iconNum then
                        lastIcon[rowIndex] = data.iconNum
                        SetIconTexture(iconWin, data.iconNum)
                    end
                    LabelSetText(rowName .. "Name", data.name or L"")
                    LabelSetText(rowName .. "Status", data.statusText or L"")
                    LabelSetText(rowName .. "Stock", data.stockText or towstring(tostring(data.potionHave or 0)))
                    LabelSetText(rowName .. "Craftable", data.craftableText or T("ui.dash"))
                    LabelSetText(rowName .. "Target", data.targetText or towstring(tostring(data.target or 0)))
                    TintStepper(rowName .. "TargetChipBg")
                    ApplyStatusColor(rowName .. "Status", data.statusKey)
                    local autoGrowWin = rowName .. "AutoGrow"
                    if DoesWindowExist(autoGrowWin) then
                        syncingUi = true
                        ButtonSetCheckButtonFlag(autoGrowWin, true)
                        ButtonSetPressedFlag(autoGrowWin, canGrow and data.autoGrow == true)
                        ButtonSetDisabledFlag(autoGrowWin, not canGrow)
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
                    -- Only cache after a full paint so a mid-paint failure cannot sticky-skip.
                    StockPiler2TabWatch._rowPaintKey[rowIndex] = paintKey
                end
            else
                -- Unused ListBox slots stay opaque white unless hidden.
                WindowSetShowing(rowName, false)
                StockPiler2TabWatch._rowPaintKey[rowIndex] = nil
            end
        end
    end
    if Perf and Perf.End then
        Perf.End("WatchRows")
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

--- 0.4.135: demand-changing settings — Bump + prewarm + coalesced PlanRebuild.
--- Avoid sync Refresh on the click frame (list paints via MarkWatchUiDirty).
local function AfterWatchSettingsChanged()
    BumpWatch()
    local Sch = StockPiler2.Scheduler
    if Sch and Sch.RequestCachePrewarm then
        Sch.RequestCachePrewarm("settings")
    end
    if Sch and Sch.EnqueuePlanRebuild then
        Sch.EnqueuePlanRebuild({ nudge = true })
    end
    if StockPiler2.Ui and StockPiler2.Ui.MarkWatchUiDirty then
        StockPiler2.Ui.MarkWatchUiDirty()
    end
end

--- Instant Target label paint without Refresh / plan rebuild.
local function ApplyTargetOptimistic(data, target)
    if type(data) ~= "table" then
        return
    end
    target = tonumber(target) or 0
    data.target = target
    data.targetText = towstring(tostring(target))
    data.potionMin = target
    local have = tonumber(data.potionHave) or 0
    data.potionDeficit = math.max(0, target - have)
    StockPiler2TabWatch._rowPaintKey = nil
    if StockPiler2TabWatch.UpdateRows then
        StockPiler2TabWatch.UpdateRows()
    end
end

--- Patch live PlanSnapshot row targets so tips/status stay consistent without rebuild.
local function PatchPlanSnapshotTarget(potionKey, target, have)
    if potionKey == nil then
        return
    end
    target = tonumber(target) or 0
    have = tonumber(have)
    local PS = StockPiler2.PlanSnapshot
    local plan = PS and PS.Get and PS.Get()
    if type(plan) ~= "table" or type(plan.rows) ~= "table" then
        return
    end
    local keyStr = tostring(potionKey)
    for i = 1, #plan.rows do
        local row = plan.rows[i]
        if type(row) == "table" then
            local rowKey = row.potionRecipeKey or row.id or row.potionKey
            if rowKey ~= nil and tostring(rowKey) == keyStr then
                row.target = target
                row.potionMin = target
                local rowHave = have
                if rowHave == nil then
                    rowHave = tonumber(row.potionHave) or 0
                end
                row.potionDeficit = math.max(0, target - rowHave)
            end
        end
    end
end

--- True when target tweak cannot change grow/brew demand or status class.
--- stocked↔stocked (have >= both targets > 0) or no_target↔no_target (both 0).
local function TargetChangeIsDemandNoop(have, oldTarget, newTarget)
    have = tonumber(have) or 0
    oldTarget = tonumber(oldTarget) or 0
    newTarget = tonumber(newTarget) or 0
    local oldDeficit = math.max(0, oldTarget - have)
    local newDeficit = math.max(0, newTarget - have)
    if oldDeficit > 0 or newDeficit > 0 then
        return false
    end
    -- no_target (0) vs potion_stocked (>0) is a status change — needs full plan.
    if (oldTarget > 0) ~= (newTarget > 0) then
        return false
    end
    return true
end

--- 0.4.133: stocked target chip (+1 with have already above target) used to BumpGen +
--- Invalidate + OnDemandChanged(force ClearCountCaches) + PlanRebuild (~400–750ms).
--- When deficit stays 0 and status class unchanged, paint + patch snapshot only.
local function AfterTargetChipChanged(data, potionKey, oldTarget, newTarget)
    local have = tonumber(data and data.potionHave)
    if have == nil and type(data) == "table" then
        local uid = tonumber(data.uniqueID) or 0
        if uid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUid then
            have = tonumber(StockPiler2.Inventory.CountByUid(uid)) or 0
        else
            have = 0
        end
    end
    have = tonumber(have) or 0
    if TargetChangeIsDemandNoop(have, oldTarget, newTarget) then
        ApplyTargetOptimistic(data, newTarget)
        PatchPlanSnapshotTarget(potionKey, newTarget, have)
        return
    end
    ApplyTargetOptimistic(data, newTarget)
    AfterWatchSettingsChanged()
end

local function NotifySettings(msg)
    if StockPiler2.Debug and StockPiler2.Debug.Notify then
        StockPiler2.Debug.Notify(msg)
    elseif StockPiler2.Debug and StockPiler2.Debug.Print then
        StockPiler2.Debug.Print(msg)
    end
end

local function OnOff(flag)
    return flag and T("boot.on") or T("boot.off")
end

local function PotionLabel(data)
    if type(data) == "table" and data.name ~= nil and data.name ~= L"" then
        return data.name
    end
    return T("watch.fallback")
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
    NotifySettings(T("watch.autogrow", { state = OnOff(row.autoGrowEnabled) }))
    -- 0.4.135: demand-changing — light Bump + prewarm + PlanRebuild (not sync Refresh).
    AfterWatchSettingsChanged()
    if row.autoGrowEnabled == true then
        if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
            StockPiler2.Scheduler.WakeAutoGrow()
        end
    else
        if StockPiler2.Orchestrator and StockPiler2.Orchestrator.OnAutoGrowDisabled then
            StockPiler2.Orchestrator.OnAutoGrowDisabled()
        end
    end
    UpdateEnableCheckbox()
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
    NotifySettings(T("watch.additives", { state = OnOff(row.autoGrowAdditives) }))
    -- 0.4.135: additives do not change plan demand — dirty plant job only.
    if StockPiler2.Grow and StockPiler2.Grow.MarkPlantJobDirty then
        StockPiler2.Grow.MarkPlantJobDirty()
    end
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
    NotifySettings(T("watch.seed_buffer", { state = OnOff(row.growSeedBufferEnabled) }))
    AfterWatchSettingsChanged()
    UpdateSeedBufferEnableCheckbox()
    UpdateSeedBufferLabel()
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
    NotifySettings(T("watch.autobuy", { state = OnOff(row.autoBuyEnabled) }))
    -- 0.4.135: AutoBuy flag does not change plan Status — no BumpWatch/PlanRebuild.
    if StockPiler2.Buy and StockPiler2.Buy.InvalidateJobsCache then
        StockPiler2.Buy.InvalidateJobsCache()
    end
    if row.autoBuyEnabled == true and StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoBuy then
        StockPiler2.Scheduler.WakeAutoBuy()
    end
    UpdateAutoBuyCheckbox()
    UpdateAutoBuyChips()
end

function StockPiler2TabWatch.OnToggleCombatPause()
    if syncingUi then
        return
    end
    if not CanAutoGrowUi() then
        UpdateCombatPauseCheckbox()
        return
    end
    local row = CharRow()
    if type(row) ~= "table" then
        return
    end
    row.autoGrowPauseCombat = ButtonGetPressedFlag(COMBAT_PAUSE_WIN) == true
    NotifySettings(T("watch.combat_pause", { state = OnOff(row.autoGrowPauseCombat) }))
    if StockPiler2.Grow and StockPiler2.Grow.ClearFillBlocked then
        StockPiler2.Grow.ClearFillBlocked()
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
        StockPiler2.Scheduler.WakeAutoGrow()
    end
    UpdateCombatPauseCheckbox()
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
    growSeedBufferMin = "watch.setting.seed_buffer",
    autoBuyReserveGold = "watch.setting.reserve",
    autoBuyBudgetGold = "watch.setting.budget",
}

local function AdjustChip(field, delta, lo, hi)
    local row = CharRow()
    if type(row) ~= "table" then
        return
    end
    local old = tonumber(row[field]) or lo
    local n = old + delta
    if n < lo then n = lo end
    if n > hi then n = hi end
    if n == old then
        return
    end
    row[field] = n
    local labelKey = CHIP_NOTIFY_LABEL[field]
    if labelKey then
        NotifySettings(T("watch.setting_eq", { label = T(labelKey), value = tostring(n) }))
    end
    -- 0.4.135: money chips are Soft; seed buffer min is Light (status/seed-lines).
    if field == "autoBuyReserveGold" or field == "autoBuyBudgetGold" then
        UpdateAutoBuyChips()
        if StockPiler2.Buy and StockPiler2.Buy.ClearMoneyGateStop then
            StockPiler2.Buy.ClearMoneyGateStop(field)
        elseif StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoBuy then
            StockPiler2.Scheduler.WakeAutoBuy()
        end
        return
    end
    if field == "growSeedBufferMin" then
        AfterWatchSettingsChanged()
        UpdateSeedBufferLabel()
        return
    end
    AfterWatchSettingsChanged()
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
    NotifySettings(T("watch.row_autogrow", { name = PotionLabel(data), state = OnOff(watch.autoGrow) }))
    -- 0.4.135: row AutoGrow changes demand — light plan path.
    AfterWatchSettingsChanged()
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
    local oldTarget = tonumber(watch.targetStock) or 0
    local target = oldTarget + ChipStep(flags)
    if target > TARGET_MAX then
        target = TARGET_MAX
    end
    if target == oldTarget then
        return
    end
    watch.targetStock = target
    watch.enabled = true
    NotifySettings(T("watch.row_target", { name = PotionLabel(data), value = tostring(target) }))
    AfterTargetChipChanged(data, potionKey, oldTarget, target)
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
    local oldTarget = tonumber(watch.targetStock) or 0
    local target = oldTarget - ChipStep(flags)
    if target < 0 then
        target = 0
    end
    if target == oldTarget then
        return
    end
    watch.targetStock = target
    if target > 0 then
        watch.enabled = true
    end
    NotifySettings(T("watch.row_target", { name = PotionLabel(data), value = tostring(target) }))
    AfterTargetChipChanged(data, potionKey, oldTarget, target)
end

function StockPiler2TabWatch.OnMouseOverEnabled()
    if not CanAutoGrowUi() then
        local Caps = StockPiler2.TradeSkillCaps
        local gather = Caps and Caps.GatheringLabel and Caps.GatheringLabel()
        local text = T("tip.watch.autogrow_need_cult")
        if gather ~= nil and gather ~= CULT_NAME then
            text = T("tip.watch.autogrow_gathers", { gather = gather })
        end
        Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, text)
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
        return
    end
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("tip.watch.autogrow_master"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverAdditives()
    if not CanAutoGrowUi() then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            T("tip.watch.additives_need_cult")
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
        return
    end
    Tooltips.CreateTextOnlyTooltip(
        SystemData.ActiveWindow.name,
        T("tip.watch.additives")
    )
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverAutoBuy()
    if not CanAutoBuyUi() then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            T("tip.watch.autobuy_need_skill")
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
        return
    end
    local text = T("tip.watch.autobuy")
    if CanAutoGrowUi() then
        text = text .. T("tip.watch.autobuy_growable")
    else
        text = text .. T("tip.watch.autobuy_no_cult")
    end
    text = text .. T("tip.watch.autobuy_indep")
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, text)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverCombatPause()
    if not CanAutoGrowUi() then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            T("tip.watch.combat_pause_need_cult")
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
        return
    end
    Tooltips.CreateTextOnlyTooltip(
        SystemData.ActiveWindow.name,
        T("tip.watch.combat_pause")
    )
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverSeedBufferEnable()
    if not CanAutoGrowUi() then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            T("tip.watch.seed_buffer_need_cult")
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
        return
    end
    Tooltips.CreateTextOnlyTooltip(
        SystemData.ActiveWindow.name,
        T("tip.watch.seed_buffer")
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
    return T("watch.watched_seed")
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
                        resinNeed = 0,
                    }
                    intentsByKey[key] = rec
                end
                local uses = math.max(1, tonumber(it.uses) or 1)
                rec.count = rec.count + uses
                if it.reason == "plant-need" then
                    rec.plantNeed = rec.plantNeed + uses
                elseif it.reason == "resin-need" then
                    rec.resinNeed = rec.resinNeed + uses
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

local function BuildSeedBufferTooltipRows(data)
    local MS = StockPiler2.MaterialSpec
    local colorOk = RgbDef(COLOR_OK)
    local colorWarn = RgbDef(COLOR_WARN)
    local colorBlock = RgbDef(COLOR_BLOCK)
    local sepLine = (StockPiler2RecipeTooltip and StockPiler2RecipeTooltip.SEP_LINE)
        or T("watch.sep")

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
            header = fallbackName or T("watch.watched_seed")
        end
        local detail = parts and parts.detail or L""
        return header, detail
    end

    local rows = {
        { text = T("tip.watch.sb.title"), kind = "title" },
        {
            text = T("tip.watch.sb.buffer_line", {
                value = tostring(data.buffer),
                state = data.enabled and T("watch.enabled") or T("watch.disabled"),
            }),
            kind = data.enabled and "body" or "warning",
        },
        { text = T("tip.watch.sb.watched_seeds"), kind = "meta" },
    }

    local maxWatched = 4
    local maxIntents = 3

    if #data.watched == 0 then
        rows[#rows + 1] = { text = T("tip.watch.sb.none"), kind = "meta" }
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
                liveText = liveText .. T("tip.watch.sb.live_ground", { ground = tostring(w.ground) })
            end
            local statusText = T("tip.watch.sb.status", {
                live = liveText,
                planned = tostring(w.planned),
                need = tostring(data.buffer),
            })
            local credit = tonumber(w.total) or ((tonumber(w.live) or 0) + (tonumber(w.ground) or 0) + (tonumber(w.planned) or 0))
            local shortBy = tonumber(w.shortBy) or 0
            local statusColor = colorOk
            if shortBy > 0 then
                statusText = statusText .. T("tip.watch.sb.short", { n = tostring(shortBy) })
                if credit <= 0 then
                    statusColor = colorBlock
                else
                    statusColor = colorWarn
                end
            else
                statusText = statusText .. T("tip.watch.sb.ok")
            end
            rows[#rows + 1] = { text = statusText, kind = "body", color = statusColor }
        end
        if #data.watched > maxWatched then
            rows[#rows + 1] = {
                text = T("tip.watch.sb.more_watched", { n = tostring(#data.watched - maxWatched) }),
                kind = "meta",
            }
        end
    end

    rows[#rows + 1] = { text = T("tip.watch.sb.planned_refine"), kind = "meta" }
    if #data.intents == 0 then
        rows[#rows + 1] = { text = T("tip.watch.sb.no_refine"), kind = "meta" }
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
            local reason = T("tip.watch.sb.reason.buffer")
            if it.resinNeed and it.resinNeed > 0 then
                reason = T("tip.watch.sb.reason.resin")
            elseif it.plantNeed > 0 and it.seedBuffer > 0 then
                reason = T("tip.watch.sb.reason.need_buffer")
            elseif it.plantNeed > 0 then
                reason = T("tip.watch.sb.reason.need")
            end
            rows[#rows + 1] = {
                text = T("tip.watch.sb.queued", { count = tostring(it.count), reason = reason }),
                kind = "body",
            }
        end
        if #data.intents > maxIntents then
            rows[#rows + 1] = {
                text = T("tip.watch.sb.more_refine", { n = tostring(#data.intents - maxIntents) }),
                kind = "meta",
            }
        end
    end

    rows[#rows + 1] = {
        text = T("tip.watch.seed_buffer_chip"),
        kind = "meta",
    }
    return rows
end

function StockPiler2TabWatch.OnMouseOverSeedBuffer()
    if not StockPiler2RecipeTooltip or not StockPiler2RecipeTooltip.ShowColoredRows then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            T("tip.watch.seed_buffer_chip")
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
        return
    end

    local genKey = PlanTipCacheKey()
    local cache = StockPiler2TabWatch._seedBufferTipCache
    if type(cache) ~= "table" or cache.genKey ~= genKey then
        cache = { genKey = genKey, rows = nil }
        StockPiler2TabWatch._seedBufferTipCache = cache
    end
    local rows = cache.rows
    if type(rows) ~= "table" then
        if StockPiler2.Perf and StockPiler2.Perf.Begin then
            StockPiler2.Perf.Begin("SeedBufferTooltip.Build")
        end
        rows = BuildSeedBufferTooltipRows(CollectSeedBufferTooltipData())
        cache.rows = rows
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("SeedBufferTooltip.Build")
        end
    end
    StockPiler2RecipeTooltip.ShowColoredRows(SystemData.ActiveWindow.name, rows, Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPiler2TabWatch.OnMouseOverReserve()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("tip.watch.reserve_chip"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverBudget()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("tip.watch.budget_chip"))
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
    Tooltips.SetTooltipText(1, 1, title or T("ui.potion_fallback"))
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
    local have = tostring(data.potionHave or 0)
    local target = tostring(data.potionMin or data.target or 0)
    local line2
    if data.statusText and data.statusText ~= L"" then
        line2 = T("tip.watch.have_target_status", {
            have = have,
            target = target,
            status = data.statusText,
        })
    else
        line2 = T("tip.watch.have_target", { have = have, target = target })
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
            name = data.name or T("ui.potion_fallback"),
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
        data.name or T("ui.potion_fallback"),
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
    -- Yellow: AutoGrow can still progress (or buy seeds/plants accelerates the same path).
    if string.find(n, "needs planting", 1, true)
        or string.find(n, "converting", 1, true)
        or string.find(n, "need seed", 1, true)
        or string.find(n, "buy seeds", 1, true)
        or string.find(n, "buy plants", 1, true)
    then
        return "warning"
    end
    -- Red: player must intervene outside grow/refine (vendor mats, cult/AG off).
    if string.find(n, "buy flasks", 1, true)
        or string.find(n, "buy materials", 1, true)
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

--- Match Planner: containers / vendor mats are not AutoGrow-progressable.
local function SpecIsAutoGrowProgressableTip(entry)
    if type(entry) ~= "table" then
        return false
    end
    if entry.role == "container" then
        return false
    end
    local spec = entry.spec
    if type(spec) ~= "table" then
        return false
    end
    local SM = StockPiler2.SeedMap
    if SM and SM.IsGrowableSpec and SM.IsGrowableSpec(spec) == true then
        return true
    end
    local MS = StockPiler2.MaterialSpec
    if MS and MS.IsGrowable and MS.IsGrowable(spec) == true then
        return true
    end
    return false
end

local function TitleCaseStatusNote(notes)
    local narrow = StockPiler2.ToNarrow and StockPiler2.ToNarrow(notes) or tostring(notes or "")
    if narrow == "" then
        return notes
    end
    local lower = string.lower(narrow)
    if lower == "stocked" then
        return T("watch.note.stocked")
    end
    if lower == "shared" then
        return T("watch.note.shared")
    end
    if lower == "pooled" then
        return T("watch.note.pooled")
    end
    if lower == "buy flasks" then
        return T("watch.note.buy_flasks")
    end
    if lower == "buy materials" then
        return T("watch.note.buy_materials")
    end
    if lower == "buy seeds" then
        return T("watch.note.buy_seeds")
    end
    if lower == "buy plants" then
        return T("watch.note.buy_plants")
    end
    if lower == "needs planting" then
        return T("watch.note.needs_planting")
    end
    if lower == "needs cultivation" then
        return T("watch.note.needs_cult")
    end
    if lower == "autogrow off for this watch" then
        return T("watch.note.autogrow_off")
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

local function BuildStatusTooltipRows(data)
    local rows = {
        {
            text = data.statusText or T("watch.col.status"),
            kind = "title",
            color = StatusTitleColor(data.statusKey),
        },
    }

    local function appendMeta(text)
        if text and text ~= L"" then
            rows[#rows + 1] = { text = text, kind = "meta" }
        end
    end

    local slots = data.statusTipSlots
    if type(slots) ~= "table" or #slots == 0 then
        slots = data.statusSlots
    end
    local recipe = data.recipe or data.specRecipe
    local craftsNeeded = tonumber(data.craftsNeeded) or 0
    local deficit = tonumber(data.potionDeficit) or 0
    -- Prefer live bag stock for Need-line when list already overlaid live counts.
    local liveHave = tonumber(data.potionHave)
    local liveMin = tonumber(data.potionMin) or tonumber(data.target) or 0
    if liveHave ~= nil and liveMin > 0 then
        deficit = math.max(0, liveMin - liveHave)
        local RS = StockPiler2.RecipeSpec
        local recipeForNeed = data.recipe or data.specRecipe
        if deficit > 0 and type(recipeForNeed) == "table" and RS and RS.CraftsNeededForDeficit then
            craftsNeeded = tonumber(RS.CraftsNeededForDeficit(deficit, recipeForNeed)) or craftsNeeded
        elseif deficit <= 0 then
            craftsNeeded = 0
        end
    end
    local yield = tonumber(data.recipeYield) or 0
    local usedTipSlots = type(data.statusTipSlots) == "table" and #data.statusTipSlots > 0
    local fullSlots = nil
    if not usedTipSlots
        and type(recipe) == "table"
        and StockPiler2.Planner
        and StockPiler2.Planner.BuildRecipeSlotTooltipEntries
        and (craftsNeeded > 0 or (type(slots) == "table" and #slots > 0))
    then
        local demand = nil
        local RS = StockPiler2.RecipeSpec
        if RS and RS.BuildBalancedSpecDemand then
            demand = RS.BuildBalancedSpecDemand()
        end
        fullSlots = StockPiler2.Planner.BuildRecipeSlotTooltipEntries(recipe, craftsNeeded, demand)
    end
    if type(fullSlots) == "table" and #fullSlots > 0 then
        slots = fullSlots
    end
    if type(slots) == "table" and #slots > 0 then
        if craftsNeeded > 0 and deficit > 0 then
            rows[#rows + 1] = {
                text = T("tip.watch.need_crafts", {
                    crafts = tostring(craftsNeeded),
                    deficit = tostring(deficit),
                }),
                kind = "body",
            }
            if yield > 0 then
                appendMeta(T("tip.watch.yield_best_case", { yield = tostring(yield) }))
            end
            if data.statusKey == "enable_autogrow" then
                rows[#rows + 1] = {
                    text = T("tip.watch.enable_autogrow_row"),
                    kind = "warning",
                    color = RgbDef(COLOR_BLOCK),
                }
            elseif data.statusKey == "need_skill" then
                local lines = data.statusLines
                if type(lines) == "table" and #lines > 0 then
                    for i = 1, #lines do
                        rows[#rows + 1] = {
                            text = lines[i],
                            kind = "warning",
                            color = RgbDef(COLOR_BLOCK),
                        }
                    end
                else
                    rows[#rows + 1] = {
                        text = data.statusText or T("tip.watch.need_higher_skill"),
                        kind = "warning",
                        color = RgbDef(COLOR_BLOCK),
                    }
                end
            elseif data.statusKey == "need_apothecary" then
                rows[#rows + 1] = {
                    text = T("tip.watch.apo_only_brew"),
                    kind = "warning",
                    color = RgbDef(COLOR_BLOCK),
                }
            elseif data.statusKey == "buy_ingredients" and not CanAutoGrowUi() then
                local st = string.lower(
                    StockPiler2.ToNarrow and StockPiler2.ToNarrow(data.statusText) or tostring(data.statusText or "")
                )
                if not string.find(st, "flask", 1, true) then
                    local Caps = StockPiler2.TradeSkillCaps
                    local text = T("tip.watch.cult_required")
                    local gather = Caps and Caps.GatheringLabel and Caps.GatheringLabel()
                    if gather ~= nil and gather ~= CULT_NAME then
                        text = T("tip.watch.gathers_via", { gather = gather })
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
                        text = T("tip.watch.success_expected", {
                            pct = tostring(pct),
                            crafts = tostring(expectedCrafts),
                        }),
                        kind = "warning",
                    }
                end
                if RS.FormatApoSkillUpLine then
                    local apoLine = RS.FormatApoSkillUpLine(recipe)
                    if apoLine and apoLine ~= L"" then
                        appendMeta(apoLine)
                    end
                end
            end
        elseif data.statusNeedLine and data.statusNeedLine ~= L"" then
            appendMeta(data.statusNeedLine)
        end

        rows[#rows + 1] = {
            text = (StockPiler2RecipeTooltip and StockPiler2RecipeTooltip.SEP_LINE)
                or T("watch.sep"),
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
                            text = T("watch.sep"),
                            kind = "separator",
                        }
                    end
                end
                slotShown = slotShown + 1

                local parts = MS and MS.NeedLabelParts and MS.NeedLabelParts(entry.spec) or nil
                local header = parts and parts.header
                    or (MS and MS.NeedLabel and MS.NeedLabel(entry.spec))
                    or T("watch.material_fallback")
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

                -- Live bag Have (plan Need / craftsNeeded stay from row until rebuild).
                local RS = StockPiler2.RecipeSpec
                if RS and RS.CountItemsMatchingSpec and type(entry.spec) == "table" then
                    local liveHave = tonumber(RS.CountItemsMatchingSpec(entry.spec)) or 0
                    entry.have = liveHave
                    local need = tonumber(entry.need) or 0
                    entry.deficit = math.max(0, need - liveHave)
                    entry.stocked = entry.deficit <= 0
                    local perCraft = tonumber(entry.perCraft) or 1
                    if perCraft > 0 then
                        entry.craftsHave = math.floor(liveHave / perCraft)
                    end
                end
                local stocked = entry.stocked == true or (tonumber(entry.deficit) or 0) <= 0
                local agProgressable = SpecIsAutoGrowProgressableTip(entry)
                -- Red = player buy / blocked; yellow = AutoGrow (grow/refine) can still progress.
                -- Do not use entry.kind alone: growable shorts become kind=buy when seedCredit is 0.
                local haveColor = colorOk
                if not stocked then
                    if entry.kind == "convert" then
                        -- Byproduct: yellow while plant feedstock or refinable surplus can feed convert.
                        local feedable = false
                        for j = 1, #slots do
                            local sibling = slots[j]
                            if type(sibling) == "table" and sibling.kind == "plant" then
                                feedable = true
                                break
                            end
                        end
                        if not feedable then
                            if data.convertFeedable == true then
                                feedable = true
                            elseif StockPiler2.Refine and StockPiler2.Refine.HasResinConvertFeedstock
                                and StockPiler2.Refine.HasResinConvertFeedstock() == true
                            then
                                feedable = true
                            end
                        end
                        haveColor = feedable and colorWarn or colorBlock
                    elseif agProgressable then
                        haveColor = colorWarn
                    else
                        haveColor = colorBlock
                    end
                end
                local statusNote = nil
                local noteKind = stocked and "stocked" or "body"
                -- Plant notes, or growable kind=buy (seed line exhausted → planner buySeedOrMat).
                if (entry.kind == "plant" or (agProgressable and entry.kind ~= "convert"))
                    and not stocked
                then
                    -- Always prefer live plot notes over plan-time growingNotes.
                    local notes = L""
                    if Grow and Grow.GrowingNotesForSpec then
                        notes = Grow.GrowingNotesForSpec(entry.spec) or L""
                    end
                    if notes == nil or notes == L"" then
                        notes = entry.growingNotes
                    end
                    if notes == nil or notes == L"" then
                        notes = L""
                    end
                    if notes == L"" then
                        if not CanAutoGrowUi() then
                            notes = T("watch.note.needs_cult")
                            haveColor = colorBlock
                        elseif data.autoGrow == true then
                            -- Prefer plan-time seed credit when present; else resolve once.
                            local seedUid = tonumber(entry.seedUid) or 0
                            local credit = tonumber(entry.seedCredit)
                            if credit == nil then
                                credit = 0
                                if seedUid <= 0 then
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
                                end
                                if seedUid > 0 and StockPiler2.Refine and StockPiler2.Refine.GetSeedBudgetForSpec then
                                    local budget = StockPiler2.Refine.GetSeedBudgetForSpec(entry.spec, seedUid)
                                    credit = tonumber(budget and budget.credit) or 0
                                end
                            end

                            -- Yellow: matches status need_seeds / restocking (buy seeds helps, AG can too).
                            if seedUid > 0 and credit <= 0 then
                                notes = T("watch.note.buy_seeds")
                                haveColor = colorWarn
                            elseif seedUid <= 0 then
                                notes = T("watch.note.buy_plants")
                                haveColor = colorWarn
                            else
                                notes = T("watch.note.needs_planting")
                                haveColor = colorWarn
                            end
                        else
                            notes = T("watch.note.autogrow_off")
                            haveColor = colorBlock
                        end
                    end
                    statusNote = TitleCaseStatusNote(notes)
                    noteKind = GrowingNoteKind(notes)
                elseif not stocked then
                    -- True buy path (container / butchered / vendor): red + Buy* note.
                    if entry.role == "container" then
                        statusNote = T("watch.note.buy_flasks")
                    elseif entry.buySeedOrMat == true
                        and (tonumber(entry.seedUid) or 0) > 0
                    then
                        statusNote = T("watch.note.buy_seeds")
                    else
                        statusNote = T("watch.note.buy_materials")
                    end
                    noteKind = "block"
                    haveColor = colorBlock
                elseif stocked then
                    local contestedKeys = data.contestedSpecKeys
                    local specKey = entry.specKey
                    local claimContested = (data.craftableShared == true
                            or data.statusKey == "ready_to_craft_shared"
                            or data.statusKey == "buy_ingredients")
                        and type(contestedKeys) == "table"
                        and type(specKey) == "string"
                        and specKey ~= ""
                        and contestedKeys[specKey] == true
                    -- Shared = brew-now claims fight other short watches (AutoGrow can progress).
                    -- Red Buy* only when Status is already buy_ingredients (buy-only contest).
                    -- Pooled = grow-to-target demand across watches still exceeds bags.
                    if claimContested then
                        if data.statusKey == "buy_ingredients"
                            and not SpecIsAutoGrowProgressableTip(entry)
                        then
                            if entry.role == "container" then
                                statusNote = T("watch.note.buy_flasks")
                            elseif entry.buySeedOrMat == true
                                and (tonumber(entry.seedUid) or 0) > 0
                            then
                                statusNote = T("watch.note.buy_seeds")
                            else
                                statusNote = T("watch.note.buy_materials")
                            end
                            noteKind = "block"
                            haveColor = colorBlock
                        else
                            statusNote = T("watch.note.shared")
                            noteKind = "warning"
                            haveColor = colorWarn
                        end
                    elseif entry.sharedPool == true then
                        statusNote = T("watch.note.pooled")
                        noteKind = "warning"
                        haveColor = colorWarn
                    else
                        statusNote = T("watch.note.stocked")
                        noteKind = "stocked"
                    end
                end
                local haveText
                if statusNote and statusNote ~= L"" then
                    haveText = T("tip.watch.have_need_note", {
                        have = tostring(entry.have or 0),
                        need = tostring(entry.need or 0),
                        note = statusNote,
                    })
                else
                    haveText = T("tip.watch.have_need", {
                        have = tostring(entry.have or 0),
                        need = tostring(entry.need or 0),
                    })
                end
                rows[#rows + 1] = {
                    text = haveText,
                    kind = noteKind,
                    color = haveColor,
                }
                if entry.kind == "plant" then
                    local seedUid = tonumber(entry.seedUid) or 0
                    local plantUid = tonumber(entry.plantUid) or 0
                    if seedUid <= 0 and StockPiler2.SeedMap and StockPiler2.SeedMap.ResolveSeedForSpec
                        and type(entry.spec) == "table"
                    then
                        local seed = StockPiler2.SeedMap.ResolveSeedForSpec(entry.spec)
                        if type(seed) == "table" then
                            seedUid = tonumber(seed.uniqueID) or 0
                            if plantUid <= 0 then
                                plantUid = tonumber(seed.plantUid) or 0
                            end
                        end
                    end
                    if seedUid > 0 and StockPiler2.SeedMap then
                        local rateLines = nil
                        if StockPiler2.SeedMap.FormatHarvestTooltipRateLines then
                            rateLines = StockPiler2.SeedMap.FormatHarvestTooltipRateLines(seedUid, plantUid)
                        end
                        if type(rateLines) == "table" then
                            for ri = 1, #rateLines do
                                if rateLines[ri] and rateLines[ri] ~= "" then
                                    appendMeta(towstring(rateLines[ri]))
                                end
                            end
                        elseif StockPiler2.SeedMap.FormatHarvestRateLine then
                            local rateLine = StockPiler2.SeedMap.FormatHarvestRateLine(seedUid, plantUid)
                            if type(rateLine) == "string" and rateLine ~= "" then
                                appendMeta(towstring(rateLine))
                            end
                        end
                    end
                end
            end
        end
    elseif type(data.statusLines) == "table" and #data.statusLines > 0 then
        for i = 1, #data.statusLines do
            appendMeta(data.statusLines[i])
        end
    elseif data.statusDetail and data.statusDetail ~= L"" then
        appendMeta(data.statusDetail)
    end

    return rows
end

function StockPiler2TabWatch.OnMouseOverStatus()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    if not StockPiler2RecipeTooltip or not StockPiler2RecipeTooltip.ShowColoredRows then
        Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, data.statusText or T("watch.col.status"))
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
        return
    end

    local engineMax = (Tooltips and tonumber(Tooltips.NUM_ROWS)) or 17
    -- Do not cache status tips across bag snaps: Have lines are live-refreshed and
    -- must not stick at plan-time zeros while plants sit in bags / plots.
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    local genKey = PlanTipCacheKey() .. ":s" .. tostring(snapGen)
    local watchKey = tostring(data.potionKey or data.id or "")
    local cache = StockPiler2TabWatch._statusTipCache
    if type(cache) ~= "table" or cache.genKey ~= genKey then
        cache = { genKey = genKey, byWatch = {} }
        StockPiler2TabWatch._statusTipCache = cache
    end
    local rows = watchKey ~= "" and cache.byWatch[watchKey] or nil
    if type(rows) ~= "table" then
        if StockPiler2.Perf and StockPiler2.Perf.Begin then
            StockPiler2.Perf.Begin("StatusTooltip.Build")
        end
        rows = BuildStatusTooltipRows(data)
        TrimStatusTooltipRows(rows, engineMax)
        if watchKey ~= "" then
            cache.byWatch[watchKey] = rows
        end
        if StockPiler2.Perf and StockPiler2.Perf.End then
            StockPiler2.Perf.End("StatusTooltip.Build")
        end
    end

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
            T("tip.watch.stock_simple")
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
        return
    end
    local target = tonumber(data.target) or 0
    local have = tonumber(data.potionHave) or 0
    local craftable = tonumber(data.craftable) or 0
    local contested = data.craftableShared == true or data.statusKey == "ready_to_craft_shared"
    local colorOk = RgbDef(COLOR_OK)
    local colorWarn = RgbDef(COLOR_WARN)
    local colorBlock = RgbDef(COLOR_BLOCK)
    local title = T("tip.watch.stock_no_target")
    local meta = T("tip.watch.stock_no_target_meta")
    local titleColor = nil
    local stockKind = "body"
    if target > 0 then
        if have >= target then
            title = T("tip.watch.stock_full")
            meta = T("tip.watch.stock_full_meta")
            titleColor = colorOk
            stockKind = "stocked"
        elseif (have + craftable) >= target then
            -- Yellow Stock = bags short, but Craftable reaches Target (brew to finish).
            -- Contested vs safe is Craftable yellow/green — not a different Stock color.
            title = T("tip.watch.stock_need_brew")
            meta = T("tip.watch.stock_need_brew_meta")
            titleColor = colorWarn
            stockKind = "warning"
            if contested then
                meta = meta .. T("tip.watch.stock_contested_extra")
            end
        else
            title = T("tip.watch.stock_need_mats")
            meta = T("tip.watch.stock_need_mats_meta")
            titleColor = colorBlock
            stockKind = "warning"
        end
    end
    local craftKind = "body"
    local craftColor = colorBlock
    if craftable > 0 then
        if contested then
            craftKind = "warning"
            craftColor = colorWarn
        else
            craftKind = "stocked"
            craftColor = colorOk
        end
    end
    local rows = {
        { text = title, kind = "title", color = titleColor },
        {
            text = T("tip.watch.stock_line", {
                have = tostring(have),
                target = tostring(target),
            }),
            kind = stockKind,
            color = titleColor,
        },
        {
            text = T("tip.watch.craftable_n", { n = tostring(craftable) }),
            kind = craftKind,
            color = craftColor,
        },
        { text = meta, kind = "meta" },
    }
    if target > 0 and have < target then
        local combined = have + craftable
        if combined >= target then
            rows[#rows + 1] = {
                text = T("tip.watch.covers_target"),
                kind = "meta",
            }
        else
            local short = target - combined
            rows[#rows + 1] = {
                text = T("tip.watch.short_after", { n = tostring(short) }),
                kind = "warning",
                color = colorBlock,
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
            T("tip.watch.stock_simple")
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
    end
end

local function ShowCraftableHeaderTooltip()
    if not StockPiler2RecipeTooltip or not StockPiler2RecipeTooltip.ShowColoredRows then
        Tooltips.CreateTextOnlyTooltip(
            SystemData.ActiveWindow.name,
            T("tip.watch.craftable_header")
        )
        Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
        return
    end
    StockPiler2RecipeTooltip.ShowColoredRows(SystemData.ActiveWindow.name, {
        { text = T("tip.watch.craftable_title"), kind = "title" },
        {
            text = T("tip.watch.craftable_meta1"),
            kind = "body",
        },
        {
            text = T("tip.watch.craftable_meta2"),
            kind = "meta",
        },
        {
            text = T("tip.watch.craftable_meta3"),
            kind = "meta",
        },
    }, Tooltips.ANCHOR_WINDOW_TOP)
end

local function ShowCraftableRowTooltip(data)
    if not StockPiler2RecipeTooltip or not StockPiler2RecipeTooltip.ShowColoredRows then
        return
    end
    local contested = data.craftableShared == true
    local colorOk = RgbDef(COLOR_OK)
    local colorWarn = RgbDef(COLOR_WARN)
    local colorBlock = RgbDef(COLOR_BLOCK)
    local rows = {
        { text = T("tip.watch.craftable_title"), kind = "title" },
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
    local countKind = "body"
    local countColor = colorBlock
    if craftable > 0 then
        if contested then
            countKind = "warning"
            countColor = colorWarn
        else
            countKind = "stocked"
            countColor = colorOk
        end
    end
    if craftable > 0 or (crafts and crafts > 0) then
        local yield = tonumber(data.recipeYield)
        if (not yield or yield <= 0) and RS and RS.RecipeOutputYield and type(recipe) == "table" then
            yield = RS.RecipeOutputYield(recipe, uid)
        end
        local nStr = tostring(math.floor((craftable or 0) + 0.5))
        local line
        if crafts and crafts > 0 and yield and yield > 0 then
            line = T("tip.watch.best_case_detail", {
                n = nStr,
                crafts = tostring(crafts),
                yield = FormatTooltipNumber(yield),
            })
        else
            line = T("tip.watch.best_case", { n = nStr })
        end
        rows[#rows + 1] = { text = line, kind = countKind, color = countColor }
    else
        rows[#rows + 1] = {
            text = T("tip.watch.no_crafts"),
            kind = "warning",
            color = colorBlock,
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
        local rateLine
        if attempts > 0 then
            rateLine = T("tip.watch.success_rate_n", {
                pct = tostring(pct),
                ok = tostring(successes),
                att = tostring(attempts),
            })
        else
            rateLine = T("tip.watch.success_rate", { pct = tostring(pct) })
        end
        rows[#rows + 1] = {
            text = rateLine,
            kind = rate < 0.5 and "warning" or "meta",
        }
        if expected ~= nil and craftable > 0 then
            rows[#rows + 1] = {
                text = T("tip.watch.expected_bottles", { n = FormatTooltipNumber(expected) }),
                kind = rate < 0.5 and "warning" or "body",
            }
        end
        if RS and RS.FormatApoSkillUpLine and type(recipe) == "table" then
            local apoLine = RS.FormatApoSkillUpLine(recipe)
            if apoLine and apoLine ~= L"" then
                rows[#rows + 1] = { text = apoLine, kind = "meta" }
            end
        end
    else
        rows[#rows + 1] = {
            text = T("tip.watch.no_rate_yet"),
            kind = "meta",
        }
        rows[#rows + 1] = {
            text = T("tip.watch.rarities_note"),
            kind = "meta",
        }
    end

    if craftable <= 0 then
        rows[#rows + 1] = {
            text = T("tip.watch.craftable_red"),
            kind = "warning",
            color = colorBlock,
        }
    elseif contested then
        rows[#rows + 1] = {
            text = T("tip.watch.craftable_yellow"),
            kind = "warning",
            color = colorWarn,
        }
        rows[#rows + 1] = {
            text = T("tip.watch.craftable_yellow_autogrow"),
            kind = "meta",
        }
    else
        rows[#rows + 1] = {
            text = T("tip.watch.craftable_green"),
            kind = "meta",
            color = colorOk,
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
        T("tip.watch.target_chip")
    )
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2TabWatch.OnMouseOverRowAutoGrow()
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("tip.watch.row_autogrow"))
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
    Tooltips.CreateTextOnlyTooltip(SystemData.ActiveWindow.name, T("tip.watch.row_brew"))
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_TOP)
end

function StockPiler2TabWatch.OnMouseOverCraftableHeader()
    ShowCraftableHeaderTooltip()
end

function StockPiler2TabWatch.OnCraftableHeaderClick()
end
