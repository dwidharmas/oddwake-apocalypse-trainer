class_name M01Telemetry
extends RefCounted

const SCHEMA := "m01.1"
const SCHEMA_EXPANDED := "m01.2"
const TYPE_NAMES := {
	1: "REQUEST", 2: "REJECT", 3: "RESPONSE", 4: "PRESSURE", 5: "PLAN",
	6: "ACTION_START", 7: "COST", 8: "DUE", 9: "COMMIT", 10: "CANCEL",
	11: "IMPACT", 12: "DAMAGE", 13: "HEAL", 14: "RESOURCE_BAND", 15: "BRACE",
	16: "VISION", 17: "SEARCH", 18: "CONTROL", 19: "KO", 20: "ENCOUNTER_END",
	21: "CHECKPOINT", 22: "LIFECYCLE", 23: "NPC_DECISION", 24: "NPC_SUBMISSION",
	25: "PHYSICAL_LOCK", 26: "BOUND_TRAVEL", 27: "BABY_LIFECYCLE", 28: "HUNT_REWARD",
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
	"entity_ids": {"0": "monster0", "1": "monster1", "2": "prey0", "3": "prey1"},
	"baby_transition": ["monster_down", "return_wait", "monster_return", "prey_depleted",
		"spawn_wait", "prey_spawn"],
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
var schema := SCHEMA
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
	schema = str(setup.get("schema", SCHEMA))
	header = {
		"schema": schema,
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
	if schema == SCHEMA_EXPANDED:
		header["entity_map"] = DICTIONARIES["entity_ids"]
		header["target_ref"] = {"encoding": "0/1 monster, 2/3 prey",
			"fields": ["kind", "id", "life_id"]}
		header["event_definitions"] = {
			"27": "BABY_LIFECYCLE[transition,entity,old_life,new_life,due,position,batch]",
			"28": "HUNT_REWARD[slot,prey_life,winner,lifetime_damage,first_positive,group_damage,group_allocated,ordinal,atk_delta,exp_delta,cum_atk,cum_exp]",
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
		"schema": schema,
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
	var result := {"ok": false, "schema": "", "header": null, "events": [], "footer": null, "errors": []}
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
	var header: Variant = result["header"]
	var footer: Variant = result["footer"]
	if not (header is Dictionary):
		(result["errors"] as Array).append("missing header")
		return result
	var header_schema := str((header as Dictionary).get("schema", ""))
	result["schema"] = header_schema
	if header_schema != SCHEMA and header_schema != SCHEMA_EXPANDED:
		(result["errors"] as Array).append("unsupported schema '%s'" % header_schema)
		return result
	if header_schema == SCHEMA_EXPANDED and not (header as Dictionary).has("entity_map"):
		(result["errors"] as Array).append("expanded header missing entity_map")
	if not (footer is Dictionary):
		(result["errors"] as Array).append("missing footer")
		return result
	if str((footer as Dictionary).get("schema", "")) != header_schema:
		(result["errors"] as Array).append("footer/header schema mismatch")
	var expanded := header_schema == SCHEMA_EXPANDED
	if expanded:
		var em: Variant = (header as Dictionary).get("entity_map", null)
		var expected_map := {"0": "monster0", "1": "monster1", "2": "prey0", "3": "prey1"}
		if not (em is Dictionary) or (em as Dictionary).size() != 4:
			(result["errors"] as Array).append("expanded header entity_map is not the fixed 4-entry map")
		else:
			for k in expected_map:
				if str((em as Dictionary).get(k, "")) != str(expected_map[k]):
					(result["errors"] as Array).append("expanded entity_map entry %s is not %s" % [
						k, expected_map[k]])
	for ev in result["events"] as Array:
		var type_raw: Variant = (ev as Array)[2]
		if not _exact_int(type_raw):
			(result["errors"] as Array).append("non-integral event type %s" % str(type_raw))
			continue
		var type_id := int(type_raw)
		if not TYPE_NAMES.has(type_id):
			(result["errors"] as Array).append("unsupported event type %d" % type_id)
			continue
		if not expanded and type_id > 26:
			(result["errors"] as Array).append("m01.1 bundle carries expanded event %d" % type_id)
			continue
		if expanded and not _expanded_shape_ok(type_id, (ev as Array)[3]):
			(result["errors"] as Array).append("unsupported %s shape" % TYPE_NAMES[type_id])
	if result["header"] != null and result["footer"] != null and (result["errors"] as Array).is_empty():
		result["ok"] = true
	return result


## R3: JSON numbers arrive as floats. Accept only EXACT finite integrals within the supported
## conversion range, then normalize; no epsilon acceptance and no fractional truncation.
static func _num(v: Variant) -> bool:
	return v is int or (v is float and not is_nan(v) and not is_inf(v))


static func _exact_int(v: Variant) -> bool:
	if v is int:
		return true
	if v is float:
		if is_nan(v) or is_inf(v):
			return false
		if absf(v) > 9007199254740992.0:
			return false
		return float(int(v)) == v
	return false


static func _intlike(v: Variant) -> bool:
	return _exact_int(v)


static func _posint(v: Variant) -> bool:
	return _exact_int(v) and int(v) > 0


static func _nonnegint(v: Variant) -> bool:
	return _exact_int(v) and int(v) >= 0


static func _in_set(v: Variant, allowed: Array) -> bool:
	if not _exact_int(v):
		return false
	return allowed.has(int(v))


static func _entity(v: Variant) -> bool:
	return _exact_int(v) and int(v) >= 0 and int(v) <= 3


static func _monster_entity(v: Variant) -> bool:
	return _exact_int(v) and (int(v) == 0 or int(v) == 1)


static func _prey_entity(v: Variant) -> bool:
	return _exact_int(v) and (int(v) == 2 or int(v) == 3)


static func _pair_finite(v: Variant) -> bool:
	if v == null:
		return true
	if not (v is Array) or (v as Array).size() != 2:
		return false
	return _num((v as Array)[0]) and _num((v as Array)[1])


static func _pair_int2(v: Variant, minv: int) -> bool:
	if v == null:
		return false
	if not (v is Array) or (v as Array).size() != 2:
		return false
	return _exact_int((v as Array)[0]) and _exact_int((v as Array)[1]) \
		and int((v as Array)[0]) >= minv and int((v as Array)[1]) >= minv


static func _pair_int_or_null2(v: Variant, minv: int) -> bool:
	if not (v is Array) or (v as Array).size() != 2:
		return false
	for e in v as Array:
		if e == null:
			continue
		if not _exact_int(e) or int(e) < minv:
			return false
	return true


## Expanded event shapes are explicit: fixed entity mapping, per-event entity kinds, exact
## integral generations and transition/nullability relationships. Unrecognized combinations are
## never accepted as valid evidence.
static func _expanded_shape_ok(type_id: int, payload: Variant) -> bool:
	if not (payload is Array):
		return false
	var p := payload as Array
	match type_id:
		6:
			# 9 fields; actor is a monster; Quick's entity target needs a positive generation.
			if p.size() != 9 or not _monster_entity(p[1]):
				return false
			var sid := str(p[4])
			if sid == "quick_claw":
				if not _entity(p[5]) or not _posint(p[8]):
					return false
			elif sid == "brace":
				if p[5] != null or p[8] != null:
					return false
			elif sid == "short_bound":
				if not (p[5] is Array) or p[8] != null:
					return false
			else:
				if p[8] != null:
					return false
			return p[5] == null or _entity(p[5]) or _pair_finite(p[5])
		11:
			# 8 fields; target entity; valid hit needs a positive generation.
			if p.size() != 8 or not _entity(p[3]) or not _monster_entity(p[2]):
				return false
			var st := str(p[5])
			if st == "hit":
				return _posint(p[4])
			if st != "blocked" and st != "invalid_life":
				return false
			return p[4] == null or _posint(p[4])
		12:
			# 11 fields; target entity; target life positive; prey credit nullable pair.
			return p.size() == 11 and _entity(p[1]) and _posint(p[9]) \
				and (p[10] == null or _pair_int2(p[10], 0))
		19:
			return p.size() == 4 and _monster_entity(p[0]) and _posint(p[1])
		27:
			if p.size() != 7 or not (p[0] is String) \
					or not (DICTIONARIES["baby_transition"] as Array).has(str(p[0])):
				return false
			var tr := str(p[0])
			# S1: explicit mapping of every released transition to its entity class, including
			# the two wait names that carry neither a monster_/prey_ prefix.
			var monster_tr := ["monster_down", "return_wait", "monster_return"]
			var prey_tr := ["prey_depleted", "spawn_wait", "prey_spawn"]
			if monster_tr.has(tr):
				if not _monster_entity(p[1]):
					return false
			elif prey_tr.has(tr):
				if not _prey_entity(p[1]):
					return false
			else:
				return false
			if not _posint(p[2]) or not _posint(p[3]):
				return false
			var needs_due := tr in ["monster_down", "prey_depleted", "return_wait", "spawn_wait"]
			var needs_pos := tr in ["monster_down", "prey_depleted", "monster_return", "prey_spawn"]
			if needs_due:
				if not _posint(p[4]):
					return false
			elif p[4] != null:
				return false
			if needs_pos:
				if not (p[5] is Array) or not _pair_finite(p[5]):
					return false
			elif p[5] != null:
				return false
			return p[6] == null or _intlike(p[6])
		28:
			return p.size() == 12 and _in_set(p[0], [0, 1]) and _posint(p[1]) \
				and (p[2] == null or _in_set(p[2], [0, 1])) \
				and _pair_int2(p[3], 0) \
				and _pair_int_or_null2(p[4], 0) \
				and _pair_int2(p[5], 0) and _pair_int2(p[6], 0) \
				and (p[7] == null or _in_set(p[7], [1, 2, 3])) \
				and _nonnegint(p[8]) and _nonnegint(p[9]) \
				and (p[10] == null or _nonnegint(p[10])) \
				and (p[11] == null or _nonnegint(p[11]))
	return true
