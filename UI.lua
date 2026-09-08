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
-- Sized as a share of the screen rather than to a fixed pixel cap. The cap was
-- the bug: at a UI scale of 0.53 on a 2560-wide display UIParent is roughly
-- 4800 units across, so an 1800-wide window covered barely a third of it and
-- every table was cramped for no reason.
--
-- These are locals reassigned by computeLayout() instead of constants, so
-- changing the size takes effect without a reload.
local FRAME_W, FRAME_H
local SCREEN_W, SCREEN_H
local MARGIN, GAP, BTN_H = 8, 16, 34
local SIDE_X, SIDE_Y, SIDE_W, SIDE_H, SIDE_BOTTOM_GAP
local CONTENT_BOTTOM, CONTENT_X, CONTENT_W
local DASH_Y, DASH_H, BODY_Y, BODY_H
local PAGE_X, PAGE_W, PAGE_H, PAGE_PAD

-- Column positions throughout are written against this width and scaled to
-- whatever the page actually is. Widening the window used to add empty space
-- on the right instead of room for the data, because every table but the
-- comparison had its columns pinned to absolute pixels.
local PAGE_REF_W = 1108

local WINDOW_SHARE_DEFAULT = 0.78     -- of the screen, both axes
local WINDOW_MIN_W, WINDOW_MIN_H = 1320, 780
local WINDOW_MAX_W, WINDOW_MAX_H = 4200, 2800

local function computeLayout()
    local uiW, uiH
    if UIParent and UIParent.GetSize then
        local ok, w, h = pcall(UIParent.GetSize, UIParent)
        if ok and type(w) == "number" and type(h) == "number" then uiW, uiH = w, h end
    end

    local share = WINDOW_SHARE_DEFAULT
    if RaidPulseDB and RaidPulseDB.config and tonumber(RaidPulseDB.config.windowShare) then
        share = math.max(0.4, math.min(1.0, tonumber(RaidPulseDB.config.windowShare)))
    end

    SCREEN_W, SCREEN_H = uiW, uiH

    FRAME_W, FRAME_H = WINDOW_MIN_W, WINDOW_MIN_H
    if uiW and uiH and uiW > 0 and uiH > 0 then
        -- The screen is the last word. A window wider than the display puts
        -- its own title bar out of reach, which is worse than a cramped table.
        FRAME_W = math.floor(math.min(uiW,
            math.max(WINDOW_MIN_W, math.min(WINDOW_MAX_W, uiW * share))))
        FRAME_H = math.floor(math.min(uiH,
            math.max(WINDOW_MIN_H, math.min(WINDOW_MAX_H, uiH * share))))
    end

    SIDE_X, SIDE_Y = MARGIN, -MARGIN
    SIDE_W = 138
    SIDE_BOTTOM_GAP = 20                -- below the button row
    -- The sidebar spans everything above the button row, so it follows the
    -- frame height rather than being pinned to a value that suited one size.
    SIDE_H = FRAME_H - MARGIN - GAP - BTN_H - SIDE_BOTTOM_GAP
    CONTENT_BOTTOM = SIDE_Y - SIDE_H     -- every block ends here

    -- The rectangle the dashboard, the summary and the scroll container share:
    -- one gap right of the sidebar, the same margin on the right as the left.
    CONTENT_X = SIDE_X + SIDE_W + GAP
    CONTENT_W = FRAME_W - MARGIN - CONTENT_X

    DASH_Y, DASH_H = -36, 64             -- the KPI strip under the title
    BODY_Y = DASH_Y - DASH_H - GAP       -- top of everything below it
    BODY_H = math.abs(CONTENT_BOTTOM) - math.abs(BODY_Y)

    -- Margins *inside* the scroll: Scroll() insets its child by 4 and sizes it
    -- to CONTENT_W - 10, and the scrollbar sits over the right edge of that.
    PAGE_X, PAGE_PAD = 8, 8
    PAGE_W = CONTENT_W - 10 - PAGE_X - 24
    PAGE_H = 430                         -- for the tabs that still use a panel
end

computeLayout()

-- computeLayout() runs when this file loads, before saved variables exist, so
-- it falls back to the default share. Called again once the DB is up to pick
-- up a stored size.
-- Resize the window keeping its TOP-LEFT corner exactly where it is.
--
-- Everything inside is anchored from that corner, so nothing shifts under the
-- cursor. With the frame anchored by its CENTER the left edge crept outward as
-- the window grew, the size slider crept with it, and the mouse -- which had
-- not moved -- was suddenly further along the track: the value climbed, the
-- window grew again, and one nudge slammed it from the minimum to 100%.
--
-- While a drag is in progress the corner is left alone even if the window runs
-- past the edge of the screen; moving it would restart that same feedback. It
-- is pulled back on screen when the drag ends.
local function applyFrameSize(keepOnScreen)
    local f = _G.MCAFrame
    if not f then return end

    local left, top = f:GetLeft(), f:GetTop()
    if not left or not top then
        f:SetSize(FRAME_W, FRAME_H)
        return
    end

    if keepOnScreen and SCREEN_W and SCREEN_H then
        left = math.max(0, math.min(left, SCREEN_W - FRAME_W))
        top = math.min(SCREEN_H, math.max(top, FRAME_H))
    end

    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    f:SetSize(FRAME_W, FRAME_H)

    if RaidPulseDB then
        RaidPulseDB.framePos = {point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = left, y = top}
    end
end

-- `dragging` skips the on-screen clamp; see applyFrameSize.
function MCA:RefreshLayout(dragging)
    computeLayout()
    applyFrameSize(not dragging)
end

-- Resize without a reload. The frame is resized rather than destroyed: it is
-- created once and kept on purpose, and orphaning it would leak exactly what
-- the widget pool exists to avoid. Its contents come from the pool and are
-- redrawn at the new measurements anyway.
-- Resize the frame only. Used while a slider is being dragged: rebuilding the
-- window on every value change would recycle the slider being dragged, so the
-- frame grows live and the contents reflow once the mouse is released.
function MCA:PreviewWindowShare(share)
    RaidPulseDB.config = RaidPulseDB.config or {}
    RaidPulseDB.config.windowShare = math.max(0.4, math.min(1.0, tonumber(share) or WINDOW_SHARE_DEFAULT))
    self:RefreshLayout(true)
    return FRAME_W, FRAME_H
end

function MCA:GetWindowShare()
    local v = RaidPulseDB and RaidPulseDB.config and tonumber(RaidPulseDB.config.windowShare)
    return v or WINDOW_SHARE_DEFAULT
end

function MCA:GetWindowSize()
    return FRAME_W, FRAME_H
end

-- UIParent measured in UI units, which is what the window is sized in. Not
-- pixels: at a UI scale of 0.53 a 2560-wide display is ~4800 units across.
function MCA:GetScreenUnits()
    return SCREEN_W, SCREEN_H
end

-- The smallest share that still produces a usable window. Every table is
-- written against a 1108-unit page, so under WINDOW_MIN_W columns start
-- falling off the right edge and the size clamps. On a small screen that floor
-- can already be most of the display, and the slider offers that range instead
-- of percentages that would all clamp to the same size.
function MCA:GetMinWindowShare()
    if not (SCREEN_W and SCREEN_H and SCREEN_W > 0 and SCREEN_H > 0) then return 0.4 end
    return math.max(0.4, math.min(1.0,
        math.max(WINDOW_MIN_W / SCREEN_W, WINDOW_MIN_H / SCREEN_H)))
end

function MCA:SetWindowShare(share)
    RaidPulseDB.config = RaidPulseDB.config or {}
    RaidPulseDB.config.windowShare = math.max(0.4, math.min(1.0, tonumber(share) or WINDOW_SHARE_DEFAULT))

    self:RefreshLayout()
    self:Print(string.format("Finestra al %d%% dello schermo (%dx%d unita', schermo %s).",
        math.floor(RaidPulseDB.config.windowShare * 100 + 0.5), FRAME_W, FRAME_H,
        (SCREEN_W and SCREEN_H) and string.format("%dx%d", SCREEN_W, SCREEN_H) or "?"))
    self:BuildDashboard(self:GetLastAvailableReport())
end

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

local function poolKeyFor(ftype, template, tag)
    return (ftype or "Frame") .. "|" .. (template or "") .. "|" .. (tag or "")
end

-- Reset the per-frame cursors so its fontstrings and textures are handed out
-- from the start again.
local function resetWidgetCursors(f)
    f._rpTextCursor = 0
    f._rpTexCursor = 0
end

-- `tag` separates pools for frames that share a type and template but not a
-- role. Without it a scroll child and a spell-icon frame were both "Frame|"
-- and could be handed to each other's job.
function MCA:AcquireFrame(ftype, parent, template, tag)
    local key = poolKeyFor(ftype, template, tag)
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

-- Rewind a frame that is NOT pooled, so it can be drawn on again from scratch.
-- Resetting the cursors alone is not enough: nothing would hide what the
-- previous render left on it, which is how the settings list stayed on screen
-- underneath every tab opened after it.
function MCA:RewindWidget(f)
    if not f then return end

    if f._rpTexts then
        for i = 1, #f._rpTexts do f._rpTexts[i]:Hide() end
    end
    if f._rpTextures then
        for i = 1, #f._rpTextures do f._rpTextures[i]:Hide() end
    end

    f._rpTextCursor = 0
    f._rpTexCursor = 0
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

        local key = f._rpPoolKey or poolKeyFor("Frame", nil, nil)
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

-- Built from a bare Slider rather than OptionsSliderTemplate: that template
-- reaches for its labels through globals derived from the frame's name, and
-- pooled frames are deliberately unnamed. The labels are ours instead.
function MCA:Slider(parent, point, w, minV, maxV, value, onChange, onRelease)
    -- BackdropTemplate rather than a bare Slider: SetBackdrop arrives with
    -- that template's mixin, and calling it on a plain Slider raises — which
    -- took the whole rest of the settings page down with it.
    local slider = self:AcquireFrame("Slider", parent, "BackdropTemplate", "slider")
    slider:SetPoint(unpack(point))
    slider:SetSize(w, 16)
    slider:SetOrientation("HORIZONTAL")

    -- Style once and let it ride along with the pooled frame. A flat bar cut
    -- from WHITE8X8 rather than Blizzard's rounded slider knob: the knob is
    -- drawn at its own proportions and reads as a bead on a string next to
    -- the squared-off panels around it.
    if not slider.rpStyled then
        slider:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
        local thumb = slider:GetThumbTexture()
        if thumb then
            thumb:SetSize(12, 22)
            local a = self:UIColor("accent")
            thumb:SetVertexColor(a[1], a[2], a[3], 1)
        end
        slider.rpStyled = true
    end
    self:SetBackdropSolid(slider, {0.05,0.05,0.06,0.9}, {0.30,0.31,0.33,1})

    -- Unhook first. A recycled slider still carries the previous render's
    -- handler, and SetMinMaxValues can clamp the current value into range,
    -- which would fire that handler with a closure over a fontstring that has
    -- since been handed to something else.
    slider:SetScript("OnValueChanged", nil)

    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end

    -- The value goes in while nothing is listening, or positioning the thumb
    -- would itself count as a change and apply a resize on every render.
    slider:SetValue(value)
    slider:SetScript("OnValueChanged", function(_, v)
        if onChange then onChange(math.floor(v + 0.5)) end
    end)
    slider:SetScript("OnMouseUp", function(sliderFrame)
        if onRelease then onRelease(math.floor(sliderFrame:GetValue() + 0.5)) end
    end)

    slider:Show()
    return slider
end

function MCA:Scroll(parent, point, w, h, bg, flush)
    -- Tagged so scroll containers keep their own pool: a recycled plain panel
    -- must never be handed out as one, because the scroll frame and its child
    -- ride along with it.
    local outer = self:AcquireFrame("Frame", parent, "BackdropTemplate", "scroll")
    outer:SetPoint(unpack(point))
    outer:SetSize(w, h)
    self:SetBackdropSolid(outer,
        flush and TRANSPARENT or (bg or self:UIColor("panel")),
        flush and TRANSPARENT or self:UIColor("border"))

    -- The scroll frame and its child are created once per container and never
    -- pooled. Reparenting a frame that is still registered as some scroll
    -- frame's child leaves a dangling pointer on the C side and crashes the
    -- client outright — which is exactly what happened when scroll children
    -- shared a pool with the spell-icon frames.
    local scroll = outer.rpScroll
    if not scroll then
        scroll = CreateFrame("ScrollFrame", nil, outer, "UIPanelScrollFrameTemplate")
        outer.rpScroll = scroll
    end
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -4, 4)
    scroll:Show()

    local child = scroll.rpChild
    if not child then
        child = CreateFrame("Frame", nil, scroll)
        scroll.rpChild = child
        scroll:SetScrollChild(child)
    end
    child:SetSize(w - 10, h - 8)
    child:Show()
    -- Kept out of the pool, so it is rewound here instead.
    self:RewindWidget(child)

    -- A reused scroll keeps the offset its previous table was left at, which
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
    local f = self:AcquireFrame("Frame", parent, nil, "spellicon")
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

-- Class colours, the convention every WoW UI shares.
--
-- CUSTOM_CLASS_COLORS is checked first: unit-frame addons set it when the
-- player has chosen their own palette, and matching what the rest of their UI
-- already shows matters more than matching Blizzard's defaults.
function MCA:GetClassColor(class)
    local token = tostring(class or ""):upper()
    local c = (_G.CUSTOM_CLASS_COLORS and _G.CUSTOM_CLASS_COLORS[token])
           or (_G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[token])

    if c and c.r then return {c.r, c.g, c.b, 1} end
    return self:UIColor("white")
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
        {"Compare","compare"},
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
                self:Text(row, "OK", "GameFontNormalSmall", {"LEFT", row, "LEFT", x, 0}, buffColW, self:UIColor("green"), "CENTER")
            elseif has == false then
                self:Text(row, "X", "GameFontHighlightLarge", {"LEFT", row, "LEFT", x, 0}, buffColW, self:UIColor("red"), "CENTER")
            else
                self:Text(row, "-", "GameFontNormalLarge", {"LEFT", row, "LEFT", x, 0}, buffColW, self:UIColor("gray"), "CENTER")
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

-- How long the history delete button stays armed after the first click.
-- Declared here, above its only user: a local declared further down the file
-- is not in scope earlier, and the name would silently resolve to a nil
-- global -- which the arming comparison would then blow up on.
local HISTORY_DELETE_ARM_SECONDS = 8

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
        MCA.historyDeleteArmed = nil       -- a new filter is a new question
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

    -- Two clicks, not one. This button sits in the same row as the filters,
    -- there is no undo, and a night of pulls is gone the moment it is pressed
    -- by accident. The first click only arms it; the label says so, and the
    -- arming lapses on its own so it cannot sit armed waiting for a stray
    -- click later.
    local armed = MCA.historyDeleteArmed
    local isArmed = armed and armed.filter == filter
        and (GetTime() - (armed.at or 0)) < HISTORY_DELETE_ARM_SECONDS

    self:Button(parent, isArmed and ("Confermi? " .. deleteLabel) or deleteLabel,
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_W - 180, -50}, 180, 24, function()
        if deleteCount == 0 then
            MCA:Print("Nessun report da cancellare con questo filtro.")
            return
        end

        if not isArmed then
            MCA.historyDeleteArmed = {filter = filter, at = GetTime()}
            MCA:Print(string.format(
                "Clicca di nuovo entro %d secondi per cancellare %d report. Non c'e' modo di annullare.",
                HISTORY_DELETE_ARM_SECONDS, deleteCount))
            MCA.activeTab = "history"
            MCA:BuildDashboard(MCA:GetLastAvailableReport())
            return
        end

        MCA.historyDeleteArmed = nil
        if filter then
            MCA:ClearHistoryByResult(filter == "kill")
        else
            MCA:ClearHistory()
        end
        MCA:Print(string.format("Nello storico restano %d report.",
            #(RaidPulseDB.history or {})))
        MCA.activeTab = "history"
        MCA:BuildDashboard(MCA:GetLastAvailableReport())
    end, true)

    -- Same scaling the shared table renderer applies, so the history stretches
    -- with the window instead of huddling on the left of a wide page.
    local k = self:ColScale()

    local header = self:AcquireFrame("Frame", parent, "BackdropTemplate")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", PAGE_X, -92)
    header:SetSize(PAGE_W, 28)
    self:SetBackdropSolid(header, {0.025,0.027,0.030,0.95}, {0.16,0.17,0.18,1})

    self:Text(header, "Data", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 10 * k, 0}, 120 * k, self:UIColor("white"))
    self:Text(header, "Tipo", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 145 * k, 0}, 70 * k, self:UIColor("white"))
    self:Text(header, "Encounter / Dungeon", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 230 * k, 0}, 260 * k, self:UIColor("white"))
    self:Text(header, "Modalità", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 510 * k, 0}, 130 * k, self:UIColor("white"))
    self:Text(header, "Durata", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 660 * k, 0}, 70 * k, self:UIColor("white"))
    self:Text(header, "Esito", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 750 * k, 0}, 70 * k, self:UIColor("white"))
    self:Text(header, "Avg DPS", "GameFontHighlightSmall", {"LEFT", header, "LEFT", 840 * k, 0}, 70 * k, self:UIColor("white"))

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

        self:Text(row, report.savedAt or "?", "GameFontNormalSmall", {"LEFT", row, "LEFT", 10 * k, 0}, 120 * k, self:UIColor("gray"))
        self:Text(row, report.type or "?", "GameFontNormalSmall", {"LEFT", row, "LEFT", 145 * k, 0}, 70 * k, self:UIColor("accent"))
        self:Text(row, report.boss or "?", "GameFontNormal", {"LEFT", row, "LEFT", 230 * k, 0}, 260 * k, self:UIColor("white"))
        self:Text(row, self:GetModeDifficultyText(report), "GameFontNormalSmall", {"LEFT", row, "LEFT", 510 * k, 0}, 130 * k, self:GetDifficultyColor(report.difficulty))
        self:Text(row, self:FormatTime(report.duration or 0), "GameFontNormalSmall", {"LEFT", row, "LEFT", 660 * k, 0}, 70 * k, self:UIColor("white"))
        self:Text(row, resultText, "GameFontNormalSmall", {"LEFT", row, "LEFT", 750 * k, 0}, 70 * k, isKill and self:UIColor("green") or self:UIColor("red"))
        self:Text(row, self:FormatMetricValue(self:ComputeAverageDPS(report)), "GameFontNormalSmall", {"LEFT", row, "LEFT", 840 * k, 0}, 70 * k, self:UIColor("accent"))

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
-- How much to stretch column positions written against PAGE_REF_W. Never
-- squeezes below the reference: a narrow window scrolls rather than overlaps.
function MCA:ColScale()
    return math.max(1, PAGE_W / PAGE_REF_W)
end

function MCA:DrawPageTable(parent, headers, rows, y)
    local k = self:ColScale()
    local header = self:AcquireFrame("Frame", parent, "BackdropTemplate")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", PAGE_X, y)
    header:SetSize(PAGE_W, 28)
    self:SetBackdropSolid(header, {0.025,0.027,0.030,0.95}, {0.16,0.17,0.18,1})

    for _, c in ipairs(headers or {}) do
        self:Text(header, c.label, "GameFontHighlightSmall",
            {"LEFT", header, "LEFT", c.x * k, 0}, c.w * k, self:UIColor("white"), c.justify)
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

        -- A highlighted row is lifted clear of the alternating stripes and given
        -- a visible border, so finding yourself in a 25-name table is a glance
        -- rather than a search.
        local border = rowData.highlight and {0.45,0.47,0.50,1} or {0.12,0.13,0.14,1}
        if rowData.highlight then
            self:SetBackdropSolid(row, {0.20,0.21,0.23,0.95}, border)
        else
            self:SetBackdropSolid(row, i % 2 == 0 and self:UIColor("rowAlt") or self:UIColor("row"), border)
        end

        if rowData.onClick then
            row:SetScript("OnClick", rowData.onClick)
            -- Nothing else marks a row as clickable, so the border answers on
            -- hover. The resting colour is captured here rather than read back
            -- inside the handler, which would return whatever hover just set.
            row:SetScript("OnEnter", function() row:SetBackdropBorderColor(1, 0.82, 0, 1) end)
            row:SetScript("OnLeave", function()
                row:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
            end)
        end

        for _, cell in ipairs(rowData) do
            local iconW = 0
            if cell.spellID then
                self:SpellIcon(row, cell.spellID, cell.x * k, -6, 18)
                iconW = 25
            elseif cell.classIcon then
                self:ClassIcon(row, cell.classIcon, cell.x * k, -6, 18)
                iconW = 24
            end

            self:Text(row, cell.text or "", cell.font or "GameFontNormalSmall",
                {"LEFT", row, "LEFT", cell.x * k + iconW, 0}, (cell.w or 80) * k - iconW,
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
-- What can be compared. Every one of these is already captured per player and
-- readable — none of it is protected the way boss health turned out to be.
--
--   kind "rate"  : per-second figures, compared with a 5% deadband so ordinary
--                  variance is not painted as a trend
--   kind "count" : small integers, where any difference is the signal
--
-- `better` says which direction is good, so deaths colour the opposite way to
-- everything else.
local COMPARE_METRICS = {
    {key = "dps",        label = "DPS",       kind = "rate",  better = 1,
     get = function(self, p) return self:GetPlayerDPS(p) end},
    {key = "damage",     label = "Damage Overall", kind = "rate", better = 1,
     get = function(self, p) return tonumber(p.blizzardDamageDone or p.damageDone) or 0 end},
    {key = "hps",        label = "HPS",       kind = "rate",  better = 1,
     get = function(self, p) return tonumber(p.blizzardHps or p.hps) or 0 end},
    {key = "healing",    label = "Heal Overall",   kind = "rate", better = 1,
     get = function(self, p) return tonumber(p.blizzardHealingDone or p.healingDone) or 0 end},
    {key = "parse",      label = "Parse",     kind = "count", better = 1,
     get = function(self, p) return tonumber(p.mcaRating) or 0 end},
    {key = "deaths",     label = "Morti",     kind = "count", better = -1,
     get = function(self, p) return tonumber(p.deaths) or 0 end},
}

-- Defensives and interrupts are deliberately absent. Neither can be filled in
-- for anyone but the local player: UNIT_SPELLCAST_SUCCEEDED does not reliably
-- fire for other raid members and the addon sync that used to cover that gap
-- was removed, while interrupts only ever arrive from the meter. A column of
-- zeroes for twenty-four people is worse than not offering the comparison.

function MCA:GetCompareMetric()
    for _, m in ipairs(COMPARE_METRICS) do
        if m.key == self.compareMetric then return m end
    end
    return COMPARE_METRICS[1]
end

-- Columns get narrow fast, so cap how many attempts render at once. Selecting
-- more than this keeps the newest and says so rather than squeezing "156k +2"
-- into 60 pixels.
local COMPARE_MAX_COLUMNS = 8

-- savedAt is "dd/mm/yyyy HH:MM" and the chips only have room for the clock,
-- which is what tells attempts apart within one night anyway.
--
-- Kill or wipe is carried by colour rather than a symbol: WoW's fonts cover
-- Latin-1 but not the dingbat range, so the "nh" that used to be
-- appended here came out as an empty box on every chip and column header.
-- Inline colour codes always render.
-- Kill and wipe are drawn in these two colours everywhere an attempt is shown,
-- as text in the comparison tab and as a band under the columns in the player
-- charts. Defined once as numbers and turned into escape codes on demand, so
-- the two cannot drift apart.
local OUTCOME_COLOR = {
    kill = {85 / 255, 221 / 255, 85 / 255, 1},
    wipe = {1, 85 / 255, 85 / 255, 1},
}

local function outcomeColor(report)
    if report and report.result then return OUTCOME_COLOR.kill end
    return OUTCOME_COLOR.wipe
end

local function colorCode(c)
    return string.format("%02x%02x%02x",
        math.floor(c[1] * 255 + 0.5),
        math.floor(c[2] * 255 + 0.5),
        math.floor(c[3] * 255 + 0.5))
end

local function attemptLabel(report)
    local t = tostring(report and report.savedAt or "")
    t = t:match("(%d%d:%d%d)%s*$") or t

    -- Runs of one dungeon are charted together whatever the key, so each
    -- column has to carry its level: without it a +4 next to a +10 reads as
    -- the player having got worse.
    if report and (report.type or "") == "M+" then
        local level = tostring(report.difficulty or ""):match("^%+%d+$")
        if level then t = t .. " " .. level end
    end

    return "|cff" .. colorCode(outcomeColor(report)) .. t .. "|r"
end

-- Which attempts belong together.
--
-- Raid pulls are scoped to the raid group: a night with one roster and a night
-- with another are not the same measurement, which is why the key carries the
-- group.
--
-- A key is the opposite case. The group disbands at the end of every M+ run,
-- so keying those on the group would leave each run alone on its own island
-- and there would never be two of anything to compare. Runs of the same
-- dungeon are comparable whoever they were run with and at whatever level, so
-- they share one bucket keyed on the dungeon alone. The level still shows on
-- each column, because a +4 and a +10 side by side otherwise read as one
-- player getting better.
local ANY_GROUP = "*"

local function fightGroupOf(report)
    if report and (report.type or "") == "M+" then return ANY_GROUP end
    return (report and report.groupID) or "legacy"
end

local function fightKeyFor(report)
    return tostring(report and report.boss) .. "||" .. fightGroupOf(report)
end

-- Every fight in the history worth comparing: one entry per boss (raid) or
-- dungeon (key), with at least two saved attempts, most recently played first.
--
-- Listing these is what lets the tab work while standing in a city doing
-- nothing. It used to compare only the fight of whichever report happened to
-- be open, which meant the answer to "how did we do on the other boss" was to
-- go find that report first.
function MCA:GetComparableFights()
    local history = self.GetHistory and self:GetHistory() or (RaidPulseDB.history or {})

    local byKey, order = {}, {}
    for _, r in ipairs(history) do
        if r and r.boss and r.boss ~= "" and r.historyID then
            -- Reports saved before groups were tracked share one legacy
            -- bucket rather than each becoming an uncomparable island.
            local groupID = fightGroupOf(r)
            local key = fightKeyFor(r)

            local entry = byKey[key]
            if not entry then
                entry = {key = key, boss = r.boss, groupID = groupID, type = r.type,
                         count = 0, latest = 0, groupStartedAt = r.groupStartedAt}
                byKey[key] = entry
                order[#order + 1] = entry
            end
            entry.count = entry.count + 1
            entry.latest = math.max(entry.latest, tonumber(r.savedAtEpoch) or 0)
        end
    end

    -- A single attempt has nothing to be compared against, so it is not offered.
    local out, bossCounts = {}, {}
    for _, entry in ipairs(order) do
        if entry.count >= 2 then
            out[#out + 1] = entry
            bossCounts[entry.boss] = (bossCounts[entry.boss] or 0) + 1
        end
    end

    table.sort(out, function(a, b) return a.latest > b.latest end)

    -- Only say which group when the same fight appears under more than one,
    -- otherwise every chip carries a date nobody needs to read.
    for _, entry in ipairs(out) do
        entry.label = entry.boss
        if (bossCounts[entry.boss] or 0) > 1 then
            local when = entry.groupStartedAt or entry.latest
            local stamp = (when and when > 0 and date and date("%d/%m %H:%M", when)) or "gruppo prec."
            entry.label = entry.boss .. " - " .. stamp
        end
    end

    return out
end

-- The calendar day an attempt belongs to, as dd/mm/yyyy. Read from savedAt
-- rather than recomputed from the epoch: that string is what every label in
-- the window already shows, and two sources for one date drift.
function MCA:GetAttemptDay(report)
    local stamp = tostring(report and report.savedAt or "")
    return stamp:match("^(%d%d/%d%d/%d%d%d%d)") or stamp:match("^(%d%d/%d%d)") or nil
end

-- Resolve a stored day filter against the days actually available.
--
-- Three states, not two. nil is "not decided yet" and takes the default:
-- today, or the most recent day there is when the fight was not played today.
-- false is "the player asked for every day". A string is a choice. Without the
-- difference between nil and false, choosing every day would be undone by the
-- next redraw, and these tabs redraw on every click in them.
--
-- Shared by the comparison tab and the player page so the two cannot drift.
-- `countByDay`, when given, keeps the default from landing on a day with a
-- single attempt: there is nothing to compare there, and for an M+ dungeon --
-- whose runs are pooled across groups and key levels on purpose -- today is
-- very often exactly one run. An explicit pick is still honoured at one
-- attempt, because that was asked for.
function MCA:ResolveDayFilter(stored, days, countByDay)
    local active
    if stored then
        for _, day in ipairs(days) do
            if day == stored then active = day end
        end
        -- A day left over from another fight matches nothing here, so the
        -- default decides again instead of emptying the page.
        if not active then stored = nil end
    end

    if stored == nil then
        local today = date and date("%d/%m/%Y") or nil
        for _, day in ipairs(days) do
            if day == today then active = day end
        end
        active = active or days[1]

        if active and countByDay and #days > 1
            and (countByDay[active] or 0) < 2 then
            active = nil
        end

        stored = active or false
    end

    return active, stored
end

-- How many of these attempts fall on each day.
function MCA:CountAttemptsByDay(reports)
    local counts = {}
    for _, r in ipairs(reports) do
        local day = self:GetAttemptDay(r.report or r)
        if day then counts[day] = (counts[day] or 0) + 1 end
    end
    return counts
end

-- The days a set of attempts covers, newest first.
function MCA:GetAttemptDays(candidates)
    local seen, days = {}, {}
    for _, r in ipairs(candidates) do
        local day = self:GetAttemptDay(r)
        if day and not seen[day] then
            seen[day] = true
            days[#days + 1] = day
        end
    end
    return days
end

-- Every saved attempt on one fight, for one group, newest first.
function MCA:GetComparisonCandidates(boss, groupID)
    if not boss or boss == "" then return {} end

    local history = self.GetHistory and self:GetHistory() or (RaidPulseDB.history or {})
    local out = {}
    for i = #history, 1, -1 do
        local r = history[i]
        if r and r.boss == boss and r.historyID
           and (groupID == ANY_GROUP or (r.groupID or "legacy") == (groupID or "legacy")) then
            out[#out + 1] = r
        end
    end
    return out
end

-- Which fight the tab is showing. Prefers an explicit pick, then the open
-- report's own fight, then whatever was played most recently — so opening the
-- tab always lands on something rather than on an empty page.
function MCA:GetCompareFight(fights, data)
    for _, f in ipairs(fights) do
        if f.key == self.compareFightKey then return f end
    end

    -- The open report's own fight, matched on its group too so it does not
    -- land on the same boss played with someone else.
    if data and data.boss then
        local wanted = fightKeyFor(data)
        for _, f in ipairs(fights) do
            if f.key == wanted then
                self.compareFightKey = f.key
                self.compareSelection = nil
                return f
            end
        end
    end

    local first = fights[1]
    self.compareFightKey = first and first.key
    self.compareSelection = nil
    return first
end

-- Selection is per fight: switching fights starts fresh rather than carrying
-- ticks that refer to another encounter's attempts.
function MCA:GetCompareSelection(candidates)
    if not self.compareSelection then
        -- Default to the newest few, so the tab is useful before touching it.
        self.compareSelection = {}
        for i = 1, math.min(#candidates, 4) do
            self.compareSelection[candidates[i].historyID] = true
        end
    end
    return self.compareSelection
end

-- Lay a row of chips out across the page, wrapping as needed. Returns the y
-- below the last row.
local function chipGrid(self, parent, y, items, chipW, render)
    local chipH, gap = 24, 6
    local perRow = math.max(1, math.floor((PAGE_W + gap) / (chipW + gap)))

    for i, item in ipairs(items) do
        local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
        render(item,
            {"TOPLEFT", parent, "TOPLEFT", PAGE_X + col * (chipW + gap), y - row * (chipH + gap)},
            chipW, chipH)
    end

    return y - math.ceil(#items / perRow) * (chipH + gap)
end

function MCA:DrawComparePage(parent, data, y)
    local fights = self:GetComparableFights()

    if #fights == 0 then
        self:Text(parent, "Nessun fight con almeno due tentativi salvati da confrontare.",
            "GameFontNormal", {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 6},
            700, self:UIColor("gray"))
        return y - 40
    end

    local function rebuild()
        MCA.activeTab = "compare"
        MCA:BuildDashboard(MCA:GetLastAvailableReport())
    end

    local fight = self:GetCompareFight(fights, data)
    local boss = fight and fight.boss

    -- Fight picker.
    self:Text(parent, "Boss / dungeon:", "GameFontNormalSmall",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 4}, 300, self:UIColor("gray"))
    y = chipGrid(self, parent, y - 22, fights, 208, function(f, point, w, h)
        local tag = (f.type == "M+") and "M+" or "Raid"
        self:FilterButton(parent, f.label .. "  (" .. f.count .. " " .. tag .. ")",
            point, w, h, f.key == (fight and fight.key),
            function()
                MCA.compareFightKey = f.key
                MCA.compareSelection = nil
                MCA.compareDay = nil
                rebuild()
            end)
    end)

    -- Attempt picker for the chosen fight.
    local allCandidates = self:GetComparisonCandidates(boss, fight and fight.groupID)
    local days = self:GetAttemptDays(allCandidates)

    local activeDay
    activeDay, self.compareDay = self:ResolveDayFilter(self.compareDay, days,
        self:CountAttemptsByDay(allCandidates))

    -- Offered only when there is more than one day to tell apart: a single
    -- night needs no filter, and a row of one chip is furniture.
    if #days > 1 then
        self:Text(parent, "Giorno:", "GameFontNormalSmall",
            {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 10}, 300,
            self:UIColor("gray"))
        y = chipGrid(self, parent, y - 28, days, 118, function(day, point, w, h)
            self:FilterButton(parent, day, point, w, h, day == activeDay,
                function()
                    -- Selecting a day drops a selection made on another one,
                    -- which would otherwise stay in the table invisibly.
                    MCA.compareDay = (day ~= activeDay) and day or false
                    MCA.compareSelection = nil
                    rebuild()
                end)
        end)

        if activeDay then
            self:Button(parent, "Tutti i giorni",
                {"TOPLEFT", parent, "TOPLEFT", PAGE_X, y - 8}, 140, 24,
                function() MCA.compareDay = false MCA.compareSelection = nil rebuild() end)
            y = y - 34
        end
    end

    local candidates = allCandidates
    if activeDay then
        candidates = {}
        for _, r in ipairs(allCandidates) do
            if self:GetAttemptDay(r) == activeDay then candidates[#candidates + 1] = r end
        end
    end

    local selection = self:GetCompareSelection(candidates)

    self:Text(parent, "Tentativi da confrontare:", "GameFontNormalSmall",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 10}, 300, self:UIColor("gray"))
    y = chipGrid(self, parent, y - 28, candidates, 104, function(r, point, w, h)
        local on = selection[r.historyID] and true or false
        self:FilterButton(parent, attemptLabel(r),
            point, w, h, on,
            function()
                selection[r.historyID] = (not on) or nil
                rebuild()
            end)
    end)

    local metric = self:GetCompareMetric()
    self:Text(parent, "Metrica:", "GameFontNormalSmall",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 10}, 300, self:UIColor("gray"))
    y = chipGrid(self, parent, y - 28, COMPARE_METRICS, 136, function(m, point, w, h)
        self:FilterButton(parent, m.label, point, w, h, m.key == metric.key,
            function()
                MCA.compareMetric = m.key
                rebuild()
            end)
    end)

    self:Button(parent, "Seleziona tutto",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X, y - 8}, 150, 24,
        function()
            -- Only what the day filter is showing: selecting attempts that are
            -- hidden would put columns in the table with no chip to remove.
            MCA.compareSelection = {}
            for _, r in ipairs(candidates) do
                MCA.compareSelection[r.historyID] = true
            end
            rebuild()
        end)
    self:Button(parent, "Deseleziona tutto",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + 160, y - 8}, 150, 24,
        function() MCA.compareSelection = {} rebuild() end)
    self:Button(parent, "Ultimi 4",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + 320, y - 8}, 110, 24,
        function() MCA.compareSelection = nil rebuild() end)
    y = y - 42

    -- Selected attempts, newest first, capped at what the width can show.
    local attempts, dropped = {}, 0
    for _, r in ipairs(candidates) do
        if selection[r.historyID] then
            if #attempts < COMPARE_MAX_COLUMNS then
                attempts[#attempts + 1] = r
            else
                dropped = dropped + 1
            end
        end
    end

    if #attempts < 2 then
        self:Text(parent, "Selezionane almeno due.", "GameFontNormal",
            {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 6}, 700, self:UIColor("gray"))
        return y - 40
    end

    local nameCol = {x = 10, w = 210}
    local firstX = 230
    local colW = math.max(90, math.floor((PAGE_REF_W - firstX) / #attempts))

    local headers = {{label = "Player", x = nameCol.x, w = nameCol.w}}
    for i, r in ipairs(attempts) do
        headers[#headers + 1] = {
            label = attemptLabel(r),
            x = firstX + (i - 1) * colW, w = colW - 10, justify = "CENTER",
        }
    end

    -- One row per player seen in any selected attempt, ordered by how they did
    -- in the newest one so the table reads top-down like the summary does.
    local seen, names = {}, {}
    for _, r in ipairs(attempts) do
        for _, p in pairs(r.players or {}) do
            if p.name and not seen[p.name] then
                seen[p.name] = true
                names[#names + 1] = p.name
            end
        end
    end

    -- Ordered by the metric on show: sorting a healing comparison by damage
    -- would bury the people it is about.
    local latest = attempts[1].players or {}
    table.sort(names, function(a, b)
        local va = latest[a] and metric.get(self, latest[a]) or 0
        local vb = latest[b] and metric.get(self, latest[b]) or 0
        if va == vb then return a < b end
        return va > vb
    end)

    -- Taken from the most recent attempt a player appears in: the class for
    -- the row's colour, and the row itself as the subject of the charts a
    -- click opens.
    local playerOf = {}
    for i = #attempts, 1, -1 do
        for _, p in pairs(attempts[i].players or {}) do
            if p.name then playerOf[p.name] = p end
        end
    end

    local myName = UnitName("player")

    local rows = {}
    for _, name in ipairs(names) do
        local row = {{x = nameCol.x, w = nameCol.w, text = name, font = "GameFontNormal",
                      color = self:GetClassColor((playerOf[name] or {}).class)}}
        row.highlight = (name == myName)

        -- Opens this player's charts on the fight and group being compared
        -- here, rather than on whatever report happens to be loaded.
        row.onClick = function()
            MCA.selectedPlayer = playerOf[name]
            MCA.playerFightKey = fight.key
            MCA.activeTab = "playerDetail"
            MCA:BuildDashboard(MCA:GetLastAvailableReport())
        end

        for i, r in ipairs(attempts) do
            local p = (r.players or {})[name]

            local text, color = "-", self:UIColor("gray")
            if not p then
                text = "assente"
            else
                local value = metric.get(self, p) or 0
                local prev = attempts[i + 1] and (attempts[i + 1].players or {})[name]
                local prevValue = prev and metric.get(self, prev) or nil

                -- A rate of zero means the metric does not apply to this player
                -- (a healer has no DPS worth showing), so it stays a dash rather
                -- than a misleading 0 sitting at the bottom of the column.
                if metric.kind == "rate" and value <= 0 then
                    text = "-"
                else
                    color = self:UIColor("white")

                    if prevValue then
                        local up
                        if metric.kind == "rate" then
                            -- attempts run newest-first, so the next index is older
                            if prevValue > 0 then
                                if value > prevValue * 1.05 then up = true
                                elseif value < prevValue * 0.95 then up = false end
                            end
                        elseif value ~= prevValue then
                            up = value > prevValue
                        end

                        if up ~= nil then
                            local good = (up and metric.better == 1) or (not up and metric.better == -1)
                            color = good and self:UIColor("green") or self:UIColor("red")
                        end
                    end

                    if metric.kind == "rate" then
                        -- Deaths are their own metric and their own chart. Hung
                        -- off the end of a rate they read as part of it, and a
                        -- column of "141k +2" is harder to scan than the
                        -- figures alone.
                        text = self:FormatMetricValue(value)
                    else
                        text = tostring(math.floor(value))
                    end
                end
            end

            row[#row + 1] = {x = firstX + (i - 1) * colW, w = colW - 10,
                             text = text, color = color, justify = "CENTER"}
        end

        rows[#rows + 1] = row
    end

    y = self:DrawPageTable(parent, headers, rows, y)

    local legend
    if metric.kind == "rate" then
        legend = "Confronto su " .. metric.label .. ". Verde/rosso = variazione oltre il 5% "
            .. "rispetto al tentativo precedente. Le morti sono nella metrica Morti."
    else
        legend = "Confronto su " .. metric.label .. ". Verde/rosso = qualunque variazione "
            .. "rispetto al tentativo precedente"
            .. (metric.better == -1 and " (meno e' meglio)" or "") .. ". \"✖\" = wipe."
    end
    if dropped > 0 then
        legend = legend .. "  (" .. dropped .. " selezionati oltre i " .. COMPARE_MAX_COLUMNS
            .. " visualizzabili non sono mostrati.)"
    end
    self:Text(parent, legend, "GameFontNormalSmall",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 10}, 1000, self:UIColor("gray"))
    return y - 40
end

-- ---------------------------------------------------------------------------
-- Player detail.
--
-- Clicking a player used to open a one-row table restating what the list above
-- already said. What is worth knowing about a player mid-raid is whether this
-- pull went better or worse than the last one, so the page charts their
-- attempts against each other instead.
-- ---------------------------------------------------------------------------

-- Past this the columns are too narrow to label, so the oldest attempts drop
-- off rather than being squeezed.
local PLAYER_CHART_MAX_BARS = 12

-- Damage taken is charted for tanks but deliberately kept out of the
-- comparison tab: no attempt saved before it started being captured carries
-- the figure, so as a column it would be a page of dashes.
--
-- better = 0 means the change is reported without a verdict. Less damage taken
-- is not simply better -- a longer pull takes more -- and painting a survived
-- pull red would be a claim the number cannot support.
local PLAYER_EXTRA_METRICS = {
    {key = "taken", label = "Damage Taken", kind = "rate", better = 0,
     get = function(self, p) return tonumber(p.blizzardDamageTaken or p.damageTaken) or 0 end},
}

-- Which charts each role gets, in the order they are drawn. A healer's damage
-- and a damage dealer's healing are noise, so they are not drawn even when the
-- numbers are there.
local PLAYER_CHART_ROLES = {
    TANK    = {"taken", "dps", "damage", "parse", "deaths"},
    HEALER  = {"hps", "healing", "parse", "deaths"},
    DAMAGER = {"dps", "damage", "parse", "deaths"},
}

local playerChartMetrics = {}
for _, m in ipairs(COMPARE_METRICS) do playerChartMetrics[m.key] = m end
for _, m in ipairs(PLAYER_EXTRA_METRICS) do playerChartMetrics[m.key] = m end

-- Anything without a role, and anyone the client reports as NONE, is charted
-- as a damage dealer.
local function chartsForRole(role)
    return PLAYER_CHART_ROLES[tostring(role or "")] or PLAYER_CHART_ROLES.DAMAGER
end

-- Every saved attempt on this fight in which the player appears, oldest
-- first, so the chart reads left to right in time.
--
-- The caller decides the scope by what it passes as groupID: a raid fight
-- passes its own group, because the same boss with a different raid is not
-- the same measurement, and an M+ dungeon passes the wildcard, because every
-- run of it is a different group by definition. See fightGroupOf.
function MCA:GetPlayerAttempts(playerName, boss, groupID, day)
    if not playerName or not boss then return {} end

    local candidates = self:GetComparisonCandidates(boss, groupID)
    local out = {}
    for i = #candidates, 1, -1 do          -- candidates arrive newest first
        local report = candidates[i]
        local player = (report.players or {})[playerName]
        -- Filtered before the cap below, or a day beyond the newest twelve
        -- attempts would vanish from a chart that is supposed to show it.
        if player and ((not day) or self:GetAttemptDay(report) == day) then
            out[#out + 1] = {report = report, player = player}
        end
    end

    while #out > PLAYER_CHART_MAX_BARS do table.remove(out, 1) end
    return out
end

-- Round gridline values at or below `top`.
--
-- Bars alone give a ratio and nothing else: 86k beside 36k looks the same as
-- 860k beside 360k. A labelled scale is what turns the picture back into
-- quantities.
--
-- The count is biased down by half a line, or a top of 16.7M picks a 10M step
-- and draws one gridline where 5M draws three. `integer` keeps a count metric
-- off fractional steps, which would label a chart topping out at one death
-- with both "0" and "1".
local function niceTicks(top, integer)
    if not top or top <= 0 then return {} end

    local raw = top / 3.5
    local magnitude = 10 ^ math.floor(math.log10(raw))
    local step = 10 * magnitude
    for _, candidate in ipairs({1, 2, 2.5, 5, 10}) do
        if raw <= candidate * magnitude then
            step = candidate * magnitude
            break
        end
    end

    if integer then step = math.max(1, math.floor(step + 0.5)) end

    local ticks, value = {}, step
    while value <= top * 1.001 do
        ticks[#ticks + 1] = value
        value = value + step
    end
    return ticks
end

-- A column chart built from plain textures. WoW has no canvas and no charting
-- widget, and for a dozen pulls sized rectangles are the entire job. The
-- textures belong to the card frame, so they are recycled along with it.
--
-- Beyond the columns it carries a labelled scale and a dashed line at the
-- average of what is shown. The average is the reference the chart used to
-- lack: without it a column says only "taller than the one beside it", and the
-- question is almost always whether a pull was above or below normal.
-- `fixedMax` pins the axis instead of scaling it to the tallest column, and
-- `bandTo` shades everything below a value. Both exist for the parse: it is a
-- percentile, and a percentile scaled to its own maximum is a lie -- a parse of
-- 24 filled the card exactly like a parse of 99.
function MCA:DrawBarChart(parent, x, y, w, h, title, series, formatValue, isCount,
                          fixedMax, bandTo)
    local card = self:Panel(parent, {"TOPLEFT", parent, "TOPLEFT", x, y}, w, h)

    self:Text(card, title, "GameFontNormal",
        {"TOPLEFT", card, "TOPLEFT", 10, -8}, w - 20, self:UIColor("accent"))

    local maxV, sum, counted = fixedMax or 0, 0, 0
    for _, point in ipairs(series) do
        local value = point.value or 0
        if not fixedMax then maxV = math.max(maxV, value) end
        -- Averaged over the attempts that have a figure. A zero is "absent",
        -- or a metric that does not apply to this player; counting it as a
        -- performance of nothing drags the line below every column it is a
        -- reference for.
        if value > 0 then
            sum = sum + value
            counted = counted + 1
        end
    end
    local average = (counted > 0) and (sum / counted) or 0

    -- Room kept left for the scale, above for the title and value labels, and
    -- below for the outcome band and the attempt times.
    local axisW = 40
    local baseline = -(h - 34)
    local plotH = h - 80

    local function yOf(value)
        if maxV <= 0 then return baseline end
        return baseline + math.min(plotH, value / maxV * plotH)
    end

    if bandTo and maxV > 0 then
        local bandTop, bandBottom = yOf(bandTo), yOf(0)
        local band = self:AcquireTexture(card, "BACKGROUND")
        band:SetColorTexture(1, 1, 1, 0.035)
        band:SetPoint("TOPLEFT", card, "TOPLEFT", axisW, bandTop)
        band:SetSize(w - axisW - 10, math.max(1, bandTop - bandBottom))
    end

    for _, tick in ipairs(niceTicks(maxV, isCount)) do
        local gy = yOf(tick)
        local line = self:AcquireTexture(card, "ARTWORK")
        line:SetColorTexture(0.15, 0.16, 0.18, 1)
        line:SetPoint("TOPLEFT", card, "TOPLEFT", axisW, gy)
        line:SetSize(w - axisW - 10, 1)

        self:Text(card, formatValue(tick), "GameFontNormalSmall",
            {"RIGHT", card, "TOPLEFT", axisW - 6, gy + 4}, axisW - 10,
            {0.44, 0.46, 0.49, 1}, "RIGHT")
    end

    local axis = self:AcquireTexture(card, "ARTWORK")
    axis:SetColorTexture(0.30, 0.31, 0.33, 1)
    axis:SetPoint("TOPLEFT", card, "TOPLEFT", axisW, baseline)
    axis:SetSize(w - axisW - 10, 1)

    local slot = (w - axisW - 10) / math.max(#series, 1)
    local barW = math.max(5, math.min(34, slot - 10))

    for i, point in ipairs(series) do
        local value = math.min(point.value or 0, maxV > 0 and maxV or (point.value or 0))
        local barH = math.max(1, yOf(value) - baseline)

        local cx = axisW + (i - 0.5) * slot
        local c = point.color or self:UIColor("blue")

        local bar = self:AcquireTexture(card, "ARTWORK")
        -- The pull open right now is drawn solid and the rest dimmed, so the
        -- one being read is findable without a legend entry per bar.
        bar:SetColorTexture(c[1], c[2], c[3], point.current and 1 or 0.5)
        bar:SetPoint("BOTTOMLEFT", card, "TOPLEFT", cx - barW / 2, baseline + 1)
        bar:SetSize(barW, barH)

        self:Text(card, formatValue(value), "GameFontNormalSmall",
            {"BOTTOM", card, "TOPLEFT", cx, baseline + barH + 3}, slot,
            point.current and self:UIColor("white") or self:UIColor("gray"), "CENTER")

        -- Kill or wipe, as a solid band directly under the column. The colour
        -- of a five-character timestamp is too small a target to read across
        -- six charts; a filled bar the width of the column is not, and the
        -- bands line up into a single row that can be scanned left to right.
        if point.outcome then
            local band = self:AcquireTexture(card, "ARTWORK")
            local o = point.outcome
            band:SetColorTexture(o[1], o[2], o[3], 1)
            band:SetPoint("TOPLEFT", card, "TOPLEFT", cx - barW / 2, baseline - 5)
            band:SetSize(barW, 5)
        end

        self:Text(card, point.label or "", "GameFontNormalSmall",
            {"TOP", card, "TOPLEFT", cx, baseline - 14}, slot,
            self:UIColor("gray"), "CENTER")
    end

    -- Drawn over the columns, and only when more than one attempt has a
    -- figure: the average of a single attempt is that attempt.
    if counted > 1 and average > 0 and not fixedMax then
        local ay = yOf(average)
        local line = self:AcquireTexture(card, "OVERLAY")
        line:SetColorTexture(0.55, 0.57, 0.60, 0.9)
        line:SetPoint("TOPLEFT", card, "TOPLEFT", axisW, ay)
        line:SetSize(w - axisW - 10, 1)

        self:Text(card, "media " .. formatValue(average), "GameFontNormalSmall",
            {"BOTTOMRIGHT", card, "TOPLEFT", w - 12, ay + 2}, 120,
            {0.55, 0.57, 0.60, 1}, "RIGHT")
    end

    return card
end

local function formatClock(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- One row per attempt, from the pull's start to its end, a tick per death.
--
-- The count of deaths is not the story: two pulls of Ula'tek with twenty and
-- twenty-three deaths were a collapse at 1:40 and a seven-minute grind, and
-- the bar chart called the second one worse. The rest of the group is drawn
-- faint behind, because a death on its own says little and a death in the
-- middle of eleven others says what happened.
function MCA:DrawDeathStrip(parent, x, y, w, h, title, strips)
    local card = self:Panel(parent, {"TOPLEFT", parent, "TOPLEFT", x, y}, w, h)

    self:Text(card, title, "GameFontNormal",
        {"TOPLEFT", card, "TOPLEFT", 10, -8}, w - 20, self:UIColor("accent"))

    local axisW, padT, clockW = 40, 30, 46
    local plotW = w - axisW - 14 - clockW
    local rows = math.max(#strips, 1)
    local rowH = math.min(20, (h - padT - 18) / rows)

    -- Rows are as long as the pull was, against the longest one shown.
    -- Normalising each row to its own duration drew a 2:38 wipe and a 7:39 one
    -- at the same width, which hides the very thing the strip exists to show.
    local longest = 1
    for _, strip in ipairs(strips) do
        longest = math.max(longest, tonumber(strip.duration) or 0)
    end

    for index, strip in ipairs(strips) do
        local mid = -(padT + (index - 0.5) * rowH)
        local duration = (tonumber(strip.duration) or 0) > 0 and strip.duration or 1
        local rowW = math.max(6, plotW * duration / longest)

        self:Text(card, strip.label, "GameFontNormalSmall",
            {"RIGHT", card, "TOPLEFT", axisW - 6, mid}, axisW - 10,
            {0.44, 0.46, 0.49, 1}, "RIGHT")

        local line = self:AcquireTexture(card, "ARTWORK")
        line:SetColorTexture(0.15, 0.16, 0.18, 1)
        line:SetPoint("TOPLEFT", card, "TOPLEFT", axisW, mid)
        line:SetSize(rowW, 1)

        local cap = self:AcquireTexture(card, "ARTWORK")
        local o = strip.outcome
        cap:SetColorTexture(o[1], o[2], o[3], 1)
        cap:SetPoint("TOPLEFT", card, "TOPLEFT", axisW + rowW, mid + rowH / 4)
        cap:SetSize(3, math.max(2, rowH / 2))

        local function tick(when, colour, height, alpha)
            local at = math.min(1, math.max(0, when / duration))
            local mark = self:AcquireTexture(card, "OVERLAY")
            mark:SetColorTexture(colour[1], colour[2], colour[3], alpha)
            mark:SetPoint("TOP", card, "TOPLEFT", axisW + at * rowW, mid + height / 2)
            mark:SetSize(2, height)
        end

        for _, when in ipairs(strip.others) do
            tick(when, {0.36, 0.38, 0.41}, math.max(4, rowH * 0.55), 1)
        end
        for _, when in ipairs(strip.own) do
            tick(when, self:UIColor("red"), math.max(6, rowH * 0.9), 1)
        end

        -- Past the end of the row, in the gutter kept for it, so it cannot
        -- sit on top of the deaths that happen as a pull ends.
        self:Text(card, formatClock(duration), "GameFontNormalSmall",
            {"LEFT", card, "TOPLEFT", axisW + rowW + 7, mid}, clockW - 10,
            {0.44, 0.46, 0.49, 1}, "LEFT")
    end

    self:Text(card, "inizio", "GameFontNormalSmall",
        {"TOPLEFT", card, "TOPLEFT", axisW, -(h - 16)}, 60, self:UIColor("gray"))
    self:Text(card, "fine pull", "GameFontNormalSmall",
        {"TOPRIGHT", card, "TOPLEFT", axisW + plotW, -(h - 16)}, 70,
        self:UIColor("gray"), "RIGHT")

    return card
end

-- Damage reads as the player's class colour, healing as healing, and the two
-- counts keep the colours they already carry elsewhere in the window.
local function chartColor(self, metric, player)
    if metric.key == "hps" or metric.key == "healing" then return self:UIColor("green") end
    if metric.key == "parse" then return self:UIColor("purple") end
    if metric.key == "deaths" then return self:UIColor("red") end
    return self:GetClassColor(player and player.class)
end

-- Grey where the metric carries no verdict, so the change is reported without
-- being called an improvement or a regression.
local function verdictCode(metric, delta)
    if (metric.better or 0) == 0 then return "999999" end
    if (delta > 0) == (metric.better > 0) then return "55dd55" end
    return "ff5555"
end

-- The headline each chart exists to answer: better or worse than last pull.
-- Rates carry the same 5% deadband as the comparison table, so ordinary
-- variance is not reported as a trend.
local function chartTrend(metric, series)
    local n = #series
    if n < 2 then return "" end

    local last, prev = series[n].value or 0, series[n - 1].value or 0

    if metric.kind == "rate" then
        if prev <= 0 then return "" end
        local pct = (last - prev) / prev * 100
        if math.abs(pct) < 5 then return "  |cff999999(stabile)|r" end
        return string.format("  |cff%s(%+.0f%% vs prec.)|r",
            verdictCode(metric, pct), pct)
    end

    local diff = last - prev
    if diff == 0 then return "  |cff999999(invariato)|r" end
    return string.format("  |cff%s(%+d vs prec.)|r", verdictCode(metric, diff), diff)
end

-- Fights this player actually took part in: one entry per boss and raid
-- group, keyed and labelled the way the comparison tab does it, newest first.
--
-- Built from the player rather than from the open report, which is what lets
-- the page work standing in a city: the question "how am I doing on this boss
-- with this group" does not depend on which report happens to be loaded.
function MCA:GetPlayerFights(playerName)
    if not playerName then return {} end

    local history = self.GetHistory and self:GetHistory() or (RaidPulseDB.history or {})
    local byKey, order, bossCounts = {}, {}, {}

    for _, r in ipairs(history) do
        if r and r.boss and r.boss ~= "" and r.historyID and (r.players or {})[playerName] then
            local groupID = fightGroupOf(r)
            local key = fightKeyFor(r)

            local entry = byKey[key]
            if not entry then
                entry = {key = key, boss = r.boss, groupID = groupID, type = r.type,
                         count = 0, latest = 0, groupStartedAt = r.groupStartedAt}
                byKey[key] = entry
                order[#order + 1] = entry
                bossCounts[r.boss] = (bossCounts[r.boss] or 0) + 1
            end
            entry.count = entry.count + 1
            entry.latest = math.max(entry.latest, tonumber(r.savedAtEpoch) or 0)
        end
    end

    table.sort(order, function(a, b) return a.latest > b.latest end)

    -- Only say which group when the same fight appears under more than one,
    -- otherwise every chip carries a date nobody needs to read.
    for _, entry in ipairs(order) do
        entry.label = entry.boss
        if (bossCounts[entry.boss] or 0) > 1 then
            local when = entry.groupStartedAt or entry.latest
            local stamp = (when and when > 0 and date and date("%d/%m %H:%M", when)) or "gruppo prec."
            entry.label = entry.boss .. " - " .. stamp
        end
    end

    return order
end

-- What the web export can be pointed at, grouped the way the page groups it:
-- a raid night by its group, a dungeon by its name. Newest first.
--
-- The same split as fightGroupOf, built here over whole containers rather than
-- single fights, because the export addresses a night and not a boss.
-- `day`, when given, is the only day counted: every figure on a row has to
-- describe what the command next to it will actually export. Without it a row
-- read "4 run" while the command, narrowed to one day, wrote a page with one.
function MCA:GetExportGroups(day)
    local history = self.GetHistory and self:GetHistory() or (RaidPulseDB.history or {})
    local byKey, order = {}, {}

    for _, r in ipairs(history) do
        local sameDay = (not day) or (self:GetAttemptDay(r) == day)
        if sameDay and r and r.boss and r.boss ~= "" and r.historyID then
            local isMplus = (r.type or "") == "M+"
            local key = isMplus and ("mplus::" .. r.boss)
                or ("raid::" .. tostring(r.groupID or "legacy"))

            local entry = byKey[key]
            if not entry then
                entry = {
                    key = key,
                    kind = isMplus and "M+" or "raid",
                    selector = isMplus and r.boss or tostring(r.groupID or "legacy"),
                    bossOrder = {}, bossCount = {}, players = {},
                    count = 0, kills = 0, first = 0, latest = 0,
                    keyMin = nil, keyMax = nil,
                    days = {}, daySeen = {},
                }
                byKey[key] = entry
                order[#order + 1] = entry
            end

            entry.count = entry.count + 1
            if r.result then entry.kills = entry.kills + 1 end

            -- The key level is what actually varies between runs of one
            -- dungeon; how many distinct people were in them does not mean
            -- anything, since a key is five players and every one is a
            -- different five.
            local level = tonumber(tostring(r.difficulty or ""):match("^%+(%d+)$"))
            if level then
                entry.keyMin = math.min(entry.keyMin or level, level)
                entry.keyMax = math.max(entry.keyMax or level, level)
            end

            local epoch = tonumber(r.savedAtEpoch) or 0
            if epoch > 0 then
                if entry.first == 0 or epoch < entry.first then entry.first = epoch end
                if epoch > entry.latest then entry.latest = epoch end
            end

            -- A raid group can run past midnight, so a night is not always one
            -- calendar day and the export has to be able to say which.
            local day = self:GetAttemptDay(r)
            if day and not entry.daySeen[day] then
                entry.daySeen[day] = true
                entry.days[#entry.days + 1] = day
            end

            if not entry.bossCount[r.boss] then
                entry.bossOrder[#entry.bossOrder + 1] = r.boss
                entry.bossCount[r.boss] = 0
            end
            entry.bossCount[r.boss] = entry.bossCount[r.boss] + 1

            for _, p in pairs(r.players or {}) do
                if p.name then entry.players[p.name] = true end
            end
        end
    end

    for _, entry in ipairs(order) do
        entry.playerCount = 0
        for _ in pairs(entry.players) do entry.playerCount = entry.playerCount + 1 end

        if entry.kind == "M+" then
            entry.label = entry.bossOrder[1] or "?"
        else
            local names = {}
            for i = 1, math.min(#entry.bossOrder, 2) do names[i] = entry.bossOrder[i] end
            if #entry.bossOrder > 2 then
                names[#names + 1] = "+" .. (#entry.bossOrder - 2)
            end
            entry.label = table.concat(names, ", ")
        end

        entry.stamp = "?"
        if entry.first > 0 and date then
            entry.stamp = date("%d/%m %H:%M", entry.first)
            if entry.latest > entry.first then
                -- The date on both ends when they fall on different days: a
                -- raid that ran to 00:03 read as "21:37 - 00:03" on one date,
                -- which is a night that looks like it went backwards.
                local sameDay = date("%d/%m", entry.first) == date("%d/%m", entry.latest)
                entry.stamp = entry.stamp .. " - "
                    .. date(sameDay and "%H:%M" or "%d/%m %H:%M", entry.latest)
            end
        end
    end

    table.sort(order, function(a, b) return a.latest > b.latest end)
    return order
end

-- Every day the history covers, newest first, for the export day filter.
function MCA:GetExportDays()
    local seen, days = {}, {}
    local history = self.GetHistory and self:GetHistory() or (RaidPulseDB.history or {})

    for i = #history, 1, -1 do
        local day = self:GetAttemptDay(history[i])
        if day and not seen[day] then
            seen[day] = true
            days[#days + 1] = day
        end
    end
    return days
end

-- The group a report belongs to, so the window opens on it.
function MCA:GetExportGroupKey(data)
    if not data or not data.boss then return nil end
    if (data.type or "") == "M+" then return "mplus::" .. data.boss end
    return "raid::" .. tostring(data.groupID or "legacy")
end

-- Every day this player has attempts on this fight, newest first. Read from
-- the candidates rather than from GetPlayerAttempts, which is capped at twelve
-- columns and would hide the older days entirely.
function MCA:GetPlayerDays(playerName, boss, groupID)
    local seen, days = {}, {}
    for _, r in ipairs(self:GetComparisonCandidates(boss, groupID)) do
        if (r.players or {})[playerName] then
            local day = self:GetAttemptDay(r)
            if day and not seen[day] then
                seen[day] = true
                days[#days + 1] = day
            end
        end
    end
    return days
end

-- Prefers an explicit pick, then the fight of whatever report is open, then
-- the most recent -- so the page always lands on something.
function MCA:GetPlayerFight(fights, data)
    for _, f in ipairs(fights) do
        if f.key == self.playerFightKey then return f end
    end

    if data and data.boss then
        local wanted = fightKeyFor(data)
        for _, f in ipairs(fights) do
            if f.key == wanted then
                self.playerFightKey = f.key
                return f
            end
        end
    end

    self.playerFightKey = fights[1] and fights[1].key
    return fights[1]
end

-- The logged-in character as a player row. A saved attempt is preferred over
-- asking the client, so class and role read the same here as in the charts;
-- the client is only consulted for a character with nothing recorded yet.
function MCA:GetSelfPlayer(data)
    local name = UnitName("player")
    if not name then return nil end

    if data and (data.players or {})[name] then return data.players[name] end

    local history = self.GetHistory and self:GetHistory() or (RaidPulseDB.history or {})
    for i = #history, 1, -1 do
        local p = (history[i].players or {})[name]
        if p then return p end
    end

    local _, class = UnitClass("player")
    return {name = name, class = class,
            role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player") or "DAMAGER"}
end

-- What the history actually holds, grouped exactly the way the charts group
-- it. "Only one pull saved here" has two very different causes -- one run
-- really was recorded, or several were recorded and are not being matched --
-- and nothing in the window told them apart.
function MCA:ReportHistoryState()
    local history = self.GetHistory and self:GetHistory() or (RaidPulseDB.history or {})
    local me = UnitName("player")

    self:Print(string.format("Storico: %d report salvati. Io sono '%s'.",
        #history, tostring(me)))

    local byKey, order = {}, {}
    for _, r in ipairs(history) do
        local key = fightKeyFor(r)
        local entry = byKey[key]
        if not entry then
            entry = {key = key, boss = r.boss, type = r.type, total = 0, mine = 0, latest = 0}
            byKey[key] = entry
            order[#order + 1] = entry
        end
        entry.total = entry.total + 1
        if (r.players or {})[me] then entry.mine = entry.mine + 1 end
        entry.latest = math.max(entry.latest, tonumber(r.savedAtEpoch) or 0)
    end

    table.sort(order, function(a, b) return a.latest > b.latest end)

    for _, entry in ipairs(order) do
        self:Print(string.format("  %s [%s] %d salvati, %d con me, ultimo %s  (key %s)",
            tostring(entry.boss), tostring(entry.type or "?"),
            entry.total, entry.mine,
            (entry.latest > 0 and date and date("%d/%m %H:%M", entry.latest)) or "?",
            entry.key))
    end

    if #order == 0 then
        self:Print("  Nessun report nello storico.")
    end
end

function MCA:DrawPlayerCharts(parent, data, y)
    -- The tab is the logged-in character's own page. Clicking someone else in
    -- the Riepilogo tables opens the same page for them instead.
    local sel = (self.activeTab == "playerDetail" and self.selectedPlayer)
        or self:GetSelfPlayer(data)

    if not sel or not sel.name then
        self:Text(parent, "Nessun personaggio da mostrare.", "GameFontNormal",
            {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 6}, 700,
            self:UIColor("gray"))
        return y - 40
    end

    self:Text(parent, sel.name, "GameFontHighlightLarge",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 420,
        self:GetClassColor(sel.class))
    y = y - 22

    self:Text(parent, string.format("%s - %s",
            self:PrettyClass(sel.class), self:RoleShort(sel.role)),
        "GameFontNormalSmall",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y}, PAGE_W - 20,
        self:UIColor("gray"))
    y = y - 28

    local fights = self:GetPlayerFights(sel.name)
    if #fights == 0 then
        self:Text(parent, "Nessun pull salvato per questo personaggio.", "GameFontNormal",
            {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 6}, PAGE_W - 20,
            self:UIColor("gray"))
        return y - 44
    end

    local fight = self:GetPlayerFight(fights, data)

    self:Text(parent, "Raid / dungeon:", "GameFontNormalSmall",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 300, self:UIColor("gray"))
    y = chipGrid(self, parent, y - 20, fights, 232, function(f, point, w, h)
        local tag = (f.type == "M+") and "M+" or "Raid"
        self:FilterButton(parent, f.label .. "  (" .. f.count .. " " .. tag .. ")",
            point, w, h, f.key == fight.key,
            function()
                MCA.playerFightKey = f.key
                MCA.playerDay = nil          -- a new fight decides its day again
                MCA:BuildDashboard(MCA:GetLastAvailableReport())
            end)
    end)
    y = y - 12

    local days = self:GetPlayerDays(sel.name, fight.boss, fight.groupID)
    local activeDay
    activeDay, self.playerDay = self:ResolveDayFilter(self.playerDay, days,
        self:CountAttemptsByDay(self:GetPlayerAttempts(sel.name, fight.boss,
            fight.groupID)))

    -- Offered only when there is more than one day to tell apart: a single
    -- night needs no filter, and a row of one chip is furniture.
    if #days > 1 then
        self:Text(parent, "Giorno:", "GameFontNormalSmall",
            {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 4}, 300,
            self:UIColor("gray"))
        y = chipGrid(self, parent, y - 22, days, 118, function(day, point, w, h)
            self:FilterButton(parent, day, point, w, h, day == activeDay,
                function()
                    MCA.playerDay = (day ~= activeDay) and day or false
                    MCA:BuildDashboard(MCA:GetLastAvailableReport())
                end)
        end)

        if activeDay then
            self:Button(parent, "Tutti i giorni",
                {"TOPLEFT", parent, "TOPLEFT", PAGE_X, y - 8}, 140, 24,
                function()
                    MCA.playerDay = false
                    MCA:BuildDashboard(MCA:GetLastAvailableReport())
                end)
            y = y - 34
        end
    end

    local attempts = self:GetPlayerAttempts(sel.name, fight.boss, fight.groupID, activeDay)

    if #attempts < 2 then
        -- The two scopes need two different explanations. Telling someone
        -- their key needs "the same group" would be wrong now: M+ runs are
        -- charted together across groups and key levels.
        local why
        if activeDay then
            why = "Un solo tentativo il " .. activeDay .. ". Scegli un altro giorno "
                .. "o premi Tutti i giorni per confrontarli tutti."
        elseif fight.type == "M+" then
            why = "Una sola run salvata per questa dungeon. Le run della stessa M+ "
                .. "vengono confrontate tutte insieme, con qualunque gruppo e a "
                .. "qualunque livello di chiave: serve una seconda run. "
                .. "Usa /rp hist per vedere cosa c'e' nello storico."
        else
            why = "Un solo pull salvato qui. Serve un secondo tentativo sullo stesso "
                .. "boss con lo stesso gruppo perche' ci sia qualcosa da confrontare: "
                .. "i pull di un altro gruppo raid restano separati apposta, non sono "
                .. "la stessa misura."
        end

        self:Text(parent, why, "GameFontNormal",
            {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 6}, PAGE_W - 20,
            self:UIColor("gray"))
        return y - 60
    end

    local cols, gapX, gapY, chartH = 2, 14, 14, 200
    local chartW = math.floor((PAGE_W - 2 * PAGE_PAD - gapX) / cols)
    local top, drawn = y, 0

    for _, key in ipairs(chartsForRole(sel.role)) do
        local metric = playerChartMetrics[key]
        local series, maxV = {}, 0

        for _, attempt in ipairs(attempts) do
            local value = tonumber(metric.get(self, attempt.player)) or 0
            maxV = math.max(maxV, value)
            series[#series + 1] = {
                label = attemptLabel(attempt.report),
                outcome = outcomeColor(attempt.report),
                value = value,
                color = chartColor(self, metric, sel),
                -- "the pull open now", which only means anything while the
                -- chosen fight is the one the open report belongs to.
                current = (data.historyID ~= nil and attempt.report.historyID == data.historyID)
                    or attempt.report == data,
            }
        end

        -- Drawn even when there is nothing in it. These are the charts the role
        -- is meant to have, so a missing one has to say so rather than leaving
        -- a hole in the grid: damage taken in particular is absent from every
        -- attempt saved before it started being captured. Deaths are exempt --
        -- there, all zeroes is the answer, not a gap.
        local note = chartTrend(metric, series)
        if maxV <= 0 and metric.key ~= "deaths" then
            note = "  |cff999999(non rilevato)|r"
        end

        local formatValue
        if metric.kind == "rate" then
            formatValue = function(v) return MCA:FormatMetricValue(v) end
        else
            formatValue = function(v) return tostring(math.floor(v or 0)) end
        end

        local cardX = PAGE_X + PAGE_PAD + (drawn % cols) * (chartW + gapX)
        local cardY = top - math.floor(drawn / cols) * (chartH + gapY)

        if metric.key == "deaths" then
            -- Where in the pull, not how many.
            local strips, mine = {}, 0
            for _, attempt in ipairs(attempts) do
                local own, others = {}, {}
                for _, row in pairs(attempt.report.players or {}) do
                    local when = tonumber(row.deathTime) or 0
                    if when > 0 then
                        if row.name == sel.name then
                            own[#own + 1] = when
                        else
                            others[#others + 1] = when
                        end
                    end
                end
                mine = mine + #own
                strips[#strips + 1] = {
                    label = attemptLabel(attempt.report),
                    duration = tonumber(attempt.report.duration) or 0,
                    own = own, others = others,
                    outcome = outcomeColor(attempt.report),
                }
            end

            self:DrawDeathStrip(parent, cardX, cardY, chartW, chartH,
                string.format("%s  |cff999999(%d in %d pull)|r",
                    metric.label, mine, #strips),
                strips)
        elseif metric.key == "parse" then
            -- 0..100 fixed, with everything below the median shaded.
            self:DrawBarChart(parent, cardX, cardY, chartW, chartH,
                metric.label .. note, series, formatValue, true, 100, 50)
        else
            self:DrawBarChart(parent, cardX, cardY, chartW, chartH,
                metric.label .. note, series, formatValue,
                metric.kind == "count")
        end
        drawn = drawn + 1
    end

    y = top - math.ceil(drawn / cols) * (chartH + gapY)

    self:Text(parent,
        "Fascia sotto la colonna: verde = kill, rossa = wipe. "
        .. "Colonna a piena tinta = il pull aperto ora.",
        "GameFontNormalSmall",
        {"TOPLEFT", parent, "TOPLEFT", PAGE_X + PAGE_PAD, y - 6}, PAGE_W - 20,
        self:UIColor("gray"))
    return y - 36
end

function MCA:DrawFullPage(root, data)
    local _, child, scroll = self:Scroll(root, {"TOPLEFT", root, "TOPLEFT", CONTENT_X, BODY_Y}, CONTENT_W, BODY_H, {0.018,0.020,0.022,0.65})

    local titleMap = {summary="Riepilogo", players="Player", playerDetail="Player", deaths="Deaths", buffs="Buff Raid", interrupts="Interrupt", timeline="Timeline", history="Storico", compare="Compare", settings="Impostazioni"}
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
        local function sectionHeader(title)
            self:Text(child, title, "GameFontHighlightLarge",
                {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 400, self:UIColor("accent"))
            y = y - 30
        end

        sectionHeader("Grafica")

        local w, h = self:GetWindowSize()
        local sizeLabel = self:Text(child,
            string.format("Dimensione finestra: %d%%  (%dx%d)",
                math.floor(self:GetWindowShare() * 100 + 0.5), w, h),
            "GameFontNormal", {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 420,
            self:UIColor("white"))
        y = y - 26

        local minPct = math.ceil(self:GetMinWindowShare() * 100)
        local curPct = math.min(100, math.max(minPct,
            math.floor(self:GetWindowShare() * 100 + 0.5)))

        self:Slider(child, {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 320,
            minPct, 100, curPct,
            function(pct)
                -- Live: the window grows as the thumb moves.
                local nw, nh = MCA:PreviewWindowShare(pct / 100)
                sizeLabel:SetText(string.format("Dimensione finestra: %d%%  (%dx%d)", pct, nw, nh))
            end,
            function(pct)
                -- On release: reflow the contents at the new measurements.
                MCA:SetWindowShare(pct / 100)
            end)
        y = y - 20

        -- The track starts at the minimum, not at zero, so a thumb sitting
        -- hard left means "as small as it goes" rather than "stuck". Without
        -- the two end labels that reads as a bug.
        self:Text(child, minPct .. "%", "GameFontNormalSmall",
            {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 60, self:UIColor("gray"))
        self:Text(child, "100%", "GameFontNormalSmall",
            {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD + 260, y}, 60,
            self:UIColor("gray"), "RIGHT")
        y = y - 22

        local sw, sh = self:GetScreenUnits()
        local screenStr = (sw and sh) and string.format("%dx%d unita'", sw, sh)
            or "dimensione sconosciuta"

        local hint
        if minPct >= 99 then
            -- Saying "40%-100%" here would be a lie: everything below the
            -- floor clamps to the same window, so the cursor would look broken.
            hint = string.format(
                "Le tabelle richiedono almeno %dx%d e il tuo schermo e' %s, "
                .. "quindi il cursore ha poco margine.",
                WINDOW_MIN_W, WINDOW_MIN_H, screenStr)
        else
            hint = string.format(
                "Il minimo e' %d%% (%dx%d): sotto quella misura le colonne delle tabelle "
                .. "verrebbero tagliate. Schermo: %s. La finestra cresce dall'angolo in "
                .. "alto a sinistra e il contenuto si riadatta quando rilasci.",
                minPct, WINDOW_MIN_W, WINDOW_MIN_H, screenStr)
        end

        self:Text(child, hint, "GameFontNormalSmall",
            {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 620,
            self:UIColor("gray"))
        y = y - 56

        sectionHeader("Tasti rapidi")

        for _, action in ipairs(MCA.KEYBIND_ACTIONS or {}) do
            local bound = self:GetKeybind(action.key)
            local capturing = (self.keybindCapturing == action.key)

            self:Text(child, action.label, "GameFontNormal",
                {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 240,
                self:UIColor("white"))

            local keyText, keyColor
            if capturing then
                keyText, keyColor = "Premi un tasto (ESC annulla)", self:UIColor("accent")
            elseif bound then
                keyText, keyColor = bound, self:UIColor("green")
            else
                keyText, keyColor = "non assegnato", self:UIColor("gray")
            end
            self:Text(child, keyText, "GameFontNormal",
                {"TOPLEFT", child, "TOPLEFT", 270, y}, 200, keyColor)

            if capturing then
                self:Button(child, "Annulla", {"TOPLEFT", child, "TOPLEFT", 490, y + 4}, 110, 22,
                    function()
                        MCA:StopKeybindCapture()
                        MCA:BuildDashboard(data)
                    end)
            else
                self:Button(child, "Imposta", {"TOPLEFT", child, "TOPLEFT", 490, y + 4}, 110, 22,
                    function()
                        MCA:StartKeybindCapture(action.key)
                        MCA:BuildDashboard(data)
                    end)
                if bound then
                    self:Button(child, "Rimuovi", {"TOPLEFT", child, "TOPLEFT", 610, y + 4}, 110, 22,
                        function()
                            MCA:ClearKeybind(action.key)
                            MCA:BuildDashboard(data)
                        end)
                end
            end

            y = y - 30
        end

        self:Text(child,
            "I tasti valgono per la sessione e vengono riassegnati a ogni login: RaidPulse "
            .. "non scrive nei keybind del personaggio, quindi disattivarlo non lascia nulla "
            .. "indietro. Un tasto gia' occupato viene preso da RaidPulse finche' resta "
            .. "assegnato qui, e la chat dice cosa sostituisce.",
            "GameFontNormalSmall",
            {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD, y - 4}, 620,
            self:UIColor("gray"))
        y = y - 56

        sectionHeader("Report")

        local settings = {
            {"Debug", "debug"},
            {"ElvUI Skin", "useElvUISkin"},
            {"Auto Open", "autoOpen"},
            {"Show Kill", "showAfterKill"},
            {"Show Wipe", "showAfterWipe"},
            {"Show M+ End", "showMythicEnd"}
        }

        for _, sett in ipairs(settings) do
            self:Text(child, sett[1]..": "..(RaidPulseDB.config[sett[2]] and "ON" or "OFF"), "GameFontNormal", {"TOPLEFT", child, "TOPLEFT", PAGE_X + PAGE_PAD, y}, 200, RaidPulseDB.config[sett[2]] and self:UIColor("green") or self:UIColor("red"))
            self:Button(child, "Toggle", {"TOPLEFT", child, "TOPLEFT", 240, y+4}, 90, 22, function()
                RaidPulseDB.config[sett[2]] = not RaidPulseDB.config[sett[2]]
                MCA:BuildDashboard(data)
            end)
            y = y - 36
        end

    elseif self.activeTab == "players" or self.activeTab == "playerDetail" then
        y = self:DrawPlayerCharts(child, data, y)

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
        -- BackdropTemplate: SetBackdropSolid below needs the mixin it carries.
        local row = self:AcquireFrame("Frame", box, "BackdropTemplate")
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
