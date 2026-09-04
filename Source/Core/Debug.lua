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

-- WarTriage / SP1 style: colored [StockPiler2] LINK prefix before chat body.
local CHAT_PREFIX_TEXT = "StockPiler2"
local CHAT_PREFIX_COLOR = { 170, 220, 170 }

local function ChatPrefix(includeSpace)
    local coloredPartRaw = string.format(
        "<LINK data=\"0\" color=\"%d,%d,%d\" text=\"%s\">",
        CHAT_PREFIX_COLOR[1],
        CHAT_PREFIX_COLOR[2],
        CHAT_PREFIX_COLOR[3],
        CHAT_PREFIX_TEXT
    )
    local prefix = L"[" .. towstring(coloredPartRaw) .. L"]"
    if includeSpace then
        prefix = prefix .. L" "
    end
    return prefix
end

function D.Print(msg)
    local body = msg
    if type(body) == "string" then
        body = towstring(body)
    elseif type(body) ~= "wstring" then
        if body == nil then
            body = L""
        else
            body = towstring(tostring(body))
        end
    end
    if EA_ChatWindow and EA_ChatWindow.Print then
        local filter = SystemData and SystemData.SystemLogFilters and SystemData.SystemLogFilters.GENERAL or 0
        EA_ChatWindow.Print(ChatPrefix(true) .. body, filter)
    elseif type(d) == "function" then
        d("StockPiler2| " .. D.LogText(body))
    end
end

--- User-facing ops chat (alias of Print).
function D.Notify(msg)
    D.Print(msg)
end

local _notifyOnce = {}

--- Print once per key until ClearNotifyOnce; safe to call from polled paths.
--- Returns true when the message was printed (first time for this key).
function D.NotifyOnce(key, msg)
    key = tostring(key or "")
    if key == "" then
        D.Notify(msg)
        return true
    end
    if _notifyOnce[key] == true then
        return false
    end
    _notifyOnce[key] = true
    D.Notify(msg)
    return true
end

function D.ClearNotifyOnce(key)
    key = tostring(key or "")
    if key == "" then
        return
    end
    _notifyOnce[key] = nil
end

function D.ClearNotifyOncePrefix(prefix)
    prefix = tostring(prefix or "")
    if prefix == "" then
        return
    end
    local n = string.len(prefix)
    for k, _ in pairs(_notifyOnce) do
        if type(k) == "string" and string.sub(k, 1, n) == prefix then
            _notifyOnce[k] = nil
        end
    end
end

--- Play a GameData.Sound / numeric id (no-op while loading or if PlaySound missing).
function D.PlayUiSound(soundId)
    soundId = tonumber(soundId)
    if soundId == nil then
        return
    end
    if SystemData and SystemData.LoadingData and SystemData.LoadingData.isLoading == true then
        return
    end
    if type(PlaySound) ~= "function" then
        return
    end
    if StockPiler2.TryCall then
        StockPiler2.TryCall("PlaySound", PlaySound, soundId)
    else
        pcall(PlaySound, soundId)
    end
end
