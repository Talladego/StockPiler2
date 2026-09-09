# StockPiler3 — Complete Build Prompt

Use this document as the sole product + architecture + performance specification for a greenfield **StockPiler3** addon for Return of Reckoning (Warhammer Online). It is written to be usable in **any** AI-powered build environment that can fetch the public GitHub references below—no local game install sibling folders, no private workspace paths, and no dependency on other addons that happen to sit next to a developer’s clone.

Implement behavior from these contracts. Reimplement all logic. Do **not** copy StockPiler / StockPiler2 Lua for Core, Stores, Planner, domain modules, Executors, Knowledge, Macro, or Persistence.

**Feature parity baseline:** StockPiler2 **0.4.41** user-facing surface (as documented in that repo’s README and this prompt).

---

## 1. Mission

StockPiler3 is a Cultivation + Apothecary stock-automation addon. Players watch potions, set bag stock targets, AutoGrow plots from deficits and a seed buffer, refine plants to seeds when needed, harvest ready plots via footer/macro, brew Ready watches, and AutoBuy craft mats at vendors—without hijacking native craft skills. The addon must stay responsive during harvest, refine, and vendor storms: **performance is equal priority with feature parity**.

---

## 2. References (public only)

| Resource | URL | How to use it |
| :--- | :--- | :--- |
| StockPiler (SP1) | https://github.com/Talladego/StockPiler | Historical behavior; denser UI/work coupling — **do not copy** as architecture |
| StockPiler2 (SP2) | https://github.com/Talladego/StockPiler2 | Feature + View **XML** source of truth; README for UX; Lua = behavioral reference only |
| Stock RoR UI | https://github.com/xyeppp/RoR-Interface | Default `interface/` — templates, window/skin patterns, `SystemData` / `GameData` usage, FrameManager |
| WarTriage (macro UX precedent) | https://tools.idrinth.de/addons/wartriage/ | Public addon that creates a hotbar macro and updates its appearance; **pattern inspiration only** |
| GatherButton (macro API precedent) | Discussed on RoR forums / community addon trees (e.g. GatherButton `CreateMacro` / `SetMacroData` patterns) | Same family of macro create + rebind patterns SP1/SP2 used |
| LibSlash (optional) | Common RoR slash library (CurseForge / community mirrors; name `LibSlash`) | Optional `.mod` dependency; register `/sp3` when present; also support a no-LibSlash fallback |

**Do not assume** a local `Interface/AddOns/…` tree, LibPerf, PotionBar, or any other sibling addon exists in the build environment. If a pattern came from those sources, this document **describes the pattern** so you can reimplement it.

### 2.1 Patterns to reimplement (not “require that addon”)

**ActionBar craft macros (WarTriage / GatherButton / SP1–SP2 family)**

1. Find or create a named macro slot via the game macro APIs (`DataUtils.GetMacros`, `SetMacroData` / equivalent — see stock UI + GatherButton-style code).
2. Macro body is a `/script Addon.Macro.HarvestClick()` (or Brew) call—**not** a hijack of stock Cultivating / Apothecary skill buttons.
3. Player drags the macro to a hotbar. On activate, run the same prepare/activate path as the window footer.
4. Keep hotbar button icon/enabled state in sync with footer readiness; when gated, use the icon’s `_disabled` DDS variant (no checkbox overlays).
5. On `PLAYER_HOT_BAR_UPDATED` (or equivalent), only re-apply appearance when the Harvest/Brew **slot fingerprint** (slot id + action identity) changed; ignore echoes from your own refresh; coalesce enable sync.

**Optional slash registration**

- If `LibSlash.RegisterWSlashCmd` / `RegisterSlashCmd` exists, register `sp3` and `stockpiler3`.
- Always provide a fallback so the addon still loads and can open via a default keybind or settings entry if LibSlash is absent (match SP2: prefer LibSlash when available).

**Frametime hitch logger (in-addon; do not require LibPerf)**

- OnUpdate (or bridge post-update): if frame delta ≥ threshold (persisted, default ~400ms), log a breadcrumb **trail** of recent named sections (`Perf.Begin` / `End` or equivalent).
- Hold the trail only during real harvest/brew work sections—not idle “op active” flags and not mere `planDue`.
- Empty trail on a hitch usually means engine/DXVK/other UI—not a missing Begin site.

### 2.2 Reuse vs rewrite

- **May copy/adapt from the SP2 GitHub repo:** View XML files listed in §8 (clone SP2 or fetch those paths from https://github.com/Talladego/StockPiler2). Rename `StockPiler2*` → `StockPiler3*`.
- **Must rewrite:** all Lua, including View controllers.
- **Do not copy:** SP1/SP2 Core, Stores, Planner, Grow, Refine, Brew, Buy, Macro, Knowledge, Persistence Lua.

---

## 3. Priorities

1. **Feature parity** with SP2 0.4.41 (Watch, AutoGrow, Refine, Harvest, Brew, AutoBuy, macros, diagnostics, tooltips/chat).
2. **Performance** equal priority — §6 doctrine; verify §14 perf scenarios.
3. **Prescribed architecture** (§5).
4. Clean separation from SP1/SP2 (folder, `.mod`, saved vars, macro names, slash).

---

## 4. Non-goals

- Bank / alt-aware stock targets
- Auction house buying or vendor route planning
- Dedicated Plants tab (raise potion targets instead)
- Idle plant-bag floors without raising potion targets
- Full bulk-refine / craft-queue product
- Export/import watch presets
- Finer scenario/combat pause policies beyond scenario Flatten/plan deferral
- Migrating SP1/SP2 saved variables (fresh Account; relearn in-game)
- Depending on LibPerf or any non-listed third-party addon for core function

---

## 5. Recommended architecture (required)

### 5.1 SP1 → SP2 lesson

SP1 mixed UI, planning, and craft work in fewer, thicker modules → harder craft/UI stalls. SP2 separated **adapters**, **gen-keyed stores**, a **pure planner**, **domain intents**, **executors**, and a **single orchestrated tick**, then added **UI coalescing** and **critical-path deferral**. StockPiler3 must keep that separation; performance rules are part of the architecture.

### 5.2 Layer diagram

```text
Engine events
    → EngineEventBridge
        → EventBus
            → Stores (generation counters, dirty flags)
                → Orchestrator (phases + paced tick + job priority)
                    → Planner.Build (pure, gen-keyed cache)
                    → Domain (Grow / Refine / Brew / Buy intents)
                    → Executors (issue actions; pending discipline)
                        → Adapters (Cultivator / Apothecary / Bag / Vendor / CraftChat)
                    → View (snapshots only; coalesced flush)
Macro (named macros + fingerprint-gated appearance — §2.1)
Persistence (character settings vs account knowledge)
```

### 5.3 Mandated modules

| Layer | Responsibility |
| :--- | :--- |
| **Adapters** | Thin wrappers: cultivator, apothecary, bags, vendor, craft chat, trade-skill caps. Cache expensive lookups (e.g. FindSeedSlot). No business rules. |
| **Stores** | Inventory, Garden, RefinePipeline, Knowledge, Watch, PlanSnapshot. Generation counters; dirty flags. |
| **Planner** | Pure `Build()` from store snapshots. Cache keyed by store gens. No side effects / engine calls. While UI coalesce is pending, serve last snapshot rather than rebuilding. |
| **Domain** | Grow, Refine, Brew, Buy — *what* to do. |
| **Executors** | *How* — plant, refine uses, brew load/perform, vendor buy; pending/outstanding. |
| **Orchestrator + Scheduler** | Phase FSM; paced tick; plant→additives→refine→buy order; fillBlocked; scenario/defer; harvest wake. |
| **View** | Reads plan/store snapshots only. Never drives refine/grow from list rebuilds. |
| **Macro** | §2.1 pattern; enable with footer. |
| **Persistence** | `StockPiler3.Settings` + `StockPiler3.Account`. |
| **Core** | EventBus, Debug, Perf (in-addon hitch logger), Audit. |

### 5.4 Suggested folder layout

```text
StockPiler3/
  StockPiler3.mod
  Source/
    Bootstrap.lua
    Core/         EventBus, Scheduler, Orchestrator, EngineEventBridge, Debug, Perf, Audit
    Stores/       Inventory, Garden, RefinePipeline, Knowledge, Watch, PlanSnapshot
    Planner/      Planner.lua
    Grow/         Grow.lua
    Brew/         Brew.lua
    Refine/       Refine.lua
    Buy/          Buy.lua
    Executors/    Grow, Refine, Brew, Buy
    Adapters/     Bag, Cultivator, Apothecary, Vendor, CraftChat, TradeSkillCaps
    Knowledge/    RecipeSpec, SeedMap, BrewLearn, LearnBridge, Classify, MaterialSpec, Additives, Items, Shims
    Macro/        Macro.lua
    Persistence/  Settings, Character, Account
    View/         Window, Templates, TabPotions, TabWatch, Catalog, Ui, tooltips
```

### 5.5 Orchestrator — phases, tick order, fillBlocked

**Phases (expose in `/sp3 state`):** at least `idle`, `planting`, `refining`, `harvesting`, `buying` (emit `PHASE_CHANGED` on the bus when changing).

**Tick order (when AutoGrow / related work is due):**

1. Plant (one seed) if a plantable job exists and not in plant quiet / fillBlocked for plant
2. Optional stage additives for in-progress plots when enabled
3. Refine intents (buffer / plant-need) subject to plant-first rules
4. AutoBuy when vendor open and enabled (runs even if AutoGrow is off)

**fillBlocked:** after plant fail / no-seeds situations, block further **plant** attempts for N ticks (or a short time window). While fillBlocked: still allow **seed-buffer refine** and **AutoBuy**. Do **not** fill-block solely because refine intents are throttle-gated.

**Harvest wake:** after harvest, wake AutoGrow once; share **one** force plant-queue invalidate across multi-plot wake (P1–P4 style); start ~1.2s plant quiet. Do **not** ClearFillBlocked / WakeAutoGrow on every inventory snap (snap-wake storm / freeze risk).

**AutoGrow commit release:** when a plant commit completes or fails, release commit state promptly so the next tick can proceed—do not leave sticky commits that stall the pipeline.

### 5.6 Scheduler

- Coalesce `planDue` / UI dirty into deferred work; do not rebuild plan every bag event while coalesce pending.
- Distinct AutoGrow idle vs busy tick intervals (busier while planting/refining).
- Suppress redundant inventory ticks when a Flatten/snap is already scheduled.
- Distinguish **wake** (intentional) vs **snap** (inventory observation)—only wake paths force plant-queue invalidates.

### 5.7 Inventory tier model (L0–L3)

| Tier | Role |
| :--- | :--- |
| **L0** | Fast per-uid count adjust / live seed counts for refine headroom and harvest mat snapshots |
| **L2** | Flatten / aggregated bag view when structure changed |
| **L3** | Full expensive snap — rare |

Prefer L0 on critical paths. Never let a stale L2/L3 sample `stackCount` stomp L0 live trackers used for headroom.

Trust DataUtils dirty-gated `GetItems` / `GetCraftingItems` for L0 slot reads (one bag table per event). `FetchForce` / full Flatten only for session load or true desync — not refine-expire or soft dirty.

### 5.8 Planner gen cache

Cache key includes at least: `gardenGen + refinePipelineGen + watchGen + knowledgeGen` (+ inventory gen as needed). Invalidate only when gens change. While UI coalesce pending, return last built plan.

`Planner.Build` / `BuildBalancedSpecDemand`: one snapGen-keyed `WarmSpecHaveCache` bag pass (CountByUid for incomplete+boundUid specs); do not clear `_specHaveCache` twice or walk the bag once per ingredient spec.

Nested Build sections: `Build.WarmHave`, `Build.Demand`, `Build.Status`, `Build.Tips`. Plan-cache `IsHarvestByproduct`. Build all `RecipeSlotPlanEntry` once per deficit row (status + tipSlots share). Memo `CountCraftsPossible` per recipe key within a Build (non-reserve).

### 5.9 EventBus (illustrative catalog)

Publish/subscribe names such as: `INVENTORY_DIRTY` / `INVENTORY_FLAT`, `GARDEN_DIRTY` / `GARDEN_SYNC`, `PLAN_DUE` / `PLAN_BUILT`, `PHASE_CHANGED`, `CMD_HARVEST`, `CMD_BREW_*`, refine outstanding updates. Soften `GARDEN_DIRTY` so plot noise does not force full rebuilds every frame.

### 5.10 Knowledge learning

- **BrewLearn:** brewing a potion once stores recipe slot layout on Account.
- **SeedMap / LearnBridge:** seed↔plant maps from plant/harvest/refine observations; learn/snapshot only on real harvest **complete** attempts.
- **MaterialSpec:** material roles (main, stabilizer, extender, etc.).
- **Classify / Additives / Items:** supporting catalogs.
- **One-way / Liniment-class mains:** some harvest products are not plant→seed refinable; AutoGrow still plants/learns them without expecting refine (skill- and recipe-aware).

---

## 6. Performance doctrine (high priority)

Normative. Violating these fails acceptance even if features “work.”

1. **UI deferral during craft-critical ops** — No Watch list rebuild / full RefreshWatch during refine outstanding, buffer refine, AutoBuy visit, or harvest critical windows; coalesced flush after.
2. **Coalesced UI flush** — List repopulate and expensive labels through one deferred path. Open-window content key must include `knowledgeGen` (not only inventory/plan) so newly learned alternate recipe rows appear without reload.
3. **Planner deferral** — No rebuild on every bag tick while coalesce pending; defer Flatten/plan while in scenario (`isInScenario` or equivalent).
4. **Reconcile / walk cost** — Early-out; walk only outstanding seeds / dirty keys.
5. **Live counts over stale samples** — Seed budget / refine headroom prefer live uid (L0); never stomp live trackers with sample stacks alone.
6. **Pending discipline** — No same-tick pending-throttle clear + IssueOne retry (burst overshoot). Expire path clears stuck pending.
7. **Macro appearance storms** — Fingerprint gate; ignore self-refresh echoes; coalesce enable sync; short-circuit appearance work before opening Perf sections when unchanged; do not wipe dirty-reentry keys in a way that retriggers storms.
8. **Harvest path cost** — Learn/snapshot only on complete attempts; L0 / craft-bag-scoped snaps; nested perf sections for Snapshot vs Complete; LearnBridge work must not pull Refine into the harvest trail.
9. **AutoBuy batching** — No per-purchase Flatten/plan/jobs invalidate; batch after visit.
10. **Post-harvest plant delay** — ~1.2s quiet.
11. **Attribution honesty** — Empty-trail hitches ≈ engine/DXVK/other UI; do not spray Begin to “fix.” Rate-limit empty-trail spike uilog (keep summary counts); low thresholds must not flood every frame.
12. **Critical-path budget** — No large allocations, full catalog rebuilds, or all-watch walks on harvest complete / IssueOne / vendor buy.
13. **P1–P4 wake debounce** — One force plant-queue invalidate across multi-plot harvest wake, not one per plot event.
14. **No snap-wake storm** — Do not WakeAutoGrow / ClearFillBlocked on every inventory snap.
15. **Lookup caches** — Cache FindSeedSlot and seed-line lookups; invalidate on real bag structure changes.
16. **Softer garden dirty** — Do not treat every plot pulse as a full UI/plan invalidate.
17. **Trail hold policy** — Hold hitch trail during real harvest/brew sections only; exclude idle harvest-op flags and mere `planDue`.
18. **AutoGrow commit release** — Release sticky plant commits promptly (see §5.5).
19. **DataUtils L0 trust** — Slot events read one warm bag table; no FetchForce on hot paths (see §5.7).
20. **One-pass spec-have** — Planner/demand have-counts via snapGen-keyed `WarmSpecHaveCache` (see §5.8), not N× `ForEachItem` per unique ingredient spec.
21. **Brew coalesce** — No trail-hold for brew session; coalesce `SnapshotPotionCounts`; brew in Watch fill-burst; invalidate + `EnqueuePlanRebuild` (never sync force Build after brew).

**Minimal Perf/Debug surface:** hitch logger + trail; plan/state/grow/brew/buy dumps; debug uilog. Persist hitch threshold (default 400ms).

---

## 7. Product features

### 7.1 Packaging

- Addon folder `StockPiler3`, parallel-safe with StockPiler and StockPiler2 if those are also installed.
- Slash: `/sp3` (LibSlash when available — §2.1).
- Macros: **StockPiler3 Harvest**, **StockPiler3 Brew**. Ignore names `StockPiler Harvest` / `StockPiler Brew` / `StockPiler2 Harvest` / `StockPiler2 Brew`.
- Dependencies: EASystem_Utils, EASystem_WindowUtils, EATemplate_DefaultWindowSkin, EA_SettingsWindow, EA_ChatWindow, EASystem_Tooltips, EA_ActionBars; LibSlash optional.
- Category: CRAFTING.

### 7.2 Window and tabs

- **Potions** — learned catalog; name search; effect filter; known-recipe-only; sort columns (incl. Lvl); rarity-colored names; one row per recipe fingerprint; live refresh on knowledge gen; watch; forget; recipe/icon tooltips.
- **Watch** — master AutoGrow, additives, seed buffer enable + min chip, AutoBuy + reserve/budget; per-row target, AutoGrow, Status / Stock / Craftable; row Load/Brew. Column for per-row AutoGrow may be labeled AutoGrow (not “Priority”).
- **Footer** — Clear watches; Harvest (prepare + native activate); Brew (auto Ready); live tooltips that update while hovered when readiness changes.
- **Skill gates** — AutoGrow / additives / seed buffer / row AutoGrow → Cultivation; Brew → Apothecary; AutoBuy → Cultivation **or** Apothecary. Tooltips explain gated state.

### 7.3 Automation

- AutoGrow, Refine (buffer / plant-need), Harvest (manual), Brew (footer vs row), AutoBuy — see §9.

### 7.4 Knowledge

- Empty Account on install; brew once for slots; harvest/refine for seed maps; one-way mains without refine (§5.10).

### 7.5 Slash commands

| Command | Behavior |
| :--- | :--- |
| `/sp3` | Toggle main window |
| `/sp3 potions` / `watch` | Open on tab |
| `/sp3 help` | Command list |
| `/sp3 debug` / `on` / `off` | Structured uilog |
| `/sp3 plan` | Planner dump |
| `/sp3 watchplan` | Watch status / stock / craftable / shared |
| `/sp3 state` | Phase + store generations |
| `/sp3 growplan` | Garden / grow / refine diagnostics |
| `/sp3 brewplan` | Brew session + ready watches |
| `/sp3 buyplan` | Buy jobs |
| `/sp3 bags` / `bags force` | Bag snapshot |
| `/sp3 events` / `on` / `off` / `dump` | Event bus trace |
| `/sp3 perf` / `on` / `off` / `summary` | Hitch logger |
| `/sp3 perf on [ms]` / `baseline [ms]` | Threshold / baseline |
| `/sp3 audit` | Saved-variables health |
| `/sp3 harvest` | Prepare next ready plot |

---

## 8. UI specification + reuse whitelist

### 8.1 Whitelist (fetch from SP2 GitHub)

From https://github.com/Talladego/StockPiler2 (clone the repo or download these paths):

- `Source/View/StockPiler2Window.xml`
- `Source/View/StockPiler2TabPotions.xml`
- `Source/View/StockPiler2TabWatch.xml`
- `Source/View/StockPiler2Templates.xml`
- Any textures shipped under that addon, if present

Rename `StockPiler2*` → `StockPiler3*`. Rewrite all View Lua. If XML cannot be fetched, rebuild from the window tree + interaction tables below using stock skins from https://github.com/xyeppp/RoR-Interface.

### 8.2 Window tree map

```text
StockPiler3Window (movable, savesettings)
├─ Background, TitleBar, WindowImage, Close
├─ ButtonBackground
├─ TabButtons → Potions (id=1), Watch (id=2)
├─ WindowSocket
├─ TabPotions
│  ├─ Banner
│  ├─ SearchBox, EffectCombo, FilterKnownRecipe
│  ├─ Sort headers (Watch, Name, Effect, Power, Stability, SuperCrit, Yield, Have, Recipe, Forget)
│  └─ List → PotionRow { Watch, Icon, Name, Effect, …, Recipe, Forget }
├─ TabWatch
│  ├─ Banner
│  ├─ Enable AutoGrow, Additives
│  ├─ SeedBufferEnable, SeedBufferChip (min 4–20)
│  ├─ AutoBuy, ReserveChip (1–99), BudgetChip (1–999)
│  ├─ Column headers (Potion, Status, Stock, Craftable, Target, AutoGrow, Brew)
│  └─ List → WatchRow { Icon, Name, Status, Stock, Craftable, TargetChip, AutoGrow, Load }
└─ ClearWatches, Harvest (gameactionbutton), Brew
```

### 8.3 Interaction spec

| Control | Behavior |
| :--- | :--- |
| Tabs | Switch; persist `selectedTab` |
| Potion Watch | Toggle watch for recipe key |
| Potion Forget | Unlink this potion from its learned recipe; if other potions still share that recipe, keep the shared recipe data |
| Sort / Search / Effect / Known | Filter/sort; persist |
| Watch Enable / Additives / Seed buffer / AutoBuy | Toggles + chips; skill-gated; chat on settings change. Re-apply skill gates after session load / window show (tradeSkills often missing at CreateWindow Initialize). After session load with window already open, force bag/plan + active-tab list refresh so stock/craftable/status are not stale until a tab flip. |
| Row Target / AutoGrow / Load | Target L/R; AutoGrow flag; Load Idle→Load→Brew, R clears |
| Footer Brew / Harvest | §9.4–9.5; live tooltip ticks while hovered |
| Clear watches | Clear all character watches |

### 8.4 Traffic lights and tooltips

- **Green** — stocked or uncontested Ready
- **Yellow** — Ready-shared; restocking; need seeds / buffer
- **Red** — no recipe; enable AutoGrow; need Apo; buy ingredients; byproduct stabilizer with **no plant feedstock** (red, not yellow)
- Skip “Restocking materials” status when seed lines are empty.
- Contested Shared-materials slots: **(Shared)** not **(Stocked)**.
- **Seed Buffer tooltip:** recipe/restocking layout with dashed separators; green material headers; yellow detail; traffic-light SHORT / partial / OK for buffer lines.

---

## 9. Behavior contracts

### 9.1 Watch / shared materials

- Deficit = `max(0, targetStock − bag stock)` per enabled watch.
- Stocked watches do not join shared-mat contention.
- Contested craftable uses crafts **needed for deficit**, not max bag crafts.
- Green Ready vs yellow Ready-shared as in §8.4.
- AutoGrow keeps filling contested shared plants until Craftable can go green.
- Status keys: `ready_to_craft`, `ready_to_craft_shared`, restocking, and red block keys for missing recipe / skill / buy.

### 9.2 AutoGrow

- Master on + Cultivation; one seed per tick; plant-first before refine when a plantable job exists.
- Demand order: highest crafts short → fewest plots already growing that seed → role order (main → stabilizer/goldweed → extender → multiplier/stimulant → container → ingredient).
- Fallbacks: seed-buffer grow, then surplus grow (buffer on).
- **SHORT surplus block:** when buffer is SHORT for a seed, do not surplus-grow that seed.
- **Must not** buffer-grow while refinable plants for that seed remain.
- Buffer credit = bag + in-ground (no uproot).
- ~1.2s post-harvest plant quiet.
- Skill skip for seeds the character cannot use.
- Optional additives; no plant while brew session loading/crafting.
- One-way / Liniment-class: plant/learn without expecting plant→seed refine (§5.10).

### 9.3 Refine

- When seeds needed (empty plot no plant job, post-harvest buffer refill, seed-buffer pending).
- Plant-first; surplus plant jobs must not block seed-buffer refine.
- Headroom = target − (bag + in-ground + outstanding); clamp IssueOne to fresh live headroom (buffer batch ≤ ~5).
- No pending-throttle burst retry; expire clears stuck pending.
- Prefer status Refine / Seed buffer over Buy seeds when refinable plants remain.
- Throttle-only must not fill-block AutoGrow plant path.

### 9.4 Harvest

- Ready chat/sound only when every **planted** plot is grown (empty ignored).
- Enable footer/macro when ready plots exist and brew not loading/crafting.
- Manual/native harvest only.
- Footer Harvest: bind/clear `PERFORM_CRAFTING`/Cultivation only on ready transitions (skip redundant SetGameActionData — strips DefaultResizeable chrome). Keep HandleInput on so tooltips work. Clear bind when leaving Watch.
- After harvest: single wake + quiet; refine due only if no plantable seed job remains.

### 9.5 Brew

- Apothecary gated.
- Footer: green Ready only (`deficit > 0`, uncontested craftable).
- Footer enable matches click usefulness: grey while load job / performing / brew op-lock; after load, lit for Ready craft (or another Ready pick); not lit for stale non-Ready loads (R-click clears).
- Row: may overstock / yellow shared when craftable.
- Auto footer session clears when target met; manual row may continue.
- Load from crafting bag; no brew while pending plant commits.
- R-click clears load; board changes invalidate owned session.
- **`brewRespectGrowReserve` (default true):** when brew and AutoGrow would compete for the same seed/buffer reserve, prefer not starving AutoGrow’s reserved seeds. Persist the flag; no dedicated UI required unless you add one.

### 9.6 AutoBuy

- Independent of AutoGrow when vendor open.
- Cult/Apo craft mats; plant/seed buys only if Cultivation missing.
- No growables when character can AutoGrow.
- Gold reserve + per-visit budget; store-close detection; resume on reopen.
- No alt-currency / non–cult-apo junk.

### 9.7 Macros

- Implement §2.1 fully (create, activate, tooltips, `_disabled` icons, fingerprint gating).
- Enable with footer; do not hijack stock craft skills.

### 9.8 Chat / sounds

| Event | Behavior |
| :--- | :--- |
| Harvest all-planted ready | One-shot chat + `HELP_TIPS_NEW`; clear key when not ready |
| Footer Brew Ready appears | One-shot chat + `HELP_TIPS_HIGHTLIGHT_WINDOW`; clear when gone |
| Plant op | Chat with reason |
| Brew success / fail | Chat |
| TabWatch settings change | Chat |
| Watch status becomes red | One-shot chat per transition |

---

## 10. Data model / persistence

### 10.1 Saved variables

| Variable | Scope | Contents |
| :--- | :--- | :--- |
| `StockPiler3.Settings` | Shared profile | UI prefs + `characters[name]` |
| `StockPiler3.Account` | Global | Learned knowledge |

Separate from `StockPiler.*` and `StockPiler2.*`.

### 10.2 Settings (profile)

- `settingsVersion`, `charactersVersion`, `characters = {}`
- `debugEnabled`, `eventTrace`, `perfEnabled`, `perfThresholdMs` (400)
- `selectedTab`, potion filters/sort fields

### 10.3 Character bucket

Key = player name (strip trailing `^…` realm markup); fallback `_default`.

| Field | Default / clamp |
| :--- | :--- |
| `watches` | map → `{ enabled, targetStock, autoGrow }` |
| `autoGrowEnabled` / `autoGrowAdditives` | false |
| `autoBuyEnabled` | false |
| `autoBuyReserveGold` | 10 (1–99) |
| `autoBuyBudgetGold` | 50 (1–999) |
| `growSeedBufferMin` | 5 (4–20) |
| `growSeedBufferEnabled` | true |
| `brewMacroEnabled` | true unless explicitly false |
| `brewRespectGrowReserve` | true |

Watch defaults: `enabled = false`, `targetStock = 40`, `autoGrow = false`.

### 10.4 Account

Empty install: `accountVersion`, `items`, `grows`, `refines`, `recipes`, `potions`, `additives`, `vendorItems`. Relearn in-game.

---

## 11. Platform constraints

1. RoR Lua does **not** hoist `local function` — define callees above callers (large RecipeSpec-style files).
2. Validate before engine APIs; contextual `TryCall`; never blind `pcall`; report failures with context.
3. Prefer named `SystemData.*` / `GameData.*` as used in https://github.com/xyeppp/RoR-Interface — not unexplained magic numbers.
4. `WindowRegisterEventHandler`; FrameManager / window patterns from stock `interface/`.
5. `.mod` load order: Core → Stores → Planner → domain → View → Bootstrap.
6. Parallel-safe with StockPiler / StockPiler2 (no shared global mutation; distinct macro names).
7. No hard dependency on LibPerf, PotionBar, or other non-listed addons.

---

## 12. Invariants (hard lessons)

1. Live uid seed counts for headroom; do not stomp with stale samples.
2. Outstanding refine counts against headroom until delivery or expire.
3. Expire clears pending (no deadlock).
4. Shared craftable = deficit crafts only.
5. Contested tooltip **(Shared)**.
6. Learn/snapshot on harvest complete only.
7. Macro fingerprint gating.
8. Defer Watch UI during refine outstanding / buffer refine / AutoBuy visit.
9. Scenario Flatten/plan deferral.
10. ~1.2s post-harvest plant quiet.
11. Prefer Refine/Seed buffer status over Buy seeds when refinable plants remain.
12. Empty Account on install is intentional.
13. No snap-wake storm; debounce multi-plot harvest wake.
14. fillBlocked blocks plant, not buffer refine / AutoBuy; throttle-only ≠ fill-block.
15. One-way mains do not require refine to satisfy AutoGrow learning/planting.

---

## 13. Diagnostics

Slash-driven: debug uilog (`StockPiler3| …`); plan/watchplan/state/growplan/brewplan/buyplan/bags; event ring; perf hitch logger + baseline; audit. Empty-trail spikes → likely engine—do not Begin-spam.

---

## 14. Acceptance scenarios

### Feature

1. First install — empty Account; brew once → recipe in catalog.
2. Watch toggle → Watch tab; target 40; status updates.
3. Shared contention — yellow Shared; footer skips; AutoGrow toward green.
4. Shared tooltip — (Shared) not (Stocked).
5. AutoGrow plants one seed/tick by demand.
6. Seed buffer — bag+in-ground; refine shortfall; batch when plots full; SHORT/partial/OK tooltip.
7. SHORT surplus block — no surplus grow while SHORT.
8. No buffer-grow while refinable plants remain.
9. Mass buffer refine — no live-seed overshoot past headroom.
10. Post-harvest ~1.2s plant quiet.
11. Harvest ready chat/sound once; empty plots ignored.
12. Footer Brew Ready-only; session clear after auto target hit.
13. Row overstock / yellow shared Load/Brew allowed.
14. Brew R-click clears load.
15. AutoBuy reserve/budget + reopen resume.
16. AutoBuy no growables when Cultivation present.
17. Skill gates on UI + footer + macros (`_disabled` icons).
18. Macros created; SP1/SP2 names ignored; enable with footer.
19. Clear watches.
20. Parallel SP1/SP2 installed — SP3 macros/saved vars intact.
21. Forget potion — unlinks potion; keeps shared recipe if siblings remain.
22. One-way / Liniment-class — plants/learns without refine loop.
23. Restocking — byproduct stabilizer red without feedstock; no Restocking status with empty seed lines.
24. Seed buffer + Watch setting changes produce chat feedback.

### Performance

25. Refine UI quiet — no per-tick full Watch rebuild; flush after.
26. Hotbar noise — no Macro appearance storm (fingerprint).
27. Harvest complete — no LearnBridge every dirty frame.
28. Scenario — no Flatten/plan thrash every bag event.
29. AutoBuy multi-buy — no per-item full invalidate.
30. Empty trail honesty — not “fixed” by Begin spam.
31. Multi-plot harvest wake — single force invalidate + quiet (no P1–P4 storm).
32. Inventory snaps — no WakeAutoGrow/ClearFillBlocked storm.
33. FindSeedSlot / seed-line caches hit on repeated plant/refine.

---

## 15. Build order

Perf review at **each** milestone.

1. Skeleton — `.mod`, Bootstrap, slash (§2.1), Debug, EventBus, Scheduler, Perf, empty window
2. Persistence + audit
3. Adapters (thin + FindSeedSlot cache)
4. Stores + gens + Inventory L0–L3
5. EngineEventBridge (scenario deferral; soft GARDEN_DIRTY)
6. Planner (gen cache; shared craftable)
7. Knowledge (RecipeSpec, SeedMap, BrewLearn, LearnBridge, MaterialSpec, …) — local-order safe
8. UI — SP2 XML from GitHub whitelist or rebuild from §8; rewrite View Lua
9. Grow + executor (quiet, wake debounce, commit release, one-way)
10. Refine + executor (live headroom, pending discipline)
11. Brew + executor (footer vs row; grow reserve flag)
12. Buy + executor (batch invalidate)
13. Macro (§2.1 full)
14. Polish — tooltips (seed buffer, shared, live footer), chat/sounds, forget, acceptance §14
15. Perf pass — §6 + scenarios 25–33

---

## 16. Definition of done

- §7 features + §9 contracts match SP2 0.4.41 user-facing behavior.
- §5 architecture and §6 performance implemented and verified.
- §8 UI complete (XML from SP2 GitHub or equivalent rebuild).
- §14 acceptance (feature + perf) passes.
- No SP1/SP2 Core/domain Lua copied; no hard dependency on unpublished local addons.

**Start here:** create `StockPiler3` as a new addon; keep this file as the spec; clone https://github.com/xyeppp/RoR-Interface for stock UI patterns; clone https://github.com/Talladego/StockPiler2 only for View XML + behavioral cross-check; treat https://github.com/Talladego/StockPiler as historical contrast. Reimplement every pattern described in §2.1 rather than importing sibling addons from a developer machine.
