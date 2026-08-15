package main

import "core:sort"
import "core:strings"

// Recognition defaults. The confidence threshold is read from settings when
// present and falls back to RECOGNITION_DEFAULT_CONFIDENCE otherwise.
RECOGNITION_DEFAULT_CONFIDENCE :: f32(0.35)
RECOGNITION_BATCH_IMAGES :: 8
RECOGNITION_PROVIDER_APPLE_VISION :: "apple-vision"

// Tag_Kind records which Vision request produced a tag so the UI and future
// providers can distinguish a top-level class from a detected animal or
// object. The label itself carries the user-facing keyword.
Tag_Kind :: enum {
	Class,  // VNClassifyImageRequest
	Animal, // VNRecognizeAnimalsRequest
	Object, // VNRecognizeObjectsRequest
}

Image_Tag :: struct {
	kind:       Tag_Kind,
	label:      string,
	confidence: f32,
}

image_tag_destroy :: proc(value: ^Image_Tag, allocator := context.allocator) {
	if value == nil {return}
	delete(value.label, allocator)
	value^ = {}
}

image_tags_destroy :: proc(tags: []Image_Tag, allocator := context.allocator) {
	for &tag in tags {image_tag_destroy(&tag, allocator)}
}

Recognition_Error :: enum {
	None,
	Unsupported,
	Invalid_Image,
	Backend_Unavailable,
	Vision_Failed,
	Allocation_Failed,
}

// Apple_Vision_Provider is the v1 recognition backend. It holds the label
// confidence threshold; labels at or above it are kept in the tag set.
Apple_Vision_Provider :: struct {
	confidence_threshold: f32,
}

// Tag_Provider is the closed set of recognition backends. A remote provider
// (OpenRouter or a local endpoint) joins this union without changing call
// sites; the registry below maps the stored settings name to a provider.
Tag_Provider :: union {
	^Apple_Vision_Provider,
}

// tag_provider_default constructs the provider named by settings, falling back
// to Apple Vision. Returns nil for an unknown name so callers can report an
// explicit configuration error.
tag_provider_default :: proc(name: string, confidence_threshold: f32) -> Tag_Provider {
	switch name {
	case RECOGNITION_PROVIDER_APPLE_VISION, "":
		return apple_vision_provider(confidence_threshold)
	}
	return nil
}

apple_vision_provider :: proc(confidence_threshold: f32) -> Tag_Provider {
	provider := new(Apple_Vision_Provider)
	provider.confidence_threshold = confidence_threshold
	return provider
}

tag_provider_destroy :: proc(provider: Tag_Provider) {
	switch p in provider {
	case ^Apple_Vision_Provider:
		free(p)
	case:
	}
}

// tag_provider_classify runs recognition over the image at path and returns
// the accepted tags (labels at or above the provider threshold). Providers own
// the thresholding; callers own the returned tag storage.
tag_provider_classify :: proc(
	provider: Tag_Provider,
	path: string,
	allocator := context.allocator,
) -> ([]Image_Tag, Recognition_Error) {
	switch p in provider {
	case ^Apple_Vision_Provider:
		return apple_vision_classify(p, path, allocator)
	case:
		return nil, .Unsupported
	}
}

// recognition_confidence resolves the effective threshold from settings.
// A zero or absent settings value (older settings files, folder-only mode)
// falls back to the documented default.
recognition_confidence :: proc() -> f32 {
	settings, error := local_settings_load(context.temp_allocator)
	if error != .None {return RECOGNITION_DEFAULT_CONFIDENCE}
	defer local_settings_destroy(&settings)
	if settings.recognition_confidence > 0 {
		return settings.recognition_confidence
	}
	return RECOGNITION_DEFAULT_CONFIDENCE
}

recognition_enabled :: proc() -> bool {
	settings, error := local_settings_load(context.temp_allocator)
	if error != .None {return true}
	defer local_settings_destroy(&settings)
	return !settings.recognition_disabled
}

// generated_tags_string renders recognized tags into the space-separated
// keyword string stored in folder_images.generated_tags and searched by FTS.
// Labels are normalized (underscores to spaces), deduplicated, and sorted so
// retagging is idempotent.
generated_tags_string :: proc(tags: []Image_Tag, allocator := context.allocator) -> string {
	if len(tags) == 0 {return ""}
	// allocated holds each freshly allocated normalized label so every
	// occurrence can be freed; aliased labels (no underscore was replaced)
	// remain owned by the caller.
	allocated := make([dynamic]string, allocator)
	defer {
		for value in allocated {delete(value, allocator)}
		delete(allocated)
	}
	unique_values := make(map[string]struct{}, allocator)
	defer delete(unique_values)
	for &tag in tags {
		if len(tag.label) == 0 {continue}
		normalized, was_allocated := strings.replace_all(tag.label, "_", " ", allocator)
		unique_values[normalized] = {}
		if was_allocated {append(&allocated, normalized)}
	}
	result := make([dynamic]string, allocator)
	defer delete(result)
	for value in unique_values {append(&result, value)}
	sort.quick_sort(result[:])
	return strings.join(result[:], " ", allocator)
}

// generated_tags_merge combines existing generated tags with a freshly
// recognized set, keeping one occurrence of every keyword. Existing tags that
// were removed by a recognition run are intentionally preserved: a lower
// threshold or a different provider should be able to extend, never erase.
generated_tags_merge :: proc(existing, additional: string, allocator := context.allocator) -> string {
	if len(additional) == 0 {return strings.clone(existing, allocator)}
	if len(existing) == 0 {return strings.clone(additional, allocator)}
	seen := make(map[string]struct{}, allocator)
	defer delete(seen)
	result := make([dynamic]string, allocator)
	defer delete(result)
	ex := existing
	for word, ok := strings.fields_iterator(&ex); ok; word, ok = strings.fields_iterator(&ex) {
		append(&result, word)
		seen[word] = {}
	}
	ad := additional
	for word, ok := strings.fields_iterator(&ad); ok; word, ok = strings.fields_iterator(&ad) {
		if word in seen {continue}
		append(&result, word)
		seen[word] = {}
	}
	sort.quick_sort(result[:])
	return strings.join(result[:], " ", allocator)
}

// recognition_tag_set summarizes a recognized tag list for diagnostics.
recognition_tag_summary :: proc(tags: []Image_Tag, allocator := context.allocator) -> string {
	if len(tags) == 0 {return ""}
	labels := make([dynamic]string, allocator)
	defer delete(labels)
	for &tag in tags {
		if len(tag.label) > 0 {append(&labels, tag.label)}
	}
	return strings.join(labels[:], ", ", allocator)
}
