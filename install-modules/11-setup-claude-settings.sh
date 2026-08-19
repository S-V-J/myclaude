#!/bin/bash
# Module: 11-setup-claude-settings
# Configure ~/.claude/settings.json

run_11_setup_claude_settings() {
    setup_claude_settings
}

setup_claude_settings() {
    log_info "Setting up ~/.claude/settings.json..."

    mkdir -p "$CLAUDE_SETTINGS_DIR"

    # Check if settings.json already exists
    if [ -f "$CLAUDE_SETTINGS_FILE" ]; then
        if [[ "${AUTO_MODE:-false}" != "true" ]] && [ -t 0 ]; then
            if ! whiptail --title "MyClaude Installer" --yesno "~/.claude/settings.json already exists. Overwrite with MyClaude optimized settings?" 10 70; then
                log_info "Keeping existing settings.json"
                return 0
            fi
        else
            log_info "Overwriting existing settings.json with MyClaude optimized settings..."
        fi
    fi

    cat > "$CLAUDE_SETTINGS_FILE" <<'SETTINGSEOF'
{
  "autoCompactWindow": 1000000,
  "theme": "auto",
  "verbose": false,
  "permissions": {
    "bash": {
      "allow": [
        "git *",
        "gh *",
        "npm *",
        "npx *",
        "pip *",
        "pip3 *",
        "python *",
        "python3 *",
        "docker *",
        "docker-compose *",
        "kubectl *",
        "helm *",
        "terraform *",
        "ansible *",
        "make *",
        "cmake *",
        "cargo *",
        "go *",
        "mvn *",
        "gradle *",
        "systemctl *",
        "service *",
        "journalctl *",
        "nginx *",
        "ufw *",
        "firewall-cmd *",
        "iptables *",
        "ss *",
        "netstat *",
        "lsof *",
        "ps *",
        "top *",
        "htop *",
        "free *",
        "df *",
        "du *",
        "ls *",
        "find *",
        "grep *",
        "rg *",
        "awk *",
        "sed *",
        "cat *",
        "head *",
        "tail *",
        "less *",
        "more *",
        "vim *",
        "nano *",
        "code *",
        "chmod *",
        "chown *",
        "mkdir *",
        "rm *",
        "cp *",
        "mv *",
        "ln *",
        "tar *",
        "gzip *",
        "gunzip *",
        "unzip *",
        "curl *",
        "wget *",
        "ssh *",
        "scp *",
        "rsync *",
        "sudo *",
        "apt *",
        "apt-get *",
        "dnf *",
        "yum *",
        "pacman *",
        "zypper *",
        "snap *",
        "flatpak *",
        "brew *",
        "npm *",
        "yarn *",
        "pnpm *",
        "bun *",
        "deno *",
        "nvm *",
        "fnm *",
        "pyenv *",
        "rbenv *",
        "rustup *",
        "sdkman *",
        "asdf *"
      ],
      "deny": []
    }
  },
  "autoCompact": true,
  "autoScroll": true,
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-github"
      ],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    },
    "filesystem": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/home/ML"
      ]
    },
    "fetch": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-fetch"
      ]
    },
    "brave-search": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-brave-search"
      ],
      "env": {
        "BRAVE_API_KEY": "${BRAVE_API_KEY}"
      }
    },
    "postgres": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-postgres"
      ],
      "env": {
        "POSTGRES_CONNECTION_STRING": "${POSTGRES_URL}"
      }
    },
    "sqlite": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-sqlite",
        "--db-path",
        "/home/ML/data.db"
      ]
    },
    "redis": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-redis"
      ],
      "env": {
        "REDIS_URL": "${REDIS_URL}"
      }
    }
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo '[PRE] Running: $TOOL_INPUT'"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo '[POST] Completed: $TOOL_INPUT'"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo 'Session ended at $(date)'"
          }
        ]
      }
    ]
  },
  "model": "opus[1m]",
  "maxTokens": 8192,
  "temperature": 0.1,
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT": "true",
    "CLAUDE_CODE_MAX_THINKING_TOKENS": "32000",
    "CLAUDE_CODE_ENABLE_THINKING": "true",
    "CLAUDE_CODE_BYPASS_PERMISSIONS": "false"
  },
  "agentSettings": {
    "defaultAgent": "general-purpose",
    "availableAgents": [
      "general-purpose",
      "code-reviewer",
      "security-auditor",
      "performance-engineer",
      "devops-engineer",
      "database-engineer",
      "frontend-engineer",
      "backend-engineer",
      "ml-engineer",
      "api-designer",
      "test-engineer",
      "documentation-writer"
    ]
  },
  "workspace": {
    "root": "/home/ML",
    "include": [
      "**/*.py",
      "**/*.js",
      "**/*.ts",
      "**/*.json",
      "**/*.yaml",
      "**/*.yml",
      "**/*.md",
      "**/*.sh",
      "**/*.dockerfile",
      "**/Dockerfile*",
      "**/*.tf",
      "**/*.go",
      "**/*.rs",
      "**/*.java",
      "**/*.kt",
      "**/*.cs",
      "**/*.cpp",
      "**/*.c",
      "**/*.h",
      "**/*.hpp"
    ],
    "exclude": [
      "node_modules/**",
      ".git/**",
      "venv/**",
      "__pycache__/**",
      "*.log",
      "*.tmp",
      "dist/**",
      "build/**",
      ".next/**",
      "target/**",
      "*.min.js",
      "*.min.css"
    ]
  },
  "telemetry": {
    "enabled": false
  },
  "notifications": {
    "enabled": true,
    "sound": false
  }
}
SETTINGSEOF

    log_success "Created ~/.claude/settings.json with MyClaude optimized configuration"
    log_info "Includes: MCP servers (GitHub, Filesystem, Fetch, Brave Search, Postgres, SQLite, Redis)"
    log_info "Includes: Permissive bash permissions for development tools"
    log_info "Includes: Auto-compact, thinking enabled, Opus 1M model"
}