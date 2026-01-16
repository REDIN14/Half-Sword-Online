-- Half Sword Multiplayer Mod v7.0 (UDP Sync)
-- ImGui Control Panel + LuaSocket UDP Position Sync

print("=== Half Sword Multiplayer Mod v7.0 (UDP Sync) ===")

-- Configuration
local ABYSS_MAP = "Abyss_Map_Open_Intermediate"
local PORT = 7777
local DEFAULT_IP_FILE = "ue4ss\\server_ip.txt"

-- Load UDP Sync Module (uses LuaSocket)
local UDPSync = nil
local udpLoadSuccess, udpErr = pcall(function()
    UDPSync = require("udp_sync")
end)
if udpLoadSuccess then
    print("[OK] UDP Sync module loaded!")
else
    print("[WARNING] UDP Sync module failed to load: " .. tostring(udpErr))
end

-- GUI State
local ShowMenu = true -- Start visible
local ServerIP = "127.0.0.1"
local GUITitle = "Half Sword Multiplayer Mod v7.0"
local StatusMessage = "Ready."
local CurrentHostIP = nil  -- Track host IP for clients

-- ==============================================================================
-- Network Logic
-- ==============================================================================

local function HostServer(mapName)
    StatusMessage = "Hosting " .. mapName .. "..."
    print(StatusMessage)
    
    ExecuteInGameThread(function()
        local PCs = FindAllOf("PlayerController")
        if PCs and #PCs > 0 then
            local PC = PCs[1]
            local URL = mapName .. "?listen?port=" .. tostring(PORT)
            
            print("ClientTravel(" .. URL .. ")...")
            
            local success, err = pcall(function()
                PC:ClientTravel(URL, 0, false, {}) 
            end)
            
            if success then
                StatusMessage = "Host Started. Loading..."
                print(StatusMessage)
                -- Start UDP sync as host
                if UDPSync then
                    LoopAsync(2000, function()
                        UDPSync.StartAsHost()
                        return false
                    end)
                end
            else
                StatusMessage = "Host Error: " .. tostring(err)
                print(StatusMessage)
            end
        else
            StatusMessage = "Error: No PlayerController found."
            print(StatusMessage)
        end
    end)
end

local function JoinGame(ip)
    StatusMessage = "Joining " .. ip .. "..."
    print(StatusMessage)
    CurrentHostIP = ip  -- Save host IP for UDP sync
    
    local URL = ip .. ":" .. tostring(PORT)
    ExecuteInGameThread(function()
        local PCs = FindAllOf("PlayerController")
        if PCs and #PCs > 0 then
            PCs[1]:ClientTravel(URL, 0, false, {})
            -- Start UDP sync as client
            if UDPSync then
                LoopAsync(2000, function()
                    UDPSync.StartAsClient(ip)
                    return false
                end)
            end
        end
    end)
end

local function Disconnect()
    StatusMessage = "Disconnecting..."
    print(StatusMessage)
    
     ExecuteInGameThread(function()
        local KismetLibrary = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local PCs = FindAllOf("PlayerController")
        if KismetLibrary and PCs and #PCs > 0 then
             KismetLibrary:ExecuteConsoleCommand(PCs[1], "disconnect", nil)
        end
    end)
end

-- ==============================================================================
-- IP File Reader (must be defined before keybinds)
-- ==============================================================================
local function ReadServerIP()
    local paths = { "ue4ss\\server_ip.txt", "ue4ss/server_ip.txt", "server_ip.txt" }
    for _, path in ipairs(paths) do
        local file = io.open(path, "r")
        if file then
            local ip = file:read("*l")
            file:close()
            if ip and ip ~= "" then
                return ip:match("^%s*(.-)%s*$")
            end
        end
    end
    return "127.0.0.1"
end

-- ==============================================================================
-- GUI Logic (ImGui)
-- ==============================================================================

-- Wrapped Keybind Registration
local function SafeRegisterKeyBind(key, callback)
    local success, err = pcall(function()
        RegisterKeyBind(key, callback)
    end)
    if not success then
        print("Failed to register keybind: " .. tostring(err))
    end
end
SafeRegisterKeyBind(Key.F1, function()
    ShowMenu = not ShowMenu
    print("Menu Toggled: " .. tostring(ShowMenu))
end)

SafeRegisterKeyBind(Key.F5, function()
    HostServer(ABYSS_MAP)
end)

SafeRegisterKeyBind(Key.F8, function()
    -- Re-read IP from file every time F8 is pressed
    ServerIP = ReadServerIP()
    print("F8 Pressed. Current IP from file: " .. ServerIP)
    JoinGame(ServerIP)
end)

SafeRegisterKeyBind(Key.F7, function()
    Disconnect()
end)

local hasPrintedDraw = false
function OnDrawGui()
    if not hasPrintedDraw then
        print("OnDrawGui is ticking!")
        hasPrintedDraw = true
    end

    if not ShowMenu then return end

    -- Main Window
    if ImGui.Begin(GUITitle, true) then
        
        ImGui.Text("Status: " .. StatusMessage)
        ImGui.Separator()
        
        -- HOST SECTION
        ImGui.Text("Host Game")
        if ImGui.Button("Host Abyss (Multiplayer)") then
            HostServer(ABYSS_MAP)
        end
        
        ImGui.Separator()
        
        -- JOIN SECTION
        ImGui.Text("Join Game")
        local changed, newIP = ImGui.InputText("IP Address", ServerIP, 32)
        if changed then ServerIP = newIP end
        
        if ImGui.Button("Join " .. ServerIP) then
            JoinGame(ServerIP)
        end
        
        ImGui.Separator()
        
        -- UTILS
        if ImGui.Button("Disconnect") then
            Disconnect()
        end
        
        ImGui.Separator()
        ImGui.Text("Press INSERT to Toggle Menu")
        
        ImGui.End() 
    end
end

-- Load IP on startup
ServerIP = ReadServerIP()
print("Mod Loaded v7.0. Hotkeys: F1=Menu, F5=Host, F8=Join, F7=Disconnect, F11=UDP Status")
