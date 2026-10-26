"""
MyClaude per-API-key concurrency guard for LiteLLM — v2.2 (NO PAYLOAD MUTATION).

WHY THIS EXISTS
  NVIDIA NIM hard-caps a worker at 16 in-flight requests
  ("ResourceExhausted: Worker local request limit reached (16/16)").
  That is a CONCURRENCY wall, not an RPM wall. LiteLLM's own
  max_parallel_requests REJECTS past the cap; it does not queue.
  This guard QUEUES (awaits) at 14 per bucket, leaving headroom.

THE CALLBACK SHAPE — three revisions, three distinct failures, now settled
-----------------------------------------------------------------------------
  v1 / v1.1  callbacks: ["concurrency_guard.async_pre_call_hook", ...]
      The loader accepted the bare FUNCTIONS, then ProxyLogging performed an
      UNGUARDED `callback.async_post_call_success_hook(...)` on the
      NON-STREAMING path. A function has no such attribute:
          'function' object has no attribute 'async_post_call_success_hook'
      -> HTTP 400 invalid_request_error on /v1/chat/completions
      -> HTTP 500 code:500                on /v1/messages
      Streaming survived (that path never invokes the hook), which is why
      diag_paths showed 8/8 stream cells OK and 8/8 non-stream cells dead.

  v2.0       callbacks: ["concurrency_guard.ConcurrencyGuard"]
      This LiteLLM build's loader (proxy/common_utils/callback_utils.py,
      _loaded_callback_or_raise -> _raise_callback_load_error) is STRICTER:
          ValueError: ... resolved to the class ..., which is neither a
          CustomLogger instance nor a callable, so the proxy would never run it.
      Boot died status=3 and systemd crash-looped to restart counter 20.

  v2.1/v2.2  callbacks: ["concurrency_guard.proxy_handler_instance"]
      A module-level INSTANCE of a CustomLogger subclass is the ONLY shape that
      satisfies both constraints at once: it is an instance (loader happy) and
      it owns the full hook surface (ProxyLogging happy). This is exactly the
      form the loader's own error message prescribes.

WHAT v2.2 CHANGES (three defects, all found by live traffic, none by reading)
-----------------------------------------------------------------------------
  BUG C — BLOCKER, introduced by v2.0. async_pre_call_hook assigned the
    correlation id onto the outbound payload:  data["_mc_cid"] = cid
    On the openai-compatible (nvidia_nim) path LiteLLM forwards unknown
    TOP-LEVEL keys straight into the JSON body, and NVIDIA's server-side
    validator rejected every request:
        BadRequestError: Nvidia_nimException - Validation:
        Unsupported parameter(s): `_mc_cid`
    Observed: 182 guard failures + 16/16 HTTP 400 cells in doctor section 6.
    drop_params: true does NOT protect against this -- proven, because every
    scene sets it and every request still 400'd.
    REMOVAL IS PROVABLY SAFE, not merely plausible: all 40 successful releases
    in guard.log carried UUID cids, _cid_from tries litellm_call_id BEFORE
    _mc_cid, and our own fallback renders as "task<hex>". So litellm_call_id
    alone already correlates acquire->release on every release path that fired.
    Worst case if a future LiteLLM omits litellm_call_id: a slot is held until
    the sweeper's MAX_HOLD_SECS reclaim -- bounded, never a deadlock, and
    doctor section 7 counts it.

  BUG D — bucket granularity, and a correction to an earlier claim. Every live
    bucket line is alias:<name>, never key<N>. Two causes, only one of which is
    a bug:
      (i)  BUG (fixed here): _RAW2ENV was built from os.getenv at import time.
           The systemd unit's Environment= carries NO NVIDIA_API_KEY_* (verified
           via `systemctl show -p Environment`), and LiteLLM populates them
           later, so the map came out empty in the proxy process. _build_raw_map()
           below now reads .env from disk as well, with os.environ taking
           precedence on conflict (the process environment is what LiteLLM will
           actually use for this request).
      (ii) ARCHITECTURE (not fixable here, and previously mis-described): under
           the PROXY path the upstream NVIDIA key is chosen by the ROUTER *after*
           async_pre_call_hook runs, so `data` at pre_call contains neither the
           'os.environ/NVIDIA_API_KEY_n' placeholder nor an 'nvapi-...' token.
           All three key-resolution attempts miss by design. Alias bucketing is
           therefore the DESIGNED OUTCOME under the proxy path, not a
           degradation. A local unit test that hand-builds litellm_params will
           show key<N> and MUST NOT be read as proof about the proxy path.
    Consequence, stated plainly so nobody over-trusts this file: per-ALIAS caps
    do not bound a single KEY, because one key is shared by ~12 deployments
    across scenes 1-6 (6 aliases x 14 = 84 legal in-flight on one key). The
    per-key wall is enforced by max_parallel_requests: 7 x 2 deployments/key in
    the scene YAML, and the 6-key aggregate by general_settings.
    global_max_parallel_requests: 84 (= 6 x 14) -- which this build ACCEPTS
    (it was not among the keys flagged by proxy_server.py:5738). The guard is
    one of three layers, and it is the only one that QUEUES instead of rejecting.
    Empirical status: ResourceExhausted = 0 and sweeper-reclaims = 0 across 319
    log lines. Sound machinery, layered mitigation.

  DEDUPE — v2.1 contained `proxy_handler_instance = ConcurrencyGuard()` TWICE
    (once after the class, once appended at end of file). The name bound to the
    second instance and the first was garbage. Functionally survivable because
    state is module-level, but it made hook_provenance()/status() ambiguous.
    Exactly one construction now.

WHY THERE IS NO __getattr__ NET (kept from v2.1, and it is load-bearing reasoning)
  The net synthesised no-ops for unknown async_*_hook/async_*_event names. With
  a bare function (v1) that was necessary. With a CustomLogger INSTANCE it is
  pure liability:
    1. It makes hasattr() lie. build_config.sh assertion 6 and doctor section 3
       both probe hasattr(obj, hook). With the net every such probe returns True
       -- including for a hook we typo'd -- so MISS=none becomes a tautology and
       the tripwire cannot fire. A guard rail that cannot fail is decoration.
    2. It can MASK A LEAK. Misspell async_post_call_streaming_iterator_hook and
       the net absorbs the call as a no-op; the stream-complete release never
       fires; every streamed request holds its slot until the sweeper reclaims
       it at MAX_HOLD_SECS (1200 s). That converts a typo into a 20-minute stall.
  Hook presence is therefore verified by walking class __dict__s (see
  hook_provenance), which bypasses __getattr__ entirely.

CORRECTNESS RULES ENFORCED HERE
  1. Acquire in async_pre_call_hook (before the byte leaves the box).
  2. Release at the truthful completion point, layered so that ANY ONE of these
     firing is sufficient and ALL of them firing is harmless:
       a. async_post_call_streaming_iterator_hook  (stream fully drained)
       b. async_log_success_event / async_log_failure_event (logging emitter)
       c. async_post_call_failure_hook (proxy-level exception that bypasses
          the emitter -- the v1.x leak path)
       d. the sweeper (absolute backstop)
     _release() pops from _held, so callers 2..n are no-ops. Never release in a
     hook that fires at stream-OPEN.
  3. Correlate acquire->release by litellm_call_id ONLY. Never by asyncio task
     identity (LiteLLM runs logging callbacks in a different task), and never by
     writing into the outbound payload (BUG C).
  4. Self-heal: the sweeper force-releases any slot held longer than
     MAX_HOLD_SECS. A missed release degrades to a bounded stall, never deadlock.
  5. Never crash the proxy: every hook is wrapped; a guard bug cannot take down
     serving.
  6. State is PROCESS-LOCAL. Exactly ONE LiteLLM process may own this config, on
     a single worker, else the effective cap is MAX_INFLIGHT x N and NVIDIA's
     16-wall returns. myclaude.sh stop) sweeps strays; doctor section 4 asserts
     singleton-ness.
  7. Register EXACTLY ONE callback. Two guard callbacks => async_pre_call_hook
     runs twice per request => two acquisitions => effective cap 7/key.
     build_config.sh assertion 6 enforces the count.
  8. THE OUTBOUND PAYLOAD IS NEVER MUTATED. See BUG C. This is now an asserted
     invariant, checked by the local contract test, not just a convention.

Callback registration MUST be the module-level instance (config_base.yaml):
  concurrency_guard.proxy_handler_instance
"""
import asyncio
import logging
import os
import re
import sys
import time
from typing import Any, AsyncIterator, Dict, Optional, Tuple

# ---- tunables (override via .env / systemd Environment=) -------------------
MAX_INFLIGHT    = int(os.getenv("MYCLAUDE_MAX_INFLIGHT", "14"))
ACQUIRE_TIMEOUT = float(os.getenv("MYCLAUDE_ACQUIRE_TIMEOUT", "120"))
# Must exceed the longest legitimate request (vision timeout is 900s).
MAX_HOLD_SECS   = float(os.getenv("MYCLAUDE_MAX_HOLD", "1200"))
SWEEP_EVERY     = float(os.getenv("MYCLAUDE_SWEEP_EVERY", "30"))

_HERE = os.path.dirname(os.path.abspath(__file__))
GUARD_LOG = os.getenv("MYCLAUDE_GUARD_LOG", os.path.join(_HERE, "guard.log"))

# ---- logging: self-announcing (contract preserved from v1.1/v2.0/v2.1) -----
# myclaude.sh greps guard.log for "guard: module loaded"; doctor section 3
# asserts len(logger.handlers) == 2. Both contracts are load-bearing.
logger = logging.getLogger("myclaude.concurrency_guard")
if not logger.handlers:
    logger.setLevel(logging.INFO)
    logger.propagate = False          # LiteLLM owns root logging; do not inherit
    _fmt = logging.Formatter("[guard] %(asctime)s %(levelname)s %(message)s", "%H:%M:%S")
    for _h in (logging.StreamHandler(sys.stderr),                    # -> journald
               logging.FileHandler(GUARD_LOG, encoding="utf-8")):    # -> ~/myclaude/guard.log
        _h.setFormatter(_fmt)
        logger.addHandler(_h)

# ---- base class ------------------------------------------------------------
# Subclassing CustomLogger is what gives the INSTANCE its full hook surface.
# The shim keeps the module importable where litellm is absent (build-time
# validation, unit tests) -- but a shim-derived instance WILL BE REJECTED by the
# real proxy loader, so HAS_CUSTOM_LOGGER is asserted at build time and alarmed
# at import time.
try:
    from litellm.integrations.custom_logger import CustomLogger as _Base
    HAS_CUSTOM_LOGGER = True
except Exception:                     # pragma: no cover - degraded import path
    class _Base:                      # noqa: D101
        def __init__(self, *a, **kw): pass
    HAS_CUSTOM_LOGGER = False

# ---- state (module-level: shared by every instance in THIS process) --------
_sems: Dict[str, asyncio.Semaphore] = {}
_held: Dict[str, Tuple[str, float]] = {}      # cid -> (bucket, acquired_at)
_cid_by_task: Dict[int, str] = {}             # secondary correlation hint
_lock = asyncio.Lock()                        # 3.10+: binds lazily to running loop
_sweeper_running = False
_logged_buckets: Dict[str, str] = {}          # bucket -> resolution method

_ENV_NAMES = [f"NVIDIA_API_KEY_{i}" for i in range(1, 9)]


def _build_raw_map() -> Dict[str, str]:
    """raw nvapi value -> env var name, from BOTH os.environ AND .env on disk.

    The file fallback is a correctness fix, not belt-and-braces (BUG D(i)): in
    the systemd process this module is imported before LiteLLM's own dotenv load
    populates os.environ, and the unit's Environment= carries no NVIDIA_API_KEY_*,
    so a pure-os.getenv map came out EMPTY.

    os.environ wins on conflict (setdefault from the file), because the process
    environment is what LiteLLM will actually use for this request.

    NOTE (BUG D(ii)): even a perfect map does not produce key<N> buckets under
    the PROXY path, because the router selects the upstream key AFTER
    async_pre_call_hook. This map serves the direct/acompletion path, tests, and
    any future hook that does see the key.
    """
    m: Dict[str, str] = {}
    for n in _ENV_NAMES:
        v = os.getenv(n)
        if v:
            m[v.strip().strip('"').strip("'")] = n
    try:
        raw = open(os.path.join(_HERE, ".env"), "rb").read().decode("utf-8-sig", "replace")
        raw = raw.replace("\r\n", "\n").replace("\r", "\n")
        for line in raw.splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            if k in _ENV_NAMES and v:
                m.setdefault(v, k)
    except OSError:
        pass
    return m


_RAW2ENV: Dict[str, str] = _build_raw_map()

logger.info(f"guard: module loaded cap={MAX_INFLIGHT} acquire_timeout={ACQUIRE_TIMEOUT:.0f}s "
            f"max_hold={MAX_HOLD_SECS:.0f}s base={'CustomLogger' if HAS_CUSTOM_LOGGER else 'shim'} "
            f"rawmap={len(_RAW2ENV)} log={GUARD_LOG}")
if not HAS_CUSTOM_LOGGER:
    # Loud, because this exact condition produced a boot-time ValueError loop:
    # an instance of the shim base is NOT a CustomLogger instance, so the proxy's
    # loader will refuse concurrency_guard.proxy_handler_instance and the unit
    # will crash-loop.
    logger.error("guard: SHIM BASE ACTIVE -- litellm.integrations.custom_logger."
                 "CustomLogger is not importable in THIS interpreter. A proxy "
                 "started with this interpreter will reject "
                 "concurrency_guard.proxy_handler_instance with 'neither a "
                 "CustomLogger instance nor a callable'. Ensure the unit runs the "
                 "venv interpreter (venv/bin/litellm), not system python.")


# ===========================================================================
# helpers
# ===========================================================================

def _resolve_bucket(data: Dict[str, Any]) -> Tuple[str, str]:
    """Identify which bucket this call belongs to.

    Returns (bucket_id, resolution_method). Attempts, in order:
      1. litellm_params.api_key as 'os.environ/NVIDIA_API_KEY_3' (pre-resolution)
      2. litellm_params.api_key / data.api_key as raw 'nvapi-...' (post-resolution)
      3. deep scan of the payload repr for any nvapi- token
      4. FALLBACK: bucket by model alias.

    READ THIS BEFORE "FIXING" THE FALLBACK (BUG D(ii)): under the proxy path,
    attempts 1-3 normally ALL miss, because the router picks the upstream NVIDIA
    key after async_pre_call_hook runs. alias:<name> is therefore the EXPECTED
    outcome in production, not a misconfiguration, and logging it as a WARNING
    on every bucket was misleading. The per-key 16-worker wall is enforced
    elsewhere: max_parallel_requests: 7 x 2 deployments/key (scene YAML) bounds a
    single key, and general_settings.global_max_parallel_requests: 84 bounds the
    6-key aggregate. This guard is the layer that QUEUES instead of rejecting.
    """
    lp = data.get("litellm_params")
    lp = lp if isinstance(lp, dict) else {}

    candidates = []
    for v in (lp.get("api_key"), data.get("api_key")):
        if v:
            candidates.append(str(v))
    try:
        candidates.extend(re.findall(r"nvapi-[A-Za-z0-9_\-]{12,}", repr(data)))
    except Exception:
        pass

    for c in candidates:
        m = re.search(r"NVIDIA_API_KEY_(\d+)", c)
        if m:
            return f"key{m.group(1)}", "env-name"
        if c in _RAW2ENV:
            return f"key{_RAW2ENV[c].rsplit('_', 1)[-1]}", "raw-map"

    alias = str(lp.get("model") or data.get("model") or "unknown")
    return f"alias:{alias}", "alias-fallback"


async def _get_sem(bucket: str) -> asyncio.Semaphore:
    async with _lock:
        sem = _sems.get(bucket)
        if sem is None:
            sem = asyncio.Semaphore(MAX_INFLIGHT)
            _sems[bucket] = sem
            logger.info(f"guard: new bucket={bucket} cap={MAX_INFLIGHT}")
        return sem


def _ensure_sweeper() -> None:
    """Lazy-start the leak-recovery sweeper inside the running loop."""
    global _sweeper_running
    if _sweeper_running:
        return
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return                       # no loop yet; retry on the next pre_call
    _sweeper_running = True
    asyncio.create_task(_sweeper())
    logger.info(f"guard: sweeper started (every {SWEEP_EVERY:.0f}s, "
                f"force-release after {MAX_HOLD_SECS:.0f}s)")


async def _sweeper() -> None:
    """Force-release slots whose owner never called back. Anti-deadlock
    guarantee: worst case a slot is stuck MAX_HOLD_SECS, never forever."""
    while True:
        try:
            await asyncio.sleep(SWEEP_EVERY)
            now = time.time()
            stale = [cid for cid, (_b, ts) in _held.items() if now - ts > MAX_HOLD_SECS]
            for cid in stale:
                bucket, ts = _held[cid]
                logger.error(f"guard: SWEeper reclaiming leaked slot "
                             f"cid={cid} bucket={bucket} held={now - ts:.0f}s")
                _release(cid)
        except asyncio.CancelledError:
            return
        except Exception as e:
            logger.error(f"guard: sweeper error (continuing): {e}")


def _release(cid: Optional[str]) -> None:
    """Idempotent release. Safe from async AND sync contexts, and safe to call
    repeatedly for the same cid (pop-once semantics). This idempotence is what
    makes the 4-layer release strategy (iterator / emitter / post-failure /
    sweeper) composable instead of double-decrementing."""
    if not cid:
        return
    ent = _held.pop(cid, None)
    if ent is None:
        return                       # already released / never acquired: no-op
    bucket = ent[0]
    sem = _sems.get(bucket)
    if sem is not None:
        try:
            sem.release()
        except (ValueError, RuntimeError):
            pass                     # over-release, or wrong loop: ignore


def _cid_from(obj: Any) -> Optional[str]:
    """Extract the correlation id from whatever LiteLLM handed us.

    litellm_call_id is the ONLY supported source going forward (BUG C removed
    the payload stash). The _mc_cid read is retained solely so that entries
    acquired by an older load still release cleanly during a rolling restart;
    nothing in this module writes that key any more.
    """
    if not isinstance(obj, dict):
        return None
    cid = obj.get("litellm_call_id") or obj.get("_mc_cid")
    if cid:
        return str(cid)
    task = asyncio.current_task()
    if task is not None:
        return _cid_by_task.get(id(task))
    return None


def _drift(data: Any, cache: Any, where: str) -> None:
    """Convert signature drift from a SILENT no-op (v1.x bug B) into a loud
    error that doctor section 7 counts. v1.x bound `data` to the CACHE object,
    so isinstance(data, dict) was False on every call and the guard acquired
    nothing while appearing healthy. Never let that go quiet again."""
    logger.error(
        f"guard: {where} got non-dict data (type={type(data).__name__}); "
        f"cache type={type(cache).__name__}. LiteLLM signature drift -> guard "
        f"INERT for this call. Do NOT ignore: the per-bucket cap is not applied."
    )


# ===========================================================================
# LiteLLM callback surface — every hook defined EXPLICITLY. No __getattr__ net:
# it would defeat hasattr-based verification and could mask a release typo.
# ===========================================================================

class ConcurrencyGuard(_Base):
    """Per-bucket queueing semaphore. Instantiated EXACTLY ONCE at module scope."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        try:
            super().__init__(*args, **kwargs)
        except TypeError:
            pass                     # CustomLogger __init__ signature varies by version
        self.name = "myclaude_concurrency_guard"

    # ------------------------------------------------------------------ 1.
    async def async_pre_call_hook(self, user_api_key_dict=None, cache=None,
                                  data=None, call_type=None) -> Any:
        """Acquire a slot BEFORE the request leaves for NVIDIA. Queues (awaits)
        when the bucket is full instead of rejecting.

        Canonical dispatch is POSITIONAL (user_api_key_dict, cache, data,
        call_type). Parameter NAMES and ORDER must stay exactly as below: some
        LiteLLM versions invoke by keyword, others positionally, and v1.x's
        4-arg-but-wrong-order declaration is what made the guard inert.

        INVARIANT (BUG C): this hook MUST NOT write into `data`. It returns the
        same object it received, with an unchanged key set.
        """
        try:
            if not isinstance(data, dict):
                _drift(data, cache, "async_pre_call_hook")
                return data
            _ensure_sweeper()

            bucket, method = _resolve_bucket(data)
            if _logged_buckets.get(bucket) != method:
                _logged_buckets[bucket] = method
                if method == "alias-fallback":
                    # INFO, not WARNING: this is the expected production outcome
                    # (see _resolve_bucket docstring, BUG D(ii)). Warning here
                    # previously implied a misconfiguration that does not exist.
                    logger.info(
                        f"guard: bucket={bucket} via alias-fallback (expected under "
                        f"the proxy path; per-key wall is enforced by "
                        f"max_parallel_requests 7 x 2/key + global cap 84)")
                else:
                    logger.info(f"guard: bucket={bucket} resolved via {method}")

            sem = await _get_sem(bucket)
            try:
                await asyncio.wait_for(sem.acquire(), timeout=ACQUIRE_TIMEOUT)
            except asyncio.TimeoutError:
                # Queue waited too long -> raise so LiteLLM's fallback/rotation
                # moves this call to a different key/alias instead of piling up.
                logger.warning(f"guard: queue timeout bucket={bucket} "
                               f"({ACQUIRE_TIMEOUT:.0f}s) -> raising for rotation")
                raise

            cid = str(data.get("litellm_call_id") or f"task{id(asyncio.current_task()):x}")
            _held[cid] = (bucket, time.time())
            # v2.2: NO data["_mc_cid"] = cid  -- see BUG C. The outbound payload
            # is never mutated; correlation rides on litellm_call_id alone.
            task = asyncio.current_task()
            if task is not None:
                _cid_by_task[id(task)] = cid
        except asyncio.TimeoutError:
            raise                                    # intentional: trigger rotation
        except Exception as e:
            logger.error(f"guard: pre_call error (non-fatal, request proceeds): {e}")
        return data

    # ------------------------------------------------------------------ 2.
    async def async_post_call_success_hook(self, data=None, user_api_key_dict=None,
                                           response=None) -> Any:
        """The hook whose ABSENCE caused Defect A. Present as a pure pass-through:
        it must NOT release the slot, because on the Anthropic translator this
        fires while the body is assembled but not yet flushed to the client.
        Release belongs to the iterator / emitter / post-failure layers.
        """
        return response

    # ------------------------------------------------------------------ 3.
    async def async_post_call_failure_hook(self, request_data=None,
                                           original_exception=None,
                                           user_api_key_dict=None,
                                           response=None, **kwargs: Any) -> None:
        """Proxy-level failure that BYPASSES the logging emitter. This was the
        v1.x leak path: a 400/500 raised here never reached
        async_log_failure_event, so the slot stayed held until the sweeper
        reclaimed it (up to MAX_HOLD_SECS). Closed explicitly -- and proven
        working in production: 40 releases with UUID cids came through here.
        """
        try:
            cid = _cid_from(request_data)
            if cid:
                _release(cid)
                logger.warning(f"guard: post_call_failure released cid={cid} "
                               f"exc={type(original_exception).__name__}: "
                               f"{str(original_exception)[:140]}")
        except Exception as e:
            logger.error(f"guard: post_call_failure error: {e}")

    # ------------------------------------------------------------------ 4.
    async def async_post_call_streaming_iterator_hook(self, user_api_key_dict=None,
                                                      response=None,
                                                      request_data=None,
                                                      **kwargs: Any) -> AsyncIterator[Any]:
        """The truthful stream-complete release point for Claude Code, which
        ALWAYS streams. Async-generator by contract: wrap the upstream iterator,
        release exactly once in `finally`. Idempotent with the other layers.
        """
        cid = _cid_from(request_data) if isinstance(request_data, dict) else None
        if not cid and isinstance(response, dict):
            cid = _cid_from(response)
        try:
            if hasattr(response, "__aiter__"):
                async for chunk in response:
                    yield chunk
            elif hasattr(response, "__iter__"):
                for chunk in response:
                    yield chunk
            else:
                yield response
        finally:
            if cid:
                _release(cid)

    # ------------------------------------------------------------------ 5.
    async def async_log_success_event(self, kwargs=None, response_obj=None,
                                      start_time=None, end_time=None) -> None:
        """Fires after the logging emitter sees the completed call."""
        try:
            cid = _cid_from(kwargs)
            _release(cid)
            dt = (end_time - start_time).total_seconds() if (start_time and end_time) else 0.0
            if dt > 60:
                logger.info(f"guard: slow OK latency={dt:.1f}s cid={cid}")
        except Exception as e:
            logger.error(f"guard: success-release error: {e}")

    # ------------------------------------------------------------------ 6.
    async def async_log_failure_event(self, kwargs=None, response_obj=None,
                                      start_time=None, end_time=None) -> None:
        """Fires on 4xx/5xx/exception. Releasing here is what stops a failed
        attempt from permanently eating a slot."""
        try:
            cid = _cid_from(kwargs)
            _release(cid)
            dt = (end_time - start_time).total_seconds() if (start_time and end_time) else 0.0
            code = getattr(response_obj, "status_code", None)
            body = getattr(response_obj, "body", response_obj)
            logger.warning(f"guard: failure code={code} latency={dt:.2f}s :: {str(body)[:160]}")
        except Exception as e:
            logger.error(f"guard: failure-release error: {e}")

    # ------------------------------------------------------------------ 7.
    # Sync variants: LiteLLM calls these on non-async code paths. _release() is
    # pure-Python (no await), so delegating is safe from either context.
    def log_success_event(self, kwargs=None, response_obj=None,
                          start_time=None, end_time=None) -> None:
        try:
            _release(_cid_from(kwargs))
        except Exception as e:
            logger.error(f"guard: sync success-release error: {e}")

    def log_failure_event(self, kwargs=None, response_obj=None,
                          start_time=None, end_time=None) -> None:
        try:
            _release(_cid_from(kwargs))
        except Exception as e:
            logger.error(f"guard: sync failure-release error: {e}")


# ===========================================================================
# THE SINGLETON — exactly ONE construction (v2.1 had two; see DEDUPE above).
# Constructed at import time: __init__ touches no event loop (semaphores are
# created lazily in _get_sem inside the running loop), so this is safe under
# systemd, under build-time validation, and under asyncio.run() in tests.
# This is the object config_base.yaml must name.
# ===========================================================================
proxy_handler_instance = ConcurrencyGuard()


# ===========================================================================
# Introspection (python shell, doctor, or a /debug route)
# ===========================================================================

#: Hooks the proxy will invoke on this object. Verified against class __dict__s
#: (never hasattr) so no synthesised attribute can fake a pass.
REQUIRED_HOOKS = (
    "async_pre_call_hook",
    "async_post_call_success_hook",
    "async_post_call_failure_hook",
    "async_post_call_streaming_iterator_hook",
    "async_log_success_event",
    "async_log_failure_event",
    "log_success_event",
    "log_failure_event",
)


def hook_provenance() -> Dict[str, str]:
    """Map each required hook to the class that actually defines it.

    Walks the MRO and inspects __dict__ directly. __getattr__ is never invoked
    by a __dict__ lookup, which is precisely why this replaces the hasattr test
    that v2.0's net would have defeated.
    """
    out: Dict[str, str] = {}
    for h in REQUIRED_HOOKS:
        owner = None
        for k in type(proxy_handler_instance).__mro__:
            if k is object:
                continue
            if h in k.__dict__:
                owner = k.__name__
                break
        out[h] = owner or "MISSING"
    return out


def status() -> Dict[str, Any]:
    now = time.time()
    return {
        "version": "2.2-no-payload-mutation",
        "base": "CustomLogger" if HAS_CUSTOM_LOGGER else "shim",
        "cap_per_bucket": MAX_INFLIGHT,
        "acquire_timeout_s": ACQUIRE_TIMEOUT,
        "max_hold_s": MAX_HOLD_SECS,
        "handlers": len(logger.handlers),
        "guard_log": GUARD_LOG,
        "raw_map_entries": len(_RAW2ENV),
        "instance": type(proxy_handler_instance).__name__,
        "hook_provenance": hook_provenance(),
        "buckets": {b: {"in_use": MAX_INFLIGHT - s._value, "free": s._value}
                    for b, s in _sems.items()},
        "held_slots": {cid: {"bucket": b, "age_s": round(now - ts, 1)}
                       for cid, (b, ts) in _held.items()},
        "resolution_methods": dict(_logged_buckets),
    }
