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
    Write-Host "  Prep a Windows 11 USB for Pro install:" -ForegroundColor DarkGray
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
    return (Test-Path "${Root}sources\install.wim") -or (Test-Path "${Root}sources\install.esd")
}

function Find-DataUSB {
    # Returns the first non-system drive that is NOT a Windows 11 install USB.
    # This prevents hash CSVs from being written to install media.
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Root -ne ($env:SystemDrive + "\") -and
        -not (Test-IsWindows11USB -Root $_.Root)
    }
    if ($drives) { return @($drives)[0].Root }
    return $null
}

function Find-Windows11USB {
    # Returns the first drive that contains Windows 11 setup files.
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object {
        $_.Root -ne ($env:SystemDrive + "\") -and
        (Test-IsWindows11USB -Root $_.Root)
    }
    if ($drives) { return @($drives)[0] }
    return $null
}

# ── PrepUSB ────────────────────────────────────────────────────────────────────

function Invoke-PrepUSB {
    param([string]$Drive)

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

    $eiCfgPath = "${root}sources\ei.cfg"

    if (Test-Path $eiCfgPath) {
        Write-Host "[PrepUSB] Existing ei.cfg found — overwriting." -ForegroundColor Yellow
    }

    $eiCfg = "[EditionID]`r`nProfessional`r`n[Channel]`r`n_Default`r`n[VL]`r`n0`r`n"

    try {
        Set-Content -Path $eiCfgPath -Value $eiCfg -Encoding ASCII -Force
        Write-Host "[PrepUSB] Done — USB will now install Windows 11 Pro automatically." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "[PrepUSB] ERROR: Could not write ei.cfg: $_" -ForegroundColor Red
        Write-Host "[PrepUSB] Ensure the USB is not write-protected and you are running as Administrator." -ForegroundColor Yellow
        return $false
    }
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
            Write-Host "[CollectHash] No separate USB detected — saving to Public Desktop: $outPath" -ForegroundColor Yellow
            Write-Host "[CollectHash] (Windows 11 install USB does not count — insert a separate data USB to save there)" -ForegroundColor DarkGray
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

if ($PrepUSB)    { $usbOk  = Invoke-PrepUSB -Drive $DriveLetter;          Write-Host "" }
if ($CollectHash){ $hashOk = Invoke-CollectHash -OverridePath $OutputPath; Write-Host "" }

Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
if ($PrepUSB)    { Write-Host "  PrepUSB     $(if ($usbOk)  { 'Complete' } else { 'Failed' })" -ForegroundColor $(if ($usbOk)  { 'Green' } else { 'Red' }) }
if ($CollectHash){ Write-Host "  CollectHash $(if ($hashOk) { 'Complete' } else { 'Failed' })" -ForegroundColor $(if ($hashOk) { 'Green' } else { 'Red' }) }
Write-Host ""

if ($PrepUSB -and $usbOk) {
    Write-Host "  Next: Boot the target PC from the USB and complete the Windows 11 Pro install." -ForegroundColor Cyan
    Write-Host "        At OOBE, connect to the internet — Autopilot will take over automatically." -ForegroundColor Cyan
    Write-Host ""
}