#!/usr/bin/env python3
"""Check that the commands the documentation tells you to run are the commands that exist.

Every check here is bidirectional where that is meaningful, and every one of them exists because a
command was once written into these docs from memory and was wrong:

  * two `tool/media-probe.ts` section names were documented that the probe does not have
    (`backpressure`, `retryTimer` — the real ones are `retry` and `capture`), while four sections
    it does have went undocumented;
  * four real `bin/mesh_sim.dart` flags were missing from the cheat sheet;
  * `make clean` was documented as removing a directory it does not remove.

A reader who copies a documented command and gets "unknown option" loses far more than the minute
it takes to run this. So the source of truth is always the program: its own argument parser, its
own registry, its own target list. The docs are what gets checked against it.

Checks
------
dart-cli-flags    `bin/mesh_sim.dart` usage + arg parsing  <->  docs/12's CLI table
media-sections    `tool/media-probe.ts` section registry   <-   section names in the docs
make-targets      `Makefile` targets                       <-   `make X` in code spans and blocks
ps1-targets       `make.ps1` $ScriptTargets keys           ->   must be real Makefile targets
ci-script-flags   each `tool/ci/*.sh` argument parser      <-   flags used next to it in the docs

Deliberately not checked: prose that paraphrases a command without naming it, and the reverse
direction for media sections and Makefile targets, where "undocumented" is a judgement about what a
cheat sheet should carry rather than a fact about whether a command works.

`--self-test` is the part that makes the above worth believing. A drift checker that always passes
is indistinguishable from one that is broken, so it copies the files it reads into a temporary
tree, injects one fault per check, and requires that each fault is caught and named. Run it after
changing any parser here.

Exit 0 when every check passes, 1 when any fails, 64 on bad usage.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, NamedTuple, Optional, Set

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent

# What --self-test copies. Small, and exactly the set of files the checks read.
SELFTEST_PATHS = [
    "Makefile",
    "make.ps1",
    "tool/media-probe.ts",
    "sim/mesh_sim/bin/mesh_sim.dart",
]


class Result(NamedTuple):
    name: str
    ok: bool
    summary: str
    problems: List[str]


class Repo:
    """The files the checks read, so a self-test can point them at a mutated copy."""

    def __init__(self, root: Path):
        self.root = root
        self.docs = sorted((root / "docs").glob("*.md"))
        if (root / "README.md").exists():
            self.docs.append(root / "README.md")

    def read(self, rel: str) -> str:
        return (self.root / rel).read_text(encoding="utf-8")

    def write(self, rel: str, text: str) -> None:
        (self.root / rel).write_text(text, encoding="utf-8")


# --- the sources of truth ------------------------------------------------------

def _dart_usage_flags(src: str) -> Set[str]:
    """Flags in the CLI's own usage text.

    Read as one block rather than line by line, because the help line reads `-h, --help` and a
    column-anchored pattern silently misses a flag that does not start its line.
    """
    q = "'" * 3
    m = re.search(q + "(.*?)" + q, src, re.S)
    return set(re.findall(r"(--[a-z][a-z-]*)", m.group(1))) if m else set()


def _dart_parsed_flags(src: str) -> Set[str]:
    """Flags the CLI actually handles: args.contains('--x') and _arg(args, '--x', ...)."""
    return set(re.findall(r"'(--[a-z][a-z-]*)'", src))


def dart_cli_flags(repo: Repo) -> Set[str]:
    src = repo.read("sim/mesh_sim/bin/mesh_sim.dart")
    return _dart_usage_flags(src) | _dart_parsed_flags(src)


def dart_usage_disagreement(repo: Repo) -> List[str]:
    """A flag in the usage text but not the parser, or the reverse, is a defect in the program."""
    src = repo.read("sim/mesh_sim/bin/mesh_sim.dart")
    usage, parsed = _dart_usage_flags(src), _dart_parsed_flags(src)
    out = [f"bin/mesh_sim.dart documents {f} in its usage text but never parses it"
           for f in sorted(usage - parsed)]
    out += [f"bin/mesh_sim.dart parses {f} but its usage text does not mention it"
            for f in sorted(parsed - usage)]
    return out


def dart_accepted_values(repo: Repo) -> Dict[str, Set[str]]:
    """The value strings each enum-like flag accepts, read from its switch's case labels."""
    src = repo.read("sim/mesh_sim/bin/mesh_sim.dart")
    out: Dict[str, Set[str]] = {}
    for var in ["policyName", "accessName", "captureName", "priorityName", "backoffName"]:
        i = src.find(f"switch ({var})")
        if i < 0:
            continue
        j = src.find("exitCode = 64;", i)
        out[var] = set(re.findall(r"case '([a-z][a-z-]*)':", src[i:j if j > 0 else None]))
    return out


def media_sections(repo: Repo) -> Set[str]:
    """Section names in the probe's registry — the list it prints when given an unknown one.

    Only the `sections` array. Matching every `["name", fn]` pair in the file also picks up an
    unrelated one elsewhere and reports sections the probe does not have.
    """
    src = repo.read("tool/media-probe.ts")
    i = src.index("const sections:")
    j = src.index("];", i)
    return set(re.findall(r'\[\s*"([A-Za-z][A-Za-z0-9]*)"\s*,', src[i:j]))


def make_targets(repo: Repo) -> Set[str]:
    out = set()
    for line in repo.read("Makefile").splitlines():
        m = re.match(r"^([a-zA-Z][a-zA-Z0-9_-]*):", line)
        if m:
            out.add(m.group(1))
    return out


def ps1_script_targets(repo: Repo) -> Dict[str, str]:
    """make.ps1's $ScriptTargets: target name -> script path. Used when make is not installed."""
    src = repo.read("make.ps1")
    i = src.index("$ScriptTargets")
    j = src.index("}", src.index("@{", i))
    block = src[i:j]
    return {k: v for k, v in re.findall(r"'([a-zA-Z][a-zA-Z0-9_-]*)'\s*=\s*'([^']*)'", block)}


def check_help_covers_targets(repo: Repo) -> Result:
    """Every target with a `## ` comment must be reachable from `make help`.

    `make help` builds its list by grepping the Makefile with a pattern of its own, so a target
    whose name the pattern does not describe is silently invisible: `check-ps1` was missing from
    the help for as long as it existed, because the pattern allowed letters, `_` and `-` but not
    the digit in its name. The check reads the pattern out of the recipe and applies it, so it
    follows the Makefile rather than duplicating it.
    """
    mk = repo.read("Makefile")
    m = re.search(r"grep -hE '([^']+)'", mk)
    if not m:
        return Result("help-covers-targets", False, "could not find the help pattern",
                      ["the help recipe no longer greps for `## ` comments; this check needs "
                       "updating to match however it now builds the list"])
    pattern = m.group(1)
    documented, invisible = 0, []
    for line in mk.splitlines():
        if "## " not in line or not re.match(r"^[a-zA-Z0-9_-]+:", line):
            continue
        documented += 1
        # Python's re is not grep -E, but the only part that differs in behaviour here is `.*?`,
        # which both accept; the character class and the `## ` literal mean the same in each.
        if not re.search(pattern, line):
            invisible.append(line.split(":")[0])
    problems = [f"`make {t}` has a help comment but the help recipe's pattern "
                f"`{pattern}` does not match it, so it never appears in `make help`"
                for t in invisible]
    return Result("help-covers-targets", not problems,
                  f"{documented} documented targets, all visible in help", problems)


def ci_script_flags(repo: Repo) -> Dict[str, Set[str]]:
    """Flags each `tool/ci/*.sh` accepts, read out of its own argument parser.

    Taken from the `case "$1" in` block, so the answer is what the script does rather than what
    its header comment claims. A script using getopt-style parsing would need its own reader;
    none of these do.
    """
    out: Dict[str, Set[str]] = {}
    for sh in sorted((repo.root / "tool/ci").glob("*.sh")):
        src = sh.read_text(encoding="utf-8")
        flags: Set[str] = set()
        m = re.search(r'case "\$1" in(.*?)\n\s*esac', src, re.S)
        if m:
            flags |= set(re.findall(r"(--[a-z][a-z-]*)", m.group(1)))
        flags |= set(re.findall(r'\[ "\$1" = "(--[a-z][a-z-]*)"', src))
        if flags:
            out[sh.name] = flags
    return out


# --- reading what the docs claim ----------------------------------------------

def code_spans_and_blocks(text: str) -> List[tuple]:
    """Only the parts of a Markdown document that are commands, each with its line number.

    Prose is excluded on purpose: "make sure the radio is free" is not an invocation of `make`,
    and counting it would bury the real findings in noise.
    """
    out: List[tuple] = []
    fenced = False
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            out.append((n, line))
            continue
        for span in re.findall(r"`([^`]*)`", line):
            out.append((n, span))
    return out


def docs_section(repo: Repo, path: Path, heading: str, stop: str) -> str:
    t = path.read_text(encoding="utf-8")
    i = t.index(heading)
    return t[i:t.index(stop, i)]


# --- the checks ----------------------------------------------------------------

def check_dart_cli_flags(repo: Repo) -> Result:
    impl = dart_cli_flags(repo)
    cheat = repo.root / "docs/12-cli-cheat-sheet.md"
    sec = docs_section(repo, cheat, "### The Dart CLI itself", "\n---\n")
    claimed = set(re.findall(r"(--[a-z][a-z-]*)", sec))

    problems = [f"docs/12 names {f}, which the CLI does not accept" for f in sorted(claimed - impl)]
    problems += [f"the CLI accepts {f}, which docs/12 does not mention" for f in sorted(impl - claimed)]
    problems += dart_usage_disagreement(repo)

    # Each accepted value too. Documenting the enum spelling (`halfDuplex`) instead of the CLI's
    # (`half-duplex`) is the mistake that reads correctly and fails at runtime.
    for var, values in dart_accepted_values(repo).items():
        for val in sorted(values):
            if val not in sec:
                problems.append(f"docs/12 does not list `{val}`, a value the CLI accepts ({var})")

    return Result("dart-cli-flags", not problems,
                  f"{len(impl)} CLI flags vs {len(claimed)} documented", problems)


def check_media_sections(repo: Repo) -> Result:
    impl = media_sections(repo)
    problems: List[str] = []
    seen: Set[str] = set()
    invoked = re.compile(r"(?:npm run media|make media SECT=)\s*(?:--\s*)?([A-Za-z][A-Za-z0-9]*)")
    for d in repo.docs:
        text = d.read_text(encoding="utf-8")
        for n, span in code_spans_and_blocks(text):
            for m in invoked.finditer(span):
                sect = m.group(1)
                seen.add(sect)
                if sect in impl or sect in ("run", "media"):  # `npm run media`, no section
                    continue
                problems.append(f"{d.name}:{n} names section `{sect}`; the probe has no such section")
        # "one section; also `shedding`, `captureEffect`" names sections in prose, on a line that
        # is itself about the command. A reader will act on those, so they are checked too — but
        # only on such a line, or every backticked identifier in the docs becomes a suspect.
        for n, line in enumerate(text.splitlines(), 1):
            if "npm run media" not in line and "make media" not in line:
                continue
            for span in re.findall(r"`([^`]*)`", line):
                if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", span) or span == "media":
                    continue
                seen.add(span)
                if span not in impl:
                    problems.append(
                        f"{d.name}:{n} names section `{span}`; the probe has no such section")
    return Result("media-sections", not problems,
                  f"{len(impl)} sections in the probe, {len(seen)} named in the docs", problems)


def check_make_targets(repo: Repo) -> Result:
    impl = make_targets(repo)
    problems: List[str] = []
    seen: Set[str] = set()
    # Lowercase-initial only: the cheat sheet's conventions note says "`make X` on Linux", and X
    # is a metavariable. Every real target in this Makefile starts lowercase.
    pat = re.compile(r"\bmake ([a-z][a-z0-9_-]*)")
    for d in repo.docs:
        for n, span in code_spans_and_blocks(d.read_text(encoding="utf-8")):
            for m in pat.finditer(span):
                t = m.group(1)
                seen.add(t)
                if t not in impl:
                    problems.append(
                        f"{d.name}:{n} tells the reader to run `make {t}`; there is no such target")
    return Result("make-targets", not problems,
                  f"{len(impl)} targets, {len(seen)} named in the docs", problems)


def check_ps1_targets(repo: Repo) -> Result:
    impl = make_targets(repo)
    mapping = ps1_script_targets(repo)
    problems = [f"make.ps1 maps `{k}` to a script, but the Makefile has no target `{k}`"
                for k in sorted(mapping) if k not in impl]
    # And the script it maps to must exist, or the target fails on a machine without make —
    # which is the only machine this table is for.
    for k, path in sorted(mapping.items()):
        script = path.split()[0]
        if not (repo.root / script).exists():
            problems.append(f"make.ps1 maps `{k}` to {script}, which does not exist")
    return Result("ps1-targets", not problems,
                  f"{len(mapping)} make.ps1 targets, all backed by the Makefile", problems)


def check_ci_script_flags(repo: Repo) -> Result:
    impl = ci_script_flags(repo)
    problems: List[str] = []
    seen = 0
    for d in repo.docs:
        for n, span in code_spans_and_blocks(d.read_text(encoding="utf-8")):
            for script, flags in impl.items():
                stem = script[:-3]  # run-pipeline.sh -> run-pipeline
                if stem not in span:
                    continue
                # `.sh` is optional: without it the pattern only matched the one place in the
                # docs that names a script by its bare stem, and silently skipped every real
                # invocation — a check that reports ok while examining almost nothing.
                for m in re.finditer(re.escape(stem) + r"(?:\.sh)?((?:\s+--[a-z][a-z-]*)+)", span):
                    for f in re.findall(r"(--[a-z][a-z-]*)", m.group(1)):
                        seen += 1
                        if f not in flags:
                            problems.append(
                                f"{d.name}:{n} passes {f} to {script}, which does not accept it "
                                f"(it takes: {' '.join(sorted(flags))})")
    return Result("ci-script-flags", not problems,
                  f"{len(impl)} scripts, {seen} flag uses checked", problems)


CHECKS = [
    check_dart_cli_flags,
    check_media_sections,
    check_make_targets,
    check_ps1_targets,
    check_ci_script_flags,
    check_help_covers_targets,
]


def run_checks(repo: Repo, only: Optional[str] = None) -> List[Result]:
    out = []
    for c in CHECKS:
        r = c(repo)
        if only and r.name != only:
            continue
        out.append(r)
    return out


# --- the self-test -------------------------------------------------------------
#
# A drift checker that always passes is indistinguishable from one that is broken. Each fault
# below is a mistake this repository has actually made, or the closest analogue of one.

FAULTS = [
    ("dart-cli-flags", "sim/mesh_sim/bin/mesh_sim.dart", "  --trace  ",
     lambda s: s.replace("  --trace  ", "  --turbo  \n  --trace  ", 1), "--turbo"),
    ("media-sections", "docs/08-media-transport-ptt.md", "npm run media -- backoff",
     lambda s: s.replace("npm run media -- backoff", "npm run media -- backpressure", 1),
     "backpressure"),
    ("make-targets", "docs/12-cli-cheat-sheet.md", "make checks-list",
     lambda s: s.replace("make checks-list", "make checks-listt", 1), "checks-listt"),
    ("ps1-targets", "make.ps1", "    'ci'          =",
     lambda s: s.replace("    'ci'          =", "    'bogus'       = 'tool/ci/nope.sh'\n"
                                                "    'ci'          =", 1), "bogus"),
    ("ci-script-flags", "docs/10-local-development-and-ci.md", "run-pipeline.sh --job",
     lambda s: s.replace("run-pipeline.sh --job", "run-pipeline.sh --jobs", 1), "--jobs"),
    # the real regression: a pattern that cannot see a digit hides check-ps1 from help
    ("help-covers-targets", "Makefile", "^[a-zA-Z0-9_-]+:",
     lambda s: s.replace("^[a-zA-Z0-9_-]+:", "^[a-zA-Z_-]+:", 1), "check-ps1"),
]


def self_test() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="check-docs-selftest-"))
    failures: List[str] = []
    try:
        (tmp / "docs").mkdir(parents=True)
        (tmp / "tool/ci").mkdir(parents=True)
        (tmp / "sim/mesh_sim/bin").mkdir(parents=True)
        for rel in SELFTEST_PATHS:
            shutil.copy2(ROOT / rel, tmp / rel)
        for d in sorted((ROOT / "docs").glob("*.md")):
            shutil.copy2(d, tmp / "docs" / d.name)
        if (ROOT / "README.md").exists():
            shutil.copy2(ROOT / "README.md", tmp / "README.md")
        for sh in sorted((ROOT / "tool/ci").glob("*.sh")):
            shutil.copy2(sh, tmp / "tool/ci" / sh.name)

        repo = Repo(tmp)
        base = [r for r in run_checks(repo) if not r.ok]
        if base:
            for r in base:
                failures.append(f"the unmutated copy already fails {r.name}: {r.problems[0]}")
            print("self-test: the copy of the real tree does not pass, so nothing below is meaningful")
            for f in failures:
                print(f"  · {f}")
            return 1

        print(f"self-test: the copied tree passes all {len(CHECKS)} checks; now breaking it on purpose")
        for name, rel, needs, mutate, token in FAULTS:
            original = (tmp / rel).read_text(encoding="utf-8")
            if needs not in original:
                failures.append(f"{name}: fixture anchor {needs!r} is gone from {rel}; "
                                f"this fault can no longer be injected")
                continue
            (tmp / rel).write_text(mutate(original), encoding="utf-8")
            hit = [r for r in run_checks(repo, only=name) if not r.ok]
            (tmp / rel).write_text(original, encoding="utf-8")

            if not hit:
                failures.append(f"{name}: injecting `{token}` into {rel} was NOT caught")
                continue
            if not any(token in p for p in hit[0].problems):
                failures.append(f"{name}: caught something, but never named `{token}`: "
                                f"{hit[0].problems[0]}")
                continue
            print(f"  ok    {name:18s} caught `{token}` in {rel}")

        # and prove the tree was put back, or a later fault is testing the wrong thing
        for rel in SELFTEST_PATHS:
            if (tmp / rel).read_text(encoding="utf-8") != (ROOT / rel).read_text(encoding="utf-8"):
                failures.append(f"{rel} was not restored after its fault")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("\nself-test FAILED:")
        for f in failures:
            print(f"  · {f}")
        return 1
    print(f"\nself-test passed: all {len(FAULTS)} faults caught and named, tree restored.")
    return 0


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", metavar="PATH", help="also write the findings as JSON")
    ap.add_argument("--only", metavar="NAME", help="run one check by name")
    ap.add_argument("--quiet", action="store_true", help="print only failures")
    ap.add_argument("--self-test", action="store_true",
                    help="inject one fault per check into a temporary copy and prove each is caught")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    repo = Repo(ROOT)
    if args.only and args.only not in [c(repo).name for c in CHECKS]:
        print(f"error: no check named {args.only}. Have: {', '.join(c(repo).name for c in CHECKS)}",
              file=sys.stderr)
        return 64

    results = run_checks(repo, args.only)
    if not args.quiet:
        print("documentation drift — does every documented command exist?")
    failed = 0
    for r in results:
        if r.ok:
            if not args.quiet:
                print(f"  ok    {r.name:18s} {r.summary}")
            continue
        failed += 1
        print(f"  FAIL  {r.name:18s} {r.summary}")
        for p in r.problems:
            print(f"        · {p}")

    if args.json:
        Path(args.json).write_text(json.dumps({
            "checks": [{"name": r.name, "ok": r.ok, "summary": r.summary, "problems": r.problems}
                       for r in results],
            "failed": failed,
        }, indent=2) + "\n", encoding="utf-8")

    if failed:
        print(f"\n{failed} check(s) failed. The source of truth is the program, not the prose:")
        print("either the docs name something that does not exist, or they have gone stale.")
        return 1
    if not args.quiet:
        print(f"\nall {len(results)} checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
