#!/usr/bin/env bash

###############################################################################
# bin/library/library_refresh.sh
#
# Version:       1.0.0
# Last updated:  2026-09-12
#
# -----------------------------------------------------------------------------
# PURPOSE
# -----------------------------------------------------------------------------
#   Orchestrate the freshness loop of the personal library (myprivatelib):
#   decide whether the on-disk Books collection changed since the last
#   population run, and if so run the safety backup + the rebuild, then
#   write an updated checkpoint.
#
#   The checkpoint is a RECURSIVE TREE FINGERPRINT of the Books tree - one
#   line per file: relative path, size, mtime (epoch seconds).  It is
#   deliberately not a single `stat` of the root directory: folder mtimes
#   do not reliably propagate on the Windows/9P mount when files are added
#   to subfolders, so a root-only stat would miss real changes.  A changed
#   fingerprint means "at least one file was added / removed / resized /
#   touched" - exactly the conditions that change what populate must
#   represent.
#
#   Pipeline, in order (each step is skippable):
#
#       1. fingerprint the Books tree          (find -printf, sorted)
#       2. compare against the checkpoint file -> up-to-date or needs-work
#       3. needs-work:
#            a. library_backup.sh         (safety dump before the purge)
#            b. library_populate.sh       (md5 match + verbatim keys)
#       4. write the new checkpoint (mtime = run stamp)
#
#   Steps a/b delegate to the existing tools via `bash "$tool"` with
#   REFRESH_MYSQL_ARGS forwarded (MYSQL_* env vars pass through untouched);
#   the orchestrator itself never talks to MariaDB - single responsibility:
#   change detection + sequencing.  populate and backup handle the server
#   lifecycle themselves (a running server is left untouched by both, so
#   the pipeline runs cleanly against an already-up server too).
#
#   Exit contract for automation (cron / CI):
#       0   success (including "nothing to do" - NOT an error)
#       1   operational failure (library root missing, backup or populate
#           failed, checkpoint unwritable)
#
#   The checkpoint lives in the report dir (default:
#   /mnt/c/Backup_Go7/merge-reports/refresh_checkpoint.tsv) so it sits next
#   to the populate reports it complements.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#   ./bin/library/library_refresh.sh [options]
#
#   Options:
#       -f, --force          skip the checkpoint comparison, always run
#                            backup + populate (initial run / repair)
#       -n, --dry-run        report the decision and what would run, change
#                            nothing, do NOT write a checkpoint
#       -s, --status         print the current checkpoint state and exit
#       -d, --debug          print verbose diagnostics to stderr
#       -h, --help           show this help
#       -v, --version        print version and exit
#
#   Exit codes:
#       0   success (up to date, or refresh completed)
#       1   operational failure
#       2   usage error
#
#   Environment / config (config/library_refresh.conf; all overridable):
#       REFRESH_LIBRARY_ROOT   the Books tree to watch (default:
#                              /mnt/c/Backup_Go7/Books - keep in sync with
#                              POP_LIBRARY_ROOT)
#       REFRESH_REPORT_DIR     where the checkpoint + reports go
#                              (default: /mnt/c/Backup_Go7/merge-reports)
#       REFRESH_CHECKPOINT     checkpoint file name inside REPORT_DIR
#                              (default: refresh_checkpoint.tsv)
#       REFRESH_MYSQL_ARGS     forwarded to backup/populate as extra args
#                              (default: empty)
#       MYSQL_*                pass through to the child tools untouched
#
###############################################################################

set -euo pipefail

# --- shared infrastructure (refactor Phase 3) ----------------------------------
# common.sh sets set -Eeuo pipefail, resolves SCRIPT_DIR/PROJECT_ROOT at any
# bin/ depth, and provides log/debug/die.
# shellcheck source=../../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/common.sh"
common_init

# SCRIPT_VERSION is parsed from this file's own header (version-sync contract).
# shellcheck disable=SC2155  # sed+head pipeline cannot fail; masking not a concern
readonly SCRIPT_VERSION="$(sed -n 's/^# Version:[[:space:]]*//p' "$0" | head -n 1)"

# --- config file ---------------------------------------------------------------
CONF_FILE="${CONF_FILE:-$PROJECT_ROOT/config/library_refresh.conf}"
# shellcheck source=../../config/library_refresh.conf
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"

REFRESH_LIBRARY_ROOT="${REFRESH_LIBRARY_ROOT:-/mnt/c/Backup_Go7/Books}"
REFRESH_REPORT_DIR="${REFRESH_REPORT_DIR:-/mnt/c/Backup_Go7/merge-reports}"
REFRESH_CHECKPOINT="${REFRESH_CHECKPOINT:-refresh_checkpoint.tsv}"
REFRESH_MYSQL_ARGS="${REFRESH_MYSQL_ARGS:-}"

DRY_RUN=0
FORCE=0
STATUS_ONLY=0
DEBUG=0

checkpoint_file="$REFRESH_REPORT_DIR/$REFRESH_CHECKPOINT"

# --- 1. fingerprint: rel path, size, mtime (epoch), C-sorted --------------------
tree_fingerprint() { # root -> writes one TSV line per file to stdout
    local root="$1"
    # -printf with %p|%s|%T@ is GNU find; LC_ALL=C keeps the sort byte-stable
    # so identical trees produce byte-identical fingerprints.
    ( cd "$root" && find . -type f ! -name '.*' \
        -printf '%P\t%s\t%T@\n' | LC_ALL=C sort )
}

# --- decision --------------------------------------------------------------------
# Prints "up-to-date", "changed", or "no-checkpoint"; with --debug also a
# short diff summary (first few differing paths).
decide() {
    if [[ ! -s "$checkpoint_file" ]]; then
        printf 'no-checkpoint'
        return 0
    fi
    local now_f="$tmp/now.tsv"
    tree_fingerprint "$REFRESH_LIBRARY_ROOT" > "$now_f"
    if cmp -s "$now_f" "$checkpoint_file"; then
        printf 'up-to-date'
        return 0
    fi
    if (( DEBUG )); then
        local added removed changed
        added="$(comm -13 <(LC_ALL=C sort "$checkpoint_file") "$now_f" | wc -l | tr -d ' ')"
        removed="$(comm -23 <(LC_ALL=C sort "$checkpoint_file") "$now_f" | wc -l | tr -d ' ')"
        changed="$(( added + removed ))"
        debug "fingerprint differs: $changed differing line(s) (added-or-changed=$added, removed=$removed)"
        diff <(LC_ALL=C sort "$checkpoint_file") "$now_f" | sed -n '3,9p' | sed 's/^/debug:   /'
    fi
    printf 'changed'
}

# --- 3a/3b. child tools -------------------------------------------------------------
run_tool() { # tool_path [args...]
    local tool="$1"; shift
    debug "running: bash $tool $*"
    bash "$tool" "$@" $REFRESH_MYSQL_ARGS
}

# --- main ------------------------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        -f|--force)   FORCE=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -s|--status)  STATUS_ONLY=1; shift ;;
        -d|--debug)   DEBUG=1; shift ;;
        -h|--help)
            cat >&2 <<'EOF'
Usage: library_refresh.sh [options]

Orchestrate the freshness loop of the personal library (myprivatelib):
fingerprint the on-disk Books tree (rel path + size + mtime per file),
compare against the checkpoint from the previous run, and when anything
changed run the safety backup (library_backup.sh) followed by the
rebuild (library_populate.sh), then write the new checkpoint.
The checkpoint is a recursive tree fingerprint - not a single stat of
the root folder - because folder mtimes do not reliably propagate on
the Windows mount when files land in subfolders.

Options:
  -f, --force     skip the checkpoint comparison; always refresh
  -n, --dry-run   report the decision and what would run; change nothing
  -s, --status    print the checkpoint state and exit
  -d, --debug     verbose diagnostics on stderr
  -h, --help      show this help
  -v, --version   print version and exit

Exit codes: 0 success (incl. up to date), 1 operational failure,
2 usage error.

Environment / config (config/library_refresh.conf, all overridable):
  REFRESH_LIBRARY_ROOT / REFRESH_REPORT_DIR / REFRESH_CHECKPOINT /
  REFRESH_MYSQL_ARGS; MYSQL_* pass through to the child tools.
EOF
            exit 0 ;;
        -v|--version) echo "bin/library/library_refresh.sh v$SCRIPT_VERSION"; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; echo "Try '$0 --help'." >&2; exit 2 ;;
    esac
done

[[ -d "$REFRESH_LIBRARY_ROOT" ]] || die "library root not found: $REFRESH_LIBRARY_ROOT"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/refresh.XXXXXX")"
cleanup() { rm -rf "$tmp"; return 0; }
trap cleanup EXIT

decision="$(decide)"

if (( STATUS_ONLY )); then
    printf 'checkpoint: %s\n' "$checkpoint_file"
    printf 'state:      %s\n' "$decision"
    if [[ -s "$checkpoint_file" ]]; then
        printf 'checkpointed files: %s\n' "$(wc -l < "$checkpoint_file" | tr -d ' ')"
        printf 'checkpoint written: %s\n' "$(date -r "$checkpoint_file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
    fi
    exit 0
fi

log "info : refresh decision: $decision$( (( FORCE )) && printf ' (forced)' )"

case "$decision" in
    up-to-date)
        if (( FORCE )); then
            : # fall through to the refresh below
        else
            log "info : Books tree unchanged since the last refresh; nothing to do"
            exit 0
        fi
        ;;
esac

if (( DRY_RUN )); then
    if (( FORCE )) || [[ "$decision" != "up-to-date" ]]; then
        log "dry-run: would back up myprivatelib (library_backup.sh)"
        log "dry-run: would rebuild myprivatelib from $REFRESH_LIBRARY_ROOT (library_populate.sh)"
        log "dry-run: would write the checkpoint to $checkpoint_file"
    fi
    exit 0
fi

# --- the real refresh: backup -> populate -> checkpoint ------------------------------
log "info : step 1/3: safety backup"
run_tool "$PROJECT_ROOT/bin/library/library_backup.sh" \
    || die "backup failed; myprivatelib left untouched (populate not run)"

log "info : step 2/3: rebuild"
run_tool "$PROJECT_ROOT/bin/library/library_populate.sh" \
    || die "populate failed; the pre-run backup above preserves the previous state"

log "info : step 3/3: checkpoint"
mkdir -p "$REFRESH_REPORT_DIR"
tree_fingerprint "$REFRESH_LIBRARY_ROOT" > "$checkpoint_file" \
    || die "cannot write checkpoint: $checkpoint_file"
log "info : checkpoint written: $checkpoint_file ($(wc -l < "$checkpoint_file" | tr -d ' ') file(s))"

log "info : refresh complete"
exit 0
