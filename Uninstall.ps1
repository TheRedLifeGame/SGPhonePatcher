[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$GamePath,
    [switch]$RemoveBackup
)

$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $packageRoot 'PhonePatch.ps1')

$configPath = Join-Path $packageRoot 'Config.local.json'
if (-not (Test-Path -LiteralPath $configPath)) { $configPath = Join-Path $packageRoot 'Config.json' }
$config = Get-Content -Raw $configPath | ConvertFrom-Json
$gameRoot = Resolve-GamePath -ConfiguredPath $config.GamePath -CommandLinePath $GamePath
Assert-GameRoot $gameRoot
Assert-GameClosed

$backupRoot = Join-Path $gameRoot 'PhonePatcherBackup'
if (-not (Test-Path -LiteralPath $backupRoot)) {
    throw "No 1.0.0 backup was found in $gameRoot."
}

$statePath = Join-Path $backupRoot 'install-state.json'
if (-not (Test-Path -LiteralPath $statePath)) {
    throw "The record is missing from $backupRoot."
}
$state = Get-Content -Raw $statePath | ConvertFrom-Json
$changedArchives = @($state.ChangedArchives)
if ($changedArchives.Count -eq 0) {
    throw 'The install record does not list any changed archives.'
}

foreach ($name in $changedArchives) {
    $backup = Join-Path $backupRoot $name
    $destination = if ($name -eq 'enscript.mpk') { Join-Path $gameRoot 'languagebarrier\enscript.mpk' } else { Join-Path $gameRoot "USRDIR\$name" }
    if (-not (Test-Path -LiteralPath $backup)) {
        throw "The backup is incomplete: $backup"
    }
    if ($PSCmdlet.ShouldProcess($destination, 'Restore original archive')) {
        Copy-Item -LiteralPath $backup -Destination $destination -Force
    }
}

if ($RemoveBackup -and $PSCmdlet.ShouldProcess($backupRoot, 'Remove patch backup')) {
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

Write-Output "Restored the archives changed by the patch."
if (-not $RemoveBackup) {
    Write-Output "The backup was kept at $backupRoot"
}
