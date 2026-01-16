-- UDP Position Sync Module for Half Sword MP
-- Version 6.0: Ultimate Sync - Weapons + GameState + Death Ragdoll

print("[UDPSync] Loading v6.0 Ultimate Sync...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 0.033  -- 30 Hz
local INTERPOLATION_SPEED = 15.0

local KEY_BONES = {
    "pelvis", "spine_01", "spine_02", "spine_03",
    "head", "neck_01",
    "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
    "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r",
    "thigh_l", "calf_l", "foot_l",
    "thigh_r", "calf_r", "foot_r"
}

local DAMAGE_PROPS = {
    "Health", "CurrentHealth", "MaxHealth",
    "BleedLevel", "BleedRate", "BleedAmount",
    "DamageLevel", "DamageAmount",
    "StaminaCurrent", "BalanceCurrent"
}

-- Weapon sockets to check for attached actors
local WEAPON_SOCKETS = {"hand_r", "hand_l", "weapon_r", "weapon_l", "grip_r", "grip_l"}

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
local RemoteIsDead = false
local SpawnedWeapons = {}

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
-- Physics Control
-- ============================================================================

local function DisableAllPhysics(pawn)
    if PhysicsDisabledOnRemote then return end
    if not pawn or not pawn:IsValid() then return end
    
    local mesh = GetMesh(pawn)
    if not mesh then return end
    
    SafeCall(function()
        mesh:SetAllBodiesSimulatePhysics(false)
        print("[UDPSync] Physics DISABLED on remote")
    end)
    SafeCall(function() mesh:SetCollisionEnabled(0) end)
    
    local controller = pawn.Controller
    if controller and controller:IsValid() and not controller:IsPlayerControlled() then
        SafeCall(function() controller:UnPossess() end)
    end
    
    PhysicsDisabledOnRemote = true
end

local function EnableDeathPhysics(pawn, impulseX, impulseY, impulseZ)
    if not pawn or not pawn:IsValid() then return end
    local mesh = GetMesh(pawn)
    if not mesh then return end
    
    SafeCall(function()
        mesh:SetAllBodiesSimulatePhysics(true)
        mesh:SetCollisionEnabled(1) -- QueryAndPhysics
        mesh:AddImpulse({X=impulseX or 0, Y=impulseY or 0, Z=impulseZ or 500}, "None", true)
        print("[UDPSync] Death physics ENABLED with impulse")
    end)
    
    RemoteIsDead = true
    PhysicsDisabledOnRemote = false
end

-- ============================================================================
-- Bone Sync
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
                mesh:SetBoneTransformByName(FName(name),
                    {Translation={X=tonumber(tx),Y=tonumber(ty),Z=tonumber(tz)},
                     Rotation={Pitch=tonumber(rx),Yaw=tonumber(ry),Roll=tonumber(rz)},
                     Scale3D={X=1,Y=1,Z=1}}, 0)
            end)
        end
    end
end

-- ============================================================================
-- Damage/Health Sync
-- ============================================================================

local function GetDamageState(pawn)
    if not pawn or not pawn:IsValid() then return "" end
    local props = {}
    for _, propName in ipairs(DAMAGE_PROPS) do
        SafeCall(function()
            local val = pawn[propName]
            if val ~= nil and type(val) == "number" then
                table.insert(props, string.format("%s=%.1f", propName, val))
            end
        end)
    end
    return table.concat(props, ",")
end

local function ApplyDamageState(pawn, damageStr)
    if not pawn or not pawn:IsValid() or not damageStr or damageStr == "" then return end
    for key, value in string.gmatch(damageStr, "([^=]+)=([^,]+)") do
        local numVal = tonumber(value)
        if numVal then
            SafeCall(function() pawn[key] = numVal end)
        end
    end
end

-- ============================================================================
-- Weapon Sync
-- ============================================================================

local function GetWeaponData(pawn)
    if not pawn or not pawn:IsValid() then return "" end
    
    local weapons = {}
    SafeCall(function()
        local attached = pawn:GetAttachedActors()
        if attached then
            for _, actor in ipairs(attached) do
                if actor:IsValid() then
                    local className = actor:GetClass():GetFName():ToString()
                    -- Get attachment socket if possible
                    local socket = "hand_r" -- default
                    table.insert(weapons, className .. "@" .. socket)
                end
            end
        end
    end)
    return table.concat(weapons, ";")
end

local function ApplyWeaponData(pawn, weaponStr)
    if not pawn or not pawn:IsValid() or not weaponStr or weaponStr == "" then return end
    
    -- TODO: Full implementation requires spawning actors
    -- For now, just log what weapons the other player has
    if DebugMode and weaponStr ~= "" then
        print("[UDPSync] Remote weapons: " .. weaponStr)
    end
end

-- ============================================================================
-- Game State Sync
-- ============================================================================

local function GetGameStateData()
    local data = {}
    SafeCall(function()
        local gs = FindFirstOf("GameState")
        if gs and gs:IsValid() then
            -- Try common game state properties
            local props = {"MatchState", "ElapsedTime", "RemainingTime", "bGamePaused"}
            for _, prop in ipairs(props) do
                local val = gs[prop]
                if val ~= nil then
                    if type(val) == "number" then
                        table.insert(data, prop .. "=" .. tostring(val))
                    elseif type(val) == "boolean" then
                        table.insert(data, prop .. "=" .. (val and "1" or "0"))
                    end
                end
            end
        end
    end)
    return table.concat(data, ",")
end

local function ApplyGameStateData(gsStr)
    if not gsStr or gsStr == "" then return end
    -- Game state is read-only for clients in most cases
    -- Just log for debugging
    if DebugMode then
        print("[UDPSync] GameState: " .. gsStr)
    end
end

-- ============================================================================
-- Death Detection
-- ============================================================================

local function IsPlayerDead(pawn)
    if not pawn or not pawn:IsValid() then return false end
    
    local health = SafeCall(function() return pawn.Health or pawn.CurrentHealth end)
    if health and health <= 0 then return true end
    
    -- Check if ragdolling (velocity on pelvis bone could indicate falling)
    return false
end

-- ============================================================================
-- Network Protocol
-- ============================================================================

local function PackState(loc, rot, boneData, damageData, weaponData, gsData, isDead)
    return string.format("P:%.0f,%.0f,%.0f|R:%.0f,%.0f,%.0f|B:%s|D:%s|W:%s|G:%s|X:%s",
        loc.X, loc.Y, loc.Z,
        rot.Pitch, rot.Yaw, rot.Roll,
        boneData or "",
        damageData or "",
        weaponData or "",
        gsData or "",
        isDead and "1" or "0"
    )
end

local function UnpackState(data)
    if not data then return nil end
    
    local posStr = data:match("P:([^|]+)")
    local rotStr = data:match("R:([^|]+)")
    local bonesStr = data:match("B:([^|]*)")
    local damageStr = data:match("D:([^|]*)")
    local weaponStr = data:match("W:([^|]*)")
    local gsStr = data:match("G:([^|]*)")
    local deadStr = data:match("X:([^|]*)")
    
    if not posStr then return nil end
    
    local px, py, pz = posStr:match("([^,]+),([^,]+),([^,]+)")
    local rx, ry, rz = rotStr and rotStr:match("([^,]+),([^,]+),([^,]+)") or 0, 0, 0
    
    return {
        Pos = {X = tonumber(px), Y = tonumber(py), Z = tonumber(pz)},
        Rot = {Pitch = tonumber(rx), Yaw = tonumber(ry), Roll = tonumber(rz)},
        Bones = bonesStr,
        Damage = damageStr,
        Weapons = weaponStr,
        GameState = gsStr,
        IsDead = (deadStr == "1")
    }
end

-- ============================================================================
-- Main Sync Loop
-- ============================================================================

local function StartSyncLoop(hostIP)
    if Initialized then return end
    
    IsHost = (hostIP == nil or hostIP == "")
    PhysicsDisabledOnRemote = false
    RemoteIsDead = false
    RemotePawnCache = nil
    SpawnedWeapons = {}
    
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
                
                -- 1. Gather All State
                local loc = LocalPawn:GetActorLocation()
                local rot = LocalPawn:GetActorRotation()
                if not loc or not rot then return end
                
                local boneData = GetBoneData(mesh)
                local damageData = GetDamageState(LocalPawn)
                local weaponData = GetWeaponData(LocalPawn)
                local gsData = IsHost and GetGameStateData() or ""
                local isDead = IsPlayerDead(LocalPawn)
                
                local packet = PackState(loc, rot, boneData, damageData, weaponData, gsData, isDead)
                
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
                    local state = UnpackState(data)
                    
                    if state then
                        local remote = FindRemotePawn(LocalPawn)
                        if remote and remote:IsValid() then
                            
                            -- Handle Death
                            if state.IsDead and not RemoteIsDead then
                                EnableDeathPhysics(remote, 0, 0, 500)
                            elseif not state.IsDead and RemoteIsDead then
                                -- Respawn - reset state
                                RemoteIsDead = false
                                PhysicsDisabledOnRemote = false
                            end
                            
                            -- Normal sync (if not dead)
                            if not state.IsDead then
                                DisableAllPhysics(remote)
                                
                                -- Position
                                local curr = remote:GetActorLocation()
                                if curr then
                                    local alpha = math.min(1.0, SYNC_INTERVAL * INTERPOLATION_SPEED)
                                    local nx = curr.X + (state.Pos.X - curr.X) * alpha
                                    local ny = curr.Y + (state.Pos.Y - curr.Y) * alpha
                                    local nz = curr.Z + (state.Pos.Z - curr.Z) * alpha
                                    remote:K2_SetActorLocation({X=nx, Y=ny, Z=nz}, false, {}, false)
                                end
                                
                                -- Rotation
                                remote:K2_SetActorRotation({Pitch=state.Rot.Pitch, Yaw=state.Rot.Yaw, Roll=state.Rot.Roll}, false)
                                
                                -- Bones
                                local remoteMesh = GetMesh(remote)
                                if remoteMesh then
                                    ApplyBoneData(remoteMesh, state.Bones)
                                end
                            end
                            
                            -- Always apply these
                            ApplyDamageState(remote, state.Damage)
                            ApplyWeaponData(remote, state.Weapons)
                            ApplyGameStateData(state.GameState)
                        end
                    end
                end
            end)
        end)
        return true
    end)
    
    print("[UDPSync] v6.0 Ultimate Sync Started!")
end

local function StopSync()
    Initialized = false
    PhysicsDisabledOnRemote = false
    RemoteIsDead = false
    RemotePawnCache = nil
    SpawnedWeapons = {}
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
    print("  Host=" .. tostring(IsHost) .. " Dead=" .. tostring(RemoteIsDead))
    print("  PhysOff=" .. tostring(PhysicsDisabledOnRemote))
end)

return UDPSync
