----------------------------------------------------------------
-- StockPiler2 Stores/RefinePipelineStore — in-flight refine ops ledger
----------------------------------------------------------------

StockPiler2.RefinePipeline = StockPiler2.RefinePipeline or {}
local RP = StockPiler2.RefinePipeline

RP._gen = 0
RP._outstanding = {} -- [seedUid] = count

function RP.GetGen()
    return tonumber(RP._gen) or 0
end

function RP.GetOutstanding(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end
    return tonumber(RP._outstanding[seedUid]) or 0
end

function RP.Register(seedUid, plantUid)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 then
        return false
    end
    RP._outstanding[seedUid] = (tonumber(RP._outstanding[seedUid]) or 0) + 1
    RP._gen = (tonumber(RP._gen) or 0) + 1
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("ledger", string.format(
            "register seedUid=%d plantUid=%d outstanding=%d",
            seedUid, plantUid, RP.GetOutstanding(seedUid)
        ))
    end
    return true
end

function RP.Reconcile(seedUid, delivered)
    seedUid = tonumber(seedUid) or 0
    delivered = tonumber(delivered) or 1
    if seedUid <= 0 then
        return false
    end
    local n = (tonumber(RP._outstanding[seedUid]) or 0) - delivered
    if n <= 0 then
        RP._outstanding[seedUid] = nil
    else
        RP._outstanding[seedUid] = n
    end
    RP._gen = (tonumber(RP._gen) or 0) + 1
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("ledger", string.format(
            "reconcile seedUid=%d outstanding=%d",
            seedUid, RP.GetOutstanding(seedUid)
        ))
    end
    return true
end

function RP.Snapshot()
    local out = {}
    for uid, n in pairs(RP._outstanding) do
        out[uid] = n
    end
    return out
end

function RP.HasOutstanding()
    for _, n in pairs(RP._outstanding) do
        if (tonumber(n) or 0) > 0 then
            return true
        end
    end
    return false
end
