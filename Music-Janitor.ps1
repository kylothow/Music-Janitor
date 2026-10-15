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
       art, which is resized the same way into the .opus files. JPEG art that
       fits the size target, needs no rotation and would not shrink from
       recompression is passed through unchanged.
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
.PARAMETER FlacThreads
    --threads value for the FLAC re-encode, 0-64 (flac 1.5.0 or newer). The
    default 0 is automatic: the number of logical processors, capped at 6.
    flac 1.5.0's threaded encoder runs its --verify decoder on a single
    thread, so worker threads beyond that cap stop helping and can slow
    the re-encode down.
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
    .\Music-Janitor.ps1 -Path "D:\Music"
    .\Music-Janitor.ps1 -Path "D:\Music" -NoReencode -Force
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

    [ValidateRange(0, 64)]
    [int]$FlacThreads = 0,  # --threads for the re-encode; 0 = automatic

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
    'TOTALDISCS', 'TOTALTRACKS', 'UPC',
    'REPLAYGAIN_TRACK_GAIN', 'REPLAYGAIN_TRACK_PEAK',
    'REPLAYGAIN_ALBUM_GAIN', 'REPLAYGAIN_ALBUM_PEAK'
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

function Invoke-MetaflacBatch([string[]]$Operation, [string[]]$FilePaths, [scriptblock]$ParseLine) {
    # metaflac accepts many files per call; chunked to stay under the ~32 KB
    # Windows command-line limit. Output is streamed line by line into
    # $ParseLine instead of being collected, so a chunk with large embedded art
    # does not end up held in memory twice. Per-file errors print on the console
    # and the failing files produce no output; callers treat missing output as
    # unknown and fail safe.
    $i = 0
    while ($i -lt $FilePaths.Count) {
        $chunk = New-Object System.Collections.Generic.List[string]
        $len   = 0
        while ($i -lt $FilePaths.Count -and ($chunk.Count -eq 0 -or ($len + $FilePaths[$i].Length + 1) -lt 28000)) {
            $len += $FilePaths[$i].Length + 1
            [void]$chunk.Add($FilePaths[$i])
            $i++
        }
        & $metaflac @Operation @chunk | ForEach-Object { & $ParseLine $_ }
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

# System.Drawing is loaded lazily on first image use (Test-DrawingLoaded):
# libraries without covers never pay for loading it, and a load failure is only
# reported when image processing is attempted
$drawingOk    = $true
$drawingTried = $false

$folderCoverCache = @{}  # folder -> temp .jpg path (or $null)
$folderCoverMtime = @{}  # folder -> cover source LastWriteTimeUtc (or $null)
$tempCovers       = New-Object System.Collections.Generic.List[string]

function Test-DrawingLoaded {
    # load System.Drawing on first use and cache the outcome; the writes need
    # the explicit scope qualifier because a plain assignment inside a function
    # would create a function-local variable
    if (-not $drawingTried) {
        $script:drawingTried = $true
        try { Add-Type -AssemblyName System.Drawing } catch {
            $script:drawingOk = $false
            Write-Warning "Could not load System.Drawing (cover resizing unavailable): $($_.Exception.Message)"
        }
    }
    return $drawingOk
}

function Convert-CoverArt([string]$Source, [string]$Destination, [int]$MaxDim, [int]$JpegQuality) {
    # a JPEG stores no quality header; "already optimal" in practice means that
    # re-encoding it would not make it any smaller
    $isJpeg = $false
    $fs     = [System.IO.File]::OpenRead($Source)
    try {
        $magic  = New-Object byte[] 3
        $isJpeg = ($fs.Read($magic, 0, 3) -eq 3) -and $magic[0] -eq 0xFF -and $magic[1] -eq 0xD8 -and $magic[2] -eq 0xFF
    } finally { $fs.Close() }
    $img = [System.Drawing.Image]::FromFile($Source)
    try {
        $rotated = $false
        # honor EXIF orientation (3 = 180, 6 = 90 CW, 8 = 270 CW; rare variants
        # ignored)
        try {
            switch ($img.GetPropertyItem(274).Value[0]) {
                3 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone); $rotated = $true }
                6 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone);  $rotated = $true }
                8 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone); $rotated = $true }
            }
        } catch { }  # EXIF orientation absent: no rotation
        # never upscale
        $scale      = [Math]::Min(1.0, $MaxDim / [Math]::Max($img.Width, $img.Height))
        $tw         = [Math]::Max(1, [int][Math]::Round($img.Width  * $scale))
        $th         = [Math]::Max(1, [int][Math]::Round($img.Height * $scale))
        $downscaled = ($tw -lt $img.Width -or $th -lt $img.Height)
        $bmp        = New-Object System.Drawing.Bitmap($tw, $th)
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
            # pass the source through untouched when it is a JPEG that needed
            # neither rotation nor downscaling, and re-encoding would not shrink
            # it
            if ($isJpeg -and -not $rotated -and -not $downscaled -and
                (Get-Item -LiteralPath $Source).Length -le (Get-Item -LiteralPath $Destination).Length) {
                Copy-Item -LiteralPath $Source -Destination $Destination -Force
            }
        } finally { $bmp.Dispose() }
    } finally { $img.Dispose() }
}

function Find-CoverSource([string]$Dir) {
    # first recognized folder image in the folder, priority order, or $null
    foreach ($n in $CoverNames) {
        $p = Join-Path $Dir $n
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Get-FolderCover([string]$Dir, [switch]$NoOpus, [int]$CoverMaxDim, [int]$CoverJpegQuality) {
    # returns the path of a resized cover JPEG for this folder (cached), or
    # $null. Under -NoOpus the resized JPEG would never be embedded, so only the
    # source path is returned, after confirming the image loads; callers use it
    # solely to decide whether the embedded art may be stripped. Called lazily
    # (only when an action, strip or opus build, needs the cover) so idle runs
    # never pay for image processing.
    if ($folderCoverCache.ContainsKey($Dir)) { return $folderCoverCache[$Dir] }
    $jpg = $null
    $src = $folderCoverSrc[$Dir]  # resolved once before the loop
    if ($src -and (Test-DrawingLoaded)) {
        if ($NoOpus) {
            try {
                $probeLine = [System.Drawing.Image]::FromFile($src)
                $probeLine.Dispose()
                $jpg = $src
            }
            catch {
                Write-Warning "Cover '$src' could not be loaded ($($_.Exception.Message)) -- keeping embedded art for: $Dir"
            }
        }
        else {
            try {
                $jpg = Join-Path ([System.IO.Path]::GetTempPath()) ("musicjanitor-cover-" + [guid]::NewGuid().ToString('N') + ".jpg")
                Convert-CoverArt -Source $src -Destination $jpg -MaxDim $CoverMaxDim -JpegQuality $CoverJpegQuality
                [void]$tempCovers.Add($jpg)
            }
            catch {
                Write-Warning "Cover '$src' could not be processed ($($_.Exception.Message)) -- keeping embedded art for: $Dir"
                if ($jpg -and (Test-Path -LiteralPath $jpg)) { Remove-Item -LiteralPath $jpg -Force -ErrorAction SilentlyContinue }
                $jpg = $null
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
        # the canonical tag plus its synonyms in order; the first one present
        # wins, and missing tags are skipped
        $src = @($t) + @($TagSynonyms[$t]) | Where-Object { $_ -and $vals.ContainsKey($_) } | Select-Object -First 1
        if (-not $src) { continue }
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
$flacVerLine = (& $flac --version) | Select-Object -First 1
if ("$flacVerLine" -match 'flac\s+([\d.]+)') { $flacVersion = $Matches[1].Trim('.') }
# flac 1.5.0's threaded encoder still runs the --verify decoder, the in-order
# frame writes and the input reading on a single (main) thread, so throughput is
# expected to saturate at about five worker threads; extra workers only contend
# with that serial stage. Measured on a hybrid 6P+4E laptop, a 34.8 min album
# takes 2.25 s at 4-6 threads and 3.20 s at 16. The automatic value is therefore
# capped; -FlacThreads overrides it when needed.
$encodeThreads = [Math]::Min([Environment]::ProcessorCount, 6)
if ($FlacThreads -gt 0) { $encodeThreads = $FlacThreads }
$threadArgs = @()
# unparseable version stays single-threaded
try { if ([version]$flacVersion -ge [version]'1.5.0') { $threadArgs = @("--threads=$encodeThreads") } } catch { }
if ($FlacThreads -gt 0 -and -not $threadArgs) {
    $verNote = if ($flacVersion) { "flac $flacVersion" } else { 'the installed flac (version unknown)' }
    Write-Warning "-FlacThreads ignored: $verNote does not support --threads (needs 1.5.0 or newer)."
}

# opusenc version, e.g. "0.2-52-g5f894e9" (opus-tools); informational only
$opusencVersion = ''
$opusVerLine    = (& $opusenc --version) | Select-Object -First 1
if ("$opusVerLine" -match 'opus-tools\s+(\S+)') { $opusencVersion = $Matches[1] }
elseif ("$opusVerLine" -match '([\d.]+)') { $opusencVersion = $Matches[1] }
if (-not $opusencVersion) { $opusencVersion = '(unknown)' }
$flacLabel = if ($flacVersion) { "flac $flacVersion" } else { 'flac (unknown)' }

$root  = (Resolve-Path -LiteralPath $Path).Path
# keep a drive root as 'C:\': trimming it to 'C:' would make Get-ChildItem
# follow the session's per-drive current directory instead of the root
if ($root.Length -gt 3) { $root = $root.TrimEnd('\') }
# -ErrorAction SilentlyContinue: an unreadable subfolder is skipped, not fatal
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.flac -Force -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) { Write-Host "No FLAC files found under '$root'."; return }

$folderGroups = @($files | Group-Object DirectoryName)
$folderCount  = $folderGroups.Count
$metaInfo     = if ($metaflac) { 'yes' } else { 'NOT FOUND (tag filtering and art stripping disabled)' }
$threadsLabel = "$encodeThreads threads"
if ($encodeThreads -eq 1) { $threadsLabel = '1 thread' }
if (-not $threadArgs -and $flacVersion) { $threadsLabel = 'single-threaded (pre-1.5.0)' }
if (-not $threadArgs -and -not $flacVersion) { $threadsLabel = 'single-threaded (unknown)' }
$mode         = @(
    if ($NoReencode) { 're-encode off' } else { "re-encode on ($threadsLabel)" }
    if ($NoOpus) { 'opus off' } else { "opus on (${OpusBitrate}k VBR)" }
    "covers ${CoverMaxDim}px/q$CoverJpegQuality"
    if ($Force) { 'force rebuilds' }
    if ($OpusRoot) { "opus root: $OpusRoot" }
) -join '; '
Write-Host "Catalog : $root -- $($files.Count) FLAC file(s) in $folderCount folder(s)"
Write-Host "Tools   : $flacLabel, metaflac $metaInfo, opusenc $opusencVersion"
Write-Host "Mode    : $mode"

$reencoded    = 0; $flacSkipped = 0; $opusMade = 0; $opusSkipped = 0; $failed = 0
$picsStripped = 0
$bytesSaved   = [long]0
# size totals for files with an Opus after this run (made or up to date)
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
    # resolve every folder's cover source and mtime up front (cheap filesystem
    # probes); the resized JPEG itself is built lazily by Get-FolderCover, only
    # when an action needs it, so idle runs do no image processing at all
    $folderCoverSrc = @{}
    foreach ($g in $folderGroups) {
        $src = Find-CoverSource $g.Name
        $folderCoverSrc[$g.Name] = $src
        $folderCoverMtime[$g.Name] = $null
        if ($src) {
            # a cover vanishing mid-run (or a flaky share) must not abort the
            # batch
            try { $folderCoverMtime[$g.Name] = (Get-Item -LiteralPath $src).LastWriteTimeUtc } catch { }
        }
    }
    # batch-scan the encoder vendor strings before the loop: one
    # --show-vendor-tag per chunk of files replaces a metaflac process per file
    # (about 25x fewer spawns). A file that produces no line (unreadable, or a
    # batch interrupted by a bad file) is absent from the map and falls back to
    # the re-encode path, where failures surface loudly. Skipped when
    # re-encoding is off/forced.
    $vendorMap = @{}
    if ($metaflac -and $flacVersion -and (-not $NoReencode) -and (-not $Force)) {
        Write-Progress -Activity 'Converting music library' -Status 'Scanning encoder vendor strings...'
        $allPaths = @($files.FullName)
        # --with-filename: metaflac prefixes output lines with the file path
        # only when more than one file is passed; a single-file chunk (small
        # library, last chunk) must produce the same parseable format
        Invoke-MetaflacBatch -Operation @('--with-filename', '--show-vendor-tag') -FilePaths $allPaths -ParseLine {
            param($ln)
            if ($ln -match '^(.*\.flac):(.*)$') { $vendorMap[$Matches[1]] = $Matches[2] }
        }
    }
    # batch-scan the covered-folder files for embedded art: --list
    # --block-type=PICTURE prints one prefixed METADATA block line per file that
    # still carries art and nothing for clean files, so this costs one spawn per
    # chunk instead of one per file. Cover-less folders are never part of the
    # scan; their art is detected at build time, otherwise their kept-forever
    # art would be hex-dumped on every run.
    $picSet = $null
    if ($metaflac) {
        $coverPaths = New-Object System.Collections.Generic.List[string]
        foreach ($g in $folderGroups) {
            if ($folderCoverSrc[$g.Name]) {
                foreach ($m in $g.Group) { [void]$coverPaths.Add($m.FullName) }
            }
        }
        if ($coverPaths.Count -gt 0) {
            Write-Progress -Activity 'Converting music library' -Status 'Scanning embedded art...'
            $picSet = New-Object 'System.Collections.Generic.HashSet[string]'
            Invoke-MetaflacBatch -Operation @('--with-filename', '--list', '--block-type=PICTURE') -FilePaths $coverPaths -ParseLine {
                param($ln)
                if ($ln -match '^(.*\.flac):METADATA block') { [void]$picSet.Add($Matches[1]) }
            }
        }
    }
    # Write-Progress is throttled to 1% increments (slow on large libraries)
    $lastPct = -1
    for ($i = 0; $i -lt $files.Count; $i++) {
        $f   = $files[$i]
        $pct = [int](100 * ($i + 1) / $files.Count)
        if ($pct -ne $lastPct) {
            $lastPct = $pct
            # empty for files directly in the root
            $relDir = $f.DirectoryName.Substring($root.Length).TrimStart('\')
            Write-Progress -Activity 'Converting music library' -Status ("{0}/{1}  {2}" -f ($i + 1), $files.Count, $relDir) `
                -CurrentOperation $f.Name -PercentComplete $pct
        }

        $coverSrc = $folderCoverSrc[$f.DirectoryName]

        # ---------- 1) per-file metadata (batch-scanned) ----------
        $vendor = ''
        if ($vendorMap.ContainsKey($f.FullName)) { $vendor = $vendorMap[$f.FullName] }
        # files missing from the pic set (or the scan) keep their embedded art
        $hasPic = ($null -ne $picSet -and $picSet.Contains($f.FullName))

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
                $flacNow = Get-Item -LiteralPath $f.FullName
                $flacNow.LastWriteTimeUtc = $mtime  # keep original timestamps
                $reencoded++
                $bytesSaved += $sizeBefore - $flacNow.Length
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
        if ($coverSrc -and $metaflac -and $hasPic) {
            # build (or reuse) the resized folder image; the strip stays gated
            # on the cover being usable, exactly as before
            $cover = Get-FolderCover -Dir $f.DirectoryName -NoOpus:$NoOpus -CoverMaxDim $CoverMaxDim -CoverJpegQuality $CoverJpegQuality
            if ($cover) {
                try {
                    # metaflac's --preserve-modtime only keeps whole seconds;
                    # capture and restore the exact timestamp ourselves
                    $flacNow = Get-Item -LiteralPath $f.FullName
                    $mtime   = $flacNow.LastWriteTimeUtc
                    Invoke-Checked $metaflac @('--dont-use-padding', '--preserve-modtime',
                        '--remove', '--block-type=PICTURE', $f.FullName)
                    $flacNow.LastWriteTimeUtc = $mtime
                    $strippedNow = $true; $picsStripped++
                }
                catch {
                    Write-Warning "Could not remove embedded art from: $($f.FullName) -- $($_.Exception.Message)"
                }
            }
        }

        # ---------- 4) FLAC -> Opus (allowed tags only, new cover) ----------
        if (-not $NoOpus) {
            if ($OpusRoot) {
                $rel  = $f.FullName.Substring($root.Length).TrimStart('\')
                $opus = Join-Path $OpusRoot ($rel -replace '\.flac$', '.opus')
                $dir  = Split-Path -Parent $opus
                [void](New-Item -ItemType Directory -Path $dir -Force)
            }
            else {
                $opus = [System.IO.Path]::ChangeExtension($f.FullName, '.opus')
            }

            # a FLAC vanishing or becoming unreadable after its re-encode (or a
            # flaky share) must not abort the batch; report it as an opus
            # failure and move on
            $flacNow    = $null
            try { $flacNow = Get-Item -LiteralPath $f.FullName }
            catch {
                $failed++
                [void]$failedFiles.Add("$($f.FullName) [opus]")
                Write-Warning "Opus build FAILED (FLAC unreadable mid-run): $($f.FullName) -- $($_.Exception.Message)"
                continue
            }
            $coverMtime = $folderCoverMtime[$f.DirectoryName]
            # treat a vanished opus (or flaky share) as not up to date rather
            # than aborting
            $opusNow    = $null
            try { $opusNow = Get-Item -LiteralPath $opus } catch { }
            # up to date only when newer than both the FLAC and, when present,
            # the folder image
            $upToDate = -not $Force -and -not $strippedNow -and $opusNow -and
                ($opusNow.LastWriteTimeUtc -gt $flacNow.LastWriteTimeUtc) -and
                ((-not $coverMtime) -or ($opusNow.LastWriteTimeUtc -gt $coverMtime))
            if ($upToDate) {
                $opusSkipped++
                $flacBytesTotal += $flacNow.Length
                $opusBytesTotal += $opusNow.Length
            }
            else {
                # encode via a sibling temp file: an interrupted or failed build
                # must never leave a partial .opus behind (its fresh mtime would
                # make the up-to-date check accept it), and must not destroy the
                # previous one
                $opusTmp = "$opus.tmp"
                try {
                    # reset first, so the finally can never see the previous
                    # file's temp path
                    $embeddedPic = $null
                    # build (or reuse) the resized folder image now that the
                    # file is being rebuilt
                    $cover = $null
                    if ($coverSrc) {
                        $cover = Get-FolderCover -Dir $f.DirectoryName -NoOpus:$NoOpus -CoverMaxDim $CoverMaxDim -CoverJpegQuality $CoverJpegQuality
                    }
                    $encArgs = @('--quiet', "--bitrate=$OpusBitrate")
                    if ($tagFilter) {
                        # don't copy the FLAC's tags wholesale; re-add only the
                        # allowed ones
                        $encArgs += '--discard-comments'
                        $encArgs += @(New-OpusTagArgs $f.FullName)
                        if (-not $cover) {
                            # --discard-comments also drops the FLAC's embedded
                            # picture (opus stores it as a comment); re-embed it
                            # explicitly so folders without a folder image keep
                            # their art. Detected here so the cost only occurs
                            # when an opus is rebuilt; one output line decides
                            # the answer, so stop reading before the whole
                            # picture is hex-dumped through the pipeline. An
                            # empty result with a non-zero exit is a probe
                            # failure, not a clean "no art"
                            $probeLine = & $metaflac --list --block-type=PICTURE $f.FullName | Select-Object -First 1
                            if (-not $probeLine -and $LASTEXITCODE -ne 0) {
                                throw "metaflac picture probe failed (exit code $LASTEXITCODE)"
                            }
                            $hasEmbedded = [bool]$probeLine
                            if ($hasEmbedded) {
                                $embeddedPic = Join-Path ([System.IO.Path]::GetTempPath()) ("musicjanitor-art-" + [guid]::NewGuid().ToString('N'))
                                Invoke-Checked $metaflac @("--export-picture-to=$embeddedPic", $f.FullName)
                                if ((Get-Item -LiteralPath $embeddedPic).Length -eq 0) {
                                    # placeholder PICTURE block with no image
                                    # bytes; neither GDI+ nor opusenc accepts
                                    # empty input, so build a tag-only opus
                                    Remove-Item -LiteralPath $embeddedPic -Force -ErrorAction SilentlyContinue
                                    $embeddedPic = $null
                                    Write-Warning "Empty embedded art skipped for: $($f.FullName)"
                                }
                                if ($embeddedPic) {
                                    # normalize like a folder image (max
                                    # dimension, JPEG quality); if the image
                                    # cannot be processed, embed the original
                                    # bytes
                                    $resized = Join-Path ([System.IO.Path]::GetTempPath()) ("musicjanitor-art-" + [guid]::NewGuid().ToString('N') + ".jpg")
                                    try {
                                        if (Test-DrawingLoaded) {
                                            Convert-CoverArt -Source $embeddedPic -Destination $resized -MaxDim $CoverMaxDim -JpegQuality $CoverJpegQuality
                                            Remove-Item -LiteralPath $embeddedPic -Force -ErrorAction SilentlyContinue
                                            $embeddedPic = $resized
                                        }
                                        # without System.Drawing the original
                                        # bytes are embedded as-is
                                    }
                                    catch {
                                        Write-Warning "Embedded art of $($f.FullName) could not be resized ($($_.Exception.Message)) -- embedding the original"
                                        Remove-Item -LiteralPath $resized -Force -ErrorAction SilentlyContinue
                                    }
                                    $encArgs += @('--discard-pictures', '--picture', $embeddedPic)
                                }
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
                    Remove-Item -LiteralPath $opusTmp -Force -ErrorAction SilentlyContinue
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

$mb            = [Math]::Round($bytesSaved / 1MB, 1)
$headlineColor = if ($failed -gt 0) { 'Red' } else { 'Green' }
$folderCovers  = @($folderCoverSrc.Values | Where-Object { $_ }).Count
Write-Host ''
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
        $pctSmaller = [int][Math]::Round(100 * (1.0 - $opusBytesTotal / [double]$flacBytesTotal))
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
