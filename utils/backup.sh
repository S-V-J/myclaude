#!/bin/bash
# MyClaude Backup Utility
# Creates backups of configuration and data

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults
REPO_DIR="${MYCLAUDE_INSTALL_DIR:-$HOME/myclaude}"
BACKUP_DIR="${MYCLAUDE_BACKUP_DIR:-/tmp/myclaude-backups}"
INCLUDE_LOGS="${INCLUDE_LOGS:-false}"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

MyClaude Backup Utility

Options:
  --repo-dir DIR       MyClaude installation directory (default: \$HOME/myclaude)
  --backup-dir DIR     Backup destination directory (default: /tmp/myclaude-backups)
  --include-logs       Include application logs in backup
  --help               Show this help

Examples:
  $0                                    # Backup config only
  $0 --include-logs                     # Backup config and logs
  $0 --repo-dir /opt/myclaude           # Custom installation
  $0 --backup-dir /mnt/backups/myclaude # Custom backup location
EOF
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --repo-dir) REPO_DIR="$2"; shift 2 ;;
            --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
            --include-logs) INCLUDE_LOGS=true; shift ;;
            --help) usage ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
}

create_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="myclaude-backup-${timestamp}"
    local backup_path="${BACKUP_DIR}/${backup_name}"

    log_info "Creating backup: $backup_name"
    mkdir -p "$backup_path"

    # Backup configuration files
    local config_files=(
        ".env"
        "config.yaml"
        "config_base.yaml"
        "requirements.txt"
        "models/"
        "nginx-myclaude.conf"
        "logrotate-myclaude"
        "myclaude.sh"
        "build_config.sh"
        "litellm.service.template"
        "setup-tls.sh"
    )

    for item in "${config_files[@]}"; do
        if [[ -e "$REPO_DIR/$item" ]]; then
            cp -r "$REPO_DIR/$item" "$backup_path/"
            log_info "Backed up: $item"
        fi
    done

    # Backup logs if requested
    if [[ "$INCLUDE_LOGS" == "true" ]] && [[ -d "$REPO_DIR/logs" ]]; then
        cp -r "$REPO_DIR/logs" "$backup_path/"
        log_info "Backed up: logs/"
    fi

    # Backup system configs (if running as root)
    if [[ $EUID -eq 0 ]]; then
        local system_files=(
            "/etc/systemd/system/myclaude.service"
            "/etc/nginx/sites-available/myclaude"
            "/etc/nginx/sites-enabled/myclaude"
            "/etc/logrotate.d/myclaude"
            "/usr/local/bin/myclaude"
        )

        mkdir -p "$backup_path/system"
        for file in "${system_files[@]}"; do
            if [[ -e "$file" ]]; then
                cp "$file" "$backup_path/system/"
                log_info "Backed up: $file"
            fi
        done
    fi

    # Create manifest
    cat > "$backup_path/MANIFEST.txt" <<EOF
MyClaude Backup Manifest
Generated: $(date)
Installation Directory: $REPO_DIR
Backup Directory: $BACKUP_DIR
Include Logs: $INCLUDE_LOGS

Files included:
EOF
    find "$backup_path" -type f | sed "s|$backup_path/||" | sort >> "$backup_path/MANIFEST.txt"

    # Create tarball
    log_info "Creating archive..."
    tar -czf "${backup_path}.tar.gz" -C "$BACKUP_DIR" "$backup_name"
    rm -rf "$backup_path"

    log_success "Backup created: ${backup_path}.tar.gz"
    log_info "Size: $(du -h "${backup_path}.tar.gz" | cut -f1)"
}

restore_backup() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        exit 1
    fi

    log_info "Restoring from: $backup_file"
    local temp_dir
    temp_dir=$(mktemp -d)

    tar -xzf "$backup_file" -C "$temp_dir"

    local extracted_dir
    extracted_dir=$(find "$temp_dir" -maxdepth 1 -type d -name "myclaude-backup-*" | head -1)

    if [[ -z "$extracted_dir" ]]; then
        log_error "Invalid backup format"
        rm -rf "$temp_dir"
        exit 1
    fi

    # Restore config files
    for item in "$extracted_dir"/*; do
        local basename
        basename=$(basename "$item")
        if [[ -d "$item" ]]; then
            cp -r "$item" "$REPO_DIR/"
        else
            cp "$item" "$REPO_DIR/"
        fi
        log_info "Restored: $basename"
    done

    # Restore system files if running as root and they exist
    if [[ $EUID -eq 0 ]] && [[ -d "$extracted_dir/system" ]]; then
        for file in "$extracted_dir/system"/*; do
            local basename
            basename=$(basename "$file")
            case "$basename" in
                myclaude.service)
                    cp "$file" "/etc/systemd/system/"
                    systemctl daemon-reload
                    ;;
                myclaude)
                    cp "$file" "/usr/local/bin/"
                    chmod +x "/usr/local/bin/myclaude"
                    ;;
                myclaude)
                    cp "$file" "/etc/nginx/sites-available/myclaude"
                    ;;
                logrotate.d.myclaude)
                    cp "$file" "/etc/logrotate.d/myclaude"
                    ;;
            esac
            log_info "Restored system: $basename"
        done
    fi

    rm -rf "$temp_dir"
    log_success "Backup restored successfully"
    log_warn "Restart services to apply changes: sudo systemctl restart myclaude nginx"
}

list_backups() {
    log_info "Available backups in $BACKUP_DIR:"
    find "$BACKUP_DIR" -name "myclaude-backup-*.tar.gz" -type f | sort -r | while read -r file; do
        local size name date
        size=$(du -h "$file" | cut -f1)
        name=$(basename "$file" .tar.gz)
        date=$(stat -c "%y" "$file" | cut -d' ' -f1)
        echo "  $name ($size, $date)"
    done
}

main() {
    parse_args "$@"

    case "${1:-backup}" in
        backup)
            create_backup
            ;;
        restore)
            if [[ $# -lt 2 ]]; then
                log_error "Usage: $0 restore <backup-file>"
                exit 1
            fi
            restore_backup "$2"
            ;;
        list)
            list_backups
            ;;
        *)
            log_error "Unknown command: $1"
            usage
            ;;
    esac
}

main "$@"