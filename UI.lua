_G.MCA = _G.MCA or {}
MCA = _G.MCA

-- One content geometry for every full-page tab. These used to be written out
-- at each call site and had drifted apart — most tabs sat at x=12 with a width
-- of 1100, the history at x=20 with 1060, settings at 20 and the text summary
-- at 24 — so the table visibly jumped sideways when switching tabs.
--
-- ---------------------------------------------------------------------------
-- Layout. Everything is derived from the frame size, one margin and one gap,
-- so the pieces cannot drift apart again: the window used to leave 8px on the
-- left and 50 on the right because the content width was written out by hand.
-- ---------------------------------------------------------------------------
local FRAME_W, FRAME_H = 1320, 780
local MARGIN = 8            -- same on the left, the right and the top
local GAP = 16              -- between blocks, on both axes
local BTN_H = 34

local SIDE_X, SIDE_Y = MARGIN, -MARGIN
local SIDE_W, SIDE_H = 138, 702
local CONTENT_BOTTOM = SIDE_Y - SIDE_H            -- every block ends here

-- The rectangle the dashboard, the summary and the scroll container share:
-- one gap right of the sidebar, and the same margin on the right as the left.
local CONTENT_X = SIDE_X + SIDE_W + GAP
local CONTENT_W = FRAME_W - MARGIN - CONTENT_X

local DASH_Y, DASH_H = -36, 64                    -- the KPI strip under the title
local BODY_Y = DASH_Y - DASH_H - GAP              -- top of everything below it
local BODY_H = math.abs(CONTENT_BOTTOM) - math.abs(BODY_Y)

-- Margins *inside* the scroll: Scroll() insets its child by 4 and sizes it to
-- CONTENT_W - 10, and the scrollbar sits over the right edge of that.
local PAGE_X = 8
local PAGE_W = CONTENT_W - 10 - PAGE_X - 24
local PAGE_H = 430          -- panel height for the tabs that still use one
local PAGE_PAD = 8          -- inner padding for text drawn straight onto the page

MCA.ClassIconCoords = {
    WARRIOR={0,0.25,0,0.25}, MAGE={0.25,0.5,0,0.25}, ROGUE={0.5,0.75,0,0.25}, DRUID={0.75,1,0,0.25},
    HUNTER={0,0.25,0.25,0.5}, SHAMAN={0.25,0.5,0.25,0.5}, PRIEST={0.5,0.75,0.25,0.5}, WARLOCK={0.75,1,0.25,0.5},
    PALADIN={0,0.25,0.5,0.75}, DEATHKNIGHT={0.25,0.5,0.5,0.75}, MONK={0.5,0.75,0.5,0.75}, DEMONHUNTER={0.75,1,0.5,0.75}, EVOKER={0,0.25,0.75,1}
}

MCA.RoleLabel = {
    TANK = "Tank",
    HEALER = "Healer",
    DAMAGER = "DPS",
    NONE = "DPS"
}

function MCA:UIColor(name)
    local colors = {
        bg = {0.015,0.018,0.020,0.92},
        panel = {0.025,0.028,0.030,0.88},
        panel2 = {0.035,0.038,0.042,0.90},
        row = {0.07,0.075,0.08,0.50},
        rowAlt = {0.10,0.105,0.11,0.50},
        border = {0.22,0.24,0.26,0.90},
        accent = {1.0,0.82,0.00,1},
        purple = {0.78,0.25,1.0,1},
        green = {0.20,1.0,0.20,1},
        red = {1.0,0.18,0.18,1},
        orange = {1.0,0.55,0.0,1},
        blue = {0.30,0.65,1.0,1},
        gray = {0.68,0.68,0.68,1},
        white = {0.92,0.92,0.92,1}
    }
    return colors[name] or colors.white
end

function MCA:SetBackdropSolid(frame, bg, border)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1
    })
    local b = bg or self:UIColor("panel")
    local e = border or self:UIColor("border")
    frame:SetBackdropColor(b[1],b[2],b[3],b[4] or 1)
    frame:SetBackdropBorderColor(e[1],e[2],e[3],e[4] or 1)
end

-- ---------------------------------------------------------------------------
-- Widget recycling.
--
-- WoW never frees a frame. Hide() plus SetParent(nil) only orphans it, and the
-- memory is held for the rest of the session — so rebuilding the whole window
-- on every tab click, every report open and every render leaked a full
-- window's worth of frames and fontstrings each time. A 25-player Player tab
-- is ~25 row frames and ~175 fontstrings; a raid night's worth of clicks adds
-- up to thousands of orphaned objects.
--
-- Widgets are now taken from a pool and handed back at the start of each
-- rebuild. Fontstrings and textures belong to the frame that created them, so
-- they ride along with their frame and are handed out again in order.
-- ---------------------------------------------------------------------------
-- Bumped on every recycle. Deferred work captures it and bails if a rebuild
-- happened in the meantime, so a C_Timer callback cannot land on a frame that
-- has since been handed to something else.
local renderGeneration = 0
local widgetPools = {}      -- "type|template" -> free frames
local liveWidgets = {}      -- handed out since the last recycle
local poolAttic            -- parent for parked frames; created on first use

local function poolKeyFor(ftype, template)
    return (ftype or "Frame") .. "|" .. (template or "")
end

-- Reset the per-frame cursors so its fontstrings and textures are handed out
-- from the start again.
local function resetWidgetCursors(f)
    f._rpTextCursor = 0
    f._rpTexCursor = 0
end

function MCA:AcquireFrame(ftype, parent, template)
    local key = poolKeyFor(ftype, template)
    local pool = widgetPools[key]
    local f = pool and table.remove(pool)

    if f then
        f:SetParent(parent)
        f:ClearAllPoints()
        -- Scripts are set per use; a recycled row must not keep the previous
        -- occupant's click handler.
        for _, script in ipairs({"OnClick", "OnEnter", "OnLeave", "OnUpdate", "OnDragStart", "OnDragStop", "OnHide", "OnShow"}) do
            if f:HasScript(script) then f:SetScript(script, nil) end
        end
        f:Show()
    else
        f = CreateFrame(ftype or "Frame", nil, parent, template)
        f._rpPoolKey = key
    end

    resetWidgetCursors(f)
    liveWidgets[#liveWidgets + 1] = f
    return f
end

function MCA:AcquireText(frame, font)
    frame._rpTexts = frame._rpTexts or {}
    frame._rpTextCursor = (frame._rpTextCursor or 0) + 1

    local fs = frame._rpTexts[frame._rpTextCursor]
    if not fs then
        fs = frame:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
        frame._rpTexts[frame._rpTextCursor] = fs
    end

    fs:SetFontObject(font or "GameFontNormal")
    fs:ClearAllPoints()
    fs:Show()
    return fs
end

function MCA:AcquireTexture(frame, layer)
    frame._rpTextures = frame._rpTextures or {}
    frame._rpTexCursor = (frame._rpTexCursor or 0) + 1

    local t = frame._rpTextures[frame._rpTexCursor]
    if not t then
        t = frame:CreateTexture(nil, layer or "ARTWORK")
        frame._rpTextures[frame._rpTexCursor] = t
    end

    t:ClearAllPoints()
    t:SetTexCoord(0, 1, 0, 1)
    t:SetVertexColor(1, 1, 1, 1)
    t:Show()
    return t
end

-- Hide any fontstring or texture the frame owns beyond what this pass used,
-- so a recycled frame does not show the previous occupant's leftovers.
local function hideUnusedChildren(f)
    if f._rpTexts then
        for i = (f._rpTextCursor or 0) + 1, #f._rpTexts do f._rpTexts[i]:Hide() end
    end
    if f._rpTextures then
        for i = (f._rpTexCursor or 0) + 1, #f._rpTextures do f._rpTextures[i]:Hide() end
    end
end

function MCA:TrimWidget(f)
    hideUnusedChildren(f)
end

function MCA:RenderGeneration()
    return renderGeneration
end

function MCA:RecycleWidgets()
    renderGeneration = renderGeneration + 1
    if not poolAttic then
        poolAttic = CreateFrame("Frame", nil, UIParent)
        poolAttic:Hide()
    end

    for i = #liveWidgets, 1, -1 do
        local f = liveWidgets[i]
        liveWidgets[i] = nil

        hideUnusedChildren(f)
        if f._rpTexts then
            for j = 1, #f._rpTexts do f._rpTexts[j]:Hide() end
        end
        if f._rpTextures then
            for j = 1, #f._rpTextures do f._rpTextures[j]:Hide() end
        end

        f:Hide()
        f:ClearAllPoints()
        f:SetParent(poolAttic)

        local key = f._rpPoolKey or poolKeyFor("Frame", nil)
        widgetPools[key] = widgetPools[key] or {}
        table.insert(widgetPools[key], f)
    end
end

-- Diagnostic for /rp pool.
function MCA:ReportWidgetPool()
    local free, kinds = 0, 0
    for key, list in pairs(widgetPools) do
        kinds = kinds + 1
        free = free + #list
        self:Print(string.format("  %-34s %d liberi", key, #list))
    end
    self:Print(string.format("Pool widget: %d tipi, %d frame riutilizzabili, %d in uso",
        kinds, free, #liveWidgets))
end

function MCA:Text(parent, text, font, point, width, color, justify)
    local fs = self:AcquireText(parent, font)
    fs:SetPoint(unpack(point))
    -- Every property is set unconditionally: a recycled fontstring would
    -- otherwise keep the previous width, colour or justification.
    fs:SetWidth(width or 0)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetText(text or "")
    local c = color or self:UIColor("white")
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    return fs
end

function MCA:Panel(parent, point, w, h, bg, border)
    local f = self:AcquireFrame("Frame", parent, "BackdropTemplate")
    f:SetPoint(unpack(point))
    f:SetSize(w,h)
    self:SetBackdropSolid(f, bg or self:UIColor("panel"), border or self:UIColor("border"))
    return f
end

function MCA:Button(parent, text, point, w, h, fn, danger)
    local b = self:AcquireFrame("Button", parent, "BackdropTemplate")
    b:SetPoint(unpack(point))
    b:SetSize(w,h)
    local bg = danger and {0.18,0.03,0.03,0.88} or {0.06,0.055,0.025,0.88}
    local br = danger and {0.65,0.12,0.12,1} or {0.45,0.35,0.02,1}
    self:SetBackdropSolid(b, bg, br)
    self:Text(b, text, "GameFontNormal", {"CENTER", b, "CENTER", 0, 0}, w-8, danger and {1,0.55,0.55,1} or self:UIColor("accent"), "CENTER")
    b:SetScript("OnClick", fn or function() end)
    b:SetScript("OnEnter", function()
        b:SetBackdropBorderColor(1,0.82,0,1)
    end)
    b:SetScript("OnLeave", function()
        b:SetBackdropBorderColor(br[1],br[2],br[3],br[4] or 1)
    end)
    return b
end



-- Button that can render as selected. Button() captures its border colour in
-- the OnLeave closure, so an active state painted over it would be wiped the
-- first time the mouse left; this keeps the selected colours in the closure.
function MCA:FilterButton(parent, text, point, w, h, active, fn)
    local b = self:AcquireFrame("Button", parent, "BackdropTemplate")
    b:SetPoint(unpack(point))
    b:SetSize(w, h)

    local bg = active and {0.10,0.09,0.03,0.95} or {0.045,0.045,0.05,0.88}
    local br = active and {0.95,0.78,0.05,1} or {0.22,0.23,0.24,1}
    self:SetBackdropSolid(b, bg, br)
    self:Text(b, text, "GameFontNormalSmall", {"CENTER", b, "CENTER", 0, 0}, w - 6,
        active and self:UIColor("accent") or self:UIColor("gray"), "CENTER")

    b:SetScript("OnClick", fn or function() end)
    b:SetScript("OnEnter", function() b:SetBackdropBorderColor(1, 0.82, 0, 1) end)
    b:SetScript("OnLeave", function() b:SetBackdropBorderColor(br[1], br[2], br[3], br[4] or 1) end)
    return b
end


-- `flush` drops the container's own background and border, so the table reads
-- as part of the panel it sits in instead of as a second boxed-in table. The
-- scrolling itself is unaffected; only the chrome goes.
local TRANSPARENT = {0, 0, 0, 0}

function MCA:Scroll(parent, point, w, h, bg, flush)
    local outer = self:Panel(parent, point, w, h,
        flush and TRANSPARENT or bg,
        flush and TRANSPARENT or nil)
    local scroll = self:AcquireFrame("ScrollFrame", outer, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -4, 4)

    local child = self:AcquireFrame("Frame", scroll)
    child:SetSize(w - 10, h - 8)
    scroll:SetScrollChild(child)
    -- A recycled scroll keeps the offset its previous table was left at, which
    -- would open the next tab already scrolled down.
    scroll:SetVerticalScroll(0)

    scroll.mdrOuterWidth = w
    scroll.mdrOuterHeight = h
    scroll.mdrChild = child

    if scroll.ScrollBar then
        self:ApplyScrollBarStyle(scroll.ScrollBar)
        scroll.ScrollBar:Hide()
    end

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = self:GetVerticalScrollRange()
        if maxScroll <= 0 then return end
        local current = self:GetVerticalScroll()
        local step = 45
        if delta < 0 then
            self:SetVerticalScroll(math.min(current + step, maxScroll))
        else
            self:SetVerticalScroll(math.max(current - step, 0))
        end
    end)

    return outer, child, scroll
end

function MCA:UpdateScrollBar(child, scroll, neededHeight)
    if not child then return end

    local parentHeight = 1
    if child:GetParent() and child:GetParent().GetHeight then
        parentHeight = child:GetParent():GetHeight() or 1
    end

    local height = math.max(neededHeight or 1, parentHeight)
    child:SetHeight(height)

    if scroll and scroll.ScrollBar then
        local gen = self:RenderGeneration()
        C_Timer.After(0, function()
            if not scroll or not scroll.GetVerticalScrollRange then return end
            -- The window was rebuilt before this ran; this scroll may now
            -- belong to a different table.
            if MCA:RenderGeneration() ~= gen then return end
            local needsScroll = scroll:GetVerticalScrollRange() and scroll:GetVerticalScrollRange() > 1
            if needsScroll then
                scroll.ScrollBar:Show()
                scroll:SetPoint("BOTTOMRIGHT", -24, 4)
                if scroll.mdrChild then scroll.mdrChild:SetWidth((scroll.mdrOuterWidth or 100) - 34) end
            else
                scroll.ScrollBar:Hide()
                scroll:SetPoint("BOTTOMRIGHT", -4, 4)
                if scroll.mdrChild then scroll.mdrChild:SetWidth((scroll.mdrOuterWidth or 100) - 10) end
            end
        end)
    end
end

function MCA:GetInnerWidth(parent, fallback)
    if parent and parent.GetWidth then
        return math.max((parent:GetWidth() or fallback or 100) - 12, 50)
    end
    return fallback or 100
end

function MCA:ClassIcon(parent, class, x, y, size)
    local icon = self:AcquireTexture(parent, "ARTWORK")
    icon:SetPoint("TOPLEFT", x, y)
    icon:SetSize(size, size)
    icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")

    local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class or ""]

    if coords then
        icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        return icon
    end

    local c = self.ClassIconCoords[class or ""]
    if c then
        icon:SetTexCoord(c[1], c[2], c[3], c[4])
    else
        icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        icon:SetTexCoord(0,1,0,1)
    end

    return icon
end

function MCA:SpellIcon(parent, spellID, x, y, size, label)
    local f = self:AcquireFrame("Frame", parent)
    f:SetPoint("TOPLEFT", x, y)
    f:SetSize(size, size + (label and 12 or 0))
    f:EnableMouse(true)
    local icon = self:AcquireTexture(f, "ARTWORK")
    icon:SetSize(size,size)
    icon:SetPoint("TOPLEFT",0,0)
    icon:SetTexture(self:GetSpellIconSafe(spellID))
    if label then
        local fs = self:AcquireText(f, "GameFontNormalSmall")
        fs:SetPoint("TOP", icon, "BOTTOM", 0, -1)
        fs:SetWidth(size+24)
        fs:SetJustifyH("CENTER")
        fs:SetText(label)
    end
    f:SetScript("OnEnter", function()
        GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
        if spellID then pcall(GameTooltip.SetSpellByID, GameTooltip, spellID) end
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return f
end

function MCA:StatusForScore(score)
    if score >= 90 then return "Ottimo", self:UIColor("green") end
    if score >= 75 then return "Buono", self:UIColor("accent") end
    if score >= 55 then return "Discreto", self:UIColor("orange") end
    return "Critico", self:UIColor("red")
end

function MCA:RoleShort(role)
    return self.RoleLabel[role or "DAMAGER"] or role or "DPS"
end

function MCA:BuildPlayerList(data)
    local list = {}
    for _, p in pairs(data.players or {}) do
        table.insert(list,p)
    end
    table.sort(list, function(a,b)
        local sa, sb = MCA:GetDisplayRating(a), MCA:GetDisplayRating(b)
        if sa == sb then return (a.name or "") < (b.name or "") end
        return sa > sb
    end)
    return list
end

function MCA:GetPlayerDefensivesInWindow(player, startTime, endTime)
    local result = {}
    for _, u in ipairs(player.used or {}) do
        if (u.time or 0) >= (startTime or 0) and (u.time or 0) <= (endTime or 0) then
            table.insert(result,u)
        end
    end
    return result
end

function MCA:GetWindows(data)
    local windows = {}
    if data.type == "M+" then
        for _, boss in ipairs(data.bosses or {}) do table.insert(windows,boss) end
    else
        table.insert(windows,{name=data.boss or "Encounter", startTime=0, endTime=data.duration or 0, success=data.result, duration=data.duration or 0})
    end
    return windows
end

function MCA:CountDeathsInWindow(data, startTime, endTime)
    local count = 0
    for _, p in pairs(data.players or {}) do
        if p.deathTime and p.deathTime >= (startTime or 0) and p.deathTime <= (endTime or 0) then
            count = count + (p.deaths or 1)
        end
    end
    return count
end

function MCA:CountCDsInWindow(data, startTime, endTime)
    local count = 0
    for _, p in pairs(data.players or {}) do
        for _, u in ipairs(p.used or {}) do
            if (u.time or 0) >= (startTime or 0) and (u.time or 0) <= (endTime or 0) then
                count = count + 1
            end
        end
    end
    return count
end

function MCA:MainFrame()
    -- Built once and kept. It used to be destroyed and rebuilt on every tab
    -- click, which both leaked the old frame and threw away the position the
    -- player had dragged it to.
    if _G.MCAFrame then
        _G.MCAFrame:Show()
        return _G.MCAFrame
    end

    local f = CreateFrame("Frame", "MCAFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_W, FRAME_H)

    if UISpecialFrames then
        local found = false
        for _, frameName in ipairs(UISpecialFrames) do
            if frameName == "MCAFrame" then found = true break end
        end
        if not found then table.insert(UISpecialFrames, "MCAFrame") end
    end

    -- ESC closing is handled entirely by the UISpecialFrames registration
    -- above. The frame used to grab the keyboard and re-implement that with
    -- SetPropagateKeyboardInput, which is protected in combat: pressing any
    -- key with the report open during a pull raised "action blocked". Letting
    -- Blizzard do it also stops the window swallowing keybinds while open.
    f:SetScript("OnHide", function()
        if MCA.MinimapMenu and MCA.MinimapMenu:IsShown() then MCA.MinimapMenu:Hide() end
    end)
    local pos = RaidPulseDB and RaidPulseDB.framePos
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("CENTER")
    end
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, yOff = frame:GetPoint()
        if point then
            RaidPulseDB.framePos = {point = point, relPoint = relPoint, x = x, y = yOff}
        end
    end)
    self:SetBackdropSolid(f, self:UIColor("bg"), {0.28,0.28,0.30,1})

    self:Text(f, "RaidPulse v"..(self.VERSION or "?"), "GameFontHighlightLarge", {"TOP", f, "TOP", 0, -10}, 460, self:UIColor("accent"), "CENTER")

    return f
end


function MCA:SmallTexture(parent, texture, point, size, vertexColor)
    local t = self:AcquireTexture(parent, "ARTWORK")
    t:SetPoint(unpack(point))
    t:SetSize(size or 16, size or 16)
    t:SetTexture(texture)
    if vertexColor then
        t:SetVertexColor(vertexColor[1], vertexColor[2], vertexColor[3], vertexColor[4] or 1)
    end
    return t
end

function MCA:StatusTexture(parent, point, status)
    local color = self:UIColor("green")
    local texture = "Interface\\Buttons\\UI-CheckBox-Check"

    if status == "Critico" or status == "Crit" then
        texture = "Interface\\RaidFrame\\ReadyCheck-NotReady"
        color = self:UIColor("red")
    elseif status == "Discreto" or status == "Watch" then
        texture = "Interface\\COMMON\\Indicator-Yellow"
        color = self:UIColor("orange")
    elseif status == "Buono" or status == "Good" or status == "Ottimo" or status == "OK" then
        texture = "Interface\\Buttons\\UI-CheckBox-Check"
        color = self:UIColor("green")
    end

    return self:SmallTexture(parent, texture, point, 14, color)
end

function MCA:SuccessTexture(parent, point, success)
    if success then
        return self:SmallTexture(parent, "Interface\\Buttons\\UI-CheckBox-Check", point, 14, self:UIColor("green"))
    end
    return self:SmallTexture(parent, "Interface\\RaidFrame\\ReadyCheck-NotReady", point, 14, self:UIColor("red"))
end

function MCA:DrawSidebar(root)
    local side = self:Panel(root, {"TOPLEFT", root, "TOPLEFT", SIDE_X, SIDE_Y}, SIDE_W, SIDE_H, {0.012,0.017,0.022,0.96})

    -- Emblem placeholder
    local emblem = self:AcquireTexture(side, "ARTWORK")
    emblem:SetPoint("TOPLEFT", 17, -17)
    emblem:SetSize(48,48)
    emblem:SetTexture("Interface\\AddOns\\RaidPulse\\Textures\\icon")

    self:Text(side, "RP", "GameFontHighlightLarge", {"TOPLEFT", side, "TOPLEFT", 72, -22}, 55, self:UIColor("accent"))
    self:Text(side, "v"..(self.VERSION or "?"), "GameFontNormalSmall", {"TOPLEFT", side, "TOPLEFT", 74, -47}, 55, self:UIColor("gray"))

    local tabs = {
        {"Riepilogo","summary"},
        {"Player","players"},
        {"Deaths","deaths"},
        {"Timeline","timeline"},
        {"Confronto","compare"},
        {"Storico","history"},
        {"Impostazioni","settings"}
    }

    local y = -92
    for _, tab in ipairs(tabs) do
        local active = self.activeTab == tab[2] or (tab[2] == "players" and self.activeTab == "playerDetail")
        local b = self:AcquireFrame("Button", side, "BackdropTemplate")
        b:SetPoint("TOPLEFT", 8, y)
        b:SetSize(122, 34)
        self:SetBackdropSolid(b, active and {0.18,0.15,0.02,0.82} or {0.035,0.038,0.04,0.75}, active and {1,0.82,0,1} or {0.16,0.17,0.18,1})

        local icons = {
            summary = "Interface\\Icons\\INV_Misc_Note_01",
            players = "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend",
            deaths = "Interface\\Icons\\Ability_Creature_Cursed_02",
            buffs = "Interface\\Icons\\Spell_Holy_GreaterBlessingofKings",
            interrupts = "Interface\\Icons\\Ability_Kick",
            timeline = "Interface\\Icons\\INV_Misc_PocketWatch_01",
            compare = "Interface\\Icons\\INV_Misc_Spyglass_02",
            history = "Interface\\Icons\\INV_Misc_Book_09",
            settings = "Interface\\Icons\\INV_Misc_Gear_01"
        }

        self:SmallTexture(b, icons[tab[2]] or "Interface\\Icons\\INV_Misc_QuestionMark", {"LEFT", b, "LEFT", 9, 0}, 14)
        self:Text(b, tab[1], "GameFontNormal", {"LEFT", b, "LEFT", 30, 0}, 92, active and self:UIColor("accent") or self:UIColor("white"))
        b:SetScript("OnClick", function()
            MCA.activeTab = tab[2]
            -- Must not be MCA.lastReport: BuildDashboard bails on nil, so with
            -- no report cached the whole sidebar silently stopped responding.
            MCA:BuildDashboard(MCA:GetLastAvailableReport())
        end)
        y = y - 40
    end

end




function MCA:GetEmptyReport()
    return {
        -- Flagged so BuildDashboard does not adopt it as lastReport: doing so
        -- made the placeholder stick, and every later rebuild showed an empty
        -- dashboard even with history still saved.
        isEmpty = true,
        boss = "Nessun report",
        type = "raid",
        mode = "Raid",
        difficulty = "-",
        result = false,
        duration = 0,
        players = {},
        bosses = {},
        timeline = {},
        deaths = {},
        defensives = {},
        raidBuffs = {}
    }
end

function MCA:GetLastAvailableReport()
    -- A report that has been deleted from the history must not linger on the
    -- dashboard, so the cached one is only used while it is still saved.
    if self.lastReport and not self.lastReport.isEmpty then
        if not self.lastReport.historyID then return self.lastReport end
        for _, r in ipairs((RaidPulseDB and RaidPulseDB.history) or {}) do
            if r.historyID == self.lastReport.historyID then return self.lastReport end
        end
        self.lastReport = nil
    end

    if RaidPulseDB and RaidPulseDB.history and #RaidPulseDB.history > 0 then
        return RaidPulseDB.history[#RaidPulseDB.history]
    end

    return self:GetEmptyReport()
end

function MCA:GetModeDifficultyText(data)
    local mode = "Raid"
    local difficulty = "-"

    if data then
        if data.type == "M+" then
            mode = "Mythic+"
        elseif data.mode and data.mode ~= "" then
            mode = data.mode
        elseif data.type == "raid" then
            mode = "Raid"
        end

        if data.difficulty and data.difficulty ~= "" then
            difficulty = data.difficulty
        end
    end

    if mode == "Mythic+" then
        if difficulty ~= "-" and difficulty ~= "Mythic+" then
            return "Mythic+ " .. difficulty
        end
        return "Mythic+"
    end

    if difficulty == "-" or difficulty == "" or difficulty == "Raid" then
        return mode
    end

    return mode .. " " .. difficulty
end

function MCA:DrawTopDashboard(root, data)
    -- kpis and mode are sized by their contents; info takes whatever is left,
    -- so the three always span CONTENT_W with two equal gaps.
    local kpiW, modeW = 600, 180
    local infoW = CONTENT_W - kpiW - modeW - GAP * 2

    local info = self:Panel(root, {"TOPLEFT", root, "TOPLEFT", CONTENT_X, DASH_Y}, infoW, DASH_H, {0.018,0.021,0.024,0.50})
    self:Text(info, data.boss or "Report", "GameFontHighlightLarge", {"TOPLEFT", info, "TOPLEFT", 16, -9}, 150, self:UIColor("purple"))
    self:Text(info, (data.result and "Completato" or "Wipe")..": "..(data.savedAt or date("%d/%m/%Y %H:%M")), "GameFontNormal", {"TOPLEFT", info, "TOPLEFT", 16, -36}, 220, self:UIColor("green"))

    local totals = self:GetTotals(data)
    local kpis = self:Panel(root, {"TOPLEFT", root, "TOPLEFT", CONTENT_X + infoW + GAP, DASH_Y}, kpiW, DASH_H, {0.018,0.021,0.024,0.72})
    local cells = {
        {"Boss", totals.bossKilled.."/"..totals.bosses, self:UIColor("accent")},
        {"Durata", self:FormatTime(data.duration or 0), self:UIColor("accent")},
        {"Deaths", tostring(totals.deaths), self:UIColor("red")},
    }

    -- Raid buffs are a raid concern; a key has no raid-wide buff check to
    -- report, so the cell would always read 0/0. Dropping it also lets the
    -- remaining cells share the strip evenly rather than leaving a dead one.
    if data.type ~= "M+" then
        cells[#cells + 1] = {"Buff Raid",
            tostring(totals.buffActive or 0).."/"..tostring(totals.buffPresent or 0),
            self:UIColor((totals.buffMissing or 0) > 0 and "orange" or "green")}
    end

    cells[#cells + 1] = {"Average DPS",
        self:FormatMetricValue(self:ComputeAverageDPS(data)), self:UIColor("accent")}
    local cellWidth = math.floor(kpiW / #cells)
    local x = 0
    for _, c in ipairs(cells) do
        local cell = self:AcquireFrame("Frame", kpis, "BackdropTemplate")
        cell:SetPoint("TOPLEFT", x, 0)
        cell:SetSize(cellWidth, 64)
        self:SetBackdropSolid(cell, {0,0,0,0}, {0.17,0.18,0.19,1})
        self:Text(cell, c[1], "GameFontNormal", {"TOP", cell, "TOP", 0, -11}, cellWidth - 15, self:UIColor("white"), "CENTER")
        self:Text(cell, c[2], "GameFontHighlightLarge", {"TOP", cell, "TOP", 0, -34}, cellWidth - 15, c[3], "CENTER")
        x = x + cellWidth
    end

    local mode = self:Panel(root, {"TOPLEFT", root, "TOPLEFT", CONTENT_X + CONTENT_W - modeW, DASH_Y}, modeW, DASH_H, {0.018,0.021,0.024,0.72})
    local icon = self:AcquireTexture(mode, "ARTWORK")
    icon:SetPoint("LEFT", 20, 0)
    icon:SetSize(36,36)
    icon:SetTexture("Interface\\Icons\\Achievement_Dungeon_GloryoftheRaider")
    self:Text(mode, "Modalità", "GameFontNormal", {"TOPLEFT", mode, "TOPLEFT", 70, -13}, 110, self:UIColor("white"))
    self:Text(mode, self:GetModeDifficultyText(data), "GameFontHighlight", {"TOPLEFT", mode, "TOPLEFT", 70, -36}, 130, self:GetDifficultyColor(data.difficulty))
end

-- How much of the boss was still standing when the attempt ended: 0% on a
-- kill, otherwise the lowest health the encounter reached.
--
-- Sub-1% wipes keep a decimal on purpose. Rounding a 0.4% wipe to "0%" would
-- read as a kill, and the difference between those two is the whole point of
-- the number.
-- Damage per second for a player regardless of role. GetFightMetric returns
-- healing for healers, which is right in a per-role table but wrong when
-- summing one raid-wide damage figure.
function MCA:GetPlayerDPS(player)
    if not player then return 0 end

    if player.blizzardDps and player.blizzardDps > 0 then return player.blizzardDps end
    if player.blizzard and player.blizzard.dps and player.blizzard.dps.amountPerSecond then
        return player.blizzard.dps.amountPerSecond
    end
    return player.dps or player.fightDPS or player.damagePerSecond or 0
end

-- Total raid damage per second. Replaces the boss-health percentage, which
-- 12.0.7 does not expose to addons at all: UnitHealth, UnitHealthMax and
-- UnitPercentHealthFromGUID are all protected for boss units, and BigWigs
-- gives up on the same wall. Unlike the old average score, this separates one
-- attempt from another — a pull that died early and one that pushed look
-- nothing alike.
-- Mean damage per player. Unlike the raw total it stays comparable between a
-- five-player key and a twenty-five player raid, which is what makes it worth
-- a slot in a strip that both modes share.
function MCA:ComputeAverageDPS(data)
    local total, count = 0, 0
    for _, p in pairs((data and data.players) or {}) do
        total = total + (tonumber(self:GetPlayerDPS(p)) or 0)
        count = count + 1
    end
    if count == 0 then return 0 end
    return total / count
end

function MCA:ComputeRaidDPS(data)
    local total = 0
    for _, p in pairs((data and data.players) or {}) do
        total = total + (tonumber(self:GetPlayerDPS(p)) or 0)
    end
    return total
end

function MCA:ComputeRaidScore(data)
    local total, count = 0, 0
    for _, p in pairs(data.players or {}) do
        total = total + self:GetScore(p)
        count = count + 1
    end
    if count == 0 then return 100 end
    return math.floor(total / count)
end

function MCA:TableHeader(parent, cols, y)
    local row = self:AcquireFrame("Frame", parent, "BackdropTemplate")
    row:SetPoint("TOPLEFT", 0, y)
    row:SetSize(parent:GetWidth(), 26)
    self:SetBackdropSolid(row, {0.025,0.027,0.030,0.95}, {0.16,0.17,0.18,1})
    for _, c in ipairs(cols) do
        self:Text(row, c.label, "GameFontHighlightSmall", {"LEFT", row, "LEFT", c.x, 0}, c.w, self:UIColor("white"), c.justify or "LEFT")
    end
    return y - 28
end




function MCA:DrawPlayerTable(parent, data, singlePlayer, y)
    -- Columns are spread across the full page width. They used to be packed
    -- into the left 540px with the last one stretching to the edge, which left
    -- "Parse" floating alone in the middle of a 500px column.
    local cols = {
        num    = {x=10,  w=30,  justify="CENTER"},
        player = {x=50,  w=260},
        class  = {x=320, w=200},
        role   = {x=530, w=100, justify="CENTER"},
        deaths = {x=640, w=90,  justify="CENTER"},
        metric = {x=740, w=140, justify="CENTER"},
        parse  = {x=890, w=158, justify="CENTER"},
    }

    -- Detail view drops the metric column; Parse takes its slot so the layout
    -- does not shift between the list and the single-player view.
    local headers
    if singlePlayer then
        headers = {
            {label="#",      x=cols.num.x,    w=cols.num.w,    justify="CENTER"},
            {label="Player", x=cols.player.x, w=cols.player.w},
            {label="Classe", x=cols.class.x,  w=cols.class.w},
            {label="Ruolo",  x=cols.role.x,   w=cols.role.w,   justify="CENTER"},
            {label="Morti",  x=cols.deaths.x, w=cols.deaths.w, justify="CENTER"},
            {label="Parse",  x=cols.metric.x, w=cols.metric.w, justify="CENTER"},
        }
    else
        headers = {
            {label="#",       x=cols.num.x,    w=cols.num.w,    justify="CENTER"},
            {label="Player",  x=cols.player.x, w=cols.player.w},
            {label="Classe",  x=cols.class.x,  w=cols.class.w},
            {label="Ruolo",   x=cols.role.x,   w=cols.role.w,   justify="CENTER"},
            {label="Morti",   x=cols.deaths.x, w=cols.deaths.w, justify="CENTER"},
            {label="DPS/HPS", x=cols.metric.x, w=cols.metric.w, justify="CENTER"},
            {label="Parse",   x=cols.parse.x,  w=cols.parse.w,  justify="CENTER"},
        }
    end

    local list
    if singlePlayer then
        list = {}
        if self.selectedPlayer then table.insert(list, self.selectedPlayer) end
    else
        list = self:BuildPlayerList(data)
        -- Populate mcaRating with the same values the Riepilogo role tables use.
        if self.CalculateRoleRatings then self:CalculateRoleRatings(list) end
    end

    local rows = {}
    for i, p in ipairs(list) do
        local _, parseColor, parseText = self:ResolvePlayerParse(p, data)
        local nameColor = i % 3 == 0 and self:UIColor("blue")
            or (i % 3 == 1 and self:UIColor("accent") or self:UIColor("orange"))

        local row = {
            {x=cols.num.x,    w=cols.num.w,    text=tostring(i)..".", justify="CENTER"},
            {x=cols.player.x, w=cols.player.w, text=p.name or "?", classIcon=p.class,
             font="GameFontNormal", color=nameColor},
            {x=cols.class.x,  w=cols.class.w,  text=self:PrettyClass(p.class), classIcon=p.class},
            {x=cols.role.x,   w=cols.role.w,   text=self:RoleShort(p.role), justify="CENTER"},
            {x=cols.deaths.x, w=cols.deaths.w, text=tostring(p.deaths or 0), justify="CENTER",
             color=(p.deaths or 0) > 0 and self:UIColor("red") or self:UIColor("white")},
        }

        if singlePlayer then
            row[#row + 1] = {x=cols.metric.x, w=cols.metric.w, text=parseText,
                             color=parseColor, justify="CENTER", font="GameFontNormal"}
        else
            row[#row + 1] = {x=cols.metric.x, w=cols.metric.w,
                             text=self:FormatMetricValue(self:GetFightMetric(p)), justify="CENTER"}
            row[#row + 1] = {x=cols.parse.x, w=cols.parse.w, text=parseText,
                             color=parseColor, justify="CENTER", font="GameFontNormal"}
            row.onClick = function()
                MCA.selectedPlayer = p
                MCA.activeTab = "playerDetail"
                MCA:BuildDashboard(data)
            end
        end

        rows[#rows + 1] = row
    end

    return self:DrawPageTable(parent, headers, rows, y)
end

function MCA:PrettyClass(class)
    local map = {DEATHKNIGHT="Death Knight", DEMONHUNTER="Demon Hunter"}
    if map[class or ""] then return map[class] end
    local s = string.lower(class or "?")
    return s:gsub("^%l", string.upper)
end




function MCA:DrawBossBreakdown(parent, data)
    -- Built as rows for DrawSmallPanel, the same as the Deaths and Timeline
    -- cards beside it. It used to draw its own header and rows straight onto
    -- the panel, which is why it alone spanned the full card width, used 30px
    -- rows against the others' 28, and started 8px higher.
    local bosses = self:GetWindows(data)

    -- Must match what DrawSmallPanel will accept: it drops any column ending
    -- past innerW - 4, and innerW is the panel width less 16 for the scroll
    -- and 10 for its child. Sizing to the panel width alone silently lost the
    -- last column.
    local tableW = math.max((parent:GetWidth() or 380) - 30, 296)
    local wNum, wPull, wKill, wDurata, wMorti = 24, 38, 38, 52, 42
    local gap = 6

    local xNum, xBoss = 8, 40
    local xMorti = tableW - wMorti
    local xDurata = xMorti - gap - wDurata
    local xKill = xDurata - gap - wKill
    local xPull = xKill - gap - wPull
    local wBoss = math.max(xPull - xBoss - gap, 100)

    local headers = {
        {label="#",      x=xNum,    w=wNum,    justify="CENTER"},
        {label="Boss",   x=xBoss,   w=wBoss},
        {label="Pull",   x=xPull,   w=wPull,   justify="CENTER"},
        {label="Kill",   x=xKill,   w=wKill,   justify="CENTER"},
        {label="Durata", x=xDurata, w=wDurata, justify="CENTER"},
        {label="Morti",  x=xMorti,  w=wMorti,  justify="CENTER"},
    }

    local rows = {}
    for i, b in ipairs(bosses) do
        local deaths = self:CountDeathsInWindow(data, b.startTime or 0, b.endTime or data.duration or 0)
        rows[#rows + 1] = {
            {x=xNum,    w=wNum,    text=tostring(i), justify="CENTER"},
            {x=xBoss,   w=wBoss,   text=b.name or "Boss", color=self:UIColor("accent")},
            {x=xPull,   w=wPull,   text="1", justify="CENTER"},
            {x=xKill,   w=wKill,   success=b.success and true or false},
            {x=xDurata, w=wDurata, justify="CENTER",
             text=self:FormatTime(b.duration or ((b.endTime or 0) - (b.startTime or 0)))},
            {x=xMorti,  w=wMorti,  text=tostring(deaths), justify="CENTER",
             color=deaths > 0 and self:UIColor("red") or self:UIColor("white")},
            onClick = function()
                MCA.selectedBoss = b
                MCA:BuildDashboard(data)
            end,
        }
    end

    self:DrawSmallPanel(parent, "Boss Breakdown", nil, "accent", headers, rows)
end

function MCA:DrawBossDetail(parent, data)
    local boss = self.selectedBoss or (self:GetWindows(data)[1])
    self:Text(parent, "Dettaglio: "..(boss and boss.name or "Encounter"), "GameFontHighlightLarge",
        {"CENTER", parent, "TOP", 0, -19}, parent:GetWidth()-28, self:UIColor("accent"), "CENTER")

    local _, child, scroll = self:Scroll(parent, {"TOPLEFT", parent, "TOPLEFT", 8, -38}, parent:GetWidth()-16, parent:GetHeight()-44, {0.018,0.020,0.022,0.55}, true)

    local cols = {
        {label="Player", x=10, w=122},
        {label="Ruolo", x=146, w=50, justify="CENTER"},
        {label="Morti", x=208, w=40, justify="CENTER"},
        {label="CD", x=262, w=35, justify="CENTER"},
        {label="Debuff", x=312, w=48, justify="CENTER"},
        {label="Score", x=380, w=50, justify="CENTER"}
    }

    local y = -2
    y = self:TableHeader(child, cols, y)

    for i, p in ipairs(self:BuildPlayerList(data)) do
        local row = self:AcquireFrame("Button", child, "BackdropTemplate")
        row:SetPoint("TOPLEFT", 0, y)
        row:SetSize(442, 24)
        self:SetBackdropSolid(row, i % 2 == 0 and self:UIColor("rowAlt") or self:UIColor("row"), {0.12,0.13,0.14,1})

        self:ClassIcon(row, p.class, 10, -3, 18)
        self:Text(row, p.name or "?", "GameFontNormal", {"LEFT", row, "LEFT", 36, 0}, 96, i % 2 == 0 and self:UIColor("orange") or self:UIColor("blue"))
        self:Text(row, self:RoleShort(p.role), "GameFontNormal", {"LEFT", row, "LEFT", 146, 0}, 50, self:UIColor("white"), "CENTER")

        local deaths = (p.deathTime and boss and p.deathTime >= (boss.startTime or 0) and p.deathTime <= (boss.endTime or data.duration or 0)) and (p.deaths or 1) or 0
        local cds = boss and #self:GetPlayerDefensivesInWindow(p, boss.startTime or 0, boss.endTime or data.duration or 0) or #(p.used or {})

        self:Text(row, tostring(deaths), "GameFontNormal", {"LEFT", row, "LEFT", 208, 0}, 40, deaths > 0 and self:UIColor("red") or self:UIColor("white"), "CENTER")
        self:Text(row, tostring(cds), "GameFontNormal", {"LEFT", row, "LEFT", 262, 0}, 35, self:UIColor("white"), "CENTER")
        self:Text(row, tostring(#(p.debuffs or {})), "GameFontNormal", {"LEFT", row, "LEFT", 312, 0}, 48, self:UIColor("white"), "CENTER")

        local score = self:GetDisplayRating(p)
        local _, c = self:StatusForScore(score)
        self:Text(row, score.."%", "GameFontNormal", {"LEFT", row, "LEFT", 380, 0}, 50, c, "CENTER")

        row:SetScript("OnClick", function()
            MCA.selectedPlayer = p
            MCA.activeTab = "summary"
            MCA:BuildDashboard(data)
        end)

        y = y - 24
    end

    self:UpdateScrollBar(child, scroll, math.abs(y)+20)
end


function MCA:NormalizeColumns(parent, headers)
    local innerW = self:GetInnerWidth(parent, 260)
    local filtered = {}

    for _, h in ipairs(headers or {}) do
        local endX = (h.x or 0) + (h.w or 0)
        if endX <= innerW - 4 then
            table.insert(filtered, h)
        end
    end

    return filtered
end

function MCA:DrawSmallPanel(parent, title, iconSpell, colorName, headers, rows)
    local color = self:UIColor(colorName or "accent")
    -- Centred in the header band, which runs from the panel top down to where
    -- the scroll starts. Anchoring the string's own CENTER to the panel's TOP
    -- centres it on both axes at once, rather than pinning a corner and
    -- guessing at the offsets.
    self:Text(parent, title, "GameFontHighlightLarge",
        {"CENTER", parent, "TOP", 0, -25}, parent:GetWidth()-28, color, "CENTER")

    local scrollW = parent:GetWidth() - 16
    local scrollH = parent:GetHeight() - 62
    local _, child, scroll = self:Scroll(parent, {"TOPLEFT", parent, "TOPLEFT", 8, -50}, scrollW, scrollH, {0.018,0.020,0.022,0.55}, true)

    local innerW = scrollW - 10
    local normalizedHeaders = self:NormalizeColumns(child, headers)
    local y = -2
    y = self:TableHeader(child, normalizedHeaders, y)

    if #rows == 0 then
        self:Text(child, "Nessun dato registrato.", "GameFontNormal", {"TOPLEFT", child, "TOPLEFT", 12, y-6}, innerW-24, self:UIColor("gray"))
    end

    for i, rowData in ipairs(rows) do
        local row = self:AcquireFrame(rowData.onClick and "Button" or "Frame", child, "BackdropTemplate")
        row:SetPoint("TOPLEFT", 0, y)
        row:SetSize(innerW, 28)
        self:SetBackdropSolid(row, i % 2 == 0 and self:UIColor("rowAlt") or self:UIColor("row"), {0.12,0.13,0.14,1})
        if rowData.onClick then row:SetScript("OnClick", rowData.onClick) end

        for _, cell in ipairs(rowData) do
            local x = cell.x or 0
            local w = cell.w or 40
            if x + w <= innerW - 4 then
                if cell.success ~= nil then
                    self:SuccessTexture(row, {"LEFT", row, "LEFT", x + math.floor(w / 2) - 6, 0}, cell.success)
                else
                    if cell.spellID then self:SpellIcon(row, cell.spellID, x, -5, 18) end
                    local textX = x + (cell.spellID and 25 or 0)
                    local textW = w - (cell.spellID and 25 or 0)
                    self:Text(row, cell.text or "", "GameFontNormalSmall", {"LEFT", row, "LEFT", textX, 0}, textW, cell.color or self:UIColor("white"), cell.justify or "LEFT")
                end
            end
        end

        y = y - 28
    end

    self:UpdateScrollBar(child, scroll, math.abs(y)+20)
end

-- What killed a player, when we know it. Only the local player's own death
-- recap is available, so it is filled in for their rows and not for others —
-- this column used to be a hardcoded "-" on every single row.
function MCA:DeathCauseText(player)
    if not player then return "-" end

    local spell = player.deathSpellName
    if type(spell) ~= "string" or spell == "" or spell == "?" then return "-" end
    return spell
end

function MCA:BuildDeathsRows(data, cols)
    -- cols: optional {time, player, boss, extra} column defs {x,w}. When omitted,
    -- falls back to the compact summary-card layout. This keeps the death rows
    -- aligned with whatever header the caller draws (summary card vs full tab).
    cols = cols or {
        time   = {x=10,  w=55},
        player = {x=76,  w=110},
        boss   = {x=198, w=110},
        extra  = {x=320, w=38}
    }
    local rows = {}
    for _, p in pairs(data.players or {}) do
        if (p.deaths or 0) > 0 then
            table.insert(rows, {
                {x=cols.time.x,   w=cols.time.w,   text=self:FormatTime(p.deathTime or 0), color=self:UIColor("white")},
                {x=cols.player.x, w=cols.player.w, text=p.name or "?", color=self:UIColor("accent")},
                {x=cols.boss.x,   w=cols.boss.w,   text=self:BossNameAtTime(data, p.deathTime or 0), color=self:UIColor("white")},
                {x=cols.extra.x,  w=cols.extra.w,  text=self:DeathCauseText(p), color=self:UIColor("gray")}
            })
        end
    end
    return rows
end

function MCA:BossNameAtTime(data, t)
    for _, b in ipairs(data.bosses or {}) do
        if t >= (b.startTime or 0) and t <= (b.endTime or 0) then return b.name or "Boss" end
    end
    return data.boss or "Encounter"
end

function MCA:BuildDebuffRows(data)
    local rows = {}
    for _, p in pairs(data.players or {}) do
        for _, d in ipairs(p.debuffs or {}) do
            table.insert(rows, {
                {x=10, w=35, text="", spellID=d.spellID},
                {x=55, w=105, text=d.name or self:GetSpellNameSafe(d.spellID), color=self:UIColor("white")},
                {x=175, w=85, text=p.name or "?", color=self:UIColor("red")},
                {x=270, w=45, text="1", color=self:UIColor("white"), justify="CENTER"},
                {x=330, w=55, text="--", color=self:UIColor("white"), justify="CENTER"}
            })
        end
    end
    return rows
end

function MCA:BuildTimelineRows(data, cols)
    cols = cols or {
        time   = {x=10, w=55},
        event  = {x=76, w=210},
        player = {x=300, w=90}
    }
    local events = {}
    for _, e in ipairs(data.timeline or {}) do table.insert(events, e) end
    table.sort(events, function(a,b) return (a.time or 0) < (b.time or 0) end)
    local rows = {}
    for _, e in ipairs(events) do
        table.insert(rows, {
            {x=cols.time.x,   w=cols.time.w,   text=self:FormatTime(e.time or 0), color=self:UIColor("white")},
            {x=cols.event.x,  w=cols.event.w,  text=e.text or "Evento", spellID=e.spellID, color=e.type == "death" and self:UIColor("red") or self:UIColor("white")},
            {x=cols.player.x, w=cols.player.w, text=e.player or "", color=self:UIColor("blue")}
        })
    end
    return rows
end

function MCA:BuildDefensiveRows(data)
    local player = self.selectedPlayer or self:BuildPlayerList(data)[1]
    local rows = {}
    if player then
        for _, u in ipairs(player.used or {}) do
            table.insert(rows, {
                {x=10, w=35, text="", spellID=u.spellID},
                {x=55, w=120, text=u.name or self:GetSpellNameSafe(u.spellID), color=self:UIColor("white")},
                {x=185, w=80, text=self:BossNameAtTime(data, u.time or 0), color=self:UIColor("white")},
                {x=275, w=55, text=self:FormatTime(u.time or 0), color=self:UIColor("white"), justify="CENTER"},
                {x=340, w=70, text="Difensiva", color=self:UIColor("white")}
            })
        end
    end
    return rows
end




function MCA:DrawRaidBuffMatrix(parent, data)
    self:Text(parent, "Buff Raid", "GameFontHighlightLarge",
        {"CENTER", parent, "TOP", 0, -24}, parent:GetWidth()-28, self:UIColor("purple"), "CENTER")

    local matrix = data and data.raidBuffMatrix
    if not matrix then
        matrix = { buffs = data and data.raidBuffs or {}, players = {} }
    end

    local buffs = {}
    for _, buff in ipairs(matrix.buffs or {}) do
        if buff.classPresent then
            table.insert(buffs, buff)
        end
    end

    local _, child, scroll = self:Scroll(parent, {"TOPLEFT", parent, "TOPLEFT", 8, -48}, parent:GetWidth()-16, parent:GetHeight()-58, {0.018,0.020,0.022,0.55}, true)

    local playerColW = 190
    local roleColW = 70
    local buffColW = 90
    local tableW = playerColW + roleColW + (#buffs * buffColW) + 20

    child:SetWidth(math.max(tableW, parent:GetWidth()-32))

    local header = self:AcquireFrame("Frame", child, "BackdropTemplate")
    header:SetPoint("TOPLEFT", 0, -2)
    header:SetSize(child:GetWidth(), 30)
    self:SetBackdropSolid(header, {0.025,0.027,0.030,0.95}, {0.16,0.17,0.18,1})

    self:Text(header, "Player", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 10, 0}, playerColW-10, self:UIColor("white"))
    self:Text(header, "Ruolo", "GameFontHighlightSmall", {"LEFT", header, "LEFT", playerColW, 0}, roleColW, self:UIColor("white"), "CENTER")

    local x = playerColW + roleColW
    for _, buff in ipairs(buffs) do
        self:SpellIcon(header, buff.spellID, x + 4, -5, 18)
        self:Text(header, buff.short or buff.name or "Buff", "GameFontHighlightSmall", {"LEFT", header, "LEFT", x + 26, 0}, buffColW-28, self:UIColor("white"), "CENTER")
        x = x + buffColW
    end

    local y = -34
    local players = matrix.players or {}

    for i, p in ipairs(players) do
        local row = self:AcquireFrame("Frame", child, "BackdropTemplate")
        row:SetPoint("TOPLEFT", 0, y)
        row:SetSize(child:GetWidth(), 30)
        self:SetBackdropSolid(row, i % 2 == 0 and self:UIColor("rowAlt") or self:UIColor("row"), {0.12,0.13,0.14,1})

        self:ClassIcon(row, p.class, 10, -6, 18)
        self:Text(row, p.name or "?", "GameFontNormal", {"LEFT", row, "LEFT", 36, 0}, playerColW-40, self:UIColor("accent"))
        self:Text(row, self:RoleShort(p.role), "GameFontNormalSmall", {"LEFT", row, "LEFT", playerColW, 0}, roleColW, self:UIColor("white"), "CENTER")

        x = playerColW + roleColW
        for _, buff in ipairs(buffs) do
            local has = p.buffs and p.buffs[buff.key]
            if has == true then
                self:Text(row, "●", "GameFontHighlightLarge", {"LEFT", row, "LEFT", x, 0}, buffColW, self:UIColor("green"), "CENTER")
            elseif has == false then
                self:Text(row, "X", "GameFontHighlightLarge", {"LEFT", row, "LEFT", x, 0}, buffColW, self:UIColor("red"), "CENTER")
            else
                self:Text(row, "–", "GameFontNormalLarge", {"LEFT", row, "LEFT", x, 0}, buffColW, self:UIColor("gray"), "CENTER")
            end
            x = x + buffColW
        end

        y = y - 30
    end

    if #players == 0 then
        self:Text(child, "Nessuno snapshot buff disponibile. Verrà generato al prossimo pull.", "GameFontNormal", {"TOPLEFT", child, "TOPLEFT", 14, -44}, 500, self:UIColor("gray"))
    end

    self:UpdateScrollBar(child, scroll, math.abs(y)+40)
end


-- True when a saved report counts as a kill. Mirrors the truthiness test the
-- row rendering uses, so the filter can never disagree with the "Esito" column
-- a player is looking at.
local function reportIsKill(report)
    return (report and report.result) and true or false
end

function MCA:DrawHistoryPage(parent)
    local history = self.GetHistory and self:GetHistory() or (RaidPulseDB.history or {})

    -- nil = show everything, otherwise keep only kills or only wipes.
    local filter = self.historyFilter
    local kills, wipes = 0, 0
    for _, report in ipairs(history) do
        if reportIsKill(report) then kills = kills + 1 else wipes = wipes + 1 end
    end
    local shown = (filter == "kill" and kills) or (filter == "wipe" and wipes) or #history

    local countText = "Report salvati: " .. tostring(#history)
    if filter then
        countText = countText .. "  (mostrati: " .. tostring(shown) .. ")"
    end
    self:Text(parent, countText, "GameFontNormal", {"TOPLEFT", parent, "TOPLEFT", PAGE_X, -56}, 250, self:UIColor("gray"))

    local function selectFilter(value)
        MCA.historyFilter = value
        MCA.activeTab = "history"
        MCA:BuildDashboard(MCA:GetLastAvailableReport())
    end

    self:Text(parent, "Esito:", "GameFontNormalSmall", {"TOPLEFT", parent, "TOPLEFT", PAGE_X + 268, -56}, 46, self:UIColor("gray"))
    self:FilterButton(parent, "Tutti", {"TOPLEFT", parent, "TOPLEFT", PAGE_X + 318, -50}, 72, 24,
        filter == nil, function() selectFilter(nil) end)
    self:FilterButton(parent, "Kill (" .. kills .. ")", {"TOPLEFT", parent, "TOPLEFT", PAGE_X + 396, -50}, 82, 24,
        filter == "kill", function() selectFilter("kill") end)
    self:FilterButton(parent, "Wipe (" .. wipes .. ")", {"TOPLEFT", parent, "TOPLEFT", PAGE_X + 484, -50}, 82, 24,
        filter == "wipe", function() selectFilter("wipe") end)

    -- The delete button always follows the filter, and spells out how many
    -- reports it is about to remove — there is no undo, so the scope of the
    -- click has to be readable before making it.
    local deleteLabel, deleteCount
    if filter == "kill" then
        deleteLabel, deleteCount = "Cancella Kill (" .. kills .. ")", kills
    elseif filter == "wipe" then
        deleteLabel, deleteCount = "Cancella Wipe (" .. wipes .. ")", wipes
    else
        deleteLabel, deleteCount = "Cancella storico (" .. #history .. ")", #history
    end

    self:Button(parent, deleteLabel, {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_W - 180, -50}, 180, 24, function()
        if deleteCount == 0 then
            MCA:Print("Nessun report da cancellare con questo filtro.")
            return
        end
        if filter then
            MCA:ClearHistoryByResult(filter == "kill")
        else
            MCA:ClearHistory()
        end
        MCA.activeTab = "history"
        MCA:BuildDashboard(MCA:GetLastAvailableReport())
    end, true)

    local header = self:AcquireFrame("Frame", parent, "BackdropTemplate")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", PAGE_X, -92)
    header:SetSize(PAGE_W, 28)
    self:SetBackdropSolid(header, {0.025,0.027,0.030,0.95}, {0.16,0.17,0.18,1})

    self:Text(header, "Data", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 10, 0}, 120, self:UIColor("white"))
    self:Text(header, "Tipo", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 145, 0}, 70, self:UIColor("white"))
    self:Text(header, "Encounter / Dungeon", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 230, 0}, 260, self:UIColor("white"))
    self:Text(header, "Modalità", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 510, 0}, 130, self:UIColor("white"))
    self:Text(header, "Durata", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 660, 0}, 70, self:UIColor("white"))
    self:Text(header, "Esito", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 750, 0}, 70, self:UIColor("white"))
    self:Text(header, "Avg DPS", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 840, 0}, 70, self:UIColor("white"))

    local y = -124
    local rowIndex = 0

    for i = #history, 1, -1 do
        local report = history[i]
        local isKill = reportIsKill(report)

        -- Skipping rather than building a filtered copy keeps `i` pointing at
        -- the real history index, which the per-row delete below relies on.
        local visible = (filter == nil)
            or (filter == "kill" and isKill)
            or (filter == "wipe" and not isKill)

        if visible then
        rowIndex = rowIndex + 1

        local row = self:AcquireFrame("Button", parent, "BackdropTemplate")
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", PAGE_X, y)
        row:SetSize(PAGE_W, 30)
        self:SetBackdropSolid(row, rowIndex % 2 == 0 and self:UIColor("rowAlt") or self:UIColor("row"), {0.12,0.13,0.14,1})

        local resultText = isKill and "Kill" or "Wipe"

        self:Text(row, report.savedAt or "?", "GameFontNormalSmall", {"LEFT", row, "LEFT", 10, 0}, 120, self:UIColor("gray"))
        self:Text(row, report.type or "?", "GameFontNormalSmall", {"LEFT", row, "LEFT", 145, 0}, 70, self:UIColor("accent"))
        self:Text(row, report.boss or "?", "GameFontNormal", {"LEFT", row, "LEFT", 230, 0}, 260, self:UIColor("white"))
        self:Text(row, self:GetModeDifficultyText(report), "GameFontNormalSmall", {"LEFT", row, "LEFT", 510, 0}, 130, self:GetDifficultyColor(report.difficulty))
        self:Text(row, self:FormatTime(report.duration or 0), "GameFontNormalSmall", {"LEFT", row, "LEFT", 660, 0}, 70, self:UIColor("white"))
        self:Text(row, resultText, "GameFontNormalSmall", {"LEFT", row, "LEFT", 750, 0}, 70, isKill and self:UIColor("green") or self:UIColor("red"))
        self:Text(row, self:FormatMetricValue(self:ComputeAverageDPS(report)), "GameFontNormalSmall", {"LEFT", row, "LEFT", 840, 0}, 70, self:UIColor("accent"))

        self:Button(row, "Apri", {"RIGHT", row, "RIGHT", -84, 0}, 64, 22, function()
            MCA.activeTab = "summary"
            MCA.lastReport = report
            MCA:BuildDashboard(report)
        end)

        self:Button(row, "X", {"RIGHT", row, "RIGHT", -12, 0}, 28, 22, function()
            table.remove(RaidPulseDB.history, i)
            MCA.activeTab = "history"
            MCA:BuildDashboard(MCA:GetLastAvailableReport())
        end, true)

        row:SetScript("OnClick", function()
            MCA.activeTab = "summary"
            MCA.lastReport = report
            MCA:BuildDashboard(report)
        end)

        y = y - 32
        end
    end

    if #history == 0 then
        self:Text(parent, "Nessun report salvato. I prossimi report completati appariranno qui.", "GameFontNormal", {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, -130}, 620, self:UIColor("gray"))
    elseif shown == 0 then
        self:Text(parent, "Nessun report con esito " .. (filter == "kill" and "Kill" or "Wipe") .. ".", "GameFontNormal", {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, -130}, 620, self:UIColor("gray"))
    end

    return math.abs(y) + 80
end

-- Draw a table straight onto the page, the way the history tab does: no
-- wrapping panel, no inner scroll nested inside the page's own, and no second
-- copy of the title the page header already shows.
--
-- Row geometry matches the history exactly (28px header, 30px rows on a 32px
-- pitch) so the tabs are indistinguishable apart from their columns. Returns
-- the y below the last row, so the caller keeps growing the page scroll.
function MCA:DrawPageTable(parent, headers, rows, y)
    local header = self:AcquireFrame("Frame", parent, "BackdropTemplate")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", PAGE_X, y)
    header:SetSize(PAGE_W, 28)
    self:SetBackdropSolid(header, {0.025,0.027,0.030,0.95}, {0.16,0.17,0.18,1})

    for _, c in ipairs(headers or {}) do
        self:Text(header, c.label, "GameFontHighlightSmall",
            {"LEFT", header, "LEFT", c.x, 0}, c.w, self:UIColor("white"), c.justify)
    end

    y = y - 32

    if #(rows or {}) == 0 then
        self:Text(parent, "Nessun dato registrato.", "GameFontNormal",
            {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 6}, 620, self:UIColor("gray"))
        return y - 40
    end

    for i, rowData in ipairs(rows) do
        -- A row is a plain frame unless it carries an onClick, in which case it
        -- has to be a Button to receive one.
        local row = self:AcquireFrame(rowData.onClick and "Button" or "Frame", parent, "BackdropTemplate")
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", PAGE_X, y)
        row:SetSize(PAGE_W, 30)
        self:SetBackdropSolid(row, i % 2 == 0 and self:UIColor("rowAlt") or self:UIColor("row"), {0.12,0.13,0.14,1})
        if rowData.onClick then row:SetScript("OnClick", rowData.onClick) end

        for _, cell in ipairs(rowData) do
            local iconW = 0
            if cell.spellID then
                self:SpellIcon(row, cell.spellID, cell.x, -6, 18)
                iconW = 25
            elseif cell.classIcon then
                self:ClassIcon(row, cell.classIcon, cell.x, -6, 18)
                iconW = 24
            end

            self:Text(row, cell.text or "", cell.font or "GameFontNormalSmall",
                {"LEFT", row, "LEFT", cell.x + iconW, 0}, (cell.w or 80) - iconW,
                cell.color or self:UIColor("white"), cell.justify or "LEFT")
        end

        y = y - 32
    end

    return y
end

-- ---------------------------------------------------------------------------
-- Attempt comparison.
--
-- After a run of wipes on one boss the useful question is not what a single
-- pull looked like, but who moved between them: who improved, who fell off,
-- who dies in the same place every time. The history already holds every
-- attempt in full; this only lines them up side by side.
-- ---------------------------------------------------------------------------
local COMPARE_ATTEMPTS = 6      -- as many columns as the page width fits

-- savedAt is "dd/mm/yyyy HH:MM" and the columns only have room for the clock,
-- which is what tells attempts apart within one night anyway.
local function attemptLabel(report)
    local t = tostring(report and report.savedAt or "")
    return t:match("(%d%d:%d%d)%s*$") or t
end

-- The most recent attempts on the same boss, newest first.
function MCA:GetComparisonAttempts(data)
    local boss = data and data.boss
    if not boss or boss == "" then return {} end

    local history = self.GetHistory and self:GetHistory() or (RaidPulseDB.history or {})
    local out = {}
    for i = #history, 1, -1 do
        local r = history[i]
        if r and r.boss == boss then
            out[#out + 1] = r
            if #out >= COMPARE_ATTEMPTS then break end
        end
    end
    return out
end

function MCA:DrawComparePage(parent, data, y)
    local attempts = self:GetComparisonAttempts(data)

    if #attempts < 2 then
        self:Text(parent, "Serve piu' di un tentativo sullo stesso boss per un confronto.",
            "GameFontNormal", {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 6},
            700, self:UIColor("gray"))
        return y - 40
    end

    local nameCol = {x = 10, w = 210}
    local colW, firstX = 140, 230

    local headers = {{label = "Player", x = nameCol.x, w = nameCol.w}}
    for i, r in ipairs(attempts) do
        headers[#headers + 1] = {
            label = attemptLabel(r) .. (r.result and "" or " ✖"),
            x = firstX + (i - 1) * colW, w = colW - 10, justify = "CENTER",
        }
    end

    -- One row per player seen in any attempt, ordered by how they did in the
    -- most recent one so the table reads top-down like the summary does.
    local seen, names = {}, {}
    for _, r in ipairs(attempts) do
        for _, p in pairs(r.players or {}) do
            if p.name and not seen[p.name] then
                seen[p.name] = true
                names[#names + 1] = p.name
            end
        end
    end

    local latest = attempts[1].players or {}
    table.sort(names, function(a, b)
        local pa, pb = latest[a], latest[b]
        return (pa and self:GetPlayerDPS(pa) or 0) > (pb and self:GetPlayerDPS(pb) or 0)
    end)

    local rows = {}
    for _, name in ipairs(names) do
        local row = {{x = nameCol.x, w = nameCol.w, text = name, font = "GameFontNormal"}}

        for i, r in ipairs(attempts) do
            local p = (r.players or {})[name]
            local dps = p and self:GetPlayerDPS(p) or 0

            local text, color = "-", self:UIColor("gray")
            if p and dps > 0 then
                -- attempts run newest-first, so the next index is the older one
                local prev = attempts[i + 1] and (attempts[i + 1].players or {})[name]
                local prevDps = prev and self:GetPlayerDPS(prev) or 0

                color = self:UIColor("white")
                if prevDps > 0 then
                    -- 5% either way, so ordinary variance is not painted as a trend
                    if dps > prevDps * 1.05 then color = self:UIColor("green")
                    elseif dps < prevDps * 0.95 then color = self:UIColor("red") end
                end

                text = self:FormatMetricValue(dps)
                if (p.deaths or 0) > 0 then text = text .. " +" .. p.deaths end
            elseif not p then
                text = "assente"
            end

            row[#row + 1] = {x = firstX + (i - 1) * colW, w = colW - 10,
                             text = text, color = color, justify = "CENTER"}
        end

        rows[#rows + 1] = row
    end

    y = self:DrawPageTable(parent, headers, rows, y)
    self:Text(parent, "Verde/rosso = variazione oltre il 5% rispetto al tentativo precedente. "
        .. "\"+N\" = morti in quel tentativo. \"✖\" nell'intestazione = wipe.",
        "GameFontNormalSmall", {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 10},
        900, self:UIColor("gray"))
    return y - 40
end

function MCA:DrawFullPage(root, data)
    local _, child, scroll = self:Scroll(root, {"TOPLEFT", root, "TOPLEFT", CONTENT_X, BODY_Y}, CONTENT_W, BODY_H, {0.018,0.020,0.022,0.65})

    local titleMap = {summary="Riepilogo", players="Player", playerDetail="Player", deaths="Deaths", buffs="Buff Raid", interrupts="Interrupt", timeline="Timeline", history="Storico", compare="Confronto", settings="Impostazioni"}
    local title = titleMap[self.activeTab] or "Riepilogo"

    -- Centred over the content rectangle rather than over the scroll child:
    -- the child is 1140 wide but the content spans PAGE_X..PAGE_X+PAGE_W, so
    -- centring on the child would sit the title 8px off the table below it.
    -- The band is the 50px between the page top and where content starts.
    self:Text(child, title, "GameFontHighlightLarge",
        {"CENTER", child, "TOPLEFT", PAGE_X + PAGE_W / 2, -25}, PAGE_W,
        self:UIColor("accent"), "CENTER")

    local y = -50

    if self.activeTab == "settings" then
        local settings = {
            {"Debug", "debug"},
            {"ElvUI Skin", "useElvUISkin"},
            {"Auto Open", "autoOpen"},
            {"Show Kill", "showAfterKill"},
            {"Show Wipe", "showAfterWipe"},
            {"Show M+ End", "showMythicEnd"}
        }

        for _, s in ipairs(settings) do
            self:Text(child, s[1]..": "..(RaidPulseDB.config[s[2]] and "ON" or "OFF"), "GameFontNormal", {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 200, RaidPulseDB.config[s[2]] and self:UIColor("green") or self:UIColor("red"))
            self:Button(child, "Toggle", {"TOPLEFT", child, "TOPLEFT", 240, y+4}, 90, 22, function()
                RaidPulseDB.config[s[2]] = not RaidPulseDB.config[s[2]]
                MCA:BuildDashboard(data)
            end)
            y = y - 36
        end

    elseif self.activeTab == "players" then
        y = self:DrawPlayerTable(child, data, false, y)

    elseif self.activeTab == "playerDetail" then
        y = self:DrawPlayerTable(child, data, true, y)

    elseif self.activeTab == "interrupts" then
        local panel = self:Panel(child, {"TOPLEFT", child, "TOPLEFT", PAGE_X, y}, PAGE_W, PAGE_H)
        self:BuildInterruptPage(panel, data)
        y = y - 450

    elseif self.activeTab == "deaths" then
        local deathCols = {
            time   = {x=10,  w=70},
            player = {x=90,  w=200},
            boss   = {x=300, w=260},
            extra  = {x=570, w=400}
        }
        y = self:DrawPageTable(child, {
            {label="Tempo",  x=deathCols.time.x,   w=deathCols.time.w},
            {label="Player", x=deathCols.player.x, w=deathCols.player.w},
            {label="Boss",   x=deathCols.boss.x,   w=deathCols.boss.w},
            {label="Causa",  x=deathCols.extra.x,  w=deathCols.extra.w},
        }, self:BuildDeathsRows(data, deathCols), y)

    elseif self.activeTab == "buffs" then
        y = self:DrawPageTable(child, {
            {label="",           x=10,  w=45},
            {label="Buff",       x=60,  w=180},
            {label="Classe",     x=260, w=120},
            {label="Copertura",  x=400, w=70,  justify="CENTER"},
            {label="Stato",      x=500, w=90,  justify="CENTER"},
        }, self:BuildRaidBuffRows(data), y)

    elseif self.activeTab == "timeline" then
        local tlCols = {
            time   = {x=10,  w=70},
            event  = {x=90,  w=460},
            player = {x=560, w=160}
        }
        y = self:DrawPageTable(child, {
            {label="Tempo",  x=tlCols.time.x,   w=tlCols.time.w},
            {label="Evento", x=tlCols.event.x,  w=tlCols.event.w},
            {label="Player", x=tlCols.player.x, w=tlCols.player.w},
        }, self:BuildTimelineRows(data, tlCols), y)

    elseif self.activeTab == "compare" then
        y = self:DrawComparePage(child, data, y)

    elseif self.activeTab == "history" then
        y = -50 - self:DrawHistoryPage(child)

    else
        local totals = self:GetTotals(data)
        local lines = {
            "Player totali: "..totals.players,
            "Player con MCA: "..totals.addon.."/"..totals.players,
            "Difensivi usati: "..totals.cds,
            "Buff raid presenti: "..totals.buffActive.."/"..totals.buffPresent,
            "Deaths totali: "..totals.deaths,
            "Punteggio: "..self:ComputeRaidScore(data).."%"
        }

        for _, line in ipairs(lines) do
            self:Text(child, line, "GameFontNormalLarge", {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 420, self:UIColor("white"))
            y = y - 32
        end
    end

    self:UpdateScrollBar(child, scroll, math.abs(y)+80)
end




function MCA:FormatMetricValue(value)
    value = tonumber(value or 0) or 0
    if value <= 0 then return "-" end
    if value >= 1000000 then return string.format("%.2fM", value / 1000000) end
    if value >= 1000 then return string.format("%.0fk", value / 1000) end
    return tostring(math.floor(value))
end

function MCA:GetFightMetric(player)
    if not player then return 0 end

    if (player.role or "") == "HEALER" then
        if player.blizzardHps and player.blizzardHps > 0 then return player.blizzardHps end
        if player.blizzard and player.blizzard.hps and player.blizzard.hps.amountPerSecond then return player.blizzard.hps.amountPerSecond end
        return player.hps or player.fightHPS or player.healingPerSecond or 0
    end

    if player.blizzardDps and player.blizzardDps > 0 then return player.blizzardDps end
    if player.blizzard and player.blizzard.dps and player.blizzard.dps.amountPerSecond then return player.blizzard.dps.amountPerSecond end
    return player.dps or player.fightDPS or player.damagePerSecond or 0
end

function MCA:GetRatingColor(rating)
    rating = tonumber(rating or 0) or 0
    if rating >= 99 then return {0.886, 0.408, 1.000, 1} end -- pink
    if rating >= 95 then return {1.000, 0.502, 0.000, 1} end -- orange
    if rating >= 75 then return {0.639, 0.208, 0.933, 1} end -- purple
    if rating >= 50 then return {0.000, 0.439, 0.867, 1} end -- blue
    if rating >= 25 then return {0.118, 1.000, 0.000, 1} end -- green
    return {0.616, 0.616, 0.616, 1} -- gray
end

function MCA:CalculateRoleRatings(players)
    local maxDPS, maxHPS = 0, 0

    for _, p in ipairs(players or {}) do
        local value = self:GetFightMetric(p)
        if (p.role or "") == "HEALER" then
            if value > maxHPS then maxHPS = value end
        else
            if value > maxDPS then maxDPS = value end
        end
    end

    for _, p in ipairs(players or {}) do
        local value = self:GetFightMetric(p)
        local maxValue = ((p.role or "") == "HEALER") and maxHPS or maxDPS

        if maxValue and maxValue > 0 and value > 0 then
            p.mcaRating = math.floor(math.max(1, math.min(99, (value / maxValue) * 99)) + 0.5)
        else
            -- MCA: no DPS/HPS recorded for this player (value <= 0) -> rating must be 0,
            -- never fall back to a stale GetScore() value.
            p.mcaRating = 0
        end
    end
end

function MCA:BuildRoleList(data, wantHealer)
    local all = self:BuildPlayerList(data)
    local list = {}

    self:CalculateRoleRatings(all)

    for _, p in ipairs(all) do
        local isHealer = (p.role or "") == "HEALER"
        if (wantHealer and isHealer) or ((not wantHealer) and (not isHealer)) then
            table.insert(list, p)
        end
    end

    table.sort(list, function(a, b)
        local av = self:GetFightMetric(a)
        local bv = self:GetFightMetric(b)
        if av == bv then return (a.mcaRating or 0) > (b.mcaRating or 0) end
        return av > bv
    end)

    return list
end

function MCA:DrawRoleMetricTable(parent, data, title, wantHealer)
    -- Header band is 40px here (the scroll starts at -40), so the centre is -20.
    self:Text(parent, title, "GameFontHighlightLarge",
        {"CENTER", parent, "TOP", 0, -20}, parent:GetWidth()-28, self:UIColor("accent"), "CENTER")

    local outerW = parent:GetWidth() - 16
    local outerH = parent:GetHeight() - 50
    local _, child, scroll = self:Scroll(parent, {"TOPLEFT", parent, "TOPLEFT", 8, -40}, outerW, outerH, {0.018,0.020,0.022,0.55}, true)

    -- TableHeader sizes itself to the scroll child, so the rows have to use
    -- that same width or they stop short of the header — an 18px shortfall
    -- that showed as the header overhanging every row on its right.
    local tableW = outerW - 10
    local metricLabel = wantHealer and "HPS" or "DPS"

    local cols = {
        {label="#", x=6, w=22, justify="CENTER"},
        {label="Player", x=36, w=130},
        {label="Classe", x=178, w=105},
        {label="Morti", x=292, w=44, justify="CENTER"},
        {label=metricLabel, x=348, w=72, justify="CENTER"},
        {label="Parse", x=434, w=math.max(tableW - 434, 70), justify="CENTER"}
    }

    local y = -2
    y = self:TableHeader(child, cols, y)

    local list = self:BuildRoleList(data, wantHealer)

    if #list == 0 then
        self:Text(child, "Nessun dato registrato.", "GameFontNormal", {"TOPLEFT", child, "TOPLEFT", 12, y-6}, tableW-24, self:UIColor("gray"))
    end

    for i, p in ipairs(list) do
        local row = self:AcquireFrame("Button", child, "BackdropTemplate")
        row:SetPoint("TOPLEFT", 0, y)
        row:SetSize(tableW, 28)
        self:SetBackdropSolid(row, i % 2 == 0 and self:UIColor("rowAlt") or self:UIColor("row"), {0.12,0.13,0.14,1})

        local _, parseColor, parseText = self:ResolvePlayerParse(p, data)

        self:Text(row, tostring(i)..".", "GameFontNormal", {"LEFT", row, "LEFT", cols[1].x, 0}, cols[1].w, self:UIColor("white"), "CENTER")

        self:ClassIcon(row, p.class, cols[2].x, -5, 18)
        self:Text(row, p.name or "?", "GameFontNormal", {"LEFT", row, "LEFT", cols[2].x + 24, 0}, cols[2].w - 24, i % 3 == 0 and self:UIColor("blue") or (i % 3 == 1 and self:UIColor("accent") or self:UIColor("orange")))

        self:ClassIcon(row, p.class, cols[3].x, -5, 18)
        self:Text(row, self:PrettyClass(p.class), "GameFontNormalSmall", {"LEFT", row, "LEFT", cols[3].x + 24, 0}, cols[3].w - 24, self:UIColor("white"))

        self:Text(row, tostring(p.deaths or 0), "GameFontNormal", {"LEFT", row, "LEFT", cols[4].x, 0}, cols[4].w, (p.deaths or 0) > 0 and self:UIColor("red") or self:UIColor("white"), "CENTER")
        self:Text(row, self:FormatMetricValue(self:GetFightMetric(p)), "GameFontNormal", {"LEFT", row, "LEFT", cols[5].x, 0}, cols[5].w, self:UIColor("white"), "CENTER")
        self:Text(row, parseText, "GameFontNormal", {"LEFT", row, "LEFT", cols[6].x, 0}, cols[6].w, parseColor, "CENTER")

        row:SetScript("OnClick", function()
            MCA.selectedPlayer = p
            MCA.activeTab = "playerDetail"
            MCA:BuildDashboard(data)
        end)

        y = y - 28
    end

    self:UpdateScrollBar(child, scroll, math.abs(y)+20)
end

function MCA:DrawDashboardPage(root, data)
    -- v4.0.16 dashboard:
    -- Top row: DPS/Tank table left, Healer/HPS table right.
    -- Bottom row: Deaths, Timeline, Boss Breakdown.
    local leftX, totalW = CONTENT_X, CONTENT_W
    local gap = GAP

    -- Both rows share the body height, split so the cards keep roughly the
    -- proportion they had, and the bottom row lands exactly on the sidebar's
    -- bottom edge. Previously topY, the row heights and the card offset were
    -- four independent constants, which is why the gaps came out 6px above and
    -- 24px below, and the cards stopped 20px short of the sidebar.
    local topY = BODY_Y
    local rowsSpace = BODY_H - gap
    local topH = math.floor(rowsSpace * 0.59)

    local halfW = math.floor((totalW - gap) / 2)

    local dpsPanel = self:Panel(root, {"TOPLEFT", root, "TOPLEFT", leftX, topY}, halfW, topH)
    self:DrawRoleMetricTable(dpsPanel, data, "DPS / Tank", false)

    local healerPanel = self:Panel(root, {"TOPLEFT", root, "TOPLEFT", leftX + halfW + gap, topY}, halfW, topH)
    self:DrawRoleMetricTable(healerPanel, data, "Healer", true)

    local cardsY = topY - topH - gap
    local cardH = rowsSpace - topH
    local cardW = math.floor((totalW - (gap * 2)) / 3)

    local deathPanel = self:Panel(root, {"TOPLEFT", root, "TOPLEFT", leftX, cardsY}, cardW, cardH)
    self:DrawSmallPanel(deathPanel, "Deaths", nil, "red",
        {{label="Tempo",x=10,w=55},{label="Player",x=76,w=110},{label="Boss",x=198,w=110},{label="Causa",x=320,w=38}},
        self:BuildDeathsRows(data), nil)

    local timelinePanel = self:Panel(root, {"TOPLEFT", root, "TOPLEFT", leftX + cardW + gap, cardsY}, cardW, cardH)
    self:DrawSmallPanel(timelinePanel, "Timeline", nil, "blue",
        {{label="Tempo",x=10,w=55},{label="Evento",x=76,w=210},{label="Player",x=300,w=90}},
        self:BuildTimelineRows(data), nil)

    local bossPanel = self:Panel(root, {"TOPLEFT", root, "TOPLEFT", leftX + (cardW + gap) * 2, cardsY}, cardW, cardH)
    self:DrawBossBreakdown(bossPanel, data)
end

function MCA:GetDifficultyColor(difficulty)
    difficulty = tostring(difficulty or "")

    if difficulty:find("Mythic") then
        return self:UIColor("purple")
    elseif difficulty:find("Heroic") then
        return self:UIColor("orange")
    elseif difficulty:find("Normal") then
        return self:UIColor("green")
    elseif difficulty:find("LFR") then
        return self:UIColor("blue")
    end

    return self:UIColor("gray")
end





-- ============================================================================


-- MCA 4.0.29d restored real dashboard opener from 4.0.28
function MCA:BuildDashboard(data)
    -- Falling back rather than bailing: a caller with nothing to show still
    -- wants the window rebuilt, on the newest report or on the empty one.
    data = data or self:GetLastAvailableReport()
    if not data then return end

    -- MCA 4.3.6 apply M+ deaths before dashboard render
    if self.ApplyMythicPlusTotalDeaths then self:ApplyMythicPlusTotalDeaths(data) end

    -- Ratings are derived from the meter values, so they are recomputed on
    -- every render (late joiners and meter updates can change them).
    if self.ApplyClassBasedRatings then self:ApplyClassBasedRatings(data) end

    if not data.isEmpty then self.lastReport = data end

    -- Hand every widget from the previous render back to the pool before
    -- drawing this one. Without this the window is rebuilt from scratch and
    -- the old one is simply abandoned in memory.
    self:RecycleWidgets()

    -- The main frame is deliberately not recycled: it is created once and its
    -- only fontstring is the static title, so its cursors must NOT be rewound.
    local root = self:MainFrame()
    self:DrawSidebar(root)
    self:DrawTopDashboard(root, data)

    if self.activeTab == "boss" then
        self.activeTab = "summary"
    end

    if self.activeTab == "summary" then
        self:DrawDashboardPage(root, data)
    else
        self:DrawFullPage(root, data)
    end

    -- The button row sits on the same rectangle as everything above it: the
    -- left pair starts on the sidebar's edge, Chiudi ends on the content's
    -- right edge, and the row is one GAP below the body.
    local btnY = FRAME_H + CONTENT_BOTTOM - GAP - BTN_H
    self:Button(root, "Esporta Report", {"BOTTOMLEFT", root, "BOTTOMLEFT", SIDE_X, btnY}, SIDE_W, BTN_H,
        function() MCA:ShowExportWindow(data) end)
    self:Button(root, "Share in chat", {"BOTTOMLEFT", root, "BOTTOMLEFT", CONTENT_X, btnY}, 150, BTN_H,
        function() MCA:ShareSummary(data) end)
    self:Button(root, "Chiudi", {"BOTTOMRIGHT", root, "BOTTOMRIGHT", -MARGIN, btnY}, 120, BTN_H,
        function() root:Hide() end)

    root:Show()
end

function MCA:ShowUI(data)
    self.selectedPlayer = nil
    self.selectedBoss = nil
    self.activeTab = self.activeTab or "summary"
    self:BuildDashboard(data)
end



-- ============================================================================
-- MCA 4.1.0 UI Polish helpers
-- ============================================================================

function MCA:GetInnerTableWidth(parent, fallback, rightPadding)
    fallback = fallback or 1000
    rightPadding = rightPadding or 34

    if parent and parent.GetWidth then
        local w = parent:GetWidth()
        if w and w > 0 then
            return math.max(w - rightPadding, 320)
        end
    end

    return fallback
end

function MCA:StretchFrameToScrollbar(frame, parent, leftPadding, rightPadding)
    if not frame or not parent then return end
    leftPadding = leftPadding or 8
    rightPadding = rightPadding or 34

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", leftPadding, -8)
    frame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -rightPadding, 8)
end


-- ============================================================================
-- MCA 4.1.7 Interrupt tab
-- ============================================================================

function MCA:BuildInterruptPage(parent, report)
    if not parent then return end

    self:Text(parent, "Interrupt", "GameFontNormalLarge", {"TOPLEFT", parent, "TOPLEFT", 14, -12}, 180, self:UIColor("accent"))
    -- MCA 4.2.6 interrupt disabled notice
    self:Text(parent, "Interrupt temporaneamente disabilitati: build rebased su DPS/HPS stabile.", "GameFontNormalSmall", {"TOPLEFT", parent, "TOPLEFT", 120, -16}, 560, self:UIColor("orange"))

    local list = self:GetSortedInterruptPlayers(report)

    local box = self:AcquireFrame("Frame", parent, "BackdropTemplate")
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, -46)
    box:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -14, 14)

    if self.SetBackdropSolid then
        self:SetBackdropSolid(box, {0.02, 0.02, 0.025, 0.68}, {0.22, 0.22, 0.22, 1})
    elseif box.SetBackdrop then
        box:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 10,
            insets = {left=2,right=2,top=2,bottom=2}
        })
        box:SetBackdropColor(0.02, 0.02, 0.025, 0.68)
        box:SetBackdropBorderColor(0.22, 0.22, 0.22, 1)
    end

    local cols = {
        {label="#", x=12, w=36, justify="CENTER"},
        {label="Player", x=58, w=260},
        {label="Classe", x=340, w=220},
        {label="Interrupt", x=590, w=100, justify="CENTER"},
    }

    local header = self:AcquireFrame("Frame", box)
    header:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -10)
    header:SetPoint("TOPRIGHT", box, "TOPRIGHT", -8, -10)
    header:SetHeight(28)

    for _, c in ipairs(cols) do
        self:Text(header, c.label, "GameFontNormalSmall", {"LEFT", header, "LEFT", c.x, 0}, c.w, self:UIColor("white"), c.justify or "LEFT")
    end

    if not list or #list == 0 then
        self:Text(box, "Nessun interrupt registrato per questo encounter.", "GameFontNormal", {"TOPLEFT", box, "TOPLEFT", 20, -52}, 440, self:UIColor("gray"))
        return
    end

    local y = -42
    for i, p in ipairs(list) do
        local row = self:AcquireFrame("Frame", box)
        row:SetPoint("TOPLEFT", box, "TOPLEFT", 8, y)
        row:SetPoint("TOPRIGHT", box, "TOPRIGHT", -8, y)
        row:SetHeight(28)

        if self.SetBackdropSolid then
            self:SetBackdropSolid(row, i % 2 == 0 and {0.08,0.08,0.085,0.42} or {0.04,0.04,0.045,0.42}, {0.13,0.13,0.13,0.7})
        end

        self:Text(row, tostring(i)..".", "GameFontNormalSmall", {"LEFT", row, "LEFT", cols[1].x, 0}, cols[1].w, self:UIColor("white"), "CENTER")

        if self.ClassIcon and p.class then
            self:ClassIcon(row, p.class, cols[2].x, -6, 16)
            self:Text(row, p.name or "-", "GameFontNormalSmall", {"LEFT", row, "LEFT", cols[2].x + 22, 0}, cols[2].w - 22, self:UIColor("accent"))
        else
            self:Text(row, p.name or "-", "GameFontNormalSmall", {"LEFT", row, "LEFT", cols[2].x, 0}, cols[2].w, self:UIColor("accent"))
        end

        if self.ClassIcon and p.class then
            self:ClassIcon(row, p.class, cols[3].x, -6, 16)
            self:Text(row, tostring(p.class or "-"), "GameFontNormalSmall", {"LEFT", row, "LEFT", cols[3].x + 22, 0}, cols[3].w - 22, self:UIColor("white"))
        else
            self:Text(row, tostring(p.class or "-"), "GameFontNormalSmall", {"LEFT", row, "LEFT", cols[3].x, 0}, cols[3].w, self:UIColor("white"))
        end

        self:Text(row, tostring(self:GetInterruptValue(p)), "GameFontNormalSmall", {"LEFT", row, "LEFT", cols[4].x, 0}, cols[4].w, self:UIColor("green"), "CENTER")

        y = y - 28
    end
end


-- MCA 4.1.8 Interrupt tab aliases
function MCA:BuildInterruptsTab(parent, report)
    if self.BuildInterruptPage then
        return self:BuildInterruptPage(parent, report)
    end
end


-- ============================================================================
-- MCA 4.3.4 strict summary rating helpers
-- Summary rows must never use stale row.score/rating fallbacks.
-- ============================================================================

function MCA:GetSummaryRatingForPlayer(player)
    if not player then return 0 end
    if self.ApplyClassBasedRatings and self.lastReport then
        self:ApplyClassBasedRatings(self.lastReport)
    end
    return self:GetDisplayRating(player)
end

function MCA:GetPlayerMeterValueForDisplay(player, metric)
    if not player then return 0 end
    if metric == "hps" then
        return tonumber(player.blizzardHps or player.hps or player.fightHPS or player.healingPerSecond or 0) or 0
    end
    return tonumber(player.blizzardDps or player.dps or player.fightDPS or player.damagePerSecond or player.amountPerSecond or 0) or 0
end

function MCA:GetStrictRatingText(player, metric)
    local value = self:GetPlayerMeterValueForDisplay(player, metric)
    if not value or value <= 0 then return "0" end
    return tostring(self:GetDisplayRating(player))
end


-- ============================================================================
-- MCA 4.3.6 Mythic+ header helpers
-- ============================================================================

function MCA:GetHeaderDeathsValue(data)
    if self.ApplyMythicPlusTotalDeaths then self:ApplyMythicPlusTotalDeaths(data) end
    return tonumber(data and (data.totalDeaths or data.deaths or data.mplusDeathsTotal or 0) or 0) or 0
end

function MCA:GetHeaderCdOrDeathsLabel(data)
    if self.IsMythicPlusData and self:IsMythicPlusData(data) then
        return "Morti Totali"
    end
    return "Deaths"
end

function MCA:GetHeaderCdOrDeathsValue(data)
    if self.IsMythicPlusData and self:IsMythicPlusData(data) then
        return self:GetHeaderDeathsValue(data)
    end
    local totals = data and self:GetTotals(data)
    return tonumber(totals and totals.deaths or 0) or 0
end
