----------------------------------------------------------------
-- StockPiler2 Core/EngineEventBridge — map SystemData.Events → EventBus
----------------------------------------------------------------

StockPiler2.EngineEventBridge = StockPiler2.EngineEventBridge or {}
local Bridge = StockPiler2.EngineEventBridge

Bridge._registered = false
Bridge._handlers = {}

--- Monotonic frame counter (bumped at start of UPDATE_PROCESSED).
StockPiler2.FrameCounter = tonumber(StockPiler2.FrameCounter) or 0

local function E()
    return SystemData and SystemData.Events
end

local function BusFire(name, payload)
    local B = StockPiler2.EventBus
    if B and B.Fire then
        B.Fire(name, payload)
    end
end

local function RequestFooterIfOpen()
    if StockPiler2Window and StockPiler2Window.RequestFooterRefresh
        and DoesWindowExist("StockPiler2Window")
        and WindowGetShowing("StockPiler2Window") == true
    then
        StockPiler2Window.RequestFooterRefresh()
    end
end

function Bridge.OnInventoryUpdated(updatedSlots)
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Inv.ApplySlots")
    end
    if StockPiler2.LearnBridge and StockPiler2.LearnBridge.OnInventoryUpdated then
        StockPiler2.LearnBridge.OnInventoryUpdated()
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.ApplySlotUpdates then
        StockPiler2.Inventory.ApplySlotUpdates("main", updatedSlots, "engine-inventory")
    else
        StockPiler2.Inventory.MarkDirty({ reason = "engine-inventory", full = true })
    end
    if Perf and Perf.End then
        Perf.End("Inv.ApplySlots")
    end
end

function Bridge.OnCraftingSlotUpdated(updatedSlots)
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Inv.ApplySlots")
    end
    if StockPiler2.LearnBridge and StockPiler2.LearnBridge.OnInventoryUpdated then
        StockPiler2.LearnBridge.OnInventoryUpdated()
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.ApplySlotUpdates then
        StockPiler2.Inventory.ApplySlotUpdates("craft", updatedSlots, "engine-crafting-slot")
    else
        StockPiler2.Inventory.MarkDirty({ reason = "engine-crafting-slot", full = true })
    end
    if Perf and Perf.End then
        Perf.End("Inv.ApplySlots")
    end
    if StockPiler2.Brew and StockPiler2.Brew.OnCraftingUpdated then
        StockPiler2.Brew.OnCraftingUpdated()
    end
    if StockPiler2.Grow and StockPiler2.Grow.NeedsCurrentStageAdditive
        and StockPiler2.Grow.NeedsCurrentStageAdditive()
        and StockPiler2.Grow.MarkAdditiveDue
    then
        StockPiler2.Grow.MarkAdditiveDue()
        if StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow then
            StockPiler2.Scheduler.WakeAutoGrow()
        end
    end
end

function Bridge.OnCraftingUpdated()
    if StockPiler2.LearnBridge and StockPiler2.LearnBridge.OnCraftingUpdated then
        StockPiler2.LearnBridge.OnCraftingUpdated()
    end
    if StockPiler2.Brew and StockPiler2.Brew.OnCraftingUpdated then
        StockPiler2.Brew.OnCraftingUpdated()
    end
    RequestFooterIfOpen()
end

function Bridge.OnCultivationUpdated()
    if StockPiler2.Perf and StockPiler2.Perf.Mark then
        StockPiler2.Perf.Mark("CultivationUpdated")
    end
    local plotNum = 0
    if GameData and GameData.Player and GameData.Player.Cultivation then
        plotNum = tonumber(GameData.Player.Cultivation.UpdatedIndex) or 0
    end
    if StockPiler2.Garden and StockPiler2.Garden.OnCultivationUpdated then
        StockPiler2.Garden.OnCultivationUpdated()
    end
    if StockPiler2.Grow and StockPiler2.Grow.OnCultivationUpdated then
        StockPiler2.Grow.OnCultivationUpdated(plotNum)
    end
    if StockPiler2.LearnBridge and StockPiler2.LearnBridge.OnCultivationUpdated then
        StockPiler2.LearnBridge.OnCultivationUpdated()
    end
    -- Coalesce footer (harvest readiness) to once per UPDATE_PROCESSED.
    RequestFooterIfOpen()
    -- Seedling / Flowering unlocks Water / Nutrient — wake AutoGrow so orch ticks.
    if StockPiler2.Grow and StockPiler2.Grow.NeedsCurrentStageAdditive
        and StockPiler2.Grow.NeedsCurrentStageAdditive()
        and StockPiler2.Scheduler and StockPiler2.Scheduler.WakeAutoGrow
    then
        StockPiler2.Scheduler.WakeAutoGrow()
    end
end

function Bridge.OnStoreShow()
    if StockPiler2.VendorAdapter and StockPiler2.VendorAdapter.EnsureStoreHook then
        StockPiler2.VendorAdapter.EnsureStoreHook()
    end
    if StockPiler2.VendorAdapter and StockPiler2.VendorAdapter.OnStoreShow then
        StockPiler2.VendorAdapter.OnStoreShow()
    end
end

function Bridge.OnLoadingEnd()
    if StockPiler2.Garden and StockPiler2.Garden.SyncAll then
        StockPiler2.Garden.SyncAll()
    end
    StockPiler2.Inventory.ForceFullRefresh()
    BusFire(StockPiler2.Events.SESSION_LOADED, { reason = "loading-end" })
end

function Bridge.OnUpdateProcessed(timeElapsed)
    StockPiler2.FrameCounter = (tonumber(StockPiler2.FrameCounter) or 0) + 1
    -- Attribute previous frame hitch to trail left by last tick's work.
    if StockPiler2.Perf and StockPiler2.Perf.OnFrame then
        StockPiler2.Perf.OnFrame(timeElapsed)
    end
    -- Drain coalesced Garden.SyncAll (UpdatedIndex==0 storms) once per frame.
    if StockPiler2.Garden and StockPiler2.Garden.FlushPendingSyncAll then
        StockPiler2.Garden.FlushPendingSyncAll()
    end
    -- Publish one snapGen for all L0 AdjustUid this frame before refine/plan.
    if StockPiler2.Inventory and StockPiler2.Inventory.FlushPendingSnapGen then
        StockPiler2.Inventory.FlushPendingSnapGen()
    end
    if StockPiler2.Macro and StockPiler2.Macro.DrainEnabledSync then
        StockPiler2.Macro.DrainEnabledSync()
    end
    if StockPiler2Window and StockPiler2Window.FlushPendingFooterRefresh then
        StockPiler2Window.FlushPendingFooterRefresh()
    end
    if StockPiler2.LearnBridge and StockPiler2.LearnBridge.OnUpdateProcessed then
        StockPiler2.LearnBridge.OnUpdateProcessed()
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.OnUpdate then
        StockPiler2.Scheduler.OnUpdate(timeElapsed)
    end
end

function Bridge.Register()
    if Bridge._registered == true then
        return
    end
    local ev = E()
    if type(ev) ~= "table" or type(RegisterEventHandler) ~= "function" then
        return
    end
    if ev.PLAYER_INVENTORY_SLOT_UPDATED then
        RegisterEventHandler(ev.PLAYER_INVENTORY_SLOT_UPDATED, "StockPiler2.EngineEventBridge.OnInventoryUpdated")
    end
    if ev.PLAYER_CRAFTING_SLOT_UPDATED then
        RegisterEventHandler(ev.PLAYER_CRAFTING_SLOT_UPDATED, "StockPiler2.EngineEventBridge.OnCraftingSlotUpdated")
    end
    if ev.PLAYER_CRAFTING_UPDATED then
        RegisterEventHandler(ev.PLAYER_CRAFTING_UPDATED, "StockPiler2.EngineEventBridge.OnCraftingUpdated")
    end
    if ev.PLAYER_CULTIVATION_UPDATED then
        RegisterEventHandler(ev.PLAYER_CULTIVATION_UPDATED, "StockPiler2.EngineEventBridge.OnCultivationUpdated")
    end
    if ev.LOADING_END then
        RegisterEventHandler(ev.LOADING_END, "StockPiler2.EngineEventBridge.OnLoadingEnd")
    end
    if ev.INTERACT_SHOW_STORE then
        RegisterEventHandler(ev.INTERACT_SHOW_STORE, "StockPiler2.EngineEventBridge.OnStoreShow")
    end
    if ev.UPDATE_PROCESSED then
        RegisterEventHandler(ev.UPDATE_PROCESSED, "StockPiler2.EngineEventBridge.OnUpdateProcessed")
    end
    if StockPiler2.VendorAdapter and StockPiler2.VendorAdapter.EnsureStoreHook then
        StockPiler2.VendorAdapter.EnsureStoreHook()
    end
    Bridge._registered = true
    StockPiler2.Debug.LogAlways("init engine event bridge registered")
end

function Bridge.Unregister()
    if Bridge._registered ~= true then
        return
    end
    local ev = E()
    if type(ev) ~= "table" or type(UnregisterEventHandler) ~= "function" then
        Bridge._registered = false
        return
    end
    if ev.PLAYER_INVENTORY_SLOT_UPDATED then
        UnregisterEventHandler(ev.PLAYER_INVENTORY_SLOT_UPDATED, "StockPiler2.EngineEventBridge.OnInventoryUpdated")
    end
    if ev.PLAYER_CRAFTING_SLOT_UPDATED then
        UnregisterEventHandler(ev.PLAYER_CRAFTING_SLOT_UPDATED, "StockPiler2.EngineEventBridge.OnCraftingSlotUpdated")
    end
    if ev.PLAYER_CRAFTING_UPDATED then
        UnregisterEventHandler(ev.PLAYER_CRAFTING_UPDATED, "StockPiler2.EngineEventBridge.OnCraftingUpdated")
    end
    if ev.PLAYER_CULTIVATION_UPDATED then
        UnregisterEventHandler(ev.PLAYER_CULTIVATION_UPDATED, "StockPiler2.EngineEventBridge.OnCultivationUpdated")
    end
    if ev.LOADING_END then
        UnregisterEventHandler(ev.LOADING_END, "StockPiler2.EngineEventBridge.OnLoadingEnd")
    end
    if ev.INTERACT_SHOW_STORE then
        UnregisterEventHandler(ev.INTERACT_SHOW_STORE, "StockPiler2.EngineEventBridge.OnStoreShow")
    end
    if ev.UPDATE_PROCESSED then
        UnregisterEventHandler(ev.UPDATE_PROCESSED, "StockPiler2.EngineEventBridge.OnUpdateProcessed")
    end
    Bridge._registered = false
end
