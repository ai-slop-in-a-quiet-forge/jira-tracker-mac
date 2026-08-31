#!/usr/bin/env python3
"""Checks that relative links between markdown files actually resolve.

Broken internal links are the most common rot in a docs tree, and the cheapest thing to catch
automatically. External URLs are deliberately not checked — that turns CI into a flaky network
test that fails when someone else's site is down.

    python3 Scripts/check-doc-links.py
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Matches [text](target). Captures the target, minus any #anchor.
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")

SKIP_DIRS = {".git", ".build", "dist", "build", ".swiftpm", "DerivedData"}


def is_external(target: str) -> bool:
    return "://" in target or target.startswith(("mailto:", "#"))


def main() -> int:
    problems: list[str] = []
    checked = 0

    for path in sorted(ROOT.rglob("*.md")):
        if any(part in SKIP_DIRS for part in path.relative_to(ROOT).parts):
            continue

        for match in LINK.finditer(path.read_text(encoding="utf-8")):
            target = match.group(1)
            if is_external(target):
                continue

            # Strip an anchor; we verify the file exists, not the heading.
            file_part = target.split("#", 1)[0]
            if not file_part:
                continue

            resolved = (path.parent / file_part).resolve()
            checked += 1
            if not resolved.exists():
                relative = path.relative_to(ROOT)
                problems.append(f"{relative}: broken link to {target}")

    for problem in problems:
        print(f"::error::{problem}" if "--ci" in sys.argv else f"  BROKEN  {problem}")

    if problems:
        print(f"\n{len(problems)} broken link(s) out of {checked} checked")
        return 1

    print(f"all {checked} internal doc links resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
