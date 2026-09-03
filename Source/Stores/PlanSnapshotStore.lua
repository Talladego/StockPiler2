----------------------------------------------------------------
-- StockPiler2 Stores/PlanSnapshotStore — cached planner output
----------------------------------------------------------------

StockPiler2.PlanSnapshot = StockPiler2.PlanSnapshot or {}
local PS = StockPiler2.PlanSnapshot

PS._plan = nil
PS._cacheKey = nil

function PS.Get()
    return PS._plan
end

function PS.Set(plan, cacheKey)
    PS._plan = plan
    PS._cacheKey = cacheKey
end

function PS.GetCacheKey()
    return PS._cacheKey
end

function PS.Invalidate()
    PS._plan = nil
    PS._cacheKey = nil
    local B = StockPiler2.EventBus
    local E = StockPiler2.Events
    if B and E and E.PLAN_INVALIDATED then
        B.Fire(E.PLAN_INVALIDATED, {})
    end
end
