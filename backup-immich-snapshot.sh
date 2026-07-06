#!/usr/bin/env bash
#
# Immich backup template
# ----------------------
# What this script does:
#   1. Asks which Immich Docker compose folder to use.
#   2. Asks where the backup destination lives.
#   3. Optionally asks for an external library path.
#   4. Optionally installs a cron job for future runs.
#   5. Dumps the Immich database.
#   6. Stops the Immich compose stack briefly.
#   7. Copies the media storage and optional external library.
#   8. Starts Immich again even if something fails.
#
# Safety notes:
#   - The backup destination must already exist.
#   - The backup destination must be writable.
#   - The script refuses to back up into a path that looks like the source tree.
#   - Cron installation is optional.
#   - The cron job re-runs this script in non-interactive mode with saved paths.
#
# Usage:
#   bash backup-immich-template.sh
#   bash backup-immich-template.sh --once --yes \
#     --immich-dir /path/to/immich-app \
#     --backup-dir /path/to/backups \
#     --media-dir /path/to/immich-storage \
#     [--external-library /path/to/external/library] \
#     [--db-service postgres_service_name]
#
# Notes for cron:
#   - Use --once so the scheduled job skips the cron-setup prompts.
#   - Use --yes so the scheduled job skips the final confirmation prompt.
#   - The backup destination must still exist when the cron job runs.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
BASH_BIN="$(command -v bash || true)"

AUTO_YES=false
RUN_ONCE=false
IMMICH_DIR=""
BACKUP_ROOT=""
MEDIA_ROOT=""
EXTERNAL_LIBRARY=""
DB_SERVICE=""
COMPOSE_FILE=""
SERVICES_STOPPED=false
TIMESTAMP=""
BACKUP_DIR=""
LOG_FILE=""
DATABASE_DUMP_FILE=""
MANIFEST_FILE=""

usage() {
    cat <<EOF
Immich backup template

This script asks for the Immich compose folder, backup destination,
optional external library, and optional cron schedule. It then creates
an Immich database dump, stops the compose stack briefly, copies the
media files, and starts Immich again.

Options:
  --immich-dir PATH        Path to the Immich Docker compose folder
  --backup-dir PATH        Existing backup destination directory
  --media-dir PATH         Immich media storage directory to copy
  --external-library PATH  Optional external library path to copy
  --db-service NAME        PostgreSQL service name inside the compose file
  --yes                    Skip the final confirmation prompt
  --once                   Run the backup now and skip cron setup prompts
  -h, --help               Show this help text

Example:
  bash "$SCRIPT_PATH" --once --yes \
    --immich-dir /srv/immich \
    --backup-dir /mnt/backups \
    --media-dir /srv/immich/storage \
    --external-library /srv/media/external \
    --db-service immich_postgres
EOF
}

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

display_banner() {
    local -a banner_lines=(
" ██╗ ███╗   ███╗ ███╗   ███╗ ██╗  ██████╗ ██╗  ██╗     ███████╗ ███╗   ██╗  █████╗  ██████╗  ███████╗ ██╗  ██╗  ██████╗  ████████╗ "
" ██║ ████╗ ████║ ████╗ ████║ ██║ ██╔════╝ ██║  ██║     ██╔════╝ ████╗  ██╗ ██╔══██╗ ██╔══██╗ ██╔════╝ ██║  ██║ ██╔═══██╗ ╚══██╔══╝ "
" ██║ ██╔████╔██║ ██╔████╔██║ ██║ ██║      ███████║     ███████╗ ██╔██╗ ██║ ███████║ ██████╔╝ ███████╗ ███████║ ██║   ██║    ██║    "
" ██║ ██║╚██╔╝██║ ██║╚██╔╝██║ ██║ ██║      ██╔══██║     ╚════██║ ██║╚██╗██║ ██╔══██║ ██╔═══╝  ╚════██║ ██╔══██║ ██║   ██║    ██║    "
" ██║ ██║ ╚═╝ ██║ ██║ ╚═╝ ██║ ██║ ╚██████╗ ██║  ██║     ███████║ ██║ ╚████║ ██║  ██║ ██║      ███████║ ██║  ██║ ╚██████╔╝    ██║    "
" ╚═╝ ╚═╝     ╚═╝ ╚═╝     ╚═╝ ╚═╝  ╚═════╝ ╚═╝  ╚═╝     ╚══════╝ ╚═╝  ╚═══╝ ╚═╝  ╚═╝ ╚═╝      ╚══════╝ ╚═╝  ╚═╝  ╚═════╝     ╚═╝    "
    )

    printf '\n'
    for line in "${banner_lines[@]}"; do
        printf '%s\n' "$line"
    done
    printf '%s\n' "   An incremental backup workflow for Immich snapshots"
    printf '%s\n' "   By Akshay Krishna"
    printf '\n'
}

confirm() {
    # Returns 0 for yes, 1 for no.
    local prompt="$1"
    local reply

    while true; do
        read -r -p "$prompt [y/N]: " reply || return 1
        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no|'') return 1 ;;
            *) log "Please answer y or n." ;;
        esac
    done
}

prompt_text() {
    local prompt="$1"
    local value

    while true; do
        read -r -p "$prompt: " value || return 1
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
        log "Please enter a non-empty value."
    done
}

prompt_int_range() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local value

    while true; do
        read -r -p "$prompt: " value || return 1
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
            printf '%s\n' "$value"
            return 0
        fi
        log "Please enter a number between $min and $max."
    done
}

prompt_choice() {
    printf '%s\n' "Choose a schedule option:" >&2
    printf '%s\n' "  [1] Daily" >&2
    printf '%s\n' "  [2] Weekly" >&2
    printf '%s\n' "  [3] Twice a month" >&2
    printf '%s\n' "  [4] Once a month" >&2
    printf '%s\n' "  [5] Perform once now" >&2

    local choice
    while true; do
        read -r -p "Enter 1-5: " choice || return 1
        case "$choice" in
            1|2|3|4|5)
                printf '%s\n' "$choice"
                return 0
                ;;
            *)
                printf '%s\n' "Please choose one of 1, 2, 3, 4, or 5." >&2
                ;;
        esac
    done
}

canonical_dir() {
    cd -- "$1" && pwd -P
}

path_is_within() {
    # Usage: path_is_within CHILD PARENT
    local child="$1"
    local parent="$2"

    [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

write_backup_manifest() {
    local manifest_file="$1"

    MANIFEST_FILE="$manifest_file"
    python3 - "$manifest_file" "$IMMICH_DIR" "$BACKUP_ROOT" "$BACKUP_DIR" "$COMPOSE_FILE" "$DB_SERVICE" "$MEDIA_ROOT" "${EXTERNAL_LIBRARY:-}" <<'PY'
import json
import os
import subprocess
import sys

manifest_file, immich_dir, backup_root, backup_dir, compose_file, db_service, media_root, external_library = sys.argv[1:9]

def run(cmd):
    return subprocess.check_output(cmd, text=True).splitlines()

services = run(["docker", "compose", "-f", compose_file, "config", "--services"])
images = run(["docker", "compose", "-f", compose_file, "config", "--images"])

manifest = {
    "script": "backup-immich-snapshot.sh",
    "immich_dir": immich_dir,
    "backup_root": backup_root,
    "backup_dir": backup_dir,
    "compose_file": compose_file,
    "db_service": db_service,
    "media_root": media_root,
    "external_library": external_library or None,
    "compose_services": services,
    "compose_images": images,
}

with open(manifest_file, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

find_compose_file() {
    local dir="$1"
    local candidate

    for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [[ -f "$dir/$candidate" ]]; then
            printf '%s\n' "$dir/$candidate"
            return 0
        fi
    done

    return 1
}

read_env_value() {
    # Simple parser for Immich-style .env files.
    # It expects lines like KEY=value or KEY="value".
    local file="$1"
    local key="$2"
    local line

    line="$(grep -m1 -E "^${key}=" "$file" 2>/dev/null || true)"
    [[ -n "$line" ]] || return 1
    line="${line#${key}=}"
    line="$(printf '%s' "$line" | sed 's/\r$//; s/^"//; s/"$//')"
    printf '%s\n' "$line"
}

auto_detect_db_service() {
    local services=()
    local service candidate

    mapfile -t services < <(docker compose -f "$COMPOSE_FILE" config --services)

    for candidate in immich_postgres immich-postgres postgres postgresql db database immich_db immich-db postgres-db; do
        for service in "${services[@]}"; do
            if [[ "$service" == "$candidate" ]]; then
                printf '%s\n' "$service"
                return 0
            fi
        done
    done

    return 1
}

build_cron_command() {
    local -a cron_args=(
        "$BASH_BIN"
        "$SCRIPT_PATH"
        --yes
        --once
        --immich-dir "$IMMICH_DIR"
        --backup-dir "$BACKUP_ROOT"
        --media-dir "$MEDIA_ROOT"
        --db-service "$DB_SERVICE"
    )

    if [[ -n "$EXTERNAL_LIBRARY" ]]; then
        cron_args+=(--external-library "$EXTERNAL_LIBRARY")
    fi

    # Print a shell-escaped command string that cron can execute safely.
    printf '%q ' "${cron_args[@]}"
}

install_cron_job() {
    local schedule_expr="$1"
    local cron_command="$2"
    local begin_marker='# BEGIN IMMICH BACKUP TEMPLATE'
    local end_marker='# END IMMICH BACKUP TEMPLATE'
    local current_cron filtered_cron

    need_cmd crontab

    current_cron="$(mktemp)"
    filtered_cron="$(mktemp)"

    crontab -l >"$current_cron" 2>/dev/null || true

    awk -v begin="$begin_marker" -v end="$end_marker" '
        $0 == begin { skip = 1; next }
        $0 == end   { skip = 0; next }
        skip != 1 { print }
    ' "$current_cron" >"$filtered_cron"

    {
        printf '%s\n' "$begin_marker"
        printf '%s %s\n' "$schedule_expr" "$cron_command"
        printf '%s\n' "$end_marker"
    } >>"$filtered_cron"

    crontab "$filtered_cron"

    rm -f "$current_cron" "$filtered_cron"

    log "Cron job installed successfully."
    log "Cron entry:"
    log "  $schedule_expr $cron_command"
}

cleanup() {
    local exit_code=$?

    trap - EXIT
    set +e

    if [[ "$SERVICES_STOPPED" == true ]]; then
        log "Restoring Immich compose stack..."
        docker compose -f "$COMPOSE_FILE" up -d
    fi

    exit "$exit_code"
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Parse command-line arguments
# -----------------------------------------------------------------------------
while (($#)); do
    case "$1" in
        --immich-dir)
            IMMICH_DIR="${2:-}"
            [[ -n "$IMMICH_DIR" ]] || die "--immich-dir requires a path"
            shift 2
            ;;
        --backup-dir)
            BACKUP_ROOT="${2:-}"
            [[ -n "$BACKUP_ROOT" ]] || die "--backup-dir requires a path"
            shift 2
            ;;
        --media-dir)
            MEDIA_ROOT="${2:-}"
            [[ -n "$MEDIA_ROOT" ]] || die "--media-dir requires a path"
            shift 2
            ;;
        --external-library)
            EXTERNAL_LIBRARY="${2:-}"
            [[ -n "$EXTERNAL_LIBRARY" ]] || die "--external-library requires a path"
            shift 2
            ;;
        --db-service)
            DB_SERVICE="${2:-}"
            [[ -n "$DB_SERVICE" ]] || die "--db-service requires a service name"
            shift 2
            ;;
        --yes)
            AUTO_YES=true
            shift
            ;;
        --once)
            RUN_ONCE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
need_cmd docker
need_cmd rsync
need_cmd gzip
need_cmd sed
need_cmd awk
need_cmd grep
need_cmd mktemp

display_banner

# -----------------------------------------------------------------------------
# Ask which Immich compose folder to use.
# -----------------------------------------------------------------------------
while true; do
    if [[ -z "$IMMICH_DIR" ]]; then
        if confirm "Is the current folder your Immich Docker folder?"; then
            IMMICH_DIR="$(pwd -P)"
        else
            IMMICH_DIR="$(prompt_text "Enter the full path to the Immich Docker folder")"
        fi
    fi

    if [[ -d "$IMMICH_DIR" ]] && COMPOSE_FILE="$(find_compose_file "$IMMICH_DIR" 2>/dev/null)"; then
        IMMICH_DIR="$(canonical_dir "$IMMICH_DIR")"
        COMPOSE_FILE="$(find_compose_file "$IMMICH_DIR")"
        break
    fi

    warn "No supported compose file was found in: $IMMICH_DIR"
    IMMICH_DIR=""
done

cd "$IMMICH_DIR"

# -----------------------------------------------------------------------------
# Ask where the backup should be stored.
# -----------------------------------------------------------------------------
while true; do
    if [[ -z "$BACKUP_ROOT" ]]; then
        BACKUP_ROOT="$(prompt_text "Enter the existing backup destination directory")"
    fi

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        die "Backup destination does not exist: $BACKUP_ROOT. Create it first, then rerun the script."
    fi

    if [[ ! -w "$BACKUP_ROOT" || ! -x "$BACKUP_ROOT" ]]; then
        die "Backup destination is not writable/executable: $BACKUP_ROOT"
    fi

    BACKUP_ROOT="$(canonical_dir "$BACKUP_ROOT")"
    break
done

# -----------------------------------------------------------------------------
# Ask if an external library is attached.
# -----------------------------------------------------------------------------
if [[ -z "$EXTERNAL_LIBRARY" ]]; then
    if confirm "Is an external library attached?"; then
        EXTERNAL_LIBRARY="$(prompt_text "Enter the external library path")"
    fi
fi

if [[ -n "$EXTERNAL_LIBRARY" ]]; then
    if [[ ! -d "$EXTERNAL_LIBRARY" ]]; then
        die "External library path does not exist: $EXTERNAL_LIBRARY"
    fi
    EXTERNAL_LIBRARY="$(canonical_dir "$EXTERNAL_LIBRARY")"
fi

# -----------------------------------------------------------------------------
# Detect the media storage path.
# Prefer UPLOAD_LOCATION from the Immich .env file when available.
# -----------------------------------------------------------------------------
if [[ -z "$MEDIA_ROOT" ]]; then
    if [[ -f "$IMMICH_DIR/.env" ]]; then
        MEDIA_ROOT="$(read_env_value "$IMMICH_DIR/.env" "UPLOAD_LOCATION" || true)"
    fi
fi

if [[ -z "$MEDIA_ROOT" ]]; then
    MEDIA_ROOT="$(prompt_text "Enter the Immich media storage path")"
fi

if [[ "$MEDIA_ROOT" != /* ]]; then
    MEDIA_ROOT="$IMMICH_DIR/$MEDIA_ROOT"
fi

if [[ ! -d "$MEDIA_ROOT" ]]; then
    die "Immich media storage path does not exist: $MEDIA_ROOT"
fi

MEDIA_ROOT="$(canonical_dir "$MEDIA_ROOT")"

# Do not allow the backup destination to live inside the source tree.
if path_is_within "$BACKUP_ROOT" "$IMMICH_DIR"; then
    die "Backup destination must not be inside the Immich compose folder. Choose a separate backup path."
fi

if path_is_within "$BACKUP_ROOT" "$MEDIA_ROOT"; then
    die "Backup destination must not be inside the Immich media storage path. Choose a separate backup path."
fi

# -----------------------------------------------------------------------------
# Detect the database service.
# We try common Immich/PostgreSQL names first, then ask the user.
# -----------------------------------------------------------------------------
if [[ -z "$DB_SERVICE" ]]; then
    if DB_SERVICE="$(auto_detect_db_service 2>/dev/null)"; then
        :
    else
        log "Available compose services:"
        docker compose -f "$COMPOSE_FILE" config --services | sed 's/^/  - /'
        DB_SERVICE="$(prompt_text "Enter the PostgreSQL service name")"
    fi
fi

if ! docker compose -f "$COMPOSE_FILE" config --services | grep -Fxq "$DB_SERVICE"; then
    die "The selected database service was not found in the compose file: $DB_SERVICE"
fi

# -----------------------------------------------------------------------------
# Ask whether this backup should be scheduled as a cron job.
# If cron is selected, install it and still continue with the current backup run.
# -----------------------------------------------------------------------------
if [[ "$RUN_ONCE" == false ]]; then
    schedule_expr=""
    schedule_choice="$(prompt_choice)"
    case "$schedule_choice" in
        1)
            schedule_hour="$(prompt_int_range "Enter the hour for the daily backup (0-23)" 0 23)"
            schedule_expr="0 $schedule_hour * * *"
            ;;
        2)
            schedule_hour="$(prompt_int_range "Enter the hour for the weekly backup (0-23)" 0 23)"
            schedule_dow="$(prompt_int_range "Enter the day of week for the weekly backup (0=Sun, 7=Sun)" 0 7)"
            schedule_expr="0 $schedule_hour * * $schedule_dow"
            ;;
        3)
            schedule_hour="$(prompt_int_range "Enter the hour for the twice-monthly backup (0-23)" 0 23)"
            schedule_dom="$(prompt_text "Enter two days of month separated by a comma (example: 1,15)")"
            if [[ ! "$schedule_dom" =~ ^([1-9]|[12][0-9]|3[01]),([1-9]|[12][0-9]|3[01])$ ]]; then
                die "Twice-monthly day values must look like 1,15 or 5,20"
            fi
            schedule_expr="0 $schedule_hour $schedule_dom * *"
            ;;
        4)
            schedule_hour="$(prompt_int_range "Enter the hour for the monthly backup (0-23)" 0 23)"
            schedule_dom="$(prompt_int_range "Enter the day of month for the monthly backup (1-31)" 1 31)"
            schedule_expr="0 $schedule_hour $schedule_dom * *"
            ;;
        5)
            schedule_expr=""
            ;;
    esac

    if [[ -n "$schedule_expr" ]]; then
        cron_command="$(build_cron_command)"
        log "This will install a cron job and still continue with the current backup run."
        log "Planned cron line:"
        log "  $schedule_expr $cron_command"
        if confirm "Install this cron job now?"; then
            if ! install_cron_job "$schedule_expr" "$cron_command"; then
                warn "Cron installation failed. The immediate backup can still continue."
            fi
        else
            warn "Cron installation skipped by the user."
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Final confirmation before touching live services.
# -----------------------------------------------------------------------------
log ""
log "Backup summary:"
log "  Immich compose folder : $IMMICH_DIR"
log "  Compose file           : $COMPOSE_FILE"
log "  Backup destination     : $BACKUP_ROOT"
log "  Media storage source   : $MEDIA_ROOT"
log "  External library       : ${EXTERNAL_LIBRARY:-<none>}"
log "  Database service       : $DB_SERVICE"
log ""

if [[ "$AUTO_YES" == false ]]; then
    confirm "Proceed with the backup now?" || die "Cancelled by user."
fi

# -----------------------------------------------------------------------------
# Create the backup destination structure.
# -----------------------------------------------------------------------------
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
BACKUP_DIR="$BACKUP_ROOT/immich-backup-$TIMESTAMP"
mkdir -p "$BACKUP_DIR/database" "$BACKUP_DIR/media" "$BACKUP_DIR/logs"
if [[ -n "$EXTERNAL_LIBRARY" ]]; then
    mkdir -p "$BACKUP_DIR/external"
fi

LOG_FILE="$BACKUP_DIR/logs/backup-$TIMESTAMP.log"
DATABASE_DUMP_FILE="$BACKUP_DIR/database/immich-database-$TIMESTAMP.sql.gz"
MANIFEST_FILE="$BACKUP_DIR/backup-manifest.json"

# Mirror all output to the log file once the backup directory exists.
exec > >(tee -a "$LOG_FILE") 2>&1

write_backup_manifest "$MANIFEST_FILE"

log "======================================================"
log "Immich backup started: $(date)"
log "Immich compose folder:  $IMMICH_DIR"
log "Compose file:           $COMPOSE_FILE"
log "Media storage source:   $MEDIA_ROOT"
log "External library:       ${EXTERNAL_LIBRARY:-<none>}"
log "Backup destination:     $BACKUP_DIR"
log "======================================================"

# -----------------------------------------------------------------------------
# Back up the Immich database while the database container is still running.
# We try common environment variables inside the database container so the
# template can work across different Immich compose setups.
# -----------------------------------------------------------------------------
log ""
log "Creating database dump..."

docker compose -f "$COMPOSE_FILE" exec -T "$DB_SERVICE" sh -lc '
    set -eu
    db_name="${DB_DATABASE_NAME:-${POSTGRES_DB:-}}"
    db_user="${DB_USERNAME:-${POSTGRES_USER:-}}"

    if [ -z "$db_name" ] || [ -z "$db_user" ]; then
        echo "ERROR: The database container does not expose DB_DATABASE_NAME/DB_USERNAME or POSTGRES_DB/POSTGRES_USER." >&2
        exit 1
    fi

    exec pg_dump --clean --if-exists --dbname="$db_name" --username="$db_user"
' | gzip -c > "$DATABASE_DUMP_FILE"

if [[ ! -s "$DATABASE_DUMP_FILE" ]]; then
    die "Database backup was not created correctly."
fi

gzip -t "$DATABASE_DUMP_FILE"
log "Database dump created: $DATABASE_DUMP_FILE"

# -----------------------------------------------------------------------------
# Stop Immich temporarily before copying the media files.
# This keeps the file copy consistent and reduces the chance of partial writes.
# -----------------------------------------------------------------------------
log ""
log "Stopping the Immich compose stack temporarily..."
docker compose -f "$COMPOSE_FILE" stop
SERVICES_STOPPED=true

# -----------------------------------------------------------------------------
# Back up the media storage and optional external library.
# -----------------------------------------------------------------------------
log ""
log "Backing up media storage..."
rsync -a --human-readable --info=progress2 --stats "$MEDIA_ROOT/" "$BACKUP_DIR/media/"

if [[ -n "$EXTERNAL_LIBRARY" ]]; then
    log ""
    log "Backing up external library..."
    rsync -a --human-readable --info=progress2 --stats "$EXTERNAL_LIBRARY/" "$BACKUP_DIR/external/"
fi

log ""
log "Backup size:"
du -sh "$BACKUP_DIR"

log ""
log "Immich backup completed successfully: $(date)"
log "Database dump: $DATABASE_DUMP_FILE"
log "Log file:      $LOG_FILE"
