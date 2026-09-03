----------------------------------------------------------------
-- StockPiler2 Core/Debug — logging, TryCall, event trace ring buffer
----------------------------------------------------------------

StockPiler2 = StockPiler2 or {}
StockPiler2.Debug = StockPiler2.Debug or {}

local D = StockPiler2.Debug

D.Enabled = false
D.EventTrace = false

local RING_MAX = 200
local ring = {}
local ringN = 0
local ringHead = 0
local _opId = 0

function D.NextOpId()
    _opId = _opId + 1
    return _opId
end

function D.LogText(msg)
    local text = msg
    if type(text) == "wstring" then
        local ok, s = pcall(WStringToString, text)
        if ok and s then
            text = s
        else
            text = "wstring"
        end
    elseif type(text) ~= "string" then
        text = tostring(text)
    end
    return text
end

function D.EmitLog(text)
    if type(d) == "function" then
        d(text)
    end
end

function D.LogAlways(msg)
    D.EmitLog("StockPiler2| " .. D.LogText(msg))
end

function D.D(msg)
    if D.Enabled ~= true then
        return
    end
    D.EmitLog("StockPiler2| " .. D.LogText(msg))
end

function D.LogOp(kind, msg)
    if D.Enabled ~= true then
        return
    end
    kind = tostring(kind or "op")
    D.EmitLog("StockPiler2| " .. D.LogText(kind .. "| " .. tostring(msg)))
end

local _reporting = false
function D.ReportProtectedCallFailure(context, err, quiet)
    if _reporting == true then
        return
    end
    _reporting = true
    local msg = tostring(context or "unknown") .. ": " .. tostring(err or "unknown error")
    pcall(function()
        if quiet == true then
            if D.Enabled == true then
                D.EmitLog("StockPiler2| TryCallQuiet " .. msg)
            end
            return
        end
        D.EmitLog("StockPiler2| TryCall " .. msg)
        if type(LogLuaMessage) == "function" and SystemData and SystemData.UiLogFilters then
            LogLuaMessage("Lua", SystemData.UiLogFilters.WARNING, towstring("[StockPiler2] " .. msg))
        end
    end)
    _reporting = false
end

function D.TryCall(context, fn, ...)
    if type(fn) ~= "function" then
        D.ReportProtectedCallFailure(context, "expected function, got " .. type(fn))
        return false
    end
    local results = { pcall(fn, ...) }
    local ok = table.remove(results, 1)
    if ok then
        if #results == 0 then
            return true
        end
        return true, unpack(results)
    end
    D.ReportProtectedCallFailure(context, results[1])
    return false
end

function D.TryCallQuiet(context, fn, ...)
    if type(fn) ~= "function" then
        return false
    end
    local results = { pcall(fn, ...) }
    local ok = table.remove(results, 1)
    if ok then
        if #results == 0 then
            return true
        end
        return true, unpack(results)
    end
    D.ReportProtectedCallFailure(context, results[1], true)
    return false
end

function D.RingPush(line)
    ringHead = ringHead + 1
    if ringHead > RING_MAX then
        ringHead = 1
    end
    ring[ringHead] = line
    if ringN < RING_MAX then
        ringN = ringN + 1
    end
end

function D.EventTraceNote(eventName, summary, subs)
    if D.EventTrace ~= true then
        return
    end
    local line = string.format(
        "event| %s subs=%s %s",
        tostring(eventName),
        tostring(subs or 0),
        tostring(summary or "")
    )
    D.LogOp("event", string.sub(line, 7))
    D.RingPush(line)
end

function D.DumpEventRing(emit)
    emit = type(emit) == "function" and emit or D.LogAlways
    emit("--- event ring (" .. tostring(ringN) .. " entries) ---")
    if ringN <= 0 then
        emit("  (empty)")
        return
    end
    local start = ringHead - ringN + 1
    if start < 1 then
        start = 1
    end
    for i = start, ringHead do
        local idx = i
        if idx > RING_MAX then
            idx = idx - RING_MAX
        end
        emit("  " .. tostring(ring[idx] or ""))
    end
    emit("--- end event ring ---")
end

function D.Print(msg)
    if EA_ChatWindow and EA_ChatWindow.Print then
        EA_ChatWindow.Print(towstring(msg), SystemData.SystemLogFilters.GENERAL)
    elseif type(d) == "function" then
        d("StockPiler2| " .. D.LogText(msg))
    end
end
