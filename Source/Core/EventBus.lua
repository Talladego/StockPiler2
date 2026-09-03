----------------------------------------------------------------
-- StockPiler2 Core/EventBus — internal pub/sub
----------------------------------------------------------------

StockPiler2.EventBus = StockPiler2.EventBus or {}

local Bus = StockPiler2.EventBus
local subs = {}

StockPiler2.Events = StockPiler2.Events or {
    INVENTORY_DIRTY = "sp2.inventory.dirty",
    INVENTORY_SNAPSHOT = "sp2.inventory.snapshot",
    GARDEN_DIRTY = "sp2.garden.dirty",
    GARDEN_SNAPSHOT = "sp2.garden.snapshot",
    PLAN_INVALIDATED = "sp2.plan.invalidated",
    PLAN_UPDATED = "sp2.plan.updated",
    PHASE_CHANGED = "sp2.phase.changed",
    OP_COMPLETED = "sp2.op.completed",
    CMD_HARVEST = "sp2.cmd.harvest",
    CMD_BREW_LOAD = "sp2.cmd.brew.load",
    CMD_BREW_PERFORM = "sp2.cmd.brew.perform",
    SESSION_LOADED = "sp2.session.loaded",
    KNOWLEDGE_UPDATED = "sp2.knowledge.updated",
}

function Bus.Subscribe(eventName, fn)
    eventName = tostring(eventName or "")
    if eventName == "" or type(fn) ~= "function" then
        return false
    end
    local list = subs[eventName]
    if list == nil then
        list = {}
        subs[eventName] = list
    end
    list[#list + 1] = fn
    return true
end

function Bus.UnsubscribeAll(eventName)
    if eventName == nil then
        subs = {}
        return
    end
    subs[tostring(eventName)] = nil
end

function Bus.Fire(eventName, payload)
    eventName = tostring(eventName or "")
    local list = subs[eventName]
    local n = type(list) == "table" and #list or 0
    if StockPiler2.Debug and StockPiler2.Debug.EventTraceNote then
        local summary = ""
        if type(payload) == "table" then
            if payload.snapGen then
                summary = summary .. "snapGen=" .. tostring(payload.snapGen) .. " "
            end
            if payload.reason then
                summary = summary .. "reason=" .. tostring(payload.reason) .. " "
            end
            if payload.phase then
                summary = summary .. "phase=" .. tostring(payload.phase) .. " "
            end
        end
        StockPiler2.Debug.EventTraceNote(eventName, summary, n)
    end
    if n <= 0 then
        return
    end
    for i = 1, n do
        local fn = list[i]
        if type(fn) == "function" then
            StockPiler2.Debug.TryCallQuiet("EventBus." .. eventName, fn, payload)
        end
    end
end
