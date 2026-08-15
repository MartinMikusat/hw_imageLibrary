package main

import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import mem_virtual "core:mem/virtual"
import local_command "local_command:."

LIBRARY_SERVICE_PROTOCOL_VERSION :: 1

Library_Service_Request :: struct {
	protocol_version: int    `json:"protocol_version"`,
	command:          string `json:"command"`,
	capture_id:       string `json:"capture_id,omitempty"`,
	text:             string `json:"text,omitempty"`,
	path:             string `json:"path,omitempty"`,
	device_id:        string `json:"device_id,omitempty"`,
	confirmation:     string `json:"confirmation,omitempty"`,
	object_digest:    string `json:"object_digest,omitempty"`,
	maximum_pixels:   int    `json:"maximum_pixels,omitempty"`,
	include_deleted:  bool   `json:"include_deleted,omitempty"`,
}

Library_Service_Device :: struct {
	device_id:       string `json:"device_id"`,
	device_name:     string `json:"device_name,omitempty"`,
	sequence_prefix: u64    `json:"sequence_prefix"`,
	accepted_cutoff: u64    `json:"accepted_cutoff"`,
	authorized:      bool   `json:"authorized"`,
	retired:         bool   `json:"retired"`,
	pending_request: bool   `json:"pending_request"`,
}

Library_Service_Purge :: struct {
	object_digest:         string   `json:"object_digest"`,
	block:                 string   `json:"block"`,
	not_before_unix_ms:    i64      `json:"not_before_unix_ms,omitempty"`,
	required_event_ids:    []string `json:"required_event_ids,omitempty"`,
	blocking_device_ids:   []string `json:"blocking_device_ids,omitempty"`,
	proposal_event_id:     string   `json:"proposal_event_id,omitempty"`,
	commit_event_id:       string   `json:"commit_event_id,omitempty"`,
}

Library_Service_Response :: struct {
	protocol_version: int                             `json:"protocol_version"`,
	ok:               bool                            `json:"ok"`,
	error_code:       string                          `json:"error_code,omitempty"`,
	message:          string                          `json:"message,omitempty"`,
	captures:         [dynamic]Library_Index_Capture `json:"captures,omitempty"`,
	capture:          Library_Index_Capture           `json:"capture,omitempty"`,
	has_capture:      bool                            `json:"has_capture,omitempty"`,
	devices:          [dynamic]Library_Service_Device `json:"devices,omitempty"`,
	issue_count:      int                             `json:"issue_count,omitempty"`,
	purges:           [dynamic]Library_Service_Purge  `json:"purges,omitempty"`,
}

library_index_capture_destroy :: proc(
	value: ^Library_Index_Capture,
	allocator := context.allocator,
) {
	if value == nil {return}
	delete(value.capture_id, allocator)
	delete(value.object_digest, allocator)
	delete(value.media_type, allocator)
	delete(value.page_url, allocator)
	delete(value.page_title, allocator)
	delete(value.current_src, allocator)
	delete(value.alt_text, allocator)
	delete(value.figure_caption, allocator)
	delete(value.note, allocator)
	value^ = {}
}

library_service_response_destroy :: proc(
	value: ^Library_Service_Response,
	allocator := context.allocator,
) {
	if value == nil {return}
	delete(value.error_code, allocator)
	delete(value.message, allocator)
	for &capture in value.captures {library_index_capture_destroy(&capture, allocator)}
	delete(value.captures)
	library_index_capture_destroy(&value.capture, allocator)
	for &device in value.devices {
		delete(device.device_id, allocator)
		delete(device.device_name, allocator)
	}
	delete(value.devices)
	for &purge in value.purges {
		delete(purge.object_digest, allocator)
		delete(purge.block, allocator)
		for &event_id in purge.required_event_ids {delete(event_id, allocator)}
		delete(purge.required_event_ids, allocator)
		for &device_id in purge.blocking_device_ids {delete(device_id, allocator)}
		delete(purge.blocking_device_ids, allocator)
		delete(purge.proposal_event_id, allocator)
		delete(purge.commit_event_id, allocator)
	}
	delete(value.purges)
	value^ = {}
}

Library_Service_State :: struct {
	support_path: string,
	root:         Library_Root,
	settings:     Local_Settings,
	settings_loaded: bool,
	bookmark_resolution: MacOS_Bookmark_Resolution,
	database:     ^SQLite_DB,
	index_available: bool,
	arena:        mem_virtual.Arena,
	arena_ready:  bool,
	scan:         Library_Scan,
	materialized: Library_Materialized,
	owner_lock:   local_command.Owner_Lock,
	server:       local_command.Server,
	ingest_server: Ingest_IPC_Server,
	socket_path:  string,
	ingest_socket_path: string,
	running:      bool,
	running_mutex: sync.Mutex,
	operation_mutex: sync.Mutex,
	rescan_mutex: sync.Mutex,
	rescan_requested: bool,
	last_periodic_scan: time.Tick,
	periodic_scan_started: bool,
	file_presenter: MacOS_File_Presenter,
	transfers:     [dynamic]Native_Transfer,
}

Library_Service_Error :: enum {
	None,
	Path,
	Already_Running,
	Root,
	Database,
	Index,
	Socket,
	Presenter,
	Settings,
	Bookmark,
}

library_service_request_rescan :: proc(state: ^Library_Service_State) {
	if state == nil {return}
	sync.mutex_lock(&state.rescan_mutex)
	state.rescan_requested = true
	sync.mutex_unlock(&state.rescan_mutex)
}

library_service_take_rescan :: proc(state: ^Library_Service_State) -> bool {
	sync.mutex_lock(&state.rescan_mutex)
	requested := state.rescan_requested
	state.rescan_requested = false
	sync.mutex_unlock(&state.rescan_mutex)
	return requested
}

library_service_poll :: proc(state: ^Library_Service_State) {
	if !state.periodic_scan_started ||
	   time.tick_since(state.last_periodic_scan) >= 5*time.Second {
		state.last_periodic_scan = time.tick_now()
		state.periodic_scan_started = true
		library_service_request_rescan(state)
	}
	if library_service_take_rescan(state) {
		sync.mutex_lock(&state.operation_mutex)
		rebuilt := library_service_rebuild(state)
		if rebuilt {library_service_maintenance(state)}
		sync.mutex_unlock(&state.operation_mutex)
	}
}

library_service_socket_path :: proc(
	support_path: string,
	allocator := context.allocator,
) -> (string, bool) {
	if len(support_path) == 0 {return "", false}
	path_hash := hash.fnv64a(transmute([]u8)support_path)
	return fmt.aprintf(
		"/tmp/hw-image-library-%d-%016x.sock",
		os.get_uid(),
		path_hash,
		allocator=allocator,
	), true
}

library_service_lock_path :: proc(
	support_path: string,
	allocator := context.allocator,
) -> (string, bool) {
	return library_join([]string{support_path, "service-v1.lock"}, allocator)
}

library_service_database_path :: proc(
	support_path: string,
	allocator := context.allocator,
) -> (string, bool) {
	return library_join([]string{support_path, "index-v1.sqlite3"}, allocator)
}

library_service_set_running :: proc(state: ^Library_Service_State, running: bool) {
	sync.mutex_lock(&state.running_mutex)
	state.running = running
	sync.mutex_unlock(&state.running_mutex)
}

library_service_is_running :: proc(state: ^Library_Service_State) -> bool {
	sync.mutex_lock(&state.running_mutex)
	running := state.running
	sync.mutex_unlock(&state.running_mutex)
	return running
}

library_service_rebuild :: proc(state: ^Library_Service_State) -> bool {
	state.index_available = false
	new_arena: mem_virtual.Arena
	if mem_virtual.arena_init_growing(&new_arena, 8*1024*1024) != nil {return false}
	new_allocator := mem_virtual.arena_allocator(&new_arena)
	new_scan := library_root_scan(&state.root, new_allocator)
	new_materialized := library_materialize(
		&state.root.genesis,
		new_scan.records[:],
		new_scan.events[:],
		new_allocator,
	)
	if !library_index_rebuild(state.database, &new_scan, &new_materialized) {
		mem_virtual.arena_destroy(&new_arena)
		return false
	}
	if state.arena_ready {mem_virtual.arena_destroy(&state.arena)}
	state.arena = new_arena
	state.arena_ready = true
	state.scan = new_scan
	state.materialized = new_materialized
	if state.settings_loaded {
		membership := LOCAL_MEMBERSHIP_PENDING
		if device_index, found := library_device_index(
			state.materialized.devices[:],
			state.settings.device_id,
		); found {
			device := &state.materialized.devices[device_index]
			if device.retired {
				membership = LOCAL_MEMBERSHIP_RETIRED
			} else if device.authorized {
				membership = (state.settings.device_id == state.root.genesis.initial_device_id) ? LOCAL_MEMBERSHIP_INITIAL : LOCAL_MEMBERSHIP_ACTIVE
			}
		}
		if state.settings.membership_status != membership {
			delete(state.settings.membership_status, state.settings.allocator)
			state.settings.membership_status = strings.clone(membership, state.settings.allocator)
			if local_settings_save(&state.settings) != .None {return false}
		}
	}
	state.index_available = true
	return true
}

library_service_initialize :: proc(
	state: ^Library_Service_State,
	root_path, support_path: string,
) -> Library_Service_Error {
	if state == nil || len(root_path) == 0 || len(support_path) == 0 {return .Path}
	if !library_ensure_directory(support_path) {return .Path}
	lock_path, lock_ok := library_service_lock_path(support_path, context.temp_allocator)
	if !lock_ok {return .Path}
	if !local_command.owner_lock_try_acquire(&state.owner_lock, lock_path) {
		return .Already_Running
	}
	initialized := false
	defer if !initialized {library_service_destroy(state)}
	root, root_error := library_root_open(root_path, context.allocator)
	if root_error != .None {return .Root}
	state.root = root
	state.support_path = strings.clone(support_path)
	database_path, database_ok := library_service_database_path(support_path, context.temp_allocator)
	if !database_ok {return .Path}
	database, database_opened := sqlite_open(database_path)
	if !database_opened {return .Database}
	state.database = database
	if !library_service_rebuild(state) {return .Index}
	socket_path, socket_ok := library_service_socket_path(support_path, context.allocator)
	if !socket_ok {return .Path}
	state.socket_path = socket_path
	ingest_socket_path, ingest_socket_ok := ingest_ipc_socket_path(
		support_path,
		context.allocator,
	)
	if !ingest_socket_ok {return .Path}
	state.ingest_socket_path = ingest_socket_path
	library_service_set_running(state, true)
	initialized = true
	return .None
}

library_service_initialize_configured :: proc(
	state: ^Library_Service_State,
) -> Library_Service_Error {
	settings, settings_error := local_settings_load(context.allocator)
	if settings_error != .None {return .Settings}
	settings_owned := true
	defer if settings_owned {local_settings_destroy(&settings)}
	support_path, support_error := macos_application_support_directory(context.temp_allocator)
	if support_error != .None {return .Path}
	root_path := settings.library_path
	if settings.library_mode == LOCAL_SETTINGS_MODE_BOOKMARK {
		resolution, bookmark_error := macos_bookmark_resolve(
			settings.bookmark_base64,
			context.allocator,
		)
		if bookmark_error != .None && bookmark_error != .Stale {return .Bookmark}
		if bookmark_error == .Stale {
			macos_bookmark_resolution_close(&resolution)
			return .Bookmark
		}
		state.bookmark_resolution = resolution
		root_path = resolution.path
	}
	initialize_error := library_service_initialize(state, root_path, support_path)
	if initialize_error != .None {return initialize_error}
	if state.root.genesis.library_id != settings.library_id {
		library_service_destroy(state)
		return .Settings
	}
	local_settings_reconcile_sequence(&settings, state.scan.records[:], state.scan.events[:])
	state.settings = settings
	state.settings_loaded = true
	settings_owned = false
	if !library_service_rebuild(state) {
		library_service_destroy(state)
		return .Index
	}
	return .None
}

library_service_destroy :: proc(state: ^Library_Service_State) {
	if state == nil {return}
	library_service_set_running(state, false)
	ingest_ipc_server_stop(&state.ingest_server)
	local_command.server_stop(&state.server)
	macos_file_presenter_stop(&state.file_presenter)
	if state.database != nil {
		_ = sqlite3_close(state.database)
		state.database = nil
	}
	if state.arena_ready {
		mem_virtual.arena_destroy(&state.arena)
		state.arena_ready = false
	}
	if state.settings_loaded {
		local_settings_destroy(&state.settings)
		state.settings_loaded = false
	}
	macos_bookmark_resolution_close(&state.bookmark_resolution)
	native_ingestion_destroy(state)
	library_root_destroy(&state.root)
	local_command.owner_lock_release(&state.owner_lock)
	delete(state.support_path)
	delete(state.socket_path)
	delete(state.ingest_socket_path)
	state.support_path = ""
	state.socket_path = ""
	state.ingest_socket_path = ""
}

library_service_error_response :: proc(code, message: string) -> Library_Service_Response {
	return {
		protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
		error_code = code,
		message = message,
	}
}

library_service_devices :: proc(
	state: ^Library_Service_State,
	allocator := context.allocator,
) -> [dynamic]Library_Service_Device {
	result := make([dynamic]Library_Service_Device, allocator)
	for device in state.materialized.devices {
		name := ""
		pending := false
		for request in state.scan.join_requests {
			if request.device_id == device.device_id {
				name = request.device_name
				pending = !device.authorized
				break
			}
		}
		append(&result, Library_Service_Device{
			device_id = device.device_id,
			device_name = name,
			sequence_prefix = device.sequence_prefix,
			accepted_cutoff = device.accepted_cutoff,
			authorized = device.authorized,
			retired = device.retired,
			pending_request = pending,
		})
	}
	for request in state.scan.join_requests {
		if _, found := library_device_index(state.materialized.devices[:], request.device_id); found {
			continue
		}
		append(&result, Library_Service_Device{
			device_id = request.device_id,
			device_name = request.device_name,
			pending_request = true,
		})
	}
	return result
}

library_service_capture_state :: proc(
	state: ^Library_Service_State,
	capture_id: string,
) -> (^Library_Capture_State, bool) {
	for &capture in state.materialized.captures {
		if capture.capture_id == capture_id {return &capture, true}
	}
	return nil, false
}

library_service_frontier :: proc(
	state: ^Library_Service_State,
	include_next_local_sequence := false,
	allocator := context.allocator,
) -> [dynamic]Library_Frontier_Entry {
	frontier := make([dynamic]Library_Frontier_Entry, allocator)
	for device in state.materialized.devices {
		if !device.authorized || device.retired {continue}
		sequence := device.sequence_prefix
		if include_next_local_sequence && device.device_id == state.settings.device_id {
			sequence = max(sequence, state.settings.next_sequence)
		}
		append(&frontier, Library_Frontier_Entry{
			device_id = device.device_id,
			sequence = sequence,
		})
	}
	slice.sort_by(frontier[:], proc(a, b: Library_Frontier_Entry) -> bool {
		return a.device_id < b.device_id
	})
	return frontier
}

library_service_write_barrier :: proc(state: ^Library_Service_State) -> (string, bool) {
	if !state.settings_loaded {return "", false}
	for event_index in state.materialized.accepted_event_indices {
		ack := &state.scan.events[event_index]
		if ack.kind != LIBRARY_EVENT_PURGE_ACK ||
		   ack.device_id != state.settings.device_id {
			continue
		}
		resolved := false
		for candidate_index in state.materialized.accepted_event_indices {
			candidate := &state.scan.events[candidate_index]
			if candidate.target_event_id == ack.target_event_id &&
			   (candidate.kind == LIBRARY_EVENT_PURGE_REJECT ||
			    candidate.kind == LIBRARY_EVENT_OBJECT_PURGE ||
			    candidate.kind == LIBRARY_EVENT_ORPHAN_PURGE) {
				resolved = true
				break
			}
		}
		if !resolved {return ack.target_event_id, true}
	}
	return "", false
}

library_service_event_base :: proc(
	state: ^Library_Service_State,
	kind: string,
) -> (Library_Event, bool) {
	if !library_service_device_writable(state) {return {}, false}
	event_id, event_id_ok := library_uuid_new(context.temp_allocator)
	if !event_id_ok {return {}, false}
	return Library_Event{
		schema_version = LIBRARY_SCHEMA_VERSION,
		library_id = state.root.genesis.library_id,
		event_id = event_id,
		device_id = state.settings.device_id,
		device_sequence = state.settings.next_sequence,
		created_at_unix_ms = library_now_unix_ms(),
		kind = kind,
	}, true
}

library_service_device_writable :: proc(state: ^Library_Service_State) -> bool {
	if state == nil || !state.settings_loaded || !state.index_available {return false}
	device_index, device_found := library_device_index(
		state.materialized.devices[:],
		state.settings.device_id,
	)
	if !device_found || !state.materialized.devices[device_index].authorized ||
	   state.materialized.devices[device_index].retired {
		return false
	}
	return true
}

library_service_publish_event :: proc(
	state: ^Library_Service_State,
	event: ^Library_Event,
) -> (Library_File_Error, bool) {
	publish_error := library_publish_event(&state.root, event)
	if publish_error != .None && publish_error != .Already_Exists {
		return publish_error, false
	}
	state.settings.next_sequence = max(
		state.settings.next_sequence,
		event.device_sequence+1,
	)
	settings_saved := local_settings_save(&state.settings) == .None
	rebuilt := library_service_rebuild(state)
	return publish_error, settings_saved && rebuilt
}

library_service_publish_simple_capture_event :: proc(
	state: ^Library_Service_State,
	kind, capture_id, target_event_id: string,
) -> Library_Service_Response {
	if !state.settings_loaded {
		return library_service_error_response("settings", "The service has no writable device settings.")
	}
	if proposal_id, blocked := library_service_write_barrier(state); blocked {
		return library_service_error_response(
			"purge_barrier",
			fmt.tprintf("Writes are blocked by purge proposal %s.", proposal_id),
		)
	}
	event, event_ok := library_service_event_base(state, kind)
	if !event_ok {return library_service_error_response("identifier", "Event creation failed.")}
	event.capture_id = capture_id
	event.target_event_id = target_event_id
	publish_error, rebuilt := library_service_publish_event(state, &event)
	if publish_error != .None && publish_error != .Already_Exists {
		return library_service_error_response("publication", "The immutable event could not be published.")
	}
	if !rebuilt {
		return library_service_error_response(
			"local_rebuild",
			"The event is durable, but the local sequence or index rebuild failed.",
		)
	}
	return {
		protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
		ok = true,
		message = event.event_id,
	}
}

library_service_publish_ack :: proc(state: ^Library_Service_State) -> Library_Service_Response {
	if !state.settings_loaded {
		return library_service_error_response("settings", "The service has no writable device settings.")
	}
	event, event_ok := library_service_event_base(state, LIBRARY_EVENT_DEVICE_ACK)
	if !event_ok {return library_service_error_response("identifier", "Event creation failed.")}
	frontier := library_service_frontier(state, true, context.temp_allocator)
	event.frontier = frontier[:]
	publish_error, rebuilt := library_service_publish_event(state, &event)
	if publish_error != .None && publish_error != .Already_Exists {
		return library_service_error_response("publication", "The acknowledgement could not be published.")
	}
	if !rebuilt {
		return library_service_error_response(
			"local_rebuild",
			"The acknowledgement is durable, but the local sequence or index rebuild failed.",
		)
	}
	return {
		protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
		ok = true,
		message = event.event_id,
	}
}

library_service_latest_frontier_ack :: proc(
	state: ^Library_Service_State,
	device_id: string,
) -> (^Library_Event, bool) {
	best: ^Library_Event
	for event_index in state.materialized.accepted_event_indices {
		event := &state.scan.events[event_index]
		if event.device_id != device_id ||
		   (event.kind != LIBRARY_EVENT_DEVICE_ACK &&
		    event.kind != LIBRARY_EVENT_PURGE_ACK) {
			continue
		}
		if best == nil || event.device_sequence > best.device_sequence {best = event}
	}
	return best, best != nil
}

library_service_ack_needed :: proc(state: ^Library_Service_State) -> bool {
	if !state.settings_loaded {return false}
	required := make(map[string]u64, context.temp_allocator)
	defer delete(required)
	for capture in state.materialized.captures {
		record := &state.scan.records[capture.record_index]
		required[record.device_id] = max(required[record.device_id], record.device_sequence)
	}
	for event_index in state.materialized.accepted_event_indices {
		event := &state.scan.events[event_index]
		if event.kind == LIBRARY_EVENT_DEVICE_ACK ||
		   event.kind == LIBRARY_EVENT_PURGE_ACK {
			continue
		}
		required[event.device_id] = max(required[event.device_id], event.device_sequence)
	}
	if len(required) == 0 {return false}
	ack, ack_found := library_service_latest_frontier_ack(state, state.settings.device_id)
	if !ack_found {return true}
	for device_id, required_sequence in required {
		ack_sequence, covered := library_frontier_sequence(ack.frontier, device_id)
		if !covered || ack_sequence < required_sequence {return true}
	}
	return false
}

library_service_orphan_has_reference :: proc(
	state: ^Library_Service_State,
	digest: string,
) -> bool {
	for record in state.scan.records {
		if record.object_digest == digest {return true}
	}
	return false
}

library_service_orphan_candidate :: proc(
	state: ^Library_Service_State,
	digest: string,
) -> (^Library_Event, bool) {
	best: ^Library_Event
	for event_index in state.materialized.accepted_event_indices {
		candidate := &state.scan.events[event_index]
		if candidate.kind != LIBRARY_EVENT_ORPHAN_CANDIDATE ||
		   candidate.object_digest != digest {
			continue
		}
		resolved := false
		for other_index in state.materialized.accepted_event_indices {
			other := &state.scan.events[other_index]
			if (other.kind == LIBRARY_EVENT_ORPHAN_PURGE ||
			    other.kind == LIBRARY_EVENT_PURGE_REJECT) &&
			   other.target_event_id == candidate.event_id {
				resolved = true
				break
			}
		}
		if resolved {continue}
		if best == nil || candidate.created_at_unix_ms < best.created_at_unix_ms ||
		   (candidate.created_at_unix_ms == best.created_at_unix_ms &&
		    candidate.event_id < best.event_id) {
			best = candidate
		}
	}
	return best, best != nil
}

library_service_ack_covers_complete_frontier :: proc(
	state: ^Library_Service_State,
	ack: ^Library_Event,
	candidate: ^Library_Event,
) -> bool {
	if ack == nil {return false}
	candidate_sequence, candidate_covered := library_frontier_sequence(
		ack.frontier,
		candidate.device_id,
	)
	if !candidate_covered || candidate_sequence < candidate.device_sequence {return false}
	for device in state.materialized.devices {
		if !device.authorized || device.retired {continue}
		sequence, covered := library_frontier_sequence(ack.frontier, device.device_id)
		if !covered || sequence < device.sequence_prefix {return false}
	}
	return true
}

library_service_orphan_proof_ids :: proc(
	state: ^Library_Service_State,
	candidate: ^Library_Event,
	allocator := context.allocator,
) -> ([dynamic]string, [dynamic]string, bool) {
	active_ids := library_service_active_device_ids(state, allocator)
	proof_ids := make([dynamic]string, allocator)
	for active_id in active_ids {
		best_ack: ^Library_Event
		for event_index in state.materialized.accepted_event_indices {
			ack := &state.scan.events[event_index]
			if ack.kind != LIBRARY_EVENT_PURGE_ACK ||
			   ack.target_event_id != candidate.event_id ||
			   ack.device_id != active_id {
				continue
			}
			if best_ack == nil || ack.device_sequence > best_ack.device_sequence {
				best_ack = ack
			}
		}
		if best_ack == nil ||
		   !library_service_ack_covers_complete_frontier(state, best_ack, candidate) {
			return active_ids, proof_ids, false
		}
		append(&proof_ids, strings.clone(best_ack.event_id, allocator))
	}
	slice.sort(proof_ids[:])
	return active_ids, proof_ids, true
}

library_service_orphan_purge_valid :: proc(
	state: ^Library_Service_State,
	commit: ^Library_Event,
) -> bool {
	if commit == nil || commit.kind != LIBRARY_EVENT_ORPHAN_PURGE ||
	   library_service_orphan_has_reference(state, commit.object_digest) ||
	   len(state.materialized.pending_event_indices) > 0 ||
	   len(state.materialized.stream_faults) > 0 ||
	   len(state.materialized.document_faults) > 0 {
		return false
	}
	candidate: ^Library_Event
	for event_index in state.materialized.accepted_event_indices {
		event := &state.scan.events[event_index]
		if event.kind == LIBRARY_EVENT_ORPHAN_CANDIDATE &&
		   event.event_id == commit.target_event_id &&
		   event.object_digest == commit.object_digest {
			candidate = event
			break
		}
	}
	if candidate == nil || commit.created_at_unix_ms < candidate.purge_not_before_unix_ms {
		return false
	}
	active_ids := library_service_active_device_ids(state, context.temp_allocator)
	if !library_string_slices_equal(commit.active_device_ids, active_ids[:]) ||
	   len(commit.proof_event_ids) != len(commit.active_device_ids) {
		return false
	}
	for active_id in commit.active_device_ids {
		proof: ^Library_Event
		for event_index in state.materialized.accepted_event_indices {
			event := &state.scan.events[event_index]
			if event.kind == LIBRARY_EVENT_PURGE_ACK &&
			   event.target_event_id == candidate.event_id &&
			   event.device_id == active_id &&
			   slice.contains(commit.proof_event_ids, event.event_id) {
				proof = event
				break
			}
		}
		if proof == nil {return false}
		candidate_sequence, candidate_covered := library_frontier_sequence(
			proof.frontier,
			candidate.device_id,
		)
		if !candidate_covered || candidate_sequence < candidate.device_sequence {
			return false
		}
		for frontier_entry in commit.frontier {
			required := frontier_entry.sequence
			if frontier_entry.device_id == commit.device_id &&
			   required == commit.device_sequence {
				required -= 1
			}
			covered_sequence, covered := library_frontier_sequence(
				proof.frontier,
				frontier_entry.device_id,
			)
			if !covered || covered_sequence < required {return false}
		}
	}
	return true
}

library_service_acknowledge_or_reject_orphan :: proc(
	state: ^Library_Service_State,
	candidate: ^Library_Event,
) -> bool {
	if candidate == nil {return false}
	if library_service_orphan_has_reference(state, candidate.object_digest) {
		response := library_service_publish_purge_reject(
			state,
			candidate.event_id,
			"A capture record references the orphan candidate.",
		)
		return response.ok
	}
	if library_now_unix_ms() < candidate.purge_not_before_unix_ms {return false}
	for event_index in state.materialized.accepted_event_indices {
		ack := &state.scan.events[event_index]
		if ack.kind == LIBRARY_EVENT_PURGE_ACK &&
		   ack.target_event_id == candidate.event_id &&
		   ack.device_id == state.settings.device_id &&
		   library_service_ack_covers_complete_frontier(state, ack, candidate) {
			return false
		}
	}
	event, event_ok := library_service_event_base(state, LIBRARY_EVENT_PURGE_ACK)
	if !event_ok {return false}
	event.target_event_id = candidate.event_id
	frontier := library_service_frontier(state, true, context.temp_allocator)
	event.frontier = frontier[:]
	publish_error, rebuilt := library_service_publish_event(state, &event)
	return (publish_error == .None || publish_error == .Already_Exists) && rebuilt
}

library_service_publish_orphan_candidate :: proc(
	state: ^Library_Service_State,
	digest: string,
) -> bool {
	if library_service_orphan_has_reference(state, digest) {return false}
	if _, found := library_service_orphan_candidate(state, digest); found {return false}
	event, event_ok := library_service_event_base(state, LIBRARY_EVENT_ORPHAN_CANDIDATE)
	if !event_ok {return false}
	event.object_digest = digest
	event.purge_not_before_unix_ms = library_now_unix_ms()+
		state.root.genesis.recovery_interval_seconds*1_000
	publish_error, rebuilt := library_service_publish_event(state, &event)
	return (publish_error == .None || publish_error == .Already_Exists) && rebuilt
}

library_service_remove_orphan :: proc(
	state: ^Library_Service_State,
	digest: string,
) -> bool {
	path, path_ok := library_object_path(&state.root, digest, context.temp_allocator)
	if !path_ok {return false}
	if macos_coordinated_remove(path) != .None {return false}
	return library_service_rebuild(state)
}

library_service_commit_orphan_purge :: proc(
	state: ^Library_Service_State,
	candidate: ^Library_Event,
) -> bool {
	if candidate == nil || library_now_unix_ms() < candidate.purge_not_before_unix_ms ||
	   library_service_orphan_has_reference(state, candidate.object_digest) ||
	   len(state.materialized.pending_event_indices) > 0 ||
	   len(state.materialized.stream_faults) > 0 ||
	   len(state.materialized.document_faults) > 0 {
		return false
	}
	active_ids, proof_ids, proof_ready := library_service_orphan_proof_ids(
		state,
		candidate,
		context.temp_allocator,
	)
	if !proof_ready {return false}
	commit, commit_ok := library_service_event_base(state, LIBRARY_EVENT_ORPHAN_PURGE)
	if !commit_ok {return false}
	commit.target_event_id = candidate.event_id
	commit.object_digest = candidate.object_digest
	commit.active_device_ids = active_ids[:]
	commit.proof_event_ids = proof_ids[:]
	frontier := library_service_frontier(state, true, context.temp_allocator)
	commit.frontier = frontier[:]
	publish_error, rebuilt := library_service_publish_event(state, &commit)
	if (publish_error != .None && publish_error != .Already_Exists) || !rebuilt {
		return false
	}
	for event_index in state.materialized.accepted_event_indices {
		accepted := &state.scan.events[event_index]
		if accepted.event_id == commit.event_id &&
		   library_service_orphan_purge_valid(state, accepted) {
			return library_service_remove_orphan(state, accepted.object_digest)
		}
	}
	return false
}

library_service_maintenance :: proc(state: ^Library_Service_State) {
	if !state.settings_loaded {return}
	for digest in state.scan.orphan_digests {
		if _, found := library_service_orphan_candidate(state, digest); !found {
			if library_service_publish_orphan_candidate(state, digest) {return}
		}
	}
	for event_index in state.materialized.accepted_event_indices {
		candidate := &state.scan.events[event_index]
		if candidate.kind != LIBRARY_EVENT_ORPHAN_CANDIDATE {continue}
		if unresolved, found := library_service_orphan_candidate(
			state,
			candidate.object_digest,
		); found && unresolved.event_id == candidate.event_id {
			if library_service_acknowledge_or_reject_orphan(state, candidate) {return}
		}
	}
	if library_service_ack_needed(state) {
		_ = library_service_publish_ack(state)
		return
	}
	proposal_digest := ""
	proposal_id := ""
	for event_index in state.materialized.accepted_event_indices {
		proposal := &state.scan.events[event_index]
		if proposal.kind != LIBRARY_EVENT_PURGE_PROPOSE {continue}
		if unresolved, found := library_service_unresolved_proposal(
			state,
			proposal.object_digest,
		); found && unresolved.event_id == proposal.event_id {
			if proposal_id == "" || proposal.event_id < proposal_id {
				proposal_id = proposal.event_id
				proposal_digest = proposal.object_digest
			}
		}
	}
	if len(proposal_digest) > 0 {
		_ = library_service_purge_one(state, proposal_digest)
		return
	}
	for capture in state.materialized.captures {
		record := &state.scan.records[capture.record_index]
		if _, committed := library_object_current_purge_commit(
			&state.materialized,
			state.scan.records[:],
			state.scan.events[:],
			record.object_digest,
		); !committed {
			continue
		}
		object_path, path_ok := library_object_path(
			&state.root,
			record.object_digest,
			context.temp_allocator,
		)
		if path_ok && os.exists(object_path) {
			_ = library_service_purge_one(state, record.object_digest)
			return
		}
	}
	for event_index in state.materialized.accepted_event_indices {
		commit := &state.scan.events[event_index]
		if commit.kind == LIBRARY_EVENT_ORPHAN_PURGE &&
		   library_service_orphan_purge_valid(state, commit) {
			path, path_ok := library_object_path(
				&state.root,
				commit.object_digest,
				context.temp_allocator,
			)
			if path_ok && os.exists(path) {
				_ = library_service_remove_orphan(state, commit.object_digest)
				return
			}
		}
	}
	for digest in state.scan.orphan_digests {
		if candidate, found := library_service_orphan_candidate(state, digest); found {
			if library_service_commit_orphan_purge(state, candidate) {return}
		}
	}
}

library_purge_block_string :: proc(block: Library_Purge_Block) -> string {
	switch block {
	case .None: return "eligible"
	case .No_References: return "no_references"
	case .Live_Reference: return "live_reference"
	case .Recovery_Interval: return "recovery_interval"
	case .Missing_Device_Acknowledgement: return "missing_device_acknowledgement"
	case .Pending_Stream: return "pending_stream"
	}
	return "unknown"
}

library_service_active_device_ids :: proc(
	state: ^Library_Service_State,
	allocator := context.allocator,
) -> [dynamic]string {
	result := make([dynamic]string, allocator)
	for device in state.materialized.devices {
		if device.authorized && !device.retired {append(&result, device.device_id)}
	}
	slice.sort(result[:])
	return result
}

library_service_unresolved_proposal :: proc(
	state: ^Library_Service_State,
	object_digest: string,
) -> (^Library_Event, bool) {
	best: ^Library_Event
	for event_index in state.materialized.accepted_event_indices {
		proposal := &state.scan.events[event_index]
		if proposal.kind != LIBRARY_EVENT_PURGE_PROPOSE ||
		   proposal.object_digest != object_digest {
			continue
		}
		resolved := false
		for candidate_index in state.materialized.accepted_event_indices {
			candidate := &state.scan.events[candidate_index]
			if candidate.target_event_id == proposal.event_id &&
			   (candidate.kind == LIBRARY_EVENT_PURGE_REJECT ||
			    candidate.kind == LIBRARY_EVENT_OBJECT_PURGE) {
				resolved = true
				break
			}
		}
		if resolved {continue}
		if best == nil || proposal.created_at_unix_ms > best.created_at_unix_ms ||
		   (proposal.created_at_unix_ms == best.created_at_unix_ms &&
		    proposal.event_id > best.event_id) {
			best = proposal
		}
	}
	return best, best != nil
}

library_service_purge_statuses :: proc(
	state: ^Library_Service_State,
	allocator := context.allocator,
) -> [dynamic]Library_Service_Purge {
	result := make([dynamic]Library_Service_Purge, allocator)
	digests := make([dynamic]string, allocator)
	for capture in state.materialized.captures {
		digest := state.scan.records[capture.record_index].object_digest
		if !slice.contains(digests[:], digest) {append(&digests, digest)}
	}
	slice.sort(digests[:])
	for digest in digests {
		status := library_object_purge_status(
			&state.materialized,
			state.scan.records[:],
			state.scan.events[:],
			digest,
			library_now_unix_ms(),
			allocator,
		)
		proposal_id := ""
		if proposal, found := library_service_unresolved_proposal(state, digest); found {
			proposal_id = proposal.event_id
		}
		commit_id, committed := library_object_current_purge_commit(
			&state.materialized,
			state.scan.records[:],
			state.scan.events[:],
			digest,
		)
		append(&result, Library_Service_Purge{
			object_digest = digest,
			block = library_purge_block_string(status.block),
			not_before_unix_ms = status.not_before_unix_ms,
			required_event_ids = status.required_tombstone_ids[:],
			blocking_device_ids = status.blocking_device_ids[:],
			proposal_event_id = proposal_id,
			commit_event_id = committed ? commit_id : "",
		})
	}
	return result
}

library_service_proposal_matches_current :: proc(
	state: ^Library_Service_State,
	proposal: ^Library_Event,
	status: ^Library_Purge_Status,
) -> bool {
	active_ids := library_service_active_device_ids(state, context.temp_allocator)
	return status.block == .None &&
	       proposal.purge_not_before_unix_ms == status.not_before_unix_ms &&
	       library_string_slices_equal(
			proposal.required_event_ids,
			status.required_tombstone_ids[:],
	       ) &&
	       library_string_slices_equal(proposal.active_device_ids, active_ids[:])
}

library_service_publish_purge_reject :: proc(
	state: ^Library_Service_State,
	proposal_id, reason: string,
) -> Library_Service_Response {
	event, event_ok := library_service_event_base(state, LIBRARY_EVENT_PURGE_REJECT)
	if !event_ok {return library_service_error_response("identifier", "Event creation failed.")}
	event.target_event_id = proposal_id
	event.note = reason
	frontier := library_service_frontier(state, true, context.temp_allocator)
	event.frontier = frontier[:]
	publish_error, rebuilt := library_service_publish_event(state, &event)
	if publish_error != .None && publish_error != .Already_Exists {
		return library_service_error_response("publication", "The purge rejection could not be published.")
	}
	if !rebuilt {
		return library_service_error_response("local_rebuild", "The purge rejection is durable, but the local rebuild failed.")
	}
	return {protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, ok=true, message="rejected"}
}

library_service_purge_one :: proc(
	state: ^Library_Service_State,
	object_digest: string,
) -> Library_Service_Response {
	if !state.settings_loaded {
		return library_service_error_response("settings", "The service has no writable device settings.")
	}
	if !library_digest_valid(object_digest) {
		return library_service_error_response("invalid_digest", "The object digest is invalid.")
	}
	if commit_id, committed := library_object_current_purge_commit(
		&state.materialized,
		state.scan.records[:],
		state.scan.events[:],
		object_digest,
	); committed {
		object_path, path_ok := library_object_path(&state.root, object_digest, context.temp_allocator)
		if !path_ok || macos_coordinated_remove(object_path) != .None {
			return library_service_error_response(
				"physical_remove",
				fmt.tprintf("Purge commit %s is durable, but object removal failed.", commit_id),
			)
		}
		if !library_service_rebuild(state) {
			return library_service_error_response("local_rebuild", "The object was removed, but the local rebuild failed.")
		}
		return {protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, ok=true, message="purged"}
	}

	now := library_now_unix_ms()
	status := library_object_purge_status(
		&state.materialized,
		state.scan.records[:],
		state.scan.events[:],
		object_digest,
		now,
		context.temp_allocator,
	)
	proposal, proposal_found := library_service_unresolved_proposal(state, object_digest)
	if !proposal_found {
		if status.block != .None {
			return library_service_error_response(
				library_purge_block_string(status.block),
				"The object is not eligible for a purge proposal.",
			)
		}
		event, event_ok := library_service_event_base(state, LIBRARY_EVENT_PURGE_PROPOSE)
		if !event_ok {return library_service_error_response("identifier", "Event creation failed.")}
		event.object_digest = object_digest
		event.required_event_ids = status.required_tombstone_ids[:]
		active_ids := library_service_active_device_ids(state, context.temp_allocator)
		event.active_device_ids = active_ids[:]
		event.purge_not_before_unix_ms = status.not_before_unix_ms
		publish_error, rebuilt := library_service_publish_event(state, &event)
		if publish_error != .None && publish_error != .Already_Exists {
			return library_service_error_response("publication", "The purge proposal could not be published.")
		}
		if !rebuilt {
			return library_service_error_response("local_rebuild", "The proposal is durable, but the local rebuild failed.")
		}
		proposal, proposal_found = library_service_unresolved_proposal(state, object_digest)
		if !proposal_found {
			return library_service_error_response("proposal", "The published purge proposal was not materialized.")
		}
		status = library_object_purge_status(
			&state.materialized,
			state.scan.records[:],
			state.scan.events[:],
			object_digest,
			library_now_unix_ms(),
			context.temp_allocator,
		)
	}

	if !library_service_proposal_matches_current(state, proposal, &status) {
		return library_service_publish_purge_reject(
			state,
			proposal.event_id,
			"The synchronized references, active devices, or eligibility proof changed.",
		)
	}

	current_ack_found := false
	for event_index in state.materialized.accepted_event_indices {
		event := &state.scan.events[event_index]
		if event.kind == LIBRARY_EVENT_PURGE_ACK &&
		   event.target_event_id == proposal.event_id &&
		   event.device_id == state.settings.device_id {
			current_ack_found = true
			break
		}
	}
	if !current_ack_found {
		event, event_ok := library_service_event_base(state, LIBRARY_EVENT_PURGE_ACK)
		if !event_ok {return library_service_error_response("identifier", "Event creation failed.")}
		event.target_event_id = proposal.event_id
		frontier := library_service_frontier(state, true, context.temp_allocator)
		event.frontier = frontier[:]
		publish_error, rebuilt := library_service_publish_event(state, &event)
		if publish_error != .None && publish_error != .Already_Exists {
			return library_service_error_response("publication", "The purge acknowledgement could not be published.")
		}
		if !rebuilt {
			return library_service_error_response("local_rebuild", "The purge acknowledgement is durable, but the local rebuild failed.")
		}
		proposal, proposal_found = library_service_unresolved_proposal(state, object_digest)
		if !proposal_found {
			return library_service_error_response("proposal", "The purge proposal resolved during acknowledgement.")
		}
	}

	proof_ids := make([dynamic]string, context.temp_allocator)
	for active_device_id in proposal.active_device_ids {
		best_ack: ^Library_Event
		for event_index in state.materialized.accepted_event_indices {
			ack := &state.scan.events[event_index]
			if ack.kind != LIBRARY_EVENT_PURGE_ACK ||
			   ack.target_event_id != proposal.event_id ||
			   ack.device_id != active_device_id {
				continue
			}
			if best_ack == nil || ack.device_sequence > best_ack.device_sequence {
				best_ack = ack
			}
		}
		if best_ack == nil {
			return {protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, ok=true, message="awaiting_device_acknowledgements"}
		}
		append(&proof_ids, best_ack.event_id)
	}
	slice.sort(proof_ids[:])
	status = library_object_purge_status(
		&state.materialized,
		state.scan.records[:],
		state.scan.events[:],
		object_digest,
		library_now_unix_ms(),
		context.temp_allocator,
	)
	if !library_service_proposal_matches_current(state, proposal, &status) {
		return library_service_publish_purge_reject(
			state,
			proposal.event_id,
			"The purge proof changed before commit.",
		)
	}
	commit, commit_ok := library_service_event_base(state, LIBRARY_EVENT_OBJECT_PURGE)
	if !commit_ok {return library_service_error_response("identifier", "Event creation failed.")}
	commit.target_event_id = proposal.event_id
	commit.object_digest = proposal.object_digest
	commit.required_event_ids = proposal.required_event_ids
	commit.proof_event_ids = proof_ids[:]
	commit.active_device_ids = proposal.active_device_ids
	frontier := library_service_frontier(state, true, context.temp_allocator)
	commit.frontier = frontier[:]
	publish_error, rebuilt := library_service_publish_event(state, &commit)
	if publish_error != .None && publish_error != .Already_Exists {
		return library_service_error_response("publication", "The purge commit could not be published.")
	}
	if !rebuilt {
		return library_service_error_response("local_rebuild", "The purge commit is durable, but the local rebuild failed.")
	}
	if _, valid := library_object_has_valid_purge_commit(
		&state.materialized,
		state.scan.events[:],
		object_digest,
	); !valid {
		return library_service_error_response("commit_proof", "The published purge commit did not validate.")
	}
	object_path, path_ok := library_object_path(&state.root, object_digest, context.temp_allocator)
	if !path_ok || macos_coordinated_remove(object_path) != .None {
		return library_service_error_response("physical_remove", "The purge commit is durable, but object removal failed.")
	}
	if !library_service_rebuild(state) {
		return library_service_error_response("local_rebuild", "The object was removed, but the local rebuild failed.")
	}
	return {protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, ok=true, message="purged"}
}

library_service_move_rollback :: proc(
	state: ^Library_Service_State,
	from_path, to_path: string,
) -> bool {
	if macos_coordinated_move_directory(from_path, to_path) != .None {
		state.index_available = false
		return false
	}
	if !macos_file_presenter_start(&state.file_presenter, state) {
		state.index_available = false
		return false
	}
	return true
}

library_service_move_root :: proc(
	state: ^Library_Service_State,
	destination_path: string,
) -> Library_Service_Response {
	if !state.settings_loaded {
		return library_service_error_response("settings", "The service has no configured library root.")
	}
	if len(state.transfers) > 0 {
		return library_service_error_response("capture_active", "Finish the active browser capture before moving the library.")
	}
	if len(destination_path) == 0 || len(destination_path) > 32*1024 ||
	   !filepath.is_abs(destination_path) {
		return library_service_error_response("invalid_path", "The move destination must be an absolute path.")
	}
	if destination_path == state.root.path || os.exists(destination_path) {
		return library_service_error_response("destination_exists", "Choose a new library path that does not already exist.")
	}
	source_prefix := fmt.tprintf("%s/", state.root.path)
	destination_prefix := fmt.tprintf("%s/", destination_path)
	if strings.has_prefix(destination_prefix, source_prefix) {
		return library_service_error_response("invalid_path", "The library cannot move inside itself.")
	}
	for device in state.materialized.devices {
		if device.authorized && !device.retired &&
		   device.device_id != state.settings.device_id {
			return library_service_error_response(
				"active_remote_device",
				"Retire every other active Mac before moving the authoritative root.",
			)
		}
	}
	if !library_service_device_writable(state) {
		return library_service_error_response("device_not_writable", "This Mac is not an active authorized writer.")
	}
	old_path := strings.clone(state.root.path, context.temp_allocator)
	macos_file_presenter_stop(&state.file_presenter)
	moved := macos_coordinated_move_directory(old_path, destination_path)
	if moved != .None {
		if !macos_file_presenter_start(&state.file_presenter, state) {
			state.index_available = false
			return library_service_error_response("presenter", "The move failed and file presentation must recover on relaunch.")
		}
		return library_service_error_response("move", "The coordinated library move failed.")
	}
	new_root, open_error := library_root_open(destination_path)
	if open_error != .None {
		if !library_service_move_rollback(state, destination_path, old_path) {
			return library_service_error_response("move_rollback", "The moved library failed validation and the previous working state could not be restored automatically.")
		}
		return library_service_error_response("move_validation", "The moved library failed validation and was moved back.")
	}
	bookmark, bookmark_error := macos_bookmark_create(destination_path)
	if bookmark_error != .None {
		library_root_destroy(&new_root)
		if !library_service_move_rollback(state, destination_path, old_path) {
			return library_service_error_response("move_rollback", "Bookmark creation failed and the previous working state could not be restored automatically.")
		}
		return library_service_error_response("bookmark", "The moved library bookmark could not be created, so the move was reversed.")
	}
	next_settings := local_settings_clone(&state.settings)
	delete(next_settings.library_path)
	next_settings.library_path = strings.clone(destination_path)
	delete(next_settings.library_mode)
	next_settings.library_mode = strings.clone(LOCAL_SETTINGS_MODE_BOOKMARK)
	delete(next_settings.bookmark_base64)
	next_settings.bookmark_base64 = bookmark
	if local_settings_save(&next_settings) != .None {
		local_settings_destroy(&next_settings)
		library_root_destroy(&new_root)
		if !library_service_move_rollback(state, destination_path, old_path) {
			return library_service_error_response("move_rollback", "Settings could not be committed and the previous working state could not be restored automatically.")
		}
		return library_service_error_response("settings", "The new root could not be committed, so the move was reversed.")
	}
	library_root_destroy(&state.root)
	state.root = new_root
	local_settings_destroy(&state.settings)
	state.settings = next_settings
	if !macos_file_presenter_start(&state.file_presenter, state) {
		state.index_available = false
		return library_service_error_response("presenter", "The move is durable, but file presentation must recover on relaunch.")
	}
	if !library_service_rebuild(state) {
		return library_service_error_response("local_rebuild", "The move is durable, but the local index rebuild failed.")
	}
	return {
		protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
		ok = true,
		message = destination_path,
	}
}

library_service_execute :: proc(
	state: ^Library_Service_State,
	request: ^Library_Service_Request,
	allocator := context.allocator,
) -> Library_Service_Response {
	if request.protocol_version != LIBRARY_SERVICE_PROTOCOL_VERSION {
		return library_service_error_response("protocol_version", "Unsupported service protocol version.")
	}
	if !state.index_available && request.command != "health" &&
	   request.command != "library.rebuild" && request.command != "service.stop" {
		return library_service_error_response(
			"index_unavailable",
			"Rebuild the local index before using the library.",
		)
	}
	switch request.command {
	case "health":
		return {
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			ok = true,
			message = state.index_available ? "ready" : "index_unavailable",
			issue_count = len(state.scan.issues),
		}
	case "library.rebuild":
		if !library_service_rebuild(state) {
			return library_service_error_response("index_rebuild", "The local index rebuild failed.")
		}
		return {
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			ok = true,
			message = "rebuilt",
			issue_count = len(state.scan.issues),
		}
	case "service.stop":
		allow_stop, allowed := os.lookup_env("HW_GALLERY_ALLOW_SERVICE_STOP", context.temp_allocator)
		if !allowed || allow_stop != "1" {
			return library_service_error_response("forbidden", "Service shutdown is disabled.")
		}
		library_service_set_running(state, false)
		return {
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			ok = true,
			message = "stopping",
		}
	case "library.devices":
		return {
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			ok = true,
			devices = library_service_devices(state, allocator),
			issue_count = len(state.scan.issues),
		}
	case "library.purge-status":
		return {
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			ok = true,
			purges = library_service_purge_statuses(state, allocator),
			issue_count = len(state.scan.issues),
		}
	case "library.purge":
		if request.confirmation != request.object_digest {
			return library_service_error_response(
				"confirmation",
				"Physical purge requires the exact object digest as confirmation.",
			)
		}
		return library_service_purge_one(state, request.object_digest)
	case "library.move":
		if request.confirmation != request.path {
			return library_service_error_response("confirmation", "The library move requires the exact destination path as confirmation.")
		}
		return library_service_move_root(state, request.path)
	case "settings.theme-set":
		if request.text != "hw-light" && request.text != "hw-dark" {
			return library_service_error_response("invalid_theme", "The interface theme is invalid.")
		}
		delete(state.settings.interface_theme, state.settings.allocator)
		state.settings.interface_theme = strings.clone(request.text, state.settings.allocator)
		if local_settings_save(&state.settings) != .None {
			return library_service_error_response("settings", "The interface theme could not be saved.")
		}
		return {protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, ok=true, message=request.text}
	case "capture.list":
		captures, listed := library_index_capture_list(
			state.database,
			request.include_deleted,
			allocator,
		)
		if !listed {return library_service_error_response("index_query", "Capture listing failed.")}
		return {
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			ok = true,
			captures = captures,
		}
	case "capture.search":
		if len(request.text) == 0 || len(request.text) > 4096 {
			return library_service_error_response("invalid_query", "Search text must contain 1 to 4096 bytes.")
		}
		captures, searched := library_index_capture_search(state.database, request.text, allocator)
		if !searched {return library_service_error_response("index_query", "Capture search failed.")}
		return {
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			ok = true,
			captures = captures,
		}
	case "capture.show":
		if !library_uuid_valid(request.capture_id) {
			return library_service_error_response("invalid_capture_id", "The capture identifier is invalid.")
		}
		capture, found := library_index_capture_show(state.database, request.capture_id, allocator)
		if !found {return library_service_error_response("not_found", "The capture was not found.")}
		return {
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			ok = true,
			capture = capture,
			 has_capture = true,
		}
	case "capture.export":
		if !library_uuid_valid(request.capture_id) {
			return library_service_error_response("invalid_capture_id", "The capture identifier is invalid.")
		}
		if len(request.path) == 0 || !filepath.is_abs(request.path) {
			return library_service_error_response("invalid_path", "The export path must be absolute.")
		}
		capture, found := library_index_capture_show(state.database, request.capture_id, allocator)
		if !found {return library_service_error_response("not_found", "The capture was not found.")}
		if capture.object_state != .Available {
			return library_service_error_response("object_unavailable", "The original object is not locally available.")
		}
		source_path, source_ok := library_object_path(
			&state.root,
			capture.object_digest,
			context.temp_allocator,
		)
		if !source_ok {
			return library_service_error_response("object_path", "The original object path is invalid.")
		}
		export_error := macos_coordinated_export(
			source_path,
			request.path,
			capture.object_digest,
			capture.byte_count,
		)
		if export_error != .None {
			code := export_error == .Already_Exists ? "destination_exists" : "export"
			return library_service_error_response(code, "The byte-identical export failed.")
		}
		return {protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, ok=true, message=request.path}
	case "capture.download":
		if !library_uuid_valid(request.capture_id) {
			return library_service_error_response("invalid_capture_id", "The capture identifier is invalid.")
		}
		capture, found := library_index_capture_show(state.database, request.capture_id, allocator)
		if !found {return library_service_error_response("not_found", "The capture was not found.")}
		object_path, path_ok := library_object_path(
			&state.root,
			capture.object_digest,
			context.temp_allocator,
		)
		if !path_ok || !macos_start_downloading_ubiquitous_file(object_path) {
			return library_service_error_response("download", "The iCloud object download could not be started.")
		}
		return {protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, ok=true, message="download_started"}
	case "capture.thumbnail":
		if !library_uuid_valid(request.capture_id) {
			return library_service_error_response("invalid_capture_id", "The capture identifier is invalid.")
		}
		if request.maximum_pixels < 32 || request.maximum_pixels > 4096 {
			return library_service_error_response("invalid_size", "The thumbnail size must be between 32 and 4096 pixels.")
		}
		capture, found := library_index_capture_show(state.database, request.capture_id, allocator)
		if !found {return library_service_error_response("not_found", "The capture was not found.")}
		if capture.object_state != .Available {
			return library_service_error_response("object_unavailable", "The original object is not locally available.")
		}
		source_path, source_ok := library_object_path(
			&state.root,
			capture.object_digest,
			context.temp_allocator,
		)
		if !source_ok {
			return library_service_error_response("object_path", "The original object path is invalid.")
		}
		thumbnail_path, thumbnail_error := macos_thumbnail_cache_create(
			source_path,
			state.support_path,
			capture.object_digest,
			request.maximum_pixels,
			allocator,
		)
		if thumbnail_error != .None {
			return library_service_error_response("thumbnail", "The local thumbnail could not be generated.")
		}
		return {
			protocol_version = LIBRARY_SERVICE_PROTOCOL_VERSION,
			ok = true,
			message = thumbnail_path,
		}
	case "capture.note-set":
		if !library_uuid_valid(request.capture_id) {
			return library_service_error_response("invalid_capture_id", "The capture identifier is invalid.")
		}
		if !library_text_valid(request.text, LIBRARY_MAX_NOTE_BYTES) {
			return library_service_error_response("invalid_note", "The note exceeds the storage bound.")
		}
		capture, found := library_service_capture_state(state, request.capture_id)
		if !found {return library_service_error_response("not_found", "The capture was not found.")}
		if _, blocked := library_service_write_barrier(state); blocked {
			return library_service_error_response("purge_barrier", "A purge barrier blocks note changes.")
		}
		event, event_ok := library_service_event_base(state, LIBRARY_EVENT_NOTE_SET)
		if !event_ok {return library_service_error_response("identifier", "Event creation failed.")}
		event.capture_id = request.capture_id
		event.note = request.text
		predecessors := make([dynamic]string, context.temp_allocator)
		for head in capture.note_heads {append(&predecessors, head.revision_id)}
		slice.sort(predecessors[:])
		event.predecessor_revisions = predecessors[:]
		publish_error, rebuilt := library_service_publish_event(state, &event)
		if publish_error != .None && publish_error != .Already_Exists {
			return library_service_error_response("publication", "The note revision could not be published.")
		}
		if !rebuilt {
			return library_service_error_response("local_rebuild", "The note is durable, but the local rebuild failed.")
		}
		return {protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, ok=true, message=event.event_id}
	case "capture.delete":
		if !library_uuid_valid(request.capture_id) {
			return library_service_error_response("invalid_capture_id", "The capture identifier is invalid.")
		}
		capture, found := library_service_capture_state(state, request.capture_id)
		if !found {return library_service_error_response("not_found", "The capture was not found.")}
		if capture.deleted {return library_service_error_response("already_deleted", "The capture is already deleted.")}
		return library_service_publish_simple_capture_event(
			state,
			LIBRARY_EVENT_CAPTURE_DELETE,
			request.capture_id,
			"",
		)
	case "capture.restore":
		if !library_uuid_valid(request.capture_id) {
			return library_service_error_response("invalid_capture_id", "The capture identifier is invalid.")
		}
		capture, found := library_service_capture_state(state, request.capture_id)
		if !found {return library_service_error_response("not_found", "The capture was not found.")}
		if !capture.deleted {
			return library_service_error_response("not_deleted", "The capture has no effective tombstone.")
		}
		indexed_capture, indexed_found := library_index_capture_show(
			state.database,
			request.capture_id,
			context.temp_allocator,
		)
		if !indexed_found || indexed_capture.object_state != .Available {
			return library_service_error_response(
				"object_unavailable",
				"A deleted capture can be restored only while its original bytes remain available.",
			)
		}
		tombstones := make([dynamic]string, context.temp_allocator)
		for tombstone_id in capture.effective_delete_ids {
			append(&tombstones, strings.clone(tombstone_id, context.temp_allocator))
		}
		last_response: Library_Service_Response
		for tombstone_id in tombstones {
			last_response = library_service_publish_simple_capture_event(
				state,
				LIBRARY_EVENT_CAPTURE_RESTORE,
				request.capture_id,
				tombstone_id,
			)
			if !last_response.ok {return last_response}
		}
		return last_response
	case "library.ack":
		return library_service_publish_ack(state)
	case "library.device-authorize":
		if !library_uuid_valid(request.device_id) {
			return library_service_error_response("invalid_device_id", "The device identifier is invalid.")
		}
		if _, blocked := library_service_write_barrier(state); blocked {
			return library_service_error_response("purge_barrier", "A purge barrier blocks device authorization.")
		}
		request_found := false
		for join_request in state.scan.join_requests {
			if join_request.device_id == request.device_id {request_found = true; break}
		}
		if !request_found {
			return library_service_error_response("join_request", "No synchronized join request exists for that device.")
		}
		event, event_ok := library_service_event_base(state, LIBRARY_EVENT_DEVICE_JOIN)
		if !event_ok {return library_service_error_response("identifier", "Event creation failed.")}
		event.target_device_id = request.device_id
		publish_error, rebuilt := library_service_publish_event(state, &event)
		if publish_error != .None && publish_error != .Already_Exists {
			return library_service_error_response("publication", "The device authorization could not be published.")
		}
		if !rebuilt {
			return library_service_error_response("local_rebuild", "Authorization is durable, but the local rebuild failed.")
		}
		return {protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, ok=true, message=event.event_id}
	case "library.device-retire":
		if !library_uuid_valid(request.device_id) {
			return library_service_error_response("invalid_device_id", "The device identifier is invalid.")
		}
		if !state.settings_loaded {
			return library_service_error_response("settings", "The service has no writable device settings.")
		}
		if request.device_id == state.settings.device_id {
			return library_service_error_response("current_device", "The current device cannot retire itself.")
		}
		if request.confirmation != request.device_id {
			return library_service_error_response("confirmation", "Device retirement requires the exact device identifier as confirmation.")
		}
		device_index, found := library_device_index(state.materialized.devices[:], request.device_id)
		if !found || !state.materialized.devices[device_index].authorized ||
		   state.materialized.devices[device_index].retired {
			return library_service_error_response("device_state", "The device is not an active authorized device.")
		}
		event, event_ok := library_service_event_base(state, LIBRARY_EVENT_DEVICE_RETIRE)
		if !event_ok {return library_service_error_response("identifier", "Event creation failed.")}
		event.target_device_id = request.device_id
		event.target_device_sequence = state.materialized.devices[device_index].sequence_prefix
		publish_error, rebuilt := library_service_publish_event(state, &event)
		if publish_error != .None && publish_error != .Already_Exists {
			return library_service_error_response("publication", "The retirement event could not be published.")
		}
		if !rebuilt {
			return library_service_error_response("local_rebuild", "Retirement is durable, but the local rebuild failed.")
		}
		return {protocol_version=LIBRARY_SERVICE_PROTOCOL_VERSION, ok=true, message=event.event_id}
	}
	return library_service_error_response("unknown_command", "Unknown service command.")
}

library_service_send_response :: proc(
	connection: local_command.Connection,
	response: Library_Service_Response,
) -> bool {
	bytes, encode_error := json.marshal(response, {}, context.temp_allocator)
	if encode_error != nil {return false}
	return local_command.connection_send_response(connection, bytes)
}

library_service_handle_request :: proc(
	user_data: rawptr,
	connection: local_command.Connection,
	status: local_command.Read_Status,
	request_bytes: []u8,
) {
	state := cast(^Library_Service_State)user_data
	if status != .Success {
		_ = library_service_send_response(
			connection,
			library_service_error_response("request_read", "The service request could not be read."),
		)
		return
	}
	request: Library_Service_Request
	if decode_error := json.unmarshal(
		request_bytes,
		&request,
		.JSON,
		context.temp_allocator,
	); decode_error != nil {
		_ = library_service_send_response(
			connection,
			library_service_error_response("invalid_json", "The service request is not valid JSON."),
		)
		return
	}
	sync.mutex_lock(&state.operation_mutex)
	response := library_service_execute(state, &request, context.temp_allocator)
	_ = library_service_send_response(connection, response)
	sync.mutex_unlock(&state.operation_mutex)
}

library_service_start :: proc(state: ^Library_Service_State) -> Library_Service_Error {
	native_ingestion_cleanup_staging(state)
	if !macos_file_presenter_start(&state.file_presenter, state) {
		return .Presenter
	}
	if local_command.server_start(&state.server, {
		path = state.socket_path,
		handler = library_service_handle_request,
		user_data = state,
		request_timeout = 5*time.Second,
	}) != .None {
		macos_file_presenter_stop(&state.file_presenter)
		return .Socket
	}
	if !ingest_ipc_server_start(
		&state.ingest_server,
		state.ingest_socket_path,
		state,
	) {
		local_command.server_stop(&state.server)
		macos_file_presenter_stop(&state.file_presenter)
		return .Socket
	}
	return .None
}

library_service_client_exchange :: proc(
	socket_path: string,
	request: Library_Service_Request,
	allocator := context.allocator,
) -> (Library_Service_Response, bool) {
	request_bytes, encode_error := json.marshal(request, {}, context.temp_allocator)
	if encode_error != nil {return {}, false}
	response_bytes, client_status := local_command.client_exchange(
		socket_path,
		request_bytes,
		context.temp_allocator,
	)
	if client_status != .Success {return {}, false}
	response: Library_Service_Response
	if decode_error := json.unmarshal(response_bytes, &response, .JSON, allocator);
	   decode_error != nil {
		return {}, false
	}
	return response, true
}
