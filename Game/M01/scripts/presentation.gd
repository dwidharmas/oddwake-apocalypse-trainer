class_name M01Presentation
extends Node2D

const POSE_IDS := [
	"P01", "P02", "P03", "P04", "P05", "P06", "P07",
	"P08", "P09", "P10", "P11", "P12", "P13",
]
const FACING_NAMES := ["north", "east", "south", "west"]

const COL_BOARD := Color("12161A")
const COL_GROUND := Color("1A2026")
const COL_BLOCKER := Color("0C0F12")
const COL_EDGE := Color("8A9299")
const COL_BONE := Color("EDE7DA")
const COL_ACCENT := Color("C8B27A")
const COL_MUTED := Color("A9B2B8")
const COL_DANGER := Color("E2705A")
const COL_FOCUS := Color("F5D97A")
const COL_BACKING := Color("0B0E11")
const COL_PANEL_BORDER := Color("8A9299")
const COL_STALE := Color("8A9299")

const GRAY := {
	"board": Color("121212"), "ground": Color("2E2E2E"), "blocker": Color("0A0A0A"),
	"edge": Color("8C8C8C"), "bone": Color("D6D6D6"), "accent": Color("B4B4B4"),
	"muted": Color("9C9C9C"), "danger": Color("C4C4C4"), "focus": Color("F0F0F0"),
	"backing": Color("0F0F0F"), "border": Color("8C8C8C"), "stale": Color("8C8C8C"),
}

const POSE_PARAMS := {
	"P01": {"lean": 0.0, "arm": 18.0, "leg": 0.0, "head": 0.0, "crouch": 0.0, "droop": 0.0},
	"P02": {"lean": 4.0, "arm": 34.0, "leg": 22.0, "head": -4.0, "crouch": 0.0, "droop": 0.0},
	"P03": {"lean": -4.0, "arm": -12.0, "leg": -22.0, "head": 4.0, "crouch": 0.0, "droop": 0.0},
	"P04": {"lean": 6.0, "arm": 12.0, "leg": 0.0, "head": 26.0, "crouch": 0.0, "droop": 0.0},
	"P05": {"lean": -8.0, "arm": 10.0, "leg": 0.0, "head": -30.0, "crouch": 0.0, "droop": 0.0},
	"P06": {"lean": 14.0, "arm": 74.0, "leg": 10.0, "head": 8.0, "crouch": 0.0, "droop": 0.0},
	"P07": {"lean": 10.0, "arm": 6.0, "leg": 6.0, "head": 6.0, "crouch": 0.35, "droop": 0.0},
	"P08": {"lean": 0.0, "arm": -24.0, "leg": 26.0, "head": 0.0, "crouch": 0.2, "droop": 0.0},
	"P09": {"lean": 18.0, "arm": 40.0, "leg": 34.0, "head": 12.0, "crouch": 0.6, "droop": 0.0},
	"P10": {"lean": -16.0, "arm": -40.0, "leg": -30.0, "head": -6.0, "crouch": 0.1, "droop": 0.0},
	"P11": {"lean": 12.0, "arm": -6.0, "leg": 4.0, "head": 34.0, "crouch": 0.45, "droop": 1.0},
	"P12": {"lean": 74.0, "arm": -70.0, "leg": -60.0, "head": 40.0, "crouch": 0.9, "droop": 1.0},
	"P13": {"lean": -3.0, "arm": 8.0, "leg": 4.0, "head": -8.0, "crouch": 0.1, "droop": 0.0},
}

var host: Node = null
var hud_root: Control = null
var world: Node2D = null

var text_scale := 1.0
var grayscale := false
var reduced_motion := false
## R-F04: dirty flag — HUD/arena repaint only while running or after a state change.
var hud_dirty := true
var last_viewport_size := Vector2(-1, -1)

var own_labels: Label
var enemy_label: Label
var cue_label: Label
var lock_banner: Label
var slot_buttons: Array = []
var record_labels: Array = []
var toolbar: HBoxContainer
var start_button: Button
var resume_button: Button
var restart_button: Button
var download_button: Button
var text_scale_button: OptionButton
var grayscale_button: CheckButton
var motion_button: CheckButton
var status_label: Label
var download_status_label: Label
var loading_label: Label

var forced_pose := {}
var forced_pose_ticks := 0
var public_view := {}
var snapshot_tick := -1
var snapshot_prev_tick := -1
var own_prev_pos: Variant = null
var own_cur_pos: Variant = null
var enemy_prev_pos: Variant = null
var enemy_cur_pos: Variant = null
var snapshot_own_life := -1
var snapshot_enemy_life := -1
var own_moving := false
var enemy_moving := false
## C09: exactly one replaceable slash slot per side, keyed by captured source life.
var slash_slots := {0: {}, 1: {}}
var callouts := {0: {}, 1: {}}
var active_ms := 0.0
var result_card: PanelContainer = null
var result_title: Label = null
var result_body: Label = null
var result_footer: Label = null
var restart_home: Node = null
var restart_home_index := -1
var card_active := false
var stale_enemy := {}
var last_enemy_knowledge := -1
var last_record_size := -1
var last_record_head := ""
var last_cue_text := ""
var cue_latency_samples: Array = []
var pending_probes := {}
var slot_flash := {}
var walk_phase := 0.0
var time_accum := 0.0
var contact_marks: Array = []
var swipe_marks: Array = []
var palette_cache := {}
# COMMAND-FEEDBACK01: exactly two retained request scalars. Newest observed own
# receipt/response only; action/Hit/Miss never write them, reset restores the neutral text.
var retained_request_text := "No request yet"
var retained_request_kind := ""

const BOTTOM_MIN := 190
const BOTTOM_MAX := 216


func _ready() -> void:
	world = self
	hud_root = get_node_or_null("HUD") as Control
	host = get_parent()
	if hud_root == null and host != null:
		hud_root = host.get_node_or_null("HUD") as Control
	if hud_root != null:
		_build_hud()
	if host != null and host.has_signal("encounter_changed"):
		if not host.is_connected("encounter_changed", _on_encounter_changed):
			host.connect("encounter_changed", _on_encounter_changed)
	if host != null and host.has_signal("lifecycle_changed"):
		if not host.is_connected("lifecycle_changed", _on_host_state_changed):
			host.connect("lifecycle_changed", _on_host_state_changed)
	if host != null and host.has_signal("download_status_changed"):
		if not host.is_connected("download_status_changed", _on_host_download_changed):
			host.connect("download_status_changed", _on_host_download_changed)


func mark_hud_dirty() -> void:
	hud_dirty = true


func _on_host_state_changed(_paused: bool, reason: String) -> void:
	# COMMAND-FEEDBACK01: reason "reset" is the only explicit reset discriminator — host
	# _reset_run replaces the simulation, so retention and presentation/probe caches go back
	# to the neutral state. encounter_changed (host emits it on input too) must not do this.
	if reason == "reset":
		retained_request_text = "No request yet"
		retained_request_kind = ""
		last_cue_text = ""
		last_record_size = -1
		last_record_head = ""
		pending_probes.clear()
		latency_probe_request = 0
		latency_probe_mono = 0
		public_view = {}
		snapshot_tick = -1
		snapshot_prev_tick = -1
		own_prev_pos = null
		own_cur_pos = null
		enemy_prev_pos = null
		enemy_cur_pos = null
		snapshot_own_life = -1
		snapshot_enemy_life = -1
		callouts = {0: {}, 1: {}}
		slash_slots = {0: {}, 1: {}}
		contact_marks.clear()
		swipe_marks.clear()
		stale_enemy.clear()
		_hide_result_card()
	else:
		# R6: every pause/resume/lifecycle boundary invalidates motion baselines. Frozen
		# slash/text ages and the guard are deliberately preserved.
		own_moving = false
		enemy_moving = false
		own_prev_pos = null
		own_cur_pos = null
		enemy_prev_pos = null
		enemy_cur_pos = null
	hud_dirty = true


func _on_host_download_changed(_status: String, _message: String) -> void:
	hud_dirty = true


func _on_encounter_changed() -> void:
	last_record_size = -1
	last_record_head = ""
	last_cue_text = ""
	pending_probes.clear()
	hud_dirty = true


func _is_expanded() -> bool:
	return host != null and host.sim != null and host.sim.is_expanded()


func receive_public_snapshot(view: Dictionary) -> void:
	var t := int(view.get("tick", -1))
	if t <= snapshot_tick:
		return
	var prev_tick := snapshot_tick
	var own: Dictionary = view.get("own", {})
	var own_pos: Variant = own.get("position", null)
	var en: Dictionary = view.get("enemy", {})
	var en_pos: Variant = en.get("position", null)
	public_view = view
	snapshot_tick = t
	# OWN baseline: previous/current pair retained through draw (C10); invalidated on a
	# nonconsecutive tick, generation change, pause/end or reset.
	var own_life := int(own.get("life_id", -1))
	var own_status := str(own.get("status", "alive"))
	var own_action := str(own.get("action", ""))
	var own_ko := own_status == "down" or own_status == "waiting_return" or own_action == "ko"
	var en_visible := int(en.get("knowledge", 0)) == 2
	var en_life := int(en.get("life_id", -1)) if en_visible else -1
	var en_action := str(en.get("action", "")) if en_visible else ""
	var enemy_ko := en_visible and en_action == "ko"
	var consecutive := prev_tick == t - 1
	var own_prev: Variant = own_cur_pos
	own_cur_pos = Vector2(float(own_pos[0]), float(own_pos[1])) if own_pos != null else null
	own_moving = consecutive and own_prev != null and own_cur_pos != null \
		and ((own_cur_pos as Vector2) - (own_prev as Vector2)).length() > 0.001
	var en_prev: Variant = enemy_cur_pos
	enemy_cur_pos = Vector2(float(en_pos[0]), float(en_pos[1])) \
		if (en_visible and en_pos != null) else null
	enemy_moving = consecutive and en_visible and en_prev != null and enemy_cur_pos != null \
		and ((enemy_cur_pos as Vector2) - (en_prev as Vector2)).length() > 0.001
	# R7: a lawful release captured DURING this step (signal before snapshot) survives baseline
	# invalidation when its side/life/occurrence tick matches the permitted current state.
	var keep_own_release := not own_ko and _slot_is_current(slash_slots.get(0, {}), own_life, t)
	var keep_enemy_release := en_visible and not enemy_ko \
		and _slot_is_current(slash_slots.get(1, {}), en_life, t)
	# R5/R6: same-life KO/down invalidates transients; pause/resume handled by host event.
	if not consecutive or own_life != snapshot_own_life or own_ko:
		own_moving = false
		own_prev = null
		if not keep_own_release:
			slash_slots[0] = {}
			callouts[0] = {}
	if not consecutive or not en_visible or en_life != snapshot_enemy_life or enemy_ko:
		enemy_moving = false
		en_prev = null
		if not keep_enemy_release:
			slash_slots[1] = {}
			callouts[1] = {}
	own_prev_pos = own_prev
	enemy_prev_pos = en_prev
	snapshot_own_life = own_life
	snapshot_enemy_life = en_life
	snapshot_prev_tick = prev_tick
	# Performed onsets: only actual transitions captured by the producer. S3: KO/down/terminal
	# suppression dominates acceptance, so a same-boundary onset captured before cut5 cannot
	# recreate text for the down actor or a visibly KO'd enemy.
	var terminal := str(view.get("terminal_category", "")) != ""
	if not own_ko and not terminal:
		var own_onset := str(own.get("performed_onset", ""))
		if own_onset == "active_defense" or own_onset == "defensive_evasion":
			_set_callout(0, "DEF!")
		elif own_onset == "escape":
			_set_callout(0, "RUN!")
	if en_visible and not enemy_ko and not terminal:
		var e_onset := str(en.get("performed_onset", ""))
		if e_onset == "active_defense" or e_onset == "defensive_evasion":
			_set_callout(1, "DEF!")
		elif e_onset == "escape":
			_set_callout(1, "RUN!")
	if own_ko:
		callouts[0] = {}
		slash_slots[0] = {}
	if enemy_ko:
		callouts[1] = {}
		slash_slots[1] = {}
	if terminal:
		callouts = {0: {}, 1: {}}
		slash_slots = {0: {}, 1: {}}
		own_moving = false
		enemy_moving = false
	var lk: Variant = en.get("last_known_position", null)
	if int(en.get("knowledge", 0)) == 1 and lk != null:
		stale_enemy = {"pos": Vector2(float(lk[0]), float(lk[1])), "action": "", "hp": -1, "tick": t}
	else:
		stale_enemy.clear()
	hud_dirty = true
	update()


func _slot_is_current(slot: Variant, life_id: int, tick: int) -> bool:
	if not (slot is Dictionary):
		return false
	var s := slot as Dictionary
	if s.is_empty():
		return false
	return int(s.get("life_id", -1)) == life_id and int(s.get("tick", -1)) == tick


func on_quick_release(side: int, life_id: int, tick: int, x: float, y: float, facing: int) -> void:
	# One replaceable slash slot per side carrying the captured source life AND occurrence tick.
	slash_slots[side] = {"pos": Vector2(x, y), "angle": float(facing) * PI / 2.0,
		"born": active_ms, "life_id": life_id, "tick": tick, "side": side}
	_set_callout(side, "ATK!", life_id, tick)
	hud_dirty = true
	update()


func _set_callout(side: int, text: String, life_id: int = -1, tick: int = -1) -> void:
	callouts[side] = {"text": text, "born": active_ms, "life_id": life_id, "tick": tick}


func _age_callouts() -> void:
	for side in [0, 1]:
		var slot: Dictionary = callouts.get(side, {})
		if slot.is_empty():
			continue
		if active_ms - float(slot.get("born", 0.0)) > 220.0:
			callouts[side] = {}


func _update_result_card() -> void:
	if host == null or result_card == null:
		return
	var ended := bool(host.paused) and str(host.pause_reason) == "encounter_end"
	var cat := str(public_view.get("terminal_category", ""))
	if not ended or cat == "" or cat == "timeout":
		if card_active:
			_hide_result_card()
		return
	if card_active:
		return
	match cat:
		"baby_complete":
			_show_result_card("Baby playtest complete",
				"The diagnostic playtest reached its scheduled end.", "Diagnostic sparring result")
		"aborted":
			_show_result_card("Playtest stopped", "No result.", "Diagnostic sparring result")
		"own_down":
			_show_result_card("Encounter ended", "Your Behemoth is down", "Diagnostic sparring result")
		"enemy_down":
			_show_result_card("Encounter ended", "NPC Behemoth is down", "Diagnostic sparring result")
		"both_down":
			_show_result_card("Encounter ended", "Both Behemoths are down", "Diagnostic sparring result")
		_:
			_show_result_card("Result unavailable",
				"The encounter ended without a consistent result.", "Diagnostic sparring result")


func _show_result_card(title: String, body: String, footer: String) -> void:
	if result_card == null:
		return
	result_title.text = title
	result_body.text = body
	result_footer.text = footer
	result_card.visible = true
	card_active = true
	if restart_button != null:
		if restart_home == null:
			restart_home = restart_button.get_parent()
			restart_home_index = restart_button.get_index()
		var holder := result_card.get_node_or_null("VBox")
		if holder != null and restart_button.get_parent() != holder:
			var old := restart_button.get_parent()
			if old != null:
				old.remove_child(restart_button)
			holder.add_child(restart_button)
		restart_button.text = "Play again"
		restart_button.visible = true
		restart_button.grab_focus()
	hud_dirty = true


func _hide_result_card() -> void:
	if result_card == null:
		return
	result_card.visible = false
	card_active = false
	if restart_button != null:
		if restart_home != null and restart_button.get_parent() != restart_home:
			var old2 := restart_button.get_parent()
			if old2 != null:
				old2.remove_child(restart_button)
			restart_home.add_child(restart_button)
			restart_home.move_child(restart_button, clampi(restart_home_index, 0,
				restart_home.get_child_count() - 1))
		restart_button.text = "Restart"
	hud_dirty = true


func c(key: String) -> Color:
	if grayscale:
		return GRAY[key]
	return COLS[key]


const COLS := {
	"board": COL_BOARD, "ground": COL_GROUND, "blocker": COL_BLOCKER, "edge": COL_EDGE,
	"bone": COL_BONE, "accent": COL_ACCENT, "muted": COL_MUTED, "danger": COL_DANGER,
	"focus": COL_FOCUS, "backing": COL_BACKING, "border": COL_PANEL_BORDER, "stale": COL_STALE,
}


static func luminance(col: Color) -> float:
	return 0.2126 * _lin(col.r) + 0.7152 * _lin(col.g) + 0.0722 * _lin(col.b)


static func _lin(v: float) -> float:
	if v <= 0.03928:
		return v / 12.92
	return pow((v + 0.055) / 1.055, 2.4)


static func contrast_ratio(fg: Color, bg: Color) -> float:
	var a := luminance(fg)
	var b := luminance(bg)
	var hi := maxf(a, b)
	var lo := minf(a, b)
	return (hi + 0.05) / (lo + 0.05)


static func contrast_report() -> Dictionary:
	var pairs := {
		"text_on_backing": [COL_BONE, COL_BACKING],
		"text_on_board": [COL_BONE, COL_BOARD],
		"accent_on_backing": [COL_ACCENT, COL_BACKING],
		"muted_on_backing": [COL_MUTED, COL_BACKING],
		"danger_on_backing": [COL_DANGER, COL_BACKING],
		"focus_vs_backing": [COL_FOCUS, COL_BACKING],
		"focus_vs_board": [COL_FOCUS, COL_BOARD],
		"actor_edge_vs_ground": [COL_BONE, COL_GROUND],
		"blocker_edge_vs_ground": [COL_EDGE, COL_GROUND],
		"button_border_vs_backing": [COL_EDGE, COL_BACKING],
		"empty_text_vs_button_face": [COL_MUTED, Color("232A31")],
		"gray_text_vs_backing": [GRAY["bone"], GRAY["backing"]],
		"gray_muted_vs_backing": [GRAY["muted"], GRAY["backing"]],
		"gray_edge_vs_ground": [GRAY["edge"], GRAY["ground"]],
	}
	var out := {}
	for k in pairs:
		out[k] = snappedf(contrast_ratio(pairs[k][0], pairs[k][1]), 0.01)
	return out


func _process(delta: float) -> void:
	if host == null:
		return
	var running := bool(host.started) and not bool(host.paused)
	if running:
		active_ms += delta * 1000.0
		_age_callouts()
	# R-F04/QA-RES-F04: continuous HUD update and arena redraw only while the run is
	# actually advancing. Paused, end and idle-ready states repaint only on a state
	# change, so input/focus/cue/lifecycle feedback stays responsive without a
	# per-frame redraw of a frozen scene.
	var vs := get_viewport_rect().size
	if vs != last_viewport_size:
		last_viewport_size = vs
		hud_dirty = true
	if not running and not hud_dirty:
		return
	if hud_root != null:
		_update_hud(delta)
		_update_result_card()
	queue_redraw()
	hud_dirty = false


func update() -> void:
	queue_redraw()


func _arena_layout() -> Dictionary:
	var vp := Vector2.ZERO
	var world_root := get_viewport()
	if world_root != null:
		vp = world_root.get_visible_rect().size
	if vp.x <= 0 or vp.y <= 0:
		vp = Vector2(1280, 720)
	var bottom := clampf(vp.y * 0.29, BOTTOM_MIN, BOTTOM_MAX)
	var area := Rect2(0, 0, vp.x, vp.y - bottom)
	var s := minf(area.size.x / 20000.0, area.size.y / 12000.0)
	var arena_size := Vector2(20000.0 * s, 12000.0 * s)
	var origin := Vector2(area.position.x + (area.size.x - arena_size.x) * 0.5,
		area.position.y + (area.size.y - arena_size.y) * 0.5)
	return {"scale": s, "origin": origin, "area": area, "bottom": bottom, "view": vp}


static func world_to_screen(p: Vector2, layout: Dictionary) -> Vector2:
	return layout["origin"] + p * layout["scale"]


func _draw() -> void:
	if host == null or not ("sim" in host) or host.sim == null:
		return
	if not bool(host.started):
		return
	var layout := _arena_layout()
	var s := float(layout["scale"])
	var org: Vector2 = layout["origin"]

	draw_rect(Rect2(Vector2.ZERO, layout["view"]), c("board"), true)
	draw_rect(Rect2(org, Vector2(20000.0, 12000.0) * s), c("ground"), true)

	var arena = host.arena
	var blocker: Array = arena.original_blocker()
	var bpos := org + Vector2(float(blocker[0]), float(blocker[1])) * s
	var bsize := Vector2(float(blocker[2]) - float(blocker[0]),
		float(blocker[3]) - float(blocker[1])) * s
	draw_rect(Rect2(bpos, bsize), c("blocker"), true)
	draw_rect(Rect2(bpos, bsize), c("edge"), false, 2.0)

	if not _is_expanded():
		_draw_owner_marks(org, s)
	_draw_stale_mark(org, s)
	if _is_expanded():
		_draw_nests(org, s)
		_draw_prey(org, s)
	else:
		_draw_legal_footprints(org, s)
	_draw_actor(org, s, 0)
	_draw_enemy_actor(org, s)
	_draw_marks(org, s)
	_draw_callouts(org, s)


func _draw_owner_marks(org: Vector2, s: float) -> void:
	var spawns: Array = host.arena.spawn
	for i in 2:
		var p := org + Vector2(float(spawns[i][0]), float(spawns[i][1])) * s
		var col := c("bone") if i == 0 else c("accent")
		if i == 0:
			var a := p + Vector2(0, -16)
			var b := p + Vector2(-13, 8)
			var cc := p + Vector2(13, 8)
			draw_colored_polygon(PackedVector2Array([a, b, cc]), col)
		else:
			draw_rect(Rect2(p + Vector2(-11, -11), Vector2(22, 22)), col, false, 3.0)


func _draw_stale_mark(org: Vector2, s: float) -> void:
	if stale_enemy.is_empty():
		return
	var pos: Vector2 = stale_enemy["pos"]
	var p := org + pos * s
	var col := c("stale")
	draw_arc(p, 14.0, 0, TAU, 24, col, 2.0)
	draw_line(p + Vector2(-9, -9), p + Vector2(9, 9), col, 2.0)
	draw_line(p + Vector2(9, -9), p + Vector2(-9, 9), col, 2.0)


func _draw_legal_footprints(org: Vector2, s: float) -> void:
	for i in 2:
		var a: Dictionary = host.sim.actors[i]
		if bool(a["bound_active"]):
			var path: Array = a["bound_path"]
			if path.size() >= 2:
				var pts := PackedVector2Array()
				for w in path:
					pts.append(org + Vector2(float(w[0]), float(w[1])) * s)
				draw_polyline(pts, c("accent"), 3.0)
			var prog := float(a["bound_progress"])
			var total := maxf(float(a["bound_total"]), 0.001)
			var pos := org + Vector2(float(a["x"]), float(a["y"])) * s
			draw_arc(pos, 16.0 + 40.0 * s, 0, TAU * clampf(prog / total, 0, 1), 28,
				c("accent"), 3.0)


func _draw_marks(org: Vector2, s: float) -> void:
	var now := active_ms
	contact_marks = contact_marks.filter(func(m): return now - float(m["born"]) < 260.0)
	# S3: down/KO suppression applies to text-only slots too (a movement onset has no slash).
	var own_v0: Dictionary = public_view.get("own", {})
	var own_down0 := str(own_v0.get("status", "")) in ["down", "waiting_return"] \
		or str(own_v0.get("action", "")) == "ko"
	var enemy_ko0 := str(public_view.get("enemy", {}).get("action", "")) == "ko" \
		and int(public_view.get("enemy", {}).get("knowledge", 0)) == 2
	if own_down0:
		callouts[0] = {}
		slash_slots[0] = {}
	if enemy_ko0:
		callouts[1] = {}
		slash_slots[1] = {}
	# C09/C11: one replaceable slash slot per side, keyed by captured source life; a hidden or
	# dead-life release is suppressed. Reduced motion draws a fixed silhouette for the same
	# bounded active lifetime (no reach/alpha animation).
	for side in [0, 1]:
		var m: Dictionary = slash_slots.get(side, {})
		if m.is_empty():
			continue
		if now - float(m.get("born", 0.0)) >= 220.0:
			slash_slots[side] = {}
			continue
		var cur_life := snapshot_own_life if side == 0 else snapshot_enemy_life
		if int(m.get("life_id", -1)) != cur_life or cur_life < 0:
			slash_slots[side] = {}
			continue
		if side == 1 and int(public_view.get("enemy", {}).get("knowledge", 0)) != 2:
			slash_slots[side] = {}
			continue
		# R5: an actual same-life KO/down suppresses the transient immediately.
		var own_v: Dictionary = public_view.get("own", {})
		if side == 0 and (str(own_v.get("status", "")) in ["down", "waiting_return"] \
				or str(own_v.get("action", "")) == "ko"):
			slash_slots[side] = {}
			callouts[side] = {}
			continue
		if side == 1 and str(public_view.get("enemy", {}).get("action", "")) == "ko":
			slash_slots[side] = {}
			callouts[side] = {}
			continue
		var p := org + (m["pos"] as Vector2) * s
		var ang := float(m["angle"])
		var arc := PackedVector2Array()
		if reduced_motion:
			for k in 7:
				var t2 := ang - 0.7 + 1.4 * float(k) / 6.0
				arc.append(p + Vector2(cos(t2), sin(t2)) * 46.0)
			draw_polyline(arc, c("bone"), 4.0)
		else:
			var age := clampf((now - float(m["born"])) / 220.0, 0.0, 1.0)
			var reach := 46.0 * (0.5 + 0.5 * age)
			for k in 7:
				var t := ang - 0.7 + 1.4 * float(k) / 6.0
				arc.append(p + Vector2(cos(t), sin(t)) * reach)
			draw_polyline(arc, Color(c("bone"), 1.0 - age), 4.0)
	for m in contact_marks:
		var age2 := clampf((now - float(m["born"])) / 260.0, 0.0, 1.0)
		var p2 := org + (m["pos"] as Vector2) * s
		var r := 18.0 + 8.0 * age2
		draw_rect(Rect2(p2 - Vector2(r, r) * 0.5, Vector2(r, r)), Color(c("accent"), 1.0 - age2),
			false, 3.0)


## Primitive prey silhouettes from the copied visible samples only. No hidden positions.
func _draw_prey(org: Vector2, s: float) -> void:
	for rec in (public_view.get("prey", []) as Array):
		var p := org + Vector2(float(rec["x"]), float(rec["y"])) * s
		var r := 250.0 * s
		var body := c("bone")
		var moving := bool(rec.get("moving", false))
		draw_circle(p, maxf(r, 3.0), body)
		draw_circle(p + Vector2(r * 0.9, -r * 0.2), maxf(r * 0.45, 2.0), body)
		draw_arc(p, maxf(r, 3.0), 0.0, TAU, 20, c("edge"), 1.5)
		var leg := r * 0.5 if moving else r * 0.35
		draw_line(p + Vector2(-r * 0.35, r * 0.6), p + Vector2(-r * 0.35, r * 0.6 + leg),
			c("edge"), 2.0)
		draw_line(p + Vector2(r * 0.35, r * 0.6), p + Vector2(r * 0.35, r * 0.6 + leg),
			c("edge"), 2.0)


## Two reusable Nest bases with a non-color ownership shape, drawn from the copied layout.
func _draw_nests(org: Vector2, s: float) -> void:
	for n in (public_view.get("nests", []) as Array):
		var p := org + Vector2(float(n["x"]), float(n["y"])) * s
		var rad := float(n["radius"]) * s
		draw_arc(p, maxf(rad, 4.0), 0.0, TAU, 36, c("edge"), 2.0)
		var col := c("bone") if int(n["side"]) == 0 else c("accent")
		if int(n["side"]) == 0:
			draw_colored_polygon(PackedVector2Array([p + Vector2(0, -10), p + Vector2(-9, 6),
				p + Vector2(9, 6)]), col)
		else:
			draw_rect(Rect2(p + Vector2(-8, -8), Vector2(16, 16)), col, false, 3.0)


## Two replaceable actor-relative text slots, aged by active unpaused presentation time.
func _draw_callouts(org: Vector2, s: float) -> void:
	var font := ThemeDB.fallback_font
	for side in [0, 1]:
		var slot: Dictionary = callouts.get(side, {})
		if slot.is_empty():
			continue
		var p: Variant = null
		if side == 0:
			p = public_view.get("own", {}).get("position", null)
		else:
			if int(public_view.get("enemy", {}).get("knowledge", 0)) != 2:
				continue
			p = public_view.get("enemy", {}).get("position", null)
		if p == null:
			continue
		var sp := org + Vector2(float(p[0]), float(p[1])) * s
		var text := str(slot.get("text", ""))
		if text == "":
			continue
		var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
		var pos := sp + Vector2(24.0, -58.0)
		var view := get_viewport_rect().size
		pos.x = clampf(pos.x, 4.0, maxf(4.0, view.x - size.x - 8.0))
		pos.y = clampf(pos.y, 20.0, maxf(20.0, view.y - 8.0))
		draw_rect(Rect2(pos + Vector2(-3, -15), size + Vector2(6, 6)), c("backing"), true)
		draw_rect(Rect2(pos + Vector2(-3, -15), size + Vector2(6, 6)), c("edge"), false, 1.0)
		draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, c("bone"))


func _pose_for(i: int) -> String:
	if forced_pose.has(i) and forced_pose_ticks > 0:
		return str(forced_pose[i])
	var a: Dictionary = host.sim.actors[i]
	if not bool(a["alive"]):
		return "P12"
	if int(a["lock_end"]) > int(host.sim.tick):
		return "P11"
	var pub := str(a["public_action"])
	match pub:
		"bracing":
			return "P08"
		"preparing_brace":
			return "P07"
		"preparing_bound", "bound":
			return "P09" if pub == "preparing_bound" else "P10"
		"claw":
			return "P06"
		"searching":
			return "P04"
		"exhausted":
			return "P11"
		"acting_alone":
			return "P13"
	if i == 0 and not host.sim.human_feedback.is_empty():
		var head: Dictionary = host.sim.human_feedback[host.sim.human_feedback.size() - 1]
		if int(head.get("tick", -1)) == int(host.sim.tick):
			if str(head.get("cue", "")) == "Declined":
				return "P05"
			if str(head.get("cue", "")).begins_with("Understood"):
				return "P04"
	if bool(a["moved_this_boundary"]):
		walk_phase += 0.5
		return "P02" if int(walk_phase) % 2 == 0 else "P03"
	return "P01"


func _draw_actor(org: Vector2, s: float, i: int) -> void:
	var a: Dictionary = host.sim.actors[i]
	var pos := Vector2(float(a["x"]), float(a["y"]))
	if _is_expanded() and i == 0:
		var own: Dictionary = public_view.get("own", {})
		var op: Variant = own.get("position", null)
		if op != null:
			pos = Vector2(float(op[0]), float(op[1]))
		if own_moving and own_prev_pos != null:
			_draw_strokes(org, s, pos, own_prev_pos)
		_draw_puppet(org + pos * s, int(own.get("facing", 0)), _pose_for(0), s, 0)
		if str(own.get("action", "")) == "bracing":
			_draw_guard(org + pos * s, s)
		return
	_draw_puppet(org + pos * s, int(a["facing"]), _pose_for(i), s, i)


## Two short paper motion strokes behind measured displacement; none when stationary.
## C11: reduced motion suppresses movement strokes entirely.
func _draw_strokes(org: Vector2, s: float, cur: Vector2, prev: Vector2) -> void:
	if reduced_motion:
		return
	var d := cur - prev
	if d.length() < 0.001:
		return
	var dir := d.normalized()
	var side := Vector2(-dir.y, dir.x)
	var base := org + prev * s
	for k in 2:
		var off := base - dir * (10.0 + 8.0 * k) + side * (6.0 if k == 0 else -6.0)
		draw_line(off - side * 6.0, off + side * 6.0, c("muted"), 2.0)


## Static open angular guard bracket, no filled shield.
func _draw_guard(sp: Vector2, s: float) -> void:
	var r := 40.0 + 10.0 * s
	draw_line(sp + Vector2(-r, -r * 0.5), sp + Vector2(-r, r * 0.6), c("bone"), 3.0)
	draw_line(sp + Vector2(r, -r * 0.5), sp + Vector2(r, r * 0.6), c("bone"), 3.0)


func _draw_enemy_actor(org: Vector2, s: float) -> void:
	if _is_expanded():
		var e: Dictionary = public_view.get("enemy", {})
		if int(e.get("knowledge", 0)) != 2:
			return
		var posv: Variant = e.get("position", null)
		if posv == null:
			return
		var ep2 := Vector2(float(posv[0]), float(posv[1]))
		if enemy_moving and enemy_prev_pos != null:
			_draw_strokes(org, s, ep2, enemy_prev_pos)
		var pp := _pose_enemy(str(e.get("action", "")))
		_draw_puppet(org + ep2 * s, 2, pp, s, 1, false)
		if str(e.get("action", "")) == "bracing":
			_draw_guard(org + ep2 * s, s)
		return
	var obs: Dictionary = host.sim.observe_for(0)
	var cues: Dictionary = obs["enemy"]
	var k := int(cues.get("knowledge", 0))
	if k >= 1:
		var arr: Array = cues.get("position", [])
		var pos := Vector2(float(arr[0]), float(arr[1])) if arr.size() == 2 else Vector2.ZERO
		stale_enemy = {"pos": pos, "action": str(cues.get("action_archetype", "")),
			"hp": int(cues.get("hp_band", -1)), "tick": int(cues.get("last_seen_tick", -1))}
		last_enemy_knowledge = k
	elif last_enemy_knowledge == 1 and k == 0:
		stale_enemy.clear()
		last_enemy_knowledge = 0
	if k == 0 and stale_enemy.is_empty():
		return
	if stale_enemy.is_empty():
		return
	var ep: Vector2 = stale_enemy["pos"]
	var pose := "P01"
	if k == 2:
		pose = _pose_enemy(str(cues.get("action_archetype", "")))
	else:
		pose = "P01"
	_draw_puppet(org + ep * s, 2, pose, s, 1, k != 2)


func _pose_enemy(pub: String) -> String:
	match pub:
		"bracing":
			return "P08"
		"preparing_brace":
			return "P07"
		"preparing_bound":
			return "P09"
		"bound":
			return "P10"
		"claw":
			return "P06"
		"searching":
			return "P04"
		"exhausted":
			return "P11"
		"ko":
			return "P12"
	return "P01"


func _draw_puppet(screen_pos: Vector2, facing: int, pose: String, s: float, side: int,
		stale: bool = false) -> void:
	var params: Dictionary = POSE_PARAMS.get(pose, POSE_PARAMS["P01"])
	var a: Dictionary = host.sim.actors[side]
	var collision_dia := 2.0 * float(a["radius"]) * s
	var silhouette := clampf(collision_dia * 1.6, 64.0, 80.0)
	var unit := silhouette / 100.0

	var bob := 0.0
	if not reduced_motion and not stale and pose in ["P02", "P03"]:
		bob = 3.0
	var base := screen_pos + Vector2(0, -bob)

	var body_col := c("bone") if side == 0 else c("accent")
	if stale:
		body_col = Color(body_col, 0.55)

	var lean := deg_to_rad(float(params["lean"]))
	var head_off := deg_to_rad(float(params["head"]))
	var crouch := float(params["crouch"])
	var droop := float(params["droop"])

	draw_set_transform(base, 0.0, Vector2.ONE)

	# contact shadow (ground support primitive)
	draw_set_transform(base + Vector2(0, 6.0 * unit), 0.0, Vector2.ONE)
	draw_set_transform(base, 0.0, Vector2.ONE)

	var body_h := 46.0 * unit * (1.0 - 0.3 * crouch)
	var body_w := 44.0 * unit
	var top := -body_h - 10.0 * unit * crouch

	# legs
	var leg_lift := float(params["leg"])
	for side_sign in [-1.0, 1.0]:
		var hip := Vector2(side_sign * 14.0 * unit, top + body_h)
		var foot := hip + Vector2(side_sign * 8.0 * unit + deg_to_rad(leg_lift) * 18.0 * unit * side_sign,
			24.0 * unit - 6.0 * unit * absf(leg_lift) / 30.0)
		foot = hip + Vector2(side_sign * (9.0 + leg_lift * 0.18) * unit,
			(22.0 - absf(leg_lift) * 0.16) * unit)
		draw_line(hip, foot, body_col, 7.0 * unit)
		draw_circle(foot + Vector2(0, 2.0 * unit), 5.0 * unit, body_col)

	# torso (inscribed core body stays within authored collision circle)
	var torso_top := top + 6.0 * unit
	var torso := Rect2(Vector2(-body_w * 0.5, torso_top), Vector2(body_w, body_h - 6.0 * unit))
	_lean_draw(torso, lean, body_col)

	# arms
	var arm_ang := deg_to_rad(float(params["arm"]))
	for side_sign in [-1.0, 1.0]:
		var sh := Vector2(side_sign * body_w * 0.5, torso_top + 10.0 * unit)
		var ang: float = arm_ang * side_sign
		var hand := sh + Vector2(sin(ang) * 30.0 * unit * side_sign,
			cos(ang) * 26.0 * unit * (1.0 + 0.2 * droop))
		draw_line(sh, hand, body_col, 6.0 * unit)
		draw_circle(hand, 5.0 * unit * (1.5 if pose == "P06" and side_sign == 1.0 else 1.0),
			body_col)

	# head + oversized horns
	var head_r := 20.0 * unit
	var head_c := Vector2(0, torso_top - head_r * 0.7)
	rotate_point(head_c, lean)
	head_c += Vector2(sin(head_off) * 10.0 * unit, -absf(head_off) * 4.0 * unit)
	rotate_point(head_c, lean)
	draw_circle(head_c, head_r, body_col)
	var horn_col := c("bone")
	for side_sign in [-1.0, 1.0]:
		var hroot := head_c + Vector2(side_sign * head_r * 0.62, -head_r * 0.55)
		var htip := hroot + Vector2(side_sign * 16.0 * unit,
			-26.0 * unit * (1.0 - 0.3 * droop))
		var hmid := hroot + Vector2(side_sign * 5.0 * unit, -6.0 * unit)
		draw_colored_polygon(PackedVector2Array([hroot, htip, hmid]), horn_col)

	# eyes / facing cue
	var show_eyes := facing == 2
	var show_profile := facing == 1 or facing == 3
	if show_eyes or show_profile:
		var dir := 1.0 if facing != 1 else -1.0
		if facing == 1 or facing == 3:
			dir = 1.0 if facing == 1 else -1.0
		var eye_col := c("backing")
		if facing == 2:
			draw_circle(head_c + Vector2(-6.0 * unit, -1.0 * unit), 4.2 * unit, eye_col)
			draw_circle(head_c + Vector2(6.0 * unit, -1.0 * unit), 4.2 * unit, eye_col)
			draw_circle(head_c + Vector2(-4.6 * unit, -2.4 * unit), 1.6 * unit, c("bone"))
			draw_circle(head_c + Vector2(7.4 * unit, -2.4 * unit), 1.6 * unit, c("bone"))
		else:
			draw_circle(head_c + Vector2(dir * 6.0 * unit, -1.0 * unit), 4.2 * unit, eye_col)
			draw_circle(head_c + Vector2(dir * 7.4 * unit, -2.4 * unit), 1.6 * unit, c("bone"))
	else:
		var seam := head_c + Vector2(0, -head_r * 0.2)
		draw_arc(seam, head_r * 0.6, 0.6, PI - 0.6, 12, Color(c("edge"), 0.7), 2.0)

	# 2px+ identity edge around the whole silhouette
	draw_circle(head_c, head_r, Color(body_col, 1.0), false)
	draw_arc(head_c, head_r, 0, TAU, 32, c("edge"), 2.0)
	_draw_outline(torso, lean, c("edge"))

	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_outline(r: Rect2, lean: float, col: Color) -> void:
	var pts := PackedVector2Array([
		r.position, r.position + Vector2(r.size.x, 0),
		r.position + r.size, r.position + Vector2(0, r.size.y),
	])
	var out := PackedVector2Array()
	for p in pts:
		var q := p - Vector2(0, -r.size.y * 0.5)
		q = Vector2(q.x * cos(lean) - q.y * sin(lean), q.x * sin(lean) + q.y * cos(lean))
		q += Vector2(0, -r.size.y * 0.5)
		out.append(q)
	draw_polyline(out + PackedVector2Array([out[0]]), col, 2.0)


func _lean_draw(r: Rect2, lean: float, col: Color) -> void:
	var pts := PackedVector2Array([
		r.position, r.position + Vector2(r.size.x, 0),
		r.position + r.size, r.position + Vector2(0, r.size.y),
	])
	var out := PackedVector2Array()
	for p in pts:
		var q := p - Vector2(0, -r.size.y * 0.5)
		q = Vector2(q.x * cos(lean) - q.y * sin(lean), q.x * sin(lean) + q.y * cos(lean))
		q += Vector2(0, -r.size.y * 0.5)
		out.append(q)
	draw_colored_polygon(out, col)


func rotate_point(p: Vector2, lean: float) -> Vector2:
	return p


func register_swipe(pos: Vector2, angle: float) -> void:
	swipe_marks.append({"pos": pos, "angle": angle, "born": Time.get_ticks_msec()})


func register_contact(pos: Vector2) -> void:
	contact_marks.append({"pos": pos, "born": Time.get_ticks_msec()})


func _update_hud(delta: float) -> void:
	if hud_root == null or host == null:
		return
	time_accum += delta
	if forced_pose_ticks > 0:
		forced_pose_ticks -= 1
	_apply_text_scale()
	_update_lifecycle_labels()
	_update_start_button()
	if not ("sim" in host) or host.sim == null:
		return
	_update_own_state()
	_update_enemy_state()
	_update_cue()
	_update_record()
	_update_slots()
	_update_toolbar()


func _apply_text_scale() -> void:
	pass


func _base_size() -> int:
	return maxi(16, int(round(16.0 * text_scale)))


func _update_lifecycle_labels() -> void:
	if status_label == null:
		return
	var sz := _base_size()
	status_label.add_theme_font_size_override("font_size", sz)
	loading_label.add_theme_font_size_override("font_size", sz)
	download_status_label.add_theme_font_size_override("font_size", sz)
	if str(host.content_error) != "":
		loading_label.text = "Could not load sparring encounter content. Check Game/M01/content/*.json."
		loading_label.add_theme_color_override("font_color", c("danger"))
		return
	if not bool(host.started):
		loading_label.text = "Ready · press Start encounter to begin"
		loading_label.add_theme_color_override("font_color", c("accent"))
		return
	if host.paused and str(host.pause_reason) == "encounter_end":
		loading_label.text = "Diagnostic playtest ended." if _is_expanded() \
			else "Diagnostic encounter complete. Restart to run another."
		loading_label.add_theme_color_override("font_color", c("accent"))
		return
	if host.paused:
		loading_label.text = "Send requests; your monster decides how to act"
		loading_label.add_theme_color_override("font_color", c("muted"))
		return
	if _is_expanded() and not public_view.is_empty():
		var own: Dictionary = public_view.get("own", {})
		var st := str(own.get("status", "alive"))
		var now_t := int(public_view.get("tick", -1))
		var msg := "Send requests; your monster decides how to act"
		var col := c("muted")
		if st == "down":
			msg = "Your monster is down — returning to your Nest"
			col = c("danger")
		elif st == "waiting_return":
			msg = "Waiting for a clear return point"
			col = c("danger")
		elif int(own.get("return_tick", -1)) >= 0 and now_t - int(own["return_tick"]) <= 13:
			msg = "Returned to Nest"
			col = c("accent")
		elif int(own.get("growth_tick", -1)) >= 0 and now_t - int(own["growth_tick"]) <= 13:
			msg = "Hunt growth gained"
			col = c("accent")
		loading_label.text = msg
		loading_label.add_theme_color_override("font_color", col)
		return
	loading_label.text = "Send requests; your monster decides how to act"
	loading_label.add_theme_color_override("font_color", c("muted"))
	download_status_label.text = str(host.download_message)


func _update_own_state() -> void:
	var a: Dictionary = host.sim.actors[0]
	var labels := M01Observations.own_state_labels(a)
	labels["tick"] = int(host.sim.tick)
	var sz := _base_size()
	own_labels.add_theme_font_size_override("font_size", sz)
	var action := str(a["public_action"])
	var action_text := _action_text(action)
	own_labels.text = "%s · HP %s · STAM %s · Fatigue %s · Monster now: %s" % [
		str(labels["emotion"]), str(labels["hp_label"]), str(labels["stam_label"]),
		str(labels["fatigue_label"]), action_text]
	own_labels.add_theme_color_override("font_color", c("bone"))
	own_labels.tooltip_text = ""

	cue_label.add_theme_font_size_override("font_size", sz)
	cue_label.add_theme_color_override("font_color", c("accent"))
	var lock_text := ""
	if int(a["control_mode"]) != 0:
		lock_text = "Diagnostic: %s lock · Trainer commands locked; monster acts alone" % (
			"normal Demigod" if int(a["control_mode"]) == 1 else "Doomsday")
	lock_banner.visible = lock_text != ""
	lock_banner.add_theme_font_size_override("font_size", sz)
	lock_banner.add_theme_color_override("font_color", c("danger"))
	lock_banner.text = lock_text


func _action_text(action: String) -> String:
	match action:
		"bracing":
			return "Bracing"
		"preparing_brace":
			return "Preparing Brace"
		"preparing_bound":
			return "Preparing Short Bound"
		"bound":
			return "Short Bound"
		"claw":
			return "Quick Claw"
		"searching":
			return "Searching"
		"exhausted":
			return "Exhausted"
		"acting_alone":
			return "Acting alone"
		"ko":
			return "Down"
	return "Calm wait"


func _update_enemy_state() -> void:
	enemy_label.add_theme_font_size_override("font_size", _base_size())
	enemy_label.add_theme_color_override("font_color", c("bone"))
	var k := 0
	var arch := ""
	var last_seen := -1
	var hp_band := -1
	if _is_expanded() and not public_view.is_empty():
		var e: Dictionary = public_view.get("enemy", {})
		k = int(e.get("knowledge", 0))
		arch = str(e.get("action", ""))
		last_seen = int(e.get("last_seen_tick", -1))
		hp_band = int(e.get("hp_band", -1))
	else:
		var obs: Dictionary = host.sim.observe_for(0)
		var cues: Dictionary = obs["enemy"]
		k = int(cues.get("knowledge", 0))
		arch = str(cues.get("action_archetype", ""))
		last_seen = int(cues.get("last_seen_tick", -1))
		hp_band = int(cues.get("hp_band", -1))
	var text := ""
	if k == 2:
		text = "NPC: Visible · %s · %s" % [
			M01Observations.hp_label(hp_band if hp_band >= 0 else 4),
			_action_text(arch) if arch != "" else "observing"]
	elif k == 1:
		text = "NPC: Last Known · stale (froze at tick %d)" % last_seen
	else:
		text = "NPC: Unknown"
	enemy_label.text = text
	if k == 1:
		enemy_label.add_theme_color_override("font_color", c("stale"))
	else:
		enemy_label.add_theme_color_override("font_color", c("bone"))


func _update_cue() -> void:
	var rec: Array = host.sim.human_feedback
	# COMMAND-FEEDBACK01: scan EVERY retained entry in append order; each receipt/response
	# replaces the request-row candidate, action/Hit/Miss/end never compete for it. The last
	# eligible entry wins and is persisted in the two retained scalars, so an unchanged
	# snapshot re-applies idempotently and an empty history keeps the previous observation.
	var rid := 0
	for e in rec:
		var kind := str(e.get("kind", ""))
		if kind != "receipt" and kind != "response":
			continue
		retained_request_text = _entry_text(e)
		retained_request_kind = kind
		rid = int(e.get("request", 0))
	# Priority: actual endpoint/own Down removes pending-looking claims, then the current
	# authority lock, then the retained request/response row.
	var own: Dictionary = host.sim.actors[0]
	var ended := bool(host.paused) and str(host.pause_reason) == "encounter_end"
	var own_down := str(own.get("public_action", "")) == "ko"
	var end_text := ""
	for e in rec:
		if str(e.get("kind", "")) == "end":
			end_text = _entry_text(e)
	var shown := retained_request_text
	var shown_kind := retained_request_kind
	if ended or own_down:
		shown = (end_text if end_text != "" else "Diagnostic encounter complete")
		shown_kind = "end"
	elif int(own.get("control_mode", 0)) != 0:
		shown = "Trainer commands locked"
		shown_kind = ""
	var key := "%s|%s" % [shown_kind, shown]
	if key != last_cue_text:
		last_cue_text = key
		cue_label.text = shown
	# Colour is re-applied on every update, not only when the text changes: _update_own_state
	# runs first and reasserts the accent colour on this same label each frame.
	if shown_kind == "receipt":
		cue_label.add_theme_color_override("font_color", c("muted"))
	elif shown_kind == "response":
		cue_label.add_theme_color_override("font_color", c("accent"))
	elif shown_kind == "end":
		cue_label.add_theme_color_override("font_color", c("danger"))
	else:
		cue_label.add_theme_color_override("font_color", c("bone"))
	# Latency hooks stay observational: they retire a genuine request probe once and never
	# consume feedback or influence selection above.
	if rid > 0 and pending_probes.has(rid):
		var probe := int(pending_probes[rid])
		var now := Time.get_ticks_usec()
		cue_latency_samples.append(float(now - probe) / 1000.0)
		if cue_latency_samples.size() > 200:
			cue_latency_samples.pop_front()
		pending_probes.erase(rid)
	_measure_cue_latency_now()


var latency_probe_request := 0
var latency_probe_mono := 0


func _measure_cue_latency_now() -> void:
	if latency_probe_request <= 0:
		return
	var rid := latency_probe_request
	if host.sim.human_feedback.is_empty():
		return
	var found := false
	for e in host.sim.human_feedback:
		if int(e.get("request", 0)) == rid:
			found = true
			break
	if not found:
		return
	var now := Time.get_ticks_usec()
	cue_latency_samples.append(float(now - latency_probe_mono) / 1000.0)
	if cue_latency_samples.size() > 200:
		cue_latency_samples.pop_front()
	latency_probe_request = 0


func note_request_receipt(request_id: int, mono_usec: int) -> void:
	if request_id <= 0:
		return
	pending_probes[request_id] = mono_usec
	latency_probe_request = request_id
	latency_probe_mono = mono_usec


func _update_record() -> void:
	var rec: Array = host.sim.human_feedback
	var sz := maxi(14, int(round(16.0 * text_scale)))
	# COMMAND-FEEDBACK01: rebuild every retained row from the current entries, oldest to
	# newest, on each HUD update. The old size/head/tick signature skipped the rebuild when
	# the head row was unchanged even though earlier rows had changed, so it is no longer the
	# correctness gate; six formatting operations per update, no growing storage.
	var head := ""
	if not rec.is_empty():
		var h: Dictionary = rec[rec.size() - 1]
		head = "%d|%s" % [int(h.get("tick", 0)), str(h.get("cue", ""))]
	last_record_size = rec.size()
	last_record_head = "%d|%s|%d" % [rec.size(), head, text_scale]
	for i in 6:
		var lbl: Label = record_labels[i]
		lbl.add_theme_font_size_override("font_size", sz)
		if i < rec.size():
			var e: Dictionary = rec[i]
			lbl.text = _record_text(e)
			lbl.visible = true
			lbl.add_theme_color_override("font_color", _record_color(str(e.get("kind", ""))))
		else:
			lbl.text = ""
			lbl.visible = true


func _record_text(e: Dictionary) -> String:
	return "[%04d] %s" % [int(e.get("tick", 0)), _entry_text(e)]


# COMMAND-FEEDBACK01: one safe formatter shared by the request row and every history row.
# kind is the authoritative display category; family is display metadata only and an
# unknown/missing family is never defaulted to Attack.
func _entry_text(e: Dictionary) -> String:
	var kind := str(e.get("kind", ""))
	var cue := str(e.get("cue", ""))
	var raw_detail := str(e.get("detail", ""))
	var detail := _safe_detail(raw_detail)
	if kind == "receipt" and raw_detail == "Awaiting response":
		detail = raw_detail
	elif kind == "end" and raw_detail == "mutual KO":
		detail = raw_detail
	var text := cue
	if kind == "response":
		var family_labels := {1: "Attack", 2: "Defense", 3: "Run"}
		var fam := str(family_labels.get(int(e.get("family", 0)), ""))
		if cue.begins_with("Interpreted as"):
			text = ("%s requested · %s" % [fam, cue]) if fam != "" else cue
		elif not cue.begins_with("Understood:") and fam != "":
			text = "%s · %s" % [fam, cue]
	elif kind == "action":
		text = "Monster: %s" % cue
	if detail != "":
		text += " · " + detail
	return text


# Whitelisted safe details only; empty/unknown/internal reasons are omitted, never printed.
func _safe_detail(detail: String) -> String:
	match detail:
		"finishing_current_action":
			return "Finishing current action"
		"exhausted", "start_exhaustion":
			return "Exhausted"
		"technique_unavailable":
			return "Technique unavailable"
		"target_lost":
			return "Target lost"
		"authority_locked":
			return "Trainer commands locked"
		"intent_change":
			return "Request changed"
	return ""


func _record_color(kind: String) -> Color:
	match kind:
		"receipt":
			return c("muted")
		"response":
			return c("accent")
		"end":
			return c("danger")
	return c("bone")


func _update_slots() -> void:
	var a: Dictionary = host.sim.actors[0]
	var sz := maxi(15, int(round(16.0 * text_scale)))
	var now := Time.get_ticks_msec()
	for i in 8:
		var b: Button = slot_buttons[i]
		b.add_theme_font_size_override("font_size", sz)
		var label := str(a["slot_labels"][i])
		var key := ""
		if i < 3:
			key = str(i + 1)
		var base_label := ("%s %s" % [key, label]) if key != "" else label
		if slot_flash.has(i) and now - int(slot_flash[i]) < 180:
			b.add_theme_color_override("font_color", c("focus"))
		else:
			b.remove_theme_color_override("font_color")
		b.text = base_label
		var locked := int(a["control_mode"]) != 0 or bool(host.paused) or not bool(host.started)
		# PREVIEW01: Empty slots 4-8 are never actionable, so keep them disabled in every
		# lock/unlock state; only Attack/Defense/Run follow the legal control state.
		b.disabled = locked or i >= 3
		var actionable := not b.disabled
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if actionable else Control.CURSOR_ARROW
		if not actionable:
			b.add_theme_color_override("font_color", c("muted"))
		else:
			b.remove_theme_color_override("font_color")


func _update_toolbar() -> void:
	var sz := maxi(15, int(round(16.0 * text_scale)))
	for n in [start_button, resume_button, restart_button, download_button, text_scale_button,
			grayscale_button, motion_button, status_label]:
		if n != null:
			n.add_theme_font_size_override("font_size", sz)
	# R-F04/QA-RES-F04: Start/resume/restart/download visibility comes from
	# _update_start_button(), which already ran before the sim guard.
	resume_button.disabled = not bool(host.resume_required) and str(host.pause_reason) == "visibility"
	status_label.text = "Tick %d" % (int(host.sim.tick) if host.sim != null else 0)
	status_label.add_theme_color_override("font_color", c("muted"))


## R-F04/QA-RES-F04: runs before the sim guard so Start is truthful even when
## content failed to load and no simulation object exists.
func _update_start_button() -> void:
	if start_button == null:
		return
	var can_start := not bool(host.started) and str(host.content_error) == ""
	start_button.visible = not bool(host.started)
	start_button.disabled = not can_start
	start_button.tooltip_text = "" if can_start else "Encounter content failed to load."
	if resume_button != null:
		resume_button.visible = bool(host.started) and bool(host.paused) \
				and str(host.pause_reason) != "encounter_end"
	if restart_button != null:
		restart_button.visible = bool(host.started)
	if download_button != null:
		# PREVIEW01: the evidence Download control bridges to a web-only download; on
		# native it is suppressed with an honest explanation instead of inviting an
		# unavailable path. Browser visibility and the host bridge guard are unchanged.
		var web := OS.has_feature("web")
		download_button.visible = bool(host.started) and web
		download_button.disabled = not web
		download_button.tooltip_text = "" if web else \
				"Evidence download is web-only; native evidence is the supervisor console."


func set_slot_flash(index: int) -> void:
	slot_flash[index] = Time.get_ticks_msec()
	hud_dirty = true
	update()


func force_pose(index: int, pose: String, ticks: int) -> void:
	forced_pose[index] = pose
	forced_pose_ticks = ticks
	hud_dirty = true
	update()


func _build_hud() -> void:
	var font_size := 16
	hud_root.custom_minimum_size = Vector2(0, BOTTOM_MAX)
	hud_root.anchor_right = 1.0
	hud_root.anchor_top = 1.0
	hud_root.anchor_bottom = 1.0
	hud_root.offset_top = -BOTTOM_MAX
	hud_root.offset_bottom = 0
	hud_root.mouse_filter = Control.MOUSE_FILTER_STOP

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	hud_root.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = COL_BACKING
	style.border_color = COL_PANEL_BORDER
	style.set_border_width_all(2)
	style.set_corner_radius_all(0)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.name = "Rows"
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var state_row := HBoxContainer.new()
	state_row.name = "StateRow"
	state_row.add_theme_constant_override("separation", 16)
	vbox.add_child(state_row)

	own_labels = Label.new()
	own_labels.name = "OwnState"
	own_labels.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	own_labels.text = "Calm · HP Healthy · STAM High · Fatigue Fresh · Monster now: Calm wait"
	own_labels.add_theme_font_size_override("font_size", font_size)
	own_labels.add_theme_color_override("font_color", COL_BONE)
	state_row.add_child(own_labels)

	enemy_label = Label.new()
	enemy_label.name = "EnemyState"
	enemy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	enemy_label.text = "NPC: Unknown"
	enemy_label.add_theme_font_size_override("font_size", font_size)
	enemy_label.add_theme_color_override("font_color", COL_BONE)
	state_row.add_child(enemy_label)

	cue_label = Label.new()
	cue_label.name = "Cue"
	cue_label.text = "No request yet"
	cue_label.add_theme_font_size_override("font_size", font_size)
	cue_label.add_theme_color_override("font_color", COL_ACCENT)
	vbox.add_child(cue_label)

	lock_banner = Label.new()
	lock_banner.name = "LockBanner"
	lock_banner.text = ""
	lock_banner.visible = false
	lock_banner.add_theme_font_size_override("font_size", font_size)
	lock_banner.add_theme_color_override("font_color", COL_DANGER)
	vbox.add_child(lock_banner)

	var slots := HBoxContainer.new()
	slots.name = "Slots"
	slots.add_theme_constant_override("separation", 6)
	vbox.add_child(slots)
	slot_buttons.clear()
	for i in 8:
		var b := Button.new()
		b.name = "Slot%d" % (i + 1)
		b.custom_minimum_size = Vector2(120, 44)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_ALL
		var lbl := "Empty" if i >= 3 else "%d %s" % [i + 1, ["Attack", "Defense", "Run"][i]]
		b.text = lbl
		if i >= 3:
			b.disabled = true
		b.add_theme_font_size_override("font_size", font_size)
		_apply_button_theme(b)
		slots.add_child(b)
		slot_buttons.append(b)

	var record := GridContainer.new()
	record.name = "Record"
	record.columns = 2
	record.add_theme_constant_override("h_separation", 18)
	record.add_theme_constant_override("v_separation", 0)
	record.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(record)
	record_labels.clear()
	for i in 6:
		var l := Label.new()
		l.name = "Record%d" % (i + 1)
		l.text = ""
		l.add_theme_font_size_override("font_size", font_size)
		l.add_theme_color_override("font_color", COL_BONE)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		record.add_child(l)
		record_labels.append(l)

	var bottom := HBoxContainer.new()
	bottom.name = "Toolbar"
	bottom.add_theme_constant_override("separation", 8)
	vbox.add_child(bottom)

	start_button = _tool_button("Start encounter")
	start_button.disabled = true
	resume_button = _tool_button("Resume")
	restart_button = _tool_button("Restart")
	download_button = _tool_button("Download evidence")
	bottom.add_child(start_button)
	bottom.add_child(resume_button)
	bottom.add_child(restart_button)
	bottom.add_child(download_button)

	text_scale_button = OptionButton.new()
	text_scale_button.name = "TextSize"
	for t in ["100%", "125%", "150%", "200%"]:
		text_scale_button.add_item(t)
	text_scale_button.selected = 0
	_apply_button_theme(text_scale_button)
	bottom.add_child(text_scale_button)

	grayscale_button = CheckButton.new()
	grayscale_button.name = "Grayscale"
	grayscale_button.text = "Grayscale"
	bottom.add_child(grayscale_button)

	motion_button = CheckButton.new()
	motion_button.name = "ReducedMotion"
	motion_button.text = "Reduced motion"
	bottom.add_child(motion_button)

	status_label = Label.new()
	status_label.name = "Status"
	status_label.text = "Tick 0"
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_label.add_theme_font_size_override("font_size", font_size)
	status_label.add_theme_color_override("font_color", COL_MUTED)
	bottom.add_child(status_label)

	# Result card: hidden until a genuine terminal lifecycle. Reuses the existing connected
	# Restart instance as Play again (reparented on entry, restored on reset).
	result_card = PanelContainer.new()
	result_card.name = "ResultCard"
	result_card.visible = false
	result_card.set_anchors_preset(Control.PRESET_CENTER)
	result_card.custom_minimum_size = Vector2(400, 0)
	result_card.mouse_filter = Control.MOUSE_FILTER_STOP
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = COL_BACKING
	card_style.border_color = COL_EDGE
	card_style.set_border_width_all(2)
	card_style.content_margin_left = 16
	card_style.content_margin_right = 16
	card_style.content_margin_top = 16
	card_style.content_margin_bottom = 16
	result_card.add_theme_stylebox_override("panel", card_style)
	var card_vbox := VBoxContainer.new()
	card_vbox.name = "VBox"
	card_vbox.add_theme_constant_override("separation", 8)
	result_card.add_child(card_vbox)
	result_title = Label.new()
	result_title.name = "ResultTitle"
	result_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_title.add_theme_font_size_override("font_size", 20)
	result_title.add_theme_color_override("font_color", COL_BONE)
	card_vbox.add_child(result_title)
	result_body = Label.new()
	result_body.name = "ResultBody"
	result_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result_body.add_theme_font_size_override("font_size", font_size)
	result_body.add_theme_color_override("font_color", COL_BONE)
	card_vbox.add_child(result_body)
	result_footer = Label.new()
	result_footer.name = "ResultFooter"
	result_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_footer.add_theme_font_size_override("font_size", font_size)
	result_footer.add_theme_color_override("font_color", COL_MUTED)
	card_vbox.add_child(result_footer)
	hud_root.add_child(result_card)

	loading_label = Label.new()
	loading_label.name = "Loading"
	loading_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	loading_label.offset_top = -56
	loading_label.offset_bottom = -28
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_label.text = "Loading sparring encounter"
	loading_label.add_theme_font_size_override("font_size", font_size)
	loading_label.add_theme_color_override("font_color", COL_ACCENT)
	hud_root.add_child(loading_label)

	download_status_label = Label.new()
	download_status_label.name = "DownloadStatus"
	download_status_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	download_status_label.offset_top = -26
	download_status_label.offset_bottom = -4
	download_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	download_status_label.add_theme_font_size_override("font_size", 14)
	download_status_label.add_theme_color_override("font_color", COL_MUTED)
	hud_root.add_child(download_status_label)


func _tool_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 36)
	b.focus_mode = Control.FOCUS_ALL
	_apply_button_theme(b)
	return b


func _apply_button_theme(b: BaseButton) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("232A31")
	normal.border_color = COL_EDGE
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(3)
	normal.content_margin_left = 10
	normal.content_margin_right = 10
	normal.content_margin_top = 4
	normal.content_margin_bottom = 4
	var hover := normal.duplicate()
	hover.bg_color = Color("2C343C")
	var pressed := normal.duplicate()
	pressed.bg_color = Color("3A444D")
	var disabled := normal.duplicate()
	disabled.bg_color = Color("1A1F24")
	var focus := StyleBoxFlat.new()
	focus.bg_color = Color("232A31")
	focus.border_color = COL_FOCUS
	focus.set_border_width_all(2)
	focus.set_corner_radius_all(3)
	focus.content_margin_left = 10
	focus.content_margin_right = 10
	focus.content_margin_top = 4
	focus.content_margin_bottom = 4
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_stylebox_override("focus", focus)
	b.add_theme_color_override("font_color", COL_BONE)
	b.add_theme_color_override("font_hover_color", COL_BONE)
	b.add_theme_color_override("font_pressed_color", COL_FOCUS)
	b.add_theme_color_override("font_focus_color", COL_BONE)
	b.add_theme_color_override("font_disabled_color", COL_MUTED)
