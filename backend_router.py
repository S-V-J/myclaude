#!/usr/bin/env python3
"""
Backend AI Model Orchestration Router
Intelligently routes requests from primary models (Ultra-550b, Super-120b)
to specialized worker models based on task analysis.
"""

import re
import json
import logging
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass
from enum import Enum

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class TaskType(Enum):
    CODING = "coding"
    VISION = "vision"
    VISION_REASONING = "vision_reasoning"
    FAST_RESPONSE = "fast_response"
    HIGH_THROUGHPUT = "high_throughput"
    REASONING = "reasoning"
    GENERAL = "general"
    UNKNOWN = "unknown"

@dataclass
class ModelConfig:
    name: str
    model_id: str
    api_key_env: str
    specialization: TaskType
    max_tokens: int
    temperature: float
    capabilities: List[str]

class BackendOrchestrator:
    def __init__(self):
        # Initialize model configurations
        self.models = self._initialize_models()

        # Task detection patterns
        self.task_patterns = {
            TaskType.CODING: [
                r'(?i)\b(code|program|function|class|method|variable|loop|if|else|for|while|return|import|from|def|lambda)\b',
                r'(?i)\b(debug|fix|error|exception|bug|stack trace|traceback)\b',
                r'(?i)\b(algorithm|data structure|array|list|dict|set|tree|graph|sort|search)\b',
                r'(?i)\b(api|endpoint|rest|graphql|http|request|response|json|xml)\b',
                r'(?i)\b(sql|query|database|table|join|select|insert|update|delete)\b',
                r'(?i)\b(test|unit test|pytest|jest|mocha|testing|assert|mock)\b',
                r'(?i)\b(refactor|optimize|performance|memory|cpu|benchmark)\b',
                r'(?i)\b(git|github|version control|commit|push|pull|merge|branch)\b',
                r'(?i)\b(docker|kubernetes|container|deployment|devops|ci/cd)\b',
                r'(?i)\b(html|css|javascript|typescript|python|java|c\+\+|rust|go|php|ruby|swift|kotlin)\b'
            ],
            TaskType.VISION: [
                r'(?i)\b(image|photo|picture|img|visual|see|look|view|display)\b',
                r'(?i)\b(object|face|person|car|animal|scene|landscape|background)\b',
                r'(?i)\b(color|red|blue|green|yellow|black|white|bright|dark)\b',
                r'(?i)\b(text|ocr|read|extract|caption|describe|label)\b',
                r'(?i)\b(chart|graph|plot|diagram|figure|visualization)\b',
                r'(?i)\b(screenshot|photo|camera|lens|pixel|resolution)\b',
                r'(?i)\b(format|png|jpg|jpeg|gif|bmp|tiff|webp|svg)\b'
            ],
            TaskType.VISION_REASONING: [
                r'(?i)\b(explain|why|how|reason|analyze|interpret|understand|infer)\b.*\b(image|photo|picture|chart|graph|diagram)\b',
                r'(?i)\b(what is happening|what does this show|what can you see)\b',
                r'(?i)\b(trend|pattern|correlation|relationship|comparison|difference)\b.*\b(data|chart|graph)\b',
                r'(?i)\b(problem|solution|answer|calculate|solve|compute)\b.*\b(image|diagram|chart)\b',
                r'(?i)\b(mathematics|equation|formula|calculation|math)\b.*\b(image|diagram)\b'
            ],
            TaskType.FAST_RESPONSE: [
                r'(?i)\b(quick|fast|instant|rapid|speed|immediate|now|hurry)\b',
                r'(?i)\b(hello|hi|hey|thanks|thank you|goodbye|bye)\b',
                r'(?i)\b(yes|no|ok|okay|sure|maybe|perhaps)\b',
                r'(?i)\b(define|meaning|what is|abbreviation|acronym)\b.*\?',
                r'(?i)\b(translate|translation|language|spanish|french|german|chinese|japanese)\b',
                r'(?i)\b(summary|summarize|tl;dr|brief|short|concise)\b',
                r'(?i)\b(count|number|how many|what.*\d+|\d+.*what)\b',
                r'(?i)\b(date|time|today|tomorrow|yesterday|now|clock)\b'
            ],
            TaskType.HIGH_THROUGHPUT: [
                r'(?i)\b(batch|bulk|mass|large volume|many|multiple|lots)\b',
                r'(?i)\b(process|processes|processing|handle|handles|handling)\b',
                r'(?i)\b(list|enumerate|item|items|entry|entries|record|records)\b',
                r'(?i)\b(generate|create|produce|make|build|construct)\b.*\b(multiple|many|several)\b',
                r'(?i)\b(transform|convert|change|modify|alter|update)\b.*\b(data|file|document)\b',
                r'(?i)\b(filter|sort|search|find|lookup|query)\b.*\b(collection|array|list)\b',
                r'(?i)\b(aggregate|sum|total|average|mean|median|mode|statistics)\b',
                r'(?i)\b(export|import|save|load|store|retrieve|backup|archive)\b'
            ],
            TaskType.REASONING: [
                r'(?i)\b(solve|solution|answer|calculate|compute|math|mathematics)\b',
                r'(?i)\b(logic|logical|deduce|deduction|infer|inference|reason|reasoning)\b',
                r'(?i)\b(problem|puzzle|riddle|brain teaser|challenge|question)\b',
                r'(?i)\b(step by step|step-by-step|explain|walk through|show work)\b',
                r'(?i)\b(equation|formula|expression|inequality|variable|solve for)\b',
                r'(?i)\b(proof|prove|theorem|lemma|corollary|hypothesis)\b',
                r'(?i)\b(analyze|analysis|examine|investigate|study|research)\b',
                r'(?i)\b(decide|decision|choice|option|alternative|pros and cons)\b'
            ]
        }

        # Model routing map: task_type -> list of preferred models (in order)
        self.routing_map = {
            TaskType.CODING: [
                "myclaude-worker-coder-deepseek",
                "myclaude-worker-coder-starcoder",
                "myclaude-worker-coder-codestral",
                "myclaude-worker-coder-granite-large",
                "myclaude-worker-coder-granite-fast"
            ],
            TaskType.VISION: [
                "myclaude-worker-vision-llama-11b",
                "myclaude-worker-vision-llama-90b",
                "myclaude-worker-vision-nano-omni"
            ],
            TaskType.VISION_REASONING: [
                "myclaude-worker-vision-nano-omni",
                "myclaude-worker-vision-llama-90b",
                "myclaude-worker-vision-llama-11b"
            ],
            TaskType.FAST_RESPONSE: [
                "myclaude-worker-fast-gemma-4b",
                "myclaude-worker-fast-mistral-7b",
                "myclaude-worker-fast-gemma-12b"
            ],
            TaskType.HIGH_THROUGHPUT: [
                "myclaude-worker-general-mistral-large2",
                "myclaude-worker-general-nemotron-4-340b",
                "myclaude-worker-general-yi-large"
            ],
            TaskType.REASONING: [
                "myclaude-worker-reasoning-lightning",
                "myclaude-worker-reasoning-nano3",
                "myclaude-worker-general-yi-large"
            ],
            TaskType.GENERAL: [
                "myclaude-worker-general-mistral-large2",
                "myclaude-worker-general-nemotron-4-340b",
                "myclaude-worker-general-yi-large"
            ],
            TaskType.UNKNOWN: [
                "myclaude-router-super",  # Default to Super router
                "myclaude-router-ultra"
            ]
        }

    def _initialize_models(self) -> Dict[str, ModelConfig]:
        """Initialize model configurations from scene files or defaults"""
        models = {}

        # This would normally be loaded from config files, but for now we'll define key ones
        # In a real implementation, this would parse the generated config.yaml

        # Coding models
        models["myclaude-worker-coder-deepseek"] = ModelConfig(
            name="deepseek-coder-6.7b",
            model_id="nvidia_nim/deepseek-ai/deepseek-coder-6.7b-instruct",
            api_key_env="NVIDIA_API_KEY_3",
            specialization=TaskType.CODING,
            max_tokens=16384,
            temperature=0.2,
            capabilities=["code_generation", "debugging", "refactoring", "code_review"]
        )

        models["myclaude-worker-coder-starcoder"] = ModelConfig(
            name="starcoder2-15b",
            model_id="nvidia_nim/bigcode/starcoder2-15b",
            api_key_env="NVIDIA_API_KEY_4",
            specialization=TaskType.CODING,
            max_tokens=16384,
            temperature=0.2,
            capabilities=["code_completion", "generation", "explanation"]
        )

        # Vision models
        models["myclaude-worker-vision-nano-omni"] = ModelConfig(
            name="nemotron-3-nano-omni-30b",
            model_id="nvidia_nim/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
            api_key_env="NVIDIA_API_KEY_3",
            specialization=TaskType.VISION_REASONING,
            max_tokens=65536,
            temperature=0.6,
            capabilities=["image_analysis", "ocr", "chart_understanding", "visual_reasoning"],
            reasoning_budget=16384
        )

        models["myclaude-worker-vision-llama-11b"] = ModelConfig(
            name="llama-3.2-11b-vision",
            model_id="nvidia_nim/meta/llama-3.2-11b-vision-instruct",
            api_key_env="NVIDIA_API_KEY_4",
            specialization=TaskType.VISION,
            max_tokens=65536,
            temperature=0.6,
            capabilities=["image_description", "object_detection", "text_extraction"]
        )

        # Fast response models
        models["myclaude-worker-fast-gemma-4b"] = ModelConfig(
            name="gemma-3-4b-it",
            model_id="nvidia_nim/google/gemma-3-4b-it",
            api_key_env="NVIDIA_API_KEY_2",
            specialization=TaskType.FAST_RESPONSE,
            max_tokens=8192,
            temperature=0.7,
            capabilities=["instant_replies", "classification", "simple_tasks"]
        )

        # Reasoning models
        models["myclaude-worker-reasoning-lightning"] = ModelConfig(
            name="nemotron-3.5-lightning-30b",
            model_id="nvidia_nim/nvidia/nemotron-3.5-lightning-30b-a3b",
            api_key_env="NVIDIA_API_KEY_1",
            specialization=TaskType.REASONING,
            max_tokens=32768,
            temperature=0.5,
            capabilities=["logical_reasoning", "math", "problem_solving"]
        )

        # General models
        models["myclaude-worker-general-mistral-large2"] = ModelConfig(
            name="mistral-large-2-instruct",
            model_id="nvidia_nim/mistralai/mistral-large-2-instruct",
            api_key_env="NVIDIA_API_KEY_4",
            specialization=TaskType.GENERAL,
            max_tokens=32768,
            temperature=0.7,
            capabilities=["complex_reasoning", "long_context", "multilingual", "tool_use"]
        )

        return models

    def detect_task_type(self, message: str, images_present: bool = False) -> TaskType:
        """
        Detect the task type based on message content and presence of images

        Args:
            message: The user's input message
            images_present: Whether images are attached to the request

        Returns:
            TaskType enum indicating the detected task type
        """
        # If images are present, likely vision-related task
        if images_present:
            # Check if it's vision reasoning (asking questions about the image)
            vision_reasoning_score = self._score_task_patterns(message, TaskType.VISION_REASONING)
            vision_score = self._score_task_patterns(message, TaskType.VISION)

            if vision_reasoning_score > vision_score * 0.7:  # Reasoning component detected
                return TaskType.VISION_REASONING
            else:
                return TaskType.VISION

        # Score each task type based on keyword patterns
        scores = {}
        for task_type in TaskType:
            if task_type != TaskType.UNKNOWN:
                scores[task_type] = self._score_task_patterns(message, task_type)

        # Get the task type with highest score
        if max(scores.values()) > 0:
            return max(scores, key=scores.get)
        else:
            return TaskType.UNKNOWN

    def _score_task_patterns(self, message: str, task_type: TaskType) -> float:
        """Score how well the message matches patterns for a task type"""
        if task_type not in self.task_patterns:
            return 0.0

        score = 0.0
        message_lower = message.lower()

        for pattern in self.task_patterns[task_type]:
            matches = len(re.findall(pattern, message_lower))
            score += matches

        # Normalize by message length to avoid bias toward long messages
        if len(message) > 0:
            score = score / (len(message.split()) + 1)  # +1 to avoid division by zero

        return score

    def select_model(self, task_type: TaskType, fallback_chain: List[str] = None) -> str:
        """
        Select the best model for a given task type

        Args:
            task_type: The detected task type
            fallback_chain: Optional list of model names to use as fallback

        Returns:
            Model name string for the selected model
        """
        # Get preferred models for this task type
        preferred_models = self.routing_map.get(task_type, self.routing_map[TaskType.UNKNOWN])

        # If fallback chain provided, intersect with preferred models
        if fallback_chain:
            # Filter preferred models to only those in fallback chain
            available_preferred = [m for m in preferred_models if m in fallback_chain]
            if available_preferred:
                preferred_models = available_preferred

        # Return the first available model (in real implementation, check health/availability)
        if preferred_models:
            selected = preferred_models[0]
            logger.info(f"Selected model '{selected}' for task type {task_type.value}")
            return selected
        else:
            # Final fallback
            fallback = "myclaude-router-super"
            logger.warning(f"No preferred models available, using fallback: {fallback}")
            return fallback

    def route_request(self, message: str, images_present: bool = False,
                     fallback_chain: List[str] = None) -> Tuple[str, TaskType]:
        """
        Main routing function - analyzes request and returns best model

        Args:
            message: The user's input message
            images_present: Whether images are attached
            fallback_chain: Optional fallback model chain from config

        Returns:
            Tuple of (model_name, task_type)
        """
        # Detect task type
        task_type = self.detect_task_type(message, images_present)

        # Select best model
        model_name = self.select_model(task_type, fallback_chain)

        logger.info(f"Routing request: '{message[:50]}...' -> {task_type.value} -> {model_name}")

        return model_name, task_type

    def get_model_info(self, model_name: str) -> Optional[ModelConfig]:
        """Get configuration for a model"""
        return self.models.get(model_name)

    def list_available_models(self) -> List[str]:
        """List all available model names"""
        return list(self.models.keys())

def main():
    """Example usage of the BackendOrchestrator"""
    orchestrator = BackendOrchestrator()

    # Test cases
    test_requests = [
        ("Write a Python function to calculate fibonacci numbers", False),
        ("What's in this image? Describe what you see.", True),
        ("Explain the theory of relativity step by step", False),
        ("Hello, how are you today?", False),
        ("Analyze this chart and explain the trends shown", True),
        ("Create a REST API endpoint for user authentication", False),
        ("What is the capital of France?", False),
        ("Process these 1000 CSV files and extract email addresses", False),
        ("Debug this JavaScript code that's causing a null pointer exception", False),
        ("Translate 'hello world' to Spanish", False)
    ]

    print("Backend AI Model Orchestration Router - Test Runs")
    print("=" * 60)

    for message, has_images in test_requests:
        model, task_type = orchestrator.route_request(message, has_images)
        print(f"Message: {message}")
        print(f"Images: {has_images}")
        print(f"Task Type: {task_type.value}")
        print(f"Selected Model: {model}")
        print("-" * 40)

if __name__ == "__main__":
    main()