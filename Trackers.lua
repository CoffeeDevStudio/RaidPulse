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

    -- If we tracked a killing blow via the combat log, attach spell + damage
    -- info so the timeline can render a full cause of death.
    local cause = self.lastHitByGUID and self.lastHitByGUID[UnitGUID(unit) or ""]

    local ev = {
        type = "death",
        time = player.deathTime,
        player = name,
    }
    if cause then
        ev.spellID    = cause.spellID
        ev.spellName  = cause.spellName
        ev.amount     = cause.amount
        ev.sourceName = cause.sourceName
        player.deathSpellID   = cause.spellID
        player.deathSpellName = cause.spellName
        player.deathAmount    = cause.amount
        player.deathSource    = cause.sourceName
        ev.text = string.format("%s muore (%s: %s)",
            name, cause.spellName or "?",
            self.FormatMetricValue and self:FormatMetricValue(cause.amount or 0) or tostring(cause.amount or "?"))
    else
        ev.text = name .. " muore"
    end
    self:AddTimelineEvent(ev)

    if name == UnitName("player") then
        self:SendDeath(player.deathTime)
    end
end

-- Track the last damaging hit received by each raid member's GUID. We store
-- source, spell and amount so the death timeline can display cause + damage.
-- We only track damage to units that are in our session roster (raid members
-- with a matching GUID), so the table stays small.
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
            do
                p.deaths = (p.deaths or 0) + 1
                p.deadSeen = true
                p.deathTime = GetTime() - self.session.start
                local cause = self.lastHitByGUID and self.lastHitByGUID[destGUID]
                local ev = { type = "death", time = p.deathTime, player = name }
                if cause then
                    ev.spellID = cause.spellID
                    ev.spellName = cause.spellName
                    ev.amount = cause.amount
                    ev.sourceName = cause.sourceName
                    ev.text = string.format("%s muore (%s: %s)",
                        name, cause.spellName or "?",
                        self.FormatMetricValue and self:FormatMetricValue(cause.amount or 0) or tostring(cause.amount or "?"))
                    p.deathSpellID = cause.spellID
                    p.deathSpellName = cause.spellName
                    p.deathAmount = cause.amount
                    p.deathSource = cause.sourceName
                else
                    ev.text = name .. " muore"
                end
                self:AddTimelineEvent(ev)
            end
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
