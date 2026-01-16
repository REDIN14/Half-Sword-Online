-- Position Sync Module for Half Sword MP
-- Handles position synchronization between players
-- Version 1.0

print("[PositionSync] Loading Position Sync Module...")

local UEHelpers = require("UEHelpers")

-- ============================================================================
-- Configuration
-- ============================================================================

local SYNC_ENABLED = true
local SYNC_INTERVAL = 0.016  -- 16ms = ~60 Hz (maximum practical speed)
local INTERPOLATION_SPEED = 25.0  -- Very fast interpolation for snappy movement

-- ============================================================================
-- State
-- ============================================================================

local IsHost = false
local LocalPawn = nil
local RemotePlayers = {}  -- Table of remote player pawns and their target positions
local LastSyncTime = 0
local SyncInitialized = false

-- ============================================================================
-- Utility Functions
-- ============================================================================

local function GetAllCharacters()
    return FindAllOf("Character") or FindAllOf("Pawn") or {}
end

local function GetLocalPawn()
    local pc = UEHelpers.GetPlayerController()
    if pc and pc:IsValid() then
        local pawn = pc.Pawn
        if pawn and pawn:IsValid() then
            return pawn
        end
    end
    return nil
end

local function CheckIfHost()
    local pc = UEHelpers.GetPlayerController()
    if pc and pc:IsValid() then
        local success, hasAuth = pcall(function() return pc:HasAuthority() end)
        if success then
            return hasAuth
        end
    end
    return false
end

local function GetPawnPosition(pawn)
    if pawn and pawn:IsValid() then
        local success, loc = pcall(function() return pawn:GetActorLocation() end)
        if success and loc then
            return {X = loc.X, Y = loc.Y, Z = loc.Z}
        end
    end
    return nil
end

local function GetPawnRotation(pawn)
    if pawn and pawn:IsValid() then
        local success, rot = pcall(function() return pawn:GetActorRotation() end)
        if success and rot then
            return {Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll}
        end
    end
    return nil
end

local function SetPawnPosition(pawn, pos)
    if pawn and pawn:IsValid() and pos then
        local success, err = pcall(function()
            -- Create FVector for position
            local newLoc = {}
            newLoc.X = pos.X
            newLoc.Y = pos.Y
            newLoc.Z = pos.Z
            pawn:K2_SetActorLocation(newLoc, false, {}, false)
        end)
        return success
    end
    return false
end

-- ============================================================================
-- Interpolation
-- ============================================================================

local function Lerp(a, b, t)
    return a + (b - a) * t
end

local function LerpPosition(current, target, deltaTime)
    if not current or not target then return target end
    local t = math.min(1.0, INTERPOLATION_SPEED * deltaTime)
    return {
        X = Lerp(current.X, target.X, t),
        Y = Lerp(current.Y, target.Y, t),
        Z = Lerp(current.Z, target.Z, t)
    }
end

-- ============================================================================
-- Sync Logic
-- ============================================================================

local function IdentifyRemotePlayers()
    local localPawn = GetLocalPawn()
    if not localPawn then return end
    
    local allChars = GetAllCharacters()
    RemotePlayers = {}
    
    for i, char in ipairs(allChars) do
        if char:IsValid() and char ~= localPawn then
            local pos = GetPawnPosition(char)
            if pos then
                table.insert(RemotePlayers, {
                    pawn = char,
                    lastPosition = pos,
                    targetPosition = pos,
                    interpolatedPosition = pos
                })
            end
        end
    end
    
    if #RemotePlayers > 0 then
        print(string.format("[PositionSync] Found %d remote player(s)", #RemotePlayers))
    end
end

local function UpdateRemotePositions(deltaTime)
    for _, remote in ipairs(RemotePlayers) do
        if remote.pawn and remote.pawn:IsValid() then
            -- Get current server position
            local serverPos = GetPawnPosition(remote.pawn)
            if serverPos then
                remote.targetPosition = serverPos
                
                -- Interpolate smoothly
                if remote.interpolatedPosition then
                    remote.interpolatedPosition = LerpPosition(
                        remote.interpolatedPosition,
                        remote.targetPosition,
                        deltaTime
                    )
                else
                    remote.interpolatedPosition = serverPos
                end
            end
        end
    end
end

-- ============================================================================
-- Main Sync Loop (via LoopAsync)
-- ============================================================================

local SyncLoopRunning = false

local function StartSyncLoop()
    if SyncLoopRunning then return end
    SyncLoopRunning = true
    
    print("[PositionSync] Starting sync loop...")
    
    LoopAsync(math.floor(SYNC_INTERVAL * 1000), function()
        if not SYNC_ENABLED then return true end  -- Return true to continue loop
        
        ExecuteInGameThread(function()
            -- Initialize if needed
            if not SyncInitialized then
                LocalPawn = GetLocalPawn()
                IsHost = CheckIfHost()
                if LocalPawn then
                    SyncInitialized = true
                    print(string.format("[PositionSync] Initialized. IsHost: %s", tostring(IsHost)))
                    IdentifyRemotePlayers()
                end
            end
            
            -- Update remote player tracking
            if SyncInitialized then
                -- Re-identify players periodically (in case new players join)
                if #RemotePlayers == 0 then
                    IdentifyRemotePlayers()
                end
                
                -- Update positions
                UpdateRemotePositions(SYNC_INTERVAL)
            end
        end)
        
        return true  -- Continue the loop
    end)
end

local function StopSyncLoop()
    SYNC_ENABLED = false
    SyncLoopRunning = false
    print("[PositionSync] Sync loop stopped.")
end

-- ============================================================================
-- Public API
-- ============================================================================

local PositionSync = {}

function PositionSync.Start()
    SYNC_ENABLED = true
    StartSyncLoop()
end

function PositionSync.Stop()
    StopSyncLoop()
end

function PositionSync.GetRemotePlayers()
    return RemotePlayers
end

function PositionSync.GetLocalPosition()
    return GetPawnPosition(LocalPawn)
end

function PositionSync.IsHost()
    return IsHost
end

function PositionSync.GetStatus()
    return {
        enabled = SYNC_ENABLED,
        initialized = SyncInitialized,
        isHost = IsHost,
        remotePlayers = #RemotePlayers,
        localPawn = LocalPawn and LocalPawn:IsValid()
    }
end

-- ============================================================================
-- Debug Output (F10 hotkey)
-- ============================================================================

RegisterKeyBind(Key.F10, function()
    ExecuteInGameThread(function()
        print("\n[PositionSync] Status Report:")
        local status = PositionSync.GetStatus()
        print(string.format("  Enabled: %s", tostring(status.enabled)))
        print(string.format("  Initialized: %s", tostring(status.initialized)))
        print(string.format("  IsHost: %s", tostring(status.isHost)))
        print(string.format("  Remote Players: %d", status.remotePlayers))
        print(string.format("  Local Pawn Valid: %s", tostring(status.localPawn)))
        
        local localPos = PositionSync.GetLocalPosition()
        if localPos then
            print(string.format("  Local Position: X=%.1f, Y=%.1f, Z=%.1f", localPos.X, localPos.Y, localPos.Z))
        end
        
        for i, remote in ipairs(RemotePlayers) do
            if remote.targetPosition then
                print(string.format("  Remote[%d]: X=%.1f, Y=%.1f, Z=%.1f", 
                    i, remote.targetPosition.X, remote.targetPosition.Y, remote.targetPosition.Z))
            end
        end
    end)
end)

-- ============================================================================
-- Auto-Start (Immediately)
-- ============================================================================

-- Start the sync loop immediately after a tiny delay for game init
LoopAsync(500, function()
    PositionSync.Start()
    return false  -- Don't repeat, just run once
end)

print("[PositionSync] Module loaded. Sync starts automatically. F10 for status.")

return PositionSync
