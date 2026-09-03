----------------------------------------------------------------
-- StockPiler2 Core/Perf — frametime hitch breadcrumbs (SP1-aligned)
----------------------------------------------------------------

StockPiler2.Perf = StockPiler2.Perf or {}
local Perf = StockPiler2.Perf

Perf.Enabled = false
Perf.FrameThresholdMs = 400

local SECTION_MS = 50
local MAX_NAMES = 16
local TRAIL_IDLE_CLEAR_SEC = 0.1
local SUMMARY_MAX_ENTRIES = 12

local counts = {}
local order = {}
local orderN = 0
local starts = {}
local lastSpike = nil
local trailIdleSec = 0
local spikeStats = {}

local baseline = {
    collecting = false,
    count = 0,
    sum = 0,
    min = nil,
    max = 0,
    emptyTrail = 0,
    geThreshold = 0,
    thresholdMs = 50,
}

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function Emit(msg)
    if StockPiler2.Debug and StockPiler2.Debug.EmitLog then
        StockPiler2.Debug.EmitLog("StockPiler2| Perf| " .. StockPiler2.Debug.LogText(msg))
    end
end

local function ClearTrail()
    for i = 1, orderN do
        local name = order[i]
        counts[name] = nil
        order[i] = nil
    end
    orderN = 0
    trailIdleSec = 0
end

local function TrailText()
    if orderN <= 0 then
        return "(none)"
    end
    local parts = {}
    local n = orderN
    if n > MAX_NAMES then
        n = MAX_NAMES
    end
    for i = 1, n do
        local name = order[i]
        local c = counts[name] or 1
        if c > 1 then
            parts[i] = name .. " x" .. tostring(c)
        else
            parts[i] = name
        end
    end
    local text = table.concat(parts, ", ")
    if orderN > MAX_NAMES then
        text = text .. " +" .. tostring(orderN - MAX_NAMES) .. " names"
    end
    return text
end

local function RecordSpikeSummary(ms, trail)
    trail = trail or "(none)"
    local entry = spikeStats[trail]
    if type(entry) ~= "table" then
        entry = { count = 0, maxMs = 0 }
        spikeStats[trail] = entry
    end
    entry.count = entry.count + 1
    if ms > entry.maxMs then
        entry.maxMs = ms
    end
end

local function RecordBaseline(ms, trailEmpty)
    if baseline.collecting ~= true then
        return
    end
    baseline.count = baseline.count + 1
    baseline.sum = baseline.sum + ms
    if baseline.min == nil or ms < baseline.min then
        baseline.min = ms
    end
    if ms > baseline.max then
        baseline.max = ms
    end
    if trailEmpty then
        baseline.emptyTrail = baseline.emptyTrail + 1
    end
    if ms >= baseline.thresholdMs then
        baseline.geThreshold = baseline.geThreshold + 1
    end
end

function Perf.Mark(name)
    if Perf.Enabled ~= true then
        return
    end
    name = tostring(name or "?")
    trailIdleSec = 0
    if counts[name] == nil then
        orderN = orderN + 1
        order[orderN] = name
        counts[name] = 1
    else
        counts[name] = counts[name] + 1
    end
end

function Perf.Begin(name)
    if Perf.Enabled ~= true then
        return
    end
    name = tostring(name or "?")
    Perf.Mark(name)
    starts[name] = NowSec()
end

function Perf.End(name)
    if Perf.Enabled ~= true then
        return
    end
    name = tostring(name or "?")
    local t0 = starts[name]
    starts[name] = nil
    if t0 == nil then
        return
    end
    local dtMs = (NowSec() - t0) * 1000
    if dtMs >= SECTION_MS then
        Emit(string.format("section %s %.0fms", name, dtMs))
    end
end

function Perf.ShouldHoldTrail()
    local Sch = StockPiler2.Scheduler
    if Sch then
        if Sch._bagDue == true or Sch._planDue == true then
            return true
        end
    end
    return false
end

function Perf.OnFrame(timeElapsed)
    if Perf.Enabled ~= true then
        return
    end
    local ms = (tonumber(timeElapsed) or 0) * 1000
    local trailEmpty = orderN <= 0
    RecordBaseline(ms, trailEmpty)
    local threshold = tonumber(Perf.FrameThresholdMs) or 400
    if ms >= threshold then
        local trail = TrailText()
        local line = string.format("spike %.1fms trail=%s", ms, trail)
        lastSpike = line
        RecordSpikeSummary(ms, trail)
        Emit(line)
    end
    if orderN > 0 then
        if Perf.ShouldHoldTrail() then
            trailIdleSec = 0
        else
            trailIdleSec = trailIdleSec + (tonumber(timeElapsed) or 0)
            if trailIdleSec >= TRAIL_IDLE_CLEAR_SEC then
                ClearTrail()
            end
        end
    else
        trailIdleSec = 0
    end
end

function Perf.SetFrameThreshold(ms)
    ms = tonumber(ms)
    if ms == nil or ms < 1 then
        return tonumber(Perf.FrameThresholdMs) or 400
    end
    if ms > 10000 then
        ms = 10000
    end
    Perf.FrameThresholdMs = ms
    return ms
end

function Perf.GetFrameThreshold()
    return tonumber(Perf.FrameThresholdMs) or 400
end

function Perf.SetEnabled(on)
    Perf.Enabled = on == true
    if Perf.Enabled ~= true then
        ClearTrail()
    end
    Emit("perf " .. (Perf.Enabled and "ON" or "OFF"))
end

function Perf.ResetSummary()
    spikeStats = {}
end

function Perf.PrintSummary()
    local ranked = {}
    for trail, entry in pairs(spikeStats) do
        if type(entry) == "table" and (entry.count or 0) > 0 then
            ranked[#ranked + 1] = {
                trail = trail,
                count = entry.count or 0,
                maxMs = entry.maxMs or 0,
            }
        end
    end
    if #ranked <= 0 then
        local threshold = Perf.GetFrameThreshold()
        Emit("summary empty (no hitches >= " .. tostring(threshold) .. "ms recorded)")
        if StockPiler2.Ui and StockPiler2.Ui.Print then
            StockPiler2.Ui.Print(L"Perf summary: no hitches recorded. /sp2 perf on 100 then reproduce.")
        end
        return
    end
    table.sort(ranked, function(a, b)
        if a.maxMs ~= b.maxMs then
            return a.maxMs > b.maxMs
        end
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.trail < b.trail
    end)
    local n = #ranked
    if n > SUMMARY_MAX_ENTRIES then
        n = SUMMARY_MAX_ENTRIES
    end
    Emit(string.format("summary top %d trails (threshold=%dms):", n, Perf.GetFrameThreshold()))
    if StockPiler2.Ui and StockPiler2.Ui.Print then
        StockPiler2.Ui.Print(L"Perf summary (top " .. towstring(tostring(n)) .. L" trails):")
    end
    for i = 1, n do
        local row = ranked[i]
        local line = string.format("#%d count=%d max=%.0fms %s", i, row.count, row.maxMs, row.trail)
        Emit(line)
        if StockPiler2.Ui and StockPiler2.Ui.Print then
            StockPiler2.Ui.Print(L"  " .. towstring(string.format("#%d x%d max=%.0fms %s",
                i, row.count, row.maxMs, row.trail)))
        end
    end
end

function Perf.IsBaselineCollecting()
    return baseline.collecting == true
end

function Perf.StartBaseline(thresholdMs)
    thresholdMs = tonumber(thresholdMs) or 50
    if thresholdMs < 1 then
        thresholdMs = 50
    end
    baseline.thresholdMs = thresholdMs
    baseline.count = 0
    baseline.sum = 0
    baseline.min = nil
    baseline.max = 0
    baseline.emptyTrail = 0
    baseline.geThreshold = 0
    baseline.collecting = true
    Perf.SetFrameThreshold(thresholdMs)
    Perf.SetEnabled(true)
    Perf.ResetSummary()
    return thresholdMs
end

function Perf.PrintBaseline()
    if baseline.count <= 0 then
        Emit("baseline empty (no frames recorded)")
        if StockPiler2.Ui and StockPiler2.Ui.Print then
            StockPiler2.Ui.Print(L"Perf baseline: no frames recorded yet.")
        end
        return
    end
    local avg = baseline.sum / baseline.count
    local emptyPct = (baseline.emptyTrail / baseline.count) * 100
    local gePct = (baseline.geThreshold / baseline.count) * 100
    local line = string.format(
        "baseline n=%d avg=%.0fms min=%.0fms max=%.0fms emptyTrail=%.0f%% ge%dms=%.0f%% threshold=%d",
        baseline.count,
        avg,
        baseline.min or 0,
        baseline.max,
        emptyPct,
        baseline.thresholdMs,
        gePct,
        baseline.thresholdMs
    )
    Emit(line)
    if StockPiler2.Ui and StockPiler2.Ui.Print then
        StockPiler2.Ui.Print(L"Perf baseline: " .. towstring(string.format(
            "n=%d avg=%.0f min=%.0f max=%.0f emptyTrail=%.0f%% >=%dms=%.0f%%",
            baseline.count, avg, baseline.min or 0, baseline.max, emptyPct,
            baseline.thresholdMs, gePct
        )))
    end
    baseline.collecting = false
    Perf.PrintSummary()
end
