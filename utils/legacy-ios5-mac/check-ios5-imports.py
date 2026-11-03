#!/usr/bin/env python3
"""Prove every strong import of an armv7 dylib/executable resolves on iOS 5.1.1.

A strong import the OS cannot satisfy is a launch-time dyld failure with no
recourse, so this is a hard gate. Resolution is two-level-namespace aware: a symbol
must be exported by the library the linker bound it to (or one it re-exports); the
same name existing in some unrelated image does not count. Weak imports are allowed (dyld binds them to
NULL) but are counted so a reviewer can confirm the code null-checks them.

Usage:
  check-ios5-imports.py [--reference ios5-reference/ios511-exports.json.gz] FILE...
  check-ios5-imports.py --runtime-dir DIR        # every *.dylib in DIR
  check-ios5-imports.py --self-test

Imports that name one of our own libswift*.dylib files are skipped (they are
validated by closure inside the runtime directory instead).
Exit codes: 0 pass, 1 unresolved strong import, 2 usage/IO error.
"""
import gzip
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_REFERENCE = HERE / "ios5-reference" / "ios511-exports.json.gz"


def load_reference(path):
    """Return {image path: frozenset(exports)} for the iOS 5.1.1 shared cache."""
    opener = gzip.open if str(path).endswith(".gz") else open
    with opener(path, "rt") as stream:
        images = json.load(stream)
    return {name: frozenset(exports) for name, exports in images.items()}


def providers(reference, library):
    """Images that can satisfy an import bound (two-level namespace) to `library`.

    dyld looks a symbol up only in the dylib the linker recorded, plus whatever that
    dylib re-exports. libSystem.B re-exports every /usr/lib/system/*.dylib; the other
    libraries are matched by install-name stem (libobjc -> libobjc.A, libc++ ->
    libc++.1 and libc++abi, Foundation -> Foundation.framework, ...).
    """
    if library is None:
        return list(reference)
    stem = library.split(".")[0]
    result = []
    for path in reference:
        base = Path(path).name
        if library == "libSystem":
            if path == "/usr/lib/libSystem.B.dylib" or path.startswith("/usr/lib/system/"):
                result.append(path)
        elif path.startswith("/System/Library/Frameworks/%s.framework/Frameworks/" % library):
            # Umbrella frameworks (Accelerate, CoreServices, ...) re-export the
            # sub-frameworks nested in their own Frameworks/ directory.
            result.append(path)
        elif base.split(".")[0] == stem or (stem == "libc++" and base.startswith("libc++abi")):
            result.append(path)
    return result


def imports_of(path):
    """Yield (symbol, weak, library) for each undefined symbol of an armv7 image."""
    out = subprocess.run(["/usr/bin/nm", "-arch", "armv7", "-m", str(path)],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise OSError("nm failed for %s: %s" % (path, out.stderr.strip()))
    pattern = re.compile(r"\(undefined\) (weak )?external (\S+)(?: \(from (\S+)\))?")
    for line in out.stdout.splitlines():
        match = pattern.search(line)
        if match:
            yield match.group(2), bool(match.group(1)), match.group(3)


def classify(imports, reference):
    """Split imports into (strong_unresolved, weak_unresolved).

    An import counts as resolved only if the exact library it is bound to (or what
    that library re-exports) exports it on iOS 5.1.1.
    """
    strong, weak = [], []
    cache = {}
    for symbol, is_weak, library in imports:
        if library and library.startswith("libswift"):
            continue  # resolved inside our own runtime directory
        if library not in cache:
            cache[library] = frozenset().union(
                *[reference[p] for p in providers(reference, library)]) \
                if providers(reference, library) else frozenset()
        if symbol in cache[library]:
            continue
        (weak if is_weak else strong).append((symbol, library))
    return strong, weak


def self_test():
    reference = {
        "/usr/lib/libSystem.B.dylib": frozenset({"_exit"}),
        "/usr/lib/system/libsystem_c.dylib": frozenset({"_malloc", "__NSGetEnviron"}),
        "/usr/lib/libobjc.A.dylib": frozenset({"_objc_msgSend"}),
        "/System/Library/PrivateFrameworks/Symbolication.framework/Symbolication":
            frozenset({"_environ"}),
    }
    reference["/System/Library/Frameworks/Accelerate.framework/Frameworks/vImage.framework/vImage"] = \
        frozenset({"_vImageBoxConvolve_ARGB8888"})
    synthetic = [("_vImageBoxConvolve_ARGB8888", False, "Accelerate"),  # umbrella re-export
                 ("_malloc", False, "libSystem"),                  # re-exported sublib
                 ("_environ", False, "libSystem"),                 # exists, but NOT in libSystem
                 ("_os_unfair_lock_lock", True, "libSystem"),      # weak, absent: tolerated
                 ("_class_setSuperclass", False, "libobjc"),
                 ("_x", False, "libswiftCore")]
    strong, weak = classify(synthetic, reference)
    assert strong == [("_environ", "libSystem"), ("_class_setSuperclass", "libobjc")], strong
    assert weak == [("_os_unfair_lock_lock", "libSystem")], weak
    print("PASS: iOS 5 import policy self-test (library-aware)")


def main(argv):
    reference_path = DEFAULT_REFERENCE
    files = []
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--self-test":
            self_test()
            return 0
        if arg == "--reference":
            reference_path = Path(argv[index + 1])
            index += 2
            continue
        if arg == "--runtime-dir":
            files.extend(sorted(Path(argv[index + 1]).glob("*.dylib")))
            index += 2
            continue
        files.append(Path(arg))
        index += 1
    if not files:
        print(__doc__)
        return 2
    if not reference_path.is_file():
        print("FAIL: missing iOS 5.1.1 reference %s" % reference_path)
        return 2
    reference = load_reference(reference_path)
    failures = 0
    for path in files:
        strong, weak = classify(imports_of(path), reference)
        for symbol, library in strong:
            print("FAIL %s: strong import %s (%s) is not exported by iOS 5.1.1"
                  % (path.name, symbol, library))
        failures += len(strong)
        print("%s %s: %d strong unresolved, %d weak (null-checked)"
              % ("FAIL" if strong else "PASS", path.name, len(strong), len(weak)))
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except OSError as error:
        print("FAIL: %s" % error)
        sys.exit(2)
