#!/usr/bin/env python3
"""Regression: a failing command inside a build stage must stop before stamping."""
from pathlib import Path
import subprocess
import tempfile

script = Path(__file__).resolve().parents[1] / 'build-all.sh'
text = script.read_text()
start = text.index('stage() {')
end = text.index('\nwhile [ $#', start)
function = text[start:end]
with tempfile.TemporaryDirectory(prefix='legacy-stage-test-') as temporary:
    root = Path(temporary)
    (root / 'logs').mkdir()
    (root / '.stamps').mkdir()
    common = 'set -euo pipefail\nROOT="$1"; L="$ROOT/logs"\n' + function
    failed = subprocess.run(['bash', '-c', common + '''
broken() { false; touch "$ROOT/incorrectly-continued"; }
stage broken broken
''', 'test', str(root)], capture_output=True, text=True)
    assert failed.returncode != 0, failed.stdout + failed.stderr
    assert not (root / 'incorrectly-continued').exists()
    assert not (root / '.stamps/broken').exists()
    succeeded = subprocess.run(['bash', '-c', common + '''
working() { touch "$ROOT/success"; }
stage working working
''', 'test', str(root)], capture_output=True, text=True)
    assert succeeded.returncode == 0, succeeded.stdout + succeeded.stderr
    assert (root / 'success').exists()
    assert (root / '.stamps/working').exists()
print('PASS: stage failure stops execution; only successful stages are stamped')
