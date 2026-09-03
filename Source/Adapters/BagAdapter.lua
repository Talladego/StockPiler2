----------------------------------------------------------------
-- StockPiler2 Adapters/BagAdapter — read backpack + craft bag tables
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

local function FetchBags(forceRefresh)
    local bags = {}
    if forceRefresh == true and GameData and GameData.Player then
        GameData.Player.itemsDirty = true
        GameData.Player.craftingItemsDirty = true
    end
    if DataUtils and type(DataUtils.GetItems) == "function" then
        local ok, data = TryQuiet("BagAdapter.GetItems", DataUtils.GetItems)
        if ok and type(data) == "table" then
            bags[#bags + 1] = { bagType = BAG_MAIN, data = data }
        end
    elseif type(GetInventoryItemData) == "function" then
        local ok, data = TryQuiet("BagAdapter.GetInventoryItemData", GetInventoryItemData)
        if ok and type(data) == "table" then
            bags[#bags + 1] = { bagType = BAG_MAIN, data = data }
        end
    end
    if forceRefresh == true and GameData and GameData.Player then
        GameData.Player.craftingItemsDirty = true
    end
    if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
        local ok, data = TryQuiet("BagAdapter.GetCraftingItems", DataUtils.GetCraftingItems)
        if ok and type(data) == "table" then
            bags[#bags + 1] = { bagType = BAG_CRAFT, data = data }
        end
    elseif type(GetCraftingItemData) == "function" then
        local ok, data = TryQuiet("BagAdapter.GetCraftingItemData", GetCraftingItemData)
        if ok and type(data) == "table" then
            bags[#bags + 1] = { bagType = BAG_CRAFT, data = data }
        end
    end
    return bags
end

function BA.FetchLight()
    return FetchBags(false)
end

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

function BA.ReadSlot(bagType, slot)
    bagType = tostring(bagType or BAG_MAIN)
    slot = tonumber(slot) or 0
    if slot <= 0 then
        return 0, 0, nil
    end
    -- Prefer single-slot API (no full bag fetch).
    if DataUtils and type(DataUtils.GetItemData) == "function" and GameData and GameData.ItemLocs then
        local itemLoc = nil
        if bagType == BAG_CRAFT then
            itemLoc = GameData.ItemLocs.CRAFTING_ITEM
        else
            itemLoc = GameData.ItemLocs.INVENTORY
        end
        if itemLoc ~= nil then
            local ok, item = TryQuiet("BagAdapter.GetItemData", DataUtils.GetItemData, itemLoc, slot)
            if ok then
                local uid, qty = BA.SlotQty(item)
                return uid, qty, item
            end
        end
    end
    local bags = BA.FetchLight()
    for i = 1, #bags do
        local entry = bags[i]
        if entry.bagType == bagType then
            local item = entry.data and entry.data[slot]
            local uid, qty = BA.SlotQty(item)
            return uid, qty, item
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
    if bagType == BAG_CRAFT then
        if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
            local ok, data = TryQuiet("BagAdapter.GetCraftingItems", DataUtils.GetCraftingItems)
            if ok and type(data) == "table" then
                return { bagType = BAG_CRAFT, data = data }
            end
        elseif type(GetCraftingItemData) == "function" then
            local ok, data = TryQuiet("BagAdapter.GetCraftingItemData", GetCraftingItemData)
            if ok and type(data) == "table" then
                return { bagType = BAG_CRAFT, data = data }
            end
        end
    else
        if DataUtils and type(DataUtils.GetItems) == "function" then
            local ok, data = TryQuiet("BagAdapter.GetItems", DataUtils.GetItems)
            if ok and type(data) == "table" then
                return { bagType = BAG_MAIN, data = data }
            end
        elseif type(GetInventoryItemData) == "function" then
            local ok, data = TryQuiet("BagAdapter.GetInventoryItemData", GetInventoryItemData)
            if ok and type(data) == "table" then
                return { bagType = BAG_MAIN, data = data }
            end
        end
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
