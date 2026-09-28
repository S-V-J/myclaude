"""
Real-time RAM monitoring with high-load protection for the MyClaude gateway.

Provides memory pressure detection, automatic throttling, and graceful degradation
under high memory conditions.
"""
import os
import time
import threading
import psutil
from dataclasses import dataclass, field
from typing import Optional, Callable, Dict, Any
from enum import Enum
import logging

logger = logging.getLogger(__name__)


class MemoryPressureLevel(Enum):
    """Memory pressure levels based on system RAM usage."""
    NORMAL = "normal"           # < 70% RAM used
    ELEVATED = "elevated"       # 70-80% RAM used
    HIGH = "high"               # 80-90% RAM used
    CRITICAL = "critical"       # > 90% RAM used


@dataclass
class RAMMonitorConfig:
    """Configuration for RAM monitoring thresholds and behavior."""
    # Memory pressure thresholds (percentage of total RAM)
    normal_threshold: float = 70.0
    elevated_threshold: float = 80.0
    high_threshold: float = 90.0
    critical_threshold: float = 95.0

    # Monitoring interval in seconds
    check_interval: float = 5.0

    # Throttle behavior
    throttle_on_elevated: bool = True
    throttle_on_high: bool = True
    reject_on_critical: bool = True

    # Throttle factors (multiplier for rate limits)
    elevated_throttle_factor: float = 0.5   # 50% rate limit at elevated
    high_throttle_factor: float = 0.25      # 25% rate limit at high

    # Cooldown period after pressure subsides (seconds)
    cooldown_seconds: float = 30.0

    # Enable/disable monitoring
    enabled: bool = True


@dataclass
class MemoryStats:
    """Current memory statistics."""
    total_mb: float
    available_mb: float
    used_mb: float
    percent_used: float
    pressure_level: MemoryPressureLevel
    timestamp: float


class RAMMonitor:
    """
    Monitors system RAM and provides memory pressure detection with callbacks.

    Features:
    - Real-time memory pressure detection (4 levels)
    - Configurable thresholds
    - Callback system for pressure changes
    - Thread-safe operations
    - Integration with rate limiters for automatic throttling
    """

    def __init__(self, config: Optional[RAMMonitorConfig] = None):
        self.config = config or RAMMonitorConfig()
        self._lock = threading.RLock()
        self._monitor_thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._current_stats: Optional[MemoryStats] = None
        self._current_pressure: MemoryPressureLevel = MemoryPressureLevel.NORMAL
        self._pressure_callbacks: Dict[MemoryPressureLevel, list] = {
            level: [] for level in MemoryPressureLevel
        }
        self._last_pressure_change: float = 0
        self._throttle_factor: float = 1.0

    def start(self) -> None:
        """Start the background monitoring thread."""
        if not self.config.enabled:
            logger.info("RAM monitoring is disabled")
            return

        with self._lock:
            if self._monitor_thread and self._monitor_thread.is_alive():
                logger.warning("RAM monitor already running")
                return

            self._stop_event.clear()
            self._monitor_thread = threading.Thread(
                target=self._monitor_loop,
                name="ram-monitor",
                daemon=True
            )
            self._monitor_thread.start()
            logger.info("RAM monitor started")

    def stop(self) -> None:
        """Stop the background monitoring thread."""
        with self._lock:
            self._stop_event.set()
            if self._monitor_thread:
                self._monitor_thread.join(timeout=2.0)
                self._monitor_thread = None
            logger.info("RAM monitor stopped")

    def _monitor_loop(self) -> None:
        """Main monitoring loop."""
        while not self._stop_event.is_set():
            try:
                stats = self._collect_stats()
                self._evaluate_pressure(stats)
            except Exception as e:
                logger.error(f"Error in RAM monitor loop: {e}")

            self._stop_event.wait(self.config.check_interval)

    def _collect_stats(self) -> MemoryStats:
        """Collect current memory statistics."""
        vm = psutil.virtual_memory()
        total_mb = vm.total / (1024 * 1024)
        available_mb = vm.available / (1024 * 1024)
        used_mb = vm.used / (1024 * 1024)
        percent_used = vm.percent

        pressure = self._calculate_pressure(percent_used)

        stats = MemoryStats(
            total_mb=total_mb,
            available_mb=available_mb,
            used_mb=used_mb,
            percent_used=percent_used,
            pressure_level=pressure,
            timestamp=time.time()
        )

        with self._lock:
            self._current_stats = stats

        return stats

    def _calculate_pressure(self, percent_used: float) -> MemoryPressureLevel:
        """Calculate pressure level from memory usage percentage."""
        if percent_used >= self.config.critical_threshold:
            return MemoryPressureLevel.CRITICAL
        elif percent_used >= self.config.high_threshold:
            return MemoryPressureLevel.HIGH
        elif percent_used >= self.config.elevated_threshold:
            return MemoryPressureLevel.ELEVATED
        else:
            return MemoryPressureLevel.NORMAL

    def _evaluate_pressure(self, stats: MemoryStats) -> None:
        """Evaluate pressure level and trigger callbacks if changed."""
        with self._lock:
            old_pressure = self._current_pressure
            new_pressure = stats.pressure_level

            if old_pressure != new_pressure:
                self._current_pressure = new_pressure
                self._last_pressure_change = time.time()
                self._update_throttle_factor(new_pressure)
                self._trigger_callbacks(old_pressure, new_pressure, stats)

    def _update_throttle_factor(self, pressure: MemoryPressureLevel) -> None:
        """Update the throttle factor based on pressure level."""
        if pressure == MemoryPressureLevel.NORMAL:
            self._throttle_factor = 1.0
        elif pressure == MemoryPressureLevel.ELEVATED:
            self._throttle_factor = self.config.elevated_throttle_factor
        elif pressure == MemoryPressureLevel.HIGH:
            self._throttle_factor = self.config.high_throttle_factor
        elif pressure == MemoryPressureLevel.CRITICAL:
            self._throttle_factor = 0.0  # Reject all requests

        logger.info(f"Memory pressure: {pressure.value}, throttle factor: {self._throttle_factor}")

    def _trigger_callbacks(self, old: MemoryPressureLevel, new: MemoryPressureLevel, stats: MemoryStats) -> None:
        """Trigger registered callbacks for pressure level changes."""
        for callback in self._pressure_callbacks.get(new, []):
            try:
                callback(old, new, stats)
            except Exception as e:
                logger.error(f"Error in pressure callback: {e}")

        # Also trigger general change callbacks
        for callback in self._pressure_callbacks.get(MemoryPressureLevel.NORMAL, []):
            try:
                callback(old, new, stats)
            except Exception as e:
                logger.error(f"Error in general pressure callback: {e}")

    def register_callback(self, level: MemoryPressureLevel, callback: Callable[[MemoryPressureLevel, MemoryPressureLevel, MemoryStats], None]) -> None:
        """Register a callback for a specific pressure level."""
        with self._lock:
            self._pressure_callbacks[level].append(callback)

    def register_general_callback(self, callback: Callable[[MemoryPressureLevel, MemoryPressureLevel, MemoryStats], None]) -> None:
        """Register a callback for any pressure level change."""
        with self._lock:
            self._pressure_callbacks[MemoryPressureLevel.NORMAL].append(callback)

    def get_current_stats(self) -> Optional[MemoryStats]:
        """Get the most recent memory statistics."""
        with self._lock:
            return self._current_stats

    def get_current_pressure(self) -> MemoryPressureLevel:
        """Get the current memory pressure level."""
        with self._lock:
            return self._current_pressure

    def get_throttle_factor(self) -> float:
        """Get the current throttle factor (0.0 to 1.0)."""
        with self._lock:
            return self._throttle_factor

    def should_throttle(self) -> bool:
        """Check if requests should be throttled."""
        return self.get_throttle_factor() < 1.0

    def should_reject(self) -> bool:
        """Check if requests should be rejected (critical pressure)."""
        return self.get_current_pressure() == MemoryPressureLevel.CRITICAL

    def get_status(self) -> Dict[str, Any]:
        """Get comprehensive status for monitoring/debugging."""
        with self._lock:
            stats = self._current_stats
            return {
                "enabled": self.config.enabled,
                "pressure_level": self._current_pressure.value,
                "throttle_factor": self._throttle_factor,
                "should_throttle": self.should_throttle(),
                "should_reject": self.should_reject(),
                "last_pressure_change": self._last_pressure_change,
                "memory": {
                    "total_mb": round(stats.total_mb, 1) if stats else None,
                    "used_mb": round(stats.used_mb, 1) if stats else None,
                    "available_mb": round(stats.available_mb, 1) if stats else None,
                    "percent_used": round(stats.percent_used, 1) if stats else None,
                } if stats else None,
                "thresholds": {
                    "normal": self.config.normal_threshold,
                    "elevated": self.config.elevated_threshold,
                    "high": self.config.high_threshold,
                    "critical": self.config.critical_threshold,
                }
            }


class RAMAwareRateLimiter:
    """
    Wrapper that adds RAM-aware throttling to any rate limiter.

    Automatically adjusts effective rate limits based on memory pressure.
    """

    def __init__(self, base_limiter, ram_monitor: RAMMonitor):
        self.base_limiter = base_limiter
        self.ram_monitor = ram_monitor
        self._original_max_requests = {}

        # Register for pressure changes
        ram_monitor.register_general_callback(self._on_pressure_change)

    def _on_pressure_change(self, old: MemoryPressureLevel, new: MemoryPressureLevel, stats: MemoryStats) -> None:
        """Handle memory pressure changes by adjusting rate limits."""
        factor = self.ram_monitor.get_throttle_factor()

        if factor < 1.0:
            # Throttle: reduce effective max_requests
            for key in self._original_max_requests:
                original = self._original_max_requests[key]
                new_max = max(1, int(original * factor))
                # Update the base limiter's config if it supports it
                if hasattr(self.base_limiter, 'config'):
                    self.base_limiter.config.max_requests = new_max
                logger.warning(f"Throttled rate limit for {key}: {original} -> {new_max} (factor: {factor})")
        else:
            # Restore original limits
            for key, original in self._original_max_requests.items():
                if hasattr(self.base_limiter, 'config'):
                    self.base_limiter.config.max_requests = original
                logger.info(f"Restored rate limit for {key}: {original}")

    def acquire(self, key: str) -> bool:
        """Acquire a slot with RAM-aware throttling."""
        # Check if we should reject entirely
        if self.ram_monitor.should_reject():
            logger.warning(f"Request rejected for {key}: critical memory pressure")
            return False

        # Check if we should apply additional throttling
        if self.ram_monitor.should_throttle():
            # Could add additional delay or probabilistic rejection here
            pass

        return self.base_limiter.acquire(key)

    def release(self, key: str) -> None:
        return self.base_limiter.release(key)

    def get_usage(self, key: str):
        return self.base_limiter.get_usage(key)

    def is_exhausted(self, key: str) -> bool:
        # Also consider memory pressure
        if self.ram_monitor.should_reject():
            return True
        return self.base_limiter.is_exhausted(key)

    def reset(self, key: str) -> None:
        return self.base_limiter.reset(key)

    def get_wait_time(self, key: str) -> float:
        return self.base_limiter.get_wait_time(key)


# Global instance for convenience
_ram_monitor: Optional[RAMMonitor] = None


def get_ram_monitor(config: Optional[RAMMonitorConfig] = None) -> RAMMonitor:
    """Get or create the global RAM monitor instance."""
    global _ram_monitor
    if _ram_monitor is None:
        _ram_monitor = RAMMonitor(config)
    return _ram_monitor