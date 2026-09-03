----------------------------------------------------------------
-- StockPiler2 Knowledge/Shims — v1-compat globals for ported learn code
----------------------------------------------------------------

StockPiler2 = StockPiler2 or {}

StockPiler2.ACCOUNT_TABLE_KEYS = {
    "items", "grows", "refines", "recipes", "potions", "additives", "vendorItems",
}

StockPiler2.CHARACTER_ALIAS_KEYS = {
    "watches",
    "autoGrowEnabled",
    "autoGrowAdditives",
    "autoBuyEnabled",
    "autoBuyReserveGold",
    "autoBuyBudgetGold",
    "growSeedBufferMin",
    "growSeedBufferEnabled",
    "brewMacroEnabled",
    "brewRespectGrowReserve",
}

StockPiler2.ACCOUNT_ALIAS_KEYS = {
    "learnedRecipeSpecs",
    "knownPotions",
}

function StockPiler2.ToNarrow(value)
    if value == nil then
        return ""
    end
    if type(value) == "string" then
        return value
    end
    if type(value) == "wstring" then
        if type(WStringToString) ~= "function" then
            return ""
        end
        local ok, text = StockPiler2.TryCallQuiet("ToNarrow", WStringToString, value)
        if ok and type(text) == "string" then
            return text
        end
        return ""
    end
    return tostring(value)
end

function StockPiler2.TryCallQuiet(context, fn, ...)
    if StockPiler2.Debug and StockPiler2.Debug.TryCallQuiet then
        return StockPiler2.Debug.TryCallQuiet(context, fn, ...)
    end
    return pcall(fn, ...)
end

function StockPiler2.TryCall(context, fn, ...)
    if StockPiler2.Debug and StockPiler2.Debug.TryCall then
        return StockPiler2.Debug.TryCall(context, fn, ...)
    end
    return pcall(fn, ...)
end

function StockPiler2.Trace(msg)
    if StockPiler2.Debug and StockPiler2.Debug.D then
        StockPiler2.Debug.D(msg)
    end
end

function StockPiler2.D(msg)
    StockPiler2.Trace(msg)
end

local function ProfileSettings()
    if StockPiler2.Persistence and StockPiler2.Persistence.EnsureSettings then
        return StockPiler2.Persistence.EnsureSettings()
    end
    return StockPiler2.Settings
end

local function BindCharacterAliases(session, row)
    if type(session) ~= "table" then
        return
    end
    if type(row) ~= "table" then
        session.watches = {}
        session.autoGrowEnabled = false
        session.autoGrowAdditives = false
        session.autoBuyEnabled = false
        session.autoBuyReserveGold = 10
        session.autoBuyBudgetGold = 50
        session.growSeedBufferMin = 5
        session.growSeedBufferEnabled = true
        session.brewMacroEnabled = false
        session.brewRespectGrowReserve = true
        return
    end
    if type(row.watches) ~= "table" then
        row.watches = {}
    end
    session.watches = row.watches
    session.autoGrowEnabled = row.autoGrowEnabled == true
    session.autoGrowAdditives = row.autoGrowAdditives == true
    session.autoBuyEnabled = row.autoBuyEnabled == true
    session.autoBuyReserveGold = tonumber(row.autoBuyReserveGold) or 10
    session.autoBuyBudgetGold = tonumber(row.autoBuyBudgetGold) or 50
    session.growSeedBufferMin = tonumber(row.growSeedBufferMin) or 5
    session.growSeedBufferEnabled = row.growSeedBufferEnabled ~= false
    session.brewMacroEnabled = row.brewMacroEnabled ~= false
    session.brewRespectGrowReserve = row.brewRespectGrowReserve ~= false
end

local function BuildSessionSettings()
    local acct = StockPiler2.Persistence and StockPiler2.Persistence.EnsureAccount()
    if type(acct) ~= "table" then
        return {}
    end
    local profile = ProfileSettings()
    local session = StockPiler2._sessionSettings
    if type(session) ~= "table" then
        session = {}
        StockPiler2._sessionSettings = session
    end
    for i = 1, #StockPiler2.ACCOUNT_TABLE_KEYS do
        local key = StockPiler2.ACCOUNT_TABLE_KEYS[i]
        session[key] = acct[key]
    end
    session.learnedRecipeSpecs = acct.recipes
    session.knownPotions = acct.potions
    session.accountVersion = acct.accountVersion
    if type(profile) == "table" then
        session.characters = profile.characters
    end
    local row = StockPiler2.Watch and StockPiler2.Watch.CharacterRow and StockPiler2.Watch.CharacterRow()
    BindCharacterAliases(session, row)
    return session
end

--- RecipeSpec/SeedMap expect EnsureSettings() to return knowledge + character aliases.
--- Session table only — never write aliases onto StockPiler2.Account.
function StockPiler2.EnsureSettings()
    return BuildSessionSettings()
end

function StockPiler2.ClearAccountTable(name)
    if StockPiler2.Knowledge and StockPiler2.Knowledge.GetTable then
        local tbl = StockPiler2.Knowledge.GetTable(name)
        if type(tbl) == "table" then
            for k in pairs(tbl) do
                tbl[k] = nil
            end
            return tbl
        end
    end
    return {}
end

function StockPiler2.BindAccountIntoSettings(s)
    local acct = StockPiler2.Persistence and StockPiler2.Persistence.EnsureAccount()
    if type(s) ~= "table" or type(acct) ~= "table" then
        return
    end
    for i = 1, #StockPiler2.ACCOUNT_TABLE_KEYS do
        local key = StockPiler2.ACCOUNT_TABLE_KEYS[i]
        s[key] = acct[key]
    end
    s.learnedRecipeSpecs = acct.recipes
    s.knownPotions = acct.potions
end

--- Remove keys that must never persist on client-global Account.
function StockPiler2.StripLeakedKeysFromAccount(acct)
    if type(acct) ~= "table" then
        return
    end
    for i = 1, #StockPiler2.ACCOUNT_ALIAS_KEYS do
        acct[StockPiler2.ACCOUNT_ALIAS_KEYS[i]] = nil
    end
    for i = 1, #StockPiler2.CHARACTER_ALIAS_KEYS do
        acct[StockPiler2.CHARACTER_ALIAS_KEYS[i]] = nil
    end
end

function StockPiler2.ProfileSettings()
    return ProfileSettings()
end
