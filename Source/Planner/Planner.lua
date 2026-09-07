----------------------------------------------------------------
-- StockPiler2 Planner — pure policy (scaffold; cache by store gens)
----------------------------------------------------------------

StockPiler2.Planner = StockPiler2.Planner or {}
local Planner = StockPiler2.Planner

local function ToNarrow(value)
    if StockPiler2.ToNarrow then
        return StockPiler2.ToNarrow(value)
    end
    return tostring(value or "")
end

local function CanAutoGrowSkill()
    local Caps = StockPiler2.TradeSkillCaps
    return Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true
end

local function CanBrewPotionsSkill()
    local Caps = StockPiler2.TradeSkillCaps
    return Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() == true
end

--- Growable short: AutoGrow path when Cultivation trained; otherwise buy plants/seeds.
local function SetMaterialsShortStatus(row, growable, detail, buyLabel)
    if CanAutoGrowSkill() then
        if growable == true then
            row.statusKey = "restocking"
            row.statusText = L"Restocking materials"
        else
            -- Growable short but AutoGrow off: user must enable AutoGrow (not a buy shortage).
            row.statusKey = "enable_autogrow"
            row.statusText = L"Enable AutoGrow"
        end
    else
        row.statusKey = "buy_ingredients"
        row.statusText = buyLabel or L"Buy plants"
    end
    if detail ~= nil then
        row.statusDetail = detail
    end
end

local function ApplyNeedApothecaryStatus(row)
    if CanBrewPotionsSkill() then
        return
    end
    if row.statusKey ~= "ready_to_craft" and row.statusKey ~= "ready_to_craft_shared" then
        return
    end
    row.statusKey = "need_apothecary"
    row.statusText = L"Need Apothecary"
    local lines = {
        L"Materials are ready, but only Apothecaries can brew potions.",
    }
    local Caps = StockPiler2.TradeSkillCaps
    if Caps and Caps.HasTalisman and Caps.HasTalisman() == true then
        lines[#lines + 1] = L"This character is a Talisman maker."
    end
    row.statusLines = lines
end

-- Red traffic-light statusKeys (TabWatch STATUS_COLORS COLOR_BLOCK).
local RED_STATUS_KEYS = {
    no_recipe = true,
    enable_autogrow = true,
    need_apothecary = true,
    buy_ingredients = true,
    need_materials = true,
}

-- True-green Watch statuses (not shared/yellow).
local TRUE_GREEN_STATUS_KEYS = {
    potion_stocked = true,
    ready_to_craft = true,
}

-- Player must act; AutoGrow cannot clear these by planting.
local PLAYER_ACTION_STATUS_KEYS = {
    buy_ingredients = true,
    need_materials = true,
    enable_autogrow = true,
    need_apothecary = true,
}

Planner._watchBlockOnceKeys = Planner._watchBlockOnceKeys or {}
Planner._growIdleBlockOnceKey = Planner._growIdleBlockOnceKey or nil

local function PlayNotifySound(soundId)
    if StockPiler2.Debug and StockPiler2.Debug.PlayUiSound then
        StockPiler2.Debug.PlayUiSound(soundId)
    elseif type(PlaySound) == "function" and soundId ~= nil then
        pcall(PlaySound, soundId)
    end
end

local function NotifyWatchRedBlocks(rows)
    local D = StockPiler2.Debug
    if not D or not D.NotifyOnce then
        return
    end
    local prev = Planner._watchBlockOnceKeys or {}
    local now = {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local statusKey = tostring(row.statusKey or "")
            if RED_STATUS_KEYS[statusKey] == true then
                local watchKey = tostring(row.potionKey or row.id or i)
                local onceKey = "watch-block:" .. watchKey .. ":" .. statusKey
                now[watchKey] = onceKey
                local name = row.name
                if name == nil or name == L"" then
                    name = L"watch"
                end
                local statusText = row.statusText
                if statusText == nil or statusText == L"" then
                    statusText = towstring(statusKey)
                end
                D.NotifyOnce(onceKey, name .. L": " .. statusText)
            end
        end
    end
    for watchKey, onceKey in pairs(prev) do
        if now[watchKey] ~= onceKey and D.ClearNotifyOnce then
            D.ClearNotifyOnce(onceKey)
        end
    end
    Planner._watchBlockOnceKeys = now
end

--- Once when every enabled plan row is true green; clear when any leaves.
--- Also wait for Seed Buffer — same gate as brew-ready / AutoGrow idle.
local function NotifyAllWatchesReady(rows)
    local D = StockPiler2.Debug
    if not D then
        return
    end
    local Grow = StockPiler2.Grow
    if Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied() ~= true then
        if D.ClearNotifyOnce then
            D.ClearNotifyOnce("watches-all-ready")
        end
        return
    end
    local any = false
    local allGreen = true
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            any = true
            local statusKey = tostring(row.statusKey or "")
            if TRUE_GREEN_STATUS_KEYS[statusKey] ~= true then
                allGreen = false
                break
            end
        end
    end
    if any and allGreen then
        local printed = false
        if D.NotifyOnce then
            printed = D.NotifyOnce("watches-all-ready", L"All watches ready to craft.") == true
        elseif D.Notify then
            D.Notify(L"All watches ready to craft.")
            printed = true
        end
        if printed then
            local soundId = GameData and GameData.Sound and GameData.Sound.HELP_TIPS_HIGHTLIGHT_WINDOW
            PlayNotifySound(soundId)
        end
    elseif D.ClearNotifyOnce then
        D.ClearNotifyOnce("watches-all-ready")
    end
end

--- Once when AutoGrow is action-idle but watches still need player actions.
local function NotifyAutoGrowIdleBlocked(rows)
    local D = StockPiler2.Debug
    if not D then
        return
    end
    local prevKey = Planner._growIdleBlockOnceKey
    local function clearPrev()
        if prevKey ~= nil and prevKey ~= "" and D.ClearNotifyOnce then
            D.ClearNotifyOnce(prevKey)
        end
        Planner._growIdleBlockOnceKey = nil
    end
    local Grow = StockPiler2.Grow
    if not (Grow and Grow.IsActionIdle and Grow.IsActionIdle() == true) then
        clearPrev()
        return
    end
    local keySet = {}
    local texts = {}
    local seenText = {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local statusKey = tostring(row.statusKey or "")
            if PLAYER_ACTION_STATUS_KEYS[statusKey] == true then
                keySet[statusKey] = true
                local narrow = ToNarrow(row.statusText)
                if narrow == "" then
                    narrow = statusKey
                end
                if seenText[narrow] ~= true then
                    seenText[narrow] = true
                    texts[#texts + 1] = narrow
                end
            end
        end
    end
    local fpParts = {}
    for statusKey in pairs(keySet) do
        fpParts[#fpParts + 1] = statusKey
    end
    if #fpParts == 0 or #texts == 0 then
        clearPrev()
        return
    end
    table.sort(fpParts)
    local onceKey = "grow-idle-blocked:" .. table.concat(fpParts, ",")
    if prevKey ~= nil and prevKey ~= onceKey and D.ClearNotifyOnce then
        D.ClearNotifyOnce(prevKey)
    end
    Planner._growIdleBlockOnceKey = onceKey
    local summary = table.concat(texts, "; ")
    local msg = L"AutoGrow idle: " .. towstring(summary) .. L"."
    local printed = false
    if D.NotifyOnce then
        printed = D.NotifyOnce(onceKey, msg) == true
    elseif D.Notify then
        D.Notify(msg)
        printed = true
    end
    if printed then
        local soundId = GameData and GameData.Sound and GameData.Sound.HELP_TIPS_NEW
        PlayNotifySound(soundId)
    end
end

local function CompareGrowPriority(a, b)
    local ca = tonumber(a.craftsHave) or 0
    local cb = tonumber(b.craftsHave) or 0
    if ca ~= cb then
        return ca < cb
    end
    local as = tonumber(a.craftsShort) or 0
    local bs = tonumber(b.craftsShort) or 0
    if as ~= bs then
        return as > bs
    end
    local da = tonumber(a.deficit) or 0
    local db = tonumber(b.deficit) or 0
    if da ~= db then
        return da > db
    end
    return tostring(a.specKey or "") < tostring(b.specKey or "")
end

--- Classify one recipe slot for plan status / tooltip (includes stocked slots).
local function RecipeSlotPlanEntry(slot, slots, craftsNeeded, specDemand)
    local RS = StockPiler2.RecipeSpec
    local MS = StockPiler2.MaterialSpec
    local SM = StockPiler2.SeedMap
    if type(slot) ~= "table" or not RS then
        return nil
    end
    local spec = slot.spec
    if type(spec) ~= "table" then
        return nil
    end
    local specKey = MS and MS.Key and MS.Key(spec) or ""
    local perCraft = RS.EffectiveSpecPerCraft and RS.EffectiveSpecPerCraft(slot, slots) or 1
    craftsNeeded = tonumber(craftsNeeded) or 0
    local potionNeed = craftsNeeded * perCraft
    local have = RS.CountItemsMatchingSpec and RS.CountItemsMatchingSpec(spec) or 0
    local demandRow = type(specDemand) == "table" and specDemand[specKey] or nil
    if type(demandRow) == "table" then
        have = tonumber(demandRow.have) or have
    end
    local deficit = math.max(0, potionNeed - have)
    local byproduct = SM and SM.IsHarvestByproduct and SM.IsHarvestByproduct(spec) == true
    local growable = (not byproduct) and MS and MS.IsGrowable and MS.IsGrowable(spec)
    local oneWay = (not byproduct) and SM and SM.IsOneWayHarvestSpec
        and SM.IsOneWayHarvestSpec(spec) == true
    local seedRecord = nil
    local seedHave = 0
    -- Resolve seed-line for both one-way harvest mats and growable plant products.
    -- This lets the planner detect a truly exhausted seed-line (live + outstanding).
    if (oneWay == true or growable == true) and SM.ResolveSeedForSpec then
        seedRecord = SM.ResolveSeedForSpec(spec)
        if type(seedRecord) == "table" then
            seedHave = tonumber(seedRecord.count) or 0
        end
    end

    local seedUid = type(seedRecord) == "table" and (tonumber(seedRecord.uniqueID) or 0) or 0
    local plantUid = type(seedRecord) == "table" and (tonumber(seedRecord.plantUid) or 0) or 0
    if plantUid <= 0 and seedUid > 0 and SM and SM.GetPlantUidForSeed then
        plantUid = tonumber(SM.GetPlantUidForSeed(seedUid)) or 0
    end
    if plantUid <= 0 and SM and SM.FindPlantUidForSpec then
        plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
    end
    local seedCredit = 0
    if seedUid > 0 and StockPiler2.Refine and StockPiler2.Refine.GetSeedBudgetForSpec then
        local budget = StockPiler2.Refine.GetSeedBudgetForSpec(spec, seedUid)
        seedCredit = tonumber(budget and budget.credit) or 0
    end
    local refinable = 0
    if growable and plantUid > 0 and StockPiler2.Refine and StockPiler2.Refine.CountRefinablePlants then
        refinable = tonumber(StockPiler2.Refine.CountRefinablePlants(plantUid, spec)) or 0
    end
    local craftsHave = perCraft > 0 and math.floor(have / perCraft) or 0
    -- Pooled short across grow-demand watches: this recipe's Need may be covered
    -- while absolute demand still exceeds bag stock (e.g. 3x Need 40, have 72).
    local absolute = 0
    local watchCount = 0
    if type(demandRow) == "table" then
        absolute = tonumber(demandRow.absolute) or 0
        if type(demandRow.watchDetails) == "table" then
            watchCount = #demandRow.watchDetails
        end
    end
    local sharedPool = absolute > have and (watchCount > 1 or absolute > potionNeed)
    local entry = {
        spec = spec,
        specKey = specKey,
        have = have,
        need = potionNeed,
        deficit = deficit,
        role = slot.role,
        perCraft = perCraft,
        craftsHave = craftsHave,
        craftsShort = math.max(0, craftsNeeded - craftsHave),
        stocked = deficit <= 0,
        sharedPool = sharedPool == true,
        absoluteNeed = absolute,
        oneWay = oneWay == true,
        seed = seedRecord,
        seedHave = seedHave,
        seedUid = seedUid,
        plantUid = plantUid,
        seedCredit = seedCredit,
        refinable = refinable,
    }
    if slot.role == "container" then
        entry.kind = "buy"
    elseif byproduct then
        entry.kind = "convert"
    elseif oneWay and deficit > 0 and seedCredit <= 0 then
        -- One-way harvest mat with no seeds in bags: buy seed or buy material.
        entry.kind = "buy"
        entry.buySeedOrMat = true
    elseif growable and deficit > 0 and seedCredit <= 0 and refinable > 0 then
        -- Plants in bag can refill seeds — not a buy shortage.
        entry.kind = "plant"
        entry.needsRefine = true
    elseif growable and deficit > 0 and seedCredit <= 0 then
        -- Growable plant whose seed-line is exhausted and nothing refinable: buy seed.
        entry.kind = "buy"
        entry.buySeedOrMat = true
    elseif growable or (oneWay and seedCredit > 0) then
        entry.kind = "plant"
    else
        entry.kind = "buy"
    end
    return entry
end

function Planner.BuildRecipeSlotTooltipEntries(recipe, craftsNeeded, specDemand)
    local entries = {}
    if type(recipe) ~= "table" then
        return entries
    end
    craftsNeeded = tonumber(craftsNeeded) or 0
    local slots = recipe.slots or {}
    for i = 1, #slots do
        local entry = RecipeSlotPlanEntry(slots[i], slots, craftsNeeded, specDemand)
        if entry ~= nil then
            entries[#entries + 1] = entry
        end
    end
    return entries
end

local function ApplySpecPlanStatus(row, target, recipe, demand)
    local RS = StockPiler2.RecipeSpec
    local MS = StockPiler2.MaterialSpec
    row.statusDetail = L""
    row.statusLines = nil
    row.statusSlots = nil
    row.statusNeedLine = nil
    row.statusTipSlots = nil
    if target.min <= 0 then
        row.statusKey = "no_target"
        row.statusText = L"Set target"
        row.statusLines = { L"Set a Target# for this potion." }
        return
    end
    if recipe == nil then
        row.statusKey = "no_recipe"
        row.statusText = L"Learn recipe"
        if CanBrewPotionsSkill() then
            row.statusLines = {
                L"Learn this recipe at the Apothecary, then brew it once so StockPiler can store the slots.",
            }
        else
            row.statusLines = {
                L"Learning potion recipes requires Apothecary. Brew once at the Apothecary to store the slots.",
            }
        end
        return
    end
    if target.deficit <= 0 then
        row.statusKey = "potion_stocked"
        row.statusText = L"Potions stocked"
        row.statusLines = { L"Bag count is at or above the target." }
        return
    end
    local yield = RS.RecipeOutputYield and RS.RecipeOutputYield(recipe) or (tonumber(recipe.recipeYield) or 2)
    local craftsNeeded = RS.CraftsNeededForDeficit and RS.CraftsNeededForDeficit(target.deficit, recipe)
        or math.ceil(target.deficit / math.max(1, yield))
    row.recipeYield = yield
    row.stockYield = RS.WatchStockYield and RS.WatchStockYield(recipe) or 1
    row.craftsNeeded = craftsNeeded
    if RS.WatchCoveredByBagsAndCraftable
        and RS.WatchCoveredByBagsAndCraftable(target.entry, recipe, target.min)
    then
        local wantsGrowCovered = RS.ShouldAutoGrowPotion
            and RS.ShouldAutoGrowPotion(target.potionKey, nil) == true
        if wantsGrowCovered
            and StockPiler2.Watch
            and StockPiler2.Watch.IsSeedBufferEnabled
            and StockPiler2.Watch.IsSeedBufferEnabled() == true
            and RS.WatchHasSeedBufferShort
            and RS.WatchHasSeedBufferShort(recipe)
        then
            local buffer = StockPiler2.Watch.GetSeedBufferMin and StockPiler2.Watch.GetSeedBufferMin() or 5
            row.statusKey = "need_seeds"
            row.statusText = L"Seed buffer"
            row.statusLines = {
                L"Stock + Craftable covers the target, but watched seeds are below the buffer ("
                    .. towstring(tostring(buffer))
                    .. L").",
                L"AutoGrow will refine or buffer-grow until the seed buffer is full. Brewing now risks a seed shortage.",
            }
            return
        end
        row.statusKey = "ready_to_craft"
        row.statusText = L"Ready to craft"
        if CanBrewPotionsSkill() then
            row.statusLines = {
                L"Stock + Craftable covers the target. Open the Apothecary to brew.",
                L"Potent / other rarities do not count. Growing resumes if stock is still short after brewing.",
            }
        else
            row.statusLines = {
                L"Stock + Craftable covers the target, but only Apothecaries can brew potions.",
            }
        end
        return
    end
    local wantsGrow = RS.ShouldAutoGrowPotion and RS.ShouldAutoGrowPotion(target.potionKey, nil) == true
    local slots = recipe.slots or {}
    local limiting = nil
    local containerShort = nil
    local vendorShort = nil
    local byproductShort = nil
    local plantShort = {}
    local convertShort = {}
    local buyShort = {}
    local statusSlots = {}
    -- One RecipeSlotPlanEntry pass for status + tipSlots (tip pass reuses).
    local allEntries = {}
    for i = 1, #slots do
        local entry = RecipeSlotPlanEntry(slots[i], slots, craftsNeeded, demand)
        if entry ~= nil then
            allEntries[#allEntries + 1] = entry
            if entry.deficit > 0 then
                if entry.kind == "buy" and entry.role == "container" then
                    containerShort = entry
                    buyShort[#buyShort + 1] = entry
                elseif entry.kind == "convert" then
                    if byproductShort == nil or entry.craftsHave < (byproductShort.craftsHave or 0) then
                        byproductShort = entry
                    end
                    convertShort[#convertShort + 1] = entry
                elseif entry.kind == "plant" then
                    if limiting == nil or CompareGrowPriority(entry, limiting) then
                        limiting = entry
                    end
                    plantShort[#plantShort + 1] = entry
                else
                    if vendorShort == nil or entry.deficit > vendorShort.deficit then
                        vendorShort = entry
                    end
                    buyShort[#buyShort + 1] = entry
                end
            end
        end
    end
    row.statusTipSlots = allEntries

    for i = 1, #plantShort do
        statusSlots[#statusSlots + 1] = plantShort[i]
    end
    for i = 1, #convertShort do
        statusSlots[#statusSlots + 1] = convertShort[i]
    end
    for i = 1, #buyShort do
        statusSlots[#statusSlots + 1] = buyShort[i]
    end
    row.statusSlots = statusSlots

    local function haveNeed(entry)
        return towstring(tostring(entry.have)) .. L"/" .. towstring(tostring(entry.need))
    end
    local function matName(entry)
        if MS and MS.NeedLabel then
            return MS.NeedLabel(entry.spec)
        end
        if MS and MS.Label then
            return MS.Label(entry.spec)
        end
        return L"material"
    end
    local function seedName(entry)
        if MS and MS.NeedLabel then
            return MS.NeedLabel(entry.spec, { asSeed = true, seed = entry.seed })
        end
        return L"seed"
    end
    local lines = {
        L"Need " .. towstring(tostring(craftsNeeded)) .. L" crafts for "
            .. towstring(tostring(target.deficit)) .. L" more of this potion."
            .. L" Recipe yield "
            .. towstring(tostring(yield))
            .. L" is a best case; Potent / other rarities do not count.",
    }
    if wantsGrow ~= true then
        if CanAutoGrowSkill() then
            lines[#lines + 1] = L"Enable AutoGrow for this watch to plant short materials."
        else
            lines[#lines + 1] =
                L"Cultivation is required to AutoGrow. Buy plants or seeds, or use a Cultivator character."
            local Caps = StockPiler2.TradeSkillCaps
            local gather = Caps and Caps.GatheringLabel and Caps.GatheringLabel()
            if gather ~= nil and gather ~= L"Cultivation" then
                lines[#lines + 1] = L"This character gathers via "
                    .. gather
                    .. L" — plant mats must be bought or grown on a Cultivator."
            end
        end
    end
    for i = 1, #plantShort do
        local entry = plantShort[i]
        local verb = L"Plant "
        if entry.needsRefine == true then
            verb = L"Refine "
        end
        local line = verb .. matName(entry) .. L" (" .. haveNeed(entry) .. L")"
        local Grow = StockPiler2.Grow
        if Grow and Grow.GrowingNotesForSpec then
            local notes = Grow.GrowingNotesForSpec(entry.spec)
            entry.growingNotes = notes or L""
            if notes and notes ~= L"" then
                line = line .. L" -- " .. notes
            end
        end
        lines[#lines + 1] = line
    end
    for i = 1, #convertShort do
        local entry = convertShort[i]
        lines[#lines + 1] = L"Grow recipe plants, then convert surplus for "
            .. matName(entry) .. L" (" .. haveNeed(entry) .. L")"
    end
    local buySeedOrMatShort = nil
    for i = 1, #buyShort do
        local entry = buyShort[i]
        if entry.buySeedOrMat == true then
            buySeedOrMatShort = buySeedOrMatShort or entry
            lines[#lines + 1] = L"Buy "
                .. seedName(entry)
                .. L" (have "
                .. towstring(tostring(entry.seedHave or 0))
                .. L") or buy "
                .. matName(entry)
                .. L" ("
                .. haveNeed(entry)
                .. L")"
        else
            local verb = L"Buy "
            if entry.role == "container" then
                verb = L"Buy flasks: "
            end
            lines[#lines + 1] = verb .. matName(entry) .. L" (" .. haveNeed(entry) .. L")"
        end
    end
    if #plantShort + #convertShort + #buyShort == 0 then
        lines[#lines + 1] = L"Materials look sufficient for this potion."
    end
    row.statusLines = lines
    row.statusNeedLine = lines[1]

    -- Byproduct convert only claims "Restocking" when AutoGrow can feed it:
    -- plant-kind deficits, or any recipe slot with seed credit (surplus grow for convert).
    local convertFeedable = limiting ~= nil
    if byproductShort ~= nil and not convertFeedable then
        for i = 1, #allEntries do
            local entry = allEntries[i]
            if entry ~= nil and (tonumber(entry.seedCredit) or 0) > 0 then
                convertFeedable = true
                break
            end
        end
    end
    if byproductShort ~= nil
        and convertFeedable
        and (limiting == nil or (byproductShort.craftsHave or 0) <= (limiting.craftsHave or 0))
    then
        row.growable = wantsGrow
        SetMaterialsShortStatus(row, wantsGrow, lines[2] or lines[1], L"Buy materials")
        row.specDeficit = byproductShort
        return
    end
    if limiting ~= nil then
        row.growable = wantsGrow
        row.specDeficit = limiting
        if limiting.needsRefine == true then
            if StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
                and StockPiler2.Watch.IsSeedBufferEnabled() == true
            then
                row.statusKey = "need_seeds"
                row.statusText = L"Seed buffer"
            elseif CanAutoGrowSkill() and wantsGrow == true then
                row.statusKey = "restocking"
                row.statusText = L"Refine plants"
            else
                SetMaterialsShortStatus(row, wantsGrow, lines[2] or lines[1], L"Buy plants")
            end
            row.statusDetail = lines[2] or lines[1]
            return
        end
        local buyLabel = L"Buy plants"
        if limiting.buySeedOrMat == true
            and limiting.seedUid
            and tonumber(limiting.seedUid) > 0
        then
            buyLabel = L"Buy seeds"
        end
        SetMaterialsShortStatus(row, wantsGrow, lines[2] or lines[1], buyLabel)
        return
    end
    if containerShort ~= nil then
        row.statusKey = "buy_ingredients"
        row.statusText = L"Buy flasks"
        row.statusDetail = lines[2] or lines[1]
        return
    end
    if buySeedOrMatShort ~= nil then
        row.statusKey = "buy_ingredients"
        row.statusText = buySeedOrMatShort.seedUid and tonumber(buySeedOrMatShort.seedUid) > 0
            and L"Buy seeds"
            or L"Buy seed or material"
        row.statusDetail = lines[2] or lines[1]
        row.specDeficit = buySeedOrMatShort
        return
    end
    if vendorShort ~= nil then
        row.statusKey = "buy_ingredients"
        row.statusText = L"Buy materials"
        row.statusDetail = lines[2] or lines[1]
        return
    end
    -- Byproduct short but no seed/plant feedstock and no other buy shorts.
    if byproductShort ~= nil then
        row.statusKey = "buy_ingredients"
        row.statusText = L"Buy materials"
        row.statusDetail = lines[2] or lines[1]
        row.specDeficit = byproductShort
        return
    end
    row.statusKey = "ready_to_craft"
    row.statusText = L"Ready to craft"
    row.statusSlots = nil
    if CanBrewPotionsSkill() then
        row.statusLines = { L"Ready to craft. Open the Apothecary to brew." }
    else
        row.statusLines = { L"Materials look ready, but only Apothecaries can brew potions." }
    end
end

local function BuildWatchedTargets(ctx)
    local targets = {}
    local RS = StockPiler2.RecipeSpec
    local watches = type(ctx) == "table" and ctx.watches or {}
    if type(watches) ~= "table" or not RS then
        return targets
    end
    for watchKey, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local resolved = RS.ResolveWatchPotion and RS.ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            if type(potion) == "table" then
                local have = RS.PotionHaveCombined and RS.PotionHaveCombined(potion) or 0
                local min = tonumber(watch.targetStock) or 0
                local recipeLabel = L""
                if resolved.recipeSpecKey and RS.RecipeLabelForKey then
                    recipeLabel = RS.RecipeLabelForKey(resolved.recipeSpecKey, potion.outputUid) or L""
                end
                targets[#targets + 1] = {
                    id = watchKey,
                    potionKey = watchKey,
                    potionBaseKey = resolved.potionKey,
                    recipeSpecKey = resolved.recipeSpecKey,
                    recipeLabel = recipeLabel,
                    entry = potion,
                    uniqueID = potion.outputUid,
                    name = potion.name or towstring(tostring(potion.outputUid)),
                    iconNum = tonumber(potion.iconNum) or 0,
                    have = have,
                    min = min,
                    deficit = math.max(0, min - have),
                    autoGrow = RS.WatchWantsAutoGrow and RS.WatchWantsAutoGrow(watch) or (watch.autoGrow ~= false),
                }
            end
        end
    end
    table.sort(targets, function(a, b)
        local na = ToNarrow(a.name)
        local nb = ToNarrow(b.name)
        if na ~= nb then
            return na < nb
        end
        return ToNarrow(a.recipeLabel) < ToNarrow(b.recipeLabel)
    end)
    return targets
end

function Planner.BuildWatchRows(ctx)
    local rows = {}
    local RS = StockPiler2.RecipeSpec
    local Perf = StockPiler2.Perf
    local targets = BuildWatchedTargets(ctx)
    local demand = nil
    if RS and RS.BuildBalancedSpecDemand then
        if Perf and Perf.Begin then
            Perf.Begin("Build.Demand")
        end
        demand = RS.BuildBalancedSpecDemand()
        if Perf and Perf.End then
            Perf.End("Build.Demand")
        end
    end
    if Perf and Perf.Begin then
        Perf.Begin("Build.Status")
    end
    for i = 1, #targets do
        local target = targets[i]
        local recipe = RS and RS.RecipeSpecForPotion and RS.RecipeSpecForPotion(target.potionKey)
        local row = {
            id = target.id,
            potionKey = target.potionKey,
            potionRecipeKey = target.potionKey,
            name = target.name,
            iconNum = target.iconNum,
            uniqueID = target.uniqueID,
            potionHave = target.have,
            stockText = towstring(tostring(target.have)),
            potionMin = target.min,
            target = target.min,
            targetText = towstring(tostring(target.min)),
            potionDeficit = target.deficit,
            recipe = recipe,
            recipeLabel = target.recipeLabel,
            recipeSpecKey = target.recipeSpecKey,
            potionBaseKey = target.potionBaseKey,
            autoGrow = target.autoGrow == true,
            hasRecipe = type(recipe) == "table",
        }
        ApplySpecPlanStatus(row, target, recipe, demand)
        local craftable = 0
        local craftsPossible = 0
        if recipe and RS.CountPotionsCraftable then
            craftable = RS.CountPotionsCraftable(recipe) or 0
            craftable = math.max(0, math.floor((tonumber(craftable) or 0) + 0.5))
            if RS.CountCraftsPossible then
                craftsPossible = math.max(0, math.floor((tonumber(RS.CountCraftsPossible(recipe)) or 0) + 0.5))
            end
        end
        row.craftable = craftable
        row.craftsPossible = craftsPossible
        row.craftableShared = false
        row.craftableText = craftable > 0 and towstring(tostring(craftable)) or (recipe and L"0" or L"-")
        if type(recipe) == "table" and RS.HydrateRecipeSlots then
            RS.HydrateRecipeSlots(recipe)
        end
        rows[#rows + 1] = row
    end
    -- Contested shared mats among deficit watches only (stocked leftover craftable ignored).
    if RS and RS.ApplyDeficitCraftableShared then
        RS.ApplyDeficitCraftableShared(rows)
    else
        for i = 1, #rows do
            rows[i].craftableShared = false
            rows[i].contestedSpecKeys = nil
        end
    end
    if Perf and Perf.End then
        Perf.End("Build.Status")
    end
    local Grow = StockPiler2.Grow
    if Perf and Perf.Begin then
        Perf.Begin("Build.Tips")
    end
    for i = 1, #rows do
        local row = rows[i]
        if (tonumber(row.craftable) or 0) > 0 or row.hasRecipe then
            row.craftableText = towstring(tostring(row.craftable or 0))
        end
        if row.statusKey == "ready_to_craft" and row.craftableShared == true then
            row.statusKey = "ready_to_craft_shared"
            row.statusText = L"Shared materials"
            row.statusLines = {
                L"Stock + Craftable covers the target, but shared materials are contested with other short watches.",
                L"AutoGrow will keep filling shared plants until Craftable turns green. Footer Brew waits for uncontested Ready; row Load/Brew can brew early.",
            }
        elseif row.statusKey == "ready_to_craft" then
            row.statusLines = {
                L"Stock + Craftable covers the target and shared materials are uncontested.",
                L"Use footer Brew or the row Brew button to load and craft. Growing resumes if stock is still short after brewing.",
            }
        end
        ApplyNeedApothecaryStatus(row)

        -- Tip-ready full slot entries (stocked + short) so Status hover skips rebuild.
        local craftsNeeded = tonumber(row.craftsNeeded) or 0
        local recipe = row.recipe
        if type(recipe) == "table" and craftsNeeded > 0 then
            local tipSlots = row.statusTipSlots
            if type(tipSlots) ~= "table" then
                tipSlots = Planner.BuildRecipeSlotTooltipEntries(recipe, craftsNeeded, demand)
            end
            if Grow and Grow.GrowingNotesForSpec then
                for s = 1, #tipSlots do
                    local entry = tipSlots[s]
                    if type(entry) == "table"
                        and entry.kind == "plant"
                        and (entry.stocked ~= true)
                        and ((tonumber(entry.deficit) or 0) > 0)
                    then
                        if entry.growingNotes == nil then
                            entry.growingNotes = Grow.GrowingNotesForSpec(entry.spec) or L""
                        end
                    end
                end
            end
            row.statusTipSlots = tipSlots
        else
            row.statusTipSlots = nil
        end
    end
    if Perf and Perf.End then
        Perf.End("Build.Tips")
    end
    NotifyWatchRedBlocks(rows)
    NotifyAllWatchesReady(rows)
    NotifyAutoGrowIdleBlocked(rows)
    return rows
end

local function CacheKey(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    return table.concat({
        tostring(ctx.snapGen or 0),
        tostring(ctx.gardenGen or 0),
        tostring(ctx.refineGen or 0),
        tostring(ctx.watchGen or 0),
        tostring(ctx.knowledgeGen or 0),
        tostring(ctx.settingsHash or 0),
    }, ":")
end

function Planner.SettingsHash()
    local Watch = StockPiler2.Watch
    local settings = StockPiler2.Settings
    local hash = 0
    if type(settings) == "table" then
        hash = tonumber(settings.settingsVersion) or 0
        local row = Watch and Watch.CharacterRow and Watch.CharacterRow()
        if type(row) == "table" and row.autoGrowEnabled == true then
            hash = hash + 1
        end
    end
    local Caps = StockPiler2.TradeSkillCaps
    if Caps and Caps.LevelsHash then
        -- Fold skill levels into the numeric hash so status/enable gates refresh.
        local levels = Caps.LevelsHash()
        local n = 0
        for i = 1, string.len(levels) do
            n = n + string.byte(levels, i)
        end
        hash = hash + n * 17
    end
    return hash
end

function Planner.CacheKeyFromGens()
    local Inv = StockPiler2.Inventory
    local Garden = StockPiler2.Garden
    local RP = StockPiler2.RefinePipeline
    local Watch = StockPiler2.Watch
    local Know = StockPiler2.Knowledge
    return CacheKey({
        snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0,
        gardenGen = Garden and (Garden.GetPlanGen and Garden.GetPlanGen() or Garden.GetGen and Garden.GetGen()) or 0,
        refineGen = RP and RP.GetGen and RP.GetGen() or 0,
        watchGen = Watch and Watch.GetGen and Watch.GetGen() or 0,
        knowledgeGen = Know and Know.GetGen and Know.GetGen() or 0,
        settingsHash = Planner.SettingsHash(),
    })
end

function Planner.BuildContext()
    local Inv = StockPiler2.Inventory
    local Garden = StockPiler2.Garden
    local RP = StockPiler2.RefinePipeline
    local Watch = StockPiler2.Watch
    local Know = StockPiler2.Knowledge
    return {
        snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0,
        gardenGen = Garden and (Garden.GetPlanGen and Garden.GetPlanGen() or Garden.GetGen and Garden.GetGen()) or 0,
        refineGen = RP and RP.GetGen and RP.GetGen() or 0,
        watchGen = Watch and Watch.GetGen and Watch.GetGen() or 0,
        knowledgeGen = Know and Know.GetGen and Know.GetGen() or 0,
        settingsHash = Planner.SettingsHash(),
        counts = Inv and Inv.GetCountsCopy and Inv.GetCountsCopy() or {},
        plots = Garden and Garden.GetPlotsCopy and Garden.GetPlotsCopy() or {},
        outstanding = RP and RP.Snapshot and RP.Snapshot() or {},
        watches = Watch and Watch.GetWatches and Watch.GetWatches() or {},
        trace = {},
    }
end

function Planner.GetOrBuild(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.force == true then
        return Planner.Build(opts)
    end
    local PS = StockPiler2.PlanSnapshot
    -- While a coalesced rebuild is pending, serve the last snapshot so harvest/bag
    -- bursts do not force Planner.Build xN from UI/orch GetOrBuild callers.
    local Sch = StockPiler2.Scheduler
    if Sch and Sch.IsPlanRebuildPending and Sch.IsPlanRebuildPending() == true then
        local stale = PS and PS.Get and PS.Get()
        if type(stale) == "table" then
            return stale
        end
        -- Pending with no snapshot: do not sync-build on hot paths (footer/cultivation).
        return nil
    end
    local key = Planner.CacheKeyFromGens()
    if PS and PS.GetCacheKey and PS.GetCacheKey() == key then
        local cached = PS.Get and PS.Get()
        if type(cached) == "table" then
            return cached
        end
    end
    -- Hot paths (footer CanBrewNow, Watch list): never sync-build; enqueue and return stale.
    if opts.refresh == false then
        if Sch and Sch.EnqueuePlanRebuild then
            Sch.EnqueuePlanRebuild()
        end
        local stale = PS and PS.Get and PS.Get()
        if type(stale) == "table" then
            return stale
        end
        return nil
    end
    return Planner.Build(opts)
end

function Planner.Build(opts)
    opts = type(opts) == "table" and opts or {}
    local PS = StockPiler2.PlanSnapshot
    if opts.force ~= true and PS and PS.GetCacheKey then
        local key = Planner.CacheKeyFromGens()
        if PS.GetCacheKey() == key then
            local cached = PS.Get and PS.Get()
            if type(cached) == "table" then
                return cached
            end
        end
    end
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Planner.Build")
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.SuppressInventorySideEffects then
        StockPiler2.Scheduler.SuppressInventorySideEffects(3)
    end
    if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.BeginPlanCraftsMemo then
        StockPiler2.RecipeSpec.BeginPlanCraftsMemo()
    end
    -- One-pass have-cache for this snapGen (replaces blind wipe + per-spec bag walks).
    if Perf and Perf.Begin then
        Perf.Begin("Build.WarmHave")
    end
    if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.WarmSpecHaveCacheForWatches then
        StockPiler2.RecipeSpec.WarmSpecHaveCacheForWatches()
    elseif StockPiler2.RecipeSpec then
        StockPiler2.RecipeSpec._specHaveCache = {}
        StockPiler2.RecipeSpec._specHaveSnapGen = nil
    end
    if Perf and Perf.End then
        Perf.End("Build.WarmHave")
    end
    if StockPiler2.SeedMap and StockPiler2.SeedMap.ClearPlanCaches then
        StockPiler2.SeedMap.ClearPlanCaches()
    end
    local ctx = Planner.BuildContext()
    local key = CacheKey(ctx)
    local trace = {}
    if StockPiler2.Debug and StockPiler2.Debug.Enabled == true then
        trace[#trace + 1] = string.format(
            "snapGen=%d gardenGen=%d watches=%d",
            ctx.snapGen, ctx.gardenGen,
            type(ctx.watches) == "table" and (function()
                local n = 0
                for _ in pairs(ctx.watches) do n = n + 1 end
                return n
            end)() or 0
        )
    end
    local planGen = (tonumber(Planner._planGen) or 0) + 1
    Planner._planGen = planGen
    local plan = {
        planGen = planGen,
        cacheKey = key,
        ctx = ctx,
        rows = Planner.BuildWatchRows(ctx),
        growJobs = {},
        refineIntents = {},
        brewBlocks = {},
        reservations = {},
        trace = trace,
        builtAt = (type(GetGameTime) == "function" and GetGameTime()) or 0,
    }
    if PS then
        PS.Set(plan, key)
    end
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("plan", string.format("rebuild gen=%d key=%s", planGen, key))
    end
    if StockPiler2.Brew and StockPiler2.Brew.MaybeNotifyBrewReady then
        StockPiler2.Brew.MaybeNotifyBrewReady()
    end
    local B = StockPiler2.EventBus
    local E = StockPiler2.Events
    if B and E and E.PLAN_UPDATED then
        B.Fire(E.PLAN_UPDATED, { planGen = planGen, cacheKey = key })
    end
    if Perf and Perf.End then
        Perf.End("Planner.Build")
    end
    return plan
end

function Planner.BuildPlan(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.refresh == true then
        opts.force = true
    end
    return Planner.Build(opts)
end

function Planner.InvalidatePlanCache()
    if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Invalidate then
        StockPiler2.PlanSnapshot.Invalidate()
    end
end

local function DumpWatchRows(emit, rows)
    local RS = StockPiler2.RecipeSpec
    local MS = StockPiler2.MaterialSpec
    emit("=== StockPiler2 watchplan ===")
    emit(string.format("  watches=%d", type(rows) == "table" and #rows or 0))
    if type(rows) ~= "table" then
        emit("=== end watchplan ===")
        return
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            emit(string.format(
                "  [%d] %s key=%s status=%s stock=%s/%s deficit=%s craftable=%s craftsPossible=%s craftsNeeded=%s craftsClaim=%s shared=%s autoGrow=%s",
                i,
                ToNarrow(row.name),
                tostring(row.potionKey or ""),
                tostring(row.statusKey or ""),
                tostring(row.potionHave or 0),
                tostring(row.potionMin or row.target or 0),
                tostring(row.potionDeficit or 0),
                tostring(row.craftable or 0),
                tostring(row.craftsPossible or 0),
                tostring(row.craftsNeeded or "-"),
                tostring(row.craftsClaim or "-"),
                tostring(row.craftableShared == true),
                tostring(row.autoGrow == true)
            ))
            if row.statusText ~= nil then
                emit("      statusText=" .. ToNarrow(row.statusText))
            end
            local recipe = row.recipe
            if type(recipe) == "table" and type(recipe.slots) == "table" then
                local claim = tonumber(row.craftsClaim)
                if claim == nil then
                    local possible = tonumber(row.craftsPossible) or 0
                    local needed = tonumber(row.craftsNeeded) or possible
                    claim = math.min(possible, needed)
                end
                for s = 1, #recipe.slots do
                    local slot = recipe.slots[s]
                    local spec = slot and (slot.spec or (RS and RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)))
                    if type(spec) == "table" then
                        local specKey = MS and MS.Key and MS.Key(spec) or ""
                        local perCraft = RS and RS.EffectiveSpecPerCraft
                            and RS.EffectiveSpecPerCraft(slot, recipe.slots) or 1
                        perCraft = tonumber(perCraft) or 1
                        local have = 0
                        if RS and RS.CountItemsMatchingSpec then
                            have = tonumber(RS.CountItemsMatchingSpec(spec)) or 0
                        end
                        local label = ""
                        if MS and MS.NeedLabel then
                            label = ToNarrow(MS.NeedLabel(spec))
                        elseif MS and MS.Label then
                            label = ToNarrow(MS.Label(spec))
                        end
                        emit(string.format(
                            "      slot role=%s spec=%s label=%s have=%s perCraft=%s claim=%s",
                            tostring(slot.role or ""),
                            tostring(specKey),
                            label,
                            tostring(have),
                            tostring(perCraft),
                            tostring(claim * perCraft)
                        ))
                    end
                end
            end
        end
    end
    emit("=== end watchplan ===")
end

function Planner.DumpWatchPlan(emit)
    emit = type(emit) == "function" and emit or function(msg)
        StockPiler2.Debug.Print(msg)
    end
    emit("(diagnostic: forces full plan rebuild)")
    local plan = Planner.Build({ force = true })
    DumpWatchRows(emit, plan and plan.rows)
end

function Planner.Dump(emit)
    emit = type(emit) == "function" and emit or function(msg)
        StockPiler2.Debug.Print(msg)
    end
    emit("(diagnostic: forces full plan rebuild)")
    local plan = Planner.Build({ force = true })
    emit("=== StockPiler2 plan ===")
    emit("planGen=" .. tostring(plan.planGen) .. " cacheKey=" .. tostring(plan.cacheKey))
    if type(plan.trace) == "table" then
        for i = 1, #plan.trace do
            emit("  trace: " .. tostring(plan.trace[i]))
        end
    end
    emit("uid counts: " .. tostring((function()
        local n = 0
        for _ in pairs(plan.ctx.counts or {}) do n = n + 1 end
        return n
    end)()))
    DumpWatchRows(emit, plan and plan.rows)
    emit("=== end plan ===")
end

function Planner.DumpGrowPlan(emit)
    emit = type(emit) == "function" and emit or function(msg) StockPiler2.Debug.Print(msg) end
    emit("=== StockPiler2 grow plan ===")
    emit("(diagnostic: forces garden sync + grow/refine diagnostics)")
    local Garden = StockPiler2.Garden
    if Garden and Garden.SyncAll then
        Garden.SyncAll()
    end
    if Garden and Garden.GetPlotsCopy then
        local plots = Garden.GetPlotsCopy()
        for plotNum = 1, 4 do
            local p = plots[plotNum]
            local pending = 0
            if StockPiler2.Grow and StockPiler2.Grow._pendingPlant then
                pending = tonumber(StockPiler2.Grow._pendingPlant[plotNum]) or 0
            end
            if type(p) == "table" then
                emit(string.format(
                    "  P%d stage=%d seedUid=%d plantUid=%d pending=%d isPlotEmpty=%s",
                    plotNum,
                    tonumber(p.stage) or 0,
                    tonumber(p.seedUid) or 0,
                    tonumber(p.plantUid) or 0,
                    pending,
                    tostring(StockPiler2.Grow and StockPiler2.Grow.IsPlotEmpty
                        and StockPiler2.Grow.IsPlotEmpty(plotNum))
                ))
            else
                emit(string.format(
                    "  P%d (empty) pending=%d",
                    plotNum, pending
                ))
            end
        end
    end
    if StockPiler2.Grow and StockPiler2.Grow.DumpDiagnostics then
        StockPiler2.Grow.DumpDiagnostics(emit)
    end
    if StockPiler2.Refine and StockPiler2.Refine.DumpDiagnostics then
        StockPiler2.Refine.DumpDiagnostics(emit)
    end
    emit("=== end grow plan ===")
end

--- Classify recipe slot for AutoBuy: only non-growable, non-byproduct mats.
local function ClassifyBuyKind(spec)
    if type(spec) ~= "table" then
        return nil
    end
    if StockPiler2.SeedMap
        and StockPiler2.SeedMap.IsHarvestByproduct
        and StockPiler2.SeedMap.IsHarvestByproduct(spec) == true
    then
        return "convert"
    end
    if StockPiler2.SeedMap
        and StockPiler2.SeedMap.IsGrowableSpec
        and StockPiler2.SeedMap.IsGrowableSpec(spec) == true
    then
        return "plant"
    end
    if StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.IsGrowable
        and StockPiler2.MaterialSpec.IsGrowable(spec) == true
    then
        return "plant"
    end
    return "buy"
end

local function SpecJobLabel(spec)
    local MS = StockPiler2.MaterialSpec
    if MS and MS.NeedLabel then
        return MS.NeedLabel(spec)
    end
    if MS and MS.Label then
        return MS.Label(spec)
    end
    return L"material"
end

--- Vendor buy list for enabled watches below target.
--- Prefers mats for max bottleGap (Target-Stock-Craftable) focus watches; falls
--- back to all short watches when focus yields no buyable deficits (e.g. focus
--- only needs growables). Never refine byproducts. Plants/seeds omitted when
--- Cultivation is trained (AutoGrow owns that pipeline).
function Planner.CollectVendorBuyJobs()
    local jobs = {}
    Planner._vendorBuyJobsMeta = {
        source = "none",
        maxBottleGap = nil,
        focusWatchCount = 0,
    }
    local Inv = StockPiler2.Inventory
    if Inv and Inv._ready ~= true then
        return jobs
    end
    local RS = StockPiler2.RecipeSpec
    local MS = StockPiler2.MaterialSpec
    local watches = StockPiler2.Watch and StockPiler2.Watch.GetWatches and StockPiler2.Watch.GetWatches() or nil
    if type(RS) ~= "table" or type(watches) ~= "table" then
        return jobs
    end
    if RS.ClearCountCaches then
        RS.ClearCountCaches()
    end

    local Caps = StockPiler2.TradeSkillCaps
    local allowPlantBuys = not (Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() == true)

    local function ResolveWatchRecipe(watchKey, resolved)
        local recipe = nil
        if resolved and resolved.recipeSpecKey and RS.RecipeSpecForPotionRecipe then
            recipe = RS.RecipeSpecForPotionRecipe(resolved.recipeSpecKey)
        end
        if type(recipe) ~= "table" and RS.RecipeSpecForPotion then
            recipe = RS.RecipeSpecForPotion(watchKey)
        end
        return recipe
    end

    local function JobsFromBuyPool(buyPool)
        local out = {}
        for specKey, row in pairs(buyPool) do
            local have = 0
            if RS.CountItemsMatchingSpec then
                have = tonumber(RS.CountItemsMatchingSpec(row.spec)) or 0
            end
            local deficit = math.max(0, (tonumber(row.absolute) or 0) - have)
            if deficit > 0 then
                out[#out + 1] = {
                    kind = row.kind or "buy",
                    spec = row.spec,
                    role = row.role,
                    have = have,
                    need = row.absolute,
                    deficit = deficit,
                    specKey = specKey,
                    label = row.label,
                    name = row.label,
                    bottleGap = tonumber(row.bottleGap),
                }
            end
        end
        return out
    end

    local function SortBuyJobs(list)
        table.sort(list, function(a, b)
            local ar = (a and a.role) or ""
            local br = (b and b.role) or ""
            if ar == "container" and br ~= "container" then
                return true
            end
            if br == "container" and ar ~= "container" then
                return false
            end
            local ad = tonumber(a and a.deficit) or 0
            local bd = tonumber(b and b.deficit) or 0
            if ad ~= bd then
                return ad > bd
            end
            local al = ToNarrow(a and (a.label or a.name))
            local bl = ToNarrow(b and (b.label or b.name))
            return al < bl
        end)
    end

    local function BuildBuyPoolFromWatchEntries(entries)
        local buyPool = {}
        local function addBuyNeed(spec, role, craftsNeeded, slots, slot, bottleGap)
            if type(spec) ~= "table" then
                return
            end
            local kind = ClassifyBuyKind(spec)
            if kind == "convert" or kind == nil then
                return
            end
            if kind == "plant" and not allowPlantBuys then
                return
            end
            if kind ~= "buy" and kind ~= "plant" then
                return
            end
            local specKey = ""
            if MS and MS.Key then
                specKey = tostring(MS.Key(spec) or "")
            end
            if specKey == "" then
                specKey = ToNarrow(SpecJobLabel(spec))
            end
            local perCraft = 1
            if RS.EffectiveSpecPerCraft then
                perCraft = tonumber(RS.EffectiveSpecPerCraft(slot, slots)) or 1
            end
            if perCraft < 1 then
                perCraft = 1
            end
            local row = buyPool[specKey]
            if row == nil then
                row = {
                    spec = spec,
                    role = role or spec.role,
                    specKey = specKey,
                    absolute = 0,
                    label = SpecJobLabel(spec),
                    kind = kind,
                    bottleGap = nil,
                }
                buyPool[specKey] = row
            end
            row.absolute = (tonumber(row.absolute) or 0) + (craftsNeeded * perCraft)
            local gap = tonumber(bottleGap)
            if gap ~= nil and (row.bottleGap == nil or gap > row.bottleGap) then
                row.bottleGap = gap
            end
        end

        for i = 1, #entries do
            local entry = entries[i]
            local recipe = entry and entry.recipe
            local deficit = tonumber(entry and entry.deficit) or 0
            local bottleGap = tonumber(entry and entry.bottleGap)
            if deficit > 0 and type(recipe) == "table" then
                local craftsNeeded = RS.CraftsNeededForDeficit
                    and RS.CraftsNeededForDeficit(deficit, recipe)
                    or math.ceil(deficit / 2)
                local slots = recipe.slots or {}
                for j = 1, #slots do
                    local slot = slots[j]
                    local spec = type(slot) == "table" and (slot.spec or (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot))) or nil
                    addBuyNeed(
                        spec,
                        slot and (slot.role or (spec and spec.role)),
                        craftsNeeded,
                        slots,
                        slot,
                        bottleGap
                    )
                end
            end
        end
        return buyPool
    end

    local function FocusWatchEntries(focus)
        local entries = {}
        if type(focus) ~= "table" or type(focus.watches) ~= "table" then
            return entries
        end
        for i = 1, #focus.watches do
            local fw = focus.watches[i]
            if type(fw) == "table" and type(fw.recipe) == "table" then
                local stock = tonumber(fw.stock) or 0
                local target = tonumber(fw.target) or 0
                entries[#entries + 1] = {
                    recipe = fw.recipe,
                    deficit = math.max(0, target - stock),
                    bottleGap = tonumber(fw.bottleGap),
                }
            end
        end
        return entries
    end

    local function AllShortWatchEntries()
        local byUid = {}
        local uidOrder = {}
        for watchKey, watch in pairs(watches) do
            if type(watch) == "table" and watch.enabled == true then
                local resolved = RS.ResolveWatchPotion and RS.ResolveWatchPotion(watchKey)
                local potion = resolved and resolved.potion
                local recipe = ResolveWatchRecipe(watchKey, resolved)
                if type(potion) == "table" and type(recipe) == "table" then
                    local target = tonumber(watch.targetStock) or 0
                    local havePot = RS.PotionHaveCombined and RS.PotionHaveCombined(potion) or 0
                    local potDeficit = math.max(0, target - havePot)
                    local uid = tonumber(resolved and resolved.outputUid) or tonumber(potion.outputUid) or 0
                    if potDeficit > 0
                        and target > 0
                        and RS.WatchStillNeedsGrow
                        and RS.WatchStillNeedsGrow(potion, recipe, target, watchKey)
                    then
                        local craftable = RS.CountPotionsCraftable and RS.CountPotionsCraftable(recipe) or 0
                        local bottleGap = math.max(0, target - havePot - craftable)
                        local groupKey = uid
                        if groupKey <= 0 then
                            groupKey = watchKey
                        end
                        local group = byUid[groupKey]
                        if group == nil then
                            group = {
                                uid = uid,
                                have = havePot,
                                maxTarget = target,
                                primaryRecipe = recipe,
                                bottleGap = bottleGap,
                            }
                            byUid[groupKey] = group
                            uidOrder[#uidOrder + 1] = groupKey
                        else
                            if target > group.maxTarget then
                                group.maxTarget = target
                            end
                            if havePot < group.have then
                                group.have = havePot
                            end
                            if bottleGap > (tonumber(group.bottleGap) or 0) then
                                group.bottleGap = bottleGap
                                group.primaryRecipe = recipe
                            end
                        end
                    end
                end
            end
        end
        local entries = {}
        for i = 1, #uidOrder do
            local group = byUid[uidOrder[i]]
            entries[#entries + 1] = {
                recipe = group.primaryRecipe,
                deficit = math.max(0, group.maxTarget - group.have),
                bottleGap = tonumber(group.bottleGap),
            }
        end
        return entries
    end

    local focus = RS.CollectAutoBuyFocus and RS.CollectAutoBuyFocus() or nil
    local maxGap = type(focus) == "table" and tonumber(focus.maxBottleGap) or nil
    local focusCount = type(focus) == "table" and type(focus.watches) == "table" and #focus.watches or 0
    Planner._vendorBuyJobsMeta.maxBottleGap = maxGap
    Planner._vendorBuyJobsMeta.focusWatchCount = focusCount

    local source = "fallback"
    local buyPool = nil
    if focusCount > 0 then
        buyPool = BuildBuyPoolFromWatchEntries(FocusWatchEntries(focus))
        jobs = JobsFromBuyPool(buyPool)
        if #jobs > 0 then
            source = "focus"
        end
    end
    if source ~= "focus" then
        buyPool = BuildBuyPoolFromWatchEntries(AllShortWatchEntries())
        jobs = JobsFromBuyPool(buyPool)
        source = (#jobs > 0) and "fallback" or "none"
    end
    Planner._vendorBuyJobsMeta.source = source

    SortBuyJobs(jobs)
    return jobs
end

function Planner.DumpBrewPlan(emit)
    emit = type(emit) == "function" and emit or function(msg) StockPiler2.Debug.Print(msg) end
    if StockPiler2.Brew and StockPiler2.Brew.DumpPlan then
        StockPiler2.Brew.DumpPlan(emit)
        return
    end
    emit("=== StockPiler2 brew plan ===")
    emit("  (Brew.DumpPlan not loaded)")
    emit("=== end brew plan ===")
end
