# Deletes the staging folder to reset the machine state.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$stagingRoot = "C:\Staging_Logmein_central"

if (-not (Test-Path $stagingRoot)) {
    Write-Host "Staging folder not found: $stagingRoot"
    exit 0
}

Write-Host ("Deleting staging folder: " + $stagingRoot)
Remove-Item -Path $stagingRoot -Recurse -Force -ErrorAction Stop
Write-Host "Staging folder deleted."
