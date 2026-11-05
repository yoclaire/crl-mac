# Complete Reference Library for macOS

A native macOS (Apple silicon) version of Mindscape's 1995 *Complete Reference Library* CD-ROM,
rebuilt by reverse-engineering the original Windows program and its data formats. No emulation.

The finished app is self-contained: the disc is decoded once at build time and the result is
embedded in the app bundle. Nothing from the disc is included in this repository, and because the
built app contains the (copyrighted) disc content it is for personal use, not for sharing.

## What's on the disc

Ten reference works (American Heritage Dictionary 3rd ed., Concise Columbia Encyclopedia,
Information Please Almanac, Roget's II, National Directory, Legal Word Book, Wall Street Words,
Reader's Companion to American History, Written Word III, Simpson's Contemporary Quotations),
~1,800 photos and maps, ~10,000 spoken pronunciations, 81 videos and animations, 154 music clips.

## Get the app

Two ways, neither needs the disc. The releases are private to this repository.

**Download and run.** Grab `Complete-Reference-Library-<version>.zip` from the latest release, unzip,
and open it:

```sh
gh release download --repo yoclaire/crl-mac --pattern 'Complete-Reference-Library-*.zip'
ditto -x -k Complete-Reference-Library-*.zip . && open "Complete Reference Library.app"
```

The app is ad-hoc signed, so a copy downloaded in a browser is quarantined: the first time, right-click →
Open (or allow it in System Settings → Privacy & Security). Copies fetched with `gh` aren't quarantined.

**Build from source.** Requires macOS 15+ and Swift 6 (Command Line Tools are enough) plus `gh`:

```sh
git clone https://github.com/yoclaire/crl-mac && cd crl-mac
./scripts/make-app.sh          # downloads the decoded library from its release, then builds
open "dist/Complete Reference Library.app"
```

`make-app.sh` embeds the first library it finds: `--library DIR`, else `build/library`, else the app's
Application Support one, else `CRL-library-<version>.zip` from the release named by `LIBRARY_RELEASE` in
the script (checked against `scripts/library.sha256`). `--download` forces a fresh download.

**From the disc.** With the ISO (and ffmpeg, `brew install ffmpeg`, for the Indeo 3 video, converted
once during import), `./scripts/make-app.sh --iso "Complete Reference Library (1995)(Mindscape).iso"`
decodes everything in about 80 seconds. Only needed when the decoders change; publish the new
`build/library` with the next release and update `LIBRARY_RELEASE` and `scripts/library.sha256`.
`--no-embed` builds an empty app that asks for the disc on first launch.

Command-line equivalents (with Command Line Tools 27.2, add `--build-system native` to `swift build`;
its default build system can't start — `make-app.sh` does this automatically):

```sh
swift build -c release
.build/release/crltool import "Complete Reference Library (1995)(Mindscape).iso" ./library
.build/release/crltool search ./library hubble telescope
.build/release/crltool entry  "…iso" dictionary 25213
.build/release/crltool selftest
.build/release/crltool ui "…iso" ./library     # refresh only the artwork, sounds, font and icon
.build/release/crltool iconset ./library AppIcon.iconset   # the app icon (make-app.sh does this)
```

## CRL Quick Bar

Room menu → CRL Quick Bar, or System Configuration → Quick Reference to open it at start-up. It
floats above other apps. Select a word anywhere, click the magnifier, and the library comes forward
with the matches in the Index; the lettered buttons open and close books for searching. Reading
another app's selection needs Accessibility access (System Settings → Privacy & Security →
Accessibility); without it the bar searches whatever is on the clipboard. The Services menu item
"Search in Complete Reference Library" does the same for a selection without any permission.

## Layout

- `Sources/CRLKit` — ISO 9660 reader, InfoSoft RE text decoder, Pegasus JPEG repair, Trio C-Index
  catalogue readers, PE resource extractor, library builder (SQLite + FTS5).
- `Sources/CRLApp` — the 1995 reading room in SwiftUI/AppKit, drawn with the bitmaps unpacked from
  the disc's `CRL32.EXE`.
- `tools/*.py` — the original Python prototypes of the decoders.
- `docs/FORMATS.md` — everything recovered about the file formats and UI.
