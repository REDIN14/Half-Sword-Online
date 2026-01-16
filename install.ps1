# Half-Sword-Online One-Click Installer
$ErrorActionPreference = "Stop"

Write-Host "Searching for Half Sword Demo installation..." -ForegroundColor Cyan

# Function to find Steam Libraries
function Get-SteamLibraries {
    $steamPath = Get-ItemProperty -Path "HKLM:\SOFTWARE\Wow6432Node\Valve\Steam" -Name "InstallPath" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InstallPath
    if (-not $steamPath) { return @() }
    
    $libraries = @("$steamPath\steamapps")
    $vdfPath = "$steamPath\steamapps\libraryfolders.vdf"
    
    if (Test-Path $vdfPath) {
        $content = Get-Content $vdfPath -Raw
        # Simple regex to find paths in VDF (paths are quoted)
        $matches = [regex]::Matches($content, '"path"\s+"(.*?)"')
        foreach ($match in $matches) {
            $libPath = $match.Groups[1].Value
            # Fix escaped backslashes if any
            $libPath = $libPath -replace '\\\\', '\'
            $libraries += "$libPath\steamapps"
        }
    }
    return $libraries
}

# Find Game Directory
$libraries = Get-SteamLibraries
$gamePath = $null
$possiblePaths = @(
    "common\Half Sword Demo\HalfSwordUE5\Binaries\Win64",
    "common\Half Sword Demo" 
)

foreach ($lib in $libraries) {
    foreach ($sub in $possiblePaths) {
        $checkPath = Join-Path $lib $sub
        if (Test-Path "$checkPath\HalfSwordUE5-Win64-Shipping.exe") {
            # We found the binary folder directly or the root (adjust to binary)
            if ($checkPath -match "Win64$") {
                $gamePath = $checkPath
            } else {
                $gamePath = "$checkPath\HalfSwordUE5\Binaries\Win64"
            }
            break
        }
    }
    if ($gamePath) { break }
}

if (-not $gamePath) {
    Write-Host "Could not automatically find Half Sword Demo installation." -ForegroundColor Red
    Write-Host "Please ensure the game is installed."
    Exit 1
}

Write-Host "Found Game Path: $gamePath" -ForegroundColor Green

# Download Latest Release
$repoOwner = "REDIN14"
$repoName = "Half-Sword-Online"
$apiUrl = "https://api.github.com/repos/$repoOwner/$repoName/releases/latest"

Write-Host "Fetching latest release info..." -ForegroundColor Cyan
try {
    $release = Invoke-RestMethod -Uri $apiUrl -Method Get
    $assets = $release.assets
    # Look for a zip file
    $zipAsset = $assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
    
    if (-not $zipAsset) {
        Write-Host "No zip asset found in the latest release!" -ForegroundColor Red
        Exit 1
    }
    
    $downloadUrl = $zipAsset.browser_download_url
    Write-Host "Downloading $($zipAsset.name)..." -ForegroundColor Cyan
    
    $tempZip = "$env:TEMP\HalfSwordMod.zip"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip
    
    Write-Host "Installing to $gamePath..." -ForegroundColor Cyan
    Expand-Archive -Path $tempZip -DestinationPath $gamePath -Force
    
    Remove-Item $tempZip -Force
    
    Write-Host ""
    Write-Host "Installation Complete!" -ForegroundColor Green
    Write-Host "You can now launch Half Sword Demo." -ForegroundColor Green
}
catch {
    Write-Host "Error fetching or downloading release: $_" -ForegroundColor Red
    Write-Host "Make sure a Release exists on the GitHub repository." -ForegroundColor Yellow
    Exit 1
}
