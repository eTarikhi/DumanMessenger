#!/usr/bin/env python3
"""Turn captured `dart analyze` / `dart test` / CLI output into diagnostics.

This is the *same* parser the CI workflow calls. It used to be an inline heredoc in
`.github/workflows/ci.yml`, which meant the local runner either had to duplicate it —
and then the two could drift, so a local run would report something different from the
remote one — or go without it. Extracting it makes "did my build pass" mean the same
thing in both places, which is the entire reason to have a local runner.

Three output formats:

  github  `::error file=...,line=...::` workflow commands plus a `$GITHUB_STEP_SUMMARY`
          section. This is what CI consumes, and it is why a red Dart build here reports
          the analyzer, the test failures *and* the CLI metrics with real file paths —
          the runner's generic problem matcher loses the paths.
  text    a readable report for a terminal. The default when not in CI.
  json    machine-readable, for `validate-and-push.sh` to record what actually failed.

Exit status is 0 whenever the inputs parsed, including when they describe failures:
deciding whether the build passed is the Gate step's job, not the parser's. A nonzero
exit means the parser itself broke, and the workflow marks this step
`continue-on-error` so that a bug here cannot fail an otherwise green build.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional, Tuple

MAX_ANALYZE_ANNOTATIONS = 20
MAX_TEST_ANNOTATIONS = 20
CLIP_AT = 1200


def read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read().strip()
    except OSError:
        return "(no output captured)"


def escape(text: str) -> str:
    """Workflow-command escaping: `%`, CR and LF are significant in `::` lines."""
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def clip(text: str, limit: int = CLIP_AT) -> str:
    text = text.strip()
    return text if len(text) <= limit else text[:limit] + " …(clipped)"


def analyze_issues(text: str) -> List[Tuple[str, str, str, str, str, str]]:
    """Parse `dart analyze` lines of the form '<severity> • <field> • <field> • <code>'.

    Which field holds the location differs between SDK versions, so pick the one that
    ends in :line:col rather than assuming a position.
    """
    issues: List[Tuple[str, str, str, str, str, str]] = []
    for line in text.splitlines():
        parts = [p.strip() for p in line.split(" • ")]
        if len(parts) < 3 or parts[0] not in ("error", "warning", "info"):
            continue
        loc = next((p for p in parts if re.search(r":\d+:\d+$", p)), None)
        if loc is None:
            continue
        path, line_no, col = loc.rsplit(":", 2)
        rest = [p for p in parts[1:] if p != loc]
        code = rest[-1] if rest else ""
        message = " • ".join(rest[:-1]) if len(rest) > 1 else code
        issues.append((parts[0], path, line_no, col, code, message))
    return issues


def test_failures(text: str) -> List[Dict[str, Optional[str]]]:
    """Group the expanded reporter's output into one entry per failing test.

    A failure starts at '<mm:ss> +n -m: <name> [E]' and runs until the next timestamped
    line; the first 'file.dart line:col' frame gives the location.
    """
    failures: List[Dict[str, Any]] = []
    current: Optional[Dict[str, Any]] = None
    for line in text.splitlines():
        header = re.match(r"^\d{2}:\d{2} \+\d+(?: -\d+)?: (.*?) \[E\]\s*$", line)
        if header:
            if current:
                failures.append(current)
            current = {"name": header.group(1), "detail": []}
            continue
        if current is None:
            continue
        if re.match(r"^\d{2}:\d{2} \+\d+", line):
            failures.append(current)
            current = None
            continue
        current["detail"].append(line)
    if current:
        failures.append(current)

    located: List[Dict[str, Optional[str]]] = []
    for failure in failures:
        detail: List[str] = failure["detail"]
        frame = next(
            (
                re.match(r"^\s*((?:test|lib|bin)/\S+\.dart) (\d+):(\d+)", line)
                for line in detail
                if re.match(r"^\s*((?:test|lib|bin)/\S+\.dart) (\d+):(\d+)", line)
            ),
            None,
        )
        body = [l for l in detail if not re.match(r"^\s*\S+\.dart \d+:\d+\s", l)]
        located.append(
            {
                "name": failure["name"],
                "path": frame.group(1) if frame else None,
                "line": frame.group(2) if frame else None,
                "col": frame.group(3) if frame else None,
                "message": clip("\n".join(body).strip() or "(no detail captured)"),
            }
        )
    return located


def failing_test_text(text: str) -> str:
    failures = test_failures(text)
    if not failures:
        return "(no test failures in the captured output)"
    out = []
    for f in failures:
        where = (
            "%s:%s:%s" % (f["path"], f["line"], f["col"])
            if f["path"]
            else "location unknown"
        )
        out.append("%s\n  at %s\n%s" % (f["name"], where, f["message"]))
    return "\n\n".join(out)


def test_summary(text: str) -> Dict[str, int]:
    """Passed/failed/skipped counts from the expanded reporter's progress lines.

    Best-effort by design: the reporter's last `+passed -failed` line is the truth when
    there is one, and when the run died before printing one the counts stay zero and the
    failure list above carries the information instead.
    """
    passed = failed = skipped = 0
    for line in text.splitlines():
        m = re.match(r"^\d{2}:\d{2} \+(\d+)(?: ~(\d+))?(?: -(\d+))?(?::| All tests)", line)
        if m:
            passed = int(m.group(1))
            skipped = int(m.group(2) or 0)
            failed = int(m.group(3) or 0)
    return {"passed": passed, "failed": failed, "skipped": skipped}


def analyze_severity_counts(issues: List[Tuple[str, str, str, str, str, str]]) -> Dict[str, int]:
    out = {"error": 0, "warning": 0, "info": 0}
    for severity, *_ in issues:
        out[severity] = out.get(severity, 0) + 1
    return out


def emit_github(analyze_out: str, test_out: str, cli_out: str) -> Dict[str, Any]:
    """Workflow commands on stdout, narrative into $GITHUB_STEP_SUMMARY."""
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY") or os.devnull
    issues = analyze_issues(analyze_out)

    emitted = 0
    for severity, path, line_no, col, code, message in issues:
        if emitted >= MAX_ANALYZE_ANNOTATIONS:
            print(
                "::warning::More analyzer issues than fit the annotation budget "
                "— see the job summary."
            )
            break
        level = "notice" if severity == "info" else severity
        print(
            "::%s file=%s,line=%s,col=%s,title=dart analyze: %s::%s"
            % (level, path, line_no, col, code or severity, escape(message))
        )
        emitted += 1

    failures = test_failures(test_out)
    emitted = 0
    for failure in failures:
        if emitted >= MAX_TEST_ANNOTATIONS:
            print(
                "::warning::More failing tests than fit the annotation budget "
                "— see the job summary."
            )
            break
        location = ""
        if failure["path"]:
            location = " file=%s,line=%s,col=%s" % (
                failure["path"],
                failure["line"],
                failure["col"],
            )
        print(
            "::error%s,title=dart test: %s::%s"
            % (location, escape(clip(str(failure["name"]), 200)), escape(str(failure["message"])))
        )
        emitted += 1

    tail = "\n".join(test_out.splitlines()[-25:]) or test_out
    with open(summary_path, "a", encoding="utf-8") as summary:
        summary.write("### dart analyze\n\n```\n%s\n```\n\n" % analyze_out)
        summary.write("### dart test — failures\n\n```\n%s\n```\n\n" % failing_test_text(test_out))
        summary.write("### dart test — tail\n\n```\n%s\n```\n\n" % tail)
        summary.write("### CLI acceptance (campus_quad, seed 42)\n\n```\n%s\n```\n" % cli_out)

    return {"analyze_issues": issues, "test_failures": failures}


def emit_text(analyze_out: str, test_out: str, cli_out: str) -> Dict[str, Any]:
    issues = analyze_issues(analyze_out)
    failures = test_failures(test_out)
    counts = analyze_severity_counts(issues)
    totals = test_summary(test_out)

    print("dart analyze — %d error(s), %d warning(s), %d info(s)"
          % (counts["error"], counts["warning"], counts["info"]))
    if issues:
        for severity, path, line_no, col, code, message in issues[:MAX_ANALYZE_ANNOTATIONS]:
            print("  %-7s %s:%s:%s  %s  %s" % (severity, path, line_no, col, code, message))
        if len(issues) > MAX_ANALYZE_ANNOTATIONS:
            print("  … and %d more" % (len(issues) - MAX_ANALYZE_ANNOTATIONS))
    else:
        print("  (no analyzer issues with a location; raw output below if non-empty)")
        if analyze_out and "No issues found" not in analyze_out:
            for line in analyze_out.splitlines()[:20]:
                print("  | %s" % line)

    print("")
    print("dart test — %d passed, %d failed, %d skipped"
          % (totals["passed"], totals["failed"], totals["skipped"]))
    if failures:
        for f in failures[:MAX_TEST_ANNOTATIONS]:
            where = "%s:%s:%s" % (f["path"], f["line"], f["col"]) if f["path"] else "location unknown"
            print("  FAIL %s\n       at %s" % (f["name"], where))
            for line in str(f["message"]).splitlines()[:12]:
                print("       %s" % line)
        if len(failures) > MAX_TEST_ANNOTATIONS:
            print("  … and %d more" % (len(failures) - MAX_TEST_ANNOTATIONS))
    else:
        print("  (no failing tests parsed)")

    print("")
    print("CLI acceptance (campus_quad, seed 42) — last 15 lines")
    for line in (cli_out.splitlines()[-15:] or ["(no output captured)"]):
        print("  | %s" % line)

    return {"analyze_issues": issues, "test_failures": failures}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--analyze", default="/tmp/dart-analyze.txt")
    parser.add_argument("--test", default="/tmp/dart-test.txt", dest="test_file")
    parser.add_argument("--cli", default="/tmp/dart-cli.txt")
    parser.add_argument("--format", choices=("github", "text", "json"),
                        default="github" if os.environ.get("GITHUB_ACTIONS") else "text")
    parser.add_argument("--out", help="also write the parsed result as JSON to this path")
    args = parser.parse_args()

    analyze_out = read(args.analyze)
    test_out = read(args.test_file)
    cli_out = read(args.cli)

    if args.format == "github":
        parsed = emit_github(analyze_out, test_out, cli_out)
    elif args.format == "json":
        parsed = {
            "analyze": analyze_severity_counts(analyze_issues(analyze_out)),
            "analyze_issues": [
                {"severity": s, "path": p, "line": l, "col": c, "code": code, "message": m}
                for s, p, l, c, code, m in analyze_issues(analyze_out)
            ],
            "test": test_summary(test_out),
            "test_failures": test_failures(test_out),
            "cli_tail": cli_out.splitlines()[-15:],
        }
        print(json.dumps(parsed, indent=2))
    else:
        parsed = emit_text(analyze_out, test_out, cli_out)

    if args.out:
        record = {
            "analyze_issues": [
                {"severity": s, "path": p, "line": l, "col": c, "code": code, "message": m}
                for s, p, l, c, code, m in parsed.get("analyze_issues", [])
            ],
            "test_failures": parsed.get("test_failures", []),
            "test": test_summary(test_out),
            "analyze": analyze_severity_counts(analyze_issues(analyze_out)),
        }
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(record, handle, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
