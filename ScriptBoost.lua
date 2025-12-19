local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ---------- Defaults ----------
local DEFAULTS = {
    mode = "Velocity", -- "Velocity", "VectorForce", "LinearVelocity", "Impulse"
    speed = 90,
    duration = 0.18,
    smoothing = 8,
    rampTime = 0.06,
    airControl = 0.6,
    strafeStrength = 60,
    cs2Mode = false,
    acceleration = 400,
    maxForce = 1e5,
    impulseStrength = 60,
    maxAirSpeed = 150,
    enableMaxAirSpeed = true,
    alignResponsiveness = 50,
    alignMaxForce = 1e5,
    playerESP = false,
    gravity = (workspace and workspace.Gravity) or 196.2,
    gravityHelper = false,

    -- Aim
    aimHelper = false,
    aimTargetPart = "HumanoidRootPart",
    aimStrength = 0.9,
    aimSpeed = 10,
    aimFOV = 90,
    aimBindMode = "Hold", -- "Hold", "Toggle", "None"
    aimBind = nil,
    aimWallCheck = true,

    -- Pull
    pullBindMode = "Hold", -- "Hold", "Toggle", "None"
    pullBind = nil,

    -- AutoJump
    autoJump = false,
    autoJumpInterval = 0.18,

    -- ModeActive
    modeActive = "Smart", -- "Basic", "IdleDelayed", "Smart", "Advanced"
    idleDelay = 0.5,
    moveThreshold = 0.5,
}

local settings = {}
for k,v in pairs(DEFAULTS) do settings[k] = v end

-- ---------- Utilities ----------
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

local function clamp(x, a, b) return math.clamp(x, a, b) end

-- ---------- Runtime flags ----------
local enabled = true -- main toggle
local pullHoldActive = false
local pullToggleActive = false
local aimToggle = false
local autoJumpRunning = false
local espLoopRunning = false
local originalGlobalGravity = nil
local lastMoveTime = tick()

local highlights = {} -- userId -> {hl, player}
local charState = {} -- Character -> state table

-- find owner id (exclude owner from ESP)
local ownerUserId
pcall(function()
    if type(game.CreatorId) == "number" and game.CreatorId > 0 then ownerUserId = game.CreatorId end
end)

-- ---------- UI ----------
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "JumpPullGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local root = Instance.new("Frame")
root.Name = "JP_Root"
root.Size = UDim2.new(0,420,0,260)
root.Position = UDim2.new(0,12,0,12)
root.BackgroundColor3 = Color3.fromRGB(28,28,28)
root.BorderSizePixel = 0
root.Active = true
root.Draggable = true
root.Parent = screenGui

local title = Instance.new("TextLabel", root)
title.Size = UDim2.new(1, -16, 0, 28)
title.Position = UDim2.new(0,8,0,8)
title.BackgroundTransparency = 1
title.Font = Enum.Font.SourceSansBold
title.TextSize = 18
title.TextColor3 = Color3.fromRGB(240,240,240)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "JumpPull — Full"

local status = Instance.new("TextLabel", root)
status.Size = UDim2.new(1,-16,0,16)
status.Position = UDim2.new(0,8,0,36)
status.BackgroundTransparency = 1
status.Font = Enum.Font.SourceSans
status.TextSize = 14
status.TextColor3 = Color3.fromRGB(200,200,200)
status.TextXAlignment = Enum.TextXAlignment.Left
status.Text = string.format("Enabled: %s | ModeActive: %s | Mode: %s", enabled and "ON" or "OFF", settings.modeActive, settings.mode)

local function makeButton(parent, text, x, y, w)
    local b = Instance.new("TextButton", parent)
    b.Size = UDim2.new(0, w or 140, 0, 32)
    b.Position = UDim2.new(0, x, 0, y)
    b.Font = Enum.Font.SourceSansBold
    b.TextSize = 16
    b.Text = text
    b.BackgroundColor3 = Color3.fromRGB(65,65,65)
    b.TextColor3 = Color3.fromRGB(240,240,240)
    return b
end

local btnToggle = makeButton(root, "Enabled: ON", 8, 64, 128)
local btnBindings = makeButton(root, "Bindings", 148, 64, 128)
local btnAutoJump = makeButton(root, "AutoJump: OFF", 288, 64, 120)
local infoLabel = Instance.new("TextLabel", root)
infoLabel.Size = UDim2.new(1,-16,0,18)
infoLabel.Position = UDim2.new(0,8,0,104)
infoLabel.BackgroundTransparency = 1
infoLabel.Font = Enum.Font.SourceSans
infoLabel.TextSize = 14
infoLabel.TextColor3 = Color3.fromRGB(200,200,200)
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.Text = "Bindings: closed"

local modeBtn = makeButton(root, "Mode: "..settings.mode, 8, 128, 200)
local espBtnQuick = makeButton(root, "ESP: OFF", 220, 128, 180)

local gravityBtnQuick = makeButton(root, "GravityHelper: OFF", 8, 168, 200)

-- Bindings Frame
local bindFrame = Instance.new("Frame")
bindFrame.Name = "BindingsFrame"
bindFrame.Size = UDim2.new(0,360,0,300)
bindFrame.Position = UDim2.new(0,12,0,300)
bindFrame.BackgroundColor3 = Color3.fromRGB(24,24,24)
bindFrame.BorderSizePixel = 0
bindFrame.Active = true
bindFrame.Draggable = true
bindFrame.Parent = screenGui
bindFrame.Visible = false

local function bfLabel(txt, y)
    local l = Instance.new("TextLabel", bindFrame)
    l.Size = UDim2.new(1,-16,0,22)
    l.Position = UDim2.new(0,8,0,y)
    l.BackgroundTransparency = 1
    l.Font = Enum.Font.SourceSans
    l.Text = txt
    l.TextColor3 = Color3.fromRGB(220,220,220)
    l.TextSize = 14
    l.TextXAlignment = Enum.TextXAlignment.Left
    return l
end

bfLabel("Bindings & Quick Settings", 8)

-- Pull bind row
bfLabel("Pull Bind (click then press key; Esc to clear)", 40)
local pullBindBtn = Instance.new("TextButton", bindFrame)
pullBindBtn.Size = UDim2.new(0,140,0,26)
pullBindBtn.Position = UDim2.new(1,-152,0,40)
pullBindBtn.Text = settings.pullBind and settings.pullBind.Name or "Not bound"
pullBindBtn.Font = Enum.Font.SourceSans
pullBindBtn.TextSize = 14

bfLabel("Pull Mode (Hold / Toggle / None)", 74)
local pullModeBtn = Instance.new("TextButton", bindFrame)
pullModeBtn.Size = UDim2.new(0,140,0,26)
pullModeBtn.Position = UDim2.new(1,-152,0,74)
pullModeBtn.Text = settings.pullBindMode
pullModeBtn.Font = Enum.Font.SourceSans
pullModeBtn.TextSize = 14

-- AutoJump
bfLabel("AutoJump ON/OFF (interval seconds)", 108)
local autoJumpToggleBtn = Instance.new("TextButton", bindFrame)
autoJumpToggleBtn.Size = UDim2.new(0,80,0,26)
autoJumpToggleBtn.Position = UDim2.new(1,-236,0,108)
autoJumpToggleBtn.Text = settings.autoJump and "ON" or "OFF"
autoJumpToggleBtn.Font = Enum.Font.SourceSans
autoJumpToggleBtn.TextSize = 14
local autoJumpBox = Instance.new("TextBox", bindFrame)
autoJumpBox.Size = UDim2.new(0,80,0,26)
autoJumpBox.Position = UDim2.new(1,-152,0,108)
autoJumpBox.Text = tostring(settings.autoJumpInterval)
autoJumpBox.Font = Enum.Font.SourceSans
autoJumpBox.TextSize = 14
autoJumpBox.BackgroundColor3 = Color3.fromRGB(32,32,32)
autoJumpBox.TextColor3 = Color3.fromRGB(230,230,230)

-- ModeActive
bfLabel("ModeActive (Basic / IdleDelayed / Smart / Advanced)", 142)
local modeActiveBtn = Instance.new("TextButton", bindFrame)
modeActiveBtn.Size = UDim2.new(0,140,0,26)
modeActiveBtn.Position = UDim2.new(1,-152,0,142)
modeActiveBtn.Text = settings.modeActive
modeActiveBtn.Font = Enum.Font.SourceSans
modeActiveBtn.TextSize = 14

-- Aim helper
bfLabel("Aim Helper ON/OFF (FOV box)", 176)
local aimHelperBtn = Instance.new("TextButton", bindFrame)
aimHelperBtn.Size = UDim2.new(0,80,0,26)
aimHelperBtn.Position = UDim2.new(1,-236,0,176)
aimHelperBtn.Text = settings.aimHelper and "ON" or "OFF"
aimHelperBtn.Font = Enum.Font.SourceSans
aimHelperBtn.TextSize = 14
local aimFovBox = Instance.new("TextBox", bindFrame)
aimFovBox.Size = UDim2.new(0,60,0,26)
aimFovBox.Position = UDim2.new(1,-152,0,176)
aimFovBox.Text = tostring(settings.aimFOV)
aimFovBox.Font = Enum.Font.SourceSans
aimFovBox.TextSize = 14
aimFovBox.BackgroundColor3 = Color3.fromRGB(32,32,32)
aimFovBox.TextColor3 = Color3.fromRGB(230,230,230)

-- ESP / Gravity quick toggles
bfLabel("ESP / Gravity helper", 210)
local espBtn = Instance.new("TextButton", bindFrame)
espBtn.Size = UDim2.new(0,80,0,26)
espBtn.Position = UDim2.new(1,-236,0,210)
espBtn.Text = settings.playerESP and "ON" or "OFF"
espBtn.Font = Enum.Font.SourceSans
espBtn.TextSize = 14
local gravityBtn = Instance.new("TextButton", bindFrame)
gravityBtn.Size = UDim2.new(0,140,0,26)
gravityBtn.Position = UDim2.new(1,-152,0,210)
gravityBtn.Text = settings.gravityHelper and "ON" or "OFF"
gravityBtn.Font = Enum.Font.SourceSans
gravityBtn.TextSize = 14

-- Save / Load
local saveBtn = Instance.new("TextButton", bindFrame)
saveBtn.Size = UDim2.new(0,80,0,28)
saveBtn.Position = UDim2.new(0,12,0,250)
saveBtn.Text = "Save"
saveBtn.Font = Enum.Font.SourceSans
saveBtn.TextSize = 14
local loadBtn = Instance.new("TextButton", bindFrame)
loadBtn.Size = UDim2.new(0,80,0,28)
loadBtn.Position = UDim2.new(0,110,0,250)
loadBtn.Text = "Load"
loadBtn.Font = Enum.Font.SourceSans
loadBtn.TextSize = 14

-- ---------- ESP helpers ----------
local function createHighlightForPlayer(p)
    if not p or p == player then return end
    if ownerUserId and p.UserId == ownerUserId then return end
    local uid = p.UserId
    local rec = highlights[uid]
    if rec and rec.hl and rec.hl.Parent == workspace then
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

local espConn = nil
local function startESPLoop()
    if espLoopRunning then return end
    espLoopRunning = true
    espConn = RunService.Heartbeat:Connect(function()
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
    if espConn then espConn:Disconnect(); espConn = nil end
    for uid,rec in pairs(highlights) do
        pcall(function() if rec.hl then rec.hl:Destroy() end end)
    end
    highlights = {}
end

-- ---------- Gravity helper ----------
local function setGravityHelper(on)
    settings.gravityHelper = (on ~= nil) and on or not settings.gravityHelper
    gravityBtn.Text = settings.gravityHelper and "ON" or "OFF"
    gravityBtnQuick.Text = "GravityHelper: "..(settings.gravityHelper and "ON" or "OFF")
    if settings.gravityHelper then
        if not originalGlobalGravity then pcall(function() originalGlobalGravity = workspace.Gravity end) end
        pcall(function() workspace.Gravity = tonumber(settings.gravity) or DEFAULTS.gravity end)
    else
        if originalGlobalGravity then
            pcall(function() workspace.Gravity = originalGlobalGravity end)
            originalGlobalGravity = nil
        end
    end
    player:SetAttribute("JP_GravityHelper", settings.gravityHelper)
end

-- ---------- Movement tracking ----------
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

-- ---------- Mode gating ----------
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

-- ---------- applyBurst implementations ----------
local function createAttach(basePart)
    local a = Instance.new("Attachment")
    a.Name = "_JP_Att"
    a.Parent = basePart
    return a
end

local function applyBurst(character)
    if not character then return end
    if not allowedByMode(character) or not enabled then return end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local st = charState[character] or {}
    charState[character] = st
    if st._deb then return end
    st._deb = true

    local mode = settings.mode
    if mode == "VectorForce" then
        -- create VectorForce applied via attachment
        local att = createAttach(hrp)
        local vf = Instance.new("VectorForce")
        vf.Name = "_JP_VectorForce"
        vf.Attachment0 = att
        vf.RelativeTo = Enum.ActuatorRelativeTo.World
        vf.ApplyAtCenterOfMass = true
        vf.Parent = hrp

        local look = hrp.CFrame.LookVector
        local forward = Vector3.new(look.X, 0, look.Z)
        if forward.Magnitude == 0 then forward = Vector3.new(0,0,1) end
        forward = forward.Unit
        local desired = forward * (parseNumber(settings.speed) or settings.speed)
        local cur = hrp.Velocity
        local dv = Vector3.new(desired.X - cur.X, 0, desired.Z - cur.Z)
        local mass = 1
        pcall(function() mass = hrp:GetMass() end)
        local force = dv * (mass / math.max(0.016, parseNumber(settings.duration) or settings.duration))
        local mf = parseNumber(settings.maxForce) or settings.maxForce
        if force.Magnitude > mf then force = force.Unit * mf end
        vf.Force = force

        task.delay(parseNumber(settings.duration) or settings.duration, function()
            pcall(function() vf:Destroy() end)
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
        local forward = Vector3.new(look.X, 0, look.Z)
        if forward.Magnitude == 0 then forward = Vector3.new(0,0,1) end
        forward = forward.Unit
        lv.VectorVelocity = forward * (parseNumber(settings.speed) or settings.speed)

        task.delay(parseNumber(settings.duration) or settings.duration, function()
            pcall(function() lv:Destroy() end)
            pcall(function() if a and a.Parent then a:Destroy() end end)
        end)

    elseif mode == "Impulse" then
        local look = hrp.CFrame.LookVector
        local forward = Vector3.new(look.X,0,look.Z)
        if forward.Magnitude == 0 then forward = Vector3.new(0,0,1) end
        forward = forward.Unit
        local mass = 1
        pcall(function() mass = hrp:GetMass() end)
        local imp = forward * (parseNumber(settings.impulseStrength) or settings.impulseStrength) * mass
        pcall(function() if hrp and hrp:IsA("BasePart") then hrp:ApplyImpulse(imp) end end)

    else
        -- Velocity fallback: lerp or set immediate
        local look = hrp.CFrame.LookVector
        local forward = Vector3.new(look.X, 0, look.Z)
        if forward.Magnitude == 0 then forward = Vector3.new(0,0,1) end
        forward = forward.Unit
        local desired = forward * (parseNumber(settings.speed) or settings.speed)
        local cur = hrp.Velocity
        -- smoothing via lerp
        local smooth = parseNumber(settings.smoothing) or settings.smoothing
        local nv = cur:Lerp(Vector3.new(desired.X, cur.Y, desired.Z), clamp((RunService.Heartbeat and RunService.Heartbeat:Wait() or 1/60) * smooth, 0, 1))
        pcall(function() hrp.Velocity = Vector3.new(nv.X, cur.Y, nv.Z) end)
    end

    task.spawn(function()
        task.wait((parseNumber(settings.duration) or settings.duration) + 0.05)
        st._deb = false
    end)
end

-- ---------- attach to character ----------
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
            -- Allow advanced single-use if advanced gating used
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

-- ---------- Pull runner (toggle/hold) ----------
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

-- ---------- AutoJump ----------
local autoJumpThread = nil
local function startAutoJump()
    if autoJumpRunning then return end
    autoJumpRunning = true
    settings.autoJump = true
    autoJumpToggleBtn.Text = "ON"
    btnAutoJump.Text = "AutoJump: ON"
    autoJumpBox.Text = tostring(settings.autoJumpInterval)
    autoJumpThread = task.spawn(function()
        while autoJumpRunning do
            local ch = player.Character
            local humanoid = ch and ch:FindFirstChild("Humanoid")
            if humanoid and humanoid.Health > 0 then
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
    autoJumpToggleBtn.Text = "OFF"
    btnAutoJump.Text = "AutoJump: OFF"
end

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
        local part = entry.part
        local ang = angleToTarget(part.Position)
        if ang <= (settings.aimFOV or 180) then
            local dist = (part.Position - cam.CFrame.Position).Magnitude
            if settings.aimWallCheck and not wallCheck(part) then
                -- skip
            else
                local score = ang + dist * 0.01
                if score < bestScore then best = entry.player; bestScore = score; bestPart = part end
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
        elseif settings.aimBindMode == "Toggle" then aimShouldRun = aimToggle end
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

-- keep aim loop running only when enabled in settings
task.spawn(function()
    while true do
        if settings.aimHelper then startAimLoop() else stopAimLoop() end
        task.wait(0.2)
    end
end)

-- ---------- Bind capture (pull/aim) ----------
local waitingForPullBind = false
local waitingForAimBind = false
local captureConn = nil

local function captureBind(which)
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
            infoLabel.Text = "Pull bind set: "..(settings.pullBind and settings.pullBind.Name or "none")
            if captureConn then captureConn:Disconnect(); captureConn = nil end
        end)
    elseif which == "aim" then
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
            infoLabel.Text = "Aim bind set: "..(settings.aimBind and settings.aimBind.Name or "none")
            if captureConn then captureConn:Disconnect(); captureConn = nil end
        end)
    end
end

-- ---------- Global input handling ----------
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.T then
        enabled = not enabled
        btnToggle.Text = enabled and "Enabled: ON" or "Enabled: OFF"
        status.Text = string.format("Enabled: %s | ModeActive: %s | Mode: %s", enabled and "ON" or "OFF", settings.modeActive, settings.mode)
        return
    end

    if settings.aimBind and input.KeyCode == settings.aimBind then
        if settings.aimBindMode == "Toggle" then aimToggle = not aimToggle end
    end

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

UserInputService.InputEnded:Connect(function(input, gp)
    if gp then return end
    if settings.pullBind and input.KeyCode == settings.pullBind and settings.pullBindMode == "Hold" then
        pullHoldActive = false
    end
end)

-- ---------- UI hooks ----------
btnToggle.MouseButton1Click:Connect(function()
    enabled = not enabled
    btnToggle.Text = enabled and "Enabled: ON" or "Enabled: OFF"
    status.Text = string.format("Enabled: %s | ModeActive: %s | Mode: %s", enabled and "ON" or "OFF", settings.modeActive, settings.mode)
end)

btnBindings.MouseButton1Click:Connect(function()
    bindFrame.Visible = not bindFrame.Visible
    infoLabel.Text = bindFrame.Visible and "Bindings: open" or "Bindings: closed"
end)

btnAutoJump.MouseButton1Click:Connect(function()
    if settings.autoJump then stopAutoJump() else startAutoJump() end
end)

modeBtn.MouseButton1Click:Connect(function()
    local MODES = {"Velocity","VectorForce","LinearVelocity","Impulse"}
    local idx = 1
    for i,v in ipairs(MODES) do if v == settings.mode then idx = i; break end end
    local nextIdx = (idx % #MODES) + 1
    settings.mode = MODES[nextIdx]
    modeBtn.Text = "Mode: "..settings.mode
    status.Text = string.format("Enabled: %s | ModeActive: %s | Mode: %s", enabled and "ON" or "OFF", settings.modeActive, settings.mode)
end)

espBtnQuick.MouseButton1Click:Connect(function()
    settings.playerESP = not settings.playerESP
    espBtnQuick.Text = "ESP: "..(settings.playerESP and "ON" or "OFF")
    espBtn.Text = settings.playerESP and "ON" or "OFF"
    if settings.playerESP then startESPLoop() else stopESPLoop() end
end)

gravityBtnQuick.MouseButton1Click:Connect(function()
    setGravityHelper(not settings.gravityHelper)
end)

pullBindBtn.MouseButton1Click:Connect(function() captureBind("pull") end)
pullModeBtn.MouseButton1Click:Connect(function()
    if settings.pullBindMode == "Hold" then settings.pullBindMode = "Toggle"
    elseif settings.pullBindMode == "Toggle" then settings.pullBindMode = "None"
    else settings.pullBindMode = "Hold" end
    pullModeBtn.Text = settings.pullBindMode
    infoLabel.Text = "Pull mode: "..settings.pullBindMode
end)

autoJumpToggleBtn.MouseButton1Click:Connect(function()
    if settings.autoJump then stopAutoJump() else startAutoJump() end
    autoJumpToggleBtn.Text = settings.autoJump and "ON" or "OFF"
end)
autoJumpBox.FocusLost:Connect(function()
    local n = parseNumber(autoJumpBox.Text)
    if n and n > 0 then settings.autoJumpInterval = n; autoJumpBox.Text = tostring(n) else autoJumpBox.Text = tostring(settings.autoJumpInterval) end
end)

modeActiveBtn.MouseButton1Click:Connect(function()
    if settings.modeActive == "Basic" then settings.modeActive = "IdleDelayed"
    elseif settings.modeActive == "IdleDelayed" then settings.modeActive = "Smart"
    elseif settings.modeActive == "Smart" then settings.modeActive = "Advanced"
    else settings.modeActive = "Basic" end
    modeActiveBtn.Text = settings.modeActive
    status.Text = string.format("Enabled: %s | ModeActive: %s | Mode: %s", enabled and "ON" or "OFF", settings.modeActive, settings.mode)
    infoLabel.Text = "ModeActive -> "..settings.modeActive
end)

aimHelperBtn.MouseButton1Click:Connect(function()
    settings.aimHelper = not settings.aimHelper
    aimHelperBtn.Text = settings.aimHelper and "ON" or "OFF"
    infoLabel.Text = "AimHelper -> "..(settings.aimHelper and "ON" or "OFF")
end)

aimFovBox.FocusLost:Connect(function()
    local n = parseNumber(aimFovBox.Text)
    if n and n > 0 then settings.aimFOV = n; aimFovBox.Text = tostring(n) else aimFovBox.Text = tostring(settings.aimFOV) end
end)

espBtn.MouseButton1Click:Connect(function()
    settings.playerESP = not settings.playerESP
    espBtn.Text = settings.playerESP and "ON" or "OFF"
    espBtnQuick.Text = "ESP: "..(settings.playerESP and "ON" or "OFF")
    if settings.playerESP then startESPLoop() else stopESPLoop() end
end)

gravityBtn.MouseButton1Click:Connect(function()
    setGravityHelper(not settings.gravityHelper)
end)

saveBtn.MouseButton1Click:Connect(function()
    local ok,err = pcall(function()
        player:SetAttribute("JP_Settings", HttpService:JSONEncode(settings))
    end)
    infoLabel.Text = ok and "Saved settings" or ("Save failed: "..tostring(err))
end)

loadBtn.MouseButton1Click:Connect(function()
    local enc = player:GetAttribute("JP_Settings")
    if not enc then infoLabel.Text = "No saved settings"; return end
    local ok, dec = pcall(function() return HttpService:JSONDecode(enc) end)
    if not ok or type(dec) ~= "table" then infoLabel.Text = "Load failed (invalid)"; return end
    for k,v in pairs(dec) do settings[k] = v end
    -- update UI state
    pullBindBtn.Text = settings.pullBind and settings.pullBind.Name or "Not bound"
    pullModeBtn.Text = settings.pullBindMode
    autoJumpToggleBtn.Text = settings.autoJump and "ON" or "OFF"
    autoJumpBox.Text = tostring(settings.autoJumpInterval)
    modeActiveBtn.Text = settings.modeActive
    aimHelperBtn.Text = settings.aimHelper and "ON" or "OFF"
    aimFovBox.Text = tostring(settings.aimFOV)
    espBtn.Text = settings.playerESP and "ON" or "OFF"
    gravityBtn.Text = settings.gravityHelper and "ON" or "OFF"
    modeBtn.Text = "Mode: "..settings.mode
    btnAutoJump.Text = "AutoJump: "..(settings.autoJump and "ON" or "OFF")
    btnToggle.Text = enabled and "Enabled: ON" or "Enabled: OFF"
    infoLabel.Text = "Settings loaded"
    if settings.playerESP then startESPLoop() else stopESPLoop() end
    if settings.gravityHelper then setGravityHelper(true) end
end)

-- ---------- Player events for ESP housekeeping ----------
Players.PlayerRemoving:Connect(function(p) removeHighlightForPlayer(p) end)

Players.PlayerAdded:Connect(function(p)
    p.CharacterAdded:Connect(function(ch)
        task.delay(0.05, function()
            if settings.playerESP and p ~= player and (not ownerUserId or p.UserId ~= ownerUserId) then
                createHighlightForPlayer(p)
                local rec = highlights[p.UserId]
                if rec and rec.hl then pcall(function() rec.hl.Adornee = ch end) end
            end
        end)
    end)
    p.CharacterRemoving:Connect(function()
        local rec = highlights[p.UserId]
        if rec and rec.hl then pcall(function() rec.hl.Adornee = nil end) end
    end)
end)

-- ---------- Cleanup on gui destroy ----------
screenGui.AncestryChanged:Connect(function(_, parent)
    if not parent then
        stopESPLoop()
        setGravityHelper(false)
        stopAimLoop()
    end
end)

