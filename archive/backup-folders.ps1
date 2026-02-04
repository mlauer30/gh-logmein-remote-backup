param(
    [string]$PropertyName,
    [string]$PropertyKey,
    [hashtable]$PropertyMap,
    [string]$DestinationDrive = "Q:\",
    [string]$ArchiveFolderName = "01_ARCHIVE",
    [string]$UsersRoot = "C:\Users",
    [string[]]$UserFolderNames = @("Desktop", "Downloads", "Documents"),
    [string[]]$ExcludeUsers = @("Public", "Default", "Default User", "All Users", "DefaultAppPool", "WDAGUtilityAccount"),
    [string]$ConfigPath,
    [switch]$Mirror,
    [switch]$DryRun,
    [string]$LogPath = (Join-Path $PSScriptRoot "logs"),
    [int]$Retries = 2,
    [int]$WaitSeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Set-IfEmpty {
    param(
        [Parameter(Mandatory = $true)][ref]$Target,
        [Parameter(Mandatory = $true)]$Value
    )
    if (-not $Target.Value) {
        $Target.Value = $Value
    }
}

function Get-SafeName {
    param([Parameter(Mandatory = $true)][string]$Path)
    $name = Split-Path -Path $Path -Leaf
    if (-not $name) {
        $name = $Path
    }
    return ($name -replace "[^A-Za-z0-9._-]", "_")
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Resolve-ConfigPath {
    if ($ConfigPath) {
        return $ConfigPath
    }

    $centralFilesPath = $null
    if ($env:central_FilesPath) {
        $centralFilesPath = $env:central_FilesPath
    } elseif ($env:CENTRAL_FILESPATH) {
        $centralFilesPath = $env:CENTRAL_FILESPATH
    }

    if ($centralFilesPath) {
        $candidate = Join-Path $centralFilesPath "backup-config.json"
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Resolve-PropertyName {
    param(
        [string]$Name,
        [string]$Key,
        [hashtable]$Map
    )

    if ($Name) {
        return $Name
    }

    if (-not $Key) {
        $Key = $env:COMPUTERNAME
    }

    if ($Map -and $Key -and $Map.ContainsKey($Key)) {
        return $Map[$Key]
    }

    return $null
}

function Invoke-BackupCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$LogFile
    )

    if (-not (Test-Path $Source)) {
        throw "Source not found: $Source"
    }

    Ensure-Directory -Path $Destination

    $commonArgs = @(
        $Source,
        $Destination,
        "/COPY:DAT",
        "/R:$Retries",
        "/W:$WaitSeconds",
        "/LOG+:$LogFile"
    )

    if ($Mirror) {
        $commonArgs += "/MIR"
    } else {
        $commonArgs += "/E"
    }

    if ($DryRun) {
        $commonArgs += "/L"
    }

    & robocopy @commonArgs | Out-Null
    return $LASTEXITCODE
}

try {
    $resolvedConfigPath = Resolve-ConfigPath
    if ($resolvedConfigPath) {
        $config = Get-Content -Path $resolvedConfigPath -Raw | ConvertFrom-Json
        Set-IfEmpty -Target ([ref]$PropertyName) -Value $config.PropertyName
        if ($config.PropertyKey) { $PropertyKey = $config.PropertyKey }
        if ($config.PropertyMap) { $PropertyMap = @{} + $config.PropertyMap }
        if ($config.DestinationDrive) { $DestinationDrive = $config.DestinationDrive }
        if ($config.ArchiveFolderName) { $ArchiveFolderName = $config.ArchiveFolderName }
        if ($config.UsersRoot) { $UsersRoot = $config.UsersRoot }
        if ($config.UserFolderNames) { $UserFolderNames = $config.UserFolderNames }
        if ($config.ExcludeUsers) { $ExcludeUsers = $config.ExcludeUsers }
        if ($config.Mirror -ne $null) { $Mirror = [bool]$config.Mirror }
        if ($config.DryRun -ne $null) { $DryRun = [bool]$config.DryRun }
        if ($config.LogPath) { $LogPath = $config.LogPath }
        if ($config.Retries) { $Retries = [int]$config.Retries }
        if ($config.WaitSeconds) { $WaitSeconds = [int]$config.WaitSeconds }
    }

    $PropertyName = Resolve-PropertyName -Name $PropertyName -Key $PropertyKey -Map $PropertyMap
    if (-not $PropertyName) {
        throw "PropertyName is required. Provide PropertyName or PropertyKey with PropertyMap."
    }

    if (-not (Test-Path $UsersRoot)) {
        throw "Users root not found: $UsersRoot"
    }

    if (-not $DestinationDrive) {
        throw "DestinationDrive is required."
    }

    Ensure-Directory -Path $LogPath

    $destinationRoot = Join-Path $DestinationDrive $PropertyName
    $archiveRoot = Join-Path $destinationRoot $ArchiveFolderName
    Ensure-Directory -Path $archiveRoot

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $failures = @()

    $userDirs = Get-ChildItem -Path $UsersRoot -Directory -ErrorAction Stop
    foreach ($userDir in $userDirs) {
        if ($ExcludeUsers -contains $userDir.Name) {
            continue
        }

        $ntUserDat = Join-Path $userDir.FullName "NTUSER.DAT"
        if (-not (Test-Path $ntUserDat)) {
            continue
        }

        foreach ($folderName in $UserFolderNames) {
            $source = Join-Path $userDir.FullName $folderName
            if (-not (Test-Path $source)) {
                continue
            }

            $destBase = Join-Path $archiveRoot $userDir.Name
            if ($Mirror) {
                $dest = Join-Path $destBase $folderName
            } else {
                $dest = Join-Path $destBase (Join-Path $folderName $timestamp)
            }

            $safeUser = Get-SafeName -Path $userDir.Name
            $safeFolder = Get-SafeName -Path $folderName
            $logFile = Join-Path $LogPath ("backup-" + $safeUser + "-" + $safeFolder + "-" + $timestamp + ".log")
            $exitCode = Invoke-BackupCopy -Source $source -Destination $dest -LogFile $logFile

            if ($exitCode -gt 7) {
                $failures += [pscustomobject]@{
                    Source = $source
                    Destination = $dest
                    ExitCode = $exitCode
                    Log = $logFile
                }
            }
        }
    }

    if ($failures.Count -gt 0) {
        $failures | Format-Table -AutoSize | Out-String | Write-Output
        exit 1
    }

    Write-Output "Backup completed successfully."
    exit 0
}
catch {
    Write-Error $_
    exit 2
}
