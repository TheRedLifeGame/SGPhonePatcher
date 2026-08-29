[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$GamePath
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

$ringtones = @($config.Ringtones)
$wallpapers = @($config.Wallpapers)
$forceUnlock = [bool]$config.ForceUnlockWallpapers
$hasScriptChange = $forceUnlock -or $ringtones.Count -gt 0 -or $wallpapers.Count -gt 0

if (-not $hasScriptChange) {
    throw 'Config.json does not request any changes.'
}

$backupRoot = Join-Path $gameRoot 'PhonePatcherBackup'
$archivePaths = @{
    bgm = Join-Path $gameRoot 'USRDIR\bgm.mpk'
    se = Join-Path $gameRoot 'USRDIR\se.mpk'
    system = Join-Path $gameRoot 'USRDIR\system.mpk'
    enscript = Join-Path $gameRoot 'languagebarrier\enscript.mpk'
}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
foreach ($key in $archivePaths.Keys) {
    $source = $archivePaths[$key]
    $backup = Join-Path $backupRoot ($key + '.mpk')
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Missing game archive: $source"
    }
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $source -Destination $backup
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('SGPhonePatch_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $toolSourceRoot = Join-Path $packageRoot 'tools\MagesScriptTool'
    $toolRoot = Join-Path $tempRoot 'MagesScriptTool'
    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $toolSourceRoot '*') -Destination $toolRoot -Recurse -Force
    $toolPath = Join-Path $toolRoot 'MagesScriptTool.exe'
    $bankPath = Join-Path $packageRoot 'tools\mgs-spec-bank'
    Assert-Tooling $toolPath $bankPath
    $texconvPath = Join-Path $packageRoot 'tools\DirectXTex\texconv.exe'
    Assert-Texconv $texconvPath

    $scriptSource = Join-Path $tempRoot 'source'
    $scriptCompiled = Join-Path $tempRoot 'compiled'
    New-Item -ItemType Directory -Path $scriptSource -Force | Out-Null
    New-Item -ItemType Directory -Path $scriptCompiled -Force | Out-Null

    $enscriptEntries = Read-MpkEntries $archivePaths.enscript
    $mailEntry = $enscriptEntries | Where-Object { $_.Name -ieq '_MAIL.SCX' }
    if ($null -eq $mailEntry) {
        throw 'The game script archive does not contain _MAIL.SCX.'
    }
    Export-MpkEntry $archivePaths.enscript $mailEntry (Join-Path $scriptCompiled '_MAIL.scx')
    Invoke-MagesScriptTool $toolPath $bankPath 'Decompile' $scriptSource $scriptCompiled

    $sctPath = Join-Path $scriptSource '_MAIL.sct'
    $scsPath = Join-Path $scriptSource '_MAIL.scs'
    if (-not (Test-Path -LiteralPath $sctPath) -or -not (Test-Path -LiteralPath $scsPath)) {
        throw 'The MAGES script tool did not produce the phone script files.'
    }

$ringtoneEntries = @()
$wallpaperEntries = @()
$labels = @()
$nextLabelId = Get-NextLabelId $sctPath
foreach ($item in $ringtones) {
    $entry = Convert-RingtoneEntry $item $packageRoot
    $entry.LabelId = $nextLabelId
    $nextLabelId++
    $ringtoneEntries += $entry
    $labels += $entry
}

foreach ($item in $wallpapers) {
        $entry = Convert-WallpaperEntry $item $packageRoot $tempRoot
    $entry.LabelId = $nextLabelId
    $nextLabelId++
    $wallpaperEntries += $entry
    $labels += $entry
}

    if ($labels.Count -gt 0) {
        Add-PhoneLabels $sctPath $labels
    }

    if ($ringtones.Count -gt 0) {
        $bgmEntries = Read-MpkEntries $archivePaths.bgm
        $seEntries = Read-MpkEntries $archivePaths.se
        $nextBgmId = (($bgmEntries | Measure-Object -Property FileId -Maximum).Maximum + 1)
        $nextSeId = (($seEntries | Measure-Object -Property FileId -Maximum).Maximum + 1)
        for ($i = 0; $i -lt $ringtoneEntries.Count; $i++) {
            $ringtoneEntries[$i].BgmId = $nextBgmId + $i
            $ringtoneEntries[$i].SeId = $nextSeId + $i
        }
    }

    $scriptText = [IO.File]::ReadAllText($scsPath)
    if ($forceUnlock -or $wallpapers.Count -gt 0) {
        $scriptText = Update-WallpaperChunk $scriptText $forceUnlock $wallpaperEntries
    }
    if ($ringtones.Count -gt 0) {
        $scriptText = Update-RingtoneChunk $scriptText $ringtoneEntries
    }
    [IO.File]::WriteAllText($scsPath, $scriptText, [Text.UTF8Encoding]::new($false))

    Invoke-MagesScriptTool $toolPath $bankPath 'Compile' $scriptSource $scriptCompiled
    $compiledMail = Get-ChildItem -LiteralPath $scriptCompiled -File | Where-Object { $_.Name -ieq '_MAIL.scx' } | Select-Object -First 1
    if ($null -eq $compiledMail) {
        throw 'The MAGES script tool did not produce a compiled _MAIL.SCX.'
    }

    $outputs = @()
    $outputs += [pscustomobject]@{ Source = $archivePaths.enscript; Replacement = $compiledMail.FullName; Additions = @() }

    if ($ringtones.Count -gt 0) {
        $bgmAdditions = @()
        $seAdditions = @()
        for ($i = 0; $i -lt $ringtoneEntries.Count; $i++) {
            $entry = $ringtoneEntries[$i]
            $base = ('PHONE_RING_{0:D2}' -f ($i + 1))
            $bgmId = $entry.BgmId
            $seId = $entry.SeId
            $bgmAdditions += [pscustomobject]@{ FileId = $bgmId; Name = "$base.OGG"; Path = $entry.AudioPath }
            $previewPath = if ([string]::IsNullOrWhiteSpace($entry.PreviewPath)) { $entry.AudioPath } else { $entry.PreviewPath }
            $seAdditions += [pscustomobject]@{ FileId = $seId; Name = "${base}_PREVIEW.OGG"; Path = $previewPath }
        }
        $outputs += [pscustomobject]@{ Source = $archivePaths.bgm; Replacement = $null; Additions = $bgmAdditions }
        $outputs += [pscustomobject]@{ Source = $archivePaths.se; Replacement = $null; Additions = $seAdditions }
    }

    if ($wallpapers.Count -gt 0) {
        $wallpaperTextures = Build-WallpaperAtlases $archivePaths.system $wallpaperEntries $texconvPath $tempRoot
        $outputs += [pscustomobject]@{ Source = $archivePaths.system; Replacement = $null; Additions = $wallpaperTextures }
    }

    foreach ($output in $outputs) {
        $tempArchive = Join-Path $tempRoot ([IO.Path]::GetFileName($output.Source) + '.new')
        Build-MpkArchive $output.Source $tempArchive $output.Replacement $output.Additions
        if ($PSCmdlet.ShouldProcess($output.Source, 'Install phone patch archive')) {
            Move-Item -LiteralPath $tempArchive -Destination $output.Source -Force
        }
    }

    $state = [ordered]@{
        Version = '1.0.0'
        InstalledAt = [DateTime]::UtcNow.ToString('o')
        GamePath = $gameRoot
        BackupPath = $backupRoot
        ForceUnlockWallpapers = $forceUnlock
        RingtoneCount = $ringtones.Count
        WallpaperCount = $wallpapers.Count
        ChangedArchives = @($outputs | ForEach-Object { [IO.Path]::GetFileName($_.Source) })
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupRoot 'install-state.json') -Encoding utf8
    Write-Output "Installed patch in $gameRoot"
    Write-Output "Backups are stored in $backupRoot"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
