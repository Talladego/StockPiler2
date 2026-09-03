----------------------------------------------------------------
-- StockPiler2 Knowledge/Additives — Soil / Water / Nutrient
-- Classify + learn from craft-bag item data; persist Account.additives.
-- Auto-apply is Grow's job (stage match + AddCraftingItem).
----------------------------------------------------------------

StockPiler2.Additives = StockPiler2.Additives or {}
local AD = StockPiler2.Additives

local function ToNarrow(text)
    if StockPiler2.ToNarrow then
        return StockPiler2.ToNarrow(text)
    end
    return tostring(text or "")
end

local function CultTypes()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes
    end
    return { NONE = 0, SEED = 1, SOIL = 2, WATERCAN = 3, NUTRIENT = 4, SPORE = 5 }
end

local function CraftBonusRefs()
    if StockPiler2.BrewLearn and StockPiler2.BrewLearn.CraftBonus then
        return StockPiler2.BrewLearn.CraftBonus
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.CraftBonus then
        return StockPiler2.Inventory.CraftBonus
    end
    return {
        GROW_TIME = 10,
        CRITICAL_CHANCE = 12,
        FAIL_CHANCE = 13,
        SPECIAL_CHANCE = 14,
    }
end

local function FirstBonus(bonuses, ref)
    if type(bonuses) ~= "table" or type(bonuses[ref]) ~= "table" then
        return 0
    end
    return tonumber(bonuses[ref][1]) or 0
end

local function SignedBonus(val)
    val = tonumber(val) or 0
    if val > 32767 then
        return val - 65536
    end
    return val
end

local function ParseStats(itemData)
    local B = CraftBonusRefs()
    local bonuses = {}
    if type(itemData) == "table" and type(itemData.craftingBonus) == "table" then
        for _, bonus in pairs(itemData.craftingBonus) do
            if type(bonus) == "table" then
                local ref = tonumber(bonus.bonusReference) or 0
                if ref > 0 then
                    if bonuses[ref] == nil then
                        bonuses[ref] = {}
                    end
                    bonuses[ref][#bonuses[ref] + 1] = SignedBonus(bonus.bonusValue)
                end
            end
        end
    end
    return {
        growTime = FirstBonus(bonuses, B.GROW_TIME),
        critChance = FirstBonus(bonuses, B.CRITICAL_CHANCE),
        superCrit = FirstBonus(bonuses, B.SPECIAL_CHANCE),
        failChance = FirstBonus(bonuses, B.FAIL_CHANCE),
    }
end

local function AdditivesTable()
    if StockPiler2.Knowledge and StockPiler2.Knowledge.GetTable then
        return StockPiler2.Knowledge.GetTable("additives")
    end
    local acct = StockPiler2.Account
    if type(acct) ~= "table" then
        return nil
    end
    if type(acct.additives) ~= "table" then
        acct.additives = {}
    end
    return acct.additives
end

--- Classify from cultivationType and/or additive stat fingerprints.
function AD.Classify(itemData)
    if type(itemData) ~= "table" then
        return nil
    end
    local types = CultTypes()
    local soil = tonumber(types.SOIL) or 2
    local water = tonumber(types.WATERCAN) or 3
    local nutrient = tonumber(types.NUTRIENT) or 4
    local seed = tonumber(types.SEED) or 1
    local spore = tonumber(types.SPORE) or 5
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType == seed or cultType == spore then
        return nil
    end

    local stats = ParseStats(itemData) or {
        growTime = 0,
        critChance = 0,
        superCrit = 0,
        failChance = 0,
    }

    if cultType ~= soil and cultType ~= water and cultType ~= nutrient then
        if stats.growTime < 0 and stats.critChance > 0 and stats.superCrit <= 0 then
            cultType = soil
        elseif stats.growTime < 0 and stats.superCrit > 0 then
            cultType = water
        elseif stats.growTime < 0 and stats.failChance < 0 then
            cultType = nutrient
        else
            return nil
        end
    end

    local role = "soil"
    if cultType == water then
        role = "watering"
    elseif cultType == nutrient then
        role = "nutrient"
    end

    return {
        cultType = cultType,
        role = role,
        growTime = stats.growTime,
        critChance = stats.critChance,
        superCrit = stats.superCrit,
        failChance = stats.failChance,
    }
end

function AD.RoleLabel(role)
    if role == "watering" then
        return L"Watering"
    end
    if role == "nutrient" then
        return L"Nutrient"
    end
    return L"Soil"
end

function AD.IsEnabled()
    if StockPiler2.Watch and StockPiler2.Watch.IsAutoGrowAdditivesEnabled then
        return StockPiler2.Watch.IsAutoGrowAdditivesEnabled() == true
    end
    local row = StockPiler2.Watch and StockPiler2.Watch.CharacterRow and StockPiler2.Watch.CharacterRow()
    return type(row) == "table" and row.autoGrowAdditives == true
end

local function StoreRecord(itemData, info, source)
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
    if uid <= 0 then
        return false, false
    end
    local store = AdditivesTable()
    if type(store) ~= "table" then
        return false, false
    end
    local key = tostring(uid)
    local isNew = store[key] == nil
    local nameW = itemData.name
    if type(nameW) ~= "wstring" then
        nameW = towstring(tostring(itemData.name or ""))
    end
    store[key] = {
        uniqueID = uid,
        iconNum = tonumber(itemData.iconNum) or 0,
        name = nameW,
        nameNarrow = ToNarrow(itemData.name),
        cultType = info.cultType,
        role = info.role,
        growTime = info.growTime,
        critChance = info.critChance,
        superCrit = info.superCrit,
        failChance = info.failChance,
        skillReq = tonumber(itemData.craftingSkillRequirement) or 0,
        source = source or "bag",
    }
    if StockPiler2.Items and StockPiler2.Items.UpsertFromItemData then
        StockPiler2.Items.UpsertFromItemData(itemData, "additive")
    end
    if isNew and StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
        StockPiler2.Knowledge.Touch()
    end
    return true, isNew
end

--- Persist a slim additive record when bags / plot / tooltip show Soil / Water / Nutrient.
function AD.LearnFromItemData(itemData, source)
    local info = AD.Classify(itemData)
    if info == nil then
        return false
    end
    local stored, isNew = StoreRecord(itemData, info, source)
    if stored and isNew then
        if StockPiler2.D then
            StockPiler2.D("Learned additive uid=" .. tostring(itemData.uniqueID)
                .. " role=" .. tostring(info.role)
                .. " src=" .. tostring(source or "?"))
        elseif StockPiler2.Trace then
            StockPiler2.Trace("additive| learned uid=" .. tostring(itemData.uniqueID)
                .. " role=" .. tostring(info.role))
        end
    end
    return stored
end

function AD.LearnFromSnapshotSamples()
    local samples = StockPiler2.Inventory and StockPiler2.Inventory._sampleByUid
    if type(samples) ~= "table" then
        return 0
    end
    local types = CultTypes()
    local soil = tonumber(types.SOIL) or 2
    local water = tonumber(types.WATERCAN) or 3
    local nutrient = tonumber(types.NUTRIENT) or 4
    local n = 0
    for _, item in pairs(samples) do
        if type(item) == "table" then
            local cult = tonumber(item.cultivationType) or 0
            if cult == soil or cult == water or cult == nutrient
                or (cult == 0 and type(item.craftingBonus) == "table")
            then
                if AD.LearnFromItemData(item, "bag") then
                    n = n + 1
                end
            end
        end
    end
    return n
end

--- Secondary confirm: learn from plot additive slots when the engine fills them.
function AD.LearnFromPlotRow(row)
    if type(row) ~= "table" then
        return 0
    end
    local n = 0
    local slots = row.additives
    if type(slots) ~= "table" then
        slots = row.Additives
    end
    if type(slots) ~= "table" then
        return 0
    end
    for _, slot in pairs(slots) do
        if type(slot) == "table" then
            local item = slot.item or slot
            local id = tonumber(item.id) or tonumber(slot.id) or 0
            local uid = tonumber(item.uniqueID) or tonumber(slot.uniqueID) or 0
            if id ~= 0 or uid ~= 0 then
                if AD.LearnFromItemData(item, "plot") then
                    n = n + 1
                end
            end
        end
    end
    return n
end

function AD.PlayerCultivationSkill()
    local cult = (GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION) or 3
    if GameData and GameData.Player and type(GameData.Player.tradeSkills) == "table" then
        local row = GameData.Player.tradeSkills[cult]
        return type(row) == "table" and tonumber(row.level) or tonumber(row) or 0
    end
    if GameData and type(GameData.TradeSkillLevels) == "table" then
        return tonumber(GameData.TradeSkillLevels[cult]) or 0
    end
    return 0
end

--- Higher is better: skill req (highest usable), iLevel, role bonus, grow-time cut.
function AD.Score(info, skillReq, iLevel)
    if type(info) ~= "table" then
        return 0
    end
    local roleScore = tonumber(info.critChance) or 0
    if info.role == "watering" then
        roleScore = tonumber(info.superCrit) or 0
    elseif info.role == "nutrient" then
        roleScore = -(tonumber(info.failChance) or 0)
    end
    local timeScore = -(tonumber(info.growTime) or 0)
    return (tonumber(skillReq) or 0) * 100000
        + (tonumber(iLevel) or 0) * 1000
        + roleScore * 100
        + timeScore
end

function AD.StageForCultType(cultType)
    cultType = tonumber(cultType) or 0
    local types = CultTypes()
    local stages = GameData and GameData.CultivationStage
    if cultType == (tonumber(types.SOIL) or 2) then
        return (stages and stages.GERMINATION) or 1
    end
    if cultType == (tonumber(types.WATERCAN) or 3) then
        return (stages and stages.SEEDLING) or 2
    end
    if cultType == (tonumber(types.NUTRIENT) or 4) then
        return (stages and stages.FLOWERING) or 3
    end
    return nil
end

function AD.CultTypeForStage(stageNum)
    stageNum = tonumber(stageNum) or 0
    local stages = GameData and GameData.CultivationStage
    local germ = (stages and stages.GERMINATION) or 1
    local seed = (stages and stages.SEEDLING) or 2
    local flower = (stages and stages.FLOWERING) or 3
    local types = CultTypes()
    if stageNum == germ then
        return tonumber(types.SOIL) or 2
    end
    if stageNum == seed then
        return tonumber(types.WATERCAN) or 3
    end
    if stageNum == flower then
        return tonumber(types.NUTRIENT) or 4
    end
    return nil
end

--- True when plot already has this additive slot filled.
--- Accepts Garden row (additives[]) or raw GetCultivationInfo (Additives[]).
function AD.PlotHasAdditive(plotData, cultType)
    cultType = tonumber(cultType) or 0
    if type(plotData) ~= "table" or cultType <= 0 then
        return false
    end
    local slot = nil
    if type(plotData.additives) == "table" then
        slot = plotData.additives[cultType]
        if type(slot) == "table" then
            if slot.filled == true then
                return true
            end
            return (tonumber(slot.id) or 0) ~= 0
                or (tonumber(slot.uniqueID) or 0) ~= 0
        end
    end
    if type(plotData.Additives) == "table" then
        slot = plotData.Additives[cultType]
        if type(slot) == "table" then
            return (tonumber(slot.id) or 0) ~= 0
        end
    end
    return false
end

--- Best usable additive of this cultType in the crafting bag.
function AD.FindBestInCraftBag(cultType)
    cultType = tonumber(cultType) or 0
    if cultType <= 0 then
        return 0, nil, nil
    end
    local backpackType = 4
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        backpackType = EA_Window_Backpack.TYPE_CRAFTING
    end
    if StockPiler2.CultivatorAdapter and StockPiler2.CultivatorAdapter.CraftingBackpackType then
        backpackType = StockPiler2.CultivatorAdapter.CraftingBackpackType()
    end

    local bag = nil
    local Inv = StockPiler2.Inventory
    if Inv and Inv._ready == true and type(Inv._itemBySlot) == "table"
        and type(Inv._itemBySlot.craft) == "table"
    then
        bag = Inv._itemBySlot.craft
    end
    if type(bag) ~= "table" and DataUtils and DataUtils.GetCraftingItems then
        local ok, items
        if StockPiler2.TryCallQuiet then
            ok, items = StockPiler2.TryCallQuiet("DataUtils.GetCraftingItems", DataUtils.GetCraftingItems)
        else
            ok, items = pcall(DataUtils.GetCraftingItems)
        end
        if ok then
            bag = items
        end
    end
    if type(bag) ~= "table" then
        return 0, nil, nil
    end

    local skill = AD.PlayerCultivationSkill()
    local bestSlot = 0
    local bestItem = nil
    local bestScore = nil
    for slot, item in pairs(bag) do
        if type(item) == "table" then
            local info = AD.Classify(item)
            if info and info.cultType == cultType then
                local req = tonumber(item.craftingSkillRequirement) or 0
                local usable = req <= skill
                if usable and Inv and Inv.CanUseCraftingItem then
                    usable = Inv.CanUseCraftingItem(item) == true
                end
                if usable then
                    local iLevel = tonumber(item.iLevel) or tonumber(item.level) or 0
                    local score = AD.Score(info, req, iLevel)
                    if bestScore == nil or score > bestScore then
                        bestScore = score
                        bestSlot = tonumber(slot) or 0
                        bestItem = item
                    end
                end
            end
        end
    end
    if bestSlot <= 0 then
        return 0, nil, nil
    end
    return bestSlot, bestItem, backpackType
end

--- Optional one-shot import from StockPiler v1 settings when both addons are loaded.
function AD.TryMigrateFromSp1()
    local store = AdditivesTable()
    if type(store) ~= "table" then
        return 0
    end
    local src = nil
    if StockPiler and type(StockPiler.Settings) == "table" then
        src = StockPiler.Settings.additives
    end
    if type(src) ~= "table" and StockPiler and type(StockPiler.Account) == "table" then
        src = StockPiler.Account.additives
    end
    if type(src) ~= "table" then
        return 0
    end
    local n = 0
    for key, row in pairs(src) do
        if type(row) == "table" and store[tostring(key)] == nil then
            local uid = tonumber(row.uniqueID) or tonumber(key) or 0
            if uid > 0 then
                store[tostring(uid)] = {
                    uniqueID = uid,
                    iconNum = tonumber(row.iconNum) or 0,
                    name = row.name,
                    nameNarrow = row.nameNarrow or ToNarrow(row.name),
                    cultType = tonumber(row.cultType) or 0,
                    role = row.role,
                    growTime = tonumber(row.growTime) or 0,
                    critChance = tonumber(row.critChance) or 0,
                    superCrit = tonumber(row.superCrit) or 0,
                    failChance = tonumber(row.failChance) or 0,
                    skillReq = tonumber(row.skillReq) or 0,
                    source = "migrate-sp1",
                }
                n = n + 1
            end
        end
    end
    if n > 0 and StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
        StockPiler2.Knowledge.Touch()
    end
    if n > 0 and StockPiler2.D then
        StockPiler2.D("Additives migrated from SP1 count=" .. tostring(n))
    end
    return n
end

function AD.CountKnown()
    local store = AdditivesTable()
    if type(store) ~= "table" then
        return 0
    end
    local n = 0
    for _ in pairs(store) do
        n = n + 1
    end
    return n
end
