#!/usr/bin/env bash
#
# pr-review.sh — Spin up an isolated, READ-ONLY code-review environment for a GitHub PR.
#
# Given a PR URL it will:
#   1. Parse org / repo / PR number from the URL
#   2. Fetch the PR head and create a dedicated git worktree (your main clone is untouched)
#   3. Copy the JS env file into the worktree and install dependencies (lockfile-based)
#   4. Create a tmux session with 3 windows: claude / shell / review
#   5. Launch Claude Code seeded to run the `code-review-excellence` skill in
#      REVIEW-ONLY mode — it will NOT push, commit, comment, or open anything on GitHub
#   6. Claude writes the review to a markdown file in the worktree while the
#      interactive session stays alive, so you can keep asking follow-ups
#
# Usage:
#   ./pr-review.sh <github-pr-url>
#   ./pr-review.sh https://github.com/cashea-bnpl/merchant-web/pull/1316
#   ./pr-review.sh --clean <github-pr-url|repo#pr>   # tear the environment back down
#
# Config (override by exporting these before running):
#   REPOS_ROOT        where your clones live              (default: $HOME/Documents/projects)
#   WORKTREE_ROOT     where worktrees are created         (default: $REPOS_ROOT/.worktrees)
#   ENV_SOURCE        path to the .env to copy in         (default: <main clone>/.env)
#   REVIEW_SKILL      Claude Code skill to invoke         (default: code-review-excellence)
#   START_DEV         "1" to auto-start the dev server    (default: 0)
#   CLAUDE_GUARD      "1" to pass --disallowedTools guard  (default: 1)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
REPOS_ROOT="${REPOS_ROOT:-$HOME/Documents/projects}"
WORKTREE_ROOT="${WORKTREE_ROOT:-$REPOS_ROOT/.worktrees}"
REVIEW_SKILL="${REVIEW_SKILL:-code-review-excellence}"
START_DEV="${START_DEV:-0}"
CLAUDE_GUARD="${CLAUDE_GUARD:-1}"

# ---------------------------------------------------------------------------
# Logging (everything goes to stderr so it never pollutes piped output)
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
for bin in git tmux claude; do
  command -v "$bin" >/dev/null 2>&1 || die "required command not found: $bin"
done

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
CLEAN=0
if [[ "${1:-}" == "--clean" ]]; then CLEAN=1; shift; fi
URL="${1:-}"
[[ -n "$URL" ]] || die "usage: $0 [--clean] <github-pr-url>"

# Accepts: .../pull/1316, .../pull/1316/, .../pull/1316/files, repo#1316
if [[ "$URL" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  ORG="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]}"; PR="${BASH_REMATCH[3]}"
elif [[ "$URL" =~ ^([^/]+)/([^#]+)#([0-9]+)$ ]]; then
  ORG="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]}"; PR="${BASH_REMATCH[3]}"
else
  die "could not parse a PR from: $URL"
fi

MAIN_CLONE="$REPOS_ROOT/$REPO"
BRANCH="pr-$PR"
WORKTREE="$WORKTREE_ROOT/${REPO}-pr-${PR}"
STATE_DIR="$WORKTREE_ROOT/.state/${REPO}-pr-${PR}"
SESSION="review-${REPO}-${PR}"
REVIEW_FILE="code-review-pr-${PR}.md"

# ---------------------------------------------------------------------------
# Teardown mode
# ---------------------------------------------------------------------------
if [[ "$CLEAN" == "1" ]]; then
  log "Tearing down review environment for $ORG/$REPO #$PR"
  if tmux kill-session -t "$SESSION" 2>/dev/null; then
    ok "killed tmux session $SESSION"
  fi
  if [[ -d "$WORKTREE" ]]; then
    if git -C "$MAIN_CLONE" worktree remove --force "$WORKTREE" 2>/dev/null; then
      ok "removed worktree"
    else
      warn "git worktree remove failed for $WORKTREE — leaving the directory in place. Inspect it and 'rm -rf' manually if you're sure nothing in it is worth keeping."
    fi
  fi
  if git -C "$MAIN_CLONE" branch -D "$BRANCH" 2>/dev/null; then
    ok "deleted branch $BRANCH"
  fi
  rm -rf "$STATE_DIR"
  git -C "$MAIN_CLONE" worktree prune 2>/dev/null || true
  ok "done"
  exit 0
fi

log "Reviewing $ORG/$REPO PR #$PR"

# ---------------------------------------------------------------------------
# 1. Locate (or clone) the main repository
# ---------------------------------------------------------------------------
if [[ ! -d "$MAIN_CLONE/.git" ]]; then
  log "No clone at $MAIN_CLONE — cloning…"
  mkdir -p "$REPOS_ROOT"
  if command -v gh >/dev/null 2>&1; then
    gh repo clone "$ORG/$REPO" "$MAIN_CLONE"
  else
    git clone "git@github.com:$ORG/$REPO.git" "$MAIN_CLONE"
  fi
fi
ok "main clone: $MAIN_CLONE"

# Refresh remote refs (cheap, lets us see new branches/tags).
# pull/<n>/head works for forks too, so this is fork-safe.
git -C "$MAIN_CLONE" fetch origin --prune 2>/dev/null || warn "could not refresh origin (offline?)"

# Friendly head ref name for logs (best effort, needs gh)
if command -v gh >/dev/null 2>&1; then
  HEAD_REF="$(gh pr view "$PR" --repo "$ORG/$REPO" --json headRefName -q .headRefName 2>/dev/null || true)"
  [[ -n "${HEAD_REF:-}" ]] && log "PR source branch: $HEAD_REF"
fi

# ---------------------------------------------------------------------------
# 2. Fetch the PR head + create or refresh the worktree
# ---------------------------------------------------------------------------
# Git refuses to update a branch that is checked out in another worktree, so
# the fetch strategy depends on whether the worktree already exists:
#   - new worktree → fetch PR into a local branch in the main clone, then add worktree
#   - existing worktree → fetch + reset --hard inside the worktree (refreshes PR head)
mkdir -p "$WORKTREE_ROOT" "$STATE_DIR"
if git -C "$MAIN_CLONE" worktree list --porcelain | grep -qx "worktree $WORKTREE"; then
  warn "worktree already exists — refreshing PR head inside it (any local edits will be discarded)"
  git -C "$WORKTREE" fetch origin "pull/$PR/head"
  git -C "$WORKTREE" reset --hard FETCH_HEAD
  ok "refreshed PR head in $WORKTREE"
else
  log "Fetching PR head into branch '$BRANCH'"
  git -C "$MAIN_CLONE" fetch origin "pull/$PR/head:$BRANCH" --force
  git -C "$MAIN_CLONE" worktree add "$WORKTREE" "$BRANCH"
  ok "worktree: $WORKTREE"
fi

# ---------------------------------------------------------------------------
# 3. JavaScript environment: copy .env + install deps
# ---------------------------------------------------------------------------
ENV_SOURCE="${ENV_SOURCE:-$MAIN_CLONE/.env}"
if [[ -f "$ENV_SOURCE" ]]; then
  ENV_BASENAME="$(basename "$ENV_SOURCE")"
  ENV_DEST="$WORKTREE/$ENV_BASENAME"
  cp "$ENV_SOURCE" "$ENV_DEST"
  chmod 600 "$ENV_DEST"               # secret file -> owner-only
  if git -C "$WORKTREE" check-ignore -q "$ENV_BASENAME" 2>/dev/null; then
    ok "copied $ENV_BASENAME (gitignored, mode 600)"   # contents never printed
  else
    warn "$ENV_BASENAME is NOT gitignored in this repo — add it to .gitignore so secrets can't be committed"
  fi
else
  warn "no env file at $ENV_SOURCE — skipping. Set ENV_SOURCE=<path> to point at the right one."
fi

# Pick the package manager from the lockfile, then install reproducibly.
install_deps() {
  cd "$WORKTREE"
  # Best-effort node version pin if nvm + .nvmrc are present
  if [[ -f .nvmrc && -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "${NVM_DIR:-$HOME/.nvm}/nvm.sh" && nvm use >/dev/null 2>&1 || warn "nvm use failed; using default node"
  fi
  if   [[ -f pnpm-lock.yaml   ]]; then PM=pnpm; INSTALL=(pnpm install --frozen-lockfile);  DEV=(pnpm dev)
  elif [[ -f yarn.lock        ]]; then PM=yarn; INSTALL=(yarn install --frozen-lockfile);  DEV=(yarn dev)
  elif [[ -f bun.lockb || -f bun.lock ]]; then PM=bun; INSTALL=(bun install --frozen-lockfile); DEV=(bun dev)
  elif [[ -f package-lock.json ]]; then PM=npm;  INSTALL=(npm ci);                          DEV=(npm run dev)
  else PM=npm; INSTALL=(npm install); DEV=(npm run dev); warn "no lockfile found — using plain install"; fi
  log "Installing JS deps with ${PM}…"
  command -v "$PM" >/dev/null 2>&1 || { warn "${PM} not on PATH — run the install yourself in the 'shell' window"; return 0; }
  "${INSTALL[@]}" && ok "dependencies installed" || warn "install failed — finish it in the 'shell' window"
  printf '%s\n' "${DEV[*]}" > "$STATE_DIR/dev-cmd"   # remember how to start the dev server
}
install_deps

# ---------------------------------------------------------------------------
# 4. Build the review prompt + a launcher (file-based, so quoting stays sane)
# ---------------------------------------------------------------------------
PROMPT_FILE="$STATE_DIR/review-prompt.md"
cat > "$PROMPT_FILE" <<EOF
Use the ${REVIEW_SKILL} skill to perform a thorough code review of GitHub PR #${PR} (${ORG}/${REPO}).

The PR head is checked out in this worktree as the local branch "${BRANCH}". Review the diff of
this branch against its merge base with the repository's default branch — detect whether the
default is origin/main or origin/master, then diff merge-base(HEAD, <default>)...HEAD.

STRICT CONSTRAINTS — this is a READ-ONLY review:
- Do NOT push, commit, or modify the branch. Do NOT run \`git push\`, \`git commit\`, or \`git merge\`.
- Do NOT run any GitHub-writing command: no \`gh pr create/edit/comment/review/merge/close/reopen\`,
  no \`gh issue create/edit/comment/close\`, no \`gh api\` (it can POST/PATCH/DELETE), no
  \`gh release|repo|workflow\` write subcommands. Do NOT post reviews, comments, or status checks.
- READ-ONLY GitHub queries are ALLOWED and encouraged: \`gh pr view\`, \`gh pr diff\`,
  \`gh pr checks\`, \`gh pr status\`, \`gh issue view\`, \`gh issue list\`, \`gh repo view\`.
- Do NOT read, open, print, or quote the contents of any .env file or other secrets. If a finding
  involves secrets handling, describe it without revealing values.

DELIVERABLE:
- Write the complete review to ./${REVIEW_FILE} in this worktree (create or overwrite it).
- Then post a short summary of the top findings in this chat and STOP. Stay in this interactive
  session so I can ask follow-up questions — do not exit.
EOF

# Optional hard guard: block GitHub-WRITING tools AND secret-file reads at the CLI level.
# Format per Claude Code docs: --disallowedTools is variadic — pass each pattern as its OWN
# positional arg, with a SPACE between the command and the wildcard (e.g. "Bash(git push *)").
# Important: DO NOT use "Bash(gh *)" — it blocks read-only queries like `gh pr view` that the
# review skill needs. Block only the gh subcommands that mutate GitHub state.
# We add "--" after the patterns so Claude does not confuse the prompt with another pattern.
# If your Claude Code version rejects this flag entirely, set CLAUDE_GUARD=0.
GUARD_FLAGS=()
if [[ "$CLAUDE_GUARD" == "1" ]]; then
  GUARD_FLAGS=(
    --disallowedTools
    # git writes
    "Bash(git push *)" "Bash(git commit *)" "Bash(git merge *)"
    # gh PR writes
    "Bash(gh pr create *)" "Bash(gh pr edit *)" "Bash(gh pr comment *)"
    "Bash(gh pr review *)" "Bash(gh pr merge *)" "Bash(gh pr close *)"
    "Bash(gh pr reopen *)" "Bash(gh pr ready *)"
    # gh issue writes
    "Bash(gh issue create *)" "Bash(gh issue edit *)" "Bash(gh issue comment *)"
    "Bash(gh issue close *)" "Bash(gh issue reopen *)" "Bash(gh issue delete *)"
    # gh release / repo / workflow writes
    "Bash(gh release create *)" "Bash(gh release edit *)" "Bash(gh release delete *)"
    "Bash(gh repo create *)" "Bash(gh repo edit *)" "Bash(gh repo delete *)"
    "Bash(gh workflow run *)" "Bash(gh workflow enable *)" "Bash(gh workflow disable *)"
    # gh api can do POST/PATCH/DELETE — block blanket; reads should use high-level subcommands
    "Bash(gh api *)"
    # secret file reads
    "Read(*.env)" "Read(*.env.*)" "Read(**/.env)" "Read(**/.env.*)"
    "Bash(cat *.env*)" "Bash(rg *.env*)" "Bash(bat *.env*)"
  )
fi

LAUNCHER="$STATE_DIR/launch-claude.sh"
{
  printf '#!/usr/bin/env bash\nset -e\ncd %q\n' "$WORKTREE"
  printf 'exec claude'
  for f in "${GUARD_FLAGS[@]}"; do printf ' %q' "$f"; done
  # "--" stops flag/pattern parsing so the prompt is unambiguously the initial query.
  printf ' -- "$(cat %q)"\n' "$PROMPT_FILE"
} > "$LAUNCHER"
chmod +x "$LAUNCHER"

# ---------------------------------------------------------------------------
# 5. tmux session: claude / shell / review
# ---------------------------------------------------------------------------
if tmux has-session -t "$SESSION" 2>/dev/null; then
  warn "tmux session '$SESSION' already exists — attaching to it"
else
  log "Creating tmux session '$SESSION'"
  tmux new-session  -d -s "$SESSION" -n claude -c "$WORKTREE"
  tmux new-window      -t "$SESSION" -n shell  -c "$WORKTREE"
  tmux new-window      -t "$SESSION" -n review -c "$WORKTREE"

  # Window 1: Claude Code seeded with the review prompt (interactive, persistent).
  tmux send-keys -t "$SESSION:claude" "exec $LAUNCHER" C-m

  # Window 2: free shell for git diff / tests / ad-hoc work.
  tmux send-keys -t "$SESSION:shell" \
    "echo 'Worktree: $WORKTREE'; echo 'PR #$PR — git diff origin/HEAD...$BRANCH'" C-m

  # Window 3: live-tail the review file as Claude writes it (-F waits for it to appear).
  tmux send-keys -t "$SESSION:review" \
    "echo 'Watching $REVIEW_FILE …'; tail -n +1 -F '$REVIEW_FILE'" C-m

  # Optional: auto-start the dev server in the shell window
  if [[ "$START_DEV" == "1" && -f "$STATE_DIR/dev-cmd" ]]; then
    tmux send-keys -t "$SESSION:shell" "$(cat "$STATE_DIR/dev-cmd")" C-m
  fi

  tmux select-window -t "$SESSION:claude"
fi

ok "Environment ready."
log "Review file will appear at: $WORKTREE/$REVIEW_FILE"

# ---------------------------------------------------------------------------
# 6. Attach
# ---------------------------------------------------------------------------
if [[ -n "${TMUX:-}" ]]; then
  tmux switch-client -t "$SESSION"
else
  tmux attach-session -t "$SESSION"
fi