[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Status', 'Install', 'Restore')]
    [string]$Action = 'Status',

    [string]$GameRoot,

    [string]$LegacyRoot,

    [switch]$BackupData
)

# Backwards-compatible entry point. The downloaded Steam rollback files use a
# full depot layout, so the implementation lives in Install-LegacyBuild.ps1.
$implementation = Join-Path $PSScriptRoot 'Install-LegacyBuild.ps1'
& $implementation @PSBoundParameters
exit $LASTEXITCODE
