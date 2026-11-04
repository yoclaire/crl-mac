import CRLKit
import Foundation

// crltool — build or inspect a library without the app.
//   crltool import <disc.iso> <library-dir>
//   crltool entry <disc.iso> <book-id> <n>
//   crltool search <library-dir> <query>
//   crltool ui <disc.iso> <library-dir>      refresh only the artwork, sounds and font

let args = CommandLine.arguments
func usage() -> Never {
    print("usage: crltool import <disc.iso> <library-dir> | entry <disc.iso> <book> <n> | search <library-dir> <query> | help <disc.iso> | suggest <library-dir> <word> | ui <disc.iso> <library-dir>")
    exit(2)
}
guard args.count >= 2 else { usage() }

do {
    switch args[1] {
    case "import" where args.count == 4:
        let b = try LibraryBuilder(isoURL: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]))
        if b.ffmpegPath == nil { print("note: ffmpeg not found — videos will be listed but not playable") }
        var last = ""
        b.progress = { msg, f in
            if msg != last { print(String(format: "[%3.0f%%] %@", f * 100, msg)); last = msg }
        }
        let t = Date()
        try b.build()
        print(String(format: "built in %.1fs", Date().timeIntervalSince(t)))
    case "ui" where args.count == 4:
        guard Library.isBuilt(URL(fileURLWithPath: args[3])) else { print("no library at \(args[3])"); exit(1) }
        try LibraryBuilder(isoURL: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])).buildUI()
    case "entry" where args.count == 5:
        let iso = try ISO9660(url: URL(fileURLWithPath: args[2]))
        guard let book = Book.all.first(where: { $0.id == args[3] }), let n = Int(args[4]) else { usage() }
        print(Markup.decode(try REDB(data: iso.contents("CRL/REFDATA/\(book.file)")).entry(n)))
    case "search" where args.count >= 4:
        let lib = try Library(directory: URL(fileURLWithPath: args[2]))
        for hit in try lib.search(args[3...].joined(separator: " "), limit: 20) {
            print("\(hit.book)\t\(hit.num)\t\(hit.title)")
        }
    case "suggest" where args.count == 4:
        let lib = try Library(directory: URL(fileURLWithPath: args[2]))
        for h in lib.suggestions(for: args[3]) { print(h.title) }
    case "help" where args.count == 3:
        let iso = try ISO9660(url: URL(fileURLWithPath: args[2]))
        for t in try HelpFile.topics(try iso.contents("CRL/CRL32.HLP")) {
            let shown = t.body.map { c -> String in
                switch c { case HelpFile.linkStart: "[["; case HelpFile.linkEnd: "]]"; case HelpFile.boldStart: "**"; case HelpFile.boldEnd: "**"; default: String(c) }
            }.joined()
            print("## \(t.title)\n\(shown)\n")
        }
    case "selftest":
        func check(_ ok: Bool, _ what: String) { print(ok ? "ok   \(what)" : "FAIL \(what)"); if !ok { exit(1) } }
        check(Markup.title("<WD>aard\u{b7}vark<PR>x\n<HW>y").title == "aardvark", "title strips tags and syllable dots")
        check(Markup.title("<IWD>Pakistan [7]\n").isContinuation, "continuation detection")
        check(Markup.plain("&ldquo;you&rdquo; \\schwa/") == "“you” ə", "entities and glyphs")
        check(Markup.span("<WD>x\n<CS>1<CE>13<PAR>1")?.last == 13, "article span")
        let j = Data([0xFF, 0xD8, 0xFF, 0xE1, 0, 10, 0x50, 0x49, 0x43, 0, 1, 24, 30, 1, 0xFF, 0xDA, 0, 2])
        let r = try MediaFile.repairJPEG(j)
        check(Array(r.prefix(4)) == [0xFF, 0xD8, 0xFF, 0xDB] && r.range(of: Data("PIC".utf8)) == nil && r[6] == 0 && r[7] == 12, "Pegasus JPEG repair")
        // C-Index: an index node (level 1) holding the key "Birds" + a child pointer sits before the leaf
        // node that holds the real record; the scan must take the leaf's payload.
        var ctg = Data(count: 0x400 + 2 * 4096)
        func put(_ at: Int, _ b: [UInt8]) { ctg.replaceSubrange(at..<at + b.count, with: b) }
        func rec(_ name: String, _ payload: [UInt8]) -> [UInt8] {
            let body: [UInt8] = [1, 0x80, 0, 0, 0, 0] + Array(name.utf8) + [0] + payload
            return [UInt8(body.count)] + body
        }
        put(0x400 + 12, [1, 0])
        put(0x400 + 20, rec("Birds", [3, 0, 0, 0]))
        put(0x1400 + 20, rec("Birds", [1, 0, 0, 0] + Array("A.PIC".utf8) + [UInt8](repeating: 0, count: 9)))
        check(MediaCatalog.categories(ctg).map(\.pictures) == [["A.PIC"]], "C-Index scan skips index nodes")
        // MEDIA.DBS: Almanac (book 2 → key type 3) entry 7, one map + one video, blob split over two chunks.
        var dbs = Data(count: 0x400 + 4096)
        func put2(_ at: Int, _ b: [UInt8]) { dbs.replaceSubrange(at..<at + b.count, with: b) }
        func le(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func pad(_ s: String, _ n: Int) -> [UInt8] { Array(s.utf8) + [UInt8](repeating: 0, count: n - s.utf8.count) }
        let items: [UInt8] = [1] + pad("Clip", 51) + pad("ASHE.AVI", 14) + [6] + pad("Albania", 51) + le(4242)
        let blob: [UInt8] = [0, 1, 0, 0, 0, 0, 1] + le(11 + items.count) + items
        func chunk(_ flag: UInt8, _ part: ArraySlice<UInt8>) -> [UInt8] {
            let body: [UInt8] = [3, flag] + le(7) + le(3 << 28 | 7) + Array(part)
            return [UInt8(body.count)] + body
        }
        let c0 = chunk(0x00, blob[..<60]), c1 = chunk(0x81, blob[60...])
        put2(0x400 + 20, c0); put2(0x400 + 20 + c0.count, c1)
        let am = MediaCatalog.articleMedia(dbs)
        check(am.count == 1 && am[0].bookCode == 2 && am[0].entry == 7 && am[0].items.map(\.type) == [1, 6]
              && am[0].items[0].file == "ASHE.AVI" && am[0].items[1].filOffset == 4242 && am[0].items[1].label == "Albania",
              "MEDIA.DBS article media, chunked")
        check(Library.distance(Array("teh"), Array("the"), max: 2) == 1 && Library.distance(Array("kitten"), Array("sitting"), max: 3) == 3
              && Library.distance(Array("kitten"), Array("sitting"), max: 2) == nil && Library.distance(Array(""), Array("ab"), max: 2) == 2,
              "spell-check edit distance")
        check(LibraryBuilder.safeName("I0110026.PIC") != nil && LibraryBuilder.safeName("../x.png") == nil
              && LibraryBuilder.safeName("a/b") == nil && LibraryBuilder.safeName("..") == nil, "output names are confined")
    default: usage()
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
