// SQLiteReader: rows out of a SQLite database, read without writing anything where it
// is kept.
//
// ProPresenter's database workspaces (DatabaseWorkspace.swift) are SQLite databases in
// write-ahead mode: recent changes sit in a "-wal" file beside the database until
// ProPresenter folds them in. KNOWN (the maintainer's Mac, 2026-10): the registry of
// workspaces was 4 KB of database and 125 KB of "-wal", every row of it in the second.
// Opened as unchangeable ("immutable"), SQLite would not look at the "-wal" and would
// see none of them; opened in the ordinary way, even only to read, it may write the
// shared-memory file beside them, in ProPresenter's folder.
//
// So the database and its "-wal" are copied into a folder of this app's own, and the
// copy is read; nothing is ever opened in ProPresenter's folder but to copy it. Should
// ProPresenter change the files while they are copied, the copy is made again (up to
// three times), as their sizes and dates show.
//
// macOS's own SQLite (libsqlite3) is used: it comes with the system, so it is no new
// dependency.

import Foundation
import SQLite3

enum SQLiteError: Error, CustomStringConvertible {
    case cannotOpen(String, String)
    case query(String)
    case changing(String)

    var description: String {
        switch self {
        case .cannotOpen(let file, let why): return "\(file) could not be read: \(why)"
        case .query(let why): return "A query of ProPresenter's database failed: \(why)"
        case .changing(let file): return "\(file) kept changing while it was being read. Is ProPresenter saving? Try again in a moment."
        }
    }
}

/// One value of a row.
enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var text: String? { if case .text(let t) = self { return t } else { return nil } }
    var blob: Data? { if case .blob(let b) = self { return b } else { return nil } }
    var integer: Int64? { if case .integer(let i) = self { return i } else { return nil } }
}

final class SQLiteReader {
    private var db: OpaquePointer?
    private let copy: URL

    /// A copy of the database at `file` (and its "-wal"), opened to read.
    init(copying file: URL) throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ProToPPTX-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        copy = folder.appendingPathComponent(file.lastPathComponent)
        let wal = URL(fileURLWithPath: file.path + "-wal")

        func stamp() -> [String] {
            [file, wal].map { url in
                let a = try? fm.attributesOfItem(atPath: url.path)
                return "\(a?[.size] ?? "-") \((a?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)"
            }
        }
        var copied = false
        for _ in 0 ..< 3 {
            let before = stamp()
            try? fm.removeItem(at: copy)
            try? fm.removeItem(at: URL(fileURLWithPath: copy.path + "-wal"))
            try fm.copyItem(at: file, to: copy)
            if fm.fileExists(atPath: wal.path) { try fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }
            if stamp() == before {
                copied = true
                break
            }
        }
        guard copied else {
            try? fm.removeItem(at: folder)
            throw SQLiteError.changing(file.lastPathComponent)
        }
        // The copy is opened to write, so that SQLite can take in the "-wal" beside it.
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            db = nil
            try? fm.removeItem(at: folder)
            throw SQLiteError.cannotOpen(file.lastPathComponent, why)
        }
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
    }

    /// The rows a query gives, each value by its column's name.
    func rows(_ sql: String, _ arguments: [String] = []) throws -> [[String: SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (k, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(k + 1), argument, -1, transient)
        }
        var result: [[String: SQLiteValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw SQLiteError.query(String(cString: sqlite3_errmsg(db))) }
            var row: [String: SQLiteValue] = [:]
            for c in 0 ..< sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, c))
                switch sqlite3_column_type(statement, c) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, c)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, c))
                    if let bytes = sqlite3_column_blob(statement, c), count > 0 {
                        row[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        row[name] = .blob(Data())
                    }
                default: row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }

    /// Whether the database has a table of this name.
    func hasTable(_ name: String) throws -> Bool {
        try !rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [name]).isEmpty
    }
}
