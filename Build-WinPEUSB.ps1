# Build-WinPEUSB.ps1
#
# .SYNOPSIS
#   Builds a bootable WinPE USB drive for Autopilot hardware hash collection.
#
# .DESCRIPTION
#   Creates a WinPE-based bootable USB that automatically collects the Autopilot
#   hardware hash (via oa3tool.exe) and uploads it to Microsoft Intune using
#   client credentials from autopilot-appreg.config. Injects the hash collection
#   script, oa3tool.exe, oa3.cfg, and PCPKsp.dll into the WinPE image and
#   configures startnet.cmd to launch the script on boot.
#
# .REQUIREMENTS
#   - Windows ADK Deployment Tools (auto-installed if missing)
#   - Windows ADK WinPE add-on (manual install required)
#   - OSD PowerShell module (auto-installed if missing)
#   - autopilot-appreg.config in the script directory (created by New-AutopilotAppRegistration.ps1)
#   - Administrator elevation
#
# .USAGE
#   # Use defaults (config from script dir, prompt for USB drive):
#   .\Build-WinPEUSB.ps1
#
#   # Specify all parameters:
#   .\Build-WinPEUSB.ps1 -ConfigPath C:\configs\autopilot-appreg.config -DriveLetter E -WorkspacePath D:\OSDWork
#
#   # Specify just the drive letter:
#   .\Build-WinPEUSB.ps1 -DriveLetter F
#
# .NOTES
#   autopilot-appreg.config contains sensitive credentials and is not in the repo.
#   Run New-AutopilotAppRegistration.ps1 to generate it.

param(
    [string]$ConfigPath     = (Join-Path $PSScriptRoot 'autopilot-appreg.config'),
    [string]$DriveLetter,
    [string]$WorkspacePath  = (Join-Path $env:TEMP 'OSDCloudBuild')
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Status {
    param(
        [string]$Message,
        [string]$ForegroundColor = 'White'
    )
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] " -ForegroundColor DarkGray -NoNewline
    Write-Host $Message -ForegroundColor $ForegroundColor
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1 — Prerequisites
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Status "Phase 1 — Prerequisites" -ForegroundColor Cyan
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── Require elevation ────────────────────────────────────────────────────────

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Status "ERROR: This script must be run as Administrator." -ForegroundColor Red
    exit 1
}
Write-Status "Running as Administrator." -ForegroundColor Green

# ── Detect ADK root ─────────────────────────────────────────────────────────

$AdkRoot = $null
$adkPaths = @(
    'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit',
    'C:\Program Files\Windows Kits\10\Assessment and Deployment Kit'
)

foreach ($p in $adkPaths) { if (Test-Path $p) { $AdkRoot = $p; break } }

# ── Auto-install ADK Deployment Tools if missing ─────────────────────────────

if (-not $AdkRoot) {
    Write-Status "Windows ADK Deployment Tools not found — downloading installer..." -ForegroundColor Yellow

    $adkInstaller = "$env:TEMP\adksetup.exe"
    $dlState      = @{ Done = $false; Err = $null; Pct = 0 }
    $wc           = New-Object System.Net.WebClient

    $sub1 = Register-ObjectEvent -InputObject $wc -EventName DownloadProgressChanged -MessageData $dlState -Action {
        $Event.MessageData.Pct = $Event.SourceEventArgs.ProgressPercentage
    }
    $sub2 = Register-ObjectEvent -InputObject $wc -EventName DownloadFileCompleted -MessageData $dlState -Action {
        $Event.MessageData.Done = $true
        if ($Event.SourceEventArgs.Error) { $Event.MessageData.Err = $Event.SourceEventArgs.Error.Message }
    }

    $wc.DownloadFileAsync([Uri]'https://go.microsoft.com/fwlink/?linkid=2271337', $adkInstaller)

    $lastPct = -1
    while (-not $dlState.Done) {
        Start-Sleep -Milliseconds 500
        $pct = $dlState.Pct
        if ($pct -ne $lastPct) {
            $lastPct = $pct
            Write-Host "`r[$((Get-Date -Format 'HH:mm:ss'))] Downloading ADK: $pct%" -NoNewline
        }
    }
    Write-Host ""

    Unregister-Event -SubscriptionId $sub1.Id -ErrorAction SilentlyContinue
    Unregister-Event -SubscriptionId $sub2.Id -ErrorAction SilentlyContinue
    Remove-Job $sub1 -Force -ErrorAction SilentlyContinue
    Remove-Job $sub2 -Force -ErrorAction SilentlyContinue
    $wc.Dispose()

    if ($dlState.Err) {
        Write-Status "ERROR: ADK download failed — $($dlState.Err)" -ForegroundColor Red
        exit 1
    }

    Write-Status "Installing ADK Deployment Tools — this may take a few minutes..." -ForegroundColor Cyan
    Start-Process -FilePath $adkInstaller -ArgumentList "/quiet /features OptionId.DeploymentTools /norestart" -Wait -NoNewWindow

    foreach ($p in $adkPaths) { if (Test-Path $p) { $AdkRoot = $p; break } }

    if (-not $AdkRoot) {
        Write-Status "ERROR: ADK not found after installation. Check the installation manually." -ForegroundColor Red
        exit 1
    }

    Write-Status "ADK Deployment Tools installed." -ForegroundColor Green
} else {
    Write-Status "ADK found at: $AdkRoot" -ForegroundColor Green
}

# ── Detect WinPE add-on ──────────────────────────────────────────────────────

$winpeWim = Join-Path $AdkRoot 'Windows Preinstallation Environment\amd64\en-us\winpe.wim'
if (-not (Test-Path $winpeWim)) {
    Write-Status "ERROR: ADK WinPE add-on not found (winpe.wim missing)." -ForegroundColor Red
    Write-Status "Install the WinPE add-on from:" -ForegroundColor Red
    Write-Status "https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" -ForegroundColor Red
    exit 1
}
Write-Status "ADK WinPE add-on found." -ForegroundColor Green

# ── OSD module ───────────────────────────────────────────────────────────────

if (-not (Get-Module -ListAvailable -Name 'OSD')) {
    Write-Status "OSD module not found — installing from PSGallery..." -ForegroundColor Yellow
    try {
        Install-Module -Name 'OSD' -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Status "OSD module installed." -ForegroundColor Green
    } catch {
        Write-Status "ERROR: Could not install OSD module — $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Status "OSD module found." -ForegroundColor Green
}

Import-Module OSD -Force -ErrorAction Stop
Write-Status "OSD module imported." -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2 — Config and staging
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Status "Phase 2 — Config and staging" -ForegroundColor Cyan
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── Read config ──────────────────────────────────────────────────────────────

if (-not (Test-Path $ConfigPath)) {
    Write-Status "ERROR: Config file not found at $ConfigPath" -ForegroundColor Red
    Write-Status "Run New-AutopilotAppRegistration.ps1 to create it." -ForegroundColor Yellow
    exit 1
}

$config = @{}
foreach ($line in (Get-Content $ConfigPath)) {
    if ($line -match '^([^=]+)=(.*)$') {
        $config[$Matches[1].Trim()] = $Matches[2].Trim()
    }
}

$requiredKeys = @('TenantId', 'AppId', 'AppSecret', 'SecretExpiry')
foreach ($key in $requiredKeys) {
    if (-not $config[$key] -or $config[$key] -eq '') {
        Write-Status "ERROR: Config key '$key' is missing or empty in $ConfigPath" -ForegroundColor Red
        exit 1
    }
}

Write-Status "Config loaded — Tenant: $($config['TenantId'])" -ForegroundColor Green

# ── Check secret expiry ──────────────────────────────────────────────────────

$secretExpiry = [DateTime]::Parse($config['SecretExpiry'])
$daysUntilExpiry = ($secretExpiry - (Get-Date)).Days

if ($daysUntilExpiry -lt 0) {
    Write-Status "ERROR: Client secret expired on $($secretExpiry.ToString('yyyy-MM-dd')). Re-run New-AutopilotAppRegistration.ps1." -ForegroundColor Red
    exit 1
}

if ($daysUntilExpiry -le 30) {
    Write-Status "WARNING: Client secret expires in $daysUntilExpiry days ($($secretExpiry.ToString('yyyy-MM-dd'))). Consider rotating soon." -ForegroundColor Yellow
}

# ── Create staging directory ─────────────────────────────────────────────────

$stagingDir = Join-Path $env:TEMP 'autopilot-winpe-stage'

if (Test-Path $stagingDir) {
    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

Write-Status "Staging directory: $stagingDir" -ForegroundColor Green

# ── Copy and inject credentials into Invoke-AutopilotHash.ps1 ────────────────

$sourceScript = Join-Path $ScriptDir 'WinPE\Invoke-AutopilotHash.ps1'
$stagedScript = Join-Path $stagingDir 'Invoke-AutopilotHash.ps1'

if (-not (Test-Path $sourceScript)) {
    Write-Status "ERROR: WinPE\Invoke-AutopilotHash.ps1 not found at $sourceScript" -ForegroundColor Red
    exit 1
}

$scriptContent = Get-Content -Path $sourceScript -Raw
$scriptContent = $scriptContent.Replace('##TENANTID##',  $config['TenantId'])
$scriptContent = $scriptContent.Replace('##APPID##',     $config['AppId'])
$scriptContent = $scriptContent.Replace('##APPSECRET##', $config['AppSecret'])
Set-Content -Path $stagedScript -Value $scriptContent -Encoding UTF8 -Force

if ($scriptContent -match '##[A-Z]+##') {
    Write-Status "ERROR: Unreplaced placeholder tokens found in staged script." -ForegroundColor Red
    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Status "Invoke-AutopilotHash.ps1 staged with credentials injected." -ForegroundColor Green

# ── Copy oa3.cfg ─────────────────────────────────────────────────────────────

$sourceOa3Cfg = Join-Path $ScriptDir 'WinPE\oa3.cfg'
if (-not (Test-Path $sourceOa3Cfg)) {
    Write-Status "ERROR: WinPE\oa3.cfg not found at $sourceOa3Cfg" -ForegroundColor Red
    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
Copy-Item -Path $sourceOa3Cfg -Destination (Join-Path $stagingDir 'oa3.cfg') -Force
Write-Status "oa3.cfg staged." -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3 — WinPE build
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Status "Phase 3 — WinPE build" -ForegroundColor Cyan
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── Create OSDCloud workspace ────────────────────────────────────────────────

Write-Status "Creating OSDCloud workspace at $WorkspacePath..." -ForegroundColor Cyan
New-OSDCloudWorkspace -WorkspacePath $WorkspacePath -ErrorAction Stop
Write-Status "OSDCloud workspace created." -ForegroundColor Green

Write-Status "Editing WinPE with cloud drivers..." -ForegroundColor Cyan
Edit-OSDCloudWinPE -CloudDriver * -ErrorAction Stop
Write-Status "WinPE edited with cloud drivers." -ForegroundColor Green

# ── Locate boot.wim ──────────────────────────────────────────────────────────

$bootWim = Join-Path $WorkspacePath 'Media\sources\boot.wim'
if (-not (Test-Path $bootWim)) {
    Write-Status "ERROR: boot.wim not found at $bootWim" -ForegroundColor Red
    exit 1
}
Write-Status "boot.wim located: $bootWim" -ForegroundColor Green

# ── Locate oa3tool.exe ───────────────────────────────────────────────────────

$oa3tool = Join-Path $AdkRoot 'Deployment Tools\amd64\Licensing\OA3\oa3tool.exe'
if (-not (Test-Path $oa3tool)) {
    Write-Status "ERROR: oa3tool.exe not found at $oa3tool" -ForegroundColor Red
    exit 1
}
Write-Status "oa3tool.exe located: $oa3tool" -ForegroundColor Green

# ── Locate PCPKsp.dll ────────────────────────────────────────────────────────

$pcpKsp = Join-Path $env:SystemRoot 'System32\PCPKsp.dll'
if (-not (Test-Path $pcpKsp)) {
    Write-Status "ERROR: PCPKsp.dll not found at $pcpKsp" -ForegroundColor Red
    exit 1
}
Write-Status "PCPKsp.dll located: $pcpKsp" -ForegroundColor Green

# ── Mount WIM and inject files ───────────────────────────────────────────────

$mountDir = Join-Path $env:TEMP 'autopilot-winpe-mount'
if (Test-Path $mountDir) {
    Remove-Item -Path $mountDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

Write-Status "Mounting boot.wim..." -ForegroundColor Cyan

try {
    Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $mountDir -ErrorAction Stop | Out-Null
    Write-Status "boot.wim mounted at $mountDir" -ForegroundColor Green
} catch {
    Write-Status "ERROR: Failed to mount boot.wim — $_" -ForegroundColor Red
    exit 1
}

$sys32 = Join-Path $mountDir 'Windows\System32'

try {
    Copy-Item -Path $stagedScript -Destination (Join-Path $sys32 'Invoke-AutopilotHash.ps1') -Force -ErrorAction Stop
    Write-Status "Invoke-AutopilotHash.ps1 injected." -ForegroundColor Green

    Copy-Item -Path (Join-Path $stagingDir 'oa3.cfg') -Destination (Join-Path $sys32 'oa3.cfg') -Force -ErrorAction Stop
    Write-Status "oa3.cfg injected." -ForegroundColor Green

    Copy-Item -Path $oa3tool -Destination (Join-Path $sys32 'oa3tool.exe') -Force -ErrorAction Stop
    Write-Status "oa3tool.exe injected." -ForegroundColor Green

    Copy-Item -Path $pcpKsp -Destination (Join-Path $sys32 'PCPKsp.dll') -Force -ErrorAction Stop
    Write-Status "PCPKsp.dll injected." -ForegroundColor Green

    $startnetPath = Join-Path $sys32 'startnet.cmd'
    $startnetContent = @(
        'wpeinit'
        'powershell.exe -ExecutionPolicy Bypass -File X:\Windows\System32\Invoke-AutopilotHash.ps1'
    )
    Set-Content -Path $startnetPath -Value $startnetContent -Encoding ASCII -Force -ErrorAction Stop
    Write-Status "startnet.cmd overwritten with Autopilot launch command." -ForegroundColor Green
} catch {
    Write-Status "ERROR: File injection failed — $_" -ForegroundColor Red
    Write-Status "Dismounting WIM with discard..." -ForegroundColor Yellow
    Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue
    exit 1
}

# ── Dismount and save ────────────────────────────────────────────────────────

Write-Status "Dismounting and saving boot.wim..." -ForegroundColor Cyan
try {
    Dismount-WindowsImage -Path $mountDir -Save -ErrorAction Stop
    Write-Status "boot.wim saved successfully." -ForegroundColor Green
} catch {
    Write-Status "ERROR: Failed to dismount/save boot.wim — $_" -ForegroundColor Red
    Dismount-WindowsImage -Path $mountDir -Discard -ErrorAction SilentlyContinue
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4 — USB write
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Status "Phase 4 — USB write" -ForegroundColor Cyan
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── Select drive letter ──────────────────────────────────────────────────────

if (-not $DriveLetter) {
    Write-Status "Detecting USB drives..." -ForegroundColor Cyan

    $usbDisks = Get-Disk | Where-Object { $_.BusType -eq 'USB' }
    if (-not $usbDisks) {
        Write-Status "ERROR: No USB drives detected. Insert a USB drive and try again." -ForegroundColor Red
        exit 1
    }

    foreach ($disk in $usbDisks) {
        $parts = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
        foreach ($part in $parts) {
            if ($part.DriveLetter) {
                $sizeGB = [math]::Round($disk.Size / 1GB, 1)
                Write-Status "  $($part.DriveLetter): — Disk $($disk.Number) — $($disk.FriendlyName) — $sizeGB GB" -ForegroundColor White
            }
        }
    }

    Write-Host ""
    $DriveLetter = Read-Host "Enter the drive letter for the USB drive (e.g. E)"
}

# ── Validate drive letter ───────────────────────────────────────────────────

$DriveLetter = $DriveLetter.Trim().TrimEnd(':').ToUpper()

if ($DriveLetter -notmatch '^[A-Z]$') {
    Write-Status "ERROR: '$DriveLetter' is not a valid drive letter." -ForegroundColor Red
    exit 1
}

$targetPartition = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
if (-not $targetPartition) {
    Write-Status "ERROR: No partition found with drive letter $DriveLetter." -ForegroundColor Red
    exit 1
}

$targetDisk = Get-Disk -Number $targetPartition.DiskNumber -ErrorAction SilentlyContinue
if ($targetDisk.BusType -ne 'USB') {
    Write-Status "ERROR: Drive $DriveLetter is not a USB disk (bus type: $($targetDisk.BusType)). Refusing to format non-USB media." -ForegroundColor Red
    exit 1
}

Write-Status "Target: $DriveLetter`: — $($targetDisk.FriendlyName)" -ForegroundColor Green

# ── Build label from expiry ──────────────────────────────────────────────────

$usbLabel = "AutopilotPE-$($secretExpiry.ToString('yyyyMMdd'))"

# ── Confirmation ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Status "  USB Build Summary" -ForegroundColor Cyan
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Status "  Drive       : $DriveLetter`:" -ForegroundColor White
Write-Status "  Disk        : $($targetDisk.FriendlyName)" -ForegroundColor White
Write-Status "  Label       : $usbLabel" -ForegroundColor White
Write-Status "  Tenant      : $($config['TenantId'])" -ForegroundColor White
Write-Status "  Secret exp. : $($secretExpiry.ToString('yyyy-MM-dd'))" -ForegroundColor White
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Status "WARNING: ALL DATA ON DRIVE $DriveLetter`: WILL BE ERASED!" -ForegroundColor Yellow
Write-Host ""

$confirm = Read-Host "Type YES to proceed"
if ($confirm -ne 'YES') {
    Write-Status "Aborted by user." -ForegroundColor Yellow
    exit 1
}

# ── Format NTFS ──────────────────────────────────────────────────────────────

Write-Status "Formatting $DriveLetter`: as NTFS with label '$usbLabel'..." -ForegroundColor Cyan

try {
    Format-Volume -DriveLetter $DriveLetter -FileSystem NTFS -NewFileSystemLabel $usbLabel -Confirm:$false -Force -ErrorAction Stop | Out-Null
    Write-Status "Format complete." -ForegroundColor Green
} catch {
    Write-Status "ERROR: Format failed — $_" -ForegroundColor Red
    exit 1
}

# ── Mark partition active via diskpart ───────────────────────────────────────

Write-Status "Marking partition active..." -ForegroundColor Cyan

$diskpartScript = @(
    "select disk $($targetPartition.DiskNumber)"
    "select partition $($targetPartition.PartitionNumber)"
    "active"
) -join "`r`n"

$diskpartFile = Join-Path $env:TEMP 'autopilot-diskpart.txt'
Set-Content -Path $diskpartFile -Value $diskpartScript -Encoding ASCII -Force

try {
    $dpOut = & diskpart /s $diskpartFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Status "ERROR: diskpart failed — $($dpOut -join ' ')" -ForegroundColor Red
        Remove-Item -Path $diskpartFile -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Status "Partition marked active." -ForegroundColor Green
} catch {
    Write-Status "ERROR: diskpart failed — $_" -ForegroundColor Red
    Remove-Item -Path $diskpartFile -Force -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item -Path $diskpartFile -Force -ErrorAction SilentlyContinue

# ── Apply boot sector via bootsect.exe ───────────────────────────────────────

Write-Status "Applying boot sector..." -ForegroundColor Cyan

$bootsect = Join-Path $AdkRoot 'Deployment Tools\amd64\BCDBoot\bootsect.exe'
if (-not (Test-Path $bootsect)) {
    Write-Status "ERROR: bootsect.exe not found at $bootsect" -ForegroundColor Red
    exit 1
}

try {
    $bsOut = & $bootsect /nt60 "${DriveLetter}:" /mbr 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Status "ERROR: bootsect failed — $($bsOut -join ' ')" -ForegroundColor Red
        exit 1
    }
    Write-Status "Boot sector applied." -ForegroundColor Green
} catch {
    Write-Status "ERROR: bootsect failed — $_" -ForegroundColor Red
    exit 1
}

# ── Copy media to USB ────────────────────────────────────────────────────────

Write-Status "Copying WinPE media to $DriveLetter`:..." -ForegroundColor Cyan

$mediaSource = Join-Path $WorkspacePath 'Media\*'
try {
    Copy-Item -Path $mediaSource -Destination "${DriveLetter}:\" -Recurse -Force -ErrorAction Stop
    Write-Status "Media copied successfully." -ForegroundColor Green
} catch {
    Write-Status "ERROR: Failed to copy media — $_" -ForegroundColor Red
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5 — Cleanup
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Status "Phase 5 — Cleanup" -ForegroundColor Cyan
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

if (Test-Path $stagingDir) {
    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Status "Staging directory removed (contained injected credentials)." -ForegroundColor Green
}

if (Test-Path $WorkspacePath) {
    Remove-Item -Path $WorkspacePath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Status "OSDCloud workspace removed." -ForegroundColor Green
}

if (Test-Path $mountDir) {
    Remove-Item -Path $mountDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Status "Mount point removed." -ForegroundColor Green
}

# ── Completion summary ───────────────────────────────────────────────────────

Write-Host ""
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Status "  Build Complete" -ForegroundColor Green
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Status "  Drive       : $DriveLetter`:" -ForegroundColor White
Write-Status "  Label       : $usbLabel" -ForegroundColor White
Write-Status "  Expiry      : $($secretExpiry.ToString('yyyy-MM-dd'))" -ForegroundColor White
Write-Status "────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Status "SECURITY: This USB contains embedded Azure AD credentials." -ForegroundColor Yellow
Write-Status "Store it securely, do not leave it unattended, and destroy or rebuild when the secret expires." -ForegroundColor Yellow
Write-Host ""
