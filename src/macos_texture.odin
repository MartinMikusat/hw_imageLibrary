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
	// The app's CAMetalLayer uses a non-sRGB pixel format and every UI color is
	// authored as sRGB-encoded values that pass straight through the shader.
	// MTKTextureLoader defaults to creating sRGB textures, which would decode
	// the image to linear on sample and re-encode it only at a non-existent
	// sRGB framebuffer — the classic double-gamma look (washed out or overly
	// contrasty). Loading without sRGB keeps the source bytes intact.
	options := msg_id_id_id(
		objc_getClass("NSDictionary"),
		sel_registerName("dictionaryWithObject:forKey:"),
		msg_id_bool(objc_getClass("NSNumber"), sel_registerName("numberWithBool:"), false),
		nsstring("MTKTextureLoaderOptionSRGB"),
	)
	error: Id
	p := transmute(proc "c" (Id, Sel, Id, Id, ^Id) -> Id)objc_send_address
	texture = p(
		loader,
		sel_registerName("newTextureWithContentsOfURL:options:error:"),
		nsurl_file(path),
		options,
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
