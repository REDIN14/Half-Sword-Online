<#
.SYNOPSIS
    Half-Sword-Online Modern Launcher
    Premium GUI for Hosting and Joining Games.
#>

# Self-Elevation (Run as Admin)
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Hide PowerShell Console Window
Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("Kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
[DllImport("User32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'
$consolePtr = [Console.Window]::GetConsoleWindow()
[Console.Window]::ShowWindow($consolePtr, 0) | Out-Null

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Drawing

# --- Configuration (Use Script's Directory as Base) ---
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    # Fallback for when run via iex or other methods
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if (-not $ScriptDir) {
    # Last resort: use current directory
    $ScriptDir = Get-Location
}

$GameExe = Join-Path $ScriptDir "HalfSwordUE5-Win64-Shipping.exe"
$IpFile = Join-Path $ScriptDir "ue4ss\server_ip.txt"
$IpDir = Join-Path $ScriptDir "ue4ss"

# --- Logic Functions ---

function Get-LocalIP {
    try {
        # Get all IPv4 addresses, filter out loopback, virtual, and APIPA (169.254.x.x)
        $ip = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
            $_.InterfaceAlias -notlike "*Loopback*" -and 
            $_.InterfaceAlias -notlike "*vEthernet*" -and
            $_.InterfaceAlias -notlike "*Bluetooth*" -and
            $_.IPAddress -notlike "127.*" -and
            $_.IPAddress -notlike "169.254.*"  # Exclude APIPA addresses
        } | Select-Object -ExpandProperty IPAddress -First 1
        
        if ($ip) { return $ip }
        return "Check ipconfig"
    } catch {
        return "Unknown"
    }
}

function Launch-Game {
    if (Test-Path $GameExe) {
        Start-Process $GameExe
        $WPFWindow.Close()
    } else {
        [System.Windows.MessageBox]::Show("Could not find '$GameExe'. Make sure Launcher.ps1 is in the Binaries/Win64 folder.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
}

function Set-ClientIP {
    param($ip)
    # Ensure directory exists (use absolute path)
    if (-not (Test-Path $IpDir)) { New-Item -ItemType Directory -Path $IpDir -Force | Out-Null }
    
    # Write to file
    $ip | Out-File -FilePath $IpFile -Encoding ascii -Force
}

function Clean-Config {
    # Ensure server_ip.txt is proper for hosting (localhost or empty is fine, but cleaner to leave it or set to self)
    # Actually, for host, the file content doesn't matter much as they are the server, but best to set 127.0.0.1 so they don't try to connect to random IP
    Set-ClientIP "127.0.0.1"
}

function Setup-Firewall {
    # Check if firewall rules already exist
    $rule1 = Get-NetFirewallRule -DisplayName "Half Sword Online UDP 7778" -ErrorAction SilentlyContinue
    $rule2 = Get-NetFirewallRule -DisplayName "Half Sword Online UDP 7779" -ErrorAction SilentlyContinue
    
    if ($rule1 -and $rule2) {
        return  # Already configured
    }
    
    # Try to add firewall rules (requires admin)
    try {
        if (-not $rule1) {
            New-NetFirewallRule -DisplayName "Half Sword Online UDP 7778" -Direction Inbound -Protocol UDP -LocalPort 7778 -Action Allow -Profile Private,Domain -ErrorAction Stop | Out-Null
        }
        if (-not $rule2) {
            New-NetFirewallRule -DisplayName "Half Sword Online UDP 7779" -Direction Inbound -Protocol UDP -LocalPort 7779 -Action Allow -Profile Private,Domain -ErrorAction Stop | Out-Null
        }
        # Also add game executable rule
        $gamePath = Join-Path $ScriptDir "HalfSwordUE5-Win64-Shipping.exe"
        $gameRule = Get-NetFirewallRule -DisplayName "Half Sword Online Game" -ErrorAction SilentlyContinue
        if (-not $gameRule -and (Test-Path $gamePath)) {
            New-NetFirewallRule -DisplayName "Half Sword Online Game" -Direction Inbound -Program $gamePath -Action Allow -Profile Private,Domain -ErrorAction Stop | Out-Null
        }
    } catch {
        # If we can't add rules (not admin), show a message
        [System.Windows.MessageBox]::Show("Could not configure firewall automatically. For best multiplayer experience, run Setup-Firewall.ps1 as Administrator.", "Firewall Notice", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
}

# Auto-setup firewall on launch
Setup-Firewall

# --- XAML UI Definition ---
[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Half Sword Online" Height="450" Width="800"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#121212">
    
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#333333"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="5">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#505050"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#252525"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#444"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <Style TargetType="TextBlock">
            <Setter Property="FontFamily" Value="Segoe UI"/>
            <Setter Property="Foreground" Value="#EEEEEE"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="60"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="40"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Background="#1F1F1F">
            <TextBlock Text="HALF SWORD ONLINE"  FontSize="24" FontWeight="Bold" 
                       HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#E0E0E0"/>
        </Border>

        <!-- Main Content (Tabs simulated) -->
        <Grid Grid.Row="1" Margin="20">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- HOST PANEL -->
            <Border Grid.Column="0" Background="#1E1E1E" Margin="10" CornerRadius="10" BorderBrush="#333" BorderThickness="1">
                <StackPanel Margin="20" VerticalAlignment="Center">
                    <TextBlock Text="HOST GAME" FontSize="20" FontWeight="Bold" Foreground="#4CAF50" HorizontalAlignment="Center"/>
                    <TextBlock Text="Be the Server" FontSize="12" Foreground="#888" HorizontalAlignment="Center" Margin="0,5,0,20"/>

                    <TextBlock Text="Your Local IP:" FontSize="14" Foreground="#AAA" HorizontalAlignment="Center"/>
                    <TextBox x:Name="TxtHostIP" Text="Loading..." FontSize="18" FontWeight="Bold" 
                             HorizontalAlignment="Center" TextAlignment="Center" Width="200" Margin="0,5,0,0" IsReadOnly="True" Background="Transparent" BorderThickness="0"/>

                    <TextBlock Text="Share this IP with your friends." FontSize="11" Foreground="#666" HorizontalAlignment="Center" Margin="0,5,0,20"/>

                    <Button x:Name="BtnHost" Content="LAUNCH AS HOST" Height="50" Background="#2E7D32" FontSize="16" Margin="0,10,0,0"/>
                </StackPanel>
            </Border>

            <!-- CLIENT PANEL -->
            <Border Grid.Column="1" Background="#1E1E1E" Margin="10" CornerRadius="10" BorderBrush="#333" BorderThickness="1">
                <StackPanel Margin="20" VerticalAlignment="Center">
                    <TextBlock Text="JOIN GAME" FontSize="20" FontWeight="Bold" Foreground="#2196F3" HorizontalAlignment="Center"/>
                    <TextBlock Text="Connect to a Friend" FontSize="12" Foreground="#888" HorizontalAlignment="Center" Margin="0,5,0,20"/>

                    <TextBlock Text="Enter Host IP:" FontSize="14" Foreground="#AAA" HorizontalAlignment="Center"/>
                    <TextBox x:Name="TxtJoinIP" Text="" FontSize="16" Width="200" Margin="0,5,0,20" TextAlignment="Center"/>

                    <Button x:Name="BtnJoin" Content="JOIN GAME" Height="50" Background="#1565C0" FontSize="16" Margin="0,10,0,0"/>
                </StackPanel>
            </Border>
        </Grid>

        <!-- Footer -->
        <Border Grid.Row="2" Background="#111">
             <TextBlock x:Name="TxtStatus" Text="Made by Redin." Foreground="#666" VerticalAlignment="Center" Margin="15,0"/>
        </Border>
    </Grid>
</Window>
"@

# --- Load XAML ---
$Reader = (New-Object System.Xml.XmlNodeReader $XAML)
$WPFWindow = [Windows.Markup.XamlReader]::Load($Reader)

# --- Find Controls ---
$BtnHost = $WPFWindow.FindName("BtnHost")
$BtnJoin = $WPFWindow.FindName("BtnJoin")
$TxtHostIP = $WPFWindow.FindName("TxtHostIP")
$TxtJoinIP = $WPFWindow.FindName("TxtJoinIP")
$TxtStatus = $WPFWindow.FindName("TxtStatus")

# --- Initialize Data ---
$MyIP = Get-LocalIP
$TxtHostIP.Text = $MyIP

# Check if server_ip.txt exists and pre-fill join IP (if not localhost)
if (Test-Path $IpFile) {
    $CurrentIP = Get-Content $IpFile -Raw -ErrorAction SilentlyContinue
    if ($CurrentIP -and $CurrentIP.Trim() -ne "" -and $CurrentIP.Trim() -ne "127.0.0.1") {
        $TxtJoinIP.Text = $CurrentIP.Trim()
    }
}

# --- Event Handlers ---

$BtnHost.Add_Click({
    $TxtStatus.Text = "Configuring for Host..."
    try {
        Clean-Config # Reset IP to localhost or similar to avoid client logic interference
        [System.Windows.MessageBox]::Show("Game will launch.\n\n1. Wait for game to load.\n2. Press F5 to Start Server.", "Host Instructions", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        Launch-Game
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

$BtnJoin.Add_Click({
    $TargetIP = $TxtJoinIP.Text.Trim()
    
    # Validation: Empty
    if ($TargetIP -eq "") {
        [System.Windows.MessageBox]::Show("Please enter the Host's IP Address.", "Input Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    
    # Validation: Localhost (common mistake)
    if ($TargetIP -eq "127.0.0.1" -or $TargetIP -eq "localhost") {
        [System.Windows.MessageBox]::Show("You entered '127.0.0.1' (localhost).`n`nThis means you're trying to connect to YOURSELF.`n`nPlease enter your FRIEND's IP address instead!", "Invalid IP", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        return
    }
    
    # Validation: Basic IP format (X.X.X.X)
    if ($TargetIP -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        [System.Windows.MessageBox]::Show("The IP address format looks wrong.`n`nIt should look like: 192.168.1.50", "Invalid Format", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $TxtStatus.Text = "Configuring Client to Join $TargetIP..."
    try {
        Set-ClientIP $TargetIP
         [System.Windows.MessageBox]::Show("Config Saved! Game will launch.`n`n1. Wait for game to load.`n2. Press F8 to Join.", "Join Instructions", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        Launch-Game
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
})

# --- Show Window ---
$WPFWindow.ShowDialog() | Out-Null
