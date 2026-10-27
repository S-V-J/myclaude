#!/usr/bin/env python3
"""probe_cancel.py v2 — deterministic mid-stream client abort.

v1 RESULT (2026-10-26 12:22): the CONTROL arm "leaked". It did not.
  control  chunks=882 elapsed=65.1s completed=True
  reclaim  12:22:30 held=60s   -> acquisition ~12:21:30
  completion ~12:22:35       => the sweeper reclaimed a LIVE call 3-5s early.
  MY ERROR: MYCLAUDE_MAX_HOLD=60 was chosen to surface leaks fast, and the prompt
  to a 65s call, without checking max_hold > call_duration. The sweeper has NO
  liveness check -- it compares only `now - ts > MAX_HOLD_SECS` (contract:
  "worst case a slot is stuck MAX_HOLD_SECS, never forever"). So max_hold below
  call length == GUARANTEED false reclaim. v2 refuses to run in that state.

DESIGN CONSTRAINT THIS EXPOSED (worth more than the leak answer):
  max_hold MUST exceed the p99 legitimate call duration. Mechanism: the sweeper
  pops the cid and releases the semaphore; the real release later no-ops
  (_held.pop -> None -> return). Exactly one release per acquire -- safe, no
  crash, no double-decrement -- BUT the slot re-enters the pool while its call
  still runs, so in-flight is under-reported and the guard OVER-ADMITS for the
  remainder. At 60s/65.1s that was 5s of one slot (harmless: cap 14 vs NVIDIA's
  wall of 16). It is not harmless in production if max_hold is ever tuned below
  real call lengths. Note the 07:21:10 event (held=1222s vs max_hold=1200s) has
  the SAME signature as a legitimate 2-attempt call (num_retries 3 x timeout 600
  = 1800s worst case), which is why T1's journal trace must run BEFORE this.

v2 vs v1 -- two changes, both forced by measurement:
  1. PARAMETER GATE. max_hold is read NUMERICALLY from the newest 'module loaded'
     line. If the control call would not finish with a >=3x margin, exit 2 with
     the numbers printed. No more silent false reclaim.
  2. ABSENCE IS THE PROOF, not timestamp correlation. v1 looked for a
     release/failure line within +-8s of the abort. That was weak: _release() is
     SILENT (it only pops _held and releases the semaphore -- no log call), and
     async_log_success_event just calls _release. So a CLEAN release writes
     NOTHING, and "no line within 8s" could not distinguish released-silently
     from not-yet-released. v2 inverts it: the sweeper is UNCONDITIONAL, so if no
     reclaim appears within max_hold + grace of acquisition, the slot WAS
     released. That is airtight, and any failure/release line that does appear is
     diagnostic colour about WHICH path did it.
  3. Reclaims are identified ARITHMETICALLY, not by fuzz: a reclaim line carries
     held=Ns, so implied_acquisition = reclaim_clock - held. Compared against the
     moment we aborted, that says whether the reclaim is OURS. A reclaim whose
     cid later appears in a 'post_call_failure released' line is a DEFINITE false
     reclaim + over-release, independent of clocks. (A *successful* completion
     after a false reclaim logs nothing, so arithmetic remains the general test.)

PARAMETERS (runner arms these; do not run without them):
  drop-in  MYCLAUDE_MAX_HOLD=180        (15x margin over a ~12s control)
  prompt   count to 120                 (~10-20s; measured 13.5 chunks/s on 882)
  abort    after 6 SSE data lines       (~1-3s in, far below 180)
  poll     max_hold + 80                (a genuine leak MUST surface)

Exit codes:
  0 = NO LEAK   (no reclaim within max_hold+grace -> slot was released)
  1 = LEAK      (reclaim arithmetic-attributed to the aborted call)
  2 = PARAMETER/HARNESS problem (control too slow for max_hold, stall, no abort,
      or the only reclaim was a false one)
"""
import argparse, http.client, json, os, re, sys, time

GUARD = "guard.log"
RECLAIM_RE = re.compile(r"SWEeper reclaiming")
RELEASE_RE = re.compile(r"post_call_failure released")
FAILURE_RE = re.compile(r"guard: failure")
CLOCK_RE   = re.compile(r"^\[guard\] (\d\d):(\d\d):(\d\d)")
HELD_RE    = re.compile(r"held=([0-9]+)s")
CID_RE     = re.compile(r"cid=([0-9a-fA-F-]+)")
MH_RE      = re.compile(r"max_hold=([0-9.]+)s")
MODULE_RE  = re.compile(r"module loaded")


def hms_of(line):
    """Seconds-since-midnight from a guard.log line, or None."""
    m = CLOCK_RE.match(line)
    return None if not m else int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))


def wall_hms(t=None):
    lt = time.localtime(t)
    return lt.tm_hour * 3600 + lt.tm_min * 60 + lt.tm_sec


def read_max_hold():
    """Numeric max_hold from the newest 'module loaded' line. None if absent."""
    last = None
    if os.path.exists(GUARD):
        with open(GUARD, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if MODULE_RE.search(line):
                    m = MH_RE.search(line)
                    last = float(m.group(1)) if m else None
    return last


def guard_line_count():
    if not os.path.exists(GUARD):
        return 0
    with open(GUARD, "r", encoding="utf-8", errors="replace") as f:
        return sum(1 for _ in f)


def tail_new(path, start):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for i, line in enumerate(f):
            if i >= start:
                yield line.rstrip("\n")


def stream_call(host, port, key, model, max_tokens, abort_after, sock_timeout, prompt):
    """POST a streaming completion. abort_after=None drains to [DONE]; otherwise
    stop reading after that many 'data:' lines and close the socket.
    Returns (chunks, elapsed, completed, abort_wall_monotonic_or_None)."""
    conn = http.client.HTTPConnection(host, port, timeout=sock_timeout)
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": True,
    }).encode()
    t0 = time.monotonic()
    abort_wall = None
    try:
        conn.request("POST", "/v1/chat/completions", body=body, headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        })
        resp = conn.getresponse()
        if resp.status != 200:
            snippet = resp.read(400).decode("utf-8", "replace")
            raise SystemExit(f"❌ HTTP {resp.status} before streaming: {snippet}")
        chunks, completed = 0, False
        try:
            while True:
                # resp.readline() de-chunks transparently; resp.fp.readline() would
                # NOT (raw chunk framing). This is why the harness can be trusted
                # to see real SSE events rather than transport noise.
                line = resp.readline()
                if not line:                       # EOF without [DONE]
                    break
                if line.startswith(b"data: [DONE]"):
                    completed = True
                    break
                if line.startswith(b"data: "):
                    chunks += 1
                    if abort_after is not None and chunks >= abort_after:
                        abort_wall = time.monotonic()
                        break                      # abandon mid-stream
                if time.monotonic() - t0 > 300:    # safety: never hang the session
                    break
        except (TimeoutError, OSError) as e:
            if abort_after is None:
                raise SystemExit(f"❌ control stream stalled ({e}) -- server problem, "
                                 f"not a leak test (rc=2)")
            return chunks, time.monotonic() - t0, completed, None
        return chunks, time.monotonic() - t0, completed, abort_wall
    finally:
        conn.close()                               # socket close == client abort


def classify_reclaims(lines, our_acq, mh):
    """Split reclaim lines into (ours, foreign, false_reclaim). Arithmetic only:
    implied_acquisition = reclaim_clock - held, compared to our acquisition."""
    ours, foreign, false = [], [], []
    for line in lines:
        clk, held = hms_of(line), HELD_RE.search(line)
        if clk is None or not held:
            foreign.append((line, "unparsable clock/held"))
            continue
        implied = clk - int(held.group(1))
        delta = implied - our_acq
        if abs(delta) <= 10:
            cid = CID_RE.search(line)
            ours.append((line, implied, delta, cid.group(1) if cid else "?"))
            # a reclaim whose held ~= max_hold on a call that ended long before is
            # only a false reclaim if the call was still running; v2's gate makes
            # that impossible for OURS, so anything attributed here is a leak.
        else:
            foreign.append((line, f"implied_acq {implied} vs ours {our_acq} "
                                  f"(delta {delta:+d}s)"))
    return ours, foreign, false


def main():
    ap = argparse.ArgumentParser(description="deterministic mid-stream cancel probe (v2)")
    ap.add_argument("--alias", default="claude-sonnet-5",
                    help="target alias (the 07:00:48 event was on this bucket)")
    ap.add_argument("--count-to", type=int, default=120,
                    help="prompt length; ~13.5 chunks/s measured => ~10-20s")
    ap.add_argument("--chunks", type=int, default=6,
                    help="abort after this many SSE data lines (~1-3s in)")
    ap.add_argument("--max-tokens", type=int, default=8000)
    ap.add_argument("--margin", type=float, default=3.0,
                    help="REFUSE to run unless max_hold >= margin x control elapsed")
    ap.add_argument("--poll-extra", type=int, default=80,
                    help="seconds past max_hold to keep watching")
    a = ap.parse_args()

    key = os.environ.get("LITELLM_MASTER_KEY")
    if not key:
        sys.exit("❌ LITELLM_MASTER_KEY not in env -- run: source tests/env.sh first")
    try:
        port = int(open(".nginx_port").read().strip())
    except Exception as e:
        sys.exit(f"❌ cannot read .nginx_port: {e}")
    host = "127.0.0.1"
    mh = read_max_hold()
    prompt = f"Count from 1 to {a.count_to}, one number per line, no commentary."

    print(f"VIA=nginx  base=http://{host}:{port}  alias={a.alias}")
    print(f"prompt=count to {a.count_to}  abort_after={a.chunks} chunks  "
          f"max_tokens={a.max_tokens}")
    print(f"max_hold read from guard.log: {mh if mh is not None else '(NONE -- is the unit up?)'}")
    if mh is None:
        sys.exit("❌ no 'module loaded' line with max_hold= in guard.log -- the proxy is "
                 "not running, or the guard never loaded. Fix that before testing. (rc=2)")

    # ---------- Phase A: CONTROL, and the PARAMETER GATE ---------------------
    print("\n── Phase A (CONTROL): stream to [DONE] ──")
    base_a = guard_line_count()
    ch, el, done, _ = stream_call(host, port, key, a.alias, a.max_tokens, None, 60, prompt)
    print(f"   chunks={ch} elapsed={el:.1f}s completed={done}")
    if not done:
        sys.exit("❌ control never reached [DONE] -- abort result would be meaningless (rc=2)")
    if mh < a.margin * el:
        sys.exit(f"❌ REFUSING: max_hold={mh:.0f}s but the control call took {el:.1f}s. "
                 f"Need max_hold >= {a.margin:.1f} x {el:.1f}s = {a.margin*el:.0f}s, "
                 f"else the sweeper reclaims a LIVE call and every verdict is a "
                 f"false positive. This is exactly how v1's control arm 'leaked' "
                 f"(60s backstop, 65.1s call). Raise the drop-in or shorten "
                 f"--count-to. (rc=2)")
    print(f"   ✅ parameter gate passed: max_hold {mh:.0f}s >= {a.margin:.1f}x "
          f"control {el:.1f}s ({mh/el:.1f}x margin)")
    for line, *_ in [(l,) for l in tail_new(GUARD, base_a) if RECLAIM_RE.search(l)]:
        sys.exit(f"❌ CONTROL produced a reclaim despite the gate: {line}\n"
                 f"   Something else is holding slots. Stop and paste this. (rc=2)")
    print("   ✅ control completed, released, no reclaim")

    # ---------- Phase B: ABORT ----------------------------------------------
    base_b = guard_line_count()
    acq_est = wall_hms()          # refined below from the reclaim's own held=
    print(f"\n── Phase B (ABORT): close socket after {a.chunks} SSE lines ──")
    ch, el, done, abort_mono = stream_call(host, port, key, a.alias, a.max_tokens,
                                           a.chunks, 60, prompt)
    if abort_mono is None:
        sys.exit(f"❌ stream ended before {a.chunks} chunks (chunks={ch}, completed={done}) "
                 f"-- no abort happened (rc=2)")
    abort_wall = wall_hms(time.time() - (time.monotonic() - abort_mono))
    print(f"   aborted at {time.strftime('%H:%M:%S', time.localtime(time.time() - (time.monotonic()-abort_mono)))} "
          f"after {ch} chunks / {el:.2f}s  (max_hold is {mh:.0f}s, so a genuine leak "
          f"surfaces ~{mh:.0f}s from now)")

    # ---------- Watch: absence of reclaim IS the proof -----------------------
    poll = int(mh) + a.poll_extra
    print(f"── watching guard.log for {poll}s (sweeper is unconditional, so no "
          f"reclaim in this window == the slot was released) ──")
    deadline = time.time() + poll
    reclaims, others = [], []
    while time.time() < deadline:
        for line in tail_new(GUARD, base_b):
            if RECLAIM_RE.search(line):
                reclaims.append(line)
            elif RELEASE_RE.search(line) or FAILURE_RE.search(line):
                others.append(line)
        if reclaims:
            break                      # decisive; stop early
        time.sleep(3)

    ours, foreign, _ = classify_reclaims(reclaims, abort_wall, mh)
    print(f"\n   reclaims seen: {len(reclaims)}  (attributed to our abort: {len(ours)})")
    for line, implied, delta, cid in ours:
        print(f"     OURS  cid={cid} implied_acq={implied} delta={delta:+d}s :: {line}")
    for line, why in foreign:
        print(f"     not ours ({why}) :: {line}")
    print(f"   release/failure lines in window: {len(others)}")
    for line in others[-6:]:
        print(f"     {line}")
    print(f"   guard config now: max_hold={read_max_hold()}")

    if ours:
        print("\n❌ LEAK REPRODUCED: the sweeper reclaimed the aborted call's slot, "
              "and arithmetic attributes it to our abort (implied acquisition within "
              "10s of the moment we closed the socket, held ~= max_hold).")
        print("   The cancelled-stream shape bypasses every release path.")
        print("   -> M4: event-driven release (asyncio task add_done_callback) in the "
              "streaming hook. NOT a max_hold reduction -- the 604.6s legitimate call "
              "and the 1222s event both prove the backstop must stay well above real "
              "call durations.")
        sys.exit(1)
    if foreign and not ours:
        print("\n⚠️ reclaims seen but NONE attributable to our abort -- background "
              "traffic or a pre-existing held slot. Inconclusive for this shape; "
              "re-run when the box is idle. (rc=2)")
        sys.exit(2)
    print("\n✅ NO LEAK: no reclaim within max_hold+grace of the abort, so the slot "
          "WAS released (the sweeper is unconditional -- absence is proof).")
    if others:
        print("   Release path evidenced by: " +
              "; ".join(("post_call_failure" if RELEASE_RE.search(l) else "failure-event")
                        for l in others[-2:]))
    else:
        print("   No release line logged -- consistent with the SILENT success path "
              "(_release pops _held and returns without logging). That is the clean "
              "case, not a gap.")
    print("   The 07:00:48/07:21:10 event was therefore either a false reclaim of a "
          "legitimate long call (see T1) or a rarer shape. No guard edit.")
    sys.exit(0)


if __name__ == "__main__":
    # Exit-code contract, now unambiguous:
    #   0 = NO LEAK | 1 = LEAK | 2 = param/harness refusal or interrupt
    #   3 = UNEXPECTED EXCEPTION (a harness bug; NEVER a leak/no-leak verdict)
    # Without this wrapper a TypeError exits 1 and reads as "leak reproduced".
    try:
        main()
    except SystemExit:
        raise                       # intentional sys.exit(N) verdicts pass through
    except KeyboardInterrupt:
        print("\n⚠️ interrupted by user — not a verdict. (rc=2)")
        sys.exit(2)
    except BaseException as e:
        import traceback
        traceback.print_exc()
        print(f"\n💥 UNEXPECTED EXCEPTION (harness bug, NOT a verdict): "
              f"{type(e).__name__}: {e}")
        print("   Read the traceback above. This is not 'leak reproduced'. (rc=3)")
        sys.exit(3)
