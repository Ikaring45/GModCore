import Foundation
import GModLua

// SQLite is already supplied by iOS and modern Windows. Declaring the small C
// ABI used here keeps GModEngine buildable in Swift Playgrounds without a
// separate C target or a vendored copy of SQLite.
@_silgen_name("sqlite3_open_v2")
private func gpad_sqlite3_open_v2(
    _ filename: UnsafePointer<CChar>?,
    _ database: UnsafeMutablePointer<OpaquePointer?>?,
    _ flags: Int32,
    _ virtualFileSystem: UnsafePointer<CChar>?
) -> Int32

@_silgen_name("sqlite3_close_v2")
private func gpad_sqlite3_close_v2(_ database: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_prepare_v2")
private func gpad_sqlite3_prepare_v2(
    _ database: OpaquePointer?,
    _ sql: UnsafePointer<CChar>?,
    _ byteCount: Int32,
    _ statement: UnsafeMutablePointer<OpaquePointer?>?,
    _ tail: UnsafeMutablePointer<UnsafePointer<CChar>?>?
) -> Int32

@_silgen_name("sqlite3_step")
private func gpad_sqlite3_step(_ statement: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_finalize")
private func gpad_sqlite3_finalize(_ statement: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_column_count")
private func gpad_sqlite3_column_count(_ statement: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_column_name")
private func gpad_sqlite3_column_name(
    _ statement: OpaquePointer?,
    _ column: Int32
) -> UnsafePointer<CChar>?

@_silgen_name("sqlite3_column_type")
private func gpad_sqlite3_column_type(_ statement: OpaquePointer?, _ column: Int32) -> Int32

@_silgen_name("sqlite3_column_text")
private func gpad_sqlite3_column_text(
    _ statement: OpaquePointer?,
    _ column: Int32
) -> UnsafePointer<UInt8>?

@_silgen_name("sqlite3_column_bytes")
private func gpad_sqlite3_column_bytes(_ statement: OpaquePointer?, _ column: Int32) -> Int32

@_silgen_name("sqlite3_errmsg")
private func gpad_sqlite3_errmsg(_ database: OpaquePointer?) -> UnsafePointer<CChar>?

private typealias SQLiteAuthorizer = @convention(c) (
    UnsafeMutableRawPointer?,
    Int32,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
) -> Int32

@_silgen_name("sqlite3_set_authorizer")
private func gpad_sqlite3_set_authorizer(
    _ database: OpaquePointer?,
    _ authorizer: SQLiteAuthorizer?,
    _ context: UnsafeMutableRawPointer?
) -> Int32

@_silgen_name("sqlite3_enable_load_extension")
private func gpad_sqlite3_enable_load_extension(
    _ database: OpaquePointer?,
    _ enabled: Int32
) -> Int32

@_silgen_name("sqlite3_limit")
private func gpad_sqlite3_limit(
    _ database: OpaquePointer?,
    _ category: Int32,
    _ newLimit: Int32
) -> Int32

private let sqliteOK: Int32 = 0
private let sqliteDeny: Int32 = 1
private let sqliteOpenReadWrite: Int32 = 0x0000_0002
private let sqliteOpenCreate: Int32 = 0x0000_0004
private let sqliteOpenMemory: Int32 = 0x0000_0080
private let sqliteOpenFullMutex: Int32 = 0x0001_0000
private let sqliteRow: Int32 = 100
private let sqliteDone: Int32 = 101
private let sqliteNull: Int32 = 5
private let sqliteAttach: Int32 = 24
private let sqliteDetach: Int32 = 25
private let sqliteCreateVirtualTable: Int32 = 29
private let sqliteDropVirtualTable: Int32 = 30
private let sqliteFunction: Int32 = 31
private let sqliteLimitAttached: Int32 = 7

private let gpadSQLiteAuthorizer: SQLiteAuthorizer = { _, action, first, second, _, _ in
    if action == sqliteAttach
        || action == sqliteDetach
        || action == sqliteCreateVirtualTable
        || action == sqliteDropVirtualTable {
        return sqliteDeny
    }
    if action == sqliteFunction {
        // SQLite reports a function name in the second argument today; check
        // both documented authorizer arguments so the policy is ABI-tolerant.
        let names = [first, second].compactMap { pointer in
            pointer.map { String(cString: $0).lowercased() }
        }
        if names.contains("load_extension") {
            return sqliteDeny
        }
    }
    return sqliteOK
}

private struct GMLuaSQLiteError: Error, CustomStringConvertible {
    let description: String
}

private struct GMLuaSQLiteRow {
    var fields: [(name: LuaString, value: LuaString)]
}

private final class GMLuaSQLiteDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSLock()

    init() throws {
        var opened: OpaquePointer?
        let flags = sqliteOpenReadWrite | sqliteOpenCreate | sqliteOpenMemory | sqliteOpenFullMutex
        let result = ":memory:".withCString {
            gpad_sqlite3_open_v2($0, &opened, flags, nil)
        }
        guard result == sqliteOK, let opened else {
            let message = opened.flatMap(gpad_sqlite3_errmsg).map(String.init(cString:))
                ?? "unable to open the state-local SQLite database (error \(result))"
            if let opened {
                _ = gpad_sqlite3_close_v2(opened)
            }
            throw GMLuaSQLiteError(description: message)
        }
        handle = opened

        let extensionResult = gpad_sqlite3_enable_load_extension(handle, 0)
        guard extensionResult == sqliteOK else {
            let message = Self.errorMessage(from: handle, fallbackCode: extensionResult)
            _ = gpad_sqlite3_close_v2(handle)
            throw GMLuaSQLiteError(description: message)
        }
        _ = gpad_sqlite3_limit(handle, sqliteLimitAttached, 0)

        let authorizerResult = gpad_sqlite3_set_authorizer(handle, gpadSQLiteAuthorizer, nil)
        guard authorizerResult == sqliteOK else {
            let message = Self.errorMessage(from: handle, fallbackCode: authorizerResult)
            _ = gpad_sqlite3_close_v2(handle)
            throw GMLuaSQLiteError(description: message)
        }
    }

    deinit {
        _ = gpad_sqlite3_close_v2(handle)
    }

    func query(_ source: LuaString) -> Result<[GMLuaSQLiteRow]?, GMLuaSQLiteError> {
        lock.lock()
        defer { lock.unlock() }

        do {
            let rows = try execute(source)
            return .success(rows.isEmpty ? nil : rows)
        } catch let error as GMLuaSQLiteError {
            return .failure(error)
        } catch {
            let wrapped = GMLuaSQLiteError(description: String(describing: error))
            return .failure(wrapped)
        }
    }

    private func execute(_ source: LuaString) throws -> [GMLuaSQLiteRow] {
        var bytes = source.bytes.map { CChar(bitPattern: $0) }
        bytes.append(0)
        var rows: [GMLuaSQLiteRow] = []

        try bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let sqlByteCount = buffer.count - 1
            var offset = 0

            while offset < sqlByteCount {
                let cursor = base.advanced(by: offset)
                let remaining = sqlByteCount - offset
                guard remaining <= Int(Int32.max) else {
                    throw GMLuaSQLiteError(description: "SQL query is too large")
                }

                var statement: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                let prepareResult = gpad_sqlite3_prepare_v2(
                    handle,
                    cursor,
                    Int32(remaining),
                    &statement,
                    &tail
                )
                guard prepareResult == sqliteOK else {
                    throw currentError(code: prepareResult)
                }

                let consumed = tail.map { cursor.distance(to: $0) } ?? remaining
                guard consumed > 0 else {
                    if let statement { _ = gpad_sqlite3_finalize(statement) }
                    throw GMLuaSQLiteError(description: "SQLite parser made no progress")
                }
                offset += consumed

                guard let statement else {
                    // Whitespace and comments produce no prepared statement.
                    continue
                }

                do {
                    try appendRows(from: statement, to: &rows)
                } catch {
                    _ = gpad_sqlite3_finalize(statement)
                    throw error
                }
                let finalizeResult = gpad_sqlite3_finalize(statement)
                guard finalizeResult == sqliteOK else {
                    throw currentError(code: finalizeResult)
                }
            }
        }

        return rows
    }

    private func appendRows(
        from statement: OpaquePointer,
        to rows: inout [GMLuaSQLiteRow]
    ) throws {
        while true {
            let stepResult = gpad_sqlite3_step(statement)
            if stepResult == sqliteDone { return }
            guard stepResult == sqliteRow else {
                throw currentError(code: stepResult)
            }

            let columnCount = gpad_sqlite3_column_count(statement)
            var fields: [(name: LuaString, value: LuaString)] = []
            fields.reserveCapacity(Int(columnCount))

            for column in 0..<columnCount {
                // Lua tables cannot store a nil field; SQLite NULL is therefore
                // represented by the absence of that column key in the row.
                if gpad_sqlite3_column_type(statement, column) == sqliteNull {
                    continue
                }
                guard let namePointer = gpad_sqlite3_column_name(statement, column) else {
                    continue
                }
                let name = LuaString(String(cString: namePointer))
                let count = max(0, Int(gpad_sqlite3_column_bytes(statement, column)))
                let valueBytes: [UInt8]
                if let text = gpad_sqlite3_column_text(statement, column), count > 0 {
                    valueBytes = Array(UnsafeBufferPointer(start: text, count: count))
                } else {
                    valueBytes = []
                }
                fields.append((name, LuaString(bytes: valueBytes)))
            }
            rows.append(GMLuaSQLiteRow(fields: fields))
        }
    }

    private func currentError(code: Int32) -> GMLuaSQLiteError {
        GMLuaSQLiteError(description: Self.errorMessage(from: handle, fallbackCode: code))
    }

    private static func errorMessage(from handle: OpaquePointer, fallbackCode: Int32) -> String {
        guard let pointer = gpad_sqlite3_errmsg(handle) else {
            return "SQLite error \(fallbackCode)"
        }
        return String(cString: pointer)
    }
}

/// Installs the native boundary used by Garry's Mod's Lua `util/sql.lua`.
///
/// The database is intentionally state-local and in-memory. This provides real
/// SQLite query and transaction behavior, but does not claim GMod's persistent
/// `sv.db` storage behavior yet.
public enum GMLuaSQL {
    public static func install(into state: LuaState) throws {
        let database = try GMLuaSQLiteDatabase()
        let sqlTable: LuaTable
        if case let .table(existing) = state.getGlobal("sql") {
            sqlTable = existing
        } else {
            sqlTable = LuaTable()
        }

        try state.setRawTableValue(.string(""), for: .string("m_strError"), in: sqlTable)

        let query = LuaNativeFunctionBox(
            { [weak state, weak sqlTable, database] arguments in
                guard let first = arguments.first, case let .string(source) = first else {
                    throw LuaError.runtime("bad argument #1 to 'Query' (string expected)")
                }
                guard let state, let sqlTable else {
                    throw LuaError.runtime("attempt to use sql.Query after its Lua state was released")
                }

                switch database.query(source) {
                case let .failure(error):
                    try state.setTableValue(
                        .string(LuaString(error.description)),
                        for: .string("m_strError"),
                        in: sqlTable
                    )
                    return [.boolean(false)]

                case let .success(rows):
                    guard let rows else { return [.nilValue] }
                    let result = LuaTable()
                    for (rowIndex, row) in rows.enumerated() {
                        let rowTable = LuaTable()
                        for field in row.fields {
                            try state.setRawTableValue(
                                .string(field.value),
                                for: .string(field.name),
                                in: rowTable
                            )
                        }
                        try state.setRawTableValue(
                            .table(rowTable),
                            for: .number(Double(rowIndex + 1)),
                            in: result
                        )
                    }
                    return [.table(result)]
                }
            },
            debugName: "sql.Query"
        )
        try state.setRawTableValue(.nativeFunction(query), for: .string("Query"), in: sqlTable)

        let lastError = LuaNativeFunctionBox(
            { [weak state, weak sqlTable] _ in
                guard let state, let sqlTable else {
                    throw LuaError.runtime("attempt to use sql.LastError after its Lua state was released")
                }
                return [try state.rawTableValue(for: .string("m_strError"), in: sqlTable)]
            },
            debugName: "sql.LastError"
        )
        try state.setRawTableValue(
            .nativeFunction(lastError),
            for: .string("LastError"),
            in: sqlTable
        )
        state.setGlobal("sql", value: .table(sqlTable))
    }
}
