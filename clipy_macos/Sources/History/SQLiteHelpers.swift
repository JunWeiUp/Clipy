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
