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

1.  Launch **Half Sword Demo** from Steam.
2.  The mod should load automatically (you might see a console window).
3.  [Add specific usage instructions here if applicable, e.g., "Press F10 to open menu" or "Edit server_ip.txt"]

## 📂 Files Included

*   `dwmapi.dll`: Mod loader (UE4SS).
*   `ue4ss/`: Mod configuration and scripts.
*   `install.ps1`: Automated installer script.

**Note**: Do NOT verify game files via Steam after installing, as it may remove mod files. If you do, just run the installer again.
