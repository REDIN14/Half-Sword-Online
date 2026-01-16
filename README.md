# Half Sword Online

**Half Sword Online** is a multiplayer mod for the Half Sword Demo, enabling you to play with friends over the internet using UE4SS.

## 🚀 Easy Installation

You can install the mod automatically using a single PowerShell command.

1.  Open **Windows PowerShell**.
2.  Paste the following command and press **Enter**:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/REDIN14/Half-Sword-Online/main/install.ps1) }"
```

This installer will:
*   Automatically find your Half Sword Demo installation.
*   Download the latest version of the mod (UE4SS + Config).
*   Install the files to the correct directory.

## 🛠️ Manual Installation

1.  Download the **Latest Release** zip file from the [Releases Page](../../releases).
2.  Extract the contents ( `ue4ss/`, `dwmapi.dll`, etc.) into your game's binary folder:
    *   `.../Steam/steamapps/common/Half Sword Demo/HalfSwordUE5/Binaries/Win64/`
3.  Launch the game.

## 🚀 How to Play (New GUI Launcher)
We now have a modern interface to make connecting easy!

1.  Run `Launcher.ps1` (Right-click -> Run with PowerShell).
2.  **To Host**:
    *   Click the green **LAUNCH AS HOST** button.
    *   Share the "Your Local IP" displayed on screen with your friend.
    *   In game: Press **F5**.
3.  **To Join**:
    *   Paste your friend's IP into the box.
    *   Click the blue **JOIN GAME** button.
    *   In game: Press **F8**.

*(Note: You can still use the F1 in-game menu if you prefer, but the Launcher handles the config for you!)*

### Default Controls
*   **F1 / Insert**: Toggle Mod Menu
*   **F5**: Host Server
*   **F8**: Join Server
*   **F7**: Disconnect
*   **F9**: Network Diagnostics
*   **F10**: Position Sync Status

### v6.0 Features
*   Automatic position sync with interpolation
*   Network diagnostics tool
*   Smart IP detection in Launcher

## 📂 Files Included

*   `Launcher.ps1`: **The new Mod Launcher App.**
*   `dwmapi.dll`: Mod loader (UE4SS).
*   `ue4ss/`: Mod configuration and scripts.
*   `install.ps1`: Automated installer script.

Example:
If you are HOSTING (The Server)
You do NOT need to type anything in 
server_ip.txt
.
You just press F5 (Host) in the game.
Your job is to find your IP (which you did: 192.168.178.28) and tell it to your friend.
The Person JOINING You (The Client)
THEY need to open their 
server_ip.txt
.
THEY must type YOUR IP (192.168.178.28) into that file.
Then THEY press F8 (Join).




**Important**: Do NOT verify game files via Steam after installing, as it may remove mod files. If you do, just run the installer again.
