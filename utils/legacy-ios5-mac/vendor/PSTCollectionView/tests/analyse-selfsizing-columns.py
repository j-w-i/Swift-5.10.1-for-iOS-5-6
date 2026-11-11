#!/usr/bin/env python3
"""Compare competing fixed-width native cache models; diagnostic, not a PST parity gate."""
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
def records(path):
    result = [json.loads(line) for line in path.read_text().splitlines()]
    assert len(result) == 6, path
    return result

def replay(rows, columns, boundary, changed_only):
    reported, proposals, errors = {}, [40.] * 60, []
    for record in rows:
        for event in record['events']:
            if event[0] == 'fit':
                index, original, preferred = event[1], event[2][3], event[3]
                if not changed_only or index in reported or abs(original - preferred) > 1e-7:
                    reported[index] = preferred
            elif event[0] == 'invalidate' and event[1] and reported:
                first = min(event[1])
                if boundary == 'previous-item':
                    start = max(0, first - 1)
                elif boundary == 'current-row':
                    start = (first // columns) * columns
                elif boundary == 'previous-row':
                    start = max(0, ((first // columns) - 1) * columns)
                else:
                    start = (max(0, first - 1) // columns) * columns
                mean = sum(reported.values()) / len(reported)
                for index in range(start, 60):
                    if index not in reported:
                        proposals[index] = mean
        for index, frame in enumerate(record['frames']):
            predicted = reported.get(index, proposals[index])
            if abs(predicted - frame[1]) > 1e-6:
                errors.append((record['phase'], index, predicted, frame[1]))
    return errors

configurations = 0
item_boundary_rejected = False
all_reports_rejected = False
for plain_path in sorted(root.glob('native-c*.jsonl')):
    if '-events' in plain_path.stem:
        continue
    plain = records(plain_path)
    instrumented = records(plain_path.with_name(plain_path.stem + '-events.jsonl'))
    fields = ('frames', 'rects', 'fittings', 'requests', 'visible', 'contentHeight', 'offset')
    assert all(all(a[k] == b[k] for k in fields) for a, b in zip(plain, instrumented)), ('instrumentation changed results', plain_path)
    width = plain[0]['itemWidth']
    columns = int(200 // width)
    assert columns in (2, 3)
    assert all(len(row['rects']) == 60 and all(abs(r[2] - width) < 1e-6 for r in row['rects']) for row in plain)
    configurations += 1
    print('CONFIG', plain_path.name, f'columns={columns}; instrumentation unchanged')
    matches = []
    best = None
    for boundary in ('previous-item', 'current-row', 'previous-row', 'row-containing-previous-item'):
        for changed_only in (False, True):
            label = boundary + ('/changed-only' if changed_only else '/all-reports')
            errors = replay(instrumented, columns, boundary, changed_only)
            print(' ', label, 'height_errors=', len(errors))
            if label == 'previous-item/changed-only' and errors:
                item_boundary_rejected = True
            if label == 'previous-row/all-reports' and errors:
                all_reports_rejected = True
            if not errors:
                matches.append(label)
            if best is None or len(errors) < len(best[1]):
                best = (label, errors)
    if matches:
        print(' MATCHING HYPOTHESES', matches)
    else:
        print(' NO MATCH; best counterexamples', best[0], best[1][:5])
    assert 'previous-row/changed-only' in matches, ('selected hypothesis rejected', plain_path)
assert configurations == 4 and item_boundary_rejected and all_reports_rejected
print('NATIVE MODEL MATCH: 1440 heights; counterexamples reject item-only boundary and caching all reports')
print('Scope: fixed-width native HEIGHT hypotheses only; no PST, batching, origins or general-layout parity claim')
