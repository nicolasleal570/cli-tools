#!/usr/bin/env bash
#
# install.sh — Symlink cli-tools scripts (and their zsh completions) into
# directories on your PATH / fpath.
#
# Usage:
#   ./install.sh                                       # default targets
#   PREFIX=~/bin ./install.sh                          # custom binary target
#   COMP_DIR=~/.config/zsh/completions ./install.sh    # custom completions target
#
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
COMP_DIR="${COMP_DIR:-$HOME/.zsh/completions}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Source filename → installed command name
SCRIPTS=(
  "pr-review.sh:pr-review"
  "worktree.sh:worktree"
)

_c() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
ok()   { _c "0;32"; printf '✓ %s\n' "$*"; _c 0; }
warn() { _c "1;33"; printf '! %s\n' "$*"; _c 0; }

# ---------------------------------------------------------------------------
# 1. Binaries
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 2. zsh completions
# ---------------------------------------------------------------------------
COMPLETIONS_SRC="$SCRIPT_DIR/completions"

if [[ -d "$COMPLETIONS_SRC" ]]; then
  mkdir -p "$COMP_DIR"
  installed_any=0
  for src in "$COMPLETIONS_SRC"/_*; do
    [[ -f "$src" ]] || continue
    name="$(basename "$src")"
    dst="$COMP_DIR/$name"
    if [[ -L "$dst" || -e "$dst" ]]; then
      rm -f "$dst"
    fi
    ln -s "$src" "$dst"
    ok "linked completion $name → $src"
    installed_any=1
  done

  ZSHRC="$HOME/.zshrc"
  if [[ "$installed_any" -eq 1 ]]; then
    if [[ -f "$ZSHRC" ]] && grep -qF "$COMP_DIR" "$ZSHRC"; then
      :  # already referenced — assume the user has it wired up
    else
      warn "$COMP_DIR is NOT referenced in your ~/.zshrc — completions won't load yet."
      if [[ -f "$ZSHRC" ]] && grep -q "compinit" "$ZSHRC"; then
        printf '    Add this line BEFORE your existing compinit call:\n'
        printf '      fpath=(%s $fpath)\n' "$COMP_DIR"
      else
        printf '    Add these lines to ~/.zshrc:\n'
        printf '      fpath=(%s $fpath)\n' "$COMP_DIR"
        printf '      autoload -Uz compinit && compinit\n'
      fi
      printf '    Then reload with: source ~/.zshrc\n'
    fi
  fi
fi
