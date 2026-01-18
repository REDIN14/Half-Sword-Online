-- UDP Position Sync Module for Half Sword MP
-- Version 13.0: Kinematic Remote Pawns (Physics Disabled)
-- Disables physics on remote pawns to prevent fighting with sync

print("[UDPSync] Loading v13.0 Kinematic Sync...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 16  -- 60 Hz (was 50ms = 20 Hz)
local RESPAWN_COOLDOWN = 5
local MIN_VALID_Z = -500

-- Key bones to sync for upper body movement
local SYNC_BONES = {
    "pelvis", "spine_01", "spine_02", "spine_03",
    "head", "neck_01",
    "upperarm_l", "upperarm_r",
    "lowerarm_l", "lowerarm_r",
    "hand_l", "hand_r",
    "thigh_l", "thigh_r",
    "calf_l", "calf_r"
}

-- Alternative bone names (some skeletons use different conventions)
local ALT_BONE_NAMES = {
    pelvis = {"Pelvis", "Hips", "hip"},
    spine_01 = {"Spine", "spine1", "Spine1"},
    spine_02 = {"Spine1", "spine2", "Spine2"},
    spine_03 = {"Spine2", "spine3", "Spine3", "chest"},
    head = {"Head"},
    neck_01 = {"Neck", "neck"},
    upperarm_l = {"LeftUpperArm", "upperarm_L", "UpperArm_L"},
    upperarm_r = {"RightUpperArm", "upperarm_R", "UpperArm_R"},
    lowerarm_l = {"LeftLowerArm", "lowerarm_L", "LowerArm_L"},
    lowerarm_r = {"RightLowerArm", "lowerarm_R", "LowerArm_R"},
    hand_l = {"LeftHand", "hand_L", "Hand_L"},
    hand_r = {"RightHand", "hand_R", "Hand_R"},
    thigh_l = {"LeftThigh", "thigh_L", "Thigh_L"},
    thigh_r = {"RightThigh", "thigh_R", "Thigh_R"},
    calf_l = {"LeftCalf", "calf_L", "Calf_L", "shin_l"},
    calf_r = {"RightCalf", "calf_R", "Calf_R", "shin_r"}
}

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
local LastLocalPawnPtr = nil
local LastRemotePawnPtr = nil
local LocalPawnChangeTime = 0
local RemotePawnChangeTime = 0
local RemotePhysicsDisabled = false  -- Track if we've disabled physics

-- ============================================================================
-- Helpers
-- ============================================================================

local function SafeGet(fn)
    local ok, result = pcall(fn)
    return ok and result or nil
end

local function Log(msg)
    if DebugMode then
        print(msg)
    end
end

-- Normalize angle to -180 to 180
local function NormalizeAngle(angle)
    while angle > 180 do angle = angle - 360 end
    while angle < -180 do angle = angle + 360 end
    return angle
end

local function GetPawnPtr(pawn)
    if not pawn then return nil end
    return SafeGet(function() return tostring(pawn:GetAddress()) end)
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
    if not pawn then return false end
    if not SafeGet(function() return pawn:IsValid() end) then return false end
    local loc = SafeGet(function() return pawn:GetActorLocation() end)
    return loc ~= nil
end

local function GetMesh(pawn)
    if not pawn then return nil end
    return SafeGet(function() return pawn.Mesh end)
end

local function GetControllerType(ctrl)
    if not ctrl then return nil end
    if not SafeGet(function() return ctrl:IsValid() end) then return nil end

    local className = SafeGet(function()
        local class = ctrl:GetClass()
        if class then return class:GetFName():ToString() end
        return nil
    end)

    if not className then return "Unknown" end
    if className:find("PlayerController") then return "PlayerController"
    elseif className:find("AIController") then return "AIController"
    else return "Other:" .. className end
end

local function CanSetControlRotation(ctrl)
    return GetControllerType(ctrl) == "PlayerController"
end

-- ============================================================================
-- Physics Control (Key to fixing sync!)
-- ============================================================================

-- Disable physics simulation on a pawn's mesh
-- This is the key fix: remote pawns become kinematic "puppets"
-- that follow sync data exactly without physics interference
local function DisablePhysicsOnPawn(pawn)
    if not pawn or not SafeGet(function() return pawn:IsValid() end) then
        return false
    end

    local mesh = GetMesh(pawn)
    if not mesh or not SafeGet(function() return mesh:IsValid() end) then
        print("[UDPSync] No mesh found on pawn")
        return false
    end

    local success = false

    -- Method 1: Disable physics simulation on the mesh
    pcall(function()
        mesh:SetSimulatePhysics(false)
        print("[UDPSync] SetSimulatePhysics(false) called")
        success = true
    end)

    -- Method 2: Disable physics on all bodies
    pcall(function()
        mesh:SetAllBodiesSimulatePhysics(false)
        print("[UDPSync] SetAllBodiesSimulatePhysics(false) called")
        success = true
    end)

    -- Method 3: Disable gravity
    pcall(function()
        mesh:SetEnableGravity(false)
        print("[UDPSync] SetEnableGravity(false) called")
    end)

    -- Method 4: Set collision to QueryOnly (visual collision only, no physics response)
    -- ECollisionEnabled values: 0=NoCollision, 1=QueryOnly, 2=PhysicsOnly, 3=QueryAndPhysics
    pcall(function()
        mesh:SetCollisionEnabled(1)  -- QueryOnly
        print("[UDPSync] SetCollisionEnabled(QueryOnly) called")
    end)

    -- Method 5: Try setting all bodies to kinematic
    pcall(function()
        mesh:SetAllBodiesPhysicsBlendWeight(0.0)
        print("[UDPSync] SetAllBodiesPhysicsBlendWeight(0) called")
    end)

    if success then
        print("[UDPSync] Physics disabled on remote pawn - now kinematic")
    else
        print("[UDPSync] WARNING: Could not disable physics on pawn")
    end

    return success
end

-- Re-enable physics on a pawn (if needed for cleanup)
local function EnablePhysicsOnPawn(pawn)
    if not pawn or not SafeGet(function() return pawn:IsValid() end) then
        return false
    end

    local mesh = GetMesh(pawn)
    if not mesh then return false end

    pcall(function()
        mesh:SetSimulatePhysics(true)
        mesh:SetAllBodiesSimulatePhysics(true)
        mesh:SetEnableGravity(true)
        mesh:SetCollisionEnabled(3)  -- QueryAndPhysics
        mesh:SetAllBodiesPhysicsBlendWeight(1.0)
    end)

    print("[UDPSync] Physics re-enabled on pawn")
    return true
end

-- ============================================================================
-- Bone Sync
-- ============================================================================

-- Try to set bone rotation with fallback to alternative names
local function SetBoneRotation(mesh, boneName, rotation)
    if not mesh then return false end

    -- Try primary name
    local success = SafeGet(function()
        local fname = FName(boneName)
        mesh:SetBoneRotationByName(fname, rotation, 0)
        return true
    end)
    if success then return true end

    -- Try alternative names
    local alts = ALT_BONE_NAMES[boneName]
    if alts then
        for _, altName in ipairs(alts) do
            success = SafeGet(function()
                local fname = FName(altName)
                mesh:SetBoneRotationByName(fname, rotation, 0)
                return true
            end)
            if success then return true end
        end
    end

    return false
end

-- Apply upper body tilt based on pitch
local function ApplyUpperBodyTilt(mesh, pitch)
    if not mesh then return end

    -- Scale pitch for different spine sections
    local spineRotation = {Pitch = pitch * 0.3, Yaw = 0, Roll = 0}

    SetBoneRotation(mesh, "spine_01", spineRotation)
    SetBoneRotation(mesh, "spine_02", spineRotation)
    SetBoneRotation(mesh, "spine_03", {Pitch = pitch * 0.4, Yaw = 0, Roll = 0})
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
        Pitch = tonumber(cp) or 0, Yaw = NormalizeAngle(tonumber(cy) or 0), Roll = tonumber(cr) or 0
    }
end

-- ============================================================================
-- Apply Sync State to Remote Pawn
-- ============================================================================

local function ApplySyncToRemote(remote, state)
    if not remote or not state then return end
    if not SafeGet(function() return remote:IsValid() end) then return end
    if state.Z < MIN_VALID_Z then return end

    -- With physics disabled, we can teleport directly (no lerp needed!)
    -- The 'true' at the end is the teleport flag
    SafeGet(function()
        remote:K2_SetActorLocation(
            {X = state.X, Y = state.Y, Z = state.Z},
            false,  -- sweep
            {},     -- hit result
            true    -- teleport
        )
    end)

    -- Set actor rotation directly (teleport flag)
    SafeGet(function()
        remote:K2_SetActorRotation(
            {Pitch = 0, Yaw = state.Yaw, Roll = 0},
            true  -- teleport
        )
    end)

    -- Controller rotation if PlayerController
    local remoteCtrl = SafeGet(function() return remote.Controller end)
    if remoteCtrl and CanSetControlRotation(remoteCtrl) then
        SafeGet(function()
            remoteCtrl:SetControlRotation({
                Pitch = state.Pitch,
                Yaw = state.Yaw,
                Roll = state.Roll
            })
        end)
    end

    -- Apply upper body tilt for looking up/down
    local mesh = GetMesh(remote)
    if mesh then
        ApplyUpperBodyTilt(mesh, state.Pitch)
    end
end

-- ============================================================================
-- Main Sync Loop
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
    RemotePhysicsDisabled = false

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
    print("[UDPSync] Sync rate: " .. math.floor(1000/SYNC_INTERVAL) .. " Hz")
    Initialized = true

    LoopAsync(SYNC_INTERVAL, function()
        if not Initialized then return true end

        TickCount = TickCount + 1
        local now = os.time()

        -- Wait for game to stabilize
        if now - StartTime < 3 then return true end

        ExecuteInGameThread(function()
            local myPawn = GetMyPawn()
            local myController = GetMyController()

            -- Track local pawn changes (respawns)
            local myPtr = GetPawnPtr(myPawn)
            if myPtr ~= LastLocalPawnPtr then
                LocalPawnChangeTime = now
                LastLocalPawnPtr = myPtr
            end

            if now - LocalPawnChangeTime < RESPAWN_COOLDOWN then return end
            if not myPawn or not myController then return end
            if not IsPawnStable(myPawn) then return end

            local packet = MakePacket(myPawn, myController)
            if not packet then return end

            -- Send our state
            if IsHost and ClientIP then
                UDPSendSocket:sendto(packet, ClientIP, UDP_PORT_BROADCAST)
            elseif not IsHost and TargetHostIP then
                UDPSendSocket:sendto(packet, TargetHostIP, UDP_PORT_RECEIVE)
            end

            -- Receive remote state
            local data, ip = UDPReceiveSocket:receivefrom()
            if data then
                RecvCount = RecvCount + 1
                if IsHost and ip then ClientIP = ip end

                local state = ParsePacket(data)
                if state then
                    local remote = FindRemotePawn(myPawn)

                    -- Check if remote pawn changed
                    local remotePtr = GetPawnPtr(remote)
                    if remotePtr ~= LastRemotePawnPtr then
                        print("[UDPSync] New remote pawn detected")
                        RemotePawnChangeTime = now
                        LastRemotePawnPtr = remotePtr
                        RemotePhysicsDisabled = false  -- Reset flag for new pawn
                    end

                    -- Wait for remote pawn to stabilize
                    if now - RemotePawnChangeTime < RESPAWN_COOLDOWN then return end

                    if remote and IsPawnStable(remote) then
                        -- CRITICAL: Disable physics on first sync with this remote pawn
                        if not RemotePhysicsDisabled then
                            print("[UDPSync] Disabling physics on remote pawn...")
                            if DisablePhysicsOnPawn(remote) then
                                RemotePhysicsDisabled = true
                                print("[UDPSync] Remote pawn is now kinematic - sync should work!")
                            else
                                print("[UDPSync] WARNING: Failed to disable physics, sync may jitter")
                            end
                        end

                        -- Apply the sync state
                        ApplySyncToRemote(remote, state)
                    end
                end

                if DebugMode and RecvCount % 60 == 1 then
                    print(string.format("[UDPSync] RX#%d Pos=(%.0f,%.0f,%.0f) Yaw=%.0f",
                        RecvCount, state.X, state.Y, state.Z, state.Yaw))
                end
            end
        end)

        return true
    end)

    print("[UDPSync] v13.0 Kinematic Sync Started")
end

local function StopSync()
    Initialized = false
    RemotePhysicsDisabled = false
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

-- Debug key binding
RegisterKeyBind(Key.F11, function()
    DebugMode = not DebugMode
    print("[UDPSync] v13.0 Kinematic Sync")
    print("  Debug=" .. tostring(DebugMode))
    print("  Ticks=" .. TickCount .. " Recv=" .. RecvCount)
    print("  SyncRate=" .. math.floor(1000/SYNC_INTERVAL) .. "Hz")
    print("  PhysicsDisabled=" .. tostring(RemotePhysicsDisabled))

    local myPawn = GetMyPawn()
    local remote = FindRemotePawn(myPawn)
    if remote then
        local loc = SafeGet(function() return remote:GetActorLocation() end)
        if loc then
            print(string.format("  RemotePos=(%.0f,%.0f,%.0f)", loc.X, loc.Y, loc.Z))
        end
        local remoteCtrl = SafeGet(function() return remote.Controller end)
        print("  RemoteCtrl: " .. tostring(GetControllerType(remoteCtrl)))
    else
        print("  No remote pawn found")
    end
end)

return UDPSync
