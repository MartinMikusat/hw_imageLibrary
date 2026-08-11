package main

import "core:dynlib"
import "core:sync"

MacOS_Ubiquitous_File_State :: enum {
	Local,
	Downloaded,
	Not_Downloaded,
	Unknown,
}

macos_foundation_symbols_mutex: sync.Mutex
macos_foundation_library: dynlib.Library
macos_foundation_library_loaded: bool

macos_foundation_global_id :: proc(name: string) -> Id {
	sync.mutex_lock(&macos_foundation_symbols_mutex)
	defer sync.mutex_unlock(&macos_foundation_symbols_mutex)
	if !macos_foundation_library_loaded {
		library, loaded := dynlib.load_library(
			"/System/Library/Frameworks/Foundation.framework/Foundation",
		)
		if !loaded {return nil}
		macos_foundation_library = library
		macos_foundation_library_loaded = true
	}
	address, found := dynlib.symbol_address(macos_foundation_library, name)
	if !found || address == nil {return nil}
	return (cast(^Id)address)^
}

macos_ubiquitous_file_state :: proc(path: string) -> MacOS_Ubiquitous_File_State {
	if !objc_initialize() || len(path) == 0 {return .Unknown}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return .Unknown}
	defer macos_autorelease_pool_end(pool)
	url := nsurl_file(path)
	manager := msg_id(objc_getClass("NSFileManager"), sel_registerName("defaultManager"))
	if !msg_bool_id(manager, sel_registerName("isUbiquitousItemAtURL:"), url) {
		return .Local
	}
	key := macos_foundation_global_id("NSURLUbiquitousItemDownloadingStatusKey")
	if key == nil {return .Unknown}
	value: Id
	error: Id
	p := transmute(proc "c" (Id, Sel, ^Id, Id, ^Id) -> bool)objc_send_address
	if !p(url, sel_registerName("getResourceValue:forKey:error:"), &value, key, &error) ||
	   value == nil || error != nil {
		return .Unknown
	}
	not_downloaded := macos_foundation_global_id(
		"NSURLUbiquitousItemDownloadingStatusNotDownloaded",
	)
	downloaded := macos_foundation_global_id(
		"NSURLUbiquitousItemDownloadingStatusDownloaded",
	)
	current := macos_foundation_global_id(
		"NSURLUbiquitousItemDownloadingStatusCurrent",
	)
	if not_downloaded != nil && msg_bool_id(
		value,
		sel_registerName("isEqualToString:"),
		not_downloaded,
	) {
		return .Not_Downloaded
	}
	if (downloaded != nil && msg_bool_id(
		value,
		sel_registerName("isEqualToString:"),
		downloaded,
	)) || (current != nil && msg_bool_id(
		value,
		sel_registerName("isEqualToString:"),
		current,
	)) {
		return .Downloaded
	}
	return .Unknown
}

macos_start_downloading_ubiquitous_file :: proc(path: string) -> bool {
	if !objc_initialize() || len(path) == 0 {return false}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return false}
	defer macos_autorelease_pool_end(pool)
	manager := msg_id(objc_getClass("NSFileManager"), sel_registerName("defaultManager"))
	url := nsurl_file(path)
	if !msg_bool_id(manager, sel_registerName("isUbiquitousItemAtURL:"), url) {
		return true
	}
	error: Id
	p := transmute(proc "c" (Id, Sel, Id, ^Id) -> bool)objc_send_address
	return p(
		manager,
		sel_registerName("startDownloadingUbiquitousItemAtURL:error:"),
		url,
		&error,
	) && error == nil
}
