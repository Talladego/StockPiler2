----------------------------------------------------------------
-- StockPiler2 Executors/BuyExecutor — one BuyItem per orchestrator tick
----------------------------------------------------------------

StockPiler2.BuyExecutor = StockPiler2.BuyExecutor or {}

function StockPiler2.BuyExecutor.Tick(opId)
    if not StockPiler2.Buy or not StockPiler2.Buy.OnTick then
        return false, "not-implemented"
    end
    if StockPiler2.Buy.OnTick() == true then
        if StockPiler2.Debug and StockPiler2.Debug.LogOp then
            StockPiler2.Debug.LogOp("buy", "opId=" .. tostring(opId or "?") .. " purchased")
        end
        return true
    end
    return false
end
