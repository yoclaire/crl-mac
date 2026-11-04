import Foundation

/// Reader for InfoSoft "RE" reference databases (`REFDATA/REN*.DAT`).
/// Format recovered from REWIN32.DLL; see docs/FORMATS.md ("Reference databases").
public final class REDB {
    public let entryCount: Int          // entries are numbered 1...entryCount
    let data: Data
    let codeBase: Int
    let width: Int
    let shift: Int
    let checkpoints: Data
    let left: [Int16]
    let right: [Int16]
    let pool: Data
    let terminalCount: Int
    let endCode: Int

    public init(data: Data) throws {
        self.data = data
        let fileCount = Int(data.be16(0x316)), dirOffset = Int(data.be32(0x318))
        var entryFile: (header: Int, base: Int)?
        for i in 0..<fileCount where data.be16(dirOffset + 12 * i) == 1 {
            entryFile = (Int(data.be32(dirOffset + 12 * i + 4)), Int(data.be32(dirOffset + 12 * i + 8)))
        }
        guard let (hdr, base) = entryFile else { throw CRLError.format("no entry file in RE database") }
        codeBase = base
        entryCount = Int(data.be32(hdr + 0x68))
        width = Int(data.be16(hdr + 0x76))
        shift = Int(data.be16(hdr + 0x72)).trailingZeroBitCount

        var sections: [Int: (count: Int, bytes: Data)] = [:]
        let sectionCount = Int(data.be16(hdr + 0x50)), sectionDir = hdr + Int(data.be32(hdr + 0x52))
        for i in 0..<sectionCount {
            let r = sectionDir + 16 * i
            let id = Int(data.be16(r)), off = Int(data.be32(r + 2)), cnt = Int(data.be16(r + 10)), size = Int(data.be32(r + 12))
            if size > 0 { sections[id] = (cnt, data.sub(hdr + off, size)) }
        }
        guard let ck = sections[10], let l = sections[0x14], let r = sections[0x1e] else {
            throw CRLError.format("RE database missing grammar sections")
        }
        checkpoints = ck.bytes
        func shorts(_ d: Data) -> [Int16] { (0..<d.count / 2).map { Int16(bitPattern: d.le16($0 * 2)) } }
        left = shorts(l.bytes)
        right = shorts(r.bytes)
        pool = sections[0x3c]?.bytes ?? Data()
        if pool.isEmpty {
            terminalCount = 0
            endCode = l.count - 1
        } else {
            let nterm = (1 << width) - Int(left[0])
            var end: Int?
            for c in 0..<nterm where right[c] == 4 {
                let o = Int(UInt16(bitPattern: left[c]))
                if o + 4 <= pool.count, pool.sub(o, 4).allSatisfy({ $0 == 0xFE }) { end = c; break }
            }
            guard let end else { throw CRLError.format("RE database has no end code") }
            terminalCount = nterm
            endCode = end
        }
    }

    /// Iterates fixed-width codes, MSB-first in big-endian 16-bit words (FUN_10027b85).
    struct Codes: IteratorProtocol {
        let data: Data, base: Int, width: Int, mask: UInt32
        var bit: Int
        mutating func next() -> Int? {
            let byte = base + (bit >> 4) * 2, sh = bit & 15
            guard byte + 3 < data.count else { return nil }
            let word = data.be32(byte)
            bit += width
            return Int((word >> UInt32(32 - sh - width)) & mask)
        }
    }

    func codes(from index: Int) -> Codes {
        Codes(data: data, base: codeBase, width: width, mask: (1 << UInt32(width)) - 1, bit: index * width)
    }

    /// Expand one code through the pair grammar (FUN_100127e0).
    @inline(__always) func expand(_ code: Int, into out: inout [UInt8], stack: inout [Int]) {
        stack.removeAll(keepingCapacity: true)
        stack.append(code)
        while let c = stack.popLast() {
            let r = right[c]
            if c < terminalCount || r == -1 {
                if r == -1 {
                    out.append(UInt8(truncatingIfNeeded: left[c]))
                } else {
                    let o = Int(UInt16(bitPattern: left[c]))
                    out.append(contentsOf: pool[(pool.startIndex + o)..<(pool.startIndex + o + Int(r))])
                }
            } else {
                stack.append(Int(r))
                stack.append(Int(left[c]))
            }
        }
    }

    /// Raw markup bytes of entry `n` (1-based). 0xFF bytes become newlines.
    public func entry(_ n: Int) -> [UInt8] {
        let k = n >> shift
        let start = Int(checkpoints.le32(k * 4))
        var skip = (n & ((1 << shift) - 1)) + (k > 0 ? 1 : 0)
        var it = codes(from: start)
        while skip > 0, let c = it.next() { if c == endCode { skip -= 1 } }
        var out: [UInt8] = [], stack: [Int] = []
        while let c = it.next(), c != endCode { expand(c, into: &out, stack: &stack) }
        return out.map { $0 == 0xFF ? 0x0A : $0 }
    }

    /// Decode every entry in one sequential pass (much faster than random access).
    public func allEntries(_ body: (Int, [UInt8]) throws -> Void) rethrows {
        var it = codes(from: 0), out: [UInt8] = [], stack: [Int] = [], n = 0
        while n <= entryCount, let c = it.next() {
            if c == endCode {
                if n > 0 { try body(n, out.map { $0 == 0xFF ? 0x0A : $0 }) }
                out.removeAll(keepingCapacity: true)
                n += 1
            } else {
                expand(c, into: &out, stack: &stack)
            }
        }
    }
}

/// The ten titles on the disc, with the media-catalogue db codes recovered from MEDIA.LNK.
// MARK: - Table of Contents

extension REDB {
    /// One line of a book's Table of Contents outline: pre-order, nesting given by `level` alone
    /// (0 = the book itself). The node covers articles `first...last`.
    public struct TOCNode: Sendable, Hashable { public let title: String; public let level: Int; public let first: Int; public let last: Int }

    /// Sub-file directory `(type, header offset)` and a sub-file's section directory
    /// `{u16 id, u32 offset (rel. header), u32 record size, u16 count, u32 size}`, all big-endian.
    func subfileHeaders() -> [(type: Int, header: Int)] {
        let n = Int(data.be16(0x316)), dir = Int(data.be32(0x318))
        return (0..<n).map { (Int(data.be16(dir + 12 * $0)), Int(data.be32(dir + 12 * $0 + 4))) }
    }
    func sectionTable(_ hdr: Int) -> [Int: (offset: Int, recordSize: Int, count: Int, size: Int)] {
        var out: [Int: (offset: Int, recordSize: Int, count: Int, size: Int)] = [:]
        let n = Int(data.be16(hdr + 0x50)), dir = hdr + Int(data.be32(hdr + 0x52))
        for i in 0..<n {
            let r = dir + 16 * i
            out[Int(data.be16(r))] = (hdr + Int(data.be32(r + 2)), Int(data.be32(r + 6)), Int(data.be16(r + 10)), Int(data.be32(r + 12)))
        }
        return out
    }

    /// The outline CRL32 shows under "Display Table of Contents" (recovered from REWIN32.DLL
    /// `FUN_1001aae2` and `_REstrtab@12`, and CRL32 `FUN_00403e61`). Nodes: section 0x28 of the entry
    /// sub-file, 16-byte records `{u16 title id, u16 level, u16 inTOC, u32 first, u32 last, u16 next}`.
    /// Titles: string table 3 in the sub-file holding sections 0x122 (sorted 8-byte index
    /// `{u16 table, u16 index, u16 offset, u16}`) and 0x12c (NUL-terminated cp1252 pool). Empty when the
    /// book has no outline. CRL32 hides a few reference appendices by title prefix; so does this.
    public func tableOfContents(isDictionary: Bool = false) -> [TOCNode] {
        let files = subfileHeaders()
        guard let entryHeader = files.first(where: { $0.type == 1 })?.header,
              let nodes = sectionTable(entryHeader)[0x28], nodes.recordSize == 16, nodes.count > 0,
              nodes.offset + 16 * nodes.count <= data.count else { return [] }
        var titles: [Int: String] = [:]
        for f in files where f.type != 1 {
            let s = sectionTable(f.header)
            guard let index = s[0x122], let pool = s[0x12c], pool.offset + pool.size <= data.count else { continue }
            for k in 0..<index.count {
                let r = index.offset + 8 * k
                guard Int(data.be16(r)) == 3 else { continue }
                let o = Int(data.be16(r + 4))
                guard o < pool.size else { continue }
                var e = pool.offset + o
                while e < pool.offset + pool.size, data.u8(e) != 0 { e += 1 }
                titles[Int(data.be16(r + 2))] = String(data: data.sub(pool.offset + o, e - pool.offset - o), encoding: .windowsCP1252)
            }
            break
        }
        let hidden = ["ad-", "od-", "Two Year", "Four Year"] + (isDictionary ? ["Indo-"] : [])
        var out: [TOCNode] = []
        for k in 0..<nodes.count {
            let r = nodes.offset + 16 * k
            guard data.be16(r + 4) != 0, let title = titles[Int(data.be16(r))],
                  !hidden.contains(where: { title.hasPrefix($0) }) else { continue }
            out.append(TOCNode(title: title, level: Int(data.be16(r + 2)), first: Int(data.be32(r + 6)), last: Int(data.be32(r + 10))))
        }
        return out
    }
}

public struct Book: Sendable, Hashable, Identifiable {
    public let id: String          // stable key used in the library database
    public let file: String
    public let title: String
    public let spine: String       // room object name in spec/room.json
    public let mediaCode: Int?     // CRL32 book code (table at 0x49b0d8), used by MEDIA.LNK / MEDIA.DBS

    public static let all: [Book] = [
        Book(id: "dictionary", file: "REN3F500.DAT", title: "American Heritage Dictionary", spine: "dictionary", mediaCode: 0),
        Book(id: "encyclopedia", file: "RENEF420.DAT", title: "Concise Columbia Encyclopedia", spine: "encyclopedia", mediaCode: 4),
        Book(id: "almanac", file: "RENAP421.DAT", title: "Information Please Almanac", spine: "almanac", mediaCode: 2),
        Book(id: "thesaurus", file: "RENTF330.DAT", title: "Roget's II Thesaurus", spine: "thesaurus", mediaCode: 1),
        Book(id: "directory", file: "RENND401.DAT", title: "National Directory", spine: "directory", mediaCode: 8),
        Book(id: "legal", file: "RENLW442.DAT", title: "The Legal Word Book", spine: "legal", mediaCode: 9),
        Book(id: "wallstreet", file: "RENWS411.DAT", title: "Wall Street Words", spine: "wallstreet", mediaCode: 6),
        Book(id: "history", file: "RENRC420.DAT", title: "Reader's Companion to American History", spine: "history", mediaCode: 7),
        Book(id: "style", file: "RENWW421.DAT", title: "The Written Word III", spine: "style", mediaCode: 5),
        Book(id: "quotes", file: "RENQF410.DAT", title: "Simpson's Contemporary Quotations", spine: "quotes", mediaCode: 3),
    ]
}
