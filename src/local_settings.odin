package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "base:runtime"

LOCAL_SETTINGS_SCHEMA_VERSION :: 1
LOCAL_SETTINGS_MAX_BYTES :: 1024 * 1024
LOCAL_SETTINGS_MODE_ICLOUD :: "icloud"
LOCAL_SETTINGS_MODE_BOOKMARK :: "bookmark"
LOCAL_SETTINGS_MODE_TEST :: "test"
LOCAL_MEMBERSHIP_INITIAL :: "initial"
LOCAL_MEMBERSHIP_PENDING :: "pending"
LOCAL_MEMBERSHIP_ACTIVE :: "active"
LOCAL_MEMBERSHIP_RETIRED :: "retired"

Local_Settings :: struct {
	schema_version:    int    `json:"schema_version"`,
	library_id:        string `json:"library_id"`,
	library_path:      string `json:"library_path"`,
	library_mode:      string `json:"library_mode"`,
	bookmark_base64:   string `json:"bookmark_base64,omitempty"`,
	device_id:         string `json:"device_id"`,
	membership_status: string `json:"membership_status"`,
	next_sequence:     u64    `json:"next_sequence"`,
	interface_theme:       string `json:"interface_theme,omitempty"`,
	recognition_disabled:  bool   `json:"recognition_disabled,omitempty"`,
	recognition_confidence: f32   `json:"recognition_confidence,omitempty"`,
	allocator:             runtime.Allocator `json:"-",`
}

Local_Settings_Error :: enum {
	None,
	Not_Found,
	Path,
	Read,
	Decode,
	Invalid,
	Write,
}

local_settings_clone :: proc(
	value: ^Local_Settings,
	allocator := context.allocator,
) -> Local_Settings {
	return {
		schema_version = value.schema_version,
		library_id = strings.clone(value.library_id, allocator),
		library_path = strings.clone(value.library_path, allocator),
		library_mode = strings.clone(value.library_mode, allocator),
		bookmark_base64 = strings.clone(value.bookmark_base64, allocator),
		device_id = strings.clone(value.device_id, allocator),
		membership_status = strings.clone(value.membership_status, allocator),
		next_sequence = value.next_sequence,
		interface_theme = strings.clone(value.interface_theme, allocator),
		allocator = allocator,
	}
}

local_settings_destroy :: proc(
	value: ^Local_Settings,
	allocator := context.allocator,
) {
	if value == nil {return}
	owner := value.allocator
	if owner.procedure == nil {owner = allocator}
	delete(value.library_id, owner)
	delete(value.library_path, owner)
	delete(value.library_mode, owner)
	delete(value.bookmark_base64, owner)
	delete(value.device_id, owner)
	delete(value.membership_status, owner)
	delete(value.interface_theme, owner)
	value^ = {}
}

local_settings_validate :: proc(value: ^Local_Settings) -> bool {
	if value.schema_version != LOCAL_SETTINGS_SCHEMA_VERSION ||
	   !library_uuid_valid(value.library_id) ||
	   !library_uuid_valid(value.device_id) ||
	   value.next_sequence == 0 || len(value.library_path) == 0 ||
	   len(value.library_path) > 32*1024 || !filepath.is_abs(value.library_path) {
		return false
	}
	switch value.library_mode {
	case LOCAL_SETTINGS_MODE_ICLOUD:
		if len(value.bookmark_base64) != 0 {return false}
	case LOCAL_SETTINGS_MODE_BOOKMARK:
		if len(value.bookmark_base64) == 0 || len(value.bookmark_base64) > 512*1024 {
			return false
		}
	case LOCAL_SETTINGS_MODE_TEST:
	case:
		return false
	}
	switch value.membership_status {
	case LOCAL_MEMBERSHIP_INITIAL,
	     LOCAL_MEMBERSHIP_PENDING,
	     LOCAL_MEMBERSHIP_ACTIVE,
	     LOCAL_MEMBERSHIP_RETIRED:
	case:
		return false
	}
	if len(value.interface_theme) > 0 &&
	   value.interface_theme != "hw-light" &&
	   value.interface_theme != "hw-dark" {
		return false
	}
	if value.recognition_confidence < 0 || value.recognition_confidence > 1 {
		return false
	}
	return true
}

local_settings_path :: proc(allocator := context.allocator) -> (string, Local_Settings_Error) {
	support, support_error := macos_application_support_directory(allocator)
	if support_error != .None {return "", .Path}
	path, joined := library_join([]string{support, "settings-v1.json"}, allocator)
	if !joined {return "", .Path}
	return path, .None
}

local_atomic_replace_bytes :: proc(path: string, bytes: []u8) -> bool {
	parent := filepath.dir(path)
	if !library_ensure_directory(parent) {return false}
	id, id_ok := library_uuid_new(context.temp_allocator)
	if !id_ok {return false}
	temporary_name := fmt.tprintf(".settings-partial-%s", id)
	temporary_path, joined := library_join([]string{parent, temporary_name}, context.temp_allocator)
	if !joined {return false}
	if library_write_synced_exclusive(temporary_path, bytes) != .None {return false}
	temporary_exists := true
	defer if temporary_exists {_ = os.remove(temporary_path)}
	if os.rename(temporary_path, path) != nil {return false}
	temporary_exists = false
	return library_sync_directory(parent)
}

local_settings_save :: proc(value: ^Local_Settings) -> Local_Settings_Error {
	if !local_settings_validate(value) {return .Invalid}
	path, path_error := local_settings_path(context.temp_allocator)
	if path_error != .None {return path_error}
	bytes, encode_error := json.marshal(
		value^,
		{pretty=true, use_spaces=true, spaces=2},
		context.temp_allocator,
	)
	if encode_error != nil || len(bytes) > LOCAL_SETTINGS_MAX_BYTES {return .Write}
	if !local_atomic_replace_bytes(path, bytes) {return .Write}
	return .None
}

local_settings_load :: proc(
	allocator := context.allocator,
) -> (Local_Settings, Local_Settings_Error) {
	path, path_error := local_settings_path(context.temp_allocator)
	if path_error != .None {return {}, path_error}
	bytes, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		return {}, read_error == .Not_Exist ? .Not_Found : .Read
	}
	if len(bytes) > LOCAL_SETTINGS_MAX_BYTES {return {}, .Invalid}
	value: Local_Settings
	if decode_error := json.unmarshal(bytes, &value, .JSON, allocator); decode_error != nil {
		return {}, .Decode
	}
	if !local_settings_validate(&value) {return {}, .Invalid}
	value.allocator = allocator
	return value, .None
}

local_settings_initial :: proc(
	root: ^Library_Root,
	library_mode, bookmark_base64: string,
) -> Local_Settings {
	return {
		schema_version = LOCAL_SETTINGS_SCHEMA_VERSION,
		library_id = root.genesis.library_id,
		library_path = root.path,
		library_mode = library_mode,
		bookmark_base64 = bookmark_base64,
		device_id = root.genesis.initial_device_id,
		membership_status = LOCAL_MEMBERSHIP_INITIAL,
		next_sequence = 1,
		interface_theme = "hw-light",
	}
}

local_settings_reconcile_sequence :: proc(
	value: ^Local_Settings,
	records: []Library_Capture_Record,
	events: []Library_Event,
) {
	maximum: u64
	for record in records {
		if record.device_id == value.device_id {maximum = max(maximum, record.device_sequence)}
	}
	for event in events {
		if event.device_id == value.device_id {maximum = max(maximum, event.device_sequence)}
	}
	value.next_sequence = max(value.next_sequence, maximum+1)
}
