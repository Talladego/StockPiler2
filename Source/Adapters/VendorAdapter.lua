----------------------------------------------------------------
-- StockPiler2 Adapters/VendorAdapter — NPC interaction store
----------------------------------------------------------------

StockPiler2.VendorAdapter = StockPiler2.VendorAdapter or {}
local VA = StockPiler2.VendorAdapter

local STORE_WIN = "EA_Window_InteractionStore"
VA._storeHooked = false

local function TryQuiet(context, fn, ...)
    if StockPiler2.TryCallQuiet then
        return StockPiler2.TryCallQuiet(context, fn, ...)
    end
    if type(fn) ~= "function" then
        return false, nil
    end
    local ok, a, b = pcall(fn, ...)
    return ok, a, b
end

function VA.IsStoreOpen()
    if type(DoesWindowExist) ~= "function" or type(WindowGetShowing) ~= "function" then
        return false
    end
    if not DoesWindowExist(STORE_WIN) then
        return false
    end
    return WindowGetShowing(STORE_WIN) == true
end

function VA.IsBuybackView()
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" then
        return false
    end
    return store.displayData ~= nil and store.displayData == store.buyBackData
end

--- Visible store listing (not buyback). Pages arrive over time.
function VA.StoreRows()
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" then
        return nil
    end
    if store.displayData ~= nil and store.displayData == store.buyBackData then
        return nil
    end
    local list = store.displayData
    if type(list) ~= "table" then
        list = store.storedata
    end
    if type(list) ~= "table" and type(GetStoreData) == "function" then
        local ok, data = TryQuiet("GetStoreData", GetStoreData)
        if ok then
            list = data
        end
    end
    if type(list) ~= "table" then
        return nil
    end
    return list
end

function VA.GetPlayerMoneyBrass()
    if type(Player) ~= "table" or type(Player.GetMoney) ~= "function" then
        return 0
    end
    local ok, value = TryQuiet("Player.GetMoney", Player.GetMoney)
    if not ok then
        return 0
    end
    return tonumber(value) or 0
end

--- Skip confirm dialog; same as SP1 / default BuyItem path.
function VA.BuyItem(itemData, buyCount)
    buyCount = tonumber(buyCount) or 0
    if type(itemData) ~= "table" or buyCount < 1 then
        return false, "invalid-args"
    end
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" or type(store.BuyItem) ~= "function" then
        return false, "no-api"
    end
    local ok, err = StockPiler2.TryCall("VendorAdapter.BuyItem", store.BuyItem, itemData, buyCount)
    if not ok then
        return false, err
    end
    return true
end

local function NotifyStoreUpdated()
    if StockPiler2.Buy and StockPiler2.Buy.OnStoreUpdated then
        StockPiler2.Buy.OnStoreUpdated()
    end
    if StockPiler2.Buy and StockPiler2.Buy.LearnFromOpenStore then
        StockPiler2.Buy.LearnFromOpenStore()
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoBuy then
        StockPiler2.Scheduler.WakeAutoBuy()
    end
end

function VA.OnStoreShow()
    NotifyStoreUpdated()
end

--- Wrap store UI updates so page arrivals refresh AutoBuy + vendor learn.
function VA.EnsureStoreHook()
    if VA._storeHooked == true then
        return
    end
    local store = EA_Window_InteractionStore
    if type(store) ~= "table" then
        return
    end
    if type(store.ShowStore) == "function" and store._sp2ShowStoreWrapped ~= true then
        local orig = store.ShowStore
        store.ShowStore = function(...)
            local a, b, c = orig(...)
            StockPiler2.TryCall("VendorAdapter.OnStoreShow", VA.OnStoreShow)
            return a, b, c
        end
        store._sp2ShowStoreWrapped = true
    end
    if type(store.UpdateStoreList) == "function" and store._sp2UpdateStoreWrapped ~= true then
        local orig = store.UpdateStoreList
        store.UpdateStoreList = function(...)
            local a, b, c = orig(...)
            StockPiler2.TryCall("VendorAdapter.OnStoreShow", VA.OnStoreShow)
            return a, b, c
        end
        store._sp2UpdateStoreWrapped = true
    end
    if type(store.UpdateBuyBackList) == "function" and store._sp2UpdateBuyBackWrapped ~= true then
        local orig = store.UpdateBuyBackList
        store.UpdateBuyBackList = function(...)
            local a, b, c = orig(...)
            StockPiler2.TryCall("VendorAdapter.OnStoreShow", VA.OnStoreShow)
            return a, b, c
        end
        store._sp2UpdateBuyBackWrapped = true
    end
    VA._storeHooked = true
end
