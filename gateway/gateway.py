"""
Main API Gateway - Production-ready multi-scene gateway with fallback chains
and intelligent routing.
"""
import os
import time
import logging
import threading
import base64
import io
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Any, Callable, Tuple, Union
from enum import Enum

# Import gateway components
from .rate_limiter import RateLimiter, SlidingWindowRateLimiter, RateLimitConfig
from .fallback_manager import (
    FallbackManager, SceneConfig, ModelConfig,
    ModelTier, FallbackReason
)
from .ram_monitor import RAMMonitor, RAMMonitorConfig, RAMAwareRateLimiter, MemoryPressureLevel, MemoryStats
from .auto_compactor import AutoCompactor, CompactionConfig, CompactionTarget
from .resilient_fallback import ResilientFallbackManager
from .parallel_executor import ParallelExecutor, FanOutConfig, FanOutStrategy, AggregationMethod

logger = logging.getLogger(__name__)


class GatewayMode(str, Enum):
    """Gateway operation modes."""
    PRIMARY_ONLY = "primary_only"           # Use only NVIDIA NIM models
    PRIMARY_WITH_FALLBACK = "primary_fallback"  # Primary + key/model fallback


class RequestType(str, Enum):
    """Types of requests the gateway can handle."""
    CHAT = "chat"
    COMPLETION = "completion"
    EMBEDDING = "embedding"
    TOOL_CALL = "tool_call"
    VISION = "vision"
    STREAMING = "streaming"


@dataclass
class RequestContext:
    """Context for a gateway request."""
    scene_id: Optional[str] = None
    model_alias: str = "claude-opus-5"
    messages: List[Dict[str, Any]] = field(default_factory=list)
    max_tokens: int = 16384
    temperature: float = 0.7
    top_p: float = 0.95
    tools: Optional[List[Dict]] = None
    tool_choice: Optional[str] = None
    stream: bool = False
    images_present: bool = False
    required_capabilities: Dict[str, bool] = field(default_factory=dict)
    metadata: Dict[str, Any] = field(default_factory=dict)
    request_id: Optional[str] = None
    user_id: Optional[str] = None
    session_id: Optional[str] = None


@dataclass
class GatewayResponse:
    """Standardized gateway response."""
    success: bool
    content: Optional[str] = None
    tool_calls: Optional[List[Dict]] = None
    model_used: Optional[str] = None
    provider: Optional[str] = None
    scene_id: Optional[str] = None
    api_key_index: Optional[int] = None
    fallback_tier: int = 0
    latency_ms: float = 0.0
    tokens_used: Dict[str, int] = field(default_factory=dict)
    error: Optional[str] = None
    error_code: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)

    def to_openai_format(self) -> Dict[str, Any]:
        """Convert to OpenAI-compatible response format."""
        return {
            "id": self.metadata.get("request_id", "chatcmpl-" + str(int(time.time()))),
            "object": "chat.completion",
            "created": int(time.time()),
            "model": self.model_used or "unknown",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": self.content,
                    "tool_calls": self.tool_calls
                },
                "finish_reason": "stop" if self.success else "error"
            }],
            "usage": {
                "prompt_tokens": self.tokens_used.get("prompt_tokens", 0),
                "completion_tokens": self.tokens_used.get("completion_tokens", 0),
                "total_tokens": self.tokens_used.get("total_tokens", 0)
            }
        }


@dataclass
class GatewayConfig:
    """Configuration for the API Gateway."""
    mode: GatewayMode = GatewayMode.PRIMARY_WITH_FALLBACK
    default_scene: str = "scene_1_default"
    default_model_alias: str = "claude-opus-5"
    enable_intelligent_routing: bool = True
    request_timeout: int = 300000  # 5 minutes
    max_retries: int = 3
    log_level: str = "INFO"
    track_costs: bool = True


class APIGateway:
    """
    Production-ready Multi-Scene API Gateway.

    Features:
    - 5 scenes, each with 5 API keys (32 RPM per key)
    - Fallback chain: Ultra-550B -> Super-120B -> Ultra-550B per key
    - Key rotation on rate limit (429) or errors
    - NVIDIA NIM provider only
    - Intelligent task routing via BackendOrchestrator
    - Thread-safe operations
    - Comprehensive monitoring and metrics
    """

    def __init__(self, config: Optional[GatewayConfig] = None):
        self.config = config or GatewayConfig()
        self._setup_logging()

        # Initialize RAM monitor
        self.ram_monitor = RAMMonitor()
        self.ram_monitor.start()

        # Initialize core components
        self.fallback_manager = FallbackManager()
        # Wrap the fallback manager's rate limiter with RAM-aware throttling
        self._wrap_rate_limiter_with_ram_monitoring()

        # Initialize auto-compactor
        compaction_config = CompactionConfig(
            enabled=True,
            interval_seconds=300.0,  # 5 minutes
            targets=[
                CompactionTarget.RATE_LIMITER_WINDOWS,
                CompactionTarget.RATE_LIMITER_LOCKS,
                CompactionTarget.GATEWAY_ERRORS,
                CompactionTarget.FALLBACK_MANAGER_STATE,
                CompactionTarget.PYTHON_GC,
            ]
        )
        self.auto_compactor = AutoCompactor(compaction_config)
        self.auto_compactor.start()

        # Register components for compaction
        # Register the first scene's rate limiter as representative (all scenes have same structure)
        first_scene = next(iter(self.fallback_manager.scenes.values()), None)
        if first_scene and hasattr(first_scene, 'rate_limiter'):
            self.auto_compactor.register_rate_limiter(first_scene.rate_limiter)
        self.auto_compactor.register_gateway(self)
        self.auto_compactor.register_fallback_manager(self.fallback_manager)
        self.auto_compactor.register_ram_monitor(self.ram_monitor)

        # Initialize resilient fallback manager
        self.resilient_fallback = ResilientFallbackManager(self.fallback_manager)

        # Initialize parallel executor
        fanout_config = FanOutConfig(
            strategy=FanOutStrategy.RACE,
            max_parallel=5,
            timeout_seconds=30.0,
            min_responses=1,
            aggregation=AggregationMethod.FIRST_SUCCESS
        )
        self.parallel_executor = ParallelExecutor(self.fallback_manager, self.resilient_fallback, fanout_config)
        self.parallel_executor.start()

        # Gateway state
        self._lock = threading.RLock()
        self._request_count = 0
        self._total_latency = 0.0
        self._total_cost = 0.0
        self._errors: Dict[str, int] = {}

        # LiteLLM callback for actual execution
        self._litellm_callback: Optional[Callable] = None

        logger.info(f"APIGateway initialized in {self.config.mode.value} mode with RAM monitoring and auto-compaction")

    def _wrap_rate_limiter_with_ram_monitoring(self):
        """Wrap the fallback manager's rate limiter with RAM-aware throttling."""
        # The fallback manager creates its own rate limiter internally
        # We'll apply RAM-aware throttling at the gateway level in process_request
        pass

    def _preprocess_image_for_vision(self, image_data: bytes, source: str = "clipboard") -> bytes:
        """
        Preprocess image data pasted from clipboard for optimal vision model processing.

        Args:
            image_data: Raw image data from paste operation
            source: Source of the image (clipboard, file, etc.)

        Returns:
            Processed image data optimized for vision models
        """
        try:
            from PIL import Image

            # Load image from data
            image = Image.open(io.BytesIO(image_data))

            # Convert to RGB if necessary (removes alpha channel issues)
            if image.mode in ('RGBA', 'LA', 'P'):
                image = image.convert('RGB')

            # Optimize size for vision models (maintain aspect ratio)
            max_dimension = 1024
            if max(image.width, image.height) > max_dimension:
                ratio = max_dimension / max(image.width, image.height)
                new_width = int(image.width * ratio)
                new_height = int(image.height * ratio)
                image = image.resize((new_width, new_height), Image.Resampling.LANCZOS)

            # Convert back to bytes
            output = io.BytesIO()
            image.save(output, format='PNG', optimize=True)
            return output.getvalue()

        except Exception as e:
            logger.warning(f"Image preprocessing failed: {e}, using original data")
            return image_data

    def _detect_vision_from_clipboard_paste(self, context: RequestContext) -> tuple[bool, Optional[bytes]]:
        """
        Detect if a request contains pasted image content requiring vision processing.

        Args:
            context: The request context

        Returns:
            Tuple of (bool, image_data) - True if vision processing needed, and extracted image data if found
        """
        if not context.messages:
            return False, None

        # Check for clipboard/paste indicators in the message
        for message in context.messages:
            if isinstance(message, dict) and 'content' in message:
                content = message['content']

                # Handle both string content and list content (for multimodal messages)
                if isinstance(content, str):
                    content_lower = content.lower()
                    paste_indicators = [
                        'paste', 'clipboard', 'ctrl+v', 'ctrl v',
                        'pasted', 'copied from', 'screenshot',
                        'image attached', 'embedded image'
                    ]
                    if any(indicator in content_lower for indicator in paste_indicators):
                        # Check for base64 image data
                        if 'data:image/' in content or 'base64,' in content:
                            # Extract base64 image data
                            image_data = self._extract_base64_image(content)
                            return True, image_data
                        return True, None

                elif isinstance(content, list):
                    # Handle multimodal content (list of text and image blocks)
                    for block in content:
                        if isinstance(block, dict):
                            if block.get('type') == 'image':
                                # Extract image data from multimodal block
                                image_data = block.get('source', {}).get('data', '')
                                if image_data:
                                    if image_data.startswith('data:image/'):
                                        image_data = self._extract_base64_image(image_data)
                                    return True, self._preprocess_image_for_vision(
                                        base64.b64decode(image_data) if isinstance(image_data, str) else image_data
                                    )
                            elif block.get('type') == 'text':
                                text = block.get('text', '').lower()
                                paste_indicators = [
                                    'paste', 'clipboard', 'ctrl+v', 'ctrl v',
                                    'pasted', 'copied from', 'screenshot',
                                    'image attached', 'embedded image'
                                ]
                                if any(indicator in text for indicator in paste_indicators):
                                    return True, None

        return False, None

    def _extract_base64_image(self, content: str) -> bytes:
        """Extract base64 image data from content string."""
        try:
            # Find base64 data after 'base64,' or 'data:image/...;base64,'
            import re
            # Pattern to match base64 data after 'base64,'
            match = re.search(r'base64,([A-Za-z0-9+/=]+)', content)
            if match:
                return base64.b64decode(match.group(1))

            # Pattern to match data:image/...;base64,...
            match = re.search(r'data:image/[^;]+;base64,([A-Za-z0-9+/=]+)', content)
            if match:
                return base64.b64decode(match.group(1))

            return b''
        except Exception as e:
            logger.warning(f"Failed to extract base64 image: {e}")
            return b''

    def _inject_image_into_messages(self, context: RequestContext, image_data: bytes) -> None:
        """Inject preprocessed image data into request context messages."""
        try:
            # Convert image data to base64 for transmission
            image_base64 = base64.b64encode(image_data).decode('utf-8')

            # Create image block for multimodal content
            image_block = {
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": "image/png",
                    "data": image_base64
                }
            }

            # Add image block to the first message if it's a list, or create a new message
            if context.messages and isinstance(context.messages[0], dict) and 'content' in context.messages[0]:
                # If first message has content, make it a multimodal message
                if isinstance(context.messages[0]['content'], str):
                    # Convert text content to multimodal format
                    original_content = context.messages[0]['content']
                    context.messages[0]['content'] = [
                        {"type": "text", "text": original_content},
                        image_block
                    ]
                elif isinstance(context.messages[0]['content'], list):
                    # Already multimodal, append image block
                    context.messages[0]['content'].append(image_block)
                else:
                    # Unexpected format, replace with multimodal
                    context.messages[0]['content'] = [
                        {"type": "text", "text": str(context.messages[0]['content']) if context.messages[0]['content'] else ""},
                        image_block
                    ]
            else:
                # Create new message with image
                context.messages.insert(0, {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": ""},  # Empty text, image will carry the content
                        image_block
                    ]
                })

        except Exception as e:
            logger.warning(f"Failed to inject image into messages: {e}")

    def _setup_logging(self):
        """Configure logging."""
        logging.getLogger(__name__).setLevel(getattr(logging, self.config.log_level))

    def set_litellm_callback(self, callback: Callable):
        """
        Set the LiteLLM execution callback.

        Args:
            callback: Function that takes (model, messages, **kwargs) and returns response
        """
        self._litellm_callback = callback

    def _execute_with_litellm(self, model_config: ModelConfig,
                              messages: List[Dict],
                              **kwargs) -> Tuple[Dict, Dict]:
        """
        Execute request via LiteLLM callback or return params for external execution.

        Returns:
            Tuple of (response_dict, metadata_dict)
        """
        start_time = time.time()

        if self._litellm_callback:
            # Execute via provided callback (e.g., actual LiteLLM call)
            litellm_params = model_config.to_dict()["litellm_params"]
            litellm_params.update(kwargs)
            litellm_params["messages"] = messages

            try:
                response = self._litellm_callback(**litellm_params)
                latency = (time.time() - start_time) * 1000

                # Extract standard fields
                content = None
                tool_calls = None
                tokens = {}

                if hasattr(response, 'choices') and response.choices:
                    choice = response.choices[0]
                    if hasattr(choice, 'message'):
                        content = choice.message.content
                        tool_calls = getattr(choice.message, 'tool_calls', None)

                    if hasattr(response, 'usage'):
                        tokens = {
                            "prompt_tokens": response.usage.prompt_tokens,
                            "completion_tokens": response.usage.completion_tokens,
                            "total_tokens": response.usage.total_tokens
                        }

                return {
                    "content": content,
                    "tool_calls": tool_calls,
                    "tokens": tokens
                }, {
                    "latency_ms": latency,
                    "model": model_config.name,
                    "model_id": model_config.model_id
                }
            except Exception as e:
                latency = (time.time() - start_time) * 1000
                raise e
        else:
            # Return params for external execution
            litellm_params = model_config.to_dict()["litellm_params"]
            litellm_params.update(kwargs)
            litellm_params["messages"] = messages

            return {
                "content": None,
                "litellm_params": litellm_params
            }, {
                "latency_ms": 0,
                "model": model_config.name,
                "model_id": model_config.model_id,
                "needs_external_execution": True
            }

    def process_request(self, context: RequestContext) -> GatewayResponse:
        """
        Process a request through the gateway pipeline (NVIDIA NIM only).

        Args:
            context: RequestContext with all request parameters

        Returns:
            GatewayResponse with result or error
        """
        request_id = context.request_id or f"req_{int(time.time() * 1000)}"
        start_time = time.time()

        # Check memory pressure - reject if critical
        if self.ram_monitor.should_reject():
            logger.warning(f"Request {request_id} rejected: critical memory pressure")
            return GatewayResponse(
                success=False,
                error="Service temporarily unavailable: critical memory pressure",
                error_code="MEMORY_PRESSURE_CRITICAL",
                latency_ms=(time.time() - start_time) * 1000,
                metadata={"request_id": request_id, "memory_pressure": self.ram_monitor.get_current_pressure().value}
            )

        # Apply throttle factor if elevated/high pressure (could add delay or probabilistic rejection here)
        throttle_factor = self.ram_monitor.get_throttle_factor()
        if throttle_factor < 1.0:
            logger.info(f"Request {request_id}: applying throttle factor {throttle_factor} due to memory pressure")
            # For now, we just log the throttle factor. Could implement probabilistic rejection or delay.

        # ===== VISION PASTE DETECTION & AUTO-TRIGGER =====
        # Automatically detect pasted images and route to vision models
        vision_detected, image_data = self._detect_vision_from_clipboard_paste(context)
        if vision_detected:
            logger.info(f"Request {request_id}: Detected pasted image content, auto-routing to vision model")
            # Override scene and model for vision processing if not explicitly set
            if not context.scene_id:
                scene_id = "scene_5_vision"
            if not context.model_alias or context.model_alias in ["claude-opus-5", "claude-3-opus-20240229"]:
                model_alias = "claude-sonnet-5"  # Vision-capable model

            # If we extracted image data, preprocess and add to context
            if image_data:
                preprocessed_image = self._preprocess_image_for_vision(image_data)
                # Add preprocessed image to messages if not already present
                self._inject_image_into_messages(context, preprocessed_image)

        # Update stats
        with self._lock:
            self._request_count += 1

        # Determine scene (if not already set by vision detection)
        if 'scene_id' not in locals():
            scene_id = context.scene_id or self.config.default_scene
        if 'model_alias' not in locals():
            model_alias = context.model_alias or self.config.default_model_alias

        # Prepare request function for fallback manager
        def request_func(scene: SceneConfig, model_config: ModelConfig, key_index: int):
            return self._execute_with_litellm(model_config, context.messages,
                                              max_tokens=context.max_tokens,
                                              temperature=context.temperature,
                                              top_p=context.top_p,
                                              tools=context.tools,
                                              tool_choice=context.tool_choice,
                                              stream=context.stream)

        last_error = None
        final_metadata = {}

        try:
            # Try primary fallback chain (NVIDIA NIM models) with resilient fallback
            if self.config.mode in [GatewayMode.PRIMARY_ONLY, GatewayMode.PRIMARY_WITH_FALLBACK]:
                response, metadata = self.resilient_fallback.execute_with_resilient_fallback(
                    scene_id, model_alias, request_func
                )
                final_metadata = metadata
                last_error = None

                # Check if we got a valid response
                if response.get("content") or response.get("litellm_params"):
                    # Check if this response needs external execution (from attempts array in metadata)
                    needs_external = False
                    for attempt in metadata.get("attempts", []):
                        if attempt.get("needs_external_execution", False):
                            needs_external = True
                            break
                    return self._build_response(
                        success=True,
                        start_time=start_time,
                        response=response,
                        metadata=metadata,
                        needs_external_execution=needs_external
                    )

        except Exception as e:
            last_error = e
            logger.warning(f"Primary fallback chain failed: {e}")
            final_metadata = {"error": str(e)}

        # All attempts failed
        with self._lock:
            error_type = type(last_error).__name__ if last_error else "UnknownError"
            self._errors[error_type] = self._errors.get(error_type, 0) + 1

        return GatewayResponse(
            success=False,
            error=str(last_error) if last_error else "All fallback attempts failed",
            error_code=type(last_error).__name__ if last_error else "GATEWAY_ERROR",
            latency_ms=(time.time() - start_time) * 1000,
            metadata={**final_metadata, "request_id": request_id}
        )

    def _build_response(self, success: bool, start_time: float,
                       response: Dict, metadata: Dict,
                       needs_external_execution: bool = False) -> GatewayResponse:
        """Build standardized GatewayResponse."""
        latency_ms = (time.time() - start_time) * 1000
        request_id = metadata.get("request_id", f"req_{int(time.time() * 1000)}")

        # Extract data from response
        content = response.get("content")
        tool_calls = response.get("tool_calls")
        tokens = response.get("tokens", {})

        # Extract metadata
        model_used = metadata.get("model") or metadata.get("final_model")
        provider = metadata.get("provider", "nvidia_nim")
        scene_id = metadata.get("scene_id")
        api_key_index = metadata.get("final_key")
        fallback_tier = len(metadata.get("attempts", []))

        with self._lock:
            self._total_latency += latency_ms

        return GatewayResponse(
            success=success,
            content=content,
            tool_calls=tool_calls,
            model_used=model_used,
            provider=provider,
            scene_id=scene_id,
            api_key_index=api_key_index,
            fallback_tier=fallback_tier,
            latency_ms=latency_ms,
            tokens_used=tokens,
            metadata={
                **metadata,
                "needs_external_execution": needs_external_execution,
                "request_id": request_id
            }
        )

    def process_request_async(self, context: RequestContext) -> GatewayResponse:
        """
        Process request and return immediately with litellm_params
        for external execution (non-blocking).
        """
        # Temporarily disable callback
        original_callback = self._litellm_callback
        self._litellm_callback = None

        try:
            return self.process_request(context)
        finally:
            self._litellm_callback = original_callback

    # Convenience methods for common request types

    def chat(self, messages: List[Dict], model_alias: str = "claude-opus-5",
             scene_id: str = "scene_1_default", **kwargs) -> GatewayResponse:
        """Simple chat completion."""
        context = RequestContext(
            scene_id=scene_id,
            model_alias=model_alias,
            messages=messages,
            **kwargs
        )
        return self.process_request(context)

    def chat_stream(self, messages: List[Dict], model_alias: str = "claude-opus-5",
                    scene_id: str = "scene_1_default", **kwargs) -> GatewayResponse:
        """Streaming chat completion."""
        context = RequestContext(
            scene_id=scene_id,
            model_alias=model_alias,
            messages=messages,
            stream=True,
            **kwargs
        )
        return self.process_request(context)

    def completion(self, prompt: str, model_alias: str = "claude-opus-5",
                   scene_id: str = "scene_1_default", **kwargs) -> GatewayResponse:
        """Text completion."""
        messages = [{"role": "user", "content": prompt}]
        context = RequestContext(
            scene_id=scene_id,
            model_alias=model_alias,
            messages=messages,
            **kwargs
        )
        return self.process_request(context)

    def with_tools(self, messages: List[Dict], tools: List[Dict],
                   model_alias: str = "claude-opus-5",
                   scene_id: str = "scene_1_default", **kwargs) -> GatewayResponse:
        """Chat with tool calling."""
        context = RequestContext(
            scene_id=scene_id,
            model_alias=model_alias,
            messages=messages,
            tools=tools,
            required_capabilities={"tools": True},
            **kwargs
        )
        return self.process_request(context)

    def with_vision(self, messages: List[Dict], images_present: bool = True,
                    model_alias: str = "claude-sonnet-5",
                    scene_id: str = "scene_5_vision", **kwargs) -> GatewayResponse:
        """Vision-enabled request."""
        context = RequestContext(
            scene_id=scene_id,
            model_alias=model_alias,
            messages=messages,
            images_present=images_present,
            required_capabilities={"vision": True},
            **kwargs
        )
        return self.process_request(context)

    # Status and monitoring

    def get_status(self) -> Dict[str, Any]:
        """Get comprehensive gateway status."""
        with self._lock:
            scene_status = self.fallback_manager.get_scene_status()

            return {
                "gateway": {
                    "mode": self.config.mode.value,
                    "total_requests": self._request_count,
                    "avg_latency_ms": self._total_latency / max(self._request_count, 1),
                    "total_cost": self._total_cost,
                    "errors": dict(self._errors)
                },
                "scenes": scene_status,
                "ram_monitor": self.ram_monitor.get_status(),
                "auto_compactor": self.auto_compactor.get_status() if hasattr(self, 'auto_compactor') else None,
                "resilient_fallback": self.resilient_fallback.get_fallback_status() if hasattr(self, 'resilient_fallback') else None,
                "parallel_executor": self.parallel_executor.get_stats() if hasattr(self, 'parallel_executor') else None
            }

    def get_scene_status(self, scene_id: str) -> Optional[Dict[str, Any]]:
        """Get status for a specific scene."""
        all_status = self.fallback_manager.get_scene_status()
        return all_status.get(scene_id)

    def reset_rate_limits(self, scene_id: Optional[str] = None):
        """Reset rate limits for a scene or all scenes."""
        if scene_id:
            self.fallback_manager.reset_scene_rate_limits(scene_id)
        else:
            for scene_id in self.fallback_manager.list_scenes():
                self.fallback_manager.reset_scene_rate_limits(scene_id)

    def disable_model(self, scene_id: str, model_name: str) -> bool:
        """Disable a specific model."""
        return self.fallback_manager.disable_model(scene_id, model_name)

    def enable_model(self, scene_id: str, model_name: str) -> bool:
        """Enable a specific model."""
        return self.fallback_manager.enable_model(scene_id, model_name)

    # Intelligent routing integration

    def route_intelligently(self, message: str, images_present: bool = False) -> Dict[str, Any]:
        """
        Use BackendOrchestrator for intelligent routing.

        Returns routing decision with model and task type.
        """
        try:
            from backend_router import BackendOrchestrator
            orchestrator = BackendOrchestrator()
            model_name, task_type = orchestrator.route_request(message, images_present)
            # Handle case where task_type might be a string or an enum
            task_type_value = task_type.value if hasattr(task_type, 'value') else task_type
            return {
                "model_name": model_name,
                "task_type": task_type_value,
                "scene_id": self._get_scene_for_model(model_name),
                "model_alias": self._get_alias_for_model(model_name)
            }
        except ImportError:
            logger.warning("BackendOrchestrator not available")
            return {
                "model_name": "myclaude-router-super",
                "task_type": "general",
                "scene_id": "scene_1_default",
                "model_alias": "claude-sonnet-5"
            }

    def _get_scene_for_model(self, model_name: str) -> str:
        """Map model name to scene ID."""
        if "coder" in model_name or "code" in model_name:
            return "scene_2_opus_1m"
        elif "vision" in model_name or "omni" in model_name:
            return "scene_5_vision"
        elif "fast" in model_name or "gemma" in model_name:
            return "scene_3_sonnet"
        elif "reasoning" in model_name or "lightning" in model_name:
            return "scene_4_sonnet_1m"
        return "scene_1_default"

    def _get_alias_for_model(self, model_name: str) -> str:
        """Map model name to model alias."""
        if "coder" in model_name or "code" in model_name:
            return "claude-opus-5"
        elif "vision" in model_name or "omni" in model_name:
            return "claude-sonnet-5"
        elif "fast" in model_name:
            return "claude-haiku-5"
        elif "reasoning" in model_name or "lightning" in model_name:
            return "claude-opus-5"
        return "claude-sonnet-5"

    # Configuration management

    def set_mode(self, mode: GatewayMode):
        """Change gateway mode."""
        with self._lock:
            self.config.mode = mode
            logger.info(f"Gateway mode changed to {mode.value}")

    def update_config(self, **kwargs):
        """Update gateway configuration."""
        with self._lock:
            for key, value in kwargs.items():
                if hasattr(self.config, key):
                    setattr(self.config, key, value)
                    logger.info(f"Config updated: {key} = {value}")

    def list_scenes(self) -> List[str]:
        """List all available scenes."""
        return self.fallback_manager.list_scenes()

    def list_models(self, scene_id: Optional[str] = None) -> Dict[str, List[str]]:
        """List available models per scene."""
        scenes = [scene_id] if scene_id else self.list_scenes()
        result = {}
        for sid in scenes:
            scene = self.fallback_manager.get_scene(sid)
            if scene:
                result[sid] = [m.name for m in scene.models if m.enabled]
        return result

    def shutdown(self):
        """Gracefully shutdown the gateway and stop monitoring."""
        logger.info("Shutting down APIGateway...")
        if hasattr(self, 'parallel_executor') and self.parallel_executor:
            self.parallel_executor.stop()
        if hasattr(self, 'auto_compactor') and self.auto_compactor:
            self.auto_compactor.stop()
        if hasattr(self, 'ram_monitor') and self.ram_monitor:
            self.ram_monitor.stop()
        logger.info("APIGateway shutdown complete")


# Convenience function for quick access
_default_gateway: Optional[APIGateway] = None


def get_default_gateway(config: Optional[GatewayConfig] = None) -> APIGateway:
    """Get or create the default gateway instance."""
    global _default_gateway
    if _default_gateway is None:
        _default_gateway = APIGateway(config)
    return _default_gateway


# Example usage and testing
if __name__ == "__main__":
    # Create gateway with primary fallback
    config = GatewayConfig(
        mode=GatewayMode.PRIMARY_WITH_FALLBACK,
        default_scene="scene_1_default",
        default_model_alias="claude-opus-5",
        log_level="DEBUG"
    )

    gateway = APIGateway(config)

    # Print status
    import json
    print(json.dumps(gateway.get_status(), indent=2, default=str))

    # Test basic request (without callback - returns params for external execution)
    print("\n--- Test Request (no callback) ---")
    response = gateway.chat(
        messages=[{"role": "user", "content": "Hello, world!"}],
        model_alias="claude-opus-5",
        scene_id="scene_1_default"
    )
    print(f"Success: {response.success}")
    print(f"Model: {response.model_used}")
    print(f"Scene: {response.scene_id}")
    print(f"Key: {response.api_key_index}")
    print(f"Latency: {response.latency_ms:.2f}ms")
    print(f"Needs external execution: {response.metadata.get('needs_external_execution')}")

    if response.metadata.get("litellm_params"):
        print(f"LiteLLM params: {json.dumps(response.metadata['litellm_params'], indent=2, default=str)}")