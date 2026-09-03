----------------------------------------------------------------
-- StockPiler2 Persistence/Character — shared-profile character buckets
-- Per-character prefs live in Settings.characters[characterName].
----------------------------------------------------------------

StockPiler2.Persistence = StockPiler2.Persistence or {}

local function ClampInt(n, lo, hi, default)
    n = tonumber(n)
    if n == nil then
        return default
    end
    n = math.floor(n)
    if n < lo then
        return lo
    end
    if n > hi then
        return hi
    end
    return n
end

function StockPiler2.Persistence.ToNarrow(value)
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
        local ok, text
        if StockPiler2.Debug and StockPiler2.Debug.TryCallQuiet then
            ok, text = StockPiler2.Debug.TryCallQuiet("ToNarrow", WStringToString, value)
        else
            ok, text = pcall(WStringToString, value)
        end
        if ok and type(text) == "string" then
            return text
        end
        return ""
    end
    return tostring(value)
end

function StockPiler2.Persistence.GetCharacterKey()
    if GameData and GameData.Player and GameData.Player.name then
        local name = GameData.Player.name
        if type(name) == "wstring" then
            local narrow = StockPiler2.Persistence.ToNarrow(name)
            if type(narrow) == "string" and narrow ~= "" then
                if string.len(narrow) >= 2 and string.sub(narrow, -2, -2) == "^" then
                    narrow = string.sub(narrow, 1, -3)
                end
                narrow = string.gsub(narrow, "^%s+", "")
                narrow = string.gsub(narrow, "%s+$", "")
                if narrow ~= "" then
                    return narrow
                end
            end
        end
    end
    return "_default"
end

function StockPiler2.Persistence.EnsureCharacterBucketShape(char)
    if type(char) ~= "table" then
        char = {}
    end
    local defaults = StockPiler2.DefaultCharacterSettings
    if type(defaults) ~= "table" then
        return char
    end
    for k, v in pairs(defaults) do
        if char[k] == nil then
            if type(v) == "table" then
                char[k] = {}
            else
                char[k] = v
            end
        end
    end
    if type(char.watches) ~= "table" then
        char.watches = {}
    end
    char.autoGrowEnabled = char.autoGrowEnabled == true
    char.autoGrowAdditives = char.autoGrowAdditives == true
    char.autoBuyEnabled = char.autoBuyEnabled == true
    char.brewMacroEnabled = char.brewMacroEnabled ~= false
    char.brewRespectGrowReserve = char.brewRespectGrowReserve ~= false
    char.autoBuyReserveGold = ClampInt(char.autoBuyReserveGold, 1, 99, 10)
    char.autoBuyBudgetGold = ClampInt(char.autoBuyBudgetGold, 1, 999, 50)
    char.growSeedBufferMin = ClampInt(char.growSeedBufferMin, 4, 20, 5)
    char.growSeedBufferEnabled = char.growSeedBufferEnabled ~= false
    return char
end

function StockPiler2.Persistence.GetCharacterBucket(create)
    local settings = StockPiler2.Persistence.EnsureSettings()
    settings.characters = type(settings.characters) == "table" and settings.characters or {}
    local key = StockPiler2.Persistence.GetCharacterKey()
    local row = settings.characters[key]
    if type(row) ~= "table" then
        if create == false then
            return nil, key
        end
        row = StockPiler2.Persistence.CopyTable(StockPiler2.DefaultCharacterSettings)
        settings.characters[key] = row
    end
    return StockPiler2.Persistence.EnsureCharacterBucketShape(row), key
end
