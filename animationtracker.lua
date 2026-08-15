-- AnimationTracker for Project Vector
-- Rewritten from Matcha/Executor version to use Project Vector Lua API

-- Fetch offsets via utility.HttpGet
local offsets = nil

local KnownOffsets = {
    ["NodeNext"] = 0x10,
}

local urls = {"https://offsets.imtheo.lol/Offsets.json", "https://artxficial.dev/misc/theo"}
for i = 1, #urls do
    local url = urls[i]
    local body, status = utility.HttpGet(url)
    if body and #body > 0 then
        local function extract(key)
            return tonumber(body:match('"' .. key .. '"%s*:%s*(%d+)'))
        end

        KnownOffsets["AnimationId"] = extract("AnimationId")
        KnownOffsets["ClassDescriptor"] = extract("ClassDescriptor")
        KnownOffsets["ClassDescriptorToClassName"] = extract("ClassName")
        KnownOffsets["Name"] = extract("Name")
        KnownOffsets["TimePosition"] = extract("TimePosition")
        KnownOffsets["ActiveAnimations"] = extract("ActiveAnimations")
        KnownOffsets["Animation"] = extract("Animation")
        KnownOffsets["Speed"] = extract("Speed")
        KnownOffsets["IsPlaying"] = extract("IsPlaying")
        
        -- Check if we got at least one key successfully to confirm it's valid
        if KnownOffsets["AnimationId"] then
            print("[DEBUG] Successfully parsed offsets from: " .. url)
            break
        end
    end
end

-- Fallbacks in case extraction fails completely
KnownOffsets["AnimationId"] = KnownOffsets["AnimationId"] or 32
KnownOffsets["ClassDescriptor"] = KnownOffsets["ClassDescriptor"] or 24
KnownOffsets["ClassDescriptorToClassName"] = KnownOffsets["ClassDescriptorToClassName"] or 16
KnownOffsets["Name"] = KnownOffsets["Name"] or 64
KnownOffsets["TimePosition"] = KnownOffsets["TimePosition"] or 216
KnownOffsets["ActiveAnimations"] = KnownOffsets["ActiveAnimations"] or 2944
KnownOffsets["Animation"] = KnownOffsets["Animation"] or 184
KnownOffsets["Speed"] = KnownOffsets["Speed"] or 212
KnownOffsets["IsPlaying"] = KnownOffsets["IsPlaying"] or 2704

local function GetAnimatorAddress(Character)
    if not Character or Character.Address == 0 then return nil end

    local Humanoid = Character:FindFirstChildWhichIsA("Humanoid")
    if not Humanoid then return nil end

    local Animator = Humanoid:FindFirstChildWhichIsA("Animator")
    return Animator and Animator.Address or nil
end

local function GetPlayingAnimationTracks(Character)
    local AnimatorAddress = GetAnimatorAddress(Character)
    if not AnimatorAddress then 
        print("Failed to resolve Animator.")
        return 
    end

    -- This is the address of the head of the linked list of active animations
    local ListHead_Ptr = memory.Read(AnimatorAddress + KnownOffsets.ActiveAnimations, "ptr")
    if not ListHead_Ptr or ListHead_Ptr == 0 then
        return 
    end

    -- When you read the pointer at the head, you get the first node in the list (or the head itself if the list is empty)
    local firstNode = memory.Read(ListHead_Ptr, "ptr")
    if not firstNode or firstNode == 0 or firstNode == ListHead_Ptr then 
        return {}
    end

    local AnimationTracks = {}
    local currentNode = firstNode
    local foundCount = 0

    while currentNode and currentNode ~= 0 and currentNode ~= ListHead_Ptr do
        -- 1. Read the track data from the current node first
        local track = memory.Read(currentNode + KnownOffsets.NodeNext, "ptr")
        
        if track then
            foundCount = foundCount + 1
            AnimationTracks[foundCount] = track
        end

        if foundCount >= 50 then 
            break 
        end

        -- 2. Look ahead to see where we go next
        local nextNode = memory.Read(currentNode, "ptr")
        
        if nextNode == ListHead_Ptr then
            break -- Safe to exit now; we fully processed currentNode
        elseif nextNode == 0 or not nextNode then
            break
        end

        currentNode = nextNode
    end

    return AnimationTracks
end

local function GetTimePosition(AnimationTrackAddress)
    if not AnimationTrackAddress or AnimationTrackAddress == 0 then return nil end
    
    local TimePosition = memory.Read(AnimationTrackAddress + KnownOffsets.TimePosition, "float")
    
    return TimePosition
end

local function ExtractAnimationTrackInfo(AnimationTrackAddress)
    if not AnimationTrackAddress or AnimationTrackAddress == 0 then return nil end

    local Animation = memory.Read(AnimationTrackAddress + KnownOffsets.Animation, "ptr")
    local AnimationIdPointer = memory.Read(Animation + KnownOffsets.AnimationId, "ptr")
    local AnimationId = memory.ReadString(AnimationIdPointer)

    local NamePtr = memory.Read(AnimationTrackAddress + KnownOffsets.Name, "ptr")
    local Name = memory.ReadString(NamePtr)
    local TimePosition = memory.Read(AnimationTrackAddress + KnownOffsets.TimePosition, "float")
    local Speed = memory.Read(AnimationTrackAddress + KnownOffsets.Speed, "float")
    local IsPlaying = memory.Read(AnimationTrackAddress + KnownOffsets.IsPlaying, "byte")

    return {
        Address = AnimationTrackAddress,
        Name = Name,
        AnimationId = AnimationId,
        TimePosition = TimePosition,
        Speed = Speed,
        IsPlaying = IsPlaying
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
        end
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
    
    self.AnimationAdded = Signal.new()
    self.AnimationUpdated = Signal.new()
    self.AnimationRemoved = Signal.new()
    self.IgnoreIds = IgnoreIds or {}
    
    self._cachedTracks = {}
    
    return self
end

-- Helper to check if a value exists in a table (replaces table.find)
local function tableContains(tbl, val)
    for i = 1, #tbl do
        if tbl[i] == val then return true end
    end
    return false
end

-- BATCH UPDATE: Reads, updates, cleans up, and returns all active animations at once
function AnimationTracker:Update(character)
    local tracksPlaying = GetPlayingAnimationTracks(character)
    if not tracksPlaying then return {} end

    local currentAddresses = {}
    local activeSnapshot = {}

    -- 1. Batch process all currently playing tracks
    for i = 1, #tracksPlaying do
        local address = tracksPlaying[i]
        
        -- Mark as active so your garbage collector doesn't constantly delete and re-extract ignored tracks
        currentAddresses[address] = true 
    
        local info = self._cachedTracks[address]
        local newlyExtracted = false
    
        -- Extract and cache if it doesn't exist
        if not info then
            info = ExtractAnimationTrackInfo(address)
            if info then
                self._cachedTracks[address] = info
                newlyExtracted = true
            end
        end
    
        if info then
            -- 2. Check the Ignore List
            local assetId = info.AnimationId 
            local numericId = assetId and tonumber(string.match(tostring(assetId), "%d+"))
    
            -- If the ID is found in the ignore list, skip the rest of the loop
            if not (numericId and tableContains(self.IgnoreIds, numericId)) then
                -- 3. Process Valid Tracks
                -- Only fire Added event if it's brand new AND passed the ignore check
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

print("[AnimationTracker] Functions were imported, use Tracker:Update() in a loop v1.1 (Project Vector)")

_G.AnimationTracker = AnimationTracker
return AnimationTracker
