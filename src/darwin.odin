package main

import "core:dynlib"
import "core:strings"

Id :: rawptr
Sel :: rawptr

Point :: struct {x, y: f64}
Size :: struct {width, height: f64}
Rect :: struct {origin: Point, size: Size}

foreign import objc "system:objc"
foreign objc {
	objc_getClass :: proc "c" (name: cstring) -> Id ---
	sel_registerName :: proc "c" (name: cstring) -> Sel ---
	objc_allocateClassPair :: proc "c" (superclass: Id, name: cstring, extra: uint) -> Id ---
	objc_registerClassPair :: proc "c" (cls: Id) ---
	class_addMethod :: proc "c" (cls: Id, name: Sel, imp: rawptr, types: cstring) -> bool ---
	class_addProtocol :: proc "c" (cls: Id, protocol: Id) -> bool ---
	objc_getProtocol :: proc "c" (name: cstring) -> Id ---
	class_addIvar :: proc "c" (cls: Id, name: cstring, size: uint, alignment: u8, types: cstring) -> bool ---
	class_getInstanceVariable :: proc "c" (cls: Id, name: cstring) -> rawptr ---
	object_setIvar :: proc "c" (object: Id, ivar: rawptr, value: Id) ---
	object_getIvar :: proc "c" (object: Id, ivar: rawptr) -> Id ---
}

objc_send_address: rawptr

objc_initialize :: proc() -> bool {
	if objc_send_address != nil {return true}
	handle, loaded := dynlib.load_library("/usr/lib/libobjc.A.dylib")
	if !loaded {return false}
	objc_send_address, loaded = dynlib.symbol_address(handle, "objc_msgSend")
	return loaded
}

msg_id :: proc(receiver: Id, selector: Sel) -> Id {
	p := transmute(proc "c" (Id, Sel) -> Id)objc_send_address
	return p(receiver, selector)
}

msg_void :: proc(receiver: Id, selector: Sel) {
	p := transmute(proc "c" (Id, Sel))objc_send_address
	p(receiver, selector)
}

msg_id_id :: proc(receiver: Id, selector: Sel, value: Id) -> Id {
	p := transmute(proc "c" (Id, Sel, Id) -> Id)objc_send_address
	return p(receiver, selector, value)
}

msg_id_id_id :: proc(receiver: Id, selector: Sel, first, second: Id) -> Id {
	p := transmute(proc "c" (Id, Sel, Id, Id) -> Id)objc_send_address
	return p(receiver, selector, first, second)
}

msg_id_rawptr_u :: proc(receiver: Id, selector: Sel, value: rawptr, count: uint) -> Id {
	p := transmute(proc "c" (Id, Sel, rawptr, uint) -> Id)objc_send_address
	return p(receiver, selector, value, count)
}

msg_id_id_bool :: proc(receiver: Id, selector: Sel, value: Id, flag: bool) -> Id {
	p := transmute(proc "c" (Id, Sel, Id, bool) -> Id)objc_send_address
	return p(receiver, selector, value, flag)
}

msg_id_u_u :: proc(receiver: Id, selector: Sel, a, b: uint) -> Id {
	p := transmute(proc "c" (Id, Sel, uint, uint) -> Id)objc_send_address
	return p(receiver, selector, a, b)
}

msg_id_u :: proc(receiver: Id, selector: Sel, value: uint) -> Id {
	p := transmute(proc "c" (Id, Sel, uint) -> Id)objc_send_address
	return p(receiver, selector, value)
}

msg_id_bool :: proc(receiver: Id, selector: Sel, value: bool) -> Id {
	p := transmute(proc "c" (Id, Sel, bool) -> Id)objc_send_address
	return p(receiver, selector, value)
}

msg_void_id :: proc(receiver: Id, selector: Sel, value: Id) {
	p := transmute(proc "c" (Id, Sel, Id))objc_send_address
	p(receiver, selector, value)
}

msg_void_id_id :: proc(receiver: Id, selector: Sel, first, second: Id) {
	p := transmute(proc "c" (Id, Sel, Id, Id))objc_send_address
	p(receiver, selector, first, second)
}

msg_void_bool :: proc(receiver: Id, selector: Sel, value: bool) {
	p := transmute(proc "c" (Id, Sel, bool))objc_send_address
	p(receiver, selector, value)
}

msg_void_int :: proc(receiver: Id, selector: Sel, value: int) {
	p := transmute(proc "c" (Id, Sel, int))objc_send_address
	p(receiver, selector, value)
}

msg_void_u :: proc(receiver: Id, selector: Sel, value: uint) {
	p := transmute(proc "c" (Id, Sel, uint))objc_send_address
	p(receiver, selector, value)
}

msg_bool :: proc(receiver: Id, selector: Sel) -> bool {
	p := transmute(proc "c" (Id, Sel) -> bool)objc_send_address
	return p(receiver, selector)
}

msg_bool_id :: proc(receiver: Id, selector: Sel, value: Id) -> bool {
	p := transmute(proc "c" (Id, Sel, Id) -> bool)objc_send_address
	return p(receiver, selector, value)
}

msg_bool_id_id :: proc(receiver: Id, selector: Sel, first, second: Id) -> bool {
	p := transmute(proc "c" (Id, Sel, Id, Id) -> bool)objc_send_address
	return p(receiver, selector, first, second)
}

msg_int :: proc(receiver: Id, selector: Sel) -> int {
	p := transmute(proc "c" (Id, Sel) -> int)objc_send_address
	return p(receiver, selector)
}

msg_uint :: proc(receiver: Id, selector: Sel) -> uint {
	p := transmute(proc "c" (Id, Sel) -> uint)objc_send_address
	return p(receiver, selector)
}

msg_f64 :: proc(receiver: Id, selector: Sel) -> f64 {
	p := transmute(proc "c" (Id, Sel) -> f64)objc_send_address
	return p(receiver, selector)
}

msg_float :: proc(receiver: Id, selector: Sel) -> f32 {
	p := transmute(proc "c" (Id, Sel) -> f32)objc_send_address
	return p(receiver, selector)
}

msg_id_f64_f64 :: proc(receiver: Id, selector: Sel, first, second: f64) -> Id {
	p := transmute(proc "c" (Id, Sel, f64, f64) -> Id)objc_send_address
	return p(receiver, selector, first, second)
}

msg_id_rect :: proc(receiver: Id, selector: Sel, value: Rect) -> Id {
	p := transmute(proc "c" (Id, Sel, Rect) -> Id)objc_send_address
	return p(receiver, selector, value)
}

msg_id_rect_u_u_b :: proc(
	receiver: Id,
	selector: Sel,
	value: Rect,
	style, backing: uint,
	defer_window: bool,
) -> Id {
	p := transmute(proc "c" (Id, Sel, Rect, uint, uint, bool) -> Id)objc_send_address
	return p(receiver, selector, value, style, backing, defer_window)
}

msg_rect :: proc(receiver: Id, selector: Sel) -> Rect {
	p := transmute(proc "c" (Id, Sel) -> Rect)objc_send_address
	return p(receiver, selector)
}

msg_point :: proc(receiver: Id, selector: Sel) -> Point {
	p := transmute(proc "c" (Id, Sel) -> Point)objc_send_address
	return p(receiver, selector)
}

msg_point_point_id :: proc(receiver: Id, selector: Sel, point: Point, view: Id) -> Point {
	p := transmute(proc "c" (Id, Sel, Point, Id) -> Point)objc_send_address
	return p(receiver, selector, point, view)
}

msg_void_size :: proc(receiver: Id, selector: Sel, value: Size) {
	p := transmute(proc "c" (Id, Sel, Size))objc_send_address
	p(receiver, selector, value)
}

msg_void_rect :: proc(receiver: Id, selector: Sel, value: Rect) {
	p := transmute(proc "c" (Id, Sel, Rect))objc_send_address
	p(receiver, selector, value)
}

msg_void_rect_bool :: proc(receiver: Id, selector: Sel, value: Rect, display: bool) {
	p := transmute(proc "c" (Id, Sel, Rect, bool))objc_send_address
	p(receiver, selector, value, display)
}

msg_rect_rect_id :: proc(receiver: Id, selector: Sel, value: Rect, view: Id) -> Rect {
	p := transmute(proc "c" (Id, Sel, Rect, Id) -> Rect)objc_send_address
	return p(receiver, selector, value, view)
}

msg_rect_rect :: proc(receiver: Id, selector: Sel, value: Rect) -> Rect {
	p := transmute(proc "c" (Id, Sel, Rect) -> Rect)objc_send_address
	return p(receiver, selector, value)
}

nsstring :: proc(value: string) -> Id {
	if len(value) == 0 {
		return msg_id(objc_getClass("NSString"), sel_registerName("string"))
	}
	c_value := strings.clone_to_cstring(value, context.temp_allocator)
	p := transmute(proc "c" (Id, Sel, cstring) -> Id)objc_send_address
	return p(objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), c_value)
}

nsstring_to_string :: proc(value: Id, allocator := context.allocator) -> (string, bool) {
	if value == nil {return "", false}
	utf8 := msg_id(value, sel_registerName("UTF8String"))
	if utf8 == nil {return "", false}
	copy, error := strings.clone(string(cstring(utf8)), allocator)
	return copy, error == nil
}

nsurl_file :: proc(path: string, is_directory := false) -> Id {
	return msg_id_id_bool(
		objc_getClass("NSURL"),
		sel_registerName("fileURLWithPath:isDirectory:"),
		nsstring(path),
		is_directory,
	)
}

nsurl_path :: proc(url: Id, allocator := context.allocator) -> (string, bool) {
	if url == nil {return "", false}
	return nsstring_to_string(msg_id(url, sel_registerName("path")), allocator)
}

macos_autorelease_pool_begin :: proc() -> Id {
	if !objc_initialize() {return nil}
	return msg_id(objc_getClass("NSAutoreleasePool"), sel_registerName("new"))
}

macos_autorelease_pool_end :: proc(pool: Id) {
	if pool != nil {msg_void(pool, sel_registerName("drain"))}
}
