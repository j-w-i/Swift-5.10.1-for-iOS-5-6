# Reproducible legacy overlay input bootstrap

This stage replaces the manually assembled `modules510`, shim and generated
source inputs used by the initial Swift 5.10 probes. It prepares **compiler/import
inputs only**, not a complete runtime or an installable toolchain. It does not
compile, link, select Xcode globally, modify an installed toolchain, or use
products from the original Swift 5.1 build directory.

## Required inputs

- An installed Swift 5.10 Darwin resource directory, normally the toolchain's
  `usr/lib/swift`, containing real `iphoneos` modules (including Swift), modern
  `shims`, and the armv7 layout data required by the compiler. The script retains
  the input layout rather than manufacturing missing modules or layout data.
- The original patched Swift 5.1 **source** checkout, including
  `stdlib/public/SwiftShims`, `utils/gyb`, `gyb.py`, and its Python helper modules.
  No old `.swiftmodule` or `.swiftinterface` is transplanted: Swift 5.10 rejected
  those in the initial probe.
- The committed migrated overlay sources alongside the bootstrap script.
- Bash and Python 3.8+. The Swift 5.1 GYB utility is explicitly run with Python 3,
  ignoring its historical Python 2.7 shebang. No Python packages are installed.
- A new output directory, separate from all input trees. Existing output
  directories are rejected, even if empty. On failure, the partial stage remains
  available for inspection; choose a new output path to retry. Nothing is deleted.

All paths are explicit; the script does not infer a toolchain or original source
from `$HOME`. To choose Python, set `PYTHON` for this command only.

```bash
bash /path/to/swift-5.10-ios5/utils/legacy-ios5-mac/prepare-legacy-resources.sh \
  --swift510-resource /path/to/swift-5.10.1-RELEASE.xctoolchain/usr/lib/swift \
  --swift51-source /path/to/original-swift-5.1-source \
  --output /path/to/new-isolated-bootstrap-stage
```

The script is fail-fast and serial (no background workers or parallel jobs).
It sets `PYTHONDONTWRITEBYTECODE=1` only in GYB child processes, so importing the
old generator does not create cache files in the original source tree.

## Output layout

- `probes/modules510/`: copied real Swift 5.10 resources and modules, excluding
  Dispatch, Foundation, CoreGraphics, Metal, QuartzCore, CoreImage and UIKit
  compiled modules (these must be rebuilt from the migrated sources). Installed
  dylibs, archives and object binaries are excluded: this is not a target runtime
  installer. Modern Swift core shim definitions remain intact.
- `probes/dispatch-shims/`: complete real Swift 5.1 header set, including the
  NS*/CF* dependencies and FoundationShimSupport; its module map copies the
  original `_Swift*OverlayShims` definitions and adds the committed CDispatch map
  and `cdispatch/` headers. It deliberately does **not** redeclare `SwiftShims` or
  `SwiftOverlayShims`, so the modern compiler continues to use its own core shims.
  Do not add `-U__swift__`: the modern RefCount headers need it to avoid pulling
  C++ definitions into Objective-C imports.
- `src/legacy-overlays/`: isolated copies of the committed migrated sources.
- `generated/Foundation/NSValue.swift`, `generated/QuartzCore/NSValue.swift`,
  `generated/CoreGraphics/CGFloat.swift`, and
  `generated/UIKit/UIKit_FoundationExtensions.swift`: generated serially from
  their actual GYB templates, using the old source GYB tool and
  `CMAKE_SIZEOF_VOID_P=4`. No old generated build products are referenced.
- `probes/<framework-lowercase>510-sources.txt`: absolute, quoted Swift response
  files, preserving each overlay's CMake source list and replacing GYB inputs
  with the new generated source paths. Dispatch uses its committed Swift files.
  Foundation's intentionally excluded sources are not accidentally globbed in.
- `bootstrap-manifest.json`: explicit input paths and SHA-256 hashes of all
  prepared files. Response-file hashes naturally include the chosen output path.

## Consuming the stage and remaining prerequisites

Existing probe scripts currently contain historical absolute paths. This script
**does not rewrite or execute them**. Point the probe's resource directory at
`<stage>/probes/modules510`, add `-I <stage>/probes/dispatch-shims` and
`-Xcc -I<stage>/probes/modules510/iphoneos`, and pass the corresponding
`@<stage>/probes/...510-sources.txt` instead of the original build's `ursnm.txt`
or a source glob. Generated framework inputs in particular require the response
file; the generic probe's `*.swift` glob does not include `generated/`.

Compile prerequisites remain the selected host Swift 5.10 compiler, matching
Apple SDK, real armv7 core modules/layout data and the real migrated sources.
Build serially (`-j1`, whole-module optimization where needed; existing Mac policy
also uses `nice -n 15`). Dependency order for these probes is core import modules
then Dispatch, CoreGraphics, Foundation, Metal/QuartzCore/CoreImage, then UIKit.
This bootstrap does not install old runtime dylibs or a CRT; linking additionally
requires the separately audited real old runtime/native helpers/compiler-rt and
correct framework availability/weak-link handling. No placeholder overlay module
is generated for any missing framework.

Stock installed Swift 5.10 is useful only for source/ABI probes. Rebuild with the
patched frontend and explicit `-enable-legacy-ios5-runtime` before claiming
legacy class marking. Preserve the probe's compatibility controls such as
`-runtime-compatibility-version none`; they prevent unwanted modern compatibility
archive force-load references but are not a proof of runtime ABI compatibility.
Actual armv7 links, import/availability audits, UNIXTHREAD startup inspection,
and real iOS 5 device execution remain separate required stages. Current stock-compiler probes intentionally compile overlays at iOS7.0 and inherit old runtime dylibs with that Mach-O minimum. They are not deployment-qualified iOS5 libraries; do not rewrite their load commands to conceal this. The final patched-compiler stage must produce/audit genuine deployment metadata or explicitly verify old-dyld acceptance before qualification. The sample executable's min5.0 does not change its libraries' minima.

## Validation performed for this bootstrap

Linux-only: `bash -n`, embedded Python AST parsing, verification of all committed
CMake-listed Swift/GYB inputs, and successful Python 3 generation of all four GYB
templates against the original Swift 5.1 source utility.

Lead integration on the Mac subsequently passed the full resource bootstrap into a fresh stage and serial compilation of all seven actual overlay modules/objects with installed Swift 5.10. A separate proof linked the full ApiTest app against migrated overlays and the old runtime (including the exact upstream stack-allocation helper backport) and passed the existing import screen. These are source/ABI probes using the stock compiler: patched class marking and device execution remain pending. The original installed environment is unchanged.

`GenericRuntimeSmoke.swift` compiles and links as armv7 against the migrated imports/runtime without missing strong or lazy-bound symbols in the existing screen. Its 22 checks also pass as a **modern macOS host-only** fixture sanity run (Xcode13 compiler/system runtime); that does not test iOS5 class marking, old ObjC realization, legacy allocation, or device behavior. Run the same fixture in the final iOS5 app before making those claims.
