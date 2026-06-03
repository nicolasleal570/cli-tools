#!/usr/bin/env bash
#
# worktree.sh — Unified git worktree manager for feature development.
#
# Subcommands:
#   worktree.sh create <repo> <branch> <base-branch>
#       Create a worktree for <branch> in <repo>, starting from <base-branch>.
#       Sets up a tmux session, copies env files, installs JS deps.
#
#   worktree.sh remove <worktree-dir> [--delete-branch] [--force]
#       Tear down a worktree. <worktree-dir> can be a folder name (resolved
#       under $WORKTREE_ROOT), a relative path, an absolute path, or "."
#       when standing inside the worktree. The branch, repo, and tmux
#       session are derived from git metadata in the worktree itself.
#       --delete-branch  also delete the local branch (default: keep)
#       --force          skip the uncommitted-changes safety check AND
#                        pass --force to git worktree remove
#
#   worktree.sh list [<repo>]
#       List active worktrees under $WORKTREE_ROOT. Optionally filter by repo.
#
# Usage:
#   ./worktree.sh create merchant-web feat/alds-1234-nuevo-modal feat/merchant-web
#   ./worktree.sh remove merchant-web-alds-1234
#   ./worktree.sh list
#
# Config (override by exporting before running):
#   REPOS_ROOT     where your clones live      (default: $HOME/Documents/projects)
#   WORKTREE_ROOT  where worktrees are created (default: $REPOS_ROOT/.worktrees)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REPOS_ROOT="${REPOS_ROOT:-$HOME/Documents/projects}"
WORKTREE_ROOT="${WORKTREE_ROOT:-$REPOS_ROOT/.worktrees}"

# ---------------------------------------------------------------------------
# Logging (stderr so it never pollutes piped output)
# ---------------------------------------------------------------------------
_c() { [[ -t 2 ]] && printf '\033[%sm' "$1" >&2 || true; }
log()  { _c "0;36"; printf '› %s\n' "$*" >&2; _c 0; }
ok()   { _c "0;32"; printf '✓ %s\n' "$*" >&2; _c 0; }
warn() { _c "1;33"; printf '! %s\n' "$*" >&2; _c 0; }
die()  { _c "1;31"; printf '✗ %s\n' "$*" >&2; _c 0; exit 1; }

trap 'die "failed at line $LINENO"' ERR

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for bin in git tmux; do
  command -v "$bin" >/dev/null 2>&1 || die "required command not found: $bin"
done

# ---------------------------------------------------------------------------
# Slug derivation
#   feat/alds-1234-nuevo-modal    -> alds-1234            (ticket-style)
#   hotfix/usuario-bloqueado-xyz  -> usuario-bloqueado-xyz (full slug)
# ---------------------------------------------------------------------------
derive_slug() {
  local branch="$1"
  local rest="${branch#*/}"   # strip "feat/" / "hotfix/" / etc.
  if [[ "$rest" =~ ^([a-zA-Z]+-[0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'
  else
    printf '%s' "$rest"
  fi
}

# ---------------------------------------------------------------------------
# tmux session bootstrap: idempotent, three windows (1, 2, 3) all in worktree
# ---------------------------------------------------------------------------
bootstrap_tmux() {
  local session="$1" worktree="$2"
  if tmux has-session -t "$session" 2>/dev/null; then
    warn "tmux session '$session' already exists — attaching"
  else
    log "Creating tmux session '$session'"
    tmux new-session -d -s "$session" -n "1" -c "$worktree"
    tmux new-window     -t "$session" -n "2" -c "$worktree"
    tmux new-window     -t "$session" -n "3" -c "$worktree"
    tmux select-window  -t "$session:1"
  fi
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session"
  fi
}

# ---------------------------------------------------------------------------
# create <repo> <branch> <base-branch>
# ---------------------------------------------------------------------------
cmd_create() {
  local repo="${1:-}" branch="${2:-}" base="${3:-}"
  [[ -n "$repo" && -n "$branch" && -n "$base" ]] \
    || die "usage: $0 create <repo> <branch> <base-branch>"

  local main_clone="$REPOS_ROOT/$repo"
  [[ -d "$main_clone/.git" ]] || die "no git repo at $main_clone — clone it first"

  local slug
  slug="$(derive_slug "$branch")"
  [[ -n "$slug" ]] || die "could not derive a slug from branch '$branch'"

  local worktree="$WORKTREE_ROOT/${repo}-${slug}"
  local session="${repo}-${slug}"

  log "repo:     $repo"
  log "branch:   $branch"
  log "base:     $base"
  log "slug:     $slug"
  log "worktree: $worktree"
  log "session:  $session"

  mkdir -p "$WORKTREE_ROOT"

  # Idempotent: if the worktree already exists, jump straight to tmux.
  if git -C "$main_clone" worktree list --porcelain | grep -qFx "worktree $worktree"; then
    warn "worktree already exists — re-attaching tmux session"
    bootstrap_tmux "$session" "$worktree"
    return 0
  fi

  log "Fetching origin…"
  git -C "$main_clone" fetch origin --prune

  # Resolve where the branch is, creating it from origin/<base> if missing.
  if git -C "$main_clone" show-ref --verify --quiet "refs/heads/$branch"; then
    log "branch '$branch' exists locally — using it"
  elif git -C "$main_clone" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    log "branch '$branch' exists on origin — creating local tracking branch"
    git -C "$main_clone" branch "$branch" "origin/$branch"
  else
    git -C "$main_clone" show-ref --verify --quiet "refs/remotes/origin/$base" \
      || die "base branch 'origin/$base' not found — check the name or fetch first"
    log "creating '$branch' from 'origin/$base'"
    git -C "$main_clone" branch "$branch" "origin/$base"
  fi

  log "Adding worktree at $worktree"
  git -C "$main_clone" worktree add "$worktree" "$branch"
  ok "worktree created"

  # Copy first env file that exists, in priority order.
  local env_copied=0 env_name
  for env_name in .env .env.local .env.staging .env.production; do
    if [[ -f "$main_clone/$env_name" ]]; then
      cp "$main_clone/$env_name" "$worktree/$env_name"
      chmod 600 "$worktree/$env_name"
      if git -C "$worktree" check-ignore -q "$env_name" 2>/dev/null; then
        ok "copied $env_name (gitignored, mode 600)"
      else
        warn "$env_name is NOT gitignored — add it to .gitignore so secrets don't leak"
      fi
      env_copied=1
      break
    fi
  done
  [[ "$env_copied" -eq 1 ]] \
    || warn "no env file (.env / .env.local / .env.staging / .env.production) found in $main_clone — skipping"

  # Copy .claude/ from main clone if it exists locally AND is gitignored
  # (i.e. it's local-only config that the worktree won't get from checkout).
  if [[ -d "$main_clone/.claude" ]] \
     && git -C "$main_clone" check-ignore -q ".claude" 2>/dev/null \
     && [[ ! -e "$worktree/.claude" ]]; then
    cp -R "$main_clone/.claude" "$worktree/"
    ok "copied .claude/ (local config)"
  fi

  # nvm + install deps inside a subshell so cwd/env changes don't leak.
  (
    cd "$worktree"

    if [[ -f .nvmrc && -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
      # shellcheck disable=SC1090,SC1091
      source "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
      nvm use >/dev/null 2>&1 || warn "nvm use failed — falling back to default node"
    fi

    local pm
    local -a install_cmd
    if   [[ -f pnpm-lock.yaml      ]]; then pm=pnpm; install_cmd=(pnpm install --frozen-lockfile)
    elif [[ -f yarn.lock           ]]; then pm=yarn; install_cmd=(yarn install --frozen-lockfile)
    elif [[ -f bun.lockb || -f bun.lock ]]; then pm=bun; install_cmd=(bun install --frozen-lockfile)
    elif [[ -f package-lock.json   ]]; then pm=npm;  install_cmd=(npm ci)
    else pm=npm; install_cmd=(npm install); warn "no lockfile found — using plain npm install"
    fi

    log "Installing JS deps with ${pm}…"
    if command -v "$pm" >/dev/null 2>&1; then
      if "${install_cmd[@]}"; then
        ok "dependencies installed"
      else
        warn "install failed — finish it manually inside the worktree"
      fi
    else
      warn "$pm not on PATH — install deps manually inside the worktree"
    fi
  )

  bootstrap_tmux "$session" "$worktree"
}

# ---------------------------------------------------------------------------
# remove <worktree-dir> [--delete-branch] [--force]
# ---------------------------------------------------------------------------
cmd_remove() {
  local target="" delete_branch=0 force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-branch) delete_branch=1; shift ;;
      --force)         force=1; shift ;;
      -*)              die "unknown flag: $1" ;;
      *)
        [[ -z "$target" ]] || die "unexpected arg: $1"
        target="$1"; shift
        ;;
    esac
  done
  [[ -n "$target" ]] || die "usage: $0 remove <worktree-dir> [--delete-branch] [--force]"

  # Resolve target to an absolute worktree path.
  local worktree
  if [[ "$target" == "." || "$target" == "./" ]]; then
    worktree="$(pwd)"
  elif [[ "$target" == /* ]]; then
    worktree="$target"
  elif [[ "$target" == */* ]]; then
    worktree="$(cd "$target" 2>/dev/null && pwd)" || die "path does not exist: $target"
  else
    worktree="$WORKTREE_ROOT/$target"
  fi
  [[ -d "$worktree" ]] || die "not a directory: $worktree"

  # Canonicalize so equality checks survive symlinks / trailing slashes.
  worktree="$(cd "$worktree" && pwd -P)"

  git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not inside a git work tree: $worktree"

  # Derive main clone from worktree metadata. The first entry of
  # `git worktree list` is always the main worktree (the clone itself).
  local main_clone
  main_clone="$(git -C "$worktree" worktree list --porcelain \
                | awk '/^worktree / { print $2; exit }')"
  [[ -n "$main_clone" ]] || die "could not determine main clone for $worktree"
  main_clone="$(cd "$main_clone" && pwd -P)"

  [[ "$worktree" != "$main_clone" ]] \
    || die "$worktree is the main clone — refusing to remove"

  local branch repo slug session
  branch="$(git -C "$worktree" rev-parse --abbrev-ref HEAD)"
  repo="$(basename "$main_clone")"
  slug="$(basename "$worktree")"
  slug="${slug#${repo}-}"  # strip "<repo>-" prefix if present
  session="${repo}-${slug}"

  log "worktree: $worktree"
  log "branch:   $branch"
  log "repo:     $repo"
  log "session:  $session"

  # Refuse to nuke uncommitted work unless --force.
  if [[ "$force" -eq 0 ]]; then
    if [[ -n "$(git -C "$worktree" status --porcelain)" ]]; then
      die "worktree has uncommitted changes — commit/stash them or pass --force"
    fi
  fi

  if tmux kill-session -t "$session" 2>/dev/null; then
    ok "killed tmux session '$session'"
  fi

  log "Removing worktree…"
  if [[ "$force" -eq 1 ]]; then
    git -C "$main_clone" worktree remove --force "$worktree" \
      || die "git worktree remove failed"
  else
    git -C "$main_clone" worktree remove "$worktree" \
      || die "git worktree remove failed"
  fi
  ok "worktree removed"

  if [[ "$delete_branch" -eq 1 ]]; then
    if git -C "$main_clone" branch -D "$branch" 2>/dev/null; then
      ok "deleted branch '$branch'"
    else
      warn "could not delete branch '$branch' (already gone?)"
    fi
  fi

  git -C "$main_clone" worktree prune 2>/dev/null || true
  ok "done"
}

# ---------------------------------------------------------------------------
# list [<repo>]
# ---------------------------------------------------------------------------
cmd_list() {
  local filter="${1:-}"
  [[ -d "$WORKTREE_ROOT" ]] \
    || { warn "no worktrees yet ($WORKTREE_ROOT does not exist)"; return 0; }

  local found=0
  printf '%-40s %-50s %-10s\n' "WORKTREE" "BRANCH" "TMUX"
  local dir
  for dir in "$WORKTREE_ROOT"/*/; do
    [[ -d "$dir" ]] || continue
    local name branch main_clone repo slug session status
    name="$(basename "$dir")"
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    main_clone="$(git -C "$dir" worktree list --porcelain 2>/dev/null \
                  | awk '/^worktree / { print $2; exit }')"
    repo="${main_clone:+$(basename "$main_clone")}"
    repo="${repo:-?}"
    if [[ -n "$filter" && "$repo" != "$filter" ]]; then
      continue
    fi
    slug="${name#${repo}-}"
    session="${repo}-${slug}"
    if tmux has-session -t "$session" 2>/dev/null; then status="alive"; else status="dead"; fi
    printf '%-40s %-50s %-10s\n' "$name" "$branch" "$status"
    found=1
  done
  [[ "$found" -eq 1 ]] || warn "no worktrees found"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  list)   shift; cmd_list   "$@" ;;
  ""|-h|--help)
    cat >&2 <<EOF
Usage:
  $0 create <repo> <branch> <base-branch>
  $0 remove <worktree-dir> [--delete-branch] [--force]
  $0 list   [<repo>]

Config:
  REPOS_ROOT     (default: \$HOME/Documents/projects)
  WORKTREE_ROOT  (default: \$REPOS_ROOT/.worktrees)
EOF
    exit 0
    ;;
  *) die "unknown subcommand: ${1} (use create|remove|list)" ;;
esac
