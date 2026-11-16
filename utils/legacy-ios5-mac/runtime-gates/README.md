# Runtime gates

Static and dynamic checks for the multi-architecture legacy runtime. All are OS-agnostic: they test
properties (which implementation served an API, whether memory stays intact) rather than version numbers.

- `check-binary-gates.sh APP` – no system-Swift deps, no duplicate/system rpath, all @rpath deps shipped,
  64-bit executable linked-SDK tag >= 19, runtime has the load-time class-bit switch.
- `run-sim-gates.sh RUNTIME_DIR` – compiles `cast-corruption.swift` and runs it on a booted simulator.
- `api-gating-probe.swift` – app that exercises anchors, isActive, safe area, layout guides, stack view,
  refresh control, casts, dispatch churn, and records which class served each (`id.*` lines). Run it on a
  device and on a simulator beside a native-compiled copy and diff the output.
- `battery-sim.sh APP BUNDLE_ID SIM` – 12 cold launches, soak, appearance/content-size changes,
  background/foreground cycles, malloc scribble + guard edges, crash-report check.

Known limit: `UILayoutGuide` and the anchor classes are compiled in (`id.UILayoutGuide.class`,
`id.UIView.topAnchor.class` report the backport type even on iOS 9+); the constraints they create are native.
