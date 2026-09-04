----------------------------------------------------------------
-- StockPiler2 Stores/GardenStore — plot cache (event write only)
----------------------------------------------------------------

StockPiler2.Garden = StockPiler2.Garden or {}
local Garden = StockPiler2.Garden

Garden._gen = 0
Garden._planGen = 0
Garden._plots = {}

function Garden.GetGen()
    return tonumber(Garden._gen) or 0
end

--- Plan cache only cares about plant/empty transitions, not grow-stage ticks.
function Garden.GetPlanGen()
    return tonumber(Garden._planGen) or 0
end

local function IsPlotEmptyStage(stage)
    if GameData and GameData.CultivationStage then
        return (tonumber(stage) or 0) == (GameData.CultivationStage.EMPTY or 0)
    end
    return (tonumber(stage) or 0) == 0
end

local function ActionablePlotChange(prev, row)
    if type(prev) ~= "table" then
        return true
    end
    if (tonumber(prev.seedUid) or 0) ~= (tonumber(row.seedUid) or 0) then
        return true
    end
    if (tonumber(prev.plantUid) or 0) ~= (tonumber(row.plantUid) or 0) then
        return true
    end
    if IsPlotEmptyStage(prev.stage) ~= IsPlotEmptyStage(row.stage) then
        return true
    end
    return false
end

local function AdditiveFillKey(row)
    if type(row) ~= "table" or type(row.additives) ~= "table" then
        return ""
    end
    local parts = {}
    for cultType, slot in pairs(row.additives) do
        if type(slot) == "table" and (slot.filled == true or (tonumber(slot.id) or 0) ~= 0) then
            parts[#parts + 1] = tostring(cultType) .. ":"
                .. tostring(tonumber(slot.uniqueID) or tonumber(slot.id) or 0)
        end
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function ApplyPlotRow(plotNum, row)
    local prev = Garden._plots[plotNum]
    local anyChange = type(prev) ~= "table" or prev.stage ~= row.stage
        or prev.seedUid ~= row.seedUid or prev.plantUid ~= row.plantUid
        or AdditiveFillKey(prev) ~= AdditiveFillKey(row)
    local planChange = ActionablePlotChange(prev, row)
    Garden._plots[plotNum] = row
    return anyChange, planChange
end

function Garden.GetPlotsCopy()
    local out = {}
    for k, v in pairs(Garden._plots) do
        out[k] = v
    end
    return out
end

function Garden.SyncAll()
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Garden.SyncAll")
    end
    local CA = StockPiler2.CultivatorAdapter
    if not CA then
        if Perf and Perf.End then
            Perf.End("Garden.SyncAll")
        end
        return
    end
    local n = CA.NumPlots()
    local changed = false
    local planChanged = false
    for plotNum = 1, n do
        local row = CA.ReadPlot(plotNum)
        local anyChange, plotPlanChange = ApplyPlotRow(plotNum, row)
        if anyChange then
            changed = true
        end
        if plotPlanChange then
            planChanged = true
        end
    end
    if changed then
        Garden._gen = (tonumber(Garden._gen) or 0) + 1
        if planChanged then
            Garden._planGen = (tonumber(Garden._planGen) or 0) + 1
        end
        local B = StockPiler2.EventBus
        local E = StockPiler2.Events
        if B and E and E.GARDEN_SNAPSHOT then
            B.Fire(E.GARDEN_SNAPSHOT, { gardenGen = Garden._gen })
        end
    end
    if Perf and Perf.End then
        Perf.End("Garden.SyncAll")
    end
end

function Garden.OnCultivationUpdated()
    local plotNum = 0
    if GameData and GameData.Player and GameData.Player.Cultivation then
        plotNum = tonumber(GameData.Player.Cultivation.UpdatedIndex) or 0
    end
    local genBefore = tonumber(Garden._gen) or 0
    local planGenBefore = tonumber(Garden._planGen) or 0
    if plotNum > 0 and StockPiler2.CultivatorAdapter then
        local row = StockPiler2.CultivatorAdapter.ReadPlot(plotNum)
        local anyChange, planChange = ApplyPlotRow(plotNum, row)
        if anyChange then
            Garden._gen = genBefore + 1
        end
        if planChange then
            Garden._planGen = planGenBefore + 1
        end
    else
        Garden.SyncAll()
    end
    if (tonumber(Garden._gen) or 0) > genBefore then
        local B = StockPiler2.EventBus
        local E = StockPiler2.Events
        if B and E and E.GARDEN_DIRTY then
            B.Fire(E.GARDEN_DIRTY, { gardenGen = Garden._gen, plotNum = plotNum })
        end
    end
end
