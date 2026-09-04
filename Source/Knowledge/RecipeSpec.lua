----------------------------------------------------------------
-- Recipe spec storage, known potions, spec matching
----------------------------------------------------------------

StockPiler2.RecipeSpec = StockPiler2.RecipeSpec or {}

local RS = StockPiler2.RecipeSpec
local MS = StockPiler2.MaterialSpec

local function ToNarrow(text)
    return StockPiler2.ToNarrow(text)
end

local function EnsureSettings()
    if StockPiler2.EnsureSettings then
        return StockPiler2.EnsureSettings()
    end
    return StockPiler2.Settings
end

local function RecipesTable(s)
    s = s or EnsureSettings()
    if type(s.recipes) ~= "table" then
        if StockPiler2.ClearAccountTable then
            s.recipes = StockPiler2.ClearAccountTable("recipes")
        else
            s.recipes = {}
        end
    end
    -- Compat alias
    s.learnedRecipeSpecs = s.recipes
    return s.recipes
end

local function PotionsTable(s)
    s = s or EnsureSettings()
    if type(s.potions) ~= "table" then
        if StockPiler2.ClearAccountTable then
            s.potions = StockPiler2.ClearAccountTable("potions")
        else
            s.potions = {}
        end
    end
    s.knownPotions = s.potions
    return s.potions
end

local function EnsureBrewStats(recipe)
    if type(recipe) ~= "table" then
        return
    end
    if recipe.brewAttempts == nil then
        local crafts = tonumber(recipe.crafts) or 0
        recipe.brewSuccesses = tonumber(recipe.brewSuccesses) or crafts
        recipe.brewAttempts = tonumber(recipe.brewAttempts) or crafts
    end
    recipe.brewSuccesses = tonumber(recipe.brewSuccesses) or 0
    recipe.brewAttempts = tonumber(recipe.brewAttempts) or 0
    recipe.brewCrits = tonumber(recipe.brewCrits) or 0
    recipe.brewSuperCrits = tonumber(recipe.brewSuperCrits) or 0
    recipe.brewFailures = tonumber(recipe.brewFailures) or 0
    recipe.brewVolatiles = tonumber(recipe.brewVolatiles) or 0
    -- Do not invent product counts from an old stored yield.
    recipe.yieldProductSum = tonumber(recipe.yieldProductSum) or 0
    recipe.yieldSamples = tonumber(recipe.yieldSamples) or 0
end

-- RoR Lua quirk: local callees must be defined BEFORE callers (RoR-Interface docs/api/lua-local-order.md).

local function PotionRecipeKeys(potion)
    if type(potion) ~= "table" then
        return nil
    end
    if type(potion.recipeKeys) == "table" then
        return potion.recipeKeys
    end
    return potion.alternateRecipeSpecKeys
end

local function PotionActiveRecipeKey(potion)
    if type(potion) ~= "table" then
        return nil
    end
    local key = potion.activeRecipeKey or potion.activeRecipeSpecKey
    if type(key) == "string" and key ~= "" then
        return key
    end
    local keys = PotionRecipeKeys(potion)
    if type(keys) == "table" and #keys == 1 then
        key = keys[1]
        if type(key) == "string" and key ~= "" then
            return key
        end
    end
    return nil
end

local ROLE_ORDER = {
    container = 1,
    main = 2,
    stabilizer = 3,
    goldweed = 3,
    extender = 4,
    multiplier = 5,
    stimulant = 5,
    ingredient = 6,
}

function RS.PotionKeyFromUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    return "uid:" .. tostring(uid)
end

--- Watch / catalog identity: one row per potion uid x recipe fingerprint.
--- Format: "uid:<outputUid>|rk:<recipeSpecKey>"
function RS.PotionRecipeKey(outputUid, recipeSpecKey)
    local potionKey = RS.PotionKeyFromUid(outputUid)
    recipeSpecKey = tostring(recipeSpecKey or "")
    if potionKey == nil or recipeSpecKey == "" then
        return nil
    end
    return potionKey .. "|rk:" .. recipeSpecKey
end

function RS.ParsePotionRecipeKey(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    local uidStr, recipeSpecKey = string.match(key, "^uid:(%d+)|rk:(.+)$")
    if uidStr and recipeSpecKey and recipeSpecKey ~= "" then
        local uid = tonumber(uidStr) or 0
        return {
            potionRecipeKey = key,
            outputUid = uid,
            potionKey = RS.PotionKeyFromUid(uid),
            recipeSpecKey = recipeSpecKey,
            isComposite = true,
        }
    end
    local plainUid = string.match(key, "^uid:(%d+)$")
    if plainUid then
        local uid = tonumber(plainUid) or 0
        return {
            potionRecipeKey = key,
            outputUid = uid,
            potionKey = RS.PotionKeyFromUid(uid),
            recipeSpecKey = nil,
            isComposite = false,
        }
    end
    return nil
end

function RS.IsPotionRecipeKey(key)
    local parsed = RS.ParsePotionRecipeKey(key)
    return type(parsed) == "table" and parsed.isComposite == true
end

local function CraftBonusRef(name, fallback)
    local B = StockPiler2.Inventory and StockPiler2.Inventory.CraftBonus
    if type(B) == "table" and B[name] ~= nil then
        return B[name]
    end
    return fallback
end

local function SumSlotBonus(slots, ref)
    local sum = 0
    if type(slots) ~= "table" or ref == nil then
        return sum
    end
    for i = 1, #slots do
        local slot = slots[i]
        local spec = RS.ResolveSlotSpec(slot)
        if type(spec) == "table" and type(spec.bonuses) == "table" then
            local per = 1
            if type(slot) == "table" then
                per = math.max(1, tonumber(slot.perCraft) or 1)
            end
            sum = sum + (tonumber(spec.bonuses[ref]) or 0) * per
        end
    end
    return sum
end

local function FormatYieldNumber(yield)
    yield = tonumber(yield) or 0
    if yield <= 0 then
        return nil
    end
    local rounded = math.floor(yield + 0.5)
    if math.abs(yield - rounded) < 0.05 then
        return tostring(rounded)
    end
    return string.format("%.1f", yield)
end

--- Summed craft bonuses + observed yield for a recipe fingerprint.
--- Duration is omitted (changes potion uid). Critical/Fail are optional extras.
function RS.RecipeFingerprintStats(recipe, potionUid)
    local stats = {
        power = 0,
        stability = 0,
        superCrit = 0,
        critical = 0,
        fail = 0,
        yield = 0,
    }
    if type(recipe) ~= "table" then
        return stats
    end
    RS.HydrateRecipeSlots(recipe)
    stats.power = SumSlotBonus(recipe.slots, CraftBonusRef("POWER", 2))
    stats.stability = SumSlotBonus(recipe.slots, CraftBonusRef("STABILITY", 1))
    stats.superCrit = SumSlotBonus(recipe.slots, CraftBonusRef("SPECIAL_CHANCE", 14))
    stats.critical = SumSlotBonus(recipe.slots, CraftBonusRef("CRITICAL_CHANCE", 12))
    stats.fail = SumSlotBonus(recipe.slots, CraftBonusRef("FAIL_CHANCE", 13))
    local yield = nil
    if RS.RecipeOutputYield then
        yield = RS.RecipeOutputYield(recipe, potionUid)
    end
    if not yield or yield <= 0 then
        yield = tonumber(recipe.recipeYield)
    end
    stats.yield = tonumber(yield) or 0
    return stats
end

--- Outcome-focused label for Watch / compact lists.
--- e.g. "Yield: 5", "Yield: 2, Super-Critical: 9%"
function RS.RecipeLabelForRecipe(recipe, potionUid)
    if type(recipe) ~= "table" then
        return L""
    end
    local stats = RS.RecipeFingerprintStats(recipe, potionUid)
    local parts = {}
    local ystr = FormatYieldNumber(stats.yield)
    if ystr then
        parts[#parts + 1] = "Yield: " .. ystr
    end
    if stats.superCrit ~= 0 then
        parts[#parts + 1] = "Super-Critical: " .. tostring(stats.superCrit) .. "%"
    end
    if stats.critical ~= 0 then
        parts[#parts + 1] = "Critical: " .. tostring(stats.critical) .. "%"
    end
    if stats.fail ~= 0 then
        parts[#parts + 1] = "Fail: " .. tostring(stats.fail) .. "%"
    end
    if #parts == 0 then
        return L"Recipe"
    end
    return towstring(table.concat(parts, ", "))
end

--- Slots-only fallback (no observed yield yet): chance bonuses from mats.
function RS.RecipeLabelFromSlots(slots)
    if type(slots) ~= "table" then
        return L""
    end
    return RS.RecipeLabelForRecipe({ slots = slots }, nil)
end

function RS.MaterialsToSpecSlots(materials)
    local slots = {}
    if type(materials) ~= "table" or not MS or not MS.FromItemData then
        return slots
    end
    for i = 1, #materials do
        local mat = materials[i]
        local itemData = mat.itemData
        local uid = tonumber(mat.uniqueID) or 0
        if type(itemData) ~= "table" and StockPiler2.Inventory then
            if uid <= 0 then
                uid = 0
            end
            if uid > 0 then
                local _, sample = StockPiler2.Inventory.CountByUniqueId(uid)
                itemData = sample
            end
        end
        if uid <= 0 and type(itemData) == "table" then
            uid = tonumber(itemData.uniqueID) or 0
        end
        local spec = MS.FromItemData(itemData, mat.role)
        if spec then
            if uid > 0 and StockPiler2.Items and StockPiler2.Items.UpsertFromItemData then
                StockPiler2.Items.UpsertFromItemData(itemData, "mat")
            end
            if spec.incomplete == true and uid > 0 then
                spec.boundUid = uid
            end
            slots[#slots + 1] = {
                role = mat.role or spec.role,
                uid = uid > 0 and uid or nil,
                spec = MS.Copy(spec),
                perCraft = tonumber(mat.perCraft) or 1,
            }
            if StockPiler2.SeedMap and StockPiler2.SeedMap.RegisterFromItem then
                StockPiler2.SeedMap.RegisterFromItem(itemData)
            end
            if StockPiler2.SeedMap and StockPiler2.SeedMap.MaybeLearnHarvestByproduct then
                StockPiler2.SeedMap.MaybeLearnHarvestByproduct(itemData, spec)
            end
        end
    end
    table.sort(slots, function(a, b)
        return (ROLE_ORDER[a.role] or 99) < (ROLE_ORDER[b.role] or 99)
    end)
    return slots
end

--- Recipe identity = ingredient fingerprint only (no output uid).
function RS.BuildRecipeSpecKey(slots, _outputUid)
    return RS.SlotsFingerprint(slots)
end

function RS.OutputQuality(out)
    if type(out) ~= "table" then
        return "failed"
    end
    local name = string.lower(ToNarrow(out.name) or "")
    if string.find(name, "volatile", 1, true) then
        return "volatile"
    end
    if string.find(name, "potent", 1, true) then
        return "potent"
    end
    return "good"
end

--- Same slots, no output uid. Sibling recipes (Lasting vs Potent) share this.
function RS.SlotsFingerprint(slots)
    local parts = {}
    if type(slots) ~= "table" or not MS then
        return ""
    end
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" then
            local spec = RS.ResolveSlotSpec(slot)
            if type(spec) == "table" then
                local boundUid = tonumber(slot.uid) or tonumber(spec.boundUid) or 0
                parts[#parts + 1] = tostring(slot.role or "")
                    .. "x" .. tostring(slot.perCraft or 1)
                    .. ":" .. MS.Key(spec, boundUid)
            end
        end
    end
    return table.concat(parts, "|")
end

--- Canonical fingerprint for a stored recipe key (re-hydrates slots).
function RS.RecipeFingerprintForKey(recipes, key)
    key = tostring(key or "")
    if key == "" or type(recipes) ~= "table" then
        return key
    end
    local recipe = recipes[key]
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return key
    end
    RS.HydrateRecipeSlots(recipe)
    local fp = RS.SlotsFingerprint(recipe.slots)
    if fp ~= "" then
        return fp
    end
    return key
end

--- Find a learned recipe by canonical ingredient fingerprint.
function RS.FindRecipeByFingerprint(recipes, fingerprint)
    fingerprint = tostring(fingerprint or "")
    if fingerprint == "" or type(recipes) ~= "table" then
        return nil, nil
    end
    local direct = recipes[fingerprint]
    if type(direct) == "table" then
        return fingerprint, direct
    end
    for key, recipe in pairs(recipes) do
        if type(recipe) == "table" and RS.RecipeFingerprintForKey(recipes, key) == fingerprint then
            return key, recipe
        end
    end
    return nil, nil
end

--- Merge brew stats / outcomes when two keys are the same cauldron loadout.
function RS.MergeRecipeRecords(into, from)
    if type(into) ~= "table" or type(from) ~= "table" then
        return into
    end
    EnsureBrewStats(into)
    EnsureBrewStats(from)
    into.brewAttempts = (tonumber(into.brewAttempts) or 0) + (tonumber(from.brewAttempts) or 0)
    into.brewSuccesses = (tonumber(into.brewSuccesses) or 0) + (tonumber(from.brewSuccesses) or 0)
    into.brewCrits = (tonumber(into.brewCrits) or 0) + (tonumber(from.brewCrits) or 0)
    into.brewSuperCrits = (tonumber(into.brewSuperCrits) or 0) + (tonumber(from.brewSuperCrits) or 0)
    into.brewFailures = (tonumber(into.brewFailures) or 0) + (tonumber(from.brewFailures) or 0)
    into.brewVolatiles = (tonumber(into.brewVolatiles) or 0) + (tonumber(from.brewVolatiles) or 0)
    into.yieldProductSum = (tonumber(into.yieldProductSum) or 0) + (tonumber(from.yieldProductSum) or 0)
    into.yieldSamples = (tonumber(into.yieldSamples) or 0) + (tonumber(from.yieldSamples) or 0)
    into.crafts = (tonumber(into.brewSuccesses) or 0)
    if type(from.outcomes) == "table" then
        if type(into.outcomes) ~= "table" then
            into.outcomes = {}
        end
        for uidKey, oc in pairs(from.outcomes) do
            if type(oc) == "table" then
                local existing = into.outcomes[uidKey]
                if type(existing) ~= "table" then
                    into.outcomes[uidKey] = {
                        successes = tonumber(oc.successes) or 0,
                        qtySum = tonumber(oc.qtySum) or 0,
                        quality = oc.quality,
                    }
                else
                    existing.successes = (tonumber(existing.successes) or 0) + (tonumber(oc.successes) or 0)
                    existing.qtySum = (tonumber(existing.qtySum) or 0) + (tonumber(oc.qtySum) or 0)
                    if existing.quality == nil then
                        existing.quality = oc.quality
                    end
                end
            end
        end
    end
    if (tonumber(into.yieldSamples) or 0) > 0 and (tonumber(into.yieldProductSum) or 0) > 0 then
        into.recipeYield = into.yieldProductSum / into.yieldSamples
    end
    if into.activeOutcomeUid == nil and from.activeOutcomeUid ~= nil then
        into.activeOutcomeUid = from.activeOutcomeUid
        into.outputUid = from.outputUid
    end
    return into
end

local function DedupePotionRecipeKeys(potion, recipes)
    if type(potion) ~= "table" or type(recipes) ~= "table" then
        return false
    end
    local keys = PotionRecipeKeys(potion)
    if type(keys) ~= "table" or #keys < 2 then
        return false
    end
    local seen = {}
    local out = {}
    local changed = false
    for i = 1, #keys do
        local key = keys[i]
        local canon = RS.RecipeFingerprintForKey(recipes, key)
        if type(recipes[canon]) ~= "table" and type(recipes[key]) == "table" then
            canon = key
        elseif type(recipes[canon]) ~= "table" then
            changed = true
        elseif seen[canon] ~= true then
            seen[canon] = true
            out[#out + 1] = canon
            if canon ~= key then
                changed = true
            end
        else
            changed = true
        end
    end
    if changed then
        potion.recipeKeys = out
        potion.alternateRecipeSpecKeys = nil
        local active = PotionActiveRecipeKey(potion)
        if active ~= nil then
            local canonActive = RS.RecipeFingerprintForKey(recipes, active)
            if type(recipes[canonActive]) == "table" then
                potion.activeRecipeKey = canonActive
            elseif #out > 0 then
                potion.activeRecipeKey = out[1]
            end
        end
        potion.activeRecipeSpecKey = nil
    end
    return changed
end

local function RemapRecipeSpecKey(s, oldKey, newKey, recipe)
    if oldKey == newKey or oldKey == "" or newKey == "" then
        return
    end
    local recipes = s.recipes or s.learnedRecipeSpecs
    if type(recipes) ~= "table" then
        return
    end
    recipe.recipeSpecKey = newKey
    recipes[newKey] = recipe
    if recipes[oldKey] == recipe then
        recipes[oldKey] = nil
    end
    local potions = s.potions or s.knownPotions
    if type(potions) == "table" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" then
                if PotionActiveRecipeKey(potion) == oldKey then
                    potion.activeRecipeKey = newKey
                end
                potion.activeRecipeSpecKey = nil
                local keys = PotionRecipeKeys(potion)
                if type(keys) == "table" then
                    for i = 1, #keys do
                        if keys[i] == oldKey then
                            keys[i] = newKey
                        end
                    end
                    potion.recipeKeys = keys
                end
                potion.alternateRecipeSpecKeys = nil
            end
        end
    end
    if type(s.watches) == "table" then
        local suffix = "|rk:" .. oldKey
        local rekey = {}
        for watchKey, watch in pairs(s.watches) do
            if type(watchKey) == "string"
                and (watchKey == oldKey or string.sub(watchKey, -#suffix) == suffix)
            then
                local newWatchKey = watchKey
                if watchKey == oldKey then
                    newWatchKey = newKey
                else
                    newWatchKey = string.sub(watchKey, 1, -#suffix - 1) .. "|rk:" .. newKey
                end
                if newWatchKey ~= watchKey then
                    rekey[#rekey + 1] = { oldKey = watchKey, newKey = newWatchKey, watch = watch }
                end
            end
        end
        for i = 1, #rekey do
            local entry = rekey[i]
            if type(s.watches[entry.newKey]) ~= "table" then
                s.watches[entry.newKey] = entry.watch
            end
            s.watches[entry.oldKey] = nil
        end
    end
end

--- Collapse legacy twin keys (e.g. differ only by DESTROY_ON_FAIL bonus ref 15).
function RS.RepairDuplicateRecipeFingerprints()
    local s = EnsureSettings()
    local recipes = RecipesTable(s)
    local groups = {}
    for key, recipe in pairs(recipes) do
        if type(recipe) == "table" and type(recipe.slots) == "table" then
            RS.HydrateRecipeSlots(recipe)
            local canon = RS.SlotsFingerprint(recipe.slots)
            if canon ~= "" then
                local group = groups[canon]
                if group == nil then
                    group = { canon = canon, entries = {} }
                    groups[canon] = group
                end
                group.entries[#group.entries + 1] = { key = key, recipe = recipe }
            end
        end
    end

    local merged = 0
    for canon, group in pairs(groups) do
        if #group.entries == 0 then
            -- skip
        elseif #group.entries == 1 and group.entries[1].key == canon then
            -- already canonical
        elseif #group.entries == 1 and group.entries[1].key ~= canon then
            RemapRecipeSpecKey(s, group.entries[1].key, canon, group.entries[1].recipe)
            merged = merged + 1
        else
            local combined = group.entries[1].recipe
            for i = 2, #group.entries do
                RS.MergeRecipeRecords(combined, group.entries[i].recipe)
            end
            combined.recipeSpecKey = canon
            recipes[canon] = combined
            for i = 1, #group.entries do
                local entry = group.entries[i]
                if entry.key ~= canon then
                    RemapRecipeSpecKey(s, entry.key, canon, combined)
                end
            end
            merged = merged + 1
        end
    end

    local potions = PotionsTable(s)
    for _, potion in pairs(potions) do
        if DedupePotionRecipeKeys(potion, recipes) then
            merged = merged + 1
        end
    end

    if merged > 0 then
        RS.SlimAllRecipesForStorage()
        if StockPiler2.Inventory and StockPiler2.Inventory.InvalidateRecipeCaches then
            StockPiler2.Inventory.InvalidateRecipeCaches()
        end
        if StockPiler2.Planner and StockPiler2.Planner.InvalidatePlanCache then
            StockPiler2.Planner.InvalidatePlanCache()
        end
    end
    return merged
end

function RS.ResolveSlotSpec(slot)
    if type(slot) ~= "table" then
        return nil
    end
    local spec = nil
    if type(slot.spec) == "table" then
        spec = slot.spec
    else
        local uid = tonumber(slot.uid) or 0
        if uid > 0 and StockPiler2.Items and StockPiler2.Items.ToSpec then
            spec = StockPiler2.Items.ToSpec(uid)
        end
    end
    if type(spec) ~= "table" then
        return nil
    end
    local uid = tonumber(slot.uid) or 0
    if spec.incomplete == true and uid > 0 and tonumber(spec.boundUid) ~= uid then
        spec = MS and MS.Copy and MS.Copy(spec) or spec
        if type(spec) == "table" then
            spec.boundUid = uid
            slot.spec = spec
        end
    end
    return spec
end

function RS.HydrateRecipeSlots(recipe)
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return recipe
    end
    for i = 1, #recipe.slots do
        local slot = recipe.slots[i]
        if type(slot) == "table" and type(slot.spec) ~= "table" then
            slot.spec = RS.ResolveSlotSpec(slot)
        end
    end
    return recipe
end

local function SlimSlotsForStorage(slots)
    local slim = {}
    if type(slots) ~= "table" then
        return slim
    end
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" then
            slim[#slim + 1] = {
                role = slot.role,
                uid = tonumber(slot.uid) or 0,
                perCraft = tonumber(slot.perCraft) or 1,
            }
        end
    end
    return slim
end

--- Drop ephemeral slot.spec blobs so Account only stores uid/role/perCraft.
function RS.SlimRecipeForStorage(recipe)
    if type(recipe) ~= "table" then
        return recipe
    end
    if type(recipe.slots) == "table" then
        recipe.slots = SlimSlotsForStorage(recipe.slots)
    end
    recipe.recipeSpecKey = nil
    return recipe
end

function RS.SlimAllRecipesForStorage()
    local s = EnsureSettings()
    local recipes = s and (s.recipes or s.learnedRecipeSpecs)
    if type(recipes) ~= "table" then
        return 0
    end
    local n = 0
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            RS.SlimRecipeForStorage(recipe)
            n = n + 1
        end
    end
    return n
end

--- Drop legacy duplicate potion fields before persist.
function RS.SlimAllPotionsForStorage()
    local s = EnsureSettings()
    local potions = s and (s.potions or s.knownPotions)
    if type(potions) ~= "table" then
        return 0
    end
    local n = 0
    for _, potion in pairs(potions) do
        if type(potion) == "table" then
            if type(potion.recipeKeys) ~= "table" and type(potion.alternateRecipeSpecKeys) == "table" then
                potion.recipeKeys = potion.alternateRecipeSpecKeys
            end
            if potion.activeRecipeKey == nil and potion.activeRecipeSpecKey ~= nil then
                potion.activeRecipeKey = potion.activeRecipeSpecKey
            end
            potion.alternateRecipeSpecKeys = nil
            potion.activeRecipeSpecKey = nil
            potion.potionKey = nil
            local keys = potion.recipeKeys
            if type(keys) == "table" and #keys == 1 then
                potion.activeRecipeKey = nil
            end
            n = n + 1
        end
    end
    return n
end

function RS.RecipeLabelForKey(recipeSpecKey, potionUid)
    recipeSpecKey = tostring(recipeSpecKey or "")
    if recipeSpecKey == "" then
        return L""
    end
    local s = EnsureSettings()
    local recipes = RecipesTable(s)
    local recipe = recipes[recipeSpecKey]
    if type(recipe) ~= "table" then
        return L"Recipe"
    end
    return RS.RecipeLabelForRecipe(recipe, potionUid)
end

--- Observed bottles of the expected potion per successful brew.
function RS.ObservedRecipeYield(recipe)
    if type(recipe) ~= "table" then
        return nil
    end
    EnsureBrewStats(recipe)
    local samples = tonumber(recipe.yieldSamples) or 0
    local sum = tonumber(recipe.yieldProductSum) or 0
    if samples > 0 and sum > 0 then
        return sum / samples
    end
    local stored = tonumber(recipe.recipeYield)
    if stored and stored > 0 then
        return stored
    end
    return nil
end

--- Fraction of slot-matched brews that produced this recipe's expected potion.
function RS.RecipeSuccessRate(recipe)
    EnsureBrewStats(recipe)
    local attempts = tonumber(recipe and recipe.brewAttempts) or 0
    if attempts <= 0 then
        return nil
    end
    local ok = tonumber(recipe.brewSuccesses) or 0
    if ok < 0 then
        ok = 0
    end
    if ok > attempts then
        ok = attempts
    end
    return ok / attempts
end

--- Per-product outcome row for a shared recipe fingerprint (good / potent / volatile).
function RS.OutcomeForPotion(recipe, potionUid)
    potionUid = tonumber(potionUid) or 0
    if type(recipe) ~= "table" or potionUid <= 0 then
        return nil
    end
    if type(recipe.outcomes) ~= "table" then
        return nil
    end
    local oc = recipe.outcomes[tostring(potionUid)]
    if type(oc) ~= "table" then
        return nil
    end
    return oc
end

--- Fraction of fingerprint brews that produced this specific potion uid.
--- Potent / volatile share the recipe but must not reuse the primary "good" success rate.
function RS.OutcomeSuccessRate(recipe, potionUid)
    EnsureBrewStats(recipe)
    local attempts = tonumber(recipe and recipe.brewAttempts) or 0
    if attempts <= 0 then
        return nil
    end
    local oc = RS.OutcomeForPotion(recipe, potionUid)
    local ok = 0
    if type(oc) == "table" then
        ok = tonumber(oc.successes) or 0
    else
        -- Legacy: primary good potion may only have recipe.brewSuccesses.
        local primary = tonumber(recipe.activeOutcomeUid) or tonumber(recipe.outputUid) or 0
        if potionUid == primary then
            ok = tonumber(recipe.brewSuccesses) or 0
        end
    end
    if ok < 0 then
        ok = 0
    end
    if ok > attempts then
        ok = attempts
    end
    return ok / attempts, ok, attempts
end

function RS.RegisterKnownPotion(outputUid, out, recipeSpecKey, quality)
    outputUid = tonumber(outputUid) or 0
    if outputUid <= 0 then
        return nil
    end
    local s = EnsureSettings()
    local potions = PotionsTable(s)
    local potionKey = RS.PotionKeyFromUid(outputUid)
    local existing = potions[potionKey]
    if type(existing) ~= "table" then
        existing = {
            potionKey = potionKey,
            outputUid = outputUid,
            recipeKeys = {},
        }
    end
    existing.name = out and out.name or existing.name
    existing.nameNarrow = out and (out.nameNarrow or ToNarrow(out.name)) or existing.nameNarrow
    existing.iconNum = out and tonumber(out.iconNum) or existing.iconNum or 0
    if StockPiler2.Items and StockPiler2.Items.Upsert then
        StockPiler2.Items.Upsert(outputUid, {
            kind = "potion",
            name = existing.name,
            nameNarrow = existing.nameNarrow,
            iconNum = existing.iconNum,
        })
    end
    recipeSpecKey = tostring(recipeSpecKey or "")
    if quality ~= "failed" and recipeSpecKey ~= "" then
        local keys = PotionRecipeKeys(existing)
        if type(keys) ~= "table" then
            keys = {}
        end
        existing.recipeKeys = keys
        existing.alternateRecipeSpecKeys = nil
        local seen = false
        for i = 1, #keys do
            if keys[i] == recipeSpecKey then
                seen = true
                break
            end
        end
        if not seen then
            keys[#keys + 1] = recipeSpecKey
        end
        local recipes = RecipesTable(s)
        DedupePotionRecipeKeys(existing, recipes)
        local recipe = recipes[recipeSpecKey]
        local crafts = recipe and tonumber(recipe.crafts) or 0
        local active = PotionActiveRecipeKey(existing)
        local activeRecipe = active and recipes[active]
        local activeCrafts = activeRecipe and tonumber(activeRecipe.crafts) or 0
        if active == nil or crafts >= activeCrafts then
            existing.activeRecipeKey = recipeSpecKey
        end
        existing.activeRecipeSpecKey = nil
        RS.ResolveEffectKeyForPotion(existing, {
            recipe = recipe,
            recipeKey = recipeSpecKey,
            out = out,
            itemData = out and out.itemData,
        })
    else
        RS.ResolveEffectKeyForPotion(existing, {
            out = out,
            itemData = out and out.itemData,
        })
    end
    potions[potionKey] = existing
    return existing
end

local function ApplyObservedYield(recipe)
    EnsureBrewStats(recipe)
    if recipe.yieldSamples > 0 and recipe.yieldProductSum > 0 then
        recipe.recipeYield = recipe.yieldProductSum / recipe.yieldSamples
    end
end

local function RecordExactSuccess(recipe, qty, mainConsumed)
    qty = tonumber(qty) or 0
    if qty < 1 then
        qty = 1
    end
    recipe.brewSuccesses = recipe.brewSuccesses + 1
    recipe.yieldProductSum = recipe.yieldProductSum + qty
    recipe.yieldSamples = recipe.yieldSamples + 1
    recipe.crafts = recipe.brewSuccesses
    if mainConsumed == false then
        recipe.brewCrits = recipe.brewCrits + 1
    end
    ApplyObservedYield(recipe)
end

local function RecordOutcome(recipe, potionUid, quality, qty)
    potionUid = tonumber(potionUid) or 0
    if potionUid <= 0 then
        return
    end
    if type(recipe.outcomes) ~= "table" then
        recipe.outcomes = {}
    end
    local key = tostring(potionUid)
    local oc = recipe.outcomes[key]
    if type(oc) ~= "table" then
        oc = { successes = 0, qtySum = 0 }
    end
    oc.quality = quality or oc.quality or "good"
    oc.successes = (tonumber(oc.successes) or 0) + 1
    oc.qtySum = (tonumber(oc.qtySum) or 0) + (tonumber(qty) or 1)
    recipe.outcomes[key] = oc
    if quality == "good" or (quality ~= "potent" and quality ~= "volatile"
        and (recipe.activeOutcomeUid == nil or tonumber(recipe.activeOutcomeUid) == potionUid))
    then
        if quality == "good" or recipe.activeOutcomeUid == nil then
            recipe.activeOutcomeUid = potionUid
            recipe.outputUid = potionUid
        end
    elseif recipe.activeOutcomeUid == nil and quality ~= "volatile" then
        recipe.activeOutcomeUid = potionUid
        recipe.outputUid = potionUid
    end
end

--- Observe one cauldron brew. One recipe per ingredient fingerprint;
--- Potent / volatile share that recipe via outcomes[potionUid].
function RS.StoreLearnedRecipeSpec(materials, outputs, opts)
    if type(materials) ~= "table" or #materials == 0 then
        return false
    end
    if type(outputs) ~= "table" then
        outputs = {}
    end
    if type(opts) ~= "table" then
        opts = {}
    end
    if not MS then
        return false
    end
    local s = EnsureSettings()
    local recipes = RecipesTable(s)
    local slots = RS.MaterialsToSpecSlots(materials)
    if #slots == 0 then
        return false
    end

    -- Incomplete mains (no EFFECT in craftingBonus) get fx from the brew output.
    RS.BackfillIncompleteMainsFromOutputs(slots, outputs)

    local byUid = {}
    local betterCount = 0
    local volatileCount = 0
    local goodUid = nil
    for i = 1, #outputs do
        local out = outputs[i]
        local uid = tonumber(out and out.uniqueID) or 0
        local quality = RS.OutputQuality(out)
        if uid > 0 and quality ~= "failed" then
            byUid[uid] = out
            if quality == "potent" then
                betterCount = betterCount + 1
            elseif quality == "volatile" then
                volatileCount = volatileCount + 1
            elseif quality == "good" and goodUid == nil then
                goodUid = uid
            end
        end
    end
    local producedAny = next(byUid) ~= nil
    local failed = not producedAny
    local mainConsumed = opts.mainConsumed
    if mainConsumed == nil then
        mainConsumed = true
    end
    local fingerprint = RS.SlotsFingerprint(slots)
    if fingerprint == "" then
        return false
    end

    local existingKey, existingRecipe = RS.FindRecipeByFingerprint(recipes, fingerprint)
    local recipe = existingRecipe
    local isNew = type(recipe) ~= "table"
    if isNew then
        recipe = {
            recipeSpecKey = fingerprint,
            slots = SlimSlotsForStorage(slots),
            outcomes = {},
            brewAttempts = 0,
            brewSuccesses = 0,
            brewCrits = 0,
            brewSuperCrits = 0,
            brewFailures = 0,
            brewVolatiles = 0,
            yieldProductSum = 0,
            yieldSamples = 0,
            crafts = 0,
            quality = "good",
        }
    else
        EnsureBrewStats(recipe)
        recipe.slots = SlimSlotsForStorage(slots)
        if type(existingKey) == "string" and existingKey ~= fingerprint then
            RemapRecipeSpecKey(s, existingKey, fingerprint, recipe)
        end
    end

    recipe.brewAttempts = (tonumber(recipe.brewAttempts) or 0) + 1

    if failed then
        recipe.brewFailures = (tonumber(recipe.brewFailures) or 0) + 1
    else
        local primaryQty = 0
        local primaryUid = goodUid
        for uid, out in pairs(byUid) do
            local quality = RS.OutputQuality(out)
            local qty = tonumber(out.lastDelta) or tonumber(out.crafts) or 1
            RecordOutcome(recipe, uid, quality, qty)
            RS.RegisterKnownPotion(uid, out, fingerprint, quality)
            if quality == "good" then
                primaryQty = primaryQty + qty
                primaryUid = uid
            elseif primaryUid == nil and quality == "potent" then
                primaryUid = uid
            end
        end
        if betterCount > 0 and (goodUid == nil or byUid[goodUid] == nil) then
            recipe.brewSuperCrits = (tonumber(recipe.brewSuperCrits) or 0) + 1
        end
        if volatileCount > 0 and betterCount == 0 and goodUid == nil then
            recipe.brewVolatiles = (tonumber(recipe.brewVolatiles) or 0) + 1
        end
        if goodUid and byUid[goodUid] then
            local qty = tonumber(byUid[goodUid].lastDelta) or tonumber(byUid[goodUid].crafts) or 1
            RecordExactSuccess(recipe, qty, mainConsumed)
        elseif primaryUid and byUid[primaryUid] and RS.OutputQuality(byUid[primaryUid]) == "potent" then
            -- Potent-only brew: still a success for learning, counted as super-crit miss for "good" yield.
            recipe.brewSuperCrits = (tonumber(recipe.brewSuperCrits) or 0) + 1
            if mainConsumed == false then
                recipe.brewCrits = (tonumber(recipe.brewCrits) or 0) + 1
            end
        elseif next(byUid) then
            -- Volatile or unclassified: count attempt side effects only.
            if mainConsumed == false then
                recipe.brewCrits = (tonumber(recipe.brewCrits) or 0) + 1
            end
        end
        if recipe.activeOutcomeUid == nil and primaryUid then
            recipe.activeOutcomeUid = primaryUid
            recipe.outputUid = primaryUid
        elseif goodUid then
            recipe.activeOutcomeUid = goodUid
            recipe.outputUid = goodUid
        end
    end

    recipes[fingerprint] = recipe
    RS.SlimRecipeForStorage(recipe)

    if StockPiler2.Trace then
        local rate = RS.RecipeSuccessRate(recipe)
        StockPiler2.Trace("Recipe " .. (isNew and "new" or "update")
            .. " key=" .. fingerprint
            .. " yield=" .. tostring(recipe.recipeYield)
            .. " success=" .. tostring(recipe.brewSuccesses)
            .. "/" .. tostring(recipe.brewAttempts)
            .. (rate and (" (" .. tostring(math.floor(rate * 100 + 0.5)) .. "%)") or "")
            .. (mainConsumed == false and " main-kept" or "")
            .. (failed and " FAIL" or ""))
    end
    if isNew and not failed then
        local firstOut = nil
        for _, out in pairs(byUid) do
            firstOut = out
            break
        end
        if firstOut and StockPiler2.NotifyRecipeLearned then
            StockPiler2.NotifyRecipeLearned(firstOut)
        end
    end

    if StockPiler2.Inventory and StockPiler2.Inventory.InvalidateRecipeCaches then
        StockPiler2.Inventory.InvalidateRecipeCaches()
    end
    if StockPiler2.Planner and StockPiler2.Planner.InvalidatePlanCache then
        StockPiler2.Planner.InvalidatePlanCache()
    end
    if StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
        StockPiler2.Knowledge.Touch()
    end
    return true
end

local function CollectUidsFromRecipe(recipe)
    local uids = {}
    local seen = {}
    local function add(uid)
        uid = tonumber(uid) or 0
        if uid > 0 and not seen[uid] then
            seen[uid] = true
            uids[#uids + 1] = uid
        end
    end
    if type(recipe) ~= "table" then
        return uids
    end
    add(recipe.outputUid)
    add(recipe.activeOutcomeUid)
    if type(recipe.slots) == "table" then
        for i = 1, #recipe.slots do
            local slot = recipe.slots[i]
            if type(slot) == "table" then
                add(slot.uid)
            end
        end
    end
    if type(recipe.outcomes) == "table" then
        for uidKey, _ in pairs(recipe.outcomes) do
            add(uidKey)
        end
    end
    return uids
end

local function IsUidReferencedInAccount(s, uid)
    uid = tonumber(uid) or 0
    if uid <= 0 or type(s) ~= "table" then
        return false
    end
    local uidKey = tostring(uid)
    local recipes = s.recipes or s.learnedRecipeSpecs
    if type(recipes) == "table" then
        for _, recipe in pairs(recipes) do
            if type(recipe) == "table" then
                if (tonumber(recipe.outputUid) or 0) == uid
                    or (tonumber(recipe.activeOutcomeUid) or 0) == uid
                then
                    return true
                end
                if type(recipe.outcomes) == "table" and type(recipe.outcomes[uidKey]) == "table" then
                    return true
                end
                if type(recipe.slots) == "table" then
                    for i = 1, #recipe.slots do
                        local slot = recipe.slots[i]
                        if type(slot) == "table" and (tonumber(slot.uid) or 0) == uid then
                            return true
                        end
                    end
                end
            end
        end
    end
    local potions = s.potions or s.knownPotions
    if type(potions) == "table" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" and (tonumber(potion.outputUid) or 0) == uid then
                return true
            end
        end
    end
    if type(s.grows) == "table" then
        if type(s.grows[uidKey]) == "table" then
            return true
        end
        for _, plants in pairs(s.grows) do
            if type(plants) == "table" and type(plants[uidKey]) == "table" then
                return true
            end
        end
    end
    if type(s.refines) == "table" then
        if type(s.refines[uidKey]) == "table" then
            return true
        end
        for plantKey, row in pairs(s.refines) do
            if type(row) == "table" then
                if (tonumber(plantKey) or 0) == uid or (tonumber(row.seedUid) or 0) == uid then
                    return true
                end
                if type(row.byproducts) == "table" and type(row.byproducts[uidKey]) == "table" then
                    return true
                end
            end
        end
    end
    return false
end

local function PruneOrphanItems(uids, s)
    if type(uids) ~= "table" or type(s) ~= "table" then
        return 0
    end
    local items = s.items
    if type(items) ~= "table" then
        return 0
    end
    local removed = 0
    for i = 1, #uids do
        local uid = uids[i]
        if not IsUidReferencedInAccount(s, uid) then
            local key = tostring(uid)
            if items[key] ~= nil then
                items[key] = nil
                removed = removed + 1
            end
        end
    end
    return removed
end

local function WatchKeyMatchesRecipe(watchKey, recipeSpecKey)
    watchKey = tostring(watchKey or "")
    recipeSpecKey = tostring(recipeSpecKey or "")
    if watchKey == "" or recipeSpecKey == "" then
        return false
    end
    if watchKey == recipeSpecKey then
        return true
    end
    local suffix = "|rk:" .. recipeSpecKey
    return #watchKey >= #suffix and string.sub(watchKey, -#suffix) == suffix
end

local function WatchKeyMatchesPotion(watchKey, potionKey)
    watchKey = tostring(watchKey or "")
    potionKey = tostring(potionKey or "")
    if watchKey == "" or potionKey == "" then
        return false
    end
    if watchKey == potionKey then
        return true
    end
    local prefix = potionKey .. "|"
    return string.sub(watchKey, 1, #prefix) == prefix
end

local function ScrubPotionWatchKeys(watches, potionKey)
    if type(watches) ~= "table" or type(potionKey) ~= "string" or potionKey == "" then
        return 0
    end
    local drop = {}
    for watchKey, _ in pairs(watches) do
        if WatchKeyMatchesPotion(watchKey, potionKey) then
            drop[#drop + 1] = watchKey
        end
    end
    for i = 1, #drop do
        watches[drop[i]] = nil
    end
    return #drop
end

local function CharacterBuckets(s)
    if type(s) == "table" and type(s.characters) == "table" then
        return s.characters
    end
    if StockPiler2.ProfileSettings then
        local profile = StockPiler2.ProfileSettings()
        if type(profile) == "table" and type(profile.characters) == "table" then
            return profile.characters
        end
    end
    return nil
end

local function ScrubExactWatchKeyFromTable(watches, watchKey)
    if type(watches) ~= "table" or type(watchKey) ~= "string" or watchKey == "" then
        return 0
    end
    if watches[watchKey] ~= nil then
        watches[watchKey] = nil
        return 1
    end
    return 0
end

local function ScrubExactWatchKeyAll(s, watchKey)
    if type(s) ~= "table" then
        return 0
    end
    local n = ScrubExactWatchKeyFromTable(s.watches, watchKey)
    local chars = CharacterBuckets(s)
    if type(chars) == "table" then
        for _, char in pairs(chars) do
            if type(char) == "table" then
                n = n + ScrubExactWatchKeyFromTable(char.watches, watchKey)
            end
        end
    end
    return n
end

local function ScrubWatchesFromTable(watches, recipeSpecKey, potionKeys)
    if type(watches) ~= "table" then
        return 0
    end
    local drop = {}
    for watchKey, _ in pairs(watches) do
        local remove = WatchKeyMatchesRecipe(watchKey, recipeSpecKey)
        if not remove and type(potionKeys) == "table" then
            for i = 1, #potionKeys do
                if WatchKeyMatchesPotion(watchKey, potionKeys[i]) then
                    remove = true
                    break
                end
            end
        end
        if remove then
            drop[#drop + 1] = watchKey
        end
    end
    for i = 1, #drop do
        watches[drop[i]] = nil
    end
    return #drop
end

local function ScrubPotionWatchKeysAll(s, potionKey)
    if type(s) ~= "table" or type(potionKey) ~= "string" or potionKey == "" then
        return 0
    end
    local n = ScrubPotionWatchKeys(s.watches, potionKey)
    local chars = CharacterBuckets(s)
    if type(chars) == "table" then
        for _, char in pairs(chars) do
            if type(char) == "table" then
                n = n + ScrubPotionWatchKeys(char.watches, potionKey)
            end
        end
    end
    return n
end

local function PruneForgottenRecipeWatches(s, recipeSpecKey, potionKeys)
    if type(s) ~= "table" then
        return 0
    end
    local n = ScrubWatchesFromTable(s.watches, recipeSpecKey, potionKeys)
    local chars = CharacterBuckets(s)
    if type(chars) == "table" then
        for _, char in pairs(chars) do
            if type(char) == "table" then
                n = n + ScrubWatchesFromTable(char.watches, recipeSpecKey, potionKeys)
            end
        end
    end
    return n
end

local function RecomputeRecipePrimaryOutcome(recipe)
    if type(recipe) ~= "table" then
        return
    end
    if type(recipe.outcomes) ~= "table" or next(recipe.outcomes) == nil then
        recipe.activeOutcomeUid = nil
        recipe.outputUid = nil
        return
    end
    local goodUid = nil
    local anyUid = nil
    for uidKey, oc in pairs(recipe.outcomes) do
        local uid = tonumber(uidKey) or 0
        if uid > 0 then
            anyUid = uid
            if type(oc) == "table" and oc.quality == "good" then
                goodUid = uid
                break
            end
        end
    end
    local primary = goodUid or anyUid
    if primary then
        recipe.activeOutcomeUid = primary
        recipe.outputUid = primary
    else
        recipe.activeOutcomeUid = nil
        recipe.outputUid = nil
    end
end

local function TouchForgetSideEffects()
    if StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
        StockPiler2.Knowledge.Touch()
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.InvalidateRecipeCaches then
        StockPiler2.Inventory.InvalidateRecipeCaches()
    end
    if StockPiler2.Planner and StockPiler2.Planner.InvalidatePlanCache then
        StockPiler2.Planner.InvalidatePlanCache()
    end
end

--- Drop recipes no potion row still references via recipeKeys.
function RS.ForgetRecipesWithoutLinkedPotions()
    local s = EnsureSettings()
    local recipes = RecipesTable(s)
    local potions = PotionsTable(s)
    if type(recipes) ~= "table" then
        return 0
    end
    local linked = {}
    if type(potions) == "table" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" then
                local keys = PotionRecipeKeys(potion)
                if type(keys) == "table" then
                    for i = 1, #keys do
                        local key = keys[i]
                        if type(key) == "string" and key ~= "" then
                            linked[key] = true
                            local canon = RS.RecipeFingerprintForKey(recipes, key)
                            if type(canon) == "string" and canon ~= "" then
                                linked[canon] = true
                            end
                        end
                    end
                end
            end
        end
    end
    local removed = 0
    local toDrop = {}
    for key, recipe in pairs(recipes) do
        if type(recipe) == "table" and linked[key] ~= true then
            toDrop[#toDrop + 1] = key
        end
    end
    for i = 1, #toDrop do
        local key = toDrop[i]
        local recipe = recipes[key]
        local orphanCandidates = CollectUidsFromRecipe(recipe)
        recipes[key] = nil
        PruneForgottenRecipeWatches(s, key, nil)
        local prunedItems = PruneOrphanItems(orphanCandidates, s)
        if prunedItems > 0 and StockPiler2.Trace then
            StockPiler2.Trace("Forgot orphan recipe pruned " .. tostring(prunedItems) .. " item(s)")
        end
        removed = removed + 1
    end
    return removed
end

--- Forget one potion uid x recipe fingerprint link; keep shared recipe if siblings remain.
function RS.ForgetPotionRecipeLink(outputUid, recipeSpecKey)
    outputUid = tonumber(outputUid) or 0
    recipeSpecKey = tostring(recipeSpecKey or "")
    if outputUid <= 0 or recipeSpecKey == "" then
        return false
    end
    local s = EnsureSettings()
    local recipes = RecipesTable(s)
    local potions = PotionsTable(s)
    local potionKey = RS.PotionKeyFromUid(outputUid)
    local potion = type(potionKey) == "string" and potions[potionKey] or nil
    local recipe = recipes[recipeSpecKey]
    local hadLink = false
    if type(potion) == "table" then
        local keys = PotionRecipeKeys(potion)
        if type(keys) == "table" then
            for i = 1, #keys do
                if keys[i] == recipeSpecKey then
                    hadLink = true
                    break
                end
            end
        end
    end
    if type(recipe) == "table" and type(recipe.outcomes) == "table"
        and type(recipe.outcomes[tostring(outputUid)]) == "table"
    then
        hadLink = true
    end
    if not hadLink then
        return false
    end

    local orphanCandidates = { outputUid }

    if type(potion) == "table" then
        if PotionActiveRecipeKey(potion) == recipeSpecKey then
            potion.activeRecipeKey = nil
            potion.activeRecipeSpecKey = nil
        end
        local keys = PotionRecipeKeys(potion)
        if type(keys) == "table" then
            local trimmed = {}
            for j = 1, #keys do
                if keys[j] ~= recipeSpecKey then
                    trimmed[#trimmed + 1] = keys[j]
                end
            end
            potion.recipeKeys = trimmed
            potion.alternateRecipeSpecKeys = nil
            if PotionActiveRecipeKey(potion) == nil then
                for j = 1, #trimmed do
                    if type(recipes[trimmed[j]]) == "table" then
                        potion.activeRecipeKey = trimmed[j]
                        break
                    end
                end
            end
        end
        potion.activeRecipeSpecKey = nil
    end

    if type(recipe) == "table" then
        if type(recipe.outcomes) == "table" then
            recipe.outcomes[tostring(outputUid)] = nil
        end
        RecomputeRecipePrimaryOutcome(recipe)
    end

    local compositeKey = RS.PotionRecipeKey(outputUid, recipeSpecKey)
    if compositeKey then
        ScrubExactWatchKeyAll(s, compositeKey)
    end

    RS.ForgetKnownPotionsWithoutRecipe()
    RS.ForgetRecipesWithoutLinkedPotions()
    local prunedItems = PruneOrphanItems(orphanCandidates, s)
    if prunedItems > 0 and StockPiler2.Trace then
        StockPiler2.Trace("Forgot link pruned " .. tostring(prunedItems) .. " orphan item(s)")
    end
    TouchForgetSideEffects()
    return true
end

function RS.ForgetLearnedRecipeSpec(recipeSpecKey)
    recipeSpecKey = tostring(recipeSpecKey or "")
    if recipeSpecKey == "" then
        return false
    end
    local s = EnsureSettings()
    local recipes = RecipesTable(s)
    local recipe = recipes[recipeSpecKey]
    if type(recipe) ~= "table" then
        return false
    end

    local pairs = {}
    local seen = {}
    local function addPair(uid)
        uid = tonumber(uid) or 0
        if uid > 0 then
            local id = tostring(uid) .. "|" .. recipeSpecKey
            if seen[id] ~= true then
                seen[id] = true
                pairs[#pairs + 1] = { uid = uid, key = recipeSpecKey }
            end
        end
    end

    if type(recipe.outcomes) == "table" then
        for uidKey, _ in pairs(recipe.outcomes) do
            addPair(uidKey)
        end
    end
    local potions = PotionsTable(s)
    for _, potion in pairs(potions) do
        if type(potion) == "table" then
            local uid = tonumber(potion.outputUid) or 0
            local keys = PotionRecipeKeys(potion)
            if uid > 0 and type(keys) == "table" then
                for i = 1, #keys do
                    if keys[i] == recipeSpecKey then
                        addPair(uid)
                    end
                end
            end
        end
    end

    if #pairs == 0 then
        local orphanCandidates = CollectUidsFromRecipe(recipe)
        recipes[recipeSpecKey] = nil
        PruneForgottenRecipeWatches(s, recipeSpecKey, nil)
        RS.ForgetKnownPotionsWithoutRecipe()
        local prunedItems = PruneOrphanItems(orphanCandidates, s)
        if prunedItems > 0 and StockPiler2.Trace then
            StockPiler2.Trace("Forgot recipe pruned " .. tostring(prunedItems) .. " orphan item(s)")
        end
        TouchForgetSideEffects()
        return true
    end

    for i = 1, #pairs do
        RS.ForgetPotionRecipeLink(pairs[i].uid, pairs[i].key)
    end
    return true
end

local function PotionHasLearnedRecipe(s, potion)
    if type(s) ~= "table" or type(potion) ~= "table" then
        return false
    end
    local recipes = s.recipes or s.learnedRecipeSpecs
    if type(recipes) ~= "table" then
        return false
    end
    local key = PotionActiveRecipeKey(potion)
    if type(key) == "string" and key ~= "" and type(recipes[key]) == "table" then
        return true
    end
    local uid = tonumber(potion.outputUid) or 0
    if uid <= 0 then
        return false
    end
    local uidKey = tostring(uid)
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            if (tonumber(recipe.outputUid) or 0) == uid
                or (tonumber(recipe.activeOutcomeUid) or 0) == uid
            then
                return true
            end
            if type(recipe.outcomes) == "table" and type(recipe.outcomes[uidKey]) == "table" then
                return true
            end
        end
    end
    return false
end

--- Drop potions that were never linked to a learned recipe.
function RS.ForgetKnownPotionsWithoutRecipe()
    local s = EnsureSettings()
    local potions = PotionsTable(s)
    local removed = 0
    for key, potion in pairs(potions) do
        if type(potion) ~= "table" or not PotionHasLearnedRecipe(s, potion) then
            potions[key] = nil
            ScrubPotionWatchKeysAll(s, key)
            removed = removed + 1
        end
    end
    return removed
end

function RS.GetKnownPotionList()
    local s = EnsureSettings()
    local list = {}
    local potions = PotionsTable(s)
    for _, potion in pairs(potions) do
        if type(potion) == "table" and potion.outputUid and PotionHasLearnedRecipe(s, potion) then
            list[#list + 1] = potion
        end
    end
    table.sort(list, function(a, b)
        return ToNarrow(a.name) < ToNarrow(b.name)
    end)
    return list
end

function RS.GetRecipeSpecList()
    local s = EnsureSettings()
    local list = {}
    local recipes = RecipesTable(s)
    local potions = PotionsTable(s)
    for key, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            RS.HydrateRecipeSlots(recipe)
            local uid = tonumber(recipe.activeOutcomeUid) or tonumber(recipe.outputUid) or 0
            local potion = potions[RS.PotionKeyFromUid(uid)]
            list[#list + 1] = {
                recipeSpecKey = recipe.recipeSpecKey or key,
                outputUid = uid,
                slots = recipe.slots,
                outcomes = recipe.outcomes,
                quality = recipe.quality or "good",
                recipeYield = RS.RecipeOutputYield(recipe),
                crafts = tonumber(recipe.crafts) or 0,
                brewAttempts = tonumber(recipe.brewAttempts) or 0,
                brewSuccesses = tonumber(recipe.brewSuccesses) or 0,
                brewCrits = tonumber(recipe.brewCrits) or 0,
                brewSuperCrits = tonumber(recipe.brewSuperCrits) or 0,
                brewFailures = tonumber(recipe.brewFailures) or 0,
                brewVolatiles = tonumber(recipe.brewVolatiles) or 0,
                yieldProductSum = tonumber(recipe.yieldProductSum) or 0,
                yieldSamples = tonumber(recipe.yieldSamples) or 0,
                successRate = RS.RecipeSuccessRate(recipe),
                potionName = potion and potion.name,
                potionIcon = potion and potion.iconNum or 0,
            }
        end
    end
    table.sort(list, function(a, b)
        return ToNarrow(a.potionName) < ToNarrow(b.potionName)
    end)
    return list
end

function RS.RecipeSpecForPotion(potionKey)
    local s = EnsureSettings()
    local potions = PotionsTable(s)
    local parsed = RS.ParsePotionRecipeKey(potionKey)
    if type(parsed) == "table" and parsed.isComposite == true then
        return RS.RecipeSpecForPotionRecipe(potionKey)
    end
    local potion = potions[potionKey]
    if type(potion) ~= "table" then
        return nil
    end
    local key = PotionActiveRecipeKey(potion)
    if type(key) ~= "string" or key == "" then
        local keys = PotionRecipeKeys(potion)
        if type(keys) == "table" and type(keys[1]) == "string" then
            key = keys[1]
        end
    end
    if type(key) ~= "string" or key == "" then
        return nil
    end
    local recipes = RecipesTable(s)
    local recipe = recipes[key]
    if type(recipe) ~= "table" then
        return nil
    end
    RS.HydrateRecipeSlots(recipe)
    -- Expose the watched potion as outputUid for planners/tooltips.
    local uid = tonumber(potion.outputUid) or 0
    if uid > 0 then
        recipe.outputUid = uid
    end
    return recipe
end

--- Recipe for a composite potionRecipeKey (uid:N|rk:fingerprint).
function RS.RecipeSpecForPotionRecipe(potionRecipeKey)
    local parsed = RS.ParsePotionRecipeKey(potionRecipeKey)
    if type(parsed) ~= "table" or type(parsed.recipeSpecKey) ~= "string" then
        return nil
    end
    local s = EnsureSettings()
    local recipes = RecipesTable(s)
    local recipe = recipes[parsed.recipeSpecKey]
    if type(recipe) ~= "table" then
        return nil
    end
    RS.HydrateRecipeSlots(recipe)
    local uid = tonumber(parsed.outputUid) or 0
    if uid > 0 then
        recipe.outputUid = uid
    end
    return recipe
end

--- Resolve watch/catalog key to potion row + recipeSpecKey (legacy uid:N or composite).
function RS.ResolveWatchPotion(watchKey)
    local s = EnsureSettings()
    local potions = PotionsTable(s)
    local parsed = RS.ParsePotionRecipeKey(watchKey)
    if type(parsed) ~= "table" then
        local potion = potions[watchKey]
        if type(potion) ~= "table" then
            return nil
        end
        return {
            potion = potion,
            potionKey = potion.potionKey or watchKey,
            potionRecipeKey = watchKey,
            recipeSpecKey = PotionActiveRecipeKey(potion),
            outputUid = tonumber(potion.outputUid) or 0,
        }
    end
    local potion = potions[parsed.potionKey]
    if type(potion) ~= "table" then
        return nil
    end
    local recipeSpecKey = parsed.recipeSpecKey
    if recipeSpecKey == nil or recipeSpecKey == "" then
        recipeSpecKey = PotionActiveRecipeKey(potion)
        local keys = PotionRecipeKeys(potion)
        if (recipeSpecKey == nil or recipeSpecKey == "") and type(keys) == "table" then
            recipeSpecKey = keys[1]
        end
    end
    local potionRecipeKey = parsed.isComposite and parsed.potionRecipeKey
        or RS.PotionRecipeKey(parsed.outputUid, recipeSpecKey)
    return {
        potion = potion,
        potionKey = parsed.potionKey,
        potionRecipeKey = potionRecipeKey,
        recipeSpecKey = recipeSpecKey,
        outputUid = parsed.outputUid,
    }
end

--- One catalog entry per (outputUid, recipeSpecKey) that can produce that potion.
function RS.ListPotionRecipeEntries()
    local s = EnsureSettings()
    local list = {}
    local potions = PotionsTable(s)
    local recipes = RecipesTable(s)
    for _, potion in pairs(potions) do
        if type(potion) == "table" and potion.outputUid and PotionHasLearnedRecipe(s, potion) then
            local uid = tonumber(potion.outputUid) or 0
            local keys = PotionRecipeKeys(potion)
            if type(keys) ~= "table" then
                keys = {}
            end
            local active = PotionActiveRecipeKey(potion)
            if #keys == 0 and type(active) == "string" and active ~= "" then
                keys = { active }
            end
            local seen = {}
            local seenRow = {}
            for i = 1, #keys do
                local recipeKey = keys[i]
                if type(recipeKey) == "string" and recipeKey ~= "" and seen[recipeKey] ~= true then
                    seen[recipeKey] = true
                    local recipe = recipes[recipeKey]
                    if type(recipe) == "table" then
                        local include = true
                        if type(recipe.outcomes) == "table" then
                            local oc = recipe.outcomes[tostring(uid)]
                            if oc == nil and next(recipe.outcomes) ~= nil then
                                -- Linked on potion but this fingerprint never produced this uid.
                                include = false
                            end
                        end
                        if include then
                            RS.HydrateRecipeSlots(recipe)
                            local rowFp = RS.SlotsFingerprint(recipe.slots)
                            if rowFp == "" then
                                rowFp = recipeKey
                            end
                            local rowId = tostring(uid) .. "|" .. rowFp
                            if seenRow[rowId] ~= true then
                                seenRow[rowId] = true
                                local prKey = RS.PotionRecipeKey(uid, recipeKey)
                                local stats = RS.RecipeFingerprintStats(recipe, uid)
                                list[#list + 1] = {
                                    potionRecipeKey = prKey,
                                    potionKey = potion.potionKey or RS.PotionKeyFromUid(uid),
                                    outputUid = uid,
                                    recipeSpecKey = recipeKey,
                                    name = potion.name,
                                    nameNarrow = potion.nameNarrow,
                                    iconNum = tonumber(potion.iconNum) or 0,
                                    effectKey = potion.effectKey,
                                    recipeLabel = RS.RecipeLabelForRecipe(recipe, uid),
                                    power = stats.power,
                                    stability = stats.stability,
                                    superCrit = stats.superCrit,
                                    yield = stats.yield,
                                    potion = potion,
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b)
        local na = ToNarrow(a.name)
        local nb = ToNarrow(b.name)
        if na ~= nb then
            return na < nb
        end
        return ToNarrow(a.recipeLabel) < ToNarrow(b.recipeLabel)
    end)
    return list
end

--- Remap legacy watches["uid:N"] to watches["uid:N|rk:..."].
--- Uses Settings in place when already binding (do not re-enter EnsureSettings).
function RS.MigrateWatchesToPotionRecipeKeys()
    local s = StockPiler2.Settings
    if type(s) ~= "table" or type(s.watches) ~= "table" then
        if StockPiler2._bindingCharacter == true then
            return 0
        end
        s = EnsureSettings()
    end
    if type(s) ~= "table" or type(s.watches) ~= "table" then
        return 0
    end
    local potions = PotionsTable(s)
    local moved = 0
    local toAdd = {}
    local toRemove = {}
    for key, watch in pairs(s.watches) do
        if type(watch) == "table" and not RS.IsPotionRecipeKey(key) then
            local parsed = RS.ParsePotionRecipeKey(key)
            local potionKey = key
            if type(parsed) == "table" and parsed.potionKey then
                potionKey = parsed.potionKey
            end
            local potion = potions[potionKey]
            if type(potion) == "table" then
                local recipeKey = PotionActiveRecipeKey(potion)
                local keys = PotionRecipeKeys(potion)
                if (recipeKey == nil or recipeKey == "") and type(keys) == "table" then
                    recipeKey = keys[1]
                end
                local newKey = RS.PotionRecipeKey(potion.outputUid, recipeKey)
                if type(newKey) == "string" and newKey ~= key then
                    if type(s.watches[newKey]) ~= "table" then
                        toAdd[newKey] = watch
                    else
                        -- Prefer enabled / higher target when merging.
                        local existing = s.watches[newKey]
                        if watch.enabled == true then
                            existing.enabled = true
                        end
                        if (tonumber(watch.targetStock) or 0) > (tonumber(existing.targetStock) or 0) then
                            existing.targetStock = watch.targetStock
                        end
                        if watch.autoGrow == false then
                            existing.autoGrow = false
                        end
                    end
                    toRemove[#toRemove + 1] = key
                    moved = moved + 1
                end
            end
        end
    end
    for i = 1, #toRemove do
        s.watches[toRemove[i]] = nil
    end
    for newKey, watch in pairs(toAdd) do
        s.watches[newKey] = watch
    end
    return moved
end

function RS.ClearCountCaches()
    RS._specHaveCache = nil
    RS._demandCache = nil
    RS._demandSnapGen = nil
    RS._autoGrowSeedLines = nil
    RS._autoGrowSeedLinesKey = nil
end

local function AutoGrowSeedLinesCacheKey()
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    local gardenGen = 0
    if StockPiler2.Garden and StockPiler2.Garden.GetGen then
        gardenGen = tonumber(StockPiler2.Garden.GetGen()) or 0
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
    return tostring(snapGen) .. ":" .. tostring(gardenGen) .. ":" .. tostring(watchGen)
        .. ":" .. tostring(buffer) .. ":" .. enabled
end

function RS.CountItemsMatchingSpec(spec)
    if type(spec) ~= "table" or not MS then
        return 0
    end
    if not MS.ProductMatches and not MS.Matches then
        return 0
    end
    local specKey = MS.Key and MS.Key(spec) or nil
    local cache = RS._specHaveCache
    if type(cache) == "table" and specKey ~= nil and cache[specKey] ~= nil then
        return cache[specKey]
    end
    local total = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if StockPiler2.Inventory.CanUseCraftingItem
                and not StockPiler2.Inventory.CanUseCraftingItem(item)
            then
                return
            end
            if StockPiler2.Inventory.IsSeedOrSporeItem
                and StockPiler2.Inventory.IsSeedOrSporeItem(item)
            then
                return
            end
            local match = false
            if MS.ProductMatches then
                match = MS.ProductMatches(item, spec) == true
            elseif MS.Matches then
                match = MS.Matches(item, spec) == true
            end
            if match then
                local n = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                total = total + math.max(1, n)
            end
        end)
    end
    if type(cache) == "table" and specKey ~= nil then
        cache[specKey] = total
    end
    return total
end

function RS.SpecStabilityTotal(slots)
    local total = 0
    if type(slots) ~= "table" or not MS then
        return total
    end
    for i = 1, #slots do
        local slot = slots[i]
        local role = slot.role or ""
        if role ~= "extender" and role ~= "multiplier" and role ~= "stimulant" then
            local per = tonumber(slot.perCraft) or 1
            local spec = RS.ResolveSlotSpec(slot)
            total = total + MS.Stability(spec) * per
        end
    end
    return total
end

function RS.EffectiveSpecPerCraft(slot, slots)
    local perCraft = tonumber(slot.perCraft) or 1
    if type(slot) ~= "table" or type(slots) ~= "table" or not MS then
        return perCraft
    end
    local role = slot.role or ""
    if role ~= "stabilizer" and role ~= "goldweed" then
        return perCraft
    end
    local total = RS.SpecStabilityTotal(slots)
    if total >= 0 then
        return perCraft
    end
    local stab = MS.Stability(RS.ResolveSlotSpec(slot))
    if stab <= 0 then
        return perCraft
    end
    return perCraft + math.ceil(-total / stab)
end

--- How many full crafts current bags can support (min over every slot).
--- opts.respectGrowReserve: subtract AutoGrow-reserved growable plants (cached plan).
function RS.CountCraftsPossible(recipe, opts)
    if type(recipe) ~= "table" then
        return 0
    end
    opts = type(opts) == "table" and opts or nil
    RS.HydrateRecipeSlots(recipe)
    local slots = recipe.slots
    if type(slots) ~= "table" or #slots == 0 then
        return 0
    end
    local possible = nil
    for i = 1, #slots do
        local slot = slots[i]
        local spec = RS.ResolveSlotSpec(slot)
        if type(slot) == "table" and type(spec) == "table" then
            local perCraft = RS.EffectiveSpecPerCraft(slot, slots)
            if perCraft < 1 then
                perCraft = 1
            end
            local have = RS.CountItemsMatchingSpec(spec)
            if opts and opts.respectGrowReserve == true
                and StockPiler2.Planner
                and StockPiler2.Planner.BrewAvailableForSpec
            then
                have = StockPiler2.Planner.BrewAvailableForSpec(spec)
            end
            local craftsHave = math.floor(have / perCraft)
            if craftsHave < 0 then
                craftsHave = 0
            end
            if possible == nil or craftsHave < possible then
                possible = craftsHave
            end
        end
    end
    return possible or 0
end

--- Observed bottles of this potion per successful brew of its fingerprint.
--- Optional potionUid selects a shared-recipe outcome (potent / volatile / good).
--- Planner fallback is the last stored yield, then 2 if never observed.
function RS.RecipeOutputYield(recipe, potionUid)
    potionUid = tonumber(potionUid) or 0
    if type(recipe) == "table" and type(recipe.outcomes) == "table" then
        local uid = potionUid
        if uid <= 0 then
            uid = tonumber(recipe.outputUid) or tonumber(recipe.activeOutcomeUid) or 0
        end
        if uid > 0 then
            local oc = recipe.outcomes[tostring(uid)]
            if type(oc) == "table" then
                local successes = tonumber(oc.successes) or 0
                local qtySum = tonumber(oc.qtySum) or 0
                if successes > 0 and qtySum > 0 then
                    return qtySum / successes
                end
            end
        end
    end
    local observed = RS.ObservedRecipeYield(recipe)
    if observed and observed > 0 then
        return observed
    end
    local yield = tonumber(recipe and recipe.recipeYield) or 2
    if yield < 1 then
        yield = 1
    end
    return yield
end

--- Sync stored recipeYield from observed products / successful brews.
function RS.RepairRecipeYields()
    local s = EnsureSettings()
    local recipes = type(s) == "table" and (s.recipes or s.learnedRecipeSpecs) or nil
    if type(recipes) ~= "table" then
        return 0
    end
    local fixed = 0
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            EnsureBrewStats(recipe)
            local observed = RS.ObservedRecipeYield(recipe)
            if observed and tonumber(recipe.recipeYield) ~= observed then
                recipe.recipeYield = observed
                fixed = fixed + 1
            end
        end
    end
    if fixed > 0 and StockPiler2.Inventory and StockPiler2.Inventory.InvalidateRecipeCaches then
        StockPiler2.Inventory.InvalidateRecipeCaches()
    end
    if fixed > 0 and StockPiler2.Planner and StockPiler2.Planner.InvalidatePlanCache then
        StockPiler2.Planner.InvalidatePlanCache()
    end
    return fixed
end

-- Watched stock is exact output uniqueID. A crit (Potent) is not a
-- success for this watch. Yield is observed bottles per exact-match
-- success; a leftover deficit rebuilds the plan.
function RS.WatchStockYield(recipe)
    return RS.RecipeOutputYield(recipe)
end

--- Stock + best-case Craftable already reaches Target#. AutoGrow should
--- not plant more for this watch (seed-buffer maintenance is separate).
function RS.WatchCoveredByBagsAndCraftable(potion, recipe, target)
    target = tonumber(target) or 0
    if target <= 0 then
        return true
    end
    local have = RS.PotionHaveCombined(potion)
    if have >= target then
        return true
    end
    if type(recipe) ~= "table" or not RS.CountPotionsCraftable then
        return false
    end
    return have + RS.CountPotionsCraftable(recipe) >= target
end

--- Mark craftableShared on each info among deficit watches only.
--- Stocked watches (deficit <= 0) never participate and get craftableShared = false.
--- infos[i] fields: potionDeficit, craftable, craftsPossible, recipe
function RS.ApplyDeficitCraftableShared(infos)
    if type(infos) ~= "table" then
        return
    end
    local MS = StockPiler2.MaterialSpec
    local matUsers = {}
    for i = 1, #infos do
        local info = infos[i]
        if type(info) == "table" then
            info.craftableShared = false
            local deficit = tonumber(info.potionDeficit) or 0
            local craftable = tonumber(info.craftable) or 0
            if deficit > 0 and craftable > 0 then
                local recipe = info.recipe
                if type(recipe) == "table" and type(recipe.slots) == "table" and MS and MS.Key then
                    if RS.HydrateRecipeSlots then
                        RS.HydrateRecipeSlots(recipe)
                    end
                    local slots = recipe.slots
                    local craftsPossible = tonumber(info.craftsPossible) or 0
                    local craftsNeeded = tonumber(info.craftsNeeded)
                    if craftsNeeded == nil and RS.CraftsNeededForDeficit then
                        craftsNeeded = tonumber(RS.CraftsNeededForDeficit(deficit, recipe)) or craftsPossible
                        info.craftsNeeded = craftsNeeded
                    end
                    local crafts = math.min(craftsPossible, craftsNeeded or craftsPossible)
                    info.craftsClaim = crafts
                    for s = 1, #slots do
                        local slot = slots[s]
                        local spec = slot and (slot.spec or (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)))
                        if type(spec) == "table" then
                            local specKey = MS.Key(spec)
                            if type(specKey) == "string" and specKey ~= "" then
                                local perCraft = RS.EffectiveSpecPerCraft and RS.EffectiveSpecPerCraft(slot, slots) or 1
                                local list = matUsers[specKey]
                                if list == nil then
                                    list = {}
                                    matUsers[specKey] = list
                                end
                                list[#list + 1] = {
                                    infoIdx = i,
                                    perCraft = tonumber(perCraft) or 1,
                                    crafts = crafts,
                                    spec = spec,
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    for i = 1, #infos do
        local info = infos[i]
        if type(info) ~= "table" then
            -- skip
        elseif (tonumber(info.potionDeficit) or 0) <= 0 or (tonumber(info.craftable) or 0) <= 0 then
            info.craftableShared = false
        else
            local contested = false
            local recipe = info.recipe
            if type(recipe) == "table" and type(recipe.slots) == "table" and MS and MS.Key then
                local slots = recipe.slots
                for s = 1, #slots do
                    local slot = slots[s]
                    local spec = slot and (slot.spec or (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)))
                    if type(spec) == "table" then
                        local specKey = MS.Key(spec)
                        local users = type(specKey) == "string" and matUsers[specKey] or nil
                        if type(users) == "table" and #users > 1 then
                            local combinedNeed = 0
                            for u = 1, #users do
                                combinedNeed = combinedNeed + (users[u].crafts * users[u].perCraft)
                            end
                            local have = 0
                            if RS.CountItemsMatchingSpec then
                                have = tonumber(RS.CountItemsMatchingSpec(spec)) or 0
                            end
                            if have < combinedNeed then
                                contested = true
                                break
                            end
                        end
                    end
                end
            end
            info.craftableShared = contested
        end
    end
end

--- Contested map for enabled deficit watches: watchKey -> craftableShared.
--- Matches Planner Status/Craftable (stocked leftover craftable ignored).
function RS.BuildWatchDeficitContestedByKey()
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    local watchGen = 0
    if StockPiler2.Watch and StockPiler2.Watch.GetGen then
        watchGen = tonumber(StockPiler2.Watch.GetGen()) or 0
    end
    local cacheKey = tostring(snapGen) .. ":" .. tostring(watchGen)
    if type(RS._deficitContestedCache) == "table" and RS._deficitContestedSnapGen == cacheKey then
        return RS._deficitContestedCache
    end
    local s = EnsureSettings()
    local out = {}
    if type(s.watches) ~= "table" then
        RS._deficitContestedCache = out
        RS._deficitContestedSnapGen = cacheKey
        return out
    end
    local infos = {}
    local keys = {}
    for watchKey, watch in pairs(s.watches) do
        if type(watch) == "table" and watch.enabled == true then
            local resolved = RS.ResolveWatchPotion(watchKey)
            local potion = resolved and resolved.potion
            local recipe = RS.RecipeSpecForPotion(watchKey)
            if type(potion) == "table" and type(recipe) == "table" then
                local target = tonumber(watch.targetStock) or 0
                local have = RS.PotionHaveCombined(potion)
                local deficit = math.max(0, target - have)
                if deficit > 0 and target > 0 then
                    local craftable = 0
                    local craftsPossible = 0
                    if RS.CountPotionsCraftable then
                        craftable = math.max(0, math.floor((tonumber(RS.CountPotionsCraftable(recipe)) or 0) + 0.5))
                    end
                    if RS.CountCraftsPossible then
                        craftsPossible = math.max(0, math.floor((tonumber(RS.CountCraftsPossible(recipe)) or 0) + 0.5))
                    end
                    keys[#keys + 1] = watchKey
                    infos[#infos + 1] = {
                        potionDeficit = deficit,
                        craftable = craftable,
                        craftsPossible = craftsPossible,
                        craftsNeeded = RS.CraftsNeededForDeficit(deficit, recipe),
                        recipe = recipe,
                    }
                end
            end
        end
    end
    RS.ApplyDeficitCraftableShared(infos)
    for i = 1, #keys do
        out[keys[i]] = infos[i].craftableShared == true
    end
    RS._deficitContestedCache = out
    RS._deficitContestedSnapGen = cacheKey
    return out
end

--- Deficit watch still needs plant/refine: uncovered, or covered but deficit-contested.
function RS.WatchStillNeedsGrow(potion, recipe, target, watchKey)
    target = tonumber(target) or 0
    if target <= 0 or type(potion) ~= "table" then
        return false
    end
    local have = RS.PotionHaveCombined(potion)
    local deficit = math.max(0, target - have)
    if deficit <= 0 then
        return false
    end
    if not RS.WatchCoveredByBagsAndCraftable(potion, recipe, target) then
        return true
    end
    watchKey = tostring(watchKey or "")
    if watchKey == "" then
        return false
    end
    local map = RS.BuildWatchDeficitContestedByKey()
    return map[watchKey] == true
end

--- Growable refinable seed/plant lines from AutoGrow-enabled watches, even when
--- Stock+Craftable already covers Target (seed-buffer maintenance set).
--- Excludes one-way / non-refinable harvest (no plant→seed refine path).
--- Cached per snap/garden/buffer settings (hot path: refine gates / intents).
function RS.CollectAutoGrowSeedLines()
    local cacheKey = AutoGrowSeedLinesCacheKey()
    if RS._autoGrowSeedLinesKey == cacheKey and type(RS._autoGrowSeedLines) == "table" then
        return RS._autoGrowSeedLines
    end
    local lines = {}
    local seen = {}
    local s = EnsureSettings()
    local SM = StockPiler2.SeedMap
    local MS = StockPiler2.MaterialSpec
    if type(s.watches) ~= "table" or type(SM) ~= "table" or not SM.IsGrowableSpec then
        RS._autoGrowSeedLinesKey = cacheKey
        RS._autoGrowSeedLines = lines
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
    RS._autoGrowSeedLinesKey = cacheKey
    RS._autoGrowSeedLines = lines
    return lines
end

--- True when Seed Buffer is on and any growable refinable recipe line for this watch
--- is below the buffer (bag + in-ground + outstanding).
function RS.WatchHasSeedBufferShort(recipe)
    if not (StockPiler2.Watch and StockPiler2.Watch.IsSeedBufferEnabled
        and StockPiler2.Watch.IsSeedBufferEnabled() == true)
    then
        return false
    end
    if type(recipe) ~= "table" then
        return false
    end
    local SM = StockPiler2.SeedMap
    local Refine = StockPiler2.Refine
    if type(SM) ~= "table" or not SM.IsGrowableSpec then
        return false
    end
    local buffer = StockPiler2.Watch.GetSeedBufferMin and StockPiler2.Watch.GetSeedBufferMin() or 5
    if RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end
    local slots = recipe.slots or {}
    local seen = {}
    for i = 1, #slots do
        local slot = slots[i]
        local spec = slot and (slot.spec or (RS.ResolveSlotSpec and RS.ResolveSlotSpec(slot)))
        if type(spec) == "table" and SM.IsGrowableSpec(spec) then
            if SM.IsOneWayHarvestSpec and SM.IsOneWayHarvestSpec(spec) == true then
                -- One-way: ignore for buffer short.
            else
                local productKey = StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.ProductKey
                    and StockPiler2.MaterialSpec.ProductKey(spec) or tostring(i)
                if seen[productKey] ~= true then
                    seen[productKey] = true
                    local seed = SM.ResolveSeedForSpec and SM.ResolveSeedForSpec(spec)
                    local seedUid = 0
                    local plantUid = 0
                    if type(seed) == "table" then
                        seedUid = tonumber(seed.uniqueID) or 0
                        plantUid = tonumber(seed.plantUid) or 0
                    end
                    if plantUid <= 0 and SM.FindPlantUidForSpec then
                        plantUid = tonumber(SM.FindPlantUidForSpec(spec)) or 0
                    end
                    if seedUid <= 0 or plantUid <= 0 then
                        -- Unmapped / non-refinable: ignore for buffer short.
                    else
                        local credit = 0
                        if Refine and Refine.GetSeedBudgetForSpec then
                            local budget = Refine.GetSeedBudgetForSpec(spec, seedUid)
                            credit = tonumber(budget and budget.credit) or 0
                        elseif SM.CountSeedsInBagsForSpec then
                            credit = tonumber(SM.CountSeedsInBagsForSpec(spec)) or 0
                        end
                        if credit < buffer then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

--- Crafts to cover a potion deficit at recipe yield (often 2). Potent crits
--- do not count toward this watch; they are a bonus, not extra material need.
function RS.CraftsNeededForDeficit(deficit, recipe)
    deficit = math.max(0, tonumber(deficit) or 0)
    if deficit <= 0 then
        return 0
    end
    local yield = RS.RecipeOutputYield(recipe)
    if yield < 1 then
        yield = 1
    end
    return math.max(1, math.ceil(deficit / yield))
end

--- Potion count those crafts would yield (crafts × recipe yield).
--- Best case: every output is this potion, not a Potent / other rarity.
--- Yield can be a fractional observed average — round for UI / comparisons.
function RS.CountPotionsCraftable(recipe, opts)
    local crafts = RS.CountCraftsPossible(recipe, opts)
    local bottles = crafts * RS.RecipeOutputYield(recipe)
    return math.floor((tonumber(bottles) or 0) + 0.5)
end

--- Expected bottles of this potion from current materials, using observed
--- outcome success rate. Best-case Craftable* is still crafts × yield;
--- expected = Craftable* × rate. Returns expected, rate, bestCase, crafts.
function RS.ExpectedCraftableBottles(recipe, potionUid)
    potionUid = tonumber(potionUid) or tonumber(recipe and recipe.outputUid) or 0
    local crafts = RS.CountCraftsPossible(recipe)
    local yield = RS.RecipeOutputYield(recipe, potionUid)
    if yield < 1 then
        yield = 1
    end
    local best = crafts * yield
    local rate = nil
    if RS.OutcomeSuccessRate then
        rate = RS.OutcomeSuccessRate(recipe, potionUid)
    end
    if rate == nil then
        return nil, nil, best, crafts
    end
    if rate < 0 then
        rate = 0
    elseif rate > 1 then
        rate = 1
    end
    return best * rate, rate, best, crafts
end

--- Crafts expected to cover a deficit when only `rate` of brews produce this potion.
--- Falls back to best-case CraftsNeededForDeficit when rate is unknown.
function RS.ExpectedCraftsForDeficit(deficit, recipe, potionUid)
    deficit = math.max(0, tonumber(deficit) or 0)
    if deficit <= 0 then
        return 0, nil
    end
    potionUid = tonumber(potionUid) or tonumber(recipe and recipe.outputUid) or 0
    local rate = nil
    if RS.OutcomeSuccessRate then
        rate = RS.OutcomeSuccessRate(recipe, potionUid)
    end
    local yield = RS.RecipeOutputYield(recipe, potionUid)
    if yield < 1 then
        yield = 1
    end
    if rate == nil or rate <= 0 then
        return RS.CraftsNeededForDeficit(deficit, recipe), rate
    end
    if rate > 1 then
        rate = 1
    end
    local perCraft = yield * rate
    if perCraft <= 0 then
        return RS.CraftsNeededForDeficit(deficit, recipe), rate
    end
    return math.max(1, math.ceil(deficit / perCraft)), rate
end

--- Stock count for a watched potion is exact uniqueID only.
--- Potent / regular / other rarities are separate potions; watch each to target it.
function RS.PotionHaveCombined(potion)
    if type(potion) ~= "table" or not StockPiler2.Inventory then
        return 0
    end
    local uid = tonumber(potion.outputUid) or 0
    if uid <= 0 or not StockPiler2.Inventory.CountByUniqueId then
        return 0
    end
    local count = StockPiler2.Inventory.CountByUniqueId(uid)
    return tonumber(count) or 0
end

function RS.EnsureWatch(potionKey)
    local s = EnsureSettings()
    if type(s.watches) ~= "table" then
        s.watches = {}
    end
    if type(s.watches[potionKey]) ~= "table" then
        s.watches[potionKey] = {
            enabled = false,
            autoGrow = true,
            targetStock = 40,
        }
    end
    if s.watches[potionKey].autoGrow == nil then
        s.watches[potionKey].autoGrow = true
    end
    return s.watches[potionKey]
end

--- Wipe this character's watches table (orphans / forgotten-recipe leftovers).
--- Returns how many entries were removed.
function RS.ClearWatchList()
    local s = EnsureSettings()
    local n = 0
    if type(s.watches) == "table" then
        for _ in pairs(s.watches) do
            n = n + 1
        end
    end
    s.watches = {}
    if StockPiler2.PersistActiveCharacterSettings then
        StockPiler2.PersistActiveCharacterSettings(s)
    end
    if StockPiler2.Planner and StockPiler2.Planner.InvalidatePlanCache then
        StockPiler2.Planner.InvalidatePlanCache()
    end
    if StockPiler2.AutoGrow then
        if StockPiler2.AutoGrow.InvalidatePlantQueue then
            StockPiler2.AutoGrow.InvalidatePlantQueue()
        end
        if StockPiler2.AutoGrow.OnDemandChanged then
            StockPiler2.AutoGrow.OnDemandChanged()
        end
    end
    if StockPiler2.LogSettingsAlways then
        StockPiler2.LogSettingsAlways("clearWatchList count=" .. tostring(n))
    elseif StockPiler2.LogOp then
        StockPiler2.LogOp("settings", "clearWatchList count=" .. tostring(n))
    end
    return n
end

-- Per-potion AutoGrow preference only (Watch-tab checkbox). Independent of global.
function RS.WatchWantsAutoGrow(watch)
    return type(watch) == "table" and watch.autoGrow ~= false
end

--- Any brewed recipe with slots can be grown when the player watches it.
--- Volatile outcomes are included; quality "good" is not required.
function RS.RecipeEligibleForGrow(recipe)
    return type(recipe) == "table" and type(recipe.slots) == "table" and #recipe.slots > 0
end

-- Watch is on the grow-demand list (enabled + AutoG). Independent of the global switch
-- so the plot plan can be built before Enable, and reused when the switch flips on.
function RS.WatchContributesGrowDemand(potionKey, watch)
    local s = EnsureSettings()
    if type(watch) ~= "table" then
        watch = type(s.watches) == "table" and s.watches[potionKey] or nil
    end
    return type(watch) == "table"
        and watch.enabled == true
        and RS.WatchWantsAutoGrow(watch)
end

-- AutoGrow watches still below target, with the lowest Craftable count.
-- Plot assignment uses only these recipes so a 0-craftable watch is not
-- starved by another watch's Goldweed (or any other extra plant).
function RS.CollectAutoGrowFocus()
    local s = EnsureSettings()
    local focus = {
        minCraftable = nil,
        watches = {},
    }
    if type(s.watches) ~= "table" or type(s.knownPotions) ~= "table" then
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
                local have = RS.PotionHaveCombined(potion)
                local deficit = math.max(0, target - have)
                if deficit > 0 and target > 0
                    and RS.WatchStillNeedsGrow(potion, recipe, target, watchKey)
                then
                    local craftable = RS.CountPotionsCraftable(recipe)
                    candidates[#candidates + 1] = {
                        potionKey = watchKey,
                        potionBaseKey = resolved.potionKey,
                        recipeSpecKey = resolved.recipeSpecKey,
                        name = potion.name or L"",
                        nameNarrow = potion.nameNarrow or ToNarrow(potion.name),
                        craftable = craftable,
                        recipe = recipe,
                    }
                    if focus.minCraftable == nil or craftable < focus.minCraftable then
                        focus.minCraftable = craftable
                    end
                end
            end
        end
    end
    for i = 1, #candidates do
        if candidates[i].craftable == focus.minCraftable then
            focus.watches[#focus.watches + 1] = candidates[i]
        end
    end
    return focus
end

function RS.FocusSpecKeys(focus)
    local keys = {}
    if type(focus) ~= "table" or type(focus.watches) ~= "table" or not MS or not MS.Key then
        return keys
    end
    for i = 1, #focus.watches do
        local slots = focus.watches[i].recipe and focus.watches[i].recipe.slots
        if type(slots) == "table" then
            for j = 1, #slots do
                local spec = slots[j] and slots[j].spec
                if type(spec) == "table" then
                    keys[MS.Key(spec)] = true
                end
            end
        end
    end
    return keys
end

function RS.FocusWatchNames(focus)
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
function RS.ShouldAutoGrowPotion(potionKey, watch)
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

-- Sum ingredient need across every watched potion that should AutoGrow.
-- Shared specs share one bag count; deficit = total need − have.
function RS.BuildBalancedSpecDemand()
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    local watchGen = 0
    if StockPiler2.Watch and StockPiler2.Watch.GetGen then
        watchGen = tonumber(StockPiler2.Watch.GetGen()) or 0
    end
    local cacheKey = tostring(snapGen) .. ":" .. tostring(watchGen)
    if type(RS._demandCache) == "table" and RS._demandSnapGen == cacheKey then
        return RS._demandCache
    end
    RS._specHaveCache = {}
    local s = EnsureSettings()
    local demand = {}
    if type(s.watches) ~= "table" or type(s.knownPotions) ~= "table" then
        RS._demandCache = demand
        RS._demandSnapGen = cacheKey
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
    local function EnsureConvertDemandRow(spec)
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
                row = EnsureConvertDemandRow(fallback)
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
    RS._demandCache = demand
    RS._demandSnapGen = cacheKey
    return demand
end

local function MainUidFromLegacyRecipes(outputUid)
    outputUid = tonumber(outputUid) or 0
    if outputUid <= 0 then
        return nil
    end
    local s = EnsureSettings()
    if type(s.learnedRecipes) ~= "table" then
        return nil
    end
    for _, recipe in pairs(s.learnedRecipes) do
        if type(recipe) == "table" and tonumber(recipe.outputUid) == outputUid then
            local materials = recipe.materials
            if type(materials) == "table" then
                for i = 1, #materials do
                    local mat = materials[i]
                    if type(mat) == "table" and mat.role == "main" then
                        local uid = tonumber(mat.uniqueID) or 0
                        if uid > 0 then
                            return uid
                        end
                    end
                end
            end
        end
    end
    return nil
end

local EFFECT_KEY_UI_ALIASES = {
    rskill = "bs",
    wil = "wp",
    arm = "armor",
    shabs = "absorb",
    regen = "hot",
}

--- Map MaterialSpec / description aliases onto Potions-tab filter keys.
function RS.NormalizeEffectKeyForUi(effectKey)
    if type(effectKey) ~= "string" or effectKey == "" then
        return nil
    end
    local key = string.lower(effectKey)
    return EFFECT_KEY_UI_ALIASES[key] or key
end

local function EffectKeyFromFxInRecipeKey(recipeKey)
    recipeKey = tostring(recipeKey or "")
    if recipeKey == "" then
        return nil
    end
    local fx = string.match(recipeKey, "fx:(%d+)")
    local effectId = tonumber(fx) or 0
    if effectId <= 0 or not MS or not MS.EffectKeyFromEffectId then
        return nil
    end
    return RS.NormalizeEffectKeyForUi(MS.EffectKeyFromEffectId(effectId))
end

local function EffectKeyFromRecipeMain(recipe)
    if type(recipe) ~= "table" then
        return nil
    end
    RS.HydrateRecipeSlots(recipe)
    local slots = recipe.slots or {}
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" and (slot.role == "main" or (type(slot.spec) == "table" and slot.spec.role == "main")) then
            local spec = RS.ResolveSlotSpec(slot)
            local effectId = type(spec) == "table" and tonumber(spec.effectId) or 0
            if effectId <= 0 then
                local uid = tonumber(slot.uid) or 0
                if uid > 0 and StockPiler2.Items and StockPiler2.Items.Get then
                    local row = StockPiler2.Items.Get(uid)
                    effectId = type(row) == "table" and tonumber(row.effectId) or 0
                end
            end
            if effectId > 0 and MS and MS.EffectKeyFromEffectId then
                return RS.NormalizeEffectKeyForUi(MS.EffectKeyFromEffectId(effectId))
            end
        end
    end
    return nil
end

--- Resolve potion Effect column key: stored → recipe fx: → main effectId → Classify.
--- opts.recipe / opts.recipeKey optional; stamps potion.effectKey when found and potion table given.
function RS.ResolveEffectKeyForPotion(potion, opts)
    opts = type(opts) == "table" and opts or {}
    local key = nil
    if type(potion) == "table" and type(potion.effectKey) == "string" and potion.effectKey ~= "" then
        key = RS.NormalizeEffectKeyForUi(potion.effectKey)
    end
    local recipe = opts.recipe
    local recipeKey = tostring(opts.recipeKey or "")
    if key == nil then
        if recipeKey == "" and type(potion) == "table" then
            recipeKey = tostring(PotionActiveRecipeKey(potion) or "")
            if recipeKey == "" then
                local keys = PotionRecipeKeys(potion)
                if type(keys) == "table" and type(keys[1]) == "string" then
                    recipeKey = keys[1]
                end
            end
        end
        if recipeKey ~= "" then
            key = EffectKeyFromFxInRecipeKey(recipeKey)
        end
        if key == nil and type(potion) == "table" then
            local keys = PotionRecipeKeys(potion)
            if type(keys) == "table" then
                for i = 1, #keys do
                    key = EffectKeyFromFxInRecipeKey(keys[i])
                    if key then
                        break
                    end
                end
            end
        end
    end
    if key == nil then
        if type(recipe) ~= "table" and recipeKey ~= "" then
            local s = EnsureSettings()
            local recipes = RecipesTable(s)
            recipe = recipes[recipeKey]
        end
        if type(recipe) ~= "table" and type(potion) == "table" then
            local pk = potion.potionKey or (potion.outputUid and RS.PotionKeyFromUid(potion.outputUid))
            if pk then
                recipe = RS.RecipeSpecForPotion(pk)
            end
        end
        key = EffectKeyFromRecipeMain(recipe)
    end
    if key == nil and StockPiler2.Classify and StockPiler2.Classify.GetEffectKey then
        local itemData = opts.itemData
        if type(itemData) ~= "table" and type(opts.out) == "table" then
            itemData = opts.out.itemData or opts.out
        end
        -- Live bag / tooltip sample for output potion when opts omitted it.
        if type(itemData) ~= "table" and type(potion) == "table" then
            local uid = tonumber(potion.outputUid) or 0
            if uid > 0 and StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
                local _, sample = StockPiler2.Inventory.CountByUniqueId(uid)
                if type(sample) == "table" then
                    itemData = sample
                end
            end
            if type(itemData) ~= "table"
                and StockPiler2.Inventory
                and StockPiler2.Inventory.ResolvePotionItemData
            then
                local pk = potion.potionKey or RS.PotionKeyFromUid(uid)
                itemData = StockPiler2.Inventory.ResolvePotionItemData(pk, uid, nil)
            end
            if type(itemData) ~= "table" and uid > 0 and type(GetDatabaseItemData) == "function" then
                local ok, data = StockPiler2.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
                if ok and type(data) == "table" then
                    itemData = data
                end
            end
        end
        if type(itemData) == "table" then
            key = RS.NormalizeEffectKeyForUi(StockPiler2.Classify.GetEffectKey(itemData))
        end
    end
    if key and type(potion) == "table" and opts.stamp ~= false then
        potion.effectKey = key
    end
    return key
end

--- Potion effectKey for a recipe (learned output / linked potion row).
function RS.EffectKeyHintForRecipe(recipe, recipeKey)
    recipeKey = tostring(recipeKey or "")
    local s = EnsureSettings()
    local potions = PotionsTable(s)
    if type(potions) == "table" and recipeKey ~= "" then
        for _, potion in pairs(potions) do
            if type(potion) == "table" then
                local match = PotionActiveRecipeKey(potion) == recipeKey
                if not match then
                    local keys = PotionRecipeKeys(potion)
                    if type(keys) == "table" then
                        for i = 1, #keys do
                            if keys[i] == recipeKey then
                                match = true
                                break
                            end
                        end
                    end
                end
                if match then
                    local key = RS.ResolveEffectKeyForPotion(potion, {
                        recipe = recipe,
                        recipeKey = recipeKey,
                    })
                    if key then
                        return key
                    end
                end
            end
        end
    end
    local fromFx = EffectKeyFromFxInRecipeKey(recipeKey)
    if fromFx then
        return fromFx
    end
    local fromMain = EffectKeyFromRecipeMain(recipe)
    if fromMain then
        return fromMain
    end
    local tryUids = {}
    local function pushUid(uid)
        uid = tonumber(uid) or 0
        if uid > 0 then
            tryUids[#tryUids + 1] = uid
        end
    end
    if type(recipe) == "table" then
        pushUid(recipe.activeOutcomeUid)
        pushUid(recipe.outputUid)
        if type(recipe.outcomes) == "table" then
            for uidStr, oc in pairs(recipe.outcomes) do
                if type(oc) == "table" and (oc.quality == "good" or oc.quality == nil) then
                    pushUid(uidStr)
                end
            end
            for uidStr, _ in pairs(recipe.outcomes) do
                pushUid(uidStr)
            end
        end
    end
    for i = 1, #tryUids do
        local potion = potions[RS.PotionKeyFromUid(tryUids[i])]
        if type(potion) == "table" then
            local key = RS.ResolveEffectKeyForPotion(potion, {
                recipe = recipe,
                recipeKey = recipeKey,
            })
            if key then
                return key
            end
        end
        if StockPiler2.Classify and StockPiler2.Classify.GetEffectKey then
            local itemData = nil
            if StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
                local _, sample = StockPiler2.Inventory.CountByUniqueId(tryUids[i])
                if type(sample) == "table" then
                    itemData = sample
                end
            end
            if type(itemData) ~= "table" and StockPiler2.Items and StockPiler2.Items.AsItemData then
                itemData = StockPiler2.Items.AsItemData(tryUids[i])
            end
            if type(itemData) == "table" then
                local classified = StockPiler2.Classify.GetEffectKey(itemData)
                if type(classified) == "string" and classified ~= "" then
                    return RS.NormalizeEffectKeyForUi(classified)
                end
            end
        end
    end
    return nil
end

--- Ensure every recipe outcome uid is listed on that potion's recipeKeys.
function RS.RelinkPotionRecipeKeysFromOutcomes()
    local s = EnsureSettings()
    local recipes = RecipesTable(s)
    local potions = PotionsTable(s)
    if type(recipes) ~= "table" or type(potions) ~= "table" then
        return 0
    end
    local added = 0
    for recipeKey, recipe in pairs(recipes) do
        if type(recipe) == "table" and type(recipe.outcomes) == "table" then
            for uidStr, oc in pairs(recipe.outcomes) do
                local uid = tonumber(uidStr) or 0
                if uid > 0 and type(oc) == "table" then
                    local potionKey = RS.PotionKeyFromUid(uid)
                    local potion = potions[potionKey]
                    if type(potion) ~= "table" then
                        potion = {
                            potionKey = potionKey,
                            outputUid = uid,
                            recipeKeys = {},
                        }
                        potions[potionKey] = potion
                    end
                    local keys = PotionRecipeKeys(potion)
                    if type(keys) ~= "table" then
                        keys = {}
                        potion.recipeKeys = keys
                    end
                    local seen = false
                    for i = 1, #keys do
                        if keys[i] == recipeKey then
                            seen = true
                            break
                        end
                    end
                    if not seen then
                        keys[#keys + 1] = recipeKey
                        added = added + 1
                    end
                end
            end
        end
    end
    if added > 0 then
        for _, potion in pairs(potions) do
            if type(potion) == "table" then
                DedupePotionRecipeKeys(potion, recipes)
            end
        end
        if StockPiler2.Trace then
            StockPiler2.Trace("learn| relinked potion recipeKeys +" .. tostring(added))
        end
    end
    return added
end

--- Stamp incomplete main slots from brew outputs before fingerprinting.
function RS.BackfillIncompleteMainsFromOutputs(slots, outputs)
    if type(slots) ~= "table" or not MS or not MS.RepairMainSpec then
        return 0
    end
    local effectKey = nil
    if type(outputs) == "table" and StockPiler2.Classify and StockPiler2.Classify.GetEffectKey then
        for i = 1, #outputs do
            local out = outputs[i]
            if type(out) == "table" and RS.OutputQuality(out) == "good" then
                effectKey = StockPiler2.Classify.GetEffectKey(out.itemData or out)
                if type(effectKey) == "string" and effectKey ~= "" then
                    break
                end
                effectKey = nil
            end
        end
        if effectKey == nil then
            for i = 1, #outputs do
                local out = outputs[i]
                if type(out) == "table" and RS.OutputQuality(out) ~= "failed" then
                    effectKey = StockPiler2.Classify.GetEffectKey(out.itemData or out)
                    if type(effectKey) == "string" and effectKey ~= "" then
                        break
                    end
                    effectKey = nil
                end
            end
        end
    end
    if type(effectKey) ~= "string" or effectKey == "" then
        return 0
    end
    local fixed = 0
    for i = 1, #slots do
        local slot = slots[i]
        local spec = type(slot) == "table" and slot.spec or nil
        if type(slot) == "table"
            and slot.role == "main"
            and type(spec) == "table"
            and (spec.incomplete == true or not tonumber(spec.effectId) or tonumber(spec.effectId) <= 0)
        then
            if MS.RepairMainSpec(spec, slot.uid, { effectKey = effectKey }) then
                slot.spec = spec
                if slot.uid and StockPiler2.Items and StockPiler2.Items.Upsert then
                    StockPiler2.Items.Upsert(slot.uid, {
                        effectId = spec.effectId,
                        bonuses = spec.bonuses,
                        incomplete = false,
                    })
                end
                fixed = fixed + 1
            end
        end
    end
    return fixed
end

function RS.RepairIncompleteMainSpecs()
    if not MS or not MS.RepairMainSpec or not MS.Key then
        return 0
    end
    local s = EnsureSettings()
    local fixed = 0
    local recipeMigrates = {}
    local recipes = s.recipes or s.learnedRecipeSpecs

    if type(recipes) == "table" then
        for key, recipe in pairs(recipes) do
            if type(recipe) == "table" and type(recipe.slots) == "table" then
                RS.HydrateRecipeSlots(recipe)
                local changed = false
                local mainUid = nil
                for i = 1, #recipe.slots do
                    local slot = recipe.slots[i]
                    if type(slot) == "table" and slot.role == "main" then
                        mainUid = tonumber(slot.uid) or mainUid
                    end
                end
                local effectHint = { effectKey = RS.EffectKeyHintForRecipe(recipe, key) }
                for i = 1, #recipe.slots do
                    local slot = recipe.slots[i]
                    local spec = RS.ResolveSlotSpec(slot)
                    if type(slot) == "table" and slot.role == "main" and type(spec) == "table" then
                        if MS.RepairMainSpec(spec, mainUid or slot.uid, effectHint) then
                            slot.spec = spec
                            if slot.uid and StockPiler2.Items and StockPiler2.Items.Upsert then
                                StockPiler2.Items.Upsert(slot.uid, {
                                    effectId = spec.effectId,
                                    bonuses = spec.bonuses,
                                    incomplete = false,
                                })
                            end
                            changed = true
                            fixed = fixed + 1
                        elseif spec.incomplete == true then
                            local uid = tonumber(slot.uid) or tonumber(mainUid) or 0
                            if uid > 0 and tonumber(spec.boundUid) ~= uid then
                                spec = MS.Copy(spec) or spec
                                spec.boundUid = uid
                                slot.spec = spec
                                changed = true
                            end
                        end
                    end
                end
                if changed then
                    local newKey = RS.SlotsFingerprint(recipe.slots)
                    if newKey ~= "" and newKey ~= key then
                        recipeMigrates[#recipeMigrates + 1] = {
                            oldKey = key,
                            newKey = newKey,
                            recipe = recipe,
                        }
                    end
                else
                    -- Remount keys that lack uid: while main is still incomplete.
                    local newKey = RS.SlotsFingerprint(recipe.slots)
                    if newKey ~= "" and newKey ~= key and string.find(newKey, "uid:", 1, true) then
                        recipeMigrates[#recipeMigrates + 1] = {
                            oldKey = key,
                            newKey = newKey,
                            recipe = recipe,
                        }
                        fixed = fixed + 1
                    end
                end
            end
        end
    end

    -- Orphan Account.items mains (seen in bags / harvest) with no recipe slot yet.
    if StockPiler2.Items and StockPiler2.Items.Get and StockPiler2.Items.Upsert and StockPiler2.Account then
        local items = StockPiler2.Account.items
        if type(items) == "table" then
            for key, row in pairs(items) do
                if type(row) == "table"
                    and row.role == "main"
                    and row.incomplete == true
                then
                    local uid = tonumber(row.uniqueID) or tonumber(key) or 0
                    local spec = StockPiler2.Items.ToSpec(uid)
                    local effectKey = nil
                    if type(recipes) == "table" then
                        for recipeKey, recipe in pairs(recipes) do
                            if type(recipe) == "table" and type(recipe.slots) == "table" then
                                for i = 1, #recipe.slots do
                                    local slot = recipe.slots[i]
                                    if type(slot) == "table"
                                        and slot.role == "main"
                                        and tonumber(slot.uid) == uid
                                    then
                                        effectKey = RS.EffectKeyHintForRecipe(recipe, recipeKey)
                                        break
                                    end
                                end
                                if effectKey then
                                    break
                                end
                            end
                        end
                    end
                    if type(spec) == "table"
                        and MS.RepairMainSpec(spec, uid, { effectKey = effectKey })
                    then
                        StockPiler2.Items.Upsert(uid, {
                            effectId = spec.effectId,
                            bonuses = spec.bonuses,
                            incomplete = false,
                        })
                        fixed = fixed + 1
                    end
                end
            end
        end
    end

    for i = 1, #recipeMigrates do
        local migrate = recipeMigrates[i]
        RemapRecipeSpecKey(s, migrate.oldKey, migrate.newKey, migrate.recipe)
    end

    RS.RelinkPotionRecipeKeysFromOutcomes()
    RS.SlimAllRecipesForStorage()

    if fixed > 0 and StockPiler2.Inventory and StockPiler2.Inventory.InvalidateRecipeCaches then
        StockPiler2.Inventory.InvalidateRecipeCaches()
    end
    return fixed
end
