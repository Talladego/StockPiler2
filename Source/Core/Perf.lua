----------------------------------------------------------------
-- StockPiler2 Core/Perf — optional LibPerf.Scope bridge
--
-- When LibPerf is loaded: StockPiler2.Perf is an isolated scope writing
-- logs/libperf_StockPiler2.log. Enable/threshold via /libperf only
-- (persisted in LibPerf.Settings). When missing: no-op stubs.
-- LibPerf owns UPDATE_PROCESSED; EngineEventBridge must not call OnFrame.
----------------------------------------------------------------

StockPiler2 = StockPiler2 or {}

local function Noop()
end

local function MakeNoopPerf()
    local Perf = {
        Enabled = false,
        FrameThresholdMs = 400,
        Available = false,
    }
    function Perf.IsEnabled()
        return false
    end
    function Perf.SetEnabled(on)
        Perf.Enabled = on == true
    end
    function Perf.Enable()
        Perf.SetEnabled(true)
    end
    function Perf.Disable()
        Perf.SetEnabled(false)
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
    Perf.SetThreshold = Perf.SetFrameThreshold
    Perf.GetThreshold = Perf.GetFrameThreshold
    Perf.Begin = Noop
    Perf.End = Noop
    Perf.Mark = Noop
    Perf.HoldTrail = Noop
    Perf.ShouldHoldTrail = function()
        return false
    end
    Perf.ResetSummary = Noop
    Perf.OnFrame = Noop
    Perf.PrintSummary = Noop
    Perf.DumpSummary = Noop
    function Perf.IsBaselineCollecting()
        return false
    end
    function Perf.StartBaseline()
        return 50
    end
    Perf.PrintBaseline = Noop
    function Perf.GetLogPath()
        return ""
    end
    return Perf
end

-- Client idle floor is often ~140-155ms; thresholds below this flood empty-trail noise.
local CAPTURE_FLOOR_MS = 250

if LibPerf and type(LibPerf.Scope) == "function" then
    local Perf = LibPerf.Scope("StockPiler2")
    Perf.Available = true
    function Perf.OnFrame(_timeElapsed)
        -- LibPerf owns the frame pump; intentionally empty.
    end
    -- 0.4.144: bump restored low thresholds so next Autogrow/brew capture stays usable.
    local thr = 0
    if Perf.GetThreshold then
        thr = tonumber(Perf.GetThreshold()) or 0
    elseif Perf.GetFrameThreshold then
        thr = tonumber(Perf.GetFrameThreshold()) or 0
    end
    if thr > 0 and thr < CAPTURE_FLOOR_MS then
        if Perf.SetThreshold then
            Perf.SetThreshold(CAPTURE_FLOOR_MS)
        elseif Perf.SetFrameThreshold then
            Perf.SetFrameThreshold(CAPTURE_FLOOR_MS)
        end
    end
    StockPiler2.Perf = Perf
else
    StockPiler2.Perf = MakeNoopPerf()
end
