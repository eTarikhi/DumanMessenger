#!/usr/bin/env python3
"""Do the two engines agree on the numbers they were both given?

`src/` (TypeScript, the visual reference) and `sim/mesh_sim/` (Dart, the
authoritative engine) are a cross-language contract: same protocol constants, same
draw order, same golden vectors. Two mechanisms police it today and both need a
toolchain this repository does not currently have anywhere in its pipeline:

  * `make golden` regenerates the vectors from the TypeScript engine and
    compares them to the committed file, so a changed constant on that side shows
    up as drift. Needs npm.
  * `dart test` runs `golden_test.dart`, which compares the Dart engine's fields
    against the same vectors. Needs a Dart SDK — absent here, and unreachable,
    because `storage.googleapis.com` is not on this sandbox's allow list.

So a constant changed in one engine only is invisible until somebody's Windows
machine runs Dart. This closes that gap with no toolchain at all: it reads both
sources, pairs up the constants the two engines share by name, and requires the
values to agree.

What it does **not** do is require the two inventories to match. They are not
supposed to: `src/types.ts` exports `GROUP_ADDRESS` where Dart has
`broadcastAddress` alongside it, Dart's `transport.dart` has no TypeScript
counterpart file at all, and the React visualiser has helpers the engine never
needed. A check that demanded symmetry would need an exception list long enough to
hide the thing it was for. Only names that appear on **both** sides are compared,
and the counts of one-sided names are reported rather than failed.

    python3 tool/ci/check-parity.py              # compare the two engines
    python3 tool/ci/check-parity.py --self-test  # does this checker still work?
    python3 tool/ci/check-parity.py --json PATH  # machine-readable result
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Dict, List, NamedTuple, Optional, Tuple

TS_GLOB = "src/*.ts"
DART_GLOB = "sim/mesh_sim/lib/src/*.dart"

# Constants the two engines named differently. Kept as an explicit table rather
# than inferred, because inferring synonyms is how a parity check starts passing
# vacuously — and if this list grows, that is a smell worth seeing rather than a
# thing to hide behind fuzzy matching.
#
#   MPR_WAIT_MS (src/routing.ts)  vs  mprWaitDefaultMs (lib/src/routing.dart)
#   BROADCAST_PER_MINUTE_CAP      vs  broadcastPerMinuteCapDefault
#   RELAY_PER_SOURCE_PER_MINUTE_CAP vs relayPerSourcePerMinuteCapDefault
#
# Dart needs the word "Default" because those are also SimConfig field names, and a
# constructor default of `this.x = x` would be self-referential. TypeScript has no
# collision, because its constants are SCREAMING_CASE and its config fields are not.
# Same values either way, which is the only thing this check cares about.
ALIASES: Dict[str, str] = {
    "mprWaitMs": "mprWaitDefaultMs",
    # Dart spells these with a `Default` suffix because SimConfig has a field of the
    # plain name, and a constructor default of `this.x = x` would be self-referential.
    # TypeScript has no such collision: its constants are SCREAMING_CASE.
    "broadcastPerMinuteCap": "broadcastPerMinuteCapDefault",
    "relayPerSourcePerMinuteCap": "relayPerSourcePerMinuteCapDefault",
}


class Decl(NamedTuple):
    name: str
    expr: str
    file: str
    line: int


def screaming_to_camel(name: str) -> str:
    """`PAD_BLOCK_BYTES` -> `padBlockBytes`. Dart has no SCREAMING_CASE convention,
    so the TypeScript name is normalised to the Dart one before pairing. Names that
    are already camel pass through untouched, which is why `MAX_SKIP` and `maxSkip`
    both work but `wireSizeOf` is never rewritten."""
    if "_" not in name and not name.isupper():
        return name
    parts = name.lower().split("_")
    return parts[0] + "".join(p.title() for p in parts[1:])


# `export const NAME[: type] = expr;` and the module-private `const NAME = expr;`
# at column 0. The type annotation is optional and, when present, is the reason a
# naive `=\s*(.*)` grab picks up half the declaration.
#
# Private constants are included because privacy is not the same as unshared: Dart
# has `_pdrWindow` and TypeScript has `PDR_WINDOW`, both 20, and a parity check
# that only read exported names would miss every one of the constants `docs/03` §3
# and §7 actually specify. Indented declarations are excluded, which is what keeps
# function-local `const`s out.
TS_CONST = re.compile(
    r"^(?:export )?const ([A-Za-z0-9_]+)(?::\s*[A-Za-z0-9_<>\[\]| .]+?)?\s*=\s*([^;\n]+);",
    re.M,
)
# Dart writes the type between `const` and the name, and sometimes omits it. A
# leading `_` is Dart's privacy marker and is stripped before pairing, for the same
# reason the TypeScript side includes private constants.
DART_CONST_TYPED = re.compile(
    r"^const\s+[A-Za-z_][A-Za-z0-9_<>,?]*\s+(_?[a-zA-Z_][A-Za-z0-9_]*)\s*=\s*([^;\n]+);", re.M
)
DART_CONST_BARE = re.compile(r"^const\s+(_?[a-zA-Z_][A-Za-z0-9_]*)\s*=\s*([^;\n]+);", re.M)


def collect(root: pathlib.Path) -> Tuple[Dict[str, Decl], Dict[str, Decl]]:
    ts: Dict[str, Decl] = {}
    for path in sorted(root.glob(TS_GLOB)):
        text = path.read_text(encoding="utf-8")
        for m in TS_CONST.finditer(text):
            name = screaming_to_camel(m.group(1))
            line = text.count("\n", 0, m.start()) + 1
            ts.setdefault(name, Decl(name, m.group(2).strip(), str(path.relative_to(root)), line))

    dart: Dict[str, Decl] = {}
    for path in sorted(root.glob(DART_GLOB)):
        text = path.read_text(encoding="utf-8")
        for pattern in (DART_CONST_TYPED, DART_CONST_BARE):
            for m in pattern.finditer(text):
                raw = m.group(1)
                name = raw.lstrip("_") or raw
                line = text.count("\n", 0, m.start()) + 1
                dart.setdefault(
                    name, Decl(name, m.group(2).strip(), str(path.relative_to(root)), line)
                )
    return ts, dart


def normalise(expr: str) -> str:
    """Reduce an initialiser to something comparable across two languages.

    Spaces go, because `27 + 12` and `27+12` are the same constant. Digit
    separators go, because TypeScript allows `30_000` and Dart does not — that
    single difference is why a textual comparison of `neighborScoreTtlMs` fails
    while the two engines agree. Quotes unify, because `"GROUP"` and `'GROUP'` are
    the same string in different syntaxes.
    """
    out = expr.replace("_", "").replace(" ", "").replace("'", '"')
    return out


def as_number(expr: str) -> Optional[float]:
    """Numeric value of an initialiser, or None if it is an expression.

    Expressions are compared as normalised text rather than evaluated: evaluating
    `0.15 / 8` in Python to compare it against Dart's `0.15 / 8` would be a real
    check, but evaluating `(0.15 / 8) * 4` means shipping an expression parser, and
    a textual comparison already catches every change that matters — the two sides
    are written to be literally the same expression.
    """
    text = expr.replace("_", "").replace(" ", "")
    if re.fullmatch(r"-?\d+", text):
        return float(text)
    if re.fullmatch(r"-?\d*\.\d+", text):
        return float(text)
    return None


# --- the coverage-score weight vector -----------------------------------------
#
# `docs/03` §3 fixes it: 0.30 peers, 0.25 rssi, 0.20 battery, 0.15 stability,
# 0.10 pdr, +0.10 for charging, promote above 0.60 and inside the top 20 %, demote
# below 0.50 for two cycles. It is the one constant in either engine that is not a
# scalar — TypeScript has an object literal, Dart a `const` class of field defaults
# — so the name-pairing above cannot see it, and it is exactly the kind of number
# that gets "tuned" on one side only.
TS_WEIGHTS_FILE = "src/election.ts"
DART_WEIGHTS_FILE = "sim/mesh_sim/lib/src/election.dart"
TS_WEIGHTS_BLOCK = re.compile(r"^export const WEIGHTS = \{(.*?)\}", re.S | re.M)
DART_WEIGHTS_BLOCK = re.compile(r"^class Weights \{(.*?)^\}", re.S | re.M)
WEIGHTS_SUM = 1.0


def weight_vector(text: str, block: re.Pattern, field: re.Pattern) -> Dict[str, float]:
    m = block.search(text)
    if not m:
        return {}
    return {name: float(value) for name, value in field.findall(m.group(1))}


def check_weights(root: pathlib.Path) -> Tuple[List[str], Dict[str, object]]:
    ts_path, dart_path = root / TS_WEIGHTS_FILE, root / DART_WEIGHTS_FILE
    if not ts_path.exists() or not dart_path.exists():
        return [f"cannot find {TS_WEIGHTS_FILE} or {DART_WEIGHTS_FILE}"], {}
    ts = weight_vector(
        ts_path.read_text(encoding="utf-8"), TS_WEIGHTS_BLOCK, re.compile(r"(\w+):\s*(-?[\d.]+)")
    )
    dart = weight_vector(
        dart_path.read_text(encoding="utf-8"),
        DART_WEIGHTS_BLOCK,
        re.compile(r"final\s+\w+\s+(\w+)\s*=\s*(-?[\d.]+);"),
    )
    problems: List[str] = []
    if not ts:
        problems.append(f"{TS_WEIGHTS_FILE}: no `export const WEIGHTS = {{...}}` block found")
    if not dart:
        problems.append(f"{DART_WEIGHTS_FILE}: no `class Weights {{...}}` block found")
    if ts and dart:
        for name in sorted(set(ts) | set(dart)):
            if name not in dart:
                problems.append(f"coverage weight `{name}`: in {TS_WEIGHTS_FILE} but not in Dart")
            elif name not in ts:
                problems.append(f"coverage weight `{name}`: in Dart but not in {TS_WEIGHTS_FILE}")
            elif abs(ts[name] - dart[name]) > 1e-12:
                problems.append(
                    f"coverage weight `{name}`: {TS_WEIGHTS_FILE} says {ts[name]} but "
                    f"{DART_WEIGHTS_FILE} says {dart[name]}"
                )
        # docs/03 §3's five weights are a distribution over the score, so they sum
        # to 1. If they do not, the 0.60 promote and 0.50 demote thresholds mean
        # something different from what §3 says they mean.
        for label, vec in (("TypeScript", ts), ("Dart", dart)):
            total = sum(vec.values())
            if abs(total - WEIGHTS_SUM) > 1e-9:
                problems.append(f"{label} coverage weights sum to {total:.6f}, docs/03 §3 says {WEIGHTS_SUM}")
    return problems, {"ts_weights": ts, "dart_weights": dart}


def ts_interface_fields(text: str, name: str) -> Optional[List[str]]:
    """Field names of a TypeScript `export interface`, or None if it is not there."""
    m = re.search(rf"export interface {re.escape(name)} \{{(.*?)\n\}}", text, re.S)
    if not m:
        return None
    return re.findall(r"^  (\w+)\??\s*:", m.group(1), re.M)


def dart_class_fields(text: str, name: str) -> Optional[List[str]]:
    """`final` field names of a Dart class, or None if it is not there."""
    lo = re.search(rf"^class {re.escape(name)} \{{", text, re.M)
    if not lo:
        return None
    start = lo.end()
    end = re.search(r"^\}", text[start:], re.M)
    if not end:
        return None
    return re.findall(r"^  final [\w<>?, .]+ (\w+);", text[start : start + end.start()], re.M)


# The two type inventories that are contracts rather than conveniences. `SimConfig` is what a
# caller may set and `SimulationStats` is what every consumer reads — the React dashboard,
# `--json`, and every number published in docs/06 and docs/08. Both were verified to match
# exactly (83 fields and 80 fields, none one-sided) before the rule was written, which is what
# makes it safe for the rule to fail rather than report.
#
# Enums are deliberately absent from this list. Extracting them reliably means knowing where a
# Dart `enum` body ends and the neighbouring `extension` begins, and a first attempt at exactly
# that read `HopAction`'s Dart values as `class`, `final` and `required`, and `MsgType`'s
# TypeScript union as three of its eight members. A parity check that invents disagreements is
# worse than no parity check, so until that parse is right, it is not here.
INVENTORY_TYPES = ("SimConfig", "SimulationStats")


def sim_config_fields(root: pathlib.Path) -> Tuple[Optional[List[str]], Optional[List[str]]]:
    """The `SimConfig` field names in each engine, or None where the file is absent.

    Absent is a real case and not an error: the self-test builds a fixture tree, and a
    check that failed on a tree it was never asked about could not be self-tested.
    """
    ts_path = root / "src" / "simulation.ts"
    dart_path = root / "sim" / "mesh_sim" / "lib" / "src" / "simulation.dart"
    if not ts_path.exists() or not dart_path.exists():
        return None, None
    ts_text = ts_path.read_text(encoding="utf-8")
    dart_text = dart_path.read_text(encoding="utf-8")
    return ts_interface_fields(ts_text, "SimConfig"), dart_class_fields(dart_text, "SimConfig")


INVENTORY_WORDING = {
    "SimConfig": (
        "a knob in src/simulation.ts with no field in the Dart SimConfig, so the two "
        "engines do not accept the same configuration",
        "a field in the Dart SimConfig with no knob in src/simulation.ts, so the two "
        "engines do not accept the same configuration",
    ),
    "SimulationStats": (
        "a statistic the TypeScript engine reports and the Dart one does not, so --json "
        "and the two engines' outputs are not the same contract",
        "a statistic the Dart engine reports and the TypeScript one does not, so --json "
        "and the two engines' outputs are not the same contract",
    ),
}


def check_config_inventory(root: pathlib.Path) -> Tuple[List[str], Dict[str, object]]:
    """Do the two engines expose the same configuration knobs and statistics?

    Unlike the constant inventories, which legitimately differ — `broadcastAddress`,
    `defaultConfig` and `ln10` have no counterpart on the other side by design — these
    two type inventories are supposed to be *identical*, and both were verified to be
    before the rule was written: 83 `SimConfig` fields and 80 `SimulationStats` fields,
    none one-sided. So this fails rather than reports, and the mistake it exists for is
    the easiest to make in a two-engine repository and the hardest to see without a
    compiler: a field added to one engine and not the other, so an experiment that sets
    a knob silently configures half the contract, or a consumer that reads a statistic
    gets it from one engine and `undefined` from the other.
    """
    ts_path = root / "src" / "simulation.ts"
    dart_path = root / "sim" / "mesh_sim" / "lib" / "src" / "simulation.dart"
    if not ts_path.exists() or not dart_path.exists():
        return {}, {}  # type: ignore[return-value]
    ts_text = ts_path.read_text(encoding="utf-8")
    dart_text = dart_path.read_text(encoding="utf-8")
    problems: List[str] = []
    counts: Dict[str, object] = {}
    for name in INVENTORY_TYPES:
        prefix = "config" if name == "SimConfig" else "stats"
        ts_fields = ts_interface_fields(ts_text, name)
        dart_fields = dart_class_fields(dart_text, name)
        if ts_fields is None or dart_fields is None:
            counts[f"{prefix}_shared"] = None
            continue
        ts_wording, dart_wording = INVENTORY_WORDING[name]
        for f in sorted(set(ts_fields) - set(dart_fields)):
            problems.append(f"{name}.{f}: {ts_wording}")
        for f in sorted(set(dart_fields) - set(ts_fields)):
            problems.append(f"{name}.{f}: {dart_wording}")
        counts[f"{prefix}_ts"] = len(ts_fields)
        counts[f"{prefix}_dart"] = len(dart_fields)
        counts[f"{prefix}_shared"] = len(set(ts_fields) & set(dart_fields))
    return problems, counts


def check(root: pathlib.Path) -> Tuple[List[str], Dict[str, object]]:
    ts, dart = collect(root)
    # Apply the alias table before intersecting, so a renamed constant is compared
    # rather than quietly dropped into the "one-sided" counts.
    for ts_name, dart_name in ALIASES.items():
        if ts_name in ts and dart_name in dart and ts_name not in dart:
            ts[dart_name] = ts.pop(ts_name)
    shared = sorted(set(ts) & set(dart))
    problems: List[str] = []
    numeric = textual = 0
    for name in shared:
        a, b = ts[name], dart[name]
        na, nb = as_number(a.expr), as_number(b.expr)
        if na is not None and nb is not None:
            numeric += 1
            if na != nb:
                problems.append(
                    f"{name}: {a.file}:{a.line} says {a.expr} but {b.file}:{b.line} says {b.expr}"
                )
            continue
        textual += 1
        if normalise(a.expr) != normalise(b.expr):
            problems.append(
                f"{name}: {a.file}:{a.line} says `{a.expr}` but {b.file}:{b.line} says `{b.expr}`"
            )
    counts = {
        "ts_consts": len(ts),
        "dart_consts": len(dart),
        "shared": len(shared),
        "numeric": numeric,
        "textual": textual,
        "ts_only": len(set(ts) - set(dart)),
        "dart_only": len(set(dart) - set(ts)),
    }
    # One-sided names are reported, not failed: the two inventories are not supposed
    # to match. But they are worth *seeing*, because a synonym pair sitting in these
    # lists is a constant this check is silently not comparing — which is how
    # MPR_WAIT_MS / mprWaitDefaultMs was found and added to ALIASES.
    # `weights` is Dart's `const Weights weights` instance, which has no scalar
    # counterpart to pair with — but it is not uncompared, because check_weights
    # reads the vector out of both engines field by field. Listing it here would say
    # the opposite of the truth two lines below.
    covered_elsewhere = {"weights"}
    one_sided = {
        "ts_only": sorted(set(ts) - set(dart) - covered_elsewhere),
        "dart_only": sorted(set(dart) - set(ts) - covered_elsewhere),
    }
    weight_problems, weights = check_weights(root)
    config_problems, config_counts = check_config_inventory(root)
    counts.update({k: v for k, v in config_counts.items()})
    return (
        problems + weight_problems + config_problems,
        {"counts": counts, "one_sided": one_sided, "weights": weights},
    )


# --- self-test -----------------------------------------------------------------
#
# On a synthetic two-file tree rather than a copy of the real one: the check reads
# exactly two globs, so the fixture can be four lines long and the fault injection
# exact. A checker that reports "38 constants agree" is indistinguishable from one
# that never looked, and this is the only way to tell them apart.
FIXTURE_TS = """\
export const PAD_BLOCK_BYTES = 256;
export const SPRAY_LIMIT = 3;
export const NEIGHBOR_SCORE_TTL_MS = 30_000;
export const PACKET_OVERHEAD_BYTES = 27 + 12 + 16 + 32 + 8;
export const GROUP_ADDRESS = "GROUP";
export const NORMAL_DRAIN_PER_HOUR = 0.15 / 8;
export function wireSizeOf(n: number): number { return n; }
"""
FIXTURE_DART = """\
const int padBlockBytes = 256;
const sprayLimit = 3;
const int neighborScoreTtlMs = 30000;
const packetOverheadBytes = 27 + 12 + 16 + 32 + 8;
const groupAddress = 'GROUP';
const double normalDrainPerHour = 0.15 / 8;
int wireSizeOf(int n) => n;
"""

# The SimConfig fixtures carry no `export const` and no Dart `const x = ...`, so they add
# nothing to the constant inventory the clean-fixture assertion counts. A constructor is left
# out of the Dart one for the same reason: the inventory check reads `final` fields only.
FIXTURE_TS_SIM = """\
export interface SimConfig {
  alpha: number;
  beta: boolean;
}

export interface SimulationStats {
  gamma: number;
}
"""
FIXTURE_DART_SIM = """\
class SimConfig {
  final double alpha;
  final bool beta;
}

class SimulationStats {
  final double gamma;
}
"""

# (name, side, find, replace, expectation). "problem" must be reported as a
# disagreement; "counted" must not be, and is here so the self-test states what the
# checker does *not* catch as loudly as what it does.
FIXTURE_TS_ELECTION = """\
export const WEIGHTS = {
  peers: 0.3,
  rssi: 0.25,
  battery: 0.2,
  stability: 0.15,
  pdr: 0.1,
} as const;
"""
FIXTURE_DART_ELECTION = """\
class Weights {
  const Weights();

  final double peers = 0.30;
  final double rssi = 0.25;
  final double battery = 0.20;
  final double stability = 0.15;
  final double pdr = 0.10;
}
"""

SELFTEST_FAULTS: List[Tuple[str, str, str, str, str]] = [
    ("an integer changed on one side only", "dart", "padBlockBytes = 256", "padBlockBytes = 512", "problem"),
    ("a float changed on one side only", "ts", "0.15 / 8;", "0.20 / 8;", "problem"),
    ("an expression changed on one side only", "dart", "27 + 12 + 16 + 32 + 8", "27 + 12 + 16 + 32", "problem"),
    ("a string changed on one side only", "ts", '"GROUP"', '"GROUPS"', "problem"),
    ("a constant deleted from one side", "dart", "const sprayLimit = 3;\n", "", "counted"),
    ("a coverage weight changed on one side only", "ts-election", "rssi: 0.25", "rssi: 0.30", "problem"),
    ("a coverage weight renamed on one side only", "dart-election",
     "final double stability", "final double steadiness", "problem"),
    ("a config knob present only in the Dart engine", "ts-sim",
     "  beta: boolean;\n", "", "problem"),
    ("a config knob present only in the TypeScript engine", "dart-sim",
     "  final bool beta;\n", "", "problem"),
    ("a statistic reported by only one engine", "dart-sim",
     "  final double gamma;\n", "", "problem"),
]


def selftest() -> int:
    import tempfile

    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        (root / "src").mkdir()
        (root / "sim" / "mesh_sim" / "lib" / "src").mkdir(parents=True)
        ts_path = root / "src" / "routing.ts"
        dart_path = root / "sim" / "mesh_sim" / "lib" / "src" / "routing.dart"
        ts_election = root / "src" / "election.ts"
        dart_election = root / "sim" / "mesh_sim" / "lib" / "src" / "election.dart"

        ts_path.write_text(FIXTURE_TS, encoding="utf-8")
        dart_path.write_text(FIXTURE_DART, encoding="utf-8")
        ts_election.write_text(FIXTURE_TS_ELECTION, encoding="utf-8")
        dart_election.write_text(FIXTURE_DART_ELECTION, encoding="utf-8")
        ts_sim = root / "src" / "simulation.ts"
        dart_sim = root / "sim" / "mesh_sim" / "lib" / "src" / "simulation.dart"
        ts_sim.write_text(FIXTURE_TS_SIM, encoding="utf-8")
        dart_sim.write_text(FIXTURE_DART_SIM, encoding="utf-8")
        paths = {"ts": ts_path, "dart": dart_path,
                 "ts-election": ts_election, "dart-election": dart_election,
                 "ts-sim": ts_sim, "dart-sim": dart_sim}
        problems, result = check(root)
        counts = result["counts"]
        # The config inventory is asserted too, and not only for its own sake: a check
        # that never finds its input reports nothing and looks exactly like a pass.
        if (
            problems
            or counts["shared"] != 6
            or counts.get("config_shared") != 2
            or counts.get("stats_shared") != 1
        ):
            print(f"  FAIL the clean fixture does not pass: {problems} {counts}")
            failed += 1
        else:
            print(
                f"  ok   clean fixture: {counts['shared']} shared constants agree, "
                f"{counts['config_shared']} SimConfig knobs and {counts['stats_shared']} "
                f"SimulationStats field identical"
            )

        # A fault the checker cannot see, and must say so rather than imply it looked:
        # deleting a constant from *both* sides leaves them agreeing.
        for name, side, find, replace, expect in SELFTEST_FAULTS:
            path = paths[side]
            original = path.read_text(encoding="utf-8")
            if original.count(find) != 1:
                print(f"  FAIL {name}: the fixture no longer contains `{find}` exactly once")
                failed += 1
                continue
            path.write_text(original.replace(find, replace), encoding="utf-8")
            problems, result = check(root)
            path.write_text(original, encoding="utf-8")
            if expect == "counted":
                # Deleting a name from one side is *not* a value disagreement, and
                # this checker does not claim it is: the inventories legitimately
                # differ, so a one-sided name is counted and reported. What must
                # happen is that the shared count drops — a checker that kept
                # reporting "6 agree" after a constant vanished would be lying.
                if problems or result["counts"]["shared"] != 5:
                    print(f"  FAIL {name}: shared={result['counts']['shared']} problems={problems}")
                    failed += 1
                else:
                    print(f"  ok   {name} -> shared drops to 5 and the name is reported, not failed")
                continue
            if not problems:
                print(f"  FAIL {name}: not caught")
                failed += 1
            else:
                print(f"  ok   {name} -> {problems[0].split(': ', 1)[-1][:70]}")

    total = len(SELFTEST_FAULTS) + 1
    print(f"check-parity --self-test: {total - failed}/{total} cases behaved as expected")
    return 1 if failed else 0


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true", help="prove the checker can still fail")
    parser.add_argument("--json", metavar="PATH", help="write the result as JSON")
    parser.add_argument("--quiet", action="store_true", help="only print the verdict")
    parser.add_argument("--root", metavar="DIR", help="repository root (default: inferred)")
    args = parser.parse_args(argv[1:])

    if args.self_test:
        return selftest()

    root = pathlib.Path(args.root) if args.root else pathlib.Path(__file__).resolve().parent.parent.parent
    problems, result = check(root)
    counts = result["counts"]
    one_sided = result["one_sided"]

    if not args.quiet:
        print("cross-language parity — do the two engines agree on their constants?")
    payload = {
        "check": "engine-constants",
        "status": "fail" if problems else "pass",
        "counts": counts,
        "one_sided": one_sided,
        "problems": problems,
    }
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(payload, indent=2), encoding="utf-8")

    if problems:
        for problem in problems:
            print(f"  FAIL  {problem}")
        print(
            f"\n{len(problems)} constant(s) disagree. {counts['shared']} are shared between the\n"
            "engines; one of them was changed without the other. The golden vectors would catch\n"
            "this too — `make golden` on the TypeScript side, `dart test` on the Dart side —\n"
            "and neither can run where no Dart SDK exists."
        )
        return 1

    if not args.quiet:
        if counts.get("config_shared") is not None:
            print(
                f"  ok    config-inventory   {counts['config_shared']} SimConfig knobs, "
                f"identical in both engines ({counts['config_ts']} TS, {counts['config_dart']} Dart)"
            )
        if counts.get("stats_shared") is not None:
            print(
                f"  ok    stats-inventory    {counts['stats_shared']} SimulationStats fields, "
                f"identical in both engines ({counts['stats_ts']} TS, {counts['stats_dart']} Dart)"
            )
        print(
            f"  ok    engine-constants   {counts['shared']} shared constants agree "
            f"({counts['numeric']} numeric, {counts['textual']} by expression)"
        )
        # Printed from the listed names, not from counts['*_only']: `weights` is
        # counted there but is compared by check_weights below, and quoting a number
        # that disagrees with the list underneath it is how a report loses readers.
        print(
            f"        {counts['ts_consts']} exported in src/, {counts['dart_consts']} in sim/mesh_sim/lib/src/; "
            f"{len(one_sided['ts_only'])} TypeScript-only and {len(one_sided['dart_only'])} Dart-only\n"
            "        names are not compared by this check, because the two inventories are not\n"
            "        supposed to match."
        )
        if one_sided["ts_only"] or one_sided["dart_only"]:
            print("        one-sided names, listed because a synonym pair hiding here is a")
            print("        constant this check is silently not comparing:")
            if one_sided["ts_only"]:
                print(f"          src/ only       {', '.join(one_sided['ts_only'])}")
            if one_sided["dart_only"]:
                print(f"          sim/ only       {', '.join(one_sided['dart_only'])}")
        weights = result.get("weights") or {}
        if weights.get("ts_weights"):
            order = sorted(weights["ts_weights"])
            print(
                "  ok    coverage-weights   "
                + ", ".join(f"{k} {weights['ts_weights'][k]:g}" for k in order)
                + f"  (sum {sum(weights['ts_weights'].values()):g})"
            )
            print(
                "        docs/03 §3's vector, read out of both engines and required to sum to 1 —"
                " if it does not,\n        the 0.60 promote and 0.50 demote thresholds do not mean"
                " what §3 says they mean."
            )
        print("\nall parity checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
