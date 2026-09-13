----------------------------------------------------------------
-- StockPiler2 SeedMap shared module support
----------------------------------------------------------------

StockPiler2.SeedMap = StockPiler2.SeedMap or {}
local SeedMap = StockPiler2.SeedMap
SeedMap._private = SeedMap._private or {}
local Private = SeedMap._private

----------------------------------------------------------------
-- StockPilerSeedMap - seed/spore resolution via plant/harvest/refine learning
----------------------------------------------------------------

StockPiler2.SeedMap = StockPiler2.SeedMap or {}

StockPiler2.SeedMap._pendingRefine = nil
StockPiler2.SeedMap._bagSeedIndexGen = -1
StockPiler2.SeedMap._bagSeedIndex = nil
-- Live seedUniqueID can be 0 by harvest time; remember last non-zero per plot.
StockPiler2.SeedMap._plotSeedByPlot = StockPiler2.SeedMap._plotSeedByPlot or {}
StockPiler2.SeedMap._planLinkCache = StockPiler2.SeedMap._planLinkCache or {}

--- Per Planner.Build caches (cleared via ClearPlanCaches).
function Private.PlanCacheGet(kind, key)
    local c = StockPiler2.SeedMap._planLinkCache
    if type(c) ~= "table" or key == nil or key == "" then
        return nil, false
    end
    local bucket = c[kind]
    if type(bucket) ~= "table" or bucket[key] == nil then
        return nil, false
    end
    return bucket[key], true
end

function Private.PlanCacheSet(kind, key, value)
    if key == nil or key == "" then
        return
    end
    local c = StockPiler2.SeedMap._planLinkCache
    if type(c) ~= "table" then
        c = {}
        StockPiler2.SeedMap._planLinkCache = c
    end
    local bucket = c[kind]
    if type(bucket) ~= "table" then
        bucket = {}
        c[kind] = bucket
    end
    bucket[key] = value
end

function StockPiler2.SeedMap.ClearPlanCaches()
    StockPiler2.SeedMap._planLinkCache = {}
end

Private.BUTCHER_HINTS = {
    "scale",
    "fragment",
    "hide",
    "claw",
    "fang",
    "horn",
    "bone",
    "gland",
    "organ",
    "blood",
    "ichor",
    "gore",
    "chitin",
    "tooth",
}

function Private.ToNarrow(text)
    return StockPiler2.ToNarrow(text)
end

function Private.LooksButchering(nameNarrow)
    local s = string.lower(nameNarrow or "")
    for i = 1, #Private.BUTCHER_HINTS do
        if string.find(s, Private.BUTCHER_HINTS[i], 1, true) then
            return true
        end
    end
    return false
end

function Private.ItemNameLooksLikeResin(itemData)
    local n = string.lower(Private.ToNarrow(itemData and (itemData.nameNarrow or itemData.name)))
    return n ~= "" and string.find(n, "resin", 1, true) ~= nil
end

--- Convert byproduct candidates: name resin, or already cached as resin kind.
function Private.IsResinLikeItem(itemData, uid)
    if Private.ItemNameLooksLikeResin(itemData) then
        return true
    end
    uid = tonumber(uid) or (type(itemData) == "table" and tonumber(itemData.uniqueID)) or 0
    if uid > 0 and StockPiler2.Items and StockPiler2.Items.Get then
        local row = StockPiler2.Items.Get(uid)
        if type(row) == "table" and row.kind == "resin" then
            return true
        end
    end
    return false
end

--- WAR Lua has no `os` library. GetGameTime is seconds.
function Private.NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

function Private.GetSettings()
    if StockPiler2.EnsureSettings then
        return StockPiler2.EnsureSettings()
    end
    if type(StockPiler2.Settings) ~= "table" then
        StockPiler2.Settings = {}
    end
    if StockPiler2.BindAccountIntoSettings then
        StockPiler2.BindAccountIntoSettings(StockPiler2.Settings)
    end
    return StockPiler2.Settings
end

--- Always the Account table for this key (same reference Settings aliases).
function Private.AccountTable(key)
    if StockPiler2.ClearAccountTable and type(StockPiler2.Account) == "table"
        and type(StockPiler2.Account[key]) ~= "table"
    then
        return StockPiler2.ClearAccountTable(key)
    end
    local a = StockPiler2.EnsureAccount and StockPiler2.EnsureAccount() or StockPiler2.Account
    if type(a) ~= "table" then
        a = {}
        StockPiler2.Account = a
    end
    if type(a[key]) ~= "table" then
        a[key] = {}
    end
    local s = Private.GetSettings()
    if type(s) == "table" then
        s[key] = a[key]
    end
    return a[key]
end

function Private.ClearAccountTable(key)
    if StockPiler2.ClearAccountTable then
        return StockPiler2.ClearAccountTable(key)
    end
    local tbl = Private.AccountTable(key)
    for k in pairs(tbl) do
        tbl[k] = nil
    end
    return tbl
end

function Private.RecordStat(bucket, uid, count, sampled)
    uid = tonumber(uid) or 0
    count = tonumber(count) or 0
    if uid <= 0 then
        return false
    end
    local key = tostring(uid)
    local row = bucket[key]
    if type(row) ~= "table" then
        row = { samples = 0, countSum = 0, last = 0 }
    end
    if sampled ~= false and count > 0 then
        row.samples = (tonumber(row.samples) or 0) + 1
        row.countSum = (tonumber(row.countSum) or 0) + count
        row.last = count
    elseif sampled == false then
        -- Known pair without a counted sample.
        row.last = tonumber(row.last) or 0
    end
    bucket[key] = row
    return true
end

function Private.CultivationSeedType()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes.SEED
    end
    return 1
end

function Private.CultivationSporeType()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes.SPORE
    end
    return 5
end

--- Bag/database item sample for code defined above LookupItemData.
function Private.BagItemSample(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
        local _, sample = StockPiler2.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            return sample
        end
    end
    if StockPiler2.Items and StockPiler2.Items.AsItemData then
        local cached = StockPiler2.Items.AsItemData(uid)
        if type(cached) == "table" then
            return cached
        end
    end
    if GetDatabaseItemData ~= nil then
        local ok, data = StockPiler2.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return data
        end
    end
    return nil
end

function Private.IsBagSeedOrSpore(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    return cultType == Private.CultivationSeedType() or cultType == Private.CultivationSporeType()
end

--- Vendor "Seed Packet" / "Spore Packet" consumables (buyable feedstock, like armor scales).
--- They grow the standard plant line; refine never yields the packet back.
function StockPiler2.SeedMap.IsSeedPacketItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local name = string.lower(Private.ToNarrow(itemData.name or itemData.nameNarrow))
    if name == "" then
        return false
    end
    return string.find(name, "seed packet", 1, true) ~= nil
        or string.find(name, "spore packet", 1, true) ~= nil
end

function StockPiler2.SeedMap.IsSeedPacketUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return false
    end
    return StockPiler2.SeedMap.IsSeedPacketItem(Private.BagItemSample(uid)) == true
end

--- Forward declaration; defined after GetPlantUidForSpec helpers as Private.SeedMatchesGrowSpec.

--- Soft cold-start aid for grow relatedness — not the seed-map source of truth.
--- Learned grows/refines uid pairs are authoritative once stored.
function Private.NormalizeGrowName(nameNarrow)
    local s = string.lower(nameNarrow or "")
    -- Charged/permanent liniment seed + Bunched harvest prefixes (patch notes / wiki).
    s = string.gsub(s, "^bunched%s+", "")
    s = string.gsub(s, "^eternal%s+", "")
    s = string.gsub(s, "^exceptional%s+", "")
    s = string.gsub(s, "%s+seed%s+packet$", "")
    s = string.gsub(s, "%s+spore%s+packet$", "")
    s = string.gsub(s, "%s+seed$", "")
    s = string.gsub(s, "%s+spore$", "")
    -- Compound forms: "Blackbell Bloodseed" (no space before seed).
    s = string.gsub(s, "seed$", "")
    s = string.gsub(s, "spore$", "")
    -- One-way harvest products: "Blackbell Powder" / remaining "blood" → blackbell.
    s = string.gsub(s, "%s+powder$", "")
    s = string.gsub(s, "%s+extract$", "")
    s = string.gsub(s, "%s+blood$", "")
    s = string.gsub(s, "%s+dust$", "")
    s = string.gsub(s, "%s+oil$", "")
    s = string.gsub(s, "%s+pulp$", "")
    s = string.gsub(s, "%s+", " ")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

-- Permanent purple (Eternal *) — Gunbad/Crypts/Bilerot; seed never consumed.
Private.ETERNAL_SEED_UID = {
    [199801] = true, -- Eternal Black Hellebore Seed
    [199802] = true, -- Eternal Crimson Monkshood Seed
    [199803] = true, -- Eternal Violetseal Seed
    [199804] = true, -- Eternal White Baneberry Seed
    [199805] = true, -- Eternal Azurethread Seed
    [199806] = true, -- Eternal Nightshade Seed
    [199809] = true, -- Eternal Black Serissa Seed
    [199810] = true, -- Eternal Red Serissa Seed
    [199811] = true, -- Eternal Pale Serissa Seed
    [199812] = true, -- Eternal Golden Serissa Seed
}

-- Charged purple (Exceptional * Bloodseed) — Bastion Stair; ~250 grows then spent.
Private.EXCEPTIONAL_SEED_UID = {
    [2018021] = true, -- Exceptional Dark Lily Bloodseed
    [2018022] = true, -- Exceptional Black Rose Bloodseed
    [2018023] = true, -- Exceptional Coal Aster Bloodseed
    [2018024] = true, -- Exceptional Blackbell Bloodseed
    [2018025] = true, -- Exceptional Brass Iris Bloodseed
    [2018026] = true, -- Exceptional Wiry Hellebore Bloodseed
}

function Private.SeedNameNarrow(seedUid, nameHint)
    local n = string.lower(Private.ToNarrow(nameHint))
    if n ~= "" then
        return n
    end
    -- LookupItemData is defined later; use BagItemSample (forwarded) when present.
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 or type(Private.BagItemSample) ~= "function" then
        return ""
    end
    local data = Private.BagItemSample(seedUid)
    return string.lower(Private.ToNarrow(data and data.name))
end

--- 3 = Eternal (infinite), 2 = Exceptional/charged, 1 = normal consumable seed.
function Private.SeedReplantTier(seedUid, nameHint)
    seedUid = tonumber(seedUid) or 0
    if seedUid > 0 and Private.ETERNAL_SEED_UID[seedUid] then
        return 3
    end
    if seedUid > 0 and Private.EXCEPTIONAL_SEED_UID[seedUid] then
        return 2
    end
    local n = Private.SeedNameNarrow(seedUid, nameHint)
    if n ~= "" then
        if string.find(n, "eternal ", 1, true) == 1 then
            return 3
        end
        if string.find(n, "exceptional ", 1, true) == 1 then
            return 2
        end
    end
    return 1
end

--- Bag stack stays while planting (Eternal forever; Exceptional until charges expire).
function Private.IsOpaqueReplantSeed(seedUid, nameHint)
    return Private.SeedReplantTier(seedUid, nameHint) >= 2
end

--- Credit for AutoGrow plantable math: opaque seeds plant a full plot wave while owned.
function StockPiler2.SeedMap.EffectiveSeedCredit(seedUid, bagCount)
    bagCount = tonumber(bagCount) or 0
    if bagCount <= 0 then
        return 0
    end
    if not Private.IsOpaqueReplantSeed(seedUid) then
        return bagCount
    end
    local plots = 4
    local CA = StockPiler2.CultivatorAdapter
    if CA and CA.NumPlots then
        plots = tonumber(CA.NumPlots()) or 4
    end
    if plots < 1 then
        plots = 4
    end
    if bagCount >= plots then
        return bagCount
    end
    return plots
end

function StockPiler2.SeedMap.IsEternalSeed(seedUid, nameHint)
    return Private.SeedReplantTier(seedUid, nameHint) >= 3
end

function StockPiler2.SeedMap.IsExceptionalSeed(seedUid, nameHint)
    return Private.SeedReplantTier(seedUid, nameHint) == 2
end

function StockPiler2.SeedMap.IsOpaqueReplantSeed(seedUid, nameHint)
    return Private.IsOpaqueReplantSeed(seedUid, nameHint)
end

function StockPiler2.SeedMap.SeedReplantTier(seedUid, nameHint)
    return Private.SeedReplantTier(seedUid, nameHint)
end

function Private.StripSimplePlural(nameNorm)
    if nameNorm == "" then
        return nameNorm
    end
    if string.match(nameNorm, "s$") and not string.match(nameNorm, "ss$") then
        local singular = string.sub(nameNorm, 1, -2)
        if singular ~= "" then
            return singular
        end
    end
    return nameNorm
end

function Private.GrowNameStemsMatch(a, b)
    if a == b then
        return true
    end
    if string.gsub(a, " ", "") == string.gsub(b, " ", "") then
        return true
    end
    local sa = Private.StripSimplePlural(a)
    local sb = Private.StripSimplePlural(b)
    if sa == sb or sa == b or a == sb then
        return true
    end
    return string.gsub(sa, " ", "") == string.gsub(sb, " ", "")
end

--- Harvested plant and its seed share a stem: "Glossy Spumepetal" / "Glossy Spumepetal Seed".
--- Also one-way: "Blackbell Powder" / "Blackbell Bloodseed" after product-type strip.
function StockPiler2.SeedMap.GrowNamesRelated(plantName, seedName)
    local a = Private.NormalizeGrowName(Private.ToNarrow(plantName))
    local b = Private.NormalizeGrowName(Private.ToNarrow(seedName))
    if a == "" or b == "" then
        return false
    end
    return Private.GrowNameStemsMatch(a, b)
end

--- Last token after NormalizeGrowName (e.g. "spumepetal", "parsley") — crit tiers / packets.
function Private.GrowNameGenusToken(nameNarrow)
    local n = Private.NormalizeGrowName(Private.ToNarrow(nameNarrow))
    if n == "" then
        return ""
    end
    local last = string.match(n, "([^%s]+)$")
    return last or n
end

function StockPiler2.SeedMap.GrowNamesGenusRelated(plantName, seedName)
    if StockPiler2.SeedMap.GrowNamesRelated(plantName, seedName) then
        return true
    end
    local a = Private.GrowNameGenusToken(plantName)
    local b = Private.GrowNameGenusToken(seedName)
    if a == "" or b == "" then
        return false
    end
    return a == b
end

function Private.HarvestNameMatchesItemName(harvestName, itemName)
    local a = Private.NormalizeGrowName(Private.ToNarrow(harvestName))
    local b = Private.NormalizeGrowName(Private.ToNarrow(itemName))
    if a == "" or b == "" then
        return false
    end
    return Private.GrowNameStemsMatch(a, b)
        or string.find(a, b, 1, true) ~= nil
        or string.find(b, a, 1, true) ~= nil
end

--- Name/genus relatedness only. ProductMatches on seeds falsely linked Ashberry→Energy mains.
--- One-way powders/bloodseeds match via NormalizeGrowName stem (Blackbell Powder / Bloodseed).
function Private.SeedPlantPairRelated(seedData, plantData)
    if type(seedData) ~= "table" or type(plantData) ~= "table" then
        return false
    end
    return StockPiler2.SeedMap.GrowNamesGenusRelated(plantData.name, seedData.name) == true
end

--- Engine seed list for a plant (CraftItemInfo only — not polluted grows).
function Private.EngineSeedUidsForPlant(plantUid)
    plantUid = tonumber(plantUid) or 0
    local list = {}
    if plantUid <= 0 then
        return list
    end
    if type(CraftItemInfo) == "table" and type(CraftItemInfo.GetSeedsToProduce) == "function" then
        local ok, raw
        if StockPiler2.TryCallQuiet then
            ok, raw = StockPiler2.TryCallQuiet(
                "CraftItemInfo.GetSeedsToProduce",
                CraftItemInfo.GetSeedsToProduce,
                plantUid
            )
        else
            ok, raw = pcall(CraftItemInfo.GetSeedsToProduce, plantUid)
        end
        if ok and type(raw) == "table" then
            for _, entry in pairs(raw) do
                local sid = tonumber(entry)
                if sid == nil and type(entry) == "table" then
                    sid = tonumber(entry.uniqueID) or tonumber(entry.id) or tonumber(entry.seedUid)
                end
                sid = tonumber(sid) or 0
                if sid > 0 then
                    list[#list + 1] = sid
                end
            end
        end
    end
    return list
end

function Private.EngineListsSeedForPlant(plantUid, seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local list = Private.EngineSeedUidsForPlant(plantUid)
    for i = 1, #list do
        if list[i] == seedUid then
            return true
        end
    end
    return false
end

--- True when plantUid may be recorded as a harvest product (not butcher/container noise).
--- One-way harvest (Blackbell Powder) passes via SeedPlantPairRelated / GrowNamesRelated.
function Private.IsEligibleHarvestProductUid(plantUid, seedUid)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    if plantUid <= 0 then
        return false
    end
    if StockPiler2.SeedMap.IsResinUid and StockPiler2.SeedMap.IsResinUid(plantUid) then
        return false
    end
    local plantData = Private.BagItemSample(plantUid)
    local nameNarrow = ""
    local isRefinable = false
    local ct = 0
    local role = ""
    if type(plantData) == "table" then
        nameNarrow = plantData.nameNarrow or Private.ToNarrow(plantData.name)
        isRefinable = plantData.isRefinable == true
        ct = tonumber(plantData.cultivationType) or 0
    end
    if StockPiler2.Items and StockPiler2.Items.Get then
        local row = StockPiler2.Items.Get(plantUid)
        if type(row) == "table" then
            if nameNarrow == "" then
                nameNarrow = row.nameNarrow or Private.ToNarrow(row.name)
            end
            if row.isRefinable == true then
                isRefinable = true
            end
            if ct == 0 then
                ct = tonumber(row.cultivationType) or 0
            end
            role = row.role or role
        end
    end
    if nameNarrow ~= "" and Private.LooksButchering(nameNarrow) then
        return false
    end
    if role == "container" then
        return false
    end
    local lower = string.lower(nameNarrow)
    if string.find(lower, "vial", 1, true) then
        return false
    end
    if ct == Private.CultivationSeedType() or ct == Private.CultivationSporeType() then
        return false
    end
    if isRefinable then
        return true
    end
    if ct ~= 0 then
        return true
    end
    if #Private.EngineSeedUidsForPlant(plantUid) > 0 then
        return true
    end
    local seedData = seedUid > 0 and Private.BagItemSample(seedUid) or nil
    if type(seedData) == "table" and type(plantData) == "table" then
        if Private.SeedPlantPairRelated(seedData, plantData) then
            return true
        end
        if StockPiler2.SeedMap.GrowNamesRelated(plantData.name, seedData.name) then
            return true
        end
    end
    return false
end

--- Safe to attribute plantUid as a harvest product of seedUid?
--- opts.expectedPlantUid / opts.chatPlantUids / opts.relatedToPlantUid / opts.allowExisting
--- opts.plotTrusted — plot-watched harvest: allow eligible plants without name match
---   (vendor packets → Musty/Swaying; also records Special Moment co-yields).
function Private.HarvestPairAllowed(seedUid, plantUid, opts)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    opts = type(opts) == "table" and opts or {}
    if seedUid <= 0 or plantUid <= 0 or plantUid == seedUid then
        return false
    end
    if not Private.IsEligibleHarvestProductUid(plantUid, seedUid) then
        return false
    end
    if opts.plotTrusted == true then
        return true
    end
    if plantUid == (tonumber(opts.expectedPlantUid) or 0) then
        return true
    end
    local chatUids = opts.chatPlantUids
    if type(chatUids) == "table" and chatUids[plantUid] == true then
        return true
    end
    if Private.EngineListsSeedForPlant(plantUid, seedUid) then
        return true
    end
    -- BagItemSample: LookupItemData is defined later (RoR local-order).
    local seedData = Private.BagItemSample(seedUid)
    local plantData = Private.BagItemSample(plantUid)
    if Private.SeedPlantPairRelated(seedData, plantData) then
        return true
    end
    local relatedUid = tonumber(opts.relatedToPlantUid) or 0
    if relatedUid > 0 and relatedUid ~= plantUid then
        local baseData = Private.BagItemSample(relatedUid)
        if type(baseData) == "table" and type(plantData) == "table"
            and StockPiler2.SeedMap.GrowNamesRelated(plantData.name, baseData.name)
        then
            return true
        end
    end
    -- Existing grows row alone is not enough (polluted pairs must not self-perpetuate).
    if opts.allowExisting == true then
        local grows = Private.AccountTable("grows")
        local bucket = grows[tostring(seedUid)]
        if type(bucket) == "table" and type(bucket[tostring(plantUid)]) == "table" then
            if Private.EngineListsSeedForPlant(plantUid, seedUid)
                or Private.SeedPlantPairRelated(seedData, plantData)
            then
                return true
            end
        end
    end
    return false
end

function Private.D(msg)
    if StockPiler2.D then
        StockPiler2.D(msg)
    end
end

--- CraftValueTip is no longer used; knowledge comes from planting/harvest/refine.
function StockPiler2.SeedMap.CvtAvailable()
    return false
end

function Private.AddUniqueUid(list, seen, uid)
    uid = tonumber(uid) or 0
    if uid > 0 and not seen[uid] then
        seen[uid] = true
        list[#list + 1] = uid
    end
end

function StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
    plantUid = tonumber(plantUid) or 0
    local uids = {}
    local seen = {}
    if plantUid <= 0 then
        return uids
    end

    -- Optional live API (not CraftValueTip); never persisted.
    if type(CraftItemInfo) == "table" and type(CraftItemInfo.GetSeedsToProduce) == "function" then
        local ok, list = StockPiler2.TryCallQuiet("CraftItemInfo.GetSeedsToProduce", CraftItemInfo.GetSeedsToProduce, plantUid)
        if ok and type(list) == "table" then
            for i = 1, #list do
                Private.AddUniqueUid(uids, seen, list[i])
            end
        end
    end

    local refines = Private.AccountTable("refines")
    local entry = refines[tostring(plantUid)]
    if type(entry) == "table" then
        local refineSeedUid = tonumber(entry.seedUid) or 0
        -- Never trust polluted refine.seedUid without relatedness / engine list.
        if refineSeedUid > 0 and Private.HarvestPairAllowed(refineSeedUid, plantUid, {}) then
            Private.AddUniqueUid(uids, seen, refineSeedUid)
        end
    end

    -- One-way harvest: grows[seedUid][plantUid] without a refine reverse link.
    local grows = Private.AccountTable("grows")
    local plantKey = tostring(plantUid)
    for seedKey, bucket in pairs(grows) do
        if type(bucket) == "table" and type(bucket[plantKey]) == "table" then
            local seedUid = tonumber(seedKey) or 0
            if seedUid > 0 and Private.HarvestPairAllowed(seedUid, plantUid, {}) then
                Private.AddUniqueUid(uids, seen, seedUid)
            end
        end
    end

    return uids
end

function StockPiler2.SeedMap.GetPlantUidForSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return 0
    end

    local harvested = StockPiler2.SeedMap.PrimaryPlantForSeed(seedUid)
    if harvested > 0 then
        return harvested
    end

    local refines = Private.AccountTable("refines")
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" and tonumber(entry.seedUid) == seedUid then
            local plantUid = tonumber(plantKey) or 0
            if plantUid > 0 and Private.HarvestPairAllowed(seedUid, plantUid, {}) then
                return plantUid
            end
        end
    end

    return 0
end

--- True when a bag seed grows a plant matching the recipe material spec (not seed==spec).
Private.SeedMatchesGrowSpec = function(seedItem, spec, expectedPlantUid)
    if type(seedItem) ~= "table" or type(spec) ~= "table" then
        return false, 0
    end
    local MS = StockPiler2.MaterialSpec
    if not MS or not MS.ProductMatches then
        return false, 0
    end
    expectedPlantUid = tonumber(expectedPlantUid) or 0
    if expectedPlantUid <= 0 then
        if StockPiler2.SeedMap.CachedPlantUidForSpec then
            expectedPlantUid = tonumber(StockPiler2.SeedMap.CachedPlantUidForSpec(spec)) or 0
        end
        if expectedPlantUid <= 0 and StockPiler2.SeedMap.FindPlantUidForSpec then
            expectedPlantUid = tonumber(StockPiler2.SeedMap.FindPlantUidForSpec(spec)) or 0
        end
    end
    local seedUid = tonumber(seedItem.uniqueID) or 0
    local function pairOk(plantUid)
        plantUid = tonumber(plantUid) or 0
        if plantUid <= 0 or seedUid <= 0 then
            return false
        end
        return Private.HarvestPairAllowed(seedUid, plantUid, {}) == true
            or Private.EngineListsSeedForPlant(plantUid, seedUid) == true
    end
    local plantUid = StockPiler2.SeedMap.GetPlantUidForSeed(seedUid)
    if plantUid > 0 then
        if not pairOk(plantUid) then
            -- Polluted primary mapping: ignore for match.
            plantUid = 0
        elseif expectedPlantUid > 0 and plantUid == expectedPlantUid then
            return true, plantUid
        else
            local plantData = Private.BagItemSample(plantUid)
            if type(plantData) == "table" and MS.ProductMatches(plantData, spec) then
                return true, plantUid
            end
            -- Learned Items fingerprint (AsItemData has no craftingBonus for ProductMatches).
            if StockPiler2.Items and StockPiler2.Items.ToSpec then
                local plantSpec = StockPiler2.Items.ToSpec(plantUid)
                if type(plantSpec) == "table" then
                    local a = (MS.ProductKey and MS.ProductKey(plantSpec)) or MS.Key(plantSpec)
                    local b = (MS.ProductKey and MS.ProductKey(spec)) or MS.Key(spec)
                    if a ~= "" and a == b then
                        return true, plantUid
                    end
                end
            end
            -- Mapped plant missing or wrong: Liniment seeds still ProductMatch the apo spec.
            if (type(plantData) ~= "table" or expectedPlantUid <= 0)
                and Private.IsBagSeedOrSpore(seedItem)
                and MS.ProductMatches(seedItem, spec) == true
            then
                return true, plantUid
            end
            return false, plantUid
        end
    end
    -- One-way / Liniment: bought seed ProductMatches recipe Main with no refinable plant uid.
    if seedUid > 0 and Private.IsBagSeedOrSpore(seedItem) and MS.ProductMatches(seedItem, spec) == true then
        return true, expectedPlantUid
    end
    if expectedPlantUid <= 0 or seedUid <= 0 then
        return false, 0
    end

    local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(expectedPlantUid)
    if type(seedUids) == "table" then
        for i = 1, #seedUids do
            if tonumber(seedUids[i]) == seedUid then
                return true, expectedPlantUid
            end
        end
    end

    -- Existing grows row alone is not enough (polluted pairs must not self-perpetuate).
    if pairOk(expectedPlantUid) then
        local grows = Private.AccountTable("grows")
        local bucket = grows[tostring(seedUid)]
        if type(bucket) == "table" and type(bucket[tostring(expectedPlantUid)]) == "table" then
            return true, expectedPlantUid
        end
    end

    local plantData = Private.BagItemSample(expectedPlantUid)
    if type(plantData) ~= "table" or MS.ProductMatches(plantData, spec) ~= true then
        return false, expectedPlantUid
    end
    if StockPiler2.SeedMap.PairLooksLikePlantAndSeed
        and StockPiler2.SeedMap.PairLooksLikePlantAndSeed(expectedPlantUid, seedUid) == true
    then
        return true, expectedPlantUid
    end
    return false, expectedPlantUid
end

--- @param trusted boolean|nil When true, allow count updates for existing grows pairs and
---   treat opts.expectedPlantUid as authoritative (chat / pending primary). Never blank-accept.
--- @param expectedPlantUid number|nil Optional expected plant from chat or pending harvest.
--- @param plotTrusted boolean|nil Plot-watched harvest: learn eligible plants without name match.
function StockPiler2.SeedMap.LearnMapping(plantUid, seedUid, source, trusted, expectedPlantUid, plotTrusted)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    trusted = trusted == true
    expectedPlantUid = tonumber(expectedPlantUid) or 0
    plotTrusted = plotTrusted == true
    if plantUid <= 0 or seedUid <= 0 then
        return false
    end

    if StockPiler2.SeedMap.IsResinUid and StockPiler2.SeedMap.IsResinUid(plantUid) then
        return false
    end
    -- Resin / incomplete resin stubs must never become grow seed buckets.
    local seedData = Private.BagItemSample(seedUid)
    if Private.IsResinLikeItem(seedData, seedUid) then
        return false
    end
    if not Private.HarvestPairAllowed(seedUid, plantUid, {
        expectedPlantUid = expectedPlantUid,
        relatedToPlantUid = expectedPlantUid,
        allowExisting = trusted,
        plotTrusted = plotTrusted,
    }) then
        if StockPiler2.SeedMap.PairLooksLikePlantAndSeed then
            StockPiler2.SeedMap.PairLooksLikePlantAndSeed(plantUid, seedUid)
        end
        return false
    end

    local already = false
    if source == "harvest" or source == "plant" then
        local grows = Private.AccountTable("grows")
        local bucket = grows[tostring(seedUid)]
        already = type(bucket) == "table" and type(bucket[tostring(plantUid)]) == "table"
        StockPiler2.SeedMap.NoteKnownHarvestPair(seedUid, plantUid, trusted, plotTrusted)
    else
        -- refine / learned: prefer refine pair when plant is refinable; else harvest-only.
        local plantData = Private.BagItemSample(plantUid)
        local refinable = type(plantData) == "table" and plantData.isRefinable == true
        if not refinable and StockPiler2.Items and StockPiler2.Items.Get then
            local row = StockPiler2.Items.Get(plantUid)
            if type(row) == "table" then
                refinable = row.isRefinable == true
            end
        end
        if refinable then
            local refines = Private.AccountTable("refines")
            local entry = refines[tostring(plantUid)]
            already = type(entry) == "table" and tonumber(entry.seedUid) == seedUid
            StockPiler2.SeedMap.NoteKnownRefinePair(plantUid, seedUid)
        else
            local grows = Private.AccountTable("grows")
            local bucket = grows[tostring(seedUid)]
            already = type(bucket) == "table" and type(bucket[tostring(plantUid)]) == "table"
            StockPiler2.SeedMap.NoteKnownHarvestPair(seedUid, plantUid, trusted, plotTrusted)
        end
    end

    if already then
        return false
    end
    if StockPiler2.NotifySeedLearned then
        StockPiler2.NotifySeedLearned(plantUid, seedUid, source)
    end
    if StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
        StockPiler2.Knowledge.Touch()
    end
    return true
end

function Private.ObservedMatRecord(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler2.Items and StockPiler2.Items.Get then
        return StockPiler2.Items.Get(uid)
    end
    return nil
end

function Private.LookupItemData(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
        local _, sample = StockPiler2.Inventory.CountByUniqueId(uid)
        if type(sample) == "table" then
            return sample
        end
    end
    local cached = nil
    if StockPiler2.Items and StockPiler2.Items.AsItemData then
        cached = StockPiler2.Items.AsItemData(uid)
    end
    -- Account rows often had itemType=0 before type was persisted from GameData.type.
    -- Prefer database when cache type is missing/NONE so CRAFTING checks stay accurate.
    local cachedType = type(cached) == "table"
        and (tonumber(cached.type) or tonumber(cached.itemType))
        or nil
    if GetDatabaseItemData ~= nil and (cached == nil or cachedType == nil or cachedType == 0) then
        local ok, data = StockPiler2.TryCallQuiet("GetDatabaseItemData", GetDatabaseItemData, uid)
        if ok and type(data) == "table" then
            return data
        end
    end
    if type(cached) == "table" then
        return cached
    end
    return nil
end

function Private.UpsertItem(itemData, kindHint)
    if type(itemData) ~= "table" or not (StockPiler2.Items and StockPiler2.Items.UpsertFromItemData) then
        return nil
    end
    return StockPiler2.Items.UpsertFromItemData(itemData, kindHint)
end

Private.rejectLogged = {}

function StockPiler2.SeedMap.PairLooksLikePlantAndSeed(plantUid, seedUid)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    if plantUid <= 0 or seedUid <= 0 then
        return false
    end
    local plantData = Private.LookupItemData(plantUid)
    local seedData = Private.LookupItemData(seedUid)
    if type(plantData) ~= "table" or type(seedData) ~= "table" then
        return false
    end
    -- Same relatedness as harvest learning (names or ProductMatches).
    if Private.SeedPlantPairRelated(seedData, plantData) then
        return true
    end
    local logKey = tostring(plantUid) .. ":" .. tostring(seedUid)
    if Private.rejectLogged[logKey] ~= true then
        Private.rejectLogged[logKey] = true
        Private.D("SeedMap reject unrelated plantUid=" .. tostring(plantUid)
            .. " seedUid=" .. tostring(seedUid)
            .. " plant=" .. Private.ToNarrow(plantData.name)
            .. " seed=" .. Private.ToNarrow(seedData.name))
    end
    return false
end

--- GameData.ItemTypes.CRAFTING = 34. Live bags use itemData.type; Account cache uses itemType.
--- Failed harvest trash (e.g. Wilted Wild Weed) is typically NONE (0), not CRAFTING.
function Private.CraftingItemType()
    if GameData and GameData.ItemTypes and GameData.ItemTypes.CRAFTING then
        return GameData.ItemTypes.CRAFTING
    end
    return 34
end

function Private.IsCraftingItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local t = tonumber(itemData.type) or tonumber(itemData.itemType)
    if t == nil then
        return false
    end
    return t == Private.CraftingItemType()
end

function Private.ProductKindForItem(itemData)
    if type(itemData) ~= "table" then
        return "other"
    end
    if Private.ItemNameLooksLikeResin(itemData) then
        return "resin"
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType == Private.CultivationSporeType() then
        return "spore"
    end
    if cultType == Private.CultivationSeedType() then
        return "seed"
    end
    local n = string.lower(Private.ToNarrow(itemData.name))
    if string.find(n, "spore", 1, true) then
        return "spore"
    end
    if string.find(n, "seed", 1, true) then
        return "seed"
    end
    return "plant"
end

function Private.OutcomeAvg(prod)
    if type(prod) ~= "table" then
        return 0
    end
    local samples = tonumber(prod.samples) or 0
    if samples > 0 then
        return (tonumber(prod.countSum) or 0) / samples
    end
    return tonumber(prod.last) or 0
end

function Private.EnsureGrowsBucket(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end
    local seedData = Private.BagItemSample(seedUid)
    if Private.IsResinLikeItem(seedData, seedUid) then
        return nil
    end
    local grows = Private.AccountTable("grows")
    local key = tostring(seedUid)
    local bucket = grows[key]
    if type(bucket) ~= "table" then
        bucket = {}
        grows[key] = bucket
    end
    return bucket
end

--- Read-only grows bucket (must be above CultSkillUpRate / harvest rate helpers).
function Private.GrowsBucketStats(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end
    local grows = Private.AccountTable("grows")
    local bucket = grows[tostring(seedUid)]
    if type(bucket) ~= "table" then
        return nil
    end
    return bucket
end

function Private.EnsureRefineEntry(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return nil
    end
    local refines = Private.AccountTable("refines")
    local key = tostring(plantUid)
    local entry = refines[key]
    if type(entry) ~= "table" then
        entry = { seedUid = 0, seedKind = "seed", byproducts = {} }
        refines[key] = entry
    end
    if type(entry.byproducts) ~= "table" then
        entry.byproducts = {}
    end
    return entry
end

function Private.StatRowToProduct(uid, kind, row)
    row = type(row) == "table" and row or {}
    return {
        uid = tonumber(uid) or 0,
        kind = kind or "other",
        samples = tonumber(row.samples) or 0,
        countSum = tonumber(row.countSum) or 0,
        last = tonumber(row.last) or 0,
    }
end

function Private.SortedProductList(list)
    table.sort(list, function(a, b)
        local ka = a.kind == "seed" or a.kind == "spore"
        local kb = b.kind == "seed" or b.kind == "spore"
        if ka ~= kb then
            return ka
        end
        if (a.kind or "") ~= (b.kind or "") then
            return tostring(a.kind) < tostring(b.kind)
        end
        return (tonumber(a.uid) or 0) < (tonumber(b.uid) or 0)
    end)
    return list
end

--- Seed/spore -> plants gained when that plot is harvested.
--- @param forceRelated boolean|nil When true, also allow count updates for pairs already in grows
---   (crit-tier). Never records arbitrary crafting mats from a co-timed bag pulse.
--- @param plotTrusted boolean|nil Plot-watched harvest: record eligible plants without name match.
function StockPiler2.SeedMap.ObserveMatFromRefine(plantUid, seedUid)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    local plantData = Private.LookupItemData(plantUid)
    if type(plantData) == "table" then
        Private.UpsertItem(plantData, "mat")
        StockPiler2.SeedMap.RegisterFromItem(plantData, seedUid)
    end
    local seedData = Private.LookupItemData(seedUid)
    if type(seedData) == "table" then
        local kind = Private.ProductKindForItem(seedData)
        Private.UpsertItem(seedData, (kind == "spore") and "spore" or "seed")
        StockPiler2.SeedMap.RegisterFromItem(seedData, plantUid)
    end
end

function StockPiler2.SeedMap.RegisterSpecLink(plantSpec, seedSpec, seedUid, plantUid, source)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    if plantUid > 0 and seedUid > 0 then
        return StockPiler2.SeedMap.LearnMapping(plantUid, seedUid, source)
    end
    return false
end

function StockPiler2.SeedMap.RegisterFromItem(itemData, linkedUid)
    if type(itemData) ~= "table" then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    local seedType = Private.CultivationSeedType()
    local sporeType = Private.CultivationSporeType()
    local uid = tonumber(itemData.uniqueID) or 0

    if cultType == seedType or cultType == sporeType then
        Private.UpsertItem(itemData, (cultType == sporeType) and "spore" or "seed")
        local plantUid = tonumber(linkedUid) or 0
        if plantUid > 0 and uid > 0 then
            return StockPiler2.SeedMap.LearnMapping(plantUid, uid, "learned")
        end
        return false
    end

    local spec = StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.FromItemData(itemData)
    local plantRole = type(spec) == "table" and (spec.role or "") or ""
    if itemData.isRefinable == true
        or plantRole == "main" or plantRole == "stabilizer" or plantRole == "goldweed"
        or plantRole == "extender" or plantRole == "multiplier" or plantRole == "stimulant"
    then
        Private.UpsertItem(itemData, "mat")
        local plantUid = uid
        local seedUid = tonumber(linkedUid) or 0
        if seedUid <= 0 and plantUid > 0 then
            local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
            seedUid = StockPiler2.SeedMap.PickBestSeedUid(plantUid, seedUids)
        end
        if seedUid > 0 and plantUid > 0 then
            local seedData = Private.LookupItemData(seedUid)
            if type(seedData) == "table" then
                local kind = Private.ProductKindForItem(seedData)
                Private.UpsertItem(seedData, (kind == "spore") and "spore" or "seed")
            end
            return StockPiler2.SeedMap.LearnMapping(plantUid, seedUid, "learned")
        end
        if (plantRole == "stabilizer" or plantRole == "goldweed")
            and itemData.isRefinable ~= true
            and type(spec) == "table"
        then
            StockPiler2.SeedMap.MaybeLearnHarvestByproduct(itemData, spec)
        end
    end
    return false
end

function StockPiler2.SeedMap.RegisterPlantUid(plantUid, source)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return false
    end
    local plantData = Private.LookupItemData(plantUid)
    if type(plantData) ~= "table" then
        return false
    end
    -- Do not create empty refine rows for butcher / non-cultivation recipe mats.
    if not Private.IsEligibleHarvestProductUid(plantUid, 0)
        and plantData.isRefinable ~= true
        and (tonumber(plantData.cultivationType) or 0) == 0
        and #Private.EngineSeedUidsForPlant(plantUid) == 0
    then
        Private.UpsertItem(plantData, "mat")
        return false
    end
    Private.EnsureRefineEntry(plantUid)
    local linkedUid = nil
    local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
    local seedUid = StockPiler2.SeedMap.PickBestSeedUid(plantUid, seedUids)
    if seedUid > 0 then
        linkedUid = seedUid
    end
    if StockPiler2.SeedMap.RegisterFromItem(plantData, linkedUid) then
        return true
    end
    return false
end
