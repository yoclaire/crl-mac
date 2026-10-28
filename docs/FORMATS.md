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
