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
                iconNum = tonumber(slot.iconNum) or 0,
                name = slot.name,
                item = slot,
            }
        end
    end
    return out
end

local function SeedDisplayFromTable(seed)
    if type(seed) ~= "table" then
        return nil
    end
    return {
        uniqueID = SeedUidFromSeedTable(seed),
        name = seed.name,
        iconNum = tonumber(seed.iconNum) or 0,
        rarity = seed.rarity,
        itemSet = seed.itemSet,
    }
end

--- Prefer engine GetCultivationInfo (same as default CultivationWindow).
--- Plots[].seedUniqueID/stage are often empty and broke manual plant→harvest learn.
function CA.ReadPlot(plotNum)
    plotNum = tonumber(plotNum) or 0
    local out = {
        plotNum = plotNum,
        stage = 0,
        stageTimer = 0,
        stageTimerOn = false,
        totalTimer = 0,
        totalTimerOn = false,
        seedUid = 0,
        plantUid = 0,
        seedName = nil,
        seedIconNum = 0,
        seed = nil,
        additives = {},
    }
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
            out.stageTimer = tonumber(info.StageTimer) or 0
            out.totalTimer = tonumber(info.TotalTimer) or 0
            local filled = stage ~= StageEmpty()
            if info.StageTimerOn ~= nil or info.stageTimerOn ~= nil then
                out.stageTimerOn = info.StageTimerOn == true or info.stageTimerOn == true
            else
                out.stageTimerOn = filled and out.stageTimer > 0
            end
            if info.TotalTimerOn ~= nil or info.totalTimerOn ~= nil then
                out.totalTimerOn = info.TotalTimerOn == true or info.totalTimerOn == true
            else
                out.totalTimerOn = filled and out.totalTimer > 0
            end
            out.seedUid = SeedUidFromSeedTable(info.Seed)
            out.seed = SeedDisplayFromTable(info.Seed)
            if type(info.Seed) == "table" then
                out.seedName = info.Seed.name
                out.seedIconNum = tonumber(info.Seed.iconNum) or 0
            end
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
        out.stageTimer = tonumber(p.StageTimer) or tonumber(p.stageTimer) or 0
        out.totalTimer = tonumber(p.TotalTimer) or tonumber(p.totalTimer) or 0
        local filled = out.stage ~= StageEmpty()
        out.stageTimerOn = filled and out.stageTimer > 0
        out.totalTimerOn = filled and out.totalTimer > 0
        out.seedUid = tonumber(p.seedUniqueID) or SeedUidFromSeedTable(p.Seed) or 0
        out.seed = SeedDisplayFromTable(p.Seed)
        if type(p.Seed) == "table" then
            out.seedName = p.Seed.name
            out.seedIconNum = tonumber(p.Seed.iconNum) or 0
        end
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
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("FindSeedSlot")
    end

    local Inv = StockPiler2.Inventory
    local snapGen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    -- Memoize by snap + seedUid (same seed across plots in a fill wave).
    if seedUid > 0 and type(CA._seedSlotCache) == "table" then
        local cached = CA._seedSlotCache[seedUid]
        if type(cached) == "table" and (tonumber(cached.snapGen) or 0) == snapGen then
            local slot = tonumber(cached.slot) or 0
            local bagKey = cached.bagKey
            local item = nil
            if slot > 0 and Inv and Inv._ready == true and type(Inv._itemBySlot) == "table"
                and type(Inv._itemBySlot[bagKey]) == "table"
            then
                item = Inv._itemBySlot[bagKey][slot]
            end
            if type(item) == "table" and (tonumber(item.uniqueID) or 0) == seedUid then
                local stack = tonumber(item.stackCount) or tonumber(item.StackCount) or 1
                if stack > 0 then
                    if not (Inv.CanUseCraftingItem and not Inv.CanUseCraftingItem(item)) then
                        if Perf and Perf.End then
                            Perf.End("FindSeedSlot")
                        end
                        return slot, item, BackpackTypeForBagKey(bagKey)
                    end
                end
            end
            CA._seedSlotCache[seedUid] = nil
        end
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

    if Inv and Inv._ready == true and type(Inv._itemBySlot) == "table" then
        for bagKey, slots in pairs(Inv._itemBySlot) do
            if type(slots) == "table" then
                for slot, item in pairs(slots) do
                    consider(bagKey, tonumber(slot) or 0, item)
                end
            end
        end
    else
        local BA = StockPiler2.BagAdapter
        if BA and BA.FetchLight and BA.IterateSlots then
            local bags = BA.FetchLight()
            for i = 1, #bags do
                BA.IterateSlots(bags[i], consider)
            end
        end
    end

    if Perf and Perf.End then
        Perf.End("FindSeedSlot")
    end
    if bestSlot > 0 then
        if seedUid > 0 then
            if type(CA._seedSlotCache) ~= "table" then
                CA._seedSlotCache = {}
            end
            CA._seedSlotCache[seedUid] = {
                snapGen = snapGen,
                slot = bestSlot,
                bagKey = bestBagKey,
            }
        end
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
