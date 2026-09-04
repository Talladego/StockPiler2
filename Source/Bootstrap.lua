----------------------------------------------------------------
-- StockPiler2 Bootstrap — init, shutdown, slash commands
----------------------------------------------------------------

StockPiler2 = StockPiler2 or {}
StockPiler2.Version = L"0.4.23"

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

local function SetDebugEnabled(on)
    local s = StockPiler2.Persistence.EnsureSettings()
    s.debugEnabled = on == true
    StockPiler2.Debug.Enabled = s.debugEnabled
    EmitLog("settings| debug=" .. (StockPiler2.Debug.Enabled and "ON" or "OFF"))
    Print(L"Debug " .. (StockPiler2.Debug.Enabled and L"ON" or L"OFF"))
end

local function SetEventTrace(on)
    local s = StockPiler2.Persistence.EnsureSettings()
    s.eventTrace = on == true
    StockPiler2.Debug.EventTrace = s.eventTrace
    Print(L"Event trace " .. (s.eventTrace and L"ON" or L"OFF"))
end

local function SetPerfEnabled(on)
    local s = StockPiler2.Persistence.EnsureSettings()
    s.perfEnabled = on == true
    if StockPiler2.Perf then
        StockPiler2.Perf.SetEnabled(s.perfEnabled)
    end
    Print(L"Perf " .. (s.perfEnabled and L"ON" or L"OFF"))
end

local function PrintHelp()
    Print(L"Commands:")
    Print(L"/sp2 - open window")
    Print(L"/sp2 help - show this help")
    Print(L"/sp2 potions | watch - open on a tab")
    Print(L"/sp2 debug [on|off] - uilog debug")
    Print(L"/sp2 plan | watchplan | state | growplan | brewplan | buyplan - dump to uilog")
    Print(L"/sp2 bags [force] - dump bag snapshot to uilog")
    Print(L"/sp2 events [on|off|dump] - event trace")
    Print(L"/sp2 perf [on|off|summary] - frametime hitch log")
    Print(L"/sp2 perf on [ms] | perf baseline [ms] - hitch threshold / baseline")
    Print(L"/sp2 audit [mapping] - saved-data health")
    Print(L"/sp2 harvest - prepare next ready plot (macro/CMD path)")
end

local function SetPerfThreshold(thresholdMs)
    if not StockPiler2.Perf then
        return
    end
    thresholdMs = tonumber(thresholdMs) or 400
    if thresholdMs < 50 then
        thresholdMs = 50
    end
    if StockPiler2.Perf.SetFrameThreshold then
        thresholdMs = StockPiler2.Perf.SetFrameThreshold(thresholdMs)
    else
        StockPiler2.Perf.FrameThresholdMs = thresholdMs
    end
    local s = StockPiler2.Persistence and StockPiler2.Persistence.EnsureSettings
        and StockPiler2.Persistence.EnsureSettings()
    if type(s) == "table" then
        s.perfThresholdMs = thresholdMs
    end
    Print(L"Perf threshold " .. towstring(tostring(thresholdMs)) .. L"ms")
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
            Print(L"Note: /sp2 plan forces a full rebuild (profiling only).")
            StockPiler2.Planner.Dump(function(msg) EmitLog(msg) end)
            Print(L"Plan dumped to uilog.log")
        end
        return
    end
    if lower == "watchplan" then
        if StockPiler2.Planner and StockPiler2.Planner.DumpWatchPlan then
            Print(L"Note: /sp2 watchplan forces a full rebuild (profiling only).")
            StockPiler2.Planner.DumpWatchPlan(function(msg) EmitLog(msg) end)
            Print(L"Watch plan dumped to uilog.log")
        end
        return
    end
    if lower == "state" then
        if StockPiler2.Orchestrator and StockPiler2.Orchestrator.DumpState then
            StockPiler2.Orchestrator.DumpState(function(msg) EmitLog(msg) end)
            Print(L"State dumped to uilog.log")
        end
        return
    end
    if lower == "growplan" then
        if StockPiler2.Planner and StockPiler2.Planner.DumpGrowPlan then
            Print(L"Note: /sp2 growplan runs heavy diagnostics (profiling only).")
            StockPiler2.Planner.DumpGrowPlan(function(msg) EmitLog(msg) end)
            Print(L"Grow plan dumped to uilog.log")
        end
        return
    end
    if lower == "bags" or lower == "bags force" then
        if StockPiler2.BagAdapter and StockPiler2.BagAdapter.Dump then
            local force = string.find(lower, "force", 1, true) ~= nil
            StockPiler2.BagAdapter.Dump(function(msg) EmitLog(msg) end, { force = force })
            Print(L"Bags dumped to uilog.log")
        end
        return
    end
    if lower == "craftbag" or lower == "craftbag force" then
        if StockPiler2.BagAdapter and StockPiler2.BagAdapter.Dump then
            local force = string.find(lower, "force", 1, true) ~= nil
            StockPiler2.BagAdapter.Dump(function(msg) EmitLog(msg) end, { force = force })
            Print(L"Bags dumped to uilog.log")
        end
        return
    end
    if lower == "brewplan" then
        if StockPiler2.Planner and StockPiler2.Planner.DumpBrewPlan then
            StockPiler2.Planner.DumpBrewPlan(function(msg) EmitLog(msg) end)
            Print(L"Brew plan dumped to uilog.log")
        elseif StockPiler2.Brew and StockPiler2.Brew.DumpPlan then
            StockPiler2.Brew.DumpPlan(function(msg) EmitLog(msg) end)
            Print(L"Brew plan dumped to uilog.log")
        end
        return
    end
    if lower == "buyplan" then
        if StockPiler2.Buy and StockPiler2.Buy.DumpBuyPlan then
            StockPiler2.Buy.DumpBuyPlan({ force = true })
            Print(L"Buy plan dumped to uilog.log (enable /sp2 debug for ongoing buy| lines)")
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
            Print(L"Event ring dumped to uilog.log")
        end
        return
    end
    if lower == "events" then
        local s = StockPiler2.Persistence.EnsureSettings()
        SetEventTrace(not (s.eventTrace == true))
        return
    end
    if string.find(lower, "^perf on", 1) == 1 then
        local thresholdMs = string.match(lower, "perf on%s+(%d+)")
        SetPerfEnabled(true)
        if thresholdMs then
            SetPerfThreshold(thresholdMs)
        end
        return
    end
    if lower == "perf off" then
        SetPerfEnabled(false)
        return
    end
    if lower == "perf summary" then
        if StockPiler2.Perf and StockPiler2.Perf.PrintSummary then
            StockPiler2.Perf.PrintSummary()
        end
        return
    end
    if string.find(lower, "^perf baseline", 1) == 1 then
        if StockPiler2.Perf then
            if StockPiler2.Perf.IsBaselineCollecting and StockPiler2.Perf.IsBaselineCollecting() then
                StockPiler2.Perf.PrintBaseline()
            else
                local thresholdMs = string.match(lower, "perf baseline%s+(%d+)") or 50
                StockPiler2.Perf.StartBaseline(tonumber(thresholdMs))
                SetPerfEnabled(true)
                Print(L"Perf baseline collecting (threshold " .. towstring(tostring(thresholdMs)) .. L"ms). Run /sp2 perf baseline again to print.")
            end
        end
        return
    end
    if lower == "perf" then
        local s = StockPiler2.Persistence.EnsureSettings()
        SetPerfEnabled(not (s.perfEnabled == true))
        return
    end
    if lower == "audit mapping" then
        if StockPiler2.Audit and StockPiler2.Audit.RunMapping then
            StockPiler2.Audit.RunMapping(function(msg) EmitLog(msg) end)
            Print(L"Mapping audit dumped to uilog.log")
        end
        return
    end
    if lower == "audit" then
        if StockPiler2.Audit and StockPiler2.Audit.Run then
            StockPiler2.Audit.Run(function(msg) EmitLog(msg) end)
            Print(L"Audit dumped to uilog.log")
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
    Print(L"Unknown /sp2 command. Try /sp2 help")
end

function StockPiler2.Initialize()
    StockPiler2.Persistence.EnsureSettings()
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
    if LibSlash and LibSlash.RegisterWSlashCmd then
        LibSlash.RegisterWSlashCmd("sp2", StockPiler2.OnSlash)
        LibSlash.RegisterWSlashCmd("stockpiler2", StockPiler2.OnSlash)
    end
    EmitLog("init v" .. tostring(StockPiler2.Version)
        .. " debug=" .. tostring(StockPiler2.Debug.Enabled == true)
        .. " perf=" .. tostring(StockPiler2.Perf and StockPiler2.Perf.Enabled == true))
    Print(L"v" .. StockPiler2.Version .. L" loaded. /sp2 to open window.")
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
