-- UDP Position Sync Module for Half Sword MP
-- Version 8.0: Proper Player Detection (Uses IsPlayerControlled)

print("[UDPSync] Loading v8.0 with Proper Player Detection...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 0.016  -- 60 Hz
local INTERPOLATION_SPEED = 25.0

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

-- Cached pawns (refresh each frame for safety)
local CachedLocalPawn = nil
local CachedRemotePawn = nil

-- ============================================================================
-- Safe Helpers
-- ============================================================================

local function SafeCall(fn)
    local ok, result = pcall(fn)
    if not ok then
        if DebugMode then print("[UDPSync] Error: " .. tostring(result)) end
        return nil
    end
    return result
end

local function IsValid(obj)
    if not obj then return false end
    local valid = SafeCall(function() return obj:IsValid() end)
    return valid == true
end

-- ============================================================================
-- CRITICAL: Proper Player Pawn Detection
-- Uses IsPlayerControlled() to distinguish players from NPCs
-- ============================================================================

local function IsPlayerPawn(pawn)
    if not IsValid(pawn) then return false end
    
    -- Check if this pawn is controlled by a player (not AI)
    local isPlayer = SafeCall(function()
        return pawn:IsPlayerControlled()
    end)
    
    return isPlayer == true
end

local function IsLocalPawn(pawn)
    if not IsPlayerPawn(pawn) then return false end
    
    -- Check if this pawn is locally controlled (our player)
    local isLocal = SafeCall(function()
        return pawn:IsLocallyControlled()
    end)
    
    return isLocal == true
end

local function GetPlayerPawns()
    local players = {}
    local localPawn = nil
    local remotePawn = nil
    
    SafeCall(function()
        local allPawns = FindAllOf("Pawn")
        if not allPawns then return end
        
        for _, pawn in ipairs(allPawns) do
            if IsPlayerPawn(pawn) then
                if IsLocalPawn(pawn) then
                    localPawn = pawn
                else
                    remotePawn = pawn
                end
            end
        end
    end)
    
    return localPawn, remotePawn
end

-- ============================================================================
-- Network Protocol (Simplified)
-- ============================================================================

local function PackState(loc, rot)
    return string.format("P:%.1f,%.1f,%.1f|R:%.1f,%.1f,%.1f",
        loc.X, loc.Y, loc.Z,
        rot.Pitch, rot.Yaw, rot.Roll
    )
end

local function UnpackState(data)
    if not data then return nil end
    
    local posStr = data:match("P:([^|]+)")
    local rotStr = data:match("R:([^|]+)")
    
    if not posStr then return nil end
    
    local px, py, pz = posStr:match("([^,]+),([^,]+),([^,]+)")
    local rx, ry, rz = (rotStr or "0,0,0"):match("([^,]+),([^,]+),([^,]+)")
    
    return {
        Pos = {X = tonumber(px) or 0, Y = tonumber(py) or 0, Z = tonumber(pz) or 0},
        Rot = {Pitch = tonumber(rx) or 0, Yaw = tonumber(ry) or 0, Roll = tonumber(rz) or 0}
    }
end

-- ============================================================================
-- Main Sync Loop
-- ============================================================================

local function StartSyncLoop(hostIP)
    if Initialized then 
        print("[UDPSync] Already running!")
        return 
    end
    
    IsHost = (hostIP == nil or hostIP == "")
    TargetHostIP = hostIP
    ClientIP = nil
    CachedLocalPawn = nil
    CachedRemotePawn = nil
    
    -- Create sockets
    local ok, sendSock = pcall(function() return socket.udp() end)
    if not ok or not sendSock then
        print("[UDPSync] FAILED to create send socket!")
        return
    end
    UDPSendSocket = sendSock
    UDPSendSocket:settimeout(0)
    
    local ok2, recvSock = pcall(function() return socket.udp() end)
    if not ok2 or not recvSock then
        print("[UDPSync] FAILED to create receive socket!")
        return
    end
    UDPReceiveSocket = recvSock
    UDPReceiveSocket:settimeout(0)
    
    -- Bind to port
    local port = IsHost and UDP_PORT_RECEIVE or UDP_PORT_BROADCAST
    local bindOk = UDPReceiveSocket:setsockname("*", port)
    
    if IsHost then
        print("[UDPSync] === HOST MODE ===")
        print("[UDPSync] Listening on port " .. port)
    else
        print("[UDPSync] === CLIENT MODE ===")
        print("[UDPSync] Connecting to " .. tostring(hostIP))
        print("[UDPSync] Listening on port " .. port)
    end
    
    Initialized = true
    
    -- Main loop
    LoopAsync(math.floor(SYNC_INTERVAL * 1000), function()
        if not Initialized then return true end
        
        SafeCall(function()
            ExecuteInGameThread(function()
                -- Get player pawns (local and remote)
                local localPawn, remotePawn = GetPlayerPawns()
                
                if not IsValid(localPawn) then
                    if DebugMode then print("[UDPSync] No local player pawn") end
                    return
                end
                
                CachedLocalPawn = localPawn
                CachedRemotePawn = remotePawn
                
                -- Get local state
                local loc = SafeCall(function() return localPawn:GetActorLocation() end)
                local rot = SafeCall(function() return localPawn:GetActorRotation() end)
                
                if not loc or not rot then return end
                
                -- Create and send packet
                local packet = PackState(loc, rot)
                
                if IsHost then
                    if ClientIP then
                        UDPSendSocket:sendto(packet, ClientIP, UDP_PORT_BROADCAST)
                    end
                else
                    if TargetHostIP then
                        UDPSendSocket:sendto(packet, TargetHostIP, UDP_PORT_RECEIVE)
                    end
                end
                
                -- Receive packet
                local data, senderIP = UDPReceiveSocket:receivefrom()
                if data then
                    if IsHost and senderIP then
                        ClientIP = senderIP
                        if DebugMode then print("[UDPSync] Client connected: " .. senderIP) end
                    end
                    
                    local state = UnpackState(data)
                    if state and IsValid(remotePawn) then
                        -- Apply position with interpolation
                        local currLoc = SafeCall(function() return remotePawn:GetActorLocation() end)
                        if currLoc then
                            local alpha = math.min(1.0, SYNC_INTERVAL * INTERPOLATION_SPEED)
                            local newLoc = {
                                X = currLoc.X + (state.Pos.X - currLoc.X) * alpha,
                                Y = currLoc.Y + (state.Pos.Y - currLoc.Y) * alpha,
                                Z = currLoc.Z + (state.Pos.Z - currLoc.Z) * alpha
                            }
                            SafeCall(function()
                                remotePawn:K2_SetActorLocation(newLoc, false, {}, false)
                            end)
                        end
                        
                        -- Apply rotation
                        SafeCall(function()
                            remotePawn:K2_SetActorRotation(state.Rot, false)
                        end)
                    elseif state and DebugMode then
                        print("[UDPSync] Got packet but no remote pawn to apply to")
                    end
                end
            end)
        end)
        
        return true
    end)
    
    print("[UDPSync] v8.0 Started!")
end

local function StopSync()
    Initialized = false
    CachedLocalPawn = nil
    CachedRemotePawn = nil
    ClientIP = nil
    
    SafeCall(function() if UDPSendSocket then UDPSendSocket:close() end end)
    SafeCall(function() if UDPReceiveSocket then UDPReceiveSocket:close() end end)
    
    print("[UDPSync] Stopped")
end

-- ============================================================================
-- Public API
-- ============================================================================

local UDPSync = {}
function UDPSync.StartAsHost() StartSyncLoop(nil) end
function UDPSync.StartAsClient(ip) StartSyncLoop(ip) end
function UDPSync.Stop() StopSync() end

-- Debug keybind
RegisterKeyBind(Key.F11, function()
    DebugMode = not DebugMode
    print("")
    print("=== UDP SYNC DEBUG ===")
    print("  DebugMode: " .. tostring(DebugMode))
    print("  Initialized: " .. tostring(Initialized))
    print("  IsHost: " .. tostring(IsHost))
    print("  ClientIP: " .. tostring(ClientIP))
    print("  TargetHostIP: " .. tostring(TargetHostIP))
    
    -- Scan for player pawns and report
    local localPawn, remotePawn = GetPlayerPawns()
    print("  LocalPawn: " .. (IsValid(localPawn) and localPawn:GetFullName() or "NONE"))
    print("  RemotePawn: " .. (IsValid(remotePawn) and remotePawn:GetFullName() or "NONE"))
    
    -- Count all pawns
    local allPawns = FindAllOf("Pawn")
    local playerCount = 0
    local npcCount = 0
    if allPawns then
        for _, p in ipairs(allPawns) do
            if IsPlayerPawn(p) then 
                playerCount = playerCount + 1 
            else 
                npcCount = npcCount + 1
            end
        end
    end
    print("  Player Pawns: " .. playerCount .. ", NPC Pawns: " .. npcCount)
    print("======================")
end)

return UDPSync
