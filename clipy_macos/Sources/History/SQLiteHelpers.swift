import Foundation
import SQLite3

/// Shared SQLite binding helpers used across history persistence classes.
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Binds a nullable string to a prepared statement, using NULL for nil values.
func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
    if let value {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    } else {
        sqlite3_bind_null(stmt, index)
    }
}

/// Reads an optional string column from a prepared statement row.
func optionalString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
          let cString = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cString)
}

/// Last error message reported by the connection, for diagnostics.
func sqliteErrorMessage(_ db: OpaquePointer?) -> String {
    guard let db, let message = sqlite3_errmsg(db) else { return "unknown error" }
    return String(cString: message)
}

/// Logs a failed SQLite operation. Failures used to be dropped on the floor,
/// which made a corrupt or full database look like an empty history.
func sqliteLogFailure(_ db: OpaquePointer?, _ context: String) {
    appLog("SQLite \(context) failed: \(sqliteErrorMessage(db))", level: .error)
}

/// Runs a statement that returns no rows, logging any failure.
@discardableResult
func sqliteExec(_ db: OpaquePointer?, _ sql: String, context: String) -> Bool {
    guard let db else { return false }
    var errorPointer: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
        let detail = errorPointer.map { String(cString: $0) } ?? sqliteErrorMessage(db)
        sqlite3_free(errorPointer)
        appLog("SQLite \(context) failed: \(detail)", level: .error)
        return false
    }
    sqlite3_free(errorPointer)
    return true
}
