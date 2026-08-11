package main

import "core:os"
import "core:path/filepath"
import "base:runtime"

HW_IMAGE_LIBRARY_BUNDLE_ID :: "com.halwayland.hw-imagelibrary"
HW_IMAGE_LIBRARY_UBIQUITY_CONTAINER :: "iCloud.com.halwayland.hw-imagelibrary"
HW_IMAGE_LIBRARY_NATIVE_HOST :: "com.halwayland.hw_imagelibrary"
HW_IMAGE_LIBRARY_SUPPORT_OVERRIDE :: "HW_IMAGE_LIBRARY_APP_SUPPORT_DIR"

MACOS_APPLICATION_SUPPORT_DIRECTORY :: uint(14)
MACOS_USER_DOMAIN_MASK :: uint(1)
MACOS_BOOKMARK_CREATION_WITH_SECURITY_SCOPE :: uint(1 << 11)
MACOS_BOOKMARK_RESOLUTION_WITH_SECURITY_SCOPE :: uint(1 << 10)
MACOS_MODAL_RESPONSE_OK :: int(1)

MacOS_Path_Error :: enum {
	None,
	Objective_C,
	Unavailable,
	Must_Run_Off_Main_Thread,
	Invalid,
	Bookmark,
	Stale,
	Access,
	Cancelled,
}

MacOS_Bookmark_Resolution :: struct {
	url:            Id,
	path:           string,
	stale:          bool,
	access_started: bool,
	allocator:      runtime.Allocator,
}

macos_application_support_directory :: proc(
	allocator := context.allocator,
) -> (string, MacOS_Path_Error) {
	if override, found := os.lookup_env(HW_IMAGE_LIBRARY_SUPPORT_OVERRIDE, allocator); found {
		if len(override) == 0 {return "", .Invalid}
		if !library_ensure_directory(override) {return "", .Unavailable}
		return override, .None
	}
	if !objc_initialize() {return "", .Objective_C}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return "", .Objective_C}
	defer macos_autorelease_pool_end(pool)
	manager := msg_id(objc_getClass("NSFileManager"), sel_registerName("defaultManager"))
	urls := msg_id_u_u(
		manager,
		sel_registerName("URLsForDirectory:inDomains:"),
		MACOS_APPLICATION_SUPPORT_DIRECTORY,
		MACOS_USER_DOMAIN_MASK,
	)
	base_url := msg_id(urls, sel_registerName("firstObject"))
	if base_url == nil {return "", .Unavailable}
	app_url := msg_id_id_bool(
		base_url,
		sel_registerName("URLByAppendingPathComponent:isDirectory:"),
		nsstring("hw_imageLibrary"),
		true,
	)
	path, path_ok := nsurl_path(app_url, allocator)
	if !path_ok || !library_ensure_directory(path) {return "", .Unavailable}
	return path, .None
}

macos_default_icloud_library_root :: proc(
	allocator := context.allocator,
) -> (string, MacOS_Path_Error) {
	if !objc_initialize() {return "", .Objective_C}
	if msg_bool(objc_getClass("NSThread"), sel_registerName("isMainThread")) {
		return "", .Must_Run_Off_Main_Thread
	}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return "", .Objective_C}
	defer macos_autorelease_pool_end(pool)
	manager := msg_id(objc_getClass("NSFileManager"), sel_registerName("defaultManager"))
	if msg_id(manager, sel_registerName("ubiquityIdentityToken")) == nil {
		return "", .Unavailable
	}
	container_url := msg_id_id(
		manager,
		sel_registerName("URLForUbiquityContainerIdentifier:"),
		nsstring(HW_IMAGE_LIBRARY_UBIQUITY_CONTAINER),
	)
	if container_url == nil {return "", .Unavailable}
	documents_url := msg_id_id_bool(
		container_url,
		sel_registerName("URLByAppendingPathComponent:isDirectory:"),
		nsstring("Documents"),
		true,
	)
	root_url := msg_id_id_bool(
		documents_url,
		sel_registerName("URLByAppendingPathComponent:isDirectory:"),
		nsstring("hw_imageLibrary"),
		true,
	)
	path, path_ok := nsurl_path(root_url, allocator)
	if !path_ok {return "", .Unavailable}
	return path, .None
}

macos_bookmark_create :: proc(
	path: string,
	allocator := context.allocator,
) -> (string, MacOS_Path_Error) {
	if !objc_initialize() || len(path) == 0 {return "", .Invalid}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return "", .Objective_C}
	defer macos_autorelease_pool_end(pool)
	url := nsurl_file(path, true)
	error: Id
	p := transmute(proc "c" (Id, Sel, uint, Id, Id, ^Id) -> Id)objc_send_address
	data := p(
		url,
		sel_registerName("bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:"),
		MACOS_BOOKMARK_CREATION_WITH_SECURITY_SCOPE,
		nil,
		nil,
		&error,
	)
	if data == nil || error != nil {return "", .Bookmark}
	encoded := msg_id_u(data, sel_registerName("base64EncodedStringWithOptions:"), 0)
	bookmark, bookmark_ok := nsstring_to_string(encoded, allocator)
	if !bookmark_ok || len(bookmark) == 0 {return "", .Bookmark}
	return bookmark, .None
}

macos_bookmark_resolve :: proc(
	bookmark_base64: string,
	allocator := context.allocator,
) -> (MacOS_Bookmark_Resolution, MacOS_Path_Error) {
	if !objc_initialize() || len(bookmark_base64) == 0 {return {}, .Invalid}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return {}, .Objective_C}
	defer macos_autorelease_pool_end(pool)
	data_alloc := msg_id(objc_getClass("NSData"), sel_registerName("alloc"))
	if data_alloc == nil {return {}, .Bookmark}
	p_data := transmute(proc "c" (Id, Sel, Id, uint) -> Id)objc_send_address
	data := p_data(
		data_alloc,
		sel_registerName("initWithBase64EncodedString:options:"),
		nsstring(bookmark_base64),
		0,
	)
	if data == nil {return {}, .Bookmark}
	defer msg_void(data, sel_registerName("release"))
	stale := false
	error: Id
	url_alloc := msg_id(objc_getClass("NSURL"), sel_registerName("alloc"))
	p_url := transmute(proc "c" (Id, Sel, Id, uint, Id, ^bool, ^Id) -> Id)objc_send_address
	url := p_url(
		url_alloc,
		sel_registerName("initByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:"),
		data,
		MACOS_BOOKMARK_RESOLUTION_WITH_SECURITY_SCOPE,
		nil,
		&stale,
		&error,
	)
	if url == nil || error != nil {
		return {}, .Bookmark
	}
	path, path_ok := nsurl_path(url, allocator)
	if !path_ok {
		msg_void(url, sel_registerName("release"))
		return {}, .Invalid
	}
	access_started := msg_bool(url, sel_registerName("startAccessingSecurityScopedResource"))
	if !access_started {
		msg_void(url, sel_registerName("release"))
		return {}, .Access
	}
	return {
		url = url,
		path = path,
		stale = stale,
		access_started = true,
		allocator = allocator,
	}, stale ? .Stale : .None
}

macos_bookmark_resolution_close :: proc(value: ^MacOS_Bookmark_Resolution) {
	if value.url != nil {
		if value.access_started {
			msg_void(value.url, sel_registerName("stopAccessingSecurityScopedResource"))
		}
		msg_void(value.url, sel_registerName("release"))
	}
	if len(value.path) > 0 {delete(value.path, value.allocator)}
	value^ = {}
}

macos_choose_library_root :: proc(
	allocator := context.allocator,
) -> (string, string, MacOS_Path_Error) {
	if !objc_initialize() {return "", "", .Objective_C}
	panel := msg_id(objc_getClass("NSOpenPanel"), sel_registerName("openPanel"))
	if panel == nil {return "", "", .Unavailable}
	msg_void_bool(panel, sel_registerName("setCanChooseFiles:"), false)
	msg_void_bool(panel, sel_registerName("setCanChooseDirectories:"), true)
	msg_void_bool(panel, sel_registerName("setAllowsMultipleSelection:"), false)
	msg_void_bool(panel, sel_registerName("setCanCreateDirectories:"), true)
	msg_void_id(panel, sel_registerName("setPrompt:"), nsstring("Use Library Folder"))
	if msg_int(panel, sel_registerName("runModal")) != MACOS_MODAL_RESPONSE_OK {
		return "", "", .Cancelled
	}
	url := msg_id(panel, sel_registerName("URL"))
	path, path_ok := nsurl_path(url, allocator)
	if !path_ok {return "", "", .Invalid}
	bookmark, bookmark_error := macos_bookmark_create(path, allocator)
	if bookmark_error != .None {return "", "", bookmark_error}
	return path, bookmark, .None
}

macos_choose_export_path :: proc(
	suggested_name: string,
	allocator := context.allocator,
) -> (string, MacOS_Path_Error) {
	if !objc_initialize() {return "", .Objective_C}
	panel := msg_id(objc_getClass("NSSavePanel"), sel_registerName("savePanel"))
	if panel == nil {return "", .Unavailable}
	msg_void_bool(panel, sel_registerName("setCanCreateDirectories:"), true)
	msg_void_id(panel, sel_registerName("setPrompt:"), nsstring("Export Original"))
	if len(suggested_name) > 0 {
		msg_void_id(
			panel,
			sel_registerName("setNameFieldStringValue:"),
			nsstring(suggested_name),
		)
	}
	if msg_int(panel, sel_registerName("runModal")) != MACOS_MODAL_RESPONSE_OK {
		return "", .Cancelled
	}
	path, path_ok := nsurl_path(msg_id(panel, sel_registerName("URL")), allocator)
	if !path_ok {return "", .Invalid}
	return path, .None
}

macos_choose_library_move_destination :: proc(
	allocator := context.allocator,
) -> (string, MacOS_Path_Error) {
	if !objc_initialize() {return "", .Objective_C}
	panel := msg_id(objc_getClass("NSSavePanel"), sel_registerName("savePanel"))
	if panel == nil {return "", .Unavailable}
	msg_void_bool(panel, sel_registerName("setCanCreateDirectories:"), true)
	msg_void_id(panel, sel_registerName("setPrompt:"), nsstring("Move Library"))
	msg_void_id(
		panel,
		sel_registerName("setNameFieldStringValue:"),
		nsstring("hw_imageLibrary"),
	)
	if msg_int(panel, sel_registerName("runModal")) != MACOS_MODAL_RESPONSE_OK {
		return "", .Cancelled
	}
	path, path_ok := nsurl_path(msg_id(panel, sel_registerName("URL")), allocator)
	if !path_ok {return "", .Invalid}
	return path, .None
}

macos_device_name :: proc(allocator := context.allocator) -> string {
	if !objc_initialize() {return "Mac"}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return "Mac"}
	defer macos_autorelease_pool_end(pool)
	host := msg_id(objc_getClass("NSHost"), sel_registerName("currentHost"))
	name := msg_id(host, sel_registerName("localizedName"))
	value, converted := nsstring_to_string(name, allocator)
	if !converted || len(value) == 0 {return "Mac"}
	return value
}

macos_open_url :: proc(url: string) -> bool {
	if !library_http_url_valid(url) || !objc_initialize() {return false}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return false}
	defer macos_autorelease_pool_end(pool)
	url_value := msg_id_id(
		objc_getClass("NSURL"),
		sel_registerName("URLWithString:"),
		nsstring(url),
	)
	if url_value == nil {return false}
	workspace := msg_id(objc_getClass("NSWorkspace"), sel_registerName("sharedWorkspace"))
	return msg_bool_id(workspace, sel_registerName("openURL:"), url_value)
}

macos_clipboard_string :: proc(
	allocator := context.allocator,
) -> (string, bool) {
	if !objc_initialize() {return "", false}
	pasteboard := msg_id(objc_getClass("NSPasteboard"), sel_registerName("generalPasteboard"))
	if pasteboard == nil {return "", false}
	value := msg_id_id(
		pasteboard,
		sel_registerName("stringForType:"),
		nsstring("public.utf8-plain-text"),
	)
	return nsstring_to_string(value, allocator)
}
