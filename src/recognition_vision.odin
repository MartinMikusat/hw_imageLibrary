package main

import "core:dynlib"
import "core:os"
import "core:strings"

// apple_vision_classify runs the three recognition requests
// (VNClassifyImageRequest, VNRecognizeAnimalsRequest,
// VNRecognizeObjectsRequest) over the image at path through one
// VNImageRequestHandler. The handler reads the file URL directly, so no pixel
// decode is needed. Labels below the provider confidence threshold are
// dropped; the remaining labels become the image's generated tags.
apple_vision_classify :: proc(
	provider: ^Apple_Vision_Provider,
	path: string,
	allocator := context.allocator,
) -> ([]Image_Tag, Recognition_Error) {
	result: [dynamic]Image_Tag
	append_tag :: proc(
		tags: ^[dynamic]Image_Tag,
		kind: Tag_Kind,
		label: string,
		confidence: f32,
	) {
		append(tags, Image_Tag{
			kind = kind,
			label = label,
			confidence = confidence,
		})
	}

	if provider == nil || len(path) == 0 {return nil, .Invalid_Image}
	if !objc_initialize() || !recognition_vision_load() {
		return nil, .Backend_Unavailable
	}
	info, info_error := os.stat(path, context.temp_allocator)
	if info_error != nil {return nil, .Invalid_Image}
	if info.type != .Regular {return nil, .Invalid_Image}

	pool := macos_autorelease_pool_begin()
	if pool == nil {return nil, .Backend_Unavailable}
	defer macos_autorelease_pool_end(pool)

	handler := msg_id(objc_getClass("VNImageRequestHandler"), sel_registerName("alloc"))
	if handler == nil {return nil, .Backend_Unavailable}
	defer msg_void(handler, sel_registerName("release"))
	handler = msg_id_id_id(handler, sel_registerName("initWithURL:options:"), nsurl_file(path), nil)
	if handler == nil {return nil, .Invalid_Image}

	classify := msg_id(objc_getClass("VNClassifyImageRequest"), sel_registerName("new"))
	if classify == nil {return nil, .Backend_Unavailable}
	defer msg_void(classify, sel_registerName("release"))
	animals := msg_id(objc_getClass("VNRecognizeAnimalsRequest"), sel_registerName("new"))
	if animals == nil {return nil, .Backend_Unavailable}
	defer msg_void(animals, sel_registerName("release"))
	objects := msg_id(objc_getClass("VNRecognizeObjectsRequest"), sel_registerName("new"))
	if objects == nil {return nil, .Backend_Unavailable}
	defer msg_void(objects, sel_registerName("release"))

	request_array := [3]Id{classify, animals, objects}
	requests := msg_id_rawptr_u(
		objc_getClass("NSArray"),
		sel_registerName("arrayWithObjects:count:"),
		raw_data(request_array[:]),
		len(request_array),
	)
	if requests == nil {return nil, .Backend_Unavailable}

	if !msg_bool_id(handler, sel_registerName("performRequests:error:"), requests) {
		return nil, .Vision_Failed
	}

	threshold := provider.confidence_threshold
	if threshold <= 0 {threshold = RECOGNITION_DEFAULT_CONFIDENCE}

	collect_labels := proc(
		results: Id,
		kind: Tag_Kind,
		threshold: f32,
		tags: ^[dynamic]Image_Tag,
	) -> bool {
		if results == nil {return true}
		count := msg_uint(results, sel_registerName("count"))
		if count == 0 {return true}
		if kind == .Class {
			// VNClassifyImageRequest reports the full concept hierarchy in
			// descending confidence order; every ancestor of a detected leaf
			// carries the leaf's exact confidence. Only the most specific
			// label of each equal-confidence run is kept, so tags read
			// "german_shepherd" instead of every parent class.
			pending := ""
			pending_confidence := f32(-1)
			flush_pending :: proc(
				tags: ^[dynamic]Image_Tag,
				kind: Tag_Kind,
				threshold: f32,
				label: string,
				confidence: f32,
			) {
				if len(label) == 0 || confidence < threshold {return}
				// The label is cloned because the pending buffer is freed right
				// after the flush; the tag must own its own copy.
				cloned := strings.clone(label)
				if len(cloned) == 0 {return}
				append(tags, Image_Tag{kind=kind, label=cloned, confidence=confidence})
			}
			for index in 0..<count {
				observation := msg_id_u(results, sel_registerName("objectAtIndex:"), index)
				if observation == nil {continue}
				confidence := msg_float(observation, sel_registerName("confidence"))
				label, copied := nsstring_to_string(msg_id(observation, sel_registerName("identifier")))
				if !copied || len(label) == 0 {continue}
				if confidence != pending_confidence {
					flush_pending(tags, kind, threshold, pending, pending_confidence)
					delete(pending)
					pending = label
					pending_confidence = confidence
				} else {
					delete(pending)
					pending = label
				}
			}
			flush_pending(tags, kind, threshold, pending, pending_confidence)
			delete(pending)
			return true
		}
		// VNRecognizedObjectObservation groups labels per detected region;
		// only the highest-confidence label of each region is kept.
		for index in 0..<count {
			observation := msg_id_u(results, sel_registerName("objectAtIndex:"), index)
			if observation == nil {continue}
			labels := msg_id(observation, sel_registerName("labels"))
			if labels == nil {continue}
			label_count := msg_uint(labels, sel_registerName("count"))
			for label_index in 0..<label_count {
				label_observation := msg_id_u(labels, sel_registerName("objectAtIndex:"), label_index)
				if label_observation == nil {continue}
				confidence := msg_float(label_observation, sel_registerName("confidence"))
				if confidence < threshold {continue}
				label, copied := nsstring_to_string(
					msg_id(label_observation, sel_registerName("identifier")),
				)
				if !copied || len(label) == 0 {continue}
				append_tag(tags, kind, label, confidence)
				break
			}
		}
		return true
	}

	collect_labels(
		msg_id(classify, sel_registerName("results")),
		.Class,
		threshold,
		&result,
	)
	collect_labels(
		msg_id(animals, sel_registerName("results")),
		.Animal,
		threshold,
		&result,
	)
	collect_labels(
		msg_id(objects, sel_registerName("results")),
		.Object,
		threshold,
		&result,
	)

	// Vision orders each request's results by descending confidence; a small
	// label cap keeps the generated tag set compact for search and display.
	if len(result) > RECOGNITION_MAX_TAGS {
		for &tag in result[RECOGNITION_MAX_TAGS:] {image_tag_destroy(&tag)}
		resize(&result, RECOGNITION_MAX_TAGS)
	}
	return result[:], .None
}

RECOGNITION_MAX_TAGS :: 12

recognition_vision_loaded: bool

recognition_vision_load :: proc() -> bool {
	if recognition_vision_loaded {return true}
	_, ok := dynlib.load_library("/System/Library/Frameworks/Vision.framework/Vision")
	recognition_vision_loaded = ok
	return ok
}
