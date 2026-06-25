# Invoke-AutopilotSetup.ps1
# Autopilot deployment tool for Microsoft 365 Business Premium environments.
#
# Run from an elevated PowerShell prompt:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -CollectHash
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -CollectHash

param(
    [switch]$PrepUSB,
    [switch]$CollectHash,
    [string]$DriveLetter,
    [string]$OutputPath
)

# ── Execution policy ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Autopilot Setup Tool" -ForegroundColor Cyan
Write-Host "  Microsoft 365 Business Premium" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "[Setup] Setting execution policy to RemoteSigned (CurrentUser)..." -ForegroundColor DarkGray

try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop
    Write-Host "[Setup] Execution policy set." -ForegroundColor DarkGray
} catch {
    Write-Host "[Setup] WARNING: Could not set execution policy: $_" -ForegroundColor Yellow
    Write-Host "[Setup] Script installation from PSGallery may fail. Try running as Administrator." -ForegroundColor Yellow
}

Write-Host ""

# ── Show help if no flags ──────────────────────────────────────────────────────

if (-not $PrepUSB -and -not $CollectHash) {
    Write-Host "No action specified. Available flags:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  -CollectHash       Collect Autopilot hardware hash, saves to USB (or desktop if no USB)" -ForegroundColor White
    Write-Host "  -PrepUSB           Inject ei.cfg into a Windows 11 USB to force Pro edition install" -ForegroundColor White
    Write-Host "  -DriveLetter X     Force a specific drive letter for -PrepUSB  (e.g. -DriveLetter E)" -ForegroundColor White
    Write-Host "  -OutputPath path   Override the hash CSV save location" -ForegroundColor White
    Write-Host ""
    Write-Host "Copy and run one of these commands:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Collect hash (insert a separate USB first, auto-detects it):" -ForegroundColor DarkGray
    Write-Host "  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -CollectHash" -ForegroundColor White
    Write-Host ""
    Write-Host "  Prep a Windows 11 USB for Pro install (auto-detects CPU, injects VMD driver if needed):" -ForegroundColor DarkGray
    Write-Host "  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB" -ForegroundColor White
    Write-Host ""
    Write-Host "  Prep USB on drive E specifically:" -ForegroundColor DarkGray
    Write-Host "  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -DriveLetter E" -ForegroundColor White
    Write-Host ""
    Write-Host "  Do both in one shot:" -ForegroundColor DarkGray
    Write-Host "  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -CollectHash" -ForegroundColor White
    Write-Host ""
    exit 0
}

# ── Shared helpers ─────────────────────────────────────────────────────────────

function Test-IsWindows11USB {
    param([string]$Root)
    # boot.wim is always present on any Windows install USB (MCT or Rufus).
    # install.wim / install.esd may be absent on MCT-created ESD-USB drives.
    return (Test-Path "${Root}sources\boot.wim") -or
           (Test-Path "${Root}sources\install.wim") -or
           (Test-Path "${Root}sources\install.esd")
}

function Find-DataUSB {
    # Returns the first non-system drive that is NOT a Windows 11 install USB.
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Root -ne ($env:SystemDrive + "\") -and
        -not (Test-IsWindows11USB -Root $_.Root)
    }
    if ($drives) { return @($drives)[0].Root }
    return $null
}

function Find-Windows11USB {
    # Returns the first drive that looks like a Windows install USB.
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Root -ne ($env:SystemDrive + "\") -and
        (Test-IsWindows11USB -Root $_.Root)
    }
    if ($drives) { return @($drives)[0] }
    return $null
}

# ── VMD detection helpers ──────────────────────────────────────────────────────

function Get-CPUVMDStatus {
    param([string]$CpuName)

    # AMD / Qualcomm / ARM — no VMD controller present
    if ($CpuName -match '(AMD|Ryzen|EPYC|Qualcomm|Snapdragon)') {
        return @{ NeedsVMD = $false; Reason = "AMD/Qualcomm CPU detected — VMD not applicable, skipping" }
    }

    if ($CpuName -notmatch 'Intel') {
        return @{ NeedsVMD = $false; Reason = "Non-Intel CPU detected — skipping VMD check" }
    }

    # Intel Core Ultra series (Meteor Lake / Lunar Lake / Arrow Lake)
    # Naming pattern: "Intel(R) Core(TM) Ultra 5 125H"
    #   100-series = Series 1 (Meteor Lake)   → VMD required
    #   200-series = Series 2 (Lunar Lake / Arrow Lake) → VMD required
    #   300-series = Series 3 (per spec: no VMD)
    if ($CpuName -match 'Core\s*\(TM\)\s*Ultra\s+\d+\s+(\d{3})') {
        $series = [math]::Floor([int]$Matches[1] / 100)
        if ($series -ge 3) {
            return @{ NeedsVMD = $false; Reason = "Intel Core Ultra Series $series detected — VMD not required" }
        }
        return @{ NeedsVMD = $true; Reason = "Intel Core Ultra Series $series detected — VMD driver required" }
    }

    # Intel Core i-series (traditional generations)
    # Model number format: i7-1165G7 → captures "1165" (4 digits) → gen 11
    #                      i9-13900K → captures "13900" (5 digits) → gen 13
    if ($CpuName -match 'Core\s*\(TM\)\s+i\d+-(\d{4,5})') {
        $modelStr = $Matches[1]
        $gen = if ($modelStr.Length -eq 4) {
            [math]::Floor([int]$modelStr / 100)    # 1165 → 11
        } else {
            [math]::Floor([int]$modelStr / 1000)   # 13900 → 13
        }

        if ($gen -ge 11 -and $gen -le 14) {
            return @{ NeedsVMD = $true; Reason = "Intel ${gen}th gen detected — VMD driver required" }
        }
        return @{ NeedsVMD = $false; Reason = "Intel ${gen}th gen detected — VMD not required" }
    }

    # Unrecognised Intel CPU string — skip with a warning
    return @{ NeedsVMD = $false; Reason = "Intel CPU generation unrecognised ('$CpuName') — skipping VMD injection" }
}

function Get-IntelRSTDownloadUrl {
    $apiUrl      = "https://www.intel.com/bin/downloadcollection.json?ids=720755"
    $fallbackUrl = "https://downloadmirror.intel.com/720755/Intel-RST-VMD-Driver-Software_20.5.4.1.zip"

    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
        'Accept'     = 'application/json, text/html, */*'
    }

    # ── Attempt 1: Intel download collection API ───────────────────────────────
    Write-Host "[PrepUSB] Querying Intel download API for current RST driver URL..." -ForegroundColor Cyan
    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 30 -ErrorAction Stop

        # Walk the response object to find the first downloadmirror.intel.com URL
        $url = $null
        if ($response.downloads) {
            foreach ($entry in $response.downloads) {
                if ($entry.downloadUrl -match 'downloadmirror\.intel\.com') {
                    $url = $entry.downloadUrl; break
                }
            }
        }
        if (-not $url -and $response -is [System.Collections.IEnumerable]) {
            foreach ($item in $response) {
                $candidate = $null
                if     ($item.downloadUrl) { $candidate = $item.downloadUrl }
                elseif ($item.url)         { $candidate = $item.url }
                elseif ($item.href)        { $candidate = $item.href }
                if ($candidate -match 'downloadmirror\.intel\.com') {
                    $url = $candidate; break
                }
            }
        }

        if ($url) {
            Write-Host "[PrepUSB] API returned driver URL: $url" -ForegroundColor Cyan
            return $url
        }
        Write-Host "[PrepUSB] API response contained no download URL — trying fallback." -ForegroundColor Yellow
    } catch {
        Write-Host "[PrepUSB] API query failed ($_) — trying fallback." -ForegroundColor Yellow
    }

    # ── Attempt 2: Known stable direct URL ────────────────────────────────────
    Write-Host "[PrepUSB] Using fallback driver URL: $fallbackUrl" -ForegroundColor Cyan
    try {
        $probe = Invoke-WebRequest -Uri $fallbackUrl -Method Head -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        if ($probe.StatusCode -eq 200) { return $fallbackUrl }
    } catch {
        Write-Host "[PrepUSB] Fallback URL probe failed: $_" -ForegroundColor Yellow
    }

    return $null
}

function Invoke-VMDDriverInjection {
    param(
        [string]$UsbRoot
    )

    # ── Detect CPU ─────────────────────────────────────────────────────────────
    Write-Host "[PrepUSB] Detecting CPU generation for VMD requirement..." -ForegroundColor Cyan

    try {
        $cpuName = (Get-WmiObject -Class Win32_Processor | Select-Object -ExpandProperty Name -First 1).Trim()
        Write-Host "[PrepUSB] CPU: $cpuName" -ForegroundColor Cyan
    } catch {
        Write-Host "[PrepUSB] ERROR: Could not read CPU info — $_" -ForegroundColor Red
        return $false
    }

    $vmdStatus = Get-CPUVMDStatus -CpuName $cpuName

    if (-not $vmdStatus.NeedsVMD) {
        Write-Host "[PrepUSB] CPU does not require VMD driver — skipping injection." -ForegroundColor DarkGray
        return $true
    }

    Write-Host "[PrepUSB] $($vmdStatus.Reason)" -ForegroundColor Cyan

    # ── Download Intel RST driver ───────────────────────────────────────────────
    $tempDir = Join-Path $env:TEMP "AutopilotVMD_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $driverInfDir = $null

    try {
        $driverUrl = Get-IntelRSTDownloadUrl
        if (-not $driverUrl) { throw "Could not obtain a driver download URL from Intel API or fallback." }
        Write-Host "[PrepUSB] Downloading from: $driverUrl" -ForegroundColor Cyan

        $archivePath = Join-Path $tempDir "rst_driver.zip"
        Write-Host "[PrepUSB] Downloading Intel RST driver package..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $driverUrl -OutFile $archivePath -UseBasicParsing -TimeoutSec 120

        Write-Host "[PrepUSB] Extracting package..." -ForegroundColor Cyan
        Expand-Archive -Path $archivePath -DestinationPath $tempDir -Force

        # Locate VMD driver INF — iaStorVD.inf is the canonical VMD controller driver
        $infFile = Get-ChildItem -Path $tempDir -Filter "iaStorVD.inf" -Recurse -ErrorAction SilentlyContinue |
                   Select-Object -First 1

        # Fallback: any INF inside a folder named VMD, RST, IRST, or iaStore
        if (-not $infFile) {
            $infFile = Get-ChildItem -Path $tempDir -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue |
                       Where-Object { $_.DirectoryName -match '(VMD|RST|IRST|iaStore)' } |
                       Select-Object -First 1
        }

        if (-not $infFile) {
            throw "iaStorVD.inf not found in extracted package — package structure may have changed"
        }

        $driverInfDir = $infFile.DirectoryName
        Write-Host "[PrepUSB] Driver files located at: $driverInfDir" -ForegroundColor Cyan

    } catch {
        Write-Host "[PrepUSB] ERROR: Could not download or extract Intel RST driver — $_" -ForegroundColor Red
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    # ── DISM injection into boot.wim ───────────────────────────────────────────
    # Uses inbox dism.exe (C:\Windows\System32\dism.exe) — no ADK required.
    # Targets index 2 of boot.wim: the Windows Setup environment that runs during
    # the "Where do you want to install Windows?" screen where disk detection occurs.

    $bootWim  = "${UsbRoot}sources\boot.wim"
    $mountDir = Join-Path $env:TEMP "WimMount_$(Get-Random)"
    New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
    $dismOk = $false

    Write-Host "[PrepUSB] Injecting VMD driver into boot.wim (index 2) using dism.exe..." -ForegroundColor Cyan

    try {
        # attrib -R removes the read-only attribute — MCT marks boot.wim read-only on the USB
        & "$env:SystemRoot\System32\attrib.exe" -R "$bootWim" 2>&1 | Out-Null
        Write-Host "[PrepUSB] Read-only attribute cleared on boot.wim." -ForegroundColor DarkGray

        $out = & "$env:SystemRoot\System32\dism.exe" /Mount-Wim /WimFile:"$bootWim" /Index:2 /MountDir:"$mountDir" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Mount failed (exit $LASTEXITCODE): $($out -join ' ')" }

        $out = & "$env:SystemRoot\System32\dism.exe" /Image:"$mountDir" /Add-Driver /Driver:"$driverInfDir" /Recurse 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Add-Driver failed (exit $LASTEXITCODE): $($out -join ' ')" }

        $out = & "$env:SystemRoot\System32\dism.exe" /Unmount-Wim /MountDir:"$mountDir" /Commit 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Unmount/commit failed (exit $LASTEXITCODE): $($out -join ' ')" }

        $dismOk = $true

    } catch {
        Write-Host "[PrepUSB] ERROR: DISM injection failed — $_" -ForegroundColor Red
    } finally {
        if (-not $dismOk) {
            & "$env:SystemRoot\System32\dism.exe" /Unmount-Wim /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
        }
        Remove-Item -Path $mountDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $tempDir  -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $dismOk) { return $false }

    Write-Host "[PrepUSB] VMD driver injected into boot.wim — disk will be detected automatically during Windows setup." -ForegroundColor Green
    return $true
}

# ── PrepUSB ────────────────────────────────────────────────────────────────────

function Invoke-PrepUSB {
    param(
        [string]$Drive
    )

    Write-Host "[PrepUSB] Looking for Windows 11 USB..." -ForegroundColor Cyan

    if ($Drive) {
        $Drive = $Drive.TrimEnd(':').ToUpper()
        $root = "${Drive}:\"
        if (-not (Test-IsWindows11USB -Root $root)) {
            Write-Host "[PrepUSB] ERROR: Drive ${Drive}: does not contain Windows 11 setup files." -ForegroundColor Red
            return $false
        }
    } else {
        $found = Find-Windows11USB
        if (-not $found) {
            Write-Host "[PrepUSB] ERROR: No Windows 11 USB detected. Write the ISO to a USB first, then re-run." -ForegroundColor Red
            return $false
        }
        $Drive = $found.Name.TrimEnd(':').ToUpper()
        $root  = $found.Root
        Write-Host "[PrepUSB] Found Windows 11 USB at drive ${Drive}:" -ForegroundColor Green
    }

    # ── Write ei.cfg to force Pro edition ─────────────────────────────────────
    $eiCfgPath = "${root}sources\ei.cfg"

    if (Test-Path $eiCfgPath) {
        Write-Host "[PrepUSB] Existing ei.cfg found — overwriting." -ForegroundColor Yellow
    }

    $eiCfg = "[EditionID]`r`nProfessional`r`n[Channel]`r`n_Default`r`n[VL]`r`n0`r`n"

    try {
        Set-Content -Path $eiCfgPath -Value $eiCfg -Encoding ASCII -Force
        Write-Host "[PrepUSB] ei.cfg written — USB will install Windows 11 Pro automatically." -ForegroundColor Green
    } catch {
        Write-Host "[PrepUSB] ERROR: Could not write ei.cfg: $_" -ForegroundColor Red
        Write-Host "[PrepUSB] Ensure the USB is not write-protected and you are running as Administrator." -ForegroundColor Yellow
        return $false
    }

    # ── VMD driver detection and injection ─────────────────────────────────────
    $vmdOk = Invoke-VMDDriverInjection -UsbRoot $root
    if (-not $vmdOk) { return $false }

    return $true
}

# ── CollectHash ────────────────────────────────────────────────────────────────

function Invoke-CollectHash {
    param([string]$OverridePath)

    if ($OverridePath) {
        $outPath = $OverridePath
        Write-Host "[CollectHash] Output path overridden: $outPath" -ForegroundColor Yellow
    } else {
        $usbRoot = Find-DataUSB
        if ($usbRoot) {
            $hashFolder = "${usbRoot}AutopilotHashes"
            New-Item -ItemType Directory -Force -Path $hashFolder | Out-Null
            $outPath = "$hashFolder\autopilot-$(hostname).csv"
            Write-Host "[CollectHash] USB detected at ${usbRoot} — saving to: $outPath" -ForegroundColor Green
        } else {
            $outPath = "C:\Users\Public\Desktop\autopilot-$(hostname).csv"
            Write-Host "[CollectHash] No separate data USB detected — saving to Public Desktop: $outPath" -ForegroundColor Yellow
            Write-Host "[CollectHash] (Insert a separate USB to save the hash there instead)" -ForegroundColor DarkGray
        }
    }

    Write-Host "[CollectHash] Installing Get-WindowsAutopilotInfo..." -ForegroundColor Cyan

    try {
        Install-Script -Name Get-WindowsAutopilotInfo -Force -ErrorAction Stop
    } catch {
        Write-Host "[CollectHash] ERROR: Failed to install Get-WindowsAutopilotInfo: $_" -ForegroundColor Red
        Write-Host "[CollectHash] Check internet access and ensure you are running as Administrator." -ForegroundColor Yellow
        return $false
    }

    Write-Host "[CollectHash] Collecting hardware hash for $(hostname)..." -ForegroundColor Cyan

    try {
        Get-WindowsAutopilotInfo -OutputFile $outPath -ErrorAction Stop
    } catch {
        Write-Host "[CollectHash] ERROR: Get-WindowsAutopilotInfo failed: $_" -ForegroundColor Red
        return $false
    }

    if (Test-Path $outPath) {
        Write-Host "[CollectHash] Done. Hash saved to: $outPath" -ForegroundColor Green
        Write-Host "[CollectHash] Import into Intune: Devices > Enroll devices > Windows enrollment > Devices > Import" -ForegroundColor DarkGray
        return $true
    } else {
        Write-Host "[CollectHash] ERROR: File not found at $outPath after collection." -ForegroundColor Red
        return $false
    }
}

# ── Run ────────────────────────────────────────────────────────────────────────

$usbOk  = $true
$hashOk = $true

if ($PrepUSB)    { $usbOk  = Invoke-PrepUSB -Drive $DriveLetter; Write-Host "" }
if ($CollectHash){ $hashOk = Invoke-CollectHash -OverridePath $OutputPath;                    Write-Host "" }

Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
if ($PrepUSB)    { Write-Host "  PrepUSB     $(if ($usbOk)  { 'Complete' } else { 'Failed' })" -ForegroundColor $(if ($usbOk)  { 'Green' } else { 'Red' }) }
if ($CollectHash){ Write-Host "  CollectHash $(if ($hashOk) { 'Complete' } else { 'Failed' })" -ForegroundColor $(if ($hashOk) { 'Green' } else { 'Red' }) }
Write-Host ""

if ($PrepUSB -and $usbOk) {
    Write-Host "  Next: Boot the target PC from the USB and complete the Windows 11 Pro install." -ForegroundColor Cyan
    Write-Host "        At OOBE, connect to the internet — Autopilot will take over automatically." -ForegroundColor Cyan
    Write-Host ""
}
