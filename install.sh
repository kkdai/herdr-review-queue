#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOD_SRC="$REPO_ROOT/mods/review-queue"
CLI_SRC="$REPO_ROOT/bin/hc-review"

APP_HOME="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
MOD_DST_DIR="$APP_HOME/mods"
MOD_DST="$MOD_DST_DIR/review-queue"

BIN_DIR="${HC_REVIEW_BIN_DIR:-$HOME/.local/bin}"
CLI_DST="$BIN_DIR/hc-review"

dry_run=0
uninstall=0

usage() {
  cat <<'EOF'
Usage:
  ./install.sh [--dry-run] [--uninstall]
EOF
}

die() {
  printf 'install.sh: error: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --uninstall)
      uninstall=1
      shift
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

is_our_symlink() {
  dst="$1"
  src="$2"
  [ -L "$dst" ] || return 1
  target=$(readlink "$dst" 2>/dev/null || true)
  if [ "$target" = "$src" ]; then
    return 0
  fi
  if [ -d "$dst" ] && [ -d "$src" ]; then
    dst_real=$(CDPATH= cd -- "$dst" 2>/dev/null && pwd -P || true)
    src_real=$(CDPATH= cd -- "$src" 2>/dev/null && pwd -P || true)
    if [ -n "$dst_real" ] && [ "$dst_real" = "$src_real" ]; then
      return 0
    fi
  fi
  return 1
}

if [ "$uninstall" -eq 1 ]; then
  for pair in "$MOD_DST|$MOD_SRC" "$CLI_DST|$CLI_SRC"; do
    dst="${pair%%|*}"
    src="${pair#*|}"
    if is_our_symlink "$dst" "$src"; then
      if [ "$dry_run" -eq 1 ]; then
        printf '[dry-run] rm %s\n' "$dst"
      else
        rm "$dst"
        printf 'removed: %s\n' "$dst"
      fi
    elif [ -e "$dst" ] || [ -L "$dst" ]; then
      printf 'install.sh: skipping %s (not a symlink to this repo)\n' "$dst" >&2
    fi
  done
  exit 0
fi

# Verify neither target exists as a non-repo file/dir/symlink before touching anything
for pair in "$MOD_DST|$MOD_SRC" "$CLI_DST|$CLI_SRC"; do
  dst="${pair%%|*}"
  src="${pair#*|}"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    if ! is_our_symlink "$dst" "$src"; then
      die "$dst already exists and is not a symlink to $src (refusing to overwrite)"
    fi
  fi
done

if [ "$dry_run" -eq 1 ]; then
  printf '[dry-run] mkdir -p %s\n' "$MOD_DST_DIR"
  printf '[dry-run] ln -s %s %s\n' "$MOD_SRC" "$MOD_DST"
  printf '[dry-run] mkdir -p %s\n' "$BIN_DIR"
  printf '[dry-run] ln -s %s %s\n' "$CLI_SRC" "$CLI_DST"
  printf '[dry-run] herdr-app check %s\n' "$MOD_DST"
  exit 0
fi

mkdir -p "$MOD_DST_DIR"
if ! is_our_symlink "$MOD_DST" "$MOD_SRC"; then
  ln -s "$MOD_SRC" "$MOD_DST"
fi
printf 'linked: %s -> %s\n' "$MOD_DST" "$MOD_SRC"

mkdir -p "$BIN_DIR"
if ! is_our_symlink "$CLI_DST" "$CLI_SRC"; then
  ln -s "$CLI_SRC" "$CLI_DST"
fi
printf 'linked: %s -> %s\n' "$CLI_DST" "$CLI_SRC"

if command -v herdr-app >/dev/null 2>&1; then
  herdr-app check "$MOD_DST"
else
  printf 'install.sh: warning: herdr-app not found in PATH; skipping check\n' >&2
fi
