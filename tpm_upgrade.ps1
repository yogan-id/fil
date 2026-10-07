# =====================================================================
#  tpm_upgrade.ps1
#  Finds the .BIN file that matches the current TPM firmware version
#  and runs the HP TPM Configuration Utility (TPMConfig64.exe) with it.
#
#  HOW TO RUN (without start.cmd):
#    1. Open PowerShell AS ADMINISTRATOR
#       (Start -> type "PowerShell" -> right click -> Run as administrator).
#       Admin rights are required: Get-Tpm does not work without them.
#    2. Go to the folder with this script, TPMConfig64.exe and the .BIN files:
#         cd C:\Users\pc\Desktop\1
#    3. Allow scripts in THIS window only (resets when the window is closed,
#       the system-wide policy is not changed):
#         Set-ExecutionPolicy Bypass -Scope Process -Force
#    4. Run the script (".\" = "from the current folder", PowerShell
#       does not run files from the current folder by name alone):
#         .\tpm_upgrade.ps1
#
#  BEFORE RUNNING: BitLocker on C: must be fully decrypted (manage-bde -off C:),
#  otherwise TPMConfig64 will refuse to update the TPM.
# =====================================================================


# $PSScriptRoot = full path of the folder where this script is located.
# We store it in $dir so the script works from any folder
# (Desktop\1, C:\1, USB stick...) without editing paths.
$dir = $PSScriptRoot


# Get-Tpm                 -> asks Windows for information about the TPM chip.
# .ManufacturerVersion    -> takes only the firmware version field from it,
#                            e.g. "6.41.197.0".
# The result is stored in $fw and used to choose the right .BIN file.
$fw = (Get-Tpm).ManufacturerVersion

# Write-Host -> prints text to the screen so you can see the detected version.
Write-Host "TPM firmware: $fw"


# Get-ChildItem $dir      -> lists files in the script folder.
# -Filter "..."           -> keeps only files whose name matches the pattern:
#                            TPM12_<current version>..._to_TPM20_....BIN
#                            ("*" = any characters). Example for 6.41.197.0:
#                            TPM12_6.41.197.0_to_TPM20_7.62.3126.0.BIN
# Select-Object -First 1  -> if several files match, take only the first one.
# The found file is stored in $bin.
$bin = Get-ChildItem $dir -Filter "TPM12_${fw}*_to_TPM20_*.BIN" | Select-Object -First 1


# if (-not $bin) -> "if no file was found".
# This happens when the TPM is already 2.0 (version 7.x) or when there is
# no .BIN for this firmware in the folder. Then we show a message and stop.
if (-not $bin) {
    Write-Host "No matching .BIN for firmware $fw (TPM may already be 2.0)." -ForegroundColor Red
    # exit 1 -> stop the script (1 = finished with an error).
    exit 1
}

# Show which file was selected (cyan text). Compare it with the version above.
Write-Host "File: $($bin.Name)" -ForegroundColor Cyan


# Start-Process "...TPMConfig64.exe" -> starts the HP utility from the script folder.
# -ArgumentList "-s -f"<file>""      -> parameters passed to the utility:
#       -s        = silent mode (no questions in the window)
#       -f"<file>" = firmware file to flash (full path of the selected .BIN,
#                    in quotes because the path may contain spaces)
#    NOTE: check these switches with "TPMConfig64.exe /?" or the HP ReadMe.
# -WorkingDirectory $dir -> the utility runs "inside" the script folder.
# -Wait                  -> PowerShell waits until TPMConfig64 has finished.
Start-Process "$dir\TPMConfig64.exe" -ArgumentList "-s -f`"$($bin.FullName)`"" -WorkingDirectory $dir -Wait

# After it finishes: reboot the PC. On startup the BIOS may ask to confirm
# the TPM change (press F1). Then check the result in PowerShell:
#   Get-Tpm   or   tpmtool getdeviceinformation   (version should be 7.62.x / TPM 2.0)
