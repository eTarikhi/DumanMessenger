#!/usr/bin/env python3
"""Flat per-seed review table; full config remains in companion JSON."""
import csv
import json
import sys
from pathlib import Path

writer = csv.writer(sys.stdout)
writer.writerow(['split', 'scenario', 'duty', 'seed', 'strategy', 'sent', 'delivered',
                 'withinFive', 'fiveRatio', 'deliveryRatio', 'threeRatio', 'hopsMean', 'hopsP95',
                 'relayTx', 'totalTx', 'latencyMeanMs', 'latencyP95Ms', 'retries', 'retriesExhausted',
                 'undeliveredAtHorizon', 'queuedCopies', 'flapsPerNodeMin', 'normalPercentPerHour',
                 'superPercentPerHour'])
for path in sys.argv[1:]:
    for r in json.loads(Path(path).read_text())['rows']:
        writer.writerow([r[k] for k in ['split', 'scenario', 'duty', 'seed', 'strategy', 'sent',
                                       'delivered', 'withinFive', 'fiveRatio', 'deliveryRatio',
                                       'threeRatio', 'hopsMean', 'hopsP95']] +
                        [r['stats']['totalForwarded'], r['totalTx'], r['latencyMeanMs'], r['latencyP95Ms'],
                         r['stats']['retriesSent'], r['stats']['retriesExhausted'], r['undeliveredAtHorizon'],
                         r['stats']['totalQueued'], r['stats']['roleChangesPerNodeMin'],
                         r['stats']['batteryPercentPerHourNormal'], r['stats']['batteryPercentPerHourSuper']])
