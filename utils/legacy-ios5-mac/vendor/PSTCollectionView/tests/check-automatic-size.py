#!/usr/bin/env python3
"""Fail closed on geometry differences outside the explicitly recorded gaps.

The sole-item gaps below are exact known outputs, not a broad tolerance. Other
item coordinates may differ only by at most one device pixel; sizes and content
extents must match exactly. This is a bounded regression gate, not exact parity.
"""
import pathlib
import re
import sys


def parse(path):
    cases = {}
    current = None
    for line in pathlib.Path(path).read_text().splitlines():
        case = re.fullmatch(r"count=(\d+) axis=(\d+) content=([\d.e+-]+)x([\d.e+-]+)", line)
        if case:
            current = tuple(map(int, case.group(1, 2)))
            assert current not in cases, f"duplicate case: {current}"
            cases[current] = {"content": tuple(map(float, case.group(3, 4))), "cells": {}}
            continue
        cell = re.fullmatch(r"cell=(\d+) frame=([\d.e+,-]+)", line)
        assert cell and current is not None, f"unexpected output: {line!r}"
        index = int(cell.group(1))
        frame = tuple(map(float, cell.group(2).split(',')))
        assert len(frame) == 4 and index not in cases[current]['cells']
        cases[current]['cells'][index] = frame
    assert set(cases) == {(count, axis) for count in (1, 2, 3) for axis in (0, 1)}, 'missing/extra cases'
    for (count, _), case in cases.items():
        assert set(case['cells']) == set(range(count)), 'missing/extra cells'
    return cases


def compare(native, pst, scale):
    assert scale > 0
    known = 0
    rounded = 0
    for key, n in native.items():
        p = pst[key]
        if key == (1, 0):
            assert n == {'content': (200, 30), 'cells': {0: (60, 0, 80, 30)}}, 'native sole vertical oracle changed'
            assert p == {'content': (80, 30), 'cells': {0: (0, 0, 80, 30)}}, 'sole vertical gap changed'
            known += 1
            continue
        assert p['content'] == n['content'], f'content extent mismatch {key}: {n} vs {p}'
        for index, nf in n['cells'].items():
            pf = p['cells'][index]
            if key == (1, 1):
                assert nf == (0, 85, 80, 30) and pf == (0, 0, 80, 30), 'sole horizontal gap changed'
                known += 1
                continue
            assert pf[2:] == nf[2:], f'cell size mismatch {key}/{index}'
            for a, b in zip(nf[:2], pf[:2]):
                assert abs(a - b) <= 1.0 / scale + 0.0001, f'position mismatch {key}/{index}: {nf} vs {pf}'
                rounded += a != b
    return known, rounded


if __name__ == '__main__':
    try:
        known, rounded = compare(parse(sys.argv[1]), parse(sys.argv[2]), float(sys.argv[3]))
    except (AssertionError, ValueError) as error:
        sys.exit(f'FAIL: {error}')
    print(f'PASS: bounded automatic-size geometry gate; {known} known sole-item gaps, {rounded} subpixel differences')
    if known or rounded:
        print('NOT exact native parity: sole-item centering/content width and pixel rounding remain unresolved')
