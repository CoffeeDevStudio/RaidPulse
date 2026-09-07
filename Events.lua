_G.MCA = _G.MCA or {}
MCA = _G.MCA

local f = CreateFrame("Frame")
MCA.EventFrame = f

local events = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_ENTERING_WORLD",
    "GROUP_ROSTER_UPDATE",
    "ENCOUNTER_START",
    "ENCOUNTER_END",
    "CHALLENGE_MODE_START",
    "CHALLENGE_MODE_COMPLETED",
    "CHALLENGE_MODE_RESET",
    "PLAYER_DEAD",
    "PLAYER_LEAVING_WORLD",
    "UNIT_SPELLCAST_SUCCEEDED",
    -- COMBAT_LOG_EVENT_UNFILTERED intentionally NOT registered here.
    -- In patch 12.0.7 (Midnight) registering CLEU from a non-Blizzard addon
    -- raises "Frame:RegisterEvent() forbidden". The popup is cosmetic (the
    -- addon still works) but very annoying.
    --
    -- Deaths are instead detected by the polling death watcher in Trackers.lua
    -- (started with the session), and the cause of death comes from Blizzard's
    -- own death recap (C_DeathInfo), which only covers the local player.
}

-- Register a single event to bootstrap: ADDON_LOADED. Everything else is
-- registered from within the ADDON_LOADED handler. This defers the whole
-- registration batch to a point AFTER all addon files have loaded, which
-- avoids the "Frame:RegisterEvent forbidden" popup that some patch 12.x
-- clients raise when addons call RegisterEvent from a file's main chunk.
_G.RaidPulseRegisterLog = _G.RaidPulseRegisterLog or {}
local eventsRegistered = false

local function registerAllEvents()
    if eventsRegistered then return end
    eventsRegistered = true
    for _, event in ipairs(events) do
        table.insert(_G.RaidPulseRegisterLog, event)
        pcall(function() f:RegisterEvent(event) end)
    end
end

f:RegisterEvent("ADDON_LOADED")

f:SetScript("OnEvent", function(_, event, arg1, ...)
    -- Bootstrap: when our addon has finished loading all files, register
    -- the rest of the events. This one-shot handler runs once and unregisters
    -- ADDON_LOADED so we don't listen to every addon's load event forever.
    if event == "ADDON_LOADED" and arg1 == "RaidPulse" then
        f:UnregisterEvent("ADDON_LOADED")
        registerAllEvents()
        return
    end

    if MCA[event] then
        local ok, err = pcall(MCA[event], MCA, arg1, ...)
        if not ok then
            MCA:Debug("Event error in " .. tostring(event) .. ": " .. tostring(err))
        end
    end
end)

-- SafeFight:
-- No OnUpdate aura/debuff polling in combat.
-- This avoids raid-wide Lua error spam on Midnight aura APIs.

function MCA:ADDON_LOADED(addonName)
    if addonName ~= "RaidPulse" then return end
    self:InitDB()
end

function MCA:PLAYER_LOGIN()
    self:DetectElvUI()
    if self.InitInspectSpec then self:InitInspectSpec() end
    self:UpdateRoster()
    -- Delay the first inspect scan by 5s so it doesn't fire during the
    -- loading-screen protection window (which raises "protected action"
    -- popups on some clients).
    C_Timer.After(5, function()
        if MCA and MCA.InspectSpec_QueueGroup then
            MCA:InspectSpec_QueueGroup()
        end
    end)
    if self.CreateMinimapButton then self:CreateMinimapButton() end
    self:Print("Loaded v" .. self.VERSION)
end

function MCA:PLAYER_ENTERING_WORLD()
    self:UpdateRoster()

    -- Same delay as above: PLAYER_ENTERING_WORLD fires after every loading
    -- screen (portals, hearthstone, wipes), and the client protects UI-side
    -- API calls for a short window afterwards.
    C_Timer.After(3, function()
        if MCA and MCA.InspectSpec_QueueGroup then
            MCA:InspectSpec_QueueGroup()
        end
    end)
end

function MCA:GROUP_ROSTER_UPDATE()
    -- Dropping out of a group ends its run of attempts. Joining the next one
    -- mints a fresh id at that group's first pull.
    if not IsInGroup() and self.EndGroupSession then
        self:EndGroupSession()
    end

    self:UpdateRoster()
    -- Roster updates during combat should not trigger inspect calls (they're
    -- protected). Defer to next OnUpdate tick.
    C_Timer.After(1, function()
        if MCA and MCA.InspectSpec_QueueGroup then
            MCA:InspectSpec_QueueGroup()
        end
    end)
end

function MCA:ENCOUNTER_START(id, name)
    if self.HideRaidBuffWindowForPull then self:HideRaidBuffWindowForPull() end
    self:StartRaidEncounter(id, name)
end

function MCA:ENCOUNTER_END(id, name, diff, size, success)
    -- 4.0.28: wait briefly so Blizzard Damage Meter finalizes the encounter data.
    C_Timer.After(1.0, function()
        if MCA and MCA.FinishRaidEncounter then
            MCA:FinishRaidEncounter(id, name, success)
        end
    end)
end

function MCA:CHALLENGE_MODE_START()
    if self.HideRaidBuffWindowForPull then self:HideRaidBuffWindowForPull() end
    self:StartMythicPlusSession()
end

function MCA:CHALLENGE_MODE_COMPLETED()
    -- 4.0.28: wait briefly so Blizzard Damage Meter finalizes the run data.
    C_Timer.After(1.0, function()
        if MCA and MCA.FinishMythicPlusSession then
            MCA:FinishMythicPlusSession(true)
        end
    end)
end

function MCA:CHALLENGE_MODE_RESET()
    -- MCA: fires both on key abandon/surrender and on normal key reset.
    -- The run is over either way, so close it out as a completed (failed)
    -- session and show the report immediately, instead of waiting on a
    -- combat-lockdown check that may never resolve before the instance
    -- teleports the player out.
    self:FinishMythicPlusSession(false, true)
end

function MCA:PLAYER_LEAVING_WORLD()
    -- MCA: safety net for the "vote to abandon" feature. A successful abandon
    -- vote teleports the whole group out of the instance and does NOT reliably
    -- fire CHALLENGE_MODE_RESET (or fires it after the player has already left
    -- the challenge map), so the run was never being closed and the report
    -- only surfaced when the next key started. If we still have an active M+
    -- session when we leave the world, finalize it as a failed run now.
    --
    -- Guard: skip if the challenge mode is still active on this map (e.g. the
    -- player just did a /reload inside the dungeon), so we don't wrongly close
    -- a run that is actually still going.
    if not (self.session and self.session.type == "M+") then return end

    local stillActive = false
    if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
        local ok, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
        if ok and mapID then stillActive = true end
    end

    if not stillActive then
        self:FinishMythicPlusSession(false, true)
    end
end


function MCA:PLAYER_REGEN_DISABLED()
    if self.HideRaidBuffWindowForPull then self:HideRaidBuffWindowForPull() elseif self.StopRaidBuffLiveTracking then self:StopRaidBuffLiveTracking(true) end
end
