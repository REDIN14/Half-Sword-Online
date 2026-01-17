-- UDP Position Sync Module for Half Sword MP
-- Version 10.1: Respawn Protection
-- Detects pawn changes and pauses sync during respawn

print("[UDPSync] Loading v10.1 with Respawn Protection...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 50  -- 20 Hz
local RESPAWN_COOLDOWN = 3  -- Seconds to wait after pawn change

-- ============================================================================
-- State
-- ============================================================================

local IsHost = false
local UDPSendSocket = nil
local UDPReceiveSocket = nil
local Initialized = false
local ClientIP = nil
local DebugMode = false
local TargetHostIP = nil
local TickCount = 0
local RecvCount = 0
local StartTime = 0

-- Pawn tracking for respawn detection
local LastLocalPawnPtr = nil
local LastRemotePawnPtr = nil
local LocalPawnChangeTime = 0
local RemotePawnChangeTime = 0

-- ============================================================================
-- Helpers
-- ============================================================================

local function SafeGet(fn)
    local ok, result = pcall(fn)
    return ok and result or nil
end

local function GetPawnPtr(pawn)
    -- Get a unique identifier for the pawn to detect changes
    if not pawn then return nil end
    return SafeGet(function() return pawn:GetAddress() end)
end

local function GetMyController()
    return SafeGet(function()
        local pc = UEHelpers.GetPlayerController()
        if pc and pc:IsValid() then return pc end
        return nil
    end)
end

local function GetMyPawn()
    local pc = GetMyController()
    if not pc then return nil end
    local pawn = SafeGet(function() return pc.Pawn end)
    if not pawn then return nil end
    if not SafeGet(function() return pawn:IsValid() end) then return nil end
    return pawn
end

local function FindRemotePawn(myPawn)
    local allPawns = SafeGet(function() return FindAllOf("Pawn") end)
    if not allPawns then return nil end
    
    for _, p in ipairs(allPawns) do
        if p ~= myPawn and SafeGet(function() return p:IsValid() end) then
            local isPlayer = SafeGet(function() return p:IsPlayerControlled() end)
            if isPlayer then
                return p
            end
        end
    end
    return nil
end

local function IsPawnStable(pawn)
    -- Extra validation to check pawn is fully ready
    if not pawn then return false end
    if not SafeGet(function() return pawn:IsValid() end) then return false end
    
    -- Try to access location - if this fails, pawn isn't ready
    local loc = SafeGet(function() return pawn:GetActorLocation() end)
    if not loc then return false end
    
    return true
end

-- ============================================================================
-- Protocol
-- ============================================================================

local function MakePacket(pawn, controller)
    local loc = SafeGet(function() return pawn:GetActorLocation() end)
    local ctrlRot = SafeGet(function() return controller:GetControlRotation() end)
    
    if loc and ctrlRot then
        return string.format("P:%.0f,%.0f,%.0f|C:%.1f,%.1f,%.1f",
            loc.X, loc.Y, loc.Z,
            ctrlRot.Pitch, ctrlRot.Yaw, ctrlRot.Roll
        )
    end
    return nil
end

local function ParsePacket(data)
    if not data then return nil end
    
    local posStr = data:match("P:([^|]+)")
    local ctrlStr = data:match("C:([^|]+)")
    if not posStr then return nil end
    
    local px, py, pz = posStr:match("([^,]+),([^,]+),([^,]+)")
    local cp, cy, cr = 0, 0, 0
    if ctrlStr then
        cp, cy, cr = ctrlStr:match("([^,]+),([^,]+),([^,]+)")
    end
    
    return {
        X = tonumber(px) or 0, Y = tonumber(py) or 0, Z = tonumber(pz) or 0,
        Pitch = tonumber(cp) or 0, Yaw = tonumber(cy) or 0, Roll = tonumber(cr) or 0
    }
end

-- ============================================================================
-- Main Sync
-- ============================================================================

local function StartSync(hostIP)
    if Initialized then return end
    
    IsHost = (hostIP == nil or hostIP == "")
    TargetHostIP = hostIP
    TickCount = 0
    RecvCount = 0
    StartTime = os.time()
    LastLocalPawnPtr = nil
    LastRemotePawnPtr = nil
    LocalPawnChangeTime = 0
    RemotePawnChangeTime = 0
    
    UDPSendSocket = SafeGet(function() return socket.udp() end)
    UDPReceiveSocket = SafeGet(function() return socket.udp() end)
    
    if not UDPSendSocket or not UDPReceiveSocket then
        print("[UDPSync] Socket error")
        return
    end
    
    UDPSendSocket:settimeout(0)
    UDPReceiveSocket:settimeout(0)
    
    local port = IsHost and UDP_PORT_RECEIVE or UDP_PORT_BROADCAST
    UDPReceiveSocket:setsockname("*", port)
    
    print("[UDPSync] " .. (IsHost and "HOST" or "CLIENT") .. " port " .. port)
    Initialized = true
    
    LoopAsync(SYNC_INTERVAL, function()
        if not Initialized then return true end
        
        TickCount = TickCount + 1
        local now = os.time()
        
        -- Wait for initial load
        if now - StartTime < 3 then return true end
        
        ExecuteInGameThread(function()
            local myPawn = GetMyPawn()
            local myController = GetMyController()
            
            -- Check for local pawn change (respawn)
            local myPtr = GetPawnPtr(myPawn)
            if myPtr ~= LastLocalPawnPtr then
                if LastLocalPawnPtr ~= nil then
                    LocalPawnChangeTime = now
                    if DebugMode then print("[UDPSync] Local pawn changed - respawn detected") end
                end
                LastLocalPawnPtr = myPtr
            end
            
            -- Skip if local pawn recently changed (respawning)
            if now - LocalPawnChangeTime < RESPAWN_COOLDOWN then
                return
            end
            
            if not myPawn or not myController then return end
            if not IsPawnStable(myPawn) then return end
            
            local packet = MakePacket(myPawn, myController)
            if not packet then return end
            
            -- Send
            if IsHost and ClientIP then
                UDPSendSocket:sendto(packet, ClientIP, UDP_PORT_BROADCAST)
            elseif not IsHost and TargetHostIP then
                UDPSendSocket:sendto(packet, TargetHostIP, UDP_PORT_RECEIVE)
            end
            
            -- Receive
            local data, ip = UDPReceiveSocket:receivefrom()
            if data then
                RecvCount = RecvCount + 1
                if IsHost and ip then ClientIP = ip end
                
                local state = ParsePacket(data)
                if state then
                    local remote = FindRemotePawn(myPawn)
                    
                    -- Check for remote pawn change
                    local remotePtr = GetPawnPtr(remote)
                    if remotePtr ~= LastRemotePawnPtr then
                        if LastRemotePawnPtr ~= nil then
                            RemotePawnChangeTime = now
                            if DebugMode then print("[UDPSync] Remote pawn changed") end
                        end
                        LastRemotePawnPtr = remotePtr
                    end
                    
                    -- Skip if remote pawn recently changed
                    if now - RemotePawnChangeTime < RESPAWN_COOLDOWN then
                        return
                    end
                    
                    if remote and IsPawnStable(remote) then
                        -- Apply position (interpolated)
                        local currLoc = SafeGet(function() return remote:GetActorLocation() end)
                        if currLoc then
                            local alpha = 0.3
                            local newLoc = {
                                X = currLoc.X + (state.X - currLoc.X) * alpha,
                                Y = currLoc.Y + (state.Y - currLoc.Y) * alpha,
                                Z = currLoc.Z + (state.Z - currLoc.Z) * alpha
                            }
                            SafeGet(function()
                                remote:K2_SetActorLocation(newLoc, false, {}, false)
                            end)
                        end
                        
                        -- Apply rotation (Yaw only for body facing)
                        SafeGet(function()
                            remote:K2_SetActorRotation({Pitch=0, Yaw=state.Yaw, Roll=0}, false)
                        end)
                    end
                end
                
                if DebugMode and RecvCount % 20 == 1 then
                    print("[UDPSync] RX: " .. data:sub(1,30))
                end
            end
        end)
        
        return true
    end)
    
    print("[UDPSync] v10.1 Started")
end

local function StopSync()
    Initialized = false
    LastLocalPawnPtr = nil
    LastRemotePawnPtr = nil
    SafeGet(function() if UDPSendSocket then UDPSendSocket:close() end end)
    SafeGet(function() if UDPReceiveSocket then UDPReceiveSocket:close() end end)
    print("[UDPSync] Stopped")
end

-- ============================================================================
-- API
-- ============================================================================

local UDPSync = {}
UDPSync.StartAsHost = function() StartSync(nil) end
UDPSync.StartAsClient = function(ip) StartSync(ip) end
UDPSync.Stop = StopSync

RegisterKeyBind(Key.F11, function()
    DebugMode = not DebugMode
    print("[UDPSync] v10.1 Debug=" .. tostring(DebugMode))
    print("  Ticks=" .. TickCount .. " Recv=" .. RecvCount)
    print("  LocalPtr=" .. tostring(LastLocalPawnPtr))
    print("  RemotePtr=" .. tostring(LastRemotePawnPtr))
end)

return UDPSync
