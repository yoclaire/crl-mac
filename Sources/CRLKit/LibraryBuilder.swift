import Foundation

/// Builds a library directory from the CRL disc image:
///
///     library.sqlite      entries + FTS5 index + media catalogue
///     media/pic/*.jpg     repaired Pegasus JPEGs (photos and maps)
///     media/wav/*.wav     MS-ADPCM pronunciations / sounds (played natively)
///     media/video/*.mp4   Indeo 3 AVIs/ANIs transcoded with ffmpeg (if available)
///     media/music/*        the MUSIC folder's clips: despite the .MID names they are RIFF WAVE
///                          (MS-ADPCM) recordings, stored under the extension matching their content
///     ui/*.png            CRL32.EXE bitmap resources (room artwork), magenta keyed to alpha
///     fonts/CRL_1.TTF     pronunciation font from the disc
public final class LibraryBuilder {
    public let iso: ISO9660
    public let output: URL
    public var progress: (String, Double) -> Void = { _, _ in }
    public var ffmpegPath: String? = LibraryBuilder.findFFmpeg()

    public static let schemaVersion = 2   // 2: help_topics, toc

    public init(isoURL: URL, output: URL) throws {
        iso = try ISO9660(url: isoURL)
        self.output = output
    }

    public static func findFFmpeg() -> String? {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] + env.split(separator: ":").map(String.init)
        return dirs.map { "\($0)/ffmpeg" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Every output file name comes from the disc image, so only plain DOS-style names are accepted
    /// (letters, digits, '_' and '-', optional 1-3 character extension). Anything else is skipped,
    /// which keeps a crafted image from writing outside the library directory.
    public static func safeName(_ name: String) -> String? {
        let ok = name.range(of: #"^[A-Za-z0-9_-]{1,16}(\.[A-Za-z0-9]{1,3})?$"#, options: .regularExpression) != nil
        return ok ? name : nil
    }

    func dir(_ path: String) throws -> URL {
        let u = output.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    public func build() throws {
        guard (try? iso.entry("CRL/REFDATA")) != nil else {
            throw CRLError.missing("this disc image is not the Complete Reference Library (no CRL/REFDATA)")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Rebuilding over an old library: clear only the subdirectories this builder owns.
        for sub in ["media", "ui", "fonts"] { try? FileManager.default.removeItem(at: output.appendingPathComponent(sub)) }
        let dbURL = output.appendingPathComponent("library.sqlite.partial")
        try? FileManager.default.removeItem(at: dbURL)
        let db = try SQLite(path: dbURL.path)
        try db.exec("""
            PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE books(id TEXT PRIMARY KEY, title TEXT, entries INTEGER, ord INTEGER);
            CREATE TABLE entries(rowid INTEGER PRIMARY KEY, book TEXT, num INTEGER, title TEXT, sort TEXT,
                                 continuation INTEGER, first INTEGER, last INTEGER, markup TEXT);
            CREATE UNIQUE INDEX entries_key ON entries(book, num);
            CREATE INDEX entries_title ON entries(book, continuation, sort);
            CREATE VIRTUAL TABLE fts USING fts5(title, body, content='', tokenize='unicode61 remove_diacritics 2');
            CREATE TABLE media(name TEXT PRIMARY KEY, kind TEXT, path TEXT, caption TEXT, width INTEGER, height INTEGER);
            CREATE TABLE entry_media(book TEXT, num INTEGER, media TEXT, label TEXT, ord INTEGER);
            CREATE INDEX entry_media_key ON entry_media(book, num);
            CREATE TABLE categories(name TEXT, kind TEXT, ord INTEGER);
            CREATE TABLE category_items(category TEXT, media TEXT, ord INTEGER);
            CREATE TABLE help_topics(ord INTEGER PRIMARY KEY, title TEXT, body TEXT);
            CREATE TABLE toc(book TEXT, ord INTEGER, title TEXT, level INTEGER, first INTEGER, last INTEGER,
                             PRIMARY KEY (book, ord));
            """)

        try buildText(db)
        let filIndex = try buildMediaFile(db)
        try buildCatalog(db, filIndex: filIndex)
        try buildDiscMedia(db)
        try nameAndGroupMedia(db)
        try buildHelp(db)
        try buildUI()

        try db.prepare("INSERT INTO meta VALUES (?, ?)").run("schema", "\(Self.schemaVersion)")
        try db.prepare("INSERT INTO meta VALUES (?, ?)").run("volume", try iso.volumeLabel())
        try db.exec("INSERT INTO fts(fts) VALUES('optimize')")
        let final = output.appendingPathComponent("library.sqlite")
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: dbURL, to: final)
        progress("Done", 1)
    }

    // MARK: text

    func buildText(_ db: SQLite) throws {
        try db.exec("BEGIN")
        let insBook = try db.prepare("INSERT INTO books VALUES (?, ?, ?, ?)")
        let ins = try db.prepare("INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        let fts = try db.prepare("INSERT INTO fts(rowid, title, body) VALUES (?, ?, ?)")
        let toc = try db.prepare("INSERT INTO toc VALUES (?, ?, ?, ?, ?, ?)")
        var rowid = 0
        for (b, book) in Book.all.enumerated() {
            progress("Reading \(book.title)", Double(b) / Double(Book.all.count) * 0.4)
            let re = try REDB(data: iso.contents("CRL/REFDATA/\(book.file)"))
            try insBook.run(book.id, book.title, re.entryCount, b)
            for (k, n) in re.tableOfContents(isDictionary: book.id == "dictionary").enumerated() {
                try toc.run(book.id, k, n.title, n.level, n.first, n.last)
            }
            try re.allEntries { n, bytes in
                let s = Markup.decode(bytes)
                let (title, cont) = Markup.title(s)
                let span = Markup.span(s)
                rowid += 1
                try ins.run(rowid, book.id, n, title, title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil),
                            cont ? 1 : 0, span?.first, span?.last, s)
                try fts.run(rowid, cont ? "" : title, Markup.plain(s))
            }
        }
        try db.exec("COMMIT")
    }

    // MARK: MEDIA.FIL

    func buildMediaFile(_ db: SQLite) throws -> [Int: String] {
        let fil = try iso.entry("CRL/MEDIADB/MEDIA.FIL")
        let records = try MediaFile.records(fileSize: fil.size) { try iso.read(fil, offset: $0, count: $1) }
        let pics = try dir("media/pic"), wavs = try dir("media/wav")
        let ins = try db.prepare("INSERT OR REPLACE INTO media VALUES (?, ?, ?, NULL, ?, ?)")
        var byOffset: [Int: String] = [:]
        try db.exec("BEGIN")
        for (i, r) in records.enumerated() {
            if i % 200 == 0 { progress("Extracting pictures and sounds", 0.4 + 0.3 * Double(i) / Double(records.count)) }
            byOffset[r.offset] = r.name
            guard let safe = Self.safeName(r.name) else { continue }
            let blob = try iso.read(fil, offset: r.dataOffset, count: r.size)
            let stem = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension.uppercased()
            switch ext {
            case "WAV":
                try blob.write(to: wavs.appendingPathComponent("\(stem).wav"))
                try ins.run(r.name, "sound", "media/wav/\(stem).wav", nil, nil)
            case "PIC", "MAP":
                let p = try MediaFile.picture(blob)
                try p.jpeg.write(to: pics.appendingPathComponent("\(stem).jpg"))
                try ins.run(r.name, ext == "MAP" ? "map" : "picture", "media/pic/\(stem).jpg", p.width, p.height)
            default: break
            }
        }
        try db.exec("COMMIT")
        return byOffset
    }

    // MARK: catalogue

    /// CRL32.HLP's text help (the "Text" half of the room's "Text and Video Help"). Bodies keep
    /// HelpFile's link and bold markers; the app renders them.
    func buildHelp(_ db: SQLite) throws {
        progress("Reading the help", 0.96)
        let add = try db.prepare("INSERT INTO help_topics VALUES (?, ?, ?)")
        for (k, t) in try HelpFile.topics(try iso.contents("CRL/CRL32.HLP")).enumerated() { try add.run(k, t.title, t.body) }
    }

    func buildCatalog(_ db: SQLite, filIndex: [Int: String]) throws {
        progress("Reading the media catalogue", 0.72)
        try db.exec("BEGIN")
        let link = try db.prepare("INSERT INTO entry_media VALUES (?, ?, ?, ?, ?)")
        let codes = Dictionary(uniqueKeysWithValues: Book.all.compactMap { b in b.mediaCode.map { ($0, b.id) } })
        // MEDIA.DBS is what CRL32 itself consults for an article's media (all kinds, maps included).
        var linked = Set<String>()
        for rec in MediaCatalog.articleMedia(try iso.contents("CRL/MEDIADB/MEDIA.DBS")) {
            guard let book = codes[rec.bookCode] else { continue }
            for (k, it) in rec.items.enumerated() {
                guard let name = it.filOffset.flatMap({ filIndex[$0] }) ?? it.file?.uppercased() else { continue }
                guard linked.insert("\(book)/\(rec.entry)/\(name)").inserted else { continue }
                try link.run(book, rec.entry, name, it.label.isEmpty ? nil : it.label, k)
            }
        }
        // MEDIA.LNK is the reverse index (media → articles) behind the Media Library's Related Articles;
        // it should agree with DBS, so it only adds links DBS lacks.
        for (name, targets) in MediaCatalog.links(try iso.contents("CRL/MEDIADB/MEDIA.LNK")) {
            for (k, t) in targets.enumerated() {
                guard let book = codes[t.db], linked.insert("\(book)/\(t.entry)/\(name)").inserted else { continue }
                try link.run(book, t.entry, name, nil, 100 + k)
            }
        }
        let cap = try db.prepare("UPDATE media SET caption = ? WHERE name = ?")
        for (name, c) in MediaCatalog.captions(try iso.contents("CRL/MEDIADB/MEDIA.UTL"), validOffsets: filIndex) { try cap.run(c, name) }
        let cat = try db.prepare("INSERT INTO categories VALUES (?, ?, ?)"), item = try db.prepare("INSERT INTO category_items VALUES (?, ?, ?)")
        for (k, c) in MediaCatalog.categories(try iso.contents("CRL/MEDIADB/MEDIA.CTG")).enumerated() {
            try cat.run(c.name, "picture", k)
            // (ord continues in nameAndGroupMedia)
            for (j, p) in c.pictures.enumerated() { try item.run(c.name, p, j) }
        }
        try db.exec("COMMIT")
    }

    // MARK: Media Library names and categories

    /// MEDIA.UTL holds authored captions for every kind (pictures, maps, videos, animations, music,
    /// pronunciations) and MEDIA.CTG the photo categories. Items the disc leaves uncaptioned (a few music
    /// clips and animations) get a name derived from the disc's own data, and kinds without categories
    /// get a grouping, so the Media Library never shows raw 8.3 file names:
    /// - pronunciations: the word from MEDIA.DBS, grouped A–Z
    /// - music: the first article MEDIA.LNK links it to; 500xxxx = instruments, 60xxx = styles
    /// - video/animation: the linked article whose title matches the file name, else the first link
    /// - maps: MEDIA.FIL stores them in one alphabetical run per region; each run is a category
    /// - photos in no MEDIA.CTG category: "Other Pictures"
    func nameAndGroupMedia(_ db: SQLite) throws {
        progress("Indexing the Media Library", 0.955)
        try db.exec("BEGIN")
        let setCaption = try db.prepare("UPDATE media SET caption = ? WHERE name = ? AND (caption IS NULL OR caption = '')")
        // Videos, animations and music only exist as rows once buildDiscMedia has run, after the catalogue
        // pass, so apply their MEDIA.UTL captions here, before any name is inferred. (No FIL offsets: the
        // picture/map captions, which need them, were applied in buildCatalog.)
        for (name, c) in MediaCatalog.captions(try iso.contents("CRL/MEDIADB/MEDIA.UTL"), validOffsets: [:]) {
            try setCaption.run(c, name)
        }
        let addCategory = try db.prepare("INSERT INTO categories VALUES (?, ?, ?)")
        let addItem = try db.prepare("INSERT INTO category_items VALUES (?, ?, ?)")
        var order = try db.rows("SELECT COALESCE(MAX(ord), 0) FROM categories") { $0.int(0) }.first ?? 0
        func category(_ name: String, _ kind: String, _ members: [String]) throws {
            guard !members.isEmpty else { return }
            order += 1
            try addCategory.run(name, kind, order)
            for (k, m) in members.enumerated() { try addItem.run(name, m, k) }
        }
        func capitalized(_ t: String) -> String { t.prefix(1).uppercased() + t.dropFirst() }
        func key(_ t: String) -> String { t.uppercased().filter { $0.isLetter || $0.isNumber } }

        // Pronunciations
        let words = try db.rows("""
            SELECT media, MIN(label) FROM entry_media WHERE book = 'dictionary' AND media LIKE '%.WAV' AND label != '' GROUP BY media
            """) { ($0.string(0)!, $0.string(1)!) }
        for (m, w) in words { try setCaption.run(w, m) }
        var byLetter: [String: [String]] = [:]
        for (m, w) in words {
            let c = w.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).first.map { String($0).uppercased() } ?? "#"
            byLetter[c.first!.isLetter ? c : "#", default: []].append(m)
        }
        for letter in byLetter.keys.sorted() { try category(letter, "sound", byLetter[letter]!) }
        // Recordings no dictionary entry refers to: listed rather than hidden.
        let orphans = try db.rows("""
            SELECT name FROM media WHERE kind = 'sound' AND name NOT IN (SELECT media FROM entry_media) ORDER BY name
            """) { $0.string(0)! }
        for m in orphans { try setCaption.run("Recording \((m as NSString).deletingPathExtension)", m) }
        try category("Unlabelled", "sound", orphans)

        // Music, video, animation: names from the article links
        for kind in ["music", "video", "animation"] {
            let items = try db.rows("SELECT name FROM media WHERE kind = ? AND path IS NOT NULL ORDER BY name", kind) { $0.string(0)! }
            var groups: [String: [String]] = [:]
            for m in items {
                let links = try db.rows("""
                    SELECT e.book, e.title FROM entry_media em JOIN entries e ON e.book = em.book AND e.num = em.num
                    WHERE em.media = ? ORDER BY em.ord
                    """, m) { ($0.string(0)!, $0.string(1)!.replacingOccurrences(of: #" \[\d+\]$"#, with: "", options: .regularExpression)) }
                let stem = key((m as NSString).deletingPathExtension)
                let pick = links.first { key($0.1).hasPrefix(stem) || (stem.count >= 4 && key($0.1).hasPrefix(String(stem.prefix(5)))) }
                    ?? (kind == "music" ? links.first : links.first { $0.0 == "encyclopedia" } ?? links.first)
                let number = (m as NSString).deletingPathExtension
                let caption = pick.map { capitalized($0.1) } ?? (kind == "music" ? "Music \(number)" : capitalized(number.lowercased()))
                try setCaption.run(caption, m)
                let group = kind == "music" ? (number.hasPrefix("500") ? "Instruments" : "Musical Styles")
                                            : (kind == "video" ? "All Videos" : "All Animations")
                groups[group, default: []].append(m)
            }
            for g in groups.keys.sorted() { try category(g, kind, groups[g]!) }
            // Several clips can link to the same article ("Bass" ×3): number the repeats.
            let dupes = try db.rows("""
                SELECT name, caption FROM media WHERE kind = ? AND caption IN
                  (SELECT caption FROM media WHERE kind = ? GROUP BY caption HAVING COUNT(*) > 1) ORDER BY caption, name
                """, kind, kind) { ($0.string(0)!, $0.string(1)!) }
            let renumber = try db.prepare("UPDATE media SET caption = ? WHERE name = ?")
            var seen: [String: Int] = [:]
            for (m, c) in dupes {
                seen[c, default: 0] += 1
                if seen[c]! > 1 { try renumber.run("\(c) \(seen[c]!)", m) }
            }
        }

        // Maps: one alphabetical run per region in MEDIA.FIL order (media rows were inserted in that order)
        let maps = try db.rows("SELECT name FROM media WHERE kind = 'map' ORDER BY rowid") { $0.string(0)! }
        var runs: [[String]] = []
        for m in maps {
            if let last = runs.last?.last, m >= last { runs[runs.count - 1].append(m) } else { runs.append([m]) }
        }
        var regions: [(String, [String])] = []
        for run in runs {
            let stems = Set(run.map { ($0 as NSString).deletingPathExtension })
            let name = Self.mapRegions.first { !stems.isDisjoint(with: $0.members) }?.name ?? "Maps"
            if let i = regions.firstIndex(where: { $0.0 == name }) { regions[i].1 += run } else { regions.append((name, run)) }
        }
        for (name, members) in regions { try category(name, "map", members) }

        // Photos outside every MEDIA.CTG category
        let loose = try db.rows("""
            SELECT name FROM media WHERE kind = 'picture' AND name NOT IN (SELECT media FROM category_items)
            """) { $0.string(0)! }
        try category("Other Pictures", "picture", loose)
        try db.exec("COMMIT")
    }

    /// Region names for the map runs, keyed by a few members of each run (names are ours; the disc
    /// only implies the grouping).
    static let mapRegions: [(name: String, members: Set<String>)] = [
        ("Asia", ["AFGHANIS", "CHINA", "JAPAN"]), ("Europe", ["ALBANIA", "FRANCE", "GERMANY"]),
        ("Africa", ["ALGERIA", "KENYA", "NIGERIA"]), ("Caribbean", ["ANGUILLA", "CUBA", "JAMAICA"]),
        ("South America", ["ARGENTIN", "BRAZIL", "PERU"]), ("Former Soviet Republics", ["ARMENIA", "RUSSIA", "UKRAINE"]),
        ("Australia and Oceania", ["AUSTRALI", "FIJI", "NEWZEALA"]), ("Central America", ["BELIZE", "MEXICO", "PANAMA"]),
        ("North America and the Arctic", ["CANADA", "US", "ARCTIC"]), ("Middle East", ["BAHRAIN", "EGYPT", "ISRAEL"]),
        ("U.S. Cities", ["ALBUQUER", "BOSTON", "CHICAGO"]), ("U.S. States", ["AK", "CA", "NY", "ID", "TX"]),
    ]

    // MARK: video / music

    func buildDiscMedia(_ db: SQLite) throws {
        let music = try dir("media/music"), video = try dir("media/video")
        let ins = try db.prepare("INSERT OR REPLACE INTO media VALUES (?, ?, ?, ?, NULL, NULL)")
        for f in try iso.files(in: "CRL/MUSIC") where f.name.hasSuffix(".MID") && Self.safeName(f.name) != nil {
            let data = try iso.read(f, offset: 0, count: f.size)
            // The disc names them .MID, but they are WAVE audio; keep real MIDI (MThd) as .mid.
            let ext = data.prefix(4) == Data("MThd".utf8) ? "mid" : "wav"
            let file = "\((f.name as NSString).deletingPathExtension.lowercased()).\(ext)"
            try data.write(to: music.appendingPathComponent(file))
            try ins.run(f.name, "music", "media/music/\(file)", nil)
        }
        let clips = try [("CRL/VIDEOS", "video"), ("CRL/ANIMATE", "animation"), ("CRL/HELP", "help")].flatMap { path, kind in
            try iso.files(in: path).filter { Self.safeName($0.name) != nil }.map { (path, kind, $0) }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("crl-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for (i, (_, kind, f)) in clips.enumerated() {
            progress("Converting video \(i + 1) of \(clips.count)", 0.75 + 0.2 * Double(i) / Double(clips.count))
            let stem = (f.name as NSString).deletingPathExtension.lowercased()
            let dest = video.appendingPathComponent("\(stem).mp4")
            var path: String? = nil
            if let ffmpeg = ffmpegPath {
                let src = tmp.appendingPathComponent(f.name)
                try iso.read(f, offset: 0, count: f.size).write(to: src)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffmpeg)
                p.arguments = ["-v", "error", "-y", "-i", src.path, "-c:v", "h264_videotoolbox", "-b:v", "1200k",
                               "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", dest.path]
                try p.run(); p.waitUntilExit()
                try? FileManager.default.removeItem(at: src)
                if p.terminationStatus == 0 { path = "media/video/\(stem).mp4" }
            }
            try ins.run(f.name, kind, path, nil)
        }
    }

    // MARK: UI artwork

    func buildUI() throws {
        progress("Unpacking the reading room", 0.96)
        let ui = try dir("ui")
        let exe = try iso.contents("CRL/CRL32.EXE")
        for r in try PEResources.resources(exe) where r.type == 2 {
            guard let name = Self.safeName(r.id.map(String.init) ?? r.name ?? "") else { continue }
            let opaque = [271, 272, 308, 436, 437, 477, 478, 479, 480, 481].contains(r.id ?? -1)
            try PEResources.png(fromDIB: r.data, keyMagenta: !opaque).write(to: ui.appendingPathComponent("\(name).png"))
        }
        let sounds = try dir("ui/sounds")
        for f in try iso.files(in: "CRL") where f.name.hasSuffix(".WAV") {
            guard let name = Self.safeName(f.name.lowercased()) else { continue }
            try iso.read(f, offset: 0, count: f.size).write(to: sounds.appendingPathComponent(name))
        }
        let fonts = try dir("fonts")
        try iso.contents("CRL/CRL_1.TTF").write(to: fonts.appendingPathComponent("CRL_1.TTF"))
    }
}
