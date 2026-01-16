-- UDP Position Sync Module for Half Sword MP
-- Version 10.0: Controller Rotation Sync
-- Syncs GetControlRotation for proper facing direction

print("[UDPSync] Loading v10.0 Controller Rotation Sync...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 50  -- 20 Hz

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
local RemotePawnCache = nil

-- ============================================================================
-- Helpers
-- ============================================================================

local function SafeGet(fn)
    local ok, result = pcall(fn)
    return ok and result or nil
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
    if pawn and SafeGet(function() return pawn:IsValid() end) then
        return pawn
    end
    return nil
end

local function FindRemotePawn(myPawn)
    if RemotePawnCache and SafeGet(function() return RemotePawnCache:IsValid() end) then
        if RemotePawnCache ~= myPawn then return RemotePawnCache end
    end
    
    local allPawns = SafeGet(function() return FindAllOf("Pawn") end)
    if not allPawns then return nil end
    
    for _, p in ipairs(allPawns) do
        if p ~= myPawn then
            -- Check if it's player-controlled (not NPC)
            local isPlayer = SafeGet(function() return p:IsPlayerControlled() end)
            if isPlayer then
                RemotePawnCache = p
                return p
            end
        end
    end
    return nil
end

-- ============================================================================
-- Protocol: Position + Controller Rotation
-- ============================================================================

local function MakePacket(pawn, controller)
    local loc = SafeGet(function() return pawn:GetActorLocation() end)
    
    -- Get CONTROLLER rotation (where player is looking), not actor rotation
    local ctrlRot = SafeGet(function() return controller:GetControlRotation() end)
    
    -- Also get actor rotation as backup
    local actorRot = SafeGet(function() return pawn:GetActorRotation() end)
    
    if loc and (ctrlRot or actorRot) then
        local rot = ctrlRot or actorRot
        return string.format("P:%.0f,%.0f,%.0f|C:%.1f,%.1f,%.1f|A:%.1f,%.1f,%.1f",
            loc.X, loc.Y, loc.Z,
            rot.Pitch, rot.Yaw, rot.Roll,
            actorRot and actorRot.Pitch or 0,
            actorRot and actorRot.Yaw or 0,
            actorRot and actorRot.Roll or 0
        )
    end
    return nil
end

local function ParsePacket(data)
    if not data then return nil end
    
    local posStr = data:match("P:([^|]+)")
    local ctrlStr = data:match("C:([^|]+)")
    local actorStr = data:match("A:([^|]+)")
    
    if not posStr then return nil end
    
    local px, py, pz = posStr:match("([^,]+),([^,]+),([^,]+)")
    
    local cp, cy, cr = 0, 0, 0
    if ctrlStr then
        cp, cy, cr = ctrlStr:match("([^,]+),([^,]+),([^,]+)")
    end
    
    local ap, ay, ar = 0, 0, 0
    if actorStr then
        ap, ay, ar = actorStr:match("([^,]+),([^,]+),([^,]+)")
    end
    
    return {
        X = tonumber(px) or 0, Y = tonumber(py) or 0, Z = tonumber(pz) or 0,
        CtrlPitch = tonumber(cp) or 0, CtrlYaw = tonumber(cy) or 0, CtrlRoll = tonumber(cr) or 0,
        ActorPitch = tonumber(ap) or 0, ActorYaw = tonumber(ay) or 0, ActorRoll = tonumber(ar) or 0
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
    RemotePawnCache = nil
    
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
        
        -- Wait for game to fully load
        if os.time() - StartTime < 3 then return true end
        
        ExecuteInGameThread(function()
            local myPawn = GetMyPawn()
            local myController = GetMyController()
            if not myPawn or not myController then return end
            
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
                    if remote then
                        -- Apply position (interpolated)
                        local currLoc = SafeGet(function() return remote:GetActorLocation() end)
                        if currLoc then
                            local alpha = 0.3
                            local newLoc = {
                                X = currLoc.X + (state.X - currLoc.X) * alpha,
                                Y = currLoc.Y + (state.Y - currLoc.Y) * alpha,
                                Z = currLoc.Z + (state.Z - currLoc.Z) * alpha
                            }
                            SafeGet(function()
                                remote:K2_SetActorLocation(newLoc, false, {}, false)
                            end)
                        end
                        
                        -- Apply ACTOR rotation (this controls body facing)
                        SafeGet(function()
                            remote:K2_SetActorRotation({
                                Pitch = 0,  -- Keep upright
                                Yaw = state.CtrlYaw,  -- Use controller yaw for facing
                                Roll = 0
                            }, false)
                        end)
                        
                        -- Try to set controller rotation on remote's controller
                        local remoteCtrl = SafeGet(function() return remote.Controller end)
                        if remoteCtrl then
                            SafeGet(function()
                                remoteCtrl:SetControlRotation({
                                    Pitch = state.CtrlPitch,
                                    Yaw = state.CtrlYaw,
                                    Roll = state.CtrlRoll
                                })
                            end)
                        end
                    end
                end
                
                if DebugMode and RecvCount % 20 == 1 then
                    print("[UDPSync] RX: " .. data:sub(1,40))
                end
            end
        end)
        
        return true
    end)
    
    print("[UDPSync] v10.0 Started")
end

local function StopSync()
    Initialized = false
    RemotePawnCache = nil
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
    print("[UDPSync] v10.0 Debug=" .. tostring(DebugMode))
    print("  Ticks=" .. TickCount .. " Recv=" .. RecvCount)
    print("  IsHost=" .. tostring(IsHost) .. " Client=" .. tostring(ClientIP))
    
    local ctrl = GetMyController()
    if ctrl then
        local rot = SafeGet(function() return ctrl:GetControlRotation() end)
        if rot then
            print("  CtrlRot: P=" .. string.format("%.1f", rot.Pitch) .. 
                  " Y=" .. string.format("%.1f", rot.Yaw))
        end
    end
end)

return UDPSync
