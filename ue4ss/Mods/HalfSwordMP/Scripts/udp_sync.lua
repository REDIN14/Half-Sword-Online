-- UDP Position Sync Module for Half Sword MP
-- Version 9.0: MINIMAL SAFE MODE
-- This version only READS and LOGS - no position modifications
-- Used to diagnose crashes

print("[UDPSync] Loading v9.0 SAFE MODE (read-only)...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 0.100  -- 10 Hz (slower = safer)

-- ============================================================================
-- State
-- ============================================================================

local IsHost = false
local UDPSendSocket = nil
local UDPReceiveSocket = nil
local Initialized = false
local ClientIP = nil
local DebugMode = true  -- Always debug in safe mode
local TargetHostIP = nil
local PacketCount = 0

-- ============================================================================
-- Safe Execution
-- ============================================================================

local function SafeCall(fn)
    local ok, result = pcall(fn)
    if not ok then
        print("[UDPSync] SafeCall Error: " .. tostring(result))
        return nil
    end
    return result
end

-- ============================================================================
-- Pawn Detection (Safe)
-- ============================================================================

local function GetLocalPlayerPawn()
    return SafeCall(function()
        local pc = UEHelpers.GetPlayerController()
        if pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
            return pc.Pawn
        end
        return nil
    end)
end

-- ============================================================================
-- Protocol
-- ============================================================================

local function PackPos(pawn)
    local loc = SafeCall(function() return pawn:GetActorLocation() end)
    local rot = SafeCall(function() return pawn:GetActorRotation() end)
    
    if loc and rot then
        return string.format("P:%.0f,%.0f,%.0f|R:%.0f,%.0f,%.0f",
            loc.X, loc.Y, loc.Z,
            rot.Pitch, rot.Yaw, rot.Roll)
    end
    return nil
end

-- ============================================================================
-- Main Loop (READ-ONLY - NO MODIFICATIONS)
-- ============================================================================

local function StartSyncLoop(hostIP)
    if Initialized then 
        print("[UDPSync] Already running")
        return 
    end
    
    IsHost = (hostIP == nil or hostIP == "")
    TargetHostIP = hostIP
    PacketCount = 0
    
    -- Create sockets
    local ok1, sock1 = pcall(function() return socket.udp() end)
    if not ok1 then
        print("[UDPSync] Failed to create send socket")
        return
    end
    UDPSendSocket = sock1
    UDPSendSocket:settimeout(0)
    
    local ok2, sock2 = pcall(function() return socket.udp() end)
    if not ok2 then
        print("[UDPSync] Failed to create recv socket")
        return
    end
    UDPReceiveSocket = sock2
    UDPReceiveSocket:settimeout(0)
    
    local port = IsHost and UDP_PORT_RECEIVE or UDP_PORT_BROADCAST
    UDPReceiveSocket:setsockname("*", port)
    
    print("[UDPSync] " .. (IsHost and "HOST" or "CLIENT") .. " on port " .. port)
    
    Initialized = true
    
    LoopAsync(math.floor(SYNC_INTERVAL * 1000), function()
        if not Initialized then return true end
        
        SafeCall(function()
            ExecuteInGameThread(function()
                -- Get local pawn
                local localPawn = GetLocalPlayerPawn()
                if not localPawn then return end
                
                -- Create packet
                local packet = PackPos(localPawn)
                if not packet then return end
                
                -- Send
                if IsHost then
                    if ClientIP then
                        UDPSendSocket:sendto(packet, ClientIP, UDP_PORT_BROADCAST)
                    end
                else
                    if TargetHostIP then
                        UDPSendSocket:sendto(packet, TargetHostIP, UDP_PORT_RECEIVE)
                    end
                end
                
                -- Receive (READ ONLY - just log, no apply)
                local data, ip = UDPReceiveSocket:receivefrom()
                if data then
                    PacketCount = PacketCount + 1
                    
                    if IsHost and ip then
                        ClientIP = ip
                    end
                    
                    -- Just log the received data, don't apply it
                    if PacketCount % 30 == 1 then  -- Log every 30th packet
                        print("[UDPSync] RX#" .. PacketCount .. ": " .. data:sub(1, 50))
                    end
                end
            end)
        end)
        
        return true
    end)
    
    print("[UDPSync] v9.0 SAFE MODE Started (read-only)")
end

local function StopSync()
    Initialized = false
    SafeCall(function() if UDPSendSocket then UDPSendSocket:close() end end)
    SafeCall(function() if UDPReceiveSocket then UDPReceiveSocket:close() end end)
    print("[UDPSync] Stopped")
end

-- ============================================================================
-- API
-- ============================================================================

local UDPSync = {}
function UDPSync.StartAsHost() StartSyncLoop(nil) end
function UDPSync.StartAsClient(ip) StartSyncLoop(ip) end
function UDPSync.Stop() StopSync() end

RegisterKeyBind(Key.F11, function()
    print("")
    print("=== UDP SYNC v9.0 SAFE MODE ===")
    print("  Initialized: " .. tostring(Initialized))
    print("  IsHost: " .. tostring(IsHost))
    print("  ClientIP: " .. tostring(ClientIP))
    print("  PacketsReceived: " .. PacketCount)
    
    local pawn = GetLocalPlayerPawn()
    if pawn then
        local loc = SafeCall(function() return pawn:GetActorLocation() end)
        if loc then
            print("  LocalPos: " .. math.floor(loc.X) .. "," .. math.floor(loc.Y) .. "," .. math.floor(loc.Z))
        end
    else
        print("  LocalPawn: NONE")
    end
    print("================================")
end)

return UDPSync
