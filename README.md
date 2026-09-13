# StockPiler2

Greenfield rewrite of StockPiler using an **Orchestrator + Stores + Planner + Executors** architecture. Runs as a **separate addon** alongside v1 — does not modify the original StockPiler folder.

**Version:** 0.4.151

Repository: [Talladego/StockPiler2](https://github.com/Talladego/StockPiler2)

## Install

1. Ensure the `StockPiler2` folder is under `Interface/AddOns/`.
2. (Optional) Enable **LibPerf** for hitch logs via `/libperf StockPiler2 on`.
3. Enable **StockPiler2** in the addon list (v1 can stay enabled for parallel testing).
4. `/reloadui`

On first load, StockPiler2 creates ActionBar macros **StockPiler2 Harvest** and **StockPiler2 Brew** (if an empty macro slot exists). Drag them to a hotbar for click + keybind harvest/brew. Leftover v1 macros (`StockPiler Harvest` / `StockPiler Brew`) are ignored.

## Commands

| Command | Description |
| :--- | :--- |
| `/sp2` | Toggle main window |
| `/sp2 potions` / `watch` | Open window on a tab |
| `/sp2 help` | Command list |
| `/sp2 debug` / `on` / `off` | Structured uilog (`StockPiler2\| …`) |
| `/sp2 plan` | Planner dump (includes watch rows) |
| `/sp2 watchplan` | Watch-row status / stock / craftable / shared dump |
| `/sp2 state` | Orchestrator phase + store generations |
| `/sp2 growplan` | Garden / grow / refine diagnostics |
| `/sp2 stats` | Craft-cycle stats (plant/harvest/crit/SM, refine, brew rates) |
| `/sp2 brewplan` | Brew session + ready watches dump |
| `/sp2 buyplan` | Buy job dump |
| `/sp2 bags` / `bags force` | Bag snapshot dump |
| `/sp2 events` / `on` / `off` / `dump` | Internal event bus trace |
| `/libperf StockPiler2 …` | Frametime hitch logger (optional **LibPerf**; see `/libperf help`) |
| `/sp2 audit` | Saved variables health |
| `/sp2 mem` | Live table key counts only (safe footprint triage; do **not** `d(StockPiler2)`) |
| `/sp2 harvest` | Prepare next ready plot (macro/CMD path) |

Perf tip: enable the **LibPerf** addon (optional dependency). Use `/libperf StockPiler2 on 250` (settings persist in LibPerf; thresholds below 250 are bumped on load because the client idle floor is often ~140–155 ms). Spikes with `trail=(none)` / high `emptyTrail%` on baseline are usually **engine** stalls (native craft/UI, DXVK, other addons, zone load)—not missing Lua sites. Empty trail means SP2 did not `Begin` recently; leave those alone. Empty-trail spike lines are rate-limited (summary still counts every hitch). Logs: `logs/libperf_StockPiler2.log`. Use `/libperf scopes` to list paths.

## UI

- **Potions tab** — learned potion list, search/effect filters, sort columns, watch toggle; placeholder tooltips use the potion icon
- **Watch tab** — AutoGrow / AutoBuy / seed buffer, per-row target and AutoGrow, traffic-light status / stock / craftable
- **Skill gates** — AutoGrow needs Cultivation; Brew needs Apothecary; AutoBuy needs Cultivation or Apothecary
- **Row Brew** — Idle → Load → Brew (L-click); R-click unloads that row’s load
- **Footer Brew** — auto-picks green Ready watches only; R-click clears the load
- **Footer Harvest** — native cultivation harvest when plots are ready
- **ActionBar macros** — same activate + tooltips as footer Harvest/Brew; enabled/disabled with the footer (mushroom / madened-speed elixir icons)

## AutoGrow

- Plants empty plots from watch deficits and seed buffer (one seed per orchestrator tick).
- Seed buffer credits bag + in-ground seeds; shortfalls refine when needed (batched when plots are full).
- After harvest, replant is delayed slightly so AutoGrow work does not stack on the engine harvest hitch.
- Additives optional via Watch tab.

## Brew behavior

- Footer Brew only loads/performs watches that are **Ready to brew** (deficit > 0, uncontested craftable).
- After an **auto** brew hits the watch target, the session clears so the next footer click can pick another Ready watch.
- **Manual** row Load/Brew can overstock (target already met or yellow shared craftable).
- Shared-materials contention uses crafts **needed for deficit**, not max crafts possible from bags.

## AutoBuy

- Buys Cultivating / Apothecary craft mats (and plant/seed buys when Cultivation is missing).
- Prefers materials for watches with the largest bottle gap (Target−Stock−Craftable), same starve-first idea as AutoGrow; falls back to all short watches when focus has no buyable mats.
- Respects gold reserve / budget stops; reopens correctly after vendor close.

## Architecture

```
Core/         EventBus, Scheduler, Orchestrator, EngineEventBridge, Debug, Perf, Audit
Stores/       Inventory, Garden, RefinePipeline, Knowledge, Watch, PlanSnapshot
Planner/      Pure Build() with gen-keyed cache
Grow/         Plant job pick + harvest helpers
Brew/         Load / perform / session (footer + row)
Refine/       Seed buffer refine intents
Buy/          Vendor buy jobs
Macro/        ActionBar Harvest / Brew macros (WarTriage rebind)
Executors/    Grow / Refine / Brew / Buy
Adapters/     Bag, Cultivator, Apothecary, Vendor, CraftChat, TradeSkillCaps
Persistence/  Settings, Character, Account
View/         Window, Templates, TabPotions, TabWatch, Catalog, Ui
```

## Saved data

StockPiler2 starts with **empty** learned data. Relearn recipes in-game (brew once so slots are stored).

| Variable | Scope | Contents |
| :--- | :--- | :--- |
| `StockPiler2.Settings` | Shared profile | UI prefs + `characters[characterName]` rows |
| `StockPiler2.Account` | Global | Learned knowledge |

Separate from v1 `StockPiler.*` saved variables.

## Localization

English catalog lives in `Source/Locale/enUS.lua`. User chat and on-screen UI go through `StockPiler2.T(key, tokens)`.

- Templates are `L"..."` wstrings; for chat use ASCII punctuation only (`-`, `|`, `...`) — no UTF-8 fancy dashes/ellipsis in narrow strings (see RoR-Interface `docs/api/lua-chat-strings.md`).
- Tokens are named `{name}`, `{count}`, etc.; values are coerced with `towstring`.
- `settings.language = 0` follows the game language; only enUS ships today (other packs fall back per key).
- Phase 2 covers Window/Potions/Watch chrome, recipe/watch tips, Planner Status column, Harvest/Brew tooltips, and MaterialSpec tip meta.
- Phase 3 (secondary languages) is deferred. Macro identity names stay English for slot lookup stability.

## Profiling (LibPerf)

Install and enable **LibPerf** alongside StockPiler2. Then `/libperf StockPiler2 on 250` writes hitch breadcrumbs to `logs/libperf_StockPiler2.log`. All enable/threshold/summary/baseline (global and per-scope) is via `/libperf` only; StockPiler2 registers the `StockPiler2` scope at load.

## Memory / introspection

Use `/sp2 mem` for safe key counts (`Inventory._specParseCache`, Account maps, plan rows, RecipeSpec caches). **Do not** `d(StockPiler2)` — EA debug walks full bag item tables and can freeze/disconnect the client.

## Future considerations

Optional ideas for later — not commitments:

- **Bank / alts** — stock targets stay bag-local; no cross-character or bank-aware targets
- **Multi-character / shared Account learnings** — deeper “this alt can’t grow that tier” UX on top of shared Account knowledge
- **Scenario / combat / travel policy** — finer “pause AutoGrow in context X” rules
- **Vendor / AH strategy** — AutoBuy is store-visit only; no auction house or route planning
- **Idle plant-bag floors** without raising potion targets — consciously deferred (raise the potion target instead)
- **Bulk refine / queue craft** — not a full refine-automation product
- **Export/import watch presets** — convenience

A dedicated **Plants** tab was considered and rejected; surplus plant materials are handled by raising potion stock targets instead.

## Rebuild blueprint (StockPiler3)

[`docs/STOCKPILER3_BUILD_PROMPT.md`](docs/STOCKPILER3_BUILD_PROMPT.md) is the maintained **future blueprint** for a clean-room StockPiler3 rebuild (features, prescribed architecture, performance doctrine, acceptance scenarios). Keep it current whenever SP2 ships:

- new user-facing features or UX behavior
- important performance optimizations
- important bug fixes that change contracts, invariants, or hard lessons

Treat prompt updates as part of those ships—not a one-off doc.

## Versioning

On each user-facing ship, bump together:

1. `StockPiler2.mod` `version` + `date`
2. `Source/Bootstrap.lua` `StockPiler2.Version`
3. This README **Version:** line + a changelog bullet below
4. [`docs/STOCKPILER3_BUILD_PROMPT.md`](docs/STOCKPILER3_BUILD_PROMPT.md) when the ship adds features or important perf/bug-fix contracts (see **Rebuild blueprint** above)

| Bump | When |
| :--- | :--- |
| **Patch** (`0.x.Y+1`) | Bugfix / polish only |
| **Minor** (`0.X+1.0`) | New behavior / UX features |
| **Major** (`N+1.0.0`) | Breaking saved-var / architecture break (rare in 0.x) |

## Changelog

**0.4.151:** Fix — SeedMap split: `SeedMatchesGrowSpec` lives on shared `Private` (Resolve was calling a Core-only local every UPDATE_PROCESSED).

**0.4.150:** Architecture — SeedMap facade split (Core / Observe / Resolve / Maintenance); public `SeedMap.*` API unchanged.

**0.4.149:** Architecture — plant/brew engine writes routed only through GrowExecutor / BrewExecutor (Orch + domain call executors).

**0.4.148:** Architecture — Harvest/Brew footer chrome + tooltips moved to `View/HarvestChrome`, `View/HarvestTooltip`, `View/BrewChrome`, `View/BrewTooltip`.

**0.4.147:** Perf — Watch Status + Seed buffer tooltips are plan-snapshot only (no SpecDemand / CollectIntents on hover); live-patch Have counts on bag snap.

**0.4.146:** Architecture — `BuildBalancedSpecDemand` + WarmHave caches moved to `Planner/SpecDemand.lua` + `Planner/SpecHaveCache.lua`; RecipeSpec keeps thin one-release aliases.

**0.4.145:** Architecture nits (GrokBot Phase 0) — Orch.Initialize once-only; additive ticks via GrowExecutor.TryAdditive; drop craftbag slash alias; harvest active = Grow op-lock only; GrowExecutor header cleanup.

**0.4.144:** Perf — restore/bump LibPerf threshold to ≥250ms (client floor ~150ms); Footer no longer `Perf.Begin` on SyncActionReadiness no-ops (stops Footer xN000 trail glue). LibPerf 1.2.3 — low-threshold warn at 250ms.

**0.4.143:** Fix — Watch Status follows live bag counts for stocked / Ready to brew / Seed buffer flips within ~1s (no longer waits on deferred PlanRebuild). Brew session allows Watch paint every 1s so Stock/Status stay current while apo stays open.

**0.4.142:** Fix — sticky `refineConvertFailed` no longer permanently blacklists proven plant→seed converts (Gobswort/Goldweed/Fusk/Beardweed); session cooldown only. accountVersion 3 clears false SV flags; Special Squig Bits stays blocked. Unblocks AutoGrow when bag had plants but refinable=0.

**0.4.141:** Fix — AutoGrow plant spam: chat only when soil leaves EMPTY (no optimistic PlantSeed chat); garden-wide 8s quiet after unconfirmed plant; force InvalidatePlantQueue arms unconfirmed cooldowns instead of wiping protection. Fix — seed-buffer refine only converts surplus plants above brew need (stops burning Gobswort/Goldweed feedstock); 45s cooldown after no-convert / expire-stuck.

**0.4.140:** Fix — SeedMap pollution: Scorching Ashberry / Marshroot no longer map to Drunken Dandedragon (Energy). Matching ignores unrelated grows/refine.seedUid; PrimaryPlant never returns unrelated products; refine.seedUid prefers highest-sample related seedOut; load-time EnsureSpecBootstrap + accountVersion 2 cleanup. Grow.TryPlant only LearnMapping when pair looks related.

**0.4.139:** Fix — AutoGrow plant no longer blocked by `isInRvRLake` (idle lake stay was stuck empty); Watch **Combat pause** toggles combat/scenario plant pause only. Orch does not fill-block on combat/scenario defer. Perf — skip FrameWork.Pump on SkipPlan/harvest-storm; hold Footer for storm/quiet; HoldPlan/Orch prewarm waits include seed-lines.

**0.4.138:** Liniment purple seeds — prefer Eternal ≫ Exceptional ≫ blue when planting; treat Eternal/Exceptional as opaque replant (credit a full plot wave while owned; bag stack does not drop per plant). Strip Eternal/Exceptional/Bunched name prefixes for Bloodseed↔Powder relatedness.

**0.4.137:** Fix — failed refine converts (false `isRefinable` butcher mats like Special Squig Bits) fast-fail in ~1.5s, clear pending/outstanding, and blacklist the uid so AutoGrow does not stall; real seed→plant Extender/Multiplier/Stimulant converts still work.

**0.4.136:** Fix — when the craft bag is full, harvest/refine learning and brew load also see CRAFTING mats in inventory (overflow); Have counts already included both bags.

**0.4.135:** Perf — settings soft/light paths: Reserve/Budget chips no longer BumpWatch/PlanRebuild; Additives/AutoBuy toggles skip plan invalidate; Seed buffer + AutoGrow use Bump + prewarm + coalesced PlanRebuild (MarkWatchUiDirty, no sync Refresh). `Grow.OnDemandChanged` keeps Have caches (`keepPlanCache`) so settings clicks do not cold-WarmHave.

**0.4.134:** Fix — after AutoBuy fills flasks/mats, Status stayed `Buy flasks` (Brew/macro grey) until `/sp2 watchplan`. Tip Have overlays were live, but plan `statusKey` was never rebuilt (per-purchase plan invalidate intentionally removed). Now arm one coalesced PlanRebuild + prewarm when buy jobs go idle after buys, or on visit stop with buys.

**0.4.133:** Perf — target chip (+/-) when bag stock already covers both old and new target no longer BumpGen / Invalidate / OnDemandChanged / PlanRebuild (was ~400–750ms for stocked→stocked tweaks like 40→41 with have 50). Optimistic row paint + in-place PlanSnapshot target patch only; crossing stock / zero-target still full rebuild.

**0.4.132:** Perf — make FrameWork prewarm win before PlanRebuild and post-brew Orch.Tick: skip Pump/BufferFlags during brew session; re-arm prewarm on snapGen drift while plan pending + arm on brew-clear; hold PlanRebuild/Orch.Tick until have/demand caches match current snap (capped); one StartOnce job per Pump frame; skip Planner WarmHave when already warm; hold Footer on PlanRebuild didHeavy; one GetPlantJob per Orch.Tick.

**0.4.131:** Fix — footer/macro Brew stayed grey after one successful auto brew while apo session stayed loaded (row Brew still lit). Cause: brew learn invalidated the plan, PlanRebuild stayed deferred for brew-session (0.4.126), and `CanBrewNow` required a live `ready_to_craft` plan row. Now loaded auto sessions also enable from session deficit/craftable + board validate (same idea as `HasReadyToCraft`); `/sp2 watchplan` no longer needed to wake footer.

**0.4.130:** Perf — frame-slice pattern in-addon (`Source/Core/FrameWork.lua`): fuse Footer after LearnBridge/Scheduler + SkipUi holds Footer; Reconcile frames SkipUi; storm-end/bag-flush prewarm WarmHave/Demand/seed-lines across frames (no sync BuildBalancedSpecDemand on storm expiry); PlanRebuild waits while warm-have prewarm active. PATTERN comments for reuse by other addons.

**0.4.129:** Chat — harvest / brew success / AutoBuy gain lines use clickable item LINKs (`ITEM:uid`); plant and load messages stay plain text.

**0.4.128:** AutoBuy — chat `AutoBuy: Nx Name (spent Xg)` per material type when that type's need is filled (not one summary on vendor close); flush leftovers on stop/close.

**0.4.127:** Chat — "All watches ready to craft" + brew chime only when every watch is green and at least one is Ready to brew (not when all are Potions stocked after /reloadui).

**0.4.126:** Perf — mid-brew: defer PlanRebuild while apo session loading/loaded (not bag flush); keep plan snapshot across crafts; one rebuild on session clear; hold Watch paint except Load/Brew chrome; SkipPlan/SkipUi on craft frame; Orch.Tick skips AutoGrow probes during brew (still AutoBuy).

**0.4.125:** Perf — post-replant: defer PlanRebuild while refine outstanding/pending (one rebuild when clear); SkipPlan/SkipUi on refine delivery frame; fill-wave keeps plan cache; BufferFlags reuse mid-refine when garden full; IntentCacheKey drops snapGen.

**0.4.124:** AutoGrow — print plant chat on accepted PlantSeed (once via meta.chatted); soil confirm only clears pending. FlushPendingSyncAll also runs Grow confirm. Fixes last-plot chat when soil lag / fill-wave wipe skipped notify.

**0.4.123:** AutoGrow — last-plot replant chat: do not `OnFillWaveComplete` (force-clear pending meta) while a plant is still awaiting soil confirm; confirm from SyncPlot cache and complete the wave only after pending clears.

**0.4.122:** Perf — vault/bank↔bag moves: snap-only Watch paint no longer nudges PlanRebuild; INVENTORY_SNAPSHOT MarkPlantJobDirty only when AutoGrow has empty plot / additive / buffer work; pending-harvest Snapshot clears lootDirty on no non-seed gain (stops stuck ~1s Harvest.Snapshot loops).

**0.4.121:** Watch — after R-click unload, block board re-adopt / BrewUi for 1.5s so deferred ClearSlots craft updates cannot flip Load→Brew→Load. Intentional Load clears the block.

**0.4.120:** Watch — suppress brew UI refresh/adopt while clearing a loaded session so ClearSlots craft updates cannot briefly re-show Brew/Idle before Load.

**0.4.119:** Watch — Load/Brew row labels track apo session again (WatchContentKey + flush interval ignored brew phase, so first Load left the chip on Load until a later bag/plan paint).

**0.4.118:** Perf — Watch-open plan coalesce uses `PLAN_MIN_GAP` (nudge no longer bypasses the 2s gap; open wait was 0.5s). Storm end prewarms `BuildBalancedSpecDemand` on the plan-skipped frame so first replant can cache-hit. Plant job stashes seed slot by snapGen+seedUid for same-tick reuse. ~140ms Tick/(none) floor remains client noise.

**0.4.117:** Perf — after harvest Complete, skip Watch paint one frame (`SkipUiThisFrame`) so Complete does not fuse with UiFlush/WatchRows/Footer; Orch storm/quiet returns before `HasAutoGrowWork` (no BufferFlags probe on held ticks). LibPerf note: trails stick ~0.1s across frames — success is Complete spikes without UiFlush/WatchRows, not “trail never lists Complete and PlanRebuild together.”

**0.4.116:** AutoGrow — defer plant/additives in scenario/combat/RvR (same gate as bag flush); plant chat only after soil confirms; 6s per-plot cooldown when pending expires still empty (stops unconfirmed replant spam).

**0.4.115:** Persistence — strip historical settings-flag leaks from Account on load; drop obsolete `perfEnabled`/`perfThresholdMs` from Settings (LibPerf owns hitch config); `/sp2 audit` reports unexpected Account top-level keys. Architecture review doc: `docs/ARCHITECTURE_REVIEW_0.4.114.md`.

**0.4.114:** AutoGrow — plant-hold for ready harvest only when the garden is a uniform ready/mid-batch wave (Grown + empty, no mid-grow). Staggered timers still allow planting empties.

**0.4.113:** AutoGrow — do not plant into empty plots while any plot is still Grown/ready to harvest (avoids mid-batch harvest lockout). Refine/additives still run; replant resumes when the ready batch is cleared.

**0.4.112:** Watch tip — Have/Need red vs yellow follows AutoGrow-progressable (growable), not planner `kind=buy` when seed credit is 0; Buy seeds/plants notes stay yellow to match `need_seeds`; true buy (flasks/butchered) stay red with Buy* notes; AutoGrow off / Needs cult stay red.

**0.4.111:** Chat — replace Unicode em dashes in locale with ASCII ` - ` (mojibake-safe).

**0.4.110:** Chat — `Harvest:` / `Brew:` prefixes with capitalized action; plot lines as `Harvest: Plot N harvested/planted…`.

**0.4.109:** Chat — normalize plot/brew user messages (`Plot N: Harvested/Planted…`, `Harvest: ready…`, `Brew: ready/load/Brewed…`).

**0.4.108:** Harvest — outcome chat / primary plant pick skip non-growables (via `IsEligibleHarvestProductUid`), not resin-only.

**0.4.107:** Harvest — outcome chat ignores Arboreal Resin (refine/convert loot); report the main plant only.

**0.4.106:** Harvest — button/macro enable only when all planted plots are ready (empty ignored); keep mid-batch lit without re-chime; per-plot chat for main harvest / crit-fail. Brew — ready chime/chat only on real edge into Ready (not between crafts); chat `Brew load: {name}` when the loaded recipe/watch key changes; keep per-brew outcome lines.

**0.4.105:** Brew — do not clear apo load when FindSessionRow is nil right after plan invalidate (0.4.104 false-cleared every brew); clear on plan-updated only when row is missing/not Ready or board invalid, or when session counters are exhausted.

**0.4.104:** Brew — clear stuck auto apo load when the watch is no longer green Ready (session craftable alone used to keep phase=loaded while the footer greys and AutoGrow is blocked); re-check on plan rebuild after brew.

**0.4.103:** Brew — when a session cannot continue (materials / craftable exhausted) but phase stayed `loaded`, clear the apo load like footer R-click so AutoGrow is not blocked. Potent/byproduct outcomes still continue the session when mats remain; every brew still counts as target progress (crit rates not modeled).

**0.4.102:** Brew — incorrect interim: aborted session on non-watched (Potent) output. Replaced by 0.4.103.

**0.4.101:** Perf — skip snapGen/INVENTORY_SNAPSHOT on no-op L0 bag rearranges; no BrewUi on idle craft-bag slot events; post-storm SkipPlanThisFrame + defer BrewUi one frame so WarmHave/WatchRows do not stack with first AutoGrow replant Tick (harvest hitch unchanged).

**0.4.100:** Watch — red Buy flasks/materials for Shared contest only when every contested key is non-growable; if plants/buffer are still contested, stay yellow Shared materials.

**0.4.99:** Watch — contested shared containers show red Buy flasks (not yellow Shared materials); tip Have/Need for those flasks paints red.

**0.4.98:** Watch — stocked AutoGrow watches show yellow Seed buffer when recipe seed lines are below buffer (was green Potions stocked while Brew still held); Ready to craft label → Ready to brew.

**0.4.97:** AutoGrow — defer `seed_buffer`/`surplus` plant when potion_stock is seed-starved but refinable plants remain, so Orch refines first and can close Shared/yellow watches without waiting a full buffer grow cycle.

**0.4.96:** Perf — split Harvest.Complete from PlanRebuild (SkipPlanThisFrame); keep lootDirty on failed complete; align plant quiet to storm + Orch storm early-return; seed-line cache drops snapGen; skip MarkPlantJobDirty mid-storm; IntentCacheKey uses planGen; why-comments on new + existing harvest/plan/Tick guards.

**0.4.95:** Perf — cut harvest/replant hitch: WakeAfterHarvest no sync Pick; defer harvest learn ≥1 frame; harvest-storm defers bag/plan + BrewUi; plan deadline stretches (nudge + 6s cap); Orch skips plant during quiet (no fill-block); Watch UiFlush held through storm/quiet/didHeavy.

**0.4.94:** Perf — seed-line/buffer/plant-job caches key on garden planGen (not stage ticks); BrewUi dirty-only + frame-coalesced brew-ready notify; plan coalesce keeps 3s while AutoGrow awake even with window open + PLAN_MIN_GAP_SEC; CollectAutoGrowFocus cached; refine gate Peek-only; suppress window defers snap bumps; footer early-out.

**0.4.93:** Perf — plantUid Have uses Cached/Items (no nested bag ProductMatches); FindPlantUidForSpec tries learned data before bags; ClearPlanCaches before WarmHave; idle AutoGrow backs off when empty plots have no plant job; nested LibPerf trails for demand/pick.

**0.4.92:** Fix — suppress false "Need Apo/Cult" chat at login until trade skills are populated (`TRADE_SKILL_UPDATED`); then rebuild plan.

**0.4.91:** Fix — Main Have still 0 for Heaving Spumepetal (20 in bag): parse `CraftItemInfo` map, prefer Items stamp for thin bag mains, and fall back Have/refinable to `CountByUid(plantUid)`.

**0.4.90:** Fix — cultivated Main plants that omit EFFECT (e.g. Heaving Spumepetal) now match recipe Have/Craftable via description or skill/stab/power (was stuck at Have 0).

**0.4.89:** Watch — overlay live bag Stock/Craftable on coalesced plan rows; status tip Have + plot notes refresh from bags/garden; 1s UI flush while plan pending; faster plan rebuild while window open.

**0.4.88:** Watch — bypass 5s UI flush on planGen; skip stale snap paints that burned the interval; tip caches keyed with planGen (Status/Stock/Craftable catch up with plan rebuild).

**0.4.87:** Fix — clear orphan refine `_pendingByPlant` when outstanding is already 0 (and sync pending on seed delivery) so AutoGrow cannot stall empty plots behind `pending-throttle`.

**0.4.86:** Fix — MaterialSpec parse cache keyed by uid (not item table identity) and cleared on inventory snap; stops unbounded `_specParseCache` growth. Add `/sp2 mem` for safe footprint counts (never `d(StockPiler2)`).

**0.4.85:** Perf — remove `/sp2 perf*`; all hitch settings via `/libperf` (LibPerf 1.2 persists enable/threshold). Help points at `/libperf StockPiler2`.

**0.4.84:** Perf — optional LibPerf dependency; hitch trails go to `logs/libperf_StockPiler2.log` (no built-in frame pump). `/sp2 perf` no-ops with a message if LibPerf is missing.

**0.4.83:** Localization Phase 2 — Window/Potions/Watch chrome, recipe and Watch tips, Planner Status column, Harvest/Brew tooltips, and MaterialSpec tip meta via `StockPiler2.T` (enUS only).

**0.4.82:** Localization — Locale scaffold + enUS catalog; user chat (`Notify`/`Print`/`/sp2 help`, macros, perf summary) via `StockPiler2.T`; mojibake-safe ASCII chat punctuation.

**0.4.81:** Brew — RecipeIsStable requires stability total > 0 (match engine HIGH); Effective*PerCraft also tops up at total == 0; LogCauldronStability logs OmeterValue beside SuccessChance.

**0.4.80:** Watch — Craftable green only when safe to brew (uncontested vs other watches and seed-buffer plant headroom); footer/macro Brew continue requires green Ready; tooltips updated.

**0.4.79:** Potions — paint on learn without waiting on Watch 5s flush (knowledgeGen bypasses interval); Relink potion recipeKeys after each StoreLearnedRecipeSpec so alternate/potent fingerprints appear without `/reload`.

**0.4.78:** Brew — harden Watch-row Load→Brew (no op-lock swallow, paint while loading, Notify on rejects); manual row Load skips AutoGrow holds; footer Brew + macro Ready-only (ignore manual load sessions).

**0.4.77:** UI — Watch Target chips and Potions Watch toggle update instantly (optimistic row paint); Forget / Watch catch-up via coalesced plan + dirty flush (no sync cross-tab RefreshWatch); WatchContentKey includes watchGen.

**0.4.76:** Fix — `GrowsBucketStats` local-order crash in `CultSkillUpRate` (OnUpdateProcessed).

**0.4.75:** Potions — live list refresh when a new recipe fingerprint is learned (UI content key includes knowledgeGen); rarity-colored names; sortable Lvl column (fits by shrinking Name, window width unchanged).

**0.4.74:** Brew — cauldron stability diagnostics (`sp2Total` / `sp2Stable` vs engine `SuccessChance`) on pending, fail, and VALID_RECIPE (for calibrating RecipeIsStable vs mixed-tier loads).

**0.4.73:** Refine resin-need — only convert plants whose skill level matches the needed Arboreal Resin (1:1 same-tier seed+resin); drop orphan/wrong-tier burns (e.g. Special Moment plants).

**0.4.72:** Tooltip craft-cycle rates — Status tip harvest rates under plant slots; Harvest/Brew footer tips show survive/yield/SM and brew success/yield; empirical Cult/Apo skill-up % when skill below 200 (n≥5) via TRADE_SKILL_UPDATED attribution.

**0.4.71:** Craft-cycle stats — Special Moment chat cue; plantAttempts / specialMomentHits / refineAttempts+seedOut; harvest survive/SM/yield helpers + `SeedsNeededForPlants`; `/sp2 stats` dump; Watch Status harvest rate line.

**0.4.70:** AutoGrow — shorter post-harvest replant quiet (1.2s→0.75s) and harvest op-lock (1.5s→1.0s); multi-plot force debounce unchanged.

**0.4.69:** Fix — Brew/Harvest ready chat+sound sync with button/macro lighting (macros update even when SP2 window closed; harvest notify also requires CanHarvestNow).

**0.4.68:** Refine — `resin-need` converts surplus recipe plants (highest stock) for Arboreal Resin when stabilizer is short; ignores seed-buffer headroom; Watch shows Refine for resin / red only with no feedstock.

**0.4.67:** SeedMap — plot-watched harvest trusts bag-delta plants without name match (vendor Seed Packet → Musty/Swaying + Special Moment); packets excluded from PickBestSeedUid / refine `seedUid`; ForgetUnrelated keeps packet→plant grows.

**0.4.66:** AutoGrow — respect Cultivation plot unlocks (1/2/3/4 at skill 1/50/100/150); skip `Locked` plots from `GetCultivationInfo` so low-skill chars no longer spam plant on P2–P4 (`Illegal Plot Number`).
**0.4.65:** Watch — red `need_skill` when recipe material skillLevels exceed character Cultivation/Apothecary (e.g. lv200 Draught on skill 1 no longer looks like a buy shortage).

**0.4.64:** Fix — Watch/Potions ListBox: hide unused `visiblerows` slots (empty Watch was 11 opaque white bars with ghost AutoGrow checkboxes; tint only covered PopulatorIndices).

**0.4.63:** Fix — Watch list white bars: always re-apply SetListRowTint; set paintKey only after a full paint; clear paint cache on window show (ListBox recreate was skipping tint).

**0.4.62:** Fix — Brew ready chat/sound and footer Brew tooltip follow `CanBrewNow` (no “Click to load” / chime while button is grey from op-lock or crafting-in-progress).

**0.4.61:** Fix — Brew ready / all-watches-ready / AutoGrow-idle chat wait until Seed Buffer is satisfied; hold brew load while buffer is still short or refining (avoids false ready after buffer eats brew mats).

**0.4.60:** Ops chat — AutoBuy visit summary (what was bought + reserve/budget/cap stop); NotifyOnce when all watches are true green (ready to craft / stocked); NotifyOnce when AutoGrow is action-idle but watches still need player actions (buy flasks / skill gates).

**0.4.59:** Perf — craft/cultivation footer once per frame; CanBrewNow frame memo; harvest readiness from Garden store; Watch list single paint + row paint-key skip; idle Refine negative-intent cache; GetOrBuild(refresh=false) never sync-builds; Garden.SyncAll coalesced once/frame; SnapshotPotionCounts from L0 counts; Buy per-visit store index; drop bag-due trail hold / dead section timing; Marks for ApplySlots/Footer/WatchRows/BrewUi/ApoCapture.

**0.4.58:** Fix — AutoGrow keeps ticking in combat/RvR (combat only defers bag Flatten, not Orch/plan); Watch list keeps last good rows when plan is nil/pending; open-window Watch UI catch-up no longer skipped for fill-burst.

**0.4.57:** Fix — plant-need refine respects seed-buffer credit (live+ground+outstanding); dedupe vs buffer intents; emergency single refine only when an empty plot’s cached plant seed matches and headroom is 0.

**0.4.56:** Perf — idle Orch/Refine: edge-only seed-buffer MarkRefineDue + honor wait ticks; skip Orch while fill-blocked waiting; Macro.Appearance: bind-cache only on slot move, slot-list cache, side-only apply, no re-CanBrewNow in UpdateEnabledState during refresh; BrewLearn L0 potion deltas skip full bag snapshot after craft; skip Orch same frame after learn drain.

**0.4.55:** Fix — AutoBuy continues across focus watches in one vendor visit (no reopen after first watch); clear visit-acquired on inventory snap so shared mats are not starved; budget remains per-visit allowance; reserve/budget/cap stops unchanged.

**0.4.54:** Fix — brew no longer sticks after a main-kept craft: plan rebuild is deferred only while loading/busy (not idle `loaded`); `CanBrewNow`/`TryBrewClick` continue from session deficit+craftable+validate without a plan row; skip false after-brew idle-close when still craftable.

**0.4.53:** Fix — refine extras gated to resin-only; `IsResinUid` no longer treats arbitrary byproduct keys as resin; reject resin grow-seed buckets; forget unrelated grow rows even with samples; `tooth` butcher hint. Offline SV cleanup of remaining polluted grows/refines.

**0.4.52:** Fix — stop recording butcher/container/wrong-plant bag noise as Goldweed harvest products; Chitin/butcher apo mains AutoBuy-able (`chitin` hint + cultivation-linked SpecLinked). Offline SV cleanup of polluted grows/refines.

**0.4.51:** Fix — butchering mats (Armor Scales, Zoic Gore, …) no longer false-growable via ProductMatches overlap with cult plants; AutoBuy can purchase them when budget/reserve allows.

**0.4.50:** Perf — brew hitch coalesce: stop trail-hold for brew session; snapGen-cache + dedupe `SnapshotPotionCounts` / BeginPendingCraft; inventory craft poll once per frame; brew in Watch UI fill-burst; EnqueuePlanRebuild after learn/after-brew (no force BuildPlan on idle close); skip macro appearance drift sync while brew busy/loading.

**0.4.49:** Fix — move `FindSessionRow` above `CanBrewNow` (RoR local-order; was nil global on UPDATE_PROCESSED).

**0.4.48:** Perf — nested `Build.WarmHave` / `Build.Demand` / `Build.Status` / `Build.Tips` under Planner.Build; plan-cache `IsHarvestByproduct`; one `RecipeSlotPlanEntry` pass per deficit row (tips reuse + GrowingNotes once); memo `CountCraftsPossible` per recipe within a Build.

**0.4.47:** Perf — trust DataUtils for L0 bag sync (no hot-path FetchForce / per-slot FetchLight; one bag table per slot event); demote refine-expire from full Flatten; one-pass `WarmSpecHaveCache` for Planner.Build / demand (CountByUid for incomplete+boundUid; one ForEachItem for fuzzy specs; stop double `_specHaveCache` wipe).

**0.4.46:** Perf — coalesce L0 inventory snapGen to once per UPDATE_PROCESSED; stop EnqueuePlanRebuild on every SNAPSHOT (SP1 snap-only vs needQueue); defer PlanRebuild during harvest/scenario; skip ClearCountCaches on harvest keepPlanCache; frame-gate ReconcileAll; share demand/seed-lines per orch tick; rate-limit defer bag-flush logs.

**0.4.45:** Fair AutoBuy — buy mats for max bottle-gap watches first (Target-Stock-Craftable); fall back to all short watches when focus has no vendor buy deficits. Sort: container then deficit (drop alphabetical primacy).

**0.4.44:** Fair AutoGrow plant pick — focus watches with max bottle gap (Target-Stock-Craftable); plant unique bottlenecks for those recipes first (fallback to pooled craftsShort if focus has nothing plantable). Fixes Rejuvenating-style starvation by shared Goldweed/Gobswort.

**0.4.43:** Perf — harvest hitch: CraftChat soft-wake only (LearnBridge owns force); keep PlanSnapshot on harvest wake + enqueue coalesced rebuild; CanBrewNow no longer triggers MaybeNotify/GetOrBuild mid-cultivation; GetOrBuild never sync-builds while plan pending; ReconcileAll once per snapGen (drop Orch duplicates; defer intent-cache bust).

**0.4.42:** Fix — Brew/Harvest hotbar grey sticks: hook ActionButton.UpdateEnabledState so engine DO_MACRO re-enable cannot overwrite SP2 readiness; force grey tint when macros ship colorful *_disabled textures.

**0.4.41:** Fix — Brew hotbar macro clears PERFORM_CRAFTING bind when not ready (was always bound, so bar stayed lit while footer correctly disabled); footer resyncs macro if appearance key drifts.

**0.4.40:** Perf — plan builds tip-ready statusTipSlots with demand; keep _specHaveCache warm; cache ExpectedCraftableBottles + ResolveSeedForSpec; Brew live tip fingerprints snapGen (not per-tick bag digests); cache Seed Buffer tip rows.

**0.4.39:** Perf — cache Watch status tooltip rows per plan gen (first hover builds; re-hovers reuse until bags/garden/watch gens change).

**0.4.38:** Fix — Stock/Craftable tooltip mojibake (ASCII `-` instead of Unicode em dash in L-strings).

**0.4.37:** Clarify Watch traffic-light copy — Stock/Craftable tooltips match column colors; mat note (Pooled) = grow demand across watches, (Shared) = brew-claim contest; Craftable green = uncontested bottle count.

**0.4.36:** Fix — restocking tooltip marks recipe-covered mats yellow when pooled grow demand across watches still exceeds bag stock (now labeled Pooled in 0.4.37).

**0.4.35:** Fix — Watch restocking tooltip plot notes use exact seed UIDs only (no PairLooksLike / bag-seed pollution); Extender plots no longer show under Multiplier (e.g. Rejuvenating Draught).

**0.4.34:** Fix — footer Harvest tooltip works again (stop gating HandleInput; bind/clear only on ready transitions; force HandleInput on to recover from 0.4.32).

**0.4.33:** Fix — footer Brew enable matches click usefulness (grey while busy/op-lock; loaded session only lit for green Ready craft or another Ready pick); refresh footer when brew op-lock expires.

**0.4.32:** Fix — footer Harvest chrome no longer strips on rapid click (bind once on Watch; gate via HandleInput/Disabled instead of clear/rebind; skip L-up footer refresh + macro sync when readiness unchanged).

**0.4.31:** Fix — after relog with window already open on Watch, force bag flush + plan rebuild + active-tab refresh on SESSION_LOADED (stock/craftable/status no longer stale until tab flip).

**0.4.30:** Perf — rate-limit `trail=(none)` spike uilog (digest + summary still count; avoids flood at low thresholds). Fix — AutoBuy no longer `visit-resume` every store update after reserved/budget (resume on close→open or ClearMoneyGateStop). Fix — Watch skill-gate checkboxes refresh on SESSION_LOADED / window show (no longer stuck grey after relog until tab flip).

**0.4.29:** Fix — seed-buffer budget prefers Inventory L0 seed counts (stop ForSpec under-count + lastLive stomp); no pending-throttle clear/burst retry; IssueOne clamps uses to fresh uid headroom.

**0.4.28:** Perf — defer Watch UI rebuild during refine / outstanding / buffer-refine; list repopulate goes through coalesced flush; trail hold no longer includes planDue.

**0.4.27:** Perf — harvest trail honesty (LearnBridge Begin only on complete attempts; no IsHarvestOpActive trail hold); craft-bag-only harvest snapshot; nested Harvest.Snapshot / Harvest.Complete sections.

**0.4.26:** Watch status tooltip — contested recipe slots show (Shared) instead of (Stocked) under Shared materials.

**0.4.25:** Perf — ReconcileAll early-outs and only walks outstanding seeds; defer bag Flatten/plan rebuild while `isInScenario`. Fix — clear refine `_pendingByPlant` on stuck outstanding expire; do not fill-block when intents only fail throttle; Watch status uses Refine/Seed buffer (not Buy seeds) when refinable plants remain.

**0.4.24:** Macro — PLAYER_HOT_BAR_UPDATED only forces appearance re-apply when harvest/brew slot fingerprint changes (stops Macro.Appearance trail storms from unrelated hotbar noise).

**0.4.23:** Perf — Macro ignore hotbar echoes during appearance refresh; harvest mat snapshot prefers Inventory L0; LearnBridge perf excludes Refine; AutoBuy skips per-purchase Flatten/plan/jobs invalidate; Watch UI defers during AutoBuy visit.

**0.4.22:** Macro — coalesce hotbar enable sync; short-circuit appearance before Perf.Begin; stop dirty-reentry key wipe (cuts Macro.Appearance trail spam).

**0.4.21:** Perf — breadcrumbs for Garden sync, harvest prepare/wake, Brew tick/load, Buy, Macro appearance; hold trail during harvest/brew; persist `/sp2 perf on [ms]` threshold.

**0.4.20:** Harvest ready chat/sound — only when every planted plot is grown (empty plots ignored).

**0.4.19:** Harvest ready sound — `HELP_TIPS_NEW` (was `PREGAME_DONE_BUTTON`).

**0.4.18:** Sounds — harvest ready (`PREGAME_DONE_BUTTON`) and brew ready (`HELP_TIPS_HIGHTLIGHT_WINDOW`) play with their one-shot chat lines.

**0.4.17:** Chat — plant ops (+ reason), harvest/brew ready (once), brew success/fail, TabWatch settings changes, one-shot red watch status.

**0.4.16:** Watch Restocking tip — byproduct stabilizers red (not yellow) when no plant feedstock; skip "Restocking materials" status with empty seed lines.

**0.4.15:** Harvest/Brew — trade-skill gate enablement (Cultivation / Apothecary); footer and macro tooltips explain when gated.

**0.4.14:** Seed Buffer tooltip — recipe/restocking layout (dashed separators, green material headers, yellow detail, traffic-light SHORT/partial/OK).

**0.4.13:** Macros — mushroom / madened-speed elixir icons; disable hotbar macros with footer rules (disabled DDS); drop checkbox overlays.

**0.4.12:** ActionBar macros — `StockPiler2 Harvest` / `StockPiler2 Brew` (WarTriage rebind; footer-equivalent activate + tooltips; ignores SP1 macros).

**0.4.11:** Perf — post-harvest plant quiet (~1.2s); debounce force plant-queue invalidates across P1–P4 wake wave.

**0.4.10–0.4.9:** Harvest/fill perf — Watch flush skip, FindSeedSlot cache, softer GARDEN_DIRTY, seed-line caches, deferred Planner while coalesce pending.

**0.4.8:** AutoBuy — store-close detection for reserved/budget stops; visit resume on reopen.

**0.4.7:** Seed buffer — bag + in-ground credit; SHORT surplus block; batched buffer refine when plots full.

**0.4.6–0.4.4:** LearnBridge/harvest perf; AutoGrow commit release; uid-first seed↔plant; freeze fix (snap wake storm).

**0.4.3–0.4.0:** Liniment/one-way AutoGrow; skill-aware Grow/Brew/Buy; traffic-light status polish.

**0.3.0:** Watch dashboard polish — footer vs row Brew split, shared craftable contention, `/sp2 watchplan`.

## Lua pitfalls (addon authors)

RoR’s embedded Lua does **not** hoist `local function` declarations (Lua 5.0–style). If function **A** calls local helper **B**, **B must appear above A** in the file — otherwise: `attempt to call global 'B' (a nil value)`.

**Primary reference:** RoR-Interface `docs/api/lua-local-order.md` (listed in `docs/INDEX.md`).

SP2-specific helper order: `Source/Knowledge/RecipeSpec.lua` (see comment at local helper block).
