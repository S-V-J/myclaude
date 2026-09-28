"""
Manages scene-based model fallback chains with API key rotation.

Handles:
- Scene configurations with 5 API keys each
- Fallback chain: Ultra -> Super -> Ultra per key
- Key rotation on rate limit or failure
- Model selection per scene
"""
import time
import threading
from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, List, Optional, Tuple
from .rate_limiter import RateLimiter, SlidingWindowRateLimiter


class ModelTier(str, Enum):
    """Model tiers in the fallback chain."""
    ULTRA_550B = "nemotron-3-ultra-550b-a55b"
    SUPER_120B = "nemotron-3-super-120b-a12b"


class FallbackReason(str, Enum):
    """Reason for falling back to next option."""
    RATE_LIMITED = "rate_limited"
    ERROR = "error"
    TIMEOUT = "timeout"
    UNAVAILABLE = "unavailable"


@dataclass
class ModelConfig:
    """Configuration for a specific model."""
    name: str
    model_id: str
    tier: ModelTier
    api_key_index: int  # 0-4 for the 5 API keys in scene
    max_tokens: int = 16384
    temperature: float = 1.0
    top_p: float = 0.95
    timeout: int = 120000
    enabled: bool = True

    def to_dict(self) -> dict:
        """Convert to dictionary for LiteLLM config."""
        return {
            "model_name": self.name,
            "litellm_params": {
                "model": self.model_id,
                "api_key": f"os.environ/NVIDIA_API_KEY_{self.api_key_index + 1}",
                "max_tokens": self.max_tokens,
                "temperature": self.temperature,
                "top_p": self.top_p,
                "drop_params": True,
                "num_retries": 3,
                "timeout": self.timeout,
                "chat_template_kwargs": {"enable_thinking": True}
            },
            "model_info": {"mode": "chat"}
        }


@dataclass
class SceneConfig:
    """Configuration for a scene with 5 API keys and fallback chains."""
    scene_id: str
    name: str
    api_key_count: int = 5
    models: List[ModelConfig] = field(default_factory=list)
    fallback_chains: Dict[str, List[ModelTier]] = field(default_factory=dict)
    rate_limiter: Optional[RateLimiter] = None

    def __post_init__(self):
        if self.rate_limiter is None:
            self.rate_limiter = SlidingWindowRateLimiter()

        # Initialize default fallback chains if not provided
        if not self.fallback_chains:
            self.fallback_chains = {
                "claude-opus-5": [ModelTier.ULTRA_550B, ModelTier.SUPER_120B, ModelTier.ULTRA_550B],
                "claude-sonnet-5": [ModelTier.SUPER_120B, ModelTier.ULTRA_550B, ModelTier.SUPER_120B],
                "claude-haiku-5": [ModelTier.SUPER_120B, ModelTier.ULTRA_550B, ModelTier.SUPER_120B],  # Simplified
            }

        # Generate model configs for each API key in each fallback chain
        if not self.models:
            self._generate_model_configs()

    def _generate_model_configs(self):
        """Generate model configs for the standard fallback chains."""
        for model_alias, chain in self.fallback_chains.items():
            for idx, tier in enumerate(chain):
                # Distribute across API keys (round-robin)
                api_key_index = idx % self.api_key_count

                model_name = f"{self.scene_id}-{model_alias}-key{api_key_index + 1}-tier{idx + 1}"
                model_config = ModelConfig(
                    name=model_name,
                    model_id=tier.value,
                    tier=tier,
                    api_key_index=api_key_index,
                    max_tokens=16384,
                    temperature=1.0,
                    top_p=0.95
                )
                self.models.append(model_config)

    def get_fallback_chain(self, model_alias: str) -> List[ModelTier]:
        """Get the fallback chain for a model alias."""
        return self.fallback_chains.get(model_alias, [ModelTier.SUPER_120B])

    def get_available_models(self, key_index: int) -> List[ModelConfig]:
        """Get all models available for a specific API key."""
        return [m for m in self.models if m.api_key_index == key_index and m.enabled]

    def increment_usage(self, api_key_index: int) -> bool:
        """
        Increment usage for an API key and check if allowed.

        Returns:
            True if request is allowed, False if rate limited
        """
        key = f"{self.scene_id}_key_{api_key_index}"
        allowed = self.rate_limiter.acquire(key)
        return allowed

    def release_usage(self, api_key_index: int) -> None:
        """Release usage tracking (for error cleanup)."""
        key = f"{self.scene_id}_key_{api_key_index}"
        self.rate_limiter.release(key)

    def get_key_usage(self, api_key_index: int) -> Tuple[int, int]:
        """Get usage stats for a specific API key."""
        key = f"{self.scene_id}_key_{api_key_index}"
        return self.rate_limiter.get_usage(key)

    def is_key_exhausted(self, api_key_index: int) -> bool:
        """Check if a specific API key is exhausted."""
        key = f"{self.scene_id}_key_{api_key_index}"
        return self.rate_limiter.is_exhausted(key)

    def wait_time_for_key(self, api_key_index: int) -> float:
        """Get wait time for an API key to become available."""
        key = f"{self.scene_id}_key_{api_key_index}"
        return self.rate_limiter.get_wait_time(key)


class FallbackManager:
    """
    Manages fallback logic across scenes with rate limiting.

    Coordinates:
    - Scene selection (1-5)
    - API key rotation within scene (1-5)
    - Model fallback within key (Ultra -> Super -> Ultra)
    """

    def __init__(self):
        self.scenes: Dict[str, SceneConfig] = {}
        self._scene_order = ["scene_1_default", "scene_2_opus_1m", "scene_3_sonnet",
                            "scene_4_sonnet_1m", "scene_5_vision"]
        self._lock = threading.RLock()
        self._initialize_scenes()

    def _initialize_scenes(self):
        """Initialize all 5 scenes with their configurations."""
        # Scene 1: Default
        scene1 = SceneConfig(
            scene_id="scene_1_default",
            name="Default Scene",
            api_key_count=5
        )
        self.scenes[scene1.scene_id] = scene1

        # Scene 2: Opus 1M
        scene2 = SceneConfig(
            scene_id="scene_2_opus_1m",
            name="Opus 1M Context Scene",
            api_key_count=5
        )
        self.scenes[scene2.scene_id] = scene2

        # Scene 3: Sonnet
        scene3 = SceneConfig(
            scene_id="scene_3_sonnet",
            name="Sonnet Scene",
            api_key_count=5
        )
        self.scenes[scene3.scene_id] = scene3

        # Scene 4: Sonnet 1M
        scene4 = SceneConfig(
            scene_id="scene_4_sonnet_1m",
            name="Sonnet 1M Context Scene",
            api_key_count=5
        )
        self.scenes[scene4.scene_id] = scene4

        # Scene 5: Vision
        scene5 = SceneConfig(
            scene_id="scene_5_vision",
            name="Vision Scene",
            api_key_count=5
        )
        self.scenes[scene5.scene_id] = scene5

    def get_scene(self, scene_id: str) -> Optional[SceneConfig]:
        """Get a scene by ID."""
        with self._lock:
            return self.scenes.get(scene_id)

    def list_scenes(self) -> List[str]:
        """List all scene IDs."""
        with self._lock:
            return list(self.scenes.keys())

    def find_available_key(self, scene: SceneConfig,
                          model_alias: str,
                          exclude_keys: Optional[List[int]] = None) -> Optional[int]:
        """
        Find the next available API key for a scene and model alias.

        Args:
            scene: The scene configuration
            model_alias: The model alias to get fallback chain for
            exclude_keys: List of key indices to exclude (already tried/failed)

        Returns:
            Available key index or None if none available
        """
        exclude_keys = exclude_keys or []
        chain = scene.get_fallback_chain(model_alias)

        # Try each API key in order (0-4)
        for key_index in range(scene.api_key_count):
            if key_index in exclude_keys:
                continue

            # Check if key is not exhausted
            if not scene.is_key_exhausted(key_index):
                # Check if we have models for this key and tier combination
                available_models = scene.get_available_models(key_index)
                # For simplicity, we'll check if any model matches the first tier in chain
                # In practice, we'd match exact tier
                if available_models:
                    return key_index

        return None

    def execute_with_fallback(self, scene_id: str, model_alias: str,
                            request_func) -> Tuple[any, dict]:
        """
        Execute a request with full fallback logic.

        Args:
            scene_id: The scene to use
            model_alias: The model alias to request (e.g., "claude-opus-5")
            request_func: Function that takes (scene_config, model_config, api_key_index)
                         and returns (response, metadata)

        Returns:
            Tuple of (response, metadata) where metadata includes fallback info
        """
        with self._lock:
            scene = self.get_scene(scene_id)
            if not scene:
                raise ValueError(f"Scene not found: {scene_id}")

            metadata = {
                "scene_id": scene_id,
                "model_alias": model_alias,
                "attempts": [],
                "final_key": None,
                "final_model": None,
                "fallback_reason": None,
                "total_latency": 0.0
            }

            start_time = time.time()
            excluded_keys = []

            # Try to find an available key
            key_index = self.find_available_key(scene, model_alias, excluded_keys)

            if key_index is None:
                # All keys exhausted, wait for the earliest to become available
                min_wait_time = float('inf')
                best_key = None

                for i in range(scene.api_key_count):
                    wait_time = scene.wait_time_for_key(i)
                    if wait_time < min_wait_time:
                        min_wait_time = wait_time
                        best_key = i

                if min_wait_time < float('inf'):
                    # Wait for the best key
                    time.sleep(min_wait_time)
                    key_index = best_key
                else:
                    raise RuntimeError("All API keys exhausted and no wait time available")

            # Try the fallback chain for this key
            chain = scene.get_fallback_chain(model_alias)

            for tier_index, tier in enumerate(chain):
                # Find a model config matching this tier and key
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
                    "start_time": attempt_start
                }

                try:
                    # Check rate limit before request
                    if not scene.increment_usage(key_index):
                        attempt_metadata["error"] = "rate_limited"
                        attempt_metadata["fallback_reason"] = FallbackReason.RATE_LIMITED.value
                        metadata["attempts"].append(attempt_metadata)
                        excluded_keys.append(key_index)

                        # Try next key
                        key_index = self.find_available_key(scene, model_alias, excluded_keys)
                        if key_index is None:
                            raise RuntimeError("All API keys exhausted")
                        continue  # Retry with new key

                    # Execute the request
                    response, extra_metadata = request_func(scene, model_config, key_index)

                    # Success!
                    attempt_metadata["success"] = True
                    attempt_metadata["latency"] = time.time() - attempt_start
                    attempt_metadata.update(extra_metadata)
                    metadata["attempts"].append(attempt_metadata)
                    metadata["final_key"] = key_index
                    metadata["final_model"] = model_config.name
                    metadata["total_latency"] = time.time() - start_time

                    return response, metadata

                except Exception as e:
                    # Request failed, try fallback
                    attempt_metadata["success"] = False
                    attempt_metadata["error"] = str(e)
                    attempt_metadata["latency"] = time.time() - attempt_start

                    # Determine fallback reason
                    if "429" in str(e) or "rate limit" in str(e).lower():
                        attempt_metadata["fallback_reason"] = FallbackReason.RATE_LIMITED.value
                        # Add key to excluded list so we try a different key for next tier
                        excluded_keys.append(key_index)
                        key_index = self.find_available_key(scene, model_alias, excluded_keys)
                        if key_index is None:
                            metadata["attempts"].append(attempt_metadata)
                            raise RuntimeError("All API keys exhausted")
                    elif "timeout" in str(e).lower():
                        attempt_metadata["fallback_reason"] = FallbackReason.TIMEOUT.value
                    else:
                        attempt_metadata["fallback_reason"] = FallbackReason.ERROR.value

                    metadata["attempts"].append(attempt_metadata)

                    # Release the usage since we're not counting this failed request
                    scene.release_usage(key_index)

                    # Continue to next tier in chain
                    continue

            # If we get here, all fallback attempts failed
            metadata["total_latency"] = time.time() - start_time
            metadata["fallback_reason"] = FallbackReason.UNAVAILABLE.value
            raise RuntimeError(f"All fallback attempts failed for {model_alias} in {scene_id}")

    def get_scene_status(self) -> Dict[str, dict]:
        """Get status of all scenes including rate limiting info."""
        status = {}
        with self._lock:
            for scene_id, scene in self.scenes.items():
                key_usage = []
                for i in range(scene.api_key_count):
                    used, limit = scene.get_key_usage(i)
                    key_usage.append({
                        "key_index": i,
                        "used": used,
                        "limit": limit,
                        "available": limit - used,
                        "exhausted": scene.is_key_exhausted(i),
                        "wait_time": scene.wait_time_for_key(i)
                    })

                status[scene_id] = {
                    "name": scene.name,
                    "api_key_count": scene.api_key_count,
                    "key_usage": key_usage,
                    "total_models": len(scene.models),
                    "enabled_models": len([m for m in scene.models if m.enabled])
                }
        return status

    def reset_scene_rate_limits(self, scene_id: str) -> None:
        """Reset rate limits for a scene."""
        with self._lock:
            scene = self.get_scene(scene_id)
            if scene:
                for i in range(scene.api_key_count):
                    scene.rate_limiter.reset(f"{scene_id}_key_{i}")

    def disable_model(self, scene_id: str, model_name: str) -> bool:
        """Disable a specific model (for maintenance/failures)."""
        with self._lock:
            scene = self.get_scene(scene_id)
            if scene:
                for model in scene.models:
                    if model.name == model_name:
                        model.enabled = False
                        return True
        return False

    def enable_model(self, scene_id: str, model_name: str) -> bool:
        """Enable a specific model."""
        with self._lock:
            scene = self.get_scene(scene_id)
            if scene:
                for model in scene.models:
                    if model.name == model_name:
                        model.enabled = True
                        return True
        return False