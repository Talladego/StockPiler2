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
    -- Always queue readiness sync so hotbar macros update even when SP2 is closed.
    if StockPiler2Window and StockPiler2Window.RequestFooterRefresh then
        StockPiler2Window.RequestFooterRefresh()
    end
end

function Bridge.OnInventoryUpdated(updatedSlots)
    -- 0.4.159: coalesce main-bag applies to one GetBagTable per UPDATE_PROCESSED
    -- (mirrors craft FlushPendingCraftSlots; kills Inv.ApplySlots xN storms).
    Bridge._pendingMainSlots = Bridge._pendingMainSlots or {}
    Bridge._pendingMainSlotSet = Bridge._pendingMainSlotSet or {}
    if type(updatedSlots) == "table" then
        local n = 0
        for _, v in ipairs(updatedSlots) do
            local slot = tonumber(v) or 0
            if slot > 0 and Bridge._pendingMainSlotSet[slot] ~= true then
                Bridge._pendingMainSlotSet[slot] = true
                Bridge._pendingMainSlots[#Bridge._pendingMainSlots + 1] = slot
                n = n + 1
            end
        end
        if n == 0 then
            for k, v in pairs(updatedSlots) do
                local slot = tonumber(k)
                if slot == nil or slot <= 0 then
                    slot = tonumber(v) or 0
                end
                if slot > 0 and Bridge._pendingMainSlotSet[slot] ~= true then
                    Bridge._pendingMainSlotSet[slot] = true
                    Bridge._pendingMainSlots[#Bridge._pendingMainSlots + 1] = slot
                end
            end
        end
    end
    Bridge._pendingMainApply = true
    Bridge._pendingMainLearn = true
end

--- Apply coalesced main-bag slots once per frame (single GetBagTable).
function Bridge.FlushPendingMainSlots()
    if Bridge._pendingMainApply ~= true then
        return false
    end
    Bridge._pendingMainApply = false
    local slots = Bridge._pendingMainSlots
    Bridge._pendingMainSlots = {}
    Bridge._pendingMainSlotSet = {}
    local learn = Bridge._pendingMainLearn == true
    Bridge._pendingMainLearn = false
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Inv.ApplySlots")
    end
    if learn and StockPiler2.LearnBridge and StockPiler2.LearnBridge.OnInventoryUpdated then
        StockPiler2.LearnBridge.OnInventoryUpdated()
    end
    if type(slots) == "table" and #slots > 0 then
        if StockPiler2.Inventory and StockPiler2.Inventory.ApplySlotUpdates then
            StockPiler2.Inventory.ApplySlotUpdates("main", slots, "engine-inventory")
        else
            StockPiler2.Inventory.MarkDirty({ reason = "engine-inventory", full = true })
        end
    end
    if Perf and Perf.End then
        Perf.End("Inv.ApplySlots")
    end
    return true
end

function Bridge.OnCraftingSlotUpdated(updatedSlots)
    -- 0.4.156: coalesce craft-slot applies to one GetBagTable per UPDATE_PROCESSED.
    Bridge._pendingCraftSlots = Bridge._pendingCraftSlots or {}
    Bridge._pendingCraftSlotSet = Bridge._pendingCraftSlotSet or {}
    if type(updatedSlots) == "table" then
        local n = 0
        for _, v in ipairs(updatedSlots) do
            local slot = tonumber(v) or 0
            if slot > 0 and Bridge._pendingCraftSlotSet[slot] ~= true then
                Bridge._pendingCraftSlotSet[slot] = true
                Bridge._pendingCraftSlots[#Bridge._pendingCraftSlots + 1] = slot
                n = n + 1
            end
        end
        if n == 0 then
            for k, v in pairs(updatedSlots) do
                local slot = tonumber(k)
                if slot == nil or slot <= 0 then
                    slot = tonumber(v) or 0
                end
                if slot > 0 and Bridge._pendingCraftSlotSet[slot] ~= true then
                    Bridge._pendingCraftSlotSet[slot] = true
                    Bridge._pendingCraftSlots[#Bridge._pendingCraftSlots + 1] = slot
                end
            end
        end
    end
    Bridge._pendingCraftApply = true
    Bridge._pendingCraftLearn = true
    -- Perf: Brew job active → always pass through (ReconcileBoardIntegrity + Tick).
    -- Idle craft-bag rearrange must NOT MarkBrewUiDue (was BrewUi+WatchRows on every
    -- slot shuffle). Apo/crafting state still arms BrewUi via OnCraftingUpdated.
    local Brew = StockPiler2.Brew
    local jobActive = Brew and type(Brew._job) == "table"
    if jobActive then
        Bridge._pendingCraftBrewUpdate = true
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

--- Apply coalesced craft slots once per frame (single GetBagTable).
function Bridge.FlushPendingCraftSlots()
    if Bridge._pendingCraftApply ~= true then
        return false
    end
    Bridge._pendingCraftApply = false
    local slots = Bridge._pendingCraftSlots
    Bridge._pendingCraftSlots = {}
    Bridge._pendingCraftSlotSet = {}
    local learn = Bridge._pendingCraftLearn == true
    Bridge._pendingCraftLearn = false
    local brewUpdate = Bridge._pendingCraftBrewUpdate == true
    Bridge._pendingCraftBrewUpdate = false
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Inv.ApplySlots")
    end
    if learn and StockPiler2.LearnBridge and StockPiler2.LearnBridge.OnInventoryUpdated then
        StockPiler2.LearnBridge.OnInventoryUpdated()
    end
    if type(slots) == "table" and #slots > 0 then
        if StockPiler2.Inventory and StockPiler2.Inventory.ApplySlotUpdates then
            StockPiler2.Inventory.ApplySlotUpdates("craft", slots, "engine-crafting-slot")
        else
            StockPiler2.Inventory.MarkDirty({ reason = "engine-crafting-slot", full = true })
        end
    end
    if Perf and Perf.End then
        Perf.End("Inv.ApplySlots")
    end
    if brewUpdate then
        local Brew = StockPiler2.Brew
        if Brew and Brew.OnCraftingUpdated then
            Brew.OnCraftingUpdated()
        end
    end
    return true
end

function Bridge.OnCraftingUpdated()
    if StockPiler2.LearnBridge and StockPiler2.LearnBridge.OnCraftingUpdated then
        StockPiler2.LearnBridge.OnCraftingUpdated()
    end
    local Sch = StockPiler2.Scheduler
    local Brew = StockPiler2.Brew
    local jobActive = Brew and type(Brew._job) == "table"
    if jobActive then
        if Brew.OnCraftingUpdated then
            Brew.OnCraftingUpdated()
        end
    elseif Sch and Sch.ShouldHoldBrewUi and Sch.ShouldHoldBrewUi() == true then
        if Sch.MarkBrewUiDue then
            Sch.MarkBrewUiDue()
        end
        if Sch.IsHarvestStormActive and Sch.IsHarvestStormActive() == true then
            Sch._brewUiStormHeld = true
        end
    elseif Sch and Sch.MarkBrewUiDue then
        Sch.MarkBrewUiDue()
    elseif Brew and Brew.OnCraftingUpdated then
        Brew.OnCraftingUpdated()
    end
    RequestFooterIfOpen()
end

function Bridge.OnCultivationUpdated()
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("CultivationUpdated")
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
    if Perf and Perf.End then
        Perf.End("CultivationUpdated")
    end
end

function Bridge.OnTradeSkillUpdated()
    local Caps = StockPiler2.TradeSkillCaps
    if not Caps then
        return
    end
    if Caps.MarkTradeSkillsReady then
        Caps.MarkTradeSkillsReady()
    end
    local cult = Caps.CultivationLevel and Caps.CultivationLevel() or 0
    local apo = Caps.ApothecaryLevel and Caps.ApothecaryLevel() or 0
    local levelsHash = Caps.LevelsHash and Caps.LevelsHash() or (tostring(cult) .. ":" .. tostring(apo))
    local prev = Bridge._skillPrev
    local hashChanged = Bridge._skillLevelsHash ~= levelsHash
    local firstSkillsReady = Bridge._skillsWereReady ~= true
    Bridge._skillLevelsHash = levelsHash
    Bridge._skillsWereReady = true
    if type(prev) ~= "table" then
        Bridge._skillPrev = { cult = cult, apo = apo }
        hashChanged = true
    else
        local dCult = cult - (tonumber(prev.cult) or cult)
        local dApo = apo - (tonumber(prev.apo) or apo)
        prev.cult = cult
        prev.apo = apo
        -- Logout / char switch: ignore large negative jumps.
        if dCult <= -5 or dApo <= -5 then
            if Caps.ResetTradeSkillsReady then
                Caps.ResetTradeSkillsReady()
            end
            Bridge._skillsWereReady = false
            Bridge._skillLevelsHash = nil
            return
        end
        if dCult > 0 and StockPiler2.SeedMap and StockPiler2.SeedMap.OnCultSkillDelta then
            StockPiler2.SeedMap.OnCultSkillDelta(dCult)
        end
        if dApo > 0 and StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.OnApoSkillDelta then
            StockPiler2.RecipeSpec.OnApoSkillDelta(dApo)
        end
    end
    -- Login: skills just became known — drop any premature skill-gate NotifyOnce.
    if firstSkillsReady then
        if StockPiler2.Debug and StockPiler2.Debug.ClearNotifyOnceContaining then
            StockPiler2.Debug.ClearNotifyOnceContaining(":need_skill")
            StockPiler2.Debug.ClearNotifyOnceContaining(":need_apothecary")
        end
        if StockPiler2.Planner then
            local keys = StockPiler2.Planner._watchBlockOnceKeys
            if type(keys) == "table" then
                for watchKey, onceKey in pairs(keys) do
                    local s = tostring(onceKey or "")
                    if string.find(s, ":need_skill", 1, true)
                        or string.find(s, ":need_apothecary", 1, true)
                    then
                        keys[watchKey] = nil
                    end
                end
            end
        end
    end
    if hashChanged or firstSkillsReady then
        if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueuePlanRebuild then
            StockPiler2.Scheduler.EnqueuePlanRebuild()
        end
        if StockPiler2TabWatch and StockPiler2TabWatch.RefreshSkillGates then
            StockPiler2TabWatch.RefreshSkillGates()
        end
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
    -- Re-arm skill readiness; tradeSkills are often still empty here.
    if StockPiler2.TradeSkillCaps and StockPiler2.TradeSkillCaps.ResetTradeSkillsReady then
        local Caps = StockPiler2.TradeSkillCaps
        Caps.ResetTradeSkillsReady()
        if Caps.AreTradeSkillsReady then
            Caps.AreTradeSkillsReady() -- mark ready immediately if levels already warm
        end
    end
    Bridge._skillLevelsHash = nil
    Bridge._skillPrev = nil
    Bridge._skillsWereReady = false
    if StockPiler2.Garden and StockPiler2.Garden.SyncAll then
        StockPiler2.Garden.SyncAll()
    end
    StockPiler2.Inventory.ForceFullRefresh()
    BusFire(StockPiler2.Events.SESSION_LOADED, { reason = "loading-end" })
end

function Bridge.OnUpdateProcessed(timeElapsed)
    StockPiler2.FrameCounter = (tonumber(StockPiler2.FrameCounter) or 0) + 1
    -- Perf hitch attribution is owned by LibPerf (optional); do not call OnFrame here.
    -- Drain coalesced Garden.SyncAll (UpdatedIndex==0 storms) once per frame.
    if StockPiler2.Garden and StockPiler2.Garden.FlushPendingSyncAll then
        StockPiler2.Garden.FlushPendingSyncAll()
    end
    -- SyncAll does not call Grow — confirm pending plants after coalesced flush.
    if StockPiler2.Grow and StockPiler2.Grow.OnCultivationUpdated then
        StockPiler2.Grow.OnCultivationUpdated(0)
    end
    -- One main-bag ApplySlots for all PLAYER_INVENTORY_SLOT_UPDATED this frame.
    if Bridge.FlushPendingMainSlots then
        Bridge.FlushPendingMainSlots()
    end
    -- One craft-bag ApplySlots for all PLAYER_CRAFTING_SLOT_UPDATED this frame.
    if Bridge.FlushPendingCraftSlots then
        Bridge.FlushPendingCraftSlots()
    end
    -- Publish one snapGen for all L0 AdjustUid this frame before refine/plan.
    if StockPiler2.Inventory and StockPiler2.Inventory.FlushPendingSnapGen then
        StockPiler2.Inventory.FlushPendingSnapGen()
    end
    if StockPiler2.Macro and StockPiler2.Macro.DrainEnabledSync then
        StockPiler2.Macro.DrainEnabledSync()
    end
    -- One Brew.OnCraftingUpdated max per frame (craft-slot coalesce); storm may still hold.
    -- Promote post-storm BrewUi arm from a prior expiry frame before flush (0.4.101).
    if StockPiler2.Scheduler and StockPiler2.Scheduler.PromotePostStormBrewUi then
        StockPiler2.Scheduler.PromotePostStormBrewUi()
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.FlushBrewUiIfDue then
        StockPiler2.Scheduler.FlushBrewUiIfDue()
    end
    if StockPiler2.LearnBridge and StockPiler2.LearnBridge.OnUpdateProcessed then
        StockPiler2.LearnBridge.OnUpdateProcessed()
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.OnUpdate then
        StockPiler2.Scheduler.OnUpdate(timeElapsed)
    end
    -- 0.4.130: Footer AFTER LearnBridge/Scheduler so SkipUiThisFrame (Harvest.Complete /
    -- Refine delivery) can hold Footer off the same hitch as Complete/Reconcile.
    -- Pending stays set when skipped; next frame flushes.
    if StockPiler2Window and StockPiler2Window.FlushPendingFooterRefresh then
        StockPiler2Window.FlushPendingFooterRefresh()
    end
    if StockPiler2.Scheduler then
        StockPiler2.Scheduler._skipUiHoldFooter = false
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
    if ev.TRADE_SKILL_UPDATED then
        RegisterEventHandler(ev.TRADE_SKILL_UPDATED, "StockPiler2.EngineEventBridge.OnTradeSkillUpdated")
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
    local Caps = StockPiler2.TradeSkillCaps
    if Caps then
        Bridge._skillPrev = {
            cult = Caps.CultivationLevel and Caps.CultivationLevel() or 0,
            apo = Caps.ApothecaryLevel and Caps.ApothecaryLevel() or 0,
        }
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
    if ev.TRADE_SKILL_UPDATED then
        UnregisterEventHandler(ev.TRADE_SKILL_UPDATED, "StockPiler2.EngineEventBridge.OnTradeSkillUpdated")
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
