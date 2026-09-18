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
    2) Encodes an .opus twin at -OpusBitrate (default 128 kbit/s VBR), carrying
       over only the tags the player supports (TITLE, ALBUM, ARTIST, GENRE,
       DATE, TRACKNUMBER, DISCNUMBER).
    Existing .opus files newer than their .flac are skipped unless -Force.
.EXAMPLE
    .\Convert-Music.ps1 -Path "D:\Music"
    .\Convert-Music.ps1 -Path "D:\Music" -OpusBitrate 96 -OpusRoot "D:\Music-Opus"
    .\Convert-Music.ps1 -Path "D:\Music" -NoReencode
    # only (re)build Opus files
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,  # folder that contains your FLAC files

    [ValidateRange(24, 512)]
    [int]$OpusBitrate = 128,  # kbit/s; 128 is 'transparent' for stereo music

    [string]$FlacExe,  # optional: full path to flac.exe
    [string]$OpusencExe,  # optional: full path to opusenc.exe

    [string]$OpusRoot,  # optional: mirror .opus files into this tree
# (default: next to each .flac)
    [switch]$NoReencode,  # skip the FLAC -> FLAC re-encode
    [switch]$NoOpus,  # skip the FLAC -> Opus encode
    [switch]$Force  # redo everything, even if already up to date
)

$ErrorActionPreference = 'Stop'

# tags kept in the .opus files (all others are stripped). Add/remove to taste.
$script:KeepTags    = @('TITLE', 'ALBUM', 'ARTIST', 'GENRE', 'DATE', 'TRACKNUMBER', 'DISCNUMBER')
# used only if the canonical tag is absent
$script:TagSynonyms = @{ DATE = 'YEAR'; TRACKNUMBER = 'TRACK'; DISCNUMBER = 'DISC' }

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

# metaflac.exe ships with flac.exe; used for vendor-string skipping and tag
# filtering.
$metaflacPath = Get-Command 'metaflac' -ErrorAction SilentlyContinue
if ($metaflacPath) { $script:metaflac = $metaflacPath.Source }
else {
    $sibling = Join-Path (Split-Path -Parent $flac) 'metaflac.exe'
    if (Test-Path -LiteralPath $sibling) { $script:metaflac = $sibling } else { $script:metaflac = $null }
}
if (-not $script:metaflac) {
    Write-Warning "metaflac.exe not found: Opus tag filtering will be skipped."
}

function Get-OpusCommentArgs([string]$FlacPath) {
    # returns an array of '--comment','TAG=value' argument pairs for the allowed
    # tags
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

# flac >= 1.5.0 can use several CPU cores per file
$threadArgs = @()
try { if ([version]$flacVersion -ge [version]'1.5.0') { $threadArgs = @("--threads=$([Environment]::ProcessorCount)") } } catch { }

$root  = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.flac -Force)
if ($files.Count -eq 0) { Write-Host "No FLAC files found under '$root'."; return }
Write-Host "Found $($files.Count) FLAC file(s). flac v$flacVersion, Opus target ${OpusBitrate}k."

$reencoded  = 0; $flacSkipped = 0; $opusMade = 0; $opusSkipped = 0; $failed = 0
$bytesSaved = [long]0

for ($i = 0; $i -lt $files.Count; $i++) {
    $f = $files[$i]
    Write-Progress -Activity 'Converting music library' -Status $f.FullName `
        -PercentComplete ([int](100 * ($i + 1) / $files.Count))

    # ---------- 1) lossless FLAC -> FLAC re-encode ----------
    $needReencode = -not $NoReencode
    if ($needReencode -and -not $Force -and $metaflac) {
        $vendor = (& $metaflac --list --block-type=VORBIS_COMMENT "$($f.FullName)") |
            Where-Object { $_ -match 'vendor string:' } | Select-Object -First 1
        if ("$vendor" -match ("libFLAC " + [regex]::Escape($flacVersion) + "(\s|$)")) {
            $needReencode = $false  # already encoded by this exact flac version
        }
    }

    if (-not $needReencode) {
        $flacSkipped++
    }
    else {
        $sizeBefore = $f.Length
        $mtime      = $f.LastWriteTimeUtc
        try {
            # -8 maximum compression preset --verify decode the result while
            # encoding and compare with the input -f allow in-place replacement
            # (flac writes a temp file and only replaces the original after
            # success) -s no progress spam; errors still show
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
            continue  # don't build an Opus from a file that just failed
        }
    }

    # ---------- 2) FLAC -> Opus twin ----------
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

        $flacNow = Get-Item -LiteralPath $f.FullName
        if (-not $Force -and (Test-Path -LiteralPath $opus) -and
            ((Get-Item -LiteralPath $opus).LastWriteTimeUtc -gt $flacNow.LastWriteTimeUtc)) {
            # .opus exists and is newer than its (unchanged) source
            $opusSkipped++
        }
        else {
            try {
                $commentArgs = Get-OpusCommentArgs "$($f.FullName)"
                $encArgs     = @('--quiet', "--bitrate=$OpusBitrate")
                if ($commentArgs -is [array]) {
                    $encArgs += '--discard-comments'
                    $encArgs += $commentArgs
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

Write-Progress -Activity 'Converting music library' -Completed
$mb = [math]::Round($bytesSaved / 1MB, 1)
Write-Host ""
Write-Host ("Done. FLAC re-encoded: {0} ({1} MB saved), already current: {2} | Opus created: {3}, up to date: {4} | failures: {5}" -f `
    $reencoded, $mb, $flacSkipped, $opusMade, $opusSkipped, $failed)
