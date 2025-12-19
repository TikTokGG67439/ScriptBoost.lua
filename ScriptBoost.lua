-- JumpPull — Feature-complete expanded LocalScript
-- Paste into StarterPlayer > StarterPlayerScripts as LocalScript
-- Features:
--  - Pull bind: Hold / Toggle / None (capture via UI)
--  - Bindings Frame: movable, quick capture for binds + settings
--  - AutoJump: ON/OFF, interval, only when on ground
--  - ModeActive: Basic / IdleDelayed / Smart / Advanced (clear behavior)
--  - Multiple force modes: Velocity, VectorForce, LinearVelocity, Impulse
--  - Aim helper: Hold/Toggle/None, FOV, smoothing, wallcheck
--  - Player ESP highlights toggle
--  - Gravity helper: set world gravity while enabled, restore original on off
--  - CS2-style strafe helper, Air control, MaxAirSpeed clamp
--  - Save/Load settings (player attributes JSON)
--  - Robust checks, pcall's, debug prints, concise UI, persistent attributes
--  - Numerous safety checks and comments
--  - Debug mode for verbose output
-- Estimated lines: large (feature-rich, verbose comments)

-- services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ======= CONFIG DEFAULTS =======
local DEFAULTS = {
    debug = false,

    -- core mode selection
    mode = "Velocity", -- "Velocity", "VectorForce", "LinearVelocity", "Impulse"
    speed = 90,
    duration = 0.18,
    smoothing = 8,
    rampTime = 0.06,

    -- air control / strafing
    airControl = 0.6,
    strafeStrength = 60,
    cs2Mode = false,

    -- force / impulse
    acceleration = 400,
    maxForce = 1e5,
    impulseStrength = 60,
    maxAirSpeed = 150,
    enableMaxAirSpeed = true,

    -- align (alignposition/orientation settings)
    alignResponsiveness = 50,
    alignMaxForce = 1e5,

    -- aim helper
    aimHelper = false,
    aimTargetPart = "HumanoidRootPart",
    aimStrength = 0.9,
    aimSpeed = 10,
    aimFOV = 90,
    aimBindMode = "Hold", -- Hold/Toggle/None
    aimBind = nil,
    aimWallCheck = true,
    aimWallCheckPadding = 0.1,

    -- pull bind settings
    pullBindMode = "Hold", -- Hold/Toggle/None
    pullBind = nil,        -- Enum.KeyCode or nil

    -- auto jump
    autoJump = false,
    autoJumpInterval = 0.18,

    -- modeActive gating
    modeActive = "Smart", -- Basic / IdleDelayed / Smart / Advanced
    idleDelay = 0.5,
    moveThreshold = 0.5,

    -- misc
    playerESP = false,
    gravity = (workspace and workspace.Gravity) or 196.2,
    gravityHelper = false
}

-- runtime settings table (copy of defaults to edit)
local settings = {}
for k,v in pairs(DEFAULTS) do settings[k] = v end

-- runtime flags
local enabled = true
local pullHoldActive = false
local pullToggleActive = false
local aimActiveToggle = false
local autoJumpRunning = false
local originalGlobalGravity = nil
local espLoopRunning = false
local debugMode = settings.debug

-- store highlight handles for players
local highlights = {} -- [userId] = {hl = Highlight, player = Player}

-- per-character state
local charState = {} -- [Character] = {vAttach, vForce, lv, align, ...}

-- helper: debug print
local function dprint(...)
    if debugMode then
        print("[JP DEBUG]", ...)
    end
end

-- helper: safe tonumber and scientific notation parser
local function parseNumber(s)
    if type(s) == "number" then return s end
    if type(s) ~= "string" then return nil end
    s = s:gsub(",", ".")
    local n = tonumber(s)
    if n then return n end
    local mant,exp = s:match("^([+-]?%d*%.?%d+)[eE]([+-]?%d+)$")
    if mant and exp then
        local mn = tonumber(mant)
        local e = tonumber(exp)
        if mn and e then return mn * (10 ^ e) end
    end
    return nil
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "JumpPull_UI"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

-- root frame
local root = Instance.new("Frame")
root.Name = "JP_Root"
root.Size = UDim2.new(0,420,0,260)
root.Position = UDim2.new(0,12,0,12)
root.AnchorPoint = Vector2.new(0,0)
root.BackgroundColor3 = Color3.fromRGB(30,30,30)
root.BorderSizePixel = 0
root.Active = true
root.Draggable = true
root.Parent = screenGui

local title = Instance.new("TextLabel", root)
title.Size = UDim2.new(1, -16, 0, 26)
title.Position = UDim2.new(0, 8, 0, 8)
title.BackgroundTransparency = 1
title.Text = "JumpPull — Full"
title.Font = Enum.Font.SourceSansBold
title.TextSize = 18
title.TextColor3 = Color3.fromRGB(240,240,240)
title.TextXAlignment = Enum.TextXAlignment.Left

-- small status label
local statusLabel = Instance.new("TextLabel", root)
statusLabel.Size = UDim2.new(1, -16, 0, 18)
statusLabel.Position = UDim2.new(0, 8, 0, 36)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Enabled: ON | ModeActive: "..settings.modeActive.." | Mode: "..settings.mode
statusLabel.Font = Enum.Font.SourceSans
statusLabel.TextSize = 14
statusLabel.TextColor3 = Color3.fromRGB(200,200,200)
statusLabel.TextXAlignment = Enum.TextXAlignment.Left

-- button factory
local function makeButton(parent, text, x, y, w)
    local btn = Instance.new("TextButton", parent)
    btn.Size = UDim2.new(0, w or 190, 0, 32)
    btn.Position = UDim2.new(0, x, 0, y)
    btn.Text = text
    btn.Font = Enum.Font.SourceSansBold
    btn.TextSize = 16
    btn.TextColor3 = Color3.fromRGB(240,240,240)
    btn.BackgroundColor3 = Color3.fromRGB(60,60,60)
    return btn
end

local btnToggle = makeButton(root, "Enabled: ON", 8, 64, 120)
local btnBindings = makeButton(root, "Bindings", 140, 64, 120)
local btnAutoJump = makeButton(root, "AutoJump: OFF", 272, 64, 140)

-- quick info label
local infoLabel = Instance.new("TextLabel", root)
infoLabel.Size = UDim2.new(1, -16, 0, 20)
infoLabel.Position = UDim2.new(0,8,0,104)
infoLabel.BackgroundTransparency = 1
infoLabel.TextColor3 = Color3.fromRGB(200,200,200)
infoLabel.Font = Enum.Font.SourceSans
infoLabel.TextSize = 14
infoLabel.Text = "Bindings closed. Press Bindings to open."

-- Mode selection quick button (cycles through main modes)
local btnMode = makeButton(root, "Mode: "..settings.mode, 8, 128, 200)
local btnESP = makeButton(root, "PlayerESP: OFF", 220, 128, 190)

-- quick gravity helper toggle
local btnGravity = makeButton(root, "GravityHelper: OFF", 8, 168, 200)

-- Bindings panel (movable)
local bindPanel = Instance.new("Frame", screenGui)
bindPanel.Size = UDim2.new(0, 380, 0, 300)
bindPanel.Position = UDim2.new(0, 12, 0, 280)
bindPanel.BackgroundColor3 = Color3.fromRGB(26,26,26)
bindPanel.BorderSizePixel = 0
bindPanel.Active = true
bindPanel.Draggable = true
bindPanel.Visible = false

local bpTitle = Instance.new("TextLabel", bindPanel)
bpTitle.Size = UDim2.new(1, -16, 0, 22)
bpTitle.Position = UDim2.new(0, 8, 0, 8)
bpTitle.BackgroundTransparency = 1
bpTitle.Font = Enum.Font.SourceSansBold
bpTitle.Text = "Bindings / Advanced Settings"
bpTitle.TextColor3 = Color3.fromRGB(230,230,230)
bpTitle.TextSize = 16
bpTitle.TextXAlignment = Enum.TextXAlignment.Left

-- helper to make rows on bindPanel
local function bpRow(idx, labelText)
    local y = 8 + 26 * idx
    local lbl = Instance.new("TextLabel", bindPanel)
    lbl.Size = UDim2.new(0.56,0,0,22)
    lbl.Position = UDim2.new(0,8,0,y)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.SourceSans
    lbl.Text = labelText
    lbl.TextColor3 = Color3.fromRGB(220,220,220)
    lbl.TextSize = 14
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    return y
end

-- rows (we'll use indexes)
bpRow(1, "Pull Bind (click then press key). Esc to clear.")
local pullBindBtn = Instance.new("TextButton", bindPanel)
pullBindBtn.Size = UDim2.new(0, 140, 0, 22)
pullBindBtn.Position = UDim2.new(1, -152, 0, 8+26*1)
pullBindBtn.Text = settings.pullBind and settings.pullBind.Name or "Not bound"
pullBindBtn.Font = Enum.Font.SourceSans
pullBindBtn.TextSize = 14
pullBindBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)

bpRow(2, "Pull Mode (Hold / Toggle / None)")
local pullModeBtn = Instance.new("TextButton", bindPanel)
pullModeBtn.Size = UDim2.new(0, 140, 0, 22)
pullModeBtn.Position = UDim2.new(1, -152, 0, 8+26*2)
pullModeBtn.Text = settings.pullBindMode
pullModeBtn.Font = Enum.Font.SourceSans
pullModeBtn.TextSize = 14
pullModeBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)

bpRow(3, "AutoJump ON/OFF (interval)")
local autoJumpBtn = Instance.new("TextButton", bindPanel)
autoJumpBtn.Size = UDim2.new(0, 80, 0, 22)
autoJumpBtn.Position = UDim2.new(1, -236, 0, 8+26*3)
autoJumpBtn.Text = settings.autoJump and "ON" or "OFF"
autoJumpBtn.Font = Enum.Font.SourceSans
autoJumpBtn.TextSize = 14
autoJumpBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)

local autoJumpBox = Instance.new("TextBox", bindPanel)
autoJumpBox.Size = UDim2.new(0, 60, 0, 22)
autoJumpBox.Position = UDim2.new(1, -152, 0, 8+26*3)
autoJumpBox.Text = tostring(settings.autoJumpInterval)
autoJumpBox.Font = Enum.Font.SourceSans
autoJumpBox.TextSize = 14
autoJumpBox.BackgroundColor3 = Color3.fromRGB(36,36,36)
autoJumpBox.TextColor3 = Color3.fromRGB(230,230,230)

bpRow(4, "ModeActive (Basic / IdleDelayed / Smart / Advanced)")
local modeActiveBtn = Instance.new("TextButton", bindPanel)
modeActiveBtn.Size = UDim2.new(0, 140, 0, 22)
modeActiveBtn.Position = UDim2.new(1, -152, 0, 8+26*4)
modeActiveBtn.Text = settings.modeActive
modeActiveBtn.Font = Enum.Font.SourceSans
modeActiveBtn.TextSize = 14
modeActiveBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)

bpRow(5, "Aim Helper ON/OFF (FOV / Strength / Bind)")
local aimHelperBtn = Instance.new("TextButton", bindPanel)
aimHelperBtn.Size = UDim2.new(0, 80, 0, 22)
aimHelperBtn.Position = UDim2.new(1, -236, 0, 8+26*5)
aimHelperBtn.Text = settings.aimHelper and "ON" or "OFF"
aimHelperBtn.Font = Enum.Font.SourceSans
aimHelperBtn.TextSize = 14
aimHelperBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)

local aimFovBox = Instance.new("TextBox", bindPanel)
aimFovBox.Size = UDim2.new(0, 60, 0, 22)
aimFovBox.Position = UDim2.new(1, -152, 0, 8+26*5)
aimFovBox.Text = tostring(settings.aimFOV)
aimFovBox.Font = Enum.Font.SourceSans
aimFovBox.TextSize = 14
aimFovBox.BackgroundColor3 = Color3.fromRGB(36,36,36)
aimFovBox.TextColor3 = Color3.fromRGB(230,230,230)

bpRow(6, "ESP: highlight players (except owner), On/Off")
local espBtn = Instance.new("TextButton", bindPanel)
espBtn.Size = UDim2.new(0, 80, 0, 22)
espBtn.Position = UDim2.new(1, -236, 0, 8+26*6)
espBtn.Text = settings.playerESP and "ON" or "OFF"
espBtn.Font = Enum.Font.SourceSans
espBtn.TextSize = 14
espBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)

bpRow(7, "Gravity Helper: set workspace.Gravity when ON")
local gravityBtn = Instance.new("TextButton", bindPanel)
gravityBtn.Size = UDim2.new(0, 140, 0, 22)
gravityBtn.Position = UDim2.new(1, -152, 0, 8+26*7)
gravityBtn.Text = settings.gravityHelper and "ON" or "OFF"
gravityBtn.Font = Enum.Font.SourceSans
gravityBtn.TextSize = 14
gravityBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)

bpRow(8, "Save / Load settings to Player attributes")
local saveBtn = Instance.new("TextButton", bindPanel)
saveBtn.Size = UDim2.new(0, 80, 0, 26)
saveBtn.Position = UDim2.new(0, 12, 0, 8+26*8)
saveBtn.Text = "Save"
saveBtn.Font = Enum.Font.SourceSans
saveBtn.TextSize = 14
saveBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)

local loadBtn = Instance.new("TextButton", bindPanel)
loadBtn.Size = UDim2.new(0, 80, 0, 26)
loadBtn.Position = UDim2.new(0, 100, 0, 8+26*8)
loadBtn.Text = "Load"
loadBtn.Font = Enum.Font.SourceSans
loadBtn.TextSize = 14
loadBtn.BackgroundColor3 = Color3.fromRGB(60,60,60)

-- internal helpers for highlight management
local ownerUserId = nil
pcall(function()
    if type(game.CreatorId) == "number" and game.CreatorId > 0 then ownerUserId = game.CreatorId end
end)

local function createHighlightForPlayer(p)
    if not p or p == player then return end
    if ownerUserId and p.UserId == ownerUserId then return end
    local uid = p.UserId
    local rec = highlights[uid]
    if rec and rec.hl and rec.hl.Parent == workspace then
        -- reattach if needed
        if p.Character then
            pcall(function() rec.hl.Adornee = p.Character end)
        end
        rec.player = p
        return
    end
    local ok, hl = pcall(function()
        local h = Instance.new("Highlight")
        h.Name = "_JP_Highlight_"..tostring(uid)
        h.Parent = workspace
        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        h.FillTransparency = 0.6
        h.OutlineTransparency = 0.4
        return h
    end)
    if not ok or not hl then return end
    highlights[uid] = {hl = hl, player = p}
    if p.Character then
        pcall(function() hl.Adornee = p.Character end)
    end
end

local function removeHighlightForPlayer(p)
    if not p then return end
    local uid = p.UserId
    local rec = highlights[uid]
    if rec and rec.hl then
        pcall(function() rec.hl:Destroy() end)
    end
    highlights[uid] = nil
end

local espLoopConn = nil
local function startESPLoop()
    if espLoopRunning then return end
    espLoopRunning = true
    espLoopConn = RunService.Heartbeat:Connect(function()
        if settings.playerESP then
            for _,p in ipairs(Players:GetPlayers()) do
                if p ~= player and (not ownerUserId or p.UserId ~= ownerUserId) then
                    createHighlightForPlayer(p)
                    local rec = highlights[p.UserId]
                    if rec and rec.hl then
                        local ch = p.Character
                        if ch and rec.hl.Adornee ~= ch then
                            pcall(function() rec.hl.Adornee = ch end)
                        end
                    end
                end
            end
        else
            for uid,rec in pairs(highlights) do
                pcall(function() if rec.hl then rec.hl.Adornee = nil end end)
            end
        end
    end)
end

local function stopESPLoop()
    espLoopRunning = false
    if espLoopConn then espLoopConn:Disconnect(); espLoopConn = nil end
    for uid,rec in pairs(highlights) do
        pcall(function() if rec.hl then rec.hl:Destroy() end end)
    end
    highlights = {}
end

local function manageESP()
    if settings.playerESP then
        startESPLoop()
    else
        stopESPLoop()
    end
end

-- gravity helper toggles workspace gravity but stores original
local function toggleGravityHelper(val)
    local v = (val ~= nil) and val or not settings.gravityHelper
    settings.gravityHelper = v
    gravityBtn.Text = v and "ON" or "OFF"
    btnGravity.Text = "GravityHelper: "..(v and "ON" or "OFF")
    if v then
        if not originalGlobalGravity then
            pcall(function() originalGlobalGravity = workspace.Gravity end)
        end
        pcall(function() workspace.Gravity = tonumber(settings.gravity) or DEFAULTS.gravity end)
    else
        if originalGlobalGravity then
            pcall(function() workspace.Gravity = originalGlobalGravity end)
            originalGlobalGravity = nil
        end
    end
    player:SetAttribute("JP_GravityHelper", settings.gravityHelper)
end

-- ===== Movement tracking for IdleDelayed & Smart =====
local lastMoveTime = tick()
local function trackMovement(hrp)
    lastMoveTime = tick()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not hrp or not hrp.Parent then conn:Disconnect(); return end
        local v = hrp.Velocity and hrp.Velocity.Magnitude or 0
        if v > settings.moveThreshold then lastMoveTime = tick() end
    end)
    return conn
end

-- ===== Character attach, applyBurst & modes =====
local function createAttach(hrp)
    local a = Instance.new("Attachment")
    a.Name = "_JP_Att"
    a.Parent = hrp
    return a
end

local function allowedByMode(character)
    local modeActive = settings.modeActive
    if modeActive == "Basic" then return true end
    local humanoid = character:FindFirstChild("Humanoid")
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not hrp then return false end
    if modeActive == "IdleDelayed" then
        if tick() - lastMoveTime >= settings.idleDelay then return false end
        return true
    elseif modeActive == "Smart" then
        local movingNow = false
        pcall(function()
            if humanoid.MoveDirection and humanoid.MoveDirection.Magnitude > 0.1 then movingNow = true end
            if hrp.Velocity and hrp.Velocity.Magnitude > settings.moveThreshold then movingNow = true end
        end)
        if movingNow then return true end
        if tick() - lastMoveTime < settings.idleDelay then return true end
        return false
    elseif modeActive == "Advanced" then
        local st = charState[character]
        if st and st._allowAdvanced then st._allowAdvanced = nil; return true end
        return false
    end
    return true
end

local function applyBurst(character)
    if not character or not allowedByMode(character) or not enabled then return end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local st = charState[character] or {}
    charState[character] = st
    if st._deb then return end
    st._deb = true

    local mode = settings.mode
    if mode == "VectorForce" then
        -- VectorForce approach
        local att = createAttach(hrp)
        local vf = Instance.new("VectorForce")
        vf.Name = "_JP_VectorForce"
        vf.Attachment0 = att
        vf.RelativeTo = Enum.ActuatorRelativeTo.World
        vf.ApplyAtCenterOfMass = true
        vf.Parent = hrp

        local look = hrp.CFrame.LookVector
        local forward = Vector3.new(look.X,0,look.Z)
        if forward.Magnitude == 0 then forward = Vector3.new(0,0,1) end
        forward = forward.Unit
        local desired = forward * (parseNumber(settings.speed) or settings.speed)
        local curVel = hrp.Velocity
        local dv = Vector3.new(desired.X - curVel.X, 0, desired.Z - curVel.Z)
        local mass = 1
        pcall(function() mass = hrp:GetMass() end)
        local force = dv * (mass / math.max(0.016, parseNumber(settings.duration) or settings.duration))
        if force.Magnitude > (parseNumber(settings.maxForce) or settings.maxForce) then
            force = force.Unit * (parseNumber(settings.maxForce) or settings.maxForce)
        end
        vf.Force = force

        task.delay(parseNumber(settings.duration) or settings.duration, function()
            pcall(function() if vf and vf.Parent then vf:Destroy() end end)
            pcall(function() if att and att.Parent then att:Destroy() end end)
        end)

    elseif mode == "LinearVelocity" then
        local a = createAttach(hrp)
        local lv = Instance.new("LinearVelocity")
        lv.Name = "_JP_LinearVelocity"
        lv.Attachment0 = a
        lv.RelativeTo = Enum.ActuatorRelativeTo.World
        lv.VectorVelocity = Vector3.new(0,0,0)
        pcall(function() lv.MaxForce = Vector3.new(settings.maxForce, settings.maxForce, settings.maxForce) end)
        lv.Parent = hrp

        local look = hrp.CFrame.LookVector
        local forward = Vector3.new(look.X,0,look.Z)
        if forward.Magnitude==0 then forward = Vector3.new(0,0,1) end
        forward = forward.Unit
        lv.VectorVelocity = forward * (parseNumber(settings.speed) or settings.speed)

        task.delay(parseNumber(settings.duration) or settings.duration, function()
            pcall(function() if lv and lv.Parent then lv:Destroy() end end)
            pcall(function() if a and a.Parent then a:Destroy() end end)
        end)
    elseif mode == "Impulse" then
        local look = hrp.CFrame.LookVector
        local forward = Vector3.new(look.X,0,look.Z)
        if forward.Magnitude==0 then forward = Vector3.new(0,0,1) end
        forward = forward.Unit
        local mass = 1
        pcall(function() mass = hrp:GetMass() end)
        local imp = forward * (parseNumber(settings.impulseStrength) or settings.impulseStrength) * mass
        pcall(function() if hrp and hrp:IsA("BasePart") then hrp:ApplyImpulse(imp) end end)
    else
        -- Velocity fallback (instant set)
        local look = hrp.CFrame.LookVector
        local forward = Vector3.new(look.X,0,look.Z)
        if forward.Magnitude == 0 then forward = Vector3.new(0,0,1) end
        forward = forward.Unit
        local desired = forward * (parseNumber(settings.speed) or settings.speed)
        local cur = hrp.Velocity
        pcall(function() hrp.Velocity = Vector3.new(desired.X, cur.Y, desired.Z) end)
    end

    task.spawn(function()
        task.wait((parseNumber(settings.duration) or settings.duration) + 0.05)
        st._deb = false
    end)
end

-- attach to character: movement tracking and jump hook
local function attachToCharacter(character)
    if not character then return end
    local humanoid = character:FindFirstChild("Humanoid") or character:WaitForChild("Humanoid", 2)
    local hrp = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 2)
    if not humanoid or not hrp then return end
    local st = charState[character] or {}
    charState[character] = st

    if st._moveConn then st._moveConn:Disconnect() end
    st._moveConn = trackMovement(hrp)

    if st._jumpConn then st._jumpConn:Disconnect() end
    st._jumpConn = humanoid.Jumping:Connect(function(active)
        if active and enabled then
            -- allow one advanced trigger: Advanced mode requires explicit trigger
            st._allowAdvanced = true
            applyBurst(character)
        end
    end)

    humanoid.Died:Connect(function()
        if st._moveConn then st._moveConn:Disconnect() end
        if st._jumpConn then st._jumpConn:Disconnect() end
        charState[character] = nil
    end)
end

-- attach local player's character persistently
player.CharacterAdded:Connect(function(ch) task.wait(0.05); attachToCharacter(ch) end)
if player.Character then task.spawn(function() task.wait(0.05); attachToCharacter(player.Character) end) end

-- Pull runner: handles toggle/hold timing and safety
task.spawn(function()
    while true do
        if pullToggleActive and enabled then
            local ch = player.Character
            if ch then applyBurst(ch) end
            task.wait((parseNumber(settings.duration) or settings.duration) + 0.05)
        elseif pullHoldActive and enabled then
            local ch = player.Character
            if ch then applyBurst(ch) end
            task.wait((parseNumber(settings.duration) or settings.duration) + 0.05)
        else
            task.wait(0.06)
        end
    end
end)


local autoJumpThread = nil
local function startAutoJump()
    if autoJumpRunning then return end
    autoJumpRunning = true
    settings.autoJump = true
    autoJumpBtn.Text = "ON"
    btnAutoJump.Text = "AutoJump: ON"
    autoJumpBox.Text = tostring(settings.autoJumpInterval)
    autoJumpThread = task.spawn(function()
        while autoJumpRunning do
            local ch = player.Character
            local humanoid = ch and ch:FindFirstChild("Humanoid")
            if humanoid and humanoid.Health > 0 then
                -- only jump when on floor (not in air)
                if humanoid.FloorMaterial ~= Enum.Material.Air then
                    humanoid.Jump = true
                end
            end
            local waitT = math.max(0.05, parseNumber(autoJumpBox.Text) or settings.autoJumpInterval)
            task.wait(waitT)
        end
    end)
end

local function stopAutoJump()
    autoJumpRunning = false
    settings.autoJump = false
    autoJumpBtn.Text = "OFF"
    btnAutoJump.Text = "AutoJump: OFF"
end

-- ===== Aim helper (simple target picker + camera lerp) =====
local cameraRef = workspace.CurrentCamera
local aimConn = nil

local function getCamera()
    local cam = workspace.CurrentCamera
    if cam then cameraRef = cam end
    return cameraRef
end

local function getCandidates()
    local res = {}
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= player then
            local ch = p.Character
            if ch and ch.Parent then
                local part = ch:FindFirstChild(settings.aimTargetPart)
                local humanoid = ch:FindFirstChild("Humanoid")
                if part and humanoid and humanoid.Health > 0 then
                    if not (ownerUserId and p.UserId == ownerUserId) then
                        table.insert(res, {player = p, part = part, humanoid = humanoid})
                    end
                end
            end
        end
    end
    return res
end

local function wallCheck(targetPart)
    if not settings.aimWallCheck then return true end
    local cam = getCamera()
    if not cam then return true end
    local origin = cam.CFrame.Position
    local targetPos = targetPart.Position
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    local ignore = {}
    if player.Character then table.insert(ignore, player.Character) end
    if targetPart and targetPart.Parent then table.insert(ignore, targetPart.Parent) end
    params.FilterDescendantsInstances = ignore
    local dir = (targetPos - origin)
    local result = workspace:Raycast(origin, dir, params)
    if not result then return true end
    if result.Instance and result.Instance:IsDescendantOf(targetPart.Parent) then return true end
    return false
end

local function angleToTarget(targetPos)
    local cam = getCamera()
    if not cam then return 180 end
    local look = cam.CFrame.LookVector
    local dir = (targetPos - cam.CFrame.Position)
    if dir.Magnitude == 0 then return 0 end
    local unit = dir.Unit
    local dot = math.clamp(look:Dot(unit), -1, 1)
    return math.deg(math.acos(dot))
end

local function pickTarget()
    local cand = getCandidates()
    local best, bestScore, bestPart = nil, math.huge, nil
    local cam = getCamera()
    if not cam then return nil end
    for _,entry in ipairs(cand) do
        local p = entry.player
        local part = entry.part
        local ang = angleToTarget(part.Position)
        if ang <= (settings.aimFOV or 180) then
            local dist = (part.Position - cam.CFrame.Position).Magnitude
            if settings.aimWallCheck and not wallCheck(part) then
                -- ignore behind wall
            else
                local score = ang + dist * 0.01
                if score < bestScore then best = p; bestScore = score; bestPart = part end
            end
        end
    end
    return best, bestPart
end

local function startAimLoop()
    if aimConn then return end
    aimConn = RunService.RenderStepped:Connect(function(dt)
        if not settings.aimHelper then return end
        local cam = getCamera()
        if not cam then return end
        local aimShouldRun = false
        if settings.aimBindMode == "None" then aimShouldRun = settings.aimHelper
        elseif settings.aimBindMode == "Hold" then if settings.aimBind then aimShouldRun = UserInputService:IsKeyDown(settings.aimBind) end
        elseif settings.aimBindMode == "Toggle" then aimShouldRun = aimActiveToggle end
        if not aimShouldRun then return end
        local targetPlayer, targetPart = pickTarget()
        if not targetPlayer or not targetPart then return end
        local camPos = cam.CFrame.Position
        local desired = CFrame.lookAt(camPos, targetPart.Position)
        local aimStrength = tonumber(settings.aimStrength) or settings.aimStrength or 0.9
        aimStrength = math.clamp(aimStrength, 0, 1)
        local aimSpeed = tonumber(settings.aimSpeed) or settings.aimSpeed or 10
        local t = math.clamp(1 - math.exp(-aimSpeed * dt), 0, 1)
        local mix = t * aimStrength
        if mix <= 0 then return end
        local newCFrame = cam.CFrame:Lerp(desired, mix)
        local final = CFrame.new(camPos, newCFrame.LookVector + camPos)
        pcall(function() cam.CFrame = final end)
    end)
end

local function stopAimLoop()
    if aimConn then aimConn:Disconnect(); aimConn = nil end
end

-- aim monitor (start/stop based on settings)
task.spawn(function()
    while true do
        if settings.aimHelper then startAimLoop() else stopAimLoop() end
        task.wait(0.2)
    end
end)

-- ===== Bind capture logic (for pull & aim) =====
local waitingForPullBind = false
local waitingForAimBind = false
local captureConn = nil

local function captureKeyFor(which)
    -- which == "pull" or "aim"
    if which == "pull" then
        if waitingForPullBind then return end
        waitingForPullBind = true
        infoLabel.Text = "Press key for Pull bind (Esc to clear)"
        captureConn = UserInputService.InputBegan:Connect(function(inp, gp)
            if gp then return end
            if not waitingForPullBind then
                if captureConn then captureConn:Disconnect(); captureConn = nil end
                return
            end
            waitingForPullBind = false
            if inp.KeyCode == Enum.KeyCode.Escape then settings.pullBind = nil
            else settings.pullBind = inp.KeyCode end
            pullBindBtn.Text = settings.pullBind and settings.pullBind.Name or "Not bound"
            infoLabel.Text = "Pull bind updated"
            if captureConn then captureConn:Disconnect(); captureConn = nil end
        end)
    else
        if waitingForAimBind then return end
        waitingForAimBind = true
        infoLabel.Text = "Press key for Aim bind (Esc to clear)"
        captureConn = UserInputService.InputBegan:Connect(function(inp, gp)
            if gp then return end
            if not waitingForAimBind then
                if captureConn then captureConn:Disconnect(); captureConn = nil end
                return
            end
            waitingForAimBind = false
            if inp.KeyCode == Enum.KeyCode.Escape then settings.aimBind = nil
            else settings.aimBind = inp.KeyCode end
            -- (aim bind UI not displayed individually, but saved)
            infoLabel.Text = "Aim bind updated"
            if captureConn then captureConn:Disconnect(); captureConn = nil end
        end)
    end
end

-- ===== Bind Input handling (global) =====
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    -- main toggle (T)
    if input.KeyCode == Enum.KeyCode.T then
        enabled = not enabled
        btnToggle.Text = enabled and "Enabled: ON" or "Enabled: OFF"
        statusLabel.Text = "Enabled: "..(enabled and "ON" or "OFF").." | ModeActive: "..settings.modeActive.." | Mode: "..settings.mode
        return
    end
    -- aim toggle or hold
    if settings.aimBind and input.KeyCode == settings.aimBind then
        if settings.aimBindMode == "Toggle" then aimActiveToggle = not aimActiveToggle end
    end
    -- pull bind handling
    if settings.pullBind and input.KeyCode == settings.pullBind then
        if settings.pullBindMode == "Toggle" then
            pullToggleActive = not pullToggleActive
            if pullToggleActive then
                local ch = player.Character
                if ch then applyBurst(ch) end
            end
        elseif settings.pullBindMode == "Hold" then
            pullHoldActive = true
            local ch = player.Character
            if ch then applyBurst(ch) end
        end
    end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if settings.pullBind and input.KeyCode == settings.pullBind and settings.pullBindMode == "Hold" then
        pullHoldActive = false
    end
end)

-- ===== UI interactions hookups =====
btnToggle.MouseButton1Click:Connect(function()
    enabled = not enabled
    btnToggle.Text = enabled and "Enabled: ON" or "Enabled: OFF"
    statusLabel.Text = "Enabled: "..(enabled and "ON" or "OFF").." | ModeActive: "..settings.modeActive.." | Mode: "..settings.mode
end)

btnBindings.MouseButton1Click:Connect(function()
    bindPanel.Visible = not bindPanel.Visible
    infoLabel.Text = bindPanel.Visible and "Bindings open" or "Bindings closed"
end)

btnAutoJump.MouseButton1Click:Connect(function()
    if settings.autoJump then
        stopAutoJump()
    else
        startAutoJump()
    end
    autoJumpBtn.Text = settings.autoJump and "ON" or "OFF"
end)

-- mode quick change
btnMode.MouseButton1Click:Connect(function()
    local MODES = {"Velocity", "VectorForce", "LinearVelocity", "Impulse"}
    local idx = 1
    for i,v in ipairs(MODES) do if v == settings.mode then idx = i; break end end
    local next = (idx % #MODES) + 1
    settings.mode = MODES[next]
    btnMode.Text = "Mode: "..settings.mode
    statusLabel.Text = "Enabled: "..(enabled and "ON" or "OFF").." | ModeActive: "..settings.modeActive.." | Mode: "..settings.mode
end)

btnESP.MouseButton1Click:Connect(function()
    settings.playerESP = not settings.playerESP
    espBtn.Text = settings.playerESP and "ON" or "OFF"
    btnESP.Text = "PlayerESP: "..(settings.playerESP and "ON" or "OFF")
    manageESP()
end)

btnGravity.MouseButton1Click:Connect(function()
    toggleGravityHelper()
end)

-- Bind panel handlers
pullBindBtn.MouseButton1Click:Connect(function() captureKeyFor("pull") end)
pullModeBtn.MouseButton1Click:Connect(function()
    if settings.pullBindMode == "Hold" then settings.pullBindMode = "Toggle"
    elseif settings.pullBindMode == "Toggle" then settings.pullBindMode = "None"
    else settings.pullBindMode = "Hold" end
    pullModeBtn.Text = settings.pullBindMode
    infoLabel.Text = "Pull mode set to "..settings.pullBindMode
end)

autoJumpBtn.MouseButton1Click:Connect(function()
    if settings.autoJump then stopAutoJump() else startAutoJump() end
    autoJumpBtn.Text = settings.autoJump and "ON" or "OFF"
    infoLabel.Text = "AutoJump "..(settings.autoJump and "enabled" or "disabled")
end)

autoJumpBox.FocusLost:Connect(function()
    local n = parseNumber(autoJumpBox.Text)
    if n and n > 0 then settings.autoJumpInterval = n; autoJumpBox.Text = tostring(n)
    else autoJumpBox.Text = tostring(settings.autoJumpInterval) end
end)

modeActiveBtn.MouseButton1Click:Connect(function()
    if settings.modeActive == "Basic" then settings.modeActive = "IdleDelayed"
    elseif settings.modeActive == "IdleDelayed" then settings.modeActive = "Smart"
    elseif settings.modeActive == "Smart" then settings.modeActive = "Advanced"
    else settings.modeActive = "Basic" end
    modeActiveBtn.Text = settings.modeActive
    statusLabel.Text = "Enabled: "..(enabled and "ON" or "OFF").." | ModeActive: "..settings.modeActive.." | Mode: "..settings.mode
    infoLabel.Text = "ModeActive -> "..settings.modeActive
end)

aimHelperBtn.MouseButton1Click:Connect(function()
    settings.aimHelper = not settings.aimHelper
    aimHelperBtn.Text = settings.aimHelper and "ON" or "OFF"
    infoLabel.Text = "Aim helper "..(settings.aimHelper and "enabled" or "disabled")
end)

aimFovBox.FocusLost:Connect(function()
    local n = parseNumber(aimFovBox.Text)
    if n and n > 0 then settings.aimFOV = n; aimFovBox.Text = tostring(n)
    else aimFovBox.Text = tostring(settings.aimFOV) end
end)

espBtn.MouseButton1Click:Connect(function()
    settings.playerESP = not settings.playerESP
    espBtn.Text = settings.playerESP and "ON" or "OFF"
    btnESP.Text = "PlayerESP: "..(settings.playerESP and "ON" or "OFF")
    manageESP()
end)

gravityBtn.MouseButton1Click:Connect(function()
    toggleGravityHelper()
end)

saveBtn.MouseButton1Click:Connect(function()
    local ok, err = pcall(function()
        player:SetAttribute("JP_Settings", HttpService:JSONEncode(settings))
    end)
    if ok then infoLabel.Text = "Settings saved." else infoLabel.Text = "Save failed: "..tostring(err) end
end)

loadBtn.MouseButton1Click:Connect(function()
    local enc = player:GetAttribute("JP_Settings")
    if not enc then infoLabel.Text = "No saved settings." return end
    local ok, dec = pcall(function() return HttpService:JSONDecode(enc) end)
    if not ok or type(dec) ~= "table" then infoLabel.Text = "Load failed (invalid)." return end
    for k,v in pairs(dec) do settings[k] = v end
    -- update UI
    pullBindBtn.Text = settings.pullBind and settings.pullBind.Name or "Not bound"
    pullModeBtn.Text = settings.pullBindMode
    autoJumpBox.Text = tostring(settings.autoJumpInterval)
    autoJumpBtn.Text = settings.autoJump and "ON" or "OFF"
    modeActiveBtn.Text = settings.modeActive
    aimHelperBtn.Text = settings.aimHelper and "ON" or "OFF"
    aimFovBox.Text = tostring(settings.aimFOV)
    espBtn.Text = settings.playerESP and "ON" or "OFF"
    gravityBtn.Text = settings.gravityHelper and "ON" or "OFF"
    btnMode.Text = "Mode: "..settings.mode
    statusLabel.Text = "Enabled: "..(enabled and "ON" or "OFF").." | ModeActive: "..settings.modeActive.." | Mode: "..settings.mode
    infoLabel.Text = "Settings loaded"
    manageESP()
    if settings.gravityHelper then toggleGravityHelper(true) end
end)


pullBindBtn.Text = settings.pullBind and settings.pullBind.Name or "Not bound"
pullModeBtn.Text = settings.pullBindMode
autoJumpBtn.Text = settings.autoJump and "ON" or "OFF"
modeActiveBtn.Text = settings.modeActive
aimHelperBtn.Text = settings.aimHelper and "ON" or "OFF"
aimFovBox.Text = tostring(settings.aimFOV)
espBtn.Text = settings.playerESP and "ON" or "OFF"
gravityBtn.Text = settings.gravityHelper and "ON" or "OFF"
btnMode.Text = "Mode: "..settings.mode
btnAutoJump.Text = "AutoJump: "..(settings.autoJump and "ON" or "OFF")

-- cleanup on GUI destroy
screenGui.AncestryChanged:Connect(function(_, parent)
    if not parent then
        -- clean up highlights, connections, restore gravity
        stopESPLoop()
        toggleGravityHelper(false)
        stopAimLoop()
    end
end)

-- final notice
print("[JumpPull] Feature-complete script loaded. Use Bindings panel to configure. Toggle main enabled with T.")
