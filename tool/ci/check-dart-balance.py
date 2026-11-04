#!/usr/bin/env python3
"""Delimiter balance for Dart sources, for the case where no Dart SDK is available.

`sim/mesh_sim` is the authoritative engine and this sandbox has no Dart SDK, so
Dart edits cannot be compiled here. That is not a reason to commit unbalanced
braces: a state machine that strips comments and string literals first catches the
class of mistake that is invisible to the eye (a brace inside a triple-quoted
block, a `${}` interpolation containing a nested string) and that would otherwise
surface as a hundred unrelated analyzer errors on the first machine that *can*
build.

This is not a Dart parser and does not claim to be. It answers one question: does
every delimiter opened outside a comment or a string literal get closed, in order,
by the end of the file? Exit 0 if yes, 1 with the offending position if no.

    python3 tool/ci/check-dart-balance.py [FILE ...]
    python3 tool/ci/check-dart-balance.py              # every .dart file in the repo
    python3 tool/ci/check-dart-balance.py --self-test  # does the checker still work?
"""
from __future__ import annotations

import pathlib
import sys

OPENERS = {"(": ")", "[": "]", "{": "}"}
CLOSERS = {")": "(", "]": "[", "}": "{"}

# Interpolation inside a Dart string: `$name` needs no tracking, `${expr}` opens a
# brace that must be matched *inside* the string, and the expression may itself
# contain a string. The stack therefore carries a mode, so a `}` knows whether it
# closes code or ends an interpolation.
CODE = "code"
STRING = "string"
INTERP = "interp"

# Stack frame: (mode, opener char, line, col, string delimiter, is-triple, is-raw).
Frame = tuple[str, str, int, int, str, bool, bool]


def is_raw_prefix(text: str, i: int) -> bool:
    """True when the quote at `i` is preceded by a Dart `r` string prefix.

    The character before the `r` must not be part of an identifier, or `var x = 1;`
    followed by `'...'` would... not match anyway, but `floor'x'` would. Cheap to
    check and it removes the one way this scanner can invent a false positive.
    """
    if i == 0 or text[i - 1] != "r":
        return False
    if i >= 2 and (text[i - 2].isalnum() or text[i - 2] in "_$"):
        return False
    return True


def scan(text: str, path: str) -> str | None:
    """Return an error message, or None when the file balances."""
    # The string delimiter lives *in the frame*, not in a variable beside the
    # stack. The first version of this checker kept it outside and reported
    # `mesh_sim.dart`'s usage text as an unterminated string: the interpolation
    # `${scenarioNames().join(' | ')}` nests a single-quoted string inside a
    # triple-quoted block, and closing the inner one left the outer one being
    # tracked with the wrong delimiter. Nested state belongs on the stack.
    stack: list[Frame] = []
    i = 0
    line = 1
    col = 1
    n = len(text)

    def advance(count: int = 1) -> None:
        nonlocal i, line, col
        for _ in range(count):
            if i < n and text[i] == "\n":
                line += 1
                col = 1
            else:
                col += 1
            i += 1

    while i < n:
        ch = text[i]
        top: Frame | None = stack[-1] if stack else None
        mode = top[0] if top else CODE
        quote = top[4] if top else ""
        triple = top[5] if top else False
        raw = top[6] if top else False

        if mode == CODE:
            if ch == "/" and i + 1 < n and text[i + 1] == "/":
                while i < n and text[i] != "\n":
                    advance()
                continue
            if ch == "/" and i + 1 < n and text[i + 1] == "*":
                advance(2)
                while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                    advance()
                advance(2)
                continue
            if ch in ("'", '"'):
                is_triple = text[i : i + 3] == ch * 3
                delim = ch * 3 if is_triple else ch
                stack.append((STRING, ch, line, col, delim, is_triple, is_raw_prefix(text, i)))
                advance(len(delim))
                continue
            if ch in OPENERS:
                stack.append((CODE, ch, line, col, "", False, False))
                advance()
                continue
            if ch in CLOSERS:
                if not stack:
                    return f"{path}:{line}:{col}: unmatched closing '{ch}'"
                frame = stack.pop()
                open_mode, open_ch, open_line, open_col = frame[0], frame[1], frame[2], frame[3]
                if open_mode != CODE:
                    return (
                        f"{path}:{line}:{col}: '{ch}' closed a {open_mode} "
                        f"opened at {open_line}:{open_col}"
                    )
                if OPENERS[open_ch] != ch:
                    return (
                        f"{path}:{line}:{col}: '{ch}' does not match '{open_ch}' "
                        f"opened at {open_line}:{open_col}"
                    )
                advance()
                continue
            advance()
            continue

        if mode == STRING:
            # A raw string (r'...') has no escape processing at all: `\` is a
            # literal backslash and the string ends at the first quote. Treating
            # `\'` as an escape there would run the scanner past the real
            # terminator and report an unterminated string that is not one.
            if ch == "\\" and not raw:
                advance(2)
                continue
            if text.startswith(quote, i):
                stack.pop()
                advance(len(quote))
                continue
            if not triple and ch == "\n":
                return (
                    f"{path}:{line}:{col}: unterminated string opened at "
                    f"{top[2]}:{top[3]}"
                )
            # Raw strings do not interpolate either, so `${` inside one is text.
            if ch == "$" and not raw and i + 1 < n and text[i + 1] == "{":
                stack.append((INTERP, "{", line, col, "", False, False))
                advance(2)
                continue
            advance()
            continue

        # INTERP: ordinary code, except that its own closing brace ends the
        # interpolation instead of popping a code brace.
        if ch in ("'", '"'):
            is_triple = text[i : i + 3] == ch * 3
            delim = ch * 3 if is_triple else ch
            stack.append((STRING, ch, line, col, delim, is_triple, is_raw_prefix(text, i)))
            advance(len(delim))
            continue
        if ch in OPENERS:
            stack.append((CODE, ch, line, col, "", False, False))
            advance()
            continue
        if ch == "}":
            stack.pop()
            advance()
            continue
        if ch in CLOSERS:
            return f"{path}:{line}:{col}: '{ch}' inside an interpolation closes nothing"
        advance()
        continue

    if stack:
        mode, ch, open_line, open_col = stack[-1][0], stack[-1][1], stack[-1][2], stack[-1][3]
        return f"{path}:{line}:{col}: unclosed {mode} '{ch}' opened at {open_line}:{open_col}"
    return None


# --- self-test ---------------------------------------------------------------
#
# A balance checker that reports "all balanced" is indistinguishable from one that
# never looks, so it carries its own faults. The negative cases matter as much as
# the positive ones: the way this class of checker fails in practice is by alarming
# on a delimiter that is inside a string or a comment, and a false alarm on a
# 12 000-line Dart engine is how a check gets deleted.
TQ = "'" * 3  # a Dart triple-single-quote, spelled so it cannot end this list

SELFTEST_CASES: list[tuple[str, str, str | None]] = [
    ("balanced function", "int f(int x) {\n  return x + 1;\n}\n", None),
    ("balanced list literal", "final xs = <int>[1, 2, 3];\n", None),
    ("brace inside a string is not a brace", "final s = 'a { b';\n", None),
    ("parens inside a double-quoted string", 'final s = ") ) )";\n', None),
    ("delimiters inside a line comment", "// } ) ]\nint f() => 1;\n", None),
    ("delimiters inside a block comment", "/* { [ ( */\nint f() => 1;\n", None),
    (
        "nested interpolation in a triple-quoted string",
        "void u() {\n  print(" + TQ + "\n  ${names().join(' | ')}\n  " + TQ + ");\n}\n",
        None,
    ),
    (
        "interpolation holding a nested string that holds a brace",
        "void u() {\n  print('x ${m['{']} y');\n}\n",
        None,
    ),
    ("escaped quote inside a string", "final s = 'it\\'s';\n", None),
    ("raw string keeps its backslashes", "final s = r'C:\\temp\\{x}';\n", None),
    ("raw string does not interpolate", "final s = r'${notAnInterpolation(}'\n", None),
    ("a double backslash in an ordinary string is one escape",
     "final s = r'a' + '\\\\';\n", None),
    ("unclosed function brace", "int f(int x) {\n  return x;\n", "unclosed code"),
    ("unmatched closing brace", "int f() => 1;\n}\n", "unmatched closing"),
    ("mismatched delimiter", "int f() {\n  return (1;\n}\n", "does not match"),
    ("single-quoted string crossing a newline", "final s = 'abc\n  ;\n", "unterminated string"),
    ("triple-quoted string never closed", "void u() {\n  print(" + TQ + "\nabc\n}\n", "unclosed"),
    # A `'` inside an unterminated interpolation starts a nested string, so the
    # report names the innermost thing that never closed. Naming the right frame is
    # the point: "unclosed" alone would send a reader to the wrong line.
    ("a quote inside a broken interpolation is the innermost unclosed frame",
     "void u() {\n  print('a ${b + 1');\n}\n", "unterminated string"),
    ("interpolation never closed",
     "void u() {\n  print(" + TQ + "a ${b + 1\n", "unclosed interp"),
]


def selftest() -> int:
    failed = 0
    for name, source, expected in SELFTEST_CASES:
        error = scan(source, "<selftest>")
        if expected is None:
            if error is not None:
                print(f"  FAIL {name}: reported a clean snippet: {error}")
                failed += 1
            else:
                print(f"  ok   {name}")
            continue
        if error is None:
            print(f"  FAIL {name}: expected /{expected}/, got no error")
            failed += 1
        elif expected.lower() not in error.lower():
            print(f"  FAIL {name}: expected /{expected}/, got: {error}")
            failed += 1
        else:
            print(f"  ok   {name} -> {error.split(': ', 1)[-1]}")
    total = len(SELFTEST_CASES)
    print(f"check-dart-balance --self-test: {total - failed}/{total} cases behaved as expected")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return selftest()
    root = pathlib.Path(__file__).resolve().parent.parent.parent
    paths = [a for a in argv[1:] if not a.startswith("--")]
    files = [pathlib.Path(a) for a in paths] if paths else sorted(
        p for p in root.rglob("*.dart") if ".dart_tool" not in p.parts
    )
    bad = 0
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            print(f"{path}: cannot read ({exc})")
            bad += 1
            continue
        error = scan(text, str(path))
        if error:
            print(error)
            bad += 1
    print(f"check-dart-balance: {len(files) - bad}/{len(files)} files balanced")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
