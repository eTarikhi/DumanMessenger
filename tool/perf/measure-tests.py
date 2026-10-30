#!/usr/bin/env python3
"""Full-suite timing/CPU evidence without changing discovery, assertions or budgets.
Raw profiles/reports stay in ignored tool/.build, never historical research paths.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import time
try:
    import resource
except ImportError:
    resource = None

parser = argparse.ArgumentParser()
parser.add_argument('--label', required=True)
parser.add_argument('--profile', action='store_true')
args = parser.parse_args()
if not args.label.replace('-', '').replace('_', '').isalnum():
    parser.error('label must be alphanumeric/dash/underscore')
root = pathlib.Path(__file__).resolve().parents[2]
out = root / 'tool/.build' / ('perf-' + args.label)
out.mkdir(parents=True, exist_ok=False)
cmd = ['node', 'node_modules/vitest/vitest.mjs', 'run', '--reporter=json', '--outputFile='+str(out/'tests.json')]
if args.profile:
    cmd += ['--execArgv=--cpu-prof', '--execArgv=--cpu-prof-dir='+str(out)]
start = time.monotonic()
with (out/'stdout.log').open('w') as log:
    result = subprocess.run(cmd, cwd=root, stdout=log, stderr=subprocess.STDOUT)
usage = resource.getrusage(resource.RUSAGE_CHILDREN) if resource else None
files = ['src/election.ts','src/simulation.ts','src/tq-history.ts','vitest.config.ts','package-lock.json']
metadata = dict(command=cmd, exit=result.returncode, wallSeconds=time.monotonic()-start,
    sourceHead=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
    node=subprocess.check_output(['node','--version'],text=True).strip(),
    npm=subprocess.check_output(['npm','--version'],text=True).strip(),
    sourceHashes={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files if (root/p).exists()},
    resources=dict(userSeconds=usage.ru_utime, systemSeconds=usage.ru_stime,
        maxChildRssKiB=usage.ru_maxrss, note='Unix maximum child RSS, not aggregate concurrent memory; Darwin reports bytes') if usage else None)
(out/'resources.json').write_text(json.dumps(metadata,indent=2)+'\n')
print(out)
raise SystemExit(result.returncode)
