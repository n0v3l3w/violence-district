-- AnimationTracker for Project Vector
-- Ported from executor-based AnimationTracker v1.1
--
-- API changes from original:
--   memory_read("uintptr_t", addr)  → memory.Read(addr, "ptr")
--   memory_read("float", addr)      → memory.Read(addr, "float")
--   memory_read("string", addr)     → memory.ReadString(addr)
--   memory_read("byte", addr)       → memory.Read(addr, "u8")
--   game:HttpGet(url)               → utility.HttpGet(url)
--   HttpService:JSONDecode(str)     → parseJSON(str)  (built-in)
--   table.find (Luau)               → table_find helper
--   continue  (Luau)                → if/end guard

---------------------------------------------------------------------------
-- Minimal JSON parser (Vector environment has no JSONDecode)
---------------------------------------------------------------------------
local function parseJSON(str)
    local pos = 1

    local function skip_ws()
        local p = str:find("[^ \t\r\n]", pos)
        pos = p or (#str + 1)
    end

    local function parse_string()
        pos = pos + 1 -- skip opening "
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

    local parse_value -- forward declaration

    local function parse_object()
        pos = pos + 1 -- skip {
        local obj = {}
        skip_ws()
        if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
        while true do
            skip_ws()
            local key = parse_string()
            skip_ws()
            pos = pos + 1 -- skip :
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
        pos = pos + 1 -- skip [
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

---------------------------------------------------------------------------
-- Luau compatibility (Vector uses standard Lua, not Luau)
---------------------------------------------------------------------------
local function table_find(t, value)
    for i = 1, #t do
        if t[i] == value then return i end
    end
    return nil
end

---------------------------------------------------------------------------
-- Fetch offsets via HTTP
---------------------------------------------------------------------------
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
            print("[DEBUG] Successfully using offsets from: " .. url)
            offsets = result
            break
        end
    end
end

if not offsets then
    print("[DEBUG] Both endpoints failed. Defaulting to empty table.")
    offsets = {}
end

---------------------------------------------------------------------------
-- Offset table (nil-safe access)
---------------------------------------------------------------------------
local KnownOffsets = {
    ["AnimationId"]                = offsets.Misc and offsets.Misc.AnimationId or 0,
    ["ClassDescriptor"]            = offsets.Instance and offsets.Instance.ClassDescriptor or 0,    -- const
    ["ClassDescriptorToClassName"] = offsets.Instance and offsets.Instance.ClassName or 0,          -- const
    ["Name"]                       = offsets.Instance and offsets.Instance.Name or 0,               -- const
    ["TimePosition"]               = offsets.AnimationTrack and offsets.AnimationTrack.TimePosition or 0,
    ["ActiveAnimations"]           = offsets.Animator and offsets.Animator.ActiveAnimations or 0,    -- const
    ["Animation"]                  = offsets.AnimationTrack and offsets.AnimationTrack.Animation or 0,
    ["Speed"]                      = offsets.AnimationTrack and offsets.AnimationTrack.Speed or 0,
    ["IsPlaying"]                  = offsets.AnimationTrack and offsets.AnimationTrack.IsPlaying or 0,
    -- Node Structure
    ["NodeNext"] = 0x10,
}

---------------------------------------------------------------------------
-- Core memory-reading functions
---------------------------------------------------------------------------
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

    -- Head of the linked list of active animations
    local ListHead_Ptr = memory.Read(AnimatorAddress + KnownOffsets.ActiveAnimations, "ptr")
    if not ListHead_Ptr or ListHead_Ptr == 0 then
        return
    end

    -- First node (or head itself if empty)
    local firstNode = memory.Read(ListHead_Ptr, "ptr")
    if not firstNode or firstNode == 0 or firstNode == ListHead_Ptr then
        return {}
    end

    local AnimationTracks = {}
    local currentNode = firstNode
    local foundCount = 0

    while currentNode and currentNode ~= 0 and currentNode ~= ListHead_Ptr do
        -- Read the track pointer from the current node
        local track = memory.Read(currentNode + KnownOffsets.NodeNext, "ptr")

        if track then
            foundCount = foundCount + 1
            AnimationTracks[foundCount] = track
        end

        if foundCount >= 50 then
            break
        end

        -- Advance to the next node
        local nextNode = memory.Read(currentNode, "ptr")

        if nextNode == ListHead_Ptr then
            break -- looped back to head
        elseif nextNode == 0 or not nextNode then
            break -- end of list
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

---------------------------------------------------------------------------
-- Signal (lightweight event emitter)
---------------------------------------------------------------------------
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

---------------------------------------------------------------------------
-- AnimationTracker class
---------------------------------------------------------------------------
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

-- Batch update: reads, caches, fires signals, cleans up stopped tracks
function AnimationTracker:Update(character)
    local tracksPlaying = GetPlayingAnimationTracks(character)
    if not tracksPlaying then return {} end

    local currentAddresses = {}
    local activeSnapshot   = {}

    -- Process all currently playing tracks
    for i = 1, #tracksPlaying do
        local address = tracksPlaying[i]
        currentAddresses[address] = true

        local info = self._cachedTracks[address]
        local newlyExtracted = false

        -- Extract and cache if not seen before
        if not info then
            info = ExtractAnimationTrackInfo(address)
            if info then
                self._cachedTracks[address] = info
                newlyExtracted = true
            end
        end

        if info then
            -- Check ignore list  (replaces Luau `continue`)
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

    -- Purge tracks that are no longer playing
    for address, cachedInfo in pairs(self._cachedTracks) do
        if not currentAddresses[address] then
            self.AnimationRemoved:Fire(cachedInfo)
            self._cachedTracks[address] = nil
        end
    end

    return activeSnapshot
end

print("[AnimationTracker] Vector port loaded, use Tracker:Update() in a loop v1.1")

_G.AnimationTracker = AnimationTracker
return AnimationTracker
