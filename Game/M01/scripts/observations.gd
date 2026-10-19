class_name M01Observations
extends RefCounted

const BANDS := {"hp": 0, "stam": 1, "fatigue": 2, "int": 3, "instinct": 4}


static func hp_band(hp: int, hp_max: int) -> int:
	if hp <= 0:
		return 0
	var ratio := float(hp) / float(hp_max)
	if ratio >= 0.75:
		return 4
	if ratio >= 0.50:
		return 3
	if ratio >= 0.25:
		return 2
	return 1


static func stam_band(stam: int, stam_max: int) -> int:
	if stam <= 0:
		return 0
	var ratio := float(stam) / float(stam_max)
	if ratio >= 0.75:
		return 3
	if ratio >= 0.25:
		return 2
	return 1


static func fatigue_band(fatigue_centi: int) -> int:
	if fatigue_centi >= 8000:
		return 2
	if fatigue_centi >= 3500:
		return 1
	return 0


static func int_band(value: int) -> int:
	if value >= 70:
		return 2
	if value >= 40:
		return 1
	return 0


static func instinct_band(value: int) -> int:
	if value >= 70:
		return 2
	if value >= 40:
		return 1
	return 0


static func hp_label(band: int) -> String:
	return ["KO", "Critical", "Wounded", "Hurt", "Healthy"][band]


static func stam_label(band: int) -> String:
	return ["Empty", "Low", "Steady", "High"][band]


static func fatigue_label(band: int) -> String:
	return ["Fresh", "Strained", "Exhausted"][band]


static func own_state_labels(actor: Dictionary) -> Dictionary:
	var sp := int(actor["stam"]) / 100.0
	var bands := {
		"hp": hp_band(int(actor["hp"]), int(actor["hp_max"])),
		"stam": stam_band(int(actor["stam"]), int(actor["stam_max"])),
		"fatigue": fatigue_band(int(actor["fatigue_centi"])),
	}
	return {
		"emotion": str(actor["emotion"]),
		"hp_band": bands["hp"],
		"hp_label": hp_label(bands["hp"]),
		"stam_band": bands["stam"],
		"stam_label": stam_label(bands["stam"]),
		"fatigue_band": bands["fatigue"],
		"fatigue_label": fatigue_label(bands["fatigue"]),
		"physical_locked": int(actor.get("lock_end", 0)) > int(actor.get("tick", 0)),
		"ready": {},
	}


static func visibility_state(actor: Dictionary, tick: int) -> int:
	var mem_valid := int(actor["memory_expiry"]) > tick and int(actor["memory_last_seen_tick"]) >= 0
	if bool(actor["enemy_visible"]):
		return 2
	if mem_valid:
		return 1
	return 0


static func build_trainer_observation(observer: int, tick: int, actors: Array,
		enemy_idx: int, arena_map: Dictionary, memory: Dictionary) -> Dictionary:
	var own: Dictionary = actors[observer]
	var enemy: Dictionary = actors[enemy_idx]
	var own_labels := own_state_labels(own)
	own_labels["tick"] = tick
	own_labels["observer"] = observer
	own_labels["control"] = int(own["control_mode"])
	own_labels["skills"] = own["loadout_skill_ids"].duplicate()
	own_labels["slot_labels"] = own["slot_labels"].duplicate()
	own_labels["affordable"] = {}
	for sid in own["loadout_skill_ids"]:
		if str(sid) == "":
			continue
		own_labels["affordable"][sid] = bool(own["affordable"].get(sid, false))
	own_labels["ready"] = {}
	for sid in own["loadout_skill_ids"]:
		if str(sid) == "":
			continue
		own_labels["ready"][sid] = bool(own["ready"].get(sid, false))

	var state := visibility_state(own, tick)
	var cues := {}
	if state == 2:
		cues = {
			"knowledge": 2,
			"position": [float(enemy["x"]), float(enemy["y"])],
			"last_seen_tick": tick,
			"hp_band": hp_band(int(enemy["hp"]), int(enemy["hp_max"])),
			"form": str(enemy["presentation_id"]),
			"action_archetype": str(enemy["public_action"]),
			"visible": true,
		}
	elif state == 1:
		cues = {
			"knowledge": 1,
			"position": [float(memory["x"]), float(memory["y"])],
			"last_seen_tick": int(memory["tick"]),
			"hp_band": int(memory["hp_band"]),
			"form": str(memory["form"]),
			"action_archetype": "",
			"visible": false,
		}
	else:
		cues = {"knowledge": 0, "position": null, "last_seen_tick": -1,
			"hp_band": -1, "form": "", "action_archetype": "", "visible": false}

	return {
		"schema": "m01.1",
		"observer": observer,
		"observation_tick": tick,
		"own": own_labels,
		"enemy": cues,
		"known_map": arena_map,
	}


static func public_feedback(recipient: int, request_id: int, tick: int, cue: String,
		family: int, detail: String) -> Dictionary:
	return {
		"schema": "m01.1",
		"recipient": recipient,
		"request": request_id,
		"tick": tick,
		"cue": cue,
		"family": family,
		"detail": detail,
	}


static func enemy_band_text(cues: Dictionary) -> String:
	var k := int(cues.get("knowledge", 0))
	if k == 2:
		return "Visible · %s" % hp_label(int(cues.get("hp_band", 4)))
	if k == 1:
		return "Last Known · stale"
	return "Unknown"
