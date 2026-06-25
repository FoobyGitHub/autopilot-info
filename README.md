# autopilot-info

Single-script Windows 11 Pro deployment toolkit for Microsoft 365 Business Premium / Intune / Autopilot environments.

The script sets the PowerShell execution policy automatically on every run, so you will not hit unsigned script errors when installing from PSGallery.

---

## Commands

Run from an **elevated PowerShell prompt**. Copy the command for the task you need.

**Collect hardware hash** — insert a USB first, the script auto-detects it:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -CollectHash
```

**Prep a Windows 11 USB for Pro install** — auto-detects the USB:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB
```

**Prep USB on a specific drive letter:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -DriveLetter E
```

**Both at once:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -PrepUSB -CollectHash
```

**No flags** — prints a help screen with all options and the above commands ready to copy.

---

## Full deployment workflow

### 1. Collect hardware hashes

Insert a USB drive into the target device and run `-CollectHash`. The script saves `autopilot-<hostname>.csv` into an `AutopilotHashes\` folder on the USB. Multiple devices can share the same USB — each writes its own file named after its hostname. If no USB is found, the file is saved to the Public Desktop instead.

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

- The hash CSV contains serial number, Windows product ID, and hardware hash only — no personal data.
- If a device was previously registered in Autopilot under a different tenant, it must be deregistered there first.