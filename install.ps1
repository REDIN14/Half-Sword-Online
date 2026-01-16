# Half-Sword-Online One-Click Installer
$ErrorActionPreference = "Stop"

function Pause-AndExit {
    param([int]$ExitCode = 0)
    Write-Host ""
    Write-Host "Press any key to close this window..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Exit $ExitCode
}

Write-Host "==========================================" -ForegroundColor Magenta
Write-Host "   Half-Sword-Online Installer Started    " -ForegroundColor Magenta
Write-Host "==========================================" -ForegroundColor Magenta
Write-Host ""

try {
    Write-Host "[INFO] Searching for Half Sword Demo installation..." -ForegroundColor Cyan

    # Function to find Steam Libraries
    function Get-SteamLibraries {
        $steamPath = Get-ItemProperty -Path "HKLM:\SOFTWARE\Wow6432Node\Valve\Steam" -Name "InstallPath" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty InstallPath
        if (-not $steamPath) { 
            Write-Host "[WARN] Steam InstallPath registry key not found." -ForegroundColor Yellow
            return @() 
        }
        
        $libraries = @("$steamPath\steamapps")
        $vdfPath = "$steamPath\steamapps\libraryfolders.vdf"
        if (Test-Path $vdfPath) {
            $content = Get-Content $vdfPath -Raw
            $matches = [regex]::Matches($content, '"path"\s+"(.*?)"')
            foreach ($match in $matches) {
                $libPath = $match.Groups[1].Value -replace '\\\\', '\'
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
        Write-Host "[WARN] Could not automatically find Half Sword Demo installation." -ForegroundColor Yellow
        Write-Host "Please check if the game is installed in the default Steam library locations."
        
        # Manual Fallback
        $gamePath = Read-Host "Please paste the full path to 'HalfSwordUE5\Binaries\Win64' manually"
        if (-not (Test-Path "$gamePath\HalfSwordUE5-Win64-Shipping.exe")) {
             Write-Host "[ERROR] Invalid path provided. Could not find game executable." -ForegroundColor Red
             Pause-AndExit 1
        }
    }

    Write-Host "[SUCCESS] Found Game Path: $gamePath" -ForegroundColor Green

    # Download Latest Code from Main Branch
    $repoOwner = "REDIN14"
    $repoName = "Half-Sword-Online"
    $downloadUrl = "https://github.com/$repoOwner/$repoName/archive/refs/heads/main.zip"

    Write-Host "[INFO] Downloading latest version from main branch..." -ForegroundColor Cyan
    
    $tempZip = "$env:TEMP\HalfSwordMod.zip"
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing
    } catch {
        Write-Host "[ERROR] Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Pause-AndExit 1
    }
    
    Write-Host "[INFO] Installing to $gamePath..." -ForegroundColor Cyan
    try {
        # Extract to temp folder first to check structure
        $extractPath = "$env:TEMP\HalfSwordMod_Extract"
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $tempZip -DestinationPath $extractPath -Force
        
        $extractedItems = Get-ChildItem -Path $extractPath
        
        # If the zip contains a single top-level folder (common in GitHub source zips), dive into it
        if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer) {
            $sourceDir = $extractedItems[0].FullName
            Write-Host "[INFO] Detected nested folder structure, flattening..." -ForegroundColor Cyan
            Copy-Item -Path "$sourceDir\*" -Destination $gamePath -Recurse -Force
        } else {
            # Standard flat zip
            Copy-Item -Path "$extractPath\*" -Destination $gamePath -Recurse -Force
        }

        # Clean up temp extract folder
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "[ERROR] Extraction failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Make sure the game is not running!"
        Pause-AndExit 1
    }
    
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    
    Write-Host ""
    Write-Host "[SUCCESS] Installation Complete!" -ForegroundColor Green
    Write-Host "You can now launch Half Sword Demo." -ForegroundColor Green
    Pause-AndExit 0

} catch {
    Write-Host ""
    Write-Host "[CRITICAL ERROR] An unexpected error occurred:" -ForegroundColor Red
    Write-Host $_.Exception.ToString() -ForegroundColor Red
    Pause-AndExit 1
}
