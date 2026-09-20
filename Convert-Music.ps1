<#
.SYNOPSIS
    Re-encodes a FLAC library with the newest FLAC encoder, then builds matching
    Opus files.
.DESCRIPTION
    For every *.flac under -Path (recursively):
    1) Lossless FLAC -> FLAC re-encode at maximum preset (-8) with --verify.
       flac writes a temp file, verifies it, and only then replaces the
       original. Tags, embedded art and cue sheets carry over automatically.
       Files already encoded by your installed flac version are skipped
       (vendor-string check).
    2) Cover art: if a folder contains a recognized folder image
       (cover/folder/front/album + .jpg/.jpeg/.png), it is resized to
       -CoverMaxDim px and saved as a JPEG at -CoverJpegQuality. The embedded
       picture is then REMOVED from the FLAC files (the folder image stays as
       the lossless master), and the resized JPEG is embedded into the .opus
       files instead.
    3) FLAC -> Opus at -OpusBitrate kbit/s VBR. Only the tags your player
       supports are carried over: TITLE, ALBUM, ARTIST, GENRE, DATE,
       TRACKNUMBER, DISCNUMBER (YEAR/TRACK/DISC are remapped to
       DATE/TRACKNUMBER/DISCNUMBER).
    Existing .opus files newer than their .flac are skipped unless -Force.
.EXAMPLE
    .\Convert-Music.ps1 -Path "D:\Music"
    .\Convert-Music.ps1 -Path "D:\Music" -NoReencode -Force
    # rebuild all .opus with the new rules
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,  # folder that contains your FLAC files

    [ValidateRange(24, 512)]
    [int]$OpusBitrate = 128,  # kbit/s; 128 is 'transparent' for stereo music

    [ValidateRange(64, 4000)]
    [int]$CoverMaxDim = 1200,  # max width/height (px) of the embedded JPEG

    [ValidateRange(50, 100)]
    [int]$CoverJpegQuality = 86,  # JPEG quality for the embedded cover

    [string]$FlacExe,  # optional: full path to flac.exe
    [string]$OpusencExe,  # optional: full path to opusenc.exe

    [string]$OpusRoot,  # optional: mirror .opus files into this tree
    [switch]$NoReencode,  # skip the FLAC -> FLAC re-encode
    [switch]$NoOpus,  # skip the FLAC -> Opus encode
    [switch]$Force  # redo everything, even if already up to date
)

$ErrorActionPreference = 'Stop'

# tags kept in the .opus files (all others are stripped). Add/remove to taste.
$script:KeepTags     = @('TITLE', 'ALBUM', 'ARTIST', 'GENRE', 'DATE', 'TRACKNUMBER', 'DISCNUMBER')
# used only if the canonical tag is absent
$script:TagSynonyms  = @{ DATE = 'YEAR'; TRACKNUMBER = 'TRACK'; DISCNUMBER = 'DISC' }

# folder image file names recognized in each folder, in priority order
$script:CoverNames = @('cover.jpg', 'cover.jpeg', 'folder.jpg', 'folder.jpeg',
    'front.jpg', 'front.jpeg', 'album.jpg', 'album.jpeg',
    'cover.png', 'folder.png', 'front.png', 'album.png')

function Resolve-Tool([string]$Name, [string]$ExplicitPath) {
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) { throw "$Name not found at '$ExplicitPath'." }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "$Name not found on PATH. Install it, or pass -$($Name)Exe with the full path."
}

$flac    = Resolve-Tool 'flac'    $FlacExe
$opusenc = Resolve-Tool 'opusenc' $OpusencExe

# metaflac.exe ships with flac.exe; needed for picture removal and tag filtering
$metaflacPath = Get-Command 'metaflac' -ErrorAction SilentlyContinue
if ($metaflacPath) { $script:metaflac = $metaflacPath.Source }
else {
    $sibling = Join-Path (Split-Path -Parent $flac) 'metaflac.exe'
    if (Test-Path -LiteralPath $sibling) { $script:metaflac = $sibling } else { $script:metaflac = $null }
}
if (-not $script:metaflac) {
    Write-Warning "metaflac.exe not found: embedded art will NOT be removed from FLACs, and Opus tag filtering will fall back to copying all tags."
}

$script:drawingOk = $true
try { Add-Type -AssemblyName System.Drawing } catch {
    $script:drawingOk = $false
    Write-Warning "Could not load System.Drawing (cover resizing unavailable): $($_.Exception.Message)"
}

$script:folderCoverCache = @{}  # folder -> temp .jpg path (or $null)
$script:tempCovers       = New-Object System.Collections.Generic.List[string]

function Convert-CoverArt([string]$Source, [string]$Destination, [int]$MaxDim, [int]$JpegQuality) {
    $img = [System.Drawing.Image]::FromFile($Source)
    try {
        # honor EXIF orientation (3 = 180, 6 = 90 CW, 8 = 270 CW; rare variants
        # ignored)
        try {
            switch ($img.GetPropertyItem(274).Value[0]) {
                3 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
                6 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
                8 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
            }
        } catch { }  # EXIF orientation absent: no rotation
        # never upscale
        $scale = [Math]::Min(1.0, $MaxDim / [Math]::Max($img.Width, $img.Height))
        $tw    = [Math]::Max(1, [int][Math]::Round($img.Width  * $scale))
        $th    = [Math]::Max(1, [int][Math]::Round($img.Height * $scale))
        $bmp   = New-Object System.Drawing.Bitmap($tw, $th)
        try {
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $g.DrawImage($img, 0, 0, $tw, $th)
            } finally { $g.Dispose() }
            $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
            $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
            try {
                $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)
                if ($codec) { $bmp.Save($Destination, $codec, $ep) }
                else { $bmp.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Jpeg) }
            } finally { $ep.Dispose() }
        } finally { $bmp.Dispose() }
    } finally { $img.Dispose() }
}

function Get-FolderCover([string]$Dir) {
    # returns the path of a resized cover JPEG for this folder (cached), or
    # $null
    if ($script:folderCoverCache.ContainsKey($Dir)) { return $script:folderCoverCache[$Dir] }
    $jpg = $null
    if ($script:drawingOk) {
        $src = $null
        foreach ($n in $script:CoverNames) {
            $p = Join-Path $Dir $n
            if (Test-Path -LiteralPath $p -PathType Leaf) { $src = $p; break }
        }
        if ($src) {
            try {
                $jpg = Join-Path ([System.IO.Path]::GetTempPath()) ("opuscover-" + [guid]::NewGuid().ToString('N') + ".jpg")
                Convert-CoverArt -Source $src -Destination $jpg -MaxDim $CoverMaxDim -JpegQuality $CoverJpegQuality
                [void]$script:tempCovers.Add($jpg)
            } catch {
                Write-Warning "Cover '$src' could not be processed ($($_.Exception.Message)) - keeping embedded art for: $Dir"
                if ($jpg -and (Test-Path -LiteralPath $jpg)) { Remove-Item -LiteralPath $jpg -Force -ErrorAction SilentlyContinue }
                $jpg = $null
            }
        }
    }
    $script:folderCoverCache[$Dir] = $jpg
    return $jpg
}

function Get-OpusCommentArgs([string]$FlacPath) {
    # returns [array of '--comment','TAG=value',...] for the allowed tags, or
    # $null if unavailable
    if (-not $script:metaflac) { return $null }
    $lines = (& $script:metaflac --export-tags-to=- "$FlacPath") | Where-Object { $_ -and $_.IndexOf('=') -gt 0 }
    $vals  = @{}
    foreach ($l in $lines) {
        $i = $l.IndexOf('='); $n = $l.Substring(0, $i).Trim().ToUpperInvariant()
        if (-not $vals.ContainsKey($n)) { $vals[$n] = New-Object System.Collections.Generic.List[string] }
        $vals[$n].Add($l.Substring($i + 1))
    }
    $out = @()
    foreach ($t in $script:KeepTags) {
        $src = $t
        if (-not $vals.ContainsKey($t)) {
            $syn = $script:TagSynonyms[$t]
            if ($syn -and $vals.ContainsKey($syn)) { $src = $syn } else { continue }
        }
        foreach ($v in $vals[$src]) { $out += @('--comment', "$t=$v") }
    }
    return ,$out
}

# installed flac version, e.g. "1.5.0"
$flacVersion = ''
$verLine     = (& $flac --version) | Select-Object -First 1
if ("$verLine" -match 'flac\s+([\d.]+)') { $flacVersion = $Matches[1].Trim('.') }
$threadArgs = @()
try { if ([version]$flacVersion -ge [version]'1.5.0') { $threadArgs = @("--threads=$([Environment]::ProcessorCount)") } } catch { }

$root  = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.flac -Force)
if ($files.Count -eq 0) { Write-Host "No FLAC files found under '$root'."; return }
Write-Host "Found $($files.Count) FLAC file(s). flac v$flacVersion, Opus target ${OpusBitrate}k, cover ${CoverMaxDim}px/q$CoverJpegQuality."

$reencoded    = 0; $flacSkipped = 0; $opusMade = 0; $opusSkipped = 0; $failed = 0
$picsStripped = 0; $coversUsed = 0
$bytesSaved   = [long]0

try {
    for ($i = 0; $i -lt $files.Count; $i++) {
        $f = $files[$i]
        Write-Progress -Activity 'Converting music library' -Status $f.FullName `
            -PercentComplete ([int](100 * ($i + 1) / $files.Count))

        # ---------- 1) lossless FLAC -> FLAC re-encode ----------
        $needReencode = -not $NoReencode
        if ($needReencode -and -not $Force -and $script:metaflac) {
            $vendor = (& $script:metaflac --list --block-type=VORBIS_COMMENT "$($f.FullName)") |
                Where-Object { $_ -match 'vendor string:' } | Select-Object -First 1
            if ("$vendor" -match ("libFLAC " + [regex]::Escape($flacVersion) + "(\s|$)")) {
                # already encoded by this exact flac version
                $needReencode = $false
            }
        }
        if (-not $needReencode) {
            $flacSkipped++
        }
        else {
            $sizeBefore = $f.Length
            $mtime      = $f.LastWriteTimeUtc
            try {
                # -8 = max preset; --verify = decode & compare while encoding;
                # -f  = in-place replace via temp file, only on success
                & $flac -8 --verify -s -f @threadArgs -- "$($f.FullName)"
                if ($LASTEXITCODE -ne 0) { throw "flac.exe exited with code $LASTEXITCODE" }
                # keep original timestamps
                (Get-Item -LiteralPath $f.FullName).LastWriteTimeUtc = $mtime
                $reencoded++
                $bytesSaved += $sizeBefore - (Get-Item -LiteralPath $f.FullName).Length
            }
            catch {
                $failed++
                Write-Warning "FLAC re-encode FAILED (original left untouched): $($f.FullName) -- $($_.Exception.Message)"
                continue
            }
        }

        # ---------- 2) strip embedded art from the FLAC ----------
        $cover       = Get-FolderCover $f.DirectoryName
        $strippedNow = $false
        if ($cover) {
            if (-not $script:metaflac) {
                # no metaflac -> can't strip; opus still gets the new cover (see
                # below)
            }
            elseif ([bool](& $script:metaflac --list --block-type=PICTURE "$($f.FullName)" |
                Where-Object { $_ -match 'METADATA block' })) {
                & $script:metaflac --dont-use-padding --preserve-modtime --remove --block-type=PICTURE "$($f.FullName)"
                if ($LASTEXITCODE -eq 0) { $strippedNow = $true; $picsStripped++ }
                else { Write-Warning "Could not remove embedded art from: $($f.FullName)" }
            }
        }

        # ---------- 3) FLAC -> Opus (allowed tags only, new cover) ----------
        if (-not $NoOpus) {
            if ($OpusRoot) {
                $rel  = $f.FullName.Substring($root.Length).TrimStart('\')
                $opus = Join-Path $OpusRoot ($rel -replace '\.flac$', '.opus')
                $dir  = Split-Path -Parent $opus
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            }
            else {
                $opus = [System.IO.Path]::ChangeExtension($f.FullName, '.opus')
            }

            $flacNow  = Get-Item -LiteralPath $f.FullName
            $upToDate = -not $Force -and -not $strippedNow -and (Test-Path -LiteralPath $opus) -and
                ((Get-Item -LiteralPath $opus).LastWriteTimeUtc -gt $flacNow.LastWriteTimeUtc)
            if ($upToDate) {
                $opusSkipped++
            }
            else {
                try {
                    $commentArgs = @(Get-OpusCommentArgs "$($f.FullName)")
                    $encArgs     = @('--quiet', "--bitrate=$OpusBitrate")
                    if ($script:metaflac) {
                        # don't copy the FLAC's tags wholesale...
                        $encArgs += '--discard-comments'
                        # ...only the allowed ones, re-added explicitly
                        $encArgs += $commentArgs
                    }
                    if ($cover) {
                        $encArgs += @('--discard-pictures', '--picture', "$cover")
                        $coversUsed++
                    }
                    & $opusenc @encArgs "$($f.FullName)" "$opus"
                    if ($LASTEXITCODE -ne 0) { throw "opusenc.exe exited with code $LASTEXITCODE" }
                    $opusMade++
                }
                catch {
                    $failed++
                    Remove-Item -LiteralPath $opus -Force -ErrorAction SilentlyContinue
                    Write-Warning "Opus encode FAILED: $($f.FullName) -- $($_.Exception.Message)"
                }
            }
        }
    }
}
finally {
    foreach ($t in $script:tempCovers) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    Write-Progress -Activity 'Converting music library' -Completed
}

$mb = [math]::Round($bytesSaved / 1MB, 1)
Write-Host ""
Write-Host ("Done. FLAC re-encoded: {0} ({1} MB saved), already current: {2} | embedded art removed from {3} files, {4} covers used | Opus created: {5}, up to date: {6} | failures: {7}" -f `
    $reencoded, $mb, $flacSkipped, $picsStripped, $coversUsed, $opusMade, $opusSkipped, $failed)
