# Daily run — 20261028T030850Z

| | |
| --- | --- |
| Commit | `3ed1af9` |
| Branch | `arena/ff85cb12-dumanmessenger` |
| Mode | full, with evidence probes |
| Elapsed | 3757s |
| dart | 3.13.7 |
| node | /mnt/c/Users/Administrator/Desktop/Git-Clones/DumanMessenger/tool/ci/lib.sh: line 58: /home/administrator/bin/node: Permission denied |
| Verdict | **GREEN** (exit 0) |

## Compared with the previous run

(no previous daily run to compare against)

## What that verdict means

Everything that could run, ran and passed, and nothing was skipped.

## What this machine cannot do

9 blocker(s) probed before the run, 1 of them repairable from here.

Of the 28 open roadmap items, 0 can be closed on this machine. The other 28 need
a handset, a store account and signing key, a Dart/Flutter toolchain that is not
installable from here, or a crowd of people carrying phones — `blockers.txt` lists
every item with the rule that classified it and the probe behind each row.

> 1 row(s) are repairable here (`node`); none of them is the checkout, so the results
> below describe the pushed work.

## The two halves

| half | exit | reading |
| --- | ---: | --- |
| CI mirror (`run-pipeline.sh`) | 0 | green |
| checks (`collect-checks.sh`) | 0 | 30 passed, 0 failed, 0 could not run |

## Files in this directory

* `DAILY.md` — this page
* `REPORT.md` — the check table, one row per check, with what each was verified against
* `pipeline.txt`, `checks.txt` — full output of each half
* `pipeline/`, `checks.json`, `pipeline.json` — per-step artifacts and machine-readable results
* `blockers.txt`, `blockers.json` — what this machine cannot do, probed before the run
* `evidence-*.txt` — the probes that reproduce the numbers published in docs/06-docs/09
