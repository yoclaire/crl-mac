import Foundation
import SQLite3

/// Small wrapper over the system SQLite (which includes FTS5).
public final class SQLite: @unchecked Sendable {
    let db: OpaquePointer
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, readOnly: Bool = false) throws {
        var p: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &p, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let p else {
            throw CRLError.format("cannot open \(path)")
        }
        db = p
    }
    deinit { sqlite3_close(db) }

    var message: String { String(cString: sqlite3_errmsg(db)) }

    public func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CRLError.format("sqlite: \(message)") }
    }

    public final class Statement {
        let s: OpaquePointer, owner: SQLite
        init(_ s: OpaquePointer, _ owner: SQLite) { self.s = s; self.owner = owner }
        deinit { sqlite3_finalize(s) }

        @discardableResult
        public func bind(_ values: [Any?]) -> Statement {
            sqlite3_reset(s); sqlite3_clear_bindings(s)
            for (i, v) in values.enumerated() {
                let k = Int32(i + 1)
                switch v {
                case nil: sqlite3_bind_null(s, k)
                case let x as Int: sqlite3_bind_int64(s, k, Int64(x))
                case let x as Double: sqlite3_bind_double(s, k, x)
                case let x as String: sqlite3_bind_text(s, k, x, -1, SQLite.transient)
                case let x as Data: _ = x.withUnsafeBytes { sqlite3_bind_blob(s, k, $0.baseAddress, Int32(x.count), SQLite.transient) }
                default: sqlite3_bind_text(s, k, "\(v!)", -1, SQLite.transient)
                }
            }
            return self
        }
        public func run(_ values: Any?...) throws {
            bind(values)
            guard sqlite3_step(s) == SQLITE_DONE else { throw CRLError.format("sqlite: \(owner.message)") }
        }
        public func step() -> Bool { sqlite3_step(s) == SQLITE_ROW }
        public func int(_ c: Int32) -> Int { Int(sqlite3_column_int64(s, c)) }
        public func string(_ c: Int32) -> String? {
            sqlite3_column_text(s, c).map { String(cString: $0) }
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw CRLError.format("sqlite: \(message) in \(sql)") }
        return Statement(s, self)
    }

    /// Run a query and map each row.
    public func rows<T>(_ sql: String, _ args: Any?..., map: (Statement) -> T) throws -> [T] {
        let st = try prepare(sql)
        st.bind(args)
        var out: [T] = []
        while st.step() { out.append(map(st)) }
        return out
    }
}
