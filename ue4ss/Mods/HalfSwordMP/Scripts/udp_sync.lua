-- UDP Position Sync Module for Half Sword MP
-- Version 4.0: Deep Dive - Skeleton Bone Sync

print("[UDPSync] Loading Deep Dive Skeleton Sync v4.0...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 0.033 -- 30 Hz for heavy bone data
local INTERPOLATION_SPEED = 15.0

-- Key bones to sync (Half-Sword uses Active Ragdoll, these cover the whole body)
local KEY_BONES = {
    "pelvis", "spine_01", "spine_02", "spine_03",
    "head", "neck_01",
    "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
    "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r",
    "thigh_l", "calf_l", "foot_l",
    "thigh_r", "calf_r", "foot_r"
}

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
            if DebugMode then print("[UDPSync] Found Remote: " .. pawn:GetFullName()) end
            return pawn
        end
    end
    return nil
end

local function GetMesh(pawn)
    if not pawn or not pawn:IsValid() then return nil end
    return pawn.Mesh
end

local function MakePuppet(pawn)
    if not pawn or not pawn:IsValid() then return end
    local mesh = GetMesh(pawn)
    if mesh and mesh:IsValid() then
        pcall(function()
            if mesh:IsSimulatingPhysics() then
                mesh:SetSimulatePhysics(false)
            end
        end)
    end
    local controller = pawn.Controller
    if controller and controller:IsValid() and not controller:IsPlayerControlled() then
        pcall(function() controller:UnPossess() end)
    end
end

-- ============================================================================
-- Bone Sync
-- ============================================================================

local function GetBoneTransforms(mesh)
    if not mesh or not mesh:IsValid() then return nil end
    
    local bones = {}
    for _, boneName in ipairs(KEY_BONES) do
        pcall(function()
            -- GetSocketTransform is widely available & returns world-space transform
            local transform = mesh:GetSocketTransform(FName(boneName), 0) -- 0 = WorldSpace
            if transform then
                table.insert(bones, string.format("%s:%.1f,%.1f,%.1f,%.1f,%.1f,%.1f",
                    boneName,
                    transform.Translation.X, transform.Translation.Y, transform.Translation.Z,
                    transform.Rotation.Pitch, transform.Rotation.Yaw, transform.Rotation.Roll
                ))
            end
        end)
    end
    return table.concat(bones, "|")
end

local function ApplyBoneTransforms(mesh, boneData)
    if not mesh or not mesh:IsValid() or not boneData or boneData == "" then return end
    
    for entry in string.gmatch(boneData, "([^|]+)") do
        local name, tx, ty, tz, rx, ry, rz = entry:match("([^:]+):([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
        if name and tx then
            pcall(function()
                -- SetBoneTransformByName(BoneName, InTransform, Space)
                -- Space: 0 = WorldSpace, 1 = BoneSpace
                mesh:SetBoneTransformByName(
                    FName(name),
                    {
                        Translation = {X = tonumber(tx), Y = tonumber(ty), Z = tonumber(tz)},
                        Rotation = {Pitch = tonumber(rx), Yaw = tonumber(ry), Roll = tonumber(rz)},
                        Scale3D = {X = 1, Y = 1, Z = 1}
                    },
                    0 -- WorldSpace
                )
            end)
        end
    end
end

-- ============================================================================
-- Network
-- ============================================================================

local function PacketToString(loc, rot, boneData)
    return string.format("POS:%.1f,%.1f,%.1f|ROT:%.1f,%.1f,%.1f|BONES:%s",
        loc.X, loc.Y, loc.Z,
        rot.Pitch, rot.Yaw, rot.Roll,
        boneData or ""
    )
end

local function StringToPacket(data)
    if not data then return nil end
    
    local posStr = data:match("POS:([^|]+)")
    local rotStr = data:match("ROT:([^|]+)")
    local bonesStr = data:match("BONES:(.*)")
    
    if not posStr then return nil end
    
    local px, py, pz = posStr:match("([^,]+),([^,]+),([^,]+)")
    local rx, ry, rz = rotStr and rotStr:match("([^,]+),([^,]+),([^,]+)") or 0, 0, 0
    
    return {
        Pos = {X = tonumber(px), Y = tonumber(py), Z = tonumber(pz)},
        Rot = {Pitch = tonumber(rx), Yaw = tonumber(ry), Roll = tonumber(rz)},
        Bones = bonesStr
    }
end

-- ============================================================================
-- Main Sync Loop
-- ============================================================================

local function StartSyncLoop(hostIP)
    if Initialized then return end
    
    IsHost = (hostIP == nil or hostIP == "")
    
    UDPSendSocket = socket.udp()
    UDPSendSocket:settimeout(0)
    UDPReceiveSocket = socket.udp()
    UDPReceiveSocket:settimeout(0)
    
    if IsHost then
        UDPReceiveSocket:setsockname("*", UDP_PORT_RECEIVE)
        print("[UDPSync] HOST on " .. UDP_PORT_RECEIVE)
    else
        UDPReceiveSocket:setsockname("*", UDP_PORT_BROADCAST)
        print("[UDPSync] CLIENT on " .. UDP_PORT_BROADCAST)
    end
    
    Initialized = true
    
    LoopAsync(math.floor(SYNC_INTERVAL * 1000), function()
        if not Initialized then return true end
        
        pcall(function()
            ExecuteInGameThread(function()
                LocalPawn = GetLocalPawn()
                if not LocalPawn then return end
                
                local mesh = GetMesh(LocalPawn)
                if not mesh then return end
                
                -- 1. Gather Local State + Bones
                local loc = LocalPawn:GetActorLocation()
                local rot = LocalPawn:GetActorRotation()
                local boneData = GetBoneTransforms(mesh)
                local packet = PacketToString(loc, rot, boneData)
                
                -- 2. Send
                if IsHost then
                    if ClientIP then UDPSendSocket:sendto(packet, ClientIP, UDP_PORT_BROADCAST) end
                else
                    if hostIP then UDPSendSocket:sendto(packet, hostIP, UDP_PORT_RECEIVE) end
                end
                
                -- 3. Receive & Apply
                local data, ip = UDPReceiveSocket:receivefrom()
                if data then
                    if IsHost and ip then ClientIP = ip end
                    local target = StringToPacket(data)
                    
                    if target then
                        local remote = FindRemotePawn(LocalPawn)
                        if remote then
                            MakePuppet(remote)
                            
                            -- Apply Actor Position/Rotation
                            local curr = remote:GetActorLocation()
                            local alpha = math.min(1.0, SYNC_INTERVAL * INTERPOLATION_SPEED)
                            local nx = curr.X + (target.Pos.X - curr.X) * alpha
                            local ny = curr.Y + (target.Pos.Y - curr.Y) * alpha
                            local nz = curr.Z + (target.Pos.Z - curr.Z) * alpha
                            
                            remote:K2_SetActorLocation({X=nx, Y=ny, Z=nz}, false, {}, false)
                            remote:K2_SetActorRotation({Pitch=target.Rot.Pitch, Yaw=target.Rot.Yaw, Roll=target.Rot.Roll}, false)
                            
                            -- Apply Bone Transforms
                            local remoteMesh = GetMesh(remote)
                            if remoteMesh then
                                ApplyBoneTransforms(remoteMesh, target.Bones)
                            end
                        end
                    end
                end
            end)
        end)
        return true
    end)
    
    print("[UDPSync] Deep Dive Loop Started!")
end

local function StopSync()
    Initialized = false
    if UDPSendSocket then UDPSendSocket:close() end
    if UDPReceiveSocket then UDPReceiveSocket:close() end
    print("[UDPSync] Stopped.")
end

-- ============================================================================
-- API
-- ============================================================================

local UDPSync = {}
function UDPSync.StartAsHost() StartSyncLoop(nil) end
function UDPSync.StartAsClient(ip) StartSyncLoop(ip) end
function UDPSync.Stop() StopSync() end

RegisterKeyBind(Key.F11, function()
    DebugMode = not DebugMode
    print("[UDPSync] Debug: " .. tostring(DebugMode))
    print("  IsHost: " .. tostring(IsHost) .. " Init: " .. tostring(Initialized))
    print("  ClientIP: " .. tostring(ClientIP))
    if LocalPawn then
        local m = GetMesh(LocalPawn)
        print("  LocalMesh: " .. (m and m:GetFullName() or "nil"))
    end
end)

return UDPSync
