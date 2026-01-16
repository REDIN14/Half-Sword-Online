# Half Sword Online - Firewall Setup Script
# Run as Administrator to add UDP firewall rules for multiplayer sync

Write-Host "=== Half Sword Online Firewall Setup ===" -ForegroundColor Cyan
Write-Host ""

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (-not $isAdmin) {
    Write-Host "[ERROR] This script must be run as Administrator!" -ForegroundColor Red
    Write-Host "Right-click the script and select 'Run as Administrator'" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "[*] Adding firewall rules for Half Sword Online..." -ForegroundColor Green

# Remove old rules if they exist
Remove-NetFirewallRule -DisplayName "Half Sword Online UDP 7778" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Half Sword Online UDP 7779" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Half Sword Online Game" -ErrorAction SilentlyContinue

# Add UDP port rules
try {
    New-NetFirewallRule -DisplayName "Half Sword Online UDP 7778" -Direction Inbound -Protocol UDP -LocalPort 7778 -Action Allow -Profile Private,Domain | Out-Null
    Write-Host "[OK] UDP 7778 (Host Broadcast) opened" -ForegroundColor Green
    
    New-NetFirewallRule -DisplayName "Half Sword Online UDP 7779" -Direction Inbound -Protocol UDP -LocalPort 7779 -Action Allow -Profile Private,Domain | Out-Null
    Write-Host "[OK] UDP 7779 (Client Send) opened" -ForegroundColor Green
    
    # Also allow the game executable
    $gamePath = "$PSScriptRoot\HalfSwordUE5-Win64-Shipping.exe"
    if (Test-Path $gamePath) {
        New-NetFirewallRule -DisplayName "Half Sword Online Game" -Direction Inbound -Program $gamePath -Action Allow -Profile Private,Domain | Out-Null
        Write-Host "[OK] Game executable allowed" -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "=== Firewall setup complete! ===" -ForegroundColor Cyan
    Write-Host "Run this script on BOTH computers." -ForegroundColor Yellow
    
} catch {
    Write-Host "[ERROR] Failed to add firewall rules: $_" -ForegroundColor Red
}

Write-Host ""
Read-Host "Press Enter to close"
