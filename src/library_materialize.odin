package main

import "core:slice"
import "base:runtime"

Library_Operation_Kind :: enum {
	Capture,
	Event,
}

Library_Operation_Ref :: struct {
	kind:            Library_Operation_Kind,
	index:           int,
	device_id:       string,
	device_sequence: u64,
	document_id:     string,
	prefix_complete: bool,
	accepted:        bool,
}

Library_Stream_Fault :: struct {
	device_id: string,
	sequence:  u64,
	reason:    string,
}

Library_Document_Fault :: struct {
	document_id: string,
	reason:      string,
}

Library_Device_State :: struct {
	device_id:          string,
	sequence_prefix:    u64,
	accepted_cutoff:    u64,
	authorized:         bool,
	retired:            bool,
	latest_ack_event_id: string,
}

Library_Note_Head :: struct {
	revision_id: string,
	note:        string,
}

Library_Capture_State :: struct {
	record_index:         int,
	capture_id:           string,
	captured_at_unix_ms:  i64,
	deleted:              bool,
	note:                 string,
	note_conflict:        bool,
	note_heads:           [dynamic]Library_Note_Head,
	effective_delete_ids: [dynamic]string,
	event_indices:        [dynamic]int,
}

Library_Materialized :: struct {
	devices:                [dynamic]Library_Device_State,
	captures:               [dynamic]Library_Capture_State,
	accepted_event_indices: [dynamic]int,
	pending_event_indices:  [dynamic]int,
	stream_faults:          [dynamic]Library_Stream_Fault,
	document_faults:        [dynamic]Library_Document_Fault,
	allocator:              runtime.Allocator,
}

Library_Note_Revision :: struct {
	revision_id: string,
	note:        string,
	event_index: int,
	accepted:    bool,
}

Library_Purge_Block :: enum {
	None,
	No_References,
	Live_Reference,
	Recovery_Interval,
	Missing_Device_Acknowledgement,
	Pending_Stream,
}

Library_Purge_Status :: struct {
	block:                  Library_Purge_Block,
	not_before_unix_ms:     i64,
	required_tombstone_ids: [dynamic]string,
	blocking_device_ids:    [dynamic]string,
	allocator:              runtime.Allocator,
}

Library_Purge_Commit_Status :: enum {
	None,
	Proposal_Missing,
	Proposal_Mismatch,
	Rejected,
	Proof_Mismatch,
	Frontier_Mismatch,
	Too_Early,
}

library_string_slices_equal :: proc(a, b: []string) -> bool {
	if len(a) != len(b) {return false}
	for value, index in a {
		if value != b[index] {return false}
	}
	return true
}

library_frontiers_equal :: proc(a, b: []Library_Frontier_Entry) -> bool {
	if len(a) != len(b) {return false}
	for value, index in a {
		if value != b[index] {return false}
	}
	return true
}

library_capture_equivalent :: proc(a, b: ^Library_Capture_Record) -> bool {
	return a^ == b^
}

library_event_equivalent :: proc(a, b: ^Library_Event) -> bool {
	return a.schema_version == b.schema_version &&
	       a.library_id == b.library_id &&
	       a.event_id == b.event_id &&
	       a.device_id == b.device_id &&
	       a.device_sequence == b.device_sequence &&
	       a.created_at_unix_ms == b.created_at_unix_ms &&
	       a.kind == b.kind &&
	       a.capture_id == b.capture_id &&
	       a.target_event_id == b.target_event_id &&
	       a.target_device_id == b.target_device_id &&
	       a.target_device_sequence == b.target_device_sequence &&
	       a.note == b.note &&
	       library_string_slices_equal(a.predecessor_revisions, b.predecessor_revisions) &&
	       library_frontiers_equal(a.frontier, b.frontier) &&
	       a.object_digest == b.object_digest &&
	       library_string_slices_equal(a.required_event_ids, b.required_event_ids) &&
	       library_string_slices_equal(a.proof_event_ids, b.proof_event_ids) &&
	       library_string_slices_equal(a.active_device_ids, b.active_device_ids) &&
	       a.purge_not_before_unix_ms == b.purge_not_before_unix_ms
}

library_operation_equivalent :: proc(
	a, b: ^Library_Operation_Ref,
	records: []Library_Capture_Record,
	events: []Library_Event,
) -> bool {
	if a.kind != b.kind || a.document_id != b.document_id {return false}
	switch a.kind {
	case .Capture:
		return library_capture_equivalent(&records[a.index], &records[b.index])
	case .Event:
		return library_event_equivalent(&events[a.index], &events[b.index])
	}
	return false
}

library_device_index :: proc(devices: []Library_Device_State, device_id: string) -> (int, bool) {
	for device, index in devices {
		if device.device_id == device_id {return index, true}
	}
	return -1, false
}

library_capture_index :: proc(
	states: []Library_Capture_State,
	records: []Library_Capture_Record,
	capture_id: string,
) -> (int, bool) {
	for state, index in states {
		if records[state.record_index].capture_id == capture_id {return index, true}
	}
	return -1, false
}

library_materialized_destroy :: proc(value: ^Library_Materialized) {
	for &capture in value.captures {
		delete(capture.note_heads)
		delete(capture.effective_delete_ids)
		delete(capture.event_indices)
	}
	delete(value.devices)
	delete(value.captures)
	delete(value.accepted_event_indices)
	delete(value.pending_event_indices)
	delete(value.stream_faults)
	delete(value.document_faults)
	value^ = {}
}

library_purge_status_destroy :: proc(value: ^Library_Purge_Status) {
	delete(value.required_tombstone_ids)
	delete(value.blocking_device_ids)
	value^ = {}
}

library_add_device_if_missing :: proc(
	devices: ^[dynamic]Library_Device_State,
	device_id: string,
) -> int {
	if index, found := library_device_index(devices[:], device_id); found {return index}
	append(devices, Library_Device_State{device_id=device_id})
	return len(devices) - 1
}

library_event_is_membership :: proc(event: ^Library_Event) -> bool {
	return event.kind == LIBRARY_EVENT_DEVICE_JOIN ||
	       event.kind == LIBRARY_EVENT_DEVICE_RETIRE
}

library_note_revision_index :: proc(
	revisions: []Library_Note_Revision,
	revision_id: string,
) -> (int, bool) {
	for revision, index in revisions {
		if revision.revision_id == revision_id {return index, true}
	}
	return -1, false
}

library_materialize_capture_events :: proc(
	state: ^Library_Capture_State,
	record: ^Library_Capture_Record,
	events: []Library_Event,
	allocator: runtime.Allocator,
) {
	revisions := make([dynamic]Library_Note_Revision, 0, len(state.event_indices)+1, allocator)
	defer delete(revisions)
	append(&revisions, Library_Note_Revision{
		revision_id = record.capture_id,
		note = record.initial_note,
		event_index = -1,
		accepted = true,
	})

	for event_index in state.event_indices {
		event := &events[event_index]
		if event.kind != LIBRARY_EVENT_NOTE_SET {continue}
		append(&revisions, Library_Note_Revision{
			revision_id = event.event_id,
			note = event.note,
			event_index = event_index,
		})
	}

	changed := true
	for changed {
		changed = false
		for &revision in revisions[1:] {
			if revision.accepted {continue}
			event := &events[revision.event_index]
			predecessors_available := true
			for predecessor in event.predecessor_revisions {
				index, found := library_note_revision_index(revisions[:], predecessor)
				if !found || !revisions[index].accepted {
					predecessors_available = false
					break
				}
			}
			if predecessors_available {
				revision.accepted = true
				changed = true
			}
		}
	}

	for revision in revisions {
		if !revision.accepted {continue}
		is_head := true
		for child in revisions[1:] {
			if !child.accepted {continue}
			event := &events[child.event_index]
			for predecessor in event.predecessor_revisions {
				if predecessor == revision.revision_id {
					is_head = false
					break
				}
			}
			if !is_head {break}
		}
		if is_head {
			append(&state.note_heads, Library_Note_Head{
				revision_id = revision.revision_id,
				note = revision.note,
			})
		}
	}
	slice.sort_by(state.note_heads[:], proc(a, b: Library_Note_Head) -> bool {
		return a.revision_id < b.revision_id
	})
	state.note_conflict = len(state.note_heads) > 1
	if len(state.note_heads) > 0 {state.note = state.note_heads[0].note}

	for event_index in state.event_indices {
		event := &events[event_index]
		if event.kind != LIBRARY_EVENT_CAPTURE_DELETE {continue}
		restored := false
		for restore_index in state.event_indices {
			restore := &events[restore_index]
			if restore.kind == LIBRARY_EVENT_CAPTURE_RESTORE &&
			   restore.target_event_id == event.event_id {
				restored = true
				break
			}
		}
		if !restored {append(&state.effective_delete_ids, event.event_id)}
	}
	slice.sort(state.effective_delete_ids[:])
	state.deleted = len(state.effective_delete_ids) > 0
}

library_materialize :: proc(
	genesis: ^Library_Genesis,
	records: []Library_Capture_Record,
	events: []Library_Event,
	allocator := context.allocator,
) -> Library_Materialized {
	result := Library_Materialized{
		devices = make([dynamic]Library_Device_State, allocator),
		captures = make([dynamic]Library_Capture_State, allocator),
		accepted_event_indices = make([dynamic]int, allocator),
		pending_event_indices = make([dynamic]int, allocator),
		stream_faults = make([dynamic]Library_Stream_Fault, allocator),
		document_faults = make([dynamic]Library_Document_Fault, allocator),
		allocator = allocator,
	}
	operations := make([dynamic]Library_Operation_Ref, 0, len(records)+len(events), allocator)
	defer delete(operations)

	library_add_device_if_missing(&result.devices, genesis.initial_device_id)
	for &record, index in records {
		if library_capture_validate(&record, genesis.library_id) != .None {continue}
		library_add_device_if_missing(&result.devices, record.device_id)
		append(&operations, Library_Operation_Ref{
			kind = .Capture,
			index = index,
			device_id = record.device_id,
			device_sequence = record.device_sequence,
			document_id = record.capture_id,
		})
	}
	for &event, index in events {
		if library_event_validate(&event, genesis.library_id) != .None {continue}
		library_add_device_if_missing(&result.devices, event.device_id)
		if len(event.target_device_id) > 0 {
			library_add_device_if_missing(&result.devices, event.target_device_id)
		}
		append(&operations, Library_Operation_Ref{
			kind = .Event,
			index = index,
			device_id = event.device_id,
			device_sequence = event.device_sequence,
			document_id = event.event_id,
		})
	}

	slice.sort_by(operations[:], proc(a, b: Library_Operation_Ref) -> bool {
		if a.device_id != b.device_id {return a.device_id < b.device_id}
		if a.device_sequence != b.device_sequence {return a.device_sequence < b.device_sequence}
		if a.kind != b.kind {return a.kind < b.kind}
		return a.document_id < b.document_id
	})

	operation_index := 0
	for operation_index < len(operations) {
		group_end := operation_index + 1
		for group_end < len(operations) &&
		   operations[group_end].device_id == operations[operation_index].device_id &&
		   operations[group_end].device_sequence == operations[operation_index].device_sequence {
			group_end += 1
		}
		group_equivalent := true
		for &candidate in operations[operation_index+1:group_end] {
			if !library_operation_equivalent(
				&operations[operation_index],
				&candidate,
				records,
				events,
			) {
				group_equivalent = false
				break
			}
		}
		device_index, _ := library_device_index(result.devices[:], operations[operation_index].device_id)
		device := &result.devices[device_index]
		if !group_equivalent {
			append(&result.stream_faults, Library_Stream_Fault{
				device_id = device.device_id,
				sequence = operations[operation_index].device_sequence,
				reason = "sequence collision",
			})
		} else if operations[operation_index].device_sequence == device.sequence_prefix + 1 {
			operations[operation_index].prefix_complete = true
			device.sequence_prefix += 1
		}
		operation_index = group_end
	}

	initial_index, _ := library_device_index(result.devices[:], genesis.initial_device_id)
	result.devices[initial_index].authorized = true
	changed := true
	for changed {
		changed = false
		for operation in operations {
			if !operation.prefix_complete || operation.kind != .Event {continue}
			event := &events[operation.index]
			if event.kind != LIBRARY_EVENT_DEVICE_JOIN {continue}
			author_index, _ := library_device_index(result.devices[:], event.device_id)
			if !result.devices[author_index].authorized {continue}
			target_index, _ := library_device_index(result.devices[:], event.target_device_id)
			if !result.devices[target_index].authorized {
				result.devices[target_index].authorized = true
				changed = true
			}
		}
	}

	for &device in result.devices {
		device.accepted_cutoff = device.sequence_prefix
	}
	for operation in operations {
		if !operation.prefix_complete || operation.kind != .Event {continue}
		event := &events[operation.index]
		if event.kind != LIBRARY_EVENT_DEVICE_RETIRE {continue}
		author_index, _ := library_device_index(result.devices[:], event.device_id)
		if !result.devices[author_index].authorized {continue}
		target_index, found := library_device_index(result.devices[:], event.target_device_id)
		if !found || !result.devices[target_index].authorized {continue}
		target := &result.devices[target_index]
		target.retired = true
		target.accepted_cutoff = min(target.accepted_cutoff, event.target_device_sequence)
	}

	for &operation in operations {
		if !operation.prefix_complete {continue}
		device_index, _ := library_device_index(result.devices[:], operation.device_id)
		device := &result.devices[device_index]
		if !device.authorized || operation.device_sequence > device.accepted_cutoff {continue}
		operation.accepted = true
		if operation.kind == .Event {
			append(&result.accepted_event_indices, operation.index)
		}
	}
	for left_index in 0..<len(operations) {
		left := &operations[left_index]
		if !left.accepted {continue}
		for right_index in left_index+1..<len(operations) {
			right := &operations[right_index]
			if !right.accepted || left.document_id != right.document_id {continue}
			append(&result.document_faults, Library_Document_Fault{
				document_id = left.document_id,
				reason = "document identifier collision",
			})
			left.accepted = false
			right.accepted = false
		}
	}
	clear(&result.accepted_event_indices)
	for operation in operations {
		if operation.accepted && operation.kind == .Event {
			append(&result.accepted_event_indices, operation.index)
		}
	}

	for operation in operations {
		if !operation.accepted || operation.kind != .Capture {continue}
		record := &records[operation.index]
		duplicate := false
		for state in result.captures {
			if records[state.record_index].capture_id == record.capture_id {
				duplicate = true
				break
			}
		}
		if duplicate {continue}
		append(&result.captures, Library_Capture_State{
			record_index = operation.index,
			capture_id = record.capture_id,
			captured_at_unix_ms = record.captured_at_unix_ms,
			note_heads = make([dynamic]Library_Note_Head, allocator),
			effective_delete_ids = make([dynamic]string, allocator),
			event_indices = make([dynamic]int, allocator),
		})
	}

	for event_index in result.accepted_event_indices {
		event := &events[event_index]
		if len(event.capture_id) == 0 {continue}
		if capture_index, found := library_capture_index(result.captures[:], records, event.capture_id); found {
			append(&result.captures[capture_index].event_indices, event_index)
		} else {
			append(&result.pending_event_indices, event_index)
		}
	}

	for &state in result.captures {
		library_materialize_capture_events(
			&state,
			&records[state.record_index],
			events,
			allocator,
		)
	}
	slice.sort_by(result.captures[:], proc(a, b: Library_Capture_State) -> bool {
		if a.captured_at_unix_ms != b.captured_at_unix_ms {
			return a.captured_at_unix_ms > b.captured_at_unix_ms
		}
		return a.capture_id < b.capture_id
	})
	return result
}

library_frontier_sequence :: proc(
	frontier: []Library_Frontier_Entry,
	device_id: string,
) -> (u64, bool) {
	for entry in frontier {
		if entry.device_id == device_id {return entry.sequence, true}
	}
	return 0, false
}

library_accepted_event_by_id :: proc(
	state: ^Library_Materialized,
	events: []Library_Event,
	event_id: string,
) -> (^Library_Event, bool) {
	for event_index in state.accepted_event_indices {
		event := &events[event_index]
		if event.event_id == event_id {return event, true}
	}
	return nil, false
}

library_purge_commit_validate :: proc(
	state: ^Library_Materialized,
	events: []Library_Event,
	commit: ^Library_Event,
) -> Library_Purge_Commit_Status {
	if commit == nil || commit.kind != LIBRARY_EVENT_OBJECT_PURGE {
		return .Proposal_Missing
	}
	proposal, proposal_found := library_accepted_event_by_id(
		state,
		events,
		commit.target_event_id,
	)
	if !proposal_found || proposal.kind != LIBRARY_EVENT_PURGE_PROPOSE {
		return .Proposal_Missing
	}
	if proposal.object_digest != commit.object_digest ||
	   !library_string_slices_equal(proposal.required_event_ids, commit.required_event_ids) ||
	   !library_string_slices_equal(proposal.active_device_ids, commit.active_device_ids) {
		return .Proposal_Mismatch
	}
	if commit.created_at_unix_ms < proposal.purge_not_before_unix_ms {
		return .Too_Early
	}
	for event_index in state.accepted_event_indices {
		event := &events[event_index]
		if event.kind == LIBRARY_EVENT_PURGE_REJECT &&
		   event.target_event_id == proposal.event_id {
			return .Rejected
		}
	}
	if len(commit.proof_event_ids) != len(commit.active_device_ids) {
		return .Proof_Mismatch
	}
	for device_id in commit.active_device_ids {
		matching_ack_count := 0
		for proof_event_id in commit.proof_event_ids {
			proof, proof_found := library_accepted_event_by_id(state, events, proof_event_id)
			if !proof_found || proof.kind != LIBRARY_EVENT_PURGE_ACK ||
			   proof.target_event_id != proposal.event_id {
				continue
			}
			if proof.device_id == device_id {
				matching_ack_count += 1
				commit_sequence, covered := library_frontier_sequence(
					commit.frontier,
					proof.device_id,
				)
				if !covered || commit_sequence < proof.device_sequence {
					return .Frontier_Mismatch
				}
			}
		}
		if matching_ack_count != 1 {return .Proof_Mismatch}
	}
	proposal_sequence, proposal_covered := library_frontier_sequence(
		commit.frontier,
		proposal.device_id,
	)
	if !proposal_covered || proposal_sequence < proposal.device_sequence {
		return .Frontier_Mismatch
	}
	return .None
}

library_object_has_valid_purge_commit :: proc(
	state: ^Library_Materialized,
	events: []Library_Event,
	object_digest: string,
) -> (string, bool) {
	best: ^Library_Event
	for event_index in state.accepted_event_indices {
		event := &events[event_index]
		if event.kind != LIBRARY_EVENT_OBJECT_PURGE ||
		   event.object_digest != object_digest ||
		   library_purge_commit_validate(state, events, event) != .None {
			continue
		}
		if best == nil || event.created_at_unix_ms > best.created_at_unix_ms ||
		   (event.created_at_unix_ms == best.created_at_unix_ms && event.event_id > best.event_id) {
			best = event
		}
	}
	if best == nil {return "", false}
	return best.event_id, true
}

library_object_current_purge_commit :: proc(
	state: ^Library_Materialized,
	records: []Library_Capture_Record,
	events: []Library_Event,
	object_digest: string,
) -> (string, bool) {
	commit_id, committed := library_object_has_valid_purge_commit(
		state,
		events,
		object_digest,
	)
	if !committed {return "", false}
	for capture in state.captures {
		record := &records[capture.record_index]
		if record.object_digest == object_digest &&
		   record.reinstates_purge_event_id == commit_id {
			return "", false
		}
	}
	return commit_id, true
}

library_apply_purge_object_states :: proc(
	state: ^Library_Materialized,
	records: []Library_Capture_Record,
	events: []Library_Event,
	object_states: []Library_Object_State,
) {
	for capture in state.captures {
		record := &records[capture.record_index]
		if object_states[capture.record_index] != .Missing {continue}
		all_references_deleted := true
		for other_capture in state.captures {
			other_record := &records[other_capture.record_index]
			if other_record.object_digest == record.object_digest && !other_capture.deleted {
				all_references_deleted = false
				break
			}
		}
		if !all_references_deleted {continue}
		if _, purged := library_object_current_purge_commit(
			state,
			records,
			events,
			record.object_digest,
		); purged {
			for matching_capture in state.captures {
				matching_record := &records[matching_capture.record_index]
				if matching_record.object_digest == record.object_digest &&
				   object_states[matching_capture.record_index] == .Missing {
					object_states[matching_capture.record_index] = .Purged
				}
			}
		}
	}
}

library_latest_ack :: proc(
	state: ^Library_Materialized,
	events: []Library_Event,
	device_id: string,
) -> (^Library_Event, bool) {
	best: ^Library_Event
	for event_index in state.accepted_event_indices {
		event := &events[event_index]
		if event.device_id != device_id || event.kind != LIBRARY_EVENT_DEVICE_ACK {continue}
		if best == nil || event.device_sequence > best.device_sequence {best = event}
	}
	return best, best != nil
}

library_object_purge_status :: proc(
	state: ^Library_Materialized,
	records: []Library_Capture_Record,
	events: []Library_Event,
	object_digest: string,
	now_unix_ms: i64,
	allocator := context.allocator,
) -> Library_Purge_Status {
	status := Library_Purge_Status{
		required_tombstone_ids = make([dynamic]string, allocator),
		blocking_device_ids = make([dynamic]string, allocator),
		allocator = allocator,
	}
	reference_count := 0
	required_sequences := make(map[string]u64, allocator)
	defer delete(required_sequences)

	for capture in state.captures {
		record := &records[capture.record_index]
		if record.object_digest != object_digest {continue}
		reference_count += 1
		if !capture.deleted {
			status.block = .Live_Reference
			return status
		}
		required_sequences[record.device_id] = max(
			required_sequences[record.device_id],
			record.device_sequence,
		)
		for tombstone_id in capture.effective_delete_ids {
			append(&status.required_tombstone_ids, tombstone_id)
			for event_index in capture.event_indices {
				event := &events[event_index]
				if event.event_id != tombstone_id {continue}
				status.not_before_unix_ms = max(
					status.not_before_unix_ms,
					event.created_at_unix_ms + LIBRARY_RECOVERY_INTERVAL_SECONDS * 1000,
				)
				required_sequences[event.device_id] = max(
					required_sequences[event.device_id],
					event.device_sequence,
				)
				break
			}
		}
	}
	if reference_count == 0 {
		status.block = .No_References
		return status
	}
	if now_unix_ms < status.not_before_unix_ms {
		status.block = .Recovery_Interval
		return status
	}
	slice.sort(status.required_tombstone_ids[:])

	for device in state.devices {
		if !device.authorized || device.retired {continue}
		ack, found := library_latest_ack(state, events, device.device_id)
		if !found {
			append(&status.blocking_device_ids, device.device_id)
			continue
		}
		complete := true
		for active_device in state.devices {
			if !active_device.authorized || active_device.retired {continue}
			_, present := library_frontier_sequence(ack.frontier, active_device.device_id)
			if !present {
				complete = false
				break
			}
		}
		for author_device_id, required_sequence in required_sequences {
			if !complete {break}
			ack_sequence, present := library_frontier_sequence(ack.frontier, author_device_id)
			if !present || ack_sequence < required_sequence {
				complete = false
				break
			}
		}
		if !complete {append(&status.blocking_device_ids, device.device_id)}
	}
	if len(status.blocking_device_ids) > 0 {
		slice.sort(status.blocking_device_ids[:])
		status.block = .Missing_Device_Acknowledgement
		return status
	}
	status.block = .None
	return status
}
