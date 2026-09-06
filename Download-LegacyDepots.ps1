[CmdletBinding()]
param(
    [ValidateSet('Guide', 'Status', 'ShowCommands')]
    [string]$Action = 'Guide',

    # Steam's Console always writes download_depot output beneath the Steam
    # client directory, not the library containing the installed game.
    [string]$SteamRoot,

    # Useful when Steam's Console is already visible, and for non-interactive
    # verification of an already-downloaded set of depots.
    [switch]$NoLaunchSteam,

    # Download and validate only; do not start either installer afterward.
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# These are the pre-May-2023 Windows manifests used by the legacy-build test.
# File counts and byte totals make an incomplete Steam Console download fail
# before it can be applied to the game install.
$Depots = @(
    [pscustomobject]@{
        Id = '34331'
        Manifest = '686532749519328994'
        ExpectedFiles = 3
        ExpectedBytes = [Int64]25275469
        RequiredFiles = @('Shogun2.exe', 'Shogun2.dll')
        ExpectedSha256 = @{
            'Shogun2.exe' = '4A42E2E9A246892E5F9762FC97830836B1F6DF4B16603A3A5672E28ECF9DC1F6'
            'Shogun2.dll' = '15B5966B74358C69F59AA66279CFF4F99733DA89A660E834A5ED495EBDAC3AA1'
        }
    }
    [pscustomobject]@{
        Id = '34332'
        Manifest = '7514500714585308624'
        ExpectedFiles = 2713
        ExpectedBytes = [Int64]19960990339
        RequiredFiles = @('steam_api.dll', 'data\\data.pack')
        ExpectedSha256 = @{
            'steam_api.dll' = 'B0FD893EAA8A225510389E04C0802312539A01FD2EB3A1A8A38005CEE7F1D10F'
        }
    }
    [pscustomobject]@{
        Id = '34333'
        Manifest = '1972056557494830740'
        ExpectedFiles = 154
        ExpectedBytes = [Int64]122926803
        RequiredFiles = @('redist\\vcredist_x86.exe')
        ExpectedSha256 = @{}
    }
    [pscustomobject]@{
        Id = '34334'
        Manifest = '8572849454388416810'
        ExpectedFiles = 1571
        ExpectedBytes = [Int64]633340038
        RequiredFiles = @('data\\local_en.pack')
        ExpectedSha256 = @{}
    }
)

function Add-Candidate {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$List,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not $List.Contains($Path)) {
        $List.Add($Path)
    }
}

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

function Test-SteamRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Test-Path -LiteralPath (Join-Path $Path 'steam.exe')
}

function Resolve-SteamRoot {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $explicit = [System.IO.Path]::GetFullPath($RequestedRoot)
        if (Test-SteamRoot $explicit) {
            return $explicit
        }
        throw "The supplied Steam root does not contain steam.exe: $explicit"
    }

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        Add-Candidate $candidates (Join-Path ${env:ProgramFiles(x86)} 'Steam')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        Add-Candidate $candidates (Join-Path $env:ProgramFiles 'Steam')
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
                Add-Candidate $candidates ([string]$property.Value)
            }
        }
    }

    foreach ($candidate in @($candidates)) {
        if (Test-SteamRoot $candidate) {
            return ([System.IO.Path]::GetFullPath($candidate))
        }
    }

    throw 'Could not locate Steam. Supply -SteamRoot with the directory containing steam.exe.'
}

function Get-ContentRoot {
    param([Parameter(Mandatory = $true)][string]$ResolvedSteamRoot)
    return (Join-Path $ResolvedSteamRoot 'steamapps\content\app_34330')
}

function Get-DepotCommand {
    param([Parameter(Mandatory = $true)][pscustomobject]$Depot)
    return "download_depot 34330 $($Depot.Id) $($Depot.Manifest)"
}

function Get-DepotVerification {
    param(
        [Parameter(Mandatory = $true)][string]$ContentRoot,
        [Parameter(Mandatory = $true)][pscustomobject]$Depot
    )

    $depotRoot = Join-Path $ContentRoot "depot_$($Depot.Id)"
    $problems = New-Object System.Collections.ArrayList
    $actualFiles = 0
    [Int64]$actualBytes = 0

    if (-not (Test-Path -LiteralPath $depotRoot)) {
        [void]$problems.Add('folder is missing')
    }
    else {
        $files = @(Get-ChildItem -LiteralPath $depotRoot -Recurse -File -Force)
        $actualFiles = $files.Count
        $measure = $files | Measure-Object -Property Length -Sum
        if ($null -ne $measure.Sum) {
            $actualBytes = [Int64]$measure.Sum
        }

        if ($actualFiles -ne $Depot.ExpectedFiles) {
            [void]$problems.Add("file count is $actualFiles; expected $($Depot.ExpectedFiles)")
        }
        if ($actualBytes -ne $Depot.ExpectedBytes) {
            [void]$problems.Add("byte total is $actualBytes; expected $($Depot.ExpectedBytes)")
        }

        foreach ($relativePath in @($Depot.RequiredFiles)) {
            if (-not (Test-Path -LiteralPath (Join-Path $depotRoot $relativePath))) {
                [void]$problems.Add("required file is missing: $relativePath")
            }
        }

        foreach ($relativePath in $Depot.ExpectedSha256.Keys) {
            $path = Join-Path $depotRoot $relativePath
            if ((Test-Path -LiteralPath $path) -and ((Get-Sha256 $path) -ne $Depot.ExpectedSha256[$relativePath])) {
                [void]$problems.Add("hash mismatch: $relativePath")
            }
        }
    }

    return [pscustomobject]@{
        Depot = $Depot.Id
        Path = $depotRoot
        Complete = ($problems.Count -eq 0)
        ActualFiles = $actualFiles
        ExpectedFiles = $Depot.ExpectedFiles
        ActualBytes = $actualBytes
        ExpectedBytes = $Depot.ExpectedBytes
        Details = if ($problems.Count -eq 0) { 'verified' } else { $problems -join '; ' }
    }
}

function Copy-DepotCommand {
    param([Parameter(Mandatory = $true)][string]$Command)

    $setClipboard = Get-Command -Name Set-Clipboard -ErrorAction SilentlyContinue
    if ($null -ne $setClipboard) {
        Set-Clipboard -Value $Command
        return $true
    }

    $clip = Join-Path $env:SystemRoot 'System32\clip.exe'
    if (Test-Path -LiteralPath $clip) {
        $Command | & $clip
        return $true
    }

    return $false
}

function Open-SteamConsole {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedSteamRoot,
        [Parameter(Mandatory = $true)][bool]$DoNotLaunch
    )

    if ($DoNotLaunch) {
        Write-Output 'Steam Console launch skipped by -NoLaunchSteam.'
        return
    }

    try {
        Start-Process 'steam://open/console' -ErrorAction Stop
    }
    catch {
        $steamExe = Join-Path $ResolvedSteamRoot 'steam.exe'
        Start-Process -FilePath $steamExe -ArgumentList '-console' -ErrorAction Stop
    }
    Write-Output 'Steam Console opened. Sign in with the Steam account that owns Shogun 2 if Steam asks.'
}

function Invoke-GuidedDownload {
    param(
        [Parameter(Mandatory = $true)][string]$ContentRoot,
        [Parameter(Mandatory = $true)][string]$ResolvedSteamRoot,
        [Parameter(Mandatory = $true)][bool]$DoNotLaunch,
        [Parameter(Mandatory = $true)][bool]$DoNotInstall
    )

    Write-Output 'This helper never reads, stores, or transmits Steam credentials.'
    Write-Output 'Close Shogun 2 before starting the final legacy installer.'
    Open-SteamConsole -ResolvedSteamRoot $ResolvedSteamRoot -DoNotLaunch:$DoNotLaunch

    foreach ($depot in $Depots) {
        $verification = Get-DepotVerification -ContentRoot $ContentRoot -Depot $depot
        $commandOffered = $false
        while (-not $verification.Complete) {
            Write-Output ''
            Write-Output "Depot $($depot.Id) is not complete: $($verification.Details)"
            if (-not $commandOffered) {
                $command = Get-DepotCommand -Depot $depot
                $copied = Copy-DepotCommand -Command $command
                if ($copied) {
                    Write-Output 'The required Steam Console command is in your clipboard.'
                }
                Write-Output "Command: $command"
                Write-Output 'Click Steam > CONSOLE, paste the command, and press Enter.'
                Write-Output 'Wait until Steam reports that the depot download completed; the data depot is about 20 GB.'
                $commandOffered = $true
            }
            else {
                Write-Output 'Steam may still be downloading. Do not submit the command again unless Steam reported an error.'
            }
            $answer = Read-Host 'Press Enter to check again; type R only to re-copy/retry after a Steam error'
            if ($answer -match '^[Rr]$') {
                $commandOffered = $false
            }
            $verification = Get-DepotVerification -ContentRoot $ContentRoot -Depot $depot
        }
        Write-Output "Verified depot $($depot.Id): $($verification.ActualFiles) files, $($verification.ActualBytes) bytes."
    }

    Write-Output "All four depots are verified in: $ContentRoot"
    if ($DoNotInstall) {
        Write-Output 'Installer launch skipped by -SkipInstall.'
        return
    }

    [void](Read-Host 'Press Enter to start the guarded legacy installer, or close this window to stop')
    & (Join-Path $PSScriptRoot 'Install-LegacyBuild.ps1') -Action Install -LegacyRoot $ContentRoot
    & (Join-Path $PSScriptRoot 'Shogun2CoopFix.ps1') -Action InstallProfile
    Write-Output 'Legacy files and the shared random-seed profile have been installed.'
}

$resolvedSteamRoot = Resolve-SteamRoot -RequestedRoot $SteamRoot
$contentRoot = Get-ContentRoot -ResolvedSteamRoot $resolvedSteamRoot

switch ($Action) {
    'Status' {
        $Depots |
            ForEach-Object { Get-DepotVerification -ContentRoot $contentRoot -Depot $_ } |
            Select-Object Depot, Complete, ActualFiles, ExpectedFiles, ActualBytes, ExpectedBytes, Details, Path
    }

    'ShowCommands' {
        $Depots | ForEach-Object { Get-DepotCommand -Depot $_ }
    }

    'Guide' {
        Invoke-GuidedDownload -ContentRoot $contentRoot -ResolvedSteamRoot $resolvedSteamRoot -DoNotLaunch:$NoLaunchSteam -DoNotInstall:$SkipInstall
    }
}
