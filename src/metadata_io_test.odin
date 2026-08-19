package main

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
metadata_keywords_round_trip_png :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	testing.expect(t, folder_test_write_png(root, "photo.png"), "png fixture")
	path, _ := filepath.join([]string{root, "photo.png"})
	defer delete(path)

	testing.expect(t, metadata_keywords_write(path, "collar dog") == .None, "png keyword write")
	got, read_ok := metadata_keywords_read(path)
	defer delete(got)
	testing.expect(t, read_ok, "png keyword read")
	testing.expectf(t, got == "collar dog", "png round-trip got %q", got)
}

@(test)
metadata_keywords_round_trip_jpeg :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	testing.expect(t, folder_test_write_png(root, "source.png"), "png source")
	png_path, _ := filepath.join([]string{root, "source.png"})
	defer delete(png_path)
	jpeg_path, _ := filepath.join([]string{root, "photo.jpg"})
	defer delete(jpeg_path)
	testing.expect(
		t,
		metadata_copy_with_orientation(png_path, jpeg_path, 1) == .None,
		"jpeg copy",
	)
	info, stated := os.stat(jpeg_path, context.allocator)
	testing.expect(t, stated == nil, "jpeg exists")
	before := info.size
	os.file_info_delete(info, context.allocator)

	testing.expect(t, metadata_keywords_write(jpeg_path, "outdoor") == .None, "jpeg keyword write")
	got, read_ok := metadata_keywords_read(jpeg_path)
	defer delete(got)
	testing.expect(t, read_ok && got == "outdoor", "jpeg round-trip")

	after_info, after_ok := os.stat(jpeg_path, context.allocator)
	testing.expect(t, after_ok == nil, "jpeg still exists")
	after := after_info.size
	os.file_info_delete(after_info, context.allocator)
	// ImageIO re-encodes JPEG. Record the size ratio; a 1x1 fixture is not a
	// quality oracle. XMP injection stays deferred unless a real-folder
	// measurement shows an unacceptable loss.
	if before > 0 {
		ratio := f64(after) / f64(before)
		testing.expectf(t, ratio > 0.25 && ratio < 8.0, "jpeg size ratio %.3f (before %d after %d)", ratio, before, after)
	}
}

@(test)
metadata_write_preserves_jpeg_orientation :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	testing.expect(t, folder_test_write_png(root, "source.png"), "png source")
	png_path, _ := filepath.join([]string{root, "source.png"})
	defer delete(png_path)
	jpeg_path, _ := filepath.join([]string{root, "rotated.jpg"})
	defer delete(jpeg_path)
	testing.expect(
		t,
		metadata_copy_with_orientation(png_path, jpeg_path, 6) == .None,
		"oriented jpeg",
	)
	before, before_ok := metadata_orientation_read(jpeg_path)
	testing.expect(t, before_ok && before == 6, "orientation must be 6 before write-back")
	testing.expect(t, metadata_keywords_write(jpeg_path, "dog") == .None, "keyword write")
	after, after_ok := metadata_orientation_read(jpeg_path)
	testing.expect(t, after_ok && after == 6, "orientation must survive keyword write")
	got, read_ok := metadata_keywords_read(jpeg_path)
	defer delete(got)
	testing.expect(t, read_ok && got == "dog", "keywords must round-trip")
}

@(test)
metadata_failed_destination_leaves_source :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	testing.expect(t, folder_test_write_png(root, "keep.png"), "png fixture")
	path, _ := filepath.join([]string{root, "keep.png"})
	defer delete(path)
	original, read_error := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_error == nil, "original bytes")
	defer delete(original)

	blocked, _ := filepath.join([]string{root, "blocked"})
	defer delete(blocked)
	testing.expect(t, os.make_directory(blocked) == nil, "blocked directory")
	error := metadata_keywords_write_destination(path, blocked, "dog")
	testing.expect(t, error != .None, "writing onto a directory must fail")

	after, after_error := os.read_entire_file(path, context.allocator)
	testing.expect(t, after_error == nil, "source still readable")
	defer delete(after)
	testing.expect(t, len(after) == len(original), "source length unchanged")
	same := true
	for index in 0..<len(original) {
		if after[index] != original[index] {same = false; break}
	}
	testing.expect(t, same, "source bytes unchanged after failed write")
}

@(test)
folder_scan_indexes_embedded_keywords :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
	defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	defer sqlite3_close(database)
	testing.expect(t, folder_test_write_png(root, "tagged.png"), "png fixture")
	path, _ := filepath.join([]string{root, "tagged.png"})
	defer delete(path)
	testing.expect(t, metadata_keywords_write(path, "bridge") == .None, "embed keyword")
	root_id, added := folder_root_add(database, root, "", true)
	testing.expect(t, added, "root")
	testing.expect(t, folder_scan_root(database, root_id) == .None, "scan")
	images, listed := folder_image_list(database, root_id)
	defer folder_index_image_list_destroy(images)
	testing.expect(t, listed && len(images) == 1, "one image")
	testing.expectf(t, images[0].tags == "bridge", "indexed tags got %q", images[0].tags)
}
