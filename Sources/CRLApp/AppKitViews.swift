import AppKit
import CRLKit
import SwiftUI

/// Bitmaps unpacked from CRL32.EXE at import time.
@MainActor
enum Art {
    static var directory: URL?
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let dir = directory, let i = NSImage(contentsOf: dir.appendingPathComponent("ui/\(name).png")) else { return nil }
        cache[name] = i
        return i
    }
    static func image(_ id: Int) -> NSImage? { image(String(id)) }

    /// 16×16 icons from the IDB_MAINLIST strip: 4 columns (closed book, book+, folder, document)
    /// × 17 rows (one per book, then map/video/sound/music/picture/animation/search), on a pure-blue key.
    static func listIcon(column: Int, row: Int) -> NSImage? {
        let key = "icon-\(column)-\(row)"
        if let i = cache[key] { return i }
        guard let strip = image("IDB_MAINLIST"), let cg = strip.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let crop = cg.cropping(to: CGRect(x: column * 16, y: row * 16, width: 16, height: 16)) else { return nil }
        var px = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let ctx = CGContext(data: &px, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        for i in stride(from: 0, to: px.count, by: 4) where px[i] == 0 && px[i + 1] == 0 && px[i + 2] == 255 {
            px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0
        }
        let i = NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: 16, height: 16))
        cache[key] = i
        return i
    }
}

/// Colours sampled from the original panels.
enum Palette {
    static let panel = NSColor(srgbRed: 0.937, green: 0.902, blue: 0.835, alpha: 1)       // parchment body
    static let list = NSColor(srgbRed: 0.894, green: 0.851, blue: 0.769, alpha: 1)
    static let selection = NSColor(srgbRed: 0.769, green: 0.663, blue: 0.494, alpha: 1)
    static let titleBar = NSColor(srgbRed: 0.690, green: 0.592, blue: 0.431, alpha: 1)
    static let header = NSColor(srgbRed: 0.851, green: 0.784, blue: 0.659, alpha: 1)
    static let frame = NSColor(srgbRed: 0.30, green: 0.22, blue: 0.13, alpha: 1)
    static let track = NSColor(srgbRed: 0.659, green: 0.592, blue: 0.494, alpha: 1)
    static let highlight = NSColor(srgbRed: 1, green: 1, blue: 0.35, alpha: 1)
}

/// Windows 3.1-style scroller drawn with the SCRL_* bitmaps (arrows, thumb) on a tan track.
final class RetroScroller: NSScroller {
    nonisolated(unsafe) static var thickness: CGFloat = 32
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { thickness }
    override class var isCompatibleWithOverlayScrollers: Bool { false }

    var vertical: Bool { bounds.height > bounds.width }
    var side: CGFloat { vertical ? bounds.width : bounds.height }
    var decRect: NSRect { vertical ? NSRect(x: 0, y: 0, width: side, height: side) : NSRect(x: 0, y: 0, width: side, height: side) }
    var incRect: NSRect { vertical ? NSRect(x: 0, y: bounds.height - side, width: side, height: side)
                                   : NSRect(x: bounds.width - side, y: 0, width: side, height: side) }
    var slot: NSRect { vertical ? NSRect(x: 0, y: side, width: side, height: max(0, bounds.height - 2 * side))
                                : NSRect(x: side, y: 0, width: max(0, bounds.width - 2 * side), height: side) }
    var thumbRect: NSRect {
        let length = vertical ? slot.height : slot.width
        let t = side, travel = max(0, length - t), pos = (vertical ? slot.minY : slot.minX) + travel * CGFloat(doubleValue)
        return vertical ? NSRect(x: 0, y: pos, width: side, height: t) : NSRect(x: pos, y: 0, width: t, height: side)
    }
    var pressed: NSScroller.Part = .noPart

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.track.setFill(); bounds.fill()
        let dec = vertical ? (pressed == .decrementPage ? "SCRL_UD" : "SCRL_UU") : (pressed == .decrementPage ? "SCRL_LD" : "SCRL_LU")
        let inc = vertical ? (pressed == .incrementPage ? "SCRL_DD" : "SCRL_DU") : (pressed == .incrementPage ? "SCRL_RD" : "SCRL_RU")
        draw(dec, in: decRect); draw(inc, in: incRect)
        if knobProportion < 1 { draw("SCRL_BU", in: thumbRect) }
    }

    func draw(_ name: String, in r: NSRect) {
        guard let img = Art.image(name) else { return }
        NSGraphicsContext.current?.imageInterpolation = .none
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    var scrollView: NSScrollView? { superview as? NSScrollView }

    func scroll(by delta: CGFloat) {
        guard let sv = scrollView else { return }
        var o = sv.contentView.bounds.origin
        let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
        o.y = min(maxY, max(0, o.y + delta))
        sv.contentView.scroll(to: o); sv.reflectScrolledClipView(sv.contentView)
    }

    func scroll(toFraction f: CGFloat) {
        guard let sv = scrollView else { return }
        let maxY = max(0, (sv.documentView?.frame.height ?? 0) - sv.contentView.bounds.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: maxY * min(1, max(0, f))))
        sv.reflectScrolledClipView(sv.contentView)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let line = (scrollView?.verticalLineScroll ?? 12) * 1.5, page = (scrollView?.contentView.bounds.height ?? 100) * 0.9
        let action: (() -> Void)?
        if decRect.contains(p) { pressed = .decrementPage; action = { self.scroll(by: -line) } }
        else if incRect.contains(p) { pressed = .incrementPage; action = { self.scroll(by: line) } }
        else if thumbRect.contains(p) {
            let grab = (vertical ? p.y - thumbRect.minY : p.x - thumbRect.minX)
            while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type == .leftMouseDragged {
                let q = convert(e.locationInWindow, from: nil)
                let travel = max(1, (vertical ? slot.height : slot.width) - side)
                scroll(toFraction: ((vertical ? q.y - slot.minY : q.x - slot.minX) - grab) / travel)
            }
            return
        } else {
            let before = vertical ? p.y < thumbRect.minY : p.x < thumbRect.minX
            action = { self.scroll(by: before ? -page : page) }
        }
        needsDisplay = true
        action?()
        // Auto-repeat while the button is held, like the original.
        var first = true
        while true {
            guard let e = window?.nextEvent(matching: [.leftMouseUp, .periodic], until: .distantFuture, inMode: .eventTracking, dequeue: true) else { break }
            if e.type == .leftMouseUp { break }
            if first { first = false; NSEvent.startPeriodicEvents(afterDelay: 0.35, withPeriod: 0.05) }
            action?()
        }
        NSEvent.stopPeriodicEvents()
        pressed = .noPart; needsDisplay = true
    }
}

func makeRetroScrollView() -> NSScrollView {
    let sv = NSScrollView()
    sv.scrollerStyle = .legacy
    sv.hasVerticalScroller = true
    sv.hasHorizontalScroller = false
    sv.autohidesScrollers = false
    sv.verticalScroller = RetroScroller()
    sv.borderType = .noBorder
    sv.drawsBackground = false
    return sv
}

// MARK: - Article text

struct ArticleTextView: NSViewRepresentable {
    /// The visible article text view (for the Highlighter).
    @MainActor static weak var current: NSTextView?

    let text: NSAttributedString
    let scale: CGFloat
    var highlights: [NSRange] = []
    let follow: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(follow: follow) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = makeRetroScrollView()
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = Palette.panel
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = context.coordinator
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        RetroScroller.thickness = 16 * scale
        sv.tile()
        context.coordinator.follow = follow
        guard let tv = sv.documentView as? NSTextView else { return }
        tv.textContainerInset = NSSize(width: 4 * scale, height: 3 * scale)
        if context.coordinator.shown !== text {
            context.coordinator.shown = text
            tv.textStorage?.setAttributedString(text)
            for r in highlights where NSMaxRange(r) <= text.length {
                tv.textStorage?.addAttribute(.backgroundColor, value: Palette.highlight, range: r)
            }
            tv.scroll(.zero)
        }
        context.coordinator.textView = tv
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var follow: (URL) -> Void
        var shown: NSAttributedString?
        weak var textView: NSTextView? {
            didSet { if textView != nil { ArticleTextView.current = textView } }
        }
        init(follow: @escaping (URL) -> Void) { self.follow = follow }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let u = link as? URL { follow(u); return true }
            return false
        }
    }
}

// MARK: - Subject list

struct SubjectTable: NSViewRepresentable {
    struct Row: Hashable { let title: String; let icon: Int; let tag: Int; var column = 0 }
    let rows: [Row]
    let selected: Int?
    let scale: CGFloat
    let choose: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = makeRetroScrollView()
        let tv = NSTableView()
        tv.headerView = nil
        tv.addTableColumn(NSTableColumn(identifier: .init("t")))
        tv.backgroundColor = Palette.list
        tv.intercellSpacing = .zero
        tv.selectionHighlightStyle = .none
        tv.style = .plain
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator
        tv.target = context.coordinator
        tv.action = #selector(Coordinator.clicked(_:))
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        RetroScroller.thickness = 16 * scale
        sv.tile()
        guard let tv = sv.documentView as? NSTableView else { return }
        let c = context.coordinator
        c.choose = choose
        let changed = c.rows != rows || c.scale != scale
        c.scale = scale
        tv.rowHeight = (16 * scale).rounded()
        if changed { c.rows = rows; tv.reloadData() }
        if c.selected != selected {
            let old = c.selected
            c.selected = selected
            if let i = old.flatMap({ s in rows.firstIndex { $0.tag == s } }) { tv.reloadData(forRowIndexes: [i], columnIndexes: [0]) }
            if let i = selected.flatMap({ s in rows.firstIndex { $0.tag == s } }) {
                tv.reloadData(forRowIndexes: [i], columnIndexes: [0])
                tv.scrollRowToVisible(i)
            }
        }
        tv.tableColumns.first?.width = sv.contentSize.width
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [Row] = [], selected: Int?, scale: CGFloat = 1
        var choose: (Int) -> Void = { _ in }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: .init("c"), owner: nil) as? SubjectCell) ?? SubjectCell()
            cell.identifier = .init("c")
            let r = rows[row]
            cell.configure(title: r.title, icon: r.icon, column: r.column, selected: r.tag == selected, scale: scale)
            return cell
        }

        @objc func clicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0, sender.clickedRow < rows.count else { return }
            choose(rows[sender.clickedRow].tag)
        }
    }
}

final class SubjectCell: NSView {
    private var title = "", icon = 0, column = 0, selected = false, scale: CGFloat = 1
    override var isFlipped: Bool { true }

    func configure(title: String, icon: Int, column: Int, selected: Bool, scale: CGFloat) {
        self.title = title; self.icon = icon; self.column = column; self.selected = selected; self.scale = scale
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (selected ? Palette.selection : Palette.list).setFill()
        bounds.fill()
        let s = scale
        if let img = MainActor.assumeIsolated({ Art.listIcon(column: column, row: icon) }) {
            NSGraphicsContext.current?.imageInterpolation = .none
            img.draw(in: NSRect(x: 2 * s, y: 0, width: 16 * s, height: 16 * s), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
        }
        let font = NSFont(name: "Times New Roman", size: 12.5 * s) ?? .systemFont(ofSize: 12 * s)
        (title as NSString).draw(at: NSPoint(x: 20 * s, y: 1 * s), withAttributes: [.font: font, .foregroundColor: NSColor.black])
    }
}

// MARK: - Pop-up menus

/// Closure-backed NSMenuItems, for the room's pop-up menus (bookmarks, search type).
@MainActor
final class MenuAction: NSObject {
    private let run: () -> Void
    private static var live: [MenuAction] = []      // NSMenuItem holds its target weakly
    private static var shown: [MenuAction] = []     // the last menu's actions, kept until the next one
    private init(_ run: @escaping () -> Void) { self.run = run }
    @objc private func fire() { run() }

    static func item(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(run)
        live.append(a)
        let i = NSMenuItem(title: title, action: enabled ? #selector(fire) : nil, keyEquivalent: "")
        i.target = a
        i.isEnabled = enabled
        return i
    }

    /// Show the menu at the mouse in the key window. Its actions stay alive until the next pop-up,
    /// however AppKit schedules the chosen item's action.
    static func popUp(_ menu: NSMenu) {
        shown = live
        live = []
        menu.autoenablesItems = false
        if let view = NSApp.keyWindow?.contentView ?? NSApp.windows.first(where: \.isVisible)?.contentView {
            let p = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            menu.popUp(positioning: nil, at: p, in: view)
        }
    }
}
