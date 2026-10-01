<#
.SYNOPSIS
    Re-encodes a FLAC library with the newest FLAC encoder, then builds matching
    Opus files.
.DESCRIPTION
    For every *.flac under -Path (recursively):
    1) Lossless FLAC -> FLAC re-encode at maximum preset (-8) with --verify.
       flac writes a temp file, verifies it, and only then replaces the
       original. Tags, embedded art and cue sheets carry over automatically.
       Files already encoded by your installed flac version are skipped (needs
       metaflac.exe).
    2) Cover art: if a folder contains a recognized folder image
       (cover/folder/front/album + .jpg/.jpeg/.png), it is resized to
       -CoverMaxDim px and saved as a JPEG at -CoverJpegQuality. The embedded
       picture is then REMOVED from the FLAC files (the folder image stays as
       the lossless master), and the resized JPEG is embedded into the .opus
       files instead. Folders without a recognized image keep their embedded
       art, which is resized the same way into the .opus files.
    3) FLAC -> Opus at -OpusBitrate kbit/s VBR. A fixed allowlist of Vorbis
       comments is kept (see $KeepTags below); common synonyms are remapped to
       the canonical name when the latter is absent, and all other tags are
       dropped.
    An art-strip during the current run forces that file's opus to rebuild.
    Existing .opus files newer than both their .flac and the folder image,
    when present, are skipped unless -Force.
.PARAMETER Path
    Folder that contains the FLAC library; scanned recursively.
.PARAMETER OpusBitrate
    Opus VBR target in kbit/s (24-512). The default 128 is transparent for
    stereo music.
.PARAMETER CoverMaxDim
    Maximum width and height in pixels (64-4000) of the cover art embedded in
    the .opus files; images are never upscaled.
.PARAMETER CoverJpegQuality
    JPEG quality (50-100) for the embedded cover art.
.PARAMETER FlacExe
    Full path to flac.exe when it is not on PATH.
.PARAMETER OpusencExe
    Full path to opusenc.exe when it is not on PATH.
.PARAMETER OpusRoot
    Mirror .opus files into this tree instead of writing them next to the FLAC
    files.
.PARAMETER NoReencode
    Skip the FLAC -> FLAC re-encode and only build or refresh .opus files.
.PARAMETER NoOpus
    Skip Opus creation and perform FLAC maintenance only.
.PARAMETER Force
    Redo everything, even if already up to date.
.NOTES
    Assumes one album per folder: a single folder image is applied to all FLACs
    in it.
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

# fail fast on an invalid -Path instead of dying later with a confusing error
if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "-Path must be an existing folder, got: '$Path'"
}

# tags kept in the .opus files (all others are stripped). Add/remove to taste.
$KeepTags    = @(
    'TITLE', 'ALBUM', 'ARTIST', 'ALBUMARTIST', 'GENRE', 'DATE',
    'TRACKNUMBER', 'DISCNUMBER', 'COPYRIGHT', 'ISRC', 'LABEL',
    'TOTALDISCS', 'TOTALTRACKS', 'UPC'
)
$TagSynonyms = @{
    DATE         = 'YEAR'
    TRACKNUMBER  = 'TRACK'
    DISCNUMBER   = 'DISC'
    ALBUMARTIST  = 'ALBUM ARTIST', 'ALBUM_ARTIST'
    TOTALDISCS   = 'TOTALDISC', 'TOTAL_DISCS', 'DISCTOTAL'
    TOTALTRACKS  = 'TOTALTRACK', 'TOTAL_TRACKS', 'TRACKTOTAL'
    UPC          = 'BARCODE', 'EAN'
    LABEL        = 'ORGANIZATION'
}

# folder image file names recognized in each folder, in priority order
$CoverNames = @('cover.jpg', 'cover.jpeg', 'folder.jpg', 'folder.jpeg',
    'front.jpg', 'front.jpeg', 'album.jpg', 'album.jpeg',
    'cover.png', 'folder.png', 'front.png', 'album.png')

function Resolve-Tool([string]$Name, [string]$ExplicitPath) {
    if ($ExplicitPath) {
        if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) { throw "$Name not found at '$ExplicitPath'." }
        return (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $paramName = '-' + $Name.Substring(0, 1).ToUpperInvariant() + $Name.Substring(1) + 'Exe'
    throw "$Name not found on PATH. Install it, or pass $paramName with the full path."
}

function Invoke-Checked([string]$ExePath, [string[]]$Arguments) {
    # run an external tool and throw on failure, so callers can catch and report
    & $ExePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("{0} exited with code {1}" -f (Split-Path -Leaf $ExePath), $LASTEXITCODE)
    }
}

$flac    = Resolve-Tool 'flac'    $FlacExe
$opusenc = Resolve-Tool 'opusenc' $OpusencExe

# metaflac.exe ships with flac.exe; needed for picture removal and tag
# filtering. Without it the script degrades gracefully: no art stripping, all
# tags copied.
$metaflac = $null
$mfCmd    = Get-Command 'metaflac' -ErrorAction SilentlyContinue
if ($mfCmd) { $metaflac = $mfCmd.Source }
else {
    $mfSibling = Join-Path (Split-Path -Parent $flac) 'metaflac.exe'
    if (Test-Path -LiteralPath $mfSibling -PathType Leaf) { $metaflac = $mfSibling }
}
$tagFilter = [bool]$metaflac  # true = opus files carry only the allowed tags
if (-not $metaflac) {
    Write-Warning "metaflac.exe not found: embedded art will NOT be removed from FLACs, and Opus tag filtering will be skipped."
}

$drawingOk = $true
try { Add-Type -AssemblyName System.Drawing } catch {
    $drawingOk = $false
    Write-Warning "Could not load System.Drawing (cover resizing unavailable): $($_.Exception.Message)"
}

$folderCoverCache = @{}  # folder -> temp .jpg path (or $null)
$folderCoverMtime = @{}  # folder -> cover source LastWriteTimeUtc (or $null)
$tempCovers       = New-Object System.Collections.Generic.List[string]

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
                # transparent PNGs would otherwise turn black in the JPEG
                $g.Clear([System.Drawing.Color]::White)
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

function Get-FolderCover([string]$Dir, [switch]$NoOpus, [int]$CoverMaxDim, [int]$CoverJpegQuality) {
    # returns the path of a resized cover JPEG for this folder (cached), or
    # $null. Under -NoOpus the resized JPEG would never be embedded, so only the
    # source path is returned, after confirming the image loads; callers use it
    # solely to decide whether the embedded art may be stripped.
    if ($folderCoverCache.ContainsKey($Dir)) { return $folderCoverCache[$Dir] }
    $jpg = $null
    if ($drawingOk) {
        $src = $null
        foreach ($n in $CoverNames) {
            $p = Join-Path $Dir $n
            if (Test-Path -LiteralPath $p -PathType Leaf) { $src = $p; break }
        }
        $folderCoverMtime[$Dir] = $null
        if ($src) {
            $folderCoverMtime[$Dir] = (Get-Item -LiteralPath $src).LastWriteTimeUtc
            if ($NoOpus) {
                try {
                    $probe = [System.Drawing.Image]::FromFile($src)
                    $probe.Dispose()
                    $jpg = $src
                }
                catch {
                    Write-Warning "Cover '$src' could not be loaded ($($_.Exception.Message)) - keeping embedded art for: $Dir"
                }
            }
            else {
                try {
                    $jpg = Join-Path ([System.IO.Path]::GetTempPath()) ("opuscover-" + [guid]::NewGuid().ToString('N') + ".jpg")
                    Convert-CoverArt -Source $src -Destination $jpg -MaxDim $CoverMaxDim -JpegQuality $CoverJpegQuality
                    [void]$tempCovers.Add($jpg)
                }
                catch {
                    Write-Warning "Cover '$src' could not be processed ($($_.Exception.Message)) - keeping embedded art for: $Dir"
                    if ($jpg -and (Test-Path -LiteralPath $jpg)) { Remove-Item -LiteralPath $jpg -Force -ErrorAction SilentlyContinue }
                    $jpg = $null
                }
            }
        }
    }
    $folderCoverCache[$Dir] = $jpg
    return $jpg
}

function New-OpusTagArgs([string]$FlacPath) {
    # emits '--comment','TAG=value' argument pairs for the allowed tags. The
    # output may legitimately be empty; the caller wraps it with @(). Caveat:
    # values containing newlines would be split by this line-based parser;
    # irrelevant for the short single-line tags kept here.
    if (-not $metaflac) { return }
    # --no-utf8-convert: metaflac must hand us the stored bytes, not a
    # local-charset conversion of them (the script decodes output as UTF-8).
    $lines = (& $metaflac --no-utf8-convert --export-tags-to=- $FlacPath) |
        Where-Object { $_ -and $_.IndexOf('=') -gt 0 }
    # fail loudly instead of silently building a tagless .opus
    if ($LASTEXITCODE -ne 0) { throw "metaflac tag export failed (exit code $LASTEXITCODE)" }
    $vals = @{}
    foreach ($l in $lines) {
        $i = $l.IndexOf('='); $n = $l.Substring(0, $i).Trim().ToUpperInvariant()
        if (-not $vals.ContainsKey($n)) { $vals[$n] = New-Object System.Collections.Generic.List[string] }
        $vals[$n].Add($l.Substring($i + 1))
    }
    foreach ($t in $KeepTags) {
        $src = $t
        if (-not $vals.ContainsKey($t)) {
            # synonyms may list several alternatives (e.g. TOTALDISCS ->
            # TOTALDISC / TOTAL_DISCS); the first one present wins
            $src = $null
            foreach ($syn in @($TagSynonyms[$t])) {
                if ($syn -and $vals.ContainsKey($syn)) { $src = $syn; break }
            }
            if (-not $src) { continue }
        }
        foreach ($v in $vals[$src]) { '--comment', "$t=$v" }
    }
}

function Format-Bytes([long]$Bytes) {
    if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    else { '{0:N0} KB' -f ($Bytes / 1KB) }
}

# installed flac version, e.g. "1.5.0"
$flacVersion = ''
$verLine     = (& $flac --version) | Select-Object -First 1
if ("$verLine" -match 'flac\s+([\d.]+)') { $flacVersion = $Matches[1].Trim('.') }
$threadArgs = @()
try { if ([version]$flacVersion -ge [version]'1.5.0') { $threadArgs = @("--threads=$([Environment]::ProcessorCount)") } } catch { }

# opusenc version, e.g. "0.2-52-g5f894e9" (opus-tools); informational only
$opusencVersion = ''
$ovLine         = (& $opusenc --version) | Select-Object -First 1
if ("$ovLine" -match 'opus-tools\s+(\S+)') { $opusencVersion = $Matches[1] }
elseif ("$ovLine" -match '([\d.]+)') { $opusencVersion = $Matches[1] }
if (-not $opusencVersion) { $opusencVersion = '(unknown)' }

$root  = (Resolve-Path -LiteralPath $Path).Path
# keep a drive root as 'C:\': trimming it to 'C:' would make Get-ChildItem
# follow the session's per-drive current directory instead of the root
if ($root.Length -gt 3) { $root = $root.TrimEnd('\') }
# -ErrorAction SilentlyContinue: an unreadable subfolder is skipped, not fatal
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.flac -Force -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) { Write-Host "No FLAC files found under '$root'."; return }

$folderCount = @($files | Group-Object DirectoryName).Count
$metaInfo    = if ($metaflac) { 'yes' } else { 'NOT FOUND (tag filtering and art stripping disabled)' }
$mode        = @(
    if ($NoReencode) { 're-encode off' } else { 're-encode on' }
    if ($NoOpus) { 'opus off' } else { "opus on (${OpusBitrate}k VBR)" }
    "covers ${CoverMaxDim}px/q$CoverJpegQuality"
    if ($Force) { 'force rebuilds' }
    if ($OpusRoot) { "opus root: $OpusRoot" }
) -join '; '
Write-Host "Catalog : $root -- $($files.Count) FLAC file(s) in $folderCount folder(s)"
Write-Host "Tools   : flac $flacVersion, metaflac $metaInfo, opusenc $opusencVersion"
Write-Host "Mode    : $mode"

$reencoded    = 0; $flacSkipped = 0; $opusMade = 0; $opusSkipped = 0; $failed = 0
$picsStripped = 0
$bytesSaved   = [long]0
# files with an Opus after this run (made or up to date)
$flacBytesTotal = [long]0
$opusBytesTotal = [long]0
# path + failing phase, for the summary
$failedFiles = New-Object System.Collections.Generic.List[string]

# metaflac writes tag output as UTF-8, but PS 5.1 decodes native command output
# using the console code page (OEM by default), which mangles non-ASCII tags on
# their way into the .opus comments. Decode as UTF-8 for this run instead;
# restored in the finally block below.
$origOutputEncoding = $null
try {
    if ([Console]::OutputEncoding.CodePage -ne [System.Text.Encoding]::UTF8.CodePage) {
        $origOutputEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
} catch {
    Write-Warning "Could not switch the console to UTF-8 (non-ASCII tags may be mangled): $($_.Exception.Message)"
}

try {
    # Write-Progress is throttled to 1% increments (slow on large libraries)
    $lastPct = -1
    for ($i = 0; $i -lt $files.Count; $i++) {
        $f   = $files[$i]
        $pct = [int](100 * $i / $files.Count)
        if ($pct -ne $lastPct) {
            $lastPct = $pct
            # empty for files directly in the root
            $relDir = $f.DirectoryName.Substring($root.Length).TrimStart('\')
            Write-Progress -Activity 'Converting music library' -Status ("{0}/{1}  {2}" -f ($i + 1), $files.Count, $relDir) `
                -CurrentOperation $f.Name -PercentComplete $pct
        }

        $cover = Get-FolderCover -Dir $f.DirectoryName -NoOpus:$NoOpus -CoverMaxDim $CoverMaxDim -CoverJpegQuality $CoverJpegQuality

        # ---------- 1) per-file metadata probe (vendor, picture) ----------
        $vendor     = ''; $hasPic = $false
        $needVendor = $metaflac -and $flacVersion -and (-not $NoReencode) -and (-not $Force)
        # strip or re-embed decision needs it
        $needPic    = $metaflac -and ($cover -or -not $NoOpus)
        if ($needVendor -or $needPic) {
            # one --list serves both the vendor-skip check and the picture
            # checks
            $probe = & $metaflac --list --block-type=VORBIS_COMMENT,PICTURE $f.FullName
            foreach ($ln in $probe) {
                if ($ln -match 'vendor string:') { $vendor = $ln }
                elseif ($ln -match 'type: 6 \(PICTURE\)') { $hasPic = $true }
            }
        }

        # ---------- 2) lossless FLAC -> FLAC re-encode ----------
        $needReencode = -not $NoReencode
        if ($needReencode -and -not $Force -and $vendor -match ("libFLAC " + [regex]::Escape($flacVersion) + "(\s|$)")) {
            $needReencode = $false  # already encoded by this exact flac version
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
                Invoke-Checked $flac (@('-8', '--verify', '-s', '-f') + $threadArgs + @('--', $f.FullName))
                $flacNew = Get-Item -LiteralPath $f.FullName
                $flacNew.LastWriteTimeUtc = $mtime  # keep original timestamps
                $reencoded++
                $bytesSaved += $sizeBefore - $flacNew.Length
            }
            catch {
                $failed++
                [void]$failedFiles.Add("$($f.FullName) [re-encode]")
                Write-Warning "FLAC re-encode FAILED (original left untouched): $($f.FullName) -- $($_.Exception.Message)"
                continue
            }
        }

        # ---------- 3) strip embedded art from the FLAC ----------
        $strippedNow = $false
        if ($cover -and $metaflac -and $hasPic) {
            try {
                # metaflac's --preserve-modtime only keeps whole seconds;
                # capture and restore the exact timestamp ourselves
                $flacObj = Get-Item -LiteralPath $f.FullName
                $mtime   = $flacObj.LastWriteTimeUtc
                Invoke-Checked $metaflac @('--dont-use-padding', '--preserve-modtime',
                    '--remove', '--block-type=PICTURE', $f.FullName)
                $flacObj.LastWriteTimeUtc = $mtime
                $strippedNow = $true; $picsStripped++
            }
            catch {
                Write-Warning "Could not remove embedded art from: $($f.FullName) -- $($_.Exception.Message)"
            }
        }

        # ---------- 4) FLAC -> Opus (allowed tags only, new cover) ----------
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

            $flacNow    = Get-Item -LiteralPath $f.FullName
            $coverMtime = $folderCoverMtime[$f.DirectoryName]
            $opusNow    = if (Test-Path -LiteralPath $opus) { Get-Item -LiteralPath $opus }
            # up to date only when newer than both the FLAC and, when present,
            # the folder image
            $upToDate = -not $Force -and -not $strippedNow -and $opusNow -and
                ($opusNow.LastWriteTimeUtc -gt $flacNow.LastWriteTimeUtc) -and
                ((-not $coverMtime) -or ($opusNow.LastWriteTimeUtc -gt $coverMtime))
            if ($upToDate) {
                $opusSkipped++
                $flacBytesTotal += $flacNow.Length
                $opusBytesTotal += (Get-Item -LiteralPath $opus).Length
            }
            else {
                # encode via a sibling temp file: an interrupted or failed build
                # must never leave a partial .opus behind (its fresh mtime would
                # make the up-to-date check accept it), and must not destroy the
                # previous one
                $opusTmp = "$opus.tmp"
                try {
                    $encArgs     = @('--quiet', "--bitrate=$OpusBitrate")
                    $embeddedPic = $null
                    if ($tagFilter) {
                        # don't copy the FLAC's tags wholesale; re-add only the
                        # allowed ones
                        $encArgs += '--discard-comments'
                        $encArgs += @(New-OpusTagArgs $f.FullName)
                        if (-not $cover) {
                            # --discard-comments also drops the FLAC's embedded
                            # picture (opus stores it as a comment); re-embed it
                            # explicitly so folders without a folder image keep
                            # their art
                            if ($hasPic) {
                                $embeddedPic = Join-Path ([System.IO.Path]::GetTempPath()) ("opusart-" + [guid]::NewGuid().ToString('N'))
                                Invoke-Checked $metaflac @("--export-picture-to=$embeddedPic", $f.FullName)
                                # normalize like a folder image (max dimension,
                                # JPEG quality); if the image cannot be
                                # processed, embed the original bytes
                                $resized = Join-Path ([System.IO.Path]::GetTempPath()) ("opusart-" + [guid]::NewGuid().ToString('N') + ".jpg")
                                try {
                                    Convert-CoverArt -Source $embeddedPic -Destination $resized -MaxDim $CoverMaxDim -JpegQuality $CoverJpegQuality
                                    Remove-Item -LiteralPath $embeddedPic -Force -ErrorAction SilentlyContinue
                                    $embeddedPic = $resized
                                }
                                catch {
                                    Write-Warning "Embedded art of $($f.FullName) could not be resized ($($_.Exception.Message)) - embedding the original"
                                    Remove-Item -LiteralPath $resized -Force -ErrorAction SilentlyContinue
                                }
                                $encArgs += @('--discard-pictures', '--picture', $embeddedPic)
                            }
                        }
                    }
                    if ($cover) {
                        $encArgs += @('--discard-pictures', '--picture', $cover)
                    }
                    Invoke-Checked $opusenc ($encArgs + @($f.FullName, $opusTmp))
                    Move-Item -LiteralPath $opusTmp -Destination $opus -Force
                    $opusMade++
                    $flacBytesTotal += $flacNow.Length
                    $opusBytesTotal += (Get-Item -LiteralPath $opus).Length
                }
                catch {
                    $failed++
                    [void]$failedFiles.Add("$($f.FullName) [opus]")
                    Write-Warning "Opus encode FAILED (previous .opus left in place): $($f.FullName) -- $($_.Exception.Message)"
                }
                finally {
                    if (Test-Path -LiteralPath $opusTmp) { Remove-Item -LiteralPath $opusTmp -Force -ErrorAction SilentlyContinue }
                    if ($embeddedPic) { Remove-Item -LiteralPath $embeddedPic -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }
}
finally {
    foreach ($t in $tempCovers) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    if ($origOutputEncoding) {
        try { [Console]::OutputEncoding = $origOutputEncoding } catch { }
    }
    Write-Progress -Activity 'Converting music library' -Completed
}

$mb            = [math]::Round($bytesSaved / 1MB, 1)
$headlineColor = if ($failed -gt 0) { 'Red' } else { 'Green' }
# cache has one entry per FLAC folder
$folderCovers = @($folderCoverCache.Values | Where-Object { $_ }).Count
Write-Host ""
Write-Host ("Done. {0} FLAC file(s) in {1} folder(s) processed." -f $files.Count, $folderCount) -ForegroundColor $headlineColor
if ($NoReencode) {
    Write-Host '  Re-encode : (disabled)'
} else {
    Write-Host ("  Re-encode : {0} re-encoded (net {1} MB), {2} already current" -f $reencoded, $mb, $flacSkipped)
}
Write-Host ("  Cover art : {0} of {1} folder(s) had an image; embedded art removed from {2} files" -f $folderCovers, $folderCount, $picsStripped)
if ($NoOpus) {
    Write-Host '  Opus      : (disabled)'
} else {
    Write-Host ("  Opus      : {0} created, {1} up to date" -f $opusMade, $opusSkipped)
    if ($opusBytesTotal -gt 0) {
        $pctSmaller = [int][math]::Round(100 * (1.0 - $opusBytesTotal / [double]$flacBytesTotal))
        Write-Host ("  Size      : {0} FLAC -> {1} Opus ({2}% smaller)" -f `
            (Format-Bytes $flacBytesTotal), (Format-Bytes $opusBytesTotal), $pctSmaller)
    }
}
Write-Host ("  Failures  : {0}" -f $failed) -ForegroundColor $headlineColor
if ($failedFiles.Count -gt 0) {
    foreach ($ff in $failedFiles) { Write-Host "    $ff" -ForegroundColor Red }
}

# non-zero exit code so failures surface to callers and scheduled tasks
if ($failed -gt 0) { exit 1 }
