----------------------------------------------------------------
-- StockPiler2 Executors — stubs (one engine action per tick)
----------------------------------------------------------------

StockPiler2.GrowExecutor = StockPiler2.GrowExecutor or {}
StockPiler2.RefineExecutor = StockPiler2.RefineExecutor or {}
-- BuyExecutor lives in Source/Executors/BuyExecutor.lua
StockPiler2.BrewExecutor = StockPiler2.BrewExecutor or {}
StockPiler2.BuyExecutor = StockPiler2.BuyExecutor or {}

function StockPiler2.GrowExecutor.Tick(opId)
    if StockPiler2.Grow and StockPiler2.Grow.TryPlantNextEmptyPlot then
        if StockPiler2.Grow.TryPlantNextEmptyPlot(opId) == true then
            return true
        end
    end
    if StockPiler2.Grow and StockPiler2.Grow.TryApplyNextAdditive then
        if StockPiler2.Grow.TryApplyNextAdditive(opId) == true then
            return true
        end
    end
    return false
end

function StockPiler2.GrowExecutor.Harvest(opId)
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("harvest", "opId=" .. tostring(opId) .. " prepare")
    end
    if StockPiler2.Grow and StockPiler2.Grow.PrepareHarvestPlot then
        local ok = StockPiler2.Grow.PrepareHarvestPlot(true) == true
        if ok ~= true then
            return false, "no-ready-plot"
        end
        return true
    end
    return false, "not-implemented"
end
