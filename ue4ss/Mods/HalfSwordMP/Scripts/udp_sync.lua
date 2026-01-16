-- UDP Position Sync Module for Half Sword MP
-- Version 7.0: Robust Sync (Position + Rotation + Damage)
-- NOTE: Bone transforms don't work with Half Sword's active ragdoll physics
-- The physics engine immediately overrides any bone position changes

print("[UDPSync] Loading v7.0 Robust Sync...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 0.050  -- 20 Hz (more stable)
local INTERPOLATION_SPEED = 10.0

-- Damage properties to sync
local DAMAGE_PROPS = {
    "Health", "CurrentHealth", "MaxHealth",
    "BleedLevel", "BleedRate",
    "Stamina", "StaminaCurrent",
    "Balance", "BalanceCurrent"
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
local RemotePawnCache = nil
local LastDeathState = false
local LocalPawnCache = nil

-- ============================================================================
-- Safe Helpers
-- ============================================================================

local function SafeCall(fn)
    local ok, result = pcall(fn)
    if not ok then
        if DebugMode and result then
            print("[UDPSync] SafeCall error: " .. tostring(result))
        end
        return nil
    end
    return result
end

local function IsValidPawn(pawn)
    if not pawn then return false end
    local valid = false
    SafeCall(function()
        valid = pawn:IsValid()
    end)
    return valid
end

local function GetLocalPawn()
    -- Use cache if still valid
    if IsValidPawn(LocalPawnCache) then
        return LocalPawnCache
    end
    
    return SafeCall(function()
        local pc = UEHelpers.GetPlayerController()
        if pc and pc:IsValid() and pc.Pawn and pc.Pawn:IsValid() then
            LocalPawnCache = pc.Pawn
            return pc.Pawn
        end
        return nil
    end)
end

local function FindRemotePawn(localPawn)
    if IsValidPawn(RemotePawnCache) and RemotePawnCache ~= localPawn then
        return RemotePawnCache
    end
    
    return SafeCall(function()
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
    end)
end

-- ============================================================================
-- Physics Control (only for remote pawn)
-- ============================================================================

local PhysicsDisabled = false

local function DisableRemotePhysics(pawn)
    if PhysicsDisabled then return end
    if not IsValidPawn(pawn) then return end
    
    SafeCall(function()
        local mesh = pawn.Mesh
        if mesh and mesh:IsValid() then
            -- Disable physics so we can control position directly
            mesh:SetAllBodiesSimulatePhysics(false)
            mesh:SetCollisionEnabled(0)
            print("[UDPSync] Disabled remote physics")
        end
    end)
    
    -- Disconnect AI controller
    SafeCall(function()
        local controller = pawn.Controller
        if controller and controller:IsValid() and not controller:IsPlayerControlled() then
            controller:UnPossess()
        end
    end)
    
    PhysicsDisabled = true
end

local function EnableRemotePhysics(pawn)
    if not PhysicsDisabled then return end
    if not IsValidPawn(pawn) then return end
    
    SafeCall(function()
        local mesh = pawn.Mesh
        if mesh and mesh:IsValid() then
            mesh:SetAllBodiesSimulatePhysics(true)
            mesh:SetCollisionEnabled(1)
            print("[UDPSync] Enabled remote physics (death)")
        end
    end)
    
    PhysicsDisabled = false
end

-- ============================================================================
-- Damage Sync
-- ============================================================================

local function GetDamageState(pawn)
    if not IsValidPawn(pawn) then return "" end
    
    local props = {}
    for _, propName in ipairs(DAMAGE_PROPS) do
        SafeCall(function()
            local val = pawn[propName]
            if val ~= nil and type(val) == "number" then
                table.insert(props, string.format("%s=%.0f", propName, val))
            end
        end)
    end
    return table.concat(props, ",")
end

local function ApplyDamageState(pawn, damageStr)
    if not IsValidPawn(pawn) or not damageStr or damageStr == "" then return end
    
    for entry in string.gmatch(damageStr, "([^,]+)") do
        local key, value = entry:match("([^=]+)=([^,]+)")
        if key and value then
            local numVal = tonumber(value)
            if numVal then
                SafeCall(function() pawn[key] = numVal end)
            end
        end
    end
end

local function IsDead(pawn)
    if not IsValidPawn(pawn) then return false end
    
    local dead = false
    SafeCall(function()
        local health = pawn.Health or pawn.CurrentHealth or 100
        dead = (health <= 0)
    end)
    return dead
end

-- ============================================================================
-- Network Protocol
-- ============================================================================

local function PackState(loc, rot, damageData, isDead)
    return string.format("P:%.0f,%.0f,%.0f|R:%.0f,%.0f,%.0f|D:%s|X:%d",
        loc.X, loc.Y, loc.Z,
        rot.Pitch, rot.Yaw, rot.Roll,
        damageData or "",
        isDead and 1 or 0
    )
end

local function UnpackState(data)
    if not data then return nil end
    
    local posStr = data:match("P:([^|]+)")
    local rotStr = data:match("R:([^|]+)")
    local damageStr = data:match("D:([^|]*)")
    local deadStr = data:match("X:(%d)")
    
    if not posStr then return nil end
    
    local px, py, pz = posStr:match("([^,]+),([^,]+),([^,]+)")
    local rx, ry, rz = rotStr and rotStr:match("([^,]+),([^,]+),([^,]+)") or 0, 0, 0
    
    return {
        Pos = {X = tonumber(px) or 0, Y = tonumber(py) or 0, Z = tonumber(pz) or 0},
        Rot = {Pitch = tonumber(rx) or 0, Yaw = tonumber(ry) or 0, Roll = tonumber(rz) or 0},
        Damage = damageStr,
        IsDead = deadStr == "1"
    }
end

-- ============================================================================
-- Main Sync Loop
-- ============================================================================

local function StartSyncLoop(hostIP)
    if Initialized then 
        print("[UDPSync] Already running")
        return 
    end
    
    IsHost = (hostIP == nil or hostIP == "")
    PhysicsDisabled = false
    RemotePawnCache = nil
    LocalPawnCache = nil
    LastDeathState = false
    
    -- Create sockets
    UDPSendSocket = socket.udp()
    UDPSendSocket:settimeout(0)
    UDPReceiveSocket = socket.udp()
    UDPReceiveSocket:settimeout(0)
    
    local bindResult
    if IsHost then
        bindResult = UDPReceiveSocket:setsockname("*", UDP_PORT_RECEIVE)
        print("[UDPSync] HOST mode, listening on port " .. UDP_PORT_RECEIVE)
    else
        bindResult = UDPReceiveSocket:setsockname("*", UDP_PORT_BROADCAST)
        print("[UDPSync] CLIENT mode, listening on port " .. UDP_PORT_BROADCAST)
        print("[UDPSync] Target host: " .. tostring(hostIP))
    end
    
    if not bindResult then
        print("[UDPSync] WARNING: Socket bind may have failed")
    end
    
    Initialized = true
    
    LoopAsync(math.floor(SYNC_INTERVAL * 1000), function()
        if not Initialized then return true end
        
        SafeCall(function()
            ExecuteInGameThread(function()
                -- Get local pawn with validation
                local localPawn = GetLocalPawn()
                if not IsValidPawn(localPawn) then
                    return
                end
                
                -- Get location and rotation safely
                local loc = SafeCall(function() return localPawn:GetActorLocation() end)
                local rot = SafeCall(function() return localPawn:GetActorRotation() end)
                if not loc or not rot then return end
                
                -- Gather state
                local damageData = GetDamageState(localPawn)
                local dead = IsDead(localPawn)
                local packet = PackState(loc, rot, damageData, dead)
                
                -- Send packet
                if IsHost then
                    if ClientIP then
                        UDPSendSocket:sendto(packet, ClientIP, UDP_PORT_BROADCAST)
                    end
                else
                    if hostIP then
                        UDPSendSocket:sendto(packet, hostIP, UDP_PORT_RECEIVE)
                    end
                end
                
                -- Receive and process
                local data, senderIP = UDPReceiveSocket:receivefrom()
                if data then
                    if IsHost and senderIP then 
                        ClientIP = senderIP 
                    end
                    
                    local state = UnpackState(data)
                    if state then
                        local remote = FindRemotePawn(localPawn)
                        if IsValidPawn(remote) then
                            -- Handle death state
                            if state.IsDead and not LastDeathState then
                                EnableRemotePhysics(remote)
                                LastDeathState = true
                            elseif not state.IsDead then
                                if LastDeathState then
                                    DisableRemotePhysics(remote)
                                    LastDeathState = false
                                else
                                    DisableRemotePhysics(remote)
                                end
                                
                                -- Apply position with interpolation
                                local currLoc = SafeCall(function() return remote:GetActorLocation() end)
                                if currLoc then
                                    local alpha = math.min(1.0, SYNC_INTERVAL * INTERPOLATION_SPEED)
                                    local newLoc = {
                                        X = currLoc.X + (state.Pos.X - currLoc.X) * alpha,
                                        Y = currLoc.Y + (state.Pos.Y - currLoc.Y) * alpha,
                                        Z = currLoc.Z + (state.Pos.Z - currLoc.Z) * alpha
                                    }
                                    SafeCall(function()
                                        remote:K2_SetActorLocation(newLoc, false, {}, false)
                                    end)
                                end
                                
                                -- Apply rotation
                                SafeCall(function()
                                    remote:K2_SetActorRotation(state.Rot, false)
                                end)
                            end
                            
                            -- Always apply damage
                            ApplyDamageState(remote, state.Damage)
                        end
                    end
                end
            end)
        end)
        
        return true  -- Keep loop running
    end)
    
    print("[UDPSync] v7.0 Robust Sync Started!")
end

local function StopSync()
    Initialized = false
    PhysicsDisabled = false
    RemotePawnCache = nil
    LocalPawnCache = nil
    LastDeathState = false
    
    if UDPSendSocket then 
        SafeCall(function() UDPSendSocket:close() end)
    end
    if UDPReceiveSocket then 
        SafeCall(function() UDPReceiveSocket:close() end)
    end
    
    print("[UDPSync] Stopped")
end

-- ============================================================================
-- Public API
-- ============================================================================

local UDPSync = {}
function UDPSync.StartAsHost() StartSyncLoop(nil) end
function UDPSync.StartAsClient(ip) StartSyncLoop(ip) end
function UDPSync.Stop() StopSync() end

-- Debug keybind
RegisterKeyBind(Key.F11, function()
    DebugMode = not DebugMode
    print("[UDPSync] Debug=" .. tostring(DebugMode))
    print("  IsHost=" .. tostring(IsHost))
    print("  ClientIP=" .. tostring(ClientIP))
    print("  PhysicsOff=" .. tostring(PhysicsDisabled))
    print("  DeathState=" .. tostring(LastDeathState))
    
    local lp = GetLocalPawn()
    print("  LocalPawn=" .. (IsValidPawn(lp) and lp:GetFullName() or "nil"))
    
    local rp = RemotePawnCache
    print("  RemotePawn=" .. (IsValidPawn(rp) and rp:GetFullName() or "nil"))
end)

return UDPSync
