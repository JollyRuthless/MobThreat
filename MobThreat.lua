-- Mob Threat: shows YOUR threat on every enemy nameplate.
-- The number is how close you are to pulling that mob (100% = it comes for you).
--
-- Minimap button: left-click settings, right-click aggro list, drag to move
-- /mobthreat opens settings; "/mobthreat list" aggro list; "/mobthreat test" readout
--
-- Forever hands threat to addons as a "secret" value: the addon can't read it,
-- compare it, or do math on it. It can only pass it back to the game to draw.
-- So everything below passes the number through untouched.

local addonName, ns = ...   -- shared with Glow.lua

-- Settings you can change
local UPDATE_EVERY = 0.2      -- seconds between refreshes
local X_OFFSET     = 2        -- gap to the right of the nameplate
local MIN_SIZE     = 8
local MAX_SIZE     = 32
local DEFAULT_SIZE = 12

local labels = {}   -- nameplate frame -> our text
local active = {}   -- unit token ("nameplate3") -> true while its plate is shown
local lastColorMode = "none yet"
local curveSetupError = "none"
curveError = "none"          -- why the smooth fade failed, if it did
statusColorError = "none"    -- why the four-color backup failed, if it did

local function FontSize()
    return (MobThreatDB and MobThreatDB.size) or DEFAULT_SIZE
end

---------------------------------------------------------------------------
-- Color: green up to 51%, then fading through yellow to red at 100%.
-- This uses a "color curve": we give the game the color points, and the
-- game itself works out the color from the hidden number.
---------------------------------------------------------------------------
local curve
local curveOk, curveSetupErr = pcall(function()
    curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    curve:AddPoint(0,   CreateColor(0.2, 1.0, 0.2))   -- green
    curve:AddPoint(51,  CreateColor(0.2, 1.0, 0.2))   -- still green
    curve:AddPoint(75,  CreateColor(1.0, 1.0, 0.0))   -- yellow
    curve:AddPoint(100, CreateColor(1.0, 0.1, 0.1))   -- red
end)
if not curveOk then
    curve = nil
    curveSetupError = tostring(curveSetupErr)
end

local function ApplyColor(fs, status, pct)
    fs:SetTextColor(1, 1, 1)

    -- First choice: smooth green-to-red curve
    if curve then
        local ok, err = pcall(function()
            local c = curve:Evaluate(pct)
            fs:SetTextColor(c:GetRGB())
        end)
        if ok then
            lastColorMode = "smooth curve"
            return
        end
        curveError = tostring(err)
    end

    -- Backup: the game's own four threat colors
    local ok, err = pcall(function()
        local r, g, b = GetThreatStatusColor(status)
        fs:SetTextColor(r, g, b)
    end)
    if not ok then statusColorError = tostring(err) end
    if ok then
        lastColorMode = "game's threat colors (no smooth curve)"
    else
        fs:SetTextColor(1, 1, 1)
        lastColorMode = "white (game blocked color)"
    end
end

---------------------------------------------------------------------------
-- Nameplate text
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Threat bar: sits behind the mob's name, in the strip just above the
-- health bar, so the name reads on top of it. The number sits to its right.
-- The bar's picture is a fixed stripe, green up to 51%, yellow at 75%,
-- red at 100%. The bar only uncovers as much of the stripe as your threat,
-- so the color at the tip of the bar shows how close you are to pulling.
-- The game lets addons fill bars with hidden values, so this works where
-- coloring the number doesn't.
---------------------------------------------------------------------------
local BAR_TEXTURE = "Interface\\AddOns\\MobThreat\\ThreatBar"
local BAR_HEIGHT  = 14      -- height of the strip behind the name
local BAR_GAP     = 1       -- gap between the strip and the health bar
local BAR_ALPHA   = 0.85    -- lower this if the name is hard to read
local NUMBER_PAD  = 20       -- space between the name (or bar) and the % number
local bars = {}     -- nameplate frame -> bar

-- Find the game's health bar on a nameplate. Frame names here are a guess
-- for Forever, so this tries the usual ones and falls back to the plate.
local function FindHealthBar(plate)
    local uf = plate.UnitFrame
    if uf then
        return uf.healthBar or uf.HealthBar or uf.healthbar, uf
    end
    return nil, nil
end

local function GetLabel(plate)
    local fs = labels[plate]
    if not fs then
        local health, uf = FindHealthBar(plate)

        local bar = CreateFrame("StatusBar", nil, plate)
        bar:SetHeight(BAR_HEIGHT)
        if health then
            bar:SetPoint("BOTTOMLEFT", health, "TOPLEFT", 0, BAR_GAP)
            bar:SetPoint("BOTTOMRIGHT", health, "TOPRIGHT", 0, BAR_GAP)
        else
            bar:SetPoint("TOPLEFT", plate, "TOPLEFT", 0, 0)
            bar:SetPoint("TOPRIGHT", plate, "TOPRIGHT", 0, 0)
        end

        -- Draw the bar underneath the nameplate so the name sits on top
        if uf then
            bar:SetFrameStrata(uf:GetFrameStrata())
            bar:SetFrameLevel(math.max(0, uf:GetFrameLevel() - 1))
        end

        bar:SetStatusBarTexture(BAR_TEXTURE)
        bar:SetMinMaxValues(0, 100)
        bar:SetValue(0)
        bar:SetAlpha(BAR_ALPHA)

        local back = bar:CreateTexture(nil, "BACKGROUND")
        back:SetAllPoints()
        back:SetColorTexture(0, 0, 0, 0.5)

        bar:Hide()
        bars[plate] = bar

        -- The number, to the right of the bar (moved past long names below)
        fs = plate:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, FontSize(), "OUTLINE")
        fs:SetPoint("LEFT", bar, "RIGHT", NUMBER_PAD, 0)
        labels[plate] = fs
    end
    return fs, bars[plate]
end

-- Put the number after whichever ends further right: the bar, or the mob's
-- name text. Long names spill past the bar, so the number has to dodge them.
-- It measures the actual letters, not the name's box, because the game's
-- name box can be bar-width with the text centered and spilling out of it.
local nameCache = {}   -- nameplate frame -> the game's name text

local function FindName(plate, unit)
    local uf = plate.UnitFrame
    if not uf then return nil end
    local name = uf.name or uf.Name
    if name and name.GetStringWidth then return name end

    -- Not where expected: look for the text on the plate that matches the mob's name
    local wanted = UnitName(unit)
    local function scan(frame)
        for _, r in ipairs({ frame:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "FontString" and r:GetText() == wanted then
                return r
            end
        end
        for _, child in ipairs({ frame:GetChildren() }) do
            local found = scan(child)
            if found then return found end
        end
    end
    return scan(uf)
end

local function PlaceNumber(plate, unit, fs, bar)
    local extra = 0
    pcall(function()
        local name = nameCache[plate]
        if not name or name:GetText() ~= UnitName(unit) then
            name = FindName(plate, unit)
            nameCache[plate] = name
        end
        if name and name:IsShown() then
            local textRight
            local justify = name:GetJustifyH()
            if justify == "LEFT" then
                textRight = name:GetLeft() + name:GetStringWidth()
            elseif justify == "RIGHT" then
                textRight = name:GetRight()
            else
                textRight = name:GetCenter() + name:GetStringWidth() / 2
            end
            local barRight = bar:GetRight()
            if textRight and barRight and textRight > barRight then
                extra = textRight - barRight
            end
        end
    end)
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", bar, "RIGHT", NUMBER_PAD + extra, 0)
end

local function Draw(fs, bar, unit)
    if not UnitCanAttack("player", unit) then
        fs:Hide()
        bar:Hide()
        return
    end

    local isTanking, status, scaledPercent = UnitDetailedThreatSituation("player", unit)
    if not status or not scaledPercent then
        fs:Hide()     -- you're not on this mob's threat list
        bar:Hide()
        return
    end

    ApplyColor(fs, status, scaledPercent)
    fs:SetFormattedText("%d%%", scaledPercent)   -- the game fills in the number
    fs:Show()

    bar:SetValue(scaledPercent)                   -- the game fills the bar
    bar:Show()
end

local function UpdateUnit(unit)
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return end
    local fs, bar = GetLabel(plate)
    PlaceNumber(plate, unit, fs, bar)

    local ok, err = pcall(Draw, fs, bar, unit)
    if not ok then
        bar:Hide()
        local msg = tostring(err)
        if msg ~= MobThreatLastError then
            print("|cffff4444Mob Threat error:|r " .. msg)
        end
        MobThreatLastError = msg
        fs:SetTextColor(0.6, 0.6, 0.6)
        fs:SetText("?")
        fs:Show()
    end
end

local function UpdateAll()
    for unit in pairs(active) do
        UpdateUnit(unit)
    end
end

---------------------------------------------------------------------------
-- Settings window with a size slider
---------------------------------------------------------------------------
local win = CreateFrame("Frame", "MobThreatOptions", UIParent)
win:SetSize(240, 160)
win:SetPoint("CENTER")
win:SetFrameStrata("DIALOG")
win:SetMovable(true)
win:EnableMouse(true)
win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", win.StartMoving)
win:SetScript("OnDragStop", win.StopMovingOrSizing)
win:Hide()
ns.win = win   -- Glow.lua puts its tick box in here

local bg = win:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0, 0, 0, 0.85)

local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -8)
title:SetText("Mob Threat")

local close = CreateFrame("Button", nil, win)
close:SetSize(20, 20)
close:SetPoint("TOPRIGHT", -4, -4)
local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
closeText:SetAllPoints()
closeText:SetText("X")
close:SetScript("OnClick", function() win:Hide() end)

local sizeText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
sizeText:SetPoint("TOP", 0, -30)

local slider = CreateFrame("Slider", nil, win)
slider:SetOrientation("HORIZONTAL")
slider:SetSize(200, 16)
slider:SetPoint("TOP", 0, -50)
slider:SetMinMaxValues(MIN_SIZE, MAX_SIZE)
slider:SetValueStep(1)
pcall(slider.SetObeyStepOnDrag, slider, true)
slider:EnableMouse(true)
slider:EnableMouseWheel(true)

local track = slider:CreateTexture(nil, "BACKGROUND")
track:SetColorTexture(0.35, 0.35, 0.35, 1)
track:SetPoint("LEFT")
track:SetPoint("RIGHT")
track:SetHeight(4)

slider:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
local thumb = slider:GetThumbTexture()
thumb:SetSize(10, 16)
thumb:SetVertexColor(1, 0.8, 0)

-- A sample number so you can see the size without being in a fight
local preview = win:CreateFontString(nil, "OVERLAY")
preview:SetFont(STANDARD_TEXT_FONT, DEFAULT_SIZE, "OUTLINE")
preview:SetPoint("TOP", 0, -78)
preview:SetTextColor(1, 1, 0)
preview:SetText("75%")

local function ApplySize()
    local size = FontSize()
    sizeText:SetText("Text size: " .. size)
    preview:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
    for _, fs in pairs(labels) do
        fs:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
    end
end

slider:SetScript("OnValueChanged", function(self, value)
    value = math.floor(value + 0.5)
    if MobThreatDB then MobThreatDB.size = value end
    ApplySize()
end)

slider:SetScript("OnMouseWheel", function(self, delta)
    self:SetValue(self:GetValue() + delta)
end)

---------------------------------------------------------------------------
-- Test readout
---------------------------------------------------------------------------
local function Test()
    if not UnitExists("target") then
        print("Mob Threat: target a mob first.")
        return
    end
    local ok = pcall(UnitDetailedThreatSituation, "player", "target")
    print("Mob Threat: threat call works = " .. tostring(ok))
    print("Mob Threat: smooth color curve available = " .. tostring(curve ~= nil))
    print("Mob Threat: color in use = " .. lastColorMode)
    print("Mob Threat: curve setup error = " .. curveSetupError)
    print("Mob Threat: curve color error = " .. tostring(curveError))
    print("Mob Threat: backup color error = " .. tostring(statusColorError))
    print("Mob Threat: last error = " .. tostring(MobThreatLastError))
end

local function ToggleWindow()
    if win:IsShown() then win:Hide() else win:Show() end
end

---------------------------------------------------------------------------
-- Aggro list window: every group member, with the mobs looking at them
-- indented underneath. It works by asking each mob with a nameplate who its
-- target is, not by reading threat, so the secret-number rules don't apply.
-- Only mobs with a nameplate showing can be seen.
---------------------------------------------------------------------------
local LIST_FONT_SIZE = 12
local LINE_HEIGHT    = 15
local LIST_WIDTH     = 230
local MAX_LINES      = 60
local LIST_UPDATE    = 0.3     -- seconds between refreshes

local list = CreateFrame("Frame", "MobThreatAggroList", UIParent)
list:SetSize(LIST_WIDTH, 60)
list:SetPoint("CENTER", 300, 0)
list:SetFrameStrata("MEDIUM")
list:SetClampedToScreen(true)
list:SetMovable(true)
list:EnableMouse(true)
list:RegisterForDrag("LeftButton")
list:SetScript("OnDragStart", list.StartMoving)
list:SetScript("OnDragStop", list.StopMovingOrSizing)
list:Hide()

local listBg = list:CreateTexture(nil, "BACKGROUND")
listBg:SetAllPoints()
listBg:SetColorTexture(0, 0, 0, 0.7)

local listTitle = list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
listTitle:SetPoint("TOPLEFT", 8, -6)
listTitle:SetText("Who has aggro")

local listClose = CreateFrame("Button", nil, list)
listClose:SetSize(18, 18)
listClose:SetPoint("TOPRIGHT", -4, -3)
local listCloseText = listClose:CreateFontString(nil, "OVERLAY", "GameFontNormal")
listCloseText:SetAllPoints()
listCloseText:SetText("X")
listClose:SetScript("OnClick", function()
    list:Hide()
    if MobThreatDB then MobThreatDB.listShown = false end
end)

local lines = {}

local function GetLine(i)
    local fs = lines[i]
    if not fs then
        fs = list:CreateFontString(nil, "OVERLAY")
        fs:SetFont(STANDARD_TEXT_FONT, LIST_FONT_SIZE, "")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:SetWidth(LIST_WIDTH - 16)
        fs:SetPoint("TOPLEFT", 8, -26 - (i - 1) * LINE_HEIGHT)
        lines[i] = fs
    end
    return fs
end

-- Everyone in your group, plus pets (so a warlock's voidwalker shows up)
local function GroupMembers()
    local out = {}
    local function add(u)
        if UnitExists(u) then table.insert(out, u) end
    end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            add("raid" .. i)
            add("raidpet" .. i)
        end
    else
        add("player")
        add("pet")
        for i = 1, 4 do
            add("party" .. i)
            add("partypet" .. i)
        end
    end
    return out
end

-- Player names in class color, pets in pale blue
local function NameWithColor(u)
    local name = UnitName(u) or u
    if UnitIsPlayer(u) then
        local _, class = UnitClass(u)
        local c = class and RAID_CLASS_COLORS[class]
        if c then return name, c.r, c.g, c.b end
        return name, 1, 1, 1
    end
    return name, 0.6, 0.75, 1
end

-- Mob name, with its raid marker (skull, star...) in front if it has one
local function MobLabel(unit)
    local name = UnitName(unit) or "?"
    local icon = GetRaidTargetIndex(unit)
    if icon then
        name = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_" .. icon .. ":0|t " .. name
    end
    return name
end

local function BuildList()
    local members = GroupMembers()
    local onMember = {}    -- position in members -> list of mob labels

    for unit in pairs(active) do
        if UnitCanAttack("player", unit) and not UnitIsDead(unit) then
            local looking = unit .. "target"
            if UnitExists(looking) then
                for i, m in ipairs(members) do
                    if UnitIsUnit(looking, m) then
                        onMember[i] = onMember[i] or {}
                        table.insert(onMember[i], MobLabel(unit))
                        break
                    end
                end
            end
        end
    end

    local n = 0
    local function put(text, r, g, b)
        n = n + 1
        if n > MAX_LINES then return end
        local fs = GetLine(n)
        fs:SetText(text)
        fs:SetTextColor(r, g, b)
        fs:Show()
    end

    for i, m in ipairs(members) do
        local mobs = onMember[i]
        local name, r, g, b = NameWithColor(m)
        if mobs then
            table.sort(mobs)
            put(name .. "  (" .. #mobs .. ")", r, g, b)
            for _, mob in ipairs(mobs) do
                put("      " .. mob, 1, 0.45, 0.45)
            end
        elseif UnitIsPlayer(m) then
            put(name, r * 0.5, g * 0.5, b * 0.5)   -- dimmed: nothing on them
        end
    end

    return math.min(n, MAX_LINES)
end

local function RefreshList()
    if not list:IsShown() then return end

    local ok, result = pcall(BuildList)
    local n
    if ok then
        n = result
    else
        local msg = tostring(result)
        if msg ~= MobThreatListError then
            print("|cffff4444Mob Threat list error:|r " .. msg)
        end
        MobThreatListError = msg
        n = 1
        local fs = GetLine(1)
        fs:SetText("Blocked by the game, see chat")
        fs:SetTextColor(1, 0.3, 0.3)
        fs:Show()
    end

    for i = n + 1, #lines do
        lines[i]:Hide()
    end
    list:SetHeight(32 + n * LINE_HEIGHT)
end

C_Timer.NewTicker(LIST_UPDATE, RefreshList)

local function ToggleList()
    if list:IsShown() then
        list:Hide()
    else
        list:Show()
        RefreshList()
    end
    if MobThreatDB then MobThreatDB.listShown = list:IsShown() end
end

---------------------------------------------------------------------------
-- Minimap button
-- Left-click: settings window. Right-click: aggro list.
-- Drag it with the left mouse button to slide it around the minimap edge.
---------------------------------------------------------------------------
local mini = CreateFrame("Button", "MobThreatMinimapButton", Minimap)
mini:SetSize(31, 31)
mini:SetFrameStrata("MEDIUM")
mini:SetFrameLevel(8)
mini:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mini:RegisterForDrag("LeftButton")
mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local miniBg = mini:CreateTexture(nil, "BACKGROUND")
miniBg:SetSize(20, 20)
miniBg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
miniBg:SetPoint("TOPLEFT", 7, -5)

local miniIcon = mini:CreateTexture(nil, "ARTWORK")
miniIcon:SetSize(17, 17)
miniIcon:SetTexture("Interface\\Icons\\Spell_Nature_Reincarnation")
miniIcon:SetPoint("TOPLEFT", 7, -6)

local miniBorder = mini:CreateTexture(nil, "OVERLAY")
miniBorder:SetSize(53, 53)
miniBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
miniBorder:SetPoint("TOPLEFT")

local function PlaceButton()
    local angle = math.rad((MobThreatDB and MobThreatDB.angle) or 225)
    local radius = (Minimap:GetWidth() / 2) + 10
    mini:ClearAllPoints()
    mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

mini:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        if MobThreatDB then
            MobThreatDB.angle = math.deg(math.atan2(cy - my, cx - mx))
        end
        PlaceButton()
    end)
end)

mini:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

mini:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        ToggleList()
    else
        ToggleWindow()
    end
end)

mini:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Mob Threat")
    GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
    GameTooltip:AddLine("Right-click: who has aggro list", 1, 1, 1)
    GameTooltip:AddLine("Drag: move button", 1, 1, 1)
    GameTooltip:Show()
end)

mini:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

PlaceButton()

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:RegisterEvent("NAME_PLATE_UNIT_ADDED")
watcher:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
watcher:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
watcher:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_LOGIN" then
        MobThreatDB = MobThreatDB or {}
        MobThreatDB.size = MobThreatDB.size or DEFAULT_SIZE
        MobThreatDB.angle = MobThreatDB.angle or 225
        slider:SetValue(MobThreatDB.size)
        ApplySize()
        PlaceButton()
        if MobThreatDB.listShown then list:Show() end
        print("|cff00ff00Mob Threat|r loaded. Click the minimap button, or type /mobthreat.")
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        active[unit] = true
        UpdateUnit(unit)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        active[unit] = nil
        local plate = C_NamePlate.GetNamePlateForUnit(unit)
        if plate and labels[plate] then
            labels[plate]:Hide()
        end
        if plate and bars[plate] then
            bars[plate]:Hide()
        end
    elseif event == "UNIT_THREAT_LIST_UPDATE" and unit and active[unit] then
        UpdateUnit(unit)
    end
end)

-- Steady refresh so numbers keep moving during a fight
C_Timer.NewTicker(UPDATE_EVERY, UpdateAll)

---------------------------------------------------------------------------
-- Slash commands (backup for the minimap button)
-- /mobthreat or /mthreat        opens settings
-- /mobthreat test               test readout
-- /mobthreat glow               turns the target glow box on or off
-- /mobthreat size 150           mob nameplates at 150%
-- /mobthreat target 130         your target 130% bigger on top of that
---------------------------------------------------------------------------
SLASH_MOBTHREAT1 = "/mobthreat"
SLASH_MOBTHREAT2 = "/mthreat"
SlashCmdList["MOBTHREAT"] = function(msg)
    msg = strlower(strtrim(msg or ""))
    if ns.GlowSlash and ns.GlowSlash(msg) then
        return   -- glow, size and target commands live in Glow.lua
    elseif msg == "test" then
        Test()
    elseif msg == "list" then
        ToggleList()
    else
        ToggleWindow()
    end
end
