# cli-tools

Personal collection of CLI scripts for git worktree workflows and GitHub PR reviews.

## Install

```bash
./install.sh
```

This creates symlinks in `~/.local/bin/` (override with `PREFIX=~/bin ./install.sh`). Make sure that directory is on your `$PATH`.

After installing you can invoke each tool by its short name from anywhere:

```bash
worktree create merchant-web feat/alds-1234-modal feat/merchant-web
pr-review https://github.com/org/repo/pull/123
```

## Scripts

### `worktree` — git worktree manager for feature development

Unified manager for creating, removing, and listing git worktrees. Sets up a tmux session, copies env files, and installs JS dependencies.

```
worktree create <repo> <branch> <base-branch>
worktree remove <worktree-dir> [--delete-branch] [--force]
worktree list   [<repo>]
```

**Examples**

```bash
# Create a feature worktree
worktree create merchant-web feat/alds-1234-nuevo-modal feat/merchant-web

# Remove by folder name (branch, repo, and tmux session derived from git metadata)
worktree remove merchant-web-alds-1234

# Remove from inside the worktree
cd ~/Documents/projects/.worktrees/merchant-web-alds-1234
worktree remove .

# Remove and also drop the local branch
worktree remove merchant-web-alds-1234 --delete-branch
```

**Behaviour highlights**

- Slug derived from the branch: `feat/alds-1234-foo` → `alds-1234`, `hotfix/usuario-bloqueado-xyz` → `usuario-bloqueado-xyz`.
- Worktree path: `$WORKTREE_ROOT/<repo>-<slug>`.
- Tmux session: `<repo>-<slug>` with three windows (`1`, `2`, `3`), all cwd'd to the worktree.
- Idempotent: re-running `create` for an existing worktree just re-attaches the tmux session.
- `remove` refuses to drop a worktree with uncommitted changes unless `--force`.
- `.env` fallback (first match copied with mode 600): `.env` → `.env.local` → `.env.staging` → `.env.production`.
- Copies `.claude/` from the main clone if it exists locally and is gitignored.
- Runs `nvm use` if `.nvmrc` is present, then installs deps using the detected package manager (`pnpm` / `yarn` / `bun` / `npm`).

**Config (env vars)**

| Var | Default | Purpose |
|---|---|---|
| `REPOS_ROOT` | `$HOME/Documents/projects` | Where your clones live |
| `WORKTREE_ROOT` | `$REPOS_ROOT/.worktrees` | Where worktrees are created |

### `pr-review` — READ-ONLY code-review environment for a GitHub PR

Spins up an isolated worktree pinned to the PR head, copies the env file, installs deps, and launches Claude Code in a tmux session seeded with a review prompt. The Claude session is guarded against pushing, committing, or making any GitHub mutation.

```
pr-review <github-pr-url>
pr-review --clean <github-pr-url|repo#pr>
```

**Examples**

```bash
pr-review https://github.com/cashea-bnpl/merchant-web/pull/1316
pr-review --clean https://github.com/cashea-bnpl/merchant-web/pull/1316
```

**Config (env vars)**

| Var | Default | Purpose |
|---|---|---|
| `REPOS_ROOT` | `$HOME/Documents/projects` | Where your clones live |
| `WORKTREE_ROOT` | `$REPOS_ROOT/.worktrees` | Where review worktrees are created |
| `ENV_SOURCE` | `<main clone>/.env` | `.env` file to copy into the worktree |
| `REVIEW_SKILL` | `code-review-excellence` | Claude Code skill to invoke |
| `START_DEV` | `0` | Set to `1` to auto-start the dev server |
| `CLAUDE_GUARD` | `1` | Block GitHub-writing tools at the Claude CLI level |

## Requirements

- `git`, `tmux`
- `claude` (only for `pr-review`)
- `gh` (optional — used by `pr-review` for fork-safe PR head fetching and friendly logs)
- `nvm` (optional — used by both scripts when `.nvmrc` is present)
