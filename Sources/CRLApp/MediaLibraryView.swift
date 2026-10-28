import AppKit
import CRLKit
import SwiftUI

/// The Media Library screen (bitmap 308): six media types down the left, Categories and Items
/// lists, a viewer, and the Prior / Next / Play / Play All / Related Articles / Done controls.
struct MediaLibraryView: View {
    @EnvironmentObject var model: AppModel
    let s: CGFloat
    var type: String { model.mediaType }
    var item: Library.MediaRef? { model.mediaItem }

    // Icon positions located on bitmap 308 by template matching.
    // (normal sprite as it sits on bitmap 308, selected-state sprite)
    static let types: [(kind: String, sprite: Int, selected: Int, rect: CGRect)] = [
        ("map", 444, 443, CGRect(x: 46, y: 64, width: 61, height: 59)),
        ("video", 445, 446, CGRect(x: 10, y: 147, width: 61, height: 49)),
        ("picture", 447, 448, CGRect(x: 53, y: 215, width: 57, height: 48)),
        ("animation", 449, 450, CGRect(x: 10, y: 288, width: 75, height: 40)),
        ("sound", 451, 452, CGRect(x: 63, y: 349, width: 44, height: 58)),
        ("music", 453, 454, CGRect(x: 10, y: 409, width: 78, height: 39)),
    ]
    static let categoriesRect = CGRect(x: 128, y: 44, width: 168, height: 150)
    static let itemsRect = CGRect(x: 304, y: 44, width: 228, height: 150)
    static let viewer = CGRect(x: 128, y: 202, width: 404, height: 238)


    var body: some View {
        ZStack(alignment: .topLeading) {
            PixelImage(image: Art.image(308)).frame(width: 640 * s, height: 480 * s)
            ForEach(Self.types, id: \.kind) { t in
                Button { model.selectMediaType(t.kind) } label: {
                    PixelImage(image: Art.image(t.kind == type ? t.selected : t.sprite))
                }.buttonStyle(.plain).place(t.rect, s)
            }
            let categories = model.mediaCategories
            PanelFrame(s: s) {
                SubjectTable(rows: categories.enumerated().map { .init(title: $1, icon: iconRow(media: type), tag: $0, column: 2) },
                             selected: categories.firstIndex(of: model.mediaCategory ?? ""), scale: s) { model.selectMediaCategory(categories[$0]) }
            }.place(Self.categoriesRect, s)
            let list = model.mediaItems
            PanelFrame(s: s) {
                SubjectTable(rows: list.enumerated().map { .init(title: $1.caption ?? $1.name, icon: iconRow(media: $1.kind), tag: $0) },
                             selected: item.flatMap { list.firstIndex(of: $0) }, scale: s) { select(list[$0]) }
            }.place(Self.itemsRect, s)
            viewer.place(Self.viewer, s)
            controls(list)
        }
        .frame(width: 640 * s, height: 480 * s)
        .onAppear { if model.mediaCategories.isEmpty { model.selectMediaType(model.mediaType) } }
    }

    @ViewBuilder var viewer: some View {
        ZStack {
            Color(nsColor: Palette.panel)
            if let item, let path = item.path, let lib = model.library {
                if ["video", "animation"].contains(item.kind) {
                    VideoView(url: lib.url(path))
                } else if ["picture", "map"].contains(item.kind), let img = NSImage(contentsOf: lib.url(path)) {
                    VStack(spacing: 2 * s) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        Text(item.caption ?? "").font(.custom("Times New Roman", size: 12 * s)).foregroundStyle(.black)
                    }.padding(4 * s)
                } else {
                    Text(item.caption ?? item.name).font(.custom("Times New Roman", size: 14 * s)).foregroundStyle(.black)
                }
            }
        }
        .overlay(Rectangle().stroke(Color(nsColor: Palette.frame), lineWidth: max(1, s)))
    }

    func select(_ m: Library.MediaRef) { model.selectMediaItem(m) }

    func controls(_ list: [Library.MediaRef]) -> some View {
        let idx = item.flatMap { list.firstIndex(of: $0) } ?? -1
        return Group {
            Button { if idx > 0 { select(list[idx - 1]) } } label: { PixelImage(image: Art.image(455)) }
                .buttonStyle(.plain).place(CGRect(x: 228, y: 451, width: 29, height: 29), s)
            Button { if idx + 1 < list.count { select(list[idx + 1]) } } label: { PixelImage(image: Art.image(457)) }
                .buttonStyle(.plain).place(CGRect(x: 272, y: 451, width: 29, height: 29), s)
            Button { if let item { select(item) } else if let f = list.first { select(f) } } label: { PixelImage(image: Art.image(459)) }
                .buttonStyle(.plain).place(CGRect(x: 345, y: 451, width: 63, height: 29), s)
            Button { playAll(list) } label: { PixelImage(image: Art.image(461)) }
                .buttonStyle(.plain).place(CGRect(x: 422, y: 450, width: 75, height: 30), s)
            Button { related() } label: { PixelImage(image: Art.image(465)) }
                .buttonStyle(.plain).place(CGRect(x: 551, y: 449, width: 32, height: 31), s)
            Button { model.player.stop(); model.screen = .room } label: { PixelImage(image: Art.image(463)) }
                .buttonStyle(.plain).place(CGRect(x: 597, y: 451, width: 36, height: 29), s)
        }
    }

    func playAll(_ list: [Library.MediaRef]) {
        guard !list.isEmpty else { return }
        Task { @MainActor in
            for m in list {
                guard model.screen == .mediaLibrary else { break }
                select(m)
                try? await Task.sleep(for: .seconds(m.kind == "picture" || m.kind == "map" ? 4 : 8))
            }
        }
    }

    /// Jump to the first article that links this media item.
    func related() {
        guard let item, let hit = (try? model.library?.articles(linking: item.name))?.first else { NSSound.beep(); return }
        model.player.stop()
        model.screen = .room
        model.panel = .subjects
        model.show(hit)
    }
}
