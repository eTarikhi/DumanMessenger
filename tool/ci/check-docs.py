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
    "tool/e2ee-probe.ts",
    "sim/mesh_sim/bin/mesh_sim.dart",
    "package.json",
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
        # Everything that cites a section of something else, not only docs/.
        self.corpus = list(self.docs)
        self.corpus += sorted((root / "skills").glob("*.md"))
        self.corpus += sorted((root / "roadmap").glob("*.md"))
        # PRIVACY.md sits at the root because that is where a store listing and a release
        # artefact expect to find it, but it cites `docs/NN §M` like everything else — and an
        # unchecked citation in a legal document is the worst place in the repository for a
        # reference to rot. In the corpus (so doc-section-refs reads it) but not in `docs`
        # (so it is not scanned for `make` targets or probe sections, which it does not
        # contain and should not).
        for extra in ("PRIVACY.md",):
            if (root / extra).exists():
                self.corpus.append(root / extra)

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
    for var in ["policyName", "accessName", "captureName", "priorityName", "backoffName",
                "capScopeName", "blockScopeName", "occupancyName", "intervalModeName", "scanModeName"]:
        i = src.find(f"switch ({var})")
        if i < 0:
            continue
        j = src.find("exitCode = 64;", i)
        out[var] = set(re.findall(r"case '([a-z][a-z-]*)':", src[i:j if j > 0 else None]))
    return out


def probe_sections(repo: Repo, rel: str, decl: str) -> Set[str]:
    """Section names in a probe's registry — the list it prints when given an unknown one.

    Only the one named array. Matching every `["name", fn]` pair in the file also picks up
    unrelated ones elsewhere: the first version of this reported 15 media sections where the
    probe has 13, because another array in the file has the same shape.
    """
    src = repo.read(rel)
    i = src.index(decl)
    j = src.index("];", i)
    return set(re.findall(r'\[\s*"([A-Za-z][A-Za-z0-9]*)"\s*,', src[i:j]))


def media_sections(repo: Repo) -> Set[str]:
    return probe_sections(repo, "tool/media-probe.ts", "const sections:")


def e2ee_sections(repo: Repo) -> Set[str]:
    return probe_sections(repo, "tool/e2ee-probe.ts", "const SECTIONS:")


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


def check_doc_section_refs(repo: Repo) -> Result:
    """Every `docs/NN §M` citation must point at a section that document actually has.

    192 such citations exist across docs/, skills/ and the roadmap, and nothing guarded any of
    them. This cannot catch a citation to a section that exists but says something else — that is
    how the latency budget came to be attributed to `docs/04` §5, which is Relay Privacy — but it
    does catch renumbering, which is the more common way a reference rots.
    """
    by_num = {}
    for d in repo.docs:
        m = re.match(r"^(\d{2})-", d.name)
        if m:
            by_num[m.group(1)] = d
    headings = {}
    for num, path in by_num.items():
        nums = set()
        for line in path.read_text(encoding="utf-8").splitlines():
            h = re.match(r"^#{2,4}\s+(\d+(?:\.\d+)*)\.?\s+\S", line)
            if h:
                nums.add(h.group(1))
        headings[num] = nums

    pat = re.compile(
        r"docs/(\d{2})(?:[a-z0-9-]*\.md)?`?\s*"
        r"(?:§+\s*(\d+(?:\.\d+)*)(?:\s*[-–]\s*§?\s*(\d+(?:\.\d+)*))?)?")
    problems: List[str] = []
    total = 0
    for f in repo.corpus:
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            for m in pat.finditer(line):
                num = m.group(1)
                if num not in headings or not headings[num]:
                    continue  # unknown document, or one with no numbered headings to check against
                for sec in (m.group(2), m.group(3)):
                    if not sec:
                        continue
                    total += 1
                    if sec not in headings[num]:
                        problems.append(
                            f"{f.name}:{n} cites docs/{num} §{sec}, which has no such section "
                            f"(it has {len(headings[num])})")
    return Result("doc-section-refs", not problems,
                  f"{total} section citations, all resolve", problems)


def check_npm_scripts(repo: Repo) -> Result:
    """Every `npm run X` in the docs must be a script package.json actually has.

    Only the forward direction. `test` and `typecheck` are never written as `npm run test` — the
    docs say `npm test` and `make typecheck` — so "unreferenced" here would be a claim about
    phrasing rather than a broken command.
    """
    scripts = set(json.loads(repo.read("package.json")).get("scripts", {}))
    pat = re.compile(r"npm run ([a-zA-Z0-9:_-]+)")
    problems: List[str] = []
    seen: Set[str] = set()
    for d in repo.corpus:
        for n, line in enumerate(d.read_text(encoding="utf-8").splitlines(), 1):
            for m in pat.finditer(line):
                nm = m.group(1)
                seen.add(nm)
                if nm not in scripts:
                    problems.append(
                        f"{d.name}:{n} tells the reader to run `npm run {nm}`; package.json has "
                        f"no such script")
    return Result("npm-scripts", not problems,
                  f"{len(scripts)} scripts, {len(seen)} referenced in the docs", problems)


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


def section_claims(repo: Repo, invokes: Tuple[str, ...]) -> List[Tuple[str, int, str]]:
    """Section names the docs claim, as (file, line, name).

    Two shapes count: an invocation (`npm run media -- backoff`, `make e2ee SECT=churn`), and a
    bare backticked identifier on a line that is itself about the probe — which is how a doc lists
    "also `shedding`, `captureEffect`". Scanning every backticked identifier in the corpus would
    bury the findings in prose.

    The second shape has a known cost, hit twice now. Any backticked identifier sharing a line with
    a command name is read as a section claim, so a `docs/12` table row that says "measured against
    `wireSizeOf`" on the same line as `npm run e2ee crypto` claims a section called `wireSizeOf`.
    That is a false positive in the doc's favour — it fires, it is one line, and the fix is to not
    name an unrelated symbol on a line about the command. The alternative would be to decide which
    identifiers "look like" section names, and `captureEffect` and `wireSizeOf` look exactly alike.
    A check that occasionally says "this line is doing two things" is worth more than one that
    guesses.
    """
    out: List[Tuple[str, int, str]] = []
    invoked = re.compile(
        r"(?:" + "|".join(re.escape(i) for i in invokes) + r")\s*(?:--\s*)?([A-Za-z][A-Za-z0-9]*)")
    for d in repo.docs:
        text = d.read_text(encoding="utf-8")
        for n, span in code_spans_and_blocks(text):
            for m in invoked.finditer(span):
                out.append((d.name, n, m.group(1)))
        for n, line in enumerate(text.splitlines(), 1):
            if not any(i in line for i in invokes):
                continue
            for span in re.findall(r"`([^`]*)`", line):
                if re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", span):
                    out.append((d.name, n, span))
    return out


def check_sections(name: str, impl: Set[str], claims: List[Tuple[str, int, str]],
                   noise: Set[str], summary_noun: str) -> Result:
    """One probe's sections, in the direction that can be checked precisely.

    Invented names are the mistake this repository has actually made — `backpressure` and
    `retryTimer` were documented for a probe that has `retry` and `capture` — and they are
    unambiguous, because the probe's registry is a closed list.

    The reverse is not checked, and it is worth saying why rather than quietly omitting it.
    Thirteen of the media probe's eighteen sections are named `file`, `voice`, `retry`,
    `capture`, `channel`, `priority`, `contention`, `acceptance`, `serialization`, `beacon`,
    `reach`, `occupancy` and `shedding`: ordinary English words.
    "Does any document mention `capture`" cannot be answered by searching for a backticked word,
    because the corpus discusses capture the phenomenon at length and the probe's own row in
    docs/12 lists all thirteen on a table line that never names the command. A first version of
    this check reported all nine as undocumented. A check with nine false positives trains people
    to ignore it, which is worse than the gap.
    """
    problems: List[str] = []
    claimed = {c for _, _, c in claims}
    for f, n, c in claims:
        if c in impl or c in noise:
            continue
        problems.append(f"{f}:{n} names section `{c}`; the {summary_noun} has no such section")
    return Result(name, not problems,
                  f"{len(impl)} sections in the probe, {len(claimed & impl)} named in the docs",
                  problems)


def check_section_counts(repo: Repo) -> Result:
    """A documented *number* of probe sections must equal the number the probe has.

    `media-sections` catches an invented name; it cannot catch a count that went stale, because
    a count is not a name. README said "`npm run media` — 17 sections" for as long as the probe
    had eighteen, and every check passed: the line names no section, so nothing read it. The
    number is the part a reader acts on — it tells them how long the run takes and how much of
    the documentation the probe covers — so it is the part worth guarding.

    Scoped to a line that also names the invocation, for the same reason `section_claims` is: a
    bare "18 sections" appears in pasted check output and in prose about other things, and
    matching those would produce a check whose failures mean nothing.
    """
    probes = [
        ("npm run media", media_sections(repo)),
        ("npm run e2ee", e2ee_sections(repo)),
    ]
    pat = re.compile(r"\b(\d+)\s+sections\b")
    problems: List[str] = []
    seen = 0
    for d in repo.corpus:
        for n, line in enumerate(d.read_text(encoding="utf-8").splitlines(), 1):
            for invoke, impl in probes:
                if invoke not in line or not impl:
                    continue
                for m in pat.finditer(line):
                    seen += 1
                    if int(m.group(1)) != len(impl):
                        problems.append(
                            f"{d.name}:{n} says `{invoke}` has {m.group(1)} sections; it has "
                            f"{len(impl)}")
    return Result("section-counts", not problems,
                  f"{seen} section-count claim(s) checked against the probes", problems)


def check_media_sections(repo: Repo) -> Result:
    return check_sections(
        "media-sections", media_sections(repo),
        section_claims(repo, ("npm run media", "make media SECT=")),
        {"run", "media"}, "probe")


def check_e2ee_sections(repo: Repo) -> Result:
    return check_sections(
        "e2ee-sections", e2ee_sections(repo),
        section_claims(repo, ("npm run e2ee", "make e2ee SECT=")),
        {"run", "e2ee"}, "probe")


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


def workflow_jobs(repo: Repo) -> List[str]:
    """Job names in `.github/workflows/ci.yml`, read without a YAML dependency.

    The checker is stdlib-only on purpose — it has to run on a machine that has nothing but
    python3, which is the situation that makes it worth having. Top-level job keys are two
    spaces in under `jobs:` and nothing else in this file is indented exactly that way.
    """
    path = repo.root / ".github" / "workflows" / "ci.yml"
    if not path.exists():
        return []
    text = path.read_text(encoding="utf-8")
    m = re.search(r"^jobs:\n(.*?)(?=^\S|\Z)", text, re.S | re.M)
    if not m:
        return []
    return re.findall(r"^  ([a-z][a-z0-9-]*):$", m.group(1), re.M)


def pipeline_jobs(repo: Repo) -> List[str]:
    """Job names `run-pipeline.sh` will dispatch, from its own `JOBS_ALL`."""
    path = repo.root / "tool" / "ci" / "run-pipeline.sh"
    if not path.exists():
        return []
    m = re.search(r'^JOBS_ALL="([^"]+)"', path.read_text(encoding="utf-8"), re.M)
    return m.group(1).split() if m else []


def check_ci_jobs(repo: Repo) -> Result:
    """Does the local pipeline mirror the workflow it claims to mirror?

    `run-pipeline.sh` exists so that a green local run is evidence about the remote one, and
    `docs/10` says so in those words: it copies each step onto the workflow step it copies.
    That claim is only worth anything if the two job lists agree, and they are maintained in
    two places by hand — which is a drift this repository had not been checking, added the
    same day a fifth job went into both. A job in the workflow that the pipeline does not run
    means a local green says nothing about that job; a job the pipeline runs that the workflow
    does not means the local run is stricter than CI and a merge can still land red.
    """
    wf = workflow_jobs(repo)
    pipe = pipeline_jobs(repo)
    problems: List[str] = []
    if not wf:
        problems.append("no jobs could be read out of .github/workflows/ci.yml")
    if not pipe:
        problems.append("no JOBS_ALL could be read out of tool/ci/run-pipeline.sh")

    # `--list` is the mapping docs/10 §10 tells a reader to trust ("prints this mapping from the
    # script itself, so the table above and the runner cannot disagree for long"), and `--job`'s
    # help line is how anybody learns the job names exist. Both are hand-written text in the same
    # file as JOBS_ALL, and both had silently lost a job: `checks` ran, was gated on, and appeared
    # in neither — so the reference table in the docs omitted the one job whose whole purpose is
    # catching drift, and `--job checks` looked like a typo rather than the default first job.
    src = (repo.root / "tool" / "ci" / "run-pipeline.sh").read_text(encoding="utf-8") \
        if (repo.root / "tool" / "ci" / "run-pipeline.sh").exists() else ""
    # One space, not two: the label column is ten characters wide and `cli-matrix` fills it, so
    # a `\s{2,}` separator reported a job that is plainly described. Measured before shipping.
    described = set(re.findall(r"^([a-z][a-z0-9-]*)\s+\S", _between(src, "describe_jobs() {", r"^}$"), re.M))
    m = re.search(r"--job LIST\s+comma-separated: ([^(]+)", src)
    advertised = {t.strip() for t in m.group(1).split(",")} if m else set()
    for j in pipe:
        if j not in described:
            problems.append(
                f"run-pipeline.sh runs a job `{j}` that its own --list plan does not describe, so "
                f"the mapping docs/10 §10 tells readers to trust omits it")
        if j not in advertised:
            problems.append(
                f"run-pipeline.sh runs a job `{j}` that the --job LIST help line does not name, so "
                f"`--job {j}` reads as a typo instead of a supported selection")
    for j in wf:
        if j not in pipe:
            problems.append(
                f"ci.yml defines a job `{j}` that run-pipeline.sh does not mirror, so a green "
                f"local run says nothing about it")
    for j in pipe:
        if j not in wf:
            problems.append(
                f"run-pipeline.sh runs a job `{j}` that ci.yml does not define, so the local "
                f"pipeline is stricter than CI and a merge can still land red")
    return Result("ci-jobs", not problems,
                  f"{len(wf)} workflow jobs, {len(pipe)} mirrored", problems)


def _checker_invocations(text: str) -> Set[str]:
    """Names of the `tool/ci/check-*.py` scripts a block of shell or YAML actually runs.

    Two refinements, both of them earned the hard way in this check's own self-test:

    * Only a line that names an interpreter counts. Every entry point labels its step with the
      script name (`run_step o "Cross-language parity (check-parity.py)" …`), and counting bare
      mentions made a label look like an invocation — so deleting the real invocation and
      leaving the label in place passed the check, which is precisely the false pass the first
      self-test fault was injected to find. The limitation is that a direct `./tool/ci/check-x.py`
      would not count; all five are invoked through `python3` in all three lists.
    * A `--self-test` run does not count: it exercises the checker's own fixtures, not the
      repository. The window is character-based rather than a pattern because the three entry
      points spell it differently (`check-x.py --self-test`, `"$1/check-x.py" --self-test`).
    """
    out: Set[str] = set()
    for line in text.splitlines():
        if "python3" not in line and "python " not in line:
            continue
        for m in re.finditer(r"(check-[\w-]+\.py)(.{0,24})", line):
            if "--self-test" in m.group(2):
                continue
            out.add(m.group(1))
    return out


def _between(text: str, start: str, stop: str) -> str:
    """The block between two column-anchored lines, or '' if either is missing."""
    m = re.search(re.escape(start) + r"\n(.*?)" + stop, text, re.S | re.M)
    return m.group(1) if m else ""


def check_ci_checkers(repo: Repo) -> Result:
    """Do all three entry points run the same static checkers?

    `ci.yml`'s `checks` job, `run-pipeline.sh`'s `job_checks` and `collect-checks.sh`'s `docs`
    group are three hand-maintained lists of the same five scripts, and the claim they exist to
    support — "a green local run is evidence about the remote one" (`docs/10` §10), "every check
    in the repository, one pass" (`docs/12`) — is only true while the three agree. `ci-jobs`
    compares the *job* names and cannot see a step missing inside one of them, which is how
    `check-ps1.py` came to be run by nothing automated at all: it had a `make` target, three
    lists that did not mention it, and a Windows entry point nobody was checking.
    """
    wf = repo.root / ".github" / "workflows" / "ci.yml"
    pipe = repo.root / "tool" / "ci" / "run-pipeline.sh"
    coll = repo.root / "tool" / "ci" / "collect-checks.sh"
    blocks = {
        "ci.yml's checks job": _between(repo.read(".github/workflows/ci.yml"), "  checks:",
                                        r"^  [a-z][a-z0-9-]*:$") if wf.exists() else "",
        "run-pipeline.sh's job_checks": _between(pipe.read_text(encoding="utf-8"),
                                                 "job_checks() {", r"^}$") if pipe.exists() else "",
        "collect-checks.sh's docs group": _between(coll.read_text(encoding="utf-8"),
                                                   "if selected docs; then", r"^fi$")
                                          if coll.exists() else "",
    }
    problems: List[str] = []
    sets = {name: _checker_invocations(text) for name, text in blocks.items()}
    for name, found in sets.items():
        if not found:
            problems.append(f"no checker invocations could be read out of {name}, so its "
                            f"agreement with the other two is unverifiable")
    union: Set[str] = set().union(*sets.values()) if sets else set()
    for name, found in sets.items():
        for c in sorted(union - found):
            problems.append(
                f"{name} does not run tool/ci/{c}, which the other entry points do: the three "
                f"lists are hand-maintained and this one has drifted, so a green run of it "
                f"says less than docs/10 §10 and docs/12 claim")
    on_disk = {f.name for f in (repo.root / "tool" / "ci").glob("check-*.py")}
    for c in sorted(on_disk - union):
        problems.append(
            f"tool/ci/{c} exists but no entry point runs it — the check-ps1.py case: a checker "
            f"with a make target and no automation, which is indistinguishable from no checker")
    return Result("ci-checkers", not problems,
                  f"{len(union & on_disk) if on_disk else len(union)} checkers run by all three "
                  f"entry points", problems)


CHECKS = [
    check_ci_jobs,
    check_ci_checkers,
    check_section_counts,
    check_dart_cli_flags,
    check_media_sections,
    check_e2ee_sections,
    check_make_targets,
    check_ps1_targets,
    check_ci_script_flags,
    check_help_covers_targets,
    check_doc_section_refs,
    check_npm_scripts,
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
    ("e2ee-sections", "docs/12-cli-cheat-sheet.md", "make e2ee SECT=churn",
     lambda s: s.replace("make e2ee SECT=churn", "make e2ee SECT=churnn", 1), "churnn"),
    ("make-targets", "docs/12-cli-cheat-sheet.md", "make checks-list",
     lambda s: s.replace("make checks-list", "make checks-listt", 1), "checks-listt"),
    ("ps1-targets", "make.ps1", "    'ci'          =",
     lambda s: s.replace("    'ci'          =", "    'bogus'       = 'tool/ci/nope.sh'\n"
                                                "    'ci'          =", 1), "bogus"),
    # the drift this check was written for: a job added to one list and not the other
    ("ci-jobs", "tool/ci/run-pipeline.sh", 'JOBS_ALL="checks web',
     lambda s: s.replace('JOBS_ALL="checks web', 'JOBS_ALL="checks bogus web', 1), "bogus"),
    # the real regression: a job that ran and was gated on, but that --list and --job both forgot
    ("ci-jobs", "tool/ci/run-pipeline.sh", "checks     Toolchain-free static checks",
     lambda s: re.sub(r"^checks\s+Toolchain-free.*\n", "", s, count=1, flags=re.M), "checks"),
    # the real regression: a checker with a make target that no pipeline called, so the
    # Windows entry point was validated only when a human remembered to type the command
    ("ci-checkers", "tool/ci/run-pipeline.sh", '"$ROOT" python3 tool/ci/check-ps1.py make.ps1',
     lambda s: s.replace('"$ROOT" python3 tool/ci/check-ps1.py make.ps1', '"$ROOT" true', 1),
     "check-ps1.py"),
    ("ci-checkers", "tool/ci/collect-checks.sh", 'python3 "$HERE/check-parity.py"',
     lambda s: s.replace('python3 "$HERE/check-parity.py"', "true", 1), "check-parity.py"),
    ("ci-script-flags", "docs/10-local-development-and-ci.md", "run-pipeline.sh --job",
     lambda s: s.replace("run-pipeline.sh --job", "run-pipeline.sh --jobs", 1), "--jobs"),
    # the real regression: a pattern that cannot see a digit hides check-ps1 from help
    ("help-covers-targets", "Makefile", "^[a-zA-Z0-9_-]+:",
     lambda s: s.replace("^[a-zA-Z0-9_-]+:", "^[a-zA-Z_-]+:", 1), "check-ps1"),
    ("npm-scripts", "docs/12-cli-cheat-sheet.md", "npm run e2ee",
     lambda s: s.replace("npm run e2ee", "npm run e2ee2", 1), "e2ee2"),
    # the real regression: a count that went stale while every name still resolved
    ("section-counts", "README.md", "# 18 sections",
     lambda s: s.replace("# 18 sections", "# 17 sections", 1), "17 sections"),
    # a citation to a section that does not exist: the renumbering case
    ("doc-section-refs", "docs/07-e2ee-noise-xx.md", "`docs/02` §6",
     lambda s: s.replace("`docs/02` §6", "`docs/02` §96", 1), "§96"),
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
        (tmp / "skills").mkdir(parents=True, exist_ok=True)
        (tmp / "roadmap").mkdir(parents=True, exist_ok=True)
        for d in sorted((ROOT / "skills").glob("*.md")):
            shutil.copy2(d, tmp / "skills" / d.name)
        for d in sorted((ROOT / "roadmap").glob("*.md")):
            shutil.copy2(d, tmp / "roadmap" / d.name)
        if (ROOT / "README.md").exists():
            shutil.copy2(ROOT / "README.md", tmp / "README.md")
        for sh in sorted((ROOT / "tool/ci").glob("*.sh")):
            shutil.copy2(sh, tmp / "tool/ci" / sh.name)
        # ci-checkers also asks whether every `check-*.py` on disk is run by something, so the
        # copy needs the checkers themselves or that half of the rule is vacuous in the fixture.
        for py in sorted((ROOT / "tool/ci").glob("check-*.py")):
            shutil.copy2(py, tmp / "tool/ci" / py.name)
        # ci-jobs compares the workflow against run-pipeline.sh, so the self-test's copy needs
        # the workflow too. Without it the unmutated copy fails and every fault below it is
        # meaningless — which is exactly what the guard under this block is for, and why it
        # printed instead of quietly passing nine checks and skipping the tenth.
        wf = ROOT / ".github" / "workflows" / "ci.yml"
        if wf.exists():
            (tmp / ".github" / "workflows").mkdir(parents=True, exist_ok=True)
            shutil.copy2(wf, tmp / ".github" / "workflows" / "ci.yml")

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
