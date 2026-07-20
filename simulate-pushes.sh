#!/usr/bin/env bash
#
# simulate-pushes.sh
#
# Simulates a burst of git pushes by repeatedly updating a file,
# committing, and pushing in a loop.
#
# Usage:
#   ./simulate-pushes.sh [NUM_PUSHES] [BRANCH]
#
# Examples:
#   ./simulate-pushes.sh            # 80 pushes to the current branch
#   ./simulate-pushes.sh 80         # 80 pushes to the current branch
#   ./simulate-pushes.sh 50 main    # 50 pushes to the 'main' branch
#
set -euo pipefail

# ---- Config -------------------------------------------------------------
NUM_PUSHES="${1:-80}"                                   # how many push cycles
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD)}"       # target branch
TARGET_FILE="push-counter.txt"                          # file we keep updating
REMOTE="origin"
# ------------------------------------------------------------------------

# Make sure we're inside a git repo.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

echo "Simulating $NUM_PUSHES pushes to $REMOTE/$BRANCH ..."
start_time=$(date +%s)

for ((i = 1; i <= NUM_PUSHES; i++)); do
  # 1. Update the file with a unique value so there is always a change.
  echo "push #$i at $(date +%s.%N)" >> "$TARGET_FILE"

  # 2. Stage the change.
  git add "$TARGET_FILE"

  # 3. Commit.
  git commit -q -m "Simulated push #$i" >/dev/null

  # 4. Push.
  git push -q "$REMOTE" "$BRANCH"

  echo "  -> completed push #$i"
done

end_time=$(date +%s)
elapsed=$((end_time - start_time))
echo "Done: $NUM_PUSHES pushes in ${elapsed}s."
