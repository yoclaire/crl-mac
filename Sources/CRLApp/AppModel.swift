import AppKit
import AVFoundation
import CRLKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Screen { case welcome, importing, room, mediaLibrary }
    enum Panel: Equatable { case none, subjects, index, contents, trails, help }

    @Published var screen: Screen = .welcome
    @Published var library: Library?
    @Published var importStatus = ""
    @Published var importFraction = 0.0
    @Published var importError: String?

    // Reading state
    @Published var panel: Panel = .none
    @Published var book: Book?
    @Published var subjects: [Library.Subject] = []
    @Published var selection: Library.Subject?
    @Published var article: Library.Article?
    @Published var overlay: Library.MediaRef?          // picture/map/video shown over the article pane
    @Published var overlayItems: [Library.MediaRef] = []

    // Media Library
    @Published var mediaType = "picture"
    @Published var mediaCategories: [String] = []
    @Published var mediaCategory: String?
    @Published var mediaItems: [Library.MediaRef] = []
    @Published var mediaItem: Library.MediaRef?

    // Index (search)
    @Published var query = ""
    @Published var hits: [Library.Hit] = []
    @Published var fullText = false

    // Room
    @Published var hover: String?
    @Published var highlights: [String: [NSRange]] = [:]   // Highlighter marks, per article (this session)
    @Published var windowActive = true
    @Published var trail: [Library.Hit] = []
    @Published var bookmarks: [Library.Hit] = []
    @Published var buttonSounds = UserDefaults.standard.object(forKey: "ButtonSounds") as? Bool ?? true {
        didSet { UserDefaults.standard.set(buttonSounds, forKey: "ButtonSounds") }
    }

    let player = MediaPlayer()
    private var searchTask: Task<Void, Never>?

    /// Where a disc import writes its library (used only by builds without embedded content).
    static var importedLibraryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Complete Reference Library/library", isDirectory: true)
    }

    /// Library built into the app bundle by `scripts/make-app.sh` (the normal case).
    static var embeddedLibraryURL: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("library", isDirectory: true) }.flatMap { Library.isBuilt($0) ? $0 : nil }
    }

    static var isEmbedded: Bool { embeddedLibraryURL != nil }
    static var libraryURL: URL { embeddedLibraryURL ?? importedLibraryURL }

    init() {
        if Library.isBuilt(Self.libraryURL), let lib = try? Library(directory: Self.libraryURL) {
            library = lib
            screen = .room
        }
        bookmarks = (UserDefaults.standard.array(forKey: "Bookmarks") as? [[String: Any]] ?? []).compactMap {
            guard let b = $0["book"] as? String, let n = $0["num"] as? Int, let t = $0["title"] as? String else { return nil }
            return Library.Hit(book: b, num: n, title: t)
        }
    }

    // MARK: import

    func importDisc(_ iso: URL) {
        screen = .importing
        importError = nil
        let out = Self.importedLibraryURL
        Task.detached(priority: .userInitiated) {
            do {
                let b = try LibraryBuilder(isoURL: iso, output: out)
                b.progress = { msg, f in Task { @MainActor in self.importStatus = msg; self.importFraction = f } }
                try b.build()
                let lib = try Library(directory: out)
                await MainActor.run { Art.directory = out; self.library = lib; self.screen = .room; self.sound("success.wav") }
            } catch {
                await MainActor.run { self.importError = "\(error)"; self.screen = .welcome }
            }
        }
    }

    // MARK: books & articles

    func open(_ book: Book) {
        guard let library else { return }
        sound("refopen.wav")
        self.book = book
        subjects = (try? library.subjects(book: book.id)) ?? []
        panel = .subjects
        if let first = subjects.first { show(first) }
    }

    func show(_ s: Library.Subject) {
        selection = s
        load(book: s.book, num: s.num, title: s.title)
    }

    func show(_ hit: Library.Hit) {
        if book?.id != hit.book, let b = Book.all.first(where: { $0.id == hit.book }) {
            book = b
            subjects = (try? library?.subjects(book: b.id)) ?? []
        }
        selection = subjects.first { $0.num == hit.num } ?? Library.Subject(book: hit.book, num: hit.num, title: hit.title)
        load(book: hit.book, num: hit.num, title: hit.title)
    }

    private func load(book: String, num: Int, title: String) {
        overlay = nil
        player.stop()
        article = try? library?.article(book: book, num: num)
        let hit = Library.Hit(book: book, num: num, title: article?.title ?? title)
        trail.removeAll { $0 == hit }
        trail.insert(hit, at: 0)
        if trail.count > 100 { trail.removeLast() }
    }

    /// Follow an in-article cross-reference (crl://book/num).
    func follow(_ url: URL) {
        guard url.scheme == "crl", let book = url.host, let num = Int(url.lastPathComponent) else { return }
        show(Library.Hit(book: book, num: num, title: ""))
    }

    func media(_ kinds: Set<String>) -> [Library.MediaRef] {
        (article?.media ?? []).filter { kinds.contains($0.kind) && $0.path != nil }
    }

    // MARK: room objects

    static let mediaKinds: [String: Set<String>] = [
        "camera": ["picture"], "globe": ["map"], "videocam": ["video"], "filmstrip": ["animation"],
        "speaker": ["sound"], "trumpet": ["music"],
    ]

    func isEnabled(_ name: String) -> Bool {
        if let kinds = Self.mediaKinds[name] { return !media(kinds).isEmpty }
        switch name {
        case "textbook", "copier", "printer", "eraser": return article != nil
        case "glue": return article != nil
        default: return true
        }
    }

    func activate(_ name: String) {
        guard isEnabled(name) else { NSSound.beep(); return }
        if let b = Book.all.first(where: { $0.spine == name }) { open(b); return }
        if let kinds = Self.mediaKinds[name] { present(media(kinds)); return }
        switch name {
        case "textbook": overlay = nil; player.stop(); if panel == .none { panel = .subjects }
        case "magnifier", "index": panel = .index
        case "toc": panel = .contents
        case "notepad": panel = .trails
        case "help": panel = .help
        case "eraser": addBookmark()
        case "glue": highlightSelection()
        case "copier": copyArticle()
        case "printer": printArticle()
        case "media": screen = .mediaLibrary
        case "computer": NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case "quit": NSApp.terminate(nil)
        case "close": NSApp.keyWindow?.miniaturize(nil)
        case "sysmenu": NSApp.orderFrontStandardAboutPanel(nil)
        default: break
        }
    }

    func present(_ items: [Library.MediaRef]) {
        guard let first = items.first else { return }
        overlayItems = items
        play(first)
    }

    func play(_ m: Library.MediaRef) {
        guard let path = m.path, let library else { return }
        let url = library.url(path)
        switch m.kind {
        case "sound": player.playSound(url)
        case "music": player.playMusic(url)
        default: overlay = m; if m.kind == "video" || m.kind == "animation" || m.kind == "help" { player.stop() }
        }
    }

    func step(_ delta: Int) {
        guard let cur = overlay, let i = overlayItems.firstIndex(of: cur) else { return }
        let j = (i + delta + overlayItems.count) % overlayItems.count
        play(overlayItems[j])
    }

    /// Highlighter: mark the selected article text in yellow (select text first, then click the pen).
    func highlightSelection() {
        guard let a = article, let tv = ArticleTextView.current, tv.selectedRange().length > 0 else { NSSound.beep(); return }
        let r = tv.selectedRange()
        highlights["\(a.book)/\(a.num)", default: []].append(r)
        tv.textStorage?.addAttribute(.backgroundColor, value: Palette.highlight, range: r)
        tv.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
    }

    // MARK: Media Library

    func selectMediaType(_ kind: String) {
        player.stop()
        mediaType = kind
        mediaCategories = (try? library?.categories(kind: kind)) ?? []
        selectMediaCategory(mediaCategories.first)
    }

    func selectMediaCategory(_ c: String?) {
        mediaCategory = c
        mediaItems = c.flatMap { try? library?.media(inCategory: $0, kind: mediaType) } ?? []
        mediaItem = nil
    }

    func selectMediaItem(_ m: Library.MediaRef) {
        mediaItem = m
        guard let path = m.path, let library else { return }
        if m.kind == "sound" { player.playSound(library.url(path)) }
        if m.kind == "music" { player.playMusic(library.url(path)) }
    }

    func addBookmark() {
        guard let a = article else { return }
        let hit = Library.Hit(book: a.book, num: a.num, title: a.title)
        guard !bookmarks.contains(hit) else { return }
        bookmarks.append(hit)
        UserDefaults.standard.set(bookmarks.map { ["book": $0.book, "num": $0.num, "title": $0.title] }, forKey: "Bookmarks")
        sound("success.wav")
    }

    func copyArticle() {
        guard let a = article, let book = Book.all.first(where: { $0.id == a.book }) else { return }
        let text = ArticleRenderer(book: book, scale: 1).render(a).string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        sound("success.wav")
    }

    func printArticle() {
        guard let a = article, let book = Book.all.first(where: { $0.id == a.book }) else { return }
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        view.textStorage?.setAttributedString(ArticleRenderer(book: book, scale: 1).render(a))
        NSPrintOperation(view: view).run()
    }

    // MARK: search

    func search() {
        searchTask?.cancel()
        let q = query, full = fullText, lib = library, scope: String? = nil
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let lib else { return }
            let r = await Task.detached {
                full ? (try? lib.search(q, book: scope)) ?? [] : (try? lib.titles(prefix: q, book: scope)) ?? []
            }.value
            if !Task.isCancelled { hits = r }
        }
    }

    func sound(_ name: String) {
        guard buttonSounds, let library else { return }
        player.playEffect(library.url("ui/sounds/\(name)"))
    }
}

/// Audio/MIDI playback. Video is shown by the overlay view with AVPlayer.
@MainActor
final class MediaPlayer {
    private var audio: AVAudioPlayer?
    private var effect: AVAudioPlayer?
    private var midi: AVMIDIPlayer?

    func playSound(_ url: URL) {
        stop()
        audio = try? AVAudioPlayer(contentsOf: url)
        audio?.play()
    }

    func playEffect(_ url: URL) {
        effect = try? AVAudioPlayer(contentsOf: url)
        effect?.play()
    }

    /// The disc's music clips are WAVE recordings; only genuine .mid files go to the MIDI player.
    func playMusic(_ url: URL) {
        if url.pathExtension.lowercased() == "mid" { playMIDI(url) } else { playSound(url) }
    }

    func playMIDI(_ url: URL) {
        stop()
        midi = try? AVMIDIPlayer(contentsOf: url, soundBankURL: nil)
        midi?.prepareToPlay()
        midi?.play(nil)
    }

    func stop() {
        audio?.stop(); audio = nil
        midi?.stop(); midi = nil
    }
}
