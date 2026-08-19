package main

import "core:c"
import "core:strings"

SQLite_DB :: struct {}
SQLite_Statement :: struct {}

foreign import sqlite "system:sqlite3"
foreign sqlite {
	sqlite3_open_v2 :: proc "c" (filename: cstring, database: ^^SQLite_DB, flags: c.int, vfs: cstring) -> c.int ---
	sqlite3_close :: proc "c" (database: ^SQLite_DB) -> c.int ---
	sqlite3_errmsg :: proc "c" (database: ^SQLite_DB) -> cstring ---
	sqlite3_exec :: proc "c" (database: ^SQLite_DB, sql: cstring, callback, ctx: rawptr, error_message: ^cstring) -> c.int ---
	sqlite3_free :: proc "c" (value: rawptr) ---
	sqlite3_prepare_v2 :: proc "c" (database: ^SQLite_DB, sql: cstring, bytes: c.int, statement: ^^SQLite_Statement, tail: ^cstring) -> c.int ---
	sqlite3_finalize :: proc "c" (statement: ^SQLite_Statement) -> c.int ---
	sqlite3_step :: proc "c" (statement: ^SQLite_Statement) -> c.int ---
	sqlite3_reset :: proc "c" (statement: ^SQLite_Statement) -> c.int ---
	sqlite3_clear_bindings :: proc "c" (statement: ^SQLite_Statement) -> c.int ---
	sqlite3_bind_text :: proc "c" (statement: ^SQLite_Statement, index: c.int, value: cstring, bytes: c.int, destroy: rawptr) -> c.int ---
	sqlite3_bind_int :: proc "c" (statement: ^SQLite_Statement, index, value: c.int) -> c.int ---
	sqlite3_bind_int64 :: proc "c" (statement: ^SQLite_Statement, index: c.int, value: i64) -> c.int ---
	sqlite3_bind_blob :: proc "c" (statement: ^SQLite_Statement, index: c.int, value: rawptr, bytes: c.int, destroy: rawptr) -> c.int ---
	sqlite3_column_text :: proc "c" (statement: ^SQLite_Statement, index: c.int) -> cstring ---
	sqlite3_column_int :: proc "c" (statement: ^SQLite_Statement, index: c.int) -> c.int ---
	sqlite3_column_int64 :: proc "c" (statement: ^SQLite_Statement, index: c.int) -> i64 ---
	sqlite3_column_blob :: proc "c" (statement: ^SQLite_Statement, index: c.int) -> rawptr ---
	sqlite3_column_bytes :: proc "c" (statement: ^SQLite_Statement, index: c.int) -> c.int ---
	sqlite3_busy_timeout :: proc "c" (database: ^SQLite_DB, milliseconds: c.int) -> c.int ---
}

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101
SQLITE_TRANSIENT :: rawptr(~uintptr(0))
SQLITE_OPEN_READONLY :: 0x00000001
SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE :: 0x00000004
SQLITE_OPEN_FULLMUTEX :: 0x00010000

sqlite_open :: proc(path: string, readonly := false) -> (^SQLite_DB, bool) {
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	database: ^SQLite_DB
	flags := SQLITE_OPEN_READONLY if readonly else
	         SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
	if sqlite3_open_v2(path_c, &database, c.int(flags), nil) != SQLITE_OK {
		if database != nil {_ = sqlite3_close(database)}
		return nil, false
	}
	_ = sqlite3_busy_timeout(database, 5000)
	return database, true
}

sqlite_error :: proc(database: ^SQLite_DB) -> string {
	if database == nil {return "SQLite database is not open"}
	message := sqlite3_errmsg(database)
	if message == nil {return "Unknown SQLite error"}
	return string(message)
}

sqlite_execute :: proc(database: ^SQLite_DB, sql: string) -> bool {
	query := strings.clone_to_cstring(sql, context.temp_allocator)
	error_message: cstring
	result := sqlite3_exec(database, query, nil, nil, &error_message)
	if error_message != nil {sqlite3_free(rawptr(error_message))}
	return result == SQLITE_OK
}

sqlite_prepare :: proc(database: ^SQLite_DB, sql: string) -> (^SQLite_Statement, bool) {
	query := strings.clone_to_cstring(sql, context.temp_allocator)
	statement: ^SQLite_Statement
	prepared := sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK
	return statement, prepared
}

sqlite_bind_text_value :: proc(statement: ^SQLite_Statement, index: int, value: string) -> bool {
	text := strings.clone_to_cstring(value, context.temp_allocator)
	return sqlite3_bind_text(statement, c.int(index), text, c.int(len(value)), nil) == SQLITE_OK
}

sqlite_bind_i64_value :: proc(statement: ^SQLite_Statement, index: int, value: i64) -> bool {
	return sqlite3_bind_int64(statement, c.int(index), value) == SQLITE_OK
}

sqlite_bind_int_value :: proc(statement: ^SQLite_Statement, index, value: int) -> bool {
	return sqlite3_bind_int(statement, c.int(index), c.int(value)) == SQLITE_OK
}

sqlite_bind_blob_value :: proc(statement: ^SQLite_Statement, index: int, value: []u8) -> bool {
	if len(value) == 0 {
		return sqlite3_bind_blob(statement, c.int(index), nil, 0, nil) == SQLITE_OK
	}
	return sqlite3_bind_blob(
		statement,
		c.int(index),
		raw_data(value),
		c.int(len(value)),
		SQLITE_TRANSIENT,
	) == SQLITE_OK
}

sqlite_column_blob_copy :: proc(
	statement: ^SQLite_Statement,
	index: int,
	allocator := context.allocator,
) -> []u8 {
	bytes := int(sqlite3_column_bytes(statement, c.int(index)))
	if bytes <= 0 {return nil}
	source := sqlite3_column_blob(statement, c.int(index))
	if source == nil {return nil}
	result := make([]u8, bytes, allocator)
	src := (cast([^]u8)source)[:bytes]
	copy(result, src)
	return result
}

sqlite_column_string :: proc(
	statement: ^SQLite_Statement,
	index: int,
	allocator := context.allocator,
) -> string {
	value := sqlite3_column_text(statement, c.int(index))
	if value == nil {return ""}
	copy, error := strings.clone(string(value), allocator)
	if error != nil {return ""}
	return copy
}
