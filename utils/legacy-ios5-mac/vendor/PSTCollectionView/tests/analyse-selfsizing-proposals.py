#!/usr/bin/env python3
"""Validate a one-column native proposal-cache hypothesis; NOT a PST parity gate.

Input: artifacts from trace-selfsizing-steps.sh SIM --matrix.
Model: preserve known fitted sizes; after a preferred invalidation batch, assign the
running mean to unknown items starting one item before the batch's first index.
Do not infer batching, multi-column behaviour, pixel rounding, or full layout parity.
"""
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
def records(path):
    value = [json.loads(line) for line in path.read_text().splitlines()]
    assert len(value) == 6, path
    return value

pairs = [(root / 'native.jsonl', root / 'native-events.jsonl')]
pairs += [(path, path.with_name(path.stem + '-events.jsonl'))
          for path in sorted(root.glob('native-v*.jsonl')) if '-events' not in path.stem]
failures = 0
for plain_path, event_path in pairs:
    plain, instrumented = records(plain_path), records(event_path)
    fields = ('frames', 'fittings', 'requests', 'visible', 'contentHeight', 'offset')
    transparent = all(all(a[key] == b[key] for key in fields) for a, b in zip(plain, instrumented))
    if not transparent:
        print('REJECT instrumented subclass changed baseline:', plain_path.name)
        failures += 1
        continue
    reported = {}
    proposals = [40.] * 60
    errors = []
    batches = 0
    for record in instrumented:
        assert len(record['frames']) == 60
        for event in record['events']:
            if event[0] == 'fit':
                reported[event[1]] = event[3]
            elif event[0] == 'invalidate' and event[1] and reported:
                # Only this probe's preferred invalidations are modelled.
                first = max(0, min(event[1]) - 1)
                mean = sum(reported.values()) / len(reported)
                for index in range(first, 60):
                    if index not in reported:
                        proposals[index] = mean
                batches += 1
        for index, frame in enumerate(record['frames']):
            predicted = reported.get(index, proposals[index])
            if abs(predicted - frame[1]) > 1e-6:
                errors.append((record['phase'], index, predicted, frame[1]))
    if errors:
        print('COUNTEREXAMPLE', plain_path.name, errors[:10])
        failures += 1
    else:
        print('MODEL MATCH', plain_path.name, f'{batches} invalidation batches; 360 item heights; instrumentation unchanged')
print('Scope: native one-column HEIGHT model only; no PST/frame/batching/multi-column parity claim')
sys.exit(1 if failures else 0)
