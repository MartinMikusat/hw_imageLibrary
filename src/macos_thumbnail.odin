package main

import cf "core:sys/darwin/CoreFoundation"
import "core:fmt"
import "core:os"
import "core:path/filepath"

foreign import thumbnail_image_io "system:ImageIO.framework"
foreign thumbnail_image_io {
	@(link_name="CGImageSourceCreateThumbnailAtIndex") macos_CGImageSourceCreateThumbnailAtIndex :: proc "c" (
		source: rawptr,
		index: uint,
		options: rawptr,
	) -> rawptr ---
	@(link_name="CGImageDestinationCreateWithURL") macos_CGImageDestinationCreateWithURL :: proc "c" (
		url, type_identifier: rawptr,
		count: uint,
		options: rawptr,
	) -> rawptr ---
	@(link_name="CGImageDestinationAddImage") macos_CGImageDestinationAddImage :: proc "c" (
		destination, image, properties: rawptr,
	) ---
	@(link_name="CGImageDestinationFinalize") macos_CGImageDestinationFinalize :: proc "c" (
		destination: rawptr,
	) -> bool ---
	kCGImageSourceCreateThumbnailFromImageAlways: rawptr
	kCGImageSourceCreateThumbnailWithTransform: rawptr
	kCGImageSourceThumbnailMaxPixelSize: rawptr
}

MacOS_Thumbnail_Context :: struct {
	destination_path: string,
	maximum_pixels:   int,
}

macos_thumbnail_create_operation :: proc(
	user_context: rawptr,
	coordinated_source_path: string,
) -> Library_File_Error {
	value := cast(^MacOS_Thumbnail_Context)user_context
	if value == nil || value.maximum_pixels < 32 || value.maximum_pixels > 4096 {
		return .Invalid_Path
	}
	if !objc_initialize() {return .Open}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return .Open}
	defer macos_autorelease_pool_end(pool)

	source_url := nsurl_file(coordinated_source_path)
	source := macos_CGImageSourceCreateWithURL(source_url, nil)
	if source == nil {return .Read}
	defer cf.CFRelease(cf.TypeRef(source))

	options := msg_id(objc_getClass("NSMutableDictionary"), sel_registerName("dictionary"))
	true_value := msg_id_bool(objc_getClass("NSNumber"), sel_registerName("numberWithBool:"), true)
	maximum_value := msg_id_u(
		objc_getClass("NSNumber"),
		sel_registerName("numberWithUnsignedInteger:"),
		uint(value.maximum_pixels),
	)
	msg_void_id_id(
		options,
		sel_registerName("setObject:forKey:"),
		true_value,
		Id(kCGImageSourceCreateThumbnailFromImageAlways),
	)
	msg_void_id_id(
		options,
		sel_registerName("setObject:forKey:"),
		true_value,
		Id(kCGImageSourceCreateThumbnailWithTransform),
	)
	msg_void_id_id(
		options,
		sel_registerName("setObject:forKey:"),
		maximum_value,
		Id(kCGImageSourceThumbnailMaxPixelSize),
	)
	image := macos_CGImageSourceCreateThumbnailAtIndex(source, 0, options)
	if image == nil {return .Read}
	defer cf.CFRelease(cf.TypeRef(image))

	identifier := nsstring("public.png")
	destination := macos_CGImageDestinationCreateWithURL(
		nsurl_file(value.destination_path),
		identifier,
		1,
		nil,
	)
	if destination == nil {return .Write}
	defer cf.CFRelease(cf.TypeRef(destination))
	macos_CGImageDestinationAddImage(destination, image, nil)
	if !macos_CGImageDestinationFinalize(destination) {return .Write}
	return .None
}

macos_thumbnail_cache_path :: proc(
	support_path, digest: string,
	maximum_pixels: int,
	allocator := context.allocator,
) -> (string, bool) {
	if !library_digest_valid(digest) || maximum_pixels < 32 || maximum_pixels > 4096 {
		return "", false
	}
	return library_join(
		[]string{
			support_path,
			"thumbnails-v1",
			fmt.tprintf("%s-%d.png", digest, maximum_pixels),
		},
		allocator,
	)
}

macos_thumbnail_cache_create :: proc(
	source_path, support_path, digest: string,
	maximum_pixels: int,
	allocator := context.allocator,
) -> (string, Library_File_Error) {
	path, path_ok := macos_thumbnail_cache_path(
		support_path,
		digest,
		maximum_pixels,
		allocator,
	)
	if !path_ok {return "", .Invalid_Path}
	if os.exists(path) {
		if info, inspected := macos_image_inspect(path); inspected &&
		   info.pixel_width <= maximum_pixels && info.pixel_height <= maximum_pixels {
			return path, .None
		}
		_ = os.remove(path)
	}
	if !library_ensure_directory(filepath.dir(path)) {return "", .Create_Directory}
	token, token_ok := library_uuid_new(context.temp_allocator)
	if !token_ok {return "", .Write}
	temporary_path := fmt.aprintf(
		"%s.tmp-%s",
		path,
		token,
		allocator = context.temp_allocator,
	)
	defer if os.exists(temporary_path) {_ = os.remove(temporary_path)}
	value := MacOS_Thumbnail_Context{
		destination_path = temporary_path,
		maximum_pixels = maximum_pixels,
	}
	error := macos_coordinate_read(
		source_path,
		macos_thumbnail_create_operation,
		&value,
	)
	if error != .None {return "", error}
	if os.rename(temporary_path, path) != nil {return "", .Write}
	return path, .None
}
