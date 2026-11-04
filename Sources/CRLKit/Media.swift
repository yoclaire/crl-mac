import Foundation

/// MEDIA.FIL blob store and the Pegasus "PIC" JPEG repair. See docs/FORMATS.md.
public enum MediaFile {
    public struct Record {
        public let name: String     // 8.3 name, e.g. "I0110026.PIC", "00001.WAV"
        public let offset: Int      // offset of the 26-byte record header (what the catalogue stores)
        public let size: Int
        public var dataOffset: Int { offset + 26 }
    }

    /// Walk the sequential records. `read` returns bytes at an absolute file offset.
    public static func records(fileSize: Int, read: (Int, Int) throws -> Data) rethrows -> [Record] {
        var out: [Record] = [], o = 0
        while o + 26 <= fileSize {
            let h = try read(o, 26)
            let name = h.cString(0, max: 14), size = Int(h.le32(14))
            out.append(Record(name: name, offset: o, size: size))
            o += 26 + size
        }
        return out
    }

    // Base quantisation tables, PEGASUS.DLL @0x430750 / @0x430790 (zigzag order = JPEG Annex K).
    static let qBase: [[UInt8]] = [
        [16, 11, 12, 14, 12, 10, 16, 14, 13, 14, 18, 17, 16, 19, 24, 40, 26, 24, 22, 22, 24, 49, 35, 37, 29, 40, 58, 51,
         61, 60, 57, 51, 56, 55, 64, 72, 92, 78, 64, 68, 87, 69, 55, 56, 80, 109, 81, 87, 95, 98, 103, 104, 103, 62, 77,
         113, 121, 112, 100, 120, 92, 101, 103, 99],
        [17, 18, 18, 24, 21, 24, 47, 26, 26, 47, 99, 66, 56, 66] + Array(repeating: 99, count: 50),
    ]

    // Standard Annex K Huffman tables (FUN_00415278 builds these).
    static let huffman: [(UInt8, [UInt8], [UInt8])] = [
        (0x00, [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], Array(0...11)),
        (0x10, [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d], hex(
            "01020300041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9fa")),
        (0x01, [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], Array(0...11)),
        (0x11, [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77], hex(
            "000102031104052131061241510761711322328108144291a1b1c109233352f0156272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475767778797a82838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa")),
    ]

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = [], i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    static func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let n = payload.count + 2
        return [0xFF, marker, UInt8(n >> 8), UInt8(n & 0xFF)] + payload
    }

    /// Rebuild a conforming JPEG from Pegasus' abbreviated stream by inserting the DQT/DHT
    /// segments it derives from the APP1 "PIC\0" quality bytes (FUN_004113ac / FUN_00415444).
    public static func repairJPEG(_ j: Data) throws -> Data {
        guard j.count > 4, j.u8(0) == 0xFF, j.u8(1) == 0xD8 else { throw CRLError.format("not a JPEG") }
        var out: [UInt8] = [0xFF, 0xD8], i = 2
        var ql = 32, qc = 32, haveDQT = false, haveDHT = false
        while i + 4 <= j.count {
            guard j.u8(i) == 0xFF else { throw CRLError.format("bad JPEG marker at \(i)") }
            let m = j.u8(i + 1), len = Int(j.be16(i + 2))
            if m == 0xE1, j.sub(i + 4, 4) == Data([0x50, 0x49, 0x43, 0]) {
                ql = Int(j.u8(i + 9)); qc = Int(j.u8(i + 10))
                i += 2 + len; continue
            }
            if m == 0xDB { haveDQT = true }
            if m == 0xC4 { haveDHT = true }
            if (m == 0xC0 || m == 0xDA) && !haveDQT {
                for (tid, (base, q)) in zip(qBase, [ql, qc]).enumerated() {
                    out += segment(0xDB, [UInt8(tid)] + base.map { UInt8(min(255, max(1, (Int($0) * q) >> 5))) })
                }
                haveDQT = true
            }
            if m == 0xDA {
                if !haveDHT { for (tc, bits, vals) in huffman { out += segment(0xC4, [tc] + bits + vals) } }
                out += j[(j.startIndex + i)...]
                return Data(out)
            }
            out += j[(j.startIndex + i)..<(j.startIndex + i + 2 + len)]
            i += 2 + len
        }
        throw CRLError.format("JPEG without scan")
    }

    /// PIC/MAP payload → (repaired JPEG, width, height).
    public static func picture(_ blob: Data) throws -> (jpeg: Data, width: Int, height: Int) {
        guard blob.count > 54, blob.u8(0) == 0x42, blob.u8(1) == 0x4D else { throw CRLError.format("PIC without BM header") }
        let off = Int(blob.le32(10))
        let w = Int(Int32(bitPattern: blob.le32(18))), h = Int(Int32(bitPattern: blob.le32(22)))
        guard blob.sub(30, 4) == Data("JPEG".utf8) else { throw CRLError.format("PIC is not JPEG-compressed") }
        return (try repairJPEG(blob.sub(off, blob.count - off)), w, abs(h))
    }
}

/// The Trio Systems C-Index media catalogue (MEDIA.DBS/.LNK/.UTL/.CTG).
/// Records are found by scanning for self-validating layouts rather than walking the B-tree.
public enum MediaCatalog {
    /// One media item attached to an article. Pictures, pronunciations and maps are MEDIA.FIL records
    /// (`filOffset`); videos, music and animations are disc files (`file`, e.g. `ASHE.AVI`).
    public struct Item: Sendable {
        public let type: Int            // 0 picture, 1 video, 2 pronunciation, 3 music, 4 animation, 6 map
        public let label: String
        public let filOffset: Int?
        public let file: String?
    }

    /// MEDIA.DBS: the original's per-article media index, for every book that has media.
    ///
    /// CRL32 looks an article up by exact key (`FUN_004191ad` → `FUN_0041ac8f`): key type = book code + 1,
    /// key = `keyType << 28 | entry`. Records are `L, keyType, chunk, u32 entry, u32 key`, then a blob
    /// `u8 counts[7], u32 blobLen (= 11 + items), items grouped by type 0…6`: types 0, 2, 5, 6 are 56 bytes
    /// `{u8 type, char caption[51], u32 MEDIA.FIL offset}`, types 1, 3, 4 are 66 bytes
    /// `{u8 type, char caption[51], char file[14]}`. A blob too big for one record is split into chunks
    /// (`chunk` low bits = index, bit 7 = last), like MEDIA.CTG. The counts enable the room's media
    /// objects; the items, in stored order, are what each object shows.
    public static func articleMedia(_ d: Data) -> [(bookCode: Int, entry: Int, items: [Item])] {
        var chunks: [Int: [Int: Data]] = [:], last: [Int: Int] = [:]
        var i = 1
        while i + 11 < d.count {
            defer { i += 1 }
            let kt = Int(d.u8(i))
            guard kt > 0, kt < 16, isLeafNode(d, at: i) else { continue }
            let entry = Int(d.le32(i + 2)), key = Int(d.le32(i + 6))
            guard key >> 28 == kt, key & 0xFF_FFFF == entry else { continue }
            let flag = Int(d.u8(i + 1)), L = Int(d.u8(i - 1))
            let start = i + 10, end = i - 1 + L + 1
            guard end > start, end <= d.count else { continue }
            let index = flag & 0x7F
            if chunks[key, default: [:]][index] == nil { chunks[key, default: [:]][index] = d.sub(start, end - start) }
            if flag & 0x80 != 0, last[key] == nil { last[key] = index }
        }
        var out: [(bookCode: Int, entry: Int, items: [Item])] = []
        for (key, n) in last.sorted(by: { $0.key < $1.key }) {
            guard let parts = chunks[key], (0...n).allSatisfy({ parts[$0] != nil }) else { continue }
            let blob = (0...n).reduce(Data()) { $0 + parts[$1]! }
            guard blob.count >= 11 else { continue }
            let counts = (0..<7).map { Int(blob.u8($0)) }
            let size = { (t: Int) in [0, 2, 5, 6].contains(t) ? 56 : 66 }
            let declared = Int(blob.le32(7))
            guard declared == 11 + counts.enumerated().reduce(0, { $0 + $1.element * size($1.offset) }), declared <= blob.count else { continue }
            var items: [Item] = [], o = 11
            for (t, c) in counts.enumerated() {
                for _ in 0..<c {
                    let label = blob.cString(o + 1, max: 51)
                    if size(t) == 56 { items.append(Item(type: t, label: label, filOffset: Int(blob.le32(o + 52)), file: nil)) }
                    else { items.append(Item(type: t, label: label, filOffset: nil, file: blob.cString(o + 52, max: 14))) }
                    o += size(t)
                }
            }
            out.append(((key >> 28) - 1, key & 0xFF_FFFF, items))
        }
        return out
    }

    /// Records shaped `L, type, 80, u32 0, NAME.EXT\0, …`; yields (name, offset after the NUL, L).
    /// `type` is the C-Index key type (MEDIA.UTL: 1 picture, 2 video, 3 pronunciation, 4 music,
    /// 5 animation, 7 map). `leafOnly` skips B-tree index nodes, whose copies of a key carry a child
    /// node pointer instead of the record's data.
    static func namedRecords(_ d: Data, extensions: Set<String>, types: Set<UInt8> = [1], leafOnly: Bool = false,
                             _ body: (String, Int, Int) -> Void) {
        var i = 1
        while i + 8 < d.count {
            defer { i += 1 }
            guard types.contains(d.u8(i)), d.u8(i + 1) == 0x80, d.le32(i + 2) == 0,
                  !leafOnly || isLeafNode(d, at: i) else { continue }
            var e = i + 6
            while e < d.count, e < i + 20, d.u8(e) != 0 { e += 1 }
            let name = d.cString(i + 6, max: 13)
            let parts = name.split(separator: ".")
            guard parts.count == 2, parts[0].count <= 8, extensions.contains(String(parts[1])),
                  name.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) else { continue }
            body(name, e + 1, Int(d.u8(i - 1)))
        }
    }

    /// MEDIA.LNK: MID/AVI/ANI file → [(db code, entry)].
    public static func links(_ d: Data) -> [String: [(db: Int, entry: Int)]] {
        var out: [String: [(db: Int, entry: Int)]] = [:]
        namedRecords(d, extensions: ["MID", "AVI", "ANI"]) { name, p, L in
            let n = Int(d.u8(p))
            guard L + 1 == 1 + 6 + name.count + 1 + 8 + 8 * n, out[name] == nil else { return }
            out[name] = (0..<n).map { k in (Int(d.le32(p + 8 + 8 * k)), Int(d.le32(p + 12 + 8 * k))) }
        }
        return out
    }

    /// MEDIA.UTL: media file name → authored caption, for every kind the Media Library lists
    /// (`u32, caption`). Pictures and maps carry their MEDIA.FIL offset in the u32, so their caption
    /// only counts when that offset points at the record of the same name; for the other kinds the
    /// u32 is 0 or unrelated and the leaf-node check is the guard.
    public static func captions(_ d: Data, validOffsets: [Int: String]) -> [String: String] {
        var out: [String: String] = [:]
        namedRecords(d, extensions: ["PIC", "MAP", "AVI", "WAV", "MID", "ANI"], types: [1, 2, 3, 4, 5, 7], leafOnly: true) { name, p, _ in
            guard out[name] == nil, p + 4 < d.count else { return }
            if name.hasSuffix(".PIC") || name.hasSuffix(".MAP") { guard validOffsets[Int(d.le32(p))] == name else { return } }
            let c = d.cString(p + 4, max: 120).trimmingCharacters(in: .whitespaces)
            if !c.isEmpty { out[name] = c }
        }
        return out
    }

    /// C-Index files are a 1 KB file header followed by 4 KB B-tree nodes; each node's `u16` at +12 is
    /// its level (0 = leaf). Index nodes repeat leaf keys in the same `L, 01, chunk, u32 0, key\0` shape
    /// but follow them with a `u32` child node instead of data, so a scan must skip them.
    static let nodeBase = 0x400, nodeSize = 4096
    static func isLeafNode(_ d: Data, at i: Int) -> Bool {
        guard i >= nodeBase else { return false }
        let node = nodeBase + (i - nodeBase) / nodeSize * nodeSize
        return node + 14 <= d.count && d.le16(node + 12) == 0
    }

    /// MEDIA.CTG: gallery category → picture names.
    /// Records are `L, 01, chunk, u32 0, name\0, payload`; `chunk` bit 7 marks the last chunk and the low
    /// bits its index. Payloads concatenate to `u32 count` + `count × char[14]` names, and later chunks
    /// may split a name, so the stream is rebuilt before parsing. Only leaf nodes hold payloads.
    public static func categories(_ d: Data) -> [(name: String, pictures: [String])] {
        var chunks: [String: [Int: Data]] = [:], last: [String: Int] = [:], order: [String] = []
        var i = 1
        while i + 8 < d.count {
            defer { i += 1 }
            guard d.u8(i) == 1, d.le32(i + 2) == 0, isLeafNode(d, at: i) else { continue }
            let flag = Int(d.u8(i + 1)), L = Int(d.u8(i - 1))
            let name = d.cString(i + 6, max: 41)
            guard name.count >= 2, !name.hasPrefix("@"), name.allSatisfy({ $0.isASCII && ($0.isLetter || " ./'&-".contains($0)) }) else { continue }
            let payloadStart = i + 6 + name.utf8.count + 1, end = i - 1 + L + 1
            guard end > payloadStart, end <= d.count else { continue }
            let index = flag & 0x7F
            if chunks[name] == nil { order.append(name) }
            if chunks[name, default: [:]][index] == nil { chunks[name, default: [:]][index] = d.sub(payloadStart, end - payloadStart) }
            if flag & 0x80 != 0, last[name] == nil { last[name] = index }
        }
        var out: [(name: String, pictures: [String])] = []
        for name in order {
            guard let n = last[name], let parts = chunks[name], (0...n).allSatisfy({ parts[$0] != nil }) else { continue }
            let stream = (0...n).reduce(Data()) { $0 + parts[$1]! }
            guard stream.count >= 4 else { continue }
            let count = Int(stream.le32(0))
            guard count > 0, count < 2000, 4 + 14 * count <= stream.count else { continue }
            let pics = (0..<count).map { stream.cString(4 + 14 * $0, max: 14) }
            guard pics.allSatisfy({ $0.hasSuffix(".PIC") || $0.hasSuffix(".MAP") }) else { continue }
            out.append((name, pics))
        }
        return out
    }
}
