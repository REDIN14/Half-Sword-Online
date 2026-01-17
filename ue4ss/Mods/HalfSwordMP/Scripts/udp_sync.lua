-- UDP Sync Module for Half Sword MP
-- Version 14.0: Input Replication
-- Syncs player INPUTS instead of position (works WITH physics)

print("[UDPSync] Loading v14.0 Input Replication...")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local UDP_PORT_BROADCAST = 7778
local UDP_PORT_RECEIVE = 7779
local SYNC_INTERVAL = 33  -- ~30 Hz for responsive input
local RESPAWN_COOLDOWN = 5

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

-- ============================================================================
-- Input Reading
-- ============================================================================

-- Read input axis values from controller
local function GetInputState(pawn, controller)
    local state = {
        MoveForward = 0,
        MoveRight = 0,
        LookPitch = 0,
        LookYaw = 0
    }
    
    if not pawn or not controller then return state end
    
    -- Try to get input axis values
    state.MoveForward = SafeGet(function() 
        return pawn:GetInputAxisValue(FName("MoveForward")) 
    end) or 0
    
    state.MoveRight = SafeGet(function() 
        return pawn:GetInputAxisValue(FName("MoveRight")) 
    end) or 0
    
    -- Get controller rotation for look direction
    local ctrlRot = SafeGet(function() return controller:GetControlRotation() end)
    if ctrlRot then
        state.LookPitch = ctrlRot.Pitch or 0
        state.LookYaw = ctrlRot.Yaw or 0
    end
    
    -- Also get position for fallback sync
    local loc = SafeGet(function() return pawn:GetActorLocation() end)
    if loc then
        state.X = loc.X
        state.Y = loc.Y
        state.Z = loc.Z
    end
    
    return state
end

-- Apply input to remote pawn
local function ApplyInputToRemote(remote, state)
    if not remote or not state then return end
    
    -- Apply movement input
    if state.MoveForward and state.MoveForward ~= 0 then
        SafeGet(function()
            local dir = SafeGet(function() return remote:GetActorForwardVector() end)
            if dir then
                remote:AddMovementInput(dir, state.MoveForward, false)
            end
        end)
    end
    
    if state.MoveRight and state.MoveRight ~= 0 then
        SafeGet(function()
            local dir = SafeGet(function() return remote:GetActorRightVector() end)
            if dir then
                remote:AddMovementInput(dir, state.MoveRight, false)
            end
        end)
    end
    
    -- Apply look rotation (actor yaw)
    if state.LookYaw then
        SafeGet(function()
            remote:K2_SetActorRotation({Pitch=0, Yaw=state.LookYaw, Roll=0}, false)
        end)
    end
    
    -- Fallback: gentle position correction if too far
    if state.X and state.Y and state.Z then
        local remoteLoc = SafeGet(function() return remote:GetActorLocation() end)
        if remoteLoc then
            local dx = state.X - remoteLoc.X
            local dy = state.Y - remoteLoc.Y
            local distSq = dx*dx + dy*dy
            
            -- Only correct if more than 500 units apart (severe desync)
            if distSq > 250000 then
                SafeGet(function()
                    remote:K2_SetActorLocation({X=state.X, Y=state.Y, Z=state.Z}, false, {}, false)
                end)
                if DebugMode then
                    print("[UDPSync] Position correction - severe desync")
                end
            end
        end
    end
end

-- ============================================================================
-- Protocol
-- ============================================================================

local function MakePacket(state)
    return string.format("I:%.2f,%.2f|L:%.1f,%.1f|P:%.0f,%.0f,%.0f",
        state.MoveForward or 0, state.MoveRight or 0,
        state.LookPitch or 0, state.LookYaw or 0,
        state.X or 0, state.Y or 0, state.Z or 0
    )
end

local function ParsePacket(data)
    if not data then return nil end
    
    local inputStr = data:match("I:([^|]+)")
    local lookStr = data:match("L:([^|]+)")
    local posStr = data:match("P:([^|]+)")
    
    local mf, mr = 0, 0
    if inputStr then
        mf, mr = inputStr:match("([^,]+),([^,]+)")
    end
    
    local lp, ly = 0, 0
    if lookStr then
        lp, ly = lookStr:match("([^,]+),([^,]+)")
    end
    
    local px, py, pz = 0, 0, 0
    if posStr then
        px, py, pz = posStr:match("([^,]+),([^,]+),([^,]+)")
    end
    
    return {
        MoveForward = tonumber(mf) or 0,
        MoveRight = tonumber(mr) or 0,
        LookPitch = tonumber(lp) or 0,
        LookYaw = tonumber(ly) or 0,
        X = tonumber(px) or 0,
        Y = tonumber(py) or 0,
        Z = tonumber(pz) or 0
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
            
            local myPtr = GetPawnPtr(myPawn)
            if myPtr ~= LastLocalPawnPtr then
                LocalPawnChangeTime = now
                LastLocalPawnPtr = myPtr
            end
            
            if now - LocalPawnChangeTime < RESPAWN_COOLDOWN then return end
            if not myPawn or not myController then return end
            if not IsPawnStable(myPawn) then return end
            
            -- Get and send input state
            local inputState = GetInputState(myPawn, myController)
            local packet = MakePacket(inputState)
            
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
                
                local remoteInput = ParsePacket(data)
                if remoteInput then
                    local remote = FindRemotePawn(myPawn)
                    
                    local remotePtr = GetPawnPtr(remote)
                    if remotePtr ~= LastRemotePawnPtr then
                        RemotePawnChangeTime = now
                        if LastRemotePawnPtr == nil then
                            print("[UDPSync] New remote - waiting to stabilize")
                        end
                        LastRemotePawnPtr = remotePtr
                    end
                    
                    if now - RemotePawnChangeTime < RESPAWN_COOLDOWN then return end
                    
                    if remote and IsPawnStable(remote) then
                        ApplyInputToRemote(remote, remoteInput)
                    end
                end
                
                if DebugMode and RecvCount % 30 == 1 then
                    print("[UDPSync] RX#" .. RecvCount .. 
                          " MF=" .. string.format("%.1f", remoteInput and remoteInput.MoveForward or 0) ..
                          " MR=" .. string.format("%.1f", remoteInput and remoteInput.MoveRight or 0))
                end
            end
        end)
        
        return true
    end)
    
    print("[UDPSync] v14.0 Input Replication Started")
end

local function StopSync()
    Initialized = false
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
    print("")
    print("=== UDPSync v14.0 INPUT REPLICATION ===")
    print("Debug: " .. tostring(DebugMode))
    print("Mode: " .. (IsHost and "HOST" or "CLIENT"))
    print("Ticks: " .. TickCount .. " Recv: " .. RecvCount)
    
    ExecuteInGameThread(function()
        local myPawn = GetMyPawn()
        local myController = GetMyController()
        if myPawn and myController then
            local state = GetInputState(myPawn, myController)
            print("MyInput: MF=" .. string.format("%.2f", state.MoveForward) ..
                  " MR=" .. string.format("%.2f", state.MoveRight))
            print("MyLook: P=" .. string.format("%.0f", state.LookPitch) ..
                  " Y=" .. string.format("%.0f", state.LookYaw))
        end
        
        local remote = FindRemotePawn(myPawn)
        print("Remote: " .. (remote and "Found" or "NOT FOUND"))
    end)
    print("========================================")
end)

print("[UDPSync] v14.0 loaded - F11 for status")

return UDPSync
