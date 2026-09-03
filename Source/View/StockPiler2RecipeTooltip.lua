----------------------------------------------------------------
-- StockPiler2RecipeTooltip - shared recipe tooltip for Potions tab
----------------------------------------------------------------

StockPiler2RecipeTooltip = {}

local RECIPE_TOOLTIP_SEP_LINE = L"----------------------------------------"
local RECIPE_TOOLTIP_MAX_ROWS = 24

StockPiler2RecipeTooltip.SEP_LINE = RECIPE_TOOLTIP_SEP_LINE

local function AppendRecipeSeparator(body)
    body[#body + 1] = { text = RECIPE_TOOLTIP_SEP_LINE, kind = "separator" }
end

function StockPiler2RecipeTooltip.AppendSeparator(rows)
    AppendRecipeSeparator(rows)
end

local function JoinTooltipParts(parts, sep)
    if #parts == 0 then
        return L""
    end
    local text = parts[1]
    for i = 2, #parts do
        text = text .. sep .. parts[i]
    end
    return text
end

local function CompactIngredientStatLines(rows)
    local i = 1
    while i <= #rows do
        if rows[i].kind == "ingredient" then
            i = i + 1
            local stats = {}
            while i <= #rows and rows[i].kind ~= "separator" and rows[i].kind ~= "ingredient" and rows[i].kind ~= "title" and rows[i].kind ~= "meta" do
                if rows[i].text and rows[i].text ~= L"" then
                    stats[#stats + 1] = rows[i]
                end
                table.remove(rows, i)
            end
            if #stats > 1 then
                local parts = {}
                for s = 1, #stats do
                    parts[s] = stats[s].text
                end
                table.insert(rows, i, {
                    text = JoinTooltipParts(parts, L"   "),
                    kind = stats[1].kind or "bonus",
                })
                i = i + 1
            elseif #stats == 1 then
                table.insert(rows, i, stats[1])
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return rows
end

local function RecipeTooltipColor(kind, role)
    if not Tooltips then
        return nil
    end
    if kind == "title" then
        return Tooltips.COLOR_HEADING
    end
    if kind == "meta" then
        return Tooltips.COLOR_EXTRA_TEXT_DEFAULT
    end
    if kind == "separator" then
        return Tooltips.COLOR_ITEM_DEFAULT_GRAY
    end
    -- Ingredient header: "150 Apothecary - Container"
    if kind == "ingredient" then
        return Tooltips.COLOR_ACTION
    end
    -- Stat / effect lines: same yellow as stock item tooltip bonuses (+10 Stability).
    if kind == "effect" or kind == "bonus" or kind == "positive" or kind == "negative" then
        return Tooltips.COLOR_ITEM_BONUS or Tooltips.COLOR_HEADING
    end
    if kind == "warning" then
        return Tooltips.COLOR_WARNING
    end
    if kind == "stocked" then
        return Tooltips.COLOR_ABILITY_STATE_READY or Tooltips.COLOR_HEADING
    end
    return Tooltips.COLOR_BODY
end

local function SetRecipeTooltipRowColor(row, color)
    if not color or not Tooltips then
        return
    end
    if Tooltips.SetTooltipColorDef then
        Tooltips.SetTooltipColorDef(row, 1, color)
    elseif Tooltips.SetTooltipColor then
        Tooltips.SetTooltipColor(row, 1, color.r or 255, color.g or 255, color.b or 255)
    end
end

local function ResolveRecipePotionLevel(data)
    local level = tonumber(data and data.potionLevel) or 0
    if level > 0 then
        return level
    end
    local uid = tonumber(data and data.potionUid) or 0
    if uid <= 0 then
        return 0
    end
    if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.PotionKeyFromUid then
        local potionKey = StockPiler2.RecipeSpec.PotionKeyFromUid(uid)
        local s = StockPiler2.EnsureSettings and StockPiler2.EnsureSettings() or StockPiler2.Settings
        local potion = s and (s.potions or s.knownPotions) and potionKey
            and (s.potions or s.knownPotions)[potionKey]
        if type(potion) == "table" and StockPiler2.Inventory then
            local entry = {
                id = potionKey,
                uniqueID = uid,
                uniqueIDs = { uid },
            }
            local itemData = nil
            if StockPiler2.Inventory.ResolveTooltipItemData then
                itemData = StockPiler2.Inventory.ResolveTooltipItemData(entry, nil)
            end
            if StockPiler2.Classify and StockPiler2.Classify.GetPotionStats then
                local minRank = StockPiler2.Classify.GetPotionStats(itemData, entry)
                level = tonumber(minRank) or 0
            end
        end
    end
    return level
end

local function MergeMetaRows(rows)
    local firstMeta, secondMeta
    for i = 1, #rows do
        if rows[i].kind == "meta" then
            if not firstMeta then
                firstMeta = i
            else
                secondMeta = i
                break
            end
        end
    end
    if firstMeta and secondMeta then
        rows[firstMeta].text = rows[firstMeta].text .. L"  " .. rows[secondMeta].text
        table.remove(rows, secondMeta)
    end
end

local function CompactRecipeTooltipRows(rows)
    CompactIngredientStatLines(rows)

    if #rows > RECIPE_TOOLTIP_MAX_ROWS then
        MergeMetaRows(rows)
    end

    while #rows > RECIPE_TOOLTIP_MAX_ROWS do
        local removed = false
        for i = #rows - 1, 1, -1 do
            if rows[i].kind == "bonus" and rows[i + 1] and rows[i + 1].kind == "bonus" then
                rows[i] = {
                    text = rows[i].text .. L"   " .. rows[i + 1].text,
                    kind = "bonus",
                }
                table.remove(rows, i + 1)
                removed = true
                break
            end
        end
        if not removed then
            for i = #rows, 1, -1 do
                if rows[i].kind == "separator" then
                    local prev = rows[i - 1]
                    local nextRow = rows[i + 1]
                    local prevIsStat = prev and (prev.kind == "bonus" or prev.kind == "effect"
                        or prev.kind == "positive" or prev.kind == "negative" or prev.kind == "ingredient")
                    local nextIsIngredient = nextRow and nextRow.kind == "ingredient"
                    -- Never drop the divider between two ingredients.
                    if not (prevIsStat and nextIsIngredient) then
                        table.remove(rows, i)
                        removed = true
                        break
                    end
                end
            end
        end
        if not removed then
            table.remove(rows, #rows)
        end
    end

    return rows
end

function StockPiler2RecipeTooltip.BuildRecipeTooltipLines(data)
    local rows = StockPiler2RecipeTooltip.BuildRecipeTooltipRows(data)
    local lines = {}
    for i = 1, #rows do
        lines[i] = rows[i].text
    end
    return lines
end

function StockPiler2RecipeTooltip.BuildRecipeTooltipRows(data)
    local body = {}
    if not data then
        return body
    end

    local potionName = data.name or L"Potion"
    body[#body + 1] = { text = L"Recipe - " .. potionName, kind = "title" }

    local level = ResolveRecipePotionLevel(data)
    if level > 0 then
        body[#body + 1] = { text = L"Level " .. towstring(tostring(level)), kind = "meta" }
    end

    local metaParts = {}
    local yield = tonumber(data.recipeYield) or 0
    local successes = tonumber(data.brewSuccesses) or 0
    local yieldSamples = tonumber(data.yieldSamples) or 0
    if yield > 0 and yieldSamples > 0 then
        local rounded = math.floor(yield * 10 + 0.5) / 10
        local yieldText
        if math.abs(rounded - math.floor(rounded + 0.5)) < 0.05 then
            yieldText = towstring(tostring(math.floor(rounded + 0.5)))
        else
            yieldText = towstring(string.format("%.1f", rounded))
        end
        metaParts[#metaParts + 1] = L"Yield: " .. yieldText .. L" per success"
    end
    local attempts = tonumber(data.brewAttempts) or 0
    local rate = tonumber(data.successRate)
    if attempts > 0 then
        if rate == nil then
            rate = successes / attempts
        end
        local pct = math.floor((rate or 0) * 100 + 0.5)
        metaParts[#metaParts + 1] = L"Success: " .. towstring(tostring(pct))
            .. L"% (" .. towstring(tostring(successes))
            .. L"/" .. towstring(tostring(attempts)) .. L")"
    elseif data.crafts and data.crafts > 0 then
        metaParts[#metaParts + 1] = L"Brewed " .. towstring(tostring(data.crafts)) .. L" time(s)"
    end
    if #metaParts == 1 then
        body[#body + 1] = { text = metaParts[1], kind = "meta" }
    elseif #metaParts >= 2 then
        body[#body + 1] = { text = metaParts[1] .. L"  " .. metaParts[2], kind = "meta" }
    end
    local mainKept = tonumber(data.brewCrits) or 0
    local crits = tonumber(data.brewSuperCrits) or 0
    local fails = tonumber(data.brewFailures) or 0
    local volatiles = tonumber(data.brewVolatiles) or 0
    if attempts > 0 and (mainKept > 0 or crits > 0 or fails > 0 or volatiles > 0) then
        local outcome = L"Crit: " .. towstring(tostring(crits))
            .. L"  Main kept: " .. towstring(tostring(mainKept))
            .. L"  Fail: " .. towstring(tostring(fails))
        if volatiles > 0 then
            outcome = outcome .. L"  Volatile: " .. towstring(tostring(volatiles))
        end
        -- Fold into last meta line so 5-slot recipes keep separators within the row budget.
        local last = body[#body]
        if last and last.kind == "meta" then
            last.text = last.text .. L"  " .. outcome
        else
            body[#body + 1] = { text = outcome, kind = "meta" }
        end
    end

    local materials = data.materials or {}
    local slotShown = 0
    for i = 1, #materials do
        local mat = materials[i]
        if type(mat) == "table" then
            local per = math.max(1, tonumber(mat.perCraft) or 1)
            local spec = mat.spec
            if type(spec) ~= "table" and StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.ResolveSlotSpec then
                spec = StockPiler2.RecipeSpec.ResolveSlotSpec(mat)
            end
            if type(spec) ~= "table" and mat.uid and StockPiler2.Items and StockPiler2.Items.ToSpec then
                spec = StockPiler2.Items.ToSpec(mat.uid)
            end
            for _n = 1, per do
                if slotShown > 0 then
                    AppendRecipeSeparator(body)
                end
                slotShown = slotShown + 1

                local slotRows
                if spec and StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.DescribeTooltipRows then
                    slotRows = StockPiler2.MaterialSpec.DescribeTooltipRows(spec, 1)
                else
                    local role = mat.role or "ingredient"
                    local matTitle = mat.name or mat.nameNarrow or role
                    if (not matTitle or matTitle == role) and mat.uid and StockPiler2.Items then
                        local row = StockPiler2.Items.Get(mat.uid)
                        if row then
                            matTitle = row.name or row.nameNarrow or matTitle
                        end
                    end
                    slotRows = {
                        {
                            text = towstring(tostring(role)) .. L": " .. towstring(tostring(matTitle)),
                            kind = "ingredient",
                            role = role,
                        },
                    }
                end
                for j = 1, #slotRows do
                    body[#body + 1] = slotRows[j]
                end
            end
        end
    end

    return CompactRecipeTooltipRows(body)
end

function StockPiler2RecipeTooltip.ShowRecipeTooltip(anchorWindow, data)
    local rows = StockPiler2RecipeTooltip.BuildRecipeTooltipRows(data)
    StockPiler2RecipeTooltip.ShowColoredRows(anchorWindow, rows, Tooltips.ANCHOR_WINDOW_RIGHT)
end

--- Shared colored text-only tooltip (Status / Craftable / Recipe use the same kinds).
--- rows: { { text = L"...", kind = "title"|"meta"|"body"|"ingredient"|"bonus"|"warning"|"stocked"|"separator", color? }, ... }
function StockPiler2RecipeTooltip.ShowColoredRows(anchorWindow, rows, anchor, maxRows)
    if type(rows) ~= "table" then
        rows = {}
    end
    if not Tooltips or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    Tooltips.CreateTextOnlyTooltip(anchorWindow)
    -- DefaultTooltip XML only defines Tooltips.NUM_ROWS (17) windows.
    local engineMax = tonumber(Tooltips.NUM_ROWS) or 17
    local limit = tonumber(maxRows) or RECIPE_TOOLTIP_MAX_ROWS
    if limit > engineMax then
        limit = engineMax
    end
    local rowCount = math.min(#rows, limit)
    for i = 1, rowCount do
        local entry = rows[i]
        if type(entry) ~= "table" then
            entry = { text = entry, kind = "body" }
        end
        Tooltips.SetTooltipText(i, 1, entry.text or L"", false)
        SetRecipeTooltipRowColor(i, entry.color or RecipeTooltipColor(entry.kind, entry.role))
    end
    for i = rowCount + 1, engineMax do
        Tooltips.SetTooltipText(i, 1, L"", false)
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_RIGHT)
end

function StockPiler2RecipeTooltip.ColorForKind(kind, role)
    return RecipeTooltipColor(kind, role)
end

local EFFECT_FULL_LABELS = {
    str = L"Strength",
    int = L"Intelligence",
    wp = L"Willpower",
    bs = L"Ballistic Skill",
    tou = L"Toughness",
    armor = L"Armor",
    absorb = L"Absorb",
    heal = L"Heal",
    hot = L"HoT",
    ap = L"Action Points",
}

--- Build placeholder rows when CreateItemTooltip cannot run (no Use-bonus in bags).
function StockPiler2RecipeTooltip.BuildPotionPlaceholderRows(summary)
    summary = type(summary) == "table" and summary or {}
    local rows = {
        { text = summary.name or L"Potion", kind = "title" },
        { text = L"Potion", kind = "meta" },
    }
    local iLevel = tonumber(summary.iLevel) or 0
    if iLevel <= 0 and type(summary.itemData) == "table" then
        iLevel = tonumber(summary.itemData.iLevel) or tonumber(summary.itemData.level) or 0
    end
    if iLevel > 0 then
        rows[#rows + 1] = {
            text = L"Item Level: " .. towstring(tostring(iLevel)),
            kind = "meta",
        }
    end
    local rank = tonumber(summary.rankNum) or 0
    if rank <= 0 then
        rank = iLevel
    end
    if rank > 0 then
        rows[#rows + 1] = {
            text = L"Minimum Rank: " .. towstring(tostring(rank)),
            kind = "body",
        }
    end
    local effectKey = summary.effectKey
    if type(effectKey) == "string" and effectKey ~= "" then
        local label = EFFECT_FULL_LABELS[effectKey] or towstring(effectKey)
        local buff = tonumber(summary.buffNum) or 0
        local durationSec = tonumber(summary.durationSec) or 0
        if buff > 0 and durationSec > 0 then
            local mins = math.floor(durationSec / 60)
            local durText = mins > 0 and (towstring(tostring(mins)) .. L" minutes")
                or (towstring(tostring(durationSec)) .. L" seconds")
            rows[#rows + 1] = {
                text = L"Use: Increases your "
                    .. label
                    .. L" by "
                    .. towstring(tostring(buff))
                    .. L" for "
                    .. durText
                    .. L".",
                kind = "positive",
            }
        else
            rows[#rows + 1] = {
                text = L"Effect: " .. label,
                kind = "positive",
            }
        end
    end
    local uid = tonumber(summary.uniqueID) or 0
    if uid > 0 then
        rows[#rows + 1] = {
            text = L"(" .. towstring(tostring(uid)) .. L")",
            kind = "meta",
        }
    end
    if summary.line2 and summary.line2 ~= L"" then
        rows[#rows + 1] = { text = summary.line2, kind = "meta" }
    end
    if summary.line3 and summary.line3 ~= L"" then
        rows[#rows + 1] = { text = summary.line3, kind = "meta" }
    end
    return rows
end

--- Full stock tip when possible; otherwise placeholder from stored/row summary.
function StockPiler2RecipeTooltip.ShowPotionIconTooltip(anchorWindow, summary)
    summary = type(summary) == "table" and summary or {}
    local itemData = summary.itemData
    if StockPiler2.Inventory and StockPiler2.Inventory.ShowItemTooltip then
        if StockPiler2.Inventory.ShowItemTooltip(itemData, anchorWindow, summary.line2) then
            return true
        end
    elseif type(itemData) == "table"
        and Tooltips
        and type(Tooltips.CreateItemTooltip) == "function"
        and StockPiler2.Inventory
        and StockPiler2.Inventory.ItemDataHasUseBonus
        and StockPiler2.Inventory.ItemDataHasUseBonus(itemData)
    then
        local ok = StockPiler2.TryCall(
            "Tooltips.CreateItemTooltip",
            Tooltips.CreateItemTooltip,
            itemData,
            anchorWindow or SystemData.ActiveWindow.name,
            Tooltips.ANCHOR_WINDOW_RIGHT,
            true
        )
        if ok then
            return true
        end
    end
    StockPiler2RecipeTooltip.ShowColoredRows(
        anchorWindow or SystemData.ActiveWindow.name,
        StockPiler2RecipeTooltip.BuildPotionPlaceholderRows(summary),
        Tooltips.ANCHOR_WINDOW_RIGHT
    )
    return false
end
