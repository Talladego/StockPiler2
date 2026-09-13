----------------------------------------------------------------
-- StockPiler2 Brew — Watch footer load/brew session (slim SP1 port)
----------------------------------------------------------------

StockPiler2.Brew = StockPiler2.Brew or {}
local Brew = StockPiler2.Brew

local function T(key, tokens)
    if StockPiler2.T then
        return StockPiler2.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

local TICK_INTERVAL_SEC = 0.05
local OPEN_WAIT_TICKS = 60
local STEP_WAIT_TICKS = 60
local CLEAR_WAIT_TICKS = 80
local BOARD_RECONCILE_INTERVAL_SEC = 0.25

local LOAD_ROLE_ORDER = {
    container = 1,
    main = 2,
    stabilizer = 3,
    goldweed = 3,
    extender = 4,
    multiplier = 5,
    stimulant = 5,
    ingredient = 6,
}

local function ToNarrow(value)
    if StockPiler2.ToNarrow then
        return StockPiler2.ToNarrow(value)
    end
    return tostring(value or "")
end

local function LogBrew(msg)
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("brew", msg)
    end
end

local function Notify(msg)
    if StockPiler2.Ui and StockPiler2.Ui.Print then
        StockPiler2.Ui.Print(msg)
    elseif StockPiler2.Debug and StockPiler2.Debug.Print then
        StockPiler2.Debug.Print(msg)
    end
end

local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

-- After ClearLoadedSession / FailJob, ClearSlots craft events arrive on later frames
-- while the board still matches the recipe — TryAdopt would paint Brew then empty→Load.
Brew.BOARD_ADOPT_BLOCK_AFTER_CLEAR_SEC = 1.5

local function ArmBoardAdoptBlock()
    local sec = tonumber(Brew.BOARD_ADOPT_BLOCK_AFTER_CLEAR_SEC) or 1.5
    local untilT = NowSec() + sec
    local cur = tonumber(Brew._blockBoardAdoptUntil) or 0
    if untilT > cur then
        Brew._blockBoardAdoptUntil = untilT
    end
end

local function BoardAdoptBlocked()
    local untilT = tonumber(Brew._blockBoardAdoptUntil) or 0
    if untilT <= 0 then
        return false
    end
    local now = NowSec()
    if now > 0 and now < untilT then
        return true
    end
    Brew._blockBoardAdoptUntil = 0
    return false
end

local function ClearBoardAdoptBlock()
    Brew._blockBoardAdoptUntil = 0
end

local function AA()
    return StockPiler2.ApothecaryAdapter
end

local function SyncOrchPhase(phase)
    local Orch = StockPiler2.Orchestrator
    if not Orch then
        return
    end
    if phase == "loading" or phase == "loaded" then
        Orch._brewPhase = phase
    else
        Orch._brewPhase = nil
    end
end

local function EmptySession()
    return {
        phase = "idle",
        potionKey = nil,
        rowId = nil,
        name = nil,
        potionUid = nil,
        potionHave = nil,
        potionMin = nil,
        potionDeficit = nil,
        craftable = nil,
        recipeYield = nil,
    }
end

local function GetSession()
    if type(Brew._session) ~= "table" then
        Brew._session = EmptySession()
    end
    return Brew._session
end

local function ClearSession()
    Brew._session = EmptySession()
    Brew._loadSource = nil
    SyncOrchPhase("idle")
    if Brew.InvalidateCanBrewCache then
        Brew.InvalidateCanBrewCache()
    end
    -- 0.4.126: one PlanRebuild after mid-brew hold (Status/tips catch up).
    if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueuePlanRebuildAfterBrewClear then
        StockPiler2.Scheduler.EnqueuePlanRebuildAfterBrewClear()
    end
end

local function CaptureSessionStatsFromRow(row, recipe)
    local session = GetSession()
    if type(row) ~= "table" then
        return
    end
    session.potionHave = tonumber(row.potionHave) or tonumber(row.have)
    session.potionMin = tonumber(row.potionMin) or tonumber(row.target)
    session.potionDeficit = tonumber(row.potionDeficit)
    session.craftable = tonumber(row.craftable)
    session.potionUid = tonumber(row.uniqueID) or tonumber(row.potionUid)
    if type(recipe) == "table" and StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.RecipeOutputYield then
        local y = tonumber(StockPiler2.RecipeSpec.RecipeOutputYield(recipe, session.potionUid)) or 2
        session.recipeYield = math.max(1, math.floor(y + 0.5))
    elseif type(recipe) == "table" then
        session.recipeYield = math.max(1, tonumber(recipe.recipeYield) or 2)
    end
end

local function SetSessionFromRow(row, phase)
    local session = GetSession()
    session.phase = phase or "idle"
    SyncOrchPhase(session.phase)
    if type(row) == "table" then
        session.potionKey = row.potionKey
        session.rowId = row.id
        session.name = row.name
        CaptureSessionStatsFromRow(row, row.specRecipe or row.recipe)
    else
        session.potionKey = nil
        session.rowId = nil
        session.name = nil
        session.potionUid = nil
        session.potionHave = nil
        session.potionMin = nil
        session.potionDeficit = nil
        session.craftable = nil
        session.recipeYield = nil
    end
    if Brew.InvalidateCanBrewCache then
        Brew.InvalidateCanBrewCache()
    end
end

function Brew.GetSession()
    return GetSession()
end

function Brew.ArmBrewOpLock(seconds)
    seconds = tonumber(seconds) or 1.25
    if seconds < 0.4 then
        seconds = 0.4
    end
    local untilT = NowSec() + seconds
    local cur = tonumber(Brew._brewOpLockUntil) or 0
    if untilT > cur then
        Brew._brewOpLockUntil = untilT
    end
end

function Brew.ClearBrewOpLock()
    Brew._brewOpLockUntil = 0
end

local function IsPerformingState()
    local a = AA()
    return a and a.IsPerforming and a.IsPerforming() == true
end

function Brew.IsBusy()
    if type(Brew._job) == "table" then
        return true
    end
    if IsPerformingState() then
        return true
    end
    local lockUntil = tonumber(Brew._brewOpLockUntil) or 0
    if lockUntil > 0 then
        if NowSec() < lockUntil then
            return true
        end
        Brew._brewOpLockUntil = 0
    end
    return false
end

--- Harvest footer/gate: block while brew is loading, loaded, or crafting.
function Brew.BlocksHarvest()
    if type(Brew._job) == "table" then
        return true
    end
    if IsPerformingState() then
        return true
    end
    local session = GetSession()
    local phase = tostring(session.phase or "idle")
    return phase == "loading" or phase == "loaded"
end

----------------------------------------------------------------
-- Ready-watch picking
----------------------------------------------------------------

local function RowIsReadyToCraft(row)
    if type(row) ~= "table" then
        return false
    end
    if (tonumber(row.potionDeficit) or 0) <= 0 then
        return false
    end
    if row.statusKey ~= "ready_to_craft" then
        return false
    end
    if (tonumber(row.craftable) or 0) <= 0 then
        return false
    end
    if row.craftableShared == true then
        return false
    end
    return true
end

--- Per-row Load: craftable (or canLoad), including stocked overstock and yellow shared.
--- Footer PickReadyWatch still uses RowIsReadyToCraft (green + deficit only).
local function RowCanPrematureLoad(row)
    if type(row) ~= "table" then
        return false
    end
    if (tonumber(row.craftable) or 0) > 0 then
        return true
    end
    return row.canLoad == true
end

local function RowMatchesSession(row, session)
    if type(row) ~= "table" or type(session) ~= "table" then
        return false
    end
    if session.rowId ~= nil and row.id ~= nil and row.id == session.rowId then
        return true
    end
    if session.potionKey ~= nil and row.potionKey ~= nil and row.potionKey == session.potionKey then
        return true
    end
    return false
end

local function CompareReadyWatch(a, b)
    local da = tonumber(a.potionDeficit) or 0
    local db = tonumber(b.potionDeficit) or 0
    if da ~= db then
        return da > db
    end
    return ToNarrow(a.name) < ToNarrow(b.name)
end

local function CurrentPlan()
    if StockPiler2.Planner and StockPiler2.Planner.GetOrBuild then
        return StockPiler2.Planner.GetOrBuild({ refresh = false })
    end
    return nil
end

--- Must sit above CanBrewNow / TryBrewClick (RoR does not hoist local functions).
local function FindSessionRow()
    local session = GetSession()
    if session.phase == "idle" and session.potionKey == nil and session.rowId == nil then
        return nil
    end
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return nil
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            if session.rowId ~= nil and row.id == session.rowId then
                return row
            end
            if session.potionKey ~= nil and row.potionKey == session.potionKey then
                return row
            end
        end
    end
    return nil
end

function Brew.PickReadyWatch()
    local a = AA()
    if a and a.IsApothecary and not a.IsApothecary() then
        return nil
    end
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return nil
    end
    local best = nil
    for i = 1, #rows do
        local row = rows[i]
        if RowIsReadyToCraft(row) then
            if best == nil or CompareReadyWatch(row, best) then
                best = row
            end
        end
    end
    return best
end

--- Print once when footer Brew becomes actionable; chime only on that edge.
--- Do not clear the once-key during op-lock / perform / load job (avoids re-chime every craft).
--- 0.4.159: edge-only immediate footer sync; steady ready uses RequestFooterRefresh.
--- 0.4.161: do not clear once-key on transient CanBrewNow holds (pending plant /
--- seed-buffer / refine) while a ready watch still exists — that re-chimed every plant.
function Brew.MaybeNotifyBrewReady()
    local function clearReady()
        if StockPiler2.Debug and StockPiler2.Debug.ClearNotifyOnce then
            StockPiler2.Debug.ClearNotifyOnce("brew-ready")
        end
    end
    -- Ready-only: never notify for a manual row Load session.
    if Brew._loadSource == "manual" then
        clearReady()
        Brew._brewReadyLatched = false
        return
    end
    -- Transient busy: keep once-key so leaving op-lock does not re-announce.
    if Brew.IsBusy and Brew.IsBusy() == true then
        return
    end
    local hasReadyRow = type(Brew.PickReadyWatch and Brew.PickReadyWatch()) == "table"
    if not (Brew.CanBrewNow and Brew.CanBrewNow() == true) then
        if hasReadyRow then
            -- Still have a Ready watch; footer is only held (plant/buffer/refine).
            if Brew._brewReadyLatched == true
                and StockPiler2Window and StockPiler2Window.RequestFooterRefresh
            then
                StockPiler2Window.RequestFooterRefresh()
            end
            return
        end
        if Brew._brewReadyLatched == true
            and StockPiler2Window and StockPiler2Window.RequestFooterRefresh
        then
            StockPiler2Window.RequestFooterRefresh()
        end
        Brew._brewReadyLatched = false
        clearReady()
        return
    end
    local wasReady = Brew._brewReadyLatched == true
    if not wasReady then
        if StockPiler2Window and StockPiler2Window.SyncActionReadiness then
            StockPiler2Window.SyncActionReadiness({ immediate = true })
        end
    elseif StockPiler2Window and StockPiler2Window.RequestFooterRefresh then
        StockPiler2Window.RequestFooterRefresh()
    end
    Brew._brewReadyLatched = true
    local row = Brew.PickReadyWatch()
    if type(row) ~= "table" then
        row = FindSessionRow()
    end
    local name = nil
    if type(row) == "table" then
        name = row.name
    end
    if name == nil or name == L"" then
        local session = GetSession()
        name = session and session.name
    end
    if name == nil or name == L"" then
        name = T("brew.potion_fallback")
    end
    local printed = false
    if StockPiler2.Debug and StockPiler2.Debug.NotifyOnce then
        printed = StockPiler2.Debug.NotifyOnce("brew-ready", T("brew.ready", { name = name })) == true
    else
        Notify(T("brew.ready", { name = name }))
        printed = true
    end
    if printed then
        local soundId = GameData and GameData.Sound and GameData.Sound.HELP_TIPS_HIGHTLIGHT_WINDOW
        if StockPiler2.Debug and StockPiler2.Debug.PlayUiSound then
            StockPiler2.Debug.PlayUiSound(soundId)
        elseif type(PlaySound) == "function" and soundId ~= nil then
            pcall(PlaySound, soundId)
        end
    end
end

function Brew.HasReadyToCraft()
    if Brew.PickReadyWatch() ~= nil then
        return true
    end
    local session = GetSession()
    -- Manual row loads do not count as Ready for footer/macro.
    if Brew._loadSource == "manual" then
        return false
    end
    if session.phase == "loading" then
        return true
    end
    if session.phase == "loaded" then
        local row = FindSessionRow()
        if RowIsReadyToCraft(row) then
            return true
        end
        return (tonumber(session.potionDeficit) or 0) > 0
            and (tonumber(session.craftable) or 0) > 0
    end
    return false
end

function Brew.CanStartBrewLoad()
    local refineWait = 0
    if StockPiler2.Refine and StockPiler2.Refine._refineWaitTicks then
        refineWait = tonumber(StockPiler2.Refine._refineWaitTicks) or 0
    end
    local outstanding = false
    local RP = StockPiler2.RefinePipeline
    if RP and RP.HasOutstanding then
        outstanding = RP.HasOutstanding() == true
    end
    local pendingPlant = false
    local Grow = StockPiler2.Grow
    if Grow and type(Grow._pendingPlant) == "table" then
        for _, n in pairs(Grow._pendingPlant) do
            if (tonumber(n) or 0) > 0 then
                pendingPlant = true
                break
            end
        end
    end
    local function Hold(reason, msg)
        if Brew._lastHoldReason ~= reason then
            Brew._lastHoldReason = reason
            LogBrew("hold reason=" .. tostring(reason)
                .. " refineWait=" .. tostring(refineWait)
                .. " outstanding=" .. tostring(outstanding)
                .. " pendingPlant=" .. tostring(pendingPlant))
        end
        return false, msg
    end
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsHarvestActive
        and StockPiler2.Orchestrator.IsHarvestActive() == true
    then
        return Hold("harvest", T("brew.held_harvest"))
    end
    if pendingPlant then
        return Hold("pendingPlant", T("brew.held_planting"))
    end
    -- Seed buffer still filling: refine/plant can consume brew mats.
    if Grow and Grow.IsSeedBufferSatisfied and Grow.IsSeedBufferSatisfied() ~= true then
        return Hold("seedBuffer", T("brew.held_seed_buffer"))
    end
    -- refineWaitTicks is orch anti-spam only; do not gate Brew on it.
    if outstanding then
        return Hold("outstanding", T("brew.held_refine"))
    end
    Brew._lastHoldReason = nil
    return true
end

--- Same gate as Watch footer Brew button (enabled when click would do useful work).
--- Does not call MaybeNotifyBrewReady (that runs after Planner.Build / brew UI refresh).
function Brew.InvalidateCanBrewCache()
    Brew._canBrewFrame = nil
    Brew._canBrewCached = nil
end

function Brew.CanBrewNow()
    local frame = tonumber(StockPiler2.FrameCounter) or 0
    if frame > 0 and Brew._canBrewFrame == frame and Brew._canBrewCached ~= nil then
        return Brew._canBrewCached == true
    end
    local function finish(result)
        Brew._canBrewFrame = frame
        Brew._canBrewCached = result == true
        return Brew._canBrewCached
    end
    local Caps = StockPiler2.TradeSkillCaps
    if Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() ~= true then
        return finish(false)
    end
    -- Match TryBrewClick: busy (load job / performing / op-lock) → grey, not silent no-op.
    if Brew.IsBusy and Brew.IsBusy() == true then
        return finish(false)
    end
    local session = GetSession()
    local phase = session and session.phase
    if phase == "loading" then
        return finish(false)
    end
    -- Manual row Load: footer/macro stay grey; perform only via row Brew.
    if phase == "loaded" and Brew._loadSource == "manual" then
        return finish(false)
    end
    if phase == "loaded" then
        local deficit = tonumber(session.potionDeficit) or 0
        local craftable = tonumber(session.craftable) or 0
        local row = FindSessionRow()
        local boardOk = Brew.ValidateApothecaryPerform
            and Brew.ValidateApothecaryPerform() == true
        -- Prefer green Ready plan row when the snapshot is live.
        if RowIsReadyToCraft(row) and deficit > 0 and boardOk then
            return finish(true)
        end
        -- 0.4.131: while brew-session defers PlanRebuild (0.4.126), the plan row can be
        -- missing/stale after learn Invalidate — footer/macro stayed grey with apo still
        -- loaded. Session counters + board validity are enough to continue (row Brew already
        -- worked; /sp2 watchplan forced rebuild and woke footer). Do not require Ready here.
        if deficit > 0 and craftable > 0 and boardOk then
            return finish(true)
        end
        return finish(false)
    end
    if Brew.HasReadyToCraft and Brew.HasReadyToCraft() == true
        and Brew.CanStartBrewLoad and Brew.CanStartBrewLoad() == true
    then
        return finish(true)
    end
    return finish(false)
end

----------------------------------------------------------------
-- Bag / load steps
----------------------------------------------------------------

local function ItemValid(item)
    return type(item) == "table" and (tonumber(item.uniqueID) or 0) > 0
end

local function ItemMatchesSpec(item, spec)
    if type(spec) ~= "table" or not ItemValid(item) then
        return false
    end
    local cultType = tonumber(item.cultivationType) or 0
    local seedType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
    if cultType == seedType or cultType == sporeType then
        return false
    end
    return StockPiler2.MaterialSpec
        and StockPiler2.MaterialSpec.Matches
        and StockPiler2.MaterialSpec.Matches(item, spec) == true
end

local function InventoryBackpackType()
    if EA_Window_Backpack and EA_Window_Backpack.TYPE_INVENTORY then
        return EA_Window_Backpack.TYPE_INVENTORY
    end
    return 1
end

local function GetInventoryBagTable()
    local frame = tonumber(StockPiler2.FrameCounter) or 0
    if frame > 0
        and Brew._invBagFrame == frame
        and type(Brew._invBagCache) == "table"
    then
        return Brew._invBagCache
    end
    local bag = nil
    if type(EA_Window_Backpack) == "table"
        and type(EA_Window_Backpack.GetItemsFromBackpack) == "function"
    then
        local ok, result = StockPiler2.TryCallQuiet(
            "GetItemsFromBackpack.inv",
            EA_Window_Backpack.GetItemsFromBackpack,
            InventoryBackpackType()
        )
        if ok and type(result) == "table" then
            bag = result
        end
    end
    if bag == nil and DataUtils and type(DataUtils.GetItems) == "function" then
        local ok, result = StockPiler2.TryCallQuiet("DataUtils.GetItems", DataUtils.GetItems)
        if ok and type(result) == "table" then
            bag = result
        end
    end
    if frame > 0 then
        Brew._invBagFrame = frame
        Brew._invBagCache = bag
    end
    return bag
end

local function GetCraftingBagTableCached()
    local frame = tonumber(StockPiler2.FrameCounter) or 0
    if frame > 0
        and Brew._craftBagFrame == frame
        and type(Brew._craftBagCache) == "table"
    then
        return Brew._craftBagCache
    end
    local a = AA()
    local bag = a and a.GetCraftingBag and a.GetCraftingBag()
    if frame > 0 then
        Brew._craftBagFrame = frame
        Brew._craftBagCache = bag
    end
    return bag
end

--- Walk craft bag first, then inventory (craft-bag overflow).
--- 0.4.157: bag tables cached once per FrameCounter (IssueLoadStep used to re-fetch each step).
local function EachBrewSourceSlot(fn)
    local a = AA()
    local craftType = a and a.CraftingBackpackType and a.CraftingBackpackType() or 4
    local n = 0
    local craftBag = GetCraftingBagTableCached()
    if type(craftBag) == "table" then
        for slot, item in pairs(craftBag) do
            if type(slot) == "number" and ItemValid(item) then
                n = n + 1
                fn(slot, item, craftType)
            end
        end
    end
    local invType = InventoryBackpackType()
    local invBag = GetInventoryBagTable()
    if type(invBag) == "table" then
        for slot, item in pairs(invBag) do
            if type(slot) == "number" and ItemValid(item) then
                n = n + 1
                fn(slot, item, invType)
            end
        end
    end
    return n
end

function Brew.CountInCraftingBag(uniqueID, narrowName, spec)
    uniqueID = tonumber(uniqueID) or 0
    narrowName = ToNarrow(narrowName)
    local total = 0
    EachBrewSourceSlot(function(_, item)
        if type(spec) == "table" then
            if ItemMatchesSpec(item, spec) then
                total = total + (tonumber(item.stackCount) or 1)
            end
        else
            local uid = tonumber(item.uniqueID) or 0
            if uniqueID > 0 and uid == uniqueID then
                total = total + (tonumber(item.stackCount) or 1)
            elseif uniqueID <= 0 and narrowName ~= "" and ToNarrow(item.name) == narrowName then
                total = total + (tonumber(item.stackCount) or 1)
            end
        end
    end)
    return total
end

local function FindCraftingBagItem(uniqueID, narrowName, exclude, spec, role)
    uniqueID = tonumber(uniqueID) or 0
    narrowName = ToNarrow(narrowName)
    exclude = exclude or {}
    local a = AA()
    local craftType = a and a.CraftingBackpackType and a.CraftingBackpackType() or 4
    local bestSlot, bestItem, bestBagType = nil, nil, craftType
    local bestStack = 100000
    local bestIsCraft = false
    local seedType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local sporeType = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
    EachBrewSourceSlot(function(slot, item, backpackType)
        local key = tostring(backpackType) .. ":" .. tostring(slot)
        local used = tonumber(exclude[key]) or 0
        local stack = tonumber(item.stackCount) or 1
        if used > 0 and used >= stack then
            return
        end
        local cultType = tonumber(item.cultivationType) or 0
        if cultType == seedType or cultType == sporeType then
            return
        end
        local matched = false
        if type(spec) == "table" then
            matched = ItemMatchesSpec(item, spec)
        elseif uniqueID > 0 and (tonumber(item.uniqueID) or 0) == uniqueID then
            matched = true
        elseif uniqueID <= 0 and narrowName ~= "" and ToNarrow(item.name) == narrowName then
            matched = true
        end
        if matched then
            local isCraft = backpackType == craftType
            -- Prefer craft bag; within a bag prefer smaller stacks.
            local take = false
            if bestSlot == nil then
                take = true
            elseif isCraft and not bestIsCraft then
                take = true
            elseif isCraft == bestIsCraft
                and (stack < bestStack or (stack == bestStack and slot < bestSlot))
            then
                take = true
            end
            if take then
                bestSlot = slot
                bestStack = stack
                bestItem = item
                bestBagType = backpackType
                bestIsCraft = isCraft
            end
        end
    end)
    return bestSlot, bestItem, bestBagType
end

local function IsOptionalRole(role)
    return role == "extender" or role == "multiplier" or role == "stimulant"
end

local function AssignCraftingSlot(role, supplementSlot)
    if role == "container" then
        return (ApothecaryWindow and ApothecaryWindow.SLOT_CONTAINER) or 0, supplementSlot
    end
    if role == "main" then
        return (ApothecaryWindow and ApothecaryWindow.SLOT_DETERMINENT) or 1, supplementSlot
    end
    local maxSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT3) or 4
    if supplementSlot > maxSlot then
        return nil, supplementSlot
    end
    return supplementSlot, supplementSlot + 1
end

local function SortSpecSlots(slots)
    local sorted = {}
    for i = 1, #slots do
        sorted[i] = slots[i]
    end
    table.sort(sorted, function(a, b)
        local ra = LOAD_ROLE_ORDER[a.role] or 99
        local rb = LOAD_ROLE_ORDER[b.role] or 99
        if ra == rb then
            local ka, kb = "", ""
            if StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.Key then
                ka = tostring(StockPiler2.MaterialSpec.Key(a.spec) or "")
                kb = tostring(StockPiler2.MaterialSpec.Key(b.spec) or "")
            end
            return ka < kb
        end
        return ra < rb
    end)
    return sorted
end

local function BuildLoadSteps(recipe)
    local steps = {}
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" or #recipe.slots == 0 then
        return steps
    end
    local RS = StockPiler2.RecipeSpec
    local supplementSlot = (ApothecaryWindow and ApothecaryWindow.SLOT_INGREDIENT1) or 2
    local sorted = SortSpecSlots(recipe.slots)
    for i = 1, #sorted do
        local slot = sorted[i]
        if type(slot) == "table" and type(slot.spec) == "table" then
            local perCraft = tonumber(slot.perCraft) or 1
            if RS and RS.EffectiveSpecPerCraft then
                perCraft = RS.EffectiveSpecPerCraft(slot, recipe.slots)
            end
            if perCraft < 1 then
                perCraft = 1
            end
            local label = ""
            if StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.Label then
                label = ToNarrow(StockPiler2.MaterialSpec.Label(slot.spec))
            end
            for _ = 1, perCraft do
                local craftingSlot
                craftingSlot, supplementSlot = AssignCraftingSlot(slot.role, supplementSlot)
                if craftingSlot == nil then
                    return steps
                end
                steps[#steps + 1] = {
                    craftingSlot = craftingSlot,
                    uniqueID = 0,
                    narrowName = label,
                    role = slot.role,
                    optional = IsOptionalRole(slot.role),
                    spec = slot.spec,
                }
            end
        end
    end
    return steps
end

function Brew.MaterialsReadyInCraftingBag(recipe)
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return false
    end
    local RS = StockPiler2.RecipeSpec
    local any = false
    for i = 1, #recipe.slots do
        local slot = recipe.slots[i]
        if type(slot) == "table" and type(slot.spec) == "table" then
            any = true
            local need = tonumber(slot.perCraft) or 1
            if RS and RS.EffectiveSpecPerCraft then
                need = RS.EffectiveSpecPerCraft(slot, recipe.slots)
            end
            if need < 1 then
                need = 1
            end
            if Brew.CountInCraftingBag(0, "", slot.spec) < need then
                return false
            end
        end
    end
    return any
end

function Brew.DescribeMissingInCraftingBag(recipe)
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return L""
    end
    local names = {}
    local seen = {}
    local RS = StockPiler2.RecipeSpec
    for i = 1, #recipe.slots do
        local slot = recipe.slots[i]
        if type(slot) == "table" and type(slot.spec) == "table" then
            local need = tonumber(slot.perCraft) or 1
            if RS and RS.EffectiveSpecPerCraft then
                need = RS.EffectiveSpecPerCraft(slot, recipe.slots)
            end
            if Brew.CountInCraftingBag(0, "", slot.spec) < need then
                local label = ""
                if StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.NeedLabel then
                    label = ToNarrow(StockPiler2.MaterialSpec.NeedLabel(slot.spec))
                elseif StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.Label then
                    label = ToNarrow(StockPiler2.MaterialSpec.Label(slot.spec))
                end
                if label ~= "" and not seen[label] then
                    seen[label] = true
                    names[#names + 1] = towstring(label)
                end
            end
        end
    end
    if #names == 0 then
        return L""
    end
    local joined = names[1]
    for i = 2, #names do
        joined = joined .. L", " .. names[i]
    end
    return joined
end

----------------------------------------------------------------
-- Validate / board helpers
----------------------------------------------------------------

local function ItemMatchesStep(item, step)
    if not ItemValid(item) or type(step) ~= "table" then
        return false
    end
    if type(step.spec) == "table" then
        return ItemMatchesSpec(item, step.spec)
    end
    local uid = tonumber(step.uniqueID) or 0
    if uid > 0 then
        return (tonumber(item.uniqueID) or 0) == uid
    end
    return ToNarrow(item.name) == ToNarrow(step.narrowName)
end

local function SlotHasItem(step)
    if type(step) ~= "table" then
        return false
    end
    local a = AA()
    local item = a and a.GetSlottedItem and a.GetSlottedItem(step.craftingSlot)
    return ItemMatchesStep(item, step)
end

local function SlotHasWrongItem(step)
    if type(step) ~= "table" then
        return false
    end
    local a = AA()
    local item = a and a.GetSlottedItem and a.GetSlottedItem(step.craftingSlot)
    if item == nil then
        return false
    end
    return not ItemMatchesStep(item, step)
end

local function StepAlreadyOnBoard(step)
    return SlotHasItem(step)
end

local function CraftingStates()
    return GameData and GameData.CraftingStates or nil
end

local function StepSatisfied(step)
    if type(step) ~= "table" then
        return false
    end
    if StepAlreadyOnBoard(step) then
        return true
    end
    if step.optional == true then
        return false
    end
    if step.loadIssued ~= true then
        return false
    end
    local a = AA()
    local cs = CraftingStates()
    if cs == nil or not a then
        return false
    end
    local state = a.CraftingState()
    if step.role == "container" and state >= cs.ADDDETERMINENT then
        return true
    end
    if step.role == "main" and state >= cs.ADDINGREDIENT then
        return true
    end
    return false
end

local function AllStepsLoaded(job)
    if type(job) ~= "table" or type(job.steps) ~= "table" then
        return false
    end
    for i = 1, #job.steps do
        if not StepSatisfied(job.steps[i]) then
            return false
        end
    end
    return #job.steps > 0
end

local function ValidateAgainstLastLoad()
    local last = Brew._lastLoad
    if type(last) ~= "table" or type(last.steps) ~= "table" then
        return true
    end
    for i = 1, #last.steps do
        local step = last.steps[i]
        if type(step) == "table" and step.craftingSlot ~= nil then
            if SlotHasWrongItem(step) then
                return false, T("brew.wrong_slot")
            end
            if not SlotHasItem(step) then
                return false, T("brew.missing_loaded")
            end
        end
    end
    return true
end

function Brew.ValidateApothecaryPerform()
    local function Fail(msg)
        local state = nil
        if type(ApothecaryWindow) == "table" then
            state = ApothecaryWindow.currentState
        end
        LogBrew("validate fail msg=" .. ToNarrow(msg) .. " state=" .. tostring(state))
        return false, msg
    end
    if type(ApothecaryWindow) ~= "table" then
        return Fail(L"Apothecary window is not open.")
    end
    local state = ApothecaryWindow.currentState
    local validState = ApothecaryWindow.STATE_VALID_RECIPE
    local repeatState = ApothecaryWindow.STATE_SUCCESS_REPEAT
    if state ~= validState and state ~= repeatState then
        return Fail(L"Recipe is incomplete or invalid.")
    end
    if GameData and GameData.CraftingSuccessChance and GameData.CraftingStatus then
        local chance = tonumber(GameData.CraftingStatus.SuccessChance) or 0
        if chance == GameData.CraftingSuccessChance.LOW
            or chance == GameData.CraftingSuccessChance.INVALID
            or chance == GameData.CraftingSuccessChance.MEDIUM
        then
            return Fail(L"Recipe is not stable enough to brew.")
        end
    end
    if StockPiler2.BrewLearn and StockPiler2.BrewLearn.CaptureApothecaryMaterials then
        local slots = StockPiler2.BrewLearn.CaptureApothecaryMaterials()
        if type(slots) ~= "table" or #slots == 0 then
            return Fail(L"No materials in the Apothecary.")
        end
        local hasMain, hasContainer = false, false
        for i = 1, #slots do
            if slots[i].role == "main" then
                hasMain = true
            elseif slots[i].role == "container" then
                hasContainer = true
            end
        end
        if not hasMain or not hasContainer then
            return Fail(L"Missing container or main ingredient.")
        end
    end
    local ok, msg = ValidateAgainstLastLoad()
    if ok ~= true then
        return Fail(msg or L"Loaded materials do not match.")
    end
    if Brew._lastValidateOkState ~= state then
        Brew._lastValidateOkState = state
        LogBrew("validate ok state=" .. tostring(state))
    end
    return true
end

----------------------------------------------------------------
-- Job machine
----------------------------------------------------------------

local function RefreshBrewUi()
    return StockPiler2.BrewChrome.RefreshBrewUi()
end

function Brew.RefreshBrewUi()
    return StockPiler2.BrewChrome.RefreshBrewUi()
end

local function CloseOwnedSession()
    local a = AA()
    if not a then
        return
    end
    -- Ensure board is empty before tearing down stealth/owned apo.
    if a.ClearSlots then
        a.ClearSlots()
        if a.ServerHasItems and a.ServerHasItems() == true then
            LogBrew("close clear-retry ServerHasItems")
            a.ClearSlots()
            if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.Clear) == "function" then
                StockPiler2.TryCall("ApothecaryWindow.Clear", ApothecaryWindow.Clear)
            end
        end
    end
    if a.CloseSession then
        a.CloseSession(Brew)
    end
end

local function FailJob(message)
    local session = GetSession()
    LogBrew("fail " .. ToNarrow(message)
        .. " name=" .. ToNarrow(session.name)
        .. " key=" .. tostring(session.potionKey or ""))
    if message then
        Notify(message)
    end
    Brew._suppressBrewUi = true
    Brew._job = nil
    Brew._updateAccum = 0
    ClearSession()
    if Brew._brewOpenedApo == true
        or Brew._brewOwnedSession == true
        or Brew._brewApoStealth == true
    then
        CloseOwnedSession()
    end
    Brew._suppressBrewUi = false
    ArmBoardAdoptBlock()
    RefreshBrewUi()
end

local function BrewOwnsApoSession()
    return Brew._brewOwnedSession == true
        or Brew._brewApoStealth == true
        or Brew._brewOpenedApo == true
end

--- Stealth loads hide ApothecaryWindow; WindowOpen() is false but the session is still live.
local function ApoSessionAlive()
    local a = AA()
    if not a then
        return false
    end
    if a.WindowOpen and a.WindowOpen() == true then
        return true
    end
    if not BrewOwnsApoSession() then
        return false
    end
    if a.CraftingSkillType and a.TradeSkill and a.CraftingSkillType() == a.TradeSkill() then
        return true
    end
    if a.ServerHasItems and a.ServerHasItems() == true then
        return true
    end
    return false
end

--- Drop owned "loaded" session when the player changes the Apothecary board.
local function InvalidateOwnedBoard(reason, opts)
    opts = type(opts) == "table" and opts or {}
    local session = GetSession()
    local hadSession = session.phase == "loaded" or type(Brew._lastLoad) == "table"
    if not hadSession then
        return false
    end
    local detail = "board drift reason=" .. tostring(reason or "")
        .. " phase=" .. tostring(session.phase or "")
        .. " name=" .. ToNarrow(session.name)
        .. " owned=" .. tostring(BrewOwnsApoSession())
        .. " winOpen=" .. tostring(AA() and AA().WindowOpen and AA().WindowOpen())
    LogBrew(detail)
    if StockPiler2.Debug and StockPiler2.Debug.LogAlways then
        StockPiler2.Debug.LogAlways("brew| " .. detail)
    end
    Brew._lastLoad = nil
    ClearSession()
    if opts.notify ~= false then
        Notify(T("brew.apo_changed"))
    end
    RefreshBrewUi()
    if Brew.MaybeRefreshBrewTooltip then
        Brew.MaybeRefreshBrewTooltip(true)
    end
    return true
end

local function ShouldSkipBoardReconcile()
    local job = Brew._job
    if type(job) == "table" then
        local phase = tostring(job.phase or "")
        if phase == "reset" or phase == "open" or phase == "clear" then
            return true
        end
    end
    if IsPerformingState() then
        return true
    end
    local lockUntil = tonumber(Brew._brewOpLockUntil) or 0
    if lockUntil > 0 and NowSec() < lockUntil then
        return true
    end
    return false
end

local function LoadJobBoardDrifted(job)
    if type(job) ~= "table" or type(job.steps) ~= "table" then
        return false
    end
    if tostring(job.phase or "") ~= "load" then
        return false
    end
    local stepIndex = tonumber(job.stepIndex) or 1
    -- Steps already accepted must still match; empty/wrong means player cleared or swapped.
    for i = 1, math.min(stepIndex - 1, #job.steps) do
        local step = job.steps[i]
        if type(step) == "table" and step.optional ~= true then
            if SlotHasWrongItem(step) or not SlotHasItem(step) then
                return true
            end
        end
    end
    local current = job.steps[stepIndex]
    if type(current) == "table" and current.optional ~= true and SlotHasWrongItem(current) then
        return true
    end
    return false
end

function Brew.ReconcileBoardIntegrity(reason)
    if ShouldSkipBoardReconcile() then
        return
    end
    local job = Brew._job
    if type(job) == "table" and tostring(job.phase or "") == "load" then
        if LoadJobBoardDrifted(job) then
            FailJob(L"Apothecary changed during load.")
        end
        return
    end
    local session = GetSession()
    if session.phase ~= "loaded" or type(Brew._lastLoad) ~= "table" then
        return
    end
    if not ApoSessionAlive() then
        InvalidateOwnedBoard(reason or "window-closed")
        return
    end
    local ok, msg = ValidateAgainstLastLoad()
    if ok ~= true then
        InvalidateOwnedBoard(reason or ToNarrow(msg) or "board-mismatch")
    end
end

local function CompleteJob(message)
    local job = Brew._job
    Brew._job = nil
    Brew._updateAccum = 0
    if type(job) == "table" then
        local stepsCopy = {}
        if type(job.steps) == "table" then
            for i = 1, #job.steps do
                local step = job.steps[i]
                if type(step) == "table" then
                    stepsCopy[#stepsCopy + 1] = {
                        craftingSlot = step.craftingSlot,
                        uniqueID = step.uniqueID,
                        narrowName = step.narrowName,
                        role = step.role,
                        optional = step.optional,
                        spec = step.spec,
                    }
                end
            end
        end
        if #stepsCopy > 0 then
            Brew._lastLoad = {
                rowId = job.rowId,
                potionKey = job.potionKey,
                potionUid = tonumber(job.potionUid) or 0,
                steps = stepsCopy,
            }
        end
        local session = GetSession()
        session.phase = "loaded"
        SyncOrchPhase("loaded")
        session.rowId = job.rowId
        session.potionKey = job.potionKey or session.potionKey
        session.name = job.potionName or session.name
        session.potionUid = tonumber(job.potionUid) or session.potionUid
        if type(job.recipe) == "table"
            and StockPiler2.RecipeSpec
            and StockPiler2.RecipeSpec.RecipeOutputYield
        then
            local y = tonumber(StockPiler2.RecipeSpec.RecipeOutputYield(job.recipe, session.potionUid)) or 2
            session.recipeYield = math.max(1, math.floor(y + 0.5))
        elseif type(job.recipe) == "table" then
            session.recipeYield = math.max(1, tonumber(job.recipe.recipeYield) or 2)
        end
        LogBrew("loaded name=" .. ToNarrow(session.name)
            .. " key=" .. tostring(session.potionKey or ""))
        -- One chat line per new recipe/watch load (not every same-key reload).
        local loadKey = tostring(session.potionKey or "")
        if loadKey == "" then
            local uid = tonumber(session.potionUid) or 0
            if uid > 0 then
                loadKey = "uid:" .. tostring(uid)
            end
        end
        if loadKey ~= "" and loadKey ~= tostring(Brew._lastAnnouncedLoadKey or "") then
            Brew._lastAnnouncedLoadKey = loadKey
            local loadName = session.name
            if loadName == nil or loadName == L"" then
                loadName = T("brew.potion_fallback")
            end
            Notify(T("brew.load_recipe", { name = loadName }))
        end
        -- Avoid false board-drift right after our own load settles.
        Brew.ArmBrewOpLock(1.25)
    end
    if Brew.InvalidateCanBrewCache then
        Brew.InvalidateCanBrewCache()
    end
    if message then
        Notify(message)
    end
    RefreshBrewUi()
end

local function FinishLoadSuccess()
    -- Recipe-change chat is emitted in CompleteJob (brew.load_recipe).
    CompleteJob(nil)
    return true
end

local function SetPhase(job, phase, reason)
    job.phase = phase
    job.waitTicks = 0
    LogBrew("phase=" .. tostring(phase) .. " " .. tostring(reason or ""))
end

local function ClaimOwned()
    local a = AA()
    if a and a.WindowOpen and a.WindowOpen() then
        return false
    end
    Brew._idleForceClosed = false
    Brew._brewOwnedSession = true
    Brew._brewApoStealth = true
    if a and a.SetSoftLocks then
        a.SetSoftLocks(true)
    end
    return true
end

local function BeginLoadSteps(job, reason)
    ClaimOwned()
    SetPhase(job, "load", reason)
    job.stepIndex = 1
    job.usedBagSlots = job.usedBagSlots or {}
end

local function AdvanceCompletedSteps(job)
    while job.stepIndex <= #job.steps do
        local step = job.steps[job.stepIndex]
        if StepSatisfied(step) then
            job.stepIndex = job.stepIndex + 1
            job.waitTicks = 0
        else
            break
        end
    end
end

local function ConfirmStepBagUse(job, step)
    local bagSlot = step.bagSlot
    local bagType = step.bagType
    if bagSlot == nil or bagType == nil then
        return
    end
    local key = tostring(bagType) .. ":" .. tostring(bagSlot)
    job.usedBagSlots = job.usedBagSlots or {}
    job.usedBagSlots[key] = (tonumber(job.usedBagSlots[key]) or 0) + 1
    step.bagSlot = nil
    step.bagType = nil
end

local function IssueLoadStep(job, step)
    local a = AA()
    if type(step) ~= "table" or not a then
        return false
    end
    if StepAlreadyOnBoard(step) then
        step.loadIssued = true
        return true
    end
    if step.loadIssued == true then
        return true
    end
    if SlotHasWrongItem(step) then
        return false
    end
    local backpackSlot, item, backpackType = FindCraftingBagItem(
        step.uniqueID,
        step.narrowName,
        job.usedBagSlots,
        step.spec,
        step.role
    )
    if backpackSlot == nil or item == nil then
        return false
    end
    local addSlot = tonumber(step.craftingSlot) or 2
    if step.role ~= "container" and step.role ~= "main"
        and type(ApothecaryWindow) == "table"
        and type(ApothecaryWindow.WouldBePossibleToAdd) == "function"
    then
        local tryToAdd, craftingSlot
        local ok = StockPiler2.TryCallQuiet("ApothecaryWindow.WouldBePossibleToAdd", function()
            tryToAdd, craftingSlot = ApothecaryWindow.WouldBePossibleToAdd(item)
        end)
        if ok and tryToAdd == true and craftingSlot ~= nil then
            addSlot = craftingSlot
            step.craftingSlot = addSlot
        end
    end
    if type(ApothecaryWindow) == "table" and type(ApothecaryWindow.clientSlotList) == "table" then
        ApothecaryWindow.clientSlotList[addSlot] = {
            slot = backpackSlot,
            backpack = backpackType,
        }
    end
    step.uniqueID = tonumber(item.uniqueID) or step.uniqueID
    step.bagSlot = backpackSlot
    step.bagType = backpackType
    step.loadIssued = true
    if step.role == "container" then
        a.AddContainer(backpackSlot, backpackType)
    else
        a.AddItem(addSlot, backpackSlot, backpackType)
    end
    LogBrew("add role=" .. tostring(step.role or "")
        .. " craftSlot=" .. tostring(addSlot)
        .. " bag=" .. tostring(backpackType) .. ":" .. tostring(backpackSlot)
        .. " uid=" .. tostring(step.uniqueID or ""))
    return true
end

local function RunSetupPhases(job)
    local a = AA()
    if not a then
        return false
    end
    if job.phase == "reset" then
        if not job.didReset then
            job.didReset = true
            if not a.SessionReadyToFill() then
                a.ClearSlots()
            end
        end
        if a.SessionReadyToFill() then
            BeginLoadSteps(job, "ready")
        elseif a.ServerHasItems() then
            if job.waitTicks > CLEAR_WAIT_TICKS then
                FailJob(L"Could not clear the Apothecary window.")
            elseif job.waitTicks % 8 == 0 then
                a.ClearSlots()
            end
            return false
        else
            SetPhase(job, "open", "need session")
        end
    end
    if job.phase == "open" then
        if not a.OpenSession(Brew) then
            if job.waitTicks > OPEN_WAIT_TICKS then
                FailJob(L"Could not open the Apothecary.")
            end
            return false
        end
        if Brew._brewApoStealth == true then
            a.HideWindowOnly()
        end
        if a.SessionReadyToFill() then
            BeginLoadSteps(job, "session ready")
        else
            SetPhase(job, "clear", "session init")
        end
    end
    if job.phase == "clear" then
        if a.ServerHasItems() then
            if job.waitTicks > CLEAR_WAIT_TICKS then
                FailJob(L"Could not clear the Apothecary window.")
            elseif job.waitTicks % 8 == 0 then
                a.ClearSlots()
            end
            return false
        end
        if not a.SessionReadyToFill() then
            if job.waitTicks > OPEN_WAIT_TICKS then
                FailJob(L"Could not reset the Apothecary window.")
            end
            return false
        end
        BeginLoadSteps(job, "slots empty")
    end
    return job.phase == "load"
end

local function JobShouldRelease(job)
    local a = AA()
    local cs = CraftingStates()
    if cs and a then
        local state = a.CraftingState()
        if state == cs.PERFORMING or state == cs.SUCCESS
            or state == cs.SUCCESS_REPEAT or state == cs.FAIL
        then
            return true
        end
    end
    return AllStepsLoaded(job)
end

--- Engine-writing load primitive. Automated and manual load progression enters
--- through BrewExecutor.Tick; keep UI/tip policy outside the executor.
function Brew.Tick()
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Brew.Tick")
    end
    local job = Brew._job
    if type(job) ~= "table" then
        if Perf and Perf.End then
            Perf.End("Brew.Tick")
        end
        return
    end
    job.waitTicks = (tonumber(job.waitTicks) or 0) + 1
    job.totalTicks = (tonumber(job.totalTicks) or 0) + 1
    if job.totalTicks > 400 then
        FailJob(L"Load timed out.")
        if Perf and Perf.End then
            Perf.End("Brew.Tick")
        end
        return
    end
    if job.phase == "load" and JobShouldRelease(job) then
        FinishLoadSuccess()
        if Perf and Perf.End then
            Perf.End("Brew.Tick")
        end
        return
    end
    if job.phase == "reset" or job.phase == "open" or job.phase == "clear" then
        if not RunSetupPhases(job) then
            if Perf and Perf.End then
                Perf.End("Brew.Tick")
            end
            return
        end
    end
    if job.phase == "load" then
        AdvanceCompletedSteps(job)
        local step = job.steps[job.stepIndex]
        if step == nil then
            if AllStepsLoaded(job) then
                FinishLoadSuccess()
            else
                FailJob(L"Materials did not load into Apothecary slots.")
            end
            if Perf and Perf.End then
                Perf.End("Brew.Tick")
            end
            return
        end
        if StepSatisfied(step) then
            ConfirmStepBagUse(job, step)
            job.stepIndex = job.stepIndex + 1
            job.waitTicks = 0
            if Perf and Perf.End then
                Perf.End("Brew.Tick")
            end
            return
        end
        if not step.loadIssued then
            if SlotHasWrongItem(step) then
                FailJob(T("brew.wrong_slot"))
                if Perf and Perf.End then
                    Perf.End("Brew.Tick")
                end
                return
            end
            if not IssueLoadStep(job, step) then
                FailJob(L"Missing a recipe material in the crafting bag.")
                if Perf and Perf.End then
                    Perf.End("Brew.Tick")
                end
                return
            end
            job.waitTicks = 0
            if Perf and Perf.End then
                Perf.End("Brew.Tick")
            end
            return
        end
        if SlotHasWrongItem(step) then
            FailJob(T("brew.wrong_slot"))
            if Perf and Perf.End then
                Perf.End("Brew.Tick")
            end
            return
        end
        if job.waitTicks > STEP_WAIT_TICKS then
            FailJob(L"Timed out loading materials into the Apothecary.")
        end
    end
    if Perf and Perf.End then
        Perf.End("Brew.Tick")
    end
end

function Brew.OnUpdate(timeElapsed)
    timeElapsed = tonumber(timeElapsed) or 0
    if Brew.FlushJobTickIfDue then
        Brew.FlushJobTickIfDue()
    end
    if type(Brew._job) == "table" then
        Brew._updateAccum = (Brew._updateAccum or 0) + timeElapsed
        if Brew._updateAccum >= TICK_INTERVAL_SEC then
            Brew._updateAccum = Brew._updateAccum - TICK_INTERVAL_SEC
            if StockPiler2.BrewExecutor and StockPiler2.BrewExecutor.Tick then
                StockPiler2.BrewExecutor.Tick()
            end
        end
    end
    -- CanBrewNow greys during op-lock; re-enable footer + row chrome when lock expires.
    local lockUntil = tonumber(Brew._brewOpLockUntil) or 0
    if lockUntil > 0 and NowSec() >= lockUntil then
        Brew._brewOpLockUntil = 0
        RefreshBrewUi()
    end
    local session = GetSession()
    if session.phase == "loaded" then
        Brew._boardReconcileAccum = (Brew._boardReconcileAccum or 0) + timeElapsed
        if Brew._boardReconcileAccum >= BOARD_RECONCILE_INTERVAL_SEC then
            Brew._boardReconcileAccum = Brew._boardReconcileAccum - BOARD_RECONCILE_INTERVAL_SEC
            Brew.ReconcileBoardIntegrity("poll")
        end
    else
        Brew._boardReconcileAccum = 0
    end
    if Brew._pendingIdleClose and Brew.IsBusy() ~= true then
        local pendingReason = Brew._pendingIdleClose
        Brew.MaybeCloseBrewSessionIfIdle(pendingReason)
    end
    if Brew._pendingCannotContinueClear and Brew.IsBusy() ~= true then
        local pendingReason = Brew._pendingCannotContinueClear
        Brew._pendingCannotContinueClear = nil
        Brew.MaybeClearLoadedIfCannotContinue(pendingReason)
    end
end

function Brew.OnCraftingUpdated()
    if Brew.InvalidateCanBrewCache then
        Brew.InvalidateCanBrewCache()
    end
    -- Post-clear settle: ignore residual ClearSlots craft updates so we do not
    -- re-adopt a still-matching board and flip Load→Brew→Load on the row chip.
    if BoardAdoptBlocked() then
        return
    end
    if type(Brew._job) == "table" then
        Brew.ReconcileBoardIntegrity("crafting-update")
        -- 0.4.157: coalesce Tick to once per frame (was Brew.Tick xN per craft-slot storm).
        Brew._jobTickDue = true
        return
    end
    Brew.ReconcileBoardIntegrity("crafting-update")
    if Brew.TryAdoptMatchingWatchFromBoard then
        Brew.TryAdoptMatchingWatchFromBoard()
    end
    RefreshBrewUi()
end

--- Drain coalesced load Tick (call from OnUpdate / UPDATE_PROCESSED).
function Brew.FlushJobTickIfDue()
    if Brew._jobTickDue ~= true then
        return false
    end
    Brew._jobTickDue = false
    if type(Brew._job) ~= "table" then
        return false
    end
    if StockPiler2.BrewExecutor and StockPiler2.BrewExecutor.Tick then
        StockPiler2.BrewExecutor.Tick()
    elseif Brew.Tick then
        Brew.Tick()
    end
    return true
end

----------------------------------------------------------------
-- Begin / click / perform / refresh
----------------------------------------------------------------

local function RowRecipe(row)
    if type(row) ~= "table" then
        return nil
    end
    if type(row.specRecipe) == "table" and type(row.specRecipe.slots) == "table" and #row.specRecipe.slots > 0 then
        return row.specRecipe
    end
    if type(row.recipe) == "table" and type(row.recipe.slots) == "table" and #row.recipe.slots > 0 then
        return row.recipe
    end
    return nil
end

local function BoardMatchesRecipe(recipe)
    if type(recipe) ~= "table" then
        return false
    end
    if not ApoSessionAlive() then
        return false
    end
    if type(ApothecaryWindow) == "table" then
        local state = ApothecaryWindow.currentState
        local validState = ApothecaryWindow.STATE_VALID_RECIPE
        local repeatState = ApothecaryWindow.STATE_SUCCESS_REPEAT
        if state ~= validState and state ~= repeatState then
            return false
        end
    end
    local steps = BuildLoadSteps(recipe)
    if #steps == 0 then
        return false
    end
    for i = 1, #steps do
        local step = steps[i]
        if type(step) == "table" and step.optional ~= true then
            if not SlotHasItem(step) then
                return false
            end
        end
    end
    return true
end

--- If the Apothecary already holds this watch's recipe, adopt loaded session + _lastLoad.
local function AdoptLoadedFromBoard(row)
    if type(row) ~= "table" then
        return false
    end
    local recipe = RowRecipe(row)
    if not BoardMatchesRecipe(recipe) then
        return false
    end
    local steps = BuildLoadSteps(recipe)
    if #steps == 0 then
        return false
    end
    -- Stamp uniqueIDs from the live board for later ValidateAgainstLastLoad.
    for i = 1, #steps do
        local step = steps[i]
        if type(step) == "table" then
            local a = AA()
            local item = a and a.GetSlottedItem and a.GetSlottedItem(step.craftingSlot)
            if ItemValid(item) then
                step.uniqueID = tonumber(item.uniqueID) or 0
                step.narrowName = ToNarrow(item.name)
            end
        end
    end
    SetSessionFromRow(row, "loaded")
    Brew._lastLoad = {
        rowId = row.id,
        potionKey = row.potionKey,
        potionUid = tonumber(row.uniqueID) or 0,
        steps = steps,
    }
    Brew._loadSource = "manual"
    LogBrew("adopt-loaded " .. ToNarrow(row.name) .. " source=manual")
    return true
end

--- If the Apothecary already holds a watched recipe, adopt it into the brew session.
function Brew.TryAdoptMatchingWatchFromBoard()
    if Brew._suppressBrewUi == true or BoardAdoptBlocked() then
        return false
    end
    if type(Brew._job) == "table" then
        return false
    end
    if not ApoSessionAlive() then
        return false
    end
    local session = GetSession()
    if session.phase == "loading" then
        return false
    end
    if session.phase == "loaded" and type(Brew._lastLoad) == "table" then
        local ok = ValidateAgainstLastLoad()
        if ok == true then
            return false
        end
    end
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return false
    end
    local bestDeficit = nil
    local bestAny = nil
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" and BoardMatchesRecipe(RowRecipe(row)) then
            if bestAny == nil then
                bestAny = row
            end
            if (tonumber(row.potionDeficit) or 0) > 0 then
                if bestDeficit == nil
                    or (tonumber(row.potionDeficit) or 0) > (tonumber(bestDeficit.potionDeficit) or 0)
                then
                    bestDeficit = row
                end
            end
        end
    end
    local pick = bestDeficit or bestAny
    if pick == nil then
        return false
    end
    if session.phase == "loaded" and RowMatchesSession(pick, session) then
        return false
    end
    return AdoptLoadedFromBoard(pick) == true
end

function Brew.BeginForRow(row, opts)
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Brew.BeginForRow")
    end
    local function done(result)
        if Perf and Perf.End then
            Perf.End("Brew.BeginForRow")
        end
        return result
    end
    opts = type(opts) == "table" and opts or {}
    local source = opts.source
    if source ~= "manual" and source ~= "auto" then
        source = "auto"
    end
    -- Intentional load supersedes post-clear adopt settle window.
    ClearBoardAdoptBlock()
    local a = AA()
    if a and a.IsApothecary and not a.IsApothecary() then
        Notify(T("brew.load_apo_only"))
        return done(false)
    end
    -- Footer/auto Ready flow respects grow holds; manual row Load does not.
    if source ~= "manual" then
        local ok, msg = Brew.CanStartBrewLoad()
        if ok ~= true then
            Notify(msg or T("brew.held_autogrow_busy"))
            return done(false)
        end
    end
    -- Block only real load/perform work — not post-load op-lock (allows switch Load).
    if type(Brew._job) == "table" then
        Notify(T("brew.already_loading"))
        return done(false)
    end
    if IsPerformingState() then
        Notify(T("brew.held_crafting"))
        return done(false)
    end
    if type(row) ~= "table" then
        return done(false)
    end
    local recipe = RowRecipe(row)
    if type(recipe) ~= "table" then
        Notify(T("brew.no_recipe"))
        return done(false)
    end
    if (tonumber(row.craftable) or 0) <= 0 and row.canLoad ~= true then
        Notify(T("brew.nothing_craftable"))
        return done(false)
    end
    if not Brew.MaterialsReadyInCraftingBag(recipe) then
        local missing = Brew.DescribeMissingInCraftingBag(recipe)
        if missing ~= nil and missing ~= L"" then
            Notify(T("brew.load_missing", { name = missing }))
        else
            Notify(T("brew.move_mats"))
        end
        Brew._lastLoad = nil
        ClearSession()
        RefreshBrewUi()
        return done(false)
    end
    local steps = BuildLoadSteps(recipe)
    if #steps == 0 then
        Notify(T("brew.no_steps"))
        return done(false)
    end
    local session = GetSession()
    if session.phase == "loaded" or session.phase == "loading" then
        Brew.ClearBrewOpLock()
    end
    Brew._loadSource = source
    SetSessionFromRow(row, "loading")
    Brew._job = {
        phase = "reset",
        steps = steps,
        stepIndex = 1,
        waitTicks = 0,
        totalTicks = 0,
        usedBagSlots = {},
        recipe = recipe,
        potionKey = row.potionKey,
        rowId = row.id,
        potionName = row.name,
        potionUid = tonumber(row.uniqueID) or 0,
    }
    LogBrew("begin-load " .. ToNarrow(row.name)
        .. " source=" .. tostring(source)
        .. " steps=" .. tostring(#steps))
    if StockPiler2.BrewExecutor and StockPiler2.BrewExecutor.Tick then
        StockPiler2.BrewExecutor.Tick()
    end
    RefreshBrewUi()
    return done(true)
end

--- Row craft button: Idle / Load / Brew (row performs when loaded).
function Brew.GetRowCraftUiState(row)
    if type(row) ~= "table" then
        return "idle"
    end
    local a = AA()
    if a and a.IsApothecary and not a.IsApothecary() then
        return "idle"
    end
    local session = GetSession()
    if RowMatchesSession(row, session) then
        if session.phase == "loaded" then
            return "loaded"
        end
        if session.phase == "loading" then
            return "loading"
        end
    end
    if RowCanPrematureLoad(row) then
        return "load"
    end
    return "idle"
end

--- Watch-row click: Load starts a manual load; Brew performs this loaded recipe.
--- Returns "go" when FirePerform should run (loaded + valid).
function Brew.OnRowCraftClick(row)
    local a = AA()
    if a and a.IsApothecary and not a.IsApothecary() then
        Notify(T("brew.load_apo_only"))
        return false
    end
    if type(row) ~= "table" then
        return false
    end
    local state = Brew.GetRowCraftUiState(row)
    if state == "loading" then
        Notify(T("brew.is_loading"))
        LogBrew("row click blocked reason=loading")
        return false
    end
    if state == "load" then
        if type(Brew._job) == "table" then
            Notify(T("brew.already_loading"))
            return false
        end
        if IsPerformingState() then
            Notify(T("brew.held_crafting"))
            return false
        end
        -- Op-lock after a prior load must not block switch-Load / new Load.
        return Brew.BeginForRow(row, { source = "manual" }) == true
    end
    if state == "loaded" then
        if type(Brew._job) == "table" then
            Notify(T("brew.already_loading"))
            return false
        end
        if IsPerformingState() then
            Notify(T("brew.held_crafting"))
            return false
        end
        -- Post-load op-lock is for board-drift only; row Brew must respond immediately.
        if Brew.ClearBrewOpLock then
            Brew.ClearBrewOpLock()
        end
        local ok = Brew.ValidateApothecaryPerform()
        if ok == true then
            LogBrew("row click phase=loaded result=go name=" .. ToNarrow(row.name)
                .. " source=" .. tostring(Brew._loadSource or ""))
            LogBrew("perform " .. ToNarrow(row.name))
            return "go"
        end
        LogBrew("row validate fail; not performing")
        Notify(T("brew.not_ready"))
        return false
    end
    Notify(T("brew.nothing_row"))
    return false
end

--- Row R-click: unload if this watch is the loaded/loading session.
function Brew.OnRowCraftRightClick(row)
    if type(row) ~= "table" then
        return false
    end
    local session = GetSession()
    if not RowMatchesSession(row, session) then
        return false
    end
    if session.phase ~= "loading" and session.phase ~= "loaded"
        and type(Brew._job) ~= "table"
        and type(Brew._lastLoad) ~= "table"
    then
        return false
    end
    return Brew.ClearLoadedSession() == true
end

--- Cancel load job and tear down owned apo session (footer R-click).
--- opts.notifyMsg: optional wstring instead of brew.load_cleared
--- opts.silent: skip chat notify
function Brew.ClearLoadedSession(opts)
    opts = type(opts) == "table" and opts or nil
    local hadJob = type(Brew._job) == "table"
    local session = GetSession()
    local hadSession = session.phase == "loading" or session.phase == "loaded"
        or type(Brew._lastLoad) == "table"
        or BrewOwnsApoSession()
    -- Hold RefreshBrewUi + board adopt while ClearSlots fires craft updates, so the
    -- row chip does not flip Brew/Idle mid-teardown before settling on Load.
    Brew._suppressBrewUi = true
    Brew._job = nil
    Brew._updateAccum = 0
    Brew._lastLoad = nil
    Brew._loadSource = nil
    Brew._pendingCannotContinueClear = nil
    Brew.ClearBrewOpLock()
    ClearSession()
    if hadSession or hadJob then
        CloseOwnedSession()
        if not (opts and opts.silent == true) then
            Notify((opts and opts.notifyMsg) or T("brew.load_cleared"))
        end
        LogBrew("clear-loaded-session")
    end
    Brew._suppressBrewUi = false
    ArmBoardAdoptBlock()
    RefreshBrewUi()
    if Brew.MaybeRefreshBrewTooltip then
        Brew.MaybeRefreshBrewTooltip(true)
    end
    return true
end

--- Auto footer load: clear when the session cannot continue brewing.
--- Do not treat a missing plan row right after invalidate as "not Ready"
--- (0.4.104 false-cleared every brew). Re-check on PLAN_UPDATED.
function Brew.MaybeClearLoadedIfCannotContinue(reason)
    reason = tostring(reason or "")
    local session = GetSession()
    if session.phase ~= "loaded" then
        Brew._pendingCannotContinueClear = nil
        return false
    end
    if Brew._loadSource == "manual" then
        return false
    end
    if type(Brew._job) == "table" or IsPerformingState() then
        Brew._pendingCannotContinueClear = (reason ~= "" and reason) or "busy"
        return false
    end
    local lockUntil = tonumber(Brew._brewOpLockUntil) or 0
    if lockUntil > 0 and NowSec() < lockUntil then
        Brew._pendingCannotContinueClear = (reason ~= "" and reason) or "op-lock"
        return false
    end
    local deficit = tonumber(session.potionDeficit) or 0
    local craftLeft = tonumber(session.craftable) or 0
    if deficit <= 0 or craftLeft <= 0 then
        Brew._pendingCannotContinueClear = nil
        LogBrew("clear cannot-continue reason=" .. reason
            .. " deficit=" .. tostring(deficit)
            .. " craftable=" .. tostring(craftLeft))
        Brew.ClearLoadedSession()
        return true
    end
    local row = FindSessionRow()
    if type(row) ~= "table" then
        -- Stale/empty plan after invalidate — wait for rebuild unless this
        -- is already a fresh PLAN_UPDATED (orphaned session).
        if reason == "plan-updated" then
            Brew._pendingCannotContinueClear = nil
            LogBrew("clear cannot-continue reason=plan-updated orphan-row")
            Brew.ClearLoadedSession()
            return true
        end
        Brew._pendingCannotContinueClear = (reason ~= "" and reason) or "await-plan-row"
        return false
    end
    Brew._pendingCannotContinueClear = nil
    if RowIsReadyToCraft(row) == true then
        local boardOk = Brew.ValidateApothecaryPerform and Brew.ValidateApothecaryPerform() == true
        if boardOk then
            return false
        end
        LogBrew("clear cannot-continue reason=" .. reason
            .. " boardOk=false status=" .. tostring(row.statusKey))
    else
        LogBrew("clear cannot-continue reason=" .. reason
            .. " planReady=false status=" .. tostring(row.statusKey)
            .. " rowCraftable=" .. tostring(row.craftable))
    end
    Brew.ClearLoadedSession()
    return true
end

function Brew.RegisterEventHandlers()
    if Brew._eventsRegistered == true then
        return
    end
    local B = StockPiler2.EventBus
    local E = StockPiler2.Events
    if not B or not E or not E.PLAN_UPDATED then
        return
    end
    Brew._busTokens = Brew._busTokens or {}
    local token = B.Subscribe(E.PLAN_UPDATED, function()
        Brew.MaybeClearLoadedIfCannotContinue("plan-updated")
    end)
    if token then
        Brew._busTokens[#Brew._busTokens + 1] = token
    end
    Brew._eventsRegistered = true
end

function Brew.UnregisterEventHandlers()
    local B = StockPiler2.EventBus
    local tokens = Brew._busTokens
    if B and B.Unsubscribe and type(tokens) == "table" then
        for i = 1, #tokens do
            B.Unsubscribe(tokens[i])
        end
    end
    Brew._busTokens = nil
    Brew._eventsRegistered = false
end

function Brew.MaybeCloseBrewSessionIfIdle(reason)
    reason = tostring(reason or "")
    if Brew.IsBusy() then
        Brew._pendingIdleClose = (reason ~= "" and reason) or "busy"
        LogBrew("close deferred busy reason=" .. tostring(Brew._pendingIdleClose))
        return
    end
    Brew._pendingIdleClose = nil
    local session = GetSession()
    if session.phase == "loading" or session.phase == "loaded" then
        return
    end
    -- Coalesced plan rebuild — avoid sync BuildPlan mid/after brew storms.
    if StockPiler2.Planner and StockPiler2.Planner.InvalidatePlanCache then
        StockPiler2.Planner.InvalidatePlanCache()
    elseif StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Invalidate then
        StockPiler2.PlanSnapshot.Invalidate()
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueuePlanRebuild then
        StockPiler2.Scheduler.EnqueuePlanRebuild()
    end
    local ready = nil
    if StockPiler2.Planner and StockPiler2.Planner.GetOrBuild then
        StockPiler2.Planner.GetOrBuild({ refresh = false })
    end
    ready = Brew.PickReadyWatch()
    if ready ~= nil then
        LogBrew("close skip ready=" .. ToNarrow(ready.name))
        return
    end
    if BrewOwnsApoSession() then
        LogBrew("close idle " .. reason)
        CloseOwnedSession()
    end
end

--- After a successful brew: advance session counters (every brew is assumed to
--- progress the target; Potent/crit rates are not modeled). When nothing is
--- left to brew but phase would stay loaded, clear the apo load so AutoGrow
--- is not blocked (footer R-click equivalent).
function Brew.RefreshSessionAfterBrew()
    -- 0.4.126: move PlanRebuild / UiFlush off the craft Inv.ApplySlots hitch.
    local Sch = StockPiler2.Scheduler
    if Sch and Sch.SkipPlanThisFrame then
        Sch.SkipPlanThisFrame()
    end
    if Sch and Sch.SkipUiThisFrame then
        Sch.SkipUiThisFrame()
    end
    local session = GetSession()
    if session.phase ~= "loaded" then
        Brew.MaybeCloseBrewSessionIfIdle("after brew (no loaded session)")
        RefreshBrewUi()
        return
    end
    local yieldAdd = math.max(1, tonumber(session.recipeYield) or 2)
    if session.potionHave ~= nil then
        session.potionHave = (tonumber(session.potionHave) or 0) + yieldAdd
    end
    if session.potionMin ~= nil then
        session.potionDeficit = math.max(0, (tonumber(session.potionMin) or 0) - (tonumber(session.potionHave) or 0))
    elseif session.potionDeficit ~= nil then
        session.potionDeficit = math.max(0, (tonumber(session.potionDeficit) or 0) - yieldAdd)
    end
    if session.craftable ~= nil then
        session.craftable = math.max(0, (tonumber(session.craftable) or 0) - 1)
    end
    -- 0.4.126: do NOT wipe PlanSnapshot while session stays loaded — deferred rebuild
    -- would leave a nil snapshot and MaybeClearLoadedIfCannotContinue could false-clear.
    -- Arm a held rebuild so Status catches up when the session clears.
    if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueuePlanRebuild then
        StockPiler2.Scheduler.EnqueuePlanRebuild()
    end
    local stillValid = Brew.ValidateApothecaryPerform() == true
    local craftLeft = tonumber(session.craftable) or 0
    if session.potionDeficit ~= nil and (tonumber(session.potionDeficit) or 0) <= 0 then
        -- Auto footer sessions stop at target. Manual row loads may overstock.
        if Brew._loadSource == "manual" and craftLeft > 0 and stillValid then
            session.phase = "loaded"
            SyncOrchPhase("loaded")
        else
            ClearSession()
        end
    else
        if stillValid then
            session.phase = "loaded"
            SyncOrchPhase("loaded")
        else
            Brew._lastLoad = nil
            ClearSession()
        end
    end
    local after = GetSession()
    LogBrew("after-brew deficit=" .. tostring(after.potionDeficit)
        .. " craftable=" .. tostring(after.craftable)
        .. " phase=" .. tostring(after.phase or "idle"))
    if after.phase == "loaded" or after.phase == "loading" then
        -- Prefer plan-ready + board validity over session craftable alone.
        -- Plan may still be stale here; PLAN_UPDATED re-checks.
        if Brew.MaybeClearLoadedIfCannotContinue("after-brew") then
            return
        end
        RefreshBrewUi()
        return
    end
    Brew.MaybeCloseBrewSessionIfIdle("after brew nothing ready")
    RefreshBrewUi()
end

--- Returns "go" to fire PerformCrafting, or "blocked" to swallow the click.
function Brew.TryBrewClick()
    local session = GetSession()
    local phase = tostring(session.phase or "idle")
    local a = AA()
    if a and a.IsApothecary and not a.IsApothecary() then
        Notify(T("brew.apo_only"))
        LogBrew("click phase=" .. phase .. " result=blocked reason=not-apo")
        return "blocked"
    end
    if Brew.IsBusy() then
        LogBrew("click phase=" .. phase .. " result=blocked reason=busy")
        return "blocked"
    end

    if session.phase == "loaded" then
        -- Manual row sessions: footer must not perform; use row Brew.
        if Brew._loadSource == "manual" then
            Notify(T("brew.use_row_button"))
            LogBrew("click phase=" .. phase .. " result=blocked reason=manual-session")
            return "blocked"
        end
        local deficitOk = (tonumber(session.potionDeficit) or 0) > 0
        local craftOk = (tonumber(session.craftable) or 0) > 0
        local row = FindSessionRow()
        -- Prefer plan Ready; else session counters (plan may be invalidated while
        -- brew-session defers rebuild — same as CanBrewNow 0.4.131).
        local canContinue = deficitOk and (
            RowIsReadyToCraft(row)
            or craftOk
        )
        if canContinue then
            local ok = Brew.ValidateApothecaryPerform()
            if ok == true then
                LogBrew("click phase=" .. phase .. " result=go name="
                    .. ToNarrow((row and row.name) or session.name)
                    .. " source=" .. tostring(Brew._loadSource or ""))
                LogBrew("perform " .. ToNarrow((row and row.name) or session.name))
                return "go"
            end
            LogBrew("validate fail; pick new")
            InvalidateOwnedBoard("click-validate-fail", { notify = false })
            -- Keep board mats; next BeginForRow reloads in place.
        else
            LogBrew("click skip loaded-not-ready name="
                .. ToNarrow((row and row.name) or session.name)
                .. " deficit=" .. tostring(session.potionDeficit)
                .. " craftable=" .. tostring(session.craftable)
                .. " shared=" .. tostring(row and row.craftableShared == true)
                .. " status=" .. tostring(row and row.statusKey)
                .. " source=" .. tostring(Brew._loadSource or ""))
            -- Greying out without a click left sessions stuck; clear when we
            -- know the loaded watch is no longer Ready.
            if Brew.MaybeClearLoadedIfCannotContinue("loaded-not-ready") then
                return "blocked"
            end
        end
    end

    local nextRow = Brew.PickReadyWatch()
    if type(nextRow) == "table" and AdoptLoadedFromBoard(nextRow) then
        local ok = Brew.ValidateApothecaryPerform()
        if ok == true then
            LogBrew("click phase=adopted result=go name=" .. ToNarrow(nextRow.name))
            LogBrew("perform " .. ToNarrow(nextRow.name))
            return "go"
        end
        Brew._lastLoad = nil
        ClearSession()
    end

    if type(nextRow) == "table" then
        LogBrew("click phase=" .. phase .. " result=blocked reason=begin-load")
        if StockPiler2.BrewExecutor and StockPiler2.BrewExecutor.BeginLoad then
            StockPiler2.BrewExecutor.BeginLoad(nextRow, { source = "auto" })
        end
        return "blocked"
    end

    Brew._lastLoad = nil
    ClearSession()
    if Brew._brewOwnedSession == true or Brew._brewApoStealth == true then
        if Brew._idleForceClosed ~= true then
            Brew._idleForceClosed = true
            CloseOwnedSession()
        end
    end
    Notify(T("brew.none_ready"))
    LogBrew("click phase=" .. phase .. " result=blocked reason=none-ready")
    RefreshBrewUi()
    return "blocked"
end

--- Thin perform primitive. BrewExecutor owns the automated lane; footer, macro,
--- and row buttons may call this directly only for their user-initiated lane.
function Brew.FirePerform()
    local a = AA()
    if not a or not a.Perform then
        return false
    end
    if StockPiler2.BrewLearn and StockPiler2.BrewLearn.BeginPendingCraft then
        StockPiler2.BrewLearn.BeginPendingCraft()
    end
    local session = GetSession()
    LogBrew("FirePerform deficit=" .. tostring(session.potionDeficit)
        .. " craftable=" .. tostring(session.craftable)
        .. " name=" .. ToNarrow(session.name))
    local ok = a.Perform()
    if ok then
        Brew.ArmBrewOpLock(1.25)
        LogBrew("PerformCrafting fired")
    end
    return ok
end

----------------------------------------------------------------
-- Live tooltip
----------------------------------------------------------------

local function FormatTooltipIcon(iconNum)
    iconNum = tonumber(iconNum) or 0
    if iconNum <= 0 then
        return L""
    end
    return towstring(string.format("<icon%05d>", iconNum))
end

local function ResolveIconNum(uid, fallbackIcon, sample)
    local icon = tonumber(fallbackIcon) or 0
    if icon > 0 then
        return icon
    end
    if type(sample) == "table" then
        icon = tonumber(sample.iconNum) or 0
        if icon > 0 then
            return icon
        end
    end
    uid = tonumber(uid) or 0
    if uid > 0 and StockPiler2.Items and StockPiler2.Items.AsItemData then
        local item = StockPiler2.Items.AsItemData(uid)
        if type(item) == "table" then
            return tonumber(item.iconNum) or 0
        end
    end
    return 0
end

local function FindSampleMatchingSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec or not StockPiler2.MaterialSpec.Matches then
        return nil
    end
    local MS = StockPiler2.MaterialSpec
    local found = nil
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if found ~= nil or type(item) ~= "table" then
                return
            end
            if StockPiler2.Inventory.CanUseCraftingItem
                and not StockPiler2.Inventory.CanUseCraftingItem(item)
            then
                return
            end
            if MS.Matches(item, spec) then
                found = item
            end
        end)
    end
    return found
end

local function PotionIconNum(row, session)
    if type(row) == "table" then
        local icon = ResolveIconNum(row.uniqueID or row.potionUid, row.iconNum, row.itemData)
        if icon > 0 then
            return icon
        end
    end
    if type(session) == "table" then
        return ResolveIconNum(session.potionUid, nil, nil)
    end
    return 0
end

local function RecipeForTooltip(row, session)
    if type(row) == "table" then
        local recipe = RowRecipe(row)
        if type(recipe) == "table" then
            return recipe
        end
    end
    if type(Brew._job) == "table" and type(Brew._job.recipe) == "table" then
        return Brew._job.recipe
    end
    if type(session) == "table" and session.potionKey ~= nil then
        local planRow = FindSessionRow()
        if type(planRow) == "table" then
            return RowRecipe(planRow)
        end
    end
    return nil
end

local function AppendPotionLine(body, prefix, row, session)
    local name = (row and row.name) or (session and session.name)
    local have = row and tonumber(row.potionHave) or (session and tonumber(session.potionHave))
    local target = row and (tonumber(row.potionMin) or tonumber(row.target))
        or (session and tonumber(session.potionMin))
    local icon = FormatTooltipIcon(PotionIconNum(row, session))
    local line
    if name ~= nil and name ~= L"" and have ~= nil and target ~= nil then
        line = T("brew.tip.potion_have_target", {
            prefix = prefix or L"",
            name = name,
            have = tostring(have),
            target = tostring(target),
        })
    elseif name ~= nil and name ~= L"" then
        line = T("brew.tip.potion_name_dot", {
            prefix = prefix or L"",
            name = name,
        })
    else
        line = prefix
    end
    if icon ~= L"" then
        body(T("grow.tip.icon_name", { icon = icon, name = line }))
    else
        body(line)
    end
end

local function IngredientStockDigest(recipe)
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" then
        return ""
    end
    local RS = StockPiler2.RecipeSpec
    local parts = {}
    local sorted = SortSpecSlots(recipe.slots)
    for i = 1, #sorted do
        local slot = sorted[i]
        if type(slot) == "table" and type(slot.spec) == "table" then
            local have = 0
            if RS and RS.CountItemsMatchingSpec then
                have = tonumber(RS.CountItemsMatchingSpec(slot.spec)) or 0
            end
            local key = ""
            if StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.Key then
                key = tostring(StockPiler2.MaterialSpec.Key(slot.spec) or "")
            end
            parts[#parts + 1] = key .. ":" .. tostring(have)
        end
    end
    return table.concat(parts, ",")
end

--- Success / yield / Apo skill-up lines for brew tooltips.
local function AppendBrewRateLines(body, recipe, potionUid)
    if type(body) ~= "function" or type(recipe) ~= "table" then
        return
    end
    local RS = StockPiler2.RecipeSpec
    potionUid = tonumber(potionUid) or tonumber(recipe.outputUid) or tonumber(recipe.activeOutcomeUid) or 0
    local attempts = tonumber(recipe.brewAttempts) or 0
    if attempts > 0 then
        local rate = nil
        local successes = tonumber(recipe.brewSuccesses) or 0
        if RS and RS.OutcomeSuccessRate then
            local r, ok, att = RS.OutcomeSuccessRate(recipe, potionUid)
            rate = r
            if ok ~= nil then
                successes = ok
            end
            if att and att > 0 then
                attempts = att
            end
        elseif RS and RS.RecipeSuccessRate then
            rate = RS.RecipeSuccessRate(recipe)
        end
        local pct = math.floor((rate or (successes / math.max(1, attempts))) * 100 + 0.5)
        local yield = 0
        if RS and RS.RecipeOutputYield then
            yield = tonumber(RS.RecipeOutputYield(recipe, potionUid)) or 0
        end
        local line = T("brew.tip.success", {
            pct = tostring(pct),
            ok = tostring(successes),
            att = tostring(attempts),
        })
        if yield > 0 then
            local rounded = math.floor(yield * 10 + 0.5) / 10
            line = line .. T("brew.tip.yield", { yield = string.format("%.1f", rounded) })
        end
        body(line)
    end
    if RS and RS.FormatApoSkillUpLine then
        local apoLine = RS.FormatApoSkillUpLine(recipe)
        if apoLine and apoLine ~= L"" then
            body(apoLine)
        end
    end
end

local function AppendIngredientStockLines(body, recipe)
    AppendBrewRateLines(body, recipe)
    if type(recipe) ~= "table" or type(recipe.slots) ~= "table" or #recipe.slots == 0 then
        return
    end
    local RS = StockPiler2.RecipeSpec
    local MS = StockPiler2.MaterialSpec
    if RS and RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end
    local sorted = SortSpecSlots(recipe.slots)
    for i = 1, #sorted do
        local slot = sorted[i]
        if type(slot) == "table" and type(slot.spec) == "table" then
            local sample = FindSampleMatchingSpec(slot.spec)
            local uid = tonumber(slot.uniqueID) or tonumber(slot.uid) or 0
            local iconNum = ResolveIconNum(uid, slot.iconNum, sample)
            local name = nil
            if type(sample) == "table" and sample.name ~= nil and sample.name ~= L"" then
                name = sample.name
            elseif uid > 0 and StockPiler2.Items and StockPiler2.Items.AsItemData then
                local item = StockPiler2.Items.AsItemData(uid)
                if type(item) == "table" then
                    name = item.name
                end
            end
            if (name == nil or name == L"") and MS and MS.Label then
                name = MS.Label(slot.spec)
            end
            if name == nil or name == L"" then
                name = towstring(tostring(slot.role or "material"))
            end
            local have = 0
            if RS and RS.CountItemsMatchingSpec then
                have = tonumber(RS.CountItemsMatchingSpec(slot.spec)) or 0
            end
            local icon = FormatTooltipIcon(iconNum)
            local text = T("brew.tip.stock_count", {
                name = name,
                have = tostring(have),
            })
            if icon ~= L"" then
                text = T("grow.tip.icon_name", { icon = icon, name = text })
            end
            body(text)
        end
    end
end

function Brew._BrewTooltipRegisterLive(anchorWindow, anchorPoint)
    if anchorWindow == nil or anchorWindow == "" then
        Brew.ClearBrewLiveTooltip()
        return
    end
    Brew._liveBrewTip = Brew._liveBrewTip or {}
    local tip = Brew._liveBrewTip
    tip.kind = "brew"
    tip.anchor = anchorWindow
    tip.anchorPoint = anchorPoint
    tip.rowKey = nil
    tip.rowId = nil
    tip.fingerprint = nil
end

function Brew._BrewTooltipRegisterRowLive(anchorWindow, anchorPoint, row)
    if anchorWindow == nil or anchorWindow == "" then
        Brew.ClearBrewLiveTooltip()
        return
    end
    Brew._liveBrewTip = Brew._liveBrewTip or {}
    local tip = Brew._liveBrewTip
    tip.kind = "row-brew"
    tip.anchor = anchorWindow
    tip.anchorPoint = anchorPoint
    tip.rowKey = row and row.potionKey or nil
    tip.rowId = row and row.id or nil
    tip.fingerprint = nil
end

function Brew._BrewTooltipClearLive()
    local tip = Brew._liveBrewTip
    if tip then
        tip.kind = nil
        tip.anchor = nil
        tip.anchorPoint = nil
        tip.rowKey = nil
        tip.rowId = nil
        tip.fingerprint = nil
    end
end

local function ResolveLiveTipRow()
    local tip = Brew._liveBrewTip
    if not tip or tip.kind ~= "row-brew" then
        return nil
    end
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    if type(rows) ~= "table" then
        return nil
    end
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            if tip.rowId ~= nil and row.id == tip.rowId then
                return row
            end
            if tip.rowKey ~= nil and row.potionKey == tip.rowKey then
                return row
            end
        end
    end
    return nil
end

local function DescribeLoadSource()
    local src = tostring(Brew._loadSource or "")
    if src == "manual" then
        return T("brew.tip.load_manual")
    end
    if src == "auto" then
        return T("brew.tip.load_auto")
    end
    return nil
end

function Brew._BrewTooltipFingerprint(row)
    local parts = {}
    local Caps = StockPiler2.TradeSkillCaps
    local canBrew = Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() == true
    parts[#parts + 1] = canBrew and "apo1" or "apo0"
    if Brew.IsBusy() then
        parts[#parts + 1] = "busy"
        if type(Brew._job) == "table" then
            parts[#parts + 1] = "job"
        elseif IsPerformingState() then
            parts[#parts + 1] = "perf"
        else
            parts[#parts + 1] = "lock"
        end
    end
    local canBrewNow = Brew.CanBrewNow and Brew.CanBrewNow() == true
    parts[#parts + 1] = canBrewNow and "go1" or "go0"
    local session = GetSession()
    parts[#parts + 1] = "phase:" .. tostring(session.phase or "?")
    parts[#parts + 1] = "name:" .. ToNarrow(session.name)
    parts[#parts + 1] = "uid:" .. tostring(session.potionUid or "")
    parts[#parts + 1] = "def:" .. tostring(session.potionDeficit or "")
    parts[#parts + 1] = "have:" .. tostring(session.potionHave or "")
    parts[#parts + 1] = "src:" .. tostring(Brew._loadSource or "")
    local tipRow = row
    if type(tipRow) ~= "table" then
        local nextRow = Brew.PickReadyWatch()
        if type(nextRow) == "table" then
            parts[#parts + 1] = "next:" .. ToNarrow(nextRow.name)
                .. ":" .. tostring(nextRow.potionDeficit)
                .. ":" .. tostring(nextRow.craftable)
                .. ":" .. tostring(nextRow.iconNum or "")
        else
            parts[#parts + 1] = "next:none"
        end
        if session.phase == "loaded" or (Brew.IsBusy() and type(Brew._job) == "table") then
            tipRow = FindSessionRow()
        elseif type(nextRow) == "table" then
            tipRow = nextRow
        end
    else
        parts[#parts + 1] = "row:" .. ToNarrow(tipRow.name)
            .. ":" .. tostring(tipRow.potionDeficit)
            .. ":" .. tostring(tipRow.craftable)
            .. ":" .. tostring(tipRow.statusKey or "")
            .. ":" .. tostring(tipRow.iconNum or "")
            .. ":" .. tostring(Brew.GetRowCraftUiState(tipRow))
    end
    local canStart = true
    if Brew.CanStartBrewLoad then
        canStart = Brew.CanStartBrewLoad() == true
    end
    parts[#parts + 1] = "canStart:" .. tostring(canStart)
    -- Snap gen only: avoid CountItemsMatchingSpec bag walks every live-tip tick.
    local snapGen = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapGen then
        snapGen = tonumber(StockPiler2.Inventory.GetSnapGen()) or 0
    end
    parts[#parts + 1] = "snap:" .. tostring(snapGen)
    if type(tipRow) == "table" then
        parts[#parts + 1] = "shared:" .. tostring(tipRow.craftableShared == true)
    end
    return table.concat(parts, "|")
end

--- Footer tip: never claim clickable unless CanBrewNow matches the button.
local function FooterBrewActionLine(body)
    if Brew.CanBrewNow and Brew.CanBrewNow() == true then
        local session = GetSession()
        if session.phase == "loaded" and Brew._loadSource ~= "manual" then
            body(T("brew.tip.click_brew_ready"))
        else
            body(T("brew.tip.click_load_ready"))
        end
        return
    end
    local session = GetSession()
    if session.phase == "loaded" and Brew._loadSource == "manual" then
        body(T("brew.tip.manual_on_board"))
        return
    end
    local canStart, holdMsg = true, nil
    if Brew.CanStartBrewLoad then
        canStart, holdMsg = Brew.CanStartBrewLoad()
    end
    if canStart ~= true then
        body(holdMsg or T("brew.held_autogrow_busy"))
    elseif Brew.IsBusy() then
        if IsPerformingState() then
            body(T("brew.held_crafting"))
        else
            body(T("brew.held_busy"))
        end
    else
        body(T("brew.not_ready_short"))
    end
end

function Brew._BrewTooltipShow(anchorWindow, anchor, liveRefresh)
    if not Tooltips or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    if anchorWindow == nil or anchorWindow == "" then
        return
    end
    if liveRefresh ~= true then
        Brew.RegisterBrewLiveTooltip(anchorWindow, anchor or Tooltips.ANCHOR_WINDOW_TOP)
    end
    Tooltips.CreateTextOnlyTooltip(anchorWindow)
    local heading = (Tooltips and Tooltips.COLOR_HEADING) or { r = 255, g = 204, b = 102 }
    Tooltips.SetTooltipText(1, 1, T("brew.tip.title"))
    if Tooltips.SetTooltipColor then
        Tooltips.SetTooltipColor(1, 1, heading.r or 255, heading.g or 204, heading.b or 102)
    end
    local line = 2
    local function body(text)
        Tooltips.SetTooltipText(line, 1, text, false)
        line = line + 1
    end
    local function warnBody(text)
        Tooltips.SetTooltipText(line, 1, text, false)
        local warn = (Tooltips and Tooltips.COLOR_WARNING) or { r = 220, g = 120, b = 120 }
        if Tooltips.SetTooltipColor then
            Tooltips.SetTooltipColor(line, 1, warn.r or 220, warn.g or 120, warn.b or 120)
        end
        line = line + 1
    end
    local Caps = StockPiler2.TradeSkillCaps
    local canBrew = Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() == true
    if not canBrew then
        warnBody(T("brew.requires_apo"))
        Tooltips.Finalize()
        Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)
        local tip = Brew._liveBrewTip
        if tip and tip.anchor == anchorWindow then
            tip.fingerprint = Brew.BrewTooltipFingerprint()
        end
        return
    end
    -- Any busy (load job, performing, op-lock) — never show "Click to load" while button is grey.
    if Brew.IsBusy() then
        local session = GetSession()
        local row = FindSessionRow()
        if type(Brew._job) == "table" then
            local name = (row and row.name) or session.name
            local icon = FormatTooltipIcon(PotionIconNum(row, session))
            if name ~= nil and name ~= L"" then
                local have = row and tonumber(row.potionHave) or tonumber(session.potionHave)
                local target = row and (tonumber(row.potionMin) or tonumber(row.target))
                    or tonumber(session.potionMin)
                local lineText
                if have ~= nil and target ~= nil then
                    lineText = T("brew.tip.loading_named_stock", {
                        name = name,
                        have = tostring(have),
                        target = tostring(target),
                    })
                else
                    lineText = T("brew.tip.loading_named", { name = name })
                end
                if icon ~= L"" then
                    body(T("grow.tip.icon_name", { icon = icon, name = lineText }))
                else
                    body(lineText)
                end
            else
                body(T("brew.tip.loading_generic"))
            end
            local srcLine = DescribeLoadSource()
            if srcLine then
                body(srcLine)
            end
            AppendIngredientStockLines(body, RecipeForTooltip(row, session))
        else
            if IsPerformingState() then
                body(T("brew.held_crafting"))
            else
                body(T("brew.held_busy"))
            end
            local nextRow = Brew.PickReadyWatch()
            if type(nextRow) == "table" then
                AppendPotionLine(body, T("brew.tip.prefix_next_auto"), nextRow, nil)
                AppendIngredientStockLines(body, RecipeForTooltip(nextRow, nil))
            elseif type(row) == "table" then
                AppendPotionLine(body, T("brew.tip.prefix_ready"), row, session)
                AppendIngredientStockLines(body, RecipeForTooltip(row, session))
            end
        end
    else
        local session = GetSession()
        if session.phase ~= "loaded" then
            local nextRow = Brew.PickReadyWatch()
            if type(nextRow) == "table" then
                AdoptLoadedFromBoard(nextRow)
                session = GetSession()
            end
        end
        if session.phase == "loaded"
            and RowIsReadyToCraft(FindSessionRow())
            and (tonumber(session.potionDeficit) or 0) > 0
        then
            local row = FindSessionRow()
            local name = (row and row.name) or session.name
            if name ~= nil and name ~= L"" then
                AppendPotionLine(body, T("brew.tip.prefix_ready"), row, session)
            else
                body(T("brew.tip.recipe_loaded"))
            end
            local srcLine = DescribeLoadSource()
            if srcLine then
                body(srcLine)
            end
            FooterBrewActionLine(body)
            AppendIngredientStockLines(body, RecipeForTooltip(row, session))
        else
            local loadedRow = session.phase == "loaded" and FindSessionRow() or nil
            if type(loadedRow) == "table" then
                AppendPotionLine(body, T("brew.tip.prefix_board"), loadedRow, session)
                body(T("brew.tip.footer_ready_only"))
            end
            local nextRow = Brew.PickReadyWatch()
            if type(nextRow) == "table" then
                AppendPotionLine(body, T("brew.tip.prefix_next_auto"), nextRow, nil)
                FooterBrewActionLine(body)
                AppendIngredientStockLines(body, RecipeForTooltip(nextRow, nil))
            else
                body(T("brew.none_ready"))
                body(T("brew.tip.row_overstock_note"))
            end
        end
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)
    local tip = Brew._liveBrewTip
    if tip and tip.anchor == anchorWindow then
        tip.fingerprint = Brew.BrewTooltipFingerprint()
    end
end

--- Per-watch Load/Brew tooltip (same style as footer), scoped to this row.
function Brew._BrewTooltipShowRow(anchorWindow, row, anchor, liveRefresh)
    if not Tooltips or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    if anchorWindow == nil or anchorWindow == "" then
        return
    end
    if liveRefresh ~= true then
        Brew.RegisterRowBrewLiveTooltip(anchorWindow, anchor or Tooltips.ANCHOR_WINDOW_TOP, row)
    end
    Tooltips.CreateTextOnlyTooltip(anchorWindow)
    local heading = (Tooltips and Tooltips.COLOR_HEADING) or { r = 255, g = 204, b = 102 }
    Tooltips.SetTooltipText(1, 1, T("brew.tip.title"))
    if Tooltips.SetTooltipColor then
        Tooltips.SetTooltipColor(1, 1, heading.r or 255, heading.g or 204, heading.b or 102)
    end
    local line = 2
    local function body(text)
        Tooltips.SetTooltipText(line, 1, text, false)
        line = line + 1
    end
    local function warnBody(text)
        Tooltips.SetTooltipText(line, 1, text, false)
        local warn = (Tooltips and Tooltips.COLOR_WARNING) or { r = 220, g = 120, b = 120 }
        if Tooltips.SetTooltipColor then
            Tooltips.SetTooltipColor(line, 1, warn.r or 220, warn.g or 120, warn.b or 120)
        end
        line = line + 1
    end
    local Caps = StockPiler2.TradeSkillCaps
    local canBrew = Caps and Caps.CanBrewPotions and Caps.CanBrewPotions() == true
    if not canBrew then
        warnBody(T("brew.requires_apo"))
        Tooltips.Finalize()
        Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)
        local tip = Brew._liveBrewTip
        if tip and tip.anchor == anchorWindow then
            tip.fingerprint = Brew.BrewTooltipFingerprint(row)
        end
        return
    end
    if type(row) ~= "table" then
        body(T("brew.tip.no_watch"))
    else
        local session = GetSession()
        local state = Brew.GetRowCraftUiState(row)
        local matches = RowMatchesSession(row, session)
        if matches and Brew.IsBusy() and type(Brew._job) == "table" then
            local name = row.name or session.name
            local icon = FormatTooltipIcon(PotionIconNum(row, session))
            if name ~= nil and name ~= L"" then
                local have = tonumber(row.potionHave) or tonumber(session.potionHave)
                local target = tonumber(row.potionMin) or tonumber(row.target) or tonumber(session.potionMin)
                local lineText
                if have ~= nil and target ~= nil then
                    lineText = T("brew.tip.loading_named_stock", {
                        name = name,
                        have = tostring(have),
                        target = tostring(target),
                    })
                else
                    lineText = T("brew.tip.loading_named", { name = name })
                end
                if icon ~= L"" then
                    body(T("grow.tip.icon_name", { icon = icon, name = lineText }))
                else
                    body(lineText)
                end
            else
                body(T("brew.tip.loading_generic"))
            end
            AppendIngredientStockLines(body, RecipeForTooltip(row, session))
        elseif Brew.IsBusy() and type(Brew._job) ~= "table" then
            if IsPerformingState() then
                body(T("brew.held_crafting"))
            else
                body(T("brew.held_busy"))
            end
            AppendPotionLine(body, L"", row, nil)
            AppendIngredientStockLines(body, RecipeForTooltip(row, session))
        elseif matches and session.phase == "loaded" then
            AppendPotionLine(body, T("brew.tip.prefix_loaded"), row, session)
            local srcLine = DescribeLoadSource()
            if srcLine then
                body(srcLine)
            end
            body(T("brew.tip.lclick_brew"))
            AppendIngredientStockLines(body, RecipeForTooltip(row, session))
        elseif state == "loading" then
            AppendPotionLine(body, T("brew.tip.prefix_loading"), row, session)
            body(T("brew.tip.materials_loading"))
            AppendIngredientStockLines(body, RecipeForTooltip(row, session))
        elseif state == "loaded" then
            AppendPotionLine(body, T("brew.tip.prefix_loaded"), row, session)
            body(T("brew.tip.lclick_brew"))
            AppendIngredientStockLines(body, RecipeForTooltip(row, session))
        elseif state == "load" then
            AppendPotionLine(body, T("brew.tip.prefix_load"), row, nil)
            if (tonumber(row.potionDeficit) or 0) <= 0 then
                body(T("brew.tip.overstock"))
            elseif row.craftableShared == true or row.statusKey == "ready_to_craft_shared" then
                body(T("brew.tip.yellow_craftable"))
            end
            body(T("brew.tip.lclick_load"))
            AppendIngredientStockLines(body, RecipeForTooltip(row, nil))
        else
            AppendPotionLine(body, L"", row, nil)
            if (tonumber(row.craftable) or 0) <= 0 and row.canLoad ~= true then
                body(T("brew.tip.idle_need_craftable"))
            else
                body(T("brew.tip.idle_nothing"))
            end
            AppendIngredientStockLines(body, RecipeForTooltip(row, nil))
        end
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_TOP)
    local tip = Brew._liveBrewTip
    if tip and tip.anchor == anchorWindow then
        tip.fingerprint = Brew.BrewTooltipFingerprint(row)
    end
end

function Brew._BrewTooltipMaybeRefresh(force)
    local tip = Brew._liveBrewTip
    if not tip or tip.anchor == nil or tip.anchor == "" then
        return
    end
    if tip.kind ~= "brew" and tip.kind ~= "row-brew" then
        return
    end
    local mouse = SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    if mouse ~= tip.anchor then
        Brew.ClearBrewLiveTooltip()
        return
    end
    local tipRow = nil
    if tip.kind == "row-brew" then
        tipRow = ResolveLiveTipRow()
    end
    local fp = Brew.BrewTooltipFingerprint(tipRow)
    if force ~= true and fp ~= nil and fp == tip.fingerprint then
        return
    end
    tip.fingerprint = fp
    if tip.kind == "row-brew" then
        Brew.ShowRowBrewTooltip(tip.anchor, tipRow, tip.anchorPoint, true)
    else
        Brew.ShowBrewTooltip(tip.anchor, tip.anchorPoint, true)
    end
end

function Brew._BrewTooltipTickLive(timeElapsed)
    local tip = Brew._liveBrewTip
    if not tip or (tip.kind ~= "brew" and tip.kind ~= "row-brew") then
        return
    end
    local mouse = SystemData and SystemData.MouseOverWindow and SystemData.MouseOverWindow.name
    if mouse ~= tip.anchor then
        Brew.ClearBrewLiveTooltip()
        return
    end
    Brew.MaybeRefreshBrewTooltip(false)
end

-- One-release compatibility forwards; tooltip rendering is owned by BrewTooltip.
function Brew.RegisterBrewLiveTooltip(anchorWindow, anchorPoint)
    return StockPiler2.BrewTooltip.RegisterLive(anchorWindow, anchorPoint)
end

function Brew.RegisterRowBrewLiveTooltip(anchorWindow, anchorPoint, row)
    return StockPiler2.BrewTooltip.RegisterRowLive(anchorWindow, anchorPoint, row)
end

function Brew.ClearBrewLiveTooltip()
    return StockPiler2.BrewTooltip.ClearLive()
end

function Brew.BrewTooltipFingerprint(row)
    return StockPiler2.BrewTooltip.Fingerprint(row)
end

function Brew.ShowBrewTooltip(anchorWindow, anchor, liveRefresh)
    return StockPiler2.BrewTooltip.Show(anchorWindow, anchor, liveRefresh)
end

function Brew.ShowRowBrewTooltip(anchorWindow, row, anchor, liveRefresh)
    return StockPiler2.BrewTooltip.ShowRow(anchorWindow, row, anchor, liveRefresh)
end

function Brew.MaybeRefreshBrewTooltip(force)
    return StockPiler2.BrewTooltip.MaybeRefresh(force)
end

function Brew.TickBrewLiveTooltip(timeElapsed)
    return StockPiler2.BrewTooltip.TickLive(timeElapsed)
end

----------------------------------------------------------------
-- /sp2 brewplan
----------------------------------------------------------------

local function EmitBrewStepLine(emit, index, step, recipeSlots)
    if type(step) ~= "table" then
        return
    end
    local RS = StockPiler2.RecipeSpec
    local MS = StockPiler2.MaterialSpec
    local label = step.narrowName or ""
    if label == "" and type(step.spec) == "table" and MS then
        if MS.NeedLabel then
            label = ToNarrow(MS.NeedLabel(step.spec))
        elseif MS.Label then
            label = ToNarrow(MS.Label(step.spec))
        end
    end
    local bagHave = 0
    if type(step.spec) == "table" and RS and RS.CountItemsMatchingSpec then
        bagHave = tonumber(RS.CountItemsMatchingSpec(step.spec)) or 0
    end
    local craftHave = Brew.CountInCraftingBag(step.uniqueID, step.narrowName, step.spec)
    local onBoard = SlotHasItem(step) == true
    local wrong = SlotHasWrongItem(step) == true
    emit(string.format(
        "  [%d] role=%s craftSlot=%s uid=%s bag=%d craft=%d onBoard=%s wrong=%s label=%s",
        index,
        tostring(step.role or "?"),
        tostring(step.craftingSlot),
        tostring(step.uniqueID or 0),
        bagHave,
        craftHave,
        tostring(onBoard),
        tostring(wrong),
        label ~= "" and label or "?"
    ))
end

function Brew.DumpPlan(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler2.Debug and StockPiler2.Debug.Print then
            StockPiler2.Debug.Print(msg)
        end
    end
    emit("=== StockPiler2 brew plan ===")
    local a = AA()
    local session = GetSession()
    local isApo = a and a.IsApothecary and a.IsApothecary() == true
    emit(string.format(
        "apo=%s skill=%s winOpen=%s apoAlive=%s owned=%s stealth=%s openedApo=%s",
        tostring(isApo),
        tostring(a and a.CraftingSkillType and a.CraftingSkillType()),
        tostring(a and a.WindowOpen and a.WindowOpen()),
        tostring(ApoSessionAlive and ApoSessionAlive()),
        tostring(Brew._brewOwnedSession == true),
        tostring(Brew._brewApoStealth == true),
        tostring(Brew._brewOpenedApo == true)
    ))
    emit(string.format(
        "pendingIdleClose=%s serverHasItems=%s",
        tostring(Brew._pendingIdleClose or ""),
        tostring(a and a.ServerHasItems and a.ServerHasItems())
    ))
    emit(string.format(
        "session phase=%s name=%s key=%s uid=%s deficit=%s craftable=%s have=%s min=%s",
        tostring(session.phase or "idle"),
        ToNarrow(session.name),
        tostring(session.potionKey or ""),
        tostring(session.potionUid or 0),
        tostring(session.potionDeficit),
        tostring(session.craftable),
        tostring(session.potionHave),
        tostring(session.potionMin)
    ))
    local job = Brew._job
    if type(job) == "table" then
        emit(string.format(
            "job phase=%s step=%s/%s wait=%s total=%s",
            tostring(job.phase),
            tostring(job.stepIndex),
            tostring(type(job.steps) == "table" and #job.steps or 0),
            tostring(job.waitTicks),
            tostring(job.totalTicks)
        ))
    else
        emit("job=none busy=" .. tostring(Brew.IsBusy() == true))
    end

    local canStart, holdMsg = true, nil
    if Brew.CanStartBrewLoad then
        canStart, holdMsg = Brew.CanStartBrewLoad()
    end
    emit("canStartLoad=" .. tostring(canStart == true)
        .. (canStart == true and "" or (" hold=" .. ToNarrow(holdMsg))))

    local targetRow = nil
    local action = "none"
    if session.phase == "loaded" then
        targetRow = FindSessionRow()
        action = "brew"
        local ok, msg = Brew.ValidateApothecaryPerform()
        emit("validatePerform=" .. tostring(ok == true)
            .. (ok == true and "" or (" msg=" .. ToNarrow(msg))))
    elseif session.phase == "loading" or type(job) == "table" then
        targetRow = FindSessionRow()
        action = "loading"
    else
        targetRow = Brew.PickReadyWatch()
        if type(targetRow) == "table" then
            if canStart == true then
                action = "load"
            else
                action = "held"
            end
        end
    end
    emit("action=" .. action)

    if type(targetRow) == "table" then
        emit(string.format(
            "target name=%s key=%s uid=%s status=%s deficit=%s craftable=%s have=%s min=%s",
            ToNarrow(targetRow.name),
            tostring(targetRow.potionKey or ""),
            tostring(targetRow.uniqueID or 0),
            tostring(targetRow.statusKey or ""),
            tostring(targetRow.potionDeficit),
            tostring(targetRow.craftable),
            tostring(targetRow.potionHave),
            tostring(targetRow.potionMin or targetRow.target)
        ))
        local recipe = RowRecipe(targetRow)
        if type(recipe) ~= "table" then
            emit("  recipe=missing")
        else
            local matsOk = Brew.MaterialsReadyInCraftingBag(recipe) == true
            emit("  recipeYield=" .. tostring(recipe.recipeYield)
                .. " craftBagReady=" .. tostring(matsOk)
                .. " boardMatch=" .. tostring(BoardMatchesRecipe and BoardMatchesRecipe(recipe)))
            local steps = BuildLoadSteps(recipe)
            emit("  loadSteps=" .. tostring(#steps))
            for i = 1, #steps do
                EmitBrewStepLine(emit, i, steps[i], recipe.slots)
            end
            if matsOk ~= true then
                local missing = Brew.DescribeMissingInCraftingBag(recipe)
                if missing ~= nil and missing ~= L"" then
                    emit("  missingCraftBag=" .. ToNarrow(missing))
                end
            end
        end
    else
        emit("target=none")
    end

    local last = Brew._lastLoad
    if type(last) == "table" and type(last.steps) == "table" then
        emit(string.format(
            "lastLoad key=%s uid=%s steps=%d",
            tostring(last.potionKey or ""),
            tostring(last.potionUid or 0),
            #last.steps
        ))
        for i = 1, #last.steps do
            EmitBrewStepLine(emit, i, last.steps[i], nil)
        end
        local ok, msg = ValidateAgainstLastLoad()
        emit("lastLoadOk=" .. tostring(ok == true)
            .. (ok == true and "" or (" msg=" .. ToNarrow(msg))))
    else
        emit("lastLoad=none")
    end

    emit("--- ready watches ---")
    local plan = CurrentPlan()
    local rows = plan and plan.rows
    local readyN = 0
    if type(rows) == "table" then
        for i = 1, #rows do
            local row = rows[i]
            if RowIsReadyToCraft(row) then
                readyN = readyN + 1
                emit(string.format(
                    "  %s deficit=%s craftable=%s have=%s/%s key=%s",
                    ToNarrow(row.name),
                    tostring(row.potionDeficit),
                    tostring(row.craftable),
                    tostring(row.potionHave),
                    tostring(row.potionMin or row.target),
                    tostring(row.potionKey or "")
                ))
            end
        end
    end
    if readyN == 0 then
        emit("  (none)")
    end
    emit("=== end brew plan ===")
end
