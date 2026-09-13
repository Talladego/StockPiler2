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

function SpecHaveCache.ClearCountCaches()
    SpecHaveCache._specHaveCache = {}
    SpecHaveCache._specHaveSnapGen = nil
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
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    if type(SpecHaveCache._specHaveCache) ~= "table" or SpecHaveCache._specHaveSnapGen ~= snapGen then
        SpecHaveCache._specHaveCache = {}
        SpecHaveCache._specHaveSnapGen = snapGen
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

--- One bag walk for all uncached fuzzy specs; CountByUid for uid-bound incomplete specs.
--- specs: array of MaterialSpec tables, or map of rows with .spec, or map of specs.
function SpecHaveCache.WarmSpecHaveCache(specs)
    if type(specs) ~= "table" or not MS then
        return 0
    end
    if not MS.ProductMatches and not MS.Matches then
        return 0
    end
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
        return filled
    end
    for i = 1, #pending do
        cache[pending[i].key] = 0
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if not ItemUsableForSpecHave(item) then
                return
            end
            local qty = ItemStackQty(item)
            for i = 1, #pending do
                local entry = pending[i]
                local match = false
                if MS.ProductMatches then
                    match = MS.ProductMatches(item, entry.spec) == true
                elseif MS.Matches then
                    match = MS.Matches(item, entry.spec) == true
                end
                if match then
                    cache[entry.key] = cache[entry.key] + qty
                end
            end
        end)
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
    return filled + #pending
end

--- Warm have-cache from every enabled watch recipe slot (Planner.Build entry).
function SpecHaveCache.WarmSpecHaveCacheForWatches()
    local s = EnsureSettings()
    if type(s) ~= "table" or type(s.watches) ~= "table" then
        EnsureSpecHaveCacheForSnap()
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

--- True when have-cache already matches current inventory snapGen (prewarm hit).
function SpecHaveCache.IsHaveCacheWarmForSnap()
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    return type(SpecHaveCache._specHaveCache) == "table" and SpecHaveCache._specHaveSnapGen == snapGen
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

function SpecHaveCache.CountItemsMatchingSpec(spec)
    if type(spec) ~= "table" or not MS then
        return 0
    end
    if not MS.ProductMatches and not MS.Matches then
        return 0
    end
    local specKey = MS.Key and MS.Key(spec) or nil
    local cache = EnsureSpecHaveCacheForSnap()
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
Planner.IsHaveCacheWarmForSnap = SpecHaveCache.IsHaveCacheWarmForSnap
Planner.IsDemandCacheWarm = SpecHaveCache.IsDemandCacheWarm
Planner.BeginOrchTick = SpecHaveCache.BeginOrchTick
