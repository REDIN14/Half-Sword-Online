-- UDP Position Sync Module for Half Sword MP
-- Uses LuaSocket for real network position synchronization
-- Version 3.0 (Ultimate Sync: Physics + Velocity + Stats + AI Kill)

print("[UDPSync] Loading Ultimate UDP Sync Module...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")
local KismetSystemLibrary = UEHelpers.GetKismetSystemLibrary(true)
local KismetMathLibrary = UEHelpers.GetKismetMathLibrary(true)

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778  -- Host broadcasts on this port
local UDP_PORT_RECEIVE = 7779    -- Clients send to host on this port
local SYNC_INTERVAL = 0.016      -- 60 Hz sync rate
local INTERPOLATION_SPEED = 20.0 -- Smoother interpolation
local VELOCITY_DAMPING = 0.5     -- Blend factor for velocity (0-1)

-- ============================================================================
-- State
-- ============================================================================

local IsHost = false
local LocalPawn = nil
local UDPSendSocket = nil
local UDPReceiveSocket = nil
local RemotePlayers = {}
local Initialized = false
local ClientIP = nil

-- ============================================================================
-- Helpers
-- ============================================================================

local function GetLocalPawn()
    local success, pc = pcall(UEHelpers.GetPlayerController)
    if success and pc and pc:IsValid() then
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
            return pawn
        end
    end
    return nil
end

local function DisableAI(pawn)
    if not pawn or not pawn:IsValid() then return end
    local controller = pawn.Controller
    if controller and controller:IsValid() and not controller:IsPlayerControlled() then
        controller:UnPossess() -- "Lobotomize" the AI so it doesn't fight the sync
    end
end

-- ============================================================================
-- Property Sync (Health, Stamina, Balance, etc.)
-- ============================================================================

local function GetSyncProperties(pawn)
    if not pawn or not pawn:IsValid() then return "" end
    local props = {}
    -- List of potential properties to sync
    local propNames = {
        "Health", "CurrentHealth", "MaxHealth",
        "Bleed", "Bleeding", "BloodLevel",
        "Damage", "DamageLevel",
        "Stamina", "CurrentStamina",
        "Energy", "CurrentEnergy",
        "Balance", "Poise", "Stability"
    }
    
    for _, name in ipairs(propNames) do
        local val = pawn[name]
        if val ~= nil and type(val) == "number" then
             table.insert(props, string.format("%s=%.2f", name, val))
        end
    end
    return table.concat(props, ",")
end

local function ApplySyncProperties(pawn, propString)
    if not pawn or not pawn:IsValid() or not propString or propString == "" then return end
    for key, value in string.gmatch(propString, "([^=]+)=([^,]+)") do
        local numVal = tonumber(value)
        if numVal then
             pcall(function() pawn[key] = numVal end)
        end
    end
end

-- ============================================================================
-- Physics & Transform Sync
-- ============================================================================

local function GetPawnState(pawn)
    if not pawn or not pawn:IsValid() then return nil end
    
    local loc = pawn:GetActorLocation()
    local rot = pawn:GetActorRotation()
    local vel = {X=0, Y=0, Z=0}
    
    -- Try to get physics velocity
    pcall(function()
        local v = pawn:GetVelocity()
        if v then vel = v end
    end)
    
    return {
        Pos = {X = loc.X, Y = loc.Y, Z = loc.Z},
        Rot = {Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll},
        Vel = {X = vel.X, Y = vel.Y, Z = vel.Z}
    }
end

local function ApplyPawnState(pawn, state, dt)
    if not pawn or not pawn:IsValid() or not state then return end
    
    -- 1. Position Interpolation
    local currentPos = pawn:GetActorLocation()
    local alpha = math.min(1.0, dt * INTERPOLATION_SPEED)
    
    local newX = currentPos.X + (state.Pos.X - currentPos.X) * alpha
    local newY = currentPos.Y + (state.Pos.Y - currentPos.Y) * alpha
    local newZ = currentPos.Z + (state.Pos.Z - currentPos.Z) * alpha
    
    pawn:K2_SetActorLocation({X=newX, Y=newY, Z=newZ}, false, {}, false)
    
    -- 2. Rotation (Direct set usually better for responsiveness, or lerp yaw)
    -- Simply creating a Rotator table
    local newRot = {Pitch=state.Rot.Pitch, Yaw=state.Rot.Yaw, Roll=state.Rot.Roll}
    pawn:K2_SetActorRotation(newRot, false)
    
    -- 3. Velocity Sync (Physics)
    pcall(function()
        -- Directly setting velocity helps physics engine predict next frame
        -- We blend it to avoid snapping
        -- Note: This might require specific collision component access in some games
        local rootComp = pawn.RootComponent
        if rootComp and rootComp:IsValid() then
             -- Simple approach: SetPhysicsLinearVelocity
             -- We multiply purely by 1 for clarity, but could dampen
             rootComp:SetPhysicsLinearVelocity(state.Vel, false, "None")
        end
    end)
end

-- ============================================================================
-- Network Packet Handling
-- ============================================================================

local function PacketToString(state, props)
    -- Format: POS:x,y,z|ROT:p,y,r|VEL:x,y,z|PROPS:k=v,...
    return string.format("POS:%.2f,%.2f,%.2f|ROT:%.2f,%.2f,%.2f|VEL:%.2f,%.2f,%.2f|PROPS:%s",
        state.Pos.X, state.Pos.Y, state.Pos.Z,
        state.Rot.Pitch, state.Rot.Yaw, state.Rot.Roll,
        state.Vel.X, state.Vel.Y, state.Vel.Z,
        props or ""
    )
end

local function StringToPacket(data)
    if not data then return nil end
    
    local posStr = data:match("POS:([^|]+)")
    local rotStr = data:match("ROT:([^|]+)")
    local velStr = data:match("VEL:([^|]+)")
    local propsStr = data:match("PROPS:(.*)")
    
    if not posStr then return nil end
    
    local px, py, pz = posStr:match("([^,]+),([^,]+),([^,]+)")
    local rx, ry, rz = rotStr and rotStr:match("([^,]+),([^,]+),([^,]+)") or 0,0,0
    local vx, vy, vz = velStr and velStr:match("([^,]+),([^,]+),([^,]+)") or 0,0,0
    
    return {
        Pos = {X=tonumber(px), Y=tonumber(py), Z=tonumber(pz)},
        Rot = {Pitch=tonumber(rx), Yaw=tonumber(ry), Roll=tonumber(rz)},
        Vel = {X=tonumber(vx), Y=tonumber(vy), Z=tonumber(vz)},
        Props = propsStr
    }
end

-- ============================================================================
-- Sync Loop
-- ============================================================================

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
                
                -- 1. Gather Local State
                local myState = GetPawnState(LocalPawn)
                local myProps = GetSyncProperties(LocalPawn)
                local packetData = PacketToString(myState, myProps)
                
                -- 2. Network IO
                local targetPacket = nil
                
                if IsHost then
                    -- Receive from Client
                    local data, ip = UDPReceiveSocket:receivefrom()
                    if data and ip then
                        ClientIP = ip
                        targetPacket = StringToPacket(data)
                    end
                    -- Send to Client
                    if ClientIP then
                        UDPSendSocket:sendto(packetData, ClientIP, UDP_PORT_BROADCAST)
                    end
                else
                    -- Send to Host
                    if hostIP then
                        UDPSendSocket:sendto(packetData, hostIP, UDP_PORT_RECEIVE)
                    end
                    -- Receive from Host
                    local data = UDPReceiveSocket:receivefrom()
                    if data then
                        targetPacket = StringToPacket(data)
                    end
                end
                
                -- 3. Apply to Remote Pawn
                if targetPacket then
                    local remotePawn = FindRemotePawn(LocalPawn)
                    if remotePawn then
                        DisableAI(remotePawn)
                        ApplyPawnState(remotePawn, targetPacket, SYNC_INTERVAL)
                        ApplySyncProperties(remotePawn, targetPacket.Props)
                    end
                end
            end)
        end)
        return true
    end)
    
    print("[UDPSync] Ultimate Sync Loop Started!")
end

local function StopSync()
    Initialized = false
    if UDPSendSocket then UDPSendSocket:close() end
    if UDPReceiveSocket then UDPReceiveSocket:close() end
    print("[UDPSync] Stopped.")
end

-- ============================================================================
-- Public API
-- ============================================================================

local UDPSync = {}
function UDPSync.StartAsHost() StartSyncLoop(nil) end
function UDPSync.StartAsClient(ip) StartSyncLoop(ip) end
function UDPSync.Stop() StopSync() end

-- F11 Debug
RegisterKeyBind(Key.F11, function()
    print("[UDPSync] Debug: IsHost="..tostring(IsHost).." Init="..tostring(Initialized))
end)

return UDPSync
