package main

import cf "core:sys/darwin/CoreFoundation"

foreign import image_io "system:ImageIO.framework"
foreign image_io {
	@(link_name="CGImageSourceCreateWithURL") macos_CGImageSourceCreateWithURL :: proc "c" (url, options: rawptr) -> rawptr ---
	@(link_name="CGImageSourceGetCount") macos_CGImageSourceGetCount :: proc "c" (source: rawptr) -> uint ---
	@(link_name="CGImageSourceGetStatus") macos_CGImageSourceGetStatus :: proc "c" (source: rawptr) -> i32 ---
	@(link_name="CGImageSourceGetType") macos_CGImageSourceGetType :: proc "c" (source: rawptr) -> rawptr ---
	@(link_name="CGImageSourceCreateImageAtIndex") macos_CGImageSourceCreateImageAtIndex :: proc "c" (source: rawptr, index: uint, options: rawptr) -> rawptr ---
}

foreign import image_core_graphics "system:CoreGraphics.framework"
foreign image_core_graphics {
	@(link_name="CGImageGetWidth") macos_CGImageGetWidth :: proc "c" (image: rawptr) -> uint ---
	@(link_name="CGImageGetHeight") macos_CGImageGetHeight :: proc "c" (image: rawptr) -> uint ---
	@(link_name="CGColorSpaceCreateDeviceRGB") macos_CGColorSpaceCreateDeviceRGB :: proc "c" () -> rawptr ---
	@(link_name="CGColorSpaceRelease") macos_CGColorSpaceRelease :: proc "c" (space: rawptr) ---
	@(link_name="CGBitmapContextCreate") macos_CGBitmapContextCreate :: proc "c" (
		data: rawptr,
		width: uint,
		height: uint,
		bits_per_component: uint,
		bytes_per_row: uint,
		space: rawptr,
		bitmap_info: u32,
	) -> rawptr ---
	@(link_name="CGContextRelease") macos_CGContextRelease :: proc "c" (ctx: rawptr) ---
	@(link_name="CGContextDrawImage") macos_CGContextDrawImage :: proc "c" (ctx: rawptr, rect: Rect, image: rawptr) ---
}

foreign import image_core_foundation "system:CoreFoundation.framework"
foreign image_core_foundation {
	@(link_name="CFURLCreateFromFileSystemRepresentation") macos_CFURLCreateFromFileSystemRepresentation :: proc "c" (
		allocator: rawptr,
		bytes: [^]u8,
		count: int,
		is_directory: bool,
	) -> rawptr ---
}

MACOS_IMAGE_STATUS_COMPLETE :: i32(0)

MacOS_Image_Info :: struct {
	media_type: string,
	pixel_width: int,
	pixel_height: int,
}

macos_image_media_type :: proc(type_identifier: rawptr) -> string {
	if type_identifier == nil {return ""}
	buffer: [256]u8
	if !bool(cf.StringGetCString(
		cf.String(type_identifier),
		raw_data(buffer[:]),
		cf.Index(len(buffer)),
		cf.StringEncoding(cf.StringBuiltInEncodings.UTF8),
	)) {
		return ""
	}
	length := 0
	for length < len(buffer) && buffer[length] != 0 {length += 1}
	identifier := string(buffer[:length])
	switch identifier {
	case "public.avif": return "image/avif"
	case "com.compuserve.gif": return "image/gif"
	case "public.jpeg": return "image/jpeg"
	case "public.png": return "image/png"
	case "org.webmproject.webp": return "image/webp"
	}
	return ""
}

macos_image_inspect :: proc(path: string) -> (MacOS_Image_Info, bool) {
	if len(path) == 0 {return {}, false}
	url := macos_CFURLCreateFromFileSystemRepresentation(
		nil,
		raw_data(transmute([]u8)path),
		len(path),
		false,
	)
	if url == nil {return {}, false}
	defer cf.CFRelease(cf.TypeRef(url))
	source := macos_CGImageSourceCreateWithURL(url, nil)
	if source == nil {return {}, false}
	defer cf.CFRelease(cf.TypeRef(source))
	if macos_CGImageSourceGetCount(source) == 0 ||
	   macos_CGImageSourceGetStatus(source) != MACOS_IMAGE_STATUS_COMPLETE {
		return {}, false
	}
	media_type := macos_image_media_type(macos_CGImageSourceGetType(source))
	if len(media_type) == 0 {return {}, false}
	image := macos_CGImageSourceCreateImageAtIndex(source, 0, nil)
	if image == nil {return {}, false}
	defer cf.CFRelease(cf.TypeRef(image))
	width := macos_CGImageGetWidth(image)
	height := macos_CGImageGetHeight(image)
	if width == 0 || height == 0 || width > LIBRARY_MAX_IMAGE_DIMENSION ||
	   height > LIBRARY_MAX_IMAGE_DIMENSION {
		return {}, false
	}
	return {
		media_type = media_type,
		pixel_width = int(width),
		pixel_height = int(height),
	}, true
}

MACOS_IMAGE_BITMAP_RGBA :: u32(3)
SIMILARITY_DECODE_MAX_PIXELS :: 512

MacOS_RGBA_Image :: struct {
	width:  int,
	height: int,
	pixels: []u8,
}

macos_rgba_destroy :: proc(value: ^MacOS_RGBA_Image, allocator := context.allocator) {
	if value == nil {return}
	delete(value.pixels, allocator)
	value^ = {}
}

// macos_image_decode_rgba loads a file into owned RGBA8 pixels, downscaling
// so the long edge is at most max_pixels. Similarity and dHash callers must
// keep this bound so an idle batch cannot decode a full-resolution photo.
macos_image_decode_rgba :: proc(
	path: string,
	max_pixels := SIMILARITY_DECODE_MAX_PIXELS,
	allocator := context.allocator,
) -> (MacOS_RGBA_Image, bool) {
	if len(path) == 0 || max_pixels < 8 {return {}, false}
	if !objc_initialize() {return {}, false}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return {}, false}
	defer macos_autorelease_pool_end(pool)
	url := nsurl_file(path)
	source := macos_CGImageSourceCreateWithURL(url, nil)
	if source == nil {return {}, false}
	defer cf.CFRelease(cf.TypeRef(source))
	image := macos_CGImageSourceCreateImageAtIndex(source, 0, nil)
	if image == nil {return {}, false}
	width := int(macos_CGImageGetWidth(image))
	height := int(macos_CGImageGetHeight(image))
	if width <= 0 || height <= 0 {
		cf.CFRelease(cf.TypeRef(image))
		return {}, false
	}
	if width > max_pixels || height > max_pixels {
		cf.CFRelease(cf.TypeRef(image))
		options := msg_id(objc_getClass("NSMutableDictionary"), sel_registerName("dictionary"))
		true_value := msg_id_bool(objc_getClass("NSNumber"), sel_registerName("numberWithBool:"), true)
		maximum_value := msg_id_u(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInteger:"),
			uint(max_pixels),
		)
		if kCGImageSourceCreateThumbnailFromImageAlways != nil {
			msg_void_id_id(options, sel_registerName("setObject:forKey:"), true_value, Id(kCGImageSourceCreateThumbnailFromImageAlways))
		}
		if kCGImageSourceCreateThumbnailWithTransform != nil {
			msg_void_id_id(options, sel_registerName("setObject:forKey:"), true_value, Id(kCGImageSourceCreateThumbnailWithTransform))
		}
		if kCGImageSourceThumbnailMaxPixelSize != nil {
			msg_void_id_id(options, sel_registerName("setObject:forKey:"), maximum_value, Id(kCGImageSourceThumbnailMaxPixelSize))
		}
		image = macos_CGImageSourceCreateThumbnailAtIndex(source, 0, options)
		if image == nil {return {}, false}
		width = int(macos_CGImageGetWidth(image))
		height = int(macos_CGImageGetHeight(image))
	}
	defer cf.CFRelease(cf.TypeRef(image))
	if width <= 0 || height <= 0 {return {}, false}
	pixels := make([]u8, width*height*4, allocator)
	if len(pixels) < width*height*4 {return {}, false}
	space := macos_CGColorSpaceCreateDeviceRGB()
	if space == nil {
		delete(pixels, allocator)
		return {}, false
	}
	defer macos_CGColorSpaceRelease(space)
	bitmap_infos := [3]u32{MACOS_IMAGE_BITMAP_RGBA, 1, 8195}
	ctx: rawptr
	for info in bitmap_infos {
		ctx = macos_CGBitmapContextCreate(
			raw_data(pixels),
			uint(width),
			uint(height),
			8,
			uint(width*4),
			space,
			info,
		)
		if ctx != nil {break}
	}
	if ctx == nil {
		delete(pixels, allocator)
		return {}, false
	}
	defer macos_CGContextRelease(ctx)
	macos_CGContextDrawImage(ctx, Rect{origin={0, 0}, size={f64(width), f64(height)}}, image)
	return {width=width, height=height, pixels=pixels}, true
}
