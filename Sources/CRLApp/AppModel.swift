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
    /// A text-help topic shown in the view window instead of an article.
    struct HelpTopic: Equatable { let title: String; let body: String }
    @Published var helpTopic: HelpTopic?
    /// Table of Contents panel: the book whose outline is open, and which outline nodes are expanded.
    @Published var tocBook: Book?
    @Published var tocExpanded: Set<Int> = []
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
    @Published var fullText = AppModel.defaults.string(forKey: "SearchTypeDefault") == "full"
    /// The last submitted search found nothing (CRL32's Quick/Full Text Search Failure dialogs).
    @Published var searchFailed = false
    /// `hits` holds Spell Check suggestions rather than search results.
    @Published var suggesting = false

    // Room
    @Published var hover: String?
    /// Highlighter marks per article ("book/num" → ranges in the rendered text), kept between launches.
    @Published var highlights: [String: [NSRange]] = [:] {
        didSet { AppModel.defaults.set(highlights.mapValues { $0.map { [$0.location, $0.length] } }, forKey: "Highlights") }
    }
    @Published var windowActive = true
    /// A disc image is being dragged over the welcome screen. Lives here rather than in a view's
    /// `@State`: SwiftUI's `State` macro plugin ships with Xcode only, so CLT-only builds can't expand it.
    @Published var droppingDisc = false
    /// Reference Trails: articles visited, newest first (saved between launches when SaveTrails is on).
    @Published var trail: [Library.Hit] = [] { didSet { if saveTrails { AppModel.defaults.set(trail.map(Self.plist), forKey: "Trails") } } }
    @Published var trailSelection: Int?
    struct Bookmark: Hashable { let name: String; let hit: Library.Hit }
    @Published var bookmarks: [Bookmark] = [] {
        didSet { AppModel.defaults.set(bookmarks.map { Self.plist($0.hit).merging(["name": $0.name]) { $1 } }, forKey: "Bookmarks") }
    }
    /// Books whose index the search covers: the ones opened from the bookcase. CRL32's default is
    /// OpenReferences = "1010100100" (by book code: Dictionary, Almanac, Encyclopedia, American History).
    @Published var openBooks: Set<String> = [] { didSet { if saveBooks { AppModel.defaults.set(Self.bookMask(openBooks), forKey: "OpenReferences") } } }

    // MARK: System Configuration (CRL32's dialog 438; UserDefaults keys are its registry value names)
    @Published var searchTypeDefault = AppModel.defaults.string(forKey: "SearchTypeDefault") ?? "quick" {   // quick | full | menu
        didSet { AppModel.defaults.set(searchTypeDefault, forKey: "SearchTypeDefault") }
    }
    @Published var indexing = AppModel.flag("Indexing", true) { didSet { AppModel.defaults.set(indexing, forKey: "Indexing") } }
    @Published var saveBooks = AppModel.flag("SaveBooks", true) {
        didSet { AppModel.defaults.set(saveBooks, forKey: "SaveBooks"); if saveBooks { AppModel.defaults.set(Self.bookMask(openBooks), forKey: "OpenReferences") } }
    }
    @Published var saveTrails = AppModel.flag("SaveTrails", true) {
        didSet { AppModel.defaults.set(saveTrails, forKey: "SaveTrails"); AppModel.defaults.set(saveTrails ? trail.map(Self.plist) : [], forKey: "Trails") }
    }
    @Published var saveArticle = AppModel.flag("Save Article", true) { didSet { AppModel.defaults.set(saveArticle, forKey: "Save Article") } }
    @Published var expandPictures = AppModel.flag("ExpandPictures", false) { didSet { AppModel.defaults.set(expandPictures, forKey: "ExpandPictures") } }
    @Published var expandMaps = AppModel.flag("ExpandMaps", false) { didSet { AppModel.defaults.set(expandMaps, forKey: "ExpandMaps") } }
    @Published var passOverHelp = AppModel.flag("PassOverHelp", true) { didSet { AppModel.defaults.set(passOverHelp, forKey: "PassOverHelp") } }
    @Published var buttonSounds = AppModel.defaults.object(forKey: "ButtonSounds") as? Bool ?? AppModel.flag("EnableSounds", true) {
        didSet { AppModel.defaults.set(buttonSounds, forKey: "ButtonSounds") }
    }

    /// Preferences. Snapshot runs (CRL_SNAPSHOT) get a scratch domain, wiped at launch, so test scenarios
    /// never touch the real trails, bookmarks or settings.
    static let defaults: UserDefaults = {
        guard ProcessInfo.processInfo.environment["CRL_SNAPSHOT"] != nil, let d = UserDefaults(suiteName: "com.clairemara.crl-mac.snapshot") else {
            return .standard
        }
        d.removePersistentDomain(forName: "com.clairemara.crl-mac.snapshot")
        for (k, v) in ProcessInfo.processInfo.environment where k.hasPrefix("CRL_PREF_") {
            let key = String(k.dropFirst(9)).replacingOccurrences(of: "_", with: " ")
            d.set(v == "1" ? true : v == "0" ? false : v as Any, forKey: key)
        }
        return d
    }()

    static func flag(_ key: String, _ def: Bool) -> Bool { AppModel.defaults.object(forKey: key) as? Bool ?? def }
    static func plist(_ h: Library.Hit) -> [String: Any] { ["book": h.book, "num": h.num, "title": h.title] }
    static func hit(_ d: [String: Any]) -> Library.Hit? {
        guard let b = d["book"] as? String, let n = d["num"] as? Int, let t = d["title"] as? String else { return nil }
        return Library.Hit(book: b, num: n, title: t)
    }
    /// Open books as CRL32's 10-character mask, one digit per book code.
    static func bookMask(_ open: Set<String>) -> String {
        String((0..<10).map { code in Book.all.first { $0.mediaCode == code }.map { open.contains($0.id) ? "1" : "0" } ?? "0" })
    }
    static func books(mask: String) -> Set<String> {
        Set(mask.enumerated().compactMap { i, c in c == "1" ? Book.all.first { $0.mediaCode == i }?.id : nil })
    }

    let player = MediaPlayer()
    private var searchTask: Task<Void, Never>?
    private var pendingSubmit: String?

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
        let d = AppModel.defaults
        bookmarks = (d.array(forKey: "Bookmarks") as? [[String: Any]] ?? []).compactMap { r in
            Self.hit(r).map { Bookmark(name: r["name"] as? String ?? $0.title, hit: $0) }
        }
        openBooks = Self.books(mask: saveBooks ? d.string(forKey: "OpenReferences") ?? "1010100100" : "1010100100")
        if saveTrails { trail = (d.array(forKey: "Trails") as? [[String: Any]] ?? []).compactMap(Self.hit) }
        highlights = (d.dictionary(forKey: "Highlights") as? [String: [[Int]]] ?? [:]).mapValues {
            $0.compactMap { $0.count == 2 ? NSRange(location: $0[0], length: $0[1]) : nil }
        }
        if saveArticle, library != nil, let h = (d.dictionary(forKey: "CurrentArticle")).flatMap(Self.hit) {
            panel = .subjects
            show(h)
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
        openBooks.insert(book.id)
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
        helpTopic = nil
        player.stop()
        article = try? library?.article(book: book, num: num)
        let hit = Library.Hit(book: book, num: num, title: article?.title ?? title)
        if saveArticle { AppModel.defaults.set(Self.plist(hit), forKey: "CurrentArticle") }
        trail.removeAll { $0 == hit }
        trail.insert(hit, at: 0)
        if trail.count > 100 { trail.removeLast() }
    }

    /// Open a book's outline in the Table of Contents panel, showing its first two levels.
    func openTOC(_ book: Book) {
        tocBook = book
        tocExpanded = Set((library?.tableOfContents(book: book.id) ?? []).enumerated().filter { $0.element.level == 0 }.map(\.offset))
    }

    /// Choose outline node `i`: a section toggles open or closed; every node opens its first article.
    func chooseTOC(_ i: Int) {
        guard let book = tocBook, let nodes = library?.tableOfContents(book: book.id), nodes.indices.contains(i) else { return }
        if i + 1 < nodes.count, nodes[i + 1].level > nodes[i].level {
            if tocExpanded.contains(i) { tocExpanded.remove(i) } else { tocExpanded.insert(i) }
        }
        show(Library.Hit(book: book.id, num: nodes[i].first, title: nodes[i].title))
    }

    /// Show a text-help topic by title in the view window.
    func showHelp(_ title: String) {
        guard let t = library?.helpTopics().first(where: { $0.title == title }) else { NSSound.beep(); return }
        overlay = nil
        player.stop()
        article = nil
        helpTopic = HelpTopic(title: t.title, body: t.body)
    }

    /// Follow an in-article cross-reference (crl://book/num) or a help link (crlhelp:Title).
    func follow(_ url: URL) {
        if url.scheme == "crlhelp" { showHelp(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""); return }
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
        case "magnifier": searchMenuOrIndex()
        case "index": panel = .index
        case "toc": panel = .contents
        case "notepad": panel = .trails
        case "help": panel = .help
        case "eraser": bookmarkMenu()
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

    /// "Expand to Full View": pictures and/or maps fill the window instead of the view window.
    func isFullView(_ m: Library.MediaRef) -> Bool {
        (m.kind == "picture" && expandPictures) || (m.kind == "map" && expandMaps)
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
    /// Highlighting over existing marks removes them instead. Marks are kept between launches.
    func highlightSelection() {
        guard let a = article, let tv = ArticleTextView.current, tv.selectedRange().length > 0 else { NSSound.beep(); return }
        let r = tv.selectedRange(), key = "\(a.book)/\(a.num)"
        let existing = highlights[key] ?? []
        let overlapping = existing.filter { NSIntersectionRange($0, r).length > 0 }
        if overlapping.isEmpty {
            highlights[key] = existing + [r]
            tv.textStorage?.addAttribute(.backgroundColor, value: Palette.highlight, range: r)
        } else {
            highlights[key] = existing.filter { NSIntersectionRange($0, r).length == 0 }
            for o in overlapping where NSMaxRange(o) <= (tv.textStorage?.length ?? 0) { tv.textStorage?.removeAttribute(.backgroundColor, range: o) }
        }
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

    // MARK: bookmarks (CRL32 dialogs 178 "Bookmark Create", 253 "Select Bookmark to find", 254 "… to Delete")

    /// "Enter Name of Bookmark to Create": the current article under a name (default: its title).
    func setBookmark() {
        guard let a = article else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Enter Name of Bookmark to Create"
        let field = NSTextField(string: a.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { NSSound.beep(); return }
        bookmarks.removeAll { $0.name == name }
        bookmarks.append(Bookmark(name: name, hit: Library.Hit(book: a.book, num: a.num, title: a.title)))
        sound("success.wav")
    }

    func gotoBookmark(_ b: Bookmark) {
        if panel == .none { panel = .subjects }
        show(b.hit)
    }

    func deleteBookmark(_ b: Bookmark) {
        bookmarks.removeAll { $0 == b }
        sound("success.wav")
    }

    /// The bookmark on the desk: a menu to set, go to, or delete bookmarks.
    func bookmarkMenu() {
        let menu = NSMenu()
        menu.addItem(MenuAction.item(article == nil ? "Set Bookmark…" : "Set Bookmark for \u{201C}\(article!.title)\u{201D}…", enabled: article != nil) { [weak self] in self?.setBookmark() })
        if !bookmarks.isEmpty {
            menu.addItem(.separator())
            for b in bookmarks.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                menu.addItem(MenuAction.item(b.name) { [weak self] in self?.gotoBookmark(b) })
            }
            menu.addItem(.separator())
            let del = NSMenuItem(title: "Delete Bookmark", action: nil, keyEquivalent: "")
            del.submenu = NSMenu()
            for b in bookmarks { del.submenu?.addItem(MenuAction.item(b.name) { [weak self] in self?.deleteBookmark(b) }) }
            menu.addItem(del)
        }
        MenuAction.popUp(menu)
    }

    // MARK: trails (CRL32 dialog 304 "Trails List": Delete, Delete All)

    func deleteTrailItem(_ i: Int) {
        guard trail.indices.contains(i) else { NSSound.beep(); return }
        trail.remove(at: i)
        trailSelection = nil
    }

    func deleteAllTrails() {
        trail.removeAll()
        trailSelection = nil
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

    /// The magnifying glass: with "Search Menu" as the default search type, ask which search to run.
    func searchMenuOrIndex() {
        guard searchTypeDefault == "menu" else { fullText = searchTypeDefault == "full"; panel = .index; return }
        let menu = NSMenu()
        menu.addItem(MenuAction.item("Quick Subject Search") { [weak self] in self?.fullText = false; self?.panel = .index; self?.search() })
        menu.addItem(MenuAction.item("Full Text Search") { [weak self] in self?.fullText = true; self?.panel = .index; self?.search() })
        MenuAction.popUp(menu)
    }

    /// Search the open books. Typing searches as you go when "Indexing while typing" is on;
    /// Return (`submit`) always searches, opens the first hit, or reports the failure.
    func search(submit: Bool = false) {
        // A submitted search (Return, a Spell Check pick) also changes `query`, and the Index's onChange
        // then asks for a live search of the same text; don't let that cancel the submitted one.
        if !submit, query == pendingSubmit { return }
        pendingSubmit = submit ? query : nil
        searchTask?.cancel()
        searchFailed = false
        suggesting = false
        guard indexing || submit else { return }
        let q = query, full = fullText, lib = library, scope = Book.all.map(\.id).filter { openBooks.contains($0) }
        searchTask = Task {
            if !submit { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled, let lib else { return }
            let r = await Task.detached {
                full ? (try? lib.search(q, books: scope)) ?? [] : (try? lib.titles(prefix: q, books: scope)) ?? []
            }.value
            guard !Task.isCancelled else { return }
            hits = r
            if submit { pendingSubmit = nil }
            if submit {
                if let h = r.first { show(h) } else if !q.trimmingCharacters(in: .whitespaces).isEmpty { searchFailed = true; sound("abort.wav") }
            }
        }
    }

    /// Search failure → "Spell Check": list dictionary words close to the query.
    func spellCheck() {
        searchFailed = false
        let words: [String] = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let word = words.max(by: { $0.count < $1.count }) ?? query
        hits = library?.suggestions(for: word) ?? []
        suggesting = true
        if hits.isEmpty { NSSound.beep() }
    }

    /// Search failure → "Text Search": run the query as a full-text search instead.
    func textSearchInstead() {
        fullText = true
        search(submit: true)
    }

    /// Pick a Spell Check suggestion: search for it.
    func useSuggestion(_ h: Library.Hit) {
        // End the search field's editing session first: a focused field keeps showing its own text
        // when `query` changes underneath it.
        NSApp.keyWindow?.makeFirstResponder(nil)
        query = h.title
        search(submit: true)
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
