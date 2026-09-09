----------------------------------------------------------------
-- StockPiler2 Persistence — settings + helpers
----------------------------------------------------------------

StockPiler2.Persistence = StockPiler2.Persistence or {}

function StockPiler2.Persistence.CopyTable(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = StockPiler2.Persistence.CopyTable(v)
    end
    return copy
end

StockPiler2.DefaultSettings = {
    settingsVersion = 1,
    charactersVersion = 1,
    characters = {},
    debugEnabled = false,
    eventTrace = false,
    language = 0,
    selectedTab = 1,
    potionNameFilter = "",
    potionEffectFilter = "",
    potionKnownRecipeOnly = false,
    potionSortColumn = "name",
    potionSortAscending = true,
}

StockPiler2.DefaultCharacterSettings = {
    watches = {},
    autoGrowEnabled = false,
    autoGrowAdditives = false,
    autoBuyEnabled = false,
    autoBuyReserveGold = 10,
    autoBuyBudgetGold = 50,
    growSeedBufferMin = 5,
    growSeedBufferEnabled = true,
    brewMacroEnabled = false,
    brewRespectGrowReserve = true,
}

function StockPiler2.Persistence.EnsureSettings()
    local s = StockPiler2.Settings
    if type(s) ~= "table" then
        s = StockPiler2.Persistence.CopyTable(StockPiler2.DefaultSettings)
        StockPiler2.Settings = s
    end
    if s.settingsVersion == nil then
        s.settingsVersion = 1
    end
    if s.characters == nil then
        s.characters = {}
    end
    if s.potionNameFilter == nil then
        s.potionNameFilter = ""
    end
    if s.potionEffectFilter == nil then
        s.potionEffectFilter = ""
    end
    if s.potionSortColumn == nil then
        s.potionSortColumn = "name"
    end
    if s.potionSortAscending == nil then
        s.potionSortAscending = true
    end
    if s.selectedTab == nil then
        s.selectedTab = 1
    end
    if s.language == nil then
        s.language = 0
    end
    StockPiler2.Debug.Enabled = s.debugEnabled == true
    StockPiler2.Debug.EventTrace = s.eventTrace == true
    return s
end
