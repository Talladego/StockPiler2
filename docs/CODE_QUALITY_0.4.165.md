# StockPiler2 Code Quality Report

**Version:** **0.4.165** (`StockPiler2.mod` UiMod version; `StockPiler2.Version`)  
**HEAD:** `af96e36f58327b21fdd927b9b440966222bde38a`  
**Analysis date:** 2026-09-14  
**Scope:** Full re-review of Talladego/StockPiler2 HEAD Lua under `Source/` (Core, Planner, Grow, Brew, Executors, Stores, View, Adapters, Knowledge). Report only — no application code changes in this pass.  
**Prior art:** closed issues #2–#4 (0.4.144 era); `docs/CODE_QUALITY_0.4.144.md` (PR #1 branch, verified against current code). Treat 0.4.165 as **new**.

---

## Overall verdict

Capable AutoGrow orchestration with real hitch defenses (plant quiet ≥ harvest storm, fill-block refine-only, cheap/garden-patch plan paths, SpecHaveCache). 0.4.160–0.4.165 stall/Status fixes are present in code.  
**New High defects** are Watch tooltip hover paths that still resolve/bag-walk or mutate plan tip payloads (incomplete Issue #4 follow-through).

**Critical:** 0  
**High:** 2 → [#5](https://github.com/Talladego/StockPiler2/issues/5), [#6](https://github.com/Talladego/StockPiler2/issues/6)  
**Summary issue:** [#7](https://github.com/Talladego/StockPiler2/issues/7)

---

## Critical / High

### High — Status tip hover still ResolveSeed/bag-walks and mutates tip slots (#5)

**Where:** `Source/View/StockPiler2TabWatch.lua` `BuildStatusTooltipRows` (~1778–1826); `Source/Grow/Grow.lua` `GrowingNotesForSpec`; `Source/Planner/SpecHaveCache.lua` `CountItemsMatchingSpec`.

**What's wrong:**
1. Calls `Grow.GrowingNotesForSpec(entry.spec)` without `{ cacheOnly = true }` → `FindPlantUidForSpec` + `ResolveSeedForSpec` on hover, despite comments saying never ResolveSeed on this path. Planner already uses `cacheOnly` at ~1601.
2. Per-slot `CountItemsMatchingSpec` may `Inventory.ForEachItem` on have-cache miss.
3. Writes `have`/`deficit`/`stocked`/`craftsHave` onto shared `row.statusTipSlots`.

**Why it matters:** First Status hover after snap / cold WarmHave can hitch; mutated tip slots pollute plan/list state until rebuild.

**Suggested check:** Hover Status with cold have-cache; assert no resolve/bag-walk; copy tip fields locally; use `GrowingNotesForSpec(spec, { cacheOnly = true })` or plan-time `growingNotes` only.

### High — Seed-buffer tip mutates/sorts plan.seedBufferTipData on hover (#6)

**Where:** `Source/View/StockPiler2TabWatch.lua` `CollectSeedBufferTooltipData` (~1111–1152); consumer `BuildSeedBufferTipData` `opts.previous` in `Source/Planner/Planner.lua`.

**What's wrong:** Mutates `live`/`total`/`shortBy` on plan tip `watched[]` and `table.sort`s that array in place. Cheap/garden-patch rebuilds reuse `previous.seedBufferTipData`.

**Why it matters:** Hover is not a plan owner; order and live fields leak into later tip builds.

**Suggested check:** Tip `watched` order unchanged after hover; shallow-copy before patch/sort.

---

## Verified fixed since 0.4.144 / #2–#4

| Prior finding | Status at 0.4.165 |
|---------------|-------------------|
| EventBus no single Unsubscribe / double-init (#3) | **Fixed** — token Subscribe/Unsubscribe, dedupe, Orch/Sch/Ui/Brew Shutdown, `_initialized` |
| Status/seed-buffer tips rebuild demand on hover (#4) | **Partially fixed** — no `BuildBalanced` / `HasResinConvertFeedstock` on tip path; **residual** #5/#6 |
| SeedMap ~5.3k god-file | **Split** — Core / Observe / Resolve / Maintenance |
| Harvest active sync theater | **Improved** — `Orch.IsHarvestActive` → Grow op-lock |
| Fill-block / seed-buffer / Ready-Stocked stalls (0.4.160–165) | **Present in code** (SetFillBlocked non-rearm, buffer refine bootstrap, ApplyLiveWatchStatus demotions) |

---

## Medium / structure (not separate issues)

1. **Megamodules:** Grow ~3606, RecipeSpec ~3368, Brew ~3320, Planner ~2910, TabWatch ~2357 LOC — high change concentration.
2. **Executor boundary cosmetic:** GrowExecutor/BrewExecutor mostly forward to domain.
3. **EventBus.Fire → Debug.TryCallQuiet unguarded** — OK with Debug loaded first in `.mod`; API smell.
4. **Plan rebuild pressure managed, not eliminated** — keep force-sync off hot trails.
5. **Domain owns some View chrome** (Grow harvest tip helpers, Brew session UX).

---

## What's good

- Hitch doctrine in Orchestrator/Scheduler (quiet ≥ storm, fill-blocked refine-only, combat plant defer without fill-block).
- Live Watch Status without full `/sp2 watchplan` (ApplyLiveWatchStatus / PatchWatchRowsLiveCounts).
- SpecDemand + SpecHaveCache under Planner; RecipeSpec compatibility shims.
- Saved-var hygiene, `/sp2 audit`, Perf.Begin/End marks.

---

## Top fixes (priority)

1. Fix #5 — Status tip: cacheOnly notes + no bag-walk Have + no writeback to `statusTipSlots`.
2. Fix #6 — Seed-buffer tip: copy before live patch/sort.
3. Optional: tip live Have only via warm SpecHaveCache / CountByUid.
4. Longer-term: continue extracting Grow/Brew tip chrome into View; keep megamodule splits going.

---

## Cross-reference

- Summary issue: https://github.com/Talladego/StockPiler2/issues/7  
- Bugs: https://github.com/Talladego/StockPiler2/issues/5 · https://github.com/Talladego/StockPiler2/issues/6  
- Prior: closed #2–#4; architecture notes in README 0.4.160–0.4.165 changelog entries.
