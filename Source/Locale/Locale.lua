----------------------------------------------------------------
-- StockPiler2 Locale - keyed phrases + named tokens (mojibake-safe)
-- Catalog templates must be L"..." wstrings with ASCII punctuation for chat.
-- See docs/api/lua-chat-strings.md (RoR-Interface) and README Localization.
----------------------------------------------------------------

StockPiler2 = StockPiler2 or {}
StockPiler2.Locale = StockPiler2.Locale or {}

local Locale = StockPiler2.Locale
Locale.Packs = Locale.Packs or {}
Locale._langId = nil
Locale._pack = nil

local function EnglishLangId()
    if SystemData and SystemData.Settings and SystemData.Settings.Language
        and SystemData.Settings.Language.ENGLISH ~= nil
    then
        return SystemData.Settings.Language.ENGLISH
    end
    return 1
end

local function ActiveGameLangId()
    if SystemData and SystemData.Settings and SystemData.Settings.Language
        and SystemData.Settings.Language.active ~= nil
    then
        return SystemData.Settings.Language.active
    end
    return EnglishLangId()
end

local function EnglishPack()
    return Locale.Packs[EnglishLangId()]
end

local function CoerceWString(val)
    if val == nil then
        return L""
    end
    if type(val) == "wstring" then
        return val
    end
    if type(val) == "string" then
        -- Narrow strings must stay ASCII when used as tokens in chat paths.
        return towstring(val)
    end
    return towstring(tostring(val))
end

local function ApplyTokens(template, tokens)
    if type(template) ~= "wstring" then
        template = CoerceWString(template)
    end
    if type(tokens) ~= "table" then
        return template
    end
    local out = template
    for name, value in pairs(tokens) do
        local key = tostring(name or "")
        if key ~= "" then
            local needle = L"{" .. towstring(key) .. L"}"
            out = wstring.gsub(out, needle, CoerceWString(value))
        end
    end
    return out
end

function Locale.GetLanguage()
    return Locale._langId or EnglishLangId()
end

--- id: SystemData.Settings.Language.* or 0/nil for game language (auto).
function Locale.SetLanguage(id)
    id = tonumber(id) or 0
    if id <= 0 then
        id = ActiveGameLangId()
    end
    local pack = Locale.Packs[id]
    if type(pack) ~= "table" then
        pack = EnglishPack()
        id = EnglishLangId()
    end
    Locale._langId = id
    Locale._pack = pack
    return id
end

function Locale.ResolveTemplate(key)
    key = tostring(key or "")
    if key == "" then
        return nil
    end
    local pack = Locale._pack
    if type(pack) ~= "table" then
        Locale.SetLanguage(0)
        pack = Locale._pack
    end
    if type(pack) == "table" and type(pack[key]) == "wstring" then
        return pack[key]
    end
    local en = EnglishPack()
    if type(en) == "table" and type(en[key]) == "wstring" then
        return en[key]
    end
    return nil
end

--- Format a catalog key with optional named tokens. Always returns wstring.
function Locale.Format(key, tokens)
    local template = Locale.ResolveTemplate(key)
    if template == nil then
        return L"[" .. CoerceWString(key) .. L"]"
    end
    return ApplyTokens(template, tokens)
end

--- Public shorthand used by call sites.
function StockPiler2.T(key, tokens)
    return Locale.Format(key, tokens)
end

function Locale.Initialize()
    local lang = 0
    if StockPiler2.Persistence and StockPiler2.Persistence.EnsureSettings then
        local s = StockPiler2.Persistence.EnsureSettings()
        if type(s) == "table" then
            if s.language == nil then
                s.language = 0
            end
            lang = tonumber(s.language) or 0
        end
    end
    Locale.SetLanguage(lang)
end
