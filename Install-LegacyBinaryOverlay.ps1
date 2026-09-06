[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Status', 'Install', 'Restore')]
    [string]$Action = 'Status',

    [string]$GameRoot,

    [string]$LegacyRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# These are the only native files this helper is allowed to replace.  It does
# not recursively copy a depot into the Steam directory and cannot touch data,
# saves, Workshop content, or unrelated DLLs.
$AllowedFiles = @('shogun2.exe', 'shogun2.retail.exe', 'empire.retail.dll', 'steam_api.dll')
$ExpectedRetailExeSha256 = '0AB284186E0BE3FBCDE34E2F800E3C0328008F3219490C7C25E822ADD837C4A9'
$ExpectedEmpireDllSha256 = '022FAE2E2DA92B59B8B1B8EE52887003C624E3C8ECA060B209F5D792A7F874F5'

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

function Resolve-GameRoot {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $explicit = [System.IO.Path]::GetFullPath($RequestedRoot)
        if (Test-Path -LiteralPath (Join-Path $explicit 'empire.retail.dll')) {
            return $explicit
        }
        throw "The supplied game root does not contain empire.retail.dll: $explicit"
    }

    $known = 'D:\SteamLibrary\steamapps\common\Total War Shogun 2'
    if (Test-Path -LiteralPath (Join-Path $known 'empire.retail.dll')) {
        return $known
    }

    throw 'Could not locate Total War Shogun 2. Use -GameRoot with the Steam install directory.'
}

function Get-ProcessLock {
    $running = Get-Process -Name 'shogun2', 'shogun2.retail' -ErrorAction SilentlyContinue
    if ($running) {
        throw 'Shogun 2 is running. Exit the game and Steam before changing native files.'
    }
}

function Get-CurrentFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    foreach ($name in $AllowedFiles) {
        $path = Join-Path $Root $name
        [pscustomobject]@{
            Name = $name
            Path = $path
            Exists = Test-Path -LiteralPath $path
            Sha256 = if (Test-Path -LiteralPath $path) { Get-Sha256 $path } else { $null }
        }
    }
}

function Get-LatestBackup {
    param([Parameter(Mandatory = $true)][string]$Root)

    $backupRoot = Join-Path $Root '.shogun2coopfix-backups'
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $backupRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Confirm-Change {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    return $PSCmdlet.ShouldProcess($Target, $Operation)
}

$resolvedRoot = Resolve-GameRoot -RequestedRoot $GameRoot
$current = @(Get-CurrentFiles -Root $resolvedRoot)

switch ($Action) {
    'Status' {
        $current
        $latestBackup = Get-LatestBackup -Root $resolvedRoot
        if ($null -eq $latestBackup) {
            Write-Output 'Latest backup: none'
        }
        else {
            Write-Output "Latest backup: $($latestBackup.FullName)"
        }
    }

    'Install' {
        if ([string]::IsNullOrWhiteSpace($LegacyRoot)) {
            throw 'Install requires -LegacyRoot pointing to a Windows pre-update executable depot or a staging directory.'
        }

        $sourceRoot = [System.IO.Path]::GetFullPath($LegacyRoot)
        if (-not (Test-Path -LiteralPath $sourceRoot)) {
            throw "Legacy source directory does not exist: $sourceRoot"
        }

        Get-ProcessLock

        $source = @($AllowedFiles | ForEach-Object {
            $sourcePath = Join-Path $sourceRoot $_
            if (Test-Path -LiteralPath $sourcePath) {
                [pscustomobject]@{ Name = $_; Path = $sourcePath; Sha256 = Get-Sha256 $sourcePath }
            }
        })

        # A partial executable set can create a new mismatch, so require the
        # two core files that determine the campaign engine before replacing
        # anything. steam_api.dll is optional because depot layouts vary.
        $required = @('shogun2.exe', 'empire.retail.dll')
        foreach ($name in $required) {
            if (-not ($source | Where-Object Name -eq $name)) {
                throw "Legacy source is incomplete; required file is missing: $name"
            }
        }

        $backupRoot = Join-Path $resolvedRoot '.shogun2coopfix-backups'
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupDirectory = Join-Path $backupRoot $stamp

        if (-not (Confirm-Change -Target $resolvedRoot -Operation 'install the supplied legacy executable overlay')) {
            return
        }

        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        $manifest = @()

        foreach ($item in $source) {
            $destination = Join-Path $resolvedRoot $item.Name
            if (Test-Path -LiteralPath $destination) {
                $backupPath = Join-Path $backupDirectory $item.Name
                Copy-Item -LiteralPath $destination -Destination $backupPath -Force
                $manifest += [pscustomobject]@{
                    Name = $item.Name
                    BackupPath = $backupPath
                    OriginalSha256 = Get-Sha256 $destination
                }
            }

            Copy-Item -LiteralPath $item.Path -Destination $destination -Force
            Write-Output "Installed: $($item.Name) [$($item.Sha256)]"
        }

        $manifestPath = Join-Path $backupDirectory 'manifest.json'
        $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        Write-Output "Backup: $backupDirectory"
        Write-Output 'This helper replaced only recognized native files. It did not copy the legacy data depot.'
    }

    'Restore' {
        Get-ProcessLock
        $backup = Get-LatestBackup -Root $resolvedRoot
        if ($null -eq $backup) {
            throw 'No Shogun2CoopFix native-file backup was found.'
        }

        $manifestPath = Join-Path $backup.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "Backup manifest is missing: $manifestPath"
        }

        $manifest = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
        if (Confirm-Change -Target $resolvedRoot -Operation "restore native files from $($backup.FullName)") {
            foreach ($item in $manifest) {
                $destination = Join-Path $resolvedRoot $item.Name
                Copy-Item -LiteralPath $item.BackupPath -Destination $destination -Force
                Write-Output "Restored: $($item.Name)"
            }
            Write-Output "Restored from: $($backup.FullName)"
        }
    }
}
