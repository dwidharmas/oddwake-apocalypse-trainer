class_name M01Gateway
extends RefCounted

const REJECT_REASONS := ["envelope", "ownership", "control", "life", "sequence", "slot", "hint"]

var pending: Array = []
var last_accepted_sequence := {0: 0, 1: 0}
var next_request_id := 1
var staged: Array = []


func reset() -> void:
	pending.clear()
	staged.clear()
	last_accepted_sequence = {0: 0, 1: 0}
	next_request_id = 1


func stage(raw: Dictionary, effective_tick: int, source_life: int = -1) -> void:
	var copy := raw.duplicate(true)
	copy["effective_tick"] = effective_tick
	copy["staged_for"] = effective_tick
	if source_life >= 0:
		copy["source_life"] = source_life
	staged.append(copy)


## Drops un-admitted work from one actor's old life on KO/return. Sequences and streams are
## NOT reset; the generation check in validate() remains authoritative.
func purge_actor(actor: int) -> void:
	var keep: Array = []
	for raw in staged:
		if int(raw.get("actor", -1)) == actor:
			continue
		keep.append(raw)
	staged = keep


func _is_finite_number(v: Variant) -> bool:
	if v is int:
		return true
	if v is float:
		return not is_nan(v) and not is_inf(v)
	return false


func validate(raw: Dictionary, tick: int, actors: Array, trainer_owner: Dictionary) -> Dictionary:
	if not (raw is Dictionary):
		return {"ok": false, "reason": "envelope"}
	for f in ["schema", "trainer", "actor", "sequence", "slot"]:
		if not raw.has(f):
			return {"ok": false, "reason": "envelope"}
	if str(raw["schema"]) != "m01.1":
		return {"ok": false, "reason": "envelope"}
	for f in ["trainer", "actor", "sequence", "slot"]:
		if not _is_finite_number(raw[f]):
			return {"ok": false, "reason": "envelope"}
	if raw.has("target_kind") and not _is_finite_number(raw["target_kind"]):
		return {"ok": false, "reason": "envelope"}

	var trainer := int(raw["trainer"])
	var actor := int(raw["actor"])
	if trainer < 0 or trainer > 1 or actor < 0 or actor > 1:
		return {"ok": false, "reason": "envelope"}
	if int(trainer_owner.get(trainer, -1)) != actor:
		return {"ok": false, "reason": "ownership", "trainer": trainer, "actor": actor}

	var a: Dictionary = actors[actor]
	if int(a["control_mode"]) != 0:
		return {"ok": false, "reason": "control", "actor": actor, "request": int(raw.get("request_id", 0))}
	if not bool(a["alive"]):
		return {"ok": false, "reason": "life", "actor": actor}
	if raw.has("source_life") and int(raw["source_life"]) >= 0 \
			and int(a["life_id"]) != int(raw["source_life"]):
		# Obsolete pre-KO generation: truthful life rejection, no waiting queue.
		return {"ok": false, "reason": "life", "actor": actor}

	var seq := int(raw["sequence"])
	var last := int(last_accepted_sequence.get(trainer, 0))
	if seq <= last:
		return {"ok": false, "reason": "sequence", "actor": actor, "trainer": trainer}

	var slot := int(raw["slot"])
	if slot < 0 or slot > 7:
		return {"ok": false, "reason": "slot"}
	var labels: Array = a["slot_labels"]
	var label := str(labels[slot])
	if label == "Empty":
		return {"ok": false, "reason": "slot", "actor": actor}

	var family := int(raw.get("family", 0))
	if family < 1 or family > 3:
		return {"ok": false, "reason": "slot"}
	if label != ["Attack", "Defense", "Run"][family - 1]:
		return {"ok": false, "reason": "slot", "actor": actor}

	var target_kind := int(raw.get("target_kind", 0))
	if target_kind < 0 or target_kind > 3:
		return {"ok": false, "reason": "hint"}
	if target_kind == 0 and raw.get("target_or_area", null) != null:
		return {"ok": false, "reason": "hint"}
	if target_kind != 0:
		if raw.get("target_or_area", null) == null:
			return {"ok": false, "reason": "hint"}
		if not _valid_hint(target_kind, raw["target_or_area"], a, actors, tick):
			return {"ok": false, "reason": "hint", "actor": actor}

	last_accepted_sequence[trainer] = seq
	var request_id := next_request_id
	next_request_id += 1
	return {
		"ok": true,
		"request": request_id,
		"trainer": trainer,
		"actor": actor,
		"sequence": seq,
		"slot": slot,
		"family": family,
		"target_kind": target_kind,
		"target_or_area": raw.get("target_or_area", null),
		"observed_tick": int(raw.get("observed_tick", tick)),
		"effective_tick": tick,
	}


func _valid_hint(target_kind: int, hint: Variant, actor: Dictionary, actors: Array, tick: int) -> bool:
	if target_kind == 1:
		return false
	if target_kind == 2:
		if not (hint is int):
			return false
		var idx := int(hint)
		if idx < 0 or idx > 1 or idx == int(actor["actor_id"]):
			return false
		var other: Dictionary = actors[idx]
		return bool(other["alive"]) and bool(actor["enemy_visible"])
	if target_kind == 3:
		if not (hint is Array) or (hint as Array).size() != 2:
			return false
		for e in hint as Array:
			if not _is_finite_number(e):
				return false
		return true
	return false


func drain_effective(tick: int) -> Array:
	var out: Array = []
	var keep: Array = []
	for raw in staged:
		if int(raw["effective_tick"]) <= tick:
			out.append(raw)
		else:
			keep.append(raw)
	staged = keep
	out.sort_custom(func(a, b): return int(a["effective_tick"]) < int(b["effective_tick"]))
	return out


func begin_boundary(tick: int) -> void:
	pending.clear()


func accept(raw: Dictionary, tick: int, actors: Array, trainer_owner: Dictionary) -> Dictionary:
	return validate(raw, tick, actors, trainer_owner)
