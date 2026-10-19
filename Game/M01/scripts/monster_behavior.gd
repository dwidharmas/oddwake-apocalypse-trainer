class_name M01MonsterBehavior
extends RefCounted

const AUTHOR_ORDER := ["quick_claw", "brace", "short_bound"]
## R-F02/QA-RES-F03 bounded decision work: one reachability search per actor per decision,
## reused for every legal candidate goal, at most MAX_SEARCH_EXPANSIONS unique expansions.
const MAX_SEARCH_EXPANSIONS := 3840
## G3 §7 approach stop: inside Claw range (1600 mWU) but clear of body contact.
const APPROACH_STOP_MWU := 1590.0

var arena: M01Arena
var content: M01Content

var decision_id := 0
var decision_searches := 0
var decision_expansions := 0
var decision_violations := 0
var total_searches := 0
var total_expansions := 0
var total_violations := 0
var _tree := {}
var _tree_key := ""


func begin_decision() -> void:
	decision_id += 1
	decision_searches = 0
	decision_expansions = 0
	decision_violations = 0
	_tree = {}
	_tree_key = ""


func _route(self_pos: Array, goal_pos: Array) -> Array:
	var key := "%d|%.6f|%.6f" % [decision_id, float(self_pos[0]), float(self_pos[1])]
	if _tree_key != key:
		_tree = arena.build_route_tree(self_pos)
		_tree_key = key
		decision_searches += 1
		total_searches += 1
		if decision_searches > 1:
			decision_violations += 1
			total_violations += 1
		decision_expansions += int(_tree.get("expansions", 0))
		total_expansions += int(_tree.get("expansions", 0))
		if decision_expansions > MAX_SEARCH_EXPANSIONS:
			decision_violations += 1
			total_violations += 1
	return arena.route_from_tree(_tree, self_pos, goal_pos)


func setup(p_arena: M01Arena, p_content: M01Content) -> void:
	arena = p_arena
	content = p_content


func intent_family(actor: Dictionary) -> int:
	var intent: Variant = actor.get("accepted_intent", null)
	if intent == null or not (intent is Dictionary) or (intent as Dictionary).is_empty():
		return 0
	return int((intent as Dictionary).get("family", 0))


func candidate_skills(actor: Dictionary, family: int, enemy: Dictionary, tick: int) -> Array:
	var out: Array = []
	if family == 0:
		return out
	for sid in AUTHOR_ORDER:
		var def := content.skill(sid)
		if def.is_empty():
			continue
		if int(def["family"]) != _family_for_skill(sid, family):
			continue
		if not bool(actor["learned"].get(sid, false)):
			continue
		if not bool(actor["ready"].get(sid, false)):
			continue
		if not bool(actor["affordable"].get(sid, false)):
			continue
		if bool(actor["physical_locked"]) and sid != "quick_claw":
			pass
		if not _target_legal(sid, actor, enemy, tick):
			continue
		out.append(sid)
	return out


func _family_for_skill(sid: String, family: int) -> int:
	match sid:
		"quick_claw":
			return 1
		"brace":
			return 2
		"short_bound":
			return 3
	return 0


func _target_legal(sid: String, actor: Dictionary, enemy: Dictionary, tick: int) -> bool:
	if sid == "brace":
		return true
	if sid == "quick_claw":
		return bool(enemy["alive"]) and _visible(actor, enemy, tick)
	if sid == "short_bound":
		return true
	return false


func _visible(actor: Dictionary, enemy: Dictionary, tick: int) -> bool:
	if not bool(actor["enemy_visible"]):
		return false
	var dx := float(enemy["x"]) - float(actor["x"])
	var dy := float(enemy["y"]) - float(actor["y"])
	var d2 := dx * dx + dy * dy
	if d2 > arena.vision * arena.vision:
		return false
	return arena.line_of_effect(float(actor["x"]), float(actor["y"]),
		float(enemy["x"]), float(enemy["y"]))


## Endpoint separation gain for a candidate Bound route; enemy_center is the observed or frozen
## centre (never a hidden live position).
func _gain_to(end_pt: Array, enemy_center: Array, sep_before: float) -> float:
	var ex := float(enemy_center[0])
	var ey := float(enemy_center[1])
	var dx := float(end_pt[0]) - ex
	var dy := float(end_pt[1]) - ey
	return sqrt(dx * dx + dy * dy) - sep_before


func bound_candidates(actor: Dictionary, enemy_center: Array) -> Array:
	var sx := float(actor["x"])
	var sy := float(actor["y"])
	var ex := float(enemy_center[0])
	var ey := float(enemy_center[1])
	var bx := sx - ex
	var by := sy - ey
	var bl := sqrt(bx * bx + by * by)
	if bl > 0.001:
		bx = bx / bl
		by = by / bl
	else:
		bx = -1.0
		by = 0.0
	# Authored direction order: away, perpendicular-left, perpendicular-right, toward.
	var dirs: Array = [[bx, by], [-by, bx], [by, -bx], [-bx, -by]]
	var out: Array = []
	var sep_before := sqrt((sx - ex) * (sx - ex) + (sy - ey) * (sy - ey))
	for i in dirs.size():
		var dir: Array = dirs[i]
		var dx := float(dir[0])
		var dy := float(dir[1])
		if dx * dx + dy * dy < 1e-9:
			continue
		var ray_end := [sx + dx * 2400.0, sy + dy * 2400.0]
		var clipped := arena.clip_static([sx, sy], ray_end)
		var cx := float(clipped[0]) - sx
		var cy := float(clipped[1]) - sy
		var ray_len := sqrt(cx * cx + cy * cy)
		if ray_len < 1.0:
			continue
		var node_id := arena.nearest_legal_node_id(float(clipped[0]), float(clipped[1]))
		if node_id < 0:
			continue
		var node_pt := arena.node_center(node_id)
		var route := _route([sx, sy], node_pt)
		if route.is_empty():
			continue
		route = arena.truncate_route(route, 2400.0)
		var total := arena.route_length(route)
		if total < 200.0 or total > 2400.0 + 1e-6:
			continue
		var end_pt: Array = route[route.size() - 1]
		if not arena.center_legal(float(end_pt[0]), float(end_pt[1])):
			continue
		out.append({
			"direction": i,
			"route": route,
			"endpoint": end_pt,
			"gain": _gain_to(end_pt, enemy_center, sep_before),
			"length": total,
		})
	return out


func _best_from(opts: Array, min_gain: float) -> Dictionary:
	var best := {}
	var best_gain := -INF
	for o in opts:
		if float(o["gain"]) < min_gain:
			continue
		if float(o["gain"]) > best_gain + 1e-9:
			best_gain = float(o["gain"])
			best = o
	return best


func best_escape_bound(actor: Dictionary, enemy_center: Array) -> Dictionary:
	return _best_from(bound_candidates(actor, enemy_center), 1000.0)


func best_any_bound(actor: Dictionary, enemy_center: Array) -> Dictionary:
	return _best_from(bound_candidates(actor, enemy_center), -INF)


func plan(actor: Dictionary, enemy: Dictionary, tick: int, knowledge_state: String) -> Dictionary:
	begin_decision()
	var family := intent_family(actor)
	var self_pos := [float(actor["x"]), float(actor["y"])]
	# Frozen-memory isolation: the centre/distance used for planning comes from the observed
	# enemy only while visible, otherwise from the frozen last-known point, never hidden state.
	var enemy_center: Array = [float(self_pos[0]), float(self_pos[1])]
	var visible := _visible(actor, enemy, tick)
	if visible:
		enemy_center = [float(enemy["x"]), float(enemy["y"])]
	elif bool(actor["memory_valid"]):
		enemy_center = [float(actor["memory_x"]), float(actor["memory_y"])]
	var dx := float(enemy_center[0]) - float(self_pos[0])
	var dy := float(enemy_center[1]) - float(self_pos[1])
	var d := sqrt(dx * dx + dy * dy)
	var hp_ratio := float(actor["hp"]) / float(actor["hp_max"])
	var locked := bool(actor["physical_locked"])

	if family == 0:
		return _autonomous_plan(actor, enemy, tick, visible, d, hp_ratio, self_pos, enemy_center)

	if locked and family == 1:
		return _rest_plan(actor, "exhausted")
	if family == 1:
		if not visible:
			if bool(actor["memory_valid"]):
				return _search_plan(actor, "search")
			return _scout_plan(actor)
		if d <= 1600.0 and arena.line_of_effect(float(self_pos[0]), float(self_pos[1]),
				float(enemy_center[0]), float(enemy_center[1])):
			var fits := {}
			var cands: Array = []
			if bool(actor["ready"].get("quick_claw", false)) \
					and bool(actor["affordable"].get("quick_claw", false)):
				cands.append("quick_claw")
				fits["quick_claw"] = 1.0
			if cands.is_empty():
				# Inside Claw range with no legal Claw (cost/cooldown): ordinary rest.
				# Out of range is handled below by the ordinary approach goal.
				return _rest_plan(actor, "cannot_reach")
			return {"skill": cands[0], "fit_reason": "attack", "fits": fits, "candidates": cands,
				"knowledge": knowledge_state, "goal": _rest_goal(), "context_family": 1}
		return _approach_plan(actor, enemy_center)

	if family == 2:
		return _defense_plan(actor, enemy, tick, visible, d, self_pos, enemy_center,
			knowledge_state)

	if family == 3:
		return _run_plan(actor, enemy, tick, visible, self_pos, enemy_center, knowledge_state)

	return _rest_plan(actor, "not_ready")


## G3 §7 lines 137-140. Candidates are always appended in canonical authored order
## (Claw, Brace, Bound); defense pools never contain Claw.
func _defense_plan(actor: Dictionary, enemy: Dictionary, tick: int, visible: bool,
		d: float, self_pos: Array, enemy_center: Array, knowledge_state: String) -> Dictionary:
	var tune: Dictionary = content.tuning["defense_fit"]
	if not visible:
		if bool(actor["memory_valid"]):
			return _search_plan(actor, "search")
		return _rest_plan(actor, "rest")
	if d > float(tune["escape_max_distance_mwu"]):
		return _rest_plan(actor, "guarding")
	var brace_ok := bool(actor["ready"].get("brace", false)) \
		and bool(actor["affordable"].get("brace", false))
	var bound_ok := bool(actor["ready"].get("short_bound", false)) \
		and bool(actor["affordable"].get("short_bound", false))
	var opts := bound_candidates(actor, enemy_center)
	var escape := _best_from(opts, 1000.0)
	var best := _best_from(opts, -INF)
	var fits := {}
	var cands: Array = []
	var reason := "neutral_defense"

	if d <= float(tune["escape_max_distance_mwu"]) and not escape.is_empty() and bound_ok:
		reason = "escape"
		if brace_ok:
			cands.append("brace")
			fits["brace"] = float(tune["escape_brace_fit"])
		cands.append("short_bound")
		fits["short_bound"] = float(tune["escape_bound_fit"])
	elif d <= float(tune["hold_max_distance_mwu"]) and escape.is_empty():
		reason = "hold_ground"
		if brace_ok:
			cands.append("brace")
			fits["brace"] = float(tune["hold_brace_fit"])
		if bound_ok and not best.is_empty():
			cands.append("short_bound")
			fits["short_bound"] = float(tune["hold_bound_fit"])
	elif d > float(tune["hold_max_distance_mwu"]) and d <= float(tune["escape_max_distance_mwu"]):
		reason = "neutral_defense"
		if brace_ok:
			cands.append("brace")
			fits["brace"] = float(tune["neutral_fit"])
		if bound_ok and not best.is_empty():
			cands.append("short_bound")
			fits["short_bound"] = float(tune["neutral_fit"])
	elif d <= float(tune["hold_max_distance_mwu"]):
		# Escape route exists but Bound cannot be paid: Brace-only hold ground.
		reason = "hold_ground"
		if brace_ok:
			cands.append("brace")
			fits["brace"] = float(tune["hold_brace_fit"])

	if cands.is_empty():
		if d <= float(tune["escape_max_distance_mwu"]):
			return _disengage_plan(actor, enemy_center, knowledge_state)
		return _rest_plan(actor, "guarding")
	var goal := _rest_goal()
	if not best.is_empty():
		goal = _bound_goal(best)
	# GP-PLAY01-R03-F01: every defensive candidate choice (Brace or Bound) keeps the GENERAL
	# Defense context, so an autonomous defensive charge is compatible with a later Defense
	# request. The cands.is_empty() branch above hands off to _disengage_plan, which carries
	# Run context instead.
	return {"skill": null, "fit_reason": reason, "fits": fits, "candidates": cands,
		"knowledge": knowledge_state, "goal": goal, "context_family": 2}


func _run_plan(actor: Dictionary, enemy: Dictionary, tick: int, visible: bool,
		self_pos: Array, enemy_center: Array, knowledge_state: String) -> Dictionary:
	var tune: Dictionary = content.tuning["defense_fit"]
	if not visible and not bool(actor["memory_valid"]):
		return _rest_plan(actor, "rest")
	var escape := best_escape_bound(actor, enemy_center)
	var stam_ok := int(actor["stam"]) >= int(tune["run_min_stam_cp"])
	var bound_ok := bool(actor["ready"].get("short_bound", false)) \
		and bool(actor["affordable"].get("short_bound", false))
	if not escape.is_empty() and stam_ok and bound_ok:
		# GP-PLAY01-R03-F01: a Bound chosen to run away carries the general Run context.
		return {"skill": null, "fit_reason": "run", "fits": {"short_bound": 0.90},
			"candidates": ["short_bound"], "knowledge": knowledge_state,
			"goal": _bound_goal(escape), "context_family": 3}
	return _disengage_plan(actor, enemy_center, knowledge_state)


func _autonomous_plan(actor: Dictionary, enemy: Dictionary, tick: int, visible: bool,
		d: float, hp_ratio: float, self_pos: Array, enemy_center: Array) -> Dictionary:
	var knowledge := "unknown"
	if visible:
		knowledge = "visible"
	elif bool(actor["memory_valid"]):
		knowledge = "last_known"
	if bool(actor["physical_locked"]) or hp_ratio < 0.25:
		if knowledge == "unknown":
			return _rest_plan(actor, "rest")
		return _disengage_plan(actor, enemy_center, knowledge)
	if visible and d <= 1600.0 and hp_ratio < 0.50:
		return _defense_plan(actor, enemy, tick, visible, d, self_pos, enemy_center, knowledge)
	if visible:
		var claw_ok := bool(actor["ready"].get("quick_claw", false)) \
			and bool(actor["affordable"].get("quick_claw", false))
		if d <= 1600.0 and claw_ok and arena.line_of_effect(float(self_pos[0]),
				float(self_pos[1]), float(enemy_center[0]), float(enemy_center[1])):
			return {"skill": "quick_claw", "fit_reason": "attack", "fits": {"quick_claw": 1.0},
				"candidates": ["quick_claw"], "knowledge": knowledge, "goal": _rest_goal(),
				"context_family": 1}
		if claw_ok:
			return _approach_plan(actor, enemy_center)
		return _rest_plan(actor, "not_ready")
	if bool(actor["memory_valid"]):
		return _search_plan(actor, "search")
	return _scout_plan(actor)


func _approach_plan(actor: Dictionary, enemy_center: Array) -> Dictionary:
	var self_pos := [float(actor["x"]), float(actor["y"])]
	var dx := float(enemy_center[0]) - float(self_pos[0])
	var dy := float(enemy_center[1]) - float(self_pos[1])
	# Never emit an already-satisfied approach goal: it would complete on creation and replan
	# every boundary with no movement.
	if sqrt(dx * dx + dy * dy) <= APPROACH_STOP_MWU + arena.GUARD:
		return _rest_plan(actor, "unavailable")
	var route := _route(self_pos, enemy_center)
	if route.is_empty():
		return _rest_plan(actor, "unavailable")
	return {"skill": null, "fit_reason": "attack", "fits": {}, "candidates": [],
		"knowledge": "visible",
		"goal": _move_goal(enemy_center, route, APPROACH_STOP_MWU, "approach")}


func _disengage_plan(actor: Dictionary, enemy_center: Array, knowledge: String) -> Dictionary:
	var opts := bound_candidates(actor, enemy_center)
	var best := {}
	var best_gain := -INF
	for o in opts:
		if float(o["gain"]) <= 0.0:
			continue
		if float(o["gain"]) > best_gain + 1e-9:
			best_gain = float(o["gain"])
			best = o
	if not best.is_empty() and bool(actor["ready"].get("short_bound", false)) \
			and bool(actor["affordable"].get("short_bound", false)) \
			and float(best["gain"]) >= 1000.0 and int(actor["stam"]) >= 2000:
		# GP-PLAY01-R03-F01: a disengaging autonomous Bound carries the general Run context,
		# so a later Run request waits on it instead of cancelling the charge.
		return {"skill": "short_bound", "fit_reason": "disengage", "fits": {"short_bound": 0.90},
			"candidates": ["short_bound"], "knowledge": knowledge, "goal": _bound_goal(best),
			"context_family": 3}
	# GP-F05 P2: ordinary disengagement needs STRICTLY positive gain. Zero or negative
	# improvement rests instead of travelling to a point that is no better than staying.
	var move_best := _best_from(opts, 1e-9)
	if move_best.is_empty():
		return _rest_plan(actor, "rest")
	return {"skill": null, "fit_reason": "disengage", "fits": {}, "candidates": [],
		"knowledge": knowledge,
		"goal": _move_goal(move_best["endpoint"], move_best["route"], 0.0, "disengage")}


func _search_plan(actor: Dictionary, reason: String) -> Dictionary:
	var goals := search_goals(actor)
	for g in goals:
		var self_pos := [float(actor["x"]), float(actor["y"])]
		var route := _route(self_pos, g)
		if route.is_empty():
			continue
		return {"skill": null, "fit_reason": reason, "fits": {}, "candidates": [],
			"knowledge": "last_known",
			"goal": _move_goal(g, route, 0.0, "search")}
	return _scout_plan(actor)


func _scout_plan(actor: Dictionary) -> Dictionary:
	var entries := _patrol_entries(actor)
	var self_pos := [float(actor["x"]), float(actor["y"])]
	for e in entries:
		var route := _route(self_pos, e[1])
		if route.is_empty():
			continue
		return {"skill": null, "fit_reason": "scout", "fits": {}, "candidates": [],
			"knowledge": "unknown",
			"goal": _move_goal(e[1], route, 0.0, "patrol", int(e[0]))}
	return _rest_plan(actor, "rest")


func _rest_goal() -> Dictionary:
	return {"kind": "rest", "point": null, "route": [], "stop_mwu": 0.0, "purpose": "rest",
		"patrol_index": -1, "i": 0}


func _rest_plan(actor: Dictionary, reason: String) -> Dictionary:
	return {"skill": null, "fit_reason": _reason(reason), "fits": {}, "candidates": [],
		"knowledge": "unknown", "goal": _rest_goal()}


## Single place where raw rest reasons become G3-sanctioned fit_reason values.
func _reason(reason: String) -> String:
	match reason:
		"guarding":
			return "guard"
		"not_ready", "cannot_reach", "exhausted":
			return "unavailable"
	return reason


func _move_goal(point: Array, route: Array, stop_mwu: float, purpose: String,
		patrol_index: int = -1) -> Dictionary:
	var pts: Array = []
	for p in route:
		pts.append([float(p[0]), float(p[1])])
	return {"kind": "move", "point": [float(point[0]), float(point[1])], "route": pts,
		"stop_mwu": stop_mwu, "purpose": purpose, "patrol_index": patrol_index, "i": 0}


func _bound_goal(opt: Dictionary) -> Dictionary:
	var route: Array = opt.get("route", [])
	return _move_goal(opt.get("endpoint", [0.0, 0.0]), route, 0.0, "bound")


func _list_has_point(list: Array, point: Array) -> bool:
	for p in list:
		if float(p[0]) == float(point[0]) and float(p[1]) == float(point[1]):
			return true
	return false


## G3 §6 line 121: remembered centre first, then (J>=0.5) the four legal offset probes in
## authored order, else (J<0.5) the nearest REACHABLE public patrol point. Points already reached
## under the current search token are skipped.
## GP-PLAY01-R02-F03: the low-Instinct fallback is consumed at most ONCE per token — centre plus
## that single patrol point exhaust the sequence, after which `_search_plan` falls through to
## ordinary public scouting. The token is never extended by offering the next of the four patrol
## points. This is a pure query: nothing on the actor is mutated here.
func search_goals(actor: Dictionary) -> Array:
	var out: Array = []
	if not bool(actor["memory_valid"]):
		return out
	if bool(actor["search_token_exhausted"].get(str(actor["memory_token"]), false)):
		return out
	var visited: Array = actor["search_visited"]
	var center := [float(actor["memory_x"]), float(actor["memory_y"])]
	if not _list_has_point(visited, center):
		out.append(center)
	var j := float(actor["instinct"]) / 100.0
	if j >= 0.5:
		for off in content.tuning["vision"]["search_probe_offsets_mwu"]:
			var p := [float(center[0]) + float(off[0]), float(center[1]) + float(off[1])]
			if _list_has_point(visited, p):
				continue
			if arena.center_legal(float(p[0]), float(p[1])) \
					and arena.circle_line_clear([float(actor["x"]), float(actor["y"])], p, 0.0):
				out.append(p)
	elif not _patrol_consumed(visited):
		for p in patrol_goals(actor):
			if _list_has_point(visited, p):
				continue
			if not arena.center_legal(float(p[0]), float(p[1])):
				continue
			if not arena.circle_line_clear([float(actor["x"]), float(actor["y"])], p, 0.0):
				continue
			out.append(p)
			break
	return out


## True once any authored public patrol point has been reached under the current search token.
## `search_visited` is cleared when a new observation starts a new token, so this is exactly
## "one patrol fallback consumed for this token".
func _patrol_consumed(visited: Array) -> bool:
	for q in arena.patrol:
		if _list_has_point(visited, q):
			return true
	return false


## Nearest unvisited public patrol point first, ties broken by authored index.
## Returns [[authored_index, [x, y]], ...].
func _patrol_entries(actor: Dictionary) -> Array:
	var visited: Array = actor["patrol_visited"]
	var order: Array = arena.patrol
	var pending: Array = []
	for i in order.size():
		if visited.has(i):
			continue
		var px := float(order[i][0]) - float(actor["x"])
		var py := float(order[i][1]) - float(actor["y"])
		var d := px * px + py * py
		var inserted := false
		for k in pending.size():
			# GP-F05 P2: equal distance keeps the SMALLER authored index first, so the tie
			# fixture (10000,3000) chooses patrol index 0 over equally distant index 1.
			if d < float(pending[k][1]) - 1e-9 \
					or (absf(d - float(pending[k][1])) <= 1e-9 and int(pending[k][0]) > i):
				pending.insert(k, [i, d])
				inserted = true
				break
		if not inserted:
			pending.append([i, d])
	var out: Array = []
	for k in pending.size():
		var idx := int(pending[k][0])
		out.append([idx, [float(order[idx][0]), float(order[idx][1])]])
	return out


func patrol_goals(actor: Dictionary) -> Array:
	var out: Array = []
	for e in _patrol_entries(actor):
		out.append(e[1])
	return out


## G3 §7 line 131: U=(0.5+0.5J)*fit+0.6(1-J)*(2u-1), canonical authored technique order,
## one independent draw per candidate and only for pools of two or more.
func select_by_utility(candidates: Array, fits: Dictionary, instinct: int,
		draw: Callable) -> String:
	if candidates.is_empty():
		return ""
	if candidates.size() == 1:
		return str(candidates[0])
	var ordered: Array = []
	for sid in AUTHOR_ORDER:
		if candidates.has(sid):
			ordered.append(sid)
	for sid in candidates:
		if not ordered.has(sid):
			ordered.append(sid)
	var j := float(instinct) / 100.0
	var best := ""
	var best_util := -INF
	for i in ordered.size():
		var sid := str(ordered[i])
		var fit := float(fits.get(sid, 0.0))
		var u := (0.5 + 0.5 * j) * fit
		if ordered.size() >= 2:
			var z: float = 2.0 * float(draw.call()) - 1.0
			u += 0.6 * (1.0 - j) * z
		var better := false
		if u > best_util + 1e-12:
			better = true
		elif absf(u - best_util) <= 1e-12 and best != "":
			better = _tie_prefer(sid, best)
		if better:
			best_util = u
			best = sid
	return best


func _tie_prefer(candidate: String, current: String) -> bool:
	var rank := {"brace": 0, "short_bound": 1, "quick_claw": 2}
	return int(rank.get(candidate, 9)) < int(rank.get(current, 9))
