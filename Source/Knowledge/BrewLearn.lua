----------------------------------------------------------------
-- StockPiler2 Knowledge/BrewLearn — apothecary brew learning
----------------------------------------------------------------

StockPiler2.BrewLearn = StockPiler2.BrewLearn or {}
local BL = StockPiler2.BrewLearn

local function ToNarrow(value)
    return StockPiler2.ToNarrow(value)
end

local function StackSize(item)
    local n = tonumber(item.stackCount) or tonumber(item.Count) or 0
    if n < 1 then
        return 1
    end
    return n
end

local function CopyItemData(item)
    if type(item) ~= "table" then
        return nil
    end
    local function copyVal(v, depth)
        if type(v) ~= "table" then
            return v
        end
        if depth >= 4 then
            return nil
        end
        local out = {}
        for k, val in pairs(v) do
            local cv = copyVal(val, depth + 1)
            if cv ~= nil or type(val) ~= "table" then
                out[k] = cv
            end
        end
        return out
    end
    return copyVal(item, 0)
end

local function IsPotionType(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if GameData and GameData.ItemTypes and GameData.ItemTypes.POTION then
        return itemData.type == GameData.ItemTypes.POTION
    end
    return tonumber(itemData.type) == 31
end

local function EachItem(fn)
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(fn)
        return
    end
    local BA = StockPiler2.BagAdapter
    if not BA then
        return
    end
    local bags = BA.FetchLight()
    for i = 1, #bags do
        BA.IterateSlots(bags[i], function(_, _, item)
            fn(item)
        end)
    end
end

local function SnapshotItems()
    -- Prefer the L0 inventory snapshot. Do not force Flatten on every craft
    -- learn snapshot (that caused Flatten x3 + plan/UI cascades per brew).
    local Inv = StockPiler2.Inventory
    if Inv and Inv._ready == true then
        return
    end
    if Inv and Inv.Flush then
        Inv.Flush({})
    elseif GameData and GameData.Player then
        GameData.Player.itemsDirty = true
        GameData.Player.craftingItemsDirty = true
    end
end

local CRAFTING_FAMILY_REF = 5
local CRAFTING_TYPE_REF = 8

local function CraftingBonusRefs()
    local family = CRAFTING_FAMILY_REF
    local typ = CRAFTING_TYPE_REF
    if GameData and GameData.CraftingBonusRef then
        family = GameData.CraftingBonusRef.CRAFTING_FAMILY or family
        typ = GameData.CraftingBonusRef.TYPE or typ
    end
    return family, typ
end

local function GetCraftingFamiliesAndResource(itemData)
    local families = {}
    local resourceType = 0
    if type(itemData) ~= "table" or type(itemData.craftingBonus) ~= "table" then
        return families, resourceType
    end
    local familyRef, typeRef = CraftingBonusRefs()
    for _, bonus in ipairs(itemData.craftingBonus) do
        if type(bonus) == "table" then
            local ref = tonumber(bonus.bonusReference) or 0
            local val = tonumber(bonus.bonusValue) or 0
            if ref == familyRef and val > 0 then
                families[#families + 1] = val
            elseif ref == typeRef and val > 0 then
                resourceType = val
            end
        end
    end
    return families, resourceType
end

local function ClassifyMat(itemData)
    local skillReq = tonumber(itemData.craftingSkillRequirement) or 0
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType ~= 0 then
        local cult = (GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION) or 3
        return cult, cultType, skillReq, "cultivation"
    end
    local apo = (GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY) or 4
    local families, resourceType = GetCraftingFamiliesAndResource(itemData)
    for i = 1, #families do
        if families[i] == apo then
            return apo, resourceType, skillReq, "apothecary"
        end
    end
    return 0, 0, skillReq, nil
end

function StockPiler2.BrewLearn.PrimaryRecipeOutput(outputs)
    if type(outputs) ~= "table" then
        return nil
    end
    local best = nil
    local bestCrafts = 0
    for i = 1, #outputs do
        local out = outputs[i]
        if type(out) == "table" then
            local crafts = tonumber(out.crafts) or 0
            if best == nil or crafts > bestCrafts then
                best = out
                bestCrafts = crafts
            end
        end
    end
    if best == nil then
        for _, out in pairs(outputs) do
            if type(out) == "table" then
                local crafts = tonumber(out.crafts) or 0
                if best == nil or crafts > bestCrafts then
                    best = out
                    bestCrafts = crafts
                end
            end
        end
    end
    return best
end

function StockPiler2.BrewLearn.LearnFromItemData(itemData, source)
    if StockPiler2.Items and StockPiler2.Items.UpsertFromItemData then
        StockPiler2.Items.UpsertFromItemData(itemData, source)
        return true
    end
    return false
end

----------------------------------------------------------------
-- Apothecary craft learning (materials -> potion outputs)
----------------------------------------------------------------

StockPiler2.BrewLearn._pendingCraft = nil

-- craftingBonus.bonusReference values (matches CraftValueTip / game data).
BL.CraftBonus = {
    STABILITY = 1,
    POWER = 2,
    DURATION = 3,
    MULTIPLIER = 4,
    CRAFTING_FAMILY = 5,
    EFFECT = 6,
    SLOTS = 7,
    TYPE = 8,
    CRAFTING_LEVEL = 9,
    GROW_TIME = 10,
    YIELD = 11,
    CRITICAL_CHANCE = 12,
    FAIL_CHANCE = 13,
    SPECIAL_CHANCE = 14,
    DESTROY_ON_FAIL = 15,
}

local function SignedCraftBonusValue(val)
    val = tonumber(val) or 0
    if val > 32767 then
        return val - 65536
    end
    return val
end

function StockPiler2.BrewLearn.GetItemCraftBonuses(itemData)
    local result = {}
    if type(itemData) ~= "table" or type(itemData.craftingBonus) ~= "table" then
        return result
    end
    for _, bonus in ipairs(itemData.craftingBonus) do
        if type(bonus) == "table" then
            local ref = tonumber(bonus.bonusReference) or 0
            if ref > 0 then
                if result[ref] == nil then
                    result[ref] = {}
                end
                result[ref][#result[ref] + 1] = SignedCraftBonusValue(bonus.bonusValue)
            end
        end
    end
    return result
end

function StockPiler2.BrewLearn.GetItemStability(itemData)
    local bonuses = BL.GetItemCraftBonuses(itemData)
    local values = bonuses[BL.CraftBonus.STABILITY]
    if type(values) == "table" and values[1] ~= nil then
        return tonumber(values[1]) or 0
    end
    return 0
end

function StockPiler2.BrewLearn.GetMaterialStability(mat)
    if type(mat) ~= "table" then
        return 0
    end
    if mat.stability ~= nil then
        return tonumber(mat.stability) or 0
    end
    if type(mat.itemData) == "table" then
        return BL.GetItemStability(mat.itemData)
    end
    local uid = tonumber(mat.uniqueID) or 0
    if uid > 0 and type(BL._learnedMatData) == "table" then
        local cached = BL._learnedMatData["uid:" .. tostring(uid)]
        if type(cached) == "table" then
            return BL.GetItemStability(cached)
        end
    end
    return 0
end

function StockPiler2.BrewLearn.IsOptionalModifierMat(mat)
    if type(mat) ~= "table" then
        return false
    end
    local role = mat.role or ""
    if role == "extender" or role == "multiplier" or role == "stimulant" then
        return true
    end
    local resourceType = tonumber(mat.resourceType) or 0
    if GameData and GameData.CraftingItemType then
        local cit = GameData.CraftingItemType
        if resourceType == cit.EXTENDER
            or resourceType == cit.MULTIPLIER
            or resourceType == cit.STIMULANT
        then
            return true
        end
    end
    return false
end

function StockPiler2.BrewLearn.RecipeStabilityTotal(materials)
    local total = 0
    if type(materials) ~= "table" then
        return total
    end
    for i = 1, #materials do
        local mat = materials[i]
        if not BL.IsOptionalModifierMat(mat) then
            local perCraft = tonumber(mat.perCraft) or 1
            if perCraft < 1 then
                perCraft = 1
            end
            total = total + (BL.GetMaterialStability(mat) * perCraft)
        end
    end
    return total
end

function StockPiler2.BrewLearn.RecipeIsStable(materials)
    return BL.RecipeStabilityTotal(materials) >= 0
end

local GROW_BREW_ROLE_ORDER = {
    container = 1,
    main = 2,
    stabilizer = 3,
    goldweed = 3,
    extender = 4,
    multiplier = 5,
    stimulant = 5,
    ingredient = 6,
}

--- Stabilizer slots required for a stable brew (may exceed learned perCraft when recipe was captured incomplete).
function StockPiler2.BrewLearn.EffectiveMaterialPerCraft(mat, materials)
    local perCraft = tonumber(mat.perCraft) or 1
    if perCraft < 1 then
        perCraft = 1
    end
    if type(mat) ~= "table" or type(materials) ~= "table" then
        return perCraft
    end
    local role = mat.role or ""
    if role ~= "stabilizer" and role ~= "goldweed" then
        return perCraft
    end
    local total = BL.RecipeStabilityTotal(materials)
    if total >= 0 then
        return perCraft
    end
    local stab = BL.GetMaterialStability(mat) or 0
    if stab <= 0 then
        return perCraft
    end
    return perCraft + math.ceil(-total / stab)
end

--- One growable seed/spore per apothecary slot for a single brew (matches Load slot order, skips flask).
function StockPiler2.BrewLearn.BuildGrowableBrewSlots(recipe)
    local slots = {}
    if type(recipe) ~= "table" or type(recipe.materials) ~= "table" then
        return slots
    end
    local materials = recipe.materials
    local sorted = {}
    for i = 1, #materials do
        sorted[i] = materials[i]
    end
    table.sort(sorted, function(a, b)
        local ra = GROW_BREW_ROLE_ORDER[a.role] or 99
        local rb = GROW_BREW_ROLE_ORDER[b.role] or 99
        if ra == rb then
            return (tonumber(a.uniqueID) or 0) < (tonumber(b.uniqueID) or 0)
        end
        return ra < rb
    end)
    for i = 1, #sorted do
        local mat = sorted[i]
        if mat.role ~= "container" then
            local growable = StockPiler2.SeedMap
                and StockPiler2.SeedMap.IsGrowableMaterial
                and StockPiler2.SeedMap.IsGrowableMaterial(mat) == true
            if growable then
                local perCraft = BL.EffectiveMaterialPerCraft(mat, materials)
                for _ = 1, perCraft do
                    slots[#slots + 1] = mat
                end
            end
        end
    end
    return slots
end

local ROLE_ORDER = {
    main = 1,
    stabilizer = 2,
    goldweed = 2,
    extender = 3,
    multiplier = 4,
    container = 5,
    ingredient = 6,
}

local function MatResourceRole(resourceType, slotNum)
    resourceType = tonumber(resourceType) or 0
    if GameData and GameData.CraftingItemType then
        local cit = GameData.CraftingItemType
        if resourceType == cit.CONTAINER or resourceType == cit.CONTAINER_DYE then
            return "container"
        end
        if resourceType == cit.MAIN_INGREDIENT or resourceType == cit.PIGMENT then
            return "main"
        end
        if resourceType == cit.STABILIZER or resourceType == cit.GOLDWEED then
            return "stabilizer"
        end
        if resourceType == cit.EXTENDER then
            return "extender"
        end
        if resourceType == cit.MULTIPLIER then
            return "multiplier"
        end
        if resourceType == cit.STIMULANT then
            return "stimulant"
        end
    end
    if slotNum == 0 then
        return "container"
    end
    if slotNum == 1 then
        return "main"
    end
    return "ingredient"
end

function StockPiler2.BrewLearn.CaptureApothecaryMaterials()
    if type(ApothecaryWindow) ~= "table" or type(ApothecaryWindow.craftingData) ~= "table" then
        return nil
    end
    local slots = {}
    for slotNum = 0, 4 do
        local cd = ApothecaryWindow.craftingData[slotNum]
        if type(cd) == "table" and tonumber(cd.objectId) and tonumber(cd.objectId) > 0 then
            local itemData = nil
            if type(EA_Window_Backpack) == "table"
                and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
                and cd.sourceBackpack
                and cd.sourceSlot
            then
                local bag = EA_Window_Backpack.GetItemsFromBackpack(cd.sourceBackpack)
                if type(bag) == "table" then
                    itemData = bag[cd.sourceSlot]
                end
            end
            local resourceType = 0
            local skillReq = 0
            local matKind = nil
            if type(itemData) == "table" then
                if CraftingSystem and type(CraftingSystem.GetCraftingData) == "function" then
                    local ok, _, rt = StockPiler2.TryCallQuiet("CraftingSystem.GetCraftingData", CraftingSystem.GetCraftingData, itemData)
                    if ok then
                        resourceType = tonumber(rt) or 0
                    end
                end
                local _, _, req, kind = ClassifyMat(itemData)
                skillReq = tonumber(req) or 0
                matKind = kind
            end
            local role = MatResourceRole(resourceType, slotNum)
            local uid = tonumber(cd.objectId) or 0
            local stability = 0
            if type(itemData) == "table" then
                stability = BL.GetItemStability(itemData)
            end
            slots[#slots + 1] = {
                slot = slotNum,
                uniqueID = uid,
                role = role,
                resourceType = resourceType,
                matKind = matKind,
                craftingSkillRequirement = skillReq,
                stability = stability,
                name = (type(itemData) == "table" and itemData.name) or nil,
                nameNarrow = (type(itemData) == "table" and ToNarrow(itemData.name)) or "",
                iconNum = tonumber(cd.iconId) or (type(itemData) == "table" and tonumber(itemData.iconNum)) or 0,
                itemData = CopyItemData(itemData),
            }
            if itemData and BL.LearnFromItemData then
                BL.LearnFromItemData(itemData, "craft-slot")
            end
        end
    end
    if #slots == 0 then
        return nil
    end
    return slots
end

function StockPiler2.BrewLearn.SnapshotPotionCounts()
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("BrewLearn.SnapshotPotionCounts")
    end
    BL._snapshotDone = false
    SnapshotItems()
    local counts = {}
    EachItem(function(item)
        if IsPotionType(item) then
            local uid = tonumber(item.uniqueID) or 0
            if uid > 0 then
                counts[uid] = (counts[uid] or 0) + StackSize(item)
            end
        end
    end)
    if Perf and Perf.End then
        Perf.End("BrewLearn.SnapshotPotionCounts")
    end
    return counts
end

local function AggregateMaterials(slots)
    local byUid = {}
    for i = 1, #slots do
        local m = slots[i]
        local uid = tonumber(m.uniqueID) or 0
        if uid > 0 then
            local key = tostring(uid) .. ":" .. tostring(m.role or "ingredient")
            local row = byUid[key]
            if row == nil then
                row = {
                    uniqueID = uid,
                    role = m.role or "ingredient",
                    resourceType = tonumber(m.resourceType) or 0,
                    matKind = m.matKind,
                    craftingSkillRequirement = tonumber(m.craftingSkillRequirement) or 0,
                    stability = tonumber(m.stability) or 0,
                    name = m.name,
                    nameNarrow = m.nameNarrow or "",
                    iconNum = tonumber(m.iconNum) or 0,
                    perCraft = 0,
                    itemData = m.itemData,
                }
                byUid[key] = row
            end
            row.perCraft = row.perCraft + 1
            if (row.stability or 0) == 0 and (tonumber(m.stability) or 0) ~= 0 then
                row.stability = tonumber(m.stability)
            end
            if (row.iconNum or 0) <= 0 and (tonumber(m.iconNum) or 0) > 0 then
                row.iconNum = tonumber(m.iconNum)
            end
            if row.name == nil and m.name ~= nil then
                row.name = m.name
                row.nameNarrow = m.nameNarrow or ToNarrow(m.name)
            end
            if row.itemData == nil and m.itemData ~= nil then
                row.itemData = m.itemData
            end
            if row.matKind == nil and m.matKind ~= nil then
                row.matKind = m.matKind
            end
            if (row.craftingSkillRequirement or 0) <= 0 and (tonumber(m.craftingSkillRequirement) or 0) > 0 then
                row.craftingSkillRequirement = tonumber(m.craftingSkillRequirement)
            end
        end
    end
    local list = {}
    for _, row in pairs(byUid) do
        list[#list + 1] = row
    end
    table.sort(list, function(a, b)
        local ra = ROLE_ORDER[a.role] or 99
        local rb = ROLE_ORDER[b.role] or 99
        if ra == rb then
            return (a.uniqueID or 0) < (b.uniqueID or 0)
        end
        return ra < rb
    end)
    return list
end

function StockPiler2.BrewLearn.BuildRecipeKey(materials, outputUid)
    local mainUid = 0
    local containerUid = 0
    local extras = {}
    for i = 1, #materials do
        local m = materials[i]
        local uid = tonumber(m.uniqueID) or 0
        if uid > 0 then
            if m.role == "main" then
                mainUid = uid
            elseif m.role == "container" then
                containerUid = uid
            else
                extras[uid] = (extras[uid] or 0) + (tonumber(m.perCraft) or 1)
            end
        end
    end
    local parts = {}
    for uid, cnt in pairs(extras) do
        parts[#parts + 1] = tostring(uid) .. "x" .. tostring(cnt)
    end
    table.sort(parts)
    local key = "m:" .. tostring(mainUid) .. "|c:" .. tostring(containerUid) .. "|i:" .. table.concat(parts, ",")
    outputUid = tonumber(outputUid) or 0
    if outputUid > 0 then
        key = key .. "|o:" .. tostring(outputUid)
    end
    return key
end

function StockPiler2.BrewLearn.BeginPendingCraft()
    if StockPiler2.EnsureApothecaryHook then
        StockPiler2.EnsureApothecaryHook()
    end
    local slots = BL.CaptureApothecaryMaterials()
    if slots == nil then
        StockPiler2.BrewLearn._pendingCraft = nil
        return
    end
    local materials = AggregateMaterials(slots)
    local mainCount = 0
    for i = 1, #materials do
        if materials[i].role == "main" then
            mainCount = mainCount + 1
        end
    end
    if mainCount == 0 then
        StockPiler2.BrewLearn._pendingCraft = nil
        return
    end
    local mainUid = 0
    for i = 1, #materials do
        if materials[i].role == "main" then
            mainUid = tonumber(materials[i].uniqueID) or 0
            break
        end
    end
    StockPiler2.BrewLearn._pendingCraft = {
        materials = materials,
        mainUid = mainUid,
        recipeKey = BL.BuildRecipeKey(materials),
        potionCountsBefore = BL.SnapshotPotionCounts(),
    }
    if StockPiler2.Trace then
        local parts = {}
        for i = 1, #materials do
            local m = materials[i]
            parts[#parts + 1] = tostring(m.role or "?") .. ":" .. tostring(m.uniqueID or 0)
                .. "x" .. tostring(m.perCraft or 1)
        end
        StockPiler2.Trace("Brew pending key=" .. tostring(StockPiler2.BrewLearn._pendingCraft.recipeKey)
            .. " mats=" .. table.concat(parts, ", "))
    end
end

local function TableCount(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do
            n = n + 1
        end
    end
    return n
end

local function SlimMaterial(mat)
    if type(mat) ~= "table" then
        return mat
    end
    return {
        uniqueID = tonumber(mat.uniqueID) or 0,
        role = mat.role or "ingredient",
        resourceType = tonumber(mat.resourceType) or 0,
        matKind = mat.matKind,
        craftingSkillRequirement = tonumber(mat.craftingSkillRequirement) or 0,
        name = mat.name,
        nameNarrow = mat.nameNarrow or "",
        iconNum = tonumber(mat.iconNum) or 0,
        perCraft = tonumber(mat.perCraft) or 1,
        stability = tonumber(mat.stability) or 0,
        isRefinable = mat.isRefinable == true
            or (type(mat.itemData) == "table" and mat.itemData.isRefinable == true),
    }
end

local function SlimMaterialList(materials)
    local list = {}
    if type(materials) ~= "table" then
        return list
    end
    for i = 1, #materials do
        list[i] = SlimMaterial(materials[i])
    end
    return list
end

local function SlimOutput(out, craftsTotal)
    if type(out) ~= "table" then
        return out
    end
    local slim = {
        uniqueID = tonumber(out.uniqueID) or 0,
        name = out.name,
        nameNarrow = out.nameNarrow or "",
        iconNum = tonumber(out.iconNum) or 0,
        crafts = tonumber(craftsTotal) or tonumber(out.crafts) or 1,
    }
    local lastDelta = tonumber(out.lastDelta)
    if lastDelta and lastDelta > 0 then
        slim.lastDelta = lastDelta
    end
    return slim
end

local function SlimRecipe(recipe)
    if type(recipe) ~= "table" then
        return recipe
    end
    local crafts = tonumber(recipe.crafts) or 1
    local slimMats = SlimMaterialList(recipe.materials)
    local outUid = tonumber(recipe.outputUid) or 0
    local outputs = {}
    if type(recipe.outputs) == "table" and #recipe.outputs > 0 then
        local out = recipe.outputs[1]
        outUid = tonumber(out.uniqueID) or outUid
        outputs[1] = SlimOutput(out, crafts)
    elseif outUid > 0 then
        outputs[1] = {
            uniqueID = outUid,
            crafts = crafts,
        }
    end
    return {
        recipeKey = recipe.recipeKey,
        source = recipe.source or "craft",
        crafts = crafts,
        materials = slimMats,
        outputUid = outUid,
        outputs = outputs,
        recipeYield = tonumber(recipe.recipeYield) or nil,
    }
end

local function MigrateLearnedRecipesSplitByOutput(s)
    local migrated = {}
    for key, recipe in pairs(s.learnedRecipes) do
        if type(recipe) ~= "table" then
            migrated[key] = recipe
        elseif string.find(key, "|o:", 1, true) then
            migrated[key] = recipe
        else
            local outputs = type(recipe.outputs) == "table" and recipe.outputs or {}
            if #outputs == 0 then
                migrated[key] = recipe
            else
                for i = 1, #outputs do
                    local out = outputs[i]
                    local uid = tonumber(out.uniqueID) or 0
                    if uid > 0 then
                        local newKey = BL.BuildRecipeKey(recipe.materials, uid)
                        local entry = migrated[newKey]
                        if type(entry) ~= "table" then
                            entry = {
                                recipeKey = newKey,
                                source = recipe.source or "craft",
                                crafts = 0,
                                materials = recipe.materials,
                                outputUid = uid,
                                outputs = {},
                            }
                        end
                        local delta = tonumber(out.lastDelta) or tonumber(out.crafts) or 1
                        entry.crafts = (tonumber(entry.crafts) or 0) + delta
                        entry.recipeYield = delta
                        entry.outputs = { out }
                        migrated[newKey] = entry
                    end
                end
            end
        end
    end
    s.learnedRecipes = migrated
end

local function MigrateLearnedRecipes(s)
    if type(s) ~= "table" or type(s.learnedRecipes) ~= "table" then
        return
    end
    local version = tonumber(s.recipeKeyVersion) or 1

    if version < 2 then
        MigrateLearnedRecipesSplitByOutput(s)
        version = 2
    end

    if version < 3 then
        local slimmed = {}
        for key, recipe in pairs(s.learnedRecipes) do
            if type(recipe) == "table" then
                local slim = SlimRecipe(recipe)
                slim.recipeKey = slim.recipeKey or key
                slimmed[slim.recipeKey or key] = slim
            else
                slimmed[key] = recipe
            end
        end
        s.learnedRecipes = slimmed
        version = 3
    end

    if version < 4 then
        for key, recipe in pairs(s.learnedRecipes) do
            if type(recipe) == "table" and (tonumber(recipe.recipeYield) or 0) <= 0 then
                local out = BL.PrimaryRecipeOutput(recipe.outputs)
                local delta = out and tonumber(out.lastDelta) or 0
                if delta > 0 then
                    recipe.recipeYield = delta
                end
            end
        end
        version = 4
    end

    if version < 5 then
        for _, recipe in pairs(s.learnedRecipes) do
            if type(recipe) == "table" and type(recipe.materials) == "table" then
                for i = 1, #recipe.materials do
                    local mat = recipe.materials[i]
                    if type(mat) == "table" and mat.stability == nil then
                        mat.stability = BL.GetMaterialStability(mat)
                    end
                end
            end
        end
        version = 5
    end

    s.recipeKeyVersion = version
end

function StockPiler2.BrewLearn.RecipeYield(recipe)
    if type(recipe) ~= "table" then
        return 2
    end
    if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.RecipeOutputYield then
        return StockPiler2.RecipeSpec.RecipeOutputYield(recipe)
    end
    local yield = tonumber(recipe.recipeYield)
    if yield and yield > 0 then
        return yield
    end
    local out = BL.PrimaryRecipeOutput(recipe.outputs)
    if out then
        yield = tonumber(out.lastDelta)
        if yield and yield > 0 then
            return yield
        end
    end
    if type(recipe.catalogEntry) == "table" then
        yield = tonumber(recipe.catalogEntry.recipeYield)
        if yield and yield > 0 then
            return yield
        end
    end
    return 2
end

function StockPiler2.BrewLearn.StoreLearnedRecipe(_materials, _outputs)
    -- v8: UID recipe store is retired; specs are written by StoreLearnedRecipeSpec.
    return false
end

local function CauldronStillHasMain(mainUid)
    mainUid = tonumber(mainUid) or 0
    if mainUid <= 0 then
        return nil
    end
    local slots = BL.CaptureApothecaryMaterials()
    if type(slots) ~= "table" then
        return nil
    end
    for i = 1, #slots do
        local slot = slots[i]
        if type(slot) == "table" and slot.role == "main"
            and (tonumber(slot.uniqueID) or 0) == mainUid then
            return true
        end
    end
    return false
end

function StockPiler2.BrewLearn.CompletePendingCraftLearn(opts)
    if type(opts) ~= "table" then
        opts = {}
    end
    local pending = StockPiler2.BrewLearn._pendingCraft
    if type(pending) ~= "table" then
        return false
    end
    local after = BL.SnapshotPotionCounts()
    local before = pending.potionCountsBefore or {}
    local outputs = {}
    for uid, count in pairs(after) do
        local prev = tonumber(before[uid]) or 0
        if count > prev then
            local delta = count - prev
            local sample = nil
            if StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
                _, sample = StockPiler2.Inventory.CountByUniqueId(uid)
            end
            if sample and BL.LearnFromItemData then
                BL.LearnFromItemData(sample, "craft-output")
            end
            outputs[#outputs + 1] = {
                uniqueID = uid,
                name = sample and sample.name or towstring(tostring(uid)),
                nameNarrow = sample and ToNarrow(sample.name) or tostring(uid),
                iconNum = sample and tonumber(sample.iconNum) or 0,
                crafts = 1,
                lastDelta = delta,
                itemData = sample and CopyItemData(sample) or nil,
            }
        end
    end
    -- SUCCESS with no bag delta yet: keep pending for the inventory fallback.
    -- FAIL / critical failure (window closed, items destroyed) with no
    -- potion is recorded now. A volatile that already landed in bags is
    -- learned even when the engine reports FAIL.
    local chatCues = nil
    if StockPiler2.CraftChat and StockPiler2.CraftChat.PeekCues then
        chatCues = StockPiler2.CraftChat.PeekCues()
    end
    if type(pending.chatCriticalFailure) == "boolean" and pending.chatCriticalFailure then
        opts.failed = opts.failed == true or (#outputs == 0)
    elseif type(chatCues) == "table" and chatCues.criticalFailure == true and #outputs == 0 then
        opts.failed = true
    end
    if #outputs == 0 and opts.failed ~= true then
        if StockPiler2.Trace then
            StockPiler2.Trace("Brew complete: no new potion outputs yet")
        end
        return false
    end
    local mainStillThere = CauldronStillHasMain(pending.mainUid)
    local mainConsumed = mainStillThere ~= true
    -- Brew chat "Critical Success" pairs with Potent output (name/uid), not main-kept.
    -- Main kept is only from cauldron still holding the main after brew.
    StockPiler2.BrewLearn._pendingCraft = nil
    if StockPiler2.CraftChat and StockPiler2.CraftChat.TakeCues then
        StockPiler2.CraftChat.TakeCues()
    end
    local stored = false
    if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.StoreLearnedRecipeSpec then
        stored = StockPiler2.RecipeSpec.StoreLearnedRecipeSpec(pending.materials, outputs, {
            failed = #outputs == 0,
            mainConsumed = mainConsumed,
        }) == true
    end
    if StockPiler2.Trace then
        local chatCrit = pending.chatCriticalSuccess == true
            or (type(chatCues) == "table" and chatCues.criticalSuccess == true)
        if #outputs == 0 then
            StockPiler2.Trace("Brew recorded as failure (no potion produced)"
                .. " mainConsumed=" .. tostring(mainConsumed)
                .. " chatCritFail=" .. tostring(pending.chatCriticalFailure == true))
        else
            for i = 1, #outputs do
                local out = outputs[i]
                StockPiler2.Trace("Brew learned uid=" .. tostring(out.uniqueID)
                    .. " delta=" .. tostring(out.lastDelta or out.crafts or 1)
                    .. " mainConsumed=" .. tostring(mainConsumed)
                    .. " chatCritOk=" .. tostring(chatCrit)
                    .. " spec=" .. tostring(stored == true))
            end
        end
    end
    if opts.failed ~= true and #outputs > 0
        and StockPiler2.Brew and StockPiler2.Brew.RefreshSessionAfterBrew
    then
        StockPiler2.Brew.RefreshSessionAfterBrew()
    end
    return stored
end

--- Fallback when PLAYER_CRAFTING_UPDATED does not reach addons (instant brew + bag update).
function StockPiler2.BrewLearn.MaybeCompletePendingCraftFromInventory()
    local pending = StockPiler2.BrewLearn._pendingCraft
    if type(pending) ~= "table" then
        return false
    end
    BL._snapshotDone = false
    local after = BL.SnapshotPotionCounts()
    local before = pending.potionCountsBefore or {}
    for uid, count in pairs(after) do
        if count > (tonumber(before[uid]) or 0) then
            return BL.CompletePendingCraftLearn() == true
        end
    end
    return false
end

function StockPiler2.BrewLearn.OnCraftingUpdated()
    if StockPiler2.EnsureApothecaryHook then
        StockPiler2.EnsureApothecaryHook()
    end
    if not GameData or not GameData.CraftingStatus or not GameData.CraftingStates then
        return false
    end
    local apo = (GameData.TradeSkills and GameData.TradeSkills.APOTHECARY) or 4
    local skill = tonumber(GameData.CraftingStatus.SkillType) or -1
    local state = tonumber(GameData.CraftingStatus.State) or -1
    if skill ~= apo then
        return false
    end
    local SUCCESS = GameData.CraftingStates.SUCCESS
    local SUCCESS_REPEAT = GameData.CraftingStates.SUCCESS_REPEAT
    local FAIL = GameData.CraftingStates.FAIL
    local PERFORMING = GameData.CraftingStates.PERFORMING
    if state == PERFORMING then
        BL.BeginPendingCraft()
        return false
    end
    if state == FAIL then
        local err = tonumber(GameData.CraftingStatus.ErrorCode) or 0
        local backpackFull = GameData.CraftingError and GameData.CraftingError.BACKPACK_FULL
        if backpackFull and err == backpackFull then
            return false
        end
        return BL.CompletePendingCraftLearn({ failed = true }) == true
    end
    if state == SUCCESS or state == SUCCESS_REPEAT then
        return BL.CompletePendingCraftLearn() == true
    end
    return false
end