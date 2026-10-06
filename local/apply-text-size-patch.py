#!/usr/bin/env python3
"""Apply local/text-size.patch to a checkout, locating each hunk by its content.

Why this exists
---------------
The text-size patch used to live as commits that were rebased onto every
upstream release. A rebase replays those commits onto moving code, so every time
upstream touched a line near ours it produced a conflict — and the same conflict
came back with the next release. Resolving it by hand once did not help; the
next rebase had to do it again.

This script applies the stored patch instead. Each hunk is located by its own
content — the lines it removes, or the lines it sits between — and never by line
number, so upstream adding a line next to one of ours is harmless: the hunk is
spliced in at its anchor and everything else, the new upstream line included,
stays where it is.

When an anchor is genuinely gone (upstream refactored the area, or the patch is
already applied in an unexpected way) the script names the hunk and stops
without writing anything, because a half-applied patch is worse than none.

Idempotent: hunks whose added lines are already present are skipped.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATCH = Path(__file__).resolve().parent / "text-size.patch"


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def split_groups(body: list[tuple[str, str]]) -> list[tuple[list[str], list[tuple[str, str]], list[str]]]:
    """A hunk's body -> [(lead, changes, trail), ...], one per change run.

    A single hunk can hold several changes with context between them: the tests
    hunk replaces three expectations, and the lines between them are context. Each
    run is placed on its own, with the context before and after it as the anchor,
    which is the only way the middle changes can be found independently of the
    first.
    """
    groups: list[tuple[list[str], list[tuple[str, str]], list[str]]] = []
    lead: list[str] = []
    changes: list[tuple[str, str]] = []
    i = 0
    while i < len(body):
        kind, text = body[i]
        if kind == " ":
            if changes:
                trail: list[str] = []
                while i < len(body) and body[i][0] == " ":
                    trail.append(body[i][1])
                    i += 1
                groups.append((lead, changes, trail))
                lead, changes = list(trail), []
                continue
            lead.append(text)
        else:
            changes.append((kind, text))
        i += 1
    if changes:
        groups.append((lead, changes, []))
    return groups


def parse_patch(text: str) -> list[tuple[str, list[dict]]]:
    """Patch text -> [(path, [hunk, ...])] with hunk = body/header."""
    files: list[tuple[str, list[dict]]] = []
    current_file: list[dict] | None = None
    hunk: dict | None = None
    for raw in text.splitlines():
        if raw.startswith("diff --git "):
            if " b/" not in raw:
                die(f"cannot read the target path from: {raw}")
            current_file = []
            files.append((raw.split(" b/", 1)[1], current_file))
            hunk = None
        elif raw.startswith("@@") and current_file is not None:
            hunk = {"body": [], "header": raw}
            current_file.append(hunk)
        elif hunk is not None:
            if raw.startswith("-") and not raw.startswith("---"):
                hunk["body"].append(("-", raw[1:]))
            elif raw.startswith("+") and not raw.startswith("+++"):
                hunk["body"].append(("+", raw[1:]))
            elif raw.startswith(" "):
                hunk["body"].append((" ", raw[1:]))
            elif raw.startswith("\\"):  # "\ No newline at end of file"
                continue
            elif raw == "":
                # A truly empty line in the patch body carries no marker only
                # when the hunk ended; anything else would be a malformed patch.
                hunk = None
    return files


def find_block(lines: list[str], block: list[str], start: int = 0) -> list[int]:
    return [i for i in range(start, len(lines) - len(block) + 1) if lines[i : i + len(block)] == block]


def apply_hunk(lines: list[str], group: tuple[list[str], list[tuple[str, str]], list[str]], where: str) -> tuple[list[str] | None, str]:
    lead, changes, trail = group
    removed = [t for k, t in changes if k in "- "]
    added = [t for k, t in changes if k in "+ "]

    # Already applied? Then the added lines are there exactly as we would write
    # them, which is what makes a second run a no-op instead of an error.
    if added and find_block(lines, added):
        return lines, "already"

    if removed:
        candidates = find_block(lines, removed)
        if lead:
            narrowed = [i for i in candidates if lines[max(0, i - len(lead)) : i] == lead]
            candidates = narrowed or candidates
        if trail:
            narrowed = [i for i in candidates if lines[i + len(removed) : i + len(removed) + len(trail)] == trail]
            candidates = narrowed or candidates
        if len(candidates) != 1:
            return None, f"its own lines are not in {where} exactly once ({len(candidates)} matches)"
        i = candidates[0]
        replacement = [t for k, t in changes if k != "-"]
        return lines[:i] + replacement + lines[i + len(removed) :], "applied"

    # Pure insertion: it belongs where the following context lines are, directly
    # after the preceding ones. Both are part of the anchor, so a repeated line
    # such as "Connections {" does not have to be guessed about.
    if not trail:
        return None, f"an insertion in {where} has no following context to anchor on"
    candidates = find_block(lines, trail)
    if lead:
        narrowed = [i for i in candidates if lines[max(0, i - len(lead)) : i] == lead]
        candidates = narrowed or candidates
    if len(candidates) != 1:
        return None, f"its insertion point in {where} is not unique ({len(candidates)} matches)"
    i = candidates[0]
    return lines[:i] + added + lines[i:], "applied"


def main() -> int:
    if not PATCH.is_file():
        die(f"{PATCH} is missing: it is the patch this script applies")

    files = parse_patch(PATCH.read_text(encoding="utf-8"))
    if not files:
        die(f"{PATCH} contains no file diffs")

    results: list[tuple[Path, list[str]]] = []
    for path, hunks in files:
        target = ROOT / path
        if not target.is_file():
            die(f"{path} is missing from this checkout; is it the right repository?")
        lines = target.read_text(encoding="utf-8").splitlines()
        for hunk in hunks:
            for group in split_groups(hunk["body"]):
                lines, what = apply_hunk(lines, group, path)
                if lines is None:
                    die(
                        f"cannot place a hunk of {path} {hunk['header']}: {what}.\n"
                        "  Upstream changed the code this patch edits, so it needs a human.\n"
                        f"  Look at {path}, then update local/text-size.patch by hand."
                    )
                print(f"  {path}: {what} ({hunk['header'].split('@@')[1].strip()})")
        results.append((target, lines))

    changed = False
    for target, lines in results:
        text = "\n".join(lines) + "\n"
        if text != target.read_text(encoding="utf-8"):
            target.write_text(text, encoding="utf-8")
            changed = True

    print("patch applied" if changed else "already applied, nothing to do")
    return 0


if __name__ == "__main__":
    sys.exit(main())
