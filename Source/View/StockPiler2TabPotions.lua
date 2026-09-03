----------------------------------------------------------------
-- StockPiler2TabPotions - potion stock targets (watch / min / filters)
----------------------------------------------------------------

StockPiler2TabPotions = {}
StockPiler2TabPotions.listData = {}
StockPiler2TabPotions.displayOrder = {}

local ICON_SCALE = 0.34

local SORT_IDS = {
    [1] = "name",
    [2] = "effect",
    [3] = "power",
    [4] = "stability",
    [5] = "superCrit",
    [6] = "yield",
    [7] = "have",
    [8] = "watch",
}

local SORT_HEADERS = {
    watch = "SP2TabPotionsSortWatch",
    name = "SP2TabPotionsSortName",
    effect = "SP2TabPotionsSortEffect",
    power = "SP2TabPotionsSortPower",
    stability = "SP2TabPotionsSortStability",
    superCrit = "SP2TabPotionsSortSuperCrit",
    yield = "SP2TabPotionsSortYield",
    have = "SP2TabPotionsSortHave",
}

local SORT_HEADER_LABELS = {
    name = L"Name",
    effect = L"Effect",
    power = L"Power",
    stability = L"Stability",
    superCrit = L"Super-Crit",
    yield = L"Yield",
    have = L"Stock",
}

local EFFECT_CYCLE = {
    "",
    "str", "int", "wp", "bs", "tou", "armor", "absorb", "heal", "hot", "ap",
    "hytoucrit", "hystrmelee", "hywillheal", "hystrheal", "hyintmcrit", "hyaccrcrit",
    "hywoumelee", "hywoucrit", "hywoumcrit", "hywourcrit", "hywouheal", "hywoustr",
    "hyresist", "hywouarmpen", "hywouinit", "hytounocrit", "hyhpregencritdmg", "hywsarmpen",
}

local EFFECT_LABELS = {
    str = L"Str",
    int = L"Int",
    wp = L"WP",
    bs = L"BS",
    tou = L"Tou",
    armor = L"Armor",
    absorb = L"Absorb",
    heal = L"Heal",
    hot = L"HoT",
    ap = L"AP",
    hytoucrit = L"T+MC",
    hystrmelee = L"S+Melee",
    hywillheal = L"WP+Heal",
    hystrheal = L"S+Heal",
    hyintmcrit = L"I+MagC",
    hyaccrcrit = L"BS+RC",
    hywoumelee = L"W+Melee",
    hywoucrit = L"W+MC",
    hywoumcrit = L"W+MagC",
    hywourcrit = L"W+RC",
    hywouheal = L"W+Heal",
    hywoustr = L"W+Str",
    hyresist = L"HyResist",
    hywouarmpen = L"W+AP",
    hywouinit = L"W+Init",
    hytounocrit = L"T-Crit",
    hyhpregencritdmg = L"HoT-CD",
    hywsarmpen = L"WS+AP",
}

local function ToNarrow(text)
    return StockPiler2.Persistence.ToNarrow(text)
end

local function GetSettings()
    if StockPiler2.Persistence.EnsureSettings then
        return StockPiler2.Persistence.EnsureSettings()
    end
    return StockPiler2.Settings
end

local function ResolveEffectKey(entry, itemData)
    if entry and entry.effectKey then
        return entry.effectKey
    end
    if itemData and StockPiler2.Classify and StockPiler2.Classify.GetEffectKey then
        return StockPiler2.Classify.GetEffectKey(itemData)
    end
    return nil
end

local function EffectTextForRow(effectKey, _catalogEffect)
    if type(effectKey) ~= "string" or effectKey == "" then
        return L""
    end
    if EFFECT_LABELS[effectKey] then
        return EFFECT_LABELS[effectKey]
    end
    -- Never blank a known key (hybrids / future ids).
    return towstring(string.upper(effectKey))
end

local function ResolveTooltipItemData(entry, itemData)
    if StockPiler2.Inventory and StockPiler2.Inventory.ResolveTooltipItemData then
        return StockPiler2.Inventory.ResolveTooltipItemData(entry, itemData) or itemData
    end
    return itemData
end

local function ApplyPotionStats(row, entry, itemData)
    local rankText = L"-"
    local buffText = L"-"
    local durationText = L"-"
    row.rankNum = 0
    row.buffNum = 0
    row.durationSec = 0

    if StockPiler2.Classify and StockPiler2.Classify.GetPotionStats then
        local minRank, buffValue, durationSec, instant = StockPiler2.Classify.GetPotionStats(itemData, entry)
        row.rankNum = tonumber(minRank) or 0
        row.buffNum = tonumber(buffValue) or 0
        row.durationSec = tonumber(durationSec) or 0
        if minRank and minRank > 0 then
            rankText = towstring(tostring(minRank))
        end
        if buffValue and buffValue > 0 then
            buffText = towstring(tostring(buffValue))
        end
        if instant then
            durationText = L"Inst"
        elseif durationSec and durationSec > 0 and StockPiler2.Classify.FormatDuration then
            durationText = StockPiler2.Classify.FormatDuration(durationSec)
            if durationText == L"" then
                durationText = L"-"
            end
        end
    end

    row.rankText = rankText
    row.buffText = buffText
    row.durationText = durationText
end

local function BuildRecipeDataForPotion(potionKey, potionName, recipe, potionLevel, potionUid)
    if type(recipe) ~= "table" then
        return nil
    end
    local uid = tonumber(potionUid) or tonumber(recipe.outputUid) or tonumber(recipe.activeOutcomeUid) or 0
    local RS = StockPiler2.RecipeSpec
    local attempts = tonumber(recipe.brewAttempts) or 0
    local successes = tonumber(recipe.brewSuccesses) or 0
    local successRate = nil
    local yieldSamples = tonumber(recipe.yieldSamples) or 0
    local yieldProductSum = tonumber(recipe.yieldProductSum) or 0
    if RS and RS.OutcomeSuccessRate then
        local rate, ok, att = RS.OutcomeSuccessRate(recipe, uid)
        successRate = rate
        if att and att > 0 then
            attempts = att
        end
        if ok ~= nil then
            successes = ok
        end
    elseif RS and RS.RecipeSuccessRate then
        successRate = RS.RecipeSuccessRate(recipe)
    end
    local oc = RS and RS.OutcomeForPotion and RS.OutcomeForPotion(recipe, uid) or nil
    if type(oc) == "table" then
        local ocOk = tonumber(oc.successes) or 0
        local ocQty = tonumber(oc.qtySum) or 0
        if ocOk > 0 then
            yieldSamples = ocOk
            yieldProductSum = ocQty
        end
    end
    local recipeYield = 0
    if RS and RS.RecipeOutputYield then
        recipeYield = RS.RecipeOutputYield(recipe, uid) or 0
    else
        recipeYield = tonumber(recipe.recipeYield) or 0
    end
    return {
        name = potionName,
        potionLevel = tonumber(potionLevel) or 0,
        potionUid = uid,
        recipeSpecKey = recipe.recipeSpecKey,
        recipeYield = recipeYield,
        crafts = tonumber(recipe.crafts) or 0,
        brewAttempts = attempts,
        brewSuccesses = successes,
        brewCrits = tonumber(recipe.brewCrits) or 0,
        brewSuperCrits = tonumber(recipe.brewSuperCrits) or 0,
        brewFailures = tonumber(recipe.brewFailures) or 0,
        brewVolatiles = tonumber(recipe.brewVolatiles) or 0,
        yieldProductSum = yieldProductSum,
        yieldSamples = yieldSamples,
        successRate = successRate,
        materials = recipe.slots or {},
    }
end

local function MatchesNameFilter(name, filter)
    if filter == nil or filter == "" then
        return true
    end
    return string.find(string.lower(ToNarrow(name)), string.lower(filter), 1, true) ~= nil
end

local function MatchesEffectFilter(effectKey, filter)
    if filter == nil or filter == "" then
        return true
    end
    return effectKey == filter
end

local function ResolvePotionItemData(potionKey, uid, existing)
    if StockPiler2.Inventory and StockPiler2.Inventory.ResolvePotionItemData then
        return StockPiler2.Inventory.ResolvePotionItemData(potionKey, uid, existing)
    end
    return existing
end

local function PassesFilters(row, nameFilter, effectFilter)
    if not MatchesNameFilter(row.name, nameFilter)
        and not MatchesNameFilter(row.baseName, nameFilter)
        and not MatchesNameFilter(row.recipeLabel, nameFilter)
    then
        return false
    end
    return MatchesEffectFilter(row.effectKey, effectFilter)
end

local function CompareName(a, b)
    local na = string.lower(ToNarrow(a.baseName or a.name))
    local nb = string.lower(ToNarrow(b.baseName or b.name))
    if na == nb then
        local la = string.lower(ToNarrow(a.recipeLabel))
        local lb = string.lower(ToNarrow(b.recipeLabel))
        if la ~= lb then
            return la < lb
        end
        return ToNarrow(a.id) < ToNarrow(b.id)
    end
    return na < nb
end

local function FormatSignedStat(value)
    value = tonumber(value) or 0
    if value > 0 then
        return towstring("+" .. tostring(value))
    end
    return towstring(tostring(value))
end

local function FormatPercentStat(value)
    value = tonumber(value) or 0
    if value == 0 then
        return L"-"
    end
    return towstring(tostring(value) .. "%")
end

local function FormatYieldStat(value)
    value = tonumber(value) or 0
    if value <= 0 then
        return L"-"
    end
    local rounded = math.floor(value + 0.5)
    if math.abs(value - rounded) < 0.05 then
        return towstring(tostring(rounded))
    end
    return towstring(string.format("%.1f", value))
end

local function CompareRows(a, b, column, ascending)
    local function finish(lt)
        if lt then
            return ascending
        end
        return not ascending
    end

    if column == "name" then
        local na = string.lower(ToNarrow(a.name))
        local nb = string.lower(ToNarrow(b.name))
        if na == nb then
            return CompareName(a, b)
        end
        return finish(na < nb)
    elseif column == "effect" then
        local ea = ToNarrow(a.effectText)
        local eb = ToNarrow(b.effectText)
        if ea == eb then
            return CompareName(a, b)
        end
        return finish(ea < eb)
    elseif column == "power" then
        local pa = a.powerNum or 0
        local pb = b.powerNum or 0
        if pa == pb then
            return CompareName(a, b)
        end
        return finish(pa < pb)
    elseif column == "stability" then
        local sa = a.stabilityNum or 0
        local sb = b.stabilityNum or 0
        if sa == sb then
            return CompareName(a, b)
        end
        return finish(sa < sb)
    elseif column == "superCrit" then
        local ca = a.superCritNum or 0
        local cb = b.superCritNum or 0
        if ca == cb then
            return CompareName(a, b)
        end
        return finish(ca < cb)
    elseif column == "yield" then
        local ya = a.yieldNum or 0
        local yb = b.yieldNum or 0
        if ya == yb then
            return CompareName(a, b)
        end
        return finish(ya < yb)
    elseif column == "have" then
        local ha = a.have or 0
        local hb = b.have or 0
        if ha == hb then
            return CompareName(a, b)
        end
        return finish(ha < hb)
    elseif column == "watch" then
        local wa = a.watched == true
        local wb = b.watched == true
        if wa == wb then
            return CompareName(a, b)
        end
        return finish(wa and not wb)
    end
    return CompareName(a, b)
end

local function SortRows(rows)
    local s = GetSettings()
    local column = s.potionSortColumn or "name"
    local ascending = s.potionSortAscending ~= false
    table.sort(rows, function(a, b)
        return CompareRows(a, b, column, ascending)
    end)
end

local function SyncEffectComboSelection()
    local w = "SP2TabPotionsEffectCombo"
    if not DoesWindowExist(w) then
        return
    end
    local cur = (GetSettings().potionEffectFilter) or ""
    local selected = 1
    for i = 1, #EFFECT_CYCLE do
        if EFFECT_CYCLE[i] == cur then
            selected = i
            break
        end
    end
    ComboBoxSetSelectedMenuItem(w, selected)
end

local function InitEffectCombo()
    local w = "SP2TabPotionsEffectCombo"
    if not DoesWindowExist(w) then
        return
    end
    ComboBoxClearMenuItems(w)
    ComboBoxAddMenuItem(w, L"All effects")
    for i = 2, #EFFECT_CYCLE do
        local key = EFFECT_CYCLE[i]
        ComboBoxAddMenuItem(w, EFFECT_LABELS[key])
    end
    SyncEffectComboSelection()
end

local function UpdateSortHeaderLabels()
    for key, win in pairs(SORT_HEADERS) do
        if DoesWindowExist(win) and SORT_HEADER_LABELS[key] then
            ButtonSetText(win, SORT_HEADER_LABELS[key])
        end
    end
    if DoesWindowExist("SP2TabPotionsSortRecipe") then
        ButtonSetText("SP2TabPotionsSortRecipe", L"Recipe")
    end
    if DoesWindowExist("SP2TabPotionsSortForget") then
        ButtonSetText("SP2TabPotionsSortForget", L"Forget")
    end
end

local function UpdateSortHeaders()
    UpdateSortHeaderLabels()
    local s = GetSettings()
    local col = s.potionSortColumn or "name"
    local asc = s.potionSortAscending ~= false
    for key, win in pairs(SORT_HEADERS) do
        if DoesWindowExist(win) then
            local up = win .. "UpArrow"
            local down = win .. "DownArrow"
            if key == col then
                WindowSetShowing(up, asc)
                WindowSetShowing(down, not asc)
            else
                WindowSetShowing(up, false)
                WindowSetShowing(down, false)
            end
        end
    end
end

local function UpdateKnownRecipeFilterCheckbox()
    local s = GetSettings()
    if DoesWindowExist("SP2TabPotionsFilterKnownRecipe") then
        ButtonSetCheckButtonFlag("SP2TabPotionsFilterKnownRecipe", true)
        ButtonSetPressedFlag("SP2TabPotionsFilterKnownRecipe", s.potionKnownRecipeOnly == true)
    end
end

local function BuildVisibleList()
    local s = GetSettings()
    if type(s) ~= "table" then
        return
    end
    local nameFilter = s.potionNameFilter or ""
    local effectFilter = s.potionEffectFilter or ""
    local rows = {}

    if StockPiler2.Inventory and StockPiler2.Inventory.RefreshAllIfNeeded then
        StockPiler2.Inventory.RefreshAllIfNeeded()
    end

    local RSpec = StockPiler2.RecipeSpec
    local Catalog = StockPiler2.Catalog
    if RSpec and RSpec.MigrateWatchesToPotionRecipeKeys then
        RSpec.MigrateWatchesToPotionRecipeKeys()
    end
    local potions = Catalog and Catalog.ListPotionRecipeEntries and Catalog.ListPotionRecipeEntries()
        or (RSpec and RSpec.GetKnownPotionList and RSpec.GetKnownPotionList())
        or {}

    for i = 1, #potions do
        local potion = potions[i]
        local potionKey = potion.potionRecipeKey or potion.potionKey
        local potionBase = potion.potion or potion
        local watch = Catalog and Catalog.EnsureWatch and Catalog.EnsureWatch(potionKey) or { enabled = false, targetStock = 40 }
        local watched = watch.enabled == true
        local have = Catalog and Catalog.PotionHaveCombined and Catalog.PotionHaveCombined(potionBase) or 0
        local min = tonumber(watch.targetStock) or 0
        local uid = tonumber(potion.outputUid or potionBase.outputUid) or 0
        local entry = {
            id = potionKey,
            uniqueID = uid,
            uniqueIDs = { uid },
        }
        local itemData = ResolvePotionItemData(potion.potionKey or potionKey, uid, nil)
        local effectKey = potion.effectKey or potionBase.effectKey
        if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.ResolveEffectKeyForPotion then
            effectKey = StockPiler2.RecipeSpec.ResolveEffectKeyForPotion(potionBase, {
                recipeKey = potion.recipeSpecKey,
                itemData = itemData,
            }) or effectKey
        elseif not effectKey and itemData and StockPiler2.Classify then
            effectKey = StockPiler2.Classify.GetEffectKey(itemData)
        end
        if type(effectKey) == "string" and effectKey ~= "" then
            if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.NormalizeEffectKeyForUi then
                effectKey = StockPiler2.RecipeSpec.NormalizeEffectKeyForUi(effectKey) or effectKey
            end
            if type(potionBase) == "table" then
                potionBase.effectKey = effectKey
            end
            if type(potion) == "table" then
                potion.effectKey = effectKey
            end
        end
        local recipeLabel = potion.recipeLabel or L""
        local baseName = potion.name or potionBase.name or towstring(tostring(uid))
        local powerNum = tonumber(potion.power) or 0
        local stabilityNum = tonumber(potion.stability) or 0
        local superCritNum = tonumber(potion.superCrit) or 0
        local yieldNum = tonumber(potion.yield) or 0
        local row = {
            id = potionKey,
            potionKey = potionKey,
            potionBaseKey = potion.potionKey or potionBase.potionKey,
            recipeSpecKey = potion.recipeSpecKey,
            recipeLabel = recipeLabel,
            entry = entry,
            name = baseName,
            baseName = baseName,
            effectKey = effectKey,
            effectText = EffectTextForRow(effectKey, nil),
            powerNum = powerNum,
            powerText = FormatSignedStat(powerNum),
            stabilityNum = stabilityNum,
            stabilityText = FormatSignedStat(stabilityNum),
            superCritNum = superCritNum,
            superCritText = FormatPercentStat(superCritNum),
            yieldNum = yieldNum,
            yieldText = FormatYieldStat(yieldNum),
            have = have,
            haveText = towstring(tostring(have)),
            min = min,
            minText = towstring(tostring(min)),
            watched = watched,
            iconNum = tonumber(potion.iconNum or potionBase.iconNum) or 0,
            itemData = itemData,
            uniqueID = uid,
            observed = true,
        }
        ApplyPotionStats(row, entry, itemData)
        local recipe = nil
        if RSpec and RSpec.RecipeSpecForPotion then
            recipe = RSpec.RecipeSpecForPotion(potionKey)
        end
        row.recipeSpecKey = (recipe and recipe.recipeSpecKey) or potion.recipeSpecKey
        if recipe and RSpec.RecipeFingerprintStats then
            local stats = RSpec.RecipeFingerprintStats(recipe, uid)
            row.powerNum = stats.power
            row.powerText = FormatSignedStat(stats.power)
            row.stabilityNum = stats.stability
            row.stabilityText = FormatSignedStat(stats.stability)
            row.superCritNum = stats.superCrit
            row.superCritText = FormatPercentStat(stats.superCrit)
            row.yieldNum = stats.yield
            row.yieldText = FormatYieldStat(stats.yield)
        end
        row.recipeData = BuildRecipeDataForPotion(potionKey, baseName, recipe, row.rankNum, uid)
        row.hasRecipe = row.recipeData ~= nil
        if PassesFilters(row, nameFilter, effectFilter) then
            rows[#rows + 1] = row
        end
    end

    SortRows(rows)

    local order = {}
    for i = 1, #rows do
        order[i] = i
    end
    StockPiler2TabPotions.listData = rows
    StockPiler2TabPotions.displayOrder = order
end

local function UpdateKnownRecipeFilterCheckbox()
    local s = GetSettings()
    if DoesWindowExist("SP2TabPotionsFilterKnownRecipe") then
        ButtonSetCheckButtonFlag("SP2TabPotionsFilterKnownRecipe", true)
        ButtonSetPressedFlag("SP2TabPotionsFilterKnownRecipe", s.potionKnownRecipeOnly == true)
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

function StockPiler2TabPotions.Initialize()
    LabelSetText("SP2TabPotionsBannerTitle", L"Known potions")
    LabelSetText(
        "SP2TabPotionsBannerText",
        L"Recipes are learned by brewing manually. One row per recipe; columns are fingerprint stats (effect / rank / buff / duration in the icon tip)."
    )
    LabelSetText("SP2TabPotionsSearchLabel", L"Search:")
    LabelSetText("SP2TabPotionsEffectLabel", L"Effect:")
    UpdateSortHeaderLabels()

    local s = GetSettings()
    if DoesWindowExist("SP2TabPotionsSearchBox") then
        TextEditBoxSetText("SP2TabPotionsSearchBox", towstring(s.potionNameFilter or ""))
    end
    if DoesWindowExist("SP2TabPotionsFilterKnownRecipe") then
        WindowSetShowing("SP2TabPotionsFilterKnownRecipe", false)
    end
    if DoesWindowExist("SP2TabPotionsFilterKnownRecipeLabel") then
        WindowSetShowing("SP2TabPotionsFilterKnownRecipeLabel", false)
    end
    InitEffectCombo()
    UpdateSortHeaders()
end

function StockPiler2TabPotions.Refresh()
    if not DoesWindowExist("SP2TabPotions") then
        return
    end
    SyncEffectComboSelection()
    UpdateSortHeaders()
    BuildVisibleList()

    if DoesWindowExist("SP2TabPotionsList") then
        ListBoxSetDisplayOrder("SP2TabPotionsList", {})
        ListBoxSetDisplayOrder("SP2TabPotionsList", StockPiler2TabPotions.displayOrder)
        StockPiler2TabPotions.UpdateRows()
    end
end

function StockPiler2TabPotions.UpdateRows()
    if SP2TabPotionsList.PopulatorIndices == nil then
        return
    end
    for rowIndex, dataIndex in ipairs(SP2TabPotionsList.PopulatorIndices) do
        local data = StockPiler2TabPotions.listData[dataIndex]
        if data then
            local rowName = "SP2TabPotionsListRow" .. rowIndex
            DefaultColor.SetListRowTint(rowName .. "Background", rowIndex, false)
            ButtonSetCheckButtonFlag(rowName .. "Watch", true)
            ButtonSetPressedFlag(rowName .. "Watch", data.watched == true)
            SetIconTexture(rowName .. "Icon", data.iconNum)

            LabelSetText(rowName .. "Name", data.name or L"")
            LabelSetText(rowName .. "Effect", data.effectText or L"")
            LabelSetText(rowName .. "Power", data.powerText or L"0")
            LabelSetText(rowName .. "Stability", data.stabilityText or L"0")
            LabelSetText(rowName .. "SuperCrit", data.superCritText or L"-")
            LabelSetText(rowName .. "Yield", data.yieldText or L"-")
            LabelSetText(rowName .. "Have", data.haveText or towstring(tostring(data.have or 0)))
            LabelSetTextColor(rowName .. "Have", 255, 255, 255)

            local recipeWin = rowName .. "Recipe"
            if DoesWindowExist(recipeWin) then
                WindowSetShowing(recipeWin, data.hasRecipe == true)
            end

            local forgetWin = rowName .. "Forget"
            if DoesWindowExist(forgetWin) then
                WindowSetShowing(forgetWin, data.hasRecipe == true)
            end
        end
    end
end

function StockPiler2TabPotions.OnToggleKnownRecipeFilter()
    local s = GetSettings()
    s.potionKnownRecipeOnly = ButtonGetPressedFlag(SystemData.ActiveWindow.name) == true
    StockPiler2TabPotions.Refresh()
end

function StockPiler2TabPotions.OnSearchChanged()
    local text = TextEditBoxGetText("SP2TabPotionsSearchBox")
    GetSettings().potionNameFilter = ToNarrow(text)
    StockPiler2TabPotions.Refresh()
end

function StockPiler2TabPotions.OnEffectComboChanged()
    local idx = tonumber(ComboBoxGetSelectedMenuItem("SP2TabPotionsEffectCombo")) or 1
    local newFilter = EFFECT_CYCLE[idx] or ""
    local s = GetSettings()
    if s.potionEffectFilter == newFilter then
        return
    end
    s.potionEffectFilter = newFilter
    StockPiler2TabPotions.Refresh()
end

function StockPiler2TabPotions.OnSortColumn()
    local id = WindowGetId(SystemData.ActiveWindow.name)
    local col = SORT_IDS[id]
    if not col then
        return
    end
    local s = GetSettings()
    if s.potionSortColumn == col then
        s.potionSortAscending = not (s.potionSortAscending ~= false)
    else
        s.potionSortColumn = col
        s.potionSortAscending = true
    end
    StockPiler2TabPotions.Refresh()
end

local function RowDataFromActiveChild()
    local rowWindow = WindowGetParent(SystemData.ActiveWindow.name)
    local rowIndex = WindowGetId(rowWindow)
    local dataIndex = ListBoxGetDataIndex("SP2TabPotionsList", rowIndex)
    return StockPiler2TabPotions.listData[dataIndex]
end

function StockPiler2TabPotions.OnToggleWatch()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local s = GetSettings()
    local potionKey = data.potionKey or data.id
    if not (StockPiler2.Catalog and StockPiler2.Catalog.EnsureWatch) then
        return
    end
    local watch = StockPiler2.Catalog.EnsureWatch(potionKey)
    watch.enabled = ButtonGetPressedFlag(SystemData.ActiveWindow.name) == true
    if watch.autoGrow == nil then
        watch.autoGrow = true
    end
    StockPiler2.Watch.BumpGen()
    if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Invalidate then
        StockPiler2.PlanSnapshot.Invalidate()
    end
    if StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("settings", string.format(
            "watch enabled=%s potion=%s key=%s target=%d autoGrow=%s",
            tostring(watch.enabled == true),
            StockPiler2.Persistence.ToNarrow(data.name or data.id or "?"),
            tostring(potionKey),
            tonumber(watch.targetStock) or 0,
            tostring(watch.autoGrow ~= false)
        ))
    end
    if StockPiler2.Grow and StockPiler2.Grow.OnDemandChanged then
        StockPiler2.Grow.OnDemandChanged()
    elseif StockPiler2.Grow and StockPiler2.Grow.InvalidatePlantQueue then
        StockPiler2.Grow.InvalidatePlantQueue({ force = true })
    end
    StockPiler2TabPotions.Refresh()
    if StockPiler2TabWatch and StockPiler2TabWatch.Refresh then
        StockPiler2TabWatch.Refresh()
    end
end

local function ShowItemOrTextTooltip(itemData, title, line2, line3)
    if StockPiler2.Inventory and StockPiler2.Inventory.ShowItemTooltip then
        if StockPiler2.Inventory.ShowItemTooltip(itemData, SystemData.ActiveWindow.name) then
            return
        end
    elseif itemData ~= nil and type(Tooltips.CreateItemTooltip) == "function" then
        local ok = StockPiler2.Debug.TryCall(
            "Tooltips.CreateItemTooltip", Tooltips.CreateItemTooltip,
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
    Tooltips.SetTooltipText(1, 1, title or L"Item")
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

function StockPiler2TabPotions.OnMouseOverIcon()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local itemData = ResolvePotionItemData(data.potionKey, data.uniqueID, data.itemData)
    if itemData then
        data.itemData = itemData
    end
    local iLevel = 0
    if type(itemData) == "table" then
        iLevel = tonumber(itemData.iLevel) or tonumber(itemData.level) or 0
    end
    if StockPiler2RecipeTooltip and StockPiler2RecipeTooltip.ShowPotionIconTooltip then
        StockPiler2RecipeTooltip.ShowPotionIconTooltip(SystemData.ActiveWindow.name, {
            name = data.name or L"Potion",
            uniqueID = data.uniqueID,
            itemData = itemData,
            iLevel = iLevel,
            effectKey = data.effectKey,
            rankNum = data.rankNum,
            buffNum = data.buffNum,
            durationSec = data.durationSec,
        })
        return
    end
    ShowItemOrTextTooltip(itemData, data.name or L"Potion", nil, nil)
end

function StockPiler2TabPotions.OnMouseOverRecipe()
    local data = RowDataFromActiveChild()
    if not data or not data.recipeData then
        return
    end
    if StockPiler2RecipeTooltip and StockPiler2RecipeTooltip.ShowRecipeTooltip then
        StockPiler2RecipeTooltip.ShowRecipeTooltip(SystemData.ActiveWindow.name, data.recipeData)
    elseif StockPilerRecipeTooltip and StockPilerRecipeTooltip.ShowRecipeTooltip then
        StockPilerRecipeTooltip.ShowRecipeTooltip(SystemData.ActiveWindow.name, data.recipeData)
    end
end

function StockPiler2TabPotions.ConfirmForgetRecipe()
    local outputUid = StockPiler2TabPotions._pendingForgetOutputUid
    local recipeSpecKey = StockPiler2TabPotions._pendingForgetRecipeKey
    local compositeKey = StockPiler2TabPotions._pendingForgetKey
    local label = StockPiler2TabPotions._pendingForgetLabel or compositeKey or recipeSpecKey
    StockPiler2TabPotions._pendingForgetOutputUid = nil
    StockPiler2TabPotions._pendingForgetRecipeKey = nil
    StockPiler2TabPotions._pendingForgetKey = nil
    StockPiler2TabPotions._pendingForgetLabel = nil
    local forgot = false
    if StockPiler2.Catalog and StockPiler2.Catalog.ForgetPotionRecipeLink
        and tonumber(outputUid) and tonumber(outputUid) > 0
        and type(recipeSpecKey) == "string" and recipeSpecKey ~= ""
    then
        forgot = StockPiler2.Catalog.ForgetPotionRecipeLink(outputUid, recipeSpecKey) == true
    elseif compositeKey and compositeKey ~= "" and StockPiler2.Catalog and StockPiler2.Catalog.ForgetLearnedRecipeSpec then
        forgot = StockPiler2.Catalog.ForgetLearnedRecipeSpec(compositeKey) == true
    end
    if forgot then
        if StockPiler2.Ui.Print then
            StockPiler2.Ui.Print(L"Forgot learned potion recipe: " .. towstring(label))
        end
        if StockPiler2.Grow and StockPiler2.Grow.InvalidatePlantQueue then
            StockPiler2.Grow.InvalidatePlantQueue({ force = true })
        end
        StockPiler2TabPotions.Refresh()
        if StockPiler2TabWatch and StockPiler2TabWatch.Refresh then
            StockPiler2TabWatch.Refresh()
        end
    end
end

function StockPiler2TabPotions.OnForgetRow()
    local data = RowDataFromActiveChild()
    if not data then
        return
    end
    local outputUid = tonumber(data.uniqueID) or 0
    if outputUid <= 0 and type(data.entry) == "table" then
        outputUid = tonumber(data.entry.uniqueID) or 0
    end
    local recipeSpecKey = data.recipeSpecKey
    if (not recipeSpecKey or recipeSpecKey == "") and type(data.recipeData) == "table" then
        recipeSpecKey = data.recipeData.recipeSpecKey
    end
    local compositeKey = data.potionKey or data.id
    local RSpec = StockPiler2.RecipeSpec
    if RSpec and RSpec.ParsePotionRecipeKey and type(compositeKey) == "string" then
        local parsed = RSpec.ParsePotionRecipeKey(compositeKey)
        if type(parsed) == "table" and parsed.isComposite == true then
            outputUid = tonumber(parsed.outputUid) or outputUid
            recipeSpecKey = parsed.recipeSpecKey or recipeSpecKey
        end
    end
    if outputUid <= 0 or type(recipeSpecKey) ~= "string" or recipeSpecKey == "" then
        return
    end
    local label = ToNarrow(data.baseName or data.name) or tostring(outputUid)
    local statsHint = ToNarrow(data.recipeLabel)
    if statsHint and statsHint ~= "" then
        label = label .. " (" .. statsHint .. ")"
    end
    StockPiler2TabPotions._pendingForgetOutputUid = outputUid
    StockPiler2TabPotions._pendingForgetRecipeKey = recipeSpecKey
    StockPiler2TabPotions._pendingForgetKey = RSpec and RSpec.PotionRecipeKey
        and RSpec.PotionRecipeKey(outputUid, recipeSpecKey) or compositeKey
    StockPiler2TabPotions._pendingForgetLabel = label
    if type(DialogManager) == "table" and type(DialogManager.MakeTwoButtonDialog) == "function" then
        local yes = GetString and GetString(StringTables.Default.LABEL_YES) or L"Yes"
        local no = GetString and GetString(StringTables.Default.LABEL_NO) or L"No"
        DialogManager.MakeTwoButtonDialog(
            L"Forget this learned potion recipe?\n" .. towstring(label),
            yes,
            StockPiler2TabPotions.ConfirmForgetRecipe,
            no,
            nil
        )
        return
    end
    StockPiler2TabPotions.ConfirmForgetRecipe()
end

function StockPiler2TabPotions.OnMouseOverForget()
    Tooltips.CreateTextOnlyTooltip(
        SystemData.ActiveWindow.name,
        L"Forget this potion recipe path. Other outcomes or recipes for the same cauldron loadout are kept when still linked."
    )
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end
