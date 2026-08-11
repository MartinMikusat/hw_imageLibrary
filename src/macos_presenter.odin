package main

import "core:sync"
import "base:runtime"

MACOS_FILE_PRESENTER_CLASS :: "HWImageLibraryFilePresenter"
MACOS_FILE_PRESENTER_STATE_IVAR :: "odinState"

MacOS_File_Presenter :: struct {
	presenter:  Id,
	presented_url: Id,
	queue:      Id,
	registered: bool,
}

macos_file_presenter_class: Id
macos_file_presenter_class_mutex: sync.Mutex

macos_file_presenter_state :: proc(object: Id) -> ^Library_Service_State {
	ivar := class_getInstanceVariable(
		macos_file_presenter_class,
		MACOS_FILE_PRESENTER_STATE_IVAR,
	)
	if ivar == nil {return nil}
	return cast(^Library_Service_State)object_getIvar(object, ivar)
}

macos_presented_item_url :: proc "c" (object: Id, command: Sel) -> Id {
	context = runtime.default_context()
	state := macos_file_presenter_state(object)
	if state == nil {return nil}
	return state.file_presenter.presented_url
}

macos_presented_item_queue :: proc "c" (object: Id, command: Sel) -> Id {
	context = runtime.default_context()
	state := macos_file_presenter_state(object)
	if state == nil {return nil}
	return state.file_presenter.queue
}

macos_presenter_request_rescan :: proc(object: Id) {
	context = runtime.default_context()
	state := macos_file_presenter_state(object)
	if state != nil {library_service_request_rescan(state)}
}

macos_presented_item_did_change :: proc "c" (object: Id, command: Sel) {
	context = runtime.default_context()
	macos_presenter_request_rescan(object)
}

macos_presented_subitem_did_appear :: proc "c" (object: Id, command: Sel, url: Id) {
	context = runtime.default_context()
	macos_presenter_request_rescan(object)
}

macos_presented_subitem_did_change :: proc "c" (object: Id, command: Sel, url: Id) {
	context = runtime.default_context()
	macos_presenter_request_rescan(object)
}

macos_presented_subitem_did_move :: proc "c" (
	object: Id,
	command: Sel,
	old_url, new_url: Id,
) {
	context = runtime.default_context()
	macos_presenter_request_rescan(object)
}

macos_file_presenter_class_initialize :: proc() -> bool {
	sync.mutex_lock(&macos_file_presenter_class_mutex)
	defer sync.mutex_unlock(&macos_file_presenter_class_mutex)
	if macos_file_presenter_class != nil {return true}
	if !objc_initialize() {return false}
	class := objc_allocateClassPair(
		objc_getClass("NSObject"),
		MACOS_FILE_PRESENTER_CLASS,
		0,
	)
	if class == nil {return false}
	if !class_addIvar(
		class,
		MACOS_FILE_PRESENTER_STATE_IVAR,
		size_of(rawptr),
		3,
		"^v",
	) ||
	   !class_addMethod(
		class,
		sel_registerName("presentedItemURL"),
		cast(rawptr)macos_presented_item_url,
		"@@:",
	) ||
	   !class_addMethod(
		class,
		sel_registerName("presentedItemOperationQueue"),
		cast(rawptr)macos_presented_item_queue,
		"@@:",
	) ||
	   !class_addMethod(
		class,
		sel_registerName("presentedItemDidChange"),
		cast(rawptr)macos_presented_item_did_change,
		"v@:",
	) ||
	   !class_addMethod(
		class,
		sel_registerName("presentedSubitemDidAppearAtURL:"),
		cast(rawptr)macos_presented_subitem_did_appear,
		"v@:@",
	) ||
	   !class_addMethod(
		class,
		sel_registerName("presentedSubitemDidChangeAtURL:"),
		cast(rawptr)macos_presented_subitem_did_change,
		"v@:@",
	) ||
	   !class_addMethod(
		class,
		sel_registerName("presentedSubitemAtURL:didMoveToURL:"),
		cast(rawptr)macos_presented_subitem_did_move,
		"v@:@@",
	) {
		return false
	}
	protocol := objc_getProtocol("NSFilePresenter")
	if protocol == nil || !class_addProtocol(class, protocol) {return false}
	objc_registerClassPair(class)
	macos_file_presenter_class = class
	return true
}

macos_file_presenter_start :: proc(
	value: ^MacOS_File_Presenter,
	state: ^Library_Service_State,
) -> bool {
	if value == nil || state == nil || !macos_file_presenter_class_initialize() {
		return false
	}
	presenter := msg_id(
		msg_id(macos_file_presenter_class, sel_registerName("alloc")),
		sel_registerName("init"),
	)
	if presenter == nil {return false}
	started := false
	defer if !started {msg_void(presenter, sel_registerName("release"))}
	ivar := class_getInstanceVariable(
		macos_file_presenter_class,
		MACOS_FILE_PRESENTER_STATE_IVAR,
	)
	if ivar == nil {return false}
	object_setIvar(presenter, ivar, cast(Id)state)
	presented_url := msg_id(nsurl_file(state.root.path, true), sel_registerName("retain"))
	queue := msg_id(objc_getClass("NSOperationQueue"), sel_registerName("new"))
	if presented_url == nil || queue == nil {
		if presented_url != nil {msg_void(presented_url, sel_registerName("release"))}
		if queue != nil {msg_void(queue, sel_registerName("release"))}
		return false
	}
	msg_void_int(queue, sel_registerName("setMaxConcurrentOperationCount:"), 1)
	value.presenter = presenter
	value.presented_url = presented_url
	value.queue = queue
	msg_void_id(
		objc_getClass("NSFileCoordinator"),
		sel_registerName("addFilePresenter:"),
		presenter,
	)
	value.registered = true
	started = true
	return true
}

macos_file_presenter_stop :: proc(value: ^MacOS_File_Presenter) {
	if value == nil {return}
	if value.registered {
		msg_void_id(
			objc_getClass("NSFileCoordinator"),
			sel_registerName("removeFilePresenter:"),
			value.presenter,
		)
		value.registered = false
	}
	if value.queue != nil {
		msg_void(value.queue, sel_registerName("cancelAllOperations"))
		msg_void(value.queue, sel_registerName("waitUntilAllOperationsAreFinished"))
		msg_void(value.queue, sel_registerName("release"))
	}
	if value.presented_url != nil {msg_void(value.presented_url, sel_registerName("release"))}
	if value.presenter != nil {msg_void(value.presenter, sel_registerName("release"))}
	value^ = {}
}
