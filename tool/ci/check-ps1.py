#!/usr/bin/env python3
"""Static sanity check for PowerShell scripts, for machines that cannot run pwsh.

Why this exists
---------------
The Windows entry point (make.ps1) cannot be executed on a Linux CI runner or in a
sandbox without PowerShell, and shipping a script nobody has run is how a repository
ends up with a broken front door. This is not a parser and does not pretend to be one:
it catches the two failure classes that account for almost all hand-written PowerShell
bugs found late, and it does so with no dependencies.

  1. Unbalanced delimiters. A missing brace in PowerShell often does not fail at the
     point of the error; it swallows the rest of the file and reports something
     unrelated, or fails only when a particular branch is taken.

  2. PowerShell 7-only syntax in a script meant for Windows PowerShell 5.1, which is
     what Windows 11 actually ships. `??`, `?.`, the `? :` ternary, `&&` and `||` as
     pipeline chain operators, and `$PSStyle` all parse on pwsh 7 and all fail on 5.1
     with a message that does not say "your PowerShell is too old".

Both checks run on *code only*: strings and comments are stripped by a character walk
first, because a regex over raw source mis-pairs apostrophes in prose ("the
repository's intent") with real string delimiters and reports braces that are not
there. That false positive is the reason this is a walk and not a one-liner.

Usage
-----
    python3 tool/ci/check-ps1.py make.ps1 [more.ps1 ...]
    python3 tool/ci/check-ps1.py --ps7-ok make.ps1     # allow PS7-only syntax

Exit codes: 0 clean · 1 problems found · 64 bad usage.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

PS7_PATTERNS = (
    (r"\?\?", "null-coalescing operator ??"),
    (r"\?\.", "null-conditional operator ?."),
    (r"(?<!['\"\w])\?(?!['\"\w])", "ternary operator ? :"),
    (r"&&", "pipeline chain operator &&"),
    (r"\|\|", "pipeline chain operator ||"),
    (r"\$PSStyle", "$PSStyle (PS 7.2+)"),
    (r"\bGet-Error\b", "Get-Error cmdlet"),
)

PAIRS = (("{", "}"), ("(", ")"), ("[", "]"))


def strip_to_code(source: str) -> tuple[str, int]:
    """Return (code_with_strings_blanketed, block_comment_count).

    Strings become a fixed two-character token so delimiters inside them cannot be
    counted, and comments are dropped. Line structure is preserved so reported line
    numbers still match the original file.
    """
    body, blocks = re.subn(r"<#.*?#>", lambda m: "\n" * m.group(0).count("\n"), source, flags=re.S)

    out: list[str] = []
    state = "code"  # code | single | double | linecomment
    i, n = 0, len(body)

    while i < n:
        ch = body[i]
        nxt = body[i + 1] if i + 1 < n else ""

        if state == "code":
            if ch == "'":
                state, i = "single", i + 1
                out.append("''")
                continue
            if ch == '"':
                state, i = "double", i + 1
                out.append('""')
                continue
            if ch == "#":
                state, i = "linecomment", i + 1
                out.append("\n" if nxt == "\n" else "")
                continue
            out.append(ch)
            i += 1
            continue

        if state == "single":
            if ch == "'" and nxt == "'":  # '' is an escaped quote inside a literal
                i += 2
                continue
            if ch == "'":
                state = "code"
            elif ch == "\n":
                out.append("\n")  # unterminated literal: keep line numbering honest
            i += 1
            continue

        if state == "double":
            if ch == "`":  # backtick escape, including `" and `n
                i += 2
                continue
            if ch == '"':
                state = "code"
            elif ch == "\n":
                out.append("\n")
            i += 1
            continue

        if state == "linecomment":
            if ch == "\n":
                state = "code"
                out.append("\n")
            i += 1
            continue

    return "".join(out), blocks


def check(path: Path, allow_ps7: bool) -> list[str]:
    problems: list[str] = []
    try:
        source = path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"cannot read: {exc}"]

    code, _ = strip_to_code(source)

    for opener, closer in PAIRS:
        n_open, n_close = code.count(opener), code.count(closer)
        if n_open != n_close:
            problems.append(
                f"unbalanced {opener}{closer}: {n_open} open vs {n_close} close"
            )

    if not allow_ps7:
        for lineno, line in enumerate(code.split("\n"), 1):
            for pattern, name in PS7_PATTERNS:
                if re.search(pattern, line):
                    problems.append(
                        f"line {lineno}: {name} — fails on Windows PowerShell 5.1 "
                        f"(use --ps7-ok if this script is pwsh-only)"
                    )

    if source.count("\ufeff"):
        problems.append("file contains a byte-order mark; PowerShell tolerates it but git diffs do not")

    return problems


def main(argv: list[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    allow_ps7 = "--ps7-ok" in argv

    if not args:
        print(__doc__.strip().splitlines()[-1])
        return 64

    failed = False
    for arg in args:
        path = Path(arg)
        if not path.is_file():
            print(f"error: {arg} is not a file")
            failed = True
            continue
        problems = check(path, allow_ps7)
        if problems:
            failed = True
            print(f"FAIL  {path}")
            for p in problems:
                print(f"        {p}")
        else:
            print(f"ok    {path}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
