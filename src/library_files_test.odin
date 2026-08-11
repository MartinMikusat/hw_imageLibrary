package main

import "core:encoding/base64"
import "core:os"
import "core:testing"
import "base:runtime"

TEST_PNG_BASE64 :: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
TEST_PNG_DIGEST :: "431ced6916a2a21a156e38701afe55bbd7f88969fbbfc56d7fe099d47f265460"

test_png_bytes :: proc(allocator := context.allocator) -> ([]u8, bool) {
	bytes, error := base64.decode(TEST_PNG_BASE64, allocator=allocator)
	return bytes, error == nil
}

@(test)
library_sequence_filename_round_trip_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	name, encoded := library_sequence_filename(42, TEST_CAPTURE_ID, context.temp_allocator)
	testing.expect(t, encoded)
	testing.expect_value(t, name, "00000000000000000042-cccccccc-cccc-4ccc-8ccc-cccccccccccc.json")
	sequence, document_id, parsed := library_sequence_filename_parse(name)
	testing.expect(t, parsed)
	testing.expect_value(t, sequence, u64(42))
	testing.expect_value(t, document_id, TEST_CAPTURE_ID)
	_, _, invalid := library_sequence_filename_parse("42-capture.json")
	testing.expect(t, !invalid)
}

@(test)
library_root_and_atomic_record_publication_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-test-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)

	root, initialize_error := library_root_initialize(
		temporary_root,
		1_700_000_000_000,
		context.temp_allocator,
	)
	testing.expect_value(t, initialize_error, Library_File_Error.None)
	testing.expect(t, library_uuid_valid(root.genesis.library_id))
	testing.expect(t, library_uuid_valid(root.genesis.initial_device_id))

	opened, open_error := library_root_open(temporary_root, context.temp_allocator)
	testing.expect_value(t, open_error, Library_File_Error.None)
	testing.expect_value(t, opened.genesis, root.genesis)

	record := test_capture()
	record.library_id = root.genesis.library_id
	record.device_id = root.genesis.initial_device_id
	object_source, source_joined := library_join(
		[]string{temporary_root, "source.bin"},
		context.temp_allocator,
	)
	testing.expect(t, source_joined)
	fixture, fixture_decoded := test_png_bytes(context.temp_allocator)
	testing.expect(t, fixture_decoded)
	testing.expect_value(
		t,
		library_atomic_publish_bytes(object_source, fixture),
		Library_File_Error.None,
	)
	record.object_digest = TEST_PNG_DIGEST
	record.byte_count = 68
	record.pixel_width = 1
	record.pixel_height = 1
	testing.expect_value(
		t,
		library_install_object_uncoordinated(&root, object_source, record.object_digest, 68),
		Library_File_Error.None,
	)
	testing.expect_value(
		t,
		library_install_object_uncoordinated(&root, object_source, record.object_digest, 68),
		Library_File_Error.Already_Exists,
	)
	testing.expect_value(
		t,
		library_publish_record_uncoordinated(&root, &record),
		Library_File_Error.None,
	)
	testing.expect_value(
		t,
		library_publish_record_uncoordinated(&root, &record),
		Library_File_Error.Already_Exists,
	)
	record.page_title = "conflicting bytes"
	testing.expect_value(
		t,
		library_publish_record_uncoordinated(&root, &record),
		Library_File_Error.Conflict,
	)
	record.page_title = "Fixture"
	ack := test_event(TEST_EVENT_ACK_A, root.genesis.initial_device_id, 2, LIBRARY_EVENT_DEVICE_ACK)
	ack.library_id = root.genesis.library_id
	ack.frontier = []Library_Frontier_Entry{
		{device_id=root.genesis.initial_device_id, sequence=2},
	}
	testing.expect_value(
		t,
		library_publish_event_uncoordinated(&root, &ack),
		Library_File_Error.None,
	)
	join_request := Library_Join_Request{
		schema_version = LIBRARY_SCHEMA_VERSION,
		library_id = root.genesis.library_id,
		device_id = TEST_DEVICE_B,
		requested_at_unix_ms = 1_700_000_002_000,
		device_name = "Fixture Mac",
	}
	testing.expect_value(
		t,
		library_publish_join_request(&root, &join_request),
		Library_File_Error.None,
	)
	scan := library_root_scan(&root, context.temp_allocator)
	testing.expect_value(t, len(scan.records), 1)
	testing.expect_value(t, len(scan.record_objects), 1)
	if len(scan.record_objects) == 1 {
		testing.expect_value(t, scan.record_objects[0], Library_Object_State.Available)
	}
	testing.expect_value(t, len(scan.events), 1)
	testing.expect_value(t, len(scan.join_requests), 1)
	testing.expect_value(t, len(scan.issues), 0)
}

@(test)
library_sha256_file_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-hash-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)
	path, joined := library_join([]string{temporary_root, "fixture.bin"}, context.temp_allocator)
	testing.expect(t, joined)
	if !joined {return}
	fixture := []u8{'a', 'b', 'c'}
	testing.expect_value(
		t,
		library_atomic_publish_bytes(path, fixture),
		Library_File_Error.None,
	)
	digest, byte_count, hashed := library_sha256_file(path, context.temp_allocator)
	testing.expect(t, hashed)
	testing.expect_value(t, byte_count, i64(3))
	testing.expect_value(
		t,
		digest,
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	)
}

@(test)
library_scan_reports_unreferenced_installed_object_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-orphan-scan-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)

	root, root_error := library_root_initialize(
		temporary_root,
		1_700_000_000_000,
		context.temp_allocator,
	)
	testing.expect_value(t, root_error, Library_File_Error.None)
	if root_error != .None {return}
	fixture, fixture_ok := test_png_bytes(context.temp_allocator)
	source_path, source_path_ok := library_join(
		[]string{temporary_root, "orphan.png"},
		context.temp_allocator,
	)
	testing.expect(t, fixture_ok && source_path_ok)
	if !fixture_ok || !source_path_ok {return}
	testing.expect_value(
		t,
		library_atomic_publish_bytes(source_path, fixture),
		Library_File_Error.None,
	)
	testing.expect_value(
		t,
		library_install_object_uncoordinated(&root, source_path, TEST_PNG_DIGEST, 68),
		Library_File_Error.None,
	)

	scan := library_root_scan(&root, context.temp_allocator)
	testing.expect_value(t, len(scan.records), 0)
	testing.expect_value(t, len(scan.object_digests), 1)
	testing.expect_value(t, len(scan.orphan_digests), 1)
	if len(scan.object_digests) == 1 {
		testing.expect_value(t, scan.object_digests[0], TEST_PNG_DIGEST)
	}
	if len(scan.orphan_digests) == 1 {
		testing.expect_value(t, scan.orphan_digests[0], TEST_PNG_DIGEST)
	}
}
