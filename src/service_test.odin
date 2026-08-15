package main

import "core:os"
import "core:sync"
import "core:testing"
import "base:runtime"

@(test)
library_service_blocks_queries_while_index_is_unavailable_test :: proc(t: ^testing.T) {
	state := Library_Service_State{index_available=false}
	list := library_service_execute(
		&state,
		&Library_Service_Request{
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			command = "capture.list",
		},
	)
	testing.expect(t, !list.ok)
	testing.expect_value(t, list.error_code, "index_unavailable")
	health := library_service_execute(
		&state,
		&Library_Service_Request{
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			command = "health",
		},
	)
	testing.expect(t, health.ok)
	testing.expect_value(t, health.message, "index_unavailable")
}

@(test)
library_service_headless_query_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-service-*",
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
	root, root_error := library_root_initialize(
		library_path,
		1_700_000_000_000,
		context.temp_allocator,
	)
	testing.expect_value(t, root_error, Library_File_Error.None)
	if root_error != .None {return}

	fixture, fixture_ok := test_png_bytes(context.temp_allocator)
	testing.expect(t, fixture_ok)
	if !fixture_ok {return}
	source_path, source_path_ok := library_join(
		[]string{temporary_root, "fixture.png"},
		context.temp_allocator,
	)
	testing.expect(t, source_path_ok)
	if !source_path_ok {return}
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
		library_install_object_uncoordinated(&root, source_path, TEST_PNG_DIGEST, 68),
		Library_File_Error.None,
	)
	testing.expect_value(
		t,
		library_publish_record_uncoordinated(&root, &record),
		Library_File_Error.None,
	)

	state: Library_Service_State
	initialize_error := library_service_initialize(&state, library_path, support_path)
	testing.expect_value(t, initialize_error, Library_Service_Error.None)
	if initialize_error != .None {return}
	defer library_service_destroy(&state)
	testing.expect_value(t, library_service_start(&state), Library_Service_Error.None)

	health, health_ok := library_service_client_exchange(
		state.socket_path,
		{protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, command="health"},
		context.temp_allocator,
	)
	testing.expect(t, health_ok && health.ok)
	testing.expect_value(t, health.message, "ready")

	list, list_ok := library_service_client_exchange(
		state.socket_path,
		{protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, command="capture.list"},
		context.temp_allocator,
	)
	testing.expect(t, list_ok && list.ok)
	testing.expect_value(t, len(list.captures), 1)
	if len(list.captures) == 1 {
		testing.expect_value(t, list.captures[0].capture_id, TEST_CAPTURE_ID)
	}

	search, search_ok := library_service_client_exchange(
		state.socket_path,
		{
			protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
			command="capture.search",
			text="fixture",
		},
		context.temp_allocator,
	)
	testing.expect(t, search_ok && search.ok)
	testing.expect_value(t, len(search.captures), 1)

	show, show_ok := library_service_client_exchange(
		state.socket_path,
		{
			protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
			command="capture.show",
			capture_id=TEST_CAPTURE_ID,
		},
		context.temp_allocator,
	)
	testing.expect(t, show_ok && show.ok && show.has_capture)
	testing.expect_value(t, show.capture.capture_id, TEST_CAPTURE_ID)
}

@(test)
library_service_moves_single_device_root_and_commits_bookmark_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.mutex_lock(&macos_path_environment_mutex)
	defer sync.mutex_unlock(&macos_path_environment_mutex)
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-service-move-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)
	library_path, library_path_ok := library_join(
		[]string{temporary_root, "library"},
		context.temp_allocator,
	)
	destination_path, destination_path_ok := library_join(
		[]string{temporary_root, "moved-library"},
		context.temp_allocator,
	)
	support_path, support_path_ok := library_join(
		[]string{temporary_root, "support"},
		context.temp_allocator,
	)
	testing.expect(t, library_path_ok && destination_path_ok && support_path_ok)
	if !library_path_ok || !destination_path_ok || !support_path_ok {return}
	previous, had_previous := os.lookup_env(
		HW_GALLERY_SUPPORT_OVERRIDE,
		context.temp_allocator,
	)
	defer if had_previous {
		_ = os.set_env(HW_GALLERY_SUPPORT_OVERRIDE, previous)
	} else {
		_ = os.unset_env(HW_GALLERY_SUPPORT_OVERRIDE)
	}
	testing.expect(t, os.set_env(HW_GALLERY_SUPPORT_OVERRIDE, support_path) == nil)
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
	testing.expect_value(t, library_service_start(&state), Library_Service_Error.None)
	moved, exchanged := library_service_client_exchange(
		state.socket_path,
		{
			protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
			command="library.move",
			path=destination_path,
			confirmation=destination_path,
		},
		context.temp_allocator,
	)
	testing.expect(t, exchanged && moved.ok)
	testing.expect(t, !os.exists(library_path))
	testing.expect(t, os.exists(destination_path))
	testing.expect_value(t, state.root.path, destination_path)
	loaded, load_error := local_settings_load(context.temp_allocator)
	testing.expect_value(t, load_error, Local_Settings_Error.None)
	testing.expect_value(t, loaded.library_path, destination_path)
	testing.expect_value(t, loaded.library_mode, LOCAL_SETTINGS_MODE_BOOKMARK)
	testing.expect(t, len(loaded.bookmark_base64) > 0)
}

@(test)
library_service_delete_restore_and_ack_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.mutex_lock(&macos_path_environment_mutex)
	defer sync.mutex_unlock(&macos_path_environment_mutex)
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-service-write-*",
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
		HW_GALLERY_SUPPORT_OVERRIDE,
		context.temp_allocator,
	)
	defer if had_previous {
		_ = os.set_env(HW_GALLERY_SUPPORT_OVERRIDE, previous)
	} else {
		_ = os.unset_env(HW_GALLERY_SUPPORT_OVERRIDE)
	}
	testing.expect(t, os.set_env(HW_GALLERY_SUPPORT_OVERRIDE, support_path) == nil)

	root, root_error := library_root_initialize(
		library_path,
		1_700_000_000_000,
		context.temp_allocator,
	)
	testing.expect_value(t, root_error, Library_File_Error.None)
	if root_error != .None {return}
	fixture, fixture_ok := test_png_bytes(context.temp_allocator)
	source_path, source_path_ok := library_join(
		[]string{temporary_root, "fixture.png"},
		context.temp_allocator,
	)
	testing.expect(t, fixture_ok && source_path_ok)
	if !fixture_ok || !source_path_ok {return}
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
		library_install_object_uncoordinated(&root, source_path, TEST_PNG_DIGEST, 68),
		Library_File_Error.None,
	)
	testing.expect_value(
		t,
		library_publish_record_uncoordinated(&root, &record),
		Library_File_Error.None,
	)
	settings := local_settings_initial(&root, LOCAL_SETTINGS_MODE_TEST, "")
	local_settings_reconcile_sequence(&settings, []Library_Capture_Record{record}, nil)
	testing.expect_value(t, local_settings_save(&settings), Local_Settings_Error.None)

	state: Library_Service_State
	initialize_error := library_service_initialize_configured(&state)
	testing.expect_value(t, initialize_error, Library_Service_Error.None)
	if initialize_error != .None {return}
	defer library_service_destroy(&state)
	testing.expect_value(t, library_service_start(&state), Library_Service_Error.None)

	deleted, deleted_ok := library_service_client_exchange(
		state.socket_path,
		{
			protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
			command="capture.delete",
			capture_id=TEST_CAPTURE_ID,
		},
		context.temp_allocator,
	)
	testing.expect(t, deleted_ok && deleted.ok)
	testing.expect(t, library_uuid_valid(deleted.message))
	list, list_ok := library_service_client_exchange(
		state.socket_path,
		{protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, command="capture.list"},
		context.temp_allocator,
	)
	testing.expect(t, list_ok && list.ok)
	testing.expect_value(t, len(list.captures), 0)

	restored, restored_ok := library_service_client_exchange(
		state.socket_path,
		{
			protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION,
			command="capture.restore",
			capture_id=TEST_CAPTURE_ID,
		},
		context.temp_allocator,
	)
	testing.expect(t, restored_ok && restored.ok)
	list, list_ok = library_service_client_exchange(
		state.socket_path,
		{protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, command="capture.list"},
		context.temp_allocator,
	)
	testing.expect(t, list_ok && list.ok)
	testing.expect_value(t, len(list.captures), 1)

	ack, ack_ok := library_service_client_exchange(
		state.socket_path,
		{protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, command="library.ack"},
		context.temp_allocator,
	)
	testing.expect(t, ack_ok && ack.ok)
	testing.expect(t, library_uuid_valid(ack.message))
	loaded, load_error := local_settings_load(context.temp_allocator)
	testing.expect_value(t, load_error, Local_Settings_Error.None)
	testing.expect_value(t, loaded.next_sequence, u64(5))
}

@(test)
library_service_two_phase_physical_purge_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.mutex_lock(&macos_path_environment_mutex)
	defer sync.mutex_unlock(&macos_path_environment_mutex)
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-service-purge-*",
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
		HW_GALLERY_SUPPORT_OVERRIDE,
		context.temp_allocator,
	)
	defer if had_previous {
		_ = os.set_env(HW_GALLERY_SUPPORT_OVERRIDE, previous)
	} else {
		_ = os.unset_env(HW_GALLERY_SUPPORT_OVERRIDE)
	}
	testing.expect(t, os.set_env(HW_GALLERY_SUPPORT_OVERRIDE, support_path) == nil)
	root, root_error := library_root_initialize(
		library_path,
		1_500_000_000_000,
		context.temp_allocator,
	)
	testing.expect_value(t, root_error, Library_File_Error.None)
	if root_error != .None {return}
	fixture, fixture_ok := test_png_bytes(context.temp_allocator)
	source_path, source_path_ok := library_join(
		[]string{temporary_root, "fixture.png"},
		context.temp_allocator,
	)
	testing.expect(t, fixture_ok && source_path_ok)
	if !fixture_ok || !source_path_ok {return}
	testing.expect_value(
		t,
		library_atomic_publish_bytes(source_path, fixture),
		Library_File_Error.None,
	)
	record := test_capture()
	record.library_id = root.genesis.library_id
	record.device_id = root.genesis.initial_device_id
	record.captured_at_unix_ms = 1_500_000_000_100
	record.object_digest = TEST_PNG_DIGEST
	record.byte_count = 68
	record.pixel_width = 1
	record.pixel_height = 1
	testing.expect_value(
		t,
		library_install_object_uncoordinated(&root, source_path, TEST_PNG_DIGEST, 68),
		Library_File_Error.None,
	)
	testing.expect_value(
		t,
		library_publish_record_uncoordinated(&root, &record),
		Library_File_Error.None,
	)
	delete_event := test_event(
		"50000000-0000-4000-8000-000000000001",
		root.genesis.initial_device_id,
		2,
		LIBRARY_EVENT_CAPTURE_DELETE,
	)
	delete_event.library_id = root.genesis.library_id
	delete_event.capture_id = record.capture_id
	delete_event.created_at_unix_ms = 1_600_000_000_000
	ack := test_event(
		"50000000-0000-4000-8000-000000000002",
		root.genesis.initial_device_id,
		3,
		LIBRARY_EVENT_DEVICE_ACK,
	)
	ack.library_id = root.genesis.library_id
	ack.created_at_unix_ms = 1_600_000_000_100
	ack.frontier = []Library_Frontier_Entry{{
		device_id = root.genesis.initial_device_id,
		sequence = 3,
	}}
	testing.expect_value(
		t,
		library_publish_event_uncoordinated(&root, &delete_event),
		Library_File_Error.None,
	)
	testing.expect_value(
		t,
		library_publish_event_uncoordinated(&root, &ack),
		Library_File_Error.None,
	)
	settings := local_settings_initial(&root, LOCAL_SETTINGS_MODE_TEST, "")
	local_settings_reconcile_sequence(
		&settings,
		[]Library_Capture_Record{record},
		[]Library_Event{delete_event, ack},
	)
	testing.expect_value(t, local_settings_save(&settings), Local_Settings_Error.None)

	state: Library_Service_State
	initialize_error := library_service_initialize_configured(&state)
	testing.expect_value(t, initialize_error, Library_Service_Error.None)
	if initialize_error != .None {return}
	defer library_service_destroy(&state)
	testing.expect_value(t, library_service_start(&state), Library_Service_Error.None)
	purged, purged_ok := library_service_client_exchange(
		state.socket_path,
		{
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			command = "library.purge",
			object_digest = TEST_PNG_DIGEST,
			confirmation = TEST_PNG_DIGEST,
		},
		context.temp_allocator,
	)
	testing.expect(t, purged_ok && purged.ok)
	testing.expect_value(t, purged.message, "purged")
	object_path, object_path_ok := library_object_path(
		&state.root,
		TEST_PNG_DIGEST,
		context.temp_allocator,
	)
	testing.expect(t, object_path_ok)
	testing.expect(t, !os.exists(object_path))
	indexed, indexed_ok := library_index_capture_show(
		state.database,
		record.capture_id,
		context.temp_allocator,
	)
	testing.expect(t, indexed_ok)
	testing.expect_value(t, indexed.object_state, Library_Object_State.Purged)
	restored, restored_ok := library_service_client_exchange(
		state.socket_path,
		{
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			command = "capture.restore",
			capture_id = record.capture_id,
		},
		context.temp_allocator,
	)
	testing.expect(t, restored_ok)
	testing.expect(t, !restored.ok)
	testing.expect_value(t, restored.error_code, "object_unavailable")
}

@(test)
library_service_two_phase_orphan_purge_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.mutex_lock(&macos_path_environment_mutex)
	defer sync.mutex_unlock(&macos_path_environment_mutex)
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-service-orphan-*",
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
		HW_GALLERY_SUPPORT_OVERRIDE,
		context.temp_allocator,
	)
	defer if had_previous {
		_ = os.set_env(HW_GALLERY_SUPPORT_OVERRIDE, previous)
	} else {
		_ = os.unset_env(HW_GALLERY_SUPPORT_OVERRIDE)
	}
	testing.expect(t, os.set_env(HW_GALLERY_SUPPORT_OVERRIDE, support_path) == nil)

	root, root_error := library_root_initialize(
		library_path,
		1_500_000_000_000,
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

	candidate := test_event(
		"60000000-0000-4000-8000-000000000001",
		root.genesis.initial_device_id,
		1,
		LIBRARY_EVENT_ORPHAN_CANDIDATE,
	)
	candidate.library_id = root.genesis.library_id
	candidate.created_at_unix_ms = 1_500_000_000_100
	candidate.object_digest = TEST_PNG_DIGEST
	candidate.purge_not_before_unix_ms = 1_600_000_000_000
	ack := test_event(
		"60000000-0000-4000-8000-000000000002",
		root.genesis.initial_device_id,
		2,
		LIBRARY_EVENT_PURGE_ACK,
	)
	ack.library_id = root.genesis.library_id
	ack.created_at_unix_ms = 1_600_000_000_100
	ack.target_event_id = candidate.event_id
	ack.frontier = []Library_Frontier_Entry{{
		device_id = root.genesis.initial_device_id,
		sequence = 2,
	}}
	testing.expect_value(
		t,
		library_publish_event_uncoordinated(&root, &candidate),
		Library_File_Error.None,
	)
	testing.expect_value(
		t,
		library_publish_event_uncoordinated(&root, &ack),
		Library_File_Error.None,
	)
	settings := local_settings_initial(&root, LOCAL_SETTINGS_MODE_TEST, "")
	local_settings_reconcile_sequence(
		&settings,
		[]Library_Capture_Record{},
		[]Library_Event{candidate, ack},
	)
	testing.expect_value(t, local_settings_save(&settings), Local_Settings_Error.None)

	state: Library_Service_State
	initialize_error := library_service_initialize_configured(&state)
	testing.expect_value(t, initialize_error, Library_Service_Error.None)
	if initialize_error != .None {return}
	defer library_service_destroy(&state)
	testing.expect_value(t, len(state.scan.orphan_digests), 1)
	testing.expect_value(t, len(state.materialized.accepted_event_indices), 2)
	testing.expect_value(t, len(state.materialized.pending_event_indices), 0)
	testing.expect_value(t, len(state.materialized.stream_faults), 0)
	testing.expect_value(t, len(state.materialized.document_faults), 0)
	testing.expect(t, !library_service_ack_needed(&state))
	testing.expect(t, library_service_device_writable(&state))
	testing.expect(t, !library_service_orphan_has_reference(&state, TEST_PNG_DIGEST))
	testing.expect(t, library_now_unix_ms() >= candidate.purge_not_before_unix_ms)
	materialized_candidate, candidate_found := library_service_orphan_candidate(
		&state,
		TEST_PNG_DIGEST,
	)
	testing.expect(t, candidate_found)
	if candidate_found {
		active_ids, proof_ids, proof_ready := library_service_orphan_proof_ids(
			&state,
			materialized_candidate,
			context.temp_allocator,
		)
		testing.expect(t, proof_ready)
		testing.expect_value(t, len(proof_ids), 1)
		candidate_commit, commit_created := library_service_event_base(
			&state,
			LIBRARY_EVENT_ORPHAN_PURGE,
		)
		testing.expect(t, commit_created)
		if commit_created {
			candidate_commit.target_event_id = materialized_candidate.event_id
			candidate_commit.object_digest = materialized_candidate.object_digest
			candidate_commit.active_device_ids = active_ids[:]
			candidate_commit.proof_event_ids = proof_ids[:]
			frontier := library_service_frontier(&state, true, context.temp_allocator)
			candidate_commit.frontier = frontier[:]
			testing.expect_value(
				t,
				library_event_validate(&candidate_commit, state.root.genesis.library_id),
				Library_Document_Error.None,
			)
		}
	}
	library_service_maintenance(&state)
	testing.expect_value(t, len(state.scan.events), 3)
	testing.expect_value(t, state.settings.next_sequence, u64(4))
	object_path, object_path_ok := library_object_path(
		&state.root,
		TEST_PNG_DIGEST,
		context.temp_allocator,
	)
	testing.expect(t, object_path_ok)
	testing.expect(t, !os.exists(object_path))
	testing.expect_value(t, len(state.scan.orphan_digests), 0)
	committed := false
	for event in state.scan.events {
		if event.kind == LIBRARY_EVENT_ORPHAN_PURGE &&
		   event.target_event_id == candidate.event_id &&
		   event.object_digest == TEST_PNG_DIGEST {
			committed = true
		}
	}
	testing.expect(t, committed)
}

@(test)
library_service_reference_blocks_orphan_commit_test :: proc(t: ^testing.T) {
	record := test_capture()
	record.object_digest = TEST_PNG_DIGEST
	state: Library_Service_State
	state.scan.records = make([dynamic]Library_Capture_Record)
	defer delete(state.scan.records)
	append(&state.scan.records, record)
	candidate := test_event(
		"70000000-0000-4000-8000-000000000001",
		TEST_DEVICE_A,
		1,
		LIBRARY_EVENT_ORPHAN_CANDIDATE,
	)
	candidate.object_digest = TEST_PNG_DIGEST
	candidate.purge_not_before_unix_ms = 1
	testing.expect(t, library_service_orphan_has_reference(&state, TEST_PNG_DIGEST))
	testing.expect(t, !library_service_commit_orphan_purge(&state, &candidate))
	clear(&state.scan.records)
	candidate.purge_not_before_unix_ms = library_now_unix_ms()+1_000
	testing.expect(t, !library_service_acknowledge_or_reject_orphan(&state, &candidate))
}
