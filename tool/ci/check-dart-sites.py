#!/usr/bin/env python3
"""Site consistency for the Dart engine's repetitive declarations, without a Dart SDK.

`sim/mesh_sim` cannot be compiled in this sandbox. Two checkers already stand in for part of
that: `check-dart-balance.py` for delimiters and `check-parity.py` for shared constants.
Neither sees the failure mode this engine's shape actually invites — a declaration that has
to be repeated at several sites, where missing one is a compile error on the first machine
that *can* build, and where the sites are far enough apart that the eye does not connect
them.

Five patterns, each with provenance in this repository:

1. `SimConfig` — a field needs a constructor parameter, and anything overridable through
   `copyWith` needs a parameter *and* a body assignment. A parameter with no body
   assignment compiles and silently keeps the old value, which is worse than not compiling.
2. `SimulationStats` — a field needs a constructor parameter, a declaration, a `toJson()`
   entry and an entry at the construction site in `_computeStats`. The `toJson` half is not
   hypothetical: commit `f18c5c6` added 32 missing entries, so the Dart CLI had been
   reporting statistics it never emitted.
3. `EventKind` — every enum value needs a `case` in `_handleEvent`. A switch over an enum
   that does not cover it is a Dart error, and CI runs `dart analyze`.
4. Qualified references — every `X.y` names a type that exists and, where `X` is an enum, a
   member that exists. Both were typed into this package for real during the week this check
   was written: `OgmiIntervalMode` for `OgmIntervalMode`, and a stub function referencing a
   `_Never` type. Each was caught by hand, which is luck rather than a process.
5. Import reachability — every type a file names is declared in that file or reachable from
   its own `import`/`export` lines, following a barrel one hop. Dart resolves names through
   those lines and nothing else, so this is the error a cross-file feature introduces
   silently, and every feature added that month was cross-file.

Structural walking is done on a copy of the file with every comment and string character
replaced by a space at the same offset, because doc comments in a parameter list contain
unbalanced parentheses and a naive walk drifts on them — which is how the first version of
this checker failed to find `copyWith` at all and then reported nothing about it. Extraction
regexes run on the real text at those same offsets.

What it does **not** check, each declined on a measurement rather than on taste:

* That a called *function* exists. 321 distinct call sites against a regex-collected
  declaration set leaves 13 names unresolved: six `package:test` matchers, the `catch` keyword,
  and six local helpers declared inside test bodies in forms the declaration regex cannot see.
  That is what separates it from patterns 4 and 5, whose undeclared surfaces measured five and
  zero. Dart's function *declaration* syntax — nested, closures bound to variables, `async`,
  getters, extensions — is varied enough that a regex declaration set is incomplete, and an
  incomplete declaration set produces false positives rather than misses.
* Argument counts or types at call sites, for the same reason plus Dart's optional,
  positional-optional and named parameters.

Six names to allowlist and six declaration forms to support is a parser, and a check that needs
one should not pretend otherwise.

This is not a Dart parser. It reads sites by line-anchored pattern inside slices it has located
by their declarations, so it is only as good as the repository's formatting, which `dart format`
enforces. Where it cannot be sure it says nothing rather than guessing: a check with false
positives is worse than no check.

    python3 tool/ci/check-dart-sites.py
    python3 tool/ci/check-dart-sites.py --self-test   # does it still fail when it should?
    python3 tool/ci/check-dart-sites.py --quiet       # only the verdict line
    python3 tool/ci/check-dart-sites.py --help        # the five patterns, and the two it declines
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
    """Members of `enum NAME { ... }`, walking to the *matching* brace.

    The first version of this matched to the first `}` at column zero. That is right for a
    multi-line enum and wrong for a one-line one — `enum ChannelAccess { free, halfDuplex, csma }`
    has no brace at column zero, so the scan ran on into the following declarations and reported
    their keywords as members. It was harmless while the only consumer was `EventKind`, which is
    multi-line, and it produced 265 false positives the moment a second check depended on it.
    """
    m = re.search(rf"^enum {re.escape(name)} \{{", mt, re.M)
    if not m:
        return []
    i = mt.find("{", m.start())
    if i < 0:
        return []
    depth = 0
    for k in range(i, len(mt)):
        if mt[k] == "{":
            depth += 1
        elif mt[k] == "}":
            depth -= 1
            if depth == 0:
                body = mt[i + 1 : k]
                return [
                    ident.group(1)
                    for ident in (re.match(r"\s*(\w+)", part) for part in body.split(","))
                    if ident
                ]
    return []


# PascalCase receivers whose static members come from the SDK rather than from this package.
# Measured, not guessed: scanning every `X.y` in `sim/mesh_sim` produced exactly these five
# undeclared receivers, from three `dart:` libraries. The list is short on purpose and the
# failure message tells a maintainer what to do when it grows, because the alternative — a
# permissive rule — is a check that cannot see the typo it was written for.
SDK_STATIC_TYPES = {
    "ByteData": "dart:typed_data",
    "Endian": "dart:typed_data",
    "Uint8List": "dart:typed_data",
    "Future": "dart:async",
    "JsonEncoder": "dart:convert",
}

DECLARATION_KEYWORDS = ("class", "enum", "extension", "mixin", "typedef")

# Provided by the language on every enum rather than declared in the source.
ENUM_BUILTIN_MEMBERS = ("values", "index")


def dart_sources(overrides: dict[pathlib.Path, str] | None = None) -> dict[pathlib.Path, str]:
    """Every Dart source in the package, with any in-memory mutations substituted.

    The self-test mutates one file at a time and must not write to the tree, so the checks take
    texts rather than paths. Declarations are collected package-wide either way, because a type
    declared in `types.dart` is referenced from `simulation.dart` and a check that only looked at
    one file would report every cross-file reference as undefined.
    """
    overrides = overrides or {}
    out: dict[pathlib.Path, str] = {}
    for path in sorted((ROOT / "sim" / "mesh_sim").rglob("*.dart")):
        out[path] = overrides.get(path, path.read_text(encoding="utf-8"))
    return out


# --- the checks ------------------------------------------------------------------


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


def check_references(sources: dict[pathlib.Path, str]) -> tuple[list[str], str]:
    """Every `X.y` in the package names a type that exists, and a member that exists.

    Two failure modes, both of which a compiler catches instantly and neither of which anything
    else in this repository can see — and both of which were typed into this package during the
    week the check was written: `OgmiIntervalMode` for `OgmIntervalMode`, and a stub function
    referencing a `_Never` type that did not exist. Each was found by hand, which is luck rather
    than a process.

    The scan runs on masked text, so a `Role.normal` inside a doc comment or a string is not a
    reference. Receivers are PascalCase only, which excludes `math.max` and `int.parse` — the
    import-prefix and lowercase-static cases that would otherwise need rules of their own.
    """
    declared: dict[str, str] = {}
    enums: dict[str, list[str]] = {}
    for path, text in sources.items():
        mt = mask(text)
        for kw in DECLARATION_KEYWORDS:
            for name in re.findall(rf"^{kw} (\w+)", mt, re.M):
                declared.setdefault(name, path.name)
        for name in re.findall(r"^enum (\w+) \{", mt, re.M):
            enums[name] = enum_values(mt, name)

    problems: list[str] = []
    refs = 0
    for path, text in sources.items():
        mt = mask(text)
        for n, line in enumerate(mt.split("\n"), 1):
            for receiver, member in re.findall(r"\b([A-Z]\w*)\.([a-z]\w*)", line):
                refs += 1
                if receiver in declared:
                    # `values` and `index` exist on every Dart enum by the language's own
                    # definition and are not declared in the source, so a check that required
                    # them to be would report one false positive per enum the package iterates.
                    if (
                        receiver in enums
                        and member not in enums[receiver]
                        and member not in ENUM_BUILTIN_MEMBERS
                    ):
                        problems.append(
                            f"{path.name}:{n} `{receiver}.{member}` — `{receiver}` has no such "
                            f"member (it has: {', '.join(enums[receiver])})"
                        )
                    continue
                if receiver in SDK_STATIC_TYPES:
                    continue
                problems.append(
                    f"{path.name}:{n} `{receiver}.{member}` — no type named `{receiver}` is "
                    f"declared anywhere in sim/mesh_sim. If it is an SDK type with static "
                    f"members, add it to SDK_STATIC_TYPES in check-dart-sites.py with the import "
                    f"that provides it; that list is five entries long and is meant to stay short."
                )
    return problems, f"{refs} qualified references, {len(declared)} declared types"


BARREL = "lib/mesh_sim.dart"


def _package_files() -> dict[str, str]:
    """Every Dart source in the package, keyed by its path relative to `sim/mesh_sim`."""
    root = ROOT / "sim" / "mesh_sim"
    return {
        str(p.relative_to(root)): p.read_text(encoding="utf-8")
        for p in sorted(root.rglob("*.dart"))
    }


def _resolve_import(from_rel: str, spec: str) -> str | None:
    """An import specifier as a package-relative path, or None for something external."""
    if spec.startswith("package:duman_mesh_sim/"):
        return "lib/" + spec.split("package:duman_mesh_sim/", 1)[1]
    if spec.startswith("dart:") or spec.startswith("package:"):
        return None
    return str(pathlib.Path(pathlib.Path(from_rel).parent, spec))


def check_imports(sources: dict[pathlib.Path, str] | None = None) -> tuple[list[str], str]:
    """Every type a file names is declared in that file or reachable from its imports.

    Dart resolves a library's names through its own `import` and `export` lines and nothing
    else, so using a type from `types.dart` inside `simulation.dart` without importing it is a
    compile error — and it is the error this repository is most exposed to, because every
    feature added this month put a new type in one file and used it from another:
    `RadioOccupancy`, `OgmIntervalMode`, `ScanIntervalMode`, `BlockScope`. On the TypeScript
    side `tsc` catches it in a second. Here nothing did.

    Two details this got wrong before it got them right, both worth keeping visible:

    * Import specifiers are parsed from the **raw** text, not the masked copy. A specifier is a
      string literal, and masking strings is what lets the reference check ignore prose — so
      reading imports from masked text finds none at all and reports every cross-file type as
      unreachable. Measured that way the surface looked like 193 problems; measured correctly it
      is zero, which is the difference between a check worth adding and one worth abandoning.
    * Reachability follows `export` one hop, because `lib/mesh_sim.dart` is a barrel: a test or
      a binary that imports the package gets every type behind it. Dart imports are not
      otherwise transitive, so exactly one hop is right and more would be wrong.
    """
    # Start from the real package and overlay any in-memory mutations, so the self-test can
    # break one file without writing to the tree. Reachability is a whole-package property:
    # a check that saw only the mutated file could not tell an import from a missing one.
    root = ROOT / "sim" / "mesh_sim"
    raw = _package_files()
    for path, text in (sources or {}).items():
        try:
            raw[str(path.relative_to(root))] = text
        except ValueError:
            continue

    owner: dict[str, set[str]] = {}
    for rel, text in raw.items():
        mt = mask(text)
        for kw in DECLARATION_KEYWORDS:
            for name in re.findall(rf"^{kw} (\w+)", mt, re.M):
                owner.setdefault(name, set()).add(rel)

    def exported(barrel: str) -> set[str]:
        out = set()
        for spec in re.findall(r"^export '([^']+)'", raw.get(barrel, ""), re.M):
            r = _resolve_import(barrel, spec)
            if r:
                out.add(r)
        return out

    problems: list[str] = []
    checked = 0
    for rel, text in raw.items():
        specs = re.findall(r"^import '([^']+)'", text, re.M) + re.findall(
            r"^export '([^']+)'", text, re.M
        )
        reach = {r for r in (_resolve_import(rel, s) for s in specs) if r}
        for d in list(reach):
            reach |= exported(d)
        for name in sorted(set(re.findall(r"\b([A-Z]\w*)\b", mask(text)))):
            if name not in owner or rel in owner[name] or (owner[name] & reach):
                continue
            checked += 1
            problems.append(
                f"{rel}: `{name}` is declared in {', '.join(sorted(owner[name]))} but this file "
                f"imports nothing that reaches it — a compile error, and the kind that a "
                f"cross-file feature introduces silently"
            )
    return problems, f"{len(owner)} declared types reachable-checked across {len(raw)} files"


def run(sim_text: str, events_text: str) -> tuple[list[str], list[str]]:
    sim_mt = mask(sim_text)
    events_mt = mask(events_text)
    problems: list[str] = []
    notes: list[str] = []
    for found, note in (
        check_sim_config(sim_text, sim_mt),
        check_sim_stats(sim_text, sim_mt),
        check_event_kinds(sim_text, sim_mt, events_text, events_mt),
        check_references(dart_sources({SIM: sim_text, EVENTS: events_text})),
        check_imports({SIM: sim_text, EVENTS: events_text}),
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
    # Both of these were typed into this package for real during the week this check was
    # written, and both were caught by hand rather than by anything automatic.
    (
        "a reference to an enum type that does not exist",
        lambda t: t.replace("OgmIntervalMode.fixed", "OgmiIntervalMode.fixed", 1),
        "no type named `OgmiIntervalMode`",
    ),
    (
        # Dart resolves names only through a file's own import and export lines, so dropping one
        # is a compile error — the error a cross-file feature introduces and nothing else here saw.
        "an import removed, so a type is named but not reachable",
        lambda t: t.replace("import 'types.dart';", "", 1),
        "imports nothing that reaches it",
    ),
    (
        "a reference to an enum member that does not exist",
        # Aimed at a use in code rather than the first occurrence in the file, which is inside a
        # doc comment — and a masked comment is not a reference, so mutating it proves nothing.
        lambda t: t.replace(
            "config.radioOccupancy == RadioOccupancy.airtime",
            "config.radioOccupancy == RadioOccupancy.airtim",
            1,
        ),
        "`RadioOccupancy` has no such member",
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
    # Prints the module docstring rather than a separate help text, because the docstring is
    # where the five patterns and the two declined checks are written down — and a checker whose
    # limits live only in its source is a checker whose limits nobody reads.
    if "--help" in argv or "-h" in argv:
        print(__doc__)
        return 0
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
