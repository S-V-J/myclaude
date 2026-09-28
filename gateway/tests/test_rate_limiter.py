"""
Unit tests for rate_limiter module.

Tests cover:
- RateLimitConfig dataclass
- SlidingWindowRateLimiter core functionality
- TokenBucketRateLimiter implementation
- get_default_limiter singleton
"""
import os
import sys
import time
import threading
from typing import List

import pytest

# Add project root to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../..'))

from gateway.rate_limiter import (
    RateLimitConfig,
    RateLimiter,
    SlidingWindowRateLimiter,
    TokenBucketRateLimiter,
    get_default_limiter
)


class TestRateLimitConfig:
    """Test RateLimitConfig dataclass."""

    def test_defaults(self):
        """Test default configuration values."""
        config = RateLimitConfig()
        assert config.max_requests == 32
        assert config.window_seconds == 60
        assert config.key_prefix == "api_key"

    def test_custom_values(self):
        """Test custom configuration values."""
        config = RateLimitConfig(
            max_requests=100,
            window_seconds=30,
            key_prefix="custom_key"
        )
        assert config.max_requests == 100
        assert config.window_seconds == 30
        assert config.key_prefix == "custom_key"


class TestSlidingWindowRateLimiter:
    """Test SlidingWindowRateLimiter implementation."""

    def setup_method(self):
        """Setup test fixtures."""
        self.config = RateLimitConfig(max_requests=5, window_seconds=60)
        self.limiter = SlidingWindowRateLimiter(self.config)

    def test_acquire_allows_up_to_max(self):
        """Test that acquire allows up to max_requests."""
        key = "test_key_1"

        # Should allow all requests up to max
        for i in range(5):
            assert self.limiter.acquire(key) is True, f"Request {i+1} should be allowed"

        # 6th request should be denied
        assert self.limiter.acquire(key) is False

    def test_acquire_different_keys_independent(self):
        """Test that different keys have independent limits."""
        # Fill up key1
        for _ in range(5):
            assert self.limiter.acquire("key1") is True
        assert self.limiter.acquire("key1") is False

        # key2 should still work
        for _ in range(5):
            assert self.limiter.acquire("key2") is True
        assert self.limiter.acquire("key2") is False

    def test_release_frees_slot(self):
        """Test that release frees a slot."""
        key = "test_key_2"

        # Fill up the window
        for _ in range(5):
            assert self.limiter.acquire(key) is True
        assert self.limiter.acquire(key) is False

        # Release one slot
        self.limiter.release(key)

        # Should allow one more
        assert self.limiter.acquire(key) is True
        assert self.limiter.acquire(key) is False

    def test_get_usage_returns_correct_counts(self):
        """Test get_usage returns correct (current, max) tuple."""
        key = "test_key_3"

        # Initially empty
        current, max_req = self.limiter.get_usage(key)
        assert current == 0
        assert max_req == 5

        # Make 3 requests
        for _ in range(3):
            self.limiter.acquire(key)

        current, max_req = self.limiter.get_usage(key)
        assert current == 3
        assert max_req == 5

    def test_is_exhausted_when_at_limit(self):
        """Test is_exhausted returns True when at limit."""
        key = "test_key_4"

        assert self.limiter.is_exhausted(key) is False

        # Fill up
        for _ in range(5):
            self.limiter.acquire(key)

        assert self.limiter.is_exhausted(key) is True

    def test_reset_clears_window(self):
        """Test reset clears the window for a key."""
        key = "test_key_5"

        # Fill up
        for _ in range(5):
            self.limiter.acquire(key)
        assert self.limiter.is_exhausted(key) is True

        # Reset
        self.limiter.reset(key)

        # Should be empty again
        assert self.limiter.is_exhausted(key) is False
        current, max_req = self.limiter.get_usage(key)
        assert current == 0

    def test_get_wait_time_returns_zero_when_available(self):
        """Test get_wait_time returns 0 when slots available."""
        key = "test_key_6"

        wait_time = self.limiter.get_wait_time(key)
        assert wait_time == 0.0

        # Make some requests but not at limit
        self.limiter.acquire(key)
        self.limiter.acquire(key)

        wait_time = self.limiter.get_wait_time(key)
        assert wait_time == 0.0

    def test_get_wait_time_returns_positive_when_exhausted(self):
        """Test get_wait_time returns positive value when exhausted."""
        key = "test_key_7"

        # Fill up
        for _ in range(5):
            self.limiter.acquire(key)

        wait_time = self.limiter.get_wait_time(key)
        assert wait_time > 0.0
        assert wait_time <= 60.0  # Should be within window

    def test_get_all_usage_returns_all_keys(self):
        """Test get_all_usage returns usage for all tracked keys."""
        # Add some usage to multiple keys
        for _ in range(3):
            self.limiter.acquire("key_a")
        for _ in range(2):
            self.limiter.acquire("key_b")

        all_usage = self.limiter.get_all_usage()

        assert "key_a" in all_usage
        assert "key_b" in all_usage
        assert all_usage["key_a"] == (3, 5)
        assert all_usage["key_b"] == (2, 5)

    def test_concurrent_access_thread_safety(self):
        """Test thread safety with concurrent access."""
        key = "concurrent_key"
        results: List[bool] = []
        errors: List[Exception] = []

        def make_requests(num_requests: int):
            try:
                for _ in range(num_requests):
                    result = self.limiter.acquire(key)
                    results.append(result)
            except Exception as e:
                errors.append(e)

        # Run 10 threads each making 3 requests (30 total, limit is 5)
        threads = []
        for _ in range(10):
            t = threading.Thread(target=make_requests, args=(3,))
            threads.append(t)
            t.start()

        for t in threads:
            t.join()

        assert len(errors) == 0, f"Errors occurred: {errors}"
        # Exactly 5 should succeed, 25 should fail
        success_count = sum(1 for r in results if r)
        assert success_count == 5, f"Expected 5 successes, got {success_count}"

    def test_window_expiration(self):
        """Test that old entries expire after window_seconds."""
        # Use a short window for testing
        config = RateLimitConfig(max_requests=2, window_seconds=1)
        limiter = SlidingWindowRateLimiter(config)
        key = "expiry_key"

        # Fill up
        assert limiter.acquire(key) is True
        assert limiter.acquire(key) is True
        assert limiter.acquire(key) is False

        # Wait for window to expire
        time.sleep(1.1)

        # Should allow again
        assert limiter.acquire(key) is True
        assert limiter.acquire(key) is True
        assert limiter.acquire(key) is False


class TestTokenBucketRateLimiter:
    """Test TokenBucketRateLimiter implementation."""

    def setup_method(self):
        """Setup test fixtures."""
        self.config = RateLimitConfig(max_requests=10, window_seconds=60)
        self.limiter = TokenBucketRateLimiter(self.config)

    def test_acquire_allows_up_to_max(self):
        """Test that acquire allows up to max_requests tokens."""
        key = "tb_key_1"

        for i in range(10):
            assert self.limiter.acquire(key) is True, f"Request {i+1} should be allowed"

        assert self.limiter.acquire(key) is False

    def test_release_adds_token_back(self):
        """Test that release adds a token back."""
        key = "tb_key_2"

        # Exhaust tokens
        for _ in range(10):
            self.limiter.acquire(key)
        assert self.limiter.acquire(key) is False

        # Release one
        self.limiter.release(key)

        # Should allow one more
        assert self.limiter.acquire(key) is True
        assert self.limiter.acquire(key) is False

    def test_get_usage_returns_correct_counts(self):
        """Test get_usage returns correct usage."""
        key = "tb_key_3"

        # Initially full
        used, max_req = self.limiter.get_usage(key)
        assert used == 0
        assert max_req == 10

        # Use 4 tokens
        for _ in range(4):
            self.limiter.acquire(key)

        used, max_req = self.limiter.get_usage(key)
        assert used == 4
        assert max_req == 10

    def test_is_exhausted(self):
        """Test is_exhausted when bucket is empty."""
        key = "tb_key_4"

        assert self.limiter.is_exhausted(key) is False

        # Exhaust
        for _ in range(10):
            self.limiter.acquire(key)

        assert self.limiter.is_exhausted(key) is True

    def test_reset_clears_bucket(self):
        """Test reset clears the bucket."""
        key = "tb_key_5"

        # Exhaust
        for _ in range(10):
            self.limiter.acquire(key)

        self.limiter.reset(key)

        # Should be full again
        used, max_req = self.limiter.get_usage(key)
        assert used == 0

    def test_refill_over_time(self):
        """Test token refill behavior over time."""
        # Use high refill rate for testing
        config = RateLimitConfig(max_requests=10, window_seconds=1)  # 10 tokens/sec
        limiter = TokenBucketRateLimiter(config)
        key = "tb_key_6"

        # Exhaust
        for _ in range(10):
            limiter.acquire(key)
        assert limiter.acquire(key) is False

        # Wait for refill
        time.sleep(0.6)  # Should refill ~6 tokens

        # Should be able to acquire some
        acquired = 0
        for _ in range(10):
            if limiter.acquire(key):
                acquired += 1

        assert acquired >= 5, f"Expected at least 5 tokens, got {acquired}"

    def test_different_keys_independent(self):
        """Test different keys have independent buckets."""
        # Exhaust key1
        for _ in range(10):
            self.limiter.acquire("tb_key_a")
        assert self.limiter.acquire("tb_key_a") is False

        # key2 should work
        for _ in range(10):
            assert self.limiter.acquire("tb_key_b") is True


class TestGetDefaultLimiter:
    """Test get_default_limiter singleton."""

    def test_returns_sliding_window_limiter(self):
        """Test that default limiter is SlidingWindowRateLimiter."""
        limiter = get_default_limiter()
        assert isinstance(limiter, SlidingWindowRateLimiter)

    def test_returns_same_instance(self):
        """Test that multiple calls return the same instance."""
        limiter1 = get_default_limiter()
        limiter2 = get_default_limiter()
        assert limiter1 is limiter2

    def test_default_config(self):
        """Test default limiter uses default config."""
        limiter = get_default_limiter()
        assert limiter.config.max_requests == 32
        assert limiter.config.window_seconds == 60


if __name__ == "__main__":
    pytest.main([__file__, "-v"])