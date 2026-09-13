----------------------------------------------------------------
-- StockPiler2 BrewTooltip — footer and watch-row tooltip view boundary
----------------------------------------------------------------

StockPiler2.BrewTooltip = StockPiler2.BrewTooltip or {}
local BrewTooltip = StockPiler2.BrewTooltip
local Brew = StockPiler2.Brew

-- Capture the stable builders, then keep Brew forwards for one-release compatibility.
-- Live state intentionally stays on Brew so an open tooltip survives this extraction.
BrewTooltip.RegisterLive = Brew._BrewTooltipRegisterLive
BrewTooltip.RegisterRowLive = Brew._BrewTooltipRegisterRowLive
BrewTooltip.ClearLive = Brew._BrewTooltipClearLive
BrewTooltip.Fingerprint = Brew._BrewTooltipFingerprint
BrewTooltip.Show = Brew._BrewTooltipShow
BrewTooltip.ShowRow = Brew._BrewTooltipShowRow
BrewTooltip.MaybeRefresh = Brew._BrewTooltipMaybeRefresh
BrewTooltip.TickLive = Brew._BrewTooltipTickLive
