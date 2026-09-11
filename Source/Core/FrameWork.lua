----------------------------------------------------------------
-- StockPiler2 Core/FrameWork — frame-sliced prewarm (in-addon pattern)
--
-- PATTERN: frame-sliced prewarm (copy for other RoR addons)
-- RoR Lua finishes every for-loop in the same frame. Spread restartable CPU by:
--   1) Keep a last-complete cache for readers (hot path never waits on a half build).
--   2) Queue a job { id, gen, list|resume, step, stepsPerFrame }.
--   3) Each UPDATE / Scheduler.OnUpdate, run at most N steps; replace if gen changes.
--   4) Never slice game actions (PlantSeed / BuyItem / PerformCrafting).
--   5) Never publish a torn plan/UI snapshot — publish only in done() or keep prior.
-- Do NOT use maxMs budgets — GetGameTime() does not advance within a frame.
-- Prefer fuse-breaks (one heavy domain per frame: SkipPlan/SkipUi/didHeavy) before slicing.
--
-- See README 0.4.130 and Scheduler.OnUpdate didHeavy / Skip*ThisFrame.
----------------------------------------------------------------

StockPiler2.FrameWork = StockPiler2.FrameWork or {}
local FW = StockPiler2.FrameWork

FW.DEFAULT_STEPS_PER_FRAME = 1
FW.DEFAULT_FRAME_BUDGET = 4

FW._jobs = FW._jobs or {}
FW._order = FW._order or {}
FW._didWork = false
FW._frameBudget = tonumber(FW._frameBudget) or FW.DEFAULT_FRAME_BUDGET

local function TryCall(context, fn, ...)
    if StockPiler2.TryCallQuiet then
        return StockPiler2.TryCallQuiet(context, fn, ...)
    end
    return pcall(fn, ...)
end

local function RemoveFromOrder(id)
    local order = FW._order
    for i = #order, 1, -1 do
        if order[i] == id then
            table.remove(order, i)
        end
    end
end

--- Global steps allowed across all jobs this Pump() call.
function FW.SetFrameBudget(n)
    n = tonumber(n) or FW.DEFAULT_FRAME_BUDGET
    if n < 1 then
        n = 1
    end
    FW._frameBudget = n
end

function FW.GetFrameBudget()
    return tonumber(FW._frameBudget) or FW.DEFAULT_FRAME_BUDGET
end

--- True if Pump spent budget this Scheduler frame (treat like didHeavy).
function FW.DidWork()
    return FW._didWork == true
end

function FW.ClearDidWork()
    FW._didWork = false
end

function FW.IsActive(id)
    id = tostring(id or "")
    return id ~= "" and type(FW._jobs[id]) == "table"
end

function FW.Busy()
    return #(FW._order) > 0
end

function FW.Cancel(id)
    id = tostring(id or "")
    if id == "" then
        return
    end
    local job = FW._jobs[id]
    if type(job) ~= "table" then
        return
    end
    FW._jobs[id] = nil
    RemoveFromOrder(id)
    if type(job.cancel) == "function" then
        TryCall("FrameWork.cancel:" .. id, job.cancel)
    end
end

--- Start or replace a prewarm job.
--- opts.id (required), opts.gen (optional identity; same id+gen no-ops if already running)
--- opts.list + opts.step(item, index)  OR  opts.resume(state) → "continue"|"done"
--- opts.done / opts.cancel / opts.stepsPerFrame
function FW.Start(opts)
    opts = type(opts) == "table" and opts or nil
    if not opts then
        return false
    end
    local id = tostring(opts.id or "")
    if id == "" then
        return false
    end
    local gen = opts.gen
    local existing = FW._jobs[id]
    if type(existing) == "table" and existing.gen ~= nil and gen ~= nil
        and tostring(existing.gen) == tostring(gen)
    then
        return false
    end
    if type(existing) == "table" then
        FW.Cancel(id)
    end
    local steps = tonumber(opts.stepsPerFrame) or FW.DEFAULT_STEPS_PER_FRAME
    if steps < 1 then
        steps = 1
    end
    local job = {
        id = id,
        gen = gen,
        list = type(opts.list) == "table" and opts.list or nil,
        index = 1,
        step = type(opts.step) == "function" and opts.step or nil,
        resume = type(opts.resume) == "function" and opts.resume or nil,
        state = type(opts.state) == "table" and opts.state or {},
        done = type(opts.done) == "function" and opts.done or nil,
        cancel = type(opts.cancel) == "function" and opts.cancel or nil,
        stepsPerFrame = steps,
        cost = math.max(1, tonumber(opts.cost) or 1),
    }
    if job.list == nil and job.resume == nil and job.step == nil then
        return false
    end
    -- Single-shot: step with no list runs once via resume wrapper.
    if job.list == nil and job.resume == nil and job.step ~= nil then
        local stepFn = job.step
        job.resume = function(_state)
            TryCall("FrameWork.step:" .. id, stepFn, nil, 1)
            return "done"
        end
        job.step = nil
    end
    FW._jobs[id] = job
    RemoveFromOrder(id)
    FW._order[#FW._order + 1] = id
    return true
end

local function FinishJob(id, job)
    FW._jobs[id] = nil
    RemoveFromOrder(id)
    if type(job.done) == "function" then
        TryCall("FrameWork.done:" .. id, job.done)
    end
end

local function RunOneStep(job)
    local id = job.id
    if type(job.resume) == "function" then
        local ok, result = TryCall("FrameWork.resume:" .. id, job.resume, job.state)
        if not ok then
            return false
        end
        return result ~= "done"
    end
    local list = job.list
    local index = tonumber(job.index) or 1
    if type(list) ~= "table" or index > #list then
        return false
    end
    if type(job.step) == "function" then
        local ok = TryCall("FrameWork.step:" .. id, job.step, list[index], index)
        if not ok then
            return false
        end
    end
    job.index = index + 1
    return job.index <= #list
end

--- Drain up to frame budget. Returns true if any step ran.
function FW.Pump()
    FW._didWork = false
    local budget = FW.GetFrameBudget()
    local spent = 0
    local guard = 0
    while spent < budget and #(FW._order) > 0 and guard < 64 do
        guard = guard + 1
        local id = FW._order[1]
        local job = FW._jobs[id]
        if type(job) ~= "table" then
            RemoveFromOrder(id)
        else
            local steps = tonumber(job.stepsPerFrame) or 1
            local cost = tonumber(job.cost) or 1
            local n = 0
            local cont = true
            while cont and n < steps and (spent + cost) <= budget do
                cont = RunOneStep(job) == true
                n = n + 1
                spent = spent + cost
                FW._didWork = true
            end
            if cont ~= true then
                FinishJob(id, job)
            else
                -- Round-robin: move to end so other jobs get budget.
                RemoveFromOrder(id)
                if FW._jobs[id] == job then
                    FW._order[#FW._order + 1] = id
                end
            end
        end
    end
    if FW._didWork == true and StockPiler2.Perf and StockPiler2.Perf.Mark then
        StockPiler2.Perf.Mark("FrameWork.Pump")
    end
    return FW._didWork == true
end

--- Convenience: one-shot prewarm that runs fn once on a later Pump (not this caller's frame if already didHeavy).
function FW.StartOnce(id, gen, fn)
    return FW.Start({
        id = id,
        gen = gen,
        stepsPerFrame = 1,
        step = function()
            if type(fn) == "function" then
                fn()
            end
        end,
    })
end
