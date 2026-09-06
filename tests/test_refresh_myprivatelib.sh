#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# tests/test_refresh_myprivatelib.sh
#
# Regression suite for bin/refresh_myprivatelib.sh v1.0.0 (the freshness
# orchestrator: tree-fingerprint checkpoint -> backup -> populate ->
# checkpoint).  No real MariaDB and no real Books tree are needed: the
# suite builds a fixture library, and the two child tools are mock scripts
# that record their invocation.
#
# Asserts:
#   - version / usage / unknown-option contracts
#   - status: no-checkpoint -> after a run -> up-to-date
#   - first run (no checkpoint): refresh runs (backup + populate), writes
#     the checkpoint; a second run with an unchanged tree is a no-op
#     (children NOT invoked again, exit 0)
#   - changing a file (touch), adding a file, removing a file, and
#     resizing a file each flip the decision to "changed" -> children run
#   - --force refreshes even when up to date
#   - --dry-run reports the plan, invokes NO child tool, writes NO
#     checkpoint
#   - a failing populate aborts the run (checkpoint NOT written, rc 1)
#   - a failing backup aborts the run BEFORE populate is invoked
#   - the checkpoint is byte-stable: two fingerprints of an unchanged
#     tree compare equal (cmp)
#
# Usage:  bash tests/test_refresh_myprivatelib.sh
# Runs anywhere (pure text processing; no DB, no WSL needed).
# -----------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$REPO_ROOT/bin/refresh_myprivatelib.sh"

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/refresh_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- fixture library -------------------------------------------------------------
LIB="$TMP/Books"
mkdir -p "$LIB/A/Author One" "$LIB/Б/Автор Два"
printf 'content one' > "$LIB/A/Author One/01-One.zip"
printf 'содержимое два' > "$LIB/Б/Автор Два/02-Два.fb2"

REPORT_DIR="$TMP/reports"
CHECKPOINT="$REPORT_DIR/refresh_checkpoint.tsv"

# --- mock child tools ---------------------------------------------------------------
MOCK_BIN="$TMP/mockbin"
mkdir -p "$MOCK_BIN"
CALL_LOG="$TMP/calls.log"

# A real tool stand-in: records "backup <args>" / "populate <args>" and can
# be told to fail via MOCK_FAIL=backup|populate.
cat > "$MOCK_BIN/backup_myprivatelib.sh" <<'EOF'
#!/usr/bin/env bash
printf 'backup %s\n' "$*" >> "${CALL_LOG:?}"
[[ "${MOCK_FAIL:-}" == "backup" ]] && exit 1
exit 0
EOF
cat > "$MOCK_BIN/populate_myprivatelib.sh" <<'EOF'
#!/usr/bin/env bash
printf 'populate %s\n' "$*" >> "${CALL_LOG:?}"
[[ "${MOCK_FAIL:-}" == "populate" ]] && exit 1
exit 0
EOF
chmod +x "$MOCK_BIN"/*.sh

# The orchestrator resolves child tools relative to ITS project root
# (PROJECT_ROOT/bin/<tool>), so the mock project must carry the children
# in its own bin/ alongside the tool under test.
MOCK_ROOT="$TMP/mockproj"
mkdir -p "$MOCK_ROOT/bin"
cp "$TOOL" "$MOCK_ROOT/bin/"
cp "$MOCK_BIN/backup_myprivatelib.sh" "$MOCK_BIN/populate_myprivatelib.sh" "$MOCK_ROOT/bin/"
MOCKTOOL="$MOCK_ROOT/bin/refresh_myprivatelib.sh"

run_tool() { # [args...]
    OUT="$TMP/stdout.txt" ERR="$TMP/stderr.txt"
    : > "$CALL_LOG"
    env CALL_LOG="$CALL_LOG" \
        CONF_FILE="$TMP/no-such.conf" \
        REFRESH_LIBRARY_ROOT="$LIB" \
        REFRESH_REPORT_DIR="$REPORT_DIR" \
        bash "$MOCKTOOL" "$@" >"$OUT" 2>"$ERR" < /dev/null
    RC=$?
}

calls() { grep -c "^$1" "$CALL_LOG" 2>/dev/null; }   # grep -c prints 0 on no match

echo "== refresh_myprivatelib (checkpoint orchestrator) =="

# --- version / usage -----------------------------------------------------------------
version="$(sed -n 's/^# Version:[[:space:]]*//p' "$TOOL" | head -n 1)"
case "$version" in
    1.0.*) report "version_header" ok "header $version" ;;
    *)     report "version_header" fail "got '$version', expected 1.0.x" ;;
esac

bash "$TOOL" --version >"$TMP/v.txt" 2>&1
if [[ "$(cat "$TMP/v.txt")" == "bin/refresh_myprivatelib.sh v$version" ]]; then
    report "version_flag" ok
else
    report "version_flag" fail "got '$(cat "$TMP/v.txt")'"
fi

bash "$TOOL" --help >"$TMP/h.txt" 2>&1
if (( $? == 0 )) && grep -q -- "--force" "$TMP/h.txt" && grep -q "checkpoint" "$TMP/h.txt"; then
    report "help_exit0" ok
else
    report "help_exit0" fail "help must exit 0 and describe the tool"
fi

bash "$TOOL" --bogus >"$TMP/u.txt" 2>&1
if (( $? == 2 )); then
    report "unknown_option_exit2" ok
else
    report "unknown_option_exit2" fail "expected exit 2"
fi

# --- status: no checkpoint yet ---------------------------------------------------------
rm -rf "$REPORT_DIR"
run_tool --status
if (( RC == 0 )) && grep -q "state:      no-checkpoint" "$OUT"; then
    report "status_no_checkpoint" ok
else
    report "status_no_checkpoint" fail "rc=$RC out=$(cat "$OUT" | tr '\n' '|')"
fi

# --- first run: refresh + checkpoint ----------------------------------------------------
run_tool
if (( RC == 0 )) \
   && [[ "$(calls backup)" == "1" ]] \
   && [[ "$(calls populate)" == "1" ]] \
   && [[ -s "$CHECKPOINT" ]] \
   && grep -q "step 1/3" "$ERR" && grep -q "checkpoint written" "$ERR"; then
    report "first_run_backup_populate_checkpoint" ok
else
    report "first_run_backup_populate_checkpoint" fail "rc=$RC calls=$(cat "$CALL_LOG" | tr '\n' '|') err=$(tail -3 "$ERR" | tr '\n' '|')"
fi

# checkpoint content shape: rel paths, tab-separated, includes the multibyte dir
if grep -q "^A/Author One/01-One\.zip" "$CHECKPOINT" \
   && grep -q "^Б/Автор Два/02-Два\.fb2" "$CHECKPOINT" \
   && [[ "$(awk -F'\t' '{print NF}' "$CHECKPOINT" | sort -u | tr '\n' ' ')" == "3 " ]]; then
    report "checkpoint_shape" ok
else
    report "checkpoint_shape" fail "file=$(head -3 "$CHECKPOINT" | tr '\n' '|')"
fi

# --- second run, unchanged tree: no-op ---------------------------------------------------
run_tool
if (( RC == 0 )) \
   && [[ "$(calls backup)" == "0" ]] \
   && [[ "$(calls populate)" == "0" ]] \
   && grep -q "nothing to do" "$ERR"; then
    report "unchanged_tree_noop" ok
else
    report "unchanged_tree_noop" fail "rc=$RC calls=$(cat "$CALL_LOG" | tr '\n' '|') err=$(tail -2 "$ERR" | tr '\n' '|')"
fi

# --- status: up-to-date -------------------------------------------------------------------
run_tool --status
if (( RC == 0 )) && grep -q "state:      up-to-date" "$OUT"; then
    report "status_up_to_date" ok
else
    report "status_up_to_date" fail "rc=$RC out=$(cat "$OUT" | tr '\n' '|')"
fi

# --- change detection: touch / add / remove / resize ----------------------------------------
for change in touch add remove resize; do
    case "$change" in
        touch)  touch "$LIB/A/Author One/01-One.zip" ;;
        add)    printf 'new book' > "$LIB/A/Author One/03-New.zip" ;;
        remove) rm -f "$LIB/A/Author One/03-New.zip" ;;
        resize) printf 'content one but bigger now' > "$LIB/A/Author One/01-One.zip" ;;
    esac
    run_tool
    if (( RC == 0 )) \
       && [[ "$(calls backup)" == "1" ]] \
       && [[ "$(calls populate)" == "1" ]] \
       && grep -q "refresh decision: changed" "$ERR"; then
        report "detect_$change" ok
    else
        report "detect_$change" fail "rc=$RC calls=$(cat "$CALL_LOG" | tr '\n' '|') err=$(head -2 "$ERR" | tr '\n' '|')"
    fi
    # restore the baseline for the next iteration (the file added by the
    # 'add' iteration STAYS - the 'remove' iteration deletes it)
    printf 'content one' > "$LIB/A/Author One/01-One.zip"
    run_tool   # re-sync the checkpoint with the restored baseline
done

# --- --force refreshes even when up to date ----------------------------------------------------
run_tool   # ensure up-to-date
: > "$CALL_LOG"
run_tool --force
if (( RC == 0 )) \
   && [[ "$(calls backup)" == "1" ]] \
   && [[ "$(calls populate)" == "1" ]] \
   && grep -q "(forced)" "$ERR"; then
    report "force_always_refreshes" ok
else
    report "force_always_refreshes" fail "rc=$RC calls=$(cat "$CALL_LOG" | tr '\n' '|') err=$(head -2 "$ERR" | tr '\n' '|')"
fi

# --- --dry-run: plan only, no children, no checkpoint --------------------------------------------
rm -rf "$REPORT_DIR"
run_tool --dry-run
if (( RC == 0 )) \
   && [[ "$(calls backup)" == "0" ]] \
   && [[ "$(calls populate)" == "0" ]] \
   && [[ ! -e "$CHECKPOINT" ]] \
   && grep -q "would back up" "$ERR" \
   && grep -q "would rebuild" "$ERR" \
   && grep -q "would write the checkpoint" "$ERR"; then
    report "dryrun_plan_only" ok
else
    report "dryrun_plan_only" fail "rc=$RC calls=$(cat "$CALL_LOG" | tr '\n' '|') err=$(tail -3 "$ERR" | tr '\n' '|')"
fi

# dry-run when up to date: reports nothing to do
run_tool >/dev/null 2>&1   # real run writes the checkpoint
run_tool --dry-run
if (( RC == 0 )) && grep -q "nothing to do" "$ERR"; then
    report "dryrun_up_to_date_noop" ok
else
    report "dryrun_up_to_date_noop" fail "rc=$RC err=$(tail -2 "$ERR" | tr '\n' '|')"
fi

# --- failure: populate fails -> checkpoint NOT written, rc 1 --------------------------------------
rm -rf "$REPORT_DIR"
MOCK_FAIL=populate run_tool
if (( RC == 1 )) \
   && [[ "$(calls populate)" == "1" ]] \
   && [[ ! -e "$CHECKPOINT" ]] \
   && grep -q "populate failed" "$ERR"; then
    report "populate_fail_aborts" ok
else
    report "populate_fail_aborts" fail "rc=$RC calls=$(cat "$CALL_LOG" | tr '\n' '|')"
fi

# --- failure: backup fails -> populate NOT invoked --------------------------------------------------
MOCK_FAIL=backup run_tool
if (( RC == 1 )) \
   && [[ "$(calls backup)" == "1" ]] \
   && [[ "$(calls populate)" == "0" ]] \
   && grep -q "backup failed" "$ERR"; then
    report "backup_fail_aborts_before_populate" ok
else
    report "backup_fail_aborts_before_populate" fail "rc=$RC calls=$(cat "$CALL_LOG" | tr '\n' '|')"
fi

# --- missing library root -> exit 1 -------------------------------------------------------------------
run_tool_with_root() {
    OUT="$TMP/stdout.txt" ERR="$TMP/stderr.txt"
    : > "$CALL_LOG"
    env CALL_LOG="$CALL_LOG" CONF_FILE="$TMP/no-such.conf" \
        REFRESH_LIBRARY_ROOT="$TMP/no-such-root" \
        REFRESH_REPORT_DIR="$REPORT_DIR" \
        bash "$MOCKTOOL" >"$OUT" 2>"$ERR" < /dev/null
    RC=$?
}
run_tool_with_root
if (( RC == 1 )) && grep -q "library root not found" "$ERR"; then
    report "missing_library_root" ok
else
    report "missing_library_root" fail "rc=$RC err=$(head -2 "$ERR" | tr '\n' '|')"
fi

# --- fingerprint determinism: unchanged tree -> byte-identical checkpoint -----------------------------
run_tool
cp "$CHECKPOINT" "$TMP/ckpt1"
sleep 1
touch "$LIB/Б/Автор Два"    # touch a DIRECTORY only - files unchanged
run_tool
if cmp -s "$TMP/ckpt1" "$CHECKPOINT"; then
    report "fingerprint_ignores_dir_mtime" ok
else
    report "fingerprint_ignores_dir_mtime" fail "dir mtime changed the fingerprint"
fi

echo ""
echo "=============================="
echo "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    printf '  - %s\n' "${FAILURE_LINES[@]}"
    exit 1
fi
echo "All tests passed."
exit 0
