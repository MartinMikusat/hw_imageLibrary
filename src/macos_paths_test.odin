package main

import "core:os"
import "core:sync"
import "core:testing"
import "base:runtime"

macos_path_environment_mutex: sync.Mutex

@(test)
macos_application_support_override_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	sync.mutex_lock(&macos_path_environment_mutex)
	defer sync.mutex_unlock(&macos_path_environment_mutex)
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-support-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)
	previous, had_previous := os.lookup_env(
		HW_IMAGE_LIBRARY_SUPPORT_OVERRIDE,
		context.temp_allocator,
	)
	defer if had_previous {
		_ = os.set_env(HW_IMAGE_LIBRARY_SUPPORT_OVERRIDE, previous)
	} else {
		_ = os.unset_env(HW_IMAGE_LIBRARY_SUPPORT_OVERRIDE)
	}
	testing.expect(t, os.set_env(HW_IMAGE_LIBRARY_SUPPORT_OVERRIDE, temporary_root) == nil)
	path, path_error := macos_application_support_directory(context.temp_allocator)
	testing.expect_value(t, path_error, MacOS_Path_Error.None)
	testing.expect_value(t, path, temporary_root)
}

@(test)
macos_security_scoped_bookmark_round_trip_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	temporary_root, temp_error := os.make_directory_temp(
		"",
		"hw-image-library-bookmark-*",
		context.temp_allocator,
	)
	testing.expect(t, temp_error == nil)
	if temp_error != nil {return}
	defer os.remove_all(temporary_root)
	bookmark, bookmark_error := macos_bookmark_create(temporary_root, context.temp_allocator)
	testing.expect_value(t, bookmark_error, MacOS_Path_Error.None)
	if bookmark_error != .None {return}
	resolution, resolution_error := macos_bookmark_resolve(bookmark, context.temp_allocator)
	testing.expect(t, resolution_error == .None || resolution_error == .Stale)
	if resolution.url == nil {return}
	defer macos_bookmark_resolution_close(&resolution)
	expected_path, expected_error := os.get_absolute_path(temporary_root, context.temp_allocator)
	resolved_path, resolved_error := os.get_absolute_path(resolution.path, context.temp_allocator)
	testing.expect(t, expected_error == nil && resolved_error == nil)
	testing.expect_value(t, resolved_path, expected_path)
}
