#!/usr/bin/env python3
"""Independent bounded supervisor for approved M01 child commands.

Implements the Architect r2 interface with the MM-M01-RES02 fail-closed
corrections (contracts 1-4) plus the MM-M01-RES03 guard-gap corrections
(contracts F01-F05): one owned child group, an independent monotonic wall
deadline, optional CPU limit where supported, owned-group aggregate RSS
sampling, bounded output capture/drain, cancellation, bounded TERM-to-KILL
escalation within two seconds with reaping, and a JSON record.

Fail-closed rules (R02 + R03):
  * A launched run succeeds only after the child is reaped and the owned
    group is positively verified empty. Cleanup sampling failure, final
    verification failure, unknown verification or surviving group members
    make the run nonzero; the original wall/RSS/cancel cause is retained
    alongside the cleanup failure.
  * Normal-mode calls require explicit finite positive wall and RSS limits;
    NaN, infinity, zero, negative, fractional or missing values are rejected
    with usage exit 2 before launch. Limit options are never accepted (and
    silently ignored) in `--diagnose` mode; each case defines its own budgets.
  * Sample freshness is gated by one fixed absolute bound (250 ms): sample
    waits run in short slices so cancellation and the wall deadline stay
    responsive while a sample is in flight, samples that never finish are
    recorded with their real unfinished age, and an over-bound gap is
    monitoring failure. Cancellation and expiry are rechecked immediately
    before launch. An empty or wrong-group probe is a monitoring failure and
    never launches.
  * Every path after a successful launch retains the real PID/PGID and enters
    bounded cleanup/reaping. A post-launch exception in any stage funnels
    into bounded terminate/verify/collect and a structured nonzero record.
    Reader read errors make the drain incomplete, never a successful drain.
  * Escalation is independent of sampling: TERM at stop start, KILL no later
    than two seconds after stop start regardless of sampler state, with
    per-signal timestamps, a single shared wait-status decoder, and stage
    elapsed/overrun fields. Sample budgets contain no undocumented slack.
  * Each diagnostic case runs in its own session group under an outer finite
    containment deadline that can interrupt a hung inner supervisor and
    boundedly clean the exact case identities (spawn sidecar records pid/pgid).

No shell expansion, no retry, no unrelated process termination. Monitoring
failure prevents launch. Sampled RSS is best effort, never a hard allocation
cap, and process groups do not contain sessions that escape the group.

Diagnostic mode runs harmless sleeping/idle children only; it never launches
Godot and never allocates large memory. `--argcheck` revalidates normal-mode
argument rejection with harmless children under the same bounded spawn.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import platform
import resource
import signal
import subprocess
import sys
import tempfile
import threading
import time

EXIT_OK = 0
EXIT_CHILD = 1
EXIT_USAGE = 2
EXIT_MONITORING = 3
EXIT_WALL = 4
EXIT_RSS = 5
EXIT_CPU = 6
EXIT_INTERNAL = 7
EXIT_CANCELLED = 130

DEFAULT_POLL_MS = 250
DEFAULT_OUTPUT_BYTES = 262144
OUTPUT_MIN_BYTES = 1024
OUTPUT_MAX_BYTES = 8 * 1024 * 1024
POLL_MIN_MS = 50
POLL_MAX_MS = 5000
PS_TIMEOUT_SECONDS = 2.0
CLEANUP_SAMPLE_TIMEOUT = 1.0
VERIFY_TIMEOUT = 1.0
# Fixed absolute freshness gate (R03 contract F01 / Architect r2 Task 3):
# one number for every gap, never inflated by poll time, sampler budget or
# slack. First observation is gated from M, later ones from last valid V.
FRESHNESS_BOUND_MS = 250
# Conservative early refusal: the wait is stopped this many ms before the
# hard freshness cutoff so dispatch room exists. The decision must still be
# <= the hard cutoff; no observation older than FRESHNESS_BOUND_MS is valid.
FRESHNESS_DECISION_LEAD_MS = 20
# Launch handoff deadline H = M + HANDOFF_MS, clipped to W and the freshness
# decision target (Architect r2 F01 admission window).
HANDOFF_MS = 100
# Bootstrap no-release lease measured from bootstrap entry.
BOOTSTRAP_LEASE_MS = 500
A2_PARENT_EXIT_CASE = "a2_parent_exit_before_admission"
A2_PARENT_EXIT_CODE = 71
A5_UNRELATED_CASE = "a5_unrelated_admission"
A5_REFUSAL_EXIT_CODE = 73
A3_CRASH_CASE = "a3_inner_crash"
A3_CRASH_EXIT_CODE = 72
GODOT_PARSE_CASE = "godot_parse_probe"
GODOT_PARSE_ARGV = (
    "/Applications/Godot.app/Contents/MacOS/Godot", "--headless", "--path",
    "/Users/madedwidharma/Work/bg-mm-apocalypsetrainer/Game/M01",
    "--check-only", "--script", "res://checks/run_checks.gd",
)

# RUN01: two fixed engine acceptance routes through the same retained outer controller. The
# inner argv is derived only from the named attempt directory, never from user input; engine,
# project, script, suite, seed and limits stay fixed. Direct dispatch without the outer private
# admission gate, an unknown profile, path escape, symlink redirection and a reused sink are all
# refused rather than treated as a shortcut.
GODOT_DEV_SMOKE_CASE = "godot_dev_smoke_probe"
GODOT_PLAY01_CASE = "godot_play01_probe"
GODOT_ENGINE_SUITE = {
    GODOT_DEV_SMOKE_CASE: "dev_smoke",
    GODOT_PLAY01_CASE: "play01_focus",
}
ENGINE_CASES = frozenset(GODOT_ENGINE_SUITE)
# Exact expected runner result sets for those two fixed profiles (RUN01-SOURCE). The helper
# refuses a result that is missing, duplicated or extra relative to these, and a NOT RUN row
# never counts as success.
DEV_SMOKE_EXPECTED_IDS = (
    "C00-content-load", "D00-fixtures-load", "D01-nav-fixtures",
    "D02-corrupt-chain-fails-closed", "D03-dev-tick-wall-budget",
    "D04-nav-work-budget", "D05-timeout-predicate", "D06-probe-timeout",
    "D07-remaining-budget-oracle",
)
PLAY01_FOCUS_EXPECTED_IDS = (
    "C00-content-load", "C26-ordinary-movement", "C27-goal-production",
    "C28-corner-traversal", "C63-legal-connectors", "C64-static-stop-contact",
    "C53-lifecycle-correlation", "C54-quick-g14-boundaries",
    "C55-movement-action-state", "C57-owning-intent-retirement",
    "C58-request-episode-divergence", "C59-quick-production-commit",
    "C65-brace-interrupt-exhaustion", "C49-npc-ingress-correlation",
    "C81-g12-utility-selection", "C82-m01-03-response-instinct-invariant",
    "C82-m01-03-skill-instinct-flip",
)
ENGINE_ERROR_MARKERS = ("ERROR:", "PARSE ERROR", "SCRIPT ERROR", "FAILED TO LOAD",
                        "FAILED LOADING", "CANNOT LOAD", "COULD NOT LOAD",
                        "COMPILATION FAILED")
# Byte form for the bounded preview fatal-output scan. Matching upper-cases the pumped
# bytes, so these markers stay upper case (same set as the post-run scan).
ENGINE_ERROR_MARKER_BYTES = tuple(m.encode("utf-8") for m in ENGINE_ERROR_MARKERS)
GODOT_ENGINE_BINARY = "/Applications/Godot.app/Contents/MacOS/Godot"
GODOT_ENGINE_PROJECT = "/Users/madedwidharma/Work/bg-mm-apocalypsetrainer/Game/M01"
GODOT_ENGINE_SCRIPT = "res://checks/run_checks.gd"
# Named Junior evidence root every fresh RUN01 attempt must live under (RUN01-SOURCE).
RUN01_EVIDENCE_ROOT = (
    "/Users/madedwidharma/Work/bg-mm-apocalypsetrainer/Docs/junior/evidence/"
    "MM-M01-PLAY01/RUN01"
)
# Fixed inner normal command for the engine routes (Architect RUN01 proposal external limits).
ENGINE_INNER_LIMITS = ("--wall-seconds", "5", "--cpu-seconds", "4", "--rss-mib", "512",
                       "--output-bytes", "262144", "--poll-ms", "100", "--keep-output")

# PREVIEW01: one fixed native main-scene route for a single monitored graphical preview.
# It is deliberately NOT part of GODOT_ENGINE_SUITE/ENGINE_CASES: the two headless check
# routes keep their own suite map, runner result/marker predicates, 8s outer limit and
# A2/A5 registration shapes. The preview has its own argv, completion predicates and a
# 63s outer runtime, and never fabricates a runner pass or match completion.
GODOT_NATIVE_PREVIEW_CASE = "godot_native_preview"
PREVIEW_CASES = frozenset({GODOT_NATIVE_PREVIEW_CASE})
# Diagnostic opt-in union: the two headless checks plus the preview route opt into the
# producer timestamps, `registration_reads` and `identity_query` observations. This is a
# union only; the suite/dispatch maps above stay specific to the headless checks.
INSTRUMENTED_CASES = ENGINE_CASES | PREVIEW_CASES
# Exact fixed native argv: installed binary + pinned project main scene. No seed, scene,
# headless/script/editor/import/export or renderer/FPS flag (host defaults root_seed=3101;
# project.godot sets 1280x720 Compatibility 30FPS).
GODOT_PREVIEW_ARGV = (GODOT_ENGINE_BINARY, "--path", GODOT_ENGINE_PROJECT)
# Preview-only envelope (supervisor limits, not engine argv).
OUTER_PREVIEW_RUNTIME_S = 63.0
PREVIEW_HANDOFF_MS = 200
PREVIEW_FRESHNESS_BOUND_MS = 400
PREVIEW_INNER_LIMITS = ("--wall-seconds", "60", "--cpu-seconds", "4", "--rss-mib", "512",
                        "--output-bytes", "262144", "--poll-ms", "100", "--keep-output")
# Observed aggregate RSS early-stop for the accountable launch set (Owner-accepted
# sampled policy; not a hard physical-memory guarantee). KiB are converted by 1024.
PREVIEW_AGG_RSS_BYTES = 750 * 1024 * 1024
# Fixed retained engine-group per-process early-stop authority (D38): 512 MiB, strict `>`.
PREVIEW_ENGINE_RSS_BYTES = 512 * 1024 * 1024
# Named evidence root for the preview route (separate from the check routes' RUN01 root).
PREVIEW_EVIDENCE_ROOT = (
    "/Users/madedwidharma/Work/bg-mm-apocalypsetrainer/Docs/junior/evidence/MM-M01-PREVIEW01"
)


def preview_child_argv() -> list:
    """The only native-preview argv this file ever dispatches (PREVIEW01 fixed route)."""
    return list(GODOT_PREVIEW_ARGV)


def preview_child_case(child: list) -> str | None:
    """The one registered native-preview case this exact argv implements, else None."""
    return GODOT_NATIVE_PREVIEW_CASE if list(child or []) == list(GODOT_PREVIEW_ARGV) else None


def engine_child_argv(suite: str, out_dir: str) -> list:
    """The only engine argv this file ever dispatches (RUN01 fixed profiles)."""
    return [GODOT_ENGINE_BINARY, "--headless", "--path", GODOT_ENGINE_PROJECT,
            "--script", GODOT_ENGINE_SCRIPT, "--",
            "--suite=" + suite, "--seed=3101", "--out=" + out_dir]


def engine_child_case(child: list) -> str | None:
    """Registered engine case a normal-mode child argv exactly implements, else None.

    An unregistered suite, a non-3101 seed, extra/missing flags or an --out outside the
    named evidence root all return None so they cannot borrow this file's admission.
    """
    if not child or child[0] != GODOT_ENGINE_BINARY:
        return None
    prefix = [GODOT_ENGINE_BINARY, "--headless", "--path", GODOT_ENGINE_PROJECT,
              "--script", GODOT_ENGINE_SCRIPT, "--"]
    if child[:len(prefix)] != prefix:
        return None
    tail = child[len(prefix):]
    if len(tail) != 3:
        return None
    suite_flag, seed_flag, out_flag = tail
    if seed_flag != "--seed=3101" or not suite_flag.startswith("--suite="):
        return None
    if not out_flag.startswith("--out="):
        return None
    suite = suite_flag[len("--suite="):]
    if suite not in GODOT_ENGINE_SUITE.values():
        return None
    out_dir = os.path.realpath(out_flag[len("--out="):])
    root = os.path.realpath(RUN01_EVIDENCE_ROOT)
    if out_dir != root and not out_dir.startswith(root + os.sep):
        return None
    for case, known in GODOT_ENGINE_SUITE.items():
        if known == suite:
            return case
    return None


def validate_engine_record_dir(record_dir, root=RUN01_EVIDENCE_ROOT) -> str | None:
    """Fresh, un-symlinked, escape-proof attempt directory for the engine routes."""
    if record_dir is None:
        return ("--record is required for the engine routes; a fresh attempt "
                f"directory under {root} must be named")
    real = os.path.realpath(record_dir)
    root = os.path.realpath(root)
    if real != root and not real.startswith(root + os.sep):
        return f"engine record directory must live under {root} (got {real})"
    if os.path.islink(record_dir):
        return "engine record directory must not be a symlink"
    if os.path.isdir(record_dir):
        entries = sorted(os.listdir(record_dir))
        if entries:
            return ("engine record directory is not empty; refusing reused sink: "
                    + ", ".join(entries[:8]))
    elif os.path.exists(record_dir):
        return "engine record path exists and is not a directory"
    if root == os.path.realpath(RUN01_EVIDENCE_ROOT):
        for suite in GODOT_ENGINE_SUITE.values():
            if os.path.exists(os.path.join(real, suite)):
                return f"runner subdirectory already exists: {suite}"
    return None
# Registration/ACK/release framing bounds (Architect r2 F01 descriptor table).
FRAME_MAX_BYTES = 512
REG_AGG_MAX_BYTES = 1024
# Absolute stop-origin cutoffs, all measured from S (Architect r2 deadline
# table): TERM dispatch target, KILL aim/hard gate, termination, verification,
# collection and the single combined post-stop total.
TERM_DISPATCH_TARGET_MS = 50
KILL_TARGET_MS = 1750
KILL_HARD_MS = 2000
TERMINATION_END_MS = 4000
VERIFY_ALLOWANCE_MS = 1000
COLLECT_ALLOWANCE_MS = 2000
POST_STOP_TOTAL_MS = 7000
# Effective monitoring cadence; later due times advance from M in steps of
# min(requested poll, 100 ms), skipping missed slots (never completion+period).
FRESHNESS_PERIOD_S = 0.10
# Sliced wait granularity while a sample is in flight; capped at 5 ms and
# clipped to the freshness decision target (Architect r2 Task 3).
SAMPLE_SLICE_S = 0.005
# Inner ps subprocess timeout is shortened by this handoff allowance so the
# bounded join can wait exactly the sample budget (no undocumented slack).
SAMPLE_HANDOFF_S = 0.005
# Cleanup samples are skipped when the remaining window (until the KILL
# target or the termination end) is smaller than this: an observation cut to
# a few milliseconds would time out on ordinary ps latency and record a fake
# sampler failure. Waiting is honest; sampling is not. Skipping never extends
# a deadline and never converts a missing observation into success.
MIN_CLEANUP_SAMPLE_WAIT_S = 0.15
COLLECT_JOIN_SECONDS = 2.0
STUCK_READER_SECONDS = 60.0
TERMINATION_ALLOWANCE_SECONDS = TERMINATION_END_MS / 1000.0
CLEANUP_ALLOWANCE_SECONDS = VERIFY_ALLOWANCE_MS / 1000.0
COLLECT_ALLOWANCE_SECONDS = COLLECT_ALLOWANCE_MS / 1000.0
OUTPUT_HEAD_CHARS = 400
SYNTHETIC_SURVIVOR_PID = 2147483646
ARGCHECK_MARKER = "R03_ARGCHECK_NO_LAUNCH"
# Diagnostic outer bounds (Architect r2): reviewed 8-second outer runtime
# plus one seven-second teardown, with explicitly earlier 1-second timeout
# cases; every controlled workload/descendant self-limits at five seconds.
OUTER_RUNTIME_S = 8.0
OUTER_EARLY_TIMEOUT_S = 1.0
WORKLOAD_SELF_LIMIT_S = 5.0
INNER_STALL_S = 4.0
OUTER_POST_STOP_S = 7.0
# Case names that use the deliberately earlier 1-second outer timeout.
EARLY_TIMEOUT_CASES = frozenset({"a1_outer_stall"})
# Outer containment: each case subprocess gets case wall plus this margin,
# which covers stop (4 s) + verification (1 s) + collection (2 s) + the
# inner wall+8 s acceptance bound with room for bounded teardown (F05).
CASE_OUTER_MARGIN_S = 12.0
OUTER_PIPE_CAP_BYTES = 256 * 1024
OUTER_DRAIN_JOIN_S = 2.0

DIAGNOSE_CASES = (
    # Original R01/R02 cases (rechecked under R03).
    "deadline",
    "cancel",
    "cleanup",
    "rss_available",
    "rss_low",
    "sampler_stale",
    "sampler_failed",
    "output_bounded",
    "cpu_limit",
    "cleanup_sampler_failed",
    "final_verifier_failed",
    "final_verifier_nonempty",
    "probe_stalled",
    "probe_expired",
    "sampler_stalled",
    "cancel_while_sampling",
    "reader_setup_failure",
    "term_resistant",
    "pipe_retention",
    "drain_stuck",
    # R03 contract F01: fixed 250 ms freshness.
    "probe_empty",
    "probe_wrong_group",
    "probe_cancel",
    "sample_slow_over_250",
    "expiry_during_sample",
    "cancel_latency",
    # R03 contract F02: post-launch finalization funnel + reader errors.
    "sampler_runtime_failed",
    "reader_partial_start",
    "reader_mid_read_failure",
    "post_launch_fault_monitor_start",
    "post_launch_fault_terminate",
    "post_launch_fault_collect",
    # R03 contract F04: escalation independent of sampling + shared decoder.
    "term_resistant_sampler_stalled",
    "cleanup_normal_exit",
    # R03 contract F05: enforced outer containment self-proof.
    # Architect r2 A1 replaces it: outer-only finite stall under the earlier
    # 1-second outer timeout. Inner ignores TERM and self-limits at four
    # seconds; no separately launched workload.
    "a1_outer_stall",
    "a2_parent_exit_before_admission",
    "a5_unrelated_admission",
    "a3_inner_crash",
    "a5_survivor",
    "b1_normal_cli",
    "b2_first_stall",
    "b4_later_stall",
    "c3_term_resistance",
    "b5_cancel_stalled",
)

# Cases whose inner process intentionally hangs so the outer boundary is
# proven to interrupt it. Expected outcome: outer timeout + exact kill.
OUTER_SELFTEST_CASES = frozenset({"a1_outer_stall"})

# Cases that are supposed to end with a cleanup failure (R02 contract 1,
# R03 contract F02/F04).
EXPECT_CLEANUP_FAILURE = frozenset({
    "cleanup_sampler_failed",
    "final_verifier_failed",
    "final_verifier_nonempty",
    "post_launch_fault_terminate",
    "term_resistant_sampler_stalled",
})

# Cases whose design prevents the child from ever being launched.
PRE_LAUNCH_CASES = frozenset({
    "sampler_failed", "probe_stalled", "probe_expired",
    "probe_empty", "probe_wrong_group",
})

# Pre-launch cases that stop because of cancellation, not monitoring failure.
PRE_LAUNCH_CANCEL_CASES = frozenset({"probe_cancel"})

CANCEL = threading.Event()
CANCEL_AT = None  # monotonic seconds when CANCEL was last set (F01 latency)
CANCEL_AT_NS = None
CURRENT_STAGE = ""
STAGE_LOG: list = []
# Reporting errors are retained in memory (Architect r2 Task 2): a failed
# stderr write is never retried in the critical signal path and never lets an
# exception escape into the finalizer.
REPORTING_ERRORS: list = []


class SamplerError(RuntimeError):
    pass


def stage(name: str) -> None:
    """Record a stage without performing I/O in the safety path."""
    global CURRENT_STAGE
    CURRENT_STAGE = name
    try:
        STAGE_LOG.append({"stage": name, "at_ns": time.monotonic_ns()})
    except Exception as exc:  # noqa: BLE001 - reporting must not break control flow
        REPORTING_ERRORS.append(
            f"stage write failed for {name}: {type(exc).__name__}: {exc}")


def _report_text(text: str, stream, end_ns=None) -> dict:
    """A stalled output sink cannot extend the caller's original deadline."""
    started = time.monotonic_ns()
    if end_ns is None:
        end_ns = started+20_000_000
    box = {}
    encoded = text.encode("utf-8")
    if len(encoded) > OUTER_PIPE_CAP_BYTES:
        box["error"] = "report exceeds output cap"
    elif started >= end_ns:
        box["error"] = "report budget exhausted"
    else:
        def write():
            try:
                # Avoid a buffered-stream lock held by a timed-out daemon.
                fd = stream.fileno()
                view = memoryview(encoded)
                while view:
                    if time.monotonic_ns() >= end_ns:
                        raise TimeoutError("report cutoff reached")
                    written = os.write(fd, view)
                    if written <= 0:
                        raise OSError("report made no progress")
                    view = view[written:]
            except Exception as exc:
                box["error"] = f"report write failed: {type(exc).__name__}: {exc}"
            finally:
                box["write_end_ns"] = time.monotonic_ns()
        worker = threading.Thread(target=write, name="run_bounded-report", daemon=True)
        try:
            worker.start()
            worker.join(max(0, end_ns-time.monotonic_ns())/1e9)
            if worker.is_alive():
                box["error"] = "report completion unknown before cutoff"
        except Exception as exc:
            box["error"] = f"report worker failed: {exc}"
    box["started_ns"], box["completed_ns"] = started, time.monotonic_ns()
    box["complete"] = (not box.get("error") and type(box.get("write_end_ns")) is int
                       and box["completed_ns"] <= end_ns)
    if not box["complete"]:
        REPORTING_ERRORS.append(box.get("error", "report completed after cutoff"))
    return box


def note(msg: str) -> None:
    _report_text(f"NOTE {msg}\n", sys.stderr)



def utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")


def self_sha256() -> str:
    try:
        with open(__file__, "rb") as handle:
            return hashlib.sha256(handle.read()).hexdigest()
    except OSError:
        return ""


def _ms(since: float) -> int:
    return int(round((time.monotonic() - since) * 1000))


def _limits_dict(wall_seconds=None, cpu_seconds=None, rss_mib=None,
                 output_bytes=DEFAULT_OUTPUT_BYTES, poll_ms=DEFAULT_POLL_MS,
                 *, preview_policy=False) -> dict:
    return {
        "wall_seconds": wall_seconds,
        "cpu_seconds": cpu_seconds,
        "rss_mib": rss_mib,
        "output_bytes": output_bytes,
        "poll_ms": poll_ms,
        "sample_period_ms": int(round(FRESHNESS_PERIOD_S * 1000)),
        "termination_allowance_seconds": TERMINATION_ALLOWANCE_SECONDS,
        "cleanup_allowance_seconds": CLEANUP_ALLOWANCE_SECONDS,
        "collect_allowance_seconds": COLLECT_ALLOWANCE_SECONDS,
        "sampler_timeout_seconds": PS_TIMEOUT_SECONDS,
        "freshness_bound_ms": (PREVIEW_FRESHNESS_BOUND_MS if preview_policy
                               else FRESHNESS_BOUND_MS),
        "freshness_decision_lead_ms": FRESHNESS_DECISION_LEAD_MS,
        "handoff_ms": PREVIEW_HANDOFF_MS if preview_policy else HANDOFF_MS,
        "bootstrap_lease_ms": BOOTSTRAP_LEASE_MS,
        "term_dispatch_target_ms": TERM_DISPATCH_TARGET_MS,
        "kill_target_ms": KILL_TARGET_MS,
        "kill_hard_ms": KILL_HARD_MS,
        "termination_end_ms": TERMINATION_END_MS,
        "verify_allowance_ms": VERIFY_ALLOWANCE_MS,
        "collect_allowance_ms": COLLECT_ALLOWANCE_MS,
        "post_stop_total_ms": POST_STOP_TOTAL_MS,
    }


def _finite_positive(value) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
        and float(value) > 0
    )


def _ps_capture(columns: str, end_ns: int, meta: dict | None = None,
                *, query_timing_out: dict | None = None) -> tuple:
    """Capped complete ps capture, including query cleanup in the same budget.

    RUN02-OBS01: when `meta` is supplied, the same existing query additionally
    records its own observed timing facts for later bounded evidence. This only
    adds monotonic reads and dict writes inside the existing budget; the cutoff
    equation, `ps` arguments, query count and every decision are unchanged, and
    a failed or partial table can never be turned into ownership by metadata.

    TIMING01: when `query_timing_out` is supplied, this SAME existing query also
    publishes fresh nine-field projections into its single private slot at the
    five existing meta checkpoints. Publication copies scalars already recorded
    in `meta` (no new clock, lock, wait, I/O or query), never exposes the live
    `meta` dictionary, and adds no reader other than this call's own caller.
    """
    proc = None
    buffers = [bytearray(), bytearray()]
    error = None
    if meta is None and query_timing_out is not None:
        # Publication enabled without a caller-supplied meta: keep the metadata
        # worker-private and reuse the existing optional-metadata path verbatim.
        meta = {}
    if meta is not None:
        meta.update(entry_ns=None, deadline_ns=end_ns, cutoff_ns=None,
                    popen_return_ns=None, capture_stop_ns=None,
                    capture_stop_reason=None, function_return_ns=None,
                    stdout_bytes=None, stderr_bytes=None,
                    stdout_eof=None, stderr_eof=None, exit_code=None,
                    kill_attempted=False, reap_confirmed=False, error=None)

    def publish(completed: bool) -> None:
        # TIMING01: one fresh immutable-by-convention projection per checkpoint;
        # only the slot reference is replaced, so a controller already holding an
        # earlier projection keeps a coherent snapshot of that earlier stage.
        if query_timing_out is None or meta is None:
            return
        reason = meta.get("capture_stop_reason")
        failure = meta.get("error") if completed else None
        reap = (meta.get("reap_confirmed")
                if (meta.get("popen_return_ns") is not None
                    and meta.get("function_return_ns") is not None)
                else None)
        query_timing_out["snapshot"] = {
            "entry_ns": meta.get("entry_ns"),
            "deadline_ns": meta.get("deadline_ns"),
            "cutoff_ns": meta.get("cutoff_ns"),
            "popen_return_ns": meta.get("popen_return_ns"),
            "capture_stop_ns": meta.get("capture_stop_ns"),
            "capture_stop_reason": (reason[:256] if isinstance(reason, str)
                                    else None),
            "function_return_ns": meta.get("function_return_ns"),
            "reap_confirmed": reap if isinstance(reap, bool) else None,
            "error": failure[:256] if isinstance(failure, str) else None,
        }

    def finish(result: tuple) -> tuple:
        # Observed facts only; unreached stages stay explicitly None.
        if meta is not None:
            meta["stdout_bytes"] = len(buffers[0])
            meta["stderr_bytes"] = len(buffers[1])
            meta["exit_code"] = proc.returncode if proc is not None else None
            meta["error"] = result[2]
            meta["function_return_ns"] = time.monotonic_ns()
            publish(True)
        return result

    try:
        now = time.monotonic_ns()
        if meta is not None:
            meta["entry_ns"] = now
        publish(False)
        if now >= end_ns:
            return finish((None, None, "process-table budget exhausted"))
        # Leave part of the original budget to kill/reap a stalled query.
        query_end = end_ns - min(20_000_000, (end_ns - now) // 4)
        if meta is not None:
            meta["cutoff_ns"] = query_end
        publish(False)
        proc = subprocess.Popen(
            ["ps", "-axo", columns], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if meta is not None:
            meta["popen_return_ns"] = time.monotonic_ns()
        publish(False)
        streams = [proc.stdout, proc.stderr]
        fds = [stream.fileno() for stream in streams]
        for fd in fds:
            os.set_blocking(fd, False)
        active = set(range(2))
        while active or proc.poll() is None:
            if time.monotonic_ns() >= query_end:
                error = "process-table capture cutoff reached"
                break
            progressed = False
            for i in tuple(active):
                try:
                    chunk = os.read(fds[i], min(65536, PS_MAX_CAPTURE_BYTES + 1))
                except BlockingIOError:
                    continue
                if not chunk:
                    active.remove(i)
                    continue
                progressed = True
                if sum(map(len, buffers)) + len(chunk) > PS_MAX_CAPTURE_BYTES:
                    error = "process-table capture cap exceeded"
                    break
                buffers[i].extend(chunk)
            if error:
                break
            if not progressed:
                time.sleep(min(0.001, max(0, query_end-time.monotonic_ns())/1e9))
        if meta is not None:
            meta["capture_stop_ns"] = time.monotonic_ns()
            meta["capture_stop_reason"] = error
            meta["stdout_eof"] = 0 not in active
            meta["stderr_eof"] = 1 not in active
        publish(False)
        if error is None and proc.returncode != 0:
            error = f"ps failed rc={proc.returncode}"
    except Exception as exc:
        error = f"ps capture failed: {type(exc).__name__}: {exc}"
    finally:
        if proc is not None:
            if proc.poll() is None:
                if meta is not None:
                    # Entry into the attempted call, not delivery or cause of exit.
                    meta["kill_attempted"] = True
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass
                except OSError as exc:
                    error = f"{error or ''}; ps kill failed: {exc}"
                while proc.poll() is None and time.monotonic_ns() < end_ns:
                    time.sleep(min(0.001, max(0, end_ns-time.monotonic_ns())/1e9))
                if proc.returncode is None:
                    error = f"{error or ''}; ps reap unconfirmed"
                elif meta is not None:
                    meta["reap_confirmed"] = True
            elif meta is not None:
                meta["reap_confirmed"] = True
            for stream in (proc.stdout, proc.stderr):
                if stream is not None:
                    stream.close()
    if time.monotonic_ns() > end_ns:
        error = f"{error or ''}; process-table completion exceeded cutoff"
    if error:
        return finish((None, proc.pid if proc else None, error))
    if not buffers[0] or not buffers[0].endswith(b"\n"):
        return finish((None, proc.pid, "empty or incomplete process-table output"))
    return finish((bytes(buffers[0]), proc.pid, None))


def _reset_preview_observation(diag: dict, phase: str) -> None:
    """Clear phase-local observation diagnostics BEFORE the existing attempt.

    Covers the no-call / aborted / raised sampling paths (which never reach
    ``ps_sample``) so a stale prior membership can never be read as the current
    observation. The marker records the phase attempt; callers set ``complete``.
    """
    diag["members"] = {}
    diag["mismatched"] = []
    diag["query_pid"] = None
    diag["query_rss_kib"] = None
    diag["query_ppid"] = None
    diag["query_pgid"] = None
    diag["observation"] = {"phase": phase, "attempted_ns": time.monotonic_ns()}


def ps_sample(pgid: int, timeout: float = PS_TIMEOUT_SECONDS, *,
              diag: dict | None = None,
              query_timing_out: dict | None = None) -> dict:
    if diag is not None:
        # PREVIEW01: clear observation-specific fields up front so a failed, rejected or
        # fallback call can never leave a previous observation's RSS/profile reused. The
        # caller's phase marker (when present) is preserved.
        _reset_preview_observation(diag, (diag.get("observation") or {}).get("phase", "sample"))
    # TIMING01: with no slot the expansion contributes no argument, so this stays
    # the ORIGINAL single capture invocation — same columns and the existing
    # computed end expression, evaluated once in the same call position. Only the
    # enabled call forwards the private publication slot.
    capture_kw = ({"query_timing_out": query_timing_out}
                  if query_timing_out is not None else {})
    out, ps_pid, error = _ps_capture(
        "pgid=,rss=,pid=", time.monotonic_ns() + int(timeout * 1e9), **capture_kw)
    if error:
        raise SamplerError(error)
    rows = {}
    all_rows = {}
    for line in out.decode("utf-8", "strict").splitlines():
        parts = line.split()
        if len(parts) != 3:
            raise SamplerError("incomplete process sample row")
        try:
            group, rss, pid = map(int, parts)
        except ValueError as exc:
            raise SamplerError("invalid process sample row") from exc
        if pid < 0 or group < 0 or rss < 0 or pid in all_rows:
            raise SamplerError("invalid or duplicate process sample identity")
        all_rows[pid] = (group, rss)
        if group == pgid and pid != ps_pid:
            rows[pid] = rss
    if all_rows.get(os.getpid(), (None,))[0] != os.getpgrp():
        raise SamplerError("querying controller missing or group mismatched")
    if diag is not None:
        # PREVIEW01: diagnostic launch-set membership taken from the SAME bounded
        # observation. These rows never enter the authoritative engine `rows` or the
        # signal/cleanup set; the query process's own RSS is included here even though
        # it is deliberately excluded from `rows`. Each expected member's observed group
        # is validated against its recorded expected group so a reused or mismatched PID
        # cannot be silently accepted as a launch member.
        members = {}
        mismatched = []
        expected_groups = diag.get("expected_groups") or {}
        for pid in diag.get("expected_pids", ()):
            entry = all_rows.get(pid)
            if entry is None:
                continue
            group, rss = entry
            want_group = expected_groups.get(pid)
            if want_group is not None and group != want_group:
                mismatched.append(pid)
                continue
            members[pid] = rss
        diag["members"] = members
        diag["mismatched"] = mismatched
        diag["query_pid"] = ps_pid
        diag["query_rss_kib"] = all_rows.get(ps_pid, (None, None))[1]
    return rows

def _call_sampler(sampler, pgid: int, timeout_s: float, diag=None,
                  *, query_timing_out=None):
    """Synchronous sampler call; returns (rows, error)."""
    try:
        try:
            if query_timing_out is not None:
                # TIMING01: the enabled preview route invokes its sampler EXACTLY
                # once with timeout, diag and the private publication slot. A
                # TypeError raised here is reported by the existing single-call
                # error return below; it never probes for another signature.
                rows = sampler(pgid, timeout=timeout_s, diag=diag,
                               query_timing_out=query_timing_out)
            elif diag is not None:
                rows = sampler(pgid, timeout=timeout_s, diag=diag)
            else:
                rows = sampler(pgid, timeout=timeout_s)
        except TypeError:
            if query_timing_out is not None:
                raise
            rows = sampler(pgid)
    except Exception as exc:  # noqa: BLE001 - reported to the caller as monitoring data
        return None, str(exc) or type(exc).__name__
    if not isinstance(rows, dict):
        return None, "sampler returned a non-mapping"
    return rows, None


def _probe_group_identity(rows: dict) -> str | None:
    """Authoritative identity check for a probe observation (contract F03).

    Every pid the probe reports must currently resolve, through the kernel,
    to this supervisor's own process group. A mismatch is a monitoring
    failure and blocks launch; an unresolvable pid is never accepted.
    """
    my_pgrp = os.getpgrp()
    for pid in rows:
        try:
            observed_pgrp = os.getpgid(int(pid))
        except (ProcessLookupError, PermissionError, OSError, ValueError) as exc:
            return (f"probe observed pid {pid} that cannot be resolved to a "
                    f"group: {exc}")
        if observed_pgrp != my_pgrp:
            return (f"probe observed pid {pid} in group {observed_pgrp}, "
                    f"not the supervisor group {my_pgrp}")
    return None


def sample_bounded(sampler, pgid: int, timeout_s: float, diag=None):
    """One worker, with no positive floor or renewed join allowance."""
    end_ns = time.monotonic_ns() + int(timeout_s * 1e9)
    inner = timeout_s - SAMPLE_HANDOFF_S
    if inner <= 0:
        return None, "no time remaining before the applicable cutoff", False
    box = {}

    def work():
        try:
            remaining = (end_ns-time.monotonic_ns())/1e9-SAMPLE_HANDOFF_S
            box["value"] = (_call_sampler(sampler, pgid, remaining, diag=diag)
                            if remaining > 0
                            else (None, "sample budget exhausted before call"))
        except BaseException as exc:
            box["error"] = str(exc) or type(exc).__name__

    worker = threading.Thread(target=work, name="run_bounded-sample", daemon=True)
    worker.start()
    worker.join(max(0, end_ns-time.monotonic_ns())/1e9)
    if worker.is_alive() or time.monotonic_ns() > end_ns:
        return None, None, True
    if "error" in box:
        return None, box["error"], False
    rows, error = box.get("value", (None, "sampler returned no result"))
    return rows, error, False

def _due_event(now_ns, deadline_ns=None, fresh_ns=None, cancel=None):
    events = []
    if cancel is not None and cancel.is_set():
        events.append((CANCEL_AT_NS if CANCEL_AT_NS is not None else now_ns, 0, "cancel"))
    if deadline_ns is not None and now_ns >= deadline_ns:
        events.append((deadline_ns, 1, "deadline"))
    if fresh_ns is not None and now_ns >= fresh_ns:
        events.append((fresh_ns, 2, "freshness"))
    return min(events) if events else None


def _sample_responsive(sampler, pgid: int, budget_s: float, *,
                       cancel=None, deadline=None, fresh_until=None, diag=None,
                       timing_out=None) -> dict:
    started = time.monotonic_ns()
    end = started + max(0, int(budget_s * 1_000_000_000))
    if deadline is not None:
        end = min(end, deadline)
    if fresh_until is not None:
        end = min(end, fresh_until)
    box = {}
    worker = None
    abort = None
    # TIMING01: bracket/gap bookkeeping is enabled only for the controller-owned
    # summary and is derived from clocks this function ALREADY reads. No extra
    # sleep, check, join, wait, query or due-event precedence is introduced, and
    # the timing_out=None route keeps its exact prior call, arithmetic and
    # clock-read behavior.
    query_timing_out = None
    # TIMING01-FIX01: `gap_from`/`gap_to` are ONLY the retained maximum's
    # endpoints. `prev_reading` is the independent rolling previous-reading cursor
    # (also seeded from the existing `started` reading) that every comparison uses,
    # so a smaller or equal gap can never leave a stale reference behind.
    prev_reading = started
    gap_from = None
    gap_to = started
    max_gap = None
    last_loop_check = None
    start_check = None
    start_resume = None
    wait_check = None
    wait_resume = None
    start_pending = False
    wait_pending = False
    if timing_out is not None:
        # Existing locals copied unchanged: the local clipped end is the attempt's
        # cutoff fact and is never recomputed or extended here.
        timing_out["start_ns"] = started
        timing_out["cutoff_ns"] = end
        # Fresh private receiver for this attempt; its worker is the only writer.
        query_timing_out = {"snapshot": None}

    def work():
        remaining = (end - time.monotonic_ns()) / 1_000_000_000
        if remaining <= 0:
            box["value"] = (None, "sample budget exhausted before call")
        else:
            # TIMING01: with no receiver the expansion contributes no argument, so
            # the disabled call is the ORIGINAL call unchanged; only an enabled
            # attempt forwards the private single-slot publication receiver.
            call_kw = ({"query_timing_out": query_timing_out}
                       if query_timing_out is not None else {})
            box["value"] = _call_sampler(sampler, pgid, remaining, diag=diag,
                                         **call_kw)
        box["completed_ns"] = time.monotonic_ns()

    while True:
        now = time.monotonic_ns()
        if timing_out is not None:
            # Runs before any break so the loop-top reading that ends the loop is
            # still recorded; the final observed reading below never becomes
            # last_loop_check_ns. Zero is a legitimate equal-clock difference.
            last_loop_check = now
            # TIMING01-FIX01: ADJACENT difference against the immediately
            # preceding reading, never against the retained maximum's endpoint.
            # The maximum/endpoints change only on the first comparison or a
            # strictly greater difference (earliest pair survives a tie), then the
            # rolling cursor advances on EVERY reading — including smaller or equal
            # ones — so no later comparison can span an intervening check.
            gap = now - prev_reading
            if max_gap is None or gap > max_gap:
                max_gap = gap
                gap_from = prev_reading
                gap_to = now
            prev_reading = now
            if start_pending:
                start_resume = now
                start_pending = False
            if wait_pending:
                wait_resume = now
                wait_pending = False
        due = _due_event(now, deadline, fresh_until, cancel)
        if due:
            abort = due[2]
            break
        if now >= end:
            break
        if worker is None:
            if timing_out is not None:
                # Bracket opens on this existing loop-top reading, before Thread
                # construction/start, and closes on the next loop-top reading. It
                # measures a bracket, not Thread.start alone.
                start_check = now
                start_pending = True
            worker = threading.Thread(target=work, name="run_bounded-responsive-sample", daemon=True)
            worker.start()
            continue
        if not worker.is_alive():
            break
        # TIMING01: the EXISTING pre-join budget reading is captured once here and
        # reused by this same join expression — identical arithmetic and exactly one
        # clock read on either route — plus, when timing is enabled, its bracket
        # endpoint. Each new join replaces the prior wait pair, initially with
        # resume=None.
        joined_at = time.monotonic_ns()
        worker.join(min(SAMPLE_SLICE_S, max(0.0, (end-joined_at)/1_000_000_000)))
        if timing_out is not None:
            wait_check = joined_at
            wait_pending = True
    # Hold exactly ONE projection reference immediately before the existing final
    # observed read. The held object is a coherent earlier stage snapshot; a worker
    # that publishes later only replaces the slot value, so neither the held
    # projection nor the summary copied from it can be modified afterwards, and no
    # second join/wait/rendezvous for metadata ever occurs.
    held = (query_timing_out["snapshot"]
            if query_timing_out is not None else None)
    observed = time.monotonic_ns()
    due = _due_event(observed, deadline, fresh_until, cancel)
    if due:
        abort = due[2]
    unfinished = worker is None or worker.is_alive()
    late = observed >= end
    rows, err = box.get("value", (None, "sample unfinished"))
    result = {"rows": None if unfinished or abort or late else rows,
              "err": err, "timed_out": bool(unfinished or abort or late),
              "abort": abort, "elapsed_s": (observed-started)/1_000_000_000,
              "start_ns": started, "observed_ns": observed,
              "completed_ns": box.get("completed_ns")}
    if diag is not None:
        # PREVIEW01 FIX05: publish the EXISTING local clipped budget end unchanged as the
        # attempt's original cutoff fact (no recomputation/extension/new parameter). A
        # non-preview call (diag=None) keeps the exact prior dictionary shape.
        result["cutoff_ns"] = end
    if timing_out is not None:
        # TIMING01: written only AFTER the original due/timeout/row decisions above,
        # and never again after this return. Unreached stages stay None; a later
        # worker publication or a later phase cannot repair this retained summary.
        # TIMING01-FIX01: the final observed reading applies the same ADJACENT rule
        # against the rolling cursor (no new clock read): first comparison or
        # strictly greater only, so a tie keeps the earliest pair. The cursor needs
        # no advance after this last reading, and `observed` still never becomes
        # last_loop_check_ns.
        gap = observed - prev_reading
        if max_gap is None or gap > max_gap:
            max_gap = gap
            gap_from = prev_reading
            gap_to = observed
        timing_out["observed_ns"] = observed
        timing_out["controller"] = {
            "last_loop_check_ns": last_loop_check,
            "max_gap_ns": max_gap,
            "max_gap_from_ns": gap_from,
            "max_gap_to_ns": gap_to,
            "start_check_ns": start_check,
            "start_resume_ns": start_resume,
            "wait_check_ns": wait_check,
            "wait_resume_ns": wait_resume,
        }
        if held is not None:
            # Fixed scalar copies from the held projection; never live worker meta.
            query = timing_out["query"]
            for key in query:
                query[key] = held.get(key)
    return result


def try_reap(pid: int, blocking: bool = False):
    try:
        got, status, usage = os.wait4(pid, 0 if blocking else os.WNOHANG)
    except ChildProcessError:
        return "gone", None, None
    if got == 0:
        return "running", None, None
    return "reaped", status, usage


def _stop_origin(state: dict) -> int:
    if state.get("s_ns") is None:
        state["s_ns"] = time.monotonic_ns()
        state["stop_origin"] = state["s_ns"] / 1_000_000_000
    return state["s_ns"]


def send_group(pgid: int, sig: int, state: dict) -> bool:
    origin = _stop_origin(state)
    event = {"signal": signal.Signals(sig).name, "pgid": pgid,
             "attempt_ns": time.monotonic_ns(), "ok": False}
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        event["result"] = "nonexistent"
    except PermissionError:
        event["result"] = "denied"
    except OSError as exc:
        event["result"] = f"error: {exc}"
    else:
        event.update(result="sent", ok=True)
        if event["signal"] not in state["signals"]:
            state["signals"].append(event["signal"])
    event["completed_ns"] = time.monotonic_ns()
    event["at_stop_ms"] = (event["attempt_ns"] - origin) / 1_000_000
    event["at_monotonic_ms"] = event["attempt_ns"] / 1_000_000
    event["completed_ms"] = (event["completed_ns"] - origin) / 1_000_000
    state["signal_events"].append(event)
    bound = TERM_DISPATCH_TARGET_MS if sig == signal.SIGTERM else KILL_HARD_MS
    event["lateness_ns"] = event["completed_ns"] - origin - bound * 1_000_000
    if event["lateness_ns"] > 0:
        state["cutoff_misses"].append(f"{event['signal']} late by {event['lateness_ns']}ns")
    if event["result"] not in ("sent", "nonexistent"):
        state["sample_errors"].append(f"dispatch {pgid}: {event['result']}")
    return event["ok"]


def _group_state(pgid: int) -> str:
    """Direct kernel existence check for an owned group (no subprocess).

    Returns "gone", "exists" or "unknown". A permission/unknown result is
    never treated as proof of emptiness (Architect r2 Task 2).
    """
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return "gone"
    except PermissionError:
        return "exists"
    except OSError:
        return "unknown"
    return "exists"


def verify_group_empty(pgid: int, verifier, end_ns: int | None = None,
                       diag=None) -> tuple:
    if end_ns is None:
        end_ns = time.monotonic_ns() + VERIFY_ALLOWANCE_MS * 1_000_000
    remaining = (end_ns - time.monotonic_ns()) / 1_000_000_000
    if remaining <= 0:
        return None, "verification budget exhausted"
    rows, error, timed_out = sample_bounded(verifier, pgid, remaining, diag=diag)
    if timed_out or time.monotonic_ns() > end_ns:
        return None, "verification cutoff missed"
    if error or rows is None:
        return None, error or "verification unknown"
    return list(rows), None


def _direct_stop(pid: int, groups: list, state: dict, proc=None) -> None:
    """Safety path only: no reporting, sampling, workers or renewed clocks."""
    s = _stop_origin(state)
    state.setdefault("termination_start_ns", s)
    end = s + TERMINATION_END_MS * 1_000_000
    kill_target = s + KILL_TARGET_MS * 1_000_000
    state["termination_deadline_ns"] = end
    state["kill_target_ns"] = kill_target
    state["kill_deadline_ns"] = s + KILL_HARD_MS * 1_000_000
    for gid in groups:
        if not any(e["pgid"] == gid and e["signal"] == "SIGTERM"
                   for e in state["signal_events"]):
            send_group(gid, signal.SIGTERM, state)
    if state.pop("terminate_fault", False):
        raise _PostLaunchFault("injected coordinator fault after TERM")
    while True:
        now = time.monotonic_ns()
        if not state.get("reaped"):
            try:
                if proc is None:
                    outcome, status, usage = try_reap(pid)
                    if outcome == "reaped":
                        _store_reap(state, status, usage, observed_by="cleanup")
                        state["reaped_at_ns"] = time.monotonic_ns()
                else:
                    code = proc.poll()
                    if code is not None:
                        state.update(reaped=True, inner_exit=code,
                                     reaped_at_ns=time.monotonic_ns())
            except Exception as exc:
                _note_sample_error(state, f"reap failed: {type(exc).__name__}: {exc}")
        remaining_groups = []
        for gid in groups:
            existence = _group_state(gid)
            if existence == "unknown":
                _note_sample_error(state, f"group {gid} existence unknown")
            if existence != "gone":
                remaining_groups.append(gid)
        if not remaining_groups and state.get("reaped"):
            break
        if now >= kill_target:
            for gid in remaining_groups:
                if not any(e["pgid"] == gid and e["signal"] == "SIGKILL"
                           for e in state["signal_events"]):
                    send_group(gid, signal.SIGKILL, state)
        if time.monotonic_ns() >= end:
            state["cutoff_misses"].append("termination deadline reached before completion")
            break
        wake = min(end, kill_target) if now < kill_target else end
        time.sleep(max(0.0, min(SAMPLE_SLICE_S,
                               (wake - time.monotonic_ns()) / 1_000_000_000)))
    state["termination_end_ns"] = time.monotonic_ns()
    if state["termination_end_ns"] > end:
        state["cutoff_misses"].append("termination completed after cutoff")
    state["reap_failed"] = not state.get("reaped", False)


def stop_group(pid: int, pgid: int, sampler, state: dict, observed_members: set) -> None:
    _direct_stop(pid, [pgid], state)
    state["cleanup_elapsed_ms"] = (state["termination_end_ns"] - state["s_ns"]) / 1_000_000
    state["survivors_after"] = None
    state["cleanup_samples"] = 0



def _emergency_stop(pid, groups, state, proc=None):
    """Remaining direct actions after a coordinator failure; retain original S."""
    s = _stop_origin(state)
    end = s + 4_000_000_000
    for sig, target in ((signal.SIGTERM, s), (signal.SIGKILL, s+1_750_000_000)):
        while time.monotonic_ns() < min(target, end):
            time.sleep(min(0.005, max(0.0, (target-time.monotonic_ns())/1e9)))
        for gid in groups:
            if any(e["pgid"] == gid and e["signal"] == signal.Signals(sig).name
                   for e in state["signal_events"]):
                continue
            event = {"pgid": gid, "signal": signal.Signals(sig).name,
                     "attempt_ns": time.monotonic_ns(), "ok": False}
            try:
                os.killpg(gid, sig)
            except ProcessLookupError:
                event["result"] = "nonexistent"
            except OSError as exc:
                event["result"] = f"error: {exc}"
                state["sample_errors"].append(event["result"])
            else:
                event.update(ok=True, result="sent")
                state["signals"].append(event["signal"])
            event["completed_ns"] = time.monotonic_ns()
            limit = 50_000_000 if sig == signal.SIGTERM else 2_000_000_000
            event["lateness_ns"] = event["completed_ns"]-s-limit
            event["at_stop_ms"] = (event["attempt_ns"]-s)/1e6
            event["completed_ms"] = (event["completed_ns"]-s)/1e6
            event["at_monotonic_ms"] = event["attempt_ns"]/1e6
            state["signal_events"].append(event)
            if event["lateness_ns"] > 0:
                state["cutoff_misses"].append("emergency signal cutoff missed")
    while not state.get("reaped") and time.monotonic_ns() < end:
        try:
            got, status, usage = os.wait4(pid, os.WNOHANG)
            if got == pid:
                if proc is None:
                    _store_reap(state, status, usage, observed_by="cleanup")
                else:
                    proc.returncode = os.waitstatus_to_exitcode(status)
                    state.update(reaped=True, inner_exit=proc.returncode)
                state["reaped_at_ns"] = time.monotonic_ns()
                break
        except ChildProcessError:
            if proc is not None and proc.returncode is not None:
                state.update(reaped=True, inner_exit=proc.returncode,
                             reaped_at_ns=time.monotonic_ns())
            break
        except OSError as exc:
            state["sample_errors"].append(f"emergency wait: {exc}")
            break
        time.sleep(min(0.005, max(0.0, (end-time.monotonic_ns())/1e9)))
    state["termination_start_ns"] = s
    state["termination_deadline_ns"] = end
    state["termination_end_ns"] = time.monotonic_ns()
    state["reap_failed"] = not state.get("reaped")
    if state["termination_end_ns"] > end:
        state["cutoff_misses"].append("emergency termination cutoff missed")


def _note_sample_error(state: dict, message: str) -> None:
    if message not in state["sample_errors"]:
        state["sample_errors"].append(message)


def record_cleanup(launched: bool, state: dict, verifier_error, synthetic: bool) -> dict:
    """Build the fail-closed cleanup record (contract 1).

    ok requires: the owned child was reaped, no cleanup/verification errors
    were recorded, and the final verifier positively returned an empty list.
    Unknown verification (None) is never ok.
    """
    if not launched:
        return {
            "attempted": False,
            "ok": True,
            "verified": None,
            "errors": [],
            "reaped": False,
            "synthetic": False,
            "note": "pre-launch refusal; no owned group existed",
        }
    verified = state.get("survivors_verified")
    errors = list(state.get("sample_errors", []))
    if verifier_error:
        errors.append(verifier_error)
    reaped = bool(state.get("reaped"))
    ok = reaped and not errors and verified == []
    if not reaped:
        note = "owned child was not reaped"
    elif verified is None:
        note = "final verification unknown; not treated as empty"
    elif verified != []:
        note = f"final verification reported {len(verified)} member(s)"
    elif errors:
        note = "cleanup errors present despite empty verification"
    else:
        note = "child reaped and owned group verified empty"
    return {
        "attempted": True,
        "ok": ok,
        "verified": verified,
        "errors": errors,
        "reaped": reaped,
        "synthetic": synthetic,
        "note": note,
    }


class _Capture:
    """Bounded child-output capture with a size cap and total accounting."""

    __slots__ = ("limit", "total", "buf", "lock",
                 "fatal_markers", "fatal_hit", "_fatal_tails", "_fatal_keep")

    def __init__(self, limit: int, fatal_markers=None) -> None:
        self.limit = limit
        self.total = 0
        self.buf = bytearray()
        self.lock = threading.Lock()
        # PREVIEW01: bounded fatal-marker scan with SEPARATE suffix state per output
        # stream, so interleaved stdout/stderr can never corrupt continuity or fabricate
        # a cross-stream marker. Matching is case-insensitive, a shared latch records the
        # fact, and the scan is independent of the capture cap.
        self.fatal_markers = tuple(fatal_markers or ())
        self.fatal_hit = False
        self._fatal_tails = {}
        self._fatal_keep = max((len(m) for m in self.fatal_markers), default=1) - 1

    def feed(self, data: bytes, stream: str = "stdout") -> None:
        with self.lock:
            self.total += len(data)
            room = self.limit - len(self.buf)
            if room > 0:
                self.buf.extend(data[:room])
            if self.fatal_markers and not self.fatal_hit:
                tail = self._fatal_tails.get(stream, b"")
                hay = (tail + data).upper()
                if any(marker in hay for marker in self.fatal_markers):
                    self.fatal_hit = True
                elif self._fatal_keep > 0:
                    self._fatal_tails[stream] = hay[-self._fatal_keep:]
                else:
                    self._fatal_tails[stream] = b""

    def snapshot(self, timeout_s: float | None = None) -> tuple:
        """Bounded snapshot: (data, total, ok). Never waits indefinitely.

        Architect r2 Task 2: failing to obtain the capture lock inside the
        remaining collection budget is reported as incomplete output, never
        as a successful empty capture.
        """
        if timeout_s is None:
            ok = self.lock.acquire(timeout=None)
        else:
            ok = self.lock.acquire(timeout=max(0.0, timeout_s))
        if not ok:
            return None, None, False
        try:
            return bytes(self.buf), self.total, True
        finally:
            self.lock.release()


def _close_quietly(files: list) -> None:
    for handle in files:
        try:
            handle.close()
        except Exception:  # noqa: BLE001 - closing is best effort after a finished read
            pass


def _pump_fd(fd: int, capture: _Capture, errors: list, stream: str = "stdout") -> None:
    """Pump one pipe into the bounded capture; read errors are recorded."""
    try:
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            capture.feed(chunk, stream)
    except OSError as exc:
        errors.append(f"reader error: {exc}")


def start_readers(proc, capture: _Capture, mode: str, errors: list,
                  holder: dict | None = None) -> dict:
    """Start output readers after a successful launch.

    mode: "normal" pumps the pipes, "fail_start" injects a reader setup
    failure (no thread is created), "partial_fail" starts the first reader
    then fails (the partial state is preserved in holder), "fail_mid" starts
    both readers and injects a read error part-way through, and "stuck"
    starts synthetic threads that never touch the pipes so the bounded-join
    guard can be asserted without creating a real blocked read. All threads
    are daemons.

    R03 contract F02: whatever was started before an exception is reported
    through holder["state"], so the caller can retain partial reader state
    instead of discarding it. Reader read errors are collected in errors and
    make the drain incomplete.
    """
    state = {"threads": [], "files": [f for f in (proc.stdout, proc.stderr) if f is not None],
             "started": False, "errors": errors}
    if holder is not None:
        holder["state"] = state
    if mode == "fail_start":
        raise RuntimeError("injected reader-start failure (diagnostic)")
    files = [f for f in (proc.stdout, proc.stderr) if f is not None]
    state["files"] = files
    if mode == "stuck":
        def _stuck() -> None:
            time.sleep(STUCK_READER_SECONDS)
        for _handle in files:
            worker = threading.Thread(target=_stuck, name="run_bounded-stuck-reader", daemon=True)
            worker.start()
            state["threads"].append(worker)
        state["started"] = True
        return state
    if mode == "partial_fail":
        # First reader is created, then the setup fails: partial state must
        # be retained by the caller (contract F02 partial reader-start case).
        if files:
            fd = files[0].fileno()
            worker = threading.Thread(target=_pump_fd, args=(fd, capture, errors, "stdout"),
                                       name="run_bounded-reader", daemon=True)
            worker.start()
            state["threads"].append(worker)
        state["started"] = bool(state["threads"])
        errors.append("reader setup failed: injected partial reader-start failure (diagnostic)")
        raise RuntimeError("injected partial reader-start failure (diagnostic)")
    for index, handle in enumerate(files):
        fd = handle.fileno()
        pump_errors = errors
        stream = "stdout" if index == 0 else "stderr"
        if mode == "fail_mid" and index == 0:
            def _pump_mid(fd: int = fd) -> None:
                try:
                    chunk = os.read(fd, 65536)
                    if chunk:
                        capture.feed(chunk, "stdout")
                    raise OSError("injected mid-read failure (diagnostic)")
                except OSError as exc:
                    pump_errors.append(f"reader error: {exc}")
            worker = threading.Thread(target=_pump_mid, name="run_bounded-reader",
                                       daemon=True)
        else:
            worker = threading.Thread(target=_pump_fd,
                                       args=(fd, capture, pump_errors, stream),
                                       name="run_bounded-reader", daemon=True)
        worker.start()
        state["threads"].append(worker)
    state["started"] = True
    if holder is not None:
        holder["state"] = state
    return state


def collect_output(state: dict, budget_s: float = COLLECT_JOIN_SECONDS, *, end_ns=None) -> tuple:
    """Bounded output collection; the main thread never waits indefinitely.

    Returns (join_ms, incomplete, detail). Pipes are closed only when no
    reader can still be inside a stream operation. R03 contract F02: any
    recorded reader read error makes the drain incomplete - an errored read
    is never treated as a successful drain.
    """
    started = time.monotonic_ns()
    deadline = end_ns if end_ns is not None else started + int(budget_s*1e9)
    for worker in [t for t in state["threads"] if t.is_alive()]:
        remaining = (deadline - time.monotonic_ns())/1e9
        if remaining <= 0:
            break
        worker.join(remaining)
    join_ms = (time.monotonic_ns()-started)/1e6
    if time.monotonic_ns() > deadline:
        return join_ms, True, "collection deadline exceeded"
    if not state["started"]:
        _close_quietly(state["files"])
        return join_ms, True, "reader never started; stream state unknown"
    alive = [t for t in state["threads"] if t.is_alive()]
    if alive:
        return (join_ms, True,
                f"{len(alive)} reader(s) still alive after {join_ms}ms; "
                "drain incomplete (pipes left open on purpose)")
    _close_quietly(state["files"])
    errors = [str(e) for e in state.get("errors", []) if e]
    if errors:
        return (join_ms, True,
                "reader errors during drain: " + "; ".join(errors[:3]))
    return join_ms, False, ""


REASON_EXIT = {
    "ok": EXIT_OK,
    "child": EXIT_CHILD,
    "usage": EXIT_USAGE,
    "bad_command": EXIT_USAGE,
    "monitoring": EXIT_MONITORING,
    "wall": EXIT_WALL,
    "rss": EXIT_RSS,
    "cpu": EXIT_CPU,
    "cancelled": EXIT_CANCELLED,
}


def classify(mon: dict, child_box: dict, launched: bool) -> tuple:
    """Pick the reason/exit for a run before the cleanup override.

    R03 contract F04/F05: the child's observed wait status comes from the
    single shared decoder (state['exit_code']/['signal']), so classification
    reads the same interpreted result whether the monitor or the cleanup reap
    observed it. Cancellation and wall expiry are honoured even when launch
    was skipped (a cancelled probe never launches).
    """
    if mon.get("monitoring_failure"):
        return "monitoring", EXIT_MONITORING
    if mon.get("preview_fatal"):
        # PREVIEW01: fatal script/engine output is a preview failure, reported distinctly
        # from a crash or a labeled operating stop, and never accepted as play.
        return "fatal", EXIT_INTERNAL
    if mon.get("preview_aggregate_stop"):
        # PREVIEW01: the preview-only observed aggregate-RSS early stop is a labeled
        # operating stop, reported distinctly from a crash or a completion.
        return "rss", EXIT_RSS
    if mon.get("cancel"):
        return "cancelled", EXIT_CANCELLED
    if mon.get("wall"):
        return "wall", EXIT_WALL
    if mon.get("rss"):
        return "rss", EXIT_RSS
    if not launched:
        return "monitoring", EXIT_MONITORING
    sig = child_box.get("signal")
    if sig is not None:
        if sig in (signal.SIGXCPU, getattr(signal, "SIGXCPU2", signal.SIGXCPU)):
            return "cpu", EXIT_CPU
        return "child", EXIT_CHILD
    exit_code = child_box.get("exit_code")
    if exit_code is None:
        return "internal", EXIT_INTERNAL
    if exit_code == 0:
        return "ok", EXIT_OK
    return "child", EXIT_CHILD


def install_signal_handlers() -> None:
    def _handler(signum, _frame) -> None:
        global CANCEL_AT, CANCEL_AT_NS
        if CANCEL_AT_NS is None:
            CANCEL_AT_NS = time.monotonic_ns()
            CANCEL_AT = CANCEL_AT_NS / 1_000_000_000
        CANCEL.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, _handler)
        except (OSError, ValueError):
            pass


def write_record(path: str, payload: dict) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def write_record_once(path: str, payload: dict, *, end_ns=None) -> dict:
    """One primary and one fallback; no caller wait exceeds the original cutoff.

    A persisted payload precedes its own write completion. Its sink state is
    explicitly pending; the enclosing controller/returned status owns the
    final sink verdict. A timed-out writer is unknown, never retried.
    """
    started = time.monotonic_ns()
    result = {"primary_ok": False, "fallback_ok": False, "primary_error": None,
              "fallback_error": None, "path": None, "started_ns": started,
              "completed_ns": None, "late": False, "writer_pending": False}
    if end_ns is None:
        end_ns = started+2_000_000_000
    try:
        saved = dict(payload)
        saved["sink"] = {"status": "pending at serialization",
                         "final_status_owner": "enclosing controller or caller"}
        if "passed" in saved:
            saved["pre_sink_predicates_passed"] = saved["passed"]
            saved["passed"] = False
        data = (json.dumps(saved, indent=2, sort_keys=True)+"\n").encode()
    except Exception as exc:
        result["primary_error"] = f"serialization failed: {exc}"
        result["completed_ns"] = time.monotonic_ns()
        result["late"] = result["completed_ns"] > end_ns
        return result
    for label, target in (("primary", path), ("fallback", path+".fallback.json")):
        if time.monotonic_ns() >= end_ns:
            result[label+"_error"] = "evidence budget exhausted"
            break
        if label == "fallback":
            saved["sink"] = {**result, "status": "fallback pending at serialization",
                             "final_status_owner": "enclosing controller or caller"}
            data = (json.dumps(saved, indent=2, sort_keys=True)+"\n").encode()
        box = {}
        def write(target=target):
            try:
                os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
                with open(target, "xb") as handle:
                    handle.write(data)
                    handle.flush()
                box["ok"] = True
            except Exception as exc:
                box["error"] = f"{type(exc).__name__}: {exc}"
            finally:
                box["completed_ns"] = time.monotonic_ns()
        worker = threading.Thread(target=write, name="run_bounded-evidence", daemon=True)
        try:
            worker.start()
            worker.join(max(0, end_ns-time.monotonic_ns())/1e9)
        except Exception as exc:
            result[label+"_error"] = f"evidence worker failed: {exc}"
            result["writer_pending"] = worker.is_alive()
            break
        if worker.is_alive():
            result[label+"_error"] = "evidence write completion unknown"
            result["writer_pending"] = True
            break
        if box.get("ok") and box["completed_ns"] <= end_ns:
            result[label+"_ok"], result["path"] = True, target
            break
        result[label+"_error"] = box.get("error", "evidence write completed late")
        if box.get("ok"):
            break
    result["completed_ns"] = time.monotonic_ns()
    result["late"] = result["completed_ns"] > end_ns
    return result


def _elapsed_value(seconds: float) -> float:
    return round(seconds, 3) if seconds >= 0.05 else seconds


def emit_child_output(result: dict, enabled: bool) -> None:
    if enabled:
        head = str(result.get("output", {}).get("head", ""))
        if head:
            result["child_output_report"] = _report_text(
                head, sys.stdout, result.get("evidence_deadline_ns"))


def result_line(result: dict) -> str:
    peak_kib = int(result.get("peak_rss_kib", 0) or 0)
    output = result.get("output", {})
    cleanup = result.get("cleanup", {})
    drained = "ok" if not result.get("drain_incomplete") else "incomplete"
    monitoring = result.get("monitoring_failure")
    monitoring_text = monitoring if monitoring else "None"
    return (
        f"RESULT reason={result.get('reason')} exit={result.get('exit_code')} "
        f"elapsed_s={_elapsed_value(float(result.get('elapsed_seconds', 0.0)))} "
        f"peak_rss_mib={peak_kib / 1024:.2f} "
        f"samples={int(result.get('samples', 0) or 0)} "
        f"output={int(output.get('captured_bytes', 0))}/{int(output.get('total_bytes', 0))} "
        f"launched={bool(result.get('child', {}).get('launched'))} "
        f"survivors={cleanup.get('verified')!r} "
        f"monitoring={monitoring_text} "
        f"cleanup={'ok' if cleanup.get('ok') else 'fail'} drain={drained}"
    )


def _decode_wait(status, usage) -> dict:
    """Single wait-status decoder for every reap (R03 contract F04).

    Used by both the monitoring loop and the cleanup reap so exit code,
    signal and CPU time are interpreted in exactly one place, with the
    observer recorded alongside the observed result.
    """
    decoded = {
        "observed_by": None,
        "exited": False,
        "exit_code": None,
        "signaled": False,
        "signal": None,
        "cpu_seconds": None,
    }
    if status is None:
        return decoded
    if os.WIFEXITED(status):
        decoded["exited"] = True
        decoded["exit_code"] = os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        decoded["signaled"] = True
        decoded["signal"] = os.WTERMSIG(status)
    if usage is not None:
        decoded["cpu_seconds"] = round(usage[0] + usage[1], 3)
    return decoded


def _store_reap(state: dict, status, usage, observed_by: str) -> None:
    state["reaped"] = True
    state["status"] = status
    state["usage"] = usage
    decoded = _decode_wait(status, usage)
    decoded["observed_by"] = observed_by
    state["reap"] = decoded
    state["exit_code"] = decoded["exit_code"]
    state["signal"] = decoded["signal"]


def _monitor_loop(pid: int, pgid: int, *, deadline: int, poll_s: float, sampler,
                  rss_mib, cancellable: bool, state: dict, sampling: dict,
                  observed_members: set, monitor_start: int, diag=None,
                  fatal=None, preview_policy=False) -> dict:
    freshness_ms = (PREVIEW_FRESHNESS_BOUND_MS if preview_policy
                    else FRESHNESS_BOUND_MS)
    freshness_ns = freshness_ms * 1_000_000
    decision_ns = freshness_ns - FRESHNESS_DECISION_LEAD_MS * 1_000_000
    agg = None
    if diag is not None:
        # PREVIEW01: separate diagnostic launch-set aggregate; never the authoritative
        # engine peak/rows or the signal/cleanup set. Bounded phase summaries only, no
        # unbounded log. Retained-outer accounting at outer verification is not possible
        # within existing observations (no RSS column) and stays an explicit gap.
        agg = {"metric": "observed_aggregate_rss_kib_x1024",
               "threshold_bytes": PREVIEW_AGG_RSS_BYTES,
               "roles": dict(diag.get("roles", {})),
               "role_of": dict(diag.get("role_of", {})),
               "expected_pids": sorted(diag.get("expected_pids", ())),
               "expected_groups": dict(diag.get("expected_groups", {})),
               "samples": 0, "members": {}, "mismatched": [], "missing": [],
               "query_pid": None, "query_rss_kib": None,
               "observed_bytes": 0, "peak_bytes": 0,
               "stopped": False, "stop_source": None,
               "engine_group_rss_stop": False, "fatal_stop": False,
               "phase": "runtime", "phases": {}, "gaps": []}
    mon = {"wall": False, "rss": False, "cancel": False,
           "monitoring_failure": None, "peak_rss_kib": 0, "preview_aggregate": agg}
    valid = monitor_start
    period = min(int(poll_s * 1_000_000_000), 100_000_000)
    next_due = monitor_start
    sampling.update(clock="monotonic_ns", m_ns=monitor_start,
                    applied_period_ns=period, observations=[], max_age_ms=None,
                    max_gap_ms=None)
    if diag is not None:
        # TIMING01: exactly one preview-runtime field, initialized None when this
        # preview monitor starts and never populated if no runtime attempt occurs.
        # Ordinary diag=None monitors keep their exact prior dictionary shape.
        sampling["last_attempt_timing"] = None

    def due_now(now):
        hard = valid + freshness_ns
        target = valid + decision_ns
        event = _due_event(now, deadline, target, CANCEL if cancellable else None)
        if not event:
            return False
        if now > hard and event[2] != "freshness":
            state["cutoff_misses"].append(f"freshness detection late by {now-hard}ns")
        state["primary_event_ns"], _, kind = event
        tied = []
        if cancellable and CANCEL.is_set() and (CANCEL_AT_NS or now) == event[0]:
            tied.append("cancel")
        if deadline == event[0]:
            tied.append("deadline")
        if target == event[0]:
            tied.append("freshness")
        sampling["selected_event"] = {"scheduled_ns": event[0], "detected_ns": now,
                                     "kind": kind, "tied_kinds": tied}
        _stop_origin(state)
        if kind == "cancel":
            mon["cancel"] = True
        elif kind == "deadline":
            mon["wall"] = True
        else:
            mon["monitoring_failure"] = "sampling freshness early refusal" if now <= hard else "sampling freshness hard cutoff missed"
            fact = {"origin_ns": valid, "cutoff_ns": hard, "decision_ns": target,
                    "detected_ns": now, "lateness_ns": now-hard,
                    "early_refusal": now <= hard, "bound_ms": freshness_ms}
            sampling["freshness_breaches"].append(fact)
            sampling["freshness_detected_ms"] = (now-monitor_start)/1_000_000
            sampling["freshness_cutoff_ms"] = (hard-monitor_start)/1_000_000
            if now > hard:
                sampling["breaches"].append(fact)
                state["cutoff_misses"].append(f"freshness detection late by {now-hard}ns")
        return True

    while True:
        if due_now(time.monotonic_ns()):
            break
        if fatal is not None and fatal():
            # PREVIEW01: a fatal marker already seen in the bounded capture stops the run
            # promptly through the retained stop coordinator; due-event/cutoff precedence
            # above is preserved and no extra reader or unbounded buffer is used.
            mon["preview_fatal"] = True
            if agg is not None:
                agg["fatal_stop"] = True
                agg["stop_source"] = "fatal_output"
            _stop_origin(state)
            break
        outcome, status, usage = try_reap(pid)
        if outcome == "reaped":
            _store_reap(state, status, usage, observed_by="monitor")
            state["reaped_at_ns"] = time.monotonic_ns()
            due_now(time.monotonic_ns())
            _stop_origin(state)
            break
        now = time.monotonic_ns()
        if due_now(now):
            break
        decision = valid + decision_ns
        if now < next_due:
            wake = min(next_due, deadline, decision)
            time.sleep(max(0.0, min(SAMPLE_SLICE_S, (wake-now)/1_000_000_000)))
            continue
        scheduled_due = next_due + ((now-next_due)//period)*period
        next_due = scheduled_due+period
        remaining = min(deadline, decision)-now
        sampling["attempts"] += 1
        timing_out = None
        if diag is not None:
            # TIMING01: a fresh controller-owned summary for THIS attempt, stored as
            # the latest slot before the responsive call (replacement, never a list).
            # Every key exists from allocation, so unreached stages stay None and a
            # later attempt simply replaces this object.
            timing_out = {
                "attempt_index": sampling["attempts"] - 1,
                "scheduled_due_ns": scheduled_due,
                "prior_v_ns": valid,
                "policy_cutoff_ns": min(deadline, decision),
                "start_ns": None, "cutoff_ns": None, "observed_ns": None,
                "controller": {"last_loop_check_ns": None, "max_gap_ns": None,
                               "max_gap_from_ns": None, "max_gap_to_ns": None,
                               "start_check_ns": None, "start_resume_ns": None,
                               "wait_check_ns": None, "wait_resume_ns": None},
                "query": {"entry_ns": None, "deadline_ns": None,
                          "cutoff_ns": None, "popen_return_ns": None,
                          "capture_stop_ns": None, "capture_stop_reason": None,
                          "function_return_ns": None, "reap_confirmed": None,
                          "error": None},
            }
            sampling["last_attempt_timing"] = timing_out
        # TIMING01: with no summary the expansion contributes no argument, so the
        # ordinary diag=None path keeps the ORIGINAL responsive call unchanged;
        # only this preview attempt opts in to the controller-owned summary.
        timing_kw = ({"timing_out": timing_out} if timing_out is not None else {})
        sample = _sample_responsive(sampler, pgid, remaining/1_000_000_000,
                cancel=CANCEL if cancellable else None, deadline=deadline,
                fresh_until=decision, diag=diag, **timing_kw)
        now = time.monotonic_ns()
        sample["scheduled_due_ns"] = scheduled_due
        sampling["observations"].append(sample)
        if sample["timed_out"]:
            sampling["unfinished"] += 1
            sampling["unfinished_ages_ms"].append(sample["elapsed_s"]*1000)
            sampling["unfinished_reasons"].append(sample["abort"] or "budget_timeout")
        if due_now(now):
            break
        if sample["timed_out"] or sample["rows"] is None:
            mon["monitoring_failure"] = sample["err"] or "runtime sampler incomplete"
            _stop_origin(state)
            break
        rows = sample["rows"]
        # No completion can reset V until the original raw event checks pass.
        sampling["count"] += 1
        sample["accepted_ns"] = now
        sample_ms = (now-monitor_start)/1_000_000
        if sampling["first_sample_ms"] is None:
            sampling["first_sample_ms"] = sample_ms
        sampling["last_sample_ms"] = sample_ms
        sampling["last_age_ms"] = (now-sample["start_ns"])/1_000_000
        sampling["max_age_ms"] = max(sampling["max_age_ms"] or 0, sampling["last_age_ms"])
        sampling["max_gap_ms"] = max(sampling["max_gap_ms"] or 0, (now-valid)/1_000_000)
        valid = now
        sampling["v_ns"] = valid
        if next_due <= now:
            next_due += ((now-next_due)//period+1)*period
        observed_members.update(member for member in rows if member != pid)
        total = sum(rows.values())
        mon["peak_rss_kib"] = max(mon["peak_rss_kib"], total)
        if agg is not None:
            # PREVIEW01: one observation, deduplicated by PID. Engine-group rows plus the
            # recorded live controllers and the query process when its row is present.
            members = {m: int(v) for m, v in rows.items()}
            for m, v in (diag.get("members") or {}).items():
                members[m] = int(v)
            if diag.get("query_rss_kib") is not None:
                members[diag.get("query_pid")] = int(diag["query_rss_kib"])
            agg["samples"] += 1
            agg["members"] = members
            agg["sample_ms"] = sample_ms
            agg["query_pid"] = diag.get("query_pid")
            agg["query_rss_kib"] = diag.get("query_rss_kib")
            agg["observed_bytes"] = sum(members.values()) * 1024
            mismatched = sorted(diag.get("mismatched") or ())
            missing = sorted(p for p in agg["expected_pids"] if p not in members)
            agg["mismatched"] = mismatched
            if missing or mismatched:
                # A failed/unqualified observation never advances the retained usable
                # runtime peak; its raw values stay as diagnostics only.
                agg["missing"] = missing
                detail = []
                if missing:
                    detail.append("missing " + ",".join(str(p) for p in missing))
                if mismatched:
                    detail.append("wrong-group " + ",".join(str(p) for p in mismatched))
                mon["monitoring_failure"] = ("preview launch-set accounting "
                                             + "; ".join(detail))
                _stop_origin(state)
                break
            # Complete, correctly attributed runtime observation: usable measurement.
            agg["peak_bytes"] = max(agg["peak_bytes"], agg["observed_bytes"])
        # Evaluate BOTH RSS conditions from this SAME observation before selecting the
        # existing primary precedence, so a simultaneous crossing keeps both causes.
        aggregate_crossed = (agg is not None
                             and agg["observed_bytes"] >= PREVIEW_AGG_RSS_BYTES)
        engine_group_crossed = (rss_mib is not None
                                and total > int(rss_mib) * 1024)
        if agg is not None:
            # F3: record the numeric cause (bytes) AND the accepted rows/members for each
            # crossing from the SAME observation, so acceptance can reconcile the scalar
            # totals against the actual evidence rather than trusting a supplied integer.
            agg["aggregate_crossed"] = aggregate_crossed
            agg["engine_group_crossed"] = engine_group_crossed
            agg["crossing_observed_bytes"] = agg["observed_bytes"]
            agg["engine_group_bytes"] = int(total) * 1024 if rss_mib is not None else None
            agg["engine_group_threshold_bytes"] = (int(rss_mib) * 1024 * 1024
                                                   if rss_mib is not None else None)
            agg["engine_group_total_kib"] = int(total) if rss_mib is not None else None
            if aggregate_crossed:
                agg["crossing_members"] = dict(members)
            if engine_group_crossed:
                agg["crossing_engine_rows"] = {int(k): int(v) for k, v in rows.items()}
        if aggregate_crossed:
            agg["stopped"] = True
            agg["stop_source"] = "aggregate_750mib"
            mon["preview_aggregate_stop"] = True
        if engine_group_crossed:
            mon["rss"] = True
            if agg is not None:
                # Distinguish the retained engine-group per-process 512MiB stop from the
                # launch-set aggregate 750MiB stop; the source is recorded, not inferred.
                agg["engine_group_rss_stop"] = True
                if agg.get("stop_source") is None:
                    agg["stop_source"] = "engine_group_512mib"
        if aggregate_crossed or engine_group_crossed:
            _stop_origin(state)
            break
        if not rows:
            outcome, status, usage = try_reap(pid)
            if outcome == "reaped":
                _store_reap(state, status, usage, observed_by="monitor")
                state["reaped_at_ns"] = time.monotonic_ns()
                due_now(time.monotonic_ns())
            elif not due_now(time.monotonic_ns()):
                mon["monitoring_failure"] = "owned group not visible to sampler"
            _stop_origin(state)
            break
    sampling["monitor_end_ns"] = time.monotonic_ns()
    sampling["tail_origin_ns"] = valid
    sampling["tail_age_ns"] = sampling["monitor_end_ns"]-valid
    sampling["tail_age_ms"] = sampling["tail_age_ns"]/1_000_000
    return mon


GATE_ENV_KEYS = ("RB_GATE_REG_FD", "RB_GATE_ACK_FD", "RB_GATE_TOKEN",
                 "RB_GATE_CASE")


def _gate_context() -> tuple:
    """Read and validate the inherited diagnostic-owner gate context.

    Returns (context, error). Absence of every RB_GATE_* variable is an
    ordinary normal-mode caller and keeps the existing direct target launch.
    A partial, malformed or unusable context refuses the launch (r2 Task 1);
    only explicitly inherited descriptors are used - never a marker found in
    the process table or an arbitrary PGID override.
    """
    present = [key for key in GATE_ENV_KEYS if os.environ.get(key)]
    if not present:
        return None, None
    missing = [key for key in GATE_ENV_KEYS if key not in present]
    if missing:
        return None, ("incomplete diagnostic gate context; missing "
                      + ", ".join(missing))
    try:
        reg_fd = int(os.environ["RB_GATE_REG_FD"])
        ack_fd = int(os.environ["RB_GATE_ACK_FD"])
    except ValueError:
        return None, "diagnostic gate descriptors are not integers"
    if min(reg_fd, ack_fd) < 3 or reg_fd == ack_fd:
        return None, "diagnostic gate descriptors are not distinct private endpoints"
    token = os.environ["RB_GATE_TOKEN"]
    case = os.environ["RB_GATE_CASE"]
    if not token or not case:
        return None, "diagnostic gate token/case is empty"
    for label, fd in (("registration", reg_fd), ("acknowledgment", ack_fd)):
        try:
            os.fstat(fd)
        except OSError as exc:
            return None, (f"diagnostic gate {label} descriptor unusable: "
                          f"{exc}")
    return {"reg_fd": reg_fd, "ack_fd": ack_fd, "token": token,
            "case": case}, None


def _gate_handoff(proc, gate: dict, monitor_start: int, deadline: int,
                  release_w: int, state: dict) -> dict:
    """Inner side of the F01 launch gate: receipt, acknowledgment, release.

    M has already been captured immediately after Popen by the caller; H is
    M plus the named case's handoff allowance, clipped to W and the
    F-minus-20-ms freshness decision target. One receipt, at most one
    acknowledgment, one release. Any error,
    EOF, identity mismatch or expired H selects abort: the release pipe is
    closed without a release frame, so the bootstrap cannot exec. The release
    read end was already handed to the bootstrap at Popen; the inner only
    ever owns the write end.
    """
    preview_policy = gate["case"] == GODOT_NATIVE_PREVIEW_CASE
    freshness_ms = (PREVIEW_FRESHNESS_BOUND_MS if preview_policy
                    else FRESHNESS_BOUND_MS)
    handoff_ms = PREVIEW_HANDOFF_MS if preview_policy else HANDOFF_MS
    hard_f = monitor_start + freshness_ms * 1_000_000
    decision = hard_f - FRESHNESS_DECISION_LEAD_MS * 1_000_000
    h_at = min(monitor_start + handoff_ms * 1_000_000, deadline, decision)

    handoff = {
        "m_ns": monitor_start, "h_ns": h_at, "w_ns": deadline,
        "f_ns": hard_f, "decision_ns": decision,
        "h_offset_ms": (h_at - monitor_start) / 1_000_000,
        "ack": None, "ack_error": None, "receipt_error": None,
        "released": False, "release_error": None,
        "ack_at_ms": None, "release_at_ms": None,
    }
    open_fds = state["control_fds"]
    def target_live():
        outcome, status, usage = try_reap(proc.pid)
        if outcome == "reaped":
            _store_reap(state, status, usage, observed_by="monitor")
            state["reaped_at_ns"] = time.monotonic_ns()
            proc.returncode = os.waitstatus_to_exitcode(status)
        return outcome == "running"
    try:
        os.set_blocking(release_w, False)
        os.set_blocking(gate["reg_fd"], False)
        os.set_blocking(gate["ack_fd"], False)
        receipt = {"kind": "receipt", "case": gate["case"],
                   "token": gate["token"], "child_pid": proc.pid,
                   "inner_pid": os.getpid(),
                   **{key: handoff[key] for key in
                      ("m_ns", "h_ns", "w_ns", "f_ns", "decision_ns")}}
        handoff["receipt_error"] = _write_gate_frame(gate["reg_fd"], receipt,
                                                     h_at)
        handoff["receipt_completed_ns"] = time.monotonic_ns()
        # EOF completes this endpoint's single receipt transaction.
        open_fds.remove(gate["reg_fd"])
        os.close(gate["reg_fd"])
        if (state.get("a2_parent_exit") is True
                and gate["case"] == A2_PARENT_EXIT_CASE
                and handoff["receipt_error"] is None):
            # This fixture exits before the ACK read/release branch. Only
            # the bootstrap owns the release reader; closing this sole
            # writer gives it real EOF, without granting signal authority.
            release_close_started_ns = time.monotonic_ns()
            for fd in (gate["ack_fd"], release_w):
                open_fds.remove(fd)
                os.close(fd)
            release_closed_ns = time.monotonic_ns()
            event = {"kind": "a2_parent_exit", "case": gate["case"],
                     "token": gate["token"], "inner_pid": os.getpid(),
                     "child_pid": proc.pid,
                     "receipt_completed_ns": handoff["receipt_completed_ns"],
                     "release_close_started_ns": release_close_started_ns,
                     "release_closed_ns": release_closed_ns,
                     "exit_selected_ns": time.monotonic_ns(),
                     "exit_code": A2_PARENT_EXIT_CODE,
                     "ack_attempted": False, "released": False}
            os.set_blocking(sys.stderr.fileno(), False)
            error = _write_gate_frame(sys.stderr.fileno(), event, h_at)
            if error or CANCEL.is_set() or time.monotonic_ns() >= h_at:
                raise RuntimeError(f"A2 parent-exit evidence failed: {error}")
            os._exit(A2_PARENT_EXIT_CODE)
        if handoff["receipt_error"] is None:
            ack_buf = bytearray()
            ack_frames = []
            ack_bytes = 0
            while time.monotonic_ns() < h_at:
                if CANCEL.is_set():
                    handoff["ack_error"] = "cancelled before acknowledgment"
                    break
                if not target_live():
                    handoff["ack_error"] = ("target exited before "
                                            "acknowledgment")
                    break
                try:
                    chunk = os.read(gate["ack_fd"], 4096)
                except BlockingIOError:
                    time.sleep(0.001)
                    continue
                except OSError as exc:
                    handoff["ack_error"] = (f"acknowledgment read failed: "
                                            f"{type(exc).__name__}: {exc}")
                    break
                if chunk == b"":
                    if len(ack_frames) != 1 or ack_buf:
                        handoff["ack_error"] = "incomplete acknowledgment transaction"
                        break
                    ack = ack_frames[0]
                    expected = {"kind": "ack", "case": gate["case"],
                                "token": gate["token"], "child_pid": proc.pid,
                                "pid": proc.pid, "pgid": proc.pid, "sid": proc.pid,
                                **{key: handoff[key] for key in
                                   ("m_ns", "h_ns", "w_ns", "f_ns", "decision_ns")}}
                    if (ack != expected or any(type(ack.get(key)) is not int
                            for key in ("child_pid", "pid", "pgid", "sid",
                                        "m_ns", "h_ns", "w_ns", "f_ns", "decision_ns"))):
                        handoff["ack_error"] = "acknowledgment identity/clock mismatch"
                    else:
                        handoff["ack"] = ack
                        handoff["ack_at_ns"] = time.monotonic_ns()
                    break
                ack_bytes += len(chunk)
                ack_buf.extend(chunk)
                if ack_bytes > FRAME_MAX_BYTES:
                    handoff["ack_error"] = "acknowledgment oversized"
                    break
                frames, frame_error = _split_frames(ack_buf)
                if frame_error:
                    handoff["ack_error"] = frame_error
                    break
                if frames:
                    ack_frames.extend(frames)
                    if len(ack_frames) > 1:
                        handoff["ack_error"] = "duplicate acknowledgment"
                        break
            else:
                handoff["ack_error"] = (
                    f"no acknowledgment before H (+{handoff['h_offset_ms']}ms)")

        # One release write, only after an exact identity/clock recheck.
        if (handoff["receipt_error"] is None and handoff["ack_error"] is None
                and handoff["ack"] is not None):
            if CANCEL.is_set():
                handoff["release_error"] = "cancelled before release"
            elif time.monotonic_ns() >= h_at:
                handoff["release_error"] = "H expired before release"
            elif not target_live():
                handoff["release_error"] = "target exited before release"
            else:
                release = {"kind": "release", "case": gate["case"],
                           "token": gate["token"], "pid": proc.pid,
                           "pgid": proc.pid, "sid": proc.pid,
                           **{key: handoff[key] for key in
                              ("m_ns", "h_ns", "w_ns", "f_ns", "decision_ns")}}
                handoff["release_write_started_ns"] = time.monotonic_ns()
                handoff["release_error"] = _write_gate_frame(release_w,
                                                             release, h_at)
                handoff["released"] = handoff["release_error"] is None
                handoff["release_at_ns"] = time.monotonic_ns()
    except Exception as exc:
        handoff["receipt_error"] = (
            handoff["receipt_error"]
            or f"gate setup failed: {type(exc).__name__}: {exc}")
    finally:
        # Descriptor table: after the handoff the inner closes its
        # registration write, its acknowledgment read and the release write
        # (EOF on abort, frame on release).
        if gate["case"] == A5_UNRELATED_CASE:
            handoff["release_close_started_ns"] = time.monotonic_ns()
        for fd in tuple(open_fds):
            open_fds.remove(fd)
            try:
                os.close(fd)
            except OSError:
                pass
        if gate["case"] == A5_UNRELATED_CASE:
            handoff["release_closed_ns"] = time.monotonic_ns()
    if gate["case"] == GODOT_NATIVE_PREVIEW_CASE:
        # Step 3: preview-only diagnostic copy of the existing process-local first cancel
        # receipt (integer ns or None). No fresh clock read, handler, reset or classifier.
        handoff["cancel_received_ns"] = CANCEL_AT_NS
    return handoff


class _PostLaunchFault(RuntimeError):
    """Injected post-launch stage fault (diagnose only; contract F02)."""


def _read_fixture_ready(proc, case, end_ns, *, descendant=False) -> tuple:
    """One bounded stdout frame; setup consumes the existing wall/freshness clock."""
    buf = bytearray()
    fd = proc.stdout.fileno()
    os.set_blocking(fd, False)
    try:
        while not CANCEL.is_set() and time.monotonic_ns() < end_ns:
            try:
                chunk = os.read(fd, FRAME_MAX_BYTES+1-len(buf))
            except BlockingIOError:
                time.sleep(min(0.001, max(0, end_ns-time.monotonic_ns())/1e9))
                continue
            if not chunk:
                raise ValueError("fixture readiness EOF")
            buf.extend(chunk)
            if len(buf) > FRAME_MAX_BYTES:
                raise ValueError("fixture readiness oversized")
            if b"\n" not in buf:
                continue
            if not buf.endswith(b"\n") or buf.count(b"\n") != 1:
                raise ValueError("fixture needs exactly one complete readiness frame")
            value = json.loads(buf)
            received = time.monotonic_ns()
            if (not isinstance(value, dict) or value.get("kind") != "fixture_ready"
                    or value.get("case") != case or received >= end_ns
                    or CANCEL.is_set()):
                raise ValueError("fixture readiness identity/cutoff failure")
            pid, pgid, sid, entry = (value.get(k) for k in ("pid", "pgid", "sid", "e_ns"))
            if (not all(type(v) is int and v > 0 for v in (pid, pgid, sid, entry))
                    or pgid != proc.pid or sid != proc.pid
                    or (pid == proc.pid) == descendant
                    or not entry <= received
                    or value.get("expiry_ns") != entry+5_000_000_000
                    or os.getpgid(pid) != pgid or os.getsid(pid) != sid):
                raise ValueError("fixture readiness live identity/lifetime mismatch")
            return {**value, "received_ns": received, "cutoff_ns": end_ns}, bytes(buf)
        raise ValueError("fixture readiness cancelled or expired")
    except Exception as exc:
        raise ValueError(f"{exc}; captured readiness bytes={bytes(buf)!r}") from exc
    finally:
        os.set_blocking(fd, True)


def _observe_survivor(proc, ready, state, end_ns) -> dict:
    """Observe the actual leader reap and a live same-group member before selecting S."""
    while not CANCEL.is_set() and time.monotonic_ns() < end_ns:
        outcome, status, usage = try_reap(proc.pid)
        if outcome == "reaped":
            _store_reap(state, status, usage, observed_by="monitor")
            state["reaped_at_ns"] = time.monotonic_ns()
            proc.returncode = os.waitstatus_to_exitcode(status)
            break
        if outcome != "running":
            raise ValueError("survivor leader wait unavailable")
        time.sleep(min(0.001, max(0, end_ns-time.monotonic_ns())/1e9))
    if not state["reaped"] or proc.returncode != 0:
        raise ValueError("survivor leader did not actually exit0 before the cutoff")
    started = time.monotonic_ns()
    rows, error = _ps_table(end_ns=end_ns)
    completed = time.monotonic_ns()
    member = next((r for r in rows or [] if r["pid"] == ready["pid"]), None)
    if (error or CANCEL.is_set() or completed >= end_ns or member is None
            or member["pgid"] != proc.pid or "Z" in member["stat"]):
        raise ValueError(f"positive pre-stop descendant observation failed: {error}")
    return {"query_start_ns": started, "query_end_ns": completed,
            "query_deadline_ns": end_ns, "validated_row_count": len(rows),
            "rows": [r for r in rows if r["pgid"] == proc.pid],
            "member": member, "source": "actual bounded ps table"}


def supervise(argv: list, opts: dict) -> dict:
    """One launch, retained ownership, and one unconditional finalizer."""
    global CANCEL_AT, CANCEL_AT_NS
    STAGE_LOG.clear()
    REPORTING_ERRORS.clear()
    CANCEL.clear()
    CANCEL_AT = CANCEL_AT_NS = None
    install_signal_handlers()
    if opts.get("unrelated_admission") is True and os.environ.get("RB_GATE_CASE") == A5_UNRELATED_CASE:
        # The selected refusal closes B's release pipe itself after ACK EOF;
        # prompt outer TERM must not turn that controlled EOF into cancellation.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    run_ns = time.monotonic_ns()
    started_utc = utcnow()
    wall = float(opts["wall_seconds"])
    deadline = run_ns + int(wall * 1_000_000_000)
    poll_ms = int(opts.get("poll_ms", DEFAULT_POLL_MS))
    output_bytes = int(opts.get("output_bytes", DEFAULT_OUTPUT_BYTES))
    rss_mib, cpu_seconds = opts.get("rss_mib"), opts.get("cpu_seconds")
    probe_fn = opts.get("probe_fn") or ps_sample
    runtime_fn = opts.get("runtime_fn") or ps_sample
    cleanup_fn = opts.get("cleanup_fn") or runtime_fn
    verifier_fn = opts.get("verifier_fn") or ps_sample
    verify_synthetic = bool(opts.get("verify_synthetic", False))
    preview_route = os.environ.get("RB_GATE_CASE") == GODOT_NATIVE_PREVIEW_CASE
    # PREVIEW01: enable the launch-set diagnostic aggregate only for the native preview
    # route. The known live launch controllers are this inner and the retained outer;
    # the bootstrap-to-engine identity is covered once by the engine group rows.
    preview_diag = None
    if preview_route:
        inner_pid, outer_pid = os.getpid(), os.getppid()
        preview_diag = {
            "expected_pids": {inner_pid, outer_pid},
            "roles": {"inner": inner_pid, "outer": outer_pid},
            "role_of": {inner_pid: "inner", outer_pid: "outer"},
            "expected_groups": {inner_pid: os.getpgid(0),
                                outer_pid: os.getpgid(outer_pid)},
            "members": {}, "mismatched": [], "query_pid": None, "query_rss_kib": None,
            "phases": {},
        }
    reader_mode = str(opts.get("reader_mode", "normal"))
    fault = opts.get("post_launch_fault")
    keep_output = bool(opts.get("keep_output", False))
    state = {"launched": False, "pid": None, "pgid": None, "launched_at_utc": None,
             "reaped": False, "status": None, "usage": None, "reap_failed": False,
             "reap": None, "exit_code": None, "signal": None, "launch_error": None,
             "survivors_verified": None, "survivors_after": None,
             "sample_errors": [], "signals": [], "signal_events": [],
             "stop_origin": None, "s_ns": None, "orphans_cleaned": 0,
             "cutoff_misses": [], "gate": None,
             "terminate_fault": fault == "terminate", "control_fds": set()}
    mon = {"wall": False, "rss": False, "cancel": False,
           "monitoring_failure": None, "peak_rss_kib": 0}
    sampling = {"count": 0, "attempts": 0, "first_sample_ms": None,
                "last_sample_ms": None, "max_gap_ms": None, "max_age_ms": None,
                "freshness_bound_ms": (PREVIEW_FRESHNESS_BOUND_MS if preview_route
                                       else FRESHNESS_BOUND_MS),
                "freshness_breaches": [], "breaches": [],
                "unfinished": 0, "unfinished_ages_ms": [], "unfinished_reasons": [],
                "tail_age_ms": None}
    times, notes, stage_overruns, post_faults = {}, [], [], []
    observed_members = set()
    capture = _Capture(output_bytes,
                       fatal_markers=(ENGINE_ERROR_MARKER_BYTES if preview_route else None))
    readers = {"threads": [], "files": [], "started": False, "errors": []}
    holder = {}
    proc = None
    gate = None
    release_r = release_w = None
    cancel_timer = pre_cancel_timer = None
    probe_rows = None
    verifier_error = None
    incomplete, drain_detail, join_ms = False, "", 0
    raw, total = b"", 0
    finalized = False
    monitor_stop_reason = None
    launch_threads = {"other_threads": [], "preexec_fn": False}

    def close_fd(fd):
        if fd is not None and fd in state["control_fds"]:
            state["control_fds"].remove(fd)
            try:
                os.close(fd)
            except OSError:
                pass

    def finish_stage(label, start, end):
        done = time.monotonic_ns()
        state[label+"_start_ns"] = start
        state[label+"_deadline_ns"] = end
        state[label+"_end_ns"] = done
        times[label+"_ms"] = (done-start)/1_000_000
        if done > end:
            stage_overruns.append(f"{label} late by {done-end}ns")

    def finalize():
        nonlocal finalized, verifier_error, incomplete, drain_detail, join_ms, raw, total
        if finalized or not state["launched"]:
            return
        finalized = True
        if state.get("a5_unrelated") is True:
            # B is observation-only under D13, including fixture setup faults.
            # The already closed release writer / original lease aborts it.
            return
        s = _stop_origin(state)
        # TERM is the first safety action. Reporting happens after cleanup.
        try:
            stop_group(state["pid"], state["pgid"], cleanup_fn, state, observed_members)
        except Exception as exc:
            state["sample_errors"].append(f"terminate stage exception: {type(exc).__name__}: {exc}")
            try:
                _emergency_stop(state["pid"], [state["pgid"]], state)
            except Exception as fallback:
                state["sample_errors"].append(f"emergency cleanup failed: {fallback}")
                state["reap_failed"] = not state["reaped"]
        if state["reaped"] and state["status"] is not None:
            proc.returncode = os.waitstatus_to_exitcode(state["status"])
        finish_stage("termination", s, s+4_000_000_000)
        times["terminate_ms"] = times["termination_ms"]
        start = time.monotonic_ns()
        end = min(start+1_000_000_000, s+5_000_000_000)
        if preview_route and preview_diag is not None:
            _reset_preview_observation(preview_diag, "verification")
        try:
            verified, verifier_error = verify_group_empty(state["pgid"], verifier_fn, end,
                diag=(preview_diag if preview_route else None))
            state["survivors_verified"] = verified
            state["survivors_after"] = verified
            if verified == []:
                state["orphans_cleaned"] = len(observed_members)
        except Exception as exc:
            verifier_error = f"final verification exception: {type(exc).__name__}: {exc}"
        finish_stage("verification", start, end)
        times["verify_ms"] = times["verification_ms"]
        if preview_route and preview_diag is not None:
            # PREVIEW01: bounded verification-phase summary from the SAME existing
            # observation, now qualified for expected-live membership and threshold. The
            # inner is still executing this finalizer, so the live inner/outer/query RSS is
            # measured here; only a positively reaped engine is retired. The authoritative
            # empty-engine-group result above is unchanged, and accounting failure is
            # recorded while existing owned cleanup continues.
            members = {m: int(v) for m, v in (preview_diag.get("members") or {}).items()}
            query_pid = preview_diag.get("query_pid")
            query_rss = preview_diag.get("query_rss_kib")
            if query_rss is not None:
                members[query_pid] = int(query_rss)
            mismatched = list(preview_diag.get("mismatched") or ())
            missing = sorted(p for p in preview_diag.get("expected_pids", ())
                             if p not in members)
            observed_bytes = sum(members.values()) * 1024
            # One acceptance read taken once, immediately before deriving usability. The
            # actual existing stage end is retained; K is the original min(L+1s,S+5s). Only
            # a completed, timely observation with correct current lifecycle/provenance is
            # usable; a complete high observation is usable but resource-invalid.
            phase_accepted = time.monotonic_ns()
            phase_end = state.get("verification_end_ns")
            clock_ok = (type(phase_end) is int and type(start) is int
                        and type(end) is int and type(phase_accepted) is int
                        and start <= phase_end <= phase_accepted <= end)
            # The agreed retirement input is EXACTLY an empty verified group: a nonempty or
            # unknown survivor list is not a usable measurement even when the query returned
            # cleanly. Positive reap/status and verifier success remain required.
            phase_complete = (verifier_error is None and clock_ok
                              and state.get("survivors_verified") == []
                              and state.get("reaped") is True
                              and state.get("status") is not None)
            phase_usable = (phase_complete and not mismatched and not missing
                            and observed_bytes > 0)
            phase_valid = phase_usable and observed_bytes < PREVIEW_AGG_RSS_BYTES
            preview_diag.setdefault("phases", {})["verification"] = {
                "phase": "inner_verification",
                "start_ns": start, "end_ns": phase_end,
                "cutoff_ns": end, "accepted_ns": phase_accepted,
                "engine_group_empty": state.get("survivors_verified") == [],
                "verifier_error": verifier_error,
                "roles": dict(preview_diag.get("roles") or {}),
                "role_of": dict(preview_diag.get("role_of") or {}),
                "members": members,
                "query_pid": query_pid, "query_rss_kib": query_rss,
                "mismatched": mismatched, "missing": missing,
                "observed_bytes": observed_bytes,
                "complete": bool(phase_complete),
                "measurement_usable": bool(phase_usable),
                "over_threshold": observed_bytes >= PREVIEW_AGG_RSS_BYTES,
                "valid": bool(phase_valid),
                "note": ("inner and outer are live during this finalizer; engine retirement "
                         "requires positive reap"),
            }
            if not phase_valid:
                preview_diag["accounting_failure"] = True
        start = time.monotonic_ns()
        end = min(start+2_000_000_000, s+7_000_000_000)
        state["collection_deadline_ns"] = end
        try:
            if fault == "collect":
                raise _PostLaunchFault("injected post-launch fault at collect")
            join_ms, incomplete, drain_detail = collect_output(
                readers, end_ns=end)
            captured, counted, ok = capture.snapshot(max(0.0, (end-time.monotonic_ns())/1e9))
            if ok:
                raw, total = captured, counted
            else:
                incomplete, drain_detail = True, "snapshot incomplete inside collection budget"
        except Exception as exc:
            incomplete, drain_detail = True, f"collection failed: {type(exc).__name__}: {exc}"
            post_faults.append(drain_detail)
        finish_stage("collection", start, end)
        times["collect_ms"] = times["collection_ms"]
        state["post_stop_end_ns"] = time.monotonic_ns()
        times["post_stop_ms"] = (state["post_stop_end_ns"]-s)/1e6
        if state["post_stop_end_ns"] > s+7_000_000_000:
            stage_overruns.append("post-stop total exceeded")
        if incomplete:
            notes.append(drain_detail)

    # All retained state and finalization machinery exist before Popen.
    try:
        if opts.get("cancel_pre_at") is not None:
            pre_cancel_timer = threading.Timer(float(opts["cancel_pre_at"]),
                lambda: os.kill(os.getpid(), signal.SIGINT))
            pre_cancel_timer.daemon = True
            pre_cancel_timer.start()
        stage("probe")
        start = time.monotonic_ns()
        if preview_route and preview_diag is not None:
            _reset_preview_observation(preview_diag, "startup")
        probe = _sample_responsive(probe_fn, os.getpgrp(),
            max(0.0, min(PS_TIMEOUT_SECONDS, (deadline-start)/1e9)),
            cancel=CANCEL, deadline=deadline,
            diag=(preview_diag if preview_route else None))
        times["probe_ms"] = (time.monotonic_ns()-start)/1e6
        if preview_route and preview_diag is not None:
            # PREVIEW01: bounded startup-phase summary AND enforcement from the existing
            # probe observation. The engine does not exist yet; pre-first-sample time stays
            # a disclosed gap. A stored sample is not enforcement.
            members = {m: int(v) for m, v in (preview_diag.get("members") or {}).items()}
            query_pid = preview_diag.get("query_pid")
            query_rss = preview_diag.get("query_rss_kib")
            if query_rss is not None:
                members[query_pid] = int(query_rss)
            mismatched = list(preview_diag.get("mismatched") or ())
            missing = sorted(p for p in preview_diag.get("expected_pids", ())
                             if p not in members)
            startup_bytes = sum(members.values()) * 1024
            # One actual phase end then one acceptance read; the sampler's EXISTING local
            # clipped cutoff is copied unchanged (never relabelled as end or moved). The
            # phase-then-sampler clock relation must hold for the observation to be usable.
            phase_end = time.monotonic_ns()
            phase_accepted = time.monotonic_ns()
            cutoff = probe.get("cutoff_ns")
            sampler_clocks = (probe.get("start_ns"), probe.get("completed_ns"),
                              probe.get("observed_ns"))
            policy_ceiling = ((sampler_clocks[0] + int(PS_TIMEOUT_SECONDS * 1_000_000_000))
                              if type(sampler_clocks[0]) is int else None)
            clock_ok = (type(cutoff) is int and type(policy_ceiling) is int
                        and cutoff <= deadline and cutoff <= policy_ceiling
                        and all(type(v) is int for v in sampler_clocks)
                        and all(type(v) is int for v in (start, phase_end, phase_accepted))
                        and start <= sampler_clocks[0] <= sampler_clocks[1]
                        <= sampler_clocks[2] <= phase_end <= phase_accepted <= cutoff)
            probe_aborted = probe.get("abort") in ("cancel", "deadline")
            monitor_ok = (bool(probe["rows"]) and not probe["timed_out"]
                          and not probe_aborted and clock_ok)
            startup_usable = (monitor_ok and not mismatched and not missing
                              and startup_bytes > 0)
            startup_valid = startup_usable and startup_bytes < PREVIEW_AGG_RSS_BYTES
            preview_diag.setdefault("phases", {})["startup"] = {
                "phase": "startup",
                "start_ns": start, "end_ns": phase_end, "accepted_ns": phase_accepted,
                "cutoff_ns": cutoff,
                "observed": monitor_ok, "engine_present": False,
                "roles": dict(preview_diag.get("roles") or {}),
                "members": members,
                "query_pid": query_pid, "query_rss_kib": query_rss,
                "mismatched": mismatched, "missing": missing,
                "observed_bytes": startup_bytes,
                "complete": bool(monitor_ok),
                "measurement_usable": bool(startup_usable),
                "over_threshold": startup_bytes >= PREVIEW_AGG_RSS_BYTES,
                "valid": bool(startup_valid),
                "note": "pre-launch: bootstrap/engine not yet started",
            }
            if (not monitor_ok or mismatched or missing) and not probe_aborted:
                detail = []
                if not monitor_ok:
                    detail.append("unusable/unqualified controller observation")
                if mismatched:
                    detail.append("wrong-group " + ",".join(str(p) for p in mismatched))
                if missing:
                    detail.append("missing " + ",".join(str(p) for p in missing))
                mon["monitoring_failure"] = ("preview startup launch-set accounting "
                                             + "; ".join(detail))
                preview_diag["accounting_failure"] = True
            elif startup_bytes >= PREVIEW_AGG_RSS_BYTES:
                mon["preview_aggregate_stop"] = True
                preview_diag["startup_threshold_stop"] = True
                preview_diag["accounting_failure"] = True
        if probe["abort"] == "cancel":
            mon["cancel"] = True
        elif probe["abort"] == "deadline":
            mon["monitoring_failure"] = "wall deadline expired during probe; launch skipped"
        elif probe["timed_out"] or probe["rows"] is None:
            mon["monitoring_failure"] = f"probe incomplete: {probe['err']}"
        elif not probe["rows"]:
            mon["monitoring_failure"] = "probe observed no processes; monitoring not established"
        else:
            probe_rows = len(probe["rows"])
            identity_error = _probe_group_identity(probe["rows"])
            # PREVIEW01: never overwrite an earlier startup accounting refusal (missing /
            # wrong-group / unusable observation); _probe_group_identity only validates the
            # returned inner-group authority rows. Cancel/deadline precedence is preserved.
            if mon["monitoring_failure"] is None:
                mon["monitoring_failure"] = identity_error
        if (not mon["cancel"] and mon["monitoring_failure"] is None
                and not mon.get("preview_aggregate_stop")):
            event = _due_event(time.monotonic_ns(), deadline, cancel=CANCEL)
            if event:
                mon["cancel"] = event[2] == "cancel"
                if not mon["cancel"]:
                    mon["monitoring_failure"] = "wall deadline expired before launch"
        if (not mon["cancel"] and mon["monitoring_failure"] is None
                and not mon.get("preview_aggregate_stop")):
            stage("launch")
            others = [t.name for t in threading.enumerate()
                      if t is not threading.current_thread() and t.is_alive()]
            launch_threads = {"other_threads": others, "preexec_fn": cpu_seconds is not None}
            if cpu_seconds is not None and others:
                raise RuntimeError("worker lifecycle check: preexec RLIMIT_CPU refused")
            gate, error = _gate_context()
            if error:
                state["launch_error"] = error
            else:
                if opts.get("unrelated_admission") and (gate is None or gate["case"] != A5_UNRELATED_CASE):
                    raise ValueError("A5 requires its outer-owned private context")
                launch_argv, pass_fds, child_env = argv, (), None
                parent_exit_fixture = (gate is not None
                    and gate["case"] == A2_PARENT_EXIT_CASE
                    and opts.get("parent_exit_after_gated_popen") is True)
                unrelated_fixture = (gate is not None and gate["case"] == A5_UNRELATED_CASE
                    and opts.get("unrelated_admission") is True)
                if gate is not None:
                    state["control_fds"].update((gate["reg_fd"], gate["ack_fd"]))
                    release_r, release_w = os.pipe()
                    state["control_fds"].update((release_r, release_w))
                    launch_argv = [sys.executable, os.path.abspath(__file__), "--bootstrap", "--", *argv]
                    pass_fds = (gate["reg_fd"], release_r)
                    child_env = os.environ.copy()
                    child_env.pop("RB_GATE_ACK_FD", None)
                    child_env["RB_RELEASE_FD"] = str(release_r)
                preexec = None
                if cpu_seconds is not None:
                    limit = int(cpu_seconds)
                    def preexec():
                        resource.setrlimit(resource.RLIMIT_CPU, (limit, limit))
                launch_ns = time.monotonic_ns()
                state["launch_started_ns"] = launch_ns
                if CANCEL.is_set() or launch_ns >= deadline:
                    raise RuntimeError("cancel/deadline before Popen")
                try:
                    proc = subprocess.Popen(launch_argv, stdin=subprocess.DEVNULL,
                        stdout=None if parent_exit_fixture or unrelated_fixture else subprocess.PIPE,
                        stderr=None if parent_exit_fixture or unrelated_fixture else subprocess.PIPE,
                        start_new_session=True, preexec_fn=preexec,
                        pass_fds=pass_fds, env=child_env)
                except OSError as exc:
                    state["launch_error"] = f"{type(exc).__name__}: {exc}"
                    raise
                state.update(launched=True, pid=proc.pid, pgid=proc.pid)
                state["m_ns"] = time.monotonic_ns()
                if unrelated_fixture:
                    state["a5_unrelated"] = True
                if parent_exit_fixture:
                    state["a2_parent_exit"] = True
                readers["files"] = [proc.stdout, proc.stderr]
                times["launch_ms"] = (state["m_ns"]-launch_ns)/1e6
                state["launched_at_utc"] = utcnow()
                if gate is not None:
                    close_fd(release_r)
                    release_r = None
                    handoff_fd, release_w = release_w, None
                    state["gate"] = _gate_handoff(proc, gate, state["m_ns"], deadline, handoff_fd, state)
                    if not state["gate"]["released"]:
                        if (unrelated_fixture and state["gate"].get("receipt_error") is None
                                and state["gate"].get("ack_error") == "incomplete acknowledgment transaction"
                                and state["gate"].get("ack") is None and not CANCEL.is_set()
                                and time.monotonic_ns() < state["gate"]["h_ns"]):
                            event = {"kind": "a5_inner_refusal", "case": gate["case"],
                                     "token": gate["token"], "inner_pid": os.getpid(),
                                     "child_pid": proc.pid, "exit_code": A5_REFUSAL_EXIT_CODE,
                                     "receipt_completed_ns": state["gate"]["receipt_completed_ns"],
                                     "release_close_started_ns": state["gate"]["release_close_started_ns"],
                                     "release_closed_ns": state["gate"]["release_closed_ns"],
                                     "gate_closed_ns": time.monotonic_ns(),
                                     "exit_selected_ns": time.monotonic_ns(), "released": False,
                                     "term_ignore": signal.getsignal(signal.SIGTERM) is signal.SIG_IGN}
                            os.set_blocking(sys.stderr.fileno(), False)
                            error = _write_gate_frame(sys.stderr.fileno(), event, state["gate"]["h_ns"])
                            if error or time.monotonic_ns() >= state["gate"]["h_ns"]:
                                raise RuntimeError(f"A5 refusal evidence failed: {error}")
                            os._exit(A5_REFUSAL_EXIT_CODE)
                        raise RuntimeError(f"launch handoff refused: {state['gate']}")
                if opts.get("ready_case"):
                    ready_end = min(deadline, state["m_ns"]+230_000_000)
                    ready, ready_bytes = _read_fixture_ready(proc, opts["ready_case"], ready_end,
                        descendant=opts.get("survivor_before_stop") is True)
                    if ready["term_ignore"] is not bool(opts.get("ready_term_ignore")):
                        raise ValueError("fixture installed TERM disposition mismatch")
                    state["fixture_ready"] = ready
                    capture.feed(ready_bytes)
                    if opts.get("crash_after_ready"):
                        if gate is None or gate["case"] != A3_CRASH_CASE:
                            raise ValueError("A3 requires the outer-owned private gate")
                        events = [
                            {"kind": "a3_gate", "case": gate["case"], "token": gate["token"],
                             "inner_pid": os.getpid(), "child_pid": proc.pid,
                             **{k:state["gate"][k] for k in
                                ("receipt_completed_ns", "ack_at_ns", "release_at_ns")},
                             "release_write_started_ns": state["gate"]["release_write_started_ns"],
                             "released": True},
                            {"kind": "a3_ready", "case": gate["case"], "token": gate["token"],
                             "ready": {k:ready[k] for k in
                                ("pid", "pgid", "sid", "e_ns", "expiry_ns", "received_ns", "term_ignore")}},
                            {"kind": "a3_crash", "case": gate["case"], "token": gate["token"],
                             "exit_selected_ns": time.monotonic_ns(), "exit_code": A3_CRASH_EXIT_CODE}]
                        os.set_blocking(sys.stderr.fileno(), False)
                        for event in events:
                            error = _write_gate_frame(sys.stderr.fileno(), event, ready_end)
                            if error:
                                raise ValueError(f"A3 crash evidence failed: {error}")
                        if CANCEL.is_set() or time.monotonic_ns() >= ready_end:
                            raise ValueError("A3 crash trigger expired")
                        os._exit(A3_CRASH_EXIT_CODE)
                stage("monitor")
                if fault == "monitor_start":
                    raise _PostLaunchFault("injected post-launch fault at monitor start")
                try:
                    readers = start_readers(proc, capture, reader_mode, [], holder=holder)
                finally:
                    readers = holder.get("state", readers)
                if opts.get("cancel_at") is not None:
                    # Requested diagnostic cancellation stays anchored to M.
                    state["cancel_requested_ns"] = state["m_ns"]+int(float(opts["cancel_at"])*1e9)
                    delay = max(0.0, (state["cancel_requested_ns"]-time.monotonic_ns())/1e9)
                    cancel_timer = threading.Timer(delay, lambda: os.kill(os.getpid(), signal.SIGINT))
                    cancel_timer.daemon = True
                    cancel_timer.start()
                if opts.get("survivor_before_stop"):
                    state["survivor_observation"] = _observe_survivor(
                        proc, state["fixture_ready"], state, min(deadline, state["m_ns"]+230_000_000))
                    observed_members.add(state["fixture_ready"]["pid"])
                    sampling.update(m_ns=state["m_ns"], monitor_end_ns=time.monotonic_ns(),
                        tail_origin_ns=state["m_ns"], applied_period_ns=100_000_000)
                    sampling["tail_age_ns"] = sampling["monitor_end_ns"]-state["m_ns"]
                    sampling["tail_age_ms"] = sampling["tail_age_ns"]/1e6
                else:
                    mon = _monitor_loop(state["pid"], state["pgid"], deadline=deadline,
                        poll_s=poll_ms/1000, sampler=runtime_fn, rss_mib=rss_mib,
                        cancellable=bool(opts.get("cancellable", True)), state=state,
                        sampling=sampling, observed_members=observed_members,
                        monitor_start=state["m_ns"], diag=preview_diag,
                        fatal=(lambda: capture.fatal_hit) if preview_route else None,
                        preview_policy=preview_route)
                _stop_origin(state)
                times["monitor_ms"] = (time.monotonic_ns()-state["m_ns"])/1e6
                if mon["cancel"] and CANCEL_AT_NS is not None:
                    state["cancel_received_ns"] = CANCEL_AT_NS
                    state["cancel_latency_ns"] = state["s_ns"]-CANCEL_AT_NS
                    mon["cancel_latency_ms"] = state["cancel_latency_ns"]/1e6
                monitor_stop_reason, _ = classify(mon, state, True)
                # The terminate injection occurs inside the coordinator after TERM.
    except Exception as exc:
        if state["launched"]:
            _stop_origin(state)
            message = f"post-launch stage failed: {type(exc).__name__}: {exc}"
            post_faults.append(message)
        else:
            message = f"pre-launch failed: {type(exc).__name__}: {exc}"
        mon["monitoring_failure"] = mon["monitoring_failure"] or message
    finally:
        if state["launched"]:
            _stop_origin(state)
        try:
            finalize()
        finally:
            for fd in tuple(state["control_fds"]):
                close_fd(fd)
            for timer in (cancel_timer, pre_cancel_timer):
                if timer is not None:
                    timer.cancel()

    reason, exit_code = classify(mon, state, state["launched"])
    if state["launch_error"]:
        reason, exit_code = "bad_command", EXIT_USAGE
    cleanup = record_cleanup(state["launched"], state, verifier_error, verify_synthetic)
    faults = (not cleanup["ok"] or state["cutoff_misses"] or stage_overruns
              or incomplete or REPORTING_ERRORS or post_faults)
    if faults and exit_code == EXIT_OK:
        exit_code = EXIT_INTERNAL
    timings_ns = {k:v for k,v in state.items() if k.endswith("_ns")}
    end_ns = time.monotonic_ns()
    times["total_ms"] = (end_ns-run_ns)/1e6
    head_limit = len(raw) if keep_output else min(len(raw), OUTPUT_HEAD_CHARS)
    # PREVIEW01: attach the bounded phase summaries and the explicit unmeasured gaps to
    # the separate diagnostic aggregate (never the authoritative engine metrics).
    preview_aggregate = mon.get("preview_aggregate")
    if preview_route and isinstance(preview_aggregate, dict) and preview_diag is not None:
        phases = dict(preview_diag.get("phases") or {})
        preview_aggregate["phases"] = phases
        # Retained runtime peak plus only MEASUREMENT-USABLE inner-observed phase totals,
        # combined by maximum (never a sum of phase peaks). Invalid/partial observations
        # stay as diagnostics and are excluded. The later outer phase completes the
        # all-phase maximum at the outer level, not in this serialized inner record.
        phase_totals = [int(preview_aggregate.get("peak_bytes", 0))]
        for phase in phases.values():
            if (isinstance(phase, dict) and phase.get("measurement_usable") is True
                    and int(phase.get("observed_bytes", 0)) > 0):
                phase_totals.append(int(phase.get("observed_bytes", 0)))
        preview_aggregate["peak_across_phases_bytes"] = max(phase_totals)
        preview_aggregate["accounting_failure"] = bool(
            preview_diag.get("accounting_failure"))
        preview_aggregate["gaps"] = [
            "pre-first-sample startup interval",
            "direct-termination stop path (no sampling by design)",
            "transient query subprocess lifetime",
            "final evidence-write interval",
        ]
    return {
        "argv": list(argv), "pid": state["pid"], "pgid": state["pgid"],
        "clock": "monotonic_ns", "run_ns": run_ns, "return_prepared_ns": end_ns,
        "wall_deadline_ns": deadline,
        "timings_ns": timings_ns, "timings_ms": times,
        "evidence_deadline_ns": state.get("collection_deadline_ns"),
        "child": {"launched": state["launched"], "launched_at_utc": state["launched_at_utc"],
                  "exit_code": state["exit_code"], "signal": state["signal"],
                  "cpu_seconds": (state["reap"] or {}).get("cpu_seconds")},
        "group": {k:state[k] for k in ("orphans_cleaned", "reap", "reap_failed", "reaped",
                  "sample_errors", "signal_events", "signals", "survivors_after",
                  "survivors_verified")},
        "cleanup": cleanup, "cleanup_failure": None if cleanup["ok"] else cleanup["note"],
        "gate": state["gate"], "reason": reason, "exit_code": exit_code,
        "fixture_ready": state.get("fixture_ready"),
        "survivor_observation": state.get("survivor_observation"),
        "monitor_stop_reason": monitor_stop_reason,
        "monitoring_failure": mon["monitoring_failure"],
        "peak_rss_kib": mon["peak_rss_kib"], "samples": sampling["count"],
        "preview_aggregate": preview_aggregate,
        "sampling": sampling, "stage_overruns": stage_overruns,
        "cutoff_misses": state["cutoff_misses"], "post_faults": post_faults,
        "reporting_errors": list(REPORTING_ERRORS), "notes": notes,
        "drain_incomplete": incomplete, "drain_join_ms": join_ms,
        # F4: bounded fatal fact persisted from the shared latch AFTER the bounded reader
        # drain completes. It is evidence for the preview acceptance predicate; it is not
        # a new completion protocol and does not itself set the exit code.
        "preview_fatal_final": bool(capture.fatal_hit),
        "keep_output": keep_output, "launch_error": state["launch_error"],
        "launch_threads": launch_threads, "cancel_latency_ms": mon.get("cancel_latency_ms"),
        "limits": _limits_dict(wall, cpu_seconds, rss_mib, output_bytes, poll_ms,
                               preview_policy=preview_route),
        "sampler": {"kind": opts.get("sampler_kind", "ps_sample"), "probe_rows": probe_rows,
                    "cleanup_kind": opts.get("cleanup_kind", "ps_sample"),
                    "verify_kind": opts.get("verify_kind", "ps_sample")},
        "output": {"captured_bytes": len(raw), "total_bytes": total,
                   "truncated": total>len(raw), "head": raw[:head_limit].decode("utf-8","replace")},
        "elapsed_seconds": (end_ns-run_ns)/1e9, "started_at_utc": started_utc,
        "ended_at_utc": utcnow(), "supervisor": "run_bounded.py",
        "supervisor_sha256": self_sha256()
    }

STALL_SECONDS = 10.0
OUTER_ALLOWANCE_S = 8.0
# Outer containment (R03 contract F05): every inner case runs with a hard
# outer boundary of case wall + margin; the escalation waits after TERM/KILL.
CASE_OUTER_MARGIN_S = 12.0
OUTER_TERM_JOIN_S = 2.0
OUTER_KILL_JOIN_S = 2.0
OUTER_PIPE_CAP_BYTES = 256 * 1024
OUTER_DRAIN_JOIN_S = 2.0
# The selftest uses a small margin because its inner process never runs the
# supervisor; it only has to hang until the outer boundary fires.
OUTER_SELFTEST_MARGIN_S = 0.3
# Bounded argument-check subprocess (safety net only; cases exit fast).
ARGCHECK_SUBPROCESS_TIMEOUT_S = OUTER_RUNTIME_S
ARGCHECK_CAPTURE_CAP = 65536


def _sleep_code(seconds) -> str:
    return f"import time; time.sleep({seconds})"


def _ready_sleep_code(case: str, term_ignore=False) -> str:
    return (
        "import os,signal,time,json;"
        + ("signal.signal(signal.SIGTERM,signal.SIG_IGN);" if term_ignore else "")
        + "e=time.monotonic_ns();expiry=e+5000000000;"
        + "print(json.dumps({'kind':'fixture_ready','case':"+repr(case)+","
        "'pid':os.getpid(),'pgid':os.getpgrp(),'sid':os.getsid(0),"
        "'e_ns':e,'expiry_ns':expiry,'term_ignore':"+repr(term_ignore)+"},"
        "separators=(',',':')),flush=True);"
        "time.sleep(max(0,expiry-time.monotonic_ns())/1e9)")


def _later_stall_sampler():
    attempts = 0
    def sample(pgid, timeout=None):
        nonlocal attempts
        attempts += 1
        if attempts > 1:
            time.sleep(0.5)
        return ps_sample(pgid, timeout=timeout or PS_TIMEOUT_SECONDS)
    return sample


def _failing_sampler(pgid, timeout=None):
    raise SamplerError("injected ps failure")


def _stale_sampler(pgid, timeout=None):
    return {}


def _stalled_sampler(pgid, timeout=None):
    time.sleep(STALL_SECONDS)
    return ps_sample(pgid, timeout=PS_TIMEOUT_SECONDS)


def _stalled_probe(pgid, timeout=None):
    time.sleep(STALL_SECONDS)
    return ps_sample(pgid, timeout=PS_TIMEOUT_SECONDS)


def _slow_probe(over_s: float):
    def fn(pgid, timeout=None):
        budget = float(timeout if timeout is not None else PS_TIMEOUT_SECONDS)
        started = time.monotonic()
        target = budget + over_s
        while time.monotonic() - started < target:
            time.sleep(0.005)
        return ps_sample(pgid, timeout=PS_TIMEOUT_SECONDS)
    return fn


def _slow_sampler(delay: float):
    def fn(pgid, timeout=None):
        time.sleep(delay)
        return ps_sample(pgid, timeout=timeout or PS_TIMEOUT_SECONDS)
    return fn


def _synthetic_verifier(pgid, timeout=None):
    return {SYNTHETIC_SURVIVOR_PID: 1}


def _empty_probe(pgid, timeout=None):
    """Probe that observes nothing (contract F03 empty-probe rejection)."""
    return {}


def _wrong_group_probe(pgid, timeout=None):
    """Probe that reports pids outside the supervisor group (contract F03).

    pid 1 always exists and belongs to a different group, so the identity
    check must reject it before any launch.
    """
    return {1: 100}


def _slow_fixed_probe(delay: float):
    """Probe that waits a fixed delay before sampling (slow probe cases)."""
    def fn(pgid, timeout=None):
        time.sleep(delay)
        return ps_sample(pgid, timeout=timeout or PS_TIMEOUT_SECONDS)
    return fn


def case_specs() -> dict:
    """Built-in diagnostics and one explicitly named parser command."""
    py = sys.executable

    def sleeper(seconds) -> list:
        return [py, "-c", _sleep_code(seconds)]

    retain_code = (
        "import subprocess,sys,time;"
        "subprocess.Popen([sys.executable,'-c',"
        "\"import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)\"]);"
        "print('pipe retained',flush=True)")
    return {
        "deadline": (
            "1s wall stop against a 30s harmless sleeper",
            sleeper(30), {"wall_seconds": 1.0}),
        "cancel": (
            "SIGINT cancellation of a supervised 30s sleeper",
            sleeper(30), {"wall_seconds": 30.0, "cancel_at": 0.3}),
        "cleanup": (
            "parent exits leaving a same-group sleeper; group must be flushed",
            [py, "-c", "import subprocess,sys,time;subprocess.Popen([sys.executable,"
             "'-c','import time;time.sleep(60)']);print('parent done',flush=True)"],
            {"wall_seconds": 15.0}),
        "rss_available": (
            "available sampler: aggregate RSS sampled while child sleeps",
            sleeper(1.5), {"wall_seconds": 15.0, "rss_mib": 512}),
        "rss_low": (
            "deliberately low 1 MiB threshold against ordinary baseline RSS",
            sleeper(5), {"wall_seconds": 5.0, "rss_mib": 1}),
        "sampler_stale": (
            "probe succeeds, then sampler stops seeing the owned group",
            sleeper(10), {"wall_seconds": 15.0, "runtime_fn": _stale_sampler,
                          "sampler_kind": "stale_ps_sample"}),
        "sampler_failed": (
            "sampler fails before launch; launch must be prevented",
            sleeper(10), {"wall_seconds": 15.0, "probe_fn": _failing_sampler,
                          "sampler_kind": "failing_ps_sample"}),
        "output_bounded": (
            "2 MB of child output drained into a bounded 256 KiB capture",
            [py, "-c", "import sys; sys.stdout.write('x'*2000000)"],
            {"wall_seconds": 15.0, "output_bytes": 262144}),
        "cpu_limit": (
            "1s CPU limit against a harmless busy child",
            [py, "-c", "while True: pass"],
            {"wall_seconds": 8.0, "cpu_seconds": 1}),
        "cleanup_sampler_failed": (
            "cleanup sampler fails after a clean child exit; run must not pass",
            sleeper(0.2),
            {"wall_seconds": 15.0, "cleanup_fn": _failing_sampler,
             "cleanup_kind": "injected_failing_ps_sample"}),
        "final_verifier_failed": (
            "final verifier fails after cleanup; verification is unknown, not empty",
            sleeper(0.2),
            {"wall_seconds": 15.0, "verifier_fn": _failing_sampler,
             "verify_kind": "injected_failing_ps_sample"}),
        "final_verifier_nonempty": (
            "injected verifier reports a synthetic survivor; run must fail",
            sleeper(0.2),
            {"wall_seconds": 15.0, "verifier_fn": _synthetic_verifier,
             "verify_kind": "injected_synthetic_verifier",
             "verify_synthetic": True}),
        "probe_stalled": (
            "stalled probe is cut off by the remaining stage time; no launch",
            sleeper(10),
            {"wall_seconds": 1.0, "probe_fn": _stalled_probe,
             "sampler_kind": "stalled_ps_sample"}),
        "probe_expired": (
            "probe consumes the wall deadline; expiry recheck blocks launch",
            sleeper(10),
            {"wall_seconds": 0.2, "probe_fn": _slow_probe(0.02),
             "sampler_kind": "slow_ps_sample"}),
        "sampler_stalled": (
            "runtime sampler stall is bounded by the stage budget; monitoring fails",
            sleeper(10),
            {"wall_seconds": 15.0, "runtime_fn": _stalled_sampler,
             "cleanup_fn": ps_sample, "sampler_kind": "stalled_ps_sample"}),
        "cancel_while_sampling": (
            "SIGINT arrives during a slow sample; cancellation stays bounded",
            sleeper(30),
            {"wall_seconds": 15.0, "runtime_fn": _slow_sampler(0.4),
             "cleanup_fn": ps_sample, "cancel_at": 0.1,
             "sampler_kind": "slow_ps_sample"}),
        "reader_setup_failure": (
            "reader start fails after launch; bounded cleanup retains identity",
            sleeper(10),
            {"wall_seconds": 5.0, "reader_mode": "fail_start"}),
        "term_resistant": (
            "owned child ignores TERM; bounded KILL escalation and reap",
            [py, "-c", "import signal,time; signal.signal(signal.SIGTERM, "
             "signal.SIG_IGN); time.sleep(60)"],
            {"wall_seconds": 0.5}),
        "pipe_retention": (
            "same-group child retains the output pipe; no hang, group flushed",
            [py, "-c", retain_code],
            {"wall_seconds": 15.0}),
        "drain_stuck": (
            "synthetic stuck reader: bounded join makes incomplete drain fail",
            sleeper(10),
            {"wall_seconds": 0.3, "reader_mode": "stuck"}),
        # ---- R03 contract F01: fixed 250 ms freshness gate ---------------
        "probe_empty": (
            "probe observes nothing; monitoring not established, no launch",
            sleeper(10),
            {"wall_seconds": 15.0, "probe_fn": _empty_probe,
             "sampler_kind": "empty_probe_sample"}),
        "probe_wrong_group": (
            "probe reports a foreign-group pid; identity check blocks launch",
            sleeper(10),
            {"wall_seconds": 15.0, "probe_fn": _wrong_group_probe,
             "sampler_kind": "wrong_group_probe_sample"}),
        "probe_cancel": (
            "SIGINT during a slow probe; cancellation blocks launch",
            sleeper(30),
            {"wall_seconds": 15.0, "probe_fn": _slow_fixed_probe(0.4),
             "cancel_pre_at": 0.1, "sampler_kind": "slow_fixed_ps_sample"}),
        "sample_slow_over_250": (
            "sample takes longer than the 250 ms gate; failure is expected",
            sleeper(10),
            {"wall_seconds": 15.0, "runtime_fn": _slow_sampler(0.2),
             "cleanup_fn": ps_sample, "sampler_kind": "slow_ps_sample"}),
        "expiry_during_sample": (
            "wall deadline expires while a sample is in flight",
            sleeper(30),
            {"wall_seconds": 0.2, "runtime_fn": _slow_sampler(0.35),
             "cleanup_fn": ps_sample, "sampler_kind": "slow_ps_sample"}),
        "cancel_latency": (
            "SIGINT during a slow sample; cancel latency must stay <= 250 ms",
            sleeper(30),
            {"wall_seconds": 15.0, "runtime_fn": _slow_sampler(0.5),
             "cleanup_fn": ps_sample, "cancel_at": 0.2,
             "sampler_kind": "slow_ps_sample"}),
        # ---- R03 contract F02: post-launch funnel and reader errors ------
        "sampler_runtime_failed": (
            "runtime sampler fails at start; monitoring fails, cleanup runs",
            sleeper(10),
            {"wall_seconds": 15.0, "runtime_fn": _failing_sampler,
             "cleanup_fn": ps_sample, "sampler_kind": "failing_ps_sample"}),
        "reader_partial_start": (
            "partial reader-start failure keeps partial state; drain fails",
            sleeper(10),
            {"wall_seconds": 5.0, "reader_mode": "partial_fail"}),
        "reader_mid_read_failure": (
            "reader read error mid-stream; drain incomplete, run nonzero",
            sleeper(0.6),
            {"wall_seconds": 5.0, "reader_mode": "fail_mid"}),
        "post_launch_fault_monitor_start": (
            "exception at monitor start funnels into bounded cleanup",
            sleeper(5),
            {"wall_seconds": 5.0, "post_launch_fault": "monitor_start"}),
        "post_launch_fault_terminate": (
            "exception at terminate; bounded fallback stop, run nonzero",
            sleeper(0.2),
            {"wall_seconds": 15.0, "post_launch_fault": "terminate"}),
        "post_launch_fault_collect": (
            "exception at collect; drain incomplete, run nonzero",
            sleeper(0.3),
            {"wall_seconds": 15.0, "post_launch_fault": "collect"}),
        # ---- R03 contract F04: escalation + shared wait-status decoder ---
        "term_resistant_sampler_stalled": (
            "TERM-resistant child with a dead cleanup sampler; KILL on time",
            [py, "-c", "import signal,time; signal.signal(signal.SIGTERM, "
             "signal.SIG_IGN); time.sleep(60)"],
            {"wall_seconds": 0.5, "cleanup_fn": _stalled_sampler,
             "cleanup_kind": "stalled_ps_sample"}),
        "cleanup_normal_exit": (
            "child exits before TERM; the cleanup reap observes the status",
            sleeper(0.1),
            {"wall_seconds": 15.0, "runtime_fn": _stale_sampler,
             "cleanup_fn": _slow_sampler(0.15),
             "sampler_kind": "stale_ps_sample",
             "cleanup_kind": "slow_ps_sample"}),
        # ---- Architect r2 A1: outer-only finite stall --------------------
        "a1_outer_stall": (
            "inner ignores TERM and self-limits at four seconds; the outer "
            "boundary must interrupt it under the earlier one-second bound "
            "with prompt TERM and the required KILL, then reap the inner and "
            "verify its group empty",
            [],
            {"wall_seconds": 5.0,
             "outer_margin_s": OUTER_SELFTEST_MARGIN_S}),
        A2_PARENT_EXIT_CASE: (
            "inner exits after gated Popen/receipt; admission waits for its "
            "actual exit, refuses promotion, and verifies the unreleased "
            "bootstrap disappeared without workload exec",
            sleeper(WORKLOAD_SELF_LIMIT_S),
            {"wall_seconds": 5.0, "parent_exit_after_gated_popen": True}),
        A5_UNRELATED_CASE: (
            "reject a registration naming a directly owned unrelated TERM-resistant control",
            sleeper(5), {"wall_seconds": 5.0, "unrelated_admission": True,
                        "control_argv": [py, "-c", _ready_sleep_code(A5_UNRELATED_CASE, True)]}),
        A3_CRASH_CASE: (
            "actual inner crash after admitted release and live separate workload readiness",
            [py, "-c", _ready_sleep_code(A3_CRASH_CASE)],
            {"wall_seconds": 5.0, "ready_case": A3_CRASH_CASE, "crash_after_ready": True}),
        "a5_survivor": (
            "leader exits0; observe a live same-group TERM-resistant descendant before S",
            [py, "-c", "import subprocess,sys;subprocess.Popen([sys.executable,'-c',"
             +repr(_ready_sleep_code("a5_survivor", True))+"])"] ,
            {"wall_seconds": 5.0, "ready_case": "a5_survivor", "ready_term_ignore": True,
             "survivor_before_stop": True}),
        "b1_normal_cli": (
            "outer-owned normal CLI with explicit limits and a finite0.6s workload",
            [py, "-c", "import time;print('b1 normal ready',flush=True);time.sleep(0.6);"
             "print('b1 normal complete',flush=True)"],
            {"wall_seconds": 5.0, "rss_mib": 512, "output_bytes": 262144, "poll_ms": 100}),
        "b2_first_stall": (
            "first sampler stalls0.5s against the original M+250ms freshness cutoff",
            sleeper(5), {"wall_seconds": 5.0, "rss_mib": 512,
                        "runtime_fn": _slow_sampler(0.5), "cleanup_fn": ps_sample,
                        "sampler_kind": "finite_first_stall"}),
        "b4_later_stall": (
            "healthy first real sample, then a0.5s stall without a renewed clock",
            sleeper(5), {"wall_seconds": 5.0, "rss_mib": 512,
                        "runtime_fn": _later_stall_sampler(), "cleanup_fn": ps_sample,
                        "sampler_kind": "finite_later_stall"}),
        "c3_term_resistance": (
            "installed TERM-ignore readiness before W=R+500ms; self-limit E+5s",
            [py, "-c", _ready_sleep_code("c3_term_resistance", True)],
            {"wall_seconds": 0.5, "rss_mib": 512, "ready_case": "c3_term_resistance",
             "ready_term_ignore": True}),
        "b5_cancel_stalled": (
            "actual cancellation M+100ms during a finite0.5s stalled sample",
            sleeper(5), {"wall_seconds": 5.0, "rss_mib": 512,
                        "runtime_fn": _slow_sampler(0.5), "cleanup_fn": ps_sample,
                        "cancel_at": 0.1, "sampler_kind": "finite_cancel_stall"}),
        GODOT_PARSE_CASE: (
            "fixed Godot check-only script parse through retained outer/normal supervision",
            list(GODOT_PARSE_ARGV), {}),
        GODOT_DEV_SMOKE_CASE: (
            "fixed Godot headless dev_smoke acceptance run through retained outer/normal "
            "supervision with checked runner result sink",
            [], {"engine_suite": GODOT_ENGINE_SUITE[GODOT_DEV_SMOKE_CASE]}),
        GODOT_PLAY01_CASE: (
            "fixed Godot headless play01_focus acceptance run through retained outer/normal "
            "supervision with checked runner result sink",
            [], {"engine_suite": GODOT_ENGINE_SUITE[GODOT_PLAY01_CASE]}),
        GODOT_NATIVE_PREVIEW_CASE: (
            "one fixed Godot native main-scene preview through retained outer/normal "
            "supervision (no headless, no runner result/marker)",
            [], {"preview": True}),
    }


def check_diagnose(name: str, r: dict, wall_clock: float) -> list:
    """Per-case acceptance (contracts 1-4, R03 F01-F05).

    Returns the problem list.
    """
    problems: list = []
    child = r.get("child", {})
    cleanup = r.get("cleanup", {})
    group = r.get("group", {})
    sampling = r.get("sampling", {})
    limits = r.get("limits", {})
    launched = bool(child.get("launched"))
    exit_code = r.get("exit_code")
    reason = r.get("reason")

    def want(cond, message: str) -> None:
        if not cond:
            problems.append(message)

    want(not r.get("cutoff_misses"), "actual raw cutoff miss")
    want(not r.get("stage_overruns"), "actual stage overrun")
    want(not r.get("reporting_errors"), "reporting failed")
    allowed_fault = {
        "post_launch_fault_monitor_start":
            "post-launch stage failed: _PostLaunchFault: injected post-launch fault at monitor start",
        "post_launch_fault_collect":
            "collection failed: _PostLaunchFault: injected post-launch fault at collect",
    }.get(name)
    want(all(f == allowed_fault for f in r.get("post_faults", [])),
         "unexpected post-launch fault")
    raw = r.get("timings_ns", {})
    if launched:
        s_ns = raw.get("s_ns")
        want(type(s_ns) is int, "raw stop clock missing")
        if type(s_ns) is int:
            for label, allowance, total in (("termination", 4_000_000_000, 4_000_000_000),
                                            ("verification", 1_000_000_000, 5_000_000_000),
                                            ("collection", 2_000_000_000, 7_000_000_000)):
                start, end, cutoff = (raw.get(label+k) for k in
                                      ("_start_ns", "_end_ns", "_deadline_ns"))
                valid = all(type(v) is int for v in (start, end, cutoff))
                want(valid and s_ns <= start <= end <= cutoff == min(start+allowance, s_ns+total),
                     f"{label} raw timing missing/late")
            want(type(raw.get("reaped_at_ns")) is int
                 and raw["reaped_at_ns"] <= s_ns+4_000_000_000, "raw reap missing/late")
        gate = r.get("gate") or {}
        want(gate.get("released") is True and isinstance(gate.get("ack"), dict),
             "positive workload admission/release missing")
        ordered = [gate.get(k) for k in
                   ("m_ns", "receipt_completed_ns", "ack_at_ns", "release_at_ns", "h_ns")]
        want(all(type(v) is int for v in ordered) and ordered == sorted(ordered)
             and ordered[-2] < ordered[-1], "raw gate ordering missing/late")
        want(not any(gate.get(k) for k in ("receipt_error", "ack_error", "release_error")),
             "gate error")
    run_start, run_end, wall_end = (r.get(k) for k in
                                   ("run_ns", "return_prepared_ns", "wall_deadline_ns"))
    want(all(type(v) is int for v in (run_start, run_end, wall_end))
         and run_start <= run_end <= wall_end+7_000_000_000,
         "case raw wall/teardown bound missing or exceeded")
    # Freshness gate: breaches are the expected failure of exactly one case.
    if name == "sample_slow_over_250":
        want(bool(sampling.get("breaches")),
             "the slow-sample case must record a freshness breach")
        want(all(int(b.get("bound_ms", 0)) == FRESHNESS_BOUND_MS
                 for b in sampling.get("breaches", [])),
             f"every breach must cite the fixed {FRESHNESS_BOUND_MS} ms bound")
    else:
        want(not sampling.get("breaches"),
             f"freshness breaches recorded: {sampling.get('breaches')}")
    want(not group.get("reap_failed"), "reap failed for the owned child")
    want(limits.get("freshness_bound_ms") == FRESHNESS_BOUND_MS,
         f"limits must record freshness_bound_ms={FRESHNESS_BOUND_MS}")
    want(limits.get("sample_period_ms") == int(FRESHNESS_PERIOD_S * 1000),
         f"limits must record sample_period_ms={int(FRESHNESS_PERIOD_S * 1000)}")
    want(sampling.get("freshness_bound_ms") == FRESHNESS_BOUND_MS,
         f"sampling must record freshness_bound_ms={FRESHNESS_BOUND_MS}")

    if name in PRE_LAUNCH_CASES:
        want(not launched, "child must not launch")
        want(r.get("pid") is None, "no pid may be recorded before launch")
        want(exit_code == EXIT_MONITORING,
             f"expected monitoring exit {EXIT_MONITORING}, got {exit_code}")
        want(reason == "monitoring", f"expected reason monitoring, got {reason}")
        want(cleanup.get("attempted") is False,
             "cleanup must not be attempted before launch")
        want(cleanup.get("verified") is None,
             "pre-launch verification must be null, never an empty list")
        want(not cleanup.get("errors"), "pre-launch cleanup must have no errors")
        want(isinstance(r.get("monitoring_failure"), str) and r["monitoring_failure"],
             "the monitoring failure must be recorded")
        if name == "probe_expired":
            want("expired" in str(r.get("monitoring_failure", "")),
                 "monitoring failure must mention the expired deadline")
        if name == "probe_empty":
            want("no processes" in str(r.get("monitoring_failure", "")),
                 "monitoring failure must mention the empty probe observation")
        if name == "probe_wrong_group":
            want("group" in str(r.get("monitoring_failure", "")),
                 "monitoring failure must mention the wrong-group observation")
        return problems

    if name in PRE_LAUNCH_CANCEL_CASES:
        want(not launched, "child must not launch when the probe is cancelled")
        want(r.get("pid") is None, "no pid may be recorded before launch")
        want(exit_code == EXIT_CANCELLED,
             f"expected cancelled exit {EXIT_CANCELLED}, got {exit_code}")
        want(reason == "cancelled", f"expected reason cancelled, got {reason}")
        want(r.get("monitoring_failure") is None,
             "a cancelled probe must not be a monitoring failure")
        want(cleanup.get("attempted") is False,
             "cleanup must not be attempted before launch")
        want(cleanup.get("verified") is None,
             "pre-launch verification must be null, never an empty list")
        return problems

    # ---- launched cases --------------------------------------------------
    want(launched, "child must launch")
    want(r.get("pid") is not None, "launched pid must be recorded")
    want(r.get("pgid") is not None and r.get("pgid") == r.get("pid"),
         "pgid must equal the launched child pid")
    want(cleanup.get("attempted") is True, "cleanup must be attempted")
    want(cleanup.get("reaped") is True, "child must be reaped")
    want(group.get("reaped") is True, "group record must show the reap")
    want(not r.get("stage_overruns"),
         f"stage overruns recorded: {r.get('stage_overruns')}")

    # Shared wait-status decoder (F04): one record, one observer, CPU time.
    reap = group.get("reap")
    want(isinstance(reap, dict) and reap.get("observed_by") in ("monitor", "cleanup"),
         f"reap record with observer expected, got {reap!r}")
    if isinstance(reap, dict):
        want(reap.get("cpu_seconds") is not None,
             "the decoded reap record must carry cpu_seconds")
    # Per-signal timestamps (F04).
    events = group.get("signal_events", [])
    want(len(events) == len(set(
        (e.get("signal"), e.get("attempt_ns")) for e in events)),
         "signal events must be individually recorded")
    for event in events:
        completed, stop = event.get("completed_ns"), raw.get("s_ns")
        want(type(completed) is int and type(stop) is int,
             "raw signal completion missing")
        want(event.get("result") in ("sent", "nonexistent"), "signal dispatch failed")
        if type(completed) is int and type(stop) is int:
            limit = 50_000_000 if event.get("signal") == "SIGTERM" else 2_000_000_000
            want(0 <= completed-stop <= limit, "signal completion outside raw cutoff")


    # Freshness accounting (F01): completed samples carry honest ages.
    if int(sampling.get("count", 0)) > 0:
        want(sampling.get("first_sample_ms") is not None,
             "first sample completion time must be recorded")
        want(sampling.get("last_sample_ms") is not None,
             "last sample completion time must be recorded")
        want(isinstance(sampling.get("tail_age_ms"), (int, float)),
             "tail age must be recorded when samples completed")
        if sampling.get("tail_age_ms") is not None and not sampling.get(
                "breaches"):
            # When a breach was detected the tail honestly reports the stale
            # age that caused the failure; the bound applies to runs that
            # complete monitoring without a breach.
            want(type(sampling.get("tail_age_ns")) is int
                 and 0 <= sampling["tail_age_ns"] <= FRESHNESS_BOUND_MS*1_000_000,
                 f"tail age {sampling['tail_age_ms']}ms exceeds "
                 f"{FRESHNESS_BOUND_MS}ms")
        want(int(sampling.get("unfinished", 0)) == len(
            sampling.get("unfinished_ages_ms", [])) == len(
            sampling.get("unfinished_reasons", [])),
             "unfinished samples must record age and reason lists")
    else:
        want(sampling.get("unfinished", 0) >= 0,
             "unfinished counter must be numeric")

    expected = {
        "deadline": (EXIT_WALL, "wall"),
        "cancel": (EXIT_CANCELLED, "cancelled"),
        "cleanup": (EXIT_OK, "ok"),
        "rss_available": (EXIT_OK, "ok"),
        "rss_low": (EXIT_RSS, "rss"),
        "sampler_stale": (EXIT_MONITORING, "monitoring"),
        "output_bounded": (EXIT_OK, "ok"),
        "cpu_limit": (EXIT_CPU, "cpu"),
        "cleanup_sampler_failed": (EXIT_INTERNAL, "ok"),
        "final_verifier_failed": (EXIT_INTERNAL, "ok"),
        "final_verifier_nonempty": (EXIT_INTERNAL, "ok"),
        "sampler_stalled": (EXIT_MONITORING, "monitoring"),
        "cancel_while_sampling": (EXIT_CANCELLED, "cancelled"),
        "reader_setup_failure": (EXIT_MONITORING, "monitoring"),
        "term_resistant": (EXIT_WALL, "wall"),
        "pipe_retention": (EXIT_OK, "ok"),
        "drain_stuck": (EXIT_MONITORING, "monitoring"),
        "sample_slow_over_250": (EXIT_MONITORING, "monitoring"),
        "expiry_during_sample": (EXIT_WALL, "wall"),
        "cancel_latency": (EXIT_CANCELLED, "cancelled"),
        "sampler_runtime_failed": (EXIT_MONITORING, "monitoring"),
        "reader_partial_start": (EXIT_MONITORING, "monitoring"),
        "reader_mid_read_failure": (EXIT_MONITORING, "monitoring"),
        "post_launch_fault_monitor_start": (EXIT_MONITORING, "monitoring"),
        "post_launch_fault_terminate": (EXIT_INTERNAL, "ok"),
        "post_launch_fault_collect": (EXIT_MONITORING, "monitoring"),
        "term_resistant_sampler_stalled": (EXIT_WALL, "wall"),
        "cleanup_normal_exit": (EXIT_MONITORING, "monitoring"),
        "a5_survivor": (EXIT_OK, "ok"),
        "b1_normal_cli": (EXIT_OK, "ok"),
        "b2_first_stall": (EXIT_MONITORING, "monitoring"),
        "b4_later_stall": (EXIT_MONITORING, "monitoring"),
        "c3_term_resistance": (EXIT_WALL, "wall"),
        "b5_cancel_stalled": (EXIT_CANCELLED, "cancelled"),
    }
    if name in expected:
        want(exit_code == expected[name][0],
             f"expected exit {expected[name][0]}, got {exit_code}")
        want(reason == expected[name][1],
             f"expected reason {expected[name][1]}, got {reason}")

    expect_cleanup_ok = name not in EXPECT_CLEANUP_FAILURE
    if expect_cleanup_ok:
        want(cleanup.get("ok") is True,
             f"cleanup must be ok: {cleanup.get('note')}")
        want(cleanup.get("verified") == [],
             f"verified must be [], got {cleanup.get('verified')!r}")
        want(not cleanup.get("errors"), f"cleanup errors: {cleanup.get('errors')}")
        want(r.get("cleanup_failure") is None, "cleanup_failure must be null")
        want(group.get("survivors_after") == [],
             f"survivors_after must be [], got {group.get('survivors_after')!r}")
    else:
        want(cleanup.get("ok") is False, "cleanup must fail closed")
        want(bool(r.get("cleanup_failure")), "cleanup_failure must be recorded")

    signals = group.get("signals", [])
    if name == "deadline":
        want("SIGTERM" in signals, "SIGTERM must be recorded")
        want(r.get("monitor_stop_reason") == "wall", "monitor stop reason must be wall")
        want(child.get("signal") == signal.SIGTERM,
             "the cleanup reap must observe the TERM-killed child")
        want(isinstance(reap, dict) and reap.get("observed_by") == "cleanup",
             "TERM-killed child must be reaped by the cleanup stage")
    elif name == "cancel":
        want("SIGTERM" in signals, "SIGTERM must be recorded")
        want(r.get("monitor_stop_reason") == "cancelled",
             "monitor stop reason must be cancelled")
        want(isinstance(reap, dict) and reap.get("observed_by") == "cleanup",
             "cancelled child must be reaped by the cleanup stage")
    elif name == "cleanup":
        want(int(group.get("orphans_cleaned", 0)) >= 1,
             "the orphan must be cleaned from the owned group")
        want("SIGTERM" in signals, "SIGTERM must be recorded")
        want(isinstance(reap, dict) and reap.get("observed_by") == "monitor",
             "naturally exiting child must be reaped by the monitor")
        want(child.get("exit_code") == 0, "natural exit code must be 0")
    elif name == "rss_available":
        want(int(r.get("samples", 0)) >= 2, "expected multiple RSS samples")
        want(int(r.get("peak_rss_kib", 0)) > 0, "expected a sampled RSS peak")
        want(limits.get("rss_mib") == 512, "limits must record rss_mib=512")
        want(isinstance(reap, dict) and reap.get("observed_by") == "monitor",
             "naturally exiting child must be reaped by the monitor")
    elif name == "rss_low":
        want(int(r.get("peak_rss_kib", 0)) > 1024,
             "sampled peak must exceed the 1 MiB threshold")
        want("SIGTERM" in signals, "SIGTERM must be recorded")
        want(isinstance(reap, dict) and reap.get("observed_by") == "cleanup",
             "rss-stopped child must be reaped by the cleanup stage")
    elif name == "sampler_stale":
        want("stale" in str(r.get("monitoring_failure", "")),
             "monitoring failure must mention the stale sampler")
    elif name == "output_bounded":
        out = r.get("output", {})
        want(int(out.get("captured_bytes", 0)) == 262144, "capture must be 256 KiB")
        want(int(out.get("total_bytes", 0)) == 2000000, "total must be 2000000")
        want(out.get("truncated") is True, "output must be marked truncated")
        want(r.get("drain_incomplete") is False, "drain must complete")
    elif name == "cpu_limit":
        want(child.get("signal") == getattr(signal, "SIGXCPU", 24),
             f"child must die from SIGXCPU, got {child.get('signal')}")
        want(limits.get("cpu_seconds") == 1, "limits must record cpu_seconds=1")
        want(child.get("cpu_seconds") is not None and child["cpu_seconds"] >= 0.5,
             "child CPU time must be recorded")
        want(launch_threads_ok(r), "RLIMIT_CPU must not be applied with live threads")
    elif name == "cleanup_sampler_failed":
        want(cleanup.get("verified") == [],
             "the independent final verifier must still run")
        want(bool(group.get("sample_errors")),
             "cleanup sampler errors must be recorded")
        want(exit_code == EXIT_INTERNAL, "cleanup failure must force a nonzero exit")
    elif name == "final_verifier_failed":
        want(cleanup.get("verified") is None,
             "failed verification must stay unknown (null)")
        want(any("final verifier failed" in e for e in cleanup.get("errors", [])),
             "verifier error must appear in cleanup errors")
    elif name == "final_verifier_nonempty":
        want(cleanup.get("verified") == [SYNTHETIC_SURVIVOR_PID],
             f"synthetic survivor must be listed, got {cleanup.get('verified')!r}")
        want(cleanup.get("synthetic") is True, "cleanup must be flagged synthetic")
        want(any("synthetic survivor" in n for n in r.get("notes", [])),
             "notes must state the survivor is synthetic")
    elif name == "sampler_stalled":
        want("sampler timeout" in str(r.get("monitoring_failure", "")),
             "monitoring failure must mention the bounded sampler timeout")
        want(int(r.get("samples", 0)) == 0, "no successful sample is expected")
        want(int(sampling.get("unfinished", 0)) >= 1,
             "the stalled attempt must be recorded as unfinished")
    elif name == "cancel_while_sampling":
        want(wall_clock < 5.0,
             f"cancellation must not wait out the sampler: {wall_clock}s")
        want(int(sampling.get("unfinished", 0)) >= 1,
             "the in-flight slow sample must be recorded as unfinished")
        cancel_latency_ok(want, r, "cancel during sampling")
    elif name == "reader_setup_failure":
        want("reader setup failed" in str(r.get("monitoring_failure", "")),
             "monitoring failure must mention the reader setup")
        want(r.get("pid") is not None, "launched identity must be retained")
        want(r.get("drain_incomplete") is True,
             "stream state is unknown when no reader started")
    elif name == "term_resistant":
        want("SIGKILL" in signals,
             f"SIGKILL escalation must be recorded, got {signals}")
        want("SIGTERM" in signals, "SIGTERM must be recorded first")
        want(child.get("signal") == signal.SIGKILL,
             "the cleanup reap must observe the KILL-killed child")
        want(isinstance(reap, dict) and reap.get("observed_by") == "cleanup",
             "KILL-killed child must be reaped by the cleanup stage")
    elif name == "pipe_retention":
        want("SIGKILL" in signals,
             f"SIGKILL escalation must be recorded, got {signals}")
        want(int(group.get("orphans_cleaned", 0)) >= 1,
             "the pipe-retaining child must be cleaned")
        want(r.get("drain_incomplete") is False,
             "the pipe must drain after group termination")
        want(int(r.get("output", {}).get("captured_bytes", 0)) >= 1,
             "the parent's output must be captured")
    elif name == "drain_stuck":
        want(r.get("drain_incomplete") is True, "drain must be incomplete")
        want("drain incomplete" in str(r.get("monitoring_failure", "")),
             "monitoring failure must mention the incomplete drain")
    # ---- R03 contract cases ---------------------------------------------
    elif name == "sample_slow_over_250":
        want(int(sampling.get("count", 0)) >= 2,
             "two completed samples are needed to measure the over-bound gap")
        want("freshness" in str(r.get("monitoring_failure", "")),
             "monitoring failure must mention the freshness bound")
    elif name == "expiry_during_sample":
        want(int(sampling.get("unfinished", 0)) >= 1,
             "the sample in flight at expiry must be recorded as unfinished")
        want(all(0 < int(age) <= int(PS_TIMEOUT_SECONDS * 1000) + 50
                 for age in sampling.get("unfinished_ages_ms", [])),
             f"unfinished ages must be honest and bounded: "
             f"{sampling.get('unfinished_ages_ms')}")
        want(r.get("monitor_stop_reason") == "wall",
             "monitor stop reason must be wall")
    elif name == "cancel_latency":
        cancel_latency_ok(want, r, "cancel during slow sample")
        want(int(sampling.get("unfinished", 0)) >= 1,
             "the sample in flight at cancel must be recorded as unfinished")
        want(wall_clock < 5.0,
             f"cancellation must stay bounded: {wall_clock}s")
    elif name == "sampler_runtime_failed":
        want("runtime sampler failed" in str(r.get("monitoring_failure", "")),
             "monitoring failure must mention the runtime sampler failure")
        want(r.get("monitor_stop_reason") == "monitoring",
             "monitor stop reason must be monitoring")
    elif name == "reader_partial_start":
        want("reader setup failed" in str(r.get("monitoring_failure", "")),
             "monitoring failure must mention the reader setup")
        want(r.get("pid") is not None, "launched identity must be retained")
        want(r.get("drain_incomplete") is True,
             "a partial reader start must never be a successful drain")
    elif name == "reader_mid_read_failure":
        want(r.get("drain_incomplete") is True,
             "a reader read error must make the drain incomplete")
        want("reader errors during drain" in str(
            r.get("monitoring_failure", "") or ""),
             "monitoring failure must mention the reader error")
    elif name == "post_launch_fault_monitor_start":
        want("post-launch monitor stage failed" in str(
            r.get("monitoring_failure", "")),
             "monitoring failure must name the post-launch funnel")
        want(r.get("pid") is not None, "launched identity must be retained")
        want(cleanup.get("reaped") is True,
             "the funnel must still reap the owned child")
    elif name == "post_launch_fault_terminate":
        want(cleanup.get("reaped") is True,
             "the bounded fallback stop must reap the child")
        want(any("terminate stage exception" in e
                 for e in cleanup.get("errors", [])),
             "the terminate exception must appear in cleanup errors")
        want(any("bounded fallback stop" in n for n in r.get("notes", [])),
             "the fallback stop must be noted")
        want(exit_code == EXIT_INTERNAL,
             "a cleanup exception must force a nonzero exit")
    elif name == "post_launch_fault_collect":
        want(r.get("drain_incomplete") is True,
             "a collect exception must make the drain incomplete")
        want("collect" in str(r.get("monitoring_failure", "")),
             "monitoring failure must mention the collect stage")
    elif name == "term_resistant_sampler_stalled":
        want("SIGKILL" in signals,
             f"SIGKILL escalation must be recorded, got {signals}")
        want(bool(group.get("sample_errors")),
             "the dead cleanup sampler must be recorded as errors")
        kill_events = [e for e in events if e.get("signal") == "SIGKILL"]
        want(kill_events and kill_events[0].get("result") == "sent"
             and type(raw.get("s_ns")) is int
             and 0 <= kill_events[0]["completed_ns"]-raw["s_ns"] <= 2_000_000_000,
             f"KILL must land within 2s of stop start despite the sampler: "
             f"{kill_events}")
        want(isinstance(reap, dict) and reap.get("observed_by") == "cleanup",
             "KILL-killed child must be reaped by the cleanup stage")
    elif name == "cleanup_normal_exit":
        want(isinstance(reap, dict) and reap.get("observed_by") == "cleanup",
             "the cleanup reap must be the observer of the wait status")
        want(child.get("exit_code") == 0,
             f"natural exit observed by cleanup, got {child.get('exit_code')}")
        want(child.get("signal") is None,
             "a natural exit must carry no signal")
        want(cleanup.get("ok") is True,
             f"cleanup must be ok: {cleanup.get('note')}")
    problems.extend(_selected_monitor_predicates(name, r))
    return problems


def _selected_monitor_predicates(name, r):
    """Selected finite scenarios require their actual trigger, not only the expected exit."""
    selected = {"a5_survivor", "b1_normal_cli", "b2_first_stall", "b4_later_stall",
                "rss_low", "c3_term_resistance", "b5_cancel_stalled"}
    if name not in selected:
        return []
    problems = []
    def want(ok, message):
        if not ok:
            problems.append(message)
    def integer(v):
        return type(v) is int and v > 0
    raw, sampling = r.get("timings_ns", {}), r.get("sampling", {})
    m, s = raw.get("m_ns"), raw.get("s_ns")
    observations = sampling.get("observations", [])
    count = sampling.get("count")
    want(integer(m) and integer(s) and m <= s, "selected raw M/S missing")
    want(r.get("drain_incomplete") is False and not r.get("output", {}).get("truncated"),
         "selected output incomplete/truncated")
    if not integer(m) or not integer(s):
        return problems
    if name in ("b1_normal_cli", "rss_low", "c3_term_resistance"):
        want(type(count) is int and count >= (2 if name == "b1_normal_cli" else 1),
             "healthy real sample evidence missing")
        accepted = [v for v in observations if not v.get("timed_out") and v.get("rows") is not None]
        want(len(accepted) == count, "healthy observation/acceptance count mismatch")
        unfinished = [v for v in observations if v not in accepted]
        want(not unfinished or (name == "c3_term_resistance" and len(unfinished) == 1
             and observations[-1] is unfinished[0] and unfinished[0].get("abort") == "deadline"
             and unfinished[0].get("rows") is None), "unexpected unfinished healthy observation")
        want(sampling.get("applied_period_ns") == 100_000_000,
             "selected sampling period changed")
        for index, observation in enumerate(accepted):
            start, done, observed, slot = (observation.get(k) for k in
                ("start_ns", "completed_ns", "observed_ns", "scheduled_due_ns"))
            valid = all(integer(v) for v in (start, done, observed, slot))
            accepted_at = observation.get("accepted_ns")
            previous_valid = m if index == 0 else accepted[index-1].get("accepted_ns")
            terminal_empty = (name == "b1_normal_cli" and index == len(accepted)-1
                and observation.get("rows") == {} and r.get("child", {}).get("exit_code") == 0
                and (r.get("group", {}).get("reap") or {}).get("observed_by") == "monitor"
                and integer(raw.get("reaped_at_ns")) and integer(observed)
                and raw["reaped_at_ns"] >= observed)
            want(valid and observation.get("abort") is None and observation.get("err") is None
                 and (bool(observation.get("rows")) or terminal_empty), "healthy bounded process sample missing")
            if valid:
                want(m <= slot <= start <= done <= observed
                     and observed-start <= 250_000_000
                     and (slot-m)%100_000_000 == 0 and start < slot+100_000_000,
                     "healthy sample age/cadence not anchored to M")
                want(integer(accepted_at) and integer(previous_valid)
                     and observed <= accepted_at and 0 <= accepted_at-start <= 250_000_000
                     and 0 <= accepted_at-previous_valid <= 250_000_000,
                     "healthy acceptance/original validity clock missing or stale")
        want(isinstance(sampling.get("max_gap_ms"), (int, float))
             and 0 <= sampling["max_gap_ms"] <= 250, "healthy gap outside freshness bound")
    if name in ("b2_first_stall", "b4_later_stall"):
        expected_count = 0 if name == "b2_first_stall" else 1
        want(count == expected_count and sampling.get("attempts") == expected_count+1
             and len(observations) == expected_count+1, "wrong selected stall boundary")
        origin = m if expected_count == 0 else sampling.get("v_ns")
        fact = sampling.get("freshness_breaches", [])
        want(len(fact) == 1 and not sampling.get("breaches"), "one early freshness refusal required")
        event = sampling.get("selected_event", {})
        if integer(origin) and len(fact) == 1:
            want(fact[0].get("origin_ns") == origin
                 and fact[0].get("cutoff_ns") == origin+250_000_000
                 and fact[0].get("decision_ns") == origin+230_000_000
                 and fact[0].get("early_refusal") is True
                 and event.get("kind") == "freshness"
                 and event.get("scheduled_ns") == origin+230_000_000
                 and integer(event.get("detected_ns"))
                 and origin+230_000_000 <= event["detected_ns"] <= s <= origin+250_000_000,
                 "stall clock renewed or actual early refusal missed")
        else:
            want(False, "stall original freshness origin missing")
        if observations:
            stalled = observations[-1]
            want(stalled.get("timed_out") is True and stalled.get("rows") is None
                 and stalled.get("abort") == "freshness"
                 and stalled.get("accepted_ns") is None
                 and stalled.get("completed_ns") is None,
                 "selected0.5s stall did not remain unfinished at refusal")
            if expected_count and len(observations) == 2:
                first = observations[0]
                want(not first.get("timed_out") and bool(first.get("rows"))
                     and first.get("accepted_ns") == origin
                     and integer(first.get("completed_ns"))
                     and m <= first["completed_ns"] <= origin < stalled.get("start_ns", 0),
                     "later stall lacks the first healthy real observation")
    elif name == "b5_cancel_stalled":
        received = raw.get("cancel_received_ns")
        event = sampling.get("selected_event", {})
        want(raw.get("cancel_requested_ns") == m+100_000_000
             and integer(received) and m+100_000_000 <= received < m+230_000_000,
             "actual M+100ms cancellation delivery did not precede freshness")
        want(event.get("kind") == "cancel" and event.get("scheduled_ns") == received
             and count == 0 and sampling.get("attempts") == 1 and len(observations) == 1
             and not sampling.get("freshness_breaches"), "cancellation did not win a full first stall")
        if observations and integer(received):
            observation = observations[0]
            want(observation.get("timed_out") is True and observation.get("abort") == "cancel"
                 and observation.get("rows") is None and observation.get("completed_ns") is None
                 and integer(observation.get("start_ns"))
                 and integer(observation.get("observed_ns"))
                 and observation["start_ns"] <= received <= observation["observed_ns"] <= s < m+250_000_000,
                 "cancellation was not observed during the stalled sample")
        cancel_latency_ok(want, r, "selected early cancellation")
    elif name == "b1_normal_cli":
        want(sum(bool(v.get("rows")) for v in observations) >= 2, "B1 needs multiple live healthy samples")
        want(r.get("limits", {}).get("wall_seconds") == 5
             and r["limits"].get("rss_mib") == 512 and r["limits"].get("output_bytes") == 262144
             and r["limits"].get("poll_ms") == 100 and r["limits"].get("cpu_seconds") is None,
             "B1 applied normal CLI limits mismatch")
        expected = "b1 normal ready\nb1 normal complete\n"
        out = r.get("output", {})
        want(out.get("head") == expected and out.get("total_bytes") == len(expected.encode())
             and out.get("captured_bytes") == out.get("total_bytes"), "B1 complete output missing")
        want(r.get("child", {}).get("exit_code") == 0 and r["child"].get("signal") is None,
             "B1 actual normal child exit0 missing")
    elif name == "rss_low":
        want(r.get("limits", {}).get("wall_seconds") == 5 and r["limits"].get("rss_mib") == 1
             and any(isinstance(v.get("rows"), dict) and sum(v["rows"].values()) > 1024
                     for v in observations), "finite baseline RSS threshold was not actually exceeded")
    if name in ("a5_survivor", "c3_term_resistance"):
        ready = r.get("fixture_ready") or {}
        entry, received, expiry = (ready.get(k) for k in ("e_ns", "received_ns", "expiry_ns"))
        kills = [v for v in r.get("group", {}).get("signal_events", [])
                 if v.get("pgid") == r.get("pgid") and v.get("signal") == "SIGKILL"]
        valid = all(integer(v) for v in (entry, received, expiry))
        want(valid and ready.get("case") == name and ready.get("term_ignore") is True
             and ready.get("pgid") == r.get("pgid") and ready.get("sid") == r.get("pgid"),
             "installed TERM-ignore identity/readiness missing")
        if valid:
            want(integer(raw.get("launch_started_ns")) and raw["launch_started_ns"] <= entry <= received
                 and m <= received < s < expiry == entry+5_000_000_000,
                 "selected finite readiness/lifetime order invalid")
            want(len(kills) == 1 and kills[0].get("result") == "sent" and kills[0].get("ok") is True
                 and integer(kills[0].get("completed_ns"))
                 and s+1_750_000_000 <= kills[0]["completed_ns"] <= s+2_000_000_000 < expiry,
                 "successful KILL before natural expiry missing")
            want(integer(raw.get("reaped_at_ns")) and raw["reaped_at_ns"] < expiry
                 and integer(raw.get("verification_end_ns")) and raw["verification_end_ns"] < expiry,
                 "termination/verification substituted natural expiry")
        if name == "c3_term_resistance":
            wall = r.get("wall_deadline_ns")
            event = sampling.get("selected_event", {})
            want(integer(wall) and wall == r.get("run_ns", 0)+500_000_000
                 and valid and received < wall <= s and event.get("kind") == "deadline"
                 and event.get("scheduled_ns") == wall
                 and r.get("child", {}).get("signal") == signal.SIGKILL,
                 "C3 live wall stop/actual SIGKILL wait missing")
            want((r.get("group", {}).get("reap") or {}).get("observed_by") == "cleanup"
                 and len(kills) == 1 and integer(kills[0].get("completed_ns"))
                 and integer(raw.get("reaped_at_ns")) and kills[0]["completed_ns"] <= raw["reaped_at_ns"],
                 "C3 actual cleanup wait did not follow its KILL dispatch")
        else:
            witness = r.get("survivor_observation") or {}
            order = [raw.get("reaped_at_ns"), witness.get("query_start_ns"),
                     witness.get("query_end_ns"), s]
            member = witness.get("member") or {}
            want(all(integer(v) for v in order) and order == sorted(order)
                 and order[-2] < s <= m+250_000_000
                 and member.get("pid") == ready.get("pid") != r.get("pid")
                 and member.get("pgid") == r.get("pgid") and "Z" not in member.get("stat", "Z")
                 and member in witness.get("rows", [])
                 and r.get("child", {}).get("exit_code") == 0
                 and (r.get("group", {}).get("reap") or {}).get("observed_by") == "monitor",
                 "A5 actual leader reap/live same-group descendant before S missing")
    return problems


def launch_threads_ok(r: dict) -> bool:
    """RLIMIT_CPU preexec may only be used when no other thread was alive."""
    threads = r.get("launch_threads", {})
    if threads.get("preexec_fn"):
        return not threads.get("other_threads")
    return True


def cancel_latency_ok(want, r: dict, context: str) -> None:
    """Observed cancellation latency must stay within the freshness bound."""
    latency = r.get("timings_ns", {}).get("cancel_latency_ns")
    want(type(latency) is int, f"{context}: raw cancel latency missing")
    if type(latency) is int:
        want(0 <= latency <= FRESHNESS_BOUND_MS*1_000_000,
             f"{context}: cancel latency {latency}ns exceeds bound")


def run_bootstrap(workload: list) -> int:
    """Gate bootstrap for one diagnostic workload launch (r2 Task 1).

    Starts in the actual separate session created by the inner's gated Popen,
    registers its own PID/PGID/SID and per-case token, then waits on the
    private release pipe. It cannot execute the supplied workload before a
    matching release. The registration write and release read are bounded by
    the 500 ms lease from entry; once release metadata arrives the received
    H/W/F are enforced as well. Every control descriptor is closed before
    exec, so no workload descendant inherits a channel, and exec preserves
    this PID/PGID/SID so reap and group ownership stay stable.
    """
    entry = time.monotonic_ns()
    lease = entry + BOOTSTRAP_LEASE_MS * 1_000_000
    if not workload:
        note("bootstrap requires a workload after --")
        return EXIT_USAGE
    keys = ("RB_GATE_REG_FD", "RB_GATE_TOKEN", "RB_GATE_CASE",
            "RB_RELEASE_FD")
    missing = [key for key in keys if not os.environ.get(key)]
    if missing:
        note("incomplete bootstrap gate context; missing "
             + ", ".join(missing))
        return EXIT_USAGE
    try:
        reg_fd = int(os.environ["RB_GATE_REG_FD"])
        release_fd = int(os.environ["RB_RELEASE_FD"])
    except ValueError:
        note("bootstrap descriptors are not integers")
        return EXIT_USAGE
    if min(reg_fd, release_fd) < 3 or reg_fd == release_fd:
        note("bootstrap descriptors are not distinct private endpoints")
        return EXIT_USAGE
    token = os.environ["RB_GATE_TOKEN"]
    case = os.environ["RB_GATE_CASE"]

    try:
        os.set_blocking(reg_fd, False)
        os.set_blocking(release_fd, False)
        registration = {"kind": "bootstrap", "case": case, "token": token,
                        "pid": os.getpid(), "pgid": os.getpgrp(),
                        "sid": os.getsid(0)}
        if case == A2_PARENT_EXIT_CASE:
            registration.update(entry_ns=entry, lease_ns=lease)
        elif case == A5_UNRELATED_CASE:
            control_pid = int(os.environ["RB_A5_CONTROL_PID"])
            if control_pid <= 0 or control_pid in (os.getpid(), os.getppid()):
                raise ValueError("A5 control identity is not unrelated")
            registration.update(pid=control_pid, pgid=control_pid, sid=control_pid,
                                bootstrap_pid=os.getpid(), entry_ns=entry, lease_ns=lease)
        if case in INSTRUMENTED_CASES:
            # Non-authoritative producer timestamps for the two headless checks and the
            # native preview route only. bootstrap_entry_ns reuses the existing entry
            # sample; the second is a pre-write observation, not proof of write completion.
            registration["bootstrap_entry_ns"] = entry
            registration["registration_write_started_ns"] = time.monotonic_ns()
        error = _write_gate_frame(reg_fd, registration, lease)
        if error:
            note(f"bootstrap registration refused: {error}")
            return EXIT_USAGE
    except OSError as exc:
        note(f"bootstrap registration failed: {type(exc).__name__}: {exc}")
        return EXIT_USAGE
    finally:
        try:
            os.close(reg_fd)   # registration writer is never retained
        except OSError:
            pass

    release = None
    buf = bytearray()
    release_frames = []
    release_bytes = 0
    try:
        while True:
            if time.monotonic_ns() >= lease:
                note("bootstrap lease expired before release")
                return EXIT_INTERNAL
            try:
                chunk = os.read(release_fd, 4096)
            except BlockingIOError:
                time.sleep(0.001)
                continue
            except OSError as exc:
                note(f"bootstrap release read failed: "
                     f"{type(exc).__name__}: {exc}")
                return EXIT_INTERNAL
            if chunk == b"":
                if len(release_frames) != 1 or buf:
                    if case == A2_PARENT_EXIT_CASE:
                        event = {"kind": "a2_bootstrap_abort", "case": case,
                                 "token": token, "pid": os.getpid(),
                                 "pgid": os.getpgrp(), "sid": os.getsid(0),
                                 "entry_ns": entry, "lease_ns": lease,
                                 "observed_ns": time.monotonic_ns(),
                                 "reason": "release_eof",
                                 "release_bytes": release_bytes,
                                 "release_frames": len(release_frames),
                                 "exec_attempted": False}
                        os.set_blocking(sys.stderr.fileno(), False)
                        error = _write_gate_frame(sys.stderr.fileno(), event, lease)
                        if error:
                            note(f"A2 bootstrap abort evidence failed: {error}")
                        return EXIT_INTERNAL
                    if case == A5_UNRELATED_CASE:
                        event = {"kind": "a5_bootstrap_abort", "case": case, "token": token,
                                 "pid": os.getpid(), "pgid": os.getpgrp(), "sid": os.getsid(0),
                                 "entry_ns": entry, "lease_ns": lease,
                                 "observed_ns": time.monotonic_ns(), "reason": "release_eof",
                                 "release_bytes": release_bytes, "release_frames": len(release_frames),
                                 "exec_attempted": False}
                        os.set_blocking(sys.stderr.fileno(), False)
                        error = _write_gate_frame(sys.stderr.fileno(), event, lease)
                        if error:
                            note(f"A5 bootstrap abort evidence failed: {error}")
                        return EXIT_INTERNAL
                    note("bootstrap aborted: incomplete release transaction")
                    return EXIT_INTERNAL
                release = release_frames[0]
                break
            release_bytes += len(chunk)
            buf.extend(chunk)
            if release_bytes > FRAME_MAX_BYTES:
                note("bootstrap release frame oversized")
                return EXIT_INTERNAL
            frames, frame_error = _split_frames(buf)
            if frame_error:
                note(f"bootstrap release rejected: {frame_error}")
                return EXIT_INTERNAL
            if frames:
                release_frames.extend(frames)
                if len(release_frames) > 1:
                    note("bootstrap aborted: duplicate release")
                    return EXIT_INTERNAL
    finally:
        try:
            os.close(release_fd)
        except OSError:
            pass

    # Recheck identity, H/W/F and the lease after receipt and immediately
    # before exec; a late or mismatched release is never usable.
    problems: list = []
    if release.get("kind") != "release":
        problems.append("release frame kind mismatch")
    if release.get("case") != case or release.get("token") != token:
        problems.append("release case/token mismatch")
    try:
        own_pgid = os.getpgrp()
        own_sid = os.getsid(0)
    except OSError as exc:
        problems.append(f"session identity query failed: {exc}")
        own_pgid = own_sid = -1
    if (any(type(release.get(k)) is not int or release[k] <= 0
            for k in ("pid", "pgid", "sid"))
            or release.get("pid") != os.getpid() or release.get("pgid") != own_pgid
            or release.get("sid") != own_sid):
        problems.append("release identity does not match this bootstrap")
    clocks = ("m_ns", "h_ns", "w_ns", "f_ns", "decision_ns")
    if any(type(release.get(k)) is not int or release[k] <= 0 for k in clocks):
        problems.append("release clock types invalid")
    else:
        m, h, w, f, d = (release[k] for k in clocks)
        preview_policy = case == GODOT_NATIVE_PREVIEW_CASE
        freshness_ms = (PREVIEW_FRESHNESS_BOUND_MS if preview_policy
                        else FRESHNESS_BOUND_MS)
        handoff_ms = PREVIEW_HANDOFF_MS if preview_policy else HANDOFF_MS
        if (f != m + freshness_ms * 1_000_000
                or d != f - FRESHNESS_DECISION_LEAD_MS * 1_000_000
                or h != min(m + handoff_ms * 1_000_000, w, d) or not m < h):
            problems.append("release clock relationships invalid")
    now_ns = time.monotonic_ns()
    for label in ("h_ns", "w_ns", "f_ns", "decision_ns"):
        value = release.get(label)
        if type(value) is not int:
            problems.append(f"release carries no {label}")
        elif now_ns >= value:
            problems.append(f"release applied after {label} "
                            f"({now_ns} >= {value})")
    if now_ns >= lease:
        problems.append("bootstrap lease expired before exec")
    if problems:
        note("bootstrap refused exec: " + "; ".join(problems))
        return EXIT_INTERNAL

    target = list(workload)
    for key in (*GATE_ENV_KEYS, "RB_RELEASE_FD", "RB_A5_CONTROL_PID"):
        os.environ.pop(key, None)
    try:
        if time.monotonic_ns() >= min(lease, *(release[key] for key in
                ("h_ns", "w_ns", "f_ns", "decision_ns"))):
            return EXIT_INTERNAL
        if "/" in target[0]:
            os.execv(target[0], target)
        else:
            os.execvp(target[0], target)
    except OSError as exc:
        note(f"bootstrap exec failed: {type(exc).__name__}: {exc}")
        return EXIT_INTERNAL
    return EXIT_INTERNAL  # exec never returns on success


def run_diagnose_one(name: str, record_path) -> int:
    """Inner containment mode: run exactly one case in this process.

    The outer harness starts this mode under a hard outer boundary. Each
    case's evidence is written to its own record file so that a hung or
    killed inner process can never corrupt another case's record.
    """
    if name not in DIAGNOSE_CASES:
        note(f"unknown diagnose case: {name}")
        return EXIT_USAGE
    if name in OUTER_SELFTEST_CASES:
        # Architect r2 A1: outer-only finite stall. The inner process itself
        # ignores TERM and self-limits at four seconds (well inside the five
        # second workload self-limit), so the outer boundary must escalate to
        # the required KILL. No workload and no descendant are launched here,
        # and no signal handler other than the deliberate TERM ignore is
        # installed, so the record is written by the outer only.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        ready_ns = time.monotonic_ns()
        ready = _report_text(
            f"CASE {name} READY term_ignore=true ready_ns={ready_ns}\n",
            sys.stderr, ready_ns+100_000_000)
        if not ready["complete"]:
            return EXIT_INTERNAL
        time.sleep(max(0, ready_ns+4_000_000_000-time.monotonic_ns())/1e9)
        return EXIT_INTERNAL
    if not record_path:
        note("diagnose-one requires --record <path>")
        return EXIT_USAGE
    install_signal_handlers()
    describe, argv, case_opts = case_specs()[name]
    stage(f"diagnose-{name}")
    diagnose_stage = dict(STAGE_LOG[-1])
    started = time.monotonic()
    try:
        result = supervise(argv, {**case_opts, "emit_output": False})
        wall_clock = round(time.monotonic() - started, 3)
        problems = check_diagnose(name, result, wall_clock)
    except Exception as exc:  # noqa: BLE001 - funnel into a fail-closed record
        wall_clock = round(time.monotonic() - started, 3)
        result = {"reason": "internal", "exit_code": EXIT_INTERNAL,
                  "elapsed_seconds": wall_clock,
                  "fatal": f"{type(exc).__name__}: {exc}"}
        problems = [f"inner supervisor raised: {type(exc).__name__}: {exc}"]
    stage("record")
    result["stages"] = [diagnose_stage] + list(STAGE_LOG)
    record = {
        "argv": list(argv),
        "case": name,
        "describe": describe,
        "inner": True,
        "passed": not problems,
        "problems": problems,
        "recorded_at_utc": utcnow(),
        "result": result,
        "wall_clock_seconds": wall_clock,
    }
    record["sink"] = write_record_once(
        record_path, record, end_ns=result.get("evidence_deadline_ns"))
    if not record["sink"]["primary_ok"] or record["sink"]["late"]:
        problems.append("inner evidence incomplete or late")
    report = _report_text(
        f"CASE {name} pre-report-verdict={'PASS' if not problems else 'FAIL'} ({wall_clock}s)\n",
        sys.stderr, result.get("evidence_deadline_ns"))
    if not report["complete"] or REPORTING_ERRORS:
        problems.append("final reporting incomplete")
    return 0 if not problems else 1


def _drain_pipes(proc, stop_at: float, cap: int) -> tuple:
    """Read both pipes in slices until EOF, deadline or byte cap.

    Bytes beyond the cap are consumed and discarded, so a verbose process
    can never block on a full pipe while the deadline still holds.
    Returns (stdout_bytes, stderr_bytes, capped, open_at_stop).
    """
    stdout_chunks: list = []
    stderr_chunks: list = []
    stored = 0
    capped = False
    streams = {proc.stdout: stdout_chunks, proc.stderr: stderr_chunks}
    open_fds = set(streams)
    for handle in streams:
        try:
            os.set_blocking(handle.fileno(), False)
        except OSError:
            open_fds.discard(handle)
    while open_fds and time.monotonic() < stop_at:
        for handle in list(open_fds):
            try:
                chunk = os.read(handle.fileno(), 65536)
            except BlockingIOError:
                continue
            except OSError:
                open_fds.discard(handle)
                continue
            if not chunk:
                open_fds.discard(handle)
                continue
            if stored < cap:
                room = cap - stored
                keep = chunk[:room]
                streams[handle].append(keep)
                stored += len(keep)
                if len(chunk) > len(keep):
                    capped = True
            else:
                capped = True
        if open_fds:
            time.sleep(0.01)
    return (b"".join(stdout_chunks), b"".join(stderr_chunks),
            capped, bool(open_fds))


PS_MAX_CAPTURE_BYTES = 256 * 1024


def _ps_table(timeout_s=PS_TIMEOUT_SECONDS, *, end_ns=None, meta=None,
              diag=None) -> tuple:
    """Require a complete capped kernel snapshot with controller visibility.

    PREVIEW01 option D: when a private diagnostic context is supplied, the SAME single
    existing `_ps_capture` request appends an `rss=` column. RSS is parsed privately for
    preview accounting; the returned authoritative rows stay exactly
    {pid,pgid,ppid,stat} with unchanged meaning, and every other caller keeps its exact
    four-column request, byte cap, deadline/cutoff and query cleanup.
    """
    if end_ns is None:
        end_ns = time.monotonic_ns() + int(timeout_s * 1e9)
    if meta is not None:
        meta.update(validation_end_ns=None, validation_status="unexecuted")
    if diag is not None:
        diag["rss_kib"] = {}
        diag["query_pid"] = None
        diag["query_ppid"] = None
        diag["query_pgid"] = None
        diag["error"] = None
    columns = "pid=,pgid=,ppid=,stat=" + (",rss=" if diag is not None else "")
    out, query_pid, error = _ps_capture(columns, end_ns, meta)

    def finish(result: tuple) -> tuple:
        if meta is not None:
            meta["validation_end_ns"] = time.monotonic_ns()
            meta["validation_status"] = "ok" if result[1] is None else result[1]
        if diag is not None:
            diag["query_pid"] = query_pid
            if result[1] is not None:
                diag["error"] = result[1]
        return result

    if error:
        return finish((None, error))
    rows = {}
    fields = 5 if diag is not None else 4
    try:
        for line in out.decode("utf-8", "strict").splitlines():
            parts = line.split()
            if len(parts) != fields:
                return finish((None, "incomplete process-table row"))
            row = {"pid": int(parts[0]), "pgid": int(parts[1]),
                   "ppid": int(parts[2]), "stat": parts[3]}
            if row["pid"] < 0 or row["pgid"] < 0 or row["ppid"] < 0:
                return finish((None, "invalid process-table identity"))
            if row["pid"] in rows:
                return finish((None, "duplicate process-table identity"))
            rows[row["pid"]] = row
            if diag is not None:
                rss = int(parts[4])
                if rss < 0:
                    return finish((None, "invalid private process-table rss"))
                diag["rss_kib"][row["pid"]] = rss
    except (ValueError, UnicodeError) as exc:
        return finish((None, f"invalid process-table output: {exc}"))
    me = rows.get(os.getpid())
    if me is None or me["pgid"] != os.getpgrp():
        return finish((None, "querying controller absent or group mismatched"))
    if time.monotonic_ns() > end_ns:
        return finish((None, "process-table validation exceeded cutoff"))
    if diag is not None and query_pid in rows:
        diag["query_ppid"] = rows[query_pid]["ppid"]
        diag["query_pgid"] = rows[query_pid]["pgid"]
    return finish((list(rows.values()), None))

def _ps_tree(root_pid: int) -> tuple:
    """Exact-identity descendants and their group ids from one snapshot.

    Returns (descendant_pids, descendant_pgids, error). The root's own
    process group is the caller's to handle (it is the inner supervisor).
    """
    rows, err = _ps_table()
    if err is not None:
        return [], [], err
    children: dict = {}
    for row in rows:
        children.setdefault(row["ppid"], []).append(row["pid"])
    seen: set = set()
    stack = [root_pid]
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        stack.extend(children.get(pid, []))
    descendants = sorted(seen - {root_pid})
    pgids: set = set()
    for row in rows:
        if row["pid"] in seen and row["pid"] != root_pid:
            pgids.add(row["pgid"])
    return descendants, sorted(pgids), None


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _a5_stop_owned(proc, control_proc, control, info, targets, pending, lease_ns, *,
                   observe_allowed=True, capture=None):
    """D13 only: direct union signals/reaps with one nonblocking termination witness."""
    s = _stop_origin(info)
    end, kill_at, witness_end = s+4_000_000_000, s+1_750_000_000, s+1_700_000_000
    info.setdefault("termination_start_ns", s)
    info.update(termination_deadline_ns=end, kill_target_ns=kill_at,
                kill_deadline_ns=s+2_000_000_000)
    control.setdefault("reaped", False)
    target_groups = [g for g in targets if g != control_proc.pid]
    worker, box, attempted = None, {}, False
    witness = {"deadline_ns": witness_end, "complete": False,
               "source": "actual bounded ps table", "error": None}
    if observe_allowed:
        info["control_witness"] = witness
    else:
        witness = info.setdefault("control_witness", witness)
        witness.update(complete=False, error="witness unavailable after coordinator fault")

    def dispatch(gid, sig):
        send_group(gid, sig, info)
        info["signal_events"][-1]["authority"] = (
            "direct_control_popen" if gid == control_proc.pid else
            "direct_inner_popen" if proc is not None and gid == proc.pid else "admitted_workload")

    # No witness, log or helper creation precedes direct TERM.
    for gid in targets:
        if not any(e["pgid"] == gid and e["signal"] == "SIGTERM" for e in info["signal_events"]):
            dispatch(gid, signal.SIGTERM)
    open_streams = set()
    if capture is not None and proc is not None:
        open_streams = set(capture.get("a5_open_streams", ["out", "err"]))
        for stream in (proc.stdout, proc.stderr):
            os.set_blocking(stream.fileno(), False)

    def observe():
        try:
            rows, error = _ps_table(end_ns=witness_end)
            if error:
                box["error"] = error
            else:
                box["validated_row_count"] = len(rows)
                box["rows"] = [r for r in rows if r["pgid"] in targets or
                    r["pid"] in pending or r["pgid"] in pending or r["pid"] == os.getpid()]
                box["target_members"] = [r for r in rows if r["pgid"] in target_groups]
                box["pending_members"] = [r for r in rows if r["pid"] in pending or r["pgid"] in pending]
                box["control_row"] = next((r for r in rows if r["pid"] == control_proc.pid), None)
                box["control_pgid"] = os.getpgid(control_proc.pid)
                box["control_sid"] = os.getsid(control_proc.pid)
        except Exception as exc:
            box["error"] = f"control witness failed: {type(exc).__name__}: {exc}"
        finally:
            box["end_ns"] = time.monotonic_ns()

    while True:
        now = time.monotonic_ns()
        for key in tuple(open_streams):
            stream = proc.stdout if key == "out" else proc.stderr
            try:
                chunk = os.read(stream.fileno(), 65536)
            except BlockingIOError:
                continue
            except OSError as exc:
                capture.setdefault("read_errors", []).append(f"A5 {key} read failed: {exc}")
                open_streams.remove(key)
                continue
            if not chunk:
                open_streams.remove(key)
                continue
            used = (len(capture.get("stdout", b""))+len(capture.get("stderr", b""))
                    + capture.get("control_ready_bytes", 0))
            field = "stdout" if key == "out" else "stderr"
            capture.setdefault(field, bytearray()).extend(chunk[:max(0, OUTER_PIPE_CAP_BYTES-used)])
            if len(chunk) > OUTER_PIPE_CAP_BYTES-used:
                capture["capped"] = True
        if (capture is not None and not open_streams and not capture.get("read_errors")
                and not capture.get("capped") and "a5_capture_completed_ns" not in capture):
            capture["a5_capture_completed_ns"] = time.monotonic_ns()
        if proc is not None and not info.get("reaped"):
            try:
                code = proc.poll()
                if code is not None:
                    info.update(inner_exit=proc.returncode, reaped_at_ns=time.monotonic_ns())
                    info["reaped"] = True
            except Exception as exc:
                info["errors"].append(f"A5 direct-inner reap failed: {exc}")
        if not control.get("reaped"):
            try:
                outcome, status, usage = try_reap(control_proc.pid)
                if outcome == "reaped":
                    _store_reap(control, status, usage, observed_by="outer_control")
                    control_proc.returncode = os.waitstatus_to_exitcode(status)
                    control["reaped_at_ns"] = time.monotonic_ns()
                elif outcome == "gone":
                    if control_proc.returncode is not None:
                        control.update(reaped=True, reaped_at_ns=time.monotonic_ns(),
                            popen_wait={"exit_code": control_proc.returncode,
                                        "raw_status_available": False,
                                        "observer": "retained Popen.poll"})
                        control["wait_error"] = "shared raw wait data unavailable after premature control exit"
                    else:
                        control["wait_error"] = "direct-control wait unavailable"
            except Exception as exc:
                control["wait_error"] = f"direct-control reap failed: {exc}"
        remaining = [g for g in targets if _group_state(g) != "gone"]
        target_gone = not any(g in remaining for g in target_groups)
        target_reaped = proc is None or info.get("reaped") is True
        now = time.monotonic_ns()
        if (observe_allowed and not attempted and proc is not None and target_gone and target_reaped
                and type(lease_ns) is int and now >= lease_ns and now < witness_end):
            attempted = True
            witness.update(start_ns=time.monotonic_ns(), target_gone_ns=now,
                           target_reaped_ns=info.get("reaped_at_ns"), lease_ns=lease_ns)
            try:
                worker = threading.Thread(target=observe, name="run_bounded-a5-witness", daemon=True)
                worker.start()
            except Exception as exc:
                witness["error"] = f"witness worker start failed: {exc}"
        if worker is not None and not worker.is_alive() and "end_ns" in box:
            witness.update(box)
            row = box.get("control_row") or {}
            witness["complete"] = (not box.get("error") and box["end_ns"] <= witness_end
                and box.get("target_members") == [] and box.get("pending_members") == []
                and row.get("pid") == row.get("pgid") == box.get("control_pgid")
                == box.get("control_sid") == control_proc.pid
                and row.get("ppid") == os.getpid() and "Z" not in row.get("stat", "Z"))
        # Main-thread clock/signal work never waits for the witness worker.
        if now >= kill_at:
            for gid in remaining:
                if not any(e["pgid"] == gid and e["signal"] == "SIGKILL" for e in info["signal_events"]):
                    dispatch(gid, signal.SIGKILL)
        if target_reaped and control.get("reaped") is True and not remaining:
            break
        if time.monotonic_ns() >= end:
            info["cutoff_misses"].append("A5 termination deadline reached before complete union reap/disappearance")
            break
        wake = min(end, kill_at) if now < kill_at else end
        time.sleep(max(0, min(SAMPLE_SLICE_S, (wake-time.monotonic_ns())/1e9)))
    if worker is not None and not worker.is_alive() and "end_ns" in box:
        witness.update(box)
    witness["worker_unfinished"] = (worker is not None and worker.is_alive()) if observe_allowed else None
    if not witness["complete"] or witness["worker_unfinished"]:
        witness["error"] = witness["error"] or "one timely target-empty/B-absent/C-live witness missing"
        info["errors"].append(witness["error"])
    if not control.get("reaped") or control.get("wait_error"):
        info["errors"].append(control.get("wait_error") or "direct-control reap unconfirmed")
    info["termination_end_ns"] = time.monotonic_ns()
    if info["termination_end_ns"] > end:
        info["cutoff_misses"].append("A5 termination completed after cutoff")


def _escalate_process(proc, owned_groups=None, *, state=None, pending=None,
                      control_proc=None, control=None, lease_ns=None, capture=None,
                      query_meta=None, preview_diag=None) -> dict:
    """Direct stop and one complete verification under the original stop clock."""
    info = state if state is not None else {}
    for key in ("signal_events", "signals", "cutoff_misses", "sample_errors", "errors"):
        info.setdefault(key, [])
    info.setdefault("reaped", False)
    s = _stop_origin(info)
    targets = list(dict.fromkeys([*([proc.pid] if proc is not None else []),
                                  *(owned_groups or []),
                                  *([control_proc.pid] if control_proc is not None else [])]))
    targets = [g for g in targets if g not in (os.getpid(), os.getpgrp())]
    info["targets"] = targets
    try:
        if control_proc is not None:
            _a5_stop_owned(proc, control_proc, control, info, targets, set(pending or []), lease_ns,
                           capture=capture)
        else:
            _direct_stop(proc.pid, targets, info, proc)
    except Exception as exc:
        info["errors"].append(f"outer stop failed: {type(exc).__name__}: {exc}")
        try:
            if control_proc is None:
                _emergency_stop(proc.pid, targets, info, proc)
            else:
                # Resume only direct signals/reaps against the retained S/T;
                # no new witness, stage clock or final-verification allowance.
                _a5_stop_owned(proc, control_proc, control, info, targets,
                               set(pending or []), lease_ns, observe_allowed=False)
        except Exception as fallback:
            info["errors"].append(f"emergency stop failed: {fallback}")
    info["errors"].extend(info["sample_errors"])
    start = time.monotonic_ns()
    end = min(start+1_000_000_000, s+5_000_000_000)
    info.update(verification_start_ns=start, verification_deadline_ns=end,
                verification_complete=False, survivors_after_kill=None,
                zombies=None, pending_remaining=None, verification_error=None)
    # Pending identifiers are observation-only, never signal targets.
    pending = set(pending or [])
    try:
        # A pending bootstrap has a 500ms no-release lease. Observe it once
        # after that interval, still inside the one verification allowance.
        if pending and control_proc is None:
            lease_end = min(start+BOOTSTRAP_LEASE_MS*1_000_000, end)
            while time.monotonic_ns() < lease_end:
                time.sleep(min(SAMPLE_SLICE_S, max(0, lease_end-time.monotonic_ns())/1e9))
        rows, error = _ps_table(end_ns=end, meta=query_meta, diag=preview_diag)
        if error:
            info["verification_error"] = error
        else:
            if control_proc is not None:
                info["verification_owned_groups"] = list(targets)
                info["verification_pending_ids"] = sorted(pending)
                info["verification_validated_row_count"] = len(rows)
                info["verification_identity_rows"] = [r for r in rows if r["pgid"] in targets
                    or r["pid"] in pending or r["pgid"] in pending or r["pid"] == os.getpid()]
            info["survivors_after_kill"] = sorted(
                r["pid"] for r in rows if r["pgid"] in targets and "Z" not in r["stat"])
            info["zombies"] = sorted(
                r["pid"] for r in rows if r["pgid"] in targets and "Z" in r["stat"])
            info["pending_remaining"] = sorted(
                r["pid"] for r in rows if r["pid"] in pending or r["pgid"] in pending)
            info["verification_complete"] = not info["pending_remaining"]
        if not info["verification_complete"]:
            info["verification_error"] = info["verification_error"] or "pending disappearance unconfirmed"
    except Exception as exc:
        info["verification_error"] = f"verification failed: {type(exc).__name__}: {exc}"
    if query_meta is not None:
        # RUN02-OBS01: observed timing for the existing verification query only;
        # attached to the same escalation evidence, never a new sink.
        info["verification_query"] = query_meta
    info["verification_end_ns"] = time.monotonic_ns()
    if info["verification_end_ns"] > end:
        info["cutoff_misses"].append("outer verification cutoff missed")
        info["verification_complete"] = False
    if info["verification_error"]:
        info["errors"].append(info["verification_error"])
    if info["survivors_after_kill"] or info["zombies"]:
        info["errors"].append("retained group not empty at verification")
    if proc is not None and not info.get("reaped"):
        info["errors"].append("direct inner reap unconfirmed")
    for label in ("TERM", "KILL"):
        events = [e for e in info["signal_events"] if e["signal"] == "SIG"+label]
        info[label.lower()+"_at_ms"] = max(
            ((e["completed_ns"]-s)/1e6 for e in events), default=None)
    info["term_join_s"] = (info.get("termination_end_ns", s)-s)/1e9
    if preview_diag is not None:
        # PREVIEW01 option D: the retained-outer RSS phase captured from the SAME existing
        # outer verification query, stored on the outer receipt where it actually occurs.
        info["preview_outer_rss"] = _preview_outer_phase(preview_diag, proc, info, end)
    return info


def _preview_outer_phase(diag: dict, inner_proc, info: dict, cutoff_ns: int) -> dict:
    """Bounded outer-verification RSS phase for the preview route (option D).

    Uses only the same single verification query's privately parsed RSS. The retained
    outer is live here; the inner is retired only on positive direct-child reap. A
    retained query PID whose row is transiently absent is the approved disclosed gap (not
    zero and not a failure); an observed query row must validate its parent, inherited
    group and RSS. A same-observation total at or above the threshold is an accounting
    failure. Missing or invalid measurements are never counted as zero.
    """
    outer_pid, outer_pgid = os.getpid(), os.getpgrp()
    rss = dict(diag.get("rss_kib") or {})
    query_pid = diag.get("query_pid")
    query_observed = query_pid is not None and query_pid in rss
    query_rss = int(rss[query_pid]) if query_observed else None
    members = {}
    if outer_pid in rss:
        members[outer_pid] = int(rss[outer_pid])
    if query_observed:
        members[query_pid] = query_rss
    inner_pid = inner_proc.pid if inner_proc is not None else None
    inner_reaped = bool(inner_proc is not None and inner_proc.returncode is not None)
    query_ok = True
    if query_observed:
        query_ok = (diag.get("query_ppid") == outer_pid
                    and diag.get("query_pgid") == outer_pgid
                    and type(query_rss) is int and query_rss >= 0)
    observed_bytes = sum(members.values()) * 1024
    # One acceptance read, taken once. Measurement usability requires the observation to
    # have completed timely AND every existing shared outer retirement/verification fact to
    # hold, with the retained outer present and correct provenance. A transiently absent
    # query row is the approved disclosed gap (not zero, not a failure). Resource validity
    # additionally requires the total below the threshold; a complete high observation is
    # still usable and belongs in the measured maximum.
    accepted = time.monotonic_ns()
    v_start, v_end = info.get("verification_start_ns"), info.get("verification_end_ns")
    s_ns, reaped_at = info.get("s_ns"), info.get("reaped_at_ns")
    inner_exit = info.get("inner_exit")
    clock_ok = (all(type(v) is int for v in (v_start, v_end, accepted, cutoff_ns))
                and v_start <= v_end <= accepted <= cutoff_ns)
    lifecycle_ok = (info.get("verification_error") is None
                    and info.get("verification_complete") is True
                    and info.get("survivors_after_kill") == []
                    and info.get("zombies") == []
                    and info.get("pending_remaining") == []
                    and info.get("reaped") is True
                    and inner_proc is not None and inner_proc.returncode is not None
                    and inner_proc.returncode == inner_exit
                    and type(reaped_at) is int and type(s_ns) is int
                    and reaped_at > 0 and reaped_at <= s_ns + 4_000_000_000)
    complete = (diag.get("error") is None and clock_ok and lifecycle_ok)
    measurement_usable = (complete and outer_pid in members and query_ok
                          and observed_bytes > 0)
    valid = measurement_usable and observed_bytes < PREVIEW_AGG_RSS_BYTES
    return {
        "phase": "outer_verification",
        "valid": bool(valid),
        "accounting_failure": not bool(valid),
        "metric": "observed_aggregate_rss_kib_x1024",
        "threshold_bytes": PREVIEW_AGG_RSS_BYTES,
        "outer_pid": outer_pid, "outer_pgid": outer_pgid,
        "inner_pid": inner_pid, "inner_reaped": inner_reaped,
        "members": members,
        "query_pid": query_pid,
        "query_observed": bool(query_observed),
        "query_absent": not query_observed,
        "query_rss_kib": query_rss,
        "observed_bytes": observed_bytes,
        "complete": bool(complete),
        "measurement_usable": bool(measurement_usable),
        "over_threshold": observed_bytes >= PREVIEW_AGG_RSS_BYTES,
        "start_ns": v_start,
        "end_ns": v_end,
        "cutoff_ns": cutoff_ns,
        "accepted_ns": accepted,
        "error": diag.get("error"),
        "note": ("retained outer current RSS from the SAME verification query; an absent "
                 "transient query row is a disclosed gap, not zero"),
    }


def _synthetic_case_record(name: str, describe: str, argv: list,
                           failure: str) -> dict:
    """Fail-closed record for an inner process that never reported."""
    return {
        "argv": list(argv or []),
        "case": name,
        "describe": describe,
        "inner": False,
        "passed": False,
        "problems": [failure],
        "recorded_at_utc": utcnow(),
        "result": {"reason": "outer_failure", "exit_code": None},
        "wall_clock_seconds": None,
    }


def _frame_bytes(payload: dict) -> bytes:
    """One newline-terminated JSON gate frame, hard-capped at FRAME_MAX_BYTES."""
    data = (json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    if len(data) > FRAME_MAX_BYTES:
        raise ValueError(f"gate frame exceeds {FRAME_MAX_BYTES} bytes ({len(data)})")
    return data


def _split_frames(buf: bytearray) -> tuple:
    """Consume complete frames from a bounded accumulation buffer.

    Returns (frames, error). Accumulation is already capped by the caller; a
    frame over FRAME_MAX_BYTES or a non-JSON line is an admission error,
    never a silent drop.
    """
    frames: list = []
    while True:
        newline = buf.find(b"\n")
        if newline < 0:
            break
        line = bytes(buf[:newline])
        del buf[:newline + 1]
        if not line.strip():
            return frames, "empty gate frame"
        if len(line) + 1 > FRAME_MAX_BYTES:
            return frames, f"gate frame exceeds {FRAME_MAX_BYTES} bytes"
        try:
            frame = json.loads(line.decode("utf-8"))
            if not isinstance(frame, dict):
                return frames, "gate frame must be an object"
            frames.append(frame)
        except ValueError as exc:
            return frames, f"malformed gate frame: {exc}"
    if len(frames) > 2:
        return frames, "more gate frames than the two expected registrations"
    return frames, None


def _write_gate_frame(fd: int, payload: dict, deadline: int) -> str | None:
    """Bounded nonblocking frame write; returns an error string or None.

    A write failure aborts the handoff and is reported once; it is never
    retried past the deadline and never suppresses the signal path.
    """
    try:
        data = _frame_bytes(payload)
    except ValueError as exc:
        return str(exc)
    view = memoryview(data)
    deadline_ns = deadline
    while view:
        remaining = deadline_ns - time.monotonic_ns()
        if remaining <= 0:
            return "gate write deadline expired before the frame was sent"
        try:
            written = os.write(fd, view)
        except BlockingIOError:
            time.sleep(0.001)
            continue
        except OSError as exc:
            return f"gate write failed: {type(exc).__name__}: {exc}"
        if written <= 0:
            return "gate write made no progress"
        view = view[written:]
        if time.monotonic_ns() >= deadline_ns:
            return "gate write completed at or after its cutoff"
    return None


def _admit_candidate(frames: list, *, case: str, token: str, inner_proc,
                     controller_pid: int, controller_pgid: int,
                     admission_meta: dict | None = None) -> tuple:
    """F01 admission: one receipt plus one bootstrap registration, proven live.

    Returns (owned_identity_or_None, ack_payload_or_None, problems). Only a
    promoted identity enters the owned signal set; a rejected, late or
    unverifiable candidate stays pending and is never signalled.
    """
    problems: list = []
    inner_pid = inner_proc.pid
    receipts = [f for f in frames if f.get("kind") == "receipt"]
    regs = [f for f in frames if f.get("kind") == "bootstrap"]
    other = [f for f in frames
             if f.get("kind") not in ("receipt", "bootstrap")]
    if other or len(receipts) != 1 or len(regs) != 1:
        return None, None, [
            "expected exactly one receipt and one bootstrap registration, "
            f"got kinds {[f.get('kind') for f in frames]}"]
    receipt, registration = receipts[0], regs[0]
    for label, frame in (("receipt", receipt), ("registration", registration)):
        if frame.get("case") != case or frame.get("token") != token:
            problems.append(f"{label} case/token mismatch")
    if type(receipt.get("child_pid")) is not int or receipt["child_pid"] <= 0:
        problems.append("receipt has no positive integer child pid")
    if type(receipt.get("inner_pid")) is not int or receipt["inner_pid"] != inner_pid:
        problems.append("receipt does not identify retained Popen parent")
    clocks = ("m_ns", "h_ns", "w_ns", "f_ns", "decision_ns")
    if any(type(receipt.get(key)) is not int or receipt[key] <= 0 for key in clocks):
        problems.append("receipt has invalid raw clock fields")
    else:
        m, h, w, f, d = (receipt[key] for key in clocks)
        preview_policy = case == GODOT_NATIVE_PREVIEW_CASE
        freshness_ms = (PREVIEW_FRESHNESS_BOUND_MS if preview_policy
                        else FRESHNESS_BOUND_MS)
        handoff_ms = PREVIEW_HANDOFF_MS if preview_policy else HANDOFF_MS
        if (f != m + freshness_ms * 1_000_000
                or d != f - FRESHNESS_DECISION_LEAD_MS * 1_000_000
                or h != min(m + handoff_ms * 1_000_000, w, d)
                or not m < h <= min(w, d, f)):
            problems.append("receipt raw cutoffs are incoherent")
    if problems:
        return None, None, problems

    child_pid = receipt["child_pid"]
    candidate = registration.get("pid")
    pgid = registration.get("pgid")
    sid = registration.get("sid")
    if not all(type(v) is int and v > 0 for v in (candidate, pgid, sid)):
        return None, None, ["registration identity is not three integers"]
    if candidate != child_pid:
        problems.append(
            f"registration pid {candidate} does not match the retained inner "
            f"receipt child {child_pid}")
    if not (candidate == pgid == sid):
        problems.append("candidate is not a new-session leader (pid=pgid=sid)")
    protected = {controller_pid, controller_pgid, inner_pid}
    if candidate in protected or pgid in protected or sid in protected:
        problems.append("candidate identity collides with a protected identity")
    if problems:
        return None, None, problems

    # Live-parent provenance: ps for the parent, direct syscalls for the
    # group and session, both taken while the retained inner is still live.
    if CANCEL.is_set() or inner_proc.poll() is not None or time.monotonic_ns() >= h:
        return None, None, ["admission cancelled, expired or parent exited before query"]
    rows, query_error = _ps_table(end_ns=h, meta=admission_meta)
    if query_error:
        return None, None, [f"kernel identity query unusable: {query_error}"]
    by_pid = {row["pid"]: row for row in rows}
    candidate_row = by_pid.get(candidate)
    inner_row = by_pid.get(inner_pid)
    if inner_row is None or "Z" in inner_row["stat"]:
        problems.append("retained inner is not live during the identity query")
    if candidate_row is None or "Z" in candidate_row["stat"]:
        problems.append("candidate is not visible in the kernel identity query")
    if candidate_row is not None and candidate_row["ppid"] != inner_pid:
        problems.append(
            f"candidate parentage {candidate_row['ppid']} is not the retained "
            f"inner {inner_pid}")
    try:
        live_pgid = os.getpgid(candidate)
        live_sid = os.getsid(candidate)
    except OSError as exc:
        problems.append(f"candidate group/session query failed: {exc}")
    else:
        if live_pgid != pgid or live_sid != sid:
            problems.append(
                f"candidate group/session mismatch: live pgid={live_pgid} "
                f"sid={live_sid}, registered pgid={pgid} sid={sid}")
    if inner_proc.poll() is not None:
        problems.append("retained inner died before promotion")
    if CANCEL.is_set() or time.monotonic_ns() >= h:
        problems.append("admission cancelled or expired after identity query")
    if problems:
        return None, None, problems

    owned = {"pid": candidate, "pgid": pgid, "sid": sid,
             "ppid": candidate_row["ppid"],
             "validated_at_ns": time.monotonic_ns()}
    ack = {"kind": "ack", "case": case, "token": token, "pid": candidate,
           "pgid": pgid, "sid": sid, "child_pid": child_pid,
           **{key: receipt.get(key) for key in
              ("m_ns", "h_ns", "w_ns", "f_ns", "decision_ns")}}
    return owned, ack, problems


def _outer_pump(proc, reg_r, stop_at: int, cap: int, on_frames=None,
                *, state=None, collection=False, progress=None,
                reg_obs=None) -> dict:
    """Read bounded slices; raw due events precede callbacks and completion."""
    result = {"stdout": bytearray(), "stderr": bytearray(), "capped": False,
              "open_at_end": False, "frames": [], "reg_buf": bytearray(),
              "reg_error": None, "reg_eof": False, "read_errors": [],
              "stopped_reason": None, "registration_bytes": 0,
              "ready_observed_ns": None, "live_at_deadline": False}
    if progress is not None:
        progress.update(result)
        result = progress
    fds = {"out": proc.stdout.fileno(), "err": proc.stderr.fileno()}
    if reg_r is not None:
        fds["reg"] = reg_r
    for fd in fds.values():
        os.set_blocking(fd, False)
    active = set(fds)
    while True:
        now = time.monotonic_ns()
        if now >= stop_at or (not collection and CANCEL.is_set()):
            result["stopped_reason"] = "deadline" if now >= stop_at else "cancel"
            if state is not None:
                _stop_origin(state)
            result["live_at_deadline"] = proc.poll() is None
            break
        if not active:
            completed = collection or proc.poll() is not None
            # A reap observed after expiry cannot bypass the due-event check.
            if time.monotonic_ns() >= stop_at or (not collection and CANCEL.is_set()):
                continue
            if completed:
                break
        progressed = False
        for key in sorted(active):
            if time.monotonic_ns() >= stop_at:
                break
            try:
                chunk = os.read(fds[key], 65536)
            except BlockingIOError:
                # RUN04-OBS02: retain only the latest no-ready sample BEFORE the first
                # complete bootstrap frame. Once that frame latches, freeze the slot so a
                # later wait-for-EOF read cannot overwrite the pre-frame bracket.
                if (reg_obs is not None and key == "reg"
                        and reg_obs["bootstrap_frame_read_ns"] is None):
                    reg_obs["last_reg_blocking_ns"] = time.monotonic_ns()
                continue
            except OSError as exc:
                result["read_errors"].append(f"{key} read failed: {exc}")
                active.remove(key)
                continue
            progressed = True
            if not chunk:
                active.remove(key)
                if key == "reg":
                    result["reg_eof"] = True
                    if reg_obs is not None:
                        # RUN04-OBS01: controller observed registration EOF.
                        reg_obs["registration_eof_ns"] = time.monotonic_ns()
                    if result["reg_buf"] or (result["frames"] and len(result["frames"]) != 2):
                        result["reg_error"] = "incomplete registration transaction"
                    elif len(result["frames"]) == 2 and on_frames:
                        if time.monotonic_ns() >= stop_at or CANCEL.is_set():
                            result["reg_error"] = "outer cutoff before admission"
                        else:
                            if reg_obs is not None:
                                # RUN04-OBS01: admission-callback dispatch sample.
                                reg_obs["admission_dispatch_ns"] = time.monotonic_ns()
                            result["reg_error"] = on_frames(list(result["frames"]))
                continue
            if key == "reg":
                result["registration_bytes"] += len(chunk)
                if result["registration_bytes"] > REG_AGG_MAX_BYTES:
                    result["reg_error"] = "registration aggregate cap exceeded"
                    continue
                result["reg_buf"].extend(chunk)
                frames, error = _split_frames(result["reg_buf"])
                result["frames"].extend(frames)
                if reg_obs is not None and frames:
                    # RUN04-OBS01: first complete frame of each kind the controller
                    # decoded; frames decoded from one read share this sample.
                    observed_ns = time.monotonic_ns()
                    for frame in frames:
                        if frame.get("kind") == "receipt" \
                                and reg_obs["receipt_frame_read_ns"] is None:
                            reg_obs["receipt_frame_read_ns"] = observed_ns
                        elif frame.get("kind") == "bootstrap" \
                                and reg_obs["bootstrap_frame_read_ns"] is None:
                            reg_obs["bootstrap_frame_read_ns"] = observed_ns
                if len(result["frames"]) > 2:
                    error = "more than two registration frames"
                result["reg_error"] = result["reg_error"] or error
            else:
                used = len(result["stdout"]) + len(result["stderr"])
                target = result["stdout"] if key == "out" else result["stderr"]
                target.extend(chunk[:max(0, cap-used)])
                if len(chunk) > cap-used:
                    result["capped"] = True
                if key == "err" and result["ready_observed_ns"] is None:
                    if b" READY term_ignore=true ready_ns=" in target and target.endswith(b"\n"):
                        result["ready_observed_ns"] = time.monotonic_ns()
        if state is not None and state.get("a5_refused") is True:
            result["stopped_reason"] = "expected admission refusal"
            result["a5_open_streams"] = sorted(active.intersection(("out", "err")))
            break
        if result["reg_error"] or result["read_errors"] or result["capped"]:
            result["stopped_reason"] = "protocol/read/output failure"
            if state is not None:
                _stop_origin(state)
            break
        if not progressed:
            time.sleep(min(SAMPLE_SLICE_S, max(0, stop_at-time.monotonic_ns())/1e9))
    result["open_at_end"] = bool(active)
    result["stopped_reason"] = result["stopped_reason"] or "pipes closed"
    result["completed_ns"] = time.monotonic_ns()
    if state is not None:
        _stop_origin(state)
    return result


def _read_record_bounded(path, end_ns):
    box = {}
    def read():
        try:
            with open(path, "rb") as handle:
                data = handle.read(OUTER_PIPE_CAP_BYTES+1)
            if len(data) > OUTER_PIPE_CAP_BYTES:
                raise ValueError("inner record exceeds evidence cap")
            value = json.loads(data)
            if not isinstance(value, dict):
                raise ValueError("inner record is not an object")
            box["record"] = value
        except Exception as exc:
            box["error"] = f"inner record read failed: {exc}"
        box["completed_ns"] = time.monotonic_ns()
    if time.monotonic_ns() >= end_ns:
        return None, "no evidence read budget"
    worker = threading.Thread(target=read, name="run_bounded-record-read", daemon=True)
    worker.start()
    worker.join(max(0, end_ns-time.monotonic_ns())/1e9)
    if worker.is_alive() or time.monotonic_ns() > end_ns:
        return None, "inner record read incomplete before cutoff"
    return box.get("record"), box.get("error")


def _a2_parent_exit_predicates(c: dict) -> list:
    """Only the named, observed pre-admission parent exit is an expected refusal."""
    problems = []
    def want(ok, message):
        if not ok:
            problems.append(message)
    def integer(value):
        return type(value) is int and value > 0
    a2, e, promotion = c["expected_parent_exit"], c["escalation"], c["promotion"]
    want(c["spawn"].get("case") == A2_PARENT_EXIT_CASE, "A2 case identity missing")
    spawn = c["spawn"]
    digest = spawn.get("source_sha256")
    want(integer(spawn.get("pid")) and spawn.get("pid") == spawn.get("pgid")
         and spawn.get("clock") == "monotonic_ns"
         and isinstance(digest, str) and len(digest) == 64
         and all(v in "0123456789abcdef" for v in digest), "A2 source/outer identity missing")
    want(integer(spawn.get("started_ns"))
         and spawn.get("deadline_ns") == spawn["started_ns"]+int(OUTER_RUNTIME_S*1e9),
         "A2 original outer deadline missing/changed")
    want(a2.get("expected_refusal") is True, "A2 exact parent-exit refusal missing")
    want(a2.get("inner_record_absent") is True, "A2 expected missing inner record unproved")
    wait = a2.get("parent_wait") or {}
    want(wait.get("exit_code") == A2_PARENT_EXIT_CODE
         and c.get("inner_exit") == e.get("inner_exit") == A2_PARENT_EXIT_CODE
         and wait.get("observed_ns") == e.get("reaped_at_ns"),
         "A2 actual direct-inner wait missing or unexpected")
    pending_wait = a2.get("pending_wait") or {}
    want(pending_wait.get("available") is False and pending_wait.get("status") is None,
         "A2 orphan wait must remain unavailable")
    want(promotion.get("attempted") is True and promotion.get("owned") is None
         and promotion.get("ack_error") is None
         and promotion.get("ack_completed_ns") is None
         and promotion.get("rejected") ==
             "admission cancelled, expired or parent exited before query",
         "A2 candidate was promoted, ACKed or refused for another cause")
    want(not c.get("outer_timeout") and c.get("pump_stop_reason") == "pipes closed",
         "A2 expected branch ended by timeout/error")
    want(a2.get("registration_eof") is True, "A2 complete registration EOF missing")
    frames = c.get("registration_frames", [])
    receipts = [v for v in frames if v.get("kind") == "receipt"]
    registrations = [v for v in frames if v.get("kind") == "bootstrap"]
    events = a2.get("events", [])
    parents = [v for v in events if v.get("kind") == "a2_parent_exit"]
    aborts = [v for v in events if v.get("kind") == "a2_bootstrap_abort"]
    complete = (len(frames) == 2 and len(receipts) == len(registrations) == 1
                and len(events) == 2 and len(parents) == len(aborts) == 1)
    want(complete, "A2 needs one receipt, registration, parent-exit and EOF-abort event")
    if not complete:
        return problems
    receipt, registration, parent, abort = receipts[0], registrations[0], parents[0], aborts[0]
    token = a2.get("case_token")
    want(isinstance(token, str) and all(v.get("case") == A2_PARENT_EXIT_CASE
         and v.get("token") == token for v in (receipt, registration, parent, abort)),
         "A2 case/token evidence mismatch")
    candidate = receipt.get("child_pid")
    want(pending_wait.get("pid") == candidate, "A2 unavailable wait identity missing")
    want(integer(candidate) and candidate != c["spawn"].get("pid")
         and receipt.get("inner_pid") == parent.get("inner_pid") == c["spawn"].get("pid")
         and parent.get("child_pid") == candidate
         and all(v.get(k) == candidate for v in (registration, abort)
                 for k in ("pid", "pgid", "sid")), "A2 actual candidate identity mismatch")
    want(a2.get("pending_ids") == [candidate]
         and candidate not in e.get("targets", [])
         and all(v.get("pgid") != candidate for v in e.get("signal_events", [])),
         "A2 pending identity missing or candidate was signalled")
    want(parent.get("exit_code") == A2_PARENT_EXIT_CODE
         and parent.get("ack_attempted") is False and parent.get("released") is False,
         "A2 no-ACK/no-release trigger evidence missing")
    want(abort.get("reason") == "release_eof" and abort.get("exec_attempted") is False
         and type(abort.get("release_bytes")) is int and abort["release_bytes"] == 0
         and type(abort.get("release_frames")) is int and abort["release_frames"] == 0,
         "A2 positive unreleased EOF/no-exec proof missing")
    clocks = [receipt.get(k) for k in ("m_ns", "h_ns", "w_ns", "f_ns", "decision_ns")]
    order = [receipt.get("m_ns"), parent.get("receipt_completed_ns"),
             parent.get("release_close_started_ns"), parent.get("release_closed_ns"),
             parent.get("exit_selected_ns"), wait.get("observed_ns"),
             a2.get("admission_started_ns"), a2.get("admission_end_ns")]
    valid = all(integer(v) for v in [*clocks, *order])
    want(valid, "A2 missing raw M/H/W/F or parent/admission clocks")
    if valid:
        m, h, w, f, d = clocks
        want(f == m+FRESHNESS_BOUND_MS*1_000_000
             and d == f-FRESHNESS_DECISION_LEAD_MS*1_000_000
             and h == min(m+HANDOFF_MS*1_000_000, w, d)
             and m < h and order == sorted(order) and order[-1] < h,
             "A2 parent exit/admission was late or clocks renewed")
    entry, lease, eof = (abort.get(k) for k in ("entry_ns", "lease_ns", "observed_ns"))
    valid_lease = all(integer(v) for v in (entry, lease, eof))
    want(valid_lease, "A2 bootstrap lease/EOF clocks missing")
    if valid_lease:
        want(registration.get("entry_ns") == entry and registration.get("lease_ns") == lease
             and lease == entry+BOOTSTRAP_LEASE_MS*1_000_000 and entry <= eof < lease,
             "A2 original bootstrap lease/EOF invalid or late")
        if valid:
            want(parent["release_close_started_ns"] <= eof,
                 "A2 EOF predates release-writer close attempt")
        captured = a2.get("capture_completed_ns")
        want(integer(captured) and eof <= captured < lease,
             "A2 complete abort evidence capture missing or late")
        want(integer(e.get("verification_end_ns")) and e["verification_end_ns"] >= lease,
             "A2 bounded disappearance observation precedes original lease")
    return problems


def _outer_predicates(containment: dict, *, a1=False) -> list:
    """Raw shared facts; missing evidence never behaves like an empty group."""
    c, e = containment, containment["escalation"]
    problems = []
    def want(ok, message):
        if not ok:
            problems.append(message)
    def integer(value):
        return type(value) is int and value > 0
    s = e.get("s_ns")
    want(integer(s), "missing raw stop origin")
    if not integer(s):
        return problems
    previous_end = s
    for label, allowance, cap in (("termination", 4_000_000_000, 4_000_000_000),
                                   ("verification", 1_000_000_000, 5_000_000_000),
                                   ("collection", 2_000_000_000, 7_000_000_000)):
        start, end, cutoff = (e.get(label+k) for k in
                              ("_start_ns", "_end_ns", "_deadline_ns"))
        valid = all(integer(v) for v in (start, end, cutoff))
        want(valid, f"missing {label} clock facts")
        if valid:
            want(previous_end <= start <= end <= cutoff == min(start+allowance, s+cap),
                 f"{label} timing failed")
            previous_end = end
            if label == "termination":
                want(start == s, "termination did not retain S")
    want(e.get("reaped") is True and integer(e.get("reaped_at_ns"))
         and e["reaped_at_ns"] <= s+4_000_000_000, "real timely reap missing")
    want(c.get("pending_identity_status") in ("identified", "not applicable: no workload"),
         "pending identity unknown")
    want(e.get("verification_complete") is True
         and e.get("survivors_after_kill") == [] and e.get("zombies") == []
         and e.get("pending_remaining") == [], "positive complete emptiness missing")
    want(e.get("collection_complete") is True, "collection incomplete")
    want(integer(e.get("post_stop_end_ns"))
         and e["post_stop_end_ns"] <= s+7_000_000_000, "post-stop completion missing/late")
    want(not e.get("errors") and not e.get("cutoff_misses")
         and not e.get("verification_error"), "outer cleanup errors")
    want(not c.get("read_errors") and not c.get("capped")
         and not c.get("registration_error"), "outer read/registration/output fault")
    targets = set(e.get("targets", []))
    inner = c["spawn"].get("pid")
    control = c.get("direct_control") if c["spawn"].get("case") == A5_UNRELATED_CASE else None
    want(targets == {inner, *([c["promotion"]["owned"]["pgid"]]
                              if c["promotion"].get("owned") else []),
                    *([control["pgid"]] if control else [])},
         "signal ownership set mismatch")
    for event in e.get("signal_events", []):
        want(event.get("pgid") in targets, "unowned signal target")
        want(event.get("result") in ("sent", "nonexistent"), "signal dispatch error")
        completed = event.get("completed_ns")
        want(integer(completed), "signal completion missing")
        if integer(completed):
            limit = 50_000_000 if event.get("signal") == "SIGTERM" else 2_000_000_000
            want(0 <= completed-s <= limit, "signal completion late/invalid")
    if c["promotion"].get("owned"):
        gate = c.get("inner_gate") or {}
        owned = c["promotion"]["owned"]
        ordered = [gate.get("m_ns"), gate.get("receipt_completed_ns"),
                   owned.get("validated_at_ns"), owned.get("promoted_at_ns"),
                   c["promotion"].get("ack_completed_ns"), gate.get("ack_at_ns"),
                   gate.get("release_at_ns"), gate.get("h_ns")]
        want(all(integer(v) for v in ordered) and ordered == sorted(ordered)
             and ordered[-2] < ordered[-1], "complete raw admission/release ordering missing")
        want(gate.get("released") is True and not any(gate.get(k) for k in
             ("receipt_error", "ack_error", "release_error")), "workload release not confirmed")
    if a1:
        spawn = c["spawn"]
        want(spawn.get("pid") == spawn.get("pgid") and integer(inner), "A1 identity missing")
        digest = spawn.get("source_sha256")
        want(spawn.get("case") == "a1_outer_stall" and isinstance(digest, str)
             and len(digest) == 64 and all(v in "0123456789abcdef" for v in digest),
             "A1 source/case missing")
        want(spawn.get("deadline_ns") == spawn.get("started_ns", 0)+1_000_000_000,
             "A1 applied deadline is not one second")
        want(c.get("outer_timeout") is True and c.get("pump_stop_reason") == "deadline"
             and c.get("live_at_deadline") is True and s >= spawn["deadline_ns"],
             "A1 live deadline stop missing")
        ready, observed = c.get("ready_ns"), c.get("ready_observed_ns")
        want(integer(ready) and integer(observed)
             and spawn["started_ns"] <= ready <= observed <= spawn["deadline_ns"],
             "A1 TERM-ignore readiness missing or late")
        want(c.get("gate_applicability") == "not applicable: A1 has no workload",
             "A1 gate applicability missing")
        for label, low, high in (("SIGTERM", 0, 50_000_000),
                                  ("SIGKILL", 1_750_000_000, 2_000_000_000)):
            events = [v for v in e.get("signal_events", [])
                      if v.get("pgid") == inner and v.get("signal") == label]
            want(len(events) == 1 and events[0].get("result") == "sent"
                 and events[0].get("ok") is True
                 and integer(events[0].get("completed_ns"))
                 and low <= events[0]["completed_ns"]-s <= high,
                 f"A1 successful timely {label} missing")
        want(e.get("inner_exit") == -signal.SIGKILL, "A1 actual wait was not SIGKILL")
    return problems


def _godot_parse_predicates(c, r):
    """Parser-specific facts; a quick natural exit still needs fresh monitoring."""
    problems = []
    def want(ok, message):
        if not ok:
            problems.append(message)
    def integer(v):
        return type(v) is int and v > 0
    spawn, e = c["spawn"], c["escalation"]
    want(c.get("inner_exit") == e.get("inner_exit") == 0 and isinstance(r, dict),
         "parse actual normal-supervisor exit0/record missing")
    if not isinstance(r, dict):
        return problems
    try:
        problems.extend(check_diagnose(GODOT_PARSE_CASE, r, r.get("elapsed_seconds", 0)))
        cmd = spawn.get("cmd", [])
        path = cmd[cmd.index("--record")+1] if "--record" in cmd else None
        expected = [sys.executable, "-B", os.path.abspath(__file__),
            "--wall-seconds", "5", "--rss-mib", "512", "--output-bytes", "262144",
            "--poll-ms", "100", "--keep-output", "--record", path, "--", *GODOT_PARSE_ARGV]
        want(cmd == expected and isinstance(path, str)
             and os.path.basename(path) == GODOT_PARSE_CASE+".inner.json"
             and r.get("argv") == list(GODOT_PARSE_ARGV), "parse fixed normal/engine argv mismatch")
        want(spawn.get("case") == GODOT_PARSE_CASE
             and integer(spawn.get("started_ns"))
             and spawn.get("deadline_ns") == spawn["started_ns"]+8_000_000_000
             and r.get("supervisor_sha256") == spawn.get("source_sha256"),
             "parse source/case/original8s outer clock missing")
        limits, raw, gate = r.get("limits", {}), r.get("timings_ns", {}), r.get("gate") or {}
        want(all(limits.get(k) == v for k, v in
                 (("wall_seconds", 5), ("rss_mib", 512), ("output_bytes", 262144), ("poll_ms", 100)))
             and r.get("keep_output") is True and integer(r.get("run_ns"))
             and r.get("wall_deadline_ns") == r["run_ns"]+5_000_000_000,
             "parse applied limits/capture/original R+5s clock mismatch")
        m, h, w = gate.get("m_ns"), gate.get("h_ns"), gate.get("w_ns")
        want(all(integer(v) for v in (m, h, w)) and m == raw.get("m_ns")
             and w == r.get("wall_deadline_ns") and h == min(m+100_000_000, w, m+230_000_000)
             and gate.get("f_ns") == m+250_000_000 and gate.get("decision_ns") == m+230_000_000,
             "parse original M/H/W/F equations missing/changed")
        child, group = r.get("child", {}), r.get("group", {})
        reap = group.get("reap") or {}
        want(r.get("exit_code") == 0 and r.get("reason") == r.get("monitor_stop_reason") == "ok"
             and child.get("exit_code") == 0 and child.get("signal") is None
             and reap.get("exited") is True and reap.get("exit_code") == 0
             and reap.get("signaled") is False and reap.get("signal") is None
             and reap.get("observed_by") == "monitor", "parse actual natural Godot wait0 missing")
        want(not r.get("monitoring_failure") and not r.get("launch_error")
             and r.get("fixture_ready") is None and r.get("drain_incomplete") is False
             and group.get("survivors_verified") == [] and not group.get("sample_errors"),
             "parse unknown monitoring/readiness/capture/verification")
        sampler = r.get("sampler", {})
        want(all(sampler.get(k) == "ps_sample" for k in ("kind", "cleanup_kind", "verify_kind"))
             and integer(sampler.get("probe_rows")), "parse actual responsive probe/sampler missing")
        out = r.get("output", {})
        text, total, captured = out.get("head"), out.get("total_bytes"), out.get("captured_bytes")
        want(type(total) is int and type(captured) is int and 0 <= total == captured <= 262144
             and out.get("truncated") is False and isinstance(text, str) and "\ufffd" not in text,
             "parse complete output missing/truncated/undecodable")
        if isinstance(text, str):
            encoded = text.encode("utf-8")
            want(len(encoded) == captured
                 and c.get("stdout_tail") == encoded[-2000:].decode("utf-8", "replace"),
                 "parse enclosing output capture mismatch")
            for line in text.splitlines():
                upper = line.strip().upper()
                want(not any(marker in upper for marker in
                     ("ERROR:", "PARSE ERROR", "SCRIPT ERROR", "FAILED TO LOAD", "FAILED LOADING",
                      "CANNOT LOAD", "COULD NOT LOAD", "COMPILATION FAILED")),
                     "parse error output: "+line[:200])
                want(upper not in ("STAGE", "SUITE") and not upper.startswith(("STAGE ", "SUITE ")),
                     "parse runner executed: "+line[:200])
        sink_lines = [line[len("evidence sink: "):] for line in c.get("stderr_tail", "").splitlines()
                      if line.startswith("evidence sink: ")]
        want(len(sink_lines) == 1, "parse enclosing inner-sink completion missing")
        if len(sink_lines) == 1:
            sink = json.loads(sink_lines[0])
            want(sink.get("path") == path and sink.get("primary_ok") is True
                 and sink.get("writer_pending") is False and sink.get("late") is False
                 and sink.get("primary_error") is None and integer(sink.get("started_ns"))
                 and integer(sink.get("completed_ns")) and integer(r.get("evidence_deadline_ns"))
                 and sink["started_ns"] <= sink["completed_ns"] <= r["evidence_deadline_ns"],
                 "parse inner primary write incomplete/late")
        sampling = r.get("sampling", {})
        observations = sampling.get("observations")
        want(isinstance(observations, list), "parse actual monitoring observations missing")
        observations = observations if isinstance(observations, list) else []
        count, attempts, unfinished = (sampling.get(k) for k in ("count", "attempts", "unfinished"))
        want(type(count) is int and count >= 0 and count == r.get("samples")
             and type(attempts) is int and attempts == len(observations)
             and type(unfinished) is int and unfinished == 0
             and isinstance(sampling.get("unfinished_ages_ms"), list)
             and isinstance(sampling.get("unfinished_reasons"), list)
             and unfinished == len(sampling.get("unfinished_ages_ms", []))
                            == len(sampling.get("unfinished_reasons", []))
             and sampling.get("applied_period_ns") == 100_000_000 and sampling.get("m_ns") == m,
             "parse actual sample counters/cadence missing")
        want(sampling.get("breaches") == [] and sampling.get("freshness_breaches") == []
             and sampling.get("selected_event") is None, "parse stale/fault stop cannot pass")
        accepted = [v for v in observations if integer(v.get("accepted_ns"))]
        want(count == len(accepted), "parse accepted sample count mismatch")
        previous = m
        for observation in observations:
            clocks = [observation.get(k) for k in ("start_ns", "completed_ns", "observed_ns", "accepted_ns")]
            due = observation.get("scheduled_due_ns")
            rows = observation.get("rows")
            want(not observation.get("timed_out") and observation.get("abort") is None
                 and observation.get("err") is None and isinstance(rows, dict)
                 and all(type(v) is int and v >= 0 for v in rows.values()),
                 "parse unfinished/unknown sample cannot be healthy")
            valid = integer(previous) and all(integer(v) for v in clocks) and integer(due)
            want(valid and clocks == sorted(clocks) and due >= m and (due-m)%100_000_000 == 0
                 and due <= clocks[0] and 0 <= clocks[-1]-clocks[0] <= 250_000_000
                 and previous <= clocks[-1] <= previous+230_000_000,
                 "parse stale/nonanchored accepted observation")
            if integer(clocks[-1]):
                previous = clocks[-1]
        origin, end, age = (sampling.get(k) for k in ("tail_origin_ns", "monitor_end_ns", "tail_age_ns"))
        want(all(integer(v) for v in (m, origin, end)) and type(age) is int
             and origin == previous and end >= origin and age == end-origin and 0 <= age <= 250_000_000
             and (sampling.get("v_ns") == previous if accepted else sampling.get("v_ns") is None)
             and integer(raw.get("reaped_at_ns")) and raw["reaped_at_ns"] <= end,
             "parse fast exit has stale/unknown tail or natural wait")
    except Exception as exc:
        problems.append(f"parse result schema/predicate failed: {exc}")
    return problems


def _runner_result_predicates(name: str, suite: str, out_dir) -> list:
    """Verify the runner's own result file and completion marker (RUN01 checked sink).

    This runs BEFORE the case verdict/write, so a missing, undecodable, incomplete or
    NOT RUN-bearing result cannot be accepted as a pass even on exit 0.
    """
    problems: list = []

    def want(cond, message: str) -> None:
        if not cond:
            problems.append(message)

    expected = (PLAY01_FOCUS_EXPECTED_IDS if suite == "play01_focus"
                else DEV_SMOKE_EXPECTED_IDS)
    results_found: list = []
    markers: list = []
    if isinstance(out_dir, str) and os.path.isdir(out_dir):
        for entry in sorted(os.listdir(out_dir)):
            # RUN01 F02: the completion marker also ends in ".json", so the more specific
            # suffix has to be classified first. Matched the other way round, a healthy sink
            # looks like two results and zero markers.
            if entry.startswith("checks_") and entry.endswith(".json.complete.json"):
                markers.append(os.path.join(out_dir, entry))
            elif entry.startswith("checks_") and entry.endswith(".json"):
                results_found.append(os.path.join(out_dir, entry))
    want(len(results_found) == 1,
         f"{name}: expected exactly one runner result file, found {len(results_found)}")
    want(len(markers) == 1,
         f"{name}: expected exactly one completion marker, found {len(markers)}")
    if len(results_found) == 1:
        try:
            with open(results_found[0], encoding="utf-8") as handle:
                body = json.loads(handle.read())
        except Exception as exc:
            problems.append(f"{name}: runner result is not decodable JSON: {exc}")
            return problems
        want(isinstance(body, dict), f"{name}: runner result is not a JSON object")
        if not isinstance(body, dict):
            return problems
        want(body.get("schema") == "m01.1"
             and body.get("kind") == "junior_check_results",
             f"{name}: runner result schema/kind mismatch")
        want(body.get("profile") == suite and body.get("seed") == 3101,
             f"{name}: runner profile/seed mismatch: "
             f"{body.get('profile')!r}/{body.get('seed')!r}")
        rows = body.get("results")
        want(isinstance(rows, list), f"{name}: runner results list missing")
        rows = rows if isinstance(rows, list) else []
        ids = [str(r.get("id", "")) for r in rows if isinstance(r, dict)]
        want(len(ids) == len(set(ids)), f"{name}: duplicate record ids: {ids}")
        want(sorted(ids) == sorted(expected),
             f"{name}: record set mismatch, missing={sorted(set(expected) - set(ids))} "
             f"extra={sorted(set(ids) - set(expected))}")
        not_run = [i for i in ids
                   if any(isinstance(r, dict) and r.get("id") == i
                          and r.get("not_run") for r in rows)]
        failed = [i for i in ids
                  if any(isinstance(r, dict) and r.get("id") == i
                         and not r.get("not_run") and not r.get("pass") for r in rows)]
        want(not not_run, f"{name}: NOT RUN records cannot count as success: {not_run}")
        want(not failed, f"{name}: failing records: {failed}")
        totals = body.get("totals")
        want(isinstance(totals, dict)
             and int(totals.get("pass", -1)) == len(expected)
             and int(totals.get("fail", -1)) == 0
             and int(totals.get("not_run", -1)) == 0,
             f"{name}: totals must be {len(expected)} pass / 0 fail / 0 not run, "
             f"got {totals!r}")
        want(body.get("unattempted_ids") == [], f"{name}: unattempted ids present")
        want(body.get("duplicate_ids") == [], f"{name}: duplicate ids present")
        stop = body.get("stop")
        want(isinstance(stop, dict) and not stop.get("stopped"),
             f"{name}: selected route reported a stop: {stop!r}")
        deadline = body.get("deadline")
        steps = body.get("steps")
        # RUN01 F04: these fields are sampled before the result is written, so they are a
        # necessary condition only. Timely *final* completion is proven by the exactly-once
        # `checked sink: ... deadline_ok=true` line together with the natural exit; a
        # pre-I/O timestamp on its own must never be accepted as that proof.
        want(isinstance(deadline, dict) and deadline.get("ok") is True
             and isinstance(deadline.get("wall_ms"), int)
             and deadline.get("wall_ms") > 0
             and type(deadline.get("remaining_ms")) is int
             and int(deadline.get("remaining_ms", 0)) > 0,
             f"{name}: deadline accounting missing/not on positive remainder: {deadline!r}")
        want(isinstance(steps, dict) and type(steps.get("attempted")) is int
             and type(steps.get("completed")) is int
             and type(steps.get("manual_tick_jumps")) is int
             and 0 <= int(steps.get("completed", -1)) <= int(steps.get("attempted", -1)),
             f"{name}: step accounting missing/inconsistent: {steps!r}")
        if suite == "play01_focus":
            want(int(steps.get("ceiling", 0)) == 4096
                 and int(steps.get("attempted", 99999)) <= 4096,
                 f"{name}: play01_focus step ceiling not respected: {steps!r}")
            want(int(deadline.get("wall_ms", 0)) == 3000,
                 f"{name}: play01_focus deadline is not 3000ms: {deadline!r}")
        elif suite == "dev_smoke":
            # RUN01 F06: the existing 120-call cap still bounds the workload and the result
            # must report it, not a 0 ceiling, while never exceeding it.
            want(type(steps.get("ceiling")) is int
                 and int(steps.get("ceiling", -1)) == 120
                 and int(steps.get("attempted", 99999)) <= 120,
                 f"{name}: dev_smoke step cap not respected: {steps!r}")
    if len(markers) == 1:
        try:
            with open(markers[0], encoding="utf-8") as handle:
                marker = json.loads(handle.read())
        except Exception as exc:
            problems.append(f"{name}: completion marker is not decodable JSON: {exc}")
            return problems
        want(isinstance(marker, dict) and marker.get("complete") is True
             and marker.get("profile") == suite and marker.get("seed") == 3101,
             f"{name}: completion marker incomplete: {marker!r}")
        if len(results_found) == 1:
            # RUN01 F02: exactly one linked pair, checked by filename as well as by the
            # marker's own "result" field, so a stray or wrongly linked marker fails.
            want(os.path.basename(markers[0])
                 == os.path.basename(results_found[0]) + ".complete.json",
                 f"{name}: completion marker is not the result's linked file: "
                 f"{os.path.basename(markers[0])!r} vs {os.path.basename(results_found[0])!r}")
            if isinstance(marker, dict):
                want(marker.get("result") == os.path.basename(results_found[0]),
                     f"{name}: completion marker names a different result file")
    return problems


def _engine_play_predicates(c, r, name):
    """Named acceptance for the two RUN01 engine routes, from existing containment facts.

    Deliberately unlike `_godot_parse_predicates`: STAGE output is NOT rejected (the check
    runner prints `STAGE ...` by design), and there is no literal output/sample-count
    requirement. Instead exactly one `SUITE <profile>` line and the profile's completion
    markers are required, errors are inspected even on exit 0, and the runner's own result
    file is evaluated before the case verdict.
    """
    problems: list = []
    def want(ok, message: str) -> None:
        if not ok:
            problems.append(message)
    def integer(v):
        return type(v) is int and v > 0
    suite = GODOT_ENGINE_SUITE[name]
    spawn, e = c["spawn"], c["escalation"]
    want(c.get("inner_exit") == e.get("inner_exit") == 0 and isinstance(r, dict),
         "engine actual normal-supervisor exit0/record missing")
    if not isinstance(r, dict):
        return problems
    try:
        problems.extend(check_diagnose(name, r, r.get("elapsed_seconds", 0)))
        cmd = spawn.get("cmd", [])
        path = cmd[cmd.index("--record") + 1] if "--record" in cmd else None
        argv = list(r.get("argv") or [])
        out_flags = [a for a in argv if isinstance(a, str) and a.startswith("--out=")]
        want(len(out_flags) == 1, "engine exactly one --out flag missing")
        out_dir = out_flags[0][len("--out="):] if out_flags else None
        expected_cmd = [sys.executable, "-B", os.path.abspath(__file__),
                        *ENGINE_INNER_LIMITS, "--record", path, "--", *argv]
        want(cmd == expected_cmd and isinstance(path, str)
             and os.path.basename(path) == name + ".inner.json",
             "engine fixed normal/engine argv mismatch")
        want(argv == engine_child_argv(suite, out_dir) if out_dir else False,
             "engine child argv is not the registered fixed route")
        want(spawn.get("case") == name and integer(spawn.get("started_ns"))
             and spawn.get("deadline_ns") == spawn["started_ns"] + 8_000_000_000
             and r.get("supervisor_sha256") == spawn.get("source_sha256"),
             "engine source/case/original8s outer clock missing")
        limits, raw, gate = r.get("limits", {}), r.get("timings_ns", {}), r.get("gate") or {}
        want(all(limits.get(k) == v for k, v in
                 (("wall_seconds", 5), ("cpu_seconds", 4), ("rss_mib", 512),
                  ("output_bytes", 262144), ("poll_ms", 100)))
             and r.get("keep_output") is True and integer(r.get("run_ns"))
             and r.get("wall_deadline_ns") == r["run_ns"] + 5_000_000_000,
             "engine applied limits/capture/original R+5s clock mismatch")
        m, h, w = gate.get("m_ns"), gate.get("h_ns"), gate.get("w_ns")
        want(all(integer(v) for v in (m, h, w)) and m == raw.get("m_ns")
             and w == r.get("wall_deadline_ns")
             and h == min(m + 100_000_000, w, m + 230_000_000)
             and gate.get("f_ns") == m + 250_000_000
             and gate.get("decision_ns") == m + 230_000_000,
             "engine original M/H/W/F equations missing/changed")
        child, group = r.get("child", {}), r.get("group", {})
        reap = group.get("reap") or {}
        want(r.get("exit_code") == 0 and r.get("reason") == r.get("monitor_stop_reason") == "ok"
             and child.get("exit_code") == 0 and child.get("signal") is None
             and reap.get("exited") is True and reap.get("exit_code") == 0
             and reap.get("signaled") is False and reap.get("signal") is None
             and reap.get("observed_by") == "monitor",
             "engine actual natural Godot/helper wait0 missing")
        want(not r.get("monitoring_failure") and not r.get("launch_error")
             and r.get("fixture_ready") is None and r.get("drain_incomplete") is False
             and group.get("survivors_verified") == [] and not group.get("sample_errors"),
             "engine unknown monitoring/readiness/capture/verification")
        out = r.get("output", {})
        text, total, captured = out.get("head"), out.get("total_bytes"), out.get("captured_bytes")
        want(type(total) is int and type(captured) is int and 0 <= total == captured <= 262144
             and out.get("truncated") is False and isinstance(text, str)
             and "�" not in text, "engine complete output missing/truncated/undecodable")
        stdout_tail = c.get("stdout_tail", "") or ""
        stderr_tail = c.get("stderr_tail", "") or ""
        if isinstance(text, str):
            want(len(text.encode("utf-8")) == captured
                 and stdout_tail == text.encode("utf-8")[-2000:].decode("utf-8", "replace"),
                 "engine enclosing output capture mismatch")
            suite_lines = [ln for ln in text.splitlines() if ln.startswith("SUITE ")]
            want(suite_lines == ["SUITE " + suite],
                 f"engine expected exactly one 'SUITE {suite}' line, got {suite_lines!r}")
            want(sum(1 for ln in text.splitlines() if ln.startswith("=== M01 checks: ")) == 1,
                 "engine completion summary line missing/duplicated")
            want(sum(1 for ln in text.splitlines() if ln.startswith("wrote ")) == 1,
                 "engine result-write line missing/duplicated")
            # RUN01 F03: the runner stringifies Booleans as lowercase true/false, so the
            # case-sensitive uppercase prefix never matched a healthy sink. Require exactly
            # one checked-sink line in total and make it carry the full success form,
            # including RUN01 F04's post-I/O deadline_ok completion proof. Exit 0 alone,
            # a false field, a missing or a duplicated line all still fail here.
            sink_lines = [ln for ln in text.splitlines()
                          if ln.startswith("checked sink: ")]
            want(len(sink_lines) == 1,
                 "engine checked-sink line missing/duplicated: " + repr(sink_lines[:2]))
            if len(sink_lines) == 1:
                want(sink_lines[0].startswith(
                        "checked sink: readback=true completion_marker=true "
                        "deadline_ok=true path="),
                     "engine checked-sink success line false/malformed: "
                     + sink_lines[0][:200])
            for line in text.splitlines():
                upper = line.strip().upper()
                want(not any(marker in upper for marker in ENGINE_ERROR_MARKERS),
                     "engine stdout error output: " + line[:200])
        for line in stderr_tail.splitlines():
            upper = line.strip().upper()
            want(not any(marker in upper for marker in ENGINE_ERROR_MARKERS),
                 "engine stderr error output: " + line[:200])
        sink_lines = [line[len("evidence sink: "):] for line in stderr_tail.splitlines()
                      if line.startswith("evidence sink: ")]
        want(len(sink_lines) == 1, "engine enclosing inner-sink completion missing")
        if len(sink_lines) == 1 and isinstance(path, str):
            sink = json.loads(sink_lines[0])
            want(sink.get("path") == path and sink.get("primary_ok") is True
                 and sink.get("writer_pending") is False and sink.get("late") is False
                 and sink.get("primary_error") is None and integer(sink.get("started_ns"))
                 and integer(sink.get("completed_ns")) and integer(r.get("evidence_deadline_ns"))
                 and sink["started_ns"] <= sink["completed_ns"] <= r["evidence_deadline_ns"],
                 "engine inner primary write incomplete/late")
        sampling = r.get("sampling", {})
        want(isinstance(sampling.get("observations"), list)
             and sampling.get("unfinished") == 0
             and sampling.get("breaches") == [] and sampling.get("freshness_breaches") == [],
             "engine sampling/freshness stop cannot pass")
        problems.extend(_runner_result_predicates(name, suite, out_dir))
    except Exception as exc:
        problems.append(f"engine result schema/predicate failed: {exc}")
    return problems


def _preview_predicates(c, r, name):
    """Named acceptance for the single native-preview route (PREVIEW01).

    Unlike the headless check routes it requires NO runner result or completion marker: a
    scene ready observation is not a runner pass. It requires positive promotion with a
    recorded ACK/release, complete owned/pending verification, the fixed argv/limits, a
    complete bounded capture, and a VALID inner result: successful launch/reap/cleanup, no
    sampling/cutoff/post-stage/reporting fault and consistent reason/exit/stop facts.
    Natural ``ok`` requires a real child exit0 with no signal; an accepted operating stop
    (wall/cpu/rss/cancelled) keeps its distinct label and must still pass capture,
    accounting and cleanup. Fatal output and every other reason are reportable failures.
    An accepted label alone never passes a workload.
    """
    problems: list = []

    def want(ok, message: str) -> None:
        if not ok:
            problems.append(message)

    promotion = c.get("promotion") or {}
    escalation = c.get("escalation") or {}
    rec = r if isinstance(r, dict) else {}
    child = rec.get("child") or {}
    group = rec.get("group") or {}
    cleanup = rec.get("cleanup") or {}
    out = rec.get("output") or {}
    agg = rec.get("preview_aggregate")

    # Admission / authority / verification use the existing authoritative facts.
    want(promotion.get("attempted") is True and promotion.get("owned") is not None
         and promotion.get("ack_error") is None and promotion.get("rejected") is None,
         "preview positive admission/promotion/ACK missing")
    want(c.get("pending_identity_status") == "identified"
         and escalation.get("verification_complete") is True
         and not escalation.get("verification_error")
         and escalation.get("survivors_after_kill") == []
         and escalation.get("zombies") == [],
         "preview complete owned/pending verification missing")
    # Fixed route and supervisor limits.
    want(list(rec.get("argv") or []) == list(GODOT_PREVIEW_ARGV),
         "preview child argv is not the fixed native route (binary,--path,project)")
    limits = rec.get("limits") or {}
    want(rec.get("supervisor_sha256") == (c.get("spawn") or {}).get("source_sha256"),
         "preview supervisor source identity mismatch")
    want(rec.get("clock") == "monotonic_ns", "preview clock is not monotonic_ns")
    want(limits.get("wall_seconds") == 60.0 and limits.get("cpu_seconds") == 4.0
         and limits.get("poll_ms") == 100 and limits.get("rss_mib") == 512
         and limits.get("output_bytes") == 262144,
         f"preview fixed supervisor limits missing: {limits!r}")
    want(limits.get("handoff_ms") == PREVIEW_HANDOFF_MS
         and limits.get("freshness_bound_ms") == PREVIEW_FRESHNESS_BOUND_MS
         and limits.get("freshness_decision_lead_ms") == FRESHNESS_DECISION_LEAD_MS
         and limits.get("bootstrap_lease_ms") == BOOTSTRAP_LEASE_MS,
         "preview timing policy labels disagree with fixed authority")
    # The 60s inner wall deadline must be the one established from run_ns before the
    # probe/Popen, not a later renewal. This is a REAL prerequisite: the dependent wall
    # arithmetic below is guarded on the same integer facts and is never repaired with a
    # zero default.
    run_ns = rec.get("run_ns")
    wall_deadline_ns = rec.get("wall_deadline_ns")
    fixed_wall_ok = (type(run_ns) is int and type(wall_deadline_ns) is int
                     and wall_deadline_ns == run_ns + 60_000_000_000)
    want(fixed_wall_ok, "preview fixed 60s inner wall deadline missing/changed")
    spawn = c.get("spawn") if isinstance(c.get("spawn"), dict) else {}
    outer_started_ns = spawn.get("started_ns")
    outer_deadline_ns = spawn.get("deadline_ns")
    want(c.get("bound_seconds") == OUTER_PREVIEW_RUNTIME_S
         and spawn.get("outer_bound_seconds") == OUTER_PREVIEW_RUNTIME_S
         and type(outer_started_ns) is int and type(outer_deadline_ns) is int
         and outer_started_ns > 0
         and outer_deadline_ns == outer_started_ns + int(OUTER_PREVIEW_RUNTIME_S * 1_000_000_000),
         "preview fixed 63s outer deadline missing/changed")
    # FIX05 steps 3-5: partition attempts into a nonempty accepted prefix (length N) plus at
    # most ONE final unaccepted wall/cancel terminal attempt T. Counters, accepted grid
    # clocks, the fresh tail and the terminal-form facts are validated from EXISTING recorded
    # evidence; the fixed PREVIEW_FRESHNESS_BOUND_MS / FRESHNESS_DECISION_LEAD_MS authorities are
    # referenced, never widened by recorded metadata.
    def _pid_map(raw):
        """One lossless PID-key normalization; reject malformed keys / duplicate identities."""
        if not isinstance(raw, dict):
            return None
        out = {}
        for key, val in raw.items():
            try:
                pid = int(key)
            except (TypeError, ValueError):
                return None
            if pid < 0 or pid in out or type(val) is not int or val < 0:
                return None
            out[pid] = val
        return out

    def _event_winner(sel, b, v_last, w_ref, recv):
        """Reproduce the existing due-event selection from retained facts.

        Candidates at the actual detection timestamp B are cancel (C,rank0), deadline
        (W,rank1) and freshness (v_last+H-Dlead,rank2); the lexicographic minimum by
        (schedule,rank) must match the recorded selection, and any recorded tied_kinds must
        describe exactly the candidates at that winning schedule.
        """
        if not (type(b) is int and type(v_last) is int and type(w_ref) is int):
            return False
        cands = []
        if type(recv) is int and recv <= b:
            cands.append((recv, 0, "cancel"))
        if w_ref <= b:
            cands.append((w_ref, 1, "deadline"))
        fresh = v_last + h_ns - dlead
        if fresh <= b:
            cands.append((fresh, 2, "freshness"))
        if not cands:
            return False
        best = min(cands)
        if sel.get("scheduled_ns") != best[0] or sel.get("kind") != best[2]:
            return False
        tied = sel.get("tied_kinds")
        if isinstance(tied, list):
            exp = [k for (s, _, k) in cands if s == best[0]]
            if sorted(tied) != sorted(exp):
                return False
        return True

    p_ns = 100_000_000
    h_ns = PREVIEW_FRESHNESS_BOUND_MS * 1_000_000
    dlead = FRESHNESS_DECISION_LEAD_MS * 1_000_000
    # Bounded structural prerequisites: fail closed BEFORE dependent evaluation. A missing
    # or malformed required fact returns failure, never a successful empty/zero substitute;
    # non-dictionary observation entries are never filtered into a qualifying sequence and
    # the raw producer evidence is left unchanged.
    if not isinstance(rec.get("sampling"), dict):
        problems.append("preview inner result/sampling unavailable")
        return problems
    sampling = rec["sampling"]
    timings = rec.get("timings_ns") if isinstance(rec.get("timings_ns"), dict) else {}
    gate = rec.get("gate") if isinstance(rec.get("gate"), dict) else {}
    clock_keys = ("m_ns", "h_ns", "w_ns", "f_ns", "decision_ns")
    gate_clocks_ok = all(type(gate.get(k)) is int and gate[k] > 0 for k in clock_keys)
    if gate_clocks_ok:
        m, h, w, f, d = (gate[k] for k in clock_keys)
        gate_clocks_ok = (fixed_wall_ok and w == wall_deadline_ns
                          and f == m + h_ns and d == f - dlead
                          and h == min(m + PREVIEW_HANDOFF_MS * 1_000_000, w, d)
                          and m < h <= min(w, d, f)
                          and gate.get("h_offset_ms") == (h - m) / 1_000_000)
    want(gate_clocks_ok, "preview gate clock equations disagree with fixed authority")
    frames = c.get("registration_frames")
    receipts = ([v for v in frames if isinstance(v, dict) and v.get("kind") == "receipt"]
                if isinstance(frames, list) else [])
    ack = gate.get("ack")
    outer_gate = c.get("inner_gate")
    want(gate_clocks_ok and len(receipts) == 1 and isinstance(ack, dict)
         and isinstance(outer_gate, dict)
         and all(receipts[0].get(k) == ack.get(k) == outer_gate.get(k) == gate[k]
                 for k in clock_keys),
         "preview receipt/ACK/release clocks disagree")
    observations = sampling.get("observations")
    if not isinstance(observations, list):
        problems.append("preview sampling observations unavailable (not a list)")
        return problems
    if any(not isinstance(v, dict) for v in observations):
        problems.append("preview sampling observation entry malformed (not a mapping)")
        return problems
    count, attempts, unfinished = (sampling.get(k) for k in
                                   ("count", "attempts", "unfinished"))
    m_ns = sampling.get("m_ns")
    gate_m = gate.get("m_ns")
    timing_m = timings.get("m_ns")
    w_ns = rec.get("wall_deadline_ns")
    accepted = [v for v in observations if type(v.get("accepted_ns")) is int]
    if (type(count) is not int or count <= 0 or type(m_ns) is not int
            or type(w_ns) is not int or not accepted):
        problems.append("preview sampling has no usable accepted prefix")
        return problems
    q = len(observations) - len(accepted)
    want(count == rec.get("samples") == len(accepted),
         "preview accepted sample count mismatch")
    # The monitor origin M must equal the existing timing and gate handoff origins before
    # any grid/relative equation uses it.
    want(type(timing_m) is int and type(gate_m) is int and m_ns == timing_m == gate_m,
         "preview sampling origin M disagrees with the timing/gate handoff origin")
    # aggregate.samples = N is required on EVERY qualifying preview route, not RSS only.
    want(isinstance(agg, dict) and agg.get("samples") == count,
         "preview aggregate accepted-observation count mismatch")
    want(type(attempts) is int and attempts == len(observations),
         "preview sample attempt count mismatch")
    want(observations[:len(accepted)] == accepted and q in (0, 1),
         "preview accepted prefix / terminal attempt shape invalid")
    timed_out_n = sum(1 for v in observations if v.get("timed_out") is True)
    ages_ms, reasons = sampling.get("unfinished_ages_ms"), sampling.get("unfinished_reasons")
    want(type(unfinished) is int and unfinished == timed_out_n
         and isinstance(ages_ms, list) and isinstance(reasons, list)
         and len(ages_ms) == unfinished and len(reasons) == unfinished
         and all(v.get("timed_out") is False for v in accepted),
         "preview unfinished/attempt counters inconsistent")
    want(sampling.get("applied_period_ns") == p_ns,
         "preview sampling cadence label missing")
    want(type(sampling.get("freshness_bound_ms")) is int
         and sampling["freshness_bound_ms"] == PREVIEW_FRESHNESS_BOUND_MS,
         "preview recorded freshness bound disagrees with the fixed authority")
    want(sampling.get("breaches") == [] and sampling.get("freshness_breaches") == [],
         f"preview freshness breach recorded: {sampling.get('freshness_breaches')!r}")
    want(sampling.get("v_ns") == (accepted[-1].get("accepted_ns") if accepted else None),
         "preview last accepted origin V mismatched")
    # Step 4: every accepted observation's ordered grid/origin/cutoff clocks.
    receipt_c = timings.get("cancel_received_ns")
    previous, prev_due, accepted_ok = m_ns, None, bool(accepted)
    if type(m_ns) is int and type(w_ns) is int:
        for obs in accepted:
            due, start = obs.get("scheduled_due_ns"), obs.get("start_ns")
            comp, observed, acc = (obs.get("completed_ns"), obs.get("observed_ns"),
                                   obs.get("accepted_ns"))
            cutoff = obs.get("cutoff_ns")
            rows = _pid_map(obs.get("rows"))
            ok = (obs.get("timed_out") is False and obs.get("abort") is None
                  and obs.get("err") is None and rows is not None
                  and all(type(v) is int for v in (due, start, comp, observed, acc, cutoff)))
            if ok:
                ceiling = min(w_ns, previous + h_ns - dlead)
                ok = ((due - m_ns) % p_ns == 0 and previous <= due <= start
                      and start <= comp <= observed <= acc
                      and (prev_due is None or due > prev_due)
                      and acc < cutoff <= ceiling
                      and (type(receipt_c) is not int or acc <= receipt_c)
                      and type(obs.get("elapsed_s")) in (int, float)
                      and obs.get("elapsed_s") == (observed - start) / 1e9)
            accepted_ok = accepted_ok and ok
            if type(due) is int:
                prev_due = due
            if type(acc) is int:
                previous = acc
    want(accepted_ok, "preview stale/nonanchored/inconsistent accepted observation")
    # Derived ms metrics must equal the producer's arithmetic from the same integer facts.
    # A failed accepted prefix must not proceed as a healthy sequence.
    if accepted_ok and accepted and all(type(o.get(k)) is int for o in accepted
                                        for k in ("accepted_ns", "start_ns")):
        v_first, v_last = accepted[0]["accepted_ns"], accepted[-1]["accepted_ns"]
        gaps = [v_first - m_ns] + [accepted[i]["accepted_ns"] - accepted[i - 1]["accepted_ns"]
                                   for i in range(1, len(accepted))]
        want(sampling.get("first_sample_ms") == (v_first - m_ns) / 1e6
             and sampling.get("last_sample_ms") == (v_last - m_ns) / 1e6
             and sampling.get("last_age_ms") == (v_last - accepted[-1]["start_ns"]) / 1e6
             and sampling.get("max_age_ms") == max(
                 (o["accepted_ns"] - o["start_ns"]) / 1e6 for o in accepted)
             and sampling.get("max_gap_ms") == max(gaps) / 1e6,
             "preview derived sample age/gap metrics mismatched")
    # Step 4 tail: last accepted origin V and the exact tail equation/bound.
    origin, end, age = (sampling.get(k) for k in
                        ("tail_origin_ns", "monitor_end_ns", "tail_age_ns"))
    s_ns = timings.get("s_ns")
    want(type(origin) is int and type(end) is int and type(age) is int
         and origin == previous and end >= origin and age == end - origin
         and 0 <= age <= h_ns and type(s_ns) is int and origin <= s_ns <= end
         and sampling.get("tail_age_ms") == age / 1e6,
         "preview stale/inconsistent tail observation")
    # Step 5: at most one final unaccepted terminal attempt T for a supported wall/cancel
    # operating stop. T never advances count/V/usable peak and supplies no RSS proof.
    _sel = sampling.get("selected_event")
    selected_event = _sel if isinstance(_sel, dict) else {}
    terminal_form = None
    if q == 1:
        terminal = observations[-1]
        sel_kind = selected_event.get("kind")
        sel_sched, sel_det = (selected_event.get("scheduled_ns"),
                              selected_event.get("detected_ns"))
        t_due, t_start, t_obs = (terminal.get("scheduled_due_ns"), terminal.get("start_ns"),
                                 terminal.get("observed_ns"))
        t_cut, t_err = terminal.get("cutoff_ns"), terminal.get("err")
        t_rows = _pid_map(terminal.get("rows"))
        common = (all(type(v) is int for v in (t_due, t_start, t_obs, t_cut,
                                               sel_sched, sel_det, s_ns, end, m_ns, w_ns))
                  and sel_kind in ("deadline", "cancel")
                  and (t_due - m_ns) % p_ns == 0
                  and (prev_due is None or t_due > prev_due)
                  and previous <= t_due <= t_start <= t_obs
                  and t_obs <= sel_det <= s_ns <= end
                  and t_cut <= min(w_ns, previous + h_ns - dlead))
        want(common, "preview terminal attempt clock/grid/event binding invalid")
        # Invalid common raw clock/event prerequisites must not reach the branch comparisons
        # (no comparison against a missing scheduled/observed clock). The supported
        # interrupted form still permits completed_ns=None.
        if common:
            t_elapsed = (t_obs - t_start) / 1e9
            t_elapsed_ok = (type(terminal.get("elapsed_s")) in (int, float)
                            and terminal.get("elapsed_s") == t_elapsed)
            if terminal.get("timed_out") is True:
                t_comp = terminal.get("completed_ns")
                want(t_err in (None, "sample unfinished", "sample budget exhausted before call")
                     and t_rows is None
                     and terminal.get("abort") in ("deadline", "cancel")
                     and (terminal.get("abort") == "cancel") == (sel_kind == "cancel")
                     and sel_sched <= t_obs
                     and (t_comp is None or (type(t_comp) is int and t_start <= t_comp <= sel_det))
                     and t_elapsed_ok
                     and sampling.get("unfinished") == 1
                     and sampling.get("unfinished_reasons") == [terminal.get("abort")]
                     and sampling.get("unfinished_ages_ms") == [t_elapsed * 1000],
                     "preview interrupted terminal attempt facts inconsistent")
                terminal_form = "interrupted"
            else:
                t_comp = terminal.get("completed_ns")
                wall_ok = (sel_kind == "deadline" and t_obs < w_ns and sel_sched == w_ns
                           and w_ns <= sel_det)
                cancel_ok = sel_kind == "cancel" and t_obs <= sel_sched <= sel_det
                want(terminal.get("timed_out") is False and terminal.get("abort") is None
                     and t_err is None and t_rows is not None and type(t_comp) is int
                     and t_start <= t_comp <= t_obs < t_cut and (wall_ok or cancel_ok)
                     and t_elapsed_ok
                     and sampling.get("unfinished") == 0
                     and sampling.get("unfinished_ages_ms") == []
                     and sampling.get("unfinished_reasons") == [],
                     "preview completed-but-unaccepted terminal attempt inconsistent")
                terminal_form = "completed"
    # Inner validity: real launch/reap/cleanup, no faults, complete undecodable-free capture.
    want(child.get("launched") is True, "preview engine never launched")
    want(rec.get("monitoring_failure") is None, "preview inner monitoring failure")
    want(not group.get("sample_errors"),
         f"preview inner sample errors: {group.get('sample_errors')!r}")
    want(not rec.get("cutoff_misses"), f"preview inner cutoff misses: {rec.get('cutoff_misses')!r}")
    want(not rec.get("post_faults"), f"preview inner post-stage faults: {rec.get('post_faults')!r}")
    want(not rec.get("stage_overruns"), f"preview inner stage overruns: {rec.get('stage_overruns')!r}")
    want(not rec.get("reporting_errors"), f"preview reporting errors: {rec.get('reporting_errors')!r}")
    # F3: every reporting failure rejects acceptance, including one recorded after an
    # operating stop. The serialized flag and the outer-observed divergence both fail.
    want(rec.get("reporting_failure") in (False, None),
         f"preview reporting failure flag: {rec.get('reporting_failure')!r}")
    want(c.get("inner_reporting_failure") is False,
         "preview outer-observed inner reporting failure")
    want(rec.get("drain_incomplete") is False, "preview engine output drain incomplete")
    want(cleanup.get("ok") is True, f"preview inner cleanup failed: {cleanup.get('note')!r}")
    want(group.get("reap_failed") in (False, None), "preview inner reap failed")
    total, captured = out.get("total_bytes"), out.get("captured_bytes")
    want(type(total) is int and type(captured) is int and 0 <= total == captured,
         f"preview capture incomplete/short: total={total!r} captured={captured!r}")
    want(out.get("truncated") is False, "preview capture truncated")
    want(rec.get("keep_output") is True, "preview capture is not in complete-output mode")
    cap = limits.get("output_bytes")
    want(type(cap) is int and cap > 0 and captured <= cap,
         f"preview capture exceeds the output cap: captured={captured!r} cap={cap!r}")
    text = out.get("head")
    want(isinstance(text, str) and "\ufffd" not in text, "preview output undecodable")
    if isinstance(text, str):
        want(len(text.encode("utf-8")) == captured,
             "preview captured text length does not equal the captured byte count")
    # Reason / exit / raw-cause consistency. An accepted label is necessary, never enough.
    reason = rec.get("reason")
    stop_kinds = ("wall", "cpu", "rss", "cancelled")
    want(reason == "ok" or reason in stop_kinds,
         f"preview ended without a natural exit or an accepted operating stop: {reason!r}")
    want(rec.get("monitor_stop_reason") == reason,
         f"preview reason/monitor_stop_reason disagree: {reason!r}/{rec.get('monitor_stop_reason')!r}")
    want(rec.get("exit_code") == REASON_EXIT.get(reason),
         f"preview reason/exit mismatch: {reason!r} exit={rec.get('exit_code')!r}")
    if reason == "ok":
        want(rec.get("exit_code") == 0 and child.get("exit_code") == 0
             and child.get("signal") is None,
             ("preview natural exit is not a real child exit0: "
              f"exit={rec.get('exit_code')!r} child={child.get('exit_code')!r} "
              f"signal={child.get('signal')!r}"))
    elif reason == "wall":
        # Bind the selected deadline event to the original wall deadline and the actual
        # detection/first-stop clocks, and reject any concealed earlier competing event.
        want(fixed_wall_ok
             and selected_event.get("kind") == "deadline"
             and selected_event.get("scheduled_ns") == w_ns
             and type(selected_event.get("detected_ns")) is int
             and type(s_ns) is int and type(end) is int and type(origin) is int
             and selected_event["scheduled_ns"] <= selected_event["detected_ns"]
             <= s_ns <= end
             and timings.get("primary_event_ns") == selected_event["scheduled_ns"]
             and _event_winner(selected_event, selected_event.get("detected_ns"),
                               origin, w_ns, receipt_c),
             "preview wall stop lacks a real deadline/precedence binding")
    elif reason == "cpu":
        # Only a real CPU signal supports a CPU stop; an arbitrary SIGKILL/SIGTERM does not.
        want(child.get("signal") == signal.SIGXCPU,
             f"preview cpu stop lacks a real SIGXCPU wait: signal={child.get('signal')!r}")
    elif reason == "cancelled":
        # The RETAINED timings_ns.cancel_latency_ns must be the exact S-C integer within the
        # existing inclusive bound, and the recorded ms must derive from that same value; a
        # fresh local subtraction is not a substitute for the retained evidence.
        retained_ns = timings.get("cancel_latency_ns")
        want(selected_event.get("kind") == "cancel"
             and type(selected_event.get("scheduled_ns")) is int
             and type(receipt_c) is int and selected_event["scheduled_ns"] == receipt_c
             and type(selected_event.get("detected_ns")) is int
             and selected_event["detected_ns"] >= receipt_c
             and type(s_ns) is int and type(end) is int and type(origin) is int
             and receipt_c <= selected_event["detected_ns"] <= s_ns <= end
             and timings.get("primary_event_ns") == selected_event["scheduled_ns"]
             and type(retained_ns) is int and retained_ns == s_ns - receipt_c
             and 0 <= retained_ns <= FRESHNESS_BOUND_MS * 1_000_000
             and rec.get("cancel_latency_ms") == retained_ns / 1e6
             and _event_winner(selected_event, selected_event.get("detected_ns"),
                               origin, w_ns, receipt_c),
             "preview cancelled stop lacks a consistent retained cancel receipt")
    elif reason == "rss":
        # Step 7: reconcile every claimed cause with the LAST accepted observation's engine
        # rows and the current deduplicated accountable member union; validate each claimed
        # cause independently, then require at least one actual crossing.
        o_last = accepted[-1] if accepted else {}
        r_rows = _pid_map(o_last.get("rows"))
        g_map = _pid_map(agg.get("members")) if isinstance(agg, dict) else None
        roles = (agg.get("roles")
                 if isinstance(agg, dict) and isinstance(agg.get("roles"), dict) else {})
        egroups = _pid_map(agg.get("expected_groups")) if isinstance(agg, dict) else None
        epids = (agg.get("expected_pids")
                 if isinstance(agg, dict) and isinstance(agg.get("expected_pids"), list)
                 else [])
        q_pid = agg.get("query_pid") if isinstance(agg, dict) else None
        q_rss = agg.get("query_rss_kib") if isinstance(agg, dict) else None
        spawn = c.get("spawn") or {}
        _esc = c.get("escalation")
        outer_phase = _esc.get("preview_outer_rss") if isinstance(_esc, dict) else None
        outer_phase = outer_phase if isinstance(outer_phase, dict) else {}
        inner_pid, outer_pid = roles.get("inner"), roles.get("outer")
        o_acc = o_last.get("accepted_ns")
        want(q == 0 and count >= 1 and isinstance(agg, dict)
             and r_rows is not None and g_map is not None
             and agg.get("samples") == count
             and type(o_acc) is int and type(m_ns) is int
             and agg.get("sample_ms") == (o_acc - m_ns) / 1e6,
             "preview rss stop lacks a linkage to the last accepted observation")
        if r_rows is not None and g_map is not None:
            union = set(r_rows) | set(epids)
            if type(q_pid) is int and q_rss is not None:
                union.add(q_pid)
            members_ok = (set(g_map) == union
                          and all(g_map.get(p) == r for p, r in r_rows.items())
                          and all(type(g_map.get(p)) is int and g_map[p] >= 0 for p in epids)
                          and (q_rss is None
                               or (type(q_pid) is int and g_map.get(q_pid) == q_rss)))
            ids_ok = (egroups is not None
                      and type(inner_pid) is int and type(outer_pid) is int
                      and inner_pid != outer_pid
                      and sorted(epids) == sorted({inner_pid, outer_pid})
                      and spawn.get("pid") == inner_pid
                      and egroups.get(inner_pid) == spawn.get("pgid")
                      and outer_phase.get("outer_pid") == outer_pid
                      and egroups.get(outer_pid) == outer_phase.get("outer_pgid")
                      and agg.get("missing") == [] and not agg.get("mismatched"))
            want(members_ok and ids_ok,
                 "preview rss member union / provenance inconsistent with the accepted sample")
            engine_bytes = 1024 * sum(r_rows.values())
            aggregate_bytes = 1024 * sum(g_map.values())
            want(agg.get("observed_bytes") == aggregate_bytes
                 and agg.get("crossing_observed_bytes") == aggregate_bytes
                 and agg.get("engine_group_bytes") == engine_bytes
                 and agg.get("engine_group_total_kib") == sum(r_rows.values())
                 and agg.get("engine_group_threshold_bytes") == PREVIEW_ENGINE_RSS_BYTES
                 and agg.get("aggregate_crossed")
                     == (aggregate_bytes >= PREVIEW_AGG_RSS_BYTES)
                 and agg.get("engine_group_crossed")
                     == (engine_bytes > PREVIEW_ENGINE_RSS_BYTES),
                 "preview rss numeric totals/flags contradict the accepted rows")
            agg_flag = agg.get("aggregate_crossed") is True
            eng_flag = agg.get("engine_group_crossed") is True
            # Each TRUE claimed cause must independently satisfy its own crossing copy and
            # stop latch; an OR may never let one valid cause mask the other's contradiction.
            agg_proof = (agg.get("stopped") is True
                         and _pid_map(agg.get("crossing_members")) == g_map)
            eng_proof = (agg.get("engine_group_rss_stop") is True
                         and _pid_map(agg.get("crossing_engine_rows")) == r_rows)
            want((not agg_flag or agg_proof)
                 and (not eng_flag or eng_proof)
                 and (agg_flag or eng_flag)
                 and agg.get("stop_source") == ("aggregate_750mib" if agg_flag
                     else "engine_group_512mib"),
                 "preview rss stop lacks an independently reconciled crossed source")
    if reason not in ("wall", "cancelled"):
        want(q == 0, f"preview {reason} result must not carry a terminal wall/cancel attempt")
    if reason != "rss" and isinstance(agg, dict):
        want(agg.get("aggregate_crossed") is not True
             and agg.get("engine_group_crossed") is not True,
             "preview non-rss result retained a crossed runtime map")
    # The OUTER-observed inner exit must agree with the label (serialized inner fields alone
    # are insufficient: writing/reporting can finish after serialization).
    want(c.get("inner_exit") == REASON_EXIT.get(reason),
         f"preview outer-observed inner exit {c.get('inner_exit')!r} != label {reason!r}")
    # The bounded completion sink is the OUTER-captured `evidence sink:` diagnostic.
    spawn_cmd = (c.get("spawn") or {}).get("cmd") or []
    expected_inner = None
    if "--record" in spawn_cmd:
        index = spawn_cmd.index("--record")
        if index + 1 < len(spawn_cmd):
            expected_inner = spawn_cmd[index + 1]
    sink_lines = [line[len("evidence sink: "):] for line in (c.get("stderr_tail") or "").splitlines()
                  if line.startswith("evidence sink: ")]
    want(len(sink_lines) == 1, "preview outer-captured evidence sink missing/duplicated")
    if len(sink_lines) == 1:
        try:
            sink = json.loads(sink_lines[0])
        except Exception:
            sink = None
        want(isinstance(sink, dict), "preview outer-captured evidence sink is not JSON")
        if isinstance(sink, dict):
            deadline = r.get("evidence_deadline_ns") if isinstance(r, dict) else None
            want(sink.get("path") == expected_inner
                 and sink.get("primary_ok") is True and sink.get("writer_pending") is False
                 and sink.get("late") is False and sink.get("primary_error") is None
                 and type(sink.get("started_ns")) is int and type(sink.get("completed_ns")) is int
                 and type(deadline) is int
                 and sink["started_ns"] <= sink["completed_ns"] <= deadline,
                 "preview inner sink completion missing/untimely/at a different path")
    # The option-D outer verification RSS phase must be present, valid and internally
    # consistent (usability/resource flags and ordered stored clocks) on the OUTER receipt.
    _esc = c.get("escalation")
    outer_phase = _esc.get("preview_outer_rss") if isinstance(_esc, dict) else None
    want(isinstance(outer_phase, dict) and outer_phase.get("valid") is True
         and outer_phase.get("measurement_usable") is True
         and outer_phase.get("complete") is True
         and all(type(outer_phase.get(k)) is int for k in
                 ("start_ns", "end_ns", "accepted_ns", "cutoff_ns"))
         and outer_phase["start_ns"] <= outer_phase["end_ns"]
         <= outer_phase["accepted_ns"] <= outer_phase["cutoff_ns"],
         "preview outer verification RSS phase missing/invalid/contradictory")
    # The final all-phase maximum is computed at the OUTER level (inner phases + the outer
    # observation, by maximum, never summed). A non-rss stop must stay below the threshold;
    # an accepted rss stop is validated by its recorded numeric crossing elsewhere.
    peak = c.get("preview_all_phase_peak_bytes")
    want(type(peak) is int, f"preview all-phase peak missing: {peak!r}")
    if reason != "rss":
        want(type(peak) is int and peak < PREVIEW_AGG_RSS_BYTES,
             f"preview all-phase peak at/above threshold without an rss stop: {peak!r}")
    # F4: the fatal fact is the bounded drain-completed latch persisted in the inner
    # result, not a re-scan of the merged (possibly truncated) output text. It must be
    # explicitly false; missing or true fails.
    want(rec.get("preview_fatal_final") is False,
         f"preview fatal output latch missing or set: {rec.get('preview_fatal_final')!r}")
    # Aggregate accounting qualifications and evidence-backed stop source.
    if isinstance(agg, dict):
        want(agg.get("metric") == "observed_aggregate_rss_kib_x1024",
             "preview aggregate metric label missing")
        want(type(agg.get("samples")) is int and agg.get("samples") > 0,
             "preview aggregate accounting had no usable observation")
        want(agg.get("missing") == [],
             f"preview aggregate accounting missing live member(s): {agg.get('missing')!r}")
        want(not agg.get("mismatched"),
             f"preview aggregate accounting wrong-group member(s): {agg.get('mismatched')!r}")
        # A later good runtime observation must never erase an earlier phase refusal.
        want(agg.get("accounting_failure") is False,
             "preview aggregate accounting failure recorded")
        phases = agg.get("phases") if isinstance(agg.get("phases"), dict) else {}
        for phase_name in ("startup", "verification"):
            phase = phases.get(phase_name)
            want(isinstance(phase, dict) and phase.get("valid") is True
                 and phase.get("measurement_usable") is True
                 and phase.get("complete") is True
                 and (phase.get("engine_group_empty") is True
                      and "verifier_error" in phase and phase["verifier_error"] is None
                      if phase_name == "verification"
                      else phase.get("engine_present") is False)
                 and all(type(phase.get(k)) is int for k in
                         ("start_ns", "end_ns", "accepted_ns", "cutoff_ns"))
                 and phase["start_ns"] <= phase["end_ns"] <= phase["accepted_ns"]
                 <= phase["cutoff_ns"],
                 f"preview {phase_name} accounting phase missing/invalid/contradictory")
        want(type(agg.get("threshold_bytes")) is int
             and agg.get("threshold_bytes") == PREVIEW_AGG_RSS_BYTES,
             "preview aggregate threshold mismatch")
        if agg.get("stopped") or agg.get("engine_group_rss_stop"):
            want(agg.get("stop_source") in ("aggregate_750mib", "engine_group_512mib"),
                 "preview RSS stop lacks a recorded source")
        if agg.get("aggregate_crossed"):
            want(type(agg.get("observed_bytes")) is int
                 and agg.get("observed_bytes") >= PREVIEW_AGG_RSS_BYTES,
                 "preview aggregate crossing below its threshold")
    else:
        want(False, "preview aggregate accounting record missing")
    return problems


def _selected_outer_predicates(name, c, result):
    if name in ENGINE_CASES:
        return _engine_play_predicates(c, result, name)
    if name in PREVIEW_CASES:
        return _preview_predicates(c, result, name)
    if name == GODOT_PARSE_CASE:
        return _godot_parse_predicates(c, result)
    if name not in (A5_UNRELATED_CASE, A3_CRASH_CASE, "b1_normal_cli"):
        return []
    problems = []
    def want(ok, message):
        if not ok:
            problems.append(message)
    def integer(v):
        return type(v) is int and v > 0
    spawn, e, promotion = c["spawn"], c["escalation"], c["promotion"]
    s, inner = e.get("s_ns"), spawn.get("pid")
    want(integer(spawn.get("started_ns")) and spawn.get("deadline_ns") ==
         spawn.get("started_ns", 0)+8_000_000_000, "selected original8s outer clock missing/changed")
    if name == "b1_normal_cli":
        want(c.get("inner_exit") == 0 and isinstance(result, dict), "B1 actual normal CLI exit0/record missing")
        if isinstance(result, dict):
            want(result.get("supervisor_sha256") == spawn.get("source_sha256"), "B1 source identity mismatch")
            want(result.get("exit_code") == 0 and result.get("reason") == "ok", "B1 normal primary result failed")
            want(c.get("stdout_tail") == "b1 normal ready\nb1 normal complete\n", "B1 outer capture incomplete")
            cmd = spawn.get("cmd", [])
            want("--diagnose-one" not in cmd and "--wall-seconds" in cmd and "--keep-output" in cmd
                 and "--record" in cmd and "--" in cmd, "B1 did not use the normal command path")
            try:
                problems.extend(check_diagnose(name, result, result.get("elapsed_seconds", 0)))
            except Exception as exc:
                problems.append(f"B1 result schema/predicate failed: {exc}")
        return problems
    fixture = c.get("unrelated_refusal" if name == A5_UNRELATED_CASE else "expected_inner_crash") or {}
    events, frames = fixture.get("events", []), c.get("registration_frames", [])
    receipt_list = [v for v in frames if v.get("kind") == "receipt"]
    reg_list = [v for v in frames if v.get("kind") == "bootstrap"]
    want(len(frames) == 2 and len(receipt_list) == len(reg_list) == 1
         and fixture.get("registration_eof") is True, "selected complete receipt/registration missing")
    if len(receipt_list) != 1 or len(reg_list) != 1 or not integer(s):
        return problems
    receipt, registration = receipt_list[0], reg_list[0]
    b = receipt.get("child_pid")
    token = fixture.get("case_token")
    want(isinstance(token, str) and all(v.get("case") == name and v.get("token") == token
         for v in [receipt, registration, *events]), "selected case/token evidence mismatch")
    want(receipt.get("inner_pid") == inner and integer(b) and b != inner,
         "selected actual inner/bootstrap identity missing")
    clocks = [receipt.get(k) for k in ("m_ns", "h_ns", "w_ns", "f_ns", "decision_ns")]
    valid_clocks = all(integer(v) for v in clocks)
    want(valid_clocks, "selected raw handoff clocks missing")
    if not valid_clocks:
        return problems
    m, h, w, f, decision = clocks
    want(f == m+250_000_000 and decision == f-20_000_000
         and h == min(m+100_000_000, w, decision) and m < h,
         "selected original M/H/W/F equations changed")
    want(fixture.get("inner_record_absent") is True, "selected deliberate exit record absence unproved")
    if name == A3_CRASH_CASE:
        want(len(events) == 3 and sorted(v.get("kind", "") for v in events) ==
             ["a3_crash", "a3_gate", "a3_ready"], "A3 three positive crash/release/ready events missing")
        by_kind = {v.get("kind"):v for v in events}
        gate, ready, crash = by_kind.get("a3_gate", {}), by_kind.get("a3_ready", {}).get("ready", {}), by_kind.get("a3_crash", {})
        owned = promotion.get("owned") or {}
        want(owned.get("pid") == owned.get("pgid") == owned.get("sid") == b
             and all(registration.get(k) == b for k in ("pid", "pgid", "sid"))
             and gate.get("child_pid") == b and gate.get("inner_pid") == inner
             and gate.get("released") is True, "A3 actual promoted separate workload/release missing")
        want(c.get("inner_exit") == e.get("inner_exit") == A3_CRASH_EXIT_CODE
             and crash.get("exit_code") == A3_CRASH_EXIT_CODE, "A3 actual deliberate inner exit72 missing")
        order = [gate.get("release_write_started_ns"), ready.get("e_ns"), ready.get("received_ns"),
                 crash.get("exit_selected_ns"), fixture.get("capture_completed_ns"), s]
        want(all(integer(v) for v in order) and order == sorted(order)
             and order[-2] <= m+250_000_000
             and ready.get("pid") == ready.get("pgid") == ready.get("sid") == b
             and ready.get("term_ignore") is False, "A3 live readiness did not precede crash/cleanup")
        expiry = ready.get("expiry_ns")
        valid_expiry = integer(expiry) and integer(ready.get("e_ns"))
        want(valid_expiry and expiry == ready["e_ns"]+5_000_000_000, "A3 finite E+5s lifetime missing")
        terms = [v for v in e.get("signal_events", []) if v.get("pgid") == b and v.get("signal") == "SIGTERM"]
        if valid_expiry:
            want(len(terms) == 1 and terms[0].get("result") == "sent" and terms[0].get("ok") is True
                 and integer(terms[0].get("completed_ns")) and s <= terms[0]["completed_ns"] < expiry
                 and integer(e.get("verification_end_ns")) and e["verification_end_ns"] < expiry,
                 "A3 live workload was not independently contained before natural expiry")
        orphan_wait = fixture.get("workload_wait") or {}
        want(orphan_wait.get("pid") == b and orphan_wait.get("available") is False
             and orphan_wait.get("status") is None, "A3 orphan wait must remain unavailable")
        return problems

    control = c.get("direct_control") or {}
    control_pid, ready = control.get("pid"), control.get("ready") or {}
    want(integer(control_pid) and control_pid == control.get("pgid") == control.get("sid")
         and control_pid not in (inner, b, control.get("controller_pid"), control.get("controller_pgid"))
         and control.get("authority") == "direct_control_popen"
         and control.get("gate_descriptors_inherited") is False, "A5 distinct direct C ownership missing")
    want(all(registration.get(k) == control_pid for k in ("pid", "pgid", "sid"))
         and registration.get("bootstrap_pid") == b
         and set(registration) == {"kind", "case", "token", "pid", "pgid", "sid", "bootstrap_pid", "entry_ns", "lease_ns"},
         "A5 forged registration does not identify exactly retained C and actual B")
    expected = f"registration pid {control_pid} does not match the retained inner receipt child {b}"
    want(fixture.get("expected_refusal") is True and promotion.get("attempted") is True
         and promotion.get("rejected") == expected and promotion.get("owned") is None
         and promotion.get("ack_completed_ns") is None and promotion.get("ack_error") is None,
         "A5 exact receipt mismatch/no-promotion/no-ACK missing")
    want(c.get("pump_stop_reason") == "expected admission refusal" and not c.get("outer_timeout"),
         "A5 refusal replaced by timeout/setup error")
    query = fixture.get("admission_query") or {}
    order = [m, fixture.get("admission_started_ns"), query.get("start_ns"), query.get("end_ns"),
             fixture.get("admission_end_ns"), s]
    want(all(integer(v) for v in order) and order == sorted(order)
         and order[-2] < h and query.get("deadline_ns") == h and query.get("error") is None,
         "A5 live provenance mismatch was not established before original H/S")
    by_pid = {v.get("pid"):v for v in query.get("rows", [])}
    c_row, b_row = by_pid.get(control_pid, {}), by_pid.get(b, {})
    want(c_row.get("pgid") == control_pid and c_row.get("ppid") == control.get("controller_pid") != inner
         and b_row.get("pgid") == b and b_row.get("ppid") == inner
         and "Z" not in c_row.get("stat", "Z") and "Z" not in b_row.get("stat", "Z"),
         "A5 positive unrelated/provenance/pending observation missing")
    parents = [v for v in events if v.get("kind") == "a5_inner_refusal"]
    aborts = [v for v in events if v.get("kind") == "a5_bootstrap_abort"]
    want(len(events) == 2 and len(parents) == len(aborts) == 1, "A5 positive refusal/EOF events missing")
    if len(parents) != 1 or len(aborts) != 1:
        return problems
    parent, abort = parents[0], aborts[0]
    want(parent.get("inner_pid") == inner and parent.get("child_pid") == b
         and parent.get("exit_code") == A5_REFUSAL_EXIT_CODE and parent.get("released") is False
         and parent.get("term_ignore") is True
         and c.get("inner_exit") == e.get("inner_exit") == A5_REFUSAL_EXIT_CODE,
         "A5 actual inner refusal exit73/no-release missing")
    want(all(abort.get(k) == b for k in ("pid", "pgid", "sid"))
         and abort.get("reason") == "release_eof" and abort.get("release_bytes") == 0
         and abort.get("release_frames") == 0 and abort.get("exec_attempted") is False,
         "A5 positive B no-exec/EOF proof missing")
    lease, entry, eof = abort.get("lease_ns"), abort.get("entry_ns"), abort.get("observed_ns")
    lease_valid = all(integer(v) for v in (entry, lease, eof))
    want(lease_valid and lease == entry+500_000_000 and registration.get("entry_ns") == entry
         and registration.get("lease_ns") == fixture.get("lease_ns") == lease,
         "A5 original B lease missing/changed")
    order = [parent.get("receipt_completed_ns"), fixture.get("admission_started_ns"),
             fixture.get("ack_close_started_ns"), parent.get("gate_closed_ns"),
             parent.get("exit_selected_ns"), e.get("reaped_at_ns")]
    want(all(integer(v) for v in order) and order == sorted(order) and m <= order[0]
         and order[-1] < h, "A5 refusal/actual parent wait was not completed before H")
    close_order = [parent.get("release_close_started_ns"), parent.get("release_closed_ns"),
                   parent.get("gate_closed_ns"), parent.get("exit_selected_ns")]
    want(all(integer(v) for v in close_order) and close_order == sorted(close_order)
         and close_order[-1] < h and integer(fixture.get("ack_closed_ns"))
         and integer(fixture.get("ack_close_started_ns"))
         and fixture["ack_close_started_ns"] <= fixture["ack_closed_ns"] < h,
         "A5 raw ACK/release endpoint close facts missing/late")
    captured = fixture.get("capture_completed_ns")
    if lease_valid:
        want(integer(captured) and entry <= eof <= captured < lease
             and integer(parent.get("release_close_started_ns")) and parent["release_close_started_ns"] <= eof,
             "A5 actual EOF/capture was incomplete or after the original lease")
    wait = fixture.get("pending_wait") or {}
    want(fixture.get("pending_ids") == [b] and wait.get("pid") == b
         and wait.get("available") is False and wait.get("status") is None,
         "A5 B pending identity/wait separation missing")
    signals = e.get("signal_events", [])
    want(set(e.get("targets", [])) == {inner, control_pid} and all(v.get("pgid") != b for v in signals),
         "A5 unpromoted B was signalled or ownership union changed")
    for gid, authority in ((inner, "direct_inner_popen"), (control_pid, "direct_control_popen")):
        terms = [v for v in signals if v.get("pgid") == gid and v.get("signal") == "SIGTERM"]
        want(len(terms) == 1 and terms[0].get("authority") == authority
             and terms[0].get("result") == "sent" and terms[0].get("ok") is True,
             "A5 prompt direct-owned TERM authority/success missing")
    witness = e.get("control_witness") or {}
    row = witness.get("control_row") or {}
    order = [e.get("reaped_at_ns"), witness.get("target_gone_ns"),
             witness.get("start_ns"), witness.get("end_ns")]
    want(witness.get("complete") is True and witness.get("worker_unfinished") is False
         and witness.get("error") is None and all(integer(v) for v in order)
         and order == sorted(order) and order[-1] <= witness.get("deadline_ns", 0) == s+1_700_000_000
         and lease_valid and witness.get("start_ns", 0) >= lease
         and witness.get("target_members") == witness.get("pending_members") == [],
         "A5 one target-empty/B-absent/C-live witness by S+1700ms missing")
    want(row.get("pid") == row.get("pgid") == witness.get("control_pgid") == witness.get("control_sid") == control_pid
         and row.get("ppid") == control.get("controller_pid") and "Z" not in row.get("stat", "Z")
         and row in witness.get("rows", []), "A5 witness does not prove retained C live with actual parentage")
    ready_order = [spawn.get("started_ns"), control.get("launch_started_ns"), control.get("owned_at_ns"),
                   ready.get("received_ns"), control.get("injection_prepared_ns"),
                   spawn.get("inner_launch_started_ns")]
    want(all(integer(v) for v in ready_order) and ready_order == sorted(ready_order)
         and integer(ready.get("e_ns")) and control.get("launch_started_ns", 0) <= ready["e_ns"] <= ready.get("received_ns", 0)
         and ready.get("term_ignore") is True and ready.get("pid") == ready.get("pgid") == ready.get("sid") == control_pid,
         "A5 C installed ignore readiness/receipt did not precede injection")
    expiry = ready.get("expiry_ns")
    kills = [v for v in signals if v.get("pgid") == control_pid and v.get("signal") == "SIGKILL"]
    want(integer(expiry) and integer(ready.get("e_ns")) and expiry == ready["e_ns"]+5_000_000_000,
         "A5 C original E+5s self-limit missing")
    if integer(expiry):
        want(len(kills) == 1 and kills[0].get("authority") == "direct_control_popen"
             and kills[0].get("result") == "sent" and kills[0].get("ok") is True
             and integer(kills[0].get("attempt_ns")) and integer(kills[0].get("completed_ns"))
             and integer(witness.get("end_ns")) and witness["end_ns"] <= kills[0]["attempt_ns"]
             and s+1_750_000_000 <= kills[0]["completed_ns"] <= s+2_000_000_000
             and kills[0]["completed_ns"] < expiry,
             "A5 successful C KILL did not follow the witness under original deadlines")
        want(control.get("reaped") is True and control.get("reap", {}).get("signal") == signal.SIGKILL
             and control["reap"].get("observed_by") == "outer_control"
             and integer(control.get("reaped_at_ns")) and control["reaped_at_ns"] <= s+4_000_000_000
             and control["reaped_at_ns"] < expiry, "A5 actual direct C SIGKILL wait before natural expiry missing")
        want(len(kills) == 1 and integer(kills[0].get("completed_ns"))
             and integer(control.get("reaped_at_ns")) and integer(e.get("termination_end_ns"))
             and kills[0]["completed_ns"] <= control["reaped_at_ns"] <= e["termination_end_ns"],
             "A5 C actual wait did not follow KILL within the original termination stage")
    want(set(e.get("verification_owned_groups", [])) == {inner, control_pid}
         and e.get("verification_pending_ids") == [b]
         and not any(v.get("pgid") in (inner, control_pid) or v.get("pid") == b or v.get("pgid") == b
                     for v in e.get("verification_identity_rows", []))
         and type(e.get("verification_validated_row_count")) is int
         and e["verification_validated_row_count"] > 0,
         "A5 final complete query did not verify every owned group and B")
    output = control.get("output") or {}
    want(output.get("complete") is True and output.get("stdout_tail") == output.get("stderr_tail") == "",
         "A5 complete control output missing or unexpected")
    return problems


def _contain_one(name: str, describe: str, argv: list, case_opts: dict,
                 record_dir, *, command=None, expect_no_workload=False) -> dict:
    """One retained inner plus admitted group, with unconditional outer cleanup."""
    early = name in EARLY_TIMEOUT_CASES
    # PREVIEW01: the native preview keeps the check routes' 8s bound unchanged and uses
    # its own 63s outer runtime plus the existing 7s post-stop allowance.
    bound = (OUTER_PREVIEW_RUNTIME_S if name in PREVIEW_CASES
             else (OUTER_EARLY_TIMEOUT_S if early else OUTER_RUNTIME_S))
    if record_dir is None:
        record_dir = tempfile.mkdtemp(prefix="run_bounded_evidence_")
    os.makedirs(record_dir, exist_ok=True)
    inner_path = os.path.join(record_dir, f"{name}.inner.json")
    outer_path = os.path.join(record_dir, f"{name}.json")
    if any(os.path.exists(p) for p in (inner_path, outer_path, outer_path+".fallback.json")):
        return _synthetic_case_record(name, describe, argv, "evidence path already exists")
    cmd = command if command is not None else [
        sys.executable, os.path.abspath(__file__), "--diagnose-one", name, "--record", inner_path]
    token = os.urandom(16).hex()
    reg_r, reg_w = os.pipe()
    ack_r, ack_w = os.pipe()
    descriptors = {reg_r, reg_w, ack_r, ack_w}
    env = os.environ.copy()
    env.update(RB_GATE_REG_FD=str(reg_w), RB_GATE_ACK_FD=str(ack_r),
               RB_GATE_TOKEN=token, RB_GATE_CASE=name)
    problems, pump, escalation = [], {}, {}
    # RUN04-OBS01: controller-owned registration-read observations, engine routes only.
    # Fixed scalar slots; null until actually observed. Non-authoritative.
    reg_obs = ({"last_reg_blocking_ns": None, "receipt_frame_read_ns": None,
                "bootstrap_frame_read_ns": None, "registration_eof_ns": None,
                "admission_dispatch_ns": None} if name in INSTRUMENTED_CASES else None)
    # PREVIEW01 option D: private RSS context for the SAME existing outer verification query.
    preview_outer_diag = {} if name in PREVIEW_CASES else None
    promotion = {"owned": None, "ack_error": None, "rejected": None, "attempted": False}
    spawn = {"case": name, "source_sha256": self_sha256(), "cmd": cmd,
             "pid": None, "pgid": None, "clock": "monotonic_ns",
             "outer_bound_seconds": bound}
    proc = None
    control_proc, control, control_tail = None, None, {}
    record = None
    tail = {}
    pending_identity_complete = False
    a2 = ({"expected_refusal": False, "inner_record_absent": False, "case_token": token,
           "events": [], "pending_wait": {"available": False, "status": None,
           "reason": "pending bootstrap is not the outer's wait child"}}
          if name == A2_PARENT_EXIT_CASE and command is None else None)
    a5 = ({"case_token": token, "expected_refusal": False, "events": [],
           "inner_record_absent": False,
           "pending_wait": {"available": False, "status": None,
                            "reason": "B is not the outer's wait child"}}
          if name == A5_UNRELATED_CASE and command is None else None)
    a3 = ({"case_token": token, "events": [], "inner_record_absent": False}
          if name == A3_CRASH_CASE and command is None else None)
    if a5 is not None:
        for key in ("signal_events", "signals", "cutoff_misses", "sample_errors", "errors"):
            escalation[key] = []
    def close(fd):
        if fd in descriptors:
            descriptors.remove(fd)
            try:
                os.close(fd)
            except OSError:
                pass
    def admit(frames):
        promotion["attempted"] = True
        if a5 is not None:
            receipts = [f for f in frames if f.get("kind") == "receipt"]
            registrations = [f for f in frames if f.get("kind") == "bootstrap"]
            a5["admission_started_ns"] = time.monotonic_ns()
            owned, ack, errors = _admit_candidate(frames, case=name, token=token, inner_proc=proc,
                controller_pid=os.getpid(), controller_pgid=os.getpgrp())
            receipt = receipts[0] if len(receipts) == 1 else {}
            registration = registrations[0] if len(registrations) == 1 else {}
            b, h = receipt.get("child_pid"), receipt.get("h_ns")
            expected = (f"registration pid {control_proc.pid} does not match the retained inner "
                        f"receipt child {b}")
            valid = (owned is None and ack is None and errors == [expected]
                and type(b) is int and type(h) is int and len(frames) == 2
                and b not in (control_proc.pid, proc.pid, os.getpid(), os.getpgrp())
                and registration.get("bootstrap_pid") == b
                and all(registration.get(k) == control_proc.pid for k in ("pid", "pgid", "sid"))
                and type(registration.get("entry_ns")) is int
                and registration.get("lease_ns") == registration["entry_ns"]+500_000_000
                and not CANCEL.is_set() and time.monotonic_ns() < h
                and proc.poll() is None and control_proc.poll() is None)
            if valid:
                query_start = time.monotonic_ns()
                rows, error = _ps_table(end_ns=h)
                queried = time.monotonic_ns()
                by_pid = {r["pid"]:r for r in rows or []}
                c_row, b_row, i_row = (by_pid.get(pid) or {} for pid in (control_proc.pid, b, proc.pid))
                valid = (not error and queried < h and proc.poll() is None and control_proc.poll() is None
                    and c_row.get("pgid") == control_proc.pid and c_row.get("ppid") == os.getpid()
                    and b_row.get("pgid") == b and b_row.get("ppid") == proc.pid
                    and i_row.get("pgid") == proc.pid and "Z" not in c_row.get("stat", "Z")
                    and "Z" not in b_row.get("stat", "Z") and "Z" not in i_row.get("stat", "Z")
                    and os.getsid(control_proc.pid) == control_proc.pid and os.getsid(b) == b
                    and not CANCEL.is_set())
                a5["admission_query"] = {"start_ns": query_start, "end_ns": queried,
                    "deadline_ns": h, "validated_row_count": len(rows or []), "error": error,
                    "rows": [r for r in rows or [] if r["pid"] in (control_proc.pid, b, proc.pid, os.getpid())]}
            a5["admission_end_ns"] = time.monotonic_ns()
            valid = valid and a5["admission_end_ns"] < h
            promotion["rejected"] = "; ".join(errors)
            if valid:
                a5.update(expected_refusal=True, bootstrap_pid=b, lease_ns=registration["lease_ns"])
                a5["pending_wait"]["pid"] = b
                # Refusal selects the original S. Direct Popen ownership is
                # the only authority for these prompt target/control signals.
                _stop_origin(escalation)
                for gid, authority in ((proc.pid, "direct_inner_popen"),
                                       (control_proc.pid, "direct_control_popen")):
                    send_group(gid, signal.SIGTERM, escalation)
                    escalation["signal_events"][-1]["authority"] = authority
                escalation["a5_refused"] = True
                a5["ack_close_started_ns"] = time.monotonic_ns()
                close(ack_w)
                a5["ack_closed_ns"] = time.monotonic_ns()
                return None
            close(ack_w)
            error = "A5 expected live receipt/provenance mismatch before H missing"
            problems.append(error)
            return error
        if a2 is not None:
            receipts = [f for f in frames if f.get("kind") == "receipt"]
            h = receipts[0].get("h_ns") if len(receipts) == 1 else None
            code = None
            if type(h) is int:
                while not CANCEL.is_set() and time.monotonic_ns() < h:
                    code = proc.poll()
                    if code is not None:
                        observed_ns = time.monotonic_ns()
                        a2["parent_wait"] = {"exit_code": code,
                                             "observed_ns": observed_ns}
                        escalation.update(reaped=True, inner_exit=code,
                                          reaped_at_ns=observed_ns)
                        break
                    time.sleep(min(SAMPLE_SLICE_S, max(0, h-time.monotonic_ns())/1e9))
            if (code != A2_PARENT_EXIT_CODE or CANCEL.is_set()
                    or type(h) is not int or time.monotonic_ns() >= h):
                error = "A2 expected parent exit was not observed before H"
                promotion["rejected"] = error
                problems.append(error)
                close(ack_w)
                return error
            a2["admission_started_ns"] = time.monotonic_ns()
            owned, ack, errors = _admit_candidate(
                frames, case=name, token=token, inner_proc=proc,
                controller_pid=os.getpid(), controller_pgid=os.getpgrp())
            a2["admission_end_ns"] = time.monotonic_ns()
            expected = "admission cancelled, expired or parent exited before query"
            close(ack_w)
            promotion["rejected"] = "; ".join(errors)
            if (owned is None and ack is None and errors == [expected]
                    and not CANCEL.is_set() and a2["admission_end_ns"] < h):
                a2["expected_refusal"] = True
                return None  # expected refusal, not a protocol I/O failure
            error = "A2 admission did not produce the exact parent-exit refusal"
            problems.append(error)
            return error  # never promote/ACK an A2 candidate, even on a bad trigger
        # Diagnostic metadata for the headless checks and the native preview (explicit
        # instrumented union); suite selection and runner predicates stay ENGINE_CASES.
        admission_meta = None
        if name in INSTRUMENTED_CASES:
            admission_meta = {"phase": "admission",
                              "primary_branch_ns": time.monotonic_ns()}
            promotion["identity_query"] = admission_meta
        owned, ack, errors = _admit_candidate(
            frames, case=name, token=token, inner_proc=proc,
            controller_pid=os.getpid(), controller_pgid=os.getpgrp(),
            admission_meta=admission_meta)
        if owned is None or CANCEL.is_set() or proc.poll() is not None or time.monotonic_ns() >= ack["h_ns"]:
            promotion["rejected"] = "; ".join(errors) or "parent/cutoff changed before promotion"
            problems.append(promotion["rejected"])
            close(ack_w)
            return promotion["rejected"]
        owned["promoted_at_ns"] = time.monotonic_ns()
        promotion["owned"] = owned
        promotion["ack_error"] = _write_gate_frame(ack_w, ack, ack["h_ns"])
        promotion["ack_completed_ns"] = time.monotonic_ns()
        close(ack_w)
        if promotion["ack_error"]:
            problems.append(promotion["ack_error"])
        return promotion["ack_error"]
    try:
        os.set_blocking(ack_w, False)
        spawn["started_ns"] = time.monotonic_ns()
        spawn["deadline_ns"] = spawn["started_ns"] + int(bound*1e9)
        if a5 is not None:
            control_env = {k:v for k,v in os.environ.items()
                           if k not in (*GATE_ENV_KEYS, "RB_RELEASE_FD", "RB_A5_CONTROL_PID")}
            control_launch = time.monotonic_ns()
            control = {"controller_pid": os.getpid(), "controller_pgid": os.getpgrp(),
                       "launch_started_ns": control_launch, "authority": "direct_control_popen",
                       "gate_descriptors_inherited": False, "argv": list(case_opts["control_argv"]),
                       "reaped": False}
            control_proc = subprocess.Popen(case_opts["control_argv"], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                close_fds=True, env=control_env)
            control.update(pid=control_proc.pid, pgid=control_proc.pid, sid=control_proc.pid)
            control["owned_at_ns"] = time.monotonic_ns()
            ready, raw_ready = _read_fixture_ready(control_proc, A5_UNRELATED_CASE, spawn["deadline_ns"])
            control.update(ready=ready, ready_frame=raw_ready.decode("utf-8"))
            pump["control_ready_bytes"] = len(raw_ready)
            if ready.get("term_ignore") is not True:
                raise ValueError("A5 installed control TERM-ignore readiness missing")
            env["RB_A5_CONTROL_PID"] = str(control_proc.pid)
            control["injection_prepared_ns"] = time.monotonic_ns()
        if CANCEL.is_set() or time.monotonic_ns() >= spawn["deadline_ns"]:
            raise ValueError("outer setup cancelled/expired before inner Popen")
        spawn["inner_launch_started_ns"] = time.monotonic_ns()
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            pass_fds=(reg_w, ack_r), env=env)
        spawn["pid"], spawn["pgid"] = proc.pid, proc.pid
        spawn["m_ns"] = time.monotonic_ns()
        close(reg_w)
        close(ack_r)
        pump = _outer_pump(proc, reg_r, spawn["deadline_ns"],
                           OUTER_PIPE_CAP_BYTES-pump.get("control_ready_bytes", 0),
                           admit, state=escalation, progress=pump, reg_obs=reg_obs)
    except Exception as exc:
        if proc is not None or control_proc is not None:
            _stop_origin(escalation)
        problems.append(f"outer failed: {type(exc).__name__}: {exc}")
    finally:
        if proc is not None or control_proc is not None:
            _stop_origin(escalation)
            for key in ("signal_events", "signals", "cutoff_misses", "sample_errors", "errors"):
                escalation.setdefault(key, [])
            owned = [promotion["owned"]["pgid"]] if promotion["owned"] else []
            pending = set()
            if not owned:
                for frame in pump.get("frames", []):
                    for key in ("pid", "child_pid", "pgid"):
                        value = frame.get(key)
                        if type(value) is int and value > 0:
                            pending.add(value)
                pending.difference_update((*( [proc.pid] if proc is not None else []),
                                           os.getpid(), os.getpgrp()))
                if a5 is not None and control_proc is not None:
                    # Only exact equality to the separately retained direct C
                    # removes the forged registration from B's pending set.
                    pending.discard(control_proc.pid)
            frames = pump.get("frames", [])
            pending_identity_complete = (
                bool(owned) or
                (pump.get("reg_eof") is True and not pump.get("reg_error")
                 and len(frames) == 2 and bool(pending)))
            try:
                # Corresponding verification for an instrumented engine admission.
                _escalate_process(proc, owned, state=escalation, pending=pending,
                    control_proc=control_proc, control=control,
                    lease_ns=(a5 or {}).get("lease_ns"), capture=pump if a5 is not None else None,
                    query_meta=({"phase": "verification"}
                                if "identity_query" in promotion else None),
                    preview_diag=preview_outer_diag)
            except Exception as exc:
                escalation.setdefault("errors", []).append(f"outer finalization: {exc}")
                for key in ("signal_events", "signals", "cutoff_misses", "sample_errors"):
                    escalation.setdefault(key, [])
                try:
                    if control_proc is not None:
                        _a5_stop_owned(proc, control_proc, control, escalation,
                            [*([proc.pid] if proc is not None else []), *owned, control_proc.pid],
                            pending, (a5 or {}).get("lease_ns"), observe_allowed=False)
                    else:
                        _emergency_stop(proc.pid, [proc.pid, *owned], escalation, proc)
                except Exception as fallback:
                    escalation["errors"].append(f"outer direct fallback: {fallback}")
            start = time.monotonic_ns()
            end = min(start+2_000_000_000, escalation["s_ns"]+7_000_000_000)
            escalation.update(collection_start_ns=start, collection_deadline_ns=end,
                              collection_complete=False)
            try:
                used = len(pump.get("stdout", b""))+len(pump.get("stderr", b""))
                used += len((control or {}).get("ready_frame", "").encode())
                if proc is not None:
                    tail = _outer_pump(proc, None, end, max(0, OUTER_PIPE_CAP_BYTES-used), collection=True)
                if control_proc is not None:
                    used += len(tail.get("stdout", b""))+len(tail.get("stderr", b""))
                    control_tail = _outer_pump(control_proc, None, end,
                        max(0, OUTER_PIPE_CAP_BYTES-used), collection=True)
                    control["output"] = {"stdout_tail": bytes(control_tail["stdout"]).decode("utf-8", "replace"),
                        "stderr_tail": bytes(control_tail["stderr"]).decode("utf-8", "replace"),
                        "complete": not (control_tail.get("open_at_end") or control_tail.get("read_errors")
                                         or control_tail.get("capped"))}
                if (a2 is not None and a2["expected_refusal"]
                        and proc.returncode == A2_PARENT_EXIT_CODE):
                    if os.path.exists(inner_path):
                        raise ValueError("A2 unexpected inner record after deliberate exit")
                    a2["inner_record_absent"] = True
                elif (a5 is not None and a5["expected_refusal"] and proc is not None
                      and proc.returncode == A5_REFUSAL_EXIT_CODE):
                    if os.path.exists(inner_path):
                        raise ValueError("A5 unexpected inner record after refusal exit")
                    a5["inner_record_absent"] = True
                elif a3 is not None and proc is not None and proc.returncode == A3_CRASH_EXIT_CODE:
                    if os.path.exists(inner_path):
                        raise ValueError("A3 unexpected record after deliberate crash")
                    a3["inner_record_absent"] = True
                elif command is None and name not in OUTER_SELFTEST_CASES:
                    record, read_error = _read_record_bounded(inner_path, end)
                    if read_error:
                        raise ValueError(read_error)
                elif command is not None and "--record" in command:
                    path_index = command.index("--record")+1
                    value, read_error = _read_record_bounded(command[path_index], end)
                    if read_error:
                        raise ValueError(read_error)
                    record = {"case": name, "argv": argv, "describe": describe,
                              "inner": True, "result": value, "problems": []}
                escalation["collection_complete"] = not (
                    tail.get("open_at_end") or tail.get("read_errors") or tail.get("capped")
                    or control_tail.get("open_at_end") or control_tail.get("read_errors") or control_tail.get("capped"))
            except Exception as exc:
                problems.append(f"collection failed: {type(exc).__name__}: {exc}")
            escalation["collection_end_ns"] = time.monotonic_ns()
            escalation["post_stop_end_ns"] = time.monotonic_ns()
        for fd in tuple(descriptors):
            close(fd)
        if proc is not None:
            for stream in (proc.stdout, proc.stderr):
                if stream is not None:
                    stream.close()
        if control_proc is not None:
            for stream in (control_proc.stdout, control_proc.stderr):
                if stream is not None:
                    stream.close()
    if proc is None:
        failed = _synthetic_case_record(name, describe, argv, "; ".join(problems))
        failed["setup_cleanup"] = {"spawn": spawn, "direct_control": control, "escalation": escalation}
        if control_proc is not None:
            # Preserve the C-owned collection deadline for the case, summary
            # and console even when setup failed before I existed.
            failed["containment"] = {"spawn": spawn, "escalation": escalation,
                "direct_control": control, "promotion": promotion, "inner_exit": None,
                "pending_identity_status": "not applicable: inner was never created"}
            sink = write_record_once(outer_path, failed, end_ns=escalation["collection_deadline_ns"])
            failed["sink"] = sink
            escalation["collection_end_ns"] = escalation["post_stop_end_ns"] = sink["completed_ns"]
            if not sink["primary_ok"] or sink["late"]:
                failed["problems"].append("failed-setup primary evidence incomplete/late")
                escalation["collection_complete"] = False
        return failed
    stderr_b = bytes(pump.get("stderr", b""))+bytes(tail.get("stderr", b""))
    stdout_b = bytes(pump.get("stdout", b""))+bytes(tail.get("stdout", b""))
    for fixture, kinds in ((a5, {"a5_inner_refusal", "a5_bootstrap_abort"}),
                           (a3, {"a3_gate", "a3_ready", "a3_crash"})):
        if fixture is None:
            continue
        fixture["capture_completed_ns"] = (pump.get("a5_capture_completed_ns")
            if fixture is a5 else pump.get("completed_ns"))
        fixture["registration_eof"] = pump.get("reg_eof") is True
        if stdout_b or not stderr_b.endswith(b"\n"):
            problems.append(f"{name} unexpected stdout or incomplete evidence newline")
        for line in stderr_b.splitlines():
            try:
                event = json.loads(line)
                if not isinstance(event, dict) or event.get("kind") not in kinds or len(line)+1 > FRAME_MAX_BYTES:
                    raise ValueError("unexpected/oversized fixture evidence frame")
                fixture["events"].append(event)
            except (ValueError, UnicodeError) as exc:
                problems.append(f"{name} evidence parse failed: {exc}: {line[:160]!r}")
    if a5 is not None:
        a5["pending_ids"] = sorted(pending)
    if a2 is not None:
        a2["registration_eof"] = pump.get("reg_eof") is True
        a2["pending_ids"] = sorted(pending)
        a2["pending_wait"]["pid"] = next(iter(pending)) if len(pending) == 1 else None
        a2["capture_completed_ns"] = pump.get("completed_ns")
        if stdout_b or not stderr_b.endswith(b"\n"):
            problems.append("A2 unexpected stdout or incomplete evidence newline")
        for line in stderr_b.splitlines():
            if line.startswith(b'{'):
                try:
                    event = json.loads(line)
                    if (not isinstance(event, dict) or event.get("kind") not in
                            ("a2_parent_exit", "a2_bootstrap_abort")):
                        raise ValueError("unexpected A2 evidence frame")
                    if len(line)+1 > FRAME_MAX_BYTES:
                        raise ValueError("A2 evidence frame oversized")
                    a2["events"].append(event)
                except (ValueError, UnicodeError) as exc:
                    problems.append(f"A2 evidence parse failed: {exc}")
            else:
                problems.append("A2 unexpected stderr: " + line[:200].decode("utf-8", "replace"))
    ready = None
    prefix = f"CASE {name} READY term_ignore=true ready_ns="
    for line in stderr_b.decode("utf-8", "replace").splitlines():
        if line.startswith(prefix):
            try:
                value = int(line[len(prefix):])
                if ready is not None:
                    problems.append("duplicate READY")
                ready = value
            except ValueError:
                problems.append("invalid READY clock")
    no_workload_proven = (
        name in OUTER_SELFTEST_CASES or
        (expect_no_workload and command is not None and proc.returncode == EXIT_USAGE
         and pump.get("reg_eof") is True and not pump.get("registration_bytes")) or
        (command is None and record is not None and proc.returncode == 0
         and record.get("result", {}).get("child", {}).get("launched") is False
         and record.get("result", {}).get("pid") is None
         and pump.get("reg_eof") is True and not pump.get("registration_bytes")))
    pending_status = ("not applicable: no workload" if no_workload_proven else
                      "identified" if pending_identity_complete else "unknown")
    if pending_status == "unknown":
        problems.append("pending child identity/disappearance unknown")
        escalation["verification_complete"] = False
    # Checked local inner-result mapping view, PREVIEW ONLY: a missing/null/non-mapping
    # result is carried as None and every dependent preview extraction is skipped. The
    # original stored inner result is left unchanged, and non-preview extraction/arguments
    # are preserved exactly. The nested retained gate is handed to the shared outer
    # validator only when it is itself a mapping; a wrong/absent container is a truthful
    # failure rather than a scalar forwarded into the validator.
    preview_inner = None
    preview_gate = None
    if name in PREVIEW_CASES:
        preview_inner = record.get("result") if isinstance(record, dict) else None
        preview_inner = preview_inner if isinstance(preview_inner, dict) else None
        raw_gate = preview_inner.get("gate") if preview_inner else None
        if isinstance(raw_gate, dict):
            preview_gate = raw_gate
        else:
            problems.append("preview retained inner gate unavailable (not a mapping)")
    containment = {
        "pending_identity_status": pending_status,
        "spawn": spawn, "escalation": escalation, "promotion": promotion,
        "bound_seconds": bound, "inner_exit": proc.returncode,
        "outer_timeout": pump.get("stopped_reason") == "deadline",
        "live_at_deadline": pump.get("live_at_deadline"),
        "pump_stop_reason": pump.get("stopped_reason"),
        "capped": bool(pump.get("capped") or tail.get("capped") or control_tail.get("capped")),
        "read_errors": [*pump.get("read_errors", []), *tail.get("read_errors", []),
                        *control_tail.get("read_errors", [])],
        "registration_error": pump.get("reg_error"),
        "registration_frames": pump.get("frames", []),
        "inner_gate": (preview_gate if name in PREVIEW_CASES
                       else (record or {}).get("result", {}).get("gate")),
        "ready_ns": ready, "ready_observed_ns": pump.get("ready_observed_ns"),
        "gate_applicability": ("not applicable: A1 has no workload"
                               if name in OUTER_SELFTEST_CASES else "required for launched workload"),
        "stdout_tail": stdout_b[-2000:].decode("utf-8", "replace"),
        "stderr_tail": stderr_b[-2000:].decode("utf-8", "replace"),
    }
    if reg_obs is not None:
        # RUN04-OBS01: engine-only controller read observations; producer timestamps
        # stay in registration_frames and are not duplicated here.
        containment["registration_reads"] = reg_obs
    if preview_outer_diag is not None:
        # F2: complete the all-phase maximum at the OUTER level (the inner record's
        # `peak_across_phases_bytes` stays scoped to inner-observed phases). Combine the
        # inner usable retained/runtime phases with the outer-verification observation by
        # maximum over usable observations only, never a sum of phase peaks.
        _op = escalation.get("preview_outer_rss")
        outer_phase = _op if isinstance(_op, dict) else {}
        inner_agg = preview_inner.get("preview_aggregate") if preview_inner else None
        inner_peak = (inner_agg.get("peak_across_phases_bytes")
                      if isinstance(inner_agg, dict) else None)
        if type(inner_peak) is not int:
            # Unavailable inner qualified peak stays an explicit failure fact; never
            # manufacture a complete maximum from a default zero plus an outer-only value.
            containment["preview_all_phase_peak_bytes"] = None
            problems.append("preview inner qualified all-phase peak unavailable")
        else:
            all_phase_totals = [inner_peak]
            outer_usable = outer_phase.get("measurement_usable") is True
            outer_bytes = outer_phase.get("observed_bytes") if outer_usable else None
            if outer_usable and not (type(outer_bytes) is int and outer_bytes > 0):
                # A claimed-usable outer contribution with missing/null/nonnumeric/non-positive
                # bytes is invalid evidence: keep the complete peak unavailable instead of
                # coercing text, substituting zero, or labeling an inner-only total complete.
                containment["preview_all_phase_peak_bytes"] = None
                problems.append("preview outer usable phase bytes unavailable/invalid")
            else:
                if outer_usable:
                    all_phase_totals.append(outer_bytes)
                containment["preview_all_phase_peak_bytes"] = max(all_phase_totals)
        # F3: the inner can only persist reporting facts known BEFORE it serialized its
        # record. A failure during the later stderr report forces the observed inner exit
        # to EXIT_INTERNAL while the serialized exit stays at the operating/ok value; that
        # divergence is the durable, outer-observed evidence of a reporting failure.
        serialized_exit = preview_inner.get("exit_code") if preview_inner else None
        persisted = (bool(preview_inner)
                     and (preview_inner.get("reporting_failure") is True
                          or bool(preview_inner.get("reporting_errors"))))
        overrode = (type(serialized_exit) is int and proc.returncode == EXIT_INTERNAL
                    and serialized_exit != EXIT_INTERNAL)
        containment["inner_reporting_failure"] = bool(persisted or overrode)
        # Step 3: retain the outer process's existing first cancel receipt (integer ns or
        # None), copied from the existing process-local first CANCEL_AT_NS with no fresh read.
        containment["outer_cancel_received_ns"] = CANCEL_AT_NS
    if a2 is not None:
        containment["expected_parent_exit"] = a2
    if a5 is not None:
        containment.update(unrelated_refusal=a5, direct_control=control)
    if a3 is not None:
        containment["expected_inner_crash"] = a3
        gates = [v for v in a3["events"] if v.get("kind") == "a3_gate"]
        receipts = [v for v in containment["registration_frames"] if v.get("kind") == "receipt"]
        a3["workload_wait"] = {"pid": receipts[0].get("child_pid") if len(receipts) == 1 else None,
            "available": False, "status": None, "reason": "released workload is not the outer's wait child"}
        if len(gates) == len(receipts) == 1:
            # Reconstruct only clocks reported by the actual crashing inner,
            # paired with the original receipt; no final JSON grants ownership.
            containment["inner_gate"] = {**{k:receipts[0].get(k) for k in
                ("m_ns", "h_ns", "w_ns", "f_ns", "decision_ns")},
                **{k:gates[0].get(k) for k in
                ("receipt_completed_ns", "ack_at_ns", "release_at_ns", "released")}}
    def _selected_checks(stage, result):
        # Bounded evidence-preservation backstop for the preview route ONLY: an ordinary
        # qualification exception becomes a compact failure diagnostic instead of suppressing
        # the outer record. Never catches BaseException, never wraps cleanup/safety/the whole
        # launcher, and never clears earlier problems or rewrites the immutable primary.
        if name not in PREVIEW_CASES:
            return _selected_outer_predicates(name, containment, result)
        try:
            return _selected_outer_predicates(name, containment, result)
        except Exception as exc:  # noqa: BLE001 - bounded preview qualification backstop
            return [f"preview {stage} qualification failed: "
                    f"{type(exc).__name__}: {str(exc)[:256]}"]

    problems.extend(_outer_predicates(containment, a1=name in OUTER_SELFTEST_CASES))
    if a2 is not None:
        problems.extend(_a2_parent_exit_predicates(containment))
    problems.extend(_selected_checks(
        "pre-write",
        preview_inner if name in PREVIEW_CASES else (record or {}).get("result")))
    if name not in OUTER_SELFTEST_CASES and containment["outer_timeout"]:
        problems.append("unexpected outer timeout")
    if record is None:
        record = {"case": name, "argv": argv, "describe": describe, "inner": False,
                  "result": {"exit_code": proc.returncode,
                             "reason": ("expected_parent_exit_before_admission"
                                        if a2 is not None and a2["expected_refusal"]
                                        else "expected_unrelated_admission_refusal"
                                        if a5 is not None and a5["expected_refusal"]
                                        else "expected_inner_crash" if a3 is not None
                                        and proc.returncode == A3_CRASH_EXIT_CODE
                                        else "outer_timeout" if containment["outer_timeout"]
                                        else "outer_completed")},
                  "problems": []}
    if command is not None and "--record" in command and not promotion["owned"]:
        problems.append("normal regression workload admission missing")
    if (command is None and name not in OUTER_SELFTEST_CASES and proc.returncode != 0
            and not (a2 is not None and a2["expected_refusal"]
                     and proc.returncode == A2_PARENT_EXIT_CODE)
            and not (a5 is not None and a5["expected_refusal"] and proc.returncode == A5_REFUSAL_EXIT_CODE)
            and not (a3 is not None and proc.returncode == A3_CRASH_EXIT_CODE)):
        problems.append("inner verdict or evidence sink returned nonzero")
    record["problems"] = list(record.get("problems", []))+problems
    record.update(containment=containment, passed=not record["problems"],
                  wall_clock_seconds=(time.monotonic_ns()-spawn["started_ns"])/1e9)
    record["recorded_at_utc"] = utcnow()
    sink = write_record_once(outer_path, record, end_ns=escalation["collection_deadline_ns"])
    record["sink"] = sink
    escalation["collection_end_ns"] = sink["completed_ns"]
    escalation["post_stop_end_ns"] = sink["completed_ns"]
    if not sink["primary_ok"] or sink["late"]:
        record["passed"] = False
        record["problems"].append("primary evidence incomplete or late")
        escalation["collection_complete"] = False
    record["problems"].extend(_outer_predicates(containment, a1=name in OUTER_SELFTEST_CASES))
    if a2 is not None:
        record["problems"].extend(_a2_parent_exit_predicates(containment))
    _post = record.get("result")
    if name in PREVIEW_CASES and not isinstance(_post, dict):
        _post = None
    record["problems"].extend(_selected_checks("post-write", _post))
    record["passed"] = not record["problems"]
    return record


def run_diagnose(names: list, record_dir) -> int:
    install_signal_handlers()
    REPORTING_ERRORS.clear()
    specs = case_specs()
    records = []
    if any(n in ENGINE_CASES or n in PREVIEW_CASES for n in names):
        # RUN01/PREVIEW01: the engine and preview routes never fall back to a temp
        # directory; the attempt directory must be fresh, un-symlinked and inside the
        # route's named evidence root.
        root = (RUN01_EVIDENCE_ROOT if any(n in ENGINE_CASES for n in names)
                else PREVIEW_EVIDENCE_ROOT)
        problem = validate_engine_record_dir(record_dir, root)
        if problem:
            note(problem)
            return EXIT_USAGE
    elif record_dir is None:
        record_dir = tempfile.mkdtemp(prefix="run_bounded_diagnose_")
    for name in names:
        if CANCEL.is_set():
            break
        describe, argv, case_opts = specs[name]
        command = None
        if name == "b1_normal_cli":
            command = [sys.executable, os.path.abspath(__file__),
                "--wall-seconds", "5", "--rss-mib", "512", "--output-bytes", "262144", "--poll-ms", "100",
                "--keep-output", "--record", os.path.join(record_dir, f"{name}.inner.json"), "--", *argv]
        elif name == GODOT_PARSE_CASE:
            command = [sys.executable, "-B", os.path.abspath(__file__),
                "--wall-seconds", "5", "--rss-mib", "512", "--output-bytes", "262144", "--poll-ms", "100",
                "--keep-output", "--record", os.path.join(record_dir, f"{name}.inner.json"), "--", *argv]
        elif name in ENGINE_CASES:
            # Fixed normal-command path with the proposal's limits, never --diagnose-one:
            # the engine child still has to register, be admitted and be released by the gate.
            suite = GODOT_ENGINE_SUITE[name]
            out_dir = os.path.join(record_dir, suite, "runner")
            argv = engine_child_argv(suite, out_dir)
            case_opts = dict(case_opts)
            case_opts["engine_suite"] = suite
            command = [sys.executable, "-B", os.path.abspath(__file__),
                *ENGINE_INNER_LIMITS,
                "--record", os.path.join(record_dir, f"{name}.inner.json"), "--", *argv]
        elif name in PREVIEW_CASES:
            # PREVIEW01: fixed native main-scene command with its own 60s/4s limits; the
            # child still registers, is admitted and is released by the retained gate.
            argv = preview_child_argv()
            command = [sys.executable, "-B", os.path.abspath(__file__),
                *PREVIEW_INNER_LIMITS,
                "--record", os.path.join(record_dir, f"{name}.inner.json"), "--", *argv]
        record = _contain_one(name, describe, argv, case_opts, record_dir, command=command)
        records.append(record)
        if not record["passed"]:
            break
    summary = {
        "cases": list(names), "records": records,
        "not_run": list(names[len(records):]),
        "failed_cases": [r["case"] for r in records if not r["passed"]],
        "mode": "diagnose",
        "passed": len(records) == len(names) and all(r["passed"] for r in records),
        "recorded_at_utc": utcnow(), "supervisor_sha256": self_sha256(),
        "reporting_errors": list(REPORTING_ERRORS),
        "limits": {"outer_runtime_s": (OUTER_PREVIEW_RUNTIME_S
                                       if names == [GODOT_NATIVE_PREVIEW_CASE]
                                       else OUTER_RUNTIME_S),
                   "early_runtime_s": OUTER_EARLY_TIMEOUT_S,
                   "post_stop_s": OUTER_POST_STOP_S,
                   "capture_bytes": OUTER_PIPE_CAP_BYTES},
    }
    last_end = (records[-1].get("containment", {}).get("escalation", {})
                .get("collection_deadline_ns")) if records else None
    summary["sink"] = write_record_once(
        os.path.join(record_dir, "summary.json"), summary, end_ns=last_end)
    if records and records[-1].get("containment"):
        last = records[-1]["containment"]["escalation"]
        last["collection_end_ns"] = summary["sink"]["completed_ns"]
        last["post_stop_end_ns"] = summary["sink"]["completed_ns"]
        if summary["sink"]["late"]:
            last["collection_complete"] = False
    if not summary["sink"]["primary_ok"] or summary["sink"]["late"] or REPORTING_ERRORS:
        summary["passed"] = False
    summary["console_status"] = "pending at serialization; process exit owns final verdict"
    report = _report_text(json.dumps(summary, indent=2, sort_keys=True)+"\n",
                          sys.stdout, last_end)
    if records and records[-1].get("containment"):
        last["collection_end_ns"] = report["completed_ns"]
        last["post_stop_end_ns"] = report["completed_ns"]
        if not report["complete"]:
            last["collection_complete"] = False
    if not report["complete"] or REPORTING_ERRORS:
        summary["passed"] = False
    return 0 if summary["passed"] else 1


def split_argv(argv: list) -> tuple:
    if "--" in argv:
        index = argv.index("--")
        return list(argv[:index]), list(argv[index + 1:])
    return list(argv), []


def validate_options(ns, child: list, mode: str):
    """Shared option validation, run before any dispatch (contract 2).

    Returns an error message or None. Normal mode additionally requires an
    explicit finite positive wall, a finite RSS limit of at least 1 MiB and
    whole-number rss/cpu values. Diagnose modes reject every limit override
    because case limits are fixed by the harness (R03 contract F05).
    """
    if mode in ("diagnose", "diagnose-one", "argcheck"):
        for flag, value in (
            ("--wall-seconds", ns.wall_seconds),
            ("--rss-mib", ns.rss_mib),
            ("--cpu-seconds", ns.cpu_seconds),
            ("--output-bytes", ns.output_bytes),
            ("--poll-ms", ns.poll_ms),
        ):
            if value is not None:
                return (f"{flag} is not supported with this mode; "
                        "limits are fixed by the harness")
    wall = ns.wall_seconds
    if wall is not None and not _finite_positive(wall):
        return "--wall-seconds must be a finite positive value"
    if mode == "normal" and wall is None:
        return "--wall-seconds must be a finite positive value"
    rss = ns.rss_mib
    if rss is not None:
        if not (math.isfinite(float(rss)) and float(rss) >= 1):
            return "--rss-mib must be a finite value of at least 1"
        if float(rss) != int(float(rss)):
            return "--rss-mib must be a whole number of MiB"
    if mode == "normal" and rss is None:
        return "--rss-mib must be a finite value of at least 1"
    cpu = ns.cpu_seconds
    if cpu is not None:
        if not _finite_positive(cpu):
            return "--cpu-seconds must be a finite positive value"
        if float(cpu) != int(float(cpu)):
            return "--cpu-seconds must be a whole number of seconds"
    if ns.output_bytes is not None and not (
            OUTPUT_MIN_BYTES <= int(ns.output_bytes) <= OUTPUT_MAX_BYTES):
        return "--output-bytes must be an integer between 1024 and 8388608"
    if ns.poll_ms is not None and not (POLL_MIN_MS <= int(ns.poll_ms)
                                       <= POLL_MAX_MS):
        return "--poll-ms must be an integer between 50 and 5000"
    if mode == "normal" and not child:
        return "no child arguments after --"
    if mode == "diagnose-one" and not ns.record:
        return "--diagnose-one requires --record <path>"
    if mode == "diagnose-one" and child:
        return "no child arguments with --diagnose-one"
    if mode == "diagnose-one" and ns.diagnose_one is not None \
            and ns.diagnose_one.strip() in ENGINE_CASES:
        # RUN01: the engine routes only exist behind the retained outer controller's private
        # admission; an in-process --diagnose-one dispatch would bypass it.
        return ("--diagnose-one cannot dispatch an engine acceptance route; "
                "use --diagnose so the retained outer controller owns admission")
    if mode == "normal" and child and child[0] == GODOT_ENGINE_BINARY:
        # RUN01 F05: this classifier was sending every normal-mode Godot child through
        # engine_child_case, whose only accepted shapes are the two RUN01 suites. The
        # retained godot_parse_probe shares the engine binary but has a different fixed
        # shape (--check-only, no "--" separator), so it was refused before launch.
        # Recognise the exact retained parse argv, keep every RUN01 refusal for anything
        # else, and require the outer private admission on both routes: the retained parse
        # command is only ever spawned by _contain_one, which always supplies it.
        if child != list(GODOT_PARSE_ARGV) and child != list(GODOT_PREVIEW_ARGV) \
                and engine_child_case(child) is None:
            return ("engine child argv is neither the retained godot_parse_probe route nor "
                    "one of the registered fixed RUN01 routes nor the native preview "
                    "(unknown profile, seed, limits or output destination)")
        for env_key in ("RB_GATE_TOKEN", "RB_GATE_REG_FD", "RB_GATE_ACK_FD", "RB_GATE_CASE"):
            if not os.environ.get(env_key):
                return ("engine routes require outer private admission; missing " + env_key)
    return None


def _ps_find(marker: str, *, end_ns=None) -> tuple:
    """Observe exact marker shape; a match never confers signal ownership."""
    if end_ns is None:
        end_ns = time.monotonic_ns()+int(PS_TIMEOUT_SECONDS*1e9)
    needle = f"-c import time; print('{marker}', flush=True); time.sleep(30)"
    out, _query_pid, error = _ps_capture("pid=,command=", end_ns)
    if error:
        return None, error
    seen, matches = set(), []
    try:
        for line in out.decode("utf-8", "strict").splitlines():
            fields = line.split(None, 1)
            if len(fields) != 2:
                return None, "incomplete marker-query row"
            pid = int(fields[0])
            if pid < 0 or pid in seen:
                return None, "invalid marker-query identity"
            seen.add(pid)
            if needle in fields[1]:
                matches.append(pid)
    except (ValueError, UnicodeError) as exc:
        return None, f"invalid marker query: {exc}"
    if os.getpid() not in seen or time.monotonic_ns() > end_ns:
        return None, "marker query incomplete or late"
    return matches, None



def _run_bounded_subprocess(cmd: list, timeout_s: float, *, expect_no_workload=False) -> dict:
    """Normal CLI regression uses the same private gate and unconditional stop."""
    evidence = tempfile.mkdtemp(prefix="run_bounded_argcheck_")
    record = _contain_one("normal_regression", "normal CLI regression", cmd,
                          {}, evidence, command=cmd, expect_no_workload=expect_no_workload)
    c = record.get("containment", {})
    return {"argv": list(cmd), "capped": c.get("capped", False),
            "duration_s": record.get("wall_clock_seconds"),
            "escalation": c.get("escalation", {}),
            "exit": c.get("inner_exit"),
            "output": c.get("stdout_tail", "")+"\n"+c.get("stderr_tail", ""),
            "timed_out": c.get("outer_timeout", True),
            "containment_ok": record["passed"], "evidence_dir": evidence,
            "problems": record.get("problems", []),
            "inner_result": record.get("result"),
            "evidence_deadline_ns": c.get("escalation", {}).get("collection_deadline_ns")}


def run_argcheck(record_path) -> int:
    """Verify normal-mode argument rejection/acceptance (contract 2).

    Every invalid invocation runs a harmless child whose argv carries a
    marker; exit 2 plus an absent marker in a bounded process observation
    corroborates rejection. Matches fail the case and never grant signal
    ownership. The common outer controller cleans only retained/admitted
    groups. One valid invocation checks explicit limits.
    """
    if not record_path:
        note("argcheck requires --record <path>")
        return EXIT_USAGE
    install_signal_handlers()
    here = os.path.abspath(__file__)
    marker_child = [
        sys.executable, "-c",
        f"import time; print('{ARGCHECK_MARKER}', flush=True); time.sleep(30)",
    ]
    invalid = [
        ("wall_missing", ["--rss-mib", "512"], True),
        ("wall_nan", ["--wall-seconds", "nan", "--rss-mib", "512"], True),
        ("wall_inf", ["--wall-seconds", "inf", "--rss-mib", "512"], True),
        ("wall_zero", ["--wall-seconds", "0", "--rss-mib", "512"], True),
        ("wall_negative", ["--wall-seconds", "-1", "--rss-mib", "512"], True),
        ("rss_missing", ["--wall-seconds", "5"], True),
        ("rss_zero", ["--wall-seconds", "5", "--rss-mib", "0"], True),
        ("rss_negative", ["--wall-seconds", "5", "--rss-mib", "-1"], True),
        ("rss_nan", ["--wall-seconds", "5", "--rss-mib", "nan"], True),
        ("rss_inf", ["--wall-seconds", "5", "--rss-mib", "inf"], True),
        ("rss_fractional", ["--wall-seconds", "5", "--rss-mib", "1.5"], True),
        ("output_small", ["--wall-seconds", "5", "--rss-mib", "512",
                          "--output-bytes", "100"], True),
        ("output_large", ["--wall-seconds", "5", "--rss-mib", "512",
                          "--output-bytes", "8388609"], True),
        ("poll_small", ["--wall-seconds", "5", "--rss-mib", "512",
                        "--poll-ms", "10"], True),
        ("poll_large", ["--wall-seconds", "5", "--rss-mib", "512",
                        "--poll-ms", "5001"], True),
        ("cpu_zero", ["--wall-seconds", "5", "--rss-mib", "512",
                      "--cpu-seconds", "0"], True),
        ("cpu_fractional", ["--wall-seconds", "5", "--rss-mib", "512",
                            "--cpu-seconds", "0.5"], True),
        ("child_missing", ["--wall-seconds", "5", "--rss-mib", "512"], False),
        ("diagnose_wall_nan", ["--diagnose", "deadline",
                               "--wall-seconds", "nan"], False),
        ("diagnose_wall_override", ["--diagnose", "deadline",
                                    "--wall-seconds", "5"], False),
        ("diagnose_rss_override", ["--diagnose", "deadline",
                                   "--rss-mib", "512"], False),
        # RUN01: an engine acceptance route must never be dispatched in-process; it only exists
        # behind the retained outer controller's private admission.
        ("engine_diagnose_one_refused",
         ["--diagnose-one", "godot_play01_probe",
          "--record", os.path.join(tempfile.gettempdir(),
                                   "run_bounded_argcheck_engine.json")], False),
    ]
    cases: list = []
    passed_all = True
    for name, flags, with_child in invalid:
        cmd = [sys.executable, here, *flags]
        if with_child:
            cmd += ["--", *marker_child]
        outcome = _run_bounded_subprocess(cmd, ARGCHECK_SUBPROCESS_TIMEOUT_S,
                                          expect_no_workload=True)
        pids, ps_error = _ps_find(
            ARGCHECK_MARKER, end_ns=outcome.get("evidence_deadline_ns"))
        marker_absent = (pids is not None and not pids) and ps_error is None
        cleanup: dict = {}
        if pids:
            cleanup = {"not_attempted": "marker match confers no signal ownership"}
        rejected_note = "NOTE " in outcome["output"]
        ok = (outcome["containment_ok"] and outcome["exit"] == EXIT_USAGE and not outcome["timed_out"]
              and marker_absent and rejected_note and ps_error is None)
        passed_all = passed_all and ok
        cases.append({
            "argv": cmd,
            "case": name,
            "cleanup": cleanup,
            "duration_s": outcome["duration_s"],
            "exit": outcome["exit"],
            "expected_exit": EXIT_USAGE,
            "found_pids": pids,
            "marker_absent": marker_absent,
            "output_capped": outcome["capped"],
            "passed": ok,
            "ps_error": ps_error,
            "rejected_note": rejected_note,
            "timed_out": outcome["timed_out"],
            "output_tail": outcome["output"][-400:],
        })
        if not ok:
            break
        report = _report_text(
            f"ARGCHECK {name} pre-report-verdict=PASS exit={outcome['exit']}\n",
            sys.stderr, outcome.get("evidence_deadline_ns"))
        if not report["complete"]:
            passed_all = False
            break

    valid_path = os.path.join(os.path.dirname(os.path.abspath(record_path)),
                              "argcheck_valid_run.json")
    if not passed_all or len(cases) != len(invalid) or os.path.exists(valid_path):
        failure = {"mode": "argcheck", "passed": False, "cases": cases,
                   "not_run": [v[0] for v in invalid[len(cases):]]+["valid_run"],
                   "problems": ["prior case failed or valid evidence path already exists"]}
        write_record_once(record_path, failure, end_ns=outcome.get("evidence_deadline_ns"))
        return EXIT_INTERNAL
    valid_child = [sys.executable, "-c",
                   "import time; print('argcheck ok', flush=True); time.sleep(0.2)"]
    valid_cmd = [sys.executable, here,
                 "--wall-seconds", "5", "--rss-mib", "512",
                 "--output-bytes", "262144", "--poll-ms", "250",
                 "--record", valid_path, "--", *valid_child]
    outcome = _run_bounded_subprocess(valid_cmd,
                                      ARGCHECK_SUBPROCESS_TIMEOUT_S)
    valid_exit = outcome["exit"]
    valid_timed_out = outcome["timed_out"]
    valid_record = outcome.get("inner_result")
    valid_ok = outcome["containment_ok"] and valid_exit == EXIT_OK and not valid_timed_out
    if not isinstance(valid_record, dict):
        valid_record = None
        valid_ok = False
        outcome["output"] += "\nrecord file missing or invalid"
    if valid_record is not None:
        limits = valid_record.get("limits", {})
        cleanup = valid_record.get("cleanup", {})
        checks = {
            "wall_is_5": limits.get("wall_seconds") == 5.0,
            "rss_is_512": limits.get("rss_mib") == 512.0,
            "reason_ok": valid_record.get("reason") == "ok",
            "cleanup_ok": cleanup.get("ok") is True,
            "verified_empty": cleanup.get("verified") == [],
            "output_seen": "argcheck ok" in str(
                valid_record.get("output", {}).get("head", "")),
            "poll_recorded": limits.get("poll_ms") == 250,
            "output_limit_recorded": limits.get("output_bytes") == 262144,
        }
        valid_ok = valid_ok and all(checks.values())
    else:
        checks = {}
    report = _report_text(
        f"ARGCHECK valid_run pre-report-verdict={'PASS' if valid_ok else 'FAIL'} exit={valid_exit}\n",
        sys.stderr, outcome.get("evidence_deadline_ns"))
    valid_ok = valid_ok and report["complete"]

    final_pids, final_error = _ps_find(
        ARGCHECK_MARKER, end_ns=outcome.get("evidence_deadline_ns"))
    final_cleanup: dict = {}
    if final_pids:
        final_cleanup = {"not_attempted": "marker match confers no signal ownership"}
    marker_clear = (final_pids is not None and not final_pids) \
        and final_error is None
    summary = {
        "cases": cases,
        "environment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
        },
        "final_cleanup": final_cleanup,
        "marker": ARGCHECK_MARKER,
        "marker_absent_at_end": marker_clear,
        "mode": "argcheck",
        "passed": passed_all and valid_ok and marker_clear,
        "recorded_at_utc": utcnow(),
        "subprocess_timeout_s": ARGCHECK_SUBPROCESS_TIMEOUT_S,
        "supervisor": "run_bounded.py",
        "supervisor_sha256": self_sha256(),
        "valid_case": {
            "argv": valid_cmd,
            "checks": checks,
            "duration_s": outcome["duration_s"],
            "exit": valid_exit,
            "expected_exit": EXIT_OK,
            "passed": valid_ok,
            "record_path": valid_path,
            "timed_out": valid_timed_out,
            "output_tail": outcome["output"][-400:],
        },
    }
    summary["sink"] = write_record_once(
        record_path, summary, end_ns=outcome.get("evidence_deadline_ns"))
    if not summary["sink"]["primary_ok"] or summary["sink"]["late"]:
        summary["passed"] = False
    report = _report_text(json.dumps(summary, indent=2, sort_keys=True)+"\n",
                          sys.stdout, outcome.get("evidence_deadline_ns"))
    if not report["complete"] or REPORTING_ERRORS:
        summary["passed"] = False
    return 0 if summary["passed"] else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="run_bounded.py",
        description="Bounded supervisor for approved M01 child commands.")
    parser.add_argument("--wall-seconds", type=float, default=None)
    parser.add_argument("--rss-mib", type=float, default=None)
    parser.add_argument("--cpu-seconds", type=float, default=None)
    parser.add_argument("--output-bytes", type=int, default=None)
    parser.add_argument("--poll-ms", type=int, default=None)
    parser.add_argument("--keep-output", action="store_true")
    parser.add_argument("--record", default=None,
                        help="record file (normal/argcheck/diagnose-one) "
                             "or directory (--diagnose)")
    parser.add_argument("--diagnose", default=None,
                        help="comma-separated case list or 'all'")
    parser.add_argument("--diagnose-one", default=None, dest="diagnose_one",
                        help="run a single case in this process (inner "
                             "containment mode started by --diagnose)")
    parser.add_argument("--argcheck", action="store_true")
    parser.add_argument("--bootstrap", action="store_true",
                        help="gate bootstrap: register, wait for release, "
                             "then exec the workload (internal launch gate)")
    return parser


def main(argv=None) -> int:
    raw = list(sys.argv[1:] if argv is None else argv)
    head, child = split_argv(raw)
    ns = build_parser().parse_args(head)
    if ns.argcheck:
        mode = "argcheck"
    elif ns.bootstrap:
        mode = "bootstrap"
    elif ns.diagnose_one is not None:
        mode = "diagnose-one"
    elif ns.diagnose is not None:
        mode = "diagnose"
    else:
        mode = "normal"
    # Validation always precedes dispatch (F02): no mode may bypass it.
    error = validate_options(ns, child, mode)
    if error:
        note(error)
        return EXIT_USAGE
    if mode == "bootstrap":
        return run_bootstrap(child)
    if mode == "diagnose-one":
        return run_diagnose_one(ns.diagnose_one.strip(), ns.record)
    if mode == "diagnose":
        spec = ns.diagnose.strip()
        if spec.lower() == "all":
            names = list(DIAGNOSE_CASES)
        else:
            names = [part.strip() for part in spec.split(",") if part.strip()]
        if not names:
            note("no diagnose cases requested")
            return EXIT_USAGE
        known = set(DIAGNOSE_CASES) | {GODOT_PARSE_CASE} | set(ENGINE_CASES) | set(PREVIEW_CASES)
        unknown = [n for n in names if n not in known]
        if unknown:
            note(f"unknown diagnose case(s): {', '.join(unknown)}")
            note("known cases: " + ", ".join(
                (*DIAGNOSE_CASES, GODOT_PARSE_CASE, *sorted(ENGINE_CASES), *sorted(PREVIEW_CASES))))
            return EXIT_USAGE
        return run_diagnose(names, ns.record)
    if mode == "argcheck":
        return run_argcheck(ns.record)
    install_signal_handlers()
    result = supervise(child, {
        "wall_seconds": ns.wall_seconds,
        "rss_mib": ns.rss_mib,
        "cpu_seconds": ns.cpu_seconds,
        "output_bytes": (DEFAULT_OUTPUT_BYTES if ns.output_bytes is None
                         else ns.output_bytes),
        "poll_ms": DEFAULT_POLL_MS if ns.poll_ms is None else ns.poll_ms,
        "keep_output": ns.keep_output,
    })
    stage("record")
    result["stages"] = list(STAGE_LOG)
    preview_route = os.environ.get("RB_GATE_CASE") in PREVIEW_CASES
    report_failed = False
    supervisor_exit = int(result.get("exit_code", EXIT_OK))
    if ns.record:
        result["sink"] = write_record_once(
            ns.record, result, end_ns=result.get("evidence_deadline_ns"))
        if not result["sink"]["primary_ok"] or result["sink"]["late"]:
            result["exit_code"] = result["exit_code"] or EXIT_INTERNAL
            report_failed = True
    try:
        emit_child_output(result, True)
        text = result_line(result)
        if ns.record:
            text += "\nevidence sink: " + json.dumps(result["sink"], sort_keys=True)
        result["final_report"] = _report_text(
            text+"\n", sys.stderr, result.get("evidence_deadline_ns"))
        if (result["final_report"] or {}).get("complete") is not True:
            report_failed = True
        if result.get("timings_ns") and result["child"]["launched"]:
            result["timings_ns"]["collection_end_ns"] = result["final_report"]["completed_ns"]
            result["timings_ns"]["post_stop_end_ns"] = result["final_report"]["completed_ns"]
    except Exception as exc:
        REPORTING_ERRORS.append(f"result output failed: {exc}")
        report_failed = True
    if REPORTING_ERRORS:
        result["exit_code"] = result["exit_code"] or EXIT_INTERNAL
        report_failed = True
    if preview_route and report_failed:
        # F3: EVERY preview reporting failure rejects acceptance, including one recorded
        # after an operating (wall/cpu/rss/cancel) stop. Reuse EXIT_INTERNAL, flag the
        # failure, and preserve the original stop reason and exit code.
        result["reporting_failure"] = True
        result["reporting_failure_prior_exit"] = supervisor_exit
        result["reporting_failure_prior_reason"] = result.get("reason")
        result["reporting_errors"] = list(REPORTING_ERRORS)
        result["exit_code"] = EXIT_INTERNAL
    return int(result["exit_code"])


if __name__ == "__main__":
    sys.exit(main())
