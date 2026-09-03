# Lua local function order

**Canonical doc:** `RoR-Interface/docs/api/lua-local-order.md`

RoR uses Lua 5.0–style scoping: `local function` callees must appear **above** callers in the same file.

**SP2 hotspot:** `Source/Knowledge/RecipeSpec.lua` — `PotionRecipeKeys` before `PotionActiveRecipeKey`; `CharacterBuckets` before `ScrubExactWatchKeyAll`.
