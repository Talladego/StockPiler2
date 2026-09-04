# StockPiler2

Greenfield rewrite of StockPiler using an **Orchestrator + Stores + Planner + Executors** architecture. Runs as a **separate addon** alongside v1 — does not modify the original StockPiler folder.

**Version:** 0.4.23

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

Perf tip: spikes with `trail=(none)` / high `emptyTrail%` on baseline are usually **engine** stalls (native craft/UI), not missing Lua sites. Threshold from `/sp2 perf on [ms]` is saved in settings.

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
