#!/usr/bin/env bash
# ==============================================================================
#  MODULE: Persistence Manager (Backup/Restore/Delete)
#  CONTEXT: Hyprland / UWSM / Arch Linux
#  DESCRIPTION: Manages backup, restoration, and cleanup of Clipboard (Cliphist) 
#               and Errands data.
# ==============================================================================

# 1. Strict Error Handling
set -euo pipefail

# ==============================================================================
#  CONSTANTS & CONFIGURATION
# ==============================================================================

readonly BACKUP_DIR="${HOME}/.local/share/rofi_cliphist_and_errands_backup"

# Use XDG_RUNTIME_DIR for a secure, per-user lock file (tmpfs backed)
readonly LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/persistence_manager_${UID}.lock"

# Format: "Path_to_Source:Backup_Subfolder_Name"
readonly TARGETS=(
    "${HOME}/.local/share/rofi-cliphist:rofi-cliphist"
    "${HOME}/.local/share/errands:errands"
    "${HOME}/.cache/cliphist:cliphist_db"
)

# Systemd services that must be paused to prevent DB corruption
readonly SERVICES=("cliphist.service" "wl-paste.service")

# GUI Processes to kill (Non-systemd apps that hold file locks)
readonly APPS_TO_KILL=("errands")
readonly KILL_TIMEOUT=50 # 50 * 0.1s = 5 seconds

# ==============================================================================
#  OUTPUT FORMATTING
# ==============================================================================

# Only use colors if stderr is a terminal (avoids log pollution)
if [[ -t 2 ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[1;33m'
    readonly BLUE=$'\033[0;34m'
    readonly BOLD=$'\033[1m'
    readonly RESET=$'\033[0m'
else
    readonly RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
fi

# Redirecting logs to stderr (&2) ensures clean stdout for potential piping
log_info() { printf '%s[INFO]%s  %s\n' "$BLUE" "$RESET" "$1" >&2; }
log_ok()   { printf '%s[OK]%s    %s\n' "$GREEN" "$RESET" "$1" >&2; }
log_warn() { printf '%s[WARN]%s  %s\n' "$YELLOW" "$RESET" "$1" >&2; }
log_err()  { printf '%s[ERR]%s   %s\n' "$RED" "$RESET" "$1" >&2; }

# ==============================================================================
#  GUARDS & LOCKING
# ==============================================================================

if [[ $EUID -eq 0 ]]; then
    log_err "This script must be run as a normal user, not root."
    log_err "It modifies files in \${HOME}."
    exit 1
fi

# Acquire exclusive lock to prevent concurrent execution
# FD 9 is used for the lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log_err "Another instance of this script is already running."
    exit 1
fi

# ==============================================================================
#  SERVICE & PROCESS MANAGEMENT
# ==============================================================================

# State tracking to prevent restarting services that weren't touched
SERVICES_STOPPED=false

stop_services() {
    log_info "Preparing environment for data migration..."

    # A. Kill GUI Apps (Safe > Wait > Force)
    local app waited
    for app in "${APPS_TO_KILL[@]}"; do
        if pgrep -x "$app" >/dev/null 2>&1; then
            log_info "Closing active process: $app"
            pkill -x "$app" || true

            # Wait loop with timeout to prevent infinite hangs
            waited=0
            while pgrep -x "$app" >/dev/null 2>&1; do
                if ((waited >= KILL_TIMEOUT)); then
                    log_warn "Process $app is unresponsive. Forcing exit (SIGKILL)..."
                    pkill -9 -x "$app" 2>/dev/null || true
                    sleep 0.2 # Allow kernel a moment to clean up
                    break
                fi
                sleep 0.1
                waited=$((waited + 1))
            done
        fi
    done

    # B. Stop Systemd Services
    local service
    for service in "${SERVICES[@]}"; do
        if systemctl --user is-active --quiet "$service" 2>/dev/null; then
            log_info "Stopping service: $service"
            systemctl --user stop "$service" || log_warn "Failed to stop $service"
        fi
    done

    SERVICES_STOPPED=true
}

restart_services() {
    # Only attempt restart if we actually stopped them
    [[ $SERVICES_STOPPED == true ]] || return 0

    # Only restart if in a Wayland session
    if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
        log_info "Restarting background services..."
        local service
        for service in "${SERVICES[@]}"; do
            # Use try-restart or start. 'start' is fine here as we want them running.
            systemctl --user start "$service" 2>/dev/null || true
        done
    fi
}

cleanup() {
    local exit_code=$?
    if ((exit_code != 0)); then
        log_err "Script failed with exit code $exit_code"
    fi
    restart_services
    # Cleanup lock file (flock releases automatically, but we remove the file)
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# ==============================================================================
#  CORE FUNCTIONS
# ==============================================================================

do_backup() {
    log_info "Starting BACKUP operation..."

    # Ensure backup root exists
    mkdir -p "$BACKUP_DIR"

    stop_services

    local moved_count=0
    local source_path backup_name dest_path

    for item in "${TARGETS[@]}"; do
        source_path=${item%%:*}
        backup_name=${item##*:}
        dest_path="${BACKUP_DIR}/${backup_name}"

        if [[ -e $source_path ]]; then
            # Clean old backup artifact
            rm -rf "$dest_path"
            
            # Move source to backup
            mv "$source_path" "$dest_path"
            log_ok "Moved ${BOLD}${source_path##*/}${RESET} -> Backup"
            
            # Safe increment avoiding set -e exit on zero
            moved_count=$((moved_count + 1))
        else
            log_warn "Source not found, skipping: $source_path"
        fi
    done

    # Flush file buffers to disk before allowing services to restart
    sync

    if ((moved_count == 0)); then
        log_warn "No files were found to backup."
    else
        log_ok "Backup complete. $moved_count item(s) moved to: $BACKUP_DIR"
    fi
}

do_restore() {
    log_info "Starting RESTORE operation..."

    if [[ ! -d $BACKUP_DIR ]]; then
        log_err "No backup directory found at: $BACKUP_DIR"
        exit 1
    fi

    stop_services

    local restored_count=0
    local source_path backup_name backup_source parent_dir

    for item in "${TARGETS[@]}"; do
        source_path=${item%%:*}
        backup_name=${item##*:}
        backup_source="${BACKUP_DIR}/${backup_name}"
        
        # Fast parameter expansion instead of $(dirname ...)
        parent_dir=${source_path%/*}

        if [[ -e $backup_source ]]; then
            mkdir -p "$parent_dir"

            # If current live data exists, nuke it to replace with backup
            if [[ -e $source_path ]]; then
                log_warn "Overwriting existing data at: $source_path"
                rm -rf "$source_path"
            fi

            mv "$backup_source" "$source_path"
            log_ok "Restored ${BOLD}${backup_name}${RESET} -> ${source_path}"
            
            restored_count=$((restored_count + 1))
        else
            log_info "Backup artifact not found for: $backup_name"
        fi
    done

    # Flush file buffers to disk before allowing services to restart
    sync

    if ((restored_count == 0)); then
        log_warn "Nothing was restored. Backup folder might be empty or corrupt."
    else
        log_ok "Restore complete. $restored_count item(s) restored."
        # Clean up backup dir if empty
        rmdir "$BACKUP_DIR" 2>/dev/null || true
    fi
}

do_delete() {
    log_warn "Starting DELETE operation..."
    log_warn "This will PERMANENTLY remove data from BOTH the live system and backups."

    stop_services

    local deleted_count=0
    local source_path backup_name backup_path

    for item in "${TARGETS[@]}"; do
        source_path=${item%%:*}
        backup_name=${item##*:}
        backup_path="${BACKUP_DIR}/${backup_name}"

        # 1. Delete Live Data
        if [[ -e $source_path ]]; then
            rm -rf "$source_path"
            log_ok "Deleted Live: ${source_path}"
            deleted_count=$((deleted_count + 1))
        fi

        # 2. Delete Backup Data
        if [[ -e $backup_path ]]; then
            rm -rf "$backup_path"
            log_ok "Deleted Backup: ${backup_path}"
            deleted_count=$((deleted_count + 1))
        fi
    done

    # Flush changes
    sync

    # Cleanup empty backup root if possible
    if [[ -d $BACKUP_DIR ]]; then
        rmdir "$BACKUP_DIR" 2>/dev/null || true
    fi

    if ((deleted_count == 0)); then
        log_warn "No files found to delete in either location."
    else
        log_ok "Cleanup complete. $deleted_count items removed."
    fi
}

show_help() {
    cat <<EOF
Usage: ${0##*/} [OPTION]

Manage backup/restore of Cliphist and Errands data.

Options:
    --backup     Move current data to backup storage
    --restore    Restore data from backup
    --delete     Permanently delete data from BOTH live and backup locations
    --help, -h   Show this help message

Without options, an interactive menu is displayed.
EOF
}

# ==============================================================================
#  MAIN ENTRY POINT
# ==============================================================================

main() {
    local mode=""

    # 1. Argument Parsing
    while (($# > 0)); do
        case $1 in
            --backup)
                [[ -z $mode ]] || { log_err "Conflicting options selected."; exit 1; }
                mode="backup"
                ;;
            --restore)
                [[ -z $mode ]] || { log_err "Conflicting options selected."; exit 1; }
                mode="restore" 
                ;;
            --delete)
                [[ -z $mode ]] || { log_err "Conflicting options selected."; exit 1; }
                mode="delete"
                ;;
            --help|-h) 
                show_help; exit 0 
                ;;
            *)
                log_err "Unknown argument: $1"
                show_help >&2
                exit 1
                ;;
        esac
        shift
    done

    # 2. Interactive Menu (If no args)
    if [[ -z $mode ]]; then
        # Check for TTY to avoid infinite loops or hangs in non-interactive shells
        if [[ ! -t 0 ]]; then
            log_err "No TTY detected. Interactive mode requires a terminal."
            log_err "Use --backup, --restore, or --delete flags."
            exit 1
        fi

        printf '\n%sSelect an operation:%s\n' "$BOLD" "$RESET"
        PS3="> "
        local options=(
            "Backup (Move current data to storage)" 
            "Restore (Move stored data back)" 
            "Delete (Permanently wipe ALL data)"
            "Cancel"
        )
        
        select opt in "${options[@]}"; do
            case $opt in
                "Backup (Move current data to storage)")
                    mode="backup"; break ;;
                "Restore (Move stored data back)")
                    mode="restore"; break ;;
                "Delete (Permanently wipe ALL data)")
                    mode="delete"; break ;;
                "Cancel")
                    log_info "Operation cancelled."; exit 0 ;;
                *)
                    log_warn "Invalid selection: $REPLY" ;;
            esac
        done

        # Handle Ctrl+D (EOF) gracefully
        if [[ -z $mode ]]; then
            printf '\n'
            log_info "Operation cancelled (EOF)."
            exit 0
        fi
    fi

    # 3. Execution
    case $mode in
        backup)  do_backup ;;
        restore) do_restore ;;
        delete)  do_delete ;;
    esac
}

main "$@"
