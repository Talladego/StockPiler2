<?xml version="1.0" encoding="UTF-8"?>

<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">

    <UiMod name="StockPiler2" version="0.2.1" date="2026-09-02">

        <Author name="Talladego" email="" />

        <Description text="StockPiler v2 — orchestrator architecture (grow, brew, plan). Runs alongside StockPiler v1." />

        <VersionSettings gameVersion="1.4.8" windowsVersion="1.0" savedVariablesVersion="1.0" />



        <Dependencies>

            <Dependency name="EASystem_Utils" />

            <Dependency name="EASystem_WindowUtils" />

            <Dependency name="EATemplate_DefaultWindowSkin" />

            <Dependency name="EA_SettingsWindow" />

            <Dependency name="EA_ChatWindow" />

            <Dependency name="EASystem_Tooltips" />

            <Dependency name="LibSlash" optional="true" />

        </Dependencies>



        <Files>

            <File name="Source/Core/Debug.lua" />

            <File name="Source/Core/EventBus.lua" />

            <File name="Source/Core/Perf.lua" />

            <File name="Source/Core/Audit.lua" />

            <File name="Source/Core/Scheduler.lua" />

            <File name="Source/Core/Orchestrator.lua" />

            <File name="Source/Core/EngineEventBridge.lua" />

            <File name="Source/Adapters/BagAdapter.lua" />

            <File name="Source/Adapters/CultivatorAdapter.lua" />

            <File name="Source/Adapters/ApothecaryAdapter.lua" />

            <File name="Source/Adapters/VendorAdapter.lua" />

            <File name="Source/Persistence/Settings.lua" />

            <File name="Source/Persistence/Character.lua" />

            <File name="Source/Persistence/Account.lua" />

            <File name="Source/Knowledge/Shims.lua" />

            <File name="Source/Stores/KnowledgeStore.lua" />

            <File name="Source/Knowledge/MaterialSpec.lua" />

            <File name="Source/Knowledge/Items.lua" />

            <File name="Source/Knowledge/Classify.lua" />

            <File name="Source/Knowledge/RecipeSpec.lua" />

            <File name="Source/Stores/WatchStore.lua" />

            <File name="Source/Stores/InventoryStore.lua" />

            <File name="Source/Knowledge/BrewLearn.lua" />

            <File name="Source/Knowledge/SeedMap.lua" />

            <File name="Source/Knowledge/Additives.lua" />

            <File name="Source/Adapters/CraftChatAdapter.lua" />

            <File name="Source/Knowledge/LearnBridge.lua" />

            <File name="Source/Stores/GardenStore.lua" />

            <File name="Source/Stores/RefinePipelineStore.lua" />

            <File name="Source/Stores/PlanSnapshotStore.lua" />

            <File name="Source/Planner/Planner.lua" />

            <File name="Source/Grow/Grow.lua" />

            <File name="Source/Refine/Refine.lua" />

            <File name="Source/Executors/GrowExecutor.lua" />

            <File name="Source/Executors/RefineExecutor.lua" />

            <File name="Source/Executors/BrewExecutor.lua" />

            <File name="Source/Buy/Buy.lua" />

            <File name="Source/Executors/BuyExecutor.lua" />

            <File name="Source/View/StockPiler2Catalog.lua" />

            <File name="Source/View/StockPiler2RecipeTooltip.lua" />

            <File name="Source/View/StockPiler2Ui.lua" />

            <File name="Source/View/StockPiler2Templates.xml" />

            <File name="Source/View/StockPiler2TabPotions.xml" />

            <File name="Source/View/StockPiler2TabWatch.xml" />

            <File name="Source/View/StockPiler2Window.xml" />

            <File name="Source/Bootstrap.lua" />

        </Files>



        <SavedVariables>

            <SavedVariable name="StockPiler2.Settings" />

            <SavedVariable name="StockPiler2.Account" global="true" />

        </SavedVariables>



        <OnInitialize>

            <CreateWindow name="StockPiler2Window" show="false" />

            <CallFunction name="StockPiler2.Initialize" />

        </OnInitialize>



        <OnShutdown>

            <CallFunction name="StockPiler2.Shutdown" />

        </OnShutdown>



        <WARInfo>

            <Categories>

                <Category name="CRAFTING" />

            </Categories>

        </WARInfo>

    </UiMod>

</ModuleFile>

