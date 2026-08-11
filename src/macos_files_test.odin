package main

import "core:os"
import "core:slice"
import "core:testing"
import "base:runtime"

@(test)
macos_file_coordinator_executes_odin_accessor_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	pool := macos_autorelease_pool_begin()
	testing.expect(t, pool != nil)
	if pool == nil {return}
	defer macos_autorelease_pool_end(pool)
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-coordinator-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)
	path, joined := library_join(
		[]string{temporary_root, "coordinated.bin"},
		context.temp_allocator,
	)
	testing.expect(t, joined)
	if !joined {return}
	bytes := []u8{'o', 'd', 'i', 'n'}
	testing.expect_value(
		t,
		macos_coordinated_publish_bytes(path, bytes),
		Library_File_Error.None,
	)
	stored, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect(t, slice.equal(stored, bytes))
}

@(test)
macos_thumbnail_cache_is_replaceable_and_bounded_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-thumbnail-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)
	source_path, source_ok := library_join(
		[]string{temporary_root, "source.png"},
		context.temp_allocator,
	)
	testing.expect(t, source_ok)
	fixture, decoded := test_png_bytes(context.temp_allocator)
	testing.expect(t, decoded)
	testing.expect_value(
		t,
		library_atomic_publish_bytes(source_path, fixture),
		Library_File_Error.None,
	)
	thumbnail_path, thumbnail_error := macos_thumbnail_cache_create(
		source_path,
		temporary_root,
		TEST_PNG_DIGEST,
		256,
		context.temp_allocator,
	)
	testing.expect_value(t, thumbnail_error, Library_File_Error.None)
	testing.expect(t, os.exists(thumbnail_path))
	info, inspected := macos_image_inspect(thumbnail_path)
	testing.expect(t, inspected)
	if inspected {
		testing.expect(t, info.pixel_width <= 256)
		testing.expect(t, info.pixel_height <= 256)
	}
	reused_path, reused_error := macos_thumbnail_cache_create(
		source_path,
		temporary_root,
		TEST_PNG_DIGEST,
		256,
		context.temp_allocator,
	)
	testing.expect_value(t, reused_error, Library_File_Error.None)
	testing.expect_value(t, reused_path, thumbnail_path)
}

@(test)
macos_file_coordinator_moves_library_directory_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-move-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)
	source, source_ok := library_join(
		[]string{temporary_root, "source"},
		context.temp_allocator,
	)
	destination, destination_ok := library_join(
		[]string{temporary_root, "destination"},
		context.temp_allocator,
	)
	testing.expect(t, source_ok && destination_ok)
	if !source_ok || !destination_ok {return}
	testing.expect(t, library_ensure_directory(source))
	marker, marker_ok := library_join(
		[]string{source, "marker"},
		context.temp_allocator,
	)
	testing.expect(t, marker_ok)
	testing.expect_value(
		t,
		library_atomic_publish_bytes(marker, []u8{'o', 'k'}),
		Library_File_Error.None,
	)
	testing.expect_value(
		t,
		macos_coordinated_move_directory(source, destination),
		Library_File_Error.None,
	)
	testing.expect(t, !os.exists(source))
	moved_marker, moved_marker_ok := library_join(
		[]string{destination, "marker"},
		context.temp_allocator,
	)
	testing.expect(t, moved_marker_ok && os.exists(moved_marker))
}
