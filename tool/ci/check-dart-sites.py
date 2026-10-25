#!/usr/bin/env python3
"""Site consistency for the Dart engine's repetitive declarations, without a Dart SDK.

`sim/mesh_sim` cannot be compiled in this sandbox. Two checkers already stand in for part of
that: `check-dart-balance.py` for delimiters and `check-parity.py` for shared constants.
Neither sees the failure mode this engine's shape actually invites — a declaration that has
to be repeated at several sites, where missing one is a compile error on the first machine
that *can* build, and where the sites are far enough apart that the eye does not connect
them.

Three patterns, each with provenance in this repository:

1. `SimConfig` — a field needs a constructor parameter, and anything overridable through
   `copyWith` needs a parameter *and* a body assignment. A parameter with no body
   assignment compiles and silently keeps the old value, which is worse than not compiling.
2. `SimulationStats` — a field needs a constructor parameter, a declaration, a `toJson()`
   entry and an entry at the construction site in `_computeStats`. The `toJson` half is not
   hypothetical: commit `f18c5c6` added 32 missing entries, so the Dart CLI had been
   reporting statistics it never emitted.
3. `EventKind` — every enum value needs a `case` in `_handleEvent`. A switch over an enum
   that does not cover it is a Dart error, and CI runs `dart analyze`.

Structural walking is done on a copy of the file with every comment and string character
replaced by a space at the same offset, because doc comments in a parameter list contain
unbalanced parentheses and a naive walk drifts on them — which is how the first version of
this checker failed to find `copyWith` at all and then reported nothing about it. Extraction
regexes run on the real text at those same offsets.

This is not a Dart parser. It reads four sites by line-anchored pattern inside slices it has
located by their declarations, so it is only as good as the repository's formatting, which
`dart format` enforces. Where it cannot be sure it says nothing rather than guessing: a check
with false positives is worse than no check.

    python3 tool/ci/check-dart-sites.py
    python3 tool/ci/check-dart-sites.py --self-test   # does it still fail when it should?
    python3 tool/ci/check-dart-sites.py --quiet       # only the verdict line
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SIM = ROOT / "sim" / "mesh_sim" / "lib" / "src" / "simulation.dart"
EVENTS = ROOT / "sim" / "mesh_sim" / "lib" / "src" / "events.dart"


# --- masking -----------------------------------------------------------------


def mask(text: str) -> str:
    """Replace every comment and string character with a space, keeping offsets.

    Newlines survive so line-anchored regexes and line counting still work on the mask.
    Interpolation inside a string is masked along with the string: a `${}` there cannot
    fool the brace walker, and nothing structural is being looked for inside a literal.
    """
    out = list(text)
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        two = text[i : i + 2]
        three = text[i : i + 3]
        if two == "//":
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        if two == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if text[k] != "\n":
                    out[k] = " "
            i = j
            continue
        if three in ("'''", '"""'):
            quote = three
            j = text.find(quote, i + 3)
            j = n if j < 0 else j + 3
            for k in range(i, j):
                if text[k] != "\n":
                    out[k] = " "
            i = j
            continue
        if c in "'\"":
            # A raw string (`r'...'`) has no escapes, so the backslash test below simply
            # never fires for one; treating both the same way is correct either way.
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == c:
                    j += 1
                    break
                if text[j] == "\n":  # unterminated; let the balance checker complain
                    break
                j += 1
            for k in range(i, min(j, n)):
                if text[k] != "\n":
                    out[k] = " "
            i = max(j, i + 1)
            continue
        i += 1
    return "".join(out)


# --- locating slices, by offset ---------------------------------------------


def class_span(mt: str, name: str) -> tuple[int, int] | None:
    """Offsets of a top-level class body, from its `{` to the `}` at column zero."""
    m = re.search(rf"^class {re.escape(name)} \{{", mt, re.M)
    if not m:
        return None
    end = re.search(r"^\}", mt[m.end() :], re.M)
    if not end:
        return None
    return m.end(), m.end() + end.start()


def member_span(text: str, mt: str, lo: int, hi: int, signature: str) -> tuple[int, int] | None:
    """Offsets of one class member inside `[lo, hi)`, matched by its signature line.

    Three shapes have to be handled and the first two versions of this handled one each. A
    `const SimConfig({...});` constructor has no body at all — walking braces from the
    signature runs on into the next member — and a `copyWith({...}) { ... }` opens a brace
    for its *parameter list* before the one for its body, so a naive walk returns the
    parameters and never sees a single assignment. So: find the parameter list, walk to its
    closing paren on the masked text, then decide what follows.
    """
    m = re.search(rf"^  (?:const )?{re.escape(signature)}", mt[lo:hi], re.M)
    if not m:
        return None
    start = lo + m.start()
    i = mt.find("(", start)
    if i < 0 or i > hi:
        return None
    depth = 0
    closed = -1
    while i < hi:
        if mt[i] == "(":
            depth += 1
        elif mt[i] == ")":
            depth -= 1
            if depth == 0:
                closed = i
                break
        i += 1
    if closed < 0:
        return None
    nxt = mt[closed + 1 : hi].lstrip()[:1]
    if nxt == ";":
        # A bodyless const constructor: the parameters are the whole of it.
        return start, closed + 1
    if nxt == "=":
        # An expression-bodied member — `copyWith({...}) => SimConfig(...);` — which is the
        # third shape and the one the first two versions of this both missed. It ends at the
        # first `;` reached at bracket depth zero, so the nested `SimConfig(...)` argument
        # list, which is where every assignment this checker wants to see actually lives,
        # stays inside the slice.
        depth = 0
        k = closed + 1
        while k < hi:
            c = mt[k]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif c == ";" and depth == 0:
                return start, k + 1
            k += 1
        return None
    j = mt.find("{", closed)
    if j < 0 or j > hi:
        return None
    depth = 0
    for k in range(j, hi):
        if mt[k] == "{":
            depth += 1
        elif mt[k] == "}":
            depth -= 1
            if depth == 0:
                return start, k + 1
    return None


def enum_values(mt: str, name: str) -> list[str]:
    m = re.search(rf"^enum {re.escape(name)} \{{(.*?)^\}}", mt, re.M | re.S)
    if not m:
        return []
    out = []
    for raw in m.group(1).split("\n"):
        ident = re.match(r"\s*(\w+)", raw)
        if ident:
            out.append(ident.group(1))
    return out


# --- the three checks --------------------------------------------------------


def check_sim_config(text: str, mt: str) -> tuple[list[str], str]:
    """Every `final` field has a ctor param; copyWith params and body agree."""
    span = class_span(mt, "SimConfig")
    if span is None:
        return ["SimConfig class not found"], ""
    lo, hi = span
    body = text[lo:hi]
    problems: list[str] = []

    fields = re.findall(r"^  final [\w<>?, .]+ (\w+);", body, re.M)
    ctor = member_span(text, mt, lo, hi, "SimConfig({")
    if ctor is None:
        return ["SimConfig constructor not found"], ""
    ctor_params = set(re.findall(r"this\.(\w+)", text[ctor[0] : ctor[1]]))
    for f in fields:
        if f not in ctor_params:
            problems.append(
                f"SimConfig.{f}: declared `final` but has no constructor parameter — Dart "
                f"will not compile a final field that is never assigned"
            )

    copy = member_span(text, mt, lo, hi, "SimConfig copyWith({")
    if copy is None:
        return problems, "SimConfig has no copyWith"
    region = text[copy[0] : copy[1]]
    params = re.findall(r"^    [\w<>?, .]+\? (\w+),", region, re.M)
    # `\s*` after the colon, not a single space: `dart format` wraps an assignment whose
    # name is long enough, so `batteryDrainMultiplier:` and its value end up on different
    # lines. Requiring them together reported four real fields as broken, and a check that
    # cries wolf on formatted code gets ignored the first time it cries wolf for real.
    assigned = re.findall(r"^        (\w+):\s*\1 \?\? this\.\1,", region, re.M)
    for p in params:
        if p not in assigned:
            problems.append(
                f"SimConfig.copyWith({p}): parameter is never used in the body, so passing "
                f"it silently keeps the old value"
            )
    for a in assigned:
        if a not in params:
            problems.append(
                f"SimConfig.copyWith body assigns `{a}` but there is no parameter for it — "
                f"undefined name"
            )
    missing = [f for f in fields if f not in params]
    note = (
        f"{len(fields)} SimConfig fields, {len(params)} overridable through copyWith"
        if not missing
        else f"{len(fields)} SimConfig fields, {len(params)} overridable through copyWith, "
        f"{len(missing)} deliberately not ({', '.join(missing[:4])}"
        f"{'…' if len(missing) > 4 else ''})"
    )
    return problems, note


def check_sim_stats(text: str, mt: str) -> tuple[list[str], str]:
    """Every stats field is declared, required, serialised and constructed."""
    span = class_span(mt, "SimulationStats")
    if span is None:
        return ["SimulationStats class not found"], ""
    lo, hi = span
    body = text[lo:hi]
    problems: list[str] = []

    required = set(re.findall(r"^    required this\.(\w+),", body, re.M))
    declared = re.findall(r"^  final [\w<>?, .]+ (\w+);", body, re.M)
    to_json = member_span(text, mt, lo, hi, "Map<String, Object?> toJson()")
    if to_json is None:
        problems.append("SimulationStats.toJson not found")
        emitted: set[str] = set()
    else:
        emitted = set(re.findall(r"'(\w+)':", text[to_json[0] : to_json[1]]))

    for f in declared:
        if f not in required:
            problems.append(
                f"SimulationStats.{f}: declared but not a `required this.` constructor "
                f"parameter"
            )
        if f not in emitted:
            problems.append(
                f"SimulationStats.{f}: missing from toJson(), so the Dart CLI and every "
                f"--json consumer silently never see it"
            )
    for r in sorted(required):
        if r not in declared:
            problems.append(
                f"SimulationStats.{r}: `required this.{r}` but no field declaration"
            )

    m = re.search(r"return SimulationStats\((.*?)\n    \);", mt, re.S)
    if not m:
        problems.append(
            "the `return SimulationStats(...)` construction site in _computeStats was not found"
        )
        return problems, f"{len(declared)} stats fields"
    constructed = set(re.findall(r"\n      (\w+):", m.group(1)))
    for f in declared:
        if f not in constructed:
            problems.append(
                f"SimulationStats.{f}: not passed at the construction site in _computeStats "
                f"— a required parameter with no argument"
            )
    return problems, f"{len(declared)} stats fields checked at all four sites"


def check_event_kinds(sim_text: str, sim_mt: str, events_text: str, events_mt: str) -> tuple[list[str], str]:
    """Every EventKind value is handled in _handleEvent."""
    values = enum_values(events_mt, "EventKind")
    if not values:
        return ["EventKind enum not found in events.dart"], ""
    m = re.search(r"void _handleEvent\(EventKind kind.*?\n  \}", sim_mt, re.S)
    if not m:
        return ["_handleEvent was not found in simulation.dart"], ""
    cases = set(re.findall(r"case EventKind\.(\w+):", sim_text[m.start() : m.end()]))
    problems = [
        f"EventKind.{v}: no `case EventKind.{v}:` in _handleEvent — a switch over an enum "
        f"that does not cover it is a Dart error, and CI runs `dart analyze`"
        for v in values
        if v not in cases
    ]
    problems += [
        f"_handleEvent has `case EventKind.{e}:` but no such enum value"
        for e in sorted(cases - set(values))
    ]
    return problems, f"{len(values)} EventKind values, {len(cases)} cases"


def run(sim_text: str, events_text: str) -> tuple[list[str], list[str]]:
    sim_mt = mask(sim_text)
    events_mt = mask(events_text)
    problems: list[str] = []
    notes: list[str] = []
    for found, note in (
        check_sim_config(sim_text, sim_mt),
        check_sim_stats(sim_text, sim_mt),
        check_event_kinds(sim_text, sim_mt, events_text, events_mt),
    ):
        problems += found
        if note:
            notes.append(note)
    return problems, notes


# --- self-test ---------------------------------------------------------------

# Each fault is (name, how to break simulation.dart, substring the report must contain).
FAULTS: list[tuple[str, object, str]] = [
    (
        "a SimConfig field with no constructor parameter",
        lambda t: t.replace("    this.ogmAliasBytes = 32,", "", 1),
        "SimConfig.ogmAliasBytes",
    ),
    (
        "a copyWith parameter the body never uses",
        lambda t: t.replace(
            "        ogmAliasBytes: ogmAliasBytes ?? this.ogmAliasBytes,", "", 1
        ),
        "copyWith(ogmAliasBytes)",
    ),
    (
        "a copyWith body assignment with no parameter",
        lambda t: t.replace("    int? ogmAliasBytes,", "", 1),
        "assigns `ogmAliasBytes`",
    ),
    (
        "a stats field missing from toJson",
        lambda t: t.replace("        'coverTx': coverTx,", "", 1),
        "SimulationStats.coverTx: missing from toJson",
    ),
    (
        "a stats field missing at the construction site",
        lambda t: t.replace("      coverTx: _coverTx,", "", 1),
        "SimulationStats.coverTx: not passed at the construction site",
    ),
    (
        "a stats field declared without `required this.`",
        lambda t: t.replace("    required this.coverTx,", "", 1),
        "SimulationStats.coverTx: declared but not a `required this.`",
    ),
    (
        "an EventKind value with no case in _handleEvent",
        lambda t: t.replace("      case EventKind.cover:", "", 1),
        "EventKind.cover: no `case EventKind.cover:`",
    ),
    (
        "a _handleEvent case for an enum value that does not exist",
        lambda t: t.replace(
            "      case EventKind.cover:", "      case EventKind.coverX:", 1
        ),
        "no such enum value",
    ),
]


def self_test() -> int:
    """Inject each fault and require the checker to name it.

    A check that always passes is indistinguishable from a broken one, so every rule gets a
    case that must fail and a substring the failure must contain. Nothing is written: the
    tree is only ever mutated in memory.
    """
    sim_text = SIM.read_text(encoding="utf-8")
    events_text = EVENTS.read_text(encoding="utf-8")

    total = len(FAULTS) + 1
    failed = 0
    clean, _ = run(sim_text, events_text)
    if clean:
        print(f"  FAIL  the real tree is not clean: {clean[0]}")
        failed += 1
    else:
        print("  ok    the real tree is clean")

    for name, fault, expect in FAULTS:
        mutated = fault(sim_text)  # type: ignore[operator]
        if mutated == sim_text:
            print(f"  FAIL  {name}: the fault did not apply, so the case proves nothing")
            failed += 1
            continue
        problems, _ = run(mutated, events_text)
        if not problems:
            print(f"  FAIL  {name}: reported nothing")
            failed += 1
        elif not any(expect in p for p in problems):
            print(
                f"  FAIL  {name}: reported {len(problems)} problem(s), none naming {expect!r}"
            )
            failed += 1
        else:
            print(f"  ok    {name}")

    print(f"check-dart-sites --self-test: {total - failed}/{total} cases behaved as expected")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return self_test()
    quiet = "--quiet" in argv
    if not SIM.exists() or not EVENTS.exists():
        print(f"check-dart-sites: cannot find {SIM} or {EVENTS}")
        return 1
    problems, notes = run(
        SIM.read_text(encoding="utf-8"), EVENTS.read_text(encoding="utf-8")
    )
    if not quiet:
        for p in problems:
            print(f"  FAIL  {p}")
        for n in notes:
            print(f"  note  {n}")
    if problems:
        print(f"check-dart-sites: {len(problems)} site(s) inconsistent")
        return 1
    print(f"check-dart-sites: all declaration sites consistent ({'; '.join(notes)})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
