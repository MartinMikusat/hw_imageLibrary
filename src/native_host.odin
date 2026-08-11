package main

import "core:encoding/json"
import "core:os"

Native_Host_Read_Status :: enum {
	Success,
	End,
	Error,
}

native_host_read_exact :: proc(file: ^os.File, bytes: []u8) -> Native_Host_Read_Status {
	read_count := 0
	for read_count < len(bytes) {
		count, read_error := os.read(file, bytes[read_count:])
		if count > 0 {read_count += count}
		if read_error == .EOF {
			return read_count == 0 ? .End : .Error
		}
		if read_error != nil || count <= 0 {return .Error}
	}
	return .Success
}

native_host_write_all :: proc(file: ^os.File, bytes: []u8) -> bool {
	written := 0
	for written < len(bytes) {
		count, write_error := os.write(file, bytes[written:])
		if write_error != nil || count <= 0 {return false}
		written += count
	}
	return true
}

native_host_write_frame :: proc(bytes: []u8) -> bool {
	if len(bytes) == 0 || len(bytes) > INGEST_IPC_MAX_RESPONSE_BYTES {return false}
	length := u32(len(bytes))
	header := [4]u8{
		u8(length),
		u8(length >> 8),
		u8(length >> 16),
		u8(length >> 24),
	}
	return native_host_write_all(os.stdout, header[:]) &&
	       native_host_write_all(os.stdout, bytes)
}

native_host_error_bytes :: proc(
	code, message: string,
	allocator := context.allocator,
) -> []u8 {
	response := Native_Wire_Response{
		wire_version = NATIVE_WIRE_VERSION,
		type = "capture_error",
		error_code = code,
		message = message,
	}
	bytes, encode_error := json.marshal(response, {}, allocator)
	if encode_error != nil {return nil}
	return bytes
}

native_host_ingest_socket :: proc(
	allocator := context.allocator,
) -> (string, bool) {
	support_path, support_error := macos_application_support_directory(context.temp_allocator)
	if support_error != .None {return "", false}
	control_socket, control_ok := library_service_socket_path(
		support_path,
		context.temp_allocator,
	)
	if !control_ok {return "", false}
	health, healthy := library_service_client_exchange(
		control_socket,
		{protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, command="health"},
		context.temp_allocator,
	)
	if !healthy || !health.ok {
		if !library_cli_start_service(control_socket) {return "", false}
	}
	return ingest_ipc_socket_path(support_path, allocator)
}

native_host_run :: proc() -> int {
	ingest_socket, socket_ok := native_host_ingest_socket(context.allocator)
	if !socket_ok {
		error_bytes := native_host_error_bytes(
			"service_unavailable",
			"The background library service did not start.",
			context.temp_allocator,
		)
		if len(error_bytes) > 0 {_ = native_host_write_frame(error_bytes)}
		return 1
	}
	defer delete(ingest_socket)
	for {
		header: [4]u8
		header_status := native_host_read_exact(os.stdin, header[:])
		if header_status == .End {return 0}
		if header_status != .Success {return 1}
		length := int(
			u32(header[0]) |
			u32(header[1]) << 8 |
			u32(header[2]) << 16 |
			u32(header[3]) << 24,
		)
		if length <= 0 || length > NATIVE_WIRE_MAX_FRAME_BYTES {
			error_bytes := native_host_error_bytes(
				"frame_bounds",
				"The native-message frame exceeds the ingestion bound.",
				context.temp_allocator,
			)
			_ = native_host_write_frame(error_bytes)
			return 1
		}
		request := make([]u8, length, context.temp_allocator)
		if native_host_read_exact(os.stdin, request) != .Success {return 1}
		response, exchanged := ingest_ipc_client_exchange(
			ingest_socket,
			request,
			context.temp_allocator,
		)
		if !exchanged {
			response = native_host_error_bytes(
				"service_unavailable",
				"The background ingestion socket is unavailable.",
				context.temp_allocator,
			)
		}
		if !native_host_write_frame(response) {return 1}
	}
}
