package main

import "core:testing"
import "base:runtime"

TEST_LIBRARY_ID :: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
TEST_DEVICE_A :: "11111111-1111-4111-8111-111111111111"
TEST_DEVICE_B :: "22222222-2222-4222-8222-222222222222"
TEST_CAPTURE_ID :: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
TEST_EVENT_JOIN :: "10000000-0000-4000-8000-000000000001"
TEST_EVENT_NOTE_A :: "10000000-0000-4000-8000-000000000002"
TEST_EVENT_NOTE_B :: "10000000-0000-4000-8000-000000000003"
TEST_EVENT_DELETE :: "10000000-0000-4000-8000-000000000004"
TEST_EVENT_RESTORE :: "10000000-0000-4000-8000-000000000005"
TEST_EVENT_RETIRE :: "10000000-0000-4000-8000-000000000006"
TEST_EVENT_ACK_A :: "10000000-0000-4000-8000-000000000007"
TEST_EVENT_ACK_B :: "10000000-0000-4000-8000-000000000008"
TEST_DIGEST :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

test_initial_predecessors := [1]string{TEST_CAPTURE_ID}

test_genesis :: proc() -> Library_Genesis {
	return {
		schema_version = LIBRARY_SCHEMA_VERSION,
		library_id = TEST_LIBRARY_ID,
		created_at_unix_ms = 1_700_000_000_000,
		recovery_interval_seconds = LIBRARY_RECOVERY_INTERVAL_SECONDS,
		initial_device_id = TEST_DEVICE_A,
	}
}

test_capture :: proc(sequence: u64 = 1) -> Library_Capture_Record {
	return {
		schema_version = LIBRARY_SCHEMA_VERSION,
		library_id = TEST_LIBRARY_ID,
		capture_id = TEST_CAPTURE_ID,
		device_id = TEST_DEVICE_A,
		device_sequence = sequence,
		captured_at_unix_ms = 1_700_000_000_100,
		object_digest = TEST_DIGEST,
		media_type = "image/png",
		byte_count = 128,
		pixel_width = 640,
		pixel_height = 480,
		page_url = "https://example.com/page",
		page_title = "Fixture",
		current_src = "https://example.com/image.png",
		alt_text = "fixture image",
		figure_caption = "fixture caption",
		initial_note = "initial",
		element_rect = {x=10, y=20, width=300, height=200},
		viewport = {width=1200, height=800},
	}
}

test_event :: proc(
	event_id, device_id: string,
	sequence: u64,
	kind: string,
) -> Library_Event {
	return {
		schema_version = LIBRARY_SCHEMA_VERSION,
		library_id = TEST_LIBRARY_ID,
		event_id = event_id,
		device_id = device_id,
		device_sequence = sequence,
		created_at_unix_ms = 1_700_000_001_000 + i64(sequence),
		kind = kind,
	}
}

test_join_event :: proc(sequence: u64 = 2) -> Library_Event {
	event := test_event(TEST_EVENT_JOIN, TEST_DEVICE_A, sequence, LIBRARY_EVENT_DEVICE_JOIN)
	event.target_device_id = TEST_DEVICE_B
	return event
}

test_note_event :: proc(event_id, device_id: string, sequence: u64, note: string) -> Library_Event {
	event := test_event(event_id, device_id, sequence, LIBRARY_EVENT_NOTE_SET)
	event.capture_id = TEST_CAPTURE_ID
	event.note = note
	event.predecessor_revisions = test_initial_predecessors[:]
	return event
}

test_delete_event :: proc(sequence: u64 = 4) -> Library_Event {
	event := test_event(TEST_EVENT_DELETE, TEST_DEVICE_A, sequence, LIBRARY_EVENT_CAPTURE_DELETE)
	event.capture_id = TEST_CAPTURE_ID
	return event
}

test_restore_event :: proc(sequence: u64 = 5) -> Library_Event {
	event := test_event(TEST_EVENT_RESTORE, TEST_DEVICE_A, sequence, LIBRARY_EVENT_CAPTURE_RESTORE)
	event.capture_id = TEST_CAPTURE_ID
	event.target_event_id = TEST_EVENT_DELETE
	return event
}

@(test)
library_contract_round_trip_and_bounds_test :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	genesis := test_genesis()
	bytes, encoded := library_document_encode(genesis, context.temp_allocator)
	testing.expect(t, encoded)
	decoded, decode_error := library_genesis_decode(bytes, context.temp_allocator)
	testing.expect_value(t, decode_error, Library_Document_Error.None)
	testing.expect_value(t, decoded, genesis)

	record := test_capture()
	record_bytes, record_encoded := library_document_encode(record, context.temp_allocator)
	testing.expect(t, record_encoded)
	record_decoded, record_error := library_capture_decode(
		record_bytes,
		TEST_LIBRARY_ID,
		context.temp_allocator,
	)
	testing.expect_value(t, record_error, Library_Document_Error.None)
	testing.expect(t, library_capture_equivalent(&record_decoded, &record))

	record.object_digest = "ABC"
	testing.expect_value(
		t,
		library_capture_validate(&record, TEST_LIBRARY_ID),
		Library_Document_Error.Digest,
	)
	record = test_capture()
	record.current_src = "file:///tmp/image.png"
	testing.expect_value(
		t,
		library_capture_validate(&record, TEST_LIBRARY_ID),
		Library_Document_Error.URL,
	)
}

@(test)
library_materialization_converges_for_every_event_permutation_test :: proc(t: ^testing.T) {
	genesis := test_genesis()
	records := []Library_Capture_Record{test_capture()}
	base := [4]Library_Event{
		test_join_event(),
		test_note_event(TEST_EVENT_NOTE_A, TEST_DEVICE_A, 3, "from A"),
		test_note_event(TEST_EVENT_NOTE_B, TEST_DEVICE_B, 1, "from B"),
		test_delete_event(),
	}
	for &event in base {
		testing.expect_value(
			t,
			library_event_validate(&event, TEST_LIBRARY_ID),
			Library_Document_Error.None,
		)
	}
	permutation_count := 0
	for a in 0..<4 {
		for b in 0..<4 {
			if b == a {continue}
			for c in 0..<4 {
				if c == a || c == b {continue}
				for d in 0..<4 {
					if d == a || d == b || d == c {continue}
					events := []Library_Event{base[a], base[b], base[c], base[d]}
					state := library_materialize(&genesis, records, events)
					testing.expect_value(t, len(state.stream_faults), 0)
					testing.expect_value(t, len(state.captures), 1)
					if len(state.captures) == 1 {
						capture := &state.captures[0]
						testing.expect(t, capture.deleted)
						testing.expect(t, capture.note_conflict)
						testing.expect_value(t, len(capture.note_heads), 2)
						if len(capture.note_heads) == 2 {
							testing.expect_value(t, capture.note_heads[0].revision_id, TEST_EVENT_NOTE_A)
							testing.expect_value(t, capture.note_heads[1].revision_id, TEST_EVENT_NOTE_B)
						}
					}
					library_materialized_destroy(&state)
					permutation_count += 1
				}
			}
		}
	}
	testing.expect_value(t, permutation_count, 24)
}

@(test)
library_materialization_stops_at_stream_gap_and_collision_test :: proc(t: ^testing.T) {
	genesis := test_genesis()
	record := test_capture()
	delete_after_gap := test_delete_event(3)
	state := library_materialize(
		&genesis,
		[]Library_Capture_Record{record},
		[]Library_Event{delete_after_gap},
	)
	testing.expect_value(t, len(state.captures), 1)
	if len(state.captures) == 1 {testing.expect(t, !state.captures[0].deleted)}
	library_materialized_destroy(&state)

	collision := test_event(TEST_EVENT_NOTE_A, TEST_DEVICE_A, 1, LIBRARY_EVENT_CAPTURE_DELETE)
	collision.capture_id = TEST_CAPTURE_ID
	state = library_materialize(
		&genesis,
		[]Library_Capture_Record{record},
		[]Library_Event{collision},
	)
	testing.expect_value(t, len(state.stream_faults), 1)
	testing.expect_value(t, len(state.captures), 0)
	library_materialized_destroy(&state)
}

@(test)
library_restore_and_retirement_cutoff_test :: proc(t: ^testing.T) {
	genesis := test_genesis()
	records := []Library_Capture_Record{test_capture()}
	restore_events := []Library_Event{
		test_join_event(),
		test_note_event(TEST_EVENT_NOTE_A, TEST_DEVICE_A, 3, "updated"),
		test_delete_event(),
		test_restore_event(),
	}
	state := library_materialize(&genesis, records, restore_events)
	testing.expect_value(t, len(state.captures), 1)
	if len(state.captures) == 1 {testing.expect(t, !state.captures[0].deleted)}
	library_materialized_destroy(&state)

	retire := test_event(TEST_EVENT_RETIRE, TEST_DEVICE_A, 3, LIBRARY_EVENT_DEVICE_RETIRE)
	retire.target_device_id = TEST_DEVICE_B
	retire.target_device_sequence = 1
	retire_events := []Library_Event{
		test_join_event(),
		retire,
		test_note_event(TEST_EVENT_NOTE_B, TEST_DEVICE_B, 1, "accepted"),
		test_event(
			"10000000-0000-4000-8000-000000000009",
			TEST_DEVICE_B,
			2,
			LIBRARY_EVENT_CAPTURE_DELETE,
		),
	}
	retire_events[3].capture_id = TEST_CAPTURE_ID
	state = library_materialize(&genesis, records, retire_events)
	testing.expect_value(t, len(state.captures), 1)
	if len(state.captures) == 1 {
		testing.expect_value(t, state.captures[0].note, "accepted")
		testing.expect(t, !state.captures[0].deleted)
	}
	device_index, found := library_device_index(state.devices[:], TEST_DEVICE_B)
	testing.expect(t, found)
	if found {
		testing.expect(t, state.devices[device_index].retired)
		testing.expect_value(t, state.devices[device_index].accepted_cutoff, u64(1))
	}
	library_materialized_destroy(&state)
}

@(test)
library_duplicate_replay_is_idempotent_test :: proc(t: ^testing.T) {
	genesis := test_genesis()
	record := test_capture()
	join := test_join_event()
	state := library_materialize(
		&genesis,
		[]Library_Capture_Record{record, record},
		[]Library_Event{join, join},
	)
	testing.expect_value(t, len(state.stream_faults), 0)
	testing.expect_value(t, len(state.captures), 1)
	library_materialized_destroy(&state)
}

@(test)
library_purge_requires_recovery_and_every_active_device_ack_test :: proc(t: ^testing.T) {
	genesis := test_genesis()
	records := []Library_Capture_Record{test_capture()}
	deleted_at := i64(1_700_000_010_000)
	delete_event := test_event(TEST_EVENT_DELETE, TEST_DEVICE_A, 3, LIBRARY_EVENT_CAPTURE_DELETE)
	delete_event.capture_id = TEST_CAPTURE_ID
	delete_event.created_at_unix_ms = deleted_at
	ack_a := test_event(TEST_EVENT_ACK_A, TEST_DEVICE_A, 4, LIBRARY_EVENT_DEVICE_ACK)
	ack_a.frontier = []Library_Frontier_Entry{
		{device_id=TEST_DEVICE_A, sequence=4},
		{device_id=TEST_DEVICE_B, sequence=1},
	}
	ack_b := test_event(TEST_EVENT_ACK_B, TEST_DEVICE_B, 1, LIBRARY_EVENT_DEVICE_ACK)
	ack_b.frontier = []Library_Frontier_Entry{
		{device_id=TEST_DEVICE_A, sequence=3},
		{device_id=TEST_DEVICE_B, sequence=1},
	}
	events := []Library_Event{test_join_event(), delete_event, ack_a, ack_b}
	state := library_materialize(&genesis, records, events)

	before := library_object_purge_status(
		&state,
		records,
		events,
		TEST_DIGEST,
		deleted_at + LIBRARY_RECOVERY_INTERVAL_SECONDS*1000 - 1,
	)
	testing.expect_value(t, before.block, Library_Purge_Block.Recovery_Interval)
	library_purge_status_destroy(&before)

	after := library_object_purge_status(
		&state,
		records,
		events,
		TEST_DIGEST,
		deleted_at + LIBRARY_RECOVERY_INTERVAL_SECONDS*1000,
	)
	testing.expect_value(t, after.block, Library_Purge_Block.None)
	testing.expect_value(t, len(after.required_tombstone_ids), 1)
	library_purge_status_destroy(&after)
	library_materialized_destroy(&state)

	state = library_materialize(&genesis, records, events[:3])
	missing := library_object_purge_status(
		&state,
		records,
		events[:3],
		TEST_DIGEST,
		deleted_at + LIBRARY_RECOVERY_INTERVAL_SECONDS*1000,
	)
	testing.expect_value(t, missing.block, Library_Purge_Block.Missing_Device_Acknowledgement)
	testing.expect_value(t, len(missing.blocking_device_ids), 1)
	if len(missing.blocking_device_ids) == 1 {
		testing.expect_value(t, missing.blocking_device_ids[0], TEST_DEVICE_B)
	}
	library_purge_status_destroy(&missing)
	library_materialized_destroy(&state)
}

@(test)
library_two_phase_purge_commit_and_restoration_state_test :: proc(t: ^testing.T) {
	genesis := test_genesis()
	records := []Library_Capture_Record{test_capture()}
	deleted_at := i64(1_600_000_000_000)
	delete_event := test_event(
		"20000000-0000-4000-8000-000000000001",
		TEST_DEVICE_A,
		2,
		LIBRARY_EVENT_CAPTURE_DELETE,
	)
	delete_event.capture_id = TEST_CAPTURE_ID
	delete_event.created_at_unix_ms = deleted_at
	ack := test_event(
		"20000000-0000-4000-8000-000000000002",
		TEST_DEVICE_A,
		3,
		LIBRARY_EVENT_DEVICE_ACK,
	)
	ack.frontier = []Library_Frontier_Entry{{device_id=TEST_DEVICE_A, sequence=3}}
	proposal := test_event(
		"20000000-0000-4000-8000-000000000003",
		TEST_DEVICE_A,
		4,
		LIBRARY_EVENT_PURGE_PROPOSE,
	)
	proposal.object_digest = TEST_DIGEST
	proposal.required_event_ids = []string{delete_event.event_id}
	proposal.active_device_ids = []string{TEST_DEVICE_A}
	proposal.purge_not_before_unix_ms = deleted_at + LIBRARY_RECOVERY_INTERVAL_SECONDS*1000
	purge_ack := test_event(
		"20000000-0000-4000-8000-000000000004",
		TEST_DEVICE_A,
		5,
		LIBRARY_EVENT_PURGE_ACK,
	)
	purge_ack.target_event_id = proposal.event_id
	purge_ack.frontier = []Library_Frontier_Entry{{device_id=TEST_DEVICE_A, sequence=5}}
	commit := test_event(
		"20000000-0000-4000-8000-000000000005",
		TEST_DEVICE_A,
		6,
		LIBRARY_EVENT_OBJECT_PURGE,
	)
	commit.created_at_unix_ms = proposal.purge_not_before_unix_ms
	commit.target_event_id = proposal.event_id
	commit.object_digest = TEST_DIGEST
	commit.required_event_ids = proposal.required_event_ids
	commit.proof_event_ids = []string{purge_ack.event_id}
	commit.active_device_ids = proposal.active_device_ids
	commit.frontier = []Library_Frontier_Entry{{device_id=TEST_DEVICE_A, sequence=6}}
	events := []Library_Event{delete_event, ack, proposal, purge_ack, commit}
	state := library_materialize(&genesis, records, events)
	testing.expect_value(
		t,
		library_purge_commit_validate(&state, events, &commit),
		Library_Purge_Commit_Status.None,
	)
	commit_id, committed := library_object_has_valid_purge_commit(&state, events, TEST_DIGEST)
	testing.expect(t, committed)
	testing.expect_value(t, commit_id, commit.event_id)
	object_states := []Library_Object_State{.Missing}
	library_apply_purge_object_states(&state, records, events, object_states)
	testing.expect_value(t, object_states[0], Library_Object_State.Purged)
	library_materialized_destroy(&state)

	restore := test_event(
		"20000000-0000-4000-8000-000000000006",
		TEST_DEVICE_A,
		7,
		LIBRARY_EVENT_CAPTURE_RESTORE,
	)
	restore.capture_id = TEST_CAPTURE_ID
	restore.target_event_id = delete_event.event_id
	events_with_restore := []Library_Event{
		delete_event,
		ack,
		proposal,
		purge_ack,
		commit,
		restore,
	}
	state = library_materialize(&genesis, records, events_with_restore)
	object_states[0] = .Missing
	library_apply_purge_object_states(&state, records, events_with_restore, object_states)
	testing.expect_value(t, object_states[0], Library_Object_State.Missing)
	library_materialized_destroy(&state)

	recapture := test_capture(7)
	recapture.capture_id = "20000000-0000-4000-8000-000000000007"
	recapture.reinstates_purge_event_id = commit.event_id
	recaptured_records := []Library_Capture_Record{records[0], recapture}
	recapture_delete := test_event(
		"20000000-0000-4000-8000-000000000008",
		TEST_DEVICE_A,
		8,
		LIBRARY_EVENT_CAPTURE_DELETE,
	)
	recapture_delete.capture_id = recapture.capture_id
	events_after_recapture := []Library_Event{
		delete_event,
		ack,
		proposal,
		purge_ack,
		commit,
		recapture_delete,
	}
	state = library_materialize(&genesis, recaptured_records, events_after_recapture)
	_, current_commit := library_object_current_purge_commit(
		&state,
		recaptured_records,
		events_after_recapture,
		TEST_DIGEST,
	)
	testing.expect(t, !current_commit)
	recaptured_states := []Library_Object_State{.Missing, .Missing}
	library_apply_purge_object_states(
		&state,
		recaptured_records,
		events_after_recapture,
		recaptured_states,
	)
	testing.expect_value(t, recaptured_states[0], Library_Object_State.Missing)
	testing.expect_value(t, recaptured_states[1], Library_Object_State.Missing)
	library_materialized_destroy(&state)
}
