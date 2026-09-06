[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Status', 'Install', 'Restore')]
    [string]$Action = 'Status',

    [string]$GameRoot,

    [string]$LegacyRoot,

    # The data depot is large. Native files are always backed up; data/locales
    # are restored by Steam file verification unless this switch is supplied.
    [switch]$BackupData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RequiredDepots = @('depot_34331', 'depot_34332', 'depot_34334')
$OptionalDepots = @('depot_34333')
$ModernExtras = @('shogun2.retail.exe')

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToUpperInvariant()
    }
    finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

function Add-Candidate {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$List,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not $List.Contains($Path)) {
        $List.Add($Path)
    }
}

function Test-GameRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    return (Test-Path -LiteralPath (Join-Path $Root 'Shogun2.exe')) -and
        ((Test-Path -LiteralPath (Join-Path $Root 'empire.retail.dll')) -or
         (Test-Path -LiteralPath (Join-Path $Root 'Shogun2.dll')))
}

function Resolve-GameRoot {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $explicit = [System.IO.Path]::GetFullPath($RequestedRoot)
        if (Test-GameRoot $explicit) {
            return $explicit
        }
        throw "The supplied game root does not look like a Shogun 2 install: $explicit"
    }

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    Add-Candidate $candidates 'D:\SteamLibrary\steamapps\common\Total War Shogun 2'

    $steamRoots = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        Add-Candidate $steamRoots (Join-Path ${env:ProgramFiles(x86)} 'Steam')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Add-Candidate $steamRoots (Join-Path $env:ProgramFiles 'Steam')
    }

    foreach ($registryKey in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        if (-not (Test-Path -LiteralPath $registryKey)) {
            continue
        }
        $properties = Get-ItemProperty -LiteralPath $registryKey
        foreach ($propertyName in @('InstallPath', 'SteamPath')) {
            $property = $properties.PSObject.Properties[$propertyName]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                Add-Candidate $steamRoots ([string]$property.Value)
            }
        }
    }

    foreach ($steamRoot in @($steamRoots)) {
        Add-Candidate $candidates (Join-Path $steamRoot 'steamapps\common\Total War Shogun 2')
        $libraryVdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $libraryVdf)) {
            continue
        }
        $vdf = [System.IO.File]::ReadAllText($libraryVdf)
        foreach ($match in [regex]::Matches($vdf, '"path"\s+"([^"]+)"')) {
            $libraryPath = $match.Groups[1].Value.Replace('\\', '\')
            Add-Candidate $candidates (Join-Path $libraryPath 'steamapps\common\Total War Shogun 2')
        }
    }

    foreach ($candidate in @($candidates)) {
        if (Test-GameRoot $candidate) {
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    throw 'Could not locate Total War Shogun 2. Use -GameRoot with the Steam install directory.'
}

function Resolve-LegacyRoot {
    param([string]$RequestedRoot)

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        Add-Candidate $candidates ([System.IO.Path]::GetFullPath($RequestedRoot))
    }
    Add-Candidate $candidates 'C:\Program Files (x86)\Steam\steamapps\content\app_34330'
    Add-Candidate $candidates 'D:\SteamLibrary\steamapps\content\app_34330'

    $steamRoots = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        Add-Candidate $steamRoots (Join-Path ${env:ProgramFiles(x86)} 'Steam')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Add-Candidate $steamRoots (Join-Path $env:ProgramFiles 'Steam')
    }
    foreach ($registryKey in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        if (-not (Test-Path -LiteralPath $registryKey)) {
            continue
        }
        $properties = Get-ItemProperty -LiteralPath $registryKey
        foreach ($propertyName in @('InstallPath', 'SteamPath')) {
            $property = $properties.PSObject.Properties[$propertyName]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                Add-Candidate $steamRoots ([string]$property.Value)
            }
        }
    }
    foreach ($steamRoot in @($steamRoots)) {
        Add-Candidate $candidates (Join-Path $steamRoot 'steamapps\content\app_34330')
        $libraryVdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryVdf) {
            $vdf = [System.IO.File]::ReadAllText($libraryVdf)
            foreach ($match in [regex]::Matches($vdf, '"path"\s+"([^"]+)"')) {
                $libraryPath = $match.Groups[1].Value.Replace('\\', '\')
                Add-Candidate $candidates (Join-Path $libraryPath 'steamapps\content\app_34330')
            }
        }
    }

    foreach ($candidate in @($candidates)) {
        $normalized = $candidate
        if ((Split-Path -Leaf $normalized) -ieq 'depot_34331') {
            $normalized = Split-Path -Parent $normalized
        }

        $missing = @($RequiredDepots | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $normalized $_))
        })
        if ($missing.Count -eq 0) {
            return ([System.IO.Path]::GetFullPath($normalized))
        }
    }

    throw 'Could not find the required legacy depots. Supply -LegacyRoot pointing to the app_34330 directory containing depot_34331, depot_34332, and depot_34334.'
}

function Get-ProcessLock {
    $running = Get-Process -Name 'shogun2', 'shogun2.retail' -ErrorAction SilentlyContinue
    if ($running) {
        throw 'Shogun 2 is running. Exit the game before changing native or data files.'
    }
}

function Is-DataPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    return $RelativePath -match '^(?i)(data|locales)\\'
}

function Get-SourceEntries {
    param([Parameter(Mandatory = $true)][string]$Root)

    $byPath = @{}
    $ordered = New-Object System.Collections.ArrayList
    $depots = @($RequiredDepots + $OptionalDepots)

    foreach ($depot in $depots) {
        $depotRoot = Join-Path $Root $depot
        if (-not (Test-Path -LiteralPath $depotRoot)) {
            continue
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $depotRoot -Recurse -File -Force)) {
            $relative = $file.FullName.Substring($depotRoot.Length).TrimStart('\')
            if ([string]::IsNullOrWhiteSpace($relative) -or
                $relative.StartsWith('..') -or [System.IO.Path]::IsPathRooted($relative)) {
                throw "Unsafe relative path in legacy depot: $($file.FullName)"
            }

            $key = $relative.ToLowerInvariant()
            $entry = [pscustomobject]@{
                RelativePath = $relative
                SourcePath = $file.FullName
                DataPath = Is-DataPath $relative
                Size = $file.Length
            }

            if ($byPath.ContainsKey($key)) {
                $ordered[$byPath[$key]] = $entry
            }
            else {
                $byPath[$key] = $ordered.Count
                [void]$ordered.Add($entry)
            }
        }
    }

    return @($ordered)
}

function Get-BackupRoot {
    param([Parameter(Mandatory = $true)][string]$Root)
    return (Join-Path (Split-Path -Parent $Root) 'Total War Shogun 2.coopfix-backups')
}

function New-BackupDirectory {
    param([Parameter(Mandatory = $true)][string]$Root)

    $backupRoot = Get-BackupRoot $Root
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $directory = Join-Path $backupRoot $stamp
    $suffix = 1
    while (Test-Path -LiteralPath $directory) {
        $directory = Join-Path $backupRoot "$stamp-$suffix"
        $suffix++
    }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    return $directory
}

function Confirm-Change {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    return $PSCmdlet.ShouldProcess($Target, $Operation)
}

function Copy-FileCreatingParent {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::Copy($Source, $Destination, $true)
}

function Install-LegacyBuild {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $true)][bool]$ShouldBackupData
    )

    Get-ProcessLock
    $backupDirectory = New-BackupDirectory $Root
    $records = New-Object System.Collections.ArrayList

    foreach ($entry in $Entries) {
        $destination = Join-Path $Root $entry.RelativePath
        $record = [ordered]@{
            RelativePath = $entry.RelativePath
            Destination = $destination
            SourcePath = $entry.SourcePath
            DataPath = [bool]$entry.DataPath
            InstalledSha256 = $null
            BackupPath = $null
            Introduced = $false
        }

        if (Test-Path -LiteralPath $destination) {
            if (-not $entry.DataPath -or $ShouldBackupData) {
                $backupPath = Join-Path $backupDirectory $entry.RelativePath
                Copy-FileCreatingParent -Source $destination -Destination $backupPath
                $record.BackupPath = $backupPath
            }
        }
        else {
            $record.Introduced = $true
        }

        Copy-FileCreatingParent -Source $entry.SourcePath -Destination $destination
        $record.InstalledSha256 = Get-Sha256 $destination
        [void]$records.Add([pscustomobject]$record)
    }

    foreach ($name in $ModernExtras) {
        $extra = Join-Path $Root $name
        $sourceKey = $name.ToLowerInvariant()
        $sourcePresent = $Entries | Where-Object { $_.RelativePath.ToLowerInvariant() -eq $sourceKey }
        if ((Test-Path -LiteralPath $extra) -and -not $sourcePresent) {
            $extraBackup = Join-Path $backupDirectory (Join-Path 'modern-extras' $name)
            Copy-FileCreatingParent -Source $extra -Destination $extraBackup
            Remove-Item -LiteralPath $extra -Force
            [void]$records.Add([pscustomobject]@{
                RelativePath = $name
                Destination = $extra
                SourcePath = $null
                DataPath = $false
                InstalledSha256 = $null
                BackupPath = $extraBackup
                Introduced = $false
            })
        }
    }

    $manifest = [pscustomobject]@{
        FormatVersion = 1
        InstalledAt = (Get-Date).ToString('o')
        GameRoot = $Root
        LegacyRoot = $SourceRoot
        BackupData = $ShouldBackupData
        Records = @($records)
    }
    $manifestPath = Join-Path $backupDirectory 'manifest.json'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $utf8)

    Write-Output "Installed legacy depot overlay: $SourceRoot"
    Write-Output "Files applied: $($records.Count)"
    Write-Output "Backup: $backupDirectory"
    if ($ShouldBackupData) {
        Write-Output 'Data/locales were backed up as well as native files.'
    }
    else {
        Write-Output 'Data/locales were not backed up; Steam file verification restores the current build if needed.'
    }
}

function Restore-LegacyBuild {
    param([Parameter(Mandatory = $true)][string]$Root)

    Get-ProcessLock
    $backupRoot = Get-BackupRoot $Root
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        throw "No legacy-build backup directory exists: $backupRoot"
    }

    $backup = Get-ChildItem -LiteralPath $backupRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $backup) {
        throw "No legacy-build backup was found: $backupRoot"
    }

    $manifestPath = Join-Path $backup.FullName 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Backup manifest is missing: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    if (-not (Confirm-Change -Target $Root -Operation "restore current files from $($backup.FullName)")) {
        return
    }

    foreach ($record in @($manifest.Records)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$record.BackupPath)) {
            Copy-FileCreatingParent -Source $record.BackupPath -Destination $record.Destination
        }
        elseif ($record.Introduced -and -not $record.DataPath -and (Test-Path -LiteralPath $record.Destination)) {
            if ((Get-Sha256 $record.Destination) -eq $record.InstalledSha256) {
                Remove-Item -LiteralPath $record.Destination -Force
            }
        }
    }

    Write-Output "Restored native files from: $($backup.FullName)"
    if (-not $manifest.BackupData) {
        Write-Output 'Data/locales were not part of the backup. Run Steam file verification to restore the current data build.'
    }
}

$resolvedRoot = Resolve-GameRoot -RequestedRoot $GameRoot

switch ($Action) {
    'Status' {
        $legacy = $null
        try { $legacy = Resolve-LegacyRoot -RequestedRoot $LegacyRoot } catch { }
        $currentFiles = @('Shogun2.exe', 'Shogun2.dll', 'shogun2.retail.exe', 'empire.retail.dll', 'steam_api.dll') |
            ForEach-Object {
                $path = Join-Path $resolvedRoot $_
                [pscustomobject]@{
                    Name = $_
                    Exists = Test-Path -LiteralPath $path
                    Sha256 = if (Test-Path -LiteralPath $path) { Get-Sha256 $path } else { $null }
                }
            }
        $currentFiles
        if ($null -ne $legacy) {
            $entries = @(Get-SourceEntries -Root $legacy)
            $summary = $entries | Measure-Object -Property Size -Sum
            Write-Output "LegacyRoot: $legacy"
            Write-Output "Legacy files: $($summary.Count); bytes: $($summary.Sum)"
        }
        else {
            Write-Output 'LegacyRoot: not found'
        }
        $latest = Get-ChildItem -LiteralPath (Get-BackupRoot $resolvedRoot) -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -eq $latest) { Write-Output 'Latest backup: none' } else { Write-Output "Latest backup: $($latest.FullName)" }
    }

    'Install' {
        $resolvedLegacy = Resolve-LegacyRoot -RequestedRoot $LegacyRoot
        $entries = @(Get-SourceEntries -Root $resolvedLegacy)
        if (-not ($entries | Where-Object { $_.RelativePath -ieq 'Shogun2.exe' })) {
            throw 'Legacy depot is missing Shogun2.exe.'
        }
        if (-not ($entries | Where-Object { $_.RelativePath -ieq 'Shogun2.dll' })) {
            throw 'Legacy depot is missing Shogun2.dll.'
        }

        $summary = $entries | Measure-Object -Property Size -Sum
        Write-Output "Legacy source: $resolvedLegacy"
        Write-Output "Files to apply: $($summary.Count); bytes: $($summary.Sum)"
        if (-not (Confirm-Change -Target $resolvedRoot -Operation 'install the complete supplied legacy depot overlay')) {
            return
        }
        Install-LegacyBuild -Root $resolvedRoot -SourceRoot $resolvedLegacy -Entries $entries -ShouldBackupData:$BackupData
    }

    'Restore' {
        Restore-LegacyBuild -Root $resolvedRoot
    }
}
