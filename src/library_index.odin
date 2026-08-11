package main

import "core:fmt"

LIBRARY_INDEX_SCHEMA_VERSION :: 1

LIBRARY_INDEX_SCHEMA :: `
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY,
  sequence_prefix INTEGER NOT NULL,
  accepted_cutoff INTEGER NOT NULL,
  authorized INTEGER NOT NULL,
  retired INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS join_requests (
  device_id TEXT PRIMARY KEY,
  requested_at_unix_ms INTEGER NOT NULL,
  device_name TEXT NOT NULL,
  authorized INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS captures (
  capture_id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  device_sequence INTEGER NOT NULL,
  captured_at_unix_ms INTEGER NOT NULL,
  object_digest TEXT NOT NULL,
  object_state INTEGER NOT NULL,
  media_type TEXT NOT NULL,
  byte_count INTEGER NOT NULL,
  pixel_width INTEGER NOT NULL,
  pixel_height INTEGER NOT NULL,
  page_url TEXT NOT NULL,
  page_title TEXT NOT NULL,
  current_src TEXT NOT NULL,
  alt_text TEXT NOT NULL,
  figure_caption TEXT NOT NULL,
  note TEXT NOT NULL,
  note_conflict INTEGER NOT NULL,
  deleted INTEGER NOT NULL,
  visible INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS captures_chronological
  ON captures(visible, captured_at_unix_ms DESC, capture_id ASC);
CREATE INDEX IF NOT EXISTS captures_digest ON captures(object_digest);
CREATE TABLE IF NOT EXISTS note_heads (
  capture_id TEXT NOT NULL REFERENCES captures(capture_id) ON DELETE CASCADE,
  revision_id TEXT NOT NULL,
  note TEXT NOT NULL,
  PRIMARY KEY(capture_id, revision_id)
);
CREATE TABLE IF NOT EXISTS effective_tombstones (
  capture_id TEXT NOT NULL REFERENCES captures(capture_id) ON DELETE CASCADE,
  event_id TEXT NOT NULL,
  PRIMARY KEY(capture_id, event_id)
);
CREATE TABLE IF NOT EXISTS events (
  event_id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  device_sequence INTEGER NOT NULL,
  kind TEXT NOT NULL,
  capture_id TEXT NOT NULL,
  target_event_id TEXT NOT NULL,
  object_digest TEXT NOT NULL,
  created_at_unix_ms INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS stream_faults (
  device_id TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  reason TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS scan_issues (
  path TEXT NOT NULL,
  reason TEXT NOT NULL
);
CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts USING fts5(
  capture_id UNINDEXED,
  page_title,
  page_url,
  alt_text,
  figure_caption,
  note,
  tokenize='unicode61'
);
`

Library_Index_Capture :: struct {
	capture_id:          string               `json:"capture_id"`,
	captured_at_unix_ms: i64                  `json:"captured_at_unix_ms"`,
	object_digest:       string               `json:"object_digest"`,
	media_type:          string               `json:"media_type"`,
	byte_count:          i64                  `json:"byte_count"`,
	pixel_width:         int                  `json:"pixel_width"`,
	pixel_height:        int                  `json:"pixel_height"`,
	page_url:            string               `json:"page_url"`,
	page_title:          string               `json:"page_title"`,
	current_src:         string               `json:"current_src"`,
	alt_text:            string               `json:"alt_text"`,
	figure_caption:      string               `json:"figure_caption"`,
	note:                string               `json:"note"`,
	note_conflict:       bool                 `json:"note_conflict"`,
	deleted:             bool                 `json:"deleted"`,
	object_state:        Library_Object_State `json:"object_state"`,
}

library_index_create_schema :: proc(database: ^SQLite_DB) -> bool {
	if !sqlite_execute(database, LIBRARY_INDEX_SCHEMA) {return false}
	return sqlite_execute(
		database,
		fmt.tprintf(
			"INSERT INTO meta(key,value) VALUES('schema_version','%d') " +
			"ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
			LIBRARY_INDEX_SCHEMA_VERSION,
		),
	)
}

library_index_clear_materialized :: proc(database: ^SQLite_DB) -> bool {
	return sqlite_execute(database, `
DELETE FROM captures_fts;
DELETE FROM note_heads;
DELETE FROM effective_tombstones;
DELETE FROM events;
DELETE FROM captures;
DELETE FROM join_requests;
DELETE FROM devices;
DELETE FROM stream_faults;
DELETE FROM scan_issues;
`)
}

library_index_insert_devices :: proc(
	database: ^SQLite_DB,
	state: ^Library_Materialized,
) -> bool {
	statement, prepared := sqlite_prepare(
		database,
		"INSERT INTO devices(device_id,sequence_prefix,accepted_cutoff,authorized,retired) VALUES(?,?,?,?,?);",
	)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	for device in state.devices {
		if !sqlite_bind_text_value(statement, 1, device.device_id) ||
		   !sqlite_bind_i64_value(statement, 2, i64(device.sequence_prefix)) ||
		   !sqlite_bind_i64_value(statement, 3, i64(device.accepted_cutoff)) ||
		   !sqlite_bind_int_value(statement, 4, device.authorized ? 1 : 0) ||
		   !sqlite_bind_int_value(statement, 5, device.retired ? 1 : 0) ||
		   sqlite3_step(statement) != SQLITE_DONE {
			return false
		}
		_ = sqlite3_reset(statement)
		_ = sqlite3_clear_bindings(statement)
	}
	return true
}

library_index_insert_captures :: proc(
	database: ^SQLite_DB,
	scan: ^Library_Scan,
	state: ^Library_Materialized,
) -> bool {
	capture_statement, capture_prepared := sqlite_prepare(database, `
INSERT INTO captures(
  capture_id,device_id,device_sequence,captured_at_unix_ms,object_digest,
  object_state,media_type,byte_count,pixel_width,pixel_height,page_url,page_title,
  current_src,alt_text,figure_caption,note,note_conflict,deleted,visible
) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);`)
	if !capture_prepared {return false}
	defer sqlite3_finalize(capture_statement)
	note_statement, note_prepared := sqlite_prepare(
		database,
		"INSERT INTO note_heads(capture_id,revision_id,note) VALUES(?,?,?);",
	)
	if !note_prepared {return false}
	defer sqlite3_finalize(note_statement)
	tombstone_statement, tombstone_prepared := sqlite_prepare(
		database,
		"INSERT INTO effective_tombstones(capture_id,event_id) VALUES(?,?);",
	)
	if !tombstone_prepared {return false}
	defer sqlite3_finalize(tombstone_statement)
	fts_statement, fts_prepared := sqlite_prepare(
		database,
		"INSERT INTO captures_fts(capture_id,page_title,page_url,alt_text,figure_caption,note) VALUES(?,?,?,?,?,?);",
	)
	if !fts_prepared {return false}
	defer sqlite3_finalize(fts_statement)

	for capture in state.captures {
		record := &scan.records[capture.record_index]
		object_state := scan.record_objects[capture.record_index]
		visible := !capture.deleted && object_state == .Available
		bound := sqlite_bind_text_value(capture_statement, 1, record.capture_id) &&
		         sqlite_bind_text_value(capture_statement, 2, record.device_id) &&
		         sqlite_bind_i64_value(capture_statement, 3, i64(record.device_sequence)) &&
		         sqlite_bind_i64_value(capture_statement, 4, record.captured_at_unix_ms) &&
		         sqlite_bind_text_value(capture_statement, 5, record.object_digest) &&
		         sqlite_bind_int_value(capture_statement, 6, int(object_state)) &&
		         sqlite_bind_text_value(capture_statement, 7, record.media_type) &&
		         sqlite_bind_i64_value(capture_statement, 8, record.byte_count) &&
		         sqlite_bind_int_value(capture_statement, 9, record.pixel_width) &&
		         sqlite_bind_int_value(capture_statement, 10, record.pixel_height) &&
		         sqlite_bind_text_value(capture_statement, 11, record.page_url) &&
		         sqlite_bind_text_value(capture_statement, 12, record.page_title) &&
		         sqlite_bind_text_value(capture_statement, 13, record.current_src) &&
		         sqlite_bind_text_value(capture_statement, 14, record.alt_text) &&
		         sqlite_bind_text_value(capture_statement, 15, record.figure_caption) &&
		         sqlite_bind_text_value(capture_statement, 16, capture.note) &&
		         sqlite_bind_int_value(capture_statement, 17, capture.note_conflict ? 1 : 0) &&
		         sqlite_bind_int_value(capture_statement, 18, capture.deleted ? 1 : 0) &&
		         sqlite_bind_int_value(capture_statement, 19, visible ? 1 : 0)
		if !bound || sqlite3_step(capture_statement) != SQLITE_DONE {return false}
		_ = sqlite3_reset(capture_statement)
		_ = sqlite3_clear_bindings(capture_statement)

		for head in capture.note_heads {
			if !sqlite_bind_text_value(note_statement, 1, record.capture_id) ||
			   !sqlite_bind_text_value(note_statement, 2, head.revision_id) ||
			   !sqlite_bind_text_value(note_statement, 3, head.note) ||
			   sqlite3_step(note_statement) != SQLITE_DONE {return false}
			_ = sqlite3_reset(note_statement)
			_ = sqlite3_clear_bindings(note_statement)
		}
		for tombstone_id in capture.effective_delete_ids {
			if !sqlite_bind_text_value(tombstone_statement, 1, record.capture_id) ||
			   !sqlite_bind_text_value(tombstone_statement, 2, tombstone_id) ||
			   sqlite3_step(tombstone_statement) != SQLITE_DONE {return false}
			_ = sqlite3_reset(tombstone_statement)
			_ = sqlite3_clear_bindings(tombstone_statement)
		}
		if !capture.deleted {
			if !sqlite_bind_text_value(fts_statement, 1, record.capture_id) ||
			   !sqlite_bind_text_value(fts_statement, 2, record.page_title) ||
			   !sqlite_bind_text_value(fts_statement, 3, record.page_url) ||
			   !sqlite_bind_text_value(fts_statement, 4, record.alt_text) ||
			   !sqlite_bind_text_value(fts_statement, 5, record.figure_caption) ||
			   !sqlite_bind_text_value(fts_statement, 6, capture.note) ||
			   sqlite3_step(fts_statement) != SQLITE_DONE {return false}
			_ = sqlite3_reset(fts_statement)
			_ = sqlite3_clear_bindings(fts_statement)
		}
	}
	return true
}

library_index_insert_events_and_issues :: proc(
	database: ^SQLite_DB,
	scan: ^Library_Scan,
	state: ^Library_Materialized,
) -> bool {
	join_statement, join_prepared := sqlite_prepare(
		database,
		"INSERT INTO join_requests(device_id,requested_at_unix_ms,device_name,authorized) VALUES(?,?,?,?);",
	)
	if !join_prepared {return false}
	defer sqlite3_finalize(join_statement)
	for request in scan.join_requests {
		device_index, found := library_device_index(state.devices[:], request.device_id)
		authorized := found && state.devices[device_index].authorized
		if !sqlite_bind_text_value(join_statement, 1, request.device_id) ||
		   !sqlite_bind_i64_value(join_statement, 2, request.requested_at_unix_ms) ||
		   !sqlite_bind_text_value(join_statement, 3, request.device_name) ||
		   !sqlite_bind_int_value(join_statement, 4, authorized ? 1 : 0) ||
		   sqlite3_step(join_statement) != SQLITE_DONE {return false}
		_ = sqlite3_reset(join_statement)
		_ = sqlite3_clear_bindings(join_statement)
	}
	event_statement, event_prepared := sqlite_prepare(database, `
INSERT INTO events(event_id,device_id,device_sequence,kind,capture_id,target_event_id,object_digest,created_at_unix_ms)
VALUES(?,?,?,?,?,?,?,?);`)
	if !event_prepared {return false}
	defer sqlite3_finalize(event_statement)
	for event_index in state.accepted_event_indices {
		event := &scan.events[event_index]
		if !sqlite_bind_text_value(event_statement, 1, event.event_id) ||
		   !sqlite_bind_text_value(event_statement, 2, event.device_id) ||
		   !sqlite_bind_i64_value(event_statement, 3, i64(event.device_sequence)) ||
		   !sqlite_bind_text_value(event_statement, 4, event.kind) ||
		   !sqlite_bind_text_value(event_statement, 5, event.capture_id) ||
		   !sqlite_bind_text_value(event_statement, 6, event.target_event_id) ||
		   !sqlite_bind_text_value(event_statement, 7, event.object_digest) ||
		   !sqlite_bind_i64_value(event_statement, 8, event.created_at_unix_ms) ||
		   sqlite3_step(event_statement) != SQLITE_DONE {return false}
		_ = sqlite3_reset(event_statement)
		_ = sqlite3_clear_bindings(event_statement)
	}
	fault_statement, fault_prepared := sqlite_prepare(
		database,
		"INSERT INTO stream_faults(device_id,sequence,reason) VALUES(?,?,?);",
	)
	if !fault_prepared {return false}
	defer sqlite3_finalize(fault_statement)
	for fault in state.stream_faults {
		if !sqlite_bind_text_value(fault_statement, 1, fault.device_id) ||
		   !sqlite_bind_i64_value(fault_statement, 2, i64(fault.sequence)) ||
		   !sqlite_bind_text_value(fault_statement, 3, fault.reason) ||
		   sqlite3_step(fault_statement) != SQLITE_DONE {return false}
		_ = sqlite3_reset(fault_statement)
		_ = sqlite3_clear_bindings(fault_statement)
	}
	issue_statement, issue_prepared := sqlite_prepare(
		database,
		"INSERT INTO scan_issues(path,reason) VALUES(?,?);",
	)
	if !issue_prepared {return false}
	defer sqlite3_finalize(issue_statement)
	for issue in scan.issues {
		if !sqlite_bind_text_value(issue_statement, 1, issue.path) ||
		   !sqlite_bind_text_value(issue_statement, 2, issue.reason) ||
		   sqlite3_step(issue_statement) != SQLITE_DONE {return false}
		_ = sqlite3_reset(issue_statement)
		_ = sqlite3_clear_bindings(issue_statement)
	}
	return true
}

library_index_rebuild :: proc(
	database: ^SQLite_DB,
	scan: ^Library_Scan,
	state: ^Library_Materialized,
) -> bool {
	if database == nil || len(scan.records) != len(scan.record_objects) {return false}
	library_apply_purge_object_states(
		state,
		scan.records[:],
		scan.events[:],
		scan.record_objects[:],
	)
	if !library_index_create_schema(database) {return false}
	if !sqlite_execute(database, "BEGIN IMMEDIATE;") {return false}
	committed := false
	defer if !committed {_ = sqlite_execute(database, "ROLLBACK;")}
	if !library_index_clear_materialized(database) ||
	   !library_index_insert_devices(database, state) ||
	   !library_index_insert_captures(database, scan, state) ||
	   !library_index_insert_events_and_issues(database, scan, state) ||
	   !sqlite_execute(database, "COMMIT;") {
		return false
	}
	committed = true
	return true
}

library_index_read_capture :: proc(
	statement: ^SQLite_Statement,
	allocator := context.allocator,
) -> Library_Index_Capture {
	return {
		capture_id = sqlite_column_string(statement, 0, allocator),
		captured_at_unix_ms = sqlite3_column_int64(statement, 1),
		object_digest = sqlite_column_string(statement, 2, allocator),
		media_type = sqlite_column_string(statement, 3, allocator),
		byte_count = sqlite3_column_int64(statement, 4),
		pixel_width = int(sqlite3_column_int(statement, 5)),
		pixel_height = int(sqlite3_column_int(statement, 6)),
		page_url = sqlite_column_string(statement, 7, allocator),
		page_title = sqlite_column_string(statement, 8, allocator),
		current_src = sqlite_column_string(statement, 9, allocator),
		alt_text = sqlite_column_string(statement, 10, allocator),
		figure_caption = sqlite_column_string(statement, 11, allocator),
		note = sqlite_column_string(statement, 12, allocator),
		note_conflict = sqlite3_column_int(statement, 13) != 0,
		deleted = sqlite3_column_int(statement, 14) != 0,
		object_state = Library_Object_State(sqlite3_column_int(statement, 15)),
	}
}

LIBRARY_INDEX_CAPTURE_COLUMNS :: `capture_id,captured_at_unix_ms,object_digest,media_type,
byte_count,pixel_width,pixel_height,page_url,page_title,current_src,alt_text,
figure_caption,note,note_conflict,deleted,object_state`

LIBRARY_INDEX_CAPTURE_COLUMNS_QUALIFIED :: `c.capture_id,c.captured_at_unix_ms,
c.object_digest,c.media_type,c.byte_count,c.pixel_width,c.pixel_height,c.page_url,
c.page_title,c.current_src,c.alt_text,c.figure_caption,c.note,c.note_conflict,
c.deleted,c.object_state`

library_index_capture_list :: proc(
	database: ^SQLite_DB,
	include_deleted := false,
	allocator := context.allocator,
) -> ([dynamic]Library_Index_Capture, bool) {
	query := fmt.tprintf(
		"SELECT %s FROM captures WHERE %s ORDER BY captured_at_unix_ms DESC,capture_id ASC;",
		LIBRARY_INDEX_CAPTURE_COLUMNS,
		include_deleted ? "1=1" : "deleted=0",
	)
	statement, prepared := sqlite_prepare(database, query)
	result := make([dynamic]Library_Index_Capture, allocator)
	if !prepared {return result, false}
	defer sqlite3_finalize(statement)
	for {
		step := sqlite3_step(statement)
		if step == SQLITE_DONE {break}
		if step != SQLITE_ROW {return result, false}
		append(&result, library_index_read_capture(statement, allocator))
	}
	return result, true
}

library_index_capture_search :: proc(
	database: ^SQLite_DB,
	query_text: string,
	allocator := context.allocator,
) -> ([dynamic]Library_Index_Capture, bool) {
	query := fmt.tprintf(
		"SELECT %s FROM captures_fts f JOIN captures c ON c.capture_id=f.capture_id " +
		"WHERE captures_fts MATCH ? AND c.deleted=0 " +
		"ORDER BY rank,c.captured_at_unix_ms DESC,c.capture_id ASC;",
		LIBRARY_INDEX_CAPTURE_COLUMNS_QUALIFIED,
	)
	statement, prepared := sqlite_prepare(database, query)
	result := make([dynamic]Library_Index_Capture, allocator)
	if !prepared || !sqlite_bind_text_value(statement, 1, query_text) {
		if statement != nil {_ = sqlite3_finalize(statement)}
		return result, false
	}
	defer sqlite3_finalize(statement)
	for {
		step := sqlite3_step(statement)
		if step == SQLITE_DONE {break}
		if step != SQLITE_ROW {return result, false}
		append(&result, library_index_read_capture(statement, allocator))
	}
	return result, true
}

library_index_capture_show :: proc(
	database: ^SQLite_DB,
	capture_id: string,
	allocator := context.allocator,
) -> (Library_Index_Capture, bool) {
	query := fmt.tprintf(
		"SELECT %s FROM captures WHERE capture_id=?;",
		LIBRARY_INDEX_CAPTURE_COLUMNS,
	)
	statement, prepared := sqlite_prepare(database, query)
	if !prepared || !sqlite_bind_text_value(statement, 1, capture_id) {
		if statement != nil {_ = sqlite3_finalize(statement)}
		return {}, false
	}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return {}, false}
	return library_index_read_capture(statement, allocator), true
}
