----------------------------------------------------------------
-- StockPiler2 Planner — pure policy (scaffold; cache by store gens)
----------------------------------------------------------------

StockPiler2.Planner = StockPiler2.Planner or {}
local Planner = StockPiler2.Planner

local function T(key, tokens)
    if StockPiler2.T then
        return StockPiler2.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

-- Engine gather label is wstring; compare/display via T so English TradeSkillCaps still match.
local CULT_NAME = T("plan.fallback.cultivation")

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
            row.statusText = T("plan.status.restocking")
        else
            -- Growable short but AutoGrow off: user must enable AutoGrow (not a buy shortage).
            row.statusKey = "enable_autogrow"
            row.statusText = T("plan.status.enable_autogrow")
        end
    else
        row.statusKey = "buy_ingredients"
        row.statusText = buyLabel or T("plan.status.buy_plants")
    end
    if detail ~= nil then
        row.statusDetail = detail
    end
end

local function ApplyNeedApothecaryStatus(row)
    local Caps = StockPiler2.TradeSkillCaps
    -- Avoid false "Need Apothecary" while tradeSkills are still 0 at login.
    if Caps and Caps.AreTradeSkillsReady and Caps.AreTradeSkillsReady() ~= true then
        return
    end
    if CanBrewPotionsSkill() then
        return
    end
    if row.statusKey ~= "ready_to_craft" and row.statusKey ~= "ready_to_craft_shared" then
        return
    end
    row.statusKey = "need_apothecary"
    row.statusText = T("plan.status.need_apothecary")
    local lines = {
        T("plan.line.ready_apo_only"),
    }
    if Caps and Caps.HasTalisman and Caps.HasTalisman() == true then
        lines[#lines + 1] = T("plan.line.talisman_maker")
    end
    row.statusLines = lines
end

--- Max Apothecary / Cultivation skillLevel required by recipe slots.
local function RecipeSkillReqs(recipe)
    local reqApo = 0
    local reqCult = 0
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return reqApo, reqCult
    end
    local MS = StockPiler2.MaterialSpec
    local RS = StockPiler2.RecipeSpec
    for i = 1, #recipe.slots do
        local slot = recipe.slots[i]
        local spec = slot and slot.spec
        if type(spec) ~= "table" and slot and RS and RS.ResolveSlotSpec then
            spec = RS.ResolveSlotSpec(slot)
        end
        if type(spec) == "table" then
            local lv = tonumber(spec.skillLevel) or 0
            if lv > reqApo then
                reqApo = lv
            end
            local growable = MS and MS.IsGrowable and MS.IsGrowable(spec) == true
            if growable and lv > reqCult then
                reqCult = lv
            end
        end
    end
    return reqApo, reqCult
end

--- Override status when recipe mats exceed player Cultivation / Apothecary levels.
local function ApplyNeedSkillStatus(row)
    if type(row) ~= "table" then
        return
    end
    local Caps = StockPiler2.TradeSkillCaps
    -- Login: Apo/Cult often read 0 until TRADE_SKILL_UPDATED — skip false need_skill.
    if Caps and Caps.AreTradeSkillsReady and Caps.AreTradeSkillsReady() ~= true then
        return
    end
    local key = tostring(row.statusKey or "")
    if key == "potion_stocked" or key == "no_target" or key == "no_recipe" then
        return
    end
    local recipe = row.recipe
    if type(recipe) ~= "table" then
        return
    end
    local reqApo, reqCult = RecipeSkillReqs(recipe)
    local haveApo = Caps and Caps.ApothecaryLevel and Caps.ApothecaryLevel() or 0
    local haveCult = Caps and Caps.CultivationLevel and Caps.CultivationLevel() or 0
    haveApo = tonumber(haveApo) or 0
    haveCult = tonumber(haveCult) or 0
    local apoShort = reqApo > 0 and haveApo < reqApo
    local cultShort = reqCult > 0 and haveCult < reqCult
    if not apoShort and not cultShort then
        return
    end
    row.skillReqApo = reqApo
    row.skillReqCult = reqCult
    row.skillHaveApo = haveApo
    row.skillHaveCult = haveCult
    row.statusKey = "need_skill"
    if apoShort and cultShort then
        local req = math.max(reqApo, reqCult)
        row.statusText = T("plan.status.need_apo_cult", { req = tostring(req) })
    elseif apoShort then
        row.statusText = T("plan.status.need_apo_level", { req = tostring(reqApo) })
    else
        row.statusText = T("plan.status.need_cult_level", { req = tostring(reqCult) })
    end
    local lines = {}
    if apoShort then
        lines[#lines + 1] = T("plan.line.apo_skill_short", {
            have = tostring(haveApo),
            need = tostring(reqApo),
        })
    end
    if cultShort then
        lines[#lines + 1] = T("plan.line.cult_skill_short", {
            have = tostring(haveCult),
            need = tostring(reqCult),
        })
    end
    if apoShort and cultShort then
        lines[#lines + 1] = T("plan.line.skill_up_both")
    elseif apoShort then
        lines[#lines + 1] = T("plan.line.skill_up_apo")
    else
        lines[#lines + 1] = T("plan.line.skill_up_cult_buy")
    end
    row.statusLines = lines
end

-- Red traffic-light statusKeys (TabWatch STATUS_COLORS COLOR_BLOCK).
local RED_STATUS_KEYS = {
    no_recipe = true,
    enable_autogrow = true,
    need_apothecary = true,
    need_skill = true,
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
    need_skill = true,
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
    local Caps = StockPiler2.TradeSkillCaps
    local skillsReady = not Caps or not Caps.AreTradeSkillsReady
        or Caps.AreTradeSkillsReady() == true
    local prev = Planner._watchBlockOnceKeys or {}
    local now = {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local statusKey = tostring(row.statusKey or "")
            -- Skill-gate chat waits until tradeSkills are populated (see AreTradeSkillsReady).
            if (statusKey == "need_skill" or statusKey == "need_apothecary")
                and skillsReady ~= true
            then
                -- skip
            elseif RED_STATUS_KEYS[statusKey] == true then
                local watchKey = tostring(row.potionKey or row.id or i)
                local onceKey = "watch-block:" .. watchKey .. ":" .. statusKey
                now[watchKey] = onceKey
                local name = row.name
                if name == nil or name == L"" then
                    name = T("watch.fallback")
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

--- Once when every enabled plan row is true green AND at least one is ready_to_craft;
--- clear when any leaves green (or none need craft). Pure potion_stocked is not "ready to craft".
--- Also wait for Seed Buffer — same gate as brew-ready / AutoGrow idle.
local function NotifyAllWatchesReady(rows)
    local D = StockPiler2.Debug
    if not D then
        return
    end
    local any = false
    local allGreen = true
    local anyReadyToCraft = false
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            any = true
            local statusKey = tostring(row.statusKey or "")
            if TRUE_GREEN_STATUS_KEYS[statusKey] ~= true then
                allGreen = false
                break
            end
            if statusKey == "ready_to_craft" then
                anyReadyToCraft = true
            end
        end
    end
    -- Only pay CollectAutoGrowSeedLines (via IsSeedBufferSatisfied) when rows are green.
    if any and allGreen and anyReadyToCraft then
        local Grow = StockPiler2.Grow
        if Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied() ~= true then
            if D.ClearNotifyOnce then
                D.ClearNotifyOnce("watches-all-ready")
            end
            return
        end
        local printed = false
        if D.NotifyOnce then
            printed = D.NotifyOnce("watches-all-ready", T("plan.all_ready")) == true
        elseif D.Notify then
            D.Notify(T("plan.all_ready"))
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
    local msg = T("plan.autogrow_idle", { summary = summary })
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

--- Yellow Seed buffer when AutoGrow + buffer on and this recipe's seed lines are short.
--- Shared by stocked and covered Ready paths (display only; Brew gates unchanged).
local function TryApplySeedBufferShortStatus(row, recipe, potionKey)
    local RS = StockPiler2.RecipeSpec
    if not (RS and RS.ShouldAutoGrowPotion and RS.ShouldAutoGrowPotion(potionKey, nil) == true) then
        return false
    end
    if not (StockPiler2.Watch
        and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true)
    then
        return false
    end
    if not (RS.WatchHasSeedBufferShort and RS.WatchHasSeedBufferShort(recipe) == true) then
        return false
    end
    local buffer = StockPiler2.Watch.GetSeedBufferMin and StockPiler2.Watch.GetSeedBufferMin() or 5
    row.statusKey = "need_seeds"
    row.statusText = T("plan.status.seed_buffer")
    row.statusLines = {
        T("plan.line.seed_buffer_short", { buffer = tostring(buffer) }),
        T("plan.line.seed_buffer_grow"),
    }
    return true
end

--- True when AutoGrow can increase supply of this contested spec (grow/refine).
--- Containers and other non-growables return false (player buy).
local function SpecIsAutoGrowProgressable(spec, role)
    if role == "container" then
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

local function ContestedSlotLabel(spec)
    local MS = StockPiler2.MaterialSpec
    if MS and MS.NeedLabel then
        return MS.NeedLabel(spec)
    end
    if MS and MS.Label then
        return MS.Label(spec)
    end
    return T("plan.fallback.material")
end

--- When craftableShared, red Buy* only if every contested key is non-growable.
--- Any growable/buffer plant contest → nil (keep yellow Shared; AutoGrow still works).
--- Returns { role, have, need, label, buySeedOrMat, seedUid } or nil.
local function ContestedBuyOnlyInfo(row)
    local keys = row and row.contestedSpecKeys
    if type(keys) ~= "table" then
        return nil
    end
    local MS = StockPiler2.MaterialSpec
    local RS = StockPiler2.RecipeSpec
    if not (MS and MS.Key) then
        return nil
    end
    local firstBuy = nil
    local matched = {}

    local function consider(spec, role, have, need, buySeedOrMat, seedUid)
        if type(spec) ~= "table" then
            return false
        end
        local specKey = MS.Key(spec)
        if type(specKey) ~= "string" or keys[specKey] ~= true then
            return false
        end
        matched[specKey] = true
        if SpecIsAutoGrowProgressable(spec, role) then
            return true -- growable contest remains
        end
        if firstBuy == nil then
            firstBuy = {
                role = role,
                have = tonumber(have) or 0,
                need = tonumber(need) or 0,
                label = ContestedSlotLabel(spec),
                buySeedOrMat = buySeedOrMat == true,
                seedUid = tonumber(seedUid) or 0,
            }
        end
        return false
    end

    local tipSlots = row.statusTipSlots
    if type(tipSlots) == "table" then
        for i = 1, #tipSlots do
            local entry = tipSlots[i]
            if type(entry) == "table" and type(entry.spec) == "table" then
                if consider(entry.spec, entry.role, entry.have, entry.need,
                    entry.buySeedOrMat, entry.seedUid)
                then
                    return nil
                end
            end
        end
    end

    local recipe = row.recipe
    if type(recipe) == "table" then
        if RS and RS.HydrateRecipeSlots then
            RS.HydrateRecipeSlots(recipe)
        end
        local slots = recipe.slots
        if type(slots) == "table" then
            local crafts = tonumber(row.craftsClaim) or tonumber(row.craftsNeeded) or 0
            for i = 1, #slots do
                local slot = slots[i]
                if type(slot) == "table" then
                    local spec = slot.spec or (RS and RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot))
                    if type(spec) == "table" then
                        local specKey = MS.Key(spec)
                        if type(specKey) == "string" and keys[specKey] == true
                            and matched[specKey] ~= true
                        then
                            local perCraft = 1
                            if RS and RS.EffectiveSpecPerCraft then
                                perCraft = tonumber(RS.EffectiveSpecPerCraft(slot, slots)) or 1
                            end
                            local need = crafts * perCraft
                            local have = 0
                            if RS and RS.CountItemsMatchingSpec then
                                have = tonumber(RS.CountItemsMatchingSpec(spec)) or 0
                            end
                            if consider(spec, slot.role, have, need, false, 0) then
                                return nil
                            end
                        end
                    end
                end
            end
        end
    end

    -- Unmatched contested keys (e.g. seed-buffer): treat as AutoGrow-side → Shared.
    for specKey, v in pairs(keys) do
        if v == true and matched[specKey] ~= true then
            return nil
        end
    end
    return firstBuy
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
        row.statusText = T("plan.status.set_target")
        row.statusLines = { T("plan.line.set_target") }
        return
    end
    if recipe == nil then
        row.statusKey = "no_recipe"
        row.statusText = T("plan.status.learn_recipe")
        if CanBrewPotionsSkill() then
            row.statusLines = {
                T("plan.line.learn_recipe_apo"),
            }
        else
            row.statusLines = {
                T("plan.line.learn_recipe_need_apo"),
            }
        end
        return
    end
    if target.deficit <= 0 then
        -- Match Ready: green Potions stocked only when buffer maintenance for this
        -- AutoGrow watch is met; else yellow Seed buffer (Brew hold already global).
        if TryApplySeedBufferShortStatus(row, recipe, target.potionKey) then
            return
        end
        row.statusKey = "potion_stocked"
        row.statusText = T("plan.status.potions_stocked")
        row.statusLines = { T("plan.line.bag_at_target") }
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
        if TryApplySeedBufferShortStatus(row, recipe, target.potionKey) then
            return
        end
        row.statusKey = "ready_to_craft"
        row.statusText = T("plan.status.ready_to_craft")
        if CanBrewPotionsSkill() then
            row.statusLines = {
                T("plan.line.ready_open_apo"),
                T("plan.line.ready_rarities_note"),
            }
        else
            row.statusLines = {
                T("plan.line.ready_apo_only_covered"),
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

    local function matName(entry)
        if MS and MS.NeedLabel then
            return MS.NeedLabel(entry.spec)
        end
        if MS and MS.Label then
            return MS.Label(entry.spec)
        end
        return T("plan.fallback.material")
    end
    local function seedName(entry)
        if MS and MS.NeedLabel then
            return MS.NeedLabel(entry.spec, { asSeed = true, seed = entry.seed })
        end
        return T("plan.fallback.seed")
    end
    local lines = {
        T("plan.line.need_crafts", {
            crafts = tostring(craftsNeeded),
            deficit = tostring(target.deficit),
            yield = tostring(yield),
        }),
    }
    if wantsGrow ~= true then
        if CanAutoGrowSkill() then
            lines[#lines + 1] = T("plan.line.enable_autogrow_watch")
        else
            lines[#lines + 1] = T("plan.line.cult_required")
            local Caps = StockPiler2.TradeSkillCaps
            local gather = Caps and Caps.GatheringLabel and Caps.GatheringLabel()
            if gather ~= nil and gather ~= CULT_NAME then
                lines[#lines + 1] = T("plan.line.gathers_via", { gather = gather })
            end
        end
    end
    for i = 1, #plantShort do
        local entry = plantShort[i]
        local Grow = StockPiler2.Grow
        local notes = nil
        if Grow and Grow.GrowingNotesForSpec then
            notes = Grow.GrowingNotesForSpec(entry.spec)
            entry.growingNotes = notes or L""
        end
        local tokens = {
            mat = matName(entry),
            have = tostring(entry.have),
            need = tostring(entry.need),
        }
        if notes and notes ~= L"" then
            tokens.notes = notes
            if entry.needsRefine == true then
                lines[#lines + 1] = T("plan.line.refine_mat_notes", tokens)
            else
                lines[#lines + 1] = T("plan.line.plant_mat_notes", tokens)
            end
        elseif entry.needsRefine == true then
            lines[#lines + 1] = T("plan.line.refine_mat", tokens)
        else
            lines[#lines + 1] = T("plan.line.plant_mat", tokens)
        end
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
        if seedUid > 0 and StockPiler2.SeedMap and StockPiler2.SeedMap.FormatHarvestTooltipRateLines then
            local rateLines = StockPiler2.SeedMap.FormatHarvestTooltipRateLines(seedUid, plantUid)
            if type(rateLines) == "table" then
                for ri = 1, #rateLines do
                    if rateLines[ri] and rateLines[ri] ~= "" then
                        lines[#lines + 1] = towstring(rateLines[ri])
                    end
                end
            end
        elseif seedUid > 0 and StockPiler2.SeedMap and StockPiler2.SeedMap.FormatHarvestRateLine then
            local rateLine = StockPiler2.SeedMap.FormatHarvestRateLine(seedUid, plantUid)
            if type(rateLine) == "string" and rateLine ~= "" then
                lines[#lines + 1] = towstring(rateLine)
            end
        end
    end
    for i = 1, #convertShort do
        local entry = convertShort[i]
        local Refine = StockPiler2.Refine
        local canRefineNow = Refine and Refine.HasResinConvertFeedstock
            and Refine.HasResinConvertFeedstock() == true
        local tokens = {
            mat = matName(entry),
            have = tostring(entry.have),
            need = tostring(entry.need),
        }
        if canRefineNow then
            lines[#lines + 1] = T("plan.line.refine_surplus", tokens)
        else
            lines[#lines + 1] = T("plan.line.grow_then_convert", tokens)
        end
    end
    local buySeedOrMatShort = nil
    for i = 1, #buyShort do
        local entry = buyShort[i]
        if entry.buySeedOrMat == true then
            buySeedOrMatShort = buySeedOrMatShort or entry
            lines[#lines + 1] = T("plan.line.buy_seed_or_mat", {
                seed = seedName(entry),
                seedHave = tostring(entry.seedHave or 0),
                mat = matName(entry),
                have = tostring(entry.have),
                need = tostring(entry.need),
            })
        elseif entry.role == "container" then
            lines[#lines + 1] = T("plan.line.buy_flasks", {
                mat = matName(entry),
                have = tostring(entry.have),
                need = tostring(entry.need),
            })
        else
            lines[#lines + 1] = T("plan.line.buy_mat", {
                mat = matName(entry),
                have = tostring(entry.have),
                need = tostring(entry.need),
            })
        end
    end
    if #plantShort + #convertShort + #buyShort == 0 then
        lines[#lines + 1] = T("plan.line.mats_sufficient")
    end
    row.statusLines = lines
    row.statusNeedLine = lines[1]

    -- Byproduct convert only claims "Restocking" when AutoGrow can feed it:
    -- plant-kind deficits, seed credit, or refinable plant surplus for resin.
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
    if byproductShort ~= nil and not convertFeedable then
        local Refine = StockPiler2.Refine
        if Refine and Refine.HasResinConvertFeedstock
            and Refine.HasResinConvertFeedstock() == true
        then
            convertFeedable = true
        end
    end
    row.convertFeedable = convertFeedable == true
    if byproductShort ~= nil
        and convertFeedable
        and (limiting == nil or (byproductShort.craftsHave or 0) <= (limiting.craftsHave or 0))
    then
        row.growable = wantsGrow
        if wantsGrow == true and CanAutoGrowSkill()
            and StockPiler2.Refine and StockPiler2.Refine.HasResinConvertFeedstock
            and StockPiler2.Refine.HasResinConvertFeedstock() == true
            and limiting == nil
        then
            row.statusKey = "restocking"
            row.statusText = T("plan.status.refine_for_resin")
            row.statusDetail = lines[2] or lines[1]
            row.specDeficit = byproductShort
            return
        end
        SetMaterialsShortStatus(row, wantsGrow, lines[2] or lines[1], T("plan.status.buy_materials"))
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
                row.statusText = T("plan.status.seed_buffer")
            elseif CanAutoGrowSkill() and wantsGrow == true then
                row.statusKey = "restocking"
                row.statusText = T("plan.status.refine_plants")
            else
                SetMaterialsShortStatus(row, wantsGrow, lines[2] or lines[1], T("plan.status.buy_plants"))
            end
            row.statusDetail = lines[2] or lines[1]
            return
        end
        local buyLabel = T("plan.status.buy_plants")
        if limiting.buySeedOrMat == true
            and limiting.seedUid
            and tonumber(limiting.seedUid) > 0
        then
            buyLabel = T("plan.status.buy_seeds")
        end
        SetMaterialsShortStatus(row, wantsGrow, lines[2] or lines[1], buyLabel)
        return
    end
    if containerShort ~= nil then
        row.statusKey = "buy_ingredients"
        row.statusText = T("plan.status.buy_flasks")
        row.statusDetail = lines[2] or lines[1]
        return
    end
    if buySeedOrMatShort ~= nil then
        row.statusKey = "buy_ingredients"
        row.statusText = buySeedOrMatShort.seedUid and tonumber(buySeedOrMatShort.seedUid) > 0
            and T("plan.status.buy_seeds")
            or T("plan.status.buy_seed_or_mat")
        row.statusDetail = lines[2] or lines[1]
        row.specDeficit = buySeedOrMatShort
        return
    end
    if vendorShort ~= nil then
        row.statusKey = "buy_ingredients"
        row.statusText = T("plan.status.buy_materials")
        row.statusDetail = lines[2] or lines[1]
        return
    end
    -- Byproduct short but no seed/plant feedstock and no other buy shorts.
    if byproductShort ~= nil then
        row.statusKey = "buy_ingredients"
        row.statusText = T("plan.status.buy_materials")
        row.statusDetail = lines[2] or lines[1]
        row.specDeficit = byproductShort
        return
    end
    row.statusKey = "ready_to_craft"
    row.statusText = T("plan.status.ready_to_craft")
    row.statusSlots = nil
    if CanBrewPotionsSkill() then
        row.statusLines = { T("plan.line.ready_open_apo_short") }
    else
        row.statusLines = { T("plan.line.mats_ready_apo_only") }
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

local function SeedBufferTipSpecLabel(spec)
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

--- Snapshot-only payload for the Watch seed-buffer tooltip.
--- Heavy seed-line / refine intent collection belongs to Planner.Build, never hover.
local function BuildSeedBufferTipData()
    local RS = StockPiler2.RecipeSpec
    local Refine = StockPiler2.Refine
    local buffer = StockPiler2.Watch and StockPiler2.Watch.GetSeedBufferMin
        and StockPiler2.Watch.GetSeedBufferMin() or 5
    local enabled = StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true
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
                local rec = {
                    key = specKey,
                    spec = spec,
                    seedUid = seedUid,
                    name = SeedBufferTipSpecLabel(spec),
                    live = live,
                    ground = ground,
                    planned = planned,
                    total = credit,
                    shortBy = math.max(0, (tonumber(buffer) or 0) - credit),
                }
                byKey[specKey] = rec
                rows[#rows + 1] = rec
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
                local key = tostring((StockPiler2.MaterialSpec
                    and StockPiler2.MaterialSpec.ProductKey
                    and StockPiler2.MaterialSpec.ProductKey(spec)) or seedUid or i)
                local rec = intentsByKey[key]
                if rec == nil then
                    rec = {
                        key = key,
                        name = SeedBufferTipSpecLabel(spec),
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

function Planner.BuildWatchRows(ctx)
    local rows = {}
    local RS = StockPiler2.RecipeSpec
    local Perf = StockPiler2.Perf
    local targets = BuildWatchedTargets(ctx)
    local demand = nil
    local SpecDemand = Planner.SpecDemand
    if SpecDemand and SpecDemand.BuildBalancedSpecDemand then
        if Perf and Perf.Begin then
            Perf.Begin("Build.Demand")
        end
        demand = SpecDemand.BuildBalancedSpecDemand()
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
            -- Red Buy* only when contest is entirely non-growable (flasks / vendor mats).
            -- Any growable plant or seed-buffer contest → yellow Shared (AutoGrow still works).
            local buy = ContestedBuyOnlyInfo(row)
            if buy ~= nil then
                row.statusKey = "buy_ingredients"
                if buy.role == "container" then
                    row.statusText = T("plan.status.buy_flasks")
                    row.statusLines = {
                        T("plan.line.buy_flasks", {
                            mat = buy.label,
                            have = tostring(buy.have),
                            need = tostring(buy.need),
                        }),
                        T("plan.line.shared_buy_contested"),
                    }
                elseif buy.buySeedOrMat == true and buy.seedUid > 0 then
                    row.statusText = T("plan.status.buy_seeds")
                    row.statusLines = {
                        T("plan.line.buy_mat", {
                            mat = buy.label,
                            have = tostring(buy.have),
                            need = tostring(buy.need),
                        }),
                        T("plan.line.shared_buy_contested"),
                    }
                else
                    row.statusText = T("plan.status.buy_materials")
                    row.statusLines = {
                        T("plan.line.buy_mat", {
                            mat = buy.label,
                            have = tostring(buy.have),
                            need = tostring(buy.need),
                        }),
                        T("plan.line.shared_buy_contested"),
                    }
                end
            else
                row.statusKey = "ready_to_craft_shared"
                row.statusText = T("plan.status.shared_materials")
                row.statusLines = {
                    T("plan.line.shared_contested"),
                    T("plan.line.shared_autogrow"),
                }
            end
        elseif row.statusKey == "ready_to_craft" then
            row.statusLines = {
                T("plan.line.ready_uncontested"),
                T("plan.line.ready_use_brew"),
            }
        end
        ApplyNeedApothecaryStatus(row)
        ApplyNeedSkillStatus(row)

        -- Tip-ready full slot entries (stocked + short) so Status hover never rebuilds.
        local craftsNeeded = tonumber(row.craftsNeeded) or 0
        local recipe = row.recipe
        local recipeSlots = type(recipe) == "table" and recipe.slots or nil
        if type(recipe) == "table" then
            local tipSlots = {}
            if type(recipeSlots) == "table" and #recipeSlots > 0 then
                tipSlots = row.statusTipSlots
                if type(tipSlots) ~= "table" or #tipSlots == 0 then
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
            end
            row.statusTipSlots = tipSlots
        else
            row.statusTipSlots = nil
        end
    end
    local seedBufferTipData = BuildSeedBufferTipData()
    if Perf and Perf.End then
        Perf.End("Build.Tips")
    end
    if Perf and Perf.Begin then
        Perf.Begin("Build.Notify")
    end
    NotifyWatchRedBlocks(rows)
    NotifyAllWatchesReady(rows)
    NotifyAutoGrowIdleBlocked(rows)
    if Perf and Perf.End then
        Perf.End("Build.Notify")
    end
    return rows, seedBufferTipData
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

--- Gens that force a real plan rebuild (excludes bag snapGen). Cheap — no bag/plot copies.
local function NonSnapGensKey(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    return table.concat({
        tostring(ctx.gardenGen or 0),
        tostring(ctx.refineGen or 0),
        tostring(ctx.watchGen or 0),
        tostring(ctx.knowledgeGen or 0),
        tostring(ctx.settingsHash or 0),
    }, ":")
end

function Planner.NonSnapGensKey()
    local Garden = StockPiler2.Garden
    local RP = StockPiler2.RefinePipeline
    local Watch = StockPiler2.Watch
    local Know = StockPiler2.Knowledge
    return NonSnapGensKey({
        gardenGen = Garden and (Garden.GetPlanGen and Garden.GetPlanGen() or Garden.GetGen and Garden.GetGen()) or 0,
        refineGen = RP and RP.GetGen and RP.GetGen() or 0,
        watchGen = Watch and Watch.GetGen and Watch.GetGen() or 0,
        knowledgeGen = Know and Know.GetGen and Know.GetGen() or 0,
        settingsHash = Planner.SettingsHash(),
    })
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
    -- Perf: use nudge=true so repeated polls do not stretch _planAt forever (see
    -- Scheduler.EnqueuePlanRebuild PLAN_MAX_STRETCH / nudge). Do not call
    -- EnqueuePlanRebuild() without nudge from refresh=false paths.
    -- 0.4.122: vault/bank bag moves only bump snapGen — Stock overlay already live-patches
    -- counts. Do not nudge a full PlanRebuild when non-snap gens still match plan.ctx.
    if opts.refresh == false then
        local stale = PS and PS.Get and PS.Get()
        if type(stale) == "table" and type(stale.ctx) == "table" then
            local wantNonSnap = Planner.NonSnapGensKey and Planner.NonSnapGensKey() or nil
            if wantNonSnap ~= nil and NonSnapGensKey(stale.ctx) == wantNonSnap then
                return stale
            end
        end
        if Sch and Sch.EnqueuePlanRebuild then
            Sch.EnqueuePlanRebuild({ nudge = true })
        end
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
    local SpecHaveCache = Planner.SpecHaveCache
    if SpecHaveCache and SpecHaveCache.BeginPlanCraftsMemo then
        SpecHaveCache.BeginPlanCraftsMemo()
    end
    -- Perf: ClearPlanCaches BEFORE WarmHave so Have/plantUid resolve share one cache gen.
    -- Clearing after WarmHave used to discard warm work mid-build. Do not reorder.
    if StockPiler2.SeedMap and StockPiler2.SeedMap.ClearPlanCaches then
        StockPiler2.SeedMap.ClearPlanCaches()
    end
    -- One-pass have-cache for this snapGen (replaces blind wipe + per-spec bag walks).
    -- 0.4.132: skip when FrameWork prewarm already filled have-cache for this snap.
    if Perf and Perf.Begin then
        Perf.Begin("Build.WarmHave")
    end
    local RS = StockPiler2.RecipeSpec
    if SpecHaveCache and SpecHaveCache.IsHaveCacheWarmForSnap
        and SpecHaveCache.IsHaveCacheWarmForSnap() == true
    then
        -- prewarm hit — leave the spec-have cache as-is
    elseif SpecHaveCache and SpecHaveCache.WarmSpecHaveCacheForWatches then
        SpecHaveCache.WarmSpecHaveCacheForWatches()
    elseif SpecHaveCache then
        SpecHaveCache._specHaveCache = {}
        SpecHaveCache._specHaveSnapGen = nil
    end
    if Perf and Perf.End then
        Perf.End("Build.WarmHave")
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
    local rows, seedBufferTipData = Planner.BuildWatchRows(ctx)
    local plan = {
        planGen = planGen,
        cacheKey = key,
        ctx = ctx,
        rows = rows,
        seedBufferTipData = seedBufferTipData,
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
    -- Coalesce footer + brew-ready notify; do not run SyncActionReadiness inside Build.
    if StockPiler2Window and StockPiler2Window.RequestFooterRefresh then
        StockPiler2Window.RequestFooterRefresh()
    elseif StockPiler2.Brew and StockPiler2.Brew.MaybeNotifyBrewReady then
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
            local reqApo, reqCult = RecipeSkillReqs(recipe)
            local Caps = StockPiler2.TradeSkillCaps
            local haveApo = Caps and Caps.ApothecaryLevel and Caps.ApothecaryLevel() or 0
            local haveCult = Caps and Caps.CultivationLevel and Caps.CultivationLevel() or 0
            emit(string.format(
                "      skill apo=%s/%s cult=%s/%s",
                tostring(haveApo),
                tostring(reqApo),
                tostring(haveCult),
                tostring(reqCult)
            ))
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
        local CA = StockPiler2.CultivatorAdapter
        local unlocked = CA and CA.NumPlots and CA.NumPlots() or 4
        local maxSlots = CA and CA.MaxPlotSlots and CA.MaxPlotSlots() or 4
        emit(string.format("  unlockedPlots=%d maxSlots=%d cultSkill=%s",
            unlocked,
            maxSlots,
            tostring(StockPiler2.TradeSkillCaps and StockPiler2.TradeSkillCaps.CultivationLevel
                and StockPiler2.TradeSkillCaps.CultivationLevel())
        ))
        for plotNum = 1, maxSlots do
            local p = plots[plotNum]
            local pending = 0
            if StockPiler2.Grow and StockPiler2.Grow._pendingPlant then
                pending = tonumber(StockPiler2.Grow._pendingPlant[plotNum]) or 0
            end
            local locked = CA and CA.IsPlotLocked and CA.IsPlotLocked(plotNum)
            if type(p) == "table" then
                if p.locked ~= nil then
                    locked = p.locked == true
                end
                emit(string.format(
                    "  P%d stage=%d seedUid=%d plantUid=%d pending=%d locked=%s isPlotEmpty=%s",
                    plotNum,
                    tonumber(p.stage) or 0,
                    tonumber(p.seedUid) or 0,
                    tonumber(p.plantUid) or 0,
                    pending,
                    tostring(locked == true),
                    tostring(StockPiler2.Grow and StockPiler2.Grow.IsPlotEmpty
                        and StockPiler2.Grow.IsPlotEmpty(plotNum))
                ))
            else
                emit(string.format(
                    "  P%d (no cache) pending=%d locked=%s isPlotEmpty=%s",
                    plotNum,
                    pending,
                    tostring(locked == true),
                    tostring(StockPiler2.Grow and StockPiler2.Grow.IsPlotEmpty
                        and StockPiler2.Grow.IsPlotEmpty(plotNum))
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
    if StockPiler2.SeedMap and StockPiler2.SeedMap.DumpCraftCycleStats then
        StockPiler2.SeedMap.DumpCraftCycleStats(emit)
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
    return T("plan.fallback.material")
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

    local SpecDemand = Planner.SpecDemand
    local focus = SpecDemand and SpecDemand.CollectAutoBuyFocus
        and SpecDemand.CollectAutoBuyFocus() or nil
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
