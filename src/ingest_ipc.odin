package main

import "core:c"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "base:runtime"

INGEST_IPC_HEADER_BYTES :: 4
INGEST_IPC_MAX_RESPONSE_BYTES :: 64 * 1024
INGEST_IPC_SOCKET_MODE :: posix.mode_t{.IRUSR, .IWUSR}

Ingest_IPC_Server :: struct {
	thread:           ^thread.Thread,
	listen_fd:        posix.FD,
	active_client_fd: posix.FD,
	running:          bool,
	path:             string,
	state:            ^Library_Service_State,
	mutex:            sync.Mutex,
}

ingest_ipc_socket_path :: proc(
	support_path: string,
	allocator := context.allocator,
) -> (string, bool) {
	if len(support_path) == 0 {return "", false}
	path_hash := hash.fnv64a(transmute([]u8)support_path)
	return fmt.aprintf(
		"/tmp/hw-image-library-%d-%016x-ingest.sock",
		os.get_uid(),
		path_hash,
		allocator=allocator,
	), true
}

ingest_ipc_socket_address :: proc(path: string) -> (posix.sockaddr_un, bool) {
	address: posix.sockaddr_un
	if len(path) == 0 || len(path) >= len(address.sun_path) {return address, false}
	address.sun_len = u8(size_of(address))
	address.sun_family = .UNIX
	for byte, index in path {address.sun_path[index] = c.char(byte)}
	return address, true
}

ingest_ipc_send_all :: proc(fd: posix.FD, bytes: []u8) -> bool {
	sent := 0
	for sent < len(bytes) {
		count := posix.send(
			fd,
			raw_data(bytes[sent:]),
			c.size_t(int(len(bytes))-sent),
			{.NOSIGNAL},
		)
		if count <= 0 {return false}
		sent += int(count)
	}
	return true
}

ingest_ipc_receive_exact :: proc(
	fd: posix.FD,
	bytes: []u8,
	deadline: time.Tick,
) -> bool {
	received := 0
	for received < len(bytes) {
		remaining_ns := i64(time.tick_diff(time.tick_now(), deadline))
		if remaining_ns <= 0 {return false}
		timeout_ms := c.int(
			(remaining_ns+i64(time.Millisecond)-1)/i64(time.Millisecond),
		)
		poll_fd := posix.pollfd{fd=fd, events={.IN}}
		if posix.poll(&poll_fd, 1, timeout_ms) <= 0 {return false}
		count := posix.recv(
			fd,
			raw_data(bytes[received:]),
			c.size_t(int(len(bytes))-received),
			{},
		)
		if count <= 0 {return false}
		received += int(count)
	}
	return true
}

ingest_ipc_receive_request :: proc(
	fd: posix.FD,
	allocator := context.allocator,
) -> ([]u8, bool) {
	deadline := time.tick_add(time.tick_now(), 15*time.Second)
	header: [INGEST_IPC_HEADER_BYTES]u8
	if !ingest_ipc_receive_exact(fd, header[:], deadline) {return nil, false}
	length := int(
		u32(header[0]) << 24 |
		u32(header[1]) << 16 |
		u32(header[2]) << 8 |
		u32(header[3]),
	)
	if length <= 0 || length > NATIVE_WIRE_MAX_FRAME_BYTES {return nil, false}
	request := make([]u8, length, allocator)
	if !ingest_ipc_receive_exact(fd, request, deadline) {return nil, false}
	return request, true
}

ingest_ipc_server_is_running :: proc(server: ^Ingest_IPC_Server) -> bool {
	sync.mutex_lock(&server.mutex)
	running := server.running
	sync.mutex_unlock(&server.mutex)
	return running
}

ingest_ipc_server_worker :: proc(worker: ^thread.Thread) {
	context = runtime.default_context()
	server := cast(^Ingest_IPC_Server)worker.data
	for ingest_ipc_server_is_running(server) {
		sync.mutex_lock(&server.mutex)
		listen_fd := server.listen_fd
		state := server.state
		sync.mutex_unlock(&server.mutex)
		client := posix.accept(listen_fd, nil, nil)
		if client < 0 {
			if !ingest_ipc_server_is_running(server) {break}
			continue
		}
		sync.mutex_lock(&server.mutex)
		server.active_client_fd = client
		running := server.running
		sync.mutex_unlock(&server.mutex)
		if running {
			{
				runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
				request, received := ingest_ipc_receive_request(
					client,
					context.temp_allocator,
				)
				if received {
					sync.mutex_lock(&state.operation_mutex)
					response, encoded := native_ingestion_execute_json(
						state,
						request,
						context.temp_allocator,
					)
					if encoded {_ = ingest_ipc_send_all(client, response)}
					sync.mutex_unlock(&state.operation_mutex)
				}
			}
		}
		_ = posix.close(client)
		sync.mutex_lock(&server.mutex)
		if server.active_client_fd == client {server.active_client_fd = -1}
		sync.mutex_unlock(&server.mutex)
	}
}

ingest_ipc_server_start :: proc(
	server: ^Ingest_IPC_Server,
	path: string,
	state: ^Library_Service_State,
) -> bool {
	address, address_ok := ingest_ipc_socket_address(path)
	if !address_ok || server == nil || state == nil {return false}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return false}
	started := false
	defer if !started {
		_ = posix.close(fd)
		_ = os.remove(path)
	}
	_ = os.remove(path)
	if posix.bind(
		fd,
		cast(^posix.sockaddr)&address,
		posix.socklen_t(size_of(address)),
	) != .OK {
		return false
	}
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	if posix.chmod(c_path, INGEST_IPC_SOCKET_MODE) != .OK {return false}
	if posix.listen(fd, 4) != .OK {return false}
	worker := thread.create(ingest_ipc_server_worker)
	if worker == nil {return false}
	sync.mutex_lock(&server.mutex)
	server.thread = worker
	server.listen_fd = fd
	server.active_client_fd = -1
	server.running = true
	server.path = strings.clone(path)
	server.state = state
	sync.mutex_unlock(&server.mutex)
	worker.data = server
	thread.start(worker)
	started = true
	return true
}

ingest_ipc_server_stop :: proc(server: ^Ingest_IPC_Server) {
	if server == nil {return}
	sync.mutex_lock(&server.mutex)
	if !server.running {
		sync.mutex_unlock(&server.mutex)
		return
	}
	server.running = false
	listen_fd := server.listen_fd
	active_client_fd := server.active_client_fd
	worker := server.thread
	path := server.path
	if active_client_fd >= 0 {_ = posix.shutdown(active_client_fd, .RDWR)}
	sync.mutex_unlock(&server.mutex)
	_ = posix.shutdown(listen_fd, .RDWR)
	_ = posix.close(listen_fd)
	if worker != nil {
		thread.join(worker)
		thread.destroy(worker)
	}
	_ = os.remove(path)
	delete(path)
	server^ = {}
}

ingest_ipc_client_exchange :: proc(
	path: string,
	request: []u8,
	allocator := context.allocator,
) -> ([]u8, bool) {
	if len(request) == 0 || len(request) > NATIVE_WIRE_MAX_FRAME_BYTES {
		return nil, false
	}
	address, address_ok := ingest_ipc_socket_address(path)
	if !address_ok {return nil, false}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return nil, false}
	defer posix.close(fd)
	if posix.connect(
		fd,
		cast(^posix.sockaddr)&address,
		posix.socklen_t(size_of(address)),
	) != .OK {
		return nil, false
	}
	length := u32(len(request))
	header := [INGEST_IPC_HEADER_BYTES]u8{
		u8(length >> 24),
		u8(length >> 16),
		u8(length >> 8),
		u8(length),
	}
	if !ingest_ipc_send_all(fd, header[:]) || !ingest_ipc_send_all(fd, request) {
		return nil, false
	}
	_ = posix.shutdown(fd, .WR)
	response := make([dynamic]u8, allocator)
	buffer: [4096]u8
	for {
		count := posix.recv(fd, raw_data(buffer[:]), c.size_t(len(buffer)), {})
		if count < 0 {return nil, false}
		if count == 0 {break}
		if len(response)+int(count) > INGEST_IPC_MAX_RESPONSE_BYTES {return nil, false}
		append(&response, ..buffer[:int(count)])
	}
	return response[:], len(response) > 0
}
