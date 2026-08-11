package main

import "core:os"
import "core:testing"
import "base:runtime"

@(test)
library_index_rebuild_and_search_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-index-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)

	root_path, root_joined := library_join(
		[]string{temporary_root, "library"},
		context.temp_allocator,
	)
	testing.expect(t, root_joined)
	if !root_joined {return}
	root, initialize_error := library_root_initialize(
		root_path,
		1_700_000_000_000,
		context.temp_allocator,
	)
	testing.expect_value(t, initialize_error, Library_File_Error.None)
	if initialize_error != .None {return}

	source_path, source_joined := library_join(
		[]string{temporary_root, "source.bin"},
		context.temp_allocator,
	)
	testing.expect(t, source_joined)
	if !source_joined {return}
	fixture, fixture_decoded := test_png_bytes(context.temp_allocator)
	testing.expect(t, fixture_decoded)
	testing.expect_value(
		t,
		library_atomic_publish_bytes(source_path, fixture),
		Library_File_Error.None,
	)
	record := test_capture()
	record.library_id = root.genesis.library_id
	record.device_id = root.genesis.initial_device_id
	record.object_digest = TEST_PNG_DIGEST
	record.byte_count = 68
	record.pixel_width = 1
	record.pixel_height = 1
	testing.expect_value(
		t,
		library_install_object_uncoordinated(&root, source_path, record.object_digest, 68),
		Library_File_Error.None,
	)
	testing.expect_value(
		t,
		library_publish_record_uncoordinated(&root, &record),
		Library_File_Error.None,
	)

	scan := library_root_scan(&root, context.temp_allocator)
	state := library_materialize(&root.genesis, scan.records[:], scan.events[:], context.temp_allocator)
	defer library_materialized_destroy(&state)
	database_path, database_joined := library_join(
		[]string{temporary_root, "index-v1.sqlite3"},
		context.temp_allocator,
	)
	testing.expect(t, database_joined)
	if !database_joined {return}
	database, opened := sqlite_open(database_path)
	testing.expect(t, opened)
	if !opened {return}
	testing.expect(t, library_index_rebuild(database, &scan, &state))
	list, listed := library_index_capture_list(database, false, context.temp_allocator)
	testing.expect(t, listed)
	testing.expect_value(t, len(list), 1)
	if len(list) == 1 {
		testing.expect_value(t, list[0].capture_id, TEST_CAPTURE_ID)
		testing.expect_value(t, list[0].page_title, "Fixture")
	}
	search, searched := library_index_capture_search(database, "fixture", context.temp_allocator)
	testing.expect(t, searched)
	testing.expect_value(t, len(search), 1)
	_ = sqlite3_close(database)

	testing.expect(t, os.remove(database_path) == nil)
	database, opened = sqlite_open(database_path)
	testing.expect(t, opened)
	if !opened {return}
	defer sqlite3_close(database)
	testing.expect(t, library_index_rebuild(database, &scan, &state))
	list, listed = library_index_capture_list(database, false, context.temp_allocator)
	testing.expect(t, listed)
	testing.expect_value(t, len(list), 1)

	scan.record_objects[0] = .Unavailable
	testing.expect(t, library_index_rebuild(database, &scan, &state))
	list, listed = library_index_capture_list(database, false, context.temp_allocator)
	testing.expect(t, listed)
	testing.expect_value(t, len(list), 1)
	if len(list) == 1 {
		testing.expect_value(t, list[0].object_state, Library_Object_State.Unavailable)
	}
	search, searched = library_index_capture_search(database, "fixture", context.temp_allocator)
	testing.expect(t, searched)
	testing.expect_value(t, len(search), 1)
}
