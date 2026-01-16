-- Half Sword Multiplayer Mod v5.0 (GUI)
-- ImGui Control Panel

print("=== Half Sword Multiplayer Mod v5.0 (GUI) ===")

-- Configuration
local ABYSS_MAP = "Abyss_Map_Open_Intermediate"
local PORT = 7777
local DEFAULT_IP_FILE = "ue4ss\\server_ip.txt"

-- GUI State
local ShowMenu = true -- Start visible
local ServerIP = "127.0.0.1"
local GUITitle = "Half Sword Multiplayer Mod"
local StatusMessage = "Ready."

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
    
    local URL = ip .. ":" .. tostring(PORT)
    ExecuteInGameThread(function()
        local PCs = FindAllOf("PlayerController")
        if PCs and #PCs > 0 then
            PCs[1]:ClientTravel(URL, 0, false, {})
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

-- ==============================================================================
-- Auto-Load IP on Start
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

ServerIP = ReadServerIP()
print("Mod Loaded v5.2. Hotkeys: F1=Menu, F5=Host Abyss, F8=Join IP, F7=Disconnect")
