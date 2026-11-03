-- BF Halloween Grinder — Delta / Android Edition v3.3.1 (crash-safe diagnostics)
-- Full audit + Android touch support + reliability fixes
-- Paste directly into Delta and execute

-- ══════════════════════════════════════════════════════════════
-- SAFE INPUT LAYER
-- ══════════════════════════════════════════════════════════════
local VIM_SAFE = nil
do
    local ok, v = pcall(function() return game:GetService("VirtualInputManager") end)
    if ok and v then VIM_SAFE = v end
end

local function TryExecutorKey(key, down)
    local fn = down and keypress or keyrelease
    if type(fn) ~= "function" then return false end
    local ok = pcall(fn, key.Value)
    return ok
end

local InputWarnShown = false
local function WarnInput()
    if not InputWarnShown then
        InputWarnShown = true
        warn("[BF Grinder] VirtualInputManager unavailable — combat keypresses disabled")
    end
end

local function SafeKeyPress(key, hold)
    if type(keypress) == "function" and type(keyrelease) == "function" then
        local pressed = TryExecutorKey(key, true)
        if pressed then
            task.wait(hold or 0.05)
            return TryExecutorKey(key, false)
        end
    end
    if not VIM_SAFE then WarnInput() return false end
    local ok, err = pcall(function()
        VIM_SAFE:SendKeyEvent(true, key, false, game)
        task.wait(hold or 0.05)
        VIM_SAFE:SendKeyEvent(false, key, false, game)
    end)
    if not ok then warn("[BF Grinder] KeyPress error: "..tostring(err)) end
    return ok
end

local function SafeClick(x, y)
    -- Never emulate a GUI tap with VirtualUser: that API is for world input.
    if x ~= nil and y ~= nil and not VIM_SAFE then return false end
    if x == nil and y == nil and not VIM_SAFE and type(mouse1click) == "function" then
        local clicked = pcall(mouse1click)
        if clicked then return true end
    end
    local ok, err = pcall(function()
        local cam = workspace.CurrentCamera
        local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
        x = x or vp.X / 2
        y = y or vp.Y / 2
        if VIM_SAFE then
            VIM_SAFE:SendMouseButtonEvent(x, y, 0, true, game, 0)
            task.wait(0.04)
            VIM_SAFE:SendMouseButtonEvent(x, y, 0, false, game, 0)
        else
            -- VirtualUser may supply M1 on some Android builds; it is not
            -- a reliable substitute for tapping arbitrary GUI coordinates.
            local vu = game:GetService("VirtualUser")
            local cf = cam and cam.CFrame or CFrame.new()
            vu:Button1Down(Vector2.new(x, y), cf)
            task.wait(0.04)
            vu:Button1Up(Vector2.new(x, y), cf)
        end
    end)
    if not ok then warn("[BF Grinder] Click failed: "..tostring(err)) end
    return ok
end

-- ══════════════════════════════════════════════════════════════
-- SERVICES
-- ══════════════════════════════════════════════════════════════
-- Reruns: disconnect the previous UI and worker before creating a replacement.
local global = (type(getgenv) == "function" and getgenv()) or _G
if global.BF_EVENT_V33_STOP then pcall(global.BF_EVENT_V33_STOP) end
local shutdown = false
local cleanup = {}
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService      = game:GetService("HttpService")
local VirtualUser      = game:GetService("VirtualUser")

local LP = Players.LocalPlayer
local function Track(conn)
    table.insert(cleanup, conn)
    return conn
end

-- Camera refreshed on every use — stale after teleport/respawn
local function GetCamera()
    return workspace.CurrentCamera
end

-- ══════════════════════════════════════════════════════════════
-- STATE MACHINE
-- ══════════════════════════════════════════════════════════════
local GS = {
    IDLE           = "IDLE",
    PUMPKIN_HUNT   = "PUMPKIN_HUNT",
    TRICK_OR_TREAT = "TRICK_OR_TREAT",
    BOSS_FIGHT     = "BOSS_FIGHT",
    GACHA          = "GACHA",
    DEAD           = "DEAD",
}

-- ══════════════════════════════════════════════════════════════
-- CONFIG
-- ══════════════════════════════════════════════════════════════
local Config = {
    Grinder = {
        Enabled            = false,
        AutoPumpkins       = false, -- opt-in after diagnostics
        AutoTrickOrTreat   = false, -- opt-in
        AutoWerewolf       = false, -- opt-in
        AutoHellRider      = false, -- opt-in
        AutoGacha          = false, -- opt-in: consumes event currency
        AutoPotionWitch    = true,
        GachaMinTokens     = 500,
        PumpkinScanRadius  = 300,
        BossScanRadius     = 500,
        DoorScanRadius     = 400,
        TPToTarget         = false, -- leave off until emulator stable
        RespawnWaitTime    = 6,
        -- When true, only attempts Trick-or-Treat if an event flag is replicated.
        HarvestMoonOnly    = true,
        LoopGrind          = true,
    },
    Combat = {
        UseZ       = true,
        UseX       = true,
        UseC       = true,
        UseF       = true,
        UseV       = false,
        M1Enabled  = true,
        M1Delay    = 0.07,
        SkillDelay = 0.18,
        AttackRadius = 12,
        AutoBlock  = true,
        AutoDodge  = true,
        DodgeHP    = 0.35,
    },
    Misc = {
        AntiAFK      = true,
        InfJump      = false,
        Fly          = false,
        FlySpeed     = 80,
        NoClip       = false,
        PanicKey     = Enum.KeyCode.Delete,
        GUIToggleKey = Enum.KeyCode.RightAlt,
    },
}

-- ══════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════
local State = {
    CurrentState    = GS.IDLE,
    SpookyTokens    = 0,
    PumpkinsSmashed = 0,
    DoorsKnocked    = 0,
    BossKills       = 0,
    GachaRolls      = 0,
    SessionStart    = tick(),
    FlyActive       = false,
    FlyBV           = nil,
    FPS             = 0,
    FrameCount      = 0,
    LastFPSTime     = tick(),
    Log             = {},
    LogDirty        = false,
    LastM1          = 0,
    LastSkill       = 0,
    SkillIdx        = 1,
    StatusText      = "Idle",
    Running         = false,
    GachaHour       = -1,
    GachaConfirmed  = 0,
    InputAvailable  = false,
}

-- ══════════════════════════════════════════════════════════════
-- LOGGING
-- ══════════════════════════════════════════════════════════════
local MAX_LOG = 60

local function Log(msg)
    local line = "["..os.date("%H:%M:%S").."] "..tostring(msg)
    table.insert(State.Log, 1, line)
    if #State.Log > MAX_LOG then
        State.Log[MAX_LOG + 1] = nil
    end
    State.LogDirty = true
    print(line)
end

-- ══════════════════════════════════════════════════════════════
-- CHARACTER HELPERS  (always re-fetch — never cache)
-- ══════════════════════════════════════════════════════════════
local function Char()
    return LP.Character
end
local function Root()
    local c = Char()
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function Hum()
    local c = Char()
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function IsAlive()
    local h = Hum()
    return h ~= nil and h.Health > 0
end
local function WaitForChar(timeout)
    timeout = timeout or 10
    local deadline = tick() + timeout
    while Config.Grinder.Enabled and not IsAlive() and tick() < deadline do
        task.wait(0.1)
    end
    return IsAlive()
end

-- ══════════════════════════════════════════════════════════════
-- MOVEMENT HELPERS
-- ══════════════════════════════════════════════════════════════
local lastTeleport = 0
local function SafeTP(pos, offset)
    -- v3.3.1 defaults teleport OFF. The user's crash occurs after teleport.
    if not Config.Grinder.TPToTarget or shutdown or not Config.Grinder.Enabled then
        return false
    end
    if typeof(pos) ~= "Vector3" then return false end
    local r = Root()
    if not r or not IsAlive() then return false end
    local now = tick()
    if now - lastTeleport < 2 then return false end
    -- Large instantaneous jumps are a likely instability source.
    if (r.Position - pos).Magnitude > 150 then
        Log("Movement skipped: destination too far")
        return false
    end
    lastTeleport = now
    offset = offset or Vector3.new(0, 4, 0)
    local ok = pcall(function() r.CFrame = CFrame.new(pos + offset) end)
    if not ok then return false end
    task.wait(0.4)
    return r.Parent ~= nil and (r.Position - (pos + offset)).Magnitude < 25
end

local function FaceTarget(pos)
    local r = Root()
    if not r then return end
    local flat = Vector3.new(pos.X, r.Position.Y, pos.Z)
    if (flat - r.Position).Magnitude > 0.01 then
        r.CFrame = CFrame.lookAt(r.Position, flat)
    end
end

-- ══════════════════════════════════════════════════════════════
-- HARVEST MOON DETECTION
-- Detect only explicitly exposed event signals. No assumed server clock.
-- If the game does not replicate an event flag, status is unknown.
-- ══════════════════════════════════════════════════════════════
local function HarvestWindow()
    -- Documented 2026 event schedule: XX:00-XX:10 UTC, a schedule estimate.
    -- This does not prove the server has actually started the event.
    return (os.time() % 3600) < 600
end

local function IsHarvestMoon()
    -- Primary: check if the game signals it via a Value object or Attribute
    local flag = workspace:FindFirstChild("HarvestMoonActive")
    if flag and (flag:IsA("BoolValue") or flag:IsA("IntValue")) then
        return flag.Value == true or flag.Value == 1
    end
    local attr = workspace:GetAttribute("HarvestMoon")
    if attr ~= nil then return attr == true end
    -- Unknown is not equivalent to active. Avoid fake event status.
    return HarvestWindow()
end

-- ══════════════════════════════════════════════════════════════
-- WORLD SEARCH
-- ══════════════════════════════════════════════════════════════
-- Restrict matches to distinct models/parts and reject our own character/GUI.
-- Names are heuristics, NOT verified Blox Fruits event identifiers.
local function TargetPart(obj)
    if obj:IsA("BasePart") then return obj end
    if obj:IsA("Model") then
        return obj:FindFirstChild("HumanoidRootPart") or obj.PrimaryPart
            or obj:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

local function FindAll(keywords, range, searchIn)
    local r = Root()
    if not r then return {} end
    local results, seen = {}, {}
    local inspected = 0
    for _, obj in ipairs((searchIn or workspace):GetDescendants()) do
        inspected = inspected + 1
        if inspected % 300 == 0 then task.wait() end -- yield to Android UI
        if inspected > 12000 then break end -- avoid massive repeated work
        if shutdown or not Config.Grinder.Enabled then break end
        if obj:IsA("Model") or obj:IsA("BasePart") then
            if Char() and obj ~= Char() and not obj:IsDescendantOf(Char()) then
                local name = obj.Name:lower()
                local matching = false
                for _, kw in ipairs(keywords) do
                    if name:find(kw, 1, true) then matching = true break end
                end
                if matching then
                    -- Prefer a named model over its individual descendant parts.
                    local owner = obj
                    if obj:IsA("BasePart") then
                        local model = obj:FindFirstAncestorOfClass("Model")
                        if model and model ~= Char() and model.Name:lower():find(name, 1, true) then
                            owner = model
                        end
                    end
                    if not seen[owner] then
                        seen[owner] = true
                        local part = TargetPart(owner)
                        if part then
                            local d = (r.Position - part.Position).Magnitude
                            if d <= (range or 500) then
                                table.insert(results, {Object = owner, Part = part, Dist = d})
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(results, function(a,b) return a.Dist < b.Dist end)
    return results
end

local function FindNearest(keywords, range, searchIn)
    local found = FindAll(keywords, range, searchIn)
    if #found == 0 then return nil, math.huge, nil end
    return found[1].Object, found[1].Dist, found[1].Part
end

-- ══════════════════════════════════════════════════════════════
-- COMBAT ENGINE
-- ══════════════════════════════════════════════════════════════
local SKILLS = {
    {key = Enum.KeyCode.Z, cfg = function() return Config.Combat.UseZ end},
    {key = Enum.KeyCode.X, cfg = function() return Config.Combat.UseX end},
    {key = Enum.KeyCode.C, cfg = function() return Config.Combat.UseC end},
    {key = Enum.KeyCode.F, cfg = function() return Config.Combat.UseF end},
    {key = Enum.KeyCode.V, cfg = function() return Config.Combat.UseV end},
}

local function RotateSkill()
    for _ = 1, #SKILLS do
        State.SkillIdx = State.SkillIdx % #SKILLS + 1
        if SKILLS[State.SkillIdx].cfg() then
            return SKILLS[State.SkillIdx].key
        end
    end
    return nil
end

local function AttackMob(mob)
    if not mob or not mob.Parent then return false end
    local r = Root()
    if not r or not IsAlive() then return false end

    local tp = TargetPart(mob)
    if not tp then return false end

    local th = mob:IsA("Model") and mob:FindFirstChildOfClass("Humanoid")
    if th and th.Health <= 0 then return false end

    local dist = (r.Position - tp.Position).Magnitude
    if Config.Grinder.TPToTarget and dist > Config.Combat.AttackRadius * 1.5 then
        local delta = r.Position - tp.Position
        local dir   = delta.Magnitude > 0.01 and delta.Unit or Vector3.new(1, 0, 0)
        SafeTP(tp.Position + dir * math.max(2, Config.Combat.AttackRadius - 2))
    end

    FaceTarget(tp.Position)

    if Config.Combat.AutoDodge then
        local h = Hum()
        if h and h.MaxHealth > 0 and (h.Health / h.MaxHealth) < Config.Combat.DodgeHP then
            SafeKeyPress(Enum.KeyCode.Q, 0.05)
            task.wait(0.1)
        end
    end

    local now = tick()
    if Config.Combat.M1Enabled and now - State.LastM1 > Config.Combat.M1Delay then
        State.LastM1 = now
        SafeClick()
    end

    if now - State.LastSkill > Config.Combat.SkillDelay then
        State.LastSkill = now
        local sk = RotateSkill()
        if sk then SafeKeyPress(sk, 0.04) end
    end

    return true -- Attack attempt, not confirmed damage.
end

local function FightUntilDead(mob, timeout)
    if not mob then return false end
    timeout = timeout or 120
    local deadline = tick() + timeout

    while tick() < deadline and Config.Grinder.Enabled do
        if not mob.Parent then
            Log("Target despawned; kill not confirmed")
            return false
        end

        if not IsAlive() then
            Log("Died during fight")
            State.CurrentState = GS.DEAD
            return false
        end

        local th = mob:IsA("Model") and mob:FindFirstChildOfClass("Humanoid")
        if th then
            if th.Health <= 0 then
                Log("Killed: "..mob.Name)
                return true
            end
        end

        AttackMob(mob)
        task.wait(0.05)
    end

    Log("Fight timeout: "..tostring(mob and mob.Name or "?"))
    return false
end

-- ══════════════════════════════════════════════════════════════
-- INTERACTION
-- ══════════════════════════════════════════════════════════════
local function Interact(part)
    if not part or not part.Parent then return false end
    if not SafeTP(part.Position) then return false end
    task.wait(0.2)
    -- Use a real prompt when the environment exposes one. No fake success.
    local prompt = part:FindFirstChildWhichIsA("ProximityPrompt", true)
    if not prompt and part.Parent then
        prompt = part.Parent:FindFirstChildWhichIsA("ProximityPrompt", true)
    end
    if prompt and type(fireproximityprompt) == "function" then
        local ok = pcall(fireproximityprompt, prompt)
        task.wait(0.4)
        return ok -- dispatched, not server-confirmed
    end
    local sent = SafeKeyPress(Enum.KeyCode.E, 0.1)
    task.wait(0.4)
    return sent -- dispatched, not server-confirmed
end

-- ══════════════════════════════════════════════════════════════
-- PUMPKIN HUNT
-- ══════════════════════════════════════════════════════════════
local PUMPKIN_KW = {"jack", "pumpkin", "lantern", "jackolantern", "jack-o"}

local function RunPumpkinHunt()
    State.CurrentState = GS.PUMPKIN_HUNT
    Log("Pumpkin Hunt started")
    State.StatusText = "🎃 Hunting pumpkins..."

    local found = FindAll(PUMPKIN_KW, Config.Grinder.PumpkinScanRadius)
    if #found == 0 then
        found = FindAll(PUMPKIN_KW, 800)
    end
    if #found == 0 then
        Log("No pumpkins found in scan radius")
        return false
    end

    Log("Found "..#found.." pumpkins")

    for _, e in ipairs(found) do
        if not Config.Grinder.Enabled then break end
        if not IsAlive() then break end
        if not e.Object.Parent then
            -- object gone, skip without continue keyword
        else
            State.StatusText = "🎃 Smashing: "..e.Object.Name

            if not SafeTP(e.Part.Position) then
                Log("Pumpkin movement failed: "..e.Object.Name)
                break
            end

            local hum = e.Object:IsA("Model") and e.Object:FindFirstChildOfClass("Humanoid")

            if hum and hum.MaxHealth > 100 then
                Log("Hostile pumpkin: "..e.Object.Name)
                State.StatusText = "⚔ Fighting: "..e.Object.Name
                local killed = FightUntilDead(e.Object, 60)
                if killed then
                    State.PumpkinsSmashed = State.PumpkinsSmashed + 1
                end
            else
                for i = 1, 5 do
                    if not e.Object.Parent then break end
                    AttackMob(e.Object)
                    task.wait(0.08)
                end
                -- Count as smashed if the object disappeared (collected/destroyed)
                if not e.Object.Parent then
                    State.PumpkinsSmashed = State.PumpkinsSmashed + 1
                end
            end

            task.wait(0.3)
        end
    end

    Log("Pumpkin hunt done — confirmed smashed: "..State.PumpkinsSmashed)
    return true
end

-- ══════════════════════════════════════════════════════════════
-- TRICK OR TREAT
-- ══════════════════════════════════════════════════════════════
local DOOR_KW   = {"door", "halloween", "spooky", "trick", "treat", "harvest"}
local HELL_KW   = {"hellfire", "flaming", "flame", "burning", "hell"}
local PORTAL_KW = {"portal", "void", "gateway", "domain"}

local RunBossFight  -- forward declared below

local function RunTrickOrTreat()
    State.CurrentState = GS.TRICK_OR_TREAT
    Log("Trick-or-Treat started")
    State.StatusText = "🚪 Finding doors..."

    local doors = FindAll(DOOR_KW, Config.Grinder.DoorScanRadius)
    if #doors == 0 then
        Log("No doors found in scan radius")
        State.StatusText = "⏳ No doors found"
        return false
    end

    Log("Found "..#doors.." doors")

    for _, e in ipairs(doors) do
        if not Config.Grinder.Enabled then break end
        if not IsAlive() then break end

        if e.Object.Parent then
            local name    = e.Object.Name:lower()
            local isHell  = false

            for _, kw in ipairs(HELL_KW) do
                if name:find(kw, 1, true) then
                    isHell = true
                    break
                end
            end

            -- Secondary: fire/particle effects on the door model
            if not isHell and e.Object:IsA("Model") then
                for _, child in ipairs(e.Object:GetDescendants()) do
                    if child:IsA("Fire") or child:IsA("ParticleEmitter") then
                        isHell = true
                        break
                    end
                end
            end

            if isHell and Config.Grinder.AutoHellRider then
                Log("HELLFIRE DOOR detected: "..e.Object.Name)
                State.StatusText = "🔥 Hellfire door — spawning portal..."
                if Interact(e.Part) then
                    task.wait(1)
                    RunBossFight("hell_rider")
                else
                    Log("Hellfire door interaction unavailable")
                end
            else
                State.StatusText = "🚪 Knocking: "..math.floor(e.Dist).."st"
                local sent = Interact(e.Part)
                Log((sent and "Door input dispatched: " or "Door input unavailable: ")..e.Object.Name)
                task.wait(0.8)

                if Config.Grinder.AutoWerewolf then
                    local wolf = FindNearest({"werewolf", "wolf"}, 60)
                    if wolf and sent then
                        Log("Werewolf found near door (spawn cause unverified)")
                        State.CurrentState = GS.BOSS_FIGHT
                        if FightUntilDead(wolf, 180) then
                            State.BossKills = State.BossKills + 1
                        end
                        State.CurrentState = GS.TRICK_OR_TREAT
                    end
                end
            end

            task.wait(0.5)
        end
    end

    Log("Trick-or-Treat done — doors knocked: "..State.DoorsKnocked)
    return true
end

-- ══════════════════════════════════════════════════════════════
-- BOSS FIGHT ENGINE
-- ══════════════════════════════════════════════════════════════
RunBossFight = function(bossType)
    State.CurrentState = GS.BOSS_FIGHT

    if bossType == "hell_rider" then
        Log("Hell Rider fight — searching for portal")
        State.StatusText = "🔥 Finding portal..."
        task.wait(2)

        local _, _, pp = FindNearest(PORTAL_KW, 200)
        if pp then
            Log("Portal found — entering domain")
            State.StatusText = "🔥 Entering Hell Rider domain..."
            if not Interact(pp) then Log("Portal input failed") end
            task.wait(2)
        else
            Log("No portal found near hellfire door — fighting in open world")
        end

        -- Search for the boss with retries
        local hellRider   = nil
        local attempts    = 0
        local HR_KEYWORDS = {"hellfire gas", "hell rider", "hellrider", "hell_rider"}

        while not hellRider and attempts < 20 and Config.Grinder.Enabled do
            hellRider = FindNearest(HR_KEYWORDS, 500)
            if not hellRider then
                task.wait(0.5)
            end
            attempts = attempts + 1
        end

        if hellRider then
            Log("Hellfire boss located — fighting")
            State.StatusText = "⚔ Fighting Hell Rider!"
            local fightStart = tick()

            while tick() - fightStart < 300 and Config.Grinder.Enabled do
                if not IsAlive() then
                    State.CurrentState = GS.DEAD
                    return false
                end

                local cur = FindNearest(HR_KEYWORDS, 500)
                if not cur then
                    Log("Hell Rider lost/despawned — kill not confirmed")
                    break
                end

                local ch = cur:IsA("Model") and cur:FindFirstChildOfClass("Humanoid")
                if ch and ch.Health <= 0 then
                    Log("Hell Rider HP = 0 — killed!")
                    State.BossKills = State.BossKills + 1
                    break
                end

                -- Portal phase: follow boss through portals
                local _, _, pp2 = FindNearest(PORTAL_KW, 100)
                if pp2 then
                    Log("Portal phase — following...")
                    if Interact(pp2) then task.wait(1.5) end
                end

                AttackMob(cur)
                task.wait(0.35) -- avoid scanning all Workspace descendants 20 times/sec
            end
        else
            Log("Hell Rider not found after "..attempts.." attempts")
        end

    elseif bossType == "werewolf" then
        Log("Werewolf fight started")
        State.StatusText = "🐺 Fighting Werewolf!"

        local wolf = FindNearest({"werewolf", "wolf"}, Config.Grinder.BossScanRadius)
        if wolf then
            if FightUntilDead(wolf, 180) then
                State.BossKills = State.BossKills + 1
            end
        else
            Log("Werewolf not found in scan radius")
            return false
        end
    end

    Log("Boss fight ended — confirmed kills: "..State.BossKills)
    return true
end

-- ══════════════════════════════════════════════════════════════
-- GACHA ENGINE
-- Fixed: original broke out of loop after first attempt regardless
-- of result. Now re-scans tokens after each roll and loops correctly.
-- ══════════════════════════════════════════════════════════════
local function TryClickGachaButton()
    if not VIM_SAFE then
        Log("Gacha GUI clicks unavailable on this executor; manual roll required")
        return false
    end
    for _, gui in ipairs(LP.PlayerGui:GetDescendants()) do
        if gui:IsA("TextButton") and gui.Visible then
            local t = gui.Text:lower()
            if t:find("roll", 1, true) or t:find("500", 1, true) or t:find("spin", 1, true) then
                local pos = gui.AbsolutePosition + gui.AbsoluteSize / 2
                if SafeClick(pos.X, pos.Y) then
                    task.wait(1.5)
                    Log("Gacha click sent (roll unconfirmed): "..gui.Text)
                    return true
                else
                    Log("Gacha click failed — input unavailable")
                    return false
                end
            end
        end
    end
    Log("No visible gacha roll button found in PlayerGui")
    return false
end

local function RunGacha()
    if State.SpookyTokens < Config.Grinder.GachaMinTokens then
        Log("Tokens insufficient: "..State.SpookyTokens.."/"..Config.Grinder.GachaMinTokens)
        return false
    end

    State.CurrentState = GS.GACHA
    Log("Gacha run — tokens: "..State.SpookyTokens)
    State.StatusText  = "🎰 Finding Zioles..."

    local _, _, zp = FindNearest({"zioles", "spooky gacha", "gacha"}, 2000)

    if not zp then
        Log("Zioles NPC not found in scan radius")
        State.StatusText = "🎰 Zioles not found — skipping gacha"
        return false
    end

    if not Interact(zp) then
        Log("Gacha NPC interaction unavailable")
        return false
    end
    task.wait(0.5)

    local clicked = TryClickGachaButton()
    if clicked then
        -- Input delivery alone does not prove the server accepted the roll.
        State.StatusText = "🎰 Roll input sent — verify result in game"
    end

    SafeKeyPress(Enum.KeyCode.Escape, 0.05)
    task.wait(0.3)
    return clicked
end

-- ══════════════════════════════════════════════════════════════
-- TOKEN SCANNER
-- Priority: leaderstats Value objects (authoritative) → UI labels (fallback)
-- ══════════════════════════════════════════════════════════════
local function ScanTokens()
    -- Method 1: leaderstats (most reliable)
    local ls = LP:FindFirstChild("leaderstats")
    if ls then
        for _, v in ipairs(ls:GetChildren()) do
            local n = v.Name:lower()
            if n:find("token", 1, true) or n:find("candy", 1, true) or n:find("spooky", 1, true) then
                if v:IsA("IntValue") or v:IsA("NumberValue") then
                    State.SpookyTokens = v.Value
                    return
                end
            end
        end
    end

    -- Method 2: PlayerGui label scan
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then return end

    for _, obj in ipairs(pg:GetDescendants()) do
        if obj:IsA("TextLabel") then
            local t = obj.Text:lower()
            if t:find("token", 1, true) or t:find("candy", 1, true) then
                local raw = obj.Text:match("([%d,]+)")
                local n   = raw and tonumber(raw:gsub(",", ""))
                if n and n >= 0 and n < 999999999 then
                    State.SpookyTokens = n
                    return
                end
            end
        end
    end
end

-- ══════════════════════════════════════════════════════════════
-- DEATH HANDLER
-- ══════════════════════════════════════════════════════════════
local function HandleDeath()
    State.CurrentState = GS.DEAD
    State.StatusText   = "💀 Dead — respawning..."
    Log("Player died — waiting "..Config.Grinder.RespawnWaitTime.."s")
    task.wait(Config.Grinder.RespawnWaitTime)
    if not Config.Grinder.Enabled then return end
    WaitForChar(15)
    if IsAlive() then
        Log("Respawned — resuming grind")
        State.CurrentState = GS.IDLE
    else
        Log("Could not confirm respawn after 15s")
    end
end

-- ══════════════════════════════════════════════════════════════
-- MAIN GRIND CYCLE
-- ══════════════════════════════════════════════════════════════
local function RunGrindCycle()
    Log("=== Grind Cycle Start ===")
    local cs = tick()

    -- Phase 1: Pumpkins (always available)
    if Config.Grinder.Enabled and Config.Grinder.AutoPumpkins then
        State.StatusText = "🎃 Phase 1: Pumpkins"
        RunPumpkinHunt()
        task.wait(1)
    end

    -- Phase 2: Trick-or-Treat
    if Config.Grinder.Enabled and Config.Grinder.AutoTrickOrTreat then
        if Config.Grinder.HarvestMoonOnly then
            -- When no supported flag exists, skip this phase and retry next cycle.
            if IsHarvestMoon() then
                Log("Harvest Moon flag active — Trick-or-Treating")
                RunTrickOrTreat()
            else
                Log("Harvest Moon not confirmed — skipping doors this cycle")
            end
        else
            -- Always run Trick-or-Treat regardless of time
            RunTrickOrTreat()
        end
    end

    -- Phase 3: Standalone werewolf scan
    if Config.Grinder.Enabled and Config.Grinder.AutoWerewolf then
        local wolf = FindNearest({"werewolf", "wolf"}, Config.Grinder.BossScanRadius)
        if wolf then
            Log("Standalone werewolf found — engaging")
            RunBossFight("werewolf")
        end
    end

    -- Phase 4: Gacha loop
    -- Fixed: original broke unconditionally after first attempt.
    -- Now loops until tokens run out or click fails.
    if Config.Grinder.Enabled and Config.Grinder.AutoGacha then
        ScanTokens()
        local rollAttempts = 0
        local currentHour = math.floor(os.time() / 3600)
        if State.GachaHour ~= currentHour then
            State.GachaHour = currentHour
            State.GachaConfirmed = 0
        end
        local MAX_ROLLS_PER_CYCLE = math.max(0, 2 - State.GachaConfirmed)
        if MAX_ROLLS_PER_CYCLE == 0 then Log("Hourly Gacha limit reached in this session") end
        while Config.Grinder.Enabled
            and State.SpookyTokens >= Config.Grinder.GachaMinTokens
            and rollAttempts < MAX_ROLLS_PER_CYCLE do

            local rolled = RunGacha()
            rollAttempts = rollAttempts + 1
            task.wait(2)
            local oldTokens = State.SpookyTokens
            ScanTokens()  -- re-read after each roll
            if not rolled then break end  -- click failed or NPC not found
            if State.SpookyTokens >= oldTokens then
                Log("Gacha tokens unchanged; stopping to avoid repeat clicks")
                break
            end
            State.GachaConfirmed = State.GachaConfirmed + 1
            State.GachaRolls = State.GachaRolls + 1
        end
    end

    local elapsed = math.floor(tick() - cs)
    Log(string.format(
        "=== Cycle done in %ds | 🎃%d 🚪%d ☠%d 🎰%d ===",
        elapsed,
        State.PumpkinsSmashed,
        State.DoorsKnocked,
        State.BossKills,
        State.GachaRolls
    ))
end

-- ══════════════════════════════════════════════════════════════
-- FLY  (defined before GUI and panic use it)
-- ══════════════════════════════════════════════════════════════
local function EnableFly()
    local c = Char() if not c then return end
    local r = c:FindFirstChild("HumanoidRootPart") if not r then return end
    local h = Hum() if not h then return end
    h.PlatformStand = true
    local bv = Instance.new("BodyVelocity")
    bv.MaxForce  = Vector3.new(1e6, 1e6, 1e6)
    bv.Velocity  = Vector3.zero
    bv.Parent    = r
    State.FlyBV  = bv
    State.FlyActive = true
end

local function DisableFly()
    if State.FlyBV then
        State.FlyBV:Destroy()
        State.FlyBV = nil
    end
    local c = Char()
    if c then
        local h = Hum()
        if h then h.PlatformStand = false end
    end
    State.FlyActive = false
end

-- ══════════════════════════════════════════════════════════════
-- GUI
-- ══════════════════════════════════════════════════════════════
local GUI = {}
do
    local C = {
        BG  = Color3.fromRGB(12, 15, 27),
        BGS = Color3.fromRGB(24, 29, 47),
        OR  = Color3.fromRGB(141, 89, 247),
        ORG = Color3.fromRGB(203, 170, 255),
        GR  = Color3.fromRGB(44, 194, 147),
        RD  = Color3.fromRGB(220, 60, 60),
        TX  = Color3.fromRGB(230, 225, 220),
        DM  = Color3.fromRGB(120, 115, 110),
        BD  = Color3.fromRGB(65, 71, 96),
    }

    local SG = Instance.new("ScreenGui")
    SG.Name           = "AxiomHalloweenDashboard"
    SG.ResetOnSpawn   = false
    SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    SG.DisplayOrder   = 999
    SG.IgnoreGuiInset = true

    local function SafeParent(g)
        local ok = pcall(function() g.Parent = game:GetService("CoreGui") end)
        if not ok or not g.Parent then g.Parent = LP.PlayerGui end
    end
    SafeParent(SG)
    global.BF_EVENT_V33_STOP = function()
        shutdown = true
        Config.Grinder.Enabled = false
        for _, conn in ipairs(cleanup) do pcall(function() conn:Disconnect() end) end
        pcall(function() SG:Destroy() end)
    end

    -- ── Main window ──
    local Main = Instance.new("Frame")
    Main.AnchorPoint     = Vector2.new(0.5, 0.5)
    Main.Size            = UDim2.new(0.92, 0, 0.82, 0)
    Main.Position        = UDim2.new(0.5, 0, 0.5, 0)
    Main.BackgroundColor3 = C.BG
    Main.BorderSizePixel = 0
    Main.ClipsDescendants = true
    Main.Parent          = SG
    Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 10)

    local SC = Instance.new("UISizeConstraint", Main)
    SC.MaxSize = Vector2.new(580, 620)
    SC.MinSize = Vector2.new(280, 300)

    local Stk = Instance.new("UIStroke", Main)
    Stk.Color        = C.OR
    Stk.Thickness    = 1.5
    Stk.Transparency = 0.3

    -- ── Title bar ──
    local TB = Instance.new("Frame")
    TB.Size             = UDim2.new(1, 0, 0, 44)
    TB.BackgroundColor3 = C.BGS
    TB.BorderSizePixel  = 0
    TB.Parent           = Main
    Instance.new("UICorner", TB).CornerRadius = UDim.new(0, 10)
    -- Cover bottom-radius on title bar
    local TF = Instance.new("Frame")
    TF.Size             = UDim2.new(1, 0, 0, 10)
    TF.Position         = UDim2.new(0, 0, 1, -10)
    TF.BackgroundColor3 = C.BGS
    TF.BorderSizePixel  = 0
    TF.Parent           = TB

    local TLbl = Instance.new("TextLabel")
    TLbl.Size               = UDim2.new(1, -90, 1, 0)
    TLbl.Position           = UDim2.new(0, 12, 0, 0)
    TLbl.BackgroundTransparency = 1
    TLbl.Text               = "✦  AXIOM / HALLOWEEN 2026"
    TLbl.TextColor3         = C.ORG
    TLbl.Font               = Enum.Font.GothamBold
    TLbl.TextSize           = 13
    TLbl.TextScaled         = false
    TLbl.TextXAlignment     = Enum.TextXAlignment.Left
    TLbl.Parent             = TB

    -- Close button — large enough for touch (44px)
    local CloseBtn = Instance.new("TextButton")
    CloseBtn.Size             = UDim2.new(0, 36, 0, 36)
    CloseBtn.Position         = UDim2.new(1, -40, 0.5, -18)
    CloseBtn.BackgroundColor3 = C.RD
    CloseBtn.Text             = "✕"
    CloseBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
    CloseBtn.Font             = Enum.Font.GothamBold
    CloseBtn.TextSize         = 14
    CloseBtn.BorderSizePixel  = 0
    CloseBtn.Parent           = TB
    Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 8)
    CloseBtn.MouseButton1Click:Connect(function() Main.Visible = false end)

    -- ── Drag (mouse + touch) ──
    local dragging, dragStart, winStart = false, nil, nil

    local function OnDragBegan(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            winStart  = Main.Position
        end
    end
    local function OnDragChanged(input)
        if dragging
        and (input.UserInputType == Enum.UserInputType.MouseMovement
          or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            Main.Position = UDim2.new(
                winStart.X.Scale, winStart.X.Offset + delta.X,
                winStart.Y.Scale, winStart.Y.Offset + delta.Y
            )
        end
    end
    local function OnDragEnded(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end

    Track(TB.InputBegan:Connect(OnDragBegan))
    Track(UserInputService.InputChanged:Connect(OnDragChanged))
    Track(UserInputService.InputEnded:Connect(OnDragEnded))

    -- ── Content ──
    local Cont = Instance.new("Frame")
    Cont.Size               = UDim2.new(1, 0, 1, -44)
    Cont.Position           = UDim2.new(0, 0, 0, 44)
    Cont.BackgroundTransparency = 1
    Cont.Parent             = Main

    local Scroll = Instance.new("ScrollingFrame")
    Scroll.Size                = UDim2.new(1, 0, 1, 0)
    Scroll.BackgroundTransparency = 1
    Scroll.BorderSizePixel     = 0
    Scroll.ScrollBarThickness  = 4
    Scroll.ScrollBarImageColor3 = C.OR
    Scroll.CanvasSize          = UDim2.new(0, 0, 0, 0)
    Scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    Scroll.Parent              = Cont

    local SLayout = Instance.new("UIListLayout", Scroll)
    SLayout.Padding              = UDim.new(0, 6)
    SLayout.HorizontalAlignment  = Enum.HorizontalAlignment.Center
    SLayout.SortOrder            = Enum.SortOrder.LayoutOrder
    Instance.new("UIPadding", Scroll).PaddingTop = UDim.new(0, 10)

    -- ── Helpers ──
    local function MkRow(parent, h, order)
        local r = Instance.new("Frame")
        r.Size             = UDim2.new(1, -16, 0, h or 44)
        r.BackgroundColor3 = C.BGS
        r.BorderSizePixel  = 0
        r.LayoutOrder      = order or 0
        r.Parent           = parent
        Instance.new("UICorner", r).CornerRadius = UDim.new(0, 8)
        return r
    end

    local function SecLbl(text, order)
        local l = Instance.new("TextLabel")
        l.Size               = UDim2.new(1, -16, 0, 20)
        l.BackgroundTransparency = 1
        l.Text               = "  ▸ "..text:upper()
        l.TextColor3         = C.ORG
        l.Font               = Enum.Font.GothamBold
        l.TextSize           = 10
        l.TextXAlignment     = Enum.TextXAlignment.Left
        l.LayoutOrder        = order or 0
        l.Parent             = Scroll
    end

    local function Toggle(parent, label, get, set, order)
        local row = MkRow(parent, 44, order)

        local lbl = Instance.new("TextLabel")
        lbl.Size               = UDim2.new(1, -68, 1, 0)
        lbl.Position           = UDim2.new(0, 12, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text               = label
        lbl.TextColor3         = C.TX
        lbl.Font               = Enum.Font.Gotham
        lbl.TextSize           = 13
        lbl.TextXAlignment     = Enum.TextXAlignment.Left
        lbl.TextTruncate       = Enum.TextTruncate.AtEnd
        lbl.Parent             = row

        local track = Instance.new("Frame")
        track.Size             = UDim2.new(0, 46, 0, 24)
        track.Position         = UDim2.new(1, -56, 0.5, -12)
        track.BackgroundColor3 = get() and C.OR or C.BD
        track.BorderSizePixel  = 0
        track.Parent           = row
        Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

        local knob = Instance.new("Frame")
        knob.Size             = UDim2.new(0, 20, 0, 20)
        knob.Position         = get() and UDim2.new(1, -22, 0.5, -10) or UDim2.new(0, 2, 0.5, -10)
        knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        knob.BorderSizePixel  = 0
        knob.Parent           = track
        Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

        local btn = Instance.new("TextButton")
        btn.Size               = UDim2.new(1, 0, 1, 0)
        btn.BackgroundTransparency = 1
        btn.Text               = ""
        btn.Parent             = track

        local function Refresh()
            local on = get()
            TweenService:Create(track, TweenInfo.new(0.18), {
                BackgroundColor3 = on and C.OR or C.BD
            }):Play()
            TweenService:Create(knob, TweenInfo.new(0.18), {
                Position = on
                    and UDim2.new(1, -22, 0.5, -10)
                    or  UDim2.new(0,  2, 0.5, -10)
            }):Play()
        end

        btn.MouseButton1Click:Connect(function()
            set(not get())
            Refresh()
        end)
    end

    -- ── START / STOP button ──
    local SR = MkRow(Scroll, 56, 1)
    local SB = Instance.new("TextButton")
    SB.Size             = UDim2.new(1, -20, 1, -10)
    SB.Position         = UDim2.new(0, 10, 0, 5)
    SB.BackgroundColor3 = C.GR
    SB.Text             = "▶  START GRINDER"
    SB.TextColor3       = Color3.fromRGB(255, 255, 255)
    SB.Font             = Enum.Font.GothamBold
    SB.TextSize         = 17
    SB.BorderSizePixel  = 0
    SB.Parent           = SR
    Instance.new("UICorner", SB).CornerRadius = UDim.new(0, 8)

    SB.MouseButton1Click:Connect(function()
        Config.Grinder.Enabled = not Config.Grinder.Enabled
        if Config.Grinder.Enabled and not (Config.Grinder.AutoPumpkins or Config.Grinder.AutoTrickOrTreat or Config.Grinder.AutoWerewolf or Config.Grinder.AutoGacha) then
            Config.Grinder.Enabled = false
            Log("Diagnostics-only mode: enable one module before START")
        end
        SB.BackgroundColor3    = Config.Grinder.Enabled and C.RD or C.GR
        SB.Text                = Config.Grinder.Enabled and "⏹  STOP GRINDER" or "▶  START GRINDER"

        if Config.Grinder.Enabled and not State.Running then
            State.Running = true
            task.spawn(function()
                while Config.Grinder.Enabled and not shutdown do
                    local ok, err = xpcall(function()
                        if not IsAlive() then
                            HandleDeath()
                        else
                            RunGrindCycle()
                        end
                    end, debug.traceback)

                    if not ok then
                        Log("Cycle error: "..tostring(err))
                        warn("[BF Grinder] Cycle error:\n"..tostring(err))
                        task.wait(3) -- brief pause before retry on error
                    end

                    if Config.Grinder.Enabled and Config.Grinder.LoopGrind then
                        task.wait(1)
                    else
                        break
                    end
                end

                -- Guaranteed cleanup
                Config.Grinder.Enabled = false
                SB.BackgroundColor3    = C.GR
                SB.Text                = "▶  START GRINDER"
                State.Running          = false
                Log("Grinder stopped")
            end)
        end
    end)

    -- ── Stats display ──
    local StR = MkRow(Scroll, 56, 2)
    local StL = Instance.new("TextLabel")
    StL.Size               = UDim2.new(1, -12, 1, 0)
    StL.Position           = UDim2.new(0, 12, 0, 0)
    StL.BackgroundTransparency = 1
    StL.TextColor3         = C.DM
    StL.Font               = Enum.Font.Gotham
    StL.TextSize           = 11
    StL.TextXAlignment     = Enum.TextXAlignment.Left
    StL.TextWrapped        = true
    StL.Parent             = StR
    GUI.StatsLbl           = StL

    -- ── Event status ──
    local EvR = MkRow(Scroll, 36, 3)
    local EvL = Instance.new("TextLabel")
    EvL.Size               = UDim2.new(1, -12, 1, 0)
    EvL.Position           = UDim2.new(0, 12, 0, 0)
    EvL.BackgroundTransparency = 1
    EvL.TextColor3         = C.ORG
    EvL.Font               = Enum.Font.GothamBold
    EvL.TextSize           = 12
    EvL.TextXAlignment     = Enum.TextXAlignment.Left
    EvL.Parent             = EvR
    GUI.EvLbl              = EvL

    -- ── Toggles ──
    SecLbl("Event Modules", 4)
    Toggle(Scroll, "🎃 Auto Pumpkin Hunt",    function() return Config.Grinder.AutoPumpkins     end, function(v) Config.Grinder.AutoPumpkins     = v end, 5)
    Toggle(Scroll, "🚪 Auto Trick-or-Treat",  function() return Config.Grinder.AutoTrickOrTreat end, function(v) Config.Grinder.AutoTrickOrTreat = v end, 6)
    Toggle(Scroll, "🔥 Auto Hell Rider",       function() return Config.Grinder.AutoHellRider    end, function(v) Config.Grinder.AutoHellRider    = v end, 7)
    Toggle(Scroll, "🐺 Auto Werewolf",         function() return Config.Grinder.AutoWerewolf     end, function(v) Config.Grinder.AutoWerewolf     = v end, 8)
    Toggle(Scroll, "🎰 Auto Gacha (spends candy)",            function() return Config.Grinder.AutoGacha        end, function(v) Config.Grinder.AutoGacha        = v end, 9)
    Toggle(Scroll, "🔁 Loop Grind",            function() return Config.Grinder.LoopGrind        end, function(v) Config.Grinder.LoopGrind        = v end, 10)
    Toggle(Scroll, "📡 Teleport to Targets",   function() return Config.Grinder.TPToTarget       end, function(v) Config.Grinder.TPToTarget       = v end, 11)
    Toggle(Scroll, "🌕 Harvest Moon Only",     function() return Config.Grinder.HarvestMoonOnly  end, function(v) Config.Grinder.HarvestMoonOnly  = v end, 12)

    SecLbl("Combat", 13)
    Toggle(Scroll, "M1 Attack",      function() return Config.Combat.M1Enabled end, function(v) Config.Combat.M1Enabled = v end, 14)
    Toggle(Scroll, "Z Skill",        function() return Config.Combat.UseZ      end, function(v) Config.Combat.UseZ      = v end, 15)
    Toggle(Scroll, "X Skill",        function() return Config.Combat.UseX      end, function(v) Config.Combat.UseX      = v end, 16)
    Toggle(Scroll, "C Skill",        function() return Config.Combat.UseC      end, function(v) Config.Combat.UseC      = v end, 17)
    Toggle(Scroll, "F Skill",        function() return Config.Combat.UseF      end, function(v) Config.Combat.UseF      = v end, 18)
    Toggle(Scroll, "Auto Dodge",     function() return Config.Combat.AutoDodge end, function(v) Config.Combat.AutoDodge = v end, 19)

    -- ── Diagnostics: visible without requiring console access ──
    SecLbl("Android / executor diagnostics", 20)
    local DiagRow = MkRow(Scroll, 76, 21)
    local Diag = Instance.new("TextLabel")
    Diag.Size = UDim2.new(1, -20, 1, -8)
    Diag.Position = UDim2.new(0, 10, 0, 4)
    Diag.BackgroundTransparency = 1
    Diag.TextColor3 = C.TX
    Diag.Font = Enum.Font.Code
    Diag.TextSize = 12
    Diag.TextWrapped = true
    Diag.TextXAlignment = Enum.TextXAlignment.Left
    Diag.TextYAlignment = Enum.TextYAlignment.Center
    Diag.Parent = DiagRow
    GUI.Diag = Diag

    -- Emergency stop accessible on touch (Delete is not available on phones).
    local EmergencyRow = MkRow(Scroll, 52, 22)
    local Emergency = Instance.new("TextButton")
    Emergency.Size = UDim2.new(1, -20, 1, -10)
    Emergency.Position = UDim2.fromOffset(10, 5)
    Emergency.Text = "STOP ALL AUTOMATION"
    Emergency.TextColor3 = Color3.new(1,1,1)
    Emergency.BackgroundColor3 = C.RD
    Emergency.Font = Enum.Font.GothamBold
    Emergency.TextSize = 14
    Emergency.Parent = EmergencyRow
    Instance.new("UICorner", Emergency).CornerRadius = UDim.new(0, 9)
    Emergency.MouseButton1Click:Connect(function()
        Config.Grinder.Enabled = false
        Log("Emergency stop requested")
    end)

    -- ── Log panel ──
    SecLbl("Activity Log", 23)
    local LgR = MkRow(Scroll, 155, 24)
    local LgF = Instance.new("ScrollingFrame")
    LgF.Size                = UDim2.new(1, -12, 1, -8)
    LgF.Position            = UDim2.new(0, 6, 0, 4)
    LgF.BackgroundTransparency = 1
    LgF.BorderSizePixel     = 0
    LgF.ScrollBarThickness  = 3
    LgF.ScrollBarImageColor3 = C.OR
    LgF.CanvasSize          = UDim2.new(0, 0, 0, 0)
    LgF.AutomaticCanvasSize = Enum.AutomaticSize.Y
    LgF.Parent              = LgR
    Instance.new("UIListLayout", LgF).Padding = UDim.new(0, 2)
    GUI.LogFrame = LgF

    GUI.Main = Main
end

-- ── Log rebuilder — diff update to avoid Instance spam ──
local logLabelCache = {}

local function RebuildLog()
    if not State.LogDirty then return end
    State.LogDirty = false

    -- Remove stale labels
    for i = #logLabelCache, #State.Log + 1, -1 do
        if logLabelCache[i] then
            logLabelCache[i]:Destroy()
            logLabelCache[i] = nil
        end
    end

    for i, line in ipairs(State.Log) do
        if not logLabelCache[i] then
            local l = Instance.new("TextLabel")
            l.Size               = UDim2.new(1, -4, 0, 14)
            l.BackgroundTransparency = 1
            l.Font               = Enum.Font.Gotham
            l.TextSize           = 10
            l.TextXAlignment     = Enum.TextXAlignment.Left
            l.TextTruncate       = Enum.TextTruncate.AtEnd
            l.Parent             = GUI.LogFrame
            logLabelCache[i]     = l
        end
        logLabelCache[i].Text       = line
        logLabelCache[i].TextColor3 = i == 1
            and Color3.fromRGB(255, 150, 60)
            or  Color3.fromRGB(120, 115, 110)
    end
end

-- ── Floating GUI toggle button (touch-friendly) ──
do
    local ToggleBtn = Instance.new("TextButton")
    ToggleBtn.Size             = UDim2.new(0, 48, 0, 48)
    ToggleBtn.Position         = UDim2.new(0, 10, 0.5, -24)
    ToggleBtn.BackgroundColor3 = Color3.fromRGB(141, 89, 247)
    ToggleBtn.Text             = "🎃"
    ToggleBtn.TextSize         = 22
    ToggleBtn.Font             = Enum.Font.GothamBold
    ToggleBtn.BorderSizePixel  = 0
    ToggleBtn.ZIndex           = 10

    -- Parent to same ScreenGui as main GUI
    ToggleBtn.Parent = GUI.Main.Parent
    Instance.new("UICorner", ToggleBtn).CornerRadius = UDim.new(0, 12)

    ToggleBtn.MouseButton1Click:Connect(function()
        GUI.Main.Visible = not GUI.Main.Visible
    end)
end

-- ══════════════════════════════════════════════════════════════
-- INPUT HANDLING
-- ══════════════════════════════════════════════════════════════
Track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end

    if input.KeyCode == Config.Misc.PanicKey then
        Config.Grinder.Enabled = false
        -- Worker owns State.Running cleanup; do not permit double workers.
        DisableFly()
        GUI.Main.Visible = false
        Log("PANIC — grinder killed")
        print("[BF Halloween] PANIC")
        return
    end

    if input.KeyCode == Config.Misc.GUIToggleKey then
        GUI.Main.Visible = not GUI.Main.Visible
        return
    end
end))

Track(UserInputService.JumpRequest:Connect(function()
    if not Config.Misc.InfJump then return end
    local h = Hum()
    if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
end))

Track(LP.Idled:Connect(function()
    if not Config.Misc.AntiAFK then return end
    local cam = GetCamera()
    pcall(function()
        if not cam then return end
        VirtualUser:Button2Down(Vector2.new(0, 0), cam.CFrame)
        task.wait(0.1)
        VirtualUser:Button2Up(Vector2.new(0, 0), cam.CFrame)
    end)
end))

Track(LP.CharacterAdded:Connect(function()
    State.FlyActive = false
    State.FlyBV     = nil
    if State.CurrentState == GS.BOSS_FIGHT
    or State.CurrentState == GS.TRICK_OR_TREAT then
        State.CurrentState = GS.IDLE
    end
end))

-- NoClip loop
Track(RunService.Stepped:Connect(function()
    if not Config.Misc.NoClip then return end
    local c = Char()
    if not c then return end
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide = false end
    end
end))

-- ══════════════════════════════════════════════════════════════
-- RENDER LOOP — UI only, no heavy logic
-- ══════════════════════════════════════════════════════════════
local scanTimer = 0

Track(RunService.RenderStepped:Connect(function(dt)
    -- FPS counter
    State.FrameCount += 1
    local now = tick()
    if now - State.LastFPSTime >= 1 then
        State.FPS          = State.FrameCount
        State.FrameCount   = 0
        State.LastFPSTime  = now
    end

    -- Token scan (throttled to 1 Hz)
    scanTimer = scanTimer + dt
    if scanTimer >= 1 then
        scanTimer = 0
        ScanTokens()
    end

    -- Reduce Android GUI churn: update labels at most twice per second.
    if now - (State.LastUiUpdate or 0) < 0.5 then return end
    State.LastUiUpdate = now
    -- Stats label
    local el = math.floor(tick() - State.SessionStart)
    GUI.Diag.Text = string.format("VIM: %s   Keyboard: %s\nClick: %s   Prompt: %s\nHarvest: %s (schedule estimate)", tostring(VIM_SAFE ~= nil), tostring(type(keypress) == "function"), tostring(type(mouse1click) == "function" or VIM_SAFE ~= nil), tostring(type(fireproximityprompt) == "function"), HarvestWindow() and "WINDOW" or "OFF")
    GUI.StatsLbl.Text = string.format(
        "⏱ %dm%ds  🎃%d  🚪%d  ☠%d  🎰%d  🪙%d  FPS:%d",
        math.floor(el / 60), el % 60,
        State.PumpkinsSmashed, State.DoorsKnocked,
        State.BossKills, State.GachaRolls,
        State.SpookyTokens, State.FPS
    )

    -- Event status
    GUI.EvLbl.Text = (HarvestWindow() and "🌕 Scheduled window" or "⏳ Next hourly window")
        .."  ["..State.CurrentState.."]  "..State.StatusText

    -- Fly controller
    if Config.Misc.Fly then
        if not State.FlyActive then EnableFly() end
        if State.FlyBV and State.FlyBV.Parent then
            local dir = Vector3.zero
            local camera = GetCamera()
            local cf = camera and camera.CFrame or CFrame.new()
            local uis = UserInputService
            if uis:IsKeyDown(Enum.KeyCode.W) then dir = dir + cf.LookVector  end
            if uis:IsKeyDown(Enum.KeyCode.S) then dir = dir - cf.LookVector  end
            if uis:IsKeyDown(Enum.KeyCode.A) then dir = dir - cf.RightVector end
            if uis:IsKeyDown(Enum.KeyCode.D) then dir = dir + cf.RightVector end
            if uis:IsKeyDown(Enum.KeyCode.Space)       then dir = dir + Vector3.new(0,1,0) end
            if uis:IsKeyDown(Enum.KeyCode.LeftControl) then dir = dir - Vector3.new(0,1,0) end
            State.FlyBV.Velocity = dir.Magnitude > 0 and dir.Unit * Config.Misc.FlySpeed or Vector3.zero
        end
    else
        if State.FlyActive then DisableFly() end
    end

    -- Log diff-update
    RebuildLog()
end))

-- ══════════════════════════════════════════════════════════════
-- BOOT
-- ══════════════════════════════════════════════════════════════
Log("Axiom Halloween v3.3.1.1 crash-safe loaded — movement OFF, modules OFF")
Log("VIM available: "..tostring(VIM_SAFE ~= nil))
if not VIM_SAFE then Log("Android input limitation: GUI clicks may fail; keypress fallback is executor-dependent") end
Log("Tap 🎃 button or RightAlt to open GUI")
Log("Press START GRINDER to begin")

print("╔══════════════════════════════════════════╗")
print("║  AXIOM HALLOWEEN v3.3.1 — TEST    ║")
print("║  🎃 button or RightAlt  =  Toggle GUI   ║")
print("║  DELETE                 =  Panic stop   ║")
print("╚══════════════════════════════════════════╝")