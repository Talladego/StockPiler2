----------------------------------------------------------------
-- StockPiler2 Bootstrap — init, shutdown, slash commands
----------------------------------------------------------------

StockPiler2 = StockPiler2 or {}
StockPiler2.Version = L"0.4.130"

local function T(key, tokens)
    if StockPiler2.T then
        return StockPiler2.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

local function EmitLog(msg)
    if StockPiler2.Debug and StockPiler2.Debug.LogAlways then
        StockPiler2.Debug.LogAlways(msg)
    end
end

local function Print(msg)
    if StockPiler2.Debug and StockPiler2.Debug.Print then
        StockPiler2.Debug.Print(msg)
    end
end

local function OnOff(on)
    return on and T("boot.on") or T("boot.off")
end

local function SetDebugEnabled(on)
    local s = StockPiler2.Persistence.EnsureSettings()
    s.debugEnabled = on == true
    StockPiler2.Debug.Enabled = s.debugEnabled
    EmitLog("settings| debug=" .. (StockPiler2.Debug.Enabled and "ON" or "OFF"))
    Print(T("boot.debug", { state = OnOff(StockPiler2.Debug.Enabled) }))
end

local function SetEventTrace(on)
    local s = StockPiler2.Persistence.EnsureSettings()
    s.eventTrace = on == true
    StockPiler2.Debug.EventTrace = s.eventTrace
    Print(T("boot.event_trace", { state = OnOff(s.eventTrace) }))
end

local function PrintHelp()
    Print(T("boot.help.header"))
    Print(T("boot.help.open"))
    Print(T("boot.help.help"))
    Print(T("boot.help.tabs"))
    Print(T("boot.help.debug"))
    Print(T("boot.help.dumps"))
    Print(T("boot.help.bags"))
    Print(T("boot.help.events"))
    Print(T("boot.help.perf"))
    Print(T("boot.help.audit"))
    Print(T("boot.help.mem"))
    Print(T("boot.help.harvest"))
end

function StockPiler2.OnSlash(input)
    local text = ""
    if input ~= nil then
        text = tostring(input)
    end
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    local lower = string.lower(text)

    if lower == "" then
        if StockPiler2.Ui and StockPiler2.Ui.ToggleWindow then
            StockPiler2.Ui.ToggleWindow()
        end
        return
    end
    if lower == "help" then
        PrintHelp()
        return
    end
    if lower == "potions" then
        if StockPiler2.Ui and StockPiler2.Ui.ShowWindow then
            StockPiler2.Ui.ShowWindow(1)
        end
        return
    end
    if lower == "watch" then
        if StockPiler2.Ui and StockPiler2.Ui.ShowWindow then
            StockPiler2.Ui.ShowWindow(2)
        end
        return
    end
    if lower == "open" or lower == "show" then
        if StockPiler2.Ui and StockPiler2.Ui.ToggleWindow then
            StockPiler2.Ui.ToggleWindow()
        end
        return
    end
    if lower == "debug" or lower == "debug on" then
        SetDebugEnabled(true)
        return
    end
    if lower == "debug off" then
        SetDebugEnabled(false)
        return
    end
    if lower == "plan" then
        if StockPiler2.Planner and StockPiler2.Planner.Dump then
            Print(T("boot.plan_note"))
            StockPiler2.Planner.Dump(function(msg) EmitLog(msg) end)
            Print(T("boot.plan_dumped"))
        end
        return
    end
    if lower == "watchplan" then
        if StockPiler2.Planner and StockPiler2.Planner.DumpWatchPlan then
            Print(T("boot.watchplan_note"))
            StockPiler2.Planner.DumpWatchPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.watchplan_dumped"))
        end
        return
    end
    if lower == "state" then
        if StockPiler2.Orchestrator and StockPiler2.Orchestrator.DumpState then
            StockPiler2.Orchestrator.DumpState(function(msg) EmitLog(msg) end)
            Print(T("boot.state_dumped"))
        end
        return
    end
    if lower == "growplan" then
        if StockPiler2.Planner and StockPiler2.Planner.DumpGrowPlan then
            Print(T("boot.growplan_note"))
            StockPiler2.Planner.DumpGrowPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.growplan_dumped"))
        end
        return
    end
    if lower == "stats" then
        if StockPiler2.SeedMap and StockPiler2.SeedMap.DumpCraftCycleStats then
            StockPiler2.SeedMap.DumpCraftCycleStats(function(msg) EmitLog(msg) end)
            Print(T("boot.stats_dumped"))
        end
        return
    end
    if lower == "bags" or lower == "bags force" then
        if StockPiler2.BagAdapter and StockPiler2.BagAdapter.Dump then
            local force = string.find(lower, "force", 1, true) ~= nil
            StockPiler2.BagAdapter.Dump(function(msg) EmitLog(msg) end, { force = force })
            Print(T("boot.bags_dumped"))
        end
        return
    end
    if lower == "craftbag" or lower == "craftbag force" then
        if StockPiler2.BagAdapter and StockPiler2.BagAdapter.Dump then
            local force = string.find(lower, "force", 1, true) ~= nil
            StockPiler2.BagAdapter.Dump(function(msg) EmitLog(msg) end, { force = force })
            Print(T("boot.bags_dumped"))
        end
        return
    end
    if lower == "brewplan" then
        if StockPiler2.Planner and StockPiler2.Planner.DumpBrewPlan then
            StockPiler2.Planner.DumpBrewPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.brewplan_dumped"))
        elseif StockPiler2.Brew and StockPiler2.Brew.DumpPlan then
            StockPiler2.Brew.DumpPlan(function(msg) EmitLog(msg) end)
            Print(T("boot.brewplan_dumped"))
        end
        return
    end
    if lower == "buyplan" then
        if StockPiler2.Buy and StockPiler2.Buy.DumpBuyPlan then
            StockPiler2.Buy.DumpBuyPlan({ force = true })
            Print(T("boot.buyplan_dumped"))
        end
        return
    end
    if lower == "events on" then
        SetEventTrace(true)
        return
    end
    if lower == "events off" then
        SetEventTrace(false)
        return
    end
    if lower == "events dump" then
        if StockPiler2.Debug and StockPiler2.Debug.DumpEventRing then
            StockPiler2.Debug.DumpEventRing(function(msg) EmitLog(msg) end)
            Print(T("boot.events_dumped"))
        end
        return
    end
    if lower == "events" then
        local s = StockPiler2.Persistence.EnsureSettings()
        SetEventTrace(not (s.eventTrace == true))
        return
    end
    if lower == "audit mapping" then
        if StockPiler2.Audit and StockPiler2.Audit.RunMapping then
            StockPiler2.Audit.RunMapping(function(msg) EmitLog(msg) end)
            Print(T("boot.mapping_dumped"))
        end
        return
    end
    if lower == "audit" then
        if StockPiler2.Audit and StockPiler2.Audit.Run then
            StockPiler2.Audit.Run(function(msg) EmitLog(msg) end)
            Print(T("boot.audit_dumped"))
        end
        return
    end
    if lower == "mem" then
        if StockPiler2.Audit and StockPiler2.Audit.RunMem then
            StockPiler2.Audit.RunMem(function(msg) EmitLog(msg) end)
            Print(T("boot.mem_dumped"))
        end
        return
    end
    if lower == "harvest" then
        local B = StockPiler2.EventBus
        local E = StockPiler2.Events
        if B and E and E.CMD_HARVEST then
            B.Fire(E.CMD_HARVEST, {})
        end
        return
    end
    Print(T("boot.unknown_cmd"))
end

function StockPiler2.Initialize()
    StockPiler2.Persistence.EnsureSettings()
    if StockPiler2.Locale and StockPiler2.Locale.Initialize then
        StockPiler2.Locale.Initialize()
    end
    StockPiler2.Persistence.EnsureAccount()
    local s = StockPiler2.Settings
    if type(s) == "table" and StockPiler2Window then
        local tab = tonumber(s.selectedTab) or 1
        if tab < 1 or tab > 2 then
            tab = 1
        end
        StockPiler2Window.SelectedTab = tab
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.Initialize then
        StockPiler2.Scheduler.Initialize()
    end
    if StockPiler2.Orchestrator and StockPiler2.Orchestrator.Initialize then
        StockPiler2.Orchestrator.Initialize()
    end
    if StockPiler2.Macro and StockPiler2.Macro.Initialize then
        StockPiler2.Macro.Initialize()
    end
    if StockPiler2.EngineEventBridge and StockPiler2.EngineEventBridge.Register then
        StockPiler2.EngineEventBridge.Register()
    end
    if StockPiler2.LearnBridge and StockPiler2.LearnBridge.Initialize then
        StockPiler2.LearnBridge.Initialize()
    end
    if StockPiler2.Ui and StockPiler2.Ui.InitializeWindow then
        StockPiler2.Ui.InitializeWindow()
    end
    if StockPiler2.Ui and StockPiler2.Ui.RegisterEventRefresh then
        StockPiler2.Ui.RegisterEventRefresh()
    end
    if StockPiler2.Brew and StockPiler2.Brew.RegisterEventHandlers then
        StockPiler2.Brew.RegisterEventHandlers()
    end
    if LibSlash and LibSlash.RegisterWSlashCmd then
        LibSlash.RegisterWSlashCmd("sp2", StockPiler2.OnSlash)
        LibSlash.RegisterWSlashCmd("stockpiler2", StockPiler2.OnSlash)
    end
    EmitLog("init v" .. tostring(StockPiler2.Version)
        .. " debug=" .. tostring(StockPiler2.Debug.Enabled == true)
        .. " perf=" .. tostring(StockPiler2.Perf and StockPiler2.Perf.Enabled == true))
    Print(T("boot.loaded", { version = StockPiler2.Version }))
    if StockPiler2.Scheduler then
        StockPiler2.Scheduler.EnqueueBagFlush(true)
    end
end

function StockPiler2.Shutdown()
    if StockPiler2.Macro and StockPiler2.Macro.Shutdown then
        StockPiler2.Macro.Shutdown()
    end
    if StockPiler2.LearnBridge and StockPiler2.LearnBridge.Shutdown then
        StockPiler2.LearnBridge.Shutdown()
    end
    if StockPiler2.EngineEventBridge and StockPiler2.EngineEventBridge.Unregister then
        StockPiler2.EngineEventBridge.Unregister()
    end
    if StockPiler2.Scheduler and StockPiler2.Scheduler.Shutdown then
        StockPiler2.Scheduler.Shutdown()
    end
    if StockPiler2.RecipeSpec then
        if StockPiler2.RecipeSpec.SlimAllRecipesForStorage then
            StockPiler2.RecipeSpec.SlimAllRecipesForStorage()
        end
        if StockPiler2.RecipeSpec.SlimAllPotionsForStorage then
            StockPiler2.RecipeSpec.SlimAllPotionsForStorage()
        end
    end
    if StockPiler2.StripLeakedKeysFromAccount and StockPiler2.Account then
        StockPiler2.StripLeakedKeysFromAccount(StockPiler2.Account)
    end
    StockPiler2._sessionSettings = nil
    EmitLog("shutdown")
end
