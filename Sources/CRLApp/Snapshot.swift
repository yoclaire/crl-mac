import AppKit
import CRLKit

/// Development aid: `CRL_SNAPSHOT=out.png CRL_SCENARIO=dictionary:eighty-six` renders the window
/// into a PNG after setting up the scenario, then quits. Lets layout be checked without screen
/// recording permission.
@MainActor
enum Snapshot {
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
            case "hover": model.hover = parts.count > 1 ? parts[1] : nil
            case "help": model.panel = .help; if parts.count > 1 { model.showHelp(parts[1]) }
            case "toc":
                // toc[:book[:node index to choose]]
                model.panel = .contents
                let f = scenario.split(separator: ":").map(String.init)
                if f.count > 1, let b = Book.all.first(where: { $0.id == f[1] }) { model.openTOC(b) }
                if f.count > 2, let i = Int(f[2]) { model.chooseTOC(i) }
            case "index": model.panel = .index; model.query = parts.count > 1 ? parts[1] : ""; model.search()
            case let b?:
                if let book = Book.all.first(where: { $0.id == b }) {
                    model.open(book)
                    if parts.count > 1, let hit = (try? model.library?.titles(prefix: parts[1], book: book.id))?.first { model.show(hit) }
                }
            default: break
            }
            if let o = env["CRL_OVERLAY"] { model.present(model.media([o])) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                exit(0)
            }
        }
    }
}
