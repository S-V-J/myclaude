"""
Thread-safe rate limiting implementation for API key quota management.

Implements sliding window rate limiting with 32 RPM per API key.
"""
import time
import threading
from collections import deque
from dataclasses import dataclass, field
from typing import Dict, Optional, Tuple
from abc import ABC, abstractmethod


@dataclass
class RateLimitConfig:
    """Configuration for rate limiting."""
    max_requests: int = 30
    window_seconds: int = 60
    key_prefix: str = "api_key"


class RateLimiter(ABC):
    """Abstract base class for rate limiters."""

    @abstractmethod
    def acquire(self, key: str) -> bool:
        """Attempt to acquire a slot for the given key. Returns True if allowed."""
        pass

    @abstractmethod
    def release(self, key: str) -> None:
        """Release a slot (for cleanup on error)."""
        pass

    @abstractmethod
    def get_usage(self, key: str) -> Tuple[int, int]:
        """Get current usage: (requests_in_window, max_requests)."""
        pass

    @abstractmethod
    def is_exhausted(self, key: str) -> bool:
        """Check if key has exhausted its quota."""
        pass

    @abstractmethod
    def reset(self, key: str) -> None:
        """Reset rate limit for a key."""
        pass


class SlidingWindowRateLimiter(RateLimiter):
    """
    Thread-safe sliding window rate limiter.

    Uses a deque to track request timestamps within the window.
    Automatically evicts expired entries on each check.
    """

    def __init__(self, config: Optional[RateLimitConfig] = None):
        self.config = config or RateLimitConfig()
        self._locks: Dict[str, threading.Lock] = {}
        self._global_lock = threading.Lock()
        self._windows: Dict[str, deque] = {}

    def _get_lock(self, key: str) -> threading.Lock:
        """Get or create a lock for a specific key."""
        with self._global_lock:
            if key not in self._locks:
                self._locks[key] = threading.Lock()
            return self._locks[key]

    def _get_window(self, key: str) -> deque:
        """Get or create the sliding window for a key."""
        if key not in self._windows:
            self._windows[key] = deque()
        return self._windows[key]

    def _cleanup_window(self, window: deque, now: float) -> None:
        """Remove expired entries from the window."""
        cutoff = now - self.config.window_seconds
        while window and window[0] < cutoff:
            window.popleft()

    def acquire(self, key: str) -> bool:
        """
        Attempt to acquire a request slot.

        Args:
            key: The API key identifier

        Returns:
            True if request is allowed, False if rate limited
        """
        lock = self._get_lock(key)
        with lock:
            window = self._get_window(key)
            now = time.time()
            self._cleanup_window(window, now)

            if len(window) >= self.config.max_requests:
                return False

            window.append(now)
            return True

    def release(self, key: str) -> None:
        """Release a slot (remove most recent entry)."""
        lock = self._get_lock(key)
        with lock:
            window = self._get_window(key)
            if window:
                window.pop()

    def get_usage(self, key: str) -> Tuple[int, int]:
        """
        Get current usage statistics.

        Returns:
            Tuple of (current_requests_in_window, max_requests)
        """
        lock = self._get_lock(key)
        with lock:
            window = self._get_window(key)
            now = time.time()
            self._cleanup_window(window, now)
            return len(window), self.config.max_requests

    def is_exhausted(self, key: str) -> bool:
        """Check if the key has hit its rate limit."""
        current, max_req = self.get_usage(key)
        return current >= max_req

    def reset(self, key: str) -> None:
        """Reset the rate limit window for a key."""
        lock = self._get_lock(key)
        with lock:
            if key in self._windows:
                self._windows[key].clear()

    def get_wait_time(self, key: str) -> float:
        """
        Get estimated wait time until a slot is available.

        Returns:
            Seconds until next slot available, or 0 if available now
        """
        lock = self._get_lock(key)
        with lock:
            window = self._get_window(key)
            if not window:
                return 0.0

            now = time.time()
            self._cleanup_window(window, now)

            if len(window) < self.config.max_requests:
                return 0.0

            # Oldest request will expire first
            oldest = window[0]
            return max(0.0, oldest + self.config.window_seconds - now)

    def get_all_usage(self) -> Dict[str, Tuple[int, int]]:
        """Get usage for all tracked keys."""
        result = {}
        with self._global_lock:
            for key in list(self._windows.keys()):
                result[key] = self.get_usage(key)
        return result


class TokenBucketRateLimiter(RateLimiter):
    """
    Alternative token bucket implementation for smoother rate limiting.
    """

    def __init__(self, config: Optional[RateLimitConfig] = None):
        self.config = config or RateLimitConfig()
        self._locks: Dict[str, threading.Lock] = {}
        self._global_lock = threading.Lock()
        self._buckets: Dict[str, Tuple[float, float]] = {}  # (tokens, last_refill)

    def _get_lock(self, key: str) -> threading.Lock:
        with self._global_lock:
            if key not in self._locks:
                self._locks[key] = threading.Lock()
            return self._locks[key]

    def _refill(self, key: str, now: float) -> float:
        """Refill tokens based on elapsed time."""
        if key not in self._buckets:
            self._buckets[key] = (float(self.config.max_requests), now)
            return float(self.config.max_requests)

        tokens, last_refill = self._buckets[key]
        elapsed = now - last_refill
        refill_rate = self.config.max_requests / self.config.window_seconds
        tokens = min(self.config.max_requests, tokens + elapsed * refill_rate)
        self._buckets[key] = (tokens, now)
        return tokens

    def acquire(self, key: str) -> bool:
        lock = self._get_lock(key)
        with lock:
            now = time.time()
            tokens = self._refill(key, now)
            if tokens >= 1.0:
                self._buckets[key] = (tokens - 1.0, now)
                return True
            return False

    def release(self, key: str) -> None:
        lock = self._get_lock(key)
        with lock:
            if key in self._buckets:
                tokens, last_refill = self._buckets[key]
                self._buckets[key] = (min(self.config.max_requests, tokens + 1.0), last_refill)

    def get_usage(self, key: str) -> Tuple[int, int]:
        lock = self._get_lock(key)
        with lock:
            now = time.time()
            tokens = self._refill(key, now)
            used = int(self.config.max_requests - tokens)
            return used, self.config.max_requests

    def is_exhausted(self, key: str) -> bool:
        return not self.acquire(key)

    def reset(self, key: str) -> None:
        lock = self._get_lock(key)
        with lock:
            if key in self._buckets:
                del self._buckets[key]


# Default instance for convenience
_default_limiter: Optional[SlidingWindowRateLimiter] = None


def get_default_limiter() -> SlidingWindowRateLimiter:
    """Get or create the default rate limiter instance."""
    global _default_limiter
    if _default_limiter is None:
        _default_limiter = SlidingWindowRateLimiter()
    return _default_limiter