_G.MCA = _G.MCA or {}
MCA = _G.MCA

function MCA:BuildReport(session)
    return session
end

function MCA:GetScore(player)
    local score = 100

    if #(player.used or {}) == 0 then score = score - 25 end

    score = score - ((player.deaths or 0) * 30)

    if score < 0 then score = 0 end

    return score
end

function MCA:GetTotals(data)
    local deaths, cds, addon, players, debuffs = 0, 0, 0, 0, 0

    for _, p in pairs(data.players or {}) do
        players = players + 1
        deaths = deaths + (p.deaths or 0)
        cds = cds + #(p.used or {})
        debuffs = debuffs + #(p.debuffs or {})
        if p.hasAddon then addon = addon + 1 end
    end

    local bossKilled = 0
    for _, b in ipairs(data.bosses or {}) do
        if b.success then bossKilled = bossKilled + 1 end
    end

    local buffPresent, buffActive, buffMissing = self:GetRaidBuffSummary(data)

    return {
        players = players,
        deaths = deaths,
        cds = cds,
        addon = addon,
        debuffs = debuffs,
        buffPresent = buffPresent,
        buffActive = buffActive,
        buffMissing = buffMissing,
        bosses = #(data.bosses or {}),
        bossKilled = bossKilled
    }
end

function MCA:GetExportText(data)
    data = data or self.lastReport
    if not data then return "No MCA report." end

    local t = self:GetTotals(data)
    local lines = {
        "RaidPulse v" .. self.VERSION,
        "Report: " .. (data.boss or "?"),
        "Type: " .. (data.type or "?"),
        "Duration: " .. self:FormatTime(data.duration or 0),
        "Players: " .. t.players .. " | MCA: " .. t.addon .. "/" .. t.players .. " | Deaths: " .. t.deaths .. " | Defensives: " .. t.cds .. " | Debuffs: " .. t.debuffs,
        ""
    }

    local showParse = self:IsParseEnabled()

    for _, p in pairs(data.players or {}) do
        local metric = self.GetFightMetric and self:GetFightMetric(p) or 0
        local metricName = ((p.role or "") == "HEALER") and "hps" or "dps"
        local line = "- " .. (p.name or "?") .. " " .. (p.class or "?")
            .. " deaths=" .. (p.deaths or 0)
            .. " " .. metricName .. "=" .. tostring(math.floor(metric or 0))

        if showParse then
            line = line .. " rating=" .. tostring(p.mcaRating or self:GetScore(p))
        end

        table.insert(lines, line)
    end

    return table.concat(lines, "\n")
end

-- Where tools/export_report.py lives. Relative by default, which works when
-- the command is run from the _retail_ folder; an addon cannot read its own
-- absolute path, so /rp toolpath stores one for anyone who would rather run
-- it from elsewhere.
local DEFAULT_TOOL_PATH = "Interface" .. string.char(92) .. "AddOns"
    .. string.char(92) .. "RaidPulse" .. string.char(92) .. "tools"
    .. string.char(92) .. "export_report.py"

function MCA:GetExportToolPath()
    local stored = RaidPulseDB and RaidPulseDB.config
        and RaidPulseDB.config.exportToolPath
    if type(stored) == "string" and stored ~= "" then return stored end
    return DEFAULT_TOOL_PATH
end

-- Plain double quotes, not string.format("%q"): that escapes for Lua source
-- and would hand back a path with every separator doubled, which no shell
-- wants. Windows paths and boss names cannot contain a double quote.
local function shellQuote(text)
    return '"' .. tostring(text) .. '"'
end

-- `selectors` is what --only receives, one per ticked row: a raid night's
-- group id, or a dungeon's name. `day` narrows it further, which matters both
-- because a raid group can run past midnight and because an evening of keys is
-- several dungeons that only the date has in common.
--
-- No selector at all is not an error: it means the whole day, or the whole
-- history when no day is chosen either.
function MCA:GetExportCommand(selectors, day)
    local command = "python " .. shellQuote(self:GetExportToolPath())

    for _, selector in ipairs(selectors or {}) do
        if selector and selector ~= "" then
            command = command .. " --only " .. shellQuote(selector)
        end
    end

    if day and day ~= "" then
        command = command .. " --day " .. shellQuote(day)
    end
    return command
end

-- A picker, not a printout.
--
-- This used to export whatever report was open, which is the one case that
-- does not need a window: the point of the page is post-raid, when the night
-- is over and you want that night and not the pull still on screen. It now
-- lists every raid night and dungeon in the history and builds the command
-- for the one selected.
--
-- The command lives in an edit box because a command line has to be copied,
-- and chat text cannot be selected.

local EXPORT_ROW_H = 22

local function exportRow(f, index)
    local row = f.rows[index]
    if row then return row end

    row = CreateFrame("Button", nil, f.listChild, "BackdropTemplate")
    row:SetPoint("TOPLEFT", 0, -(index - 1) * (EXPORT_ROW_H + 2))
    row:SetSize(620, EXPORT_ROW_H)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", 8, 0)
    row.text:SetWidth(600)
    row.text:SetJustifyH("LEFT")

    f.rows[index] = row
    return row
end

-- Five, not more: the row is "Tutti" plus the days, and six buttons at 80
-- apart is what fits beside the whole-day button in a 700-wide window.
local EXPORT_MAX_DAYS = 5

local function exportDayButton(f, index)
    local button = f.dayButtons[index]
    if button then return button end

    button = CreateFrame("Button", nil, f, "BackdropTemplate")
    button:SetPoint("TOPLEFT", 20 + (index - 1) * 80, -60)
    button:SetSize(76, 22)

    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.text:SetPoint("CENTER")

    f.dayButtons[index] = button
    return button
end

function MCA:RefreshExportWindow()
    local f = _G.RaidPulseExportFrame
    if not f or not f:IsShown() then return end

    -- Day first, because the rows are built for that day: their counts, their
    -- key levels and their span all have to match what the command exports.
    local days = self:GetExportDays()
    while #days > EXPORT_MAX_DAYS do table.remove(days) end

    local activeDay
    for _, day in ipairs(days) do
        if day == self.exportDay then activeDay = day end
    end
    self.exportDay = activeDay

    local shown = {"Tutti"}
    for _, day in ipairs(days) do shown[#shown + 1] = day end

    for index, label in ipairs(shown) do
        local button = exportDayButton(f, index)
        local day = (index > 1) and label or nil
        local active = (day == activeDay)

        self:SetBackdropSolid(button,
            active and {0.10,0.09,0.03,0.95} or {0.045,0.045,0.05,0.85},
            active and {0.95,0.78,0.05,1} or {0.20,0.21,0.22,1})
        button.text:SetText(label)
        button.text:SetTextColor(unpack(active and self:UIColor("accent")
            or self:UIColor("gray")))

        button:SetScript("OnClick", function()
            -- A new day lists different rows, and ticks that refer to the old
            -- ones would export sections nobody can see.
            MCA.exportDay = day
            MCA.exportSelected = {}
            MCA:RefreshExportWindow()
        end)
        button:Show()
    end
    for index = #shown + 1, #f.dayButtons do f.dayButtons[index]:Hide() end

    local groups = self:GetExportGroups(activeDay)

    -- Ticks, not one selection. An evening of keys is several dungeons with
    -- nothing in common but the date, and exporting them together is the
    -- reason this window exists.
    self.exportSelected = self.exportSelected or {}

    -- A tick left over from a group that the day filter hides would export
    -- something not on screen, so only what is listed can stay selected.
    local visible, ticked = {}, 0
    for _, entry in ipairs(groups) do visible[entry.key] = true end
    for key in pairs(self.exportSelected) do
        if not visible[key] then self.exportSelected[key] = nil end
    end
    for _ in pairs(self.exportSelected) do ticked = ticked + 1 end

    for index, entry in ipairs(groups) do
        local row = exportRow(f, index)
        local on = self.exportSelected[entry.key] and true or false

        self:SetBackdropSolid(row,
            on and {0.10,0.09,0.03,0.95} or {0.045,0.045,0.05,0.85},
            on and {0.95,0.78,0.05,1} or {0.20,0.21,0.22,1})

        local detail
        if entry.kind == "M+" then
            local keys = ""
            if entry.keyMin then
                keys = (entry.keyMin == entry.keyMax)
                    and string.format("  chiave +%d", entry.keyMin)
                    or string.format("  chiavi +%d..+%d", entry.keyMin, entry.keyMax)
            end
            detail = string.format("%d run%s  %d completate",
                entry.count, keys, entry.kills)
        else
            detail = string.format("%d tentativi  %d kill / %d wipe - %d player",
                entry.count, entry.kills, entry.count - entry.kills, entry.playerCount)
        end

        row.text:SetText(string.format("|cff%s[%s] %s|r  %s  |cff9aa0a8%s|r",
            on and "ffd100" or "e6e6e6", on and "x" or " ",
            entry.stamp, entry.label, detail))

        row:SetScript("OnClick", function()
            MCA.exportSelected[entry.key] = (not on) or nil
            MCA:RefreshExportWindow()
        end)
        row:Show()
    end

    for index = #groups + 1, #f.rows do f.rows[index]:Hide() end
    f.listChild:SetHeight(math.max(1, #groups * (EXPORT_ROW_H + 2)))

    f.selectAll:SetScript("OnClick", function()
        MCA.exportSelected = {}
        for _, entry in ipairs(groups) do
            MCA.exportSelected[entry.key] = true
        end
        MCA:RefreshExportWindow()
    end)
    f.selectNone:SetScript("OnClick", function()
        MCA.exportSelected = {}
        MCA:RefreshExportWindow()
    end)

    if #groups == 0 then
        f.cmd.rpText = ""
        f.cmd:SetText("")
        f.hint:SetText("Niente da esportare in questo giorno.")
        return
    end

    -- Selectors in the order the rows are in, so the command reads the way the
    -- list does.
    local selectors = {}
    for _, entry in ipairs(groups) do
        if self.exportSelected[entry.key] then
            selectors[#selectors + 1] = entry.selector
        end
    end

    local command = self:GetExportCommand(selectors, activeDay)
    f.cmd.rpText = command
    f.cmd:SetText(command)
    f.cmd:SetFocus()
    f.cmd:HighlightText()

    -- Two conditions the command depends on, neither of them obvious: the data
    -- has to be on disk, and a relative path only resolves from one folder.
    local stored = RaidPulseDB.config and RaidPulseDB.config.exportToolPath

    local what
    if ticked == 0 then
        what = activeDay and ("tutto il " .. activeDay) or "tutto lo storico"
    elseif ticked == 1 then
        what = "1 sezione" .. (activeDay and (" del " .. activeDay) or "")
    else
        what = ticked .. " sezioni" .. (activeDay and (" del " .. activeDay) or "")
    end

    f.hint:SetText("Selezionato: " .. what
        .. ".  Le SavedVariables si scrivono al /reload: un tentativo appena "
        .. "finito non e' ancora su disco."
        .. (stored and "" or "  Esegui dalla cartella _retail_, oppure lancia lo "
            .. "script una volta: stampa un /rp toolpath che toglie il vincolo."))
end

function MCA:ShowExportWindow(data)
    data = data or self.lastReport

    local f = _G.RaidPulseExportFrame
    if not f then
        f = CreateFrame("Frame", "RaidPulseExportFrame", UIParent, "BackdropTemplate")
        f:SetSize(700, 420)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        self:SetBackdropSolid(f, self:UIColor("bg"), {0.28,0.28,0.30,1})

        if UISpecialFrames then
            table.insert(UISpecialFrames, "RaidPulseExportFrame")
        end

        f.rows = {}
        f.dayButtons = {}

        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        f.title:SetPoint("TOP", 0, -12)
        f.title:SetText("Esporta pagina web")

        f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.sub:SetPoint("TOPLEFT", 16, -40)
        f.sub:SetText("Giorno, poi la serata di raid o la dungeon da esportare:")

        -- No "whole day" button any more: no tick at all already means the
        -- whole day, which is one rule instead of two controls that could
        -- disagree.
        local function pickButton(text, x)
            local button = CreateFrame("Button", nil, f, "BackdropTemplate")
            button:SetPoint("BOTTOMLEFT", x, 14)
            button:SetSize(140, 24)
            MCA:SetBackdropSolid(button, {0.06,0.055,0.025,0.88}, {0.45,0.35,0.02,1})
            local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            label:SetPoint("CENTER")
            label:SetText(text)
            label:SetTextColor(1, 0.82, 0)
            return button
        end

        f.selectAll = pickButton("Seleziona tutto", 20)
        f.selectNone = pickButton("Deseleziona tutto", 170)

        local scroll = CreateFrame("ScrollFrame", "RaidPulseExportScroll", f,
            "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 20, -90)
        scroll:SetSize(640, 188)

        f.listChild = CreateFrame("Frame", nil, scroll)
        f.listChild:SetSize(620, 1)
        scroll:SetScrollChild(f.listChild)

        f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.hint:SetPoint("TOPLEFT", 16, -288)
        f.hint:SetWidth(668)
        f.hint:SetJustifyH("LEFT")
        f.hint:SetTextColor(0.68, 0.68, 0.68)

        f.cmd = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        f.cmd:SetPoint("TOPLEFT", 24, -340)
        f.cmd:SetSize(652, 22)
        f.cmd:SetAutoFocus(false)
        f.cmd:SetFontObject("GameFontHighlightSmall")
        f.cmd:SetScript("OnEscapePressed", function() f:Hide() end)
        -- Read-only in effect: typing is undone rather than blocked, which
        -- keeps ctrl+C and ctrl+A working.
        f.cmd:SetScript("OnTextChanged", function(box, user)
            if user then box:SetText(box.rpText or "") box:HighlightText() end
        end)

        local close = CreateFrame("Button", nil, f, "BackdropTemplate")
        close:SetPoint("BOTTOMRIGHT", -16, 14)
        close:SetSize(110, 24)
        self:SetBackdropSolid(close, {0.06,0.055,0.025,0.88}, {0.45,0.35,0.02,1})
        local label = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("CENTER")
        label:SetText("Chiudi")
        label:SetTextColor(1, 0.82, 0)
        close:SetScript("OnClick", function() f:Hide() end)
    end

    -- Opens on the group of whatever is on screen, which is the likely one
    -- right after a pull, and stays wherever it was left otherwise.
    local fromReport = self:GetExportGroupKey(data)
    if fromReport then
        self.exportDay = nil
        self.exportSelected = {[fromReport] = true}
    end

    f:Show()
    self:RefreshExportWindow()
end

-- Which chat channel "Share in chat" should post to.
function MCA:GetShareChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

function MCA:ShareSummary(data)
    data = data or self.lastReport
    if not data then return end

    local channel = self:GetShareChannel()
    local chatType = nil

    if channel == "RAID" then chatType = "RAID"
    elseif channel == "INSTANCE_CHAT" then chatType = "INSTANCE_CHAT"
    elseif channel == "PARTY" then chatType = "PARTY" end

    if not chatType then
        self:Print("Non sei in gruppo.")
        return
    end

    -- Build the same player data the DPS/Tank and Healer tables show, then
    -- post it grouped by role: Tank first, then DPS, then Healer.
    local players = self:BuildPlayerList(data)
    if self.CalculateRoleRatings then self:CalculateRoleRatings(players) end

    local function roleKey(p)
        local r = (p.role or ""):upper()
        if r == "TANK" then return 1 end
        if r == "HEALER" then return 3 end
        return 2 -- DPS / everything else
    end

    -- Stable sort: by role bucket, then by metric descending within the bucket.
    table.sort(players, function(a, b)
        local ra, rb = roleKey(a), roleKey(b)
        if ra ~= rb then return ra < rb end
        return (self:GetFightMetric(a) or 0) > (self:GetFightMetric(b) or 0)
    end)

    local t = self:GetTotals(data)
    SendChatMessage("[MCA] " .. (data.boss or "?") .. " - Durata: " .. self:FormatTime(data.duration or 0) .. " - Deaths: " .. t.deaths, chatType)

    local roleTitles = { [1] = "== TANK ==", [2] = "== DPS ==", [3] = "== HEALER ==" }
    local lastRole = nil

    for _, p in ipairs(players) do
        local rk = roleKey(p)
        if rk ~= lastRole then
            SendChatMessage(roleTitles[rk], chatType)
            lastRole = rk
        end

        local metricLabel = (rk == 3) and "HPS" or "DPS"
        local metric = self:FormatMetricValue(self:GetFightMetric(p))
        local _, _, parseText = self:ResolvePlayerParse(p, data)

        SendChatMessage(string.format("%s (%s) - %s: %s - Parse: %s",
            p.name or "?", self:PrettyClass(p.class), metricLabel, metric, parseText), chatType)
    end
end
