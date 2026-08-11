package main

import "core:encoding/json"
import "core:os"
import "core:sync"
import "core:testing"
import "base:runtime"

native_ingestion_test_exchange :: proc(
	state: ^Library_Service_State,
	message: Native_Wire_Message,
	allocator := context.allocator,
) -> (Native_Wire_Response, bool) {
	request, encode_error := json.marshal(message, {}, context.temp_allocator)
	if encode_error != nil {return {}, false}
	response_bytes, exchanged := ingest_ipc_client_exchange(
		state.ingest_socket_path,
		request,
		context.temp_allocator,
	)
	if !exchanged {return {}, false}
	response: Native_Wire_Response
	if decode_error := json.unmarshal(response_bytes, &response, .JSON, allocator);
	   decode_error != nil {
		return {}, false
	}
	return response, true
}

@(test)
native_ingestion_publishes_verified_capture_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.mutex_lock(&macos_path_environment_mutex)
	defer sync.mutex_unlock(&macos_path_environment_mutex)
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-ingestion-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)
	library_path, library_path_ok := library_join(
		[]string{temporary_root, "library"},
		context.temp_allocator,
	)
	support_path, support_path_ok := library_join(
		[]string{temporary_root, "support"},
		context.temp_allocator,
	)
	testing.expect(t, library_path_ok && support_path_ok)
	if !library_path_ok || !support_path_ok {return}
	previous, had_previous := os.lookup_env(
		HW_IMAGE_LIBRARY_SUPPORT_OVERRIDE,
		context.temp_allocator,
	)
	defer if had_previous {
		_ = os.set_env(HW_IMAGE_LIBRARY_SUPPORT_OVERRIDE, previous)
	} else {
		_ = os.unset_env(HW_IMAGE_LIBRARY_SUPPORT_OVERRIDE)
	}
	testing.expect(t, os.set_env(HW_IMAGE_LIBRARY_SUPPORT_OVERRIDE, support_path) == nil)
	root, root_error := library_root_initialize(
		library_path,
		1_700_000_000_000,
		context.temp_allocator,
	)
	testing.expect_value(t, root_error, Library_File_Error.None)
	if root_error != .None {return}
	settings := local_settings_initial(&root, LOCAL_SETTINGS_MODE_TEST, "")
	testing.expect_value(t, local_settings_save(&settings), Local_Settings_Error.None)

	state: Library_Service_State
	initialize_error := library_service_initialize_configured(&state)
	testing.expect_value(t, initialize_error, Library_Service_Error.None)
	if initialize_error != .None {return}
	defer library_service_destroy(&state)
	staging_directory, staging_ok := native_ingestion_staging_directory(
		&state,
		context.temp_allocator,
	)
	testing.expect(t, staging_ok && library_ensure_directory(staging_directory))
	stale_path, stale_ok := library_join(
		[]string{staging_directory, "stale.part"},
		context.temp_allocator,
	)
	testing.expect(t, stale_ok)
	if stale_ok {
		testing.expect_value(
			t,
			library_atomic_publish_bytes(stale_path, []u8{'x'}),
			Library_File_Error.None,
		)
	}
	testing.expect_value(t, library_service_start(&state), Library_Service_Error.None)
	if stale_ok {testing.expect(t, !os.exists(stale_path))}
	begin := Native_Wire_Message{
		wire_version = NATIVE_WIRE_VERSION,
		type = NATIVE_MESSAGE_BEGIN,
		transfer_id = "30000000-0000-4000-8000-000000000001",
		capture_id = TEST_CAPTURE_ID,
		sequence = 0,
		captured_at_unix_ms = 1_700_000_000_100,
		page_url = "https://example.com/page",
		page_title = "Ingestion fixture",
		current_src = "https://example.com/image.png",
		alt_text = "fixture",
		figure_caption = "caption",
		initial_note = "note",
		element_rect = {x=10, y=20, width=30, height=40},
		viewport = {width=100, height=100},
		response_media_type = "Image/PNG; charset=binary",
		declared_byte_count = 68,
	}
	ready, ready_exchanged := native_ingestion_test_exchange(&state, begin, context.temp_allocator)
	testing.expect(t, ready_exchanged && ready.ok)
	testing.expect_value(t, ready.next_sequence, u64(1))
	chunk := Native_Wire_Message{
		wire_version = NATIVE_WIRE_VERSION,
		type = NATIVE_MESSAGE_CHUNK,
		transfer_id = begin.transfer_id,
		capture_id = begin.capture_id,
		sequence = 1,
		data_base64 = TEST_PNG_BASE64,
	}
	chunk_ack, chunk_exchanged := native_ingestion_test_exchange(&state, chunk, context.temp_allocator)
	testing.expect(t, chunk_exchanged && chunk_ack.ok)
	testing.expect_value(t, chunk_ack.byte_count, i64(68))
	commit := Native_Wire_Message{
		wire_version = NATIVE_WIRE_VERSION,
		type = NATIVE_MESSAGE_COMMIT,
		transfer_id = begin.transfer_id,
		capture_id = begin.capture_id,
		sequence = 2,
		total_byte_count = 68,
	}
	stored, stored_exchanged := native_ingestion_test_exchange(&state, commit, context.temp_allocator)
	testing.expect(t, stored_exchanged && stored.ok)
	testing.expect_value(t, stored.type, "capture_stored")
	testing.expect_value(t, stored.object_digest, TEST_PNG_DIGEST)
	testing.expect_value(t, stored.pixel_width, 1)
	testing.expect_value(t, stored.pixel_height, 1)
	testing.expect_value(t, len(state.transfers), 0)
	list, listed := library_index_capture_list(state.database, false, context.temp_allocator)
	testing.expect(t, listed)
	testing.expect_value(t, len(list), 1)
	if len(list) == 1 {
		testing.expect_value(t, list[0].capture_id, TEST_CAPTURE_ID)
		testing.expect_value(t, list[0].object_state, Library_Object_State.Available)
	}
	loaded, load_error := local_settings_load(context.temp_allocator)
	testing.expect_value(t, load_error, Local_Settings_Error.None)
	testing.expect_value(t, loaded.next_sequence, u64(2))
}
