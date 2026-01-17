-- UDP Position Sync Module for Half Sword MP
-- Version 11.0: Safe Controller Rotation with Proper Checks
-- Only calls SetControlRotation on valid PlayerController instances

print("[UDPSync] Loading v11.0 Safe Controller Rotation...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 50  -- 20 Hz
local RESPAWN_COOLDOWN = 5  -- Longer cooldown for spawn stability
local MIN_VALID_Z = -500    -- Minimum Z to prevent underground spawns

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

-- ============================================================================
-- Helpers
-- ============================================================================

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

-- Check controller type and return info
-- Returns: "PlayerController", "AIController", "SpectatorController", "Unknown", or nil
local function GetControllerType(ctrl)
    if not ctrl then return nil end
    if not SafeGet(function() return ctrl:IsValid() end) then return nil end
    
    -- Get class name to determine controller type
    local className = SafeGet(function()
        local class = ctrl:GetClass()
        if class then
            return class:GetFName():ToString()
        end
        return nil
    end)
    
    if not className then return "Unknown" end
    
    -- Check for known controller types
    if className:find("PlayerController") then
        return "PlayerController"
    elseif className:find("AIController") then
        return "AIController"
    elseif className:find("SpectatorController") or className:find("Spectator") then
        return "SpectatorController"
    elseif className:find("DebugCamera") then
        return "DebugCameraController"
    else
        return "Unknown:" .. className
    end
end

-- Check if controller supports SetControlRotation (only PlayerController and its subclasses)
local function CanSetControlRotation(ctrl)
    local ctrlType = GetControllerType(ctrl)
    if not ctrlType then return false end
    
    -- Only PlayerController (and subclasses) support SetControlRotation safely
    if ctrlType == "PlayerController" then
        return true
    end
    
    -- Also check if it's player-controlled (for custom controllers)
    local isPlayerCtrl = SafeGet(function()
        return ctrl:IsPlayerControlled()
    end)
    
    return isPlayerCtrl == true
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
            
            -- Respawn detection for local pawn
            local myPtr = GetPawnPtr(myPawn)
            if myPtr ~= LastLocalPawnPtr then
                if LastLocalPawnPtr ~= nil then
                    LocalPawnChangeTime = now
                    if DebugMode then print("[UDPSync] Local respawn") end
                end
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
                    
                    -- Respawn detection for remote pawn
                    local remotePtr = GetPawnPtr(remote)
                    if remotePtr ~= LastRemotePawnPtr then
                        if LastRemotePawnPtr ~= nil then
                            RemotePawnChangeTime = now
                            if DebugMode then print("[UDPSync] Remote respawn") end
                        end
                        LastRemotePawnPtr = remotePtr
                    end
                    
                    if now - RemotePawnChangeTime < RESPAWN_COOLDOWN then return end
                    
                    if remote and IsPawnStable(remote) then
                        -- Validate incoming position (skip if obviously wrong)
                        if state.Z < MIN_VALID_Z then
                            if DebugMode then
                                print("[UDPSync] Skipping bad Z: " .. tostring(state.Z))
                            end
                            return
                        end
                        
                        -- Apply position (interpolated)
                        local currLoc = SafeGet(function() return remote:GetActorLocation() end)
                        if currLoc and currLoc.Z > MIN_VALID_Z then
                            -- Only sync if current position is also valid
                            local alpha = 0.3
                            local newLoc = {
                                X = currLoc.X + (state.X - currLoc.X) * alpha,
                                Y = currLoc.Y + (state.Y - currLoc.Y) * alpha,
                                Z = currLoc.Z + (state.Z - currLoc.Z) * alpha
                            }
                            
                            -- Don't let Z go below minimum
                            if newLoc.Z < MIN_VALID_Z then
                                newLoc.Z = currLoc.Z
                            end
                            
                            SafeGet(function()
                                remote:K2_SetActorLocation(newLoc, false, {}, false)
                            end)
                        end
                        
                        -- Apply actor rotation (Yaw for body facing)
                        SafeGet(function()
                            remote:K2_SetActorRotation({Pitch=0, Yaw=state.Yaw, Roll=0}, false)
                        end)
                        
                        -- Try to set controller rotation ONLY if it's a PlayerController
                        local remoteCtrl = SafeGet(function() return remote.Controller end)
                        if remoteCtrl and CanSetControlRotation(remoteCtrl) then
                            SafeGet(function()
                                remoteCtrl:SetControlRotation({
                                    Pitch = state.Pitch,
                                    Yaw = state.Yaw,
                                    Roll = state.Roll
                                })
                            end)
                            if DebugMode and RecvCount % 60 == 1 then
                                local ctrlType = GetControllerType(remoteCtrl)
                                print("[UDPSync] SetControlRotation on " .. tostring(ctrlType))
                            end
                        end
                    end
                end
                
                if DebugMode and RecvCount % 20 == 1 then
                    print("[UDPSync] RX#" .. RecvCount .. ": Y=" .. string.format("%.0f", state and state.Yaw or 0))
                end
            end
        end)
        
        return true
    end)
    
    print("[UDPSync] v11.1 Started")
end

local function StopSync()
    Initialized = false
    LastLocalPawnPtr = nil
    LastRemotePawnPtr = nil
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
    print("[UDPSync] v11.1 Debug=" .. tostring(DebugMode))
    print("  Ticks=" .. TickCount .. " Recv=" .. RecvCount)
    print("  LocalPtr=" .. tostring(LastLocalPawnPtr))
    print("  RemotePtr=" .. tostring(LastRemotePawnPtr))
    
    -- Show controller type for remote pawn
    local myPawn = GetMyPawn()
    local remote = FindRemotePawn(myPawn)
    if remote then
        local remoteCtrl = SafeGet(function() return remote.Controller end)
        local ctrlType = GetControllerType(remoteCtrl)
        local canSetRot = CanSetControlRotation(remoteCtrl)
        print("  RemoteController: " .. tostring(ctrlType) .. " CanSetRot=" .. tostring(canSetRot))
    else
        print("  RemotePawn: NOT FOUND")
    end
end)

return UDPSync
