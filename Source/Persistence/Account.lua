----------------------------------------------------------------
-- StockPiler2 Persistence/Account — global learned knowledge
----------------------------------------------------------------

StockPiler2.DefaultAccount = {
    -- Client-global knowledge schema version (not a game-account setting).
    accountVersion = 1,
    items = {},
    grows = {},
    refines = {},
    recipes = {},
    potions = {},
    additives = {},
    vendorItems = {},
}

function StockPiler2.Persistence.EnsureAccount()
    local a = StockPiler2.Account
    if type(a) ~= "table" then
        a = StockPiler2.Persistence.CopyTable(StockPiler2.DefaultAccount)
        StockPiler2.Account = a
    end
    if a.accountVersion == nil then
        a.accountVersion = 1
    end
    local keys = { "items", "grows", "refines", "recipes", "potions", "additives", "vendorItems" }
    for i = 1, #keys do
        local k = keys[i]
        if type(a[k]) ~= "table" then
            a[k] = {}
        end
    end
    if StockPiler2.Knowledge and StockPiler2.Knowledge.Ensure then
        StockPiler2.Knowledge.Ensure()
    end
    return a
end
