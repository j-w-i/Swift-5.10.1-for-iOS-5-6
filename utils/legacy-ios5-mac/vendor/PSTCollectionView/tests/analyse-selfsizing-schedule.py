#!/usr/bin/env python3
"""Compare a scheduling prototype's trace artifacts, without hiding grid/work gaps.
Usage: analyse-selfsizing-schedule.py ARTIFACT_DIRECTORY [--baseline-exact]
The optional gate requires exact baseline geometry/visibility/content and fitting
COUNTS, not call order or equal data-source work. Grid differences remain diagnostics.
"""
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
gate = len(sys.argv) > 2 and sys.argv[2] == '--baseline-exact'
errors = 0
files = [root / 'pst.jsonl', *sorted(root.glob('pst-c*.jsonl'))]
for path in files:
    pst = [json.loads(line) for line in path.read_text().splitlines()]
    native_path = path.with_name(path.name.replace('pst', 'native', 1))
    native = [json.loads(line) for line in native_path.read_text().splitlines()]
    assert len(pst) == len(native) == 6
    for a, b in zip(pst, native):
        assert a['phase'] == b['phase'] and len(a['rects']) == len(b['rects']) == 60
        rectangles = sum(max(abs(x - y) for x, y in zip(r, s)) > 1e-6
                         for r, s in zip(a['rects'], b['rects']))
        content = abs(a['contentHeight'] - b['contentHeight']) <= 1e-6
        visibility = a['visible'] == b['visible']
        fits = len(a['fittings']) == len(b['fittings'])
        budget = a.get('scheduleBudgetHit', False)
        print(path.stem, a['phase'], 'rect_errors=', rectangles,
              'content_equal=', content, 'visible_equal=', visibility,
              'PST/native fittings=', (len(a['fittings']), len(b['fittings'])),
              'PST/native requests=', (a['requests'], b['requests']), 'budget_hit=', budget)
        if budget:
            errors += 1
        if gate and path.name == 'pst.jsonl':
            assert 'scheduleBudgetHit' in a
            if rectangles or not content or not visibility or not fits:
                errors += 1
if gate:
    print('BASELINE EXACT GATE:', 'FAIL' if errors else 'PASS',
          '(geometry/content/visibility/fitting counts only; NOT full parity)')
print('Grid diagnostics, request counts, fitting order and broader cases must not be treated as passing parity.')
sys.exit(1 if errors else 0)
