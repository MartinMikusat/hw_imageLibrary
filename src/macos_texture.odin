package main

macos_texture_load_file :: proc(
	device: Id,
	path: string,
) -> (texture: Id, width, height: int, ok: bool) {
	if device == nil || len(path) == 0 || !objc_initialize() {return}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return}
	defer macos_autorelease_pool_end(pool)
	loader := msg_id_id(
		msg_id(objc_getClass("MTKTextureLoader"), sel_registerName("alloc")),
		sel_registerName("initWithDevice:"),
		device,
	)
	if loader == nil {return}
	defer msg_void(loader, sel_registerName("release"))
	error: Id
	p := transmute(proc "c" (Id, Sel, Id, Id, ^Id) -> Id)objc_send_address
	texture = p(
		loader,
		sel_registerName("newTextureWithContentsOfURL:options:error:"),
		nsurl_file(path),
		nil,
		&error,
	)
	if texture == nil || error != nil {return nil, 0, 0, false}
	width = int(msg_uint(texture, sel_registerName("width")))
	height = int(msg_uint(texture, sel_registerName("height")))
	if width <= 0 || height <= 0 {
		msg_void(texture, sel_registerName("release"))
		return nil, 0, 0, false
	}
	return texture, width, height, true
}
