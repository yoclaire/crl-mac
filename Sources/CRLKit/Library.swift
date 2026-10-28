import Foundation

/// Read-only access to a built library directory.
public final class Library: @unchecked Sendable {
    public let directory: URL
    let db: SQLite

    public struct Subject: Hashable, Sendable { public let book: String; public let num: Int; public let title: String }
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
        try db.rows("SELECT num, title FROM entries WHERE book = ? AND continuation = 0 AND title != '' ORDER BY num", book) {
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

    public struct Hit: Hashable, Sendable { public let book: String; public let num: Int; public let title: String }

    /// Full-text search across every book; titles rank first.
    public func search(_ query: String, book: String? = nil, limit: Int = 200) throws -> [Hit] {
        let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
        guard !terms.isEmpty else { return [] }
        let match = terms.joined(separator: " ")
        // Each hit is the head of its article (continuation sections fold into their parent).
        return try db.rows("""
            WITH ranked AS (SELECT rowid, bm25(fts, 10.0, 1.0) AS score FROM fts WHERE fts MATCH ? ORDER BY score LIMIT 5000)
            SELECT e.book, COALESCE(CASE WHEN e.continuation = 1 THEN e.first END, e.num) AS head, h.title
            FROM ranked JOIN entries e ON e.rowid = ranked.rowid
            JOIN entries h ON h.book = e.book AND h.num = COALESCE(CASE WHEN e.continuation = 1 THEN e.first END, e.num)
            WHERE (? IS NULL OR e.book = ?)
            GROUP BY e.book, head ORDER BY MIN(ranked.score) LIMIT ?
            """, match, book, book, limit) {
            Hit(book: $0.string(0)!, num: $0.int(1), title: $0.string(2) ?? "")
        }
    }

    /// Entries whose title starts with the prefix, for the Index's type-ahead.
    public func titles(prefix: String, book: String?, limit: Int = 300) throws -> [Hit] {
        let key = prefix.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return try db.rows("""
            SELECT book, num, title FROM entries WHERE continuation = 0 AND title != '' AND sort >= ? AND sort < ?
            AND (? IS NULL OR book = ?) ORDER BY sort LIMIT ?
            """, key, key + "\u{10FFFF}", book, book, limit) {
            Hit(book: $0.string(0)!, num: $0.int(1), title: $0.string(2) ?? "")
        }
    }

    public func media(kind: String) throws -> [MediaRef] {
        try db.rows("SELECT name, kind, path, caption, width, height FROM media WHERE kind = ? ORDER BY COALESCE(caption, name)", kind) {
            MediaRef(name: $0.string(0)!, kind: $0.string(1)!, path: $0.string(2), caption: $0.string(3), label: nil,
                     width: $0.string(4).flatMap(Int.init), height: $0.string(5).flatMap(Int.init))
        }
    }

    public func categories() throws -> [String] {
        try db.rows("SELECT name FROM categories ORDER BY name") { $0.string(0)! }
    }

    public func media(inCategory c: String) throws -> [MediaRef] {
        try db.rows("""
            SELECT m.name, m.kind, m.path, m.caption, m.width, m.height FROM category_items ci JOIN media m ON m.name = ci.media
            WHERE ci.category = ? ORDER BY COALESCE(m.caption, m.name)
            """, c) {
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
