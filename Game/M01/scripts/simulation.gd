class_name M01Simulation
extends RefCounted

## Presentation-only synchronous Quick release occurrence. Carries copied side + source life only.
signal public_quick_release(side: int, life_id: int, tick: int, x: float, y: float, facing: int)

const SCHEMA := "m01.1"
const SCHEMA_EXPANDED := "m01.2"
const MODE_BABY := "baby_growth_revival"
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
## Expanded Baby lifecycle bounds (Architect §4/§5). These are work ceilings, not measurements.
const BABY_MAX_BODIES := 4
const BABY_MAX_PAIRS := 6
const BABY_MAX_PASSES := 4
const BABY_MAX_PAIR_TESTS := 24
const BABY_PLACEMENT_CANDIDATES := 17

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
## Expanded Baby: fixed two-slot prey pool, per-side progression ledger, bounded private
## presentation scratch. All empty in legacy modes.
var prey_slots: Array = []
var progression := {}
var quick_releases: Array = []
var onset_slots := {}
var lifecycle_notices: Array = []
var lifecycle_announced := {}
var pair_test_total := 0
var placement_test_total := 0
var prey_expansion_total := 0
var prey_search_total := 0
var prey_violation_total := 0
var movement_contract_failures := 0
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
	if p_mode == MODE_BABY and content.baby_section().is_empty():
		push_error("M01 expanded mode requires the baby_growth_revival content section")
		return false
	_init_streams()
	_init_actors()
	if mode == MODE_BABY:
		_init_baby_state()
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
	var spawn: Array = _spawn_for(idx)
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
		"lifecycle": "alive",
		"return_due": -1,
		"return_wait_announced": false,
		"returned_this_boundary": false,
		"selected_target": {},
		# Bounded observer knowledge: competitor compatibility view above plus two prey entries.
		"prey_knowledge": [],
		# Private presentation scratch (never serialized in canonical_state).
		"bound_purpose": -1,
		"onset_bound_action": -1,
		"onset_prior_moving": false,
		"onset_prior_category": "",
		"onset_prior_brace": false,
		"return_notice_tick": -1,
		"growth_notice_tick": -1,
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


func _spawn_for(idx: int) -> Array:
	if mode == MODE_BABY:
		# No silent legacy-spawn fallback in expanded mode: the section is required content.
		var sec := content.baby_section()
		return (sec["nests"]["centers"] as Array)[idx]
	return arena.spawn[idx]


func _init_baby_state() -> void:
	var sec := content.baby_section()
	var p: Dictionary = sec["prey"]
	var hp := int(p["hp_max_cp"])
	prey_slots = []
	for s in 2:
		var c: Array = (p["centers"] as Array)[s]
		prey_slots.append({
			"slot": s, "life_id": 1, "live": true, "hp": hp, "hp_max": hp,
			"x": float(c[0]), "y": float(c[1]), "facing": 0,
			"radius": float(p["radius_mwu"]),
			"route": [], "route_i": 0, "next_plan_tick": 0,
			"respawn_due": -1, "spawn_wait_announced": false,
			"credited": [0, 0], "first_credit": [-1, -1],
			"moved_this_boundary": false, "threat": -1,
			"threat_x": 0.0, "threat_y": 0.0,
		})
	progression = {}
	for i in 2:
		progression[i] = {"pending_atk": 0, "evolution_exp": 0, "credited_defeats": 0}
		actors[i]["prey_knowledge"] = [_new_knowledge(0), _new_knowledge(1)]
	onset_slots = {0: "", 1: ""}
	lifecycle_notices = []
	lifecycle_announced = {}
	quick_releases = []
	pair_test_total = 0
	placement_test_total = 0
	prey_expansion_total = 0
	movement_contract_failures = 0


func _new_knowledge(slot: int) -> Dictionary:
	return {"kind": "prey", "id": slot, "life_id": -1, "visible": false,
		"x": 0.0, "y": 0.0, "last_seen_tick": -1, "expiry": 0,
		"memory_valid": false, "token": 0, "visited": []}


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
	if f.has("prey_state"):
		var ps: Dictionary = f["prey_state"]
		for slot_str in ps:
			var slot := int(slot_str)
			if slot < 0 or slot >= prey_slots.size():
				continue
			for k in (ps[slot_str] as Dictionary):
				prey_slots[slot][k] = (ps[slot_str] as Dictionary)[k]
	if f.has("progression"):
		var pr: Dictionary = f["progression"]
		for side_str in pr:
			var side := int(side_str)
			if side < 0 or side > 1:
				continue
			for k in (pr[side_str] as Dictionary):
				progression[side][k] = (pr[side_str] as Dictionary)[k]
	var locks: Array = f.get("control_locks", [])
	for l in locks:
		fixture["lock_schedule"] = locks
	if f.has("arriving_effects"):
		for e in f["arriving_effects"]:
			pending_effects.append(e.duplicate(true))
	_refresh_gates(actors[0])
	_refresh_gates(actors[1])


func _is_baby() -> bool:
	return mode == MODE_BABY and not content.baby_section().is_empty()


func is_expanded() -> bool:
	return _is_baby()


func _baby() -> Dictionary:
	return content.baby_section()


func _baby_ticks(key: String) -> int:
	return int(content.compiled.get(key, 0))


func _entity_life(kind: String, id: int) -> int:
	if kind == "prey":
		if id < 0 or id >= prey_slots.size():
			return -1
		return int(prey_slots[id]["life_id"])
	if id < 0 or id > 1:
		return -1
	return int(actors[id]["life_id"])


func _entity_live(kind: String, id: int) -> bool:
	if kind == "prey":
		if id < 0 or id >= prey_slots.size():
			return false
		return bool(prey_slots[id]["live"])
	if id < 0 or id > 1:
		return false
	return bool(actors[id]["alive"])


func _entity_pos(kind: String, id: int) -> Array:
	if kind == "prey":
		return [float(prey_slots[id]["x"]), float(prey_slots[id]["y"])]
	return [float(actors[id]["x"]), float(actors[id]["y"])]


func _entity_radius(kind: String, id: int) -> float:
	if kind == "prey":
		return float(prey_slots[id]["radius"])
	return float(actors[id]["radius"])


func _make_ref(kind: String, id: int, life_id: int) -> Dictionary:
	return {"kind": kind, "id": id, "life_id": life_id}


## Validates kind/id/generation/live state. An old reference never reads a replacement life.
func _resolve_ref(ref: Variant) -> Dictionary:
	if not (ref is Dictionary):
		return {}
	var r := ref as Dictionary
	var kind := str(r.get("kind", ""))
	var id := int(r.get("id", -1))
	var life_id := int(r.get("life_id", -1))
	if kind != "monster" and kind != "prey":
		return {}
	if not _entity_live(kind, id):
		return {}
	if _entity_life(kind, id) != life_id:
		return {}
	return {"kind": kind, "id": id, "life_id": life_id}


func _entity_id_encoded(kind: String, id: int) -> int:
	return id if kind == "monster" else 2 + id


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
	onset_slots = {0: "", 1: ""}
	quick_releases = []
	last_step_ms = 0.0
	elapsed_usec = t0


func step() -> void:
	if ended:
		return
	_tick_start()
	tick += 1
	if _is_baby() and aborted:
		# Already-requested abort ends before new combat/returns (Architect §5.1).
		_end_encounter_baby(4, -1)
		active_ticks += 1
		telemetry.mark_activity(active_ticks)
		last_step_ms = float(Time.get_ticks_usec() - elapsed_usec) / 1000.0
		sim_time_ms_samples.append(last_step_ms)
		return
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
	if not _is_baby() and active_ticks >= int(content.tuning["timeout_active_ticks"]) and not ended:
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
	if _is_baby():
		_prey_plan_cut()
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
		# QA F02: only THIS episode's actual successful finalization emits Understood; the initial
		# 12-tick wait keeps class4/telemetry and still reads as Hesitating.
		if cls == 4 and bool(e.get("draw_resolved", false)):
			cue = {"cue": "Understood: %s" % FAMILY_LABEL[original], "detail": ""}
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
	var attack_view := {}
	if _is_baby():
		var ref := _select_attack_target(a)
		attack_view = _attack_view_for(a, ref)
	_execute_plan(a, enemy, attack_view)
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


func _sq_dist(p: Array, a: Dictionary) -> float:
	var dx := float(p[0]) - float(a["x"])
	var dy := float(p[1]) - float(a["y"])
	return dx * dx + dy * dy


func _los_vision(a: Dictionary, p: Array) -> bool:
	var dx := float(p[0]) - float(a["x"])
	var dy := float(p[1]) - float(a["y"])
	if dx * dx + dy * dy > arena.vision * arena.vision:
		return false
	return arena.line_of_effect(float(a["x"]), float(a["y"]), float(p[0]), float(p[1]))


func _prey_visible_to(a: Dictionary, slot: int) -> bool:
	if not _is_baby() or slot < 0 or slot >= prey_slots.size():
		return false
	var p: Dictionary = prey_slots[slot]
	if not bool(p["live"]):
		return false
	return _los_vision(a, [float(p["x"]), float(p["y"])])


func _attack_legal(a: Dictionary, ref: Variant) -> bool:
	var r := _resolve_ref(ref)
	if r.is_empty():
		return false
	if int(r["id"]) == int(a["actor_id"]) and str(r["kind"]) == "monster":
		return false
	if str(r["kind"]) == "monster":
		if not bool(a["enemy_visible"]):
			return false
		return _los_vision(a, _entity_pos("monster", int(r["id"])))
	return _prey_visible_to(a, int(r["id"]))


## Normal target-selection boundary: retain a live, lawfully visible, eligible target;
## otherwise choose the nearest visible live opponent/prey (tie opponent, then lower slot).
## With none visible, a live previous target with lawful frozen memory is retained for SEARCH
## only; attack still requires current visibility.
func _select_attack_target(a: Dictionary) -> Dictionary:
	var cur: Variant = a.get("selected_target", {})
	var cur_ref: Dictionary = cur as Dictionary if cur is Dictionary else {}
	if not cur_ref.is_empty() and _attack_legal(a, cur_ref):
		return cur_ref
	var best := {}
	var best_d := INF
	var opp := 1 - int(a["actor_id"])
	var opp_ref := _make_ref("monster", opp, int(actors[opp]["life_id"]))
	if _attack_legal(a, opp_ref):
		best = opp_ref
		best_d = _sq_dist(_entity_pos("monster", opp), a)
	for s in 2:
		if not _is_baby():
			break
		var pref := _make_ref("prey", s, int(prey_slots[s]["life_id"]))
		if not _attack_legal(a, pref):
			continue
		var d2 := _sq_dist(_entity_pos("prey", s), a)
		if d2 < best_d - 1e-9:
			best_d = d2
			best = pref
	if not best.is_empty():
		a["selected_target"] = best
		return best
	# C06: no visible target. Retain a prey target for lawful frozen last-seen SEARCH based only
	# on permitted observer knowledge/expiry — never on authoritative hidden live state, so an
	# unseen depletion/respawn cannot cancel search. Attack eligibility stays visibility-gated.
	if not cur_ref.is_empty() and str(cur_ref.get("kind", "")) == "prey" \
			and int(cur_ref.get("id", -1)) >= 0 \
			and int(cur_ref["id"]) < (a["prey_knowledge"] as Array).size():
		var k: Dictionary = (a["prey_knowledge"] as Array)[int(cur_ref["id"])]
		if int(k["life_id"]) == int(cur_ref["life_id"]) and bool(k["memory_valid"]):
			return cur_ref
	a["selected_target"] = {}
	return {}


func _attack_view_for(a: Dictionary, ref: Dictionary) -> Dictionary:
	if ref.is_empty():
		return {}
	var visible := _attack_legal(a, ref)
	var view := {"ref": ref.duplicate(true), "visible": visible}
	if visible:
		var pos := _entity_pos(str(ref["kind"]), int(ref["id"]))
		view["x"] = float(pos[0])
		view["y"] = float(pos[1])
	elif str(ref["kind"]) == "prey":
		# Frozen last-seen point only; hidden live coordinates never enter the view.
		var k: Dictionary = (a["prey_knowledge"] as Array)[int(ref["id"])]
		if int(k["life_id"]) == int(ref["life_id"]) and bool(k["memory_valid"]):
			view["x"] = float(k["x"])
			view["y"] = float(k["y"])
			view["memory"] = {"valid": true, "x": float(k["x"]), "y": float(k["y"]),
				"token": int(k["token"])}
		else:
			view["x"] = 0.0
			view["y"] = 0.0
	else:
		view["x"] = 0.0
		view["y"] = 0.0
	return view


func _execute_plan(a: Dictionary, enemy: Dictionary, attack_view: Dictionary = {}) -> void:
	var knowledge := "unknown"
	if bool(a["enemy_visible"]):
		knowledge = "visible"
	elif bool(a["memory_valid"]):
		knowledge = "last_known"
	var plan := behavior.plan(a, enemy, tick, knowledge, attack_view)
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
	var attack_ref := {}
	if sid == "quick_claw":
		if _is_baby():
			attack_ref = _resolve_ref(plan.get("attack_ref", {}))
			if attack_ref.is_empty():
				return
			var tp := _entity_pos(str(attack_ref["kind"]), int(attack_ref["id"]))
			var d := sqrt(pow(float(tp[0]) - float(a["x"]), 2.0)
				+ pow(float(tp[1]) - float(a["y"]), 2.0))
			if d > float(def["range_mwu"]):
				return
			if not _attack_legal(a, attack_ref):
				return
			if not arena.line_of_effect(float(a["x"]), float(a["y"]),
					float(tp[0]), float(tp[1])):
				return
		else:
			if not bool(enemy["alive"]) or not bool(a["enemy_visible"]):
				return
			var d := sqrt(pow(float(enemy["x"]) - float(a["x"]), 2.0)
				+ pow(float(enemy["y"]) - float(a["y"]), 2.0))
			if d > float(def["range_mwu"]):
				return
			if not arena.line_of_effect(float(a["x"]), float(a["y"]),
					float(enemy["x"]), float(enemy["y"])):
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
		if _is_baby() and not attack_ref.is_empty():
			target = _entity_id_encoded(str(attack_ref["kind"]), int(attack_ref["id"]))
		else:
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
		"life_id": int(a["life_id"]),
		"target_ref": attack_ref.duplicate(true),
		"target_life_id": int(attack_ref.get("life_id", -1)) if not attack_ref.is_empty() else null,
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
	var ev6 := [aid, int(a["actor_id"]), int(a["life_id"]) if _is_baby() else 1,
		int(action["request"]), sid, target, due, due + content.recovery_ticks(sid)]
	if _is_baby():
		ev6.append(int(attack_ref.get("life_id", -1)) if not attack_ref.is_empty() else null)
	telemetry.emit(tick, 6, ev6)
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


## R2: normalizes a captured EntityRef. Only a complete, in-range kind/id/life is accepted;
## incomplete nonempty dictionaries fail safely and never bind the current life.
func _normalize_ref(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var r := raw as Dictionary
	var kind := str(r.get("kind", ""))
	if kind != "monster" and kind != "prey":
		return {}
	if not r.has("id") or not r.has("life_id"):
		return {}
	var id_raw: Variant = r["id"]
	var life_raw: Variant = r["life_id"]
	if not (id_raw is int) or not (life_raw is int):
		return {}
	var id := int(id_raw)
	var life := int(life_raw)
	if life <= 0:
		return {}
	if kind == "monster":
		if id < 0 or id > 1:
			return {}
	else:
		if id < 0 or id >= prey_slots.size():
			return {}
	return _make_ref(kind, id, life)


func _effect_target_ref(e: Dictionary) -> Dictionary:
	var tr: Variant = e.get("target_ref", {})
	if tr is Dictionary and not (tr as Dictionary).is_empty():
		return _normalize_ref(tr)
	if _is_baby():
		# Expanded effects must carry a captured identity; never bind the CURRENT life.
		return {}
	var idx := int(e.get("target", -1))
	if idx >= 0 and idx <= 1:
		return _make_ref("monster", idx, int(actors[idx]["life_id"]))
	return {}


## Emits the invalid-life IMPACT row for an effect whose captured kind/id/life is not a live,
## matching entity. Never binds a replacement life and never indexes an incomplete ref.
func _emit_invalid_effect(e: Dictionary, ref: Dictionary) -> void:
	var norm := _normalize_ref(ref)
	var enc: Variant = int(e.get("target", -1))
	var life: Variant = null
	if not norm.is_empty():
		enc = _entity_id_encoded(str(norm["kind"]), int(norm["id"]))
		life = int(norm["life_id"])
	elif ref is Dictionary and not ref.is_empty():
		# Preserve the encoded target when known, but never require absent keys.
		var raw_id: Variant = (ref as Dictionary).get("id", null)
		if raw_id is int and int(raw_id) >= 0 and int(raw_id) <= 3:
			enc = int(raw_id)
	telemetry.emit(tick, 11, [int(e["effect"]), int(e.get("action", 0)),
		int(e.get("source", 0)), enc, life, "invalid_life", int(e.get("batch", 0)),
		"%d:%s:%s" % [int(e.get("batch", 0)), str(enc), str(life)]])
	if int(e.get("source", 0)) == 0:
		_record("Miss", "", 1, "action")


## C01: validates captured kind/id/life/live BEFORE impact/interruption, then carries valid
## qualified arrivals forward so the later settlement applies them exactly once. Source KO never
## retracts already-committed work.
func _cut3() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		a["def_frozen"] = int(a["def"])
		a["brace_frozen"] = int(a["brace_end"]) > tick and int(a["brace_start"]) >= 0 and tick > int(a["brace_start"])
	var keep: Array = []
	for e in pending_effects:
		if int(e.get("impact_tick", -1)) != tick:
			keep.append(e)
			continue
		if str(e.get("qualification", "qualified")) != "qualified":
			var bref := _effect_target_ref(e)
			var b_life := int(bref.get("life_id", -1)) if not bref.is_empty() else int(e.get("target", -1))
			var b_tgt: Variant = _entity_id_encoded(str(bref["kind"]), int(bref["id"])) if not bref.is_empty() else int(e.get("target", -1))
			telemetry.emit(tick, 11, [int(e["effect"]), int(e.get("action", 0)), int(e.get("source", 0)),
				b_tgt, b_life, "blocked", int(e.get("batch", 0)), ""])
			continue
		var ref := _effect_target_ref(e)
		var valid := false
		if _is_baby():
			valid = not ref.is_empty() and not _resolve_ref(ref).is_empty()
		else:
			var lidx := int(ref.get("id", int(e.get("target", -1))))
			valid = lidx >= 0 and lidx <= 1 and bool(actors[lidx]["alive"])
		if not valid:
			_emit_invalid_effect(e, ref)
			continue
		var tgt_idx := int(ref["id"])
		var tgt_life := int(ref.get("life_id", -1))
		if str(ref["kind"]) == "monster":
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
							_record("Interrupted", "", 0, "action")
						tgt["action"] = null
			var hit_life: Variant = tgt_life if _is_baby() else int(tgt["life"])
			telemetry.emit(tick, 11, [int(e["effect"]), int(e.get("action", 0)), int(e.get("source", 0)),
				tgt_idx, hit_life, "hit", int(e.get("batch", 0)),
				"%d:%d:%d" % [int(e.get("batch", 0)), tgt_idx, int(tgt["life"])]])
		else:
			var enc := _entity_id_encoded("prey", tgt_idx)
			var hit_life2: Variant = tgt_life if _is_baby() else -1
			telemetry.emit(tick, 11, [int(e["effect"]), int(e.get("action", 0)), int(e.get("source", 0)),
				enc, hit_life2, "hit", int(e.get("batch", 0)),
				"%d:%d:%d" % [int(e.get("batch", 0)), enc, tgt_life]])
		# Carry the validated arrival forward: _cut5(_baby) settles it exactly once this tick.
		keep.append(e)
	pending_effects = keep
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
			var tref: Dictionary = {}
			var trv: Variant = d.get("target_ref", {})
			if trv is Dictionary:
				tref = trv as Dictionary
			var tgt_idx := int(tref.get("id", int(d["target"]))) if not tref.is_empty() else int(d["target"])
			var tgt_life := int(tref.get("life_id", int(actors[tgt_idx]["life_id"]))) if not tref.is_empty() else int(actors[tgt_idx]["life_id"])
			var tgt_enc: Variant = _entity_id_encoded(str(tref.get("kind", "monster")), tgt_idx) if not tref.is_empty() else tgt_idx
			var tgt_def := int(actors[tgt_idx]["def"])
			var tgt_k := int(actors[tgt_idx]["k_defense"])
			if not tref.is_empty() and str(tref.get("kind", "monster")) == "prey":
				tgt_def = int(_baby()["prey"]["def"])
				tgt_k = int(content.species["k_defense"])
			effects.append({
				"effect": eid, "action": int(d["action"]), "source": i,
				"target": tgt_enc, "target_ref": tref.duplicate(true),
				"target_life_id": tgt_life if not tref.is_empty() else int(actors[tgt_idx]["life_id"]),
				"source_life_id": int(a["life_id"]),
				"kind": "damage",
				"impact_tick": tick, "interrupt_power": int(def["interrupt_power"]),
				"qualification": "qualified", "batch": batch,
				"base_power_cp": int(def["base_power_cp"]),
				"source_atk": int(a["atk"]),
				"target_def": tgt_def,
				"target_k_defense": tgt_k,
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
			# Architect §6: capture the selected plan's purpose BEFORE the action clear so the
			# bound onset can be classified truthfully later.
			var pv: Variant = d.get("plan", {})
			if pv is Dictionary:
				a["bound_purpose"] = int((pv as Dictionary).get("context_family", -1))
			a["onset_bound_action"] = -1
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
		# Presentation-only Quick release at the committed origin/facing, after event9 and own
		# release feedback. Own side always; enemy only when observer0 lawfully sees it.
		if sid == "quick_claw":
			if i == 0 or M01Observations.visibility_state(actors[0], tick) == 2:
				quick_releases.append({"side": i, "life_id": int(a["life_id"]), "tick": tick,
					"x": float(a["x"]), "y": float(a["y"]), "facing": int(a["facing"])})
				public_quick_release.emit(i, int(a["life_id"]), tick, float(a["x"]),
					float(a["y"]), int(a["facing"]))
	_refresh_gates(actors[0])
	_refresh_gates(actors[1])


func _release_legal(a: Dictionary, d: Dictionary) -> bool:
	var sid := str(d["skill"])
	if sid == "quick_claw":
		var ref: Variant = d.get("target_ref", {})
		if ref is Dictionary and not (ref as Dictionary).is_empty():
			var r := _resolve_ref(ref)
			if r.is_empty():
				return false
			var tp := _entity_pos(str(r["kind"]), int(r["id"]))
			var def := content.skill(sid)
			var dist := sqrt(pow(float(tp[0]) - float(a["x"]), 2.0)
				+ pow(float(tp[1]) - float(a["y"]), 2.0))
			if dist > float(def["range_mwu"]):
				return false
			if not arena.line_of_effect(float(a["x"]), float(a["y"]),
					float(tp[0]), float(tp[1])):
				return false
			return _attack_legal(a, r)
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
	if _is_baby():
		_cut5_baby()
		return
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


## Integer largest-remainder split of the credited HP loss across the two contributing sides.
func _allocate_credit(loss: int, d0: int, d1: int) -> Array:
	var total := d0 + d1
	if loss <= 0 or total <= 0:
		return [0, 0]
	var s0 := (loss * d0) / total
	var s1 := (loss * d1) / total
	var rem := loss - s0 - s1
	if rem > 0:
		var r0 := (loss * d0) % total
		var r1 := (loss * d1) % total
		if r1 > r0:
			s1 += 1
		else:
			s0 += 1
	return [s0, s1]


func _credit_winner(p: Dictionary) -> int:
	var c0 := int((p["credited"] as Array)[0])
	var c1 := int((p["credited"] as Array)[1])
	if c0 <= 0 and c1 <= 0:
		return -1
	if c0 > c1:
		return 0
	if c1 > c0:
		return 1
	var t0 := int((p["first_credit"] as Array)[0])
	var t1 := int((p["first_credit"] as Array)[1])
	if t0 >= 0 and t1 >= 0:
		if t0 < t1:
			return 0
		if t1 < t0:
			return 1
	elif t0 >= 0:
		return 0
	elif t1 >= 0:
		return 1
	return 0


func _lifecycle_entity(kind: String, id: int) -> int:
	return _entity_id_encoded(kind, id)


func _emit_lifecycle(transition: String, kind: String, id: int, old_life: int,
		new_life: int, due: Variant, pos: Variant, batch: Variant) -> void:
	telemetry.emit(tick, 27, [transition, _lifecycle_entity(kind, id), old_life, new_life,
		due, pos, batch])


## Expanded post-damage settlement. Order follows Architect §5: settle damage groups and credit,
## award newly depleted prey, then the true-end check, then due returns/spawns. Monster KO is
## nonterminal here.
func _cut5_baby() -> void:
	batch_counter += 1
	var batch := batch_counter
	var healing := {0: 0, 1: 0}
	var to_apply: Array = []
	for e in pending_effects:
		if int(e.get("impact_tick", -1)) != tick:
			continue
		if str(e.get("kind", "")) == "damage":
			to_apply.append(e)
		elif str(e.get("kind", "")) == "heal":
			var hidx := int(e.get("target", -1))
			if hidx >= 0 and hidx <= 1:
				healing[hidx] = int(healing[hidx]) + int(e.get("permit_cp", 0))
				telemetry.emit(tick, 13, [int(e["effect"]), hidx, batch,
					int(e.get("permit_cp", 0))])
	pending_effects = pending_effects.filter(func(e): return int(e.get("impact_tick", -1)) != tick)

	var mon_damage := {0: 0, 1: 0}
	var mon_contrib := {0: [], 1: []}
	var mon_hp_start := {0: int(actors[0]["hp"]), 1: int(actors[1]["hp"])}
	var prey_group := {}
	for s in prey_slots.size():
		prey_group[s] = {"d": [0, 0], "effects": [], "hp_start": int(prey_slots[s]["hp"])}
	var player_hit := false

	# Phase A: compute every effective hit. DAMAGE rows for monsters carry no prey credit.
	for e in to_apply:
		var ref := _effect_target_ref(e)
		if ref.is_empty():
			continue
		var kind := str(ref["kind"])
		var id := int(ref["id"])
		var eff_life := int(ref.get("life_id", -1))
		if kind == "monster":
			var tgt: Dictionary = actors[id]
			if not bool(tgt["alive"]) or int(tgt["life_id"]) != eff_life:
				telemetry.emit(tick, 11, [int(e["effect"]), int(e.get("action", 0)),
					int(e.get("source", 0)), id, eff_life, "invalid_life", batch,
					"%d:%d:%d" % [batch, id, eff_life]])
				if int(e.get("source", 0)) == 0:
					_record("Miss", "", 1, "action")
				continue
			var brace_bp := 10000
			if int(tgt["brace_end"]) > tick and int(tgt["brace_start"]) >= 0 \
					and tick > int(tgt["brace_start"]):
				brace_bp = int(content.skill("brace")["mitigation_bp"])
			var base_power := int(e["base_power_cp"])
			var src_atk := int(e["source_atk"])
			var tdef := int(tgt["def"])
			var k := int(tgt["k_defense"])
			var raw := float(base_power) * float(src_atk) / 100.0
			raw = raw * float(k) / float(k + maxf(0.0, float(tdef)))
			raw = raw * float(brace_bp) / 10000.0
			var effective := maxi(0, int(floor(raw + 0.5)))
			mon_damage[id] = int(mon_damage[id]) + effective
			mon_contrib[id].append(int(e["effect"]))
			if effective > 0 and (int(e.get("source", 0)) == 0 or id == 0):
				player_hit = true
			telemetry.emit(tick, 12, [int(e["effect"]), id, batch, base_power, src_atk,
				tdef, brace_bp, 10000, effective, eff_life, null])
		else:
			if id < 0 or id >= prey_slots.size():
				continue
			var p: Dictionary = prey_slots[id]
			if not bool(p["live"]) or int(p["life_id"]) != eff_life:
				telemetry.emit(tick, 11, [int(e["effect"]), int(e.get("action", 0)),
					int(e.get("source", 0)), _entity_id_encoded("prey", id), eff_life,
					"invalid_life", batch, "%d:%d:%d" % [batch, 2 + id, eff_life]])
				if int(e.get("source", 0)) == 0:
					_record("Miss", "", 1, "action")
				continue
			var pdef := int(_baby()["prey"]["def"])
			var pk := int(content.species["k_defense"])
			var pbase := int(e["base_power_cp"])
			var patk := int(e["source_atk"])
			var praw := float(pbase) * float(patk) / 100.0
			praw = praw * float(pk) / float(pk + maxf(0.0, float(pdef)))
			var peff := maxi(0, int(floor(praw + 0.5)))
			if peff > 0 and int(e.get("source", 0)) == 0:
				player_hit = true
			var grp: Dictionary = prey_group[id]
			var dside: Array = grp["d"]
			dside[int(e.get("source", 0))] = int(dside[int(e.get("source", 0))]) + peff
			grp["d"] = dside
			(grp["effects"] as Array).append([e, peff])

	# Phase B: prey credit is settled before that group's DAMAGE rows are emitted.
	for s in prey_slots.size():
		var grp2: Dictionary = prey_group[s]
		var p2: Dictionary = prey_slots[s]
		var dvals: Array = grp2["d"]
		if not bool(p2["live"]):
			continue
		var loss := mini(maxi(0, int(grp2["hp_start"])), int(dvals[0]) + int(dvals[1]))
		var share := _allocate_credit(loss, int(dvals[0]), int(dvals[1]))
		var credited: Array = p2["credited"]
		var first: Array = p2["first_credit"]
		for side in 2:
			if int(share[side]) > 0:
				credited[side] = int(credited[side]) + int(share[side])
				if int(first[side]) < 0:
					first[side] = tick
		p2["credited"] = credited
		p2["first_credit"] = first
		for pair in (grp2["effects"] as Array):
			var eff: Dictionary = pair[0]
			var peff2 := int(pair[1])
			telemetry.emit(tick, 12, [int(eff["effect"]), _entity_id_encoded("prey", s), batch,
				int(eff["base_power_cp"]), int(eff["source_atk"]),
				int(_baby()["prey"]["def"]), 10000, 10000, peff2,
				int(p2["life_id"]), [int(credited[0]), int(credited[1])]])

	if player_hit:
		_record("Hit", "", 1, "action")

	# Phase C: monster HP settlement and nonterminal down transition.
	for i in 2:
		var a: Dictionary = actors[i]
		if not bool(a["alive"]):
			continue
		var after := int(mon_hp_start[i]) + int(healing[i]) - int(mon_damage[i])
		after = clampi(after, 0, int(a["hp_max"]))
		a["hp"] = after
		if after <= 0:
			a["alive"] = false
			a["life"] = 1
			a["lifecycle"] = "down"
			a["return_due"] = tick + _baby_ticks("baby_return_ticks")
			a["return_wait_announced"] = false
			ko_this_boundary[i] = true
			telemetry.emit(tick, 19, [i, int(a["life_id"]), batch, mon_contrib[i]])
			_cancel_on_ko(a)
			gateway.purge_actor(i)
			_emit_lifecycle("monster_down", "monster", i, int(a["life_id"]),
				int(a["life_id"]), int(a["return_due"]),
				[float(a["x"]), float(a["y"])], batch)
			if i == 0:
				_record("Your monster is down — returning to your Nest", "", 0, "lifecycle")

	# Phase D: prey depletion, one award per prey life, slots ascending.
	for s in prey_slots.size():
		var p3: Dictionary = prey_slots[s]
		if not bool(p3["live"]):
			continue
		var g3: Dictionary = prey_group[s]
		var dv: Array = g3["d"]
		var applied := mini(maxi(0, int(g3["hp_start"])), int(dv[0]) + int(dv[1]))
		p3["hp"] = maxi(0, int(g3["hp_start"]) - applied)
		if int(p3["hp"]) > 0:
			continue
		p3["live"] = false
		p3["respawn_due"] = tick + _baby_ticks("baby_prey_respawn_ticks")
		p3["spawn_wait_announced"] = false
		p3["route"] = []
		p3["route_i"] = 0
		_emit_lifecycle("prey_depleted", "prey", s, int(p3["life_id"]),
			int(p3["life_id"]), int(p3["respawn_due"]),
			[float(p3["x"]), float(p3["y"])], batch)
		_award_prey(s, g3)

	# Phase E: true end precedes due placements; abort wins a same-boundary deadline.
	if aborted or tick >= _baby_ticks("baby_diagnostic_ticks"):
		_end_encounter_baby(4 if aborted else 3, batch)
		return
	_process_due_lifecycles(batch)


func _award_prey(slot: int, grp: Dictionary) -> void:
	var p: Dictionary = prey_slots[slot]
	var winner := _credit_winner(p)
	var ordinal: Variant = null
	var atk_delta := 0
	var exp_delta := 0
	var cum_atk: Variant = null
	var cum_exp: Variant = null
	if winner >= 0:
		var cd := int(progression[winner]["credited_defeats"])
		ordinal = 1 if cd == 0 else (2 if cd == 1 else 3)
		var rewards: Array = _baby()["rewards"]
		if int(ordinal) <= 2:
			var rec: Dictionary = rewards[int(ordinal) - 1]
			atk_delta = int(rec["pending_atk"])
			exp_delta = int(rec["evolution_exp"])
			progression[winner]["pending_atk"] = int(progression[winner]["pending_atk"]) + atk_delta
			progression[winner]["evolution_exp"] = int(progression[winner]["evolution_exp"]) + exp_delta
		progression[winner]["credited_defeats"] = mini(2, cd + 1)
		cum_atk = int(progression[winner]["pending_atk"])
		cum_exp = int(progression[winner]["evolution_exp"])
		if winner == 0 and (atk_delta > 0 or exp_delta > 0):
			actors[0]["growth_notice_tick"] = tick
			_record("Hunt growth gained", "", 0, "growth")
	var first: Array = p["first_credit"]
	var dvals: Array = grp["d"]
	var share := _allocate_credit(mini(maxi(0, int(grp["hp_start"])),
		int(dvals[0]) + int(dvals[1])), int(dvals[0]), int(dvals[1]))
	telemetry.emit(tick, 28, [slot, int(p["life_id"]), winner if winner >= 0 else null,
		(p["credited"] as Array).duplicate(),
		[int(first[0]) if int(first[0]) >= 0 else null,
			int(first[1]) if int(first[1]) >= 0 else null],
		[int(dvals[0]), int(dvals[1])], [int(share[0]), int(share[1])],
		ordinal, atk_delta, exp_delta, cum_atk, cum_exp])


## Due returns/spawns in stable order monster0, monster1, prey0, prey1. Blocked candidates keep
## their ORIGINAL due tick and announce the wait once.
func _process_due_lifecycles(batch: int) -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		if bool(a["alive"]) or int(a["return_due"]) < 0 or tick < int(a["return_due"]):
			continue
		if _try_place_monster(i):
			var old_life := int(a["life_id"])
			a["life_id"] = old_life + 1
			a["alive"] = true
			a["life"] = 0
			a["lifecycle"] = "alive"
			a["return_due"] = -1
			a["return_wait_announced"] = false
			a["returned_this_boundary"] = true
			_restore_returned(a)
			gateway.purge_actor(i)
			_emit_lifecycle("monster_return", "monster", i, old_life, int(a["life_id"]),
				null, [float(a["x"]), float(a["y"])], null)
			if i == 0:
				a["return_notice_tick"] = tick
				_record("Returned to Nest", "", 0, "lifecycle")
		elif not bool(a["return_wait_announced"]):
			a["return_wait_announced"] = true
			_emit_lifecycle("return_wait", "monster", i, int(a["life_id"]),
				int(a["life_id"]), int(a["return_due"]), null, null)
			if i == 0:
				_record("Waiting for a clear return point", "", 0, "lifecycle")
	for s in prey_slots.size():
		var p: Dictionary = prey_slots[s]
		if bool(p["live"]) or int(p["respawn_due"]) < 0 or tick < int(p["respawn_due"]):
			continue
		if _try_place_prey(s):
			var old_life := int(p["life_id"])
			p["life_id"] = old_life + 1
			p["live"] = true
			p["hp"] = int(p["hp_max"])
			p["credited"] = [0, 0]
			p["first_credit"] = [-1, -1]
			p["route"] = []
			p["route_i"] = 0
			p["next_plan_tick"] = 0
			p["respawn_due"] = -1
			p["spawn_wait_announced"] = false
			_emit_lifecycle("prey_spawn", "prey", s, old_life, int(p["life_id"]),
				null, [float(p["x"]), float(p["y"])], null)
		elif not bool(p["spawn_wait_announced"]):
			p["spawn_wait_announced"] = true
			_emit_lifecycle("spawn_wait", "prey", s, int(p["life_id"]),
				int(p["life_id"]), int(p["respawn_due"]), null, null)


func _placement_clear(kind: String, id: int, x: float, y: float, radius: float) -> bool:
	if not arena.static_legal_for(x, y, radius):
		return false
	for i in 2:
		if bool(actors[i]["alive"]):
			var other := _entity_radius("monster", i)
			var dx := float(actors[i]["x"]) - x
			var dy := float(actors[i]["y"]) - y
			if dx * dx + dy * dy < pow(radius + other + arena.GUARD, 2.0):
				return false
	for s in prey_slots.size():
		if bool(prey_slots[s]["live"]):
			var o2 := _entity_radius("prey", s)
			var dx2 := float(prey_slots[s]["x"]) - x
			var dy2 := float(prey_slots[s]["y"]) - y
			if dx2 * dx2 + dy2 * dy2 < pow(radius + o2 + arena.GUARD, 2.0):
				return false
	if kind == "monster":
		# Exclude self (it is down, so absent from the live sweep) — nothing else to do.
		pass
	else:
		# Exclude this depleted slot (absent from the live sweep) — nothing else to do.
		pass
	return true


func _try_place_monster(i: int) -> bool:
	var a: Dictionary = actors[i]
	var sec := _baby()
	var center: Array = (sec["nests"]["centers"] as Array)[i]
	var radius := float(a["radius"])
	var cands := arena.placement_candidates(center, sec["placement_ring_radii_mwu"])
	for c in cands:
		placement_test_total += 1
		if _placement_clear("monster", i, float(c[0]), float(c[1]), radius):
			a["x"] = float(c[0])
			a["y"] = float(c[1])
			return true
	return false


func _try_place_prey(s: int) -> bool:
	var p: Dictionary = prey_slots[s]
	var sec := _baby()
	var center: Array = (sec["prey"]["centers"] as Array)[s]
	var radius := float(p["radius"])
	var cands := arena.placement_candidates(center, sec["placement_ring_radii_mwu"])
	for c in cands:
		placement_test_total += 1
		if _placement_clear("prey", s, float(c[0]), float(c[1]), radius):
			p["x"] = float(c[0])
			p["y"] = float(c[1])
			return true
	return false


## Architect §6 exact restoration. Persistent build/stats/ledger/lifecycle generation remain.
func _restore_returned(a: Dictionary) -> void:
	a["hp"] = int(a["hp_max"])
	a["stam"] = int(a["stam_max"])
	a["fatigue_centi"] = 0
	a["lock_end"] = 0
	a["lock_latched"] = false
	a["physical_locked"] = false
	a["emotion"] = "Calm"
	a["control_mode"] = 0
	for sid in AUTHOR_SKILL_ORDER:
		a["cooldown_end"][sid] = tick
	a["recovery_end"] = tick
	a["action"] = null
	a["response_episode"] = null
	a["accepted_intent"] = null
	a["brace_action"] = -1
	a["brace_start"] = -1
	a["brace_end"] = -1
	a["bound_active"] = false
	a["bound_path"] = []
	a["bound_progress"] = 0.0
	a["bound_total"] = 0.0
	a["bound_action"] = -1
	a["bound_purpose"] = -1
	a["onset_bound_action"] = -1
	a["onset_prior_moving"] = false
	a["onset_prior_category"] = ""
	a["onset_prior_brace"] = false
	a["goal"] = null
	a["cycle_intent"] = -1
	a["cycle_request"] = 0
	a["cycle_episode"] = 0
	a["recovery_owner"] = -1
	a["rest_idle_ticks"] = 0
	a["pressure"] = 0
	a["pressure_key"] = ""
	a["last_repeat_credit"] = -9999
	a["last_plan"] = {}
	a["next_plan_tick"] = 0
	plan_watch[int(a["actor_id"])] = {}
	a["memory_valid"] = false
	a["memory_x"] = 0.0
	a["memory_y"] = 0.0
	a["memory_last_seen_tick"] = -1
	a["memory_expiry"] = 0
	a["memory_hp_band"] = -1
	a["memory_form"] = ""
	a["search_active"] = false
	a["search_start"] = -1
	a["search_deadline"] = -1
	a["search_token_exhausted"] = {}
	a["patrol_visited"] = []
	a["search_visited"] = []
	a["moved_this_boundary"] = false
	a["def_frozen"] = int(a["def"])
	a["brace_frozen"] = false
	a["brace_prepare_action"] = -1
	a["enemy_visible"] = false
	a["public_action"] = ""
	a["selected_target"] = {}
	a["prey_knowledge"] = [_new_knowledge(0), _new_knowledge(1)]
	a["last_hp_band"] = -1
	a["last_stam_band"] = -1
	a["last_fatigue_band"] = -1
	var npc: Variant = a.get("npc", null)
	if npc is Dictionary:
		(npc as Dictionary)["queued"] = null
		(npc as Dictionary)["history"] = []
		(npc as Dictionary)["repeated_episode"] = false
	_refresh_gates(a)


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
	if _is_baby():
		# A down actor does not plan, select, move or retain stale search influence.
		a["goal"] = null
		a["next_plan_tick"] = 0
		a["selected_target"] = {}
		a["search_active"] = false
		a["search_start"] = -1
		a["search_deadline"] = -1
		a["memory_valid"] = false
		a["enemy_visible"] = false
		a["accepted_intent"] = null
		a["pressure"] = 0
		a["pressure_key"] = ""
		a["last_plan"] = {}
		a["bound_purpose"] = -1
		a["onset_bound_action"] = -1
		a["onset_prior_moving"] = false
		a["onset_prior_category"] = ""
		a["onset_prior_brace"] = false
		a["public_action"] = "ko"
		var npc: Variant = a.get("npc", null)
		if npc is Dictionary:
			(npc as Dictionary)["queued"] = null
			(npc as Dictionary)["history"] = []
			(npc as Dictionary)["repeated_episode"] = false


func _cut6() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		if not bool(a["alive"]):
			continue
		if bool(a.get("returned_this_boundary", false)):
			# A body returned this boundary did not live the whole tick: no idle/resource credit.
			a["returned_this_boundary"] = false
			_publish_bands(a)
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


## Radius-aware static clip (same contract as _clip_polyline, actual body radius).
func _clip_polyline_for(proposal: Array, radius: float) -> Array:
	var out: Array = [[float(proposal[0][0]), float(proposal[0][1])]]
	for i in range(1, proposal.size()):
		var frm: Array = out[out.size() - 1]
		var to: Array = proposal[i]
		var t := arena.swept_static_limit_for(frm, to, radius)
		if t >= 1.0 - 1e-12:
			out.append([float(to[0]), float(to[1])])
			continue
		if t > 1e-12:
			out.append([float(frm[0]) + (float(to[0]) - float(frm[0])) * t,
				float(frm[1]) + (float(to[1]) - float(frm[1])) * t])
		break
	return out


## Prey flee trajectory for this boundary: walk the retained route from its cursor for `budget`.
func _route_polyline(from: Array, route: Array, idx: int, budget: float) -> Array:
	var out: Array = [[float(from[0]), float(from[1])]]
	var remaining := budget
	var i := idx
	var cur: Array = [float(from[0]), float(from[1])]
	while i < route.size() and remaining > 1e-9:
		var wp: Array = route[i]
		var dx := float(wp[0]) - float(cur[0])
		var dy := float(wp[1]) - float(cur[1])
		var d := sqrt(dx * dx + dy * dy)
		if d <= 1e-9:
			i += 1
			continue
		if d <= remaining + 1e-9:
			out.append([float(wp[0]), float(wp[1])])
			remaining -= d
			cur = [float(wp[0]), float(wp[1])]
			i += 1
		else:
			out.append([float(cur[0]) + dx * (remaining / d),
				float(cur[1]) + dy * (remaining / d)])
			break
	return out


func _body_moves(body: Dictionary) -> bool:
	return float(body["intended"]) > 1e-12


## C04: advance route progress from the PRE-step origin using the actual applied arc distance, so
## a corner is only consumed when the committed polyline genuinely traverses it.
func _advance_prey_cursor(p: Dictionary, origin: Array, travelled: float) -> void:
	var route: Array = p["route"]
	var i := int(p["route_i"])
	var remaining := travelled
	var cur: Array = [float(origin[0]), float(origin[1])]
	while i < route.size() and remaining > 1e-9:
		var wp: Array = route[i]
		var dx := float(wp[0]) - float(cur[0])
		var dy := float(wp[1]) - float(cur[1])
		var d := sqrt(dx * dx + dy * dy)
		if d <= 1e-9:
			i += 1
			continue
		if d <= remaining + 1e-9:
			remaining -= d
			cur = [float(wp[0]), float(wp[1])]
			i += 1
		else:
			break
	p["route_i"] = i
	if i >= route.size():
		p["route"] = []
		p["route_i"] = 0


func _capture_onset(a: Dictionary, body: Dictionary) -> void:
	var side := int(a["actor_id"])
	var cat := "other"
	if bool(body["bound"]):
		var purpose := int(a["bound_purpose"])
		if purpose == 2:
			cat = "defensive_evasion"
		elif purpose == 3:
			cat = "escape"
		else:
			cat = "other"
		if int(a["onset_bound_action"]) != int(a["bound_action"]):
			a["onset_bound_action"] = int(a["bound_action"])
			onset_slots[side] = cat
		return
	var goal: Variant = a["goal"]
	var purpose2 := ""
	if goal is Dictionary:
		purpose2 = str((goal as Dictionary).get("purpose", ""))
	cat = "escape" if purpose2 == "disengage" else "other"
	if not bool(a["onset_prior_moving"]) or str(a["onset_prior_category"]) != cat:
		onset_slots[side] = cat
	a["onset_prior_moving"] = true
	a["onset_prior_category"] = cat


## Expanded four-body swept resolver: stable body order, actual-radius static clip, at most six
## unordered pairs, earliest contact freezes ONLY contacting movers, at most four passes / 24
## pair tests. No shoving and no unrelated-body clamp; no-progress is a visible failure.
func _movement_cut_baby() -> void:
	var bodies: Array = []
	for i in 2:
		var a: Dictionary = actors[i]
		a["moved_this_boundary"] = false
		if not bool(a["alive"]):
			continue
		var prior: Array = [float(a["x"]), float(a["y"])]
		var want := 0.0
		var poly: Array = [prior]
		if bool(a["bound_active"]):
			var step := float(content.skill("short_bound")["travel_mwu_per_tick"])
			var remaining := float(a["bound_total"]) - float(a["bound_progress"])
			want = minf(step, remaining)
			if want > 0.0:
				poly = _bound_polyline(a, want)
		elif _movement_allowed(a):
			if _advance_goal(a):
				var goal: Variant = a["goal"]
				if goal is Dictionary and str((goal as Dictionary).get("kind", "")) == "move":
					var route: Array = (goal as Dictionary).get("route", [])
					if not route.is_empty():
						var tp: Array = route[int((goal as Dictionary).get("i", 0))]
						var dx := float(tp[0]) - float(prior[0])
						var dy := float(tp[1]) - float(prior[1])
						var d := sqrt(dx * dx + dy * dy)
						var speed := float(a["mov_mwu_per_s"]) / 60.0
						if d > 0.001:
							want = minf(speed, d)
							poly = [prior, [float(prior[0]) + dx * (want / d),
								float(prior[1]) + dy * (want / d)]]
			else:
				want = 0.0
		poly = _clip_polyline_for(poly, float(a["radius"]))
		bodies.append({"kind": "monster", "id": i, "prior": prior, "poly": poly,
			"arcs": M01Arena.poly_arcs(poly), "intended": want,
			"radius": float(a["radius"]), "bound": bool(a["bound_active"])})
	for s in prey_slots.size():
		var p: Dictionary = prey_slots[s]
		p["moved_this_boundary"] = false
		if not bool(p["live"]):
			continue
		var prior2: Array = [float(p["x"]), float(p["y"])]
		var want2 := 0.0
		var poly2: Array = [prior2]
		if int(p["threat"]) >= 0 and not (p["route"] as Array).is_empty():
			var speed2 := float(_baby()["prey"]["mov_mwu_per_s"]) / 60.0
			want2 = speed2
			poly2 = _route_polyline(prior2, p["route"], int(p["route_i"]), speed2)
		poly2 = _clip_polyline_for(poly2, float(p["radius"]))
		bodies.append({"kind": "prey", "id": s, "prior": prior2, "poly": poly2,
			"arcs": M01Arena.poly_arcs(poly2), "intended": want2,
			"radius": float(p["radius"]), "bound": false})

	var n := bodies.size()
	var stop: Array = []
	var contact_stop: Array = []
	var frozen: Array = []
	for i in n:
		stop.append(1.0)
		contact_stop.append(false)
		frozen.append(false)
	var pass_i := 0
	var tests := 0
	while pass_i < BABY_MAX_PASSES:
		var best := 2.0
		var contacts: Array = []
		for i in range(n):
			for j in range(i + 1, n):
				if tests >= BABY_MAX_PAIR_TESTS:
					break
				# R1: eligibility is based on REMAINING (unfrozen) movers. A frozen mover against an
				# originally stationary body is a stopped/stopped pair, not an unresolved contact;
				# stopped bodies still obstruct other continuing movers.
				if bool(frozen[i]) and bool(frozen[j]):
					continue
				var mi := _body_moves(bodies[i]) and not bool(frozen[i])
				var mj := _body_moves(bodies[j]) and not bool(frozen[j])
				if not mi and not mj:
					continue
				tests += 1
				var dist := float(bodies[i]["radius"]) + float(bodies[j]["radius"])
				var res := M01Arena.earliest_contact_polyline_stopped(
					bodies[i]["poly"], bodies[i]["arcs"], float(bodies[i]["intended"]),
					float(stop[i]), bodies[j]["poly"], bodies[j]["arcs"],
					float(bodies[j]["intended"]), float(stop[j]), dist)
				if bool(res[1]):
					var frac := float(res[0])
					if frac < best - 1e-12:
						best = frac
						contacts = [[i, j]]
					elif absf(frac - best) <= 1e-12:
						contacts.append([i, j])
		if contacts.is_empty():
			break
		var froze := false
		for pair in contacts:
			for member in pair:
				var m := int(member)
				if bool(frozen[m]) or not _body_moves(bodies[m]):
					continue
				stop[m] = minf(float(stop[m]), best)
				contact_stop[m] = true
				frozen[m] = true
				froze = true
		pass_i += 1
		if not froze:
			movement_contract_failures += 1
			break
	pair_test_total += tests

	for bi in n:
		var b: Dictionary = bodies[bi]
		var f := float(stop[bi])
		var applied := M01Arena.poly_point(b["poly"], b["arcs"], float(b["intended"]), f)
		var arc_end := float((b["arcs"] as Array)[(b["arcs"] as Array).size() - 1])
		var travelled := minf(f * float(b["intended"]), arc_end)
		var px := float(applied[0])
		var py := float(applied[1])
		if str(b["kind"]) == "monster":
			var a2: Dictionary = actors[int(b["id"])]
			var prior3: Array = b["prior"]
			a2["x"] = px
			a2["y"] = py
			a2["facing"] = _facing_for(prior3, applied, int(a2["facing"]))
			var moved := sqrt(pow(px - float(prior3[0]), 2.0)
				+ pow(py - float(prior3[1]), 2.0)) > 1e-9
			if moved:
				a2["moved_this_boundary"] = true
				_capture_onset(a2, b)
			if bool(a2["bound_active"]):
				var progress_after := float(a2["bound_progress"]) + travelled
				a2["bound_progress"] = progress_after
				var unfinished := progress_after < float(a2["bound_total"]) - 1e-6
				var travel_short := travelled < float(b["intended"]) - 1e-6
				if travel_short or (bool(contact_stop[bi]) and unfinished):
					var contact := bool(contact_stop[bi])
					_obstruct_bound(a2, _bound_terminal_reason(bi, contact, f,
						arc_end, float(b["intended"]), travel_short))
				elif not unfinished:
					_finish_bound(a2, "arrived")
		else:
			var p2: Dictionary = prey_slots[int(b["id"])]
			var prior4: Array = b["prior"]
			p2["x"] = px
			p2["y"] = py
			p2["facing"] = _facing_for(prior4, applied, int(p2["facing"]))
			if sqrt(pow(px - float(prior4[0]), 2.0)
					+ pow(py - float(prior4[1]), 2.0)) > 1e-9:
				p2["moved_this_boundary"] = true
			_advance_prey_cursor(p2, prior4, travelled)
	for i in 2:
		var ma: Dictionary = actors[i]
		if not bool(ma["moved_this_boundary"]):
			ma["onset_prior_moving"] = false
			ma["onset_prior_category"] = ""


## Prey sensing: nearest alive competing monster within threat range and LOS, tie side0.
func _prey_sense(p: Dictionary) -> int:
	var best := -1
	var best_d := INF
	var rng := float(_baby()["prey"]["threat_range_mwu"])
	for i in 2:
		if not bool(actors[i]["alive"]):
			continue
		var dx := float(actors[i]["x"]) - float(p["x"])
		var dy := float(actors[i]["y"]) - float(p["y"])
		var d2 := dx * dx + dy * dy
		if d2 > rng * rng:
			continue
		if not arena.line_of_effect(float(p["x"]), float(p["y"]),
				float(actors[i]["x"]), float(actors[i]["y"])):
			continue
		if d2 < best_d - 1e-9:
			best_d = d2
			best = i
	return best


## Prey planning on the existing 15-tick cadence: one bounded route tree per prey, choose the
## reachable legal node with the greatest squared distance from the sensed threat (tie lower id),
## then reconstruct ONE route. No RNG, no teleport, no relaxed limit.
func _prey_plan_cut() -> void:
	for s in prey_slots.size():
		var p: Dictionary = prey_slots[s]
		if not bool(p["live"]):
			continue
		var threat := _prey_sense(p)
		p["threat"] = threat
		if threat < 0:
			p["route"] = []
			p["route_i"] = 0
			continue
		p["threat_x"] = float(actors[threat]["x"])
		p["threat_y"] = float(actors[threat]["y"])
		if tick < int(p["next_plan_tick"]):
			continue
		_plan_prey_flee(p, threat)
		p["next_plan_tick"] = tick + int(content.tuning["vision"]["planning_ticks"])


func _plan_prey_flee(p: Dictionary, threat: int) -> void:
	var from: Array = [float(p["x"]), float(p["y"])]
	var tree := arena.build_route_tree(from)
	prey_search_total += 1
	var start_id := int(tree.get("start_id", -1))
	if not bool(tree.get("ok", false)) or start_id < 0:
		prey_violation_total += 1
		return
	var parent: Dictionary = tree.get("parent", {})
	var exp := int(tree.get("expansions", 0))
	prey_expansion_total += exp
	if exp > int(M01MonsterBehavior.MAX_SEARCH_EXPANSIONS):
		prey_violation_total += 1
	var tx := float(p["threat_x"])
	var ty := float(p["threat_y"])
	var best_id := -1
	var best_d2 := -1.0
	for id in arena.legal_nodes:
		if int(id) != start_id and not parent.has(int(id)):
			continue
		var c := arena.node_center(int(id))
		var dx := float(c[0]) - tx
		var dy := float(c[1]) - ty
		var d2 := dx * dx + dy * dy
		if d2 > best_d2 + 1e-9 \
				or (absf(d2 - best_d2) <= 1e-9 and (best_id < 0 or int(id) < best_id)):
			best_d2 = d2
			best_id = int(id)
	if best_id < 0:
		prey_violation_total += 1
		return
	var route := arena.route_from_tree(tree, from, arena.node_center(best_id))
	if route.is_empty():
		prey_violation_total += 1
		return
	p["route"] = route
	p["route_i"] = 0


func _movement_cut() -> void:
	if _is_baby():
		_movement_cut_baby()
		return
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
		if _is_baby() and not bool(a["alive"]):
			# A down observer has no live sensing and no stale search influence.
			a["enemy_visible"] = false
			a["memory_valid"] = false
			a["search_active"] = false
			continue
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
	if _is_baby():
		_update_prey_knowledge()


## Bounded three-entry observer knowledge: the competitor compatibility view above plus two prey
## entries. Frozen last-seen points are retained; a replacement life is never refreshed from
## hidden coordinates and never targeted while unseen.
func _update_prey_knowledge() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		if not bool(a["alive"]):
			continue
		for s in prey_slots.size():
			var k: Dictionary = (a["prey_knowledge"] as Array)[s]
			var p: Dictionary = prey_slots[s]
			var vis := bool(p["live"]) and _los_vision(a, [float(p["x"]), float(p["y"])])
			if vis:
				if int(k["life_id"]) != int(p["life_id"]):
					k["life_id"] = int(p["life_id"])
					k["token"] = int(k["token"]) + 1
					k["visited"] = []
				k["visible"] = true
				k["x"] = float(p["x"])
				k["y"] = float(p["y"])
				k["last_seen_tick"] = tick
				k["expiry"] = tick + int(content.tuning["vision"]["memory_ticks"])
				k["memory_valid"] = true
			else:
				k["visible"] = false
				if bool(k["memory_valid"]) and tick >= int(k["expiry"]):
					k["memory_valid"] = false


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
			"source_life": int(q.get("source_life", -1)),
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
				"source_life": int(a["life_id"]),
			}


func _publish_public_actions() -> void:
	for i in 2:
		var a: Dictionary = actors[i]
		var active_brace := int(a["brace_end"]) > tick and int(a["brace_start"]) >= 0 \
				and tick > int(a["brace_start"])
		if active_brace and not bool(a["onset_prior_brace"]):
			onset_slots[i] = "active_defense"
		a["onset_prior_brace"] = active_brace
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


## Stable copied target/area value for the causal queue fingerprint (never a live reference).
func _copy_target_value(v: Variant) -> Variant:
	if v == null:
		return null
	if v is int:
		return int(v)
	if v is float:
		return snappedf(v, 0.000001)
	if v is Array and (v as Array).size() == 2:
		var out: Array = []
		for e in v as Array:
			if e is int:
				out.append(int(e))
			elif e is float:
				out.append(snappedf(float(e), 0.000001))
			else:
				out.append(str(e))
		return out
	return str(v)


func canonical_state() -> Dictionary:
	var acts := []
	for a in actors:
		var row := {
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
		}
		if _is_baby():
			row["life_id"] = int(a["life_id"])
			row["lifecycle"] = str(a["lifecycle"])
			row["return_due"] = int(a["return_due"])
			row["selected_target"] = (a["selected_target"] as Dictionary).duplicate(true)
			row["prey_knowledge"] = (a["prey_knowledge"] as Array).duplicate(true)
			row["action"] = a["action"].duplicate(true) if a["action"] != null else null
			row["goal"] = a["goal"].duplicate(true) if a["goal"] != null else null
		acts.append(row)
	var out := {"tick": tick, "actors": acts, "streams": stream_draws.duplicate(true),
		"seed": str(root_seed), "mode": mode}
	if _is_baby():
		var effects: Array = []
		for e in pending_effects:
			var eref: Dictionary = {}
			var etr: Variant = e.get("target_ref", {})
			if etr is Dictionary:
				eref = etr as Dictionary
			effects.append({"effect": int(e.get("effect", 0)),
				"impact_tick": int(e.get("impact_tick", -1)),
				"action": int(e.get("action", 0)),
				"source": int(e.get("source", -1)),
				"source_life_id": int(e.get("source_life_id", -1)),
				"source_atk": int(e.get("source_atk", -1)),
				"base_power_cp": int(e.get("base_power_cp", -1)),
				"interrupt_power": int(e.get("interrupt_power", -1)),
				"kind": str(e.get("kind", "")),
				"target_ref": eref.duplicate(true),
				"target_life_id": int(e.get("target_life_id", -1)),
				"qualification": str(e.get("qualification", ""))})
		var prey_out: Array = []
		for s in prey_slots.size():
			var p: Dictionary = prey_slots[s]
			prey_out.append({"slot": s, "life_id": int(p["life_id"]), "live": bool(p["live"]),
				"hp": int(p["hp"]), "x": snappedf(float(p["x"]), 0.000001),
				"y": snappedf(float(p["y"]), 0.000001), "facing": int(p["facing"]),
				"respawn_due": int(p["respawn_due"]), "route_i": int(p["route_i"]),
				"next_plan_tick": int(p["next_plan_tick"]),
				"route": (p["route"] as Array).duplicate(true),
				"threat": int(p["threat"]),
				"credited": (p["credited"] as Array).duplicate(),
				"first_credit": (p["first_credit"] as Array).duplicate()})
		# Bounded copied gateway queue contents/identities in stable order (not a count only).
		# R4: admission/meaning-changing fields, including the command hint and envelope.
		var staged_copy: Array = []
		for raw in gateway.staged:
			staged_copy.append({"actor": int(raw.get("actor", -1)),
				"trainer": int(raw.get("trainer", -1)),
				"schema": str(raw.get("schema", "")),
				"slot": int(raw.get("slot", -1)),
				"sequence": int(raw.get("sequence", -1)),
				"family": int(raw.get("family", -1)),
				"target_kind": int(raw.get("target_kind", -1)),
				"target_or_area": _copy_target_value(raw.get("target_or_area", null)),
				"observed_tick": int(raw.get("observed_tick", -1)),
				"effective_tick": int(raw.get("effective_tick", -1)),
				"source_life": int(raw.get("source_life", -1))})
		staged_copy.sort_custom(func(x, y):
			if int(x["effective_tick"]) != int(y["effective_tick"]):
				return int(x["effective_tick"]) < int(y["effective_tick"])
			if int(x["sequence"]) != int(y["sequence"]):
				return int(x["sequence"]) < int(y["sequence"])
			return int(x["actor"]) < int(y["actor"]))
		out["baby"] = {"progression": progression.duplicate(true), "prey": prey_out,
			"pending_effects": effects, "gateway_staged": staged_copy,
			"gateway_staged_count": gateway.staged.size(),
			"pair_tests": pair_test_total, "placement_tests": placement_test_total,
			"prey_expansions": prey_expansion_total,
			"prey_violations": prey_violation_total,
			"movement_contract_failures": movement_contract_failures}
	return out


func _end_encounter(reason: int, batch: int) -> void:
	if ended:
		return
	ended = true
	end_reason = reason
	end_batch = batch
	telemetry.emit(tick, 20, [batch, reason, ko_actors.duplicate(), true])
	if reason == 2:
		_record("Sparring ended: diagnostic KO", "mutual KO", 0, "end")
	elif reason == 1:
		_record("Sparring ended: diagnostic KO", "", 0, "end")
	elif reason == 3:
		_record("Sparring ended: time limit", "", 0, "end")
	elif reason == 4:
		_record("Sparring stopped", "", 0, "end")
	else:
		_record("Sparring ended: result unavailable", "", 0, "end")


## Expanded Baby terminal end: no winner, empty terminal ko_actors, future schedules cancelled.
func _end_encounter_baby(reason: int, batch: int) -> void:
	if ended:
		return
	ended = true
	end_reason = reason
	end_batch = batch
	ko_actors = []
	for a in actors:
		a["return_due"] = -1
	for p in prey_slots:
		p["respawn_due"] = -1
	telemetry.emit(tick, 20, [batch, reason, [], true])
	if reason == 3:
		_record("Baby playtest complete", "", 0, "end")
	elif reason == 4:
		_record("Playtest stopped", "", 0, "end")
	else:
		_record("Baby playtest stopped: result unavailable", "", 0, "end")


func schema_name() -> String:
	return SCHEMA_EXPANDED if _is_baby() else SCHEMA


func terminal_category() -> String:
	if not ended:
		return ""
	if _is_baby():
		if end_reason == 3:
			return "baby_complete"
		if end_reason == 4:
			return "aborted"
		return "incomplete"
	match end_reason:
		1:
			if ko_actors.size() == 1 and int(ko_actors[0]) == 0:
				return "own_down"
			if ko_actors.size() == 1 and int(ko_actors[0]) == 1:
				return "enemy_down"
			return "incomplete"
		2:
			if ko_actors.size() == 2 and int(ko_actors[0]) != int(ko_actors[1]):
				return "both_down"
			return "incomplete"
		3:
			return "timeout"
		4:
			return "aborted"
	return "incomplete"


func _enemy_sample(observer: int) -> Dictionary:
	var own: Dictionary = actors[observer]
	var enemy: Dictionary = actors[1 - observer]
	var state := M01Observations.visibility_state(own, tick)
	var out := {"knowledge": state, "position": null, "facing": null, "life_id": null,
		"action": "", "performed_onset": "", "last_known_position": null,
		"hp_band": -1, "last_seen_tick": -1}
	if state == 2:
		out["position"] = [float(enemy["x"]), float(enemy["y"])]
		out["facing"] = int(enemy["facing"])
		out["life_id"] = int(enemy["life_id"])
		out["action"] = str(enemy.get("public_action", ""))
		out["performed_onset"] = str(onset_slots.get(1 - observer, ""))
		out["hp_band"] = M01Observations.hp_band(int(enemy["hp"]), int(enemy["hp_max"]))
		out["last_seen_tick"] = tick
	elif state == 1:
		out["last_known_position"] = [float(own["memory_x"]), float(own["memory_y"])]
		out["hp_band"] = int(own["memory_hp_band"])
		out["last_seen_tick"] = int(own["memory_last_seen_tick"])
	return out


func _visible_prey_samples(observer: int) -> Array:
	var out: Array = []
	if not _is_baby():
		return out
	var a: Dictionary = actors[observer]
	if not bool(a["alive"]):
		return out
	for s in prey_slots.size():
		var p: Dictionary = prey_slots[s]
		if not bool(p["live"]) or not _prey_visible_to(a, s):
			continue
		out.append({"slot": s, "life_id": int(p["life_id"]),
			"x": float(p["x"]), "y": float(p["y"]), "facing": int(p["facing"]),
			"moving": bool(p["moved_this_boundary"])})
		if out.size() >= 2:
			break
	return out


func _nest_copy() -> Array:
	if not _is_baby():
		return []
	var sec := _baby()
	var out: Array = []
	for i in 2:
		var c: Array = (sec["nests"]["centers"] as Array)[i]
		out.append({"side": i, "x": float(c[0]), "y": float(c[1]),
			"radius": float(sec["nests"]["radius_mwu"])})
	return out


## Fixed observer-0 public projection for presentation. Copies already-captured values only;
## reading it neither consumes an onset nor reveals hidden positions.
func presentation_view_for_human() -> Dictionary:
	var own: Dictionary = actors[0]
	var status := "alive"
	if _is_baby() and not bool(own["alive"]):
		status = "waiting_return" if int(own["return_due"]) >= 0 \
			and tick >= int(own["return_due"]) else "down"
	return {
		"schema": schema_name(),
		"mode": mode,
		"tick": tick,
		"terminal_category": terminal_category(),
		"own": {"side": 0, "life_id": int(own["life_id"]), "status": status,
			"position": [float(own["x"]), float(own["y"])], "facing": int(own["facing"]),
			"action": str(own.get("public_action", "")),
			"performed_onset": str(onset_slots.get(0, "")),
			"growth_tick": int(own.get("growth_notice_tick", -1)),
			"return_tick": int(own.get("return_notice_tick", -1))},
		"enemy": _enemy_sample(0),
		"prey": _visible_prey_samples(0),
		"nests": _nest_copy(),
		"layout": _map_copy(),
	}


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
	if _is_baby():
		reason_name = {3: "baby_complete", 4: "aborted"}
	var out := {
		"schema": schema_name(),
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
	if _is_baby():
		out["terminal_category"] = terminal_category()
		out["life_ids"] = [int(actors[0]["life_id"]), int(actors[1]["life_id"])]
		out["lifecycle"] = [str(actors[0]["lifecycle"]), str(actors[1]["lifecycle"])]
		out["return_due"] = [int(actors[0]["return_due"]), int(actors[1]["return_due"])]
		out["progression"] = progression.duplicate(true)
		var prey_out: Array = []
		for s in prey_slots.size():
			var p: Dictionary = prey_slots[s]
			prey_out.append({"slot": s, "life_id": int(p["life_id"]), "live": bool(p["live"]),
				"hp": int(p["hp"]), "x": snappedf(float(p["x"]), 0.000001),
				"y": snappedf(float(p["y"]), 0.000001), "respawn_due": int(p["respawn_due"]),
				"credited": (p["credited"] as Array).duplicate(),
				"first_credit": (p["first_credit"] as Array).duplicate(),
				"route_cursor": int(p["route_i"]), "next_plan_tick": int(p["next_plan_tick"])})
		out["prey"] = prey_out
		out["baby_work"] = {"pair_tests": pair_test_total,
			"placement_tests": placement_test_total,
			"prey_searches": prey_search_total,
			"prey_expansions": prey_expansion_total,
			"prey_violations": prey_violation_total,
			"movement_contract_failures": movement_contract_failures}
	return out


func observe_for(observer: int) -> Dictionary:
	var enemy := 1 - observer
	var mem := {}
	if bool(actors[observer]["memory_valid"]):
		mem = {"x": float(actors[observer]["memory_x"]), "y": float(actors[observer]["memory_y"]),
			"tick": int(actors[observer]["memory_last_seen_tick"]),
			"hp_band": int(actors[observer]["memory_hp_band"]),
			"form": str(actors[observer]["memory_form"])}
	# Canonical actors0/1 order: build_trainer_observation indexes its own array by the global
	# observer index, which previously swapped observer1's own/enemy views.
	return M01Observations.build_trainer_observation(observer, tick, actors, enemy,
		_map_copy(), mem)


func _map_copy() -> Dictionary:
	var spawn_copy := arena.spawn.duplicate(true)
	if _is_baby():
		spawn_copy = (_baby()["nests"]["centers"] as Array).duplicate(true)
	return {
		"width": int(arena.width), "height": int(arena.height),
		"blocker": [int(arena.original_blocker()[0]), int(arena.original_blocker()[1]),
			int(arena.original_blocker()[2]), int(arena.original_blocker()[3])],
		"spawn": spawn_copy,
		"patrol": arena.patrol.duplicate(true),
	}
