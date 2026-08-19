package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import "base:runtime"

Library_ICloud_Lookup :: struct {
	path: string,
	error: MacOS_Path_Error,
}

library_icloud_lookup_worker :: proc(worker: ^thread.Thread) {
	context = runtime.default_context()
	result := cast(^Library_ICloud_Lookup)worker.data
	result.path, result.error = macos_default_icloud_library_root(context.allocator)
}

library_icloud_root_off_main :: proc() -> (string, MacOS_Path_Error) {
	result: Library_ICloud_Lookup
	worker := thread.create(library_icloud_lookup_worker)
	if worker == nil {return "", .Unavailable}
	worker.data = &result
	thread.start(worker)
	thread.join(worker)
	thread.destroy(worker)
	return result.path, result.error
}

library_cli_emit :: proc(response: Library_Service_Response) -> int {
	bytes, encode_error := json.marshal(
		response,
		{pretty=true, use_spaces=true, spaces=2},
		context.temp_allocator,
	)
	if encode_error != nil {
		fmt.eprintln(`{"protocol_version":1,"ok":false,"error_code":"encode"}`)
		return 1
	}
	fmt.println(string(bytes))
	return response.ok ? 0 : 1
}

library_cli_error :: proc(code, message: string) -> int {
	return library_cli_emit(library_service_error_response(code, message))
}

library_cli_configure_root :: proc(
	root_path, mode, bookmark_base64: string,
) -> Library_Service_Response {
	if len(root_path) == 0 || !filepath.is_abs(root_path) {
		return library_service_error_response("invalid_path", "The library root must be an absolute path.")
	}
	if _, settings_error := local_settings_load(context.temp_allocator);
	   settings_error != .Not_Found {
		return library_service_error_response(
			"already_configured",
			"This Mac already has a configured library root.",
		)
	}
	genesis_path, genesis_path_ok := library_join(
		[]string{root_path, "library.json"},
		context.temp_allocator,
	)
	if !genesis_path_ok {
		return library_service_error_response("invalid_path", "The library genesis path is invalid.")
	}
	root: Library_Root
	root_error: Library_File_Error
	settings: Local_Settings
	root_ready := false
	defer if root_ready {library_root_destroy(&root)}
	if os.exists(genesis_path) {
		root, root_error = library_root_open(root_path, context.allocator)
		if root_error != .None {
			return library_service_error_response("library_open", "The existing library root is invalid.")
		}
		root_ready = true
		device_id, device_id_ok := library_uuid_new(context.temp_allocator)
		if !device_id_ok {
			return library_service_error_response("identifier", "A device identifier could not be created.")
		}
		join_request := Library_Join_Request{
			schema_version = LIBRARY_SCHEMA_VERSION,
			library_id = root.genesis.library_id,
			device_id = device_id,
			requested_at_unix_ms = library_now_unix_ms(),
			device_name = macos_device_name(context.temp_allocator),
		}
		publish_error := library_publish_join_request(&root, &join_request)
		if publish_error != .None && publish_error != .Already_Exists {
			return library_service_error_response("join_request", "The device join request could not be published.")
		}
		settings = {
			schema_version = LOCAL_SETTINGS_SCHEMA_VERSION,
			library_id = root.genesis.library_id,
			library_path = root.path,
			library_mode = mode,
			bookmark_base64 = bookmark_base64,
			device_id = device_id,
			membership_status = LOCAL_MEMBERSHIP_PENDING,
			next_sequence = 1,
			interface_theme = "hw-light",
		}
	} else {
		root, root_error = library_root_initialize(root_path, allocator=context.allocator)
		if root_error != .None {
			return library_service_error_response("library_initialize", "The library root could not be initialized.")
		}
		root_ready = true
		settings = local_settings_initial(&root, mode, bookmark_base64)
	}
	if local_settings_save(&settings) != .None {
		return library_service_error_response("settings", "The machine-local library settings could not be saved.")
	}
	return {
		protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
		ok = true,
		message = settings.membership_status,
	}
}

library_cli_rebind_root :: proc(
	root_path, bookmark_base64: string,
) -> Library_Service_Response {
	settings, settings_error := local_settings_load()
	if settings_error != .None {
		return library_service_error_response("settings", "The existing machine-local settings could not be loaded.")
	}
	defer local_settings_destroy(&settings)
	root, root_error := library_root_open(root_path, context.temp_allocator)
	if root_error != .None {
		return library_service_error_response("library_open", "The selected library root is invalid.")
	}
	if root.genesis.library_id != settings.library_id {
		return library_service_error_response("library_mismatch", "The selected folder belongs to a different image library.")
	}
	delete(settings.library_path, settings.allocator)
	delete(settings.library_mode, settings.allocator)
	delete(settings.bookmark_base64, settings.allocator)
	settings.library_path = strings.clone(root_path, settings.allocator)
	settings.library_mode = strings.clone(LOCAL_SETTINGS_MODE_BOOKMARK, settings.allocator)
	settings.bookmark_base64 = strings.clone(bookmark_base64, settings.allocator)
	if local_settings_save(&settings) != .None {
		return library_service_error_response("settings", "The replacement library bookmark could not be saved.")
	}
	return {
		protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
		ok = true,
		message = "library_reconnected",
	}
}

library_cli_initialize :: proc(args: []string) -> (int, bool) {
	if len(args) < 2 || args[0] != "library" {return 0, false}
	switch args[1] {
	case "init-local":
		if len(args) != 3 {
			return library_cli_error("usage", "Usage: library init-local <absolute-root>"), true
		}
		if !filepath.is_abs(args[2]) {
			return library_cli_error("invalid_path", "The local root path must be absolute."), true
		}
		return library_cli_emit(library_cli_configure_root(
			args[2],
			LOCAL_SETTINGS_MODE_TEST,
			"",
		)), true
	case "init-icloud":
		if len(args) != 2 {
			return library_cli_error("usage", "Usage: library init-icloud"), true
		}
		root_path, path_error := library_icloud_root_off_main()
		if path_error != .None {
			return library_cli_error("icloud_unavailable", "The signed iCloud Documents container is unavailable."), true
		}
		defer delete(root_path)
		return library_cli_emit(library_cli_configure_root(
			root_path,
			LOCAL_SETTINGS_MODE_ICLOUD,
			"",
		)), true
	case "choose-folder":
		if len(args) != 2 {
			return library_cli_error("usage", "Usage: library choose-folder"), true
		}
		root_path, bookmark, choose_error := macos_choose_library_root(context.temp_allocator)
		if choose_error != .None {
			return library_cli_error("folder_selection", "The library folder was not selected."), true
		}
		return library_cli_emit(library_cli_configure_root(
			root_path,
			LOCAL_SETTINGS_MODE_BOOKMARK,
			bookmark,
		)), true
	case "rebind-folder":
		if len(args) != 2 {
			return library_cli_error("usage", "Usage: library rebind-folder"), true
		}
		root_path, bookmark, choose_error := macos_choose_library_root(context.temp_allocator)
		if choose_error != .None {
			return library_cli_error("folder_selection", "The library folder was not selected."), true
		}
		return library_cli_emit(library_cli_rebind_root(root_path, bookmark)), true
	}
	return 0, false
}

library_cli_start_service :: proc(socket_path: string) -> bool {
	// The background service now starts without a configured library in
	// folder-only mode, so spawning is always meaningful. A service that fails
	// to boot (for example a locked database) costs the caller one poll.
	executable, executable_error := os.get_absolute_path(os.args[0], context.temp_allocator)
	if executable_error != nil {return false}
	command := []string{executable, "--service"}
	_, start_error := os.process_start({command=command})
	if start_error != nil {return false}
	for _ in 0..<200 {
		response, exchanged := library_service_client_exchange(
			socket_path,
			{protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, command="health"},
			context.temp_allocator,
		)
		if exchanged && response.ok {return true}
		time.sleep(10*time.Millisecond)
	}
	return false
}

library_cli_exchange :: proc(
	request: Library_Service_Request,
	allocator := context.allocator,
) -> (Library_Service_Response, bool) {
	support_path, support_error := macos_application_support_directory(context.temp_allocator)
	if support_error != .None {return {}, false}
	socket_path, socket_path_ok := library_service_socket_path(
		support_path,
		context.temp_allocator,
	)
	if !socket_path_ok {return {}, false}
	response, exchanged := library_service_client_exchange(socket_path, request, allocator)
	if exchanged {return response, true}
	if !library_cli_start_service(socket_path) {return {}, false}
	return library_service_client_exchange(socket_path, request, allocator)
}

library_cli_parse_request :: proc(
	args: []string,
) -> (Library_Service_Request, bool) {
	request := Library_Service_Request{protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION}
	if len(args) < 2 {return {}, false}
	if args[0] == "capture" {
		switch args[1] {
		case "list":
			if len(args) != 2 {return {}, false}
			request.command = "capture.list"
		case "show":
			if len(args) != 3 {return {}, false}
			request.command, request.capture_id = "capture.show", args[2]
		case "search":
			if len(args) < 3 {return {}, false}
			request.command = "capture.search"
			request.text = strings.join(args[2:], " ", context.temp_allocator)
		case "export":
			if len(args) != 4 {return {}, false}
			request.command, request.capture_id = "capture.export", args[2]
			request.path = args[3]
		case "delete":
			if len(args) != 3 {return {}, false}
			request.command, request.capture_id = "capture.delete", args[2]
		case "restore":
			if len(args) != 3 {return {}, false}
			request.command, request.capture_id = "capture.restore", args[2]
		case "note-set":
			if len(args) < 4 {return {}, false}
			request.command, request.capture_id = "capture.note-set", args[2]
			request.text = strings.join(args[3:], " ", context.temp_allocator)
		case "open-source":
			if len(args) != 3 {return {}, false}
			request.command, request.capture_id = "capture.open-source", args[2]
		case "thumbnail":
			if len(args) != 4 {return {}, false}
			size, parsed := strconv.parse_int(args[3])
			if !parsed {return {}, false}
			request.command, request.capture_id = "capture.thumbnail", args[2]
			request.maximum_pixels = size
		case:
			return {}, false
		}
		return request, true
	}
	if args[0] == "folder" {
		switch args[1] {
		case "add":
			if len(args) < 3 {return {}, false}
			request.command = "folder.add"
			request.path = args[2]
			request.recursive = true
			if len(args) >= 4 && args[3] == "--flat" {request.recursive = false}
		case "add-choose":
			if len(args) != 2 {return {}, false}
			path, bookmark, choose_error := macos_choose_library_root(context.temp_allocator)
			if choose_error != .None {return {}, false}
			request.command = "folder.add"
			request.path = path
			request.bookmark = bookmark
			request.recursive = true
		case "list":
			if len(args) != 2 {return {}, false}
			request.command = "folder.list"
		case "scan":
			if len(args) != 3 {return {}, false}
			root_id, parsed := strconv.parse_i64(args[2])
			if !parsed {return {}, false}
			request.command, request.root_id = "folder.scan", root_id
		case "tag":
			if len(args) != 3 {return {}, false}
			root_id, parsed := strconv.parse_i64(args[2])
			if !parsed {return {}, false}
			request.command, request.root_id = "folder.tag", root_id
		case "embed":
			if len(args) != 3 {return {}, false}
			root_id, parsed := strconv.parse_i64(args[2])
			if !parsed {return {}, false}
			request.command, request.root_id = "folder.embed", root_id
		case "similar":
			if len(args) != 3 {return {}, false}
			image_id, parsed := strconv.parse_i64(args[2])
			if !parsed {return {}, false}
			request.command, request.image_id = "folder.similar", image_id
		case "duplicates":
			if len(args) != 3 {return {}, false}
			root_id, parsed := strconv.parse_i64(args[2])
			if !parsed {return {}, false}
			request.command, request.root_id = "folder.duplicates", root_id
		case "remove":
			if len(args) != 3 {return {}, false}
			root_id, parsed := strconv.parse_i64(args[2])
			if !parsed {return {}, false}
			request.command, request.root_id = "folder.remove", root_id
		case "images":
			if len(args) != 3 {return {}, false}
			root_id, parsed := strconv.parse_i64(args[2])
			if !parsed {return {}, false}
			request.command, request.root_id = "folder.images", root_id
		case "search":
			if len(args) < 3 {return {}, false}
			request.command = "folder.search"
			request.text = strings.join(args[2:], " ", context.temp_allocator)
		case:
			return {}, false
		}
		return request, true
	}
	if args[0] == "library" {
		switch args[1] {
		case "devices":
			if len(args) != 2 {return {}, false}
			request.command = "library.devices"
		case "ack":
			if len(args) != 2 {return {}, false}
			request.command = "library.ack"
		case "device-authorize":
			if len(args) != 3 {return {}, false}
			request.command, request.device_id = "library.device-authorize", args[2]
		case "device-retire":
			if len(args) != 4 {return {}, false}
			request.command, request.device_id = "library.device-retire", args[2]
			request.confirmation = args[3]
		case "purge-status":
			if len(args) != 2 {return {}, false}
			request.command = "library.purge-status"
		case "purge":
			if len(args) != 4 {return {}, false}
			request.command = "library.purge"
			request.object_digest, request.confirmation = args[2], args[3]
		case "move":
			if len(args) != 4 {return {}, false}
			request.command = "library.move"
			request.path, request.confirmation = args[2], args[3]
		case "rebuild":
			if len(args) != 2 {return {}, false}
			request.command = "library.rebuild"
		case "service-stop":
			if len(args) != 2 {return {}, false}
			request.command = "service.stop"
		case:
			return {}, false
		}
		return request, true
	}
	return {}, false
}

library_cli_run :: proc(args: []string) -> int {
	if initialization_result, handled := library_cli_initialize(args); handled {
		return initialization_result
	}
	request, parsed := library_cli_parse_request(args)
	if !parsed {
		return library_cli_error(
			"usage",
			"Usage: capture <list|show|search|open-source|export|delete|restore|note-set|thumbnail> ... or folder <add|add-choose|list|scan|tag|embed|similar|duplicates|remove|images|search> ... or library <devices|ack|device-authorize|device-retire|purge-status|purge|move|rebuild> ...",
		)
	}
	if request.command == "capture.open-source" {
		request.command = "capture.show"
		response, exchanged := library_cli_exchange(request, context.temp_allocator)
		if !exchanged {
			return library_cli_error("service_unavailable", "The background library service did not start.")
		}
		if !response.ok {return library_cli_emit(response)}
		if !response.has_capture || !macos_open_url(response.capture.page_url) {
			return library_cli_error("open_source", "The recorded source URL could not be opened.")
		}
		response.message = response.capture.page_url
		return library_cli_emit(response)
	}
	response, exchanged := library_cli_exchange(request, context.temp_allocator)
	if !exchanged {
		return library_cli_error("service_unavailable", "The background library service did not start.")
	}
	// The folder scan is incremental; drive it to completion so the CLI
	// returns once the folder is fully indexed. The initial response was
	// temp-allocated, so free its fields as temp before looping with the
	// default allocator and destroying each intermediate response normally.
	if request.command == "folder.scan" && response.ok && response.message == "scanning" {
		library_service_response_destroy(&response, context.temp_allocator)
		for _ in 0..<20000 {
			loop_response, loop_exchanged := library_cli_exchange(request)
			if !loop_exchanged {break}
			finished := loop_response.ok && loop_response.message == "complete"
			failed := !loop_response.ok
			if finished || failed {
				response = loop_response
				break
			}
			library_service_response_destroy(&loop_response)
		}
	}
	// Recognition is likewise batched; loop until the root is fully tagged.
	if request.command == "folder.tag" && response.ok && response.message == "tagging" {
		library_service_response_destroy(&response, context.temp_allocator)
		for _ in 0..<20000 {
			loop_response, loop_exchanged := library_cli_exchange(request)
			if !loop_exchanged {break}
			finished := loop_response.ok && loop_response.message == "complete"
			failed := !loop_response.ok
			if finished || failed {
				response = loop_response
				break
			}
			library_service_response_destroy(&loop_response)
		}
	}
	if request.command == "folder.embed" && response.ok && response.message == "embedding" {
		library_service_response_destroy(&response, context.temp_allocator)
		for _ in 0..<20000 {
			loop_response, loop_exchanged := library_cli_exchange(request)
			if !loop_exchanged {break}
			finished := loop_response.ok && loop_response.message == "complete"
			failed := !loop_response.ok
			if finished || failed {
				response = loop_response
				break
			}
			library_service_response_destroy(&loop_response)
		}
	}
	return library_cli_emit(response)
}

library_service_run :: proc() -> int {
	state: Library_Service_State
	initialize_error := library_service_initialize_configured(&state)
	if initialize_error != .None {
		return library_cli_error("service_initialize", fmt.tprintf(
			"The background service could not initialize (%s).",
			initialize_error,
		))
	}
	defer library_service_destroy(&state)
	if start_error := library_service_start(&state); start_error != .None {
		return library_cli_error("service_start", fmt.tprintf(
			"The background service could not start (%s).",
			start_error,
		))
	}
	for library_service_is_running(&state) {
		library_service_poll(&state)
		time.sleep(100*time.Millisecond)
	}
	return 0
}
