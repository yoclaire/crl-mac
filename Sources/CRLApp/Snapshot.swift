import AppKit
import CRLKit

/// Development aid: `CRL_SNAPSHOT=out.png CRL_SCENARIO=dictionary:eighty-six` renders the window
/// into a PNG after setting up the scenario, then quits. Lets layout be checked without screen
/// recording permission.
@MainActor
enum Snapshot {
    /// The app's real preferences as they were at launch. AppModel's settings already go to a scratch
    /// domain in snapshot runs, but AppKit saves window frames (and AVKit its own keys) to the standard
    /// domain, so a snapshot run puts that domain back as it found it before quitting.
    private static var savedSettings: [String: Any]?
    private static let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName

    /// Called before any window exists.
    static func preserveSettings() {
        guard ProcessInfo.processInfo.environment["CRL_SNAPSHOT"] != nil else { return }
        savedSettings = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
    }

    private static func finish(_ code: Int32) -> Never {
        if let saved = savedSettings {
            if saved.isEmpty { UserDefaults.standard.removePersistentDomain(forName: domain) }
            else { UserDefaults.standard.setPersistentDomain(saved, forName: domain) }
            UserDefaults.standard.synchronize()
        }
        exit(code)
    }

    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["CRL_SNAPSHOT"] else { return }
        let scenario = env["CRL_SCENARIO"] ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let parts = scenario.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts.first {
            case "media":
                // media[:kind[:category[:item index]]]
                model.screen = .mediaLibrary
                let f = scenario.split(separator: ":").map(String.init)
                if f.count > 1 { model.selectMediaType(f[1]) }
                if f.count > 2 { model.selectMediaCategory(f[2]) }
                if f.count > 3, let i = Int(f[3]), i < model.mediaItems.count { model.selectMediaItem(model.mediaItems[i]); model.player.stop() }
            case "quickbar":
                // quickbar[:book,book…] — open the Quick Bar with exactly these books open
                if parts.count > 1 { model.openBooks = Set(parts[1].split(separator: ",").map(String.init)) }
                QuickBar.shared.show()
            case "lookup": model.quickBarSearch(parts.count > 1 ? parts[1] : nil)   // the Quick Bar magnifier's search
            case "hover": model.hover = parts.count > 1 ? parts[1] : nil
            case "help": model.panel = .help; if parts.count > 1 { model.showHelp(parts[1]) }
            case "toc":
                // toc[:book[:node index to choose]]
                model.panel = .contents
                let f = scenario.split(separator: ":").map(String.init)
                if f.count > 1, let b = Book.all.first(where: { $0.id == f[1] }) { model.openTOC(b) }
                if f.count > 2, let i = Int(f[2]) { model.chooseTOC(i) }
            case "index": model.panel = .index; model.query = parts.count > 1 ? parts[1] : ""; model.search()
            case "submit": model.panel = .index; model.query = parts.count > 1 ? parts[1] : ""; model.search(submit: true)
            case "spell": model.panel = .index; model.query = parts.count > 1 ? parts[1] : ""; model.spellCheck()
            case "pick":
                // pick:word — Spell Check, then (with the Index on screen) choose the first suggestion
                model.panel = .index; model.query = parts.count > 1 ? parts[1] : ""; model.spellCheck()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if let h = model.hits.first { model.useSuggestion(h) } }
            case "trails":
                // trails[:book:title,…] — visit articles, then show the Reference Trails panel
                for spec in (parts.count > 1 ? parts[1] : "").split(separator: ",") {
                    let f = spec.split(separator: ":").map(String.init)
                    if f.count == 2, let h = (try? model.library?.titles(prefix: f[1], book: f[0]))?.first { model.show(h) }
                }
                model.panel = .trails; model.trailSelection = 1
            case let b?:
                if let book = Book.all.first(where: { $0.id == b }) {
                    model.open(book)
                    if parts.count > 1, let hit = (try? model.library?.titles(prefix: parts[1], book: book.id))?.first { model.show(hit) }
                }
            default: break
            }
            if let o = env["CRL_OVERLAY"] { model.present(model.media([o])) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let window = parts.first == "quickbar" ? QuickBar.shared.panel : NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
                guard let view = window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { finish(1) }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                finish(0)
            }
        }
    }
}
