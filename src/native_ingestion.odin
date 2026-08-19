package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

NATIVE_INGESTION_MAX_TRANSFERS :: 8

Native_Wire_Response :: struct {
	wire_version:   int    `json:"wire_version"`,
	ok:             bool   `json:"ok"`,
	type:           string `json:"type"`,
	transfer_id:    string `json:"transfer_id,omitempty"`,
	capture_id:     string `json:"capture_id,omitempty"`,
	next_sequence:  u64    `json:"next_sequence,omitempty"`,
	object_digest:  string `json:"object_digest,omitempty"`,
	media_type:     string `json:"media_type,omitempty"`,
	byte_count:     i64    `json:"byte_count,omitempty"`,
	pixel_width:    int    `json:"pixel_width,omitempty"`,
	pixel_height:   int    `json:"pixel_height,omitempty"`,
	error_code:     string `json:"error_code,omitempty"`,
	message:        string `json:"message,omitempty"`,
}

Native_Transfer :: struct {
	begin:         Native_Wire_Message,
	staging_path:  string,
	file:          ^os.File,
	next_sequence: u64,
	byte_count:    i64,
}

native_wire_begin_clone :: proc(
	value: ^Native_Wire_Message,
	allocator := context.allocator,
) -> Native_Wire_Message {
	return {
		wire_version = value.wire_version,
		type = strings.clone(value.type, allocator),
		transfer_id = strings.clone(value.transfer_id, allocator),
		capture_id = strings.clone(value.capture_id, allocator),
		sequence = value.sequence,
		captured_at_unix_ms = value.captured_at_unix_ms,
		page_url = strings.clone(value.page_url, allocator),
		page_title = strings.clone(value.page_title, allocator),
		current_src = strings.clone(value.current_src, allocator),
		alt_text = strings.clone(value.alt_text, allocator),
		figure_caption = strings.clone(value.figure_caption, allocator),
		initial_note = strings.clone(value.initial_note, allocator),
		element_rect = value.element_rect,
		viewport = value.viewport,
		response_media_type = strings.clone(value.response_media_type, allocator),
		declared_byte_count = value.declared_byte_count,
	}
}

native_wire_begin_destroy :: proc(
	value: ^Native_Wire_Message,
	allocator := context.allocator,
) {
	delete(value.type, allocator)
	delete(value.transfer_id, allocator)
	delete(value.capture_id, allocator)
	delete(value.page_url, allocator)
	delete(value.page_title, allocator)
	delete(value.current_src, allocator)
	delete(value.alt_text, allocator)
	delete(value.figure_caption, allocator)
	delete(value.initial_note, allocator)
	delete(value.response_media_type, allocator)
	value^ = {}
}

native_transfer_destroy :: proc(
	value: ^Native_Transfer,
	remove_staging := true,
) {
	if value.file != nil {
		_ = os.close(value.file)
		value.file = nil
	}
	if remove_staging && len(value.staging_path) > 0 {
		_ = os.remove(value.staging_path)
	}
	native_wire_begin_destroy(&value.begin)
	delete(value.staging_path)
	value^ = {}
}

native_ingestion_destroy :: proc(state: ^Library_Service_State) {
	for &transfer in state.transfers {native_transfer_destroy(&transfer)}
	delete(state.transfers)
	state.transfers = nil
}

native_ingestion_response_error :: proc(
	message: ^Native_Wire_Message,
	code, detail: string,
) -> Native_Wire_Response {
	return {
		wire_version = NATIVE_WIRE_VERSION,
		type = "capture_error",
		transfer_id = message.transfer_id,
		capture_id = message.capture_id,
		error_code = code,
		message = detail,
	}
}

native_ingestion_transfer_index :: proc(
	state: ^Library_Service_State,
	transfer_id: string,
) -> (int, bool) {
	for transfer, index in state.transfers {
		if transfer.begin.transfer_id == transfer_id {return index, true}
	}
	return -1, false
}

native_ingestion_staging_directory :: proc(
	state: ^Library_Service_State,
	allocator := context.allocator,
) -> (string, bool) {
	return library_join([]string{state.support_path, "staging-v1"}, allocator)
}

native_ingestion_cleanup_staging :: proc(state: ^Library_Service_State) {
	staging_directory, staging_ok := native_ingestion_staging_directory(
		state,
		context.temp_allocator,
	)
	if !staging_ok {return}
	handle, open_error := os.open(staging_directory)
	if open_error != nil {return}
	entries, read_error := os.read_dir(handle, -1, context.temp_allocator)
	_ = os.close(handle)
	if read_error != nil {return}
	for entry in entries {
		if entry.type != .Directory && strings.has_suffix(entry.name, ".part") {
			_ = os.remove(entry.fullpath)
		}
	}
}

native_ingestion_remove_transfer :: proc(
	state: ^Library_Service_State,
	index: int,
) {
	native_transfer_destroy(&state.transfers[index])
	ordered_remove(&state.transfers, index)
}

native_ingestion_begin :: proc(
	state: ^Library_Service_State,
	message: ^Native_Wire_Message,
) -> Native_Wire_Response {
	if !state.index_available {
		return native_ingestion_response_error(
			message,
			"index_unavailable",
			"Rebuild the local index before starting another capture.",
		)
	}
	if _, blocked := library_service_write_barrier(state); blocked {
		return native_ingestion_response_error(
			message,
			"purge_barrier",
			"A purge barrier blocks new captures.",
		)
	}
	if !library_service_device_writable(state) {
		return native_ingestion_response_error(
			message,
			"device_not_writable",
			"This device is not an active authorized writer.",
		)
	}
	if existing, found := library_index_capture_show(
		state.database,
		message.capture_id,
		context.temp_allocator,
	); found {
		return {
			wire_version = NATIVE_WIRE_VERSION,
			ok = true,
			type = "capture_stored",
			transfer_id = message.transfer_id,
			capture_id = message.capture_id,
			object_digest = existing.object_digest,
			media_type = existing.media_type,
			byte_count = existing.byte_count,
			pixel_width = existing.pixel_width,
			pixel_height = existing.pixel_height,
		}
	}
	if transfer_index, found := native_ingestion_transfer_index(state, message.transfer_id); found {
		transfer := &state.transfers[transfer_index]
		if transfer.begin.capture_id != message.capture_id {
			return native_ingestion_response_error(message, "transfer_collision", "The transfer identifier is already in use.")
		}
		return {
			wire_version = NATIVE_WIRE_VERSION,
			ok = true,
			type = "capture_ready",
			transfer_id = message.transfer_id,
			capture_id = message.capture_id,
			next_sequence = transfer.next_sequence,
		}
	}
	if len(state.transfers) >= NATIVE_INGESTION_MAX_TRANSFERS {
		return native_ingestion_response_error(message, "busy", "Too many capture transfers are active.")
	}
	staging_directory, staging_ok := native_ingestion_staging_directory(
		state,
		context.temp_allocator,
	)
	if !staging_ok || !library_ensure_directory(staging_directory) {
		return native_ingestion_response_error(message, "staging", "The local staging directory is unavailable.")
	}
	staging_name := fmt.tprintf("%s.part", message.transfer_id)
	staging_path, staging_path_ok := library_join(
		[]string{staging_directory, staging_name},
		context.temp_allocator,
	)
	if !staging_path_ok {
		return native_ingestion_response_error(message, "staging", "The local staging path is invalid.")
	}
	if os.exists(staging_path) {_ = os.remove(staging_path)}
	file, open_error := os.open(
		staging_path,
		os.O_WRONLY | os.O_CREATE | os.O_EXCL,
		os.Permissions_Read_All + {.Write_User},
	)
	if open_error != nil {
		return native_ingestion_response_error(message, "staging", "The local staging file could not be created.")
	}
	append(&state.transfers, Native_Transfer{
		begin = native_wire_begin_clone(message),
		staging_path = strings.clone(staging_path),
		file = file,
		next_sequence = 1,
	})
	return {
		wire_version = NATIVE_WIRE_VERSION,
		ok = true,
		type = "capture_ready",
		transfer_id = message.transfer_id,
		capture_id = message.capture_id,
		next_sequence = 1,
	}
}

native_ingestion_chunk :: proc(
	state: ^Library_Service_State,
	message: ^Native_Wire_Message,
) -> Native_Wire_Response {
	transfer_index, found := native_ingestion_transfer_index(state, message.transfer_id)
	if !found {
		return native_ingestion_response_error(message, "transfer_not_found", "The capture transfer is not active.")
	}
	transfer := &state.transfers[transfer_index]
	if transfer.begin.capture_id != message.capture_id ||
	   message.sequence != transfer.next_sequence {
		native_ingestion_remove_transfer(state, transfer_index)
		return native_ingestion_response_error(message, "sequence", "The capture chunk sequence is invalid.")
	}
	bytes, decode_error := base64.decode(message.data_base64, allocator=context.temp_allocator)
	if decode_error != nil || len(bytes) == 0 || len(bytes) > NATIVE_WIRE_RAW_CHUNK_BYTES {
		native_ingestion_remove_transfer(state, transfer_index)
		return native_ingestion_response_error(message, "chunk", "The capture chunk is not valid bounded base64.")
	}
	new_byte_count := transfer.byte_count + i64(len(bytes))
	if new_byte_count > LIBRARY_MAX_OBJECT_BYTES ||
	   (transfer.begin.declared_byte_count > 0 &&
	    new_byte_count > transfer.begin.declared_byte_count) {
		native_ingestion_remove_transfer(state, transfer_index)
		return native_ingestion_response_error(message, "byte_count", "The transfer exceeds its byte-count bound.")
	}
	written := 0
	for written < len(bytes) {
		count, write_error := os.write(transfer.file, bytes[written:])
		if write_error != nil || count <= 0 {
			native_ingestion_remove_transfer(state, transfer_index)
			return native_ingestion_response_error(message, "staging_write", "The capture chunk could not be staged.")
		}
		written += count
	}
	transfer.byte_count = new_byte_count
	transfer.next_sequence += 1
	return {
		wire_version = NATIVE_WIRE_VERSION,
		ok = true,
		type = "capture_chunk_ack",
		transfer_id = message.transfer_id,
		capture_id = message.capture_id,
		next_sequence = transfer.next_sequence,
		byte_count = transfer.byte_count,
	}
}

native_ingestion_orphan_candidate :: proc(
	state: ^Library_Service_State,
	object_digest: string,
) {
	event, event_ok := library_service_event_base(state, LIBRARY_EVENT_ORPHAN_CANDIDATE)
	if !event_ok {return}
	event.object_digest = object_digest
	event.purge_not_before_unix_ms = library_now_unix_ms() +
		LIBRARY_RECOVERY_INTERVAL_SECONDS*1000
	_, _ = library_service_publish_event(state, &event)
}

native_ingestion_commit :: proc(
	state: ^Library_Service_State,
	message: ^Native_Wire_Message,
) -> Native_Wire_Response {
	transfer_index, found := native_ingestion_transfer_index(state, message.transfer_id)
	if !found {
		return native_ingestion_response_error(message, "transfer_not_found", "The capture transfer is not active.")
	}
	transfer := &state.transfers[transfer_index]
	if transfer.begin.capture_id != message.capture_id ||
	   message.sequence != transfer.next_sequence ||
	   message.total_byte_count != transfer.byte_count ||
	   (transfer.begin.declared_byte_count > 0 &&
	    transfer.begin.declared_byte_count != transfer.byte_count) {
		native_ingestion_remove_transfer(state, transfer_index)
		return native_ingestion_response_error(message, "byte_count", "The commit does not match the staged transfer.")
	}
	if os.sync(transfer.file) != nil || os.close(transfer.file) != nil {
		transfer.file = nil
		native_ingestion_remove_transfer(state, transfer_index)
		return native_ingestion_response_error(message, "staging_sync", "The staged capture could not be flushed.")
	}
	transfer.file = nil
	image_info, image_valid := macos_image_inspect(transfer.staging_path)
	digest, byte_count, hashed := library_sha256_file(
		transfer.staging_path,
		context.temp_allocator,
	)
	if !image_valid || !hashed || byte_count != transfer.byte_count {
		native_ingestion_remove_transfer(state, transfer_index)
		return native_ingestion_response_error(message, "image", "The response body is not a supported decodable image.")
	}
	media_hint := strings.to_lower(
		strings.trim_space(transfer.begin.response_media_type),
		context.temp_allocator,
	)
	if separator := strings.index_byte(media_hint, ';'); separator >= 0 {
		media_hint = strings.trim_space(media_hint[:separator])
	}
	if len(media_hint) > 0 && media_hint != image_info.media_type {
		native_ingestion_remove_transfer(state, transfer_index)
		return native_ingestion_response_error(message, "media_type", "The response media type does not match the decoded image.")
	}
	install_error := library_install_object(
		&state.root,
		transfer.staging_path,
		digest,
		byte_count,
	)
	if install_error != .None && install_error != .Already_Exists {
		native_ingestion_remove_transfer(state, transfer_index)
		return native_ingestion_response_error(message, "object_install", "The immutable object could not be installed.")
	}
	reinstates := ""
	if purge_event_id, was_purged := library_object_has_valid_purge_commit(
		&state.materialized,
		state.scan.events[:],
		digest,
	); was_purged {
		reinstates = purge_event_id
	}
	record := Library_Capture_Record{
		schema_version = LIBRARY_SCHEMA_VERSION,
		library_id = state.root.genesis.library_id,
		capture_id = transfer.begin.capture_id,
		device_id = state.settings.device_id,
		device_sequence = state.settings.next_sequence,
		captured_at_unix_ms = transfer.begin.captured_at_unix_ms,
		object_digest = digest,
		media_type = image_info.media_type,
		byte_count = byte_count,
		pixel_width = image_info.pixel_width,
		pixel_height = image_info.pixel_height,
		page_url = transfer.begin.page_url,
		page_title = transfer.begin.page_title,
		current_src = transfer.begin.current_src,
		alt_text = transfer.begin.alt_text,
		figure_caption = transfer.begin.figure_caption,
		initial_note = transfer.begin.initial_note,
		reinstates_purge_event_id = reinstates,
		element_rect = transfer.begin.element_rect,
		viewport = transfer.begin.viewport,
	}
	publish_error := library_publish_record(&state.root, &record)
	if publish_error != .None && publish_error != .Already_Exists {
		native_ingestion_orphan_candidate(state, digest)
		native_ingestion_remove_transfer(state, transfer_index)
		return native_ingestion_response_error(message, "record_publish", "The object is durable, but its capture record could not be published.")
	}
	state.settings.next_sequence = max(state.settings.next_sequence, record.device_sequence+1)
	settings_saved := local_settings_save(&state.settings) == .None
	rebuilt := library_service_rebuild(state)
	similar_count := 0
	if rebuilt {
		similar_count = similarity_ingest_staging(
			state,
			transfer.staging_path,
			transfer.begin.capture_id,
			digest,
		)
	}
	native_ingestion_remove_transfer(state, transfer_index)
	if !settings_saved || !rebuilt {
		return native_ingestion_response_error(message, "local_rebuild", "The capture is durable, but the local sequence or index rebuild failed.")
	}
	return {
		wire_version = NATIVE_WIRE_VERSION,
		ok = true,
		type = "capture_stored",
		transfer_id = message.transfer_id,
		capture_id = message.capture_id,
		object_digest = digest,
		media_type = image_info.media_type,
		byte_count = byte_count,
		pixel_width = image_info.pixel_width,
		pixel_height = image_info.pixel_height,
	}
}

native_ingestion_execute :: proc(
	state: ^Library_Service_State,
	message: ^Native_Wire_Message,
) -> Native_Wire_Response {
	switch message.type {
	case NATIVE_MESSAGE_BEGIN:
		return native_ingestion_begin(state, message)
	case NATIVE_MESSAGE_CHUNK:
		return native_ingestion_chunk(state, message)
	case NATIVE_MESSAGE_COMMIT:
		return native_ingestion_commit(state, message)
	case NATIVE_MESSAGE_CANCEL:
		if transfer_index, found := native_ingestion_transfer_index(
			state,
			message.transfer_id,
		); found {
			native_ingestion_remove_transfer(state, transfer_index)
		}
		return {
			wire_version = NATIVE_WIRE_VERSION,
			ok = true,
			type = "capture_cancelled",
			transfer_id = message.transfer_id,
			capture_id = message.capture_id,
		}
	}
	return native_ingestion_response_error(message, "type", "Unknown native-message type.")
}

native_ingestion_execute_json :: proc(
	state: ^Library_Service_State,
	request_bytes: []u8,
	allocator := context.allocator,
) -> ([]u8, bool) {
	message, decode_error := native_wire_message_decode(request_bytes, context.temp_allocator)
	response: Native_Wire_Response
	if decode_error != .None {
		response = {
			wire_version = NATIVE_WIRE_VERSION,
			type = "capture_error",
			error_code = "invalid_message",
			message = fmt.tprintf("The native message is invalid (%s).", decode_error),
		}
	} else {
		response = native_ingestion_execute(state, &message)
	}
	bytes, encode_error := json.marshal(response, {}, allocator)
	return bytes, encode_error == nil
}
