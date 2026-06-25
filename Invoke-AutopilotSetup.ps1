# Invoke-AutopilotSetup.ps1
# Autopilot deployment tool for Microsoft 365 Business Premium environments.
#
# Run from an elevated PowerShell prompt:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -CollectHash
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -CollectHash

param(
    [switch]$PrepUSB,
    [switch]$CollectHash,
    [string]$DriveLetter,
    [string]$OutputPath,
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret
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
    Write-Host "  -CollectHash          Collect hash and upload directly to Intune (browser sign-in — Option A)" -ForegroundColor White
    Write-Host "  -PrepUSB              Inject ei.cfg + VMD driver into a Windows 11 USB" -ForegroundColor White
    Write-Host "  -DriveLetter X        Force a specific drive letter for -PrepUSB  (e.g. -DriveLetter E)" -ForegroundColor White
    Write-Host "  -OutputPath path      Override the hash CSV save location" -ForegroundColor White
    Write-Host ""
    Write-Host "  Option B — silent app-based Intune upload (no browser prompt):" -ForegroundColor DarkGray
    Write-Host "  -TenantId <id>        Azure AD tenant ID" -ForegroundColor White
    Write-Host "  -ClientId <id>        App registration client ID" -ForegroundColor White
    Write-Host "  -ClientSecret <val>   App registration client secret" -ForegroundColor White
    Write-Host "  (Run -CollectHash with one or two of these to see full Option B setup instructions)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Copy and run one of these commands:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Collect hash + upload to Intune (browser sign-in):" -ForegroundColor DarkGray
    Write-Host "  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -CollectHash" -ForegroundColor White
    Write-Host ""
    Write-Host "  Collect hash + upload silently (app credentials — Option B):" -ForegroundColor DarkGray
    Write-Host "  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -CollectHash -TenantId <id> -ClientId <id> -ClientSecret <secret>" -ForegroundColor White
    Write-Host ""
    Write-Host "  Prep a Windows 11 USB for Pro install (auto-detects CPU, injects VMD driver if needed):" -ForegroundColor DarkGray
    Write-Host "  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB" -ForegroundColor White
    Write-Host ""
    Write-Host "  Prep USB on drive E specifically:" -ForegroundColor DarkGray
    Write-Host "  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -DriveLetter E" -ForegroundColor White
    Write-Host ""
    Write-Host "  Do both in one shot:" -ForegroundColor DarkGray
    Write-Host "  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -CollectHash" -ForegroundColor White
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

    # ── Download VMD driver files from repo ────────────────────────────────────
    $tempDir = Join-Path $env:TEMP "AutopilotVMD_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $driverInfDir = $null
    $repoBase     = "https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/drivers/VMD"
    $driverFiles  = @(
        'iaStorVD.cat',
        'iaStorVD.inf',
        'iaStorVD.sys',
        'RstMwEventLogMsg.dll',
        'RstMwService.exe'
    )

    try {
        Write-Host "[PrepUSB] Downloading VMD driver files from repo..." -ForegroundColor Cyan
        foreach ($file in $driverFiles) {
            $dest = Join-Path $tempDir $file
            Invoke-WebRequest -Uri "$repoBase/$file" -OutFile $dest -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            Write-Host "[PrepUSB]   $file" -ForegroundColor DarkGray
        }

        $driverInfDir = $tempDir
        Write-Host "[PrepUSB] Driver files ready." -ForegroundColor Cyan

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

# ── Intune upload helpers ──────────────────────────────────────────────────────

function Invoke-AutopilotGraphUpload {
    param(
        [string]$CsvPath,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )

    Write-Host "[CollectHash] Authenticating with Intune via app credentials (Option B)..." -ForegroundColor Cyan

    $tokenUrl  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $tokenBody = "grant_type=client_credentials" +
                 "&client_id=$([Uri]::EscapeDataString($ClientId))" +
                 "&client_secret=$([Uri]::EscapeDataString($ClientSecret))" +
                 "&scope=https%3A%2F%2Fgraph.microsoft.com%2F.default"

    try {
        $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody `
                             -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        $token = $tokenResponse.access_token
        Write-Host "[CollectHash] Authentication successful." -ForegroundColor Green
    } catch {
        Write-Host "[CollectHash] ERROR: Failed to obtain access token — $_" -ForegroundColor Red
        Write-Host "[CollectHash] Verify TenantId, ClientId, ClientSecret and that admin consent has been granted." -ForegroundColor Yellow
        return $false
    }

    $graphUrl = "https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities"
    $headers  = @{
        Authorization  = "Bearer $token"
        'Content-Type' = 'application/json'
    }

    $devices = Import-Csv -Path $CsvPath
    $allOk   = $true

    foreach ($device in $devices) {
        $serial  = $device.'Device Serial Number'
        $payload = ConvertTo-Json -InputObject @{
            '@odata.type'      = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
            orderIdentifier    = ''
            serialNumber       = $serial
            productKey         = $device.'Windows Product ID'
            hardwareIdentifier = $device.'Hardware Hash'
        }

        try {
            Invoke-RestMethod -Uri $graphUrl -Method Post -Headers $headers -Body $payload -ErrorAction Stop | Out-Null
            Write-Host "[CollectHash] Uploaded to Intune: $serial" -ForegroundColor Green
        } catch {
            Write-Host "[CollectHash] ERROR: Failed to upload $serial — $_" -ForegroundColor Red
            $allOk = $false
        }
    }

    if ($allOk) {
        Write-Host "[CollectHash] Device registered in Intune — visible under Devices > Enroll devices > Windows enrollment > Devices within 5-15 minutes." -ForegroundColor Green
    }
    return $allOk
}

# ── CollectHash ────────────────────────────────────────────────────────────────

function Invoke-CollectHash {
    param(
        [string]$OverridePath,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )

    # ── Validate Option B credentials ──────────────────────────────────────────
    $hasAllB = $TenantId -and $ClientId -and $ClientSecret
    $hasAnyB = $TenantId -or  $ClientId -or  $ClientSecret

    if ($hasAnyB -and -not $hasAllB) {
        Write-Host "[CollectHash] ERROR: Option B requires all three: -TenantId, -ClientId, and -ClientSecret." -ForegroundColor Red
        Write-Host ""
        Write-Host "  ── Option B setup (silent app-based Intune upload) ───────────────" -ForegroundColor Yellow
        Write-Host "  1. Sign in to https://portal.azure.com" -ForegroundColor White
        Write-Host "     Go to: Microsoft Entra ID > App registrations > New registration" -ForegroundColor White
        Write-Host "     Name it (e.g. AutopilotHashUploader), single-tenant, no redirect URI" -ForegroundColor White
        Write-Host "  2. On the overview page, note the Application (client) ID and Directory (tenant) ID" -ForegroundColor White
        Write-Host "  3. Go to: API permissions > Add a permission > Microsoft Graph" -ForegroundColor White
        Write-Host "     Select: Application permissions" -ForegroundColor White
        Write-Host "     Search for and add: DeviceManagementServiceConfig.ReadWrite.All" -ForegroundColor White
        Write-Host "     Then click: Grant admin consent for your tenant" -ForegroundColor White
        Write-Host "  4. Go to: Certificates & secrets > New client secret" -ForegroundColor White
        Write-Host "     Copy the Value immediately — it is not shown again after leaving the page" -ForegroundColor White
        Write-Host "  5. Re-run with all three parameters:" -ForegroundColor White
        Write-Host "     -CollectHash -TenantId <tenant-id> -ClientId <client-id> -ClientSecret <secret>" -ForegroundColor White
        Write-Host "  ──────────────────────────────────────────────────────────────────" -ForegroundColor Yellow
        Write-Host ""
        return $false
    }

    # ── Determine output path ──────────────────────────────────────────────────
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

    if ($hasAllB) {
        # ── Option B: collect CSV, then upload silently via Graph API ──────────
        try {
            Get-WindowsAutopilotInfo -OutputFile $outPath -ErrorAction Stop
        } catch {
            Write-Host "[CollectHash] ERROR: Get-WindowsAutopilotInfo failed: $_" -ForegroundColor Red
            return $false
        }

        if (-not (Test-Path $outPath)) {
            Write-Host "[CollectHash] ERROR: Hash file not found at $outPath after collection." -ForegroundColor Red
            return $false
        }

        Write-Host "[CollectHash] Hash saved to: $outPath" -ForegroundColor Green
        return Invoke-AutopilotGraphUpload -CsvPath $outPath -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

    } else {
        # ── Option A: collect and upload via interactive browser sign-in ───────
        Write-Host "[CollectHash] A browser sign-in window will open — sign in with your M365 admin account." -ForegroundColor Cyan

        try {
            Get-WindowsAutopilotInfo -OutputFile $outPath -Online -ErrorAction Stop
        } catch {
            Write-Host "[CollectHash] ERROR: Get-WindowsAutopilotInfo failed: $_" -ForegroundColor Red
            return $false
        }

        if (Test-Path $outPath) {
            Write-Host "[CollectHash] Hash saved to: $outPath" -ForegroundColor Green
            Write-Host "[CollectHash] Device registered in Intune — visible under Devices > Enroll devices > Windows enrollment > Devices within 5-15 minutes." -ForegroundColor Green
            return $true
        } else {
            Write-Host "[CollectHash] ERROR: Hash file not found at $outPath after collection." -ForegroundColor Red
            return $false
        }
    }
}

# ── Run ────────────────────────────────────────────────────────────────────────

$usbOk  = $true
$hashOk = $true

if ($PrepUSB)    { $usbOk  = Invoke-PrepUSB -Drive $DriveLetter; Write-Host "" }
if ($CollectHash){ $hashOk = Invoke-CollectHash -OverridePath $OutputPath -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret; Write-Host "" }

Write-Host "  ─────────────────────────────────" -ForegroundColor DarkGray
if ($PrepUSB)    { Write-Host "  PrepUSB     $(if ($usbOk)  { 'Complete' } else { 'Failed' })" -ForegroundColor $(if ($usbOk)  { 'Green' } else { 'Red' }) }
if ($CollectHash){ Write-Host "  CollectHash $(if ($hashOk) { 'Complete' } else { 'Failed' })" -ForegroundColor $(if ($hashOk) { 'Green' } else { 'Red' }) }
Write-Host ""

if ($PrepUSB -and $usbOk) {
    Write-Host "  Next: Boot the target PC from the USB and complete the Windows 11 Pro install." -ForegroundColor Cyan
    Write-Host "        At OOBE, connect to the internet — Autopilot will take over automatically." -ForegroundColor Cyan
    Write-Host ""
}
