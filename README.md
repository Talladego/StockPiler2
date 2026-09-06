# StockPiler2

Greenfield rewrite of StockPiler using an **Orchestrator + Stores + Planner + Executors** architecture. Runs as a **separate addon** alongside v1 — does not modify the original StockPiler folder.

**Version:** 0.4.58

Repository: [Talladego/StockPiler2](https://github.com/Talladego/StockPiler2)

## Install

1. Ensure the `StockPiler2` folder is under `Interface/AddOns/`.
2. Enable **StockPiler2** in the addon list (v1 can stay enabled for parallel testing).
3. `/reloadui`

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
| `/sp2 brewplan` | Brew session + ready watches dump |
| `/sp2 buyplan` | Buy job dump |
| `/sp2 bags` / `bags force` | Bag snapshot dump |
| `/sp2 events` / `on` / `off` / `dump` | Internal event bus trace |
| `/sp2 perf` / `on` / `off` / `summary` | Frametime hitch logger (trail breadcrumbs in uilog) |
| `/sp2 perf on [ms]` / `baseline [ms]` | Hitch threshold (persisted) / baseline |
| `/sp2 audit` | Saved variables health |
| `/sp2 harvest` | Prepare next ready plot (macro/CMD path) |

Perf tip: spikes with `trail=(none)` / high `emptyTrail%` on baseline are usually **engine** stalls (native craft/UI, DXVK, other addons, zone load)—not missing Lua sites. Empty trail means SP2 did not `Begin` recently; leave those alone. Empty-trail spike **uilog lines are rate-limited** (summary still counts every hitch). Threshold from `/sp2 perf on [ms]` is saved in settings.

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

- Footer Brew only loads/performs watches that are **Ready to craft** (deficit > 0, uncontested craftable).
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
