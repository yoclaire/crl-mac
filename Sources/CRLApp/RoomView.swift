import AppKit
import AVKit
import CRLKit
import SwiftUI

/// Places a view at a rectangle given in original 640×480 pixels.
struct Place: ViewModifier {
    let rect: CGRect, s: CGFloat
    func body(content: Content) -> some View {
        content.frame(width: rect.width * s, height: rect.height * s)
            .position(x: rect.midX * s, y: rect.midY * s)
    }
}
extension View {
    func place(_ r: CGRect, _ s: CGFloat) -> some View { modifier(Place(rect: r, s: s)) }
}

struct PixelImage: View {
    let image: NSImage?
    var body: some View {
        if let image { Image(nsImage: image).resizable().interpolation(.none) } else { Color.clear }
    }
}

struct RoomView: View {
    @EnvironmentObject var model: AppModel
    let s: CGFloat
    private let spec = RoomSpec.shared

    var dim: Bool { !model.windowActive }

    var body: some View {
        ZStack(alignment: .topLeading) {
            PixelImage(image: Art.image(dim ? spec.background.dim : spec.background.lit))
                .frame(width: 640 * s, height: 480 * s)
            ForEach(spec.objects) { o in sprite(o) }
            panels
            if let tip = model.hover.flatMap({ spec.object($0) }), !tip.tip.isEmpty, model.screen == .room {
                PassOverHelp(text: tip.tip, s: s).position(x: tipPosition(tip).x * s, y: tipPosition(tip).y * s)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 640 * s, height: 480 * s)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let p) = phase { model.hover = object(at: p)?.name } else { model.hover = nil }
        }
        .onTapGesture(coordinateSpace: .local) { p in
            if let o = object(at: p) { model.sound("refclose.wav"); model.activate(o.name) }
        }
    }

    func object(at p: CGPoint) -> RoomSpec.Object? {
        let q = CGPoint(x: p.x / s, y: p.y / s)
        if model.panel != .none, Layout.subjectList.insetBy(dx: -2, dy: -2).contains(q) || Layout.article.contains(q) || Layout.combo.contains(q) {
            return nil
        }
        return spec.objects.first { $0.hitRect.contains(q) }
    }

    func tipPosition(_ o: RoomSpec.Object) -> CGPoint {
        let r = o.hitRect
        let y = r.minY > 300 ? r.minY - 10 : r.maxY + 10
        return CGPoint(x: min(max(r.midX, 70), 570), y: y)
    }

    @ViewBuilder func sprite(_ o: RoomSpec.Object) -> some View {
        let hovered = model.hover == o.name
        let enabled = model.isEnabled(o.name)
        let prefix = dim ? "dim" : "lit"
        let key: String = !enabled ? "\(prefix)Disabled" : hovered ? "\(prefix)Hover" : (o.name == "media" && model.screen == .mediaLibrary ? "active" : prefix)
        if let r = o.drawRect, let id = o.variants[key] ?? (hovered ? nil : o.variants[prefix]) {
            PixelImage(image: Art.image(id)).place(r, s).allowsHitTesting(false)
        }
    }

    @ViewBuilder var panels: some View {
        switch model.panel {
        case .none: EmptyView()
        case .subjects: SubjectListPanel(s: s).place(Layout.subjectList, s)
        case .index: IndexPanel(s: s).place(Layout.subjectList, s)
        case .contents: ContentsPanel(s: s).place(Layout.subjectList, s)
        case .trails: TrailsPanel(s: s).place(Layout.subjectList, s)
        case .help: HelpPanel(s: s).place(Layout.subjectList, s)
        }
        if model.panel != .none || model.article != nil {
            ArticlePane(s: s).place(Layout.article, s)
            MediaCombo(s: s).place(Layout.combo, s)
        }
    }
}

/// Yellow tooltip, as drawn by CRL32's "Pass-Over Help".
struct PassOverHelp: View {
    let text: String, s: CGFloat
    var body: some View {
        Text(text).font(.custom("Arial", size: 10 * s)).foregroundStyle(.black)
            .padding(.horizontal, 3 * s).padding(.vertical, 1 * s)
            .background(Color(red: 1, green: 1, blue: 0.75)).border(Color.black, width: max(1, s / 2))
            .fixedSize()
    }
}

// MARK: - Panel chrome

/// The beveled tan header used on the Subject List and article pane.
struct PanelHeader: View {
    let title: String, s: CGFloat
    var dark = false
    var trailing: (() -> Void)?
    var body: some View {
        HStack(spacing: 0) {
            Text(title).font(.custom("Times New Roman", size: 13 * s)).foregroundStyle(dark ? .white : .black)
                .lineLimit(1).frame(maxWidth: .infinity)
            if let trailing {
                Button(action: trailing) {
                    PixelImage(image: Art.image("MAXU")).frame(width: 16 * s, height: 16 * s)
                }.buttonStyle(.plain)
            }
        }
        .frame(height: 18 * s)
        .background(Color(nsColor: dark ? Palette.titleBar : Palette.header))
        .overlay(Rectangle().stroke(Color(nsColor: Palette.frame), lineWidth: max(1, s / 2)))
    }
}

struct PanelFrame<Content: View>: View {
    let s: CGFloat
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Rectangle().fill(Color(nsColor: Palette.list))
                .shadow(color: .black.opacity(0.45), radius: 0, x: 2 * s, y: 2 * s))
            .overlay(Rectangle().stroke(Color(nsColor: Palette.frame), lineWidth: max(1, s)))
    }
}

// MARK: - Subject List

struct SubjectListPanel: View {
    @EnvironmentObject var model: AppModel
    let s: CGFloat
    var body: some View {
        PanelFrame(s: s) {
            PanelHeader(title: "Subject List", s: s, trailing: { model.panel = .contents })
            SubjectTable(rows: model.subjects.map { .init(title: $0.title, icon: iconRow(model.book), tag: $0.num) },
                         selected: model.selection?.num, scale: s) { num in
                if let sub = model.subjects.first(where: { $0.num == num }) { model.show(sub) }
            }
        }
    }
}

/// Row in the IDB_MAINLIST icon strip (D T A Q E S W H N L, then the media types).
func iconRow(_ book: Book?) -> Int {
    guard let book else { return 0 }
    let order = ["dictionary", "thesaurus", "almanac", "quotes", "encyclopedia", "style", "wallstreet", "history", "directory", "legal"]
    return order.firstIndex(of: book.id) ?? 0
}

func iconRow(media kind: String) -> Int {
    ["map": 10, "video": 11, "sound": 12, "music": 13, "picture": 14, "animation": 15, "help": 11][kind] ?? 16
}

// MARK: - Article pane

struct ArticlePane: View {
    @EnvironmentObject var model: AppModel
    let s: CGFloat
    var body: some View {
        PanelFrame(s: s) {
            PanelHeader(title: model.overlay.map { $0.caption ?? $0.label ?? $0.name } ?? model.article?.title ?? model.helpTopic?.title ?? "",
                        s: s, dark: true)
            ZStack {
                if let h = model.helpTopic, model.article == nil {
                    ArticleTextView(text: ArticleRenderer.renderHelp(h.body, scale: s), scale: s, highlights: []) { model.follow($0) }
                } else if let a = model.article, let book = Book.all.first(where: { $0.id == a.book }) {
                    ArticleTextView(text: ArticleRenderer(book: book, scale: s).render(a), scale: s,
                                    highlights: model.highlights["\(a.book)/\(a.num)"] ?? []) { model.follow($0) }
                } else {
                    Color(nsColor: Palette.panel)
                }
                if let m = model.overlay { MediaOverlay(media: m, s: s) }
            }
        }
    }
}

/// Picture / map / video shown in place of the article text, with Prior / Next when there are several.
struct MediaOverlay: View {
    @EnvironmentObject var model: AppModel
    let media: Library.MediaRef, s: CGFloat
    var body: some View {
        ZStack(alignment: .bottom) {
            Color(nsColor: Palette.panel)
            if let path = media.path, let lib = model.library {
                if ["video", "animation", "help"].contains(media.kind) {
                    VideoView(url: lib.url(path)).padding(6 * s)
                } else if let img = NSImage(contentsOf: lib.url(path)) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(6 * s)
                }
            }
            HStack(spacing: 8 * s) {
                if model.overlayItems.count > 1 {
                    Button { model.step(-1) } label: { PixelImage(image: Art.image(455)).frame(width: 22 * s, height: 22 * s) }
                    Button { model.step(1) } label: { PixelImage(image: Art.image(457)).frame(width: 22 * s, height: 22 * s) }
                }
                Spacer()
                Button { model.overlay = nil } label: { PixelImage(image: Art.image(463)).frame(width: 30 * s, height: 24 * s) }
            }.buttonStyle(.plain).padding(4 * s)
        }
    }
}

struct VideoView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .minimal
        v.player = AVPlayer(url: url)
        v.player?.play()
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if (v.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            v.player = AVPlayer(url: url); v.player?.play()
        }
    }
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause() }
}

/// The combo box under the article: lists the media attached to the current article.
struct MediaCombo: View {
    @EnvironmentObject var model: AppModel
    let s: CGFloat
    var body: some View {
        let items = model.article?.media.filter { $0.path != nil } ?? []
        Menu {
            ForEach(items, id: \.self) { m in
                Button("\(label(m.kind)): \(m.caption ?? m.label ?? m.name)") { model.present([m]) }
            }
        } label: {
            HStack {
                Text(items.isEmpty ? "" : "\(items.count) media item\(items.count == 1 ? "" : "s")")
                    .font(.custom("Times New Roman", size: 12 * s)).foregroundStyle(.black)
                Spacer()
                PixelImage(image: Art.image("COMBO_U")).frame(width: 17 * s, height: 19 * s)
            }
            .padding(.leading, 4 * s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: Palette.panel))
            .overlay(Rectangle().stroke(Color(nsColor: Palette.frame), lineWidth: max(1, s / 2)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(items.isEmpty)
    }
    func label(_ kind: String) -> String {
        ["picture": "Picture", "map": "Map", "sound": "Pronunciation", "video": "Video", "animation": "Animation", "music": "Music"][kind] ?? kind
    }
}

// MARK: - Index (search)

struct IndexPanel: View {
    @EnvironmentObject var model: AppModel
    let s: CGFloat
    @FocusState private var focused: Bool
    var body: some View {
        PanelFrame(s: s) {
            PanelHeader(title: "Index", s: s, trailing: { model.panel = .subjects })
            TextField("", text: $model.query)
                .textFieldStyle(.plain).font(.custom("Times New Roman", size: 13 * s))
                .padding(.horizontal, 3 * s).frame(height: 18 * s)
                .background(Color.white).overlay(Rectangle().stroke(Color(nsColor: Palette.frame), lineWidth: max(1, s / 2)))
                .padding(3 * s)
                .focused($focused)
                .onChange(of: model.query) { model.search() }
                .onSubmit { if let h = model.hits.first { model.show(h) } }
            HStack(spacing: 4 * s) {
                toggle("Quick Subject", !model.fullText) { model.fullText = false; model.search() }
                toggle("Full Text", model.fullText) { model.fullText = true; model.search() }
            }.padding(.horizontal, 3 * s).padding(.bottom, 3 * s)
            SubjectTable(rows: model.hits.enumerated().map { i, h in
                .init(title: h.title, icon: iconRow(Book.all.first { $0.id == h.book }), tag: i, column: 3)
            }, selected: nil, scale: s) { i in model.show(model.hits[i]) }
        }
        .onAppear { focused = true }
    }
    func toggle(_ t: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.custom("Arial", size: 9.5 * s)).foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 15 * s)
                .background(Color(nsColor: on ? Palette.selection : Palette.header))
                .overlay(Rectangle().stroke(Color(nsColor: Palette.frame), lineWidth: max(1, s / 2)))
        }.buttonStyle(.plain)
    }
}

// MARK: - Table of Contents, Trails, Help

struct ContentsPanel: View {
    @EnvironmentObject var model: AppModel
    let s: CGFloat
    var body: some View {
        PanelFrame(s: s) {
            if let book = model.tocBook {
                let nodes = model.library?.tableOfContents(book: book.id) ?? []
                let rows = Self.visible(nodes, expanded: model.tocExpanded)
                PanelHeader(title: "Table of Contents", s: s, trailing: { model.tocBook = nil })
                SubjectTable(rows: rows.map { i in
                    let n = nodes[i], parent = i + 1 < nodes.count && nodes[i + 1].level > n.level
                    let mark = parent ? (model.tocExpanded.contains(i) ? "▾ " : "▸ ") : "   "
                    return .init(title: String(repeating: "    ", count: n.level) + mark + n.title, icon: iconRow(book), tag: i)
                }, selected: nil, scale: s) { model.chooseTOC($0) }
            } else {
                // CRL32 offers an outline for these four books only (flag table DAT_0049b108); the Legal
                // Word Book also carries one on the disc, but the original never showed it.
                let offered: Set = ["dictionary", "almanac", "quotes", "style"]
                let books = Book.all.filter { offered.contains($0.id) && !(model.library?.tableOfContents(book: $0.id).isEmpty ?? true) }
                PanelHeader(title: "Table of Contents", s: s)
                SubjectTable(rows: books.enumerated().map { .init(title: $1.title, icon: iconRow($1), tag: $0, column: 2) }, selected: nil, scale: s) {
                    model.openTOC(books[$0])
                }
            }
        }
    }

    /// Indices of the nodes to list: a node is shown when every ancestor is expanded.
    static func visible(_ nodes: [REDB.TOCNode], expanded: Set<Int>) -> [Int] {
        var out: [Int] = [], collapsedBelow: Int?
        for (i, n) in nodes.enumerated() {
            if let c = collapsedBelow { if n.level > c { continue } else { collapsedBelow = nil } }
            out.append(i)
            let parent = i + 1 < nodes.count && nodes[i + 1].level > n.level
            if parent, !expanded.contains(i) { collapsedBelow = n.level }
        }
        return out
    }
}

struct TrailsPanel: View {
    @EnvironmentObject var model: AppModel
    let s: CGFloat
    var body: some View {
        let items = model.bookmarks.map { ("★ " + $0.title, $0) } + model.trail.map { ($0.title, $0) }
        PanelFrame(s: s) {
            PanelHeader(title: "Reference Trails", s: s, trailing: { model.panel = .subjects })
            SubjectTable(rows: items.enumerated().map { i, it in .init(title: it.0, icon: iconRow(Book.all.first { $0.id == it.1.book }), tag: i) },
                         selected: nil, scale: s) { model.show(items[$0].1) }
        }
    }
}

struct HelpPanel: View {
    @EnvironmentObject var model: AppModel
    let s: CGFloat
    var body: some View {
        let clips = (try? model.library?.media(kind: "help")) ?? []
        // Contents first (where WinHelp opens), then the other text topics, then the video help.
        let all = (model.library?.helpTopics() ?? []).map(\.title)
        let topics = all.filter { $0 == "Contents" } + all.filter { $0 != "Contents" }
        PanelFrame(s: s) {
            PanelHeader(title: "Text and Video Help", s: s, trailing: { model.panel = .subjects })
            SubjectTable(rows: topics.indices.map { .init(title: topics[$0], icon: iconRow(media: "text"), tag: $0) }
                         + clips.indices.map { .init(title: "Video Help \($0 + 1)", icon: iconRow(media: "video"), tag: topics.count + $0) },
                         selected: nil, scale: s) {
                if $0 < topics.count { model.showHelp(topics[$0]) } else { model.present([clips[$0 - topics.count]]) }
            }
        }
    }
}
