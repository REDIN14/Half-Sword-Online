-- UDP Position Sync Module for Half Sword MP
-- Version 9.3: MINIMAL - Does almost nothing to test if crashes are from game

print("[UDPSync] Loading v9.3 MINIMAL...")

local socket = require("socket")

-- ============================================================================
-- State
-- ============================================================================

local IsHost = false
local Initialized = false

-- ============================================================================
-- API (Does nothing, just logging)
-- ============================================================================

local UDPSync = {}

function UDPSync.StartAsHost()
    IsHost = true
    Initialized = true
    print("[UDPSync] HOST mode (minimal - no sync)")
end

function UDPSync.StartAsClient(ip)
    IsHost = false
    Initialized = true
    print("[UDPSync] CLIENT mode (minimal - no sync)")
    print("[UDPSync] Target: " .. tostring(ip))
end

function UDPSync.Stop()
    Initialized = false
    print("[UDPSync] Stopped")
end

RegisterKeyBind(Key.F11, function()
    print("[UDPSync] v9.3 MINIMAL - IsHost=" .. tostring(IsHost) .. " Init=" .. tostring(Initialized))
    print("[UDPSync] This version does NO syncing to test stability")
end)

print("[UDPSync] v9.3 MINIMAL loaded - press F11 for status")

return UDPSync
