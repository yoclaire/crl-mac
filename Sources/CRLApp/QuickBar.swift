import AppKit
import ApplicationServices
import Combine
import CRLKit

/// The CRL Quick Bar (CRLBAR32.EXE): a small palette that floats over other apps, with the
/// magnifying glass, a button per book and Exit, in a 3 × 4 grid of 22 × 21 cells (its hit test,
/// CRLBAR32 @0x40412b).
///
/// What the original does, and what this does instead:
/// - A book button opens or closes that book for searching. CRLBAR32 sends CRL32 message 0x4C9
///   (1 = open, 2 = close, book code), or writes CRL32.INI OpenReferences when CRL32 isn't running.
///   Here it toggles `AppModel.openBooks`, which is saved the same way.
/// - The magnifier brings the app you were using to the front, empties the clipboard, sends it Ctrl+C
///   (`keybd_event`), waits for the copy, then starts CRL32 with "Search" so it searches the clipboard
///   (CRLBAR32 @0x401b37). Here the panel never takes focus, so that app is still frontmost: its
///   selection is read through Accessibility, or copied with ⌘C, and the clipboard is put back after.
/// - The search uses the System Configuration search type and lists the hits in the Index.
@MainActor
final class QuickBar: NSObject {
    static let shared = QuickBar()
    weak var model: AppModel? {
        didSet { watch = model?.$openBooks.sink { [weak self] _ in self?.view?.needsDisplay = true } }
    }
    private(set) var panel: NSPanel?
    private var view: QuickBarView?
    private var watch: AnyCancellable?

    /// The books in glyph order (CRLBAR32 command IDs 0x25A–0x263 → book codes 4 0 1 2 8 9 6 7 5 3).
    static let books = ["encyclopedia", "dictionary", "thesaurus", "almanac", "directory", "legal", "wallstreet", "history", "style", "quotes"]
    /// Tooltip names, from CRLBAR32's strings.
    static let names = ["Encyclopedia", "American Heritage ® Dictionary", "Roget's II", "Information Please ® Almanac", "National Directory",
                        "Legal Word Book", "Wall Street Words", "American History", "Written Word III", "Simpson's Contemporary Quotations"]

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : show() }

    func close() { panel?.orderOut(nil) }

    func show() {
        if panel == nil { makePanel() }
        panel?.orderFrontRegardless()
    }

    private func makePanel() {
        let scale: CGFloat = 2
        let v = QuickBarView(scale: scale)
        v.isOpen = { [weak self] i in self?.model?.openBooks.contains(Self.books[i]) == true }
        v.tooltip = { [weak self] i in
            switch i {
            case 0: "Search/Open Reference"
            case 11: "Exit"
            default: (self?.model?.openBooks.contains(Self.books[i - 1]) == true ? "Close " : "Open ") + Self.names[i - 1]
            }
        }
        v.action = { [weak self] i in self?.press(i) }
        let p = NSPanel(contentRect: v.frame, styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "CRL Quick Bar"
        p.contentView = v
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // "It remains poised in the corner of the screen": top right, until it's moved.
        if !p.setFrameUsingName("CRLQuickBar"), let s = NSScreen.main?.visibleFrame {
            p.setFrameTopLeftPoint(NSPoint(x: s.maxX - p.frame.width - 16, y: s.maxY - 16))
        }
        p.setFrameAutosaveName("CRLQuickBar")
        panel = p
        view = v
    }

    private func press(_ i: Int) {
        guard let model else { return }
        switch i {
        case 0:
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                let tv = ArticleTextView.current
                let sel = tv.map { ($0.string as NSString).substring(with: $0.selectedRange()) }
                model.quickBarSearch(sel)
            } else {
                Task { model.quickBarSearch(await Self.selectedText(in: front)) }
            }
        case 11:
            close()
        default:
            let id = Self.books[i - 1]
            if model.openBooks.contains(id) { model.openBooks.remove(id) } else { model.openBooks.insert(id) }
        }
    }

    /// The selected text in another app: its focused element's AXSelectedText, else (as CRLBAR32 does)
    /// a copy keystroke and the clipboard, which is then restored. Both need Accessibility access;
    /// without it this asks once and uses whatever is already on the clipboard.
    static func selectedText(in app: NSRunningApplication?) async -> String? {
        guard let app else { return nil }
        let pb = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            if !AppModel.defaults.bool(forKey: "QuickBarAskedAccess") {
                AppModel.defaults.set(true, forKey: "QuickBarAskedAccess")
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            return pb.string(forType: .string)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?, selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID(),
           AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let s = selected as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        let before = pb.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 8 /* kVK_ANSI_C */, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        var waited = 0
        while pb.changeCount == before, waited < 20 { try? await Task.sleep(for: .milliseconds(50)); waited += 1 }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
        return text
    }
}

/// Draws the bar as a 1995 MFC toolbar: black-framed raised buttons, with an open book shown pushed
/// in on a dithered (lighter) face, which is how the help describes them ("light gray represent
/// reference books that are open, darker gray squares represent closed books").
final class QuickBarView: NSView {
    static let cols = 3, rows = 4, cellW: CGFloat = 22, cellH: CGFloat = 21, margin: CGFloat = 3
    let scale: CGFloat
    var isOpen: (Int) -> Bool = { _ in false }
    var tooltip: (Int) -> String = { _ in "" }
    var action: (Int) -> Void = { _ in }
    private var pressed: Int?
    private var pressedInside = false

    private static let face = NSColor(srgbRed: 192 / 255, green: 192 / 255, blue: 192 / 255, alpha: 1)
    private static let shadow = NSColor(srgbRed: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1)

    init(scale: CGFloat) {
        self.scale = scale
        let w = Self.margin * 2 + CGFloat(Self.cols) * Self.cellW + 1, h = Self.margin * 2 + CGFloat(Self.rows) * Self.cellH + 1
        super.init(frame: NSRect(x: 0, y: 0, width: w * scale, height: h * scale))
        for i in 0..<12 { addToolTip(viewRect(i), owner: self, userData: nil) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A button in bar units: 23 × 22 (so neighbours share their black frame line).
    func unitRect(_ i: Int) -> NSRect {
        NSRect(x: Self.margin + CGFloat(i % Self.cols) * Self.cellW, y: Self.margin + CGFloat(i / Self.cols) * Self.cellH,
               width: Self.cellW + 1, height: Self.cellH + 1)
    }
    func viewRect(_ i: Int) -> NSRect {
        let r = unitRect(i)
        return NSRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
    }
    func index(at p: NSPoint) -> Int? { (0..<12).first { viewRect($0).insetBy(dx: scale / 2, dy: scale / 2).contains(p) } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        ctx.imageInterpolation = .none
        ctx.cgContext.scaleBy(x: scale, y: scale)
        Self.face.setFill()
        NSRect(x: 0, y: 0, width: bounds.width / scale, height: bounds.height / scale).fill()
        let strip = Art.image("quickbar")
        for i in 0..<12 { drawButton(i, strip: strip) }
        ctx.restoreGraphicsState()
    }

    private func drawButton(_ i: Int, strip: NSImage?) {
        let r = unitRect(i)
        let down = pressed == i && pressedInside
        let checked = (1...10).contains(i) && isOpen(i - 1)
        let inner = r.insetBy(dx: 1, dy: 1)
        if checked && !down {
            // 50% dither of white and button face
            NSColor.white.setFill()
            inner.fill()
            Self.face.setFill()
            for y in Int(inner.minY)..<Int(inner.maxY) {
                for x in Int(inner.minX)..<Int(inner.maxX) where (x + y) % 2 == 0 { NSRect(x: x, y: y, width: 1, height: 1).fill() }
            }
        } else {
            Self.face.setFill()
            inner.fill()
        }
        NSColor.black.setFill()
        r.frame(withWidth: 1)
        // the frame's corner pixels are left off, as Windows 3.x buttons draw it
        Self.face.setFill()
        for c in [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX - 1, y: r.minY), NSPoint(x: r.minX, y: r.maxY - 1), NSPoint(x: r.maxX - 1, y: r.maxY - 1)] {
            NSRect(x: c.x, y: c.y, width: 1, height: 1).fill()
        }
        if down || checked {
            Self.shadow.setFill()
            NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: 1).fill()
            NSRect(x: inner.minX, y: inner.minY, width: 1, height: inner.height).fill()
        } else {
            NSColor.white.setFill()
            NSRect(x: inner.minX, y: inner.minY, width: inner.width - 1, height: 1).fill()
            NSRect(x: inner.minX, y: inner.minY, width: 1, height: inner.height - 1).fill()
            Self.shadow.setFill()
            NSRect(x: inner.minX, y: inner.maxY - 2, width: inner.width, height: 2).fill()
            NSRect(x: inner.maxX - 2, y: inner.minY, width: 2, height: inner.height).fill()
        }
        let shift: CGFloat = down || checked ? 1 : 0
        let glyph = NSRect(x: inner.minX + 2 + shift, y: inner.minY + 2 + shift, width: 16, height: 15)
        if let strip {
            strip.draw(in: glyph, from: NSRect(x: CGFloat(i) * 16, y: 0, width: 16, height: 15), operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
        } else {
            // a library built before the Quick Bar artwork was unpacked: the button letters
            let label = i == 0 ? "?" : i == 11 ? "X" : String("EDTANLWHSQ"[String.Index(utf16Offset: i - 1, in: "EDTANLWHSQ")])
            let a = NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.black])
            let s = a.size()
            a.draw(at: NSPoint(x: glyph.midX - s.width / 2, y: glyph.midY - s.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
        pressedInside = pressed != nil
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let p = pressed else { return }
        let inside = index(at: convert(event.locationInWindow, from: nil)) == p
        if inside != pressedInside { pressedInside = inside; needsDisplay = true }
    }
    override func mouseUp(with event: NSEvent) {
        let hit = pressedInside ? pressed : nil
        pressed = nil
        pressedInside = false
        needsDisplay = true
        if let hit { action(hit) }
    }
}

extension QuickBarView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        index(at: point).map(tooltip) ?? "CRL Quick Bar"
    }
}

/// Services menu ▸ "Search in Complete Reference Library": the same search for any app's selection,
/// with no Accessibility access needed (declared under NSServices in Info.plist).
final class ServiceProvider: NSObject {
    @objc func searchSelection(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pboard.string(forType: .string)
        MainActor.assumeIsolated { QuickBar.shared.model?.quickBarSearch(text) }
    }
}
