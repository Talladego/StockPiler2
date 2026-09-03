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

local function SetMaterialsShortStatus(row, growable, detail)
    if growable == true then
        row.statusKey = "restocking"
        row.statusText = L"Restocking materials"
    else
        row.statusKey = "need_materials"
        row.statusText = L"Need materials"
    end
    if detail ~= nil then
        row.statusDetail = detail
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
    if oneWay and SM.ResolveSeedForSpec then
        seedRecord = SM.ResolveSeedForSpec(spec)
        if type(seedRecord) == "table" then
            seedHave = tonumber(seedRecord.count) or 0
        end
    end
    local craftsHave = perCraft > 0 and math.floor(have / perCraft) or 0
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
        oneWay = oneWay == true,
        seed = seedRecord,
        seedHave = seedHave,
        seedUid = type(seedRecord) == "table" and (tonumber(seedRecord.uniqueID) or 0) or 0,
    }
    if slot.role == "container" then
        entry.kind = "buy"
    elseif byproduct then
        entry.kind = "convert"
    elseif oneWay and deficit > 0 and seedHave <= 0 then
        -- One-way harvest mat with no seeds in bags: buy seed or buy material.
        entry.kind = "buy"
        entry.buySeedOrMat = true
    elseif growable or (oneWay and seedHave > 0) then
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
    if target.min <= 0 then
        row.statusKey = "no_target"
        row.statusText = L"Set target"
        row.statusLines = { L"Set a Target# for this potion." }
        return
    end
    if recipe == nil then
        row.statusKey = "no_recipe"
        row.statusText = L"Learn recipe"
        row.statusLines = {
            L"Learn this recipe at the Apothecary, then brew it once so StockPiler can store the slots.",
        }
        return
    end
    if target.deficit <= 0 then
        row.statusKey = "potion_stocked"
        row.statusText = L"Potions stocked"
        row.statusLines = { L"Bag count is at or above the target." }
        return
    end
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
        row.statusLines = {
            L"Stock + Craftable covers the target. Open the Apothecary to brew.",
            L"Potent / other rarities do not count. Growing resumes if stock is still short after brewing.",
        }
        return
    end
    local yield = RS.RecipeOutputYield and RS.RecipeOutputYield(recipe) or (tonumber(recipe.recipeYield) or 2)
    local craftsNeeded = RS.CraftsNeededForDeficit and RS.CraftsNeededForDeficit(target.deficit, recipe)
        or math.ceil(target.deficit / math.max(1, yield))
    row.recipeYield = yield
    row.stockYield = RS.WatchStockYield and RS.WatchStockYield(recipe) or 1
    row.craftsNeeded = craftsNeeded
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
    for i = 1, #slots do
        local entry = RecipeSlotPlanEntry(slots[i], slots, craftsNeeded, demand)
        if entry ~= nil and entry.deficit > 0 then
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
        lines[#lines + 1] = L"AutoGrow is off for this watch - materials will not be planted."
    end
    for i = 1, #plantShort do
        local entry = plantShort[i]
        local line = L"Plant " .. matName(entry) .. L" (" .. haveNeed(entry) .. L")"
        local Grow = StockPiler2.Grow
        if Grow and Grow.GrowingNotesForSpec then
            local notes = Grow.GrowingNotesForSpec(entry.spec)
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

    if byproductShort ~= nil
        and (limiting == nil or (byproductShort.craftsHave or 0) <= (limiting.craftsHave or 0))
    then
        row.growable = wantsGrow
        SetMaterialsShortStatus(row, wantsGrow, lines[2] or lines[1])
        row.specDeficit = byproductShort
        return
    end
    if limiting ~= nil then
        row.growable = wantsGrow
        row.specDeficit = limiting
        SetMaterialsShortStatus(row, wantsGrow, lines[2] or lines[1])
        return
    end
    if containerShort ~= nil then
        row.statusKey = "buy_flasks"
        row.statusText = L"Buy flasks"
        row.statusDetail = lines[2] or lines[1]
        return
    end
    if buySeedOrMatShort ~= nil then
        row.statusKey = "buy_ingredients"
        row.statusText = L"Buy seed or material"
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
    row.statusKey = "ready_to_craft"
    row.statusText = L"Ready to craft"
    row.statusSlots = nil
    row.statusLines = { L"Ready to craft. Open the Apothecary to brew." }
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
    local MS = StockPiler2.MaterialSpec
    local targets = BuildWatchedTargets(ctx)
    local watchMats = {} -- rowIdx -> { [specKey] = perCraft }
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
        ApplySpecPlanStatus(row, target, recipe, nil)
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
        local mats = {}
        if type(recipe) == "table" and type(recipe.slots) == "table" and MS and MS.Key then
            local slots = recipe.slots
            for s = 1, #slots do
                local slot = slots[s]
                local spec = slot and (slot.spec or (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)))
                if type(spec) == "table" then
                    local specKey = MS.Key(spec)
                    if type(specKey) == "string" and specKey ~= "" then
                        local perCraft = RS.EffectiveSpecPerCraft and RS.EffectiveSpecPerCraft(slot, slots) or 1
                        mats[specKey] = perCraft
                    end
                end
            end
        end
        watchMats[#rows + 1] = mats
        rows[#rows + 1] = row
    end
    -- Contested shared mats: bag stock cannot cover combined craftable claims.
    local matUsers = {}
    for i = 1, #rows do
        local mats = watchMats[i]
        if type(mats) == "table" then
            for specKey, perCraft in pairs(mats) do
                local list = matUsers[specKey]
                if list == nil then
                    list = {}
                    matUsers[specKey] = list
                end
                list[#list + 1] = {
                    rowIdx = i,
                    perCraft = tonumber(perCraft) or 1,
                    crafts = tonumber(rows[i].craftsPossible) or 0,
                }
            end
        end
    end
    for i = 1, #rows do
        local row = rows[i]
        local mats = watchMats[i]
        local contested = false
        if type(mats) == "table" and (tonumber(row.craftable) or 0) > 0 then
            for specKey, _ in pairs(mats) do
                local users = matUsers[specKey]
                if type(users) == "table" and #users > 1 then
                    local combinedNeed = 0
                    for u = 1, #users do
                        combinedNeed = combinedNeed + (users[u].crafts * users[u].perCraft)
                    end
                    local have = 0
                    if RS and RS.CountItemsMatchingSpec then
                        local sampleSpec = nil
                        local recipe = row.recipe
                        if type(recipe) == "table" and type(recipe.slots) == "table" then
                            for s = 1, #recipe.slots do
                                local slot = recipe.slots[s]
                                local spec = slot and (slot.spec or (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)))
                                if type(spec) == "table" and MS and MS.Key and MS.Key(spec) == specKey then
                                    sampleSpec = spec
                                    break
                                end
                            end
                        end
                        if type(sampleSpec) == "table" then
                            have = RS.CountItemsMatchingSpec(sampleSpec) or 0
                        end
                    end
                    if have < combinedNeed then
                        contested = true
                        break
                    end
                end
            end
        end
        row.craftableShared = contested
        if (tonumber(row.craftable) or 0) > 0 or row.hasRecipe then
            row.craftableText = towstring(tostring(row.craftable or 0))
        end
    end
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
    local key = Planner.CacheKeyFromGens()
    if PS and PS.GetCacheKey and PS.GetCacheKey() == key then
        local cached = PS.Get and PS.Get()
        if type(cached) == "table" then
            return cached
        end
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

--- Vendor buy list for every enabled watch below target.
--- Never plants, seeds, or refine byproducts — AutoGrow owns the growable pipeline.
function Planner.CollectVendorBuyJobs()
    local jobs = {}
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

    local buyPool = {}
    local function addBuyNeed(spec, role, craftsNeeded, slots, slot)
        if type(spec) ~= "table" then
            return
        end
        if ClassifyBuyKind(spec) ~= "buy" then
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
            }
            buyPool[specKey] = row
        end
        row.absolute = (tonumber(row.absolute) or 0) + (craftsNeeded * perCraft)
    end

    local byUid = {}
    local uidOrder = {}
    for watchKey, watch in pairs(watches) do
        if type(watch) == "table" and watch.enabled == true then
            local resolved = RS.ResolveWatchPotion and RS.ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            local recipe = nil
            if resolved and resolved.recipeSpecKey and RS.RecipeSpecForPotionRecipe then
                recipe = RS.RecipeSpecForPotionRecipe(resolved.recipeSpecKey)
            end
            if type(recipe) ~= "table" and RS.RecipeSpecForPotion then
                recipe = RS.RecipeSpecForPotion(watchKey)
            end
            if type(potion) == "table" and type(recipe) == "table" then
                local target = tonumber(watch.targetStock) or 0
                local havePot = RS.PotionHaveCombined and RS.PotionHaveCombined(potion) or 0
                local potDeficit = math.max(0, target - havePot)
                local uid = tonumber(resolved and resolved.outputUid) or tonumber(potion.outputUid) or 0
                if potDeficit > 0
                    and target > 0
                    and not (RS.WatchCoveredByBagsAndCraftable
                        and RS.WatchCoveredByBagsAndCraftable(potion, recipe, target))
                then
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
                    end
                end
            end
        end
    end

    for i = 1, #uidOrder do
        local group = byUid[uidOrder[i]]
        local recipe = group.primaryRecipe
        local deficit = math.max(0, group.maxTarget - group.have)
        if deficit > 0 and type(recipe) == "table" then
            local craftsNeeded = RS.CraftsNeededForDeficit
                and RS.CraftsNeededForDeficit(deficit, recipe)
                or math.ceil(deficit / 2)
            local slots = recipe.slots or {}
            for j = 1, #slots do
                local slot = slots[j]
                local spec = type(slot) == "table" and slot.spec or nil
                addBuyNeed(spec, slot and (slot.role or (spec and spec.role)), craftsNeeded, slots, slot)
            end
        end
    end

    for specKey, row in pairs(buyPool) do
        local have = 0
        if RS.CountItemsMatchingSpec then
            have = tonumber(RS.CountItemsMatchingSpec(row.spec)) or 0
        end
        local deficit = math.max(0, (tonumber(row.absolute) or 0) - have)
        if deficit > 0 then
            jobs[#jobs + 1] = {
                kind = "buy",
                spec = row.spec,
                role = row.role,
                have = have,
                need = row.absolute,
                deficit = deficit,
                specKey = specKey,
                label = row.label,
                name = row.label,
            }
        end
    end

    table.sort(jobs, function(a, b)
        local ar = (a and a.role) or ""
        local br = (b and b.role) or ""
        if ar == "container" and br ~= "container" then
            return true
        end
        if br == "container" and ar ~= "container" then
            return false
        end
        local al = ToNarrow(a and (a.label or a.name))
        local bl = ToNarrow(b and (b.label or b.name))
        if al ~= bl then
            return al < bl
        end
        return (tonumber(a and a.deficit) or 0) > (tonumber(b and b.deficit) or 0)
    end)
    return jobs
end

function Planner.DumpBrewPlan(emit)
    emit = type(emit) == "function" and emit or function(msg) StockPiler2.Debug.Print(msg) end
    emit("=== StockPiler2 brew plan (scaffold) ===")
    emit("  (brew planner not wired yet)")
    emit("=== end brew plan ===")
end
