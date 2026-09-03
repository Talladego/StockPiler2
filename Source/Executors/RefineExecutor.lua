----------------------------------------------------------------
-- StockPiler2 Executors/RefineExecutor — plant→seed conversion tick
----------------------------------------------------------------

StockPiler2.RefineExecutor = StockPiler2.RefineExecutor or {}

function StockPiler2.RefineExecutor.Tick(opId, plan)
    if StockPiler2.Refine and StockPiler2.Refine.TryTick then
        if StockPiler2.Refine.TryTick(opId) == true then
            return true
        end
    end
    return false
end
