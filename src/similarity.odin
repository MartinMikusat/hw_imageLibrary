package main

import "core:mem"
import "core:strings"
import image_similarity "image_similarity:."

SIMILARITY_BATCH_IMAGES :: 4
SIMILARITY_MIN_SCORE :: f32(0.75)
SIMILARITY_NEAR_SCORE :: f32(0.90)
SIMILARITY_K :: 12

similarity_f32_bytes :: proc(values: []f32, allocator := context.allocator) -> []u8 {
	if len(values) == 0 {return nil}
	bytes := make([]u8, len(values)*size_of(f32), allocator)
	mem.copy(raw_data(bytes), raw_data(values), len(bytes))
	return bytes
}

similarity_bytes_f32 :: proc(bytes: []u8, allocator := context.allocator) -> []f32 {
	if len(bytes) < size_of(f32) || len(bytes)%size_of(f32) != 0 {return nil}
	count := len(bytes) / size_of(f32)
	values := make([]f32, count, allocator)
	mem.copy(raw_data(values), raw_data(bytes), len(bytes))
	return values
}

similarity_embed_file :: proc(
	path: string,
	allocator := context.allocator,
) -> (dhash: u64, embedding: []f32, ok: bool) {
	rgba, decoded := macos_image_decode_rgba(path, SIMILARITY_DECODE_MAX_PIXELS, allocator)
	if !decoded {return 0, nil, false}
	defer macos_rgba_destroy(&rgba, allocator)
	img := image_similarity.Image{width=rgba.width, height=rgba.height, pixels=rgba.pixels}
	hash, hashed := image_similarity.dhash(&img)
	if !hashed {return 0, nil, false}
	value, embed_error := image_similarity.embed(.Apple_Vision, &img, allocator)
	if embed_error != .None {
		delete(value.data, allocator)
		return 0, nil, false
	}
	return hash, value.data, true
}

library_service_folder_embed_step :: proc(
	state: ^Library_Service_State,
	root_id: i64,
) -> (more: bool, error: Recognition_Error, embedded: int) {
	if state == nil || state.database == nil {return false, .Unsupported, 0}
	candidates, found := folder_embed_candidates(state.database, root_id, SIMILARITY_BATCH_IMAGES)
	if !found {return false, .Vision_Failed, 0}
	defer {
		for &candidate in candidates {folder_index_image_destroy(&candidate)}
		delete(candidates)
	}
	count := 0
	for &candidate in candidates {
		dhash, embedding, ok := similarity_embed_file(candidate.path)
		if !ok {
			_ = folder_image_embed_fail(state.database, root_id, candidate.image_id)
			continue
		}
		bytes := similarity_f32_bytes(embedding, context.temp_allocator)
		delete(embedding)
		if !folder_image_embed_set(state.database, root_id, candidate.image_id, dhash, bytes) {
			return false, .Vision_Failed, count
		}
		count += 1
	}
	return len(candidates) >= SIMILARITY_BATCH_IMAGES, .None, count
}

similarity_load_folder_index :: proc(
	database: ^SQLite_DB,
	root_id: i64,
	allocator := context.allocator,
) -> (image_similarity.Index, bool) {
	idx: image_similarity.Index
	statement, prepared := sqlite_prepare(database, `
SELECT image_id, embedding FROM folder_images
WHERE root_id = ? AND similarity_embedded = 1 AND embedding IS NOT NULL;`)
	if !prepared {return idx, false}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_i64_value(statement, 1, root_id) {return idx, false}
	dims := 0
	for sqlite3_step(statement) == SQLITE_ROW {
		bytes := sqlite_column_blob_copy(statement, 1, context.temp_allocator)
		values := similarity_bytes_f32(bytes, context.temp_allocator)
		if len(values) == 0 {continue}
		if dims == 0 {
			dims = len(values)
			if !image_similarity.index_init(&idx, dims) {return idx, false}
		}
		if len(values) != dims {continue}
		image_id := u64(i64(sqlite3_column_int64(statement, 0)))
		if !image_similarity.index_add(&idx, image_id, values) {continue}
	}
	return idx, dims > 0
}

similarity_folder_similar :: proc(
	database: ^SQLite_DB,
	image_id: i64,
	allocator := context.allocator,
) -> ([dynamic]Folder_Index_Image, bool) {
	query, found := folder_image_lookup(database, image_id, allocator)
	if !found {return nil, false}
	defer folder_index_image_destroy(&query, allocator)
	dhash, embedding, ok := similarity_embed_file(query.path, allocator)
	if !ok {return nil, false}
	defer delete(embedding, allocator)
	_ = dhash
	idx, loaded := similarity_load_folder_index(database, query.root_id, allocator)
	result: [dynamic]Folder_Index_Image
	append(&result, Folder_Index_Image{
		root_id = query.root_id,
		image_id = query.image_id,
		path = strings.clone(query.path, allocator),
		media_type = strings.clone(query.media_type, allocator),
		pixel_width = query.pixel_width,
		pixel_height = query.pixel_height,
		size_bytes = query.size_bytes,
		modified_unix_ms = query.modified_unix_ms,
		tags = strings.clone(query.tags, allocator),
		generated_tags = strings.clone(query.generated_tags, allocator),
	})
	if !loaded {return result, true}
	defer image_similarity.index_destroy(&idx)
	matches, searched := image_similarity.k_nearest(&idx, embedding, SIMILARITY_K, SIMILARITY_MIN_SCORE)
	if searched {
		defer delete(matches)
		for match in matches {
			if i64(match.id) == image_id {continue}
			image, image_ok := folder_image_lookup(database, i64(match.id), allocator)
			if image_ok {append(&result, image)}
		}
	}
	return result, true
}

similarity_folder_duplicates :: proc(
	database: ^SQLite_DB,
	root_id: i64,
	allocator := context.allocator,
) -> ([dynamic]Folder_Index_Image, int, bool) {
	idx, loaded := similarity_load_folder_index(database, root_id, allocator)
	if !loaded {return nil, 0, true}
	defer image_similarity.index_destroy(&idx)
	groups, grouped := image_similarity.find_duplicates(&idx, SIMILARITY_NEAR_SCORE, allocator)
	if !grouped {return nil, 0, false}
	defer image_similarity.duplicate_groups_destroy(groups, allocator)
	result: [dynamic]Folder_Index_Image
	for group in groups {
		for id in group.members {
			image, ok := folder_image_lookup(database, i64(id), allocator)
			if ok {append(&result, image)}
		}
	}
	return result, len(groups), true
}

capture_embed_set :: proc(
	database: ^SQLite_DB,
	capture_id, object_digest: string,
	dhash: u64,
	embedding: []u8,
) -> bool {
	statement, prepared := sqlite_prepare(database, `
INSERT INTO capture_embeddings (capture_id, object_digest, dhash, embedding, similarity_failed)
VALUES (?, ?, ?, ?, 0)
ON CONFLICT(capture_id) DO UPDATE SET
  object_digest = excluded.object_digest,
  dhash = excluded.dhash,
  embedding = excluded.embedding,
  similarity_failed = 0;`)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_text_value(statement, 1, capture_id) &&
	       sqlite_bind_text_value(statement, 2, object_digest) &&
	       sqlite_bind_i64_value(statement, 3, i64(dhash)) &&
	       sqlite_bind_blob_value(statement, 4, embedding) &&
	       sqlite3_step(statement) == SQLITE_DONE
}

similarity_alert_set :: proc(
	database: ^SQLite_DB,
	capture_id: string,
	similar_count: int,
) -> bool {
	statement, prepared := sqlite_prepare(database, `
INSERT INTO similarity_alerts (capture_id, similar_count, created_unix_ms)
VALUES (?, ?, ?)
ON CONFLICT(capture_id) DO UPDATE SET
  similar_count = excluded.similar_count,
  created_unix_ms = excluded.created_unix_ms;`)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_text_value(statement, 1, capture_id) &&
	       sqlite_bind_int_value(statement, 2, similar_count) &&
	       sqlite_bind_i64_value(statement, 3, library_now_unix_ms()) &&
	       sqlite3_step(statement) == SQLITE_DONE
}

similarity_alert_latest :: proc(
	database: ^SQLite_DB,
	allocator := context.allocator,
) -> (capture_id: string, similar_count: int, ok: bool) {
	statement, prepared := sqlite_prepare(database, `
SELECT capture_id, similar_count FROM similarity_alerts
ORDER BY created_unix_ms DESC LIMIT 1;`)
	if !prepared {return "", 0, false}
	defer sqlite3_finalize(statement)
	if sqlite3_step(statement) != SQLITE_ROW {return "", 0, false}
	return sqlite_column_string(statement, 0, allocator),
	       int(i64(sqlite3_column_int64(statement, 1))),
	       true
}

similarity_alert_clear :: proc(database: ^SQLite_DB, capture_id: string) -> bool {
	statement, prepared := sqlite_prepare(database, `DELETE FROM similarity_alerts WHERE capture_id = ?;`)
	if !prepared {return false}
	defer sqlite3_finalize(statement)
	return sqlite_bind_text_value(statement, 1, capture_id) && sqlite3_step(statement) == SQLITE_DONE
}

// similarity_is_near is the ingest near-duplicate gate: dHash Hamming
// distance within the library threshold, then cosine at SIMILARITY_NEAR_SCORE.
similarity_is_near :: proc(query_dhash, stored_dhash: u64, query, stored: []f32) -> bool {
	if len(stored) != len(query) || len(query) == 0 {return false}
	return image_similarity.dhash_similar(query_dhash, stored_dhash) &&
		image_similarity.cosine_similarity_normalized(query, stored) >= SIMILARITY_NEAR_SCORE
}

similarity_count_near_folder :: proc(
	database: ^SQLite_DB,
	embedding: []f32,
	dhash: u64,
) -> int {
	statement, prepared := sqlite_prepare(database, `
SELECT dhash, embedding FROM folder_images
WHERE similarity_embedded = 1 AND embedding IS NOT NULL;`)
	if !prepared {return 0}
	defer sqlite3_finalize(statement)
	count := 0
	for sqlite3_step(statement) == SQLITE_ROW {
		stored_hash := u64(i64(sqlite3_column_int64(statement, 0)))
		bytes := sqlite_column_blob_copy(statement, 1, context.temp_allocator)
		values := similarity_bytes_f32(bytes, context.temp_allocator)
		if similarity_is_near(dhash, stored_hash, embedding, values) {count += 1}
	}
	return count
}

similarity_count_near_captures :: proc(
	database: ^SQLite_DB,
	embedding: []f32,
	dhash: u64,
	exclude_capture_id: string,
) -> int {
	statement, prepared := sqlite_prepare(database, `
SELECT capture_id, dhash, embedding FROM capture_embeddings
WHERE embedding IS NOT NULL;`)
	if !prepared {return 0}
	defer sqlite3_finalize(statement)
	count := 0
	for sqlite3_step(statement) == SQLITE_ROW {
		stored_id := sqlite_column_string(statement, 0, context.temp_allocator)
		if stored_id == exclude_capture_id {continue}
		stored_hash := u64(i64(sqlite3_column_int64(statement, 1)))
		bytes := sqlite_column_blob_copy(statement, 2, context.temp_allocator)
		values := similarity_bytes_f32(bytes, context.temp_allocator)
		if similarity_is_near(dhash, stored_hash, embedding, values) {count += 1}
	}
	return count
}

similarity_capture_embedding :: proc(
	database: ^SQLite_DB,
	capture_id: string,
	allocator := context.allocator,
) -> (dhash: u64, embedding: []f32, ok: bool) {
	statement, prepared := sqlite_prepare(database, `
SELECT dhash, embedding FROM capture_embeddings
WHERE capture_id = ? AND embedding IS NOT NULL;`)
	if !prepared {return 0, nil, false}
	defer sqlite3_finalize(statement)
	if !sqlite_bind_text_value(statement, 1, capture_id) {return 0, nil, false}
	if sqlite3_step(statement) != SQLITE_ROW {return 0, nil, false}
	stored_hash := u64(i64(sqlite3_column_int64(statement, 0)))
	bytes := sqlite_column_blob_copy(statement, 1, context.temp_allocator)
	values := similarity_bytes_f32(bytes, allocator)
	if len(values) == 0 {return 0, nil, false}
	return stored_hash, values, true
}

similarity_capture_similar :: proc(
	database: ^SQLite_DB,
	capture_id: string,
	allocator := context.allocator,
) -> ([dynamic]Folder_Index_Image, bool) {
	dhash, embedding, loaded := similarity_capture_embedding(database, capture_id, allocator)
	if !loaded {return nil, false}
	defer delete(embedding, allocator)
	statement, prepared := sqlite_prepare(database, `
SELECT image_id, dhash, embedding FROM folder_images
WHERE similarity_embedded = 1 AND embedding IS NOT NULL
ORDER BY image_id;`)
	if !prepared {return nil, false}
	defer sqlite3_finalize(statement)
	result: [dynamic]Folder_Index_Image
	for sqlite3_step(statement) == SQLITE_ROW {
		image_id := i64(sqlite3_column_int64(statement, 0))
		stored_hash := u64(i64(sqlite3_column_int64(statement, 1)))
		bytes := sqlite_column_blob_copy(statement, 2, context.temp_allocator)
		values := similarity_bytes_f32(bytes, context.temp_allocator)
		if !similarity_is_near(dhash, stored_hash, embedding, values) {continue}
		image, image_ok := folder_image_lookup(database, image_id, allocator)
		if image_ok {append(&result, image)}
	}
	return result, true
}

similarity_ingest_staging :: proc(
	state: ^Library_Service_State,
	staging_path, capture_id, object_digest: string,
) -> int {
	if state == nil || state.database == nil {return 0}
	dhash, embedding, ok := similarity_embed_file(staging_path)
	if !ok {return 0}
	defer delete(embedding)
	bytes := similarity_f32_bytes(embedding, context.temp_allocator)
	_ = capture_embed_set(state.database, capture_id, object_digest, dhash, bytes)
	similar := similarity_count_near_folder(state.database, embedding, dhash) +
		similarity_count_near_captures(state.database, embedding, dhash, capture_id)
	if similar > 0 {
		_ = similarity_alert_set(state.database, capture_id, similar)
	}
	return similar
}
