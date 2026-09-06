----------------------------------------------------------------
-- StockPiler2 Adapters/BagAdapter — read backpack + craft bag tables
-- Hot path: DataUtils dirty-gated cache (no force-dirty). FetchForce = recovery only.
----------------------------------------------------------------

StockPiler2.BagAdapter = StockPiler2.BagAdapter or {}
local BA = StockPiler2.BagAdapter

local BAG_MAIN = "main"
local BAG_CRAFT = "craft"

function BA.BagTypes()
    return BAG_MAIN, BAG_CRAFT
end

local function TryQuiet(label, fn, ...)
    if StockPiler2.Debug and StockPiler2.Debug.TryCallQuiet then
        return StockPiler2.Debug.TryCallQuiet(label, fn, ...)
    end
    return pcall(fn, ...)
end

--- Backpack-equivalent: DataUtils.GetItems / GetCraftingItems (or engine fallback).
--- Does not set dirty flags — trusts engine/DataUtils dirty gate.
function BA.GetBagTable(bagType)
    bagType = tostring(bagType or BAG_MAIN)
    if bagType == BAG_CRAFT then
        if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
            local ok, data = TryQuiet("BagAdapter.GetCraftingItems", DataUtils.GetCraftingItems)
            if ok and type(data) == "table" then
                return data
            end
        elseif type(GetCraftingItemData) == "function" then
            local ok, data = TryQuiet("BagAdapter.GetCraftingItemData", GetCraftingItemData)
            if ok and type(data) == "table" then
                return data
            end
        end
        return nil
    end
    if DataUtils and type(DataUtils.GetItems) == "function" then
        local ok, data = TryQuiet("BagAdapter.GetItems", DataUtils.GetItems)
        if ok and type(data) == "table" then
            return data
        end
    elseif type(GetInventoryItemData) == "function" then
        local ok, data = TryQuiet("BagAdapter.GetInventoryItemData", GetInventoryItemData)
        if ok and type(data) == "table" then
            return data
        end
    end
    return nil
end

local function FetchBags(forceRefresh)
    if forceRefresh == true and GameData and GameData.Player then
        -- Recovery only: force engine re-dump on next GetItems / GetCraftingItems.
        GameData.Player.itemsDirty = true
        GameData.Player.craftingItemsDirty = true
    end
    local bags = {}
    local main = BA.GetBagTable(BAG_MAIN)
    if type(main) == "table" then
        bags[#bags + 1] = { bagType = BAG_MAIN, data = main }
    end
    -- Stock GetCraftingItems clears itemsDirty (client bug); ensure craft dirty stuck
    -- if we forced both above so craft still reloads when called second.
    if forceRefresh == true and GameData and GameData.Player then
        GameData.Player.craftingItemsDirty = true
    end
    local craft = BA.GetBagTable(BAG_CRAFT)
    if type(craft) == "table" then
        bags[#bags + 1] = { bagType = BAG_CRAFT, data = craft }
    end
    return bags
end

function BA.FetchLight()
    return FetchBags(false)
end

--- Forces engine bag dumps. Use only for session load / explicit desync recovery.
function BA.FetchForce()
    return FetchBags(true)
end

local function ItemPresent(item)
    if type(item) ~= "table" then
        return false
    end
    local uid = tonumber(item.uniqueID) or 0
    if uid > 0 then
        return true
    end
    local n = tonumber(item.stackCount) or tonumber(item.Count) or 0
    return n > 0
end

function BA.SlotQty(item)
    if type(item) ~= "table" then
        return 0, 0
    end
    local uid = tonumber(item.uniqueID) or 0
    local qty = tonumber(item.stackCount) or tonumber(item.Count) or 0
    if uid > 0 and qty <= 0 then
        qty = 1
    end
    return uid, qty
end

function BA.IterateSlots(bagEntry, fn)
    if type(bagEntry) ~= "table" or type(fn) ~= "function" then
        return
    end
    local bag = bagEntry.data
    local bagType = bagEntry.bagType or BAG_MAIN
    if type(bag) ~= "table" then
        return
    end
    local n = #bag
    if n > 0 then
        for slot = 1, n do
            local item = bag[slot]
            if ItemPresent(item) then
                fn(bagType, slot, item)
            end
        end
        return
    end
    for slot, item in pairs(bag) do
        if type(slot) == "number" and ItemPresent(item) then
            fn(bagType, slot, item)
        end
    end
end

--- Read one slot from a pre-fetched bag table (preferred for multi-slot events).
function BA.ReadSlotFromTable(bagTable, slot)
    slot = tonumber(slot) or 0
    if slot <= 0 or type(bagTable) ~= "table" then
        return 0, 0, nil
    end
    local item = bagTable[slot]
    local uid, qty = BA.SlotQty(item)
    return uid, qty, item
end

function BA.ReadSlot(bagType, slot)
    bagType = tostring(bagType or BAG_MAIN)
    slot = tonumber(slot) or 0
    if slot <= 0 then
        return 0, 0, nil
    end
    -- Index warm DataUtils cache (GetItems/GetCraftingItems); no FetchLight per slot.
    local bag = BA.GetBagTable(bagType)
    if type(bag) == "table" then
        return BA.ReadSlotFromTable(bag, slot)
    end
    if DataUtils and type(DataUtils.GetItemData) == "function" and GameData and GameData.ItemLocs then
        local itemLoc = bagType == BAG_CRAFT and GameData.ItemLocs.CRAFTING_ITEM
            or GameData.ItemLocs.INVENTORY
        if itemLoc ~= nil then
            local ok, item = TryQuiet("BagAdapter.GetItemData", DataUtils.GetItemData, itemLoc, slot)
            if ok then
                local uid, qty = BA.SlotQty(item)
                return uid, qty, item
            end
        end
    end
    return 0, 0, nil
end

--- Read one bag table without forcing the other bag dirty.
function BA.FetchBag(bagType, forceRefresh)
    bagType = tostring(bagType or BAG_MAIN)
    if forceRefresh == true and GameData and GameData.Player then
        if bagType == BAG_CRAFT then
            GameData.Player.craftingItemsDirty = true
        else
            GameData.Player.itemsDirty = true
        end
    end
    local data = BA.GetBagTable(bagType)
    if type(data) == "table" then
        return { bagType = bagType == BAG_CRAFT and BAG_CRAFT or BAG_MAIN, data = data }
    end
    return nil
end

local function ItemLabel(item)
    if StockPiler2.ToNarrow then
        return StockPiler2.ToNarrow(item and item.name)
    end
    return tostring(item and item.name or "?")
end

function BA.Dump(emit, opts)
    emit = type(emit) == "function" and emit or function() end
    opts = type(opts) == "table" and opts or {}
    if StockPiler2.Inventory and StockPiler2.Inventory.RefreshAllIfNeeded then
        StockPiler2.Inventory.RefreshAllIfNeeded({ force = opts.force == true })
    end
    local bags = opts.force == true and BA.FetchForce() or BA.FetchLight()
    emit("=== StockPiler2 bags ===")
    if #bags == 0 then
        emit("  (no bag data)")
        emit("=== end bags ===")
        return
    end
    for i = 1, #bags do
        local entry = bags[i]
        local bagType = tostring(entry.bagType or "?")
        local slotCount = 0
        emit("--- " .. bagType .. " bag ---")
        BA.IterateSlots(entry, function(_, slot, item)
            slotCount = slotCount + 1
            local uid, qty = BA.SlotQty(item)
            emit(string.format(
                "  slot=%d uid=%d qty=%d name=%s cultType=%s",
                slot,
                uid,
                qty,
                ItemLabel(item),
                tostring(item and item.cultivationType or "?")
            ))
        end)
        if slotCount == 0 then
            emit("  (empty)")
        end
    end
    emit("=== end bags ===")
end
