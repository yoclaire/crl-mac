# Complete Reference Library for macOS

A native macOS (Apple silicon) version of Mindscape's 1995 *Complete Reference Library* CD-ROM,
rebuilt by reverse-engineering the original Windows program and its data formats. No emulation.

It reads **your own disc image**; nothing from the disc is included in this repository.

## What's on the disc

Ten reference works (American Heritage Dictionary 3rd ed., Concise Columbia Encyclopedia,
Information Please Almanac, Roget's II, National Directory, Legal Word Book, Wall Street Words,
Reader's Companion to American History, Written Word III, Simpson's Contemporary Quotations),
~1,800 photos and maps, ~10,000 spoken pronunciations, 81 videos and animations, 154 MIDI tracks.

## Build and run

Requires macOS 15+, Swift 6 (Command Line Tools are enough). For video, install ffmpeg first
(`brew install ffmpeg`): the disc's Indeo 3 video is converted once during import.

```sh
./scripts/make-app.sh                     # -> dist/Complete Reference Library.app
open "dist/Complete Reference Library.app"
```

On first launch, drop the `.iso` onto the window (or File ▸ Import Disc Image…). Import takes about
a minute and builds `~/Library/Application Support/Complete Reference Library/library` (~1 GB).

Command-line equivalents:

```sh
swift build -c release
.build/release/crltool import "Complete Reference Library (1995)(Mindscape).iso" ./library
.build/release/crltool search ./library hubble telescope
.build/release/crltool entry  "…iso" dictionary 25213
.build/release/crltool selftest
```

## Layout

- `Sources/CRLKit` — ISO 9660 reader, InfoSoft RE text decoder, Pegasus JPEG repair, Trio C-Index
  catalogue readers, PE resource extractor, library builder (SQLite + FTS5).
- `Sources/CRLApp` — the 1995 reading room in SwiftUI/AppKit, drawn with the bitmaps unpacked from
  the disc's `CRL32.EXE`.
- `tools/*.py` — the original Python prototypes of the decoders.
- `docs/FORMATS.md` — everything recovered about the file formats and UI.
