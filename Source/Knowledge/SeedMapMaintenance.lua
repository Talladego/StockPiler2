----------------------------------------------------------------
-- StockPiler2 SeedMap shared module support
----------------------------------------------------------------

StockPiler2.SeedMap = StockPiler2.SeedMap or {}
local SeedMap = StockPiler2.SeedMap
SeedMap._private = SeedMap._private or {}
local Private = SeedMap._private

function StockPiler2.SeedMap.RepairFromLearnedRecipes()
    local seen = {}
    local repaired = 0
    local recipes = Private.AccountTable("recipes")
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" and type(recipe.slots) == "table" then
            for i = 1, #recipe.slots do
                local slot = recipe.slots[i]
                if type(slot) == "table" and Private.GROW_REPAIR_ROLES[slot.role] then
                    local uid = tonumber(slot.uid) or 0
                    if uid > 0 and not seen[uid] then
                        seen[uid] = true
                        if StockPiler2.SeedMap.RegisterPlantUid(uid, "learned") then
                            repaired = repaired + 1
                        end
                    end
                end
            end
        end
    end
    return repaired
end

function StockPiler2.SeedMap.ResetSpecMaps()
    Private.ClearAccountTable("grows")
    Private.ClearAccountTable("refines")
    StockPiler2.SeedMap._specBootstrapDone = true
    local repaired = StockPiler2.SeedMap.RepairFromLearnedRecipes() or 0
    if StockPiler2.Trace then
        StockPiler2.Trace("Reset grow/refine maps recipeRepair=" .. tostring(repaired))
    end
    if StockPiler2.AutoGrow and StockPiler2.AutoGrow.InvalidatePlantQueue then
        StockPiler2.AutoGrow.InvalidatePlantQueue()
    end
    return 0, repaired
end

function StockPiler2.SeedMap.ApplyPendingMapReset()
    return false
end

function StockPiler2.SeedMap.BootstrapSpecMap()
    if StockPiler2.SeedMap.EnsureSpecBootstrap then
        StockPiler2.SeedMap.EnsureSpecBootstrap()
    end
    if StockPiler2.SeedMap.RepairFromLearnedRecipes then
        return StockPiler2.SeedMap.RepairFromLearnedRecipes() or 0
    end
    return 0
end

function StockPiler2.SeedMap.ForgetUnrelatedLearnedMaps()
    local dropped = 0

    local grows = Private.AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            local seedUid = tonumber(seedKey) or 0
            local seedData = seedUid > 0 and Private.LookupItemData(seedUid) or nil
            if Private.IsResinLikeItem(seedData, seedUid) then
                grows[seedKey] = nil
                dropped = dropped + 1
                Private.D("SeedMap forgot resin grow seedUid=" .. tostring(seedUid))
            else
                local seedIsPacket = StockPiler2.SeedMap.IsSeedPacketUid(seedUid)
                for plantKey, row in pairs(plants) do
                    if type(row) == "table" then
                        local plantUid = tonumber(plantKey) or 0
                        local plantData = plantUid > 0 and Private.LookupItemData(plantUid) or nil
                        local resinPlant = StockPiler2.SeedMap.IsResinUid and StockPiler2.SeedMap.IsResinUid(plantUid)
                        local eligible = Private.IsEligibleHarvestProductUid(plantUid, seedUid)
                        local drop = resinPlant or not eligible
                        -- Packet→standard plant (Bitter→Musty) kept via genus token or packet flag.
                        if not drop
                            and type(plantData) == "table"
                            and type(seedData) == "table"
                            and not Private.SeedPlantPairRelated(seedData, plantData)
                            and not Private.EngineListsSeedForPlant(plantUid, seedUid)
                            and not (seedIsPacket and StockPiler2.SeedMap.GrowNamesGenusRelated(plantData.name, seedData.name))
                        then
                            drop = true
                        end
                        if drop then
                            plants[plantKey] = nil
                            dropped = dropped + 1
                            Private.D("SeedMap forgot unrelated grow plantUid=" .. tostring(plantUid)
                                .. " seedUid=" .. tostring(seedUid))
                        end
                    end
                end
                if next(plants) == nil then
                    grows[seedKey] = nil
                end
            end
        end
    end

    local refines = Private.AccountTable("refines")
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            local plantUid = tonumber(plantKey) or 0
            local seedUid = tonumber(entry.seedUid) or 0
            if plantUid > 0 then
                local plantData = Private.LookupItemData(plantUid)
                local resinPlant = StockPiler2.SeedMap.IsResinUid and StockPiler2.SeedMap.IsResinUid(plantUid)
                if resinPlant then
                    if seedUid > 0 then
                        entry.seedUid = 0
                        entry.seedKind = nil
                        dropped = dropped + 1
                        Private.D("SeedMap forgot unrelated refine plantUid=" .. tostring(plantUid)
                            .. " seedUid=" .. tostring(seedUid))
                    end
                else
                    -- Always reassign from best related seedOut (never keep wrong seedUid for resin).
                    if Private.PreferBestRefineSeedUid(plantUid, entry) then
                        dropped = dropped + 1
                        Private.D("SeedMap repaired refine seedUid plantUid=" .. tostring(plantUid)
                            .. " seedUid=" .. tostring(entry.seedUid or 0)
                            .. " was=" .. tostring(seedUid))
                    end
                    -- Drop zero-sample / unrelated seedOut rows left behind.
                    if type(entry.seedOut) == "table" then
                        for outKey, row in pairs(entry.seedOut) do
                            local outUid = tonumber(outKey) or 0
                            local outData = outUid > 0 and Private.LookupItemData(outUid) or nil
                            local samples = type(row) == "table" and (tonumber(row.samples) or 0) or 0
                            local bad = outUid <= 0
                                or StockPiler2.SeedMap.IsSeedPacketUid(outUid)
                                or (type(plantData) == "table" and type(outData) == "table"
                                    and not Private.SeedPlantPairRelated(outData, plantData)
                                    and samples <= 0)
                                or (type(plantData) == "table" and type(outData) == "table"
                                    and not Private.SeedPlantPairRelated(outData, plantData)
                                    and not Private.EngineListsSeedForPlant(plantUid, outUid))
                            if bad then
                                entry.seedOut[outKey] = nil
                                dropped = dropped + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return dropped
end

function Private.OutcomeItemName(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return "?"
    end
    local data = Private.LookupItemData(uid)
    local name = Private.ToNarrow(data and data.name)
    if name ~= "" then
        return name
    end
    if StockPiler2.ItemDisplayName then
        name = Private.ToNarrow(StockPiler2.ItemDisplayName(uid, nil))
        if name ~= "" then
            return name
        end
    end
    return tostring(uid)
end

function Private.FormatOutcomeQty(prod)
    if type(prod) ~= "table" then
        return ""
    end
    if (tonumber(prod.samples) or 0) > 0 then
        return string.format("%.1fx ", Private.OutcomeAvg(prod))
    end
    if (tonumber(prod.last) or 0) > 0 then
        return tostring(prod.last) .. "x "
    end
    return ""
end

function Private.FormatOutcomeProducts(list)
    local parts = {}
    for i = 1, #list do
        local prod = list[i]
        local uid = tonumber(prod.uid) or 0
        parts[#parts + 1] = Private.FormatOutcomeQty(prod)
            .. Private.OutcomeItemName(uid)
            .. " (" .. tostring(uid) .. ")"
    end
    if #parts == 0 then
        return "(none)"
    end
    return table.concat(parts, ", ")
end

function Private.DumpGrowsToChat(chatMax)
    local grows = Private.AccountTable("grows")
    local rows = {}
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            local seedUid = tonumber(seedKey) or 0
            local products = StockPiler2.SeedMap.HarvestProducts(seedUid)
            rows[#rows + 1] = {
                uid = seedUid,
                name = Private.OutcomeItemName(seedUid),
                products = products,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.name ~= b.name then
            return string.lower(a.name) < string.lower(b.name)
        end
        return (a.uid or 0) < (b.uid or 0)
    end)
    local header = "Grows (seed -> plants): " .. tostring(#rows)
    Private.D("SeedMap dump " .. header)
    if StockPiler2.Print then
        StockPiler2.Print(towstring(header))
    end
    chatMax = tonumber(chatMax) or 30
    for i = 1, #rows do
        local row = rows[i]
        local line = row.name .. " (" .. tostring(row.uid) .. ") -> "
            .. Private.FormatOutcomeProducts(row.products)
        Private.D("SeedMap " .. line)
        if i <= chatMax and StockPiler2.Print then
            StockPiler2.Print(towstring(line))
        end
    end
    if #rows > chatMax and StockPiler2.Print then
        StockPiler2.Print(L"... " .. towstring(tostring(#rows - chatMax))
            .. L" more written to uilog.log")
    end
    return #rows
end

function Private.DumpRefinesToChat(chatMax)
    local refines = Private.AccountTable("refines")
    local rows = {}
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            local plantUid = tonumber(plantKey) or 0
            rows[#rows + 1] = {
                uid = plantUid,
                name = Private.OutcomeItemName(plantUid),
                products = StockPiler2.SeedMap.RefineProducts(plantUid),
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.name ~= b.name then
            return string.lower(a.name) < string.lower(b.name)
        end
        return (a.uid or 0) < (b.uid or 0)
    end)
    local header = "Refines (plant -> seed + extras): " .. tostring(#rows)
    Private.D("SeedMap dump " .. header)
    if StockPiler2.Print then
        StockPiler2.Print(towstring(header))
    end
    chatMax = tonumber(chatMax) or 30
    for i = 1, #rows do
        local row = rows[i]
        local line = row.name .. " (" .. tostring(row.uid) .. ") -> "
            .. Private.FormatOutcomeProducts(row.products)
        Private.D("SeedMap " .. line)
        if i <= chatMax and StockPiler2.Print then
            StockPiler2.Print(towstring(line))
        end
    end
    if #rows > chatMax and StockPiler2.Print then
        StockPiler2.Print(L"... " .. towstring(tostring(#rows - chatMax))
            .. L" more written to uilog.log")
    end
    return #rows
end

function StockPiler2.SeedMap.DumpCraftCycleStats(emit)
    emit = type(emit) == "function" and emit or function(msg)
        if StockPiler2.Debug and StockPiler2.Debug.Print then
            StockPiler2.Debug.Print(msg)
        elseif StockPiler2.D then
            StockPiler2.D(tostring(msg))
        end
    end
    emit("=== StockPiler2 craft-cycle stats ===")

    local grows = Private.AccountTable("grows")
    local growRows = {}
    for seedKey, bucket in pairs(grows) do
        if type(bucket) == "table" then
            local seedUid = tonumber(seedKey) or 0
            local attempts = tonumber(bucket.harvestAttempts) or 0
            local plants = tonumber(bucket.plantAttempts) or 0
            if attempts > 0 or plants > 0 then
                growRows[#growRows + 1] = {
                    seedUid = seedUid,
                    name = Private.OutcomeItemName(seedUid),
                    plantAttempts = plants,
                    harvestAttempts = attempts,
                    critOk = tonumber(bucket.chatCriticalSuccess) or 0,
                    critFail = tonumber(bucket.chatCriticalFailure) or 0,
                    sm = tonumber(bucket.specialMomentHits) or 0,
                    cultHits = tonumber(bucket.cultSkillHits) or 0,
                    survive = StockPiler2.SeedMap.HarvestSurviveRate(seedUid),
                    smRate = StockPiler2.SeedMap.SpecialMomentRate(seedUid),
                    cultRate = StockPiler2.SeedMap.CultSkillUpRate(seedUid),
                    yield = select(1, StockPiler2.SeedMap.ExpectedHarvestYield(seedUid, 0)),
                }
            end
        end
    end
    table.sort(growRows, function(a, b)
        if (a.harvestAttempts or 0) ~= (b.harvestAttempts or 0) then
            return (a.harvestAttempts or 0) > (b.harvestAttempts or 0)
        end
        return tostring(a.name) < tostring(b.name)
    end)
    emit("--- grows (seed) ---")
    if #growRows == 0 then
        emit("  (none with plant/harvest attempts)")
    end
    local growMax = math.min(#growRows, 40)
    for i = 1, growMax do
        local r = growRows[i]
        emit(string.format(
            "  %s uid=%d plant=%d harvest=%d survive=%.0f%% critOk=%d critFail=%d SM=%.0f%% cult=%.0f%% yield=%.2f",
            tostring(r.name),
            r.seedUid,
            r.plantAttempts,
            r.harvestAttempts,
            (r.survive or 1) * 100,
            r.critOk,
            r.critFail,
            (r.smRate or 0) * 100,
            (r.cultRate or 0) * 100,
            tonumber(r.yield) or 1
        ))
    end
    if #growRows > growMax then
        emit("  ... +" .. tostring(#growRows - growMax) .. " more")
    end

    local refines = Private.AccountTable("refines")
    local refineRows = {}
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            local plantUid = tonumber(plantKey) or 0
            local attempts = tonumber(entry.refineAttempts) or 0
            if attempts > 0 or (tonumber(entry.seedUid) or 0) > 0 then
                local seedAvg, seedSamples = StockPiler2.SeedMap.RefineSeedAvg(plantUid)
                refineRows[#refineRows + 1] = {
                    plantUid = plantUid,
                    name = Private.OutcomeItemName(plantUid),
                    attempts = attempts,
                    seedUid = tonumber(entry.seedUid) or 0,
                    seedAvg = seedAvg,
                    seedSamples = seedSamples,
                }
            end
        end
    end
    table.sort(refineRows, function(a, b)
        if (a.attempts or 0) ~= (b.attempts or 0) then
            return (a.attempts or 0) > (b.attempts or 0)
        end
        return tostring(a.name) < tostring(b.name)
    end)
    emit("--- refines (plant) ---")
    if #refineRows == 0 then
        emit("  (none)")
    end
    local refineMax = math.min(#refineRows, 40)
    for i = 1, refineMax do
        local r = refineRows[i]
        emit(string.format(
            "  %s uid=%d attempts=%d seedUid=%d seedAvg=%.2f (n=%d)",
            tostring(r.name),
            r.plantUid,
            r.attempts,
            r.seedUid,
            tonumber(r.seedAvg) or 0,
            tonumber(r.seedSamples) or 0
        ))
    end

    local RS = StockPiler2.RecipeSpec
    local recipes = Private.AccountTable("recipes")
    local brewRows = {}
    if type(recipes) == "table" then
        for key, recipe in pairs(recipes) do
            if type(recipe) == "table" then
                local attempts = tonumber(recipe.brewAttempts) or 0
                if attempts > 0 then
                    local rate = RS and RS.RecipeSuccessRate and RS.RecipeSuccessRate(recipe)
                    local apoRate = RS and RS.ApoSkillUpRate and RS.ApoSkillUpRate(recipe)
                    brewRows[#brewRows + 1] = {
                        key = tostring(key),
                        attempts = attempts,
                        ok = tonumber(recipe.brewSuccesses) or 0,
                        fail = tonumber(recipe.brewFailures) or 0,
                        crit = tonumber(recipe.brewCrits) or 0,
                        potent = tonumber(recipe.brewSuperCrits) or 0,
                        apoHits = tonumber(recipe.apoSkillHits) or 0,
                        rate = rate,
                        apoRate = apoRate,
                    }
                end
            end
        end
    end
    table.sort(brewRows, function(a, b)
        return (a.attempts or 0) > (b.attempts or 0)
    end)
    emit("--- brew (recipes) ---")
    if #brewRows == 0 then
        emit("  (none)")
    end
    local brewMax = math.min(#brewRows, 25)
    for i = 1, brewMax do
        local r = brewRows[i]
        emit(string.format(
            "  %s attempts=%d ok=%d fail=%d crit=%d potent=%d rate=%.0f%% apo=%.0f%%",
            r.key,
            r.attempts,
            r.ok,
            r.fail,
            r.crit,
            r.potent,
            (r.rate or 0) * 100,
            (r.apoRate or 0) * 100
        ))
    end
end

function StockPiler2.SeedMap.DumpToChat()
    local growN = Private.DumpGrowsToChat(25)
    local refineN = Private.DumpRefinesToChat(25)
    return growN + refineN
end

--- Prefer engine/bag type; skip Account AsItemData (often itemType=0 until relearned).
function Private.LiveItemType(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
        local _, sample = StockPiler2.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            local t = tonumber(sample.type) or tonumber(sample.itemType)
            if t ~= nil then
                return t
            end
        end
    end
    if GetDatabaseItemData ~= nil then
        local ok, data = StockPiler2.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return tonumber(data.type) or tonumber(data.itemType)
        end
    end
    return nil
end

--- Drop grow products that are not ItemTypes.CRAFTING (cleans Wilted Wild Weed, etc.).
function StockPiler2.SeedMap.PruneNonCraftingGrowProducts()
    local dropped = 0
    local grows = Private.AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            for plantKey, row in pairs(plants) do
                if type(row) == "table" then
                    local plantUid = tonumber(plantKey) or 0
                    local t = Private.LiveItemType(plantUid)
                    if t ~= nil and t ~= Private.CraftingItemType() then
                        plants[plantKey] = nil
                        dropped = dropped + 1
                        Private.D("SeedMap pruned non-crafting grow plantUid=" .. tostring(plantUid)
                            .. " seedUid=" .. tostring(seedKey)
                            .. " type=" .. tostring(t))
                    end
                end
            end
            if next(plants) == nil then
                grows[seedKey] = nil
            end
        end
    end
    return dropped
end

--- Remove harvest-trash leftovers that landed in Account.items (e.g. Wilted Wild Weed).
function StockPiler2.SeedMap.PruneNonCraftingItemOrphans()
    local dropped = 0
    if not (StockPiler2.Items and StockPiler2.Items.Get) then
        return 0
    end
    local items = Private.AccountTable("items")
    local remove = {}
    for uidKey, row in pairs(items) do
        if type(row) == "table" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            local t = Private.LiveItemType(uid)
            local cachedType = tonumber(row.itemType)
            local knownType = t
            if knownType == nil and cachedType ~= nil and cachedType > 0 then
                knownType = cachedType
            end
            -- Wilted-style trash: non-crafting, never a recipe/grow/refine actor.
            local name = string.lower(Private.ToNarrow(row.nameNarrow or row.name))
            local looksWilted = string.find(name, "wilted", 1, true) ~= nil
            if looksWilted or (knownType ~= nil and knownType ~= Private.CraftingItemType()
                and row.kind == "mat" and (tonumber(row.skillReq) or 0) == 0
                and (row.role == "container" or row.role == "ingredient"))
            then
                -- Don't drop real vials/containers used in recipes.
                local inRecipe = false
                local recipes = Private.AccountTable("recipes")
                for _, recipe in pairs(recipes) do
                    if type(recipe) == "table" and type(recipe.slots) == "table" then
                        for _, slot in pairs(recipe.slots) do
                            if type(slot) == "table" and (tonumber(slot.uid) or 0) == uid then
                                inRecipe = true
                                break
                            end
                        end
                    end
                    if inRecipe then
                        break
                    end
                end
                if not inRecipe then
                    remove[#remove + 1] = uidKey
                end
            end
        end
    end
    for i = 1, #remove do
        items[remove[i]] = nil
        dropped = dropped + 1
        Private.D("SeedMap pruned non-crafting item orphan uid=" .. tostring(remove[i]))
    end
    return dropped
end

function StockPiler2.SeedMap.PruneOrphanRefineByproducts()
    local refines = Private.AccountTable("refines")
    local pruned = 0
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" and type(entry.byproducts) == "table" then
            local plantUid = tonumber(plantKey) or 0
            local remove = {}
            for uidKey, row in pairs(entry.byproducts) do
                local uid = tonumber(uidKey) or 0
                if uid > 0 then
                    local samples = type(row) == "table" and (tonumber(row.samples) or 0) or 0
                    local countSum = type(row) == "table" and (tonumber(row.countSum) or 0) or 0
                    local isResin = Private.IsResinLikeItem(Private.LookupItemData(uid), uid)
                    local badPair = false
                    if not isResin and StockPiler2.SeedMap.PairLooksLikePlantAndSeed then
                        badPair = not StockPiler2.SeedMap.PairLooksLikePlantAndSeed(plantUid, uid)
                    end
                    -- Non-resin byproducts are never valid convert extras.
                    if not isResin or (samples <= 0 and countSum <= 0) or badPair == true then
                        remove[#remove + 1] = uidKey
                    end
                end
            end
            for i = 1, #remove do
                entry.byproducts[remove[i]] = nil
                pruned = pruned + 1
            end
        end
    end
    if pruned > 0 and StockPiler2.D then
        StockPiler2.D("SeedMap pruned orphan refine byproducts=" .. tostring(pruned))
    end
    return pruned
end

function StockPiler2.SeedMap.EnsureSpecBootstrap()
    StockPiler2.SeedMap._specBootstrapDone = true
    StockPiler2.SeedMap.PruneNonCraftingGrowProducts()
    StockPiler2.SeedMap.PruneNonCraftingItemOrphans()
    StockPiler2.SeedMap.PruneOrphanRefineByproducts()
    -- Drop mixed-harvest pairs (e.g. Gobswort Spore → Majestic Goldweed).
    StockPiler2.SeedMap.ForgetUnrelatedLearnedMaps()
    local acct = StockPiler2.Account
    if type(acct) == "table" and (tonumber(acct.accountVersion) or 1) < 2 then
        acct.accountVersion = 2
        Private.D("SeedMap accountVersion → 2 after pollution cleanup")
    end
    -- v3: clear sticky refineConvertFailed on proven plant→seed lines (false
    -- no-convert thrash blacklisted Gobswort/Goldweed and idled AutoGrow).
    if type(acct) == "table" and (tonumber(acct.accountVersion) or 1) < 3 then
        local cleared = 0
        local items = acct.items
        if type(items) == "table" then
            for key, row in pairs(items) do
                if type(row) == "table" and row.refineConvertFailed == true then
                    local uid = tonumber(row.uniqueID) or tonumber(key) or 0
                    if uid > 0 and Private.HasProvenSeedConvert(uid) then
                        Private.ClearStickyRefineConvertFailed(uid)
                        cleared = cleared + 1
                    end
                end
            end
        end
        acct.accountVersion = 3
        Private.D("SeedMap accountVersion → 3 cleared sticky refineConvertFailed="
            .. tostring(cleared))
    end
    return 0
end
