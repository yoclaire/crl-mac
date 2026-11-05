import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Extracts RT_BITMAP resources from CRL32.EXE so the room artwork is read from the user's own
/// disc at import time (nothing from the disc is shipped with the app).
public enum PEResources {
    public struct Resource { public let type: Int; public let id: Int?; public let name: String?; public let data: Data }

    public static func resources(_ d: Data) throws -> [Resource] {
        let pe = Int(d.le32(0x3C))
        guard d.sub(pe, 4) == Data([0x50, 0x45, 0, 0]) else { throw CRLError.format("not a PE file") }
        let nsec = Int(d.le16(pe + 6)), optSize = Int(d.le16(pe + 20)), opt = pe + 24
        let rsrcRVA = Int(d.le32(opt + 96 + 2 * 8))        // data directory 2 = resources (PE32)
        var sections: [(va: Int, size: Int, raw: Int)] = []
        for i in 0..<nsec {
            let s = opt + optSize + 40 * i
            sections.append((Int(d.le32(s + 12)), max(Int(d.le32(s + 8)), Int(d.le32(s + 16))), Int(d.le32(s + 20))))
        }
        func off(_ rva: Int) -> Int? {
            sections.first { rva >= $0.va && rva < $0.va + $0.size }.map { rva - $0.va + $0.raw }
        }
        guard let root = off(rsrcRVA) else { throw CRLError.format("no resource section") }

        func entries(_ dir: Int) -> [(id: Int?, name: String?, target: Int, isDir: Bool)] {
            let n = Int(d.le16(dir + 12)) + Int(d.le16(dir + 14))
            return (0..<n).map { k in
                let e = dir + 16 + 8 * k
                let nameField = d.le32(e), target = d.le32(e + 4)
                var id: Int? = nil, name: String? = nil
                if nameField & 0x8000_0000 != 0 {
                    let p = root + Int(nameField & 0x7FFF_FFFF), len = Int(d.le16(p))
                    name = String(data: d.sub(p + 2, len * 2), encoding: .utf16LittleEndian)
                } else { id = Int(nameField) }
                return (id, name, root + Int(target & 0x7FFF_FFFF), target & 0x8000_0000 != 0)
            }
        }
        var out: [Resource] = []
        for t in entries(root) where t.isDir {
            for n in entries(t.target) where n.isDir {
                for l in entries(n.target) where !l.isDir {
                    guard let p = off(Int(d.le32(l.target))) else { continue }
                    out.append(Resource(type: t.id ?? -1, id: n.id, name: n.name, data: d.sub(p, Int(d.le32(l.target + 4)))))
                }
            }
        }
        return out
    }

    /// The images of an icon group (RT_GROUP_ICON → its RT_ICON entries) as PNGs keyed by pixel size.
    /// An icon DIB is a BITMAPINFOHEADER with doubled height, a palette, the colour bitmap and then a
    /// 1-bpp AND mask whose set bits are transparent. 1/4/8-bpp palette and 32-bpp images are read.
    public static func icons(_ res: [Resource], group: Int? = nil) -> [Int: Data] {
        guard let g = res.first(where: { $0.type == 14 && (group == nil || $0.id == group) })?.data, g.count >= 6 else { return [:] }
        var out: [Int: Data] = [:]
        for k in 0..<Int(g.le16(4)) where 6 + 14 * k + 14 <= g.count {
            let id = Int(g.le16(6 + 14 * k + 12))
            guard let dib = res.first(where: { $0.type == 3 && $0.id == id })?.data, let (w, px) = decodeIcon(dib) else { continue }
            out[w] = pngData(width: w, height: w, rgba: px)
        }
        return out
    }

    static func decodeIcon(_ d: Data) -> (Int, [UInt8])? {
        guard d.count >= 40 else { return nil }
        let hs = Int(d.le32(0)), w = Int(d.le32(4)), h = Int(d.le32(8)) / 2, bpp = Int(d.le16(14))
        guard w > 0, w <= 256, h == w, [1, 4, 8, 32].contains(bpp) else { return nil }
        var colors = Int(d.le32(32)); if colors == 0 && bpp <= 8 { colors = 1 << bpp }
        let pal = hs, xor = pal + 4 * colors, xorRow = (w * bpp + 31) / 32 * 4, andRow = (w + 31) / 32 * 4
        let and = xor + xorRow * h
        guard d.count >= and + andRow * h else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let src = h - 1 - y                                   // DIB rows run bottom-up
            for x in 0..<w {
                let o = (y * w + x) * 4, r = xor + src * xorRow
                if bpp == 32 {
                    let p = r + x * 4
                    px[o] = d[d.startIndex + p + 2]; px[o + 1] = d[d.startIndex + p + 1]; px[o + 2] = d[d.startIndex + p]; px[o + 3] = d[d.startIndex + p + 3]
                    continue
                }
                let bit = x * bpp, byte = Int(d[d.startIndex + r + bit / 8])
                let i = byte >> (8 - bpp - bit % 8) & (1 << bpp - 1), c = pal + 4 * i
                let masked = Int(d[d.startIndex + and + src * andRow + x / 8]) >> (7 - x % 8) & 1 == 1
                px[o] = d[d.startIndex + c + 2]; px[o + 1] = d[d.startIndex + c + 1]; px[o + 2] = d[d.startIndex + c]; px[o + 3] = masked ? 0 : 255
                if masked { px[o] = 0; px[o + 1] = 0; px[o + 2] = 0 }
            }
        }
        return (w, px)
    }

    /// PNG bytes for straight (unpremultiplied) RGBA pixels.
    public static func pngData(width w: Int, height h: Int, rgba: [UInt8]) -> Data {
        var px = rgba
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] < 255 {   // premultiply for CoreGraphics
            let a = Int(px[i + 3]); px[i] = UInt8(Int(px[i]) * a / 255); px[i + 1] = UInt8(Int(px[i + 1]) * a / 255); px[i + 2] = UInt8(Int(px[i + 2]) * a / 255)
        }
        let img = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let buf = NSMutableData()
        let dst = CGImageDestinationCreateWithData(buf, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
        return buf as Data
    }

    /// Turn an RT_BITMAP DIB into PNG bytes. Magenta (255,0,255) becomes transparent, as the
    /// original sprite blitter treats it; `key` names a different colour to drop instead.
    public static func png(fromDIB dib: Data, keyMagenta: Bool = true, key: (UInt8, UInt8, UInt8)? = nil) throws -> Data {
        let headerSize = Int(dib.le32(0)), bpp = Int(dib.le16(14))
        var colors = Int(dib.le32(32))
        if colors == 0 && bpp <= 8 { colors = 1 << bpp }
        let fileHeader: [UInt8] = { () -> [UInt8] in
            let size = 14 + dib.count, pixels = 14 + headerSize + 4 * colors
            func le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
            return [0x42, 0x4D] + le(size) + [0, 0, 0, 0] + le(pixels)
        }()
        let bmp = Data(fileHeader) + dib
        guard let src = CGImageSourceCreateWithData(bmp as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CRLError.format("undecodable bitmap") }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let k = key ?? (keyMagenta ? (255, 0, 255) : nil) {
            for i in stride(from: 0, to: px.count, by: 4) where px[i] == k.0 && px[i + 1] == k.1 && px[i + 2] == k.2 {
                px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
            }
        }
        let out = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let buf = NSMutableData()
        let dst = CGImageDestinationCreateWithData(buf, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, out, nil)
        CGImageDestinationFinalize(dst)
        return buf as Data
    }
}
