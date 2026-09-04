# StockPiler2

Greenfield rewrite of StockPiler using an **Orchestrator + Stores + Planner + Executors** architecture. Runs as a **separate addon** alongside v1 — does not modify the original StockPiler folder.

**Version:** 0.4.13

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
| `/sp2 perf` / `on` / `off` / `summary` | Frametime hitch logger |
| `/sp2 perf on [ms]` / `baseline [ms]` | Hitch threshold / baseline |
| `/sp2 audit` | Saved variables health |
| `/sp2 harvest` | Prepare next ready plot (macro/CMD path) |

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

## Versioning

On each user-facing ship, bump together:

1. `StockPiler2.mod` `version` + `date`
2. `Source/Bootstrap.lua` `StockPiler2.Version`
3. This README **Version:** line + a changelog bullet below

| Bump | When |
| :--- | :--- |
| **Patch** (`0.x.Y+1`) | Bugfix / polish only |
| **Minor** (`0.X+1.0`) | New behavior / UX features |
| **Major** (`N+1.0.0`) | Breaking saved-var / architecture break (rare in 0.x) |

## Changelog

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
