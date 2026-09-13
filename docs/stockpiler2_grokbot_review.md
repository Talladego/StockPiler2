## StockPiler2 code quality (HEAD `0.4.144`)

> **Shipped 0.4.145–0.4.150 (GrokBot fix series):** Phase 0 nits; SpecDemand/SpecHaveCache → Planner; snapshot-only tips; Harvest/Brew View chrome; Executor-only auto plant/brew writes; SeedMap Core/Observe/Resolve/Maintenance facade. This review remains the pre-series baseline.

WAR/RoR Lua crafting UI mod: Orchestrator → Executors → Grow/Brew/Refine/Buy, with Knowledge/Stores/Planner/View. You already have a strong self-review in `docs/ARCHITECTURE_REVIEW_0.4.114.md` — most of it still holds; below is what’s still true at 0.4.144 plus concrete bugs/smells I verified in source.

### Overall verdict
**Capable and battle-hardened orchestration**, with real hitch defenses (plant quiet, harvest storm, plan coalesce, demand cache, LibPerf). The main debt is **structure**: a few megamodules still own the wrong layers, so bugs and hitch work keep landing in the same files.

---

### High — structure / maintainability

**1. Knowledge megamodules are still god-objects**
| File | ~LOC |
|------|------|
| `Source/Knowledge/SeedMap.lua` | **5300** |
| `Source/Knowledge/RecipeSpec.lua` | **4300** |
| `Source/Grow/Grow.lua` | **3600** |
| `Source/Brew/Brew.lua` | **3200** |
| `Source/View/StockPiler2TabWatch.lua` | **2600** |

`RecipeSpec.BuildBalancedSpecDemand` / `WarmSpecHaveCache*` are still a **shadow Planner** inside Knowledge. `Planner.BuildWatchRows` calls into RecipeSpec for demand. That circular Knowledge↔Planner coupling is the #1 architectural risk.

**2. Domain owns View chrome**
`Grow.lua` still has footer harvest clickability + harvest tooltip refresh (`MaybeRefreshHarvestTooltip`). Brew similarly owns tip/load UX (per your 0.4.114 review; still large). Executors stay thin stubs (~0.5–1.4 KB) while domains do engine + UI.

**3. Executor boundary is cosmetic**
`GrowExecutor.Tick` just forwards to `Grow.TryPlantNextEmptyPlot` / `TryApplyNextAdditive`. Orchestrator *also* calls `Grow.TryApplyNextAdditive` directly on the additive path — so additives bypass the executor half the time. That makes “one engine write per Tick via Executor” hard to enforce or test.

---

### Medium — performance

**4. Status / seed-buffer tooltips still do heavy work on hover**
In `StockPiler2TabWatch.lua`:
- `BuildStatusTooltipRows` can call `RecipeSpec.BuildBalancedSpecDemand()` then `Planner.BuildRecipeSlotTooltipEntries` when tip slots aren’t precomputed.
- `CollectSeedBufferTooltipData` runs `CollectAutoGrowSeedLines` **and** `Refine.CollectIntents` on mouseover.

Mitigation exists (status tip cache keyed by plan+`snapGen`), but a hover can still force demand/intent work if cache misses after a bag snap — classic hitch-while-mousing pattern. Snapshot-only tips (your backlog item #3) is still the right fix.

**5. Plan rebuild pressure is managed, not eliminated**
`Planner.GetOrBuild({ refresh = false })` mostly returns stale + nudges coalesce — good. Full `Planner.Build` still clears SeedMap plan caches, warms have-cache, rebuilds all watch rows. Fine when gated; expensive if anything forces sync builds mid-storm (brew/`GetOrBuild` paths remain the ones to watch with LibPerf).

---

### Medium — correctness / API smells

**6. EventBus can’t unsubscribe one handler**
`EventBus.Subscribe` only appends; `UnsubscribeAll` wipes the list. No dedupe. `Orchestrator.Initialize` subscribes every call — a second init would double-dispatch harvest/brew commands. Low risk if init is once-only; fragile for reload/`/reloadui` edge cases.

**7. Harvest “active” flag is sync theater**
`Orch.DispatchCommand("harvest")` sets `_harvestActive = true`, calls `GrowExecutor.Harvest` (which only `PrepareHarvestPlot`), then immediately clears the flag. So `IsHarvestActive()` is almost never true for async harvest lifecycle — real state lives in Grow/Scheduler storm. Misleading API; easy to misuse later.

**8. Duplicate slash command**
`Bootstrap.lua`: `bags` and `craftbag` are identical handlers. Dead surface area / confusion.

---

### Low / nits

- **Account leak guards look solid** (`Persistence/Account.lua` strips known leaked settings keys; shutdown slim+strip) — good follow-through on 0.4.115.
- **Perf instrumentation is real** (`Perf.Begin/End` around Orch, demand, tooltips) — use it; don’t remove it.
- **`docs/STOCKPILER3_BUILD_PROMPT.md` baseline drift** (called out in your review) — still worth fixing before SP3 so you don’t rebuild the same layering mistakes.
- GrowExecutor file header still declares other executors as stubs in one place — messy ownership vs separate Buy/Brew/Refine files.

---

### What’s actually good
- Clear intended architecture (Adapters / Stores / Planner / Executors / Scheduler).
- Hitch doctrine is coded, not just documented (storm/quiet early-returns in `Orchestrator.Tick`, fill-blocked refine-only path, combat plant defer without fill-block).
- Saved-var hygiene and `/sp2 audit` are mature for an addon this size.
- Demand caching (`_demandCache` + per-orch-tick memo) shows you’ve already fought the N× bag-walk problem.

---

### Top 5 fixes (same order I’d ship)
1. Move `BuildBalancedSpecDemand` / have-cache warm into `Planner/` (or `Planner/SpecDemand.lua`).
2. Extract Grow/Brew tooltips + footer binds into `View/`.
3. Status + seed-buffer tips: **snapshot fields only** (no `BuildBalanced` / `CollectIntents` on hover).
4. Make additive + plant engine writes go **only** through Executors; delete Orch→Grow direct additive call.
5. Split `SeedMap.lua` along observe / resolve / maintenance (after 1–4).

I can open a cloud agent to do fix #1 as a PR when GitHub stops rate-limiting, or draft a concrete split plan for `RecipeSpec` if you want that next.