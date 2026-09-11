# StockPiler2 architecture & quality review (0.4.114 / ship 0.4.115)

**Date:** 2026-09-09  
**Scope:** First-pass structure review vs Orchestrator + Stores + Planner + Executors; oversized modules; saved-data integrity; checklist; SP3 blueprint lag.  
**Non-goals:** SP3 rewrite, mass file splits in this pass, Account wipe.

---

## Verdict

**Still on the original pattern at folder / Orchestrator / Executor-shape level.** Soft and hard drift has accumulated inside Knowledge (shadow Planner), Grow/Brew (View chrome), and TabWatch (on-hover recompute). Live saved data is **structurally clean**; historical Account←Settings pollution is guarded on load in **0.4.115**.

---

## 1. Layer scorecard

| Layer | Score | Evidence |
| :--- | :--- | :--- |
| **Adapters** | Soft drift | `CraftChatAdapter.OnChatTextArrived` wakes AutoGrow / `ClearFillBlocked`; `VendorAdapter.NotifyStoreUpdated` → Buy + `WakeAutoBuy`; `ApothecaryAdapter` session mutates Brew ownership flags. Bag / TradeSkillCaps mostly thin. |
| **Stores** | Soft drift | `InventoryStore.CanUseCraftingItem` / tooltips / BrewLearn+Additives hooks leak policy+UI; Garden/Watch/PlanSnapshot/Knowledge/RefinePipeline mostly gen/dirty. |
| **Planner** | Soft drift | No craft/window mutates; `BuildWatchRows` Notify* + sounds; `Build` → footer refresh / brew ready; tip paths query Grow/Refine. Demand/have math largely lives in RecipeSpec (see hotspots). |
| **Domain UI chrome** | Hard drift | Grow footer bind/tips (~54–125, ~1604–1699, ~2934–3351); Brew tips/states (~1751, ~2576–2880). Refine/Buy little chrome. |
| **Executors** | Compliant | Thin `*.Tick` → domain. Soft: Orch additive path sometimes calls `Grow.TryApplyNextAdditive` directly. |
| **View** | Soft drift | List uses `Planner.GetOrBuild(refresh=false)`; storm/quiet holds paint; status/seed-buffer tips re-run demand/Refine; no plant/refine from paint. |
| **Scheduler / Orch** | Compliant | Tick order plant → additives → refine → buy; fillBlocked allows buffer refine + AutoBuy; quiet/storm early-return; plan coalesce. fillBlocked state lives in Grow. |

---

## 2. Hotspot section maps (coupling)

### `Knowledge/SeedMap.lua` (~4.9k)

| Approx lines | Responsibility |
| ---: | :--- |
| 1–520 | Module, classify, harvest-pair gates |
| 523–1047 | Mapping API / item upsert |
| 1048–2251 | Observe rates + byproduct convert-grow pick |
| 2252–3234 | Pending refine/harvest FSM |
| 3236–4460 | Resolve seed/plant, bag index, growability |
| 4462–end | Dump / prune / bootstrap |

**Smells:** Knowledge → `Grow.NotifyHarvestOutcome`; direct `DataUtils` bag fallback (bypass BagAdapter); convert-grow pick is Planner-ish.

**Split targets:** `SeedMapCore`, `SeedMapObserve`, `SeedMapResolve`, `SeedMapByproduct` (or move convert pick → Planner), `SeedMapMaintenance`.

### `Knowledge/RecipeSpec.lua` (~4.3k)

| Approx lines | Responsibility |
| ---: | :--- |
| 1–920 | Fingerprints, labels, slim storage |
| 921–1768 | Learn / forget / watch scrub |
| 2059–3396 | Have/crafts memo, contested/buffer, focus collectors |
| 3400–3761 | **`BuildBalancedSpecDemand`** |
| 3763–end | Effect-key / relink repair |

**Smells:** Critical — RecipeSpec is a **shadow Planner**. Circular Knowledge↔Planner; Refine pulled into buffer contests; learn-on-read side effects.

**Split targets:** `RecipeSpecStore`, `RecipeLearn`, `Planner/SpecHaveCache`, `Planner/SpecDemand`, `RecipeEffectKeys`, optional `WatchScrub`.

### `Grow/Grow.lua` (~3.4k)

| Approx lines | Responsibility |
| ---: | :--- |
| 1–200 | Harvest chrome helpers |
| 435–1405 | Plant job / fillBlocked / pending |
| 1406–2000 | Harvest ready + bind/fire/wake |
| 2005–2390 | TryPlant / additives |
| 2736–end | Harvest tooltip View |

**Smells:** Domain owns View chrome; Executors stay stubs; mutates `GameData.Player.Cultivation.CurrentPlot`.

**Split targets:** `PlantJob`, `PlantCommit`, `HarvestReady`, expand `GrowExecutor`, `View/HarvestChrome`, `View/HarvestTooltip`.

### `Brew/Brew.lua` (~3.1k)

| Approx lines | Responsibility |
| ---: | :--- |
| 1–904 | Session, ready pick, bag match, board |
| 905–2162 | Load FSM + row/footer UX |
| 2163–2885 | Brew tooltips View |
| 2887–end | Dump |

**Smells:** Domain owns View; `Planner.GetOrBuild` from brew path; writes `Orch._brewPhase`.

**Split targets:** `Session`, `ReadyPick`, `LoadBoard`, `LoadFsm`, expand `BrewExecutor`, `View/BrewTooltip`, `View/BrewChrome`.

### `View/StockPiler2TabWatch.lua` (~2.3k)

| Approx lines | Responsibility |
| ---: | :--- |
| 1–580 | Colors, list, paint |
| 582–950 | Settings handlers |
| 952–1990 | Seed-buffer + **status tip rebuild** |
| 1992–end | Stock tips / row Load |

**Smells:** Status tip calls `BuildBalancedSpecDemand` / slot tooltip builders on hover; CollectIntents in tips.

**Split targets:** `TabWatchList`, `TabWatchSettings`, `TabWatchStatusTip`, `TabWatchStockTips`, `TabWatchBrewRow`. Long-term: tips consume plan snapshot fields only.

---

## 3. Prioritized split backlog

Order restores the architecture pattern (not LOC vanity):

| Pri | Cut | Why |
| ---: | :--- | :--- |
| 1 | Move `BuildBalancedSpecDemand` / WarmHave / focus collectors from RecipeSpec → `Planner/` | Restores Planner purity; shrinks Knowledge megamodule |
| 2 | Extract Grow/Brew harvest+brew tooltips + footer chrome → `View/` | Ends Hard drift Domain↔View |
| 3 | TabWatch status tips: snapshot-only (no demand rebuild on hover) | Perf + View purity |
| 4 | Expand Executors with engine writes (`CurrentPlot`, plant/load issue) | Makes Executor boundary real |
| 5 | SeedMap observe/resolve/maintenance splits | Maintainability; hitch surface |
| 6 | Second wave: Refine, Buy, Macro, TabPotions, Scheduler size | After 1–4 |

---

## 4. Saved data integrity

### Live files inspected

- `user/settings/GLOBAL/StockPiler2/SavedVariables.lua` (Account, ~143 KB)
- `user/settings/Martyrs Square/.../StockPiler2/SavedVariables.lua` (Settings, ~156 KB)
- Historical: `SavedVariables.lua.bak_cleanup`, `SavedVariables.lua.bak-packet-20260907`
- Offline helper: `scripts/audit_savedvars.py`

### Verdict: **clean** (no active corruption)

| Check | Result |
| :--- | :--- |
| Account top-level keys | Only schema keys (`potions`, `recipes`, `items`, `grows`, `refines`, `additives`, `vendorItems`, `accountVersion`) |
| Recipe ↔ potion mapping | 36 potions, 25 recipes; **0** orphan recipes, **0** dangling recipeKeys, **0** empty recipeKeys |
| Underscore runtime keys on Account | None |
| grows / refines | Nested stats keyed by seed/plant uid strings — valid schema (not missing seedUid fields) |
| Settings character keys | 20 alts; **no** `^realm` markup |
| Watch → potion/recipe | **0** unknown potion uids, **0** dangling recipeKeys across all buckets |
| Obsolete Settings keys | `perfEnabled`, `perfThresholdMs` present (pre-LibPerf); harmless until stripped |

### Historical corruption (already cleaned in live file)

`SavedVariables.lua.bak_cleanup` shows Account once held **settings flags** (`growPlantSurplusSeeds`, `autoGrowAdditives`, …) mixed into knowledge — classic settings/account leak. Live Account no longer has those keys.

### Fix shipped in 0.4.115 (prevent recurrence)

- [`Source/Persistence/Account.lua`](../Source/Persistence/Account.lua) — strip known leaked settings keys on `EnsureAccount`
- [`Source/Persistence/Settings.lua`](../Source/Persistence/Settings.lua) — drop obsolete `perfEnabled` / `perfThresholdMs`; default `potionKnownRecipeOnly`
- [`Source/Core/Audit.lua`](../Source/Core/Audit.lua) — report unexpected Account top-level keys

No writer currently re-introducing Account settings leaks was found in Source (grep clean). No mass wipe required.

### Audit gaps (follow-up)

- `/sp2 audit` still does not walk grow/refine nested product stats for impossible uids
- Does not flag disabled-watch bloat across many alt buckets (hygiene, not corruption)
- Offline `scripts/audit_savedvars.py` is useful for CI-less spot checks

---

## 5. Checklist fill

### Architecture / coupling

| Item | Status |
| :--- | :--- |
| Planner engine calls / world mutation | **Pass** (soft: notify + footer refresh) |
| Adapter business rules | **Fail (soft)** — CraftChat/Vendor wake policy |
| View driving plant/refine from paint | **Pass** |
| Circular Knowledge↔Planner | **Fail (soft–hard)** — RecipeSpec demand + invalidate |
| Duplicate policy Planner vs View | **Fail (soft)** — tip colors / notes overlap |

### Performance doctrine (§6)

| Item | Status |
| :--- | :--- |
| Sync Build on hitch frames | **Unknown / watch** — brew path can GetOrBuild; harvest uses storm/SkipPlan |
| WakeAutoGrow every bag snap | **Pass** (doctrine documented; Scheduler gated) |
| N× bag walks vs WarmSpecHaveCache | **Pass** intent; RecipeSpec hosts the cache |
| Alloc on IssueOne / Harvest.Complete | **Unknown** — needs LibPerf trail pass |
| Trail-hold honesty | **Pass** after LibPerf move (0.4.84+) |
| Plant quiet / storm alignment | **Pass** (0.4.96+; harvest-batch hold 0.4.113–114) |

### Correctness / state machines

| Item | Status |
| :--- | :--- |
| Pending plant / refine discipline | **Pass** (with historical orphan-pending fixes in changelog) |
| fillBlocked vs throttle vs harvest-batch hold | **Pass** |
| Brew session vs AutoGrow gating | **Pass** (0.4.103–105 stuck-load fixes) |
| Gen-cache invalidation | **Soft** — complex; RecipeSpec owns many clears |

### RoR / Lua platform

| Item | Status |
| :--- | :--- |
| Local function order | **Unknown** — no automated scan this pass |
| Blind pcall vs TryCall | **Soft** — mixed; Debug.TryCall used in places |
| UTF-8 / locale | **Pass** — Locale + ASCII chat punctuation |
| `.mod` vs XML Script order | **Pass** |

### Maintainability

| Item | Status |
| :--- | :--- |
| Dead / superseded paths | **Soft** — bak_* offline; perf settings cleaned 0.4.115 |
| Naming consistency | **Soft** — Ready craft→brew largely done |
| Locale coverage | **Soft** — Phase 2 done; some domain L"" may remain |
| Dump commands as regression hooks | **Pass** |
| Doc drift SP3 prompt | **Fail** — baseline still 0.4.41 (see §6) |

### Security / safety

| Item | Status |
| :--- | :--- |
| Saved-var migrations / no silent wipe | **Pass** |
| Macro not hijacking stock skills | **Pass** |

### Saved data integrity

| Item | Status |
| :--- | :--- |
| Live Account/Settings integrity | **Pass** |
| Historical leak recurrence guard | **Pass** (0.4.115) |

---

## 6. SP3 blueprint drift (parity baseline 0.4.41 → live 0.4.115)

Update [`docs/STOCKPILER3_BUILD_PROMPT.md`](STOCKPILER3_BUILD_PROMPT.md) when it remains the architecture SoT. High-value deltas since 0.4.41:

| Area | Live SP2 behavior to capture |
| :--- | :--- |
| Localization | Locale scaffold + enUS; `StockPiler2.T`; mojibake-safe ASCII chat |
| Perf | Optional **LibPerf** dependency; in-addon hitch pump removed; harvest storm / plant quiet / SkipPlanThisFrame |
| Harvest | All-planted-ready gate; mid-batch empties OK; **plant-hold while uniform ready batch**; per-plot outcome chat; skip non-growables |
| Brew | Ready edge notify; load chat; stuck-session clears (0.4.103–105); Potent continue |
| Watch traffic lights | Shared yellow vs Buy red ContestedBuyOnly; tip Have/Need AutoGrow-progressable coloring; Seed buffer status |
| AutoGrow | Refine-first when seed-starved; seed buffer vs potion_stock deferral |
| Inventory | L0 no-op snap skip; MaterialSpec parse cache keyed by uid |
| Architecture note | RecipeSpec currently hosts demand/have — SP3 should put that in Planner from day one |
| Domain/View | Grow/Brew currently own chrome — SP3 View Lua must own tooltips/footer binds |

Prompt §9.4 still says enable harvest when “ready plots exist”; live SP2 requires **all planted ready**. Align the contract.

---

## 7. Recommended next steps

1. Land **Planner demand extract** from RecipeSpec (highest leverage).  
2. Extract Harvest/Brew chrome to View.  
3. Snapshot-only Watch status tips.  
4. Keep `/sp2 audit` + `scripts/audit_savedvars.py` in the regression habit after learn/forget storms.  
5. Bump SP3 prompt baseline when starting SP3 work.
