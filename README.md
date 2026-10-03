# Music Janitor

[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

Windows PowerShell 5.1 script that maintains a FLAC music library and builds a matching Opus mirror. The FLAC files remain the lossless masters: the script re-encodes them with the newest installed FLAC encoder, standardizes cover art, reduces metadata to a fixed tag set, and mirrors the collection into compact Opus files. An original is never modified except through flac's own verify-then-replace path.

## Contents

- [What it does](#what-it-does)
- [Key features](#key-features)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Common scenarios](#common-scenarios)
- [Parameter reference](#parameter-reference)
- [Metadata and cover specifications](#metadata-and-cover-specifications)
- [Safety and performance](#safety-and-performance)
- [License](#license)

## What it does

For every `*.flac` under `-Path` (recursively):

1. **Lossless FLAC -> FLAC re-encode** with the newest installed flac.exe: `flac -8 --verify -s -f` (multithreaded when flac >= 1.5.0). flac replaces the file in-place via its own temp file, only after the decode-and-compare check passes. Files already encoded by the installed flac version are skipped (vendor-string check via metaflac), so re-running after a flac upgrade only touches old files. Original modification times are preserved exactly.
2. **Cover art management** (assumes one album per folder): if a folder contains a recognized folder image, it is resized once per folder and the embedded PICTURE blocks are removed from that folder's FLACs (the folder image remains the lossless master) while the resized JPEG is embedded into the `.opus` files instead. Folders without a recognized image keep their embedded art, which is normalized the same way and carried over into the `.opus` files. Details in [Metadata and cover specifications](#metadata-and-cover-specifications).
3. **FLAC -> Opus** at VBR (default 128 kbit/s). Only the tags in the [allowlist](#tag-allowlist-and-synonym-remapping) are carried over, with common synonyms remapped to the canonical names; all other tags are intentionally dropped.

Existing `.opus` files newer than both their `.flac` and the folder image, when present (modification-time check), are skipped; an art-strip performed during the current run forces that file's opus to be rebuilt; `-Force` redoes everything. After changing any encoding rule, a one-time `-NoReencode -Force` pass re-syncs the existing opus files.

Failures are never fatal to the library: a file that fails leaves the original untouched, is reported as a warning, and is listed in the run summary with a non-zero exit code.

## Key features

| Feature | Details |
|---------|---------|
| Lossless archive integrity | Re-encodes with `flac -8 --verify -s -f` (multithreaded on FLAC 1.5.0+); the encoder decodes and compares before the atomic replacement, and exact modification timestamps are restored afterwards. |
| Cover art management | Treats the folder image as the authoritative cover, strips the duplicate embedded copies from the FLACs, and embeds a resized, normalized JPEG into each `.opus` file (see the cover specification below). |
| Tag sanitization | Only allowlisted tags and ReplayGain loudness metadata reach the Opus files, with common synonym spellings remapped automatically. |
| Batch metadata scanning | Vendor strings and embedded-art presence are collected in chunked `metaflac` calls instead of one process per file (roughly 25x fewer process spawns). |
| Incremental synchronization | Opus freshness is checked against both the source FLAC and the folder image; up-to-date files are skipped instantly. |
| Flexible mirroring | Opus files are written next to the FLACs or mirrored into a separate tree (`-OpusRoot`), such as a folder synced to a portable player. |
| Fault tolerance | Encoding failures leave existing files untouched, are reported per file, and produce a non-zero exit code. |

## Requirements

| Component | Notes |
|-----------|-------|
| OS | Windows with PowerShell 5.1 |
| FLAC | `flac.exe` + `metaflac.exe` (1.5.0+ recommended) |
| Opus | `opusenc.exe` (from opus-tools) |

Install FLAC via winget:

```powershell
winget install Xiph.FLAC
```

Or download the official binaries from [FLAC downloads page](https://xiph.org/flac/download.html). Obtain `opusenc.exe` from the [RareWares opus-tools builds](https://www.rarewares.org/opus.php) (recommended) or the [Opus downloads page](https://opus-codec.org/downloads/).

> [!NOTE]
> `flac.exe`, `metaflac.exe` and `opusenc.exe` must be on `PATH`, or their locations passed via `-FlacExe` and `-OpusencExe`.

> [!NOTE]
> **Graceful degradation:** without `metaflac.exe`, art stripping and tag filtering are skipped with a warning. Without `System.Drawing`, embedded art is kept as-is.

## Quick start

```powershell
powershell -ExecutionPolicy Bypass -File .\Music-Janitor.ps1 -Path "D:\Music"
```

On the first run this will:

1. Scan all folders under `D:\Music`
2. Re-encode the FLACs with max compression and verify them in place
3. Normalize cover art and remove the duplicate copies embedded in the FLACs
4. Transcode matching `.opus` files (128 kbit/s VBR) next to each `.flac`

## Common scenarios

### 1. Mirror to a dedicated Opus tree

Build the Opus collection on another drive while leaving the FLAC files untouched (for example, a folder that syncs to a portable player):

```powershell
.\Music-Janitor.ps1 -Path "D:\LosslessArchive" -OpusRoot "E:\OpusMirror"
```

### 2. Change tagging or bitrate rules without touching the FLACs

After tweaking the tag allowlist, cover dimensions, or the target bitrate, re-sync all Opus files without a FLAC re-encode:

```powershell
.\Music-Janitor.ps1 -Path "D:\Music" -NoReencode -Force -OpusBitrate 160
```

### 3. Archive maintenance only (no Opus)

Re-encode the FLACs to the latest encoder and strip embedded art without generating Opus files:

```powershell
.\Music-Janitor.ps1 -Path "D:\Music" -NoOpus
```

### 4. Custom bitrate and cover profile

Higher bitrate with more compact covers:

```powershell
.\Music-Janitor.ps1 -Path "D:\Music" -OpusBitrate 160 -CoverMaxDim 800 -CoverJpegQuality 90
```

## Parameter reference

| Parameter | Type | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| `-Path` | `String` | *(required)* | existing folder | Root of the FLAC library (scanned recursively). |
| `-OpusBitrate` | `Int32` | `128` | `24-512` | Opus VBR target in kbit/s; 128 is transparent for stereo music. |
| `-CoverMaxDim` | `Int32` | `1200` | `64-4000` | Max width/height (px) of the JPEG embedded in `.opus`. |
| `-CoverJpegQuality` | `Int32` | `86` | `50-100` | JPEG quality for the embedded cover. |
| `-OpusRoot` | `String` | *(none)* | directory path | Mirror `.opus` files into this tree instead of next to the FLACs. |
| `-NoReencode` | `Switch` | off | | Skip the FLAC -> FLAC re-encode. |
| `-NoOpus` | `Switch` | off | | Skip Opus creation (FLAC maintenance only). |
| `-Force` | `Switch` | off | | Redo everything, even if already up to date. |
| `-FlacExe` | `String` | auto | file path | Full path to `flac.exe` when not on `PATH`. |
| `-OpusencExe` | `String` | auto | file path | Full path to `opusenc.exe` when not on `PATH`. |

## Metadata and cover specifications

### Tag allowlist and synonym remapping

Only the following Vorbis comments reach the `.opus` files; common synonym spellings are remapped to the canonical name when the canonical tag is absent (multiple values per tag are preserved):

| Canonical tag | Remapped synonyms |
|---------------|-------------------|
| `TITLE` | -- |
| `ALBUM` | -- |
| `ARTIST` | -- |
| `ALBUMARTIST` | `ALBUM ARTIST`, `ALBUM_ARTIST` |
| `GENRE` | -- |
| `DATE` | `YEAR` |
| `TRACKNUMBER` | `TRACK` |
| `TOTALTRACKS` | `TOTALTRACK`, `TOTAL_TRACKS`, `TRACKTOTAL` |
| `DISCNUMBER` | `DISC` |
| `TOTALDISCS` | `TOTALDISC`, `TOTAL_DISCS`, `DISCTOTAL` |
| `UPC` | `BARCODE`, `EAN` |
| `LABEL` | `ORGANIZATION` |
| `COPYRIGHT` | -- |
| `ISRC` | -- |
| `REPLAYGAIN_TRACK_GAIN` | -- |
| `REPLAYGAIN_TRACK_PEAK` | -- |
| `REPLAYGAIN_ALBUM_GAIN` | -- |
| `REPLAYGAIN_ALBUM_PEAK` | -- |

The ReplayGain fields are loudness-normalization metadata; they are carried over verbatim when present. All non-allowlisted tags (personal comments, encoder fingerprints, store markers, etc.) are dropped from the Opus output.

### Cover art search and optimization

Folder images are recognized in each folder in this priority order:

```
cover.jpg -> cover.jpeg -> folder.jpg -> folder.jpeg -> front.jpg -> front.jpeg
  -> album.jpg -> album.jpeg -> cover.png -> folder.png -> front.png -> album.png
```

Processing rules:

- **Resizing**: high-quality bicubic interpolation up to `-CoverMaxDim`; images are never upscaled.
- **Format normalization**: saved as JPEG at `-CoverJpegQuality`.
- **Transparency**: transparent PNG backgrounds are rendered white to avoid black artifacts in the embedded JPEG.
- **EXIF rotation**: standard orientation tags (180, 90 CW, 270 CW) are honored.
- **Pass-through**: a JPEG that already fits the size target, needs no rotation, and would not shrink from recompression is embedded unchanged.
- **Folders without a folder image**: embedded FLAC art is extracted, normalized the same way, and carried over into the Opus file.

## Safety and performance

- **Non-destructive re-encoding**: flac writes a temporary file and performs a decode-and-verify pass; only on success does it atomically replace the original.
- **Atomic Opus generation**: Opus files are encoded to `<name>.opus.tmp` and renamed into place, so an interrupted or failed run never leaves a partial file (and never destroys the previous good one).
- **Timestamp accuracy**: exact modification timestamps (`LastWriteTimeUtc`) are preserved on FLAC files through re-encoding and art stripping.
- **UTF-8 console handling**: the console output encoding is switched to UTF-8 for the run (and restored afterwards) so non-ASCII tag values survive into the `.opus` files on any console.
- **Automation-ready**: exit code 0 on a clean run, 1 when any file failed; failures are listed in the end-of-run summary.

> [!WARNING]
> - When running Music Janitor on a library for the first time, test it on a small subfolder (or a copied subset) first.
> - Do not run two instances against the same library at the same time; the outcome is undefined.
> - Windows paths longer than 260 characters are not supported.

## License

This project is licensed under the [MIT License](LICENSE).
