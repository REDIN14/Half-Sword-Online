-- UDP Position Sync Module for Half Sword MP
-- Version 13.0: DISABLED - Testing Native UE5 Replication
-- All position/rotation sync disabled to test what UE5 provides natively

print("[UDPSync] Loading v13.0 NATIVE TEST MODE...")
print("[UDPSync] Custom sync DISABLED - relying on UE5 native networking")

local socket = require("socket")
local UEHelpers = require("UEHelpers")

-- ============================================================================
-- State (for monitoring only)
-- ============================================================================

local IsHost = false
local Initialized = false
local TickCount = 0
local DebugMode = false

-- ============================================================================
-- Helpers
-- ============================================================================

local function SafeGet(fn)
    local ok, result = pcall(fn)
    return ok and result or nil
end

local function GetMyPawn()
    local pc = SafeGet(function() return UEHelpers.GetPlayerController() end)
    if not pc then return nil end
    return SafeGet(function() return pc.Pawn end)
end

local function CountPlayerPawns()
    local allPawns = SafeGet(function() return FindAllOf("Pawn") end)
    if not allPawns then return 0, 0 end
    
    local total = 0
    local playerControlled = 0
    for _, p in ipairs(allPawns) do
        if SafeGet(function() return p:IsValid() end) then
            total = total + 1
            if SafeGet(function() return p:IsPlayerControlled() end) then
                playerControlled = playerControlled + 1
            end
        end
    end
    return total, playerControlled
end

-- ============================================================================
-- Start/Stop (No actual sync, just monitoring)
-- ============================================================================

local function StartSync(hostIP)
    if Initialized then return end
    
    IsHost = (hostIP == nil or hostIP == "")
    Initialized = true
    TickCount = 0
    
    print("[UDPSync] " .. (IsHost and "HOST" or "CLIENT") .. " - NATIVE MODE")
    print("[UDPSync] No custom sync active - UE5 handles everything")
    
    -- Just monitor pawn count every 2 seconds
    LoopAsync(2000, function()
        if not Initialized then return true end
        TickCount = TickCount + 1
        
        if DebugMode then
            ExecuteInGameThread(function()
                local total, players = CountPlayerPawns()
                print("[UDPSync] Tick " .. TickCount .. " | Pawns: " .. total .. " | Players: " .. players)
            end)
        end
        
        return true
    end)
    
    print("[UDPSync] v13.0 Native Test Started")
end

local function StopSync()
    Initialized = false
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
    print("=== UDPSync v13.0 NATIVE TEST ===")
    print("Debug: " .. tostring(DebugMode))
    print("Mode: " .. (IsHost and "HOST" or "CLIENT"))
    print("Custom Sync: DISABLED")
    print("UE5 Native: ACTIVE")
    
    ExecuteInGameThread(function()
        local total, players = CountPlayerPawns()
        print("Pawns: " .. total .. " | PlayerControlled: " .. players)
        
        local myPawn = GetMyPawn()
        if myPawn then
            local loc = SafeGet(function() return myPawn:GetActorLocation() end)
            if loc then
                print("MyPos: " .. string.format("%.0f, %.0f, %.0f", loc.X, loc.Y, loc.Z))
            end
        end
    end)
    print("================================")
end)

print("[UDPSync] v13.0 loaded - F11 for status")

return UDPSync
