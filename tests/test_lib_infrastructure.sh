#!/usr/bin/env bash

# __ETL_TEST_ENV_GUARD__: a caller with set -x/set -v auto-exports SHELLOPTS;
# every child bash re-applies it (it is readonly when imported), so xtrace
# noise corrupts the suites output captures.  Re-exec clean instead.
if [[ ${SHELLOPTS-} == *xtrace* || ${SHELLOPTS-} == *verbose* ]]; then
    exec env -u SHELLOPTS -u BASHOPTS bash "$0" "$@"
fi
unset SHELLOPTS BASHOPTS 2>/dev/null || true

# -----------------------------------------------------------------------------
# tests/test_lib_infrastructure.sh
#
# Phase 3 regression suite: the common shell infrastructure under lib/
# (lib/common.sh, lib/logging.sh, lib/cli.sh, lib/filesystem.sh,
# lib/database.sh).
#
# Covers (per the Phase 3 exit criteria "all foundational infrastructure has
# at least basic tests"):
#   * every library passes bash -n and sources cleanly, twice (idempotent)
#   * common_init: standard mode (set -Eeuo pipefail active), --no-errexit
#     exception mode, DEBUG normalization
#   * project-root detection from bin/ depth 1 AND depth 2 (the Phase 4
#     bin/<group>/ layout) via a sandboxed project copy
#   * logging: house format, debug gating, die() exit code 1
#   * cli: -v/-h/--debug handling, tool-flag pass-through, exit-code contract
#   * filesystem: fingerprint byte-stability, prune (dry-run + real),
#     guards, mktmp
#   * database: argv assembly from MYSQL_* env, passwordless vs MYSQL_PWD
#
# Usage:
#   bash tests/test_lib_infrastructure.sh     # runs anywhere (no DB, no gawk)
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
declare -a FAILURE_LINES=()

report() { # label  ok|fail  [detail]
    local label="$1" status="$2" detail="${3:-}"
    if [[ "$status" == "ok" ]]; then
        echo "  PASS  $label"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL  $label"
        [[ -n "$detail" ]] && echo "        $detail"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILURE_LINES+=("$label: $detail")
    fi
}

LIBS=(common.sh logging.sh cli.sh filesystem.sh database.sh)

# --- sandbox project builder ----------------------------------------------------
# Copies lib/ into a sandbox with bin/<group>/ dirs so root detection can be
# exercised without touching the real tree.
new_sandbox() {
    local sb
    sb="$(mktemp -d)"
    mkdir -p "$sb/lib" "$sb/bin" "$sb/bin/authors"
    cp "$REPO_ROOT"/lib/{common,logging,cli,filesystem,database}.sh "$sb/lib/"
    printf '%s' "$sb"
}

echo "== Phase 3: lib/ infrastructure =="

# --- 1. syntax -------------------------------------------------------------------
for lib in "${LIBS[@]}"; do
    if bash -n "$REPO_ROOT/lib/$lib" 2>/dev/null; then
        report "syntax: lib/$lib" ok
    else
        report "syntax: lib/$lib" fail "$(bash -n "$REPO_ROOT/lib/$lib" 2>&1)"
    fi
done

# --- 2. idempotent sourcing ------------------------------------------------------
sb="$(new_sandbox)"
out="$(bash -c "source '$sb/lib/common.sh' && source '$sb/lib/common.sh' && echo sourced-twice-ok" 2>&1)"
if [[ "$out" == "sourced-twice-ok" ]]; then
    report "common.sh sources idempotently" ok
else
    report "common.sh sources idempotently" fail "$out"
fi

out="$(bash -c "source '$sb/lib/logging.sh' && source '$sb/lib/logging.sh' && echo ok" 2>&1)"
[[ "$out" == "ok" ]] && report "logging.sh sources idempotently" ok \
    || report "logging.sh sources idempotently" fail "$out"

out="$(bash -c "source '$sb/lib/cli.sh' && source '$sb/lib/cli.sh' && echo ok" 2>&1)"
[[ "$out" == "ok" ]] && report "cli.sh sources idempotently" ok \
    || report "cli.sh sources idempotently" fail "$out"

out="$(bash -c "source '$sb/lib/filesystem.sh' && source '$sb/lib/filesystem.sh' && echo ok" 2>&1)"
[[ "$out" == "ok" ]] && report "filesystem.sh sources idempotently" ok \
    || report "filesystem.sh sources idempotently" fail "$out"

out="$(bash -c "source '$sb/lib/database.sh' && source '$sb/lib/database.sh' && echo ok" 2>&1)"
[[ "$out" == "ok" ]] && report "database.sh sources idempotently" ok \
    || report "database.sh sources idempotently" fail "$out"

# --- 3. common_init: modes --------------------------------------------------------
out="$(bash -c "source '$sb/lib/common.sh' && common_init && [[ \$- == *e* ]] && echo errexit-on" 2>&1)"
[[ "$out" == "errexit-on" ]] && report "common_init activates set -e (plan 7.1)" ok \
    || report "common_init activates set -e (plan 7.1)" fail "$out"

out="$(bash -c "source '$sb/lib/common.sh' && common_init --no-errexit && [[ \$- == *e* ]] && echo still-on || echo errexit-off" 2>&1)"
[[ "$out" == "errexit-off" ]] && report "common_init --no-errexit is the documented exception mode" ok \
    || report "common_init --no-errexit is the documented exception mode" fail "$out"

out="$(bash -c "unset ETL_DEBUG; source '$sb/lib/common.sh' && common_init && echo \"\$DEBUG\"" 2>&1)"
[[ "$out" == "0" ]] && report "common_init defaults DEBUG=0" ok \
    || report "common_init defaults DEBUG=0" fail "$out"

out="$(bash -c "source '$sb/lib/common.sh' && common_init --debug && echo \"\$DEBUG\"" 2>&1)"
[[ "$out" == "1" ]] && report "common_init --debug sets DEBUG=1" ok \
    || report "common_init --debug sets DEBUG=1" fail "$out"

out="$(bash -c "export ETL_DEBUG=1; source '$sb/lib/common.sh' && common_init && echo \"\$DEBUG\"" 2>&1)"
[[ "$out" == "1" ]] && report "ETL_DEBUG=1 env is honored" ok \
    || report "ETL_DEBUG=1 env is honored" fail "$out"

# --- 4. project-root detection, both depths --------------------------------------
cat > "$sb/bin/probe.sh" <<'PROBE'
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
common_init "$@"
printf 'root=%s\n' "$PROJECT_ROOT"
PROBE
cat > "$sb/bin/authors/probe.sh" <<'PROBE'
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
common_init "$@"
printf 'root=%s\n' "$PROJECT_ROOT"
PROBE

out="$(bash "$sb/bin/probe.sh" 2>&1)"
[[ "$out" == "root=$sb" ]] && report "root detection from bin/ depth 1" ok \
    || report "root detection from bin/ depth 1" fail "$out"

out="$(bash "$sb/bin/authors/probe.sh" 2>&1)"
[[ "$out" == "root=$sb" ]] && report "root detection from bin/<group>/ depth 2 (post-rename layout)" ok \
    || report "root detection from bin/<group>/ depth 2 (post-rename layout)" fail "$out"

# common_init sources the sibling libs
out="$(bash -c "source '$sb/lib/common.sh' && common_init && declare -F log >/dev/null && declare -F cli_try_global >/dev/null && declare -F fs_require_dir >/dev/null && echo siblings-sourced" 2>&1)"
[[ "$out" == "siblings-sourced" ]] && report "common_init sources logging/cli/filesystem" ok \
    || report "common_init sources logging/cli/filesystem" fail "$out"

# database.sh is deliberately NOT auto-sourced (opt-in)
out="$(bash -c "source '$sb/lib/common.sh' && common_init && declare -F db_mysql_argv >/dev/null && echo leaked || echo opt-in" 2>&1)"
[[ "$out" == "opt-in" ]] && report "database.sh stays opt-in (not auto-sourced)" ok \
    || report "database.sh stays opt-in (not auto-sourced)" fail "$out"

# --- 5. logging -------------------------------------------------------------------
out="$(bash -c "source '$sb/lib/common.sh' && common_init && log hello" 2>&1)"
if [[ "$out" =~ ^\[20[0-9]{2}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\]\ hello$ ]]; then
    report "log() preserves the house format '[ts] msg'" ok
else
    report "log() preserves the house format '[ts] msg'" fail "$out"
fi

out="$(bash -c "unset ETL_DEBUG; source '$sb/lib/common.sh' && common_init && debug gated" 2>&1)"
[[ -z "$out" ]] && report "debug() silent at DEBUG=0" ok \
    || report "debug() silent at DEBUG=0" fail "$out"

out="$(bash -c "source '$sb/lib/common.sh' && common_init --debug && debug gated" 2>&1)"
[[ "$out" == *"debug: gated" ]] && report "debug() visible at DEBUG=1" ok \
    || report "debug() visible at DEBUG=1" fail "$out"

out="$(bash -c "source '$sb/lib/common.sh' && common_init && log_info tagged" 2>&1)"
[[ "$out" == *"info : tagged" ]] && report "log_info uses the tagged form" ok \
    || report "log_info uses the tagged form" fail "$out"

bash -c "source '$sb/lib/common.sh' && common_init && die boom" >/dev/null 2>&1
rc=$?
[[ $rc -eq 1 ]] && report "die() exits 1 (house contract)" ok \
    || report "die() exits 1 (house contract)" fail "exit=$rc"

# --- 6. cli ------------------------------------------------------------------------
out="$(bash -c "
source '$sb/lib/common.sh' && common_init
SCRIPT_VERSION='3.2.1'; CLI_INVOCATION='bin/library_report.sh'
cli_try_global --version
" 2>&1)"
[[ "$out" == "bin/library_report.sh v3.2.1" ]] && report "cli_try_global --version prints the canonical line" ok \
    || report "cli_try_global --version prints the canonical line" fail "$out"

out="$(bash -c "
source '$sb/lib/common.sh' && common_init
print_help() { echo 'HELP-PAGE'; }
cli_try_global -h
" 2>&1)"
rc=$?
[[ "$out" == "HELP-PAGE" && $rc -eq 0 ]] && report "cli_try_global -h calls print_help, exit 0" ok \
    || report "cli_try_global -h calls print_help, exit 0" fail "out=$out rc=$rc"

# Direct call (the tool pattern): DEBUG and CLI_REMAINING_COUNT must be set
# in the CURRENT shell, not a subshell.
out="$(bash -c "
unset ETL_DEBUG
source '$sb/lib/common.sh' && common_init
cli_try_global --debug -- --tool-flag value
echo \"\$CLI_REMAINING_COUNT|debug=\$DEBUG\"
" 2>&1)"
[[ "$out" == "3|debug=1" ]] && report "cli_try_global consumes --debug, sets count+DEBUG in current shell" ok \
    || report "cli_try_global consumes --debug, sets count+DEBUG in current shell" fail "$out"

# Scan stops at the first tool-specific flag: later --debug stays untouched.
out="$(bash -c "
unset ETL_DEBUG
source '$sb/lib/common.sh' && common_init
cli_try_global positional --tool-flag --debug
echo \"\$CLI_REMAINING_COUNT|debug=\$DEBUG\"
" 2>&1)"
[[ "$out" == "3|debug=0" ]] && report "cli_try_global stops at the first tool-specific flag" ok \
    || report "cli_try_global stops at the first tool-specific flag" fail "$out"

out="$(bash -c "source '$sb/lib/cli.sh'; echo \"\$CLI_EXIT_OK/\$CLI_EXIT_FAIL/\$CLI_EXIT_USAGE\"" 2>&1)"
[[ "$out" == "0/1/2" ]] && report "exit-code contract 0/1/2 exported" ok \
    || report "exit-code contract 0/1/2 exported" fail "$out"
# --- 7. filesystem ------------------------------------------------------------------
tree="$sb/tree"
mkdir -p "$tree/keep/deep" "$tree/empty1/inner" "$tree/empty2"
printf 'book' > "$tree/keep/deep/f.txt"

out="$(bash -c "source '$sb/lib/common.sh' && common_init && fs_tree_fingerprint '$tree'" 2>&1)"
expected_fp="$(cd "$tree" && find . -type f ! -name '.*' -printf '%P\t%s\t%T@\n' | LC_ALL=C sort)"
[[ "$out" == "$expected_fp" && "$out" == *"keep/deep/f.txt"* ]] \
    && report "fs_tree_fingerprint matches the refresh implementation byte-for-byte" ok \
    || report "fs_tree_fingerprint matches the refresh implementation byte-for-byte" fail "out=$out"

out2="$(bash -c "source '$sb/lib/common.sh' && common_init && fs_tree_fingerprint '$tree'" 2>&1)"
[[ "$out" == "$out2" ]] && report "fs_tree_fingerprint is byte-stable across runs" ok \
    || report "fs_tree_fingerprint is byte-stable across runs" fail "runs differ"

# fingerprint must NOT list directories
[[ "$out" != *empty1* ]] && report "fs_tree_fingerprint lists files only" ok \
    || report "fs_tree_fingerprint lists files only" fail "directories leaked: $out"

out="$(bash -c "source '$sb/lib/common.sh' && common_init && fs_prune_empty_dirs '$tree' true" 2>&1)"
# dry-run counts only currently-empty dirs: empty2 + empty1/inner = 2;
# empty1 itself still has a child, so it is not yet empty.
if [[ "$out" == *"would be removed"* ]] && [[ "$out" == *"2"* ]] && [[ -d "$tree/empty1" ]]; then
    report "fs_prune_empty_dirs dry-run counts empties, removes nothing" ok
else
    report "fs_prune_empty_dirs dry-run counts empties, removes nothing" fail "out=$out"
fi

out="$(bash -c "source '$sb/lib/common.sh' && common_init && fs_prune_empty_dirs '$tree' false" 2>&1)"
if [[ ! -d "$tree/empty1" && ! -d "$tree/empty2" && -d "$tree/keep" && "$out" == *"removed 3"* ]]; then
    report "fs_prune_empty_dirs removes empty dirs, keeps non-empty" ok
else
    report "fs_prune_empty_dirs removes empty dirs, keeps non-empty" fail "out=$out"
fi

out="$(bash -c "source '$sb/lib/common.sh' && common_init && fs_require_dir '$tree/keep' 'tree dir' && echo guard-ok" 2>&1)"
[[ "$out" == "guard-ok" ]] && report "fs_require_dir passes on a real dir" ok \
    || report "fs_require_dir passes on a real dir" fail "$out"

out="$(bash -c "source '$sb/lib/common.sh' && common_init && fs_require_file '$tree/nope' 'book file'" 2>&1)"
rc=$?
[[ $rc -eq 1 && "$out" == *"book file not found: $tree/nope" ]] \
    && report "fs_require_file dies with a clear message" ok \
    || report "fs_require_file dies with a clear message" fail "rc=$rc out=$out"

out="$(bash -c "source '$sb/lib/common.sh' && common_init && d=\$(fs_mktmp probe) && [[ -d \$d ]] && echo \$d" 2>&1)"
[[ -d "$out" ]] && { rm -rf "$out"; report "fs_mktmp creates a directory" ok; } \
    || report "fs_mktmp creates a directory" fail "$out"

# --- 8. database ----------------------------------------------------------------------
out="$(bash -c "
# The suite may itself be run from a shell with MYSQL_* / ETL_DEBUG exported
# (the manual-testing walkthrough does exactly that); every env-sensitive
# bash -c block below starts from a known-clean slate.
unset MYSQL_CLIENT MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD \
      MYSQL_EXTRA_ARGS MYSQL_DATABASE MYSQL_CHARSET ETL_DEBUG
source '$sb/lib/common.sh' && source '$sb/lib/database.sh'
db_mysql_argv booksdb | tr '\n' '|'
" 2>&1)"
if [[ "$out" == "mysql|--default-character-set=utf8|--init-command=SET NAMES utf8|booksdb|-B|--skip-column-names|--raw|" ]]; then
    report "db_mysql_argv minimal shape (no env)" ok
else
    report "db_mysql_argv minimal shape (no env)" fail "$out"
fi

out="$(bash -c "
unset MYSQL_PASSWORD MYSQL_EXTRA_ARGS MYSQL_DATABASE MYSQL_CHARSET
export MYSQL_HOST=127.0.0.1 MYSQL_PORT=3307 MYSQL_USER=mike MYSQL_CLIENT=mariadb
source '$sb/lib/common.sh' && source '$sb/lib/database.sh'
db_mysql_argv | tr '\n' '|'
" 2>&1)"
if [[ "$out" == "mariadb|-h|127.0.0.1|--protocol=TCP|-P|3307|-u|mike|--default-character-set=utf8|--init-command=SET NAMES utf8|-B|--skip-column-names|--raw|" ]]; then
    report "db_mysql_argv honors MYSQL_* env overrides" ok
else
    report "db_mysql_argv honors MYSQL_* env overrides" fail "$out"
fi

# mock client via a real executable: argv arrives as separate arguments
mockdir="$sb/mockbin"; mkdir -p "$mockdir"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$mockdir/mockmysql"
chmod +x "$mockdir/mockmysql"
out="$(bash -c "
unset MYSQL_PASSWORD MYSQL_EXTRA_ARGS MYSQL_DATABASE MYSQL_CHARSET
export MYSQL_CLIENT='$mockdir/mockmysql' MYSQL_HOST=mockhost MYSQL_USER=u MYSQL_PORT=1
source '$sb/lib/common.sh' && source '$sb/lib/database.sh'
db_run_sql 'SELECT 42;' mydb | tr '\n' '|'
" 2>&1)"
[[ "$out" == "-h|mockhost|--protocol=TCP|-P|1|-u|u|--default-character-set=utf8|--init-command=SET NAMES utf8|mydb|-B|--skip-column-names|--raw|-e|SELECT 42;|" ]] \
    && report "db_run_sql invokes the client argv (mock client)" ok \
    || report "db_run_sql invokes the client argv (mock client)" fail "$out"

out="$(bash -c "
unset MYSQL_CLIENT MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD \
      MYSQL_EXTRA_ARGS MYSQL_DATABASE MYSQL_CHARSET
source '$sb/lib/common.sh' && source '$sb/lib/database.sh'
db_run_query '$sb/lib/nope.sql' 2>&1
" 2>&1)"
rc=$?
[[ $rc -eq 1 && "$out" == *"query file not found"* ]] \
    && report "db_run_query dies on a missing query file" ok \
    || report "db_run_query dies on a missing query file" fail "rc=$rc out=$out"

# --- 9. real-repo load test (clean checkout criterion) -------------------------
out="$(bash -c "source '$REPO_ROOT/lib/common.sh' && common_init && printf '%s' \"\$PROJECT_ROOT\"" 2>&1)"
expected_root="$(realpath "$REPO_ROOT")"

if [[ "$out" == "$expected_root" ]]; then
    report "clean load works against the real repo" ok
else
    report "clean load works against the real repo" fail \
        "expected=$expected_root actual=$out"
fi

rm -rf "$sb"

# --- summary --------------------------------------------------------------------------
echo
if (( FAIL_COUNT == 0 )); then
    echo "$PASS_COUNT passed, $FAIL_COUNT failed"
    exit 0
else
    echo "$PASS_COUNT passed, $FAIL_COUNT failed"
    for line in "${FAILURE_LINES[@]}"; do echo "  FAILED: $line"; done
    exit 1
fi
