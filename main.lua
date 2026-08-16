local function table_find(t, value)
    for i = 1, #t do
        if t[i] == value then return i end
    end
    return nil
end

local function parseJSON(str)
    local pos = 1

    local function skip_ws()
        local p = str:find("[^ \t\r\n]", pos)
        pos = p or (#str + 1)
    end

    local function parse_string()
        pos = pos + 1
        local chunks = {}
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(chunks)
            elseif c == '\\' then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if     esc == '"'  then chunks[#chunks + 1] = '"'
                elseif esc == '\\' then chunks[#chunks + 1] = '\\'
                elseif esc == 'n'  then chunks[#chunks + 1] = '\n'
                elseif esc == 'r'  then chunks[#chunks + 1] = '\r'
                elseif esc == 't'  then chunks[#chunks + 1] = '\t'
                elseif esc == '/'  then chunks[#chunks + 1] = '/'
                else                    chunks[#chunks + 1] = esc
                end
            else
                chunks[#chunks + 1] = c
            end
            pos = pos + 1
        end
        return table.concat(chunks)
    end

    local function parse_number()
        local start = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while pos <= #str and str:sub(pos, pos):match("[%d%.eE%+%-]") do
            pos = pos + 1
        end
        return tonumber(str:sub(start, pos - 1))
    end

    local parse_value

    local function parse_object()
        pos = pos + 1
        local obj = {}
        skip_ws()
        if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
        while true do
            skip_ws()
            local key = parse_string()
            skip_ws()
            pos = pos + 1
            skip_ws()
            obj[key] = parse_value()
            skip_ws()
            if str:sub(pos, pos) == ',' then
                pos = pos + 1
            else
                break
            end
        end
        skip_ws()
        if str:sub(pos, pos) == '}' then pos = pos + 1 end
        return obj
    end

    local function parse_array()
        pos = pos + 1
        local arr = {}
        skip_ws()
        if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
        while true do
            skip_ws()
            arr[#arr + 1] = parse_value()
            skip_ws()
            if str:sub(pos, pos) == ',' then
                pos = pos + 1
            else
                break
            end
        end
        skip_ws()
        if str:sub(pos, pos) == ']' then pos = pos + 1 end
        return arr
    end

    parse_value = function()
        skip_ws()
        local c = str:sub(pos, pos)
        if     c == '"' then return parse_string()
        elseif c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c == 't' then pos = pos + 4; return true
        elseif c == 'f' then pos = pos + 5; return false
        elseif c == 'n' then pos = pos + 4; return nil
        else                  return parse_number()
        end
    end

    skip_ws()
    return parse_value()
end


local offsets

for _, url in ipairs({
    "https://offsets.imtheo.lol/Offsets.json",
    "https://artxficial.dev/misc/theo",
}) do
    local body, status = utility.HttpGet(url)
    if body then
        local ok, result = pcall(function()
            local data = parseJSON(body)
            return data.Offsets or data
        end)
        if ok and type(result) == "table" and next(result) then
            print("[DEBUG][Offsets] Successfully using offsets from: " .. url)
            offsets = result
            break
        end
    end
end

if not offsets then
    print("[DEBUG][Offsets] Both endpoints failed. Defaulting to empty table.")
    offsets = {}
end

local KnownOffsets = {
    ["AnimationId"]                = offsets.Misc and offsets.Misc.AnimationId or 0,
    ["ClassDescriptor"]            = offsets.Instance and offsets.Instance.ClassDescriptor or 0,
    ["ClassDescriptorToClassName"] = offsets.Instance and offsets.Instance.ClassName or 0,
    ["Name"]                       = offsets.Instance and offsets.Instance.Name or 0,
    ["TimePosition"]               = offsets.AnimationTrack and offsets.AnimationTrack.TimePosition or 0,
    ["ActiveAnimations"]           = offsets.Animator and offsets.Animator.ActiveAnimations or 0,
    ["Animation"]                  = offsets.AnimationTrack and offsets.AnimationTrack.Animation or 0,
    ["Speed"]                      = offsets.AnimationTrack and offsets.AnimationTrack.Speed or 0,
    ["IsPlaying"]                  = offsets.AnimationTrack and offsets.AnimationTrack.IsPlaying or 0,
    ["NodeNext"]                   = 0x10,
}

local function GetAnimatorAddress(Character)
    if not Character or Character.Address == 0 then return nil end

    local Humanoid = Character:FindFirstChildWhichIsA("Humanoid")
    if not Humanoid then return nil end

    local Animator = Humanoid:FindFirstChildWhichIsA("Animator")
    return Animator and Animator.Address or nil
end

local function GetPlayingAnimationTracks(Character)
    local AnimatorAddress = GetAnimatorAddress(Character)
    if not AnimatorAddress then return nil end

    local ListHead_Ptr = memory.Read(AnimatorAddress + KnownOffsets.ActiveAnimations, "ptr")
    if not ListHead_Ptr or ListHead_Ptr == 0 then return nil end

    local firstNode = memory.Read(ListHead_Ptr, "ptr")
    if not firstNode or firstNode == 0 or firstNode == ListHead_Ptr then
        return {}
    end

    local AnimationTracks = {}
    local currentNode = firstNode
    local foundCount = 0

    while currentNode and currentNode ~= 0 and currentNode ~= ListHead_Ptr do
        local track = memory.Read(currentNode + KnownOffsets.NodeNext, "ptr")

        if track then
            foundCount = foundCount + 1
            AnimationTracks[foundCount] = track
        end

        if foundCount >= 50 then break end

        local nextNode = memory.Read(currentNode, "ptr")
        if nextNode == ListHead_Ptr or nextNode == 0 or not nextNode then
            break
        end

        currentNode = nextNode
    end

    return AnimationTracks
end

local function GetTimePosition(AnimationTrackAddress)
    if not AnimationTrackAddress or AnimationTrackAddress == 0 then return nil end
    return memory.Read(AnimationTrackAddress + KnownOffsets.TimePosition, "float")
end

local function ExtractAnimationTrackInfo(AnimationTrackAddress)
    if not AnimationTrackAddress or AnimationTrackAddress == 0 then return nil end

    local Animation      = memory.Read(AnimationTrackAddress + KnownOffsets.Animation, "ptr")
    local AnimIdPointer  = memory.Read(Animation + KnownOffsets.AnimationId, "ptr")
    local AnimationId    = memory.ReadString(AnimIdPointer)

    local NamePtr        = memory.Read(AnimationTrackAddress + KnownOffsets.Name, "ptr")
    local Name           = memory.ReadString(NamePtr)
    local TimePosition   = memory.Read(AnimationTrackAddress + KnownOffsets.TimePosition, "float")
    local Speed          = memory.Read(AnimationTrackAddress + KnownOffsets.Speed, "float")
    local IsPlaying      = memory.Read(AnimationTrackAddress + KnownOffsets.IsPlaying, "u8")

    return {
        Address      = AnimationTrackAddress,
        Name         = Name,
        AnimationId  = AnimationId,
        TimePosition = TimePosition,
        Speed        = Speed,
        IsPlaying    = IsPlaying,
    }
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({ _listeners = {} }, Signal)
end

function Signal:Connect(callback)
    table.insert(self._listeners, callback)
    return {
        Disconnect = function()
            for i = 1, #self._listeners do
                if self._listeners[i] == callback then
                    table.remove(self._listeners, i)
                    break
                end
            end
        end,
    }
end

function Signal:Fire(...)
    for i = 1, #self._listeners do
        self._listeners[i](...)
    end
end

local AnimationTracker = {}
AnimationTracker.__index = AnimationTracker

function AnimationTracker.new(IgnoreIds)
    local self = setmetatable({}, AnimationTracker)

    self.AnimationAdded   = Signal.new()
    self.AnimationUpdated = Signal.new()
    self.AnimationRemoved = Signal.new()
    self.IgnoreIds        = IgnoreIds or {}
    self._cachedTracks    = {}

    return self
end

function AnimationTracker:Update(character)
    local tracksPlaying = GetPlayingAnimationTracks(character)
    if not tracksPlaying then return {} end

    local currentAddresses = {}
    local activeSnapshot   = {}

    for i = 1, #tracksPlaying do
        local address = tracksPlaying[i]
        currentAddresses[address] = true

        local info = self._cachedTracks[address]
        local newlyExtracted = false

        if not info then
            info = ExtractAnimationTrackInfo(address)
            if info then
                self._cachedTracks[address] = info
                newlyExtracted = true
            end
        end

        if info then
            local assetId   = info.AnimationId
            local numericId = assetId and tonumber(string.match(tostring(assetId), "%d+"))
            local ignored   = numericId and table_find(self.IgnoreIds, numericId)

            if not ignored then
                if newlyExtracted then
                    self.AnimationAdded:Fire(info)
                end

                local liveTime = GetTimePosition(address) or info.TimePosition
                info.TimePosition = liveTime

                self.AnimationUpdated:Fire(info, liveTime)
                table.insert(activeSnapshot, info)
            end
        end
    end

    for address, cachedInfo in pairs(self._cachedTracks) do
        if not currentAddresses[address] then
            self.AnimationRemoved:Fire(cachedInfo)
            self._cachedTracks[address] = nil
        end
    end

    return activeSnapshot
end

_G.AnimationTracker = AnimationTracker

menu.AddTab("Auto Parry", "P")

menu.AddGroup("Auto Parry", "Parry Settings", 0, false)
menu.AddCheckbox("Auto Parry", "Parry Settings", "ap_enabled", "Enabled", true, {
    key = 0x50,
})
menu.AddSliderInt("Auto Parry", "Parry Settings", "ap_distance", "Trigger Distance", 5, 50, 18, "%d studs")
menu.AddSliderInt("Auto Parry", "Parry Settings", "ap_viewangle", "Facing View Angle", 30, 360, 150, "%d\xC2\xB0")
menu.AddSliderFloat("Auto Parry", "Parry Settings", "ap_cooldown", "Parry Cooldown", 0.5, 10.0, 2.5, "%.1fs")
menu.AddSliderFloat("Auto Parry", "Parry Settings", "ap_delay", "Reaction Delay", 0.0, 0.5, 0.0, "%.3fs")
menu.AddCheckbox("Auto Parry", "Parry Settings", "ap_humanizer", "Humanizer (+/-80ms)", false, {
    parent = "ap_enabled",
})
menu.AddCheckbox("Auto Parry", "Parry Settings", "ap_notify", "Show Parried Toasts", true, {
    parent = "ap_enabled",
})

menu.AddGroup("Auto Parry", "Visuals & Status", 0, true)
menu.AddCheckbox("Auto Parry", "Visuals & Status", "ap_circle", "Range Circle", true, {
    colorpicker = { 0, 1, 0.67, 1 },
    parent = "ap_enabled",
})
menu.AddCheckbox("Auto Parry", "Visuals & Status", "ap_hud", "Target Status HUD", false, {
    parent = "ap_enabled",
})
menu.AddCheckbox("Auto Parry", "Visuals & Status", "ap_debug", "Console Debug Logs", false, {
    parent = "ap_enabled",
})
menu.AddSeparator("Auto Parry", "Visuals & Status")
menu.AddLabel("Auto Parry", "Visuals & Status", "Parry Statistics:")
local ap_totalParries = 0
local ap_lastParriedName = "None"

menu.AddButton("Auto Parry", "Visuals & Status", "ap_reset_btn", "Reset Parry Counter", function()
    ap_totalParries = 0
    ap_lastParriedName = "None"
    notify.Success("Auto Parry", "Parry counter reset.")
end)

local IgnoreIds = {
    4764828935,
    4611813021,
    4639817538,
    6786106507,
    180435571,
    7479225627,
    7261701036,
    9377853166,
    9377852354,
    9377851344,
    6789165310,
    6789231619,
}

local AnimationTrackerInst = AnimationTracker.new(IgnoreIds)

local ATTACK_ANIMS = {
    ["rbxassetid://113255068724446"] = { DisplayName = "Slash 1",    ReactionTime = 0 },
    ["rbxassetid://74968262036854"]  = { DisplayName = "Slash 2",    ReactionTime = 0 },
    ["rbxassetid://110355011987939"] = { DisplayName = "Slash 3",    ReactionTime = 0 },
    ["rbxassetid://139369275981139"] = { DisplayName = "Slash 4",    ReactionTime = 0 },
    ["rbxassetid://132817836308238"] = { DisplayName = "Slash 5",    ReactionTime = 0 },
    ["rbxassetid://129784271201071"] = { DisplayName = "Heavy 1",    ReactionTime = 0 },
    ["rbxassetid://133963973694098"] = { DisplayName = "Heavy 2",    ReactionTime = 0 },
    ["rbxassetid://117042998468241"] = { DisplayName = "Attack 8",   ReactionTime = 0 },
    ["rbxassetid://105374834496520"] = { DisplayName = "Attack 9",   ReactionTime = 0 },
    ["rbxassetid://111920872708571"] = { DisplayName = "Attack 10",  ReactionTime = 0 },
    ["rbxassetid://78432063483146"]  = { DisplayName = "Attack 11",  ReactionTime = 0 },
    ["rbxassetid://118907603246885"] = { DisplayName = "Attack 12",  ReactionTime = 0 },
    ["rbxassetid://138720291317243"] = { DisplayName = "Attack 13",  ReactionTime = 0 },
    ["rbxassetid://115244153053858"] = { DisplayName = "Attack 14",  ReactionTime = 0 },
    ["rbxassetid://130593238885843"] = { DisplayName = "Attack 15",  ReactionTime = 0 },
    ["rbxassetid://122812055447896"] = { DisplayName = "Attack 16",  ReactionTime = 0 },
    ["rbxassetid://78935059863801"]  = { DisplayName = "Attack 17",  ReactionTime = 0 },
    ["rbxassetid://135002183282873"] = { DisplayName = "Attack 18",  ReactionTime = 0 },
    ["rbxassetid://121216847022485"] = { DisplayName = "Attack 19",  ReactionTime = 0 },
}

local function getAttackAnimConfig(rawAnimId, name)
    if not rawAnimId or rawAnimId == "" then return nil end

    local entry = ATTACK_ANIMS[rawAnimId]
    if entry then return entry end

    local numId = tostring(rawAnimId):match("%d+")
    if numId then
        local formattedId = "rbxassetid://" .. numId
        entry = ATTACK_ANIMS[formattedId]
        if entry then return entry end

        local numKey = tonumber(numId)
        if numKey and ATTACK_ANIMS[numKey] then
            return ATTACK_ANIMS[numKey]
        end
    end

    local lId   = tostring(rawAnimId):lower()
    local lName = tostring(name or ""):lower()
    if lId:find("attack") or lId:find("swing") or lId:find("slash") or lId:find("strike") or
       lName:find("attack") or lName:find("swing") or lName:find("slash") or lName:find("strike") or
       lName:find("m1") or lName:find("m2") then
        return { DisplayName = name or "Keyword Strike Match", ReactionTime = 0 }
    end

    return nil
end

local lastParryTime     = 0
local debugLogThrottle  = 0
local pendingParryTime  = 0
local AnimationRegistry = {}

local lastKillerScanTick = 0
local cachedKillerEntity = nil

local KILLER_KEYWORDS = { "slas", "kill", "veil" }
local WEAPON_KEYWORDS = { "spear", "veil", "kill", "weapon", "blade", "knife" }

local function matchesAny(str, keywords)
    for i = 1, #keywords do
        if str:find(keywords[i]) then return true end
    end
    return false
end

local function getKillerEntity()
    local now = utility.GetTime()

    if cachedKillerEntity and cachedKillerEntity.IsValid and cachedKillerEntity.IsAlive then
        if now - lastKillerScanTick < 1.5 then
            return cachedKillerEntity
        end
    end

    lastKillerScanTick = now
    local players = entity.GetPlayers()

    for i = 1, #players do
        local p = players[i]
        if not p.IsLocal and p.IsAlive and p.IsValid then
            local pName    = tostring(p.Name or ""):lower()
            local dispName = tostring(p.DisplayName or ""):lower()
            if matchesAny(pName, KILLER_KEYWORDS) or matchesAny(dispName, KILLER_KEYWORDS) then
                cachedKillerEntity = p
                return p
            end

            if p.HasTeam then
                local teamName = tostring(p.Team or ""):lower()
                if matchesAny(teamName, KILLER_KEYWORDS) then
                    cachedKillerEntity = p
                    return p
                end
            end

            local toolName = tostring(p.ToolName or ""):lower()
            if toolName ~= "" and matchesAny(toolName, WEAPON_KEYWORDS) then
                cachedKillerEntity = p
                return p
            end
        end
    end

    for _, modelName in ipairs({ "Slasher", "Killer", "Veil" }) do
        local model = game.Workspace:FindFirstChild(modelName)
        if model then
            for i = 1, #players do
                local p = players[i]
                if not p.IsLocal and p.IsAlive and p.Character then
                    if p.Character.Address == model.Address then
                        cachedKillerEntity = p
                        return p
                    end
                end
            end
        end
    end

    cachedKillerEntity = nil
    return nil
end

local function drawRangeCircle(localPos, radius)
    local col      = menu.GetColor("ap_circle")
    local PI2      = math.pi * 2
    local segments = 36
    local centerY  = localPos.Y - 3

    local prevSx, prevSy, prevOk

    for i = 0, segments do
        local angle = PI2 * i / segments
        local wx = localPos.X + math.cos(angle) * radius
        local wz = localPos.Z + math.sin(angle) * radius
        local sx, sy, ok = draw.WorldToScreen(wx, centerY, wz)

        if i > 0 and ok and prevOk then
            draw.Line(prevSx, prevSy, sx, sy, col, 2)
        end

        prevSx, prevSy, prevOk = sx, sy, ok
    end
end

local function updateAutoParry(now)
    if pendingParryTime > 0 and now >= pendingParryTime then
        pendingParryTime = 0
        utility.MouseClick("right")
    end

    if not menu.Get("ap_enabled") then return end

    local lp = entity.GetLocalPlayer()
    if not lp or not lp.IsAlive then return end

    local localPos = lp.Position
    if not localPos then return end

    local maxDist = menu.Get("ap_distance")
    if menu.Get("ap_circle") then
        drawRangeCircle(localPos, maxDist)
    end

    local killer = getKillerEntity()
    local debug  = menu.Get("ap_debug")

        if menu.Get("ap_hud") then
        local hudItems = {
            "Status: " .. (killer and "Killer Locked" or "Searching..."),
            "Total Parries: " .. tostring(ap_totalParries),
            "Last Parried: " .. tostring(ap_lastParriedName),
        }
        if killer and killer.Position then
            local dist = (localPos - killer.Position).Magnitude
            table.insert(hudItems, string.format("Target: %s (%.1fm)", killer.Name, dist))
        end
        draw.Window(20, 80, "ap_hud_win", "Auto Parry Info", hudItems)
    end

    if now - lastParryTime < menu.Get("ap_cooldown") then return end
    if pendingParryTime > 0 then return end

    if not killer then
        if debug and (now - debugLogThrottle > 3) then
            debugLogThrottle = now
            print("[DEBUG][AUTO PARRY] Killer not found.")
        end
        return
    end

    local killerPos = killer.Position
    if not killerPos then return end

    local diff     = localPos - killerPos
    local distance = diff.Magnitude

    if distance > maxDist then
        if debug and (now - debugLogThrottle > 3) then
            debugLogThrottle = now
            print(string.format("[DEBUG][AUTO PARRY] Out of range. Dist: %.1f (Limit: %d)", distance, maxDist))
        end
        return
    end

    local viewAngle = menu.Get("ap_viewangle")
    local toLocal   = diff.Unit
    local killerLook = killer.LookVector
    local dot    = killerLook:Dot(toLocal)
    local minDot = math.cos(math.rad(viewAngle / 2))

    if dot < minDot then
        if debug and (now - debugLogThrottle > 3) then
            debugLogThrottle = now
            print(string.format("[DEBUG][AUTO PARRY] Not facing. Dist: %.1f | Dot: %.2f (Min: %.2f)", distance, dot, minDot))
        end
        return
    end

    local killerChar = killer.Character
    if not killerChar then return end

    local activeTracks = {}
    pcall(function()
        activeTracks = AnimationTrackerInst:Update(killerChar) or {}
    end)

    local currentActiveIds = {}
    local isAttacking      = false
    local detectedAnimId   = nil
    local detectedAnimName = "Attack"

    for _, anim in ipairs(activeTracks) do
        if anim and anim.AnimationId then
            local rawAnimId = tostring(anim.AnimationId)
            local numId     = tonumber(rawAnimId:match("%d+"))

            if not (numId and table_find(IgnoreIds, numId)) then
                local animName    = tostring(anim.Name or "Unknown")
                local timePos     = anim.TimePosition or 0
                local attackConfig = getAttackAnimConfig(rawAnimId, animName)

                if attackConfig then
                    local animKey = anim.Address or rawAnimId
                    currentActiveIds[animKey] = true

                    if not AnimationRegistry[animKey] then
                        AnimationRegistry[animKey] = {
                            StartTime        = now - timePos,
                            Processed        = false,
                            CurrentTrackTime = timePos,
                            AnimationId      = rawAnimId,
                        }
                    end

                    local regData = AnimationRegistry[animKey]

                    if regData.CurrentTrackTime and (timePos < regData.CurrentTrackTime) then
                        regData.Processed = false
                        regData.StartTime = now - timePos
                    end
                    regData.CurrentTrackTime = timePos

                    local reactionTime = attackConfig.ReactionTime or 0
                    if not regData.Processed and timePos >= reactionTime then
                        isAttacking    = true
                        regData.Processed = true
                        detectedAnimId   = rawAnimId
                        detectedAnimName = attackConfig.DisplayName or animName
                        break
                    end
                end
            end
        end
    end

    for key, _ in pairs(AnimationRegistry) do
        if not currentActiveIds[key] then
            AnimationRegistry[key] = nil
        end
    end

    if not isAttacking then return end

    lastParryTime = now
    ap_totalParries = ap_totalParries + 1
    ap_lastParriedName = detectedAnimName

    if debug then
        print(string.format("[DEBUG][AUTO PARRY] Triggered: %s (%s) | Dist: %.2f | Dot: %.2f",
            tostring(detectedAnimName), tostring(detectedAnimId), distance, dot))
    end

    if menu.Get("ap_notify") then
        notify.Success(string.format("Parried %s! (%.1fm)", tostring(detectedAnimName), distance))
    end

    local delayVal = menu.Get("ap_delay")
    if menu.Get("ap_humanizer") then
        delayVal = math.max(0, delayVal + math.random(-80, 80) / 1000)
    end

    if delayVal > 0 then
        pendingParryTime = now + delayVal
    else
        utility.MouseClick("right")
    end
end

menu.SetCallback("ap_enabled", function(enabled)
    if enabled then
        notify.Success("Auto Parry ENABLED")
    else
        notify.Warning("Auto Parry DISABLED")
    end
end)


menu.AddTab("Skill Check", "S")

menu.AddGroup("Skill Check", "Skill Check Settings", 0, false)
menu.AddCheckbox("Skill Check", "Skill Check Settings", "sc_enabled", "Enabled", true, {
    key = 0x56,
})
menu.AddCombo("Skill Check", "Skill Check Settings", "sc_mode", "Hit Mode", {
    "Great / Perfect (100%)",
    "Custom Calibration",
}, 0, {
    parent = "sc_enabled",
})
menu.AddSliderFloat("Skill Check", "Skill Check Settings", "sc_delay", "Timing Offset", -0.05, 0.10, 0.00, "%.3fs", {
    parent = "sc_enabled",
})
menu.AddSliderInt("Skill Check", "Skill Check Settings", "sc_hold_ms", "Key Hold Duration", 10, 250, 120, "%d ms", {
    parent = "sc_enabled",
})
menu.AddSliderInt("Skill Check", "Skill Check Settings", "sc_chance", "Success Rate", 50, 100, 100, "%d%%", {
    parent = "sc_enabled",
})
menu.AddCheckbox("Skill Check", "Skill Check Settings", "sc_notify", "Show Success Toasts", true, {
    parent = "sc_enabled",
})

menu.AddGroup("Skill Check", "Calibration & Status", 0, true)
menu.AddSliderInt("Skill Check", "Calibration & Status", "sc_custom_start", "Custom Start Angle", 0, 360, 104, "%d\xC2\xB0", {
    parent = "sc_enabled",
})
menu.AddSliderInt("Skill Check", "Calibration & Status", "sc_custom_end", "Custom End Angle", 0, 360, 114, "%d\xC2\xB0", {
    parent = "sc_enabled",
})
menu.AddCheckbox("Skill Check", "Calibration & Status", "sc_hud", "Skill Check Info HUD", false, {
    parent = "sc_enabled",
})
menu.AddCheckbox("Skill Check", "Calibration & Status", "sc_debug", "Console Debug Logs", false, {
    parent = "sc_enabled",
})
menu.AddSeparator("Skill Check", "Calibration & Status")
menu.AddLabel("Skill Check", "Calibration & Status", "Statistics:")
local sc_totalSuccess = 0
local sc_lastHitTime = 0
local pendingSkillCheckHitTime = 0

menu.AddButton("Skill Check", "Calibration & Status", "sc_reset_btn", "Reset Success Counter", function()
    sc_totalSuccess = 0
    notify.Success("Skill Check", "Success counter reset.")
end)

local sc_line, sc_goal, sc_frame = nil, nil, nil
local sc_elementsCached = false

local function InSweetSpot()
    if not sc_line or not sc_goal then return false end
    local needle = sc_line.Rotation % 360
    local target = sc_goal.Rotation % 360

    local mode = menu.Get("sc_mode") or 0
    local startOffset = 104
    local endOffset   = 114

    if mode == 1 then
        startOffset = menu.Get("sc_custom_start") or 104
        endOffset   = menu.Get("sc_custom_end") or 114
    end

    local startAngle = (target + startOffset) % 360
    local endAngle   = (target + endOffset) % 360

    if startAngle > endAngle then
        return (needle >= startAngle or needle <= endAngle), needle, target
    else
        return (needle >= startAngle and needle <= endAngle), needle, target
    end
end

local function FindGuiElements()
    local lp = entity.GetLocalPlayer()
    if not lp then return false end

    local pg = lp.Player and lp.Player:FindFirstChild("PlayerGui")
    if not pg then return false end

    local prompt = pg:FindFirstChild("SkillCheckPromptGui")
    if not prompt then return false end

    sc_frame = prompt:FindFirstChild("Check")
    if not sc_frame then return false end

    sc_line = sc_frame:FindFirstChild("Line")
    sc_goal = sc_frame:FindFirstChild("Goal")

    sc_elementsCached = sc_line ~= nil and sc_goal ~= nil
    return sc_elementsCached
end

local function ValidateCache()
    if not sc_elementsCached then return false end
    return utility.IsValid(sc_frame) and utility.IsValid(sc_line) and utility.IsValid(sc_goal)
end

local function updateAutoSkillCheck(now)
    if pendingSkillCheckHitTime > 0 and now >= pendingSkillCheckHitTime then
        pendingSkillCheckHitTime = 0
        local holdMs = menu.Get("sc_hold_ms") or 120
        utility.KeyPress(0x20, holdMs)
        sc_elementsCached = false
        sc_line, sc_goal, sc_frame = nil, nil, nil
        sc_totalSuccess = sc_totalSuccess + 1
        sc_lastHitTime = now

        if menu.Get("sc_notify") then
            notify.Success("Skill Check Solved!", "Hit spacebar automatically", 2)
        end
    end

    if not menu.Get("sc_enabled") then return end

    local hasElements = ValidateCache() or FindGuiElements()
    local isPromptActive = hasElements and sc_frame and sc_frame.Visible

    if menu.Get("sc_hud") then
        local hudItems = {
            "Status: " .. (isPromptActive and "QTE IN PROGRESS!" or "Idle (Listening)"),
            "Total Solved: " .. tostring(sc_totalSuccess),
            "Mode: " .. (menu.Get("sc_mode") == 0 and "Great (100%)" or "Custom"),
        }
        if isPromptActive and sc_line and sc_goal then
            table.insert(hudItems, string.format("Needle: %.1f\xC2\xB0", sc_line.Rotation % 360))
            table.insert(hudItems, string.format("Target: %.1f\xC2\xB0", sc_goal.Rotation % 360))
        end
        draw.Window(20, 220, "sc_hud_win", "Auto Skill Check Info", hudItems)
    end

    if not isPromptActive then return end

    local inZone, needleRot, targetRot = InSweetSpot()
    if inZone then
        local chance = menu.Get("sc_chance") or 100
        if chance < 100 and math.random(1, 100) > chance then
            if menu.Get("sc_debug") then
                print("[DEBUG][SKILL CHECK] Skipped hit due to chance roll (" .. chance .. "%)")
            end
            sc_elementsCached = false
            sc_line, sc_goal, sc_frame = nil, nil, nil
            return
        end

        local delay = menu.Get("sc_delay") or 0.0
        if delay > 0 then
            pendingSkillCheckHitTime = now + delay
        else
            local holdMs = menu.Get("sc_hold_ms") or 120
            utility.KeyPress(0x20, holdMs)
            sc_elementsCached = false
            sc_line, sc_goal, sc_frame = nil, nil, nil
            sc_totalSuccess = sc_totalSuccess + 1
            sc_lastHitTime = now

            if menu.Get("sc_debug") then
                print(string.format("[DEBUG][SKILL CHECK] Hit triggered! Needle: %.1f | Target: %.1f", needleRot or 0, targetRot or 0))
            end

            if menu.Get("sc_notify") then
                notify.Success("Skill Check Solved!", "Hit spacebar automatically", 2)
            end
        end
    end
end

menu.SetCallback("sc_enabled", function(enabled)
    if enabled then
        notify.Success("Auto Skill Check ENABLED")
    else
        notify.Warning("Auto Skill Check DISABLED")
    end
end)


OnFrame = function()
    local now = utility.GetTime()

    updateAutoParry(now)

    updateAutoSkillCheck(now)
end

notify.Success("Project Vector Suite Loaded!", "Auto Parry [P] | Skill Check [V]", 4)
print("[Main] Unified suite loaded: Animation Tracker, Auto Parry, and Auto Skill Check active.")

