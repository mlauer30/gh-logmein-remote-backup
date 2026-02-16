# Copies the staging folder to Z:\01-PCARCHIVE.
# LogMeIn Central: Upload a config .ps1 as the first file. It must define:
#   $netIP, $netUser, $netPass
# netPath is built as: $netIP + propertyFolder (from C:\PcDetails.json).
# Example config.ps1:
#   $netIP = "\\192.168.0.1\"
#   $netUser = "superuser-role"
#   $netPass = "superuser-password"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

# Load config from uploaded file (LogMeIn Central $central_Files)
if ($central_Files -and $central_Files.Count -gt 0) {
    . $central_Files[0]
    if (-not ($netIP -and $netUser -and $netPass)) {
        Write-Host "Config file must define `$netIP, `$netUser, `$netPass"
        exit 1
    }
} else {
    Write-Host "No config file uploaded. Define `$central_Files or run with uploaded config.ps1"
    exit 1
}

# Get propertyFolder from C:\PcDetails.json and build netPath
$pcDetailsPath = "C:\PcDetails.json"
if (-not (Test-Path $pcDetailsPath)) {
    Write-Host "PcDetails.json not found: $pcDetailsPath"
    exit 1
}
$pcDetails = Get-Content -Path $pcDetailsPath -Raw | ConvertFrom-Json
$netPropertyFolder = $pcDetails.propertyFolder
if (-not $netPropertyFolder) {
    Write-Host "PcDetails.json must contain propertyFolder."
    exit 1
}
$netPropertyFolder = $netPropertyFolder.Trim()
$netPath = ($netIP.TrimEnd('\') + '\' + $netPropertyFolder.TrimStart('\'))

$sourceRoot = "C:\Staging_Logmein_central"
$destinationRoot = "Z:\01-PCARCHIVE"

if (-not (Test-Path $sourceRoot)) {
    Write-Host "Source staging folder not found: $sourceRoot"
    exit 1
}

# Run net use + robocopy in one cmd.exe process (share mapping across commands)
Write-Host "Mapping Z: drive to $netPath and copying..."
$batchContent = @"
@echo off
net use Z: /delete 2>nul
net use Z: "$netPath" /user:$netUser "$netPass" /persistent:yes
if errorlevel 1 (echo Net use failed. & exit /b 1)
if not exist "$destinationRoot" mkdir "$destinationRoot"
robocopy "$sourceRoot" "$destinationRoot" /E /NFL /NDL /NJH /NJS
exit /b 0
"@
$batchPath = Join-Path $env:TEMP "copy-to-z-archive.bat"
$batchContent | Out-File -FilePath $batchPath -Encoding ASCII -Force
cmd /c "`"$batchPath`""
$exitCode = $LASTEXITCODE
Remove-Item $batchPath -Force -ErrorAction SilentlyContinue
if ($exitCode -ge 8) { Write-Host "Robocopy error: $exitCode"; exit 1 }
Write-Host "Copy complete."
