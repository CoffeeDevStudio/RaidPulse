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

    for _, p in pairs(data.players or {}) do
        local metric = self.GetFightMetric and self:GetFightMetric(p) or 0
        local metricName = ((p.role or "") == "HEALER") and "hps" or "dps"
        local rating = p.mcaRating or self:GetScore(p)
        table.insert(lines, "- " .. (p.name or "?") .. " " .. (p.class or "?") .. " deaths=" .. (p.deaths or 0) .. " " .. metricName .. "=" .. tostring(math.floor(metric or 0)) .. " rating=" .. tostring(rating))
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

-- What --only should be given for this report, matching how the page groups
-- fights: a raid night is addressed by its group, a dungeon by its name,
-- because every run of it is a different group.
function MCA:GetExportSelector(data)
    if not data then return nil end
    if (data.type or "") == "M+" then return data.boss end
    return data.groupID
end

-- Plain double quotes, not string.format("%q"): that escapes for Lua source
-- and would hand back a path with every separator doubled, which no shell
-- wants. Windows paths and boss names cannot contain a double quote.
local function shellQuote(text)
    return '"' .. tostring(text) .. '"'
end

function MCA:GetExportCommand(data)
    data = data or self.lastReport

    local selector = self:GetExportSelector(data)
    local command = "python " .. shellQuote(self:GetExportToolPath())

    if selector and selector ~= "" then
        command = command .. " --only " .. shellQuote(selector)
    end

    return command
end

-- A read-only box rather than a Print: a command line has to be copied, and
-- chat text cannot be selected. The frame is built once and kept.
function MCA:ShowExportWindow(data)
    data = data or self.lastReport

    local f = _G.RaidPulseExportFrame
    if not f then
        f = CreateFrame("Frame", "RaidPulseExportFrame", UIParent, "BackdropTemplate")
        f:SetSize(700, 320)
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

        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        f.title:SetPoint("TOP", 0, -12)

        f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.hint:SetPoint("TOPLEFT", 16, -40)
        f.hint:SetWidth(668)
        f.hint:SetJustifyH("LEFT")

        -- Single line, selected on open, so ctrl+C is the only thing left to do.
        f.cmd = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        f.cmd:SetPoint("TOPLEFT", 20, -78)
        f.cmd:SetSize(660, 22)
        f.cmd:SetAutoFocus(false)
        f.cmd:SetFontObject("GameFontHighlightSmall")
        f.cmd:SetScript("OnEscapePressed", function() f:Hide() end)
        -- Read-only in effect: typing is undone rather than blocked, which
        -- keeps ctrl+C and ctrl+A working.
        f.cmd:SetScript("OnTextChanged", function(box, user)
            if user then box:SetText(box.rpText or "") box:HighlightText() end
        end)

        f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.sub:SetPoint("TOPLEFT", 16, -112)
        f.sub:SetText("Riepilogo testuale")

        local scroll = CreateFrame("ScrollFrame", "RaidPulseExportScroll", f,
            "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 20, -132)
        scroll:SetPoint("BOTTOMRIGHT", -34, 46)

        f.text = CreateFrame("EditBox", nil, scroll)
        f.text:SetMultiLine(true)
        f.text:SetAutoFocus(false)
        f.text:SetFontObject("GameFontHighlightSmall")
        f.text:SetWidth(620)
        f.text:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(f.text)

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

    local command = self:GetExportCommand(data)
    f.cmd.rpText = command
    f.cmd:SetText(command)

    local selector = self:GetExportSelector(data)
    f.title:SetText("Esporta " .. tostring((data and data.boss) or "report"))
    -- Two things the command needs and neither is obvious: the data has to be
    -- on disk, and a relative path only resolves from one folder. The script
    -- prints the /rp toolpath line that removes the second condition.
    local stored = RaidPulseDB.config and RaidPulseDB.config.exportToolPath
    local where = stored and "Copialo con ctrl+C."
        or "Copialo con ctrl+C ed eseguilo dalla cartella _retail_ (lo script stampa "
           .. "un comando /rp toolpath che toglie questo vincolo)."

    f.hint:SetText(selector
        and ("Comando per generare la pagina di questo "
            .. (((data.type or "") == "M+") and "dungeon" or "gruppo raid")
            .. ". Serve un /reload prima: i dati arrivano su disco solo allora. "
            .. where)
        or ("Comando per generare la pagina con tutto lo storico. Serve un /reload "
            .. "prima: i dati arrivano su disco solo allora. " .. where))

    f.text:SetText(self:GetExportText(data))
    f.text:ClearFocus()

    f:Show()
    f.cmd:SetFocus()
    f.cmd:HighlightText()
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
