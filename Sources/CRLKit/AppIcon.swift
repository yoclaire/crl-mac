import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The app icon, made at build time from CRL32.EXE's own 32×32 icon (four books), which the library
/// import saves as ui/icon-32.png. macOS puts icons that aren't a full rounded square on a grey tile,
/// so the books stand on a wood-panel tile like the reading room's, scaled up pixel for pixel.
public enum AppIcon {
    /// Writes every size of a macOS .iconset (for `iconutil -c icns`) from the original icon.
    public static func writeIconset(icon: URL, to dir: URL) throws {
        guard let src = CGImageSourceCreateWithURL(icon as CFURL, nil),
              let art = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CRLError.format("unreadable icon \(icon.path)") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png(render(art, size: points * scale)).write(to: dir.appendingPathComponent(name))
            }
        }
    }

    /// One icon image `size` pixels square, on Apple's grid: an 824/1024 tile with a drop shadow.
    static func render(_ art: CGImage, size n: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let u = CGFloat(n) / 1024
        let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
        func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
        }

        // Tile: dark wood, lighter towards the top, with a shadow under it.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 24 * u, color: rgb(0, 0.35))
        ctx.addPath(shape); ctx.setFillColor(rgb(0x4A2A16)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        let wood = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x9A6638), rgb(0x6B4022), rgb(0x45250F)] as CFArray,
                              locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(wood, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        // Faint vertical grain.
        for i in 0..<14 {
            let x = tile.minX + tile.width * (CGFloat(i) + 0.5) / 14 + CGFloat((i * 37) % 11 - 5) * u
            ctx.setFillColor(rgb(0x2A1608, i % 2 == 0 ? 0.10 : 0.06))
            ctx.fill(CGRect(x: x, y: tile.minY, width: (3 + CGFloat(i % 3) * 2) * u, height: tile.height))
        }

        // The books: the 32×32 art at a whole-pixel scale (rows 2–28 hold the books), standing on a shelf.
        // Below 64 pixels a whole pixel is too big, so the art is scaled down smoothly instead.
        let fit = tile.width * 0.78 / 32, px = fit >= 1 ? fit.rounded(.down) : fit
        let artRect = CGRect(x: (CGFloat(n) - 32 * px) / 2, y: tile.minY + tile.height * 0.25 - 3 * px, width: 32 * px, height: 32 * px)
        let shelfTop = artRect.minY + 3 * px                                 // under the books' bottom row
        ctx.setFillColor(rgb(0x2E1A0B)); ctx.fill(CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: shelfTop - tile.minY))
        ctx.setFillColor(rgb(0xB98352)); ctx.fill(CGRect(x: tile.minX, y: shelfTop - max(1, 10 * u), width: tile.width, height: max(1, 10 * u)))
        ctx.setFillColor(rgb(0x1E1006)); ctx.fill(CGRect(x: tile.minX, y: shelfTop - max(1, 22 * u), width: tile.width, height: max(1, 6 * u)))
        ctx.interpolationQuality = fit >= 1 ? .none : .high
        ctx.draw(art, in: artRect)
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    static func png(_ img: CGImage) -> Data {
        let buf = NSMutableData()
        let dst = CGImageDestinationCreateWithData(buf, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
        return buf as Data
    }
}
