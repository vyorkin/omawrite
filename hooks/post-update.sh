#!/bin/bash
#
# omarchy post-update hook: carry the local Omawrite text-size patch onto the
# newest upstream tag after `omarchy update`.
#
# The whole story lives in ~/Work/omawrite/rebuild.sh. This hook only guards the
# path and runs it, so the logic stays in one place. Output lands in the omarchy
# update log; anything that needs a decision also raises a desktop notification.

set -euo pipefail

REPO="$HOME/Work/omawrite"
SCRIPT="$REPO/rebuild.sh"

[[ -x "$SCRIPT" ]] || exit 0

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || exit 0

"$SCRIPT" "$@"
