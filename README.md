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

## 🎮 How to Play

### Setup for HOST (Main PC)
1.  Launch **Half Sword Demo**.
2.  Press **F5** to Host the Abyss map.
    *   *Alternative*: Press **F1** (or Insert) to open the menu -> Click **Host Abyss**.
3.  Wait until you spawn.
4.  Find your **Local IPv4 Address** (Open Command Prompt, type `ipconfig`, look for IPv4, e.g., `192.168.1.5`).
5.  Send this IP to your friends.

### Setup for CLIENT (Joining PC)
**Method 1: Menu (Recommended)**
1.  Launch **Half Sword Demo**.
2.  Press **F1** (or Insert) to open the mod menu.
3.  In the **IP Address** box, replace `127.0.0.1` with the **Host's IP**.
4.  Click **Join [IP]** or press **F8**.

**Method 2: Config File**
1.  Go to your game folder: `.../Binaries/Win64/ue4ss/`.
2.  Open `server_ip.txt`.
3.  Replace `127.0.0.1` with the Host's IP Address.
4.  Save and Close.
5.  Launch the game and press **F8**.

### Default Controls
*   **F1 / Insert**: Toggle Mod Menu
*   **F5**: Host Server
*   **F8**: Join Server
*   **F7**: Disconnect

## 📂 Files Included

*   `dwmapi.dll`: Mod loader (UE4SS).
*   `ue4ss/`: Mod configuration and scripts.
*   `install.ps1`: Automated installer script.

**Important**: Do NOT verify game files via Steam after installing, as it may remove mod files. If you do, just run the installer again.
