# Complete Reference Library (Mindscape, 1995) — file formats

Recovered with REA + Ghidra 12.1.4 from the shipped Win32 binaries. Addresses refer to
`CRL/REWIN32.DLL` (sha256 `d185f9b8…5ff9d`).

## Disc layout

| Path | What |
|---|---|
| `CRL/CRL32.EXE` | MFC front end (Win32) |
| `CRL/REWIN32.DLL` | InfoSoft "RE" reference engine: `REdb`, `REentry`, `REsearch`, `REidxlst`, … |
| `CRL/PEGASUS.DLL` | Pegasus Imaging codec (JPEG inside `MEDIA.FIL`) |
| `CRL/REFDATA/REN*.DAT` | Ten InfoSoft reference databases (below) |
| `CRL/MEDIADB/MEDIA.{DBS,CTG,LNK,UTL,FIL}` | Media catalogue + blob store |
| `CRL/VIDEOS/*.AVI`, `CRL/HELP/*.AVI` | Video for Windows clips |
| `CRL/ANIMATE/*.ANI` | Animations (format TBD) |
| `CRL/MUSIC/*.MID` | Standard MIDI |

## Reference databases (`REFDATA/REN*.DAT`)

| File | Title | Entries |
|---|---|---|
| REN3F500 | American Heritage Dictionary, 3rd ed. | 94,618 |
| RENAP421 | Information Please Almanac 1994 | 7,817 |
| RENEF420 | Columbia Encyclopedia | 14,189 |
| RENLW442 | Legal Word Book, 3rd ed. | 25,830 |
| RENND401 | National Directory | 129,305 |
| RENQF410 | Simpson's Quotations | 5,636 |
| RENRC420 | Reader's Companion to American History | 1,167 |
| RENTF330 | English Thesaurus (Roget's II) | 4,791 |
| RENWS411 | Wall St. Words | 3,061 |
| RENWW421 | Written Word III | 3,538 |

All integers in headers are **big-endian**; the grammar tables and checkpoint table are
**little-endian** (they are loaded raw and read with `CONCAT11(b[1], b[0])`).

### Master header (file offset 0, one 0x200 block per `hdr[0x31d]`)

- `0x316` u16: number of sub-files
- `0x318` u32: offset of the sub-file directory
- Directory: 12-byte records `{u16 type, u16 id, u32 header_offset, u32 data_base}`
  (parsed in `FUN_10016*`, loop near `0x10016...`; type 1 → `FUN_10016c3c`, type 2 → `FUN_10017922`).
  - type 1 = **entry file** (the article text); `data_base` = start of the code stream.
  - type 2 = search index files (not needed: we rebuild search with SQLite FTS).

### Entry-file header (`FUN_10016c3c`, at `header_offset`)

- `0x1e` u16 × 512 → code-stream length in bytes
- `0x50` u16 section count, `0x52` u32 offset (relative to header) of the section directory
- `0x68` u32 number of entries (entries are numbered 1..N; entry 0 is empty)
- `0x72` u16 checkpoint interval (power of two; `shift = log2`)
- `0x76` u16 code width in bits (10–13)
- Section directory: 16-byte records `{u16 id, u32 offset (rel. header), u32 ?, u16 count, u32 size}`

| Section | Meaning |
|---|---|
| 10 (0x0a) | checkpoint table: u32 LE code index of every 2^shift-th entry |
| 20 (0x14) | grammar table L: i16 LE per code |
| 30 (0x1e) | grammar table R: i16 LE per code |
| 40 (0x28) | tag table (parsed by `FUN_1001aae2`; not needed for decoding) |
| 60 (0x3c) | string pool for terminals |
| 80, 90 | auxiliary tables (TBD) |

### Text decompression (`FUN_100127e0`)

The entry stream is fixed-width codes, MSB-first, packed into big-endian 16-bit words
(`FUN_10027b85` seeks to `code_index * width` bits).

For each code `c`:
- `c == END` terminates the entry. With a string pool, `END` is the terminal whose
  `R[c] == 4` and whose pool string is `FE FE FE FE`; without a pool it is `count(L) - 1`.
- terminal if `c < NTERM` (`NTERM = 2^width - L[0]`) or `R[c] == -1`:
  - `R[c] == -1` → one literal byte, `L[c] & 0xff`
  - otherwise → `R[c]` bytes from `pool[L[c]]`
- nonterminal otherwise → expand `L[c]` then `R[c]` (explicit stack in the original).

Byte `0xFF` in the output is a newline. Text is Windows-1252 with SGML-ish markup
(`<WD>` title, `<HW>`, `<P>`, `<xr>`/`<dxr>` cross-refs, `&ldquo;`-style entities; the AHD
uses backslash glyph names like `\schwa/` drawn from `CRL_1.TTF`).

Locating entry `n`: `k = n >> shift`; start at code index `ckpt[k]`; skip
`(n & (2^shift - 1)) + (k ? 1 : 0)` END codes.

Verified: a sequential decode of every database yields exactly N+1 entries and matches
random-access lookups (`tools/verify.py`).

## Media blob store (`MEDIADB/MEDIA.FIL`)

Sequential records: `char name[14]` (NUL-padded 8.3 name), `u32 LE size`, 8 reserved bytes,
then `size` bytes of payload. 11,784 records:

| Kind | Count | Payload |
|---|---|---|
| `*.WAV` | 9,964 | RIFF WAVE, MS-ADPCM (tag 2), mono 22.05 kHz — Core Audio decodes it natively |
| `*.PIC` | 1,502 | photo, see below |
| `*.MAP` | 318 | map, same encoding as PIC |

PIC/MAP payload = `BITMAPFILEHEADER` + 68-byte `BITMAPINFOHEADER` with `biCompression='JPEG'`
(negative height = top-down) + a 216-colour palette (for 8-bit displays) + a JFIF stream at
`bfOffBits`.

The JFIF stream is **abbreviated**: it has no DQT/DHT. Pegasus (`PEGASUS.DLL`, Watcom C 1994)
reconstructs them from an `APP1` segment `"PIC\0", u8 flag, u8 Ql, u8 Qc, u8 ?`
(handler `FUN_004113ac`, via the marker jump table at `0x4200a0`):

- `FUN_00415444`: `q[i] = clamp((base[i] * Q) >> 5, 1, 255)`; luma uses `Ql`, chroma `Qc`;
  base tables at `0x430750` / `0x430790` are the JPEG Annex K tables in zigzag order.
- `FUN_00415278`: the standard Annex K Huffman tables.

`tools/mediafil.py` rebuilds a conforming JPEG by inserting those segments; all 1,820 images decode.

## Media catalogue (`MEDIA.DBS/.LNK/.UTL/.CTG`)

Trio Systems C-Index files ("(c) Copyright Trio Systems 1983-1990" in `CRL32.EXE`; opened by
`FUN_0044dae4`). Layout: a 1 KB file header (`VALIDAT1` signature interleaved with u32s), then
**4 KB B-tree nodes**; a node's `u16` at +12 is its level (0 = leaf). Records are
`u8 L, u8 key type, u8 chunk, u32 0, key\0, payload`, spanning `L+1` bytes. **Index nodes** (level ≥ 1)
repeat leaf keys in exactly the same shape but follow the key with a `u32` child node number instead of
the data — scanners must skip them (`MediaCatalog.isLeafNode`). Node counts: CTG 94 leaf + 1 index,
UTL 415 + 6, DBS 622 + 6, LNK 106 + 1. The readers scan leaf records rather than walking the tree.

- **DBS** (16,138 records) — **the per-article media index CRL32 consults** (`FUN_004191ad` →
  `FUN_0041ac8f` → C-Index exact find), for every book with media. Key type = book code + 1, key =
  `keyType << 28 | entry` (book codes, table at `0x49b0d8`: 0 Dictionary, 1 Thesaurus, 2 Almanac,
  3 Quotations, 4 Encyclopedia, 5 Written Word, 6 Wall Street, 7 American History, 8 Directory, 9 Legal).
  Record `L, keyType, chunk, u32 entry, u32 key`, blob `u8 counts[7], u32 blobLen (= 11 + items)`, then
  items grouped by type: 0 picture / 2 pronunciation / 6 map are 56 bytes `{u8 type, char caption[51],
  u32 MEDIA.FIL offset}`, 1 video / 3 music / 4 animation are 66 bytes `{u8 type, char caption[51],
  char file[14]}` (type 5 unused). 240 large blobs are split into chunks like CTG's. The counts enable
  the room's media objects; one map is shown directly, several open a caption menu. Records per key type:
  1 Dictionary 13,127 · 2 Thesaurus 1 · 3 Almanac 814 · 5 Encyclopedia 1,866 · 7 Wall Street 3 ·
  8 American History 327; 317 of the 318 maps are referenced.
- **LNK** (212 records) — `MID`/`AVI`/`ANI` file → `[(u32 db_code, u32 entry)]`, after a 7-byte pad.
  db codes: 0 = AHD, 2 = Almanac, 4 = Columbia, 7 = Reader's Companion.
- **UTL** — the Media Library's authored captions, one key type per kind; payload `u32, caption`:

  | key type | key | records | u32 |
  |---|---|---|---|
  | 1 | `NAME.PIC` picture | 1,501 | MEDIA.FIL offset |
  | 2 | `NAME.AVI` video | 50 | 0 |
  | 3 | `NNNNN.WAV` pronunciation (the word) | 9,964 | (unrelated) |
  | 4 | `NNNNNNN.MID` music | 140 of 154 | 0 |
  | 5 | `NAME.ANI` animation | 22 of 25 | 0 |
  | 7 | `NAME.MAP` map ("North Korea", "Albuquerque, NM") | 318 | MEDIA.FIL offset |

  For pictures and maps a caption counts only when its offset lands on the FIL record of the same name.
- **CTG** — gallery categories. Records are `L, 01, chunk, u32 0, name\0, payload`; `chunk` bit 7 =
  last chunk, low bits = index (`0x80` = single chunk). Payloads concatenate to `u32 count` +
  `count × char[14]` names (a name may straddle chunks). All 63 categories in `@@@_CATG_NAMES`
  reassemble once the index node's key copies are skipped (the 7 that failed before — Business Leaders,
  Entertainers, Foreign Political Figures, Literature/Writers, Places, Scientists/Doctors,
  Tools/Instruments — each had an index-node copy of one chunk ahead of the leaf copy).
- **Maps** are linked through DBS like every other medium (type 6). (Earlier versions of the
  importer matched map names against article titles; that heuristic is gone.)

## Text help (`CRL32.HLP`)

WinHelp 3.1 (`|SYSTEM` minor 21, flags 0: uncompressed, no `|Phrases`). Internal files: `|CONTEXT
|CTXOMAP |FONT |KWBTREE |KWDATA |KWMAP |SYSTEM |TOPIC |TTLBTREE`. `|TOPIC` is 4 KB blocks with a 12-byte
header each; topic links run across block boundaries. Link `{i32 size, i32 len2, i32 prev, i32 next,
i32 len1, u8 type}`: type 2 opens a topic (title = first string of LinkData2), type 0x20 is a paragraph
record: compressed `topicSize`, `topicLength`, two bytes, `u16 id`, `u16 bits` + the fields `bits` selects
(tab count is a *signed, biased* compressed short), then commands until `0xFF`, each consuming the next
NUL-separated text segment: `0x80 u16` font, `0x81` line break, `0x82` paragraph end, `0x83` tab,
`0x86–88` picture, `0x89` hotspot end, `0xE0–E7 u32` jump/popup, `0xC8/0xCC` macro. Symbol-font
runs carry ©/®/™ as 0xD3/0xE2/0xD4. 16 topics, 12 jumps — every jump's text is its target's title.
`HelpFile.swift` decodes it into `help_topics`.

## Video (`VIDEOS/*.AVI`, `HELP/*.AVI`, `ANIMATE/*.ANI`)

`.ANI` files are plain AVIs. Every clip is Intel Indeo 3.2 (`IV32`) video with 8-bit PCM audio at
22.05 kHz. AVFoundation can't decode Indeo 3, so the importer converts each clip once with ffmpeg
(`h264_videotoolbox` + AAC, ~0.6 s per clip).

`MUSIC/*.MID` are **not MIDI**: all 154 are RIFF WAVE recordings (MS-ADPCM, mono 22.05 kHz) with a
`.MID` name. The importer stores them by content type (`.wav`) and plays them as audio.

## Reading room UI (`CRL32.EXE` resources)

- Backgrounds: bitmap 271 (room lit), 272 (dim), 308 (Media Library), 477 (splash). Sprites use
  magenta (255,0,255) as the transparent key; the list icon strip `IDB_MAINLIST` uses pure blue.
- Room objects: two parallel `CRect` tables (31 hit rectangles, then 31 draw rectangles; the second
  table has one leading empty rectangle) in the function at decompiled line ~40302 of CRL32.
  Pass-Over Help strings are RT_STRING 3000–3028 in the same object order. Sprite variants per object
  are lit / lit-hover / lit-disabled / dim / dim-hover / dim-disabled (see
  `Sources/CRLApp/Resources/room.json`).
- `IDB_MAINLIST`: 16×16 icons, 4 columns (closed book, book+, folder, document) × 17 rows
  (D T A Q E S W H N L, then map, video, sound, music, picture, animation, search).
- Panel geometry (Subject List, article pane, media combo) was measured from a screenshot of the
  original running; it is not in the resources.

## CRL Quick Bar (`CRLBAR32.EXE`)

An MFC 3 floating toolbar, separate from CRL32, that looks up the selection in another program.

- Bitmap 106: 192×15, 4 bpp, twelve 16×15 glyphs: magnifier, E D T A N L W H S Q, Exit. (Bitmap 103
  is a 7-glyph strip with E D T A H only, apparently for a smaller edition.) Button-face grey
  (192,192,192) is the background; the library stores it keyed out as `ui/quickbar.png`.
- Layout, from the tooltip hit test at `0x40412b`: 3 columns × 4 rows of 22 × 21 cells. Tooltips are
  "Search/Open Reference", "Open …" / "Close …" with the book's name, and "Exit".
- Command IDs 0x259 (search), 0x25A–0x263 (books, mapped by `0x401a17` to book codes
  4 0 1 2 8 9 6 7 5 3), 0x264 (Exit, `ExitProcess`).
- A book button toggles it. If CRL32's window ("Complete Reference Library for Windows") exists it
  sends message 0x4C9 (wParam 1 = open, 2 = close; lParam = book code); otherwise it writes the
  10-digit mask to `CRL32.INI [Configuration] OpenReferences`. At start-up 0x4C9 with wParam 0 asks
  CRL32 for the open-book bitmask.
- Search (`0x401b37`): opens and empties the clipboard, `SetForegroundWindow` on the window that was
  active before the bar, sends Ctrl+C with `keybd_event` (`0x402345`), waits up to 6 s for the
  clipboard owner to change, then `ShellExecute`s `CRL32.EXE Search`, waits for its window, and sends
  0x4CA (1, first open book code).

The macOS bar keeps the look, layout, tooltips and book toggling. Its panel never takes focus, so the
app you were using is still in front: the selection is read with Accessibility (`AXSelectedText`),
falling back to a ⌘C keystroke and the clipboard, which is put back afterwards.

## Media Library names and groupings (derived)

Only photos have authored captions (MEDIA.UTL) and categories (MEDIA.CTG). For everything else the
importer derives names from the disc's own data (`LibraryBuilder.nameAndGroupMedia`):

| Type | Name | Categories |
|---|---|---|
| Pronunciations | the word in their MEDIA.DBS item | A–Z, "#", plus "Unlabelled" for 112 recordings no entry references |
| Music (WAVE clips named `.MID`) | first article MEDIA.LNK links it to (repeats numbered) | Instruments (`500xxxx.MID`) / Musical Styles (`60xxx.MID`) |
| Video, animation | linked article whose title matches the file name, else the first link | one group each |
| Maps | name-matched article title, or the alias table | 12 regions: MEDIA.FIL stores maps as one alphabetical run per region (region names are ours) |
| Photos not in any CTG category | — | "Other Pictures" |
