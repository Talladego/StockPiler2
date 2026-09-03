----------------------------------------------------------------
-- StockPiler2 Core/Audit — saved-data health (/sp2 audit)
----------------------------------------------------------------

StockPiler2.Audit = StockPiler2.Audit or {}

local function Emit(emit, msg)
    if type(emit) == "function" then
        emit(msg)
    elseif StockPiler2.Debug and StockPiler2.Debug.LogAlways then
        StockPiler2.Debug.LogAlways("audit| " .. tostring(msg))
    end
end

local function TableSize(t)
    local n = 0
    if type(t) ~= "table" then
        return 0
    end
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

local function OutcomeCount(recipe)
    if type(recipe) ~= "table" or type(recipe.outcomes) ~= "table" then
        return 0
    end
    local n = 0
    for _ in pairs(recipe.outcomes) do
        n = n + 1
    end
    return n
end

local function RecipeKeyLinkedByPotions(potions, recipes, recipeSpecKey)
    if type(potions) ~= "table" or type(recipeSpecKey) ~= "string" or recipeSpecKey == "" then
        return false
    end
    local RS = StockPiler2.RecipeSpec
    local canon = recipeSpecKey
    if RS and RS.RecipeFingerprintForKey and type(recipes) == "table" then
        canon = RS.RecipeFingerprintForKey(recipes, recipeSpecKey) or recipeSpecKey
    end
    for _, potion in pairs(potions) do
        if type(potion) == "table" then
            local keys = potion.recipeKeys or potion.alternateRecipeSpecKeys
            if type(keys) == "table" then
                for i = 1, #keys do
                    local key = keys[i]
                    if key == recipeSpecKey or key == canon then
                        return true
                    end
                    if RS and RS.RecipeFingerprintForKey and type(recipes) == "table" then
                        local keyCanon = RS.RecipeFingerprintForKey(recipes, key)
                        if keyCanon == recipeSpecKey or keyCanon == canon then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

function StockPiler2.Audit.RunMapping(emitLog)
    emitLog = type(emitLog) == "function" and emitLog or function(msg)
        StockPiler2.Debug.Print(msg)
    end
    Emit(emitLog, "--- recipe/potion mapping ---")

    local acct = StockPiler2.Account
    if type(acct) ~= "table" then
        Emit(emitLog, "  account: (missing)")
        Emit(emitLog, "--- end mapping ---")
        return
    end

    local recipes = acct.recipes
    local potions = acct.potions
    if type(recipes) ~= "table" then
        recipes = {}
    end
    if type(potions) ~= "table" then
        potions = {}
    end

    local RS = StockPiler2.RecipeSpec
    local mismatches = 0
    local multiOutcome = 0
    local multiRecipe = 0
    local orphanRecipes = 0
    local orphanPotions = 0
    local activeWarnings = 0

    for key, recipe in pairs(recipes) do
        if type(recipe) == "table" then
            if OutcomeCount(recipe) > 1 then
                multiOutcome = multiOutcome + 1
            end
            if not RecipeKeyLinkedByPotions(potions, recipes, key) then
                orphanRecipes = orphanRecipes + 1
                Emit(emitLog, "  orphan recipe (no potion recipeKeys): " .. tostring(key))
                mismatches = mismatches + 1
            end
            if type(recipe.outcomes) == "table" then
                for uidKey, _ in pairs(recipe.outcomes) do
                    local uid = tonumber(uidKey) or 0
                    if uid > 0 and RS and RS.PotionKeyFromUid then
                        local potionKey = RS.PotionKeyFromUid(uid)
                        local potion = potionKey and potions[potionKey] or nil
                        local linked = false
                        if type(potion) == "table" then
                            local keys = potion.recipeKeys or potion.alternateRecipeSpecKeys
                            if type(keys) == "table" then
                                for i = 1, #keys do
                                    if keys[i] == key then
                                        linked = true
                                        break
                                    end
                                end
                            end
                        end
                        if not linked then
                            Emit(emitLog, "  missing potion backlink: recipe " .. tostring(key)
                                .. " outcome uid:" .. tostring(uid))
                            mismatches = mismatches + 1
                        end
                    end
                end
            end
        end
    end

    for potionKey, potion in pairs(potions) do
        if type(potion) == "table" then
            local uid = tonumber(potion.outputUid) or 0
            local keys = potion.recipeKeys or potion.alternateRecipeSpecKeys
            if type(keys) ~= "table" then
                keys = {}
            end
            if #keys > 1 then
                multiRecipe = multiRecipe + 1
            end
            if #keys == 0 then
                orphanPotions = orphanPotions + 1
                Emit(emitLog, "  orphan potion (no recipeKeys): " .. tostring(potionKey))
                mismatches = mismatches + 1
            end
            local active = potion.activeRecipeKey or potion.activeRecipeSpecKey
            if #keys > 1 and (type(active) ~= "string" or active == "") then
                activeWarnings = activeWarnings + 1
                Emit(emitLog, "  missing activeRecipeKey: " .. tostring(potionKey)
                    .. " (" .. tostring(#keys) .. " recipes)")
                mismatches = mismatches + 1
            end
            if type(active) == "string" and active ~= "" then
                local inKeys = false
                for i = 1, #keys do
                    if keys[i] == active then
                        inKeys = true
                        break
                    end
                end
                if not inKeys then
                    Emit(emitLog, "  activeRecipeKey not in recipeKeys: " .. tostring(potionKey))
                    mismatches = mismatches + 1
                end
            end
            for i = 1, #keys do
                local recipeKey = keys[i]
                local recipe = type(recipeKey) == "string" and recipes[recipeKey] or nil
                if type(recipe) ~= "table" then
                    Emit(emitLog, "  dangling potion recipeKey: " .. tostring(potionKey)
                        .. " -> " .. tostring(recipeKey))
                    mismatches = mismatches + 1
                elseif type(recipe.outcomes) == "table" and next(recipe.outcomes) ~= nil then
                    if type(recipe.outcomes[tostring(uid)]) ~= "table" then
                        Emit(emitLog, "  potion uid never produced by recipe: "
                            .. tostring(potionKey) .. " -> " .. tostring(recipeKey))
                        mismatches = mismatches + 1
                    end
                end
            end
            if uid > 0 and #keys > 0 then
                local hasRecipe = false
                if RS and RS.RecipeSpecForPotionRecipe then
                    for i = 1, #keys do
                        local prKey = RS.PotionRecipeKey and RS.PotionRecipeKey(uid, keys[i])
                        if prKey and RS.RecipeSpecForPotionRecipe(prKey) then
                            hasRecipe = true
                            break
                        end
                    end
                end
                if not hasRecipe then
                    for i = 1, #keys do
                        if type(recipes[keys[i]]) == "table" then
                            hasRecipe = true
                            break
                        end
                    end
                end
                if not hasRecipe then
                    orphanPotions = orphanPotions + 1
                end
            end
        end
    end

    Emit(emitLog, string.format(
        "  multiOutcomeRecipes=%d multiRecipePotions=%d orphanRecipes=%d orphanPotions=%d activeWarnings=%d mismatches=%d",
        multiOutcome, multiRecipe, orphanRecipes, orphanPotions, activeWarnings, mismatches
    ))
    Emit(emitLog, "--- end mapping ---")
end

function StockPiler2.Audit.Run(emitLog)
    emitLog = type(emitLog) == "function" and emitLog or function(msg)
        StockPiler2.Debug.Print(msg)
    end
    Emit(emitLog, "--- StockPiler2 audit ---")

    local charKey = "_default"
    if StockPiler2.Persistence and StockPiler2.Persistence.GetCharacterKey then
        charKey = StockPiler2.Persistence.GetCharacterKey()
    elseif StockPiler2.Watch and StockPiler2.Watch.GetCharacterKey then
        charKey = StockPiler2.Watch.GetCharacterKey()
    end
    Emit(emitLog, "  characterKey=" .. tostring(charKey))

    local acct = StockPiler2.Account
    if type(acct) ~= "table" then
        Emit(emitLog, "  account: (missing)")
    else
        Emit(emitLog, "  accountVersion=" .. tostring(acct.accountVersion or "?"))
        Emit(emitLog, "  items=" .. tostring(TableSize(acct.items)))
        Emit(emitLog, "  recipes=" .. tostring(TableSize(acct.recipes)))
        Emit(emitLog, "  potions=" .. tostring(TableSize(acct.potions)))
        Emit(emitLog, "  grows=" .. tostring(TableSize(acct.grows)))
        Emit(emitLog, "  refines=" .. tostring(TableSize(acct.refines)))
        Emit(emitLog, "  additives=" .. tostring(TableSize(acct.additives)))
        Emit(emitLog, "  vendorItems=" .. tostring(TableSize(acct.vendorItems)))
    end

    local settings = StockPiler2.Settings
    if type(settings) ~= "table" then
        Emit(emitLog, "  settings: (missing)")
    else
        Emit(emitLog, "  settingsVersion=" .. tostring(settings.settingsVersion or "?"))
        Emit(emitLog, "  charactersVersion=" .. tostring(settings.charactersVersion or "?"))
        local chars = settings.characters
        local bucketCount = TableSize(chars)
        Emit(emitLog, "  characterBuckets=" .. tostring(bucketCount))
        local activeBucket = type(chars) == "table" and chars[charKey] or nil
        if type(activeBucket) == "table" then
            Emit(emitLog, "  activeBucket watches=" .. tostring(TableSize(activeBucket.watches))
                .. " autoGrow=" .. tostring(activeBucket.autoGrowEnabled == true)
                .. " additives=" .. tostring(activeBucket.autoGrowAdditives == true)
                .. " autoBuy=" .. tostring(activeBucket.autoBuyEnabled == true))
        else
            Emit(emitLog, "  activeBucket: (none yet)")
        end
    end

    if StockPiler2.Inventory and StockPiler2.Inventory.GetSnapshotMeta then
        local meta = StockPiler2.Inventory.GetSnapshotMeta()
        if type(meta) == "table" then
            Emit(emitLog, string.format(
                "  inventory snapGen=%d ready=%s uids=%d",
                tonumber(meta.snapGen) or 0,
                tostring(meta.ready),
                tonumber(meta.uidCount) or 0
            ))
        end
    end

    StockPiler2.Audit.RunMapping(emitLog)
    Emit(emitLog, "--- end audit ---")
end
