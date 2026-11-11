Paired PST-versus-native benchmark for a real iOS 6/7 device (the objective's "native performance
baseline": Apple's own UICollectionView on the same hardware, same OS).

`bench.m` is compiled twice, once per engine, with distinct class names; `main-device.m` runs both in
one app (UIApplicationMain plus a window, as devices require), alternating order, and reports
median PST/native over 9 pairs for four timing modes:

  0 layoutIfNeeded only      1 + CATransaction flush      2 + run-loop turn      3 + both

Each mode runs with and without a window, and prints the visible-cell and cellForItem counts so the
work both engines did is visible next to the time. Build for `-target armv7-apple-ios6.0 -marm`,
compile the PST sources with `-DPST_TOOLCHAIN_RUNTIME=1`, and link with
`-L /Users/jwalr/Developer/Legacy-Build-Inputs` so the executable keeps an iOS 6 minimum version
instead of being retargeted to a newer OS.
