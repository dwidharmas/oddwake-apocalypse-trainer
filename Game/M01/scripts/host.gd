class_name M01Host
extends Node

signal lifecycle_changed(paused: bool, reason: String)
signal download_status_changed(status: String, message: String)
signal encounter_changed

const TICK_SECONDS := 1.0 / 60.0
const WEB_DOWNLOAD_NAME := "mm_m01_evidence.jsonl"
const ROLE_HASHES := {
	"Docs/tasks/MM-M01-001.md": "c39d039d36264057bda54d398220733866760a1073cecae861eb62782819637d",
	"Docs/reviews/qa/QA-M01-002.md": "1047606f9c5875bfcebbea0d2c21a391354ee199334c952f9947f9d093b5469d",
	"Docs/reviews/architecture/ARCH-M01-001.md": "3f7f3e49949178d65824bfbedfe5d1005415785f209ec78ecfc24409d6f3deba",
	"Docs/reviews/gameplay/GAMEPLAY-M01-001.md": "f8cffc79940eabd3146d4b7dda7d727c34e6b329ec6ea27b71b0715ea694af4a",
	"Docs/reviews/visual/VIS-M01-001.md": "925ddaefb260ac70d135ec567198be0d860d3bc7c8921824848a56a55d4ebec7",
	"Docs/QA_TEST_PLAN.md": "8b5a66ad95270aaacf0e455467097bb190ee5b71ca784b0501e14adcd3906cd8",
}

var content := M01Content.new()
var arena := M01Arena.new()
var telemetry := M01Telemetry.new()
var sim: M01Simulation

var accumulator := 0.0
var paused := true
var started := false
var pause_reason := ""
var resume_required := true
var input_sequence := {0: 0, 1: 0}
var held_keys := {}
var backlog_ticks := 0
var max_backlog := 0
var slow_frames := 0

var download_status := "not_requested"
var download_message := ""
var prepared_bundle: PackedByteArray = PackedByteArray()
var prepared_sha := ""
var prepared_size := 0
var download_attempts: Array = []
var inject_prepare_failure := false
var inject_unavailable_bridge := false

var frame_ms_samples: Array[float] = []
var telemetry_on := true
var content_error := ""
var run_started_usec := 0
var browser_identity := ""
var engine_identity := ""
var build_id := "mm-m01-r01"
var root_seed := 3101
var mode := "live"
var fixture := {}
var restart_count := 0
var cue_events: Array = []
var frame_counter := 0
var presentation: M01Presentation = null
var stage_mono_queue: Array = []
var stage_request_queue: Array = []


func _ready() -> void:
	engine_identity = Engine.get_version_info().get("string", "unknown")
	if OS.has_feature("web"):
		browser_identity = JavaScriptBridge.eval("navigator.userAgent") as String
	else:
		browser_identity = "%s %s" % [OS.get_name(), OS.get_version()]
	var ok := content.load_from_disk()
	if not ok:
		content_error = content.failure_report()
		push_error("M01 content load failed:\n" + content_error)
		return
	arena.setup(content.arena)
	presentation = get_node_or_null("World") as M01Presentation
	_reset_run()
	_wire_hud()
	# R-F05/QA-RES-F04: no automatic combat startup. Loading ends in the paused ready
	# state at tick 0; only an explicit Start activation calls begin_run(), so no
	# simulation/resource/AI/RNG advancement happens before the user gesture.


func _reset_run() -> void:
	telemetry.reset()
	sim = M01Simulation.new()
	sim.setup(content, arena, telemetry, mode, root_seed, fixture)
	input_sequence = {0: 0, 1: 0}
	accumulator = 0.0
	paused = true
	started = false
	resume_required = true
	prepared_bundle = PackedByteArray()
	prepared_sha = ""
	prepared_size = 0
	download_status = "not_requested"
	download_message = ""
	frame_ms_samples.clear()
	cue_events.clear()
	frame_counter = 0
	_build_header()
	telemetry.emit(0, 22, ["pause", "reset"])
	lifecycle_changed.emit(true, "reset")


func _build_header() -> void:
	var streams_info := {}
	for sname in ["response.side0", "response.side1", "monster.side0", "monster.side1", "trainer.side1"]:
		streams_info[sname] = sim.stream_seed_hex(sname)
	var initial := []
	for a in sim.actors:
		initial.append({
			"actor": int(a["actor_id"]), "hp": int(a["hp"]), "stam": int(a["stam"]),
			"x": snappedf(float(a["x"]), 0.000001), "y": snappedf(float(a["y"]), 0.000001),
			"atk": int(a["atk"]), "def": int(a["def"]), "int": int(a["int_stat"]),
			"instinct": int(a["instinct"]), "bond": int(a["bond"]),
			"fatigue_centi": int(a["fatigue_centi"]),
		})
	telemetry.build_header({
		"mode": mode,
		"fixture_id": sim.fixture_id if sim.fixture_id != "" else null,
		"engine": engine_identity,
		"build": build_id,
		"platform": OS.get_name(),
		"browser": browser_identity,
		"role_hashes": ROLE_HASHES,
		"content_hashes": content.hashes,
		"map_hash": content.hashes.get("arena", ""),
		"tuning_hash": content.hashes.get("tuning", ""),
		"root_seed": str(root_seed),
		"stream_seeds": streams_info,
		"stream_draw_counts": sim.stream_draws.duplicate(true),
		"initial_state": {"actors": initial, "diagnostic_effects": fixture.get("arriving_effects", [])},
		"loadouts": [{"trainer": 0, "slots": ["Attack", "Defense", "Run", "Empty", "Empty", "Empty", "Empty", "Empty"]},
			{"trainer": 1, "slots": ["Attack", "Defense", "Run", "Empty", "Empty", "Empty", "Empty", "Empty"]}],
		"compiled_ticks": content.compiled,
	})


func _wire_hud() -> void:
	var hud := get_node_or_null("HUD") as Control
	if hud == null or presentation == null:
		return
	var panel := hud.get_node_or_null("Panel/Rows")
	if panel == null:
		return
	var slots := panel.get_node_or_null("Slots")
	if slots != null:
		for i in 8:
			var b := slots.get_node_or_null("Slot%d" % (i + 1)) as Button
			if b == null:
				continue
			var idx := i
			b.pressed.connect(_on_slot_pressed.bind(idx))
	var toolbar := panel.get_node_or_null("Toolbar")
	if toolbar == null:
		return
	var start_b := toolbar.get_node_or_null("Start encounter") as Button
	if start_b == null:
		for cnode in toolbar.get_children():
			if cnode is Button and (cnode as Button).text == "Start encounter":
				start_b = cnode as Button
	if start_b != null:
		start_b.pressed.connect(begin_run)
	var resume_b := _find_button(toolbar, "Resume")
	if resume_b != null:
		resume_b.pressed.connect(request_resume)
	var restart_b := _find_button(toolbar, "Restart")
	if restart_b != null:
		restart_b.pressed.connect(restart_run)
	var download_b := _find_button(toolbar, "Download evidence")
	if download_b != null:
		download_b.pressed.connect(prepare_bundle.bind(true))
	var text_btn := toolbar.get_node_or_null("TextSize") as OptionButton
	if text_btn != null:
		text_btn.item_selected.connect(_on_text_scale)
	var gray_btn := toolbar.get_node_or_null("Grayscale") as CheckButton
	if gray_btn != null:
		gray_btn.toggled.connect(_on_grayscale)
	var motion_btn := toolbar.get_node_or_null("ReducedMotion") as CheckButton
	if motion_btn != null:
		motion_btn.toggled.connect(_on_motion)
	presentation.text_scale = 1.0


func _find_button(root: Node, label: String) -> Button:
	for cnode in root.get_children():
		if cnode is Button and (cnode as Button).text == label:
			return cnode as Button
	return null


func _on_slot_pressed(index: int) -> void:
	if index >= 3:
		return
	submit_human_input(index + 1)


func _on_text_scale(index: int) -> void:
	var scales := [1.0, 1.25, 1.5, 2.0]
	if presentation != null:
		presentation.text_scale = float(scales[clampi(index, 0, 3)])
		presentation.mark_hud_dirty()


func _on_grayscale(on: bool) -> void:
	if presentation != null:
		presentation.grayscale = on
		presentation.mark_hud_dirty()


func _on_motion(on: bool) -> void:
	if presentation != null:
		presentation.reduced_motion = on
		presentation.mark_hud_dirty()


func begin_run(p_seed: int = -1, p_mode: String = "", p_fixture: Dictionary = {}) -> void:
	if p_seed > 0:
		root_seed = p_seed
	if p_mode != "":
		mode = p_mode
	fixture = p_fixture
	_reset_run()
	started = true
	paused = false
	resume_required = false
	run_started_usec = Time.get_ticks_usec()
	telemetry.emit(0, 22, ["resume", "start"])
	lifecycle_changed.emit(false, "start")
	encounter_changed.emit()


func restart_run() -> void:
	restart_count += 1
	begin_run(root_seed, mode, fixture)


func set_fixture(p_fixture: Dictionary) -> void:
	fixture = p_fixture


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		_pause("visibility")
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if started and paused and pause_reason == "visibility":
			resume_required = true
			lifecycle_changed.emit(true, "resume_required")


func _pause(reason: String) -> void:
	if paused:
		return
	paused = true
	pause_reason = reason
	resume_required = reason == "visibility"
	held_keys.clear()
	telemetry.emit(sim.tick if sim != null else 0, 22, ["pause", reason])
	lifecycle_changed.emit(true, reason)


func request_resume() -> void:
	if not started:
		return
	if not resume_required and paused and pause_reason != "manual":
		return
	paused = false
	resume_required = false
	pause_reason = ""
	accumulator = 0.0
	telemetry.emit(sim.tick, 22, ["resume", "user_activation"])
	lifecycle_changed.emit(false, "resume")


func toggle_pause() -> void:
	if not started:
		return
	if paused:
		request_resume()
	else:
		_pause("manual")
		resume_required = true


func _process(delta: float) -> void:
	var f0 := Time.get_ticks_usec()
	frame_counter += 1
	if not started or paused or sim == null:
		return
	if delta > TICK_SECONDS * 1.5:
		slow_frames += 1
		backlog_ticks += 1
		max_backlog = maxi(max_backlog, backlog_ticks)
	accumulator += delta
	var steps := 0
	while accumulator >= TICK_SECONDS and steps < 4:
		accumulator -= TICK_SECONDS
		backlog_ticks = maxi(0, backlog_ticks - 1)
		sim.step()
		steps += 1
		if sim.ended:
			_finish_run()
			break
	if steps == 4 and accumulator >= TICK_SECONDS:
		telemetry.note("sustained skipped-tick backlog detected at tick %d" % sim.tick)
	var f1 := Time.get_ticks_usec()
	frame_ms_samples.append(float(f1 - f0) / 1000.0)
	if frame_ms_samples.size() > 20000:
		frame_ms_samples.pop_front()


func _finish_run() -> void:
	paused = true
	pause_reason = "encounter_end"
	var summary: Dictionary = sim.summary()
	telemetry.emit(sim.tick, 22, ["pause", "encounter_end"])
	telemetry.close_footer(summary, true)
	prepare_bundle(false)
	encounter_changed.emit()
	lifecycle_changed.emit(true, "encounter_end")


func submit_human_input(family: int) -> void:
	if not started or sim == null or sim.ended:
		return
	if paused:
		return
	var actor: Dictionary = sim.actors[0]
	if int(actor["control_mode"]) != 0:
		_emit_reject_locally(family, "control")
		return
	input_sequence[0] = int(input_sequence[0]) + 1
	var raw := {
		"schema": "m01.1", "trainer": 0, "actor": 0,
		"sequence": int(input_sequence[0]), "slot": family - 1, "family": family,
		"target_kind": 0, "target_or_area": null,
		"observed_tick": sim.tick,
	}
	stage_mono_queue.append(Time.get_ticks_usec())
	if stage_mono_queue.size() > 64:
		stage_mono_queue.pop_front()
	if presentation != null:
		presentation.set_slot_flash(family - 1)
	sim.gateway.stage(raw, sim.tick + 1)
	cue_events.append({"tick": sim.tick, "kind": "request_sent", "family": family,
		"mono": Time.get_ticks_usec()})
	encounter_changed.emit()


func _emit_reject_locally(family: int, reason: String) -> void:
	telemetry.emit(sim.tick, 2, [0, 0, reason])
	cue_events.append({"tick": sim.tick, "kind": "rejected", "family": family, "reason": reason,
		"mono": Time.get_ticks_usec()})


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.echo:
			return
		var focus_owner := get_viewport().gui_get_focus_owner()
		if focus_owner is LineEdit or focus_owner is TextEdit or focus_owner is SpinBox:
			return
		if event.keycode == KEY_1:
			submit_human_input(1)
		elif event.keycode == KEY_2:
			submit_human_input(2)
		elif event.keycode == KEY_3:
			submit_human_input(3)
		elif event.keycode == KEY_SPACE:
			toggle_pause()
		elif event.keycode == KEY_R and event.ctrl_pressed:
			restart_run()
		get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and event.pressed:
		get_viewport().set_input_as_handled()


func prepare_bundle(user_action: bool = true) -> bool:
	if inject_prepare_failure:
		download_status = "detectable_error"
		download_message = "Evidence could not be prepared: injected serialization failure (diagnostic)."
		download_attempts.append({"tick": sim.tick if sim else 0, "status": download_status,
			"reason": "injected_prepare_failure"})
		download_status_changed.emit(download_status, download_message)
		return false
	var res := telemetry.prepare_bundle()
	if not bool(res["ok"]):
		download_status = "detectable_error"
		download_message = "Evidence could not be prepared: %s" % str(res.get("reason", "unknown"))
		download_attempts.append({"tick": sim.tick if sim else 0, "status": download_status,
			"reason": str(res.get("reason", ""))})
		download_status_changed.emit(download_status, download_message)
		return false
	prepared_bundle = telemetry.prepared_bytes
	prepared_size = int(res["bytes"])
	prepared_sha = str(res["sha256"])
	if user_action:
		request_download()
	return true


func request_download() -> void:
	if prepared_bundle.is_empty():
		download_status = "detectable_error"
		download_message = "Download could not be requested: no prepared bytes."
		download_attempts.append({"tick": sim.tick if sim else 0, "status": download_status,
			"reason": "no_prepared_bytes"})
		download_status_changed.emit(download_status, download_message)
		return
	if not OS.has_feature("web") or inject_unavailable_bridge:
		download_status = "detectable_error"
		download_message = "Download could not be requested: web bridge unavailable (diagnostic)."
		download_attempts.append({"tick": sim.tick if sim else 0, "status": download_status,
			"reason": "bridge_unavailable"})
		download_status_changed.emit(download_status, download_message)
		return
	JavaScriptBridge.download_buffer(prepared_bundle, WEB_DOWNLOAD_NAME)
	download_status = "requested_delivery_unknown"
	download_message = "Download requested. Check your browser's downloads; saving cannot be confirmed here."
	download_attempts.append({"tick": sim.tick if sim else 0, "status": download_status,
		"bytes": prepared_bundle.size(), "sha256": prepared_sha})
	download_status_changed.emit(download_status, download_message)


func capture_integrity() -> String:
	if telemetry.footer.is_empty():
		return "incomplete"
	return str(telemetry.footer.get("completeness", "incomplete"))


func performance_report() -> Dictionary:
	var sim_samples: Array = sim.sim_time_ms_samples if sim != null else []
	var frame := frame_ms_samples.duplicate()
	return {
		"sim_samples": sim_samples.size(),
		"sim_mean_ms": _mean(sim_samples),
		"sim_p95_ms": _pct(sim_samples, 0.95),
		"frame_samples": frame.size(),
		"frame_p95_ms": _pct(frame, 0.95),
		"max_backlog": max_backlog,
		"slow_frames": slow_frames,
		"events_per_active_second_peak": telemetry.active_rate_peak,
		"bytes_per_active_minute_peak": telemetry.active_bytes_rate_peak,
	}


static func _mean(arr: Array) -> float:
	if arr.is_empty():
		return 0.0
	var total := 0.0
	for v in arr:
		total += float(v)
	return total / float(arr.size())


static func _pct(arr: Array, p: float) -> float:
	if arr.is_empty():
		return 0.0
	var copy := arr.duplicate()
	copy.sort()
	var idx := clampi(int(floor(float(copy.size()) * p)), 0, copy.size() - 1)
	return float(copy[idx])
