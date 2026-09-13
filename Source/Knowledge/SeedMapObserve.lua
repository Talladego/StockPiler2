----------------------------------------------------------------
-- StockPiler2 SeedMap shared module support
----------------------------------------------------------------

StockPiler2.SeedMap = StockPiler2.SeedMap or {}
local SeedMap = StockPiler2.SeedMap
SeedMap._private = SeedMap._private or {}
local Private = SeedMap._private

function StockPiler2.SeedMap.ObserveHarvest(seedUid, products, sampled, forceRelated, expectedPlantUid, plotTrusted)
    seedUid = tonumber(seedUid) or 0
    forceRelated = forceRelated == true
    expectedPlantUid = tonumber(expectedPlantUid) or 0
    plotTrusted = plotTrusted == true
    if seedUid <= 0 or type(products) ~= "table" then
        return false
    end
    local bucket = Private.EnsureGrowsBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    local seedData = Private.LookupItemData(seedUid)
    if type(seedData) == "table" then
        local kind = Private.ProductKindForItem(seedData)
        Private.UpsertItem(seedData, (kind == "spore") and "spore" or "seed")
    end
    local changed = false
    for uid, count in pairs(products) do
        uid = tonumber(uid) or 0
        count = tonumber(count) or 0
        if uid > 0 and uid ~= seedUid and not StockPiler2.SeedMap.IsResinUid(uid) then
            local item = Private.LookupItemData(uid)
            if not Private.IsCraftingItem(item) then
                -- Ignore harvest trash (Wilted Wild Weed, etc.).
            else
                local kind = Private.ProductKindForItem(item)
                if kind ~= "seed" and kind ~= "spore" and kind ~= "resin" then
                    if not Private.HarvestPairAllowed(seedUid, uid, {
                        expectedPlantUid = expectedPlantUid,
                        relatedToPlantUid = expectedPlantUid,
                        allowExisting = forceRelated,
                        plotTrusted = plotTrusted,
                    }) then
                        Private.D("SeedMap ObserveHarvest skip unrelated plantUid=" .. tostring(uid)
                            .. " seedUid=" .. tostring(seedUid)
                            .. " plant=" .. Private.ToNarrow(item and item.name)
                            .. " seed=" .. Private.ToNarrow(seedData and seedData.name))
                    elseif Private.RecordStat(bucket, uid, count, sampled ~= false) then
                        changed = true
                        if type(item) == "table" then
                            Private.UpsertItem(item, "mat")
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
    local bucket = Private.EnsureGrowsBucket(seedUid)
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
    Private.D("SeedMap harvest chat seedUid=" .. tostring(seedUid)
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
    local bucket = Private.EnsureGrowsBucket(seedUid)
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
    local bucket = Private.EnsureGrowsBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    bucket.plantAttempts = (tonumber(bucket.plantAttempts) or 0) + 1
    return true
end

Private.SKILL_PENDING_TTL_SEC = 8
Private.SKILL_RATE_MIN_ATTEMPTS = 5

--- Arm Cult skill-up attribution for the next TRADE_SKILL_UPDATED (+Cult).
function StockPiler2.SeedMap.ArmCultSkillPending(seedUid, reason)
    seedUid = tonumber(seedUid) or 0
    if seedUid <= 0 then
        return false
    end
    local now = Private.NowSec()
    StockPiler2.SeedMap._pendingCultSkill = {
        seedUid = seedUid,
        reason = tostring(reason or "arm"),
        untilTime = now + Private.SKILL_PENDING_TTL_SEC,
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
    local bucket = Private.EnsureGrowsBucket(seedUid)
    if type(bucket) ~= "table" then
        return false
    end
    bucket.cultSkillHits = (tonumber(bucket.cultSkillHits) or 0) + 1
    return true
end

--- Empirical Cult +1 rate per harvest attempt. nil rate if too few samples.
function StockPiler2.SeedMap.CultSkillUpRate(seedUid)
    local bucket = Private.GrowsBucketStats(seedUid)
    if type(bucket) ~= "table" then
        return nil
    end
    local attempts = tonumber(bucket.harvestAttempts) or 0
    local hits = tonumber(bucket.cultSkillHits) or 0
    if attempts < Private.SKILL_RATE_MIN_ATTEMPTS then
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
    local now = Private.NowSec()
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

--- Pick highest-sample related seedOut uid for a refine entry; clear when none.
function Private.PreferBestRefineSeedUid(plantUid, entry)
    plantUid = tonumber(plantUid) or 0
    if type(entry) ~= "table" or plantUid <= 0 then
        return false
    end
    local plantData = Private.LookupItemData(plantUid)
    local bestUid = 0
    local bestSamples = -1
    local bestKind = "seed"
    if type(entry.seedOut) == "table" then
        for seedKey, row in pairs(entry.seedOut) do
            local seedUid = tonumber(seedKey) or 0
            if seedUid > 0 and type(row) == "table" then
                local samples = tonumber(row.samples) or 0
                local seedData = Private.LookupItemData(seedUid)
                if StockPiler2.SeedMap.IsSeedPacketUid(seedUid) then
                    -- Packets are never convert output.
                elseif type(plantData) == "table" and type(seedData) == "table"
                    and Private.SeedPlantPairRelated(seedData, plantData)
                    and samples > bestSamples
                then
                    bestSamples = samples
                    bestUid = seedUid
                    local kind = Private.ProductKindForItem(seedData)
                    bestKind = (kind == "spore") and "spore" or "seed"
                elseif type(plantData) == "table" and type(seedData) == "table"
                    and not Private.SeedPlantPairRelated(seedData, plantData)
                    and samples <= 0
                then
                    entry.seedOut[seedKey] = nil
                end
            end
        end
    end
    local prev = tonumber(entry.seedUid) or 0
    if bestUid > 0 then
        entry.seedUid = bestUid
        entry.seedKind = bestKind
        return prev ~= bestUid
    end
    if prev > 0 then
        entry.seedUid = 0
        entry.seedKind = nil
        return true
    end
    return false
end

--- Plant convert -> seed/spore plus extras (Arboreal Resin is expected on every convert).
function StockPiler2.SeedMap.ObserveRefine(plantUid, products, sampled)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 or type(products) ~= "table" then
        return false
    end
    local entry = Private.EnsureRefineEntry(plantUid)
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
    local plantData = Private.LookupItemData(plantUid)
    if type(plantData) == "table" then
        Private.UpsertItem(plantData, "mat")
    end
    local changed = false
    for uid, count in pairs(products) do
        uid = tonumber(uid) or 0
        count = tonumber(count) or 0
        if uid > 0 and uid ~= plantUid then
            local item = Private.LookupItemData(uid)
            local kind = Private.ProductKindForItem(item)
            if kind == "seed" or kind == "spore" then
                if StockPiler2.SeedMap.IsSeedPacketItem(item) then
                    -- Vendor packets are not convert output / refine seedUid.
                elseif StockPiler2.SeedMap.PairLooksLikePlantAndSeed(plantUid, uid) then
                    if Private.RecordStat(entry.seedOut, uid, count, sampled ~= false) then
                        changed = true
                    end
                    if type(item) == "table" then
                        Private.UpsertItem(item, kind)
                    end
                    changed = true
                end
            else
                -- Non-seed convert gain: only Arboreal Resin (etc.), never co-timed plants.
                if Private.IsResinLikeItem(item, uid) then
                    if Private.RecordStat(entry.byproducts, uid, count, sampled ~= false) then
                        changed = true
                        if type(item) == "table" then
                            Private.UpsertItem(item, "resin")
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
                    Private.D("SeedMap ObserveRefine skip non-resin extra uid=" .. tostring(uid)
                        .. " plantUid=" .. tostring(plantUid)
                        .. " name=" .. Private.ToNarrow(item and item.name or uid))
                end
            end
        end
    end
    if Private.PreferBestRefineSeedUid(plantUid, entry) then
        changed = true
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
    local grows = Private.AccountTable("grows")
    local bucket = grows[tostring(seedUid)]
    if type(bucket) ~= "table" then
        return list
    end
    for plantKey, row in pairs(bucket) do
        if type(row) == "table" and tonumber(plantKey) then
            list[#list + 1] = Private.StatRowToProduct(plantKey, "plant", row)
        end
    end
    return Private.SortedProductList(list)
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
    local bucket = Private.GrowsBucketStats(seedUid)
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
    local bucket = Private.GrowsBucketStats(seedUid)
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
    local bucket = Private.GrowsBucketStats(seedUid)
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
    local refines = Private.AccountTable("refines")
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
    local bucket = Private.GrowsBucketStats(seedUid)
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
    local refines = Private.AccountTable("refines")
    local entry = refines[tostring(plantUid)]
    if type(entry) ~= "table" then
        return list
    end
    local seedUid = tonumber(entry.seedUid) or 0
    if seedUid > 0 then
        list[#list + 1] = Private.StatRowToProduct(seedUid, entry.seedKind or "seed", {
            samples = 0,
            countSum = 0,
            last = 0,
        })
    end
    if type(entry.byproducts) == "table" then
        for resinKey, row in pairs(entry.byproducts) do
            if type(row) == "table" then
                list[#list + 1] = Private.StatRowToProduct(resinKey, "resin", row)
            end
        end
    end
    return Private.SortedProductList(list)
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
    if Private.ItemNameLooksLikeResin(Private.LookupItemData(uid)) then
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
            itemData = Private.LookupItemData(plantUid)
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

    local refines = Private.AccountTable("refines")
    for plantKey, entry in pairs(refines) do
        if type(entry) == "table" then
            consider(tonumber(plantKey), entry.seedUid)
        end
    end
    local grows = Private.AccountTable("grows")
    for seedKey, plants in pairs(grows) do
        local seedUid = tonumber(seedKey) or 0
        if type(plants) == "table" then
            for plantKey in pairs(plants) do
                consider(tonumber(plantKey), seedUid)
            end
        end
    end
    if StockPiler2.Inventory and StockPiler2.Inventory.ForEachItem then
        local seedType = Private.CultivationSeedType()
        local sporeType = Private.CultivationSporeType()
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
    local refines = Private.AccountTable("refines")
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
    local grows = Private.AccountTable("grows")
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

function Private.ItemStackCount(item)
    return tonumber(item.stackCount) or tonumber(item.StackCount) or 1
end

function Private.IsSeedOrSporeItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local cultType = tonumber(itemData.cultivationType) or 0
    return cultType == Private.CultivationSeedType() or cultType == Private.CultivationSporeType()
end

-- Plants that convert to seeds are often ct=0 apo mains. Molotov convert
-- junk (Smoking Pyre Ivy) is also isRefinable with ct=0. Butcher multipliers
-- (e.g. Special Squig Bits) can be wrongly flagged isRefinable too — after a
-- failed convert we persist refineConvertFailed and skip them.
-- Proven plant→seed lines (seedOut samples / mapped seeds) only get a session
-- cooldown; sticky SV blacklist was idling AutoGrow after false no-convert.

StockPiler2.SeedMap._refineConvertFailed = StockPiler2.SeedMap._refineConvertFailed or {}
StockPiler2.SeedMap._refineConvertFailedUntil = StockPiler2.SeedMap._refineConvertFailedUntil or {}
StockPiler2.SeedMap.REFINE_CONVERT_FAIL_COOLDOWN_SEC = 45

function Private.HasProvenSeedConvert(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return false
    end
    local refines = Private.AccountTable("refines")
    local entry = refines[tostring(plantUid)]
    if type(entry) == "table" and type(entry.seedOut) == "table" then
        for _, row in pairs(entry.seedOut) do
            if type(row) == "table" and (tonumber(row.samples) or 0) > 0 then
                return true
            end
        end
    end
    local uids = StockPiler2.SeedMap.GetSeedUidsForPlant(plantUid)
    if type(uids) == "table" and #uids > 0 then
        return true
    end
    return false
end

function Private.ClearStickyRefineConvertFailed(plantUid)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return
    end
    if type(StockPiler2.SeedMap._refineConvertFailed) == "table" then
        StockPiler2.SeedMap._refineConvertFailed[plantUid] = nil
    end
    if type(StockPiler2.SeedMap._refineConvertFailedUntil) == "table" then
        StockPiler2.SeedMap._refineConvertFailedUntil[plantUid] = nil
    end
    if StockPiler2.Items and StockPiler2.Items.Get then
        local row = StockPiler2.Items.Get(plantUid)
        if type(row) == "table" and row.refineConvertFailed ~= nil then
            row.refineConvertFailed = nil
        end
    end
end

function StockPiler2.SeedMap.HasProvenSeedConvert(plantUid)
    return Private.HasProvenSeedConvert(plantUid)
end

function StockPiler2.SeedMap.ClearStickyRefineConvertFailed(plantUid)
    Private.ClearStickyRefineConvertFailed(plantUid)
end

function StockPiler2.SeedMap.IsRefineConvertFailed(uid)
    uid = tonumber(uid) or 0
    if uid <= 0 then
        return false
    end
    local untilT = 0
    if type(StockPiler2.SeedMap._refineConvertFailedUntil) == "table" then
        untilT = tonumber(StockPiler2.SeedMap._refineConvertFailedUntil[uid]) or 0
    end
    if untilT > 0 then
        local now = Private.NowSec()
        if now > 0 and now < untilT then
            return true
        end
        StockPiler2.SeedMap._refineConvertFailedUntil[uid] = nil
    end
    -- Proven plant→seed: never honor sticky Items flag (false no-convert thrash).
    if Private.HasProvenSeedConvert(uid) then
        return false
    end
    if type(StockPiler2.SeedMap._refineConvertFailed) == "table"
        and StockPiler2.SeedMap._refineConvertFailed[uid] == true
    then
        return true
    end
    if StockPiler2.Items and StockPiler2.Items.Get then
        local row = StockPiler2.Items.Get(uid)
        if type(row) == "table" and row.refineConvertFailed == true then
            return true
        end
    end
    return false
end

function StockPiler2.SeedMap.MarkRefineConvertFailed(plantUid, reason)
    plantUid = tonumber(plantUid) or 0
    if plantUid <= 0 then
        return
    end
    if Private.HasProvenSeedConvert(plantUid) then
        -- Session cooldown only — do not permanently blacklist known converts.
        Private.ClearStickyRefineConvertFailed(plantUid)
        local sec = tonumber(StockPiler2.SeedMap.REFINE_CONVERT_FAIL_COOLDOWN_SEC) or 45
        local untilT = Private.NowSec() + sec
        if type(StockPiler2.SeedMap._refineConvertFailedUntil) ~= "table" then
            StockPiler2.SeedMap._refineConvertFailedUntil = {}
        end
        local cur = tonumber(StockPiler2.SeedMap._refineConvertFailedUntil[plantUid]) or 0
        if untilT > cur then
            StockPiler2.SeedMap._refineConvertFailedUntil[plantUid] = untilT
        end
        Private.D("SeedMap refine convert cooldown plantUid=" .. tostring(plantUid)
            .. " reason=" .. tostring(reason or "?")
            .. " until=" .. tostring(untilT))
        return
    end
    if type(StockPiler2.SeedMap._refineConvertFailed) ~= "table" then
        StockPiler2.SeedMap._refineConvertFailed = {}
    end
    StockPiler2.SeedMap._refineConvertFailed[plantUid] = true
    if StockPiler2.Items and StockPiler2.Items.Upsert then
        StockPiler2.Items.Upsert(plantUid, { refineConvertFailed = true })
    end
    Private.D("SeedMap refine convert failed plantUid=" .. tostring(plantUid)
        .. " reason=" .. tostring(reason or "?"))
end

function StockPiler2.SeedMap.ItemLooksLikeRefinablePlant(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    if itemData.isRefinable ~= true then
        return false
    end
    local uid = tonumber(itemData.uniqueID) or tonumber(itemData.id) or 0
    if StockPiler2.SeedMap.IsRefineConvertFailed(uid) then
        return false
    end
    if Private.IsSeedOrSporeItem(itemData) then
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

function Private.IsPotionBagItem(itemData)
    if type(itemData) ~= "table" then
        return false
    end
    local t = tonumber(itemData.type) or tonumber(itemData.itemType)
    if GameData and GameData.ItemTypes and GameData.ItemTypes.POTION then
        return t == GameData.ItemTypes.POTION
    end
    return t == 31
end

--- Live craft + inventory mat counts without InvalidateSnapshot / itemsDirty.
--- Prefer Inventory slots when ready (avoids walking all L0 uids /
--- dual DataUtils bag scans on harvest complete).
--- Includes inventory: craft-bag overflow still lands as ItemTypes.CRAFTING.
function Private.SnapshotCraftingMatCounts()
    local counts = {}
    local function addItem(item)
        if type(item) ~= "table" then
            return
        end
        -- Only CRAFTING (34): skip inventory trash like Wilted Wild Weed (NONE).
        if Private.IsCraftingItem(item) and not Private.IsPotionBagItem(item) then
            local uid = tonumber(item.uniqueID) or 0
            if uid > 0 then
                counts[uid] = (counts[uid] or 0) + Private.ItemStackCount(item)
            end
        end
    end
    local Inv = StockPiler2.Inventory
    if Inv and Inv._ready == true and type(Inv._itemBySlot) == "table" then
        local craft = Inv._itemBySlot.craft
        local main = Inv._itemBySlot.main
        if type(craft) == "table" then
            for _, item in pairs(craft) do
                addItem(item)
            end
        end
        if type(main) == "table" then
            for _, item in pairs(main) do
                addItem(item)
            end
        end
        -- Trust Inventory when ready even if both bags empty.
        if type(craft) == "table" or type(main) == "table" then
            return counts
        end
    end
    local function addBag(getter, label)
        if type(getter) ~= "function" then
            return false
        end
        local ok, data = StockPiler2.TryCallQuiet(label, getter)
        if ok and type(data) == "table" then
            for _, item in pairs(data) do
                addItem(item)
            end
            return true
        end
        return false
    end
    if DataUtils then
        addBag(DataUtils.GetCraftingItems, "DataUtils.GetCraftingItems")
        addBag(DataUtils.GetItems, "DataUtils.GetItems")
    else
        addBag(GetCraftingItemData, "GetCraftingItemData")
        addBag(GetInventoryItemData, "GetInventoryItemData")
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
        plantName = Private.ToNarrow(itemData.name),
        expectedSeeds = expected,
        countsBefore = Private.SnapshotCraftingMatCounts(),
        started = Private.NowSec(),
    }
end

function StockPiler2.SeedMap.MaybeCompletePendingRefine()
    local pending = StockPiler2.SeedMap._pendingRefine
    if type(pending) ~= "table" then
        return false
    end
    local started = tonumber(pending.started) or 0
    local now = Private.NowSec()
    local plantUid = tonumber(pending.plantUid) or 0
    local function fail(reason)
        local expectedSeed = 0
        if type(pending.expectedSeeds) == "table" then
            expectedSeed = tonumber(pending.expectedSeeds[1]) or 0
        end
        expectedSeed = tonumber(pending.confirmedSeedUid) or expectedSeed
        StockPiler2.SeedMap.MarkRefineConvertFailed(plantUid, reason)
        StockPiler2.SeedMap._pendingRefine = nil
        return {
            failed = true,
            plantUid = plantUid,
            seedUid = expectedSeed,
            reason = tostring(reason or "fail"),
        }
    end
    if plantUid <= 0 then
        StockPiler2.SeedMap._pendingRefine = nil
        return false
    end
    if started > 0 and now > 0 and (now - started) > 8 then
        return fail("timeout")
    end

    local countsAfter = Private.SnapshotCraftingMatCounts()
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
    local anySeedGain = false

    for uid, afterCount in pairs(countsAfter) do
        uid = tonumber(uid) or 0
        local prior = tonumber(before[uid]) or 0
        local change = afterCount - prior
        if uid > 0 and change > 0 then
            local item = Private.LookupItemData(uid)
            if Private.IsSeedOrSporeItem(item) then
                anySeedGain = true
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

    local plantAfter = tonumber(countsAfter[plantUid]) or 0
    local plantBefore = tonumber(before[plantUid]) or 0
    -- Fast-fail: convert did nothing (common for false isRefinable butcher mats).
    if started > 0 and now > 0 and (now - started) >= 1.5
        and plantAfter >= plantBefore
        and anySeedGain ~= true
        and seedUid <= 0
    then
        return fail("no-convert")
    end

    if seedUid <= 0 or delta <= 0 then
        return false
    end

    if plantAfter >= plantBefore then
        return false
    end

    -- Seed often lands one inventory event before Arboreal Resin. Hold the
    -- watch briefly so the byproduct delta is included in the same observe.
    local hasResin = false
    for uid, _ in pairs(extras) do
        local item = Private.LookupItemData(uid)
        if Private.ItemNameLooksLikeResin(item)
            or (StockPiler2.SeedMap.IsResinUid and StockPiler2.SeedMap.IsResinUid(uid))
            or (type(item) == "table" and not Private.IsSeedOrSporeItem(item))
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
            Private.D("SeedMap refine waiting for resin plantUid=" .. tostring(plantUid)
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
            local item = Private.LookupItemData(uid)
            if not Private.IsSeedOrSporeItem(item) and Private.IsResinLikeItem(item, uid) then
                refineProducts[uid] = change
                if StockPiler2.MaterialSpec and type(item) == "table" then
                    local spec = StockPiler2.MaterialSpec.FromItemData(item)
                    if type(spec) == "table" then
                        StockPiler2.SeedMap.MarkHarvestByproduct(spec, "refine", uid)
                        Private.D("SeedMap refine extra uid=" .. tostring(uid)
                            .. " +" .. tostring(change)
                            .. " spec=" .. tostring(StockPiler2.MaterialSpec.Key(spec)))
                    end
                else
                    Private.D("SeedMap refine extra uid=" .. tostring(uid) .. " +" .. tostring(change))
                end
            elseif not Private.IsSeedOrSporeItem(item) then
                Private.D("SeedMap refine skip non-resin extra uid=" .. tostring(uid)
                    .. " +" .. tostring(change)
                    .. " name=" .. Private.ToNarrow(item and item.name or uid))
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

function Private.PlotSeedUid(plotData)
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

function StockPiler2.SeedMap.LearnFromCraftChatHarvest(count, plantName)
    count = tonumber(count) or 0
    plantName = Private.ToNarrow(plantName)
    if plantName == "" then
        return false
    end

    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) == "table" and pending.locked == true then
        return false
    end

    local plantUid = StockPiler2.SeedMap.FindPlantUidByHarvestName(plantName)
    if plantUid <= 0 then
        Private.D("SeedMap craft harvest unknown plant name=" .. plantName)
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
        seedUid = Private.InferSeedUidForPlantHarvest(plantUid, plantName)
    end
    local plantData = Private.LookupItemData(plantUid)
    if type(plantData) == "table" then
        Private.UpsertItem(plantData, "mat")
    end
    if seedUid <= 0 then
        Private.D("SeedMap craft harvest no seedUid plantUid=" .. tostring(plantUid)
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
    Private.D("SeedMap craft harvest plantUid=" .. tostring(plantUid)
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
    local live = Private.PlotSeedUid(plotData)
    local seedUid = StockPiler2.SeedMap.ResolvePlotSeed(plotNum, live)
    StockPiler2.SeedMap._pendingHarvest = {
        plotNum = plotNum,
        seedUid = seedUid,
        countsBefore = Private.SnapshotCraftingMatCounts(),
        started = Private.NowSec(),
        locked = true,
        lootDirty = false,
        lootDirtyAt = 0,
        lastCompleteAttempt = 0,
    }
    Private.D("SeedMap harvest watch plot=" .. tostring(plotNum)
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
    pending.lootDirtyAt = Private.NowSec()
end

--- After refine/brew bag changes, rebase an unlocked harvest snapshot so convert
--- deltas are not treated as harvest loot.
function StockPiler2.SeedMap.RefreshHarvestWatchAfterBagChange()
    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) ~= "table" or pending.locked == true then
        return
    end
    pending.countsBefore = Private.SnapshotCraftingMatCounts()
    pending.started = Private.NowSec()
end

--- Keep a pre-harvest bag snapshot while a plot is grown (GatherButton / other harvesters).
function StockPiler2.SeedMap.RefreshHarvestWatch(plotNum, plotData)
    local pending = StockPiler2.SeedMap._pendingHarvest
    if type(pending) == "table" and pending.locked == true then
        Private.D("SeedMap harvest watch plot=" .. tostring(plotNum)
            .. " seedUid=" .. tostring(pending.seedUid or 0)
            .. " locked=true skip=locked")
        return
    end
    plotNum = tonumber(plotNum) or 0
    local live = Private.PlotSeedUid(plotData)
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
        countsBefore = Private.SnapshotCraftingMatCounts(),
        started = Private.NowSec(),
        locked = false,
        lootDirty = false,
        lootDirtyAt = 0,
        lastCompleteAttempt = 0,
    }
    Private.D("SeedMap harvest watch plot=" .. tostring(plotNum)
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
    local now = Private.NowSec()
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
    local now = Private.NowSec()
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
    local after = Private.SnapshotCraftingMatCounts()
    if Perf and Perf.End then
        Perf.End("Harvest.Snapshot")
    end
    local deltas = {}
    local hasNonSeedGain = false
    for uid, afterCount in pairs(after) do
        local change = afterCount - (tonumber(before[uid]) or 0)
        if change > 0 then
            deltas[uid] = change
            local item = Private.LookupItemData(uid)
            if not Private.IsSeedOrSporeItem(item) then
                hasNonSeedGain = true
            end
        end
    end
    if not hasNonSeedGain then
        -- Loot may still be arriving — clear dirty so LearnBridge does not Snapshot every
        -- throttle tick forever (vault/bank bag moves kept re-dirtying + stuck pending).
        -- Next inventory event calls MarkHarvestLootDirty again.
        pending.lootDirty = false
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
        local item = Private.LookupItemData(uid)
        if not Private.IsSeedOrSporeItem(item)
            and Private.IsEligibleHarvestProductUid(uid, seedUid)
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
        local primaryData = Private.LookupItemData(primaryUid)
        seedUid = Private.InferSeedUidForPlantHarvest(primaryUid, primaryData and primaryData.name or nil)
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
            if uid > 0 and change > 0 and not Private.IsSeedOrSporeItem(Private.LookupItemData(uid))
                and not StockPiler2.SeedMap.IsResinUid(uid)
                and Private.IsCraftingItem(Private.LookupItemData(uid))
            then
                harvestProducts[uid] = change
                local item = Private.LookupItemData(uid)
                productParts[#productParts + 1] = Private.ToNarrow(item and item.name or uid)
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
            local outUid = 0
            if type(chatCues) == "table" and chatCues.harvestedName ~= nil then
                local chatUid = 0
                if StockPiler2.SeedMap.FindPlantUidByHarvestName then
                    chatUid = tonumber(StockPiler2.SeedMap.FindPlantUidByHarvestName(chatCues.harvestedName)) or 0
                end
                -- Use chat name when unresolved, or when the resolved uid is growable.
                if chatUid <= 0 or Private.IsEligibleHarvestProductUid(chatUid, seedUid) then
                    outName = chatCues.harvestedName
                    outCount = tonumber(chatCues.harvestedCount) or 0
                    if chatUid > 0 then
                        outUid = chatUid
                    end
                end
            end
            if (outName == nil or outName == L"" or outName == "")
                and primaryUid > 0
                and Private.IsEligibleHarvestProductUid(primaryUid, seedUid)
            then
                local primaryItem = Private.LookupItemData(primaryUid)
                outName = primaryItem and primaryItem.name or nil
                outCount = primaryDelta
                outUid = primaryUid
            end
            if critFail == true then
                StockPiler2.Grow.NotifyHarvestOutcome(plotNum, { critFail = true })
            elseif outName ~= nil and outName ~= L"" and outName ~= "" then
                StockPiler2.Grow.NotifyHarvestOutcome(plotNum, {
                    name = outName,
                    count = outCount,
                    uniqueID = outUid,
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
            if uid > 0 and Private.HarvestPairAllowed(seedUid, uid, {
                expectedPlantUid = primaryUid,
                relatedToPlantUid = primaryUid,
                chatPlantUids = chatPlantUids,
                allowExisting = true,
                plotTrusted = trusted == true,
            }) then
                allowedProducts[uid] = change
            else
                local item = Private.LookupItemData(uid)
                Private.D("SeedMap harvest skip unrelated plantUid=" .. tostring(uid)
                    .. " seedUid=" .. tostring(seedUid)
                    .. " plant=" .. Private.ToNarrow(item and item.name or uid))
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
                local item = Private.LookupItemData(uid)
                if uid > 0 and Private.IsCraftingItem(item) and not StockPiler2.SeedMap.IsResinUid(uid)
                    and Private.IsEligibleHarvestProductUid(uid, seedUid)
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
                            or #Private.EngineSeedUidsForPlant(uid) > 0
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
            Private.D("SeedMap harvest plantUid=" .. tostring(primaryUid)
                .. " seedUid=" .. tostring(seedUid)
                .. " products=" .. tostring(productCount)
                .. " learned=" .. tostring(learnedAny)
                .. " trusted=true"
                .. " chatCritOk=" .. tostring(critOk == true)
                .. " chatCritFail=" .. tostring(critFail == true))
        else
            StockPiler2.SeedMap.ObserveHarvest(seedUid, allowedProducts, true, false, primaryUid)
            local primaryData = Private.LookupItemData(primaryUid)
            if Private.IsCraftingItem(primaryData) and not StockPiler2.SeedMap.IsResinUid(primaryUid)
                and Private.IsEligibleHarvestProductUid(primaryUid, seedUid)
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
                Private.D("SeedMap harvest plantUid=" .. tostring(primaryUid)
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

