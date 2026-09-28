"""
Resilient Fallback System for MyClaude Gateway.

Provides:
- Circuit breaker pattern for failing models/keys
- Health checks with configurable thresholds
- Exponential backoff retry logic
- Graceful degradation with queueing
- Comprehensive fallback event logging
"""
import time
import threading
import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Callable, Any, Tuple
from enum import Enum
from collections import deque
import random

logger = logging.getLogger(__name__)


class CircuitState(str, Enum):
    """Circuit breaker states."""
    CLOSED = "closed"      # Normal operation, requests go through
    OPEN = "open"          # Failing, requests blocked
    HALF_OPEN = "half_open"  # Testing if service recovered


class HealthStatus(str, Enum):
    """Health check status."""
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"
    UNKNOWN = "unknown"


@dataclass
class CircuitBreakerConfig:
    """Configuration for circuit breaker."""
    failure_threshold: int = 5          # Failures before opening
    success_threshold: int = 2          # Successes in half-open before closing
    timeout_seconds: float = 60.0       # Time before half-open
    half_open_max_requests: int = 3     # Max requests in half-open state


@dataclass
class RetryConfig:
    """Configuration for retry logic."""
    max_retries: int = 3
    base_delay_seconds: float = 1.0
    max_delay_seconds: float = 60.0
    exponential_base: float = 2.0
    jitter: bool = True


@dataclass
class HealthCheckConfig:
    """Configuration for health checks."""
    enabled: bool = True
    interval_seconds: float = 30.0
    timeout_seconds: float = 10.0
    healthy_threshold: int = 2        # Consecutive successes to mark healthy
    unhealthy_threshold: int = 3      # Consecutive failures to mark unhealthy
    degraded_threshold: float = 0.5   # Error rate to mark degraded


@dataclass
class CircuitBreaker:
    """Circuit breaker for a specific key/model combination."""
    key: str
    config: CircuitBreakerConfig
    state: CircuitState = CircuitState.CLOSED
    failure_count: int = 0
    success_count: int = 0
    last_failure_time: float = 0
    last_state_change: float = field(default_factory=time.time)
    half_open_requests: int = 0

    def can_execute(self) -> bool:
        """Check if request can be executed."""
        now = time.time()

        if self.state == CircuitState.CLOSED:
            return True

        elif self.state == CircuitState.OPEN:
            # Check if timeout has passed to move to half-open
            if now - self.last_failure_time >= self.config.timeout_seconds:
                self.state = CircuitState.HALF_OPEN
                self.half_open_requests = 0
                self.last_state_change = now
                logger.info(f"Circuit breaker {self.key} moved to HALF_OPEN")
                return True
            return False

        elif self.state == CircuitState.HALF_OPEN:
            # Allow limited requests in half-open
            if self.half_open_requests < self.config.half_open_max_requests:
                self.half_open_requests += 1
                return True
            return False

        return False

    def record_success(self) -> None:
        """Record a successful request."""
        if self.state == CircuitState.HALF_OPEN:
            self.success_count += 1
            if self.success_count >= self.config.success_threshold:
                self.state = CircuitState.CLOSED
                self.failure_count = 0
                self.success_count = 0
                self.last_state_change = time.time()
                logger.info(f"Circuit breaker {self.key} CLOSED after recovery")

        elif self.state == CircuitState.CLOSED:
            # Reset failure count on success
            self.failure_count = 0

    def record_failure(self) -> None:
        """Record a failed request."""
        now = time.time()
        self.failure_count += 1
        self.last_failure_time = now

        if self.state == CircuitState.HALF_OPEN:
            # Any failure in half-open goes back to open
            self.state = CircuitState.OPEN
            self.success_count = 0
            self.last_state_change = now
            logger.warning(f"Circuit breaker {self.key} reopened after half-open failure")

        elif self.state == CircuitState.CLOSED:
            if self.failure_count >= self.config.failure_threshold:
                self.state = CircuitState.OPEN
                self.last_state_change = now
                logger.warning(f"Circuit breaker {self.key} OPENED after {self.failure_count} failures")

    def get_status(self) -> Dict[str, Any]:
        """Get circuit breaker status."""
        return {
            "key": self.key,
            "state": self.state.value,
            "failure_count": self.failure_count,
            "success_count": self.success_count,
            "last_failure_time": self.last_failure_time,
            "last_state_change": self.last_state_change,
        }


@dataclass
class HealthCheckResult:
    """Result of a health check."""
    key: str
    status: HealthStatus
    latency_ms: float
    error: Optional[str] = None
    timestamp: float = field(default_factory=time.time)


class HealthMonitor:
    """
    Monitors health of API keys and models.

    Tracks:
    - Success/error rates
    - Latency percentiles
    - Consecutive failures/successes
    """

    def __init__(self, config: Optional[HealthCheckConfig] = None):
        self.config = config or HealthCheckConfig()
        self._lock = threading.RLock()
        self._health_data: Dict[str, Dict] = {}
        self._health_check_callback: Optional[Callable] = None

    def set_health_check_callback(self, callback: Callable[[str], HealthCheckResult]) -> None:
        """Set the function to call for health checks."""
        self._health_check_callback = callback

    def record_request(self, key: str, success: bool, latency_ms: float, error: Optional[str] = None) -> None:
        """Record a request result for health tracking."""
        with self._lock:
            if key not in self._health_data:
                self._health_data[key] = {
                    "total_requests": 0,
                    "successful_requests": 0,
                    "failed_requests": 0,
                    "consecutive_successes": 0,
                    "consecutive_failures": 0,
                    "latencies": deque(maxlen=100),
                    "last_check": 0,
                    "status": HealthStatus.UNKNOWN,
                }

            data = self._health_data[key]
            data["total_requests"] += 1
            data["latencies"].append(latency_ms)

            if success:
                data["successful_requests"] += 1
                data["consecutive_successes"] += 1
                data["consecutive_failures"] = 0
            else:
                data["failed_requests"] += 1
                data["consecutive_failures"] += 1
                data["consecutive_successes"] = 0

            # Update status based on thresholds
            if data["consecutive_failures"] >= self.config.unhealthy_threshold:
                data["status"] = HealthStatus.UNHEALTHY
            elif data["consecutive_successes"] >= self.config.healthy_threshold:
                data["status"] = HealthStatus.HEALTHY
            elif data["total_requests"] > 10:
                error_rate = data["failed_requests"] / data["total_requests"]
                if error_rate >= self.config.degraded_threshold:
                    data["status"] = HealthStatus.DEGRADED
                else:
                    data["status"] = HealthStatus.HEALTHY

    def get_health(self, key: str) -> Dict[str, Any]:
        """Get health status for a key."""
        with self._lock:
            data = self._health_data.get(key, {})
            if not data:
                return {"key": key, "status": HealthStatus.UNKNOWN.value}

            latencies = list(data.get("latencies", []))
            return {
                "key": key,
                "status": data.get("status", HealthStatus.UNKNOWN).value,
                "total_requests": data.get("total_requests", 0),
                "successful_requests": data.get("successful_requests", 0),
                "failed_requests": data.get("failed_requests", 0),
                "error_rate": data.get("failed_requests", 0) / max(data.get("total_requests", 1), 1),
                "consecutive_successes": data.get("consecutive_successes", 0),
                "consecutive_failures": data.get("consecutive_failures", 0),
                "avg_latency_ms": sum(latencies) / len(latencies) if latencies else 0,
                "p50_latency_ms": self._percentile(latencies, 50) if latencies else 0,
                "p95_latency_ms": self._percentile(latencies, 95) if latencies else 0,
                "p99_latency_ms": self._percentile(latencies, 99) if latencies else 0,
            }

    def _percentile(self, data: List[float], percentile: int) -> float:
        """Calculate percentile."""
        if not data:
            return 0
        sorted_data = sorted(data)
        index = int(len(sorted_data) * percentile / 100)
        return sorted_data[min(index, len(sorted_data) - 1)]

    def get_all_health(self) -> Dict[str, Dict[str, Any]]:
        """Get health for all tracked keys."""
        with self._lock:
            return {key: self.get_health(key) for key in self._health_data.keys()}

    def is_healthy(self, key: str) -> bool:
        """Check if a key is healthy."""
        health = self.get_health(key)
        return health["status"] in [HealthStatus.HEALTHY.value, HealthStatus.DEGRADED.value]


class ResilientFallbackManager:
    """
    Enhanced fallback manager with circuit breakers, health monitoring,
    and intelligent retry logic.
    """

    def __init__(
        self,
        fallback_manager,  # The original FallbackManager
        circuit_config: Optional[CircuitBreakerConfig] = None,
        retry_config: Optional[RetryConfig] = None,
        health_config: Optional[HealthCheckConfig] = None
    ):
        self.fallback_manager = fallback_manager
        self.circuit_config = circuit_config or CircuitBreakerConfig()
        self.retry_config = retry_config or RetryConfig()
        self.health_config = health_config or HealthCheckConfig()

        self._lock = threading.RLock()
        self._circuit_breakers: Dict[str, CircuitBreaker] = {}
        self._health_monitor = HealthMonitor(self.health_config)
        self._request_queue: deque = deque()
        self._queue_lock = threading.Lock()
        self._max_queue_size = 1000

    def _get_circuit_key(self, scene_id: str, key_index: int, model_tier: str) -> str:
        """Generate a unique key for circuit breaker."""
        return f"{scene_id}:key{key_index}:{model_tier}"

    def _get_or_create_circuit(self, key: str) -> CircuitBreaker:
        """Get or create a circuit breaker for a key."""
        with self._lock:
            if key not in self._circuit_breakers:
                self._circuit_breakers[key] = CircuitBreaker(key, self.circuit_config)
            return self._circuit_breakers[key]

    def execute_with_resilient_fallback(
        self,
        scene_id: str,
        model_alias: str,
        request_func: Callable
    ) -> Tuple[Any, Dict]:
        """
        Execute request with resilient fallback logic.

        Features:
        - Circuit breaker per key/model
        - Health-aware key selection
        - Exponential backoff retries
        - Request queueing when all keys exhausted
        """
        with self._lock:
            scene = self.fallback_manager.get_scene(scene_id)
            if not scene:
                raise ValueError(f"Scene not found: {scene_id}")

            metadata = {
                "scene_id": scene_id,
                "model_alias": model_alias,
                "attempts": [],
                "final_key": None,
                "final_model": None,
                "fallback_reason": None,
                "total_latency": 0.0,
                "circuit_breaker_events": [],
                "health_events": [],
            }

            start_time = time.time()
            excluded_keys = []
            chain = scene.get_fallback_chain(model_alias)

            # Try to find an available key with circuit breaker and health checks
            key_index = self._find_healthy_available_key(scene, model_alias, excluded_keys)

            if key_index is None:
                # All keys exhausted or unhealthy, try queuing
                return self._handle_all_keys_exhausted(scene, model_alias, request_func, metadata, start_time, chain, excluded_keys)

            # Try the fallback chain for this key
            for tier_index, tier in enumerate(chain):
                circuit_key = self._get_circuit_key(scene_id, key_index, tier.value)
                circuit = self._get_or_create_circuit(circuit_key)

                # Check circuit breaker
                if not circuit.can_execute():
                    logger.warning(f"Circuit breaker OPEN for {circuit_key}, trying next option")
                    metadata["circuit_breaker_events"].append({
                        "key": circuit_key,
                        "action": "blocked",
                        "state": circuit.state.value
                    })
                    excluded_keys.append(key_index)
                    key_index = self._find_healthy_available_key(scene, model_alias, excluded_keys)
                    if key_index is None:
                        return self._handle_all_keys_exhausted(scene, model_alias, request_func, metadata, start_time, chain, excluded_keys)
                    continue  # Retry with new key

                # Find model config
                model_config = None
                for model in scene.models:
                    if (model.api_key_index == key_index and
                        model.tier == tier and
                        model.enabled):
                        model_config = model
                        break

                if not model_config:
                    continue

                attempt_start = time.time()
                attempt_metadata = {
                    "key_index": key_index,
                    "tier": tier.value,
                    "model_name": model_config.name,
                    "start_time": attempt_start,
                    "circuit_key": circuit_key,
                }

                try:
                    # Check rate limit before request
                    if not scene.increment_usage(key_index):
                        attempt_metadata["error"] = "rate_limited"
                        attempt_metadata["fallback_reason"] = "rate_limited"
                        metadata["attempts"].append(attempt_metadata)
                        excluded_keys.append(key_index)

                        key_index = self._find_healthy_available_key(scene, model_alias, excluded_keys)
                        if key_index is None:
                            raise RuntimeError("All API keys exhausted")
                        continue

                    # Execute with retry logic
                    response, extra_metadata = self._execute_with_retry(
                        request_func, scene, model_config, key_index, attempt_metadata, circuit
                    )

                    # Success!
                    attempt_metadata["success"] = True
                    attempt_metadata["latency"] = time.time() - attempt_start
                    attempt_metadata.update(extra_metadata)
                    metadata["attempts"].append(attempt_metadata)
                    metadata["final_key"] = key_index
                    metadata["final_model"] = model_config.name
                    metadata["total_latency"] = time.time() - start_time

                    # Record health success
                    self._health_monitor.record_request(circuit_key, True, attempt_metadata["latency"] * 1000)
                    circuit.record_success()

                    return response, metadata

                except Exception as e:
                    latency = time.time() - attempt_start
                    attempt_metadata["success"] = False
                    attempt_metadata["error"] = str(e)
                    attempt_metadata["latency"] = latency

                    # Record health failure
                    self._health_monitor.record_request(circuit_key, False, latency * 1000, str(e))
                    circuit.record_failure()

                    metadata["circuit_breaker_events"].append({
                        "key": circuit_key,
                        "action": "failure_recorded",
                        "state": circuit.state.value,
                        "failure_count": circuit.failure_count
                    })

                    # Determine fallback reason
                    if "429" in str(e) or "rate limit" in str(e).lower():
                        attempt_metadata["fallback_reason"] = "rate_limited"
                        excluded_keys.append(key_index)
                    elif "timeout" in str(e).lower():
                        attempt_metadata["fallback_reason"] = "timeout"
                    else:
                        attempt_metadata["fallback_reason"] = "error"

                    metadata["attempts"].append(attempt_metadata)

                    # Release usage since request failed
                    scene.release_usage(key_index)

                    # Try next key
                    key_index = self._find_healthy_available_key(scene, model_alias, excluded_keys)
                    if key_index is None:
                        metadata["total_latency"] = time.time() - start_time
                        metadata["fallback_reason"] = "all_exhausted"
                        raise RuntimeError(f"All fallback attempts failed for {model_alias} in {scene_id}")

                    continue

            # All fallback attempts failed
            metadata["total_latency"] = time.time() - start_time
            metadata["fallback_reason"] = "all_exhausted"
            raise RuntimeError(f"All fallback attempts failed for {model_alias} in {scene_id}")

    def _execute_with_retry(
        self,
        request_func: Callable,
        scene,
        model_config,
        key_index: int,
        attempt_metadata: Dict,
        circuit: CircuitBreaker
    ) -> Tuple[Any, Dict]:
        """Execute request with exponential backoff retry."""
        last_exception = None

        for retry in range(self.retry_config.max_retries + 1):
            try:
                response, extra_metadata = request_func(scene, model_config, key_index)

                # Check if response indicates an error that should trigger retry
                if self._is_retryable_response(response):
                    raise RuntimeError(f"Retryable response: {response}")

                return response, extra_metadata

            except Exception as e:
                last_exception = e
                attempt_metadata[f"retry_{retry}"] = str(e)

                if retry < self.retry_config.max_retries:
                    delay = self._calculate_backoff(retry)
                    logger.warning(f"Request failed (retry {retry + 1}/{self.retry_config.max_retries}), waiting {delay:.1f}s: {e}")
                    time.sleep(delay)
                else:
                    logger.error(f"All retries exhausted for {circuit.key}: {e}")

        # All retries failed
        raise last_exception

    def _calculate_backoff(self, retry: int) -> float:
        """Calculate exponential backoff with jitter."""
        delay = min(
            self.retry_config.base_delay_seconds * (self.retry_config.exponential_base ** retry),
            self.retry_config.max_delay_seconds
        )
        if self.retry_config.jitter:
            delay = delay * (0.5 + random.random())  # 50-150% of calculated delay
        return delay

    def _is_retryable_response(self, response: Any) -> bool:
        """Check if response indicates a retryable error."""
        if isinstance(response, dict):
            error = response.get("error", "")
            if error:
                error_lower = error.lower()
                retryable_errors = ["timeout", "503", "504", "502", "overloaded", "rate limit", "429"]
                return any(err in error_lower for err in retryable_errors)
        return False

    def _find_healthy_available_key(
        self,
        scene,
        model_alias: str,
        exclude_keys: List[int]
    ) -> Optional[int]:
        """Find an available key that is also healthy."""
        chain = scene.get_fallback_chain(model_alias)

        for key_index in range(scene.api_key_count):
            if key_index in exclude_keys:
                continue

            # Check if key is not rate limited
            if scene.is_key_exhausted(key_index):
                continue

            # Check if we have models for this key
            available_models = scene.get_available_models(key_index)
            if not available_models:
                continue

            # Check circuit breaker for first tier
            circuit_key = self._get_circuit_key(scene.scene_id, key_index, chain[0].value)
            circuit = self._get_or_create_circuit(circuit_key)

            if not circuit.can_execute():
                continue

            # Check health monitor
            if not self._health_monitor.is_healthy(circuit_key):
                logger.debug(f"Key {circuit_key} is unhealthy, skipping")
                continue

            return key_index

        return None

    def _handle_all_keys_exhausted(
        self,
        scene,
        model_alias: str,
        request_func: Callable,
        metadata: Dict,
        start_time: float,
        chain: List,
        excluded_keys: List[int]
    ) -> Tuple[Any, Dict]:
        """Handle case when all keys are exhausted."""
        # Find the key with shortest wait time
        min_wait_time = float('inf')
        best_key = None

        for i in range(scene.api_key_count):
            wait_time = scene.wait_time_for_key(i)
            if wait_time < min_wait_time:
                min_wait_time = wait_time
                best_key = i

        if min_wait_time < float('inf') and min_wait_time < 30:  # Max 30s wait
            logger.info(f"All keys exhausted, waiting {min_wait_time:.1f}s for key {best_key}")
            time.sleep(min_wait_time)

            # Retry with the best key
            key_index = best_key
            for tier_index, tier in enumerate(chain):
                circuit_key = self._get_circuit_key(scene.scene_id, key_index, tier.value)
                circuit = self._get_or_create_circuit(circuit_key)

                if not circuit.can_execute():
                    continue

                model_config = None
                for model in scene.models:
                    if (model.api_key_index == key_index and
                        model.tier == tier and
                        model.enabled):
                        model_config = model
                        break

                if not model_config:
                    continue

                attempt_start = time.time()
                attempt_metadata = {
                    "key_index": key_index,
                    "tier": tier.value,
                    "model_name": model_config.name,
                    "start_time": attempt_start,
                    "circuit_key": circuit_key,
                    "after_wait": True
                }

                try:
                    if not scene.increment_usage(key_index):
                        continue

                    response, extra_metadata = self._execute_with_retry(
                        request_func, scene, model_config, key_index, attempt_metadata, circuit
                    )

                    attempt_metadata["success"] = True
                    attempt_metadata["latency"] = time.time() - attempt_start
                    attempt_metadata.update(extra_metadata)
                    metadata["attempts"].append(attempt_metadata)
                    metadata["final_key"] = key_index
                    metadata["final_model"] = model_config.name
                    metadata["total_latency"] = time.time() - start_time

                    self._health_monitor.record_request(circuit_key, True, attempt_metadata["latency"] * 1000)
                    circuit.record_success()

                    return response, metadata

                except Exception as e:
                    latency = time.time() - attempt_start
                    attempt_metadata["success"] = False
                    attempt_metadata["error"] = str(e)
                    attempt_metadata["latency"] = latency

                    self._health_monitor.record_request(circuit_key, False, latency * 1000, str(e))
                    circuit.record_failure()
                    metadata["attempts"].append(attempt_metadata)
                    scene.release_usage(key_index)
                    continue

        # Truly all exhausted
        metadata["total_latency"] = time.time() - start_time
        metadata["fallback_reason"] = "all_exhausted"
        raise RuntimeError(f"All API keys exhausted for {model_alias} in {scene.scene_id}")

    def get_circuit_status(self) -> Dict[str, Dict[str, Any]]:
        """Get status of all circuit breakers."""
        with self._lock:
            return {key: cb.get_status() for key, cb in self._circuit_breakers.items()}

    def get_health_status(self) -> Dict[str, Dict[str, Any]]:
        """Get health status for all keys."""
        return self._health_monitor.get_all_health()

    def get_fallback_status(self) -> Dict[str, Any]:
        """Get comprehensive fallback status."""
        return {
            "circuit_breakers": self.get_circuit_status(),
            "health": self.get_health_status(),
        }

    def reset_circuit(self, scene_id: str, key_index: int, tier: str) -> None:
        """Manually reset a circuit breaker."""
        circuit_key = self._get_circuit_key(scene_id, key_index, tier)
        with self._lock:
            if circuit_key in self._circuit_breakers:
                self._circuit_breakers[circuit_key] = CircuitBreaker(circuit_key, self.circuit_config)
                logger.info(f"Manually reset circuit breaker: {circuit_key}")

    def force_close_circuit(self, scene_id: str, key_index: int, tier: str) -> None:
        """Force a circuit breaker to CLOSED state."""
        circuit_key = self._get_circuit_key(scene_id, key_index, tier)
        with self._lock:
            if circuit_key in self._circuit_breakers:
                cb = self._circuit_breakers[circuit_key]
                cb.state = CircuitState.CLOSED
                cb.failure_count = 0
                cb.success_count = 0
                logger.info(f"Force closed circuit breaker: {circuit_key}")