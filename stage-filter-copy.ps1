# RUN COMMAND in LogMeIn Central: 
# To refer to an uploaded file, copy its name (including extension) into your script. To include the file's path in your script, use the environment variable %central_FilePath%
#For example: Copy-Item filename.png C:\Destination
# ContentType: Records = documents/data only; Images = image files only; All = both (default, backward compatible)
param(
    [ValidateSet("Records", "Images", "All")]
    [string]$ContentType = "All"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Long path support: use \\?\ prefix so paths > 260 chars work when copying/creating dirs
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

# Recursive enumeration that handles long paths and deeply nested directories
function Get-FilesRecursive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$AllowedExtensions = @(),
        [scriptblock]$ErrorCallback = $null
    )
    $longPath = Get-LongPath $Path
    $files = @()
    
    # Check if directory exists and is accessible
    try {
        if (-not [System.IO.Directory]::Exists($longPath)) {
            return $files
        }
    } catch {
        if ($ErrorCallback) { & $ErrorCallback "Cannot access directory: $Path - $($_.Exception.Message)" }
        return $files
    }
    
    try {
        # Get files in current directory
        foreach ($file in [System.IO.Directory]::EnumerateFiles($longPath)) {
            try {
                # Ensure we have a FileInfo with long path support
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
    
    # Recursively process subdirectories
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

# Flatten destination path if it exceeds maximum length for network shares
function Get-FlattenedDestinationPath {
    param(
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][int]$MaxLength
    )
    
    $fullPath = Join-Path $DestinationRoot $RelativePath
    $pathLength = $fullPath.Length
    
    if ($pathLength -le $MaxLength) {
        return @{
            DestinationPath = $fullPath
            WasFlattened = $false
            OriginalPath = $fullPath
        }
    }
    
    # Path is too long - flatten it
    # Strategy: Keep base folder structure (user/profile/subfolder) but flatten deep nesting
    # Use hash of the deep path to create a shorter unique identifier
    
    $parts = $RelativePath.Split([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fileName = $parts[-1]
    $extension = [IO.Path]::GetExtension($fileName)
    $nameWithoutExt = [IO.Path]::GetFileNameWithoutExtension($fileName)
    
    # Keep first 2-3 directory levels, then hash the rest
    $keepLevels = 2
    if ($parts.Count -le $keepLevels + 1) {
        # Not enough levels to flatten meaningfully, just truncate the filename if needed
        $maxFileNameLength = $MaxLength - $DestinationRoot.Length - 20
        if ($maxFileNameLength -lt 20) {
            $maxFileNameLength = 20
        }
        if ($fileName.Length -gt $maxFileNameLength) {
            $truncatedName = $nameWithoutExt.Substring(0, [Math]::Min($nameWithoutExt.Length, $maxFileNameLength - $extension.Length - 10)) + "_" + $nameWithoutExt.GetHashCode().ToString("X8") + $extension
            $flattenedPath = Join-Path $DestinationRoot $truncatedName
            return @{
                DestinationPath = $flattenedPath
                WasFlattened = $true
                OriginalPath = $fullPath
            }
        } else {
            # Path is too long but filename is short - likely the destination root is very long
            # Just put file directly in destination root
            $flattenedPath = Join-Path $DestinationRoot $fileName
            return @{
                DestinationPath = $flattenedPath
                WasFlattened = $true
                OriginalPath = $fullPath
            }
        }
    }
    
    # Build path with first few levels, then hash the rest
    $basePath = $DestinationRoot
    $pathToHash = ""
    
    # Keep first keepLevels directories
    for ($i = 0; $i -lt [Math]::Min($keepLevels, $parts.Count - 1); $i++) {
        $basePath = Join-Path $basePath $parts[$i]
    }
    
    # Hash the remaining path (excluding filename)
    if ($parts.Count -gt $keepLevels + 1) {
        $remainingParts = $parts[$keepLevels..($parts.Count - 2)]
        $pathToHash = $remainingParts -join "\"
    }
    
    # Create a short hash-based folder name
    $hashString = ""
    try {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        try {
            $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($pathToHash))
            $hashString = [BitConverter]::ToString($hash).Replace("-", "").Substring(0, 8)
        } finally {
            $md5.Dispose()
        }
    } catch {
        # Fallback to simple hash code if MD5 fails
        $hashString = $pathToHash.GetHashCode().ToString("X8").Substring(0, 8)
    }
    
    if ($pathToHash) {
        $hashFolder = Join-Path $basePath ("_flat_" + $hashString)
        $flattenedPath = Join-Path $hashFolder $fileName
    } else {
        $flattenedPath = Join-Path $basePath $fileName
    }
    
    # If still too long, truncate filename
    if ($flattenedPath.Length -gt $MaxLength) {
        $maxFileNameLength = $MaxLength - (Split-Path $flattenedPath -Parent).Length - 5
        if ($maxFileNameLength -gt 20) {
            $truncatedName = $nameWithoutExt.Substring(0, [Math]::Min($nameWithoutExt.Length, $maxFileNameLength - $extension.Length - 10)) + "_" + $nameWithoutExt.GetHashCode().ToString("X8") + $extension
            $flattenedPath = Join-Path (Split-Path $flattenedPath -Parent) $truncatedName
        } else {
            # Last resort: just use hash as filename
            $hashFileName = $hashString + $extension
            $flattenedPath = Join-Path (Split-Path $flattenedPath -Parent) $hashFileName
        }
    }
    
    return @{
        DestinationPath = $flattenedPath
        WasFlattened = $true
        OriginalPath = $fullPath
    }
}

$stagingRoot = "C:\Staging_Logmein_central"
# Folder for image files that don't fit within the size limit (separate from staging)
$overflowRoot = "C:\Staging_Logmein_overflow"
$archiveFolderName = "01_PCARCHIVE"
$maxTotalBytes = 30GB
$maxRunMinutes = 30
# Maximum destination path length (network shares often have stricter limits than local paths)
# Set to 200 to leave room for network share UNC paths (e.g., \\server\share\...)
$maxDestinationPathLength = 200

$pcDetailsMapping = "C:\PcDetails.json"

if (-not $stagingRoot) {
    Write-Host "Staging root path is empty."
    exit 1
}

if (-not (Test-Path $stagingRoot)) {
    [System.IO.Directory]::CreateDirectory((Get-LongPath $stagingRoot)) | Out-Null
}

$computerName = $env:COMPUTERNAME
if (-not $computerName) {
    Write-Host "Computer name not found."
    exit 1
}
if (-not (Test-Path $pcDetailsMapping)) {
    Write-Host "Property folder file not found: $pcDetailsMapping"
    exit 1
}

try {
    $config = Get-Content -Path $pcDetailsMapping -Raw | ConvertFrom-Json
} catch {
    Write-Host "Failed to read JSON config: $pcDetailsMapping"
    exit 1
}

$propertyPcDetailsName = $config.PropertyFolder
$targetFolder = $config.TargetFolder
if (-not $propertyPcDetailsName -or -not $targetFolder) {
    Write-Host "PcDetails.json must contain PropertyFolder and TargetFolder."
    exit 1
}

$propertyPcDetailsName = $propertyPcDetailsName.Trim()
$targetFolder = $targetFolder.Trim()
if (-not $propertyPcDetailsName -or -not $targetFolder) {
    Write-Host "PropertyPcDetails or TargetFolder is empty in: $pcDetailsMapping"
    exit 1
}

$targetFolder = $targetFolder -replace '[<>:"/\\|?*]', "_"

if (-not $targetFolder) {
    Write-Host "Target folder name is required."
    exit 1
}

$destinationBase = Join-Path $stagingRoot (Join-Path $propertyPcDetailsName (Join-Path $archiveFolderName $targetFolder))
if (-not $destinationBase) {
    Write-Host "Destination base is empty."
    exit 1
}

# Single destination tree (no Records/Images subfolders); strategy: records copied first, then images into same tree
$destinationRoot = $destinationBase

# Extension sets: Records = documents/data; Images = image files
$recordExtensions = @(
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
$imageExtensions = @(
    ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic", ".heif", ".raw", ".svg"
)
$allowedExtensions = switch ($ContentType) {
    "Records" { $recordExtensions }
    "Images"  { $imageExtensions }
    default   {
        $recordExtensions + $imageExtensions
    }
}
# Not including OneDrive or Downloads
# =======
$sourceSubfolders = @("Desktop", "Documents", "Pictures")
$usersRoot = "C:\Users"
$excludedUsers = @("Default", "Default User", "All Users", "DefaultAppPool", "WDAGUtilityAccount", "LogMeInRemoteUser")
$rootScanPath = "C:\"
$rootCopyFolderName = "_RootDrive"
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

$logDestinationRoot = $destinationBase
if (-not (Test-Path $logDestinationRoot)) {
    [System.IO.Directory]::CreateDirectory((Get-LongPath $logDestinationRoot)) | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $logDestinationRoot ("copy-log-" + $timestamp + ".txt")
if (-not $logFile) {
    Write-Host "Log file path is empty."
    exit 1
}
$pathMappingFile = Join-Path $logDestinationRoot ("path-mapping-" + $timestamp + ".txt")
$imagesNotRetainedReportFile = Join-Path $logDestinationRoot ("images-not-retained-" + $timestamp + ".txt")
$script:flattenedCount = 0
$script:imagesNotRetainedList = @()

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $logFile -Value $line
}

function Write-PathMapping {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalPath,
        [Parameter(Mandatory = $true)][string]$FlattenedPath
    )
    $line = "{0}|{1}" -f $OriginalPath, $FlattenedPath
    Add-Content -Path $pathMappingFile -Value $line
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

Write-Log "Copy job started."
Write-Log ("ContentType: " + $ContentType)
Write-Log ("ComputerName: " + $computerName)
Write-Log ("PropertyPcDetails: " + $propertyPcDetailsName)
Write-Log ("DestinationRoot: " + $destinationRoot)
if ($ContentType -eq "All") {
    Write-Log ("Images over " + $maxTotalBytes + " will be logged and reported (not copied).")
}

$userProfiles = Get-ChildItem -Path $usersRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        ($excludedUsers -notcontains $_.Name) -and
        ($_.Name -notlike "LogMeInRemoteUser*")
    }

$matchedCount = 0
$copiedCount = 0
$errorCount = 0
$enumErrorCount = 0
$totalBytes = 0
$script:overflowImageCount = 0

if ($ContentType -eq "All") {
    # ---------- Phase 1: Records first (users + root); same destination tree, no extra folders ----------
    Write-Log "Phase 1 (Records) started. Destination: $destinationBase"

    foreach ($profile in $userProfiles) {
        if (Test-TimeLimit) { break }
        foreach ($sub in $sourceSubfolders) {
            if (Test-TimeLimit) { break }
            $sourcePath = Join-Path $profile.FullName $sub
            if (-not (Test-Path $sourcePath)) { continue }

            $enumFiles = Get-FilesRecursive -Path $sourcePath -AllowedExtensions $recordExtensions -ErrorCallback {
                param($msg)
                $script:enumErrorCount++
                Write-Log ("Enumeration warning: " + $msg)
            }

            foreach ($fileInfo in $enumFiles) {
                if (Test-TimeLimit) { break }
                $matchedCount++
                if ($totalBytes -ge $maxTotalBytes) {
                    Write-Log ("Size limit reached; skipping remaining files. Limit: " + $maxTotalBytes)
                    break
                }
                $sourceFileNormal = $fileInfo.FullName
                if ($sourceFileNormal.StartsWith("\\?\")) { $sourceFileNormal = $sourceFileNormal.Substring(4) }
                $relativePath = $sourceFileNormal.Substring($sourcePath.Length).TrimStart("\")
                $destFolder = Join-Path $destinationBase (Join-Path $profile.Name $sub)
                $originalDestFile = Join-Path $destFolder $relativePath
                $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                if ($pathInfo.WasFlattened) {
                    $script:flattenedCount++
                    Write-PathMapping -OriginalPath $originalDestFile -FlattenedPath $pathInfo.DestinationPath
                    Write-Log ("Path flattened (too long): " + $originalDestFile + " -> " + $pathInfo.DestinationPath)
                }
                $destFile = $pathInfo.DestinationPath
                $destDir = Split-Path $destFile -Parent
                if (-not (Test-Path $destDir)) {
                    [System.IO.Directory]::CreateDirectory((Get-LongPath $destDir)) | Out-Null
                }
                $sourceFile = $fileInfo.FullName
                try {
                    $fileSize = $fileInfo.Length
                    if (($totalBytes + $fileSize) -gt $maxTotalBytes) {
                        Write-Log ("Skipping file due to size cap: " + $sourceFileNormal)
                        continue
                    }
                    [System.IO.File]::Copy((Get-LongPath $sourceFile), (Get-LongPath $destFile), $true)
                    $copiedCount++
                    $totalBytes += $fileSize
                } catch {
                    $errorCount++
                    Write-Log ("Copy failed: " + $sourceFileNormal + " -> " + $destFile + " | " + $_.Exception.Message)
                }
            }
        }
        if ($script:timeLimitReached) { break }
    }

    Write-Log "Root drive scan started (Phase 1 - Records)."
    if ((-not (Test-TimeLimit)) -and (Test-Path $rootScanPath)) {
        $rootFolders = Get-ChildItem -Path $rootScanPath -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $fullName = $_.FullName
                (-not $fullName.StartsWith($stagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not $fullName.StartsWith($overflowRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not $fullName.StartsWith($usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not ($excludedRootPrefixes | Where-Object { $fullName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }))
            }
        foreach ($folder in $rootFolders) {
            if (Test-TimeLimit) { break }
            if ($totalBytes -ge $maxTotalBytes) { break }
            $enumFiles = Get-FilesRecursive -Path $folder.FullName -AllowedExtensions $recordExtensions -ErrorCallback {
                param($msg)
                $script:enumErrorCount++
                Write-Log ("Enumeration warning: " + $msg)
            }
            foreach ($fileInfo in $enumFiles) {
                if (Test-TimeLimit) { break }
                $matchedCount++
                if ($totalBytes -ge $maxTotalBytes) { break }
                $sourceFileNormal = $fileInfo.FullName
                if ($sourceFileNormal.StartsWith("\\?\")) { $sourceFileNormal = $sourceFileNormal.Substring(4) }
                $relativePath = $sourceFileNormal.Substring($rootScanPath.Length).TrimStart("\")
                $destFolder = Join-Path $destinationBase $rootCopyFolderName
                $originalDestFile = Join-Path $destFolder $relativePath
                $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                if ($pathInfo.WasFlattened) {
                    $script:flattenedCount++
                    Write-PathMapping -OriginalPath $originalDestFile -FlattenedPath $pathInfo.DestinationPath
                    Write-Log ("Path flattened (too long): " + $originalDestFile + " -> " + $pathInfo.DestinationPath)
                }
                $destFile = $pathInfo.DestinationPath
                $destDir = Split-Path $destFile -Parent
                if (-not (Test-Path $destDir)) {
                    [System.IO.Directory]::CreateDirectory((Get-LongPath $destDir)) | Out-Null
                }
                $sourceFile = $fileInfo.FullName
                try {
                    $fileSize = $fileInfo.Length
                    if (($totalBytes + $fileSize) -gt $maxTotalBytes) {
                        Write-Log ("Skipping file due to size cap: " + $sourceFileNormal)
                        continue
                    }
                    [System.IO.File]::Copy((Get-LongPath $sourceFile), (Get-LongPath $destFile), $true)
                    $copiedCount++
                    $totalBytes += $fileSize
                } catch {
                    $errorCount++
                    Write-Log ("Copy failed: " + $sourceFileNormal + " -> " + $destFile + " | " + $_.Exception.Message)
                }
            }
        }
    }
    Write-Log "Phase 1 (Records) finished."

    # ---------- Phase 2: Images last; same destination tree; over limit = log/report only ----------
    $script:imagePhaseOverLimit = $false
    Write-Log "Phase 2 (Images) started. Same destination: $destinationBase ; images over limit will be logged and reported (not copied)."

    foreach ($profile in $userProfiles) {
        if (Test-TimeLimit) { break }
        foreach ($sub in $sourceSubfolders) {
            if (Test-TimeLimit) { break }
            $sourcePath = Join-Path $profile.FullName $sub
            if (-not (Test-Path $sourcePath)) { continue }

            $enumFiles = Get-FilesRecursive -Path $sourcePath -AllowedExtensions $imageExtensions -ErrorCallback {
                param($msg)
                $script:enumErrorCount++
                Write-Log ("Enumeration warning: " + $msg)
            }

            foreach ($fileInfo in $enumFiles) {
                if (Test-TimeLimit) { break }
                $matchedCount++
                $fileSize = $fileInfo.Length
                $sourceFileNormal = $fileInfo.FullName
                if ($sourceFileNormal.StartsWith("\\?\")) { $sourceFileNormal = $sourceFileNormal.Substring(4) }

                if (-not $script:imagePhaseOverLimit -and ($totalBytes + $fileSize -gt $maxTotalBytes)) {
                    $script:imagePhaseOverLimit = $true
                    Write-Log ("Size limit reached (" + $maxTotalBytes + "); remaining images will be logged as not retained (not copied).")
                }

                if ($script:imagePhaseOverLimit) {
                    $script:overflowImageCount++
                    $script:imagesNotRetainedList += [PSCustomObject]@{ Path = $sourceFileNormal; SizeBytes = $fileSize }
                    Write-Log ("Image not retained (over limit): " + $sourceFileNormal + " (" + $fileSize + " bytes)")
                    continue
                }

                $relativePath = $sourceFileNormal.Substring($sourcePath.Length).TrimStart("\")
                $destFolder = Join-Path $destinationBase (Join-Path $profile.Name $sub)
                $originalDestFile = Join-Path $destFolder $relativePath
                $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                if ($pathInfo.WasFlattened) {
                    $script:flattenedCount++
                    Write-PathMapping -OriginalPath $originalDestFile -FlattenedPath $pathInfo.DestinationPath
                    Write-Log ("Path flattened (too long): " + $originalDestFile + " -> " + $pathInfo.DestinationPath)
                }
                $destFile = $pathInfo.DestinationPath
                $destDir = Split-Path $destFile -Parent
                if (-not (Test-Path $destDir)) {
                    [System.IO.Directory]::CreateDirectory((Get-LongPath $destDir)) | Out-Null
                }
                $sourceFile = $fileInfo.FullName
                try {
                    [System.IO.File]::Copy((Get-LongPath $sourceFile), (Get-LongPath $destFile), $true)
                    $copiedCount++
                    $totalBytes += $fileSize
                } catch {
                    $errorCount++
                    Write-Log ("Copy failed: " + $sourceFileNormal + " -> " + $destFile + " | " + $_.Exception.Message)
                }
            }
        }
        if ($script:timeLimitReached) { break }
    }

    Write-Log "Root drive scan started (Phase 2 - Images)."
    if ((-not (Test-TimeLimit)) -and (Test-Path $rootScanPath)) {
        $rootFolders = Get-ChildItem -Path $rootScanPath -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $fullName = $_.FullName
                (-not $fullName.StartsWith($stagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not $fullName.StartsWith($overflowRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not $fullName.StartsWith($usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not ($excludedRootPrefixes | Where-Object { $fullName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }))
            }
        foreach ($folder in $rootFolders) {
            if (Test-TimeLimit) { break }
            $enumFiles = Get-FilesRecursive -Path $folder.FullName -AllowedExtensions $imageExtensions -ErrorCallback {
                param($msg)
                $script:enumErrorCount++
                Write-Log ("Enumeration warning: " + $msg)
            }
            foreach ($fileInfo in $enumFiles) {
                if (Test-TimeLimit) { break }
                $matchedCount++
                $fileSize = $fileInfo.Length
                $sourceFileNormal = $fileInfo.FullName
                if ($sourceFileNormal.StartsWith("\\?\")) { $sourceFileNormal = $sourceFileNormal.Substring(4) }

                if (-not $script:imagePhaseOverLimit -and ($totalBytes + $fileSize -gt $maxTotalBytes)) {
                    $script:imagePhaseOverLimit = $true
                    Write-Log ("Size limit reached (" + $maxTotalBytes + "); remaining images will be logged as not retained (not copied).")
                }

                if ($script:imagePhaseOverLimit) {
                    $script:overflowImageCount++
                    $script:imagesNotRetainedList += [PSCustomObject]@{ Path = $sourceFileNormal; SizeBytes = $fileSize }
                    Write-Log ("Image not retained (over limit): " + $sourceFileNormal + " (" + $fileSize + " bytes)")
                    continue
                }

                $relativePath = $sourceFileNormal.Substring($rootScanPath.Length).TrimStart("\")
                $destFolder = Join-Path $destinationBase $rootCopyFolderName
                $originalDestFile = Join-Path $destFolder $relativePath
                $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                if ($pathInfo.WasFlattened) {
                    $script:flattenedCount++
                    Write-PathMapping -OriginalPath $originalDestFile -FlattenedPath $pathInfo.DestinationPath
                    Write-Log ("Path flattened (too long): " + $originalDestFile + " -> " + $pathInfo.DestinationPath)
                }
                $destFile = $pathInfo.DestinationPath
                $destDir = Split-Path $destFile -Parent
                if (-not (Test-Path $destDir)) {
                    [System.IO.Directory]::CreateDirectory((Get-LongPath $destDir)) | Out-Null
                }
                $sourceFile = $fileInfo.FullName
                try {
                    [System.IO.File]::Copy((Get-LongPath $sourceFile), (Get-LongPath $destFile), $true)
                    $copiedCount++
                    $totalBytes += $fileSize
                } catch {
                    $errorCount++
                    Write-Log ("Copy failed: " + $sourceFileNormal + " -> " + $destFile + " | " + $_.Exception.Message)
                }
            }
        }
    }
    Write-Log "Phase 2 (Images) finished."
    Write-Log ("Images not retained (over size limit): " + $script:overflowImageCount)

    # Write images-not-retained report
    if ($script:overflowImageCount -gt 0 -and $script:imagesNotRetainedList.Count -gt 0) {
        $notRetainedBytes = ($script:imagesNotRetainedList | Measure-Object -Property SizeBytes -Sum).Sum
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
        foreach ($item in $script:imagesNotRetainedList) {
            $reportLines += ($item.Path + "," + $item.SizeBytes)
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

            $enumFiles = Get-FilesRecursive -Path $sourcePath -AllowedExtensions $allowedExtensions -ErrorCallback {
                param($msg)
                $script:enumErrorCount++
                Write-Log ("Enumeration warning: " + $msg)
            }

            foreach ($fileInfo in $enumFiles) {
                if (Test-TimeLimit) { break }
                $matchedCount++
                if ($totalBytes -ge $maxTotalBytes) {
                    Write-Log ("Size limit reached; skipping remaining files. Limit: " + $maxTotalBytes)
                    break
                }
                $sourceFileNormal = $fileInfo.FullName
                if ($sourceFileNormal.StartsWith("\\?\")) { $sourceFileNormal = $sourceFileNormal.Substring(4) }
                $relativePath = $sourceFileNormal.Substring($sourcePath.Length).TrimStart("\")
                $destFolder = Join-Path $destinationRoot (Join-Path $profile.Name $sub)
                $originalDestFile = Join-Path $destFolder $relativePath
                $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                if ($pathInfo.WasFlattened) {
                    $script:flattenedCount++
                    Write-PathMapping -OriginalPath $originalDestFile -FlattenedPath $pathInfo.DestinationPath
                    Write-Log ("Path flattened (too long): " + $originalDestFile + " -> " + $pathInfo.DestinationPath)
                }
                $destFile = $pathInfo.DestinationPath
                $destDir = Split-Path $destFile -Parent
                if (-not (Test-Path $destDir)) {
                    [System.IO.Directory]::CreateDirectory((Get-LongPath $destDir)) | Out-Null
                }
                $sourceFile = $fileInfo.FullName
                try {
                    $fileSize = $fileInfo.Length
                    if (($totalBytes + $fileSize) -gt $maxTotalBytes) {
                        Write-Log ("Skipping file due to size cap: " + $sourceFileNormal)
                        continue
                    }
                    [System.IO.File]::Copy((Get-LongPath $sourceFile), (Get-LongPath $destFile), $true)
                    $copiedCount++
                    $totalBytes += $fileSize
                } catch {
                    $errorCount++
                    Write-Log ("Copy failed: " + $sourceFileNormal + " -> " + $destFile + " | " + $_.Exception.Message)
                }
            }
        }
        if ($script:timeLimitReached) { break }
    }

    Write-Log "Root drive scan started."
    if ((-not (Test-TimeLimit)) -and (Test-Path $rootScanPath)) {
        $rootFolders = Get-ChildItem -Path $rootScanPath -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $fullName = $_.FullName
                (-not $fullName.StartsWith($stagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not $fullName.StartsWith($overflowRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not $fullName.StartsWith($usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
                (-not ($excludedRootPrefixes | Where-Object {
                    $fullName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
                }))
            }
        foreach ($folder in $rootFolders) {
            if (Test-TimeLimit) { break }
            if ($totalBytes -ge $maxTotalBytes) { break }
            $enumFiles = Get-FilesRecursive -Path $folder.FullName -AllowedExtensions $allowedExtensions -ErrorCallback {
                param($msg)
                $script:enumErrorCount++
                Write-Log ("Enumeration warning: " + $msg)
            }
            foreach ($fileInfo in $enumFiles) {
                if (Test-TimeLimit) { break }
                $matchedCount++
                if ($totalBytes -ge $maxTotalBytes) { break }
                $sourceFileNormal = $fileInfo.FullName
                if ($sourceFileNormal.StartsWith("\\?\")) { $sourceFileNormal = $sourceFileNormal.Substring(4) }
                $relativePath = $sourceFileNormal.Substring($rootScanPath.Length).TrimStart("\")
                $destFolder = Join-Path $destinationRoot $rootCopyFolderName
                $originalDestFile = Join-Path $destFolder $relativePath
                $pathInfo = Get-FlattenedDestinationPath -DestinationRoot $destFolder -RelativePath $relativePath -MaxLength $maxDestinationPathLength
                if ($pathInfo.WasFlattened) {
                    $script:flattenedCount++
                    Write-PathMapping -OriginalPath $originalDestFile -FlattenedPath $pathInfo.DestinationPath
                    Write-Log ("Path flattened (too long): " + $originalDestFile + " -> " + $pathInfo.DestinationPath)
                }
                $destFile = $pathInfo.DestinationPath
                $destDir = Split-Path $destFile -Parent
                if (-not (Test-Path $destDir)) {
                    [System.IO.Directory]::CreateDirectory((Get-LongPath $destDir)) | Out-Null
                }
                $sourceFile = $fileInfo.FullName
                try {
                    $fileSize = $fileInfo.Length
                    if (($totalBytes + $fileSize) -gt $maxTotalBytes) {
                        Write-Log ("Skipping file due to size cap: " + $sourceFileNormal)
                        continue
                    }
                    [System.IO.File]::Copy((Get-LongPath $sourceFile), (Get-LongPath $destFile), $true)
                    $copiedCount++
                    $totalBytes += $fileSize
                } catch {
                    $errorCount++
                    Write-Log ("Copy failed: " + $sourceFileNormal + " -> " + $destFile + " | " + $_.Exception.Message)
                }
            }
        }
    }
    Write-Log "Root drive scan finished."
}

Write-Log ("Planned files: " + $matchedCount)
Write-Log ("Copied files: " + $copiedCount)
Write-Log ("Copy errors: " + $errorCount)
Write-Log ("Enumeration errors: " + $enumErrorCount)
Write-Log ("Flattened paths (too long): " + $script:flattenedCount)
Write-Log ("Total bytes copied (staging): " + $totalBytes)
if ($ContentType -eq "All" -and $script:overflowImageCount -gt 0) {
    Write-Log ("Images not retained (over limit): " + $script:overflowImageCount)
}
Write-Log ("Timed out: " + $script:timeLimitReached)
Write-Log "Copy job finished."

#NOTE: Reintroduce post-copy antivirus scan here if needed (CLI or Defender).

Write-Host "Copy complete."
Write-Host ("ContentType: " + $ContentType)
Write-Host ("Destination root: " + $destinationRoot)
Write-Host ("Log file: " + $logFile)
if ($ContentType -eq "All" -and $script:overflowImageCount -gt 0) {
    Write-Host ("Images not retained (over limit): " + $script:overflowImageCount)
    Write-Host ("Report: " + $imagesNotRetainedReportFile)
}
if ($script:flattenedCount -gt 0) {
    Write-Host ("Path mapping file (for flattened paths): " + $pathMappingFile)
    Write-Host ("Total paths flattened: " + $script:flattenedCount)
}
exit 0
