class_name M01TrainerAI
extends RefCounted

var decision_id := 1


func reset() -> void:
	decision_id = 1


func should_decide(tick: int, npc: Dictionary) -> bool:
	if int(npc["next_decision_tick"]) < 0:
		return true
	return tick >= int(npc["next_decision_tick"])


func decide(tick: int, npc: Dictionary, actor: Dictionary, enemy: Dictionary,
		arena: M01Arena) -> Dictionary:
	var mem := {}
	if bool(actor.get("memory_valid", false)):
		mem = {"x": float(actor["memory_x"]), "y": float(actor["memory_y"]),
			"tick": int(actor["memory_last_seen_tick"]),
			"hp_band": int(actor["memory_hp_band"]),
			"form": str(actor["memory_form"])}
	var arena_map := {}
	if arena != null:
		arena_map = arena.map_copy()
	# ARCH-PLAY01-R01-F03: build_trainer_observation reads own = actors[observer] and
	# enemy = actors[enemy_idx]. Observer 1 is the NPC, so the pair must be ordered
	# [human, NPC] for observer1/enemy-index0 to yield NPC-owned bands, control, readiness
	# and memory with the human's permitted enemy cues.
	var obs := M01Observations.build_trainer_observation(1, tick, [enemy, actor], 0, arena_map, mem)
	var own: Dictionary = obs["own"]
	var cues: Dictionary = obs["enemy"]
	var knowledge := int(cues.get("knowledge", 0))
	var visible := knowledge == 2
	var pos: Variant = cues.get("position", null)
	var distance := INF
	if pos != null:
		distance = sqrt(pow(float(pos[0]) - float(actor["x"]), 2.0) + pow(float(pos[1]) - float(actor["y"]), 2.0))

	var hp_label := str(own["hp_label"])
	var fatigue_label := str(own["fatigue_label"])
	var family := 1
	var target_kind := 0
	var target_or_area: Variant = null
	var category := "attack"

	var run_distance := float(content_distance())
	if (fatigue_label == "Exhausted" or hp_label == "Wounded" or hp_label == "Critical") and visible and distance <= run_distance:
		family = 3
		category = "run"
	elif visible and distance <= 1600.0 and hp_label == "Hurt":
		family = 2
		category = "defense"
	elif visible:
		family = 1
		category = "attack"
	elif knowledge == 1:
		family = 1
		category = "attack"
		target_kind = 3
		target_or_area = [int(cues["position"][0] / 100.0) * 100, int(cues["position"][1] / 100.0) * 100]
	else:
		family = 1
		category = "attack"

	var did := decision_id
	decision_id += 1
	return {
		"decision": did,
		"observation_tick": tick,
		"source_life": int(actor.get("life_id", 1)),
		"safety_category": category,
		"proposed_slot": family,
		"lawful_hint": [target_kind, target_or_area],
		"submission_due_tick": tick + 12,
		"npc": npc.duplicate(true),
	}


func content_distance() -> float:
	return 2500.0


func apply_decision(decision: Dictionary, npc: Dictionary) -> void:
	npc["next_decision_tick"] = int(decision["observation_tick"]) + 45
