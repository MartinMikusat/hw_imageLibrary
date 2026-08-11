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
