# Get-AutopilotHash.ps1
# Collects the Autopilot hardware hash and saves it to the desktop as autopilot.csv
# Run this on the target device. Right-click > Run with PowerShell, or run from an elevated prompt.

$OutputFile = "C:\Users\Public\Desktop\autopilot.csv"

Write-Host "`n[1/3] Setting execution policy..." -ForegroundColor Cyan
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

Write-Host "[2/3] Installing Get-WindowsAutopilotInfo script..." -ForegroundColor Cyan
Install-Script -Name Get-WindowsAutopilotInfo -Force

Write-Host "[3/3] Collecting hardware hash..." -ForegroundColor Cyan
Get-WindowsAutopilotInfo -OutputFile $OutputFile

if (Test-Path $OutputFile) {
    Write-Host "`nDone. File saved to: $OutputFile" -ForegroundColor Green
} else {
    Write-Host "`nSomething went wrong — file not found at $OutputFile" -ForegroundColor Red
}