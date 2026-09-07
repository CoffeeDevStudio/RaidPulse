-- RaidPulse — keyboard shortcuts
--
-- The windows on the minimap menu, minus Export and Share: both act on the
-- last report and post or open a text box, which is a deliberate click rather
-- than something to hit by reflex.
--
-- Bindings are applied to the running session with SetBindingClick and are
-- never written to the character's binding file: RaidPulseDB is the source of
-- truth and they are reapplied at every login. That way the addon cannot leave
-- anything behind in the user's own keybinds if it is disabled or removed.

_G.MCA = _G.MCA or {}
MCA = _G.MCA

MCA.KEYBIND_ACTIONS = {
    {
        key = "toggle",
        label = "Apri/chiudi RaidPulse",
        run = function()
            -- A key is a toggle. The minimap entry only opens, because there
            -- the window is in front of you when you click it anyway.
            if _G.MCAFrame and _G.MCAFrame:IsShown() then
                _G.MCAFrame:Hide()
            elseif MCA.ShowUI then
                MCA:ShowUI(MCA:GetLastAvailableReport())
            end
        end,
    },
    {
        key = "buffs",
        label = "Raid Buff Check",
        run = function()
            if MCA.ShowRaidBuffWindow then MCA:ShowRaidBuffWindow() end
        end,
    },
    {
        key = "history",
        label = "Storico",
        run = function()
            MCA.activeTab = "history"
            if MCA.ShowUI then MCA:ShowUI(MCA:GetLastAvailableReport()) end
        end,
    },
}

-- Pressing a modifier on its own is not a binding, it is the first half of one.
local MODIFIER_KEYS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, UNKNOWN = true,
}

local function buttonNameFor(action)
    return "RaidPulseBind_" .. action.key
end

-- One hidden button per action. SetBindingClick can only point a key at a
-- named button, so these exist to be clicked and are never drawn.
local function bindButton(action)
    local name = buttonNameFor(action)
    local button = _G[name]
    if not button then
        button = CreateFrame("Button", name, UIParent)
        -- Kept shown but parked off screen with no size and no textures: a
        -- CLICK binding aimed at a hidden button is not reliably delivered,
        -- and there is nothing here to draw or to catch a stray mouse click.
        button:SetSize(1, 1)
        button:ClearAllPoints()
        button:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -50, -50)
        button:RegisterForClicks("AnyUp")   -- act on release, so a held key fires once
        button:SetScript("OnClick", function()
            local ok, err = pcall(action.run)
            if not ok then MCA:Print("Keybind '" .. action.label .. "': " .. tostring(err)) end
        end)
    end
    return button
end

function MCA:GetKeybinds()
    RaidPulseDB.config = RaidPulseDB.config or {}
    RaidPulseDB.config.keybinds = RaidPulseDB.config.keybinds or {}
    return RaidPulseDB.config.keybinds
end

function MCA:GetKeybind(actionKey)
    local bound = self:GetKeybinds()[actionKey]
    if bound == "" then return nil end
    return bound
end

-- What the key does today, if it is not already ours. Answers "am I about to
-- take this key away from something" before the binding is set rather than
-- after the user notices their bags stopped opening.
function MCA:DescribeBindingConflict(key)
    if not key or key == "" or not GetBindingAction then return nil end

    local action = GetBindingAction(key)
    if not action or action == "" then return nil end
    if action:find("^CLICK RaidPulseBind_") then return nil end

    return _G["BINDING_NAME_" .. action] or action
end

-- Applied to the running session only. Combat forbids SetBinding outright, so
-- a change made mid-pull is held and applied when combat drops.
function MCA:ApplyKeybinds()
    if InCombatLockdown and InCombatLockdown() then
        self.keybindsPending = true
        return
    end
    self.keybindsPending = nil

    local saved = self:GetKeybinds()

    for _, action in ipairs(self.KEYBIND_ACTIONS) do
        local button = bindButton(action)
        local command = "CLICK " .. buttonNameFor(action) .. ":LeftButton"

        -- Whatever we set last time goes first: without this, changing a key
        -- would leave the old one still firing.
        local old = {GetBindingKey(command)}
        for _, oldKey in ipairs(old) do
            SetBinding(oldKey, nil)
        end

        local key = saved[action.key]
        if key and key ~= "" then
            if not SetBindingClick(key, buttonNameFor(action)) then
                self:Print("Tasto rifiutato dal client: " .. tostring(key))
            end
        end
    end
end

function MCA:SetKeybind(actionKey, key)
    self:GetKeybinds()[actionKey] = key
    self:ApplyKeybinds()
end

function MCA:ClearKeybind(actionKey)
    self:SetKeybind(actionKey, nil)
end

-- The frame that reads the next key. It is shown, sized to nothing and
-- keyboard-enabled, which is what makes it swallow the keypress instead of
-- letting it reach the game.
--
-- SetPropagateKeyboardInput is deliberately not used: it is protected in
-- combat and raised "action blocked" the last time this addon touched it.
-- Refusing to capture in combat covers the same ground without the API.
local captureFrame

local function keyChord(key)
    local prefix = ""
    if IsAltKeyDown() then prefix = prefix .. "ALT-" end
    if IsControlKeyDown() then prefix = prefix .. "CTRL-" end
    if IsShiftKeyDown() then prefix = prefix .. "SHIFT-" end
    return prefix .. key
end

function MCA:StopKeybindCapture()
    self.keybindCapturing = nil
    if captureFrame then captureFrame:Hide() end
end

function MCA:StartKeybindCapture(actionKey)
    if InCombatLockdown and InCombatLockdown() then
        self:Print("Non posso cambiare i tasti in combattimento.")
        return
    end

    if not captureFrame then
        captureFrame = CreateFrame("Frame", nil, UIParent)
        captureFrame:SetSize(1, 1)
        captureFrame:SetPoint("CENTER")
        -- Above the report window, which sits at DIALOG: keys go to the
        -- highest keyboard-enabled frame, and ESC has to reach this before it
        -- reaches the window's own close-on-escape.
        captureFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        captureFrame:EnableKeyboard(true)
        captureFrame:Hide()

        captureFrame:SetScript("OnKeyDown", function(_, key)
            local pending = MCA.keybindCapturing
            if not pending then return end

            -- A modifier on its own is the first half of a chord, so keep
            -- waiting. Ending the capture here would make CTRL-R impossible to
            -- assign: the Ctrl press would close it before the R ever arrived.
            if MODIFIER_KEYS[key] then return end

            MCA:StopKeybindCapture()

            if key == "ESCAPE" then
                MCA:Print("Assegnazione annullata.")
            else
                local chord = keyChord(key)
                local taken = MCA:DescribeBindingConflict(chord)
                MCA:SetKeybind(pending, chord)
                if taken then
                    MCA:Print(chord .. " era assegnato a '" .. taken
                        .. "': in questa sessione risponde a RaidPulse.")
                end
            end

            if _G.MCAFrame and _G.MCAFrame:IsShown() and MCA.BuildDashboard then
                MCA:BuildDashboard(MCA:GetLastAvailableReport())
            end
        end)
    end

    self.keybindCapturing = actionKey
    captureFrame:Show()
end
