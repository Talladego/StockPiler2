----------------------------------------------------------------
-- StockPiler2 SeedMap shared module support
----------------------------------------------------------------

StockPiler2.SeedMap = StockPiler2.SeedMap or {}
local SeedMap = StockPiler2.SeedMap
SeedMap._private = SeedMap._private or {}
local Private = SeedMap._private

function StockPiler2.SeedMap.PickBestSeedUid(plantUid, seedUids, spec)
    plantUid = tonumber(plantUid) or 0
    local MS = StockPiler2.MaterialSpec
    if not MS or not MS.ProductMatches then
        return 0
    end

    local matchSpec = type(spec) == "table" and spec or nil
    if matchSpec == nil and plantUid > 0 then
        if StockPiler2.Items and StockPiler2.Items.ToSpec then
            local plantSpec = StockPiler2.Items.ToSpec(plantUid)
            if type(plantSpec) == "table" and MS.AsApothecaryProduct then
                matchSpec = MS.AsApothecaryProduct(plantSpec, plantSpec.role)
            end
        end
        if matchSpec == nil and MS.AsApothecaryProduct then
            local plantData = Private.BagItemSample(plantUid)
            if type(plantData) == "table" then
                matchSpec = MS.AsApothecaryProduct(plantData, nil)
            end
        end
    end
    if matchSpec == nil then
        return 0
    end

    local seen = {}
    local candidates = {}
    local function addItem(item)
        if type(item) ~= "table" then
            return
        end
        local uid = tonumber(item.uniqueID) or 0
        if uid <= 0 or seen[uid] == true then
            return
        end
        if StockPiler2.SeedMap.IsSeedPacketUid(uid) then
            return
        end
        local count = 0
        if StockPiler2.Inventory and StockPiler2.Inventory.UniqueIdCount then
            count = StockPiler2.Inventory.UniqueIdCount(uid)
        end
        if count <= 0 then
            return
        end
        if not Private.SeedMatchesGrowSpec(item, matchSpec, plantUid) then
            return
        end
        seen[uid] = true
        candidates[#candidates + 1] = uid
    end

    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if Private.IsBagSeedOrSpore(item) then
                addItem(item)
            end
        end)
    end

    if type(seedUids) == "table" then
        for i = 1, #seedUids do
            local item = Private.BagItemSample(seedUids[i])
            if Private.IsBagSeedOrSpore(item) then
                addItem(item)
            end
        end
    end

    local bestUid = 0
    local bestScore = -1
    for i = 1, #candidates do
        local uid = candidates[i]
        local count = 0
        if StockPiler2.Inventory and StockPiler2.Inventory.UniqueIdCount then
            count = StockPiler2.Inventory.UniqueIdCount(uid)
        end
        -- Prefer Eternal ≫ Exceptional/charged ≫ normal; then stack size.
        local score = (Private.SeedReplantTier(uid) * 100000) + count
        if score > bestScore or (score == bestScore and (bestUid <= 0 or uid < bestUid)) then
            bestScore = score
            bestUid = uid
        end
    end
    return bestUid
end

function StockPiler2.SeedMap.PrimaryPlantForSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    local products = StockPiler2.SeedMap.HarvestProducts(seedUid)
    if #products == 0 then
        return 0
    end
    local seedData = seedUid > 0 and Private.LookupItemData(seedUid) or nil
    local bestRelatedUid = 0
    local bestRelatedSamples = -1
    for i = 1, #products do
        local plantUid = tonumber(products[i].uid) or 0
        if plantUid > 0 then
            local samples = tonumber(products[i].samples) or 0
            local plantData = Private.LookupItemData(plantUid)
            local related = false
            if type(seedData) == "table" and type(plantData) == "table" then
                related = StockPiler2.SeedMap.GrowNamesGenusRelated(plantData.name, seedData.name) == true
            elseif Private.EngineListsSeedForPlant(plantUid, seedUid) then
                related = true
            end
            -- Never return an unrelated product (polluted zero-sample rows used to win).
            -- Crit-tier genus matches (Spumepetal) still count as related.
            if related and samples > bestRelatedSamples then
                bestRelatedSamples = samples
                bestRelatedUid = plantUid
            end
        end
    end
    return bestRelatedUid
end

function Private.SeedKindFromItem(itemData, seedUid)
    local cultType = 0
    if type(itemData) == "table" then
        cultType = tonumber(itemData.cultivationType) or 0
    end
    if cultType == Private.CultivationSporeType() then
        return "spore", true
    end
    if cultType == Private.CultivationSeedType() then
        return "seed", false
    end
    local name = string.lower(Private.ToNarrow(itemData and itemData.name))
    if string.find(name, "spore", 1, true) then
        return "spore", true
    end
    return "seed", false
end

function Private.BuildSeedRecord(seedUid, source, plantUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end

    local count = 0
    local sample = nil
    if StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
        count, sample = StockPiler2.Inventory.CountByUniqueId(seedUid)
    end

    local itemData = sample
    if type(itemData) ~= "table" then
        itemData = Private.LookupItemData(seedUid)
    end

    local obs = Private.ObservedMatRecord(seedUid)
    local name = (type(sample) == "table" and sample.name)
        or (type(obs) == "table" and obs.name)
        or (type(itemData) == "table" and itemData.name)
    local nameNarrow = Private.ToNarrow(name)
    if nameNarrow == "" and type(obs) == "table" then
        nameNarrow = obs.nameNarrow or ""
    end
    if nameNarrow == "" and plantUid and plantUid > 0 then
        local plantData = Private.LookupItemData(plantUid)
        local plantName = Private.ToNarrow(plantData and plantData.name)
        if plantName ~= "" then
            local kind = Private.SeedKindFromItem(itemData, seedUid)
            nameNarrow = plantName .. (kind == "spore" and " Spore" or " Seed")
            name = towstring(nameNarrow)
        end
    end

    local kind, isSpore = Private.SeedKindFromItem(itemData or obs, seedUid)
    local iconNum = 0
    if type(sample) == "table" and tonumber(sample.iconNum) then
        iconNum = tonumber(sample.iconNum)
    elseif type(obs) == "table" then
        iconNum = tonumber(obs.iconNum) or 0
    elseif type(itemData) == "table" then
        iconNum = tonumber(itemData.iconNum) or 0
    end

    local asItem = itemData
    if type(asItem) ~= "table" and StockPiler2.Items and StockPiler2.Items.AsItemData then
        asItem = StockPiler2.Items.AsItemData(seedUid)
    end

    return {
        uniqueID = seedUid,
        plantUid = tonumber(plantUid) or 0,
        name = name or towstring(nameNarrow),
        nameNarrow = nameNarrow,
        match = nameNarrow,
        count = count,
        iconNum = iconNum,
        itemData = asItem,
        source = source or "unknown",
        seedKind = kind,
        isSpore = isSpore,
        reaps = false,
        replantTier = Private.SeedReplantTier(seedUid, nameNarrow),
        opaqueReplant = Private.IsOpaqueReplantSeed(seedUid, nameNarrow),
    }
end

function Private.FindObservedSeed(baseNameNarrow)
    baseNameNarrow = Private.NormalizeGrowName(baseNameNarrow)
    if baseNameNarrow == "" then
        return nil
    end
    local items = Private.AccountTable("items")
    local seedType = Private.CultivationSeedType()
    local sporeType = Private.CultivationSporeType()
    local best = nil
    for _, obs in pairs(items) do
        if type(obs) == "table" then
            local cultType = tonumber(obs.cultivationType) or 0
            local kind = obs.kind
            if cultType == seedType or cultType == sporeType
                or kind == "seed" or kind == "spore"
            then
                local obsBase = Private.NormalizeGrowName(obs.nameNarrow or Private.ToNarrow(obs.name))
                if obsBase == baseNameNarrow
                    or string.find(obsBase, baseNameNarrow, 1, true)
                    or string.find(baseNameNarrow, obsBase, 1, true)
                then
                    best = obs
                    if obsBase == baseNameNarrow then
                        return obs
                    end
                end
            end
        end
    end
    return best
end

function StockPiler2.SeedMap.IsGrowableMaterial(mat)
    if type(mat) ~= "table" then
        return false
    end
    if mat.role == "container" then
        return false
    end

    local nameNarrow = mat.nameNarrow or Private.ToNarrow(mat.name) or Private.ToNarrow(mat.match)
    if nameNarrow == "" then
        return false
    end
    if Private.LooksButchering(nameNarrow) then
        return false
    end

    local cultType = tonumber(mat.cultivationType) or 0
    if cultType == 0 and type(mat.itemData) == "table" then
        cultType = tonumber(mat.itemData.cultivationType) or 0
    end
    if cultType == Private.CultivationSeedType() or cultType == Private.CultivationSporeType() then
        return false
    end

    local plantUid = tonumber(mat.uniqueID) or 0
    if plantUid > 0 then
        local uids = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
        if #uids > 0 then
            return true
        end
    end

    if mat.isRefinable == true then
        return true
    end
    if type(mat.itemData) == "table" and mat.itemData.isRefinable == true then
        return true
    end
    if plantUid > 0 then
        local obs = Private.ObservedMatRecord(plantUid)
        if type(obs) == "table" and obs.isRefinable == true then
            return true
        end
        local itemData = Private.LookupItemData(plantUid)
        if type(itemData) == "table" and itemData.isRefinable == true then
            return true
        end
    end

    if mat.matKind == "cultivation" and plantUid > 0 then
        return true
    end

    -- Lasting/extra slots (stabilizer, extender, …) use the same plants as main mats.
    local lower = string.lower(nameNarrow)
    if string.find(lower, "goldweed", 1, true) then
        return true
    end
    if string.find(lower, "nettle", 1, true)
        or string.find(lower, "beardweed", 1, true)
        or string.find(lower, "gobswort", 1, true)
        or string.find(lower, "weed", 1, true)
        or string.find(lower, "fungus", 1, true)
        or string.find(lower, "leaf", 1, true)
    then
        return true
    end

    if mat.role == "main" then
        return not Private.LooksButchering(nameNarrow)
    end

    return false
end

function StockPiler2.SeedMap.ResolveSeedForMaterial(mat, catalogEntry)
    if type(mat) ~= "table" then
        return nil
    end

    local plantUid = tonumber(mat.uniqueID) or 0
    local useCatalogSeed = type(catalogEntry) == "table"
        and catalogEntry.seedMatch
        and catalogEntry.seedMatch ~= ""
        and (mat.role == "main" or mat.role == nil)

    local function resolveByMaterialName()
        local matName = mat.nameNarrow or Private.ToNarrow(mat.name) or Private.ToNarrow(mat.match)
        if matName == "" then
            return nil
        end

        local candidates = {
            matName .. " Spore",
            matName .. " Seed",
            matName,
        }
        for i = 1, #candidates do
            local match = candidates[i]
            if StockPiler2.Inventory and StockPiler2.Inventory.CountByName then
                local count, sample = StockPiler2.Inventory.CountByName(match)
                if count > 0 or sample ~= nil then
                    local record = Private.BuildSeedRecord(
                        type(sample) == "table" and sample.uniqueID or 0,
                        "name",
                        plantUid
                    )
                    if record == nil then
                        record = {
                            name = (type(sample) == "table" and sample.name) or towstring(match),
                            nameNarrow = match,
                            match = match,
                            uniqueID = type(sample) == "table" and sample.uniqueID or nil,
                            plantUid = plantUid,
                            count = count,
                            iconNum = type(sample) == "table" and (tonumber(sample.iconNum) or 0) or 0,
                            itemData = sample,
                            source = "name",
                            seedKind = string.find(string.lower(match), "spore", 1, true) and "spore" or "seed",
                            isSpore = string.find(string.lower(match), "spore", 1, true) ~= nil,
                        }
                    else
                        record.count = count
                        record.source = "name"
                    end
                    return record
                end
            end
        end

        local obs = Private.FindObservedSeed(matName)
        if obs then
            local seedUid = tonumber(obs.uniqueID) or 0
            local record = Private.BuildSeedRecord(seedUid, "observed", plantUid)
            if record and (record.count or 0) > 0 then
                return record
            end
        end

        local guessName = matName .. " Spore"
        if string.find(string.lower(matName), "seed", 1, true)
            or string.find(string.lower(matName), "spore", 1, true)
        then
            guessName = matName .. " Seed"
        end
        return {
            name = towstring(guessName),
            nameNarrow = guessName,
            match = guessName,
            plantUid = plantUid,
            count = 0,
            iconNum = 0,
            source = "guess",
            seedKind = string.find(string.lower(guessName), "spore", 1, true) and "spore" or "seed",
            isSpore = string.find(string.lower(guessName), "spore", 1, true) ~= nil,
        }
    end

    if useCatalogSeed then
        local seedMatch = catalogEntry.seedMatch
        local count = 0
        local sample = nil
        if StockPiler2.Inventory and StockPiler2.Inventory.CountByName then
            count, sample = StockPiler2.Inventory.CountByName(seedMatch)
        end
        if count > 0 or type(sample) == "table" then
            return {
                name = (type(sample) == "table" and sample.name) or towstring(seedMatch),
                nameNarrow = seedMatch,
                match = seedMatch,
                uniqueID = type(sample) == "table" and sample.uniqueID or nil,
                plantUid = plantUid,
                count = count,
                iconNum = type(sample) == "table" and (tonumber(sample.iconNum) or 0) or 0,
                itemData = sample,
                source = "catalog",
                seedKind = string.find(string.lower(seedMatch), "spore", 1, true) and "spore" or "seed",
                isSpore = string.find(string.lower(seedMatch), "spore", 1, true) ~= nil,
            }
        end
    end

    if plantUid > 0 then
        local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
        local seedUid = StockPiler2.SeedMap.PickBestSeedUid(plantUid, seedUids)
        if seedUid > 0 then
            local source = "learned"
            local refines = Private.AccountTable("refines")
            local entry = refines[tostring(plantUid)]
            if type(entry) == "table" and tonumber(entry.seedUid) == seedUid then
                source = "refine"
            end
            local record = Private.BuildSeedRecord(seedUid, source, plantUid)
            if type(record) == "table" then
                return record
            end
        end
    end

    return resolveByMaterialName()
end

function Private.InferSeedUidForPlantHarvest(plantUid, plantName)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return 0
    end
    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) == "table" then
        local sid = tonumber(pending.seedUid) or 0
        if sid > 0 then
            return sid
        end
        if type(pending.seedsByPlot) == "table" then
            for _, plotSid in pairs(pending.seedsByPlot) do
                plotSid = tonumber(plotSid) or 0
                if plotSid > 0 then
                    return plotSid
                end
            end
        end
    end

    local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
    for i = 1, #seedUids do
        local sid = tonumber(seedUids[i]) or 0
        if sid > 0 then
            return sid
        end
    end

    local plantData = Private.LookupItemData(plantUid)
    local label = plantName
    if (label == nil or label == "") and type(plantData) == "table" then
        label = plantData.name
    end
    local MS = StockPiler2.MaterialSpec
    local bestUid = 0
    local bestCount = -1
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if not Private.IsBagSeedOrSpore(item) then
                return
            end
            local uid = tonumber(item.uniqueID) or 0
            if uid <= 0 then
                return
            end
            local related = false
            if type(plantData) == "table" then
                related = Private.SeedPlantPairRelated(item, plantData)
            end
            if not related and label ~= nil and label ~= "" then
                related = StockPiler2.SeedMap.GrowNamesRelated(label, item.name) == true
            end
            if related then
                local count = 0
                if StockPiler2.Inventory.UniqueIdCount then
                    count = StockPiler2.Inventory.UniqueIdCount(uid)
                end
                if count > bestCount or (count == bestCount and (bestUid <= 0 or uid < bestUid)) then
                    bestCount = count
                    bestUid = uid
                end
            end
        end)
    end
    return bestUid
end

function StockPiler2.SeedMap.FindPlantUidByHarvestName(plantName)
    plantName = Private.ToNarrow(plantName)
    if plantName == "" then
        return 0
    end

    local items = Private.AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind ~= "seed" and row.kind ~= "spore" and row.kind ~= "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uid > 0 then
                local name = row.nameNarrow
                if name == nil and StockPiler2.Items and StockPiler2.Items.Get then
                    local cached = StockPiler2.Items.Get(uid)
                    if type(cached) == "table" then
                        name = cached.nameNarrow or cached.name
                    end
                end
                if Private.HarvestNameMatchesItemName(plantName, name) then
                    return uid
                end
            end
        end
    end

    local found = 0
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if found > 0 or type(item) ~= "table" then
                return
            end
            if item.isRefinable == true or Private.ProductKindForItem(item) == "plant" then
                if Private.HarvestNameMatchesItemName(plantName, item.name) then
                    found = tonumber(item.uniqueID) or 0
                end
            end
        end)
    end
    return found
end

--- Manual harvest fallback when bag-delta watch did not complete (Crafting chat line).

Private.GROW_REPAIR_ROLES = {
    main = true,
    stabilizer = true,
    goldweed = true,
    extender = true,
    multiplier = true,
    stimulant = true,
}

function Private.IsCultivatablePlantItem(item)
    if type(item) ~= "table" or Private.IsSeedOrSporeItem(item) then
        return false
    end
    if item.isRefinable == true then
        return true
    end
    -- Engine seed list only — do not use polluted grows (circular).
    local uid = tonumber(item.uniqueID) or 0
    if uid > 0 and #Private.EngineSeedUidsForPlant(uid) > 0 then
        return true
    end
    return false
end

--- Refinable plants, Liniment-style non-refinable harvest (ct set or brew-learned main),
--- or producers with a known seed map. Butcher mats (Armor Scales, Zoic Gore, Chitin, …) never
--- count as grow producers even when ProductMatches a cult plant or brew-learned main.
function Private.IsGrowProducerItemForSpec(item)
    if type(item) ~= "table" or Private.IsSeedOrSporeItem(item) then
        return false
    end
    local nameNarrow = item.nameNarrow or Private.ToNarrow(item.name)
    if nameNarrow ~= "" and Private.LooksButchering(nameNarrow) then
        return false
    end
    if Private.IsCultivatablePlantItem(item) then
        return true
    end
    local ct = tonumber(item.cultivationType) or 0
    if ct ~= 0 then
        return true
    end
    local uid = tonumber(item.uniqueID) or 0
    if uid > 0 then
        if #Private.EngineSeedUidsForPlant(uid) > 0 then
            return true
        end
        local mapped = StockPiler2.SeedMap.GetSeedUidsForPlant(uid)
        if type(mapped) == "table" and #mapped > 0 then
            return true
        end
        -- Brew-learned main fingerprint (Blackbell Powder / Primals): allow as plant uid;
        -- growability still requires a related seed in SeedMatchesGrowSpec.
        -- Butcher apo mains are excluded by LooksButchering above.
        if StockPiler2.Items and StockPiler2.Items.ToSpec then
            local learned = StockPiler2.Items.ToSpec(uid)
            if type(learned) == "table"
                and learned.incomplete ~= true
                and (learned.role == "main" or learned.role == nil)
                and (tonumber(learned.effectId) or 0) > 0
            then
                return true
            end
        end
    end
    return false
end

--- Cultivation evidence only (no brew-learned-only). Used by SpecLinked / SpecLooksButchering
--- so butcher recipe mats cannot stay growable via polluted grows rows.
function Private.IsCultivationLinkedProducer(item)
    if type(item) ~= "table" or Private.IsSeedOrSporeItem(item) then
        return false
    end
    local nameNarrow = item.nameNarrow or Private.ToNarrow(item.name)
    if nameNarrow ~= "" and Private.LooksButchering(nameNarrow) then
        return false
    end
    if Private.IsCultivatablePlantItem(item) then
        return true
    end
    local ct = tonumber(item.cultivationType) or 0
    if ct ~= 0 then
        return true
    end
    local uid = tonumber(item.uniqueID) or 0
    return uid > 0 and #Private.EngineSeedUidsForPlant(uid) > 0
end

function StockPiler2.SeedMap.FindPlantUidForSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return 0
    end
    local MS = StockPiler2.MaterialSpec
    local cacheKey = (MS.ProductKey and MS.ProductKey(spec)) or (MS.Key and MS.Key(spec)) or ""
    local cached, hit = Private.PlanCacheGet("plantUid", cacheKey)
    if hit then
        return tonumber(cached) or 0
    end
    local bestUid = 0

    -- Cheap paths first: grows/Items ProductKey (EFFECT-less bag plants fail ProductMatches).
    local fromCache = StockPiler2.SeedMap.CachedPlantUidForSpec and StockPiler2.SeedMap.CachedPlantUidForSpec(spec) or 0
    if fromCache > 0 then
        Private.PlanCacheSet("plantUid", cacheKey, fromCache)
        return fromCache
    end

    local function considerUid(uid, role)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return
        end
        local itemData = nil
        if StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
            local _, sample = StockPiler2.Inventory.CountByUniqueId(uid)
            itemData = sample
        end
        if type(itemData) ~= "table" then
            itemData = Private.LookupItemData(uid)
        end
        if type(itemData) == "table" then
            if MS.ProductMatches and MS.ProductMatches(itemData, spec) and Private.IsGrowProducerItemForSpec(itemData) then
                bestUid = uid
            end
            return
        end
        -- Thin GetDatabaseItemData has no craftingBonus. Trust the recipe UID
        -- when the learned slot role matches and this uid already has a seed map.
        if role ~= nil and role == spec.role then
            local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(uid)
            if type(seedUids) == "table" and #seedUids > 0 then
                bestUid = uid
            end
        end
    end

    local items = Private.AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind ~= "seed" and row.kind ~= "spore" and row.kind ~= "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uid > 0 then
                if StockPiler2.Items and StockPiler2.Items.ToSpec and MS.Key then
                    local itemSpec = StockPiler2.Items.ToSpec(uid)
                    local specKey = (MS.ProductKey and MS.ProductKey(spec)) or MS.Key(spec)
                    if type(itemSpec) == "table" then
                        local itemKey = (MS.ProductKey and MS.ProductKey(itemSpec)) or MS.Key(itemSpec)
                        if itemKey == specKey then
                            if Private.IsGrowProducerItemForSpec(StockPiler2.Items.AsItemData(uid) or row) then
                                bestUid = uid
                            end
                        elseif MS.ProductMatches then
                            local asItem = StockPiler2.Items.AsItemData(uid)
                            if type(asItem) == "table" and MS.ProductMatches(asItem, spec)
                                and Private.IsGrowProducerItemForSpec(asItem)
                            then
                                bestUid = uid
                            end
                        end
                    end
                else
                    considerUid(uid, row.role)
                end
            end
        end
    end
    if bestUid > 0 then
        Private.PlanCacheSet("plantUid", cacheKey, bestUid)
        return bestUid
    end

    local grows = Private.AccountTable("grows")
    for _, plants in pairs(grows) do
        if type(plants) == "table" then
            for plantKey, row in pairs(plants) do
                if type(row) == "table" then
                    considerUid(plantKey, nil)
                end
            end
        end
    end
    if bestUid > 0 then
        Private.PlanCacheSet("plantUid", cacheKey, bestUid)
        return bestUid
    end

    local recipes = Private.AccountTable("recipes")
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" and type(recipe.slots) == "table" then
            for i = 1, #recipe.slots do
                local slot = recipe.slots[i]
                if type(slot) == "table" then
                    considerUid(slot.uid, slot.role)
                end
            end
        end
    end
    if bestUid > 0 then
        Private.PlanCacheSet("plantUid", cacheKey, bestUid)
        return bestUid
    end

    -- Bag walk last: live refinable plant vs butcher substitute when learned data is empty.
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem and MS.ProductMatches then
        StockPiler2.Inventory.ForEachItem(function(item)
            if type(item) == "table" and MS.ProductMatches(item, spec) and Private.IsGrowProducerItemForSpec(item) then
                local uid = tonumber(item.uniqueID) or 0
                if uid > 0 then
                    bestUid = uid
                end
            end
        end)
    end
    Private.PlanCacheSet("plantUid", cacheKey, bestUid)
    return bestUid
end

--- Have/WarmHave only: Cached + Items ProductKey. Never bag-walks (see FindPlantUidForSpec).
function StockPiler2.SeedMap.FindPlantUidForHave(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return 0
    end
    local MS = StockPiler2.MaterialSpec
    if StockPiler2.SeedMap.CachedPlantUidForSpec then
        local cached = tonumber(StockPiler2.SeedMap.CachedPlantUidForSpec(spec)) or 0
        if cached > 0 then
            return cached
        end
    end
    local specKey = (MS.ProductKey and MS.ProductKey(spec)) or (MS.Key and MS.Key(spec)) or ""
    if specKey == "" or not StockPiler2.Items or not StockPiler2.Items.ToSpec then
        return 0
    end
    local items = Private.AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind ~= "seed" and row.kind ~= "spore" and row.kind ~= "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uid > 0 then
                local itemSpec = StockPiler2.Items.ToSpec(uid)
                if type(itemSpec) == "table" then
                    local itemKey = (MS.ProductKey and MS.ProductKey(itemSpec)) or MS.Key(itemSpec)
                    if itemKey == specKey
                        and Private.IsGrowProducerItemForSpec(StockPiler2.Items.AsItemData(uid) or row)
                    then
                        return uid
                    end
                end
            end
        end
    end
    return 0
end

function StockPiler2.SeedMap.ResolveSeedForPlantUid(plantUid, spec)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return nil
    end
    if type(spec) == "table" then
        local inBags = StockPiler2.SeedMap.FindSeedInBagsForPlantSpec(spec)
        if type(inBags) == "table" and (tonumber(inBags.count) or 0) > 0 then
            return inBags
        end
    end
    local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
    local seedUid = StockPiler2.SeedMap.PickBestSeedUid(plantUid, seedUids, spec)
    if seedUid <= 0 then
        return nil
    end
    local record = Private.BuildSeedRecord(seedUid, "plant", plantUid)
    if type(record) ~= "table" or (tonumber(record.count) or 0) <= 0 then
        return nil
    end
    StockPiler2.SeedMap.LearnMapping(plantUid, seedUid, "learned")
    return record
end

function StockPiler2.SeedMap.CachedPlantUidForSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return 0
    end
    local MS = StockPiler2.MaterialSpec
    local plantKey = (MS.ProductKey and MS.ProductKey(spec)) or MS.Key(spec)
    if plantKey == "" then
        return 0
    end

    local function uidMatches(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return false
        end
        if StockPiler2.Items and StockPiler2.Items.ToSpec then
            local itemSpec = StockPiler2.Items.ToSpec(uid)
            if type(itemSpec) == "table" then
                local itemKey = (MS.ProductKey and MS.ProductKey(itemSpec)) or MS.Key(itemSpec)
                if itemKey == plantKey then
                    return true
                end
            end
        end
        local itemData = Private.LookupItemData(uid)
        if type(itemData) == "table" and MS.ProductMatches and MS.ProductMatches(itemData, spec) then
            return true
        end
        return false
    end

    local grows = Private.AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            local seedUid = tonumber(seedKey) or 0
            for plantUidKey, row in pairs(plants) do
                if type(row) == "table" and uidMatches(plantUidKey) then
                    local plantUid = tonumber(plantUidKey) or 0
                    if seedUid > 0 and Private.HarvestPairAllowed(seedUid, plantUid, {}) then
                        return plantUid
                    end
                end
            end
        end
    end

    local items = Private.AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind ~= "seed" and row.kind ~= "spore" and row.kind ~= "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uidMatches(uid) then
                local asItem = (StockPiler2.Items and StockPiler2.Items.AsItemData and StockPiler2.Items.AsItemData(uid))
                    or Private.LookupItemData(uid)
                    or row
                -- Prefer cultivatable plants; butcher substitutes are not grow producers.
                if Private.IsCultivatablePlantItem(asItem) then
                    return uid
                end
            end
        end
    end

    local refines = Private.AccountTable("refines")
    for plantKeyUid, entry in pairs(refines) do
        if type(entry) == "table" and (tonumber(entry.seedUid) or 0) > 0 and uidMatches(plantKeyUid) then
            return tonumber(plantKeyUid) or 0
        end
    end

    local recipes = Private.AccountTable("recipes")
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" and type(recipe.slots) == "table" then
            for i = 1, #recipe.slots do
                local slot = recipe.slots[i]
                if type(slot) == "table" and uidMatches(slot.uid) then
                    return tonumber(slot.uid) or 0
                end
            end
        end
    end
    return 0
end

--- One snapshot pass of seed/spore stacks, reused for the current Inv.snapGen.
function StockPiler2.SeedMap.EnsureBagSeedIndex()
    local Inv = StockPiler2.Inventory
    local gen = Inv and Inv.GetSnapGen and Inv.GetSnapGen() or 0
    if StockPiler2.SeedMap._bagSeedIndexGen == gen
        and type(StockPiler2.SeedMap._bagSeedIndex) == "table"
    then
        return StockPiler2.SeedMap._bagSeedIndex
    end
    local list = {}
    if Inv and Inv.ForEachItem then
        Inv.ForEachItem(function(item)
            if type(item) == "table" and Private.IsSeedOrSporeItem(item) then
                list[#list + 1] = item
            end
        end)
    end
    StockPiler2.SeedMap._bagSeedIndex = list
    StockPiler2.SeedMap._bagSeedIndexGen = gen
    return list
end

--- Count bag seed stacks that grow a plant matching the recipe spec.
function StockPiler2.SeedMap.CountSeedsInBagsForSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return 0
    end
    if not Private.SeedMatchesGrowSpec then
        return 0
    end
    local expectedPlant = 0
    if StockPiler2.SeedMap.CachedPlantUidForSpec then
        expectedPlant = tonumber(StockPiler2.SeedMap.CachedPlantUidForSpec(spec)) or 0
    end
    if expectedPlant <= 0 and StockPiler2.SeedMap.FindPlantUidForSpec then
        expectedPlant = tonumber(StockPiler2.SeedMap.FindPlantUidForSpec(spec)) or 0
    end
    local total = 0
    local opaqueCredit = 0
    local index = StockPiler2.SeedMap.EnsureBagSeedIndex()
    for i = 1, #index do
        local item = index[i]
        if StockPiler2.Inventory.CanUseCraftingItem
            and not StockPiler2.Inventory.CanUseCraftingItem(item)
        then
            -- skip unusable
        elseif Private.SeedMatchesGrowSpec(item, spec, expectedPlant) then
            local stack = Private.ItemStackCount(item)
            local uid = tonumber(item.uniqueID) or 0
            if Private.IsOpaqueReplantSeed(uid, item.nameNarrow or item.name) then
                local credit = StockPiler2.SeedMap.EffectiveSeedCredit(uid, stack)
                if credit > opaqueCredit then
                    opaqueCredit = credit
                end
            else
                total = total + stack
            end
        end
    end
    return total + opaqueCredit
end

--- Prefer live bag stacks over a cached uniqueID that may be empty or stale.
function StockPiler2.SeedMap.FindSeedInBagsForPlantSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return nil
    end
    if not Private.SeedMatchesGrowSpec then
        return nil
    end

    local expectedPlant = 0
    if StockPiler2.SeedMap.CachedPlantUidForSpec then
        expectedPlant = tonumber(StockPiler2.SeedMap.CachedPlantUidForSpec(spec)) or 0
    end
    if expectedPlant <= 0 and StockPiler2.SeedMap.FindPlantUidForSpec then
        expectedPlant = tonumber(StockPiler2.SeedMap.FindPlantUidForSpec(spec)) or 0
    end

    local bestUid = 0
    local bestPlant = expectedPlant
    local bestScore = -1
    local index = StockPiler2.SeedMap.EnsureBagSeedIndex()
    for i = 1, #index do
        local item = index[i]
        local seedUid = tonumber(item.uniqueID) or 0
        if seedUid > 0 then
            local ok, plantUid = Private.SeedMatchesGrowSpec(item, spec, expectedPlant)
            if ok
                and (not StockPiler2.Inventory.CanUseCraftingItem
                    or StockPiler2.Inventory.CanUseCraftingItem(item))
            then
                local stack = Private.ItemStackCount(item)
                local score = (Private.SeedReplantTier(seedUid, item.nameNarrow or item.name) * 100000) + stack
                if score > bestScore or (score == bestScore and (bestUid <= 0 or seedUid < bestUid)) then
                    bestScore = score
                    bestUid = seedUid
                    bestPlant = (tonumber(plantUid) or 0) > 0 and plantUid or expectedPlant
                end
            end
        end
    end
    if bestUid <= 0 then
        return nil
    end
    return Private.BuildSeedRecord(bestUid, "bags", bestPlant)
end

function Private.SpecHasGoldweedMultiplier(spec)
    if type(spec) ~= "table" or type(spec.bonuses) ~= "table" then
        return false
    end
    local B = StockPiler2.Inventory and StockPiler2.Inventory.CraftBonus
    local ref = (B and B.MULTIPLIER) or 4
    local val = tonumber(spec.bonuses[ref])
    return val ~= nil and val ~= 0
end

--- True when a real grow producer matching this spec appears in grows/refines or bags.
--- ProductMatches alone is not enough: butcher substitutes share fingerprints with cult plants.
function Private.SpecLinkedToGrowOrRefine(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return false
    end
    local MS = StockPiler2.MaterialSpec
    local plantKey = (MS.ProductKey and MS.ProductKey(spec)) or MS.Key(spec)
    if plantKey == "" then
        return false
    end
    local cached, hit = Private.PlanCacheGet("linked", plantKey)
    if hit then
        return cached == true
    end

    local function itemForUid(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return nil
        end
        if StockPiler2.Items and StockPiler2.Items.AsItemData then
            local asItem = StockPiler2.Items.AsItemData(uid)
            if type(asItem) == "table" then
                return asItem
            end
        end
        return Private.LookupItemData(uid)
    end

    local function uidMatches(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return false
        end
        local itemData = itemForUid(uid)
        if type(itemData) ~= "table" then
            return false
        end
        local nameNarrow = itemData.nameNarrow or Private.ToNarrow(itemData.name)
        if nameNarrow ~= "" and Private.LooksButchering(nameNarrow) then
            return false
        end
        if not Private.IsCultivationLinkedProducer(itemData) then
            return false
        end
        if StockPiler2.Items and StockPiler2.Items.ToSpec then
            local itemSpec = StockPiler2.Items.ToSpec(uid)
            if type(itemSpec) == "table" then
                local itemKey = (MS.ProductKey and MS.ProductKey(itemSpec)) or MS.Key(itemSpec)
                if itemKey == plantKey then
                    return true
                end
            end
        end
        return MS.ProductMatches and MS.ProductMatches(itemData, spec) == true
    end

    local grows = Private.AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            for plantUidKey, row in pairs(plants) do
                if type(row) == "table" and uidMatches(plantUidKey) then
                    local plantUid = tonumber(plantUidKey) or 0
                    -- Stored grows uid pairs are authoritative; do not re-gate with
                    -- empty-opts HarvestPairAllowed (name gate ignored Bloodseed→Powder).
                    if plantUid > 0
                        and not (StockPiler2.SeedMap.IsResinUid
                            and StockPiler2.SeedMap.IsResinUid(plantUid))
                    then
                        Private.PlanCacheSet("linked", plantKey, true)
                        return true
                    end
                end
            end
        end
    end

    local refines = Private.AccountTable("refines")
    for plantUidKey, entry in pairs(refines) do
        if type(entry) == "table" and (tonumber(entry.seedUid) or 0) > 0 and uidMatches(plantUidKey) then
            Private.PlanCacheSet("linked", plantKey, true)
            return true
        end
    end

    -- Bag seeds only count when a real grow plant uid exists for this spec.
    local plantUid = 0
    if StockPiler2.SeedMap.FindPlantUidForSpec then
        plantUid = tonumber(StockPiler2.SeedMap.FindPlantUidForSpec(spec)) or 0
    end
    if plantUid > 0 and uidMatches(plantUid) and StockPiler2.SeedMap.FindSeedInBagsForPlantSpec then
        local bag = StockPiler2.SeedMap.FindSeedInBagsForPlantSpec(spec)
        if type(bag) == "table" and (tonumber(bag.count) or 0) > 0 then
            Private.PlanCacheSet("linked", plantKey, true)
            return true
        end
    end
    Private.PlanCacheSet("linked", plantKey, false)
    return false
end

--- Butcher-only product sample for this fingerprint (no cult plant among matches).
--- Recipe slots learned with Armor Scales / Zoic Gore / Chitin stay butcher even if a
--- ProductMatches cult plant exists elsewhere in Items/grows.
--- Goldweed in bags/account alongside Zoic keeps the shared stabilizer growable.
function Private.SpecLooksButchering(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return false
    end
    local MS = StockPiler2.MaterialSpec
    if not MS.ProductMatches then
        return false
    end
    local sawButcher = false
    local sawGrowPlant = false
    local recipeButcher = false
    local recipeGrow = false

    local function consider(item, fromRecipe)
        if type(item) ~= "table" or MS.ProductMatches(item, spec) ~= true then
            return
        end
        local nameNarrow = item.nameNarrow or Private.ToNarrow(item.name)
        if nameNarrow ~= "" and Private.LooksButchering(nameNarrow) then
            sawButcher = true
            if fromRecipe then
                recipeButcher = true
            end
            return
        end
        if Private.IsCultivationLinkedProducer(item) then
            sawGrowPlant = true
            if fromRecipe then
                recipeGrow = true
            end
        end
    end

    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            consider(item, false)
        end)
    end

    local items = Private.AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind ~= "seed" and row.kind ~= "spore" and row.kind ~= "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            local asItem = (StockPiler2.Items and StockPiler2.Items.AsItemData and StockPiler2.Items.AsItemData(uid))
                or Private.LookupItemData(uid)
                or row
            consider(asItem, false)
        end
    end

    local recipes = Private.AccountTable("recipes")
    local targetKey = (MS.ProductKey and MS.ProductKey(spec)) or (MS.Key and MS.Key(spec)) or ""
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" and type(recipe.slots) == "table" then
            for i = 1, #recipe.slots do
                local slot = recipe.slots[i]
                if type(slot) == "table" then
                    local uid = tonumber(slot.uid) or 0
                    local slotSpec = slot.spec
                    local keyMatch = false
                    if targetKey ~= "" and type(slotSpec) == "table" then
                        local slotKey = (MS.ProductKey and MS.ProductKey(slotSpec)) or (MS.Key and MS.Key(slotSpec)) or ""
                        keyMatch = slotKey == targetKey
                    end
                    if uid > 0 then
                        local asItem = (StockPiler2.Items and StockPiler2.Items.AsItemData and StockPiler2.Items.AsItemData(uid))
                            or Private.LookupItemData(uid)
                        if keyMatch and type(asItem) == "table" then
                            local nameNarrow = asItem.nameNarrow or Private.ToNarrow(asItem.name)
                            if nameNarrow ~= "" and Private.LooksButchering(nameNarrow) then
                                sawButcher = true
                                recipeButcher = true
                            elseif Private.IsGrowProducerItemForSpec(asItem) then
                                sawGrowPlant = true
                                recipeGrow = true
                            end
                        else
                            consider(asItem, true)
                        end
                    end
                end
            end
        end
    end

    if recipeButcher and not recipeGrow then
        return true
    end
    return sawButcher and not sawGrowPlant
end

function Private.SpecHasGrowProducer(spec)
    return Private.SpecLinkedToGrowOrRefine(spec)
end

function StockPiler2.SeedMap.MarkHarvestByproduct(spec, source, uniqueID)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return false
    end
    -- Goldweed (and butcher substitutes like Zoic Gore) share +stab/+multiplier.
    -- Resin convert extras do not.
    if Private.SpecHasGoldweedMultiplier(spec) or Private.SpecHasGrowProducer(spec) then
        return false
    end
    uniqueID = tonumber(uniqueID) or 0
    if uniqueID <= 0 then
        return false
    end
    local itemData = Private.LookupItemData(uniqueID)
    if type(itemData) == "table" then
        Private.UpsertItem(itemData, "resin")
    elseif StockPiler2.Items and StockPiler2.Items.Upsert then
        StockPiler2.Items.Upsert(uniqueID, { kind = "resin" })
    end
    Private.D("SeedMap harvest byproduct uid=" .. tostring(uniqueID)
        .. " source=" .. tostring(source or "learned"))
    return true
end

function StockPiler2.SeedMap.IsHarvestByproduct(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return false
    end
    local MS = StockPiler2.MaterialSpec
    local key = MS.Key(spec)
    if key == "" then
        return false
    end
    local cached, hit = Private.PlanCacheGet("byproduct", key)
    if hit then
        return cached == true
    end
    local function finish(result)
        Private.PlanCacheSet("byproduct", key, result == true)
        return result == true
    end
    if Private.SpecHasGoldweedMultiplier(spec) or Private.SpecHasGrowProducer(spec) then
        return finish(false)
    end

    local function uidMatchesSpec(uid)
        uid = tonumber(uid) or 0
        if uid <= 0 then
            return false
        end
        if StockPiler2.Items and StockPiler2.Items.ToSpec then
            local itemSpec = StockPiler2.Items.ToSpec(uid)
            if type(itemSpec) == "table" and MS.Key(itemSpec) == key then
                return true
            end
        end
        local itemData = Private.LookupItemData(uid)
        return type(itemData) == "table" and MS.Matches and MS.Matches(itemData, spec) == true
    end

    local items = Private.AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind == "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uidMatchesSpec(uid) then
                return finish(true)
            end
        end
    end

    local refines = Private.AccountTable("refines")
    for _, entry in pairs(refines) do
        if type(entry) == "table" and type(entry.byproducts) == "table" then
            for resinKey, _ in pairs(entry.byproducts) do
                if uidMatchesSpec(resinKey) then
                    return finish(true)
                end
            end
        end
    end
    return finish(false)
end

--- Seedless, non-refinable stabilizer seen on a learned recipe (no name matching).
--- Converting plants to seeds is the primary teacher (typically 1 plant → 1 seed + 1 resin);
--- this covers the item from a recipe before a convert is observed.
function StockPiler2.SeedMap.MaybeLearnHarvestByproduct(itemData, spec)
    if not StockPiler2.MaterialSpec then
        return false
    end
    if type(spec) ~= "table" and type(itemData) == "table" then
        spec = StockPiler2.MaterialSpec.FromItemData(itemData)
    end
    if type(spec) ~= "table" then
        return false
    end
    local role = spec.role or ""
    if role ~= "stabilizer" and role ~= "goldweed" then
        return false
    end
    if Private.SpecHasGoldweedMultiplier(spec) or Private.SpecHasGrowProducer(spec) then
        return false
    end
    if type(itemData) ~= "table" then
        local plantUid = StockPiler2.SeedMap.FindPlantUidForSpec(spec)
        if plantUid > 0 then
            if StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
                local _, sample = StockPiler2.Inventory.CountByUniqueId(plantUid)
                if type(sample) == "table" then
                    itemData = sample
                end
            end
            if type(itemData) ~= "table" then
                itemData = Private.LookupItemData(plantUid)
            end
        end
    end
    if type(itemData) ~= "table" then
        return false
    end
    if itemData.isRefinable == true then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType == Private.CultivationSeedType() or cultType == Private.CultivationSporeType() then
        return false
    end
    local uid = tonumber(itemData.uniqueID) or 0
    if uid > 0 then
        local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(uid)
        if #seedUids > 0 then
            return false
        end
    end
    -- Name-like resin, or treat seedless stabilizer as resin byproduct.
    if Private.ItemNameLooksLikeResin(itemData) or role == "stabilizer" then
        return StockPiler2.SeedMap.MarkHarvestByproduct(spec, "learned", uid)
    end
    return false
end

function StockPiler2.SeedMap.IsGrowableSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return false
    end
    local MS = StockPiler2.MaterialSpec
    local cacheKey = (MS.ProductKey and MS.ProductKey(spec)) or (MS.Key and MS.Key(spec)) or ""
    local cached, hit = Private.PlanCacheGet("growable", cacheKey)
    if hit then
        return cached == true
    end
    local role = spec.role or ""
    local result = false
    if role ~= "container"
        and not (StockPiler2.SeedMap.IsHarvestByproduct and StockPiler2.SeedMap.IsHarvestByproduct(spec))
        and not Private.SpecLooksButchering(spec)
    then
        result = Private.SpecLinkedToGrowOrRefine(spec) == true
    end
    Private.PlanCacheSet("growable", cacheKey, result)
    return result
end

--- Grow-linked mat with no plant→seed refine path (e.g. Blackbell Bloodseed → Powder).
function StockPiler2.SeedMap.IsOneWayHarvestSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return false
    end
    local MS = StockPiler2.MaterialSpec
    local cacheKey = (MS.ProductKey and MS.ProductKey(spec)) or (MS.Key and MS.Key(spec)) or ""
    local cached, hit = Private.PlanCacheGet("oneWay", cacheKey)
    if hit then
        return cached == true
    end

    local function finish(result)
        Private.PlanCacheSet("oneWay", cacheKey, result == true)
        return result == true
    end

    if StockPiler2.SeedMap.IsHarvestByproduct and StockPiler2.SeedMap.IsHarvestByproduct(spec) then
        return finish(false)
    end
    if not Private.SpecLinkedToGrowOrRefine(spec) then
        return finish(false)
    end
    local plantUid = 0
    if StockPiler2.SeedMap.FindPlantUidForSpec then
        plantUid = tonumber(StockPiler2.SeedMap.FindPlantUidForSpec(spec)) or 0
    end
    if plantUid <= 0 then
        return finish(false)
    end
    local refinable = false
    local plantData = Private.LookupItemData(plantUid)
    if type(plantData) == "table" and plantData.isRefinable == true then
        refinable = true
    elseif StockPiler2.Items and StockPiler2.Items.Get then
        local row = StockPiler2.Items.Get(plantUid)
        if type(row) == "table" and row.isRefinable == true then
            refinable = true
        end
    end
    local refines = Private.AccountTable("refines")
    local entry = refines[tostring(plantUid)]
    local hasRefineSeed = type(entry) == "table" and (tonumber(entry.seedUid) or 0) > 0
    if refinable or hasRefineSeed then
        return finish(false)
    end
    -- SpecLinked + non-refinable = one-way. Do not call ResolveSeedForSpec here
    -- (that recursed into bag scans / LearnMapping during every Planner.Build).
    return finish(true)
end

function StockPiler2.SeedMap.ResolveSeedForSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return nil
    end
    local MS = StockPiler2.MaterialSpec
    local cacheKey = ""
    if MS.ProductKey then
        cacheKey = tostring(MS.ProductKey(spec) or "")
    end
    if cacheKey == "" and MS.Key then
        cacheKey = tostring(MS.Key(spec) or "")
    end
    if cacheKey ~= "" then
        local cached, hit = Private.PlanCacheGet("resolveSeed", cacheKey)
        if hit then
            if cached == false then
                return nil
            end
            return cached
        end
    end

    local result = nil
    local inBags = StockPiler2.SeedMap.FindSeedInBagsForPlantSpec(spec)
    if type(inBags) == "table" and (tonumber(inBags.count) or 0) > 0 then
        result = inBags
    else
        local plantUid = 0
        if StockPiler2.SeedMap.FindPlantUidForSpec then
            plantUid = tonumber(StockPiler2.SeedMap.FindPlantUidForSpec(spec)) or 0
        end
        local seedUids = {}
        if plantUid > 0 then
            seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
        end
        if #seedUids == 0 then
            -- Walk grows for any product matching this spec when plantUid unknown.
            local grows = Private.AccountTable("grows")
            local seenPlant = {}
            local seenSeed = {}
            for seedKey, bucket in pairs(grows) do
                if type(bucket) == "table" then
                    local sUid = tonumber(seedKey) or 0
                    for plantKey, row in pairs(bucket) do
                        if type(row) == "table" then
                            local pUid = tonumber(plantKey) or 0
                            if pUid > 0 and sUid > 0 and not seenPlant[pUid]
                                and Private.HarvestPairAllowed(sUid, pUid, {})
                            then
                                local match = false
                                if StockPiler2.Items and StockPiler2.Items.ToSpec then
                                    local itemSpec = StockPiler2.Items.ToSpec(pUid)
                                    if type(itemSpec) == "table" then
                                        local a = (MS.ProductKey and MS.ProductKey(itemSpec)) or MS.Key(itemSpec)
                                        local b = (MS.ProductKey and MS.ProductKey(spec)) or MS.Key(spec)
                                        match = a ~= "" and a == b
                                    end
                                end
                                if not match then
                                    local itemData = Private.LookupItemData(pUid)
                                    match = type(itemData) == "table" and MS.ProductMatches
                                        and MS.ProductMatches(itemData, spec) == true
                                end
                                if match then
                                    seenPlant[pUid] = true
                                    plantUid = pUid
                                    Private.AddUniqueUid(seedUids, seenSeed, seedKey)
                                end
                            end
                        end
                    end
                end
            end
            if plantUid > 0 and #seedUids == 0 then
                seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
            end
        end
        for i = 1, #seedUids do
            local seedUid = tonumber(seedUids[i]) or 0
            if seedUid > 0 then
                local record = Private.BuildSeedRecord(seedUid, "account", plantUid)
                if type(record) == "table" then
                    result = record
                    break
                end
            end
        end
    end

    if cacheKey ~= "" then
        Private.PlanCacheSet("resolveSeed", cacheKey, result ~= nil and result or false)
    end
    return result
end

