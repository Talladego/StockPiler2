----------------------------------------------------------------
-- Planner spec-have cache and per-plan/per-orchestrator memos
----------------------------------------------------------------

StockPiler2.Planner = StockPiler2.Planner or {}
local Planner = StockPiler2.Planner
local SpecHaveCache = Planner.SpecHaveCache or {}
Planner.SpecHaveCache = SpecHaveCache

local RS = StockPiler2.RecipeSpec
local MS = StockPiler2.MaterialSpec

local function EnsureSettings()
    if StockPiler2.EnsureSettings then
        return StockPiler2.EnsureSettings()
    end
    return StockPiler2.Settings
end

local function CurrentSnapGen()
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        return tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    return 0
end

local function MarkHaveCacheWarmed(snapGen)
    SpecHaveCache._specHaveWarmedGen = tonumber(snapGen) or CurrentSnapGen()
    -- Last-complete survives EnsureSpecHaveCacheForSnap wipe on next snapGen bump.
    local cache = SpecHaveCache._specHaveCache
    if type(cache) == "table" then
        local copy = {}
        for k, v in pairs(cache) do
            copy[k] = v
        end
        SpecHaveCache._specHaveLastComplete = copy
        SpecHaveCache._specHaveLastCompleteSnapGen = SpecHaveCache._specHaveWarmedGen
    end
end

function SpecHaveCache.ClearCountCaches()
    SpecHaveCache._specHaveCache = {}
    SpecHaveCache._specHaveSnapGen = nil
    SpecHaveCache._specHaveWarmedGen = nil
    SpecHaveCache._specHaveLastComplete = nil
    SpecHaveCache._specHaveLastCompleteSnapGen = nil
    SpecHaveCache._warmHaveSlicing = nil
    SpecHaveCache._demandCache = nil
    SpecHaveCache._demandSnapGen = nil
    SpecHaveCache._autoGrowSeedLines = nil
    SpecHaveCache._autoGrowSeedLinesKey = nil
    SpecHaveCache._orchTickDemand = nil
    SpecHaveCache._orchTickDemandTick = nil
    SpecHaveCache._orchTickSeedLines = nil
    SpecHaveCache._orchTickSeedLinesTick = nil
    SpecHaveCache._craftsPossibleMemo = nil
    if RS then
        RS._expectedCraftableCache = nil
        RS._expectedCraftableSnapGen = nil
    end
end

--- Cleared at Planner.Build start; memoizes CountCraftsPossible (non-reserve) for the build.
function SpecHaveCache.BeginPlanCraftsMemo()
    SpecHaveCache._craftsPossibleMemo = {}
end

function SpecHaveCache.GetCraftsPossibleMemo()
    return SpecHaveCache._craftsPossibleMemo
end

function SpecHaveCache.SetCraftsPossibleMemo(key, value)
    if type(SpecHaveCache._craftsPossibleMemo) == "table" then
        SpecHaveCache._craftsPossibleMemo[key] = value
    end
end

local function SpecHaveBoundUid(spec)
    if type(spec) ~= "table" or spec.incomplete ~= true then
        return 0
    end
    return tonumber(spec.boundUid) or 0
end

--- Cultivated mains: SeedMap often knows plantUid even when bag ProductMatches fails
--- (engine plant CraftItemInfo omits EFFECT). CountByUid is authoritative for that plant.
--- Never call FindPlantUidForSpec here — that bag-walks and nested under WarmHave.
local function SpecHavePlantUid(spec)
    if type(spec) ~= "table" or tostring(spec.role or "") ~= "main" then
        return 0
    end
    local SM = StockPiler2.SeedMap
    if type(SM) ~= "table" then
        return 0
    end
    if SM.FindPlantUidForHave then
        return tonumber(SM.FindPlantUidForHave(spec)) or 0
    end
    if SM.CachedPlantUidForSpec then
        return tonumber(SM.CachedPlantUidForSpec(spec)) or 0
    end
    return 0
end

local function EnsureSpecHaveCacheForSnap()
    local snapGen = CurrentSnapGen()
    if type(SpecHaveCache._specHaveCache) ~= "table" or SpecHaveCache._specHaveSnapGen ~= snapGen then
        SpecHaveCache._specHaveCache = {}
        SpecHaveCache._specHaveSnapGen = snapGen
        -- Empty table for a new snap is NOT warm (0.4.155).
        SpecHaveCache._specHaveWarmedGen = nil
    end
    return SpecHaveCache._specHaveCache
end

local function ItemStackQty(item)
    local n = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
    if n < 1 then
        n = 1
    end
    return n
end

local function ItemUsableForSpecHave(item)
    if type(item) ~= "table" then
        return false
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.CanUseCraftingItem
        and not StockPiler2.Inventory.CanUseCraftingItem(item)
    then
        return false
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.IsSeedOrSporeItem
        and StockPiler2.Inventory.IsSeedOrSporeItem(item)
    then
        return false
    end
    return true
end

--- Thin / incomplete bag mains need ProductMatches enrichment; cannot Key-index them.
local function ProductNeedsEnrichMatch(product)
    if type(product) ~= "table" then
        return true
    end
    if product.incomplete == true then
        return true
    end
    if tostring(product.role or "") ~= "main" then
        return false
    end
    if (tonumber(product.slotType) or 0) <= 0 then
        return true
    end
    if type(product.bonuses) ~= "table" then
        return true
    end
    local stab = 1
    if StockPiler2.BrewLearn and StockPiler2.BrewLearn.CraftBonus then
        stab = tonumber(StockPiler2.BrewLearn.CraftBonus.STABILITY) or 1
    end
    if product.bonuses[stab] == nil then
        return true
    end
    return false
end

--- One bag walk: Key-index complete products (O(items+specs)); ProductMatches only for thin items.
--- specs: array of MaterialSpec tables, or map of rows with .spec, or map of specs.
function SpecHaveCache.WarmSpecHaveCache(specs)
    if type(specs) ~= "table" or not MS then
        return 0
    end
    if not MS.ProductMatches and not MS.Matches then
        return 0
    end
    local snapGen = CurrentSnapGen()
    local cache = EnsureSpecHaveCacheForSnap()
    local list = {}
    if specs[1] ~= nil then
        for i = 1, #specs do
            local v = specs[i]
            if type(v) == "table" then
                if type(v.spec) == "table" then
                    list[#list + 1] = v.spec
                else
                    list[#list + 1] = v
                end
            end
        end
    else
        for _, v in pairs(specs) do
            if type(v) == "table" then
                if type(v.spec) == "table" then
                    list[#list + 1] = v.spec
                else
                    list[#list + 1] = v
                end
            end
        end
    end
    local pending = {}
    local pendingKeys = {}
    local filled = 0
    for i = 1, #list do
        local spec = list[i]
        local specKey = MS.Key and MS.Key(spec) or nil
        if specKey ~= nil and cache[specKey] == nil then
            local boundUid = SpecHaveBoundUid(spec)
            if boundUid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUid then
                cache[specKey] = tonumber(StockPiler2.Inventory.CountByUid(boundUid)) or 0
                filled = filled + 1
            elseif pendingKeys[specKey] ~= true then
                pendingKeys[specKey] = true
                pending[#pending + 1] = { key = specKey, spec = spec }
            end
        end
    end
    if #pending == 0 then
        MarkHaveCacheWarmed(snapGen)
        return filled
    end
    -- Perf: only Mark when the bag walk runs (prewarm/WarmHave cache miss).
    if StockPiler2.Perf and StockPiler2.Perf.Mark then
        StockPiler2.Perf.Mark("WarmHave.miss")
    end
    for i = 1, #pending do
        -- Do not pre-write 0 into live cache — readers would treat it as filled.
        local spec = pending[i].spec
        local target = nil
        if MS.AsApothecaryProduct then
            target = MS.AsApothecaryProduct(spec, spec and spec.role)
        end
        pending[i].target = target
        if type(target) == "table" and target.incomplete ~= true and MS.Key then
            pending[i].targetKey = MS.Key(target)
        else
            pending[i].targetKey = nil
        end
    end

    -- Single bag pass: index complete products by Key; keep thin items for ProductMatches.
    local byKey = {}
    local thin = {}
    local allBag = {}
    local anyNoKey = false
    for i = 1, #pending do
        if pending[i].targetKey == nil or pending[i].targetKey == "" then
            anyNoKey = true
            break
        end
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if not ItemUsableForSpecHave(item) then
                return
            end
            local qty = ItemStackQty(item)
            if anyNoKey then
                allBag[#allBag + 1] = { item = item, qty = qty }
            end
            local product = nil
            if MS.AsApothecaryProduct then
                product = MS.AsApothecaryProduct(item)
            end
            if type(product) ~= "table" or ProductNeedsEnrichMatch(product) then
                thin[#thin + 1] = { item = item, qty = qty }
                return
            end
            local k = MS.Key and MS.Key(product) or nil
            if k ~= nil and k ~= "" then
                byKey[k] = (tonumber(byKey[k]) or 0) + qty
            else
                thin[#thin + 1] = { item = item, qty = qty }
            end
        end)
    end

    for i = 1, #pending do
        local entry = pending[i]
        local total = 0
        if entry.targetKey ~= nil and entry.targetKey ~= "" then
            total = tonumber(byKey[entry.targetKey]) or 0
            -- Thin / incomplete bag rows still need ProductMatches (enrichment path).
            if #thin > 0 and MS.ProductMatches then
                for t = 1, #thin do
                    if MS.ProductMatches(thin[t].item, entry.spec) == true then
                        total = total + thin[t].qty
                    end
                end
            elseif #thin > 0 and MS.Matches then
                for t = 1, #thin do
                    if MS.Matches(thin[t].item, entry.spec) == true then
                        total = total + thin[t].qty
                    end
                end
            end
        else
            -- No stable Key: full ProductMatches against bag (rare incomplete/fuzzy).
            local src = anyNoKey and allBag or thin
            if MS.ProductMatches then
                for t = 1, #src do
                    if MS.ProductMatches(src[t].item, entry.spec) == true then
                        total = total + src[t].qty
                    end
                end
            elseif MS.Matches then
                for t = 1, #src do
                    if MS.Matches(src[t].item, entry.spec) == true then
                        total = total + src[t].qty
                    end
                end
            end
        end
        cache[entry.key] = total
    end

    for i = 1, #pending do
        local entry = pending[i]
        local plantUid = SpecHavePlantUid(entry.spec)
        if plantUid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUid then
            local byUid = tonumber(StockPiler2.Inventory.CountByUid(plantUid)) or 0
            if byUid > (tonumber(cache[entry.key]) or 0) then
                cache[entry.key] = byUid
            end
        end
    end
    MarkHaveCacheWarmed(snapGen)
    return filled + #pending
end

--- Warm have-cache from every enabled watch recipe slot (Planner.Build entry).
function SpecHaveCache.WarmSpecHaveCacheForWatches()
    -- 0.4.157: do not sync-warm over an in-flight sliced job (would MarkWarmed on half-fill).
    if SpecHaveCache._warmHaveSlicing == true then
        return 0
    end
    local FW = StockPiler2.FrameWork
    if FW and FW.IsActive and FW.IsActive("prewarm-warm-have") == true then
        return 0
    end
    local s = EnsureSettings()
    if type(s) ~= "table" or type(s.watches) ~= "table" then
        EnsureSpecHaveCacheForSnap()
        MarkHaveCacheWarmed(CurrentSnapGen())
        return 0
    end
    local specs = {}
    for watchKey, watch in pairs(s.watches) do
        if type(watch) == "table" and watch.enabled == true then
            local recipe = RS.RecipeSpecForPotion and RS.RecipeSpecForPotion(watchKey)
            if type(recipe) == "table" then
                if RS.HydrateRecipeSlots then
                    RS.HydrateRecipeSlots(recipe)
                end
                local slots = recipe.slots
                if type(slots) == "table" then
                    for i = 1, #slots do
                        local spec = slots[i] and slots[i].spec
                        if type(spec) == "table" then
                            specs[#specs + 1] = spec
                        end
                    end
                end
            end
        end
    end
    return SpecHaveCache.WarmSpecHaveCache(specs)
end

local function CollectWatchFuzzyPending()
    local s = EnsureSettings()
    local cache = EnsureSpecHaveCacheForSnap()
    local pending = {}
    local pendingKeys = {}
    if type(s) ~= "table" or type(s.watches) ~= "table" or not MS then
        return pending, 0
    end
    local filled = 0
    for watchKey, watch in pairs(s.watches) do
        if type(watch) == "table" and watch.enabled == true then
            local recipe = RS.RecipeSpecForPotion and RS.RecipeSpecForPotion(watchKey)
            if type(recipe) == "table" then
                if RS.HydrateRecipeSlots then
                    RS.HydrateRecipeSlots(recipe)
                end
                local slots = recipe.slots
                if type(slots) == "table" then
                    for i = 1, #slots do
                        local spec = slots[i] and slots[i].spec
                        if type(spec) == "table" then
                            local specKey = MS.Key and MS.Key(spec) or nil
                            if specKey ~= nil and cache[specKey] == nil then
                                local boundUid = SpecHaveBoundUid(spec)
                                if boundUid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUid then
                                    cache[specKey] = tonumber(StockPiler2.Inventory.CountByUid(boundUid)) or 0
                                    filled = filled + 1
                                elseif pendingKeys[specKey] ~= true then
                                    pendingKeys[specKey] = true
                                    local target = nil
                                    if MS.AsApothecaryProduct then
                                        target = MS.AsApothecaryProduct(spec, spec and spec.role)
                                    end
                                    local targetKey = nil
                                    if type(target) == "table" and target.incomplete ~= true and MS.Key then
                                        targetKey = MS.Key(target)
                                    end
                                    pending[#pending + 1] = {
                                        key = specKey,
                                        spec = spec,
                                        targetKey = targetKey,
                                    }
                                    -- 0.4.157: never pre-zero live cache (brew Pump skip stamped craftable=0).
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return pending, filled
end

local function BuildWarmHaveBagIndex(pending)
    local byKey = {}
    local thin = {}
    local allBag = {}
    local anyNoKey = false
    for i = 1, #pending do
        if pending[i].targetKey == nil or pending[i].targetKey == "" then
            anyNoKey = true
            break
        end
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if not ItemUsableForSpecHave(item) then
                return
            end
            local qty = ItemStackQty(item)
            if anyNoKey then
                allBag[#allBag + 1] = { item = item, qty = qty }
            end
            local product = nil
            if MS.AsApothecaryProduct then
                product = MS.AsApothecaryProduct(item)
            end
            if type(product) ~= "table" or ProductNeedsEnrichMatch(product) then
                thin[#thin + 1] = { item = item, qty = qty }
                return
            end
            local k = MS.Key and MS.Key(product) or nil
            if k ~= nil and k ~= "" then
                byKey[k] = (tonumber(byKey[k]) or 0) + qty
            else
                thin[#thin + 1] = { item = item, qty = qty }
            end
        end)
    end
    return byKey, thin, allBag, anyNoKey
end

local function FillPendingFromIndex(entry, byKey, thin, allBag, anyNoKey)
    local total = 0
    if entry.targetKey ~= nil and entry.targetKey ~= "" then
        total = tonumber(byKey[entry.targetKey]) or 0
        if #thin > 0 and MS.ProductMatches then
            for t = 1, #thin do
                if MS.ProductMatches(thin[t].item, entry.spec) == true then
                    total = total + thin[t].qty
                end
            end
        elseif #thin > 0 and MS.Matches then
            for t = 1, #thin do
                if MS.Matches(thin[t].item, entry.spec) == true then
                    total = total + thin[t].qty
                end
            end
        end
    else
        local src = anyNoKey and allBag or thin
        if MS.ProductMatches then
            for t = 1, #src do
                if MS.ProductMatches(src[t].item, entry.spec) == true then
                    total = total + src[t].qty
                end
            end
        elseif MS.Matches then
            for t = 1, #src do
                if MS.Matches(src[t].item, entry.spec) == true then
                    total = total + src[t].qty
                end
            end
        end
    end
    local plantUid = SpecHavePlantUid(entry.spec)
    if plantUid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUid then
        local byUid = tonumber(StockPiler2.Inventory.CountByUid(plantUid)) or 0
        if byUid > total then
            total = byUid
        end
    end
    return total
end

--- FrameWork-sliced WarmHave: bag index once, then N specs/frame. MarkWarmed only in done().
--- Returns true if a job was started (or already warm / nothing to do).
function SpecHaveCache.StartSlicedWarmHaveForWatches(genKey)
    local FW = StockPiler2.FrameWork
    if not (FW and FW.Start) then
        SpecHaveCache.WarmSpecHaveCacheForWatches()
        return true
    end
    if SpecHaveCache.IsHaveCacheWarmForSnap() == true then
        return true
    end
    local pending, filled = CollectWatchFuzzyPending()
    if #pending == 0 then
        MarkHaveCacheWarmed(CurrentSnapGen())
        return true
    end
    if StockPiler2.Perf and StockPiler2.Perf.Mark then
        StockPiler2.Perf.Mark("WarmHave.miss")
    end
    local snapGen = CurrentSnapGen()
    local cache = EnsureSpecHaveCacheForSnap()
    SpecHaveCache._warmHaveSlicing = true
    local state = {
        byKey = nil,
        thin = nil,
        allBag = nil,
        anyNoKey = false,
        indexed = false,
        snapGen = snapGen,
        filled = filled,
    }
    return FW.Start({
        id = "prewarm-warm-have",
        gen = genKey,
        stepsPerFrame = 1,
        state = state,
        resume = function(st)
            -- Budget=1 → one resume/frame; fill 2 specs per resume (plan stepsPerFrame=2).
            if st.indexed ~= true then
                if StockPiler2.Perf and StockPiler2.Perf.Begin then
                    StockPiler2.Perf.Begin("WarmHave.Index")
                end
                st.byKey, st.thin, st.allBag, st.anyNoKey = BuildWarmHaveBagIndex(pending)
                st.indexed = true
                st.index = 1
                if StockPiler2.Perf and StockPiler2.Perf.End then
                    StockPiler2.Perf.End("WarmHave.Index")
                end
            end
            local n = 0
            while n < 2 and st.index <= #pending do
                local entry = pending[st.index]
                st.index = st.index + 1
                n = n + 1
                if type(entry) == "table" and entry.key ~= nil then
                    cache[entry.key] = FillPendingFromIndex(
                        entry, st.byKey, st.thin, st.allBag, st.anyNoKey
                    )
                end
            end
            if st.index > #pending then
                return "done"
            end
            return "continue"
        end,
        done = function()
            SpecHaveCache._warmHaveSlicing = nil
            MarkHaveCacheWarmed(state.snapGen or CurrentSnapGen())
        end,
        cancel = function()
            SpecHaveCache._warmHaveSlicing = nil
        end,
    })
end

--- True when WarmSpecHaveCache finished for the current snapGen (empty table ≠ warm).
function SpecHaveCache.IsHaveCacheWarmForSnap()
    local snapGen = CurrentSnapGen()
    return type(SpecHaveCache._specHaveCache) == "table"
        and SpecHaveCache._specHaveSnapGen == snapGen
        and SpecHaveCache._specHaveWarmedGen == snapGen
end

--- True when demand cache matches current snapGen:watchGen (prewarm hit).
function SpecHaveCache.IsDemandCacheWarm()
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    local watchGen = 0
    if StockPiler2.Watch and StockPiler2.Watch.GetGen then
        watchGen = tonumber(StockPiler2.Watch.GetGen()) or 0
    end
    local cacheKey = tostring(snapGen) .. ":" .. tostring(watchGen)
    return type(SpecHaveCache._demandCache) == "table" and SpecHaveCache._demandSnapGen == cacheKey
end

--- Call at start of Orchestrator.Tick so PickPlantCandidate + CollectIntents share one
--- BuildBalancedSpecDemand / CollectAutoGrowSeedLines result for the tick.
function SpecHaveCache.BeginOrchTick()
    SpecHaveCache._orchTickId = (tonumber(SpecHaveCache._orchTickId) or 0) + 1
    SpecHaveCache._orchTickDemand = nil
    SpecHaveCache._orchTickDemandTick = nil
    SpecHaveCache._orchTickSeedLines = nil
    SpecHaveCache._orchTickSeedLinesTick = nil
    SpecHaveCache._orchTickFocus = nil
    SpecHaveCache._orchTickFocusTick = nil
end

--- opts.cacheOnly=true — warm cache / CountByUid / last-complete only; never ForEachItem.
--- Miss returns nil so tip hover can keep plan-time have (Issue #5).
function SpecHaveCache.CountItemsMatchingSpec(spec, opts)
    if type(spec) ~= "table" or not MS then
        return 0
    end
    if not MS.ProductMatches and not MS.Matches then
        return 0
    end
    opts = type(opts) == "table" and opts or {}
    local cacheOnly = opts.cacheOnly == true
    local specKey = MS.Key and MS.Key(spec) or nil
    local cache = EnsureSpecHaveCacheForSnap()
    local FW = StockPiler2.FrameWork
    local slicing = SpecHaveCache._warmHaveSlicing == true
        or (FW and FW.IsActive and FW.IsActive("prewarm-warm-have") == true)
    -- While sliced WarmHave is in flight: never trust live cache for unfilled keys,
    -- and never ForEachItem (Status.Craftable storm). Use last-complete / boundUid.
    if slicing or cacheOnly then
        if specKey ~= nil and cache[specKey] ~= nil then
            -- Only trust keys already filled by this slice (or boundUid path).
            return cache[specKey]
        end
        local boundUid = SpecHaveBoundUid(spec)
        if boundUid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUid then
            return tonumber(StockPiler2.Inventory.CountByUid(boundUid)) or 0
        end
        if specKey ~= nil
            and type(SpecHaveCache._specHaveLastComplete) == "table"
            and SpecHaveCache._specHaveLastComplete[specKey] ~= nil
        then
            return SpecHaveCache._specHaveLastComplete[specKey]
        end
        local plantUid = SpecHavePlantUid(spec)
        if plantUid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUid then
            return tonumber(StockPiler2.Inventory.CountByUid(plantUid)) or 0
        end
        if cacheOnly then
            return nil
        end
        return 0
    end
    if specKey ~= nil and cache[specKey] ~= nil then
        return cache[specKey]
    end
    local boundUid = SpecHaveBoundUid(spec)
    if boundUid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUid then
        local total = tonumber(StockPiler2.Inventory.CountByUid(boundUid)) or 0
        if specKey ~= nil then
            cache[specKey] = total
        end
        return total
    end
    local total = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if not ItemUsableForSpecHave(item) then
                return
            end
            local match = false
            if MS.ProductMatches then
                match = MS.ProductMatches(item, spec) == true
            elseif MS.Matches then
                match = MS.Matches(item, spec) == true
            end
            if match then
                total = total + ItemStackQty(item)
            end
        end)
    end
    local plantUid = SpecHavePlantUid(spec)
    if plantUid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUid then
        local byUid = tonumber(StockPiler2.Inventory.CountByUid(plantUid)) or 0
        if byUid > total then
            total = byUid
        end
    end
    if specKey ~= nil then
        cache[specKey] = total
    end
    return total
end

Planner.ClearCountCaches = SpecHaveCache.ClearCountCaches
Planner.BeginPlanCraftsMemo = SpecHaveCache.BeginPlanCraftsMemo
Planner.WarmSpecHaveCache = SpecHaveCache.WarmSpecHaveCache
Planner.WarmSpecHaveCacheForWatches = SpecHaveCache.WarmSpecHaveCacheForWatches
Planner.StartSlicedWarmHaveForWatches = SpecHaveCache.StartSlicedWarmHaveForWatches
Planner.IsHaveCacheWarmForSnap = SpecHaveCache.IsHaveCacheWarmForSnap
Planner.IsDemandCacheWarm = SpecHaveCache.IsDemandCacheWarm
Planner.BeginOrchTick = SpecHaveCache.BeginOrchTick
