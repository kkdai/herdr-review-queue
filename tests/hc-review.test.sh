#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CLI="$REPO_ROOT/bin/hc-review"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hc-review-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

HC_LOG="$TMP_DIR/hc.log"
HC_GET_JSON="$TMP_DIR/get.json"
HC_GET_MAP_JSON="$TMP_DIR/get_map.json"
HC_LS_JSON="$TMP_DIR/ls.json"
export HC_LOG HC_GET_JSON HC_GET_MAP_JSON HC_LS_JSON

cat >"$FAKE_BIN/hc" <<'EOF'
#!/bin/sh
set -eu

# Log call as JSON array of argv so tests can assert exact arguments
jq -nc '$ARGS.positional' --args -- "$@" >>"$HC_LOG"

cmd="${1:-}"
case "$cmd" in
  get)
    addr="${2:-}"
    if [ "${HC_GET_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    if [ -n "${HC_GET_FAIL_ADDR:-}" ] && [ "$addr" = "$HC_GET_FAIL_ADDR" ]; then
      exit 1
    fi
    if [ -f "$HC_GET_MAP_JSON" ] && jq -e --arg a "$addr" 'has($a)' "$HC_GET_MAP_JSON" >/dev/null 2>&1; then
      jq -c --arg a "$addr" '.[$a]' "$HC_GET_MAP_JSON"
    else
      cat "$HC_GET_JSON"
    fi
    ;;
  ls)
    cat "$HC_LS_JSON"
    ;;
  label)
    addr="${2:-}"
    printf '{"address":"%s","state":"live","labels":{"raw":"noisy_stdout_json"}}\n' "$addr"
    ;;
  send)
    printf 'sent at turn 1 (no status)\n'
    ;;
  *)
    printf 'fake hc: unexpected command: %s\n' "$cmd" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$FAKE_BIN/hc"

# Put fake hc first on PATH; unset HC_BIN by default so PATH resolution is tested
PATH="$FAKE_BIN:$PATH"
export PATH
unset HC_BIN || true

pass_count=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  actual="$1"
  expected="$2"
  msg="${3:-values differ}"
  if [ "$actual" != "$expected" ]; then
    fail "$msg: expected [$expected], got [$actual]"
  fi
}

assert_match() {
  val="$1"
  pat="$2"
  msg="${3:-value did not match pattern}"
  if ! printf '%s\n' "$val" | grep -Eq -- "$pat"; then
    fail "$msg: [$val] !~ /$pat/"
  fi
}

assert_not_match() {
  val="$1"
  pat="$2"
  msg="${3:-value unexpectedly matched pattern}"
  if printf '%s\n' "$val" | grep -Eq -- "$pat"; then
    fail "$msg: [$val] matched /$pat/"
  fi
}

reset_state() {
  : >"$HC_LOG"
  printf '{"address":"t7","parent":"t15"}\n' >"$HC_GET_JSON"
  rm -f "$HC_GET_MAP_JSON"
  printf '{"hidden_finished":0,"terminals":[]}\n' >"$HC_LS_JSON"
  unset HC_GET_FAIL || true
  unset HC_GET_FAIL_ADDR || true
  unset HC_REVIEW_NOW_MS || true
}

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$1"
}

# 1. --help
reset_state
help_out=$("$CLI" --help)
assert_match "$help_out" 'hc-review ready' "--help mentions ready"
assert_match "$help_out" 'hc-review seen' "--help mentions seen"
assert_match "$help_out" 'hc-review clear' "--help mentions clear"
assert_match "$help_out" 'hc-review ls' "--help mentions ls"
assert_eq "$(wc -l <"$HC_LOG" | tr -d ' ')" "0" "--help should not call hc"
pass "--help prints usage without calling hc"

# 2. ready (default reviewer from parent, sends notification, clears seen_at, clean stdout)
reset_state
ready_out=$(HC_TERMINAL_ID="t7" "$CLI" ready "Fixed issue #1")
assert_eq "$ready_out" "ready: t7 → t15" "ready prints clean confirmation line without hc JSON"
assert_not_match "$ready_out" '\{' "ready stdout contains no JSON"
assert_eq "$(wc -l <"$HC_LOG" | tr -d ' ')" "3" "ready should make 3 hc calls (get, label, send)"

call1=$(sed -n '1p' "$HC_LOG")
call2=$(sed -n '2p' "$HC_LOG")
call3=$(sed -n '3p' "$HC_LOG")

assert_eq "$call1" '["get","t7","--json"]' "first call is hc get t7 --json"
assert_eq "$(printf '%s\n' "$call2" | jq -c 'del(.[4])')" '["label","t7","review=ready","review.summary=Fixed issue #1","review.to=t15","review.seen_at="]' "second call sets review labels and removes review.seen_at"
at_arg=$(printf '%s\n' "$call2" | jq -r '.[4]')
assert_match "$at_arg" '^review\.at=[0-9]{13,}$' "review.at is ms since epoch digits"
assert_eq "$call3" '["send","t15","[review-ready] Fixed issue #1"]' "third call sends [review-ready] message to parent"
pass "ready labels terminal, sends to parent reviewer, and suppresses hc stdout"

# 3. ready with --to (remote address) and --no-send
reset_state
ready_out=$(HC_TERMINAL_ID="remote/t7" HC_REVIEW_NOW_MS="1700000000123" \
  "$CLI" ready "Ready for remote review" --to "remote/t15" --no-send)
assert_eq "$ready_out" "ready: remote/t7 → remote/t15" "ready --to --no-send prints clean line"
assert_eq "$(wc -l <"$HC_LOG" | tr -d ' ')" "1" "ready --to --no-send should only call hc label"
call1=$(sed -n '1p' "$HC_LOG")
assert_eq "$call1" '["label","remote/t7","review=ready","review.summary=Ready for remote review","review.at=1700000000123","review.to=remote/t15","review.seen_at="]' "ready --to --no-send exact hc label argv"
pass "ready supports --to, remote addresses, and --no-send"

# 4. ready summary sanitization (newlines/tabs -> spaces) and >200 char truncation with …
reset_state
long_prefix=$(awk 'BEGIN { for (i = 0; i < 195; i++) printf "a" }')
raw_summary=$(printf '%s\nnext\tline_extra_chars' "$long_prefix")
ready_out=$(HC_TERMINAL_ID="t7" HC_REVIEW_NOW_MS="1700000000999" "$CLI" ready "$raw_summary" --to "t15")
assert_eq "$ready_out" "ready: t7 → t15" "ready outputs clean line on truncated summary"
call1=$(sed -n '1p' "$HC_LOG")
call2=$(sed -n '2p' "$HC_LOG")

expected_summary="${long_prefix} nex…"
label_summary=$(printf '%s\n' "$call1" | jq -r '.[3]' | sed 's/^review\.summary=//')
send_msg=$(printf '%s\n' "$call2" | jq -r '.[2]')
summary_char_len=$(printf '%s\n' "$call1" | jq -r '.[3] | sub("^review\\.summary="; "") | length')

assert_eq "$label_summary" "$expected_summary" "summary replaces newline/tab with space and truncates with …"
assert_eq "$summary_char_len" "200" "truncated summary is 200 chars"
assert_eq "$send_msg" "[review-ready] $expected_summary" "hc send uses sanitized/truncated summary"
pass "ready normalizes newlines/tabs and truncates summary > 200 chars with …"

# 5. ready error: missing HC_TERMINAL_ID -> exit 2
reset_state
set +e
(unset HC_TERMINAL_ID; "$CLI" ready "some summary" 2>"$TMP_DIR/err")
rc=$?
set -e
assert_eq "$rc" "2" "ready without HC_TERMINAL_ID exits 2"
assert_eq "$(wc -l <"$HC_LOG" | tr -d ' ')" "0" "no hc calls when HC_TERMINAL_ID is unset"
pass "ready exits 2 when HC_TERMINAL_ID is unset"

# 6. ready error: no reviewer found (parent is null and --to omitted) -> exit 2
reset_state
printf '{"address":"t7","parent":null}\n' >"$HC_GET_JSON"
set +e
HC_TERMINAL_ID="t7" "$CLI" ready "some summary" 2>"$TMP_DIR/err"
rc=$?
set -e
assert_eq "$rc" "2" "ready without parent or --to exits 2"
assert_eq "$(wc -l <"$HC_LOG" | tr -d ' ')" "1" "only hc get called before failing"
pass "ready exits 2 when no reviewer can be found"

# 7. ready error: hc get fails and --to omitted -> exit 2
reset_state
HC_GET_FAIL=1
export HC_GET_FAIL
set +e
HC_TERMINAL_ID="t7" "$CLI" ready "some summary" 2>"$TMP_DIR/err"
rc=$?
set -e
assert_eq "$rc" "2" "ready exits 2 when hc get fails"
pass "ready exits 2 when hc get fails"

# 8. seen <t> (suppresses hc label JSON stdout and prints seen: <addr>)
reset_state
seen_out=$("$CLI" seen "machine/t7")
assert_eq "$seen_out" "seen: machine/t7" "seen prints seen: <addr> without JSON"
assert_not_match "$seen_out" '\{' "seen stdout contains no JSON"
assert_eq "$(wc -l <"$HC_LOG" | tr -d ' ')" "1" "seen calls hc once"
call1=$(sed -n '1p' "$HC_LOG")
assert_eq "$(printf '%s\n' "$call1" | jq -c '.[0:3]')" '["label","machine/t7","review=seen"]' "seen sets review=seen on target"
seen_at_arg=$(printf '%s\n' "$call1" | jq -r '.[3]')
assert_match "$seen_at_arg" '^review\.seen_at=[0-9]{13,}$' "review.seen_at is ms since epoch digits"
pass "seen sets review=seen and review.seen_at=<now ms> with clean stdout"

# 9. clear <t> (suppresses hc label JSON stdout and prints cleared: <addr>)
reset_state
clear_out=$("$CLI" clear "machine/t7")
assert_eq "$clear_out" "cleared: machine/t7" "clear prints cleared: <addr> without JSON"
assert_not_match "$clear_out" '\{' "clear stdout contains no JSON"
assert_eq "$(wc -l <"$HC_LOG" | tr -d ' ')" "1" "clear calls hc once"
call1=$(sed -n '1p' "$HC_LOG")
assert_eq "$call1" '["label","machine/t7","review=","review.summary=","review.at=","review.to=","review.seen_at="]' "clear removes all five review labels"
pass "clear removes all five review labels with clean stdout"

# 10. seen / clear missing target error -> exit 2
reset_state
set +e
"$CLI" seen 2>"$TMP_DIR/err"
rc_seen=$?
"$CLI" clear 2>"$TMP_DIR/err"
rc_clear=$?
set -e
assert_eq "$rc_seen" "2" "seen without <t> exits 2"
assert_eq "$rc_clear" "2" "clear without <t> exits 2"
assert_eq "$(wc -l <"$HC_LOG" | tr -d ' ')" "0" "invalid seen/clear makes no hc calls"
pass "seen and clear exit 2 on missing argument"

# 11. ls: fake hc ls --json returns summary WITHOUT labels/name; ls calls hc get <addr> --json for each and skips failed get
reset_state
cat >"$HC_LS_JSON" <<'EOF'
{
  "hidden_finished": 2,
  "terminals": [
    {"address": "t1", "agent": "zsh", "cwd": "/tmp", "state": "live", "turn": 1, "where": "w / 1"},
    {"address": "t9", "agent": "claude-code", "cwd": "/tmp", "state": "live", "status": "done", "turn": 2, "where": "w / 1"},
    {"address": "t_dead", "agent": "zsh", "cwd": "/tmp", "state": "live", "turn": 0, "where": "w / 1"},
    {"address": "t8", "agent": "antigravity", "cwd": "/tmp", "state": "live", "status": "working", "turn": 3, "where": "w / 1"},
    {"address": "box/t4", "agent": "claude-code", "cwd": "/tmp", "state": "live", "status": "idle", "turn": 4, "where": "w / 2"}
  ]
}
EOF

cat >"$HC_GET_MAP_JSON" <<'EOF'
{
  "t1": {
    "address": "t1",
    "name": "shell",
    "state": "live",
    "labels": {"where": "w / 1"}
  },
  "t9": {
    "address": "t9",
    "name": "coder-b",
    "state": "live",
    "labels": {
      "review": "ready",
      "review.summary": "Newer report",
      "review.at": "1700000120000",
      "review.to": "t15"
    }
  },
  "t8": {
    "address": "t8",
    "name": "coder-a",
    "state": "live",
    "labels": {
      "review": "ready",
      "review.summary": "Older report",
      "review.at": "1700000000000",
      "review.to": "t15"
    }
  },
  "box/t4": {
    "address": "box/t4",
    "name": null,
    "state": "live",
    "labels": {
      "review": "seen",
      "review.summary": "Already reviewed",
      "review.at": "1699999900000",
      "review.to": "t15",
      "review.seen_at": "1700000150000"
    }
  }
}
EOF

HC_GET_FAIL_ADDR="t_dead"
export HC_GET_FAIL_ADDR

ls_text=$(HC_REVIEW_NOW_MS="1700000180000" "$CLI" ls)
assert_eq "$(wc -l <"$HC_LOG" | tr -d ' ')" "6" "ls calls hc ls --json plus hc get for each of the 5 addresses"
assert_eq "$(sed -n '1p' "$HC_LOG")" '["ls","--json"]' "first call is hc ls --json"
assert_eq "$(sed -n '2p' "$HC_LOG")" '["get","t1","--json"]' "get called for t1"
assert_eq "$(sed -n '3p' "$HC_LOG")" '["get","t9","--json"]' "get called for t9"
assert_eq "$(sed -n '4p' "$HC_LOG")" '["get","t_dead","--json"]' "get called for t_dead (which fails and is skipped)"
assert_eq "$(sed -n '5p' "$HC_LOG")" '["get","t8","--json"]' "get called for t8"
assert_eq "$(sed -n '6p' "$HC_LOG")" '["get","box/t4","--json"]' "get called for box/t4"

header_line=$(printf '%s\n' "$ls_text" | sed -n '1p')
row1_line=$(printf '%s\n' "$ls_text" | sed -n '2p')
row2_line=$(printf '%s\n' "$ls_text" | sed -n '3p')
line_count=$(printf '%s\n' "$ls_text" | wc -l | tr -d ' ')

assert_eq "$line_count" "3" "ls text has header + 2 ready rows"
assert_match "$header_line" '^ADDRESS[[:space:]]+NAME[[:space:]]+AGE[[:space:]]+SUMMARY$' "ls header columns"
assert_match "$row1_line" '^t8[[:space:]]+coder-a[[:space:]]+3m[[:space:]]+Older report$' "oldest ready row first (3m)"
assert_match "$row2_line" '^t9[[:space:]]+coder-b[[:space:]]+1m[[:space:]]+Newer report$' "newer ready row second (1m)"
pass "ls fetches each terminal via hc get, skips failed get, and outputs ready terminals oldest first"

# 12. ls --all and ls --json
ls_json=$("$CLI" ls --json)
assert_eq "$(printf '%s\n' "$ls_json" | jq -r 'map(.address) | join(",")')" "t8,t9" "ls --json returns ready terminals oldest first"

ls_all_json=$("$CLI" ls --all --json)
assert_eq "$(printf '%s\n' "$ls_all_json" | jq -r 'map(.address) | join(",")')" "box/t4,t8,t9" "ls --all --json includes seen terminals oldest first"

ls_all_text=$(HC_REVIEW_NOW_MS="1700000180000" "$CLI" ls --all)
assert_eq "$(printf '%s\n' "$ls_all_text" | wc -l | tr -d ' ')" "4" "ls --all text has header + 3 rows"
assert_match "$(printf '%s\n' "$ls_all_text" | sed -n '2p')" '^box/t4[[:space:]]+-[[:space:]]+4m[[:space:]]+Already reviewed$' "ls --all includes seen row with - for null name"
pass "ls supports --all and --json"

# 13. HC_BIN override
reset_state
cp "$FAKE_BIN/hc" "$TMP_DIR/custom-hc"
clear_out=$(HC_BIN="$TMP_DIR/custom-hc" "$CLI" clear "t7")
assert_eq "$clear_out" "cleared: t7" "HC_BIN override prints cleared: t7"
assert_eq "$(wc -l <"$HC_LOG" | tr -d ' ')" "1" "HC_BIN override is invoked"
pass "HC_BIN overrides hc executable"

printf 'All %d tests passed.\n' "$pass_count"
