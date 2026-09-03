----------------------------------------------------------------
-- StockPiler2 Adapters/CultivatorAdapter — cultivation read + plant
----------------------------------------------------------------

StockPiler2.CultivatorAdapter = StockPiler2.CultivatorAdapter or {}
local CA = StockPiler2.CultivatorAdapter

local function ToNarrow(value)
    if StockPiler2.ToNarrow then
        return StockPiler2.ToNarrow(value)
    end
    return tostring(value or "")
end

local function NameEquals(itemName, asciiNeedle)
    if asciiNeedle == nil or asciiNeedle == "" or itemName == nil then
        return false
    end
    return string.lower(ToNarrow(itemName)) == string.lower(asciiNeedle)
end

function CA.TradeSkill()
    if GameData and GameData.TradeSkills and GameData.TradeSkills.CULTIVATION then
        return GameData.TradeSkills.CULTIVATION
    end
    return 3
end

function CA.CraftingBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        return EA_Window_Backpack.TYPE_CRAFTING
    end
    return 4
end

function CA.InventoryBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_INVENTORY then
        return EA_Window_Backpack.TYPE_INVENTORY
    end
    return 2
end

local function BackpackTypeForBagKey(bagKey)
    if bagKey == "craft" then
        return CA.CraftingBackpackType()
    end
    return CA.InventoryBackpackType()
end

function CA.NumPlots()
    if GameData and GameData.Player and GameData.Player.Cultivation then
        return tonumber(GameData.Player.Cultivation.NumPlots) or 4
    end
    return 4
end

local function StageEmpty()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.EMPTY or 0
    end
    return 0
end

--- One-shot dump so uilog proves GetCultivationInfo seed fields after reload.
CA._loggedCultivationInfo = CA._loggedCultivationInfo or false

local function SeedUidFromSeedTable(seed)
    if type(seed) ~= "table" then
        return 0
    end
    local uid = tonumber(seed.uniqueID) or 0
    if uid <= 0 then
        uid = tonumber(seed.id) or 0
    end
    return uid
end

local function LogCultivationInfoOnce(plotNum, info)
    if CA._loggedCultivationInfo == true or type(info) ~= "table" then
        return
    end
    CA._loggedCultivationInfo = true
    local seed = info.Seed
    local sid = SeedUidFromSeedTable(seed)
    local msg = "cult| GetCultivationInfo P" .. tostring(plotNum)
        .. " StageNum=" .. tostring(info.StageNum)
        .. " Seed.id=" .. tostring(type(seed) == "table" and seed.id or nil)
        .. " Seed.uniqueID=" .. tostring(type(seed) == "table" and seed.uniqueID or nil)
        .. " seedUid=" .. tostring(sid)
    if StockPiler2.D then
        StockPiler2.D(msg)
    elseif StockPiler2.Debug and StockPiler2.Debug.LogAlways then
        StockPiler2.Debug.LogAlways(msg)
    end
end

local function ReadAdditivesMap(src)
    local out = {}
    if type(src) ~= "table" then
        return out
    end
    for cultType, slot in pairs(src) do
        local ct = tonumber(cultType) or 0
        if ct > 0 and type(slot) == "table" then
            local id = tonumber(slot.id) or 0
            local uid = tonumber(slot.uniqueID) or 0
            if uid <= 0 then
                uid = id
            end
            out[ct] = {
                id = id,
                uniqueID = uid,
                filled = id ~= 0 or uid ~= 0,
                item = slot,
            }
        end
    end
    return out
end

--- Prefer engine GetCultivationInfo (same as default CultivationWindow).
--- Plots[].seedUniqueID/stage are often empty and broke manual plant→harvest learn.
function CA.ReadPlot(plotNum)
    plotNum = tonumber(plotNum) or 0
    local out = { plotNum = plotNum, stage = 0, seedUid = 0, plantUid = 0, additives = {} }
    if plotNum <= 0 then
        return out
    end

    if type(GetCultivationInfo) == "function" then
        local ok, info
        if StockPiler2.TryCall then
            ok, info = StockPiler2.TryCall("GetCultivationInfo", GetCultivationInfo, plotNum)
        else
            ok, info = pcall(GetCultivationInfo, plotNum)
        end
        if ok == true and type(info) == "table" then
            LogCultivationInfoOnce(plotNum, info)
            local stage = tonumber(info.StageNum) or 0
            -- Default UI treats 255 as EMPTY.
            if stage == 255 then
                stage = StageEmpty()
            end
            out.stage = stage
            out.seedUid = SeedUidFromSeedTable(info.Seed)
            -- Plant product id when present (optional; harvest loot still teaches plantUid).
            if type(info.Plant) == "table" then
                out.plantUid = tonumber(info.Plant.uniqueID) or tonumber(info.Plant.id) or 0
            elseif info.PlantUniqueID ~= nil then
                out.plantUid = tonumber(info.PlantUniqueID) or 0
            end
            out.additives = ReadAdditivesMap(info.Additives)
            return out
        end
    end

    -- Fallback if GetCultivationInfo missing (should not happen on live RoR).
    if not GameData or not GameData.Player or not GameData.Player.Cultivation then
        return out
    end
    local cult = GameData.Player.Cultivation
    local plots = cult.Plots
    if type(plots) == "table" and type(plots[plotNum]) == "table" then
        local p = plots[plotNum]
        out.stage = tonumber(p.stage) or tonumber(p.StageNum) or 0
        if out.stage == 255 then
            out.stage = StageEmpty()
        end
        out.seedUid = tonumber(p.seedUniqueID) or SeedUidFromSeedTable(p.Seed) or 0
        out.plantUid = tonumber(p.plantUniqueID) or 0
        out.additives = ReadAdditivesMap(p.Additives)
    end
    return out
end

--- Same API as plant: AddCraftingItem(Cultivation, plot, backpackSlot, backpackType).
function CA.ApplyAdditive(plotNum, slot, backpackType)
    return CA.PlantSeed(plotNum, slot, backpackType)
end

function CA.FindSeedSlot(seedUid, seedKey)
    seedUid = tonumber(seedUid) or 0
    seedKey = ToNarrow(seedKey or "")
    local BA = StockPiler2.BagAdapter
    if not BA or not BA.FetchLight or not BA.IterateSlots then
        return 0, nil, CA.CraftingBackpackType()
    end
    local bestSlot = 0
    local bestItem = nil
    local bestBagKey = nil
    local bestStack = 10000
    local function consider(bagKey, slot, item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        local matched = false
        if seedUid > 0 and uid == seedUid then
            matched = true
        elseif seedKey ~= "" and NameEquals(item.name, seedKey) then
            matched = true
        end
        if matched and StockPiler2.Inventory and StockPiler2.Inventory.CanUseCraftingItem
            and not StockPiler2.Inventory.CanUseCraftingItem(item)
        then
            matched = false
        end
        if matched then
            local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
            if stack < bestStack then
                bestSlot = slot
                bestStack = stack
                bestItem = item
                bestBagKey = bagKey
            end
        end
    end
    local bags = BA.FetchLight()
    for i = 1, #bags do
        BA.IterateSlots(bags[i], consider)
    end
    if bestSlot > 0 then
        return bestSlot, bestItem, BackpackTypeForBagKey(bestBagKey)
    end
    return 0, nil, CA.CraftingBackpackType()
end

function CA.PlantSeed(plotNum, slot, backpackType)
    plotNum = tonumber(plotNum) or 0
    slot = tonumber(slot) or 0
    if plotNum <= 0 or slot <= 0 or AddCraftingItem == nil then
        return false, "invalid-args"
    end
    backpackType = tonumber(backpackType) or CA.CraftingBackpackType()
    local ok, err = StockPiler2.TryCall("AddCraftingItem", AddCraftingItem, CA.TradeSkill(), plotNum, slot, backpackType)
    if not ok then
        return false, err
    end
    return true
end

--- Same API as plant: AddCraftingItem(Cultivation, plot, backpackSlot, backpackType).
function CA.ApplyAdditive(plotNum, slot, backpackType)
    return CA.PlantSeed(plotNum, slot, backpackType)
end
