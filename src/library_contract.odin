package main

import "core:encoding/json"
import "core:strings"

LIBRARY_SCHEMA_VERSION :: 1
LIBRARY_RECOVERY_INTERVAL_SECONDS :: i64(30 * 24 * 60 * 60)

LIBRARY_MAX_DOCUMENT_BYTES :: 256 * 1024
LIBRARY_MAX_OBJECT_BYTES :: i64(512 * 1024 * 1024)
LIBRARY_MAX_URL_BYTES :: 8 * 1024
LIBRARY_MAX_TITLE_BYTES :: 2 * 1024
LIBRARY_MAX_ALT_BYTES :: 16 * 1024
LIBRARY_MAX_CAPTION_BYTES :: 16 * 1024
LIBRARY_MAX_NOTE_BYTES :: 64 * 1024
LIBRARY_MAX_FRONTIER_DEVICES :: 256
LIBRARY_MAX_EVENT_REFERENCES :: 4096
LIBRARY_MAX_IMAGE_DIMENSION :: 100_000

LIBRARY_EVENT_DEVICE_JOIN :: "device_join"
LIBRARY_EVENT_DEVICE_ACK :: "device_ack"
LIBRARY_EVENT_DEVICE_RETIRE :: "device_retire"
LIBRARY_EVENT_NOTE_SET :: "note_set"
LIBRARY_EVENT_CAPTURE_DELETE :: "capture_delete"
LIBRARY_EVENT_CAPTURE_RESTORE :: "capture_restore"
LIBRARY_EVENT_PURGE_PROPOSE :: "purge_propose"
LIBRARY_EVENT_PURGE_ACK :: "purge_ack"
LIBRARY_EVENT_PURGE_REJECT :: "purge_reject"
LIBRARY_EVENT_OBJECT_PURGE :: "object_purge"
LIBRARY_EVENT_ORPHAN_CANDIDATE :: "orphan_candidate"
LIBRARY_EVENT_ORPHAN_PURGE :: "orphan_purge"

Library_Genesis :: struct {
	schema_version:            int    `json:"schema_version"`,
	library_id:                string `json:"library_id"`,
	created_at_unix_ms:        i64    `json:"created_at_unix_ms"`,
	recovery_interval_seconds: i64    `json:"recovery_interval_seconds"`,
	initial_device_id:         string `json:"initial_device_id"`,
}

Library_Join_Request :: struct {
	schema_version:       int    `json:"schema_version"`,
	library_id:           string `json:"library_id"`,
	device_id:            string `json:"device_id"`,
	requested_at_unix_ms: i64    `json:"requested_at_unix_ms"`,
	device_name:          string `json:"device_name"`,
}

Library_Rect :: struct {
	x:      f64 `json:"x"`,
	y:      f64 `json:"y"`,
	width:  f64 `json:"width"`,
	height: f64 `json:"height"`,
}

Library_Viewport :: struct {
	width:  f64 `json:"width"`,
	height: f64 `json:"height"`,
}

Library_Capture_Record :: struct {
	schema_version:      int              `json:"schema_version"`,
	library_id:          string           `json:"library_id"`,
	capture_id:          string           `json:"capture_id"`,
	device_id:           string           `json:"device_id"`,
	device_sequence:     u64              `json:"device_sequence"`,
	captured_at_unix_ms: i64              `json:"captured_at_unix_ms"`,
	object_digest:       string           `json:"object_digest"`,
	media_type:          string           `json:"media_type"`,
	byte_count:          i64              `json:"byte_count"`,
	pixel_width:         int              `json:"pixel_width"`,
	pixel_height:        int              `json:"pixel_height"`,
	page_url:            string           `json:"page_url"`,
	page_title:          string           `json:"page_title"`,
	current_src:         string           `json:"current_src"`,
	alt_text:            string           `json:"alt_text"`,
	figure_caption:      string           `json:"figure_caption"`,
	initial_note:        string           `json:"initial_note"`,
	reinstates_purge_event_id: string      `json:"reinstates_purge_event_id,omitempty"`,
	element_rect:        Library_Rect     `json:"element_rect"`,
	viewport:            Library_Viewport `json:"viewport"`,
}

Library_Frontier_Entry :: struct {
	device_id: string `json:"device_id"`,
	sequence:  u64    `json:"sequence"`,
}

Library_Event :: struct {
	schema_version:         int                      `json:"schema_version"`,
	library_id:             string                   `json:"library_id"`,
	event_id:               string                   `json:"event_id"`,
	device_id:              string                   `json:"device_id"`,
	device_sequence:        u64                      `json:"device_sequence"`,
	created_at_unix_ms:     i64                      `json:"created_at_unix_ms"`,
	kind:                    string                   `json:"kind"`,
	capture_id:              string                   `json:"capture_id,omitempty"`,
	target_event_id:         string                   `json:"target_event_id,omitempty"`,
	target_device_id:        string                   `json:"target_device_id,omitempty"`,
	target_device_sequence:  u64                      `json:"target_device_sequence,omitempty"`,
	note:                    string                   `json:"note,omitempty"`,
	predecessor_revisions:   []string                 `json:"predecessor_revisions,omitempty"`,
	frontier:                []Library_Frontier_Entry `json:"frontier,omitempty"`,
	object_digest:           string                   `json:"object_digest,omitempty"`,
	required_event_ids:      []string                 `json:"required_event_ids,omitempty"`,
	proof_event_ids:         []string                 `json:"proof_event_ids,omitempty"`,
	active_device_ids:       []string                 `json:"active_device_ids,omitempty"`,
	purge_not_before_unix_ms: i64                     `json:"purge_not_before_unix_ms,omitempty"`,
}

Library_Document_Error :: enum {
	None,
	Too_Large,
	Decode,
	Schema,
	Library,
	Identifier,
	Sequence,
	Timestamp,
	Bounds,
	Digest,
	Media_Type,
	URL,
	Geometry,
	Event_Kind,
	Event_Fields,
	Duplicate,
}

library_uuid_valid :: proc(value: string) -> bool {
	if len(value) != 36 {return false}
	for index in 0..<len(value) {
		byte := value[index]
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if byte != '-' {return false}
			continue
		}
		if !((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f')) {
			return false
		}
	}
	return true
}

library_lower_hex_valid :: proc(value: string) -> bool {
	for byte in transmute([]u8)value {
		if !((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f')) {
			return false
		}
	}
	return true
}

library_digest_valid :: proc(value: string) -> bool {
	return len(value) == 64 && library_lower_hex_valid(value)
}

library_text_valid :: proc(value: string, maximum: int) -> bool {
	if len(value) > maximum {return false}
	for byte in transmute([]u8)value {
		if byte == 0 {return false}
	}
	return true
}

library_http_url_valid :: proc(value: string) -> bool {
	if len(value) == 0 || len(value) > LIBRARY_MAX_URL_BYTES {return false}
	if !strings.has_prefix(value, "https://") && !strings.has_prefix(value, "http://") {
		return false
	}
	for byte in transmute([]u8)value {
		if byte == 0 || byte == '\n' || byte == '\r' || byte == '\t' {return false}
	}
	return true
}

library_media_type_valid :: proc(value: string) -> bool {
	switch value {
	case "image/avif", "image/gif", "image/jpeg", "image/png", "image/webp":
		return true
	}
	return false
}

library_genesis_validate :: proc(value: ^Library_Genesis) -> Library_Document_Error {
	if value.schema_version != LIBRARY_SCHEMA_VERSION {return .Schema}
	if !library_uuid_valid(value.library_id) || !library_uuid_valid(value.initial_device_id) {
		return .Identifier
	}
	if value.created_at_unix_ms <= 0 {return .Timestamp}
	if value.recovery_interval_seconds != LIBRARY_RECOVERY_INTERVAL_SECONDS {
		return .Bounds
	}
	return .None
}

library_join_request_validate :: proc(
	value: ^Library_Join_Request,
	library_id: string,
) -> Library_Document_Error {
	if value.schema_version != LIBRARY_SCHEMA_VERSION {return .Schema}
	if value.library_id != library_id {return .Library}
	if !library_uuid_valid(value.device_id) {return .Identifier}
	if value.requested_at_unix_ms <= 0 {return .Timestamp}
	if len(value.device_name) == 0 || !library_text_valid(value.device_name, 256) {
		return .Bounds
	}
	return .None
}

library_capture_validate :: proc(
	value: ^Library_Capture_Record,
	library_id: string,
) -> Library_Document_Error {
	if value.schema_version != LIBRARY_SCHEMA_VERSION {return .Schema}
	if value.library_id != library_id {return .Library}
	if !library_uuid_valid(value.capture_id) || !library_uuid_valid(value.device_id) {
		return .Identifier
	}
	if value.device_sequence == 0 {return .Sequence}
	if value.captured_at_unix_ms <= 0 {return .Timestamp}
	if !library_digest_valid(value.object_digest) {return .Digest}
	if len(value.reinstates_purge_event_id) > 0 &&
	   !library_uuid_valid(value.reinstates_purge_event_id) {
		return .Identifier
	}
	if !library_media_type_valid(value.media_type) {return .Media_Type}
	if value.byte_count <= 0 || value.byte_count > LIBRARY_MAX_OBJECT_BYTES {
		return .Bounds
	}
	if value.pixel_width <= 0 || value.pixel_width > LIBRARY_MAX_IMAGE_DIMENSION ||
	   value.pixel_height <= 0 || value.pixel_height > LIBRARY_MAX_IMAGE_DIMENSION {
		return .Bounds
	}
	if !library_http_url_valid(value.page_url) || !library_http_url_valid(value.current_src) {
		return .URL
	}
	if !library_text_valid(value.page_title, LIBRARY_MAX_TITLE_BYTES) ||
	   !library_text_valid(value.alt_text, LIBRARY_MAX_ALT_BYTES) ||
	   !library_text_valid(value.figure_caption, LIBRARY_MAX_CAPTION_BYTES) ||
	   !library_text_valid(value.initial_note, LIBRARY_MAX_NOTE_BYTES) {
		return .Bounds
	}
	if value.element_rect.x < 0 || value.element_rect.y < 0 ||
	   value.element_rect.width <= 0 || value.element_rect.height <= 0 ||
	   value.viewport.width <= 0 || value.viewport.height <= 0 ||
	   value.element_rect.x > value.viewport.width ||
	   value.element_rect.y > value.viewport.height ||
	   value.element_rect.width > value.viewport.width * 4 ||
	   value.element_rect.height > value.viewport.height * 4 ||
	   value.viewport.width > 100_000 || value.viewport.height > 100_000 {
		return .Geometry
	}
	return .None
}

library_frontier_validate :: proc(entries: []Library_Frontier_Entry) -> bool {
	if len(entries) == 0 || len(entries) > LIBRARY_MAX_FRONTIER_DEVICES {return false}
	for entry, index in entries {
		if !library_uuid_valid(entry.device_id) {return false}
		if index > 0 && entries[index-1].device_id >= entry.device_id {return false}
	}
	return true
}

library_id_list_valid :: proc(values: []string, maximum: int, allow_empty := false) -> bool {
	if (!allow_empty && len(values) == 0) || len(values) > maximum {return false}
	for value, index in values {
		if !library_uuid_valid(value) {return false}
		if index > 0 && values[index-1] >= value {return false}
	}
	return true
}

library_event_kind_valid :: proc(kind: string) -> bool {
	switch kind {
	case LIBRARY_EVENT_DEVICE_JOIN,
	     LIBRARY_EVENT_DEVICE_ACK,
	     LIBRARY_EVENT_DEVICE_RETIRE,
	     LIBRARY_EVENT_NOTE_SET,
	     LIBRARY_EVENT_CAPTURE_DELETE,
	     LIBRARY_EVENT_CAPTURE_RESTORE,
	     LIBRARY_EVENT_PURGE_PROPOSE,
	     LIBRARY_EVENT_PURGE_ACK,
	     LIBRARY_EVENT_PURGE_REJECT,
	     LIBRARY_EVENT_OBJECT_PURGE,
	     LIBRARY_EVENT_ORPHAN_CANDIDATE,
	     LIBRARY_EVENT_ORPHAN_PURGE:
		return true
	}
	return false
}

library_event_validate :: proc(
	value: ^Library_Event,
	library_id: string,
) -> Library_Document_Error {
	if value.schema_version != LIBRARY_SCHEMA_VERSION {return .Schema}
	if value.library_id != library_id {return .Library}
	if !library_uuid_valid(value.event_id) || !library_uuid_valid(value.device_id) {
		return .Identifier
	}
	if value.device_sequence == 0 {return .Sequence}
	if value.created_at_unix_ms <= 0 {return .Timestamp}
	if !library_event_kind_valid(value.kind) {return .Event_Kind}
	if len(value.note) > LIBRARY_MAX_NOTE_BYTES ||
	   len(value.predecessor_revisions) > LIBRARY_MAX_EVENT_REFERENCES ||
	   len(value.required_event_ids) > LIBRARY_MAX_EVENT_REFERENCES ||
	   len(value.proof_event_ids) > LIBRARY_MAX_EVENT_REFERENCES ||
	   len(value.active_device_ids) > LIBRARY_MAX_FRONTIER_DEVICES {
		return .Bounds
	}

	switch value.kind {
	case LIBRARY_EVENT_DEVICE_JOIN:
		if !library_uuid_valid(value.target_device_id) ||
		   !library_event_fields_empty(value, false, true, false, false, false, false, false, false, false) {
			return .Event_Fields
		}
	case LIBRARY_EVENT_DEVICE_ACK:
		if !library_frontier_validate(value.frontier) ||
		   !library_frontier_covers(value.frontier, value.device_id, value.device_sequence) ||
		   !library_event_fields_empty(value, false, false, false, false, true, false, false, false, false) {
			return .Event_Fields
		}
	case LIBRARY_EVENT_DEVICE_RETIRE:
		if !library_uuid_valid(value.target_device_id) || value.target_device_sequence == 0 ||
		   !library_event_fields_empty(value, false, true, true, false, false, false, false, false, false) {
			return .Event_Fields
		}
	case LIBRARY_EVENT_NOTE_SET:
		if !library_uuid_valid(value.capture_id) ||
		   !library_text_valid(value.note, LIBRARY_MAX_NOTE_BYTES) ||
		   !library_id_list_valid(value.predecessor_revisions, LIBRARY_MAX_EVENT_REFERENCES) ||
		   !library_event_fields_empty(value, true, false, false, true, false, false, false, false, false) {
			return .Event_Fields
		}
	case LIBRARY_EVENT_CAPTURE_DELETE:
		if !library_uuid_valid(value.capture_id) ||
		   !library_event_fields_empty(value, true, false, false, false, false, false, false, false, false) {
			return .Event_Fields
		}
	case LIBRARY_EVENT_CAPTURE_RESTORE:
		if !library_uuid_valid(value.capture_id) || !library_uuid_valid(value.target_event_id) ||
		   !library_event_fields_empty(value, true, false, false, false, false, false, false, false, true) {
			return .Event_Fields
		}
	case LIBRARY_EVENT_PURGE_PROPOSE:
		if !library_digest_valid(value.object_digest) ||
		   !library_id_list_valid(value.required_event_ids, LIBRARY_MAX_EVENT_REFERENCES) ||
		   !library_id_list_valid(value.active_device_ids, LIBRARY_MAX_FRONTIER_DEVICES) ||
		   value.purge_not_before_unix_ms <= 0 ||
		   !library_event_fields_empty(value, false, false, false, false, false, true, true, true, false, false, true) {
			return .Event_Fields
		}
	case LIBRARY_EVENT_PURGE_ACK, LIBRARY_EVENT_PURGE_REJECT:
		if !library_uuid_valid(value.target_event_id) ||
		   !library_frontier_validate(value.frontier) ||
		   !library_frontier_covers(value.frontier, value.device_id, value.device_sequence) ||
		   !library_event_fields_empty(value, false, false, false, value.kind == LIBRARY_EVENT_PURGE_REJECT, true, false, false, false, true) {
			return .Event_Fields
		}
	case LIBRARY_EVENT_OBJECT_PURGE:
		if !library_uuid_valid(value.target_event_id) ||
		   !library_digest_valid(value.object_digest) ||
		   !library_id_list_valid(value.required_event_ids, LIBRARY_MAX_EVENT_REFERENCES) ||
		   !library_id_list_valid(value.proof_event_ids, LIBRARY_MAX_EVENT_REFERENCES) ||
		   !library_id_list_valid(value.active_device_ids, LIBRARY_MAX_FRONTIER_DEVICES) ||
		   !library_frontier_validate(value.frontier) ||
		   !library_event_fields_empty(value, false, false, false, false, true, true, true, true, true, true) {
			return .Event_Fields
		}
	case LIBRARY_EVENT_ORPHAN_CANDIDATE:
		if !library_digest_valid(value.object_digest) || value.purge_not_before_unix_ms <= 0 ||
		   !library_event_fields_empty(value, false, false, false, false, false, true, false, false, false, false, true) {
			return .Event_Fields
		}
	case LIBRARY_EVENT_ORPHAN_PURGE:
		if !library_uuid_valid(value.target_event_id) ||
		   !library_digest_valid(value.object_digest) ||
		   !library_id_list_valid(value.active_device_ids, LIBRARY_MAX_FRONTIER_DEVICES) ||
		   !library_id_list_valid(value.proof_event_ids, LIBRARY_MAX_EVENT_REFERENCES) ||
		   !library_frontier_validate(value.frontier) ||
		   !library_event_fields_empty(value, false, false, false, false, true, true, false, true, true, true) {
			return .Event_Fields
		}
	}
	return .None
}

library_frontier_covers :: proc(
	frontier: []Library_Frontier_Entry,
	device_id: string,
	sequence: u64,
) -> bool {
	for entry in frontier {
		if entry.device_id == device_id {return entry.sequence >= sequence}
	}
	return false
}

library_event_fields_empty :: proc(
	value: ^Library_Event,
	allow_capture_id,
	allow_target_device_id,
	allow_target_device_sequence,
	allow_note,
	allow_frontier,
	allow_object_digest,
	allow_required_event_ids,
	allow_active_device_ids,
	allow_target_event_id: bool,
	allow_proof_event_ids := false,
	allow_purge_not_before := false,
) -> bool {
	return (allow_capture_id || len(value.capture_id) == 0) &&
	       (allow_target_event_id || len(value.target_event_id) == 0) &&
	       (allow_target_device_id || len(value.target_device_id) == 0) &&
	       (allow_target_device_sequence || value.target_device_sequence == 0) &&
	       (allow_note || (len(value.note) == 0 && len(value.predecessor_revisions) == 0)) &&
	       (allow_frontier || len(value.frontier) == 0) &&
	       (allow_object_digest || len(value.object_digest) == 0) &&
	       (allow_required_event_ids || len(value.required_event_ids) == 0) &&
	       (allow_proof_event_ids || len(value.proof_event_ids) == 0) &&
	       (allow_active_device_ids || len(value.active_device_ids) == 0) &&
	       (allow_purge_not_before || value.purge_not_before_unix_ms == 0)
}

library_genesis_decode :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (Library_Genesis, Library_Document_Error) {
	if len(bytes) > LIBRARY_MAX_DOCUMENT_BYTES {return {}, .Too_Large}
	value: Library_Genesis
	if error := json.unmarshal(bytes, &value, .JSON, allocator); error != nil {
		return {}, .Decode
	}
	return value, library_genesis_validate(&value)
}

library_capture_decode :: proc(
	bytes: []u8,
	library_id: string,
	allocator := context.allocator,
) -> (Library_Capture_Record, Library_Document_Error) {
	if len(bytes) > LIBRARY_MAX_DOCUMENT_BYTES {return {}, .Too_Large}
	value: Library_Capture_Record
	if error := json.unmarshal(bytes, &value, .JSON, allocator); error != nil {
		return {}, .Decode
	}
	return value, library_capture_validate(&value, library_id)
}

library_join_request_decode :: proc(
	bytes: []u8,
	library_id: string,
	allocator := context.allocator,
) -> (Library_Join_Request, Library_Document_Error) {
	if len(bytes) > LIBRARY_MAX_DOCUMENT_BYTES {return {}, .Too_Large}
	value: Library_Join_Request
	if error := json.unmarshal(bytes, &value, .JSON, allocator); error != nil {
		return {}, .Decode
	}
	return value, library_join_request_validate(&value, library_id)
}

library_event_decode :: proc(
	bytes: []u8,
	library_id: string,
	allocator := context.allocator,
) -> (Library_Event, Library_Document_Error) {
	if len(bytes) > LIBRARY_MAX_DOCUMENT_BYTES {return {}, .Too_Large}
	value: Library_Event
	if error := json.unmarshal(bytes, &value, .JSON, allocator); error != nil {
		return {}, .Decode
	}
	return value, library_event_validate(&value, library_id)
}

library_document_encode :: proc(value: $T, allocator := context.allocator) -> ([]u8, bool) {
	bytes, error := json.marshal(value, {pretty=true, use_spaces=true, spaces=2}, allocator)
	return bytes, error == nil && len(bytes) <= LIBRARY_MAX_DOCUMENT_BYTES
}
