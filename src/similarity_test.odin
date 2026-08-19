package main

import "core:encoding/base64"
import "core:os"
import "core:path/filepath"
import "core:testing"
import image_similarity "image_similarity:."

// A second 1x1 PNG with a different colour so cosine scores can separate
// identical copies from unrelated pixels.
TEST_FOLDER_PNG_RED_BASE64 :: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

folder_test_write_named_png :: proc(directory, name, payload: string) -> bool {
	png, decode_error := base64.decode(payload)
	if decode_error != nil {return false}
	defer delete(png)
	path, _ := filepath.join([]string{directory, name})
	defer delete(path)
	return os.write_entire_file(path, png) == nil
}

@(test)
macos_image_decode_rgba_png :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	testing.expect(t, folder_test_write_png(root, "a.png"), "png")
	path, _ := filepath.join([]string{root, "a.png"})
	defer delete(path)
	rgba, decoded := macos_image_decode_rgba(path)
	defer macos_rgba_destroy(&rgba)
	testing.expect(t, decoded, "decode")
	testing.expect(t, rgba.width == 1 && rgba.height == 1, "size")
	testing.expect(t, len(rgba.pixels) >= 4, "pixels")
}

@(test)
similarity_identical_copies_exceed_near_score :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	state: Library_Service_State
	state.database = database
	defer library_service_destroy(&state)
	testing.expect(t, folder_test_write_png(root, "a.png"), "a")
	testing.expect(t, folder_test_write_png(root, "b.png"), "b")
	path_a, _ := filepath.join([]string{root, "a.png"})
	defer delete(path_a)
	path_b, _ := filepath.join([]string{root, "b.png"})
	defer delete(path_b)
	_, embed_a, ok_a := similarity_embed_file(path_a)
	testing.expect(t, ok_a, "embed a")
	defer delete(embed_a)
	_, embed_b, ok_b := similarity_embed_file(path_b)
	testing.expect(t, ok_b, "embed b")
	defer delete(embed_b)
	score := image_similarity.cosine_similarity_normalized(embed_a, embed_b)
	testing.expectf(t, score >= SIMILARITY_NEAR_SCORE, "identical copies scored %.4f, need >= %.2f", score, SIMILARITY_NEAR_SCORE)

	root_id, added := folder_root_add(database, root, "", true)
	testing.expect(t, added, "root")
	testing.expect(t, folder_scan_root(database, root_id) == .None, "scan")
	for i in 0..<20 {
		more, error, _ := library_service_folder_embed_step(&state, root_id)
		testing.expectf(t, error == .None, "embed step %d: %v", i, error)
		if !more {break}
	}
	images, groups, grouped := similarity_folder_duplicates(database, root_id)
	defer folder_index_image_list_destroy(images)
	testing.expect(t, grouped, "duplicates query")
	testing.expectf(t, groups >= 1, "identical copies must form a group, got %d", groups)
	testing.expect(t, len(images) >= 2, "group members")
}

@(test)
similarity_unrelated_patterns_stay_below_identity :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	testing.expect(t, folder_test_write_png(root, "gray.png"), "gray")
	testing.expect(t, folder_test_write_named_png(root, "red.png", TEST_FOLDER_PNG_RED_BASE64), "red")
	gray, _ := filepath.join([]string{root, "gray.png"})
	defer delete(gray)
	red, _ := filepath.join([]string{root, "red.png"})
	defer delete(red)
	_, embed_gray, ok_g := similarity_embed_file(gray)
	testing.expect(t, ok_g, "embed gray")
	defer delete(embed_gray)
	_, embed_red, ok_r := similarity_embed_file(red)
	testing.expect(t, ok_r, "embed red")
	defer delete(embed_red)
	score := image_similarity.cosine_similarity_normalized(embed_gray, embed_red)
	testing.expectf(t, score < 1.0, "unrelated fixtures must not be identical, scored %.4f", score)
}

@(test)
similarity_is_near_requires_dhash_and_cosine :: proc(t: ^testing.T) {
	unit := []f32{1, 0, 0}
	testing.expect(t, similarity_is_near(0, 0, unit, unit), "identical hash and vector")
	testing.expect(t, !similarity_is_near(0, max(u64), unit, unit), "far hashes must not match")
}

@(test)
folder_upsert_clears_stale_embeddings_on_file_change :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	state: Library_Service_State
	state.database = database
	defer library_service_destroy(&state)
	testing.expect(t, folder_test_write_png(root, "a.png"), "png")
	root_id, added := folder_root_add(database, root, "", true)
	testing.expect(t, added, "root")
	testing.expect(t, folder_scan_root(database, root_id) == .None, "scan")
	for i in 0..<20 {
		more, error, _ := library_service_folder_embed_step(&state, root_id)
		testing.expectf(t, error == .None, "embed step %d: %v", i, error)
		if !more {break}
	}
	testing.expect(t, folder_test_similarity_embedded(t, database, root_id) == 1, "embedded")
	images, listed := folder_image_list(database, root_id)
	defer folder_index_image_list_destroy(images)
	testing.expect(t, listed && len(images) == 1, "one image")
	testing.expect(
		t,
		folder_upsert_image(
			database,
			root_id,
			images[0].path,
			"image/png",
			images[0].size_bytes,
			images[0].modified_unix_ms,
			images[0].pixel_width,
			images[0].pixel_height,
		),
		"unchanged file",
	)
	testing.expect(t, folder_test_similarity_embedded(t, database, root_id) == 1, "unchanged file keeps embedding")
	testing.expect(
		t,
		folder_upsert_image(
			database,
			root_id,
			images[0].path,
			"image/png",
			images[0].size_bytes+1,
			images[0].modified_unix_ms,
			images[0].pixel_width,
			images[0].pixel_height,
		),
		"changed file",
	)
	testing.expect(t, folder_test_similarity_embedded(t, database, root_id) == 0, "stale embedding cleared")
}

@(test)
similarity_ingest_counts_folder_and_other_captures :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	state: Library_Service_State
	state.database = database
	defer library_service_destroy(&state)
	testing.expect(t, folder_test_write_png(root, "folder.png"), "folder png")
	testing.expect(t, folder_test_write_png(support, "capture-a.png"), "capture a")
	testing.expect(t, folder_test_write_png(support, "capture-b.png"), "capture b")
	path_a, _ := filepath.join([]string{support, "capture-a.png"})
	defer delete(path_a)
	path_b, _ := filepath.join([]string{support, "capture-b.png"})
	defer delete(path_b)
	root_id, added := folder_root_add(database, root, "", true)
	testing.expect(t, added, "root")
	testing.expect(t, folder_scan_root(database, root_id) == .None, "scan")
	for i in 0..<20 {
		more, error, _ := library_service_folder_embed_step(&state, root_id)
		testing.expectf(t, error == .None, "embed step %d: %v", i, error)
		if !more {break}
	}
	folder_hits := similarity_ingest_staging(&state, path_a, "cap-a", "digest-a")
	testing.expectf(t, folder_hits >= 1, "first capture must match the folder copy, got %d", folder_hits)
	images, listed := similarity_capture_similar(database, "cap-a")
	defer folder_index_image_list_destroy(images)
	testing.expect(t, listed, "review query")
	testing.expect(t, len(images) >= 1, "review must list the folder match")
	both := similarity_ingest_staging(&state, path_b, "cap-b", "digest-b")
	testing.expectf(t, both >= 2, "second capture must match folder and the earlier capture, got %d", both)
}

folder_test_similarity_embedded :: proc(t: ^testing.T, database: ^SQLite_DB, root_id: i64) -> int {
	statement, prepared := sqlite_prepare(database, `
SELECT similarity_embedded FROM folder_images WHERE root_id = ? LIMIT 1;`)
	testing.expect(t, prepared, "prepare embedded")
	if !prepared {return -1}
	defer sqlite3_finalize(statement)
	testing.expect(t, sqlite_bind_i64_value(statement, 1, root_id), "bind")
	if sqlite3_step(statement) != SQLITE_ROW {return -1}
	return int(i64(sqlite3_column_int64(statement, 0)))
}
