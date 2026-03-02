# RUN COMMAND in LogMeIn Central (PowerShell 2.0 compatible) and compatible with Windows 7.
# Strategy: Records first, then Images. 30GB limit. Images over limit are logged and reported (not copied).
# No PcDetails.json; destination is C:\Staging_Logmein_central\<COMPUTERNAME>.

param(
    [string]$ContentType = "All"
)

# PS2: -Version 2; avoid Latest
if ($PSVersionTable.PSVersion.Major -ge 2) {
    Set-StrictMode -Version 2
}
$ErrorActionPreference = "Stop"

# Long path support: use \\?\ prefix so paths > 260 chars work when copying/creating dirs
function Get-LongPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $p = $Path.TrimEnd('\')
    if ($p.StartsWith("\\?\")) { return $p }
    if ($p.Length -ge 2 -and $p[1] -eq ':') { return "\\?\$p" }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
    if ($resolved.Length -ge 2 -and $resolved[1] -eq ':') { return "\\?\$resolved" }
    return $p
}

# Flatten destination path if it exceeds maximum length. Hash the full logical path so every file is unique.
function Get-FlattenedDestinationPath {
    param(
        [string]$DestinationRoot,
        [string]$RelativePath,
        [int]$MaxLength
    )
    $fullPath = Join-Path $DestinationRoot $RelativePath
    $pathLength = $fullPath.Length
    if ($pathLength -le $MaxLength) {
        return @{ DestinationPath = $fullPath; WasFlattened = $false; OriginalPath = $fullPath }
    }
    $uniqueKey = $fullPath
    $pathHashSuffix = ""
    $folderHash = ""
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hb = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($uniqueKey))
            $fullHashHex = [BitConverter]::ToString($hb).Replace("-", "")
            $pathHashSuffix = $fullHashHex
            $folderHash = $fullHashHex.Substring(0, 16)
        } finally { $sha.Dispose() }
    } catch {
        $h1 = [Math]::Abs($uniqueKey.GetHashCode())
        $h2 = [Math]::Abs(($uniqueKey.Length * 31 + $uniqueKey.GetHashCode()).GetHashCode())
        $pathHashSuffix = ($h1.ToString("X8") + $h2.ToString("X8"))
        $folderHash = $pathHashSuffix.Substring(0, 16)
    }
    $parts = $RelativePath.Split([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fileName = $parts[-1]
    $extension = [IO.Path]::GetExtension($fileName)
    $nameWithoutExt = [IO.Path]::GetFileNameWithoutExtension($fileName)
    $shortSuffix = $pathHashSuffix.Substring(0, [Math]::Min(24, $pathHashSuffix.Length))
    $keepLevels = 2
    if ($parts.Count -le $keepLevels + 1) {
        $maxFileNameLength = $MaxLength - $DestinationRoot.Length - 50
        if ($maxFileNameLength -lt 30) { $maxFileNameLength = 30 }
        if ($fileName.Length -gt $maxFileNameLength) {
            $truncatedName = $nameWithoutExt.Substring(0, [Math]::Min($nameWithoutExt.Length, $maxFileNameLength - $extension.Length - $shortSuffix.Length - 2)) + "_" + $shortSuffix + $extension
            $flattenedPath = Join-Path $DestinationRoot $truncatedName
        } else {
            $flattenedPath = Join-Path $DestinationRoot ($nameWithoutExt + "_" + $shortSuffix + $extension)
        }
        return @{ DestinationPath = $flattenedPath; WasFlattened = $true; OriginalPath = $fullPath }
    }
    $basePath = $DestinationRoot
    for ($i = 0; $i -lt [Math]::Min($keepLevels, $parts.Count - 1); $i++) {
        $basePath = Join-Path $basePath $parts[$i]
    }
    $hashFolder = Join-Path $basePath ("_flat_" + $folderHash)
    $flattenedPath = Join-Path $hashFolder $fileName
    if ($flattenedPath.Length -gt $MaxLength) {
        $parentPath = Split-Path $flattenedPath -Parent
        $maxFileNameLength = $MaxLength - $parentPath.Length - 5
        if ($maxFileNameLength -gt 30) {
            $truncatedName = $nameWithoutExt.Substring(0, [Math]::Min($nameWithoutExt.Length, $maxFileNameLength - $extension.Length - $shortSuffix.Length - 2)) + "_" + $shortSuffix + $extension
            $flattenedPath = Join-Path $parentPath $truncatedName
        } else {
            $flattenedPath = Join-Path $parentPath ($shortSuffix + $extension)
        }
    }
    return @{ DestinationPath = $flattenedPath; WasFlattened = $true; OriginalPath = $fullPath }
}

$stagingRoot = "C:\Staging_Logmein_central"
$maxTotalBytes = 30GB
$maxRunMinutes = 30
# Maximum destination path length (e.g. network share limits)
$maxDestinationPathLength = 200

if (-not $stagingRoot) {
    Write-Host "Staging root path is empty."
    exit 1
}

if (-not (Test-Path $stagingRoot)) {
    New-Item -Path $stagingRoot -ItemType Directory -Force | Out-Null
}

$computerName = $env:COMPUTERNAME
if (-not $computerName) {
    Write-Host "Computer name not found."
    exit 1
}

# Destination: staging\<COMPUTERNAME> (no PcDetails mapping)
$destinationBase = Join-Path $stagingRoot $computerName
if (-not $destinationBase) {
    Write-Host "Destination base is empty."
    exit 1
}

# Validate ContentType (PS2 has no ValidateSet)
if ($ContentType -ne "Records" -and $ContentType -ne "Images" -and $ContentType -ne "All") {
    $ContentType = "All"
}

# Records vs Images: same strategy as stage-filter-copy.ps1
$recordExtensions = @(
    ".pdf",
    ".doc", ".docx", ".dot", ".dotx",
    ".xls", ".xlsx", ".xlt", ".xltx", ".csv",
    ".ppt", ".pptx", ".pot", ".potx",
    ".rtf", ".txt", ".md",
    ".one", ".onepkg", ".vsd", ".vsdx",
    ".zip"
)
$imageExtensions = @(
    ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic", ".heif", ".raw", ".svg"
)
$allowedExtensions = $recordExtensions + $imageExtensions
if ($ContentType -eq "Records") { $allowedExtensions = $recordExtensions }
if ($ContentType -eq "Images")  { $allowedExtensions = $imageExtensions  }

$sourceSubfolders = @("Desktop", "Documents", "Pictures")
$usersRoot = "C:\Users"
$excludedUsers = @("Default", "Default User", "All Users", "DefaultAppPool", "WDAGUtilityAccount", "LogMeInRemoteUser")
$rootScanPath = "C:\"
$rootCopyFolderName = "_RootDrive"
$excludedRootPrefixes = @(
    "C:\Apps", "C:\Dell", "C:\Drivers", "C:\HP", "C:\inetpub",
    "C:\LocalStorage", "C:\SoftPaqDownloadDirectory", "C:\SWSETUP",
    "C:\Windows", "C:\Windows.old", "C:\Program Files", "C:\Program Files (x86)",
    "C:\ProgramData", "C:\Recovery"
)

# When All: log under destinationBase; subfolders Records and Images
$logDestinationRoot = $destinationBase
if ($ContentType -eq "Records" -or $ContentType -eq "Images") {
    $destinationRoot = Join-Path $destinationBase $ContentType
} else {
    $destinationRoot = $destinationBase
}

if (-not (Test-Path $logDestinationRoot)) {
    New-Item -Path $logDestinationRoot -ItemType Directory -Force | Out-Null
}
if ($ContentType -ne "All" -and -not (Test-Path $destinationRoot)) {
    New-Item -Path $destinationRoot -ItemType Directory -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $logDestinationRoot ("copy-log-" + $timestamp + ".txt")
$imagesNotRetainedReportFile = Join-Path $logDestinationRoot ("images-not-retained-" + $timestamp + ".txt")
$script:imagesNotRetainedList = @()

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $logFile -Value $line
}

$jobStart = Get-Date
$jobEnd = $jobStart.AddMinutes($maxRunMinutes)
$script:timeLimitReached = $false
function Test-TimeLimit {
    if ((Get-Date) -ge $jobEnd) {
        if (-not $script:timeLimitReached) {
            Write-Log ("Time limit reached; stopping copy job. Limit minutes: " + $maxRunMinutes)
        }
        $script:timeLimitReached = $true
        return $true
    }
    return $false
}

# PS2: Get-ChildItem -Recurse; filter by container for dirs
$userProfiles = Get-ChildItem -Path $usersRoot -ErrorAction SilentlyContinue |
    Where-Object { $_.PSIsContainer } |
    Where-Object {
        ($excludedUsers -notcontains $_.Name) -and
        ($_.Name -notlike "LogMeInRemoteUser*")
    }

$matchedCount = 0
$copiedCount = 0
$errorCount = 0
$totalBytes = 0
$script:overflowImageCount = 0

Write-Log "Copy job started."
Write-Log ("ContentType: " + $ContentType)
Write-Log ("ComputerName: " + $computerName)
Write-Log ("DestinationRoot: " + $destinationRoot)
if ($ContentType -eq "All") {
    Write-Log ("Images over " + $maxTotalBytes + " will be logged and reported (not copied).")
}

if ($ContentType -eq "All") {
    # ---------- Phase 1: Records first (up to 30GB) ----------
    $phase1DestRoot = Join-Path $destinationBase "Records"
    if (-not (Test-Path $phase1DestRoot)) {
        New-Item -Path $phase1DestRoot -ItemType Directory -Force | Out-Null
    }
    Write-Log "Phase 1 (Records) started. Destination: $phase1DestRoot"

    foreach ($profile in $userProfiles) {
        if (Test-TimeLimit) { break }
        foreach ($sub in $sourceSubfolders) {
            if (Test-TimeLimit) { break }
            $sourcePath = Join-Path $profile.FullName $sub
            if (-not (Test-Path $sourcePath)) { continue }

            Get-ChildItem -Path $sourcePath -Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Where-Object {
                    $ext = $_.Extension.ToLower()
                    $recordExtensions -contains $ext
                } |
                ForEach-Object {
                    if (Test-TimeLimit) { break }
                    $matchedCount++
                    if ($totalBytes -ge $maxTotalBytes) { return }
                    $relativePath = $_.FullName.Substring($sourcePath.Length).TrimStart("\")
                    $destFolder = Join-Path $phase1DestRoot (Join-Path $profile.Name $sub)
                    $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                    $destFile = $pathInfo.DestinationPath
                    $destDir = Split-Path $destFile -Parent
                    $sourceFile = $_.FullName
                    try {
                        [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
                        $fileSize = $_.Length
                        if (($totalBytes + $fileSize) -gt $maxTotalBytes) {
                            Write-Log ("Skipping file due to size cap: " + $sourceFile)
                            return
                        }
                        [System.IO.File]::Copy((Get-LongPath $sourceFile), $destFile, $true)
                        $copiedCount++
                        $totalBytes += $fileSize
                    } catch {
                        $errorCount++
                        Write-Log ("Copy failed: " + $sourceFile + " -> " + $destFile + " | " + $_.Exception.Message)
                    }
                }
        }
        if ($script:timeLimitReached) { break }
    }

    Write-Log "Root drive scan started (Phase 1 - Records)."
    if ((-not (Test-TimeLimit)) -and (Test-Path $rootScanPath)) {
        $rootFolders = Get-ChildItem -Path $rootScanPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer } |
            Where-Object {
                $fullName = $_.FullName
                (-not $fullName.StartsWith($stagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not $fullName.StartsWith($usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not ($excludedRootPrefixes | Where-Object { $fullName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }))
            }
        foreach ($folder in $rootFolders) {
            if (Test-TimeLimit) { break }
            if ($totalBytes -ge $maxTotalBytes) { break }
            Get-ChildItem -Path $folder.FullName -Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Where-Object { $recordExtensions -contains $_.Extension.ToLower() } |
                ForEach-Object {
                    if (Test-TimeLimit) { break }
                    $matchedCount++
                    if ($totalBytes -ge $maxTotalBytes) { return }
                    $relativePath = $_.FullName.Substring($rootScanPath.Length).TrimStart("\")
                    $destFolder = Join-Path $phase1DestRoot $rootCopyFolderName
                    $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                    $destFile = $pathInfo.DestinationPath
                    $destDir = Split-Path $destFile -Parent
                    $sourceFile = $_.FullName
                    try {
                        [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
                        $fileSize = $_.Length
                        if (($totalBytes + $fileSize) -gt $maxTotalBytes) {
                            Write-Log ("Skipping file due to size cap: " + $sourceFile)
                            return
                        }
                        [System.IO.File]::Copy((Get-LongPath $sourceFile), $destFile, $true)
                        $copiedCount++
                        $totalBytes += $fileSize
                    } catch {
                        $errorCount++
                        Write-Log ("Copy failed: " + $sourceFile + " -> " + $destFile + " | " + $_.Exception.Message)
                    }
                }
        }
    }
    Write-Log "Phase 1 (Records) finished."

    # ---------- Phase 2: Images; over limit = log + report only ----------
    $imagesStagingRoot = Join-Path $destinationBase "Images"
    if (-not (Test-Path $imagesStagingRoot)) {
        New-Item -Path $imagesStagingRoot -ItemType Directory -Force | Out-Null
    }
    $script:imagePhaseOverLimit = $false
    Write-Log "Phase 2 (Images) started. Images over limit will be logged and reported (not copied)."

    foreach ($profile in $userProfiles) {
        if (Test-TimeLimit) { break }
        foreach ($sub in $sourceSubfolders) {
            if (Test-TimeLimit) { break }
            $sourcePath = Join-Path $profile.FullName $sub
            if (-not (Test-Path $sourcePath)) { continue }

            Get-ChildItem -Path $sourcePath -Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Where-Object { $imageExtensions -contains $_.Extension.ToLower() } |
                ForEach-Object {
                    if (Test-TimeLimit) { break }
                    $matchedCount++
                    $fileSize = $_.Length
                    $sourceFile = $_.FullName

                    if (-not $script:imagePhaseOverLimit -and ($totalBytes + $fileSize -gt $maxTotalBytes)) {
                        $script:imagePhaseOverLimit = $true
                        Write-Log ("Size limit reached (" + $maxTotalBytes + "); remaining images will be logged as not retained (not copied).")
                    }

                    if ($script:imagePhaseOverLimit) {
                        $script:overflowImageCount++
                        $script:imagesNotRetainedList += ($sourceFile + "|" + $fileSize)
                        Write-Log ("Image not retained (over limit): " + $sourceFile + " (" + $fileSize + " bytes)")
                        return
                    }

                    $relativePath = $_.FullName.Substring($sourcePath.Length).TrimStart("\")
                    $destFolder = Join-Path $imagesStagingRoot (Join-Path $profile.Name $sub)
                    $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                    $destFile = $pathInfo.DestinationPath
                    $destDir = Split-Path $destFile -Parent
                    try {
                        [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
                        [System.IO.File]::Copy((Get-LongPath $sourceFile), $destFile, $true)
                        $copiedCount++
                        $totalBytes += $fileSize
                    } catch {
                        $errorCount++
                        Write-Log ("Copy failed: " + $sourceFile + " -> " + $destFile + " | " + $_.Exception.Message)
                    }
                }
        }
        if ($script:timeLimitReached) { break }
    }

    Write-Log "Root drive scan started (Phase 2 - Images)."
    if ((-not (Test-TimeLimit)) -and (Test-Path $rootScanPath)) {
        $rootFolders = Get-ChildItem -Path $rootScanPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer } |
            Where-Object {
                $fullName = $_.FullName
                (-not $fullName.StartsWith($stagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not $fullName.StartsWith($usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not ($excludedRootPrefixes | Where-Object { $fullName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }))
            }
        foreach ($folder in $rootFolders) {
            if (Test-TimeLimit) { break }
            Get-ChildItem -Path $folder.FullName -Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Where-Object { $imageExtensions -contains $_.Extension.ToLower() } |
                ForEach-Object {
                    if (Test-TimeLimit) { break }
                    $matchedCount++
                    $fileSize = $_.Length
                    $sourceFile = $_.FullName

                    if (-not $script:imagePhaseOverLimit -and ($totalBytes + $fileSize -gt $maxTotalBytes)) {
                        $script:imagePhaseOverLimit = $true
                        Write-Log ("Size limit reached (" + $maxTotalBytes + "); remaining images will be logged as not retained (not copied).")
                    }

                    if ($script:imagePhaseOverLimit) {
                        $script:overflowImageCount++
                        $script:imagesNotRetainedList += ($sourceFile + "|" + $fileSize)
                        Write-Log ("Image not retained (over limit): " + $sourceFile + " (" + $fileSize + " bytes)")
                        return
                    }

                    $relativePath = $_.FullName.Substring($rootScanPath.Length).TrimStart("\")
                    $destFolder = Join-Path $imagesStagingRoot $rootCopyFolderName
                    $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                    $destFile = $pathInfo.DestinationPath
                    $destDir = Split-Path $destFile -Parent
                    try {
                        [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
                        [System.IO.File]::Copy((Get-LongPath $sourceFile), $destFile, $true)
                        $copiedCount++
                        $totalBytes += $fileSize
                    } catch {
                        $errorCount++
                        Write-Log ("Copy failed: " + $sourceFile + " -> " + $destFile + " | " + $_.Exception.Message)
                    }
                }
        }
    }
    Write-Log "Phase 2 (Images) finished."
    Write-Log ("Images not retained (over size limit): " + $script:overflowImageCount)

    # Write images-not-retained report (PS2: no Measure-Object -Sum on property; sum manually)
    if ($script:overflowImageCount -gt 0 -and $script:imagesNotRetainedList.Count -gt 0) {
        $notRetainedBytes = 0
        foreach ($entry in $script:imagesNotRetainedList) {
            $parts = $entry -split "\|", 2
            if ($parts.Length -eq 2) { $notRetainedBytes += [long]$parts[1] }
        }
        $reportLines = @(
            "Images not retained (over " + $maxTotalBytes + " total staging limit)",
            "Generated: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
            "Computer: " + $computerName,
            "Total count: " + $script:overflowImageCount,
            "Total size (bytes): " + $notRetainedBytes,
            "Total size (GB): " + [math]::Round($notRetainedBytes / 1GB, 2),
            "",
            "Path,SizeBytes"
        )
        foreach ($entry in $script:imagesNotRetainedList) {
            $p = $entry -replace "\|", ","
            $reportLines += $p
        }
        $reportLines | Out-File -FilePath $imagesNotRetainedReportFile -Encoding UTF8
        Write-Log ("Report written: " + $imagesNotRetainedReportFile)
    }
} else {
    # ---------- Single phase: Records only or Images only ----------
    foreach ($profile in $userProfiles) {
        if (Test-TimeLimit) { break }
        foreach ($sub in $sourceSubfolders) {
            if (Test-TimeLimit) { break }
            $sourcePath = Join-Path $profile.FullName $sub
            if (-not (Test-Path $sourcePath)) { continue }

            Get-ChildItem -Path $sourcePath -Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Where-Object { $allowedExtensions -contains $_.Extension.ToLower() } |
                ForEach-Object {
                    if (Test-TimeLimit) { break }
                    $matchedCount++
                    if ($totalBytes -ge $maxTotalBytes) {
                        Write-Log ("Size limit reached; skipping remaining files. Limit: " + $maxTotalBytes)
                        return
                    }
                    $relativePath = $_.FullName.Substring($sourcePath.Length).TrimStart("\")
                    $destFolder = Join-Path $destinationRoot (Join-Path $profile.Name $sub)
                    $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                    $destFile = $pathInfo.DestinationPath
                    $destDir = Split-Path $destFile -Parent
                    $sourceFile = $_.FullName
                    try {
                        [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
                        $fileSize = $_.Length
                        if (($totalBytes + $fileSize) -gt $maxTotalBytes) {
                            Write-Log ("Skipping file due to size cap: " + $sourceFile)
                            return
                        }
                        [System.IO.File]::Copy((Get-LongPath $sourceFile), $destFile, $true)
                        $copiedCount++
                        $totalBytes += $fileSize
                    } catch {
                        $errorCount++
                        Write-Log ("Copy failed: " + $sourceFile + " -> " + $destFile + " | " + $_.Exception.Message)
                    }
                }
        }
        if ($script:timeLimitReached) { break }
    }

    Write-Log "Root drive scan started."
    if ((-not (Test-TimeLimit)) -and (Test-Path $rootScanPath)) {
        $rootFolders = Get-ChildItem -Path $rootScanPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer } |
            Where-Object {
                $fullName = $_.FullName
                (-not $fullName.StartsWith($stagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not $fullName.StartsWith($usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not ($excludedRootPrefixes | Where-Object {
                    $fullName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
                }))
            }
        foreach ($folder in $rootFolders) {
            if (Test-TimeLimit) { break }
            if ($totalBytes -ge $maxTotalBytes) { break }
            Get-ChildItem -Path $folder.FullName -Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                Where-Object { $allowedExtensions -contains $_.Extension.ToLower() } |
                ForEach-Object {
                    if (Test-TimeLimit) { break }
                    $matchedCount++
                    if ($totalBytes -ge $maxTotalBytes) { return }
                    $relativePath = $_.FullName.Substring($rootScanPath.Length).TrimStart("\")
                    $destFolder = Join-Path $destinationRoot $rootCopyFolderName
                    $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                    $destFile = $pathInfo.DestinationPath
                    $destDir = Split-Path $destFile -Parent
                    $sourceFile = $_.FullName
                    try {
                        [System.IO.Directory]::CreateDirectory($destDir) | Out-Null
                        $fileSize = $_.Length
                        if (($totalBytes + $fileSize) -gt $maxTotalBytes) {
                            Write-Log ("Skipping file due to size cap: " + $sourceFile)
                            return
                        }
                        [System.IO.File]::Copy((Get-LongPath $sourceFile), $destFile, $true)
                        $copiedCount++
                        $totalBytes += $fileSize
                    } catch {
                        $errorCount++
                        Write-Log ("Copy failed: " + $sourceFile + " -> " + $destFile + " | " + $_.Exception.Message)
                    }
                }
        }
    }
    Write-Log "Root drive scan finished."
}

Write-Log ("Planned files: " + $matchedCount)
Write-Log ("Copied files: " + $copiedCount)
Write-Log ("Copy errors: " + $errorCount)
Write-Log ("Total bytes copied: " + $totalBytes)
Write-Log ("Timed out: " + $script:timeLimitReached)
if ($ContentType -eq "All" -and $script:overflowImageCount -gt 0) {
    Write-Log ("Images not retained (over limit): " + $script:overflowImageCount)
}
Write-Log "Copy job finished."

Write-Host "Copy complete."
Write-Host ("ContentType: " + $ContentType)
Write-Host ("Destination root: " + $destinationRoot)
Write-Host ("Log file: " + $logFile)
if ($ContentType -eq "All" -and $script:overflowImageCount -gt 0) {
    Write-Host ("Images not retained (over limit): " + $script:overflowImageCount)
    Write-Host ("Report: " + $imagesNotRetainedReportFile)
}
exit 0
