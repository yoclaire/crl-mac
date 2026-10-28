import Foundation

/// Bounds-checked little/big-endian readers over `Data`.
/// The disc formats mix both byte orders (InfoSoft headers are big-endian, everything else little).
extension Data {
    @inline(__always) func u8(_ o: Int) -> UInt8 { self[startIndex + o] }

    @inline(__always) func le16(_ o: Int) -> UInt16 {
        UInt16(u8(o)) | UInt16(u8(o + 1)) << 8
    }
    @inline(__always) func le32(_ o: Int) -> UInt32 {
        UInt32(u8(o)) | UInt32(u8(o + 1)) << 8 | UInt32(u8(o + 2)) << 16 | UInt32(u8(o + 3)) << 24
    }
    @inline(__always) func be16(_ o: Int) -> UInt16 {
        UInt16(u8(o)) << 8 | UInt16(u8(o + 1))
    }
    @inline(__always) func be32(_ o: Int) -> UInt32 {
        UInt32(u8(o)) << 24 | UInt32(u8(o + 1)) << 16 | UInt32(u8(o + 2)) << 8 | UInt32(u8(o + 3))
    }
    func sub(_ o: Int, _ n: Int) -> Data { self[(startIndex + o)..<(startIndex + o + n)] }

    /// NUL-terminated string starting at `o`, at most `max` bytes, decoded as Windows-1252.
    func cString(_ o: Int, max: Int) -> String {
        var end = o
        while end < o + max, end < count, u8(end) != 0 { end += 1 }
        return String(data: sub(o, end - o), encoding: .windowsCP1252) ?? ""
    }
}

public enum CRLError: Error, CustomStringConvertible {
    case format(String)
    case missing(String)

    public var description: String {
        switch self {
        case .format(let s): return "format error: \(s)"
        case .missing(let s): return "missing: \(s)"
        }
    }
}
