----------------------------------------------------------------
-- StockPiler2 Executors/BrewExecutor — load tick + perform
----------------------------------------------------------------

StockPiler2.BrewExecutor = StockPiler2.BrewExecutor or {}

function StockPiler2.BrewExecutor.Tick(opId)
    if StockPiler2.Brew and StockPiler2.Brew.Tick then
        StockPiler2.Brew.Tick()
        return type(StockPiler2.Brew._job) == "table"
    end
    return false
end

function StockPiler2.BrewExecutor.TryPerform(opId)
    if not StockPiler2.Brew or not StockPiler2.Brew.TryBrewClick then
        return false, "not-implemented"
    end
    local result = StockPiler2.Brew.TryBrewClick()
    if result == "go" and StockPiler2.Brew.FirePerform then
        local ok = StockPiler2.Brew.FirePerform()
        if ok then
            return true
        end
        return false, "perform-failed"
    end
    return false, "blocked"
end
