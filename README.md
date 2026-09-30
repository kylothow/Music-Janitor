# Convert-Music.ps1

Windows PowerShell 5.1 script that maintains a FLAC music library and builds a matching Opus mirror. The FLAC files remain the lossless masters; the script never modifies an original except through flac's own verify-then-replace path.

## What it does

For every `*.flac` under `-Path` (recursively):

1. **Lossless FLAC -> FLAC re-encode** with the newest installed flac.exe: `flac -8 --verify -s -f` (multithreaded when flac >= 1.5.0). flac replaces the file in-place via its own temp file, only after the decode-and-compare check passes. Files already encoded by the installed flac version are skipped (vendor-string check via metaflac), so re-running after a flac upgrade only touches old files. Original modification times are preserved exactly.
2. **Cover art management** (assumes one album per folder): if a folder contains a recognized folder image (`cover/folder/front/album` + `.jpg/.jpeg/.png`, priority order), it is resized once per folder (System.Drawing: max 1200 px, JPEG q86, never upscaled, EXIF rotation honored, white background for transparent images). The embedded PICTURE blocks are then removed from that folder's FLACs (the folder image remains the lossless master) and the resized JPEG is embedded into the `.opus` files instead. Folders without a recognized image keep their embedded art, which is resized the same way and carried over into the `.opus` files.
3. **FLAC -> Opus** at VBR (default 128 kbit/s). The following Vorbis comments are preserved (synonyms in parentheses are remapped to the canonical name): `TITLE`, `ALBUM`, `ARTIST`, `ALBUMARTIST` (`ALBUM_ARTIST`), `GENRE`, `DATE` (`YEAR`), `TRACKNUMBER` (`TRACK`), `DISCNUMBER` (`DISC`), `COPYRIGHT`, `ISRC`, `LABEL` (`ORGANIZATION`), `TOTALDISCS` (`TOTALDISC`, `TOTAL_DISCS`), `TOTALTRACKS` (`TOTALTRACK`, `TOTAL_TRACKS`), `UPC` (`BARCODE`, `EAN`). All other tags are dropped.

Existing `.opus` files newer than their `.flac` (modification-time check) are skipped; an art-strip performed during the current run forces that file's opus to be rebuilt; `-Force` redoes everything. After changing any encoding rule, a one-time `-NoReencode -Force` pass re-syncs the existing opus files.

Failures are never fatal to the library: a file that fails leaves the original untouched and is reported as a warning, counted in the run summary.

## Requirements

- Windows with PowerShell 5.1
- flac.exe + metaflac.exe (1.5.0+ recommended): `winget install Xiph.FLAC` or download from [FLAC downloads page](https://xiph.org/flac/download.html)
- opusenc.exe: [RareWares builds](https://www.rarewares.org/opus.php) recommended

The script degrades gracefully when optional pieces are missing: without metaflac.exe there is no art stripping and all tags are copied (with a warning); without System.Drawing, embedded art is kept as-is.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\Convert-Music.ps1 -Path "D:\Music"
```

```powershell
# rebuild every .opus with the current rules, FLACs untouched
.\Convert-Music.ps1 -Path "D:\Music" -NoReencode -Force

# mirror the .opus files into a separate tree instead of next to the FLACs
.\Convert-Music.ps1 -Path "D:\Music" -OpusRoot "D:\Music-opus"
```

| Parameter | Default | Description |
|---|---|---|
| `-Path` | (required) | Folder that contains the FLAC library |
| `-OpusBitrate` | 128 | Opus VBR target, kbit/s (24-512) |
| `-CoverMaxDim` | 1200 | Max width/height (px) of the JPEG embedded in `.opus` (64-4000) |
| `-CoverJpegQuality` | 86 | JPEG quality for the embedded cover (50-100) |
| `-FlacExe` / `-OpusencExe` | auto | Full path to flac.exe / opusenc.exe when not on PATH |
| `-OpusRoot` | (none) | Mirror `.opus` files into this separate tree |
| `-NoReencode` | off | Skip the FLAC -> FLAC re-encode |
| `-NoOpus` | off | Skip the FLAC -> Opus encode |
| `-Force` | off | Redo everything, even if already up to date |

## Notes

- The console output encoding is switched to UTF-8 for the run (and restored afterwards) so non-ASCII tags survive into the `.opus` files on any console.
- The script exits with code 1 when any file failed (0 on a clean run), which makes failures visible to scheduled tasks and other callers.
- Paths longer than 260 characters are not supported.
