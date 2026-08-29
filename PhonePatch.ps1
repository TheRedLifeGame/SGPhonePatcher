Set-StrictMode -Version Latest

$script:Alignment = 0x800
$script:TocOffset = 0x40
$script:TocEntrySize = 0x100

# These dimensions match the phone texture atlases shipped in system.mpk.
$script:WallpaperWidth = 415
$script:WallpaperHeight = 477
$script:WallpaperAtlasWidth = 4096
$script:WallpaperAtlasHeight = 2048
$script:ThumbnailWidth = 64
$script:ThumbnailHeight = 72
$script:ThumbnailAtlasWidth = 768
$script:ThumbnailAtlasHeight = 768

function Resolve-GamePath {
    param([string]$ConfiguredPath, [string]$CommandLinePath)
    $candidate = $CommandLinePath
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $ConfiguredPath }
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = Read-Host 'STEINS;GATE game folder' }
    if ([string]::IsNullOrWhiteSpace($candidate)) { throw 'A game folder is required.' }
    return [IO.Path]::GetFullPath($candidate)
}

function Assert-GameRoot {
    param([string]$GameRoot)
    if (-not (Test-Path -LiteralPath $GameRoot -PathType Container)) { throw "Game folder not found: $GameRoot" }
    foreach ($path in @('USRDIR\bg.mpk', 'USRDIR\bgm.mpk', 'USRDIR\se.mpk', 'USRDIR\system.mpk', 'languagebarrier\enscript.mpk')) {
        if (-not (Test-Path -LiteralPath (Join-Path $GameRoot $path) -PathType Leaf)) { throw "Game archive not found: $(Join-Path $GameRoot $path)" }
    }
}

function Assert-GameClosed {
    $running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(Game|Launcher|LauncherC0|steins|sghd)$' }
    if ($running) { throw 'Close STEINS;GATE before changing its archives.' }
}

function Assert-Tooling {
    param([string]$ToolPath, [string]$BankPath)
    if (-not (Test-Path -LiteralPath $ToolPath -PathType Leaf)) { throw "MAGES script tool not found: $ToolPath" }
    if (-not (Test-Path -LiteralPath $BankPath -PathType Container)) { throw "MAGES specification bank not found: $BankPath" }
}

function Assert-Texconv {
    param([string]$ToolPath)
    if (-not (Test-Path -LiteralPath $ToolPath -PathType Leaf)) { throw "DirectXTex texconv was not found: $ToolPath" }
}

function Read-MpkEntries {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'MPK' + [char]0) { throw "Not an MPK archive: $Path" }
        $stream.Position = 8
        $count = $reader.ReadInt64()
        $stream.Position = $script:TocOffset
        $result = @()
        for ($i = 0; $i -lt $count; $i++) {
            $raw = $reader.ReadBytes($script:TocEntrySize)
            if ($raw.Length -ne $script:TocEntrySize) { throw "Incomplete MPK table: $Path" }
            $nameBytes = $raw[0x20..0xFF]
            $zero = [Array]::IndexOf($nameBytes, [byte]0)
            if ($zero -lt 0) { $zero = $nameBytes.Length }
            $name = [Text.Encoding]::ASCII.GetString($nameBytes, 0, $zero)
            $result += [pscustomobject]@{
                Compression = [BitConverter]::ToUInt32($raw, 0)
                FileId = [BitConverter]::ToUInt32($raw, 4)
                Offset = [BitConverter]::ToInt64($raw, 8)
                CompressedSize = [BitConverter]::ToInt64($raw, 16)
                UncompressedSize = [BitConverter]::ToInt64($raw, 24)
                Name = $name
            }
        }
        return $result
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Copy-Bytes {
    param([IO.Stream]$Source, [IO.Stream]$Destination, [long]$Count)
    $buffer = [byte[]]::new(1048576)
    $remaining = $Count
    while ($remaining -gt 0) {
        $size = if ($remaining -gt $buffer.Length) { $buffer.Length } else { [int]$remaining }
        $read = $Source.Read($buffer, 0, $size)
        if ($read -le 0) { throw 'Unexpected end of archive payload.' }
        $Destination.Write($buffer, 0, $read)
        $remaining -= $read
    }
}

function Write-Zeroes {
    param([IO.Stream]$Stream, [long]$Count)
    if ($Count -le 0) { return }
    $zeroLength = if ($Count -gt 1048576) { 1048576 } else { [int]$Count }
    $zeros = [byte[]]::new($zeroLength)
    $remaining = $Count
    while ($remaining -gt 0) {
        $write = if ($remaining -gt $zeros.Length) { $zeros.Length } else { [int]$remaining }
        $Stream.Write($zeros, 0, $write)
        $remaining -= $write
    }
}

function Align-Value {
    param([long]$Value)
    return ($Value + $script:Alignment - 1) -band (-$script:Alignment)
}

function Build-MpkArchive {
    param([string]$SourcePath, [string]$OutputPath, [string]$ReplacementPath, [array]$Additions)
    $sourceEntries = Read-MpkEntries $SourcePath
    $entries = @($sourceEntries | ForEach-Object { [pscustomobject]@{ Compression = $_.Compression; FileId = $_.FileId; Offset = $_.Offset; OriginalOffset = $_.Offset; CompressedSize = $_.CompressedSize; UncompressedSize = $_.UncompressedSize; Name = $_.Name; PayloadPath = $null } })
    if ($ReplacementPath) {
        $mail = $entries | Where-Object { $_.Name -ieq '_MAIL.SCX' }
        if ($null -eq $mail) { throw "_MAIL.SCX not found in $SourcePath" }
        $mail.PayloadPath = $ReplacementPath
        $mail.Compression = 0
    }
    foreach ($addition in @($Additions)) {
        if ($null -eq $addition) { continue }
        if ($addition.Name -notmatch '^[ -~]+$' -or $addition.Name.Length -gt 223) { throw "MPK file name must be short ASCII: $($addition.Name)" }
        $existing = @($entries | Where-Object { $_.FileId -eq [uint32]$addition.FileId -or $_.Name -eq $addition.Name })
        if ($existing.Count -gt 0) {
            if ($existing.Count -ne 1 -or $existing[0].FileId -ne [uint32]$addition.FileId -or $existing[0].Name -ne $addition.Name) { throw "MPK file ID or name conflicts with an existing entry: $($addition.Name)" }
            $existing[0].PayloadPath = $addition.Path
            $existing[0].Compression = 0
            continue
        }
        $entries += [pscustomobject]@{ Compression = 0; FileId = [uint32]$addition.FileId; Offset = 0L; OriginalOffset = 0L; CompressedSize = 0L; UncompressedSize = 0L; Name = $addition.Name; PayloadPath = $addition.Path }
    }
    $source = [IO.File]::OpenRead($SourcePath)
    $output = [IO.File]::Create($OutputPath)
    $writer = [IO.BinaryWriter]::new($output)
    try {
        $writer.Write([byte[]](0x4D, 0x50, 0x4B, 0, 0, 0, 2, 0))
        $writer.Write([int64]$entries.Count)
        Write-Zeroes $output ($script:TocOffset - $output.Position)
        Write-Zeroes $output ($entries.Count * $script:TocEntrySize)
        $output.Position = Align-Value $output.Position
        foreach ($entry in $entries) {
            $entry.Offset = $output.Position
            if ($entry.PayloadPath) {
                $payload = [IO.File]::OpenRead($entry.PayloadPath)
                try { $payload.CopyTo($output) } finally { $payload.Dispose() }
                $entry.CompressedSize = $output.Position - $entry.Offset
                $entry.UncompressedSize = $entry.CompressedSize
            } else {
                $source.Position = $entry.OriginalOffset
                Copy-Bytes $source $output $entry.CompressedSize
            }
        $aligned = Align-Value $output.Position
        Write-Zeroes $output ($aligned - $output.Position)
        }
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $entry = $entries[$i]
            $record = [byte[]]::new($script:TocEntrySize)
            [Array]::Copy([BitConverter]::GetBytes([uint32]$entry.Compression), 0, $record, 0, 4)
            [Array]::Copy([BitConverter]::GetBytes([uint32]$entry.FileId), 0, $record, 4, 4)
            [Array]::Copy([BitConverter]::GetBytes([int64]$entry.Offset), 0, $record, 8, 8)
            [Array]::Copy([BitConverter]::GetBytes([int64]$entry.CompressedSize), 0, $record, 16, 8)
            [Array]::Copy([BitConverter]::GetBytes([int64]$entry.UncompressedSize), 0, $record, 24, 8)
            $name = [Text.Encoding]::ASCII.GetBytes($entry.Name)
            [Array]::Copy($name, 0, $record, 0x20, $name.Length)
            $output.Position = $script:TocOffset + ($i * $script:TocEntrySize)
            $output.Write($record, 0, $record.Length)
        }
    }
    finally {
        $writer.Dispose()
        $source.Dispose()
        $output.Dispose()
    }
}

function Export-MpkEntry {
    param([string]$ArchivePath, $Entry, [string]$OutputPath)
    if ($Entry.Compression -ne 0) { throw "Compressed MPK entries are not supported: $($Entry.Name)" }
    $source = [IO.File]::OpenRead($ArchivePath)
    $destination = [IO.File]::Create($OutputPath)
    try {
        $source.Position = $Entry.Offset
        Copy-Bytes $source $destination $Entry.CompressedSize
    }
    finally {
        $source.Dispose()
        $destination.Dispose()
    }
}

function Invoke-MagesScriptTool {
    param([string]$ToolPath, [string]$BankPath, [string]$Mode, [string]$SourceDirectory, [string]$CompiledDirectory)
    $arguments = @('--mode', $Mode, '--uncompiled-directory', $SourceDirectory, '--compiled-directory', $CompiledDirectory, '--bank-directory', $BankPath, '--flag-set', 'steins_gate_hd', '--charset', 'steins_gate_hd', '--string-unit-encoding', 'UInt16')
    & $ToolPath @arguments
    if ($LASTEXITCODE -ne 0) { throw "MAGES script tool failed with exit code $LASTEXITCODE." }
}

function Get-NextLabelId {
    param([string]$Path)
    $max = -1
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^([0-9]+):') {
            $id = [int]$Matches[1]
            if ($id -gt $max) { $max = $id }
        }
    }
    if ($max -ge 65534) { throw 'The phone script has no available label IDs.' }
    return $max + 1
}

function Convert-RingtoneEntry {
    param($Item, [string]$PackageRoot)
    $name = [string]$Item.Name
    $audio = [string]$Item.Audio
    $preview = [string]$Item.Preview
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($audio)) { throw 'Every ringtone needs Name and Audio.' }
    Assert-LabelName $name
    $audioPath = Resolve-PackageFile $PackageRoot $audio
    if ([IO.Path]::GetExtension($audioPath).ToLowerInvariant() -ne '.ogg') { throw "Ringtones must be OGG Vorbis files: $audio" }
    $previewPath = $null
    if (-not [string]::IsNullOrWhiteSpace($preview)) {
        $previewPath = Resolve-PackageFile $PackageRoot $preview
        if ([IO.Path]::GetExtension($previewPath).ToLowerInvariant() -ne '.ogg') { throw "Previews must be OGG Vorbis files: $preview" }
    }
    return [pscustomobject]@{ Name = $name; AudioPath = $audioPath; PreviewPath = $previewPath; LabelId = 0; BgmId = 0; SeId = 0 }
}

function Convert-WallpaperEntry {
    param($Item, [string]$PackageRoot, [string]$TempRoot)
    $name = [string]$Item.Name
    $image = [string]$Item.Image
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($image)) { throw 'Every wallpaper needs Name and Image.' }
    Assert-LabelName $name
    $imagePath = Resolve-PackageFile $PackageRoot $image
    $fit = [string]$Item.Fit
    if ([string]::IsNullOrWhiteSpace($fit)) { $fit = 'Stretch' }
    if ($fit -notin @('Stretch', 'Cover', 'Contain')) { throw "Wallpaper Fit must be Stretch, Cover, or Contain: $fit" }
    $convertedPath = Join-Path $TempRoot ('wallpaper_' + [guid]::NewGuid().ToString('N') + '.png')
    try {
        Convert-WallpaperImage $imagePath $convertedPath $fit
    }
    catch {
        throw "Wallpaper image could not be converted: $image. $($_.Exception.Message)"
    }
    return [pscustomobject]@{ Name = $name; ImagePath = $convertedPath; LabelId = 0; WallpaperId = 0; AssetName = '' }
}

function Convert-WallpaperImage {
    param([string]$SourcePath, [string]$OutputPath, [string]$Fit = 'Stretch')
    Add-Type -AssemblyName System.Drawing
    $source = $null
    $bitmap = $null
    $graphics = $null
    try {
        $source = [Drawing.Image]::FromFile($SourcePath)
        $bitmap = [Drawing.Bitmap]::new($script:WallpaperWidth, $script:WallpaperHeight, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.Clear([Drawing.Color]::Black)
        if ($Fit -eq 'Stretch') {
            $graphics.DrawImage($source, 0, 0, $script:WallpaperWidth, $script:WallpaperHeight)
        }
        else {
            $scale = if ($Fit -eq 'Contain') { [Math]::Min($script:WallpaperWidth / $source.Width, $script:WallpaperHeight / $source.Height) } else { [Math]::Max($script:WallpaperWidth / $source.Width, $script:WallpaperHeight / $source.Height) }
            $width = [single]($source.Width * $scale)
            $height = [single]($source.Height * $scale)
            $x = [single](($script:WallpaperWidth - $width) / 2.0)
            $y = [single](($script:WallpaperHeight - $height) / 2.0)
            $graphics.DrawImage($source, $x, $y, $width, $height)
        }
        $bitmap.Save($OutputPath, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($source) { $source.Dispose() }
    }
}

function Invoke-Texconv {
    param([string]$ToolPath, [string[]]$Arguments)
    & $ToolPath @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "DirectXTex texconv failed with exit code $LASTEXITCODE." }
}

function Assert-DdsTexture {
    param([string]$Path, [int]$Width, [int]$Height)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 128 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'DDS ') { throw "Invalid DDS texture: $Path" }
    if ([BitConverter]::ToUInt32($bytes, 12) -ne $Height -or [BitConverter]::ToUInt32($bytes, 16) -ne $Width) { throw "Unexpected DDS dimensions: $Path" }
    if ([Text.Encoding]::ASCII.GetString($bytes, 84, 4) -ne 'DXT5') { throw "Unexpected DDS format: $Path" }
}

function Build-WallpaperAtlases {
    param([string]$SystemArchive, [array]$Wallpapers, [string]$TexconvPath, [string]$TempRoot)
    Add-Type -AssemblyName System.Drawing
    $sourceDirectory = Join-Path $TempRoot 'wallpaper-atlas-source'
    $decodedDirectory = Join-Path $TempRoot 'wallpaper-atlas-decoded'
    $encodedDirectory = Join-Path $TempRoot 'wallpaper-atlas-encoded'
    New-Item -ItemType Directory -Path $sourceDirectory, $decodedDirectory, $encodedDirectory -Force | Out-Null
    $entries = Read-MpkEntries $SystemArchive
    $wallpaperEntry = $entries | Where-Object { $_.Name -ieq 'PWCG.DDS' } | Select-Object -First 1
    $thumbnailEntry = $entries | Where-Object { $_.Name -ieq 'PWCGTHUM.DDS' } | Select-Object -First 1
    if ($null -eq $wallpaperEntry -or $null -eq $thumbnailEntry) { throw 'The phone wallpaper textures were not found in system.mpk.' }
    $wallpaperDds = Join-Path $sourceDirectory 'PWCG.DDS'
    $thumbnailDds = Join-Path $sourceDirectory 'PWCGTHUM.DDS'
    Export-MpkEntry $SystemArchive $wallpaperEntry $wallpaperDds
    Export-MpkEntry $SystemArchive $thumbnailEntry $thumbnailDds
    Invoke-Texconv -ToolPath $TexconvPath -Arguments @('-nologo', '-y', '-ft', 'png', '-o', $decodedDirectory, $wallpaperDds, $thumbnailDds)
    $wallpaperPng = Join-Path $decodedDirectory 'PWCG.png'
    $thumbnailPng = Join-Path $decodedDirectory 'PWCGTHUM.png'
    if (-not (Test-Path -LiteralPath $wallpaperPng) -or -not (Test-Path -LiteralPath $thumbnailPng)) { throw 'DirectXTex did not decode the phone wallpaper textures.' }
    $patchedWallpaperPng = Join-Path $decodedDirectory 'PWCG-patched.png'
    $patchedThumbnailPng = Join-Path $decodedDirectory 'PWCGTHUM-patched.png'
    $wallpaperAtlas = $null
    $thumbnailAtlas = $null
    $wallpaperGraphics = $null
    $thumbnailGraphics = $null
    try {
        $wallpaperAtlas = [Drawing.Bitmap]::new($wallpaperPng)
        $thumbnailAtlas = [Drawing.Bitmap]::new($thumbnailPng)
        if ($wallpaperAtlas.Width -ne $script:WallpaperAtlasWidth -or $wallpaperAtlas.Height -ne $script:WallpaperAtlasHeight) { throw 'Unexpected PWCG.DDS dimensions.' }
        if ($thumbnailAtlas.Width -ne $script:ThumbnailAtlasWidth -or $thumbnailAtlas.Height -ne $script:ThumbnailAtlasHeight) { throw 'Unexpected PWCGTHUM.DDS dimensions.' }
        $wallpaperGraphics = [Drawing.Graphics]::FromImage($wallpaperAtlas)
        $thumbnailGraphics = [Drawing.Graphics]::FromImage($thumbnailAtlas)
        $wallpaperGraphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
        $thumbnailGraphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
        $thumbnailGraphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        foreach ($wallpaper in $Wallpapers) {
            $tile = [Drawing.Image]::FromFile($wallpaper.ImagePath)
            try {
                $wallpaperX = ($wallpaper.WallpaperId % 9) * $script:WallpaperWidth
                $wallpaperY = [Math]::Floor($wallpaper.WallpaperId / 9) * $script:WallpaperHeight
                $thumbnailX = ($wallpaper.WallpaperId % 12) * $script:ThumbnailWidth
                $thumbnailY = [Math]::Floor($wallpaper.WallpaperId / 12) * $script:ThumbnailHeight
                $wallpaperGraphics.DrawImage($tile, $wallpaperX, $wallpaperY, $script:WallpaperWidth, $script:WallpaperHeight)
                $thumbnailGraphics.DrawImage($tile, $thumbnailX - 3, $thumbnailY, 67, $script:ThumbnailHeight)
            }
            finally {
                $tile.Dispose()
            }
        }
        $wallpaperAtlas.Save($patchedWallpaperPng, [Drawing.Imaging.ImageFormat]::Png)
        $thumbnailAtlas.Save($patchedThumbnailPng, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($wallpaperGraphics) { $wallpaperGraphics.Dispose() }
        if ($thumbnailGraphics) { $thumbnailGraphics.Dispose() }
        if ($wallpaperAtlas) { $wallpaperAtlas.Dispose() }
        if ($thumbnailAtlas) { $thumbnailAtlas.Dispose() }
    }
    Invoke-Texconv -ToolPath $TexconvPath -Arguments @('-nologo', '-y', '-f', 'BC3_UNORM', '-m', '1', '-ft', 'dds', '-o', $encodedDirectory, $patchedWallpaperPng, $patchedThumbnailPng)
    $patchedWallpaperDds = Join-Path $encodedDirectory 'PWCG-patched.DDS'
    $patchedThumbnailDds = Join-Path $encodedDirectory 'PWCGTHUM-patched.DDS'
    Assert-DdsTexture $patchedWallpaperDds 4096 2048
    Assert-DdsTexture $patchedThumbnailDds 768 768
    return @(
        [pscustomobject]@{ FileId = $wallpaperEntry.FileId; Name = $wallpaperEntry.Name; Path = $patchedWallpaperDds },
        [pscustomobject]@{ FileId = $thumbnailEntry.FileId; Name = $thumbnailEntry.Name; Path = $patchedThumbnailDds }
    )
}

function Assert-LabelName {
    param([string]$Name)
    if ($Name.Length -gt 80 -or $Name -match '[\r\n:]') { throw "Phone labels must be 1-80 characters without colons or line breaks: $Name" }
}

function Resolve-PackageFile {
    param([string]$PackageRoot, [string]$Path)
    $candidate = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $PackageRoot $Path }
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Asset not found: $Path" }
    return $full
}

function Add-PhoneLabels {
    param([string]$Path, [array]$Entries)
    $builder = [Text.StringBuilder]::new([IO.File]::ReadAllText($Path))
    foreach ($entry in $Entries) { [void]$builder.AppendLine(('{0}:{1}' -f $entry.LabelId, $entry.Name)) }
    [IO.File]::WriteAllText($Path, $builder.ToString(), [Text.UTF8Encoding]::new($false))
}

function Get-ChunkLines {
    param([string]$Text, [int]$ChunkNumber)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "`r?`n")) { [void]$lines.Add($line) }
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match ('^{0}:$' -f $ChunkNumber)) { $start = $i; break } }
    if ($start -lt 0) { throw "Script chunk $ChunkNumber was not found." }
    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^[0-9]+:$') { $end = $i; break } }
    return [pscustomobject]@{ Lines = $lines; Start = $start; End = $end }
}

function Get-HexBytes {
    param([Collections.Generic.List[string]]$Lines, [int]$Start, [int]$End)
    $bytes = [Collections.Generic.List[byte]]::new()
    for ($i = $Start; $i -lt $End; $i++) {
        if ($Lines[$i] -match '^\s*hex\s+(.+)$') {
            foreach ($token in $Matches[1] -split '\s+') { if ($token) { [void]$bytes.Add([Convert]::ToByte($token, 16)) } }
        }
    }
    if ($bytes.Count -eq 0) { throw 'The target script chunk has no hex data.' }
    return $bytes.ToArray()
}

function Set-HexBytes {
    param([Collections.Generic.List[string]]$Lines, [int]$Start, [int]$End, [byte[]]$Bytes)
    $first = -1
    for ($i = $Start; $i -lt $End; $i++) { if ($Lines[$i] -match '^\s*hex\s+') { $first = $i; break } }
    if ($first -lt 0) { throw 'The target script chunk has no hex line.' }
    for ($i = $End - 1; $i -ge $Start; $i--) { if ($Lines[$i] -match '^\s*hex\s+') { $Lines.RemoveAt($i) } }
    $newLines = [Collections.Generic.List[string]]::new()
    for ($offset = 0; $offset -lt $Bytes.Length; $offset += 16) {
        $count = [Math]::Min(16, $Bytes.Length - $offset)
        $slice = $Bytes[$offset..($offset + $count - 1)]
        [void]$newLines.Add(('    hex  ' + (($slice | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')))
    }
    for ($i = $newLines.Count - 1; $i -ge 0; $i--) { $Lines.Insert($first, $newLines[$i]) }
}

function Update-WallpaperChunk {
    param([string]$Text, [bool]$ForceUnlock, [array]$Wallpapers)
    $chunk = Get-ChunkLines $Text 78
    $bytes = Get-HexBytes $chunk.Lines $chunk.Start $chunk.End
    if ($bytes.Length -lt 10 -or $bytes[0] -ne 0x3C -or $bytes[-2] -ne 0xFF -or $bytes[-1] -ne 0xFF) { throw 'Unexpected wallpaper table format.' }
    $bodyLength = $bytes.Length - 6
    if (($bodyLength % 6) -ne 0) { throw 'Unexpected wallpaper table size.' }
    $records = [Collections.Generic.List[object]]::new()
    for ($offset = 4; $offset -lt ($bytes.Length - 2); $offset += 6) {
        $records.Add([pscustomobject]@{ WallpaperId = [BitConverter]::ToUInt16($bytes, $offset); LabelId = [BitConverter]::ToUInt16($bytes, $offset + 2); Condition = [BitConverter]::ToUInt16($bytes, $offset + 4) })
    }
    $slots = @(17..35)
    if ($Wallpapers.Count -gt $slots.Count) { throw 'The phone supports up to nineteen custom wallpapers.' }
    for ($i = 0; $i -lt $Wallpapers.Count; $i++) {
        $wallpaper = $Wallpapers[$i]
        $wallpaper.WallpaperId = $slots[$i]
        $records.Add([pscustomobject]@{ WallpaperId = $wallpaper.WallpaperId; LabelId = $wallpaper.LabelId; Condition = 0 })
    }
    $output = [Collections.Generic.List[byte]]::new()
    foreach ($value in $bytes[0..3]) { [void]$output.Add($value) }
    foreach ($record in $records) {
        foreach ($value in [BitConverter]::GetBytes([uint16]$record.WallpaperId)) { [void]$output.Add($value) }
        foreach ($value in [BitConverter]::GetBytes([uint16]$record.LabelId)) { [void]$output.Add($value) }
        $condition = if ($ForceUnlock) { 0 } else { $record.Condition }
        foreach ($value in [BitConverter]::GetBytes([uint16]$condition)) { [void]$output.Add($value) }
    }
    [void]$output.Add(0xFF); [void]$output.Add(0xFF)
    Set-HexBytes $chunk.Lines $chunk.Start $chunk.End $output.ToArray()
    return [string]::Join("`n", $chunk.Lines)
}

function Update-RingtoneChunk {
    param([string]$Text, [array]$Ringtones)
    $chunk = Get-ChunkLines $Text 87
    $bytes = Get-HexBytes $chunk.Lines $chunk.Start $chunk.End
    if ($bytes.Length -lt 10 -or $bytes[-2] -ne 0xFF -or $bytes[-1] -ne 0xFF) { throw 'Unexpected ringtone table format.' }
    $bodyLength = $bytes.Length - 2
    if (($bodyLength % 8) -ne 0) { throw 'Unexpected ringtone table size.' }
    $output = [Collections.Generic.List[byte]]::new()
    foreach ($value in $bytes[0..($bytes.Length - 3)]) { [void]$output.Add($value) }
    foreach ($ringtone in $Ringtones) {
        foreach ($value in [BitConverter]::GetBytes([uint16]$ringtone.BgmId)) { [void]$output.Add($value) }
        foreach ($value in [BitConverter]::GetBytes([uint16]$ringtone.SeId)) { [void]$output.Add($value) }
        foreach ($value in [BitConverter]::GetBytes([uint16]$ringtone.LabelId)) { [void]$output.Add($value) }
        foreach ($value in [BitConverter]::GetBytes([uint16]0)) { [void]$output.Add($value) }
    }
    [void]$output.Add(0xFF); [void]$output.Add(0xFF)
    Set-HexBytes $chunk.Lines $chunk.Start $chunk.End $output.ToArray()
    return [string]::Join("`n", $chunk.Lines)
}
