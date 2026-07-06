-- RaidPulse — Core
-- Real-time raid and Mythic+ analytics with local parse.

_G.RaidPulse = _G.RaidPulse or {}
RaidPulse = _G.RaidPulse

-- MCA is kept as an internal alias for the huge existing codebase; it points
-- to the same table as RaidPulse, so both work interchangeably. New code
-- should prefer RaidPulse:… over MCA:…
_G.MCA = _G.MCA or RaidPulse
MCA = _G.MCA
RaidPulse = MCA

MCA.VERSION = "1.0"
MCA.PREFIX  = "RP10"        -- addon comm prefix (must be short)

MCA.session       = nil
MCA.roster        = {}
MCA.guidToName    = {}
MCA.lastReport    = nil
MCA.selectedPlayer = nil
MCA.activeTab     = "summary"

-- Saved variables scaffolding.
RaidPulseDB          = RaidPulseDB or {}
RaidPulseDB.history  = RaidPulseDB.history or {}
RaidPulseDB.config   = RaidPulseDB.config or {}

local defaults = {
    showAfterKill      = true,
    showAfterWipe      = true,
    showMythicEnd      = true,
    syncEnabled        = true,
    debug              = false,
    useElvUISkin       = true,
    autoOpen           = true,
    minimapButtonShown = true,
    minimapAngle       = 225,
    historyLimit       = 50,
}

for k, v in pairs(defaults) do
    if RaidPulseDB.config[k] == nil then
        RaidPulseDB.config[k] = v
    end
end

function MCA:Print(msg)
    print("|cff00ccff[RP]|r " .. tostring(msg))
end

function MCA:Debug(msg)
    if RaidPulseDB.config.debug then
        print("|cffffaa00[RP DEBUG]|r " .. tostring(msg))
    end
end

-- Slash command aliases. The actual handler lives in Config.lua so the
-- subcommand routing is in one place.
SLASH_RAIDPULSE1 = "/rp"
SLASH_RAIDPULSE2 = "/raidpulse"
