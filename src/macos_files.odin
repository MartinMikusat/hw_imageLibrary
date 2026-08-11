package main

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:path/filepath"

MacOS_Coordinated_Operation :: proc(user_context: rawptr, coordinated_path: string) -> Library_File_Error
MacOS_Coordinated_Move_Operation :: proc(
	user_context: rawptr,
	coordinated_source_path, coordinated_destination_path: string,
) -> Library_File_Error

MacOS_Block_Descriptor :: struct {
	reserved: uint,
	size:     uint,
}

MacOS_URL_Accessor_Block :: struct {
	isa:        ^intrinsics.objc_class,
	flags:      u32,
	reserved:   u32,
	invoke:     proc "c" (block: ^MacOS_URL_Accessor_Block, url: Id),
	descriptor: ^MacOS_Block_Descriptor,
	operation:  MacOS_Coordinated_Operation,
	user_context: rawptr,
	result:     Library_File_Error,
	invoked:    bool,
}

MacOS_Two_URL_Accessor_Block :: struct {
	isa:        ^intrinsics.objc_class,
	flags:      u32,
	reserved:   u32,
	invoke:     proc "c" (block: ^MacOS_Two_URL_Accessor_Block, source_url, destination_url: Id),
	descriptor: ^MacOS_Block_Descriptor,
	operation:  MacOS_Coordinated_Move_Operation,
	user_context: rawptr,
	result:     Library_File_Error,
	invoked:    bool,
}

foreign import macos_blocks "system:System"
foreign macos_blocks {
	_NSConcreteStackBlock: intrinsics.objc_class
}

MACOS_FILE_WRITING_FOR_DELETING :: uint(1 << 0)
MACOS_FILE_WRITING_FOR_MOVING :: uint(1 << 1)
MACOS_FILE_WRITING_FOR_REPLACING :: uint(1 << 3)

macos_url_accessor_invoke :: proc "c" (block: ^MacOS_URL_Accessor_Block, url: Id) {
	context = runtime.default_context()
	block.invoked = true
	path, path_ok := nsurl_path(url, context.temp_allocator)
	if !path_ok {
		block.result = .Invalid_Path
		return
	}
	block.result = block.operation(block.user_context, path)
}

macos_two_url_accessor_invoke :: proc "c" (
	block: ^MacOS_Two_URL_Accessor_Block,
	source_url, destination_url: Id,
) {
	context = runtime.default_context()
	block.invoked = true
	source_path, source_ok := nsurl_path(source_url, context.temp_allocator)
	destination_path, destination_ok := nsurl_path(destination_url, context.temp_allocator)
	if !source_ok || !destination_ok {
		block.result = .Invalid_Path
		return
	}
	block.result = block.operation(
		block.user_context,
		source_path,
		destination_path,
	)
}

macos_coordinate_write :: proc(
	path: string,
	options: uint,
	operation: MacOS_Coordinated_Operation,
	operation_context: rawptr,
) -> Library_File_Error {
	if !objc_initialize() || len(path) == 0 || operation == nil {return .Invalid_Path}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return .Open}
	defer macos_autorelease_pool_end(pool)
	coordinator := msg_id_id(
		msg_id(objc_getClass("NSFileCoordinator"), sel_registerName("alloc")),
		sel_registerName("initWithFilePresenter:"),
		nil,
	)
	if coordinator == nil {return .Open}
	defer msg_void(coordinator, sel_registerName("release"))
	descriptor := MacOS_Block_Descriptor{size=size_of(MacOS_URL_Accessor_Block)}
	block := MacOS_URL_Accessor_Block{
		isa = &_NSConcreteStackBlock,
		invoke = macos_url_accessor_invoke,
		descriptor = &descriptor,
		operation = operation,
		user_context = operation_context,
		result = .Write,
	}
	error: Id
	p := transmute(proc "c" (
		Id,
		Sel,
		Id,
		uint,
		^Id,
		^MacOS_URL_Accessor_Block,
	))objc_send_address
	p(
		coordinator,
		sel_registerName("coordinateWritingItemAtURL:options:error:byAccessor:"),
		nsurl_file(path),
		options,
		&error,
		&block,
	)
	if error != nil || !block.invoked {return .Write}
	return block.result
}

macos_coordinate_read :: proc(
	path: string,
	operation: MacOS_Coordinated_Operation,
	operation_context: rawptr,
) -> Library_File_Error {
	if !objc_initialize() || len(path) == 0 || operation == nil {return .Invalid_Path}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return .Open}
	defer macos_autorelease_pool_end(pool)
	coordinator := msg_id_id(
		msg_id(objc_getClass("NSFileCoordinator"), sel_registerName("alloc")),
		sel_registerName("initWithFilePresenter:"),
		nil,
	)
	if coordinator == nil {return .Open}
	defer msg_void(coordinator, sel_registerName("release"))
	descriptor := MacOS_Block_Descriptor{size=size_of(MacOS_URL_Accessor_Block)}
	block := MacOS_URL_Accessor_Block{
		isa = &_NSConcreteStackBlock,
		invoke = macos_url_accessor_invoke,
		descriptor = &descriptor,
		operation = operation,
		user_context = operation_context,
		result = .Read,
	}
	error: Id
	p := transmute(proc "c" (
		Id,
		Sel,
		Id,
		uint,
		^Id,
		^MacOS_URL_Accessor_Block,
	))objc_send_address
	p(
		coordinator,
		sel_registerName("coordinateReadingItemAtURL:options:error:byAccessor:"),
		nsurl_file(path),
		0,
		&error,
		&block,
	)
	if error != nil || !block.invoked {return .Read}
	return block.result
}

macos_coordinate_move :: proc(
	source_path, destination_path: string,
	operation: MacOS_Coordinated_Move_Operation,
	operation_context: rawptr,
) -> Library_File_Error {
	if !objc_initialize() || len(source_path) == 0 || len(destination_path) == 0 ||
	   operation == nil {
		return .Invalid_Path
	}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return .Open}
	defer macos_autorelease_pool_end(pool)
	coordinator := msg_id_id(
		msg_id(objc_getClass("NSFileCoordinator"), sel_registerName("alloc")),
		sel_registerName("initWithFilePresenter:"),
		nil,
	)
	if coordinator == nil {return .Open}
	defer msg_void(coordinator, sel_registerName("release"))
	descriptor := MacOS_Block_Descriptor{size=size_of(MacOS_Two_URL_Accessor_Block)}
	block := MacOS_Two_URL_Accessor_Block{
		isa = &_NSConcreteStackBlock,
		invoke = macos_two_url_accessor_invoke,
		descriptor = &descriptor,
		operation = operation,
		user_context = operation_context,
		result = .Write,
	}
	error: Id
	p := transmute(proc "c" (
		Id, Sel, Id, uint, Id, uint, ^Id, ^MacOS_Two_URL_Accessor_Block,
	))objc_send_address
	p(
		coordinator,
		sel_registerName("coordinateWritingItemAtURL:options:writingItemAtURL:options:error:byAccessor:"),
		nsurl_file(source_path, true),
		MACOS_FILE_WRITING_FOR_MOVING,
		nsurl_file(destination_path, true),
		MACOS_FILE_WRITING_FOR_REPLACING,
		&error,
		&block,
	)
	if error != nil || !block.invoked {return .Write}
	return block.result
}

macos_move_directory_operation :: proc(
	user_context: rawptr,
	source_path, destination_path: string,
) -> Library_File_Error {
	if !os.exists(source_path) || os.exists(destination_path) {return .Already_Exists}
	if !library_ensure_directory(filepath.dir(destination_path)) {return .Create_Directory}
	manager := msg_id(objc_getClass("NSFileManager"), sel_registerName("defaultManager"))
	error: Id
	p := transmute(proc "c" (Id, Sel, Id, Id, ^Id) -> bool)objc_send_address
	if !p(
		manager,
		sel_registerName("moveItemAtURL:toURL:error:"),
		nsurl_file(source_path, true),
		nsurl_file(destination_path, true),
		&error,
	) || error != nil {
		return .Write
	}
	if !library_sync_directory(filepath.dir(source_path)) ||
	   !library_sync_directory(filepath.dir(destination_path)) {
		return .Sync
	}
	return .None
}

macos_coordinated_move_directory :: proc(
	source_path, destination_path: string,
) -> Library_File_Error {
	return macos_coordinate_move(
		source_path,
		destination_path,
		macos_move_directory_operation,
		nil,
	)
}

MacOS_Publish_Bytes_Context :: struct {
	bytes: []u8,
}

macos_publish_bytes_operation :: proc(
	user_context: rawptr,
	coordinated_path: string,
) -> Library_File_Error {
	value := cast(^MacOS_Publish_Bytes_Context)user_context
	return library_atomic_publish_bytes(coordinated_path, value.bytes, context.temp_allocator)
}

macos_coordinated_publish_bytes :: proc(path: string, bytes: []u8) -> Library_File_Error {
	operation_context := MacOS_Publish_Bytes_Context{bytes=bytes}
	return macos_coordinate_write(
		path,
		MACOS_FILE_WRITING_FOR_REPLACING,
		macos_publish_bytes_operation,
		&operation_context,
	)
}

MacOS_Read_Bytes_Context :: struct {
	allocator: runtime.Allocator,
	bytes:     []u8,
}

macos_read_bytes_operation :: proc(
	user_context: rawptr,
	coordinated_path: string,
) -> Library_File_Error {
	value := cast(^MacOS_Read_Bytes_Context)user_context
	bytes, error := os.read_entire_file(coordinated_path, value.allocator)
	if error != nil {return error == .Not_Exist ? .Not_Found : .Read}
	value.bytes = bytes
	return .None
}

macos_coordinated_read_bytes :: proc(
	path: string,
	allocator := context.allocator,
) -> ([]u8, Library_File_Error) {
	read_context := MacOS_Read_Bytes_Context{allocator=allocator}
	error := macos_coordinate_read(path, macos_read_bytes_operation, &read_context)
	return read_context.bytes, error
}

macos_remove_operation :: proc(
	user_context: rawptr,
	coordinated_path: string,
) -> Library_File_Error {
	if !os.exists(coordinated_path) {return .None}
	if os.remove(coordinated_path) != nil {return .Write}
	if !library_sync_directory(filepath.dir(coordinated_path)) {return .Sync}
	return .None
}

macos_coordinated_remove :: proc(path: string) -> Library_File_Error {
	if !os.exists(path) {return .None}
	return macos_coordinate_write(
		path,
		MACOS_FILE_WRITING_FOR_DELETING,
		macos_remove_operation,
		nil,
	)
}

MacOS_Export_Context :: struct {
	destination_path: string,
	expected_digest: string,
	expected_byte_count: i64,
}

macos_export_operation :: proc(
	user_context: rawptr,
	coordinated_source_path: string,
) -> Library_File_Error {
	value := cast(^MacOS_Export_Context)user_context
	if os.exists(value.destination_path) {return .Already_Exists}
	if !library_ensure_directory(filepath.dir(value.destination_path)) {
		return .Create_Directory
	}
	copy_error := library_copy_verified(
		coordinated_source_path,
		value.destination_path,
		value.expected_digest,
		value.expected_byte_count,
	)
	if copy_error != .None {return copy_error}
	if !library_sync_directory(filepath.dir(value.destination_path)) {return .Sync}
	return .None
}

macos_coordinated_export :: proc(
	source_path, destination_path, expected_digest: string,
	expected_byte_count: i64,
) -> Library_File_Error {
	if len(destination_path) == 0 || !filepath.is_abs(destination_path) {
		return .Invalid_Path
	}
	value := MacOS_Export_Context{
		destination_path = destination_path,
		expected_digest = expected_digest,
		expected_byte_count = expected_byte_count,
	}
	return macos_coordinate_read(source_path, macos_export_operation, &value)
}

MacOS_Install_Object_Context :: struct {
	root: ^Library_Root,
	source_path: string,
	expected_digest: string,
	expected_byte_count: i64,
}

macos_install_object_operation :: proc(
	user_context: rawptr,
	coordinated_path: string,
) -> Library_File_Error {
	value := cast(^MacOS_Install_Object_Context)user_context
	return library_install_object_uncoordinated(
		value.root,
		value.source_path,
		value.expected_digest,
		value.expected_byte_count,
	)
}

library_install_object :: proc(
	root: ^Library_Root,
	source_path, expected_digest: string,
	expected_byte_count: i64,
) -> Library_File_Error {
	final_path, path_ok := library_object_path(root, expected_digest, context.temp_allocator)
	if !path_ok {return .Invalid_Path}
	value := MacOS_Install_Object_Context{
		root = root,
		source_path = source_path,
		expected_digest = expected_digest,
		expected_byte_count = expected_byte_count,
	}
	return macos_coordinate_write(
		final_path,
		MACOS_FILE_WRITING_FOR_REPLACING,
		macos_install_object_operation,
		&value,
	)
}

library_publish_record :: proc(
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
	return macos_coordinated_publish_bytes(path, bytes)
}

library_publish_event :: proc(
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
	return macos_coordinated_publish_bytes(path, bytes)
}
