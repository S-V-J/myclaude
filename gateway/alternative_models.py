"""
Alternative Model Provider Integration - NVIDIA Only Version

This file has been modified to remove all alternative provider logic as requested.
Only NVIDIA NIM provider is used.
"""
import os
import time
import logging
from typing import Dict, List, Optional, Any

logger = logging.getLogger(__name__)

# Placeholder for alternative model registry - now NVIDIA-only
class AlternativeModelRegistry:
    """
    Placeholder registry for compatibility - now NVIDIA-only.
    """

    def __init__(self):
        self._models = {}
        logger.info("AlternativeModelRegistry initialized (NVIDIA-only mode)")

    def register_model(self, model) -> None:
        """Register a model (placeholder for NVIDIA-only mode)."""
        pass

    def get_model(self, model_name: str):
        """Get a model by name (returns None for NVIDIA-only mode)."""
        return None

    def get_available_providers(self):
        """Get list of available providers (returns empty for NVIDIA-only mode)."""
        return []

    def get_models_by_tier(self, tier):
        """Get models by tier (returns empty for NVIDIA-only mode)."""
        return []

    def get_models_by_capability(self, supports_tools=False, supports_vision=False, supports_reasoning=False):
        """Get models by capability (returns empty for NVIDIA-only mode)."""
        return []

    def select_best_model(self, required_capabilities=None, preferred_tier=None, exclude_providers=None):
        """Select best model (returns None for NVIDIA-only mode)."""
        return None

    def get_litellm_config(self, model_name: str):
        """Get LiteLLM configuration (returns None for NVIDIA-only mode)."""
        return None

    def get_status(self):
        """Get status (returns empty for NVIDIA-only mode)."""
        return {"providers": {}, "models": {}}

# Convenience function for quick access
_default_registry: Optional[AlternativeModelRegistry] = None

def get_default_registry() -> AlternativeModelRegistry:
    """Get or create the default registry."""
    global _default_registry
    if _default_registry is None:
        _default_registry = AlternativeModelRegistry()
    return _default_registry