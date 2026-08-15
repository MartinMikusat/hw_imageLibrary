package main

import "core:encoding/base64"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "base:runtime"

// A 1x1 PNG used to create decodable fixture files for folder scans.
TEST_FOLDER_PNG_BASE64 :: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

folder_test_write_png :: proc(directory, name: string) -> bool {
	png, decode_error := base64.decode(TEST_FOLDER_PNG_BASE64)
	if decode_error != nil {return false}
	defer delete(png)
	path, _ := filepath.join([]string{directory, name})
	defer delete(path)
	return os.write_entire_file(path, png) == nil
}

folder_test_prepare :: proc(t: ^testing.T) -> (string, string, bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temp_root, root_error := os.make_directory_temp("", "hw-gallery-folder-test-*", context.temp_allocator)
	if root_error != nil {return "", "", false}
	temp_support, support_error := os.make_directory_temp("", "hw-gallery-folder-support-*", context.temp_allocator)
	if support_error != nil {
		_ = os.remove_all(temp_root)
		return "", "", false
	}
	return temp_root, temp_support, true
}

folder_test_cleanup :: proc(root, support: string) {
	_ = os.remove_all(root)
	_ = os.remove_all(support)
}

folder_test_open_database :: proc(t: ^testing.T, support: string) -> ^SQLite_DB {
	database_path, _ := filepath.join([]string{support, "test.sqlite3"})
	defer delete(database_path)
	database, opened := sqlite_open(database_path)
	if !opened {
		testing.fail_now(t, "could not open the test database")
	}
	testing.expect(t, folder_index_create_schema(database), "folder schema must create")
	return database
}

@(test)
folder_scan_indexes_images_recursively :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	defer sqlite3_close(database)

	testing.expect(t, folder_test_write_png(root, "top.png"), "top-level image")
	subdirectory, _ := filepath.join([]string{root, "nested"})
	defer delete(subdirectory)
	testing.expect(t, os.make_directory(subdirectory) == nil, "nested directory")
	testing.expect(t, folder_test_write_png(subdirectory, "deep.jpg"), "nested image")
	testing.expect(t, folder_test_write_png(subdirectory, "notes.txt"), "non-image file")

	root_id, added := folder_root_add(database, root, "", true)
	testing.expect(t, added && root_id > 0, "folder root must be registered")

	scan_error := folder_scan_root(database, root_id)
	testing.expectf(t, scan_error == .None, "recursive scan must succeed, got %v", scan_error)

	images, listed := folder_image_list(database, root_id)
	defer folder_index_image_list_destroy(images)
	testing.expect(t, listed, "image listing must succeed")
	testing.expectf(t, len(images) == 2, "two images expected, got %d", len(images))
	for image in images {
		testing.expectf(t, len(image.media_type) > 0, "media type must be detected for %s", image.path)
		testing.expect(t, image.pixel_width == 1 && image.pixel_height == 1, "dimensions must decode")
	}
}

@(test)
folder_flat_scan_ignores_subdirectories :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	defer sqlite3_close(database)

	testing.expect(t, folder_test_write_png(root, "top.png"), "top-level image")
	subdirectory, _ := filepath.join([]string{root, "nested"})
	defer delete(subdirectory)
	testing.expect(t, os.make_directory(subdirectory) == nil, "nested directory")
	testing.expect(t, folder_test_write_png(subdirectory, "deep.png"), "nested image")

	root_id, added := folder_root_add(database, root, "", false)
	testing.expect(t, added, "folder root must be registered")
	testing.expect(t, folder_scan_root(database, root_id) == .None, "flat scan must succeed")

	images, _ := folder_image_list(database, root_id)
	defer folder_index_image_list_destroy(images)
	testing.expectf(t, len(images) == 1, "flat scan must skip subdirectories, got %d", len(images))
}

@(test)
folder_scan_reconciles_removed_files :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	defer sqlite3_close(database)

	testing.expect(t, folder_test_write_png(root, "first.png"), "first image")
	root_id, _ := folder_root_add(database, root, "", true)
	testing.expect(t, folder_scan_root(database, root_id) == .None, "first scan must succeed")

	testing.expect(t, folder_test_write_png(root, "second.png"), "second image")
	first_path, _ := filepath.join([]string{root, "first.png"})
	defer delete(first_path)
	testing.expect(t, os.remove(first_path) == nil, "remove first image")
	testing.expect(t, folder_scan_root(database, root_id) == .None, "second scan must succeed")

	images, _ := folder_image_list(database, root_id)
	defer folder_index_image_list_destroy(images)
	testing.expectf(t, len(images) == 1, "one surviving image expected, got %d", len(images))
	if len(images) == 1 {
		testing.expect(t, filepath.base(images[0].path) == "second.png", "removed file must leave the index")
	}
}

@(test)
folder_search_finds_images_by_path :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	defer sqlite3_close(database)

	testing.expect(t, folder_test_write_png(root, "mountain-sunset.png"), "mountain image")
	root_id, _ := folder_root_add(database, root, "", true)
	testing.expect(t, folder_scan_root(database, root_id) == .None, "scan must succeed")

	results, searched := folder_image_search(database, "sunset")
	defer folder_index_image_list_destroy(results)
	testing.expect(t, searched, "search must succeed")
	testing.expectf(t, len(results) == 1, "one search result expected, got %d", len(results))
	if len(results) == 1 {
		testing.expect(t, filepath.base(results[0].path) == "mountain-sunset.png", "search must match by path")
	}
}

@(test)
folder_root_remove_cascades_images :: proc(t: ^testing.T) {
	root, support, ok := folder_test_prepare(t)
	if !ok {testing.fail_now(t, "fixture setup failed")}
defer folder_test_cleanup(root, support)
	database := folder_test_open_database(t, support)
	defer sqlite3_close(database)

	testing.expect(t, folder_test_write_png(root, "image.png"), "image file")
	root_id, _ := folder_root_add(database, root, "", true)
	testing.expect(t, folder_scan_root(database, root_id) == .None, "scan must succeed")
	testing.expect(t, folder_root_remove(database, root_id), "root removal must succeed")

	images, listed := folder_image_list(database, root_id)
	defer folder_index_image_list_destroy(images)
	testing.expect(t, listed, "listing must succeed on the removed root")
	testing.expectf(t, len(images) == 0, "removing a root must cascade its images, got %d", len(images))

	folders, _ := folder_root_list(database)
	defer folder_service_root_list_destroy(folders)
	testing.expectf(t, len(folders) == 0, "no roots should remain, got %d", len(folders))
}
