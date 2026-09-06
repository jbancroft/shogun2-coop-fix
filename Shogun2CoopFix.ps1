[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Status', 'InstallProfile', 'InstallDiagnostics', 'RestoreProfile', 'ShowLogSummary')]
    [string]$Action = 'Status',

    [string]$GameRoot,

    [ValidateRange(0, 2147483647)]
    [int]$Seed = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This is the build observed on the user's machine on 2026-09-05.  The guard
# prevents silently applying a profile to an unreviewed executable revision.
$ExpectedRetailExeSha256 = '0AB284186E0BE3FBCDE34E2F800E3C0328008F3219490C7C25E822ADD837C4A9'
$ExpectedEmpireDllSha256 = '022FAE2E2DA92B59B8B1B8EE52887003C624E3C8ECA060B209F5D792A7F874F5'

$ProfileBegin = '# >>> Shogun2CoopFix BEGIN'
$ProfileEnd = '# <<< Shogun2CoopFix END'
$ProfilePattern = '(?ms)^# >>> Shogun2CoopFix BEGIN.*?^# <<< Shogun2CoopFix END\s*\r?\n?'

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

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
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

function Resolve-GameRoot {
    param([string]$RequestedRoot)

    function Test-GameRoot {
        param([Parameter(Mandatory = $true)][string]$Root)

        return (Test-Path -LiteralPath (Join-Path $Root 'Shogun2.exe')) -and
            ((Test-Path -LiteralPath (Join-Path $Root 'empire.retail.dll')) -or
             (Test-Path -LiteralPath (Join-Path $Root 'Shogun2.dll')))
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $explicit = [System.IO.Path]::GetFullPath($RequestedRoot)
        if (Test-GameRoot $explicit) {
            return $explicit
        }
        throw "The supplied game root does not look like a Shogun 2 install: $explicit"
    }

    $candidates = New-Object 'System.Collections.Generic.List[string]'

    # The installed copy found during analysis was here.  Keep this direct
    # candidate because it also works when Steam's VDF is not readable.
    Add-Candidate $candidates 'D:\SteamLibrary\steamapps\common\Total War Shogun 2'

    $steamRoots = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        Add-Candidate $steamRoots (Join-Path ${env:ProgramFiles(x86)} 'Steam')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Add-Candidate $steamRoots (Join-Path $env:ProgramFiles 'Steam')
    }

    # Cover Steam installations outside the two Program Files defaults.  The
    # registry lookup is read-only and is also useful on the other player's PC.
    $registryKeys = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )
    foreach ($registryKey in $registryKeys) {
        if (-not (Test-Path -LiteralPath $registryKey)) {
            continue
        }

        $registryProperties = Get-ItemProperty -LiteralPath $registryKey
        foreach ($propertyName in @('InstallPath', 'SteamPath')) {
            $property = $registryProperties.PSObject.Properties[$propertyName]
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

function Get-GameBuild {
    param([Parameter(Mandatory = $true)][string]$Root)

    $files = @('shogun2.exe', 'shogun2.retail.exe', 'empire.retail.dll')
    $hashes = @{}
    foreach ($name in $files) {
        $path = Join-Path $Root $name
        $hashes[$name] = if (Test-Path -LiteralPath $path) { Get-Sha256 $path } else { $null }
    }

    $retailMatches = ($hashes['shogun2.exe'] -eq $ExpectedRetailExeSha256) -and
        ($hashes['shogun2.retail.exe'] -eq $ExpectedRetailExeSha256)
    $dllMatches = $hashes['empire.retail.dll'] -eq $ExpectedEmpireDllSha256

    return [pscustomobject]@{
        Root = $Root
        Shogun2ExeSha256 = $hashes['shogun2.exe']
        Shogun2RetailExeSha256 = $hashes['shogun2.retail.exe']
        EmpireRetailDllSha256 = $hashes['empire.retail.dll']
        MatchesReviewedBuild = ($retailMatches -and $dllMatches)
    }
}

function Get-UserScriptPath {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw 'APPDATA is not set; cannot locate the Shogun 2 user scripts directory.'
    }

    return (Join-Path $env:APPDATA 'The Creative Assembly\Shogun2\scripts\user.script.txt')
}

function Get-ProfileBlock {
    param(
        [Parameter(Mandatory = $true)][int]$ProfileSeed,
        [Parameter(Mandatory = $true)][bool]$Diagnostics
    )

    $lines = @(
        $ProfileBegin,
        '# Keep this value identical on every human player machine.',
        "constant_random_seed $ProfileSeed;"
    )

    if ($Diagnostics) {
        $lines += @(
            '# Temporary diagnostics: remove with RestoreProfile after collecting logs.',
            'mp_network_sync_logging true;',
            'output_sync_logs true;'
        )
    }
    else {
        $lines += @(
            '# Diagnostics are intentionally off for normal play.',
            '# Enable them with -Action InstallDiagnostics only while reproducing a failure.'
        )
    }

    $lines += $ProfileEnd
    return ($lines -join [Environment]::NewLine)
}

function Remove-ProfileBlock {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    return [regex]::Replace($Content, $ProfilePattern, '')
}

function Install-Profile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$ProfileSeed,
        [Parameter(Mandatory = $true)][bool]$Diagnostics
    )

    $directory = Split-Path -Parent $Path
    $exists = Test-Path -LiteralPath $Path
    $oldContent = if ($exists) { [System.IO.File]::ReadAllText($Path) } else { '' }
    $cleanContent = Remove-ProfileBlock $oldContent
    $block = Get-ProfileBlock -ProfileSeed $ProfileSeed -Diagnostics:$Diagnostics
    $cleanContent = $cleanContent.TrimEnd()

    $newContent = if ([string]::IsNullOrWhiteSpace($cleanContent)) {
        $block + [Environment]::NewLine
    }
    else {
        $cleanContent + [Environment]::NewLine + [Environment]::NewLine +
            $block + [Environment]::NewLine
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'install the Shogun2CoopFix user-script profile')) {
        return
    }

    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if ($exists) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$Path.shogun2coopfix.$stamp.bak"
        $suffix = 1
        while (Test-Path -LiteralPath $backup) {
            $backup = "$Path.shogun2coopfix.$stamp-$suffix.bak"
            $suffix++
        }
        Copy-Item -LiteralPath $Path -Destination $backup -Force
        Write-Output "Backup: $backup"
    }

    Write-Utf8NoBom -Path $Path -Content $newContent
    Write-Output "Installed profile: $Path"
}

function Restore-Profile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Output "No user script exists: $Path"
        return
    }

    $oldContent = [System.IO.File]::ReadAllText($Path)
    $newContent = Remove-ProfileBlock $oldContent
    if ($newContent -eq $oldContent) {
        Write-Output 'No Shogun2CoopFix profile block was found; no changes made.'
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'remove only the Shogun2CoopFix profile block')) {
        Write-Utf8NoBom -Path $Path -Content $newContent
        Write-Output "Removed profile block: $Path"
        Write-Output 'The timestamped backup created at install time was retained.'
    }
}

function Show-LogSummary {
    $scriptPath = Get-UserScriptPath
    $logDirectory = Split-Path -Parent (Split-Path -Parent $scriptPath)
    $logDirectory = Join-Path $logDirectory 'logs'

    if (-not (Test-Path -LiteralPath $logDirectory)) {
        Write-Output "No log directory exists yet: $logDirectory"
        return
    }

    $logs = Get-ChildItem -LiteralPath $logDirectory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)(desync|sync|network)' } |
        Sort-Object LastWriteTime -Descending

    if (-not $logs) {
        Write-Output "No sync-related logs found in $logDirectory"
        return
    }

    foreach ($log in $logs) {
        Write-Output "### $($log.FullName) [$($log.Length) bytes, $($log.LastWriteTime)]"
        Get-Content -LiteralPath $log.FullName -Tail 60
    }
}

$resolvedRoot = Resolve-GameRoot -RequestedRoot $GameRoot
$build = Get-GameBuild -Root $resolvedRoot
$userScript = Get-UserScriptPath

switch ($Action) {
    'Status' {
        $profileInstalled = $false
        if (Test-Path -LiteralPath $userScript) {
            $profileInstalled = [regex]::IsMatch(
                [System.IO.File]::ReadAllText($userScript),
                $ProfilePattern
            )
        }

        $build | Add-Member -NotePropertyName UserScript -NotePropertyValue $userScript
        $build | Add-Member -NotePropertyName ProfileInstalled -NotePropertyValue $profileInstalled
        $build
    }

    'InstallProfile' {
        if (-not $build.MatchesReviewedBuild) {
            Write-Warning 'This is not the reviewed current build. The user-script profile is still safe to apply, but verify that every multiplayer participant uses the same build.'
        }
        Install-Profile -Path $userScript -ProfileSeed $Seed -Diagnostics:$false
    }

    'InstallDiagnostics' {
        if (-not $build.MatchesReviewedBuild) {
            Write-Warning 'This is not the reviewed current build. Diagnostics will be enabled, but every multiplayer participant must use the same build.'
        }
        Install-Profile -Path $userScript -ProfileSeed $Seed -Diagnostics:$true
    }

    'RestoreProfile' {
        Restore-Profile -Path $userScript
    }

    'ShowLogSummary' {
        Show-LogSummary
    }
}
