-- Parse.lua
-- Computes an approximate local "parse" percentile using RaidPulse_Benchmarks
-- (generated externally by generate_benchmarks.py from Warcraft Logs data).
--
-- The parse is an APPROXIMATION and is prefixed with "~" everywhere it is shown.
-- It matches the report's difficulty + encounter to the corresponding
-- className-specName entry in RaidPulse_Benchmarks, then interpolates linearly
-- between the stored anchor percentiles (median = 50, p75, p95, top = 99).
-- When the player's spec is unknown we fall back to the average of all specs
-- of the same class + role available in the DB.

_G.MCA = _G.MCA or {}
MCA = _G.MCA

-- Blizzard raid difficultyID -> Warcraft Logs difficulty ID.
-- (Bliz Normal=14, Heroic=15, Mythic=16 -> WCL 3, 4, 5.)
local BLIZ_TO_WCL_DIFFICULTY = {
    [14] = 3, [15] = 4, [16] = 5,
    [23] = 5, -- Mythic dungeon end-of-run counted as mythic for reference
}

-- Difficulty NAME (as MCA stores it in the report) -> WCL difficulty ID.
local NAME_TO_WCL_DIFFICULTY = {
    ["normal"]  = 3,
    ["heroic"]  = 4,
    ["mythic"]  = 5,
    ["lfr"]     = 3, -- no LFR ranking, best fallback
}

-- Blizzard class token -> WCL className (PascalCase, no spaces).
local CLASS_TOKEN_TO_WCL = {
    DEATHKNIGHT = "DeathKnight",
    DEMONHUNTER = "DemonHunter",
    DRUID       = "Druid",
    EVOKER      = "Evoker",
    HUNTER      = "Hunter",
    MAGE        = "Mage",
    MONK        = "Monk",
    PALADIN     = "Paladin",
    PRIEST      = "Priest",
    ROGUE       = "Rogue",
    SHAMAN      = "Shaman",
    WARLOCK     = "Warlock",
    WARRIOR     = "Warrior",
}

-- Blizzard specID -> WCL specName. Not exhaustive; the fallback (class-avg)
-- kicks in for any spec not listed here.
local SPEC_ID_TO_WCL = {
    [250] = "Blood",        [251] = "Frost",         [252] = "Unholy",         -- DK
    [577] = "Havoc",        [581] = "Vengeance",                                -- DH
    [102] = "Balance",      [103] = "Feral",         [104] = "Guardian",       [105] = "Restoration",  -- Druid
    [1467] = "Devastation", [1468] = "Preservation", [1473] = "Augmentation",  -- Evoker
    [253] = "Beast Mastery",[254] = "Marksmanship",  [255] = "Survival",       -- Hunter
    [62]  = "Arcane",       [63]  = "Fire",          [64]  = "Frost",          -- Mage
    [268] = "Brewmaster",   [269] = "Windwalker",    [270] = "Mistweaver",     -- Monk
    [65]  = "Holy",         [66]  = "Protection",    [70]  = "Retribution",    -- Paladin
    [256] = "Discipline",   [257] = "Holy",          [258] = "Shadow",         -- Priest
    [259] = "Assassination",[260] = "Outlaw",        [261] = "Subtlety",       -- Rogue
    [262] = "Elemental",    [263] = "Enhancement",   [264] = "Restoration",    -- Shaman
    [265] = "Affliction",   [266] = "Demonology",    [267] = "Destruction",    -- Warlock
    [71]  = "Arms",         [72]  = "Fury",          [73]  = "Protection",     -- Warrior
}

-- Public: convert Blizzard specID to WCL specName. Nil if unknown.
function MCA:SpecIDToWCLName(specID)
    if not specID then return nil end
    return SPEC_ID_TO_WCL[tonumber(specID) or -1]
end

-- Map the report's difficulty (string or numeric) to the WCL difficulty id.
-- The string match is intentionally fuzzy (substring): the addon may store
-- difficulty as "Mythic", "Mythic+", "Raid Mythic", "Raid Mythic - Flexible
-- Raiding" (12.0.7 Sporefall flex), or localized variants — all of these
-- should still map to the correct WCL difficulty bucket.
function MCA:GetReportWCLDifficulty(data)
    if not data then return nil end
    local d = data.difficulty
    if type(d) == "number" then
        return BLIZ_TO_WCL_DIFFICULTY[d]
    end
    if type(d) == "string" then
        local lower = d:lower()

        -- Exact-match first (fast path, keeps old behavior).
        local exact = NAME_TO_WCL_DIFFICULTY[lower]
        if exact then return exact end

        -- Fuzzy: substring match, in specificity order (Mythic before Heroic
        -- before Normal, because "mythic" trumps a stray "normal" tag).
        if lower:find("mythic", 1, true) then return 5 end
        if lower:find("heroic", 1, true) then return 4 end
        if lower:find("normal", 1, true) then return 3 end
        if lower:find("lfr", 1, true) or lower:find("finder", 1, true) then return 3 end
    end
    return nil
end

-- Fetch the encounter table matching this report (raid only for now).
local function getEncounterEntry(data)
    if not RaidPulse_Benchmarks or not RaidPulse_Benchmarks.encounters then return nil end
    if not data or data.type ~= "raid" then return nil end
    local encID = data.encounterID
    if not encID then return nil end
    return RaidPulse_Benchmarks.encounters[encID]
end

-- Percentile keys the v3 generator writes into each spec entry, from top to
-- bottom. Also drives the class-fallback aggregation below. The addon reads
-- RaidPulse_Benchmarks.percentiles if present, otherwise falls back to this list.
local DEFAULT_CURVE_PERCENTILES = {99, 95, 90, 85, 75, 65, 50, 40, 30, 20, 10, 5, 1}

local function getCurvePercentiles()
    if RaidPulse_Benchmarks and type(RaidPulse_Benchmarks.percentiles) == "table"
       and #RaidPulse_Benchmarks.percentiles > 0 then
        return RaidPulse_Benchmarks.percentiles
    end
    return DEFAULT_CURVE_PERCENTILES
end

-- Detect whether a ref uses the v3 curve (multiple pXX fields) or the older
-- v2 4-anchor shape (top/p95/p75/median).
local function refHasCurve(ref)
    if not ref then return false end
    local pcts = getCurvePercentiles()
    for _, p in ipairs(pcts) do
        if ref["p" .. p] then return true end
    end
    return false
end

-- Interpolate value against a v3 percentile curve. Percentiles are in the
-- ref as keys "p99", "p95", ... in decreasing order matching decreasing DPS.
-- Returns 0..99.
--
-- Compressed / truncated curves: when the paginated sample only covers the
-- top of the real population, the sample's observed p1 is well above the
-- world's real p1. How MUCH above depends on how many pages we fetched vs
-- the spec's total population.
--
-- Since we don't know the total population, we use the spread of the sample
-- as a proxy: a narrow top/p1 ratio (say 1.05) means the sample is packed
-- together at the top of the world distribution, so our p1 is really quite
-- high in the world (~p10). A wider ratio (1.5+) means we captured more of
-- the middle of the distribution, so our p1 is closer to the world p50-p60.
--
-- The remap maps observed [1..99] -> [floor..99] where floor depends on
-- ratio: narrow samples get a low floor (aggressive), wide samples get a
-- high floor (gentle).
-- Compressed / truncated curves: the paginated sample of top-N rankings
-- represents some fraction of the total world population for this bracket.
-- The spread of the sample tells us WHERE in the world distribution it sits.
--
-- - NARROW spread (top/p1 near 1.0): all N sampled players do similar DPS.
--   This means our top-N is packed at the peak of the population - our
--   observed p1 is really the world's p90+. High floor.
-- - WIDE spread (top/p1 > 1.5): our top-N includes both elite and mid-tier
--   players. Our observed p1 is closer to the world's p30-50. Low floor.
local function computeCompressedFloor(ref)
    local topV, p1V = ref.top or 0, ref.p1 or 0
    if topV <= 0 or p1V <= 0 then return 50 end
    local ratio = topV / p1V
    if ratio >= 2.0 then return 20 end
    if ratio >= 1.5 then return 40 end
    if ratio >= 1.3 then return 60 end
    if ratio >= 1.15 then return 75 end
    return 85  -- ratio < 1.15: extremely dense, sample is world top-15%
end

local function percentileFromCurve(value, ref)
    if not ref or not value or value <= 0 then return 0 end
    local pcts = getCurvePercentiles()

    -- Detect compression / truncation.
    local compressed = ref.truncated == true
    if not compressed then
        local n = ref.sample or 0
        if n >= 1500 and (n % 100 == 0) then
            compressed = true
        end
    end

    local COMPRESSED_MIN = compressed and computeCompressedFloor(ref) or 1

    local function remap(observed_p)
        if not compressed then return observed_p end
        -- Map observed [1..99] linearly to world [COMPRESSED_MIN..99].
        local t = (observed_p - 1) / 98
        return COMPRESSED_MIN + t * (99 - COMPRESSED_MIN)
    end

    -- Build ordered anchor list [{p=99, v=top}, {p=95, v=...}, ...] using
    -- only percentiles that actually have a value in this ref. Percentiles
    -- are remapped if the curve is compressed.
    local anchors = {}
    if ref.top and ref.top > 0 then
        anchors[#anchors + 1] = { p = 99, v = ref.top }
    end
    for _, p in ipairs(pcts) do
        local v = ref["p" .. p]
        if type(v) == "number" and v > 0 then
            local remapped = remap(p)
            if p == 99 and #anchors > 0 and anchors[1].p == 99 then
                anchors[1].v = v
            else
                anchors[#anchors + 1] = { p = remapped, v = v }
            end
        end
    end

    if #anchors == 0 then return 0 end

    if value >= anchors[1].v then
        return math.floor(anchors[1].p + 0.5)
    end

    for i = 1, #anchors - 1 do
        local hi = anchors[i]
        local lo = anchors[i + 1]
        if value < hi.v and value >= lo.v then
            local span = hi.v - lo.v
            if span <= 0 then return math.floor(lo.p + 0.5) end
            local t = (value - lo.v) / span
            return math.floor(lo.p + t * (hi.p - lo.p) + 0.5)
        end
    end

    -- Below the lowest observed anchor.
    --
    -- On a COMPLETE sample this is a real answer: we hold every logged kill in
    -- the bracket, so being under the worst of them is genuinely near zero and
    -- the decay below is a fair reading of how far under.
    --
    -- On a TRUNCATED one it is not. The v2 API returns at most 2000 rankings,
    -- so for a popular bracket we hold the top 2000 and nothing else, and the
    -- shape of the rest cannot be inferred from them. This used to guess
    -- anyway: an Arcane Mage at 96.8k against a bracket whose worst sampled
    -- log was 142.6k was handed 36, where WarcraftLogs said 9. Every step of
    -- that number after "off the bottom of the curve" was invented.
    --
    -- It now returns the floor as an upper bound and says so, which is the
    -- most the data supports: below the sample, and we cannot say how far.
    local lowest = anchors[#anchors]
    if lowest.v <= 0 then return 0 end

    local ratio = value / lowest.v
    if ratio <= 0 then return 0 end
    if ratio >= 1 then return math.floor(lowest.p + 0.5) end

    if compressed then
        return math.floor(lowest.p + 0.5), true
    end

    -- Extrapolate from the LOWEST anchor, not from the top one: anchoring on
    -- the top makes the curve jump when it crosses the last anchor, because
    -- the anchors are remapped for compressed curves while a top-anchored
    -- ratio is not. On a wide curve (floor 20) a player exactly at p1 scored
    -- 20 while a player one point of DPS below it scored ~40 — the parse went
    -- UP as the DPS went DOWN. Scaling from the lowest anchor is continuous
    -- there by construction (ratio = 1 gives back lowest.p) and still decays
    -- monotonically to 0.
    local extrapolated = lowest.p * (ratio ^ 1.3)
    if extrapolated < 0 then extrapolated = 0 end
    return math.floor(extrapolated + 0.5)
end

-- v2 fallback: interpolate against 4 anchors (top / p95 / p75 / median).
-- Used only if the loaded RaidPulse_Benchmarks is an older schema.
local function percentileFromAnchors(value, ref)
    if not ref or not value or value <= 0 then return 0 end
    local median, p75, p95, top = ref.median, ref.p75, ref.p95, ref.top
    if not (median and p75 and p95 and top) then return 0 end

    if value >= top then
        return 99
    elseif value >= p95 then
        local span = top - p95
        if span <= 0 then return 95 end
        return math.floor(95 + ((value - p95) / span) * 4 + 0.5)
    elseif value >= p75 then
        local span = p95 - p75
        if span <= 0 then return 75 end
        return math.floor(75 + ((value - p75) / span) * 20 + 0.5)
    elseif value >= median then
        local span = p75 - median
        if span <= 0 then return 50 end
        return math.floor(50 + ((value - median) / span) * 25 + 0.5)
    else
        if median <= 0 then return 0 end
        return math.floor((value / median) * 50 + 0.5)
    end
end

-- Returns (percentile, isUpperBound). The second value is true when the value
-- fell below a truncated sample, where the percentile is a ceiling rather than
-- a reading.
local function computePercentile(value, ref)
    if refHasCurve(ref) then
        return percentileFromCurve(value, ref)
    end
    return percentileFromAnchors(value, ref)
end

-- Cache the local player's average item level so we don't hit
-- GetAverageItemLevel on every render tick.
local cachedIlvl = nil
local function getLocalPlayerIlvl()
    if cachedIlvl and cachedIlvl > 0 then return cachedIlvl end
    if GetAverageItemLevel then
        local overall = GetAverageItemLevel()
        if overall and overall > 0 then
            cachedIlvl = math.floor(overall + 0.5)
            return cachedIlvl
        end
    end
    return nil
end

-- Public: force a refresh of the cached ilvl (call after gear changes if
-- needed). The addon can invoke MCA:InvalidateIlvlCache() from Session.lua
-- when it re-reads the local player's roster entry.
function MCA:InvalidateIlvlCache()
    cachedIlvl = nil
end

-- Given a spec entry with a "brackets" table, pick the bracket whose
-- [ilvlMin, ilvlMax) range contains the target ilvl. Uses two strategies:
--   1) Fast path: if the report's zone has a `zoneBrackets` def in the DB
--      (raid-v5+), compute bracket ID = ((ilvl - min) / bucket) + 1 and
--      look up directly.
--   2) Fallback: iterate brackets and match by ilvlMin/ilvlMax range, or
--      pick the closest bracket by midpoint.
-- Returns the bracket curve (with p99..p1) augmented with the spec metric.
local function pickBracket(specEntry, targetIlvl, zoneId)
    if not specEntry or type(specEntry.brackets) ~= "table" then return nil end
    local brackets = specEntry.brackets

    -- Fast path: compute bracket ID from zone bracket definition.
    if targetIlvl and zoneId and RaidPulse_Benchmarks and RaidPulse_Benchmarks.zoneBrackets then
        local zb = RaidPulse_Benchmarks.zoneBrackets[zoneId]
        if zb and zb.min and zb.bucket and zb.bucket > 0 then
            local bid = math.floor((targetIlvl - zb.min) / zb.bucket) + 1
            local b = brackets[bid]
            if b then
                local out = {}
                for k, v in pairs(b) do out[k] = v end
                out.metric = specEntry.metric
                return out
            end
            -- Bracket doesn't exist for the exact ilvl (too few samples);
            -- try adjacent brackets, preferring lower (safer) direction.
            for delta = 1, 5 do
                for _, tryBid in ipairs({bid - delta, bid + delta}) do
                    local tb = brackets[tryBid]
                    if tb then
                        local out = {}
                        for k, v in pairs(tb) do out[k] = v end
                        out.metric = specEntry.metric
                        return out
                    end
                end
            end
        end
    end

    -- Fallback: match by ilvl range.
    if targetIlvl then
        for _, b in pairs(brackets) do
            if b.ilvlMin and b.ilvlMax and targetIlvl >= b.ilvlMin and targetIlvl < b.ilvlMax then
                local out = {}
                for k, v in pairs(b) do out[k] = v end
                out.metric = specEntry.metric
                return out
            end
        end
    end

    -- Last resort: closest by midpoint distance.
    local best, bestDist = nil, math.huge
    for _, b in pairs(brackets) do
        if b.ilvlMin and b.ilvlMax then
            local mid = (b.ilvlMin + b.ilvlMax) / 2
            local dist = targetIlvl and math.abs(mid - targetIlvl) or (500 - mid)
            if dist < bestDist then
                best, bestDist = b, dist
            end
        end
    end

    if best then
        local out = {}
        for k, v in pairs(best) do out[k] = v end
        out.metric = specEntry.metric
        return out
    end
    return nil
end

-- Given a class token (WoW) + role, return the aggregated reference by
-- averaging every spec entry of that class in the wanted metric. Used when
-- the player's specific spec is not known.
-- For bracket-aware entries (raid-v4) it picks the target bracket in each
-- contributing spec and averages the resulting curves. For older schemas
-- it averages the numeric fields directly.
local function classFallbackRef(diffEntry, wclClass, wantMetric, targetIlvl, zoneId)
    if not diffEntry then return nil end
    local prefix = wclClass .. "-"
    local sums, count, truncatedCount = {}, 0, 0

    for key, ref in pairs(diffEntry) do
        if type(key) == "string" and key:sub(1, #prefix) == prefix and ref.metric == wantMetric then
            -- If the entry has brackets, pick the matching one first.
            local source = ref
            if type(ref.brackets) == "table" then
                source = pickBracket(ref, targetIlvl, zoneId)
            end
            if source then
                count = count + 1
                if source.truncated == true then
                    truncatedCount = truncatedCount + 1
                end
                for k, v in pairs(source) do
                    if type(v) == "number" then
                        sums[k] = (sums[k] or 0) + v
                    end
                end
            end
        end
    end

    if count == 0 then return nil end

    local avg = { metric = wantMetric }
    for k, total in pairs(sums) do
        avg[k] = total / count
    end

    -- `truncated` is a boolean, so it is not picked up by the numeric averaging
    -- above and has to be carried over explicitly. Without this the averaged
    -- curve looked like a complete sample to percentileFromCurve, which then
    -- skipped the compressed-curve remap entirely — that is why players whose
    -- spec we could not identify scored far below their real parse.
    if truncatedCount * 2 >= count then
        avg.truncated = true
    end

    -- Averaged sample size, so the truncation heuristics downstream still see
    -- a realistic per-spec magnitude rather than the number of specs merged.
    avg.sample = math.floor((sums.sample or 0) / count + 0.5)
    avg.specsMerged = count
    return avg
end

-- Public: get the reference row for a player inside a given report.
-- Returns nil if we can't match the report to the DB.
function MCA:GetBenchmarkRef(player, data)
    if not player or not data then return nil end

    local enc = getEncounterEntry(data)
    if not enc or not enc.difficulties then return nil end

    local wclDiff = self:GetReportWCLDifficulty(data)
    if not wclDiff then return nil end

    local diffEntry = enc.difficulties[wclDiff]
    if not diffEntry then return nil end

    local wclClass = CLASS_TOKEN_TO_WCL[tostring(player.class or ""):upper()]
    if not wclClass then return nil end

    local wantMetric = (tostring(player.role or ""):upper() == "HEALER") and "hps" or "dps"

    -- Target ilvl: player's own if set (rare), otherwise the local player's
    -- ilvl as a proxy (raid members are usually in the same range).
    local targetIlvl = tonumber(player.ilvl) or getLocalPlayerIlvl()
    local zoneId = enc.zoneId

    -- Try exact spec match first.
    local specName = player.wclSpec or self:SpecIDToWCLName(player.specID)
    if specName then
        local key = wclClass .. "-" .. specName
        local specEntry = diffEntry[key]
        if specEntry and specEntry.metric == wantMetric then
            -- New bracket-aware schema: pick the ilvl bracket first.
            if type(specEntry.brackets) == "table" then
                local ref = pickBracket(specEntry, targetIlvl, zoneId)
                if ref then return ref, "spec" end
            else
                -- Older schema: use the entry directly.
                return specEntry, "spec"
            end
        end
    end

    -- Fall back to class-average for the wanted metric.
    local ref = classFallbackRef(diffEntry, wclClass, wantMetric, targetIlvl, zoneId)
    if ref then return ref, "class-avg" end

    return nil
end

-- Public: compute the local approximate parse for a player inside a report.
-- Returns (parse, source) where source is "spec", "class-avg", or nil.
function MCA:ComputeLocalParse(player, data)
    local ref, source = self:GetBenchmarkRef(player, data)
    if not ref then return nil, nil end

    local value
    if self.GetFightMetric then
        value = self:GetFightMetric(player)
    end
    if not value or value <= 0 then return 0, source end

    local parse, bounded = computePercentile(value, ref)
    return parse, source, bounded
end

-- Public: parse color, mirrors the WCL palette used by GetRatingColor.
function MCA:GetParseColor(parse)
    parse = tonumber(parse or 0) or 0
    if parse >= 99 then return {0.886, 0.408, 1.000, 1} end -- pink
    if parse >= 95 then return {1.000, 0.502, 0.000, 1} end -- orange
    if parse >= 75 then return {0.639, 0.208, 0.933, 1} end -- purple
    if parse >= 50 then return {0.000, 0.439, 0.867, 1} end -- blue
    if parse >= 25 then return {0.118, 1.000, 0.000, 1} end -- green
    return {0.616, 0.616, 0.616, 1} -- gray
end

-- Public: formatted display string. Always prefixed with "~" to signal that
-- the value is a local approximation, not a real WarcraftLogs parse.
--   "-" if we can't compute (no benchmarks for this encounter/difficulty)
--   "~72"  otherwise
-- "~36" is a reading. "<36" is a ceiling: the value fell under a sample that
-- only covers the top of its bracket, so all we know is that it is below.
function MCA:FormatParse(parse, hasRef, bounded)
    if hasRef == false then return "-" end
    if not parse then return "-" end
    if bounded then return "<" .. tostring(parse) end
    return "~" .. tostring(parse)
end

-- Public one-stop helper for renderers. Returns:
--   value (number 0..99), color ({r,g,b,a}), display (string, "~NN" or NN%), source
-- Source is "benchmark" when it comes from RaidPulse_Benchmarks, "relative" when
-- it falls back to the previous in-group relative rating.
function MCA:ResolvePlayerParse(player, data)
    -- Try real (approximate) parse first.
    local parse, source, bounded = self:ComputeLocalParse(player, data)
    if parse and source then
        -- Coloured for the ceiling, not for the ceiling's value: a "<36" is
        -- somewhere below 36 and painting it as a 36 would undo the point.
        local color = self:GetParseColor(bounded and 0 or parse)
        return parse, color, self:FormatParse(parse, true, bounded), "benchmark"
    end

    -- Fall back to the in-group relative rating.
    local metricValue = self.GetFightMetric and self:GetFightMetric(player) or 0
    local rating = 0
    if metricValue and metricValue > 0 then
        rating = (player.mcaRating or (self.GetScore and self:GetScore(player)) or 0)
    end
    local color = self.GetRatingColor and self:GetRatingColor(rating) or {1,1,1,1}
    return rating, color, tostring(rating), "relative"
end
