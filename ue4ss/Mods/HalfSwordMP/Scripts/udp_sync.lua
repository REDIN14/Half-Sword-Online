-- UDP Position Sync Module for Half Sword MP
-- Version 9.2: Fixed stack overflow (removed nested loops)

print("[UDPSync] Loading v9.2...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 100  -- 100ms = 10 Hz

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

-- ============================================================================
-- Helpers
-- ============================================================================

local function SafeGet(fn)
    local ok, result = pcall(fn)
    return ok and result or nil
end

local function GetPawn()
    local pc = SafeGet(function() return UEHelpers.GetPlayerController() end)
    if not pc then return nil end
    local pawn = SafeGet(function() return pc.Pawn end)
    if not pawn then return nil end
    local valid = SafeGet(function() return pawn:IsValid() end)
    return valid and pawn or nil
end

-- ============================================================================
-- Sync
-- ============================================================================

local function StartSync(hostIP)
    if Initialized then return end
    
    IsHost = (hostIP == nil or hostIP == "")
    TargetHostIP = hostIP
    TickCount = 0
    RecvCount = 0
    StartTime = os.time()
    
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
    
    -- Single flat loop (NO NESTING!)
    LoopAsync(SYNC_INTERVAL, function()
        if not Initialized then return true end
        
        TickCount = TickCount + 1
        
        -- Wait 3 seconds for game to load
        if os.time() - StartTime < 3 then
            return true
        end
        
        ExecuteInGameThread(function()
            local pawn = GetPawn()
            if not pawn then return end
            
            local loc = SafeGet(function() return pawn:GetActorLocation() end)
            local rot = SafeGet(function() return pawn:GetActorRotation() end)
            if not loc or not rot then return end
            
            local packet = string.format("P:%.0f,%.0f,%.0f|R:%.0f,%.0f,%.0f",
                loc.X, loc.Y, loc.Z, rot.Pitch, rot.Yaw, rot.Roll)
            
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
                if DebugMode and RecvCount % 20 == 1 then
                    print("[UDPSync] RX: " .. data:sub(1,30))
                end
            end
        end)
        
        return true
    end)
    
    print("[UDPSync] v9.2 Started")
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
UDPSync.StartAsHost = function() StartSync(nil) end
UDPSync.StartAsClient = function(ip) StartSync(ip) end
UDPSync.Stop = StopSync

RegisterKeyBind(Key.F11, function()
    DebugMode = not DebugMode
    print("[UDPSync] Debug=" .. tostring(DebugMode) .. " Ticks=" .. TickCount .. " Recv=" .. RecvCount)
end)

return UDPSync
