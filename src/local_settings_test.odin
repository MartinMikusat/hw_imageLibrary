package main

import "core:os"
import "core:sync"
import "core:testing"
import "base:runtime"

@(test)
local_settings_round_trip_and_sequence_reconciliation_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.mutex_lock(&macos_path_environment_mutex)
	defer sync.mutex_unlock(&macos_path_environment_mutex)
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-settings-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)
	support_path, support_joined := library_join(
		[]string{temporary_root, "support"},
		context.temp_allocator,
	)
	library_path, library_joined := library_join(
		[]string{temporary_root, "library"},
		context.temp_allocator,
	)
	testing.expect(t, support_joined && library_joined)
	if !support_joined || !library_joined {return}
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
	loaded, load_error := local_settings_load(context.temp_allocator)
	testing.expect_value(t, load_error, Local_Settings_Error.None)
	expected := settings
	expected.allocator = loaded.allocator
	testing.expect_value(t, loaded, expected)
	record := test_capture(7)
	record.device_id = settings.device_id
	local_settings_reconcile_sequence(&loaded, []Library_Capture_Record{record}, nil)
	testing.expect_value(t, loaded.next_sequence, u64(8))
	bookmark, bookmark_error := macos_bookmark_create(library_path, context.temp_allocator)
	testing.expect_value(t, bookmark_error, MacOS_Path_Error.None)
	if bookmark_error != .None {return}
	rebound := library_cli_rebind_root(library_path, bookmark)
	testing.expect(t, rebound.ok)
	rebound_settings, rebound_error := local_settings_load(context.temp_allocator)
	testing.expect_value(t, rebound_error, Local_Settings_Error.None)
	testing.expect_value(t, rebound_settings.library_mode, LOCAL_SETTINGS_MODE_BOOKMARK)
	testing.expect_value(t, rebound_settings.library_id, root.genesis.library_id)
	testing.expect(t, len(rebound_settings.bookmark_base64) > 0)
}
