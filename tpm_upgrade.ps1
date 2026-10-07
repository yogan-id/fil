# Finds the .BIN matching the current TPM firmware and runs TPMConfig64.exe with it
$dir = $PSScriptRoot

# Current TPM firmware version, e.g. 6.41.197.0
$fw = (Get-Tpm).ManufacturerVersion
Write-Host "TPM firmware: $fw"

# Matching firmware file
$bin = Get-ChildItem $dir -Filter "TPM12_${fw}*_to_TPM20_*.BIN" | Select-Object -First 1
if (-not $bin) {
    Write-Host "No matching .BIN for firmware $fw (TPM may already be 2.0)." -ForegroundColor Red
    exit 1
}
Write-Host "File: $($bin.Name)" -ForegroundColor Cyan

# Run HP TPM Configuration Utility with the selected file
Start-Process "$dir\TPMConfig64.exe" -ArgumentList "-s -f`"$($bin.FullName)`"" -WorkingDirectory $dir -Wait
