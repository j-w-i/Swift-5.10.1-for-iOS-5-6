#!/usr/bin/env python3
"""Compare native vs PST display events structurally.

Per pass (split on '--' markers) require: identical multiset of events; all
'end' events before all 'will' events; within wills, cells before supplementary
views; within ends, cells before supplementary views. UIKit's own retire order
among views is an unspecified hash order, so only the structure is compared.
"""
import sys
def passes(path):
    out, cur = [], []
    for l in open(path).read().split('\n'):
        if not l: continue
        if l.startswith('--'):
            out.append((cur)); cur = []
        else: cur.append(l)
    out.append(cur); return out
def structure_ok(p):
    kinds = [x.split()[0] for x in p]
    if 'will' in kinds and 'end' in kinds and kinds.index('will') < len(kinds)-1-kinds[::-1].index('end'): return 'will before end'
    for k in ('will', 'end'):
        seq = [x.split()[1] for x in p if x.split()[0] == k]
        if 'supp' in seq and 'cell' in seq and seq.index('supp') < len(seq)-1-seq[::-1].index('cell'): return k + ': supplementary before cell'
    return None
n, p = passes(sys.argv[1]), passes(sys.argv[2])
bad = 0
if len(n) != len(p): print('FAIL: pass count', len(n), len(p)); sys.exit(1)
for i, (a, b) in enumerate(zip(n, p)):
    if sorted(a) != sorted(b): print(f'FAIL pass {i}: event sets differ\n native={a}\n pst={b}'); bad = 1
    for name, x in (('native', a), ('pst', b)):
        e = structure_ok(x)
        if e: print(f'FAIL pass {i} {name}: {e}'); bad = 1
sys.exit(bad)
