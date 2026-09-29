"""One-off repair for UTF-8 characters mangled by an earlier cp1252 round-trip.

Each entry replaces a run of mojibake with the character that was meant:

    U+00E2 U+2020 U+2019  ("a-dagger-quote")  ->  U+2192  right arrow
    U+00E2 U+20AC U+201D  ("a-euro-quote")     ->  U+2014  em dash

Run from the repository root:  python Scripts/fix_mojibake.py
"""

import sys
from pathlib import Path

REPLACEMENTS = [
    ("\u00e2\u2020\u2019", "\u2192"),  # a-dagger-quote -> ->
    ("\u00e2\u20ac\u201d", "\u2014"),  # a-euro-quote    -> --
]

# (relative path, expected count) -- the counts make the script fail loudly if a
# file is edited by hand before this runs again, rather than silently no-oping.
FILES = [
    ("Sources/iBiblioCore/Session/SessionStore.swift", 4),
    ("Sources/iBiblioCore/Upload/UploadService.swift", 2),
    ("Tests/iBiblioCoreTests/OIDCAuthProviderTests.swift", 1),
]


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    failures = []

    for relative, expected in FILES:
        path = root / relative
        text = path.read_text(encoding="utf-8")
        original = text

        for bad, good in REPLACEMENTS:
            text = text.replace(bad, good)

        replaced = sum(original.count(bad) for bad, _ in REPLACEMENTS)
        if replaced != expected:
            failures.append(f"{relative}: replaced {replaced}, expected {expected}")
            continue

        if text == original:
            continue

        path.write_text(text, encoding="utf-8", newline="")
        print(f"fixed {replaced} in {relative}")

    for failure in failures:
        print("FAIL", failure)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
