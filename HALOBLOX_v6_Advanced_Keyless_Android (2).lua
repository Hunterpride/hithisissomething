--[[
HALOBLOX v6.0 | Advanced Keyless Android Hub
Single-file, auditable Luau. Does not download or execute unknown code.

NOTES:
* Tested here for Lua syntax only, not inside Roblox/Delta.
* Client input being sent is NOT proof that Blox Fruits accepted a hit.
* No guaranteed instant farming, anti-cheat bypass, undocumented remotes,
  server-side event control, or automated raid initiation.
* The bundled FlowAuth example supplied by the user downloads an inaccessible
  obfuscated payload. No part of that payload is copied or executed here.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
if not player then warn("[HALOBLOX v6] LocalPlayer unavailable") return end
local playerGui = player:WaitForChild("PlayerGui", 12)
if not playerGui then warn("[HALOBLOX v6] PlayerGui unavailable") return end

local env = _G
if type(getgenv) == "function" then
    local ok, value = pcall(getgenv)
    if ok and type(value) == "table" then env = value end
end
for _, name in ipairs({"HALOBLOX_V6_CLOSE", "HALOBLOX_V5_CLOSE", "HALOBLOX_V4_STOP"}) do
    if type(env[name]) == "function" then pcall(env[name]) end
end
local oldGui = playerGui:FindFirstChild("HALOBLOX_V6_ADVANCED")
if oldGui then pcall(function() oldGui:Destroy() end) end

local COLORS = {
    bg=Color3.fromRGB(10,16,28), pane=Color3.fromRGB(19,29,49), cell=Color3.fromRGB(29,41,67),
    accent=Color3.fromRGB(126,101,246), orange=Color3.fromRGB(255,165,84),
    green=Color3.fromRGB(43,183,129), red=Color3.fromRGB(216,73,92),
    text=Color3.fromRGB(237,242,253), muted=Color3.fromRGB(171,185,210), blue=Color3.fromRGB(109,201,250)
}
local MODES = {
    {id="PUMPKIN_AUTO", title="Pumpkin Auto Assist", desc="Approach visible pumpkins, attempt attacks, verify changes", group="PUMPKINS", attacks=true},
    {id="PUMPKIN_FIND", title="Pumpkin Finder", desc="Highlight nearby pumpkins, no combat", group="PUMPKINS", attacks=false},
    {id="SNOWMAN_AUTO", title="Pumpkin Snowman Assist", desc="Hunt detected Pumpkin Snowmen", group="SNOWMEN", attacks=true},
    {id="SNOWMAN_FIND", title="Snowman Finder", desc="Highlight Pumpkin Snowmen, no combat", group="SNOWMEN", attacks=false},
    {id="NPC_GRIND", title="Nearby NPC Grind", desc="Approach non-player humanoids; experimental combat", group="NPCS", attacks=true},
    {id="RAID_ASSIST", title="Raid Combat Assist", desc="Start a raid yourself, then assist against nearby NPCs", group="RAID", attacks=true},
    {id="BOSS_FIND", title="Halloween Boss Finder", desc="Highlight named event bosses", group="BOSSES", attacks=false},
    {id="DOOR_FIND", title="Halloween Door Finder", desc="Highlight distinctly named event doors", group="DOORS", attacks=false},
    {id="MIXED", title="Event Rotation", desc="Prioritize nearby Pumpkin Snowmen, then pumpkins", group="PUMPKINS", attacks=true}
}
local modeById = {}
for _, m in ipairs(MODES) do modeById[m.id] = m end
local GROUPS = {"PUMPKINS", "SNOWMEN", "NPCS", "RAID", "BOSSES", "DOORS"}
local state = {
    alive=true, running=false, epoch=0, mode="PUMPKIN_FIND", scanBusy=false,
    radius=200, walk=true, attack=true, highlight=true, autoEquip=false,
    profile="AUTO", tapPoint=nil, calibrating=false, calibrateAt=0,
    fastWalk=false, maxAttacks=12, targetTimeout=8, scanCount=0,
    tracked={}, cooldown=setmetatable({}, {__mode="k"}), highlights={},
    connections={}, history={}, routes={}, counters={attempts=0, hits=0, pumpkins=0, failures=0, moved=0},
    lastMethod="none", lastError="none", status="Ready; open Farm to select a mode",
    lastNoTargets=0, lastScan=0, confirmed={}
}
for _, g in ipairs(GROUPS) do state.tracked[g] = setmetatable({}, {__mode="k"}) end

-- Optional local preference persistence. No executable code is loaded from disk.
local CONFIG_FILE="HALOBLOX_v6_settings.json"
local function saveConfig()
    if type(writefile)~="function" then return false end
    local data={mode=state.mode,radius=state.radius,walk=state.walk,
        attack=state.attack,highlight=state.highlight,autoEquip=state.autoEquip,
        profile=state.profile,maxAttacks=state.maxAttacks,targetTimeout=state.targetTimeout}
    local ok=pcall(function()writefile(CONFIG_FILE,HttpService:JSONEncode(data))end)
    return ok
end
local function loadConfig()
    if type(readfile)~="function" then return end
    local ok,data=pcall(function()return HttpService:JSONDecode(readfile(CONFIG_FILE))end)
    if not ok or type(data)~="table" then return end
    if type(data.mode)=="string" and modeById[data.mode] then state.mode=data.mode end
    if type(data.profile)=="string" and ({AUTO=true,MOBILE=true,MOUSE=true,TOOL=true,SKILLS=true})[data.profile] then
        state.profile=data.profile
    end
    for _,name in ipairs({"walk","attack","highlight","autoEquip"}) do
        if type(data[name])=="boolean" then state[name]=data[name] end
    end
    for key,allowed in pairs({radius={[90]=true,[200]=true,[350]=true,[600]=true},
        maxAttacks={[6]=true,[12]=true,[20]=true},targetTimeout={[5]=true,[8]=true,[12]=true}}) do
        if type(data[key])=="number" and allowed[data[key]] then state[key]=data[key] end
    end
end
loadConfig()

local gui, panel, tabs, pages, startButton, panicButton, statusLabel, metricsLabel, logsLabel, compatLabel
local function connect(signal, fn)
    local c = signal:Connect(fn)
    state.connections[#state.connections+1] = c
    return c
end
local function log(message)
    local line = os.date("%H:%M:%S") .. " " .. tostring(message)
    table.insert(state.history, 1, line)
    while #state.history > 24 do table.remove(state.history) end
    if logsLabel and logsLabel.Parent then logsLabel.Text = table.concat(state.history, "\n") end
    print("[HALOBLOX v6] " .. line)
end
local function status(message)
    state.status = message
    if statusLabel and statusLabel.Parent then statusLabel.Text = message end
end
local function character()
    local ch = player.Character
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    local root = ch and ch:FindFirstChild("HumanoidRootPart")
    if not hum or hum.Health <= 0 or not root then return nil, nil, nil end
    return ch, hum, root
end
local function partOf(object)
    if not object or not object.Parent then return nil end
    if object:IsA("BasePart") then return object end
    if object:IsA("Model") then
        return object.PrimaryPart or object:FindFirstChild("HumanoidRootPart") or object:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end
local function playerCharacter(model)
    return model and model:IsA("Model") and Players:GetPlayerFromCharacter(model) ~= nil
end
local function contains(name, fragment)
    return string.find(string.lower(name), fragment, 1, true) ~= nil
end
local function hasAncestorWord(object, fragments, levels)
    local parent = object.Parent
    for i=1, (levels or 4) do
        if not parent then break end
        for _, f in ipairs(fragments) do
            if contains(parent.Name, f) then return true end
        end
        parent=parent.Parent
    end
    return false
end
local function classify(obj)
    if not (obj:IsA("Model") or obj:IsA("BasePart")) then return nil end
    local n = string.lower(obj.Name)
    if n:find("snowman",1,true) then return "SNOWMEN" end
    if n:find("hellfire gas",1,true) or n:find("great pumpkin",1,true)
        or n:find("unbound werewolf",1,true) then return "BOSSES" end
    if n == "pumpkin" or n:match("^pumpkin%d+$") or n:find("jack.o.lantern") then
        return "PUMPKINS"
    end
    if n:find("trick.or.treat") or n:find("halloween door",1,true)
        or n:find("spooky door",1,true) or n:find("hellfire door",1,true) then return "DOORS" end
    if not obj:IsA("Model") or playerCharacter(obj) then return nil end
    local own = player.Character
    if own and obj:IsDescendantOf(own) then return nil end
    local h = obj:FindFirstChildOfClass("Humanoid")
    if not h or h.Health <= 0 then return nil end
    if n:find("raid",1,true) or hasAncestorWord(obj,{"raid", "island"},3) then return "RAID" end
    return "NPCS"
end
local function normalize(obj, cat)
    if not obj:IsA("BasePart") then return obj end
    local parent=obj.Parent
    if parent and parent:IsA("Model") and classify(parent)==cat then return parent end
    return obj
end
local function index(obj)
    if not state.alive then return end
    local cat=classify(obj)
    if cat then state.tracked[cat][normalize(obj,cat)]=true end
end
local function scan()
    if state.scanBusy or not state.alive then return end
    state.scanBusy=true
    local start=os.clock()
    local ok,err=pcall(function()
        -- Incremental breadth-first traversal: avoid building a huge
        -- Workspace:GetDescendants() array on memory-limited Android clients.
        local queue={Workspace}
        local head,tail=1,1
        local visited,found=0,0
        local LIMIT=60000
        while head<=tail and visited<LIMIT and state.alive do
            local obj=queue[head]
            queue[head]=nil
            head=head+1
            visited=visited+1
            if obj~=Workspace then
                local cat=classify(obj)
                if cat then
                    local norm=normalize(obj,cat)
                    if not state.tracked[cat][norm] then
                        state.tracked[cat][norm]=true
                        found=found+1
                    end
                end
            end
            local okChild,children=pcall(function()return obj:GetChildren()end)
            if okChild and children then
                for _,child in ipairs(children) do
                    tail=tail+1
                    queue[tail]=child
                end
            end
            if visited%180==0 then task.wait() end
        end
        state.scanCount=state.scanCount+1
        state.lastScan=os.clock()
        log("Scan #"..state.scanCount..": "..found.." new / "..visited.." visited ("..
            (math.floor((os.clock()-start)*10)/10).."s)")
        if visited==LIMIT then log("Scan budget reached; streamed arrivals indexed automatically") end
    end)
    state.scanBusy=false
    if not ok then state.lastError=tostring(err);log("Scan error: "..state.lastError) end
end
local function valid(obj,group)
    if not obj or not obj.Parent then return false end
    if group=="NPCS" or group=="RAID" then
        if not obj:IsA("Model") or playerCharacter(obj) then return false end
        local hum=obj:FindFirstChildOfClass("Humanoid")
        return hum~=nil and hum.Health>0
    end
    return true
end
local function nearby(group,radius,limit)
    local _,_,root=character()
    if not root then return {} end
    local results={}
    local now=os.clock()
    for obj in pairs(state.tracked[group]) do
        if not valid(obj,group) then state.tracked[group][obj]=nil
        else
            local p=partOf(obj)
            if p and p.Parent then
                local delta=p.Position-root.Position
                local flat=Vector3.new(delta.X,0,delta.Z).Magnitude
                if flat<=radius and math.abs(delta.Y)<55 and now>=(state.cooldown[obj] or 0) then
                    results[#results+1]={obj=obj,part=p,d=flat,group=group}
                end
            end
        end
    end
    table.sort(results,function(a,b)return a.d<b.d end)
    while #results>limit do table.remove(results) end
    return results
end
local function groupForMode()
    local m=modeById[state.mode]
    return m and m.group or "PUMPKINS"
end
local function candidates()
    if state.mode=="MIXED" then
        local snow=nearby("SNOWMEN",state.radius,3)
        if #snow>0 then return snow end
        return nearby("PUMPKINS",state.radius,8)
    end
    local grp=groupForMode()
    local a=nearby(grp,state.radius,8)
    if state.mode=="RAID_ASSIST" and #a==0 then return nearby("NPCS",state.radius,8) end
    return a
end
local function clearHighlights()
    for obj,h in pairs(state.highlights) do
        pcall(function() h:Destroy() end)
        state.highlights[obj]=nil
    end
end
local function updateHighlights()
    if not state.highlight then clearHighlights() return end
    local list=candidates()
    local keep={}
    for i=1,math.min(10,#list) do
        local t=list[i]
        keep[t.obj]=true
        if not state.highlights[t.obj] or not state.highlights[t.obj].Parent then
            local ok,h=pcall(function()
                local v=Instance.new("Highlight")
                v.Name="HALOBLOX_V6_MARKER"
                v.Adornee=t.obj
                v.FillColor=t.group=="SNOWMEN" and COLORS.blue or COLORS.orange
                v.OutlineColor=COLORS.text
                v.FillTransparency=0.80
                v.OutlineTransparency=0.1
                v.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop
                v.Parent=t.obj
                return v
            end)
            if ok then state.highlights[t.obj]=h end
        end
    end
    for obj,h in pairs(state.highlights) do
        if not keep[obj] then pcall(function() h:Destroy() end);state.highlights[obj]=nil end
    end
end

-- Input capability probes: these only establish callable APIs, not game acceptance.
local vim=nil
local vimChecked=false
local function getVIM()
    if vimChecked then return vim end
    vimChecked=true
    local ok,value=pcall(function() return game:GetService("VirtualInputManager") end)
    if ok then vim=value end
    return vim
end
local function equippedTool()
    local ch=player.Character
    if not ch then return nil end
    for _,v in ipairs(ch:GetChildren()) do if v:IsA("Tool") then return v end end
    return nil
end
local function equipTool()
    local t=equippedTool()
    if t then return t end
    if not state.autoEquip then return nil end
    local _,hum=character()
    local bp=player:FindFirstChildOfClass("Backpack")
    if not bp or not hum then return nil end
    for _,v in ipairs(bp:GetChildren()) do
        if v:IsA("Tool") then
            pcall(function() hum:EquipTool(v) end)
            task.wait(0.1)
            return equippedTool()
        end
    end
    return nil
end
local PROFILES={
    AUTO={"TOOL","CLICK","PRESS","VIM_MOUSE","VIRTUAL_USER","Z","X","TOUCH"},
    MOBILE={"TOUCH","VIM_MOUSE","VIRTUAL_USER"},
    MOUSE={"CLICK","PRESS","VIM_MOUSE","VIRTUAL_USER"},
    TOOL={"TOOL"},
    SKILLS={"Z","X"}
}
local function routeAvailable(method)
    if method=="TOOL" then return equippedTool()~=nil or (state.autoEquip and player:FindFirstChildOfClass("Backpack")~=nil) end
    if method=="CLICK" then return type(mouse1click)=="function" end
    if method=="PRESS" then return type(mouse1press)=="function" and type(mouse1release)=="function" end
    if method=="VIM_MOUSE" then return getVIM()~=nil end
    if method=="TOUCH" then return state.tapPoint~=nil and getVIM()~=nil end
    if method=="VIRTUAL_USER" then return Workspace.CurrentCamera~=nil end
    if method=="Z" or method=="X" then
        return getVIM()~=nil or (type(keypress)=="function" and type(keyrelease)=="function")
    end
    return false
end
local function inputRoutes()
    local result={}
    for _,name in ipairs(PROFILES[state.profile] or PROFILES.AUTO) do
        if routeAvailable(name) then result[#result+1]=name end
    end
    -- Prefer routes with confirmed effects, rather than blindly repeating no-op calls.
    table.sort(result,function(a,b)
        local ar=state.routes[a] or {success=0,failed=0}
        local br=state.routes[b] or {success=0,failed=0}
        local as=ar.success*10-ar.failed*0.5
        local bs=br.success*10-br.failed*0.5
        return as>bs
    end)
    return result
end
local function sendInput(method)
    local camera=Workspace.CurrentCamera
    local viewport=camera and camera.ViewportSize or Vector2.new(800,600)
    local point=state.tapPoint or Vector2.new(viewport.X*0.5,viewport.Y*0.5)
    if method=="TOOL" then
        local tool=equipTool()
        if not tool then return false,"Tool missing" end
        local ok,err=pcall(function() tool:Activate() end)
        return ok,ok and "Tool:Activate" or tostring(err)
    elseif method=="CLICK" then
        if type(mouse1click)~="function" then return false,"mouse1click unavailable" end
        local ok,err=pcall(mouse1click)
        return ok,ok and "mouse1click" or tostring(err)
    elseif method=="PRESS" then
        if type(mouse1press)~="function" or type(mouse1release)~="function" then return false,"mouse button APIs missing" end
        local ok,err=pcall(function() mouse1press();task.wait(0.06);mouse1release() end)
        return ok,ok and "mouse1press/release" or tostring(err)
    elseif method=="VIM_MOUSE" then
        local v=getVIM()
        if not v then return false,"VIM unavailable" end
        local ok,err=pcall(function()
            v:SendMouseButtonEvent(math.floor(point.X),math.floor(point.Y),0,true,game,0)
            task.wait(0.06)
            v:SendMouseButtonEvent(math.floor(point.X),math.floor(point.Y),0,false,game,0)
        end)
        return ok,ok and "VIM mouse" or tostring(err)
    elseif method=="TOUCH" then
        local v=getVIM()
        if not v or not state.tapPoint then return false,"Touch not calibrated or VIM unavailable" end
        local ok,err=pcall(function()
            v:SendTouchEvent(0,0,point.X,point.Y)
            task.wait(0.06)
            v:SendTouchEvent(0,2,point.X,point.Y)
        end)
        return ok,ok and "VIM touch (unverified)" or tostring(err)
    elseif method=="VIRTUAL_USER" then
        if not camera then return false,"Camera missing" end
        local ok,err=pcall(function()
            VirtualUser:Button1Down(point,camera.CFrame)
            task.wait(0.06)
            VirtualUser:Button1Up(point,camera.CFrame)
        end)
        return ok,ok and "VirtualUser mouse" or tostring(err)
    elseif method=="Z" or method=="X" then
        local key=method=="Z" and Enum.KeyCode.Z or Enum.KeyCode.X
        local v=getVIM()
        if v then
            local ok=pcall(function()
                v:SendKeyEvent(true,key,false,game)
                task.wait(0.08)
                v:SendKeyEvent(false,key,false,game)
            end)
            if ok then return true,"VIM skill "..method end
        end
        if type(keypress)=="function" and type(keyrelease)=="function" then
            local code=method=="Z" and 0x5A or 0x58
            local ok,err=pcall(function() keypress(code);task.wait(0.08);keyrelease(code) end)
            return ok,ok and "executor key "..method or tostring(err)
        end
        return false,"Key input unavailable"
    end
    return false,"Unknown input method "..tostring(method)
end
local function face(position)
    local _,_,root=character()
    if not root then return end
    local p=Vector3.new(position.X,root.Position.Y,position.Z)
    if (p-root.Position).Magnitude>0.1 then
        pcall(function() root.CFrame=CFrame.lookAt(root.Position,p) end)
    end
end
local function isActive(epoch)
    return state.alive and state.running and epoch==state.epoch
end
local function walkNear(position,epoch)
    local _,hum,root=character()
    if not hum or not root then return false,"Character not available" end
    local delta=Vector3.new(position.X-root.Position.X,0,position.Z-root.Position.Z)
    if delta.Magnitude<=9 then return true,"Within range" end
    if not state.walk then return false,"Walking disabled; approach target manually" end
    if delta.Magnitude>state.radius then return false,"Outside range" end
    -- MoveTo, not instant teleport. Short timeout prevents permanent lockups.
    local destination=Vector3.new(position.X,root.Position.Y,position.Z)-delta.Unit*6
    local ok=pcall(function() hum:MoveTo(destination) end)
    if not ok then return false,"MoveTo rejected" end
    local began=os.clock(); local lastMovement=began; local best=delta.Magnitude
    while isActive(epoch) and os.clock()-began<state.targetTimeout do
        local _,h,r=character()
        if not h or not r then return false,"Character lost" end
        local distance=Vector3.new(position.X-r.Position.X,0,position.Z-r.Position.Z).Magnitude
        if distance<=9 then state.counters.moved=state.counters.moved+1; return true,"Arrived" end
        if distance<best-0.6 then best=distance;lastMovement=os.clock()
        elseif os.clock()-lastMovement>1.8 then
            pcall(function() h:MoveTo(r.Position) end)
            return false,"Blocked or movement stalled"
        end
        task.wait(0.10)
    end
    if not isActive(epoch) then return false,"Cancelled" end
    return false,"Movement timed out"
end
local function observe(target,beforeHP,beforeTrans,beforeAttr)
    if not target.obj.Parent or not target.part.Parent then return true,"Object removed (not necessarily a kill)" end
    if beforeHP~=nil then
        local h=target.obj:IsA("Model") and target.obj:FindFirstChildOfClass("Humanoid") or nil
        if h and h.Health<beforeHP then return true,"HP decreased" end
    end
    if beforeAttr~=nil then
        local n=target.obj:GetAttribute("Health")
        if type(n)=="number" and n<beforeAttr then return true,"Health attribute decreased" end
    end
    if beforeTrans<0.9 and target.part.Transparency>0.97 then return true,"Target hidden" end
    return false,"No observable change"
end
local function routeRecord(method,success)
    local rec=state.routes[method] or {success=0,failed=0}
    if success then rec.success=rec.success+1 else rec.failed=rec.failed+1 end
    state.routes[method]=rec
end
local function attackTarget(t,epoch)
    if not state.attack then return false,"Attacks disabled" end
    if not t.obj.Parent then return false,"Target removed" end
    local _,_,root=character()
    if not root then return false,"Character missing" end
    local dist=(t.part.Position-root.Position).Magnitude
    if dist>24 then return false,"Out of attack range" end
    local routes=inputRoutes()
    if #routes==0 then return false,"No compatible attack API found for "..state.profile end
    local h=t.obj:IsA("Model") and t.obj:FindFirstChildOfClass("Humanoid") or nil
    local beforeHP=h and h.Health or nil
    local beforeAttr=t.obj:GetAttribute("Health")
    if type(beforeAttr)~="number" then beforeAttr=nil end
    local beforeTrans=t.part.Transparency
    if panel and panel.Parent then panel.Visible=false end
    local sentAny=false
    local methodsUsed={}
    for i=1,state.maxAttacks do
        if not isActive(epoch) then return false,"Cancelled" end
        if not t.obj.Parent or not t.part.Parent then return true,"Target object removed" end
        local _,_,r=character()
        if not r then return false,"Character lost" end
        if (t.part.Position-r.Position).Magnitude>24 then return false,"Target moved out of range" end
        face(t.part.Position)
        local method=routes[(i-1)%#routes+1]
        local ok,detail=sendInput(method)
        state.counters.attempts=state.counters.attempts+1
        state.lastMethod=detail
        methodsUsed[#methodsUsed+1]=method
        if ok then sentAny=true else routeRecord(method,false) end
        task.wait((method=="Z" or method=="X") and 0.65 or 0.20)
        local changed,why=observe(t,beforeHP,beforeTrans,beforeAttr)
        if changed then
            if ok then routeRecord(method,true) end
            state.counters.hits=state.counters.hits+1
            if t.group=="PUMPKINS" and (why=="Target hidden" or why=="Target object removed" or why=="Object removed (not necessarily a kill)") then
                state.counters.pumpkins=state.counters.pumpkins+1
            end
            return true,why
        end
    end
    if sentAny then
        for _,method in ipairs(methodsUsed) do routeRecord(method,false) end
        return false,"Input calls ran; target did not react (game may ignore input)"
    end
    return false,"No input API accepted attack calls"
end
local function stop()
    state.running=false
    state.epoch=state.epoch+1
    state.calibrating=false
    local _,hum,root=character()
    if hum and root then pcall(function() hum:MoveTo(root.Position) end) end
    if startButton and startButton.Parent then
        startButton.Text="START SELECTED MODE"
        startButton.BackgroundColor3=COLORS.green
    end
    if panicButton and panicButton.Parent then panicButton.Visible=false end
    status("Stopped")
end
local function close()
    if not state.alive then return end
    stop()
    state.alive=false
    clearHighlights()
    for _,c in ipairs(state.connections) do pcall(function() c:Disconnect() end) end
    if gui then pcall(function() gui:Destroy() end) end
    if env.HALOBLOX_V6_CLOSE==close then env.HALOBLOX_V6_CLOSE=nil end
end
env.HALOBLOX_V6_CLOSE=close

-- Native Roblox UI. No remotely fetched UI libraries or invisible telemetry.
local function corner(parent,n)
    local c=Instance.new("UICorner");c.CornerRadius=UDim.new(0,n or 9);c.Parent=parent
end
local function stroke(parent,color,width)
    local s=Instance.new("UIStroke");s.Color=color or COLORS.accent;s.Thickness=width or 1;s.Transparency=0.45;s.Parent=parent
end
local function label(parent,textValue,height,size,color)
    local t=Instance.new("TextLabel")
    t.Size=UDim2.new(1,-16,0,height or 28)
    t.BackgroundTransparency=1
    t.Text=tostring(textValue)
    t.TextColor3=color or COLORS.text
    t.Font=Enum.Font.Gotham
    t.TextSize=size or 12
    t.TextWrapped=true
    t.TextXAlignment=Enum.TextXAlignment.Left
    t.TextYAlignment=Enum.TextYAlignment.Center
    t.Parent=parent
    return t
end
local function button(parent,textValue,height,color,callback)
    local b=Instance.new("TextButton")
    b.Size=UDim2.new(1,-16,0,height or 37)
    b.Text=textValue
    b.Font=Enum.Font.GothamBold
    b.TextSize=12
    b.TextColor3=COLORS.text
    b.BackgroundColor3=color or COLORS.cell
    b.BorderSizePixel=0
    b.AutoButtonColor=true
    b.Parent=parent
    corner(b,8)
    connect(b.MouseButton1Click,callback)
    return b
end
local function headline(parent,name)
    local l=label(parent,"  "..name,25,11,COLORS.orange)
    l.Font=Enum.Font.GothamBold
    return l
end
local function createPage(id)
    local sc=Instance.new("ScrollingFrame")
    sc.Name=id
    sc.Size=UDim2.new(1,0,1,0)
    sc.BorderSizePixel=0
    sc.BackgroundTransparency=1
    sc.ScrollBarThickness=4
    sc.CanvasSize=UDim2.new(0,0,0,0)
    sc.AutomaticCanvasSize=Enum.AutomaticSize.Y
    sc.Parent=pages
    local l=Instance.new("UIListLayout")
    l.Padding=UDim.new(0,6)
    l.HorizontalAlignment=Enum.HorizontalAlignment.Center
    l.SortOrder=Enum.SortOrder.LayoutOrder
    l.Parent=sc
    local p=Instance.new("UIPadding")
    p.PaddingTop=UDim.new(0,10);p.PaddingBottom=UDim.new(0,12);p.Parent=sc
    return sc
end
local modeButtons={}
local function refreshModes()
    for _,m in ipairs(MODES) do
        local b=modeButtons[m.id]
        if b then
            b.Text=(m.id==state.mode and "[SELECTED] " or "")..m.title
            b.BackgroundColor3=m.id==state.mode and COLORS.accent or COLORS.cell
        end
    end
end
local function setMode(id)
    stop()
    state.mode=id
    saveConfig()
    refreshModes()
    clearHighlights()
    status(modeById[id].desc)
    log("Mode selected: "..modeById[id].title)
end
local function start()
    if state.running then stop();log("Mode stopped");return end
    state.epoch=state.epoch+1
    state.running=true
    startButton.Text="STOP / PAUSE"
    startButton.BackgroundColor3=COLORS.red
    panicButton.Visible=true
    status("Running "..modeById[state.mode].title)
    log("Started "..state.mode)
    if modeById[state.mode].attacks and panel and panel.Parent then panel.Visible=false end
end
local function compatReport()
    local routes=inputRoutes()
    return string.format("Device: touch=%s, keyboard=%s\nVIM: %s | mouse1click: %s | keypress: %s | equipped Tool: %s\nAvailable %s routes: %s\nRemember: callable APIs do not guarantee game damage.",
        tostring(UserInputService.TouchEnabled),tostring(UserInputService.KeyboardEnabled),
        getVIM() and "yes" or "no",type(mouse1click)=="function" and "yes" or "no",
        type(keypress)=="function" and "yes" or "no",equippedTool() and "yes" or "no",
        state.profile,#routes>0 and table.concat(routes,", ") or "none")
end
local function buildUI()
    gui=Instance.new("ScreenGui")
    gui.Name="HALOBLOX_V6_ADVANCED"
    gui.ResetOnSpawn=false
    gui.DisplayOrder=250
    gui.IgnoreGuiInset=false
    gui.Parent=playerGui
    panel=Instance.new("Frame")
    panel.Size=UDim2.new(0.94,0,0.80,0)
    panel.Position=UDim2.new(0.5,0,0.48,0)
    panel.AnchorPoint=Vector2.new(0.5,0.5)
    panel.BackgroundColor3=COLORS.bg
    panel.BorderSizePixel=0
    panel.Parent=gui
    corner(panel,12);stroke(panel,COLORS.accent,1.5)
    local size=Instance.new("UISizeConstraint")
    size.MinSize=Vector2.new(270,330)
    size.MaxSize=Vector2.new(475,590)
    size.Parent=panel
    local head=Instance.new("Frame")
    head.Size=UDim2.new(1,0,0,49)
    head.BackgroundColor3=COLORS.pane
    head.BorderSizePixel=0
    head.Parent=panel
    corner(head,11)
    local name=Instance.new("TextLabel")
    name.Size=UDim2.new(1,-100,1,0)
    name.Position=UDim2.new(0,12,0,0)
    name.BackgroundTransparency=1
    name.Text="HALOBLOX  v6  /  KEYLESS"
    name.TextColor3=COLORS.orange
    name.Font=Enum.Font.GothamBold
    name.TextSize=14
    name.TextXAlignment=Enum.TextXAlignment.Left
    name.Parent=head
    local minimize=Instance.new("TextButton")
    minimize.Size=UDim2.new(0,35,0,35)
    minimize.Position=UDim2.new(1,-81,0,7)
    minimize.BackgroundColor3=COLORS.accent
    minimize.Text="-";minimize.TextColor3=COLORS.text;minimize.TextSize=22
    minimize.Parent=head;corner(minimize,8)
    local exit=Instance.new("TextButton")
    exit.Size=UDim2.new(0,35,0,35)
    exit.Position=UDim2.new(1,-42,0,7)
    exit.BackgroundColor3=COLORS.red
    exit.Text="X";exit.TextColor3=COLORS.text;exit.Font=Enum.Font.GothamBold
    exit.Parent=head;corner(exit,8)
    connect(minimize.MouseButton1Click,function()panel.Visible=false end)
    connect(exit.MouseButton1Click,close)
    statusLabel=Instance.new("TextLabel")
    statusLabel.Size=UDim2.new(1,-18,0,35)
    statusLabel.Position=UDim2.new(0,9,0,52)
    statusLabel.BackgroundTransparency=1
    statusLabel.Text=state.status
    statusLabel.TextColor3=COLORS.orange
    statusLabel.Font=Enum.Font.Gotham
    statusLabel.TextSize=11
    statusLabel.TextWrapped=true
    statusLabel.TextXAlignment=Enum.TextXAlignment.Left
    statusLabel.Parent=panel
    tabs=Instance.new("Frame")
    tabs.Size=UDim2.new(1,-12,0,40)
    tabs.Position=UDim2.new(0,6,0,89)
    tabs.BackgroundTransparency=1
    tabs.Parent=panel
    local tl=Instance.new("UIListLayout")
    tl.FillDirection=Enum.FillDirection.Horizontal
    tl.HorizontalAlignment=Enum.HorizontalAlignment.Center
    tl.Padding=UDim.new(0,4)
    tl.Parent=tabs
    pages=Instance.new("Frame")
    pages.Size=UDim2.new(1,-8,1,-138)
    pages.Position=UDim2.new(0,4,0,133)
    pages.BackgroundTransparency=1
    pages.Parent=panel
    local names={{"HOME","Home"},{"FARM","Farm"},{"EVENTS","Events"},{"COMBAT","Combat"},{"DEBUG","Debug"}}
    local tabButtons={};local pageFrames={}
    local function switchTab(id)
        for key,page in pairs(pageFrames) do page.Visible=key==id end
        for key,b in pairs(tabButtons) do
            b.BackgroundColor3=key==id and COLORS.accent or COLORS.pane
            b.TextColor3=key==id and COLORS.text or COLORS.muted
        end
    end
    for _,entry in ipairs(names) do
        local id,title=entry[1],entry[2]
        local tab=Instance.new("TextButton")
        tab.Size=UDim2.new(0.2,-5,1,-2)
        tab.BackgroundColor3=COLORS.pane
        tab.TextColor3=COLORS.muted
        tab.Text=title
        tab.TextSize=11
        tab.Font=Enum.Font.GothamBold
        tab.Parent=tabs;corner(tab,7)
        tabButtons[id]=tab
        connect(tab.MouseButton1Click,function()switchTab(id)end)
        pageFrames[id]=createPage(id)
    end

    local home=pageFrames.HOME
    headline(home,"CONTROL CENTER")
    metricsLabel=label(home,"Initializing diagnostics...",84,12,COLORS.muted)
    startButton=button(home,"START SELECTED MODE",48,COLORS.green,start)
    button(home,"STOP EVERYTHING",43,COLORS.red,function()stop();clearHighlights();log("Emergency stop")end)
    button(home,"RESCAN VISIBLE WORLD",36,COLORS.accent,function()task.spawn(scan);log("Manual rescan requested")end)
    headline(home,"HOW IT WORKS")
    label(home,"Finder modes highlight targets without attacking. Assist modes approach targets and test the input APIs supported by your executor. A sent input is not a confirmed hit.",83,11,COLORS.muted)
    label(home,"Raids must be started manually. No remote executable code is downloaded, and no credentials or telemetry are sent.",57,11,COLORS.muted)

    local farm=pageFrames.FARM
    headline(farm,"AUTO FARM MODES")
    button(farm,"START / STOP CURRENT MODE",40,COLORS.green,start)
    for _,m in ipairs(MODES) do
        if m.id=="PUMPKIN_AUTO" or m.id=="PUMPKIN_FIND" or m.id=="NPC_GRIND" or m.id=="MIXED" then
            modeButtons[m.id]=button(farm,m.title,36,COLORS.cell,function()setMode(m.id)end)
        end
    end
    headline(farm,"MOVEMENT & TARGETING")
    local walkB
    walkB=button(farm,"WALK TO TARGET: "..(state.walk and "ON" or "OFF"),36,COLORS.cell,function()
        state.walk=not state.walk;saveConfig();walkB.Text="WALK TO TARGET: "..(state.walk and "ON" or "OFF")
    end)
    local radiusB;local radii={90,200,350,600}
    radiusB=button(farm,"TARGET RADIUS: "..state.radius.." STUDS",36,COLORS.cell,function()
        local j=1;for i,v in ipairs(radii) do if v==state.radius then j=i;break end end
        state.radius=radii[j%#radii+1];saveConfig()
        radiusB.Text="TARGET RADIUS: "..state.radius.." STUDS"
    end)
    local timeoutB;local times={5,8,12}
    timeoutB=button(farm,"WALK TIMEOUT: "..state.targetTimeout.." SECONDS",36,COLORS.cell,function()
        local j=1;for i,v in ipairs(times) do if v==state.targetTimeout then j=i;break end end
        state.targetTimeout=times[j%#times+1];saveConfig()
        timeoutB.Text="WALK TIMEOUT: "..state.targetTimeout.." SECONDS"
    end)
    label(farm,"Large radii only search objects your client has loaded. Longer movement timeouts may increase time spent on blocked targets.",61,11,COLORS.muted)

    local events=pageFrames.EVENTS
    headline(events,"HALLOWEEN EVENT MODULES")
    button(events,"START / STOP CURRENT MODE",40,COLORS.green,start)
    for _,m in ipairs(MODES) do
        if m.id=="SNOWMAN_AUTO" or m.id=="SNOWMAN_FIND" or m.id=="RAID_ASSIST" or m.id=="BOSS_FIND" or m.id=="DOOR_FIND" then
            modeButtons[m.id]=button(events,m.title,35,COLORS.cell,function()setMode(m.id)end)
            label(events,m.desc,31,10,COLORS.muted)
        end
    end
    label(events,"Snowmen and event doors spawn conditionally. Highlighting is discovery only. Raid Assist does not start or complete raids automatically.",63,11,COLORS.muted)

    local combat=pageFrames.COMBAT
    headline(combat,"INPUT & DAMAGE")
    local attackB
    attackB=button(combat,"ATTACK ATTEMPTS: "..(state.attack and "ON" or "OFF"),37,COLORS.cell,function()
        state.attack=not state.attack;saveConfig();attackB.Text="ATTACK ATTEMPTS: "..(state.attack and "ON" or "OFF")
    end)
    local profiles={"AUTO","MOBILE","MOUSE","TOOL","SKILLS"}
    local profileB
    profileB=button(combat,"INPUT PROFILE: "..state.profile,37,COLORS.cell,function()
        local j=1;for i,v in ipairs(profiles) do if v==state.profile then j=i;break end end
        state.profile=profiles[j%#profiles+1];saveConfig()
        profileB.Text="INPUT PROFILE: "..state.profile
        log("Input profile: "..state.profile)
    end)
    local equipB
    equipB=button(combat,"AUTO EQUIP TOOL: "..(state.autoEquip and "ON" or "OFF"),37,COLORS.cell,function()
        state.autoEquip=not state.autoEquip;saveConfig()
        equipB.Text="AUTO EQUIP TOOL: "..(state.autoEquip and "ON" or "OFF")
    end)
    local budgetB;local budgets={6,12,20}
    budgetB=button(combat,"ATTACK BUDGET: "..state.maxAttacks.." INPUTS / TARGET",37,COLORS.cell,function()
        local j=1;for i,v in ipairs(budgets) do if v==state.maxAttacks then j=i;break end end
        state.maxAttacks=budgets[j%#budgets+1];saveConfig()
        budgetB.Text="ATTACK BUDGET: "..state.maxAttacks.." INPUTS / TARGET"
    end)
    local tapB
    tapB=button(combat,"CALIBRATE MOBILE ATTACK BUTTON",37,COLORS.accent,function()
        stop();state.calibrating=true;state.calibrateAt=os.clock()+0.6
        panel.Visible=false
        log("Tap the game's actual ATTACK button once to calibrate")
    end)
    button(combat,"TEST A SINGLE INPUT",37,COLORS.cell,function()
        task.spawn(function()
            panel.Visible=false
            task.wait(0.4)
            local routes=inputRoutes()
            local method=routes[1]
            if not method then log("Self-test: no callable input methods");status("Input self-test failed: no methods")
            else
                local ok,message=sendInput(method)
                state.lastMethod=message
                log("Self-test "..(ok and "sent: " or "failed: ")..tostring(message))
                status(ok and "Input sent; check if game reacted" or "Input failed: "..tostring(message))
            end
        end)
    end)
    local highlightsB
    highlightsB=button(combat,"TARGET HIGHLIGHTS: "..(state.highlight and "ON" or "OFF"),37,COLORS.cell,function()
        state.highlight=not state.highlight;saveConfig()
        highlightsB.Text="TARGET HIGHLIGHTS: "..(state.highlight and "ON" or "OFF")
        if not state.highlight then clearHighlights() end
    end)
    label(combat,"The test proves only that an API call executed. If attacks do not reduce target health or remove a pumpkin, the game-side combat remains unverified.",77,11,COLORS.muted)

    local debugPage=pageFrames.DEBUG
    headline(debugPage,"COMPATIBILITY REPORT")
    compatLabel=label(debugPage,"Loading...",133,11,COLORS.muted)
    button(debugPage,"REFRESH INPUT CHECK",36,COLORS.accent,function()compatLabel.Text=compatReport()end)
    button(debugPage,"SAVE SETTINGS",36,COLORS.cell,function()
        log(saveConfig() and "Saved preferences" or "File saving unsupported; session only")
    end)
    headline(debugPage,"LIVE LOGS")
    logsLabel=label(debugPage,"No events yet",300,10,COLORS.muted)
    logsLabel.TextYAlignment=Enum.TextYAlignment.Top
    button(debugPage,"CLEAR LOGS",34,COLORS.cell,function()
        state.history={};logsLabel.Text="Cleared"
    end)
    refreshModes()
    compatLabel.Text=compatReport()
    switchTab("HOME")

    local float=Instance.new("TextButton")
    float.Name="OpenHALOBLOX"
    float.Size=UDim2.new(0,54,0,54)
    float.Position=UDim2.new(0,9,0.43,0)
    float.BackgroundColor3=COLORS.accent
    float.Text="HB"
    float.TextSize=16
    float.Font=Enum.Font.GothamBold
    float.TextColor3=COLORS.text
    float.Parent=gui;corner(float,13)
    connect(float.MouseButton1Click,function() panel.Visible=not panel.Visible end)
    panicButton=Instance.new("TextButton")
    panicButton.Size=UDim2.new(0,57,0,36)
    panicButton.Position=UDim2.new(0,9,0.43,59)
    panicButton.Text="STOP"
    panicButton.Font=Enum.Font.GothamBold
    panicButton.TextSize=12
    panicButton.TextColor3=COLORS.text
    panicButton.BackgroundColor3=COLORS.red
    panicButton.Visible=false
    panicButton.Parent=gui;corner(panicButton,8)
    connect(panicButton.MouseButton1Click,function()stop();log("Floating emergency stop")end)
    local dragging,startPos,origin=false,nil,nil
    connect(head.InputBegan,function(i)
        if i.UserInputType==Enum.UserInputType.Touch or i.UserInputType==Enum.UserInputType.MouseButton1 then
            dragging=true;startPos=i.Position;origin=panel.Position
        end
    end)
    connect(UserInputService.InputChanged,function(i)
        if dragging and startPos and (i.UserInputType==Enum.UserInputType.Touch or i.UserInputType==Enum.UserInputType.MouseMovement) then
            local d=i.Position-startPos
            panel.Position=UDim2.new(origin.X.Scale,origin.X.Offset+d.X,origin.Y.Scale,origin.Y.Offset+d.Y)
        end
    end)
    connect(UserInputService.InputEnded,function(i)
        if i.UserInputType==Enum.UserInputType.Touch or i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end
    end)
    connect(UserInputService.InputBegan,function(i,processed)
        if not state.calibrating or os.clock()<state.calibrateAt then return end
        if i.UserInputType~=Enum.UserInputType.Touch and i.UserInputType~=Enum.UserInputType.MouseButton1 then return end
        state.tapPoint=Vector2.new(i.Position.X,i.Position.Y)
        state.calibrating=false
        tapB.Text="TAP SAVED: "..math.floor(state.tapPoint.X)..","..math.floor(state.tapPoint.Y)
        log("Mobile tap calibrated at "..math.floor(state.tapPoint.X)..","..math.floor(state.tapPoint.Y))
        status("Tap location saved; executor must support replay")
        if panel then panel.Visible=true end
    end)
end

local function cycle(epoch)
    local m=modeById[state.mode]
    local list=candidates()
    local first=list[1]
    if not first then
        status("No loaded "..m.group.." target within "..state.radius.." studs")
        if os.clock()-state.lastNoTargets>15 then
            log("No candidates in range; streaming/name differences possible")
            state.lastNoTargets=os.clock()
        end
        task.wait(0.7)
        return
    end
    if not m.attacks then
        status("Found: "..first.obj.Name.." ("..math.floor(first.d).." studs)")
        task.wait(0.6)
        return
    end
    status("Approaching "..first.obj.Name.." ("..math.floor(first.d).." studs)")
    local ok,reason=walkNear(first.part.Position,epoch)
    if not isActive(epoch) then return end
    if not ok then
        state.counters.failures=state.counters.failures+1
        state.cooldown[first.obj]=os.clock()+8
        status("Move failed: "..reason)
        task.wait(0.25)
        return
    end
    local hit,why=attackTarget(first,epoch)
    if not isActive(epoch) then return end
    if hit then
        status("Observed: "..why)
        log(first.obj.Name..": "..why)
        state.cooldown[first.obj]=os.clock()+4
    else
        state.counters.failures=state.counters.failures+1
        state.cooldown[first.obj]=os.clock()+18
        status("No confirmed damage: "..why)
        log(first.obj.Name..": "..why)
    end
    task.wait(0.3)
end

buildUI()
connect(Workspace.DescendantAdded,index)
connect(Workspace.DescendantRemoving,function(obj)
    for _,group in pairs(state.tracked) do group[obj]=nil end
end)
connect(player.CharacterAdded,function()
    state.cooldown=setmetatable({}, {__mode="k"})
    status("Character respawning; waiting for a valid Humanoid")
end)
log("HALOBLOX v6 loaded; standalone keyless client")
log("The supplied FlowAuth sample is a remote loader, not readable farm logic")
task.spawn(scan)

task.spawn(function()
    while state.alive do
        if state.running then
            local epoch=state.epoch
            local ok,err=pcall(cycle,epoch)
            if not ok then
                state.lastError=tostring(err)
                state.counters.failures=state.counters.failures+1
                log("Cycle recovered: "..state.lastError)
                task.wait(0.9)
            end
        else
            task.wait(0.28)
        end
    end
end)
task.spawn(function()
    while state.alive do
        local ok,err=pcall(function()
            updateHighlights()
            if metricsLabel and metricsLabel.Parent then
                local group=groupForMode()
                local n=#candidates()
                metricsLabel.Text=string.format(
                    "Mode: %s\nNearby targets: %d | Scan: %s\nInput calls: %d | Reactions: %d | Pumpkin changes: %d\nMove arrivals: %d | Skips/errors: %d\nLast input: %s",
                    state.mode,n,state.scanBusy and "busy" or "idle",state.counters.attempts,
                    state.counters.hits,state.counters.pumpkins,state.counters.moved,
                    state.counters.failures,tostring(state.lastMethod))
            end
        end)
        if not ok then state.lastError=tostring(err) end
        task.wait(1.1)
    end
end)
-- A periodic rescan is intentionally slow. DescendantAdded handles streaming.
task.spawn(function()
    while state.alive do
        task.wait(85)
        if state.alive then scan() end
    end
end)
