-- RaidPulse — command handler
-- Registers /rp with a rich subcommand set. Primary slash is /rp (short for
-- RaidPulse); no legacy aliases here — Core.lua already declared SLASH_RAIDPULSE.

_G.MCA = _G.MCA or {}
MCA = _G.MCA

SlashCmdList["RAIDPULSE"] = function(msg)
    msg = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))
    msg = string.gsub(msg, "%s+", " ")

    if msg == "test" or msg == "mplus test" then
        local players = {
            Coffettino = {
                name = "Coffettino",
                class = "MAGE",
                role = "DAMAGER",
                deaths = 1,
                deathTime = 136,
                hasAddon = true,
                used = {
                    {name="Ice Barrier", spellID=11426, time=6},
                    {name="Ice Block", spellID=45438, time=121}
                }
            },
            Tankone = {
                name = "Tankone",
                class = "WARRIOR",
                role = "TANK",
                deaths = 0,
                hasAddon = true,
                used = {
                    {name="Shield Wall", spellID=871, time=55},
                    {name="Last Stand", spellID=12975, time=230}
                }
            },
            Roguetest = {
                name = "Roguetest",
                class = "ROGUE",
                role = "DAMAGER",
                deaths = 1,
                deathTime = 315,
                hasAddon = false,
                used = {}
            },
            Healertwo = {
                name = "Healertwo",
                class = "DRUID",
                role = "HEALER",
                deaths = 0,
                hasAddon = true,
                used = {
                    {name="Barkskin", spellID=22812, time=260}
                },
                debuffs = {
                    {name="Test Debuff", spellID=209858, time=90}
                }
            }
        }

        MCA:ShowUI({
            type = "M+",
            boss = "Ara-Kara",
            difficulty = "Mythic+",
            result = true,
            duration = 1420,
            bosses = {
                {name="Avanoxx", success=true, startTime=20, endTime=90, duration=70},
                {name="Anub'zekt", success=true, startTime=210, endTime=280, duration=70},
                {name="Ki'katal", success=true, startTime=300, endTime=370, duration=70}
            },
            players = players,
            raidBuffs = {
                {key="arcane_intellect", class="MAGE", spellID=1459, name="Arcane Intellect", short="Int", classPresent=true, total=4, missing=0, active=true},
                {key="battle_shout", class="WARRIOR", spellID=6673, name="Battle Shout", short="BS", classPresent=true, total=4, missing=0, active=true},
                {key="mark_of_the_wild", class="DRUID", spellID=1126, name="Mark of the Wild", short="Mark", classPresent=true, total=4, missing=1, active=false},
                {key="power_word_fortitude", class="PRIEST", spellID=21562, name="Power Word: Fortitude", short="Fort", classPresent=false, total=4, missing=4, active=false}
            },
            raidBuffMatrix = {
                buffs = {
                    {key="arcane_intellect", class="MAGE", spellID=1459, name="Arcane Intellect", short="Int", classPresent=true},
                    {key="battle_shout", class="WARRIOR", spellID=6673, name="Battle Shout", short="BS", classPresent=true},
                    {key="mark_of_the_wild", class="DRUID", spellID=1126, name="Mark of the Wild", short="Mark", classPresent=true},
                    {key="power_word_fortitude", class="PRIEST", spellID=21562, name="Power Word: Fortitude", short="Fort", classPresent=false}
                },
                players = {
                    {name="Coffettino", class="MAGE", role="DAMAGER", buffs={arcane_intellect=true,battle_shout=true,mark_of_the_wild=false,power_word_fortitude=nil}},
                    {name="Tankone", class="WARRIOR", role="TANK", buffs={arcane_intellect=true,battle_shout=true,mark_of_the_wild=true,power_word_fortitude=nil}},
                    {name="Roguetest", class="ROGUE", role="DAMAGER", buffs={arcane_intellect=true,battle_shout=true,mark_of_the_wild=true,power_word_fortitude=nil}},
                    {name="Healertwo", class="DRUID", role="HEALER", buffs={arcane_intellect=true,battle_shout=true,mark_of_the_wild=true,power_word_fortitude=nil}}
                }
            },
            timeline = {
                {type="defensive", time=55, text="Tankone usa Shield Wall", spellID=871},
                {type="death", time=136, text="Coffettino muore"},
                {type="debuff", time=90, text="Healertwo prende Test Debuff", spellID=209858}
            }
        })

    elseif msg == "" or msg == "show" then
        -- Falls back to the newest saved report, so this works after a
        -- reload and after the in-memory one has been cleared.
        local report = MCA:GetLastAvailableReport()
        if report and not report.isEmpty then
            MCA:ShowUI(report)
        else
            MCA:Print("Nessun report disponibile.")
        end
    elseif msg == "buffs" or msg == "raidbuffs" then
        if MCA.ShowRaidBuffWindow then MCA:ShowRaidBuffWindow() end
    elseif msg == "minimap" then
        if MCA.CreateMinimapButton then MCA:CreateMinimapButton() end
        if MCA.MinimapButton_SetShown then MCA:MinimapButton_SetShown(true) end
        MCA:Print("Bottone minimappa attivo.")
    elseif msg == "debug on" then
        RaidPulseDB.config.debug = true
        MCA:Print("debug ON")
    elseif msg == "debug off" then
        RaidPulseDB.config.debug = false
        MCA:Print("debug OFF")
    elseif msg == "export" then
        MCA:ShowExportWindow(MCA.lastReport)
    elseif msg == "share" then
        MCA:ShareSummary(MCA.lastReport)
    elseif msg == "meter" then
        if MCA.ReportDamageMeterState then MCA:ReportDamageMeterState() end
    elseif msg == "pool" then
        if MCA.ReportWidgetPool then MCA:ReportWidgetPool() end
    elseif msg == "watcher" or msg == "deaths" then
        if MCA.ReportWatcherState then MCA:ReportWatcherState() end
    elseif msg == "parse" then
        -- Diagnostic: which benchmark DB is loaded, and does it actually cover
        -- the fight we last recorded? Without this, a season change looks
        -- exactly like a bug — every parse silently reads "-".
        local db = _G.RaidPulse_Benchmarks
        if type(db) ~= "table" then
            MCA:Print("Benchmarks: NON caricati (BenchmarksDB.lua mancante o non valido).")
        else
            local encCount = 0
            for _ in pairs(db.encounters or {}) do encCount = encCount + 1 end
            local zones = {}
            for _, z in ipairs(db.zones or {}) do zones[#zones + 1] = tostring(z) end
            MCA:Print(string.format("Benchmarks: schema=%s season=%s zone=%s encounter=%d generato=%s",
                tostring(db.schema or "?"), tostring(db.season or "?"),
                (#zones > 0 and table.concat(zones, ",") or "?"), encCount,
                tostring(db.generated or "?")))

            local rep = MCA.lastReport
            if not rep then
                MCA:Print("  Nessun report recente da confrontare.")
            elseif rep.type ~= "raid" then
                MCA:Print("  Ultimo report: " .. tostring(rep.boss) ..
                    " (M+ — i parse coprono solo i raid).")
            else
                local enc = (db.encounters or {})[rep.encounterID or -1]
                if enc then
                    MCA:Print("  Ultimo report: " .. tostring(rep.boss) ..
                        " -> coperto dal DB (" .. tostring(enc.zoneName or "?") .. ").")
                else
                    MCA:Print("  Ultimo report: " .. tostring(rep.boss) ..
                        " (encounterID " .. tostring(rep.encounterID) ..
                        ") -> NON nel DB: rigenera BenchmarksDB per questa stagione.")
                end
            end
        end
    else
        MCA:Print("Commands: /rp test, /rp show, /rp minimap, /rp debug on/off, /rp export, /rp share, /rp buffs, /rp parse, /rp watcher, /rp pool, /rp meter")
    end
end
