# autopilot-prep-W11

Windows 11 Pro deployment toolkit for Microsoft 365 Business Premium environments. Single PowerShell script, runs from an elevated prompt — nothing to install.

**`-PrepUSB`** — takes a Windows 11 USB created with Rufus and prepares it for deployment: forces Pro edition via `ei.cfg`, detects the CPU, and injects the appropriate Intel drivers into `boot.wim` and `install.wim`. Run once per USB on any machine with internet access.

**`-PatchISO`** — does the same to a Windows 11 ISO file and outputs a patched `.iso` ready to burn with Rufus. Patch once, burn as many times as needed. This is the recommended approach for repeated deployments — pre-stage a single golden ISO on a fast prep machine, then burn it to as many USBs as needed with no further steps.

**`-CollectHash`** — collects the device hardware hash and uploads it to Intune via Microsoft Graph. Run on the target device before or after the OS install.

**`-ForceDrivers`** — use this when running `-PrepUSB` or `-PatchISO` on a different machine to the one being built. Driver detection reads the hardware on the machine running the script — if that's not the target, detection won't match and drivers will be skipped. `-ForceDrivers` bypasses detection and injects all four driver sets (VMD, Wi-Fi/BT, Chipset, Touchpad) regardless. For cross-machine prep this should be the default:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PatchISO -ForceDrivers
```

---

## Driver injection — what gets injected and when

The script detects the CPU and injects the appropriate driver sets automatically:

| CPU | What gets injected |
|---|---|
| Intel Core Ultra Series 2 (Arrow Lake) | VMD, Wi-Fi/BT, Chipset, Touchpad |
| Intel 11th–14th gen / Core Ultra Series 1 | VMD only |
| Intel 15th gen / Core Ultra Series 3+, AMD, Qualcomm | Nothing — not required |

**VMD** — Intel VMD manages NVMe storage on affected platforms. Without the driver, Windows setup either can't see the disk or BSODs on first boot with `INACCESSIBLE_BOOT_DEVICE`.

**Wi-Fi/BT** — Covers the Intel BE201 (Wi-Fi 7) and associated Bluetooth adapter on Arrow Lake machines where inbox Windows support may be absent at setup time.

**Chipset and Touchpad** — Arrow Lake platform drivers (Intel chipset INF and Asus touchpad stack) required for full hardware functionality on first boot.

All driver sets are injected into both `boot.wim` (so setup can see the hardware) and all indexes in `install.wim` (so the installed OS boots and operates correctly).

---

## Running the script on a different machine

Auto-detection works by querying the hardware on the machine running the script. If you are prepping a USB or patching an ISO on a separate PC — which is common, especially for `-PatchISO` — the target machine's hardware won't be visible.

In that case, use `-ForceDrivers` to inject all driver sets unconditionally, regardless of what's detected on the prep machine:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -ForceDrivers
```

Same flag applies to `-PatchISO -ForceDrivers`.

---

## Quick start

Open PowerShell as Administrator (right-click → Run as administrator) and copy the command you need.

**Collect hardware hash** — plug in a spare USB first, the script saves to it automatically:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -CollectHash
```

**Prep a Windows 11 USB** — auto-detects the USB, handles Pro edition and driver injection:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB
```

**Prep USB on a specific drive letter:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -DriveLetter E
```

**Both at once:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -CollectHash
```

**Pre-stage a patched ISO** — file and folder pickers open automatically:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PatchISO
```

**No flags** — prints a help screen with all options and the above commands ready to copy.

---

## Deployment workflows

### Deploying directly on the target machine

Run the script on the machine you are rebuilding. Detection reads the local CPU and injects only what that hardware needs — no flags required.

Create the USB with Rufus first (see below), then run `-PrepUSB` on the target machine. The script finds the USB automatically, injects `ei.cfg` and the appropriate drivers, then the machine is ready to reboot from it.

> **Use Rufus, not the Microsoft Media Creation Tool.** MCT creates USBs in ESD format — drivers can't be injected into `install.wim` on an ESD USB. Boot disk detection will still be fixed, but the installed OS may BSOD on first boot on VMD-affected machines. Rufus creates WIM-format USBs which work properly.

**Creating the USB with [Rufus](https://rufus.ie):**

1. Download the Windows 11 ISO from [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11)
2. Plug in a USB drive (8 GB minimum)
3. Open Rufus and select the USB drive
4. Click **SELECT** and pick the Windows 11 ISO
5. When asked about **"Windows User Experience"** — leave everything unchecked and click **OK**
6. Leave all other settings as they are and click **START**
7. Confirm the USB will be wiped and wait for Rufus to finish

**What `-PrepUSB` does:**

1. Injects `ei.cfg` → forces Pro edition at setup, no edition selection screen
2. Detects the CPU → determines which driver sets are needed
3. Downloads the required drivers from this repo and injects them into `boot.wim` (so setup can see the hardware) and all indexes in `install.wim` (so the installed OS boots and operates correctly)

### Building an image on a separate machine

Use this when you are prepping a USB or ISO on a different machine to the one being built — which is the normal workflow when deploying to multiple machines or when the target is being rebuilt from scratch.

Because detection reads the hardware of the machine running the script, it won't see the target's CPU. Use `-ForceDrivers` to inject all driver sets regardless of what's detected locally.

**Pre-staged USB** — create a Rufus USB as above, then run on your prep machine:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -ForceDrivers
```

**Pre-staged ISO** — patch a Windows 11 ISO once, then burn it to as many USBs as needed with Rufus — no per-USB script run required. The ISO can also be hosted centrally (file share, Azure Blob, etc.) so the team is always burning from the same known-good image.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PatchISO -ForceDrivers
```

A file picker opens for the source ISO, then a folder picker for the output location. The script injects Pro edition config and all driver sets into both WIM files, then repacks to a new `.iso`. Burn the output with Rufus.

**Requirements for `-PatchISO`:** Windows ADK Deployment Tools — installed automatically if not present (~200MB download). A 10-second warning is shown before anything is downloaded.

---

## Collecting the hardware hash

Plug a spare USB into the device and run `-CollectHash`. The hash is saved to `AutopilotHashes\autopilot-<hostname>.csv` on the USB. You can run this on multiple machines with the same USB — each device writes its own file.

If no spare USB is found, the file saves to the Public Desktop instead.

### Uploading to Intune

The script can upload the hash to Intune automatically via Microsoft Graph. There are two ways to authenticate:

**Device code (default — no setup needed)**

After collecting the hash, the script prints a short code and the URL `https://microsoft.com/devicelogin`. Open that URL in any browser, enter the code, and sign in with an account that has `DeviceManagementServiceConfig.ReadWrite.All` (delegated) in Microsoft Graph. The hash is uploaded once you authenticate.

If the upload fails or times out, the CSV is saved locally and the script tells you where it is and how to import it manually.

**Certificate auth (unattended — for automation)**

> Untested. [Raise an issue](https://github.com/FoobyGitHub/autopilot-prep-W11/issues) if you hit problems.

Requires an Entra ID App Registration with `DeviceManagementServiceConfig.ReadWrite.All` as an **application** permission (not delegated), and a certificate uploaded to the registration. The certificate private key needs to be in the local machine cert store on the machine running the script.

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -CollectHash -TenantId "your-tenant-id" -AppClientId "your-app-client-id" -AppCertThumbprint "your-cert-thumbprint"
```

**Setting up the App Registration:**

1. Entra ID → App registrations → New registration — name it something like `Autopilot Hash Upload`
2. API permissions → Add → Microsoft Graph → Application permissions → `DeviceManagementServiceConfig.ReadWrite.All` → Grant admin consent
3. Certificates & secrets → Certificates → upload your certificate public key (`.cer` file)
4. Note the Application (client) ID and your tenant ID
5. Install the certificate with its private key into the local machine cert store on the prep machine

**Manual import (if not using Graph upload):**

1. Open [Intune admin centre](https://intune.microsoft.com)
2. Devices → Enroll devices → Windows enrollment → Devices
3. Import → upload the CSV
4. Allow 5–15 minutes for the device to appear

---

## Full deployment steps

1. On the device being enrolled — run `-CollectHash` (plug in a USB first). The hash is saved to the USB or uploaded to Intune automatically.
2. On a separate machine — prep the install USB using Option A (`-PrepUSB`) or create a patched ISO using Option B (`-PatchISO`) and burn it with Rufus.
3. Boot the target device from the USB. Delete existing partitions if doing a clean install.
4. Windows 11 Pro installs — no edition prompt, no driver prompts.
5. At OOBE, connect to the internet. If the device hash is registered in Intune, Autopilot takes over automatically.
6. The user signs in with their work account and Intune enrols the device.

---

## Requirements

| | |
|---|---|
| Licence | Microsoft 365 Business Premium (includes Windows 11 Pro) |
| PowerShell | 5.1 or later (inbox on all supported Windows versions) |
| Elevation | Must run as Administrator |
| Internet | Needed for driver fetch from GitHub, hash upload, and Autopilot at OOBE |
| ADK | Not needed for `-PrepUSB` — only for `-PatchISO`, and installed automatically if missing |

---

## Logs

Every run writes a timestamped log file to:

`%TEMP%\AutopilotSetup_YYYYMMDD_HHMMSS.log`

On most machines that resolves to `C:\Users\<username>\AppData\Local\Temp\`. The log contains everything printed to the console during the run, with timestamps on each line. If something fails, the log file path is printed at the end of the session — share it when raising a bug.

---

## Notes

- The script sets execution policy to `RemoteSigned` for the current user automatically — no need to sort this manually beforehand.
- The hardware hash CSV contains serial number, Windows product ID, and hardware hash only — no personal data.
- If a device was previously registered in Autopilot under a different tenant, deregister it there first before importing the hash.

---

## WinPE Hash Collection (bare-metal devices)

This is for registering a device with Autopilot when there is no operating system installed and no spare laptop available to run `-CollectHash`. It boots the target device from a USB into WinPE, collects the hardware hash using oa3tool.exe, and uploads it directly to Intune via Microsoft Graph API — all before Windows is installed.

The USB also carries the PrepUSB content on a separate partition, so the technician can proceed with the full Windows build straight afterwards without swapping media.

This approach is not officially supported by Microsoft but is widely used in the community. The hash produced is the same 4K hardware hash that `Get-WindowsAutopilotInfo` generates — it just comes from WinPE instead of a running OS.

### Prerequisites

- **Windows ADK** installed on the admin machine — provides `oa3tool.exe` (found at `C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Licensing\OA30\oa3tool.exe`)
- **PCPKsp.dll** copied from a Windows 11 machine (`C:\Windows\System32\PCPKsp.dll`) — required for TPM data in the hash. Without it, the hash is still collected but may be incomplete.
- **OSDCloud** PowerShell module — used by `Build-WinPEUSB.ps1` to create the bootable USB
- **Entra app registration** with `DeviceManagementServiceConfig.ReadWrite.All` — created automatically by `New-AutopilotAppRegistration.ps1`

### Setup

1. **Run `New-AutopilotAppRegistration.ps1`** from an elevated PowerShell prompt. This creates the app registration in Entra, grants admin consent, creates a client secret, and writes credentials to `autopilot-appreg.config`. Requires Global Administrator or Application Administrator + Intune Administrator.

2. **Run `Build-WinPEUSB.ps1`** (coming soon) to build the bootable USB. This reads the config file, injects credentials into the WinPE scripts, and creates a dual-partition USB using OSDCloud.

3. **Boot the target device from the USB.** The hash collection and upload runs automatically.

### Security

- The public repo contains no credentials. Credentials are injected into the WinPE image at USB build time by `Build-WinPEUSB.ps1` and never appear in source control.
- `autopilot-appreg.config` is automatically added to `.gitignore`.
- The app registration has only `DeviceManagementServiceConfig.ReadWrite.All` — the minimum permission needed. It cannot read users, email, or anything else.
- Registering a device in Autopilot does not give it access to tenant resources. The device must still pass OOBE, Entra join, and Conditional Access.
- The client secret expires after 90 days. Re-run `New-AutopilotAppRegistration.ps1` and rebuild the USB to rotate.
- If the USB is lost, the only exposure is that someone could register device serial numbers in Autopilot. Revoke the client secret immediately via Entra > App registrations > AutopilotPrep-HashUpload > Certificates & secrets.

### File reference

| File | Description |
|---|---|
| `New-AutopilotAppRegistration.ps1` | Creates/validates the Entra app registration and outputs credentials |
| `WinPE/Invoke-AutopilotHash.ps1` | Runs in WinPE to collect and upload the hardware hash |
| `WinPE/oa3.cfg` | Configuration file for oa3tool.exe |
| `WinPE/README.md` | WinPE folder documentation |
| `Build-WinPEUSB.ps1` | (coming soon) Builds the bootable USB with injected credentials |

### Credits

- OA3Tool WinPE hash collection technique: [Mike Meierm](https://mikemdm.de/2023/01/29/can-you-create-a-autopilot-hash-from-winpe-yes/)
- WinPEAP project for demonstrating Graph API upload from WinPE: [blawalt](https://github.com/blawalt/WinPEAP)
- OSDCloud: [David Segura and the OSD community](https://www.osdcloud.com)
