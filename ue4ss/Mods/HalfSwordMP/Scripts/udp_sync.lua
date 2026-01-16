-- UDP Position Sync Module for Half Sword MP
-- Uses LuaSocket for real network position synchronization
-- Version 3.2 (Debug + Kinematic Puppet Fix)

print("[UDPSync] Loading Ultimate UDP Sync Module (Debug + Kinematic)...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 0.016
local INTERPOLATION_SPEED = 20.0

-- ============================================================================
-- State
-- ============================================================================

local IsHost = false
local LocalPawn = nil
local UDPSendSocket = nil
local UDPReceiveSocket = nil
local Initialized = false
local ClientIP = nil
local DebugMode = false
local RemotePawnCache = nil

-- ============================================================================
-- Helpers
-- ============================================================================

local function GetLocalPawn()
    local success, pc = pcall(UEHelpers.GetPlayerController)
    if success and pc and pc:IsValid() then
        return pc.Pawn
    end
    return nil
end

local function FindRemotePawn(localPawn)
    if RemotePawnCache and RemotePawnCache:IsValid() and RemotePawnCache ~= localPawn then
        return RemotePawnCache
    end
    
    local pawns = FindAllOf("Pawn")
    if not pawns then return nil end
    for _, pawn in ipairs(pawns) do
        if pawn:IsValid() and pawn ~= localPawn then
            RemotePawnCache = pawn
            print("[UDPSync] Found Remote Pawn: " .. pawn:GetFullName())
            return pawn
        end
    end
    return nil
end

local function MakePuppet(pawn)
    -- FORCE the remote pawn to stop simulating physics so it follows our position updates
    -- This fixes the "Frozen Body / Hand Only" glitches
    if not pawn or not pawn:IsValid() then return end
    
    local mesh = pawn.Mesh
    if mesh and mesh:IsValid() then
        if mesh:IsSimulatingPhysics() then
             print("[UDPSync] Disabling Physics on Remote Pawn Mesh (Kinematic Mode)")
             pcall(function() mesh:SetSimulatePhysics(false) end)
             pcall(function() mesh:SetCollisionEnabled(0) end) -- No collision, pure visual ghost? Maybe unsafe.
        end
    end
    
    -- Also kill controller
    local controller = pawn.Controller
    if controller and controller:IsValid() and not controller:IsPlayerControlled() then
        pcall(function() controller:UnPossess() end)
    end
end

-- ============================================================================
-- Sync Logic
-- ============================================================================

local function PacketToString(state, props)
    return string.format("POS:%.2f,%.2f,%.2f|ROT:%.2f,%.2f,%.2f|PROPS:%s",
        state.Pos.X, state.Pos.Y, state.Pos.Z,
        state.Rot.Pitch, state.Rot.Yaw, state.Rot.Roll,
        props or ""
    )
end

local function StringToPacket(data)
    if not data then return nil end
    local posStr = data:match("POS:([^|]+)")
    local rotStr = data:match("ROT:([^|]+)")
    
    if not posStr then return nil end
    local px, py, pz = posStr:match("([^,]+),([^,]+),([^,]+)")
    local rx, ry, rz = rotStr and rotStr:match("([^,]+),([^,]+),([^,]+)") or 0,0,0
    
    return {
        Pos = {X=tonumber(px), Y=tonumber(py), Z=tonumber(pz)},
        Rot = {Pitch=tonumber(rx), Yaw=tonumber(ry), Roll=tonumber(rz)},
        Props = data:match("PROPS:(.*)")
    }
end

local function StartSyncLoop(hostIP)
    if Initialized then return end
    
    local isHost = (hostIP == nil or hostIP == "")
    IsHost = isHost
    
    UDPSendSocket = socket.udp()
    UDPSendSocket:settimeout(0)
    UDPReceiveSocket = socket.udp()
    UDPReceiveSocket:settimeout(0)
    
    if isHost then
        UDPReceiveSocket:setsockname("*", UDP_PORT_RECEIVE)
        print("[UDPSync] HOST Listening on " .. UDP_PORT_RECEIVE)
    else
        UDPReceiveSocket:setsockname("*", UDP_PORT_BROADCAST)
        print("[UDPSync] CLIENT Listening on " .. UDP_PORT_BROADCAST)
    end
    
    Initialized = true
    
    LoopAsync(math.floor(SYNC_INTERVAL * 1000), function()
        if not Initialized then return true end
        
        pcall(function()
            ExecuteInGameThread(function()
                LocalPawn = GetLocalPawn()
                if not LocalPawn then return end
                
                -- DEBUG: Print if we have a local pawn
                -- if DebugMode then print("LocalPawn: " .. tostring(LocalPawn)) end
                
                -- 1. Gather & Send
                local loc = LocalPawn:GetActorLocation()
                local rot = LocalPawn:GetActorRotation()
                local packet = PacketToString(
                    {Pos={X=loc.X, Y=loc.Y, Z=loc.Z}, Rot={Pitch=rot.Pitch, Yaw=rot.Yaw, Roll=rot.Roll}},
                    "Health=100" -- Placeholder
                )
                
                if IsHost then
                     if ClientIP then UDPSendSocket:sendto(packet, ClientIP, UDP_PORT_BROADCAST) end
                else
                     if hostIP then UDPSendSocket:sendto(packet, hostIP, UDP_PORT_RECEIVE) end
                end
                
                -- 2. Receive & Apply
                local data, ip = UDPReceiveSocket:receivefrom()
                if data then
                    if IsHost and ip then ClientIP = ip end
                    local target = StringToPacket(data)
                    
                    if target then
                        local remote = FindRemotePawn(LocalPawn)
                        if remote then
                            MakePuppet(remote) -- Ensure it's a puppet
                            
                            -- Interpolate Pos
                            local curr = remote:GetActorLocation()
                            local alpha = math.min(1.0, SYNC_INTERVAL * INTERPOLATION_SPEED)
                            local nx = curr.X + (target.Pos.X - curr.X) * alpha
                            local ny = curr.Y + (target.Pos.Y - curr.Y) * alpha
                            local nz = curr.Z + (target.Pos.Z - curr.Z) * alpha
                            
                            remote:K2_SetActorLocation({X=nx, Y=ny, Z=nz}, false, {}, false)
                            remote:K2_SetActorRotation({Pitch=target.Rot.Pitch, Yaw=target.Rot.Yaw, Roll=target.Rot.Roll}, false)
                            
                            if DebugMode then
                                print(string.format("[UDPSync] Updated Remote: %.2f %.2f %.2f", nx, ny, nz))
                            end
                        else
                            if DebugMode then print("[UDPSync] Received Data but NO REMOTE PAWN found!") end
                        end
                    end
                end
            end)
        end)
        return true
    end)
    
    print("[UDPSync] Loop Started.")
end

local function StopSync()
    Initialized = false
    if UDPSendSocket then UDPSendSocket:close() end
    if UDPReceiveSocket then UDPReceiveSocket:close() end
    print("[UDPSync] Stopped.")
end

local UDPSync = {}
function UDPSync.StartAsHost() StartSyncLoop(nil) end
function UDPSync.StartAsClient(ip) StartSyncLoop(ip) end
function UDPSync.Stop() StopSync() end

RegisterKeyBind(Key.F11, function()
    DebugMode = not DebugMode
    print("[UDPSync] Debug Mode: " .. tostring(DebugMode))
    print("  IsHost: " .. tostring(IsHost))
    print("  ClientIP: " .. tostring(ClientIP))
    print("  LocalPawn: " .. (LocalPawn and LocalPawn:GetFullName() or "nil"))
    local r = FindRemotePawn(LocalPawn)
    print("  RemotePawn: " .. (r and r:GetFullName() or "None"))
end)

return UDPSync
