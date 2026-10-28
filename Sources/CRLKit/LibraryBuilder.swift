import Foundation

/// Builds a library directory from the CRL disc image:
///
///     library.sqlite      entries + FTS5 index + media catalogue
///     media/pic/*.jpg     repaired Pegasus JPEGs (photos and maps)
///     media/wav/*.wav     MS-ADPCM pronunciations / sounds (played natively)
///     media/video/*.mp4   Indeo 3 AVIs/ANIs transcoded with ffmpeg (if available)
///     media/midi/*.mid
///     ui/*.png            CRL32.EXE bitmap resources (room artwork), magenta keyed to alpha
///     fonts/CRL_1.TTF     pronunciation font from the disc
public final class LibraryBuilder {
    public let iso: ISO9660
    public let output: URL
    public var progress: (String, Double) -> Void = { _, _ in }
    public var ffmpegPath: String? = LibraryBuilder.findFFmpeg()

    public static let schemaVersion = 1

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
            """)

        try buildText(db)
        let filIndex = try buildMediaFile(db)
        try buildCatalog(db, filIndex: filIndex)
        try buildDiscMedia(db)
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
        var rowid = 0
        for (b, book) in Book.all.enumerated() {
            progress("Reading \(book.title)", Double(b) / Double(Book.all.count) * 0.4)
            let re = try REDB(data: iso.contents("CRL/REFDATA/\(book.file)"))
            try insBook.run(book.id, book.title, re.entryCount, b)
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

    func buildCatalog(_ db: SQLite, filIndex: [Int: String]) throws {
        progress("Reading the media catalogue", 0.72)
        try db.exec("BEGIN")
        let link = try db.prepare("INSERT INTO entry_media VALUES (?, ?, ?, ?, ?)")
        for (entry, items) in MediaCatalog.dictionaryMedia(try iso.contents("CRL/MEDIADB/MEDIA.DBS")) {
            for (k, it) in items.enumerated() {
                guard let name = filIndex[it.filOffset] else { continue }
                try link.run("dictionary", entry, name, it.label, k)
            }
        }
        let codes = Dictionary(uniqueKeysWithValues: Book.all.compactMap { b in b.mediaCode.map { ($0, b.id) } })
        for (name, targets) in MediaCatalog.links(try iso.contents("CRL/MEDIADB/MEDIA.LNK")) {
            for (k, t) in targets.enumerated() {
                guard let book = codes[t.db] else { continue }
                try link.run(book, t.entry, name, nil, 100 + k)
            }
        }
        let cap = try db.prepare("UPDATE media SET caption = ? WHERE name = ?")
        for (name, c) in MediaCatalog.captions(try iso.contents("CRL/MEDIADB/MEDIA.UTL"), validOffsets: filIndex) { try cap.run(c, name) }
        try linkMaps(db)
        let cat = try db.prepare("INSERT INTO categories VALUES (?, ?, ?)"), item = try db.prepare("INSERT INTO category_items VALUES (?, ?, ?)")
        for (k, c) in MediaCatalog.categories(try iso.contents("CRL/MEDIADB/MEDIA.CTG")).enumerated() {
            try cat.run(c.name, "picture", k)
            for (j, p) in c.pictures.enumerated() { try item.run(c.name, p, j) }
        }
        try db.exec("COMMIT")
    }

    /// Maps carry no catalogue links (none in DBS/LNK, none in the text), so they are matched by
    /// name: the 8-character stem (AFGHANIS.MAP) against article titles. This is an inference, not
    /// recovered behaviour — see docs/FORMATS.md.
    func linkMaps(_ db: SQLite) throws {
        let maps = try db.rows("SELECT name FROM media WHERE kind = 'map'") { $0.string(0)! }
        func key(_ t: String) -> String {
            t.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).uppercased().filter { $0.isLetter }
        }
        var titles: [(book: String, num: Int, title: String, key: String)] = []
        for book in ["encyclopedia", "almanac", "dictionary"] {
            titles += try db.rows("SELECT num, title FROM entries WHERE book = ? AND continuation = 0 AND length(title) < 40", book) {
                (book, $0.int(0), $0.string(1)!, key($0.string(1)!))
            }
        }
        var byPrefix: [String: [(book: String, num: Int, title: String, key: String)]] = [:]
        for t in titles where t.key.count >= 4 { byPrefix[String(t.key.prefix(8)), default: []].append(t) }
        let link = try db.prepare("INSERT INTO entry_media VALUES (?, ?, ?, NULL, ?)")
        let cap = try db.prepare("UPDATE media SET caption = ? WHERE name = ?")
        for m in maps {
            let raw = (m as NSString).deletingPathExtension.uppercased()
            let stem = key(Self.mapAliases[raw] ?? raw)
            let alias = Self.mapAliases[raw] != nil
            guard let cands = byPrefix[String(stem.prefix(8))]?.filter({ !alias || $0.key == stem || $0.key.hasPrefix(stem) }),
                  !cands.isEmpty else { continue }
            // Shortest matching title per book ("Afghanistan" over "Afghanistan War").
            var best: [String: (num: Int, title: String)] = [:]
            for c in cands where best[c.book].map({ c.title.count < $0.title.count }) ?? true { best[c.book] = (c.num, c.title) }
            for (book, b) in best { try link.run(book, b.num, m, 50) }
            if let caption = best["encyclopedia"]?.title ?? best["almanac"]?.title ?? Self.mapAliases[raw] { try cap.run(caption, m) }
        }
    }

    /// Map names that are abbreviations rather than truncations.
    static let mapAliases: [String: String] = [
        "MACAU": "Macao", "MALDIVE": "Maldives", "NORKOREA": "Korea, North", "SOUKOREA": "Korea, South",
        "BOSNHERZ": "Bosnia and Herzegovina", "UK": "United Kingdom", "VATICAN": "Vatican City", "BURKINA": "Burkina Faso",
        "CAF": "Central African Republic", "EQUAGUIN": "Equatorial Guinea", "GUINBISS": "Guinea-Bissau", "IVORYCOA": "Côte d'Ivoire",
        "SAOTOMEP": "São Tomé and Príncipe", "SIERRAL": "Sierra Leone", "ANTIBARB": "Antigua and Barbuda", "BRVIRGIS": "British Virgin Islands",
        "CAYMAN": "Cayman Islands", "DOMREPUB": "Dominican Republic", "NETHANTI": "Netherlands Antilles", "STKITTSN": "Saint Kitts and Nevis",
        "TURKSCAI": "Turks and Caicos Islands", "FALKISLA": "Falkland Islands", "FRENGUIA": "French Guiana", "KYRGYSTA": "Kyrgyzstan",
        "FRENPOLY": "French Polynesia", "NMARIANA": "Northern Mariana Islands", "WSAMOA": "Western Samoa", "US": "United States",
        "ANTARCT": "Antarctica", "UNITEDAE": "United Arab Emirates", "MEMPHIS": "Memphis", "PORTLANM": "Portland",
        "PORTLANO": "Portland", "STLOUIS": "Saint Louis", "WASHINDC": "Washington, D.C.",
        "AK": "Alaska", "AL": "Alabama", "AR": "Arkansas", "AZ": "Arizona", "CA": "California", "CO": "Colorado", "CT": "Connecticut",
        "DE": "Delaware", "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "IA": "Iowa", "IN": "Indiana", "ID": "Idaho", "IL": "Illinois",
        "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "MA": "Massachusetts", "MD": "Maryland", "ME": "Maine", "MI": "Michigan",
        "MN": "Minnesota", "MO": "Missouri", "MS": "Mississippi", "MT": "Montana", "NC": "North Carolina", "ND": "North Dakota",
        "NE": "Nebraska", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NV": "Nevada", "NY": "New York", "OH": "Ohio",
        "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
        "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VA": "Virginia", "VT": "Vermont", "WA": "Washington", "WI": "Wisconsin",
        "WV": "West Virginia", "WY": "Wyoming",
    ]

    // MARK: video / music

    func buildDiscMedia(_ db: SQLite) throws {
        let midi = try dir("media/midi"), video = try dir("media/video")
        let ins = try db.prepare("INSERT OR REPLACE INTO media VALUES (?, ?, ?, ?, NULL, NULL)")
        for f in try iso.files(in: "CRL/MUSIC") where f.name.hasSuffix(".MID") && Self.safeName(f.name) != nil {
            try iso.read(f, offset: 0, count: f.size).write(to: midi.appendingPathComponent(f.name.lowercased()))
            try ins.run(f.name, "music", "media/midi/\(f.name.lowercased())", nil)
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
