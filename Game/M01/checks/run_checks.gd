extends SceneTree

## M01 acceptance check runner.
## Usage:
##   Godot --headless --path Game/M01 --script res://checks/run_checks.gd
##   Godot --headless --path Game/M01 --script res://checks/run_checks.gd -- --suite=contracts
## Optional arguments after `--`:
##   --suite=<name>   run one suite. Default is the tiny development probe `dev_smoke`
##                    (max 120 logical ticks under one absolute 3000 ms deadline:
##                    the sim receives the exact remaining budget — never 0 — and an
##                    exhausted deadline stops the probe as visible noncompletion).
##                    Known: dev_smoke, smoke, contracts, geometry, response, behavior,
##                    hidden, authority, telemetry, stats, performance, play01_focus, all.
##                    An unknown suite name fails fast with a nonzero exit and runs nothing.
##   --seed=<int>     root seed override for live suites
##   --out=<path>     evidence output directory (default res://../../Docs/junior/evidence/...)
##
## RUN01 `play01_focus` is a FIXED profile, not a test registry: it executes exactly the16
## selected result records plus the C00 content gate, in one immutable order, with no seed
## override (every selected fixture pins seed3101 itself). It carries one absolute3000 ms
## deadline measured from `_initialize` entry through content, the cases and the checked result
## write/readback, and a4096-call aggregate ceiling on actual `sim.step()` invocations that is
## counted independently of whether `sim.tick` advances. Manual diagnostic tick jumps are
## counted separately and are never simulated steps. Both `play01_focus` and `dev_smoke` stop
## after a failing record, write an incomplete result and label the unreached records NOT RUN.
##
## R-F03/QA-RES-F02: default and unknown suites must never fan out into the full
## suites (smoke 10800 ticks, performance 3600 ticks, 256-trial stats). Full suites
## stay available only by explicit name. Every stage prints `STAGE <name>` before entry.
## R03 ARCH-F06: dev_smoke enforces one absolute deadline across fixture load, nav,
## corrupt-chain, sim, oracles and the final gate (D06), with synthetic labeled
## scenarios (D05, D07) for the deadline arithmetic itself.

const DEFAULT_OUT := "res://../../Docs/junior/evidence/MM-M01-001/R01"

const SUITES: Array[String] = ["dev_smoke", "smoke", "contracts", "geometry", "response",
	"behavior", "hidden", "authority", "telemetry", "stats", "performance", "play01_focus",
	"baby_growth_revival", "all"]

const DEV_SMOKE_MAX_TICKS := 120
const DEV_SMOKE_WALL_MS := 3000

## Expanded Baby opt-in profile: seed3101, <=120 actual steps, absolute3000ms deadline.
const BABY_WALL_MS := 3000
const BABY_MAX_STEPS := 120

## RUN01 fixed focused profile limits. Both are stops, not measured compliance claims.
const PLAY01_FOCUS_WALL_MS := 3000
const PLAY01_FOCUS_MAX_STEPS := 4096

## Exact expected record sets for the two selected routes. play01_focus is exactly the C00
## content gate plus16 immutable case records; dev_smoke is C00 plus D00..D07, once each.
## Missing, duplicated or unattempted IDs are reported as such and can never count as success.
const PLAY01_FOCUS_IDS: Array[String] = ["C00-content-load",
	"C26-ordinary-movement", "C27-goal-production", "C28-corner-traversal",
	"C63-legal-connectors", "C64-static-stop-contact", "C53-lifecycle-correlation",
	"C54-quick-g14-boundaries", "C55-movement-action-state", "C57-owning-intent-retirement",
	"C58-request-episode-divergence", "C59-quick-production-commit",
	"C65-brace-interrupt-exhaustion", "C49-npc-ingress-correlation",
	"C81-g12-utility-selection", "C82-m01-03-response-instinct-invariant",
	"C82-m01-03-skill-instinct-flip"]

const DEV_SMOKE_IDS: Array[String] = ["C00-content-load", "D00-fixtures-load",
	"D01-nav-fixtures", "D02-corrupt-chain-fails-closed", "D03-dev-tick-wall-budget",
	"D04-nav-work-budget", "D05-timeout-predicate", "D06-probe-timeout",
	"D07-remaining-budget-oracle"]

## Expanded Baby finite profile. Every row is authored here and NOT RUN until separately released.
const BABY_IDS: Array[String] = ["B01-content-mode", "B02-observation-symmetry",
	"B03-target-selection", "B04-prey-flee-bound", "B05-collision-four-body",
	"B06-credit-overkill", "B07-duplicate-depletion-reward", "B08-reward-cap",
	"B09-stat-hold-reset", "B10-prey-respawn-blocked", "B11-monster-ko-return",
	"B12-mutual-ko-effects", "B13-end-precedence", "B14-telemetry-schema",
	"B15-safe-projection", "B16-action-categories", "B17-legacy-preservation"]

var results: Array = []
var started_msec := 0
var content: M01Content
var arena: M01Arena
var out_dir := ""
var last_run_timed_out := false
## Fixture feed for the G-12 utility probe: one forced uniform per candidate draw.
var _probe_draws: Array = []
var _probe_draw_n := 0

## RUN01 selected-route accounting. Only `play01_focus` drives the focus deadline/step
## ceiling; `play01_focus` and `dev_smoke` additionally share the stop-first-failure gate and
## the checked result sink. Every other suite keeps its original behaviour untouched.
var profile_name := ""
var profile_seed := 3101
var checked_sink := false
var focus_active := false
var baby_active := false
var stopped := false
var stop_reason := ""
var stop_noted := false
var step_attempts := 0
var step_completed := 0
var manual_ticks := 0
var case_steps_before := 0
var case_steps_max := 0
var current_case := ""
var sink_path := ""
var sink_ok := false
var complete_marker := ""
## RUN01 F04: why the checked sink cannot confer success (empty while it can). The profile
## clock is never renewed; this only records the last stage at which it was seen exhausted.
var sink_late_reason := ""
## dev_smoke's own absolute window origin (set by _suite_dev_smoke), used only for the
## checked-sink deadline so the sink cannot outlive the probe it describes.
var dev_smoke_t0 := 0


func _stage_enter(stage: String) -> void:
	print("STAGE %s (elapsed %d ms)" % [stage, Time.get_ticks_msec() - started_msec])


func _initialize() -> void:
	# RUN01: `started_msec` is taken first so both the dev_smoke window and the play01_focus
	# absolute deadline are measured from _initialize entry, i.e. before content/setup.
	started_msec = Time.get_ticks_msec()
	var opts := _parse_args()
	out_dir = str(opts.get("out", DEFAULT_OUT))
	var suite := str(opts.get("suite", "dev_smoke"))
	var seed_override := int(str(opts.get("seed", "0")))
	profile_name = suite
	profile_seed = seed_override if seed_override > 0 else 3101
	focus_active = suite == "play01_focus"
	baby_active = suite == "baby_growth_revival"
	checked_sink = suite == "play01_focus" or suite == "dev_smoke" or suite == "baby_growth_revival"
	_stage_enter("arguments")
	print("SUITE %s" % suite)
	if not SUITES.has(suite):
		printerr("ERROR: unknown suite '%s' — refusing to run anything. Known suites: %s" % [
			suite, ", ".join(SUITES)])
		quit(2)
		return

	_stage_enter("content-load")
	content = M01Content.new()
	arena = M01Arena.new()
	var ok := content.load_from_disk()
	if not ok:
		_record("C00-content-load", false, "content validation failed:\n" + content.failure_report())
		_finish(1)
		return
	_record("C00-content-load", true, "schema m01.1, %d skills, hash species=%s tuning=%s" % [
		content.skills.size(), str(content.hashes.get("species", "")).left(12),
		str(content.hashes.get("tuning", "")).left(12)])
	arena.setup(content.arena)

	_stage_enter("suite-" + suite)
	match suite:
		"dev_smoke":
			_suite_dev_smoke(seed_override)
		"smoke":
			_suite_smoke(seed_override)
		"contracts":
			_suite_contracts()
		"geometry":
			_suite_geometry()
		"response":
			_suite_response()
		"behavior":
			_suite_behavior()
		"hidden":
			_suite_hidden()
		"authority":
			_suite_authority()
		"telemetry":
			_suite_telemetry(seed_override)
		"stats":
			_suite_stats()
		"performance":
			_suite_performance(seed_override)
		"play01_focus":
			# RUN01 fixed profile: no seed override reaches it; its own fixtures pin 3101.
			_suite_play01_focus()
		"baby_growth_revival":
			# Expanded Baby fixed profile: seed and fixtures pin 3101; not in default fanout.
			_suite_baby_growth_revival()
		"all":
			_suite_contracts()
			_suite_geometry()
			_suite_response()
			_suite_behavior()
			_suite_hidden()
			_suite_authority()
			_suite_telemetry(seed_override)
			_suite_stats()
			_suite_performance(seed_override)
			_suite_smoke(seed_override)
		_:
			printerr("ERROR: suite '%s' reached dispatch without a handler" % suite)
			quit(2)
			return
	_finish(0 if _failures() == 0 else 1)


func _parse_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			continue
		var body := a.trim_prefix("--")
		var eq := body.find("=")
		if eq > 0:
			out[body.substr(0, eq)] = body.substr(eq + 1)
		else:
			out[body] = "1"
	return out


func _failures() -> int:
	var n := 0
	for r in results:
		if not bool(r["pass"]):
			n += 1
	return n


func _record(id: String, passed: bool, detail: String) -> void:
	results.append({"id": id, "pass": passed, "detail": detail})
	print("%s %s — %s" % ["PASS" if passed else "FAIL", id, detail])
	# RUN01 stop-first-failure for the two selected routes only (play01_focus and dev_smoke).
	# The failing record is retained in full; everything unreached is labelled NOT RUN rather
	# than silently executed or silently passed. Every other suite is unaffected.
	if not passed and checked_sink and not stopped:
		_stop("record %s failed" % id)


func _not_run(id: String, why: String) -> void:
	results.append({"id": id, "pass": true, "not_run": true, "detail": why})
	print("NOT RUN %s — %s" % [id, why])


# ---------------------------------------------------------------- run helpers

func _new_telemetry(seed_v: int, mode_v: String, fixture_id: String = "") -> M01Telemetry:
	var t := M01Telemetry.new()
	t.reset()
	t.build_header({
		"schema": "m01.2" if mode_v == "baby_growth_revival" else "m01.1",
		"mode": mode_v,
		"fixture_id": fixture_id if fixture_id != "" else null,
		"engine": Engine.get_version_info().get("string", "unknown"),
		"build": "mm-m01-r01",
		"platform": OS.get_name(),
		"browser": "%s %s" % [OS.get_name(), OS.get_version()],
		"role_hashes": {},
		"content_hashes": content.hashes,
		"map_hash": content.hashes.get("arena", ""),
		"tuning_hash": content.hashes.get("tuning", ""),
		"root_seed": str(seed_v),
		"stream_seeds": {},
		"stream_draw_counts": {},
		"initial_state": {},
		"loadouts": [],
		"compiled_ticks": content.compiled,
	})
	return t


func _new_sim(seed_v: int, mode_v: String, fixture: Dictionary = {}) -> M01Simulation:
	var t := _new_telemetry(seed_v, mode_v, str(fixture.get("id", "")))
	var sim := M01Simulation.new()
	sim.setup(content, arena, t, mode_v, seed_v, fixture)
	if not fixture.is_empty():
		sim.apply_fixture(fixture)
	return sim


func _stage(sim: M01Simulation, trainer: int, family: int, seq: int, tick: int,
		target_kind: int = 0, target_or_area: Variant = null) -> void:
	var raw := {
		"schema": "m01.1", "trainer": trainer, "actor": trainer,
		"sequence": seq, "slot": family - 1, "family": family,
		"target_kind": target_kind, "target_or_area": target_or_area,
		"observed_tick": tick,
	}
	sim.gateway.stage(raw, tick + 1)


func _run(sim: M01Simulation, max_ticks: int, human_policy: Callable = Callable(),
		wall_budget_ms: int = 0) -> int:
	var guard := 0
	last_run_timed_out = false
	var t0 := Time.get_ticks_msec()
	# RUN01 F06: dev_smoke reaches sim.step() only through this loop (its single D03 _run
	# call), so its attempted/completed counts are taken here. Partial, ended and deadline
	# exits all count the calls actually reached; a tick that does not advance still counts
	# as attempted, and manual diagnostic tick jumps never count as simulated steps.
	var count_steps := profile_name == "dev_smoke"
	while not sim.ended and guard < max_ticks:
		if wall_budget_ms > 0 and Time.get_ticks_msec() - t0 > wall_budget_ms:
			last_run_timed_out = true
			break
		if human_policy.is_valid():
			human_policy.call(sim)
		if count_steps:
			step_attempts += 1
		var tick_before := int(sim.tick)
		sim.step()
		if count_steps and int(sim.tick) != tick_before:
			step_completed += 1
		guard += 1
		if wall_budget_ms > 0 and Time.get_ticks_msec() - t0 > wall_budget_ms:
			last_run_timed_out = true
			break
	if wall_budget_ms > 0 and Time.get_ticks_msec() - t0 > wall_budget_ms:
		last_run_timed_out = true
	return sim.tick


func _probe_overrun(probe_t0: int) -> bool:
	# Exhausted means remaining <= 0, so an elapsed exactly equal to the
	# budget is already the deadline, not a live remainder.
	return Time.get_ticks_msec() - probe_t0 >= DEV_SMOKE_WALL_MS


func _budget_for(elapsed_ms: int, budget_ms: int) -> int:
	return budget_ms - elapsed_ms


func _remaining_budget_ms(t0: int) -> int:
	return _budget_for(Time.get_ticks_msec() - t0, DEV_SMOKE_WALL_MS)


func _remaining_ok(remaining_ms: int) -> bool:
	return remaining_ms > 0


func _probe_incomplete(stage_name: String, elapsed_ms: int, pending: Array) -> void:
	# Deadline verdict plus explicit noncompletion labels for checks that never ran.
	_record("D06-probe-timeout", false,
		"dev_smoke exceeded its internal %dms budget during %s (elapsed %dms); probe not completed" % [
			DEV_SMOKE_WALL_MS, stage_name, elapsed_ms])
	for rid in pending:
		_not_run(str(rid), "probe deadline exceeded during " + stage_name)


func _probe_gate(stage_name: String, probe_t0: int, pending: Array) -> bool:
	if not _probe_overrun(probe_t0):
		return false
	_probe_incomplete(stage_name, Time.get_ticks_msec() - probe_t0, pending)
	return true


func _probe_exhausted(stage_name: String, probe_t0: int, processed: int,
		total: int, partial_id: String, pending: Array, observed_errors: Array,
		in_progress: bool = false) -> bool:
	# A partially processed fixture set is incomplete, never PASS: record the
	# partial item as failed with processed/total, then one D06 noncompletion
	# plus NOT RUN labels for everything not reached.
	var remaining := _remaining_budget_ms(probe_t0)
	if remaining > 0:
		return false
	_record(partial_id, false,
		"%s incomplete at the absolute deadline: completed %d/%d items, in_progress=%s, remaining %dms; observed errors=[%s]" % [
			partial_id, processed, total, str(in_progress), remaining,
			"; ".join(observed_errors)])
	_probe_incomplete(stage_name, Time.get_ticks_msec() - probe_t0, pending)
	return true


func _dev_timeout_pass(timed_out: bool, run_elapsed_ms: int, run_budget_ms: int,
		probe_elapsed_ms: int) -> bool:
	# A run passes only when its budget was positive, it stayed inside that
	# budget and the whole probe stayed inside the absolute deadline.
	return (not timed_out) \
		and run_budget_ms > 0 \
		and run_elapsed_ms <= run_budget_ms \
		and probe_elapsed_ms <= DEV_SMOKE_WALL_MS


func _dev_timeout_selftest() -> Dictionary:
	# Synthetic labeled scenarios (no engine timing): returns failing labels.
	# Covers contract classes: substantial pre-simulation work, final/ending-step
	# overrun and probe overrun after D03.
	var b := DEV_SMOKE_WALL_MS
	var pre_sim_rem := _budget_for(2900, b)
	var scenarios := {
		"full-budget-clean": _dev_timeout_pass(false, b, b, b),
		"positive-remaining": _dev_timeout_pass(false, 100, 1000, 2500),
		"substantial-pre-sim-work-remaining": _dev_timeout_pass(
			false, 50, pre_sim_rem, 2900 + 50),
		"zero-tick-clean": _dev_timeout_pass(false, 0, b, 0),
		"timed-out-flag-fails": not _dev_timeout_pass(true, 0, b, 0),
		"ending-step-overrun-fails": not _dev_timeout_pass(false, b + 1, b, 100),
		"zero-budget-fails": not _dev_timeout_pass(false, 0, 0, 0),
		"probe-overrun-after-d03-fails": not _dev_timeout_pass(
			false, 100, b, b + 1),
		"timeout-at-full-budget-fails": not _dev_timeout_pass(true, b, b, b),
	}
	var bad: Array = []
	for k in scenarios:
		if not bool(scenarios[k]):
			bad.append(str(k))
	return {"bad": bad, "count": scenarios.size()}


func _remaining_oracle() -> Dictionary:
	# Synthetic labeled scenarios for the absolute-deadline arithmetic: the sim
	# receives the exact remainder (never 0) and <=0 stops the probe.
	var b := DEV_SMOKE_WALL_MS
	var scenarios := {
		"full-remainder": _budget_for(0, b) == b and _remaining_ok(_budget_for(0, b)),
		"shrinking-remainder": _budget_for(2000, b) == b - 2000 \
			and _remaining_ok(_budget_for(2000, b)),
		"substantial-pre-sim-remainder": _budget_for(2900, b) == 100 \
			and _remaining_ok(_budget_for(2900, b)),
		"last-millisecond": _budget_for(b - 1, b) == 1 and _remaining_ok(_budget_for(b - 1, b)),
		"exhausted-zero-stops": not _remaining_ok(_budget_for(b, b)),
		"overrun-negative-stops": not _remaining_ok(_budget_for(b + 500, b)),
		"item-exhaustion-at-3000-stops": b == 3000 \
			and _budget_for(3000, b) == 0 \
			and not _remaining_ok(_budget_for(3000, b)),
		"pre-setup-exhaustion-stops": _budget_for(b + 1, b) == -1 \
			and not _remaining_ok(_budget_for(b + 1, b)),
		"zero-after-setup-stops": _budget_for(b, b) == 0 \
			and not _remaining_ok(_budget_for(b, b)),
		"post-d03-oracle-overrun-fails": not _dev_timeout_pass(false, 100, b, b + 1),
	}
	var bad: Array = []
	for k in scenarios:
		if not bool(scenarios[k]):
			bad.append(str(k))
	return {"bad": bad, "count": scenarios.size()}


# ---------------------------------------------------- RUN01 selected-route accounting/sink

## The single place a selected sim.step() is invoked, so the aggregate ceiling counts CALLS
## rather than tick advancement and a stop is visible before the next call is attempted.
func _pstep(sim: M01Simulation) -> void:
	if focus_active:
		if step_attempts >= PLAY01_FOCUS_MAX_STEPS:
			_stop("play01_focus step ceiling %d reached" % PLAY01_FOCUS_MAX_STEPS)
			return
		if not _focus_remaining_ok():
			_stop("play01_focus absolute deadline exhausted during a step")
			return
		step_attempts += 1
	elif baby_active:
		if step_attempts >= BABY_MAX_STEPS:
			_stop("baby_growth_revival step ceiling %d reached" % BABY_MAX_STEPS)
			return
		if not _baby_remaining_ok():
			_stop("baby_growth_revival absolute deadline exhausted during a step")
			return
		step_attempts += 1
	var before := int(sim.tick)
	sim.step()
	if focus_active and int(sim.tick) != before:
		step_completed += 1
	if baby_active and int(sim.tick) != before:
		step_completed += 1


## A manual diagnostic tick jump is NOT a simulated step. It is counted separately so the result
## never reports it as step-budget consumption (the cited expiry diagnostics reach tick 961 by
## assignment, not by 961 boundaries).
func _mtick(sim: M01Simulation, value: int) -> void:
	if focus_active or baby_active:
		manual_ticks += 1
	sim.tick = value


func _focus_remaining_ms() -> int:
	return (started_msec + PLAY01_FOCUS_WALL_MS) - Time.get_ticks_msec()


func _focus_remaining_ok() -> bool:
	return _focus_remaining_ms() > 0


func _baby_remaining_ms() -> int:
	return (started_msec + BABY_WALL_MS) - Time.get_ticks_msec()


func _baby_remaining_ok() -> bool:
	return _baby_remaining_ms() > 0


func _baby_gate(id: String) -> bool:
	if stopped:
		_not_run(id, stop_reason)
		return false
	current_case = id
	case_steps_before = step_attempts
	if not _baby_remaining_ok():
		_stop("baby_growth_revival absolute deadline exhausted before " + id)
		_not_run(id, stop_reason)
		return false
	return true


func _baby_end() -> void:
	var used := step_attempts - case_steps_before
	if used > case_steps_max:
		case_steps_max = used
	if not _baby_remaining_ok():
		_stop("baby_growth_revival absolute deadline exhausted after " + current_case)


func _stop(reason: String) -> void:
	stopped = true
	stop_reason = reason
	if not stop_noted:
		stop_noted = true
		_append_note("selected route stopped", reason)


## Stop-first-failure gate for dev_smoke: once a record has failed, every expected record that
## has produced no row at all is labelled NOT RUN instead of being silently executed or silently
## passed. Returns true when the caller must stop.
func _stop_gate(stage_name: String) -> bool:
	if not stopped:
		return false
	for rid in _id_accounting()["missing"]:
		_not_run(str(rid), "stopped after a failed record during " + stage_name)
	return true


## Gate before each play01_focus case. Returns false only when the case must be skipped, in
## which case it has already been labelled NOT RUN.
func _focus_gate(id: String) -> bool:
	if stopped:
		_not_run(id, stop_reason)
		return false
	current_case = id
	case_steps_before = step_attempts
	if not _focus_remaining_ok():
		_stop("play01_focus absolute deadline exhausted before " + id)
		_not_run(id, stop_reason)
		return false
	return true


## Gate after each play01_focus case: record the per-case step maximum and stop if the deadline
## was crossed while the case ran.
func _focus_end() -> void:
	var used := step_attempts - case_steps_before
	if used > case_steps_max:
		case_steps_max = used
	if not _focus_remaining_ok():
		_stop("play01_focus absolute deadline exhausted after " + current_case)


func _expected_ids() -> Array:
	if profile_name == "play01_focus":
		return PLAY01_FOCUS_IDS
	if profile_name == "dev_smoke":
		return DEV_SMOKE_IDS
	if profile_name == "baby_growth_revival":
		return BABY_IDS
	return []


## Attempted / unattempted / missing / duplicated IDs against the profile's exact expected set.
## A NOT RUN row is not an attempt; a success verdict requires every expected id exactly once.
func _id_accounting() -> Dictionary:
	var expected := _expected_ids()
	if expected.is_empty():
		return {"attempted": [], "unattempted": [], "missing": [],
			"duplicates": [], "expected": 0}
	var normal := {}
	var nrun := {}
	for r in results:
		var key := str(r.get("id", ""))
		if bool(r.get("not_run", false)):
			nrun[key] = int(nrun.get(key, 0)) + 1
		else:
			normal[key] = int(normal.get(key, 0)) + 1
	var attempted: Array = []
	var unattempted: Array = []
	var missing: Array = []
	var duplicates: Array = []
	for item in expected:
		var rid := str(item)
		var count := int(normal.get(rid, 0))
		if count > 1 or int(nrun.get(rid, 0)) > 1:
			duplicates.append(rid)
		if count == 1:
			attempted.append(rid)
		else:
			unattempted.append(rid)
			if not nrun.has(rid):
				missing.append(rid)
	for extra in normal:
		if not expected.has(extra):
			duplicates.append(extra)
	return {"attempted": attempted, "unattempted": unattempted,
		"missing": missing, "duplicates": duplicates, "expected": expected.size()}


## Absolute deadline the checked result sink must be written within: play01_focus uses its one
## deadline from _initialize entry; dev_smoke uses the very window its own D06 record already
## enforces. 0 means no applicable profile deadline.
func _sink_deadline_ms() -> int:
	if profile_name == "play01_focus":
		return started_msec + PLAY01_FOCUS_WALL_MS
	if profile_name == "dev_smoke" and dev_smoke_t0 > 0:
		return dev_smoke_t0 + DEV_SMOKE_WALL_MS
	if profile_name == "baby_growth_revival":
		return started_msec + BABY_WALL_MS
	return 0


## Checked readback: the result must exist, decode as a JSON object, carry the profile/seed/
## deadline/step/ID accounting and agree with the totals just written. Only after this may a
## completion marker exist, so a zero exit is impossible without a complete decodable sink.
func _readback_ok(pass_n: int, fail_n: int, nr_n: int) -> bool:
	if sink_path.is_empty():
		return false
	var f := FileAccess.open(sink_path, FileAccess.READ)
	if f == null:
		printerr("ERROR: result readback could not open %s (%s)" % [
			sink_path, error_string(FileAccess.get_open_error())])
		return false
	var text := f.get_as_text()
	f.close()
	var decoded: Variant = JSON.parse_string(text)
	if not (decoded is Dictionary):
		printerr("ERROR: result readback is not a decodable JSON object: " + sink_path)
		return false
	var body := decoded as Dictionary
	if str(body.get("schema", "")) != "m01.1" \
			or str(body.get("kind", "")) != "junior_check_results":
		return false
	var totals: Variant = body.get("totals", null)
	if not (totals is Dictionary):
		return false
	var t := totals as Dictionary
	if int(t.get("pass", -1)) != pass_n or int(t.get("fail", -1)) != fail_n \
			or int(t.get("not_run", -1)) != nr_n:
		return false
	if not (body.get("results") is Array):
		return false
	if int((body.get("results") as Array).size()) != pass_n + fail_n + nr_n:
		return false
	if not checked_sink:
		return true
	var acct := _id_accounting()
	if str(body.get("profile", "")) != profile_name \
			or int(body.get("seed", -1)) != profile_seed:
		return false
	for key in ["deadline", "steps", "attempted_ids", "unattempted_ids", "duplicate_ids", "stop"]:
		if not body.has(key):
			printerr("ERROR: result readback is missing the %s section" % key)
			return false
	if not (body.get("deadline") is Dictionary) or not (body.get("steps") is Dictionary):
		return false
	if not (body.get("attempted_ids") is Array) or not (body.get("unattempted_ids") is Array):
		return false
	# RUN01 F01: _id_accounting() returns ID Arrays for these three keys, so compare the
	# decoded lists by .size(). int(Array) is not a supported conversion and never yields
	# the count; the Array-valued schema itself is unchanged.
	if (body.get("attempted_ids") as Array).size() != (acct["attempted"] as Array).size() \
			or (body.get("unattempted_ids") as Array).size() != (acct["unattempted"] as Array).size() \
			or (body.get("duplicate_ids") as Array).size() != (acct["duplicates"] as Array).size():
		return false
	return true


## Success completion marker: written only after a complete, decodable sink inside the profile
## deadline. Its absence is what turns a zero-exit run into a nonzero exit.
func _write_complete_marker(pass_n: int, fail_n: int, nr_n: int) -> bool:
	var dl := _sink_deadline_ms()
	# RUN01 F04: positive remainder is required, so an elapsed exactly equal to the window
	# (zero remainder) is already exhausted. The original clock origin is never renewed.
	if dl > 0 and Time.get_ticks_msec() >= dl:
		sink_late_reason = "profile deadline %dms exhausted before completion marker work" % dl
		printerr("ERROR: completion marker withheld; " + sink_late_reason)
		return false
	var marker_path := sink_path + ".complete.json"
	var body := {
		"schema": "m01.1",
		"kind": "junior_check_completion",
		"complete": true,
		"profile": profile_name,
		"seed": profile_seed,
		"result": sink_path.get_file(),
		"totals": {"pass": pass_n, "fail": fail_n, "not_run": nr_n},
		"written_utc": Time.get_datetime_string_from_system(true),
	}
	if not _write_file(marker_path, JSON.stringify(body, "\t")):
		return false
	# The file exists from here on, so it stays named as preserved evidence even when the
	# readback or the final deadline re-check refuses it.
	complete_marker = marker_path
	var f := FileAccess.open(marker_path, FileAccess.READ)
	if f == null:
		return false
	var back: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (back is Dictionary) or not bool((back as Dictionary).get("complete", false)):
		return false
	# RUN01 F04: re-check the SAME original deadline after the marker write/readback, so an
	# I/O crossing it cannot be reported as an on-time completion.
	if dl > 0 and Time.get_ticks_msec() >= dl:
		sink_late_reason = ("profile deadline %dms exhausted during completion marker "
			+ "write/readback") % dl
		printerr("ERROR: completion marker too late; " + sink_late_reason)
		return false
	return true


func _events_of_type(sim: M01Simulation, type_id: int) -> Array:
	var out: Array = []
	for e in sim.telemetry.events:
		if int(e[2]) == type_id:
			out.append(e)
	return out


## Same selection as _events_of_type, but each row is [absolute_tick, payload] so a chain can be
## correlated by tick as well as by ID without a second pass over the delta ticks.
func _events_with_tick(sim: M01Simulation, type_id: int) -> Array:
	var out: Array = []
	var acc := 0
	for e in sim.telemetry.events:
		acc += int(e[0])
		if int(e[2]) == type_id:
			out.append([acc, e[3]])
	return out


## Rows of `rows` whose payload index `idx` equals `want`, preserving order.
func _rows_with_field(rows: Array, idx: int, want: Variant) -> Array:
	var out: Array = []
	for row in rows:
		var p: Array = row[1]
		if p.size() > idx and p[idx] == want:
			out.append(row)
	return out


func _counts(sim: M01Simulation) -> Dictionary:
	return sim.telemetry.type_counts.duplicate(true)


# ------------------------------------------------------------------- suites

func _load_fixtures() -> Dictionary:
	var f := FileAccess.open("res://checks/fixtures.json", FileAccess.READ)
	if f == null:
		return {"ok": false, "reason": "cannot open res://checks/fixtures.json (%s)" %
			error_string(FileAccess.get_open_error()), "data": {}}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false, "reason": "fixtures.json is not a JSON object", "data": {}}
	var d := parsed as Dictionary
	if str(d.get("kind", "")) != "junior_bounded_fixtures":
		return {"ok": false, "reason": "fixtures.json kind is not junior_bounded_fixtures", "data": {}}
	return {"ok": true, "reason": "", "data": d}


## R-F03/QA-RES-F02 tiny development probe: bounded navigation fixtures plus at most
## DEV_SMOKE_MAX_TICKS logical ticks under one absolute DEV_SMOKE_WALL_MS deadline
## measured from probe start. The sim receives the exact remaining budget (never 0);
## an exhausted deadline stops the probe as visible noncompletion (D06 fail plus
## NOT RUN labels). Never runs the full suites.
## RUN01 fixed focused profile: the immutable16 selected records in the proposal's exact order.
## The C00 content gate was already emitted by `_initialize` before dispatch, so this profile
## yields exactly 16 case records plus C00. No seed override reaches it (every selected fixture
## pins seed3101 itself), no legacy suite runs alongside it, and C80 is never run before
## C81/C82 — they are separate extracted blocks, not the stats suite.
func _suite_play01_focus() -> void:
	if _focus_gate("C26-ordinary-movement"):
		_case_c26()
		_focus_end()
	if _focus_gate("C27-goal-production"):
		_case_c27()
		_focus_end()
	if _focus_gate("C28-corner-traversal"):
		_case_c28()
		_focus_end()
	if _focus_gate("C63-legal-connectors"):
		_case_c63()
		_focus_end()
	if _focus_gate("C64-static-stop-contact"):
		_case_c64()
		_focus_end()
	if _focus_gate("C53-lifecycle-correlation"):
		_case_c53()
		_focus_end()
	if _focus_gate("C54-quick-g14-boundaries"):
		_case_c54()
		_focus_end()
	if _focus_gate("C55-movement-action-state"):
		_case_c55(int(content.charge_ticks("brace")), int(content.recovery_ticks("brace")))
		_focus_end()
	if _focus_gate("C57-owning-intent-retirement"):
		_case_c57()
		_focus_end()
	if _focus_gate("C58-request-episode-divergence"):
		_case_c58()
		_focus_end()
	if _focus_gate("C59-quick-production-commit"):
		_case_c59()
		_focus_end()
	if _focus_gate("C65-brace-interrupt-exhaustion"):
		_case_c65()
		_focus_end()
	if _focus_gate("C49-npc-ingress-correlation"):
		_case_c49()
		_focus_end()
	if _focus_gate("C81-g12-utility-selection"):
		_case_c81()
		_focus_end()
	if _focus_gate("C82-m01-03-response-instinct-invariant"):
		_case_c82_response()
		_focus_end()
	if _focus_gate("C82-m01-03-skill-instinct-flip"):
		_case_c82_skill()
		_focus_end()


func _suite_dev_smoke(seed_v: int) -> void:
	# RUN01: capture this suite's own absolute window origin so the checked result sink cannot
	# outlive the probe it describes. Assertions and the window itself are unchanged.
	dev_smoke_t0 = Time.get_ticks_msec()
	var probe_t0 := Time.get_ticks_msec()
	_stage_enter("dev_smoke.fixtures")
	var fx := _load_fixtures()
	if not bool(fx["ok"]):
		_record("D00-fixtures-load", false, str(fx["reason"]))
		# RUN01: label every unreached D record NOT RUN, then keep the original early exit.
		_stop_gate("dev_smoke.fixtures")
		return
	var data: Dictionary = fx["data"]
	_record("D00-fixtures-load", true, "%d nav cases, %d corrupt-chain cases" % [
		(data.get("nav_cases", []) as Array).size(),
		(data.get("corrupt_chain_cases", []) as Array).size()])
	if _stop_gate("dev_smoke.fixtures"):
		return
	if _probe_gate("fixture load", probe_t0, [
			"D01-nav-fixtures", "D02-corrupt-chain-fails-closed",
			"D03-dev-tick-wall-budget", "D04-nav-work-budget",
			"D05-timeout-predicate", "D07-remaining-budget-oracle"]):
		return

	var nav_bad: Array = []
	var nav_cases: Array = data.get("nav_cases", [])
	var nav_total := nav_cases.size()
	var nav_done := 0
	var nav_pending := [
		"D02-corrupt-chain-fails-closed", "D03-dev-tick-wall-budget",
		"D04-nav-work-budget", "D05-timeout-predicate",
		"D07-remaining-budget-oracle"]
	for entry in nav_cases:
		# Before each item (covers every continue path back to this point).
		if _probe_exhausted("nav fixtures", probe_t0, nav_done, nav_total,
				"D01-nav-fixtures", nav_pending, nav_bad):
			return
		var c := entry as Dictionary
		var cid := str(c.get("id", "?"))
		var frm := [float((c["from"] as Array)[0]), float((c["from"] as Array)[1])]
		var to := [float((c["to"] as Array)[0]), float((c["to"] as Array)[1])]
		var blocked := {}
		if c.has("blocked_node"):
			blocked[int(c["blocked_node"])] = true
		var tree := arena.build_route_tree(frm, blocked)
		var route := arena.route_from_tree(tree, frm, to)
		var report: Dictionary = arena.last_search
		var expect_fail := str(c.get("expect_failure", ""))
		if expect_fail != "":
			var got := str(report.get("failure", ""))
			if not route.is_empty() or not got.begins_with(expect_fail):
				nav_bad.append("%s: expected closed failure '%s', got route=%d failure='%s'" % [
					cid, expect_fail, route.size(), got])
			nav_done += 1
			if _probe_exhausted("nav fixture outcome", probe_t0, nav_done, nav_total,
					"D01-nav-fixtures", nav_pending, nav_bad):
				return
			continue
		if route.is_empty():
			nav_bad.append("%s: empty route (failure '%s')" % [cid, str(report.get("failure", ""))])
			nav_done += 1
			if _probe_exhausted("nav fixture outcome", probe_t0, nav_done, nav_total,
					"D01-nav-fixtures", nav_pending, nav_bad):
				return
			continue
		if not _pt_eq(route[0], frm) or not _pt_eq(route[route.size() - 1], to):
			nav_bad.append("%s: endpoints not preserved" % cid)
		var chain: Array = route.slice(1, route.size() - 1)
		var seen := {}
		for p in chain:
			var key := str(p)
			if seen.has(key):
				nav_bad.append("%s: repeated chain node %s" % [cid, key])
				break
			seen[key] = true
		if c.has("expect_nodes"):
			var expect: Array = c["expect_nodes"]
			# RUN03-F01: expect_nodes is the INCLUSIVE graph node chain, not the trimmed
			# physical interior. Reconstruct it from the existing tree/parent data under the
			# same bounded contract route_from_tree already used: no second tree, no new API.
			var parent: Dictionary = tree.get("parent", {})
			var goal_id := arena.nearest_legal_node_id(float(to[0]), float(to[1]))
			var rec := M01Arena.reconstruct_chain(parent, goal_id,
				int(tree.get("start_id", -1)),
				mini(arena.cols * arena.rows, M01Arena.MAX_NAV_CHAIN))
			var incl: Array = rec.get("chain", [])
			var chain_ok := bool(rec["ok"]) and incl.size() == expect.size()
			if chain_ok:
				for i in expect.size():
					if int(incl[i]) != int(expect[i]):
						chain_ok = false
						break
			if not chain_ok:
				nav_bad.append("%s: chain %s != expected ids %s" % [cid, str(incl), str(expect)])
			elif route.size() != expect.size():
				nav_bad.append("%s: route %s != expected centers %s" % [
					cid, str(route), str(expect)])
			else:
				for i in expect.size():
					if not _pt_eq(route[i], arena.node_center(int(expect[i]))):
						nav_bad.append("%s: route %s != expected centers %s" % [
							cid, str(route), str(expect)])
						break
		var length := arena.route_length(route)
		if c.has("expect_length_mwu"):
			var want := float(c["expect_length_mwu"])
			if absf(length - want) > 1e-6:
				nav_bad.append("%s: length %.6f != expected %.6f" % [cid, length, want])
		if int(report.get("expansions", 0)) > 3840:
			nav_bad.append("%s: expansions %d > 3840" % [cid, int(report.get("expansions", 0))])
		for i in route.size():
			var p: Array = route[i]
			if not arena.center_legal(float(p[0]), float(p[1])) and i > 0 and i < route.size() - 1:
				nav_bad.append("%s: illegal interior point %s" % [cid, str(p)])
				break
		# After bounded item work, before the next iteration.
		nav_done += 1
		if _probe_exhausted("nav fixtures", probe_t0, nav_done, nav_total,
				"D01-nav-fixtures", nav_pending, nav_bad):
			return
	if _probe_exhausted("nav aggregate", probe_t0, nav_done, nav_total,
			"D01-nav-fixtures", nav_pending, nav_bad):
		return
	_record("D01-nav-fixtures", nav_bad.is_empty(),
		"all bounded nav cases finite, acyclic and within 3840 expansions" if nav_bad.is_empty()
			else "; ".join(nav_bad))
	if _stop_gate("dev_smoke.nav"):
		return
	if _probe_gate("nav fixtures", probe_t0, [
			"D02-corrupt-chain-fails-closed", "D03-dev-tick-wall-budget",
			"D04-nav-work-budget", "D05-timeout-predicate",
			"D07-remaining-budget-oracle"]):
		return

	_stage_enter("dev_smoke.corrupt-chain")
	var corrupt_bad: Array = []
	var corrupt_cases: Array = data.get("corrupt_chain_cases", [])
	var corrupt_total := corrupt_cases.size()
	var corrupt_done := 0
	var corrupt_pending := [
		"D03-dev-tick-wall-budget", "D04-nav-work-budget",
		"D05-timeout-predicate", "D07-remaining-budget-oracle"]
	for entry in corrupt_cases:
		# Before each item (covers every continue path back to this point).
		if _probe_exhausted("corrupt-chain fixtures", probe_t0, corrupt_done,
				corrupt_total, "D02-corrupt-chain-fails-closed", corrupt_pending, corrupt_bad):
			return
		var c2 := entry as Dictionary
		var parent := {}
		for k in (c2.get("parent", {}) as Dictionary):
			parent[int(k)] = int((c2["parent"] as Dictionary)[k])
		var rec := M01Arena.reconstruct_chain(parent, int(c2["goal"]), int(c2["start"]), 3840)
		if bool(rec["ok"]):
			corrupt_bad.append("%s: corrupt chain accepted" % str(c2.get("id", "?")))
			corrupt_done += 1
			if _probe_exhausted("corrupt-chain outcome", probe_t0, corrupt_done,
					corrupt_total, "D02-corrupt-chain-fails-closed", corrupt_pending, corrupt_bad):
				return
			continue
		var want2 := str(c2.get("expect_failure", ""))
		var got2 := str(rec["failure"])
		if not got2.begins_with(want2):
			corrupt_bad.append("%s: failure '%s' != expected '%s'" % [
				str(c2.get("id", "?")), got2, want2])
		# After bounded item work, before the next iteration.
		corrupt_done += 1
		if _probe_exhausted("corrupt-chain fixtures", probe_t0, corrupt_done,
				corrupt_total, "D02-corrupt-chain-fails-closed", corrupt_pending, corrupt_bad):
			return
	if _probe_exhausted("corrupt-chain aggregate", probe_t0, corrupt_done,
			corrupt_total, "D02-corrupt-chain-fails-closed", corrupt_pending, corrupt_bad):
		return
	_record("D02-corrupt-chain-fails-closed", corrupt_bad.is_empty(),
		"corrupt/invalid parents never manufacture a path" if corrupt_bad.is_empty()
			else "; ".join(corrupt_bad))
	if _stop_gate("dev_smoke.corrupt-chain"):
		return
	if _probe_gate("corrupt-chain fixtures", probe_t0, [
			"D03-dev-tick-wall-budget", "D04-nav-work-budget",
			"D05-timeout-predicate", "D07-remaining-budget-oracle"]):
		return

	_stage_enter("dev_smoke.sim")
	if _probe_gate("sim setup", probe_t0, [
			"D03-dev-tick-wall-budget", "D04-nav-work-budget",
			"D05-timeout-predicate", "D07-remaining-budget-oracle"]):
		return
	var seed_use := seed_v if seed_v > 0 else 3101
	var sim := _new_sim(seed_use, "live")
	# Recompute after setup: the sim receives the exact remainder, never 0.
	var budget_passed := _remaining_budget_ms(probe_t0)
	if not _remaining_ok(budget_passed):
		_probe_incomplete("absolute deadline exhausted before the sim",
			Time.get_ticks_msec() - probe_t0,
			["D03-dev-tick-wall-budget", "D04-nav-work-budget",
			"D05-timeout-predicate", "D07-remaining-budget-oracle"])
		return
	var t0 := Time.get_ticks_msec()
	var ticks := _run(sim, DEV_SMOKE_MAX_TICKS, Callable(), budget_passed)
	var elapsed := Time.get_ticks_msec() - t0
	var probe_elapsed := Time.get_ticks_msec() - probe_t0
	_record("D03-dev-tick-wall-budget",
		_dev_timeout_pass(last_run_timed_out, elapsed, budget_passed, probe_elapsed),
		"ticks=%d/%d internal_wall=%dms/%dms(remaining budget passed, never 0) probe_elapsed=%dms/%dms timed_out=%s ended=%s (development budget only, not a performance claim)" % [
			ticks, DEV_SMOKE_MAX_TICKS, elapsed, budget_passed,
			probe_elapsed, DEV_SMOKE_WALL_MS,
			str(last_run_timed_out), str(sim.ended)])
	if _stop_gate("dev_smoke.sim"):
		return
	_record("D04-nav-work-budget", sim.nav_violations == 0 and sim.nav_max_decision_expansions <= 3840,
		"searches=%d expansions=%d max_per_decision=%d violations=%d (budget <=1 search/actor/decision, <=3840 expansions)" % [
			sim.nav_searches, sim.nav_expansions, sim.nav_max_decision_expansions,
			sim.nav_violations])
	if _stop_gate("dev_smoke.sim"):
		return
	var timeout_st := _dev_timeout_selftest()
	var timeout_bad := timeout_st["bad"] as Array
	_record("D05-timeout-predicate", timeout_bad.is_empty(),
		"synthetic labeled scenarios (no engine timing): count=%d failing=[%s]" % [
			int(timeout_st["count"]), ", ".join(timeout_bad)])
	if _stop_gate("dev_smoke.predicates"):
		return
	var remaining_st := _remaining_oracle()
	var remaining_bad := remaining_st["bad"] as Array
	_record("D07-remaining-budget-oracle", remaining_bad.is_empty(),
		"synthetic labeled scenarios (absolute-deadline arithmetic, no engine timing): count=%d failing=[%s]" % [
			int(remaining_st["count"]), ", ".join(remaining_bad)])
	if _stop_gate("dev_smoke.predicates"):
		return
	var final_elapsed := Time.get_ticks_msec() - probe_t0
	if final_elapsed > DEV_SMOKE_WALL_MS:
		_record("D06-probe-timeout", false,
			"dev_smoke exceeded its internal %dms budget before done (elapsed %dms); probe not completed" % [
				DEV_SMOKE_WALL_MS, final_elapsed])
	else:
		_record("D06-probe-timeout", true,
			"absolute %dms deadline held across fixtures, nav, corrupt-chain, sim and oracles (elapsed %dms)" % [
				DEV_SMOKE_WALL_MS, final_elapsed])
	_stage_enter("dev_smoke.done")


func _suite_smoke(seed_v: int) -> void:
	var seed_use := seed_v if seed_v > 0 else 3101
	var sim := _new_sim(seed_use, "live")
	var seq := {0: 0}
	var policy := func(s: M01Simulation) -> void:
		if s.tick % 60 == 30:
			seq[0] = int(seq[0]) + 1
			var family := 1 + (int(seq[0]) % 3)
			_stage(s, 0, family, int(seq[0]), s.tick)
	var ticks := _run(sim, 10800, policy)
	var summary := sim.summary()
	var c := _counts(sim)
	var detail := "seed=%d ticks=%d end=%s ko=%s requests=%d responses=%d starts=%d hits=%d events=%d" % [
		seed_use, ticks, str(summary["end_reason"]), str(summary["ko_actors"]),
		int(c.get(1, 0)), int(c.get(3, 0)), int(c.get(6, 0)), int(c.get(11, 0)),
		sim.telemetry.events.size()]
	var ended_ok := str(summary["end_reason"]) != "in_progress" and ticks < 10800
	var activity_ok := int(c.get(1, 0)) > 0 and int(c.get(3, 0)) > 0 and int(c.get(6, 0)) > 0
	_record("C01-live-encounter", ended_ok, detail)
	_record("C02-live-activity", activity_ok,
		"human requests=%d responses=%d action_starts=%d" % [int(c.get(1, 0)),
			int(c.get(3, 0)), int(c.get(6, 0))])
	sim.telemetry.close_footer(summary, true)
	var res := sim.telemetry.prepare_bundle()
	var bundle_ok := bool(res.get("ok", false))
	_record("C03-bundle-prepare", bundle_ok, str(res))
	if bundle_ok:
		var text := (sim.telemetry.prepared_bytes as PackedByteArray).get_string_from_utf8()
		var dec := M01Telemetry.decode_bundle(text)
		_record("C04-bundle-decode", bool(dec["ok"]) and (dec["errors"] as Array).is_empty(),
			"header=%s footer=%s events=%d errors=%d" % [
				dec["header"] != null, dec["footer"] != null, (dec["events"] as Array).size(),
				(dec["errors"] as Array).size()])


func _suite_contracts() -> void:
	var t := M01Telemetry.new()
	var g := M01Gateway.new()
	var actor := _fresh_actor(0)
	var actors := [actor, _fresh_actor(1)]
	var owner := {0: 0, 1: 1}
	var base := {"schema": "m01.1", "trainer": 0, "actor": 0, "sequence": 1, "slot": 0,
		"family": 1, "target_kind": 0, "target_or_area": null, "observed_tick": 0}

	var bad: Array = []
	var m1 := base.duplicate(true)
	m1["schema"] = "nope"
	if str(g.validate(m1, 10, actors, owner).get("reason", "")) != "envelope":
		bad.append("bad schema not rejected as envelope")
	var m2 := base.duplicate(true)
	m2["trainer"] = 1
	if str(g.validate(m2, 10, actors, owner).get("reason", "")) != "ownership":
		bad.append("foreign trainer not rejected as ownership")
	var m3 := base.duplicate(true)
	m3["slot"] = 7
	if str(g.validate(m3, 10, actors, owner).get("reason", "")) != "slot":
		bad.append("empty slot not rejected as slot")
	var m4 := base.duplicate(true)
	m4["sequence"] = 1
	var first := g.validate(m4, 10, actors, owner)
	var second := g.validate(m4, 10, actors, owner)
	if not bool(first.get("ok", false)) or str(second.get("reason", "")) != "sequence":
		bad.append("duplicate sequence handling wrong")
	var m5 := base.duplicate(true)
	m5["target_kind"] = 0
	m5["target_or_area"] = [1, 2]
	if str(g.validate(m5, 10, actors, owner).get("reason", "")) != "hint":
		bad.append("target hint with kind 0 not rejected")
	actors[0]["alive"] = false
	var m6 := base.duplicate(true)
	m6["sequence"] = 99
	if str(g.validate(m6, 10, actors, owner).get("reason", "")) != "life":
		bad.append("dead actor not rejected as life")
	actors[0]["alive"] = true
	actors[0]["control_mode"] = 1
	var m7 := base.duplicate(true)
	m7["sequence"] = 100
	if str(g.validate(m7, 10, actors, owner).get("reason", "")) != "control":
		bad.append("locked actor not rejected as control")
	_record("C10-gateway-rejects", bad.is_empty(),
		"all reject reasons correct" if bad.is_empty() else "; ".join(bad))

	var slots_ok := true
	var labels: Array = content.tuning["slots"]["labels"]
	var filled: Array = content.tuning["slots"]["filled"]
	if labels.size() != 8 or filled.size() != 3:
		slots_ok = false
	for i in 3:
		if str(labels[i]) != ["Attack", "Defense", "Run"][i]:
			slots_ok = false
	for i in range(3, 8):
		if str(labels[i]) != "Empty":
			slots_ok = false
	_record("C11-slot-contract", slots_ok and int(content.tuning["slots"]["total"]) == 8,
		"8 slots, 3 filled Attack/Defense/Run, 5 empty")

	var timeout_ok := int(content.tuning["timeout_active_ticks"]) == 10800 \
			and int(content.tuning["tick_rate"]) == 60
	_record("C12-watchdog-tickrate", timeout_ok,
		"tick_rate=%d timeout=%d" % [int(content.tuning["tick_rate"]),
			int(content.tuning["timeout_active_ticks"])])

	var stream_ok := true
	var seen := {}
	for sname in ["response.side0", "response.side1", "monster.side0", "monster.side1",
			"trainer.side1"]:
		if seen.has(sname):
			stream_ok = false
		seen[sname] = true
	var sim := _new_sim(3101, "live")
	var hexes := {}
	for sname in ["response.side0", "response.side1", "monster.side0", "monster.side1",
			"trainer.side1"]:
		hexes[sname] = sim.stream_seed_hex(sname)
		if (str(hexes[sname]) as String).length() != 64:
			stream_ok = false
	_record("C13-rng-streams", stream_ok and seen.size() == 5,
		"5 streams, m01-seed-1 derivation, 64-hex seeds")

	t = null


func _fresh_actor(idx: int) -> Dictionary:
	var sim := _new_sim(3101, "live")
	return sim.actors[idx]


func _pt_eq(a: Variant, b: Variant, eps: float = 1e-6) -> bool:
	if not (a is Array) or not (b is Array):
		return false
	if (a as Array).size() < 2 or (b as Array).size() < 2:
		return false
	return absf(float((a as Array)[0]) - float((b as Array)[0])) <= eps \
		and absf(float((a as Array)[1]) - float((b as Array)[1])) <= eps


func _dist(a: Array, b: Array) -> float:
	return sqrt(pow(float(b[0]) - float(a[0]), 2.0) + pow(float(b[1]) - float(a[1]), 2.0))


## Pins a move goal on one actor and freezes the planner: next_plan_tick is pushed past
## the run and the stored plan watch matches the live view, so only _execute_goal runs.
func _force_move_goal(sim: M01Simulation, idx: int, point: Array,
		purpose: String = "approach") -> void:
	var a: Dictionary = sim.actors[idx]
	var start := [float(a["x"]), float(a["y"])]
	a["goal"] = {"kind": "move", "point": [float(point[0]), float(point[1])],
		"route": arena.path_between(start, point), "stop_mwu": 0.0,
		"purpose": purpose, "patrol_index": -1, "i": 0}
	a["next_plan_tick"] = 1000000
	sim.plan_watch[idx] = sim._plan_watch(a)


## Applies exactly one boundary of movement from a labelled start to a labelled goal under a
## given action state, then reports what actually happened: [applied_displacement,
## moved_this_boundary]. QA-F06 wants this observed movement, not a Boolean helper alone.
func _one_boundary_move(sim: M01Simulation, idx: int, from_p: Array, to_p: Array,
		action: Variant) -> Array:
	var a: Dictionary = sim.actors[idx]
	a["x"] = float(from_p[0])
	a["y"] = float(from_p[1])
	a["action"] = action
	a["bound_active"] = false
	_force_move_goal(sim, idx, to_p)
	var before: Array = [float(a["x"]), float(a["y"])]
	sim._movement_cut()
	var after: Array = [float(a["x"]), float(a["y"])]
	return [_dist(before, after), bool(a["moved_this_boundary"]), float(after[0]),
		float(after[1])]


func _suite_geometry() -> void:
	var bad: Array = []

	if not arena.center_legal(4000.0, 3000.0):
		bad.append("spawn0 not legal")
	if not arena.center_legal(16000.0, 3000.0):
		bad.append("spawn1 not legal")
	if arena.center_legal(10000.0, 6000.0):
		bad.append("blocker centre reported legal")
	if arena.in_inflated_blocker(8500.0, 6000.0):
		pass
	else:
		bad.append("inflated boundary not covered")
	if arena.center_legal(400.0, 6000.0):
		bad.append("outside inset reported legal")
	# Strict inset boundaries: legal band is inset ± GUARD, exclusive of the wall itself.
	if arena.center_legal(499.99, 1000.0):
		bad.append("x=499.99 reported legal")
	if arena.center_legal(500.0, 1000.0):
		bad.append("x=500.0 reported legal (GUARD inside wall)")
	if not arena.center_legal(500.01, 1000.0):
		bad.append("x=500.01 reported illegal")
	if not arena.center_legal(19499.99, 1000.0):
		bad.append("x=19499.99 reported illegal")
	if arena.center_legal(19500.01, 1000.0):
		bad.append("x=19500.01 reported legal")
	if arena.center_legal(1000.0, 499.99):
		bad.append("y=499.99 reported legal")
	if not arena.center_legal(1000.0, 500.01):
		bad.append("y=500.01 reported illegal")
	if not arena.center_legal(1000.0, 11499.99):
		bad.append("y=11499.99 reported illegal")
	if arena.center_legal(1000.0, 11500.01):
		bad.append("y=11500.01 reported legal")
	_record("C20-static-legality", bad.is_empty(),
		"spawns legal, blocker/inset illegal" if bad.is_empty() else "; ".join(bad))

	var frac := M01Arena.earliest_contact([4000.0, 3000.0], [4050.0, 3000.0],
		[5050.0, 3000.0], [5000.0, 3000.0], 1000.0)
	var frac_swap := M01Arena.earliest_contact([5050.0, 3000.0], [5000.0, 3000.0],
		[4000.0, 3000.0], [4050.0, 3000.0], 1000.0)
	var contact_ok := absf(frac - 0.5) < 1e-6 and absf(frac - frac_swap) < 1e-9
	_record("C21-swept-contact", contact_ok,
		"head-on contact fraction %.6f (expected 0.5), side-swap %.9f (equal=%s)"
			% [frac, frac_swap, str(absf(frac - frac_swap) < 1e-9)])

	# Blocked ray runs east through the inflated blocker at y=6000; open ray runs east below it.
	var blocked_ray := arena.clip_static([4000.0, 6000.0], [20000.0, 6000.0])
	var open_ray := arena.clip_static([4000.0, 3000.0], [20000.0, 3000.0])
	var tunnel_ok := float(blocked_ray[0]) <= 8499.999 + 1e-6 \
		and float(blocked_ray[0]) > 8000.0 and absf(float(blocked_ray[1]) - 6000.0) < 1e-9 \
		and float(open_ray[0]) >= 19499.999 - 1e-6 and absf(float(open_ray[1]) - 3000.0) < 1e-9
	_record("C22-static-no-tunnel", tunnel_ok,
		"blocked y6000 stops x=%.6f (<= bx0-GUARD 8499.999); open y3000 reaches x=%.6f"
			% [float(blocked_ray[0]), float(open_ray[0])])

	var los_blocked := not arena.line_of_effect(3000.0, 6000.0, 17000.0, 6000.0)
	var los_open := arena.line_of_effect(4000.0, 3000.0, 16000.0, 3000.0)
	_record("C23-line-of-effect", los_blocked and los_open,
		"through-blocker blocked=%s, open sightline clear=%s" % [los_blocked, los_open])

	var route := arena.path_between([4000.0, 3000.0], [16000.0, 9000.0])
	var route_ok := not route.is_empty()
	if route_ok:
		for i in route.size() - 1:
			var p: Array = route[i]
			if not arena.center_legal(float(p[0]), float(p[1])):
				route_ok = false
				break
	_record("C24-pathfinding", route_ok,
		"route points=%d, all legal=%s" % [route.size(), route_ok])

	var travel_ok := true
	var sb := content.skill("short_bound")
	if int(sb["travel_mwu_per_tick"]) * int(sb["travel_boundaries"]) != int(sb["max_travel_mwu"]):
		travel_ok = false
	_record("C25-bound-travel-budget", travel_ok,
		"%d mWU/tick × %d boundaries = %d mWU" % [int(sb["travel_mwu_per_tick"]),
			int(sb["travel_boundaries"]), int(sb["max_travel_mwu"])])

	_case_c26()

	_case_c27()

	_case_c28()

	_case_c63()

	_case_c64()


func _goal_schema_ok(goal: Variant, ar: M01Arena) -> Array:
	var errs: Array = []
	if not (goal is Dictionary):
		return ["goal is not a Dictionary"]
	var g := goal as Dictionary
	var kind := str(g.get("kind", ""))
	if not (kind in ["move", "rest"]):
		errs.append("kind=" + kind)
	if not (g.get("stop_mwu", null) is float) or float(g.get("stop_mwu", 0.0)) < 0.0:
		errs.append("stop_mwu invalid")
	if not (g.get("i", null) is int) or int(g.get("i", 0)) < 0:
		errs.append("i invalid")
	if not (g.get("patrol_index", null) is int) or int(g.get("patrol_index", -1)) < -1:
		errs.append("patrol_index invalid")
	var purpose := str(g.get("purpose", ""))
	if not (purpose in ["approach", "disengage", "search", "patrol", "bound", "rest"]):
		errs.append("purpose=" + purpose)
	var point: Variant = g.get("point", null)
	var route: Variant = g.get("route", null)
	if kind == "rest":
		if point != null:
			errs.append("rest goal has a point")
		if not (route is Array) or not (route as Array).is_empty():
			errs.append("rest goal has a route")
		return errs
	if not (point is Array) or (point as Array).size() != 2:
		errs.append("point is not a scalar pair")
	elif not _pt_eq(point, point) or not is_finite(float((point as Array)[0])) \
			or not is_finite(float((point as Array)[1])):
		errs.append("point is not finite")
	if not (route is Array) or (route as Array).size() < 2:
		errs.append("route has fewer than 2 points")
	else:
		for p in route as Array:
			if not (p is Array) or (p as Array).size() != 2:
				errs.append("route point is not a scalar pair")
				break
			if not is_finite(float(p[0])) or not is_finite(float(p[1])):
				errs.append("route point is not finite")
				break
			if not ar.center_legal(float(p[0]), float(p[1])):
				errs.append("route point illegal at [%s, %s]" % [str(p[0]), str(p[1])])
				break
		if int(g.get("i", 0)) >= (route as Array).size():
			errs.append("i beyond route")
	return errs


func _suite_response() -> void:
	# G-10: isolated response/deadline function, INT 20 vs 80, Bond 50, p=F=0
	var r: Dictionary = content.tuning["response"]
	var cases := [
		{"int": 20, "d": 36, "q": 0.20, "c": 0.55, "mid": 0.56},
		{"int": 80, "d": 18, "q": 0.05, "c": 0.85, "mid": 0.1925},
	]
	var bad: Array = []
	for cs in cases:
		var i_val := float(cs["int"]) / 100.0
		var raw_d := float(r["deadline_base"]) + float(r["deadline_int_weight"]) * i_val \
				+ float(r["deadline_bond_weight"]) * 0.50
		var d := int(ceil(float(r["deadline_scale"]) * clampf(raw_d,
			float(r["deadline_min"]), float(r["deadline_max"]))))
		if d != int(cs["d"]):
			bad.append("INT%d deadline %d != %d" % [cs["int"], d, cs["d"]])
		var c := clampf(float(r["understood_base"]) + float(r["understood_int_weight"]) * i_val
				+ float(r["understood_bond_weight"]) * 0.50,
			float(r["understood_min"]), float(r["understood_max"]))
		if absf(c - float(cs["c"])) > 1e-6:
			bad.append("INT%d c %.6f != %.6f" % [cs["int"], c, cs["c"]])
		var q := clampf(0.25 * (1.0 - i_val), 0.0, float(r["ignore_max"]))
		if absf(q - float(cs["q"])) > 1e-6:
			bad.append("INT%d q %.6f != %.6f" % [cs["int"], q, cs["q"]])
		var mid := q + (1.0 - q) * (1.0 - c)
		if absf(mid - float(cs["mid"])) > 1e-4:
			bad.append("INT%d understood interval %.6f != %.6f" % [cs["int"], mid, cs["mid"]])
	_record("C30-g10-response-formula", bad.is_empty(),
		"deadline/understood/ignore match G3 §10" if bad.is_empty() else "; ".join(bad))

	# G-11: Instinct must not enter response or deadline.
	var s0 := _new_sim(3101, "diagnostic")
	s0.actors[0]["int_stat"] = 50
	s0.actors[0]["instinct"] = 20
	s0.actors[0]["bond"] = 50
	var d20 := _response_probe(s0, 0, 0.30)
	var s1 := _new_sim(3101, "diagnostic")
	s1.actors[0]["int_stat"] = 50
	s1.actors[0]["instinct"] = 80
	s1.actors[0]["bond"] = 50
	var d80 := _response_probe(s1, 0, 0.30)
	var same := str(d20) == str(d80)
	_record("C31-g11-instinct-isolated", same,
		"Instinct 20 vs 80 identical response: %s" % same)

	# G-18 damage function.
	var dmg1 := _damage(1800, 200, 25, 10000)
	var dmg2 := _damage(1, 100, 100, 10000)
	var dmg3 := _damage(1800, 100, 25, 10000)
	var dmg4 := _damage(1800, 100, 25, 3500)
	var dmg_ok := dmg1 == 2880 and dmg2 == 1 and dmg3 == 1440 and dmg4 == 504
	_record("C32-g18-damage", dmg_ok,
		"ATK200/DEF25=%d, rounding .5→%d, baseline=%d, brace=%d" % [dmg1, dmg2, dmg3, dmg4])


func _damage(base_power: int, atk: int, def_stat: int, brace_bp: int) -> int:
	var offensive := float(base_power) * float(atk) / 100.0
	var raw := offensive * 100.0 / float(100 + maxi(0, def_stat))
	raw = raw * float(brace_bp) / 10000.0
	return int(floor(raw + 0.5))


func _response_probe(sim: M01Simulation, actor_idx: int, uniform: float) -> String:
	sim.forced_uniforms["response.%d" % actor_idx] = [uniform]
	_stage(sim, 0, 1, 1, 0)
	_pstep(sim)
	var out := "no-episode"
	for i in 60:
		_pstep(sim)
		var a: Dictionary = sim.actors[actor_idx]
		var ev := _events_of_type(sim, 3)
		if not ev.is_empty():
			var last: Array = ev[ev.size() - 1]
			out = str(last[3])
			break
	return out


func _suite_behavior() -> void:
	# G-15 defense contexts by explicit geometry. Escape needs a >=1000 mWU gain route,
	# so the reason also depends on where the walls clip the four authored directions:
	# escape  — open field, away ray keeps ~2400 mWU of separation;
	# hold    — corner, every direction gains < 1000 and d <= 1600;
	# neutral — corner, every direction gains < 1000 and 1600 < d <= 2500;
	# guard   — d > 2500 (escape_max), rest with no candidates.
	var bad: Array = []
	var fit_reasons: Array = M01Telemetry.DICTIONARIES["fit_reason"]
	var contexts := [
		{"name": "C40-escape", "self_p": [4000.0, 3000.0], "foe": [5000.0, 3000.0],
			"expect": "escape", "fits": {"brace": 0.25, "short_bound": 0.90},
			"goal": "move", "cands": ["brace", "short_bound"], "escape_ok": true},
		{"name": "C40-hold", "self_p": [1250.0, 600.0], "foe": [2250.0, 1600.0],
			"expect": "hold_ground", "fits": {"brace": 0.90, "short_bound": 0.25},
			"goal": "move", "cands": ["brace", "short_bound"], "escape_ok": false},
		{"name": "C40-neutral", "self_p": [1250.0, 600.0], "foe": [2950.0, 2300.0],
			"expect": "neutral_defense", "fits": {"brace": 0.50, "short_bound": 0.50},
			"goal": "move", "cands": ["brace", "short_bound"], "escape_ok": false},
		{"name": "C40-guard", "self_p": [4000.0, 3000.0], "foe": [7000.0, 3000.0],
			"expect": "guard", "fits": {}, "goal": "rest", "cands": [], "escape_ok": false},
	]
	for ctx in contexts:
		var sim := _new_sim(3101, "diagnostic")
		var a: Dictionary = sim.actors[0]
		var e: Dictionary = sim.actors[1]
		sim.actors[0]["x"] = float((ctx["self_p"] as Array)[0])
		sim.actors[0]["y"] = float((ctx["self_p"] as Array)[1])
		sim.actors[1]["x"] = float((ctx["foe"] as Array)[0])
		sim.actors[1]["y"] = float((ctx["foe"] as Array)[1])
		sim.actors[1]["hp"] = 6000
		sim.actors[0]["enemy_visible"] = true
		sim.actors[0]["accepted_intent"] = {"intent": 1, "episode": 1, "family": 2,
			"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
			"target_or_area": null, "goal": null}
		sim._refresh_gates(sim.actors[0])
		sim._refresh_gates(sim.actors[1])
		var plan: Dictionary = sim.behavior.plan(a, e, 0, "visible")
		var reason := str(plan.get("fit_reason", ""))
		if reason != str(ctx["expect"]):
			bad.append("%s reason=%s expected %s" % [ctx["name"], reason, ctx["expect"]])
		var cands: Array = plan.get("candidates", [])
		var want_cands: Array = ctx["cands"]
		if JSON.stringify(cands) != JSON.stringify(want_cands):
			bad.append("%s candidates=%s expected %s" % [ctx["name"], cands, want_cands])
		var fits: Dictionary = plan.get("fits", {})
		var want_fits: Dictionary = ctx["fits"]
		if JSON.stringify(fits) != JSON.stringify(want_fits):
			bad.append("%s fits=%s expected %s" % [ctx["name"], fits, want_fits])
		for sid in fits:
			if not want_fits.has(sid) or absf(float(fits[sid]) - float(want_fits[sid])) > 1e-9:
				bad.append("%s fit %s=%s" % [ctx["name"], sid, str(fits[sid])])
		var goal: Variant = plan.get("goal", null)
		if not (goal is Dictionary) or str((goal as Dictionary).get("kind", "")) != str(ctx["goal"]):
			bad.append("%s goal=%s expected %s" % [ctx["name"], str(goal), ctx["goal"]])
		if not fit_reasons.has(reason):
			bad.append("%s fit_reason %s absent from M01Telemetry.DICTIONARIES" % [ctx["name"], reason])
		if str(ctx["goal"]) == "rest":
			if not ((goal as Dictionary).get("route", []) as Array).is_empty():
				bad.append("%s rest goal carries a route" % ctx["name"])
		else:
			var g_route: Array = (goal as Dictionary).get("route", [])
			if g_route.size() < 2:
				bad.append("%s move goal route has %d points" % [ctx["name"], g_route.size()])
			if str((goal as Dictionary).get("purpose", "")) != "bound":
				bad.append("%s purpose=%s expected bound" % [ctx["name"],
					str((goal as Dictionary).get("purpose", ""))])
			# The same self position as plan() reuses the cached route tree (key includes
			# decision_id and self position), so this second evaluation adds no A* rebuild
			# and no decision_violation.
			var esc: Dictionary = sim.behavior.best_escape_bound(a, ctx["foe"])
			if bool(ctx["escape_ok"]) and esc.is_empty():
				bad.append("%s no authored direction gains >= 1000 mWU" % ctx["name"])
			if not bool(ctx["escape_ok"]) and not esc.is_empty():
				bad.append("%s escape option gains %.3f mWU in a non-escape context"
					% [ctx["name"], float(esc["gain"])])
		# G3 distance bands must agree with the reported reason.
		var dx := float((ctx["foe"] as Array)[0]) - float((ctx["self_p"] as Array)[0])
		var dy := float((ctx["foe"] as Array)[1]) - float((ctx["self_p"] as Array)[1])
		var d := sqrt(dx * dx + dy * dy)
		var tune: Dictionary = content.tuning["defense_fit"]
		if reason == "guard" and d <= float(tune["escape_max_distance_mwu"]):
			bad.append("%s guard at d=%.1f" % [ctx["name"], d])
		if reason == "neutral_defense" and not (d > float(tune["hold_max_distance_mwu"])
				and d <= float(tune["escape_max_distance_mwu"])):
			bad.append("%s neutral outside (1600,2500]: d=%.1f" % [ctx["name"], d])
		if reason in ["escape", "hold_ground"] and d > float(tune["escape_max_distance_mwu"]):
			bad.append("%s %s beyond escape_max: d=%.1f" % [ctx["name"], reason, d])
		if reason == "hold_ground" and d > float(tune["hold_max_distance_mwu"]):
			bad.append("%s hold beyond hold_max: d=%.1f" % [ctx["name"], d])
	# Oracle correction (documented): with an open away ray the escape route always keeps
	# ~2400 mWU, so d=1601 is escape, not neutral/hold.
	var far := [
		{"d": 1600.0, "expect_any": ["escape"]},
		{"d": 1601.0, "expect_any": ["escape"]},
		{"d": 2500.0, "expect_any": ["escape"]},
		{"d": 2501.0, "expect_any": ["guard"]},
	]
	for ctx in far:
		var sim := _new_sim(3101, "diagnostic")
		sim.actors[0]["x"] = 4000.0
		sim.actors[0]["y"] = 3000.0
		sim.actors[1]["x"] = 4000.0 + float(ctx["d"])
		sim.actors[1]["y"] = 3000.0
		sim.actors[1]["hp"] = 6000
		sim.actors[0]["enemy_visible"] = true
		sim.actors[0]["accepted_intent"] = {"intent": 1, "episode": 1, "family": 2,
			"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
			"target_or_area": null, "goal": null}
		sim._refresh_gates(sim.actors[0])
		sim._refresh_gates(sim.actors[1])
		var plan: Dictionary = sim.behavior.plan(sim.actors[0], sim.actors[1], 0, "visible")
		var reason := str(plan.get("fit_reason", ""))
		if not (reason in (ctx["expect_any"] as Array)):
			bad.append("d=%d reason=%s not in %s" % [int(ctx["d"]), reason, ctx["expect_any"]])
	_record("C40-g15-defense-fit", bad.is_empty(),
		"4 geometry contexts + open-field distance bands correct" if bad.is_empty() else "; ".join(bad))

	# Defense must actually start a legal technique (candidate selection wired).
	var sim := _new_sim(3101, "diagnostic")
	sim.actors[0]["x"] = 4000.0
	sim.actors[0]["y"] = 3000.0
	sim.actors[1]["x"] = 5000.0
	sim.actors[1]["y"] = 3000.0
	sim.actors[1]["hp"] = 6000
	sim.actors[0]["enemy_visible"] = true
	sim.actors[0]["accepted_intent"] = {"intent": 1, "episode": 1, "family": 2,
		"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
		"target_or_area": null, "goal": null}
	sim._refresh_gates(sim.actors[0])
	var started := false
	for i in 40:
		sim.step()
		if sim.actors[0]["action"] != null or sim.actors[0]["bound_active"] \
				or int(sim.actors[0]["brace_action"]) >= 0:
			started = true
			break
	_record("C41-defense-technique-start", started,
		"Defense intent starts Brace/Bound within 40 ticks: %s" % started)

	# Autonomous behaviour with no commands must act (M01-01 no-input case).
	var auto := _new_sim(3101, "live")
	var act_ticks := 0
	for i in 600:
		auto.step()
		if auto.actors[0]["action"] != null or auto.actors[0]["bound_active"] \
				or int(auto.actors[0]["brace_action"]) >= 0 or auto.actors[0]["moved_this_boundary"]:
			act_ticks += 1
	_record("C42-autonomous-action", act_ticks > 0,
		"actor0 acted on %d/600 ticks with no trainer input" % act_ticks)

	# Pressure/cadence: repeated same-key requests are bounded and credited (G-08 shape).
	var p := _new_sim(3101, "diagnostic")
	var seq := 0
	for t in range(1, 21):
		seq += 1
		_stage(p, 0, 1, seq, t)
		p.step()
	var pressure: int = p.actors[0]["pressure"]
	var episodes := _events_of_type(p, 3).size()
	_record("C43-g08-pressure-bounded", pressure <= 240 and pressure > 0,
		"after 20 same-key requests pressure=%d (cap 240), responses=%d" % [pressure, episodes])

	_case_c53()

	_case_c54()

	_case_c55(int(content.charge_ticks("brace")), int(content.recovery_ticks("brace")))

	# C44 forced approach (actor 0) and disengage (actor 1) routes on both sides:
	# legal scalar positions, MOV/60 per boundary, no Bound travel, each side leaves spawn.
	var liv := _new_sim(3101, "diagnostic")
	_force_move_goal(liv, 0, [7000.0, 3000.0])
	_force_move_goal(liv, 1, [17000.0, 3000.0])
	var spawn: Array = [[float(liv.actors[0]["x"]), float(liv.actors[0]["y"])],
		[float(liv.actors[1]["x"]), float(liv.actors[1]["y"])]]
	var prev: Array = [[float(spawn[0][0]), float(spawn[0][1])],
		[float(spawn[1][0]), float(spawn[1][1])]]
	var max_step := 0.0
	var legal := true
	var bound_seen := false
	for i in 120:
		liv.step()
		if liv.ended:
			break
		for k in 2:
			var np: Array = [float(liv.actors[k]["x"]), float(liv.actors[k]["y"])]
			max_step = maxf(max_step, _dist(prev[k], np))
			if not arena.center_legal(float(np[0]), float(np[1])):
				legal = false
			if bool(liv.actors[k]["bound_active"]):
				bound_seen = true
			prev[k] = np
	var off0 := _dist(spawn[0], prev[0])
	var off1 := _dist(spawn[1], prev[1])
	_record("C44-route-movement",
		legal and not bound_seen and max_step <= 50.001 + 1e-6 and off0 > 50.0 and off1 > 50.0,
		"spawn offsets %.0f/%.0f mWU, max per-tick step %.4f (limit 50), legal=%s, bound_active=%s" % [
			off0, off1, max_step, legal, bound_seen])

	# C45 search lifecycle: (a) goals reached under the token grow search_visited,
	# (b) centre then probes in authored order for J>=0.5, (c) one lawful early
	# "complete" end for the same token, (d) a new observation clears the visited sets.
	var s4 := _new_sim(3101, "diagnostic")
	var a4: Dictionary = s4.actors[0]
	a4["x"] = 16000.0
	a4["y"] = 3000.0
	a4["enemy_visible"] = false
	a4["memory_valid"] = true
	a4["memory_x"] = 16000.0
	a4["memory_y"] = 3000.0
	a4["memory_last_seen_tick"] = s4.tick
	a4["memory_expiry"] = s4.tick + 480
	a4["memory_token"] = 9
	a4["instinct"] = 80
	a4["search_active"] = true
	a4["search_start"] = s4.tick
	a4["search_deadline"] = s4.tick + 360
	a4["search_visited"] = []
	var want_probes: Array = [[17000.0, 3000.0], [15000.0, 3000.0],
		[16000.0, 4000.0], [16000.0, 2000.0]]
	var goals: Array = s4.behavior.search_goals(a4)
	var order_ok := goals.size() == 5 and _pt_eq(goals[0], [16000.0, 3000.0])
	if order_ok:
		for i in 4:
			if not _pt_eq(goals[i + 1], want_probes[i]):
				order_ok = false
				break
	for g in goals:
		a4["search_visited"].append(g)
	var empty_after := s4.behavior.search_goals(a4).is_empty()
	s4._expire_intervals(a4)
	var complete_ev := _events_of_type(s4, 17)
	var reason_ok := false
	if not complete_ev.is_empty():
		var last17: Array = complete_ev[complete_ev.size() - 1]
		reason_ok = str((last17[3] as Array)[3]) == "end" \
			and str((last17[3] as Array)[5]) == "complete" \
			and int((last17[3] as Array)[2]) == 9
	var ended_ok := not bool(a4["search_active"]) \
		and bool(a4["search_token_exhausted"].get("9", false))
	# (a) walking the first goal appends it to search_visited before the deadline.
	var s4a := _new_sim(3101, "diagnostic")
	var a4a: Dictionary = s4a.actors[0]
	a4a["x"] = 4000.0
	a4a["y"] = 3000.0
	s4a.actors[1]["x"] = 19000.0
	s4a.actors[1]["y"] = 11000.0
	a4a["enemy_visible"] = false
	a4a["memory_valid"] = true
	a4a["memory_x"] = 6000.0
	a4a["memory_y"] = 3000.0
	a4a["memory_last_seen_tick"] = 0
	a4a["memory_expiry"] = 100000
	a4a["instinct"] = 80
	a4a["search_active"] = true
	a4a["search_start"] = 0
	a4a["search_deadline"] = 360
	a4a["search_visited"] = []
	var grew := false
	for i in 120:
		s4a.step()
		if not (a4a["search_visited"] as Array).is_empty():
			grew = true
			break
	# (d) a fresh observation bumps the token and empties both visited sets.
	var s4d := _new_sim(3101, "diagnostic")
	var a4d: Dictionary = s4d.actors[0]
	a4d["x"] = 4000.0
	a4d["y"] = 3000.0
	s4d.actors[1]["x"] = 5000.0
	s4d.actors[1]["y"] = 3000.0
	a4d["enemy_visible"] = false
	a4d["search_visited"] = [[4500.0, 3000.0]]
	a4d["patrol_visited"] = [0, 1]
	var tok_before := int(a4d["memory_token"])
	s4d._update_vision_and_search()
	var cleared := (a4d["search_visited"] as Array).is_empty() \
		and (a4d["patrol_visited"] as Array).is_empty() \
		and int(a4d["memory_token"]) == tok_before + 1 \
		and bool(a4d["enemy_visible"])
	_record("C45-search-lifecycle",
		order_ok and empty_after and ended_ok and reason_ok and grew and cleared,
		"centre+4 probes order=%s, goals exhausted=%s, early complete=%s, walked=%s, token bump cleared=%s" % [
			order_ok, empty_after, reason_ok, grew, cleared])

	# C56 FIX01/5 — Instinct below/above 0.5 search shape, once-per-token visit filtering,
	# the equal-distance patrol tie fixture (10000,3000), strictly-positive disengage gain,
	# and rest when no lawful positive option exists.
	var g7_bad: Array = []
	var g7 := _new_sim(3101, "diagnostic")
	var g7a: Dictionary = g7.actors[0]
	g7a["x"] = 16000.0
	g7a["y"] = 3000.0
	g7a["enemy_visible"] = false
	g7a["memory_valid"] = true
	g7a["memory_x"] = 16000.0
	g7a["memory_y"] = 3000.0
	g7a["memory_last_seen_tick"] = 0
	g7a["memory_expiry"] = 100000
	g7a["memory_token"] = 5
	g7a["search_active"] = false
	g7a["search_visited"] = []
	g7a["patrol_visited"] = []
	var g7_probe: Array = content.tuning["vision"]["search_probe_offsets_mwu"]
	var g7_centre: Array = [16000.0, 3000.0]

	# J = 0.20 (< 0.5): centre plus ONE authored patrol point, never a +-1000 probe.
	g7a["instinct"] = 20
	var g7lo: Array = g7.behavior.search_goals(g7a)
	if g7lo.size() != 2 or not _pt_eq(g7lo[0], g7_centre) or not _pt_eq(g7lo[1], [12000.0, 3000.0]):
		g7_bad.append("J20 search_goals %s != [centre, [12000,3000]]" % str(g7lo))
	for g7k in g7_probe.size():
		if g7lo.size() > 1 and _pt_eq(g7lo[1],
				[float(g7_centre[0]) + float((g7_probe[g7k] as Array)[0]),
				float(g7_centre[1]) + float((g7_probe[g7k] as Array)[1])]):
			g7_bad.append("J20 offered probe %s instead of a patrol token" % str(g7lo[1]))
	# Once per token: low-J offers centre plus ONE authored patrol point, so a consumed
	# centre+patrol pair exhausts the search sequence instead of chaining to the next
	# patrol point, and exhausting both sets yields no goal at all.
	g7a["search_visited"] = [g7_centre, [12000.0, 3000.0]]
	var g7lo2: Array = g7.behavior.search_goals(g7a)
	if not g7lo2.is_empty():
		g7_bad.append("J20 after centre+[12000,3000] visited -> %s != [] (one patrol per token)" % str(g7lo2))
	g7a["search_visited"] = [g7_centre, [12000.0, 3000.0], [12000.0, 9000.0],
		[8000.0, 3000.0], [8000.0, 9000.0]]
	var g7lo3: Array = g7.behavior.search_goals(g7a)
	if not g7lo3.is_empty():
		g7_bad.append("J20 with every token goal visited still returned %s" % str(g7lo3))

	# J = 0.80 (>= 0.5): centre plus the four authored probe offsets, in authored order.
	g7a["instinct"] = 80
	g7a["search_visited"] = []
	var g7hi: Array = g7.behavior.search_goals(g7a)
	var g7hi_ok := g7hi.size() == 5
	if g7hi_ok:
		for g7m in 4:
			var g7p: Array = [float(g7_centre[0]) + float((g7_probe[g7m] as Array)[0]),
				float(g7_centre[1]) + float((g7_probe[g7m] as Array)[1])]
			if not _pt_eq(g7hi[g7m + 1], g7p):
				g7hi_ok = false
				break
	if not g7hi_ok:
		g7_bad.append("J80 search_goals %s != centre + 4 probes in authored order" % str(g7hi))

	# Equal-distance patrol tie: (10000,3000) is 2000 from both index0 and index1, so the
	# smaller authored index wins.
	var g7t := _new_sim(3101, "diagnostic")
	var g7ta: Dictionary = g7t.actors[0]
	g7ta["x"] = 10000.0
	g7ta["y"] = 3000.0
	g7ta["patrol_visited"] = []
	var g7tg: Array = g7t.behavior.patrol_goals(g7ta)
	if g7tg.is_empty() or not _pt_eq(g7tg[0], [8000.0, 3000.0]):
		g7_bad.append("tie at (10000,3000) chose %s != [8000,3000]" % str(
			g7tg[0] if not g7tg.is_empty() else []))

	# Ordinary disengagement needs STRICTLY positive gain; zero and negative gains must be
	# rejected, and a boxed-in actor with no lawful option rests instead of travelling.
	var g7_best0: Dictionary = g7.behavior._best_from([{"gain": 0.0}, {"gain": -5.0}], 1e-9)
	var g7_best1: Dictionary = g7.behavior._best_from([{"gain": 0.0}, {"gain": 3.0}], 1e-9)
	if not g7_best0.is_empty():
		g7_bad.append("_best_from(zero,negative) returned %s instead of empty" % str(g7_best0))
	if g7_best1.is_empty() or absf(float(g7_best1["gain"]) - 3.0) > 1e-9:
		g7_bad.append("_best_from(zero,positive) returned %s != the gain-3 option" % str(g7_best1))
	var g7r := _new_sim(3101, "diagnostic")
	var g7ra: Dictionary = g7r.actors[0]
	g7ra["x"] = 600.0
	g7ra["y"] = 600.0
	g7ra["stam"] = 4000
	g7r.actors[1]["x"] = 19000.0
	g7r.actors[1]["y"] = 11000.0
	g7r._refresh_gates(g7ra)
	var g7dp: Dictionary = g7r.behavior._disengage_plan(g7ra, [19000.0, 11000.0], "visible")
	var g7dp_goal: Variant = g7dp.get("goal", null)
	if str(g7dp.get("fit_reason", "")) != "rest" or not (g7dp_goal is Dictionary) \
			or str((g7dp_goal as Dictionary).get("kind", "")) != "rest":
		g7_bad.append("boxed-in disengage fit=%s goal=%s != rest/rest" % [
			str(g7dp.get("fit_reason", "")), str(g7dp_goal)])
	# GP-F03/QA-F03: the deadline path must assert the real token/goal/OWNING-INTENT transition,
	# retiring only the fallback that owns it and never a newer waiting intent.
	var g7goal := {"kind": "move", "point": [8000.0, 3000.0],
		"route": [[4000.0, 3000.0], [8000.0, 3000.0]], "stop_mwu": 0.0,
		"purpose": "search", "patrol_index": -1, "i": 0}
	var g7d := _new_sim(3101, "diagnostic")
	var g7da: Dictionary = g7d.actors[0]
	g7da["x"] = 4000.0
	g7da["y"] = 3000.0
	g7da["goal"] = g7goal.duplicate(true)
	g7da["search_active"] = true
	g7da["search_deadline"] = g7d.tick
	g7da["memory_token"] = 3
	g7da["next_plan_tick"] = 15
	g7da["accepted_intent"] = {"intent": 7, "episode": 2, "request": 5, "family": 1,
		"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
		"target_or_area": null, "goal": null, "observation_category": "attack"}
	g7da["cycle_intent"] = 7
	g7da["cycle_request"] = 5
	g7da["cycle_episode"] = 2
	g7d._expire_intervals(g7da)
	var g7_d17: Array = _events_of_type(g7d, 17)
	if g7da["goal"] != null or int(g7da["next_plan_tick"]) != 0:
		g7_bad.append("deadline left goal=%s next_plan=%d != null/0" % [
			str(g7da["goal"]), int(g7da["next_plan_tick"])])
	if g7da["accepted_intent"] != null or int(g7da["cycle_intent"]) != -1 \
			or int(g7da["cycle_request"]) != 0 or int(g7da["cycle_episode"]) != 0:
		g7_bad.append("owning fallback not retired: accepted=%s cycle %d/%d/%d" % [
			str(g7da["accepted_intent"]), int(g7da["cycle_intent"]),
			int(g7da["cycle_request"]), int(g7da["cycle_episode"])])
	if g7_d17.is_empty() or str((g7_d17[0][3] as Array)[3]) != "end" \
			or str((g7_d17[0][3] as Array)[5]) != "timeout":
		g7_bad.append("search deadline events=%d end=%s reason=%s != end/timeout" % [
			g7_d17.size(), str((g7_d17[0][3] as Array)[3]) if not g7_d17.is_empty() else "",
			str((g7_d17[0][3] as Array)[5]) if not g7_d17.is_empty() else ""])
	# Newer waiting J under an older I cycle: only the stale goal is dropped and planning
	# reopens; I keeps ownership and J keeps its original expiry.
	var g7e := _new_sim(3101, "diagnostic")
	var g7ea: Dictionary = g7e.actors[0]
	g7ea["x"] = 4000.0
	g7ea["y"] = 3000.0
	g7ea["goal"] = g7goal.duplicate(true)
	g7ea["search_active"] = true
	g7ea["search_deadline"] = g7e.tick
	g7ea["memory_token"] = 3
	g7ea["next_plan_tick"] = 15
	g7ea["accepted_intent"] = {"intent": 8, "episode": 4, "request": 9, "family": 1,
		"accepted_tick": 1, "expiry_tick": 500, "state": "active", "target_kind": 0,
		"target_or_area": null, "goal": null, "observation_category": "attack"}
	g7ea["cycle_intent"] = 7
	g7ea["cycle_request"] = 5
	g7ea["cycle_episode"] = 2
	g7ea["recovery_owner"] = 7
	g7ea["recovery_end"] = g7e.tick + 15
	g7ea["action"] = {"action": 9, "actor": 0, "skill": "quick_claw", "state": "recovering",
		"start_tick": 0, "due_tick": 0, "recovery_ticks": 21}
	g7e._expire_intervals(g7ea)
	var g7_j: Variant = g7ea["accepted_intent"]
	if g7ea["goal"] != null or int(g7ea["next_plan_tick"]) != 0:
		g7_bad.append("stale search goal kept: goal=%s next_plan=%d != null/0" % [
			str(g7ea["goal"]), int(g7ea["next_plan_tick"])])
	if not (g7_j is Dictionary) or int((g7_j as Dictionary).get("intent", -1)) != 8 \
			or int((g7_j as Dictionary).get("expiry_tick", -1)) != 500 \
			or int(g7ea["cycle_intent"]) != 7 or int(g7ea["cycle_request"]) != 5 \
			or int(g7ea["cycle_episode"]) != 2:
		g7_bad.append("newer waiting J lost: accepted=%s cycle %d/%d/%d != intent8/expiry500 and owner7/5/2" % [
			str(g7_j), int(g7ea["cycle_intent"]), int(g7ea["cycle_request"]),
			int(g7ea["cycle_episode"])])
	_record("C56-search-fallback",
		g7_bad.is_empty(),
		"J20 centre+one patrol token then sequence exhaustion, J80 centre+4 probes, tie (10000,3000)->[8000,3000], strictly-positive gain only, boxed-in disengage rests, deadline retires its owning fallback and preserves newer waiting J"
			if g7_bad.is_empty() else str(g7_bad))

	_case_c57()

	_case_c58()

	_case_c59()

	_case_c65()

	# C46 Run and Defense never offer Claw (G3 §7/§8), and a Run intent never starts one.
	var claw_bad: Array = []
	var geoms: Array = [
		{"self_p": [4000.0, 3000.0], "foe": [5000.0, 3000.0]},
		{"self_p": [4000.0, 3000.0], "foe": [7000.0, 3000.0]},
		{"self_p": [1250.0, 600.0], "foe": [2250.0, 1600.0]},
		{"self_p": [1250.0, 600.0], "foe": [2950.0, 2300.0]},
		{"self_p": [4000.0, 3000.0], "foe": [10000.0, 3000.0]},
	]
	for g in geoms:
		for fam in [2, 3]:
			var csim := _new_sim(3101, "diagnostic")
			var self_a: Dictionary = csim.actors[0]
			var foe: Dictionary = csim.actors[1]
			self_a["x"] = float((g["self_p"] as Array)[0])
			self_a["y"] = float((g["self_p"] as Array)[1])
			foe["x"] = float((g["foe"] as Array)[0])
			foe["y"] = float((g["foe"] as Array)[1])
			foe["hp"] = 6000
			self_a["enemy_visible"] = true
			self_a["accepted_intent"] = {"intent": 1, "episode": 1, "family": fam,
				"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
				"target_or_area": null, "goal": null}
			csim._refresh_gates(self_a)
			csim._refresh_gates(foe)
			var sp: Array = [float(self_a["x"]), float(self_a["y"])]
			var ep: Array = [float(foe["x"]), float(foe["y"])]
			var dd := _dist(sp, ep)
			var runs: Array = [
				csim.behavior.plan(self_a, foe, 0, "visible"),
				csim.behavior._run_plan(self_a, foe, 0, true, sp, ep, "visible"),
				csim.behavior._defense_plan(self_a, foe, 0, true, dd, sp, ep, "visible"),
			]
			for pl in runs:
				if (pl.get("candidates", []) as Array).has("quick_claw") \
						or str(pl.get("skill", "")) == "quick_claw":
					claw_bad.append("fam%d at (%d,%d)" % [fam,
						int((g["self_p"] as Array)[0]), int((g["self_p"] as Array)[1])])
	var rn := _new_sim(3101, "diagnostic")
	rn.actors[0]["x"] = 4000.0
	rn.actors[0]["y"] = 3000.0
	rn.actors[1]["x"] = 5000.0
	rn.actors[1]["y"] = 3000.0
	rn.actors[1]["hp"] = 6000
	rn.actors[0]["enemy_visible"] = true
	rn.actors[0]["accepted_intent"] = {"intent": 1, "episode": 1, "family": 3,
		"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
		"target_or_area": null, "goal": null}
	rn._refresh_gates(rn.actors[0])
	rn._refresh_gates(rn.actors[1])
	for i in 120:
		rn.step()
	var claw_started := false
	for e in _events_of_type(rn, 6):
		if int((e[3] as Array)[1]) == 0 and str((e[3] as Array)[4]) == "quick_claw":
			claw_started = true
	_record("C46-run-never-claw", claw_bad.is_empty() and not claw_started,
		"%d geometry/family combinations offer Claw=%s; claw started in 120 ticks=%s" % [
			5 * 2 * 3, not claw_bad.is_empty(), claw_started])

	# C47 hidden pursuit targets the frozen memory point, never the live enemy; with no
	# memory the same Run intent rests instead of reaching for hidden coordinates.
	var mem_a := _new_sim(3101, "diagnostic")
	var ma: Dictionary = mem_a.actors[0]
	ma["x"] = 4000.0
	ma["y"] = 3000.0
	mem_a.actors[1]["x"] = 16000.0
	mem_a.actors[1]["y"] = 3000.0
	ma["enemy_visible"] = false
	ma["memory_valid"] = true
	ma["memory_x"] = 12000.0
	ma["memory_y"] = 9000.0
	ma["memory_last_seen_tick"] = 0
	ma["memory_expiry"] = 100000
	mem_a._refresh_gates(ma)
	mem_a._refresh_gates(mem_a.actors[1])
	var mem_plan: Dictionary = mem_a.behavior.plan(ma, mem_a.actors[1], 0, "last_known")
	var mem_goal: Variant = mem_plan.get("goal", null)
	var target_ok := false
	var no_live := false
	if mem_goal is Dictionary and str((mem_goal as Dictionary).get("kind", "")) == "move":
		var rt: Array = (mem_goal as Dictionary).get("route", [])
		if not rt.is_empty() and _pt_eq((mem_goal as Dictionary).get("point", null),
				[12000.0, 9000.0]):
			var endp: Array = rt[rt.size() - 1]
			target_ok = _dist(endp, [12000.0, 9000.0]) <= 2500.0 \
				and absf(float(endp[0]) - 12000.0) < 2500.0
			no_live = _dist(endp, [16000.0, 3000.0]) > 2500.0
	var no_mem := _new_sim(3101, "diagnostic")
	var na: Dictionary = no_mem.actors[0]
	na["x"] = 4000.0
	na["y"] = 3000.0
	no_mem.actors[1]["x"] = 16000.0
	no_mem.actors[1]["y"] = 3000.0
	na["enemy_visible"] = false
	na["memory_valid"] = false
	na["accepted_intent"] = {"intent": 1, "episode": 1, "family": 3,
		"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
		"target_or_area": null, "goal": null}
	no_mem._refresh_gates(na)
	no_mem._refresh_gates(no_mem.actors[1])
	var rest_plan: Dictionary = no_mem.behavior.plan(na, no_mem.actors[1], 0, "unknown")
	var rest_ok := str(rest_plan.get("fit_reason", "")) == "rest" \
		and rest_plan.get("goal", null) is Dictionary \
		and str((rest_plan.get("goal", {}) as Dictionary).get("kind", "")) == "rest"
	var frozen_a := _frozen_run_plan(9000.0, 6000.0, 4000.0, 3000.0)
	var frozen_b := _frozen_run_plan(9000.0, 6000.0, 17500.0, 10500.0)
	var frozen_same := JSON.stringify(frozen_a) == JSON.stringify(frozen_b)
	_record("C47-frozen-memory", target_ok and no_live and rest_ok and frozen_same,
		"goal targets memory=%s, clear of live enemy=%s, no-memory rests=%s, plan invariant=%s" % [
			target_ok, no_live, rest_ok, frozen_same])

	# C48 NPC pending-response protection with exactly one credited hesitant repeat.
	var h := _new_sim(3101, "diagnostic")
	h.actors[1]["int_stat"] = 20
	h.actors[1]["bond"] = 50
	h.actors[1]["fatigue_centi"] = 0
	h.actors[1]["pressure"] = 0
	h.forced_uniforms["response.1"] = [0.95]
	h.actors[1]["npc"]["next_decision_tick"] = 1000000
	_stage(h, 1, 1, 1, 1)
	var saw_hesitant := false
	for i in 120:
		h.step()
		var hep: Variant = h.actors[1]["response_episode"]
		if hep is Dictionary and int((hep as Dictionary).get("class", -1)) == 4 \
				and not bool((hep as Dictionary).get("draw_resolved", true)):
			saw_hesitant = true
			break
	# Decision 1: the still-pending hesitant same-key request may repeat exactly once.
	h.actors[1]["npc"]["next_decision_tick"] = h.tick + 1
	h.step()
	var repeat_queued: Variant = h.actors[1]["npc"]["queued"]
	var repeated_flag := bool(h.actors[1]["npc"]["repeated_episode"])
	# Let that repeat submit (12 ticks) and the episode resolve into an active intent.
	for i in 16:
		h.step()
	var drained: Variant = h.actors[1]["npc"]["queued"]
	var intent_active: bool = h.actors[1]["accepted_intent"] != null
	# Decision 2: same family as the active accepted intent -> held, nothing queued.
	h.actors[1]["npc"]["next_decision_tick"] = h.tick + 1
	h.step()
	var held_queued: Variant = h.actors[1]["npc"]["queued"]
	for i in 14:
		h.step()
	var dec23 := _events_of_type(h, 23).size()
	var sub24 := _events_of_type(h, 24).size()
	# Decision 3: episode resolved (class 5) and no active intent -> queues normally.
	h.actors[1]["accepted_intent"] = null
	var eps: Variant = h.actors[1]["response_episode"]
	if eps is Dictionary:
		var eps_d: Dictionary = eps
		eps_d["class"] = 5
		eps_d["draw_resolved"] = true
	h.actors[1]["npc"]["next_decision_tick"] = h.tick + 1
	h.step()
	var final_queued: Variant = h.actors[1]["npc"]["queued"]
	var dec23_after := _events_of_type(h, 23).size()
	var hold_ok := saw_hesitant and repeat_queued != null and repeated_flag \
		and drained == null and intent_active and held_queued == null \
		and dec23 == 2 and sub24 == 1 and final_queued != null and dec23_after == 3
	_record("C48-npc-hesitant-repeat-once", hold_ok,
		"hesitant=%s repeat queued=%s repeat flagged=%s queue drained=%s intent=%s second held=%s decisions=%d submissions=%d resolved queued=%s decisions=%d" % [
			saw_hesitant, repeat_queued != null, repeated_flag, drained == null,
			intent_active, held_queued == null, dec23, sub24,
			final_queued != null, dec23_after])

	_case_c49()


func _first_tick(sim: M01Simulation, type_id: int, which: int = 0) -> int:
	var acc := 0
	var seen := 0
	for ev in sim.telemetry.events:
		acc += int(ev[0])
		if int(ev[2]) == type_id:
			if seen >= which:
				return acc
			seen += 1
	return -1


func _frozen_run_plan(mem_x: float, mem_y: float, foe_x: float, foe_y: float) -> Dictionary:
	var s := _new_sim(3101, "diagnostic")
	var a: Dictionary = s.actors[0]
	var e: Dictionary = s.actors[1]
	a["x"] = 4000.0
	a["y"] = 3000.0
	a["enemy_visible"] = false
	a["memory_valid"] = true
	a["memory_x"] = mem_x
	a["memory_y"] = mem_y
	a["memory_last_seen_tick"] = 0
	a["memory_expiry"] = 100000
	a["accepted_intent"] = {"intent": 1, "episode": 1, "family": 3,
		"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
		"target_or_area": null, "goal": null}
	e["x"] = foe_x
	e["y"] = foe_y
	s._refresh_gates(a)
	s._refresh_gates(e)
	return s.behavior.plan(a, e, 0, "last_known")


func _suite_hidden() -> void:
	# Paired hidden worlds: identical permitted observation and identical NPC decisions
	# until actor 1 reacquires the hidden opponent. The mutated state is the observer's
	# opponent (b.actors[0]); b.actors[1] (the observer's own state) is never touched.
	# Contact implies visibility: contact range 1000 sits far inside vision 8000, so the
	# break on enemy_visible always fires first and no tick is silently skipped. hp 4321
	# keeps the mutated enemy above the 25% autonomous gate, and while out of vision the
	# observer's plan never reads hp, so the other side stays on the same plan branch.
	# QA-F03: the hidden opponent's PRIVATE cooldowns are varied too — cooldowns are never
	# part of a permitted observation, so this stays outside sensing with no observable
	# interaction on the observer's own state, memory or queues.
	var a := _new_sim(3101, "live")
	var b := _new_sim(3101, "live")
	b.actors[0]["hp"] = 4321
	b.actors[0]["x"] = float(b.actors[0]["x"]) + 250.0
	b.actors[0]["cooldown_end"]["quick_claw"] = int(b.actors[0]["cooldown_end"]["quick_claw"]) + 7
	b.actors[0]["cooldown_end"]["brace"] = int(b.actors[0]["cooldown_end"]["brace"]) + 11
	b.actors[0]["cooldown_end"]["short_bound"] = int(b.actors[0]["cooldown_end"]["short_bound"]) + 3
	var hidden_differs := int(a.actors[0]["hp"]) != int(b.actors[0]["hp"]) \
		and absf(float(a.actors[0]["x"]) - float(b.actors[0]["x"])) > 0.0 \
		and int(a.actors[0]["cooldown_end"]["quick_claw"]) != int(b.actors[0]["cooldown_end"]["quick_claw"]) \
		and int(a.actors[0]["cooldown_end"]["brace"]) != int(b.actors[0]["cooldown_end"]["brace"]) \
		and int(a.actors[0]["cooldown_end"]["short_bound"]) != int(b.actors[0]["cooldown_end"]["short_bound"])
	var divergent := ""
	var own_ok := true
	var compared := 0
	for t in range(1, 301):
		if a.actors[1]["enemy_visible"] or b.actors[1]["enemy_visible"]:
			break      # reacquisition ends the comparison successfully
		var obs_a: Dictionary = a.observe_for(1)
		var obs_b: Dictionary = b.observe_for(1)
		compared += 1
		if JSON.stringify(obs_a["own"]) != JSON.stringify(obs_b["own"]):
			own_ok = false
			divergent = "own state differed at tick %d" % t
			break
		if JSON.stringify(obs_a) != JSON.stringify(obs_b):
			divergent = "observation differed at tick %d" % t
			break
		a.step()
		b.step()
	var last_cmp := a.tick - 1      # last tick whose observation was compared
	var same_dec := JSON.stringify(_npc_trace(a, last_cmp)) \
		== JSON.stringify(_npc_trace(b, last_cmp))
	var same_sub := JSON.stringify(_npc_submits(a, last_cmp)) \
		== JSON.stringify(_npc_submits(b, last_cmp))
	# QA-F03: empty equal traces must not satisfy the oracle — the compared interval has to
	# contain at least one real production decision and one delayed submission.
	var dec_count := _npc_trace(a, last_cmp).size()
	var sub_count := _npc_submits(a, last_cmp).size()
	_record("C50-hidden-world-pair",
		divergent == "" and own_ok and hidden_differs and compared >= 30 and same_dec and same_sub \
			and dec_count > 0 and sub_count > 0,
		"%s; compared=%d own identical=%s hidden differs=%s npc decisions same=%s submissions same=%s decisions=%d submissions=%d" % [
			divergent if divergent != "" else "identical until reacquisition",
			compared, own_ok, hidden_differs, same_dec, same_sub, dec_count, sub_count])

	# Memory expiry rule: last-seen + 480 (QA G-09 clarification).
	var s := _new_sim(3101, "diagnostic")
	s.actors[0]["memory_valid"] = true
	s.actors[0]["memory_last_seen_tick"] = 100
	s.actors[0]["memory_expiry"] = 580
	s.tick = 579
	s._expire_intervals(s.actors[0])
	var still := bool(s.actors[0]["memory_valid"])
	s.tick = 580
	s._expire_intervals(s.actors[0])
	var gone := not bool(s.actors[0]["memory_valid"])
	_record("C51-g09-memory-expiry", still and gone,
		"expiry=last_seen+480=580; valid at 579=%s, expired at 580=%s" % [still, gone])

	# Search deadline: search start + 360, no extension by stale repeats.
	var s2 := _new_sim(3101, "diagnostic")
	s2.actors[0]["memory_valid"] = true
	s2.actors[0]["memory_token"] = 7
	s2.actors[0]["search_active"] = true
	s2.actors[0]["search_start"] = 120
	s2.actors[0]["search_deadline"] = 480
	s2.tick = 480
	s2._expire_intervals(s2.actors[0])
	var timed_out := not bool(s2.actors[0]["search_active"])
	var token_blocked: bool = s2.actors[0]["search_token_exhausted"].get("7", false)
	_record("C52-g09-search-deadline", timed_out and token_blocked,
		"search deadline enforced at 480=%s, token exhausted=%s" % [timed_out, token_blocked])


func _npc_trace(sim: M01Simulation, max_obs_tick: int = 1000000) -> Array:
	var out: Array = []
	for e in _events_of_type(sim, 23):
		var pay: Array = e[3]
		if int(pay[1]) <= max_obs_tick:
			out.append(pay)
	return out


func _npc_submits(sim: M01Simulation, max_tick: int) -> Array:
	var out: Array = []
	for e in _events_of_type(sim, 24):
		var pay: Array = e[3]
		if int(pay[2]) <= max_tick:
			out.append(pay)
	return out


func _suite_authority() -> void:
	var fixture := {
		"id": "diag.control_lock",
		"control_locks": [{"at_tick": 50, "actor": 0, "mode": 1}],
		"state": {"0": {"hp": 7777, "stam": 3333, "control_mode": 0}},
	}
	var locked := _new_sim(3101, "diagnostic", fixture)
	var baseline := _new_sim(3101, "diagnostic")
	baseline.actors[0]["hp"] = 7777
	baseline.actors[0]["stam"] = 3333
	var seq := {0: 0}
	var rejected := 0
	var accepted := 0
	for t in range(1, 201):
		if t % 20 == 5:
			seq[0] = int(seq[0]) + 1
			_stage(locked, 0, 1, int(seq[0]), t)
		if t % 20 == 7:
			seq[0] = int(seq[0]) + 1
			_stage(baseline, 0, 1, int(seq[0]), t)
		locked.step()
		baseline.step()
	var mode_val := int(locked.actors[0]["control_mode"])
	rejected = locked.telemetry.type_counts.get(2, 0)
	accepted = baseline.telemetry.type_counts.get(1, 0)
	var pressure_after: int = locked.actors[0]["pressure"]
	_record("C60-authority-lock", mode_val == 1 and rejected > 0 and accepted > 0,
		"lock mode=%d, rejections=%d, baseline accepted requests=%d" % [
			mode_val, rejected, accepted])
	_record("C61-lock-no-side-effects", pressure_after == 0,
		"locked actor pressure=%d (must stay 0)" % pressure_after)
	var preserved := int(locked.actors[0]["hp"]) == 7777 and int(locked.actors[0]["stam"]) <= 3333
	_record("C62-lock-preserves-identity", preserved,
		"HP=%d STAM=%d preserved/no refill" % [int(locked.actors[0]["hp"]),
			int(locked.actors[0]["stam"])])


func _suite_telemetry(seed_v: int) -> void:
	var seed_use := seed_v if seed_v > 0 else 3101
	var run_a := _live_bundle(seed_use, 400)
	var run_b := _live_bundle(seed_use, 400)
	var same := str(run_a["sha"]) == str(run_b["sha"])
	_record("C70-same-environment-repeat", same,
		"seed %d two runs sha equal=%s (%s vs %s)" % [seed_use, same,
			str(run_a["sha"]).left(12), str(run_b["sha"]).left(12)])

	# Close-range companion run: same seed, both bodies inside Claw range so impacts (11)
	# actually occur and the reconciliation covers a non-empty combat stream.
	var close_run := _live_bundle(seed_use, 400, true)
	var dec: Dictionary = close_run["decode"]
	var footer: Dictionary = dec["footer"]
	var counts: Dictionary = footer.get("event_counts_by_type", {})
	var events: Array = dec["events"]
	var rec: Array = _footer_reconciles(footer, events)
	var counts_nonzero := int(counts.get("1", 0)) > 0 and int(counts.get("11", 0)) > 0

	# Corruption controls: each single-foot error must be caught by the same reconciler.
	var ctrl_ok := true
	var f_inc: Dictionary = footer.duplicate(true)
	var c_inc: Dictionary = f_inc.get("event_counts_by_type", {})
	if not c_inc.has("1"):
		ctrl_ok = false
	else:
		c_inc["1"] = int(c_inc["1"]) + 1
		f_inc["event_counts_by_type"] = c_inc
		if bool(_footer_reconciles(f_inc, events)[0]):
			ctrl_ok = false
	var ev_swap: Array = events.duplicate(true)
	if ev_swap.size() < 2:
		ctrl_ok = false
	else:
		var tmp_ev: Variant = ev_swap[ev_swap.size() - 1][1]
		ev_swap[ev_swap.size() - 1][1] = ev_swap[ev_swap.size() - 2][1]
		ev_swap[ev_swap.size() - 2][1] = tmp_ev
		if bool(_footer_reconciles(footer, ev_swap)[0]):
			ctrl_ok = false
	var f_part: Dictionary = footer.duplicate(true)
	f_part["completeness"] = "partial"
	if bool(_footer_reconciles(f_part, events)[0]):
		ctrl_ok = false
	_record("C71-footer-reconciliation",
		bool(rec[0]) and ctrl_ok and counts_nonzero,
		"reconcile=%s detail=%s corrupt-controls=%s type1=%s type11=%s" % [
			str(rec[0]), str(rec[1]), ctrl_ok,
			str(counts.get("1", 0)), str(counts.get("11", 0))])

	var rates_ok := float(footer.get("queue_peak", 0)) <= 4096.0 \
			and float(close_run["bytes"]) <= 8388608.0
	_record("C72-telemetry-budgets", rates_ok,
		"queue_peak=%s bytes=%d (limits 4096 / 8MiB)" % [str(footer.get("queue_peak")),
			int(close_run["bytes"])])

	var seed_once := true
	var header: Dictionary = dec["header"]
	if str(header.get("root_seed", "")) != str(seed_use):
		seed_once = false
	_record("C73-header-identities", seed_once and str(header.get("schema")) == "m01.1",
		"root_seed=%s schema=%s content_hashes=%d" % [str(header.get("root_seed")),
			str(header.get("schema")), (header.get("content_hashes", {}) as Dictionary).size()])


func _live_bundle(seed_v: int, ticks: int, close_range: bool = false) -> Dictionary:
	var sim := _new_sim(seed_v, "live")
	if close_range:
		sim.actors[1]["x"] = 5600.0
		sim.actors[1]["y"] = 3000.0
	var seq := {0: 0}
	for t in range(1, ticks + 1):
		if t % 45 == 20:
			seq[0] = int(seq[0]) + 1
			_stage(sim, 0, 1 + (int(seq[0]) % 3), int(seq[0]), t)
		sim.step()
		if sim.ended:
			break
	var summary := sim.summary()
	sim.telemetry.close_footer(summary, true)
	var res := sim.telemetry.prepare_bundle()
	var text := ""
	if bool(res.get("ok", false)):
		text = (sim.telemetry.prepared_bytes as PackedByteArray).get_string_from_utf8()
	var sha := text.sha256_text()
	return {"sha": sha, "bytes": (sim.telemetry.prepared_bytes as PackedByteArray).size(),
		"decode": M01Telemetry.decode_bundle(text), "summary": summary}


## Footer vs stream reconciliation. Decoded footer keys are Strings (JSON objects), so
## every lookup below is String-keyed; returns [ok, detail].
func _footer_reconciles(footer: Dictionary, events: Array) -> Array:
	var detail: Array = []
	var counts: Dictionary = footer.get("event_counts_by_type", {})
	var summary: Dictionary = footer.get("summary", {})
	if int(counts.get("1", 0)) != int(summary.get("requests", 0)):
		detail.append("type1=%d summary.requests=%d" % [
			int(counts.get("1", 0)), int(summary.get("requests", 0))])
	if int(counts.get("11", 0)) != int(summary.get("impact_records", 0)):
		detail.append("type11=%d summary.impact_records=%d" % [
			int(counts.get("11", 0)), int(summary.get("impact_records", 0))])
	if str(footer.get("completeness")) != "complete":
		detail.append("completeness=%s" % str(footer.get("completeness")))
	var last_seq := int(events[events.size() - 1][1]) if not events.is_empty() else -1
	if last_seq != int(footer.get("last_sequence", -2)):
		detail.append("stream last_sequence=%d footer=%d" % [
			last_seq, int(footer.get("last_sequence", -2))])
	var seen := {}
	for ev in events:
		var k := str(int((ev as Array)[2]))
		seen[k] = int(seen.get(k, 0)) + 1
	for k in counts.keys():
		if int(counts[k]) != int(seen.get(str(k), 0)):
			detail.append("count[%s]=%d stream=%d" % [
				str(k), int(counts[k]), int(seen.get(str(k), 0))])
	return [detail.is_empty(), "; ".join(detail)]


func _suite_stats() -> void:
	var trials := 256
	var low := 0
	var high := 0
	var paired_match := true
	var responses_low: Array = []
	var responses_high: Array = []
	for i in trials:
		var u := float(_uniform_m01_unsign(i))
		var cls_low := _classify(u, 20)
		var cls_high := _classify(u, 80)
		responses_low.append(cls_low)
		responses_high.append(cls_high)
		if cls_low == 5 or cls_low == 6:
			low += 1
		if cls_high == 5 or cls_high == 6:
			high += 1
		if (cls_low == 5 or cls_low == 6) != (cls_high == 5 or cls_high == 6):
			pass
	var band_ok := low >= 80 and low <= 145 and high >= 180 and high <= 232 and high >= low + 40
	_record("C80-g10-understood-bands", band_ok,
		"256 paired trials: INT20 understood=%d (band 80..145), INT80=%d (band 180..232)" % [
			low, high])
	if not band_ok:
		# retain failing sample
		_append_note("C80 failing sample retained", JSON.stringify({
			"seed": 3101, "counts": {"int20": low, "int80": high},
			"responses_low": responses_low, "responses_high": responses_high}))

	_case_c81()

	_case_c82_response()

	_case_c82_skill()


func _uniform_m01_unsign(i: int) -> float:
	# m01-uniform-1: one unsigned 32 draw / 2^32, half-open.
	var rng := RandomNumberGenerator.new()
	rng.seed = 3101 + i * 7919
	return float(rng.randi()) / 4294967296.0


func _classify(u: float, int_stat: int) -> int:
	var r: Dictionary = content.tuning["response"]
	var i_val := float(int_stat) / 100.0
	var c := clampf(float(r["understood_base"]) + float(r["understood_int_weight"]) * i_val
			+ float(r["understood_bond_weight"]) * 0.50,
		float(r["understood_min"]), float(r["understood_max"]))
	var q := clampf(0.25 * (1.0 - i_val), 0.0, float(r["ignore_max"]))
	if u < q:
		return 1
	if u < q + (1.0 - q) * (1.0 - c):
		return 2
	if int_stat < int(r["aware_int_threshold"]):
		return 4
	return 6 if int_stat >= int(r["strong_int_threshold"]) else 5


func _utility(fit: float, j: int, z: float) -> float:
	var jj := float(j) / 100.0
	return (0.5 + 0.5 * jj) * fit + 0.6 * (1.0 - jj) * z


## One forced uniform per call from _probe_draws; counts the call and runs off the end as
## 0.0 so an unexpected extra draw is visible in the reported draw total.
func _probe_draw() -> float:
	var i := _probe_draw_n
	_probe_draw_n = i + 1
	if i >= _probe_draws.size():
		return 0.0
	return float(_probe_draws[i])


## Runs the production select_by_utility with a counting draw fed from vec, one entry per
## candidate, and returns the pick plus how many draws it actually consumed.
func _utility_pick(bhv: M01MonsterBehavior, cands: Array, fits: Dictionary,
		instinct: int, vec: Array) -> Dictionary:
	_probe_draws = vec
	_probe_draw_n = 0
	var pick := str(bhv.select_by_utility(cands, fits, instinct,
		Callable(self, "_probe_draw")))
	return {"pick": pick, "draws": _probe_draw_n}


## Closed-form G-12 utilities for one forced draw vector, mirroring the AUTHOR_ORDER walk
## that select_by_utility performs (one z per present candidate).
func _utils_for(vec: Array, fits: Dictionary, instinct: int) -> Dictionary:
	var j := float(instinct) / 100.0
	var out := {}
	var i := 0
	for sid in ["quick_claw", "brace", "short_bound"]:
		if not fits.has(sid):
			continue
		var z := 2.0 * float(vec[i]) - 1.0
		i += 1
		out[sid] = (0.5 + 0.5 * j) * float(fits[sid]) + 0.6 * (1.0 - j) * z
	return out


## Defense-escape skill chosen by the production planner for one (int_stat, instinct) pair.
## Spawn geometry (4000,3000)/(5000,3000) — or the exact mirror (16000,3000)/(15000,3000)
## for `side` 1 — puts the pair inside Claw range with an escape route gaining well over
## 1000, so the pool is {brace .25, bound .90}. Visibility resolves at the end of tick 1, so
## two seeded ticks establish it while the planner is frozen; the next two candidate draws
## are then pinned before an explicit re-plan. QA-F02: `side` is the actor-side control.
func _skill_pick(int_stat: int, instinct: int, side: int = 0) -> String:
	var s := _new_sim(3101, "live")
	var self_a: Dictionary = s.actors[side]
	var foe: Dictionary = s.actors[1 - side]
	if side == 0:
		self_a["x"] = 4000.0
		self_a["y"] = 3000.0
		foe["x"] = 5000.0
		foe["y"] = 3000.0
	else:
		self_a["x"] = 16000.0
		self_a["y"] = 3000.0
		foe["x"] = 15000.0
		foe["y"] = 3000.0
	self_a["int_stat"] = int_stat
	self_a["instinct"] = instinct
	self_a["accepted_intent"] = {"intent": 1, "episode": 1, "family": 2,
		"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
		"target_or_area": null, "goal": null}
	s._refresh_gates(self_a)
	s._refresh_gates(foe)
	self_a["next_plan_tick"] = 1000000
	s.plan_watch[side] = s._plan_watch(self_a)
	_pstep(s)
	s.plan_watch[side] = s._plan_watch(self_a)
	_pstep(s)
	var n0 := int(s.selection_draw_count[side])
	s.forced_uniforms["monster.%d.%d" % [side, n0]] = [1.0]
	s.forced_uniforms["monster.%d.%d" % [side, n0 + 1]] = [0.0]
	s._execute_plan(self_a, foe)
	return str(self_a["last_plan"].get("skill", ""))


func _suite_performance(seed_v: int) -> void:
	var seed_use := seed_v if seed_v > 0 else 3101
	var sim := _new_sim(seed_use, "live")
	var seq := {0: 0}
	var t0 := Time.get_ticks_usec()
	for t in range(1, 3601):
		if t % 45 == 20:
			seq[0] = int(seq[0]) + 1
			_stage(sim, 0, 1 + (int(seq[0]) % 3), int(seq[0]), t)
		sim.step()
		if sim.ended:
			break
	var elapsed := Time.get_ticks_usec() - t0
	var samples: Array = sim.sim_time_ms_samples
	var mean := 0.0
	for v in samples:
		mean += float(v)
	if not samples.is_empty():
		mean /= float(samples.size())
	var sorted := samples.duplicate()
	sorted.sort()
	var p95 := 0.0
	if not sorted.is_empty():
		p95 = float(sorted[clampi(int(floor(float(sorted.size()) * 0.95)), 0, sorted.size() - 1)])
	var seconds := float(elapsed) / 1000000.0
	var active_seconds := float(sim.active_ticks) / 60.0
	_record("C90-sim-timing", mean <= 2.0 and p95 <= 4.0,
		"ticks=%d active=%.1fs sim mean=%.4fms p95=%.4fms (limits 2/4)" % [
			sim.tick, active_seconds, mean, p95])
	_record("C91-sample-budget", active_seconds >= 60.0,
		"pooled active seconds %.1f (need >= 60)" % active_seconds)
	if active_seconds < 60.0:
		_append_note("C91 sample budget", "only %.1f active seconds collected" % active_seconds)


## Expanded Baby opt-in profile. Not part of the default or `all` fanout. Every row is authored
## here and remains NOT RUN until a separately released execution.
func _suite_baby_growth_revival() -> void:
	var fx := _load_fixtures()
	var grp := {}
	if bool(fx["ok"]):
		grp = (fx["data"] as Dictionary).get("baby_growth_revival", {})
	if _baby_gate("B01-content-mode"):
		_baby_case_content(grp)
		_baby_end()
	if _baby_gate("B02-observation-symmetry"):
		_baby_case_observation()
		_baby_end()
	if _baby_gate("B03-target-selection"):
		_baby_case_targeting()
		_baby_end()
	if _baby_gate("B04-prey-flee-bound"):
		_baby_case_prey_flee()
		_baby_end()
	if _baby_gate("B05-collision-four-body"):
		_baby_case_collision()
		_baby_end()
	if _baby_gate("B06-credit-overkill"):
		_baby_case_credit()
		_baby_end()
	if _baby_gate("B07-duplicate-depletion-reward"):
		_baby_case_depletion()
		_baby_end()
	if _baby_gate("B08-reward-cap"):
		_baby_case_reward_cap()
		_baby_end()
	if _baby_gate("B09-stat-hold-reset"):
		_baby_case_stat_hold()
		_baby_end()
	if _baby_gate("B10-prey-respawn-blocked"):
		_baby_case_respawn()
		_baby_end()
	if _baby_gate("B11-monster-ko-return"):
		_baby_case_ko_return()
		_baby_end()
	if _baby_gate("B12-mutual-ko-effects"):
		_baby_case_mutual()
		_baby_end()
	if _baby_gate("B13-end-precedence"):
		_baby_case_end()
		_baby_end()
	if _baby_gate("B14-telemetry-schema"):
		_baby_case_schema()
		_baby_end()
	if _baby_gate("B15-safe-projection"):
		_baby_case_projection()
		_baby_end()
	if _baby_gate("B16-action-categories"):
		_baby_case_categories()
		_baby_end()
	if _baby_gate("B17-legacy-preservation"):
		_baby_case_legacy()
		_baby_end()


func _baby_sim() -> M01Simulation:
	return _new_sim(3101, "baby_growth_revival")


## Freezes normal autonomous planning so a case can inject an exact due effect and run the real
## production `step` without unrelated starts.
func _baby_freeze(sim: M01Simulation) -> void:
	for i in 2:
		sim.actors[i]["next_plan_tick"] = 1000000
		sim.actors[i]["enemy_visible"] = false
		sim.actors[i]["memory_valid"] = false
		sim.plan_watch[i] = sim._plan_watch(sim.actors[i])


func _baby_damage_effect(eid: int, source: int, kind: String, id: int, life: int,
		power: int) -> Dictionary:
	return {"effect": eid, "action": 0, "source": source, "kind": "damage",
		"impact_tick": 0, "interrupt_power": 1, "qualification": "qualified", "batch": 0,
		"base_power_cp": power, "source_atk": 100, "target_def": 0,
		"brace_factor_bp": 10000, "phase_factor_bp": 10000,
		"target_ref": {"kind": kind, "id": id, "life_id": life},
		"target_life_id": life, "source_life_id": 1,
		"target": 0 if kind == "monster" else 2 + id}


func _baby_case_content(grp: Dictionary) -> void:
	var bad: Array = []
	if int(content.compiled.get("baby_prey_respawn_ticks", -1)) != 900:
		bad.append("respawn ticks")
	if int(content.compiled.get("baby_return_ticks", -1)) != 300:
		bad.append("return ticks")
	if int(content.compiled.get("baby_diagnostic_ticks", -1)) != 5400:
		bad.append("diagnostic ticks")
	if int(content.tuning["timeout_active_ticks"]) != 10800:
		bad.append("legacy global timeout changed")
	if grp.is_empty() or str(grp.get("id", "")) != "fixtures.m01.baby_growth_revival":
		bad.append("fixtures group missing")
	var s := _baby_sim()
	if s.prey_slots.size() != 2:
		bad.append("prey slots %d != 2" % s.prey_slots.size())
	if int(s.actors[0]["x"]) != 2000 or int(s.actors[0]["y"]) != 10000 \
			or int(s.actors[1]["x"]) != 18000 or int(s.actors[1]["y"]) != 2000:
		bad.append("nest spawns not applied")
	if int(s.actors[0]["radius"]) != 500:
		bad.append("monster radius changed")
	if int(s.prey_slots[0]["hp"]) != 2400 or int(s.prey_slots[0]["radius"]) != 250:
		bad.append("prey values")
	if int(s.progression[0]["pending_atk"]) != 0 or int(s.progression[0]["evolution_exp"]) != 0:
		bad.append("ledger not zero")
	var leg := _new_sim(3101, "live")
	if not leg.prey_slots.is_empty() or leg.is_expanded():
		bad.append("legacy mode gained prey")
	# C08: missing expanded section and nonpositive damage k must fail truthfully at load.
	var species_copy := content.species.duplicate(true)
	var tuning_copy := content.tuning.duplicate(true)
	content.tuning.erase("baby_growth_revival")
	content.errors.clear()
	content._validate_baby_growth()
	if content.errors.is_empty():
		bad.append("missing expanded section was accepted")
	content.tuning["baby_growth_revival"] = tuning_copy["baby_growth_revival"]
	content.species["k_defense"] = 0
	content.errors.clear()
	content._validate_baby_growth()
	if content.errors.is_empty():
		bad.append("nonpositive k_defense was accepted")
	content.species = species_copy
	content.errors.clear()
	content._validate_baby_growth()
	if content.baby_section().is_empty():
		bad.append("valid section not restored after negatives")
	_record("B01-content-mode", bad.is_empty(), "compiled ticks 900/300/5400, legacy timeout 10800, 2 prey at centres, Nest spawns, zero ledgers, missing-section/nonpositive-k rejected; problems=[%s]" % ", ".join(bad))


func _baby_case_observation() -> void:
	var s := _baby_sim()
	var bad: Array = []
	# C13/B02: deliberately ASYMMETRIC own states so a swapped own-state source cannot pass.
	s.actors[0]["hp"] = 3000
	s.actors[1]["hp"] = 12000
	s.actors[0]["stam"] = 1000
	s.actors[1]["stam"] = 6000
	s.actors[0]["control_mode"] = 1
	s.actors[1]["control_mode"] = 0
	s.actors[0]["int_stat"] = 10
	s.actors[1]["int_stat"] = 90
	s.actors[0]["life_id"] = 3
	s.actors[1]["life_id"] = 5
	# Distinct readiness/affordability: side0 cannot pay Quick and has it on cooldown; side1 can.
	s.actors[0]["stam"] = 100
	s.actors[1]["stam"] = 6000
	s.actors[0]["cooldown_end"]["quick_claw"] = 100
	s.actors[1]["cooldown_end"]["quick_claw"] = 0
	s._refresh_gates(s.actors[0])
	s._refresh_gates(s.actors[1])
	var o0: Dictionary = s.observe_for(0)
	var o1: Dictionary = s.observe_for(1)
	if int((o0["own"] as Dictionary).get("observer", -1)) != 0:
		bad.append("observer0 own")
	if int((o1["own"] as Dictionary).get("observer", -1)) != 1:
		bad.append("observer1 own")
	if int((o0["own"] as Dictionary).get("hp_band", -1)) != 2 \
			or int((o1["own"] as Dictionary).get("hp_band", -1)) != 4:
		bad.append("own hp bands not mapped per side (0=%d 1=%d)" % [
			int((o0["own"] as Dictionary).get("hp_band", -1)),
			int((o1["own"] as Dictionary).get("hp_band", -1))])
	if str((o0["own"] as Dictionary).get("stam_label", "")) == \
			str((o1["own"] as Dictionary).get("stam_label", "")):
		bad.append("own stamina mapping identical across asymmetric sides")
	if int((o0["own"] as Dictionary).get("control", -1)) != 1 \
			or int((o1["own"] as Dictionary).get("control", -1)) != 0:
		bad.append("own control not mapped per side")
	if int((o1["own"] as Dictionary).get("life_id", -1)) != 5 \
			or int((o0["own"] as Dictionary).get("life_id", -1)) != 3:
		bad.append("own life_id not mapped per side")
	var r0: Dictionary = (o0["own"] as Dictionary).get("ready", {})
	var r1: Dictionary = (o1["own"] as Dictionary).get("ready", {})
	var a0: Dictionary = (o0["own"] as Dictionary).get("affordable", {})
	var a1: Dictionary = (o1["own"] as Dictionary).get("affordable", {})
	if bool(a0.get("quick_claw", false)) or not bool(a1.get("quick_claw", false)):
		bad.append("own affordability not mapped per side")
	if bool(r0.get("quick_claw", false)) == bool(r1.get("quick_claw", false)):
		bad.append("own readiness not mapped per side")
	if int((o0["enemy"] as Dictionary).get("knowledge", -1)) != 0:
		bad.append("starter enemies should be out of vision")
	_record("B02-observation-symmetry", bad.is_empty(),
		"asymmetric own hp/stam/control/life map per side after canonical ordering; problems=[%s]" % ", ".join(bad))


func _baby_case_targeting() -> void:
	var s := _baby_sim()
	var a: Dictionary = s.actors[0]
	a["x"] = 6000.0
	a["y"] = 6000.0
	a["enemy_visible"] = true
	s.actors[1]["x"] = 6300.0
	s.actors[1]["y"] = 6000.0
	s.prey_slots[0]["x"] = 6300.0
	s.prey_slots[0]["y"] = 6000.0
	s.prey_slots[1]["x"] = 13000.0
	s.prey_slots[1]["y"] = 6000.0
	var bad: Array = []
	var tie := s._select_attack_target(a)
	if str(tie.get("kind", "")) != "monster":
		bad.append("equal-distance tie did not prefer opponent")
	a["enemy_visible"] = false
	var prey_pick := s._select_attack_target(a)
	if str(prey_pick.get("kind", "")) != "prey" or int(prey_pick.get("id", -1)) != 0:
		bad.append("nearest visible prey not chosen")
	# stale generation is not retained
	a["selected_target"] = {"kind": "prey", "id": 0, "life_id": 99}
	var refreshed := s._select_attack_target(a)
	if int(refreshed.get("life_id", -1)) != 1:
		bad.append("stale target life retained")
	# hidden prey never selected
	s.prey_slots[0]["live"] = false
	s.prey_slots[1]["x"] = 19000.0
	s.prey_slots[1]["y"] = 11000.0
	a["enemy_visible"] = false
	if not s._select_attack_target(a).is_empty():
		bad.append("hidden prey selected")
	# C06: paired observer-equivalent worlds whose hidden prey LIFE state differs must keep the
	# same frozen last-seen search until a lawful observation or expiry (no hidden-state leak).
	var k0 := _baby_sim()
	var k1 := _baby_sim()
	for kk in [k0, k1]:
		kk.actors[0]["x"] = 6000.0
		kk.actors[0]["y"] = 6000.0
		kk.actors[0]["enemy_visible"] = false
		kk.actors[0]["memory_valid"] = false
		kk.prey_slots[0]["x"] = 8000.0
		kk.prey_slots[0]["y"] = 6000.0
		kk.prey_slots[0]["live"] = true
		kk._update_prey_knowledge()
		kk.actors[0]["selected_target"] = {"kind": "prey", "id": 0, "life_id": 1}
		# Move the prey far out of vision so only frozen memory remains.
		kk.prey_slots[0]["x"] = 19000.0
		kk.prey_slots[0]["y"] = 11000.0
		kk._update_prey_knowledge()
	# Hidden life change in only world k1.
	k1.prey_slots[0]["life_id"] = 2
	k1.prey_slots[0]["live"] = true
	var sel0 := k0._select_attack_target(k0.actors[0])
	var sel1 := k1._select_attack_target(k1.actors[0])
	if str(sel0.get("kind", "")) != "prey" or str(sel1.get("kind", "")) != "prey":
		bad.append("frozen prey search lost without lawful observation")
	elif int(sel0.get("life_id", -1)) != int(sel1.get("life_id", -1)):
		bad.append("hidden prey life change altered frozen search")
	# Expiry still retires it lawfully.
	k0.actors[0]["prey_knowledge"][0]["memory_valid"] = false
	if not k0._select_attack_target(k0.actors[0]).is_empty():
		bad.append("expired frozen prey search not retired")
	_record("B03-target-selection", bad.is_empty(),
		"opponent tie, nearest visible prey, stale-life refresh, hidden denial, frozen-search parity; problems=[%s]" % ", ".join(bad))


func _baby_case_prey_flee() -> void:
	var s := _baby_sim()
	var p: Dictionary = s.prey_slots[0]
	p["x"] = 6000.0
	p["y"] = 6000.0
	s.actors[0]["x"] = 6000.0
	s.actors[0]["y"] = 5600.0
	var draws_before: Dictionary = s.stream_draws.duplicate(true)
	s._prey_plan_cut()
	var draws_after: Dictionary = s.stream_draws.duplicate(true)
	var bad: Array = []
	if (p["route"] as Array).is_empty():
		bad.append("no flee route")
	if s.prey_expansion_total > 3840:
		bad.append("expansions %d > 3840" % s.prey_expansion_total)
	if draws_before != draws_after:
		bad.append("prey planning consumed competing RNG")
	s.actors[0]["alive"] = false
	s._prey_plan_cut()
	if not (p["route"] as Array).is_empty():
		bad.append("threat loss did not stop movement")
	# C04: cursor advances only through vertices the committed polyline actually reaches.
	var c := _baby_sim()
	var cp: Dictionary = c.prey_slots[0]
	cp["route"] = [[6250.0, 6000.0], [6250.0, 6250.0]]
	cp["route_i"] = 0
	var step := 1600.0 / 60.0
	# Applied 26.6667 from (6220,6000) reaches x=6246.6667: 3.3333 short of the first corner.
	c._advance_prey_cursor(cp, [6220.0, 6000.0], step)
	if int(cp["route_i"]) != 0:
		bad.append("cursor skipped an unreached corner (i=%d)" % int(cp["route_i"]))
	cp["route"] = [[6250.0, 6000.0], [6250.0, 6250.0]]
	cp["route_i"] = 0
	c._advance_prey_cursor(cp, [6220.0, 6000.0], 60.0)
	if int(cp["route_i"]) < 1:
		bad.append("cursor did not consume a genuinely reached corner")
	# Producer-level: the movement cut must pass the PRE-step origin, not the applied endpoint.
	var pr := _baby_sim()
	var pp2: Dictionary = pr.prey_slots[0]
	pp2["x"] = 6220.0
	pp2["y"] = 6000.0
	pp2["route"] = [[6250.0, 6000.0], [6250.0, 6250.0]]
	pp2["route_i"] = 0
	pp2["threat"] = 0
	pr._movement_cut_baby()
	if int(pp2["route_i"]) != 0:
		bad.append("producer movement cut skipped an unreached corner")
	# S4/B04: a static clip truncates the applied arc BEFORE the corner; the cursor must not
	# consume the unreached vertex.
	var cl := _baby_sim()
	var cpz: Dictionary = cl.prey_slots[0]
	cpz["x"] = 19730.0
	cpz["y"] = 6000.0
	cpz["route"] = [[19760.0, 6000.0], [19760.0, 6250.0]]
	cpz["route_i"] = 0
	cpz["threat"] = 0
	cl._movement_cut_baby()
	if int(cpz["route_i"]) != 0:
		bad.append("static-clipped arc consumed an unreached corner")
	if float(cpz["x"]) >= 19760.0 - 1e-6:
		bad.append("static clip did not truncate before the corner (x=%.4f)" % float(cpz["x"]))
	_record("B04-prey-flee-bound", bad.is_empty(),
		"bounded single-tree flee, no RNG draw, immediate stop, producer partial/static-clipped arc; problems=[%s]" % ", ".join(bad))


func _baby_case_collision() -> void:
	var bad: Array = []
	# R1: mover -> ORIGINALLY STATIONARY body first (t=0.4), then a later moving/stationary
	# contact (t=0.75). The consumed first pair must not be rediscovered or abort resolution.
	var s := _baby_sim()
	s.actors[0]["x"] = 4000.0
	s.actors[0]["y"] = 6000.0
	s.actors[1]["x"] = 5020.0
	s.actors[1]["y"] = 6000.0
	_force_move_goal(s, 1, [4800, 6000])
	s.prey_slots[0]["x"] = 7000.0
	s.prey_slots[0]["y"] = 6000.0
	s.prey_slots[0]["threat"] = -1
	s.prey_slots[0]["route"] = []
	s.prey_slots[1]["x"] = 7520.0
	s.prey_slots[1]["y"] = 6000.0
	s.prey_slots[1]["route"] = [[7200.0, 6000.0]]
	s.prey_slots[1]["route_i"] = 0
	s.prey_slots[1]["threat"] = 0
	s.pair_test_total = 0
	s.movement_contract_failures = 0
	s._movement_cut_baby()
	if s.movement_contract_failures != 0:
		bad.append("R1 no-progress when a later contact follows a consumed stopped pair")
	if s.pair_test_total > 24:
		bad.append("pair tests %d > 24" % s.pair_test_total)
	# Stationary monster0 must not be shoved; mover monster1 freezes at its t=0.4 contact.
	if absf(float(s.actors[0]["x"]) - 4000.0) > 1e-6:
		bad.append("stationary body was displaced")
	if absf(float(s.actors[1]["x"]) - 5000.0) > 1.0:
		bad.append("mover did not freeze at its applied contact endpoint (x=%.3f)" % float(s.actors[1]["x"]))
	# Later moving->stationary prey contact resolves at t=0.75.
	if absf(float(s.prey_slots[0]["x"]) - 7000.0) > 1e-6:
		bad.append("stationary prey was displaced")
	if absf(float(s.prey_slots[1]["x"]) - 7500.0) > 1.0:
		bad.append("later mover did not freeze at its applied contact endpoint (x=%.3f)" % float(s.prey_slots[1]["x"]))
	var d_mon := _dist([float(s.actors[0]["x"]), float(s.actors[0]["y"])],
		[float(s.actors[1]["x"]), float(s.actors[1]["y"])])
	if d_mon < 1000.0 - 1.0:
		bad.append("monster pair overlapped after freeze %.3f" % d_mon)
	var d_prey := _dist([float(s.prey_slots[0]["x"]), float(s.prey_slots[0]["y"])],
		[float(s.prey_slots[1]["x"]), float(s.prey_slots[1]["y"])])
	if d_prey < 500.0 - 1.0:
		bad.append("prey pair overlapped after later freeze %.3f" % d_prey)
	# S4/B05(a): a later mover contacts a PREVIOUSLY FROZEN body (monster1 at t=0.4), and an
	# independent noncontact body keeps its own full displacement.
	var sA := _baby_sim()
	sA.actors[0]["x"] = 4000.0
	sA.actors[0]["y"] = 6000.0
	sA.actors[1]["x"] = 5020.0
	sA.actors[1]["y"] = 6000.0
	_force_move_goal(sA, 1, [4800, 6000])
	sA.prey_slots[0]["x"] = 5770.0
	sA.prey_slots[0]["y"] = 6000.0
	sA.prey_slots[0]["route"] = [[5400.0, 6000.0]]
	sA.prey_slots[0]["route_i"] = 0
	sA.prey_slots[0]["threat"] = 1
	sA.prey_slots[1]["x"] = 7000.0
	sA.prey_slots[1]["y"] = 2000.0
	sA.prey_slots[1]["route"] = [[7200.0, 2000.0]]
	sA.prey_slots[1]["route_i"] = 0
	sA.prey_slots[1]["threat"] = 0
	sA.pair_test_total = 0
	sA.movement_contract_failures = 0
	sA._movement_cut_baby()
	if sA.movement_contract_failures != 0:
		bad.append("S4 mover-vs-frozen contact aborted")
	if absf(float(sA.actors[1]["x"]) - 5000.0) > 1.0:
		bad.append("first mover did not freeze at t=0.4")
	if absf(float(sA.prey_slots[0]["x"]) - 5750.0) > 1.0:
		bad.append("later mover did not stop against the FROZEN body (x=%.3f)" % float(sA.prey_slots[0]["x"]))
	var independent_step := 1600.0 / 60.0
	if absf(float(sA.prey_slots[1]["x"]) - (7000.0 + independent_step)) > 1e-3:
		bad.append("independent noncontact body did not keep its own displacement")
	# S4/B05(b): sparse side1 Bound plus one live unrelated prey.
	var s2 := _baby_sim()
	s2.actors[0]["alive"] = false
	s2.actors[0]["lifecycle"] = "down"
	s2.prey_slots[0]["live"] = true
	s2.prey_slots[0]["x"] = 14000.0
	s2.prey_slots[0]["y"] = 9000.0
	s2.prey_slots[0]["route"] = [[14100.0, 9000.0]]
	s2.prey_slots[0]["route_i"] = 0
	s2.prey_slots[0]["threat"] = 0
	s2.prey_slots[1]["live"] = false
	s2.actors[1]["x"] = 18000.0
	s2.actors[1]["y"] = 2000.0
	s2.actors[1]["bound_active"] = true
	s2.actors[1]["bound_path"] = [[18000.0, 2000.0], [18000.0, 1500.0]]
	s2.actors[1]["bound_total"] = 500.0
	s2.actors[1]["bound_progress"] = 0.0
	s2.actors[1]["bound_action"] = 9
	s2.pair_test_total = 0
	s2.movement_contract_failures = 0
	var prey_start := [14000.0, 9000.0]
	var prey_end := [14100.0, 9000.0]
	var prey_radius := float(s2.prey_slots[0]["radius"])
	# The initial separation exceeds BOTH entire path lengths plus the contact radii.
	var separate := _dist(prey_start, [18000.0, 2000.0]) > 100.0 + 500.0 \
		+ prey_radius + float(s2.actors[1]["radius"]) + s2.arena.GUARD
	var legal_segment := s2.arena.static_legal_for(14000.0, 9000.0, prey_radius) \
		and s2.arena.static_legal_for(14100.0, 9000.0, prey_radius) \
		and s2.arena.swept_static_limit_for(prey_start, prey_end, prey_radius) >= 1.0 - 1e-9
	if not legal_segment or not separate or not bool(s2.actors[1]["alive"]) \
			or bool(s2.actors[0]["alive"]) or bool(s2.prey_slots[1]["live"]) \
			or prey_radius != 250.0 or float(s2.content.baby_section()["prey"]["mov_mwu_per_s"]) != 1600.0:
		bad.append("S4 sparse Bound/prey fixture is not statically and dynamically separate")
	else:
		s2._movement_cut_baby()
		if s2.movement_contract_failures != 0:
			bad.append("S4 sparse Bound no-progress with a live prey")
		if float(s2.actors[1]["bound_progress"]) <= 0.0:
			bad.append("S4 side1 Bound did not advance with side0 down")
		if s2.pair_test_total > 24:
			bad.append("S4 sparse Bound/prey pair ceiling exceeded")
		if absf(float(s2.prey_slots[0]["x"]) - (14000.0 + 1600.0 / 60.0)) > 1e-3 \
				or absf(float(s2.prey_slots[0]["y"]) - 9000.0) > 1e-3:
			bad.append("S4 unrelated live prey did not keep its full independent step")
	_record("B05-collision-four-body", bad.is_empty(),
		"stationary-first contacts, later mover-vs-frozen, independent body, sparse Bound+prey (pairs=%d/%d, failures=%d/%d); problems=[%s]" % [
			s.pair_test_total, sA.pair_test_total, s2.movement_contract_failures,
			sA.movement_contract_failures, ", ".join(bad)])


func _baby_case_credit() -> void:
	var s := _baby_sim()
	var bad: Array = []
	var even: Array = s._allocate_credit(2400, 2000, 2000)
	if int(even[0]) != 1200 or int(even[1]) != 1200:
		bad.append("even split %s" % str(even))
	var odd: Array = s._allocate_credit(1, 1, 1)
	if int(odd[0]) != 1 or int(odd[1]) != 0:
		bad.append("odd remainder tie not side0: %s" % str(odd))
	var zero := s._allocate_credit(0, 0, 0)
	if int(zero[0]) != 0 or int(zero[1]) != 0:
		bad.append("zero damage credited")
	var no_contrib := s._allocate_credit(500, 0, 0)
	if int(no_contrib[0]) != 0 or int(no_contrib[1]) != 0:
		bad.append("no-contributor credit %s != [0,0]" % str(no_contrib))
	var overkill := s._allocate_credit(2400, 3000, 100)
	if int(overkill[0]) + int(overkill[1]) != 2400:
		bad.append("overkill credited beyond actual HP loss")
	_record("B06-credit-overkill", bad.is_empty(),
		"integer largest-remainder allocation, exact zero no-contributor, overkill excluded, side0 remainder tie; problems=[%s]" % ", ".join(bad))


func _baby_case_depletion() -> void:
	var s := _baby_sim()
	s.prey_slots[0]["hp"] = 2400
	s.pending_effects = [
		_baby_damage_effect(1, 0, "prey", 0, 1, 2000),
		_baby_damage_effect(2, 1, "prey", 0, 1, 2000),
	]
	s._cut5_baby()
	var bad: Array = []
	var p: Dictionary = s.prey_slots[0]
	if bool(p["live"]):
		bad.append("prey not depleted")
	if int((p["credited"] as Array)[0]) != 1200 or int((p["credited"] as Array)[1]) != 1200:
		bad.append("credit %s" % str(p["credited"]))
	var atk_after := int(s.progression[0]["pending_atk"])
	# duplicate callback must not re-award
	s.pending_effects = []
	s._cut5_baby()
	if int(s.progression[0]["pending_atk"]) != atk_after:
		bad.append("duplicate depletion re-awarded")
	if _events_of_type(s, 28).size() != 1:
		bad.append("HUNT_REWARD rows %d != 1" % _events_of_type(s, 28).size())
	if _events_of_type(s, 27).size() != 1:
		bad.append("prey lifecycle rows %d != 1" % _events_of_type(s, 27).size())
	# C13: same-boundary two-slot award in ascending slot order, and a down winner still keeps
	# its persistent credit.
	var two := _baby_sim()
	two.progression[0]["credited_defeats"] = 0
	two.prey_slots[0]["hp"] = 2400
	two.prey_slots[1]["hp"] = 2400
	two.pending_effects = [
		_baby_damage_effect(1, 0, "prey", 0, 1, 2400),
		_baby_damage_effect(2, 0, "prey", 1, 1, 2400),
	]
	two.actors[0]["alive"] = false
	two.actors[0]["lifecycle"] = "down"
	two.actors[0]["return_due"] = 9999
	two._cut5_baby()
	var rewards := _events_with_tick(two, 28)
	if rewards.size() != 2:
		bad.append("same-boundary awards %d != 2" % rewards.size())
	elif int((rewards[0][1] as Array)[0]) != 0 or int((rewards[1][1] as Array)[0]) != 1:
		bad.append("same-boundary slot order not ascending")
	if int(two.progression[0]["pending_atk"]) != 3 or int(two.progression[0]["evolution_exp"]) != 15:
		bad.append("same-boundary schedule %d/%d != 3/15" % [
			int(two.progression[0]["pending_atk"]), int(two.progression[0]["evolution_exp"])])
	_record("B07-duplicate-depletion-reward", bad.is_empty(),
		"one award per life, grouped credit 1200/1200, duplicate inert, ascending two-slot award, down-winner credit; problems=[%s]" % ", ".join(bad))


func _baby_case_reward_cap() -> void:
	var s := _baby_sim()
	var grp := {"d": [2000, 0], "effects": [], "hp_start": 2400}
	s.prey_slots[0]["credited"] = [2000, 0]
	s.prey_slots[0]["first_credit"] = [1, -1]
	s._award_prey(0, grp)
	var first := [int(s.progression[0]["pending_atk"]), int(s.progression[0]["evolution_exp"])]
	s.prey_slots[0]["credited"] = [2000, 0]
	s._award_prey(0, grp)
	var second := [int(s.progression[0]["pending_atk"]), int(s.progression[0]["evolution_exp"])]
	s.prey_slots[0]["credited"] = [2000, 0]
	s._award_prey(0, grp)
	var third := [int(s.progression[0]["pending_atk"]), int(s.progression[0]["evolution_exp"])]
	var bad: Array = []
	if first != [2, 10] or second != [3, 15] or third != [3, 15]:
		bad.append("reward schedule %s/%s/%s" % [str(first), str(second), str(third)])
	# zero-reward later defeat shows no positive growth cue
	var growth_rows := 0
	for e in s.human_feedback:
		if str(e.get("kind", "")) == "growth":
			growth_rows += 1
	if growth_rows != 2:
		bad.append("growth cues %d != 2 (third is zero)" % growth_rows)
	_record("B08-reward-cap", bad.is_empty(),
		"first +2/+10, second +1/+5, third 0, zero repeats silent; problems=[%s]" % ", ".join(bad))


func _baby_case_stat_hold() -> void:
	var s := _baby_sim()
	var atk0 := int(s.actors[0]["atk"])
	var def0 := int(s.actors[0]["def"])
	var hp_max0 := int(s.actors[0]["hp_max"])
	var grp := {"d": [2000, 0], "effects": [], "hp_start": 2400}
	s.prey_slots[0]["credited"] = [2000, 0]
	s.prey_slots[0]["first_credit"] = [1, -1]
	s._award_prey(0, grp)
	var bad: Array = []
	if int(s.actors[0]["atk"]) != atk0 or int(s.actors[0]["def"]) != def0 \
			or int(s.actors[0]["hp_max"]) != hp_max0:
		bad.append("pending award changed live stats")
	if int(s.progression[0]["pending_atk"]) != 2:
		bad.append("ledger not stored")
	var s2 := _baby_sim()
	if int(s2.progression[0]["pending_atk"]) != 0 or int(s2.progression[0]["evolution_exp"]) != 0:
		bad.append("fresh encounter kept ledger")
	_record("B09-stat-hold-reset", bad.is_empty(),
		"no continuous stat change; fresh encounter zeroes ledgers; problems=[%s]" % ", ".join(bad))


func _baby_case_respawn() -> void:
	var s := _baby_sim()
	var bad: Array = []
	var cands := arena.placement_candidates([6000.0, 6000.0], [1000, 2000])
	if cands.size() != 17:
		bad.append("candidates %d != 17" % cands.size())
	if absf(float(cands[1][0]) - 7000.0) > 1e-6:
		bad.append("east offset wrong")
	var diag := 1000.0 / sqrt(2.0)
	if absf(float(cands[2][0]) - (6000.0 + diag)) > 1e-6 \
			or absf(float(cands[2][1]) - (6000.0 + diag)) > 1e-6:
		bad.append("diagonal component not radius/sqrt2")
	var p: Dictionary = s.prey_slots[0]
	p["live"] = false
	p["respawn_due"] = s.tick
	p["radius"] = 1.0e9
	s._process_due_lifecycles(0)
	if int(p["life_id"]) != 1 or bool(p["live"]):
		bad.append("blocked placement incremented generation")
	if not bool(p["spawn_wait_announced"]):
		bad.append("blocked wait not announced")
	var waits := _rows_with_field(_events_with_tick(s, 27), 0, "spawn_wait")
	s._process_due_lifecycles(0)
	if _rows_with_field(_events_with_tick(s, 27), 0, "spawn_wait").size() != waits.size():
		bad.append("wait re-announced while still blocked")
	p["radius"] = 250.0
	s._process_due_lifecycles(0)
	if int(p["life_id"]) != 2 or not bool(p["live"]) or int(p["hp"]) != 2400:
		bad.append("legal respawn did not increment generation once")
	if int((p["credited"] as Array)[0]) != 0:
		bad.append("contributor totals not reset")
	# R8/B10: per-candidate evaluation, real-radius centre blockage, finite all-candidate
	# blockage (bounded synthetic radius), original due retention, and serialized row order.
	var b := _baby_sim()
	var bp: Dictionary = b.prey_slots[0]
	bp["live"] = false
	bp["respawn_due"] = b.tick + 2
	bp["spawn_wait_announced"] = false
	b.actors[1]["x"] = 6000.0
	b.actors[1]["y"] = 6000.0
	var before_tests := b.placement_test_total
	_mtick(b, b.tick + 1)
	b._process_due_lifecycles(0)
	if bool(bp["live"]) or int(bp["life_id"]) != 1:
		bad.append("due-1 spawned early")
	var due_saved := int(bp["respawn_due"])
	_mtick(b, int(due_saved))
	b._process_due_lifecycles(0)
	if not bool(bp["live"]) or int(bp["life_id"]) != 2:
		bad.append("due respawn with a legal-radius alternate did not spawn")
	if b.placement_test_total - before_tests != 2:
		bad.append("centre-blocked placement tested %d candidates != 2" % (
			b.placement_test_total - before_tests))
	# All 17 candidates blocked (finite synthetic radius) at the legal candidate list size.
	var c := _baby_sim()
	var cps: Dictionary = c.prey_slots[0]
	cps["live"] = false
	cps["respawn_due"] = c.tick + 1
	cps["spawn_wait_announced"] = false
	cps["radius"] = 6000.0
	var cbefore := c.placement_test_total
	_mtick(c, int(cps["respawn_due"]))
	c._process_due_lifecycles(0)
	if bool(cps["live"]) or int(cps["life_id"]) != 1:
		bad.append("all-candidate blockage spawned")
	if int(cps["respawn_due"]) != int(c.tick):
		bad.append("blocked due tick was renewed")
	if c.placement_test_total - cbefore != 17:
		bad.append("all-candidate blockage tested %d != 17" % (
			c.placement_test_total - cbefore))
	# Stable simultaneous order: compare serialized row POSITION, not absolute ticks.
	var o := _baby_sim()
	o.actors[0]["alive"] = false
	o.actors[0]["lifecycle"] = "down"
	o.actors[0]["return_due"] = o.tick + 1
	o.prey_slots[0]["live"] = false
	o.prey_slots[0]["respawn_due"] = o.tick + 1
	_mtick(o, o.tick + 1)
	o._process_due_lifecycles(0)
	var lc := _events_with_tick(o, 27)
	var idx_monster := -1
	var idx_spawn := -1
	for k in lc.size():
		var pay: Array = (lc[k] as Array)[1]
		if str(pay[0]) == "monster_return" and idx_monster < 0:
			idx_monster = k
		if str(pay[0]) == "prey_spawn" and idx_spawn < 0:
			idx_spawn = k
	if idx_monster < 0 or idx_spawn < 0 or idx_monster > idx_spawn:
		bad.append("simultaneous placement serialized order not monster-before-prey")
	_record("B10-prey-respawn-blocked", bad.is_empty(),
		"17-candidate per-candidate count, real-radius centre block, finite all-candidate blockage, original due retention, serialized order; problems=[%s]" % ", ".join(bad))


func _baby_case_ko_return() -> void:
	var s := _baby_sim()
	var bad: Array = []
	# C13/B11: seed dirty resources/locks/action/queues plus nonzero persistent build/ledger,
	# then a real KO/return must fully reset lifetime state and preserve build/ledger/IDs.
	var a: Dictionary = s.actors[0]
	a["atk"] = 150
	a["instinct"] = 77
	a["learned"]["quick_claw"] = true
	s.progression[0]["pending_atk"] = 2
	s.progression[0]["evolution_exp"] = 10
	s.progression[0]["credited_defeats"] = 1
	s.pending_effects = [_baby_damage_effect(1, 1, "monster", 0, 1, 20000)]
	s._cut5_baby()
	if bool(a["alive"]) or str(a["lifecycle"]) != "down":
		bad.append("monster not temporarily down")
	if s.ended:
		bad.append("temporary KO ended the encounter")
	if int(a["return_due"]) != s.tick + 300:
		bad.append("return due %d != now+300" % int(a["return_due"]))
	if not s.ko_actors.is_empty():
		bad.append("terminal ko_actors set on temporary KO")
	var rejected := s.gateway.validate({"schema": "m01.1", "trainer": 0, "actor": 0,
		"sequence": 1, "slot": 0, "family": 1, "target_kind": 0, "target_or_area": null,
		"observed_tick": s.tick, "source_life": 1}, s.tick + 1, s.actors, s.trainer_owner)
	if bool(rejected["ok"]) or str(rejected["reason"]) != "life":
		bad.append("down input not truthfully rejected")
	# Dirty the state AFTER KO so the return must clear it, and stage old-life input + NPC queue.
	a["fatigue_centi"] = 9000
	a["lock_end"] = 500
	a["lock_latched"] = true
	a["physical_locked"] = true
	a["emotion"] = "Frenzy"
	a["control_mode"] = 2
	# Complete production-shaped dirty records: cut1/cut2 read them BEFORE cut5 returns.
	# Brace charges for 27 ticks (450ms), so it stays preparing through return at now+1.
	var dirty_due := s.tick + s.content.charge_ticks("brace")
	var dirty_cooldown := s.tick + s.content.cooldown_ticks("brace")
	var dirty_skill: Dictionary = s.content.skill("brace")
	a["action"] = {"action": 5, "actor": 0, "life": int(a["life"]), "life_id": int(a["life_id"]),
		"target_ref": {}, "target_life_id": null,
		"request": 1, "episode": 1, "intent": 1, "owning_family": 2,
		"skill": "brace", "target": null, "target_kind": 1, "start_tick": s.tick,
		"due_tick": dirty_due, "recovery_ticks": s.content.recovery_ticks("brace"),
		"paid_cost": int(dirty_skill["stam_cost_cp"]), "cooldown_end": dirty_cooldown,
		"stability": int(dirty_skill["stability"]), "interrupt_power": int(dirty_skill["interrupt_power"]),
		"state": "preparing", "cancel_cause": "",
		"plan": {"skill": "brace", "goal": null, "context_family": 2}}
	a["response_episode"] = {"episode": 1, "key": "2|none", "family": 2,
		"target_kind": 0, "target_or_area": null, "first_request": 1, "latest_request": 1,
		"issue_tick": s.tick, "response_due": s.tick + 100, "expiry_tick": s.tick + 1000,
		"pre_issuance_fatigue": 0, "pressure_at_issue": 0, "draw_resolved": false,
		"hesitation_end": -1, "class": 0, "original_family": 2, "interpreted_family": 2,
		"observation_category": "defense"}
	a["accepted_intent"] = {"intent": 1, "episode": 1, "request": 1, "family": 2,
		"accepted_tick": s.tick, "expiry_tick": s.tick + 1000, "state": "active",
		"target_kind": 0, "target_or_area": null, "goal": null, "observation_category": "defense"}
	a["goal"] = {"kind": "move", "purpose": "search", "point": [8000.0, 6000.0],
		"route": [[4000.0, 3000.0], [8000.0, 6000.0]], "i": 0, "stop_mwu": 0.0, "patrol_index": -1}
	a["pressure"] = 200
	a["npc"]["queued"] = {"decision": 7, "observation_tick": s.tick,
		"submission_due_tick": s.tick + 10, "sequence": 8, "slot": 1, "family": 1,
		"target_kind": 0, "target_or_area": null, "source_life": int(a["life_id"]),
		"revalidated_observation_tick": s.tick, "observation_category": "attack"}
	# Old valid knowledge/search influence must be replaced, not confused with fresh sensing.
	a["enemy_visible"] = false
	a["memory_valid"] = true
	a["memory_x"] = 8000.0
	a["memory_y"] = 6000.0
	a["memory_token"] = 3
	a["memory_last_seen_tick"] = s.tick
	a["memory_expiry"] = s.tick + 1000
	a["search_active"] = true
	a["search_start"] = s.tick
	a["search_deadline"] = s.tick + 1000
	a["search_visited"] = [[7000.0, 6000.0]]
	a["patrol_visited"] = [0]
	a["prey_knowledge"] = [
		{"kind": "prey", "id": 0, "life_id": 1, "visible": false, "x": 8000.0, "y": 6000.0,
			"last_seen_tick": 0, "expiry": 1000, "memory_valid": true, "token": 3,
			"visited": [[7000.0, 6000.0]]},
		s._new_knowledge(1)]
	a["hp"] = 5
	a["stam"] = 5
	a["cooldown_end"]["quick_claw"] = 999
	a["cooldown_end"]["brace"] = dirty_cooldown
	a["recovery_end"] = 999
	var loadout_before: Array = (a["loadout_skill_ids"] as Array).duplicate()
	s.gateway.last_accepted_sequence[0] = 7
	s.gateway.next_request_id = 8
	s.trainer_ai.decision_id = 11
	a["npc"]["decision_id"] = 11
	s.selection_draw_count = [3, 4]
	s.stream_draws["monster.side0"] = 5
	s.gateway.stage({"schema": "m01.1", "trainer": 0, "actor": 0, "sequence": 1, "slot": 0,
		"family": 1, "target_kind": 0, "target_or_area": null, "observed_tick": s.tick}, s.tick + 5, 1)
	var held_seq := int(s.gateway.last_accepted_sequence.get(0, 0))
	var rng_before := s.stream_draws.duplicate(true)
	var draws_before: Array = (s.selection_draw_count as Array).duplicate()
	var request_id_before := s.gateway.next_request_id
	var decision_id_before := s.trainer_ai.decision_id
	# Force the return onto the NEXT real production boundary with planning pressure present.
	a["return_due"] = s.tick + 1
	a["next_plan_tick"] = 0
	s.actors[1]["x"] = 3200.0
	s.actors[1]["y"] = 10000.0
	var return_tick := int(a["return_due"])
	if dirty_due <= return_tick or int(a["response_episode"]["response_due"]) <= return_tick \
			or int(a["response_episode"]["expiry_tick"]) <= return_tick \
			or int(a["accepted_intent"]["expiry_tick"]) <= return_tick:
		bad.append("dirty action/episode/intent must remain pending until return restoration")
	# Keep the NPC from drawing on this boundary so the RNG/draw retention assertion isolates
	# the return path; actor0 is down during cut2 and cannot act anyway.
	s.actors[1]["next_plan_tick"] = 1000000
	s.actors[1]["npc"]["next_decision_tick"] = 1000000
	s.plan_watch[1] = s._plan_watch(s.actors[1])
	_pstep(s)
	if not bool(a["alive"]) or int(a["life_id"]) != 2:
		bad.append("return did not restore exactly once")
	if not _rows_with_field(_events_with_tick(s, 6), 1, 0).filter(
			func(row): return int(row[0]) == return_tick).is_empty():
		bad.append("ACTION_START occurred on the return boundary")
	# cut6 senses AFTER restoration: prey0 is visible from the Nest on this boundary.
	var fresh: Dictionary = a["prey_knowledge"][0]
	var live_prey: Dictionary = s.prey_slots[0]
	if not s._los_vision(a, [float(live_prey["x"]), float(live_prey["y"])]) \
			or not bool(fresh["visible"]) or not bool(fresh["memory_valid"]) \
			or int(fresh["life_id"]) != int(live_prey["life_id"]) \
			or int(fresh["last_seen_tick"]) != return_tick or int(fresh["token"]) != 1 \
			or float(fresh["x"]) != float(live_prey["x"]) or float(fresh["y"]) != float(live_prey["y"]) \
			or not (fresh["visited"] as Array).is_empty() \
			or (float(fresh["x"]) == 8000.0 and float(fresh["y"]) == 6000.0):
		bad.append("old prey token/coordinates/search survived or fresh return sensing is missing")
	if not bool(a["enemy_visible"]) or not bool(a["memory_valid"]) \
			or int(a["memory_last_seen_tick"]) != return_tick or int(a["memory_token"]) != 4 \
			or float(a["memory_x"]) != float(s.actors[1]["x"]) \
			or float(a["memory_y"]) != float(s.actors[1]["y"]) or bool(a["search_active"]) \
			or int(a["search_start"]) != -1 or int(a["search_deadline"]) != -1 \
			or not (a["search_visited"] as Array).is_empty() or not (a["patrol_visited"] as Array).is_empty() \
			or not (a["search_token_exhausted"] as Dictionary).is_empty():
		bad.append("old competitor search influence survived lawful fresh reacquisition")
	if int(a["fatigue_centi"]) != 0 or int(a["control_mode"]) != 0 or a["action"] != null \
			or int(a["lock_end"]) != 0 or bool(a["lock_latched"]) or bool(a["physical_locked"]) \
			or str(a["emotion"]) != "Calm" or a["response_episode"] != null \
			or a["accepted_intent"] != null or a["goal"] != null or int(a["pressure"]) != 0 \
			or a["npc"]["queued"] != null or not s.gateway.staged.is_empty():
		bad.append("return restoration incomplete (dirty lifetime state survived)")
	if int(a["hp"]) != int(a["hp_max"]) or int(a["stam"]) != int(a["stam_max"]):
		bad.append("return did not restore full HP/STAM")
	if int(a["cooldown_end"]["quick_claw"]) != s.tick \
			or int(a["cooldown_end"]["brace"]) != s.tick or int(a["recovery_end"]) != s.tick:
		bad.append("cooldown/recovery not ready at the return tick")
	if int(a["atk"]) != 150 or int(a["instinct"]) != 77:
		bad.append("build not preserved across return")
	if (a["loadout_skill_ids"] as Array) != loadout_before:
		bad.append("loadout not preserved across return")
	if int(s.progression[0]["pending_atk"]) != 2 or int(s.progression[0]["evolution_exp"]) != 10 \
			or int(s.progression[0]["credited_defeats"]) != 1:
		bad.append("ledger not preserved across return")
	if int(s.gateway.last_accepted_sequence.get(0, 0)) != held_seq:
		bad.append("sequence reset by return")
	if s.gateway.next_request_id != request_id_before or s.trainer_ai.decision_id != decision_id_before \
			or int(a["npc"]["decision_id"]) != 11:
		bad.append("nonzero request/decision IDs reset or consumed at return")
	if s.stream_draws != rng_before or (s.selection_draw_count as Array) != draws_before:
		bad.append("RNG/draw counters reset by return")
	if a["action"] != null:
		bad.append("action started on the return boundary")
	# Next production boundary may act; the return boundary itself must not.
	s.actors[1]["x"] = 3200.0
	s.actors[1]["y"] = 10000.0
	_pstep(s)
	if a["action"] == null and a["goal"] == null:
		bad.append("no planning/action occurred on the next production boundary")
	_record("B11-monster-ko-return", bad.is_empty(),
		"dirty lifetime state cleared, full HP/STAM/cooldown reset, build/loadout/ledger/IDs/RNG preserved, next-boundary action; problems=[%s]" % ", ".join(bad))


func _baby_case_mutual() -> void:
	var bad: Array = []
	# C01(a): a valid committed prior arrival settles exactly once through the REAL step, with
	# matching IMPACT/DAMAGE and actual-loss credit.
	var s := _baby_sim()
	_baby_freeze(s)
	var e0 := _baby_damage_effect(1, 0, "prey", 0, 1, 500)
	e0["impact_tick"] = 1
	s.pending_effects = [e0]
	_pstep(s)
	var p0: Dictionary = s.prey_slots[0]
	if int((p0["credited"] as Array)[0]) != 500:
		bad.append("valid prior arrival did not settle once")
	if _events_with_tick(s, 12).size() != 1:
		bad.append("DAMAGE rows %d != 1" % _events_with_tick(s, 12).size())
	if _events_with_tick(s, 11).size() != 1:
		bad.append("IMPACT rows %d != 1" % _events_with_tick(s, 11).size())
	# C01(b): a down source's already-committed valid effect still contributes.
	var s2 := _baby_sim()
	_baby_freeze(s2)
	s2.actors[0]["alive"] = false
	s2.actors[0]["lifecycle"] = "down"
	s2.actors[0]["return_due"] = 9999
	var e1 := _baby_damage_effect(2, 0, "prey", 0, 1, 500)
	e1["impact_tick"] = 1
	s2.pending_effects = [e1]
	_pstep(s2)
	if int(((s2.prey_slots[0]["credited"] as Array))[0]) != 500:
		bad.append("down-source committed effect was discarded")
	# C01(c): an obsolete captured target life cannot interrupt or damage the replacement.
	var s3 := _baby_sim()
	_baby_freeze(s3)
	s3.actors[0]["life_id"] = 2
	s3.actors[0]["action"] = {"action": 77, "actor": 0, "life": 1, "life_id": 2,
		"request": 0, "episode": 0, "intent": -1, "owning_family": 2, "skill": "brace",
		"target": null, "target_kind": 1, "start_tick": 0, "due_tick": 5, "recovery_ticks": 15,
		"paid_cost": 0, "cooldown_end": 0, "stability": 1, "interrupt_power": 0,
		"state": "preparing", "cancel_cause": "", "plan": {}}
	var e2 := _baby_damage_effect(3, 1, "monster", 0, 1, 500)
	e2["impact_tick"] = 1
	s3.pending_effects = [e2]
	var hp_before := int(s3.actors[0]["hp"])
	_pstep(s3)
	if s3.actors[0]["action"] == null:
		bad.append("obsolete target life interrupted the replacement")
	if not _rows_with_field(_events_with_tick(s3, 10), 3, "interruption").is_empty():
		bad.append("obsolete target life emitted an interruption")
	if not _rows_with_field(_events_with_tick(s3, 11), 5, "hit").is_empty():
		bad.append("obsolete target life emitted a hit")
	if int(s3.actors[0]["hp"]) != hp_before:
		bad.append("obsolete target life damaged the replacement monster")
	if not _rows_with_field(_events_with_tick(s3, 12), 1, 0).is_empty():
		bad.append("obsolete target life emitted DAMAGE on the replacement")
	# R2: nonempty INCOMPLETE captured identity must fail safely (no key access, no damage).
	var s4 := _baby_sim()
	_baby_freeze(s4)
	var e3 := {"effect": 4, "action": 0, "source": 0, "kind": "damage", "impact_tick": 1,
		"interrupt_power": 1, "qualification": "qualified", "batch": 0,
		"base_power_cp": 500, "source_atk": 100, "target_def": 0,
		"brace_factor_bp": 10000, "phase_factor_bp": 10000,
		"target_ref": {"kind": "prey", "life_id": 1}, "target": 2}
	s4.pending_effects = [e3]
	var hp4 := int(s4.prey_slots[0]["hp"])
	_pstep(s4)
	if int(s4.prey_slots[0]["hp"]) != hp4 or int(((s4.prey_slots[0]["credited"] as Array))[0]) != 0:
		bad.append("incomplete identity damaged/credited an entity")
	if not _rows_with_field(_events_with_tick(s4, 11), 5, "hit").is_empty():
		bad.append("incomplete identity emitted a hit")
	# S4/R2: a missing (empty) captured identity through the actual step is inert.
	var s7 := _baby_sim()
	_baby_freeze(s7)
	var e5 := {"effect": 8, "action": 0, "source": 0, "kind": "damage", "impact_tick": 1,
		"interrupt_power": 1, "qualification": "qualified", "batch": 0,
		"base_power_cp": 500, "source_atk": 100, "target_def": 0,
		"brace_factor_bp": 10000, "phase_factor_bp": 10000,
		"target_ref": {}, "target": 2}
	s7.pending_effects = [e5]
	var hp7 := int(s7.prey_slots[0]["hp"])
	_pstep(s7)
	if int(s7.prey_slots[0]["hp"]) != hp7 \
			or int(((s7.prey_slots[0]["credited"] as Array))[0]) != 0:
		bad.append("missing identity damaged/credited an entity")
	if not _rows_with_field(_events_with_tick(s7, 11), 5, "hit").is_empty():
		bad.append("missing identity emitted a hit")
	if not _rows_with_field(_events_with_tick(s7, 10), 2, 8).is_empty():
		bad.append("missing identity emitted a CANCEL")
	if not _rows_with_field(_events_with_tick(s7, 12), 1, 2).is_empty():
		bad.append("missing identity emitted target DAMAGE")
	# R8: valid expanded monster prior arrival settles once against the TARGET monster.
	var s5 := _baby_sim()
	_baby_freeze(s5)
	var e4 := _baby_damage_effect(5, 0, "monster", 1, 1, 500)
	e4["impact_tick"] = 1
	s5.pending_effects = [e4]
	var m1_hp := int(s5.actors[1]["hp"])
	var m1_def := int(s5.actors[1]["def"])
	var m1_k := int(s5.actors[1]["k_defense"])
	_pstep(s5)
	# S2: default DEF25/k100 mitigation yields round(500 * 100/100 * 100/125) = 400.
	var expected_loss := 400
	if int(s5.actors[1]["hp"]) != m1_hp - expected_loss:
		bad.append("valid monster arrival HP %d != expected %d (DEF=%d k=%d)" % [
			int(s5.actors[1]["hp"]), m1_hp - expected_loss, m1_def, m1_k])
	var mon_dmg := _rows_with_field(_events_with_tick(s5, 12), 1, 1)
	if mon_dmg.is_empty():
		bad.append("valid monster arrival emitted no target DAMAGE")
	else:
		var dp: Array = (mon_dmg[0] as Array)[1]
		if dp.size() != 11 or int(dp[8]) != expected_loss or int(dp[0]) != 5:
			bad.append("target DAMAGE effective/identity %d/%d != %d/5" % [
				int(dp[8]) if dp.size() > 8 else -1, int(dp[0]), expected_loss])
	# R8: mutual monster KO is nonterminal with two independent return schedules.
	var s6 := _baby_sim()
	s6.pending_effects = [
		_baby_damage_effect(6, 1, "monster", 0, 1, 20000),
		_baby_damage_effect(7, 0, "monster", 1, 1, 20000),
	]
	s6._cut5_baby()
	if bool(s6.actors[0]["alive"]) or bool(s6.actors[1]["alive"]):
		bad.append("mutual KO did not down both monsters")
	if s6.ended or not s6.ko_actors.is_empty():
		bad.append("mutual KO fabricated a winner/end")
	if int(s6.actors[0]["return_due"]) < 0 or int(s6.actors[1]["return_due"]) < 0:
		bad.append("mutual KO did not schedule both returns")
	_record("B12-mutual-ko-effects", bad.is_empty(),
		"prior arrival settles once, down source survives, obsolete/incomplete identity rejected, mutual KO nonterminal; problems=[%s]" % ", ".join(bad))


func _baby_case_end() -> void:
	var s := _baby_sim()
	_mtick(s, 5399)
	s.actors[0]["alive"] = false
	s.actors[0]["lifecycle"] = "down"
	s.actors[0]["hp"] = 0
	s.actors[0]["life"] = 1
	s.actors[0]["return_due"] = 5400
	s.actors[0]["return_wait_announced"] = false
	_pstep(s)
	var bad: Array = []
	if not s.ended or s.end_reason != 3 or s.terminal_category() != "baby_complete":
		bad.append("5400 did not end with reason3")
	if bool(s.actors[0]["alive"]):
		bad.append("return/respawn occurred on the terminal boundary")
	if int(s.summary().get("end_reason_id", -1)) != 3:
		bad.append("summary end reason")
	var s2 := _baby_sim()
	_mtick(s2, 5399)
	s2.aborted = true
	_pstep(s2)
	if not s2.ended or s2.end_reason != 4 or s2.terminal_category() != "aborted":
		bad.append("abort did not win precedence")
	_record("B13-end-precedence", bad.is_empty(),
		"5400 ends before placements; requested abort wins same boundary; problems=[%s]" % ", ".join(bad))


func _baby_case_schema() -> void:
	# R3: the bundle must actually contain a valid serialized IMPACT (cut3 hit) and a monster KO,
	# plus a prey depletion. Build through the real production step with two due arrivals.
	var s := _baby_sim()
	_baby_freeze(s)
	s.actors[1]["hp"] = 1
	s.prey_slots[0]["hp"] = 2400
	var e_mon := _baby_damage_effect(1, 0, "monster", 1, 1, 1800)
	e_mon["impact_tick"] = 1
	var e_prey := _baby_damage_effect(2, 0, "prey", 0, 1, 2400)
	e_prey["impact_tick"] = 1
	s.pending_effects = [e_mon, e_prey]
	_pstep(s)
	# S1: exercise the REAL blocked producers for both wait transitions (labeled synthetic
	# radii at their actual due ticks), then roundtrip the serialized records.
	s.actors[1]["radius"] = 6000.0
	s.prey_slots[0]["radius"] = 6000.0
	s.actors[1]["return_wait_announced"] = false
	s.prey_slots[0]["spawn_wait_announced"] = false
	_mtick(s, int(s.actors[1]["return_due"]))
	s._process_due_lifecycles(0)
	_mtick(s, int(s.prey_slots[0]["respawn_due"]))
	s._process_due_lifecycles(0)
	var lc_events := _events_with_tick(s, 27)
	var has_return_wait := false
	var has_spawn_wait := false
	for ev in lc_events:
		var trp: Array = (ev as Array)[1]
		if str(trp[0]) == "return_wait":
			has_return_wait = true
		elif str(trp[0]) == "spawn_wait":
			has_spawn_wait = true
	s.telemetry.close_footer(s.summary(), true)
	var res := s.telemetry.prepare_bundle()
	var text := (s.telemetry.prepared_bytes as PackedByteArray).get_string_from_utf8()
	var dec := M01Telemetry.decode_bundle(text)
	var bad: Array = []
	if not has_return_wait or not has_spawn_wait:
		bad.append("real wait producers did not emit both transitions")
	if not bool(dec["ok"]) or str((dec["header"] as Dictionary).get("schema", "")) != "m01.2":
		bad.append("expanded bundle not decodable as m01.2: %s" % str(dec["errors"]))
	var dmg: Array = _events_of_type(s, 12)
	var prey_dmg := false
	for ev in dmg:
		var pay: Array = ev[3]
		if pay.size() == 11 and str(pay[1]) == "2":
			prey_dmg = true
	if not prey_dmg:
		bad.append("prey DAMAGE row lacks target life/credit fields")
	if _events_of_type(s, 11).is_empty():
		bad.append("valid serialized IMPACT row absent")
	if _events_of_type(s, 19).is_empty():
		bad.append("valid serialized monster KO row absent")
	if _events_of_type(s, 28).is_empty() or (_events_of_type(s, 28)[0][3] as Array).size() != 12:
		bad.append("HUNT_REWARD shape != 12 fields")
	if _events_of_type(s, 27).is_empty() or (_events_of_type(s, 27)[0][3] as Array).size() != 7:
		bad.append("BABY_LIFECYCLE shape != 7 fields")
	var bad_text := text.replace("\"m01.2\"", "\"m01.9\"")
	if bool(M01Telemetry.decode_bundle(bad_text)["ok"]):
		bad.append("unknown schema version accepted")
	# R3: every required malformed family must construct AND be rejected.
	var lines := text.split("\n")
	for mutant in [
		["map", "arbitrary entity mapping accepted"],
		["entity", "out-of-range target entity accepted"],
		["transition_kind", "prey transition on a monster entity accepted"],
		["wait_entity", "wait transition on the wrong entity class accepted"],
		["null_gen", "valid hit with null generation accepted"],
		["zero_gen", "zero generation accepted"],
		["near_int", "near-integer identity accepted"],
		["out_of_range", "out-of-range identity accepted"],
		["gen", "fractional identity accepted"],
		["transition", "unknown transition accepted"],
		["type", "unknown event type accepted"],
		["length", "wrong row length accepted"]]:
		var mut := _mutate_expanded_bundle(lines, str(mutant[0]))
		if mut == "":
			bad.append("required mutant '%s' could not be constructed" % str(mutant[0]))
		elif bool(M01Telemetry.decode_bundle(mut)["ok"]):
			bad.append(str(mutant[1]))
	var leg := _new_sim(3101, "live")
	leg.telemetry.close_footer(leg.summary(), true)
	leg.telemetry.prepare_bundle()
	var ldec := M01Telemetry.decode_bundle((leg.telemetry.prepared_bytes as PackedByteArray).get_string_from_utf8())
	if not bool(ldec["ok"]) or str((ldec["header"] as Dictionary).get("schema", "")) != "m01.1":
		bad.append("legacy bundle changed")
	# C07: canonical fingerprint distinguishes same-count queue/effect/route mutations.
	var f := _baby_sim()
	f.gateway.stage({"schema": "m01.1", "trainer": 0, "actor": 0, "sequence": 1, "slot": 0,
		"family": 1, "target_kind": 0, "target_or_area": null, "observed_tick": 0}, 5, 1)
	f.gateway.stage({"schema": "m01.1", "trainer": 1, "actor": 1, "sequence": 2, "slot": 1,
		"family": 2, "target_kind": 0, "target_or_area": null, "observed_tick": 0}, 6, -1)
	var h1 := M01Telemetry.canonical_state_sha256(f.canonical_state())
	var h_again := M01Telemetry.canonical_state_sha256(f.canonical_state())
	if h1 != h_again:
		bad.append("repeated unchanged fingerprint differed")
	f.gateway.staged[0]["family"] = 3
	var h2 := M01Telemetry.canonical_state_sha256(f.canonical_state())
	if h1 == h2:
		bad.append("same-count queue family mutation not fingerprinted")
	f.gateway.staged[0]["family"] = 1
	# S4: compare two LAWFUL known-area commands (target_kind 3) that differ only in hint.
	f.gateway.staged[0]["target_kind"] = 3
	f.gateway.staged[0]["target_or_area"] = [6000, 6000]
	var hint_a: Dictionary = f.gateway.staged[0].duplicate(true)
	var base_state := M01Telemetry.canonical_state_sha256(f.canonical_state())
	if base_state != M01Telemetry.canonical_state_sha256(f.canonical_state()):
		bad.append("unchanged lawful hint-A fingerprint differed")
	f.gateway.staged[0]["target_or_area"] = [7000, 6000]
	var h2t := M01Telemetry.canonical_state_sha256(f.canonical_state())
	if base_state == h2t:
		bad.append("same-count lawful area hint mutation not fingerprinted")
	var hint_b: Dictionary = f.gateway.staged[0].duplicate(true)
	if not f.gateway._valid_hint(3, hint_a["target_or_area"], f.actors[0], f.actors, f.tick) \
			or not f.gateway._valid_hint(3, hint_b["target_or_area"], f.actors[0], f.actors, f.tick) \
			or f.gateway.staged.size() != 2 \
			or h2t != M01Telemetry.canonical_state_sha256(f.canonical_state()):
		bad.append("lawful hint fixture/repeated fingerprint changed")
	hint_b["target_or_area"] = hint_a["target_or_area"]
	if hint_b != hint_a:
		bad.append("lawful hint pair differed in another envelope field")
	f.gateway.staged[0]["target_kind"] = 0
	f.gateway.staged[0]["target_or_area"] = null
	# Empty slot is an intentional negative envelope, with its own kind0/null baseline.
	var empty_slot_base := M01Telemetry.canonical_state_sha256(f.canonical_state())
	f.gateway.staged[0]["slot"] = 7
	var h2s := M01Telemetry.canonical_state_sha256(f.canonical_state())
	if empty_slot_base == h2s:
		bad.append("same-count slot mutation not fingerprinted")
	f.gateway.staged[0]["slot"] = 0
	f.pending_effects = [_baby_damage_effect(1, 0, "prey", 0, 1, 500)]
	var h3 := M01Telemetry.canonical_state_sha256(f.canonical_state())
	f.pending_effects[0]["base_power_cp"] = 900
	var h4 := M01Telemetry.canonical_state_sha256(f.canonical_state())
	if h3 == h4:
		bad.append("effect power mutation not fingerprinted")
	f.prey_slots[0]["route"] = [[6000.0, 6000.0], [7000.0, 6000.0]]
	var h5 := M01Telemetry.canonical_state_sha256(f.canonical_state())
	f.prey_slots[0]["route"] = [[6000.0, 6000.0], [7000.0, 6100.0]]
	var h6 := M01Telemetry.canonical_state_sha256(f.canonical_state())
	if h5 == h6:
		bad.append("prey route mutation not fingerprinted")
	_record("B14-telemetry-schema", bad.is_empty(),
		"m01.2 strict decode/negatives, legacy m01.1, causal fingerprint mutations; problems=[%s]" % ", ".join(bad))


## Builds a malformed expanded bundle variant from a valid one for one negative category.
## An empty return means the required mutation could not be constructed (a case failure).
func _mutate_expanded_bundle(lines: PackedStringArray, kind: String) -> String:
	var out: Array = []
	var mutated := false
	for raw in lines:
		var line := str(raw)
		var parsed: Variant = JSON.parse_string(line)
		if kind == "map" and not mutated and parsed is Dictionary \
				and (parsed as Dictionary).has("entity_map"):
			var hdr := (parsed as Dictionary).duplicate(true)
			var em: Dictionary = hdr["entity_map"]
			em["2"] = "preyX"
			hdr["entity_map"] = em
			out.append(JSON.stringify(hdr))
			mutated = true
			continue
		if parsed is Array and (parsed as Array).size() == 4:
			var ev := (parsed as Array).duplicate(true)
			var type_id := int(ev[2])
			if not mutated:
				match kind:
					"entity":
						if type_id == 12:
							(ev[3] as Array)[1] = 999
							mutated = true
					"transition_kind":
						if type_id == 27 and str((ev[3] as Array)[0]) == "prey_depleted":
							(ev[3] as Array)[1] = 0
							mutated = true
					"wait_entity":
						if type_id == 27 and str((ev[3] as Array)[0]) == "return_wait":
							(ev[3] as Array)[1] = 2
							mutated = true
					"null_gen":
						if type_id == 11 and str((ev[3] as Array)[5]) == "hit":
							(ev[3] as Array)[4] = null
							mutated = true
					"zero_gen":
						if type_id == 19:
							(ev[3] as Array)[1] = 0
							mutated = true
					"near_int":
						if type_id == 12:
							(ev[3] as Array)[9] = 1.0000000005
							mutated = true
					"out_of_range":
						if type_id == 12:
							(ev[3] as Array)[9] = 1.0e300
							mutated = true
					"gen":
						if type_id == 12:
							(ev[3] as Array)[9] = 1.5
							mutated = true
					"transition":
						if type_id == 27:
							(ev[3] as Array)[0] = "bogus_transition"
							mutated = true
					"length":
						if type_id == 27:
							(ev[3] as Array).pop_back()
							mutated = true
					"type":
						ev[2] = 99
						mutated = true
			if mutated:
				out.append(JSON.stringify(ev))
				continue
		out.append(line)
	return "\n".join(out) if mutated else ""


func _baby_case_projection() -> void:
	var s := _baby_sim()
	s.actors[0]["alive"] = false
	s.actors[0]["lifecycle"] = "down"
	s.actors[0]["return_due"] = s.tick + 300
	var v := s.presentation_view_for_human()
	var bad: Array = []
	if str((v["own"] as Dictionary).get("status", "")) != "down":
		bad.append("down status not exposed")
	if int((v["enemy"] as Dictionary).get("knowledge", -1)) != 0 \
			or (v["enemy"] as Dictionary).get("position", "x") != null:
		bad.append("down observer exposed enemy sample")
	if (v["prey"] as Array).size() != 0:
		bad.append("down observer exposed prey")
	if (v["nests"] as Array).size() != 2:
		bad.append("nest layout missing")
	if v.has("progression") or v.has("ledger"):
		bad.append("growth numbers leaked to UI projection")
	if str(v.get("terminal_category", "x")) != "":
		bad.append("terminal category before end")
	s.actors[0]["alive"] = true
	s.actors[0]["x"] = 6000.0
	s.actors[0]["y"] = 6000.0
	s.prey_slots[0]["x"] = 6100.0
	s.prey_slots[0]["y"] = 6000.0
	s.prey_slots[1]["x"] = 19000.0
	s.prey_slots[1]["y"] = 11000.0
	var v2 := s.presentation_view_for_human()
	if (v2["prey"] as Array).size() != 1:
		bad.append("visible prey sample count %d != 1" % (v2["prey"] as Array).size())
	elif not (v2["prey"] as Array).is_empty():
		var sample: Dictionary = (v2["prey"] as Array)[0]
		if sample.has("hp") or sample.has("credited"):
			bad.append("prey numeric state leaked")
	else:
		bad.append("guarded sample indexing: missing prey sample reported")
	_record("B15-safe-projection", bad.is_empty(),
		"copied own status, hidden denial, visible-only prey, nests, no growth values, guarded indexing; problems=[%s]" % ", ".join(bad))


func _baby_case_categories() -> void:
	var s := _baby_sim()
	var a: Dictionary = s.actors[0]
	var bad: Array = []
	a["bound_active"] = true
	a["bound_action"] = 7
	a["onset_bound_action"] = -1
	a["bound_purpose"] = 2
	s._capture_onset(a, {"bound": true})
	if str(s.onset_slots[0]) != "defensive_evasion":
		bad.append("defensive Bound not DEF-category")
	a["bound_action"] = 8
	a["onset_bound_action"] = -1
	a["bound_purpose"] = 3
	s._capture_onset(a, {"bound": true})
	if str(s.onset_slots[0]) != "escape":
		bad.append("escape Bound not RUN-category")
	a["bound_active"] = false
	s.onset_slots = {0: "", 1: ""}
	a["onset_prior_moving"] = false
	a["onset_prior_category"] = ""
	a["goal"] = {"kind": "move", "purpose": "disengage", "route": [[0, 0]], "point": [0, 0],
		"stop_mwu": 0.0, "patrol_index": -1, "i": 0}
	s._capture_onset(a, {"bound": false})
	if str(s.onset_slots[0]) != "escape":
		bad.append("ordinary retreat not RUN-category")
	s.onset_slots = {0: "", 1: ""}
	a["onset_prior_moving"] = false
	a["onset_prior_category"] = ""
	a["goal"] = {"kind": "move", "purpose": "approach", "route": [[0, 0]], "point": [0, 0],
		"stop_mwu": 0.0, "patrol_index": -1, "i": 0}
	s._capture_onset(a, {"bound": false})
	if str(s.onset_slots[0]) != "other":
		bad.append("approach produced a callout category")
	# brace onset and quick release
	_mtick(s, 10)
	a["brace_start"] = 9
	a["brace_end"] = 15
	a["onset_prior_brace"] = false
	s._publish_public_actions()
	if str(s.onset_slots[0]) != "active_defense":
		bad.append("active Brace onset missing")
	s.onset_slots = {0: "", 1: ""}
	s.quick_releases = []
	a["x"] = 6000.0
	a["y"] = 6000.0
	s.actors[1]["x"] = 6400.0
	s.actors[1]["y"] = 6000.0
	s.actors[1]["alive"] = true
	a["enemy_visible"] = true
	a["action"] = {"action": 1, "actor": 0, "life": 1, "life_id": 1,
		"target_ref": {"kind": "monster", "id": 1, "life_id": 1},
		"target_life_id": 1, "request": 0, "episode": 0, "intent": -1, "owning_family": 1,
		"skill": "quick_claw", "target": 1, "target_kind": 2, "start_tick": 0, "due_tick": 0,
		"recovery_ticks": 21, "paid_cost": 600, "cooldown_end": 0, "stability": 1,
		"interrupt_power": 1, "state": "due", "cancel_cause": "", "plan": {}}
	s._cut4()
	if s.quick_releases.is_empty() or int(s.quick_releases[0]["side"]) != 0:
		bad.append("quick release not recorded for own side")
	elif int(s.quick_releases[0].get("life_id", -1)) != 1:
		bad.append("quick release did not carry the captured source life")
	# C09: a release from a new life carries the new generation (so a stale-life mark cannot
	# be inherited by the replacement).
	s.quick_releases = []
	a["life_id"] = 2
	a["action"] = {"action": 2, "actor": 0, "life": 1, "life_id": 2,
		"target_ref": {"kind": "monster", "id": 1, "life_id": 1},
		"target_life_id": 1, "request": 0, "episode": 0, "intent": -1, "owning_family": 1,
		"skill": "quick_claw", "target": 1, "target_kind": 2, "start_tick": 0, "due_tick": 0,
		"recovery_ticks": 21, "paid_cost": 600, "cooldown_end": 0, "stability": 1,
		"interrupt_power": 1, "state": "due", "cancel_cause": "", "plan": {}}
	s._cut4()
	if s.quick_releases.is_empty() or int(s.quick_releases[0].get("life_id", -1)) != 2:
		bad.append("new-life quick release did not carry the new generation")
	# R5/R6/R7: real producer-to-snapshot consumer ordering.
	var pres := M01Presentation.new()
	# Hidden enemy at tick5, then a lawful enemy release captured for tick6 BEFORE its snapshot.
	pres.receive_public_snapshot(_baby_view(5, [6000, 6000], 1, "alive", "", 0, null, -1, ""))
	pres.on_quick_release(1, 1, 6, 7000.0, 6000.0, 1)
	pres.receive_public_snapshot(_baby_view(6, [6000, 6000], 1, "alive", "", 2, [7000, 6000], 1, "claw"))
	if (pres.slash_slots.get(1, {}) as Dictionary).is_empty() \
			or int((pres.slash_slots.get(1, {}) as Dictionary).get("tick", -1)) != 6:
		bad.append("current lawful release was discarded by the first visible snapshot")
	# S3: same-life KO at tick7 suppresses the visible-enemy transient even when the SAME
	# snapshot also carries a performed onset captured before cut5.
	pres.receive_public_snapshot(_baby_view(7, [6000, 6000], 1, "alive", "", 2, [7000, 6000], 1,
		"ko", "", "defensive_evasion"))
	if not (pres.slash_slots.get(1, {}) as Dictionary).is_empty() \
			or not (pres.callouts.get(1, {}) as Dictionary).is_empty():
		bad.append("same-life enemy KO did not dominate its conflicting onset")
	# S3: own down + action ko + escape onset must also stay empty.
	pres.on_quick_release(0, 1, 8, 6000.0, 6000.0, 1)
	pres.receive_public_snapshot(_baby_view(8, [6000, 6000], 1, "down", "ko", 0, null, -1, "",
		"escape", ""))
	if not (pres.slash_slots.get(0, {}) as Dictionary).is_empty() \
			or not (pres.callouts.get(0, {}) as Dictionary).is_empty():
		bad.append("same-life own down did not dominate its conflicting onset")
	# Living counterparts still receive their genuine onset text.
	pres.receive_public_snapshot(_baby_view(9, [6000, 6000], 1, "alive", "", 2, [7000, 6000], 1,
		"claw"))
	if str((pres.callouts.get(0, {}) as Dictionary).get("text", "")) != "":
		bad.append("stale own callout survived the living reset")
	pres.receive_public_snapshot(_baby_view(10, [6000, 6000], 1, "alive", "", 2, [7000, 6000], 1,
		"claw", "escape", "defensive_evasion"))
	if str((pres.callouts.get(0, {}) as Dictionary).get("text", "")) != "RUN!" \
			or str((pres.callouts.get(1, {}) as Dictionary).get("text", "")) != "DEF!":
		bad.append("living counterparts did not receive genuine DEF/RUN onset text")
	# R6/S4: pause invalidates movement baselines but preserves frozen slash/text age.
	pres.on_quick_release(0, 1, 11, 6000.0, 6000.0, 1)
	var born_before := float((pres.slash_slots.get(0, {}) as Dictionary).get("born", -1.0))
	pres.receive_public_snapshot(_baby_view(11, [6000, 6000], 1, "alive", "", 0, null, -1, ""))
	pres.receive_public_snapshot(_baby_view(12, [6050, 6000], 1, "alive", "", 0, null, -1, ""))
	if not pres.own_moving:
		bad.append("consecutive visible displacement did not register movement")
	pres._on_host_state_changed(true, "manual")
	if pres.own_moving or pres.own_prev_pos != null:
		bad.append("pause did not invalidate the movement baseline")
	if (pres.slash_slots.get(0, {}) as Dictionary).is_empty() \
			or absf(float((pres.slash_slots.get(0, {}) as Dictionary).get("born", -1.0)) - born_before) > 1e-9:
		bad.append("pause did not preserve the frozen slash age")
	pres._on_host_state_changed(false, "resume")
	pres.receive_public_snapshot(_baby_view(13, [6100, 6000], 1, "alive", "", 0, null, -1, ""))
	if pres.own_moving:
		bad.append("first resumed sample re-used a pre-pause baseline")
	pres.receive_public_snapshot(_baby_view(14, [6150, 6000], 1, "alive", "", 0, null, -1, ""))
	if not pres.own_moving:
		bad.append("later resumed actual movement did not draw")
	pres.free()
	_record("B16-action-categories", bad.is_empty(),
		"DEF/RUN/other onset mapping, life-bound Quick release, current-release retention, KO-dominated onsets, pause/restore baseline; problems=[%s]" % ", ".join(bad))


func _baby_view(tv: int, own_pos: Array, own_life: int, own_status: String, own_action: String,
		en_k: int, en_pos: Variant, en_life: int, en_action: String,
		own_onset: String = "", en_onset: String = "") -> Dictionary:
	var en := {"knowledge": en_k, "position": en_pos if en_k == 2 else null,
		"life_id": en_life if en_k == 2 else null, "action": en_action if en_k == 2 else "",
		"facing": 2, "performed_onset": en_onset if en_k == 2 else "",
		"last_known_position": null, "hp_band": 4, "last_seen_tick": tv}
	return {"tick": tv, "own": {"position": own_pos, "life_id": own_life,
		"status": own_status, "action": own_action, "facing": 2,
		"performed_onset": own_onset, "growth_tick": -1, "return_tick": -1}, "enemy": en,
		"prey": [], "nests": [], "terminal_category": ""}


func _baby_case_legacy() -> void:
	var s := _new_sim(3101, "live")
	var bad: Array = []
	if s.is_expanded() or s.schema_name() != "m01.1":
		bad.append("legacy mode/schema changed")
	if int(s.actors[0]["x"]) != 4000 or int(s.actors[1]["x"]) != 16000:
		bad.append("legacy base spawns changed")
	if int(content.tuning["timeout_active_ticks"]) != 10800:
		bad.append("legacy timeout changed")
	# C12/QA-F06: a lawful due qualified arrival at its real settlement boundary drives an actual
	# damage -> KO -> END chain through the production step (no direct _cut5 substitute).
	_baby_freeze(s)
	s.actors[1]["hp"] = 1
	var eff := {"effect": 1, "action": 0, "source": 0, "target": 1, "kind": "damage",
		"impact_tick": 1, "interrupt_power": 1, "qualification": "qualified", "batch": 0,
		"base_power_cp": 1800, "source_atk": 100, "target_def": 25,
		"brace_factor_bp": 10000, "phase_factor_bp": 10000}
	s.pending_effects = [eff]
	_pstep(s)
	if not s.ended or s.end_reason != 1 or s.ko_actors != [1]:
		bad.append("legacy damage->KO->END chain did not complete (ended=%s reason=%d ko=%s)" % [
			str(s.ended), s.end_reason, str(s.ko_actors)])
	if _events_with_tick(s, 19).is_empty():
		bad.append("legacy KO row missing")
	_record("B17-legacy-preservation", bad.is_empty(),
		"2 actors, base spawns, 10800 timeout, m01.1, real first-KO endpoint; problems=[%s]" % ", ".join(bad))


func _append_note(title: String, body: String) -> void:
	print("%s: %s" % [title, body])


# ------------------------------------------------------------------- output

func _finish(exit_code: int) -> void:
	var wall := Time.get_ticks_msec() - started_msec
	var pass_n := 0
	var fail_n := 0
	var nr_n := 0
	for r in results:
		if bool(r.get("not_run", false)):
			nr_n += 1
		elif bool(r["pass"]):
			pass_n += 1
		else:
			fail_n += 1
	print("")
	print("=== M01 checks: %d pass, %d fail, %d not run (%d ms) ===" % [
		pass_n, fail_n, nr_n, wall])
	_write_results(pass_n, fail_n, nr_n, wall)
	if checked_sink:
		# RUN01: a selected-route run never exits 0 without a complete, decodable result file and
		# its completion marker, both written and read back inside the profile deadline. Checked
		# write/readback therefore affects the final exit for play01_focus and dev_smoke only.
		sink_ok = false
		complete_marker = ""
		sink_late_reason = ""
		var dl := _sink_deadline_ms()
		var deadline_ok := false
		var readable := false
		var marked := false
		# RUN01 F04: positive remainder must still exist before any sink work begins. The result
		# file is already on disk at this point, so a refused sink stays preserved as evidence.
		if dl > 0 and Time.get_ticks_msec() >= dl:
			sink_late_reason = "profile deadline %dms exhausted before checked sink work" % dl
			printerr("ERROR: checked sink refused; " + sink_late_reason)
		else:
			readable = _readback_ok(pass_n, fail_n, nr_n)
			if readable:
				marked = _write_complete_marker(pass_n, fail_n, nr_n)
			# RUN01 F04: sampled AFTER the marker write/readback, so a pre-I/O timestamp can
			# never serve as proof that the sink finished inside the original window.
			deadline_ok = dl <= 0 or Time.get_ticks_msec() < dl
		sink_ok = readable and marked and deadline_ok
		print("checked sink: readback=%s completion_marker=%s deadline_ok=%s path=%s marker=%s" % [
			str(readable), str(marked), str(deadline_ok), sink_path, complete_marker])
		if not sink_ok and exit_code == 0:
			if sink_late_reason.is_empty():
				sink_late_reason = "checked sink incomplete: readback=%s completion_marker=%s deadline_ok=%s" % [
					readable, marked, deadline_ok]
			printerr("ERROR: checked sink cannot confer success; " + sink_late_reason)
			exit_code = 1
	quit(exit_code)


func _write_results(pass_n: int, fail_n: int, nr_n: int, wall: int) -> void:
	var path := out_dir
	if path.begins_with("res://"):
		path = ProjectSettings.globalize_path(path)
	var dir := DirAccess.open("user://")
	var abs_path := path
	if not abs_path.ends_with("/"):
		abs_path += "/"
	abs_path += "checks_%s.json" % Time.get_datetime_string_from_system().replace(":", "").replace("T", "-")
	sink_path = abs_path
	sink_ok = false
	complete_marker = ""
	var body := {
		"schema": "m01.1",
		"kind": "junior_check_results",
		"engine": Engine.get_version_info().get("string", "unknown"),
		"platform": OS.get_name(),
		"generated_utc": Time.get_datetime_string_from_system(true),
		"wall_ms": wall,
		"totals": {"pass": pass_n, "fail": fail_n, "not_run": nr_n},
		"results": results,
	}
	if checked_sink:
		# RUN01: the existing schema keeps every original key and gains profile/seed/deadline,
		# step accounting and the exact attempted/unattempted/duplicate ID sets.
		var acct := _id_accounting()
		var dl := _sink_deadline_ms()
		body["profile"] = profile_name
		body["seed"] = profile_seed
		body["deadline"] = {
			"wall_ms": PLAY01_FOCUS_WALL_MS if profile_name == "play01_focus" \
				else (DEV_SMOKE_WALL_MS if profile_name == "dev_smoke" else BABY_WALL_MS),
			"origin_ms": started_msec,
			"absolute_deadline_ms": dl,
			"remaining_ms": (dl - Time.get_ticks_msec()) if dl > 0 else -1,
			# RUN01 F04: positive remainder, not merely "not yet past". This is sampled before
			# the result is written, so it is a necessary condition only; the post-I/O proof
			# travels on the `checked sink:` line and the final exit.
			"ok": dl <= 0 or Time.get_ticks_msec() < dl,
		}
		body["steps"] = {
			"attempted": step_attempts,
			"completed": step_completed,
			# RUN01 F06: dev_smoke reports its existing 120-call cap rather than a 0 ceiling,
			# so the result can never claim no budget while real steps were taken.
			"ceiling": (PLAY01_FOCUS_MAX_STEPS if focus_active
				else (BABY_MAX_STEPS if baby_active
				else (DEV_SMOKE_MAX_TICKS if profile_name == "dev_smoke" else 0))),
			"per_case_max": case_steps_max,
			"manual_tick_jumps": manual_ticks,
		}
		body["attempted_ids"] = acct["attempted"]
		body["unattempted_ids"] = acct["unattempted"]
		body["duplicate_ids"] = acct["duplicates"]
		body["stop"] = {"stopped": stopped, "reason": stop_reason}
	var text := JSON.stringify(body, "\t")
	_write_file(abs_path, text)
	print("wrote %s" % abs_path)


## Returns true only when the file was created and fully written; the selected routes refuse
## a zero exit when this is false.
func _write_file(abs_path: String, text: String) -> bool:
	var parts: Array = abs_path.split("/")
	parts.pop_back()
	var folder := "/".join(parts)
	_make_dirs(folder)
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		print("ERROR: cannot write %s (%s)" % [abs_path, error_string(FileAccess.get_open_error())])
		return false
	f.store_string(text)
	f.close()
	return true


func _make_dirs(folder: String) -> void:
	var acc := ""
	for segment in folder.split("/"):
		if segment.is_empty():
			acc = "/"
			continue
		if acc == "/":
			acc = "/" + segment
		else:
			acc = acc + "/" + segment
		if not DirAccess.dir_exists_absolute(acc):
			DirAccess.make_dir_recursive_absolute(acc)


# ------------------------------------------------------------------ RUN01 selected case blocks
# The blocks below were moved verbatim out of _suite_geometry / _suite_behavior / _suite_stats.
# Both the original suites and the fixed `play01_focus` profile call the SAME function, so
# fixtures, predicates, causal expectations and old-suite order are shared, never duplicated.
# Only two things changed on the way in: a `sim.step()` becomes `_pstep(sim)` (aggregate step
# accounting) and a manual diagnostic tick assignment becomes `_mtick(sim, v)` (counted as a
# jump, never as a simulated step). C55 additionally takes the frozen Brace charge/recovery it
# used to read from C54's locals, so the shared setup dependency is an explicit parameter.

func _case_c26() -> void:
	# C26 ordinary movement consumes goal waypoints at MOV/60 for both sides: per-boundary
	# axis deltas <= 50.001, inside the inset, out of the inflated blocker, and any stamina
	# drop carries a same-tick event 7 (no silent movement-skill debit).
	var mv := _new_sim(3101, "diagnostic")
	var starts: Array = [[4000.0, 3000.0], [16000.0, 9000.0]]
	var ends: Array = [[7000.0, 3000.0], [17000.0, 9000.0]]
	for i in 2:
		mv.actors[i]["x"] = float(starts[i][0])
		mv.actors[i]["y"] = float(starts[i][1])
		_force_move_goal(mv, i, ends[i])
	var stam_prev: Array = [int(mv.actors[0]["stam"]), int(mv.actors[1]["stam"])]
	var prev26: Array = [[float(starts[0][0]), float(starts[0][1])],
		[float(starts[1][0]), float(starts[1][1])]]
	var max_step26 := 0.0
	var inset_ok := true
	var blocker_ok := true
	var done26 := [false, false]
	var uncosted: Array = []
	var steps26 := 0
	for i in 120:
		_pstep(mv)
		steps26 += 1
		for k in 2:
			var np: Array = [float(mv.actors[k]["x"]), float(mv.actors[k]["y"])]
			max_step26 = maxf(max_step26, maxf(
				absf(float(np[0]) - float(prev26[k][0])),
				absf(float(np[1]) - float(prev26[k][1]))))
			if not arena.in_inset(float(np[0]), float(np[1])):
				inset_ok = false
			if arena.in_inflated_blocker(float(np[0]), float(np[1])):
				blocker_ok = false
			prev26[k] = np
			if int(mv.actors[k]["stam"]) < int(stam_prev[k]):
				uncosted.append([k, mv.tick])
			stam_prev[k] = int(mv.actors[k]["stam"])
			if mv.actors[k]["goal"] == null:
				done26[k] = true
		if done26[0] and done26[1]:
			break
	var bound_started := false
	for ev in _events_of_type(mv, 6):
		if str((ev[3] as Array)[4]) == "short_bound":
			bound_started = true
	var abs_tick := 0
	var cost_at: Array = [{}, {}]
	for ev in mv.telemetry.events:
		abs_tick += int(ev[0])
		if int(ev[2]) == 7:
			var pay: Array = ev[3]
			if int(pay[1]) >= 0 and int(pay[1]) < 2:
				var cdict: Dictionary = cost_at[int(pay[1])]
				cdict[abs_tick] = true
	var uncosted_ok := true
	for row in uncosted:
		if not (cost_at[int(row[0])] as Dictionary).has(int(row[1])):
			uncosted_ok = false
	_record("C26-ordinary-movement",
		inset_ok and blocker_ok and uncosted_ok and steps26 >= 40 \
			and max_step26 <= 50.001 + 1e-6 and done26[0] and done26[1] \
			and not bound_started,
		"%d boundaries, max axis step %.4f (limit 50), inset=%s, blocker-clear=%s, costs cited=%s, goals done=%s, bound start=%s" % [
			steps26, max_step26, inset_ok, blocker_ok, uncosted_ok,
			str(done26[0] and done26[1]), bound_started])

func _case_c27() -> void:
	# C27 goal production: approach, disengage, search (both Instinct branches) and
	# patrol ordering all yield schema-valid goals with legal, contract-ordered routes.
	var bad27: Array = []

	# 1) approach: visible Attack intent out of Claw range -> move goal, legal waypoints.
	var ap := _new_sim(3101, "diagnostic")
	var ap_a: Dictionary = ap.actors[0]
	var ap_e: Dictionary = ap.actors[1]
	ap_a["x"] = 4000.0
	ap_a["y"] = 3000.0
	ap_e["x"] = 9000.0
	ap_e["y"] = 3000.0
	ap_a["enemy_visible"] = true
	ap_a["accepted_intent"] = {"intent": 1, "episode": 1, "family": 1,
		"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
		"target_or_area": null, "goal": null}
	ap._refresh_gates(ap_a)
	ap._refresh_gates(ap_e)
	var ap_plan: Dictionary = ap.behavior.plan(ap_a, ap_e, 0, "visible")
	var ap_goal: Variant = ap_plan.get("goal", null)
	var ap_errs := _goal_schema_ok(ap_goal, arena)
	if not ap_errs.is_empty():
		bad27.append("approach schema: " + "; ".join(ap_errs))
	elif ap_goal is Dictionary:
		if str(ap_plan.get("fit_reason", "")) != "attack" \
				or str((ap_goal as Dictionary).get("purpose", "")) != "approach":
			bad27.append("approach fit=%s purpose=%s" % [str(ap_plan.get("fit_reason", "")),
				str((ap_goal as Dictionary).get("purpose", ""))])
		for wp in (ap_goal as Dictionary).get("route", []) as Array:
			if not arena.center_legal(float(wp[0]), float(wp[1])):
				bad27.append("approach waypoint illegal [%s, %s]" % [str(wp[0]), str(wp[1])])
				break

	# 2) disengage: Run intent in a corner where every Bound direction gains < 1000,
	# so the plan keeps the best positive-gain move route instead of starting a Bound.
	var dis := _new_sim(3101, "diagnostic")
	var dis_a: Dictionary = dis.actors[0]
	var dis_e: Dictionary = dis.actors[1]
	dis_a["x"] = 1250.0
	dis_a["y"] = 600.0
	dis_e["x"] = 2250.0
	dis_e["y"] = 1600.0
	dis_a["enemy_visible"] = true
	dis_a["accepted_intent"] = {"intent": 1, "episode": 1, "family": 3,
		"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
		"target_or_area": null, "goal": null}
	dis._refresh_gates(dis_a)
	dis._refresh_gates(dis_e)
	var dis_plan: Dictionary = dis.behavior.plan(dis_a, dis_e, 0, "visible")
	var dis_goal: Variant = dis_plan.get("goal", null)
	var dis_errs := _goal_schema_ok(dis_goal, arena)
	if not dis_errs.is_empty():
		bad27.append("disengage schema: " + "; ".join(dis_errs))
	elif dis_goal is Dictionary:
		if str((dis_goal as Dictionary).get("purpose", "")) != "disengage":
			bad27.append("disengage purpose=%s" % str((dis_goal as Dictionary).get("purpose", "")))
	var gain_best := -INF
	for o in dis.behavior.bound_candidates(dis_a, [2250.0, 1600.0]):
		gain_best = maxf(gain_best, float(o["gain"]))
	if not (gain_best > 0.0 and gain_best < 1000.0):
		bad27.append("corner bound gain=%.1f expected (0,1000)" % gain_best)

	# 3a) search, Instinct >= 0.5: memory centre first, then the four legal probes in
	# authored order +x, -x, +y, -y.
	var s_hi := _new_sim(3101, "diagnostic")
	var hi_a: Dictionary = s_hi.actors[0]
	hi_a["x"] = 16000.0
	hi_a["y"] = 3000.0
	hi_a["enemy_visible"] = false
	hi_a["memory_valid"] = true
	hi_a["memory_x"] = 16000.0
	hi_a["memory_y"] = 3000.0
	hi_a["memory_last_seen_tick"] = 0
	hi_a["memory_expiry"] = 100000
	hi_a["instinct"] = 80
	hi_a["search_visited"] = []
	var hi_goals: Array = s_hi.behavior.search_goals(hi_a)
	var hi_want: Array = [[16000.0, 3000.0], [17000.0, 3000.0], [15000.0, 3000.0],
		[16000.0, 4000.0], [16000.0, 2000.0]]
	if hi_goals.size() != hi_want.size():
		bad27.append("search J80 returned %d goals" % hi_goals.size())
	else:
		for i in hi_want.size():
			if not _pt_eq(hi_goals[i], hi_want[i]):
				bad27.append("search J80 goal %d = %s expected %s" % [i, hi_goals[i], hi_want[i]])
				break

	# 3b) search, Instinct < 0.5: memory centre then exactly one public patrol point.
	var s_lo := _new_sim(3101, "diagnostic")
	var lo_a: Dictionary = s_lo.actors[0]
	lo_a["x"] = 4000.0
	lo_a["y"] = 3000.0
	lo_a["enemy_visible"] = false
	lo_a["memory_valid"] = true
	lo_a["memory_x"] = 6000.0
	lo_a["memory_y"] = 3000.0
	lo_a["memory_last_seen_tick"] = 0
	lo_a["memory_expiry"] = 100000
	lo_a["instinct"] = 20
	lo_a["search_visited"] = []
	var lo_goals: Array = s_lo.behavior.search_goals(lo_a)
	var lo_ok := lo_goals.size() == 2 and _pt_eq(lo_goals[0], [6000.0, 3000.0])
	if lo_ok:
		var on_patrol := false
		for pt in arena.patrol:
			if _pt_eq(lo_goals[1], pt):
				on_patrol = true
		lo_ok = on_patrol
	if not lo_ok:
		bad27.append("search J20 goals=%s expected centre + one patrol point" % [lo_goals])

	# 4) patrol_goals: nearest unvisited first, ties by authored index.
	var s_pt := _new_sim(3101, "diagnostic")
	var pt_a: Dictionary = s_pt.actors[0]
	pt_a["x"] = 4000.0
	pt_a["y"] = 3000.0
	pt_a["patrol_visited"] = [0]
	var pt_first: Array = s_pt.behavior.patrol_goals(pt_a)[0]
	var pt_expect := -1
	var pt_best := INF
	for i in arena.patrol.size():
		if (pt_a["patrol_visited"] as Array).has(i):
			continue
		var dd27 := _dist([float(pt_a["x"]), float(pt_a["y"])], arena.patrol[i])
		if dd27 < pt_best - 1e-9:
			pt_best = dd27
			pt_expect = i
	if pt_expect < 0 or not _pt_eq(pt_first, arena.patrol[pt_expect]):
		bad27.append("patrol first=%s expected index %d" % [pt_first, pt_expect])
	pt_a["patrol_visited"] = [0, 3]
	var pt_second: Array = s_pt.behavior.patrol_goals(pt_a)[0]
	if not _pt_eq(pt_second, [12000.0, 3000.0]):
		bad27.append("patrol after [0,3] first=%s expected [12000, 3000]" % [pt_second])
	_record("C27-goal-production", bad27.is_empty(),
		"approach/disengage/search(J80,J20)/patrol goals correct" if bad27.is_empty() \
			else "; ".join(bad27))

func _case_c28() -> void:
	# FIX01/G1 — QA-F01 prepared traversal fixtures: corner arc progress, a stationary peer
	# contact resolved along the true path, last-node truncation, same-node chains, mirrored
	# actor sides and swept-clear orthogonal connectors. Arithmetic hand-derived from source.
	var g1_bad: Array = []
	var g1_route: Array = [[4000.0, 3000.0], [4250.0, 3000.0], [4250.0, 3250.0]]
	var g1_total := arena.route_length(g1_route)

	# (a) Corner traversal: progress150 from (4150,3000) with an unobstructed 200 mWU budget
	#     visits (4250,3000) then (4250,3100) and stores arc progress350. A start-to-end chord
	#     would store 150+sqrt(100^2+100^2)=291.421356 and falsely obstruct.
	var c1 := _new_sim(3101, "diagnostic")
	c1.actors[1]["x"] = 16000.0
	c1.actors[1]["y"] = 9000.0
	c1.actors[0]["x"] = 4150.0
	c1.actors[0]["y"] = 3000.0
	c1.actors[0]["bound_path"] = g1_route.duplicate(true)
	c1.actors[0]["bound_total"] = g1_total
	c1.actors[0]["bound_progress"] = 150.0
	c1.actors[0]["bound_action"] = 7
	c1.actors[0]["bound_active"] = true
	c1._movement_cut()
	if absf(float(c1.actors[0]["x"]) - 4250.0) > 1e-6 \
			or absf(float(c1.actors[0]["y"]) - 3100.0) > 1e-6:
		g1_bad.append("corner endpoint (%.6f, %.6f) != (4250, 3100)" % [
			float(c1.actors[0]["x"]), float(c1.actors[0]["y"])])
	if absf(float(c1.actors[0]["bound_progress"]) - 350.0) > 1e-6:
		g1_bad.append("corner arc progress %.6f != 350" % float(c1.actors[0]["bound_progress"]))
	if not bool(c1.actors[0]["bound_active"]):
		g1_bad.append("corner traversal ended the bound early")
	if not _events_of_type(c1, 26).is_empty():
		g1_bad.append("corner traversal emitted a boundary event")

	# (a2) Open corner: progress200 from (4200,3000), same route, unobstructed 200 mWU budget
	#      ends at (4250,3150) with arc progress400 and the bound still active.
	var c1b := _new_sim(3101, "diagnostic")
	c1b.actors[1]["x"] = 16000.0
	c1b.actors[1]["y"] = 9000.0
	c1b.actors[0]["x"] = 4200.0
	c1b.actors[0]["y"] = 3000.0
	c1b.actors[0]["bound_path"] = g1_route.duplicate(true)
	c1b.actors[0]["bound_total"] = g1_total
	c1b.actors[0]["bound_progress"] = 200.0
	c1b.actors[0]["bound_action"] = 8
	c1b.actors[0]["bound_active"] = true
	c1b._movement_cut()
	if absf(float(c1b.actors[0]["x"]) - 4250.0) > 1e-6 \
			or absf(float(c1b.actors[0]["y"]) - 3150.0) > 1e-6 \
			or absf(float(c1b.actors[0]["bound_progress"]) - 400.0) > 1e-6 \
			or not bool(c1b.actors[0]["bound_active"]):
		g1_bad.append("open corner (%.6f, %.6f) p=%.6f active=%s != (4250, 3150) p=400 active" % [
			float(c1b.actors[0]["x"]), float(c1b.actors[0]["y"]),
			float(c1b.actors[0]["bound_progress"]), str(bool(c1b.actors[0]["bound_active"]))])

	# (a3) Fractional origin: the mover sits mid-segment at (4130,3000) with matching arc
	#      progress130, so the boundary starts at the real position, crosses the corner and
	#      spends the full 200 budget ending at (4250,3080) with progress330.
	var c1c := _new_sim(3101, "diagnostic")
	c1c.actors[1]["x"] = 16000.0
	c1c.actors[1]["y"] = 9000.0
	c1c.actors[0]["x"] = 4130.0
	c1c.actors[0]["y"] = 3000.0
	c1c.actors[0]["bound_path"] = g1_route.duplicate(true)
	c1c.actors[0]["bound_total"] = g1_total
	c1c.actors[0]["bound_progress"] = 130.0
	c1c.actors[0]["bound_action"] = 13
	c1c.actors[0]["bound_active"] = true
	c1c._movement_cut()
	if absf(float(c1c.actors[0]["x"]) - 4250.0) > 1e-6 \
			or absf(float(c1c.actors[0]["y"]) - 3080.0) > 1e-6 \
			or absf(float(c1c.actors[0]["bound_progress"]) - 330.0) > 1e-6 \
			or not bool(c1c.actors[0]["bound_active"]):
		g1_bad.append("fractional origin (%.6f, %.6f) p=%.6f active=%s != (4250, 3080) p=330 active" % [
			float(c1c.actors[0]["x"]), float(c1c.actors[0]["y"]),
			float(c1c.actors[0]["bound_progress"]), str(bool(c1c.actors[0]["bound_active"]))])

	# (b) Same fixture with a stationary peer at (4250,4000): first contact is the tangent at
	#     arc100 of 200, so applied position (4250,3000), arc progress150+100=250, reason
	#     "body_contact", bound ended and short_bound recovery armed for 12 ticks.
	var c2 := _new_sim(3101, "diagnostic")
	c2.actors[1]["x"] = 4250.0
	c2.actors[1]["y"] = 4000.0
	c2.actors[0]["x"] = 4150.0
	c2.actors[0]["y"] = 3000.0
	c2.actors[0]["bound_path"] = g1_route.duplicate(true)
	c2.actors[0]["bound_total"] = g1_total
	c2.actors[0]["bound_progress"] = 150.0
	c2.actors[0]["bound_action"] = 9
	c2.actors[0]["bound_active"] = true
	c2._movement_cut()
	var c2_ev: Array = _events_of_type(c2, 26)
	if absf(float(c2.actors[0]["x"]) - 4250.0) > 1e-6 \
			or absf(float(c2.actors[0]["y"]) - 3000.0) > 1e-6:
		g1_bad.append("peer first contact (%.6f, %.6f) != (4250, 3000)" % [
			float(c2.actors[0]["x"]), float(c2.actors[0]["y"])])
	if absf(float(c2.actors[0]["bound_progress"]) - 250.0) > 1e-6:
		g1_bad.append("peer arc progress %.6f != 250" % float(c2.actors[0]["bound_progress"]))
	if bool(c2.actors[0]["bound_active"]):
		g1_bad.append("peer contact did not end the bound")
	if int(c2.actors[0]["recovery_end"]) != c2.tick + 12:
		g1_bad.append("peer recovery_end %d != tick+12 (%d)" % [
			int(c2.actors[0]["recovery_end"]), c2.tick + 12])
	var c2_reason := ""
	if not c2_ev.is_empty():
		c2_reason = str((c2_ev[0][3] as Array)[4])
	if c2_ev.size() != 2 or c2_reason != "body_contact":
		g1_bad.append("peer boundary events %d reason %s != 2 body_contact" % [
			c2_ev.size(), c2_reason])

	# (b2) Moving peer: mover runs east from (4000,3000) at 200 mWU/boundary while the peer
	#      runs west from (5100,3000) at its ordinary 3000/60=50 mWU/boundary. Gap
	#      1100-250t reaches contact1000 at t=0.4, so first contact commits (4080,3000)
	#      arc80, peer (5080,3000).
	var c4 := _new_sim(3101, "diagnostic")
	c4.actors[0]["x"] = 4000.0
	c4.actors[0]["y"] = 3000.0
	c4.actors[0]["bound_path"] = [[4000.0, 3000.0], [4500.0, 3000.0]]
	c4.actors[0]["bound_total"] = 500.0
	c4.actors[0]["bound_progress"] = 0.0
	c4.actors[0]["bound_action"] = 15
	c4.actors[0]["bound_active"] = true
	c4.actors[1]["x"] = 5100.0
	c4.actors[1]["y"] = 3000.0
	_force_move_goal(c4, 1, [5000.0, 3000.0])
	c4._movement_cut()
	var c4_ev: Array = _events_of_type(c4, 26)
	var c4_reason := ""
	if not c4_ev.is_empty():
		c4_reason = str((c4_ev[0][3] as Array)[4])
	if absf(float(c4.actors[0]["x"]) - 4080.0) > 1e-6 \
			or absf(float(c4.actors[0]["y"]) - 3000.0) > 1e-6:
		g1_bad.append("moving-peer first contact (%.6f, %.6f) != (4080, 3000)" % [
			float(c4.actors[0]["x"]), float(c4.actors[0]["y"])])
	if absf(float(c4.actors[0]["bound_progress"]) - 80.0) > 1e-6 \
			or bool(c4.actors[0]["bound_active"]):
		g1_bad.append("moving-peer arc %.6f active=%s != 80 ended" % [
			float(c4.actors[0]["bound_progress"]), str(bool(c4.actors[0]["bound_active"]))])
	if absf(float(c4.actors[1]["x"]) - 5080.0) > 1e-6:
		g1_bad.append("moving peer applied x %.6f != 5080" % float(c4.actors[1]["x"]))
	if c4_ev.size() != 2 or c4_reason != "body_contact":
		g1_bad.append("moving-peer boundary events %d reason %s != 2 body_contact" % [
			c4_ev.size(), c4_reason])

	# (b3) Blocker traversal: a Bound leg enters the inflated blocker from (8300,6000), so the
	#      static sweep stops the trajectory at x≈8499.999, arc progress is the clipped length
	#      (< budget), the bound ends with reason "static" and short_bound recovery arms.
	var c5 := _new_sim(3101, "diagnostic")
	c5.actors[1]["x"] = 4000.0
	c5.actors[1]["y"] = 9000.0
	c5.actors[0]["x"] = 8300.0
	c5.actors[0]["y"] = 6000.0
	c5.actors[0]["bound_path"] = [[8300.0, 6000.0], [14000.0, 6000.0]]
	c5.actors[0]["bound_total"] = 5700.0
	c5.actors[0]["bound_progress"] = 0.0
	c5.actors[0]["bound_action"] = 17
	c5.actors[0]["bound_active"] = true
	c5._movement_cut()
	var c5_ev: Array = _events_of_type(c5, 26)
	var c5_reason := ""
	if not c5_ev.is_empty():
		c5_reason = str((c5_ev[0][3] as Array)[4])
	var c5x := float(c5.actors[0]["x"])
	var c5p := float(c5.actors[0]["bound_progress"])
	if c5x < 8499.0 or c5x > 8501.0 or absf(float(c5.actors[0]["y"]) - 6000.0) > 1e-6:
		g1_bad.append("blocker stop x=%.6f y=%.6f != x≈8499.999 y=6000" % [
			c5x, float(c5.actors[0]["y"])])
	if c5p <= 199.0 or c5p >= 200.0 - 1e-6:
		g1_bad.append("blocker arc progress %.6f not clipped below the 200 budget" % c5p)
	if bool(c5.actors[0]["bound_active"]):
		g1_bad.append("blocker traversal did not end the bound")
	if int(c5.actors[0]["recovery_end"]) != c5.tick + 12:
		g1_bad.append("blocker recovery_end %d != tick+12" % int(c5.actors[0]["recovery_end"]))
	if c5_ev.size() != 2 or c5_reason != "static":
		g1_bad.append("blocker boundary events %d reason %s != 2 static" % [
			c5_ev.size(), c5_reason])

	# (c) Mirrored actor side: the identical corner fixture on slot 1 must reproduce the same
	#     absolute endpoint and arc progress.
	var c3 := _new_sim(3101, "diagnostic")
	c3.actors[0]["x"] = 4000.0
	c3.actors[0]["y"] = 9000.0
	c3.actors[1]["x"] = 4150.0
	c3.actors[1]["y"] = 3000.0
	c3.actors[1]["bound_path"] = g1_route.duplicate(true)
	c3.actors[1]["bound_total"] = g1_total
	c3.actors[1]["bound_progress"] = 150.0
	c3.actors[1]["bound_action"] = 11
	c3.actors[1]["bound_active"] = true
	c3._movement_cut()
	if absf(float(c3.actors[1]["x"]) - 4250.0) > 1e-6 \
			or absf(float(c3.actors[1]["y"]) - 3100.0) > 1e-6 \
			or absf(float(c3.actors[1]["bound_progress"]) - 350.0) > 1e-6:
		g1_bad.append("side-1 corner (%.6f, %.6f) p=%.6f != (4250, 3100) p=350" % [
			float(c3.actors[1]["x"]), float(c3.actors[1]["y"]),
			float(c3.actors[1]["bound_progress"])])

	# (d) Truncation stops at the LAST NODE that fits: 13 nodes 250 apart. A 2250 budget lands
	#     exactly on node index9 (6250,3000); a 2400 budget falls between nodes and must stop
	#     at that same node instead of interpolating the partial 6400 endpoint.
	var tr_route: Array = []
	for n in 13:
		tr_route.append([4000.0 + 250.0 * n, 3000.0])
	var tr2250 := arena.truncate_route(tr_route, 2250.0)
	var tr2400 := arena.truncate_route(tr_route, 2400.0)
	if tr2250.size() != 10 or tr2400.size() != 10 \
			or not _pt_eq(tr2250[tr2250.size() - 1], [6250.0, 3000.0]) \
			or not _pt_eq(tr2400[tr2400.size() - 1], [6250.0, 3000.0]):
		g1_bad.append("truncate 2250 -> %d nodes, 2400 -> %d nodes, last %s / %s != 10 and 10 ending (6250, 3000)" % [
			tr2250.size(), tr2400.size(),
			str(tr2250[tr2250.size() - 1] if not tr2250.is_empty() else []),
			str(tr2400[tr2400.size() - 1] if not tr2400.is_empty() else [])])

	# (e) Same-node route: goal_id == start_id builds the one-node chain, so the route is a
	#     single legal point and the search records success instead of failing reconstruction.
	var same_from := [4000.0, 3000.0]
	var same_tree := arena.build_route_tree(same_from)
	var same_route := arena.route_from_tree(same_tree, same_from, [4000.0, 3000.0])
	if same_route.size() != 1 or not _pt_eq(same_route[0], [4000.0, 3000.0]):
		g1_bad.append("same-node route %s != [[4000, 3000]]" % str(same_route))
	if not bool(arena.last_search.get("ok", false)) \
			or str(arena.last_search.get("failure", "")) != "":
		g1_bad.append("same-node search failure=%s" % str(arena.last_search.get("failure", "")))

	# (f) Orthogonal connectors: an off-axis gap closes x-first with exactly one corner, and a
	#     body-swept-illegal leg is refused instead of appended.
	var g1_pts: Array = [[4000.0, 3000.0]]
	var g1_conn := arena._append_orthogonal(g1_pts, [4500.0, 3500.0])
	if not g1_conn or g1_pts.size() != 3 \
			or not _pt_eq(g1_pts[1], [4500.0, 3000.0]) \
			or not _pt_eq(g1_pts[2], [4500.0, 3500.0]):
		g1_bad.append("connector ok=%s pts=%s != x-first corner (4500,3000)" % [
			str(g1_conn), str(g1_pts)])
	var g1_blk_pts: Array = [[9000.0, 3000.0]]
	var g1_blk := arena._append_orthogonal(g1_blk_pts, [9000.0, 4000.0])
	if g1_blk:
		g1_bad.append("blocked connector into the inflated blocker was accepted")
	_record("C28-corner-traversal",
		g1_bad.is_empty(),
		"corner p150->350 @(4250,3100), open corner p200->400 @(4250,3150), fractional origin p130->330 @(4250,3080), stationary peer (4250,3000) p250, moving peer (4080,3000) p80 peer5080, blocker stop x≈8499.999 reason static, side-1 mirror, truncate 2250/2400 -> 10 nodes (6250,3000), same-node 1pt, x-first connector, blocked connector refused"
			if g1_bad.is_empty() else "; ".join(g1_bad))

func _case_c63() -> void:
	# FIX02/G1 (QA-F01): legal connector fixtures. (600,600) and (1250,600) are legal centres
	# under the frozen inset, so a route between them must come back orthogonal with no
	# connector_blocked. The same helper against a leg that genuinely crosses the inflated
	# blocker must fail closed instead of silently accepting it.
	var g1c_bad: Array = []
	if not arena.center_legal(600.0, 600.0) or not arena.center_legal(1250.0, 600.0):
		g1c_bad.append("legal centre (600,600)/(1250,600) rejected by center_legal")
	var g1c_path: Array = arena.path_between([1250.0, 600.0], [1500.0, 750.0])
	var g1c_fail := str(arena.last_search.get("failure", ""))
	var g1c_ok := bool(arena.last_search.get("ok", false))
	if g1c_path.is_empty() or g1c_fail == "connector_blocked" or not g1c_ok:
		g1c_bad.append("legal route (1250,600)->(1500,750) points=%d ok=%s failure=%s" % [
			g1c_path.size(), str(g1c_ok), g1c_fail])
	for i in g1c_path.size() - 1:
		var pa: Array = g1c_path[i]
		var pb: Array = g1c_path[i + 1]
		if not arena.center_legal(float(pa[0]), float(pa[1])):
			g1c_bad.append("route point %s is not a legal centre" % str(pa))
		if absf(float(pa[0]) - float(pb[0])) > 1e-6 and absf(float(pa[1]) - float(pb[1])) > 1e-6:
			g1c_bad.append("route leg %s->%s is not orthogonal" % [str(pa), str(pb)])
	var g1c_con: Array = [[600.0, 600.0]]
	if not arena._append_orthogonal(g1c_con, [1250.0, 600.0]) or g1c_con.size() != 2:
		g1c_bad.append("clear connector (600,600)->(1250,600) ok=%s pts=%s != true/2 points" % [
			str(g1c_con.size() == 2), str(g1c_con)])
	var g1c_blk: Array = [[750.0, 6000.0]]
	if arena._append_orthogonal(g1c_blk, [12000.0, 6000.0]):
		g1c_bad.append("blocked connector (750,6000)->(12000,6000) was accepted")
	var g1c_tree := {"ok": true, "start_id": arena.node_id(48, 24), "parent": {},
		"expansions": 1, "wall_us": 0, "failure": ""}
	var g1c_route: Array = arena.route_from_tree(g1c_tree, [750.0, 6000.0], [12000.0, 6000.0])
	if not g1c_route.is_empty() or str(arena.last_search.get("failure", "")) != "connector_blocked":
		g1c_bad.append("blocked control route=%s failure=%s != []/connector_blocked" % [
			str(g1c_route), str(arena.last_search.get("failure", ""))])
	_record("C63-legal-connectors",
		g1c_bad.is_empty(),
		"(600,600)/(1250,600) legal, route (1250,600)->(1500,750) orthogonal and clear, clear connector (600,600)->(1250,600) appends, blocker-crossing connector refused as connector_blocked"
			if g1c_bad.is_empty() else "; ".join(g1c_bad))

func _case_c64() -> void:
	# FIX02/G1 (QA-F02): contact OCCURRENCE is separate from its fraction. The earlier of the
	# two candidate terminal times is the applied stop time, and a contact that lands exactly on
	# the boundary end (fraction 1.0) is a real contact rather than "no contact at all".
	var g1d_bad: Array = []
	var g1d := _new_sim(3101, "diagnostic")
	g1d.actors[0]["x"] = 8400.0
	g1d.actors[0]["y"] = 6000.0
	g1d.actors[0]["bound_path"] = [[8400.0, 6000.0], [8600.0, 6000.0]]
	g1d.actors[0]["bound_total"] = 200.0
	g1d.actors[0]["bound_progress"] = 0.0
	g1d.actors[0]["bound_action"] = 31
	g1d.actors[0]["bound_active"] = true
	g1d.actors[1]["x"] = 8450.0
	g1d.actors[1]["y"] = 7040.0
	g1d.actors[1]["goal"] = {"kind": "move", "point": [8450.0, 6990.0],
		"route": [[8450.0, 7040.0], [8450.0, 6990.0]], "stop_mwu": 0.0,
		"purpose": "approach", "patrol_index": -1, "i": 0}
	g1d.actors[1]["next_plan_tick"] = 1000000
	g1d._movement_cut()
	var g1d_ev: Array = _events_of_type(g1d, 26)
	# QA-PLAY01-R03-F05: _obstruct_bound emits `obstructed` and the _finish_bound it calls then
	# emits `end`, so a terminated Bound leaves TWO event-26 records. The old prose/label said
	# one and the code only read the first row's cause; the event contract itself is unchanged.
	if not arena.center_legal(8400.0, 6000.0) or not arena.center_legal(8450.0, 7040.0):
		g1d_bad.append("static-stop initial centers (8400,6000)/(8450,7040) not both legal")
	if g1d_ev.size() != 2:
		g1d_bad.append("static-stop event26 rows=%d != 2 (obstructed then end)" % g1d_ev.size())
	else:
		var g1d_p0: Array = (g1d_ev[0][3] as Array)
		var g1d_p1: Array = (g1d_ev[1][3] as Array)
		if str(g1d_p0[2]) != "obstructed" or str(g1d_p1[2]) != "end" \
				or str(g1d_p0[4]) != "static" or str(g1d_p1[4]) != "static":
			g1d_bad.append("static-stop event26 %s/%s causes %s/%s != obstructed/end static/static" % [
				str(g1d_p0[2]), str(g1d_p1[2]), str(g1d_p0[4]), str(g1d_p1[4])])
	if absf(float(g1d.actors[0]["x"]) - 8499.999) > 1e-3 \
			or absf(float(g1d.actors[0]["y"]) - 6000.0) > 1e-6:
		g1d_bad.append("static applied (%.6f, %.6f) != (8499.999, 6000)" % [
			float(g1d.actors[0]["x"]), float(g1d.actors[0]["y"])])
	if absf(float(g1d.actors[0]["bound_progress"]) - 99.999) > 1e-3:
		g1d_bad.append("static arc progress %.6f != 99.999" % float(g1d.actors[0]["bound_progress"]))
	if bool(g1d.actors[0]["bound_active"]):
		g1d_bad.append("static stop left the Bound active")
	if int(g1d.actors[0]["recovery_end"]) != g1d.tick + 12:
		g1d_bad.append("static recovery_end %d != tick+12 (%d)" % [
			int(g1d.actors[0]["recovery_end"]), g1d.tick + 12])
	var g1d_d := sqrt(pow(float(g1d.actors[0]["x"]) - float(g1d.actors[1]["x"]), 2.0)
		+ pow(float(g1d.actors[0]["y"]) - float(g1d.actors[1]["y"]), 2.0))
	if absf(g1d_d - 1000.0) > 1e-3 or absf(float(g1d.actors[1]["y"]) - 6998.749268) > 1e-3:
		g1d_bad.append("shared-time contact d=%.6f peer=(%.6f, %.6f) != 1000 /(8450, 6998.749268)" % [
			g1d_d, float(g1d.actors[1]["x"]), float(g1d.actors[1]["y"])])
	# ARCH-PLAY01-R03-F03 / QA-PLAY01-R03-F05: the endpoint pair moves to open field (frozen
	# G-16 lane) with LEGAL initial centres, a declared total equal to the real authored route
	# length inside the authored 200..2400 Bound budget, and a route still unfinished after this
	# boundary's 200 mWU travel budget. The old pair sat inside the inflated blocker and
	# declared total 3000 for a 200-long path.
	var g1e := _new_sim(3101, "diagnostic")
	var g1e_route := [[4000.0, 3000.0], [6400.0, 3000.0]]
	g1e.actors[0]["x"] = 4000.0
	g1e.actors[0]["y"] = 3000.0
	g1e.actors[0]["bound_path"] = g1e_route
	g1e.actors[0]["bound_total"] = arena.route_length(g1e_route)
	g1e.actors[0]["bound_progress"] = 0.0
	g1e.actors[0]["bound_action"] = 33
	g1e.actors[0]["bound_active"] = true
	g1e.actors[1]["x"] = 5200.0
	g1e.actors[1]["y"] = 3000.0
	if not arena.center_legal(4000.0, 3000.0) or not arena.center_legal(5200.0, 3000.0):
		g1d_bad.append("endpoint-contact initial centers (4000,3000)/(5200,3000) not both legal")
	if absf(float(g1e.actors[0]["bound_total"]) - 2400.0) > 1e-6 \
			or float(g1e.actors[0]["bound_total"]) < 200.0 \
			or float(g1e.actors[0]["bound_total"]) > 2400.0 + 1e-6:
		g1d_bad.append("endpoint declared total %.6f != authored route length 2400 in [200,2400]" %
			float(g1e.actors[0]["bound_total"]))
	g1e._movement_cut()
	var g1e_ev: Array = _events_of_type(g1e, 26)
	if g1e_ev.size() != 2:
		g1d_bad.append("endpoint contact event26 rows=%d != 2 (obstructed then end)" %
			g1e_ev.size())
	else:
		var g1e_p0: Array = (g1e_ev[0][3] as Array)
		var g1e_p1: Array = (g1e_ev[1][3] as Array)
		if str(g1e_p0[2]) != "obstructed" or str(g1e_p1[2]) != "end" \
				or str(g1e_p0[4]) != "body_contact" or str(g1e_p1[4]) != "body_contact":
			g1d_bad.append("endpoint event26 %s/%s causes %s/%s != obstructed/end body_contact/body_contact" % [
				str(g1e_p0[2]), str(g1e_p1[2]), str(g1e_p0[4]), str(g1e_p1[4])])
	if bool(g1e.actors[0]["bound_active"]):
		g1d_bad.append("fraction-1.0 contact did not end the unfinished Bound")
	if absf(float(g1e.actors[0]["x"]) - 4200.0) > 1e-6 \
			or absf(float(g1e.actors[0]["y"]) - 3000.0) > 1e-6 \
			or absf(float(g1e.actors[0]["bound_progress"]) - 200.0) > 1e-6:
		g1d_bad.append("endpoint applied (%.6f, %.6f) p=%.6f != (4200, 3000) p=200" % [
			float(g1e.actors[0]["x"]), float(g1e.actors[0]["y"]),
			float(g1e.actors[0]["bound_progress"])])
	if int(g1e.actors[0]["recovery_end"]) != g1e.tick + 12:
		g1d_bad.append("endpoint recovery_end %d != tick+12 (%d)" % [
			int(g1e.actors[0]["recovery_end"]), g1e.tick + 12])
	# Control: the peer 100 mWU further out never makes contact, so fraction 1.0 stays "no
	# contact" and the unfinished Bound keeps running instead of being terminated.
	var g1f := _new_sim(3101, "diagnostic")
	var g1f_route := [[4000.0, 3000.0], [6400.0, 3000.0]]
	g1f.actors[0]["x"] = 4000.0
	g1f.actors[0]["y"] = 3000.0
	g1f.actors[0]["bound_path"] = g1f_route
	g1f.actors[0]["bound_total"] = arena.route_length(g1f_route)
	g1f.actors[0]["bound_progress"] = 0.0
	g1f.actors[0]["bound_action"] = 35
	g1f.actors[0]["bound_active"] = true
	g1f.actors[1]["x"] = 5200.0
	g1f.actors[1]["y"] = 3100.0
	if not arena.center_legal(4000.0, 3000.0) or not arena.center_legal(5200.0, 3100.0):
		g1d_bad.append("no-contact initial centers (4000,3000)/(5200,3100) not both legal")
	g1f._movement_cut()
	var g1f_ev: Array = _events_of_type(g1f, 26)
	var g1f_sep := sqrt(pow(float(g1f.actors[0]["x"]) - float(g1f.actors[1]["x"]), 2.0)
		+ pow(float(g1f.actors[0]["y"]) - float(g1f.actors[1]["y"]), 2.0))
	if absf(float(g1f.actors[0]["x"]) - 4200.0) > 1e-6 \
			or absf(float(g1f.actors[0]["bound_progress"]) - 200.0) > 1e-6:
		g1d_bad.append("no-contact applied (%.6f, %.6f) p=%.6f != (4200, 3000) p=200" % [
			float(g1f.actors[0]["x"]), float(g1f.actors[0]["y"]),
			float(g1f.actors[0]["bound_progress"])])
	if absf(g1f_sep - 1004.987562) > 1e-4:
		g1d_bad.append("no-contact separation %.6f != 1004.987562 (sqrt(1000^2+100^2))" % g1f_sep)
	if not g1f_ev.is_empty() or not bool(g1f.actors[0]["bound_active"]) \
			or absf(float(g1f.actors[0]["bound_progress"]) - 200.0) > 1e-6:
		g1d_bad.append("no-contact control events=%d active=%s p=%.6f != 0/true/200" % [
			g1f_ev.size(), str(bool(g1f.actors[0]["bound_active"])),
			float(g1f.actors[0]["bound_progress"])])
	_record("C64-static-stop-contact",
		g1d_bad.is_empty(),
		"static stop x≈8499.999 reason static before shared contact t≈0.825014643 peer y≈6998.749268 d=1000; open-field endpoint contact at fraction 1.0 ends the unfinished authored 2400 route at (4200,3000) p=200 as obstructed then end body_contact, recovery+12; no-contact peer separation 1004.987562 keeps it active; every initial centre legal; each termination leaves two event26 rows"
			if g1d_bad.is_empty() else "; ".join(g1d_bad))

func _case_c53() -> void:
	# C53 FIX01/4/QA-F04/F05/F06 — the REQUESTED lifecycle, isolated by actor/request/action
	# IDs. Production autonomy starts an unrelated Quick on tick1 while no accepted intent
	# exists, so its COST must neither satisfy nor terminate the staged chain; the chain is
	# followed to its own terminal COMMIT instead of stopping at cost.
	var g4_bad: Array = []
	var g4 := _new_sim(3101, "diagnostic")
	g4.actors[0]["x"] = 4000.0
	g4.actors[0]["y"] = 3000.0
	g4.actors[1]["x"] = 5000.0
	g4.actors[1]["y"] = 3000.0
	g4.actors[1]["hp"] = 6000
	# Controlled peer: in diagnostic mode a controlled actor never plans, so no stray effect can
	# interrupt the charging Brace this chain is meant to observe.
	g4.actors[1]["control_mode"] = 1
	g4.actors[0]["enemy_visible"] = true
	g4.actors[0]["int_stat"] = 100
	var g4_stam_max := int(g4.actors[0]["stam_max"])
	g4.actors[0]["stam"] = g4_stam_max
	# Bound stays unavailable, so the Defense pool is Brace alone: a single candidate draws no
	# selector RNG and no fabricated draw is needed to make the selection deterministic.
	g4.actors[0]["cooldown_end"]["short_bound"] = 999999
	g4.forced_uniforms["response.0"] = [0.99]
	_stage(g4, 0, 2, 1, 1)
	var g4_req := -1
	var g4_aid := -1
	var g4_terminated := false
	for g4i in 150:
		_pstep(g4)
		if g4_req < 0:
			var g4_seen1: Array = _events_of_type(g4, 1)
			if not g4_seen1.is_empty():
				g4_req = int((g4_seen1[0][3] as Array)[0])
		if g4_req >= 0 and g4_aid < 0:
			for g4row in _rows_with_field(_events_with_tick(g4, 6), 3, g4_req):
				g4_aid = int((g4row[1] as Array)[0])
				break
		if g4_aid >= 0 \
				and not _rows_with_field(_events_with_tick(g4, 9), 0, g4_aid).is_empty():
			g4_terminated = true
		if g4_terminated:
			break
	var g4_e1: Array = _events_with_tick(g4, 1)
	var g4_r3: Array = _rows_with_field(_events_with_tick(g4, 3), 0, g4_req)
	var g4_r5: Array = _rows_with_field(_events_with_tick(g4, 5), 1, g4_req)
	var g4_r6: Array = _rows_with_field(_events_with_tick(g4, 6), 3, g4_req)
	var g4_all7: Array = _events_with_tick(g4, 7)
	var g4_r7: Array = _rows_with_field(g4_all7, 0, g4_aid)
	var g4_r9: Array = _rows_with_field(_events_with_tick(g4, 9), 0, g4_aid)
	var g4_r10: Array = _rows_with_field(_events_with_tick(g4, 10), 0, g4_aid)
	var g4_foreign7: Array = []
	for g4row in g4_all7:
		if int((g4row[1] as Array)[0]) != g4_aid:
			g4_foreign7.append(g4row)
	var g4_cost := int(content.skill("brace")["stam_cost_cp"])
	var g4_cool := int(content.cooldown_ticks("brace"))
	var g4_rec := int(content.recovery_ticks("brace"))
	var g4_chg := int(content.charge_ticks("brace"))
	var g4_start := -1
	var g4_commit := -1
	if g4_e1.size() != 1:
		g4_bad.append("REQUEST rows %d != 1" % g4_e1.size())
	elif int(g4_e1[0][0]) != 2:
		g4_bad.append("REQUEST tick %d != 2 (staged effective tick)" % int(g4_e1[0][0]))
	if g4_aid < 0:
		g4_bad.append("no ACTION_START carries request %d" % g4_req)
	if g4_r3.is_empty() or g4_r5.is_empty() or g4_r6.is_empty() or g4_r7.is_empty() \
			or g4_r9.is_empty():
		g4_bad.append("chain counts response=%d plan=%d start=%d cost=%d commit=%d for request %d" % [
			g4_r3.size(), g4_r5.size(), g4_r6.size(), g4_r7.size(), g4_r9.size(), g4_req])
	if g4_foreign7.is_empty():
		g4_bad.append("no unrelated COST exists to prove the chain is ID-isolated")
	# QA-PLAY01-R03-F02: the unrelated payment is the single autonomous Quick the fixture
	# deliberately allows at boundary 1. It must exist, be exactly one 600 debit, and land
	# before the requested chain — it neither satisfies nor terminates that chain.
	elif g4_foreign7.size() != 1 \
			or int((g4_foreign7[0][1] as Array)[2]) != int(content.skill("quick_claw")["stam_cost_cp"]) \
			or int(g4_foreign7[0][0]) != 1:
		g4_bad.append("unrelated COST rows/tick/cost %d/%d/%d != 1/1/600 (autonomous Quick)" % [
			g4_foreign7.size(), int(g4_foreign7[0][0]), int((g4_foreign7[0][1] as Array)[2])])
	if not g4_r10.is_empty():
		g4_bad.append("requested action %d was cancelled: %s" % [
			g4_aid, str((g4_r10[0][1] as Array)[3])])
	if not g4_r6.is_empty() and g4_r6.size() != 1:
		g4_bad.append("ACTION_START carries request %d %d times != 1" % [g4_req, g4_r6.size()])
	if g4_aid >= 0 and not g4_r3.is_empty() and not g4_r5.is_empty() and not g4_r6.is_empty() \
			and not g4_r7.is_empty() and not g4_r9.is_empty():
		var g4_p3: Array = g4_r3[0][1]
		var g4_p6: Array = g4_r6[0][1]
		var g4_p7: Array = g4_r7[0][1]
		var g4_p9: Array = g4_r9[0][1]
		g4_start = int(g4_r6[0][0])
		var g4_cost_tick := int(g4_r7[0][0])
		g4_commit = int(g4_r9[0][0])
		# ARCH-PLAY01-R03-F02 / QA-PLAY01-R03-F02: correlating PLAN by request alone also collects
		# the legitimate earlier WAITING/fallback PLANs this fixture deliberately produces — the
		# autonomous Quick started at 1 and its recovery holds every skill unready until 22, so
		# the Defense intent first plans a disengage/rest fallback. The SELECTED technique PLAN is
		# the one ON the START boundary that actually chose Brace; earlier rows are retained as
		# legitimate evidence and are never required to be Brace or to share START's tick.
		var g4_at_start: Array = []
		for g4row in g4_r5:
			if int(g4row[0]) == g4_start:
				g4_at_start.append(g4row)
		var g4_sel: Array = []
		for g4row in g4_at_start:
			if str((g4row[1] as Array)[6]) == "brace":
				g4_sel.append(g4row)
		var g4_earlier := g4_r5.size() - g4_at_start.size()
		var g4_plan_tick := -1
		var g4_p5: Array = []
		if g4_sel.size() != 1:
			g4_bad.append("selected Brace PLAN at START %d = %d != 1 (earlier fallback PLAN rows=%d)" % [
				g4_start, g4_sel.size(), g4_earlier])
		else:
			g4_p5 = g4_sel[0][1]
			g4_plan_tick = int(g4_sel[0][0])
		if g4_earlier < 1:
			g4_bad.append("no earlier waiting/fallback PLAN row preserved for request %d" % g4_req)
		if int(g4_p3[0]) != g4_req:
			g4_bad.append("RESPONSE rid %d != REQUEST %d" % [int(g4_p3[0]), g4_req])
		if int(g4_p3[4]) != 6 or int(g4_p3[5]) != 2 or int(g4_p3[6]) != 2:
			g4_bad.append("RESPONSE class/original/interpreted %d/%d/%d != 6/2/2" % [
				int(g4_p3[4]), int(g4_p3[5]), int(g4_p3[6])])
		if not g4_p5.is_empty():
			if int(g4_p5[1]) != g4_req or int(g4_p5[2]) != int(g4_p3[2]) \
					or int(g4_p5[3]) != int(g4_p3[3]):
				g4_bad.append("PLAN request/episode/intent %d/%d/%d != %d/%d/%d" % [
					int(g4_p5[1]), int(g4_p5[2]), int(g4_p5[3]), g4_req, int(g4_p3[2]),
					int(g4_p3[3])])
			if str(g4_p5[6]) != "brace":
				g4_bad.append("selected PLAN skill %s != brace" % str(g4_p5[6]))
		if int(g4_p6[3]) != g4_req or int(g4_p6[3]) != int(g4_p3[0]):
			g4_bad.append("START request %d != REQUEST %d / RESPONSE rid %d" % [
				int(g4_p6[3]), g4_req, int(g4_p3[0])])
		if str(g4_p6[4]) != "brace" or int(g4_p6[0]) != g4_aid:
			g4_bad.append("START skill/aid %s/%d != brace/%d" % [
				str(g4_p6[4]), int(g4_p6[0]), g4_aid])
		if g4_plan_tick < 0 or g4_plan_tick != g4_start or g4_cost_tick != g4_start:
			g4_bad.append("selected PLAN/COST ticks %d/%d != START %d" % [
				g4_plan_tick, g4_cost_tick, g4_start])
		if int(g4_p6[6]) != g4_start + g4_chg \
				or int(g4_p6[7]) != g4_start + g4_chg + g4_rec:
			g4_bad.append("START due/recovery %d/%d != %d/%d" % [int(g4_p6[6]), int(g4_p6[7]),
				g4_start + g4_chg, g4_start + g4_chg + g4_rec])
		# Independent frozen ledger, derived from the authored cuts and rates — never read back
		# from this case's own result: the autonomous Quick pays 600 on boundary 1 and that start
		# boundary skips the resource row; boundaries 2..21 are recovery rows restoring 5 each
		# (20 x 5 = 100); _refresh_gates keeps every skill unready while recovery_end = 22, so the
		# requested Brace starts at 22 from 6000 - 600 + 100 = 5500 and pays 800 to 4700.
		var g4_regen := 20 * int(content.tuning["regen"]["recovery_cp_per_tick"])
		var g4_foreign_cost := int(content.skill("quick_claw")["stam_cost_cp"])
		var g4_pre := g4_stam_max - g4_foreign_cost + g4_regen
		var g4_post := g4_pre - g4_cost
		if g4_regen != 100 or g4_foreign_cost != 600 or g4_pre != 5500 or g4_post != 4700:
			g4_bad.append("independent ledger regen/foreign/pre/post %d/%d/%d/%d != 100/600/5500/4700" % [
				g4_regen, g4_foreign_cost, g4_pre, g4_post])
		if g4_start != 22 or g4_commit != 49:
			g4_bad.append("START/COMMIT %d/%d != 22/49 (independent timeline)" % [
				g4_start, g4_commit])
		if int(g4_p7[2]) != g4_cost or int(g4_p7[3]) != g4_post \
				or int(g4_p7[4]) != g4_start + g4_cool:
			g4_bad.append("COST cost/stam_after/cooldown %d/%d/%d != %d/%d/%d" % [
				int(g4_p7[2]), int(g4_p7[3]), int(g4_p7[4]),
				g4_cost, g4_post, g4_start + g4_cool])
		if g4_r7.size() != 1:
			g4_bad.append("cost%d charged %d times for action %d != 1" % [
				g4_cost, g4_r7.size(), g4_aid])
		if g4_commit != g4_start + g4_chg:
			g4_bad.append("COMMIT tick %d != START+charge %d" % [g4_commit, g4_start + g4_chg])
		if not (g4_p9[2] is Array) or not (g4_p9[2] as Array).is_empty():
			g4_bad.append("Brace COMMIT carried effects %s != []" % str(g4_p9[2]))
		if not g4_foreign7.is_empty() and int(g4_foreign7[0][0]) >= g4_start:
			g4_bad.append("the unrelated COST landed at %d, not before START %d" % [
				int(g4_foreign7[0][0]), g4_start])
		if g4_cost != 800 or g4_cool != 180 or g4_rec != 15 or g4_chg != 27:
			g4_bad.append("frozen Brace cost/cd/rec/charge %d/%d/%d/%d != 800/180/15/27" % [
				g4_cost, g4_cool, g4_rec, g4_chg])
		# The hold starts on the FOLLOWING boundary after commit and releases the RuntimeAction.
		var g4_hold := int(content.skill("brace")["active_boundaries"])
		if g4.actors[0]["action"] != null or int(g4.actors[0]["brace_action"]) != g4_aid \
				or int(g4.actors[0]["brace_start"]) != g4_commit \
				or int(g4.actors[0]["brace_end"]) != g4_commit + 1 + g4_hold:
			g4_bad.append("hold action/brace/start/end %s/%d/%d/%d != null/%d/%d/%d" % [
				str(g4.actors[0]["action"] != null), int(g4.actors[0]["brace_action"]),
				int(g4.actors[0]["brace_start"]), int(g4.actors[0]["brace_end"]),
				g4_aid, g4_commit, g4_commit + 1 + g4_hold])
		if not g4_terminated:
			g4_bad.append("chain never reached its own COMMIT within the 150-tick budget")

	# Committed Bound travel is protected: a replacement intent that is not a charging cancel
	# must leave the live travel running and its arc progress must keep advancing.
	var g4m := _new_sim(3101, "diagnostic")
	var g4ma: Dictionary = g4m.actors[0]
	# Legal-premise fix: the declared total must be the real authored route length and stay
	# inside the authored 200..2400 Bound budget. The old fixture declared 3000 for a path
	# production would have truncated to 2400.
	var g4m_route := [[4000.0, 3000.0], [6400.0, 3000.0]]
	g4ma["bound_path"] = g4m_route
	g4ma["bound_total"] = arena.route_length(g4m_route)
	g4ma["bound_progress"] = 0.0
	g4ma["bound_action"] = 21
	g4ma["bound_active"] = true
	g4ma["action"] = {"action": 21, "actor": 0, "life": 1, "request": 1, "intent": 4,
		"skill": "short_bound", "target": [6400, 3000], "target_kind": 3, "start_tick": 0,
		"due_tick": 18, "recovery_ticks": 12, "paid_cost": 1000, "cooldown_end": 144,
		"stability": 1, "interrupt_power": 1, "state": "committed", "cancel_cause": "",
		"plan": {}}
	g4ma["cycle_intent"] = 4
	var g4rep := {"episode": 3, "target_kind": 0, "target_or_area": null, "class": 6,
		"original_family": 1, "latest_request": 9, "observation_category": "attack",
		"draw_resolved": false}
	g4m._accept_intent(g4ma, g4rep, 1)
	if float(g4ma["bound_total"]) < 200.0 or float(g4ma["bound_total"]) > 2400.0 + 1e-6 \
			or absf(float(g4ma["bound_total"]) - arena.route_length(g4m_route)) > 1e-6:
		g4_bad.append("committed Bound route/total %.6f != authored route length within [200,2400]" %
			float(g4ma["bound_total"]))
	g4m._movement_cut()
	if not bool(g4ma["bound_active"]) or absf(float(g4ma["bound_progress"]) - 200.0) > 1e-6:
		g4_bad.append("replacement while committed active=%s progress %.6f != true/200" % [
			str(bool(g4ma["bound_active"])), float(g4ma["bound_progress"])])
	if not _events_of_type(g4m, 10).is_empty():
		g4_bad.append("committed Bound travel was cancelled by the replacement intent")
	var g4_detail := "unrelated COST count=%d, requested chain start=%d" % [
		g4_foreign7.size(), g4_start]
	if g4_aid >= 0 and g4_start >= 0 and g4_commit >= 0:
		g4_detail = "request%d isolated chain: REQUEST@2, RESPONSE class6 Defense, selected Brace PLAN/START/COST@%d, independent ledger 6000-600+100=5500 minus 800 = 4700, one 800 debit, cd start+180 (+%d), rec+15, COMMIT@%d on the following-boundary hold; %d autonomous Quick COST 600 @1 lands before START; committed Bound survives replacement progress200 no cancel" % [
			g4_req, g4_start, g4_cool, g4_commit, g4_foreign7.size()]
	_record("C53-lifecycle-correlation", g4_bad.is_empty(),
		g4_detail if g4_bad.is_empty() else "; ".join(g4_bad))

func _case_c54() -> void:
	# C54 FIX01/4 — G14 payment boundaries (Quick 599/600/601), unavailable fallback without
	# payment, both sides of the charging-cancel threshold, exhaustion, and paid retention.
	var g5_bad: Array = []
	for g5s in [599, 600, 601]:
		var g5 := _new_sim(3101, "diagnostic")
		var g5a: Dictionary = g5.actors[0]
		g5a["x"] = 4000.0
		g5a["y"] = 3000.0
		g5.actors[1]["x"] = 5000.0
		g5.actors[1]["y"] = 3000.0
		g5a["enemy_visible"] = true
		g5a["stam"] = g5s
		g5a["accepted_intent"] = {"intent": 1, "episode": 1, "family": 1,
			"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
			"target_or_area": null, "goal": null}
		g5._refresh_gates(g5a)
		var g5_fat0 := int(g5a["fatigue_centi"])
		var g5_cd0 := int(g5a["cooldown_end"]["quick_claw"])
		var g5_plan := {"skill": "quick_claw", "goal": null, "candidates": [], "fits": {},
			"fit_reason": "escape"}
		g5._try_start(g5a, "quick_claw", g5_plan, g5.actors[1])
		var g5_e6: Array = _events_of_type(g5, 6)
		var g5_e7: Array = _events_of_type(g5, 7)
		if g5s == 599:
			if g5a["action"] != null or not g5_e6.is_empty() or not g5_e7.is_empty():
				g5_bad.append("stam599 action=%s start=%d payment=%d != null/0/0 (no payment)" % [
					str(g5a["action"] != null), g5_e6.size(), g5_e7.size()])
			if int(g5a["stam"]) != 599:
				g5_bad.append("stam599 unchanged check: stam became %d" % int(g5a["stam"]))
			# QA-F04: keep the no-start cooldown assertion explicit — 599 must mutate nothing.
			if int(g5a["cooldown_end"]["quick_claw"]) != g5_cd0 \
					or int(g5a["fatigue_centi"]) != g5_fat0:
				g5_bad.append("stam599 mutated cooldown/fatigue %d/%d != %d/%d" % [
					int(g5a["cooldown_end"]["quick_claw"]), int(g5a["fatigue_centi"]),
					g5_cd0, g5_fat0])
		else:
			if g5a["action"] == null or g5_e6.is_empty() or g5_e7.is_empty():
				g5_bad.append("stam%d action=%s start=%d payment=%d != started" % [
					g5s, str(g5a["action"] != null), g5_e6.size(), g5_e7.size()])
			else:
				var g5p6: Array = g5_e6[0][3]
				var g5p7: Array = g5_e7[0][3]
				if int(g5p6[0]) != int(g5p7[0]) or int(g5p7[2]) != 600:
					g5_bad.append("stam%d START/COST aid %d/%d cost %d != same aid, 600" % [
						g5s, int(g5p6[0]), int(g5p7[0]), int(g5p7[2])])
				if int(g5p7[3]) != g5s - 600 or int(g5p7[4]) != g5.tick + 72:
					g5_bad.append("stam%d stam_after/cooldown %d/%d != %d/%d" % [
						g5s, int(g5p7[3]), int(g5p7[4]), g5s - 600, g5.tick + 72])

	# Unavailable skill (still on cooldown) must fall back with no payment at all.
	var g5r := _new_sim(3101, "diagnostic")
	var g5ra: Dictionary = g5r.actors[0]
	g5ra["x"] = 4000.0
	g5ra["y"] = 3000.0
	g5r.actors[1]["x"] = 5000.0
	g5r.actors[1]["y"] = 3000.0
	g5ra["enemy_visible"] = true
	g5ra["stam"] = 4000
	g5ra["cooldown_end"]["quick_claw"] = g5r.tick + 100
	g5ra["accepted_intent"] = {"intent": 1, "episode": 1, "family": 1,
		"accepted_tick": 0, "expiry_tick": 480, "state": "active", "target_kind": 0,
		"target_or_area": null, "goal": null}
	g5r._refresh_gates(g5ra)
	var g5r_stam := int(g5ra["stam"])
	var g5r_plan := {"skill": "quick_claw", "goal": null, "candidates": [], "fits": {},
		"fit_reason": "escape"}
	g5r._try_start(g5ra, "quick_claw", g5r_plan, g5r.actors[1])
	if g5ra["action"] != null or not _events_of_type(g5r, 7).is_empty() \
			or int(g5ra["stam"]) != g5r_stam:
		g5_bad.append("cooldown-blocked start action=%s payments=%d stam %d->%d != no payment" % [
			str(g5ra["action"] != null), _events_of_type(g5r, 7).size(),
			g5r_stam, int(g5ra["stam"])])

	# Charging-cancel threshold with INT100: threshold 0.25+0.50 = 0.75 of a 27-tick Brace
	# charge, so elapsed20 (<) cancels with payment retained and elapsed21 (>=) declines.
	var g5t := _new_sim(3101, "diagnostic")
	var g5ta: Dictionary = g5t.actors[0]
	g5ta["int_stat"] = 100
	g5ta["stam"] = 4000
	g5ta["cooldown_end"]["brace"] = 777
	g5ta["cycle_intent"] = 4
	g5t._refresh_gates(g5ta)
	var g5charge := int(content.charge_ticks("brace"))
	var g5recovery := int(content.recovery_ticks("brace"))
	var g5cd := int(content.cooldown_ticks("brace"))
	if g5charge != 27 or g5recovery != 15 or g5cd != 180:
		g5_bad.append("frozen Brace charge/recovery/cooldown %d/%d/%d != 27/15/180" % [
			g5charge, g5recovery, g5cd])
	var g5thresh := 0.25 + 0.50 * (float(g5ta["int_stat"]) / 100.0)
	var g5el_lo := int(floor(g5thresh * float(g5charge)))
	var g5el_hi := int(ceil(g5thresh * float(g5charge)))
	g5ta["action"] = {"action": 31, "actor": 0, "life": 1, "request": 1, "intent": 4,
		"skill": "brace", "target": null, "target_kind": 1, "start_tick": g5t.tick - g5el_hi,
		"due_tick": g5t.tick - g5el_hi + g5charge, "recovery_ticks": g5recovery,
		"paid_cost": 800, "cooldown_end": 777, "stability": 1, "interrupt_power": 1,
		"state": "preparing", "cancel_cause": "", "plan": {}}
	var g5declined := g5t._conflict_guard(g5ta, 1)
	if g5declined != "finishing_current_action":
		g5_bad.append("elapsed%d/%d guard=%s != finishing_current_action" % [
			g5el_hi, g5charge, g5declined])
	g5ta["action"]["start_tick"] = g5t.tick - g5el_lo
	g5ta["action"]["due_tick"] = g5t.tick - g5el_lo + g5charge
	var g5allowed := g5t._conflict_guard(g5ta, 1)
	var g5stam_before := int(g5ta["stam"])
	var g5ep := {"episode": 5, "target_kind": 0, "target_or_area": null, "class": 6,
		"original_family": 3, "latest_request": 11, "observation_category": "run",
		"draw_resolved": false}
	if g5allowed != "":
		g5_bad.append("elapsed%d/%d guard=%s != allowed" % [g5el_lo, g5charge, g5allowed])
	else:
		g5t._accept_intent(g5ta, g5ep, 1)
		var g5_c10: Array = _events_of_type(g5t, 10)
		if g5_c10.is_empty() or str((g5_c10[0][3] as Array)[3]) != "intent_change":
			g5_bad.append("qualified interruption events=%d reason=%s != 1 intent_change" % [
				g5_c10.size(), str((g5_c10[0][3] as Array)[3] if not g5_c10.is_empty() else "")])
		if g5ta["action"] != null:
			g5_bad.append("qualified interruption left the charging action alive")
		if int(g5ta["stam"]) != g5stam_before or int(g5ta["cooldown_end"]["brace"]) != 777:
			g5_bad.append("paid cost/cooldown not retained (stam %d->%d, cd %d)" % [
				g5stam_before, int(g5ta["stam"]), int(g5ta["cooldown_end"]["brace"])])
		if int(g5ta["recovery_end"]) != g5t.tick + g5recovery \
				or int(g5ta["recovery_owner"]) != 4:
			g5_bad.append("recovery/owner %d/%d != %d/4" % [
				int(g5ta["recovery_end"]), int(g5ta["recovery_owner"]),
				g5t.tick + g5recovery])
		if g5recovery != 15 or absf(g5thresh - 0.75) > 1e-9:
			g5_bad.append("frozen Brace recovery %d != 15 or threshold %.6f != 0.75" % [
				g5recovery, g5thresh])

	# Exact threshold equality on the other authored charge: INT50 gives 0.25+0.50*0.50 = 0.50
	# of Bound's 18-tick charge, so elapsed8 (<) permits the cancel and elapsed9 (==) declines.
	# Compatibility follows the OWNING INTENT's family, never the technique's authored family3.
	var g5b := _new_sim(3101, "diagnostic")
	var g5ba: Dictionary = g5b.actors[0]
	g5ba["int_stat"] = 50
	g5ba["stam"] = 4000
	g5ba["cycle_intent"] = 4
	g5b._refresh_gates(g5ba)
	var g5bcharge := int(content.charge_ticks("short_bound"))
	var g5brec := int(content.recovery_ticks("short_bound"))
	var g5bthresh := 0.25 + 0.50 * (float(g5ba["int_stat"]) / 100.0)
	if g5bcharge != 18 or absf(g5bthresh - 0.50) > 1e-9:
		g5_bad.append("frozen Bound charge/threshold %d/%.6f != 18/0.50" % [
			g5bcharge, g5bthresh])
	g5ba["action"] = {"action": 51, "actor": 0, "life": 1, "request": 1, "intent": 4,
		"owning_family": 2, "episode": 4, "skill": "short_bound", "target": [7000, 3000],
		"target_kind": 3, "start_tick": g5b.tick - 9,
		"due_tick": g5b.tick - 9 + g5bcharge, "recovery_ticks": g5brec, "paid_cost": 1000,
		"cooldown_end": 144, "stability": 1, "interrupt_power": 0, "state": "preparing",
		"cancel_cause": "", "plan": {}}
	g5ba["action"]["owning_family"] = 1
	var g5b_eq := g5b._charging_intent_block(g5ba, 2)
	g5ba["action"]["start_tick"] = g5b.tick - 8
	g5ba["action"]["due_tick"] = g5b.tick - 8 + g5bcharge
	var g5b_lo := g5b._charging_intent_block(g5ba, 2)
	if g5b_eq != "finishing_current_action" or g5b_lo != "":
		g5_bad.append("INT50 Bound elapsed9/8 guard %s/%s != finishing_current_action/" % [
			g5b_eq, g5b_lo])
	g5ba["action"]["owning_family"] = 2
	g5ba["action"]["start_tick"] = g5b.tick - 9
	g5ba["action"]["due_tick"] = g5b.tick - 9 + g5bcharge
	var g5b_own := g5b._charging_intent_block(g5ba, 2)
	if g5b_own != "":
		g5_bad.append("Defense-owned Bound declined its own family with %s" % g5b_own)
	g5ba["action"] = null

	# QA-F04: pre-start exhaustion cancels charged work that a PRODUCTION start really paid for.
	# Actor cooldown/resources are captured before and compared after, so the assertion tests
	# preservation instead of a fabricated action literal that the actor never held.
	var g5x := _new_sim(3101, "diagnostic")
	var g5xa: Dictionary = g5x.actors[0]
	g5xa["x"] = 4000.0
	g5xa["y"] = 3000.0
	g5x.actors[1]["x"] = 5000.0
	g5x.actors[1]["y"] = 3000.0
	g5xa["stam"] = 4000
	g5x._refresh_gates(g5xa)
	var g5xplan := {"skill": "brace", "goal": null, "candidates": [], "fits": {},
		"fit_reason": "hold_ground"}
	g5x._try_start(g5xa, "brace", g5xplan, g5x.actors[1])
	var g5_x6: Array = _events_of_type(g5x, 6)
	var g5_x7: Array = _events_of_type(g5x, 7)
	var g5_xaid := -1
	if g5xa["action"] == null or g5_x6.is_empty() or g5_x7.is_empty():
		g5_bad.append("production Brace start failed action=%s start=%d cost=%d" % [
			str(g5xa["action"] != null), g5_x6.size(), g5_x7.size()])
	else:
		g5_xaid = int((g5_x6[0][3] as Array)[0])
		if int((g5_x7[0][3] as Array)[0]) != g5_xaid:
			g5_bad.append("START aid %d != COST aid %s" % [
				g5_xaid, str((g5_x7[0][3] as Array)[0])])
	var g5_xstam := int(g5xa["stam"])
	var g5_xcd := int(g5xa["cooldown_end"]["brace"])
	if g5_xcd != g5x.tick + g5cd:
		g5_bad.append("production cooldown %d != start+cd %d" % [g5_xcd, g5x.tick + g5cd])
	g5xa["stam"] = 0
	g5x._detect_pre_start_exhaustion()
	var g5_x9: Array = _events_of_type(g5x, 9)
	var g5_x10: Array = _events_of_type(g5x, 10)
	if g5_x10.is_empty() or str((g5_x10[0][3] as Array)[3]) != "exhaustion" \
			or g5xa["action"] != null:
		g5_bad.append("exhaustion events=%d reason=%s action-cleared=%s != 1 exhaustion and cleared" % [
			g5_x10.size(), str((g5_x10[0][3] as Array)[3] if not g5_x10.is_empty() else ""),
			str(g5xa["action"] == null)])
	if g5_x10.is_empty() or g5_xaid < 0 or int((g5_x10[0][3] as Array)[0]) != g5_xaid:
		g5_bad.append("CANCEL aid %s != START/COST aid %d" % [
			str((g5_x10[0][3] as Array)[0]) if not g5_x10.is_empty() else "none", g5_xaid])
	if int(g5xa["cooldown_end"]["brace"]) != g5_xcd:
		g5_bad.append("exhaustion mutated the paid cooldown %d -> %d" % [
			g5_xcd, int(g5xa["cooldown_end"]["brace"])])
	if int(g5xa["stam"]) != 0 or g5_xstam != 4000 - 800:
		g5_bad.append("exhaustion pre/post stam %d/%d != %d/0" % [
			g5_xstam, int(g5xa["stam"]), 4000 - 800])
	if int(g5xa["recovery_end"]) != g5x.tick + g5recovery:
		g5_bad.append("exhaustion recovery_end %d != %d" % [
			int(g5xa["recovery_end"]), g5x.tick + g5recovery])
	if not g5_x9.is_empty():
		g5_bad.append("exhausted charge still committed (%d COMMIT events)" % g5_x9.size())
	# GP-PLAY01-R03-F01 / GP-PLAY01-R04-F01 / QA-PLAY01-R04-F01 — autonomous compatible
	# preparation keeps its GENERAL behaviour context, and this case now asserts the UNDERSTOOD
	# RESPONSE boundary instead of the request-ingress boundary. `_stage` only queues gateway
	# ingress at stage_at + 1; `_issue_episode` then stamps response_due = issue + D, where D is
	# derived below from the frozen response tuning and the pre-issuance fatigue snapshot
	# (technique start adds 200, every charge boundary decays 2). No accepted intent exists at
	# the start: own HP5000/12000 (2500/12000 for the disengaging case), a visible stationary
	# controlled peer 1000 away, INT100/Bond50/pressure0, sufficient stamina and the other
	# technique held unavailable so each plan is a single candidate (no selector draw). Autonomy
	# alone pays for the charged technique; a same-compatible general intent resolving during
	# that charge must WAIT — no below-threshold cancellation and no at/above-threshold
	# finishing_current_action decline — while request/episode/intent stay absent, so no trainer
	# attribution is invented. The trainer-owned changed-hint probes above stay as they were.
	# FIX04 selects the existing early ingress2/response15 shape; the late Brace case moves to
	# ingress9/response22 so it still observes the charge before Brace commits at 28.
	# FIX05 correction 1: the four flags are the EXPECTED THRESHOLD SIDE at INT100 (0.75), not
	# whether the response tick is late. Bound's frozen charge is 18, so its response15 lands on
	# 14/18 = 0.777778, i.e. AT/ABOVE the threshold — same as the late Brace — even though it
	# shares the early response tick. Expected sides: false / true / true / true.
	var g5aut := [
		{"name": "autonomous defensive Brace, Defense resolves early", "hp": 5000,
			"brace_off": true, "skill": "brace", "ctx": 2, "fam": 2, "stage_at": 1,
			"fat": 200, "above": false},
		{"name": "autonomous defensive Brace, Defense resolves late", "hp": 5000,
			"brace_off": true, "skill": "brace", "ctx": 2, "fam": 2, "stage_at": 8,
			"fat": 186, "above": true},
		{"name": "autonomous defensive Bound, Defense resolves at/above threshold", "hp": 5000,
			"brace_off": false, "skill": "short_bound", "ctx": 2, "fam": 2, "stage_at": 1,
			"fat": 200, "above": true},
		{"name": "autonomous disengaging Bound, Run resolves at/above threshold", "hp": 2500,
			"brace_off": false, "skill": "short_bound", "ctx": 3, "fam": 3, "stage_at": 1,
			"fat": 200, "above": true},
	]
	for g5cfg in g5aut:
		var g5n := str(g5cfg["name"])
		var g5s2 := _new_sim(3101, "diagnostic")
		var g5sa: Dictionary = g5s2.actors[0]
		var g5sf: Dictionary = g5s2.actors[1]
		g5sa["x"] = 4000.0
		g5sa["y"] = 3000.0
		g5sf["x"] = 5000.0
		g5sf["y"] = 3000.0
		g5sf["control_mode"] = 1
		g5sa["enemy_visible"] = true
		g5sa["hp"] = int(g5cfg["hp"])
		g5sa["hp_max"] = 12000
		g5sa["stam"] = int(g5sa["stam_max"])
		g5sa["int_stat"] = 100
		if bool(g5cfg["brace_off"]):
			g5sa["cooldown_end"]["short_bound"] = 999999
		else:
			g5sa["cooldown_end"]["brace"] = 999999
		g5s2.forced_uniforms["response.0"] = [0.99]
		_stage(g5s2, 0, int(g5cfg["fam"]), 1, int(g5cfg["stage_at"]))
		g5s2._refresh_gates(g5sa)
		# Independent response deadline: the same frozen formula `_issue_episode` applies, fed
		# from this fixture's own INT/Bond/pressure and the labelled PRE-issuance fatigue
		# snapshot. It is never read back from the case being tested.
		var g5tune: Dictionary = content.tuning["response"]
		var g5_iv := float(g5sa["int_stat"]) / 100.0
		var g5_bv := float(g5sa["bond"]) / 100.0
		var g5_pv := float(g5sa["pressure"]) / 30.0
		var g5_fv := float(int(g5cfg["fat"])) / 10000.0
		var g5_raw := float(g5tune["deadline_base"]) \
				+ float(g5tune["deadline_int_weight"]) * g5_iv \
				+ float(g5tune["deadline_bond_weight"]) * g5_bv \
				+ float(g5tune["deadline_pressure_weight"]) * g5_pv \
				+ float(g5tune["deadline_fatigue_weight"]) * g5_fv
		var g5_d := int(ceil(float(g5tune["deadline_scale"])
				* clampf(g5_raw, float(g5tune["deadline_min"]), float(g5tune["deadline_max"]))))
		var g5_ingress := int(g5cfg["stage_at"]) + 1
		var g5_resp := g5_ingress + g5_d
		if g5_d != 13:
			g5_bad.append("%s independent deadline D=%d != 13 (pre-fatigue %d, raw %.6f)" % [
				g5n, g5_d, int(g5cfg["fat"]), g5_raw])
		_pstep(g5s2)
		var g5_start_tick := g5s2.tick
		var g5paid_stam := int(g5sa["stam"])
		var g5paid_cd := int(g5sa["cooldown_end"].get(str(g5cfg["skill"]), 0))
		if g5sa["action"] == null \
				or str((g5sa["action"] as Dictionary).get("skill", "")) != str(g5cfg["skill"]) \
				or str((g5sa["action"] as Dictionary).get("state", "")) != "preparing":
			g5_bad.append("%s did not autonomously start (b=%d): action=%s" % [
				g5n, g5_start_tick, str(g5sa["action"])])
			continue
		var g5_aid := int((g5sa["action"] as Dictionary).get("action", -1))
		if int((g5sa["action"] as Dictionary).get("owning_family", -1)) != int(g5cfg["ctx"]) \
				or int((g5sa["action"] as Dictionary).get("intent", -1)) != -1 \
				or int((g5sa["action"] as Dictionary).get("request", 0)) != 0:
			g5_bad.append("%s action ctx/intent/request %d/%d/%d != %d/-1/0" % [
				g5n, int((g5sa["action"] as Dictionary).get("owning_family", -1)),
				int((g5sa["action"] as Dictionary).get("intent", -1)),
				int((g5sa["action"] as Dictionary).get("request", 0)), int(g5cfg["ctx"])])
		# Autonomous PLAN / START / COST produced on the start boundary, correlated by action id
		# AND by absolute tick (raw telemetry rows carry a delta at [0], so `_events_with_tick`
		# is what turns them into absolute boundaries).
		var g5_p5: Array = _events_with_tick(g5s2, 5)
		var g5_p6: Array = _events_with_tick(g5s2, 6)
		var g5_p7: Array = _events_with_tick(g5s2, 7)
		if g5_p5.size() != 1 or int(g5_p5[0][0]) != g5_start_tick \
				or str((g5_p5[0][1] as Array)[6]) != str(g5cfg["skill"]):
			g5_bad.append("%s autonomous PLAN rows/tick/skill %d/%d/%s != 1/%d/%s" % [
				g5n, g5_p5.size(),
				int(g5_p5[0][0]) if not g5_p5.is_empty() else -1,
				str((g5_p5[0][1] as Array)[6]) if not g5_p5.is_empty() else "none",
				g5_start_tick, str(g5cfg["skill"])])
		if g5_p6.size() != 1 or int(g5_p6[0][0]) != g5_start_tick \
				or int((g5_p6[0][1] as Array)[0]) != g5_aid \
				or int((g5_p6[0][1] as Array)[1]) != 0 \
				or int((g5_p6[0][1] as Array)[3]) != 0 \
				or str((g5_p6[0][1] as Array)[4]) != str(g5cfg["skill"]):
			g5_bad.append("%s START rows/tick/aid/actor/request/skill %d/%d/%d/%d/%d/%s != 1/%d/%d/0/0/%s" % [
				g5n, g5_p6.size(),
				int(g5_p6[0][0]) if not g5_p6.is_empty() else -1,
				int((g5_p6[0][1] as Array)[0]) if not g5_p6.is_empty() else -1,
				int((g5_p6[0][1] as Array)[1]) if not g5_p6.is_empty() else -1,
				int((g5_p6[0][1] as Array)[3]) if not g5_p6.is_empty() else -1,
				str((g5_p6[0][1] as Array)[4]) if not g5_p6.is_empty() else "none",
				g5_start_tick, g5_aid, str(g5cfg["skill"])])
		if g5_p7.size() != 1 or int(g5_p7[0][0]) != g5_start_tick \
				or int((g5_p7[0][1] as Array)[0]) != g5_aid \
				or int((g5_p7[0][1] as Array)[1]) != 0 \
				or int((g5_p7[0][1] as Array)[3]) != g5paid_stam \
				or int((g5_p7[0][1] as Array)[4]) != g5paid_cd:
			g5_bad.append("%s COST rows/tick/aid/actor/after/cd %d/%d/%d/%d/%d/%d != 1/%d/%d/0/%d/%d" % [
				g5n, g5_p7.size(),
				int(g5_p7[0][0]) if not g5_p7.is_empty() else -1,
				int((g5_p7[0][1] as Array)[0]) if not g5_p7.is_empty() else -1,
				int((g5_p7[0][1] as Array)[1]) if not g5_p7.is_empty() else -1,
				int((g5_p7[0][1] as Array)[3]) if not g5_p7.is_empty() else -1,
				int((g5_p7[0][1] as Array)[4]) if not g5_p7.is_empty() else -1,
				g5_start_tick, g5_aid, g5paid_stam, g5paid_cd])
		# QA-PLAY01-R04-F01 / QA-PLAY01-R05-F02: advance a FINITE number of real boundaries
		# through the independently expected response deadline. The local attempt counter is the
		# actual bound — `tick < deadline` alone never terminates when `step()` returns without
		# advancing tick because the encounter has already ended, and an ended encounter must be
		# rejected rather than waited on. Ingress alone (stage_at + 1) proves nothing about the
		# understood response, and waiting indefinitely for observed acceptance is not a check.
		var g5_budget := (g5_resp - g5s2.tick) + 20
		var g5_attempts := 0
		var g5_end_reason := ""
		while g5s2.tick < g5_resp:
			if g5s2.ended:
				g5_end_reason = "ended_before_deadline"
				break
			if g5_attempts >= g5_budget:
				g5_end_reason = "attempt_budget_exhausted"
				break
			_pstep(g5s2)
			g5_attempts += 1
		if g5_end_reason == "" and g5s2.tick != g5_resp:
			g5_end_reason = "tick_past_expected_deadline"
		if g5_end_reason != "":
			g5_bad.append("%s response wait failed: reason=%s seed3101 last_tick=%d expected_deadline=%d attempts=%d budget=%d" % [
				g5n, g5_end_reason, g5s2.tick, g5_resp, g5_attempts, g5_budget])
		# Ingress vs response: `_stage` only queues the request, so REQUEST and the episode ISSUE
		# both land on the ingress boundary and the RESPONSE lands exactly D ticks later on the
		# independently expected boundary. Verified through absolute ticks, not raw deltas.
		var g5_req: Array = _events_with_tick(g5s2, 1)
		if g5_req.size() != 1 or int(g5_req[0][0]) != g5_ingress \
				or int((g5_req[0][1] as Array)[0]) != 1 \
				or int((g5_req[0][1] as Array)[2]) != 0:
			g5_bad.append("%s REQUEST rows/tick/rid/actor %d/%d/%d/%d != 1/%d/1/0" % [
				g5n, g5_req.size(),
				int(g5_req[0][0]) if not g5_req.is_empty() else -1,
				int((g5_req[0][1] as Array)[0]) if not g5_req.is_empty() else -1,
				int((g5_req[0][1] as Array)[2]) if not g5_req.is_empty() else -1,
				g5_ingress])
		var g5_issue: Array = []
		for g5row in _events_with_tick(g5s2, 4):
			if str((g5row[1] as Array)[6]) == "issue":
				g5_issue.append(g5row)
		if g5_issue.size() != 1 or int(g5_issue[0][0]) != g5_ingress \
				or int((g5_issue[0][1] as Array)[0]) != 0 \
				or int((g5_issue[0][1] as Array)[1]) != 1:
			g5_bad.append("%s episode ISSUE rows/tick/actor/rid %d/%d/%d/%d != 1/%d/0/1" % [
				g5n, g5_issue.size(),
				int(g5_issue[0][0]) if not g5_issue.is_empty() else -1,
				int((g5_issue[0][1] as Array)[0]) if not g5_issue.is_empty() else -1,
				int((g5_issue[0][1] as Array)[1]) if not g5_issue.is_empty() else -1,
				g5_ingress])
		var g5_eps: Variant = g5sa["response_episode"]
		if not (g5_eps is Dictionary):
			g5_bad.append("%s response episode record is missing after acceptance" % g5n)
		else:
			var g5_response_ep := g5_eps as Dictionary
			var g5_iss := int(g5_response_ep.get("issue_tick", -1))
			var g5_due := int(g5_response_ep.get("response_due", -1))
			var g5_pre := int(g5_response_ep.get("pre_issuance_fatigue", -1))
			if g5_iss != g5_ingress or g5_due != g5_resp or g5_due - g5_iss != g5_d \
					or g5_pre != int(g5cfg["fat"]):
				g5_bad.append("%s issue/due/D/pre-fatigue %d/%d/%d/%d != %d/%d/%d/%d" % [
					g5n, g5_iss, g5_due, g5_due - g5_iss, g5_pre,
					g5_ingress, g5_resp, g5_d, int(g5cfg["fat"])])
			if not bool(g5_response_ep.get("draw_resolved", false)) or int(g5_response_ep.get("class", -1)) != 6 \
					or int(g5_response_ep.get("interpreted_family", -1)) != int(g5cfg["fam"]) \
					or int(g5_response_ep.get("episode", -1)) != 1:
				g5_bad.append("%s episode resolved/class/interpreted/eid %s/%d/%d/%d != true/6/%d/1" % [
					g5n, str(bool(g5_response_ep.get("draw_resolved", false))),
					int(g5_response_ep.get("class", -1)), int(g5_response_ep.get("interpreted_family", -1)),
					int(g5_response_ep.get("episode", -1)), int(g5cfg["fam"])])
		var g5guard := g5s2._charging_intent_block(g5sa, int(g5cfg["fam"]))
		if g5guard != "":
			g5_bad.append("%s same-compatible charge guard %s != empty" % [g5n, g5guard])
		var g5_c10: Array = _events_of_type(g5s2, 10)
		if not g5_c10.is_empty():
			g5_bad.append("%s compatible intent cancelled the charge: reason %s" % [
				g5n, str((g5_c10[0][3] as Array)[3])])
		var g5_r3: Array = _events_with_tick(g5s2, 3)
		var g5_cls := -1
		var g5_int := -1
		var g5_rid := -1
		var g5_resp_tick := -1
		if not g5_r3.is_empty():
			g5_resp_tick = int(g5_r3[0][0])
			g5_cls = int((g5_r3[0][1] as Array)[4])
			g5_int = int((g5_r3[0][1] as Array)[6])
			g5_rid = int((g5_r3[0][1] as Array)[0])
		if g5_r3.size() != 1 or g5_resp_tick != g5_resp or g5_cls != 6 \
				or g5_int != int(g5cfg["fam"]) or g5_rid != 1:
			g5_bad.append("%s RESPONSE rows/tick/class/interpreted/rid %d/%d/%d/%d/%d != 1/%d/6/%d/1" % [
				g5n, g5_r3.size(), g5_resp_tick, g5_cls, g5_int, g5_rid,
				g5_resp, int(g5cfg["fam"])])
		var g5acc: Variant = g5sa["accepted_intent"]
		if not (g5acc is Dictionary):
			g5_bad.append("%s compatible intent was never accepted" % g5n)
		else:
			var g5acc2 := g5acc as Dictionary
			if int(g5acc2.get("family", -1)) != int(g5cfg["fam"]) \
					or int(g5acc2.get("request", -1)) != 1:
				g5_bad.append("%s accepted family/request %d/%d != %d/1" % [
					g5n, int(g5acc2.get("family", -1)), int(g5acc2.get("request", -1)),
					int(g5cfg["fam"])])
		# The response must land while the SAME paid preparation is still live, and on the
		# threshold side this configuration expects.
		var g5_act: Variant = g5sa["action"]
		if not (g5_act is Dictionary):
			g5_bad.append("%s action vanished before the response boundary %d" % [
				g5n, g5_resp])
		else:
			var g5ad := g5_act as Dictionary
			var g5_el := float(g5s2.tick - int(g5ad.get("start_tick", 0)))
			var g5_tot := float(content.charge_ticks(str(g5ad.get("skill", ""))))
			var g5_ratio := 0.0 if g5_tot <= 0.0 else g5_el / g5_tot
			var g5_thresh := 0.25 + 0.50 * (float(g5sa["int_stat"]) / 100.0)
			var g5_above := bool(g5cfg["above"])
			if g5_above != (g5_ratio >= g5_thresh):
				g5_bad.append("%s charge ratio %.6f vs threshold %.6f is not the expected %s side" % [
					g5n, g5_ratio, g5_thresh, "at/above" if g5_above else "below"])
			if g5s2.tick >= int(g5ad.get("due_tick", -1)):
				g5_bad.append("%s response boundary %d is not before due %d" % [
					g5n, g5s2.tick, int(g5ad.get("due_tick", -1))])
		if g5sa["action"] == null \
				or int((g5sa["action"] as Dictionary).get("action", -1)) != g5_aid \
				or str((g5sa["action"] as Dictionary).get("state", "")) != "preparing" \
				or int((g5sa["action"] as Dictionary).get("owning_family", -1)) != int(g5cfg["ctx"]) \
				or int((g5sa["action"] as Dictionary).get("intent", -1)) != -1 \
				or int((g5sa["action"] as Dictionary).get("request", 0)) != 0:
			g5_bad.append("%s after-wait id/state/ctx/intent/request %d/%s/%d/%d/%d != %d/preparing/%d/-1/0" % [
				g5n,
				int((g5sa["action"] as Dictionary).get("action", -1)) if g5sa["action"] is Dictionary else -1,
				str((g5sa["action"] as Dictionary).get("state", "")) if g5sa["action"] is Dictionary else "none",
				int((g5sa["action"] as Dictionary).get("owning_family", -1)) if g5sa["action"] is Dictionary else -1,
				int((g5sa["action"] as Dictionary).get("intent", -1)) if g5sa["action"] is Dictionary else -1,
				int((g5sa["action"] as Dictionary).get("request", 0)) if g5sa["action"] is Dictionary else -1,
				g5_aid, int(g5cfg["ctx"])])
		if int(g5sa["stam"]) != g5paid_stam \
				or int(g5sa["cooldown_end"].get(str(g5cfg["skill"]), 0)) != g5paid_cd:
			g5_bad.append("%s after-wait paid stam/cd %d/%d != %d/%d" % [
				g5n, int(g5sa["stam"]),
				int(g5sa["cooldown_end"].get(str(g5cfg["skill"]), 0)),
				g5paid_stam, g5paid_cd])
	# FIX05 correction 2 / QA-PLAY01-R05-F02 — inline PREMATURE-END control, inside C54: no new
	# helper, no new record id, no product change. The same defensive-Brace early fixture is
	# rebuilt with existing setup/state machinery, the paid autonomous start is taken on a real
	# boundary, and only then is the existing public `ended` state set, before the expected
	# response deadline. The bounded wait MUST terminate and identify this response case as
	# failed inside its attempt budget. That modelled response-case failure is captured as
	# diagnostic evidence — never a C54 pass and never an unconditional C54 failure. g5_bad gains
	# an entry only if the termination itself is wrong.
	var g5_diag_note := "premature-end control seed3101: not reached"
	var g5d := _new_sim(3101, "diagnostic")
	var g5da: Dictionary = g5d.actors[0]
	var g5df: Dictionary = g5d.actors[1]
	g5da["x"] = 4000.0
	g5da["y"] = 3000.0
	g5df["x"] = 5000.0
	g5df["y"] = 3000.0
	g5df["control_mode"] = 1
	g5da["enemy_visible"] = true
	g5da["hp"] = 5000
	g5da["hp_max"] = 12000
	g5da["stam"] = int(g5da["stam_max"])
	g5da["int_stat"] = 100
	g5da["cooldown_end"]["short_bound"] = 999999
	g5d.forced_uniforms["response.0"] = [0.99]
	_stage(g5d, 0, 2, 1, 1)
	g5d._refresh_gates(g5da)
	_pstep(g5d)
	var g5d_start := g5d.tick
	var g5d_expect := 15
	var g5d_budget := (g5d_expect - g5d.tick) + 20
	var g5d_attempts := 0
	var g5d_reason := ""
	if g5da["action"] == null:
		g5_bad.append("%s premature-end control could not take a paid start (tick %d)" % [
			"premature-end", g5d_start])
	else:
		# Premature end AFTER the paid start and BEFORE the expected response deadline.
		g5d.ended = true
		while g5d.tick < g5d_expect:
			if g5d.ended:
				g5d_reason = "ended_before_deadline"
				break
			if g5d_attempts >= g5d_budget:
				g5d_reason = "attempt_budget_exhausted"
				break
			_pstep(g5d)
			g5d_attempts += 1
		if g5d_reason == "" and g5d.tick != g5d_expect:
			g5d_reason = "tick_past_expected_deadline"
		var g5d_req := _events_with_tick(g5d, 1).size()
		var g5d_resp_rows := _events_with_tick(g5d, 3).size()
		var g5d_start_rows := _events_with_tick(g5d, 6).size()
		if g5d_reason != "ended_before_deadline" or g5d.tick >= g5d_expect \
				or g5d_attempts > g5d_budget:
			g5_bad.append("premature-end control did not terminate as expected: reason=%s seed3101 last_tick=%d expected_deadline=%d attempts=%d budget=%d" % [
				g5d_reason, g5d.tick, g5d_expect, g5d_attempts, g5d_budget])
		g5_diag_note = "premature-end control seed3101: response case FAILED - encounter ended after paid START@%d before expected deadline %d; wait terminated reason=%s last_tick=%d attempts=%d budget=%d; causal rows REQUEST=%d RESPONSE=%d START=%d; captured as diagnostic evidence, not a C54 pass and not an unconditional C54 failure" % [
			g5d_start, g5d_expect, g5d_reason, g5d.tick, g5d_attempts, g5d_budget,
			g5d_req, g5d_resp_rows, g5d_start_rows]
	var g5_detail := "stam599 no start/debit/cooldown mutation, 600 pays to0, 601 to1, cd start+72; INT100 Brace 20/27 allows + retains pay/recovery/owner, 21/27 declines; INT50 Bound 8/18 allows, 9/18 equality declines, Defense-owned Bound passes its own family; production start exhausted -> CANCEL10 exhaustion with same aid, no COMMIT, stam/cooldown preserved, recovery+15; autonomous defensive Brace/Bound and disengaging Bound keep their general context (Defense/Run) and WAIT for a same-compatible intent: ingress2/9 with the independently derived D13 response at15/22 while the same aid is still preparing, one class6 same-family RESPONSE, no cancel/decline, causal IDs 0/0/-1 and paid cost/cooldown unchanged; threshold sides expected false/true/true/true (Brace14/27 and21/27, Bound14/18 twice)"
	_record("C54-quick-g14-boundaries", g5_bad.is_empty(),
		(g5_detail + "; " + g5_diag_note) if g5_bad.is_empty()
			else ("; ".join(g5_bad) + "; " + g5_diag_note))

func _case_c55(g5charge: int, g5recovery: int) -> void:
	# C55 FIX01/4/QA-F04/F06 — movement suppression and continuation under the applicable
	# action state, asserted both directly and as applied boundary displacement instead of only
	# via a non-null action check.
	var g6_bad: Array = []
	var g6 := _new_sim(3101, "diagnostic")
	var g6a: Dictionary = g6.actors[0]
	g6a["action"] = {"action": 1, "actor": 0, "skill": "quick_claw", "state": "recovering",
		"start_tick": 0, "due_tick": 0, "recovery_ticks": 21}
	var g6_quick := not g6._movement_allowed(g6a)
	g6a["action"]["skill"] = "short_bound"
	var g6_bound_ok := g6._movement_allowed(g6a)
	g6a["action"]["skill"] = "brace"
	var g6_brace_ok := g6._movement_allowed(g6a)
	g6a["action"] = null
	g6a["bound_active"] = true
	var g6_travel := not g6._movement_allowed(g6a)
	g6a["bound_active"] = false
	g6a["action"] = {"action": 2, "actor": 0, "skill": "brace", "state": "preparing",
		"start_tick": g6.tick, "due_tick": g6.tick + g5charge, "recovery_ticks": g5recovery}
	var g6_charge := not g6._movement_allowed(g6a)
	g6a["action"] = {"action": 3, "actor": 0, "skill": "quick_claw", "state": "due",
		"start_tick": g6.tick, "due_tick": g6.tick, "recovery_ticks": 21}
	var g6_due := not g6._movement_allowed(g6a)
	g6a["action"] = null
	if not (g6_quick and g6_bound_ok and g6_brace_ok and g6_travel and g6_charge and g6_due):
		g6_bad.append("states quick-recovering=%s bound-recovering=%s brace-recovering=%s bound-active=%s preparing=%s due=%s != true/true/true/true/true/true" % [
			str(g6_quick), str(g6_bound_ok), str(g6_brace_ok), str(g6_travel),
			str(g6_charge), str(g6_due)])
	# QA-F06 / QA-PLAY01-R04-F02: the same conclusions as APPLIED DISPLACEMENT across labelled
	# boundaries, not only as a Boolean helper result. STAGE LABEL — these are SAME-TICK helper
	# controls: `_one_boundary_move` samples position and `moved_this_boundary` immediately after
	# `_movement_cut()`, i.e. PRE-cut6, so the scratch flag is still live here. They do not
	# establish elapsed time. The real-boundary blocks below do, and there the post-step oracle is
	# the measured position, because cut6 consumes `moved_this_boundary` on ordinary boundaries.
	var g6m := _new_sim(3101, "diagnostic")
	g6m.actors[1]["x"] = 16000.0
	g6m.actors[1]["y"] = 9000.0
	var g6m_start: Array = [4000.0, 3000.0]
	var g6m_goal: Array = [7000.0, 3000.0]
	var g6m_free: Array = _one_boundary_move(g6m, 0, g6m_start, g6m_goal, null)
	if not bool(g6m_free[1]) or float(g6m_free[0]) <= 0.0 or float(g6m_free[0]) > 50.001:
		g6_bad.append("unrestricted boundary displacement %.6f moved=%s != (0,50.001] and true" % [
			float(g6m_free[0]), str(bool(g6m_free[1]))])
	for g6k in 3:
		var g6mq: Array = _one_boundary_move(g6m, 0, g6m_start, g6m_goal, {"action": 7,
			"actor": 0, "skill": "quick_claw", "state": "recovering",
			"start_tick": g6m.tick, "due_tick": g6m.tick, "recovery_ticks": 21})
		if absf(float(g6mq[0])) > 1e-9 or bool(g6mq[1]) \
				or absf(float(g6mq[2]) - g6m_start[0]) > 1e-9 \
				or absf(float(g6mq[3]) - g6m_start[1]) > 1e-9:
			g6_bad.append("Quick recovery boundary %d displacement %.6f moved=%s at (%.1f,%.1f) != 0/false at the labelled start" % [
				g6k, float(g6mq[0]), str(bool(g6mq[1])), float(g6mq[2]), float(g6mq[3])])
	var g6mb: Array = _one_boundary_move(g6m, 0, g6m_start, g6m_goal, {"action": 8,
		"actor": 0, "skill": "short_bound", "state": "recovering",
		"start_tick": g6m.tick, "due_tick": g6m.tick, "recovery_ticks": 12})
	if not bool(g6mb[1]) or float(g6mb[0]) <= 0.0 or float(g6mb[0]) > 50.001:
		g6_bad.append("Bound recovery boundary displacement %.6f moved=%s != (0,50.001] and true" % [
			float(g6mb[0]), str(bool(g6mb[1]))])
	# QA-PLAY01-R03-F03: the interval claims must be established across REAL advancing
	# boundaries — repeating _movement_cut on one tick cannot prove a 21-tick recovery, its
	# release, or ordinary movement on the boundary after a Bound arrival. A production Quick
	# starts inside a real step, holds zero applied displacement through b+1..b+20, and is first
	# allowed to move again on the release boundary b+21.
	var g6r := _new_sim(3101, "diagnostic")
	var g6ra: Dictionary = g6r.actors[0]
	var g6rf: Dictionary = g6r.actors[1]
	g6ra["x"] = 4000.0
	g6ra["y"] = 3000.0
	g6rf["x"] = 5000.0
	g6rf["y"] = 3000.0
	g6rf["control_mode"] = 1
	g6ra["enemy_visible"] = true
	g6ra["stam"] = int(g6ra["stam_max"])
	_pstep(g6r)
	var g6rb := g6r.tick
	var g6r_rec := int(content.recovery_ticks("quick_claw"))
	if g6r_rec != 21:
		g6_bad.append("frozen Quick recovery %d != 21" % g6r_rec)
	if _events_of_type(g6r, 6).is_empty() or _events_with_tick(g6r, 9).is_empty():
		g6_bad.append("Quick did not start and commit on its own boundary b=%d" % g6rb)
	else:
		# Distant controlled peer: outside contact range and outside vision, so the release
		# boundary plans a legal ordinary move goal instead of resting against a stale peer.
		g6rf["x"] = 16000.0
		g6rf["y"] = 9000.0
		var g6r_start: Array = [float(g6ra["x"]), float(g6ra["y"])]
		for g6k in g6r_rec - 1:
			_pstep(g6r)
			var g6rd := sqrt(pow(float(g6ra["x"]) - g6r_start[0], 2.0)
				+ pow(float(g6ra["y"]) - g6r_start[1], 2.0))
			var g6r_state := "none"
			if g6ra["action"] is Dictionary:
				g6r_state = str((g6ra["action"] as Dictionary).get("state", ""))
			# QA-PLAY01-R04-F02: after a full step the resource cut has already consumed
			# `moved_this_boundary`, so the measured position delta is the only post-step oracle.
			# A zero displacement must fail on position alone.
			if g6r.tick != g6rb + g6k + 1 or absf(g6rd) > 1e-9 \
					or g6r_state != "recovering":
				g6_bad.append("Quick recovering boundary %d (tick %d) disp=%.6f state=%s != 0/recovering (position delta after step)" % [
					g6k + 1, g6r.tick, g6rd, g6r_state])
		_pstep(g6r)
		var g6r_disp := sqrt(pow(float(g6ra["x"]) - g6r_start[0], 2.0)
			+ pow(float(g6ra["y"]) - g6r_start[1], 2.0))
		if g6r.tick != g6rb + g6r_rec:
			g6_bad.append("release boundary tick %d != b+21 (%d)" % [g6r.tick, g6rb + g6r_rec])
		if g6ra["action"] != null or int(g6ra["recovery_end"]) != g6rb + g6r_rec:
			g6_bad.append("release action=%s recovery_end=%d != null/%d" % [
				str(g6ra["action"] != null), int(g6ra["recovery_end"]), g6rb + g6r_rec])
		if g6r_disp <= 0.0 or g6r_disp > 50.001:
			g6_bad.append("release displacement %.6f != (0,50.001] (measured position delta after step)" % [
				g6r_disp])
		if not arena.center_legal(float(g6ra["x"]), float(g6ra["y"])):
			g6_bad.append("release landed on an illegal position (%.6f, %.6f)" % [
				float(g6ra["x"]), float(g6ra["y"])])
		var g6r_goal: Variant = g6ra["goal"]
		if not (g6r_goal is Dictionary) \
				or str((g6r_goal as Dictionary).get("kind", "")) != "move":
			g6_bad.append("release goal %s != a legal move goal" % str(g6r_goal))
		else:
			for g6wp in (g6r_goal as Dictionary).get("route", []) as Array:
				if not arena.center_legal(float(g6wp[0]), float(g6wp[1])):
					g6_bad.append("release goal waypoint (%.6f, %.6f) is not legal" % [
						float(g6wp[0]), float(g6wp[1])])
					break
	# QA-PLAY01-R03-F03 / QA-PLAY01-R04-F03: an ACTUAL Bound arrival A across real boundaries,
	# correlated through the existing records instead of inferred from a disappearing action and
	# a recovery deadline, then ordinary movement on A+1 while the 12-tick Bound recovery is
	# still pending. The direct paid start at tick0 is a LABELED diagnostic (FIX04); C59 remains
	# the normal in-step start.
	var g6v := _new_sim(3101, "diagnostic")
	var g6va: Dictionary = g6v.actors[0]
	g6va["x"] = 4000.0
	g6va["y"] = 3000.0
	g6v.actors[1]["x"] = 16000.0
	g6v.actors[1]["y"] = 9000.0
	g6v.actors[1]["control_mode"] = 1
	g6va["stam"] = int(g6va["stam_max"])
	var g6v_route := [[4000.0, 3000.0], [6400.0, 3000.0]]
	var g6v_goal := {"kind": "move", "point": [6400.0, 3000.0], "route": g6v_route,
		"stop_mwu": 0.0, "purpose": "disengage", "patrol_index": -1, "i": 0}
	var g6v_plan := {"skill": "short_bound", "candidates": [], "fits": {}, "fit_reason": "run",
		"knowledge": "unknown", "goal": g6v_goal}
	g6v._refresh_gates(g6va)
	g6v._try_start(g6va, "short_bound", g6v_plan, g6v.actors[1])
	var g6v_aid := -1
	if g6va["action"] == null:
		g6_bad.append("Bound did not start for the real-boundary arrival check")
	else:
		g6v_aid = int((g6va["action"] as Dictionary).get("action", -1))
		if float(g6va["bound_total"]) < 200.0 or float(g6va["bound_total"]) > 2400.0 + 1e-6 \
				or absf(float(g6va["bound_total"]) - arena.route_length(g6v_route)) > 1e-6:
			g6_bad.append("Bound route/total %.6f != authored route length within [200,2400]" %
				float(g6va["bound_total"]))
		var g6v_guard := 0
		# Drive real boundaries until the travel actually terminates: the Bound is still charging
		# (bound_active false, action live) for the first18 boundaries, travels200 per boundary
		# after commit, and arrival is the boundary that sets recovery_end.
		while g6v_guard < 40 and (g6va["action"] != null or bool(g6va["bound_active"]) \
				or int(g6va["recovery_end"]) <= 0):
			_pstep(g6v)
			g6v_guard += 1
		var g6v_A := g6v.tick
		# QA-PLAY01-R04-F03: recovery alone does not prove arrival. Correlate the paid start to
		# its COMMIT, its two terminal travel records, and the absence of any cancellation. A
		# cancelled or obstructed or shortened travel fails one of these prerequisites.
		var g6v_start: Array = _events_with_tick(g6v, 6)
		var g6v_cost: Array = _events_with_tick(g6v, 7)
		var g6v_commit: Array = _events_with_tick(g6v, 9)
		var g6v_cancel: Array = _events_with_tick(g6v, 10)
		var g6v_trav: Array = []
		for g6row in _events_with_tick(g6v, 26):
			if int((g6row[1] as Array)[0]) == g6v_aid:
				g6v_trav.append(g6row)
		if g6v_start.size() != 1 or int(g6v_start[0][0]) != 0 \
				or int((g6v_start[0][1] as Array)[0]) != g6v_aid:
			g6_bad.append("Bound START rows/tick/aid %d/%d/%d != 1/0/%d" % [
				g6v_start.size(),
				int(g6v_start[0][0]) if not g6v_start.is_empty() else -1,
				int((g6v_start[0][1] as Array)[0]) if not g6v_start.is_empty() else -1,
				g6v_aid])
		if g6v_cost.size() != 1 or int(g6v_cost[0][0]) != 0 \
				or int((g6v_cost[0][1] as Array)[0]) != g6v_aid:
			g6_bad.append("Bound COST rows/tick/aid %d/%d/%d != 1/0/%d" % [
				g6v_cost.size(),
				int(g6v_cost[0][0]) if not g6v_cost.is_empty() else -1,
				int((g6v_cost[0][1] as Array)[0]) if not g6v_cost.is_empty() else -1,
				g6v_aid])
		if g6v_commit.size() != 1 or int(g6v_commit[0][0]) != 18 \
				or int((g6v_commit[0][1] as Array)[0]) != g6v_aid \
				or int((g6v_commit[0][1] as Array)[1]) != 0:
			g6_bad.append("Bound COMMIT rows/tick/aid/actor %d/%d/%d/%d != 1/18/%d/0" % [
				g6v_commit.size(),
				int(g6v_commit[0][0]) if not g6v_commit.is_empty() else -1,
				int((g6v_commit[0][1] as Array)[0]) if not g6v_commit.is_empty() else -1,
				int((g6v_commit[0][1] as Array)[1]) if not g6v_commit.is_empty() else -1,
				g6v_aid])
		if not g6v_cancel.is_empty():
			g6_bad.append("Bound travel carries %d CANCEL10 rows for aid %d != 0" % [
				g6v_cancel.size(), g6v_aid])
		var g6v_tn := g6v_trav.size()
		var g6v_p0 := "none"
		var g6v_t0 := -1
		var g6v_p1 := "none"
		var g6v_t1 := -1
		var g6v_r1 := "none"
		if g6v_tn == 2:
			g6v_p0 = str((g6v_trav[0][1] as Array)[2])
			g6v_t0 = int(g6v_trav[0][0])
			g6v_p1 = str((g6v_trav[1][1] as Array)[2])
			g6v_t1 = int(g6v_trav[1][0])
			g6v_r1 = str((g6v_trav[1][1] as Array)[4])
		if g6v_tn != 2 or g6v_p0 != "start" or g6v_t0 != 18 \
				or g6v_p1 != "end" or g6v_t1 != 30 or g6v_r1 != "arrived":
			g6_bad.append("Bound terminal travel rows/phase/ticks/reason %d %s@%d %s@%d/%s != 2 start@18 end@30/arrived" % [
				g6v_tn, g6v_p0, g6v_t0, g6v_p1, g6v_t1, g6v_r1])
		if g6v_A != 30:
			g6_bad.append("Bound arrival tick A=%d != independently expected 30" % g6v_A)
		if bool(g6va["bound_active"]) or g6v_guard >= 40 \
				or int(g6va["recovery_end"]) != g6v_A + int(content.recovery_ticks("short_bound")):
			g6_bad.append("Bound arrival active=%s boundaries=%d A=%d recovery_end=%d" % [
				str(bool(g6va["bound_active"])), g6v_guard, g6v_A,
				int(g6va["recovery_end"])])
		else:
			# Labelled arrival snapshot, taken BEFORE any further boundary so the completed
			# travel facts are read while they are still live.
			var g6v_snap_x := float(g6va["x"])
			var g6v_snap_y := float(g6va["y"])
			var g6v_snap_prog := float(g6va["bound_progress"])
			var g6v_snap_tot := float(g6va["bound_total"])
			var g6v_snap_rec := int(g6va["recovery_end"])
			if absf(g6v_snap_prog - 2400.0) > 1e-6 or absf(g6v_snap_tot - 2400.0) > 1e-6:
				g6_bad.append("arrival progress/total %.6f/%.6f != 2400/2400" % [
					g6v_snap_prog, g6v_snap_tot])
			if absf(g6v_snap_x - 6400.0) > 1e-6 or absf(g6v_snap_y - 3000.0) > 1e-6:
				g6_bad.append("arrival endpoint (%.6f, %.6f) != (6400, 3000)" % [
					g6v_snap_x, g6v_snap_y])
			if g6v_snap_rec != 42:
				g6_bad.append("arrival recovery_end %d != 42" % g6v_snap_rec)
			var g6v_before: Array = [float(g6va["x"]), float(g6va["y"])]
			_pstep(g6v)
			var g6v_disp := sqrt(pow(float(g6va["x"]) - g6v_before[0], 2.0)
				+ pow(float(g6va["y"]) - g6v_before[1], 2.0))
			if g6v.tick != g6v_A + 1 or g6v.tick >= g6v_snap_rec:
				g6_bad.append("A+1 tick %d vs A=%d recovery_end=%d" % [
					g6v.tick, g6v_A, g6v_snap_rec])
			# QA-PLAY01-R04-F02: measured position delta is the post-step oracle; the resource
			# cut has already consumed the scratch flag by the time step() returns.
			if g6v_disp <= 0.0 or g6v_disp > 50.001:
				g6_bad.append("A+1 displacement %.6f != (0,50.001] during pending recovery (measured position delta after step)" % [
					g6v_disp])
			if not arena.center_legal(float(g6va["x"]), float(g6va["y"])):
				g6_bad.append("A+1 landed on an illegal position (%.6f, %.6f)" % [
					float(g6va["x"]), float(g6va["y"])])
			var g6v_goal2: Variant = g6va["goal"]
			if not (g6v_goal2 is Dictionary) \
					or str((g6v_goal2 as Dictionary).get("kind", "")) != "move":
				g6_bad.append("A+1 goal %s != a legal move goal" % str(g6v_goal2))
			else:
				for g6wp2 in (g6v_goal2 as Dictionary).get("route", []) as Array:
					if not arena.center_legal(float(g6wp2[0]), float(g6wp2[1])):
						g6_bad.append("A+1 goal waypoint (%.6f, %.6f) is not legal" % [
							float(g6wp2[0]), float(g6wp2[1])])
						break
	_record("C55-movement-action-state", g6_bad.is_empty(),
		"Quick recovering and any preparing/due charge suppress movement; Bound/Brace recovery continue it; live Bound travel still suppressed; same-tick PRE-cut6 helper-control displacement free=%.1f, quick-recovery x3=0, bound-recovery=%.1f (flag sampled before the resource cut; does not establish elapsed time); real boundaries judged by MEASURED position deltas: Quick displacement 0 through b+20 and release b+21, Bound START@0/COMMIT@18/arrived@30 recovery42 then ordinary movement on A+1=31 while recovery is pending" % [float(g6m_free[0]), float(g6mb[0])]
			if g6_bad.is_empty() else "; ".join(g6_bad))

func _case_c57() -> void:
	# C57 FIX02/G2 — the owning-intent retirement gate (ARCH-F03 / GP-F05 / QA-F06). I captures
	# the cycle, a newer J is accepted while that cycle is still pending, and only I's ACTUAL
	# completion retires the owner: Quick recovery end, Brace hold expiry then its recovery end,
	# Bound arrival then its recovery end, and the actor-side rest counter at the frozen
	# threshold. J keeps the expiry acceptance gave it in every case, and the owner/rest
	# progress is part of the checkpoint row.
	var g9_bad: Array = []
	var g9_life := int(content.tuning["response"]["intent_lifetime_ticks"])
	for g9m in ["quick_claw", "brace", "short_bound"]:
		var g9 := _new_sim(3101, "diagnostic")
		var g9a: Dictionary = g9.actors[0]
		g9a["x"] = 4000.0
		g9a["y"] = 3000.0
		g9.actors[1]["x"] = 16000.0
		g9.actors[1]["y"] = 9000.0
		g9a["stam"] = 6000
		_mtick(g9, 1)
		# ARCH-PLAY01-R03-F03: Quick is an ATTACK technique — Defense can never choose Claw — so
		# the owning intent, the action record's owning_family and the response metadata are all
		# family 1. Brace and Bound stay Defense-owned (family 2), which is what production
		# actually leaves behind.
		var g9_fam := 1 if g9m == "quick_claw" else 2
		var g9_cat := "attack" if g9_fam == 1 else "defense"
		var g9_rec := int(content.recovery_ticks(g9m))
		var g9_i := {"episode": 2, "target_kind": 0, "target_or_area": null, "class": 6,
			"original_family": g9_fam, "latest_request": 5, "observation_category": g9_cat,
			"draw_resolved": false}
		g9._accept_intent(g9a, g9_i, g9_fam)
		g9._capture_cycle_owner(g9a)
		g9a["recovery_owner"] = int(g9a["cycle_intent"])
		if int(g9a["cycle_intent"]) != 1 or int(g9a["cycle_request"]) != 5 \
				or int(g9a["cycle_episode"]) != 2:
			g9_bad.append("%s owner capture %d/%d/%d != 1/5/2" % [g9m,
				int(g9a["cycle_intent"]), int(g9a["cycle_request"]),
				int(g9a["cycle_episode"])])
		# I's running work, shaped exactly as its own production site leaves it.
		if g9m == "quick_claw":
			g9a["recovery_end"] = 22
			g9a["action"] = {"action": 41, "actor": 0, "life": 1, "request": 5, "intent": 1,
				"owning_family": g9_fam, "episode": 2, "skill": "quick_claw", "target": 1,
				"target_kind": 2, "start_tick": 1, "due_tick": 1, "recovery_ticks": g9_rec,
				"paid_cost": 600, "cooldown_end": 73, "stability": 1, "interrupt_power": 1,
				"state": "recovering", "cancel_cause": "", "plan": {}}
		elif g9m == "brace":
			g9a["brace_action"] = 41
			g9a["brace_start"] = 0
			g9a["brace_end"] = 5
		else:
			# Authored Bound minimum 200: the declared total must equal the real route length and
			# stay inside the authored 200..2400 budget. The old fixture declared 100.
			var g9_path := [[4000.0, 3000.0], [4200.0, 3000.0]]
			g9a["bound_path"] = g9_path
			g9a["bound_total"] = arena.route_length(g9_path)
			g9a["bound_progress"] = 0.0
			g9a["bound_action"] = 41
			g9a["bound_active"] = true
			if absf(float(g9a["bound_total"]) - 200.0) > 1e-6 \
					or float(g9a["bound_total"]) < 200.0 \
					or float(g9a["bound_total"]) > 2400.0 + 1e-6:
				g9_bad.append("Bound route/total %.6f != authored 200 within [200,2400]" %
					float(g9a["bound_total"]))
		# ARCH-PLAY01-R03-F03: an action record's owning_family is its accepted intent's family,
		# so an Attack-owned Quick record can never claim Defense family 2.
		if g9a["action"] is Dictionary \
				and int((g9a["action"] as Dictionary).get("owning_family", -1)) != g9_fam:
			g9_bad.append("%s action owning_family %d != owning intent family %d" % [g9m,
				int((g9a["action"] as Dictionary).get("owning_family", -1)), g9_fam])
		var g9_j := {"episode": 4, "target_kind": 0, "target_or_area": null, "class": 6,
			"original_family": g9_fam, "latest_request": 9, "observation_category": g9_cat,
			"draw_resolved": false}
		g9._accept_intent(g9a, g9_j, g9_fam)
		var g9_exp := -1
		var g9_jid := -1
		if g9a["accepted_intent"] is Dictionary:
			var g9acc := g9a["accepted_intent"] as Dictionary
			g9_exp = int(g9acc.get("expiry_tick", -1))
			g9_jid = int(g9acc.get("intent", -1))
		if g9_jid != 2 or g9_exp != g9.tick + g9_life or int(g9a["cycle_intent"]) != 1 \
				or int(g9a["cycle_request"]) != 5 or int(g9a["cycle_episode"]) != 2 \
				or int(g9a["recovery_owner"]) != 1:
			g9_bad.append("%s J accept id=%d expiry=%d cycle=%d/%d/%d owner=%d != 2/%d/1/5/2/1" % [
				g9m, g9_jid, g9_exp, int(g9a["cycle_intent"]),
				int(g9a["cycle_request"]), int(g9a["cycle_episode"]),
				int(g9a["recovery_owner"]), g9.tick + g9_life])
		# I's actual completion site for this work.
		if g9m == "quick_claw":
			_mtick(g9, 22)
			g9._expire_intervals(g9a)
		elif g9m == "brace":
			_mtick(g9, 5)
			g9._expire_intervals(g9a)
			if int(g9a["brace_action"]) != -1 or int(g9a["recovery_end"]) != 5 + g9_rec \
					or int(g9a["cycle_intent"]) != 1 or int(g9a["recovery_owner"]) != 1:
				g9_bad.append("brace hold expiry brace=%d rec=%d cycle=%d owner=%d != -1/%d/1/1" % [
					int(g9a["brace_action"]), int(g9a["recovery_end"]),
					int(g9a["cycle_intent"]), int(g9a["recovery_owner"]), 5 + g9_rec])
			_mtick(g9, 5 + g9_rec)
			g9._expire_intervals(g9a)
		else:
			g9._movement_cut()
			if bool(g9a["bound_active"]) or int(g9a["recovery_end"]) != 1 + g9_rec \
					or int(g9a["cycle_intent"]) != 1 or int(g9a["recovery_owner"]) != 1:
				g9_bad.append("bound arrival active=%s rec=%d cycle=%d owner=%d != false/%d/1/1" % [
					str(bool(g9a["bound_active"])), int(g9a["recovery_end"]),
					int(g9a["cycle_intent"]), int(g9a["recovery_owner"]), 1 + g9_rec])
			_mtick(g9, 1 + g9_rec)
			g9._expire_intervals(g9a)
		# Only I's owner slot retired; J still holds the expiry acceptance gave it.
		var g9_jid2 := -1
		var g9_exp2 := -1
		if g9a["accepted_intent"] is Dictionary:
			var g9acc2 := g9a["accepted_intent"] as Dictionary
			g9_jid2 = int(g9acc2.get("intent", -1))
			g9_exp2 = int(g9acc2.get("expiry_tick", -1))
		if int(g9a["cycle_intent"]) != -1 or int(g9a["cycle_request"]) != 0 \
				or int(g9a["cycle_episode"]) != 0 or int(g9a["recovery_owner"]) != -1:
			g9_bad.append("%s retirement cycle %d/%d/%d owner %d != -1/0/0/-1" % [
				g9m, int(g9a["cycle_intent"]), int(g9a["cycle_request"]),
				int(g9a["cycle_episode"]), int(g9a["recovery_owner"])])
		if g9_jid2 != 2 or g9_exp2 != g9_exp:
			g9_bad.append("%s newer waiting J became intent%d expiry%d != 2/%d" % [
				g9m, g9_jid2, g9_exp2, g9_exp])
	# ARCH-PLAY01-R03-F01 — expiry must NOT discard an unfinished cycle's captured ownership.
	# The cited sequence: accepted I4/request5/episode2 owns a paid Defense-owned Brace started
	# at 475 (due 475+27=502, cooldown 475+180=655); the intent expires at 480 while the charge
	# is still preparing; an understood Attack J7 arrives at 481 and is lawfully cancelled below
	# the 0.75 threshold (elapsed 6/27), arming recovery 481+15=496 from the ACTION owner; only
	# I's real recovery completion may retire I, and J keeps the expiry acceptance gave it.
	var g9x := _new_sim(3101, "diagnostic")
	var g9xa: Dictionary = g9x.actors[0]
	g9xa["x"] = 4000.0
	g9xa["y"] = 3000.0
	g9x.actors[1]["x"] = 16000.0
	g9x.actors[1]["y"] = 9000.0
	g9xa["stam"] = 5200
	g9xa["int_stat"] = 100
	g9xa["response_episode"] = null
	_mtick(g9x, 0)
	# Fixture id allocation standing in for the earlier intents the citation assumes; the counter
	# yields its current value as the new id, so 4 gives I4 and 7 gives J7.
	g9x.id_counter["intent"] = 4
	var g9x_i := {"episode": 2, "target_kind": 1, "target_or_area": null, "class": 6,
		"original_family": 2, "latest_request": 5, "observation_category": "defense",
		"draw_resolved": false}
	g9x._accept_intent(g9xa, g9x_i, 2)
	g9x._capture_cycle_owner(g9xa)
	g9xa["recovery_owner"] = int(g9xa["cycle_intent"])
	var g9x_own := int(g9xa["cycle_intent"])
	if g9x_own != 4 or int(g9xa["cycle_request"]) != 5 or int(g9xa["cycle_episode"]) != 2:
		g9_bad.append("cited-case owner capture %d/%d/%d != 4/5/2" % [g9x_own,
			int(g9xa["cycle_request"]), int(g9xa["cycle_episode"])])
	var g9x_rec := int(content.recovery_ticks("brace"))
	if int(content.charge_ticks("brace")) != 27 or int(content.cooldown_ticks("brace")) != 180 \
			or g9x_rec != 15:
		g9_bad.append("frozen Brace charge/cd/rec %d/%d/%d != 27/180/15" % [
			int(content.charge_ticks("brace")), int(content.cooldown_ticks("brace")), g9x_rec])
	_mtick(g9x, 475)
	g9xa["action"] = {"action": 61, "actor": 0, "life": 1, "request": 5, "intent": g9x_own,
		"owning_family": 2, "episode": 2, "skill": "brace", "target": null, "target_kind": 1,
		"start_tick": 475, "due_tick": 502, "recovery_ticks": g9x_rec, "paid_cost": 800,
		"cooldown_end": 655, "stability": 1, "interrupt_power": 0, "state": "preparing",
		"cancel_cause": "", "plan": {}}
	g9xa["cooldown_end"]["brace"] = 655
	g9xa["brace_prepare_action"] = 61
	if int((g9xa["action"] as Dictionary)["due_tick"]) != 475 + 27 \
			or int(g9xa["cooldown_end"]["brace"]) != 475 + 180:
		g9_bad.append("cited-case due/cd %d/%d != 502/655" % [
			int((g9xa["action"] as Dictionary)["due_tick"]),
			int(g9xa["cooldown_end"]["brace"])])
	_mtick(g9x, 480)
	g9x._expire_intervals(g9xa)
	if g9xa["accepted_intent"] != null:
		g9_bad.append("expiry480 left the accepted intent alive")
	if int(g9xa["cycle_intent"]) != g9x_own or int(g9xa["cycle_request"]) != 5 \
			or int(g9xa["cycle_episode"]) != 2 or int(g9xa["recovery_owner"]) != g9x_own:
		g9_bad.append("expiry480 erased unfinished ownership: cycle %d/%d/%d owner %d != %d/5/2/%d" % [
			int(g9xa["cycle_intent"]), int(g9xa["cycle_request"]), int(g9xa["cycle_episode"]),
			int(g9xa["recovery_owner"]), g9x_own, g9x_own])
	if g9xa["action"] == null or str((g9xa["action"] as Dictionary).get("state", "")) != "preparing" \
			or int(g9xa["cooldown_end"]["brace"]) != 655 or not g9x._cycle_pending(g9xa):
		g9_bad.append("expiry480 dropped the paid charge: action=%s state=%s cd=%d pending=%s" % [
			str(g9xa["action"] != null),
			str((g9xa["action"] as Dictionary).get("state", "")) if g9xa["action"] is Dictionary else "none",
			int(g9xa["cooldown_end"]["brace"]), str(g9x._cycle_pending(g9xa))])
	g9x._capture_cycle_owner(g9xa)
	if int(g9xa["cycle_intent"]) != g9x_own:
		g9_bad.append("capture after expiry replaced unfinished I%d with %d" % [
			g9x_own, int(g9xa["cycle_intent"])])
	# Lawful incompatible Attack at 481: the guard must pass (6/27 < 0.75) and the understood
	# acceptance must cancel below threshold, arming recovery from the ACTION's own owner.
	_mtick(g9x, 481)
	g9x._refresh_gates(g9xa)
	var g9x_guard := g9x._conflict_guard(g9xa, 1, 0)
	if g9x_guard != "":
		g9_bad.append("cited-case conflict guard %s != \"\" at elapsed 6/27" % g9x_guard)
	g9x.id_counter["intent"] = 7
	var g9x_j := {"episode": 4, "target_kind": 0, "target_or_area": null, "class": 6,
		"original_family": 1, "latest_request": 9, "observation_category": "attack",
		"draw_resolved": false}
	g9x._accept_intent(g9xa, g9x_j, 1)
	var g9x_c10: Array = _events_of_type(g9x, 10)
	var g9x_jid := -1
	var g9x_jexp := -1
	var g9x_jfam := -1
	var g9x_jreq := -1
	if g9xa["accepted_intent"] is Dictionary:
		var g9xj := g9xa["accepted_intent"] as Dictionary
		g9x_jid = int(g9xj.get("intent", -1))
		g9x_jexp = int(g9xj.get("expiry_tick", -1))
		g9x_jfam = int(g9xj.get("family", -1))
		g9x_jreq = int(g9xj.get("request", -1))
	if g9x_c10.size() != 1 or int((g9x_c10[0][3] as Array)[0]) != 61 \
			or str((g9x_c10[0][3] as Array)[3]) != "intent_change":
		g9_bad.append("cited-case CANCEL rows=%d aid/reason %s/%s != 1/61/intent_change" % [
			g9x_c10.size(),
			str((g9x_c10[0][3] as Array)[0]) if not g9x_c10.is_empty() else "none",
			str((g9x_c10[0][3] as Array)[3]) if not g9x_c10.is_empty() else "none"])
	if g9xa["action"] != null or int(g9xa["recovery_end"]) != 496 \
			or int(g9xa["recovery_owner"]) != g9x_own or not g9x._cycle_pending(g9xa):
		g9_bad.append("cancel481 action=%s rec=%d owner=%d pending=%s != null/496/%d/true" % [
			str(g9xa["action"] != null), int(g9xa["recovery_end"]),
			int(g9xa["recovery_owner"]), str(g9x._cycle_pending(g9xa)), g9x_own])
	if int(g9xa["cycle_intent"]) != g9x_own or int(g9xa["cycle_request"]) != 5 \
			or int(g9xa["cycle_episode"]) != 2:
		g9_bad.append("cancel481 let J recapture the slot: cycle %d/%d/%d != %d/5/2" % [
			int(g9xa["cycle_intent"]), int(g9xa["cycle_request"]),
			int(g9xa["cycle_episode"]), g9x_own])
	if g9x_jid != 7 or g9x_jfam != 1 or g9x_jreq != 9 or g9x_jexp != 481 + 480:
		g9_bad.append("cancel481 waiting J id/family/request/expiry %d/%d/%d/%d != 7/1/9/961" % [
			g9x_jid, g9x_jfam, g9x_jreq, g9x_jexp])
	if int(g9xa["cooldown_end"]["brace"]) != 655 or int(g9xa["stam"]) != 5200:
		g9_bad.append("cancel481 refunded paid cost/cd: stam/cd %d/%d != 5200/655" % [
			int(g9xa["stam"]), int(g9xa["cooldown_end"]["brace"])])
	_mtick(g9x, 496)
	g9x._expire_intervals(g9xa)
	if int(g9xa["cycle_intent"]) != -1 or int(g9xa["cycle_request"]) != 0 \
			or int(g9xa["cycle_episode"]) != 0 or int(g9xa["recovery_owner"]) != -1:
		g9_bad.append("recovery496 did not retire I: cycle %d/%d/%d owner %d != -1/0/0/-1" % [
			int(g9xa["cycle_intent"]), int(g9xa["cycle_request"]),
			int(g9xa["cycle_episode"]), int(g9xa["recovery_owner"])])
	var g9x_jid2 := -1
	var g9x_jexp2 := -1
	if g9xa["accepted_intent"] is Dictionary:
		g9x_jid2 = int((g9xa["accepted_intent"] as Dictionary).get("intent", -1))
		g9x_jexp2 = int((g9xa["accepted_intent"] as Dictionary).get("expiry_tick", -1))
	if g9x_jid2 != 7 or g9x_jexp2 != 961:
		g9_bad.append("I's completion retired waiting J: id/expiry %d/%d != 7/961" % [
			g9x_jid2, g9x_jexp2])
	_mtick(g9x, 961)
	g9x._expire_intervals(g9xa)
	if g9xa["accepted_intent"] != null:
		g9_bad.append("J's own expiry961 did not fire after I completed")
	if int(g9xa["cycle_intent"]) != -1:
		g9_bad.append("J's expiry mutated the retired cycle slot")
	# Expiry during COMMITTED travel / Brace hold / pending recovery, each driven through real
	# completion while a newer J waits behind it.
	for g9w in ["travel", "hold", "recovery"]:
		var g9z := _new_sim(3101, "diagnostic")
		var g9za: Dictionary = g9z.actors[0]
		g9za["x"] = 4000.0
		g9za["y"] = 3000.0
		g9z.actors[1]["x"] = 16000.0
		g9z.actors[1]["y"] = 9000.0
		g9za["stam"] = 6000
		g9za["response_episode"] = null
		_mtick(g9z, 0)
		var g9z_i := {"episode": 2, "target_kind": 0, "target_or_area": null, "class": 6,
			"original_family": 2, "latest_request": 5, "observation_category": "defense",
			"draw_resolved": false}
		g9z._accept_intent(g9za, g9z_i, 2)
		g9z._capture_cycle_owner(g9za)
		g9za["recovery_owner"] = int(g9za["cycle_intent"])
		var g9z_own := int(g9za["cycle_intent"])
		if g9w == "travel":
			var g9z_path := [[4000.0, 3000.0], [6400.0, 3000.0]]
			g9za["bound_path"] = g9z_path
			g9za["bound_total"] = arena.route_length(g9z_path)
			g9za["bound_progress"] = 0.0
			g9za["bound_action"] = 71
			g9za["bound_active"] = true
		elif g9w == "hold":
			g9za["brace_action"] = 71
			g9za["brace_start"] = 479
			g9za["brace_end"] = 552
		else:
			g9za["recovery_end"] = 500
		_mtick(g9z, 480)
		g9z._expire_intervals(g9za)
		if g9za["accepted_intent"] != null or int(g9za["cycle_intent"]) != g9z_own \
				or int(g9za["cycle_request"]) != 5 or int(g9za["cycle_episode"]) != 2 \
				or int(g9za["recovery_owner"]) != g9z_own or not g9z._cycle_pending(g9za):
			g9_bad.append("%s expiry480 erased unfinished ownership: accepted=%s cycle %d/%d/%d owner %d pending=%s" % [
				g9w, str(g9za["accepted_intent"] != null), int(g9za["cycle_intent"]),
				int(g9za["cycle_request"]), int(g9za["cycle_episode"]),
				int(g9za["recovery_owner"]), str(g9z._cycle_pending(g9za))])
		g9z._capture_cycle_owner(g9za)
		if int(g9za["cycle_intent"]) != g9z_own:
			g9_bad.append("%s capture after expiry replaced unfinished I%d with %d" % [
				g9w, g9z_own, int(g9za["cycle_intent"])])
		var g9z_j := {"episode": 4, "target_kind": 0, "target_or_area": null, "class": 6,
			"original_family": 2, "latest_request": 9, "observation_category": "defense",
			"draw_resolved": false}
		g9z._accept_intent(g9za, g9z_j, 2)
		if int(g9za["cycle_intent"]) != g9z_own or int(g9za["cycle_request"]) != 5 \
				or int(g9za["cycle_episode"]) != 2 or g9za["accepted_intent"] == null \
				or int((g9za["accepted_intent"] as Dictionary).get("expiry_tick", -1)) != 960:
			g9_bad.append("%s J accept overwrote unfinished I: cycle %d/%d/%d jexp %s" % [
				g9w, int(g9za["cycle_intent"]), int(g9za["cycle_request"]),
				int(g9za["cycle_episode"]),
				str((g9za["accepted_intent"] as Dictionary).get("expiry_tick", -1)) if g9za["accepted_intent"] is Dictionary else "none"])
		if g9w == "travel":
			var g9z_guard := 0
			while bool(g9za["bound_active"]) and g9z_guard < 40:
				_mtick(g9z, g9z.tick + 1)
				g9z._expire_intervals(g9za)
				g9z._movement_cut()
				g9z_guard += 1
			if bool(g9za["bound_active"]):
				g9_bad.append("travel never reached arrival within 40 boundaries")
		if g9w == "hold":
			_mtick(g9z, int(g9za["brace_end"]))
			g9z._expire_intervals(g9za)
			if int(g9za["brace_action"]) != -1 or int(g9za["cycle_intent"]) != g9z_own:
				g9_bad.append("hold expiry brace=%d cycle=%d != -1/%d" % [
					int(g9za["brace_action"]), int(g9za["cycle_intent"]), g9z_own])
		_mtick(g9z, int(g9za["recovery_end"]))
		g9z._expire_intervals(g9za)
		if int(g9za["cycle_intent"]) != -1 or int(g9za["cycle_request"]) != 0 \
				or int(g9za["cycle_episode"]) != 0 or int(g9za["recovery_owner"]) != -1:
			g9_bad.append("%s completion did not retire I: cycle %d/%d/%d owner %d != -1/0/0/-1" % [
				g9w, int(g9za["cycle_intent"]), int(g9za["cycle_request"]),
				int(g9za["cycle_episode"]), int(g9za["recovery_owner"])])
		var g9z_jid2 := -1
		var g9z_jexp2 := -1
		if g9za["accepted_intent"] is Dictionary:
			g9z_jid2 = int((g9za["accepted_intent"] as Dictionary).get("intent", -1))
			g9z_jexp2 = int((g9za["accepted_intent"] as Dictionary).get("expiry_tick", -1))
		if g9z_jid2 < 1 or g9z_jexp2 != 960:
			g9_bad.append("%s waiting J lost through I's completion: id/expiry %d/%d != >=1/960" % [
				g9w, g9z_jid2, g9z_jexp2])
	# Actor-side rest progress: captured into the checkpoint, incremented only while genuinely
	# idle, reset while an active goal exists, and completing the owner's cycle at the frozen
	# threshold.
	var g9d := _new_sim(3101, "diagnostic")
	var g9da: Dictionary = g9d.actors[0]
	g9da["x"] = 4000.0
	g9da["y"] = 3000.0
	g9da["stam"] = 6000
	var g9d_ep := {"episode": 6, "target_kind": 0, "target_or_area": null, "class": 6,
		"original_family": 2, "latest_request": 11, "observation_category": "defense",
		"draw_resolved": false}
	g9d._accept_intent(g9da, g9d_ep, 2)
	g9d._capture_cycle_owner(g9da)
	var g9d_own := int(g9da["cycle_intent"])
	var g9d_exp := int((g9da["accepted_intent"] as Dictionary)["expiry_tick"])
	if g9d_own < 1 or g9d_exp != g9d.tick + g9_life or int(g9da["cycle_request"]) != 11:
		g9_bad.append("rest owner capture intent=%d expiry=%d request=%d != >=1/%d/11" % [
			g9d_own, g9d_exp, int(g9da["cycle_request"]), g9d.tick + g9_life])
	g9da["goal"] = {"kind": "move", "point": [4100.0, 3000.0],
		"route": [[4000.0, 3000.0], [4100.0, 3000.0]], "stop_mwu": 0.0,
		"purpose": "approach", "patrol_index": -1, "i": 0}
	for g9i in 3:
		g9d._count_rest_idle(g9da)
	if int(g9da["rest_idle_ticks"]) != 0:
		g9_bad.append("moving goal still accumulated rest_idle_ticks=%d" % int(g9da["rest_idle_ticks"]))
	g9da["goal"] = null
	for g9i in 30:
		g9d._count_rest_idle(g9da)
	if int(g9da["rest_idle_ticks"]) != 30 or int(g9da["cycle_intent"]) != g9d_own:
		g9_bad.append("30 idle ticks rest=%d cycle=%d != %d/%d" % [
			int(g9da["rest_idle_ticks"]), int(g9da["cycle_intent"]), 30, g9d_own])
	var g9d_done := -1
	for g9i in 90:
		g9d._count_rest_idle(g9da)
		if int(g9da["cycle_intent"]) == -1:
			g9d_done = 30 + g9i + 1
			break
	if g9d_done != 60:
		g9_bad.append("rest cycle completed after %d idle ticks != 60" % g9d_done)
	if int(g9da["rest_idle_ticks"]) != 0 or g9da["accepted_intent"] != null:
		g9_bad.append("rest completion left rest=%d accepted=%s != 0/null" % [
			int(g9da["rest_idle_ticks"]), str(g9da["accepted_intent"])])
	var g9d_row: Dictionary = (g9d.canonical_state()["actors"] as Array)[0]
	for g9d_k in ["cycle_intent", "cycle_request", "cycle_episode", "recovery_owner",
			"rest_idle_ticks"]:
		if not g9d_row.has(g9d_k):
			g9_bad.append("canonical_state() actor row is missing %s" % g9d_k)
	_record("C57-owning-intent-retirement", g9_bad.is_empty(),
		"Attack-owned Quick rec22, Defense-owned Brace hold@5 then rec20 and a legal authored-200 Bound arrival rec13 each retire cycle -1/0/0 and owner -1 while J keeps intent2/expiry481; cited expiry480 keeps I4/5/2 and the paid charge live, the 481 cancellation arms recovery496 from the ACTION owner while J7 waits with expiry961, only recovery496 retires I and J survives the same way through committed travel, Brace hold and pending recovery; rest idles 0->30 keeps cycle, completes at 60, resets with an active goal; owner/rest exposed by canonical_state()"
			if g9_bad.is_empty() else "; ".join(g9_bad))

func _case_c58() -> void:
	# C58 FIX02/G3 — request1 -> same-key repeat2 -> changed-key request3 issues episode2. The
	# genuine request ID and the episode ID stay separate all the way to RESPONSE, PLAN and the
	# ACTION_START oracle; episode3 is never issued and request2 is never started.
	var g10_bad: Array = []
	var g10 := _new_sim(3101, "diagnostic")
	g10.actors[0]["x"] = 4000.0
	g10.actors[0]["y"] = 3000.0
	g10.actors[1]["x"] = 5000.0
	g10.actors[1]["y"] = 3000.0
	g10.actors[1]["hp"] = 6000
	g10.actors[1]["control_mode"] = 1
	g10.actors[0]["enemy_visible"] = true
	g10.actors[0]["int_stat"] = 100
	g10.actors[0]["stam"] = int(g10.actors[0]["stam_max"])
	g10.actors[0]["cooldown_end"]["short_bound"] = 999999
	g10.forced_uniforms["response.0"] = [0.99, 0.99]
	_stage(g10, 0, 2, 1, 1)
	_stage(g10, 0, 2, 2, 2)
	_stage(g10, 0, 2, 3, 3, 3, [5000.0, 3000.0])
	# 40 boundaries: the three REQUESTs mature at ticks 2/3/4, the single RESPONSE is expected
	# at tick 17 (hand-derived expectation, not a passed timing measurement) and the
	# trainer-attributed START follows as soon as Quick recovery ends (tick 22 for a Quick
	# started at 1 — QA-PLAY01-R03 factual correction, was mis-stated as 21 — no later than the
	# 15-tick plan interval at 32) — before the accepted intent can lawfully retire through a
	# fallback goal at the end of Brace recovery.
	for g10i in 40:
		_pstep(g10)
	var g10_e1: Array = []
	for g10row in _events_of_type(g10, 1):
		if int((g10row[3] as Array)[2]) == 0:
			g10_e1.append(g10row)
	if g10_e1.size() != 3:
		g10_bad.append("REQUEST rows for actor0 = %d != 3" % g10_e1.size())
	else:
		for g10k in 3:
			var g10p: Array = (g10_e1[g10k][3] as Array)
			var g10_kind := 3 if g10k == 2 else 0
			if int(g10p[0]) != g10k + 1 or int(g10p[3]) != g10k + 1 \
					or int(g10p[6]) != g10_kind:
				g10_bad.append("REQUEST[%d] id=%d seq=%d kind=%d != %d/%d/%d" % [
					g10k, int(g10p[0]), int(g10p[3]), int(g10p[6]),
					g10k + 1, g10k + 1, g10_kind])
	var g10_e4: Array = []
	for g10row in _events_of_type(g10, 4):
		if int((g10row[3] as Array)[0]) == 0:
			g10_e4.append(g10row)
	var g10_e4_req := [1, 2, 3]
	var g10_e4_ep := [1, 1, 2]
	var g10_e4_why := ["issue", "credited_repeat", "issue"]
	if g10_e4.size() != 3:
		g10_bad.append("RESPONSE-issue rows for actor0 = %d != 3" % g10_e4.size())
	else:
		for g10k in 3:
			var g10p4: Array = (g10_e4[g10k][3] as Array)
			if int(g10p4[1]) != g10_e4_req[g10k] or int(g10p4[2]) != g10_e4_ep[g10k] \
					or str(g10p4[6]) != g10_e4_why[g10k]:
				g10_bad.append("event4[%d] req/ep/why = %d/%d/%s != %d/%d/%s" % [
					g10k, int(g10p4[1]), int(g10p4[2]), str(g10p4[6]),
					g10_e4_req[g10k], g10_e4_ep[g10k], g10_e4_why[g10k]])
	for g10row in _events_of_type(g10, 4):
		if int((g10row[3] as Array)[2]) > 2:
			g10_bad.append("episode id %d was issued, the chain never reaches episode 3" %
				int((g10row[3] as Array)[2]))
	var g10_e3: Array = _events_of_type(g10, 3)
	if g10_e3.size() != 1:
		g10_bad.append("RESPONSE rows = %d != 1" % g10_e3.size())
	else:
		var g10p3: Array = (g10_e3[0][3] as Array)
		if int(g10p3[0]) != 3 or int(g10p3[2]) != 2:
			g10_bad.append("RESPONSE rid/episode = %d/%d != 3/2 (divergence)" % [
				int(g10p3[0]), int(g10p3[2])])
		if int(g10p3[0]) == int(g10p3[2]):
			g10_bad.append("RESPONSE rid == episode, the two IDs were merged")
		if int(g10p3[4]) != 6 or int(g10p3[5]) != 2 or int(g10p3[6]) != 2:
			g10_bad.append("RESPONSE class/original/interpreted = %d/%d/%d != 6/2/2" % [
				int(g10p3[4]), int(g10p3[5]), int(g10p3[6])])
	var g10_starts: Array = []
	for g10row in _events_of_type(g10, 6):
		if int((g10row[3] as Array)[3]) != 0:
			g10_starts.append(g10row)
	if g10_starts.is_empty():
		g10_bad.append("no ACTION_START carries a trainer request")
	else:
		for g10row in g10_starts:
			var g10p6: Array = (g10row[3] as Array)
			if int(g10p6[3]) == 2:
				g10_bad.append("ACTION_START carried the repeat request 2 instead of request 3")
			elif int(g10p6[3]) != 3:
				g10_bad.append("ACTION_START carried request %d != 3" % int(g10p6[3]))
	var g10_acc: Variant = g10.actors[0]["accepted_intent"]
	if not (g10_acc is Dictionary):
		g10_bad.append("no accepted intent survived the three-request chain")
	else:
		var g10a2 := g10_acc as Dictionary
		if int(g10a2.get("request", -1)) != 3 or int(g10a2.get("episode", -1)) != 2:
			g10_bad.append("accepted request/episode = %d/%d != 3/2" % [
				int(g10a2.get("request", -1)), int(g10a2.get("episode", -1))])
		if int(g10a2.get("request", -1)) == int(g10a2.get("episode", -1)):
			g10_bad.append("accepted request == episode, the two IDs were merged")
	_record("C58-request-episode-divergence", g10_bad.is_empty(),
		"REQUEST ids 1/2/3 kinds 0/0/3, event4 issue/credited_repeat/issue with ep 1/1/2, RESPONSE rid3 episode2 class6, STARTs request3 never 2, accepted 3/2, no episode3"
			if g10_bad.is_empty() else "; ".join(g10_bad))

func _case_c59() -> void:
	# C59 FIX02/G4 / QA-PLAY01-R03-F01 — Quick 599/600/601 with the start supplied INSIDE a
	# normal step() by lawful autonomy, landing on the frozen damage total 1440 against an
	# unbraced ATK100/DEF25 target. 599 is below the authored cost: no start, no debit and no
	# new cooldown, although ordinary regeneration on its own boundary is lawful. 600 pays to 0,
	# raises the own-start exhaustion exception (Quick charges 0 so it still commits) and 601
	# pays to 1 with no lock. START, due, COMMIT and DAMAGE all land on the SAME boundary b —
	# there is no START+1 production rule.
	var g11_bad: Array = []
	var g11_sk := content.skill("quick_claw")
	var g11_base := int(g11_sk["base_power_cp"])
	var g11_cost := int(g11_sk["stam_cost_cp"])
	var g11_cdt := int(content.cooldown_ticks("quick_claw"))
	var g11_rect := int(content.recovery_ticks("quick_claw"))
	if g11_base != 1800 or g11_cost != 600 or g11_cdt != 72 or g11_rect != 21 \
			or content.charge_ticks("quick_claw") != 0:
		g11_bad.append("frozen Quick base/cost/cd/rec/charge %d/%d/%d/%d/%d != 1800/600/72/21/0" % [
			g11_base, g11_cost, g11_cdt, g11_rect, content.charge_ticks("quick_claw")])
	for g11s in [599, 600, 601]:
		var g11 := _new_sim(3101, "diagnostic")
		var g11a: Dictionary = g11.actors[0]
		var g11f: Dictionary = g11.actors[1]
		g11a["x"] = 4000.0
		g11a["y"] = 3000.0
		g11f["x"] = 5000.0
		g11f["y"] = 3000.0
		g11f["control_mode"] = 1
		g11a["enemy_visible"] = true
		g11a["stam"] = g11s
		var g11_atk := int(g11a["atk"])
		var g11_tdef := int(g11f["def"])
		var g11_k := int(g11f["k_defense"])
		var g11_expect := int(floor(float(g11_base) * float(g11_atk) / 100.0
				* float(g11_k) / float(g11_k + maxi(0, g11_tdef)) + 0.5))
		if g11_atk != 100 or g11_tdef != 25 or g11_k != 100 or g11_expect != 1440:
			g11_bad.append("stam%d ATK/DEF/k/damage = %d/%d/%d/%d != 100/25/100/1440" % [
				g11s, g11_atk, g11_tdef, g11_k, g11_expect])
		var g11_hp0 := int(g11f["hp"])
		var g11_cd0 := int(g11a["cooldown_end"]["quick_claw"])
		g11._refresh_gates(g11a)
		# Sample affordability BEFORE the boundary: ordinary regeneration inside that boundary
		# can lift 599 above the cost afterwards, and the requirement is "no debit", not
		# "permanently unaffordable".
		var g11_aff0 := bool(g11a["affordable"].get("quick_claw", false))
		# QA-PLAY01-R03-F01: the previous version called _try_start directly outside step(), so
		# _tick_start reset started_technique on the following boundary and the commit fell at
		# start+1 — that artificial call sequence, not the production rule. Autonomy now supplies
		# the start on cut2 of a real boundary (visible peer in range, no accepted intent, and a
		# single-candidate pool so no selector draw is fabricated).
		_pstep(g11)
		var g11_b := g11.tick
		var g11_e6: Array = _events_of_type(g11, 6)
		var g11_e7: Array = _events_of_type(g11, 7)
		if g11s == 599:
			if g11_aff0:
				g11_bad.append("stam599 still reports quick_claw affordable before its boundary")
			if g11a["action"] != null or not g11_e6.is_empty() or not g11_e7.is_empty() \
					or int(g11a["cooldown_end"]["quick_claw"]) != g11_cd0:
				g11_bad.append("stam599 action=%s start=%d cost=%d cd=%d != no mutation" % [
					str(g11a["action"] != null), g11_e6.size(), g11_e7.size(),
					int(g11a["cooldown_end"]["quick_claw"])])
			# Ordinary regeneration on 599's own boundary is LAWFUL; the requirement is "no
			# debit", not "stamina frozen". A debit is the failure.
			if int(g11a["stam"]) < g11s:
				g11_bad.append("stam599 was debited to %d on its own boundary" % int(g11a["stam"]))
			var g11_c9: Array = []
			var g11_c12 := 0
			for g11row in _events_of_type(g11, 9):
				if int((g11row[3] as Array)[1]) == 0:
					g11_c9.append(g11row)
			for g11row in _events_of_type(g11, 12):
				if int((g11row[3] as Array)[1]) == 1:
					g11_c12 += 1
			if not g11_c9.is_empty() or g11_c12 != 0 \
					or not _events_of_type(g11, 25).is_empty():
				g11_bad.append("stam599 commit=%d damage=%d lock rows=%d != all absent" % [
					g11_c9.size(), g11_c12, _events_of_type(g11, 25).size()])
			continue
		if g11a["action"] == null or g11_e6.is_empty() or g11_e7.is_empty():
			g11_bad.append("stam%d did not start inside step: action=%s start=%d cost=%d" % [
				g11s, str(g11a["action"] != null), g11_e6.size(), g11_e7.size()])
			continue
		var g11_p6: Array = (g11_e6[0][3] as Array)
		var g11_p7: Array = (g11_e7[0][3] as Array)
		var g11_aid := int(g11_p6[0])
		# QA-PLAY01-R05-F03: raw telemetry row[0] is a DELTA (tick - last_tick), not an absolute
		# boundary; only `_events_with_tick` accumulates every delta and yields [absolute_tick,
		# payload]. PLAN5 is emitted on boundary 1 immediately before START6 on that same
		# boundary, so START's raw delta is 0 and legal — reading it as tick 0 would send every
		# downstream due/cooldown/COMMIT comparison to 0. Take START's absolute time from the
		# normalized row correlated to this same actor and action; the raw payload rows above and
		# below stay in their existing shape.
		var g11_w6: Array = _events_with_tick(g11, 6)
		var g11_start := -1
		for g11row in g11_w6:
			if int((g11row[1] as Array)[0]) == g11_aid and int((g11row[1] as Array)[1]) == 0:
				g11_start = int(g11row[0])
				break
		if g11_start < 0:
			g11_bad.append("stam%d has no normalized START row for aid %d actor0" % [
				g11s, g11_aid])
			continue
		if g11_start != g11_b:
			g11_bad.append("stam%d START landed on tick %d, not the stepped boundary %d" % [
				g11s, g11_start, g11_b])
		# Same-boundary PLAN -> START ordering on absolute ticks: this is what makes the legal
		# raw START delta of 0 harmless rather than load-bearing.
		var g11_w5: Array = _events_with_tick(g11, 5)
		if g11_w5.size() != 1 or int(g11_w5[0][0]) != g11_start:
			g11_bad.append("stam%d PLAN rows/tick %d/%d != 1/%d (same-boundary PLAN->START)" % [
				g11s, g11_w5.size(),
				int(g11_w5[0][0]) if not g11_w5.is_empty() else -1, g11_start])
		if int(g11_p6[3]) != 0 or int(g11_p6[6]) != g11_start \
				or int(g11_p7[0]) != g11_aid or int(g11_p7[1]) != 0 \
				or int(g11_p7[2]) != g11_cost or int(g11_p7[3]) != g11s - g11_cost \
				or int(g11_p7[4]) != g11_start + g11_cdt:
			g11_bad.append("stam%d START/COST req=%d due=%d actor=%d aid=%d cost=%d after=%d cd=%d != 0/%d/0/%d/%d/%d/%d" % [
				g11s, int(g11_p6[3]), int(g11_p6[6]), int(g11_p7[1]), int(g11_p7[0]),
				int(g11_p7[2]), int(g11_p7[3]), int(g11_p7[4]), g11_start, g11_aid,
				g11_cost, g11s - g11_cost, g11_start + g11_cdt])
		# Post-cut6 stamina: the start boundary publishes bands and skips _apply_resource_row, so
		# the sampled balance equals the payment remainder — 0 for 600, 1 for 601.
		if int(g11a["stam"]) != g11s - g11_cost:
			g11_bad.append("stam%d post-cut6 stamina %d != remainder %d" % [
				g11s, int(g11a["stam"]), g11s - g11_cost])
		var g11_e25: Array = _events_of_type(g11, 25)
		var g11_expect25 := 1 if g11s == 600 else 0
		if g11_e25.size() != g11_expect25:
			g11_bad.append("stam%d start-exhaustion lock rows=%d != %d" % [
				g11s, g11_e25.size(), g11_expect25])
		if g11s == 600 and not g11_e25.is_empty():
			if int((g11_e25[0][3] as Array)[0]) != 0 \
					or str((g11_e25[0][3] as Array)[1]) != "entry":
				g11_bad.append("stam600 lock row actor/reason %s/%s != 0/entry" % [
					str((g11_e25[0][3] as Array)[0]), str((g11_e25[0][3] as Array)[1])])
		var g11_w9: Array = _events_with_tick(g11, 9)
		var g11_w12: Array = _events_with_tick(g11, 12)
		if g11_w9.size() != 1 or g11_w12.size() != 1:
			g11_bad.append("stam%d COMMIT=%d DAMAGE=%d != 1/1" % [
				g11s, g11_w9.size(), g11_w12.size()])
			continue
		var g11_commit := int(g11_w9[0][0])
		var g11_p9: Array = (g11_w9[0][1] as Array)
		var g11_p12: Array = (g11_w12[0][1] as Array)
		if int(g11_p9[0]) != g11_aid or int(g11_p9[1]) != 0:
			g11_bad.append("stam%d COMMIT aid/actor %d/%d != %d/0" % [
				g11s, int(g11_p9[0]), int(g11_p9[1]), g11_aid])
		if not (g11_p9[2] is Array) or (g11_p9[2] as Array).size() != 1:
			g11_bad.append("stam%d COMMIT effects %s != exactly one" % [g11s, str(g11_p9[2])])
		# Same-boundary production rule: START == due == COMMIT == DAMAGE == b.
		if g11_commit != g11_start or int(g11_w12[0][0]) != g11_start \
				or int(g11_p6[6]) != g11_start:
			g11_bad.append("stam%d START/due/COMMIT/DAMAGE %d/%d/%d/%d != all b=%d" % [
				g11s, g11_start, int(g11_p6[6]), g11_commit, int(g11_w12[0][0]), g11_start])
		# Causal actor/action/effect correlation across START, COMMIT and DAMAGE.
		if (g11_p9[2] as Array).size() == 1:
			var g11_eff: Variant = (g11_p9[2] as Array)[0]
			if not (g11_eff is Dictionary) \
					or int((g11_eff as Dictionary).get("effect", -1)) != int(g11_p12[0]) \
					or int((g11_eff as Dictionary).get("action", -1)) != g11_aid \
					or int((g11_eff as Dictionary).get("source", -1)) != 0 \
					or int((g11_eff as Dictionary).get("target", -1)) != 1:
				g11_bad.append("stam%d COMMIT effect id/action/source/target != DAMAGE row %d" % [
					g11s, int(g11_p12[0])])
		if int(g11_p12[2]) != int(g11_p9[3]):
			g11_bad.append("stam%d DAMAGE batch %d != COMMIT batch %d" % [
				g11s, int(g11_p12[2]), int(g11_p9[3])])
		if int(g11_p12[1]) != 1 or int(g11_p12[3]) != g11_base \
				or int(g11_p12[4]) != g11_atk or int(g11_p12[5]) != g11_tdef \
				or int(g11_p12[6]) != 10000 or int(g11_p12[7]) != 10000 \
				or int(g11_p12[8]) != g11_expect:
			g11_bad.append("stam%d DAMAGE tgt/base/atk/def/brace/phase/effective = %d/%d/%d/%d/%d/%d/%d != 1/%d/%d/%d/10000/10000/%d" % [
				g11s, int(g11_p12[1]), int(g11_p12[3]), int(g11_p12[4]), int(g11_p12[5]),
				int(g11_p12[6]), int(g11_p12[7]), int(g11_p12[8]),
				g11_base, g11_atk, g11_tdef, g11_expect])
		if g11_hp0 - int(g11f["hp"]) != g11_expect or int(g11f["hp"]) <= 0:
			g11_bad.append("stam%d hp drop %d to %d != %d and alive" % [
				g11s, g11_hp0 - int(g11f["hp"]), int(g11f["hp"]), g11_expect])
		var g11_hold := int(g11f["brace_end"]) > g11_commit \
				and int(g11f["brace_start"]) >= 0 and g11_commit > int(g11f["brace_start"])
		if g11_hold:
			g11_bad.append("stam%d target was bracing during the frozen damage sample" % g11s)
		if g11a["action"] == null \
				or str((g11a["action"] as Dictionary).get("state", "")) != "recovering" \
				or int(g11a["recovery_end"]) != g11_b + g11_rect:
			g11_bad.append("stam%d post-commit action/recovery = %s/%d != recovering/%d" % [
				g11s, str(g11a["action"]), int(g11a["recovery_end"]),
				g11_b + g11_rect])
		if int(g11a["cooldown_end"]["quick_claw"]) != g11_start + g11_cdt:
			g11_bad.append("stam%d cooldown drifted to %d != %d" % [
				g11s, int(g11a["cooldown_end"]["quick_claw"]), g11_start + g11_cdt])
	_record("C59-quick-production-commit", g11_bad.is_empty(),
		"Quick started inside a real step; 599 no start/debit/new cooldown on its own boundary (regeneration lawful); 600 pays to0, own-start lock entry and still commits; 601 pays to1 with no lock; START=due=COMMIT=DAMAGE=b with one causally correlated effect, DAMAGE base1800 atk100 def25 brace10000 -> effective1440, target alive and unbraced, post-cut6 stamina 0/1, recovery b+21, cd b+72"
			if g11_bad.is_empty() else "; ".join(g11_bad))

func _case_c65() -> void:
	# C65 FIX02/G4 — a PRODUCTION-paid charged Brace interrupted by a qualified prior effect
	# (interrupt power 1 >= stability 1), then a second PRODUCTION-paid Brace whose own debit
	# lands exactly on the exhaustion trigger. Both keep the paid cost/cooldown, arm recovery 15,
	# and the cancel event correlates to the ACTION_START aid that was really paid for.
	var g12_bad: Array = []
	var g12 := _new_sim(3101, "diagnostic")
	var g12a: Dictionary = g12.actors[0]
	var g12f: Dictionary = g12.actors[1]
	g12a["x"] = 4000.0
	g12a["y"] = 3000.0
	g12f["x"] = 5000.0
	g12f["y"] = 3000.0
	g12f["control_mode"] = 1
	g12a["stam"] = 6000
	g12._refresh_gates(g12a)
	var g12_cost := int(content.skill("brace")["stam_cost_cp"])
	var g12_cdt := int(content.cooldown_ticks("brace"))
	var g12_rec := int(content.recovery_ticks("brace"))
	var g12_chg := int(content.charge_ticks("brace"))
	var g12_stab := int(content.skill("brace")["stability"])
	var g12_pwr := int(content.skill("quick_claw")["interrupt_power"])
	if g12_cost != 800 or g12_cdt != 180 or g12_rec != 15 or g12_chg != 27:
		g12_bad.append("frozen Brace cost/cd/rec/charge %d/%d/%d/%d != 800/180/15/27" % [
			g12_cost, g12_cdt, g12_rec, g12_chg])
	if g12_pwr < g12_stab:
		g12_bad.append("prior effect interrupt power %d < brace stability %d" % [
			g12_pwr, g12_stab])
	var g12_plan := {"skill": "brace", "goal": null, "candidates": [], "fits": {},
		"fit_reason": "hold_ground"}
	# FIX02 allows this effect to be an explicitly prepared fixture: production never leaves an
	# effect pending across a boundary, so the prior batch's own action id is allocated first
	# and the paid Brace below then takes the next one.
	var g12_prior_action := int(g12.id_counter["action"])
	g12.id_counter["action"] = g12_prior_action + 1
	g12._try_start(g12a, "brace", g12_plan, g12f)
	var g12_p16: Array = _events_of_type(g12, 6)
	var g12_p17: Array = _events_of_type(g12, 7)
	var g12_aid1 := -1
	if g12a["action"] == null or g12_p16.is_empty() or g12_p17.is_empty():
		g12_bad.append("phase1 paid Brace start failed action=%s start=%d cost=%d" % [
			str(g12a["action"] != null), g12_p16.size(), g12_p17.size()])
	else:
		g12_aid1 = int((g12_p16[0][3] as Array)[0])
		var g12_q7: Array = (g12_p17[0][3] as Array)
		if int(g12_q7[0]) != g12_aid1 or int(g12_q7[2]) != g12_cost \
				or int(g12_q7[3]) != 6000 - g12_cost \
				or int(g12_q7[4]) != g12.tick + g12_cdt:
			g12_bad.append("phase1 START/COST aid=%d cost=%d after=%d cd=%d != %d/%d/%d/%d" % [
				int(g12_q7[0]), int(g12_q7[2]), int(g12_q7[3]), int(g12_q7[4]),
				g12_aid1, g12_cost, 6000 - g12_cost, g12.tick + g12_cdt])
	var g12_stam1 := int(g12a["stam"])
	var g12_cd1 := int(g12a["cooldown_end"]["brace"])
	var g12_start1 := g12.tick
	# QA-PLAY01-R03-F04: the paid balance and the paid cooldown are pinned to the start, so the
	# no-refund predicate below can be exact instead of one-sided.
	if g12_stam1 != 6000 - g12_cost:
		g12_bad.append("phase1 paid stamina %d != %d" % [g12_stam1, 6000 - g12_cost])
	if g12_cd1 != g12_start1 + g12_cdt:
		g12_bad.append("phase1 captured cooldown %d != start+180 %d" % [
			g12_cd1, g12_start1 + g12_cdt])
	var g12_eid := int(g12.id_counter["effect"])
	g12.id_counter["effect"] = g12_eid + 1
	var g12_prior := {
		"effect": g12_eid, "action": g12_prior_action, "source": 1, "target": 0,
		"kind": "damage", "impact_tick": g12.tick + 1, "interrupt_power": g12_pwr,
		"qualification": "qualified", "batch": 0,
		"base_power_cp": int(content.skill("quick_claw")["base_power_cp"]),
		"source_atk": int(g12f["atk"]), "target_def": int(g12a["def"]),
		"brace_factor_bp": 10000, "phase_factor_bp": 10000,
	}
	g12.pending_effects.append(g12_prior)
	_pstep(g12)
	var g12_int_tick := g12.tick
	var g12_p210: Array = _events_of_type(g12, 10)
	if g12_p210.size() != 1 or g12_aid1 < 0:
		g12_bad.append("interruption CANCEL rows=%d aid=%d != 1/%d" % [
			g12_p210.size(), g12_aid1, g12_aid1])
	else:
		var g12_q10: Array = (g12_p210[0][3] as Array)
		if int(g12_q10[0]) != g12_aid1 or int(g12_q10[2]) != g12_eid \
				or str(g12_q10[3]) != "interruption":
			g12_bad.append("CANCEL aid/effect/reason = %d/%d/%s != %d/%d/interruption" % [
				int(g12_q10[0]), int(g12_q10[2]), str(g12_q10[3]), g12_aid1, g12_eid])
	if g12a["action"] != null:
		g12_bad.append("qualified interruption left the charge alive")
	for g12row in _events_of_type(g12, 9):
		if g12_aid1 >= 0 and int((g12row[3] as Array)[0]) == g12_aid1:
			g12_bad.append("interrupted charge still committed")
	if _events_of_type(g12, 7).size() != 1:
		g12_bad.append("interruption refunded or re-charged the Brace: COST rows=%d != 1" %
			_events_of_type(g12, 7).size())
	# QA-PLAY01-R03-F04: EXACT equality. cut6 skips regeneration on this boundary, so any
	# increase is a refund and must fail; returning the 800 cost would now be caught.
	if int(g12a["cooldown_end"]["brace"]) != g12_cd1 or int(g12a["stam"]) != g12_stam1:
		g12_bad.append("interruption mutated paid cd/stam %d/%d -> %d/%d (exact 5200 required)" % [
			g12_cd1, g12_stam1, int(g12a["cooldown_end"]["brace"]), int(g12a["stam"])])
	if int(g12a["recovery_end"]) != g12_int_tick + g12_rec:
		g12_bad.append("interruption recovery %d != %d" % [
			int(g12a["recovery_end"]), g12_int_tick + g12_rec])
	# Phase 2: a SECOND production-paid Brace whose own debit lands exactly on exhaustion.
	_mtick(g12, g12_cd1)
	g12._expire_intervals(g12a)
	if bool(g12a["lock_latched"]) or bool(g12a["physical_locked"]) \
			or int(g12a["lock_end"]) != 0:
		g12_bad.append("phase2 latch not cleared latched=%s physical=%s lock_end=%d" % [
			str(bool(g12a["lock_latched"])), str(bool(g12a["physical_locked"])),
			int(g12a["lock_end"])])
	g12a["stam"] = g12_cost
	g12._refresh_gates(g12a)
	g12._try_start(g12a, "brace", g12_plan, g12f)
	var g12_p36: Array = _events_of_type(g12, 6)
	var g12_p310: Array = _events_of_type(g12, 10)
	var g12_aid2 := -1
	if g12_p36.size() != 2:
		g12_bad.append("phase2 produced %d ACTION_START rows != 2 total" % g12_p36.size())
	else:
		g12_aid2 = int((g12_p36[1][3] as Array)[0])
		if g12_aid2 == g12_aid1 or g12_aid2 < 0:
			g12_bad.append("phase2 aid %d is not distinct from phase1 aid %d" % [
				g12_aid2, g12_aid1])
	if g12_p310.size() != 2:
		g12_bad.append("phase2 CANCEL rows %d != 2 total" % g12_p310.size())
	elif g12_aid2 >= 0:
		var g12_q3: Array = (g12_p310[1][3] as Array)
		if int(g12_q3[0]) != g12_aid2 or g12_q3[2] != null \
				or str(g12_q3[3]) != "start_exhaustion":
			g12_bad.append("phase2 CANCEL aid/effect/reason = %s/%s/%s != %d/null/start_exhaustion" % [
				str(g12_q3[0]), str(g12_q3[2]), str(g12_q3[3]), g12_aid2])
	if g12a["action"] != null:
		g12_bad.append("start exhaustion left the charged action alive")
	if int(g12a["stam"]) != 0 \
			or int(g12a["cooldown_end"]["brace"]) != g12.tick + g12_cdt:
		g12_bad.append("start exhaustion stam/cd = %d/%d != 0/%d (paid, not refunded)" % [
			int(g12a["stam"]), int(g12a["cooldown_end"]["brace"]), g12.tick + g12_cdt])
	if _events_of_type(g12, 7).size() != 2:
		g12_bad.append("the two Braces were charged %d times != exactly 2 COST rows" %
			_events_of_type(g12, 7).size())
	if int(g12a["cooldown_end"]["brace"]) < g12_cd1:
		g12_bad.append("second Brace refunded the first cooldown %d -> %d" % [
			g12_cd1, int(g12a["cooldown_end"]["brace"])])
	if int(g12a["recovery_end"]) != g12.tick + g12_rec:
		g12_bad.append("start exhaustion recovery %d != %d" % [
			int(g12a["recovery_end"]), g12.tick + g12_rec])
	var g12_2commits := 0
	for g12row in _events_of_type(g12, 9):
		if g12_aid2 >= 0 and int((g12row[3] as Array)[0]) == g12_aid2:
			g12_2commits += 1
	if g12_2commits != 0:
		g12_bad.append("start-exhausted Brace committed %d times" % g12_2commits)
	if _events_of_type(g12, 25).is_empty():
		g12_bad.append("no lock ENTRY event for the start-exhausted Brace")
	_record("C65-brace-interrupt-exhaustion", g12_bad.is_empty(),
		"paid Brace aid1 interrupted by a qualified prior effect at tick+1 (power1 >= stability1), CANCEL aid/effect correlation, no COMMIT, cooldown stays at its captured start+180, stamina stays EXACTLY the paid 5200 so a refund of the 800 fails, COST rows stay 1, recovery+15; second paid Brace at start+180 debits to0, CANCEL start_exhaustion with its own aid, stam0/cd start+180, 2 COST rows, recovery+15, lock entry, no COMMIT"
			if g12_bad.is_empty() else "; ".join(g12_bad))

func _case_c49() -> void:
	# C49 FIX01/2 — contrasting permitted-observation ownership, then the correlated
	# decision→submission→REQUEST→response chain, a gateway rejection with no response draw,
	# and the unchanged-category hold versus genuine-category-change queue gates.
	var g2_bad: Array = []

	# (a) Observer1 reads NPC-owned bands/control/readiness/memory with the human's enemy
	#     cues; each side is varied alone so no band crosses ownership.
	var g2_ob := _new_sim(3101, "diagnostic")
	var g2_npc: Dictionary = g2_ob.actors[1]
	var g2_foe: Dictionary = g2_ob.actors[0]
	g2_npc["hp"] = int(g2_npc["hp_max"])
	g2_npc["enemy_visible"] = true
	g2_foe["hp"] = int(g2_foe["hp_max"])
	var g2_base := M01Observations.build_trainer_observation(1, 5, [g2_foe, g2_npc], 0, {}, {})
	var g2_own0: Dictionary = g2_base["own"]
	var g2_cue0: Dictionary = g2_base["enemy"]
	if int(g2_own0["observer"]) != 1 or int(g2_own0["hp_band"]) != 4 \
			or int(g2_cue0["hp_band"]) != 4 or int(g2_cue0["knowledge"]) != 2:
		g2_bad.append("base observation observer=%d own band=%d enemy band=%d knowledge=%d != 1/4/4/2" % [
			int(g2_own0["observer"]), int(g2_own0["hp_band"]), int(g2_cue0["hp_band"]),
			int(g2_cue0["knowledge"])])
	g2_npc["hp"] = maxi(1, int(g2_npc["hp_max"]) / 10)
	var g2_b1 := M01Observations.build_trainer_observation(1, 5, [g2_foe, g2_npc], 0, {}, {})
	if int((g2_b1["own"] as Dictionary)["hp_band"]) == int(g2_own0["hp_band"]) \
			or int((g2_b1["enemy"] as Dictionary)["hp_band"]) != int(g2_cue0["hp_band"]):
		g2_bad.append("own-only hp change did not move the own band alone")
	g2_npc["hp"] = int(g2_npc["hp_max"])
	g2_foe["hp"] = maxi(1, int(g2_foe["hp_max"]) / 10)
	var g2_b2 := M01Observations.build_trainer_observation(1, 5, [g2_foe, g2_npc], 0, {}, {})
	if int((g2_b2["enemy"] as Dictionary)["hp_band"]) == int(g2_cue0["hp_band"]) \
			or int((g2_b2["own"] as Dictionary)["hp_band"]) != int(g2_own0["hp_band"]):
		g2_bad.append("enemy-only hp change did not move the enemy band alone")
	g2_foe["hp"] = int(g2_foe["hp_max"])
	g2_npc["enemy_visible"] = false
	var g2_b3 := M01Observations.build_trainer_observation(1, 5, [g2_foe, g2_npc], 0, {}, {})
	if int((g2_b3["enemy"] as Dictionary)["knowledge"]) != 0 \
			or int((g2_b3["own"] as Dictionary)["hp_band"]) != int(g2_own0["hp_band"]):
		g2_bad.append("no-visibility/no-memory knowledge %d != 0 or own band mutated" \
			% int((g2_b3["enemy"] as Dictionary)["knowledge"]))
	g2_npc["memory_expiry"] = 100
	g2_npc["memory_last_seen_tick"] = 3
	var g2_mem := {"x": 9000.0, "y": 6000.0, "tick": 3, "hp_band": 3, "form": ""}
	var g2_b4 := M01Observations.build_trainer_observation(1, 5, [g2_foe, g2_npc], 0, {}, g2_mem)
	var g2_cue4: Dictionary = g2_b4["enemy"]
	if int(g2_cue4["knowledge"]) != 1 or not _pt_eq(g2_cue4["position"], [9000.0, 6000.0]) \
			or int(g2_cue4["hp_band"]) != 3 \
			or int((g2_b4["own"] as Dictionary)["hp_band"]) != int(g2_own0["hp_band"]):
		g2_bad.append("memory cue knowledge=%d pos=%s band=%d != 1/[9000,6000]/3 or own band mutated" % [
			int(g2_cue4["knowledge"]), str(g2_cue4["position"]), int(g2_cue4["hp_band"])])

	# (b) One decision -> one delayed submission -> one genuine REQUEST -> one response, all
	#     keyed to the same request id; the REQUEST keeps decision observed_tick1 and the
	#     submission carries revalidation observation12.
	var g2_a := _new_sim(3101, "diagnostic")
	var g2_aa: Dictionary = g2_a.actors[1]
	g2_a.actors[0]["x"] = 6000.0
	g2_aa["enemy_visible"] = true
	g2_aa["hp"] = int(g2_aa["hp_max"])
	g2_aa["npc"]["next_decision_tick"] = 1
	_pstep(g2_a)
	g2_aa["npc"]["next_decision_tick"] = 1000000
	for g2_i in 150:
		_pstep(g2_a)
	var g2_e23: Array = _events_of_type(g2_a, 23)
	var g2_e24: Array = _events_of_type(g2_a, 24)
	var g2_e1: Array = _events_of_type(g2_a, 1)
	var g2_e3: Array = _events_of_type(g2_a, 3)
	if g2_e23.size() != 1 or g2_e24.size() != 1 or g2_e1.size() != 1 or g2_e3.is_empty():
		g2_bad.append("correlation counts decision=%d submission=%d request=%d response=%d != 1/1/1/>=1" % [
			g2_e23.size(), g2_e24.size(), g2_e1.size(), g2_e3.size()])
	else:
		var g2_p23: Array = g2_e23[0][3]
		var g2_p24: Array = g2_e24[0][3]
		var g2_p1: Array = g2_e1[0][3]
		var g2_p3: Array = g2_e3[0][3]
		if g2_p24[1] == null or int(g2_p24[1]) != int(g2_p1[0]) \
				or int(g2_p24[0]) != int(g2_p23[0]):
			g2_bad.append("submission does not link decision %s to request %s (request %s)" % [
				str(g2_p23[0]), str(g2_p1[0]), str(g2_p24[1])])
		if str(g2_p24[3]) != "submitted" or int(g2_p24[2]) != 12:
			g2_bad.append("submission outcome=%s revalidation=%s != submitted/12" % [
				str(g2_p24[3]), str(g2_p24[2])])
		if int(g2_p1[4]) != int(g2_p23[1]) or int(g2_p1[1]) != 1 or int(g2_p1[2]) != 1:
			g2_bad.append("REQUEST observed_tick=%s trainer=%s actor=%s != decision observed_tick %s / 1 / 1" % [
				str(g2_p1[4]), str(g2_p1[1]), str(g2_p1[2]), str(g2_p23[1])])
		if int(g2_p3[0]) != int(g2_p1[0]):
			g2_bad.append("response rid %s != request %s" % [str(g2_p3[0]), str(g2_p1[0])])
		if _first_tick(g2_a, 23) != 1 or _first_tick(g2_a, 24) != 13 \
				or _first_tick(g2_a, 1) != 13:
			g2_bad.append("absolute ticks decision/submission/request %d/%d/%d != 1/13/13" % [
				_first_tick(g2_a, 23), _first_tick(g2_a, 24), _first_tick(g2_a, 1)])

	# (c) Final rejection: a submission refused by the gateway carries a null request, is
	#     consumed exactly once and schedules no response draw at all. The empty Attack slot
	#     label is the refusal; nothing else about the decision changes.
	var g2_b := _new_sim(3101, "diagnostic")
	var g2_ba: Dictionary = g2_b.actors[1]
	g2_ba["enemy_visible"] = true
	g2_ba["hp"] = int(g2_ba["hp_max"])
	g2_ba["npc"]["next_decision_tick"] = 1
	_pstep(g2_b)
	g2_ba["npc"]["next_decision_tick"] = 1000000
	g2_ba["slot_labels"] = ["Empty", "Defense", "Run"]
	for g2_j in 30:
		_pstep(g2_b)
	var g2_r24: Array = _events_of_type(g2_b, 24)
	if g2_r24.size() != 1 or g2_r24[0][3][1] != null \
			or str(g2_r24[0][3][3]) != "slot":
		g2_bad.append("rejection submission count=%d payload=%s != 1 with null request and reason slot" % [
			g2_r24.size(), str(g2_r24[0][3] if not g2_r24.is_empty() else [])])
	if not _events_of_type(g2_b, 1).is_empty() or not _events_of_type(g2_b, 3).is_empty():
		g2_bad.append("rejected submission still produced a REQUEST or a response draw")
	if g2_ba["response_episode"] != null or g2_ba["npc"]["queued"] != null:
		g2_bad.append("rejection left a response episode or an unconsumed queue")

	# (d) Unchanged observational category protects a misread held intent: the decision gate
	#     compares the recorded category, so Attack-recorded-as-run is NOT re-queued while a
	#     recorded defense observing attack IS (genuine category change).
	var g2_c := _new_sim(3101, "diagnostic")
	var g2_ca: Dictionary = g2_c.actors[1]
	g2_ca["enemy_visible"] = true
	g2_ca["npc"]["next_decision_tick"] = 1
	g2_ca["accepted_intent"] = {"intent": 9, "episode": 9, "family": 3, "accepted_tick": 0,
		"expiry_tick": 480, "state": "active", "target_kind": 0, "target_or_area": null,
		"goal": null, "observation_category": "attack"}
	_pstep(g2_c)
	var g2_held: Variant = g2_ca["npc"]["queued"]
	var g2_d := _new_sim(3101, "diagnostic")
	var g2_da: Dictionary = g2_d.actors[1]
	g2_da["enemy_visible"] = true
	g2_da["npc"]["next_decision_tick"] = 1
	g2_da["accepted_intent"] = {"intent": 9, "episode": 9, "family": 1, "accepted_tick": 0,
		"expiry_tick": 480, "state": "active", "target_kind": 0, "target_or_area": null,
		"goal": null, "observation_category": "defense"}
	_pstep(g2_d)
	var g2_chg: Variant = g2_da["npc"]["queued"]
	var g2_chg_cat := ""
	if g2_chg is Dictionary:
		g2_chg_cat = str((g2_chg as Dictionary).get("observation_category", ""))
	if g2_held != null:
		g2_bad.append("unchanged-category decision re-queued instead of holding")
	if not (g2_chg is Dictionary) or g2_chg_cat != "attack":
		g2_bad.append("genuine category change queued=%s category=%s != true/'attack'" % [
			str(g2_chg != null), g2_chg_cat])
	_record("C49-npc-ingress-correlation",
		g2_bad.is_empty(),
		"own/enemy band+visibility+memory ownership isolated; decision1 -> submission/request13 -> response rid match, observed_tick1 revalidated12; rejection null-request no-draw; unchanged category holds, changed category queues attack"
			if g2_bad.is_empty() else "; ".join(g2_bad))

func _case_c81() -> void:
	# C81 G-12 utility selection: the production select_by_utility over the author draw
	# order, with one independent draw per candidate and closed-form utilities.
	var bhv: M01MonsterBehavior = _new_sim(3101, "live").behavior
	var fits81 := {"brace": 0.25, "short_bound": 0.90}
	var cands81: Array = ["brace", "short_bound"]
	var vecs81: Array = [
		{"v": [1.0, 0.0], "j20": "brace", "j80": "short_bound"},
		{"v": [0.0, 1.0], "j20": "short_bound", "j80": "short_bound"},
		{"v": [0.5, 0.5], "j20": "short_bound", "j80": "short_bound"},
		{"v": [0.25, 0.75], "j20": "short_bound", "j80": "short_bound"},
	]
	var bad81: Array = []
	var probe_text81: Array = []
	for row81 in vecs81:
		var vec81: Array = row81["v"]
		for j81 in [20, 80]:
			var got81: Dictionary = _utility_pick(bhv, cands81, fits81, j81, vec81)
			var want81: String = str(row81["j20"] if j81 == 20 else row81["j80"])
			if str(got81["pick"]) != want81:
				bad81.append("vec=%s J=%d got=%s want=%s" % [
					vec81, j81, str(got81["pick"]), want81])
			if int(got81["draws"]) != 2:
				bad81.append("vec=%s J=%d draws=%d want 2" % [
					vec81, j81, int(got81["draws"])])
			var util81: Dictionary = _utils_for(vec81, fits81, j81)
			var pick_u81 := float(util81.get(str(got81["pick"]), -INF))
			var max_u81 := -INF
			for k81 in util81:
				max_u81 = maxf(max_u81, float(util81[k81]))
			if absf(pick_u81 - max_u81) > 1e-9:
				bad81.append("vec=%s J=%d pick u=%.9f != max u=%.9f" % [
					vec81, j81, pick_u81, max_u81])
			probe_text81.append("%s@J%d=%.6f/%.6f" % [want81, j81,
				float(util81.get("brace", 0.0)), float(util81.get("short_bound", 0.0))])
	# Empty and single-candidate pools consume no RNG; input order never changes the pick.
	_probe_draws = []
	_probe_draw_n = 0
	var empty_pick81 := str(bhv.select_by_utility([], {}, 20, Callable(self, "_probe_draw")))
	var one_pick81 := str(bhv.select_by_utility(["brace"], {"brace": 0.25}, 20,
		Callable(self, "_probe_draw")))
	if empty_pick81 != "" or one_pick81 != "brace" or _probe_draw_n != 0:
		bad81.append("pool gate: empty=%s one=%s draws=%d" % [
			empty_pick81, one_pick81, _probe_draw_n])
	# Equal draws remove the noise term, so the fits alone decide at either Instinct.
	var hold81 := {"brace": 0.90, "short_bound": 0.25}
	for j81 in [20, 80]:
		var hold_eq := _utility_pick(bhv, cands81, hold81, j81, [0.5, 0.5])
		if str(hold_eq["pick"]) != "brace" or int(hold_eq["draws"]) != 2:
			bad81.append("hold fits, equal draws J=%d -> %s (want brace, 2 draws)" % [
				j81, str(hold_eq["pick"])])
		var esc_eq := _utility_pick(bhv, cands81, fits81, j81, [0.5, 0.5])
		if str(esc_eq["pick"]) != "short_bound" or int(esc_eq["draws"]) != 2:
			bad81.append("escape fits, equal draws J=%d -> %s (want short_bound, 2 draws)" % [
				j81, str(esc_eq["pick"])])
	var swap81 := str(_utility_pick(bhv, ["short_bound", "brace"], fits81, 20, [1.0, 0.0])["pick"])
	var base81 := str(_utility_pick(bhv, ["brace", "short_bound"], fits81, 20, [1.0, 0.0])["pick"])
	if swap81 != base81:
		bad81.append("order dependence: %s vs %s" % [base81, swap81])
	_record("C81-g12-utility-selection", bad81.is_empty(),
		"8 vectors: picks/draws/utilities exact (%s)" % "; ".join(probe_text81) \
			if bad81.is_empty() else "; ".join(bad81))

func _case_c82_response() -> void:
	# C82 QA-M01-03 frozen trait: fixed INT with changed Instinct preserves the response
	# (4 uniforms x 2 instinct values on 8 fresh sims); same Instinct with changed INT and
	# identical forced selection draws preserves the chosen skill, while changed Instinct
	# flips it exactly as the G-12 utility predicts.
	var uni82: Array = [0.05, 0.2, 0.5, 0.9]
	var resp82: Dictionary = {"20": [], "80": []}
	var resp_bad82: Array = []
	for ins82 in [20, 80]:
		for uni in uni82:
			var s82 := _new_sim(3101, "live")
			s82.actors[0]["int_stat"] = 60
			s82.actors[0]["instinct"] = ins82
			(resp82[str(ins82)] as Array).append(_response_probe(s82, 0, float(uni)))
	var same_payload82 := JSON.stringify(resp82["20"]) == JSON.stringify(resp82["80"])
	if not same_payload82:
		resp_bad82.append("instinct changed the response payload")
	var distinct82 := {}
	for p82 in resp82["20"]:
		distinct82[str(p82)] = true
	if distinct82.size() < 2:
		resp_bad82.append("only %d distinct probe values (need >= 2)" % distinct82.size())
	_record("C82-m01-03-response-instinct-invariant", resp_bad82.is_empty(),
		"int_stat=60, 4 uniforms, instinct 20/80: %d distinct payloads, equal=%s" % [
			distinct82.size(), same_payload82] \
			if resp_bad82.is_empty() else "; ".join(resp_bad82))

func _case_c82_skill() -> void:
	var sk_j20 := _skill_pick(60, 20)
	var sk_j80 := _skill_pick(60, 80)
	# QA-F02: the polarity is DIFFERENCE, not equality. Correct production behaviour picks
	# Brace at J20 and Bound at J80, so the two picks differ. An identical pick — correct or
	# deliberately wrong — cannot equal both named expectations and therefore fails.
	var sk_differ := sk_j20 != sk_j80
	var int_flip := _skill_pick(20, 50) == _skill_pick(80, 50)
	# QA-F02: swapped best-fit roles, mirroring G-12 — Brace is now the best fit (.90) and
	# Bound the poor fit (.25), with the adversarial vector giving the BEST skill z=-1 and
	# the other z=+1, so the poor fit still wins at J20 and the best fit wins at J80.
	var bhv82: M01MonsterBehavior = _new_sim(3101, "live").behavior
	var swap_fits := {"brace": 0.90, "short_bound": 0.25}
	var swap20 := _utility_pick(bhv82, ["brace", "short_bound"], swap_fits, 20, [0.0, 1.0])
	var swap80 := _utility_pick(bhv82, ["brace", "short_bound"], swap_fits, 80, [0.0, 1.0])
	var u_swap80: Dictionary = _utils_for([0.0, 1.0], swap_fits, 80)
	var gap80 := float(u_swap80["brace"]) - float(u_swap80["short_bound"])
	# QA-F02: actor-side control — the mirrored spawn must reproduce both named picks.
	var sk_j20_side := _skill_pick(60, 20, 1)
	var sk_j80_side := _skill_pick(60, 80, 1)
	_record("C82-m01-03-skill-instinct-flip",
		sk_differ and sk_j20 == "brace" and sk_j80 == "short_bound" and int_flip \
			and str(swap20["pick"]) == "short_bound" and str(swap80["pick"]) == "brace" \
			and int(swap20["draws"]) == 2 and int(swap80["draws"]) == 2 and gap80 > 0.0 \
			and sk_j20_side == "brace" and sk_j80_side == "short_bound",
		"differ=%s instinct20=%s instinct80=%s (want brace/short_bound); swapped-fit J20=%s J80=%s (want short_bound/brace) gap80=%.6f draws=%d/%d; side1 J20=%s J80=%s; fixed-instinct INT flip=%s" % [
			sk_differ, sk_j20, sk_j80, str(swap20["pick"]), str(swap80["pick"]), gap80,
			int(swap20["draws"]), int(swap80["draws"]), sk_j20_side, sk_j80_side, int_flip])
