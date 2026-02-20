# Stage Filter Size Report
# Uses the same filter logic as stage-filter-copy.ps1 to report how much data (GB) would match.
# No copying; read-only scan. Run locally or via LogMeIn Central.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Long path support for enumeration
function Get-LongPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $p = $Path.TrimEnd('\')
    if ($p.StartsWith("\\?\")) { return $p }
    if ($p.Length -ge 2 -and $p[1] -eq ':') { return "\\?\$p" }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
    if ($resolved.Length -ge 2 -and $resolved[1] -eq ':') { return "\\?\$resolved" }
    return $p
}

# Recursive enumeration (same as stage-filter-copy.ps1)
function Get-FilesRecursive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$AllowedExtensions = @(),
        [scriptblock]$ErrorCallback = $null
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @()
    }
    $longPath = Get-LongPath $Path
    $files = @()

    try {
        if (-not [System.IO.Directory]::Exists($longPath)) {
            return $files
        }
    } catch {
        if ($ErrorCallback) { & $ErrorCallback "Cannot access directory: $Path - $($_.Exception.Message)" }
        return $files
    }

    try {
        foreach ($file in [System.IO.Directory]::EnumerateFiles($longPath)) {
            try {
                $fileInfo = New-Object System.IO.FileInfo($file)
                if ($AllowedExtensions.Count -eq 0 -or
                    ($fileInfo.Extension -and $AllowedExtensions -contains $fileInfo.Extension.ToLowerInvariant())) {
                    $files += $fileInfo
                }
            } catch {
                if ($ErrorCallback) { & $ErrorCallback "Failed to process file: $file - $($_.Exception.Message)" }
            }
        }
    } catch {
        if ($ErrorCallback) { & $ErrorCallback "Failed to enumerate files in: $Path - $($_.Exception.Message)" }
    }

    try {
        foreach ($dir in [System.IO.Directory]::EnumerateDirectories($longPath)) {
            try {
                $subFiles = Get-FilesRecursive -Path $dir -AllowedExtensions $AllowedExtensions -ErrorCallback $ErrorCallback
                $files += $subFiles
            } catch {
                if ($ErrorCallback) { & $ErrorCallback "Failed to recurse into: $dir - $($_.Exception.Message)" }
            }
        }
    } catch {
        if ($ErrorCallback) { & $ErrorCallback "Failed to enumerate directories in: $Path - $($_.Exception.Message)" }
    }

    return $files
}

# ========== Filter configuration (must match stage-filter-copy.ps1) ==========
$allowedExtensions = @(
    ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic", ".heif", ".raw", ".svg",
    ".pdf",
    ".doc", ".docx", ".dot", ".dotx",
    ".xls", ".xlsx", ".xlt", ".xltx", ".csv",
    ".ppt", ".pptx", ".pot", ".potx",
    ".rtf",
    ".txt",
    ".md",
    ".one", ".onepkg",
    ".vsd", ".vsdx",
    ".zip"
)

$sourceSubfolders = @("Desktop", "Documents", "Pictures")
$usersRoot = "C:\Users"
$excludedUsers = @("Default", "Default User", "All Users", "DefaultAppPool", "WDAGUtilityAccount", "LogMeInRemoteUser")
$rootScanPath = "C:\"
$excludedRootPrefixes = @(
    "C:\Apps",
    "C:\Dell",
    "C:\Drivers",
    "C:\HP",
    "C:\inetpub",
    "C:\LocalStorage",
    "C:\SoftPaqDownloadDirectory",
    "C:\SWSETUP",
    "C:\Windows",
    "C:\Windows.old",
    "C:\Program Files",
    "C:\Program Files (x86)",
    "C:\ProgramData",
    "C:\Recovery"
)

# Report output path: C:\
$reportDir = "C:\"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportFile = Join-Path $reportDir ("stage-filter-report-" + $timestamp + ".txt")

$computerName = $env:COMPUTERNAME
if (-not $computerName) {
    $computerName = "Unknown"
}

$script:enumErrorCount = 0
$script:reportLines = @()

function Write-Report {
    param([string]$Message = "")
    $script:reportLines += $Message
    Write-Host $Message
}

Write-Report "=============================================="
Write-Report "Stage Filter Size Report"
Write-Report "=============================================="
Write-Report ("Computer: " + $computerName)
Write-Report ("Generated: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Write-Report ""
Write-Report "Filter conditions (same as stage-filter-copy.ps1):"
Write-Report "  Locations: C:\Users\<profile>\Desktop, Documents, Pictures; C:\ (excluding system folders)"
Write-Report ("  Extensions: " + ($allowedExtensions -join ", "))
Write-Report ""

$totalBytes = 0
$totalFileCount = 0
$byProfile = @{}
$byExtension = @{}
$rootBytes = 0
$rootFileCount = 0

# ----- User profiles (Desktop, Documents, Pictures) -----
$userProfiles = Get-ChildItem -Path $usersRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        ($excludedUsers -notcontains $_.Name) -and
        ($_.Name -notlike "LogMeInRemoteUser*")
    }

foreach ($profile in $userProfiles) {
    $profileBytes = 0
    $profileCount = 0

    foreach ($sub in $sourceSubfolders) {
        $sourcePath = Join-Path $profile.FullName $sub
        if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path $sourcePath)) { continue }

        $enumFiles = Get-FilesRecursive -Path $sourcePath -AllowedExtensions $allowedExtensions -ErrorCallback {
            param($msg)
            $script:enumErrorCount++
            Write-Report ("  [Warning] " + $msg)
        }

        foreach ($fileInfo in $enumFiles) {
            $profileBytes += $fileInfo.Length
            $profileCount++
            $ext = $fileInfo.Extension.ToLowerInvariant()
            if ($ext) {
                if (-not $byExtension.ContainsKey($ext)) {
                    $byExtension[$ext] = @{ Bytes = 0; Count = 0 }
                }
                $byExtension[$ext].Bytes += $fileInfo.Length
                $byExtension[$ext].Count++
            }
        }
    }

    if ($profileCount -gt 0) {
        $byProfile[$profile.Name] = @{ Bytes = $profileBytes; Count = $profileCount }
        $totalBytes += $profileBytes
        $totalFileCount += $profileCount
    }
}

# ----- Root drive (excluding users and system folders) -----
if (-not [string]::IsNullOrWhiteSpace($rootScanPath) -and (Test-Path $rootScanPath)) {
    $rootFolders = Get-ChildItem -Path $rootScanPath -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $fullName = $_.FullName
            (-not $fullName.StartsWith($usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
            (-not ($excludedRootPrefixes | Where-Object {
                $fullName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
            }))
        }

    foreach ($folder in $rootFolders) {
        $enumFiles = Get-FilesRecursive -Path $folder.FullName -AllowedExtensions $allowedExtensions -ErrorCallback {
            param($msg)
            $script:enumErrorCount++
            Write-Report ("  [Warning] " + $msg)
        }

        foreach ($fileInfo in $enumFiles) {
            $rootBytes += $fileInfo.Length
            $rootFileCount++
            $ext = $fileInfo.Extension.ToLowerInvariant()
            if ($ext) {
                if (-not $byExtension.ContainsKey($ext)) {
                    $byExtension[$ext] = @{ Bytes = 0; Count = 0 }
                }
                $byExtension[$ext].Bytes += $fileInfo.Length
                $byExtension[$ext].Count++
            }
        }
    }

    $totalBytes += $rootBytes
    $totalFileCount += $rootFileCount
}

# ----- Summary -----
$totalGB = [math]::Round($totalBytes / 1GB, 2)
$profileGB = [math]::Round(($totalBytes - $rootBytes) / 1GB, 2)
$rootGB = [math]::Round($rootBytes / 1GB, 2)

Write-Report "=============================================="
Write-Report "SUMMARY"
Write-Report "=============================================="
Write-Report ("Total size (filtered):  " + $totalGB + " GB  (" + $totalBytes + " bytes)")
Write-Report ("Total file count:        " + $totalFileCount)
Write-Report ("  From user profiles:    " + ($totalFileCount - $rootFileCount) + " files, " + $profileGB + " GB")
Write-Report ("  From root drive:       " + $rootFileCount + " files, " + $rootGB + " GB")
if ($script:enumErrorCount -gt 0) {
    Write-Report ("Enumeration warnings:   " + $script:enumErrorCount)
}
Write-Report ""

# Per-profile breakdown
if ($byProfile.Count -gt 0) {
    Write-Report "By user profile:"
    $byProfile.GetEnumerator() | Sort-Object { $_.Value.Bytes } -Descending | ForEach-Object {
        $gb = [math]::Round($_.Value.Bytes / 1GB, 2)
        Write-Report ("  " + $_.Key + ": " + $gb + " GB  (" + $_.Value.Count + " files)")
    }
    Write-Report ""
}

# By extension (top 15 by size)
if ($byExtension.Count -gt 0) {
    Write-Report "By extension (top 15 by size):"
    $byExtension.GetEnumerator() |
        ForEach-Object { [PSCustomObject]@{ Ext = $_.Key; Bytes = $_.Value.Bytes; Count = $_.Value.Count } } |
        Sort-Object Bytes -Descending |
        Select-Object -First 15 |
        ForEach-Object {
            $gb = [math]::Round($_.Bytes / 1GB, 2)
            Write-Report ("  " + $_.Ext + ": " + $gb + " GB  (" + $_.Count + " files)")
        }
}

Write-Report ""
Write-Report "=============================================="
Write-Report "End of report."

# Write report file (skip if path is empty to avoid ParameterBindingValidationException)
if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
    try {
        $script:reportLines | Out-File -FilePath $reportFile -Encoding UTF8
        Write-Host ""
        Write-Host ("Report saved to: " + $reportFile)
    } catch {
        Write-Host ""
        Write-Host ("Could not save report file: " + $_.Exception.Message)
    }
}

exit 0
