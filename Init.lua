-- Init.lua
-- Loaded FIRST (before Core, before anything else). Sets up a standalone
-- frame that captures ADDON_ACTION_BLOCKED and ADDON_ACTION_FORBIDDEN,
-- persisting the last 20 events into the RaidPulseDiagLog saved variable
-- so we can inspect them across /reload with /dump RaidPulseDiagLog.

local diagFrame = CreateFrame("Frame")

_G.RaidPulseDiagLog = _G.RaidPulseDiagLog or {}

diagFrame:RegisterEvent("ADDON_ACTION_BLOCKED")
diagFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
diagFrame:RegisterEvent("ADDON_LOADED")
diagFrame:RegisterEvent("PLAYER_LOGIN")
diagFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

local function logDiag(kind, arg1, arg2)
    local entry = {
        t     = date("%H:%M:%S"),
        kind  = kind,
        addon = tostring(arg1),
        func  = tostring(arg2),
        stack = debugstack and debugstack(3, 15, 2) or "n/a",
    }
    -- Which event was being registered at the moment the forbidden fired.
    -- This is set by Events.lua's registration loop, one event at a time.
    if _G.RaidPulseLastEventRegister then
        entry.lastEventRegister = tostring(_G.RaidPulseLastEventRegister)
    end
    if _G.RaidPulseRegisterLog and #_G.RaidPulseRegisterLog > 0 then
        entry.lastEvent = _G.RaidPulseRegisterLog[#_G.RaidPulseRegisterLog]
    end
    table.insert(RaidPulseDiagLog, entry)
    while #RaidPulseDiagLog > 20 do
        table.remove(RaidPulseDiagLog, 1)
    end
    print("|cffff0000[RP " .. kind .. "]|r addon=" .. entry.addon
        .. " func=" .. entry.func
        .. " lastEventRegister=" .. tostring(entry.lastEventRegister))
end

diagFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_ACTION_BLOCKED" then
        logDiag("BLOCKED", arg1, arg2)
    elseif event == "ADDON_ACTION_FORBIDDEN" then
        logDiag("FORBIDDEN", arg1, arg2)
    elseif event == "ADDON_LOADED" and arg1 == "RaidPulse" then
        print("|cff00ccff[RP INIT]|r ADDON_LOADED at " .. date("%H:%M:%S"))
    elseif event == "PLAYER_LOGIN" then
        print("|cff00ccff[RP INIT]|r PLAYER_LOGIN at " .. date("%H:%M:%S"))
    elseif event == "PLAYER_ENTERING_WORLD" then
        print("|cff00ccff[RP INIT]|r PLAYER_ENTERING_WORLD at " .. date("%H:%M:%S"))
    end
end)
