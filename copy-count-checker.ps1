param(
    [Parameter(Mandatory = $false)][string]$Path,
    [Parameter(Mandatory = $false)][string]$LogFile,
    [Parameter(Mandatory = $false)][string]$LogDirectory,
    [Parameter(Mandatory = $false)][int]$ExpectedCount,
    [Parameter(Mandatory = $false)][int]$ToleranceCount,
    [Parameter(Mandatory = $false)][int]$TolerancePercent = 5,
    [Parameter(Mandatory = $false)][switch]$UseLogDestination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ExpectedFromLog {
    param([Parameter(Mandatory = $true)][string]$LogPath)

    $lines = Get-Content -Path $LogPath -ErrorAction Stop
    $planned = $lines | Where-Object { $_ -match "Planned files:\s+(\d+)" } | Select-Object -Last 1
    if ($planned -match "Planned files:\s+(\d+)") {
        return [int]$Matches[1]
    }
    return $null
}

function Get-CopiedFromLog {
    param([Parameter(Mandatory = $true)][string]$LogPath)

    $lines = Get-Content -Path $LogPath -ErrorAction Stop
    $copied = $lines | Where-Object { $_ -match "Copied files:\s+(\d+)" } | Select-Object -Last 1
    if ($copied -match "Copied files:\s+(\d+)") {
        return [int]$Matches[1]
    }
    return $null
}

function Get-DestinationFromLog {
    param([Parameter(Mandatory = $true)][string]$LogPath)

    $lines = Get-Content -Path $LogPath -ErrorAction Stop
    $dest = $lines | Where-Object { $_ -match "DestinationRoot:\s+(.+)$" } | Select-Object -Last 1
    if ($dest -match "DestinationRoot:\s+(.+)$") {
        return $Matches[1].Trim()
    }
    return $null
}

if (-not $Path) {
    $Path = (Get-Location).Path
}

if (-not $LogFile -and -not $LogDirectory) {
    $LogDirectory = (Get-Location).Path
}
if (-not $LogFile -and $LogDirectory) {
    if (-not (Test-Path $LogDirectory)) {
        Write-Host "Log directory not found: $LogDirectory"
        exit 1
    }
    $LogFile = Get-ChildItem -Path $LogDirectory -Filter "copy-log-*.txt" -File -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $LogFile) {
        Write-Host "No copy-log-*.txt files found in: $LogDirectory"
        exit 1
    }
}
if ($LogFile -and -not (Test-Path $LogFile)) {
    Write-Host "Log file not found: $LogFile"
    exit 1
}
if ($UseLogDestination -and $LogFile) {
    $Path = Get-DestinationFromLog -LogPath $LogFile
    if (-not $Path) {
        Write-Host "DestinationRoot not found in log file."
        exit 1
    }
}

if (-not (Test-Path $Path)) {
    Write-Host "Target path not found: $Path"
    exit 1
}

$plannedCount = $null
$copiedCount = $null
if ($LogFile) {
    $plannedCount = Get-ExpectedFromLog -LogPath $LogFile
    $copiedCount = Get-CopiedFromLog -LogPath $LogFile
    if (-not $ExpectedCount) {
        $ExpectedCount = $plannedCount
    }
}

$actualCount = (Get-ChildItem -Path $Path -Recurse -File -ErrorAction Stop).Count

Write-Host ("Path: " + $Path)
Write-Host ("Actual files: " + $actualCount)

if ($copiedCount -ne $null) {
    Write-Host ("Copied files (log): " + $copiedCount)
}
if ($ExpectedCount -ne $null) {
    Write-Host ("Planned files (log): " + $ExpectedCount)
}

if ($ExpectedCount -ne $null) {
    $diff = [Math]::Abs($actualCount - $ExpectedCount)
    if ($ToleranceCount -eq $null -or $ToleranceCount -lt 0) {
        $ToleranceCount = [Math]::Floor(($ExpectedCount * $TolerancePercent) / 100)
    }
    Write-Host ("Difference: " + $diff)
    Write-Host ("Tolerance: " + $ToleranceCount + " files (" + $TolerancePercent + "%)")
    if ($diff -le $ToleranceCount) {
        Write-Host "Close enough: True"
        exit 0
    }
    Write-Host "Close enough: False"
    exit 2
}

Write-Host "Expected files: (not provided)"
exit 0
