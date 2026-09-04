----------------------------------------------------------------
-- StockPiler2 Knowledge/LearnBridge — hooks + event wiring for learning
----------------------------------------------------------------

StockPiler2.LearnBridge = StockPiler2.LearnBridge or {}
local LB = StockPiler2.LearnBridge

LB._prevPlotStages = {}
LB._apothecaryHooked = false
LB._useItemRefineHooked = false

local function StageGrown()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.GROWN or 4
    end
    return 4
end

local function StageEmpty()
    if GameData and GameData.CultivationStage then
        return GameData.CultivationStage.EMPTY or 0
    end
    return 0
end

local function RefreshUiIfLearned()
    -- Coalesced UI dirty — never force a sync RefreshActiveTab mid-UPDATE_PROCESSED.
    if StockPiler2.Ui and StockPiler2.Ui.MarkWatchUiDirty then
        StockPiler2.Ui.MarkWatchUiDirty()
    elseif StockPiler2.Ui and StockPiler2.Ui.RefreshIfOpen then
        StockPiler2.Ui.RefreshIfOpen()
    end
end

function StockPiler2.EnsureApothecaryHook()
    return LB.EnsureApothecaryHook()
end

function LB.EnsureApothecaryHook()
    if type(ApothecaryWindow) ~= "table" then
        return false
    end
    if LB._apothecaryHooked == true or ApothecaryWindow._StockPiler2Hooked == true then
        LB._apothecaryHooked = true
        return true
    end
    local origPerform = ApothecaryWindow.Perform
    if type(origPerform) == "function" then
        ApothecaryWindow.Perform = function()
            if StockPiler2.BrewLearn and StockPiler2.BrewLearn.BeginPendingCraft then
                StockPiler2.TryCall("StockPiler2.BrewLearn.BeginPendingCraft", StockPiler2.BrewLearn.BeginPendingCraft)
            end
            origPerform()
        end
    end
    local origHide = ApothecaryWindow.Hide
    if type(origHide) == "function" then
        ApothecaryWindow.Hide = function(...)
            if StockPiler2.BrewLearn and StockPiler2.BrewLearn.CompletePendingCraftLearn
                and GameData and GameData.CraftingStatus and GameData.CraftingStates
                and tonumber(GameData.CraftingStatus.State) == GameData.CraftingStates.FAIL
            then
                StockPiler2.TryCall("StockPiler2.BrewLearn.CompletePendingCraftLearn",
                    StockPiler2.BrewLearn.CompletePendingCraftLearn, { failed = true })
            end
            origHide(...)
        end
    end
    ApothecaryWindow._StockPiler2Hooked = true
    LB._apothecaryHooked = true
    StockPiler2.Debug.LogAlways("learn| apothecary hook installed")
    return true
end

--- Resolve backpack item for SendUseItem(location, slot, ...).
--- location is Cursor.SOURCE_* (refine / AutoRefine) or GameData.ItemLocs.* (some use paths).
local function ResolveItemForUse(location, slot)
    location = tonumber(location)
    slot = tonumber(slot) or 0
    if location == nil or slot <= 0 then
        return nil
    end

    local bagType = nil
    if Cursor then
        if location == Cursor.SOURCE_CRAFTING_ITEM then
            bagType = "craft"
        elseif location == Cursor.SOURCE_INVENTORY then
            bagType = "main"
        end
    end
    local ItemLocs = GameData and GameData.ItemLocs
    if bagType == nil and type(ItemLocs) == "table" then
        if location == ItemLocs.CRAFTING
            or location == ItemLocs.CRAFTING_ITEM
        then
            bagType = "craft"
        elseif location == ItemLocs.INVENTORY then
            bagType = "main"
        end
    end

    local function readBag(bt)
        if StockPiler2.BagAdapter and StockPiler2.BagAdapter.ReadSlot then
            local _, _, item = StockPiler2.BagAdapter.ReadSlot(bt, slot)
            if type(item) == "table" then
                return item
            end
        end
        return nil
    end

    if bagType ~= nil then
        return readBag(bagType)
    end
    -- Unknown location: try crafting then inventory (plants live in craft bag).
    return readBag("craft") or readBag("main")
end

function StockPiler2.EnsureUseItemRefineHook()
    return LB.EnsureUseItemRefineHook()
end

--- Arm SeedMap pending refine on any plant convert (manual Ctrl+refine or AutoRefine).
function LB.EnsureUseItemRefineHook()
    if LB._useItemRefineHooked == true then
        return true
    end
    if type(SendUseItem) ~= "function" then
        return false
    end
    local orig = SendUseItem
    SendUseItem = function(location, slot, a, b, c)
        local item = ResolveItemForUse(location, slot)
        local SM = StockPiler2.SeedMap
        if type(item) == "table" and SM and SM.ItemLooksLikeRefinablePlant
            and SM.ItemLooksLikeRefinablePlant(item) == true
            and SM.BeginPendingRefine
        then
            StockPiler2.TryCall("SeedMap.BeginPendingRefine", SM.BeginPendingRefine, item)
        end
        return orig(location, slot, a, b, c)
    end
    LB._useItemRefineHooked = true
    StockPiler2.Debug.LogAlways("learn| SendUseItem refine hook installed")
    return true
end

function LB.OnInventoryUpdated()
    if StockPiler2.SeedMap and StockPiler2.SeedMap.MarkHarvestLootDirty then
        StockPiler2.SeedMap.MarkHarvestLootDirty()
    end
    if StockPiler2.BrewLearn and StockPiler2.BrewLearn.MaybeCompletePendingCraftFromInventory then
        local learned = StockPiler2.BrewLearn.MaybeCompletePendingCraftFromInventory() == true
        if learned then
            RefreshUiIfLearned()
        end
    end
    if StockPiler2.Refine and StockPiler2.Refine.OnInventoryUpdated then
        StockPiler2.Refine.OnInventoryUpdated()
    end
end

function LB.OnCraftingUpdated()
    LB.EnsureApothecaryHook()
    LB.EnsureUseItemRefineHook()
    if StockPiler2.BrewLearn and StockPiler2.BrewLearn.OnCraftingUpdated then
        local learned = StockPiler2.BrewLearn.OnCraftingUpdated() == true
        if learned then
            RefreshUiIfLearned()
        end
    end
end

function LB.OnCultivationUpdated()
    local plotNum = 0
    if GameData and GameData.Player and GameData.Player.Cultivation then
        plotNum = tonumber(GameData.Player.Cultivation.UpdatedIndex) or 0
    end
    local grown = StageGrown()
    local empty = StageEmpty()

    local function HandlePlotEmptyTransition(pn, prevStage, newStage)
        if newStage ~= empty or prevStage == nil or prevStage == empty then
            return
        end
        if StockPiler2.Grow and StockPiler2.Grow.WakeAfterHarvest then
            StockPiler2.Grow.WakeAfterHarvest(pn)
        else
            if StockPiler2.Grow and StockPiler2.Grow.ClearFillBlocked then
                StockPiler2.Grow.ClearFillBlocked()
            end
            if StockPiler2.Grow and StockPiler2.Grow.InvalidatePlantQueue then
                StockPiler2.Grow.InvalidatePlantQueue({ force = true })
            end
            if StockPiler2.Refine and StockPiler2.Refine.MarkRefineDue then
                StockPiler2.Refine.MarkRefineDue("harvest")
            end
            if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
                StockPiler2.Scheduler.WakeAutoGrow()
            end
        end
        if StockPiler2.SeedMap and StockPiler2.SeedMap.TryCompletePendingHarvest then
            local learned = StockPiler2.SeedMap.TryCompletePendingHarvest(true) == true
            if learned then
                RefreshUiIfLearned()
            end
        end
    end

    --- Remember seedUid and arm harvest watch for non-empty / grown plots.
    local function NotePlotForHarvest(pn, row, prevStage)
        if type(row) ~= "table" then
            return
        end
        if StockPiler2.Additives and StockPiler2.Additives.LearnFromPlotRow then
            StockPiler2.Additives.LearnFromPlotRow(row)
        end
        if not StockPiler2.SeedMap then
            return
        end
        local stage = tonumber(row.stage) or 0
        local liveSeed = tonumber(row.seedUid) or 0
        if liveSeed > 0 and StockPiler2.SeedMap.NotePlotSeed then
            StockPiler2.SeedMap.NotePlotSeed(pn, liveSeed)
        end
        if stage == empty then
            return
        end
        local resolved = liveSeed
        if StockPiler2.SeedMap.ResolvePlotSeed then
            resolved = StockPiler2.SeedMap.ResolvePlotSeed(pn, liveSeed)
        end
        -- Arm on enter GROWN, stay GROWN with known seed, or any non-empty with seed
        -- so UpdatedIndex=0 / missed grown edges still get a watch.
        local justPlanted = (prevStage == nil or prevStage == empty) and resolved > 0
        local enterGrown = stage == grown and prevStage ~= grown
        local stayGrown = stage == grown and resolved > 0
        local nonEmptyWithSeed = stage ~= empty and resolved > 0
        if not (justPlanted or enterGrown or stayGrown or nonEmptyWithSeed) then
            return
        end
        if not StockPiler2.SeedMap.RefreshHarvestWatch then
            return
        end
        if justPlanted and StockPiler2.D then
            StockPiler2.D("SeedMap plant detect P" .. tostring(pn)
                .. " seedUid=" .. tostring(resolved)
                .. " stage=" .. tostring(stage))
        end
        -- Avoid re-snapshot spam: RefreshHarvestWatch keeps baseline when already watching.
        StockPiler2.SeedMap.RefreshHarvestWatch(pn, {
            Seed = { uniqueID = resolved },
        })
    end

    if plotNum <= 0 then
        -- SyncAll path: arm grown/non-empty watches and detect empty transitions.
        local Garden = StockPiler2.Garden
        if Garden and Garden.GetPlotsCopy then
            local plots = Garden.GetPlotsCopy()
            for pn, row in pairs(plots) do
                if type(row) == "table" then
                    local prev = LB._prevPlotStages[pn]
                    NotePlotForHarvest(pn, row, prev)
                    HandlePlotEmptyTransition(pn, prev, row.stage)
                    LB._prevPlotStages[pn] = row.stage
                end
            end
        end
        return
    end
    if not StockPiler2.CultivatorAdapter then
        return
    end
    local row = StockPiler2.CultivatorAdapter.ReadPlot(plotNum)
    local prev = LB._prevPlotStages[plotNum]
    NotePlotForHarvest(plotNum, row, prev)
    LB._prevPlotStages[plotNum] = row.stage
    -- Pending clear is Grow's job (grace/TTL + commit rollback); do not clear here.
    HandlePlotEmptyTransition(plotNum, prev, row.stage)
end

function LB.OnUpdateProcessed()
    local marked = false
    if StockPiler2.SeedMap
        and StockPiler2.SeedMap.TryCompletePendingHarvest
        and type(StockPiler2.SeedMap._pendingHarvest) == "table"
    then
        local pending = StockPiler2.SeedMap._pendingHarvest
        -- Pending harvest exists for the whole grow; only instrument when loot
        -- is dirty (otherwise every UPDATE_PROCESSED polluted Perf trails x1000+).
        if pending.lootDirty == true and StockPiler2.Perf and StockPiler2.Perf.Begin then
            StockPiler2.Perf.Begin("LearnBridge.OnUpdate")
            marked = true
        end
        local learned = StockPiler2.SeedMap.TryCompletePendingHarvest(false) == true
        if learned then
            RefreshUiIfLearned()
        end
    end
    if StockPiler2.Refine and StockPiler2.Refine.OnUpdateProcessed then
        StockPiler2.Refine.OnUpdateProcessed()
    end
    if marked and StockPiler2.Perf and StockPiler2.Perf.End then
        StockPiler2.Perf.End("LearnBridge.OnUpdate")
    end
end

function LB.Initialize()
    LB.EnsureApothecaryHook()
    LB.EnsureUseItemRefineHook()
    if StockPiler2.RecipeSpec then
        if StockPiler2.RecipeSpec.RepairIncompleteMainSpecs then
            local fixed = StockPiler2.RecipeSpec.RepairIncompleteMainSpecs() or 0
            if fixed > 0 and StockPiler2.Trace then
                StockPiler2.Trace("learn| repaired incomplete mains=" .. tostring(fixed))
            end
        elseif StockPiler2.RecipeSpec.RelinkPotionRecipeKeysFromOutcomes then
            StockPiler2.RecipeSpec.RelinkPotionRecipeKeysFromOutcomes()
        end
    end
    if StockPiler2.BrewLearn and StockPiler2.BrewLearn.CraftBonus and StockPiler2.Inventory then
        StockPiler2.Inventory.CraftBonus = StockPiler2.BrewLearn.CraftBonus
    end
    if StockPiler2.Additives and StockPiler2.Additives.TryMigrateFromSp1 then
        local migrated = StockPiler2.Additives.TryMigrateFromSp1() or 0
        if migrated > 0 and StockPiler2.Trace then
            StockPiler2.Trace("learn| additives migrated from SP1=" .. tostring(migrated))
        end
    end
    if StockPiler2.CraftChat and StockPiler2.CraftChat.Initialize then
        StockPiler2.CraftChat.Initialize()
    end
    if StockPiler2.SeedMap and StockPiler2.SeedMap.BootstrapSpecMap then
        local repaired = StockPiler2.SeedMap.BootstrapSpecMap() or 0
        if repaired > 0 and StockPiler2.Trace then
            StockPiler2.Trace("learn| recipe grow repair=" .. tostring(repaired))
        end
    end
    if StockPiler2.CultivatorAdapter and StockPiler2.Garden and StockPiler2.Garden.SyncAll then
        StockPiler2.Garden.SyncAll()
        local plots = StockPiler2.Garden.GetPlotsCopy()
        for plotNum, row in pairs(plots) do
            if type(row) == "table" then
                LB._prevPlotStages[plotNum] = row.stage
                local liveSeed = tonumber(row.seedUid) or 0
                if liveSeed > 0 and StockPiler2.SeedMap and StockPiler2.SeedMap.NotePlotSeed then
                    StockPiler2.SeedMap.NotePlotSeed(plotNum, liveSeed)
                end
                local stage = tonumber(row.stage) or 0
                if stage ~= StageEmpty() and StockPiler2.SeedMap and StockPiler2.SeedMap.RefreshHarvestWatch then
                    local resolved = liveSeed
                    if StockPiler2.SeedMap.ResolvePlotSeed then
                        resolved = StockPiler2.SeedMap.ResolvePlotSeed(plotNum, liveSeed)
                    end
                    if stage == StageGrown() or resolved > 0 then
                        StockPiler2.SeedMap.RefreshHarvestWatch(plotNum, {
                            Seed = { uniqueID = resolved },
                        })
                    end
                end
            end
        end
    end
    StockPiler2.Debug.LogAlways("learn| bridge initialized")
end

function LB.Shutdown()
    if StockPiler2.CraftChat and StockPiler2.CraftChat.Shutdown then
        StockPiler2.CraftChat.Shutdown()
    end
end
