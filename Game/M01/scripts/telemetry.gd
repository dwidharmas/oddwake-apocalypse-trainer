class_name M01Telemetry
extends RefCounted

const SCHEMA := "m01.1"
const TYPE_NAMES := {
	1: "REQUEST", 2: "REJECT", 3: "RESPONSE", 4: "PRESSURE", 5: "PLAN",
	6: "ACTION_START", 7: "COST", 8: "DUE", 9: "COMMIT", 10: "CANCEL",
	11: "IMPACT", 12: "DAMAGE", 13: "HEAL", 14: "RESOURCE_BAND", 15: "BRACE",
	16: "VISION", 17: "SEARCH", 18: "CONTROL", 19: "KO", 20: "ENCOUNTER_END",
	21: "CHECKPOINT", 22: "LIFECYCLE", 23: "NPC_DECISION", 24: "NPC_SUBMISSION",
	25: "PHYSICAL_LOCK", 26: "BOUND_TRAVEL",
}

const DICTIONARIES := {
	"family": {"1": "Attack", "2": "Defense", "3": "Run"},
	"knowledge": {"0": "unknown", "1": "last_known", "2": "visible"},
	"life": {"0": "alive", "1": "KO"},
	"control": {"0": "trainer_allowed", "1": "normal_demigod_lock", "2": "doomsday_lock"},
	"target_kind": {"0": "none", "1": "self", "2": "known_entity", "3": "known_area"},
	"end_reason": {"1": "single_ko", "2": "mutual_ko", "3": "diagnostic_timeout", "4": "aborted"},
	"response": {"1": "ignored", "2": "misinterpreted", "3": "declined",
		"4": "understood_hesitant", "5": "understood_normal", "6": "understood_strong"},
	"hp_band": {"0": "KO", "1": "Critical", "2": "Wounded", "3": "Hurt", "4": "Healthy"},
	"stam_band": {"0": "Empty", "1": "Low", "2": "Steady", "3": "High"},
	"fatigue_band": {"0": "Fresh", "1": "Strained", "2": "Exhausted"},
	"int_band": {"0": "Simple", "1": "Aware", "2": "Clever"},
	"instinct_band": {"0": "Clumsy", "1": "Reactive", "2": "Sharp"},
	"facing": {"0": "north", "1": "east", "2": "south", "3": "west"},
	"action_state": {"1": "preparing", "2": "due", "3": "committed", "4": "recovering", "5": "cancelled"},
	"fit_reason": ["attack", "escape", "hold_ground", "neutral_defense", "guard", "run",
		"disengage", "search", "scout", "rest", "unavailable"],
	"safe_reason": ["exhausted", "busy", "finishing_current_action", "cannot_reach",
		"obstructed", "target_lost", "technique_unavailable", "recovering", "not_ready",
		"guarding", "can_move_again", "authority_locked"],
	"reject_reason": ["ownership", "control", "life", "sequence", "slot", "hint", "envelope"],
}

var header := {}
var lines: Array[String] = []
var events: Array = []
var sequence := 0
var last_tick := 0
var expected_count := 0
var lost_count := 0
var queue_peak := 0
var overflowed := false
var writer_error := false
var disabled := false
var type_counts := {}
var active_ticks := 0
var capture_complete := true
var footer := {}
var prepared_bytes: PackedByteArray = PackedByteArray()
var notes: Array[String] = []

var event_bytes_total := 0
var active_window_start_tick := -1
var active_bytes_window := 0
var active_events_window := 0
var active_rate_peak := 0.0
var active_bytes_rate_peak := 0.0
var idle_max_bytes := 0
var idle_window_bytes := 0
var sim_ms_samples: Array[float] = []
var frame_ms_samples: Array[float] = []


func reset() -> void:
	header = {}
	lines.clear()
	events.clear()
	sequence = 0
	last_tick = 0
	expected_count = 0
	lost_count = 0
	queue_peak = 0
	overflowed = false
	writer_error = false
	disabled = false
	type_counts.clear()
	active_ticks = 0
	capture_complete = true
	footer = {}
	prepared_bytes = PackedByteArray()
	notes.clear()
	event_bytes_total = 0
	active_window_start_tick = -1
	active_bytes_window = 0
	active_events_window = 0
	active_rate_peak = 0.0
	active_bytes_rate_peak = 0.0
	idle_max_bytes = 0
	idle_window_bytes = 0
	sim_ms_samples.clear()
	frame_ms_samples.clear()


func build_header(setup: Dictionary) -> void:
	header = {
		"schema": SCHEMA,
		"kind": "header",
		"mode": setup.get("mode", "live"),
		"fixture_id": setup.get("fixture_id", null),
		"tick_rate": 60,
		"engine": setup.get("engine", "unknown"),
		"build": setup.get("build", "m01-r01"),
		"platform": setup.get("platform", OS.get_name()),
		"browser": setup.get("browser", ""),
		"role_hashes": setup.get("role_hashes", {}),
		"content_hashes": setup.get("content_hashes", {}),
		"map_hash": setup.get("map_hash", ""),
		"tuning_hash": setup.get("tuning_hash", ""),
		"root_seed": str(setup.get("root_seed", 0)),
		"stream_seeds": setup.get("stream_seeds", {}),
		"stream_draw_counts": setup.get("stream_draw_counts", {}),
		"initial_state": setup.get("initial_state", {}),
		"loadouts": setup.get("loadouts", []),
		"event_dictionaries": DICTIONARIES,
		"units": {"tick": 60, "resource": "cp100", "distance": "mWU1000",
			"pressure": "thirtieths", "fatigue": "centi", "mitigation": "bp10000"},
		"ticks": setup.get("compiled_ticks", {}),
	}
	lines.append(JSON.stringify(header))


func emit(tick: int, type_id: int, payload: Array, diagnostic: bool = false) -> void:
	if disabled:
		return
	if events.size() >= 4096 or event_bytes_total >= 8388608:
		overflowed = true
		capture_complete = false
		lost_count += 1
		return
	var delta := tick - last_tick
	var envelope := [delta, sequence, type_id, payload]
	var text := JSON.stringify(envelope)
	var byte_len := text.length()
	if event_bytes_total + byte_len > 8388608:
		overflowed = true
		capture_complete = false
		lost_count += 1
		return
	last_tick = tick
	sequence += 1
	expected_count += 1
	events.append(envelope)
	lines.append(text)
	event_bytes_total += byte_len
	type_counts[type_id] = int(type_counts.get(type_id, 0)) + 1
	queue_peak = maxi(queue_peak, events.size())
	_track_rate(tick, byte_len)
	if type_id == 21:
		return
	if diagnostic:
		notes.append("diagnostic event %d at tick %d" % [type_id, tick])


func _track_rate(tick: int, byte_len: int) -> void:
	if active_window_start_tick < 0:
		active_window_start_tick = tick
		active_bytes_window = 0
		active_events_window = 0
	var span := tick - active_window_start_tick
	active_bytes_window += byte_len
	active_events_window += 1
	if span >= 60:
		var secs := span / 60.0
		active_rate_peak = maxf(active_rate_peak, active_events_window / secs)
		active_bytes_rate_peak = maxf(active_bytes_rate_peak, (active_bytes_window * 60.0) / span)
		active_window_start_tick = tick
		active_bytes_window = 0
		active_events_window = 0


func mark_activity(active_ticks_value: int) -> void:
	active_ticks = active_ticks_value


func note(msg: String) -> void:
	notes.append(msg)


func close_footer(summary: Dictionary, complete: bool) -> void:
	capture_complete = capture_complete and complete and not overflowed and not writer_error
	footer = {
		"schema": SCHEMA,
		"kind": "footer",
		"last_sequence": sequence - 1,
		"last_tick": last_tick,
		"expected_events": expected_count,
		"serialized_events": lines.size() - 1,
		"lost_events": lost_count,
		"writer_error": writer_error,
		"overflow": overflowed,
		"completeness": "complete" if capture_complete else "incomplete",
		"event_counts_by_type": type_counts,
		"queue_peak": queue_peak,
		"event_bytes": event_bytes_total,
		"summary": summary,
	}
	if sequence - 1 != expected_count - 1:
		capture_complete = false
		footer["completeness"] = "incomplete"
	lines.append(JSON.stringify(footer))


func bundle_text() -> String:
	return "\n".join(lines) + "\n"


func prepare_bundle() -> Dictionary:
	if lines.is_empty():
		return {"ok": false, "stage": "capture", "reason": "no capture available"}
	if not footer.has("kind"):
		return {"ok": false, "stage": "serialization", "reason": "footer missing; capture incomplete"}
	var text := bundle_text()
	var bytes := text.to_utf8_buffer()
	if bytes.is_empty():
		return {"ok": false, "stage": "serialization", "reason": "serialization produced no bytes"}
	prepared_bytes = bytes
	return {"ok": true, "bytes": bytes.size(), "sha256": _sha256(bytes)}


static func _sha256(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func canonical_value(v: Variant, depth: int = 0) -> Variant:
	if depth > 32:
		return "<depth>"
	if v == null:
		return null
	if v is bool or v is int:
		return v
	if v is float:
		return snappedf(v, 0.000001)
	if v is String or v is StringName:
		return str(v)
	if v is Array:
		var out := []
		for e in v as Array:
			out.append(canonical_value(e, depth + 1))
		return out
	if v is Dictionary:
		var keys: Array = []
		for k in (v as Dictionary).keys():
			keys.append(str(k))
		keys.sort()
		var out := {}
		for k in keys:
			out[k] = canonical_value((v as Dictionary)[k], depth + 1)
		return out
	return str(v)


static func canonical_state_sha256(state: Dictionary) -> String:
	var text := JSON.stringify(canonical_value(state))
	return text.sha256_text()


static func decode_bundle(text: String) -> Dictionary:
	var result := {"ok": false, "header": null, "events": [], "footer": null, "errors": []}
	var parts := text.split("\n")
	var first := true
	for raw in parts:
		if raw.strip_edges().is_empty():
			continue
		var parsed: Variant = JSON.parse_string(raw)
		if parsed == null:
			(result["errors"] as Array).append("line parse failed")
			continue
		if first:
			result["header"] = parsed
			first = false
			continue
		if parsed is Dictionary and (parsed as Dictionary).get("kind") == "footer":
			result["footer"] = parsed
			continue
		if parsed is Array and (parsed as Array).size() == 4:
			(result["events"] as Array).append(parsed)
		else:
			(result["errors"] as Array).append("unexpected line shape")
	if result["header"] != null and result["footer"] != null and (result["errors"] as Array).is_empty():
		result["ok"] = true
	return result
