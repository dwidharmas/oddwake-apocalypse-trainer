class_name M01Arena
extends RefCounted

const GUARD := 0.001
const MAX_NAV_EXPANSIONS := 3840
const MAX_NAV_CHAIN := 3840
const NAV_NEIGHBORS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1),
	Vector2i(-1, 0), Vector2i(0, -1)]

var width := 0.0
var height := 0.0
var radius := 0.0
var contact_dist := 1000.0

var ix0 := 0.0
var ix1 := 0.0
var iy0 := 0.0
var iy1 := 0.0

var bx0 := 0.0
var bx1 := 0.0
var by0 := 0.0
var by1 := 0.0

var vision := 0.0
var cell := 250.0
var cols := 80
var rows := 48

var spawn: Array = []
var patrol: Array = []
var probes: Array = []

var legal_nodes: Array[int] = []
var node_index := {}
var node_pos: Array = []
## Counters for the most recent route request: ok/failure, unique expansions, chain length, wall µs.
var last_search := {"ok": false, "failure": "not_run", "expansions": 0, "chain_len": 0,
	"wall_us": 0}


func setup(arena: Dictionary) -> void:
	width = float(arena["width_mwu"])
	height = float(arena["height_mwu"])
	radius = float(arena["body_radius_mwu"])
	contact_dist = float(arena["contact_distance_mwu"])
	ix0 = float(arena["inset_min_x"])
	ix1 = float(arena["inset_max_x"])
	iy0 = float(arena["inset_min_y"])
	iy1 = float(arena["inset_max_y"])
	bx0 = float(arena["blocker_inflated_min_x"])
	bx1 = float(arena["blocker_inflated_max_x"])
	by0 = float(arena["blocker_inflated_min_y"])
	by1 = float(arena["blocker_inflated_max_y"])
	vision = float(arena["vision_range_mwu"])
	cell = float(arena["nav_cell_mwu"])
	cols = int(arena["nav_cols"])
	rows = int(arena["nav_rows"])
	spawn = (arena["spawn"] as Array).duplicate(true)
	patrol = (arena["patrol"] as Array).duplicate(true)
	probes = (arena["bound_probe_offsets_mwu"] as Array).duplicate(true)
	_build_nodes()


func map_copy() -> Dictionary:
	return {
		"width": width, "height": height,
		"blocker": [original_blocker()[0], original_blocker()[1],
			original_blocker()[2], original_blocker()[3]],
		"spawn": spawn.duplicate(true),
		"patrol": patrol.duplicate(true),
	}


func original_blocker() -> Array:
	return [9000.0, 11000.0, 4000.0, 8000.0]


func in_inset(x: float, y: float) -> bool:
	return x >= ix0 + GUARD and x <= ix1 - GUARD and y >= iy0 + GUARD and y <= iy1 - GUARD


func in_inflated_blocker(x: float, y: float) -> bool:
	return x > bx0 - GUARD and x < bx1 + GUARD and y > by0 - GUARD and y < by1 + GUARD


func center_legal(x: float, y: float) -> bool:
	return in_inset(x, y) and not in_inflated_blocker(x, y)


## Expanded-Baby radius-aware static legality. Derived from the SAME world rectangle and
## ORIGINAL blocker; the legacy monster-radius predicate above is untouched.
func static_legal_for(x: float, y: float, radius: float) -> bool:
	if x - radius < GUARD or x + radius > width - GUARD:
		return false
	if y - radius < GUARD or y + radius > height - GUARD:
		return false
	var b := original_blocker()
	if x + radius > float(b[0]) + GUARD and x - radius < float(b[1]) - GUARD \
			and y + radius > float(b[2]) + GUARD and y - radius < float(b[3]) - GUARD:
		return false
	return true


## Radius-aware swept static limit for one leg: the largest fraction of [from,to] whose centre
## stays statically legal at `radius`. Mirrors swept_static_limit's contract.
func swept_static_limit_for(from: Array, to: Array, radius: float) -> float:
	var fx := float(from[0])
	var fy := float(from[1])
	var tx := float(to[0])
	var ty := float(to[1])
	if not static_legal_for(fx, fy, radius):
		return 0.0
	var dx := tx - fx
	var dy := ty - fy
	if dx * dx + dy * dy < 1e-18:
		return 1.0
	var rect := _slab(fx, fy, dx, dy, radius + GUARD, width - radius - GUARD,
		radius + GUARD, height - radius - GUARD)
	if float(rect[0]) < 0.0:
		return 0.0
	var lo := maxf(0.0, float(rect[0]))
	var hi := minf(1.0, float(rect[1]))
	if lo > hi:
		return 0.0
	var b := original_blocker()
	var blk := _slab(fx, fy, dx, dy, float(b[0]) - radius - GUARD,
		float(b[1]) + radius + GUARD, float(b[2]) - radius - GUARD,
		float(b[3]) + radius + GUARD)
	var t := hi
	if float(blk[0]) >= 0.0 and float(blk[1]) >= 0.0:
		var blo := float(blk[0])
		var bhi := float(blk[1])
		if blo <= hi and bhi >= lo:
			if blo > lo:
				t = minf(t, blo)
			elif bhi < hi:
				lo = bhi
			else:
				return 0.0
	var rx := fx + dx * t
	var ry := fy + dy * t
	if static_legal_for(rx, ry, radius):
		return t
	var a := 0.0
	var bnd := t
	for i in 60:
		var m := (a + bnd) * 0.5
		if static_legal_for(fx + dx * m, fy + dy * m, radius):
			a = m
		else:
			bnd = m
	return a


## Radius-aware sampled clear-line test, used for prey route connectors on the conservative
## monster-radius navigation grid.
func circle_line_clear_for(from: Array, to: Array, radius: float) -> bool:
	var dx := float(to[0]) - float(from[0])
	var dy := float(to[1]) - float(from[1])
	var steps := maxi(1, int(ceil(sqrt(dx * dx + dy * dy) / 100.0)))
	for i in steps + 1:
		var t := float(i) / float(steps)
		if not static_legal_for(float(from[0]) + dx * t, float(from[1]) + dy * t, radius):
			return false
	return true


## Fixed 17-candidate placement order: preferred centre, then east, southeast, south,
## southwest, west, northwest, north, northeast on the first ring, then the same eight on the
## second. Diagonal components are radius/sqrt(2) from one ordered definition.
func placement_candidates(center: Array, ring_radii: Array) -> Array:
	var cx := float(center[0])
	var cy := float(center[1])
	var out: Array = [[cx, cy]]
	var dirs: Array = [[1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [-1.0, 1.0],
		[-1.0, 0.0], [-1.0, -1.0], [0.0, -1.0], [1.0, -1.0]]
	for ring in ring_radii:
		var r := float(ring)
		for d in dirs:
			var dx := float(d[0])
			var dy := float(d[1])
			var ox := 0.0
			var oy := 0.0
			if dx != 0.0 and dy != 0.0:
				ox = dx * r / sqrt(2.0)
				oy = dy * r / sqrt(2.0)
			else:
				ox = dx * r
				oy = dy * r
			out.append([cx + ox, cy + oy])
	return out


func node_id(col: int, row: int) -> int:
	return row * cols + col


func node_coords(id: int) -> Vector2i:
	return Vector2i(id % cols, id / cols)


func node_center(id: int) -> Array:
	var c := node_coords(id)
	return [c.x * cell, c.y * cell]


func _build_nodes() -> void:
	legal_nodes.clear()
	node_index.clear()
	node_pos.clear()
	var n := cols * rows
	node_pos.resize(n)
	for id in n:
		var c := node_coords(id)
		var px := c.x * cell
		var py := c.y * cell
		node_pos[id] = [px, py]
		if center_legal(px, py):
			node_index[id] = legal_nodes.size()
			legal_nodes.append(id)


func nearest_legal_node_id(x: float, y: float) -> int:
	var best_id := -1
	var best_d := INF
	for id in legal_nodes:
		var p: Array = node_pos[id]
		var dx := float(p[0]) - x
		var dy := float(p[1]) - y
		var d := dx * dx + dy * dy
		if d < best_d - 1e-9 or (absf(d - best_d) <= 1e-9 and (best_id < 0 or id < best_id)):
			best_d = d
			best_id = id
	return best_id


## Segment parameter range [t0, t1] clipped to [0, 1]; [-1.0, -1.0] when the axis ranges are
## disjoint (or an axis-parallel segment misses the slab).
static func _slab(p0x: float, p0y: float, dx: float, dy: float,
		minx: float, maxx: float, miny: float, maxy: float) -> Array:
	var t0 := 0.0
	var t1 := 1.0
	if absf(dx) < 1e-12:
		if p0x < minx or p0x > maxx:
			return [-1.0, -1.0]
	else:
		var ta := (minx - p0x) / dx
		var tb := (maxx - p0x) / dx
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return [-1.0, -1.0]
	if absf(dy) < 1e-12:
		if p0y < miny or p0y > maxy:
			return [-1.0, -1.0]
	else:
		var ta := (miny - p0y) / dy
		var tb := (maxy - p0y) / dy
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return [-1.0, -1.0]
	return [t0, t1]


func swept_static_limit(from: Array, to: Array) -> float:
	var fx := float(from[0])
	var fy := float(from[1])
	var tx := float(to[0])
	var ty := float(to[1])
	if not center_legal(fx, fy):
		return 0.0
	var dx := tx - fx
	var dy := ty - fy
	if dx * dx + dy * dy < 1e-18:
		return 1.0
	var inset := _slab(fx, fy, dx, dy, ix0 + GUARD, ix1 - GUARD, iy0 + GUARD, iy1 - GUARD)
	if float(inset[0]) < 0.0:
		return 0.0
	var lo := maxf(0.0, float(inset[0]))
	var hi := minf(1.0, float(inset[1]))
	if lo > hi:
		return 0.0
	var blk := _slab(fx, fy, dx, dy, bx0 - GUARD, bx1 + GUARD, by0 - GUARD, by1 + GUARD)
	var t := hi
	if float(blk[0]) >= 0.0 and float(blk[1]) >= 0.0:
		var blo := float(blk[0])
		var bhi := float(blk[1])
		if blo <= hi and bhi >= lo:
			if blo > lo:
				t = minf(t, blo)
			elif bhi < hi:
				lo = bhi
			else:
				return 0.0
	var rx := fx + dx * t
	var ry := fy + dy * t
	if center_legal(rx, ry):
		return t
	var a := 0.0
	var b := t
	for i in 60:
		var m := (a + b) * 0.5
		if center_legal(fx + dx * m, fy + dy * m):
			a = m
		else:
			b = m
	return a


func clip_static(from: Array, to: Array) -> Array:
	var t := swept_static_limit(from, to)
	if t <= 0.0:
		return [float(from[0]), float(from[1])]
	if t >= 1.0:
		return [float(to[0]), float(to[1])]
	return [float(from[0]) + (float(to[0]) - float(from[0])) * t,
		float(from[1]) + (float(to[1]) - float(from[1])) * t]


static func _seg_rect(p0x: float, p0y: float, p1x: float, p1y: float,
		minx: float, maxx: float, miny: float, maxy: float) -> bool:
	var r := _slab(p0x, p0y, p1x - p0x, p1y - p0y, minx, maxx, miny, maxy)
	if float(r[0]) < 0.0:
		return false
	return float(r[0]) <= float(r[1]) + 1e-12


func line_of_effect(x1: float, y1: float, x2: float, y2: float) -> bool:
	var b := original_blocker()
	if _seg_rect(x1, y1, x2, y2, b[0], b[1], b[2], b[3]):
		return false
	return true


func circle_line_clear(from: Array, to: Array, extra_radius: float) -> bool:
	var dx := float(to[0]) - float(from[0])
	var dy := float(to[1]) - float(from[1])
	var steps := maxi(1, int(ceil(sqrt(dx * dx + dy * dy) / 100.0)))
	for i in steps + 1:
		var t := float(i) / float(steps)
		var px := float(from[0]) + dx * t
		var py := float(from[1]) + dy * t
		if in_inflated_blocker_scaled(px, py, extra_radius):
			return false
		if px < ix0 + GUARD + extra_radius or px > ix1 - GUARD - extra_radius:
			return false
		if py < iy0 + GUARD + extra_radius or py > iy1 - GUARD - extra_radius:
			return false
	return true


func in_inflated_blocker_scaled(x: float, y: float, extra: float) -> bool:
	return x > bx0 - GUARD - extra and x < bx1 + GUARD + extra \
			and y > by0 - GUARD - extra and y < by1 + GUARD + extra


## R-F01/QA-RES-F01 bounded navigation. Each legal node is discovered and expanded at most once,
## parents are never overwritten, and reconstruction fails closed on corrupt/unreachable data.
func build_route_tree(from: Array, blocked: Dictionary = {}) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var start_id := nearest_legal_node_id(float(from[0]), float(from[1]))
	if start_id < 0:
		return {"ok": false, "start_id": -1, "parent": {}, "expansions": 0,
			"wall_us": Time.get_ticks_usec() - t0, "failure": "no_start_node"}
	var parent := {}
	var discovered := {}
	discovered[start_id] = true
	var frontier: Array[int] = [start_id]
	var expansions := 0
	var failure := ""
	while not frontier.is_empty() and failure.is_empty():
		frontier.sort()
		var next_frontier: Array[int] = []
		for id in frontier:
			if expansions >= MAX_NAV_EXPANSIONS:
				failure = "expansion_limit"
				break
			expansions += 1
			var c: Vector2i = node_coords(id)
			for off in NAV_NEIGHBORS:
				var nc: Vector2i = c + off
				if nc.x < 0 or nc.y < 0 or nc.x >= cols or nc.y >= rows:
					continue
				var nid := node_id(nc.x, nc.y)
				if discovered.has(nid) or blocked.has(nid):
					continue
				if not node_index.has(nid):
					continue
				discovered[nid] = true
				parent[nid] = id
				next_frontier.append(nid)
		frontier = next_frontier
	if failure.is_empty():
		return {"ok": true, "start_id": start_id, "parent": parent, "expansions": expansions,
			"wall_us": Time.get_ticks_usec() - t0, "failure": ""}
	return {"ok": false, "start_id": start_id, "parent": parent, "expansions": expansions,
		"wall_us": Time.get_ticks_usec() - t0, "failure": failure}


static func reconstruct_chain(parent: Dictionary, goal_id: int, start_id: int,
		max_nodes: int) -> Dictionary:
	if goal_id < 0 or goal_id >= max_nodes or start_id < 0 or start_id >= max_nodes:
		return {"ok": false, "chain": [], "failure": "invalid_endpoint"}
	var chain: Array[int] = []
	var seen := {}
	var cur := goal_id
	var hops := 0
	while cur != start_id:
		if seen.has(cur):
			return {"ok": false, "chain": [], "failure": "cycle_at_%d" % cur}
		if cur < 0 or cur >= max_nodes:
			return {"ok": false, "chain": [], "failure": "invalid_predecessor_%d" % cur}
		seen[cur] = true
		chain.append(cur)
		if not parent.has(cur):
			return {"ok": false, "chain": [], "failure": "missing_predecessor_%d" % cur}
		cur = int(parent[cur])
		hops += 1
		if hops > max_nodes:
			return {"ok": false, "chain": [], "failure": "chain_limit"}
	chain.append(start_id)
	chain.reverse()
	return {"ok": true, "chain": chain, "failure": ""}


func path_between(from: Array, goal: Array) -> Array:
	return route_from_tree(build_route_tree(from), from, goal)


func route_from_tree(tree: Dictionary, from: Array, goal: Array) -> Array:
	var start_id := int(tree.get("start_id", -1))
	var build_us := int(tree.get("wall_us", 0))
	var built_expansions := int(tree.get("expansions", 0))
	if not bool(tree.get("ok", false)) or start_id < 0:
		return _fail_route(str(tree.get("failure", "tree_unavailable")), built_expansions, 0, build_us)
	var goal_id := nearest_legal_node_id(float(goal[0]), float(goal[1]))
	if goal_id < 0:
		return _fail_route("no_goal_node", built_expansions, 0, build_us)
	var chain: Array = []
	if goal_id != start_id:
		var parent: Dictionary = tree.get("parent", {})
		if not parent.has(goal_id):
			return _fail_route("unreachable", built_expansions, 0, build_us)
		var rec := reconstruct_chain(parent, goal_id, start_id, mini(cols * rows, MAX_NAV_CHAIN))
		if not bool(rec["ok"]):
			return _fail_route(str(rec["failure"]), built_expansions, 0, build_us)
		chain = rec["chain"]
	else:
		chain = [start_id]
	# R01/FIX01: raw origins and raw goals reach the grid through swept-clear orthogonal
	# connectors; a diagonal shortcut or an unchecked raw append is never part of a route.
	var pts: Array = [[float(from[0]), float(from[1])]]
	for id in chain:
		if not _append_orthogonal(pts, node_center(int(id))):
			return _fail_route("connector_blocked", built_expansions, chain.size(), build_us)
	if not _append_orthogonal(pts, [float(goal[0]), float(goal[1])]):
		return _fail_route("connector_blocked", built_expansions, chain.size(), build_us)
	last_search = {"ok": true, "failure": "", "expansions": built_expansions,
		"chain_len": chain.size(), "wall_us": build_us}
	return pts


## Appends an orthogonal, body-swept-clear connector from the current tail of `out` to `to`.
## An already-coincident or already-axis-aligned clear leg appends its endpoint directly; a
## genuinely off-axis gap is closed by one deterministic intermediate corner (x-first, then
## y-first). Returns false when no swept-clear orthogonal connection exists.
## ARCH-PLAY01-R02-F01: `ix*/iy*/bx*/by*` already carry the body-centre clearance, so the
## connector is validated against that once-inflated geometry (extra radius 0). Supplying
## `radius` again imposed a second clearance and rejected legal grid edges such as
## (750,3000)->(1250,3000) and (8250,6000)->(8250,6250).
func _append_orthogonal(out: Array, to: Array) -> bool:
	var tail: Array = out[out.size() - 1]
	var tx := float(to[0])
	var ty := float(to[1])
	if absf(float(tail[0]) - tx) <= 1e-9 and absf(float(tail[1]) - ty) <= 1e-9:
		return true
	if absf(float(tail[0]) - tx) <= 1e-9 or absf(float(tail[1]) - ty) <= 1e-9:
		if not circle_line_clear(tail, to, 0.0):
			return false
		out.append([tx, ty])
		return true
	var corner: Array = [tx, float(tail[1])]
	if circle_line_clear(tail, corner, 0.0) and circle_line_clear(corner, to, 0.0):
		out.append(corner)
		out.append([tx, ty])
		return true
	corner = [float(tail[0]), ty]
	if circle_line_clear(tail, corner, 0.0) and circle_line_clear(corner, to, 0.0):
		out.append(corner)
		out.append([tx, ty])
		return true
	return false


func _fail_route(reason: String, expansions: int, chain_len: int, wall_us: int) -> Array:
	last_search = {"ok": false, "failure": reason, "expansions": expansions,
		"chain_len": chain_len, "wall_us": wall_us}
	return []


func route_length(pts: Array) -> float:
	var total := 0.0
	for i in pts.size() - 1:
		var a: Array = pts[i]
		var b: Array = pts[i + 1]
		var dx := float(b[0]) - float(a[0])
		var dy := float(b[1]) - float(a[1])
		total += sqrt(dx * dx + dy * dy)
	return total


func truncate_route(pts: Array, budget: float) -> Array:
	if pts.is_empty():
		return pts
	# G3 §4/FIX01: a Bound route truncates at the LAST NODE that fits the budget. Interpolating
	# a partial trailing segment would hand the planner an endpoint that is not a route node,
	# which is exactly the 2400-versus-2250 control the Architect specified.
	var out: Array = [[float(pts[0][0]), float(pts[0][1])]]
	var used := 0.0
	for i in pts.size() - 1:
		var a: Array = pts[i]
		var b: Array = pts[i + 1]
		var dx := float(b[0]) - float(a[0])
		var dy := float(b[1]) - float(a[1])
		var seg := sqrt(dx * dx + dy * dy)
		if used + seg <= budget + 1e-9:
			out.append([float(b[0]), float(b[1])])
			used += seg
		else:
			break
	return out


static func earliest_contact(a0: Array, a1: Array, b0: Array, b1: Array, dist: float) -> float:
	var r0x := float(a0[0]) - float(b0[0])
	var r0y := float(a0[1]) - float(b0[1])
	var vx := (float(a1[0]) - float(a0[0])) - (float(b1[0]) - float(b0[0]))
	var vy := (float(a1[1]) - float(a0[1])) - (float(b1[1]) - float(b0[1]))
	var d2 := dist * dist
	var rr := r0x * r0x + r0y * r0y
	if rr <= d2 + 1e-9:
		var rel := vx * r0x + vy * r0y
		if rel >= 0.0:
			return 1.0
		return 0.0
	var av := vx * vx + vy * vy
	if av < 1e-18:
		return 1.0
	var bq := 2.0 * (r0x * vx + r0y * vy)
	var cq := rr - d2
	var disc := bq * bq - 4.0 * av * cq
	if disc < 0.0:
		return 1.0
	var sq := sqrt(disc)
	var t1 := (-bq - sq) / (2.0 * av)
	var t2 := (-bq + sq) / (2.0 * av)
	var lo := minf(t1, t2)
	var hi := maxf(t1, t2)
	if lo >= 0.0 and lo <= 1.0:
		return lo
	if hi >= 0.0 and hi <= 1.0:
		return 1.0
	return 1.0


## Earliest contact with per-body STOP fractions: a body with stop < 1 holds its position from
## that fraction onward for the rest of the boundary. Used only by the expanded four-body sweep.
static func earliest_contact_polyline_stopped(pa: Array, aa: Array, ai: float, sa: float,
		pb: Array, ab: Array, bi: float, sb: float, dist: float) -> Array:
	var a_move := ai > 1e-12 and sa > 1e-12
	var b_move := bi > 1e-12 and sb > 1e-12
	if not a_move and not b_move:
		return [1.0, false]
	var times: Array = [0.0, 1.0]
	if a_move:
		_append_break_times(times, aa, ai)
	if b_move:
		_append_break_times(times, ab, bi)
	times.append(clampf(sa, 0.0, 1.0))
	times.append(clampf(sb, 0.0, 1.0))
	times.sort()
	var uniq: Array = []
	for t in times:
		var tf := clampf(float(t), 0.0, 1.0)
		if uniq.is_empty() or absf(float(uniq[uniq.size() - 1]) - tf) > 1e-12:
			uniq.append(tf)
	var d2 := dist * dist
	for k in range(1, uniq.size()):
		var t0 := float(uniq[k - 1])
		var t1 := float(uniq[k])
		var a0 := poly_point(pa, aa, ai, minf(t0, sa))
		var a1 := poly_point(pa, aa, ai, minf(t1, sa))
		var b0 := poly_point(pb, ab, bi, minf(t0, sb))
		var b1 := poly_point(pb, ab, bi, minf(t1, sb))
		var hit := _contact_local(a0, a1, b0, b1, d2)
		if hit >= 0.0:
			return [t0 + hit * (t1 - t0), true]
	return [1.0, false]


## Cumulative arc distance at every vertex of a proposed trajectory, measured from its first
## point. Time maps linearly onto this arc, so a corner is a break in the trajectory's velocity,
## not a chord shortcut.
static func poly_arcs(poly: Array) -> Array:
	var out: Array = [0.0]
	var cum := 0.0
	for i in range(1, poly.size()):
		var a: Array = poly[i - 1]
		var b: Array = poly[i]
		cum += sqrt(pow(float(b[0]) - float(a[0]), 2.0) + pow(float(b[1]) - float(a[1]), 2.0))
		out.append(cum)
	return out


## Position on a proposed trajectory at boundary-time fraction `t`. The actor covers `intended`
## mWU over the boundary, so its arc distance is t * intended, clamped at the trajectory end when
## static clipping truncated it earlier.
static func poly_point(poly: Array, arcs: Array, intended: float, t: float) -> Array:
	if poly.is_empty():
		return [0.0, 0.0]
	if poly.size() == 1 or intended <= 1e-12:
		return [float(poly[0][0]), float(poly[0][1])]
	var target := clampf(t * intended, 0.0, float(arcs[arcs.size() - 1]))
	for i in range(1, poly.size()):
		if float(arcs[i]) >= target - 1e-9:
			var seg := float(arcs[i]) - float(arcs[i - 1])
			var f := 0.0 if seg <= 1e-12 else (target - float(arcs[i - 1])) / seg
			var a: Array = poly[i - 1]
			var b: Array = poly[i]
			return [float(a[0]) + (float(b[0]) - float(a[0])) * f,
				float(a[1]) + (float(b[1]) - float(a[1])) * f]
	return [float(poly[poly.size() - 1][0]), float(poly[poly.size() - 1][1])]


## First-contact fraction of one linear relative sweep inside a single shared time interval.
## Returns the local fraction in [0,1], or -1.0 when the interval holds no new contact.
static func _contact_local(as0: Array, as1: Array, bs0: Array, bs1: Array, d2: float) -> float:
	var r0x := float(as0[0]) - float(bs0[0])
	var r0y := float(as0[1]) - float(bs0[1])
	var vx := (float(as1[0]) - float(as0[0])) - (float(bs1[0]) - float(bs0[0]))
	var vy := (float(as1[1]) - float(as0[1])) - (float(bs1[1]) - float(bs0[1]))
	var rr := r0x * r0x + r0y * r0y
	if rr <= d2 + 1e-9:
		# Already in contact entering the interval: blocking only while still closing.
		return 0.0 if vx * r0x + vy * r0y < 0.0 else -1.0
	var av := vx * vx + vy * vy
	if av < 1e-18:
		return -1.0
	var bq := 2.0 * (r0x * vx + r0y * vy)
	var cq := rr - d2
	var disc := bq * bq - 4.0 * av * cq
	if disc < 0.0:
		return -1.0
	var lo := (-bq - sqrt(disc)) / (2.0 * av)
	if lo >= 0.0 and lo <= 1.0:
		return lo
	return -1.0


## Earliest contact over two time-parameterized piecewise trajectories, evaluated on the shared
## time intervals formed by the union of both actors' corner times. Each actor's corner is a
## velocity break inside its own arc, so crossed corners, stationary/moving peers and side swaps
## all resolve against the real path rather than an endpoint chord.
##
## ARCH-PLAY01-R02-F02: returns `[fraction, contact_occurred]`. The occurrence flag is retained
## separately from the fraction so a contact that lands exactly on the boundary end (fraction 1.0)
## is distinguishable from "no contact at all", which also reports 1.0 for the applied position.
static func earliest_contact_polyline(pa: Array, aa: Array, ai: float, pb: Array, ab: Array,
		bi: float, dist: float) -> Array:
	if ai <= 1e-12 and bi <= 1e-12:
		return [1.0, false]
	var times: Array = [0.0, 1.0]
	_append_break_times(times, aa, ai)
	_append_break_times(times, ab, bi)
	times.sort()
	var d2 := dist * dist
	for k in range(1, times.size()):
		var t0 := float(times[k - 1])
		var t1 := float(times[k])
		var hit := _contact_local(
			poly_point(pa, aa, ai, t0), poly_point(pa, aa, ai, t1),
			poly_point(pb, ab, bi, t0), poly_point(pb, ab, bi, t1), d2)
		if hit >= 0.0:
			return [t0 + hit * (t1 - t0), true]
	return [1.0, false]


## Adds every within-boundary velocity break of one trajectory to `times`: the interior corner
## vertices, plus the final vertex when static clipping ended the path short of its intended
## distance — that last vertex is a change of velocity to zero, and `_contact_local` must not
## interpolate across it as if the actor kept moving. Deduplicated at 1e-12 resolution.
static func _append_break_times(times: Array, arcs: Array, intended: float) -> void:
	var base := float(arcs[arcs.size() - 1])
	if intended <= 1e-12 or base <= 1e-12:
		return
	for k in range(1, arcs.size() - 1):
		_append_time(times, float(arcs[k]) / intended)
	if base < intended - 1e-12:
		_append_time(times, base / intended)


static func _append_time(times: Array, f: float) -> void:
	if f <= 1e-12 or f >= 1.0 - 1e-12:
		return
	var dup := false
	for seen in times:
		if absf(float(seen) - f) <= 1e-12:
			dup = true
			break
	if not dup:
		times.append(f)
