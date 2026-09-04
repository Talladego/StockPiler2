----------------------------------------------------------------
-- Classify potions by effect (PotionBar-compatible).
-- Prefer PotionBar.getValues when that addon is loaded; otherwise mirror
-- PotionBar's English ability-description rules, plus liniment hybrids.
----------------------------------------------------------------

StockPiler2.Classify = StockPiler2.Classify or {}
local Classify = StockPiler2.Classify

-- StockPiler2 effectKey <-> PotionBar.Type.Name
local EFFECT_TO_PB = {
    str = "STRENGTH",
    int = "INTELLIGENCE",
    wp = "WILLPOWER",
    bs = "BALLISTIC",
    tou = "TOUGHNESS",
    armor = "ARMOR",
    absorb = "SHIELD",
    heal = "HEAL",
    hot = "REGEN",
    ap = "AP",
    -- Liniment / hybrid PotionBar types (Data.lua 21–38).
    hywoucrit = "WARBLOOD",
    hywoumelee = "WARDEMISE",
    hywourcrit = "WARFERVOR",
    hywoumcrit = "WARGENIUS",
    hywoustr = "WARHUNGER",
    hywouheal = "WARMERCY",
    hywouinit = "BOUNDLESSSIGHT",
    hyhpregencritdmg = "IMMUTABLEDEFIANCE",
    hyresist = "INEXORABLEAEGIS",
    hywillheal = "INSPIRATIONALWINDS",
    hytounocrit = "PEERLESSDEFENSE",
    hywsarmpen = "QUICKENEDBLADES",
    hytoucrit = "SAVAGEVIGOR",
    hywsnocrit = "SWIFTTERGIVERSATION",
    hyaccrcrit = "ETERNALHUNT",
    hystrmelee = "INEVITABLETEMPEST",
    hyintmcrit = "TOLLINGBELL",
    hystrheal = "UNFETTEREDZEAL",
}

local PB_TO_EFFECT = {}
for effectKey, pbName in pairs(EFFECT_TO_PB) do
    PB_TO_EFFECT[pbName] = effectKey
end

local function ToNarrow(name)
    if StockPiler2.ToNarrow then
        return StockPiler2.ToNarrow(name)
    end
    if type(name) == "wstring" then
        return WStringToString(name) or ""
    end
    return tostring(name or "")
end

local function TryQuiet(label, fn, ...)
    if StockPiler2.TryCallQuiet then
        return StockPiler2.TryCallQuiet(label, fn, ...)
    end
    return pcall(fn, ...)
end

local function GetNumbers(aString, count)
    if not count or type(aString) ~= "string" then
        return
    end
    local y = 0
    local results = {}
    for i = 1, count do
        if i > 1 then
            y = y + 1
        end
        local x
        x, y = string.find(aString, "%d+", y)
        if not x then
            return
        end
        results[i] = tonumber(string.sub(aString, x, y))
    end
    return unpack(results)
end

--- Local EN classifier (PotionBar-style + liniment / hybrid wounds+crit).
local function ClassifyFromDescription(name, description)
    if type(description) ~= "string" or description == "" then
        return nil
    end
    name = name or ""
    local descLower = string.lower(description)

    -- Hybrid liniments / oils: Wounds + crit family (before simple Increases patterns).
    if string.find(descLower, "wounds", 1, true) then
        if string.find(descLower, "ranged", 1, true)
            and (string.find(descLower, "crit", 1, true)
                or string.find(descLower, "critical", 1, true))
        then
            return "hywourcrit"
        end
        if string.find(descLower, "magic", 1, true)
            and (string.find(descLower, "crit", 1, true)
                or string.find(descLower, "critical", 1, true))
        then
            return "hywoumcrit"
        end
        if (string.find(descLower, "melee", 1, true)
                or string.find(descLower, "weapon", 1, true))
            and (string.find(descLower, "crit", 1, true)
                or string.find(descLower, "critical", 1, true))
        then
            return "hywoucrit"
        end
        if string.find(descLower, "initiative", 1, true) then
            return "hywouinit"
        end
        if string.find(descLower, "healing", 1, true)
            or string.find(descLower, "heal", 1, true)
        then
            return "hywouheal"
        end
        if string.find(descLower, "strength", 1, true) then
            return "hywoustr"
        end
        if string.find(descLower, "armor pen", 1, true)
            or string.find(descLower, "armour pen", 1, true)
        then
            return "hywouarmpen"
        end
        if string.find(descLower, "melee power", 1, true)
            or string.find(descLower, "melee", 1, true)
        then
            return "hywoumelee"
        end
    end
    if string.find(descLower, "ballistic", 1, true)
        and string.find(descLower, "ranged", 1, true)
        and (string.find(descLower, "crit", 1, true)
            or string.find(descLower, "critical", 1, true))
    then
        return "hyaccrcrit"
    end
    if string.find(descLower, "weapon skill", 1, true)
        or string.find(descLower, "weaponskill", 1, true)
    then
        if string.find(descLower, "armor pen", 1, true)
            or string.find(descLower, "armour pen", 1, true)
        then
            return "hywsarmpen"
        end
        if string.find(descLower, "crit", 1, true)
            or string.find(descLower, "critical", 1, true)
        then
            return "hywsnocrit"
        end
    end
    if string.find(descLower, "toughness", 1, true)
        and (string.find(descLower, "crit", 1, true)
            or string.find(descLower, "critical", 1, true))
    then
        if string.find(descLower, "chance", 1, true)
            or string.find(descLower, "reduced", 1, true)
        then
            return "hytounocrit"
        end
        return "hytoucrit"
    end
    if (string.find(descLower, "health regen", 1, true)
            or string.find(descLower, "healthregen", 1, true)
            or string.find(descLower, "regenerat", 1, true))
        and (string.find(descLower, "crit", 1, true)
            or string.find(descLower, "critical", 1, true))
    then
        return "hyhpregencritdmg"
    end
    if string.find(descLower, "resist", 1, true)
        and not string.find(descLower, "crit", 1, true)
    then
        return "hyresist"
    end

    if string.find(description, "Instantly restores %d+") then
        if string.find(description, "Action Points") then
            return "ap"
        end
        if string.find(description, "health") then
            return "heal"
        end
    end
    if string.find(description, "Heals for %d+ every %d+ seconds, for %d+ seconds.")
        or string.find(description, "Gradually restores %d+ health over %d+ seconds.")
    then
        return "hot"
    end
    if string.find(description, "Absorbs %d+ damage over the next %d+ seconds.")
        or string.find(description, "Surrounds you with a magical barrier for up to %d+ seconds which will absorb up to %d+ damage.")
    then
        return "absorb"
    end
    if string.find(description, "Increases [%a%s]+ by %d+ for %d+ minutes.") then
        if string.find(description, "Strength") then
            return "str"
        end
        if string.find(description, "Intelligence") then
            return "int"
        end
        if string.find(description, "Ballistic Skill") then
            return "bs"
        end
        if string.find(description, "Willpower") then
            return "wp"
        end
        if string.find(description, "Toughness") then
            return "tou"
        end
        if string.find(description, "Armor") then
            return "armor"
        end
    end
    return nil
end

--- Name fallback when ability text is empty (liniment titles).
local function ClassifyFromPotionName(name)
    local n = string.lower(ToNarrow(name))
    if n == "" then
        return nil
    end
    if string.find(n, "tergiversation", 1, true) then
        return "hywsnocrit"
    end
    if string.find(n, "immutable defiance", 1, true) then
        return "hyhpregencritdmg"
    end
    if string.find(n, "peerless defense", 1, true) then
        return "hytounocrit"
    end
    if string.find(n, "quickened blades", 1, true) then
        return "hywsarmpen"
    end
    if string.find(n, "inexorable aegis", 1, true) then
        return "hyresist"
    end
    if string.find(n, "war: hunger", 1, true) or string.find(n, "war hunger", 1, true) then
        return "hywoustr"
    end
    if string.find(n, "war: mercy", 1, true) or string.find(n, "war mercy", 1, true) then
        return "hywouheal"
    end
    if string.find(n, "blood archer", 1, true) or string.find(n, "war fervor", 1, true) then
        return "hywourcrit"
    end
    if string.find(n, "boundless sight", 1, true) then
        return "hywouinit"
    end
    if string.find(n, "eternal hunt", 1, true) then
        return "hyaccrcrit"
    end
    if string.find(n, "savage vigor", 1, true) then
        return "hytoucrit"
    end
    if string.find(n, "inspirational winds", 1, true) then
        return "hywillheal"
    end
    if string.find(n, "inevitable tempest", 1, true) then
        return "hystrmelee"
    end
    if string.find(n, "tolling bell", 1, true) then
        return "hyintmcrit"
    end
    if string.find(n, "unfettered zeal", 1, true) then
        return "hystrheal"
    end
    if string.find(n, "war: blood", 1, true) or string.find(n, "war blood", 1, true) then
        return "hywoucrit"
    end
    if string.find(n, "war: demise", 1, true) or string.find(n, "war demise", 1, true) then
        return "hywoumelee"
    end
    if string.find(n, "war: genius", 1, true) or string.find(n, "war genius", 1, true) then
        return "hywoumcrit"
    end
    return nil
end

local function AbilityIdFromItem(itemData)
    if type(itemData) ~= "table" or type(itemData.bonus) ~= "table" then
        return nil
    end
    local b1 = itemData.bonus[1]
    if type(b1) == "table" and b1.reference then
        return b1.reference
    end
    for _, bonusData in ipairs(itemData.bonus) do
        if type(bonusData) == "table" and bonusData.reference then
            if GameDefs and GameDefs.ITEMBONUS_USE and bonusData.type == GameDefs.ITEMBONUS_USE then
                return bonusData.reference
            end
            if bonusData.type == 3 then
                return bonusData.reference
            end
        end
    end
    return nil
end

function Classify.IsPotionItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if GameData and GameData.ItemTypes and GameData.ItemTypes.POTION then
        local t = itemData.type or itemData.itemType
        return t == GameData.ItemTypes.POTION
    end
    local n = string.lower(ToNarrow(itemData.name))
    return string.find(n, "potion", 1, true)
        or string.find(n, "draught", 1, true)
        or string.find(n, "elixir", 1, true)
        or string.find(n, "unguent", 1, true)
        or string.find(n, "liniment", 1, true)
        or string.find(n, "liquid", 1, true)
end

--- Returns StockPiler2 effectKey (str/int/hywourcrit/...) or nil.
function Classify.GetEffectKey(itemData)
    if type(itemData) ~= "table" then
        return nil
    end

    if PotionBar and type(PotionBar.getValues) == "function" then
        local abilityId = AbilityIdFromItem(itemData)
        if abilityId then
            local ok, _value, _dur, pbType = TryQuiet(
                "PotionBar.getValues", PotionBar.getValues,
                abilityId,
                itemData.iLevel or itemData.level or 1,
                itemData.name,
                itemData.uniqueID
            )
            if ok and pbType and pbType ~= 0 then
                local pbName = nil
                if PotionBar.Type and type(PotionBar.Type[pbType]) == "table" then
                    pbName = PotionBar.Type[pbType].Name
                end
                if pbName and PB_TO_EFFECT[pbName] then
                    return PB_TO_EFFECT[pbName]
                end
            end
        end
    end

    local abilityId = AbilityIdFromItem(itemData)
    local description = ""
    if abilityId and type(GetAbilityDescription) == "function" then
        local ok, desc = TryQuiet(
            "GetAbilityDescription",
            GetAbilityDescription,
            abilityId,
            itemData.iLevel or itemData.level or 1
        )
        if ok and desc then
            description = ToNarrow(desc)
        end
    end
    if description == "" and itemData.description then
        description = ToNarrow(itemData.description)
    end

    return ClassifyFromDescription(ToNarrow(itemData.name), description)
        or ClassifyFromPotionName(itemData.name)
end

local function ParseStatsFromDescription(description)
    if type(description) ~= "string" or description == "" then
        return 0, 0, false
    end
    local value, duration = 0, 0

    if string.find(description, "Instantly restores %d+") then
        value = GetNumbers(description, 1) or 0
        return value, 0, true
    end
    if string.find(description, "Heals for %d+ every %d+ seconds, for %d+ seconds.") then
        local tick, interval, total = GetNumbers(description, 3)
        if tick and interval and total and interval > 0 then
            value = tick * (total / interval)
            duration = total
        end
        return value or 0, duration, false
    end
    if string.find(description, "Gradually restores %d+ health over %d+ seconds.") then
        value, duration = GetNumbers(description, 2)
        return value or 0, duration or 0, false
    end
    if string.find(description, "Absorbs %d+ damage over the next %d+ seconds.") then
        value, duration = GetNumbers(description, 2)
        return value or 0, duration or 0, false
    end
    if string.find(description, "Surrounds you with a magical barrier for up to %d+ seconds which will absorb up to %d+ damage.") then
        duration, value = GetNumbers(description, 2)
        return value or 0, duration or 0, false
    end
    if string.find(description, "Increases [%a%s]+ by %d+ for %d+ minutes.") then
        value, duration = GetNumbers(description, 2)
        if duration then
            duration = duration * 60
        end
        return value or 0, duration or 0, false
    end
    -- Hybrid liniment-style: "Increases Wounds by N and ... for M Minutes"
    local w = string.match(description, "[Ii]ncreases%s+Wounds%s+by%s+(%d+)")
    local mins = string.match(description, "for%s+(%d+)%s+[Mm]inutes")
    if w then
        return tonumber(w) or 0, (tonumber(mins) or 0) * 60, false
    end
    return 0, 0, false
end

function Classify.GetPotionStats(itemData, _catalogEntry)
    if type(itemData) ~= "table" then
        return 0, 0, 0, false
    end

    local minRank = tonumber(itemData.iLevel) or 0
    if minRank <= 0 then
        minRank = tonumber(itemData.level) or 0
    end

    local abilityId = AbilityIdFromItem(itemData)
    local level = itemData.iLevel or itemData.level or 1
    if level <= 0 then
        level = 1
    end
    local name = itemData.name
    local uniqueID = itemData.uniqueID

    if PotionBar and type(PotionBar.getValues) == "function" and abilityId then
        local ok, potionV, potionD = TryQuiet(
            "PotionBar.getValues", PotionBar.getValues,
            abilityId,
            level,
            name,
            uniqueID
        )
        if ok then
            local buffValue = tonumber(potionV) or 0
            local durationSec = tonumber(potionD) or 0
            local description = ""
            if type(GetAbilityDescription) == "function" then
                local descOk, desc = TryQuiet("GetAbilityDescription", GetAbilityDescription, abilityId, level)
                if descOk and desc then
                    description = ToNarrow(desc)
                end
            end
            local instant = string.find(description, "Instantly restores", 1, true) ~= nil
            return minRank, buffValue, durationSec, instant
        end
    end

    local description = ""
    if abilityId and type(GetAbilityDescription) == "function" then
        local ok, desc = TryQuiet("GetAbilityDescription", GetAbilityDescription, abilityId, level)
        if ok and desc then
            description = ToNarrow(desc)
        end
    end
    if description == "" and itemData.description then
        description = ToNarrow(itemData.description)
    end

    local buffValue, durationSec, instant = ParseStatsFromDescription(description)
    return minRank, buffValue, durationSec, instant
end

function Classify.FormatDuration(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        return L""
    end
    if seconds >= 60 and seconds % 60 == 0 then
        return towstring(tostring(seconds / 60)) .. L"m"
    end
    return towstring(tostring(seconds)) .. L"s"
end

function Classify.EffectKeyToPotionBarName(effectKey)
    return EFFECT_TO_PB[effectKey]
end

function Classify.PotionBarAvailable()
    return PotionBar ~= nil and type(PotionBar.getValues) == "function"
end
