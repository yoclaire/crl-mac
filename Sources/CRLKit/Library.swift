import Foundation

/// Read-only access to a built library directory.
public final class Library: @unchecked Sendable {
    public let directory: URL
    let db: SQLite

    public struct Subject: Hashable, Sendable {
        public let book: String; public let num: Int; public let title: String
        public init(book: String, num: Int, title: String) { self.book = book; self.num = num; self.title = title }
    }
    public struct Article: Sendable {
        public let book: String
        public let num: Int
        public let title: String
        public let parts: [String]          // markup of each entry in the article span
        public let media: [MediaRef]
    }
    public struct MediaRef: Hashable, Sendable {
        public let name: String, kind: String, path: String?, caption: String?, label: String?
        public let width: Int?, height: Int?
    }

    public init(directory: URL) throws {
        self.directory = directory
        db = try SQLite(path: directory.appendingPathComponent("library.sqlite").path, readOnly: true)
    }

    public static func isBuilt(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("library.sqlite").path)
    }

    public func url(_ relative: String) -> URL { directory.appendingPathComponent(relative) }

    /// Subject List rows for a book (continuation sections of multi-entry articles are hidden).
    public func subjects(book: String) throws -> [Subject] {
        // The thesaurus is stored in category order; its list is alphabetical like the others.
        let order = book == "thesaurus" ? "sort, num" : "num"
        return try db.rows("SELECT num, title FROM entries WHERE book = ? AND continuation = 0 AND title != '' ORDER BY \(order)", book) {
            Subject(book: book, num: $0.int(0), title: $0.string(1) ?? "")
        }
    }

    public func article(book: String, num: Int) throws -> Article? {
        guard let head = try db.rows("SELECT title, first, last, markup FROM entries WHERE book = ? AND num = ?", book, num, map: {
            ($0.string(0) ?? "", $0.string(1).flatMap(Int.init), $0.string(2).flatMap(Int.init), $0.string(3) ?? "")
        }).first else { return nil }
        var parts = [head.3]
        if let first = head.1, let last = head.2, first == num, last > first {
            parts = try db.rows("SELECT markup FROM entries WHERE book = ? AND num BETWEEN ? AND ? ORDER BY num", book, first, last) {
                $0.string(0) ?? ""
            }
        }
        let media = try db.rows("""
            SELECT m.name, m.kind, m.path, m.caption, em.label, m.width, m.height FROM entry_media em
            JOIN media m ON m.name = em.media WHERE em.book = ? AND em.num BETWEEN ? AND ? ORDER BY em.ord
            """, book, num, head.2 ?? num) {
            MediaRef(name: $0.string(0)!, kind: $0.string(1)!, path: $0.string(2), caption: $0.string(3), label: $0.string(4),
                     width: $0.string(5).flatMap(Int.init), height: $0.string(6).flatMap(Int.init))
        }
        return Article(book: book, num: num, title: head.0, parts: parts, media: media)
    }

    public struct Hit: Hashable, Sendable {
        public let book: String; public let num: Int; public let title: String
        public init(book: String, num: Int, title: String) { self.book = book; self.num = num; self.title = title }
    }

    /// Full-text search across every book; titles rank first.
    public func search(_ query: String, book: String? = nil, limit: Int = 200) throws -> [Hit] {
        try search(query, books: book.map { [$0] }, limit: limit)
    }

    /// Full-text search over the given books (nil = all); titles rank first.
    public func search(_ query: String, books: [String]?, limit: Int = 200) throws -> [Hit] {
        let only = books.map { "," + $0.joined(separator: ",") + "," }
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
        guard !terms.isEmpty else { return [] }
        let match = terms.joined(separator: " ")
        // Each hit is the head of its article (continuation sections fold into their parent).
        return try db.rows("""
            WITH ranked AS (SELECT rowid, bm25(fts, 10.0, 1.0) AS score FROM fts WHERE fts MATCH ? ORDER BY score LIMIT 5000)
            SELECT e.book, COALESCE(CASE WHEN e.continuation = 1 THEN e.first END, e.num) AS head, h.title
            FROM ranked JOIN entries e ON e.rowid = ranked.rowid
            JOIN entries h ON h.book = e.book AND h.num = COALESCE(CASE WHEN e.continuation = 1 THEN e.first END, e.num)
            WHERE (? IS NULL OR instr(?, ',' || e.book || ',') > 0)
            GROUP BY e.book, head ORDER BY MIN(ranked.score) LIMIT ?
            """, match, only, only, limit) {
            Hit(book: $0.string(0)!, num: $0.int(1), title: $0.string(2) ?? "")
        }
    }

    /// Entries whose title starts with the prefix, for the Index's type-ahead.
    public func titles(prefix: String, book: String?, limit: Int = 300) throws -> [Hit] {
        try titles(prefix: prefix, books: book.map { [$0] }, limit: limit)
    }

    /// Entries whose title starts with the prefix, in the given books (nil = all).
    public func titles(prefix: String, books: [String]?, limit: Int = 300) throws -> [Hit] {
        let key = prefix.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let only = books.map { "," + $0.joined(separator: ",") + "," }
        return try db.rows("""
            SELECT book, num, title FROM entries WHERE continuation = 0 AND title != '' AND sort >= ? AND sort < ?
            AND (? IS NULL OR instr(?, ',' || book || ',') > 0) ORDER BY sort LIMIT ?
            """, key, key + "\u{10FFFF}", only, only, limit) {
            Hit(book: $0.string(0)!, num: $0.int(1), title: $0.string(2) ?? "")
        }
    }

    public func media(kind: String) throws -> [MediaRef] {
        try db.rows("SELECT name, kind, path, caption, width, height FROM media WHERE kind = ? ORDER BY COALESCE(caption, name)", kind) {
            MediaRef(name: $0.string(0)!, kind: $0.string(1)!, path: $0.string(2), caption: $0.string(3), label: nil,
                     width: $0.string(4).flatMap(Int.init), height: $0.string(5).flatMap(Int.init))
        }
    }

    /// Spell Check for a failed search, as CRL32's Quick/Full Text Search failure dialogs offer: dictionary
    /// headwords within a small edit distance of the word, closest first.
    public func suggestions(for word: String, limit: Int = 20) -> [Hit] {
        let fold = { (t: String) in Array(t.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
        let q = fold(word.trimmingCharacters(in: .whitespaces))
        guard q.count >= 2 else { return [] }
        let maxDistance = q.count <= 4 ? 1 : 2
        var scored: [(d: Int, hit: Hit)] = [], seen = Set<String>()
        for h in headwords() {
            let t = fold(h.title)
            guard abs(t.count - q.count) <= maxDistance, let d = Self.distance(q, t, max: maxDistance), d > 0 || t != q else { continue }
            guard seen.insert(h.title.lowercased()).inserted else { continue }
            scored.append((d, h))
        }
        return scored.sorted { ($0.d, abs($0.hit.title.count - q.count), $0.hit.title) < ($1.d, abs($1.hit.title.count - q.count), $1.hit.title) }
            .prefix(limit).map(\.hit)
    }

    private let headwordLock = NSLock()
    private var headwordCache: [Hit]?
    private func headwords() -> [Hit] {
        headwordLock.lock(); defer { headwordLock.unlock() }
        if let h = headwordCache { return h }
        let h = (try? db.rows("SELECT num, title FROM entries WHERE book = 'dictionary' AND continuation = 0 AND title != ''") {
            Hit(book: "dictionary", num: $0.int(0), title: $0.string(1)!)
        }) ?? []
        headwordCache = h
        return h
    }

    /// Optimal-string-alignment distance (adjacent swaps count once), or nil once it exceeds `limit`.
    public static func distance(_ a: [Character], _ b: [Character], max limit: Int) -> Int? {
        if a == b { return 0 }
        if a.isEmpty || b.isEmpty { let d = Swift.max(a.count, b.count); return d <= limit ? d : nil }
        var prev2 = [Int](repeating: 0, count: b.count + 1), prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            var rowMin = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { cur[j] = Swift.min(cur[j], prev2[j - 2] + 1) }
                rowMin = Swift.min(rowMin, cur[j])
            }
            if rowMin > limit { return nil }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[b.count] <= limit ? prev[b.count] : nil
    }

    /// The disc's text help topics in file order (empty for libraries built before schema 2).
    /// Bodies carry `HelpFile`'s link and bold markers.
    public func helpTopics() -> [(title: String, body: String)] {
        (try? db.rows("SELECT title, body FROM help_topics ORDER BY ord") { ($0.string(0)!, $0.string(1)!) }) ?? []
    }

    /// A book's Table of Contents outline (pre-order; empty for books without one, or for libraries
    /// built before schema 2).
    public func tableOfContents(book: String) -> [REDB.TOCNode] {
        (try? db.rows("SELECT title, level, first, last FROM toc WHERE book = ? ORDER BY ord", book) {
            REDB.TOCNode(title: $0.string(0)!, level: $0.int(1), first: $0.int(2), last: $0.int(3))
        }) ?? []
    }

    /// Media Library categories for one media kind. Photo categories are alphabetical with
    /// "Other Pictures" last; derived groupings (map regions, A–Z) keep their build order.
    public func categories(kind: String) throws -> [String] {
        let order = kind == "picture" ? "name = 'Other Pictures', name" : "ord"
        return try db.rows("SELECT name FROM categories WHERE kind = ? ORDER BY \(order)", kind) { $0.string(0)! }
    }

    public func media(inCategory c: String, kind: String) throws -> [MediaRef] {
        try db.rows("""
            SELECT m.name, m.kind, m.path, m.caption, m.width, m.height FROM category_items ci JOIN media m ON m.name = ci.media
            WHERE ci.category = ? AND m.kind = ? AND m.path IS NOT NULL ORDER BY COALESCE(m.caption, m.name) COLLATE NOCASE
            """, c, kind) {
            MediaRef(name: $0.string(0)!, kind: $0.string(1)!, path: $0.string(2), caption: $0.string(3), label: nil,
                     width: $0.string(4).flatMap(Int.init), height: $0.string(5).flatMap(Int.init))
        }
    }

    /// Articles that link to a media file (for the Media Library's "Related Articles").
    public func articles(linking media: String) throws -> [Hit] {
        try db.rows("""
            SELECT em.book, em.num, e.title FROM entry_media em JOIN entries e ON e.book = em.book AND e.num = em.num
            WHERE em.media = ? ORDER BY em.book
            """, media) { Hit(book: $0.string(0)!, num: $0.int(1), title: $0.string(2) ?? "") }
    }
}
