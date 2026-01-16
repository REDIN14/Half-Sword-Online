-- UDP Position Sync Module for Half Sword MP
-- Version 5.0: Active Ragdoll Override - Full Physics Disable

print("[UDPSync] Loading v5.0 Active Ragdoll Override...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 0.033  -- 30 Hz
local INTERPOLATION_SPEED = 15.0

-- Key bones for pose sync
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
local PhysicsDisabledOnRemote = false

-- ============================================================================
-- Helpers
-- ============================================================================

local function SafeCall(fn)
    local ok, result = pcall(fn)
    return ok and result or nil
end

local function GetLocalPawn()
    return SafeCall(function()
        local pc = UEHelpers.GetPlayerController()
        if pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
            return pc.Pawn
        end
        return nil
    end)
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
            if DebugMode then print("[UDPSync] Remote: " .. pawn:GetFullName()) end
            return pawn
        end
    end
    return nil
end

local function GetMesh(pawn)
    if not pawn or not pawn:IsValid() then return nil end
    local mesh = pawn.Mesh
    if mesh and mesh:IsValid() then return mesh end
    return nil
end

-- ============================================================================
-- CRITICAL: Full Physics Disable for Active Ragdoll
-- ============================================================================

local function DisableAllPhysics(pawn)
    if PhysicsDisabledOnRemote then return end
    if not pawn or not pawn:IsValid() then return end
    
    local mesh = GetMesh(pawn)
    if not mesh then return end
    
    -- THE KEY FIX: Disable ALL physics bodies on the skeletal mesh
    SafeCall(function()
        -- SetAllBodiesSimulatePhysics(false) stops ragdoll
        mesh:SetAllBodiesSimulatePhysics(false)
        print("[UDPSync] *** Disabled ALL physics bodies on remote mesh ***")
    end)
    
    -- Also disable collision to prevent interference
    SafeCall(function()
        mesh:SetCollisionEnabled(0) -- NoCollision
    end)
    
    -- Kill AI
    local controller = pawn.Controller
    if controller and controller:IsValid() and not controller:IsPlayerControlled() then
        SafeCall(function() controller:UnPossess() end)
    end
    
    PhysicsDisabledOnRemote = true
end

-- ============================================================================
-- Bone Sync (Now works because physics is disabled!)
-- ============================================================================

local function GetBoneData(mesh)
    if not mesh or not mesh:IsValid() then return "" end
    
    local bones = {}
    for _, boneName in ipairs(KEY_BONES) do
        SafeCall(function()
            local transform = mesh:GetSocketTransform(FName(boneName), 0)
            if transform then
                table.insert(bones, string.format("%s:%.0f,%.0f,%.0f,%.0f,%.0f,%.0f",
                    boneName,
                    transform.Translation.X, transform.Translation.Y, transform.Translation.Z,
                    transform.Rotation.Pitch, transform.Rotation.Yaw, transform.Rotation.Roll
                ))
            end
        end)
    end
    return table.concat(bones, "|")
end

local function ApplyBoneData(mesh, boneData)
    if not mesh or not mesh:IsValid() or not boneData or boneData == "" then return end
    
    for entry in string.gmatch(boneData, "([^|]+)") do
        local name, tx, ty, tz, rx, ry, rz = entry:match("([^:]+):([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
        if name and tx then
            SafeCall(function()
                mesh:SetBoneTransformByName(
                    FName(name),
                    {
                        Translation = {X = tonumber(tx), Y = tonumber(ty), Z = tonumber(tz)},
                        Rotation = {Pitch = tonumber(rx), Yaw = tonumber(ry), Roll = tonumber(rz)},
                        Scale3D = {X = 1, Y = 1, Z = 1}
                    },
                    0
                )
            end)
        end
    end
end

-- ============================================================================
-- Network
-- ============================================================================

local function PackState(loc, rot, boneData)
    return string.format("P:%.0f,%.0f,%.0f|R:%.0f,%.0f,%.0f|B:%s",
        loc.X, loc.Y, loc.Z,
        rot.Pitch, rot.Yaw, rot.Roll,
        boneData or ""
    )
end

local function UnpackState(data)
    if not data then return nil end
    
    local posStr = data:match("P:([^|]+)")
    local rotStr = data:match("R:([^|]+)")
    local bonesStr = data:match("B:(.*)")
    
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
-- Main Loop
-- ============================================================================

local function StartSyncLoop(hostIP)
    if Initialized then return end
    
    IsHost = (hostIP == nil or hostIP == "")
    PhysicsDisabledOnRemote = false
    RemotePawnCache = nil
    
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
        
        SafeCall(function()
            ExecuteInGameThread(function()
                LocalPawn = GetLocalPawn()
                if not LocalPawn then return end
                
                local mesh = GetMesh(LocalPawn)
                if not mesh then return end
                
                -- 1. Gather State
                local loc = LocalPawn:GetActorLocation()
                local rot = LocalPawn:GetActorRotation()
                if not loc or not rot then return end
                
                local boneData = GetBoneData(mesh)
                local packet = PackState(loc, rot, boneData)
                
                -- 2. Send
                if IsHost then
                    if ClientIP then UDPSendSocket:sendto(packet, ClientIP, UDP_PORT_BROADCAST) end
                else
                    if hostIP then UDPSendSocket:sendto(packet, hostIP, UDP_PORT_RECEIVE) end
                end
                
                -- 3. Receive
                local data, ip = UDPReceiveSocket:receivefrom()
                if data then
                    if IsHost and ip then ClientIP = ip end
                    local state = UnpackState(data)
                    
                    if state then
                        local remote = FindRemotePawn(LocalPawn)
                        if remote and remote:IsValid() then
                            -- CRITICAL: Disable physics FIRST
                            DisableAllPhysics(remote)
                            
                            -- Apply Position with interpolation
                            local curr = remote:GetActorLocation()
                            if curr then
                                local alpha = math.min(1.0, SYNC_INTERVAL * INTERPOLATION_SPEED)
                                local nx = curr.X + (state.Pos.X - curr.X) * alpha
                                local ny = curr.Y + (state.Pos.Y - curr.Y) * alpha
                                local nz = curr.Z + (state.Pos.Z - curr.Z) * alpha
                                
                                remote:K2_SetActorLocation({X=nx, Y=ny, Z=nz}, false, {}, false)
                            end
                            
                            -- Apply Rotation
                            remote:K2_SetActorRotation({Pitch=state.Rot.Pitch, Yaw=state.Rot.Yaw, Roll=state.Rot.Roll}, false)
                            
                            -- Apply Bones (NOW WORKS because physics is OFF!)
                            local remoteMesh = GetMesh(remote)
                            if remoteMesh then
                                ApplyBoneData(remoteMesh, state.Bones)
                            end
                        end
                    end
                end
            end)
        end)
        return true
    end)
    
    print("[UDPSync] v5.0 Active Ragdoll Override Started!")
end

local function StopSync()
    Initialized = false
    PhysicsDisabledOnRemote = false
    RemotePawnCache = nil
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
    print("[UDPSync] Debug=" .. tostring(DebugMode))
    print("  IsHost=" .. tostring(IsHost) .. " PhysOff=" .. tostring(PhysicsDisabledOnRemote))
    print("  ClientIP=" .. tostring(ClientIP))
end)

return UDPSync
