----------------------------------------------------------------
-- StockPiler2 Executors/BrewExecutor — load tick + perform
----------------------------------------------------------------

StockPiler2.BrewExecutor = StockPiler2.BrewExecutor or {}

function StockPiler2.BrewExecutor.BeginLoad(row, opts)
    if StockPiler2.Brew and StockPiler2.Brew.BeginForRow then
        return StockPiler2.Brew.BeginForRow(row, opts) == true
    end
    return false
end

function StockPiler2.BrewExecutor.Tick(opId)
    if StockPiler2.Brew and StockPiler2.Brew.Tick then
        StockPiler2.Brew.Tick()
        return type(StockPiler2.Brew._job) == "table"
    end
    return false
end

function StockPiler2.BrewExecutor.Perform(opId)
    if StockPiler2.Brew and StockPiler2.Brew.FirePerform then
        return StockPiler2.Brew.FirePerform() == true
    end
    return false
end

function StockPiler2.BrewExecutor.TryPerform(opId)
    if not StockPiler2.Brew or not StockPiler2.Brew.TryBrewClick then
        return false, "not-implemented"
    end
    local result = StockPiler2.Brew.TryBrewClick()
    if result == "go" then
        local ok = StockPiler2.BrewExecutor.Perform(opId)
        if ok then
            return true
        end
        return false, "perform-failed"
    end
    return false, "blocked"
end
