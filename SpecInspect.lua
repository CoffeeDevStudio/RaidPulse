-- SpecInspect.lua
-- Uses NotifyInspect + INSPECT_READY to fetch other players' specIDs so
-- Parse.lua can do exact spec-vs-benchmark matches instead of falling back
-- to a class average.
--
-- NotifyInspect is rate-limited by the server (calling it too often kicks
-- the caller off). Blizzard's UI uses ~1.5s spacing; we use 2s to stay safe.
-- We cache specIDs by GUID for the session so re-inspects on roster refresh
-- are cheap.

_G.MCA = _G.MCA or {}
MCA = _G.MCA

local INSPECT_INTERVAL = 2.0    -- seconds between inspects
local INSPECT_TIMEOUT  = 3.0    -- seconds to wait for INSPECT_READY response
local RETRY_LIMIT      = 2      -- give up on a unit after this many failures
local FIRST_SCAN_DELAY = 15     -- seconds after Init before we allow inspects

-- Per-session cache: guid -> specID.
MCA.specCache = MCA.specCache or {}

-- Inspect state.
local inspectQueue = {}         -- list of {guid=, unit=} entries to process
local inspectPending = nil      -- currently-being-inspected {guid=, unit=, sentAt=, retries=}
local inspectFrame              -- OnUpdate driver frame
local initTime = GetTime()      -- when the addon's SpecInspect module was loaded
local firstScanReady = false    -- true after FIRST_SCAN_DELAY has elapsed

-- Utility: find a raid/party unit id by GUID (unit tokens change slot when
-- someone leaves/joins, so we can't rely on the one we queued).
local function findUnitByGUID(guid)
    if not guid then return nil end
    if IsInRaid and IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local u = "raid" .. i
            if UnitExists(u) and UnitGUID(u) == guid then return u end
        end
    elseif IsInGroup and IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            local u = "party" .. i
            if UnitExists(u) and UnitGUID(u) == guid then return u end
        end
        if UnitGUID("player") == guid then return "player" end
    else
        if UnitGUID("player") == guid then return "player" end
    end
    return nil
end

-- Apply a cached specID to the roster and session entry(-ies) with the given GUID.
local function applyToRoster(guid, specID)
    for _, p in pairs(MCA.roster or {}) do
        if p.guid == guid and not p.specID then
            p.specID = specID
        end
    end

    if not (MCA.session and MCA.session.players) then return end
    for _, p in pairs(MCA.session.players) do
        if p.guid == guid and not p.specID then
            p.specID = specID
        end
    end
end

function MCA:InspectSpec_Queue(unit)
    if not unit or not UnitExists(unit) then return end
    if UnitIsUnit(unit, "player") then return end -- our own spec is captured directly
    local guid = UnitGUID(unit)
    if not guid then return end

    -- Already known?
    local cached = MCA.specCache[guid]
    if cached then
        applyToRoster(guid, cached)
        return
    end

    -- Already queued or currently being inspected?
    if inspectPending and inspectPending.guid == guid then return end
    for _, q in ipairs(inspectQueue) do
        if q.guid == guid then return end
    end

    table.insert(inspectQueue, { guid = guid, unit = unit, retries = 0 })
end

function MCA:InspectSpec_QueueGroup()
    if IsInRaid and IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            self:InspectSpec_Queue("raid" .. i)
        end
    elseif IsInGroup and IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            self:InspectSpec_Queue("party" .. i)
        end
    end
end

local function processQueue()
    if inspectPending then return end

    -- Skip the entire login taint window: no inspect calls until we've been
    -- initialized for FIRST_SCAN_DELAY seconds.
    if not firstScanReady then
        if GetTime() - initTime >= FIRST_SCAN_DELAY then
            firstScanReady = true
        else
            return
        end
    end

    -- NotifyInspect is protected during combat and during some transitional
    -- states (loading screens, entering instances). Skip; the OnUpdate loop
    -- will try again on the next tick.
    if InCombatLockdown and InCombatLockdown() then return end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return end
    if IsFalling and IsFalling() then return end

    local next = table.remove(inspectQueue, 1)
    if not next then return end

    -- Refresh the unit token — it may have changed.
    local unit = findUnitByGUID(entry.guid) or entry.unit
    if not unit or not UnitExists(unit) then return end
    if not CanInspect(unit, false) then return end

    -- We must NOT open the inspect frame, so wrap in pcall in case a taint
    -- would raise. Also stop if inspecting our own player (safety).
    if UnitIsUnit(unit, "player") then return end

    inspectPending = {
        guid = entry.guid, unit = unit,
        sentAt = GetTime(), retries = entry.retries,
    }

    local ok = pcall(NotifyInspect, unit)
    if not ok then
        -- Something else in the client is holding the inspect slot. Drop
        -- this attempt; the OnUpdate timer will retry after INSPECT_INTERVAL.
        inspectPending = nil
    end
end

local function onInspectReady(guid)
    if not inspectPending or inspectPending.guid ~= guid then
        -- Response for something we didn't request (or already timed out).
        return
    end
    local unit = findUnitByGUID(guid) or inspectPending.unit
    if unit and GetInspectSpecialization then
        local specID = GetInspectSpecialization(unit)
        if specID and specID > 0 then
            MCA.specCache[guid] = specID
            applyToRoster(guid, specID)
        end
    end
    if ClearInspectPlayer then ClearInspectPlayer() end
    inspectPending = nil
end

local function onUpdate(self, elapsed)
    self._acc = (self._acc or 0) + elapsed
    if self._acc < INSPECT_INTERVAL then return end
    self._acc = 0

    -- Timeout the pending inspect if the server never answered.
    if inspectPending and (GetTime() - inspectPending.sentAt) > INSPECT_TIMEOUT then
        if inspectPending.retries < RETRY_LIMIT then
            -- Requeue with retry counter bumped.
            table.insert(inspectQueue, {
                guid = inspectPending.guid, unit = inspectPending.unit,
                retries = inspectPending.retries + 1,
            })
        end
        if ClearInspectPlayer then ClearInspectPlayer() end
        inspectPending = nil
    end

    processQueue()
end

function MCA:InitInspectSpec()
    if inspectFrame then return end
    inspectFrame = CreateFrame("Frame")
    inspectFrame:RegisterEvent("INSPECT_READY")
    inspectFrame:SetScript("OnEvent", function(_, event, guid)
        if event == "INSPECT_READY" then
            onInspectReady(guid)
        end
    end)
    inspectFrame:SetScript("OnUpdate", onUpdate)
end
