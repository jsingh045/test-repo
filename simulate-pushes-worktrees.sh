#!/usr/bin/env bash
#
# simulate-pushes-worktrees.sh
#
# Spin up N git worktrees (one branch each) from the CURRENT repo and run
# concurrent push loops. Each branch pushes M times, spread over a target
# duration. All worktrees share this repo's single object store — no extra
# clones. Each branch pushes its own ref, so they run truly concurrently.
#
# Usage:
#   ./simulate-pushes-worktrees.sh [BRANCHES] [PUSHES] [DURATION_SECS]
#   ./simulate-pushes-worktrees.sh run     [BRANCHES] [PUSHES] [DURATION_SECS]
#   ./simulate-pushes-worktrees.sh cleanup [BRANCHES]
#
# Examples:
#   ./simulate-pushes-worktrees.sh                 # 10 branches x 10 pushes over 60s
#   ./simulate-pushes-worktrees.sh run 10 10 60    # same, explicit
#   ./simulate-pushes-worktrees.sh cleanup         # remove worktrees + local branches
#
set -euo pipefail

# ---- Parse subcommand (optional) ---------------------------------------
CMD=run
case "${1:-}" in
  run)        CMD=run;     shift ;;
  cleanup)    CMD=cleanup; shift ;;
  ""|[0-9]*)  CMD=run ;;                    # default, or numeric first arg
  *) echo "Unknown command: $1 (use 'run' or 'cleanup')" >&2; exit 1 ;;
esac

# ---- Config ------------------------------------------------------------
NUM_BRANCHES="${1:-10}"          # how many branches / worktrees
PUSHES_PER_BRANCH="${2:-10}"     # pushes per branch
DURATION_SECS="${3:-60}"         # spread each branch's pushes over this window
REMOTE="origin"
BRANCH_PREFIX="jsingh045/wt"
TARGET_FILE="counter.txt"
# ------------------------------------------------------------------------

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Error: not inside a git repository." >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$REPO_ROOT")"
WT_BASE="$(dirname "$REPO_ROOT")/${REPO_NAME}-worktrees"
LOG_DIR="$REPO_ROOT/push-logs"

# Seconds between pushes within a branch (integer floor, min 0).
INTERVAL=$(( DURATION_SECS / PUSHES_PER_BRANCH ))
(( INTERVAL < 0 )) && INTERVAL=0

branch_name() { printf "%s-%02d" "$BRANCH_PREFIX" "$1"; }
wt_path()     { printf "%s/wt-%02d" "$WT_BASE" "$1"; }

# ---- Worktree setup (idempotent) ---------------------------------------
setup_worktree() {
  local path="$1" branch="$2"
  if git worktree list --porcelain | grep -qx "worktree $path"; then
    echo "[$branch] reusing existing worktree"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add "$path" "$branch" >/dev/null
  else
    git worktree add -b "$branch" "$path" HEAD >/dev/null
  fi
  echo "[$branch] worktree ready at $path"
}

# ---- One branch's push loop (runs in the background) -------------------
run_loop() {
  local path="$1" branch="$2" pushes="$3" interval="$4"
  cd "$path"
  local i failed=0
  for (( i = 1; i <= pushes; i++ )); do
    printf 'push %d on %s at %s\n' "$i" "$branch" "$(date +%s.%N)" >> "$TARGET_FILE"
    git add "$TARGET_FILE"
    git commit -q -m "[$branch] push #$i" >/dev/null
    # Only the FIRST push per branch needs --force: each run starts from HEAD,
    # so remote history diverges between runs and push #1 is a non-fast-forward.
    # Once it lands, pushes #2..N build on it and fast-forward normally.
    local force=""
    (( i == 1 )) && force="--force"
    if git push -q $force "$REMOTE" "$branch"; then
      echo "$(date '+%Y-%m-%dT%H:%M:%S') [$branch] push #$i OK"
    else
      echo "$(date '+%Y-%m-%dT%H:%M:%S') [$branch] push #$i FAILED" >&2
      failed=$(( failed + 1 ))
    fi
    (( i < pushes )) && (( interval > 0 )) && sleep "$interval"
  done
  echo "[$branch] done ($pushes pushes, $failed failed)"
  (( failed == 0 ))   # propagate a non-zero exit if any push failed
}

# ---- Commands ----------------------------------------------------------
do_run() {
  echo "Setting up $NUM_BRANCHES worktrees under $WT_BASE ..."
  for (( n = 1; n <= NUM_BRANCHES; n++ )); do
    setup_worktree "$(wt_path "$n")" "$(branch_name "$n")"
  done

  mkdir -p "$LOG_DIR"
  echo "Launching $NUM_BRANCHES concurrent loops: ${PUSHES_PER_BRANCH} pushes each,"
  echo "  ~${INTERVAL}s apart (~${DURATION_SECS}s window). Logs: $LOG_DIR/"

  local -a pids=()
  local start; start=$(date +%s)
  for (( n = 1; n <= NUM_BRANCHES; n++ )); do
    local idx; idx=$(printf "%02d" "$n")
    run_loop "$(wt_path "$n")" "$(branch_name "$n")" \
             "$PUSHES_PER_BRANCH" "$INTERVAL" \
             > "$LOG_DIR/wt-${idx}.log" 2>&1 &
    pids+=("$!")
  done

  local fail=0
  for pid in "${pids[@]}"; do wait "$pid" || fail=$((fail + 1)); done
  local end; end=$(date +%s)

  local total=$(( NUM_BRANCHES * PUSHES_PER_BRANCH ))
  echo "All loops finished in $(( end - start ))s. Target total pushes: $total"
  (( fail > 0 )) && echo "WARNING: $fail loop(s) had a non-zero exit — check $LOG_DIR/" >&2
  echo "Verify remote tips:"
  echo "  for n in \$(seq -w 1 $NUM_BRANCHES); do b=\"${BRANCH_PREFIX}-\$n\"; printf '%s: ' \"\$b\"; git ls-remote $REMOTE \"refs/heads/\$b\" | cut -c1-12; done"
}

do_cleanup() {
  echo "Removing worktrees and local branches (${BRANCH_PREFIX}-01..$(printf '%02d' "$NUM_BRANCHES")) ..."
  for (( n = 1; n <= NUM_BRANCHES; n++ )); do
    local path branch; path="$(wt_path "$n")"; branch="$(branch_name "$n")"
    if git worktree list --porcelain | grep -qx "worktree $path"; then
      git worktree remove --force "$path" && echo "removed worktree $path"
    fi
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git branch -D "$branch" >/dev/null && echo "deleted local branch $branch"
    fi
  done
  git worktree prune
  echo "Done. Remote branches on $REMOTE are left intact."
  echo "To delete them remotely too:"
  echo "  for n in \$(seq -w 1 $NUM_BRANCHES); do git push $REMOTE --delete \"${BRANCH_PREFIX}-\$n\"; done"
}

case "$CMD" in
  run)     do_run ;;
  cleanup) do_cleanup ;;
esac
