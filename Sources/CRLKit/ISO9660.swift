import Foundation

/// Minimal read-only ISO 9660 reader (primary volume descriptor, no Joliet/Rock Ridge —
/// the CRL disc is plain 8.3 ISO 9660). Lets the importer read the .iso without mounting it.
public final class ISO9660 {
    public struct Entry {
        public let name: String      // upper-case, version suffix (";1") stripped
        public let lba: Int
        public let size: Int
        public let isDirectory: Bool
    }

    private let handle: FileHandle
    private let blockSize = 2048
    private var root: Entry!

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let pvd = try read(lba: 16, count: blockSize)
        guard pvd.u8(0) == 1, pvd.sub(1, 5) == Data("CD001".utf8) else {
            throw CRLError.format("\(url.lastPathComponent) is not an ISO 9660 image")
        }
        root = Self.parseRecord(pvd, at: 156)!
    }

    deinit { try? handle.close() }

    func read(lba: Int, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(lba * blockSize))
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func parseRecord(_ d: Data, at o: Int) -> Entry? {
        let len = Int(d.u8(o))
        guard len > 0 else { return nil }
        let lba = Int(d.le32(o + 2)), size = Int(d.le32(o + 10))
        let flags = d.u8(o + 25), nameLen = Int(d.u8(o + 32))
        var name = String(data: d.sub(o + 33, nameLen), encoding: .ascii) ?? ""
        if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
        if name.hasSuffix(".") { name.removeLast() }
        return Entry(name: name.uppercased(), lba: lba, size: size, isDirectory: flags & 2 != 0)
    }

    public func list(_ dir: Entry) throws -> [Entry] {
        let d = try read(lba: dir.lba, count: dir.size)
        var out: [Entry] = [], o = 0
        while o < d.count {
            let len = Int(d.u8(o))
            if len == 0 { o = (o / blockSize + 1) * blockSize; continue }   // records never span sectors
            // Skip the "." and ".." records (single-byte names 0x00 / 0x01).
            if let e = Self.parseRecord(d, at: o), !(d.u8(o + 32) == 1 && d.u8(o + 33) <= 1) {
                out.append(e)
            }
            o += len
        }
        return out
    }

    /// Look up a path like "CRL/REFDATA/REN3F500.DAT" (case-insensitive).
    public func entry(_ path: String) throws -> Entry {
        var cur = root!
        for part in path.uppercased().split(separator: "/") {
            guard let next = try list(cur).first(where: { $0.name == part }) else {
                throw CRLError.missing(path)
            }
            cur = next
        }
        return cur
    }

    public func contents(_ path: String) throws -> Data {
        let e = try entry(path)
        return try read(lba: e.lba, count: e.size)
    }

    public func files(in path: String) throws -> [Entry] {
        try list(entry(path)).filter { !$0.isDirectory }
    }

    /// Read a byte range of a file without loading all of it (MEDIA.FIL is 184 MB).
    public func read(_ e: Entry, offset: Int, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(e.lba * blockSize + offset))
        return try handle.read(upToCount: min(count, e.size - offset)) ?? Data()
    }

    public func volumeLabel() throws -> String {
        let pvd = try read(lba: 16, count: blockSize)
        return String(data: pvd.sub(40, 32), encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
