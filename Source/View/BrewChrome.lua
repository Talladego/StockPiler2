----------------------------------------------------------------
-- StockPiler2 BrewChrome — brew footer and watch-row paint requests
----------------------------------------------------------------

StockPiler2.BrewChrome = StockPiler2.BrewChrome or {}
local BrewChrome = StockPiler2.BrewChrome

function BrewChrome.RefreshBrewUi()
    local Brew = StockPiler2.Brew
    -- Session teardown owns the suppression flag; this module only requests chrome paint.
    if Brew._suppressBrewUi == true then
        return
    end
    Brew.InvalidateCanBrewCache()
    if StockPiler2.Perf and StockPiler2.Perf.Begin then
        StockPiler2.Perf.Begin("BrewUi")
    end
    if StockPiler2Window and StockPiler2Window.RequestFooterRefresh then
        StockPiler2Window.RequestFooterRefresh()
    elseif StockPiler2Window and StockPiler2Window.RefreshFooterButtons then
        StockPiler2Window.RefreshFooterButtons()
    end
    if StockPiler2TabWatch and StockPiler2TabWatch.InvalidateBrewChrome then
        StockPiler2TabWatch.InvalidateBrewChrome()
    end
    if StockPiler2.Ui and StockPiler2.Ui.MarkWatchUiDirty then
        StockPiler2.Ui.MarkWatchUiDirty()
    end
    if StockPiler2Window and StockPiler2Window.RequestListRepopulate then
        StockPiler2Window.RequestListRepopulate()
    end
    if StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("BrewUi")
    end
end
