package main

import "core:path/filepath"
import "core:testing"

// Tag-set normalization is pure Odin and deterministic, so it is tested
// directly. The Apple Vision classifier itself is exercised by the driver
// integration test below, which runs against real image files.

@(test)
generated_tags_string_normalizes_and_dedupes :: proc(t: ^testing.T) {
	tags := []Image_Tag{
		{kind=.Class, label="dog", confidence=0.9},
		{kind=.Animal, label="wild_animal", confidence=0.8},
		{kind=.Class, label="dog", confidence=0.7},
		{kind=.Object, label="collar", confidence=0.4},
		{kind=.Class, label="", confidence=0.9},
	}
	got := generated_tags_string(tags)
	defer delete(got)
	testing.expectf(t, got == "collar dog wild animal", "got %q", got)
}

@(test)
generated_tags_string_empty_for_no_labels :: proc(t: ^testing.T) {
	got := generated_tags_string(nil)
	defer delete(got)
	testing.expect(t, len(got) == 0, "no labels must produce an empty string")
}

@(test)
generated_tags_merge_keeps_union_sorted :: proc(t: ^testing.T) {
	existing := "dog collar"
	additional := "dog wild_animal outdoor"
	got := generated_tags_merge(existing, additional)
	defer delete(got)
	// The merge operates on whitespace-separated tokens; underscore
	// normalization happens in generated_tags_string before storage.
	testing.expectf(t, got == "collar dog outdoor wild_animal", "got %q", got)
}

@(test)
generated_tags_merge_preserves_alone_side :: proc(t: ^testing.T) {
	one := generated_tags_merge("", "dog")
	defer delete(one)
	testing.expectf(t, one == "dog", "got %q", one)
	two := generated_tags_merge("collar", "")
	defer delete(two)
	testing.expectf(t, two == "collar", "got %q", two)
}

@(test)
folder_recognition_driver_marks_and_completes :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	state: Library_Service_State
	state.database = database
	// library_service_destroy closes the database itself.
	defer library_service_destroy(&state)

	root_id, added := folder_root_add(database, root, "", true)
	testing.expect(t, added && root_id > 0, "root must register")
	testing.expect(t, folder_test_write_png(root, "a.png"), "first image")
	testing.expect(t, folder_test_write_png(root, "b.png"), "second image")
	a_path, _ := filepath.join([]string{root, "a.png"})
	defer delete(a_path)
	b_path, _ := filepath.join([]string{root, "b.png"})
	defer delete(b_path)
	testing.expect(
		t,
		folder_upsert_image(database, root_id, a_path, "image/png", 100, 1, 10, 10),
		"first image row must insert",
	)
	testing.expect(
		t,
		folder_upsert_image(database, root_id, b_path, "image/png", 100, 2, 10, 10),
		"second image row must insert",
	)

	steps := 0
	for {
		more, error, tagged := library_service_folder_tag_step(&state, root_id)
		testing.expectf(t, error == .None, "tag step %d error: %v", steps, error)
		testing.expectf(t, tagged >= 0, "tag step %d negative count", steps)
		steps += 1
		if !more {break}
		if steps > 100 {testing.fail_now(t, "recognition did not complete")}
	}
	tagged_count, counted := folder_tagged_count(database, root_id)
	testing.expect(t, counted, "tagged count must read")
	testing.expectf(t, tagged_count == 2, "expected 2 tagged, got %d", tagged_count)

	more, error, tagged := library_service_folder_tag_step(&state, root_id)
	testing.expectf(t, error == .None && !more && tagged == 0, "second pass must be idle")
}

@(test)
folder_recognition_tags_are_searchable :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	defer sqlite3_close(database)

	root_id, added := folder_root_add(database, root, "", true)
	testing.expect(t, added && root_id > 0, "root must register")
	path, _ := filepath.join([]string{root, "photo.png"})
	defer delete(path)
	testing.expect(t, folder_test_write_png(root, "photo.png"), "image must write")
	testing.expect(
		t,
		folder_upsert_image(database, root_id, path, "image/png", 100, 123, 10, 10),
		"image row must insert",
	)

	images, listed := folder_image_list(database, root_id)
	defer folder_index_image_list_destroy(images)
	testing.expect(t, listed && len(images) == 1, "one image must be indexed")

	testing.expect(
		t,
		folder_image_tag_set(database, root_id, images[0].image_id, "dog collar"),
		"tags must write",
	)
	testing.expect(t, folder_rebuild_fts(database, root_id), "fts must rebuild")

	matches, searched := folder_image_search(database, "dog")
	defer folder_index_image_list_destroy(matches)
	testing.expect(t, searched && len(matches) == 1, "search must find the tagged image")
}

@(test)
folder_index_migrate_adds_recognition_columns :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	database_path, _ := filepath.join([]string{support, "migrate.sqlite3"})
	defer delete(database_path)
	database, opened := sqlite_open(database_path)
	if !opened {testing.fail_now(t, "database must open")}
	defer sqlite3_close(database)
	// Simulate a v1 database: the old table shape without the recognition
	// columns.
	testing.expect(t, sqlite_execute(database, `
CREATE TABLE folder_roots (
  root_id INTEGER PRIMARY KEY AUTOINCREMENT,
  path TEXT NOT NULL UNIQUE,
  bookmark_base64 TEXT NOT NULL DEFAULT '',
  recursive INTEGER NOT NULL DEFAULT 1,
  last_scan_unix_ms INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE folder_images (
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
`), "old schema must create")
	testing.expect(t, folder_index_migrate(database), "migration must run")
	tagged, _ := folder_tagged_count(database, 1)
	testing.expectf(t, tagged == 0, "migrated count must read as 0, got %d", tagged)
}
