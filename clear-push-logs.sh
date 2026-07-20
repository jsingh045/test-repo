#!/usr/bin/env bash
#
# clear-push-logs.sh
#
# Remove all per-branch push logs written by simulate-pushes-worktrees.sh.
#
# Usage:
#   ./clear-push-logs.sh
#
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOG_DIR="$REPO_ROOT/push-logs"

if [[ ! -d "$LOG_DIR" ]]; then
  echo "No log directory at $LOG_DIR — nothing to clear."
  exit 0
fi

count=$(find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' | wc -l | tr -d ' ')
find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -delete
echo "Cleared $count log file(s) from $LOG_DIR"
