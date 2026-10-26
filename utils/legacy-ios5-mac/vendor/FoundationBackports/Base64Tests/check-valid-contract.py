#!/usr/bin/env python3
"""Check the separate valid Swift Data contract; never rewrite raw differences."""
import json
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('Usage: check-valid-contract.py RESULTS_DIRECTORY')
path = Path(sys.argv[1])
contract = json.loads((path / 'valid-contract.json').read_text())
report = json.loads((path / 'results.json').read_text())
print('Raw differential mismatches (retained):', report['mismatchCount'])
if not contract['passed'] or contract['mismatchCount'] != 0 or contract['strictPaddingPolicyFailures']:
    raise SystemExit('FAIL: valid Data contract or strict padding policy failed: ' + repr(contract))
print('PASS: %d valid Data comparisons, zero mismatches; %d padding-policy checks' %
      (contract['comparisons'], contract['strictPaddingPolicyChecks']))
