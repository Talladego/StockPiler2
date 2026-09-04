----------------------------------------------------------------
-- StockPiler2 Adapters/ApothecaryAdapter — open/load/clear/perform/close
----------------------------------------------------------------

StockPiler2.ApothecaryAdapter = StockPiler2.ApothecaryAdapter or {}
local AA = StockPiler2.ApothecaryAdapter

function AA.TradeSkill()
    if GameData and GameData.TradeSkills and GameData.TradeSkills.APOTHECARY then
        return GameData.TradeSkills.APOTHECARY
    end
    return 4
end

function AA.CraftingBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_CRAFTING then
        return EA_Window_Backpack.TYPE_CRAFTING
    end
    return 4
end

function AA.IsApothecary()
    local Caps = StockPiler2.TradeSkillCaps
    if Caps and Caps.HasApothecary then
        return Caps.HasApothecary() == true
    end
    local apoId = AA.TradeSkill()
    local level = 0
    if GameData and type(GameData.TradeSkillLevels) == "table" then
        level = tonumber(GameData.TradeSkillLevels[apoId]) or 0
    end
    return level > 0
end

function AA.WindowName()
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.windowName) == "string" then
        return ApothecaryWindow.windowName
    end
    return "ApothecaryWindow"
end

function AA.WindowOpen()
    local name = AA.WindowName()
    return DoesWindowExist(name) and WindowGetShowing(name) == true
end

function AA.CraftingState()
    if not GameData or not GameData.CraftingStatus then
        return -1
    end
    return tonumber(GameData.CraftingStatus.State) or -1
end

function AA.CraftingSkillType()
    if not GameData or not GameData.CraftingStatus then
        return -1
    end
    return tonumber(GameData.CraftingStatus.SkillType) or -1
end

function AA.IsPerforming()
    if type(ApothecaryWindow) == "table" and ApothecaryWindow.STATE_PERFORMING then
        if ApothecaryWindow.currentState == ApothecaryWindow.STATE_PERFORMING then
            return true
        end
    end
    if GameData and GameData.CraftingStates and GameData.CraftingStates.PERFORMING then
        return AA.CraftingSkillType() == AA.TradeSkill()
            and AA.CraftingState() == GameData.CraftingStates.PERFORMING
    end
    return type(ApothecaryWindow) == "table" and ApothecaryWindow.PerformingLock == true
end

function AA.IsBusy()
    return AA.IsPerforming() == true
end

function AA.SetSoftLocks(enabled)
    if type(EA_BackpackUtilsMediator) == "table"
        and type(EA_BackpackUtilsMediator.EnableSoftLocks) == "function"
    then
        StockPiler2.TryCallQuiet(
            "EnableSoftLocks",
            EA_BackpackUtilsMediator.EnableSoftLocks,
            enabled == true
        )
    elseif type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.EnableSoftLocks) == "function"
    then
        StockPiler2.TryCallQuiet(
            "EA_Window_Backpack.EnableSoftLocks",
            EA_Window_Backpack.EnableSoftLocks,
            enabled == true
        )
    end
end

function AA.ReleaseBackpackLocks()
    local name = AA.WindowName()
    if type(EA_BackpackUtilsMediator) == "table"
        and type(EA_BackpackUtilsMediator.ReleaseAllLocksForWindow) == "function"
    then
        StockPiler2.TryCall(
            "ReleaseAllLocksForWindow",
            EA_BackpackUtilsMediator.ReleaseAllLocksForWindow,
            name
        )
    elseif type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.ReleaseAllLocksForWindow) == "function"
    then
        StockPiler2.TryCall(
            "EA_Window_Backpack.ReleaseAllLocksForWindow",
            EA_Window_Backpack.ReleaseAllLocksForWindow,
            name
        )
    end
    AA.SetSoftLocks(false)
end

local function RemoveEntry(apo, slot, backpack, seen)
    if slot == nil or backpack == nil then
        return false
    end
    local key = tostring(backpack) .. ":" .. tostring(slot)
    if type(seen) == "table" then
        if seen[key] then
            return false
        end
        seen[key] = true
    end
    if type(RemoveCraftingItem) == "function" then
        StockPiler2.TryCall("RemoveCraftingItem", RemoveCraftingItem, apo, slot, backpack)
        return true
    end
    return false
end

function AA.ClearSlots()
    local apo = AA.TradeSkill()
    local cleared = false
    local seen = {}
    if type(GetCraftingBackPackSlots) == "function" then
        local ok, slots = StockPiler2.TryCallQuiet("GetCraftingBackPackSlots", GetCraftingBackPackSlots, apo)
        if ok and type(slots) == "table" then
            for index = 4, 0, -1 do
                local entry = slots[index]
                if type(entry) == "table" then
                    if RemoveEntry(apo, entry.slot, entry.backpack, seen) then
                        cleared = true
                    end
                end
            end
            for _, entry in pairs(slots) do
                if type(entry) == "table" then
                    if RemoveEntry(apo, entry.slot, entry.backpack, seen) then
                        cleared = true
                    end
                end
            end
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.craftingData) == "table"
        and type(RemoveCraftingItem) == "function"
    then
        for slotNum = 4, 0, -1 do
            local cd = ApothecaryWindow.craftingData[slotNum]
            if type(cd) == "table" and cd.sourceSlot and cd.sourceBackpack then
                if RemoveEntry(apo, cd.sourceSlot, cd.sourceBackpack, seen) then
                    cleared = true
                end
            end
        end
    end
    return cleared
end

function AA.HideWindowOnly()
    local name = AA.WindowName()
    if DoesWindowExist(name) and WindowGetShowing(name) then
        StockPiler2.TryCall("WindowSetShowing", WindowSetShowing, name, false)
        if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
            StockPiler2.TryCallQuiet("RemoveFromOpenList", WindowUtils.RemoveFromOpenList, name)
        end
        return true
    end
    return false
end

--- Headless apo session when possible. Sets ownership flags on Brew module.
function AA.OpenSession(brew)
    brew = brew or StockPiler2.Brew
    if StockPiler2.EnsureApothecaryHook then
        StockPiler2.EnsureApothecaryHook()
    end
    if AA.WindowOpen() then
        if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
            StockPiler2.TryCallQuiet(
                "SetCurrentTradeSkill",
                CraftingSystem.SetCurrentTradeSkill,
                AA.TradeSkill()
            )
        end
        return true
    end
    if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
        StockPiler2.TryCallQuiet(
            "SetCurrentTradeSkill",
            CraftingSystem.SetCurrentTradeSkill,
            AA.TradeSkill()
        )
    end
    if CraftingSystem and type(CraftingSystem.SetStaticData) == "function" then
        StockPiler2.TryCallQuiet("SetStaticData", CraftingSystem.SetStaticData)
    end
    if type(SendInitCrafting) == "function" then
        StockPiler2.TryCall("SendInitCrafting", SendInitCrafting, AA.TradeSkill())
    end
    AA.SetSoftLocks(true)
    if type(brew) == "table" then
        brew._idleForceClosed = false
        brew._brewOwnedSession = true
        brew._brewApoStealth = true
    end
    AA.HideWindowOnly()
    if AA.CraftingSkillType() == AA.TradeSkill() then
        return true
    end
    if not (CraftingSystem and type(CraftingSystem.ToggleShowing) == "function") then
        return AA.CraftingSkillType() == AA.TradeSkill()
    end
    StockPiler2.TryCall(
        "CraftingSystem.ToggleShowing",
        CraftingSystem.ToggleShowing,
        AA.TradeSkill()
    )
    if AA.CraftingSkillType() ~= AA.TradeSkill() and not AA.WindowOpen() then
        return false
    end
    if type(brew) == "table" then
        brew._idleForceClosed = false
        brew._brewOwnedSession = true
        brew._brewOpenedApo = true
        brew._brewApoStealth = true
    end
    AA.HideWindowOnly()
    return true
end

function AA.CloseSession(brew)
    brew = brew or StockPiler2.Brew
    local apo = AA.TradeSkill()
    local closeApo = type(brew) == "table" and brew._brewOpenedApo == true
    local ownedSession = type(brew) == "table" and brew._brewOwnedSession == true
    local stealth = type(brew) == "table" and brew._brewApoStealth == true
    local playerVisible = AA.WindowOpen()
    local apoSkillActive = AA.CraftingSkillType() == apo

    AA.ClearSlots()
    AA.ReleaseBackpackLocks()

    if type(brew) == "table" then
        brew._brewOpenedApo = false
        brew._brewOpenedBackpack = false
        brew._brewOwnedSession = false
        brew._brewApoStealth = false
    end

    local endEngine = ownedSession or stealth or closeApo
        or (apoSkillActive == true and not playerVisible)
    if not endEngine then
        return
    end

    if CraftingSystem and type(CraftingSystem.SetCurrentTradeSkill) == "function" then
        StockPiler2.TryCallQuiet(
            "SetCurrentTradeSkill",
            CraftingSystem.SetCurrentTradeSkill,
            apo
        )
    end

    if type(ApothecaryWindow) == "table" then
        if type(ApothecaryWindow.Clear) == "function" then
            StockPiler2.TryCall("ApothecaryWindow.Clear", ApothecaryWindow.Clear)
        end
        ApothecaryWindow.nextFreeSlot = 0
        ApothecaryWindow.PerformingLock = false
    end

    if type(SendCloseCrafting) == "function" then
        StockPiler2.TryCall("SendCloseCrafting", SendCloseCrafting, apo)
    end

    AA.ReleaseBackpackLocks()

    local name = AA.WindowName()
    if DoesWindowExist(name) then
        StockPiler2.TryCall("WindowSetShowing", WindowSetShowing, name, false)
        if type(WindowUtils) == "table" and type(WindowUtils.RemoveFromOpenList) == "function" then
            StockPiler2.TryCallQuiet("RemoveFromOpenList", WindowUtils.RemoveFromOpenList, name)
        end
    end
end

function AA.AddContainer(bagSlot, bagType)
    if type(AddCraftingContainer) ~= "function" then
        return false
    end
    return StockPiler2.TryCall(
        "AddCraftingContainer",
        AddCraftingContainer,
        AA.TradeSkill(),
        bagSlot,
        bagType
    ) == true
end

function AA.AddItem(craftSlot, bagSlot, bagType)
    if type(AddCraftingItem) ~= "function" then
        return false
    end
    return StockPiler2.TryCall(
        "AddCraftingItem",
        AddCraftingItem,
        AA.TradeSkill(),
        craftSlot,
        bagSlot,
        bagType
    ) == true
end

function AA.Perform()
    if type(PerformCrafting) ~= "function" then
        return false
    end
    local ok = StockPiler2.TryCall(
        "PerformCrafting",
        PerformCrafting,
        AA.TradeSkill(),
        1
    )
    if ok and type(ApothecaryWindow) == "table" then
        ApothecaryWindow.PerformingLock = true
    end
    return ok == true
end

function AA.GetCraftingBag()
    if type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
    then
        local ok, bag = StockPiler2.TryCallQuiet(
            "GetItemsFromBackpack",
            EA_Window_Backpack.GetItemsFromBackpack,
            AA.CraftingBackpackType()
        )
        if ok and type(bag) == "table" then
            return bag
        end
    end
    if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
        local ok, bag = StockPiler2.TryCallQuiet("DataUtils.GetCraftingItems", DataUtils.GetCraftingItems)
        if ok and type(bag) == "table" then
            return bag
        end
    end
    return nil
end

function AA.GetSlottedItem(craftingSlot)
    craftingSlot = tonumber(craftingSlot) or -1
    if craftingSlot < 0 then
        return nil
    end
    if type(GetCraftingBackPackSlots) == "function"
        and type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
    then
        local ok, slots = StockPiler2.TryCallQuiet(
            "GetCraftingBackPackSlots",
            GetCraftingBackPackSlots,
            AA.TradeSkill()
        )
        if ok and type(slots) == "table" then
            local entry = slots[craftingSlot]
            if type(entry) == "table" and entry.slot and entry.backpack then
                local bag = EA_Window_Backpack.GetItemsFromBackpack(entry.backpack)
                local item = type(bag) == "table" and bag[entry.slot] or nil
                if type(item) == "table" and (tonumber(item.uniqueID) or 0) > 0 then
                    return item
                end
            end
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.craftingData) == "table" then
        local cd = ApothecaryWindow.craftingData[craftingSlot]
        if type(cd) == "table" then
            if cd.sourceSlot ~= nil and type(EA_Window_Backpack) == "table"
                and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
            then
                local bag = EA_Window_Backpack.GetItemsFromBackpack(cd.sourceBackpack or AA.CraftingBackpackType())
                local fromBag = type(bag) == "table" and bag[cd.sourceSlot] or nil
                if type(fromBag) == "table" and (tonumber(fromBag.uniqueID) or 0) > 0 then
                    return fromBag
                end
            end
            if (tonumber(cd.objectId) or 0) > 0 then
                return {
                    uniqueID = tonumber(cd.objectId) or 0,
                    iconNum = tonumber(cd.iconId) or 0,
                }
            end
        end
    end
    return nil
end

function AA.ServerHasItems()
    if type(GetCraftingData) == "function" then
        local ok, data = StockPiler2.TryCallQuiet("GetCraftingData", GetCraftingData, AA.TradeSkill())
        if ok and type(data) == "table" then
            for slotNum = 0, 4 do
                local row = data[slotNum]
                if type(row) == "table" then
                    local id = tonumber(row.id) or tonumber(row.objectId) or tonumber(row.uniqueID) or 0
                    if id > 0 then
                        return true
                    end
                end
            end
        end
    end
    if type(GetCraftingBackPackSlots) == "function" then
        local ok, slots = StockPiler2.TryCallQuiet(
            "GetCraftingBackPackSlots",
            GetCraftingBackPackSlots,
            AA.TradeSkill()
        )
        if ok and type(slots) == "table" then
            for _, entry in pairs(slots) do
                if type(entry) == "table" and entry.slot then
                    return true
                end
            end
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.craftingData) == "table" then
        for slotNum = 0, 4 do
            local cd = ApothecaryWindow.craftingData[slotNum]
            if type(cd) == "table" and tonumber(cd.objectId) and tonumber(cd.objectId) > 0 then
                return true
            end
        end
    end
    return false
end

function AA.SessionReadyToFill()
    if AA.ServerHasItems() then
        return false
    end
    local containerSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_CONTAINER) or 0
    if AA.GetSlottedItem(containerSlot) ~= nil then
        return false
    end
    local cs = GameData and GameData.CraftingStates
    if cs == nil then
        return true
    end
    return AA.CraftingState() == cs.ADDCONTAINER
end
