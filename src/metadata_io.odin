package main

import cf "core:sys/darwin/CoreFoundation"
import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"
import "core:time"

foreign import metadata_image_io "system:ImageIO.framework"
foreign metadata_image_io {
	@(link_name="CGImageSourceCopyPropertiesAtIndex") macos_CGImageSourceCopyPropertiesAtIndex :: proc "c" (
		source: rawptr,
		index: uint,
		options: rawptr,
	) -> rawptr ---
	@(link_name="CGImageDestinationAddImageFromSource") macos_CGImageDestinationAddImageFromSource :: proc "c" (
		destination, source: rawptr,
		index: uint,
		properties: rawptr,
	) ---
	kCGImagePropertyIPTCDictionary: rawptr
	kCGImagePropertyIPTCKeywords: rawptr
	kCGImagePropertyOrientation: rawptr
	kCGImageDestinationLossyCompressionQuality: rawptr
}

Metadata_IO_Error :: enum {
	None,
	Invalid_Path,
	Open,
	Read,
	Write,
	Rename,
	Unsupported,
}

// metadata_keywords_read returns the space-separated, sorted, unique IPTC
// keyword set stored in the image file. An image with no keyword array yields
// an empty string, not an error; the caller treats that as "no embedded tags".
metadata_keywords_read :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	words, ok := metadata_keywords_list(path, allocator)
	if !ok {return "", false}
	defer {
		for word in words {delete(word, allocator)}
		delete(words, allocator)
	}
	if len(words) == 0 {return "", true}
	return strings.join(words, " ", allocator), true
}

metadata_keywords_list :: proc(path: string, allocator := context.allocator) -> ([]string, bool) {
	if len(path) == 0 {return nil, false}
	if !objc_initialize() {return nil, false}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return nil, false}
	defer macos_autorelease_pool_end(pool)
	source, source_ok := metadata_image_source(path)
	if !source_ok {return nil, false}
	defer cf.CFRelease(cf.TypeRef(source))
	properties := macos_CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
	if properties == nil {return nil, true}
	defer cf.CFRelease(cf.TypeRef(properties))
	return metadata_keywords_from_properties(Id(properties), allocator), true
}

metadata_orientation_read :: proc(path: string) -> (int, bool) {
	if len(path) == 0 || !objc_initialize() {return 0, false}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return 0, false}
	defer macos_autorelease_pool_end(pool)
	source, source_ok := metadata_image_source(path)
	if !source_ok {return 0, false}
	defer cf.CFRelease(cf.TypeRef(source))
	properties := macos_CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
	if properties == nil {return 1, true}
	defer cf.CFRelease(cf.TypeRef(properties))
	if kCGImagePropertyOrientation == nil {return 1, true}
	value := msg_id_id(
		Id(properties),
		sel_registerName("objectForKey:"),
		Id(kCGImagePropertyOrientation),
	)
	if value == nil {return 1, true}
	orientation := msg_int(value, sel_registerName("integerValue"))
	if orientation < 1 || orientation > 8 {return 1, true}
	return orientation, true
}

// metadata_keywords_write replaces the IPTC keyword array with the supplied
// space-separated set. Other image properties, including orientation, are
// copied from the source. The file is replaced only after a successful
// destination finalize via a temporary sibling and atomic rename.
metadata_keywords_write :: proc(path, keywords: string) -> Metadata_IO_Error {
	if len(path) == 0 {return .Invalid_Path}
	token, token_ok := library_uuid_new(context.temp_allocator)
	if !token_ok {return .Write}
	temporary := fmt.tprintf("%s.hw-gallery-meta-%s", path, token)
	error := metadata_keywords_write_destination(path, temporary, keywords)
	if error != .None {
		if os.exists(temporary) {_ = os.remove(temporary)}
		return error
	}
	if os.rename(temporary, path) != nil {
		_ = os.remove(temporary)
		return .Rename
	}
	return .None
}

// metadata_keywords_write_destination encodes the source image into destination
// with the merged keyword array. Callers that need atomic replace write to a
// temporary sibling and rename; tests use this to prove a failed destination
// leaves the source bytes untouched.
metadata_keywords_write_destination :: proc(
	source_path, destination_path, keywords: string,
) -> Metadata_IO_Error {
	if len(source_path) == 0 || len(destination_path) == 0 {return .Invalid_Path}
	if !objc_initialize() {return .Open}
	if kCGImagePropertyIPTCDictionary == nil || kCGImagePropertyIPTCKeywords == nil {
		return .Unsupported
	}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return .Open}
	defer macos_autorelease_pool_end(pool)

	source, source_ok := metadata_image_source(source_path)
	if !source_ok {return .Open}
	defer cf.CFRelease(cf.TypeRef(source))
	type_identifier := macos_CGImageSourceGetType(source)
	if type_identifier == nil {return .Unsupported}

	properties := macos_CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
	mutable := msg_id(objc_getClass("NSMutableDictionary"), sel_registerName("dictionary"))
	if properties != nil {
		defer cf.CFRelease(cf.TypeRef(properties))
		copied := msg_id_id(
			objc_getClass("NSMutableDictionary"),
			sel_registerName("dictionaryWithDictionary:"),
			Id(properties),
		)
		if copied != nil {mutable = copied}
	}
	existing := msg_id_id(
		mutable,
		sel_registerName("objectForKey:"),
		Id(kCGImagePropertyIPTCDictionary),
	)
	iptc := msg_id(objc_getClass("NSMutableDictionary"), sel_registerName("dictionary"))
	if existing != nil {
		copied := msg_id_id(
			objc_getClass("NSMutableDictionary"),
			sel_registerName("dictionaryWithDictionary:"),
			existing,
		)
		if copied != nil {iptc = copied}
	}
	keyword_array := metadata_keyword_array(keywords)
	msg_void_id_id(
		iptc,
		sel_registerName("setObject:forKey:"),
		keyword_array,
		Id(kCGImagePropertyIPTCKeywords),
	)
	msg_void_id_id(
		mutable,
		sel_registerName("setObject:forKey:"),
		iptc,
		Id(kCGImagePropertyIPTCDictionary),
	)
	if kCGImageDestinationLossyCompressionQuality != nil {
		quality := msg_id_f64(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithDouble:"),
			1.0,
		)
		msg_void_id_id(
			mutable,
			sel_registerName("setObject:forKey:"),
			quality,
			Id(kCGImageDestinationLossyCompressionQuality),
		)
	}

	destination := macos_CGImageDestinationCreateWithURL(
		nsurl_file(destination_path),
		type_identifier,
		1,
		nil,
	)
	if destination == nil {return .Write}
	defer cf.CFRelease(cf.TypeRef(destination))
	macos_CGImageDestinationAddImageFromSource(destination, source, 0, mutable)
	if !macos_CGImageDestinationFinalize(destination) {return .Write}
	return .None
}

// metadata_copy_with_orientation writes a JPEG sibling with an explicit EXIF
// orientation so write-back tests can prove the tag rewrite preserves it.
metadata_copy_with_orientation :: proc(
	source_path, destination_path: string,
	orientation: int,
) -> Metadata_IO_Error {
	if len(source_path) == 0 || len(destination_path) == 0 {return .Invalid_Path}
	if orientation < 1 || orientation > 8 {return .Unsupported}
	if !objc_initialize() || kCGImagePropertyOrientation == nil {return .Unsupported}
	pool := macos_autorelease_pool_begin()
	if pool == nil {return .Open}
	defer macos_autorelease_pool_end(pool)
	source, source_ok := metadata_image_source(source_path)
	if !source_ok {return .Open}
	defer cf.CFRelease(cf.TypeRef(source))
	mutable := msg_id(objc_getClass("NSMutableDictionary"), sel_registerName("dictionary"))
	msg_void_id_id(
		mutable,
		sel_registerName("setObject:forKey:"),
		msg_id_u(
			objc_getClass("NSNumber"),
			sel_registerName("numberWithUnsignedInteger:"),
			uint(orientation),
		),
		Id(kCGImagePropertyOrientation),
	)
	if kCGImageDestinationLossyCompressionQuality != nil {
		msg_void_id_id(
			mutable,
			sel_registerName("setObject:forKey:"),
			msg_id_f64(
				objc_getClass("NSNumber"),
				sel_registerName("numberWithDouble:"),
				1.0,
			),
			Id(kCGImageDestinationLossyCompressionQuality),
		)
	}
	destination := macos_CGImageDestinationCreateWithURL(
		nsurl_file(destination_path),
		nsstring("public.jpeg"),
		1,
		nil,
	)
	if destination == nil {return .Write}
	defer cf.CFRelease(cf.TypeRef(destination))
	macos_CGImageDestinationAddImageFromSource(destination, source, 0, mutable)
	if !macos_CGImageDestinationFinalize(destination) {return .Write}
	return .None
}

metadata_image_source :: proc(path: string) -> (rawptr, bool) {
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil || info.type != .Regular {return nil, false}
	url := nsurl_file(path)
	source := macos_CGImageSourceCreateWithURL(url, nil)
	if source == nil {return nil, false}
	if macos_CGImageSourceGetCount(source) == 0 ||
	   macos_CGImageSourceGetStatus(source) != MACOS_IMAGE_STATUS_COMPLETE {
		cf.CFRelease(cf.TypeRef(source))
		return nil, false
	}
	return source, true
}

metadata_keywords_from_properties :: proc(
	properties: Id,
	allocator := context.allocator,
) -> []string {
	result := make([dynamic]string, allocator)
	if properties == nil || kCGImagePropertyIPTCDictionary == nil {return result[:]}
	iptc := msg_id_id(
		properties,
		sel_registerName("objectForKey:"),
		Id(kCGImagePropertyIPTCDictionary),
	)
	if iptc == nil {return result[:]}
	keywords := msg_id_id(iptc, sel_registerName("objectForKey:"), Id(kCGImagePropertyIPTCKeywords))
	if keywords == nil {return result[:]}
	seen := make(map[string]struct{}, allocator)
	defer delete(seen)
	if msg_bool_id(keywords, sel_registerName("isKindOfClass:"), objc_getClass("NSString")) {
		word, copied := nsstring_to_string(keywords, allocator)
		if copied && len(word) > 0 {
			append(&result, word)
		}
		return result[:]
	}
	count := msg_uint(keywords, sel_registerName("count"))
	for index in 0..<count {
		value := msg_id_u(keywords, sel_registerName("objectAtIndex:"), index)
		word, copied := nsstring_to_string(value, allocator)
		if !copied || len(word) == 0 {continue}
		if word in seen {
			delete(word, allocator)
			continue
		}
		seen[word] = {}
		append(&result, word)
	}
	if len(result) > 1 {sort.quick_sort(result[:])}
	return result[:]
}

metadata_keyword_array :: proc(keywords: string) -> Id {
	array := msg_id(objc_getClass("NSMutableArray"), sel_registerName("array"))
	seen := make(map[string]struct{}, context.temp_allocator)
	remaining := keywords
	words: [dynamic]string
	defer delete(words)
	for word, ok := strings.fields_iterator(&remaining); ok; word, ok = strings.fields_iterator(&remaining) {
		if word in seen {continue}
		seen[word] = {}
		append(&words, word)
	}
	if len(words) > 1 {sort.quick_sort(words[:])}
	for word in words {
		msg_void_id(array, sel_registerName("addObject:"), nsstring(word))
	}
	return array
}

metadata_file_stat :: proc(path: string) -> (size_bytes, modified_unix_ms: i64, ok: bool) {
	info, stat_error := os.stat(path, context.allocator)
	if stat_error != nil {return 0, 0, false}
	defer os.file_info_delete(info, context.allocator)
	return info.size, time.to_unix_nanoseconds(info.modification_time) / 1_000_000, true
}
