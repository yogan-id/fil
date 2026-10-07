# =====================================================================
#  tpm_upgrade.ps1  -  HP TPM 1.2 -> 2.0 upgrade (EliteBook 820/840 G3 etc.)
#
#  What it does:
#    1. Checks admin rights and that a TPM is present.
#    2. If TPM is already 2.0 -> re-enables Windows TPM auto-provisioning
#       and exits (so the SAME script finishes the job after the reboot).
#    3. Stops if C: is encrypted with BitLocker (HP requires full decryption).
#    4. Detects the current TPM firmware and selects the matching .BIN.
#    5. Disables TPM auto-provisioning and runs TPMConfig64.exe.
#    6. Writes everything to a log file and returns an exit code.
#
#  HOW TO RUN:
#    Double-click start.cmd   OR   in PowerShell as Administrator:
#      cd C:\auto
#      Set-ExecutionPolicy Bypass -Scope Process -Force
#      .\tpm_upgrade.ps1
#    After the reboot run it ONCE MORE - it will finish (step 2).
#
#  EXIT CODES (useful for Intune/SCCM):
#    0 = done / nothing to do      1 = general error (no admin, no TPM, no tool)
#    2 = BitLocker not decrypted   3 = no matching .BIN
#    4 = TPMConfig64 returned an error
# =====================================================================


# ---------------- SETTINGS ----------------
$dir        = $PSScriptRoot                         # folder with script, TPMConfig64.exe and .BIN files
$LogFile    = Join-Path $dir "tpm_upgrade.log"      # log file next to the script
$SilentArgs = "-s"                                  # TPMConfig64 silent switch (verify with: TPMConfig64.exe /?)
$AutoReboot = $false                                # $true = reboot automatically after flashing
# ------------------------------------------


# Log: prints a line to the screen AND appends it (with date/time) to the log file.
function Log($text, $color = "White") {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text
    Write-Host $text -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line
}

Log "===== Start on $env:COMPUTERNAME ====="


# --- 1. Administrator check ---
# IsInRole(BuiltInRole Administrator) -> $true only if the window runs as admin (works on any Windows language).
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Log "Run as Administrator." Red; exit 1 }


# --- 2. TPM information ---
# Win32_Tpm (WMI class) -> spec version ("1.2, 2, 3" or "2.0, 0, 1.38") and firmware versions.
$wmi = Get-CimInstance -Namespace root\cimv2\security\microsofttpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue
if (-not $wmi) { Log "TPM not found (disabled in BIOS?)." Red; exit 1 }

$spec = ($wmi.SpecVersion -split ",")[0].Trim()     # first number: "1.2" or "2.0"
Log "TPM spec version: $spec"

if ($spec -like "2.0*") {
    # Already 2.0 (e.g. second run after the reboot): give TPM control back to Windows.
    Enable-TpmAutoProvisioning | Out-Null
    Log "TPM is 2.0. Auto-provisioning re-enabled. Nothing else to do." Green
    exit 0
}


# --- 3. BitLocker check ---
# VolumeStatus must be "FullyDecrypted". "Suspended" is NOT enough for HP's utility.
$bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
if ($bl -and $bl.VolumeStatus -ne "FullyDecrypted") {
    Log "C: is $($bl.VolumeStatus) ($($bl.EncryptionPercentage)%). Decrypt first: manage-bde -off C:" Red
    exit 2
}


# --- 4. Firmware version and .BIN selection ---
# -replace '[^\d\.]','' keeps only digits and dots (Windows may return hidden characters).
$fw   = (Get-Tpm).ManufacturerVersion -replace '[^\d\.]',''        # short, e.g. 6.41
$full = $wmi.ManufacturerVersionFull20 -replace '[^\d\.]',''        # full, e.g. 6.41.197.0 (if available)
if ($full -match '^\d+\.\d+\.\d+\.\d+$') { $fw = $full }
Log "TPM firmware: $fw"

$exe = Join-Path $dir "TPMConfig64.exe"
if (-not (Test-Path $exe)) { Log "TPMConfig64.exe not found in $dir" Red; exit 1 }

# All .BIN files whose name starts with the current version.
$bins = @(Get-ChildItem -Path $dir -Filter "TPM12_$fw*_to_TPM20_*.BIN")

if ($bins.Count -eq 1) {
    # One exact match -> pass it explicitly with -f"<file>".
    Log "Selected file: $($bins[0].Name)" Cyan
    $toolArgs = "$SilentArgs -f`"$($bins[0].FullName)`""
}
elseif ($bins.Count -gt 1) {
    # Only short version known (e.g. 6.41 -> 197 and 198): let TPMConfig64 choose itself.
    Log "Several files match $fw - TPMConfig64 will choose the correct one." Yellow
    $toolArgs = $SilentArgs
}
else {
    Log "No matching .BIN for firmware $fw." Red
    exit 3
}


# --- 5. Flash ---
# Stop Windows from taking ownership of the TPM during/after the upgrade.
Disable-TpmAutoProvisioning | Out-Null

Log "Running: TPMConfig64.exe $toolArgs"
# -Wait = wait until the tool finishes; -PassThru = get its process to read ExitCode.
$p = Start-Process $exe -ArgumentList $toolArgs -WorkingDirectory $dir -Wait -PassThru
Log "TPMConfig64 exit code: $($p.ExitCode)"

if ($p.ExitCode -ne 0) {
    Log "TPMConfig64 reported an error. Check its log / message window." Red
    Enable-TpmAutoProvisioning | Out-Null          # roll back the Windows setting
    exit 4
}


# --- 6. Finish ---
Log "Flash done. Reboot, confirm in BIOS if asked (F1), then run this script again." Green
if ($AutoReboot) {
    Log "Rebooting in 30 seconds..."
    shutdown /r /t 30 /c "TPM firmware upgrade - reboot required"
}
exit 0
