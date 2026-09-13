----------------------------------------------------------------
-- StockPiler2 HarvestTooltip — harvest tooltip view boundary
----------------------------------------------------------------

StockPiler2.HarvestTooltip = StockPiler2.HarvestTooltip or {}
local HarvestTooltip = StockPiler2.HarvestTooltip
local Grow = StockPiler2.Grow

-- Capture the stable tooltip implementation built by Grow, then leave compatibility
-- forwards on the domain for one release. Tooltip state remains compatible with
-- saved/runtime references that inspect Grow._liveHarvestTip.
HarvestTooltip.EnsureRows = Grow._HarvestTooltipEnsureRows
HarvestTooltip.GetPlotEntries = Grow._HarvestTooltipGetPlotEntries
HarvestTooltip.ApplyPlotRows = Grow._HarvestTooltipApplyPlotRows
HarvestTooltip.Show = Grow._HarvestTooltipShow
HarvestTooltip.SyncPlotsFromEngine = Grow._HarvestTooltipSyncPlotsFromEngine
HarvestTooltip.RegisterLive = Grow._HarvestTooltipRegisterLive
HarvestTooltip.ClearLive = Grow._HarvestTooltipClearLive
HarvestTooltip.Fingerprint = Grow._HarvestTooltipFingerprint
HarvestTooltip.MaybeRefresh = Grow._HarvestTooltipMaybeRefresh
HarvestTooltip.TickLive = Grow._HarvestTooltipTickLive
