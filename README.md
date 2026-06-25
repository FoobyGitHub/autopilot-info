# autopilot-info

Single-script Windows 11 Pro deployment toolkit for Microsoft 365 Business Premium / Intune / Autopilot environments.

Designed for zero engineer decision-making: the script detects the hardware, downloads what it needs, and configures the USB automatically. The engineer runs one command and boots the machine.

---

## Commands

Run from an **elevated PowerShell prompt**. Copy the command for the task you need.

**Collect hardware hash** — insert a separate USB first, the script auto-detects it:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/FoobyGitHub/autopilot-info/main/Invoke-AutopilotSetup.ps1))) -CollectHash
```

**Prep a Windows 11 USB for Pro install** — auto-detects the USB, CPU, and injects VMD driver if needed:

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

## What `-PrepUSB` does automatically

Running `-PrepUSB` performs three steps with no engineer input required:

### 1. Forces Windows 11 Pro edition

Injects an `ei.cfg` file into the `sources\` folder on the USB. This tells Windows Setup to install Pro silently — no edition selection screen appears. Required because OEM machines often ship with Windows 11 Home, and Autopilot requires Pro (included in Microsoft 365 Business Premium).

### 2. Detects the CPU and determines VMD requirement

Reads the CPU model using `Win32_Processor` and classifies it:

| CPU type | VMD required |
|---|---|
| Intel 11th–14th gen (Tiger Lake → Raptor Lake Refresh) | Yes |
| Intel Core Ultra Series 1–2 (Meteor Lake / Arrow Lake / Lunar Lake) | Yes |
| Intel Core Ultra Series 3+ (15th gen and newer) | No |
| AMD / Qualcomm | No |

### 3. Downloads and injects the Intel VMD driver (if required)

If the CPU requires VMD, the script:

1. Fetches the current Intel RST driver download URL dynamically from Intel's product page — no version number is hardcoded
2. Downloads and extracts the driver package to a temp directory
3. Uses **inbox `dism.exe`** (`C:\Windows\System32\dism.exe`) — no Windows ADK required — to inject the VMD driver into `boot.wim` index 2 on the USB

Index 2 is the Windows Setup environment that runs during the *"Where do you want to install Windows?"* screen. With the driver pre-injected, the NVMe/VMD storage controller is visible to setup automatically. **The engineer never needs to click "Load Driver".**

If DISM injection fails for any reason, `-PrepUSB` reports **Failed** in the summary and stops. There is no silent fallback — the error message explains exactly what went wrong.

---

## USB detection

The script distinguishes between two types of USB drive automatically:

| Drive type | How it is detected | Used for |
|---|---|---|
| Windows 11 install USB | Contains `sources\boot.wim` | `-PrepUSB` targets this drive |
| Data USB (any other) | Any non-system drive without `boot.wim` | `-CollectHash` saves here |

You can have both plugged in at the same time and each flag will target the correct drive.

If `-CollectHash` finds no data USB, it falls back to saving the CSV to the Public Desktop.

> **Note:** The Microsoft Media Creation Tool labels the USB "ESD-USB" and does not always include `install.wim` or `install.esd` in `sources\`. Detection uses `sources\boot.wim` instead, which is always present regardless of how the USB was created.

---

## Full deployment workflow

### 1. Collect hardware hashes

Insert a data USB into the target device and run `-CollectHash`. The script saves `autopilot-<hostname>.csv` into an `AutopilotHashes\` folder on the USB. Multiple devices can share the same USB — each writes its own file named after its hostname. If no data USB is found, the file falls back to the Public Desktop.

**Import into Intune once you have the CSVs:**

1. Open [Intune admin centre](https://intune.microsoft.com)
2. Go to **Devices > Enroll devices > Windows enrollment > Devices**
3. Click **Import** and upload each CSV
4. Wait 5–15 minutes for devices to appear

### 2. Prep the install USB

Write the Windows 11 ISO to a USB using the [Microsoft Media Creation Tool](https://www.microsoft.com/software-download/windows11) or [Rufus](https://rufus.ie), insert it into any PC, then run `-PrepUSB`. The script handles everything — Pro edition, VMD driver — automatically.

### 3. Clean install and OOBE

1. Boot the target PC from the prepared USB
2. Delete all existing partitions for a clean install
3. Windows 11 Pro installs automatically — no edition prompt, no Load Driver prompt
4. At OOBE, **connect to the internet** — Autopilot detects the registered device and takes over
5. The user signs in with their work account (`user@yourdomain.com`) and Intune enrols the device

---

## Requirements

| Requirement | Detail |
|---|---|
| Licence | Microsoft 365 Business Premium (includes Windows 11 Pro) |
| PowerShell | 5.1 or later |
| Elevation | Run as Administrator |
| Internet | Required for Intel driver download, PSGallery, and Autopilot detection at OOBE |
| ADK | Not required — `dism.exe` is used from `C:\Windows\System32\` |

## Notes

- The script sets `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force` automatically, preventing PSGallery install failures on machines with a restrictive default policy.
- The hash CSV contains serial number, Windows product ID, and hardware hash only — no personal data.
- If a device was previously registered in Autopilot under a different tenant, it must be deregistered there first.
