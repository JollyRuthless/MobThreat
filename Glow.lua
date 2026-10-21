-- Target Glow (part of Mob Threat): a box around your target's nameplate
-- with a bright spark that runs around the edge like a lit fuse.
-- Yellow for neutral mobs, red for hostile mobs or anything fighting you.
-- Players always stay yellow.
-- Turn it on or off with the tick box in the Mob Threat settings window.

local addonName, ns = ...

-- Settings you can change
local YELLOW = { 1, 0.9, 0 }       -- red, green, blue
local RED    = { 1, 0.15, 0.1 }
local THICK = 2                    -- border thickness in pixels
local PAD = 3                      -- space between the box and the health bar
local NAME_ROOM = 16               -- extra space above the bar so the name fits inside
local LEFT_ROOM = 4                 -- extra space left of the bar
local LEVEL_ROOM = 0               -- extra space right of the bar (34 puts the level badge inside)
local BORDER_ALPHA = 0.7           -- how solid the plain border is (0 to 1)
local SPEED = 250                  -- how fast the spark travels, pixels per second
local TRAIL = 12                   -- how many pieces in the spark's tail
local GAP = 3                      -- pixels between tail pieces

local WHITE = "Interface\\Buttons\\WHITE8X8"

-- The box that follows your target
local box = CreateFrame("Frame", "MobThreatGlowBox", UIParent)
box:SetFrameStrata("HIGH")
box:Hide()

-- The plain border
local edges = {}
local function MakeEdge()
    local t = box:CreateTexture(nil, "OVERLAY", nil, 1)
    t:SetTexture(WHITE)
    table.insert(edges, t)
    return t
end

local top, bottom, left, right = MakeEdge(), MakeEdge(), MakeEdge(), MakeEdge()

top:SetPoint("TOPLEFT")
top:SetPoint("TOPRIGHT")
top:SetHeight(THICK)

bottom:SetPoint("BOTTOMLEFT")
bottom:SetPoint("BOTTOMRIGHT")
bottom:SetHeight(THICK)

left:SetPoint("TOPLEFT")
left:SetPoint("BOTTOMLEFT")
left:SetWidth(THICK)

right:SetPoint("TOPRIGHT")
right:SetPoint("BOTTOMRIGHT")
right:SetWidth(THICK)

-- The fuse spark: a glowing tail that shrinks and fades behind the head
local sparks = {}
for i = 0, TRAIL do
    local t = box:CreateTexture(nil, "OVERLAY", nil, 5)
    t:SetTexture(WHITE)
    t:SetBlendMode("ADD")
    local fadeOut = 1 - i / (TRAIL + 1)
    local size = math.max(2, (THICK + 6) * fadeOut)
    t:SetSize(size, size)
    sparks[i] = { tex = t, alpha = fadeOut }
end

-- White-hot core on the head of the spark
local core = box:CreateTexture(nil, "OVERLAY", nil, 7)
core:SetTexture(WHITE)
core:SetBlendMode("ADD")
core:SetSize(THICK + 1, THICK + 1)
core:SetVertexColor(1, 1, 1, 1)

-- Red if the mob is hostile, or if it has aggro on you. Otherwise yellow.
local function PickColor()
    if UnitIsPlayer("target") then
        return YELLOW
    end
    local reaction = UnitReaction("player", "target")
    if reaction and reaction <= 3 then
        return RED
    end
    if UnitThreatSituation and UnitThreatSituation("player", "target") then
        return RED
    end
    return YELLOW
end

local function SetColor(c)
    for _, t in ipairs(edges) do
        t:SetVertexColor(c[1], c[2], c[3], BORDER_ALPHA)
    end
    for i = 0, TRAIL do
        sparks[i].tex:SetVertexColor(c[1], c[2], c[3], sparks[i].alpha)
    end
end

-- Turn a distance around the box into an x, y spot on its edge.
-- Starts top-left and goes clockwise.
local function PointOnBox(d, w, h)
    d = d % (2 * (w + h))
    if d < w then return d, h end
    d = d - w
    if d < h then return w, h - d end
    d = d - h
    if d < w then return w - d, 0 end
    d = d - w
    return 0, d
end

-- Move the spark every frame while the box is showing
local dist = 0
box:SetScript("OnUpdate", function(self, elapsed)
    local w = self:GetWidth() - THICK
    local h = self:GetHeight() - THICK
    if w <= 0 or h <= 0 then return end
    dist = (dist + elapsed * SPEED) % (2 * (w + h))
    local half = THICK / 2
    for i = 0, TRAIL do
        local x, y = PointOnBox(dist - i * GAP, w, h)
        local t = sparks[i].tex
        t:ClearAllPoints()
        t:SetPoint("CENTER", self, "BOTTOMLEFT", x + half, y + half)
        if i == 0 then
            core:ClearAllPoints()
            core:SetPoint("CENTER", self, "BOTTOMLEFT", x + half, y + half)
        end
    end
end)

-- How much bigger the nameplate is drawn than the rest of the UI.
-- The name and level room grow with it so they still fit inside the box.
local function PlateScale(frame)
    return frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
end

local currentBar, lastScale = nil, nil

local function Anchor(plate)
    box:ClearAllPoints()
    -- Hug the health bar if we can find it. The whole nameplate frame
    -- is much bigger than what you see, so wrapping it looks loose.
    local bar = plate.UnitFrame and plate.UnitFrame.healthBar
    currentBar = bar
    if bar then
        local sc = PlateScale(bar)
        lastScale = sc
        box:SetPoint("TOPLEFT", bar, "TOPLEFT",
            -(LEFT_ROOM + PAD) * sc, (NAME_ROOM + PAD) * sc)
        box:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT",
            (LEVEL_ROOM + PAD) * sc, -PAD * sc)
    else
        box:SetPoint("TOPLEFT", plate, "TOPLEFT", -PAD, PAD)
        box:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", PAD, -PAD)
    end
end

-- Move the box onto the target's nameplate, or hide it
local function GlowOn()
    return not (MobThreatDB and MobThreatDB.glow == false)   -- on unless switched off
end

local function Update()
    local plate = C_NamePlate.GetNamePlateForUnit("target")
    if plate and GlowOn() then
        SetColor(PickColor())
        Anchor(plate)
        box:Show()
    else
        currentBar = nil
        box:Hide()
    end
end

-- If the nameplate grows or shrinks (like when you target it), re-fit the box
local scaleWatch = CreateFrame("Frame")
scaleWatch:SetScript("OnUpdate", function()
    if currentBar and box:IsShown() then
        local sc = PlateScale(currentBar)
        if not lastScale or math.abs(sc - lastScale) > 0.01 then
            local plate = C_NamePlate.GetNamePlateForUnit("target")
            if plate then Anchor(plate) end
        end
    end
end)

-- Our own nameplate sizing, since this client has no size setting.
-- Saved between sessions in MobThreatDB.
local function DB()
    MobThreatDB = MobThreatDB or {}
    MobThreatDB.plateSize = MobThreatDB.plateSize or 100    -- mob nameplates, percent
    MobThreatDB.targetSize = MobThreatDB.targetSize or 100  -- extra for your target, percent
    if MobThreatDB.glow == nil then MobThreatDB.glow = true end
    return MobThreatDB
end

-- Mobs get the size setting. Players stay normal.
-- Your target gets the target setting on top.
local function ApplyScale(unit, plate)
    plate = plate or C_NamePlate.GetNamePlateForUnit(unit)
    if not unit or not plate or not plate.UnitFrame then return end
    local db = DB()
    local scale = 1
    if not UnitIsPlayer(unit) then
        scale = db.plateSize / 100
    end
    if UnitIsUnit(unit, "target") then
        scale = scale * db.targetSize / 100
    end
    pcall(plate.UnitFrame.SetScale, plate.UnitFrame, scale)
end

local function ScaleAll()
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        ApplyScale(plate.namePlateUnitToken, plate)
    end
end

-- Tick box in the Mob Threat settings window, under the size slider
local check = CreateFrame("CheckButton", nil, ns.win, "UICheckButtonTemplate")
check:SetSize(24, 24)
check:SetPoint("TOPLEFT", ns.win, "TOPLEFT", 16, -110)
local checkText = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
checkText:SetPoint("LEFT", check, "RIGHT", 4, 0)
checkText:SetText("Target glow box")

local function SetGlow(on)
    DB().glow = on
    check:SetChecked(on)
    Update()
end

check:SetScript("OnClick", function(self)
    SetGlow(self:GetChecked() and true or false)
end)

-- Hook up the script FIRST, then the events, one at a time and safely.
-- If this client doesn't know an event, it gets skipped instead of
-- breaking the whole addon.
local watcher = CreateFrame("Frame")
watcher:SetScript("OnEvent", function(self, event, unit)
    if event == "PLAYER_LOGIN" then
        check:SetChecked(DB().glow)
        ScaleAll()
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        ApplyScale(unit)
    elseif event == "PLAYER_TARGET_CHANGED" then
        ScaleAll()
    end
    Update()
end)

local skipped = {}
local EVENTS = {
    "PLAYER_LOGIN",
    "PLAYER_TARGET_CHANGED",
    "NAME_PLATE_UNIT_ADDED",
    "NAME_PLATE_UNIT_REMOVED",
    "UNIT_THREAT_LIST_UPDATE",
    "UNIT_THREAT_SITUATION_UPDATE",
    "UNIT_FLAGS",
    "PLAYER_REGEN_ENABLED",
}
for _, ev in ipairs(EVENTS) do
    if not pcall(watcher.RegisterEvent, watcher, ev) then
        table.insert(skipped, ev)
    end
end

-- Slash commands, called from MobThreat.lua. Returns true if it handled one.
--   /mobthreat glow          glow box on or off
--   /mobthreat size 150      mob nameplates at 150%
--   /mobthreat target 130    your target 130% bigger again on top of that
--   /mobthreat glowtest      status check for the glow box
local function Clamp(n)
    return math.max(50, math.min(300, n))
end

function ns.GlowSlash(msg)
    local cmd, num = (msg or ""):match("^%s*(%S*)%s*(%d*)")
    cmd = (cmd or ""):lower()
    num = tonumber(num)
    local db = DB()

    if cmd == "glow" then
        SetGlow(not db.glow)
        print("Mob Threat: target glow is " .. (db.glow and "on" or "off") .. ".")
    elseif cmd == "size" then
        if num then
            db.plateSize = Clamp(num)
            ScaleAll()
            Update()
        end
        print("Mob Threat: mob nameplate size is " .. db.plateSize .. "%.")
    elseif cmd == "target" then
        if num then
            db.targetSize = Clamp(num)
            ScaleAll()
            Update()
        end
        print("Mob Threat: target nameplate size is " .. db.targetSize .. "%.")
    elseif cmd == "glowtest" then
        local plate = C_NamePlate.GetNamePlateForUnit("target")
        print("Mob Threat glow: on = " .. tostring(db.glow)
            .. ". Nameplate found: " .. tostring(plate ~= nil)
            .. ". Box showing: " .. tostring(box:IsShown())
            .. ". Health bar found: " .. tostring(plate and plate.UnitFrame and plate.UnitFrame.healthBar ~= nil) .. ".")
        if #skipped > 0 then
            print("Mob Threat glow skipped events: " .. table.concat(skipped, ", "))
        end
    else
        return false
    end
    return true
end
