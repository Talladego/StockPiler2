----------------------------------------------------------------
-- StockPiler2 Stores/WatchStore — per-character watches + toggles
----------------------------------------------------------------

StockPiler2.Watch = StockPiler2.Watch or {}

function StockPiler2.Watch.GetGen()
    return tonumber(StockPiler2.Watch._gen) or 0
end

function StockPiler2.Watch.CharacterRow()
    if not StockPiler2.Persistence or not StockPiler2.Persistence.GetCharacterBucket then
        return nil
    end
    local row = StockPiler2.Persistence.GetCharacterBucket(true)
    return row
end

function StockPiler2.Watch.GetCharacterKey()
    if StockPiler2.Persistence and StockPiler2.Persistence.GetCharacterKey then
        return StockPiler2.Persistence.GetCharacterKey()
    end
    return "_default"
end

function StockPiler2.Watch.GetWatches()
    local row = StockPiler2.Watch.CharacterRow()
    if type(row) ~= "table" then
        return {}
    end
    return row.watches
end

function StockPiler2.Watch.BumpGen()
    StockPiler2.Watch._gen = (tonumber(StockPiler2.Watch._gen) or 0) + 1
end

function StockPiler2.Watch.IsAutoGrowEnabled()
    local row = StockPiler2.Watch.CharacterRow()
    return type(row) == "table" and row.autoGrowEnabled == true
end

function StockPiler2.Watch.IsAutoGrowAdditivesEnabled()
    local row = StockPiler2.Watch.CharacterRow()
    return type(row) == "table" and row.autoGrowAdditives == true
end

function StockPiler2.Watch.GetSeedBufferMin()
    local row = StockPiler2.Watch.CharacterRow()
    local n = type(row) == "table" and tonumber(row.growSeedBufferMin) or nil
    if n == nil or n < 0 then
        return 5
    end
    return math.floor(n)
end

function StockPiler2.Watch.IsSeedBufferEnabled()
    local row = StockPiler2.Watch.CharacterRow()
    if type(row) ~= "table" then
        return true
    end
    return row.growSeedBufferEnabled ~= false
end

function StockPiler2.Watch.IsAutoBuyEnabled()
    local row = StockPiler2.Watch.CharacterRow()
    return type(row) == "table" and row.autoBuyEnabled == true
end

function StockPiler2.Watch.GetAutoBuyReserveGold()
    local row = StockPiler2.Watch.CharacterRow()
    local n = type(row) == "table" and tonumber(row.autoBuyReserveGold) or nil
    if n == nil or n < 1 then
        return 10
    end
    if n > 99 then
        return 99
    end
    return math.floor(n)
end

function StockPiler2.Watch.GetAutoBuyBudgetGold()
    local row = StockPiler2.Watch.CharacterRow()
    local n = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or nil
    if n == nil or n < 1 then
        return 50
    end
    if n > 999 then
        return 999
    end
    return math.floor(n)
end
