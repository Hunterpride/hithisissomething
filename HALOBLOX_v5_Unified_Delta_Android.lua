-- HALOBLOX v5.0 | Unified / keyless / Android-first diagnostic assistant
-- Built-in Roblox UI, no third-party UI library, no remote code loader.
-- Modes: Pumpkin Finder, Snowman Finder, Pumpkin Assist, Auto Grind, Raid Assist.
-- This script does NOT bypass anti-cheat or discover secret game remotes.
-- IMPORTANT: executor-side actions are not proof that the server accepted hits.
-- If the game doesn't expose observable damage, HALOBLOX reports UNCONFIRMED.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

local player = Players.LocalPlayer
if not player then warn("[HALOBLOX] No LocalPlayer") return end
local playerGui = player:WaitForChild("PlayerGui", 12)
if not playerGui then warn("[HALOBLOX] PlayerGui unavailable") return end

local globals = _G
if type(getgenv) == "function" then
    local ok, env = pcall(getgenv)
    if ok and type(env) == "table" then globals = env end
end
if type(globals.HALOBLOX_V5_CLOSE) == "function" then
    pcall(globals.HALOBLOX_V5_CLOSE)
end
if type(globals.HALOBLOX_V4_STOP) == "function" then
    pcall(globals.HALOBLOX_V4_STOP)
end

local C = {
    background = Color3.fromRGB(12, 17, 29),
    secondary = Color3.fromRGB(24, 33, 52),
    violet = Color3.fromRGB(103, 79, 210),
    orange = Color3.fromRGB(250, 151, 75),
    green = Color3.fromRGB(43, 167, 121),
    red = Color3.fromRGB(193, 67, 82),
    text = Color3.fromRGB(236, 242, 255),
    muted = Color3.fromRGB(173, 185, 212),
}
local MODES = {
    {id="PUMPKINS", title="Pumpkin Finder", label="Highlights nearby pumpkins; no attacks"},
    {id="SNOWMEN", title="Snowman Finder", label="Highlights possible Pumpkin Snowmen"},
    {id="PUMPKIN_ASSIST", title="Pumpkin Assist", label="Walk and attempt hits; confirms object changes"},
    {id="GRIND", title="Auto Grind (experimental)", label="Nearby non-player NPCs only"},
    {id="RAID", title="Raid Assist (experimental)", label="Manual raid start; nearby raid NPCs only"},
}
local S = {
    alive = true,
    running = false,
    mode = "PUMPKINS",
    walk = true,
    attack = true,
    highlight = true,
    scanBusy = false,
    radius = 120,
    count = {pumpkins=0, snowmen=0, npc=0, raid=0},
    attempts = 0,
    confirmed = 0,
    failures = 0,
    lastMethod = "None",
    lastError = "None",
    status = "Ready: choose a mode",
    tracked = {PUMPKINS={}, SNOWMEN={}, GRIND={}, RAID={}},
    cooldown = setmetatable({}, {__mode="k"}),
    highlights = {},
    connections = {},
    history = {},
    epoch = 0,
}
local panel, gui, startButton, statusLabel, infoLabel, logsLabel, modeButtons, walkButton, attackButton, espButton
local function connect(signal, fn)
    local connection = signal:Connect(fn)
    table.insert(S.connections, connection)
    return connection
end
local function log(msg)
    local line = os.date("%H:%M:%S") .. " " .. tostring(msg)
    table.insert(S.history, 1, line)
    if #S.history > 7 then table.remove(S.history) end
    if logsLabel and logsLabel.Parent then logsLabel.Text = table.concat(S.history, "\n") end
    print("[HALOBLOX v5] " .. line)
end
local function status(msg)
    S.status = msg
    if statusLabel and statusLabel.Parent then statusLabel.Text = msg end
end
local function character()
    local c = player.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    local root = c and c:FindFirstChild("HumanoidRootPart")
    if not c or not hum or hum.Health <= 0 or not root then return nil end
    return c, hum, root
end
local function getPart(obj)
    if not obj or not obj.Parent then return nil end
    if obj:IsA("BasePart") then return obj end
    if obj:IsA("Model") then
        return obj.PrimaryPart or obj:FindFirstChild("HumanoidRootPart") or obj:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end
local function isPlayerCharacter(model)
    return model and model:IsA("Model") and Players:GetPlayerFromCharacter(model) ~= nil
end
local function hasWord(name, word)
    return string.find(string.lower(name), word, 1, true) ~= nil
end
local function candidateCategory(obj)
    if not (obj:IsA("Model") or obj:IsA("BasePart")) then return nil end
    local name = obj.Name:lower()
    if name == "pumpkin" or name:match("^pumpkin%d+$") or name:find("jack.o.lantern") then
        return "PUMPKINS"
    end
    if name == "pumpkin snowman" or name:find("snowman", 1, true) then
        return "SNOWMEN"
    end
    if not obj:IsA("Model") or isPlayerCharacter(obj) then return nil end
    if player.Character and obj:IsDescendantOf(player.Character) then return nil end
    local hum = obj:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return nil end
    local a = obj.Parent
    local raidContext = name:find("raid", 1, true) or name:find("boss", 1, true)
    for _ = 1, 3 do
        if a and (hasWord(a.Name, "raid") or hasWord(a.Name, "island")) then raidContext = true end
        a = a and a.Parent
    end
    if raidContext then return "RAID" end
    return "GRIND"
end
local function normalized(obj)
    if obj:IsA("BasePart") then
        local parent = obj.Parent
        if parent and parent:IsA("Model") and candidateCategory(parent) == candidateCategory(obj) then
            return parent
        end
    end
    return obj
end
local function index(obj)
    if not S.alive then return end
    local group = candidateCategory(obj)
    if group then
        local target = normalized(obj)
        S.tracked[group][target] = true
    end
end
local function scan()
    if S.scanBusy or not S.alive then return end
    S.scanBusy = true
    local ok, err = pcall(function()
        local descendants = Workspace:GetDescendants()
        local added = 0
        for i, obj in ipairs(descendants) do
            if not S.alive then break end
            local group = candidateCategory(obj)
            if group then
                local n = normalized(obj)
                if not S.tracked[group][n] then
                    S.tracked[group][n] = true
                    added = added + 1
                end
            end
            if i % 280 == 0 then task.wait() end
        end
        if S.alive then log("Scan complete: " .. added .. " candidates indexed") end
    end)
    S.scanBusy = false
    if not ok and S.alive then
        S.lastError = tostring(err)
        log("Scan recovered from error: " .. S.lastError)
    end
end
local function validTarget(obj, group)
    if not obj or not obj.Parent then return false end
    if group == "GRIND" or group == "RAID" then
        if not obj:IsA("Model") or isPlayerCharacter(obj) then return false end
        local h = obj:FindFirstChildOfClass("Humanoid")
        return h ~= nil and h.Health > 0
    end
    return true
end
local function nearby(group, radius, maxResults)
    local _, _, root = character()
    if not root then return {} end
    local result = {}
    local now = os.clock()
    for obj in pairs(S.tracked[group]) do
        if not validTarget(obj, group) then
            S.tracked[group][obj] = nil
        else
            local p = getPart(obj)
            if p and p.Parent then
                local delta = p.Position - root.Position
                local d = Vector3.new(delta.X, 0, delta.Z).Magnitude
                if d <= radius and math.abs(delta.Y) < 45 and now >= (S.cooldown[obj] or 0) then
                    table.insert(result, {obj=obj, part=p, d=d})
                end
            end
        end
    end
    table.sort(result, function(a,b) return a.d < b.d end)
    while #result > maxResults do result[#result] = nil end
    return result
end
local function clearHighlights()
    for obj, h in pairs(S.highlights) do
        pcall(function() h:Destroy() end)
        S.highlights[obj] = nil
    end
end
local function highlight(group)
    if not S.highlight then clearHighlights() return end
    local list = nearby(group, math.max(S.radius, 200), 12)
    local keep = {}
    for _, target in ipairs(list) do
        local obj = target.obj
        keep[obj] = true
        if not S.highlights[obj] or not S.highlights[obj].Parent then
            local ok, h = pcall(function()
                local marker = Instance.new("Highlight")
                marker.Name = "HALOBLOX_V5_Target"
                marker.Adornee = obj
                marker.FillColor = group == "SNOWMEN" and Color3.fromRGB(124, 210, 250) or C.orange
                marker.OutlineColor = Color3.fromRGB(255,255,255)
                marker.FillTransparency = 0.72
                marker.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                marker.Parent = obj
                return marker
            end)
            if ok then S.highlights[obj] = h end
        end
    end
    for obj, h in pairs(S.highlights) do
        if not keep[obj] then
            pcall(function() h:Destroy() end)
            S.highlights[obj] = nil
        end
    end
end
local function equippedTool()
    local c = player.Character
    if not c then return nil end
    for _, child in ipairs(c:GetChildren()) do
        if child:IsA("Tool") then return child end
    end
    return nil
end
local function equipTool()
    local tool = equippedTool()
    if tool then return tool end
    local _, hum = character()
    local backpack = player:FindFirstChildOfClass("Backpack")
    if not hum or not backpack then return nil end
    for _, child in ipairs(backpack:GetChildren()) do
        if child:IsA("Tool") then
            pcall(function() hum:EquipTool(child) end)
            task.wait(0.08)
            return equippedTool()
        end
    end
    return nil
end
local function sendAttack(method)
    local cam = Workspace.CurrentCamera
    if method == 1 then
        local tool = equipTool()
        if not tool then return false, "No equipped Roblox Tool" end
        local ok = pcall(function() tool:Activate() end)
        return ok, "Tool:Activate"
    elseif method == 2 then
        if type(mouse1click) ~= "function" then return false, "mouse1click unavailable" end
        return pcall(mouse1click), "mouse1click"
    elseif method == 3 then
        if not cam then return false, "Camera missing" end
        local okService, vim = pcall(function() return game:GetService("VirtualInputManager") end)
        if not okService or not vim then return false, "VirtualInputManager unavailable" end
        local vp = cam.ViewportSize
        local ok = pcall(function()
            vim:SendMouseButtonEvent(vp.X/2, vp.Y/2, 0, true, game, 0)
            task.wait(0.045)
            vim:SendMouseButtonEvent(vp.X/2, vp.Y/2, 0, false, game, 0)
        end)
        return ok, "VIM mouse"
    elseif method == 4 then
        if not cam then return false, "Camera missing" end
        local vp = cam.ViewportSize
        local ok = pcall(function()
            local xy = Vector2.new(vp.X/2, vp.Y/2)
            VirtualUser:Button1Down(xy, cam.CFrame)
            task.wait(0.045)
            VirtualUser:Button1Up(xy, cam.CFrame)
        end)
        return ok, "VirtualUser mouse"
    end
    return false, "No method"
end
local function face(pos)
    local _, _, root = character()
    if not root then return end
    local flat = Vector3.new(pos.X, root.Position.Y, pos.Z)
    if (flat - root.Position).Magnitude > 0.1 then
        pcall(function() root.CFrame = CFrame.lookAt(root.Position, flat) end)
    end
end
local function walkNear(pos, epoch)
    local _, hum, root = character()
    if not hum or not root then return false, "character not ready" end
    local diff = Vector3.new(pos.X-root.Position.X, 0, pos.Z-root.Position.Z)
    if diff.Magnitude <= 7 then return true, "already nearby" end
    if not S.walk then return false, "walking OFF; get closer manually" end
    if diff.Magnitude > S.radius then return false, "outside travel radius" end
    local goal = Vector3.new(pos.X, root.Position.Y, pos.Z) - diff.Unit*5
    local accepted = pcall(function() hum:MoveTo(goal) end)
    if not accepted then return false, "MoveTo unavailable" end
    local start = os.clock()
    local lastProgress = start
    local best = diff.Magnitude
    while S.alive and S.running and epoch == S.epoch and os.clock()-start < 5 do
        local _, h, r = character()
        if not h or not r then return false, "character lost" end
        local d = Vector3.new(pos.X-r.Position.X, 0, pos.Z-r.Position.Z).Magnitude
        if d <= 7 then return true, "arrived" end
        if d < best-0.6 then
            best = d
            lastProgress = os.clock()
        elseif os.clock()-lastProgress > 1.6 then
            return false, "no walking progress (blocked?)"
        end
        task.wait(0.12)
    end
    return false, "walk cancelled or timed out"
end
local function targetChanged(target, beforeTransparency, beforeHP)
    if not target.obj.Parent or not target.part.Parent then return true, "object removed" end
    if beforeTransparency < 0.9 and target.part.Transparency >= 0.98 then
        return true, "object hidden"
    end
    if beforeHP then
        local h = target.obj:FindFirstChildOfClass("Humanoid")
        if h and h.Health < beforeHP then return true, "target HP decreased" end
    end
    return false, "no observable change"
end
local function attackTarget(target, group, epoch)
    if not target.obj.Parent or not target.part.Parent then return false, "target vanished" end
    if not S.attack then return false, "auto-attack OFF" end
    local tool = equipTool()
    if not tool then return false, "equip a fighting style or Tool first" end
    local h = target.obj:IsA("Model") and target.obj:FindFirstChildOfClass("Humanoid") or nil
    local oldHP = h and h.Health or nil
    local oldTransparency = target.part.Transparency
    if panel and panel.Parent then panel.Visible = false end -- do not intercept center attacks
    local anySent = false
    for i=1, 6 do
        if not S.running or not S.alive or epoch ~= S.epoch then break end
        if not target.obj.Parent or not target.part.Parent then break end
        face(target.part.Position)
        local sent, method = sendAttack((i - 1)%4 + 1)
        S.lastMethod = method
        S.attempts = S.attempts + 1
        if sent then anySent = true end
        task.wait(0.19)
        local changed, reason = targetChanged(target, oldTransparency, oldHP)
        if changed then
            if group == "PUMPKINS" and reason == "object removed" then
                S.confirmed = S.confirmed + 1
            end
            -- HP loss confirms hit, not a kill; never count as boss defeated.
            return true, reason
        end
    end
    return false, anySent and ("input sent, no observed damage (" .. S.lastMethod .. ")")
        or "no supported attack input"
end
local function stop()
    S.running = false
    S.epoch = S.epoch + 1
    -- Stop the outstanding MoveTo request as well as the worker.
    local _, hum, root = character()
    if hum and root then pcall(function() hum:MoveTo(root.Position) end) end
    if startButton and startButton.Parent then
        startButton.Text = "START SELECTED MODE"
        startButton.BackgroundColor3 = C.green
    end
    status("Stopped")
end
local function close()
    if not S.alive then return end
    S.alive = false
    stop()
    clearHighlights()
    for _, conn in ipairs(S.connections) do pcall(function() conn:Disconnect() end) end
    if gui then pcall(function() gui:Destroy() end) end
    if globals.HALOBLOX_V5_CLOSE == close then globals.HALOBLOX_V5_CLOSE = nil end
end
globals.HALOBLOX_V5_CLOSE = close

local function corner(parent, px)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, px or 9)
    c.Parent = parent
end
local function label(parent, value, h, fontSize, color)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1,-18,0,h)
    l.BackgroundTransparency = 1
    l.Text = value
    l.TextColor3 = color or C.text
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Center
    l.TextWrapped = true
    l.Font = Enum.Font.Gotham
    l.TextSize = fontSize or 12
    l.Parent = parent
    return l
end
local function button(parent, value, color, h, cb)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1,-18,0,h or 37)
    b.BackgroundColor3 = color or C.secondary
    b.BorderSizePixel = 0
    b.TextColor3 = C.text
    b.Font = Enum.Font.GothamBold
    b.TextSize = 12
    b.Text = value
    b.Parent = parent
    corner(b, 8)
    connect(b.MouseButton1Click, cb)
    return b
end
local function buildUI()
    gui = Instance.new("ScreenGui")
    gui.Name = "HALOBLOX_V5_UNIFIED"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 230
    gui.Parent = playerGui
    panel = Instance.new("Frame")
    panel.AnchorPoint = Vector2.new(0.5,0.5)
    panel.Size = UDim2.new(0.88,0,0.72,0)
    panel.Position = UDim2.new(0.5,0,0.49,0)
    panel.BackgroundColor3 = C.background
    panel.BorderSizePixel = 0
    panel.Parent = gui
    corner(panel, 13)
    local constraint = Instance.new("UISizeConstraint")
    constraint.MinSize = Vector2.new(265,300)
    constraint.MaxSize = Vector2.new(405,555)
    constraint.Parent = panel
    local outline = Instance.new("UIStroke")
    outline.Color = C.violet
    outline.Thickness = 2
    outline.Parent = panel

    local top = Instance.new("Frame")
    top.Size = UDim2.new(1,0,0,43)
    top.BackgroundColor3 = C.secondary
    top.Parent = panel
    corner(top, 13)
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1,-93,1,0)
    title.Position = UDim2.new(0,11,0,0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = C.orange
    title.Text = "HALOBLOX 5 | UNIFIED"
    title.Parent = top
    local hide = Instance.new("TextButton")
    hide.Size = UDim2.new(0,33,0,33)
    hide.Position = UDim2.new(1,-76,0,5)
    hide.BackgroundColor3 = C.violet
    hide.TextColor3 = C.text
    hide.Text = "-"
    hide.TextSize = 22
    hide.Parent = top
    corner(hide,8)
    local x = Instance.new("TextButton")
    x.Size = UDim2.new(0,33,0,33)
    x.Position = UDim2.new(1,-39,0,5)
    x.BackgroundColor3 = C.red
    x.TextColor3 = C.text
    x.Text = "X"
    x.Font = Enum.Font.GothamBold
    x.Parent = top
    corner(x,8)
    connect(hide.MouseButton1Click, function() panel.Visible = false end)
    connect(x.MouseButton1Click, close)

    local scroller = Instance.new("ScrollingFrame")
    scroller.Size = UDim2.new(1,0,1,-43)
    scroller.Position = UDim2.new(0,0,0,43)
    scroller.BackgroundTransparency = 1
    scroller.BorderSizePixel = 0
    scroller.ScrollBarThickness = 4
    scroller.CanvasSize = UDim2.new(0,0,0,0)
    scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroller.Parent = panel
    local layout = Instance.new("UIListLayout")
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.Padding = UDim.new(0,5)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = scroller
    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0,9)
    pad.PaddingBottom = UDim.new(0,12)
    pad.Parent = scroller

    statusLabel = label(scroller,"Ready",36,12,C.orange)
    infoLabel = label(scroller,"Waiting for first scan...",44,11,C.muted)
    modeButtons = {}
    for _, option in ipairs(MODES) do
        local b
        b = button(scroller, (S.mode == option.id and "[SELECTED] " or "") .. option.title, C.secondary, 35, function()
            stop()
            S.mode = option.id
            for _, entry in ipairs(MODES) do
                local bb = modeButtons[entry.id]
                if bb then
                    bb.Text = (S.mode == entry.id and "[SELECTED] " or "") .. entry.title
                    bb.BackgroundColor3 = S.mode == entry.id and C.violet or C.secondary
                end
            end
            clearHighlights()
            status(option.label)
        end)
        b.BackgroundColor3 = S.mode == option.id and C.violet or C.secondary
        modeButtons[option.id] = b
    end
    startButton = button(scroller,"START SELECTED MODE",C.green,44,function()
        if S.running then
            stop()
            log("Mode stopped")
        else
            S.running = true
            S.epoch = S.epoch + 1
            startButton.Text = "STOP / EMERGENCY STOP"
            startButton.BackgroundColor3 = C.red
            status("Running " .. S.mode)
            log("Started " .. S.mode)
            if S.mode == "PUMPKIN_ASSIST" or S.mode == "GRIND" or S.mode == "RAID" then
                panel.Visible = false
            end
        end
    end)
    walkButton = button(scroller,"WALK: ON (no teleports)",C.secondary,33,function()
        S.walk = not S.walk
        walkButton.Text = "WALK: " .. (S.walk and "ON" or "OFF")
    end)
    attackButton = button(scroller,"ATTACK ATTEMPTS: ON",C.secondary,33,function()
        S.attack = not S.attack
        attackButton.Text = "ATTACK ATTEMPTS: " .. (S.attack and "ON" or "OFF")
    end)
    espButton = button(scroller,"TARGET HIGHLIGHTS: ON",C.secondary,33,function()
        S.highlight = not S.highlight
        espButton.Text = "TARGET HIGHLIGHTS: " .. (S.highlight and "ON" or "OFF")
        if not S.highlight then clearHighlights() end
    end)
    local radiusButton
    local presets = {60,120,200}
    radiusButton = button(scroller,"SEARCH / WALK RADIUS: 120 STUDS",C.secondary,33,function()
        local ix=1
        for i,d in ipairs(presets) do if S.radius == d then ix = i break end end
        S.radius = presets[ix%#presets+1]
        radiusButton.Text = "SEARCH / WALK RADIUS: " .. S.radius .. " STUDS"
    end)
    button(scroller,"REFRESH SEARCH",C.violet,33,function()
        task.spawn(scan)
        log("Manual refresh requested")
    end)
    button(scroller,"STOP EVERYTHING",C.red,35,function()
        stop()
        clearHighlights()
        log("Emergency stop")
    end)
    logsLabel = label(scroller,"Starting...",117,10,C.muted)
    logsLabel.TextYAlignment = Enum.TextYAlignment.Top
    label(scroller,"Raid Assist will NOT start raids; Pumpkin/Snowman matches are candidates, not validated event rewards.",57,10,C.muted)

    local float = Instance.new("TextButton")
    float.Size = UDim2.new(0,54,0,54)
    float.Position = UDim2.new(0,9,0.45,0)
    float.BackgroundColor3 = C.violet
    float.Text = "HB"
    float.TextSize = 16
    float.Font = Enum.Font.GothamBold
    float.TextColor3 = C.text
    float.Parent = gui
    corner(float,13)
    connect(float.MouseButton1Click,function() panel.Visible = not panel.Visible end)

    -- Touch + mouse title bar dragging
    local dragging, origin, begin
    connect(top.InputBegan,function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging=true
            origin=input.Position
            begin=panel.Position
        end
    end)
    connect(UserInputService.InputChanged,function(input)
        if dragging and origin and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement) then
            local delta=input.Position-origin
            panel.Position=UDim2.new(begin.X.Scale,begin.X.Offset+delta.X,begin.Y.Scale,begin.Y.Offset+delta.Y)
        end
    end)
    connect(UserInputService.InputEnded,function(input)
        if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging=false
        end
    end)
end

local function workCycle(epoch)
    local group = (S.mode == "PUMPKIN_ASSIST" or S.mode == "PUMPKINS") and "PUMPKINS"
        or S.mode == "SNOWMEN" and "SNOWMEN"
        or S.mode == "RAID" and "RAID" or "GRIND"
    local targets = nearby(group,S.radius,8)
    local t = targets[1]
    if not t then
        status("No nearby " .. group .. " candidates; move near visible targets")
        task.wait(1)
        return
    end
    highlight(group)
    if S.mode == "PUMPKINS" or S.mode == "SNOWMEN" then
        status("Found " .. t.obj.Name .. " at ~" .. math.floor(t.d) .. " studs")
        task.wait(0.8)
        return
    end
    status("Approaching: " .. t.obj.Name .. " (" .. math.floor(t.d) .. "st)")
    local reached, why = walkNear(t.part.Position, epoch)
    if not S.alive or not S.running or epoch ~= S.epoch then return end
    if not reached then
        S.cooldown[t.obj] = os.clock()+8
        S.failures = S.failures+1
        status("Movement: " .. why)
        task.wait(0.3)
        return
    end
    local success, reason = attackTarget(t,group,epoch)
    if success then
        status("Observed: " .. reason .. " | " .. t.obj.Name)
        log("Observed " .. reason .. " for " .. t.obj.Name)
        S.cooldown[t.obj] = os.clock()+3
    else
        if not S.running or not S.alive or epoch~=S.epoch then return end
        S.failures = S.failures+1
        S.cooldown[t.obj] = os.clock()+13
        status("Unconfirmed: " .. reason)
        log("Skipped " .. t.obj.Name .. ": " .. reason)
    end
    task.wait(0.3)
end

buildUI()
log("Unified v5 loaded; no key or external library required")
log("No forced long-distance teleport or remote guessing")
connect(Workspace.DescendantAdded,index)
connect(Workspace.DescendantRemoving,function(obj)
    for _,group in pairs(S.tracked) do group[obj]=nil end
end)
connect(player.CharacterAdded,function()
    S.cooldown = setmetatable({}, {__mode="k"})
    status("Respawning - ready when character loads")
end)
task.spawn(scan)

-- Separate, resilient workers: avoid render-step world scans and stackable loops.
task.spawn(function()
    while S.alive do
        if S.running then
            local epoch = S.epoch
            local ok,err = pcall(workCycle,epoch)
            if not ok then
                S.lastError = tostring(err)
                S.failures = S.failures+1
                log("Caught cycle error: " .. S.lastError)
                task.wait(1.2)
            end
        else
            task.wait(0.35)
        end
    end
end)
task.spawn(function()
    while S.alive do
        local group = (S.mode == "PUMPKIN_ASSIST" or S.mode == "PUMPKINS") and "PUMPKINS"
            or S.mode == "SNOWMEN" and "SNOWMEN" or S.mode == "RAID" and "RAID" or "GRIND"
        local ok,err = pcall(function()
            local near = nearby(group,math.max(200,S.radius),14)
            if S.highlight then highlight(group) else clearHighlights() end
            if infoLabel and infoLabel.Parent then
                infoLabel.Text = string.format("Mode: %s | Visible candidates: %d | Scan: %s\nAttempts: %d | Confirmed removed: %d | Skips: %d",
                    S.mode,#near,S.scanBusy and "busy" or "idle",S.attempts,S.confirmed,S.failures)
            end
        end)
        if not ok then S.lastError=tostring(err) end
        task.wait(1.0)
    end
end)
task.spawn(function()
    while S.alive do
        task.wait(75)
        if S.alive then scan() end
    end
end)
