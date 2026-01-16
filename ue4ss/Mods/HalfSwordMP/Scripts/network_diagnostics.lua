-- Network Diagnostic Script for Half Sword MP
-- This script explores the game's network actors and replication capabilities
-- Run this while connected in multiplayer to see what's available

print("=== Half Sword Network Diagnostics ===")

local UEHelpers = require("UEHelpers")

-- ============================================================================
-- DIAGNOSTIC: Find all network-related actors
-- ============================================================================

local function DiagnoseNetworkActors()
    print("\n--- Searching for Network Actors ---")
    
    -- Common network actor types
    local actorTypes = {
        "PlayerState",
        "GameState", 
        "GameMode",
        "PlayerController",
        "Character",
        "Pawn",
        "ReplicationInfo"
    }
    
    for _, actorType in ipairs(actorTypes) do
        local actors = FindAllOf(actorType)
        if actors then
            print(string.format("[FOUND] %s: %d instances", actorType, #actors))
            for i, actor in ipairs(actors) do
                if actor:IsValid() then
                    local name = actor:GetFullName()
                    print(string.format("  [%d] %s", i, name))
                end
            end
        else
            print(string.format("[NOT FOUND] %s", actorType))
        end
    end
end

-- ============================================================================
-- DIAGNOSTIC: Get player positions
-- ============================================================================

local function DiagnosePlayerPositions()
    print("\n--- Player Positions ---")
    
    -- Try to find all pawns/characters
    local pawns = FindAllOf("Character") or FindAllOf("Pawn")
    if pawns then
        print(string.format("Found %d pawns/characters", #pawns))
        for i, pawn in ipairs(pawns) do
            if pawn:IsValid() then
                local success, loc = pcall(function()
                    return pawn:GetActorLocation()
                end)
                if success and loc then
                    print(string.format("  Pawn[%d]: X=%.1f, Y=%.1f, Z=%.1f", i, loc.X, loc.Y, loc.Z))
                else
                    print(string.format("  Pawn[%d]: Could not get location", i))
                end
            end
        end
    else
        print("No pawns found")
    end
end

-- ============================================================================
-- DIAGNOSTIC: Check PlayerState for replication
-- ============================================================================

local function DiagnosePlayerState()
    print("\n--- PlayerState Analysis ---")
    
    local playerStates = FindAllOf("PlayerState")
    if playerStates and #playerStates > 0 then
        print(string.format("Found %d PlayerState(s)", #playerStates))
        for i, ps in ipairs(playerStates) do
            if ps:IsValid() then
                print(string.format("  PlayerState[%d]:", i))
                
                -- Try to access common replicated properties
                local props = {"PlayerName", "PlayerId", "bIsSpectator", "bOnlySpectator"}
                for _, prop in ipairs(props) do
                    local success, val = pcall(function() return ps[prop] end)
                    if success and val then
                        print(string.format("    %s = %s", prop, tostring(val)))
                    end
                end
                
                -- Check if pawn is accessible
                local success, pawn = pcall(function() return ps.PawnPrivate or ps.Pawn end)
                if success and pawn and pawn:IsValid() then
                    print(string.format("    Has Pawn: YES"))
                else
                    print(string.format("    Has Pawn: NO"))
                end
            end
        end
    else
        print("No PlayerState found")
    end
end

-- ============================================================================
-- DIAGNOSTIC: Check GameState for shared data
-- ============================================================================

local function DiagnoseGameState()
    print("\n--- GameState Analysis ---")
    
    local gameStates = FindAllOf("GameState") or FindAllOf("GameStateBase")
    if gameStates and #gameStates > 0 then
        print(string.format("Found %d GameState(s)", #gameStates))
        for i, gs in ipairs(gameStates) do
            if gs:IsValid() then
                print(string.format("  GameState[%d]: %s", i, gs:GetFullName()))
                
                -- Check for player array
                local success, playerArray = pcall(function() return gs.PlayerArray end)
                if success and playerArray then
                    print(string.format("    PlayerArray exists, checking..."))
                end
            end
        end
    else
        print("No GameState found")
    end
end

-- ============================================================================
-- DIAGNOSTIC: Network Role Check
-- ============================================================================

local function DiagnoseNetworkRole()
    print("\n--- Network Role ---")
    
    local pc = UEHelpers.GetPlayerController()
    if pc and pc:IsValid() then
        -- Try to get network role
        local success, role = pcall(function() return pc:GetLocalRole() end)
        if success then
            print(string.format("Local Role: %s", tostring(role)))
        end
        
        -- Check if we're the server
        local success2, isServer = pcall(function() return pc:HasAuthority() end)
        if success2 then
            print(string.format("Has Authority (is Server): %s", tostring(isServer)))
        end
    end
end

-- ============================================================================
-- RUN ALL DIAGNOSTICS
-- ============================================================================

local function RunAllDiagnostics()
    DiagnoseNetworkActors()
    DiagnosePlayerPositions()
    DiagnosePlayerState()
    DiagnoseGameState()
    DiagnoseNetworkRole()
    print("\n=== Diagnostics Complete ===")
    print("Check the output above to see what network features are available.")
end

-- Register hotkey to run diagnostics
RegisterKeyBind(Key.F9, function()
    print("\n[F9] Running Network Diagnostics...")
    ExecuteInGameThread(function()
        RunAllDiagnostics()
    end)
end)

print("Network Diagnostics Loaded. Press F9 while in-game to run diagnostics.")
