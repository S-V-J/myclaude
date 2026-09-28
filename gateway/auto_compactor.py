"""
Backend Auto-Compacting Mechanism for MyClaude Gateway.

Provides automated cleanup of:
- Stale rate limiter windows and locks
- Expired gateway error tracking
- Memory monitor historical data
- Fallback manager unused state
"""
import time
import threading
import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Callable, Any
from enum import Enum
import gc

logger = logging.getLogger(__name__)


class CompactionTarget(str, Enum):
    """Targets for compaction."""
    RATE_LIMITER_WINDOWS = "rate_limiter_windows"
    RATE_LIMITER_LOCKS = "rate_limiter_locks"
    GATEWAY_ERRORS = "gateway_errors"
    GATEWAY_REQUEST_HISTORY = "gateway_request_history"
    FALLBACK_MANAGER_STATE = "fallback_manager_state"
    RAM_MONITOR_HISTORY = "ram_monitor_history"
    PYTHON_GC = "python_gc"


@dataclass
class CompactionConfig:
    """Configuration for auto-compaction."""
    # Enable/disable auto-compaction
    enabled: bool = True

    # Compaction interval in seconds
    interval_seconds: float = 300.0  # 5 minutes

    # Max age for rate limiter windows (seconds) - windows older than this with no activity are removed
    max_window_age_seconds: float = 3600.0  # 1 hour

    # Max age for rate limiter locks (seconds) - locks for inactive keys are removed
    max_lock_age_seconds: float = 3600.0  # 1 hour

    # Max age for gateway errors (seconds) - error counts older than this are reset
    max_error_age_seconds: float = 3600.0  # 1 hour

    # Max error types to track (prevents unbounded growth)
    max_error_types: int = 100

    # Max request history entries to keep
    max_request_history: int = 10000

    # Force Python GC during compaction
    force_gc: bool = True

    # Compaction targets to run
    targets: List[CompactionTarget] = field(default_factory=lambda: [
        CompactionTarget.RATE_LIMITER_WINDOWS,
        CompactionTarget.RATE_LIMITER_LOCKS,
        CompactionTarget.GATEWAY_ERRORS,
        CompactionTarget.FALLBACK_MANAGER_STATE,
        CompactionTarget.PYTHON_GC,
    ])


@dataclass
class CompactionStats:
    """Statistics from a compaction run."""
    timestamp: float
    duration_ms: float
    targets_run: List[str]
    items_cleaned: Dict[str, int]
    errors: List[str]


class AutoCompactor:
    """
    Automated backend compaction for memory and resource management.

    Runs periodically in a background thread to clean up stale data structures
    that can accumulate over time and cause memory leaks or performance degradation.
    """

    def __init__(self, config: Optional[CompactionConfig] = None):
        self.config = config or CompactionConfig()
        self._lock = threading.RLock()
        self._compaction_thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._last_compaction_time: float = 0
        self._compaction_stats: List[CompactionStats] = []
        self._max_stats_history = 100

        # References to components to compact (set via register methods)
        self._rate_limiter = None
        self._gateway = None
        self._fallback_manager = None
        self._ram_monitor = None

        # Track last access time for rate limiter keys
        self._window_last_access: Dict[str, float] = {}
        self._lock_last_access: Dict[str, float] = {}

    def register_rate_limiter(self, rate_limiter) -> None:
        """Register a rate limiter for compaction."""
        with self._lock:
            self._rate_limiter = rate_limiter

    def register_gateway(self, gateway) -> None:
        """Register a gateway for compaction."""
        with self._lock:
            self._gateway = gateway

    def register_fallback_manager(self, fallback_manager) -> None:
        """Register a fallback manager for compaction."""
        with self._lock:
            self._fallback_manager = fallback_manager

    def register_ram_monitor(self, ram_monitor) -> None:
        """Register a RAM monitor for compaction."""
        with self._lock:
            self._ram_monitor = ram_monitor

    def start(self) -> None:
        """Start the background compaction thread."""
        if not self.config.enabled:
            logger.info("Auto-compaction is disabled")
            return

        with self._lock:
            if self._compaction_thread and self._compaction_thread.is_alive():
                logger.warning("Auto-compactor already running")
                return

            self._stop_event.clear()
            self._compaction_thread = threading.Thread(
                target=self._compaction_loop,
                name="auto-compactor",
                daemon=True
            )
            self._compaction_thread.start()
            logger.info("Auto-compactor started")

    def stop(self) -> None:
        """Stop the background compaction thread."""
        with self._lock:
            self._stop_event.set()
            if self._compaction_thread:
                self._compaction_thread.join(timeout=5.0)
                self._compaction_thread = None
            logger.info("Auto-compactor stopped")

    def _compaction_loop(self) -> None:
        """Main compaction loop."""
        while not self._stop_event.is_set():
            try:
                self.compact()
            except Exception as e:
                logger.error(f"Error in auto-compaction loop: {e}")

            # Wait for next interval or stop signal
            self._stop_event.wait(self.config.interval_seconds)

    def compact(self) -> CompactionStats:
        """
        Run a single compaction cycle.

        Returns:
            CompactionStats with results of the compaction
        """
        start_time = time.time()
        items_cleaned = {}
        errors = []
        targets_run = []

        with self._lock:
            for target in self.config.targets:
                try:
                    if target == CompactionTarget.RATE_LIMITER_WINDOWS:
                        cleaned = self._compact_rate_limiter_windows()
                        items_cleaned[target.value] = cleaned
                        targets_run.append(target.value)

                    elif target == CompactionTarget.RATE_LIMITER_LOCKS:
                        cleaned = self._compact_rate_limiter_locks()
                        items_cleaned[target.value] = cleaned
                        targets_run.append(target.value)

                    elif target == CompactionTarget.GATEWAY_ERRORS:
                        cleaned = self._compact_gateway_errors()
                        items_cleaned[target.value] = cleaned
                        targets_run.append(target.value)

                    elif target == CompactionTarget.FALLBACK_MANAGER_STATE:
                        cleaned = self._compact_fallback_manager()
                        items_cleaned[target.value] = cleaned
                        targets_run.append(target.value)

                    elif target == CompactionTarget.PYTHON_GC:
                        collected = self._run_gc()
                        items_cleaned[target.value] = collected
                        targets_run.append(target.value)

                except Exception as e:
                    error_msg = f"Error compacting {target.value}: {e}"
                    logger.error(error_msg)
                    errors.append(error_msg)

        duration_ms = (time.time() - start_time) * 1000

        stats = CompactionStats(
            timestamp=start_time,
            duration_ms=duration_ms,
            targets_run=targets_run,
            items_cleaned=items_cleaned,
            errors=errors
        )

        with self._lock:
            self._last_compaction_time = start_time
            self._compaction_stats.append(stats)
            # Keep only recent stats
            if len(self._compaction_stats) > self._max_stats_history:
                self._compaction_stats = self._compaction_stats[-self._max_stats_history:]

        logger.info(f"Compaction completed in {duration_ms:.1f}ms: {items_cleaned}")
        return stats

    def _compact_rate_limiter_windows(self) -> int:
        """Remove stale rate limiter windows."""
        if not self._rate_limiter:
            return 0

        cleaned = 0
        now = time.time()
        cutoff = now - self.config.max_window_age_seconds

        # For SlidingWindowRateLimiter
        if hasattr(self._rate_limiter, '_windows') and hasattr(self._rate_limiter, '_global_lock'):
            with self._rate_limiter._global_lock:
                keys_to_remove = []
                for key, window in self._rate_limiter._windows.items():
                    # Check if window is empty and old
                    if not window:
                        last_access = self._window_last_access.get(key, 0)
                        if last_access < cutoff:
                            keys_to_remove.append(key)
                    else:
                        # Update last access time if window has recent entries
                        if window[-1] > cutoff:
                            self._window_last_access[key] = now

                for key in keys_to_remove:
                    del self._rate_limiter._windows[key]
                    if key in self._window_last_access:
                        del self._window_last_access[key]
                    cleaned += 1

        return cleaned

    def _compact_rate_limiter_locks(self) -> int:
        """Remove stale rate limiter locks."""
        if not self._rate_limiter:
            return 0

        cleaned = 0
        now = time.time()
        cutoff = now - self.config.max_lock_age_seconds

        if hasattr(self._rate_limiter, '_locks') and hasattr(self._rate_limiter, '_global_lock'):
            with self._rate_limiter._global_lock:
                keys_to_remove = []
                for key, lock in self._rate_limiter._locks.items():
                    # Check if associated window is gone and lock is old
                    window_exists = key in getattr(self._rate_limiter, '_windows', {})
                    last_access = self._lock_last_access.get(key, 0)

                    if not window_exists and last_access < cutoff:
                        keys_to_remove.append(key)

                for key in keys_to_remove:
                    del self._rate_limiter._locks[key]
                    if key in self._lock_last_access:
                        del self._lock_last_access[key]
                    cleaned += 1

        return cleaned

    def _compact_gateway_errors(self) -> int:
        """Reset old gateway error counters."""
        if not self._gateway:
            return 0

        cleaned = 0
        now = time.time()

        with self._gateway._lock:
            # Reset error counts if too many types tracked
            if len(self._gateway._errors) > self.config.max_error_types:
                # Keep only the most recent error types (by count)
                sorted_errors = sorted(
                    self._gateway._errors.items(),
                    key=lambda x: x[1],
                    reverse=True
                )
                self._gateway._errors = dict(sorted_errors[:self.config.max_error_types])
                cleaned = len(sorted_errors) - self.config.max_error_types

            # Could add timestamp-based cleanup if errors had timestamps
            # For now, just limit the number of error types

        return cleaned

    def _compact_fallback_manager(self) -> int:
        """Clean up fallback manager state."""
        if not self._fallback_manager:
            return 0

        cleaned = 0
        now = time.time()

        with self._fallback_manager._lock:
            for scene_id, scene in self._fallback_manager.scenes.items():
                if hasattr(scene, 'rate_limiter') and scene.rate_limiter:
                    # Compact scene's rate limiter
                    if hasattr(scene.rate_limiter, '_windows'):
                        with getattr(scene.rate_limiter, '_global_lock', threading.Lock()):
                            keys_to_remove = []
                            for key, window in scene.rate_limiter._windows.items():
                                if not window:
                                    keys_to_remove.append(key)

                            for key in keys_to_remove:
                                del scene.rate_limiter._windows[key]
                                if key in scene.rate_limiter._locks:
                                    del scene.rate_limiter._locks[key]
                                cleaned += 1

        return cleaned

    def _run_gc(self) -> int:
        """Force Python garbage collection."""
        if self.config.force_gc:
            collected = gc.collect()
            logger.debug(f"GC collected {collected} objects")
            return collected
        return 0

    def get_status(self) -> Dict[str, Any]:
        """Get compactor status and statistics."""
        with self._lock:
            recent_stats = self._compaction_stats[-10:] if self._compaction_stats else []
            return {
                "enabled": self.config.enabled,
                "interval_seconds": self.config.interval_seconds,
                "last_compaction_time": self._last_compaction_time,
                "total_compactions": len(self._compaction_stats),
                "recent_compactions": [
                    {
                        "timestamp": s.timestamp,
                        "duration_ms": s.duration_ms,
                        "targets_run": s.targets_run,
                        "items_cleaned": s.items_cleaned,
                        "errors": s.errors
                    }
                    for s in recent_stats
                ],
                "config": {
                    "max_window_age_seconds": self.config.max_window_age_seconds,
                    "max_lock_age_seconds": self.config.max_lock_age_seconds,
                    "max_error_age_seconds": self.config.max_error_age_seconds,
                    "max_error_types": self.config.max_error_types,
                    "force_gc": self.config.force_gc,
                }
            }

    def force_compaction(self) -> CompactionStats:
        """Force an immediate compaction run."""
        return self.compact()


# Global instance for convenience
_auto_compactor: Optional[AutoCompactor] = None


def get_auto_compactor(config: Optional[CompactionConfig] = None) -> AutoCompactor:
    """Get or create the global auto-compactor instance."""
    global _auto_compactor
    if _auto_compactor is None:
        _auto_compactor = AutoCompactor(config)
    return _auto_compactor