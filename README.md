# StockPiler2

Greenfield rewrite of [StockPiler](../StockPiler) using an **Orchestrator + Stores + Planner + Executors** architecture. Runs as a **separate addon** alongside v1 — does not modify the original StockPiler folder.

**Version:** 0.2.0 (window + Potions/Watch tabs)

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
| `/sp2 plan` | Planner snapshot dump |
| `/sp2 state` | Orchestrator phase + store generations |
| `/sp2 growplan` | Garden plot dump |
| `/sp2 brewplan` | Brew plan dump (scaffold) |
| `/sp2 events` / `on` / `off` / `dump` | Internal event bus trace |
| `/sp2 perf` / `on` / `off` | Frametime hitch logger |
| `/sp2 audit` | Saved variables health |

## UI (v0.2)

- **Potions tab** — learned potion list, search/effect filters, sort columns, watch toggle
- **Watch tab** — global AutoGrow/AutoBuy toggles, per-row target and AutoGrow (no harvest/brew buttons yet)

## Architecture

```
Core/         EventBus, Scheduler, Orchestrator, EngineEventBridge, Debug, Perf, Audit
Stores/       Inventory, Garden, RefinePipeline, Knowledge, Watch, PlanSnapshot
Planner/      Pure Build() with gen-keyed cache
Executors/    Grow / Refine / Brew / Buy stubs
Adapters/     Bag, Cultivator, Apothecary, Vendor
Persistence/  Settings, Character, Account
View/         Window, Templates, TabPotions, TabWatch, Catalog, Ui
```

## Saved data

StockPiler2 starts with **empty** learned data. Relearn recipes in-game.

| Variable | Scope | Contents |
| :--- | :--- | :--- |
| `StockPiler2.Settings` | Shared profile | UI prefs + `characters[characterName]` rows |
| `StockPiler2.Account` | Global | Learned knowledge |

Separate from v1 `StockPiler.*` saved variables.

## Lua pitfalls (addon authors)

RoR’s embedded Lua does **not** hoist `local function` declarations (Lua 5.0–style). If function **A** calls local helper **B**, **B must appear above A** in the file — otherwise: `attempt to call global 'B' (a nil value)`.

**Primary reference:** RoR-Interface `docs/api/lua-local-order.md` (listed in `docs/INDEX.md`).

SP2-specific helper order: `Source/Knowledge/RecipeSpec.lua` (see comment at local helper block).
