import Foundation

/// The disc's text help, `CRL32.HLP` (WinHelp 3.1, uncompressed, no phrase table).
///
/// Layout: a header (`magic 0x35F3F, u32 directory`), a B+tree directory of internal files, and the
/// internal files themselves (`u32 reserved, u32 used, u8 flags`, data). `|TOPIC` is a stream of topic
/// links `{i32 blockSize, i32 dataLen2, i32 prev, i32 next, i32 dataLen1, u8 type}` + LinkData1
/// (paragraph format and a command list) + LinkData2 (text, one NUL-separated segment per command).
/// Type 2 starts a topic (its title is LinkData2's first string); type 0x20 holds paragraphs.
/// See docs/FORMATS.md for the command table.
public enum HelpFile {
    public struct Topic: Sendable { public let title: String; public let body: String }

    /// Markers inside `Topic.body`: links (text = target topic title) and bold runs.
    public static let linkStart: Character = "\u{1}", linkEnd: Character = "\u{2}"
    public static let boldStart: Character = "\u{3}", boldEnd: Character = "\u{4}"

    public enum Error: Swift.Error { case notWinHelp, unsupported(String), malformed(String) }

    public static func topics(_ data: Data) throws -> [Topic] {
        var d = [UInt8](data)   // var: the de-blocked |TOPIC stream is appended below
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= d.count else { throw Error.malformed("read past end at \(o)") }
            return Int(d[o]) | Int(d[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int { let lo = try u16(o), hi = try u16(o + 2); return lo | hi << 16 }
        func i32(_ o: Int) throws -> Int { Int(Int32(truncatingIfNeeded: try u32(o))) }
        func cstr(_ o: Int, _ end: Int) -> (String, Int) {
            var e = o
            while e < end, d[e] != 0 { e += 1 }
            return (String(decoding: d[o..<e], as: UTF8.self), e + 1)
        }
        guard d.count > 16, try u32(0) == 0x35F3F else { throw Error.notWinHelp }

        // Internal file directory: walk the B+tree down its first children, then along the leaves.
        func leaves(_ fileOffset: Int) throws -> [ArraySlice<UInt8>] {
            let h = fileOffset + 9
            guard try u16(h) == 0x293B else { throw Error.malformed("B+tree magic") }
            let pageSize = try u16(h + 4), root = try u16(h + 26), levels = try u16(h + 32)
            let pages = h + 38
            var page = root
            for _ in 1..<max(levels, 1) { page = try u16(pages + page * pageSize + 4) }
            var out: [ArraySlice<UInt8>] = [], seen = Set<Int>()
            while page != 0xFFFF, seen.insert(page).inserted {
                let start = pages + page * pageSize
                guard start + pageSize <= d.count else { throw Error.malformed("B+tree page \(page)") }
                out.append(d[start..<start + pageSize])
                page = try u16(start + 6)
            }
            return out
        }
        var files: [String: Int] = [:]
        for leaf in try leaves(try u32(4)) {
            let base = leaf.startIndex
            var o = base + 8
            for _ in 0..<(try u16(base + 2)) {
                let (name, next) = cstr(o, leaf.endIndex)
                files[name] = try u32(next); o = next + 4
            }
        }
        func internalFile(_ name: String) throws -> Range<Int> {
            guard let o = files[name] else { throw Error.malformed("missing \(name)") }
            let used = try u32(o + 4)
            guard o + 9 + used <= d.count else { throw Error.malformed("\(name) size") }
            return (o + 9)..<(o + 9 + used)
        }

        // |SYSTEM: this decoder handles the disc's uncompressed variant only.
        let sys = try internalFile("|SYSTEM")
        guard try u16(sys.lowerBound) == 0x036C else { throw Error.malformed("|SYSTEM magic") }
        let minor = try u16(sys.lowerBound + 2), flags = try u16(sys.lowerBound + 10)
        guard minor > 16, flags == 0 else { throw Error.unsupported("compressed topics (minor \(minor), flags \(flags))") }
        if files["|Phrases"] != nil { throw Error.unsupported("phrase compression") }

        // |FONT: descriptor → face name, to map Symbol-font characters and find bold runs.
        let font = try internalFile("|FONT")
        let nFaces = try u16(font.lowerBound), nDesc = try u16(font.lowerBound + 2)
        let faceOff = font.lowerBound + (try u16(font.lowerBound + 4)), descOff = font.lowerBound + (try u16(font.lowerBound + 6))
        let faceWidth = nFaces > 0 ? (descOff - faceOff) / nFaces : 0
        let faces = (0..<nFaces).map { cstr(faceOff + faceWidth * $0, faceOff + faceWidth * ($0 + 1)).0 }
        let descs: [(symbol: Bool, bold: Bool)] = try (0..<nDesc).map { k in
            let o = descOff + 11 * k, face = try u16(o + 3)
            return (face < faces.count && faces[face] == "Symbol", d[o] & 1 != 0)
        }

        let symbol: [UInt8: String] = [0xD2: "®", 0xD3: "©", 0xD4: "™", 0xE2: "®", 0xE3: "©", 0xE4: "™",
                                       0xB7: "•", 0xB0: "°", 0xD7: "×", 0xB1: "±"]
        func cp1252(_ b: ArraySlice<UInt8>) -> String {
            String(data: Data(b), encoding: .windowsCP1252) ?? String(decoding: b, as: UTF8.self)
        }

        // Compressed integers in LinkData1.
        func cword(_ o: inout Int) throws -> Int {
            if d[o] & 1 == 0 { defer { o += 1 }; return Int(d[o]) >> 1 }
            defer { o += 2 }; return try u16(o) >> 1
        }
        func cint(_ o: inout Int) throws -> Int {
            if d[o] & 1 == 0 { defer { o += 1 }; return Int(d[o]) / 2 - 0x40 }
            defer { o += 2 }; return try u16(o) / 2 - 0x4000
        }
        func clong(_ o: inout Int) throws -> Int {
            if try u16(o) & 1 == 0 { defer { o += 2 }; return try u16(o) >> 1 }
            defer { o += 4 }; return try u32(o) >> 1
        }

        /// One paragraph record → text with markers. `ld1`/`ld2` are absolute ranges into `d`.
        func paragraph(_ ld1: Range<Int>, _ ld2: Range<Int>) throws -> String {
            var o = ld1.lowerBound
            _ = try clong(&o); _ = try cword(&o)          // topic size, topic length
            o += 4                                         // unknown byte, biased byte, paragraph id
            let bits = try u16(o); o += 2
            if bits & 0x0001 != 0 { _ = try clong(&o) }
            for m in [0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040] where bits & m != 0 { _ = try cint(&o) }
            if bits & 0x0100 != 0 { o += 3 }
            if bits & 0x0200 != 0 {
                for _ in 0..<max(try cint(&o), 0) { if try cword(&o) & 0x4000 != 0 { _ = try cword(&o) } }
            }
            var segments: [ArraySlice<UInt8>] = [], s = ld2.lowerBound
            for i in ld2 where d[i] == 0 { segments.append(d[s..<i]); s = i + 1 }
            segments.append(d[s..<ld2.upperBound])

            var out = "", current = 0, inLink = false, bold = false, next = 1
            func text(_ seg: ArraySlice<UInt8>) {
                guard !seg.isEmpty else { return }
                let sym = current < descs.count && descs[current].symbol
                out += sym ? seg.map { symbol[$0] ?? String(UnicodeScalar($0)) }.joined() : cp1252(seg)
            }
            text(segments[0])
            while o < ld1.upperBound {
                let c = d[o]; o += 1
                if c == 0xFF { break }
                switch c {
                case 0x20: o += 4
                case 0x21: o += 2
                case 0x80:
                    current = try u16(o); o += 2
                    let b = current < descs.count && descs[current].bold
                    if b != bold, !inLink { out.append(b ? boldStart : boldEnd); bold = b }
                case 0x81: out += "\n"
                case 0x82: out += "\n\n"
                case 0x83: out += "\t"
                case 0x86, 0x87, 0x88:                     // picture: type, size, [hotspot count], data
                    let kind = d[o]; o += 1
                    let n = try clong(&o)
                    if kind == 0x22 { _ = try cword(&o) }
                    o += n
                case 0x89: if inLink { out.append(linkEnd); inLink = false }
                case 0x8B: out += "\u{a0}"
                case 0x8C: out += "\u{2011}"
                case 0xC8, 0xCC: o += 2 + (try u16(o))   // macro
                case 0xE0, 0xE1, 0xE2, 0xE3, 0xE6, 0xE7:   // jump / popup to a topic hash
                    o += 4
                    if bold { out.append(boldEnd); bold = false }
                    out.append(linkStart); inLink = true
                case 0xEA, 0xEB, 0xEE, 0xEF: o += 2 + (try u16(o))
                default: throw Error.malformed(String(format: "paragraph command 0x%02X", c))
                }
                if next < segments.count { text(segments[next]); next += 1 }
            }
            if inLink { out.append(linkEnd) }
            if bold { out.append(boldEnd) }
            return out
        }

        // |TOPIC is stored in 4 KB blocks, each with a 12-byte header {lastLink, firstLink, lastTopic};
        // topic links run on across block boundaries, so rebuild the continuous stream first.
        let raw = try internalFile("|TOPIC")
        let first = try i32(raw.lowerBound + 4)
        var stream: [UInt8] = []
        for b in stride(from: raw.lowerBound, to: raw.upperBound, by: 4096) where b + 12 < raw.upperBound {
            stream += d[(b + 12)..<min(b + 4096, raw.upperBound)]
        }
        let base = d.count
        d += stream
        let topic = base..<d.count
        var o = base + max(first - 12, 0), out: [Topic] = []
        var title: String?, body = ""
        func flush() {
            guard let t = title else { return }
            let cleaned = body.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !cleaned.isEmpty { out.append(Topic(title: t, body: cleaned)) }
        }
        while o + 21 <= topic.upperBound {
            let size = try i32(o), len1 = try i32(o + 16), type = d[o + 20]
            guard size > 0, len1 >= 21, o + size <= topic.upperBound, len1 <= size else { break }
            let ld1 = (o + 21)..<(o + len1), ld2 = (o + len1)..<(o + size)
            switch type {
            case 2:
                flush()
                title = cp1252(d[ld2.lowerBound..<(d[ld2].firstIndex(of: 0) ?? ld2.upperBound)])
                body = ""
            case 0x20 where title != nil:
                body += try paragraph(ld1, ld2)
            default: break
            }
            o += size
        }
        flush()
        return out
    }
}
