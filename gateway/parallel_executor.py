"""
Autonomous Parallelization (Fan-Out) for MyClaude Gateway.

Provides:
- Concurrent request execution across multiple API keys/models
- Configurable fan-out strategies (race, best-of-n, consensus)
- Result aggregation and selection
- Timeout and failure handling
- Resource-aware parallelism limits
"""
import time
import threading
import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Callable, Any, Tuple, Union
from enum import Enum
from concurrent.futures import ThreadPoolExecutor, Future, as_completed
from collections import deque
import uuid

logger = logging.getLogger(__name__)


class FanOutStrategy(str, Enum):
    """Strategies for fanning out requests."""
    RACE = "race"                    # First successful response wins
    BEST_OF_N = "best_of_n"          # Collect N responses, pick best
    CONSENSUS = "consensus"          # Require agreement from majority
    ALL = "all"                      # Wait for all to complete
    PARALLEL_KEYS = "parallel_keys"  # Try same model on multiple keys


class AggregationMethod(str, Enum):
    """Methods for aggregating multiple responses."""
    FIRST_SUCCESS = "first_success"
    LOWEST_LATENCY = "lowest_latency"
    HIGHEST_QUALITY = "highest_quality"
    MAJORITY_VOTE = "majority_vote"
    WEIGHTED_SCORE = "weighted_score"


@dataclass
class FanOutConfig:
    """Configuration for fan-out execution."""
    strategy: FanOutStrategy = FanOutStrategy.RACE
    max_parallel: int = 5             # Max concurrent executions
    timeout_seconds: float = 30.0     # Overall timeout
    min_responses: int = 1            # Minimum responses for BEST_OF_N/CONSENSUS
    aggregation: AggregationMethod = AggregationMethod.FIRST_SUCCESS
    enable_fallback_on_failure: bool = True
    collect_all_results: bool = False  # Whether to return all results


@dataclass
class ExecutionRequest:
    """A single execution request in a fan-out."""
    request_id: str
    scene_id: str
    model_alias: str
    key_index: int
    model_config: Any
    request_func: Callable
    priority: int = 0


@dataclass
class ExecutionResult:
    """Result of a single execution."""
    request_id: str
    success: bool
    response: Any = None
    metadata: Dict = field(default_factory=dict)
    error: Optional[str] = None
    latency_ms: float = 0.0
    key_index: int = -1
    model_name: str = ""


@dataclass
class FanOutResult:
    """Aggregated result of fan-out execution."""
    success: bool
    primary_response: Any = None
    primary_metadata: Dict = field(default_factory=dict)
    all_results: List[ExecutionResult] = field(default_factory=list)
    strategy_used: FanOutStrategy = FanOutStrategy.RACE
    total_latency_ms: float = 0.0
    successful_count: int = 0
    failed_count: int = 0
    error: Optional[str] = None


class ParallelExecutor:
    """
    Manages parallel execution of requests across multiple keys/models.

    Features:
    - Thread pool for concurrent execution
    - Configurable fan-out strategies
    - Result aggregation
    - Resource-aware parallelism limits
    - Integration with circuit breakers and health monitors
    """

    def __init__(
        self,
        fallback_manager,
        resilient_fallback=None,
        config: Optional[FanOutConfig] = None
    ):
        self.fallback_manager = fallback_manager
        self.resilient_fallback = resilient_fallback
        self.config = config or FanOutConfig()

        self._lock = threading.RLock()
        self._executor: Optional[ThreadPoolExecutor] = None
        self._active_executions: Dict[str, List[Future]] = {}
        self._execution_history: deque = deque(maxlen=1000)
        self._stats = {
            "total_fanouts": 0,
            "successful_fanouts": 0,
            "failed_fanouts": 0,
            "total_executions": 0,
            "total_latency_ms": 0.0,
        }

    def start(self, max_workers: Optional[int] = None) -> None:
        """Start the thread pool executor."""
        with self._lock:
            if self._executor is not None:
                logger.warning("Parallel executor already started")
                return

            workers = max_workers or self.config.max_parallel
            self._executor = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="fanout-")
            logger.info(f"Parallel executor started with {workers} workers")

    def stop(self, wait: bool = True) -> None:
        """Stop the thread pool executor."""
        with self._lock:
            if self._executor:
                self._executor.shutdown(wait=wait)
                self._executor = None
                logger.info("Parallel executor stopped")

    def execute_fanout(
        self,
        scene_id: str,
        model_alias: str,
        request_func: Callable,
        key_indices: Optional[List[int]] = None,
        model_tiers: Optional[List[str]] = None,
        custom_config: Optional[FanOutConfig] = None
    ) -> FanOutResult:
        """
        Execute a request across multiple keys/tiers in parallel.

        Args:
            scene_id: Scene to use
            model_alias: Model alias (e.g., "claude-opus-5")
            request_func: Function to execute for each key/tier
            key_indices: Specific key indices to use (None = all available)
            model_tiers: Specific tiers to try (None = all in chain)
            custom_config: Override default fan-out config

        Returns:
            FanOutResult with aggregated response
        """
        config = custom_config or self.config
        fanout_id = str(uuid.uuid4())[:8]
        start_time = time.time()

        logger.info(f"Starting fan-out {fanout_id}: {config.strategy.value} on {scene_id}/{model_alias}")

        # Get scene
        scene = self.fallback_manager.get_scene(scene_id)
        if not scene:
            return FanOutResult(
                success=False,
                error=f"Scene not found: {scene_id}",
                strategy_used=config.strategy
            )

        # Determine key indices and tiers to use
        chain = scene.get_fallback_chain(model_alias)
        tiers_to_use = model_tiers or [t.value for t in chain]
        keys_to_use = self._resolve_key_indices(scene, key_indices, tiers_to_use)

        if not keys_to_use:
            return FanOutResult(
                success=False,
                error="No available keys for fan-out",
                strategy_used=config.strategy
            )

        # Limit parallelism
        keys_to_use = keys_to_use[:config.max_parallel]

        # Create execution requests
        requests = self._create_execution_requests(
            fanout_id, scene, model_alias, keys_to_use, tiers_to_use, request_func
        )

        # Execute based on strategy
        if config.strategy == FanOutStrategy.RACE:
            result = self._execute_race(requests, config, start_time)
        elif config.strategy == FanOutStrategy.BEST_OF_N:
            result = self._execute_best_of_n(requests, config, start_time)
        elif config.strategy == FanOutStrategy.CONSENSUS:
            result = self._execute_consensus(requests, config, start_time)
        elif config.strategy == FanOutStrategy.ALL:
            result = self._execute_all(requests, config, start_time)
        elif config.strategy == FanOutStrategy.PARALLEL_KEYS:
            result = self._execute_parallel_keys(requests, config, start_time)
        else:
            result = self._execute_race(requests, config, start_time)

        result.strategy_used = config.strategy
        result.total_latency_ms = (time.time() - start_time) * 1000

        # Update stats
        with self._lock:
            self._stats["total_fanouts"] += 1
            self._stats["total_executions"] += len(requests)
            self._stats["total_latency_ms"] += result.total_latency_ms
            if result.success:
                self._stats["successful_fanouts"] += 1
            else:
                self._stats["failed_fanouts"] += 1

            # Record in history
            self._execution_history.append({
                "fanout_id": fanout_id,
                "scene_id": scene_id,
                "model_alias": model_alias,
                "strategy": config.strategy.value,
                "keys_used": len(requests),
                "success": result.success,
                "latency_ms": result.total_latency_ms,
                "timestamp": start_time,
            })

        logger.info(f"Fan-out {fanout_id} completed: success={result.success}, "
                   f"latency={result.total_latency_ms:.1f}ms, "
                   f"successful={result.successful_count}/{len(requests)}")

        return result

    def _resolve_key_indices(
        self,
        scene,
        key_indices: Optional[List[int]],
        tiers: List[str]
    ) -> List[int]:
        """Resolve which key indices to use."""
        if key_indices is not None:
            # Use specified keys, filter to valid ones
            return [k for k in key_indices if 0 <= k < scene.api_key_count and not scene.is_key_exhausted(k)]

        # Use all available keys that have models for the first tier
        available = []
        first_tier = tiers[0] if tiers else None
        for i in range(scene.api_key_count):
            if scene.is_key_exhausted(i):
                continue
            models = scene.get_available_models(i)
            if first_tier and not any(m.tier.value == first_tier for m in models):
                continue
            if models:
                available.append(i)

        return available

    def _create_execution_requests(
        self,
        fanout_id: str,
        scene,
        model_alias: str,
        key_indices: List[int],
        tiers: List[str],
        request_func: Callable
    ) -> List[ExecutionRequest]:
        """Create execution requests for each key/tier combination."""
        requests = []
        for key_index in key_indices:
            for tier_name in tiers:
                # Find model config for this key and tier
                model_config = None
                for model in scene.models:
                    if (model.api_key_index == key_index and
                        model.tier.value == tier_name and
                        model.enabled):
                        model_config = model
                        break

                if not model_config:
                    continue

                request_id = f"{fanout_id}-k{key_index}-{tier_name}"
                requests.append(ExecutionRequest(
                    request_id=request_id,
                    scene_id=scene.scene_id,
                    model_alias=model_alias,
                    key_index=key_index,
                    model_config=model_config,
                    request_func=request_func,
                ))

        return requests

    def _execute_single(self, request: ExecutionRequest) -> ExecutionResult:
        """Execute a single request."""
        start_time = time.time()
        scene = self.fallback_manager.get_scene(request.scene_id)

        try:
            # Check rate limit
            if scene and not scene.increment_usage(request.key_index):
                return ExecutionResult(
                    request_id=request.request_id,
                    success=False,
                    error="rate_limited",
                    latency_ms=(time.time() - start_time) * 1000,
                    key_index=request.key_index,
                    model_name=request.model_config.name
                )

            # Execute request
            response, metadata = request.request_func(
                self.fallback_manager.get_scene(request.scene_id),
                request.model_config,
                request.key_index
            )

            latency_ms = (time.time() - start_time) * 1000

            # Check if response is successful
            success = response.get("content") is not None or response.get("litellm_params") is not None

            return ExecutionResult(
                request_id=request.request_id,
                success=success,
                response=response,
                metadata=metadata,
                error=None if success else "empty_response",
                latency_ms=latency_ms,
                key_index=request.key_index,
                model_name=request.model_config.name
            )

        except Exception as e:
            latency_ms = (time.time() - start_time) * 1000
            # Release usage on failure
            if scene:
                scene.release_usage(request.key_index)
            return ExecutionResult(
                request_id=request.request_id,
                success=False,
                error=str(e),
                latency_ms=latency_ms,
                key_index=request.key_index,
                model_name=request.model_config.name
            )

    def _execute_race(
        self,
        requests: List[ExecutionRequest],
        config: FanOutConfig,
        start_time: float
    ) -> FanOutResult:
        """Race strategy: first successful response wins."""
        if not self._executor:
            self.start()

        futures = {self._executor.submit(self._execute_single, req): req for req in requests}
        results = []
        winner = None

        try:
            for future in as_completed(futures, timeout=config.timeout_seconds):
                result = future.result()
                results.append(result)

                if result.success and winner is None:
                    winner = result
                    # Cancel remaining futures
                    for f in futures:
                        if not f.done():
                            f.cancel()
                    break

        except TimeoutError:
            # Cancel all remaining
            for f in futures:
                f.cancel()
            logger.warning(f"Race fan-out timed out after {config.timeout_seconds}s")

        successful = [r for r in results if r.success]
        if winner:
            return FanOutResult(
                success=True,
                primary_response=winner.response,
                primary_metadata=winner.metadata,
                all_results=results if config.collect_all_results else [winner],
                successful_count=len(successful),
                failed_count=len(results) - len(successful)
            )
        elif successful:
            # Shouldn't happen in race, but handle it
            best = min(successful, key=lambda r: r.latency_ms)
            return FanOutResult(
                success=True,
                primary_response=best.response,
                primary_metadata=best.metadata,
                all_results=results if config.collect_all_results else [best],
                successful_count=len(successful),
                failed_count=len(results) - len(successful)
            )
        else:
            return FanOutResult(
                success=False,
                all_results=results if config.collect_all_results else [],
                successful_count=0,
                failed_count=len(results),
                error="All parallel executions failed"
            )

    def _execute_best_of_n(
        self,
        requests: List[ExecutionRequest],
        config: FanOutConfig,
        start_time: float
    ) -> FanOutResult:
        """Best-of-N strategy: collect N responses, pick best."""
        if not self._executor:
            self.start()

        futures = {self._executor.submit(self._execute_single, req): req for req in requests}
        results = []

        try:
            for future in as_completed(futures, timeout=config.timeout_seconds):
                results.append(future.result())
                if len([r for r in results if r.success]) >= config.min_responses:
                    # Got enough successful responses, can stop early
                    for f in futures:
                        if not f.done():
                            f.cancel()
                    break
        except TimeoutError:
            for f in futures:
                f.cancel()
            logger.warning(f"Best-of-N fan-out timed out after {config.timeout_seconds}s")

        successful = [r for r in results if r.success]
        if not successful:
            return FanOutResult(
                success=False,
                all_results=results if config.collect_all_results else [],
                successful_count=0,
                failed_count=len(results),
                error="No successful responses"
            )

        # Pick best based on aggregation method
        if config.aggregation == AggregationMethod.LOWEST_LATENCY:
            best = min(successful, key=lambda r: r.latency_ms)
        elif config.aggregation == AggregationMethod.HIGHEST_QUALITY:
            best = self._pick_highest_quality(successful)
        else:
            best = successful[0]  # FIRST_SUCCESS

        return FanOutResult(
            success=True,
            primary_response=best.response,
            primary_metadata=best.metadata,
            all_results=results if config.collect_all_results else [best],
            successful_count=len(successful),
            failed_count=len(results) - len(successful)
        )

    def _execute_consensus(
        self,
        requests: List[ExecutionRequest],
        config: FanOutConfig,
        start_time: float
    ) -> FanOutResult:
        """Consensus strategy: require majority agreement."""
        if not self._executor:
            self.start()

        futures = {self._executor.submit(self._execute_single, req): req for req in requests}
        results = []

        try:
            for future in as_completed(futures, timeout=config.timeout_seconds):
                results.append(future.result())
        except TimeoutError:
            for f in futures:
                f.cancel()
            logger.warning(f"Consensus fan-out timed out after {config.timeout_seconds}s")

        successful = [r for r in results if r.success]
        if len(successful) < config.min_responses:
            return FanOutResult(
                success=False,
                all_results=results if config.collect_all_results else [],
                successful_count=len(successful),
                failed_count=len(results) - len(successful),
                error=f"Consensus not reached: {len(successful)}/{config.min_responses} successful"
            )

        # For consensus, we could compare responses, but for now pick first
        return FanOutResult(
            success=True,
            primary_response=successful[0].response,
            primary_metadata=successful[0].metadata,
            all_results=results if config.collect_all_results else successful,
            successful_count=len(successful),
            failed_count=len(results) - len(successful)
        )

    def _execute_all(
        self,
        requests: List[ExecutionRequest],
        config: FanOutConfig,
        start_time: float
    ) -> FanOutResult:
        """All strategy: wait for all to complete."""
        if not self._executor:
            self.start()

        futures = {self._executor.submit(self._execute_single, req): req for req in requests}
        results = []

        try:
            for future in as_completed(futures, timeout=config.timeout_seconds):
                results.append(future.result())
        except TimeoutError:
            for f in futures:
                f.cancel()
            logger.warning(f"All fan-out timed out after {config.timeout_seconds}s")

        successful = [r for r in results if r.success]
        if not successful:
            return FanOutResult(
                success=False,
                all_results=results if config.collect_all_results else [],
                successful_count=0,
                failed_count=len(results),
                error="All executions failed"
            )

        # Pick best
        best = min(successful, key=lambda r: r.latency_ms)
        return FanOutResult(
            success=True,
            primary_response=best.response,
            primary_metadata=best.metadata,
            all_results=results if config.collect_all_results else [best],
            successful_count=len(successful),
            failed_count=len(results) - len(successful)
        )

    def _execute_parallel_keys(
        self,
        requests: List[ExecutionRequest],
        config: FanOutConfig,
        start_time: float
    ) -> FanOutResult:
        """Parallel keys: try same model on multiple keys."""
        # Group by tier, race within each tier
        # For simplicity, use race strategy
        return self._execute_race(requests, config, start_time)

    def _pick_highest_quality(self, results: List[ExecutionResult]) -> ExecutionResult:
        """Pick highest quality response (based on tokens, model tier, etc.)."""
        # Simple heuristic: prefer responses with more tokens, then lower latency
        def quality_score(r: ExecutionResult) -> float:
            tokens = 0
            if r.response and isinstance(r.response, dict):
                tokens = r.response.get("tokens", {}).get("total_tokens", 0)
            return tokens / max(r.latency_ms, 1) if tokens > 0 else 1.0 / max(r.latency_ms, 1)

        return max(results, key=quality_score)

    def get_stats(self) -> Dict[str, Any]:
        """Get executor statistics."""
        with self._lock:
            avg_latency = self._stats["total_latency_ms"] / max(self._stats["total_fanouts"], 1)
            return {
                "total_fanouts": self._stats["total_fanouts"],
                "successful_fanouts": self._stats["successful_fanouts"],
                "failed_fanouts": self._stats["failed_fanouts"],
                "success_rate": self._stats["successful_fanouts"] / max(self._stats["total_fanouts"], 1),
                "total_executions": self._stats["total_executions"],
                "avg_latency_ms": avg_latency,
                "active_executions": len(self._active_executions),
                "history_size": len(self._execution_history),
            }

    def get_recent_history(self, limit: int = 10) -> List[Dict]:
        """Get recent execution history."""
        with self._lock:
            return list(self._execution_history)[-limit:]


# Global instance for convenience
_parallel_executor: Optional[ParallelExecutor] = None


def get_parallel_executor(
    fallback_manager,
    resilient_fallback=None,
    config: Optional[FanOutConfig] = None
) -> ParallelExecutor:
    """Get or create the global parallel executor instance."""
    global _parallel_executor
    if _parallel_executor is None:
        _parallel_executor = ParallelExecutor(fallback_manager, resilient_fallback, config)
    return _parallel_executor