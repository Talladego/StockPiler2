# StockPiler2 Code Quality Report

**Version:** **0.4.144** (`StockPiler2.mod` UiMod version; analysis date 2026-09-13)  
**Scope:** Read-only review of Talladego/StockPiler2 HEAD. Report only — no application code changes in this pass.  
**Prior art:** `docs/ARCHITECTURE_REVIEW_0.4.114.md` (verified still largely applicable).

---

## Overall verdict

Capable, battle-hardened orchestration for a WAR/RoR crafting UI mod, with real hitch defenses (plant quiet, harvest storm, plan coalesce, demand cache, optional LibPerf). Main debt is **structure**: Knowledge/Grow/Brew megamodules still own the wrong layers, so bugs and hitch work keep landing in the same files.

**Verdict:** production-usable for AutoGrow workflows; prioritize Planner/demand extraction and snapshot-only tooltips before further feature growth.

---

## High — structure / maintainability

### 1. Knowledge megamodules are god-objects

| File | Approx size |
|------|-------------|
| `Source/Knowledge/SeedMap.lua` | ~192 KB / ~5300 LOC |
| `Source/Knowledge/RecipeSpec.lua` | ~158 KB / ~4300 LOC |
| `Source/Grow/Grow.lua` | ~132 KB / ~3600 LOC |
| `Source/Brew/Brew.lua` | ~110 KB / ~3200 LOC |
| `Source/View/StockPiler2TabWatch.lua` | ~100 KB / ~2600 LOC |

`RecipeSpec.BuildBalancedSpecDemand` / `WarmSpecHaveCache*` remain a **shadow Planner** inside Knowledge. `Planner.BuildWatchRows` calls RecipeSpec for demand → circular Knowledge↔Planner coupling.

### 2. Domain owns View chrome

`Grow.lua` still owns footer harvest clickability and harvest tooltip refresh. Brew similarly owns tip/load UX. Executors stay thin stubs while domains do engine + UI.

### 3. Executor boundary is cosmetic

`GrowExecutor.Tick` forwards to Grow plant/additive helpers. Orchestrator also calls `Grow.TryApplyNextAdditive` directly — additives bypass the executor half the time.

---

## Medium — performance

### 4. Status / seed-buffer tooltips do heavy work on hover

`Source/View/StockPiler2TabWatch.lua`:
- `BuildStatusTooltipRows` can call `RecipeSpec.BuildBalancedSpecDemand()` then `Planner.BuildRecipeSlotTooltipEntries` when tip slots aren’t precomputed.
- `CollectSeedBufferTooltipData` runs `CollectAutoGrowSeedLines` and `Refine.CollectIntents` on mouseover.

Mitigation: status tip cache keyed by plan + `snapGen`. Cache misses after bag snaps can still hitch-while-mousing. Prefer snapshot-only tips.

### 5. Plan rebuild pressure is managed, not eliminated

`Planner.GetOrBuild({ refresh = false })` returns stale + nudges coalesce (good). Full `Planner.Build` still clears SeedMap plan caches, warms have-cache, rebuilds all watch rows — expensive if anything forces sync builds mid-storm.

---

## Medium — correctness / API smells

### 6. EventBus cannot unsubscribe one handler

`EventBus.Subscribe` only appends; `UnsubscribeAll` wipes. No dedupe. A second `Orchestrator.Initialize` would double-dispatch harvest/brew.

### 7. Harvest “active” flag is sync theater

`Orch.DispatchCommand("harvest")` sets `_harvestActive`, calls `GrowExecutor.Harvest` (prepare only), then clears immediately. Real async harvest state lives in Grow/Scheduler storm — misleading API.

### 8. Duplicate slash command

`Bootstrap.lua`: `bags` and `craftbag` are identical handlers.

---

## Low / nits

- Account leak guards look solid (`Persistence/Account.lua`; shutdown slim+strip) — good follow-through on 0.4.115.
- Perf instrumentation (`Perf.Begin/End`) is real — keep it.
- `docs/STOCKPILER3_BUILD_PROMPT.md` baseline drift vs live behavior (noted in 0.4.114 review).

---

## What’s good

- Clear intended architecture (Adapters / Stores / Planner / Executors / Scheduler).
- Hitch doctrine is coded (storm/quiet early-returns in `Orchestrator.Tick`, fill-blocked refine-only path, combat plant defer without fill-block).
- Saved-var hygiene and `/sp2 audit` are mature.
- Demand caching (`_demandCache` + per-orch-tick memo) addresses N× bag walks.

---

## Top fixes (priority)

1. Move `BuildBalancedSpecDemand` / have-cache warm into `Planner/` (or `Planner/SpecDemand.lua`).
2. Extract Grow/Brew tooltips + footer binds into `View/`.
3. Status + seed-buffer tips: snapshot fields only (no `BuildBalanced` / `CollectIntents` on hover).
4. Route additive + plant engine writes only through Executors; delete Orch→Grow direct additive call.
5. Split `SeedMap.lua` along observe / resolve / maintenance (after 1–4).

---

## Cross-reference

See also `docs/ARCHITECTURE_REVIEW_0.4.114.md` for layer scorecard, hotspot section maps, and saved-data integrity notes from the 0.4.114/0.4.115 pass.
