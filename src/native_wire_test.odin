package main

import "core:encoding/json"
import os "core:os/old"
import "core:testing"
import "base:runtime"

Native_Wire_Fixtures :: struct {
	valid:   []Native_Wire_Message `json:"valid"`,
	invalid: []Native_Wire_Message `json:"invalid"`,
}

@(test)
native_wire_shared_fixtures_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	bytes, read_ok := os.read_entire_file(
		"contracts/native-message-fixtures.json",
		context.temp_allocator,
	)
	testing.expect(t, read_ok)
	if !read_ok {return}
	fixtures: Native_Wire_Fixtures
	decode_error := json.unmarshal(bytes, &fixtures, .JSON, context.temp_allocator)
	testing.expect(t, decode_error == nil)
	if decode_error != nil {return}
	testing.expect(t, len(fixtures.valid) > 0)
	testing.expect(t, len(fixtures.invalid) > 0)
	for &message in fixtures.valid {
		testing.expect_value(
			t,
			native_wire_message_validate(&message),
			Native_Wire_Error.None,
		)
	}
	for &message in fixtures.invalid {
		testing.expect(t, native_wire_message_validate(&message) != .None)
	}
}

@(test)
native_wire_rejects_cross_variant_fields_test :: proc(t: ^testing.T) {
	message := Native_Wire_Message{
		wire_version = NATIVE_WIRE_VERSION,
		type = NATIVE_MESSAGE_CHUNK,
		transfer_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
		capture_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
		sequence = 1,
		data_base64 = "AA==",
		page_url = "https://example.com/hidden-field",
	}
	testing.expect_value(
		t,
		native_wire_message_validate(&message),
		Native_Wire_Error.Fields,
	)
}
