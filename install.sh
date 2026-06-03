#!/usr/bin/env bash
#
# install.sh — Symlink CLI tools into a PATH directory.
#
# Usage:
#   ./install.sh                    # default: links into ~/.local/bin
#   PREFIX=~/bin ./install.sh       # custom target
#
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Source filename → installed command name
SCRIPTS=(
  "pr-review.sh:pr-review"
  "worktree.sh:worktree"
)

_c() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
ok()   { _c "0;32"; printf '✓ %s\n' "$*"; _c 0; }
warn() { _c "1;33"; printf '! %s\n' "$*"; _c 0; }

mkdir -p "$PREFIX"

for entry in "${SCRIPTS[@]}"; do
  src="${entry%%:*}"
  dst="${entry##*:}"
  src_path="$SCRIPT_DIR/$src"
  dst_path="$PREFIX/$dst"

  if [[ ! -f "$src_path" ]]; then
    warn "skipping $src — not found in $SCRIPT_DIR"
    continue
  fi

  chmod +x "$src_path"

  if [[ -L "$dst_path" || -e "$dst_path" ]]; then
    rm -f "$dst_path"
  fi
  ln -s "$src_path" "$dst_path"
  ok "linked $dst → $src_path"
done

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) warn "$PREFIX is NOT on your \$PATH — add this to your shell rc:"
     printf '    export PATH="%s:$PATH"\n' "$PREFIX" ;;
esac
