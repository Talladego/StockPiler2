----------------------------------------------------------------
-- StockPiler2 Adapters/TradeSkillCaps — player trade-skill levels
----------------------------------------------------------------

StockPiler2.TradeSkillCaps = StockPiler2.TradeSkillCaps or {}
local Caps = StockPiler2.TradeSkillCaps

local function SkillId(name, fallback)
    if GameData and GameData.TradeSkills and GameData.TradeSkills[name] then
        return GameData.TradeSkills[name]
    end
    return fallback
end

function Caps.ButcheringId()
    return SkillId("BUTCHERING", 1)
end

function Caps.ScavengingId()
    return SkillId("SCAVENGING", 2)
end

function Caps.CultivationId()
    return SkillId("CULTIVATION", 3)
end

function Caps.ApothecaryId()
    return SkillId("APOTHECARY", 4)
end

function Caps.TalismanId()
    return SkillId("TALISMAN", 5)
end

function Caps.SalvagingId()
    return SkillId("SALVAGING", 6)
end

--- Numeric level for a trade skill id (0 if untrained / unknown).
function Caps.Level(skillId)
    skillId = tonumber(skillId) or 0
    if skillId <= 0 then
        return 0
    end
    if GameData and GameData.Player and type(GameData.Player.tradeSkills) == "table" then
        local row = GameData.Player.tradeSkills[skillId]
        if type(row) == "table" then
            return tonumber(row.level) or 0
        end
        if row ~= nil then
            return tonumber(row) or 0
        end
    end
    if GameData and type(GameData.TradeSkillLevels) == "table" then
        return tonumber(GameData.TradeSkillLevels[skillId]) or 0
    end
    return 0
end

function Caps.HasCultivation()
    return Caps.Level(Caps.CultivationId()) > 0
end

function Caps.HasApothecary()
    return Caps.Level(Caps.ApothecaryId()) > 0
end

function Caps.HasTalisman()
    return Caps.Level(Caps.TalismanId()) > 0
end

function Caps.HasButchering()
    return Caps.Level(Caps.ButcheringId()) > 0
end

function Caps.HasScavenging()
    return Caps.Level(Caps.ScavengingId()) > 0
end

function Caps.HasSalvaging()
    return Caps.Level(Caps.SalvagingId()) > 0
end

function Caps.CanAutoGrow()
    return Caps.HasCultivation()
end

function Caps.CanBrewPotions()
    return Caps.HasApothecary()
end

--- Potion-pipeline craft mats: Cultivation or Apothecary tradeSkill only.
function Caps.IsPotionCraftTradeSkill(tradeSkillId)
    tradeSkillId = tonumber(tradeSkillId) or 0
    if tradeSkillId <= 0 then
        return false
    end
    return tradeSkillId == Caps.CultivationId() or tradeSkillId == Caps.ApothecaryId()
end

--- AutoBuy master switch: character can buy cult and/or apo craft mats.
function Caps.CanAutoBuy()
    return Caps.HasCultivation() or Caps.HasApothecary()
end

--- Whether this character may AutoBuy an item with the given tradeSkill id.
function Caps.CanBuyTradeSkill(tradeSkillId)
    tradeSkillId = tonumber(tradeSkillId) or 0
    if tradeSkillId <= 0 then
        return false
    end
    if tradeSkillId == Caps.CultivationId() then
        return Caps.HasCultivation()
    end
    if tradeSkillId == Caps.ApothecaryId() then
        return Caps.HasApothecary()
    end
    return false
end

--- Non-cultivation gathering label for tooltips, or nil.
function Caps.GatheringLabel()
    if Caps.HasCultivation() then
        return L"Cultivation"
    end
    if Caps.HasButchering() then
        return L"Butchering"
    end
    if Caps.HasScavenging() then
        return L"Scavenging"
    end
    if Caps.HasSalvaging() then
        return L"Salvaging"
    end
    return nil
end

--- Compact hash so Planner cache invalidates when skills change.
function Caps.LevelsHash()
    return table.concat({
        tostring(Caps.Level(Caps.ButcheringId())),
        tostring(Caps.Level(Caps.ScavengingId())),
        tostring(Caps.Level(Caps.CultivationId())),
        tostring(Caps.Level(Caps.ApothecaryId())),
        tostring(Caps.Level(Caps.TalismanId())),
        tostring(Caps.Level(Caps.SalvagingId())),
    }, ":")
end
