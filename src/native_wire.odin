package main

import "core:encoding/json"

NATIVE_WIRE_VERSION :: 1
NATIVE_WIRE_RAW_CHUNK_BYTES :: 192 * 1024
NATIVE_WIRE_BASE64_CHUNK_BYTES :: 256 * 1024
NATIVE_WIRE_MAX_FRAME_BYTES :: 320 * 1024
NATIVE_WIRE_MAX_RESPONSE_MEDIA_TYPE_BYTES :: 256
NATIVE_WIRE_MAX_ERROR_MESSAGE_BYTES :: 2 * 1024

NATIVE_MESSAGE_BEGIN :: "capture_begin"
NATIVE_MESSAGE_CHUNK :: "capture_chunk"
NATIVE_MESSAGE_COMMIT :: "capture_commit"
NATIVE_MESSAGE_CANCEL :: "capture_cancel"

Native_Wire_Message :: struct {
	wire_version:        int              `json:"wire_version"`,
	type:                string           `json:"type"`,
	transfer_id:         string           `json:"transfer_id"`,
	capture_id:          string           `json:"capture_id"`,
	sequence:            u64              `json:"sequence"`,
	captured_at_unix_ms: i64              `json:"captured_at_unix_ms,omitempty"`,
	page_url:            string           `json:"page_url,omitempty"`,
	page_title:          string           `json:"page_title,omitempty"`,
	current_src:         string           `json:"current_src,omitempty"`,
	alt_text:            string           `json:"alt_text,omitempty"`,
	figure_caption:      string           `json:"figure_caption,omitempty"`,
	initial_note:        string           `json:"initial_note,omitempty"`,
	element_rect:        Library_Rect     `json:"element_rect,omitempty"`,
	viewport:            Library_Viewport `json:"viewport,omitempty"`,
	response_media_type: string           `json:"response_media_type,omitempty"`,
	declared_byte_count: i64              `json:"declared_byte_count,omitempty"`,
	data_base64:         string           `json:"data_base64,omitempty"`,
	total_byte_count:    i64              `json:"total_byte_count,omitempty"`,
	reason:              string           `json:"reason,omitempty"`,
}

Native_Wire_Error :: enum {
	None,
	Too_Large,
	Decode,
	Version,
	Type,
	Identifier,
	Sequence,
	Timestamp,
	URL,
	Bounds,
	Geometry,
	Fields,
}

native_wire_geometry_valid :: proc(rect: Library_Rect, viewport: Library_Viewport) -> bool {
	return rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
	       viewport.width > 0 && viewport.height > 0 &&
	       rect.x <= viewport.width && rect.y <= viewport.height &&
	       rect.width <= viewport.width*4 && rect.height <= viewport.height*4 &&
	       viewport.width <= 100_000 && viewport.height <= 100_000
}

native_wire_begin_fields_valid :: proc(value: ^Native_Wire_Message) -> bool {
	return value.sequence == 0 &&
	       value.captured_at_unix_ms > 0 &&
	       library_http_url_valid(value.page_url) &&
	       library_http_url_valid(value.current_src) &&
	       library_text_valid(value.page_title, LIBRARY_MAX_TITLE_BYTES) &&
	       library_text_valid(value.alt_text, LIBRARY_MAX_ALT_BYTES) &&
	       library_text_valid(value.figure_caption, LIBRARY_MAX_CAPTION_BYTES) &&
	       library_text_valid(value.initial_note, LIBRARY_MAX_NOTE_BYTES) &&
	       library_text_valid(value.response_media_type, NATIVE_WIRE_MAX_RESPONSE_MEDIA_TYPE_BYTES) &&
	       value.declared_byte_count >= 0 &&
	       value.declared_byte_count <= LIBRARY_MAX_OBJECT_BYTES &&
	       native_wire_geometry_valid(value.element_rect, value.viewport) &&
	       len(value.data_base64) == 0 && value.total_byte_count == 0 &&
	       len(value.reason) == 0
}

native_wire_message_validate :: proc(value: ^Native_Wire_Message) -> Native_Wire_Error {
	if value.wire_version != NATIVE_WIRE_VERSION {return .Version}
	if !library_uuid_valid(value.transfer_id) || !library_uuid_valid(value.capture_id) {
		return .Identifier
	}
	switch value.type {
	case NATIVE_MESSAGE_BEGIN:
		if !native_wire_begin_fields_valid(value) {return .Fields}
	case NATIVE_MESSAGE_CHUNK:
		if value.sequence == 0 {return .Sequence}
		if len(value.data_base64) == 0 || len(value.data_base64) > NATIVE_WIRE_BASE64_CHUNK_BYTES {
			return .Bounds
		}
		if value.captured_at_unix_ms != 0 || len(value.page_url) != 0 ||
		   len(value.page_title) != 0 || len(value.current_src) != 0 ||
		   len(value.alt_text) != 0 || len(value.figure_caption) != 0 ||
		   len(value.initial_note) != 0 || value.element_rect != {} ||
		   value.viewport != {} || len(value.response_media_type) != 0 ||
		   value.declared_byte_count != 0 || value.total_byte_count != 0 ||
		   len(value.reason) != 0 {
			return .Fields
		}
	case NATIVE_MESSAGE_COMMIT:
		if value.sequence == 0 {return .Sequence}
		if value.total_byte_count <= 0 || value.total_byte_count > LIBRARY_MAX_OBJECT_BYTES {
			return .Bounds
		}
		if value.captured_at_unix_ms != 0 || len(value.page_url) != 0 ||
		   len(value.page_title) != 0 || len(value.current_src) != 0 ||
		   len(value.alt_text) != 0 || len(value.figure_caption) != 0 ||
		   len(value.initial_note) != 0 || value.element_rect != {} ||
		   value.viewport != {} || len(value.response_media_type) != 0 ||
		   value.declared_byte_count != 0 || len(value.data_base64) != 0 ||
		   len(value.reason) != 0 {
			return .Fields
		}
	case NATIVE_MESSAGE_CANCEL:
		if value.sequence == 0 || !library_text_valid(value.reason, NATIVE_WIRE_MAX_ERROR_MESSAGE_BYTES) {
			return .Fields
		}
		if value.captured_at_unix_ms != 0 || len(value.page_url) != 0 ||
		   len(value.page_title) != 0 || len(value.current_src) != 0 ||
		   len(value.alt_text) != 0 || len(value.figure_caption) != 0 ||
		   len(value.initial_note) != 0 || value.element_rect != {} ||
		   value.viewport != {} || len(value.response_media_type) != 0 ||
		   value.declared_byte_count != 0 || len(value.data_base64) != 0 ||
		   value.total_byte_count != 0 {
			return .Fields
		}
	case:
		return .Type
	}
	return .None
}

native_wire_message_decode :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (Native_Wire_Message, Native_Wire_Error) {
	if len(bytes) > NATIVE_WIRE_MAX_FRAME_BYTES {return {}, .Too_Large}
	value: Native_Wire_Message
	if error := json.unmarshal(bytes, &value, .JSON, allocator); error != nil {
		return {}, .Decode
	}
	return value, native_wire_message_validate(&value)
}
