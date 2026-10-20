class_name M01Content
extends RefCounted

const SCHEMA := "m01.1"
const SPECIES_PATH := "res://content/behemoth_base.json"
const SKILLS_PATH := "res://content/skills.json"
const ARENA_PATH := "res://content/arena.json"
const TUNING_PATH := "res://content/tuning.json"

const REQUIRED_SKILL_FIELDS := [
	"id", "revision", "family", "target_kind", "stam_cost_cp", "cooldown_ms",
	"charge_ms", "recovery_ms", "interrupt_power", "stability", "effect_kind", "feedback_id"
]

const REQUIRED_SPECIES_FIELDS := [
	"id", "revision", "hp_max_cp", "stam_max_cp", "atk", "def", "k_defense",
	"mov_mwu_per_s", "int_stat", "instinct", "bond", "radius_mwu",
	"learned_skills", "presentation_id"
]

var species := {}
var skills := {}
var arena := {}
var tuning := {}
var hashes := {}
var errors: Array[String] = []
var loaded := false

var compiled := {
	"charge_ticks": {},
	"cooldown_ticks": {},
	"recovery_ticks": {},
	"baby_prey_respawn_ticks": 0,
	"baby_return_ticks": 0,
	"baby_diagnostic_ticks": 0,
}
## Additive expanded-Baby section, compiled once at load. Empty for legacy content.
var baby_growth := {}
static func _read_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(path)


static func _sha256(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func _ms_to_ticks(ms: int) -> int:
	if ms <= 0:
		return 0
	return int(ceil(float(ms) * 60.0 / 1000.0)) if (ms * 60) % 1000 != 0 else (ms * 60) / 1000


static func _is_number(v: Variant) -> bool:
	return v is int or v is float


static func _bad_number(v: Variant) -> bool:
	if v is float:
		return is_nan(v) or is_inf(v)
	return false


func _err(where: String, msg: String) -> void:
	errors.append("%s: %s" % [where, msg])


func _require(rec: Dictionary, fields: Array, where: String) -> bool:
	var ok := true
	for f in fields:
		if not rec.has(f):
			_err(where, "missing required field '%s'" % f)
			ok = false
	return ok


func _require_nonneg(rec: Dictionary, fields: Array, where: String) -> bool:
	var ok := true
	for f in fields:
		if not rec.has(f):
			continue
		var v: Variant = rec[f]
		if not _is_number(v) or _bad_number(v) or (v is int and v < 0) or (v is float and v < 0.0):
			_err(where, "field '%s' must be a finite nonnegative number, got %s" % [f, str(v)])
			ok = false
	return ok


func load_from_disk() -> bool:
	errors.clear()
	loaded = false
	var payloads := {
		"species": SPECIES_PATH,
		"skills": SKILLS_PATH,
		"arena": ARENA_PATH,
		"tuning": TUNING_PATH,
	}
	for key in payloads:
		var path: String = payloads[key]
		var raw := _read_bytes(path)
		if raw.is_empty():
			_err(path, "file missing or empty")
			return false
		hashes[key] = _sha256(raw)
		var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
		if parsed == null or not (parsed is Dictionary):
			_err(path, "JSON parse failed")
			return false
		payloads[key] = parsed

	species = payloads["species"]
	arena = payloads["arena"]
	tuning = payloads["tuning"]
	var skills_doc: Dictionary = payloads["skills"]

	_validate_species()
	_validate_skills(skills_doc)
	_validate_arena()
	_validate_tuning()
	_validate_baby_growth()

	if errors.is_empty():
		_compile()
		loaded = true
	return errors.is_empty()


func _validate_species() -> void:
	if not _require(species, REQUIRED_SPECIES_FIELDS, "species"):
		return
	if species.get("schema") != SCHEMA:
		_err("species", "unknown schema '%s'" % str(species.get("schema")))
	_require_nonneg(species, ["hp_max_cp", "stam_max_cp", "atk", "def", "k_defense",
		"mov_mwu_per_s", "int_stat", "instinct", "bond", "radius_mwu"], "species")
	if int(species.get("hp_max_cp", 0)) <= 0 or int(species.get("stam_max_cp", 0)) <= 0:
		_err("species", "maxima must be positive")
	if int(species.get("radius_mwu", 0)) <= 0:
		_err("species", "radius must be positive")
	var learned: Variant = species.get("learned_skills")
	if not (learned is Array) or (learned as Array).size() != 3:
		_err("species", "learned_skills must list exactly 3 techniques for M01")
	elif (learned as Array).is_empty():
		_err("species", "learned_skills empty")


func _validate_skills(doc: Dictionary) -> void:
	if doc.get("schema") != SCHEMA:
		_err("skills", "unknown schema '%s'" % str(doc.get("schema")))
	var list: Variant = doc.get("skills")
	if not (list is Array):
		_err("skills", "missing 'skills' array")
		return
	if (list as Array).size() != 3:
		_err("skills", "M01 requires exactly 3 skill records, found %d" % (list as Array).size())
	var seen := {}
	for i in (list as Array).size():
		var rec: Variant = (list as Array)[i]
		if not (rec is Dictionary):
			_err("skills[%d]" % i, "record is not an object")
			continue
		var d := rec as Dictionary
		var where := "skills[%s]" % str(d.get("id", i))
		if not _require(d, REQUIRED_SKILL_FIELDS, where):
			continue
		var id := str(d["id"])
		if seen.has(id):
			_err(where, "duplicate skill id")
		seen[id] = true
		skills[id] = d
		if d.get("schema", SCHEMA) != SCHEMA and d.has("schema"):
			_err(where, "unknown schema")
		var fam := int(d["family"])
		if fam < 1 or fam > 3:
			_err(where, "family out of range: %d" % fam)
		_require_nonneg(d, ["stam_cost_cp", "cooldown_ms", "charge_ms", "recovery_ms",
			"interrupt_power", "stability"], where)
		if int(d["stam_cost_cp"]) <= 0:
			_err(where, "stam_cost_cp must be positive")
		if str(d["effect_kind"]) == "damage" and int(d.get("base_power_cp", 0)) <= 0:
			_err(where, "damage effect requires positive base_power_cp")
		if str(d["effect_kind"]) == "mitigate":
			var bp := int(d.get("mitigation_bp", 0))
			if bp <= 0 or bp >= 10000:
				_err(where, "mitigation_bp out of range")
			if int(d.get("active_boundaries", 0)) <= 0:
				_err(where, "active_boundaries must be positive")
		if str(d["effect_kind"]) == "travel":
			if int(d.get("max_travel_mwu", 0)) <= 0 or int(d.get("travel_boundaries", 0)) <= 0:
				_err(where, "travel requires positive max_travel_mwu and travel_boundaries")
		if int(d["charge_ms"]) > 0 and int(d.get("quick", 0)) == 1:
			_err(where, "quick skill cannot have a charge")
	var learned: Variant = species.get("learned_skills", [])
	if learned is Array:
		for sid in learned as Array:
			if not skills.has(str(sid)):
				_err("species.learned_skills", "unknown skill id '%s'" % str(sid))


func _validate_arena() -> void:
	if arena.get("schema") != SCHEMA:
		_err("arena", "unknown schema '%s'" % str(arena.get("schema")))
	var fields := ["width_mwu", "height_mwu", "body_radius_mwu", "contact_distance_mwu",
		"inset_min_x", "inset_max_x", "inset_min_y", "inset_max_y",
		"blocker_min_x", "blocker_max_x", "blocker_min_y", "blocker_max_y",
		"blocker_inflated_min_x", "blocker_inflated_max_x", "blocker_inflated_min_y",
		"blocker_inflated_max_y", "vision_range_mwu", "nav_cell_mwu", "nav_cols", "nav_rows"]
	if not _require(arena, fields, "arena"):
		return
	_require_nonneg(arena, fields, "arena")
	if int(arena["width_mwu"]) <= 0 or int(arena["height_mwu"]) <= 0:
		_err("arena", "play rectangle must be positive")
	var spawn: Variant = arena.get("spawn")
	if not (spawn is Array) or (spawn as Array).size() != 2:
		_err("arena", "spawn must have exactly 2 entries")
	else:
		for i in 2:
			var p: Variant = (spawn as Array)[i]
			if not (p is Array) or (p as Array).size() != 2:
				_err("arena", "spawn[%d] malformed" % i)
	var patrol: Variant = arena.get("patrol")
	if not (patrol is Array) or (patrol as Array).size() != 4:
		_err("arena", "patrol must have exactly 4 entries")
	if int(arena["blocker_min_x"]) >= int(arena["blocker_max_x"]) or \
			int(arena["blocker_min_y"]) >= int(arena["blocker_max_y"]):
		_err("arena", "blocker rectangle is empty")
	if int(arena["inset_min_x"]) >= int(arena["inset_max_x"]) or \
			int(arena["inset_min_y"]) >= int(arena["inset_max_y"]):
		_err("arena", "inset rectangle is empty")


func _validate_tuning() -> void:
	if tuning.get("schema") != SCHEMA:
		_err("tuning", "unknown schema '%s'" % str(tuning.get("schema")))
	var required := ["tick_rate", "timeout_active_ticks", "response", "pressure", "fatigue",
		"exhaustion", "regen", "utility", "npc", "vision", "defense_fit", "telemetry",
		"performance", "presentation", "slots"]
	for f in required:
		if not tuning.has(f):
			_err("tuning", "missing required section '%s'" % f)
	if int(tuning.get("tick_rate", 0)) != 60:
		_err("tuning", "tick_rate must be 60 for M01")
	var slots: Variant = tuning.get("slots")
	if slots is Dictionary:
		var s := slots as Dictionary
		if int(s.get("total", 0)) != 8:
			_err("tuning.slots", "total must be 8")
		var filled: Variant = s.get("filled")
		if not (filled is Array) or (filled as Array).size() != 3:
			_err("tuning.slots", "exactly 3 filled slots required")
		else:
			for idx in filled as Array:
				var i := int(idx)
				if i < 0 or i > 7:
					_err("tuning.slots", "slot index out of 0..7: %d" % i)
				if int(idx) < 1 or int(idx) > 3:
					_err("tuning.slots", "M01 filled slots must be contract indices 0..2 (labels 1..3)")
	var resp: Variant = tuning.get("response")
	if resp is Dictionary:
		for f in ["deadline_min", "deadline_max", "understood_min", "understood_max", "ignore_max"]:
			if not (resp as Dictionary).has(f):
				_err("tuning.response", "missing '%s'" % f)


## The selected expanded mode REQUIRES its section and a positive damage constant; missing
## expanded content fails truthfully at load instead of a later dictionary/division failure.
func _validate_baby_growth() -> void:
	if not tuning.has("baby_growth_revival"):
		_err("tuning.baby_growth_revival",
			"required expanded-Baby section is missing for the default baby_growth_revival mode")
		baby_growth = {}
		return
	if int(species.get("k_defense", 0)) <= 0:
		_err("species", "k_defense must be positive before prey DEF0 damage uses k/(k+DEF)")
	var raw: Variant = tuning["baby_growth_revival"]
	if not (raw is Dictionary):
		_err("tuning.baby_growth_revival", "section must be an object")
		return
	var sec := raw as Dictionary
	var prey: Variant = sec.get("prey", null)
	var nests: Variant = sec.get("nests", null)
	if not (prey is Dictionary):
		_err("tuning.baby_growth_revival.prey", "missing object")
		return
	if not (nests is Dictionary):
		_err("tuning.baby_growth_revival.nests", "missing object")
		return
	var p := prey as Dictionary
	var n := nests as Dictionary
	var ok := true
	for f in ["radius_mwu", "hp_max_cp", "def", "mov_mwu_per_s", "threat_range_mwu", "respawn_ms"]:
		if not _integral_field(p, f, "tuning.baby_growth_revival.prey"):
			ok = false
	for f in ["radius_mwu", "return_ms"]:
		if not _integral_field(n, f, "tuning.baby_growth_revival.nests"):
			ok = false
	if not _integral_field(sec, "diagnostic_ms", "tuning.baby_growth_revival"):
		ok = false
	if not ok:
		return
	if int(p["radius_mwu"]) <= 0 or int(p["hp_max_cp"]) <= 0 \
			or int(p["mov_mwu_per_s"]) <= 0 or int(p["threat_range_mwu"]) <= 0 \
			or int(p["respawn_ms"]) <= 0:
		_err("tuning.baby_growth_revival.prey", "radius/hp/speed/threat/respawn must be positive")
	if int(p["def"]) < 0:
		_err("tuning.baby_growth_revival.prey", "def must be nonnegative")
	if int(n["radius_mwu"]) <= 0 or int(n["return_ms"]) <= 0:
		_err("tuning.baby_growth_revival.nests", "radius and return_ms must be positive")
	if int(sec["diagnostic_ms"]) <= 0:
		_err("tuning.baby_growth_revival", "diagnostic_ms must be positive")
	if int(p.get("slots", 0)) != 2:
		_err("tuning.baby_growth_revival.prey", "slots must be exactly 2")
	if not _two_points(p.get("centers", null), "tuning.baby_growth_revival.prey"):
		ok = false
	if not _two_points(n.get("centers", null), "tuning.baby_growth_revival.nests"):
		ok = false
	var rings: Variant = sec.get("placement_ring_radii_mwu", null)
	if not (rings is Array) or (rings as Array).size() != 2:
		_err("tuning.baby_growth_revival", "placement_ring_radii_mwu must list exactly 2 radii")
	elif not _integral_value((rings as Array)[0]) or not _integral_value((rings as Array)[1]) \
			or int((rings as Array)[0]) <= 0 or int((rings as Array)[1]) <= 0:
		_err("tuning.baby_growth_revival", "placement ring radii must be positive integers")
	var rewards: Variant = sec.get("rewards", null)
	if not (rewards is Array) or (rewards as Array).size() != 2:
		_err("tuning.baby_growth_revival", "rewards must list exactly 2 entries")
		return
	for i in 2:
		var rec: Variant = (rewards as Array)[i]
		if not (rec is Dictionary):
			_err("tuning.baby_growth_revival.rewards[%d]" % i, "entry must be an object")
			ok = false
			continue
		var r := rec as Dictionary
		for f in ["pending_atk", "evolution_exp"]:
			if not _integral_field(r, f, "tuning.baby_growth_revival.rewards[%d]" % i):
				ok = false
			elif int(r[f]) < 0:
				_err("tuning.baby_growth_revival.rewards[%d]" % i,
					"field '%s' must be nonnegative" % f)
				ok = false
	if not ok:
		return
	_validate_baby_footprints(p, n)
	if not errors.is_empty():
		return
	baby_growth = sec.duplicate(true)


## Reference coordinates must fit the actual arena geometry at their own radius. Failure is a
## truthful load error, never a silent teleport to another point.
func _validate_baby_footprints(p: Dictionary, n: Dictionary) -> void:
	var r_prey := float(int(p["radius_mwu"]))
	var r_body := float(int(arena.get("body_radius_mwu", 500)))
	for i in 2:
		var c: Array = (p["centers"] as Array)[i]
		if not _footprint_clear(float(c[0]), float(c[1]), r_prey):
			_err("tuning.baby_growth_revival.prey.centers[%d]" % i,
				"prey center %s does not fit arena/static geometry at radius %d" % [str(c), int(r_prey)])
	for i in 2:
		var c: Array = (n["centers"] as Array)[i]
		if not _footprint_clear(float(c[0]), float(c[1]), r_body):
			_err("tuning.baby_growth_revival.nests.centers[%d]" % i,
				"nest/spawn center %s does not fit arena/static geometry at radius %d" % [str(c), int(r_body)])


## Circle-vs-arena-rectangle and circle-vs-original-blocker clearance at an explicit radius.
func _footprint_clear(x: float, y: float, radius: float) -> bool:
	var w := float(int(arena.get("width_mwu", 0)))
	var h := float(int(arena.get("height_mwu", 0)))
	if w <= 0.0 or h <= 0.0:
		return false
	if x - radius < 0.0 or x + radius > w or y - radius < 0.0 or y + radius > h:
		return false
	var bx0 := float(int(arena.get("blocker_min_x", 0)))
	var bx1 := float(int(arena.get("blocker_max_x", 0)))
	var by0 := float(int(arena.get("blocker_min_y", 0)))
	var by1 := float(int(arena.get("blocker_max_y", 0)))
	if x + radius > bx0 and x - radius < bx1 and y + radius > by0 and y - radius < by1:
		return false
	return true


## A finite integral (int, or float with no fractional part) numeric field.
func _integral_value(v: Variant) -> bool:
	if v is int:
		return true
	if v is float:
		if is_nan(v) or is_inf(v):
			return false
		return absf(v - roundf(v)) <= 1e-9
	return false


func _integral_field(rec: Dictionary, field: String, where: String) -> bool:
	if not rec.has(field):
		_err(where, "missing required field '%s'" % field)
		return false
	if not _integral_value(rec[field]):
		_err(where, "field '%s' must be a finite integral number, got %s" % [field, str(rec[field])])
		return false
	return true


func _two_points(v: Variant, where: String) -> bool:
	if not (v is Array) or (v as Array).size() != 2:
		_err(where, "centers must list exactly 2 points")
		return false
	var seen := {}
	for i in 2:
		var pt: Variant = (v as Array)[i]
		if not (pt is Array) or (pt as Array).size() != 2:
			_err(where, "center[%d] must be a 2-number point" % i)
			return false
		for c in pt as Array:
			if not _integral_value(c):
				_err(where, "center[%d] must contain finite integral coordinates" % i)
				return false
		var key := "%d,%d" % [int((pt as Array)[0]), int((pt as Array)[1])]
		if seen.has(key):
			_err(where, "centers must be unique")
			return false
		seen[key] = true
	return true


func baby_section() -> Dictionary:
	return baby_growth


func _compile() -> void:
	compiled["charge_ticks"] = {}
	compiled["cooldown_ticks"] = {}
	compiled["recovery_ticks"] = {}
	for id in skills:
		var d: Dictionary = skills[id]
		compiled["charge_ticks"][id] = _ms_to_ticks(int(d["charge_ms"]))
		compiled["cooldown_ticks"][id] = _ms_to_ticks(int(d["cooldown_ms"]))
		compiled["recovery_ticks"][id] = _ms_to_ticks(int(d["recovery_ms"]))
	if not baby_growth.is_empty():
		compiled["baby_prey_respawn_ticks"] = _ms_to_ticks(int(baby_growth["prey"]["respawn_ms"]))
		compiled["baby_return_ticks"] = _ms_to_ticks(int(baby_growth["nests"]["return_ms"]))
		compiled["baby_diagnostic_ticks"] = _ms_to_ticks(int(baby_growth["diagnostic_ms"]))


func charge_ticks(id: String) -> int:
	return int(compiled["charge_ticks"].get(id, 0))


func cooldown_ticks(id: String) -> int:
	return int(compiled["cooldown_ticks"].get(id, 0))


func recovery_ticks(id: String) -> int:
	return int(compiled["recovery_ticks"].get(id, 0))


func skill(id: String) -> Dictionary:
	return skills.get(id, {})


func failure_report() -> String:
	return "\n".join(errors)
