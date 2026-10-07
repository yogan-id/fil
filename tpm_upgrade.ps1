# Detects current TPM firmware and runs the matching .BIN via HP TPMConfig64.exe
# Run (PowerShell as Administrator):
#   powershell -ExecutionPolicy Bypass -File .\tpm_upgrade.ps1

$ToolDir = $PSScriptRoot             # folder of this script (next to TPMConfig64.exe and .BIN files)
$DryRun  = $false                    # $true = only show what would be run

# --- 1. Administrator check ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrators")) {
    Write-Host "Please run PowerShell as Administrator." -ForegroundColor Red; exit 1
}

# --- 2. Current TPM version ---
$wmi = Get-CimInstance -Namespace root\cimv2\security\microsofttpm -ClassName Win32_Tpm
if (-not $wmi) { Write-Host "TPM not found (disabled in BIOS?)." -ForegroundColor Red; exit 1 }

$spec = ($wmi.SpecVersion -split ",")[0].Trim()
$fw   = (Get-Tpm).ManufacturerVersion
if (-not $fw) { $fw = $wmi.ManufacturerVersion }

Write-Host "TPM spec version : $spec"
Write-Host "TPM firmware     : $fw"

if ($spec -like "2.0*") { Write-Host "TPM is already 2.0 - nothing to do." -ForegroundColor Green; exit 0 }

# --- 3. Select firmware file ---
$bins = Get-ChildItem $ToolDir -Recurse -Filter "TPM12_*_to_TPM20_*.BIN"
$bin  = $bins | Where-Object { $_.Name -like "TPM12_${fw}_to_*" }          # exact match (6.41.197.0)
if (-not $bin) {
    $bin = $bins | Where-Object { $_.Name -like "TPM12_${fw}.*_to_*" }      # prefix match (6.41 -> 6.41.x)
}

if (-not $bin) {
    Write-Host "No firmware file for version $fw. Available:" -ForegroundColor Red
    $bins.Name | ForEach-Object { "  $_" }; exit 1
}
if (@($bin).Count -gt 1) {
    Write-Host "Version $fw is ambiguous, several files match:" -ForegroundColor Yellow
    $bin.Name | ForEach-Object { "  $_" }
    Write-Host "Check the full version with: tpmtool getdeviceinformation" -ForegroundColor Yellow; exit 1
}
Write-Host "Selected file    : $($bin.Name)" -ForegroundColor Cyan

# --- 4. Pre-flight checks ---
$bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
if ($bl -and $bl.VolumeStatus -ne "FullyDecrypted") {
    Write-Host "C: is encrypted with BitLocker ($($bl.VolumeStatus)). Run first: manage-bde -off C:" -ForegroundColor Red; exit 1
}

$exe = Get-ChildItem $ToolDir -Recurse -Filter "TPMConfig64.exe" | Select-Object -First 1
if (-not $exe) { Write-Host "TPMConfig64.exe not found in $ToolDir" -ForegroundColor Red; exit 1 }

# --- 5. Run ---
$cmdArgs = "-s -f`"$($bin.FullName)`""
Write-Host "Command: `"$($exe.FullName)`" $cmdArgs"
if ($DryRun) { Write-Host "DryRun: nothing was executed." -ForegroundColor Yellow; exit 0 }

Disable-TpmAutoProvisioning | Out-Null
$p = Start-Process $exe.FullName -ArgumentList $cmdArgs -WorkingDirectory $exe.DirectoryName -Wait -PassThru
Write-Host "TPMConfig64 exited with code $($p.ExitCode)."
Write-Host "Reboot the PC (confirm in BIOS if prompted), then run: Enable-TpmAutoProvisioning" -ForegroundColor Green
