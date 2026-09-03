----------------------------------------------------------------
-- StockPiler2 Stores/KnowledgeStore — account learned data (read/write facade)
-- All persisted learned knowledge must go through this module into StockPiler2.Account.
----------------------------------------------------------------

StockPiler2.Knowledge = StockPiler2.Knowledge or {}

local ACCOUNT_TABLES = { "items", "grows", "refines", "recipes", "potions", "additives", "vendorItems" }

function StockPiler2.Knowledge.GetGen()
    return tonumber(StockPiler2.Knowledge._gen) or 0
end

function StockPiler2.Knowledge.Ensure()
    local acct = StockPiler2.Account
    if type(acct) ~= "table" then
        return false
    end
    for i = 1, #ACCOUNT_TABLES do
        local k = ACCOUNT_TABLES[i]
        if type(acct[k]) ~= "table" then
            acct[k] = {}
        end
    end
    return true
end

function StockPiler2.Knowledge.GetAccount()
    if StockPiler2.Persistence and StockPiler2.Persistence.EnsureAccount then
        return StockPiler2.Persistence.EnsureAccount()
    end
    if StockPiler2.Knowledge.Ensure() then
        return StockPiler2.Account
    end
    return nil
end

function StockPiler2.Knowledge.GetTable(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local allowed = false
    for i = 1, #ACCOUNT_TABLES do
        if ACCOUNT_TABLES[i] == name then
            allowed = true
            break
        end
    end
    if not allowed then
        return nil
    end
    local acct = StockPiler2.Knowledge.GetAccount()
    if type(acct) ~= "table" then
        return nil
    end
    if type(acct[name]) ~= "table" then
        acct[name] = {}
    end
    return acct[name]
end

function StockPiler2.Knowledge.BumpGen()
    StockPiler2.Knowledge._gen = (tonumber(StockPiler2.Knowledge._gen) or 0) + 1
end

function StockPiler2.Knowledge.Touch()
    StockPiler2.Knowledge.BumpGen()
    local B = StockPiler2.EventBus
    local E = StockPiler2.Events
    if B and E and E.KNOWLEDGE_UPDATED then
        B.Fire(E.KNOWLEDGE_UPDATED, { gen = StockPiler2.Knowledge.GetGen() })
    end
end
