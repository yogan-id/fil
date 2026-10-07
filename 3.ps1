# =====================================================================
#  tpm_upgrade.ps1  -  HP TPM 1.2 -> 2.0 upgrade (EliteBook 820/840 G3 etc.)
#
#  What it does:
#    1. Checks admin rights and that a TPM is present.
#    2. If TPM is already 2.0 -> re-enables Windows TPM auto-provisioning
#       and exits (so the SAME script finishes the job after the reboot).
#    3. Stops if C: is encrypted with BitLocker (HP requires full decryption).
#    4. Detects the current TPM firmware and finds the matching .BIN files.
#    5. Runs TPMConfig64.exe silently with each matching file until one works
#       (for 6.41 HP says: try 6.41.197.0, if it fails use 6.41.198.0).
#    6. Writes everything to tpm_upgrade.log and returns an exit code.
#
#  HOW TO RUN:
#    Double-click start.cmd   OR   in PowerShell as Administrator:
#      cd C:\auto
#      Set-ExecutionPolicy Bypass -Scope Process -Force
#      .\tpm_upgrade.ps1
#    After the reboot run it ONCE MORE - it will finish (step 2).
#
#  EXIT CODES of this script (useful for Intune/SCCM):
#    0 = done / nothing to do      1 = general error (no admin, no TPM, no tool)
#    2 = BitLocker not decrypted   3 = no matching .BIN
#    4 = TPMConfig64 failed (reason is written to the log)
# =====================================================================


# ---------------- SETTINGS ----------------
$dir        = $PSScriptRoot                         # folder with script, TPMConfig64.exe and .BIN files
$LogFile    = Join-Path $dir "tpm_upgrade.log"      # our log file (TPMConfig64.log is written by HP tool)
$AutoReboot = $false                                # $true = reboot automatically after flashing
# ------------------------------------------


# Log: prints a line to the screen AND appends it (with date/time) to the log file.
function Log($text, $color = "White") {
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $text
    Write-Host $text -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line
}

# Meaning of TPMConfig64 exit codes (from HP documentation).
$HpCodes = @{
    0    = "Success"
    128  = "Invalid command line option"
    256  = "No BIOS support"
    257  = "No TPM firmware bin file"
    258  = "Failed to create HP_TOOLS partition"
    259  = "Failed to flash the firmware"
    260  = "No EFI partition (GPT)"
    261  = "Bad EFI partition"
    262  = "Cannot create HP_TOOLS partition (max partitions reached)"
    263  = "Not enough space on EFI/HP_TOOLS partition"
    264  = "Unsupported operating system"
    265  = "Administrator privileges are required"
    273  = "Not supported chipset"
    274  = "No more firmware upgrades allowed"
    275  = "Invalid firmware binary file (wrong .BIN for this TPM)"
    290  = "BitLocker is currently enabled - decrypt C: first"
    291  = "Unknown BitLocker status"
    292  = "WinMagic encryption is enabled"
    293  = "WinMagic SecureDoc is enabled"
    296  = "No system information"
    305  = "Intel TXT is enabled - disable it in BIOS"
    306  = "VTx is enabled - disable Virtualization Technology in BIOS"
    307  = "SGX is enabled - disable it in BIOS"
    1602 = "User cancelled the operation"
    3010 = "Success, reboot required"
    3011 = "Success rollback"
    3012 = "Failed rollback"
}

Log "===== Start on $env:COMPUTERNAME ====="


# --- 1. Administrator check (works on any Windows language) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Log "Run as Administrator." Red; exit 1 }


# --- 2. TPM information ---
# Win32_Tpm -> spec version ("1.2, 2, 3" or "2.0, 0, 1.38").
$wmi = Get-CimInstance -Namespace root\cimv2\security\microsofttpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue
if (-not $wmi) { Log "TPM not found (disabled in BIOS?)." Red; exit 1 }

$spec = ($wmi.SpecVersion -split ",")[0].Trim()
Log "TPM spec version: $spec"

if ($spec -like "2.0*") {
    # Already 2.0 (second run after the reboot): give TPM control back to Windows.
    Enable-TpmAutoProvisioning | Out-Null
    Log "TPM is 2.0. Auto-provisioning re-enabled. Nothing else to do." Green
    exit 0
}


# --- 3. BitLocker check ("Suspended" is NOT enough, must be FullyDecrypted) ---
$bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
if ($bl -and $bl.VolumeStatus -ne "FullyDecrypted") {
    Log "C: is $($bl.VolumeStatus) ($($bl.EncryptionPercentage)%). Decrypt first: manage-bde -off C:" Red
    exit 2
}


# --- 4. Firmware version and .BIN files ---
# -replace keeps only digits and dots (Windows may return hidden characters).
$fw = (Get-Tpm).ManufacturerVersion -replace '[^\d\.]',''      # e.g. 6.41
Log "TPM firmware: $fw"

$exe = Join-Path $dir "TPMConfig64.exe"
if (-not (Test-Path $exe)) { Log "TPMConfig64.exe not found in $dir" Red; exit 1 }

# All .BIN whose name starts with the current version, sorted (6.41.197 before 6.41.198).
$bins = @(Get-ChildItem -Path $dir -Filter "TPM12_$fw*_to_TPM20_*.BIN" | Sort-Object Name)
if ($bins.Count -eq 0) { Log "No matching .BIN for firmware $fw." Red; exit 3 }
Log "Candidate files: $($bins.Name -join ', ')" Cyan


# --- 5. Flash ---
# Stop Windows from taking ownership of the TPM during/after the upgrade.
Disable-TpmAutoProvisioning | Out-Null

$ok = $false
foreach ($b in $bins) {
    # HP syntax: -s = silent, -f<file> = firmware file name (no space, no quotes).
    # The tool runs in $dir, so the file name alone is enough.
    $toolArgs = "-s -f$($b.Name)"
    Log "Running: TPMConfig64.exe $toolArgs"
    $p    = Start-Process $exe -ArgumentList $toolArgs -WorkingDirectory $dir -Wait -PassThru
    $code = $p.ExitCode
    $desc = if ($HpCodes.ContainsKey($code)) { $HpCodes[$code] } else { "Unknown code" }
    Log "TPMConfig64 exit code: $code ($desc)"

    if ($code -in 0, 3010) { $ok = $true; Log "Success with $($b.Name)" Green; break }

    # Only "wrong file" errors are worth trying the next .BIN; anything else -> stop.
    if ($code -in 257, 275) { Log "Wrong file for this TPM, trying next one..." Yellow; continue }
    break
}

if (-not $ok) {
    Log "TPM upgrade failed. Details: TPMConfig64.log in $dir" Red
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
