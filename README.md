# StockPiler2

Greenfield rewrite of StockPiler using an **Orchestrator + Stores + Planner + Executors** architecture. Runs as a **separate addon** alongside v1 — does not modify the original StockPiler folder.

**Version:** 0.3.0

## Install

1. Ensure the `StockPiler2` folder is under `Interface/AddOns/`.
2. Enable **StockPiler2** in the addon list (v1 can stay enabled for parallel testing).
3. `/reloadui`

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
| `/sp2 perf` / `on` / `off` / `summary` | Frametime hitch logger |
| `/sp2 perf on [ms]` / `baseline [ms]` | Hitch threshold / baseline |
| `/sp2 audit` | Saved variables health |
| `/sp2 harvest` | Prepare next ready plot (macro/CMD path) |

## UI (v0.3)

- **Potions tab** — learned potion list, search/effect filters, sort columns, watch toggle
- **Watch tab** — AutoGrow / AutoBuy / seed buffer, per-row target and AutoGrow, status / stock / craftable colors
- **Row Brew** — Idle → Load → Brew (L-click); R-click unloads that row’s load
- **Footer Brew** — auto-picks green Ready watches only; R-click clears the load
- **Footer Harvest** — native cultivation harvest action when plots are ready

## Brew behavior

- Footer Brew only loads/performs watches that are **Ready to craft** (deficit > 0, uncontested craftable).
- After an **auto** brew hits the watch target, the session clears so the next footer click can pick another Ready watch.
- **Manual** row Load/Brew can overstock (target already met or yellow shared craftable).
- Shared-materials contention uses crafts **needed for deficit**, not max crafts possible from bags.

## Architecture

```
Core/         EventBus, Scheduler, Orchestrator, EngineEventBridge, Debug, Perf, Audit
Stores/       Inventory, Garden, RefinePipeline, Knowledge, Watch, PlanSnapshot
Planner/      Pure Build() with gen-keyed cache
Grow/         Plant job pick + harvest helpers
Brew/         Load / perform / session (footer + row)
Refine/       Seed buffer refine intents
Buy/          Vendor buy jobs
Executors/    Grow / Refine / Brew / Buy
Adapters/     Bag, Cultivator, Apothecary, Vendor, CraftChat
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

## Lua pitfalls (addon authors)

RoR’s embedded Lua does **not** hoist `local function` declarations (Lua 5.0–style). If function **A** calls local helper **B**, **B must appear above A** in the file — otherwise: `attempt to call global 'B' (a nil value)`.

**Primary reference:** RoR-Interface `docs/api/lua-local-order.md` (listed in `docs/INDEX.md`).

SP2-specific helper order: `Source/Knowledge/RecipeSpec.lua` (see comment at local helper block).
