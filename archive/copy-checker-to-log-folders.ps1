# Copies copy-count-checker.ps1 into folders that have copy-log*.txt files.
# Usage: Run this script after Q:\ is available; it will search Q:\ for copy-log*.txt
# and copy copy-count-checker.ps1 into each matching folder.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = $PSScriptRoot
$sourceScript = Join-Path $scriptRoot "copy-count-checker.ps1"

if (-not (Test-Path $sourceScript)) {
    Write-Host "Source script not found: $sourceScript"
    exit 1
}

Write-Host "Searching for *PCARCHIVE* folders under Q:\ ..."
$archiveRoots = @()
$dirStack = New-Object System.Collections.Generic.Stack[string]
$dirStack.Push("Q:\")
$scannedCount = 0

while ($dirStack.Count -gt 0) {
    $currentDir = $dirStack.Pop()
    $scannedCount++
    Write-Progress -Activity "Scanning Q:\" -Status ("Scanning: " + $currentDir) -PercentComplete 0

    $subDirs = Get-ChildItem -Path $currentDir -Directory -ErrorAction SilentlyContinue
    foreach ($subDir in $subDirs) {
        if ($subDir.Name -like "*PCARCHIVE*") {
            $archiveRoots += $subDir
        }
        $dirStack.Push($subDir.FullName)
    }
}
Write-Progress -Activity "Scanning Q:\" -Completed
if (-not $archiveRoots) {
    Write-Host "No *PCARCHIVE* folders found under: Q:\"
    exit 1
}

$logFiles = @()
$totalArchives = $archiveRoots.Count
$archiveIndex = 0
foreach ($archiveRoot in $archiveRoots) {
    $archiveIndex++
    Write-Host ("Searching logs in {0} ({1}/{2})" -f $archiveRoot.FullName, $archiveIndex, $totalArchives)
    $logFiles += Get-ChildItem -Path $archiveRoot.FullName -Recurse -File -Filter "copy-log*.txt" -ErrorAction SilentlyContinue
}
if (-not $logFiles) {
    Write-Host "No copy-log*.txt files found under any *PCARCHIVE* folder."
    exit 0
}

$targetFolders = $logFiles | Select-Object -ExpandProperty DirectoryName -Unique
$totalTargets = $targetFolders.Count
$targetIndex = 0
foreach ($folder in $targetFolders) {
    $targetIndex++
    Write-Host ("Copying to {0} ({1}/{2})" -f $folder, $targetIndex, $totalTargets)
    $destination = Join-Path $folder "copy-count-checker.ps1"
    Copy-Item -Path $sourceScript -Destination $destination -Force -ErrorAction Stop
}

Write-Host ("Copied to " + $targetFolders.Count + " folder(s).")
