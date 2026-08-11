package main

import "core:c"
import "core:crypto"
import "core:crypto/sha2"
import hex "core:encoding/hex"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "base:runtime"

foreign import library_system "system:System"
foreign library_system {
	renamex_np :: proc "c" (old_path, new_path: cstring, flags: c.uint) -> c.int ---
}

LIBRARY_RENAME_EXCLUSIVE :: c.uint(0x00000004)
LIBRARY_PARTIAL_PREFIX :: ".hw-image-library-partial-"

Library_File_Error :: enum {
	None,
	Invalid_Path,
	Not_Found,
	Already_Exists,
	Conflict,
	Create_Directory,
	Open,
	Read,
	Write,
	Sync,
	Rename,
	Encode,
	Decode,
	Invalid_Document,
	Invalid_Layout,
	Digest_Mismatch,
}

Library_Root :: struct {
	path:    string,
	genesis: Library_Genesis,
	allocator: runtime.Allocator,
}

Library_Object_State :: enum {
	Available,
	Missing,
	Corrupt,
	Unavailable,
	Purged,
}

Library_Scan_Issue :: struct {
	path:   string,
	reason: string,
}

Library_Scan :: struct {
	records:       [dynamic]Library_Capture_Record,
	record_objects: [dynamic]Library_Object_State,
	events:        [dynamic]Library_Event,
	join_requests: [dynamic]Library_Join_Request,
	object_digests: [dynamic]string,
	orphan_digests: [dynamic]string,
	issues:        [dynamic]Library_Scan_Issue,
	allocator:     runtime.Allocator,
}

library_join :: proc(parts: []string, allocator := context.allocator) -> (string, bool) {
	path, error := filepath.join(parts, allocator)
	return path, error == nil
}

library_uuid_new :: proc(allocator := context.allocator) -> (string, bool) {
	previous_generator := context.random_generator
	context.random_generator = crypto.random_generator()
	defer context.random_generator = previous_generator
	identifier := uuid.generate_v4()
	value, error := uuid.to_string_allocated(identifier, allocator)
	return value, error == nil
}

library_now_unix_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

library_sequence_filename :: proc(
	sequence: u64,
	document_id: string,
	allocator := context.allocator,
) -> (string, bool) {
	if sequence == 0 || !library_uuid_valid(document_id) {return "", false}
	return fmt.aprintf("%020d-%s.json", sequence, document_id, allocator=allocator), true
}

library_sequence_filename_parse :: proc(name: string) -> (u64, string, bool) {
	if len(name) != 62 || name[20] != '-' || !strings.has_suffix(name, ".json") {
		return 0, "", false
	}
	sequence, parsed := strconv.parse_u64(name[:20])
	document_id := name[21:57]
	if !parsed || sequence == 0 || !library_uuid_valid(document_id) {
		return 0, "", false
	}
	return sequence, document_id, true
}

library_write_synced_exclusive :: proc(path: string, bytes: []u8) -> Library_File_Error {
	file, open_error := os.open(
		path,
		os.O_WRONLY | os.O_CREATE | os.O_EXCL,
		os.Permissions_Read_All + {.Write_User},
	)
	if open_error != nil {return .Open}
	total := 0
	for total < len(bytes) {
		count, write_error := os.write(file, bytes[total:])
		if write_error != nil || count <= 0 {
			_ = os.close(file)
			return .Write
		}
		total += count
	}
	if os.sync(file) != nil {
		_ = os.close(file)
		return .Sync
	}
	if os.close(file) != nil {return .Sync}
	return .None
}

library_sync_directory :: proc(path: string) -> bool {
	directory, open_error := os.open(path)
	if open_error != nil {return false}
	defer os.close(directory)
	return os.sync(directory) == nil
}

library_ensure_directory :: proc(path: string) -> bool {
	error := os.make_directory_all(path)
	return error == nil || os.exists(path)
}

library_atomic_publish_bytes :: proc(
	final_path: string,
	bytes: []u8,
	allocator := context.allocator,
) -> Library_File_Error {
	parent := filepath.dir(final_path)
	if len(parent) == 0 {return .Invalid_Path}
	temporary_id, id_ok := library_uuid_new(context.temp_allocator)
	if !id_ok {return .Write}
	temporary_name := fmt.tprintf("%s%s", LIBRARY_PARTIAL_PREFIX, temporary_id)
	temporary_path, path_ok := library_join([]string{parent, temporary_name}, context.temp_allocator)
	if !path_ok {return .Invalid_Path}
	write_error := library_write_synced_exclusive(temporary_path, bytes)
	if write_error != .None {return write_error}
	temporary_exists := true
	defer if temporary_exists {_ = os.remove(temporary_path)}

	old_c := strings.clone_to_cstring(temporary_path, context.temp_allocator)
	new_c := strings.clone_to_cstring(final_path, context.temp_allocator)
	if renamex_np(old_c, new_c, LIBRARY_RENAME_EXCLUSIVE) != 0 {
		if os.exists(final_path) {
			existing, read_error := os.read_entire_file(final_path, context.temp_allocator)
			if read_error != nil {return .Read}
			if slice.equal(existing, bytes) {return .Already_Exists}
			return .Conflict
		}
		return .Rename
	}
	temporary_exists = false
	if !library_sync_directory(parent) {return .Sync}
	return .None
}

library_sha256_file :: proc(
	path: string,
	allocator := context.allocator,
) -> (string, i64, bool) {
	file, open_error := os.open(path)
	if open_error != nil {return "", 0, false}
	defer os.close(file)
	context_256: sha2.Context_256
	sha2.init_256(&context_256)
	byte_count: i64
	buffer: [256 * 1024]u8
	for {
		count, read_error := os.read(file, buffer[:])
		if read_error != nil && read_error != .EOF {return "", byte_count, false}
		if count > 0 {
			sha2.update(&context_256, buffer[:count])
			byte_count += i64(count)
			if byte_count > LIBRARY_MAX_OBJECT_BYTES {return "", byte_count, false}
		}
		if count == 0 || read_error == .EOF {break}
	}
	digest: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&context_256, digest[:])
	encoded, encode_error := hex.encode(digest[:], allocator)
	if encode_error != nil {return "", byte_count, false}
	return string(encoded), byte_count, true
}

library_copy_verified :: proc(
	source_path, destination_path, expected_digest: string,
	expected_byte_count: i64,
) -> Library_File_Error {
	source, source_error := os.open(source_path)
	if source_error != nil {return .Open}
	defer os.close(source)
	destination, destination_error := os.open(
		destination_path,
		os.O_WRONLY | os.O_CREATE | os.O_EXCL,
		os.Permissions_Read_All + {.Write_User},
	)
	if destination_error != nil {return .Open}
	destination_open := true
	defer if destination_open {_ = os.close(destination)}

	context_256: sha2.Context_256
	sha2.init_256(&context_256)
	byte_count: i64
	buffer: [256 * 1024]u8
	for {
		count, read_error := os.read(source, buffer[:])
		if read_error != nil && read_error != .EOF {return .Read}
		if count > 0 {
			byte_count += i64(count)
			if byte_count > LIBRARY_MAX_OBJECT_BYTES {return .Invalid_Document}
			sha2.update(&context_256, buffer[:count])
			written := 0
			for written < count {
				amount, write_error := os.write(destination, buffer[written:count])
				if write_error != nil || amount <= 0 {return .Write}
				written += amount
			}
		}
		if count == 0 || read_error == .EOF {break}
	}
	if byte_count != expected_byte_count {return .Invalid_Document}
	digest_bytes: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&context_256, digest_bytes[:])
	encoded, encode_error := hex.encode(digest_bytes[:], context.temp_allocator)
	if encode_error != nil || string(encoded) != expected_digest {return .Digest_Mismatch}
	if os.sync(destination) != nil {return .Sync}
	if os.close(destination) != nil {return .Sync}
	destination_open = false
	return .None
}

library_install_object_uncoordinated :: proc(
	root: ^Library_Root,
	source_path, expected_digest: string,
	expected_byte_count: i64,
) -> Library_File_Error {
	if !library_digest_valid(expected_digest) || expected_byte_count <= 0 ||
	   expected_byte_count > LIBRARY_MAX_OBJECT_BYTES {
		return .Invalid_Document
	}
	final_path, path_ok := library_object_path(root, expected_digest, context.temp_allocator)
	if !path_ok {return .Invalid_Path}
	if os.exists(final_path) {
		digest, byte_count, hashed := library_sha256_file(final_path, context.temp_allocator)
		_, image_valid := macos_image_inspect(final_path)
		if hashed && image_valid && digest == expected_digest && byte_count == expected_byte_count {
			return .Already_Exists
		}
		return .Conflict
	}
	parent := filepath.dir(final_path)
	if !library_ensure_directory(parent) {return .Create_Directory}
	temporary_id, id_ok := library_uuid_new(context.temp_allocator)
	if !id_ok {return .Write}
	temporary_name := fmt.tprintf("%s%s", LIBRARY_PARTIAL_PREFIX, temporary_id)
	temporary_path, temporary_ok := library_join(
		[]string{parent, temporary_name},
		context.temp_allocator,
	)
	if !temporary_ok {return .Invalid_Path}
	copy_error := library_copy_verified(
		source_path,
		temporary_path,
		expected_digest,
		expected_byte_count,
	)
	if copy_error != .None {
		_ = os.remove(temporary_path)
		return copy_error
	}
	if _, image_valid := macos_image_inspect(temporary_path); !image_valid {
		_ = os.remove(temporary_path)
		return .Invalid_Document
	}
	temporary_exists := true
	defer if temporary_exists {_ = os.remove(temporary_path)}
	old_c := strings.clone_to_cstring(temporary_path, context.temp_allocator)
	new_c := strings.clone_to_cstring(final_path, context.temp_allocator)
	if renamex_np(old_c, new_c, LIBRARY_RENAME_EXCLUSIVE) != 0 {
		if os.exists(final_path) {
			digest, byte_count, hashed := library_sha256_file(final_path, context.temp_allocator)
			_, image_valid := macos_image_inspect(final_path)
			if hashed && image_valid && digest == expected_digest && byte_count == expected_byte_count {
				return .Already_Exists
			}
			return .Conflict
		}
		return .Rename
	}
	temporary_exists = false
	if !library_sync_directory(parent) {return .Sync}
	return .None
}

library_root_initialize :: proc(
	root_path: string,
	created_at_unix_ms: i64 = 0,
	allocator := context.allocator,
) -> (Library_Root, Library_File_Error) {
	creation_time := created_at_unix_ms
	if creation_time == 0 {creation_time = library_now_unix_ms()}
	if len(root_path) == 0 || creation_time <= 0 {return {}, .Invalid_Path}
	genesis_path, path_ok := library_join([]string{root_path, "library.json"}, context.temp_allocator)
	if !path_ok {return {}, .Invalid_Path}
	if os.exists(genesis_path) {return {}, .Already_Exists}
	objects_path, _ := library_join([]string{root_path, "objects", "sha256"}, context.temp_allocator)
	records_path, _ := library_join([]string{root_path, "records"}, context.temp_allocator)
	events_path, _ := library_join([]string{root_path, "events"}, context.temp_allocator)
	requests_path, _ := library_join([]string{root_path, "join-requests"}, context.temp_allocator)
	directories := [4]string{objects_path, records_path, events_path, requests_path}
	for path in directories {
		if !library_ensure_directory(path) {return {}, .Create_Directory}
	}
	library_id, library_id_ok := library_uuid_new(allocator)
	if !library_id_ok {return {}, .Write}
	device_id, device_id_ok := library_uuid_new(allocator)
	if !device_id_ok {return {}, .Write}
	genesis := Library_Genesis{
		schema_version = LIBRARY_SCHEMA_VERSION,
		library_id = library_id,
		created_at_unix_ms = creation_time,
		recovery_interval_seconds = LIBRARY_RECOVERY_INTERVAL_SECONDS,
		initial_device_id = device_id,
	}
	bytes, encoded := library_document_encode(genesis, context.temp_allocator)
	if !encoded {return {}, .Encode}
	publish_error := macos_coordinated_publish_bytes(genesis_path, bytes)
	if publish_error != .None {return {}, publish_error}
	return Library_Root{
		path = strings.clone(root_path, allocator),
		genesis = genesis,
		allocator = allocator,
	}, .None
}

library_root_open :: proc(
	root_path: string,
	allocator := context.allocator,
) -> (Library_Root, Library_File_Error) {
	genesis_path, path_ok := library_join([]string{root_path, "library.json"}, context.temp_allocator)
	if !path_ok {return {}, .Invalid_Path}
	bytes, read_error := macos_coordinated_read_bytes(genesis_path, context.temp_allocator)
	if read_error != .None {return {}, read_error}
	genesis, decode_error := library_genesis_decode(bytes, allocator)
	if decode_error != .None {return {}, .Invalid_Document}
	return Library_Root{
		path = strings.clone(root_path, allocator),
		genesis = genesis,
		allocator = allocator,
	}, .None
}

library_root_destroy :: proc(root: ^Library_Root) {
	if root == nil {return}
	if len(root.path) > 0 {delete(root.path, root.allocator)}
	if len(root.genesis.library_id) > 0 {delete(root.genesis.library_id, root.allocator)}
	if len(root.genesis.initial_device_id) > 0 {
		delete(root.genesis.initial_device_id, root.allocator)
	}
	root^ = {}
}

library_record_path :: proc(
	root: ^Library_Root,
	record: ^Library_Capture_Record,
	allocator := context.allocator,
) -> (string, bool) {
	name, name_ok := library_sequence_filename(record.device_sequence, record.capture_id, allocator)
	if !name_ok {return "", false}
	return library_join([]string{root.path, "records", record.device_id, name}, allocator)
}

library_event_path :: proc(
	root: ^Library_Root,
	event: ^Library_Event,
	allocator := context.allocator,
) -> (string, bool) {
	name, name_ok := library_sequence_filename(event.device_sequence, event.event_id, allocator)
	if !name_ok {return "", false}
	return library_join([]string{root.path, "events", event.device_id, name}, allocator)
}

library_object_path :: proc(
	root: ^Library_Root,
	digest: string,
	allocator := context.allocator,
) -> (string, bool) {
	if !library_digest_valid(digest) {return "", false}
	return library_join([]string{root.path, "objects", "sha256", digest[:2], digest}, allocator)
}

library_join_request_path :: proc(
	root: ^Library_Root,
	request: ^Library_Join_Request,
	allocator := context.allocator,
) -> (string, bool) {
	if !library_uuid_valid(request.device_id) {return "", false}
	name := fmt.aprintf("%s.json", request.device_id, allocator=allocator)
	return library_join([]string{root.path, "join-requests", name}, allocator)
}

library_publish_record_uncoordinated :: proc(
	root: ^Library_Root,
	record: ^Library_Capture_Record,
) -> Library_File_Error {
	if library_capture_validate(record, root.genesis.library_id) != .None {
		return .Invalid_Document
	}
	path, path_ok := library_record_path(root, record, context.temp_allocator)
	if !path_ok {return .Invalid_Path}
	if !library_ensure_directory(filepath.dir(path)) {return .Create_Directory}
	bytes, encoded := library_document_encode(record^, context.temp_allocator)
	if !encoded {return .Encode}
	return library_atomic_publish_bytes(path, bytes, context.temp_allocator)
}

library_publish_event_uncoordinated :: proc(
	root: ^Library_Root,
	event: ^Library_Event,
) -> Library_File_Error {
	if library_event_validate(event, root.genesis.library_id) != .None {
		return .Invalid_Document
	}
	path, path_ok := library_event_path(root, event, context.temp_allocator)
	if !path_ok {return .Invalid_Path}
	if !library_ensure_directory(filepath.dir(path)) {return .Create_Directory}
	bytes, encoded := library_document_encode(event^, context.temp_allocator)
	if !encoded {return .Encode}
	return library_atomic_publish_bytes(path, bytes, context.temp_allocator)
}

library_publish_join_request :: proc(
	root: ^Library_Root,
	request: ^Library_Join_Request,
) -> Library_File_Error {
	if library_join_request_validate(request, root.genesis.library_id) != .None {
		return .Invalid_Document
	}
	path, path_ok := library_join_request_path(root, request, context.temp_allocator)
	if !path_ok {return .Invalid_Path}
	bytes, encoded := library_document_encode(request^, context.temp_allocator)
	if !encoded {return .Encode}
	return macos_coordinated_publish_bytes(path, bytes)
}

library_scan_issue :: proc(scan: ^Library_Scan, path, reason: string) {
	path_copy, path_error := strings.clone(path, scan.allocator)
	reason_copy, reason_error := strings.clone(reason, scan.allocator)
	if path_error != nil || reason_error != nil {return}
	append(&scan.issues, Library_Scan_Issue{path=path_copy, reason=reason_copy})
}

library_scan_documents :: proc(
	root: ^Library_Root,
	directory_name: string,
	is_record: bool,
	scan: ^Library_Scan,
	allocator: runtime.Allocator,
) {
	base_path, joined := library_join([]string{root.path, directory_name}, context.temp_allocator)
	if !joined {
		library_scan_issue(scan, root.path, "invalid authoritative directory path")
		return
	}
	device_entries, directory_error := os.read_all_directory_by_path(base_path, context.temp_allocator)
	if directory_error != nil {
		library_scan_issue(scan, base_path, "authoritative directory is unavailable")
		return
	}
	for device_entry in device_entries {
		if strings.has_prefix(device_entry.name, ".") {continue}
		if device_entry.type != .Directory || !library_uuid_valid(device_entry.name) {
			library_scan_issue(scan, device_entry.fullpath, "invalid device directory")
			continue
		}
		files, files_error := os.read_all_directory_by_path(
			device_entry.fullpath,
			context.temp_allocator,
		)
		if files_error != nil {
			library_scan_issue(scan, device_entry.fullpath, "device directory is unavailable")
			continue
		}
		for file in files {
			if strings.has_prefix(file.name, LIBRARY_PARTIAL_PREFIX) {continue}
			if file.type != .Regular {
				library_scan_issue(scan, file.fullpath, "authoritative document is not a regular file")
				continue
			}
			sequence, document_id, parsed := library_sequence_filename_parse(file.name)
			if !parsed {
				library_scan_issue(scan, file.fullpath, "invalid authoritative filename")
				continue
			}
			if file.size <= 0 || file.size > LIBRARY_MAX_DOCUMENT_BYTES {
				library_scan_issue(scan, file.fullpath, "authoritative document exceeds bounds")
				continue
			}
			bytes, read_error := macos_coordinated_read_bytes(file.fullpath, context.temp_allocator)
			if read_error != .None {
				library_scan_issue(scan, file.fullpath, "authoritative document is unavailable")
				continue
			}
			if is_record {
				record, decode_error := library_capture_decode(bytes, root.genesis.library_id, allocator)
				if decode_error != .None || record.device_id != device_entry.name ||
				   record.device_sequence != sequence || record.capture_id != document_id {
					library_scan_issue(scan, file.fullpath, "capture record does not match its path")
					continue
				}
				append(&scan.records, record)
				object_path, object_path_ok := library_object_path(root, record.object_digest, context.temp_allocator)
				object_state := Library_Object_State.Missing
				if object_path_ok && os.exists(object_path) {
					ubiquity_state := macos_ubiquitous_file_state(object_path)
					if ubiquity_state == .Not_Downloaded {
						object_state = .Unavailable
					} else {
						digest, byte_count, hashed := library_sha256_file(object_path, context.temp_allocator)
						image_info, image_valid := macos_image_inspect(object_path)
						if hashed && image_valid && digest == record.object_digest &&
						   byte_count == record.byte_count &&
						   image_info.media_type == record.media_type &&
						   image_info.pixel_width == record.pixel_width &&
						   image_info.pixel_height == record.pixel_height {
							object_state = .Available
						} else {
							object_state = .Corrupt
							library_scan_issue(scan, object_path, "object digest, media, or dimensions mismatch")
						}
					}
				}
				append(&scan.record_objects, object_state)
			} else {
				event, decode_error := library_event_decode(bytes, root.genesis.library_id, allocator)
				if decode_error != .None || event.device_id != device_entry.name ||
				   event.device_sequence != sequence || event.event_id != document_id {
					library_scan_issue(scan, file.fullpath, "event does not match its path")
					continue
				}
				append(&scan.events, event)
			}
		}
	}
}

library_scan_objects :: proc(
	root: ^Library_Root,
	scan: ^Library_Scan,
) {
	base_path, joined := library_join(
		[]string{root.path, "objects", "sha256"},
		context.temp_allocator,
	)
	if !joined {return}
	shards, shard_error := os.read_all_directory_by_path(base_path, context.temp_allocator)
	if shard_error != nil {return}
	for shard in shards {
		if strings.has_prefix(shard.name, ".") {continue}
		if shard.type != .Directory || len(shard.name) != 2 ||
		   !library_lower_hex_valid(shard.name) {
			library_scan_issue(scan, shard.fullpath, "invalid object shard")
			continue
		}
		files, files_error := os.read_all_directory_by_path(
			shard.fullpath,
			context.temp_allocator,
		)
		if files_error != nil {
			library_scan_issue(scan, shard.fullpath, "object shard is unavailable")
			continue
		}
		for file in files {
			if strings.has_prefix(file.name, LIBRARY_PARTIAL_PREFIX) {continue}
			if file.type != .Regular || !library_digest_valid(file.name) ||
			   file.name[:2] != shard.name || file.size <= 0 ||
			   file.size > LIBRARY_MAX_OBJECT_BYTES {
				library_scan_issue(scan, file.fullpath, "invalid object path or bounds")
				continue
			}
			if !slice.contains(scan.object_digests[:], file.name) {
				append(&scan.object_digests, strings.clone(file.name, scan.allocator))
			}
		}
	}
	for digest in scan.object_digests {
		referenced := false
		for record in scan.records {
			if record.object_digest == digest {referenced = true; break}
		}
		if !referenced {
			append(&scan.orphan_digests, strings.clone(digest, scan.allocator))
		}
	}
	slice.sort(scan.object_digests[:])
	slice.sort(scan.orphan_digests[:])
}

library_root_scan :: proc(
	root: ^Library_Root,
	allocator := context.allocator,
) -> Library_Scan {
	scan := Library_Scan{
		records = make([dynamic]Library_Capture_Record, allocator),
		record_objects = make([dynamic]Library_Object_State, allocator),
		events = make([dynamic]Library_Event, allocator),
		join_requests = make([dynamic]Library_Join_Request, allocator),
		object_digests = make([dynamic]string, allocator),
		orphan_digests = make([dynamic]string, allocator),
		issues = make([dynamic]Library_Scan_Issue, allocator),
		allocator = allocator,
	}
	library_scan_documents(root, "records", true, &scan, allocator)
	library_scan_documents(root, "events", false, &scan, allocator)
	library_scan_objects(root, &scan)
	requests_path, joined := library_join([]string{root.path, "join-requests"}, context.temp_allocator)
	if !joined {
		library_scan_issue(&scan, root.path, "invalid join-request directory path")
		return scan
	}
	request_files, request_error := os.read_all_directory_by_path(requests_path, context.temp_allocator)
	if request_error != nil {
		library_scan_issue(&scan, requests_path, "join-request directory is unavailable")
		return scan
	}
	for file in request_files {
		if strings.has_prefix(file.name, LIBRARY_PARTIAL_PREFIX) {continue}
		if file.type != .Regular || len(file.name) != 41 || !strings.has_suffix(file.name, ".json") {
			library_scan_issue(&scan, file.fullpath, "invalid join-request file")
			continue
		}
		device_id := file.name[:36]
		if !library_uuid_valid(device_id) || file.size <= 0 || file.size > LIBRARY_MAX_DOCUMENT_BYTES {
			library_scan_issue(&scan, file.fullpath, "invalid join-request path or bounds")
			continue
		}
		bytes, read_error := macos_coordinated_read_bytes(file.fullpath, context.temp_allocator)
		if read_error != .None {
			library_scan_issue(&scan, file.fullpath, "join request is unavailable")
			continue
		}
		request, decode_error := library_join_request_decode(bytes, root.genesis.library_id, allocator)
		if decode_error != .None || request.device_id != device_id {
			library_scan_issue(&scan, file.fullpath, "join request does not match its path")
			continue
		}
		append(&scan.join_requests, request)
	}
	return scan
}
