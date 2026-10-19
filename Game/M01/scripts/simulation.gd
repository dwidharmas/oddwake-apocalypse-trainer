class_name M01Simulation
extends RefCounted

const SCHEMA := "m01.1"
const FAMILY_LABEL := {1: "Attack", 2: "Defense", 3: "Run"}
const RESPONSE_CLASS := {1: "ignored", 2: "misinterpreted", 3: "declined",
	4: "understood_hesitant", 5: "understood_normal", 6: "understood_strong"}
const AUTHOR_SKILL_ORDER := ["quick_claw", "brace", "short_bound"]
## G3 §5: a rest fallback completes after 60 actual idle ticks.
const REST_IDLE_TICKS := 60
## G3 §5: voluntary cancellation of a still-charging action is allowed while
## charge_elapsed / charge_total < 0.25 + 0.50 * (INT / 100). Equality declines.
const CHARGE_CANCEL_BASE := 0.25
const CHARGE_CANCEL_INT_WEIGHT := 0.50

var content: M01Content
var arena: M01Arena
var telemetry: M01Telemetry
var gateway := M01Gateway.new()
var behavior := M01MonsterBehavior.new()
var trainer_ai := M01TrainerAI.new()

var tick := 0
var active_ticks := 0
var mode := "live"
var fixture_id: String = ""
var root_seed := 3101
var ended := false
var end_reason := 0
var end_batch := -1
var ko_actors: Array = []
var aborted := false

var actors: Array = []
var trainer_owner := {0: 0, 1: 1}
var human_feedback: Array = []
var public_actions := {0: "", 1: ""}
var batch_counter := 0
var id_counter := {"request": 1, "episode": 1, "intent": 1, "action": 1,
	"effect": 1, "decision": 1, "checkpoint": 1}

var streams := {}
var stream_draws := {}
var forced_uniforms := {}
## Lifetime per-actor monster-side selection draw counters (reset with the streams).
var selection_draw_count := [0, 0]
var _sel_aid := 0
var pending_effects: Array = []
var started_technique := {0: false, 1: false}
var cancelled_this_boundary := {0: false, 1: false}
var ko_this_boundary := {0: false, 1: false}
var accepted_requests: Array = []
var plan_cache := {0: {}, 1: {}}
## R-F02/QA-RES-F03: last planning signature per actor, so an unchanged view/intent keeps the
## 15-tick cadence instead of rebuilding a plan every 60 Hz tick.
var plan_watch := {0: {}, 1: {}}
## Bounded navigation work accounting for the whole run (searches, expansions, budget violations).
var nav_searches := 0
var nav_expansions := 0
var nav_violations := 0
var nav_max_decision_expansions := 0
var sim_time_ms_samples: Array[float] = []
var last_step_ms := 0.0
var elapsed_usec := 0

var fixture := {}
var recorded_requests: Array = []
var recorded_index := 0


func setup(p_content: M01Content, p_arena: M01Arena, p_telemetry: M01Telemetry,
		p_mode: String, p_seed: int, p_fixture: Dictionary = {}) -> bool:
	content = p_content
	arena = p_arena
	telemetry = p_telemetry
	mode = p_mode
	root_seed = p_seed
	fixture = p_fixture
	fixture_id = str(p_fixture.get("id", ""))
	behavior.setup(arena, content)
	_init_streams()
	_init_actors()
	return true


func _init_streams() -> void:
	streams.clear()
	stream_draws.clear()
	selection_draw_count = [0, 0]
	for sname in ["response.side0", "response.side1", "monster.side0", "monster.side1", "trainer.side1"]:
		var rng := RandomNumberGenerator.new()
		rng.seed = _derive_seed(root_seed, sname)
		streams[sname] = rng
		stream_draws[sname] = 0


## One uniform per selection candidate, drawn from the monster stream under a lifetime per-actor
## force key ("monster.<aid>.<n>") so fixtures can pin exact draws.
func _monster_uniform(aid: int) -> float:
	var n := int(selection_draw_count[aid])
	selection_draw_count[aid] = n + 1
	return _u("monster.side%d" % aid, "monster.%d.%d" % [aid, n])


func _sel_draw() -> float:
	return _monster_uniform(_sel_aid)


func _derive_seed(p_seed: int, stream_name: String) -> int:
	var key := "m01-seed-1|%d|%s" % [p_seed, stream_name]
	var digest: PackedByteArray = key.sha256_buffer()
	var value := 0
	for i in 8:
		value = (value << 8) | int(digest[i])
	return value & 0x7FFFFFFFFFFFFFFF


func stream_seed_hex(stream_name: String) -> String:
	var key := "m01-seed-1|%d|%s" % [root_seed, stream_name]
	return key.sha256_buffer().hex_encode()


func _u(stream_name: String, force_key: String = "") -> float:
	if forced_uniforms.has(force_key) and (forced_uniforms[force_key] as Array).size() > 0:
		var arr: Array = forced_uniforms[force_key]
		var v := float(arr[0])
		arr.pop_front()
		forced_uniforms[force_key] = arr
		return v
	var rng: RandomNumberGenerator = streams[stream_name]
	var sample := rng.randi()
	stream_draws[stream_name] = int(stream_draws[stream_name]) + 1
	return float(sample) / 4294967296.0


func _make_actor(idx: int) -> Dictionary:
	var sp: Dictionary = content.species
	var spawn: Array = arena.spawn[idx]
	var labels := ["Attack", "Defense", "Run", "Empty", "Empty", "Empty", "Empty", "Empty"]
	var skill_ids := ["quick_claw", "brace", "short_bound", "", "", "", "", ""]
	var learned := {}
	for sid in sp["learned_skills"]:
		learned[str(sid)] = true
	return {
		"actor_id": idx,
		"side": idx,
		"life_id": 1,
		"species_id": str(sp["id"]),
		"presentation_id": str(sp["presentation_id"]),
		"hp_max": int(sp["hp_max_cp"]),
		"stam_max": int(sp["stam_max_cp"]),
		"hp": int(sp["hp_max_cp"]),
		"stam": int(sp["stam_max_cp"]),
		"atk": int(sp["atk"]),
		"def": int(sp["def"]),
		"k_defense": int(sp["k_defense"]),
		"mov_mwu_per_s": int(sp["mov_mwu_per_s"]),
		"int_stat": int(sp["int_stat"]),
		"instinct": int(sp["instinct"]),
		"bond": int(sp["bond"]),
		"radius": float(sp["radius_mwu"]),
		"x": float(spawn[0]),
		"y": float(spawn[1]),
		"facing": 0,
		"alive": true,
		"life": 0,
		"emotion": "Calm",
		"control_mode": 0,
		"lock_end": 0,
		"lock_latched": false,
		"physical_locked": false,
		"slot_labels": labels,
		"loadout_skill_ids": skill_ids,
		"learned": learned,
		"cooldown_end": {"quick_claw": 0, "brace": 0, "short_bound": 0},
		"recovery_end": 0,
		"action": null,
		"response_episode": null,
		"accepted_intent": null,
		# Cycle ownership (ARCH-F04): which accepted intent owns the technique cycle / fallback
		# goal currently running, which intent owns the pending recovery, and how many actual
		# idle ticks the current rest fallback has accumulated.
		"cycle_intent": -1,
		"recovery_owner": -1,
		"rest_idle_ticks": 0,
		# ARCH-PLAY01-R02-F04: the genuine request / episode behind the captured cycle owner, so
		# a fallback capture keeps the same distinct IDs the accepted intent carried.
		"cycle_request": 0,
		"cycle_episode": 0,
		"pressure": 0,
		"pressure_key": "",
		"last_repeat_credit": -9999,
		"fatigue_centi": 0,
		"affordable": {},
		"ready": {},
		"enemy_visible": false,
		"memory_valid": false,
		"memory_x": 0.0,
		"memory_y": 0.0,
		"memory_last_seen_tick": -1,
		"memory_expiry": 0,
		"memory_hp_band": -1,
		"memory_form": "",
		"memory_token": 0,
		"search_active": false,
		"search_start": -1,
		"search_deadline": -1,
		"search_token_exhausted": {},
		"patrol_index": 0,
		"patrol_visited": [],
		"search_visited": [],
		"brace_action": -1,
		"brace_start": -1,
		"brace_end": -1,
		"bound_path": [],
		"bound_progress": 0.0,
		"bound_total": 0.0,
		"bound_action": -1,
		"bound_active": false,
		"public_action": "",
		"last_hp_band": -1,
		"last_stam_band": -1,
		"last_fatigue_band": -1,
		"next_plan_tick": 0,
		"moved_this_boundary": false,
		"last_fatigue_centi": 0,
		"def_frozen": int(sp["def"]),
		"brace_frozen": false,
		"brace_prepare_action": -1,
		"goal": null,
		"knowledge_state": "unknown",
		"last_plan": {},
		"npc": {
			"next_decision_tick": -1,
			"queued": null,
			"decision_id": 1,
			"history": [],
			"repeated_episode": false,
		},
	}


func _init_actors() -> void:
	actors = [_make_actor(0), _make_actor(1)]
	for a in actors:
		_refresh_gates(a)


func apply_fixture(f: Dictionary) -> void:
	fixture = f
	fixture_id = str(f.get("id", fixture_id))
	for key in f.get("forced_uniforms", {}):
		forced_uniforms[key] = (f["forced_uniforms"] as Dictionary)[key]
	var st: Dictionary = f.get("state", {})
	for idx_str in st:
		var idx := int(idx_str)
		if idx < 0 or idx > 1:
			continue
		var patch: Dictionary = st[idx_str]
		for k in patch:
			actors[idx][k] = patch[k]
	var locks: Array = f.get("control_locks", [])
	for l in locks:
		fixture["lock_schedule"] = locks
	if f.has("arriving_effects"):
		for e in f["arriving_effects"]:
			pending_effects.append(e.duplicate(true))
	_refresh_gates(actors[0])
	_refresh_gates(actors[1])


func _refresh_gates(a: Dictionary) -> void:
	# GP-F04: readiness means cost/cooldown/physical requirements are met. An active Brace hold
	# is a physical requirement that is not met for any further technique start.
	var holding := _brace_holding(a)
	for sid in AUTHOR_SKILL_ORDER:
		var def := content.skill(sid)
		var cost := int(def["stam_cost_cp"])
		var cd := int(a["cooldown_end"].get(sid, 0))
		var rec := int(a["recovery_end"])
		a["affordable"][sid] = int(a["stam"]) >= cost and bool(a["alive"])
		a["ready"][sid] = tick >= cd and tick >= rec and bool(a["alive"]) and not holding


func _in_lock(a: Dictionary) -> bool:
	return tick < int(a["lock_end"])


func _tick_start() -> void:
	var t0 := Time.get_ticks_usec()
	started_technique = {0: false, 1: false}
	cancelled_this_boundary = {0: false, 1: false}
	ko_this_boundary = {0: false, 1: false}
	accepted_requests.clear()
	last_step_ms = 0.0
	elapsed_usec = t0


func step() -> void:
	if ended:
		return
	_tick_start()
	tick += 1
	_cut1()
	_cut2()
	_cut3()
	_cut4()
	_cut5()
	_cut6()
	active_ticks += 1
	telemetry.mark_activity(active_ticks)
	if active_ticks % 60 == 0:
		_emit_checkpoint()
	if active_ticks >= int(content.tuning["timeout_active_ticks"]) and not ended:
		_end_encounter(3, -1)
	var dt := float(Time.get_ticks_usec() - elapsed_usec) / 1000.0
	last_step_ms = dt
	sim_time_ms_samples.append(dt)


func _cut1() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		_expire_intervals(a)
		a["pressure"] = maxi(0, int(a["pressure"]) - int(content.tuning["pressure"]["decay_per_tick"]))
	_apply_control_locks()
	var staged := gateway.drain_effective(tick)
	for raw in staged:
		if mode == "recorded_requests":
			if int(raw.get("trainer", -1)) != 1:
				continue
		var res := gateway.validate(raw, tick, actors, trainer_owner)
		if not bool(res["ok"]):
			telemetry.emit(tick, 2, [int(raw.get("request_id", 0)), int(raw.get("actor", -1)), str(res["reason"])])
			continue
		accepted_requests.append(res)
	# NPC ingress shares this single admission point: matured queue entries become ordinary
	# scratch requests for this boundary's cut2, on the same tick they mature.
	_drain_npc_submissions()


func _expire_intervals(a: Dictionary) -> void:
	if int(a["brace_end"]) >= 0 and tick >= int(a["brace_end"]) and int(a["brace_action"]) >= 0:
		var bid := int(a["brace_action"])
		a["brace_action"] = -1
		a["brace_start"] = -1
		a["brace_end"] = -1
		a["recovery_end"] = tick + int(content.recovery_ticks("brace"))
		telemetry.emit(tick, 15, [int(a["actor_id"]), bid, tick, tick + int(content.recovery_ticks("brace")), "expiry"])
	# ARCH-F04 / G3 §5 / ARCH-PLAY01-R02-F03: a retained technique action ends exactly at recovery
	# end, and the cycle completes using the OWNER OF THE RECOVERY THAT ENDED — never whatever a
	# newer fallback plan captured in the meantime, so a waiting J survives I's completion.
	var act_now: Variant = a["action"]
	if act_now != null and act_now is Dictionary \
			and str((act_now as Dictionary).get("state", "")) == "recovering" \
			and tick >= int(a["recovery_end"]):
		a["action"] = null
	if int(a["recovery_owner"]) >= 0 and a["action"] == null and not bool(a["bound_active"]) \
			and int(a["brace_action"]) < 0 and tick >= int(a["recovery_end"]):
		_complete_cycle(a, int(a["recovery_owner"]))
	if int(a["memory_expiry"]) > 0 and tick >= int(a["memory_expiry"]) and bool(a["memory_valid"]):
		a["memory_valid"] = false
		a["search_active"] = false
		telemetry.emit(tick, 16, [int(a["actor_id"]), -1, 0, -1, null])
		_end_search_influence(a)
	if bool(a["search_active"]) and tick >= int(a["search_deadline"]):
		a["search_active"] = false
		a["search_token_exhausted"][str(a["memory_token"])] = true
		telemetry.emit(tick, 17, [int(a["actor_id"]), 0, int(a["memory_token"]), "end", int(a["search_deadline"]), "timeout"])
		_end_search_influence(a)
	# G3 §6: search of one token also ends early when every lawful goal of that token is reached.
	if bool(a["search_active"]) and not bool(a["enemy_visible"]) \
			and behavior.search_goals(a).is_empty():
		a["search_active"] = false
		a["search_token_exhausted"][str(a["memory_token"])] = true
		telemetry.emit(tick, 17, [int(a["actor_id"]), 0, int(a["memory_token"]), "end",
			int(a["search_deadline"]), "complete"])
		_end_search_influence(a)
	var ep: Dictionary = a["response_episode"] if a["response_episode"] != null else {}
	if not ep.is_empty() and tick >= int(ep.get("expiry_tick", -1)) and not bool(ep.get("draw_resolved", false)):
		a["response_episode"] = null
	var intent: Dictionary = a["accepted_intent"] if a["accepted_intent"] != null else {}
	if not intent.is_empty() and tick >= int(intent.get("expiry_tick", -1)):
		# G3 §5 / ARCH-PLAY01-R03-F01: expiry removes FUTURE trainer influence only — it drops
		# accepted_intent but never the owner slot of unfinished PAID work (charge, committed
		# hold/travel or pending recovery). Retaining cycle_intent/request/episode there is what
		# keeps a later cancellation tied to I, keeps _capture_cycle_owner from writing a newer J
		# into I's slot (its first guard already refuses a non-negative owner), and lets only I's
		# actual completion retire I. A cycle with nothing paid running still closes as before.
		if int(a["cycle_intent"]) == int(intent.get("intent", -1)) and not _cycle_pending(a):
			a["cycle_intent"] = -1
			a["rest_idle_ticks"] = 0
			a["cycle_request"] = 0
			a["cycle_episode"] = 0
		a["accepted_intent"] = null
	if _in_lock(a) == false and tick >= int(a["lock_end"]) and int(a["lock_end"]) > 0:
		var was_locked := int(a["lock_end"]) > 0
		a["lock_end"] = 0
		if was_locked:
			telemetry.emit(tick, 25, [int(a["actor_id"]), "exit", 0, int(a["stam"]), int(a["fatigue_centi"])])
		a["physical_locked"] = false
	if not _in_lock(a) and bool(a["lock_latched"]) and int(a["stam"]) >= int(content.tuning["exhaustion"]["latch_reset_stam_cp"]) \
			and int(a["fatigue_centi"]) <= int(content.tuning["exhaustion"]["latch_reset_fatigue_centi"]):
		a["lock_latched"] = false
		telemetry.emit(tick, 25, [int(a["actor_id"]), "latch_reset", 0, int(a["stam"]), int(a["fatigue_centi"])])


## GP-F05 / G3 §6: a search token's influence ends the moment the token does. The stale search
## goal is dropped and planning reopens on THIS boundary, so traversal cannot continue until the
## ordinary 15-tick interval and no underfoot goal is re-chosen forever.
## GP-PLAY01-R02-F03: when the goal being dropped IS the owning search fallback, that fallback
## also finishes — retiring exactly its own owner, and only while no other cycle work is pending.
func _end_search_influence(a: Dictionary) -> void:
	var g: Variant = a["goal"]
	var ends_search_goal := g != null and g is Dictionary \
			and str((g as Dictionary).get("purpose", "")) == "search"
	if ends_search_goal:
		a["goal"] = null
	a["next_plan_tick"] = 0
	if ends_search_goal and not _cycle_pending(a):
		_complete_cycle(a, int(a["cycle_intent"]))


func _apply_control_locks() -> void:
	if mode != "diagnostic":
		return
	var schedule: Array = fixture.get("lock_schedule", [])
	for entry in schedule:
		if int(entry.get("at_tick", -1)) != tick:
			continue
		var idx := int(entry.get("actor", -1))
		if idx < 0 or idx > 1:
			continue
		var a: Dictionary = actors[idx]
		var lock_mode := int(entry.get("mode", 1))
		a["control_mode"] = lock_mode
		a["emotion"] = "Calm" if lock_mode == 1 else "Frenzy"
		gateway.last_accepted_sequence[0] = 999999
		gateway.last_accepted_sequence[1] = 999999
		a["response_episode"] = null
		a["accepted_intent"] = null
		a["cycle_intent"] = -1
		a["recovery_owner"] = -1
		a["rest_idle_ticks"] = 0
		a["cycle_request"] = 0
		a["cycle_episode"] = 0
		a["pressure"] = 0
		a["pressure_key"] = ""
		for t in [0, 1]:
			gateway.last_accepted_sequence[t] = 1 << 40
		telemetry.emit(tick, 18, [idx, lock_mode, true, true, str(a["emotion"])])


func _cut2() -> void:
	_process_requests()
	_update_response_episodes()
	for i in 2:
		var a: Dictionary = actors[i]
		_refresh_gates(a)
	_detect_pre_start_exhaustion()
	for i in 2:
		var a: Dictionary = actors[i]
		if not bool(a["alive"]) or ended:
			continue
		if int(a["control_mode"]) != 0 and mode == "diagnostic":
			pass
		_plan_and_start(a)
	_advance_actions()
	_movement_cut()


func _process_requests() -> void:
	for res in accepted_requests:
		var a: Dictionary = actors[int(res["actor"])]
		if not bool(a["alive"]):
			continue
		var key := _semantic_key(int(res["family"]), res["target_or_area"])
		var ep: Dictionary = a["response_episode"] if a["response_episode"] != null else {}
		var same_pending := not ep.is_empty() and str(ep.get("key", "")) == key and not bool(ep.get("draw_resolved", false))
		var intent: Variant = a["accepted_intent"]
		var same_active_intent := intent != null and str(a["pressure_key"]) == key
		telemetry.emit(tick, 1, [int(res["request"]), int(res["trainer"]), int(res["actor"]),
			int(res["sequence"]), int(res["observed_tick"]), int(res["slot"]),
			int(res["target_kind"]), res["target_or_area"]])
		if int(a["actor_id"]) == 0:
			_record("%s requested" % FAMILY_LABEL.get(int(res["family"]), ""), "Awaiting response",
				int(res["family"]), "receipt")
		if int(a["control_mode"]) != 0:
			continue
		if key != str(a["pressure_key"]):
			a["pressure_key"] = key
			a["pressure"] = 0
		if same_pending or same_active_intent:
			var credited := tick - int(a["last_repeat_credit"]) >= int(content.tuning["pressure"]["repeat_min_interval_ticks"])
			if credited:
				a["last_repeat_credit"] = tick
				a["pressure"] = mini(int(content.tuning["pressure"]["cap_thirtieths"]),
					int(a["pressure"]) + int(content.tuning["pressure"]["repeat_credit_thirtieths"]))
				a["fatigue_centi"] = mini(int(content.tuning["fatigue"]["cap_centi"]),
					int(a["fatigue_centi"]) + int(content.tuning["fatigue"]["repeat_add"]))
				var pts := float(a["pressure"]) / 30.0
				if pts > float(content.tuning["pressure"]["excess_threshold_points"]):
					a["fatigue_centi"] = mini(int(content.tuning["fatigue"]["cap_centi"]),
						int(a["fatigue_centi"]) + int(content.tuning["pressure"]["excess_fatigue_add"]) * 100)
				telemetry.emit(tick, 4, [int(a["actor_id"]), int(res["request"]),
					int(ep.get("episode", 0)), int(a["pressure"]), int(a["fatigue_centi"]),
					true, "credited_repeat"])
			continue
		if not ep.is_empty() and not bool(ep.get("draw_resolved", false)):
			if str(ep.get("key", "")) == key:
				a["response_episode"]["latest_request"] = int(res["request"])
				continue
			# GP-F02: a different pending key REPLACES the pending episode — new key, new
			# deadline and the ordinary new-episode fatigue. A previously accepted intent is
			# left untouched until a new response accepts the replacement.
			a["response_episode"] = null
		_issue_episode(a, res, key)


func _semantic_key(family: int, target: Variant) -> String:
	if target == null:
		return "%d|none" % family
	if target is int:
		return "%d|ent%d" % [family, int(target)]
	if target is Array and (target as Array).size() == 2:
		var qx := int(floor(float(target[0]) / 100.0))
		var qy := int(floor(float(target[1]) / 100.0))
		return "%d|%d,%d" % [family, qx, qy]
	return "%d|none" % family


func _issue_episode(a: Dictionary, res: Dictionary, key: String) -> void:
	var pre_fatigue := int(a["fatigue_centi"])
	var i_val := float(a["int_stat"]) / 100.0
	var b_val := float(a["bond"]) / 100.0
	var p_val := float(a["pressure"]) / 30.0
	# GP-F02: fatigue is stored in centi units, so the frozen F = fatigue/100 normalises by
	# 10000, not 100. The deadline is computed from the PRE-issuance snapshot.
	var f_val := float(pre_fatigue) / 10000.0
	var r: Dictionary = content.tuning["response"]
	var raw := float(r["deadline_base"]) + float(r["deadline_int_weight"]) * i_val \
			+ float(r["deadline_bond_weight"]) * b_val \
			+ float(r["deadline_pressure_weight"]) * p_val \
			+ float(r["deadline_fatigue_weight"]) * f_val
	var clamped := clampf(raw, float(r["deadline_min"]), float(r["deadline_max"]))
	var d := int(ceil(float(r["deadline_scale"]) * clamped))
	var eid := int(id_counter["episode"])
	id_counter["episode"] = eid + 1
	var episode := {
		"episode": eid,
		"key": key,
		"family": int(res["family"]),
		"target_kind": int(res["target_kind"]),
		"target_or_area": res["target_or_area"],
		"first_request": int(res["request"]),
		"latest_request": int(res["request"]),
		"issue_tick": tick,
		"response_due": tick + d,
		"expiry_tick": tick + int(r["episode_expiry_ticks"]),
		"pre_issuance_fatigue": pre_fatigue,
		"pressure_at_issue": int(a["pressure"]),
		"draw_resolved": false,
		"hesitation_end": -1,
		"class": 0,
		"original_family": int(res["family"]),
		"interpreted_family": int(res["family"]),
		# GP-F01/ARCH amendment: the OBSERVED safety category, captured before any
		# misinterpretation. Simulation-owned only; no telemetry or observation field changes.
		"observation_category": str(res.get("observation_category", "")),
	}
	a["response_episode"] = episode
	# Each new episode allows at most one NPC hesitant repeat (G3 §8).
	if a.has("npc"):
		(a["npc"] as Dictionary)["repeated_episode"] = false
	a["fatigue_centi"] = mini(int(content.tuning["fatigue"]["cap_centi"]),
		int(a["fatigue_centi"]) + int(content.tuning["fatigue"]["request_add"]))
	telemetry.emit(tick, 4, [int(a["actor_id"]), int(res["request"]), eid,
		int(a["pressure"]), int(a["fatigue_centi"]), false, "issue"])


func _update_response_episodes() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		var ep: Variant = a["response_episode"]
		if ep == null or not (ep is Dictionary):
			continue
		var e := ep as Dictionary
		if bool(e["draw_resolved"]):
			continue
		if int(e["hesitation_end"]) >= 0:
			# GP-F02: the comprehension draw already happened. The fixed 12-tick wait must not
			# re-roll, extend or change class; it ends in a life/control/conflict revalidation.
			if tick >= int(e["hesitation_end"]):
				e["draw_resolved"] = true
				if not bool(a["alive"]):
					e["class"] = 3
					_emit_response(a, e, 3, int(e["original_family"]),
						int(e["interpreted_family"]), -1)
					a["response_episode"] = null
				elif int(a["control_mode"]) != 0:
					e["class"] = 3
					_emit_response(a, e, 3, int(e["original_family"]),
						int(e["interpreted_family"]), -1, "authority_locked")
					a["response_episode"] = null
				else:
					_finalize_understood(a, e, 4)
			continue
		if tick < int(e["response_due"]):
			continue
		_resolve_response(a, e)


func _resolve_response(a: Dictionary, e: Dictionary) -> void:
	var r: Dictionary = content.tuning["response"]
	var i_val := float(a["int_stat"]) / 100.0
	var b_val := float(a["bond"]) / 100.0
	var p_val := float(a["pressure"]) / 30.0
	# GP-F02: centi storage normalises by 10000 (F = fatigue/100), and this roll uses the
	# CURRENT state while the deadline above used the pre-issuance snapshot.
	var f_val := float(a["fatigue_centi"]) / 10000.0
	var c := clampf(float(r["understood_base"]) + float(r["understood_int_weight"]) * i_val
			+ float(r["understood_bond_weight"]) * b_val
			+ float(r["understood_pressure_weight"]) * p_val
			+ float(r["understood_fatigue_weight"]) * f_val,
			float(r["understood_min"]), float(r["understood_max"]))
	var q := clampf(0.25 * (1.0 - i_val) * (1.0 - p_val / 8.0), 0.0, float(r["ignore_max"]))
	var u := _u("response.side%d" % int(a["actor_id"]), "response.%d" % int(a["actor_id"]))
	var cls := 0
	if u < q:
		cls = 1
		e["draw_resolved"] = true
		e["class"] = 1
		_emit_response(a, e, 1, e["original_family"], e["original_family"], -1)
		a["response_episode"] = null
		return
	var mid_hi := q + (1.0 - q) * (1.0 - c)
	if u < mid_hi:
		var mapped := _misinterpret(int(e["original_family"]))
		e["draw_resolved"] = true
		e["class"] = 2
		e["interpreted_family"] = mapped
		var blocked := _conflict_guard(a, mapped)
		if blocked != "":
			_emit_response(a, e, 2, e["original_family"], mapped, -1, blocked)
			a["response_episode"] = null
		else:
			_accept_intent(a, e, mapped)
		return
	var guard_now := _conflict_guard(a, int(e["original_family"]), int(e["target_kind"]))
	if guard_now != "":
		e["draw_resolved"] = true
		e["class"] = 3
		_emit_response(a, e, 3, e["original_family"], e["original_family"], -1, guard_now)
		a["response_episode"] = null
		return
	if int(a["int_stat"]) < int(r["aware_int_threshold"]):
		e["class"] = 4
		e["hesitation_end"] = tick + int(r["hesitate_wait_ticks"])
		_emit_response(a, e, 4, e["original_family"], e["original_family"], int(e["hesitation_end"]))
		return
	e["draw_resolved"] = true
	_finalize_understood(a, e, 6 if int(a["int_stat"]) >= int(r["strong_int_threshold"]) else 5)


func _finalize_understood(a: Dictionary, e: Dictionary, cls: int) -> void:
	e["class"] = cls
	var family := int(e["interpreted_family"])
	var guard := _conflict_guard(a, family, int(e["target_kind"]))
	if guard != "":
		_emit_response(a, e, 3, e["original_family"], family, -1, guard)
		a["response_episode"] = null
		return
	_accept_intent(a, e, family)


func _misinterpret(family: int) -> int:
	match family:
		1:
			return 3
		2:
			return 1
		3:
			return 2
	return family


func _conflict_guard(a: Dictionary, family: int, target_kind: int = 0) -> String:
	if family == 1 or family == 2:
		if bool(a["physical_locked"]) or int(a["fatigue_centi"]) >= int(content.tuning["fatigue"]["exhausted_threshold_centi"]):
			return "exhausted"
	# GP-F04 / G3 §5: an intent that would abandon a still-CHARGING action is declined once
	# elapsed/total reaches 0.25 + 0.50I (equality declines); below it _accept_intent may
	# voluntarily cancel instead. Same-compatible intents never reach this guard.
	var charge_block := _charging_intent_block(a, family)
	if charge_block != "":
		return charge_block
	if family == 1:
		if not bool(a["affordable"].get("quick_claw", false)):
			return "technique_unavailable"
		if target_kind == 3 and bool(a["search_token_exhausted"].get(str(a["memory_token"]), false)) and not bool(a["enemy_visible"]):
			return "target_lost"
	if family == 2:
		var brace_ok := bool(a["affordable"].get("brace", false)) and bool(a["ready"].get("brace", false))
		var bound_ok := bool(a["affordable"].get("short_bound", false)) and bool(a["ready"].get("short_bound", false))
		if not brace_ok and not bound_ok:
			if bool(a["physical_locked"]):
				return "exhausted"
			return ""
	return ""


## The action currently in a charged preparation for `sid`, or null when nothing is charging.
func _charging_action(a: Dictionary) -> Variant:
	var act: Variant = a["action"]
	if act == null or not (act is Dictionary):
		return null
	var d := act as Dictionary
	var st := str(d.get("state", ""))
	if st != "preparing" and st != "due":
		return null
	if int(content.charge_ticks(str(d["skill"]))) <= 0:
		return null
	return d


## G3 §5 conflict guard: incompatible intent versus a still-charging action.
## GP-PLAY01-R02-F02: compatibility is the family of the TRAINER INTENT that owns the charge, not
## the authored family of the technique it happens to be running — Defense may lawfully run the
## family-3 Bound, and a same-family Defense request must wait for it instead of being declined.
func _charging_intent_block(a: Dictionary, family: int) -> String:
	var charging: Variant = _charging_action(a)
	if charging == null:
		return ""
	var cd := charging as Dictionary
	if int(cd.get("owning_family", -1)) == family:
		return ""
	var total := float(content.charge_ticks(str(cd["skill"])))
	if total <= 0.0:
		return ""
	var elapsed := float(tick - int(cd["start_tick"]))
	var threshold := CHARGE_CANCEL_BASE + CHARGE_CANCEL_INT_WEIGHT * (float(a["int_stat"]) / 100.0)
	if elapsed / total < threshold:
		return ""
	return "finishing_current_action"


## An active Brace hold: protection is live and cannot coexist with a new technique start.
func _brace_holding(a: Dictionary) -> bool:
	return int(a["brace_end"]) > tick and int(a["brace_start"]) >= 0 and tick > int(a["brace_start"])


## ARCH-F04: capture the accepted intent that owns the technique cycle / fallback now starting.
## The captured request and episode travel with it so action/fallback capture retains three
## distinct genuine IDs instead of one merged number.
func _capture_cycle_owner(a: Dictionary) -> void:
	if int(a["cycle_intent"]) >= 0:
		return
	var held: Variant = a["accepted_intent"]
	if held != null and held is Dictionary:
		var h := held as Dictionary
		a["cycle_intent"] = int(h.get("intent", -1))
		a["cycle_request"] = int(h.get("request", 0))
		a["cycle_episode"] = int(h.get("episode", 0))


## ARCH-F04 / ARCH-PLAY01-R02-F03: the cycle retires ONLY the owner of the work that is
## actually ending. `owner` is supplied by the completing site (recovery_owner for a technique
## completion, cycle_intent for a fallback/rest/search completion), so an older I finishing its
## recovery never clears a newer waiting J that acceptance stored in `accepted_intent`.
func _complete_cycle(a: Dictionary, owner: int) -> void:
	if owner < 0:
		return
	if int(a["cycle_intent"]) == owner:
		a["cycle_intent"] = -1
		a["rest_idle_ticks"] = 0
		a["cycle_request"] = 0
		a["cycle_episode"] = 0
	if int(a["recovery_owner"]) == owner:
		a["recovery_owner"] = -1
	var held: Variant = a["accepted_intent"]
	if held != null and held is Dictionary and int((held as Dictionary).get("intent", -1)) == owner:
		a["accepted_intent"] = null


## True while the current cycle still owns running work or its own recovery window.
func _cycle_pending(a: Dictionary) -> bool:
	return a["action"] != null or bool(a["bound_active"]) or int(a["brace_action"]) >= 0 \
			or (int(a["recovery_owner"]) >= 0 and tick < int(a["recovery_end"]))


## GP-F04: end an active Brace hold BEFORE this boundary's mitigation snapshot. Mitigation is
## gone immediately; recovery [b,b+15) gates any new technique start on this same boundary.
func _end_brace_hold(a: Dictionary, reason: String) -> void:
	if not _brace_holding(a):
		return
	var bid := int(a["brace_action"])
	var rec := int(content.recovery_ticks("brace"))
	a["brace_action"] = -1
	a["brace_start"] = -1
	a["brace_end"] = -1
	a["recovery_end"] = tick + rec
	a["recovery_owner"] = int(a["cycle_intent"])
	telemetry.emit(tick, 15, [int(a["actor_id"]), bid, tick, tick + rec, reason])
	cancelled_this_boundary[int(a["actor_id"])] = true
	_refresh_gates(a)


## GP-F04 / G3 §5: below the threshold an incompatible request voluntarily cancels the charge.
## Costs and cooldowns stay paid, recovery starts, and no same-boundary technique can start.
func _cancel_charge_for_intent(a: Dictionary) -> void:
	var charging: Variant = _charging_action(a)
	if charging == null:
		return
	var d := charging as Dictionary
	d["state"] = "cancelled"
	d["cancel_cause"] = "intent_change"
	a["recovery_end"] = tick + int(d["recovery_ticks"])
	# ARCH-PLAY01-R03-F01: the pending recovery belongs to the OWNER OF THE ACTION BEING
	# CANCELLED. Reading it from the action record keeps the recovery tied to I even when the
	# cycle slot was cleared elsewhere; an autonomous action carries no owner and falls back to
	# the cycle slot exactly as before.
	var cancel_owner := int(d.get("intent", -1))
	if cancel_owner < 0:
		cancel_owner = int(a["cycle_intent"])
	a["recovery_owner"] = cancel_owner
	telemetry.emit(tick, 10, [int(d["action"]), int(a["actor_id"]), null, "intent_change"])
	if int(a["actor_id"]) == 0:
		_record("Interrupted", "intent_change",
			int(content.skill(str(d["skill"])).get("family", 1)), "action")
	a["action"] = null
	cancelled_this_boundary[int(a["actor_id"])] = true
	_refresh_gates(a)


func _accept_intent(a: Dictionary, e: Dictionary, family: int) -> void:
	e["draw_resolved"] = true
	# G3 §5 lifecycle: an incompatible still-charging action is voluntarily cancelled below the
	# threshold (the guard already declined it at/above); an active Brace hold held against a
	# movement/offense intent is ended before the mitigation snapshot. Compatibility is judged by
	# the INTENT that owns the charge, never by the chosen technique's authored family.
	var charging: Variant = _charging_action(a)
	if charging != null and int((charging as Dictionary).get("owning_family", -1)) != family:
		_cancel_charge_for_intent(a)
	if family != 2:
		_end_brace_hold(a, "intent_change")
	# ARCH-PLAY01-R02-F03: a running cycle keeps its captured owner while its charge/commit/
	# travel/hold/recovery is still pending, so a newer waiting J is never written into the
	# owner slot and can never be retired by the older I completing.
	if not _cycle_pending(a):
		a["cycle_intent"] = -1
		a["cycle_request"] = 0
		a["cycle_episode"] = 0
	a["rest_idle_ticks"] = 0
	var lifetime := int(content.tuning["response"]["intent_lifetime_ticks"])
	var iid := int(id_counter["intent"])
	id_counter["intent"] = iid + 1
	var intent := {
		"intent": iid,
		"episode": int(e["episode"]),
		# ARCH-PLAY01-R02-F04 / QA-PLAY01-R02-F05: the genuine request ID stays distinct from
		# the episode ID that merely issued it.
		"request": int(e["latest_request"]),
		"family": family,
		"accepted_tick": tick,
		"expiry_tick": tick + lifetime,
		"state": "active",
		"target_kind": int(e["target_kind"]),
		"target_or_area": e["target_or_area"],
		"goal": null,
		# GP-F01: the observed safety category travels with the intent so later NPC decisions
		# compare against what was OBSERVED, not against the interpreted family.
		"observation_category": str(e.get("observation_category", "")),
	}
	a["accepted_intent"] = intent
	a["last_repeat_credit"] = -9999
	# GP-F02: a successful class-2 interpretation must stay class 2 in the public explanation;
	# only an unset/ignored class falls back to the ordinary understood label.
	var cls := int(e["class"])
	_emit_response(a, e, cls if cls >= 2 else 5,
		int(e["original_family"]), family, tick + lifetime)


func _emit_response(a: Dictionary, e: Dictionary, cls: int, original: int,
		interpreted: int, ready_tick: int, safe_reason: String = "") -> void:
	var rid := int(e["latest_request"])
	telemetry.emit(tick, 3, [rid, int(a["actor_id"]), int(e["episode"]),
		int(a["accepted_intent"]["intent"]) if a["accepted_intent"] != null else null,
		cls, original, interpreted, ready_tick,
		int(a["accepted_intent"]["expiry_tick"]) if a["accepted_intent"] != null else null])
	if int(a["actor_id"]) == 0:
		var cue := _feedback_cue(cls, original, interpreted, safe_reason)
		human_feedback.append({
			"recipient": 0, "request": rid, "tick": tick, "cue": cue["cue"],
			"detail": cue["detail"], "family": original, "kind": "response",
		})
		while human_feedback.size() > 6:
			human_feedback.pop_front()
		pass
	var band_old := M01Observations.fatigue_band(int(a["last_fatigue_centi"]))
	var band_new := M01Observations.fatigue_band(int(a["fatigue_centi"]))
	a["last_fatigue_centi"] = int(a["fatigue_centi"])
	if band_old != band_new:
		telemetry.emit(tick, 14, [int(a["actor_id"]), "fatigue", band_old, band_new, int(a["lock_end"])])


func _record(cue: String, detail: String, family: int, kind: String, recipient: int = 0) -> void:
	if recipient != 0:
		return
	human_feedback.append({"recipient": 0, "request": 0, "tick": tick, "cue": cue,
		"detail": detail, "family": family, "kind": kind})
	while human_feedback.size() > 6:
		human_feedback.pop_front()


func _feedback_cue(cls: int, original: int, interpreted: int, safe_reason: String) -> Dictionary:
	var fam: String = FAMILY_LABEL[original]
	match cls:
		1:
			return {"cue": "No response", "detail": ""}
		2:
			var d := "Interpreted as %s" % FAMILY_LABEL[interpreted]
			if safe_reason != "":
				d += " · Waiting"
			return {"cue": d, "detail": safe_reason}
		3:
			return {"cue": "Declined", "detail": safe_reason}
		4:
			return {"cue": "Hesitating", "detail": ""}
		5, 6:
			return {"cue": "Understood: %s" % fam, "detail": ""}
	return {"cue": fam + " requested", "detail": ""}


func _detect_pre_start_exhaustion() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		if not bool(a["alive"]):
			continue
		var crossed := (int(a["stam"]) <= int(content.tuning["exhaustion"]["stam_trigger_cp"]) \
				or int(a["fatigue_centi"]) >= int(content.tuning["exhaustion"]["fatigue_trigger_centi"])) \
				and not bool(a["lock_latched"])
		if crossed:
			_enter_lock(a)
			_cancel_charged_work(a, "exhaustion")


func _enter_lock(a: Dictionary) -> void:
	if bool(a["lock_latched"]):
		return
	a["lock_latched"] = true
	a["lock_end"] = tick + int(content.tuning["exhaustion"]["lock_ticks"])
	a["physical_locked"] = true
	telemetry.emit(tick, 25, [int(a["actor_id"]), "entry", int(a["lock_end"]),
		int(a["stam"]), int(a["fatigue_centi"])])
	if int(a["actor_id"]) == 0:
		_record("Exhausted", "", 0, "action")


func _cancel_charged_work(a: Dictionary, reason: String) -> void:
	var act: Variant = a["action"]
	if act != null and act is Dictionary:
		var d := act as Dictionary
		if str(d["state"]) in ["preparing", "due"] and int(content.charge_ticks(str(d["skill"]))) > 0:
			d["state"] = "cancelled"
			d["cancel_cause"] = reason
			a["recovery_end"] = tick + int(content.recovery_ticks(str(d["skill"])))
			cancelled_this_boundary[int(a["actor_id"])] = true
			telemetry.emit(tick, 10, [int(d["action"]), int(a["actor_id"]), null, reason])
			if int(a["actor_id"]) == 0:
				_record("Interrupted", reason, int(content.skill(str(d["skill"])).get("family", 1)), "action")
			a["action"] = null
	if bool(a["bound_active"]):
		a["bound_active"] = false
		a["recovery_end"] = tick + int(content.recovery_ticks("short_bound"))
		cancelled_this_boundary[int(a["actor_id"])] = true
		telemetry.emit(tick, 26, [int(a["bound_action"]), int(a["actor_id"]), "end",
			[float(a["x"]), float(a["y"])], reason])
	if int(a["brace_action"]) >= 0:
		var bid := int(a["brace_action"])
		a["brace_action"] = -1
		a["brace_start"] = -1
		a["brace_end"] = -1
		a["recovery_end"] = tick + int(content.recovery_ticks("brace"))
		cancelled_this_boundary[int(a["actor_id"])] = true
		telemetry.emit(tick, 15, [int(a["actor_id"]), bid, tick, tick, reason])


func _plan_and_start(a: Dictionary) -> void:
	if _in_lock(a):
		# Keep the trigger signature honest across a lock window without planning.
		_remember_plan_watch(a)
		return
	var act: Variant = a["action"]
	if act != null and act is Dictionary and str((act as Dictionary)["state"]) in ["preparing", "due", "committed"]:
		return
	if bool(a["bound_active"]):
		return
	if int(a["control_mode"]) != 0 and mode == "diagnostic" and int(a["actor_id"]) == 1:
		return
	var enemy: Dictionary = actors[1 - int(a["actor_id"])]
	# G3 §8: autonomous planning every 15 ticks while idle, or on action/observation/intent change.
	# No accepted-intent or null-goal bypass; an unchanged view/intent never replans early.
	if tick < int(a["next_plan_tick"]) and not _plan_trigger(a):
		if a["goal"] != null:
			_execute_goal(a)
		return
	_execute_plan(a, enemy)
	_remember_plan_watch(a)


func _plan_watch(a: Dictionary) -> Dictionary:
	var intent_key := -1
	var intent: Variant = a["accepted_intent"]
	if intent != null and intent is Dictionary:
		intent_key = int((intent as Dictionary).get("episode", -1))
	var action_key := -1
	var action_state := "none"
	var act: Variant = a["action"]
	if act != null and act is Dictionary:
		action_key = int((act as Dictionary).get("action", -1))
		action_state = str((act as Dictionary).get("state", ""))
	return {
		"intent": intent_key,
		"action": action_key,
		"action_state": action_state,
		"brace": int(a["brace_action"]),
		"bound": bool(a["bound_active"]),
		"locked": _in_lock(a),
		"visible": bool(a["enemy_visible"]),
		"memory": bool(a["memory_valid"]),
	}


func _plan_trigger(a: Dictionary) -> bool:
	var stored: Variant = plan_watch.get(int(a["actor_id"]), null)
	if stored == null or not (stored is Dictionary) or (stored as Dictionary).is_empty():
		return true
	var current := _plan_watch(a)
	for k in current:
		if not (stored as Dictionary).has(k) or (stored as Dictionary)[k] != current[k]:
			return true
	return false


func _remember_plan_watch(a: Dictionary) -> void:
	plan_watch[int(a["actor_id"])] = _plan_watch(a)


func _execute_plan(a: Dictionary, enemy: Dictionary) -> void:
	var knowledge := "unknown"
	if bool(a["enemy_visible"]):
		knowledge = "visible"
	elif bool(a["memory_valid"]):
		knowledge = "last_known"
	var plan := behavior.plan(a, enemy, tick, knowledge)
	nav_searches += behavior.decision_searches
	nav_expansions += behavior.decision_expansions
	nav_violations += behavior.decision_violations
	nav_max_decision_expansions = maxi(nav_max_decision_expansions, behavior.decision_expansions)
	a["knowledge_state"] = knowledge
	a["next_plan_tick"] = tick + int(content.tuning["vision"]["planning_ticks"])
	# G3 §7: bounded Instinct selection happens before PLAN telemetry and before any start.
	# An empty or single-candidate pool draws no RNG.
	var cands: Array = plan.get("candidates", [])
	if plan.get("skill", null) == null and not cands.is_empty():
		_sel_aid = int(a["actor_id"])
		plan["skill"] = behavior.select_by_utility(cands, plan.get("fits", {}),
			int(a["instinct"]), Callable(self, "_sel_draw"))
	a["last_plan"] = plan
	# A picked technique never also drives ordinary movement; plan["goal"] stays live so
	# _try_start can still read (and truncate) the Bound route through the shared reference.
	var picked: Variant = plan.get("skill", null)
	a["goal"] = null if (picked is String and str(picked) != "") else plan.get("goal", null)
	# ARCH-PLAY01-R02-F04: PLAN carries the causal ACCEPTED intent's request/episode/intent, never
	# the mutable pending response episode, which may already belong to a later command. With no
	# accepted intent the plan has no trainer attribution at all.
	var plan_req := 0
	var plan_ep := 0
	var plan_iid := 0
	var accepted: Variant = a["accepted_intent"]
	if accepted != null and accepted is Dictionary:
		var acc := accepted as Dictionary
		plan_req = int(acc.get("request", 0))
		plan_ep = int(acc.get("episode", 0))
		plan_iid = int(acc.get("intent", 0))
	telemetry.emit(tick, 5, [int(a["actor_id"]),
		plan_req,
		plan_ep,
		plan_iid,
		"%d.%d" % [int(a["actor_id"]), tick],
		knowledge, str(plan.get("skill", "")) if plan.get("skill", null) != null else null,
		plan.get("candidates", []), str(plan.get("fit_reason", ""))])
	var skill: Variant = plan.get("skill", null)
	if skill != null and str(skill) != "":
		_try_start(a, str(skill), plan, enemy)
		return
	var goal: Variant = plan.get("goal", null)
	if goal is Dictionary and str((goal as Dictionary).get("kind", "")) == "move":
		# ARCH-F04: capture owner I at fallback-goal assignment too, so travel/search/patrol
		# completion retires exactly the intent that chose it.
		_capture_cycle_owner(a)
		_execute_goal(a)
		return
	# Rest fallback: the 60 actual idle ticks are counted from here, and no 15-tick replan
	# resets them.
	_capture_cycle_owner(a)


func _execute_goal(a: Dictionary) -> void:
	var goal: Variant = a["goal"]
	if goal is Dictionary and str((goal as Dictionary).get("kind", "")) == "move":
		_advance_goal(a)


## Advances the waypoint index past waypoints already underfoot and completes the goal when the
## final point is reached. Idempotent within a boundary: calling it twice never skips a waypoint
## that has not been stood on, and completion clears the goal so a second call is a no-op.
func _advance_goal(a: Dictionary) -> bool:
	var goal: Variant = a["goal"]
	if not (goal is Dictionary) or str((goal as Dictionary).get("kind", "")) != "move":
		return true
	var g := goal as Dictionary
	var route: Array = g.get("route", [])
	var stop := float(g.get("stop_mwu", 0.0)) + arena.GUARD
	var px := float(a["x"])
	var py := float(a["y"])
	var point: Variant = g.get("point", null)
	if point is Array:
		var qx := float((point as Array)[0]) - px
		var qy := float((point as Array)[1]) - py
		if sqrt(qx * qx + qy * qy) <= stop:
			_complete_goal(a)
			return false
	var idx := int(g.get("i", 0))
	while idx < route.size() - 1:
		var wp: Array = route[idx]
		var wx := float(wp[0]) - px
		var wy := float(wp[1]) - py
		if sqrt(wx * wx + wy * wy) > arena.GUARD:
			break
		idx += 1
	g["i"] = idx
	if route.is_empty():
		_complete_goal(a)
		return false
	if idx >= route.size() - 1:
		var lp: Array = route[route.size() - 1]
		var lx := float(lp[0]) - px
		var ly := float(lp[1]) - py
		if sqrt(lx * lx + ly * ly) <= arena.GUARD:
			_complete_goal(a)
			return false
	return true


func _complete_goal(a: Dictionary) -> void:
	var goal: Variant = a["goal"]
	if goal is Dictionary:
		var g := goal as Dictionary
		var purpose := str(g.get("purpose", ""))
		if purpose == "patrol":
			var pidx := int(g.get("patrol_index", -1))
			var visited: Array = a["patrol_visited"]
			if pidx >= 0 and not visited.has(pidx):
				visited.append(pidx)
			# G3 §2: revisit the public patrol only after all four points are visited.
			if visited.size() >= arena.patrol.size():
				a["patrol_visited"] = []
		elif purpose == "search":
			var point: Variant = g.get("point", null)
			var svisited: Array = a["search_visited"]
			if point is Array and not _point_list_has(svisited, point as Array):
				svisited.append([float((point as Array)[0]), float((point as Array)[1])])
	a["goal"] = null
	a["next_plan_tick"] = 0
	a["rest_idle_ticks"] = 0
	# ARCH-F04: a fallback goal completes at lawful arrival and retires its owning cycle —
	# but only when no technique cycle of that same actor is still pending.
	if not _cycle_pending(a):
		_complete_cycle(a, int(a["cycle_intent"]))


func _point_list_has(list: Array, point: Array) -> bool:
	for p in list:
		if float(p[0]) == float(point[0]) and float(p[1]) == float(point[1]):
			return true
	return false


func _try_start(a: Dictionary, sid: String, plan: Dictionary, enemy: Dictionary) -> void:
	if _in_lock(a):
		return
	# GP-F04: an active Brace hold never coexists with a new technique start. An accepted
	# movement/offense intent ends the hold first (see _accept_intent) and then waits out
	# recovery [b,b+15); an autonomous plan simply waits for the hold to expire.
	if _brace_holding(a):
		return
	var fatigue_exhausted := int(a["fatigue_centi"]) >= int(content.tuning["fatigue"]["exhausted_threshold_centi"])
	if fatigue_exhausted:
		return
	if not bool(a["affordable"].get(sid, false)):
		return
	if not bool(a["ready"].get(sid, false)):
		return
	var def := content.skill(sid)
	if sid == "quick_claw":
		if not bool(enemy["alive"]) or not bool(a["enemy_visible"]):
			return
		var d := sqrt(pow(float(enemy["x"]) - float(a["x"]), 2.0) + pow(float(enemy["y"]) - float(a["y"]), 2.0))
		if d > float(def["range_mwu"]):
			return
		if not arena.line_of_effect(float(a["x"]), float(a["y"]), float(enemy["x"]), float(enemy["y"])):
			return
	if sid == "short_bound":
		var goal: Variant = plan.get("goal", null)
		var route: Array = []
		if goal is Dictionary and (goal as Dictionary).get("route", null) is Array:
			route = (goal as Dictionary)["route"]
		if route.is_empty():
			return
		var total := arena.route_length(route)
		if total < float(def.get("min_known_path_mwu", 200)):
			return
		if total > float(def["max_travel_mwu"]) + 1e-6:
			route = arena.truncate_route(route, float(def["max_travel_mwu"]))
			total = arena.route_length(route)
		plan["goal"]["route"] = route

	var aid := int(id_counter["action"])
	id_counter["action"] = aid + 1
	var charge := content.charge_ticks(sid)
	var cost := int(def["stam_cost_cp"])
	var target_kind := 2 if sid == "quick_claw" else (1 if sid == "brace" else 3)
	var target: Variant = null
	if sid == "quick_claw":
		target = 1 - int(a["actor_id"])
	elif sid == "short_bound":
		var g: Dictionary = plan["goal"]
		var ep: Array = g["route"][g["route"].size() - 1]
		target = [int(ep[0]), int(ep[1])]
	a["stam"] = int(a["stam"]) - cost
	a["cooldown_end"][sid] = tick + content.cooldown_ticks(sid)
	a["fatigue_centi"] = mini(int(content.tuning["fatigue"]["cap_centi"]),
		int(a["fatigue_centi"]) + int(content.tuning["fatigue"]["technique_start_add"]))
	started_technique[int(a["actor_id"])] = true
	var due := tick + charge
	# ARCH-PLAY01-R02-F04: three distinct genuine IDs. `request` is the causal accepted
	# request, `episode` the issuing episode, `intent` the accepted intent. An autonomous start
	# carries none of them, so it has no trainer attribution.
	var held: Variant = a["accepted_intent"]
	var has_intent := held != null and held is Dictionary
	# GP-PLAY01-R03-F01: compatibility is judged by the GENERAL BEHAVIOUR CONTEXT that chose this
	# preparation. A trainer-owned charge keeps its accepted intent's family; an autonomous charge
	# takes the plan's existing context (defensive planning -> Defense, disengaging -> Run)
	# instead of the authored skill family, so a Defense-owned autonomous Bound waits for Defense
	# and a disengaging one waits for Run. request/episode/intent stay absent for autonomy, so no
	# trainer attribution is invented. A plan without a context (direct diagnostic starts) keeps
	# the previous -1.
	var owning := -1
	if has_intent:
		owning = int((held as Dictionary).get("family", -1))
	else:
		owning = int(plan.get("context_family", -1))
	var action := {
		"action": aid, "actor": int(a["actor_id"]), "life": 1,
		"request": int((held as Dictionary).get("request", 0)) if has_intent else 0,
		"episode": int((held as Dictionary).get("episode", 0)) if has_intent else 0,
		"intent": int((held as Dictionary).get("intent", -1)) if has_intent else -1,
		"owning_family": owning,
		"skill": sid, "target": target, "target_kind": target_kind,
		"start_tick": tick, "due_tick": due,
		"recovery_ticks": content.recovery_ticks(sid),
		"paid_cost": cost, "cooldown_end": int(a["cooldown_end"][sid]),
		"stability": int(def["stability"]), "interrupt_power": int(def["interrupt_power"]),
		"state": "preparing" if charge > 0 else "due",
		"cancel_cause": "", "plan": plan.duplicate(true),
	}
	if charge == 0:
		action["state"] = "due"
	a["action"] = action
	# ARCH-F04: capture owner I at action assignment; it is retained through commitment/travel/
	# hold/recovery and retires the cycle only at recovery end.
	a["cycle_intent"] = int(action["intent"])
	a["cycle_request"] = int(action["request"])
	a["cycle_episode"] = int(action["episode"])
	a["recovery_owner"] = int(action["intent"])
	a["rest_idle_ticks"] = 0
	telemetry.emit(tick, 6, [aid, int(a["actor_id"]), 1,
		int(action["request"]), sid, target, due, due + content.recovery_ticks(sid)])
	telemetry.emit(tick, 7, [aid, int(a["actor_id"]), cost, int(a["stam"]), int(a["cooldown_end"][sid])])
	if sid == "short_bound":
		var g2: Dictionary = plan["goal"]
		a["bound_path"] = g2["route"]
		a["bound_total"] = arena.route_length(g2["route"])
		a["bound_progress"] = 0.0
		a["bound_action"] = aid
		a["bound_active"] = false
	if sid == "brace":
		a["brace_prepare_action"] = aid
	_refresh_gates(a)
	var threshold := int(content.tuning["exhaustion"]["fatigue_trigger_centi"])
	if not bool(a["lock_latched"]) and (int(a["stam"]) <= 0 or int(a["fatigue_centi"]) >= threshold):
		_enter_lock(a)
		if charge > 0:
			_cancel_charged_work(a, "start_exhaustion")
		else:
			a["recovery_end"] = tick + content.recovery_ticks(sid)
			cancelled_this_boundary[int(a["actor_id"])] = false
		_refresh_gates(a)


func _advance_actions() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		var act: Variant = a["action"]
		if act == null or not (act is Dictionary):
			continue
		var d := act as Dictionary
		if str(d["state"]) == "preparing" and tick >= int(d["due_tick"]):
			d["state"] = "due"
			telemetry.emit(tick, 8, [int(d["action"]), int(a["actor_id"])])


func _cut3() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		a["def_frozen"] = int(a["def"])
		a["brace_frozen"] = int(a["brace_end"]) > tick and int(a["brace_start"]) >= 0 and tick > int(a["brace_start"])
	var qualified: Array = []
	for e in pending_effects:
		if int(e.get("impact_tick", -1)) != tick:
			continue
		if str(e.get("qualification", "qualified")) != "qualified":
			telemetry.emit(tick, 11, [int(e["effect"]), int(e.get("action", 0)), int(e.get("source", 0)),
				int(e["target"]), int(actors[int(e["target"])]["life"]), "blocked", int(e.get("batch", 0)), ""])
			continue
		qualified.append(e)
	pending_effects = pending_effects.filter(func(e): return int(e.get("impact_tick", -1)) != tick)
	for e in qualified:
		var tgt_idx := int(e["target"])
		var tgt: Dictionary = actors[tgt_idx]
		var act: Variant = tgt["action"]
		if act != null and act is Dictionary:
			var d := act as Dictionary
			if str(d["state"]) in ["preparing", "due"] and int(content.charge_ticks(str(d["skill"]))) > 0:
				if int(e.get("interrupt_power", 1)) >= int(d["stability"]):
					d["state"] = "cancelled"
					d["cancel_cause"] = "interrupt"
					tgt["recovery_end"] = tick + int(d["recovery_ticks"])
					cancelled_this_boundary[tgt_idx] = true
					telemetry.emit(tick, 10, [int(d["action"]), tgt_idx, int(e["effect"]), "interruption"])
					if tgt_idx == 0:
						# COMMAND-FEEDBACK01: own prior-impact interruption is observable
						# through the existing public channel only. No NPC cue, no duplicate
						# telemetry CANCEL; action-null and event11 ordering stay intact.
						_record("Interrupted", "", 0, "action")
					tgt["action"] = null
		telemetry.emit(tick, 11, [int(e["effect"]), int(e.get("action", 0)), int(e.get("source", 0)),
			tgt_idx, int(tgt["life"]), "hit", int(e.get("batch", 0)),
			"%d:%d:%d" % [int(e.get("batch", 0)), tgt_idx, int(tgt["life"])]])
	for i in 2:
		_refresh_gates(actors[i])


func _cut4() -> void:
	var committed: Array = []
	for i in 2:
		var a: Dictionary = actors[i]
		var act: Variant = a["action"]
		if act == null or not (act is Dictionary):
			continue
		var d := act as Dictionary
		if str(d["state"]) != "due":
			continue
		if _in_lock(a) and int(content.charge_ticks(str(d["skill"]))) > 0:
			d["state"] = "cancelled"
			d["cancel_cause"] = "pre_start_exhaustion"
			a["recovery_end"] = tick + int(d["recovery_ticks"])
			telemetry.emit(tick, 10, [int(d["action"]), i, null, "pre_start_exhaustion"])
			a["action"] = null
			cancelled_this_boundary[i] = true
			continue
		if not _release_legal(a, d):
			d["state"] = "cancelled"
			d["cancel_cause"] = "illegal_release"
			a["recovery_end"] = tick + int(d["recovery_ticks"])
			telemetry.emit(tick, 10, [int(d["action"]), i, null, "illegal_release"])
			a["action"] = null
			cancelled_this_boundary[i] = true
			continue
		committed.append([i, d])
	batch_counter += 1
	var batch := batch_counter
	for pair in committed:
		var i := int(pair[0])
		var d: Dictionary = pair[1]
		var a: Dictionary = actors[i]
		d["state"] = "committed"
		d["commit_tick"] = tick
		var effects: Array = []
		var sid := str(d["skill"])
		if sid == "quick_claw":
			var eid := int(id_counter["effect"])
			id_counter["effect"] = eid + 1
			var def := content.skill(sid)
			effects.append({
				"effect": eid, "action": int(d["action"]), "source": i,
				"target": int(d["target"]), "kind": "damage",
				"impact_tick": tick, "interrupt_power": int(def["interrupt_power"]),
				"qualification": "qualified", "batch": batch,
				"base_power_cp": int(def["base_power_cp"]),
				"source_atk": int(a["atk"]),
				"target_def": int(actors[int(d["target"])]["def"]),
				"brace_factor_bp": 10000,
				"phase_factor_bp": 10000,
			})
			# ARCH-F04: retain the RuntimeAction through Quick's 21-tick recovery so the
			# telemetry action_state "recovering" is real and _movement_allowed can suppress
			# movement for exactly that interval. The record is dropped at recovery end.
			d["state"] = "recovering"
			a["recovery_end"] = tick + content.recovery_ticks(sid)
			a["public_action"] = "claw"
		elif sid == "brace":
			a["brace_action"] = int(d["action"])
			a["brace_start"] = tick
			a["brace_end"] = tick + 1 + int(content.skill(sid)["active_boundaries"])
			a["action"] = null
			telemetry.emit(tick, 15, [i, int(d["action"]), tick + 1, int(a["brace_end"]), "activate"])
			a["public_action"] = "bracing"
		elif sid == "short_bound":
			a["bound_active"] = true
			a["bound_progress"] = 0.0
			a["action"] = null
			telemetry.emit(tick, 26, [int(d["action"]), i, "start", [float(a["x"]), float(a["y"])], "commit"])
			a["public_action"] = "bound"
		else:
			a["action"] = null
		telemetry.emit(tick, 9, [int(d["action"]), i, effects, batch])
		if int(a["actor_id"]) == 0:
			# COMMAND-FEEDBACK01: name the ACTUAL committed technique at this event9
			# boundary, not its authored family — Defense-owned Short Bound must not read
			# "Executing Run". Family below stays metadata and never names the action.
			var released := "Technique released"
			match sid:
				"quick_claw":
					released = "Quick Claw released"
				"brace":
					released = "Brace released"
				"short_bound":
					released = "Short Bound released"
			_record(released, "", int(content.skill(sid).get("family", 1)), "action")
		for e in effects:
			pending_effects.append(e)
	_refresh_gates(actors[0])
	_refresh_gates(actors[1])


func _release_legal(a: Dictionary, d: Dictionary) -> bool:
	var sid := str(d["skill"])
	if sid == "quick_claw":
		var tgt: Dictionary = actors[int(d["target"])]
		if not bool(tgt["alive"]):
			return false
		var def := content.skill(sid)
		var dist := sqrt(pow(float(tgt["x"]) - float(a["x"]), 2.0) + pow(float(tgt["y"]) - float(a["y"]), 2.0))
		if dist > float(def["range_mwu"]):
			return false
		if not arena.line_of_effect(float(a["x"]), float(a["y"]), float(tgt["x"]), float(tgt["y"])):
			return false
		if not bool(a["enemy_visible"]):
			return false
	return true


func _cut5() -> void:
	batch_counter += 1
	var batch := batch_counter
	var healing := {0: 0, 1: 0}
	var damage := {0: 0, 1: 0}
	var contributors := {0: [], 1: []}
	var hp_start := {0: int(actors[0]["hp"]), 1: int(actors[1]["hp"])}
	var player_hit := false
	var to_apply: Array = []
	for e in pending_effects:
		if int(e.get("impact_tick", -1)) != tick:
			continue
		if str(e.get("kind", "")) == "damage":
			to_apply.append(e)
		elif str(e.get("kind", "")) == "heal":
			healing[int(e["target"])] = int(healing[int(e["target"])]) + int(e.get("permit_cp", 0))
			telemetry.emit(tick, 13, [int(e["effect"]), int(e["target"]), batch, int(e.get("permit_cp", 0))])
	pending_effects = pending_effects.filter(func(e): return int(e.get("impact_tick", -1)) != tick)

	for e in to_apply:
		var tgt_idx := int(e["target"])
		var tgt: Dictionary = actors[tgt_idx]
		if not bool(tgt["alive"]):
			telemetry.emit(tick, 11, [int(e["effect"]), int(e["action"]), int(e["source"]),
				tgt_idx, 1, "invalid_life", batch, "%d:%d:%d" % [batch, tgt_idx, 1]])
			if int(e["source"]) == 0:
				_record("Miss", "", 1, "action")
			continue
		var brace_bp := 10000
		if int(tgt["brace_end"]) > tick and int(tgt["brace_start"]) >= 0 and tick > int(tgt["brace_start"]):
			brace_bp = int(content.skill("brace")["mitigation_bp"])
		var base_power := int(e["base_power_cp"])
		var src_atk := int(e["source_atk"])
		var tgt_def := int(tgt["def"])
		var k := int(tgt["k_defense"])
		var offensive := float(base_power) * float(src_atk) / 100.0
		var raw := offensive * float(k) / float(k + maxf(0.0, float(tgt_def)))
		raw = raw * float(brace_bp) / 10000.0
		var effective := int(floor(raw + 0.5))
		if effective < 0:
			effective = 0
		damage[tgt_idx] = int(damage[tgt_idx]) + effective
		contributors[tgt_idx].append(int(e["effect"]))
		if effective > 0 and (int(e["source"]) == 0 or tgt_idx == 0):
			player_hit = true
		telemetry.emit(tick, 12, [int(e["effect"]), tgt_idx, batch, base_power, src_atk,
			tgt_def, brace_bp, 10000, effective])

	for i in 2:
		var a: Dictionary = actors[i]
		if not bool(a["alive"]):
			continue
		var after := int(hp_start[i]) + int(healing[i]) - int(damage[i])
		after = clampi(after, 0, int(a["hp_max"]))
		a["hp"] = after
		if after <= 0:
			a["alive"] = false
			a["life"] = 1
			ko_this_boundary[i] = true
			telemetry.emit(tick, 19, [i, 1, batch, contributors[i]])
			_cancel_on_ko(a)

	if player_hit:
		_record("Hit", "", 1, "action")
	var alive_count := 0
	for i in 2:
		if bool(actors[i]["alive"]):
			alive_count += 1
	if alive_count < 2:
		ko_actors = []
		for i in 2:
			if not bool(actors[i]["alive"]):
				ko_actors.append(i)
		_end_encounter(1 if alive_count == 1 else 2, batch)
	_flush_due_arrivals()


func _flush_due_arrivals() -> void:
	pass


func _cancel_on_ko(a: Dictionary) -> void:
	a["action"] = null
	a["bound_active"] = false
	a["brace_action"] = -1
	a["brace_start"] = -1
	a["brace_end"] = -1
	a["response_episode"] = null
	a["accepted_intent"] = null
	a["cycle_intent"] = -1
	a["recovery_owner"] = -1
	a["rest_idle_ticks"] = 0
	a["cycle_request"] = 0
	a["cycle_episode"] = 0


func _cut6() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		if not bool(a["alive"]):
			continue
		_count_rest_idle(a)
		if ko_this_boundary[i] or started_technique[i] or cancelled_this_boundary[i]:
			_publish_bands(a)
			continue
		_apply_resource_row(a)
		_publish_bands(a)
	if not ended:
		_update_vision_and_search()
		_npc_tick()
		_publish_public_actions()


## ARCH-F04 / G3 §5: a rest fallback completes after 60 ACTUAL idle ticks — no action, Bound
## travel, Brace hold, fallback goal or pending recovery this boundary. Running the 15-tick
## planner never resets this progress; only genuine activity does.
func _count_rest_idle(a: Dictionary) -> void:
	var g: Variant = a["goal"]
	var idle_goal := g == null or not (g is Dictionary) \
			or str((g as Dictionary).get("kind", "")) != "move"
	if int(a["cycle_intent"]) >= 0 and a["action"] == null and not bool(a["bound_active"]) \
			and int(a["brace_action"]) < 0 and idle_goal \
			and tick >= int(a["recovery_end"]):
		a["rest_idle_ticks"] = int(a["rest_idle_ticks"]) + 1
		if int(a["rest_idle_ticks"]) >= REST_IDLE_TICKS:
			_complete_cycle(a, int(a["cycle_intent"]))
	else:
		a["rest_idle_ticks"] = 0


func _state_row(a: Dictionary) -> String:
	if _in_lock(a):
		return "lock"
	if bool(a["bound_active"]) or (a["action"] != null and str((a["action"] as Dictionary).get("state", "")) == "preparing" \
			and int(content.charge_ticks(str((a["action"] as Dictionary)["skill"]))) > 0):
		return "charge"
	if int(a["brace_end"]) > tick and int(a["brace_start"]) >= 0 and tick > int(a["brace_start"]):
		return "brace"
	if tick < int(a["recovery_end"]):
		return "recovery"
	if bool(a["moved_this_boundary"]):
		return "move"
	return "rest"


func _apply_resource_row(a: Dictionary) -> void:
	var row := _state_row(a)
	var regen: Dictionary = content.tuning["regen"]
	var cp := 0
	var decay := int(content.tuning["fatigue"]["decay_rest_centi"])
	match row:
		"lock":
			cp = int(regen["lock_cp_per_tick"])
			decay = int(content.tuning["fatigue"]["decay_rest_centi"])
		"charge":
			cp = int(regen["charge_cp_per_tick"])
			decay = int(content.tuning["fatigue"]["decay_technique_centi"])
		"brace":
			cp = int(regen["brace_hold_cp_per_tick"])
			decay = int(content.tuning["fatigue"]["decay_technique_centi"])
		"recovery":
			cp = int(regen["recovery_cp_per_tick"])
			decay = int(content.tuning["fatigue"]["decay_technique_centi"])
		"move":
			cp = int(regen["move_cp_per_tick"])
			decay = int(content.tuning["fatigue"]["decay_move_centi"])
		"rest":
			cp = int(regen["rest_cp_per_tick"])
			decay = int(content.tuning["fatigue"]["decay_rest_centi"])
	a["stam"] = clampi(int(a["stam"]) + cp, 0, int(a["stam_max"]))
	a["fatigue_centi"] = clampi(int(a["fatigue_centi"]) - decay, 0, int(content.tuning["fatigue"]["cap_centi"]))
	a["moved_this_boundary"] = false
	_refresh_gates(a)


func _publish_bands(a: Dictionary) -> void:
	var hp_b := M01Observations.hp_band(int(a["hp"]), int(a["hp_max"]))
	if hp_b != int(a["last_hp_band"]):
		telemetry.emit(tick, 14, [int(a["actor_id"]), "hp", int(a["last_hp_band"]), hp_b, int(a["lock_end"])])
		a["last_hp_band"] = hp_b
	var st_b := M01Observations.stam_band(int(a["stam"]), int(a["stam_max"]))
	if st_b != int(a["last_stam_band"]):
		telemetry.emit(tick, 14, [int(a["actor_id"]), "stam", int(a["last_stam_band"]), st_b, int(a["lock_end"])])
		a["last_stam_band"] = st_b
	var fa_b := M01Observations.fatigue_band(int(a["fatigue_centi"]))
	if fa_b != int(a["last_fatigue_band"]):
		telemetry.emit(tick, 14, [int(a["actor_id"]), "fatigue", int(a["last_fatigue_band"]), fa_b, int(a["lock_end"])])
		a["last_fatigue_band"] = fa_b


func _movement_cut() -> void:
	var prior := [[float(actors[0]["x"]), float(actors[0]["y"])],
		[float(actors[1]["x"]), float(actors[1]["y"])]]
	# R01/FIX01 (ARCH F01/QA F01): each actor proposes a time-parameterized piecewise trajectory
	# for this boundary. Static clipping runs per leg, both actors are evaluated over shared time
	# intervals, and positions/progress/events are committed from the applied result.
	var poly: Array = [[], []]
	var arcs: Array = [[], []]
	var intended := [0.0, 0.0]
	for i in 2:
		var a: Dictionary = actors[i]
		a["moved_this_boundary"] = false
		poly[i] = [[prior[i][0], prior[i][1]]]
		if not bool(a["alive"]):
			arcs[i] = M01Arena.poly_arcs(poly[i])
			continue
		var want := 0.0
		if bool(a["bound_active"]):
			var step := float(content.skill("short_bound")["travel_mwu_per_tick"])
			var remaining := float(a["bound_total"]) - float(a["bound_progress"])
			want = minf(step, remaining)
			if want > 0.0:
				poly[i] = _bound_polyline(a, want)
		elif _movement_allowed(a):
			if not _advance_goal(a):
				want = 0.0
			else:
				var goal: Variant = a["goal"]
				if goal is Dictionary and str((goal as Dictionary).get("kind", "")) == "move":
					var route: Array = (goal as Dictionary).get("route", [])
					if not route.is_empty():
						var tp: Array = route[int((goal as Dictionary).get("i", 0))]
						var dx: float = float(tp[0]) - float(prior[i][0])
						var dy: float = float(tp[1]) - float(prior[i][1])
						var d := sqrt(dx * dx + dy * dy)
						var speed := float(a["mov_mwu_per_s"]) / 60.0
						if d > 0.001:
							want = minf(speed, d)
							poly[i] = [prior[i], [prior[i][0] + dx * (want / d),
								prior[i][1] + dy * (want / d)]]
		poly[i] = _clip_polyline(poly[i])
		arcs[i] = M01Arena.poly_arcs(poly[i])
		# The time scale is always the distance the actor WOULD cover at its boundary speed, so a
		# statically truncated trajectory ends early instead of silently shrinking its speed.
		intended[i] = want
	# ARCH-PLAY01-R02-F02: occurrence and fraction are returned separately, so a contact that
	# lands exactly on the boundary end (fraction 1.0) is no longer mistaken for "no contact".
	var contact_res: Array = M01Arena.earliest_contact_polyline(poly[0], arcs[0], intended[0],
		poly[1], arcs[1], intended[1], arena.contact_dist)
	var contact := bool(contact_res[1])
	var frac := float(contact_res[0])
	for i in 2:
		var a: Dictionary = actors[i]
		var arc_end := float(arcs[i][arcs[i].size() - 1])
		var applied := M01Arena.poly_point(poly[i], arcs[i], intended[i], frac)
		var travelled := minf(frac * intended[i], arc_end)
		var applied_x := float(applied[0])
		var applied_y := float(applied[1])
		a["x"] = applied_x
		a["y"] = applied_y
		a["facing"] = _facing_for(prior[i], applied, int(a["facing"]))
		if sqrt(pow(applied_x - prior[i][0], 2.0)
				+ pow(applied_y - prior[i][1], 2.0)) > 1e-9:
			a["moved_this_boundary"] = true
		if bool(a["bound_active"]):
			# Arc progress, not Euclidean displacement: a crossed corner advances the full
			# 200 mWU budget even though the straight-line displacement is shorter.
			var progress_before := float(a["bound_progress"])
			var progress_after := progress_before + travelled
			a["bound_progress"] = progress_after
			var unfinished := progress_after < float(a["bound_total"]) - 1e-6
			var travel_short: bool = travelled < float(intended[i]) - 1e-6
			# Terminal events follow the committed position, never a proposed one. Contact at
			# fraction 1.0 still ends an unfinished route on THIS boundary instead of waiting for
			# a next-boundary fraction-0 obstruction.
			if travel_short or (contact and unfinished):
				_obstruct_bound(a, _bound_terminal_reason(i, contact, frac, arc_end,
					intended[i], travel_short))
			elif not unfinished:
				_finish_bound(a, "arrived")


## ARCH-PLAY01-R02-F02: pick the terminal cause for a Bound obstruction. The actor's own static
## limit is the earlier event when it stopped before the shared contact time; otherwise the body
## contact is the cause. A contact arriving after an earlier static stop keeps "static".
func _bound_terminal_reason(i: int, contact: bool, contact_frac: float, arc_end: float,
		intended: float, travel_short: bool) -> String:
	if not contact:
		return "static"
	if travel_short and intended > 1e-12 and arc_end < intended - 1e-6 \
			and contact_frac > arc_end / intended + 1e-9:
		return "static"
	return "body_contact"


## Proposed Bound trajectory for this boundary: walk the committed route from the current arc
## progress for `distance` mWU, emitting every crossed waypoint so cornered routes stay
## time-parameterized instead of collapsing onto a start-to-end chord.
func _bound_polyline(a: Dictionary, distance: float) -> Array:
	var path: Array = a["bound_path"]
	var progress := float(a["bound_progress"])
	var target := progress + distance
	var out: Array = [[float(a["x"]), float(a["y"])]]
	var cum := 0.0
	for i in range(path.size() - 1):
		var p0: Array = path[i]
		var p1: Array = path[i + 1]
		var dx := float(p1[0]) - float(p0[0])
		var dy := float(p1[1]) - float(p0[1])
		var seg := sqrt(dx * dx + dy * dy)
		if seg < 1e-9:
			continue
		var seg_end := cum + seg
		if seg_end <= progress + 1e-9:
			cum = seg_end
			continue
		if target <= seg_end + 1e-9:
			var f := (target - cum) / seg
			out.append([float(p0[0]) + dx * f, float(p0[1]) + dy * f])
			return out
		out.append([float(p1[0]), float(p1[1])])
		cum = seg_end
	return out


## Truncates a proposed trajectory at the first statically illegal position, leg by leg, so a
## route that crosses a corner never sweeps the chord that cuts through the corner.
func _clip_polyline(proposal: Array) -> Array:
	var out: Array = [[float(proposal[0][0]), float(proposal[0][1])]]
	for i in range(1, proposal.size()):
		var frm: Array = out[out.size() - 1]
		var to: Array = proposal[i]
		var t := arena.swept_static_limit(frm, to)
		if t >= 1.0 - 1e-12:
			out.append([float(to[0]), float(to[1])])
			continue
		if t > 1e-12:
			out.append([float(frm[0]) + (float(to[0]) - float(frm[0])) * t,
				float(frm[1]) + (float(to[1]) - float(frm[1])) * t])
		break
	return out


func _movement_allowed(a: Dictionary) -> bool:
	if _in_lock(a):
		return false
	if bool(a["bound_active"]):
		return false
	if a["action"] != null:
		var d := a["action"] as Dictionary
		var st := str(d.get("state", ""))
		if st == "preparing" or st == "due" or st == "committed":
			if str(d.get("skill", "")) != "short_bound":
				return false
			if int(content.charge_ticks(str(d.get("skill", "")))) > 0:
				return false
		elif st == "recovering":
			# GP-F04: Quick's 21-tick recovery suppresses movement; Brace/Bound recovery let
			# ordinary locomotion continue (they no longer own a RuntimeAction).
			if str(d.get("skill", "")) == "quick_claw":
				return false
	if int(a["brace_end"]) > tick and int(a["brace_start"]) >= 0 and tick > int(a["brace_start"]):
		return false
	return true


func _obstruct_bound(a: Dictionary, reason: String) -> void:
	telemetry.emit(tick, 26, [int(a["bound_action"]), int(a["actor_id"]), "obstructed",
		[float(a["x"]), float(a["y"])], reason])
	_finish_bound(a, reason)


func _finish_bound(a: Dictionary, reason: String) -> void:
	if not bool(a["bound_active"]):
		return
	a["bound_active"] = false
	a["recovery_end"] = tick + int(content.recovery_ticks("short_bound"))
	telemetry.emit(tick, 26, [int(a["bound_action"]), int(a["actor_id"]), "end",
		[float(a["x"]), float(a["y"])], reason])


static func _facing_for(from: Array, to: Array, current: int) -> int:
	var dx := float(to[0]) - float(from[0])
	var dy := float(to[1]) - float(from[1])
	if dx * dx + dy * dy < 1e-9:
		return current
	if absf(dx) >= absf(dy):
		return 1 if dx > 0.0 else 3
	return 2 if dy > 0.0 else 0


func _update_vision_and_search() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		var enemy: Dictionary = actors[1 - i]
		var was_visible := bool(a["enemy_visible"])
		var visible := false
		if bool(enemy["alive"]) and bool(a["alive"]):
			var d := sqrt(pow(float(enemy["x"]) - float(a["x"]), 2.0) + pow(float(enemy["y"]) - float(a["y"]), 2.0))
			if d <= arena.vision and arena.line_of_effect(float(a["x"]), float(a["y"]), float(enemy["x"]), float(enemy["y"])):
				visible = true
		a["enemy_visible"] = visible
		if visible:
			if not was_visible:
				a["memory_token"] = int(a["memory_token"]) + 1
				telemetry.emit(tick, 16, [i, 1 - i, 2, tick, [float(enemy["x"]), float(enemy["y"])]])
				a["search_active"] = false
				# A new observation restarts the search token and the public patrol route.
				a["search_visited"] = []
				a["patrol_visited"] = []
			a["memory_valid"] = true
			a["memory_x"] = float(enemy["x"])
			a["memory_y"] = float(enemy["y"])
			a["memory_last_seen_tick"] = tick
			a["memory_expiry"] = tick + int(content.tuning["vision"]["memory_ticks"])
			a["memory_hp_band"] = M01Observations.hp_band(int(enemy["hp"]), int(enemy["hp_max"]))
			a["memory_form"] = str(enemy["presentation_id"])
		elif was_visible:
			telemetry.emit(tick, 16, [i, 1 - i, 1, tick, [float(enemy["x"]), float(enemy["y"])]])
		if not visible and bool(a["memory_valid"]) and not bool(a["search_active"]) \
				and not bool(a["search_token_exhausted"].get(str(a["memory_token"]), false)):
			a["search_active"] = true
			a["search_start"] = tick
			a["search_deadline"] = tick + int(content.tuning["vision"]["search_ticks"])
			telemetry.emit(tick, 17, [i, 0, int(a["memory_token"]), "start", int(a["search_deadline"]), "vision_loss"])


## ARCH amendment (NPC ingress): a decision produced in cut6 survives _tick_start in the
## simulation-owned NPCPrivateState queue and is admitted in the boundary where it matures —
## after phase/control cleanup in cut1, before cut2's response work. The boundary scratch
## accepted_requests then delivers it to _process_requests exactly once on this same boundary,
## so REQUEST/RESPONSE share the matured tick instead of dying with the previous scratch array.
func _drain_npc_submissions() -> void:
	if mode == "recorded_requests":
		return
	for i in 2:
		if i == 0:
			continue
		var a: Dictionary = actors[i]
		var npc: Dictionary = a["npc"]
		var queued: Variant = npc["queued"]
		if queued == null or tick < int((queued as Dictionary)["submission_due_tick"]):
			continue
		var q := queued as Dictionary
		# Consume exactly once even when admission is about to fail: the gateway applies the
		# current control/life/hint guards and returns the actual rejection outcome.
		npc["queued"] = null
		var raw := {
			"schema": "m01.1", "trainer": 1, "actor": i,
			"sequence": int(q["sequence"]), "slot": int(q["slot"]) - 1,
			"family": int(q["family"]), "target_kind": int(q["target_kind"]),
			"target_or_area": q["target_or_area"], "observed_tick": int(q["observation_tick"]),
		}
		# G3 §8: revalidate against the last completed permitted boundary (tick - 1) and
		# discard an obsolete hint rather than refreshing it from hidden coordinates.
		var hk := int(q["target_kind"])
		if hk == 2 and not bool(a["enemy_visible"]):
			hk = 0
		elif hk == 3 and (not bool(a["memory_valid"]) or bool(a["enemy_visible"]) \
				or bool(a["search_token_exhausted"].get(str(a["memory_token"]), false))):
			hk = 0
		raw["target_kind"] = hk
		if hk == 0:
			raw["target_or_area"] = null
		q["revalidated_observation_tick"] = tick - 1
		var res := gateway.validate(raw, tick, actors, trainer_owner)
		# Genuine gateway request ID on admission; a rejection carries a null request and
		# never reaches _issue_episode, so it schedules no response draw.
		var request_id: Variant = int(res["request"]) if bool(res["ok"]) else null
		telemetry.emit(tick, 24, [int(q["decision"]), request_id,
			int(q["revalidated_observation_tick"]),
			"submitted" if bool(res["ok"]) else str(res["reason"])])
		if bool(res["ok"]):
			res["observation_category"] = str(q.get("observation_category", ""))
			accepted_requests.append(res)


func _npc_tick() -> void:
	if mode == "recorded_requests":
		return
	for i in 2:
		if i == 0:
			continue
		var a: Dictionary = actors[i]
		if not bool(a["alive"]) or int(a["control_mode"]) != 0:
			continue
		var npc: Dictionary = a["npc"]
		if trainer_ai.should_decide(tick, npc):
			var enemy: Dictionary = actors[0]
			var decision := trainer_ai.decide(tick, npc, a, enemy, arena)
			trainer_ai.apply_decision(decision, npc)
			var fam := int(decision["proposed_slot"])
			var hint: Array = decision["lawful_hint"]
			telemetry.emit(tick, 23, [int(decision["decision"]), int(decision["observation_tick"]),
				str(decision["safety_category"]), fam, hint[1],
				int(decision["submission_due_tick"])])
			# G3 §8: an active pending response or accepted intent is not replaced by spam
			# unless the current permitted OBSERVATION changes its safety category.
			# GP-F01: compare the recorded observational category, never the interpreted
			# family — an Attack misinterpreted as Run stays category "attack".
			var active_family := -1
			var active_category := ""
			var pending_hesitant := false
			var pending_key := ""
			var ep: Variant = a["response_episode"]
			if ep != null and ep is Dictionary and not bool((ep as Dictionary).get("draw_resolved", true)):
				active_family = int((ep as Dictionary).get("original_family", 0))
				active_category = str((ep as Dictionary).get("observation_category", ""))
				pending_hesitant = int((ep as Dictionary).get("class", 0)) == 4
				pending_key = str((ep as Dictionary).get("key", ""))
			elif a["accepted_intent"] != null:
				var held := a["accepted_intent"] as Dictionary
				active_family = int(held["family"])
				active_category = str(held.get("observation_category", ""))
			var observed_category := str(decision["safety_category"])
			var category_changed: bool
			if active_category != "":
				category_changed = active_category != observed_category
			else:
				category_changed = active_family >= 0 and active_family != fam
			# G3 §8: the one-credit hesitant repeat only lives while the pending episode is
			# still an unresolved class 4; any other episode state clears it.
			if not pending_hesitant:
				npc["repeated_episode"] = false
			var repeat_ok := pending_hesitant and not bool(npc["repeated_episode"]) \
					and active_family == fam and pending_key == _semantic_key(fam, hint[1])
			if npc["queued"] != null:
				continue
			if active_family >= 0 and not category_changed and not repeat_ok:
				continue
			if repeat_ok:
				npc["repeated_episode"] = true
			var seq := int(gateway.last_accepted_sequence.get(1, 0)) + 1
			npc["queued"] = {
				"decision": int(decision["decision"]),
				"observation_tick": int(decision["observation_tick"]),
				"submission_due_tick": int(decision["submission_due_tick"]),
				"sequence": seq,
				"slot": fam,
				"family": fam,
				"target_kind": int(hint[0]),
				"target_or_area": hint[1],
				"revalidated_observation_tick": int(decision["observation_tick"]),
				"observation_category": observed_category,
			}


func _publish_public_actions() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		var public := ""
		if not bool(a["alive"]):
			public = "ko"
		elif int(a["lock_end"]) > tick:
			public = "exhausted"
		elif _in_lock(a):
			public = "acting_alone"
		elif int(a["brace_end"]) > tick and int(a["brace_start"]) >= 0 and tick > int(a["brace_start"]):
			public = "bracing"
		elif bool(a["bound_active"]):
			public = "bound"
		elif a["action"] != null and str((a["action"] as Dictionary).get("state", "")) == "preparing":
			var sid := str((a["action"] as Dictionary).get("skill", ""))
			if sid == "brace":
				public = "preparing_brace"
			elif sid == "short_bound":
				public = "preparing_bound"
			else:
				public = "preparing"
		elif a["action"] != null and str((a["action"] as Dictionary).get("state", "")) in ["due", "committed"]:
			public = "claw"
		elif bool(a["search_active"]):
			public = "searching"
		a["public_action"] = public


func _emit_checkpoint() -> void:
	var cid := int(id_counter["checkpoint"])
	id_counter["checkpoint"] = cid + 1
	var state := canonical_state()
	var sha := M01Telemetry.canonical_state_sha256(state)
	telemetry.emit(tick, 21, [cid, sha, stream_draws.duplicate(true)])


func canonical_state() -> Dictionary:
	var acts := []
	for a in actors:
		acts.append({
			"id": int(a["actor_id"]),
			"hp": int(a["hp"]),
			"stam": int(a["stam"]),
			"fatigue": int(a["fatigue_centi"]),
			"pressure": int(a["pressure"]),
			"lock_end": int(a["lock_end"]),
			"latched": bool(a["lock_latched"]),
			"recovery_end": int(a["recovery_end"]),
			"x": snappedf(float(a["x"]), 0.000001),
			"y": snappedf(float(a["y"]), 0.000001),
			"facing": int(a["facing"]),
			"alive": bool(a["alive"]),
			"cooldown_end": a["cooldown_end"].duplicate(true),
			"brace_start": int(a["brace_start"]),
			"brace_end": int(a["brace_end"]),
			"bound_active": bool(a["bound_active"]),
			"bound_progress": snappedf(float(a["bound_progress"]), 0.000001),
			"memory_valid": bool(a["memory_valid"]),
			"memory_expiry": int(a["memory_expiry"]),
			"search_active": bool(a["search_active"]),
			"search_deadline": int(a["search_deadline"]),
			"episode": a["response_episode"].duplicate(true) if a["response_episode"] != null else null,
			"intent": a["accepted_intent"].duplicate(true) if a["accepted_intent"] != null else null,
			# ARCH-PLAY01-R02-F03: the captured owner and rest progress must be part of the
			# checkpoint, otherwise equal C70 hashes cannot establish ownership closure.
			"cycle_intent": int(a["cycle_intent"]),
			"cycle_request": int(a["cycle_request"]),
			"cycle_episode": int(a["cycle_episode"]),
			"recovery_owner": int(a["recovery_owner"]),
			"rest_idle_ticks": int(a["rest_idle_ticks"]),
			"control_mode": int(a["control_mode"]),
			"emotion": str(a["emotion"]),
			"npc": {"queued": a["npc"]["queued"].duplicate(true) if a["npc"]["queued"] != null else null,
				"next": int(a["npc"]["next_decision_tick"])},
		})
	return {"tick": tick, "actors": acts, "streams": stream_draws.duplicate(true),
		"seed": str(root_seed), "mode": mode}


func _end_encounter(reason: int, batch: int) -> void:
	if ended:
		return
	ended = true
	end_reason = reason
	end_batch = batch
	telemetry.emit(tick, 20, [batch, reason, ko_actors.duplicate(), true])
	if reason == 2:
		_record("Sparring ended: diagnostic KO", "mutual KO", 0, "end")
	else:
		_record("Sparring ended: diagnostic KO", "", 0, "end")


func summary() -> Dictionary:
	var requests := int(telemetry.type_counts.get(1, 0))
	var responses := int(telemetry.type_counts.get(3, 0))
	var rejects := int(telemetry.type_counts.get(2, 0))
	var starts := int(telemetry.type_counts.get(6, 0))
	var commits := int(telemetry.type_counts.get(9, 0))
	var cancels := int(telemetry.type_counts.get(10, 0))
	var hits := int(telemetry.type_counts.get(11, 0))
	var kos := int(telemetry.type_counts.get(19, 0))
	var reason_name := {1: "single_ko", 2: "mutual_ko", 3: "diagnostic_timeout", 4: "aborted"}
	return {
		"schema": SCHEMA,
		"mode": mode,
		"fixture_id": fixture_id,
		"root_seed": str(root_seed),
		"active_ticks": active_ticks,
		"active_seconds": snappedf(active_ticks / 60.0, 0.001),
		"end_reason": reason_name.get(end_reason, "in_progress"),
		"end_reason_id": end_reason,
		"ko_actors": ko_actors.duplicate(),
		"requests": requests,
		"responses": responses,
		"rejections": rejects,
		"action_starts": starts,
		"commits": commits,
		"cancellations": cancels,
		"impact_records": hits,
		"ko_events": kos,
		"search_totals": int(telemetry.type_counts.get(17, 0)),
		"vision_totals": int(telemetry.type_counts.get(16, 0)),
		"stream_draw_counts": stream_draws.duplicate(true),
		"final": [
			{"actor": 0, "hp": int(actors[0]["hp"]), "stam": int(actors[0]["stam"]),
				"hp_band": M01Observations.hp_band(int(actors[0]["hp"]), int(actors[0]["hp_max"])),
				"stam_band": M01Observations.stam_band(int(actors[0]["stam"]), int(actors[0]["stam_max"])),
				"alive": bool(actors[0]["alive"])},
			{"actor": 1, "hp": int(actors[1]["hp"]), "stam": int(actors[1]["stam"]),
				"hp_band": M01Observations.hp_band(int(actors[1]["hp"]), int(actors[1]["hp_max"])),
				"stam_band": M01Observations.stam_band(int(actors[1]["stam"]), int(actors[1]["stam_max"])),
				"alive": bool(actors[1]["alive"])},
		],
		"queue_peak": telemetry.queue_peak,
		"event_bytes": telemetry.event_bytes_total,
	}


func observe_for(observer: int) -> Dictionary:
	var enemy := 1 - observer
	var mem := {}
	if bool(actors[observer]["memory_valid"]):
		mem = {"x": float(actors[observer]["memory_x"]), "y": float(actors[observer]["memory_y"]),
			"tick": int(actors[observer]["memory_last_seen_tick"]),
			"hp_band": int(actors[observer]["memory_hp_band"]),
			"form": str(actors[observer]["memory_form"])}
	return M01Observations.build_trainer_observation(observer, tick,
		[actors[observer], actors[enemy]], enemy, _map_copy(), mem)


func _map_copy() -> Dictionary:
	return {
		"width": int(arena.width), "height": int(arena.height),
		"blocker": [int(arena.original_blocker()[0]), int(arena.original_blocker()[1]),
			int(arena.original_blocker()[2]), int(arena.original_blocker()[3])],
		"spawn": arena.spawn.duplicate(true),
		"patrol": arena.patrol.duplicate(true),
	}
