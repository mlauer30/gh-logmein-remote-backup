# RUN COMMAND in LogMeIn Central: 
# To refer to an uploaded file, copy its name (including extension) into your script. To include the file's path in your script, use the environment variable %central_FilePath%

For example: Copy-Item filename.png C:\Destination

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$stagingRoot = "C:\Staging_Logmein_central"
$archiveFolderName = "01_PCARCHIVE"
$maxTotalBytes = 60GB
$maxRunMinutes = 30

$pcDetailsMapping = "C:\PcDetails.json"

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

$destinationRoot = Join-Path $stagingRoot (Join-Path $propertyPcDetailsName (Join-Path $archiveFolderName $targetFolder))
if (-not $destinationRoot) {
    Write-Host "Destination root is empty."
    exit 1
}

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
<<<<<<< HEAD
# Not including OneDrive or Downloads
=======

>>>>>>> origin/main
$sourceSubfolders = @("Desktop", "Documents", "Pictures")
$usersRoot = "C:\Users"
$excludedUsers = @("Default", "Default User", "All Users", "DefaultAppPool", "WDAGUtilityAccount", "LogMeInRemoteUser")
$rootScanPath = "C:\"
$rootCopyFolderName = "_RootDrive"
$excludedRootPrefixes = @(
    "C:\Windows",
    "C:\Windows.old",
    "C:\Program Files",
    "C:\Program Files (x86)",
    "C:\ProgramData",
    "C:\Recovery"
)

if (-not (Test-Path $destinationRoot)) {
    New-Item -Path $destinationRoot -ItemType Directory -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $destinationRoot ("copy-log-" + $timestamp + ".txt")
if (-not $logFile) {
    Write-Host "Log file path is empty."
    exit 1
}
function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $logFile -Value $line
}

<<<<<<< HEAD
# Configure AV CLI mappings here when needed.
$avCliOverrides = @(
    @{
        Name = "Windows Defender"
        MatchNames = @("Windows Defender", "Microsoft Defender", "Microsoft Defender ATP", "Microsoft Security Essentials")
        ExePaths = @(
            (Join-Path $env:ProgramFiles "Windows Defender\MpCmdRun.exe"),
            (Join-Path $env:ProgramFiles "Microsoft Security Client\MpCmdRun.exe")
        )
        Args = { param($scanPath) @("-Scan", "-ScanType", "3", "-File", $scanPath) }
    },
    @{
        Name = "Avast Free Antivirus"
        MatchNames = @("Avast", "Avast! Free Antivirus")
        ExePaths = @(
            (Join-Path $env:ProgramFiles "Avast Software\Avast\AvastCmd.exe"),
            (Join-Path $env:ProgramFiles "AVAST Software\Avast\AvastCmd.exe")
        )
        Args = { param($scanPath) @("scan", $scanPath) }
    },
    @{
        Name = "AVG AntiVirus Free"
        MatchNames = @("AVG AntiVirus Free", "AVG Antivirus")
        ExePaths = @(
            (Join-Path $env:ProgramFiles "AVG\Antivirus\avgscanx.exe"),
            (Join-Path $env:ProgramFiles(x86) "AVG\Antivirus\avgscanx.exe")
        )
        Args = { param($scanPath) @("/SCAN=" + $scanPath) }
    },
    @{
        Name = "Kaspersky Endpoint Security"
        MatchNames = @("Kaspersky Endpoint Security")
        ExePaths = @(
            (Join-Path $env:ProgramFiles "Kaspersky Lab\Kaspersky Endpoint Security for Windows\avp.com"),
            (Join-Path $env:ProgramFiles(x86) "Kaspersky Lab\Kaspersky Endpoint Security for Windows\avp.com")
        )
        Args = { param($scanPath) @("scan", $scanPath) }
    },
    @{
        Name = "Symantec Endpoint Protection"
        MatchNames = @("Symantec Endpoint Protection")
        ExePaths = @(
            (Join-Path $env:ProgramFiles "Symantec\Symantec Endpoint Protection\DoScan.exe"),
            (Join-Path $env:ProgramFiles(x86) "Symantec\Symantec Endpoint Protection\DoScan.exe")
        )
        Args = { param($scanPath) @("/Scan", $scanPath) }
    },
    @{
        Name = "McAfee"
        MatchNames = @("McAfee", "McAfee LiveSafe", "McAfee Small Business")
        ExePaths = @(
            (Join-Path $env:ProgramFiles "McAfee\VirusScan Enterprise\Scan32.exe"),
            (Join-Path $env:ProgramFiles(x86) "McAfee\VirusScan Enterprise\Scan32.exe")
        )
        Args = { param($scanPath) @($scanPath) }
    },
    @{
        Name = "Webroot SecureAnywhere"
        MatchNames = @("Webroot SecureAnywhere")
        ExePaths = @((Join-Path $env:ProgramFiles "Webroot\WRSA.exe"))
        Args = $null
    },
    @{
        Name = "CrowdStrike Falcon"
        MatchNames = @("CrowdStrike Falcon")
        ExePaths = @()
        Args = $null
    },
    @{
        Name = "Sentinel Agent"
        MatchNames = @("Sentinel Agent", "SentinelOne")
        ExePaths = @()
        Args = $null
    },
    @{
        Name = "LogMeIn AV"
        MatchNames = @("LogMeIn AV")
        ExePaths = @()
        Args = $null
    }
)

function Get-InstalledAvProducts {
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $names = foreach ($path in $uninstallPaths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object -ExpandProperty DisplayName
    }
    return $names | Sort-Object -Unique
}

function Get-ExistingExePath {
    param([string[]]$Paths)
    foreach ($path in $Paths) {
        if ($path -and (Test-Path $path)) {
            return $path
        }
    }
    return $null
}

function Invoke-PostCopyScan {
    param([Parameter(Mandatory = $true)][string]$ScanPath)
    $installedProducts = Get-InstalledAvProducts
    $scanStarted = $false
    $scanSucceeded = $false

    foreach ($config in $avCliOverrides) {
        $matched = $false
        foreach ($name in $config.MatchNames) {
            if ($installedProducts -match [regex]::Escape($name)) {
                $matched = $true
                break
            }
        }

        $exePath = Get-ExistingExePath -Paths $config.ExePaths
        if (-not $matched -and -not $exePath) { continue }

        if (-not $exePath) {
            Write-Log ("Post-copy scan skipped for " + $config.Name + "; executable not found.")
            return $false
        }
        if (-not $config.Args) {
            Write-Log ("Post-copy scan not configured for " + $config.Name + "; update avCliOverrides to enable.")
            return $false
        }

        try {
            Write-Log ("Post-copy scan started: " + $config.Name + " -> " + $ScanPath)
            $args = & $config.Args $ScanPath
            $scanProcess = Start-Process -FilePath $exePath -ArgumentList $args -NoNewWindow -Wait -PassThru
            Write-Log ("Post-copy scan finished: " + $config.Name + " ExitCode: " + $scanProcess.ExitCode)
            $scanStarted = $true
            if ($scanProcess.ExitCode -eq 0) {
                $scanSucceeded = $true
            } else {
                $scanSucceeded = $false
            }
            return $scanSucceeded
        } catch {
            Write-Log ("Post-copy scan failed: " + $config.Name + " | " + $_.Exception.Message)
            return $false
        }
    }

    if (-not $scanStarted) {
        Write-Log "Post-copy scan skipped; no supported AV CLI found."
        return $false
    }
    return $scanSucceeded
}
=======
#region agent log
$script:debugLogPath = "/mnt/c/Users/mlauer/Documents/Coding/gh-logmein-remote-backup/.cursor/debug.log"
function Write-DebugLog {
    param(
        [Parameter(Mandatory = $true)][string]$HypothesisId,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][hashtable]$Data,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    try {
        $payload = @{
            id = ("log_" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + "_" + ([guid]::NewGuid().ToString("N").Substring(0, 6)))
            timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            location = $Location
            message = $Message
            data = $Data
            runId = $RunId
            hypothesisId = $HypothesisId
        }
        Add-Content -Path $script:debugLogPath -Value ($payload | ConvertTo-Json -Compress)
    } catch {
        # ignore debug logging failures
    }
}
#endregion
>>>>>>> origin/main

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
Write-Log ("ComputerName: " + $computerName)
Write-Log ("PropertyPcDetails: " + $propertyPcDetailsName)
Write-Log ("DestinationRoot: " + $destinationRoot)
#region agent log
Write-DebugLog -HypothesisId "H1" -Location "logmein-filtered-copy.ps1:126" -Message "Config resolved" -Data @{
    destinationRoot = $destinationRoot
    stagingRoot = $stagingRoot
    propertyFolder = $propertyPcDetailsName
    targetFolder = $targetFolder
} -RunId "pre-fix"
#endregion

$userProfiles = Get-ChildItem -Path $usersRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        ($excludedUsers -notcontains $_.Name) -and
        ($_.Name -notlike "LogMeInRemoteUser*")
    }

$matchedCount = 0
$copiedCount = 0
$errorCount = 0
$totalBytes = 0
#region agent log
Write-DebugLog -HypothesisId "H2" -Location "logmein-filtered-copy.ps1:141" -Message "Profiles discovered" -Data @{
    usersRoot = $usersRoot
    profileCount = @($userProfiles).Count
} -RunId "pre-fix"
#endregion

foreach ($profile in $userProfiles) {
    if (Test-TimeLimit) { break }
    foreach ($sub in $sourceSubfolders) {
        if (Test-TimeLimit) { break }
        $sourcePath = Join-Path $profile.FullName $sub
        if (-not (Test-Path $sourcePath)) { continue }

#region agent log
        Write-DebugLog -HypothesisId "H3" -Location "logmein-filtered-copy.ps1:154" -Message "Source path exists" -Data @{
            profile = $profile.Name
            subfolder = $sub
            sourcePath = $sourcePath
        } -RunId "pre-fix"
#endregion

        Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $ext = $_.Extension.ToLowerInvariant()
                $allowedExtensions -contains $ext
            } |
            ForEach-Object {
                if (Test-TimeLimit) { break }
                $matchedCount++
                if ($totalBytes -ge $maxTotalBytes) {
                    Write-Log ("Size limit reached; skipping remaining files. Limit: " + $maxTotalBytes)
                    break
                }
                $relativePath = $_.FullName.Substring($sourcePath.Length).TrimStart("\")
                $destFolder = Join-Path $destinationRoot (Join-Path $profile.Name $sub)
                $destFile = Join-Path $destFolder $relativePath

                $destDir = Split-Path $destFile -Parent
                if (-not (Test-Path $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                }

                $sourceFile = $_.FullName
                try {
                    $fileSize = $_.Length
                    if (($totalBytes + $fileSize) -gt $maxTotalBytes) {
                        Write-Log ("Skipping file due to size cap: " + $sourceFile)
                        return
                    }
                    Copy-Item -Path $sourceFile -Destination $destFile -Force -ErrorAction Stop
                    $copiedCount++
                    $totalBytes += $fileSize
#region agent log
                    if ($copiedCount -le 5) {
                        Write-DebugLog -HypothesisId "H4" -Location "logmein-filtered-copy.ps1:185" -Message "File copied" -Data @{
                            sourceFile = $sourceFile
                            destFile = $destFile
                            totalBytes = $totalBytes
                        } -RunId "pre-fix"
                    }
#endregion
                } catch {
                    $errorCount++
                    Write-Log ("Copy failed: " + $sourceFile + " -> " + $destFile + " | " + $_.Exception.Message)
#region agent log
                    Write-DebugLog -HypothesisId "H5" -Location "logmein-filtered-copy.ps1:193" -Message "Copy failed" -Data @{
                        sourceFile = $sourceFile
                        destFile = $destFile
                        error = $_.Exception.Message
                    } -RunId "pre-fix"
#endregion
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
            (-not $fullName.StartsWith($usersRoot, [System.StringComparison]::OrdinalIgnoreCase)) -and
            (-not ($excludedRootPrefixes | Where-Object {
                $fullName.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
            }))
        }

    foreach ($folder in $rootFolders) {
        if (Test-TimeLimit) { break }
        if ($totalBytes -ge $maxTotalBytes) {
            Write-Log ("Size limit reached; skipping remaining root folders. Limit: " + $maxTotalBytes)
            break
        }

        Get-ChildItem -Path $folder.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $allowedExtensions -contains $_.Extension.ToLowerInvariant() } |
            ForEach-Object {
                if (Test-TimeLimit) { break }
                $matchedCount++
                if ($totalBytes -ge $maxTotalBytes) {
                    Write-Log ("Size limit reached; skipping remaining root files. Limit: " + $maxTotalBytes)
                    break
                }
                $relativePath = $_.FullName.Substring($rootScanPath.Length).TrimStart("\")
                $destFolder = Join-Path $destinationRoot $rootCopyFolderName
                $destFile = Join-Path $destFolder $relativePath

                $destDir = Split-Path $destFile -Parent
                if (-not (Test-Path $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                }

                $sourceFile = $_.FullName
                try {
                    $fileSize = $_.Length
                    if (($totalBytes + $fileSize) -gt $maxTotalBytes) {
                        Write-Log ("Skipping file due to size cap: " + $sourceFile)
                        return
                    }
                    Copy-Item -Path $sourceFile -Destination $destFile -Force -ErrorAction Stop
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

Write-Log ("Planned files: " + $matchedCount)
Write-Log ("Copied files: " + $copiedCount)
Write-Log ("Copy errors: " + $errorCount)
Write-Log ("Total bytes copied: " + $totalBytes)
Write-Log ("Timed out: " + $script:timeLimitReached)
Write-Log "Copy job finished."

# NOTE: Reintroduce post-copy antivirus scan here if needed (CLI or Defender).

Write-Host "Copy complete."
Write-Host ("Destination root: " + $destinationRoot)
Write-Host ("Log file: " + $logFile)
exit 0
