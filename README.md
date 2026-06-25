# autopilot-info

Single-script Windows 11 Pro deployment toolkit for Microsoft 365 Business Premium / Intune / Autopilot environments.

---

## Usage

Run from an **elevated PowerShell prompt**. The script always sets the execution policy automatically before doing anything else, so you will not hit unsigned script errors with PSGallery.

**Base command — substitute the flag you need at the end:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) <flag>
```

Running with no flag prints a help screen with all available options and examples.

---

## Flags

| Flag | What it does |
|---|---|
| `-CollectHash` | Collect Autopilot hardware hash — auto-saves to USB or Public Desktop |
| `-PrepUSB` | Inject `ei.cfg` into a Windows 11 USB to force Pro edition |
| `-PrepUSB -CollectHash` | Do both in one run |
| `-DriveLetter E` | Force a specific drive letter with `-PrepUSB` |
| `-OutputPath C:\path\file.csv` | Override the hash CSV save location |

---

## Examples

```powershell
# Collect hardware hash (insert USB first — script auto-detects it)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -CollectHash

# Prep a Windows 11 USB for Pro install (auto-detects the USB)
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB

# Prep USB on drive E: explicitly
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -DriveLetter E

# Prep USB and collect hash in one shot
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -CollectHash
```

---

## Full deployment workflow

### 1. Collect hardware hashes

Insert a USB drive into the target device and run `-CollectHash`. The script saves `autopilot-<hostname>.csv` into an `AutopilotHashes\` folder on the USB. Multiple devices can share the same USB — each device writes its own file named after its hostname.

If no USB is present, the file is saved to the Public Desktop instead.

**Import into Intune once you have the CSVs:**

1. Open [Intune admin centre](https://intune.microsoft.com)
2. Go to **Devices > Enroll devices > Windows enrollment > Devices**
3. Click **Import** and upload each CSV
4. Wait 5–15 minutes for devices to appear

### 2. Prep the install USB

Write the Windows 11 ISO to a USB using the [Microsoft Media Creation Tool](https://www.microsoft.com/software-download/windows11) or [Rufus](https://rufus.ie), insert it into any PC, then run `-PrepUSB`.

**Why this is needed:** OEM machines often ship with Windows 11 Home. Autopilot requires Windows 11 Pro (included in Microsoft 365 Business Premium). The script injects an `ei.cfg` into the USB so Windows Setup installs Pro silently — no edition selection screen appears.

### 3. Clean install and OOBE

1. Boot the target PC from the prepared USB
2. Delete all existing partitions for a clean install
3. Windows 11 Pro installs automatically — no edition prompt
4. At OOBE, **connect to the internet** — Autopilot detects the registered device and takes over
5. The user signs in with their work account (`user@yourdomain.com`) and Intune enrols the device

---

## Requirements

| Requirement | Detail |
|---|---|
| Licence | Microsoft 365 Business Premium (includes Windows 11 Pro) |
| PowerShell | 5.1 or later |
| Elevation | Run as Administrator |
| Internet | Required for PSGallery (`Install-Script`) and Autopilot detection at OOBE |

## Notes

- The script sets `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force` automatically on every run, preventing PSGallery install failures on machines with a restrictive default policy.
- The `& ([scriptblock]::Create((irm ...)))` pattern runs the script in-memory — the file-based execution policy check does not apply, but the policy still needs to be set for `Install-Script` to work.
- The hash CSV contains serial number, Windows product ID, and hardware hash only — no personal data.
- If a device was previously registered in Autopilot under a different tenant, it must be deregistered there first.