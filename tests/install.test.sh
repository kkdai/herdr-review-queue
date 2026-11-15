#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALL_SH="$REPO_ROOT/install.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/herdr-install-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

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

pass() {
  pass_count=$((pass_count + 1))
  printf 'ok %d - %s\n' "$pass_count" "$1"
}

# 1. --dry-run does not create symlinks
APP_HOME="$TMP_ROOT/case1-app"
BIN_DIR="$TMP_ROOT/case1-bin"
out=$(HERDR_APP_HOME="$APP_HOME" HC_REVIEW_BIN_DIR="$BIN_DIR" "$INSTALL_SH" --dry-run)
assert_match "$out" '\[dry-run\] ln -s' "--dry-run prints ln -s"
[ ! -e "$APP_HOME/mods/review-queue" ] || fail "--dry-run should not create mod symlink"
[ ! -e "$BIN_DIR/hc-review" ] || fail "--dry-run should not create cli symlink"
pass "--dry-run prints actions without modifying filesystem"

# 2. Install creates symlinks, preserves other mods, and runs herdr-app check
APP_HOME="$TMP_ROOT/case2-app"
BIN_DIR="$TMP_ROOT/case2-bin"
mkdir -p "$APP_HOME/mods/other-mod"
printf 'keep\n' >"$APP_HOME/mods/other-mod/marker.txt"

HERDR_APP_HOME="$APP_HOME" HC_REVIEW_BIN_DIR="$BIN_DIR" "$INSTALL_SH" >/dev/null
[ -L "$APP_HOME/mods/review-queue" ] || fail "mod symlink not created"
[ -L "$BIN_DIR/hc-review" ] || fail "cli symlink not created"
assert_eq "$(readlink "$APP_HOME/mods/review-queue")" "$REPO_ROOT/mods/review-queue" "mod symlink target"
assert_eq "$(readlink "$BIN_DIR/hc-review")" "$REPO_ROOT/bin/hc-review" "cli symlink target"
[ -f "$APP_HOME/mods/other-mod/marker.txt" ] || fail "other mod was touched"
pass "install symlinks mod and CLI and preserves other mods"

# 3. Re-running install is idempotent
HERDR_APP_HOME="$APP_HOME" HC_REVIEW_BIN_DIR="$BIN_DIR" "$INSTALL_SH" >/dev/null
assert_eq "$(readlink "$APP_HOME/mods/review-queue")" "$REPO_ROOT/mods/review-queue" "mod symlink still intact"
assert_eq "$(readlink "$BIN_DIR/hc-review")" "$REPO_ROOT/bin/hc-review" "cli symlink still intact"
pass "re-running install is idempotent"

# 4. --uninstall --dry-run keeps symlinks; --uninstall removes only repo symlinks
HERDR_APP_HOME="$APP_HOME" HC_REVIEW_BIN_DIR="$BIN_DIR" "$INSTALL_SH" --uninstall --dry-run >/dev/null
[ -L "$APP_HOME/mods/review-queue" ] || fail "--uninstall --dry-run removed mod symlink"
[ -L "$BIN_DIR/hc-review" ] || fail "--uninstall --dry-run removed cli symlink"

HERDR_APP_HOME="$APP_HOME" HC_REVIEW_BIN_DIR="$BIN_DIR" "$INSTALL_SH" --uninstall >/dev/null
[ ! -e "$APP_HOME/mods/review-queue" ] && [ ! -L "$APP_HOME/mods/review-queue" ] || fail "mod symlink not removed"
[ ! -e "$BIN_DIR/hc-review" ] && [ ! -L "$BIN_DIR/hc-review" ] || fail "cli symlink not removed"
[ -f "$APP_HOME/mods/other-mod/marker.txt" ] || fail "other mod was removed during uninstall"
pass "--uninstall removes repo symlinks and leaves other mods untouched"

# 5. Conflict: existing non-repo target refuses to overwrite and exits non-zero
APP_HOME="$TMP_ROOT/case5-app"
BIN_DIR="$TMP_ROOT/case5-bin"
mkdir -p "$APP_HOME/mods/review-queue"
printf 'custom\n' >"$APP_HOME/mods/review-queue/custom.txt"

set +e
HERDR_APP_HOME="$APP_HOME" HC_REVIEW_BIN_DIR="$BIN_DIR" "$INSTALL_SH" 2>"$TMP_ROOT/err5"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "install should fail when mod target already exists"
[ -f "$APP_HOME/mods/review-queue/custom.txt" ] || fail "existing mod dir was overwritten"
[ ! -e "$BIN_DIR/hc-review" ] || fail "cli symlink should not be created when mod target conflicts"

# --uninstall must also refuse to delete non-repo directory/symlink
HERDR_APP_HOME="$APP_HOME" HC_REVIEW_BIN_DIR="$BIN_DIR" "$INSTALL_SH" --uninstall 2>/dev/null
[ -f "$APP_HOME/mods/review-queue/custom.txt" ] || fail "--uninstall deleted non-repo mod dir"

# Foreign symlink conflict on CLI
APP_HOME2="$TMP_ROOT/case5b-app"
BIN_DIR2="$TMP_ROOT/case5b-bin"
mkdir -p "$BIN_DIR2"
ln -s "/bin/sh" "$BIN_DIR2/hc-review"
set +e
HERDR_APP_HOME="$APP_HOME2" HC_REVIEW_BIN_DIR="$BIN_DIR2" "$INSTALL_SH" 2>"$TMP_ROOT/err5b"
rc2=$?
set -e
[ "$rc2" -ne 0 ] || fail "install should fail when cli target is foreign symlink"
assert_eq "$(readlink "$BIN_DIR2/hc-review")" "/bin/sh" "foreign cli symlink not overwritten"
HERDR_APP_HOME="$APP_HOME2" HC_REVIEW_BIN_DIR="$BIN_DIR2" "$INSTALL_SH" --uninstall 2>/dev/null
assert_eq "$(readlink "$BIN_DIR2/hc-review")" "/bin/sh" "--uninstall did not remove foreign cli symlink"
pass "install and --uninstall refuse to overwrite or remove non-repo targets"

# 6. Missing herdr-app in PATH prints warning and still succeeds
APP_HOME="$TMP_ROOT/case6-app"
BIN_DIR="$TMP_ROOT/case6-bin"
MIN_BIN="$TMP_ROOT/min-bin"
mkdir -p "$MIN_BIN"
for tool in ln mkdir readlink dirname basename rm printf; do
  if tool_path=$(command -v "$tool" 2>/dev/null); then
    case "$tool_path" in
      /*) ln -s "$tool_path" "$MIN_BIN/$tool" 2>/dev/null || true ;;
    esac
  fi
done
PATH="$MIN_BIN" HERDR_APP_HOME="$APP_HOME" HC_REVIEW_BIN_DIR="$BIN_DIR" \
  /bin/sh "$INSTALL_SH" >/dev/null 2>"$TMP_ROOT/warn6"
assert_match "$(cat "$TMP_ROOT/warn6")" 'warning:.*herdr-app' "warns when herdr-app is not in PATH"
[ -L "$APP_HOME/mods/review-queue" ] || fail "mod symlink not created without herdr-app"
[ -L "$BIN_DIR/hc-review" ] || fail "cli symlink not created without herdr-app"
pass "missing herdr-app in PATH logs warning and completes install"

printf 'All %d install tests passed.\n' "$pass_count"
