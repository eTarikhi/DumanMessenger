#!/usr/bin/env python3
"""Intentional reference-fixture creation; review alongside authoritative tests."""
import json
import sys
from pathlib import Path

source = json.loads(Path(sys.argv[1]).read_text())
rows = []
for r in source['rows']:
    if r['seed'] == 42 and r['split'] in ['train', 'smoke']:
        rows.append(dict(scenario=r['scenario'], seed=r['seed'], duty=r['duty'],
                         strategy=r['strategy'], sent=r['sent'], delivered=r['delivered'],
                         withinFive=r['withinFive'], withinThree=round(r['threeRatio'] * r['sent']),
                         relays=r['stats']['totalForwarded'], retries=r['stats']['retriesSent']))
if len(rows) != 48:
    raise ValueError(f'Expected 48 reference cases; found {len(rows)}')
print(json.dumps(dict(version=1, sourceSha=source['sourceSha'],
                     note='150 acc-N text unicasts, independent traffic seed, gap 1500 ms, no drain; no baseline golden replaced',
                     rows=rows), indent=2))
