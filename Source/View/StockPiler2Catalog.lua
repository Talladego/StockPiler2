----------------------------------------------------------------
-- StockPiler2 View/Catalog — potion list + watch helpers (UI facade)
----------------------------------------------------------------

StockPiler2.Catalog = StockPiler2.Catalog or {}

local function Watches()
    return StockPiler2.Watch and StockPiler2.Watch.GetWatches() or {}
end

function StockPiler2.Catalog.ListPotionRecipeEntries()
    if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.ListPotionRecipeEntries then
        return StockPiler2.RecipeSpec.ListPotionRecipeEntries()
    end
    local out = {}
    local potions = StockPiler2.Knowledge and StockPiler2.Knowledge.GetTable("potions")
    local recipes = StockPiler2.Knowledge and StockPiler2.Knowledge.GetTable("recipes")
    if type(potions) ~= "table" then
        return out
    end
    for key, potion in pairs(potions) do
        if type(potion) == "table" then
            local row = {
                potionRecipeKey = key,
                potionKey = potion.potionKey or key,
                name = potion.name or towstring(tostring(key)),
                outputUid = tonumber(potion.outputUid) or 0,
                iconNum = tonumber(potion.iconNum) or 0,
                effectKey = potion.effectKey,
                power = tonumber(potion.power) or 0,
                stability = tonumber(potion.stability) or 0,
                superCrit = tonumber(potion.superCrit) or 0,
                yield = tonumber(potion.yield) or 0,
                recipeSpecKey = potion.recipeSpecKey,
                recipeLabel = potion.recipeLabel or L"",
            }
            if type(recipes) == "table" and potion.recipeSpecKey and type(recipes[potion.recipeSpecKey]) == "table" then
                row.recipe = recipes[potion.recipeSpecKey]
            end
            out[#out + 1] = row
        end
    end
    table.sort(out, function(a, b)
        local na = string.lower(tostring(a.name or ""))
        local nb = string.lower(tostring(b.name or ""))
        return na < nb
    end)
    return out
end

function StockPiler2.Catalog.EnsureWatch(potionKey)
    local watches = Watches()
    local key = tostring(potionKey or "")
    if key == "" then
        return { enabled = false, targetStock = 40, autoGrow = false }
    end
    local watch = watches[key]
    if type(watch) ~= "table" then
        watch = { enabled = false, targetStock = 40, autoGrow = false }
        watches[key] = watch
    end
    if watch.targetStock == nil then
        watch.targetStock = 40
    end
    if watch.autoGrow == nil then
        watch.autoGrow = false
    end
    return watch
end

function StockPiler2.Catalog.ClearWatchList()
    local watches = Watches()
    local n = 0
    for k in pairs(watches) do
        watches[k] = nil
        n = n + 1
    end
    if StockPiler2.Watch then
        StockPiler2.Watch.BumpGen()
    end
    if StockPiler2.PlanSnapshot and StockPiler2.PlanSnapshot.Invalidate then
        StockPiler2.PlanSnapshot.Invalidate()
    end
    return n
end

function StockPiler2.Catalog.PotionHaveCombined(potion)
    if type(potion) ~= "table" then
        return 0
    end
    local uid = tonumber(potion.outputUid) or 0
    if uid <= 0 or not StockPiler2.Inventory then
        return 0
    end
    return StockPiler2.Inventory.CountByUid(uid) or 0
end

function StockPiler2.Catalog.ForgetPotionRecipeLink(outputUid, recipeSpecKey)
    if StockPiler2.RecipeSpec and StockPiler2.RecipeSpec.ForgetPotionRecipeLink then
        local removed = StockPiler2.RecipeSpec.ForgetPotionRecipeLink(outputUid, recipeSpecKey) == true
        if removed and StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
            StockPiler2.Knowledge.Touch()
        end
        return removed
    end
    return false
end

function StockPiler2.Catalog.ForgetLearnedRecipeSpec(key)
    key = tostring(key or "")
    if key == "" then
        return false
    end
    local RS = StockPiler2.RecipeSpec
    if RS and RS.ParsePotionRecipeKey then
        local parsed = RS.ParsePotionRecipeKey(key)
        if type(parsed) == "table" and parsed.isComposite == true
            and type(parsed.recipeSpecKey) == "string" and parsed.recipeSpecKey ~= ""
        then
            return StockPiler2.Catalog.ForgetPotionRecipeLink(parsed.outputUid, parsed.recipeSpecKey)
        end
    end
    if RS and RS.ForgetLearnedRecipeSpec then
        local removed = RS.ForgetLearnedRecipeSpec(key) == true
        if removed and StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
            StockPiler2.Knowledge.Touch()
        end
        return removed
    end
    local recipes = StockPiler2.Knowledge and StockPiler2.Knowledge.GetTable("recipes")
    local potions = StockPiler2.Knowledge and StockPiler2.Knowledge.GetTable("potions")
    local removed = false
    if type(recipes) == "table" and recipes[key] ~= nil then
        recipes[key] = nil
        removed = true
    end
    if type(potions) == "table" and potions[key] ~= nil then
        potions[key] = nil
        removed = true
    end
    if removed and StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
        StockPiler2.Knowledge.Touch()
    end
    return removed
end
