----------------------------------------------------------------
-- StockPiler2 Knowledge/Items — account item rows (learned mats/potions)
----------------------------------------------------------------

StockPiler2.Items = StockPiler2.Items or {}

local function ItemsTable()
    if StockPiler2.Knowledge and StockPiler2.Knowledge.GetTable then
        return StockPiler2.Knowledge.GetTable("items")
    end
    return {}
end

local function TableEntryCount(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do
            n = n + 1
        end
    end
    return n
end

local function ItemDataHasCraftBonuses(itemData)
    return type(itemData) == "table"
        and type(itemData.craftingBonus) == "table"
        and next(itemData.craftingBonus) ~= nil
end

local function ExistingCraftProfileIsRicher(row, fields)
    if type(row) ~= "table" or type(fields) ~= "table" then
        return false
    end
    local existN = TableEntryCount(row.bonuses)
    local newN = TableEntryCount(fields.bonuses)
    local existTs = tonumber(row.tradeSkill) or 0
    local newTs = tonumber(fields.tradeSkill) or 0
    local existRole = tostring(row.role or "")
    local newRole = tostring(fields.role or "")
    local existCraftRole = existRole ~= "" and existRole ~= "ingredient"
    local newCraftRole = newRole ~= "" and newRole ~= "ingredient"
    if existN > newN then
        return true
    end
    if existTs > 0 and newTs == 0 then
        return true
    end
    if existCraftRole and not newCraftRole and existN >= newN then
        return true
    end
    if row.incomplete ~= true and fields.incomplete == true and existN >= newN then
        return true
    end
    if row.incomplete == true and fields.incomplete ~= true then
        return false
    end
    return false
end

local CRAFT_PROFILE_FIELDS = {
    "role", "bonuses", "effectId", "slotType", "skillLevel",
    "tradeSkill", "incomplete", "cultivationType",
}

function StockPiler2.Items.Get(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    local items = ItemsTable()
    local row = items[tostring(uid)]
    if type(row) == "table" then
        return row
    end
    return nil
end

function StockPiler2.Items.Upsert(uid, fields)
    uid = tonumber(uid) or 0
    if uid <= 0 or type(fields) ~= "table" then
        return nil
    end
    local items = ItemsTable()
    local key = tostring(uid)
    local row = items[key]
    if type(row) ~= "table" then
        row = { uniqueID = uid }
    end
    row.uniqueID = uid
    for k, v in pairs(fields) do
        if v ~= nil then
            if k == "itemType" and (tonumber(v) or 0) == 0 and (tonumber(row.itemType) or 0) > 0 then
                -- keep existing
            else
                row[k] = v
            end
        end
    end
    items[key] = row
    return row
end

function StockPiler2.Items.UpsertFromItemData(itemData, kindHint)
    if type(itemData) ~= "table" then
        return nil
    end
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
    if uid <= 0 then
        return nil
    end
    local fields = {
        kind = kindHint,
        name = itemData.name,
        nameNarrow = StockPiler2.ToNarrow(itemData.name),
        iconNum = tonumber(itemData.iconNum) or 0,
        skillReq = tonumber(itemData.craftingSkillRequirement) or 0,
        tradeSkill = tonumber(itemData.tradeSkill) or 0,
        cultivationType = tonumber(itemData.cultivationType) or 0,
        isRefinable = itemData.isRefinable == true,
        itemType = tonumber(itemData.type) or tonumber(itemData.itemType) or 0,
        iLevel = tonumber(itemData.iLevel) or 0,
    }
    local hasLiveCraft = ItemDataHasCraftBonuses(itemData)
    if StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.FromItemData then
        local spec = StockPiler2.MaterialSpec.FromItemData(itemData)
        if type(spec) == "table" then
            local copied = StockPiler2.MaterialSpec.Copy and StockPiler2.MaterialSpec.Copy(spec) or spec
            fields.role = copied.role
            fields.skillLevel = copied.skillLevel
            fields.slotType = copied.slotType
            fields.effectId = copied.effectId
            fields.bonuses = copied.bonuses
            fields.tradeSkill = copied.tradeSkill or fields.tradeSkill
            fields.cultivationType = copied.cultivationType or fields.cultivationType
            fields.incomplete = copied.incomplete == true
            if not fields.kind then
                local role = copied.role or ""
                if role == "ingredient" and (fields.cultivationType == 1 or fields.cultivationType == 5) then
                    fields.kind = (fields.cultivationType == 5) and "spore" or "seed"
                elseif role ~= "" and role ~= "ingredient" then
                    fields.kind = "mat"
                end
            end
        end
    end
    if not fields.kind then
        fields.kind = "mat"
    end
    local existing = StockPiler2.Items.Get(uid)
    if type(existing) == "table" and (not hasLiveCraft or ExistingCraftProfileIsRicher(existing, fields)) then
        for i = 1, #CRAFT_PROFILE_FIELDS do
            fields[CRAFT_PROFILE_FIELDS[i]] = nil
        end
        if (tonumber(fields.skillReq) or 0) == 0 and (tonumber(existing.skillReq) or 0) > 0 then
            fields.skillReq = nil
        end
    end
    return StockPiler2.Items.Upsert(uid, fields)
end

function StockPiler2.Items.ToSpec(uid)
    local row = StockPiler2.Items.Get(uid)
    if type(row) ~= "table" then
        return nil
    end
    return {
        tradeSkill = tonumber(row.tradeSkill) or 0,
        skillLevel = tonumber(row.skillLevel) or tonumber(row.skillReq) or 0,
        slotType = tonumber(row.slotType) or 0,
        effectId = row.effectId,
        bonuses = type(row.bonuses) == "table" and row.bonuses or {},
        cultivationType = tonumber(row.cultivationType) or 0,
        role = row.role,
        incomplete = row.incomplete == true,
    }
end

function StockPiler2.Items.AsItemData(uid)
    local row = StockPiler2.Items.Get(uid)
    if type(row) ~= "table" then
        return nil
    end
    return {
        uniqueID = tonumber(row.uniqueID) or tonumber(uid) or 0,
        name = row.name,
        nameNarrow = row.nameNarrow,
        iconNum = tonumber(row.iconNum) or 0,
        craftingSkillRequirement = tonumber(row.skillReq) or 0,
        tradeSkill = tonumber(row.tradeSkill) or 0,
        cultivationType = tonumber(row.cultivationType) or 0,
        isRefinable = row.isRefinable == true,
        itemType = tonumber(row.itemType) or 0,
        type = tonumber(row.itemType) or 0,
        iLevel = tonumber(row.iLevel) or 0,
        craftingBonus = nil,
    }
end
