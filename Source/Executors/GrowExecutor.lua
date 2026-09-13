----------------------------------------------------------------
-- StockPiler2 Executors/GrowExecutor — plant / additive / harvest prepare
-- One engine action per Tick. Other executors live in their own files.
----------------------------------------------------------------

StockPiler2.GrowExecutor = StockPiler2.GrowExecutor or {}

function StockPiler2.GrowExecutor.Tick(opId)
    if StockPiler2.Grow and StockPiler2.Grow.TryPlantNextEmptyPlot then
        if StockPiler2.Grow.TryPlantNextEmptyPlot(opId) == true then
            return true
        end
    end
    return StockPiler2.GrowExecutor.TryAdditive(opId) == true
end

--- Additive-only path (Orch additive-only ticks; Tick also tries plant first).
function StockPiler2.GrowExecutor.TryAdditive(opId)
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
