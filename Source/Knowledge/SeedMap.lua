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
local function PlanCacheGet(kind, key)
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

local function PlanCacheSet(kind, key, value)
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

local BUTCHER_HINTS = {
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

local function ToNarrow(text)
    return StockPiler2.ToNarrow(text)
end

local function LooksButchering(nameNarrow)
    local s = string.lower(nameNarrow or "")
    for i = 1, #BUTCHER_HINTS do
        if string.find(s, BUTCHER_HINTS[i], 1, true) then
            return true
        end
    end
    return false
end

local function ItemNameLooksLikeResin(itemData)
    local n = string.lower(ToNarrow(itemData and (itemData.nameNarrow or itemData.name)))
    return n ~= "" and string.find(n, "resin", 1, true) ~= nil
end

--- Convert byproduct candidates: name resin, or already cached as resin kind.
local function IsResinLikeItem(itemData, uid)
    if ItemNameLooksLikeResin(itemData) then
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
local function NowSec()
    if type(GetGameTime) == "function" then
        return tonumber(GetGameTime()) or 0
    end
    return 0
end

local function GetSettings()
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
local function AccountTable(key)
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
    local s = GetSettings()
    if type(s) == "table" then
        s[key] = a[key]
    end
    return a[key]
end

local function ClearAccountTable(key)
    if StockPiler2.ClearAccountTable then
        return StockPiler2.ClearAccountTable(key)
    end
    local tbl = AccountTable(key)
    for k in pairs(tbl) do
        tbl[k] = nil
    end
    return tbl
end

local function RecordStat(bucket, uid, count, sampled)
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

local function CultivationSeedType()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes.SEED
    end
    return 1
end

local function CultivationSporeType()
    if GameData and GameData.CultivationTypes then
        return GameData.CultivationTypes.SPORE
    end
    return 5
end

--- Bag/database item sample for code defined above LookupItemData.
local function BagItemSample(uid)
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

local function IsBagSeedOrSpore(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    return cultType == CultivationSeedType() or cultType == CultivationSporeType()
end

--- Vendor "Seed Packet" / "Spore Packet" consumables (buyable feedstock, like armor scales).
--- They grow the standard plant line; refine never yields the packet back.
function StockPiler2.SeedMap.IsSeedPacketItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local name = string.lower(ToNarrow(itemData.name or itemData.nameNarrow))
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
    return StockPiler2.SeedMap.IsSeedPacketItem(BagItemSample(uid)) == true
end

--- Forward declaration; defined after GetPlantUidForSpec helpers.
local SeedMatchesGrowSpec

--- Soft cold-start aid for grow relatedness — not the seed-map source of truth.
--- Learned grows/refines uid pairs are authoritative once stored.
local function NormalizeGrowName(nameNarrow)
    local s = string.lower(nameNarrow or "")
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

local function StripSimplePlural(nameNorm)
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

local function GrowNameStemsMatch(a, b)
    if a == b then
        return true
    end
    if string.gsub(a, " ", "") == string.gsub(b, " ", "") then
        return true
    end
    local sa = StripSimplePlural(a)
    local sb = StripSimplePlural(b)
    if sa == sb or sa == b or a == sb then
        return true
    end
    return string.gsub(sa, " ", "") == string.gsub(sb, " ", "")
end

--- Harvested plant and its seed share a stem: "Glossy Spumepetal" / "Glossy Spumepetal Seed".
--- Also one-way: "Blackbell Powder" / "Blackbell Bloodseed" after product-type strip.
function StockPiler2.SeedMap.GrowNamesRelated(plantName, seedName)
    local a = NormalizeGrowName(ToNarrow(plantName))
    local b = NormalizeGrowName(ToNarrow(seedName))
    if a == "" or b == "" then
        return false
    end
    return GrowNameStemsMatch(a, b)
end

local function HarvestNameMatchesItemName(harvestName, itemName)
    local a = NormalizeGrowName(ToNarrow(harvestName))
    local b = NormalizeGrowName(ToNarrow(itemName))
    if a == "" or b == "" then
        return false
    end
    return GrowNameStemsMatch(a, b)
        or string.find(a, b, 1, true) ~= nil
        or string.find(b, a, 1, true) ~= nil
end

local function SeedPlantPairRelated(seedData, plantData)
    if type(seedData) ~= "table" or type(plantData) ~= "table" then
        return false
    end
    if StockPiler2.SeedMap.GrowNamesRelated(plantData.name, seedData.name) then
        return true
    end
    local MS = StockPiler2.MaterialSpec
    if MS and MS.ProductMatches and MS.AsApothecaryProduct then
        local plantProduct = MS.AsApothecaryProduct(plantData, nil)
        if type(plantProduct) == "table" and MS.ProductMatches(seedData, plantProduct) == true then
            return true
        end
    end
    return false
end

--- Engine seed list for a plant (CraftItemInfo only — not polluted grows).
local function EngineSeedUidsForPlant(plantUid)
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

local function EngineListsSeedForPlant(plantUid, seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local list = EngineSeedUidsForPlant(plantUid)
    for i = 1, #list do
        if list[i] == seedUid then
            return true
        end
    end
    return false
end

--- True when plantUid may be recorded as a harvest product (not butcher/container noise).
--- One-way harvest (Blackbell Powder) passes via SeedPlantPairRelated / GrowNamesRelated.
local function IsEligibleHarvestProductUid(plantUid, seedUid)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    if plantUid <= 0 then
        return false
    end
    if StockPiler2.SeedMap.IsResinUid and StockPiler2.SeedMap.IsResinUid(plantUid) then
        return false
    end
    local plantData = BagItemSample(plantUid)
    local nameNarrow = ""
    local isRefinable = false
    local ct = 0
    local role = ""
    if type(plantData) == "table" then
        nameNarrow = plantData.nameNarrow or ToNarrow(plantData.name)
        isRefinable = plantData.isRefinable == true
        ct = tonumber(plantData.cultivationType) or 0
    end
    if StockPiler2.Items and StockPiler2.Items.Get then
        local row = StockPiler2.Items.Get(plantUid)
        if type(row) == "table" then
            if nameNarrow == "" then
                nameNarrow = row.nameNarrow or ToNarrow(row.name)
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
    if nameNarrow ~= "" and LooksButchering(nameNarrow) then
        return false
    end
    if role == "container" then
        return false
    end
    local lower = string.lower(nameNarrow)
    if string.find(lower, "vial", 1, true) then
        return false
    end
    if ct == CultivationSeedType() or ct == CultivationSporeType() then
        return false
    end
    if isRefinable then
        return true
    end
    if ct ~= 0 then
        return true
    end
    if #EngineSeedUidsForPlant(plantUid) > 0 then
        return true
    end
    local seedData = seedUid > 0 and BagItemSample(seedUid) or nil
    if type(seedData) == "table" and type(plantData) == "table" then
        if SeedPlantPairRelated(seedData, plantData) then
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
local function HarvestPairAllowed(seedUid, plantUid, opts)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    opts = type(opts) == "table" and opts or {}
    if seedUid <= 0 or plantUid <= 0 or plantUid == seedUid then
        return false
    end
    if not IsEligibleHarvestProductUid(plantUid, seedUid) then
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
    if EngineListsSeedForPlant(plantUid, seedUid) then
        return true
    end
    -- BagItemSample: LookupItemData is defined later (RoR local-order).
    local seedData = BagItemSample(seedUid)
    local plantData = BagItemSample(plantUid)
    if SeedPlantPairRelated(seedData, plantData) then
        return true
    end
    local relatedUid = tonumber(opts.relatedToPlantUid) or 0
    if relatedUid > 0 and relatedUid ~= plantUid then
        local baseData = BagItemSample(relatedUid)
        if type(baseData) == "table" and type(plantData) == "table"
            and StockPiler2.SeedMap.GrowNamesRelated(plantData.name, baseData.name)
        then
            return true
        end
    end
    -- Existing grows row alone is not enough (polluted pairs must not self-perpetuate).
    if opts.allowExisting == true then
        local grows = AccountTable("grows")
        local bucket = grows[tostring(seedUid)]
        if type(bucket) == "table" and type(bucket[tostring(plantUid)]) == "table" then
            if EngineListsSeedForPlant(plantUid, seedUid)
                or SeedPlantPairRelated(seedData, plantData)
            then
                return true
            end
        end
    end
    return false
end

local function D(msg)
    if StockPiler2.D then
        StockPiler2.D(msg)
    end
end

--- CraftValueTip is no longer used; knowledge comes from planting/harvest/refine.
function StockPiler2.SeedMap.CvtAvailable()
    return false
end

local function AddUniqueUid(list, seen, uid)
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
                AddUniqueUid(uids, seen, list[i])
            end
        end
    end

    local refines = AccountTable("refines")
    local entry = refines[tostring(plantUid)]
    if type(entry) == "table" then
        local refineSeedUid = tonumber(entry.seedUid) or 0
        if refineSeedUid > 0 then
            AddUniqueUid(uids, seen, refineSeedUid)
        end
    end

    -- One-way harvest: grows[seedUid][plantUid] without a refine reverse link.
    local grows = AccountTable("grows")
    local plantKey = tostring(plantUid)
    for seedKey, bucket in pairs(grows) do
        if type(bucket) == "table" and type(bucket[plantKey]) == "table" then
            local seedUid = tonumber(seedKey) or 0
            if seedUid > 0 and HarvestPairAllowed(seedUid, plantUid, {}) then
                AddUniqueUid(uids, seen, seedUid)
            end
        end
    end

    return uids
end

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
            local plantData = BagItemSample(plantUid)
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
        if not SeedMatchesGrowSpec(item, matchSpec, plantUid) then
            return
        end
        seen[uid] = true
        candidates[#candidates + 1] = uid
    end

    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if IsBagSeedOrSpore(item) then
                addItem(item)
            end
        end)
    end

    if type(seedUids) == "table" then
        for i = 1, #seedUids do
            local item = BagItemSample(seedUids[i])
            if IsBagSeedOrSpore(item) then
                addItem(item)
            end
        end
    end

    local bestUid = 0
    local bestCount = -1
    for i = 1, #candidates do
        local uid = candidates[i]
        local count = 0
        if StockPiler2.Inventory and StockPiler2.Inventory.UniqueIdCount then
            count = StockPiler2.Inventory.UniqueIdCount(uid)
        end
        if count > bestCount or (count == bestCount and (bestUid <= 0 or uid < bestUid)) then
            bestCount = count
            bestUid = uid
        end
    end
    return bestUid
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

    local refines = AccountTable("refines")
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" and tonumber(entry.seedUid) == seedUid then
            local plantUid = tonumber(plantKey) or 0
            if plantUid > 0 then
                return plantUid
            end
        end
    end

    return 0
end

--- True when a bag seed grows a plant matching the recipe material spec (not seed==spec).
SeedMatchesGrowSpec = function(seedItem, spec, expectedPlantUid)
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
    local plantUid = StockPiler2.SeedMap.GetPlantUidForSeed(seedUid)
    if plantUid > 0 then
        if expectedPlantUid > 0 and plantUid == expectedPlantUid then
            return true, plantUid
        end
        local plantData = BagItemSample(plantUid)
        if type(plantData) == "table" and MS.ProductMatches(plantData, spec) then
            return true, plantUid
        end
        -- Mapped plant missing or wrong: Liniment seeds still ProductMatch the apo spec.
        if (type(plantData) ~= "table" or expectedPlantUid <= 0)
            and IsBagSeedOrSpore(seedItem)
            and MS.ProductMatches(seedItem, spec) == true
        then
            return true, plantUid
        end
        return false, plantUid
    end
    -- One-way / Liniment: bought seed ProductMatches recipe Main with no refinable plant uid.
    if seedUid > 0 and IsBagSeedOrSpore(seedItem) and MS.ProductMatches(seedItem, spec) == true then
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

    local grows = AccountTable("grows")
    local bucket = grows[tostring(seedUid)]
    if type(bucket) == "table" and type(bucket[tostring(expectedPlantUid)]) == "table" then
        return true, expectedPlantUid
    end

    local plantData = BagItemSample(expectedPlantUid)
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
    local seedData = BagItemSample(seedUid)
    if IsResinLikeItem(seedData, seedUid) then
        return false
    end
    if not HarvestPairAllowed(seedUid, plantUid, {
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
        local grows = AccountTable("grows")
        local bucket = grows[tostring(seedUid)]
        already = type(bucket) == "table" and type(bucket[tostring(plantUid)]) == "table"
        StockPiler2.SeedMap.NoteKnownHarvestPair(seedUid, plantUid, trusted, plotTrusted)
    else
        -- refine / learned: prefer refine pair when plant is refinable; else harvest-only.
        local plantData = BagItemSample(plantUid)
        local refinable = type(plantData) == "table" and plantData.isRefinable == true
        if not refinable and StockPiler2.Items and StockPiler2.Items.Get then
            local row = StockPiler2.Items.Get(plantUid)
            if type(row) == "table" then
                refinable = row.isRefinable == true
            end
        end
        if refinable then
            local refines = AccountTable("refines")
            local entry = refines[tostring(plantUid)]
            already = type(entry) == "table" and tonumber(entry.seedUid) == seedUid
            StockPiler2.SeedMap.NoteKnownRefinePair(plantUid, seedUid)
        else
            local grows = AccountTable("grows")
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

local function ObservedMatRecord(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return nil
    end
    if StockPiler2.Items and StockPiler2.Items.Get then
        return StockPiler2.Items.Get(uid)
    end
    return nil
end

local function LookupItemData(uid)
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

local function UpsertItem(itemData, kindHint)
    if type(itemData) ~= "table" or not (StockPiler2.Items and StockPiler2.Items.UpsertFromItemData) then
        return nil
    end
    return StockPiler2.Items.UpsertFromItemData(itemData, kindHint)
end

local rejectLogged = {}

function StockPiler2.SeedMap.PairLooksLikePlantAndSeed(plantUid, seedUid)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    if plantUid <= 0 or seedUid <= 0 then
        return false
    end
    local plantData = LookupItemData(plantUid)
    local seedData = LookupItemData(seedUid)
    if type(plantData) ~= "table" or type(seedData) ~= "table" then
        return false
    end
    -- Same relatedness as harvest learning (names or ProductMatches).
    if SeedPlantPairRelated(seedData, plantData) then
        return true
    end
    local logKey = tostring(plantUid) .. ":" .. tostring(seedUid)
    if rejectLogged[logKey] ~= true then
        rejectLogged[logKey] = true
        D("SeedMap reject unrelated plantUid=" .. tostring(plantUid)
            .. " seedUid=" .. tostring(seedUid)
            .. " plant=" .. ToNarrow(plantData.name)
            .. " seed=" .. ToNarrow(seedData.name))
    end
    return false
end

--- GameData.ItemTypes.CRAFTING = 34. Live bags use itemData.type; Account cache uses itemType.
--- Failed harvest trash (e.g. Wilted Wild Weed) is typically NONE (0), not CRAFTING.
local function CraftingItemType()
    if GameData and GameData.ItemTypes and GameData.ItemTypes.CRAFTING then
        return GameData.ItemTypes.CRAFTING
    end
    return 34
end

local function IsCraftingItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local t = tonumber(itemData.type) or tonumber(itemData.itemType)
    if t == nil then
        return false
    end
    return t == CraftingItemType()
end

local function ProductKindForItem(itemData)
    if type(itemData) ~= "table" then
        return "other"
    end
    if ItemNameLooksLikeResin(itemData) then
        return "resin"
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    if cultType == CultivationSporeType() then
        return "spore"
    end
    if cultType == CultivationSeedType() then
        return "seed"
    end
    local n = string.lower(ToNarrow(itemData.name))
    if string.find(n, "spore", 1, true) then
        return "spore"
    end
    if string.find(n, "seed", 1, true) then
        return "seed"
    end
    return "plant"
end

local function OutcomeAvg(prod)
    if type(prod) ~= "table" then
        return 0
    end
    local samples = tonumber(prod.samples) or 0
    if samples > 0 then
        return (tonumber(prod.countSum) or 0) / samples
    end
    return tonumber(prod.last) or 0
end

local function EnsureGrowsBucket(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end
    local seedData = BagItemSample(seedUid)
    if IsResinLikeItem(seedData, seedUid) then
        return nil
    end
    local grows = AccountTable("grows")
    local key = tostring(seedUid)
    local bucket = grows[key]
    if type(bucket) ~= "table" then
        bucket = {}
        grows[key] = bucket
    end
    return bucket
end

--- Read-only grows bucket (must be above CultSkillUpRate / harvest rate helpers).
local function GrowsBucketStats(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end
    local grows = AccountTable("grows")
    local bucket = grows[tostring(seedUid)]
    if type(bucket) ~= "table" then
        return nil
    end
    return bucket
end

local function EnsureRefineEntry(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return nil
    end
    local refines = AccountTable("refines")
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

local function StatRowToProduct(uid, kind, row)
    row = type(row) == "table" and row or {}
    return {
        uid = tonumber(uid) or 0,
        kind = kind or "other",
        samples = tonumber(row.samples) or 0,
        countSum = tonumber(row.countSum) or 0,
        last = tonumber(row.last) or 0,
    }
end

local function SortedProductList(list)
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
function StockPiler2.SeedMap.ObserveHarvest(seedUid, products, sampled, forceRelated, expectedPlantUid, plotTrusted)
    seedUid = tonumber(seedUid) or 0
    forceRelated = forceRelated == true
    expectedPlantUid = tonumber(expectedPlantUid) or 0
    plotTrusted = plotTrusted == true
    if seedUid <= 0 or type(products) ~= "table" then
        return false
    end
    local bucket = EnsureGrowsBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    local seedData = LookupItemData(seedUid)
    if type(seedData) == "table" then
        local kind = ProductKindForItem(seedData)
        UpsertItem(seedData, (kind == "spore") and "spore" or "seed")
    end
    local changed = false
    for uid, count in pairs(products) do
        uid = tonumber(uid) or 0
        count = tonumber(count) or 0
        if uid > 0 and uid ~= seedUid and not StockPiler2.SeedMap.IsResinUid(uid) then
            local item = LookupItemData(uid)
            if not IsCraftingItem(item) then
                -- Ignore harvest trash (Wilted Wild Weed, etc.).
            else
                local kind = ProductKindForItem(item)
                if kind ~= "seed" and kind ~= "spore" and kind ~= "resin" then
                    if not HarvestPairAllowed(seedUid, uid, {
                        expectedPlantUid = expectedPlantUid,
                        relatedToPlantUid = expectedPlantUid,
                        allowExisting = forceRelated,
                        plotTrusted = plotTrusted,
                    }) then
                        D("SeedMap ObserveHarvest skip unrelated plantUid=" .. tostring(uid)
                            .. " seedUid=" .. tostring(seedUid)
                            .. " plant=" .. ToNarrow(item and item.name)
                            .. " seed=" .. ToNarrow(seedData and seedData.name))
                    elseif RecordStat(bucket, uid, count, sampled ~= false) then
                        changed = true
                        if type(item) == "table" then
                            UpsertItem(item, "mat")
                        end
                    end
                end
            end
        end
    end
    return changed
end

--- Record Crafting-chat Critical Success / Failure / Special Moment against a seed grow bucket.
--- Does not change AutoGrow; used for seed-buffer / leveling insight.
--- Returns critOk, critFail, specialMoment.
function StockPiler2.SeedMap.RecordHarvestChatCues(seedUid, cues, pending)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false, false, false
    end
    local bucket = EnsureGrowsBucket(seedUid)
    if type(bucket) ~= "table" then
        return false, false, false
    end
    bucket.harvestAttempts = (tonumber(bucket.harvestAttempts) or 0) + 1
    StockPiler2.SeedMap.ArmCultSkillPending(seedUid, "harvest")
    local critOk = false
    local critFail = false
    local specialMoment = false
    if type(pending) == "table" then
        critOk = pending.chatCriticalSuccess == true
        critFail = pending.chatCriticalFailure == true
        specialMoment = pending.chatSpecialMoment == true
    end
    if type(cues) == "table" then
        if cues.criticalSuccess == true then
            critOk = true
        end
        if cues.criticalFailure == true then
            critFail = true
        end
        if cues.specialMoment == true then
            specialMoment = true
        end
    end
    if critOk then
        bucket.chatCriticalSuccess = (tonumber(bucket.chatCriticalSuccess) or 0) + 1
    end
    if critFail then
        bucket.chatCriticalFailure = (tonumber(bucket.chatCriticalFailure) or 0) + 1
    end
    if specialMoment then
        bucket.specialMomentHits = (tonumber(bucket.specialMomentHits) or 0) + 1
    end
    D("SeedMap harvest chat seedUid=" .. tostring(seedUid)
        .. " attempts=" .. tostring(bucket.harvestAttempts)
        .. " critOk=" .. tostring(critOk)
        .. " critFail=" .. tostring(critFail)
        .. " specialMoment=" .. tostring(specialMoment))
    return critOk, critFail, specialMoment
end

--- Count a Special Moment once when chat missed but a non-primary plant was gained.
function StockPiler2.SeedMap.NoteSpecialMomentHit(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local bucket = EnsureGrowsBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    bucket.specialMomentHits = (tonumber(bucket.specialMomentHits) or 0) + 1
    return true
end

function StockPiler2.SeedMap.NotePlantAttempt(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local bucket = EnsureGrowsBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    bucket.plantAttempts = (tonumber(bucket.plantAttempts) or 0) + 1
    return true
end

local SKILL_PENDING_TTL_SEC = 8
local SKILL_RATE_MIN_ATTEMPTS = 5

--- Arm Cult skill-up attribution for the next TRADE_SKILL_UPDATED (+Cult).
function StockPiler2.SeedMap.ArmCultSkillPending(seedUid, reason)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local now = NowSec()
    StockPiler2.SeedMap._pendingCultSkill = {
        seedUid = seedUid,
        reason = tostring(reason or "arm"),
        untilTime = now + SKILL_PENDING_TTL_SEC,
    }
    return true
end

--- Flowering complete: arm each planted plot's seed (Cult skill often fires here).
function StockPiler2.SeedMap.ArmCultSkillPendingFromPlots(reason)
    local CA = StockPiler2.CultivatorAdapter
    local n = CA and CA.NumPlots and CA.NumPlots() or 4
    local armed = 0
    local lastUid = 0
    for plotNum = 1, n do
        local plot = CA and CA.ReadPlot and CA.ReadPlot(plotNum) or nil
        if type(plot) ~= "table" and StockPiler2.Grow and StockPiler2.Grow.CachedPlot then
            plot = StockPiler2.Grow.CachedPlot(plotNum)
        end
        local seedUid = 0
        if type(plot) == "table" then
            seedUid = tonumber(plot.seedUid) or 0
            if seedUid <= 0 and type(plot.seed) == "table" then
                seedUid = tonumber(plot.seed.uniqueID) or 0
            end
        end
        if seedUid > 0 then
            lastUid = seedUid
            armed = armed + 1
        end
    end
    if lastUid > 0 then
        -- Prefer a single pending seed (last non-empty plot); multi-plot ambiguity is rare.
        StockPiler2.SeedMap.ArmCultSkillPending(lastUid, reason or "flowering")
    end
    return armed > 0
end

function StockPiler2.SeedMap.NoteCultSkillHit(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local bucket = EnsureGrowsBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    bucket.cultSkillHits = (tonumber(bucket.cultSkillHits) or 0) + 1
    return true
end

--- Empirical Cult +1 rate per harvest attempt. nil rate if too few samples.
function StockPiler2.SeedMap.CultSkillUpRate(seedUid)
    local bucket = GrowsBucketStats(seedUid)
    if type(bucket) ~= "table" then
        return nil
    end
    local attempts = tonumber(bucket.harvestAttempts) or 0
    local hits = tonumber(bucket.cultSkillHits) or 0
    if attempts < SKILL_RATE_MIN_ATTEMPTS then
        return nil, hits, attempts
    end
    return hits / attempts, hits, attempts
end

function StockPiler2.SeedMap.FormatCultSkillUpLine(seedUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end
    local Caps = StockPiler2.TradeSkillCaps
    local level = Caps and Caps.CultivationLevel and Caps.CultivationLevel() or 0
    if level <= 0 or level >= 200 then
        return nil
    end
    local rate, hits, attempts = StockPiler2.SeedMap.CultSkillUpRate(seedUid)
    if rate == nil then
        return nil
    end
    return string.format(
        "Cult skill-up ~%.0f%% (n=%d)",
        rate * 100,
        attempts
    )
end

--- Consume pending Cult arm if TRADE_SKILL reported a small positive Cult delta.
function StockPiler2.SeedMap.OnCultSkillDelta(deltaCult)
    deltaCult = tonumber(deltaCult) or 0
    if deltaCult <= 0 or deltaCult > 3 then
        return false
    end
    local pending = StockPiler2.SeedMap._pendingCultSkill
    if type(pending) ~= "table" then
        return false
    end
    local now = NowSec()
    if (tonumber(pending.untilTime) or 0) < now then
        StockPiler2.SeedMap._pendingCultSkill = nil
        return false
    end
    local seedUid = tonumber(pending.seedUid) or 0
    StockPiler2.SeedMap._pendingCultSkill = nil
    if seedUid <= 0 then
        return false
    end
    return StockPiler2.SeedMap.NoteCultSkillHit(seedUid)
end

--- Critical Failure with no bag gain: clear locked harvest watch and record seed lost.
function StockPiler2.SeedMap.CompletePendingHarvestFromChat(cues)
    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) ~= "table" or pending.locked ~= true then
        return false
    end
    local seedUid = tonumber(pending.seedUid) or 0
    local plotNum = tonumber(pending.plotNum) or 0
    local _, critFail = StockPiler2.SeedMap.RecordHarvestChatCues(seedUid, cues, pending)
    StockPiler2.SeedMap._pendingHarvest = nil
    if StockPiler2.CraftChat and StockPiler2.CraftChat.TakeCues then
        StockPiler2.CraftChat.TakeCues()
    end
    if StockPiler2.LogOp then
        StockPiler2.LogOp("harvest", string.format(
            "fail P%d seedUid=%d critFail=%s reason=Critical Failure",
            plotNum,
            seedUid,
            tostring(critFail == true)
        ))
    end
    if StockPiler2.AutoGrow and StockPiler2.AutoGrow.MaybeNotifySeedLineLost then
        StockPiler2.AutoGrow.MaybeNotifySeedLineLost(seedUid, "critical_failure", plotNum)
    end
    if StockPiler2.Grow and StockPiler2.Grow.NotifyHarvestOutcome then
        StockPiler2.Grow.NotifyHarvestOutcome(plotNum, { critFail = true })
    end
    return true
end

--- Plant convert -> seed/spore plus extras (Arboreal Resin is expected on every convert).
function StockPiler2.SeedMap.ObserveRefine(plantUid, products, sampled)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 or type(products) ~= "table" then
        return false
    end
    local entry = EnsureRefineEntry(plantUid)
    if type(entry) ~= "table" then
        return false
    end
    entry.refineAttempts = (tonumber(entry.refineAttempts) or 0)
    if sampled ~= false then
        entry.refineAttempts = entry.refineAttempts + 1
    end
    if type(entry.seedOut) ~= "table" then
        entry.seedOut = {}
    end
    local plantData = LookupItemData(plantUid)
    if type(plantData) == "table" then
        UpsertItem(plantData, "mat")
    end
    local changed = false
    for uid, count in pairs(products) do
        uid = tonumber(uid) or 0
        count = tonumber(count) or 0
        if uid > 0 and uid ~= plantUid then
            local item = LookupItemData(uid)
            local kind = ProductKindForItem(item)
            if kind == "seed" or kind == "spore" then
                if StockPiler2.SeedMap.IsSeedPacketItem(item) then
                    -- Vendor packets are not convert output / refine seedUid.
                elseif StockPiler2.SeedMap.PairLooksLikePlantAndSeed(plantUid, uid) then
                    entry.seedUid = uid
                    entry.seedKind = kind
                    changed = true
                    if RecordStat(entry.seedOut, uid, count, sampled ~= false) then
                        changed = true
                    end
                    if type(item) == "table" then
                        UpsertItem(item, kind)
                    end
                end
            else
                -- Non-seed convert gain: only Arboreal Resin (etc.), never co-timed plants.
                if IsResinLikeItem(item, uid) then
                    if RecordStat(entry.byproducts, uid, count, sampled ~= false) then
                        changed = true
                        if type(item) == "table" then
                            UpsertItem(item, "resin")
                        elseif StockPiler2.Items and StockPiler2.Items.Upsert then
                            StockPiler2.Items.Upsert(uid, { kind = "resin", uniqueID = uid })
                        end
                        if StockPiler2.MaterialSpec and type(item) == "table" then
                            local spec = StockPiler2.MaterialSpec.FromItemData(item)
                            if type(spec) == "table" then
                                StockPiler2.SeedMap.MarkHarvestByproduct(spec, "refine", uid)
                            end
                        end
                    end
                else
                    D("SeedMap ObserveRefine skip non-resin extra uid=" .. tostring(uid)
                        .. " plantUid=" .. tostring(plantUid)
                        .. " name=" .. ToNarrow(item and item.name or uid))
                end
            end
        end
    end
    return changed
end

function StockPiler2.SeedMap.NoteKnownHarvestPair(seedUid, plantUid, forceRelated, plotTrusted)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 or plantUid <= 0 then
        return false
    end
    -- Do not pass plantUid as expectedPlantUid (that made HarvestPairAllowed always true).
    return StockPiler2.SeedMap.ObserveHarvest(
        seedUid,
        { [plantUid] = 0 },
        false,
        forceRelated == true,
        0,
        plotTrusted == true
    )
end

function StockPiler2.SeedMap.NoteKnownRefinePair(plantUid, productUid)
    plantUid = tonumber(plantUid) or 0
    productUid = tonumber(productUid) or 0
    if plantUid <= 0 or productUid <= 0 then
        return false
    end
    return StockPiler2.SeedMap.ObserveRefine(plantUid, { [productUid] = 0 }, false)
end

function StockPiler2.SeedMap.HarvestProducts(seedUid)
    seedUid = tonumber(seedUid) or 0
    local list = {}
    if seedUid <= 0 then
        return list
    end
    local grows = AccountTable("grows")
    local bucket = grows[tostring(seedUid)]
    if type(bucket) ~= "table" then
        return list
    end
    for plantKey, row in pairs(bucket) do
        if type(row) == "table" and tonumber(plantKey) then
            list[#list + 1] = StatRowToProduct(plantKey, "plant", row)
        end
    end
    return SortedProductList(list)
end

--- Expected plants gained per successful harvest of this seed.
--- Uses observed bag deltas (samples/countSum). Returns (yield, samples).
--- Default yield is 1 until at least one counted harvest (fresh / low skill).
function StockPiler2.SeedMap.ExpectedHarvestYield(seedUid, plantUid)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    if seedUid <= 0 then
        return 1, 0
    end
    local products = StockPiler2.SeedMap.HarvestProducts(seedUid)
    if plantUid <= 0 and StockPiler2.SeedMap.PrimaryPlantForSeed then
        plantUid = tonumber(StockPiler2.SeedMap.PrimaryPlantForSeed(seedUid)) or 0
    end
    local function avgOf(prod)
        local samples = tonumber(prod and prod.samples) or 0
        if samples <= 0 then
            return 0, 0
        end
        local avg = (tonumber(prod.countSum) or 0) / samples
        if avg < 1 then
            avg = 1
        end
        return avg, samples
    end
    if plantUid > 0 then
        for i = 1, #products do
            if (tonumber(products[i].uid) or 0) == plantUid then
                local avg, samples = avgOf(products[i])
                if samples > 0 then
                    return avg, samples
                end
                break
            end
        end
    end
    local bestAvg, bestSamples = 0, 0
    for i = 1, #products do
        local avg, samples = avgOf(products[i])
        if samples > bestSamples then
            bestSamples = samples
            bestAvg = avg
        end
    end
    if bestSamples > 0 then
        return bestAvg, bestSamples
    end
    return 1, 0
end

--- Fraction of harvests that did not Critical-Fail (seed survived). nil if no samples.
function StockPiler2.SeedMap.HarvestSurviveRate(seedUid)
    local bucket = GrowsBucketStats(seedUid)
    if type(bucket) ~= "table" then
        return nil
    end
    local attempts = tonumber(bucket.harvestAttempts) or 0
    if attempts <= 0 then
        return nil
    end
    local fails = tonumber(bucket.chatCriticalFailure) or 0
    if fails < 0 then
        fails = 0
    end
    if fails > attempts then
        fails = attempts
    end
    return (attempts - fails) / attempts
end

function StockPiler2.SeedMap.HarvestCritSuccessRate(seedUid)
    local bucket = GrowsBucketStats(seedUid)
    if type(bucket) ~= "table" then
        return nil
    end
    local attempts = tonumber(bucket.harvestAttempts) or 0
    if attempts <= 0 then
        return nil
    end
    local hits = tonumber(bucket.chatCriticalSuccess) or 0
    return hits / attempts
end

function StockPiler2.SeedMap.SpecialMomentRate(seedUid)
    local bucket = GrowsBucketStats(seedUid)
    if type(bucket) ~= "table" then
        return nil
    end
    local attempts = tonumber(bucket.harvestAttempts) or 0
    if attempts <= 0 then
        return nil
    end
    local hits = tonumber(bucket.specialMomentHits) or 0
    return hits / attempts
end

--- Seeds to buy/plant so expected surviving harvests yield plantsNeeded of plantUid.
--- Uses ObservedHarvestYield × survive rate; defaults yield=1, survive=1 when unknown.
function StockPiler2.SeedMap.SeedsNeededForPlants(seedUid, plantUid, plantsNeeded)
    seedUid = tonumber(seedUid) or 0
    plantUid = tonumber(plantUid) or 0
    plantsNeeded = tonumber(plantsNeeded) or 0
    if seedUid <= 0 or plantsNeeded <= 0 then
        return 0
    end
    local yield = 1
    if StockPiler2.SeedMap.ExpectedHarvestYield then
        -- ExpectedHarvestYield returns (avg, samples); only take the first value.
        local yieldAvg = StockPiler2.SeedMap.ExpectedHarvestYield(seedUid, plantUid)
        yield = tonumber(yieldAvg) or 1
    end
    if yield < 0.01 then
        yield = 0.01
    end
    local survive = StockPiler2.SeedMap.HarvestSurviveRate(seedUid)
    if survive == nil then
        survive = 1
    elseif survive < 0.01 then
        survive = 0.01
    end
    local perSeed = yield * survive
    if perSeed < 0.01 then
        perSeed = 0.01
    end
    return math.ceil(plantsNeeded / perSeed)
end

function StockPiler2.SeedMap.RefineSeedAvg(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return 0, 0
    end
    local refines = AccountTable("refines")
    local entry = refines[tostring(plantUid)]
    if type(entry) ~= "table" or type(entry.seedOut) ~= "table" then
        return 0, 0
    end
    local seedUid = tonumber(entry.seedUid) or 0
    local row = seedUid > 0 and entry.seedOut[tostring(seedUid)] or nil
    if type(row) ~= "table" then
        for _, r in pairs(entry.seedOut) do
            if type(r) == "table" then
                row = r
                break
            end
        end
    end
    if type(row) ~= "table" then
        return 0, 0
    end
    local samples = tonumber(row.samples) or 0
    if samples <= 0 then
        return 0, 0
    end
    return (tonumber(row.countSum) or 0) / samples, samples
end

function StockPiler2.SeedMap.FormatHarvestRateLine(seedUid, plantUid)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return nil
    end
    local bucket = GrowsBucketStats(seedUid)
    if type(bucket) ~= "table" then
        return nil
    end
    local attempts = tonumber(bucket.harvestAttempts) or 0
    if attempts <= 0 then
        return nil
    end
    local survive = StockPiler2.SeedMap.HarvestSurviveRate(seedUid) or 1
    local sm = StockPiler2.SeedMap.SpecialMomentRate(seedUid) or 0
    local yield = 1
    if StockPiler2.SeedMap.ExpectedHarvestYield then
        -- ExpectedHarvestYield returns (avg, samples); only take the first value.
        local yieldAvg = StockPiler2.SeedMap.ExpectedHarvestYield(seedUid, plantUid)
        yield = tonumber(yieldAvg) or 1
    end
    return string.format(
        "Harvest: %.0f%% survive, yield %.1f, SM %.0f%% (n=%d)",
        survive * 100,
        yield,
        sm * 100,
        attempts
    )
end

--- Narrow-string harvest + optional Cult skill-up lines for tooltips.
--- Returns list of strings (may be empty).
function StockPiler2.SeedMap.FormatHarvestTooltipRateLines(seedUid, plantUid)
    local lines = {}
    local harvest = StockPiler2.SeedMap.FormatHarvestRateLine(seedUid, plantUid)
    if type(harvest) == "string" and harvest ~= "" then
        lines[#lines + 1] = harvest
    end
    local cult = StockPiler2.SeedMap.FormatCultSkillUpLine(seedUid)
    if type(cult) == "string" and cult ~= "" then
        lines[#lines + 1] = cult
    end
    return lines
end

function StockPiler2.SeedMap.RefineProducts(plantUid)
    plantUid = tonumber(plantUid) or 0
    local list = {}
    if plantUid <= 0 then
        return list
    end
    local refines = AccountTable("refines")
    local entry = refines[tostring(plantUid)]
    if type(entry) ~= "table" then
        return list
    end
    local seedUid = tonumber(entry.seedUid) or 0
    if seedUid > 0 then
        list[#list + 1] = StatRowToProduct(seedUid, entry.seedKind or "seed", {
            samples = 0,
            countSum = 0,
            last = 0,
        })
    end
    if type(entry.byproducts) == "table" then
        for resinKey, row in pairs(entry.byproducts) do
            if type(row) == "table" then
                list[#list + 1] = StatRowToProduct(resinKey, "resin", row)
            end
        end
    end
    return SortedProductList(list)
end

function StockPiler2.SeedMap.PrimaryPlantForSeed(seedUid)
    seedUid = tonumber(seedUid) or 0
    local products = StockPiler2.SeedMap.HarvestProducts(seedUid)
    if #products == 0 then
        return 0
    end
    local seedData = seedUid > 0 and LookupItemData(seedUid) or nil
    local bestRelatedUid = 0
    local bestRelatedSamples = -1
    local bestAnyUid = 0
    local bestAnySamples = -1
    for i = 1, #products do
        local plantUid = tonumber(products[i].uid) or 0
        if plantUid > 0 then
            local samples = tonumber(products[i].samples) or 0
            if samples > bestAnySamples then
                bestAnySamples = samples
                bestAnyUid = plantUid
            end
            local plantData = LookupItemData(plantUid)
            local related = true
            if type(seedData) == "table" and type(plantData) == "table" then
                related = StockPiler2.SeedMap.GrowNamesRelated(plantData.name, seedData.name) == true
            end
            -- Prefer name-related (typical base plant); keep non-matching rows
            -- (crit-upgrade tiers) for reverse lookup via GetSeedUidsForPlant.
            if related and samples > bestRelatedSamples then
                bestRelatedSamples = samples
                bestRelatedUid = plantUid
            end
        end
    end
    if bestRelatedUid > 0 then
        return bestRelatedUid
    end
    return bestAnyUid
end

function StockPiler2.SeedMap.IsResinUid(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return false
    end
    if StockPiler2.Items and StockPiler2.Items.Get then
        local row = StockPiler2.Items.Get(uid)
        if type(row) == "table" and row.kind == "resin" then
            return true
        end
    end
    if ItemNameLooksLikeResin(LookupItemData(uid)) then
        return true
    end
    -- Do not treat arbitrary refine byproduct keys as resin (co-timed plants polluted that map).
    return false
end

--- When a recipe has no growable ingredients but needs resin (etc.), pick a plant
--- to grow and convert. Prefers same-level extenders (Cultivating-only), then any
--- plantable seed already in bags at that crafting level.
function StockPiler2.SeedMap.FindByproductConvertGrowSpec(skillLevel)
    skillLevel = tonumber(skillLevel) or 0
    if skillLevel <= 0 or not StockPiler2.MaterialSpec then
        return nil
    end
    local MS = StockPiler2.MaterialSpec
    local bestSpec = nil
    local bestScore = -1
    local bestSeedHave = -1
    local seenPlant = {}

    local function seedHaveOf(seedUid)
        seedUid = tonumber(seedUid) or 0
        if seedUid <= 0 then
            return 0
        end
        if StockPiler2.AutoGrow and StockPiler2.AutoGrow.GetEffectiveSeedCount then
            return tonumber(StockPiler2.AutoGrow.GetEffectiveSeedCount(seedUid)) or 0
        end
        if StockPiler2.Inventory and StockPiler2.Inventory.UniqueIdCount then
            return StockPiler2.Inventory.UniqueIdCount(seedUid)
        end
        return 0
    end

    local function canUseSeed(seedUid)
        seedUid = tonumber(seedUid) or 0
        if seedUid <= 0 then
            return false
        end
        if StockPiler2.Inventory and StockPiler2.Inventory.CanUseUniqueId then
            return StockPiler2.Inventory.CanUseUniqueId(seedUid) == true
        end
        return true
    end

    local function plantSpecForUid(plantUid)
        plantUid = tonumber(plantUid) or 0
        if plantUid <= 0 then
            return nil
        end
        local itemData = nil
        if StockPiler2.Inventory and StockPiler2.Inventory.CountByUniqueId then
            local _, sample = StockPiler2.Inventory.CountByUniqueId(plantUid)
            itemData = sample
        end
        if type(itemData) ~= "table" then
            itemData = LookupItemData(plantUid)
        end
        if type(itemData) == "table" and MS.FromItemData then
            local spec = MS.FromItemData(itemData)
            if type(spec) == "table" then
                return spec
            end
        end
        if StockPiler2.Items and StockPiler2.Items.ToSpec then
            return StockPiler2.Items.ToSpec(plantUid)
        end
        return nil
    end

    local function consider(plantUid, seedUid)
        plantUid = tonumber(plantUid) or 0
        seedUid = tonumber(seedUid) or 0
        if plantUid <= 0 or seenPlant[plantUid] == true then
            return
        end
        if StockPiler2.SeedMap.IsResinUid(plantUid) then
            return
        end
        if seedUid <= 0 and StockPiler2.SeedMap.ResolveSeedForPlantUid then
            local seed = StockPiler2.SeedMap.ResolveSeedForPlantUid(plantUid)
            if type(seed) == "table" then
                seedUid = tonumber(seed.uniqueID) or 0
            end
        end
        if seedUid <= 0 then
            return
        end
        local spec = plantSpecForUid(plantUid)
        if type(spec) ~= "table" then
            return
        end
        if (tonumber(spec.skillLevel) or 0) ~= skillLevel then
            return
        end
        if StockPiler2.SeedMap.IsHarvestByproduct
            and StockPiler2.SeedMap.IsHarvestByproduct(spec) == true
        then
            return
        end
        local role = spec.role or ""
        local seedHave = seedHaveOf(seedUid)
        local usable = canUseSeed(seedUid)
        -- Extenders first (even with 0 seeds); other roles only if a seed is in bags.
        local score
        if role == "extender" then
            score = 300
            if seedHave > 0 then
                score = score + 20
            end
        elseif seedHave > 0 then
            score = 100
        else
            return
        end
        if usable then
            score = score + 1
        end
        seenPlant[plantUid] = true
        if score > bestScore
            or (score == bestScore and seedHave > bestSeedHave)
        then
            bestScore = score
            bestSeedHave = seedHave
            bestSpec = spec
        end
    end

    local refines = AccountTable("refines")
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            consider(tonumber(plantKey), entry.seedUid)
        end
    end
    local grows = AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        local seedUid = tonumber(seedKey) or 0
        if type(plants) == "table" then
            for plantKey in pairs(plants) do
                consider(tonumber(plantKey), seedUid)
            end
        end
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        local seedType = CultivationSeedType()
        local sporeType = CultivationSporeType()
        StockPiler2.Inventory.ForEachItem(function(item)
            if type(item) ~= "table" then
                return
            end
            local cultType = tonumber(item.cultivationType) or 0
            if cultType ~= seedType and cultType ~= sporeType then
                return
            end
            local seedUid = tonumber(item.uniqueID) or 0
            local plantUid = 0
            if seedUid > 0 and StockPiler2.SeedMap.GetPlantUidForSeed then
                plantUid = tonumber(StockPiler2.SeedMap.GetPlantUidForSeed(seedUid)) or 0
            end
            if plantUid > 0 then
                consider(plantUid, seedUid)
            end
        end)
    end
    return bestSpec
end

function StockPiler2.SeedMap.PlantsThatYieldResin(resinUid)
    resinUid = tonumber(resinUid) or 0
    local plants = {}
    if resinUid <= 0 then
        return plants
    end
    local refines = AccountTable("refines")
    local key = tostring(resinUid)
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" and type(entry.byproducts) == "table"
            and type(entry.byproducts[key]) == "table"
        then
            plants[#plants + 1] = tonumber(plantKey) or 0
        end
    end
    return plants
end

function StockPiler2.SeedMap.CountLearnedGrowPairs()
    local grows = AccountTable("grows")
    local n = 0
    for _, plants in pairs(grows) do
        if type(plants) == "table" then
            for _, row in pairs(plants) do
                if type(row) == "table" then
                    n = n + 1
                end
            end
        end
    end
    return n
end

local function SeedKindFromItem(itemData, seedUid)
    local cultType = 0
    if type(itemData) == "table" then
        cultType = tonumber(itemData.cultivationType) or 0
    end
    if cultType == CultivationSporeType() then
        return "spore", true
    end
    if cultType == CultivationSeedType() then
        return "seed", false
    end
    local name = string.lower(ToNarrow(itemData and itemData.name))
    if string.find(name, "spore", 1, true) then
        return "spore", true
    end
    return "seed", false
end

local function BuildSeedRecord(seedUid, source, plantUid)
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
        itemData = LookupItemData(seedUid)
    end

    local obs = ObservedMatRecord(seedUid)
    local name = (type(sample) == "table" and sample.name)
        or (type(obs) == "table" and obs.name)
        or (type(itemData) == "table" and itemData.name)
    local nameNarrow = ToNarrow(name)
    if nameNarrow == "" and type(obs) == "table" then
        nameNarrow = obs.nameNarrow or ""
    end
    if nameNarrow == "" and plantUid and plantUid > 0 then
        local plantData = LookupItemData(plantUid)
        local plantName = ToNarrow(plantData and plantData.name)
        if plantName ~= "" then
            local kind = SeedKindFromItem(itemData, seedUid)
            nameNarrow = plantName .. (kind == "spore" and " Spore" or " Seed")
            name = towstring(nameNarrow)
        end
    end

    local kind, isSpore = SeedKindFromItem(itemData or obs, seedUid)
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
    }
end

local function FindObservedSeed(baseNameNarrow)
    baseNameNarrow = NormalizeGrowName(baseNameNarrow)
    if baseNameNarrow == "" then
        return nil
    end
    local items = AccountTable("items")
    local seedType = CultivationSeedType()
    local sporeType = CultivationSporeType()
    local best = nil
    for _, obs in pairs(items) do
        if type(obs) == "table" then
            local cultType = tonumber(obs.cultivationType) or 0
            local kind = obs.kind
            if cultType == seedType or cultType == sporeType
                or kind == "seed" or kind == "spore"
            then
                local obsBase = NormalizeGrowName(obs.nameNarrow or ToNarrow(obs.name))
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

    local nameNarrow = mat.nameNarrow or ToNarrow(mat.name) or ToNarrow(mat.match)
    if nameNarrow == "" then
        return false
    end
    if LooksButchering(nameNarrow) then
        return false
    end

    local cultType = tonumber(mat.cultivationType) or 0
    if cultType == 0 and type(mat.itemData) == "table" then
        cultType = tonumber(mat.itemData.cultivationType) or 0
    end
    if cultType == CultivationSeedType() or cultType == CultivationSporeType() then
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
        local obs = ObservedMatRecord(plantUid)
        if type(obs) == "table" and obs.isRefinable == true then
            return true
        end
        local itemData = LookupItemData(plantUid)
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
        return not LooksButchering(nameNarrow)
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
        local matName = mat.nameNarrow or ToNarrow(mat.name) or ToNarrow(mat.match)
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
                    local record = BuildSeedRecord(
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

        local obs = FindObservedSeed(matName)
        if obs then
            local seedUid = tonumber(obs.uniqueID) or 0
            local record = BuildSeedRecord(seedUid, "observed", plantUid)
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
            local refines = AccountTable("refines")
            local entry = refines[tostring(plantUid)]
            if type(entry) == "table" and tonumber(entry.seedUid) == seedUid then
                source = "refine"
            end
            local record = BuildSeedRecord(seedUid, source, plantUid)
            if type(record) == "table" then
                return record
            end
        end
    end

    return resolveByMaterialName()
end

local function ItemStackCount(item)
    return tonumber(item.stackCount) or tonumber(item.StackCount) or 1
end

local function IsSeedOrSporeItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    return cultType == CultivationSeedType() or cultType == CultivationSporeType()
end

-- Plants that convert to seeds are often ct=0 apo mains. Molotov convert
-- junk (Smoking Pyre Ivy) is also isRefinable with ct=0.
function StockPiler2.SeedMap.ItemLooksLikeRefinablePlant(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if itemData.isRefinable ~= true then
        return false
    end
    if IsSeedOrSporeItem(itemData) then
        return false
    end
    if StockPiler2.MaterialSpec and StockPiler2.MaterialSpec.FromItemData then
        local spec = StockPiler2.MaterialSpec.FromItemData(itemData)
        local role = spec and spec.role or ""
        if role == "main" or role == "stabilizer" or role == "goldweed"
            or role == "extender" or role == "multiplier" or role == "stimulant"
        then
            return true
        end
    end
    return false
end

local function IsPotionBagItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local t = tonumber(itemData.type) or tonumber(itemData.itemType)
    if GameData and GameData.ItemTypes and GameData.ItemTypes.POTION then
        return t == GameData.ItemTypes.POTION
    end
    return t == 31
end

--- Live craft-bag mat counts without InvalidateSnapshot / itemsDirty.
--- Prefer Inventory craft slots when ready (avoids walking all L0 uids /
--- dual DataUtils bag scans on harvest complete).
local function SnapshotCraftingMatCounts()
    local counts = {}
    local function addItem(item)
        if type(item) ~= "table" then
            return
        end
        -- Only CRAFTING (34): skip inventory trash like Wilted Wild Weed (NONE).
        if IsCraftingItem(item) and not IsPotionBagItem(item) then
            local uid = tonumber(item.uniqueID) or 0
            if uid > 0 then
                counts[uid] = (counts[uid] or 0) + ItemStackCount(item)
            end
        end
    end
    local Inv = StockPiler2.Inventory
    if Inv and Inv._ready == true and type(Inv._itemBySlot) == "table" then
        local craft = Inv._itemBySlot.craft
        if type(craft) == "table" then
            for _, item in pairs(craft) do
                addItem(item)
            end
            return counts
        end
    end
    if DataUtils and type(DataUtils.GetCraftingItems) == "function" then
        local ok, data = StockPiler2.TryCallQuiet("DataUtils.GetCraftingItems", DataUtils.GetCraftingItems)
        if ok and type(data) == "table" then
            for _, item in pairs(data) do
                addItem(item)
            end
            return counts
        end
    elseif type(GetCraftingItemData) == "function" then
        local ok, data = StockPiler2.TryCallQuiet("GetCraftingItemData", GetCraftingItemData)
        if ok and type(data) == "table" then
            for _, item in pairs(data) do
                addItem(item)
            end
            return counts
        end
    end
    return counts
end

function StockPiler2.SeedMap.BeginPendingRefine(itemData)
    if type(itemData) ~= "table" then
        StockPiler2.SeedMap._pendingRefine = nil
        return
    end
    local plantUid = tonumber(itemData.uniqueID) or 0
    if plantUid <= 0 then
        StockPiler2.SeedMap._pendingRefine = nil
        return
    end
    if not StockPiler2.SeedMap.ItemLooksLikeRefinablePlant(itemData) then
        StockPiler2.SeedMap._pendingRefine = nil
        return
    end

    local expected = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
    local best = StockPiler2.SeedMap.PickBestSeedUid(plantUid, expected)
    if best > 0 then
        expected = { best }
    end

    StockPiler2.SeedMap._pendingRefine = {
        plantUid = plantUid,
        plantName = ToNarrow(itemData.name),
        expectedSeeds = expected,
        countsBefore = SnapshotCraftingMatCounts(),
        started = NowSec(),
    }
end

function StockPiler2.SeedMap.MaybeCompletePendingRefine()
    local pending = StockPiler2.SeedMap._pendingRefine
    if type(pending) ~= "table" then
        return false
    end
    local started = tonumber(pending.started) or 0
    local now = NowSec()
    if started > 0 and now > 0 and (now - started) > 8 then
        StockPiler2.SeedMap._pendingRefine = nil
        return false
    end

    local plantUid = tonumber(pending.plantUid) or 0
    if plantUid <= 0 then
        StockPiler2.SeedMap._pendingRefine = nil
        return false
    end

    local countsAfter = SnapshotCraftingMatCounts()
    local before = pending.countsBefore or {}
    local expected = pending.expectedSeeds
    local expectedSet = {}
    if type(expected) == "table" then
        for i = 1, #expected do
            local uid = tonumber(expected[i]) or 0
            if uid > 0 then
                expectedSet[uid] = true
            end
        end
    end

    local seedUid = tonumber(pending.confirmedSeedUid) or 0
    local delta = tonumber(pending.confirmedSeedDelta) or 0
    local expectedSeedUid = 0
    local expectedDelta = 0
    local extras = type(pending.extras) == "table" and pending.extras or {}

    for uid, afterCount in pairs(countsAfter) do
        uid = tonumber(uid) or 0
        local prior = tonumber(before[uid]) or 0
        local change = afterCount - prior
        if uid > 0 and change > 0 then
            local item = LookupItemData(uid)
            if IsSeedOrSporeItem(item) then
                if change > delta then
                    delta = change
                    seedUid = uid
                end
                if expectedSet[uid] == true and change > expectedDelta then
                    expectedDelta = change
                    expectedSeedUid = uid
                end
            elseif uid ~= plantUid then
                local prev = tonumber(extras[uid]) or 0
                if change > prev then
                    extras[uid] = change
                end
            end
        end
    end
    if expectedSeedUid > 0 then
        seedUid = expectedSeedUid
        delta = expectedDelta
    end

    if seedUid <= 0 or delta <= 0 then
        return false
    end

    local plantAfter = tonumber(countsAfter[plantUid]) or 0
    local plantBefore = tonumber(before[plantUid]) or 0
    if plantAfter >= plantBefore then
        return false
    end

    -- Seed often lands one inventory event before Arboreal Resin. Hold the
    -- watch briefly so the byproduct delta is included in the same observe.
    local hasResin = false
    for uid, _ in pairs(extras) do
        local item = LookupItemData(uid)
        if ItemNameLooksLikeResin(item)
            or (StockPiler2.SeedMap.IsResinUid and StockPiler2.SeedMap.IsResinUid(uid))
            or (type(item) == "table" and not IsSeedOrSporeItem(item))
        then
            hasResin = true
            break
        end
    end
    if not hasResin then
        if pending.confirmedSeedUid == nil then
            pending.confirmedSeedUid = seedUid
            pending.confirmedSeedDelta = delta
            pending.seedSeenAt = now
            pending.extras = extras
            D("SeedMap refine waiting for resin plantUid=" .. tostring(plantUid)
                .. " seedUid=" .. tostring(seedUid))
        else
            pending.extras = extras
        end
        local seenAt = tonumber(pending.seedSeenAt) or now
        if now > 0 and (now - seenAt) < 2.5 then
            return false
        end
        -- Timed out waiting for resin; still record the seed.
        seedUid = tonumber(pending.confirmedSeedUid) or seedUid
        delta = tonumber(pending.confirmedSeedDelta) or delta
    else
        seedUid = tonumber(pending.confirmedSeedUid) or seedUid
        delta = tonumber(pending.confirmedSeedDelta) or delta
        if type(pending.extras) == "table" then
            for uid, change in pairs(pending.extras) do
                local cur = tonumber(extras[uid]) or 0
                if change > cur then
                    extras[uid] = change
                end
            end
        end
    end

    StockPiler2.SeedMap._pendingRefine = nil

    local refineProducts = { [seedUid] = delta }
    for uid, change in pairs(extras) do
        uid = tonumber(uid) or 0
        change = tonumber(change) or 0
        if uid > 0 and change > 0 and uid ~= plantUid and uid ~= seedUid then
            local item = LookupItemData(uid)
            if not IsSeedOrSporeItem(item) and IsResinLikeItem(item, uid) then
                refineProducts[uid] = change
                if StockPiler2.MaterialSpec and type(item) == "table" then
                    local spec = StockPiler2.MaterialSpec.FromItemData(item)
                    if type(spec) == "table" then
                        StockPiler2.SeedMap.MarkHarvestByproduct(spec, "refine", uid)
                        D("SeedMap refine extra uid=" .. tostring(uid)
                            .. " +" .. tostring(change)
                            .. " spec=" .. tostring(StockPiler2.MaterialSpec.Key(spec)))
                    end
                else
                    D("SeedMap refine extra uid=" .. tostring(uid) .. " +" .. tostring(change))
                end
            elseif not IsSeedOrSporeItem(item) then
                D("SeedMap refine skip non-resin extra uid=" .. tostring(uid)
                    .. " +" .. tostring(change)
                    .. " name=" .. ToNarrow(item and item.name or uid))
            end
        end
    end
    StockPiler2.SeedMap.ObserveRefine(plantUid, refineProducts, true)

    local learned = StockPiler2.SeedMap.LearnMapping(plantUid, seedUid, "refine")
    if learned and StockPiler2.SeedMap.ObserveMatFromRefine then
        StockPiler2.SeedMap.ObserveMatFromRefine(plantUid, seedUid)
    end
    return { plantUid = plantUid, seedUid = seedUid, learned = learned }
end

local function PlotSeedUid(plotData)
    if type(plotData) ~= "table" or type(plotData.Seed) ~= "table" then
        return 0
    end
    return tonumber(plotData.Seed.uniqueID) or 0
end

function StockPiler2.SeedMap.NotePlotSeed(plotNum, seedUid)
    plotNum = tonumber(plotNum) or 0
    seedUid = tonumber(seedUid) or 0
    if plotNum <= 0 or seedUid <= 0 then
        return
    end
    if type(StockPiler2.SeedMap._plotSeedByPlot) ~= "table" then
        StockPiler2.SeedMap._plotSeedByPlot = {}
    end
    StockPiler2.SeedMap._plotSeedByPlot[plotNum] = seedUid
end

function StockPiler2.SeedMap.ClearPlotSeed(plotNum)
    plotNum = tonumber(plotNum) or 0
    if plotNum <= 0 or type(StockPiler2.SeedMap._plotSeedByPlot) ~= "table" then
        return
    end
    StockPiler2.SeedMap._plotSeedByPlot[plotNum] = nil
end

--- Prefer live seedUniqueID; fall back to last remembered seed for this plot.
function StockPiler2.SeedMap.ResolvePlotSeed(plotNum, liveSeedUid)
    plotNum = tonumber(plotNum) or 0
    liveSeedUid = tonumber(liveSeedUid) or 0
    if liveSeedUid > 0 then
        if plotNum > 0 then
            StockPiler2.SeedMap.NotePlotSeed(plotNum, liveSeedUid)
        end
        return liveSeedUid
    end
    if plotNum <= 0 or type(StockPiler2.SeedMap._plotSeedByPlot) ~= "table" then
        return 0
    end
    return tonumber(StockPiler2.SeedMap._plotSeedByPlot[plotNum]) or 0
end

local function InferSeedUidForPlantHarvest(plantUid, plantName)
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

    local plantData = LookupItemData(plantUid)
    local label = plantName
    if (label == nil or label == "") and type(plantData) == "table" then
        label = plantData.name
    end
    local MS = StockPiler2.MaterialSpec
    local bestUid = 0
    local bestCount = -1
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        StockPiler2.Inventory.ForEachItem(function(item)
            if not IsBagSeedOrSpore(item) then
                return
            end
            local uid = tonumber(item.uniqueID) or 0
            if uid <= 0 then
                return
            end
            local related = false
            if type(plantData) == "table" then
                related = SeedPlantPairRelated(item, plantData)
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
    plantName = ToNarrow(plantName)
    if plantName == "" then
        return 0
    end

    local items = AccountTable("items")
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
                if HarvestNameMatchesItemName(plantName, name) then
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
            if item.isRefinable == true or ProductKindForItem(item) == "plant" then
                if HarvestNameMatchesItemName(plantName, item.name) then
                    found = tonumber(item.uniqueID) or 0
                end
            end
        end)
    end
    return found
end

--- Manual harvest fallback when bag-delta watch did not complete (Crafting chat line).
function StockPiler2.SeedMap.LearnFromCraftChatHarvest(count, plantName)
    count = tonumber(count) or 0
    plantName = ToNarrow(plantName)
    if plantName == "" then
        return false
    end

    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) == "table" and pending.locked == true then
        return false
    end

    local plantUid = StockPiler2.SeedMap.FindPlantUidByHarvestName(plantName)
    if plantUid <= 0 then
        D("SeedMap craft harvest unknown plant name=" .. plantName)
        return false
    end

    -- Prefer plot-watched / remembered seed (one-way mats fail name InferSeedUid).
    local trusted = false
    local seedUid = 0
    local SM = StockPiler2.SeedMap
    if type(pending) == "table" then
        seedUid = tonumber(pending.seedUid) or 0
        if seedUid <= 0 then
            seedUid = SM.ResolvePlotSeed(tonumber(pending.plotNum) or 0, 0)
        end
        if seedUid <= 0 and type(pending.seedsByPlot) == "table" then
            for pn, sid in pairs(pending.seedsByPlot) do
                sid = tonumber(sid) or 0
                if sid <= 0 then
                    sid = SM.ResolvePlotSeed(tonumber(pn) or 0, 0)
                end
                if sid > 0 then
                    seedUid = sid
                    break
                end
            end
        end
        if seedUid > 0 then
            trusted = true
        end
    end
    if seedUid <= 0 then
        seedUid = InferSeedUidForPlantHarvest(plantUid, plantName)
    end
    local plantData = LookupItemData(plantUid)
    if type(plantData) == "table" then
        UpsertItem(plantData, "mat")
    end
    if seedUid <= 0 then
        D("SeedMap craft harvest no seedUid plantUid=" .. tostring(plantUid)
            .. " name=" .. plantName)
        return false
    end

    local products = { [plantUid] = count > 0 and count or 1 }
    StockPiler2.SeedMap.ObserveHarvest(seedUid, products, count > 0, trusted, plantUid)
    local chatCues = nil
    if StockPiler2.CraftChat and StockPiler2.CraftChat.PeekCues then
        chatCues = StockPiler2.CraftChat.PeekCues()
    end
    StockPiler2.SeedMap.RecordHarvestChatCues(seedUid, chatCues, nil)
    local learned = StockPiler2.SeedMap.LearnMapping(plantUid, seedUid, "harvest", trusted, plantUid)
    if type(plantData) == "table" and StockPiler2.SeedMap.RegisterFromItem then
        StockPiler2.SeedMap.RegisterFromItem(plantData, seedUid)
    end
    if type(pending) == "table" then
        local pn = tonumber(pending.plotNum) or 0
        if pn > 0 then
            StockPiler2.SeedMap.ClearPlotSeed(pn)
        end
        if type(pending.seedsByPlot) == "table" then
            for pnKey, _ in pairs(pending.seedsByPlot) do
                StockPiler2.SeedMap.ClearPlotSeed(tonumber(pnKey) or 0)
            end
        end
    end
    D("SeedMap craft harvest plantUid=" .. tostring(plantUid)
        .. " seedUid=" .. tostring(seedUid)
        .. " learned=" .. tostring(learned == true)
        .. " trusted=" .. tostring(trusted)
        .. " name=" .. plantName)
    if learned and StockPiler2.Knowledge and StockPiler2.Knowledge.Touch then
        StockPiler2.Knowledge.Touch()
    end
    return learned == true
end

function StockPiler2.SeedMap.BeginPendingHarvest(plotNum, plotData)
    plotNum = tonumber(plotNum) or 0
    local live = PlotSeedUid(plotData)
    local seedUid = StockPiler2.SeedMap.ResolvePlotSeed(plotNum, live)
    StockPiler2.SeedMap._pendingHarvest = {
        plotNum = plotNum,
        seedUid = seedUid,
        countsBefore = SnapshotCraftingMatCounts(),
        started = NowSec(),
        locked = true,
        lootDirty = false,
        lootDirtyAt = 0,
        lastCompleteAttempt = 0,
    }
    D("SeedMap harvest watch plot=" .. tostring(plotNum)
        .. " seedUid=" .. tostring(seedUid)
        .. " locked=true")
end

--- Inventory events during harvest only mark dirty — do not snapshot here
--- (multi-item loot was causing multi-second frametime spikes).
function StockPiler2.SeedMap.MarkHarvestLootDirty()
    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) ~= "table" then
        return
    end
    pending.lootDirty = true
    pending.lootDirtyAt = NowSec()
end

--- After refine/brew bag changes, rebase an unlocked harvest snapshot so convert
--- deltas are not treated as harvest loot.
function StockPiler2.SeedMap.RefreshHarvestWatchAfterBagChange()
    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) ~= "table" or pending.locked == true then
        return
    end
    pending.countsBefore = SnapshotCraftingMatCounts()
    pending.started = NowSec()
end

--- Keep a pre-harvest bag snapshot while a plot is grown (GatherButton / other harvesters).
function StockPiler2.SeedMap.RefreshHarvestWatch(plotNum, plotData)
    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) == "table" and pending.locked == true then
        D("SeedMap harvest watch plot=" .. tostring(plotNum)
            .. " seedUid=" .. tostring(pending.seedUid or 0)
            .. " locked=true skip=locked")
        return
    end
    plotNum = tonumber(plotNum) or 0
    local live = PlotSeedUid(plotData)
    local seedUid = StockPiler2.SeedMap.ResolvePlotSeed(plotNum, live)
    local seedsByPlot = {}
    if type(pending) == "table" and type(pending.seedsByPlot) == "table" then
        seedsByPlot = pending.seedsByPlot
    end
    local already = plotNum > 0 and seedUid > 0 and seedsByPlot[plotNum] == seedUid
    if plotNum > 0 and seedUid > 0 then
        seedsByPlot[plotNum] = seedUid
    end
    -- Same grown plot already watched: keep the baseline. Re-snapshoting
    -- every cultivation tick was a 1 Hz hitch while waiting to harvest.
    if already == true and type(pending) == "table" and type(pending.countsBefore) == "table" then
        pending.seedsByPlot = seedsByPlot
        pending.plotNum = plotNum
        if seedUid > 0 then
            pending.seedUid = seedUid
        end
        return
    end
    StockPiler2.SeedMap._pendingHarvest = {
        plotNum = plotNum,
        seedUid = seedUid > 0 and seedUid or (pending and pending.seedUid) or 0,
        seedsByPlot = seedsByPlot,
        countsBefore = SnapshotCraftingMatCounts(),
        started = NowSec(),
        locked = false,
        lootDirty = false,
        lootDirtyAt = 0,
        lastCompleteAttempt = 0,
    }
    D("SeedMap harvest watch plot=" .. tostring(plotNum)
        .. " seedUid=" .. tostring(StockPiler2.SeedMap._pendingHarvest.seedUid)
        .. " locked=false")
end

--- True when TryCompletePendingHarvest will run MaybeComplete (past settle/throttle).
--- Used so LearnBridge does not Perf.Begin on every dirty-frame no-op.
function StockPiler2.SeedMap.ShouldAttemptHarvestComplete(force)
    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) ~= "table" then
        return false
    end
    force = force == true
    if not force and pending.lootDirty ~= true then
        return false
    end
    local now = NowSec()
    local dirtyAt = tonumber(pending.lootDirtyAt) or 0
    if not force and dirtyAt > 0 and (now - dirtyAt) < 0.2 then
        return false
    end
    local lastTry = tonumber(pending.lastCompleteAttempt) or 0
    if not force and lastTry > 0 and (now - lastTry) < 0.15 then
        return false
    end
    return true
end

--- Throttled harvest completion: one bag snapshot after loot settles (~200ms),
--- or immediately when force=true (plot became empty).
function StockPiler2.SeedMap.TryCompletePendingHarvest(force)
    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) ~= "table" then
        return false
    end
    if StockPiler2.SeedMap.ShouldAttemptHarvestComplete(force) ~= true then
        return false
    end
    local now = NowSec()
    pending.lastCompleteAttempt = now
    -- Perf: do NOT clear lootDirty before MaybeComplete. Early force=true often
    -- returns false (loot still arriving); clearing dirty forced a wait for another
    -- inventory event and pushed successful Complete onto the PlanRebuild fire frame
    -- (LearnBridge+WarmHave fusion). Keep dirty so throttle can retry. Only clear
    -- after a successful complete. Do not revert to clear-before-MaybeComplete.
    local ok = StockPiler2.SeedMap.MaybeCompletePendingHarvest() == true
    if ok then
        pending = StockPiler2.SeedMap._pendingHarvest
        if type(pending) == "table" then
            pending.lootDirty = false
        end
    end
    return ok
end

function StockPiler2.SeedMap.MaybeCompletePendingHarvest()
    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) ~= "table" then
        return false
    end
    local Perf = StockPiler2.Perf
    if Perf and Perf.Begin then
        Perf.Begin("Harvest.Snapshot")
    end
    local before = pending.countsBefore or {}
    local after = SnapshotCraftingMatCounts()
    if Perf and Perf.End then
        Perf.End("Harvest.Snapshot")
    end
    local deltas = {}
    local hasNonSeedGain = false
    for uid, afterCount in pairs(after) do
        local change = afterCount - (tonumber(before[uid]) or 0)
        if change > 0 then
            deltas[uid] = change
            local item = LookupItemData(uid)
            if not IsSeedOrSporeItem(item) then
                hasNonSeedGain = true
            end
        end
    end
    if not hasNonSeedGain then
        -- Loot may still be arriving; keep watch and allow another dirty mark.
        return false
    end

    if Perf and Perf.Begin then
        Perf.Begin("Harvest.Complete")
    end
    local function done(result)
        if Perf and Perf.End then
            Perf.End("Harvest.Complete")
        end
        return result
    end

    local plotNum = tonumber(pending.plotNum) or 0
    local seedUid = StockPiler2.SeedMap.ResolvePlotSeed(plotNum, tonumber(pending.seedUid) or 0)
    local fromPlotWatch = seedUid > 0
    local plotSeedUid = seedUid
    local primaryUid = 0
    local primaryDelta = 0
    local linkedUid = 0
    local bestRefinable = 0
    local bestRefinableDelta = 0
    for uid, change in pairs(deltas) do
        local item = LookupItemData(uid)
        if not IsSeedOrSporeItem(item)
            and IsEligibleHarvestProductUid(uid, seedUid)
        then
            local linked = false
            if seedUid > 0 then
                local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(uid)
                for i = 1, #seedUids do
                    if tonumber(seedUids[i]) == seedUid then
                        linked = true
                    end
                end
            end
            if linked then
                linkedUid = uid
            end
            if type(item) == "table" and item.isRefinable == true and change > bestRefinableDelta then
                bestRefinableDelta = change
                bestRefinable = uid
            end
            if change > primaryDelta then
                primaryDelta = change
                primaryUid = uid
            end
        end
    end
    if linkedUid > 0 then
        primaryUid = linkedUid
    elseif bestRefinable > 0 and plotSeedUid <= 0 then
        -- Prefer refinable plant when seed is unknown; with a plot seed, keep max-delta
        -- primary so one-way powder is not overridden by a simultaneous refinable plant.
        primaryUid = bestRefinable
    end

    if primaryUid <= 0 then
        StockPiler2.SeedMap._pendingHarvest = nil
        return done(false)
    end

    if seedUid <= 0 and type(pending.seedsByPlot) == "table" then
        local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(primaryUid)
        for pn, sid in pairs(pending.seedsByPlot) do
            sid = tonumber(sid) or 0
            if sid <= 0 then
                sid = StockPiler2.SeedMap.ResolvePlotSeed(tonumber(pn) or 0, 0)
            end
            for i = 1, #seedUids do
                if tonumber(seedUids[i]) == sid then
                    seedUid = sid
                    fromPlotWatch = true
                    break
                end
            end
            if seedUid > 0 then
                break
            end
        end
        if seedUid <= 0 then
            for pn, sid in pairs(pending.seedsByPlot) do
                sid = tonumber(sid) or 0
                if sid <= 0 then
                    sid = StockPiler2.SeedMap.ResolvePlotSeed(tonumber(pn) or 0, 0)
                end
                if sid > 0 then
                    seedUid = sid
                    fromPlotWatch = true
                    break
                end
            end
        end
    end
    if seedUid <= 0 and primaryUid > 0 then
        local primaryData = LookupItemData(primaryUid)
        seedUid = InferSeedUidForPlantHarvest(primaryUid, primaryData and primaryData.name or nil)
    end

    -- Trust seeds from cultivation plot watch / memory (not name inference).
    local trusted = false
    if seedUid > 0 and fromPlotWatch then
        trusted = true
    elseif seedUid > 0 and type(pending.seedsByPlot) == "table" then
        for _, sid in pairs(pending.seedsByPlot) do
            if tonumber(sid) == seedUid then
                trusted = true
                break
            end
        end
    end

    StockPiler2.SeedMap._pendingHarvest = nil
    if plotNum > 0 then
        StockPiler2.SeedMap.ClearPlotSeed(plotNum)
    end
    if type(pending.seedsByPlot) == "table" then
        for pnKey, _ in pairs(pending.seedsByPlot) do
            StockPiler2.SeedMap.ClearPlotSeed(tonumber(pnKey) or 0)
        end
    end

    if seedUid > 0 then
        local harvestProducts = {}
        local productParts = {}
        for uid, change in pairs(deltas) do
            uid = tonumber(uid) or 0
            if uid > 0 and change > 0 and not IsSeedOrSporeItem(LookupItemData(uid))
                and not StockPiler2.SeedMap.IsResinUid(uid)
                and IsCraftingItem(LookupItemData(uid))
            then
                harvestProducts[uid] = change
                local item = LookupItemData(uid)
                productParts[#productParts + 1] = ToNarrow(item and item.name or uid)
                    .. "x" .. tostring(change)
            end
        end
        local chatCues = nil
        if StockPiler2.CraftChat and StockPiler2.CraftChat.TakeCues then
            chatCues = StockPiler2.CraftChat.TakeCues()
        end
        local critOk, critFail, specialMoment = StockPiler2.SeedMap.RecordHarvestChatCues(
            seedUid,
            chatCues,
            pending
        )
        -- Main growable plant only (skip resin / vials / other non-growables).
        if StockPiler2.Grow and StockPiler2.Grow.NotifyHarvestOutcome then
            local outName = nil
            local outCount = 0
            if type(chatCues) == "table" and chatCues.harvestedName ~= nil then
                local chatUid = 0
                if StockPiler2.SeedMap.FindPlantUidByHarvestName then
                    chatUid = tonumber(StockPiler2.SeedMap.FindPlantUidByHarvestName(chatCues.harvestedName)) or 0
                end
                -- Use chat name when unresolved, or when the resolved uid is growable.
                if chatUid <= 0 or IsEligibleHarvestProductUid(chatUid, seedUid) then
                    outName = chatCues.harvestedName
                    outCount = tonumber(chatCues.harvestedCount) or 0
                end
            end
            if (outName == nil or outName == L"" or outName == "")
                and primaryUid > 0
                and IsEligibleHarvestProductUid(primaryUid, seedUid)
            then
                local primaryItem = LookupItemData(primaryUid)
                outName = primaryItem and primaryItem.name or nil
                outCount = primaryDelta
            end
            if critFail == true then
                StockPiler2.Grow.NotifyHarvestOutcome(plotNum, { critFail = true })
            elseif outName ~= nil and outName ~= L"" and outName ~= "" then
                StockPiler2.Grow.NotifyHarvestOutcome(plotNum, {
                    name = outName,
                    count = outCount,
                })
            end
        end
        local chatPlantUids = {}
        if type(chatCues) == "table" and chatCues.harvestedName then
            local chatUid = StockPiler2.SeedMap.FindPlantUidByHarvestName(chatCues.harvestedName)
            if chatUid > 0 then
                chatPlantUids[chatUid] = true
            end
        end
        local allowedProducts = {}
        for uid, change in pairs(harvestProducts) do
            uid = tonumber(uid) or 0
            if uid > 0 and HarvestPairAllowed(seedUid, uid, {
                expectedPlantUid = primaryUid,
                relatedToPlantUid = primaryUid,
                chatPlantUids = chatPlantUids,
                allowExisting = true,
                plotTrusted = trusted == true,
            }) then
                allowedProducts[uid] = change
            else
                local item = LookupItemData(uid)
                D("SeedMap harvest skip unrelated plantUid=" .. tostring(uid)
                    .. " seedUid=" .. tostring(seedUid)
                    .. " plant=" .. ToNarrow(item and item.name or uid))
            end
        end
        -- Chat missed Special Moment but a non-primary plant still arrived.
        if specialMoment ~= true and primaryUid > 0 then
            for uid, _ in pairs(allowedProducts) do
                uid = tonumber(uid) or 0
                if uid > 0 and uid ~= primaryUid then
                    StockPiler2.SeedMap.NoteSpecialMomentHit(seedUid)
                    specialMoment = true
                    break
                end
            end
        end
        if trusted then
            -- Plot seed is known; record all eligible crafting plants (base + Special Moment).
            StockPiler2.SeedMap.ObserveHarvest(seedUid, allowedProducts, true, true, primaryUid, true)
            local learnedAny = false
            for uid, _ in pairs(allowedProducts) do
                uid = tonumber(uid) or 0
                local item = LookupItemData(uid)
                if uid > 0 and IsCraftingItem(item) and not StockPiler2.SeedMap.IsResinUid(uid)
                    and IsEligibleHarvestProductUid(uid, seedUid)
                then
                    local learned = StockPiler2.SeedMap.LearnMapping(
                        uid,
                        seedUid,
                        "harvest",
                        true,
                        primaryUid,
                        true
                    )
                    if learned then
                        learnedAny = true
                    end
                    -- Only attach seed link for real cultivation plants (not butcher/vial noise).
                    if type(item) == "table" and StockPiler2.SeedMap.RegisterFromItem then
                        if item.isRefinable == true
                            or (tonumber(item.cultivationType) or 0) ~= 0
                            or #EngineSeedUidsForPlant(uid) > 0
                            or uid == primaryUid
                        then
                            StockPiler2.SeedMap.RegisterFromItem(item, seedUid)
                        else
                            StockPiler2.SeedMap.RegisterFromItem(item, nil)
                        end
                    end
                end
            end
            local productCount = 0
            for _ in pairs(allowedProducts) do
                productCount = productCount + 1
            end
            D("SeedMap harvest plantUid=" .. tostring(primaryUid)
                .. " seedUid=" .. tostring(seedUid)
                .. " products=" .. tostring(productCount)
                .. " learned=" .. tostring(learnedAny)
                .. " trusted=true"
                .. " chatCritOk=" .. tostring(critOk == true)
                .. " chatCritFail=" .. tostring(critFail == true))
        else
            StockPiler2.SeedMap.ObserveHarvest(seedUid, allowedProducts, true, false, primaryUid)
            local primaryData = LookupItemData(primaryUid)
            if IsCraftingItem(primaryData) and not StockPiler2.SeedMap.IsResinUid(primaryUid)
                and IsEligibleHarvestProductUid(primaryUid, seedUid)
            then
                local learned = StockPiler2.SeedMap.LearnMapping(
                    primaryUid,
                    seedUid,
                    "harvest",
                    false,
                    primaryUid
                )
                if type(primaryData) == "table" then
                    StockPiler2.SeedMap.RegisterFromItem(primaryData, seedUid)
                end
                D("SeedMap harvest plantUid=" .. tostring(primaryUid)
                    .. " seedUid=" .. tostring(seedUid)
                    .. " learned=" .. tostring(learned == true)
                    .. " trusted=false"
                    .. " chatCritOk=" .. tostring(critOk == true)
                    .. " chatCritFail=" .. tostring(critFail == true))
            end
        end
        local yield = 1
        if StockPiler2.SeedMap.ExpectedHarvestYield then
            yield = StockPiler2.SeedMap.ExpectedHarvestYield(seedUid, primaryUid) or 1
        end
        local garden = ""
        if StockPiler2.AutoGrow and StockPiler2.AutoGrow.GardenSummary then
            garden = " " .. StockPiler2.AutoGrow.GardenSummary()
        end
        if StockPiler2.LogOp then
            StockPiler2.LogOp("harvest", string.format(
                "done P%d seedUid=%d plantUid=%d gained=%d products=%s critOk=%s critFail=%s yieldAvg=%.2f%s",
                tonumber(pending.plotNum) or 0,
                seedUid,
                primaryUid,
                tonumber(primaryDelta) or 0,
                (#productParts > 0) and table.concat(productParts, ",") or "none",
                tostring(critOk == true),
                tostring(critFail == true),
                tonumber(yield) or 1,
                garden
            ))
        end
    end

    return done(true)
end

function StockPiler2.SeedMap.ObserveMatFromRefine(plantUid, seedUid)
    plantUid = tonumber(plantUid) or 0
    seedUid = tonumber(seedUid) or 0
    local plantData = LookupItemData(plantUid)
    if type(plantData) == "table" then
        UpsertItem(plantData, "mat")
        StockPiler2.SeedMap.RegisterFromItem(plantData, seedUid)
    end
    local seedData = LookupItemData(seedUid)
    if type(seedData) == "table" then
        local kind = ProductKindForItem(seedData)
        UpsertItem(seedData, (kind == "spore") and "spore" or "seed")
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
    local seedType = CultivationSeedType()
    local sporeType = CultivationSporeType()
    local uid = tonumber(itemData.uniqueID) or 0

    if cultType == seedType or cultType == sporeType then
        UpsertItem(itemData, (cultType == sporeType) and "spore" or "seed")
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
        UpsertItem(itemData, "mat")
        local plantUid = uid
        local seedUid = tonumber(linkedUid) or 0
        if seedUid <= 0 and plantUid > 0 then
            local seedUids = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
            seedUid = StockPiler2.SeedMap.PickBestSeedUid(plantUid, seedUids)
        end
        if seedUid > 0 and plantUid > 0 then
            local seedData = LookupItemData(seedUid)
            if type(seedData) == "table" then
                local kind = ProductKindForItem(seedData)
                UpsertItem(seedData, (kind == "spore") and "spore" or "seed")
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
    local plantData = LookupItemData(plantUid)
    if type(plantData) ~= "table" then
        return false
    end
    -- Do not create empty refine rows for butcher / non-cultivation recipe mats.
    if not IsEligibleHarvestProductUid(plantUid, 0)
        and plantData.isRefinable ~= true
        and (tonumber(plantData.cultivationType) or 0) == 0
        and #EngineSeedUidsForPlant(plantUid) == 0
    then
        UpsertItem(plantData, "mat")
        return false
    end
    EnsureRefineEntry(plantUid)
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

local GROW_REPAIR_ROLES = {
    main = true,
    stabilizer = true,
    goldweed = true,
    extender = true,
    multiplier = true,
    stimulant = true,
}

local function IsCultivatablePlantItem(item)
    if type(item) ~= "table" or IsSeedOrSporeItem(item) then
        return false
    end
    if item.isRefinable == true then
        return true
    end
    -- Engine seed list only — do not use polluted grows (circular).
    local uid = tonumber(item.uniqueID) or 0
    if uid > 0 and #EngineSeedUidsForPlant(uid) > 0 then
        return true
    end
    return false
end

--- Refinable plants, Liniment-style non-refinable harvest (ct set or brew-learned main),
--- or producers with a known seed map. Butcher mats (Armor Scales, Zoic Gore, Chitin, …) never
--- count as grow producers even when ProductMatches a cult plant or brew-learned main.
local function IsGrowProducerItemForSpec(item)
    if type(item) ~= "table" or IsSeedOrSporeItem(item) then
        return false
    end
    local nameNarrow = item.nameNarrow or ToNarrow(item.name)
    if nameNarrow ~= "" and LooksButchering(nameNarrow) then
        return false
    end
    if IsCultivatablePlantItem(item) then
        return true
    end
    local ct = tonumber(item.cultivationType) or 0
    if ct ~= 0 then
        return true
    end
    local uid = tonumber(item.uniqueID) or 0
    if uid > 0 then
        if #EngineSeedUidsForPlant(uid) > 0 then
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
local function IsCultivationLinkedProducer(item)
    if type(item) ~= "table" or IsSeedOrSporeItem(item) then
        return false
    end
    local nameNarrow = item.nameNarrow or ToNarrow(item.name)
    if nameNarrow ~= "" and LooksButchering(nameNarrow) then
        return false
    end
    if IsCultivatablePlantItem(item) then
        return true
    end
    local ct = tonumber(item.cultivationType) or 0
    if ct ~= 0 then
        return true
    end
    local uid = tonumber(item.uniqueID) or 0
    return uid > 0 and #EngineSeedUidsForPlant(uid) > 0
end

function StockPiler2.SeedMap.FindPlantUidForSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return 0
    end
    local MS = StockPiler2.MaterialSpec
    local cacheKey = (MS.ProductKey and MS.ProductKey(spec)) or (MS.Key and MS.Key(spec)) or ""
    local cached, hit = PlanCacheGet("plantUid", cacheKey)
    if hit then
        return tonumber(cached) or 0
    end
    local bestUid = 0

    -- Cheap paths first: grows/Items ProductKey (EFFECT-less bag plants fail ProductMatches).
    local fromCache = StockPiler2.SeedMap.CachedPlantUidForSpec and StockPiler2.SeedMap.CachedPlantUidForSpec(spec) or 0
    if fromCache > 0 then
        PlanCacheSet("plantUid", cacheKey, fromCache)
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
            itemData = LookupItemData(uid)
        end
        if type(itemData) == "table" then
            if MS.ProductMatches and MS.ProductMatches(itemData, spec) and IsGrowProducerItemForSpec(itemData) then
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

    local items = AccountTable("items")
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
                            if IsGrowProducerItemForSpec(StockPiler2.Items.AsItemData(uid) or row) then
                                bestUid = uid
                            end
                        elseif MS.ProductMatches then
                            local asItem = StockPiler2.Items.AsItemData(uid)
                            if type(asItem) == "table" and MS.ProductMatches(asItem, spec)
                                and IsGrowProducerItemForSpec(asItem)
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
        PlanCacheSet("plantUid", cacheKey, bestUid)
        return bestUid
    end

    local grows = AccountTable("grows")
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
        PlanCacheSet("plantUid", cacheKey, bestUid)
        return bestUid
    end

    local recipes = AccountTable("recipes")
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
        PlanCacheSet("plantUid", cacheKey, bestUid)
        return bestUid
    end

    -- Bag walk last: live refinable plant vs butcher substitute when learned data is empty.
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem and MS.ProductMatches then
        StockPiler2.Inventory.ForEachItem(function(item)
            if type(item) == "table" and MS.ProductMatches(item, spec) and IsGrowProducerItemForSpec(item) then
                local uid = tonumber(item.uniqueID) or 0
                if uid > 0 then
                    bestUid = uid
                end
            end
        end)
    end
    PlanCacheSet("plantUid", cacheKey, bestUid)
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
    local items = AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind ~= "seed" and row.kind ~= "spore" and row.kind ~= "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uid > 0 then
                local itemSpec = StockPiler2.Items.ToSpec(uid)
                if type(itemSpec) == "table" then
                    local itemKey = (MS.ProductKey and MS.ProductKey(itemSpec)) or MS.Key(itemSpec)
                    if itemKey == specKey
                        and IsGrowProducerItemForSpec(StockPiler2.Items.AsItemData(uid) or row)
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
    local record = BuildSeedRecord(seedUid, "plant", plantUid)
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
        local itemData = LookupItemData(uid)
        if type(itemData) == "table" and MS.ProductMatches and MS.ProductMatches(itemData, spec) then
            return true
        end
        return false
    end

    local grows = AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            local seedUid = tonumber(seedKey) or 0
            for plantUidKey, row in pairs(plants) do
                if type(row) == "table" and uidMatches(plantUidKey) then
                    local plantUid = tonumber(plantUidKey) or 0
                    if seedUid > 0 and HarvestPairAllowed(seedUid, plantUid, {}) then
                        return plantUid
                    end
                end
            end
        end
    end

    local items = AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind ~= "seed" and row.kind ~= "spore" and row.kind ~= "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uidMatches(uid) then
                local asItem = (StockPiler2.Items and StockPiler2.Items.AsItemData and StockPiler2.Items.AsItemData(uid))
                    or LookupItemData(uid)
                    or row
                -- Prefer cultivatable plants; butcher substitutes are not grow producers.
                if IsCultivatablePlantItem(asItem) then
                    return uid
                end
            end
        end
    end

    local refines = AccountTable("refines")
    for plantKeyUid, entry in pairs(refines) do
        if type(entry) == "table" and (tonumber(entry.seedUid) or 0) > 0 and uidMatches(plantKeyUid) then
            return tonumber(plantKeyUid) or 0
        end
    end

    local recipes = AccountTable("recipes")
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
            if type(item) == "table" and IsSeedOrSporeItem(item) then
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
    if not SeedMatchesGrowSpec then
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
    local index = StockPiler2.SeedMap.EnsureBagSeedIndex()
    for i = 1, #index do
        local item = index[i]
        if StockPiler2.Inventory.CanUseCraftingItem
            and not StockPiler2.Inventory.CanUseCraftingItem(item)
        then
            -- skip unusable
        elseif SeedMatchesGrowSpec(item, spec, expectedPlant) then
            total = total + ItemStackCount(item)
        end
    end
    return total
end

--- Prefer live bag stacks over a cached uniqueID that may be empty or stale.
function StockPiler2.SeedMap.FindSeedInBagsForPlantSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return nil
    end
    if not SeedMatchesGrowSpec then
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
    local bestCount = 0
    local index = StockPiler2.SeedMap.EnsureBagSeedIndex()
    for i = 1, #index do
        local item = index[i]
        local seedUid = tonumber(item.uniqueID) or 0
        if seedUid > 0 then
            local ok, plantUid = SeedMatchesGrowSpec(item, spec, expectedPlant)
            if ok
                and (not StockPiler2.Inventory.CanUseCraftingItem
                    or StockPiler2.Inventory.CanUseCraftingItem(item))
            then
                local stack = ItemStackCount(item)
                if stack > bestCount or (stack == bestCount and (bestUid <= 0 or seedUid < bestUid)) then
                    bestCount = stack
                    bestUid = seedUid
                    bestPlant = (tonumber(plantUid) or 0) > 0 and plantUid or expectedPlant
                end
            end
        end
    end
    if bestUid <= 0 then
        return nil
    end
    return BuildSeedRecord(bestUid, "bags", bestPlant)
end

function StockPiler2.SeedMap.RepairFromLearnedRecipes()
    local seen = {}
    local repaired = 0
    local recipes = AccountTable("recipes")
    for _, recipe in pairs(recipes) do
        if type(recipe) == "table" and type(recipe.slots) == "table" then
            for i = 1, #recipe.slots do
                local slot = recipe.slots[i]
                if type(slot) == "table" and GROW_REPAIR_ROLES[slot.role] then
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
    ClearAccountTable("grows")
    ClearAccountTable("refines")
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

local function SpecHasGoldweedMultiplier(spec)
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
local function SpecLinkedToGrowOrRefine(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return false
    end
    local MS = StockPiler2.MaterialSpec
    local plantKey = (MS.ProductKey and MS.ProductKey(spec)) or MS.Key(spec)
    if plantKey == "" then
        return false
    end
    local cached, hit = PlanCacheGet("linked", plantKey)
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
        return LookupItemData(uid)
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
        local nameNarrow = itemData.nameNarrow or ToNarrow(itemData.name)
        if nameNarrow ~= "" and LooksButchering(nameNarrow) then
            return false
        end
        if not IsCultivationLinkedProducer(itemData) then
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

    local grows = AccountTable("grows")
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
                        PlanCacheSet("linked", plantKey, true)
                        return true
                    end
                end
            end
        end
    end

    local refines = AccountTable("refines")
    for plantUidKey, entry in pairs(refines) do
        if type(entry) == "table" and (tonumber(entry.seedUid) or 0) > 0 and uidMatches(plantUidKey) then
            PlanCacheSet("linked", plantKey, true)
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
            PlanCacheSet("linked", plantKey, true)
            return true
        end
    end
    PlanCacheSet("linked", plantKey, false)
    return false
end

--- Butcher-only product sample for this fingerprint (no cult plant among matches).
--- Recipe slots learned with Armor Scales / Zoic Gore / Chitin stay butcher even if a
--- ProductMatches cult plant exists elsewhere in Items/grows.
--- Goldweed in bags/account alongside Zoic keeps the shared stabilizer growable.
local function SpecLooksButchering(spec)
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
        local nameNarrow = item.nameNarrow or ToNarrow(item.name)
        if nameNarrow ~= "" and LooksButchering(nameNarrow) then
            sawButcher = true
            if fromRecipe then
                recipeButcher = true
            end
            return
        end
        if IsCultivationLinkedProducer(item) then
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

    local items = AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind ~= "seed" and row.kind ~= "spore" and row.kind ~= "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            local asItem = (StockPiler2.Items and StockPiler2.Items.AsItemData and StockPiler2.Items.AsItemData(uid))
                or LookupItemData(uid)
                or row
            consider(asItem, false)
        end
    end

    local recipes = AccountTable("recipes")
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
                            or LookupItemData(uid)
                        if keyMatch and type(asItem) == "table" then
                            local nameNarrow = asItem.nameNarrow or ToNarrow(asItem.name)
                            if nameNarrow ~= "" and LooksButchering(nameNarrow) then
                                sawButcher = true
                                recipeButcher = true
                            elseif IsGrowProducerItemForSpec(asItem) then
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

local function SpecHasGrowProducer(spec)
    return SpecLinkedToGrowOrRefine(spec)
end

function StockPiler2.SeedMap.MarkHarvestByproduct(spec, source, uniqueID)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return false
    end
    -- Goldweed (and butcher substitutes like Zoic Gore) share +stab/+multiplier.
    -- Resin convert extras do not.
    if SpecHasGoldweedMultiplier(spec) or SpecHasGrowProducer(spec) then
        return false
    end
    uniqueID = tonumber(uniqueID) or 0
    if uniqueID <= 0 then
        return false
    end
    local itemData = LookupItemData(uniqueID)
    if type(itemData) == "table" then
        UpsertItem(itemData, "resin")
    elseif StockPiler2.Items and StockPiler2.Items.Upsert then
        StockPiler2.Items.Upsert(uniqueID, { kind = "resin" })
    end
    D("SeedMap harvest byproduct uid=" .. tostring(uniqueID)
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
    local cached, hit = PlanCacheGet("byproduct", key)
    if hit then
        return cached == true
    end
    local function finish(result)
        PlanCacheSet("byproduct", key, result == true)
        return result == true
    end
    if SpecHasGoldweedMultiplier(spec) or SpecHasGrowProducer(spec) then
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
        local itemData = LookupItemData(uid)
        return type(itemData) == "table" and MS.Matches and MS.Matches(itemData, spec) == true
    end

    local items = AccountTable("items")
    for uidKey, row in pairs(items) do
        if type(row) == "table" and row.kind == "resin" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            if uidMatchesSpec(uid) then
                return finish(true)
            end
        end
    end

    local refines = AccountTable("refines")
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
    if SpecHasGoldweedMultiplier(spec) or SpecHasGrowProducer(spec) then
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
                itemData = LookupItemData(plantUid)
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
    if cultType == CultivationSeedType() or cultType == CultivationSporeType() then
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
    if ItemNameLooksLikeResin(itemData) or role == "stabilizer" then
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
    local cached, hit = PlanCacheGet("growable", cacheKey)
    if hit then
        return cached == true
    end
    local role = spec.role or ""
    local result = false
    if role ~= "container"
        and not (StockPiler2.SeedMap.IsHarvestByproduct and StockPiler2.SeedMap.IsHarvestByproduct(spec))
        and not SpecLooksButchering(spec)
    then
        result = SpecLinkedToGrowOrRefine(spec) == true
    end
    PlanCacheSet("growable", cacheKey, result)
    return result
end

--- Grow-linked mat with no plant→seed refine path (e.g. Blackbell Bloodseed → Powder).
function StockPiler2.SeedMap.IsOneWayHarvestSpec(spec)
    if type(spec) ~= "table" or not StockPiler2.MaterialSpec then
        return false
    end
    local MS = StockPiler2.MaterialSpec
    local cacheKey = (MS.ProductKey and MS.ProductKey(spec)) or (MS.Key and MS.Key(spec)) or ""
    local cached, hit = PlanCacheGet("oneWay", cacheKey)
    if hit then
        return cached == true
    end

    local function finish(result)
        PlanCacheSet("oneWay", cacheKey, result == true)
        return result == true
    end

    if StockPiler2.SeedMap.IsHarvestByproduct and StockPiler2.SeedMap.IsHarvestByproduct(spec) then
        return finish(false)
    end
    if not SpecLinkedToGrowOrRefine(spec) then
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
    local plantData = LookupItemData(plantUid)
    if type(plantData) == "table" and plantData.isRefinable == true then
        refinable = true
    elseif StockPiler2.Items and StockPiler2.Items.Get then
        local row = StockPiler2.Items.Get(plantUid)
        if type(row) == "table" and row.isRefinable == true then
            refinable = true
        end
    end
    local refines = AccountTable("refines")
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
        local cached, hit = PlanCacheGet("resolveSeed", cacheKey)
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
            local grows = AccountTable("grows")
            local seenPlant = {}
            local seenSeed = {}
            for seedKey, bucket in pairs(grows) do
                if type(bucket) == "table" then
                    local sUid = tonumber(seedKey) or 0
                    for plantKey, row in pairs(bucket) do
                        if type(row) == "table" then
                            local pUid = tonumber(plantKey) or 0
                            if pUid > 0 and sUid > 0 and not seenPlant[pUid]
                                and HarvestPairAllowed(sUid, pUid, {})
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
                                    local itemData = LookupItemData(pUid)
                                    match = type(itemData) == "table" and MS.ProductMatches
                                        and MS.ProductMatches(itemData, spec) == true
                                end
                                if match then
                                    seenPlant[pUid] = true
                                    plantUid = pUid
                                    AddUniqueUid(seedUids, seenSeed, seedKey)
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
                local record = BuildSeedRecord(seedUid, "account", plantUid)
                if type(record) == "table" then
                    result = record
                    break
                end
            end
        end
    end

    if cacheKey ~= "" then
        PlanCacheSet("resolveSeed", cacheKey, result ~= nil and result or false)
    end
    return result
end

function StockPiler2.SeedMap.BootstrapSpecMap()
    if StockPiler2.SeedMap.RepairFromLearnedRecipes then
        return StockPiler2.SeedMap.RepairFromLearnedRecipes() or 0
    end
    return 0
end

function StockPiler2.SeedMap.ForgetUnrelatedLearnedMaps()
    local dropped = 0

    local grows = AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            local seedUid = tonumber(seedKey) or 0
            local seedData = seedUid > 0 and LookupItemData(seedUid) or nil
            if IsResinLikeItem(seedData, seedUid) then
                grows[seedKey] = nil
                dropped = dropped + 1
                D("SeedMap forgot resin grow seedUid=" .. tostring(seedUid))
            else
                local seedIsPacket = StockPiler2.SeedMap.IsSeedPacketUid(seedUid)
                for plantKey, row in pairs(plants) do
                    if type(row) == "table" then
                        local plantUid = tonumber(plantKey) or 0
                        local plantData = plantUid > 0 and LookupItemData(plantUid) or nil
                        local resinPlant = StockPiler2.SeedMap.IsResinUid and StockPiler2.SeedMap.IsResinUid(plantUid)
                        local eligible = IsEligibleHarvestProductUid(plantUid, seedUid)
                        local drop = resinPlant or not eligible
                        -- Packet→standard plant (Bitter→Musty) is name-unrelated by design; keep.
                        if not drop
                            and not seedIsPacket
                            and type(plantData) == "table"
                            and type(seedData) == "table"
                            and not SeedPlantPairRelated(seedData, plantData)
                            and not EngineListsSeedForPlant(plantUid, seedUid)
                            and not StockPiler2.SeedMap.GrowNamesRelated(plantData.name, seedData.name)
                        then
                            drop = true
                        end
                        if drop then
                            plants[plantKey] = nil
                            dropped = dropped + 1
                            D("SeedMap forgot unrelated grow plantUid=" .. tostring(plantUid)
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

    local refines = AccountTable("refines")
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            local plantUid = tonumber(plantKey) or 0
            local seedUid = tonumber(entry.seedUid) or 0
            if plantUid > 0 and seedUid > 0 then
                local plantData = LookupItemData(plantUid)
                local seedData = LookupItemData(seedUid)
                local resinPlant = StockPiler2.SeedMap.IsResinUid and StockPiler2.SeedMap.IsResinUid(plantUid)
                if resinPlant then
                    entry.seedUid = 0
                    entry.seedKind = nil
                    dropped = dropped + 1
                    D("SeedMap forgot unrelated refine plantUid=" .. tostring(plantUid)
                        .. " seedUid=" .. tostring(seedUid))
                elseif StockPiler2.SeedMap.IsSeedPacketUid(seedUid) then
                    -- Packets are never convert output; clear if somehow stored as seedUid.
                    entry.seedUid = 0
                    entry.seedKind = nil
                    dropped = dropped + 1
                    D("SeedMap forgot packet refine seedUid=" .. tostring(seedUid)
                        .. " plantUid=" .. tostring(plantUid))
                elseif type(plantData) == "table" and type(seedData) == "table"
                    and not SeedPlantPairRelated(seedData, plantData)
                then
                    -- Keep refine seed if any byproduct was sampled (observed refine).
                    local keep = false
                    if type(entry.byproducts) == "table" then
                        for _, brow in pairs(entry.byproducts) do
                            if type(brow) == "table" and (tonumber(brow.samples) or 0) > 0 then
                                keep = true
                                break
                            end
                        end
                    end
                    if not keep then
                        entry.seedUid = 0
                        entry.seedKind = nil
                        dropped = dropped + 1
                        D("SeedMap forgot unrelated refine plantUid=" .. tostring(plantUid)
                            .. " seedUid=" .. tostring(seedUid))
                    end
                end
            end
        end
    end
    return dropped
end

local function OutcomeItemName(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return "?"
    end
    local data = LookupItemData(uid)
    local name = ToNarrow(data and data.name)
    if name ~= "" then
        return name
    end
    if StockPiler2.ItemDisplayName then
        name = ToNarrow(StockPiler2.ItemDisplayName(uid, nil))
        if name ~= "" then
            return name
        end
    end
    return tostring(uid)
end

local function FormatOutcomeQty(prod)
    if type(prod) ~= "table" then
        return ""
    end
    if (tonumber(prod.samples) or 0) > 0 then
        return string.format("%.1fx ", OutcomeAvg(prod))
    end
    if (tonumber(prod.last) or 0) > 0 then
        return tostring(prod.last) .. "x "
    end
    return ""
end

local function FormatOutcomeProducts(list)
    local parts = {}
    for i = 1, #list do
        local prod = list[i]
        local uid = tonumber(prod.uid) or 0
        parts[#parts + 1] = FormatOutcomeQty(prod)
            .. OutcomeItemName(uid)
            .. " (" .. tostring(uid) .. ")"
    end
    if #parts == 0 then
        return "(none)"
    end
    return table.concat(parts, ", ")
end

local function DumpGrowsToChat(chatMax)
    local grows = AccountTable("grows")
    local rows = {}
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            local seedUid = tonumber(seedKey) or 0
            local products = StockPiler2.SeedMap.HarvestProducts(seedUid)
            rows[#rows + 1] = {
                uid = seedUid,
                name = OutcomeItemName(seedUid),
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
    D("SeedMap dump " .. header)
    if StockPiler2.Print then
        StockPiler2.Print(towstring(header))
    end
    chatMax = tonumber(chatMax) or 30
    for i = 1, #rows do
        local row = rows[i]
        local line = row.name .. " (" .. tostring(row.uid) .. ") -> "
            .. FormatOutcomeProducts(row.products)
        D("SeedMap " .. line)
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

local function DumpRefinesToChat(chatMax)
    local refines = AccountTable("refines")
    local rows = {}
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            local plantUid = tonumber(plantKey) or 0
            rows[#rows + 1] = {
                uid = plantUid,
                name = OutcomeItemName(plantUid),
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
    D("SeedMap dump " .. header)
    if StockPiler2.Print then
        StockPiler2.Print(towstring(header))
    end
    chatMax = tonumber(chatMax) or 30
    for i = 1, #rows do
        local row = rows[i]
        local line = row.name .. " (" .. tostring(row.uid) .. ") -> "
            .. FormatOutcomeProducts(row.products)
        D("SeedMap " .. line)
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

    local grows = AccountTable("grows")
    local growRows = {}
    for seedKey, bucket in pairs(grows) do
        if type(bucket) == "table" then
            local seedUid = tonumber(seedKey) or 0
            local attempts = tonumber(bucket.harvestAttempts) or 0
            local plants = tonumber(bucket.plantAttempts) or 0
            if attempts > 0 or plants > 0 then
                growRows[#growRows + 1] = {
                    seedUid = seedUid,
                    name = OutcomeItemName(seedUid),
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

    local refines = AccountTable("refines")
    local refineRows = {}
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            local plantUid = tonumber(plantKey) or 0
            local attempts = tonumber(entry.refineAttempts) or 0
            if attempts > 0 or (tonumber(entry.seedUid) or 0) > 0 then
                local seedAvg, seedSamples = StockPiler2.SeedMap.RefineSeedAvg(plantUid)
                refineRows[#refineRows + 1] = {
                    plantUid = plantUid,
                    name = OutcomeItemName(plantUid),
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
    local recipes = AccountTable("recipes")
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
    local growN = DumpGrowsToChat(25)
    local refineN = DumpRefinesToChat(25)
    return growN + refineN
end

--- Prefer engine/bag type; skip Account AsItemData (often itemType=0 until relearned).
local function LiveItemType(uid)
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
    local grows = AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        if type(plants) == "table" then
            for plantKey, row in pairs(plants) do
                if type(row) == "table" then
                    local plantUid = tonumber(plantKey) or 0
                    local t = LiveItemType(plantUid)
                    if t ~= nil and t ~= CraftingItemType() then
                        plants[plantKey] = nil
                        dropped = dropped + 1
                        D("SeedMap pruned non-crafting grow plantUid=" .. tostring(plantUid)
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
    local items = AccountTable("items")
    local remove = {}
    for uidKey, row in pairs(items) do
        if type(row) == "table" then
            local uid = tonumber(row.uniqueID) or tonumber(uidKey) or 0
            local t = LiveItemType(uid)
            local cachedType = tonumber(row.itemType)
            local knownType = t
            if knownType == nil and cachedType ~= nil and cachedType > 0 then
                knownType = cachedType
            end
            -- Wilted-style trash: non-crafting, never a recipe/grow/refine actor.
            local name = string.lower(ToNarrow(row.nameNarrow or row.name))
            local looksWilted = string.find(name, "wilted", 1, true) ~= nil
            if looksWilted or (knownType ~= nil and knownType ~= CraftingItemType()
                and row.kind == "mat" and (tonumber(row.skillReq) or 0) == 0
                and (row.role == "container" or row.role == "ingredient"))
            then
                -- Don't drop real vials/containers used in recipes.
                local inRecipe = false
                local recipes = AccountTable("recipes")
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
        D("SeedMap pruned non-crafting item orphan uid=" .. tostring(remove[i]))
    end
    return dropped
end

function StockPiler2.SeedMap.PruneOrphanRefineByproducts()
    local refines = AccountTable("refines")
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
                    local isResin = IsResinLikeItem(LookupItemData(uid), uid)
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
    return 0
end

