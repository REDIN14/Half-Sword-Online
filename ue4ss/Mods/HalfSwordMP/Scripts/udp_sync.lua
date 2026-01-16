-- UDP Position Sync Module for Half Sword MP
-- Uses LuaSocket for real network position synchronization
-- Version 1.0

print("[UDPSync] Loading UDP Position Sync Module...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778  -- Host broadcasts on this port
local UDP_PORT_RECEIVE = 7779    -- Clients send to host on this port
local SYNC_INTERVAL = 0.016      -- 60 Hz sync rate (Ultra Smooth)
local INTERPOLATION_SPEED = 25.0 -- Fast interpolation for 60Hz

-- ============================================================================
-- State
-- ============================================================================

local IsHost = false
local LocalPawn = nil
local UDPSendSocket = nil
local UDPReceiveSocket = nil
local RemotePlayers = {}
local Initialized = false
local ClientIP = nil  -- For host: the client's IP

-- ============================================================================
-- Utility Functions
-- ============================================================================

local function GetLocalPawn()
    local pc = UEHelpers.GetPlayerController()
    if pc and pc:IsValid() then
        local pawn = pc.Pawn
        if pawn and pawn:IsValid() then
            return pawn
        end
    end
    return nil
end

local function FindRemotePawn(localPawn)
    local pawns = FindAllOf("Pawn")
    if not pawns then return nil end
    
    for _, pawn in ipairs(pawns) do
        if pawn:IsValid() and pawn ~= localPawn then
            -- This is likely the remote player
            -- Check distance to avoid random NPCs if possible, but for 1v1 this is fine
            return pawn
        end
    end
    return nil
end

local function InterpolateTo(pawn, targetPos, dt)
    if not pawn or not pawn:IsValid() or not targetPos then return end
    
    local currentPos = pawn:GetActorLocation()
    if not currentPos then return end
    
    -- Lerp factor
    local alpha = dt * INTERPOLATION_SPEED
    if alpha > 1.0 then alpha = 1.0 end
    
    local newX = currentPos.X + (targetPos.X - currentPos.X) * alpha
    local newY = currentPos.Y + (targetPos.Y - currentPos.Y) * alpha
    local newZ = currentPos.Z + (targetPos.Z - currentPos.Z) * alpha
    
    -- Set location directly
    pawn:K2_SetActorLocation({X=newX, Y=newY, Z=newZ}, false, {}, false)
end

local function GetPawnPosition(pawn)
    if pawn and pawn:IsValid() then
        local success, loc = pcall(function() return pawn:GetActorLocation() end)
        if success and loc then
            return {X = loc.X, Y = loc.Y, Z = loc.Z}
        end
    end
    return nil
end

local function GetPawnRotation(pawn)
    if pawn and pawn:IsValid() then
        local success, rot = pcall(function() return pawn:GetActorRotation() end)
        if success and rot then
            return {Yaw = rot.Yaw}
        end
    end
    return nil
end

local function SetPawnPosition(pawn, pos)
    if pawn and pawn:IsValid() and pos then
        pcall(function()
            local newLoc = {X = pos.X, Y = pos.Y, Z = pos.Z}
            pawn:K2_SetActorLocation(newLoc, false, {}, false)
        end)
    end
end

-- ============================================================================
-- Network Functions
-- ============================================================================

local function InitializeNetwork(isHost)
    IsHost = isHost
    
    -- Create UDP socket for sending
    UDPSendSocket = socket.udp()
    UDPSendSocket:settimeout(0)  -- Non-blocking
    
    -- Create UDP socket for receiving
    UDPReceiveSocket = socket.udp()
    UDPReceiveSocket:settimeout(0)  -- Non-blocking
    
    if IsHost then
        -- Host listens on receive port for client data
        local status, err = UDPReceiveSocket:setsockname("*", UDP_PORT_RECEIVE)
        if not status then
            print("[UDPSync] Host failed to bind receive port: " .. tostring(err))
            return false
        end
        print("[UDPSync] Host listening on port " .. UDP_PORT_RECEIVE)
    else
        -- Client listens on broadcast port for host data
        local status, err = UDPReceiveSocket:setsockname("*", UDP_PORT_BROADCAST)
        if not status then
            print("[UDPSync] Client failed to bind broadcast port: " .. tostring(err))
            return false
        end
        print("[UDPSync] Client listening on port " .. UDP_PORT_BROADCAST)
    end
    
    Initialized = true
    return true
end

local function SendPosition(targetIP, targetPort, pos, rot)
    if not UDPSendSocket or not pos then return end
    
    -- Simple format: X,Y,Z,Yaw
    local data = string.format("POS:%f,%f,%f,%f", pos.X, pos.Y, pos.Z, rot and rot.Yaw or 0)
    UDPSendSocket:sendto(data, targetIP, targetPort)
end

local function ReceivePosition()
    if not UDPReceiveSocket then return nil, nil end
    
    local data, ip, port = UDPReceiveSocket:receivefrom()
    if data then
        -- Parse: POS:X,Y,Z,Yaw
        local prefix, posData = data:match("^(%w+):(.+)$")
        if prefix == "POS" then
            local x, y, z, yaw = posData:match("([^,]+),([^,]+),([^,]+),([^,]+)")
            if x and y and z then
                return {
                    X = tonumber(x),
                    Y = tonumber(y),
                    Z = tonumber(z),
                    Yaw = tonumber(yaw) or 0
                }, ip
            end
        end
    end
    return nil, nil
end

-- ============================================================================
-- Sync Loop
-- ============================================================================

local SyncLoopRunning = false

local function StartSyncLoop(hostIP)
    if SyncLoopRunning then return end
    SyncLoopRunning = true
    
    -- Determine if we're host based on whether hostIP is provided
    local isHost = (hostIP == nil or hostIP == "")
    
    if not InitializeNetwork(isHost) then
        print("[UDPSync] Failed to initialize network")
        return
    end
    
    if not isHost then
        print("[UDPSync] Client mode - will send to host: " .. hostIP)
    else
        print("[UDPSync] Host mode - broadcasting positions")
    end
    
    LoopAsync(math.floor(SYNC_INTERVAL * 1000), function()
        if not Initialized then return true end
        
        pcall(function()
            ExecuteInGameThread(function()
                LocalPawn = GetLocalPawn()
                if not LocalPawn then return end
                
                local myPos = GetPawnPosition(LocalPawn)
                local myRot = GetPawnRotation(LocalPawn)
                local targetPos = nil
                
                if IsHost then
                    -- HOST: Receive client positions
                    local remotePos, remoteIP = ReceivePosition()
                    if remotePos and remoteIP then
                        ClientIP = remoteIP
                        RemotePlayers[remoteIP] = { position = remotePos, lastUpdate = os.clock() }
                        targetPos = remotePos
                    end
                    
                    -- HOST: Broadcast our position
                    if ClientIP and myPos then
                        SendPosition(ClientIP, UDP_PORT_BROADCAST, myPos, myRot)
                    end
                else
                    -- CLIENT: Send our position
                    if hostIP and myPos then
                        SendPosition(hostIP, UDP_PORT_RECEIVE, myPos, myRot)
                    end
                    
                    -- CLIENT: Receive host position
                    local remotePos, remoteIP = ReceivePosition()
                    if remotePos then
                        RemotePlayers["host"] = { position = remotePos, lastUpdate = os.clock() }
                        targetPos = remotePos
                    end
                end
                
                -- APPLY POSITION TO REMOTE PAWN
                if targetPos then
                    local remotePawn = FindRemotePawn(LocalPawn)
                    if remotePawn then
                        InterpolateTo(remotePawn, targetPos, SYNC_INTERVAL)
                    end
                end
            end)
        end)
        
        return true  -- Continue loop
    end)
    
    print("[UDPSync] Sync loop started at " .. math.floor(1/SYNC_INTERVAL) .. " Hz")
end

local function StopSyncLoop()
    Initialized = false
    SyncLoopRunning = false
    if UDPSendSocket then UDPSendSocket:close() end
    if UDPReceiveSocket then UDPReceiveSocket:close() end
    print("[UDPSync] Sync loop stopped")
end

-- ============================================================================
-- Public API
-- ============================================================================

local UDPSync = {}

function UDPSync.StartAsHost()
    print("[UDPSync] Starting as HOST...")
    StartSyncLoop(nil)
end

function UDPSync.StartAsClient(hostIP)
    StartSyncLoop(hostIP)
end

function UDPSync.Stop()
    StopSyncLoop()
end

function UDPSync.GetRemotePlayers()
    return RemotePlayers
end

function UDPSync.GetStatus()
    return {
        isHost = IsHost,
        initialized = Initialized,
        remotePlayers = RemotePlayers
    }
end

-- ============================================================================
-- Debug Hotkey (F11)
-- ============================================================================

RegisterKeyBind(Key.F11, function()
    ExecuteInGameThread(function()
        print("\n[UDPSync] Status:")
        print("  Initialized: " .. tostring(Initialized))
        print("  IsHost: " .. tostring(IsHost))
        print("  Remote Players: " .. tostring(#RemotePlayers))
        
        for ip, data in pairs(RemotePlayers) do
            if data.position then
                print(string.format("  [%s]: X=%.1f, Y=%.1f, Z=%.1f", 
                    ip, data.position.X, data.position.Y, data.position.Z))
            end
        end
    end)
end)

print("[UDPSync] Module loaded. F11 for status.")
print("[UDPSync] Call UDPSync.StartAsHost() or UDPSync.StartAsClient(ip)")

return UDPSync
