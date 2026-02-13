# Copies the staging folder to Z:\01-PCARCHIVE.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sourceRoot = "C:\Staging_Logmein_central"
$destinationRoot = "Z:\01-PCARCHIVE"

if (-not (Test-Path $sourceRoot)) {
    Write-Host "Source staging folder not found: $sourceRoot"
    exit 1
}

if (-not (Test-Path $destinationRoot)) {
    New-Item -Path $destinationRoot -ItemType Directory -Force | Out-Null
}

Write-Host ("Copying staging folder to destination: " + $destinationRoot)
Copy-Item -Path $sourceRoot -Destination $destinationRoot -Recurse -Force -ErrorAction Stop
Write-Host "Copy complete."
