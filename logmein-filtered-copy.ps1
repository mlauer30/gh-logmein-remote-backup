Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$stagingRoot = "C:\Staging_Logmein_central"
$archiveFolderName = "01_PCARCHIVE"
$maxTotalBytes = 60GB

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
    ".one", ".onepkg",
    ".vsd", ".vsdx",
    ".zip"
)

$sourceSubfolders = @("Desktop", "Downloads", "Documents", "OneDrive", "Pictures")
$usersRoot = "C:\Users"
$excludedUsers = @("Default", "Default User", "All Users", "DefaultAppPool", "WDAGUtilityAccount")

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

Write-Log "Copy job started."
Write-Log ("ComputerName: " + $computerName)
Write-Log ("PropertyPcDetails: " + $propertyPcDetailsName)
Write-Log ("DestinationRoot: " + $destinationRoot)

$userProfiles = Get-ChildItem -Path $usersRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $excludedUsers -notcontains $_.Name }

$matchedCount = 0
$copiedCount = 0
$errorCount = 0
$totalBytes = 0

foreach ($profile in $userProfiles) {
    foreach ($sub in $sourceSubfolders) {
        $sourcePath = Join-Path $profile.FullName $sub
        if (-not (Test-Path $sourcePath)) { continue }

        Get-ChildItem -Path $sourcePath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $ext = $_.Extension.ToLowerInvariant()
                $allowedExtensions -contains $ext
            } |
            ForEach-Object {
                if ($totalBytes -ge $maxTotalBytes) {
                    Write-Log ("Size limit reached; skipping remaining files. Limit: " + $maxTotalBytes)
                    break
                }

                $matchedCount++
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
                } catch {
                    $errorCount++
                    Write-Log ("Copy failed: " + $sourceFile + " -> " + $destFile + " | " + $_.Exception.Message)
                }
            }
    }
}

Write-Log ("Matched files: " + $matchedCount)
Write-Log ("Copied files: " + $copiedCount)
Write-Log ("Copy errors: " + $errorCount)
Write-Log ("Total bytes copied: " + $totalBytes)
Write-Log "Copy job finished."

Write-Host "Copy complete."
exit 0
>>>>>>> origin/main
