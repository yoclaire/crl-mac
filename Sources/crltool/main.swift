import CRLKit
import Foundation

// crltool — build or inspect a library without the app.
//   crltool import <disc.iso> <library-dir>
//   crltool entry <disc.iso> <book-id> <n>
//   crltool search <library-dir> <query>

let args = CommandLine.arguments
func usage() -> Never {
    print("usage: crltool import <disc.iso> <library-dir> | entry <disc.iso> <book> <n> | search <library-dir> <query>")
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
    case "entry" where args.count == 5:
        let iso = try ISO9660(url: URL(fileURLWithPath: args[2]))
        guard let book = Book.all.first(where: { $0.id == args[3] }), let n = Int(args[4]) else { usage() }
        print(Markup.decode(try REDB(data: iso.contents("CRL/REFDATA/\(book.file)")).entry(n)))
    case "search" where args.count >= 4:
        let lib = try Library(directory: URL(fileURLWithPath: args[2]))
        for hit in try lib.search(args[3...].joined(separator: " "), limit: 20) {
            print("\(hit.book)\t\(hit.num)\t\(hit.title)")
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
    default: usage()
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
