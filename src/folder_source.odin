package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:crypto/sha2"
import "core:encoding/hex"

FOLDER_INDEX_SCHEMA_VERSION :: 1

// Folder roots are user-selected external folders indexed in place. The files
// are never moved or copied; the machine-local SQLite index mirrors them and
// can be rebuilt by re-scanning. Tag columns keep provenance separate:
// `tags` holds keywords read from the file metadata and `generated_tags`
// holds recognition output; both feed the same FTS search.
FOLDER_INDEX_SCHEMA :: `
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS folder_roots (
  root_id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL UNIQUE,
  bookmark_base64 TEXT NOT NULL DEFAULT '',
  recursive INTEGER NOT NULL DEFAULT 1,
  last_scan_unix_ms INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS folder_images (
  image_id INTEGER PRIMARY KEY AUTOINCREMENT,
  root_id INTEGER NOT NULL REFERENCES folder_roots(root_id) ON DELETE CASCADE,
  path TEXT NOT NULL,
  media_type TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  modified_unix_ms INTEGER NOT NULL,
  pixel_width INTEGER NOT NULL,
  pixel_height INTEGER NOT NULL,
  tags TEXT NOT NULL DEFAULT '',
  generated_tags TEXT NOT NULL DEFAULT '',
  UNIQUE(root_id, path)
);
CREATE INDEX IF NOT EXISTS folder_images_root ON folder_images(root_id);
CREATE VIRTUAL TABLE IF NOT EXISTS folder_images_fts USING fts5(
  root_id UNINDEXED,
  path,
  tags,
  generated_tags,
  tokenize='unicode61'
);
`

Folder_Service_Root :: struct {
	root_id:           i64    `json:"root_id"`,
	path:              string `json:"path"`,
	recursive:         bool   `json:"recursive"`,
	last_scan_unix_ms: i64    `json:"last_scan_unix_ms,omitempty"`,
	image_count:       int    `json:"image_count"`,
}

Folder_Index_Image :: struct {
	root_id:          i64    `json:"root_id"`,
	image_id:         i64    `json:"image_id"`,
	path:             string `json:"path"`,
	media_type:       string `json:"media_type,omitempty"`,
	pixel_width:      int    `json:"pixel_width"`,
	pixel_height:     int    `json:"pixel_height"`,
	size_bytes:       i64    `json:"size_bytes"`,
	modified_unix_ms: i64    `json:"modified_unix_ms"`,
	tags:             string `json:"tags,omitempty"`,
	generated_tags:   string `json:"generated_tags,omitempty"`,
}

Folder_Scan_Error :: enum {
	None,
	Complete,
	Invalid_Root,
	Bookmark,
	Open,
	Read,
	Index,
	Unsupported,
}

FOLDER_IMAGE_EXTENSIONS :: []string{
	"jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "avif",
}

// FOLDER_SCAN_SKIP_DIRECTORIES lists directory names that never contain
// library-relevant images. Walking these (node_modules, build trees, caches)
// makes scans slow and pollutes the index with dependency artwork.
FOLDER_SCAN_SKIP_DIRECTORIES :: []string{"node_modules", "build", ".cache", "__pycache__"}

// FOLDER_SCAN_BATCH_FILES bounds how many image files one incremental scan
// step processes, keeping each service exchange well under the client's
// one-second request deadline.
FOLDER_SCAN_BATCH_FILES :: 128

folder_image_supported :: proc(path: string) -> bool {
	extension := strings.to_lower(filepath.ext(path), context.temp_allocator)
	extension = strings.trim_prefix(extension, ".")
	for supported in FOLDER_IMAGE_EXTENSIONS {
		if extension == supported {return true}
	}
	return false
}

folder_scan_skip_directory :: proc(name: string) -> bool {
	for skipped in FOLDER_SCAN_SKIP_DIRECTORIES {
		if name == skipped {return true}
	}
	return false
}

// delete_strings deep-deletes a slice of owned strings.
delete_strings :: proc(values: []string) {
	for value in values {delete(value)}
	delete(values)
}

folder_index_create_schema :: proc(database: ^SQLite_DB) -> bool {
	return sqlite_execute(database, FOLDER_INDEX_SCHEMA)
}

folder_service_root_destroy :: proc(value: ^Folder_Service_Root, allocator := context.allocator) {
	if value == nil {return}
	delete(value.path, allocator)
	value^ = {}
}

folder_service_root_list_destroy :: proc(values: [dynamic]Folder_Service_Root, allocator := context.allocator) {
	for &value in values {folder_service_root_destroy(&value, allocator)}
	delete(values)
}

folder_index_image_destroy :: proc(value: ^Folder_Index_Image, allocator := context.allocator) {
	if value == nil {return}
	delete(value.path, allocator)
	delete(value.media_type, allocator)
	delete(value.tags, allocator)
	delete(value.generated_tags, allocator)
	value^ = {}
}

folder_index_image_list_destroy :: proc(values: [dynamic]Folder_Index_Image, allocator := context.allocator) {
	for &value in values {folder_index_image_destroy(&value, allocator)}
	delete(values)
}

// folder_root_add registers a folder source. An empty bookmark is permitted for
// test and local roots; the process is unsandboxed and reads the path directly.
folder_root_add :: proc(
	database: ^SQLite_DB,
	path, bookmark_base64: string,
	recursive: bool,
) -> (i64, bool) {
	if database == nil || len(path) == 0 || !filepath.is_abs(path) {return 0, false}
	statement, prepared := sqlite_prepare(database, `
INSERT INTO folder_roots (path, bookmark_base64, recursive, last_scan_unix_ms)
VALUES (?, ?, ?, 0)
ON CONFLICT(path) DO NOTHING;
`)
	if !prepared {return 0, false}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_text_value(statement, 1, path) ||
	   !sqlite_bind_text_value(statement, 2, bookmark_base64) ||
	   !sqlite_bind_int_value(statement, 3, recursive ? 1 : 0) {
		return 0, false
	}
	if sqlite3_step(statement) != SQLITE_DONE {return 0, false}

	row, row_prepared := sqlite_prepare(database, `SELECT root_id FROM folder_roots WHERE path = ?;`)
	if !row_prepared {return 0, false}
	defer sqlite3_finalize(row)
	if !sqlite_bind_text_value(row, 1, path) {return 0, false}
	if sqlite3_step(row) != SQLITE_ROW {return 0, false}
	return i64(sqlite3_column_int64(row, 0)), true
}

folder_root_exists :: proc(database: ^SQLite_DB, path: string) -> bool {
	statement, prepared := sqlite_prepare(database, `SELECT 1 FROM folder_roots WHERE path = ?;`)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_text_value(statement, 1, path) {return false}
	return sqlite3_step(statement) == SQLITE_ROW
}

folder_root_get :: proc(
	database: ^SQLite_DB,
	root_id: i64,
) -> (path, bookmark_base64: string, recursive: bool, found: bool) {
	statement, prepared := sqlite_prepare(database, `
SELECT path, bookmark_base64, recursive FROM folder_roots WHERE root_id = ?;
`)
	if !prepared {return}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_i64_value(statement, 1, root_id) {return}
	if sqlite3_step(statement) != SQLITE_ROW {return}
	path = sqlite_column_string(statement, 0)
	bookmark_base64 = sqlite_column_string(statement, 1)
	recursive = sqlite3_column_int(statement, 2) != 0
	found = true
	return
}

folder_root_list :: proc(
	database: ^SQLite_DB,
	allocator := context.allocator,
) -> ([dynamic]Folder_Service_Root, bool) {
	statement, prepared := sqlite_prepare(database, `
SELECT fr.root_id, fr.path, fr.recursive, fr.last_scan_unix_ms,
       (SELECT COUNT(*) FROM folder_images fi WHERE fi.root_id = fr.root_id)
FROM folder_roots fr
ORDER BY fr.path ASC;
`)
	if !prepared {return nil, false}
	defer sqlite3_finalize(statement)
	result: [dynamic]Folder_Service_Root
	for sqlite3_step(statement) == SQLITE_ROW {
		root := Folder_Service_Root{
			root_id = i64(sqlite3_column_int64(statement, 0)),
			path = sqlite_column_string(statement, 1, allocator),
			recursive = sqlite3_column_int(statement, 2) != 0,
			last_scan_unix_ms = i64(sqlite3_column_int64(statement, 3)),
			image_count = int(sqlite3_column_int(statement, 4)),
		}
		append(&result, root)
	}
	return result, true
}

folder_root_remove :: proc(database: ^SQLite_DB, root_id: i64) -> bool {
	if database == nil {return false}
	if !sqlite_execute(database, "BEGIN IMMEDIATE;") {return false}
	committed := false
	defer if !committed {_ = sqlite_execute(database, "ROLLBACK;")}
	// Remove the images explicitly rather than relying on the foreign-key
	// cascade so behavior is identical regardless of PRAGMA foreign_keys state.
	statement, prepared := sqlite_prepare(database, `DELETE FROM folder_images WHERE root_id = ?;`)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_i64_value(statement, 1, root_id) {return false}
	if sqlite3_step(statement) != SQLITE_DONE {return false}
	root_statement, root_prepared := sqlite_prepare(database, `DELETE FROM folder_roots WHERE root_id = ?;`)
	if !root_prepared {return false}
	defer sqlite3_finalize(root_statement)
	if !sqlite_bind_i64_value(root_statement, 1, root_id) {return false}
	if sqlite3_step(root_statement) != SQLITE_DONE {return false}
	// The FTS rows are removed separately because the virtual table has no FK.
	if !sqlite_execute(database, fmt.tprintf(
		"DELETE FROM folder_images_fts WHERE root_id = %d;",
		root_id,
	)) {
		return false
	}
	if !sqlite_execute(database, "COMMIT;") {return false}
	committed = true
	return true
}

folder_image_list :: proc(
	database: ^SQLite_DB,
	root_id: i64,
	allocator := context.allocator,
) -> ([dynamic]Folder_Index_Image, bool) {
	statement, prepared := sqlite_prepare(database, `
SELECT root_id, image_id, path, media_type, size_bytes, modified_unix_ms,
       pixel_width, pixel_height, tags, generated_tags
FROM folder_images
WHERE root_id = ?
ORDER BY modified_unix_ms DESC, path ASC;
`)
	if !prepared {return nil, false}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_i64_value(statement, 1, root_id) {return nil, false}
	return folder_read_images(statement, allocator)
}

folder_image_search :: proc(
	database: ^SQLite_DB,
	text: string,
	allocator := context.allocator,
) -> ([dynamic]Folder_Index_Image, bool) {
	// FTS5 does not accept a bound parameter for MATCH in this SQLite build,
	// so the sanitized query is inlined. Quotes and single quotes are escaped
	// so user text cannot break out of the expression.
	sanitized, _ := strings.replace_all(text, "\"", "", context.temp_allocator)
	sanitized, _ = strings.replace_all(sanitized, "'", "''", context.temp_allocator)
	expression := sanitized if strings.contains(sanitized, " ") else fmt.aprintf("%s*", sanitized, allocator=context.temp_allocator)
	query := fmt.aprintf(`
SELECT fi.root_id, fi.image_id, fi.path, fi.media_type, fi.size_bytes,
       fi.modified_unix_ms, fi.pixel_width, fi.pixel_height, fi.tags, fi.generated_tags
FROM folder_images fi
JOIN folder_images_fts fts ON fts.root_id = fi.root_id AND fts.path = fi.path
WHERE folder_images_fts MATCH '%s'
ORDER BY fi.modified_unix_ms DESC;
`, expression, allocator=context.temp_allocator)
	statement, prepared := sqlite_prepare(database, query)
	if !prepared {
		return nil, false
	}
	defer sqlite3_finalize(statement)
	images, _ := folder_read_images(statement, allocator)
	return images, true
}

folder_read_images :: proc(
	statement: ^SQLite_Statement,
	allocator := context.allocator,
) -> ([dynamic]Folder_Index_Image, bool) {
	result: [dynamic]Folder_Index_Image
	for sqlite3_step(statement) == SQLITE_ROW {
		image := Folder_Index_Image{
			root_id = i64(sqlite3_column_int64(statement, 0)),
			image_id = i64(sqlite3_column_int64(statement, 1)),
			path = sqlite_column_string(statement, 2, allocator),
			media_type = sqlite_column_string(statement, 3, allocator),
			size_bytes = i64(sqlite3_column_int64(statement, 4)),
			modified_unix_ms = i64(sqlite3_column_int64(statement, 5)),
			pixel_width = int(sqlite3_column_int(statement, 6)),
			pixel_height = int(sqlite3_column_int(statement, 7)),
			tags = sqlite_column_string(statement, 8, allocator),
			generated_tags = sqlite_column_string(statement, 9, allocator),
		}
		append(&result, image)
	}
	return result, true
}

// folder_image_get loads one folder image row by its primary key.
folder_image_get :: proc(
	database: ^SQLite_DB,
	root_id, image_id: i64,
	allocator := context.allocator,
) -> (Folder_Index_Image, bool) {
	statement, prepared := sqlite_prepare(database, `
SELECT root_id, image_id, path, media_type, size_bytes, modified_unix_ms,
       pixel_width, pixel_height, tags, generated_tags
FROM folder_images
WHERE root_id = ? AND image_id = ?;
`)
	if !prepared {return {}, false}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_i64_value(statement, 1, root_id) ||
	   !sqlite_bind_i64_value(statement, 2, image_id) {return {}, false}
	if sqlite3_step(statement) != SQLITE_ROW {return {}, false}
	image := Folder_Index_Image{
		root_id = i64(sqlite3_column_int64(statement, 0)),
		image_id = i64(sqlite3_column_int64(statement, 1)),
		path = sqlite_column_string(statement, 2, allocator),
		media_type = sqlite_column_string(statement, 3, allocator),
		size_bytes = i64(sqlite3_column_int64(statement, 4)),
		modified_unix_ms = i64(sqlite3_column_int64(statement, 5)),
		pixel_width = int(sqlite3_column_int(statement, 6)),
		pixel_height = int(sqlite3_column_int(statement, 7)),
		tags = sqlite_column_string(statement, 8, allocator),
		generated_tags = sqlite_column_string(statement, 9, allocator),
	}
	return image, true
}

// folder_thumbnail_key produces a 64-hex cache key for a folder image so the
// thumbnail cache path remains valid and regenerates when the file changes.
folder_thumbnail_key :: proc(image_id, modified_unix_ms: i64, allocator := context.allocator) -> string {
	context_256: sha2.Context_256
	sha2.init_256(&context_256)
	sha2.update(&context_256, transmute([]u8)fmt.tprintf("folder:%d:%d", image_id, modified_unix_ms))
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&context_256, digest[:])
	encoded, encode_error := hex.encode(digest[:], allocator)
	if encode_error != nil {return ""}
	return string(encoded)
}

// Folder_Scan_State carries one in-progress incremental scan. It lives in the
// service so a large folder can be walked in bounded batches without blocking
// every other command, and so the app can drive the scan to completion while
// showing incremental results.
Folder_Scan_State :: struct {
	root_id:         i64,
	recursive:       bool,
	scan_path:       string, // owned resolved root
	directory_stack: [dynamic]string,
	seen:            map[string]bool, // owned paths indexed this scan
	finished:        bool,
}

folder_scan_state_destroy :: proc(state: ^Folder_Scan_State) {
	if state == nil {return}
	delete(state.scan_path)
	delete_strings(state.directory_stack[:])
	for path in state.seen {delete(path)}
	delete(state.seen)
	state^ = {}
}

// folder_scan_state_start resolves the folder root (falling back to the stored
// path when the bookmark is stale, since the process reads paths directly) and
// seeds the walk.
folder_scan_state_start :: proc(
	state: ^Folder_Scan_State,
	root_id: i64,
	path, bookmark_base64: string,
	recursive: bool,
) -> Folder_Scan_Error {
	if state == nil || len(path) == 0 {return .Invalid_Root}
	scan_path := path
	if len(bookmark_base64) > 0 {
		resolution, bookmark_error := macos_bookmark_resolve(bookmark_base64, context.temp_allocator)
		if bookmark_error == .None {
			scan_path = resolution.path
			defer macos_bookmark_resolution_close(&resolution)
		}
	}
	if !filepath.is_abs(scan_path) || !os.is_dir(scan_path) {
		return .Invalid_Root
	}
	state.scan_path = strings.clone(scan_path)
	state.root_id = root_id
	state.recursive = recursive
	state.seen = make(map[string]bool)
	append(&state.directory_stack, strings.clone(state.scan_path))
	return .None
}

// folder_scan_step walks the folder until it has processed up to batch_limit
// image files or the tree is exhausted. When the tree is exhausted it
// reconciles removed files, rebuilds the full-text index, and stamps the scan
// time. The second result is true when more directories remain.
folder_scan_step :: proc(
	database: ^SQLite_DB,
	state: ^Folder_Scan_State,
	batch_limit: int,
) -> (more: bool, error: Folder_Scan_Error) {
	if database == nil || state == nil || state.finished {return false, .Invalid_Root}
	limit := batch_limit
	if limit <= 0 {limit = FOLDER_SCAN_BATCH_FILES}
	processed := 0
	for len(state.directory_stack) > 0 && processed < limit {
		directory := pop(&state.directory_stack)
		handle, open_error := os.open(directory)
		if open_error != nil {
			delete(directory)
			continue
		}
		entries, read_error := os.read_dir(handle, -1, context.allocator)
		_ = os.close(handle)
		if read_error != nil {
			delete(directory)
			for entry in entries {os.file_info_delete(entry, context.allocator)}
			delete(entries)
			continue
		}
		resume := false
		for entry in entries {
			// Descend only into real directories; following symlinks can loop.
			if entry.type == .Directory {
				if state.recursive &&
				   !strings.has_prefix(entry.name, ".") &&
				   !folder_scan_skip_directory(entry.name) {
					append(&state.directory_stack, strings.clone(entry.fullpath))
				}
			} else if entry.type == .Regular &&
			          folder_image_supported(entry.fullpath) {
				if processed >= limit {
					// The batch budget ran out inside this directory; revisit
					// it on the next step rather than dropping the remainder.
					resume = true
					break
				}
				if folder_upsert_scan_file(database, state, entry.fullpath) {
					processed += 1
				}
			}
		}
		for entry in entries {os.file_info_delete(entry, context.allocator)}
		delete(entries)
		if resume {
			// Move ownership of the directory string back onto the stack.
			append(&state.directory_stack, directory)
			break
		}
		delete(directory)
	}
	if len(state.directory_stack) > 0 {
		return true, .None
	}
	state.finished = true
	return false, folder_scan_finalize(database, state)
}

folder_upsert_scan_file :: proc(database: ^SQLite_DB, state: ^Folder_Scan_State, path: string) -> bool {
	// Already indexed during this scan; do not consume the batch budget so a
	// resumed directory advances past the files it finished previously.
	if state.seen[path] {return false}
	info, stat_error := os.stat(path, context.allocator)
	if stat_error != nil {return false}
	defer os.file_info_delete(info, context.allocator)
	image_info, inspectable := macos_image_inspect(path)
	if !inspectable {return false}
	// image_info.media_type is a borrowed view into the inspection buffer and
	// must not be deleted; it is consumed synchronously by the upsert.
	if !folder_upsert_image(
		database,
		state.root_id,
		path,
		image_info.media_type,
		info.size,
		time.to_unix_nanoseconds(info.modification_time) / 1_000_000,
		image_info.pixel_width,
		image_info.pixel_height,
	) {
		return false
	}
	state.seen[strings.clone(path)] = true
	return true
}

// folder_scan_finalize removes rows for files that vanished, rebuilds the FTS
// index, and stamps the scan time in one transaction.
folder_scan_finalize :: proc(database: ^SQLite_DB, state: ^Folder_Scan_State) -> Folder_Scan_Error {
	if !sqlite_execute(database, "BEGIN IMMEDIATE;") {return .Index}
	committed := false
	defer if !committed {_ = sqlite_execute(database, "ROLLBACK;")}

	existing, existing_ok := folder_existing_paths(database, state.root_id)
	defer delete_strings(existing)
	if !existing_ok {return .Index}
	for existing_path in existing {
		if state.seen[existing_path] {continue}
		if !folder_delete_image(database, state.root_id, existing_path) {return .Index}
	}

	if !folder_rebuild_fts(database, state.root_id) {return .Index}
	statement, prepared := sqlite_prepare(database, `
UPDATE folder_roots SET last_scan_unix_ms = ? WHERE root_id = ?;
`)
	if !prepared {return .Index}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_i64_value(statement, 1, library_now_unix_ms()) ||
	   !sqlite_bind_i64_value(statement, 2, state.root_id) {return .Index}
	if sqlite3_step(statement) != SQLITE_DONE {return .Index}
	if !sqlite_execute(database, "COMMIT;") {return .Index}
	committed = true
	return .None
}

// folder_scan_root runs an incremental scan to completion. The CLI and tests
// use this; the GUI drives the same steps incrementally through the service.
folder_scan_root :: proc(database: ^SQLite_DB, root_id: i64) -> Folder_Scan_Error {
	if database == nil {return .Invalid_Root}
	path, bookmark_base64, recursive, found := folder_root_get(database, root_id)
	defer delete(path)
	defer delete(bookmark_base64)
	if !found || len(path) == 0 {return .Invalid_Root}
	state: Folder_Scan_State
	defer folder_scan_state_destroy(&state)
	if start_error := folder_scan_state_start(&state, root_id, path, bookmark_base64, recursive); start_error != .None {
		return start_error
	}
	for {
		more, step_error := folder_scan_step(database, &state, FOLDER_SCAN_BATCH_FILES)
		if step_error != .None {return step_error}
		if !more {break}
	}
	return .None
}

folder_existing_paths :: proc(
	database: ^SQLite_DB,
	root_id: i64,
	allocator := context.allocator,
) -> ([]string, bool) {
	statement, prepared := sqlite_prepare(database, `SELECT path FROM folder_images WHERE root_id = ?;`)
	if !prepared {return nil, false}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_i64_value(statement, 1, root_id) {return nil, false}
	result: [dynamic]string
	for sqlite3_step(statement) == SQLITE_ROW {
		append(&result, sqlite_column_string(statement, 0, allocator))
	}
	return result[:], true
}

folder_upsert_image :: proc(
	database: ^SQLite_DB,
	root_id: i64,
	path, media_type: string,
	size_bytes, modified_unix_ms: i64,
	width, height: int,
) -> bool {
	statement, prepared := sqlite_prepare(database, `
INSERT INTO folder_images
  (root_id, path, media_type, size_bytes, modified_unix_ms, pixel_width, pixel_height, tags, generated_tags)
VALUES (?, ?, ?, ?, ?, ?, ?, '', '')
ON CONFLICT(root_id, path) DO UPDATE SET
  media_type = excluded.media_type,
  size_bytes = excluded.size_bytes,
  modified_unix_ms = excluded.modified_unix_ms,
  pixel_width = excluded.pixel_width,
  pixel_height = excluded.pixel_height;
`)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_i64_value(statement, 1, root_id) &&
	       sqlite_bind_text_value(statement, 2, path) &&
	       sqlite_bind_text_value(statement, 3, media_type) &&
	       sqlite_bind_i64_value(statement, 4, size_bytes) &&
	       sqlite_bind_i64_value(statement, 5, modified_unix_ms) &&
	       sqlite_bind_int_value(statement, 6, width) &&
	       sqlite_bind_int_value(statement, 7, height) &&
	       sqlite3_step(statement) == SQLITE_DONE
}

folder_delete_image :: proc(database: ^SQLite_DB, root_id: i64, path: string) -> bool {
	statement, prepared := sqlite_prepare(database, `DELETE FROM folder_images WHERE root_id = ? AND path = ?;`)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_i64_value(statement, 1, root_id) &&
	       sqlite_bind_text_value(statement, 2, path) &&
	       sqlite3_step(statement) == SQLITE_DONE
}

// folder_rebuild_fts reconstructs the full-text index for one root from the
// image rows so search and image state can never drift apart.
folder_rebuild_fts :: proc(database: ^SQLite_DB, root_id: i64) -> bool {
	if !sqlite_execute(database, fmt.tprintf(
		"DELETE FROM folder_images_fts WHERE root_id = %d;",
		root_id,
	)) {
		return false
	}
	return sqlite_execute(database, `
INSERT INTO folder_images_fts (root_id, path, tags, generated_tags)
SELECT root_id, path, tags, generated_tags FROM folder_images;
`)
}
