_G.MCA = _G.MCA or {}
MCA = _G.MCA

function MCA:AddDefensiveToPlayer(player, spellID, time, source)
    if not player or not spellID then return false end

    local resolvedSpellID, fallbackName = self:ResolveDefensiveSpell(player.class, spellID)
    if not resolvedSpellID then return false end

    player.usedBySpell = player.usedBySpell or {}
    local key = tostring(resolvedSpellID)

    if player.usedBySpell[key] and math.abs((time or 0) - player.usedBySpell[key]) < 2 then
        return false
    end

    player.usedBySpell[key] = time or 0

    table.insert(player.used, {
        name = self:GetSpellNameSafe(resolvedSpellID, fallbackName),
        spellID = resolvedSpellID,
        icon = self:GetSpellIconSafe(resolvedSpellID),
        time = time or 0,
        source = source or "unknown"
    })

    self:AddTimelineEvent({
        type = "defensive",
        time = time or 0,
        player = player.name,
        text = (player.name or "?") .. " usa " .. fallbackName,
        spellID = resolvedSpellID
    })

    return true
end

function MCA:RecordDefensive(player, spellID, source)
    if not self.session then return end

    local t = GetTime() - self.session.start
    local added = self:AddDefensiveToPlayer(player, spellID, t, source)

    if added and player.name == UnitName("player") then
        self:SendDefensive(spellID, t)
    end
end

function MCA:UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID)
    if not self.session or not unit or not spellID then return end

    -- Retail/Midnight: some cast payloads carry names that are "secret
    -- strings" (opaque protected values). Indexing self.session.players with
    -- one of these raises "attempted to index a table that cannot be indexed
    -- with secret keys". Guard by validating name via pcall + rawget.
    local name = UnitName(unit)
    if not name or type(name) ~= "string" then return end

    local players = self.session.players
    if not players then return end

    local ok, player = pcall(rawget, players, name)
    if not ok or not player then return end

    self:RecordDefensive(player, spellID, "cast")
end

-- Apply cause-of-death info to a death timeline event, mirroring it onto the
-- player record. Safe to call after the event was already inserted: the
-- timeline stores the table by reference, so a cause that only becomes
-- available a moment later (death recap, addon sync) still reaches the UI.
function MCA:DecorateDeathEvent(ev, cause, player)
    if not ev then return end

    -- An empty spell name is truthy in Lua, and sync messages can carry one,
    -- so check for actual content before claiming we know the cause.
    if cause and type(cause.spellName) == "string" and cause.spellName ~= "" then
        ev.spellID    = cause.spellID
        ev.spellName  = cause.spellName
        ev.amount     = cause.amount
        ev.sourceName = cause.sourceName
        ev.text = string.format("%s muore (%s: %s)",
            ev.player or "?", cause.spellName or "?",
            self.FormatMetricValue and self:FormatMetricValue(cause.amount or 0) or tostring(cause.amount or "?"))
        if player then
            player.deathSpellID   = cause.spellID
            player.deathSpellName = cause.spellName
            player.deathAmount    = cause.amount
            player.deathSource    = cause.sourceName
        end
    else
        ev.text = (ev.player or "?") .. " muore"
    end
end

-- Find the death event already recorded for a player, so a late-arriving
-- cause can be attached to it instead of adding a second line.
function MCA:FindDeathEvent(name)
    if not self.session or not self.session.timeline then return nil end
    for i = #self.session.timeline, 1, -1 do
        local ev = self.session.timeline[i]
        if ev and ev.type == "death" and ev.player == name then return ev end
    end
    return nil
end

-- Cause of death for the LOCAL player, read from Blizzard's death recap.
-- This is the CLEU-free replacement for the killing-blow tracking we had to
-- drop in 12.0.7 (see the comment block in Events.lua): C_DeathInfo is a
-- Blizzard-maintained log of the last hits the player took, so reading it
-- needs no combat-log event registration at all.
--
-- The recap is populated slightly *after* the death fires, so callers must
-- read it with a small delay rather than inline in PLAYER_DEAD.
function MCA:GetLocalDeathCause()
    if not C_DeathInfo or not C_DeathInfo.GetRecapEvents then return nil end

    local ok, events = pcall(C_DeathInfo.GetRecapEvents, 1)
    if not ok or type(events) ~= "table" then return nil end

    -- Recap entries run oldest -> newest; the killing blow is the last one
    -- that actually did damage.
    for i = #events, 1, -1 do
        local e = events[i]
        local amount = tonumber(e and e.amount) or 0
        if amount > 0 then
            local spellID = tonumber(e.spellId or e.spellID) or 0
            local spellName = e.spellName
            if not spellName and spellID > 0 and self.GetSpellNameSafe then
                spellName = self:GetSpellNameSafe(spellID)
            end
            return {
                spellID    = spellID,
                spellName  = spellName or "?",
                amount     = amount,
                sourceName = e.sourceName or e.caster,
            }
        end
    end
    return nil
end

function MCA:MarkDead(unit)
    if not self.session or not UnitExists(unit) or not UnitIsDeadOrGhost(unit) then return end

    local name = UnitName(unit)
    if type(name) ~= "string" then return end
    local players = self.session.players
    if not players then return end
    local ok, player = pcall(rawget, players, name)
    if not ok or not player or player.deadSeen then return end

    player.deaths = (player.deaths or 0) + 1
    player.deadSeen = true
    player.deathTime = GetTime() - self.session.start

    -- If the optional combat-log handler tracked a killing blow, use it.
    local cause = self.lastHitByGUID and self.lastHitByGUID[UnitGUID(unit) or ""]

    local ev = { type = "death", time = player.deathTime, player = name }
    self:DecorateDeathEvent(ev, cause, player)
    self:AddTimelineEvent(ev)

    if name == UnitName("player") then
        local deathTime = player.deathTime
        self:SendDeath(deathTime)

        -- Then look up our own recap once it has filled in, patch the event we
        -- just inserted, and tell the rest of the group what killed us so their
        -- timeline shows the cause too.
        if not cause then
            C_Timer.After(0.6, function()
                if not MCA then return end
                local recap = MCA:GetLocalDeathCause()
                if not recap then return end
                MCA:DecorateDeathEvent(ev, recap, player)
                if MCA.SendDeathCause then MCA:SendDeathCause(deathTime, recap) end
            end)
        end
    end
end

-- Lowest boss health seen during the current engagement, as a percentage.
-- This is the number raiders actually quote about a wipe ("we got him to 12%").
--
-- Council fights are summed rather than averaged: the encounter ends when the
-- whole council is down, so combined remaining health is what tracks progress.
-- Boss frames only exist while an encounter is engaged, so a sample with no
-- boss units is simply skipped rather than recorded as 0.
local MAX_BOSS_UNITS = 8

function MCA:SampleBossHealth()
    if not self.session then return end

    local cur, maxHP = 0, 0
    for i = 1, MAX_BOSS_UNITS do
        local unit = "boss" .. i
        if UnitExists(unit) then
            local h = tonumber(UnitHealth(unit)) or 0
            local hm = tonumber(UnitHealthMax(unit)) or 0
            if hm > 0 then
                cur = cur + h
                maxHP = maxHP + hm
            end
        end
    end

    if maxHP <= 0 then return end

    local pct = (cur / maxHP) * 100
    local low = self.session.bossHPLow
    if not low or pct < low then
        self.session.bossHPLow = pct
    end
end

-- Session watcher.
-- 12.0.7 forbids COMBAT_LOG_EVENT_UNFILTERED registration for addons (see
-- Events.lua) and registering UNIT_HEALTH raised the same popup on some
-- clients, so group deaths and boss health are found by polling instead. Half
-- a second is far finer than anything read off the timeline or a wipe
-- percentage, and the ticker only runs while a session is actually active.
local POLL_INTERVAL = 0.5
local sessionTicker = nil

local function pollSession()
    if not MCA or not MCA.session then return end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            MCA:MarkDead("raid" .. i)
        end
    else
        MCA:MarkDead("player")
        for i = 1, math.max(0, GetNumGroupMembers() - 1) do
            MCA:MarkDead("party" .. i)
        end
    end

    MCA:SampleBossHealth()
end

function MCA:StartSessionWatcher()
    self:StopSessionWatcher()
    if not C_Timer or not C_Timer.NewTicker then return end
    sessionTicker = C_Timer.NewTicker(POLL_INTERVAL, pollSession)
end

function MCA:StopSessionWatcher()
    if sessionTicker then
        sessionTicker:Cancel()
        sessionTicker = nil
    end
end

-- Track the last damaging hit received by each raid member's GUID. We store
-- source, spell and amount so the death timeline can display cause + damage.
-- We only track damage to units that are in our session roster (raid members
-- with a matching GUID), so the table stays small.
--
-- NOTE: this handler is deliberately NOT wired up — Events.lua does not
-- register COMBAT_LOG_EVENT_UNFILTERED on 12.0.7 because doing so raises the
-- "action blocked" popup. It is kept because it is the only way to get a cause
-- of death for players who are not running RaidPulse themselves; the supported
-- path is GetLocalDeathCause + SendDeathCause, which covers the local player
-- always and group members who have the addon.
function MCA:COMBAT_LOG_EVENT_UNFILTERED()
    if not self.session or not CombatLogGetCurrentEventInfo then return end
    local _, subevent, _, _, sourceName, _, _, destGUID, destName, _, _,
          arg12, arg13, arg14, arg15 = CombatLogGetCurrentEventInfo()

    if not subevent or not destGUID then return end

    -- Damage events. Payload layout differs between swings and spells.
    if subevent == "SWING_DAMAGE" then
        if not self:IsSessionGUID(destGUID) then return end
        local amount = arg12
        self.lastHitByGUID = self.lastHitByGUID or {}
        self.lastHitByGUID[destGUID] = {
            spellID    = 0,
            spellName  = "Melee",
            amount     = tonumber(amount) or 0,
            sourceName = sourceName,
            atTime     = GetTime(),
        }
    elseif subevent == "SPELL_DAMAGE"
        or subevent == "SPELL_PERIODIC_DAMAGE"
        or subevent == "RANGE_DAMAGE"
        or subevent == "SPELL_BUILDING_DAMAGE" then
        if not self:IsSessionGUID(destGUID) then return end
        local spellID   = arg12
        local spellName = arg13
        local amount    = arg15
        self.lastHitByGUID = self.lastHitByGUID or {}
        self.lastHitByGUID[destGUID] = {
            spellID    = tonumber(spellID) or 0,
            spellName  = spellName or "?",
            amount     = tonumber(amount) or 0,
            sourceName = sourceName,
            atTime     = GetTime(),
        }
    elseif subevent == "SPELL_INSTAKILL" or subevent == "ENVIRONMENTAL_DAMAGE" then
        if not self:IsSessionGUID(destGUID) then return end
        local spellName = (subevent == "SPELL_INSTAKILL") and (arg13 or "Instakill") or "Environment"
        local amount    = (subevent == "SPELL_INSTAKILL") and 0 or (tonumber(arg13) or 0)
        self.lastHitByGUID = self.lastHitByGUID or {}
        self.lastHitByGUID[destGUID] = {
            spellID    = tonumber(arg12) or 0,
            spellName  = spellName,
            amount     = amount,
            sourceName = sourceName or "Environment",
            atTime     = GetTime(),
        }
    elseif subevent == "UNIT_DIED" then
        -- Prefer this over UNIT_HEALTH for the actual moment of death — it
        -- fires exactly on the killing blow. We locate the roster player by
        -- GUID and call MarkDead on their unit token if we can find it.
        local name = self.guidToName and self.guidToName[destGUID] or destName
        if type(name) ~= "string" then return end
        local unit = nil
        if self.GetUnitForName then
            unit = self:GetUnitForName(name)
        end
        if unit and UnitExists(unit) then
            self:MarkDead(unit)
        else
            local players = self.session.players
            if not players then return end
            local ok, p = pcall(rawget, players, name)
            if not ok or not p or p.deadSeen then return end

            -- Fall back: mark without a unit token by writing directly.
            p.deaths = (p.deaths or 0) + 1
            p.deadSeen = true
            p.deathTime = GetTime() - self.session.start

            local ev = { type = "death", time = p.deathTime, player = name }
            self:DecorateDeathEvent(ev, self.lastHitByGUID and self.lastHitByGUID[destGUID], p)
            self:AddTimelineEvent(ev)
        end
    end
end

-- True if the given GUID belongs to any player currently tracked in the
-- session — used to skip non-raid units when scanning combat log events.
function MCA:IsSessionGUID(guid)
    if not guid or not self.session or not self.guidToName then return false end
    return self.guidToName[guid] ~= nil
end

function MCA:PLAYER_DEAD()
    self:MarkDead("player")
end

function MCA:UNIT_HEALTH(unit)
    if unit then
        self:MarkDead(unit)
    end
end

-- Compatibility no-op functions.
-- FinalizeSession calls these safely, but SafeFight deliberately does not scan auras/debuffs.
function MCA:ScanAllAuras()
end

function MCA:ScanAllDebuffs()
end

function MCA:UNIT_AURA(unit)
end

function MCA:TrackerOnUpdate(delta)
end
