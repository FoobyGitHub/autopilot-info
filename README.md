# autopilot-prep-W11

Windows 11 Pro deployment toolkit for Microsoft 365 Business Premium environments. Single PowerShell script, runs from an elevated prompt — nothing to install.

**`-PrepUSB`** — takes a Windows 11 USB created with Rufus and prepares it for deployment: forces Pro edition via `ei.cfg`, detects the CPU, and injects the appropriate Intel drivers into `boot.wim` and `install.wim`. Run once per USB on any machine with internet access.

**`-PatchISO`** — does the same to a Windows 11 ISO file and outputs a patched `.iso` ready to burn with Rufus. Patch once, burn as many times as needed.

**`-CollectHash`** — collects the device hardware hash and uploads it to Intune via Microsoft Graph. Run on the target device before or after the OS install.

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

There are two ways to get a prepped Windows 11 USB. Pick whichever suits your situation.

### Option A — Prep an existing USB (-PrepUSB)

For one-off builds or when you already have a USB to hand. Create the USB with Rufus first, then run `-PrepUSB` to inject Pro edition config and drivers.

> **Use Rufus, not the Microsoft Media Creation Tool.** MCT creates USBs in ESD format — drivers can't be injected into `install.wim` on an ESD USB. Boot disk detection will still be fixed, but the installed OS may BSOD on first boot on VMD-affected machines. Rufus creates WIM-format USBs which work properly.

**Creating the USB with [Rufus](https://rufus.ie):**

1. Download the Windows 11 ISO from [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11)
2. Plug in a USB drive (8 GB minimum)
3. Open Rufus and select the USB drive
4. Click **SELECT** and pick the Windows 11 ISO
5. When asked about **"Windows User Experience"** — leave everything unchecked and click **OK**
6. Leave all other settings as they are and click **START**
7. Confirm the USB will be wiped and wait for Rufus to finish

Once done, plug the USB into any PC with internet access and run `-PrepUSB`. The script picks it up automatically.

**What -PrepUSB does:**

1. Injects `ei.cfg` → forces Pro edition at setup, no edition selection screen
2. Detects the CPU → determines which driver sets are needed
3. Downloads the required drivers from this repo and injects them into `boot.wim` (so setup can see the hardware) and all indexes in `install.wim` (so the installed OS boots and operates correctly)

If you are prepping the USB on a different machine to the one being built, the CPU won't match the target and drivers may be skipped. Use `-ForceDrivers` to inject all driver sets regardless:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -ForceDrivers
```

### Option B — Pre-stage a golden ISO (-PatchISO)

Better for repeated deployments. Patch a Windows 11 ISO once on a fast machine, then burn it to as many USBs as you need — no per-USB script run required.

The ISO can also be hosted centrally (file share, Azure Blob, etc.) so the team is always burning from the same known-good image.

**Requirements:** Windows ADK Deployment Tools — installed automatically if not present (~200MB download). A 10-second warning is shown before anything is downloaded.

**Run:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-prep-W11/main/Invoke-AutopilotSetup.ps1))) -PatchISO
```

A file picker opens for the source ISO, then a folder picker for the output location. The script does the rest — Pro edition config, driver injection into both WIM files, and repacks to a new `.iso` file. Burn the output with Rufus.

> This feature is untested end-to-end. If you run into problems, [raise an issue](https://github.com/FoobyGitHub/autopilot-prep-W11/issues).

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

## Notes

- The script sets execution policy to `RemoteSigned` for the current user automatically — no need to sort this manually beforehand.
- The hardware hash CSV contains serial number, Windows product ID, and hardware hash only — no personal data.
- If a device was previously registered in Autopilot under a different tenant, deregister it there first before importing the hash.
