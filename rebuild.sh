#!/usr/bin/env bash
#
# Keep the locally patched Omawrite matching the desktop text size, and carry
# that patch forward across upstream releases.
#
# Why the patch exists
# --------------------
# Upstream anchors the editor font at 20px (`editorFontPixelSize: scaledSize(20)`
# in src/Main.qml). The desktop text size knob (`omarchy display text size`) is
# anchored at 12px, so above the 12px default the editor renders far larger than
# the desktop font, GTK apps, and the terminal. Anchor it at 12px and the editor
# follows the desktop text size exactly.
#
# What this script does
# ---------------------
#   1. fetch upstream tags,
#   2. compare the tag our patch sits on with the newest one,
#   3. inspect the newest tag for a changed editor font anchor, or for a new
#      font-size setting. If upstream now lets the user pick a size, the patch
#      is obsolete and we say so instead of rebasing,
#   4. rebase the patch onto the newest tag, rebuild, run the test suite,
#   5. install into /usr/local/bin, which precedes the pacman-owned /usr/bin in
#      PATH, so `omarchy update` never clobbers it.
#
# Usage
# -----
#   ./rebuild.sh           # check, rebase if needed, build, test, install
#   ./rebuild.sh --check   # report only, change nothing
#
# The omarchy post-update hook (hooks/post-update.sh) runs `./rebuild.sh` after
# every `omarchy update`.

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

BRANCH="local/text-size"
INSTALL_PATH="/usr/local/bin/omawrite"
BINARY="$REPO_DIR/build/omawrite"
STATE_FILE="$REPO_DIR/.build-state"
# A user-level desktop entry, so the launcher starts /usr/local/bin/omawrite by
# absolute path. Without it the shell's launcher resolved the packaged
# /usr/bin/omawrite (a cached path), and the patched binary never ran.
DESKTOP_ENTRY="$HOME/.local/share/applications/omawrite.desktop"
DESKTOP_SOURCE="$REPO_DIR/local/omawrite.desktop"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

notify() { # <headline> <body>
  command -v omarchy-notification-send >/dev/null 2>&1 || return 0
  # No -i: the notification daemon here falls back to rendering the icon name
  # as literal text when it cannot resolve it, which spammed a giant "omawrite".
  omarchy-notification-send --app-name Omawrite -u normal "$1" "$2" >/dev/null 2>&1 || true
}

[[ -d .git ]] || die "$REPO_DIR is not a git repository"

log "fetching upstream tags"
# `upstream` is omacom-io/omawrite; `origin` is the fork that carries the patch
# branch, so fetching tags from `origin` would miss new upstream releases.
git fetch --tags --force upstream

latest_tag="$(git describe --tags --abbrev=0 upstream/master)"
base_tag="$(git describe --tags --abbrev=0 "$BRANCH^" 2>/dev/null || echo unknown)"

# --- Inspect the newest upstream tag -----------------------------------------

anchor_line="$(git show "$latest_tag:src/Main.qml" 2>/dev/null \
  | grep -m1 -E 'editorFontPixelSize:' || true)"

# A new font-size knob (a settings key, a property, a menu entry) means upstream
# now exposes the choice and our hardcoded patch should be dropped. Exclude the
# known sizing plumbing so this only fires on genuinely new names.
new_size_api="$(git grep -inE 'fontsize|font-size|fontpixelsize' "$latest_tag" -- src README.md 2>/dev/null \
  | grep -viE 'editorFontPixelSize|font\.pixelSize|FontMetrics|fontPixelSize: Math' || true)"

if [[ -n "$new_size_api" ]]; then
  verdict="obsolete-setting"
elif [[ "$anchor_line" == *"scaledSize(20)"* ]]; then
  verdict="patch-needed"
elif [[ "$anchor_line" == *"scaledSize(12)"* ]]; then
  verdict="obsolete-adopted"
elif [[ -z "$anchor_line" ]]; then
  verdict="review"
else
  verdict="review"
fi

# --- Report -------------------------------------------------------------------

echo
printf 'upstream newest tag : %s\n' "$latest_tag"
printf 'patch base tag      : %s\n' "$base_tag"
printf 'editor anchor       : %s\n' "${anchor_line:-<not found>}"
printf 'verdict             : %s\n' "$verdict"
if [[ -n "$new_size_api" ]]; then
  echo
  echo "new font-size-looking API found in $latest_tag:"
  printf '%s\n' "$new_size_api" | sed 's/^/  /'
fi
echo

case "$verdict" in
  patch-needed)      log "upstream still anchors the editor at 20px; the patch is still needed" ;;
  obsolete-adopted)  log "upstream now anchors the editor at 12px; the patch is no longer needed" ;;
  obsolete-setting)  log "upstream looks like it grew a font-size setting; the patch is probably obsolete" ;;
  review)            log "upstream changed how the editor font is sized; review by hand" ;;
esac

if [[ "${1:-}" == "--check" ]]; then
  exit 0
fi

# --- Obsolete / unclear: do not touch the installed binary --------------------

if [[ "$verdict" != "patch-needed" ]]; then
  msg="Upstream $latest_tag no longer needs the local Omawrite text-size patch."
  body="Review $REPO_DIR, then drop the patch, remove $INSTALL_PATH, and delete $DESKTOP_ENTRY"
  notify "$msg" "$body"
  warn "$msg"
  warn "$body"
  exit 0
fi

# --- Patch still needed -------------------------------------------------------

if [[ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]]; then
  log "switching to $BRANCH"
  git checkout -q "$BRANCH"
fi

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is dirty; commit or stash changes in $REPO_DIR first"
fi

# --- Patch the newest tag -----------------------------------------------------
# This used to be a rebase of the patch commits onto the new tag, which
# conflicted every time upstream touched a line near ours and had to be resolved
# by hand again — with the same conflict coming back at the next release.
#
# Now the branch is rebuilt from the newest tag each time: this repository's own
# tooling files are restored from the branch being replaced, and
# local/apply-text-size-patch.py splices local/text-size.patch in by anchoring
# each hunk on its own content rather than on a line number. Upstream adding a
# line next to one of ours is therefore harmless — its line stays, ours lands.
# A genuine upstream refactor of the same code stops the script with the hunk
# named and nothing committed, which is the moment a human is actually needed.
#
# The patch file, not the commit history, is the source of truth now: put edits
# to the patched code there (the script reports what it applied).

if [[ -n "$(git log --oneline "$latest_tag..$BRANCH" -- src tests 2>/dev/null)" ]]; then
  warn "commits on $BRANCH touch src/ or tests/, and those edits are not carried over:"
  warn "  the patch file is the source of truth now, so put them in local/text-size.patch"
fi

previous_head="$(git rev-parse HEAD)"
log "rebuilding $BRANCH on $latest_tag (its base was $base_tag)"
if [[ "$base_tag" != "unknown" ]]; then
  git tag -f "local/applied-${base_tag#v}" "$previous_head" >/dev/null 2>&1 || true
fi
git checkout -q -B "$BRANCH" "$latest_tag"
if ! git checkout -q "$previous_head" -- rebuild.sh local hooks .gitignore 2>/dev/null; then
  die "could not restore this repository's own tooling from ${previous_head:0:7}"
fi
if ! python3 local/apply-text-size-patch.py; then
  notify "Omawrite patch needs a human" "Upstream $latest_tag changed the code the patch edits; see $REPO_DIR"
  die "the patch could not be applied to $latest_tag; nothing was committed"
fi
git add -A
if git diff --cached --quiet; then
  log "the branch already holds the patch applied to $latest_tag"
else
  git commit -q -m "local: apply the text-size patch to $latest_tag"
  log "patched $latest_tag as $(git rev-parse --short HEAD)"
fi

head_rev="$(git rev-parse HEAD)"
build_needed=true
if [[ -f "$BINARY" && -f "$STATE_FILE" && "$(cat "$STATE_FILE")" == "$head_rev" ]]; then
  build_needed=false
fi

if $build_needed; then
  log "building"
  ./bin/build

  log "running tests"
  if [[ -d tests ]]; then
    log_file="$(mktemp)"
    if ! ( cd tests && qmake6 tests.pro >/dev/null \
        && make -j"$(nproc)" >/dev/null \
        && QT_QPA_PLATFORM=offscreen ./tst_omawrite >"$log_file" 2>&1 ); then
      tail -n 20 "$log_file" >&2
      notify "Omawrite tests failed" "Patch not installed; see $REPO_DIR/tests output"
      die "test suite failed"
    fi
    grep -m1 '^Totals:' "$log_file" || true
  fi

  printf '%s\n' "$head_rev" > "$STATE_FILE"
else
  log "build is up to date ($head_rev)"
fi

# --- Install ------------------------------------------------------------------

# Always pin the launcher at the patched binary, even before the install below
# succeeds: this needs no root and is what keeps the launcher off /usr/bin.
if [[ -f "$DESKTOP_SOURCE" ]]; then
  mkdir -p "$(dirname -- "$DESKTOP_ENTRY")"
  if ! cmp -s "$DESKTOP_SOURCE" "$DESKTOP_ENTRY"; then
    cp "$DESKTOP_SOURCE" "$DESKTOP_ENTRY"
    command -v update-desktop-database >/dev/null 2>&1 \
      && update-desktop-database "$(dirname -- "$DESKTOP_ENTRY")" >/dev/null 2>&1 || true
    log "launcher pinned: $DESKTOP_ENTRY"
  fi
fi

if [[ -f "$INSTALL_PATH" ]] && cmp -s "$BINARY" "$INSTALL_PATH"; then
  log "already installed: $INSTALL_PATH"
  exit 0
fi

if sudo -n install -Dm755 "$BINARY" "$INSTALL_PATH" 2>/dev/null; then
  log "installed: $INSTALL_PATH"
  exit 0
fi

cmd="sudo install -Dm755 $BINARY $INSTALL_PATH"
notify "Omawrite rebuilt" "Run: $cmd"
warn "could not install without a password; run: $cmd"
exit 1
