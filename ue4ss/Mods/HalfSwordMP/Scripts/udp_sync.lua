-- UDP Position Sync Module for Half Sword MP
-- Version 12.2: Kinematic Remote Pawns + Rotation Fix
-- Disables physics on remote pawns to prevent sync fighting

print("[UDPSync] Loading v12.2 Kinematic Sync...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 50  -- 20 Hz
local RESPAWN_COOLDOWN = 5
local MIN_VALID_Z = -500

-- Sync aggressiveness (lower = gentler, less fighting with physics)
local POSITION_LERP = 0.15   -- Was 0.3, now gentler
local ROTATION_LERP = 0.25   -- For smooth rotation

local SPINE_BONES = {"spine_01", "spine_02", "spine_03", "Spine", "Spine1", "Spine2"}

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
local RemotePhysicsDisabled = false

-- ============================================================================
-- Math Helpers
-- ============================================================================

-- Normalize angle to -180 to 180
local function NormalizeAngle(angle)
    while angle > 180 do angle = angle - 360 end
    while angle < -180 do angle = angle + 360 end
    return angle
end

-- Lerp angle with proper wrapping
local function LerpAngle(from, to, alpha)
    local diff = NormalizeAngle(to - from)
    return from + diff * alpha
end

local function SafeGet(fn)
    local ok, result = pcall(fn)
    return ok and result or nil
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

local function GetMesh(pawn)
    if not pawn then return nil end
    return SafeGet(function() return pawn.Mesh end)
end

-- Disable physics on remote pawn to prevent fighting with sync
local function DisablePhysicsOnPawn(pawn)
    if not pawn then return false end
    local mesh = GetMesh(pawn)
    if not mesh then return false end

    local success = false

    -- Try to disable physics simulation
    pcall(function()
        mesh:SetSimulatePhysics(false)
        success = true
    end)

    pcall(function()
        mesh:SetAllBodiesSimulatePhysics(false)
        success = true
    end)

    pcall(function()
        mesh:SetEnableGravity(false)
    end)

    -- QueryOnly collision (visual only, no physics response)
    pcall(function()
        mesh:SetCollisionEnabled(1)
    end)

    if success then
        print("[UDPSync] Physics disabled on remote pawn")
    end
    return success
end

local function TrySetBoneRotation(mesh, boneNames, pitch)
    if not mesh then return false end
    
    for _, boneName in ipairs(boneNames) do
        local success = SafeGet(function()
            local fname = FName(boneName)
            mesh:SetBoneRotationByName(fname, {Pitch=pitch, Yaw=0, Roll=0}, 0)
            return true
        end)
        if success then return true end
    end
    return false
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
        Pitch = tonumber(cp) or 0, Yaw = tonumber(cy) or 0, Roll = tonumber(cr) or 0
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
    Initialized = true
    
    LoopAsync(SYNC_INTERVAL, function()
        if not Initialized then return true end
        
        TickCount = TickCount + 1
        local now = os.time()
        
        if now - StartTime < 3 then return true end
        
        ExecuteInGameThread(function()
            local myPawn = GetMyPawn()
            local myController = GetMyController()
            
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
                
                local state = ParsePacket(data)
                if state then
                    local remote = FindRemotePawn(myPawn)
                    
                    local remotePtr = GetPawnPtr(remote)
                    if remotePtr ~= LastRemotePawnPtr then
                        RemotePawnChangeTime = now
                        RemotePhysicsDisabled = false  -- Reset for new pawn
                        if LastRemotePawnPtr == nil then
                            print("[UDPSync] New remote - waiting to stabilize")
                        end
                        LastRemotePawnPtr = remotePtr
                    end

                    if now - RemotePawnChangeTime < RESPAWN_COOLDOWN then return end

                    if remote and IsPawnStable(remote) then
                        -- Disable physics on remote pawn (only once)
                        if not RemotePhysicsDisabled then
                            if DisablePhysicsOnPawn(remote) then
                                RemotePhysicsDisabled = true
                            end
                        end
                        if state.Z < MIN_VALID_Z then return end
                        
                        -- Apply position (gentler lerp)
                        local currLoc = SafeGet(function() return remote:GetActorLocation() end)
                        if currLoc and currLoc.Z > MIN_VALID_Z then
                            local newLoc = {
                                X = currLoc.X + (state.X - currLoc.X) * POSITION_LERP,
                                Y = currLoc.Y + (state.Y - currLoc.Y) * POSITION_LERP,
                                Z = math.max(currLoc.Z + (state.Z - currLoc.Z) * POSITION_LERP, MIN_VALID_Z)
                            }
                            SafeGet(function()
                                remote:K2_SetActorLocation(newLoc, false, {}, false)
                            end)
                        end
                        
                        -- Apply rotation with proper angle lerping
                        local currRot = SafeGet(function() return remote:GetActorRotation() end)
                        if currRot then
                            local newYaw = LerpAngle(currRot.Yaw, state.Yaw, ROTATION_LERP)
                            SafeGet(function()
                                remote:K2_SetActorRotation({Pitch=0, Yaw=newYaw, Roll=0}, false)
                            end)
                        end
                        
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
                        
                        -- Spine bone rotation for upper body tilt
                        local mesh = GetMesh(remote)
                        if mesh then
                            TrySetBoneRotation(mesh, SPINE_BONES, state.Pitch * 0.5)
                        end
                    end
                end
                
                if DebugMode and RecvCount % 20 == 1 then
                    print("[UDPSync] RX#" .. RecvCount .. " Y=" .. string.format("%.0f", state and state.Yaw or 0))
                end
            end
        end)
        
        return true
    end)
    
    print("[UDPSync] v12.2 Started")
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

RegisterKeyBind(Key.F11, function()
    DebugMode = not DebugMode
    print("[UDPSync] v12.2 Debug=" .. tostring(DebugMode))
    print("  Ticks=" .. TickCount .. " Recv=" .. RecvCount)
    print("  PosLerp=" .. POSITION_LERP .. " RotLerp=" .. ROTATION_LERP)
    print("  PhysicsDisabled=" .. tostring(RemotePhysicsDisabled))

    local myPawn = GetMyPawn()
    local remote = FindRemotePawn(myPawn)
    if remote then
        local remoteCtrl = SafeGet(function() return remote.Controller end)
        print("  RemoteCtrl: " .. tostring(GetControllerType(remoteCtrl)))
    end
end)

return UDPSync
