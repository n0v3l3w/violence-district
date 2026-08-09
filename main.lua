local line, goal, frame = nil, nil, nil
local elementsCached = false

local function InSweetSpot()
    if not line or not goal then return false end
    local needle = line.Rotation % 360
    local target = goal.Rotation % 360
    local start = (target + 104) % 360
    local endAngle = (target + 114) % 360
    return start > endAngle and (needle >= start or needle <= endAngle) or (needle >= start and needle <= endAngle)
end

local function FindGuiElements()
    local lp = entity.GetLocalPlayer()
    if not lp then return false end
    
    local pg = lp.Player and lp.Player:FindFirstChild("PlayerGui")
    if not pg then return false end
    
    local prompt = pg:FindFirstChild("SkillCheckPromptGui")
    if not prompt then return false end
    
    frame = prompt:FindFirstChild("Check")
    if not frame then return false end
    
    line = frame:FindFirstChild("Line")
    goal = frame:FindFirstChild("Goal")
    
    elementsCached = line ~= nil and goal ~= nil
    return elementsCached
end

local function ValidateCache()
    if not elementsCached then return false end
    return utility.IsValid(frame) and utility.IsValid(line) and utility.IsValid(goal)
end

OnFrame = function()
    if not ValidateCache() then
        if not FindGuiElements() then
            return
        end
    end
    
    if not frame.Visible then return end
    
    if InSweetSpot() then
        utility.KeyPress(0x20)
        elementsCached = false
        line, goal, frame = nil, nil, nil
    end
end

while not entity.GetLocalPlayer() do
    sleep(0.1)
end
