----------------------------------------------------------------
-- Planner demand and focus policy
----------------------------------------------------------------

StockPiler2.Planner = StockPiler2.Planner or {}
local Planner = StockPiler2.Planner
local SpecDemand = Planner.SpecDemand or {}
Planner.SpecDemand = SpecDemand

local RS = StockPiler2.RecipeSpec
local MS = StockPiler2.MaterialSpec
local HC = Planner.SpecHaveCache

local function ToNarrow(text)
    return StockPiler2.ToNarrow(text)
end

local function EnsureSettings()
    if StockPiler2.EnsureSettings then
        return StockPiler2.EnsureSettings()
    end
    return StockPiler2.Settings
end

local function AutoGrowSeedLinesCacheKey()
    -- Perf: seed lines are structural (watch → recipe → seedUid/plantUid).
    -- Do NOT key on snapGen — every harvest loot snap used to invalidate and rebuild
    -- CollectAutoGrowSeedLines under Orchestrator.Tick (paired with Grow.BufferFlags
    -- at ~110–155ms). BufferFlags still uses snapGen (inventory-sensitive pending/short).
    -- Do not re-add snapGen here.
    local gardenGen = 0
    if StockPiler2.Garden then
        if StockPiler2.Garden.GetPlanGen then
            gardenGen = tonumber(StockPiler2.Garden.GetPlanGen()) or 0
        elseif StockPiler2.Garden.GetGen then
            gardenGen = tonumber(StockPiler2.Garden.GetGen()) or 0
        end
    end
    local watchGen = 0
    if StockPiler2.Watch and StockPiler2.Watch.GetGen then
        watchGen = tonumber(StockPiler2.Watch.GetGen()) or 0
    end
    local buffer = 5
    local enabled = "0"
    if StockPiler2.Watch then
        if StockPiler2.Watch.GetSeedBufferMin then
            buffer = tonumber(StockPiler2.Watch.GetSeedBufferMin()) or 5
        end
        if StockPiler2.Watch.IsSeedBufferEnabled
            and StockPiler2.Watch.IsSeedBufferEnabled() == true
        then
            enabled = "1"
        end
    end
    return tostring(gardenGen) .. ":" .. tostring(watchGen)
        .. ":" .. tostring(buffer) .. ":" .. enabled
end

--- Growable refinable seed/plant lines from AutoGrow-enabled watches, even when
--- Stock+Craftable already covers Target (seed-buffer maintenance set).
--- Excludes one-way / non-refinable harvest (no plant→seed refine path).
--- Cached per snap/garden/buffer settings (hot path: refine gates / intents).
function SpecDemand.CollectAutoGrowSeedLines()
    local Perf = StockPiler2.Perf
    local orchTick = tonumber(HC._orchTickId) or 0
    if orchTick > 0
        and HC._orchTickSeedLinesTick == orchTick
        and type(HC._orchTickSeedLines) == "table"
    then
        return HC._orchTickSeedLines
    end
    local cacheKey = AutoGrowSeedLinesCacheKey()
    if HC._autoGrowSeedLinesKey == cacheKey and type(HC._autoGrowSeedLines) == "table" then
        if orchTick > 0 then
            HC._orchTickSeedLines = HC._autoGrowSeedLines
            HC._orchTickSeedLinesTick = orchTick
        end
        return HC._autoGrowSeedLines
    end
    if Perf and Perf.Begin then
        Perf.Begin("CollectAutoGrowSeedLines")
    end
    local lines = {}
    local seen = {}
    local s = EnsureSettings()
    local SM = StockPiler2.SeedMap
    local MS = StockPiler2.MaterialSpec
    if type(s.watches) ~= "table" or type(SM) ~= "table" or not SM.IsGrowableSpec then
        HC._autoGrowSeedLinesKey = cacheKey
        HC._autoGrowSeedLines = lines
        if orchTick > 0 then
            HC._orchTickSeedLines = lines
            HC._orchTickSeedLinesTick = orchTick
        end
        if Perf and Perf.End then
            Perf.End("CollectAutoGrowSeedLines")
        end
        return lines
    end
    for watchKey, watch in pairs(s.watches) do
        if RS.WatchContributesGrowDemand(watchKey, watch) then
            local recipe = RS.RecipeSpecForPotion(watchKey)
            if RS.RecipeEligibleForGrow(recipe) then
                if RS.HydrateRecipeSlots then
                    RS.HydrateRecipeSlots(recipe)
                end
                local slots = recipe.slots or {}
                for i = 1, #slots do
                    local slot = slots[i]
                    local spec = slot and (slot.spec or (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)))
                    if type(spec) == "table" and SM.IsGrowableSpec(spec) then
                        if SM.IsOneWayHarvestSpec and SM.IsOneWayHarvestSpec(spec) == true then
                            -- One-way (e.g. Blackbell Powder): no refine path for buffer.
                        else
                            local productKey = (MS and MS.ProductKey and MS.ProductKey(spec))
                                or (MS and MS.Key and MS.Key(spec))
                                or ""
                            if productKey ~= "" and seen[productKey] ~= true then
                                local seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(spec)
                                local seedUid = 0
                                local plantUid = 0
                                if type(seed) == "table" then
                                    seedUid = tonumber(seed.uniqueID) or 0
                                    if seedUid <= 0 and type(seed.itemData) == "table" then
                                        seedUid = tonumber(seed.itemData.uniqueID) or 0
                                    end
                                    plantUid = tonumber(seed.plantUid) or 0
                                end
                                if plantUid <= 0 and SM.FindPlantUidForSpec then
                                    plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
                                end
                                if seedUid <= 0 and plantUid > 0 and SM.PickBestSeedUid then
                                    local seedUids = SM.GetSeedUidsForPlant and SM.GetSeedUidsForPlant(plantUid) or {}
                                    seedUid = tonumber(SM.PickBestSeedUid(plantUid, seedUids, spec)) or 0
                                end
                                -- Require a known plant↔seed refine path (non-refinable harvest excluded).
                                if seedUid > 0 and plantUid > 0 then
                                    seen[productKey] = true
                                    lines[#lines + 1] = {
                                        spec = spec,
                                        specKey = productKey,
                                        seedUid = seedUid,
                                        plantUid = plantUid,
                                        seed = seed,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    HC._autoGrowSeedLinesKey = cacheKey
    HC._autoGrowSeedLines = lines
    orchTick = tonumber(HC._orchTickId) or 0
    if orchTick > 0 then
        HC._orchTickSeedLines = lines
        HC._orchTickSeedLinesTick = orchTick
    end
    if Perf and Perf.End then
        Perf.End("CollectAutoGrowSeedLines")
    end
    return lines
end

-- AutoGrow watches still below target, with the largest bottle gap
-- (Target - Stock - Craftable). Plot assignment prefers these recipes so a
-- zero-craftable watch is not starved by another watch's shared plants.
-- Perf: cached per snapGen:watchGen; orch-tick alias shares one result per Tick
-- (BeginOrchTick). Without orch-tick reuse, Tick called focus multiple times.
-- Do not drop the _orchTickFocus short-circuit.
function SpecDemand.CollectAutoGrowFocus()
    local orchTick = tonumber(HC._orchTickId) or 0
    if orchTick > 0
        and HC._orchTickFocusTick == orchTick
        and type(HC._orchTickFocus) == "table"
    then
        return HC._orchTickFocus
    end
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    local watchGen = 0
    if StockPiler2.Watch and StockPiler2.Watch.GetGen then
        watchGen = tonumber(StockPiler2.Watch.GetGen()) or 0
    end
    local cacheKey = tostring(snapGen) .. ":" .. tostring(watchGen)
    if type(HC._autoGrowFocusCache) == "table" and HC._autoGrowFocusKey == cacheKey then
        if orchTick > 0 then
            HC._orchTickFocus = HC._autoGrowFocusCache
            HC._orchTickFocusTick = orchTick
        end
        return HC._autoGrowFocusCache
    end
    local s = EnsureSettings()
    local focus = {
        maxBottleGap = nil,
        minCraftable = nil, -- legacy alias: craftable of a max-gap watch
        watches = {},
    }
    if type(s.watches) ~= "table" or type(s.knownPotions) ~= "table" then
        HC._autoGrowFocusCache = focus
        HC._autoGrowFocusKey = cacheKey
        if orchTick > 0 then
            HC._orchTickFocus = focus
            HC._orchTickFocusTick = orchTick
        end
        return focus
    end
    local candidates = {}
    for watchKey, watch in pairs(s.watches) do
        if RS.WatchContributesGrowDemand(watchKey, watch) then
            local resolved = RS.ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            local recipe = RS.RecipeSpecForPotion(watchKey)
            if type(potion) == "table" and RS.RecipeEligibleForGrow(recipe) then
                local target = tonumber(watch.targetStock) or 0
                local stock = RS.PotionHaveCombined(potion)
                local deficit = math.max(0, target - stock)
                if deficit > 0 and target > 0
                    and RS.WatchStillNeedsGrow(potion, recipe, target, watchKey)
                then
                    local craftable = RS.CountPotionsCraftable(recipe)
                    local bottleGap = math.max(0, target - stock - craftable)
                    candidates[#candidates + 1] = {
                        potionKey = watchKey,
                        potionBaseKey = resolved.potionKey,
                        recipeSpecKey = resolved.recipeSpecKey,
                        name = potion.name or L"",
                        nameNarrow = potion.nameNarrow or ToNarrow(potion.name),
                        craftable = craftable,
                        stock = stock,
                        target = target,
                        bottleGap = bottleGap,
                        recipe = recipe,
                    }
                    if focus.maxBottleGap == nil or bottleGap > focus.maxBottleGap then
                        focus.maxBottleGap = bottleGap
                    end
                end
            end
        end
    end
    local maxGap = tonumber(focus.maxBottleGap) or 0
    for i = 1, #candidates do
        if (tonumber(candidates[i].bottleGap) or 0) == maxGap then
            focus.watches[#focus.watches + 1] = candidates[i]
            local c = tonumber(candidates[i].craftable) or 0
            if focus.minCraftable == nil or c < focus.minCraftable then
                focus.minCraftable = c
            end
        end
    end
    HC._autoGrowFocusCache = focus
    HC._autoGrowFocusKey = cacheKey
    if orchTick > 0 then
        HC._orchTickFocus = focus
        HC._orchTickFocusTick = orchTick
    end
    return focus
end

-- Enabled watches still below target, with the largest bottle gap
-- (Target - Stock - Craftable). AutoBuy prefers mats for these recipes so a
-- zero-craftable watch is not starved by another watch closer to its target.
-- Independent of AutoGrow: does not require WatchContributesGrowDemand.
function SpecDemand.CollectAutoBuyFocus()
    local s = EnsureSettings()
    local focus = {
        maxBottleGap = nil,
        minCraftable = nil,
        watches = {},
    }
    if type(s.watches) ~= "table" or type(s.knownPotions) ~= "table" then
        return focus
    end
    local candidates = {}
    for watchKey, watch in pairs(s.watches) do
        if type(watch) == "table" and watch.enabled == true then
            local resolved = RS.ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            local recipe = nil
            if resolved and resolved.recipeSpecKey and RS.RecipeSpecForPotionRecipe then
                recipe = RS.RecipeSpecForPotionRecipe(resolved.recipeSpecKey)
            end
            if type(recipe) ~= "table" then
                recipe = RS.RecipeSpecForPotion(watchKey)
            end
            if type(potion) == "table" and type(recipe) == "table" then
                local target = tonumber(watch.targetStock) or 0
                local stock = RS.PotionHaveCombined(potion)
                local deficit = math.max(0, target - stock)
                if deficit > 0 and target > 0
                    and RS.WatchStillNeedsGrow(potion, recipe, target, watchKey)
                then
                    local craftable = RS.CountPotionsCraftable(recipe)
                    local bottleGap = math.max(0, target - stock - craftable)
                    candidates[#candidates + 1] = {
                        potionKey = watchKey,
                        potionBaseKey = resolved and resolved.potionKey or nil,
                        recipeSpecKey = resolved and resolved.recipeSpecKey or nil,
                        name = potion.name or L"",
                        nameNarrow = potion.nameNarrow or ToNarrow(potion.name),
                        craftable = craftable,
                        stock = stock,
                        target = target,
                        bottleGap = bottleGap,
                        recipe = recipe,
                    }
                    if focus.maxBottleGap == nil or bottleGap > focus.maxBottleGap then
                        focus.maxBottleGap = bottleGap
                    end
                end
            end
        end
    end
    local maxGap = tonumber(focus.maxBottleGap) or 0
    for i = 1, #candidates do
        if (tonumber(candidates[i].bottleGap) or 0) == maxGap then
            focus.watches[#focus.watches + 1] = candidates[i]
            local c = tonumber(candidates[i].craftable) or 0
            if focus.minCraftable == nil or c < focus.minCraftable then
                focus.minCraftable = c
            end
        end
    end
    return focus
end

function SpecDemand.FocusSpecKeys(focus)
    local keys = {}
    if type(focus) ~= "table" or type(focus.watches) ~= "table" or not MS or not MS.Key then
        return keys
    end
    for i = 1, #focus.watches do
        local slots = focus.watches[i].recipe and focus.watches[i].recipe.slots
        if type(slots) == "table" then
            for j = 1, #slots do
                local slot = slots[j]
                local spec = slot and (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot) or slot.spec)
                if type(spec) == "table" then
                    keys[MS.Key(spec)] = true
                end
            end
        end
    end
    return keys
end

function SpecDemand.FocusWatchNames(focus)
    if type(focus) ~= "table" or type(focus.watches) ~= "table" or #focus.watches == 0 then
        return L""
    end
    local text = L""
    for i = 1, #focus.watches do
        if i > 1 then
            text = text .. L", "
        end
        text = text .. (focus.watches[i].name or L"?")
    end
    return text
end

-- Plant/refine only when Cultivation is trained AND BOTH the global switch
-- and this potion's AutoGrow are on.
function SpecDemand.ShouldAutoGrowPotion(potionKey, watch)
    local Caps = StockPiler2.TradeSkillCaps
    if Caps and Caps.CanAutoGrow and Caps.CanAutoGrow() ~= true then
        return false
    end
    local s = EnsureSettings()
    if type(s) ~= "table" or s.autoGrowEnabled ~= true then
        return false
    end
    return RS.WatchContributesGrowDemand(potionKey, watch)
end

local function ByproductRoleRank(role)
    if role == "main" then
        return 1
    end
    if role == "stabilizer" or role == "goldweed" then
        return 2
    end
    return 3
end

local function RecipeSkillLevel(slots)
    local fromMain = 0
    local best = 0
    for j = 1, #slots do
        local spec = slots[j] and slots[j].spec
        if type(spec) == "table" then
            local lv = tonumber(spec.skillLevel) or 0
            if lv > best then
                best = lv
            end
            local role = slots[j].role or spec.role or ""
            if role == "main" and lv > fromMain then
                fromMain = lv
            end
        end
    end
    if fromMain > 0 then
        return fromMain
    end
    return best
end

local function EnsureConvertDemandRow(demand, spec)
    if type(spec) ~= "table" then
        return nil, nil
    end
    local specKey = MS.Key(spec)
    if specKey == nil or specKey == "" then
        return nil, nil
    end
    local row = demand[specKey]
    if row == nil then
        row = {
            spec = spec,
            specKey = specKey,
            role = spec.role,
            perCraft = 1,
            absolute = 0,
            brewAbsolute = 0,
            weighted = 0,
            watchNames = {},
            watchDetails = {},
            have = RS.CountItemsMatchingSpec(spec),
        }
        demand[specKey] = row
    end
    if row.brewAbsolute == nil then
        row.brewAbsolute = tonumber(row.absolute) or 0
    end
    return row, specKey
end

local function InflateConvertGrowRow(row, byproductItemsShort)
    if type(row) ~= "table" or (tonumber(byproductItemsShort) or 0) <= 0 then
        return
    end
    if row.brewAbsolute == nil then
        row.brewAbsolute = tonumber(row.absolute) or 0
    end
    row.byproductConvertExtra = (tonumber(row.byproductConvertExtra) or 0)
        + byproductItemsShort
    row.absolute = (tonumber(row.absolute) or 0) + byproductItemsShort
    row.deficit = math.max(0, row.absolute - (tonumber(row.have) or 0))
    local pc = tonumber(row.perCraft) or 1
    if pc < 1 then
        pc = 1
    end
    row.craftsHave = math.floor((tonumber(row.have) or 0) / pc)
    row.craftsNeeded = math.ceil((tonumber(row.absolute) or 0) / pc)
    row.craftsShort = math.max(0, row.craftsNeeded - row.craftsHave)
end

-- Sum ingredient need across every watched potion that should AutoGrow.
-- Shared specs share one bag count; deficit = total need − have.
function SpecDemand.BuildBalancedSpecDemand()
    local Perf = StockPiler2.Perf
    local orchTick = tonumber(HC._orchTickId) or 0
    if orchTick > 0
        and HC._orchTickDemandTick == orchTick
        and type(HC._orchTickDemand) == "table"
    then
        return HC._orchTickDemand
    end
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    local watchGen = 0
    if StockPiler2.Watch and StockPiler2.Watch.GetGen then
        watchGen = tonumber(StockPiler2.Watch.GetGen()) or 0
    end
    local cacheKey = tostring(snapGen) .. ":" .. tostring(watchGen)
    if type(HC._demandCache) == "table" and HC._demandSnapGen == cacheKey then
        if orchTick > 0 then
            HC._orchTickDemand = HC._demandCache
            HC._orchTickDemandTick = orchTick
        end
        return HC._demandCache
    end
    if Perf and Perf.Begin then
        Perf.Begin("BuildBalancedSpecDemand")
    end
    -- Do not wipe _specHaveCache here — Planner.Build / WarmSpecHaveCache owns snapGen keying.
    local s = EnsureSettings()
    local demand = {}
    if type(s.watches) ~= "table" or type(s.knownPotions) ~= "table" then
        HC._demandCache = demand
        HC._demandSnapGen = cacheKey
        if orchTick > 0 then
            HC._orchTickDemand = demand
            HC._orchTickDemandTick = orchTick
        end
        if Perf and Perf.End then
            Perf.End("BuildBalancedSpecDemand")
        end
        return demand
    end
    local watchPass = {}
    -- When multiple recipe-watches share an outputUid, count bag deficit once
    -- (max target) and use the first enabled watch's recipe for planting.
    local byUid = {}
    local uidOrder = {}
    for watchKey, watch in pairs(s.watches) do
        if RS.WatchContributesGrowDemand(watchKey, watch) then
            local resolved = RS.ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            local recipe = RS.RecipeSpecForPotion(watchKey)
            if type(potion) == "table" and RS.RecipeEligibleForGrow(recipe) then
                local uid = tonumber(resolved.outputUid) or tonumber(potion.outputUid) or 0
                local target = tonumber(watch.targetStock) or 0
                local have = RS.PotionHaveCombined(potion)
                local deficit = math.max(0, target - have)
                if uid > 0 and deficit > 0 and target > 0
                    and RS.WatchStillNeedsGrow(potion, recipe, target, watchKey)
                then
                    local group = byUid[uid]
                    if group == nil then
                        group = {
                            uid = uid,
                            have = have,
                            maxTarget = target,
                            primaryKey = watchKey,
                            primaryRecipe = recipe,
                            potion = potion,
                            extras = 0,
                        }
                        byUid[uid] = group
                        uidOrder[#uidOrder + 1] = uid
                    else
                        if target > group.maxTarget then
                            group.maxTarget = target
                        end
                        group.extras = group.extras + 1
                    end
                end
            end
        end
    end
    for i = 1, #uidOrder do
        local group = byUid[uidOrder[i]]
        local potion = group.potion
        local recipe = group.primaryRecipe
        local potionKey = group.primaryKey
        local target = group.maxTarget
        local have = group.have
        local deficit = math.max(0, target - have)
        if deficit > 0 and type(recipe) == "table" then
            local weight = deficit / target
            local yield = RS.RecipeOutputYield(recipe, group.uid)
            local craftsNeeded = RS.CraftsNeededForDeficit(deficit, recipe)
            local slots = recipe.slots or {}
            watchPass[#watchPass + 1] = {
                recipe = recipe,
                yield = yield,
                slots = slots,
                potionHave = have,
                potionTarget = target,
                potionDeficit = deficit,
                potionKey = potionKey,
            }
            for j = 1, #slots do
                local slot = slots[j]
                local spec = slot.spec
                if type(spec) == "table" then
                    local specKey = MS.Key(spec)
                    local perCraft = RS.EffectiveSpecPerCraft(slot, slots)
                    local absNeed = craftsNeeded * perCraft
                    local row = demand[specKey]
                    if row == nil then
                        row = {
                            spec = spec,
                            specKey = specKey,
                            role = slot.role,
                            perCraft = perCraft,
                            absolute = 0,
                            weighted = 0,
                            watchNames = {},
                            watchDetails = {},
                        }
                        demand[specKey] = row
                    end
                    if perCraft > (row.perCraft or 0) then
                        row.perCraft = perCraft
                    end
                    row.absolute = row.absolute + absNeed
                    row.weighted = row.weighted + (weight * perCraft)
                    local watchName = potion.name or towstring(tostring(potionKey))
                    if group.extras > 0 then
                        watchName = watchName
                            .. L" (+"
                            .. towstring(tostring(group.extras))
                            .. L" recipe watch)"
                    end
                    local already = false
                    for w = 1, #(row.watchDetails) do
                        if row.watchDetails[w].potionKey == potionKey then
                            already = true
                            break
                        end
                    end
                    if already ~= true then
                        row.watchNames[#row.watchNames + 1] = watchName
                        row.watchDetails[#row.watchDetails + 1] = {
                            potionKey = potionKey,
                            name = watchName,
                            have = have,
                            target = target,
                            deficit = deficit,
                        }
                    end
                end
            end
        end
    end
    -- One bag walk for all demand specs before per-row have fills.
    HC.WarmSpecHaveCache(demand)
    for _, row in pairs(demand) do
        row.have = RS.CountItemsMatchingSpec(row.spec)
        row.deficit = math.max(0, row.absolute - row.have)
        local pc = tonumber(row.perCraft) or 1
        if pc < 1 then
            pc = 1
        end
        row.perCraft = pc
        row.craftsHave = math.floor((row.have or 0) / pc)
        row.craftsNeeded = math.ceil((row.absolute or 0) / pc)
        row.craftsShort = math.max(0, row.craftsNeeded - row.craftsHave)
        -- brewAbsolute stays brew-only; convert surplus uses this so extras
        -- grown for Arboreal Resin (etc.) can actually be refined.
        row.brewAbsolute = row.absolute
    end

    -- Resin / refine byproducts are not plantable. When a recipe is short on
    -- them, grow extra of that recipe's other plants and convert the surplus
    -- (plant→seed typically yields resin). If the recipe has no growable
    -- ingredients, prefer same-level extenders, then any seed already in bags
    -- at that crafting level.
    for i = 1, #watchPass do
        local rec = watchPass[i]
        local slots = rec.slots or {}
        local craftsNeeded = RS.CraftsNeededForDeficit(rec.potionDeficit, rec.recipe)
        local byproductItemsShort = 0
        local preferredKey = nil
        local preferredRank = 99
        for j = 1, #slots do
            local slot = slots[j]
            local spec = slot.spec
            if type(spec) == "table" then
                if StockPiler2.SeedMap and StockPiler2.SeedMap.MaybeLearnHarvestByproduct then
                    StockPiler2.SeedMap.MaybeLearnHarvestByproduct(nil, spec)
                end
                local isByproduct = StockPiler2.SeedMap
                    and StockPiler2.SeedMap.IsHarvestByproduct
                    and StockPiler2.SeedMap.IsHarvestByproduct(spec) == true
                local perCraft = RS.EffectiveSpecPerCraft(slot, slots)
                if perCraft < 1 then
                    perCraft = 1
                end
                local specKey = MS.Key(spec)
                local row = demand[specKey]
                local have = type(row) == "table" and (tonumber(row.have) or 0)
                    or RS.CountItemsMatchingSpec(spec)
                local need = craftsNeeded * perCraft
                local deficit = math.max(0, need - have)
                if isByproduct then
                    if deficit > byproductItemsShort then
                        byproductItemsShort = deficit
                    end
                elseif MS.IsGrowable(spec) == true then
                    local rank = ByproductRoleRank(slot.role or spec.role)
                    if rank < preferredRank then
                        preferredRank = rank
                        preferredKey = specKey
                    end
                end
            end
        end
        if byproductItemsShort > 0 then
            local row = preferredKey ~= nil and demand[preferredKey] or nil
            if type(row) ~= "table"
                and StockPiler2.SeedMap
                and StockPiler2.SeedMap.FindByproductConvertGrowSpec
            then
                local fallback = StockPiler2.SeedMap.FindByproductConvertGrowSpec(
                    RecipeSkillLevel(slots)
                )
                row = EnsureConvertDemandRow(demand, fallback)
            end
            InflateConvertGrowRow(row, byproductItemsShort)
        end
    end

    for i = 1, #watchPass do
        local rec = watchPass[i]
        local craftsPossible = RS.CountCraftsPossible(rec.recipe)
        local watchCraftable = craftsPossible * rec.yield
        local slots = rec.slots or {}
        for j = 1, #slots do
            local slot = slots[j]
            local spec = slot.spec
            if type(spec) == "table" then
                local specKey = MS.Key(spec)
                local row = demand[specKey]
                if type(row) == "table" then
                    local pc = RS.EffectiveSpecPerCraft(slot, slots)
                    if pc < 1 then
                        pc = 1
                    end
                    local slotCrafts = math.floor((tonumber(row.have) or 0) / pc)
                    if slotCrafts <= craftsPossible then
                        local prev = tonumber(row.minWatchCraftable)
                        local stock = tonumber(rec.potionHave) or 0
                        if prev == nil or watchCraftable < prev then
                            row.minWatchCraftable = watchCraftable
                            row.minWatchStock = stock
                        elseif watchCraftable == prev then
                            local prevStock = tonumber(row.minWatchStock)
                            if prevStock == nil or stock < prevStock then
                                row.minWatchStock = stock
                            end
                        end
                    end
                end
            end
        end
    end
    HC._demandCache = demand
    HC._demandSnapGen = cacheKey
    local orchTickEnd = tonumber(HC._orchTickId) or 0
    if orchTickEnd > 0 then
        HC._orchTickDemand = demand
        HC._orchTickDemandTick = orchTickEnd
    end
    if Perf and Perf.End then
        Perf.End("BuildBalancedSpecDemand")
    end
    return demand
end

Planner.BuildBalancedSpecDemand = SpecDemand.BuildBalancedSpecDemand
Planner.CollectAutoGrowSeedLines = SpecDemand.CollectAutoGrowSeedLines
Planner.CollectAutoGrowFocus = SpecDemand.CollectAutoGrowFocus
Planner.CollectAutoBuyFocus = SpecDemand.CollectAutoBuyFocus
Planner.FocusSpecKeys = SpecDemand.FocusSpecKeys
Planner.FocusWatchNames = SpecDemand.FocusWatchNames
Planner.ShouldAutoGrowPotion = SpecDemand.ShouldAutoGrowPotion
