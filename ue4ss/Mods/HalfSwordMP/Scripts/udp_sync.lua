-- UDP Position Sync Module for Half Sword MP
-- Version 9.1: Fixed timing issues with stronger pawn validation

print("[UDPSync] Loading v9.1 with timing fixes...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 0.050  -- 20 Hz
local STARTUP_DELAY = 3000   -- Wait 3 seconds before starting sync

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
local LastRecvPacket = ""
local RecvCount = 0

-- ============================================================================
-- Safe Helpers
-- ============================================================================

local function SafeGet(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    return nil
end

-- Validate pawn is fully usable
local function IsValidPawn(pawn)
    if not pawn then return false end
    
    -- Check IsValid
    local valid = SafeGet(function() return pawn:IsValid() end)
    if not valid then return false end
    
    -- Try to access a property to confirm it's really valid
    local loc = SafeGet(function() return pawn:GetActorLocation() end)
    if not loc then return false end
    
    return true
end

local function GetMyPawn()
    local pc = SafeGet(function() return UEHelpers.GetPlayerController() end)
    if not pc then return nil end
    
    local pawn = SafeGet(function() return pc.Pawn end)
    if not IsValidPawn(pawn) then return nil end
    
    return pawn
end

-- ============================================================================
-- Network
-- ============================================================================

local function MakePacket(pawn)
    local loc = SafeGet(function() return pawn:GetActorLocation() end)
    local rot = SafeGet(function() return pawn:GetActorRotation() end)
    
    if loc and rot then
        return string.format("P:%.0f,%.0f,%.0f|R:%.0f,%.0f,%.0f",
            loc.X, loc.Y, loc.Z,
            rot.Pitch, rot.Yaw, rot.Roll)
    end
    return nil
end

local function ParsePacket(data)
    if not data then return nil end
    
    local posStr = data:match("P:([^|]+)")
    local rotStr = data:match("R:([^|]+)")
    if not posStr then return nil end
    
    local px, py, pz = posStr:match("([^,]+),([^,]+),([^,]+)")
    local rx, ry, rz = "0", "0", "0"
    if rotStr then
        rx, ry, rz = rotStr:match("([^,]+),([^,]+),([^,]+)")
    end
    
    return {
        X = tonumber(px) or 0, Y = tonumber(py) or 0, Z = tonumber(pz) or 0,
        Pitch = tonumber(rx) or 0, Yaw = tonumber(ry) or 0, Roll = tonumber(rz) or 0
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
    
    -- Create sockets
    UDPSendSocket = SafeGet(function() return socket.udp() end)
    UDPReceiveSocket = SafeGet(function() return socket.udp() end)
    
    if not UDPSendSocket or not UDPReceiveSocket then
        print("[UDPSync] Socket creation failed!")
        return
    end
    
    UDPSendSocket:settimeout(0)
    UDPReceiveSocket:settimeout(0)
    
    local port = IsHost and UDP_PORT_RECEIVE or UDP_PORT_BROADCAST
    UDPReceiveSocket:setsockname("*", port)
    
    print("[UDPSync] " .. (IsHost and "HOST" or "CLIENT") .. " on port " .. port)
    if not IsHost then
        print("[UDPSync] Target: " .. tostring(hostIP))
    end
    
    Initialized = true
    
    -- Wait for game to fully initialize
    print("[UDPSync] Waiting " .. (STARTUP_DELAY/1000) .. "s for game to load...")
    
    LoopAsync(STARTUP_DELAY, function()
        print("[UDPSync] Starting sync loop...")
        
        LoopAsync(math.floor(SYNC_INTERVAL * 1000), function()
            if not Initialized then return true end
            
            TickCount = TickCount + 1
            
            ExecuteInGameThread(function()
                -- Get local pawn
                local myPawn = GetMyPawn()
                if not myPawn then
                    if TickCount % 60 == 1 then
                        print("[UDPSync] Tick " .. TickCount .. ": No valid pawn yet")
                    end
                    return
                end
                
                -- Create packet
                local packet = MakePacket(myPawn)
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
                
                -- Receive
                local data, ip = UDPReceiveSocket:receivefrom()
                if data then
                    RecvCount = RecvCount + 1
                    LastRecvPacket = data
                    
                    if IsHost and ip then
                        ClientIP = ip
                    end
                    
                    -- Log every 30 packets
                    if DebugMode and RecvCount % 30 == 1 then
                        print("[UDPSync] RX#" .. RecvCount .. ": " .. data:sub(1, 40))
                    end
                end
            end)
            
            return true
        end)
        
        return false  -- Stop outer delay loop
    end)
    
    print("[UDPSync] v9.1 Initialized")
end

local function StopSync()
    Initialized = false
    SafeGet(function() if UDPSendSocket then UDPSendSocket:close() end end)
    SafeGet(function() if UDPReceiveSocket then UDPReceiveSocket:close() end end)
    print("[UDPSync] Stopped")
end

-- ============================================================================
-- API
-- ============================================================================

local UDPSync = {}
function UDPSync.StartAsHost() StartSync(nil) end
function UDPSync.StartAsClient(ip) StartSync(ip) end
function UDPSync.Stop() StopSync() end

RegisterKeyBind(Key.F11, function()
    DebugMode = not DebugMode
    print("")
    print("=== UDP SYNC v9.1 ===")
    print("Debug: " .. tostring(DebugMode))
    print("IsHost: " .. tostring(IsHost))
    print("ClientIP: " .. tostring(ClientIP))
    print("Ticks: " .. TickCount .. ", Received: " .. RecvCount)
    print("LastPacket: " .. (LastRecvPacket ~= "" and LastRecvPacket:sub(1,50) or "none"))
    
    local p = GetMyPawn()
    if p then
        local loc = SafeGet(function() return p:GetActorLocation() end)
        print("MyPos: " .. (loc and string.format("%.0f,%.0f,%.0f", loc.X, loc.Y, loc.Z) or "?"))
    else
        print("MyPawn: NOT FOUND")
    end
    print("=====================")
end)

return UDPSync
