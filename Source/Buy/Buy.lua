----------------------------------------------------------------
-- StockPiler2 Buy — AutoBuy from open NPC stores (non-growable mats)
----------------------------------------------------------------

StockPiler2.Buy = StockPiler2.Buy or {}
local Buy = StockPiler2.Buy

local BRASS_PER_GOLD = 10000
local MAX_PURCHASES_PER_VISIT = 80

Buy._jobsCache = nil
Buy._jobsSnapGen = nil
Buy._visitStoreOpen = false

local function ToNarrow(text)
    if StockPiler2.ToNarrow then
        return StockPiler2.ToNarrow(text)
    end
    return tostring(text or "")
end

local function LogBuyOp(msg)
    if StockPiler2.Debug and StockPiler2.Debug.LogOp then
        StockPiler2.Debug.LogOp("buy", msg)
    elseif StockPiler2.D then
        StockPiler2.D("AutoBuy " .. tostring(msg))
    end
end

local function EmitBuyTrace(msg, force)
    if force ~= true and not (StockPiler2.Debug and StockPiler2.Debug.Enabled == true) then
        return
    end
    local text = "buy| " .. tostring(msg)
    if StockPiler2.Debug and StockPiler2.Debug.LogAlways then
        StockPiler2.Debug.LogAlways(text)
    elseif type(d) == "function" then
        d("StockPiler2| " .. text)
    end
end

local function LogBuyJobLines(jobs, force)
    jobs = type(jobs) == "table" and jobs or {}
    for i = 1, math.min(#jobs, 20) do
        local job = jobs[i]
        if type(job) == "table" then
            EmitBuyTrace(string.format(
                "  job #%d kind=%s specKey=%s have=%d need=%d deficit=%d name=%s",
                i,
                tostring(job.kind or "buy"),
                tostring(job.specKey or "?"),
                tonumber(job.have) or 0,
                tonumber(job.need) or 0,
                tonumber(job.deficit) or 0,
                ToNarrow(job.label or job.name or "?")
            ), force)
        end
    end
    if #jobs > 20 then
        EmitBuyTrace("  ... +" .. tostring(#jobs - 20) .. " more jobs", force)
    end
end

function Buy.IsEnabled()
    if StockPiler2.Watch and StockPiler2.Watch.IsAutoBuyEnabled then
        return StockPiler2.Watch.IsAutoBuyEnabled() == true
    end
    local row = StockPiler2.Watch and StockPiler2.Watch.CharacterRow and StockPiler2.Watch.CharacterRow()
    return type(row) == "table" and row.autoBuyEnabled == true
end

function Buy.GetReserveGold()
    if StockPiler2.Watch and StockPiler2.Watch.GetAutoBuyReserveGold then
        return StockPiler2.Watch.GetAutoBuyReserveGold()
    end
    local row = StockPiler2.Watch and StockPiler2.Watch.CharacterRow and StockPiler2.Watch.CharacterRow()
    local n = type(row) == "table" and tonumber(row.autoBuyReserveGold) or 10
    if n == nil or n < 1 then
        return 10
    end
    if n > 99 then
        return 99
    end
    return math.floor(n)
end

function Buy.GetBudgetGold()
    if StockPiler2.Watch and StockPiler2.Watch.GetAutoBuyBudgetGold then
        return StockPiler2.Watch.GetAutoBuyBudgetGold()
    end
    local row = StockPiler2.Watch and StockPiler2.Watch.CharacterRow and StockPiler2.Watch.CharacterRow()
    local n = type(row) == "table" and tonumber(row.autoBuyBudgetGold) or 50
    if n == nil or n < 1 then
        return 50
    end
    if n > 999 then
        return 999
    end
    return math.floor(n)
end

function Buy.InvalidateJobsCache()
    Buy._jobsCache = nil
    Buy._jobsSnapGen = nil
end

----------------------------------------------------------------
-- Vendor learn (Cultivating + Apothecary crafting mats)
----------------------------------------------------------------

local function TradeSkillIds()
    local cult = 3
    local apo = 4
    if GameData and GameData.TradeSkills then
        cult = tonumber(GameData.TradeSkills.CULTIVATION) or cult
        apo = tonumber(GameData.TradeSkills.APOTHECARY) or apo
    end
    return cult, apo
end

local function IsCraftTradeSkill(item)
    local ts = tonumber(item and item.tradeSkill) or 0
    if ts <= 0 then
        return false
    end
    local cult, apo = TradeSkillIds()
    return ts == cult or ts == apo
end

local function VendorItemsTable()
    if StockPiler2.Knowledge and StockPiler2.Knowledge.GetTable then
        return StockPiler2.Knowledge.GetTable("vendorItems")
    end
    local acct = StockPiler2.Account
    if type(acct) ~= "table" then
        return nil
    end
    if type(acct.vendorItems) ~= "table" then
        acct.vendorItems = {}
    end
    return acct.vendorItems
end

--- Upsert Cult+Apo store rows into Account.items + vendorItems.
function Buy.LearnFromOpenStore()
    local VA = StockPiler2.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return 0
    end
    if VA.IsBuybackView and VA.IsBuybackView() then
        return 0
    end
    local list = VA.StoreRows and VA.StoreRows() or nil
    if type(list) ~= "table" then
        return 0
    end
    local store = VendorItemsTable()
    local n = 0
    local now = (type(GetGameTime) == "function" and tonumber(GetGameTime())) or 0
    local function consider(item)
        if type(item) ~= "table" or not IsCraftTradeSkill(item) then
            return
        end
        local uid = tonumber(item.uniqueID) or tonumber(item.id) or 0
        if uid <= 0 then
            return
        end
        if StockPiler2.Items and StockPiler2.Items.UpsertFromItemData then
            StockPiler2.Items.UpsertFromItemData(item, "vendor")
        end
        if type(store) == "table" then
            local key = tostring(uid)
            local isNew = store[key] == nil
            store[key] = {
                uniqueID = uid,
                tradeSkill = tonumber(item.tradeSkill) or 0,
                cultivationType = tonumber(item.cultivationType) or 0,
                iconNum = tonumber(item.iconNum) or 0,
                nameNarrow = ToNarrow(item.name),
                lastSeen = now,
                source = "store",
            }
            if isNew then
                n = n + 1
            end
        end
    end
    for _, item in ipairs(list) do
        consider(item)
    end
    for _, item in pairs(list) do
        consider(item)
    end
    if n > 0 and StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
        StockPiler2.Knowledge.Touch()
    end
    if n > 0 then
        LogBuyOp("learned vendor items +" .. tostring(n))
    end
    return n
end

----------------------------------------------------------------
-- Jobs
----------------------------------------------------------------

function Buy.CollectBuyJobs()
    local snapGen = StockPiler2.Inventory and tonumber(StockPiler2.Inventory.GetSnapGen and StockPiler2.Inventory.GetSnapGen())
        or tonumber(StockPiler2.Inventory and StockPiler2.Inventory._snapGen) or 0
    if type(Buy._jobsCache) == "table" and Buy._jobsSnapGen == snapGen then
        return Buy._jobsCache
    end
    local jobs = {}
    if StockPiler2.Planner and StockPiler2.Planner.CollectVendorBuyJobs then
        jobs = StockPiler2.Planner.CollectVendorBuyJobs() or {}
    end
    Buy._jobsCache = jobs
    Buy._jobsSnapGen = snapGen
    return jobs
end

function Buy.DumpBuyPlan(opts)
    opts = type(opts) == "table" and opts or {}
    local force = opts.force == true
    if force and StockPiler2.Inventory and StockPiler2.Inventory.RefreshAllIfNeeded then
        StockPiler2.Inventory.RefreshAllIfNeeded({ force = true })
    end
    Buy.InvalidateJobsCache()
    local jobs = Buy.CollectBuyJobs()
    local Inv = StockPiler2.Inventory
    local snapDone = Inv and Inv._ready == true
    local snapGen = Inv and tonumber(Inv.GetSnapGen and Inv.GetSnapGen()) or 0
    EmitBuyTrace("=== buy plan ===", force)
    EmitBuyTrace(string.format(
        "enabled=%s reserveGold=%d budgetGold=%d storeOpen=%s snapshotReady=%s snapGen=%d",
        tostring(Buy.IsEnabled()),
        Buy.GetReserveGold(),
        Buy.GetBudgetGold(),
        tostring(StockPiler2.VendorAdapter and StockPiler2.VendorAdapter.IsStoreOpen
            and StockPiler2.VendorAdapter.IsStoreOpen()),
        tostring(snapDone),
        snapGen
    ), force)
    EmitBuyTrace("--- jobs (" .. tostring(#jobs) .. ") ---", force)
    if not snapDone then
        EmitBuyTrace("  (snapshot not ready — job list may be empty)", force)
    elseif #jobs == 0 then
        EmitBuyTrace("  (no vendor buy jobs)", force)
    else
        LogBuyJobLines(jobs, force)
    end
    EmitBuyTrace("=== end buy plan ===", force)
end

----------------------------------------------------------------
-- Store match
----------------------------------------------------------------

local function HasAltCurrency(item)
    local alt = item and item.altCurrency
    if type(alt) ~= "table" then
        return false
    end
    if #alt > 0 then
        return true
    end
    for _ in pairs(alt) do
        return true
    end
    return false
end

local function PlayerCanUseStoreItem(item)
    if type(DataUtils) ~= "table" or type(DataUtils.PlayerCanUseItem) ~= "function" then
        return true
    end
    local ok, canUse = StockPiler2.TryCallQuiet("DataUtils.PlayerCanUseItem", DataUtils.PlayerCanUseItem, item)
    if not ok then
        return false
    end
    return canUse == true
end

local function IsGrowablePlantItem(item)
    if type(item) ~= "table" then
        return false
    end
    local cult = tonumber(item.cultivationType) or 0
    local seed = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SEED) or 1
    local spore = (GameData and GameData.CultivationTypes and GameData.CultivationTypes.SPORE) or 5
    if cult == seed or cult == spore then
        return true
    end
    local MS = StockPiler2.MaterialSpec
    if not (MS and MS.FromItemDataCached) then
        return false
    end
    local spec = MS.FromItemDataCached(item, nil)
    if type(spec) ~= "table" then
        return false
    end
    if StockPiler2.SeedMap and StockPiler2.SeedMap.IsGrowableSpec
        and StockPiler2.SeedMap.IsGrowableSpec(spec)
    then
        return true
    end
    return MS.IsGrowable and MS.IsGrowable(spec) == true
end

local function IsHarvestByproductItem(item)
    local MS = StockPiler2.MaterialSpec
    if not (MS and MS.FromItemDataCached) then
        return false
    end
    if not (StockPiler2.SeedMap and StockPiler2.SeedMap.IsHarvestByproduct) then
        return false
    end
    local spec = MS.FromItemDataCached(item, nil)
    return type(spec) == "table" and StockPiler2.SeedMap.IsHarvestByproduct(spec) == true
end

local function ItemMatchesJob(item, job)
    if type(item) ~= "table" or type(job) ~= "table" then
        return false
    end
    if IsGrowablePlantItem(item) or IsHarvestByproductItem(item) then
        return false
    end
    if type(job.spec) ~= "table" or not (StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.Matches) then
        return false
    end
    return StockPiler2.MaterialSpec.Matches(item, job.spec) == true
end

function Buy.FindStoreMatch(job)
    local VA = StockPiler2.VendorAdapter
    local list = VA and VA.StoreRows and VA.StoreRows() or nil
    if type(list) ~= "table" or type(job) ~= "table" then
        return nil
    end
    local function consider(item)
        if type(item) == "table"
            and tonumber(item.slotNum)
            and item.canbuy ~= false
            and not HasAltCurrency(item)
            and (tonumber(item.cost) or 0) > 0
            and PlayerCanUseStoreItem(item)
            and ItemMatchesJob(item, job)
        then
            return item, tonumber(item.cost) or 0
        end
        return nil
    end
    for _, item in ipairs(list) do
        local matched, cost = consider(item)
        if matched then
            return matched, cost
        end
    end
    for _, item in pairs(list) do
        local matched, cost = consider(item)
        if matched then
            return matched, cost
        end
    end
    return nil
end

----------------------------------------------------------------
-- Visit state + TryBuyNext
----------------------------------------------------------------

local function BuyBlockedReason()
    if StockPiler2.Scheduler and StockPiler2.Scheduler.BagWorkPending
        and StockPiler2.Scheduler.BagWorkPending()
    then
        return "bag-work"
    end
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsBrewSessionActive
        and StockPiler2.Orchestrator.IsBrewSessionActive()
    then
        return "brew-busy"
    end
    if StockPiler2.ApothecaryAdapter and StockPiler2.ApothecaryAdapter.IsBusy
        and StockPiler2.ApothecaryAdapter.IsBusy()
    then
        return "brew-busy"
    end
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.IsHarvestActive
        and StockPiler2.Orchestrator.IsHarvestActive()
    then
        return "harvest-busy"
    end
    local Grow = StockPiler2.Grow
    if Grow and type(Grow._pendingPlant) == "table" then
        for _, n in pairs(Grow._pendingPlant) do
            if (tonumber(n) or 0) > 0 then
                return "plant-busy"
            end
        end
    end
    return nil
end

local function PlayerMoneyBrass()
    local VA = StockPiler2.VendorAdapter
    if VA and VA.GetPlayerMoneyBrass then
        return VA.GetPlayerMoneyBrass()
    end
    return 0
end

local function ChatVisitStop(reason)
    if Buy._visitChatted == true then
        return
    end
    Buy._visitChatted = true
    if reason ~= "nothing" then
        Buy._visitStopReason = reason
    end
    LogBuyOp(string.format(
        "stop reason=%s bought=%d spentBrass=%d",
        tostring(reason),
        tonumber(Buy._visitBought) or 0,
        tonumber(Buy._visitSpentBrass) or 0
    ))
end

local function ResetVisit()
    Buy._visitSpentBrass = 0
    Buy._visitBought = 0
    Buy._visitPurchases = 0
    Buy._visitStopReason = nil
    Buy._visitChatted = false
    Buy._visitSawMatch = false
    Buy._visitHadJobs = false
    Buy._visitAcquiredByKey = {}
    Buy._visitNoMatchKeys = {}
    Buy._visitSkipLogged = {}
    Buy._visitSnapshotSkipLogged = false
    Buy._visitBuybackSkipLogged = false
    Buy._visitMoneyBrass = PlayerMoneyBrass()
    Buy.InvalidateJobsCache()
end

local function LogVisitSkipOnce(key, msg)
    local logged = Buy._visitSkipLogged
    if type(logged) ~= "table" then
        logged = {}
        Buy._visitSkipLogged = logged
    end
    if logged[key] == true then
        return
    end
    logged[key] = true
    LogBuyOp("skip " .. msg)
end

local function JobAcquireKey(job, item)
    if type(job) ~= "table" then
        return nil
    end
    local key = job.specKey
    if type(key) == "string" and key ~= "" then
        return key
    end
    local uid = tonumber(item and (item.uniqueID or item.id)) or 0
    if uid > 0 then
        return "uid:" .. tostring(uid)
    end
    local name = ToNarrow(job.name or job.label or "")
    if name ~= "" then
        return "name:" .. name
    end
    return nil
end

local function VisitAcquired(key)
    if key == nil then
        return 0
    end
    local map = Buy._visitAcquiredByKey
    if type(map) ~= "table" then
        return 0
    end
    return tonumber(map[key]) or 0
end

local function NoteVisitAcquired(key, qty)
    qty = tonumber(qty) or 0
    if key == nil or qty <= 0 then
        return
    end
    local map = Buy._visitAcquiredByKey
    if type(map) ~= "table" then
        map = {}
        Buy._visitAcquiredByKey = map
    end
    map[key] = VisitAcquired(key) + qty
end

local function VisitMoneyBrass()
    local live = PlayerMoneyBrass()
    local tracked = tonumber(Buy._visitMoneyBrass)
    if tracked == nil then
        Buy._visitMoneyBrass = live
        return live
    end
    if live > 0 and live < tracked then
        Buy._visitMoneyBrass = live
        return live
    end
    return tracked
end

function Buy.OnStoreUpdated()
    local VA = StockPiler2.VendorAdapter
    local showing = VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
    if showing and Buy._visitStoreOpen ~= true then
        Buy._visitStoreOpen = true
        ResetVisit()
        local jobs = Buy.IsEnabled() and Buy.CollectBuyJobs() or {}
        LogBuyOp(string.format(
            "visit-start enabled=%s jobs=%d money=%d reserveGold=%d budgetGold=%d",
            tostring(Buy.IsEnabled()),
            type(jobs) == "table" and #jobs or 0,
            tonumber(Buy._visitMoneyBrass) or 0,
            Buy.GetReserveGold(),
            Buy.GetBudgetGold()
        ))
        if Buy.IsEnabled() and type(jobs) == "table" and #jobs > 0 then
            LogBuyJobLines(jobs, false)
        end
    elseif not showing and Buy._visitStoreOpen == true then
        Buy._visitStoreOpen = false
        if (tonumber(Buy._visitBought) or 0) > 0 then
            ChatVisitStop("bought")
        elseif Buy._visitHadJobs == true and Buy._visitSawMatch ~= true then
            ChatVisitStop("nothing")
        else
            LogBuyOp(string.format(
                "visit-end bought=%d spentBrass=%d",
                tonumber(Buy._visitBought) or 0,
                tonumber(Buy._visitSpentBrass) or 0
            ))
        end
        Buy.InvalidateJobsCache()
    end
end

local function AfterPurchaseRefresh()
    Buy.InvalidateJobsCache()
    if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.ClearCountCaches then
        StockPiler2.RecipeSpec.ClearCountCaches()
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.MarkDirty then
        StockPiler2.Inventory.MarkDirty({ reason = "autobuy", full = true })
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.EnqueueBagFlush then
        StockPiler2.Scheduler.EnqueueBagFlush(false)
    end
    if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Invalidate then
        StockPiler2.PlanSnapshot.Invalidate()
    end
end

function Buy.TryBuyNext()
    if Buy._visitStopReason ~= nil then
        return false
    end
    if not Buy.IsEnabled() then
        return false
    end
    local VA = StockPiler2.VendorAdapter
    if not VA or not VA.IsStoreOpen or VA.IsStoreOpen() ~= true then
        return false
    end
    if VA.IsBuybackView and VA.IsBuybackView() then
        if Buy._visitBuybackSkipLogged ~= true then
            Buy._visitBuybackSkipLogged = true
            LogBuyOp("skip buyback-view")
        end
        return false
    end
    local busy = BuyBlockedReason()
    if busy ~= nil then
        if Buy._lastBusyLog ~= busy then
            Buy._lastBusyLog = busy
            LogBuyOp("wait " .. busy)
        end
        return false
    end
    Buy._lastBusyLog = nil

    local purchases = tonumber(Buy._visitPurchases) or 0
    if purchases >= MAX_PURCHASES_PER_VISIT then
        ChatVisitStop("cap")
        return false
    end

    local jobs = Buy.CollectBuyJobs()
    if type(jobs) ~= "table" or #jobs == 0 then
        if StockPiler2.Inventory and StockPiler2.Inventory._ready ~= true then
            if Buy._visitSnapshotSkipLogged ~= true then
                Buy._visitSnapshotSkipLogged = true
                LogBuyOp("skip snapshot-not-ready")
            end
        end
        if (tonumber(Buy._visitBought) or 0) > 0 then
            ChatVisitStop("bought")
        end
        return false
    end
    Buy._visitHadJobs = true

    local money = VisitMoneyBrass()
    local liveMoney = PlayerMoneyBrass()
    if liveMoney > 0 and liveMoney < money then
        money = liveMoney
        Buy._visitMoneyBrass = liveMoney
    end
    local reserve = Buy.GetReserveGold() * BRASS_PER_GOLD
    local budget = Buy.GetBudgetGold() * BRASS_PER_GOLD
    local spent = tonumber(Buy._visitSpentBrass) or 0
    local reserveBlock = false
    local budgetBlock = false

    for i = 1, #jobs do
        local job = jobs[i]
        local item, cost = Buy.FindStoreMatch(job)
        local acquireKey = JobAcquireKey(job, item)
        local bagDeficit = tonumber(job.deficit) or 0
        local remaining = math.max(0, bagDeficit - VisitAcquired(acquireKey))
        if remaining < 1 then
            if acquireKey ~= nil then
                LogVisitSkipOnce(
                    "acquired:" .. tostring(acquireKey),
                    string.format(
                        "acquired key=%s acquired=%d deficit=%d",
                        tostring(acquireKey),
                        VisitAcquired(acquireKey),
                        bagDeficit
                    )
                )
            end
        elseif type(item) ~= "table" and bagDeficit > 0 then
            local jobKey = tostring(job.specKey or job.kind or i)
            if type(Buy._visitNoMatchKeys) ~= "table" then
                Buy._visitNoMatchKeys = {}
            end
            Buy._visitNoMatchKeys[jobKey] = true
            LogVisitSkipOnce(
                "nomatch:" .. jobKey,
                string.format(
                    "no-match job=%s deficit=%d",
                    ToNarrow(job.name or job.label or jobKey),
                    bagDeficit
                )
            )
        elseif type(item) == "table" and (tonumber(cost) or 0) > 0 then
            Buy._visitSawMatch = true
            local vendorMax = 100
            local stackCount = tonumber(item.stackCount) or 1
            if stackCount > 1 then
                vendorMax = stackCount
            end
            local maxByReserve = math.floor((money - reserve) / cost)
            local maxByBudget = math.floor((budget - spent) / cost)
            local qty = math.min(remaining, vendorMax, maxByReserve, maxByBudget)
            if qty < 1 then
                if maxByReserve < 1 then
                    reserveBlock = true
                elseif maxByBudget < 1 then
                    budgetBlock = true
                end
            else
                local costTotal = cost * qty
                if money - costTotal < reserve then
                    reserveBlock = true
                else
                    local slotNum = tonumber(item.slotNum)
                    if slotNum == nil or acquireKey == nil then
                        LogBuyOp("skip bad-slot-or-key job=" .. ToNarrow(job.name or job.kind))
                        return false
                    end
                    local ok, err = VA.BuyItem(item, qty)
                    if ok ~= true then
                        LogBuyOp(string.format(
                            "fail BuyItem slot=%d qty=%d err=%s",
                            slotNum,
                            qty,
                            tostring(err)
                        ))
                        return false
                    end
                    Buy._visitSpentBrass = spent + costTotal
                    Buy._visitBought = (tonumber(Buy._visitBought) or 0) + qty
                    Buy._visitPurchases = purchases + 1
                    Buy._visitMoneyBrass = math.max(0, money - costTotal)
                    NoteVisitAcquired(acquireKey, qty)
                    AfterPurchaseRefresh()
                    LogBuyOp(string.format(
                        "purchase slot=%d qty=%d cost=%d name=%s remainingWas=%d spent=%d moneyLeft=%d",
                        slotNum,
                        qty,
                        costTotal,
                        ToNarrow(item.name or job.name or ""),
                        remaining,
                        tonumber(Buy._visitSpentBrass) or 0,
                        tonumber(Buy._visitMoneyBrass) or 0
                    ))
                    return true
                end
            end
        end
    end

    if reserveBlock then
        ChatVisitStop("reserved")
    elseif budgetBlock then
        ChatVisitStop("budget")
    end
    return false
end

function Buy.OnTick()
    Buy.OnStoreUpdated()
    local VA = StockPiler2.VendorAdapter
    if VA and VA.IsStoreOpen and VA.IsStoreOpen() and Buy.IsEnabled() then
        return Buy.TryBuyNext() == true
    end
    return false
end

function Buy.NeedsTick()
    if not Buy.IsEnabled() then
        return false
    end
    local VA = StockPiler2.VendorAdapter
    return VA and VA.IsStoreOpen and VA.IsStoreOpen() == true
end
