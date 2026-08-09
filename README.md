# 🤖 Claude Code + NVIDIA NIM (via LiteLLM)

> **Support this project:** If you find this useful, consider [Sponsoring me on GitHub](https://github.com/sponsors/S-V-J)! ❤️

This repository contains the configuration to run NVIDIA's Nemotron 3 Ultra model as a drop-in replacement for Claude Opus/Sonnet using [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and [LiteLLM](https://github.com/BerriAI/litellm).

It features an elite **4-Tier Context-Aware Smart Router** that dynamically allocates `reasoning_budget`, `max_tokens`, and `temperature` based on prompt complexity. This unlocks the raw power of the AI while keeping you safely under API rate limits.

## 🚀 Prerequisites
- Python 3.10+ (`python3`)
- A valid NVIDIA NIM API Key (Get one at [build.nvidia.com](https://build.nvidia.com))
- Claude Code CLI installed

## 🛠️ Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/S-V-J/myclaude.git
   cd myclaude
   ```

2. Create a virtual environment and install LiteLLM (with the FastAPI fix):
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   pip install 'litellm[proxy]' "fastapi<0.140.0"
   ```

3. Configure your API keys:
   Copy the example file and paste your actual NVIDIA key.
   ```bash
   cp .env.example .env
   nano .env
   ```

## 💻 Usage

1. Load the environment variables and start the proxy:
   ```bash
   set -a
   source .env
   set +a
   litellm --config config.yaml --port 4000
   ```

2. Open a **new terminal window** and configure Claude Code to use your local proxy:
   ```bash
   export ANTHROPIC_BASE_URL="http://localhost:4000"
   export ANTHROPIC_API_KEY="sk-local-proxy-key"
   claude
   ```

## 🧠 The Engineering Reality of "Raw Power" Parameters
A truly elite agentic system does not use max settings for everything. It uses Context-Aware Dynamic Routing. It analyzes the user's prompt to dynamically scale parameters:

- **`reasoning_budget` (256 to 16384):** Dictates how much "thinking" the model does before it acts. 4096 is sufficient for simple file reads. 16384 allows the model to mentally simulate entire codebase refactors and plan multi-tool trajectories. Maxing this out on every request exhausts API token limits.
- **`max_tokens` (1024 to 16384):** The output limit. Capping at 1024 means large files get truncated. Setting it to 16384 guarantees full-file generation for complex tasks.
- **`temperature` (0.1 to 1.0):** 
  - Low (0.1 - 0.3): Deterministic, strict syntax adherence. Best for writing code.
  - High (0.7 - 1.0): Creative, exploratory. Best for brainstorming architecture.

## ⚡ How the 4-Tier Smart Router Works
The `config.yaml` uses LiteLLM's `complexity_router` to evaluate incoming prompts in sub-milliseconds and routes to the appropriate tier:

| Tier | Use Case | Temperature | Reasoning Budget | Max Tokens |
| :--- | :--- | :---: | :---: | :---: |
| **⚡ Micro** | Trivial tasks, greetings, `ls` | `0.1` | `256` | `1024` |
| **🚀 Fast** | Standard coding, basic refactoring | `0.3` | `2048` | `4096` |
| **⚖️ Balanced** | Complex logic, multi-file debugging | `0.6` | `8192` | `16384` |
| **🧠 Max** | Deep reasoning, system design | `1.0` | `16384` | `16384` |

This dynamic scaling prevents timeout issues, eliminates truncated code, and keeps you safely under NVIDIA NIM's 32 concurrent request limit.