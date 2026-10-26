//
//  LegacyLayoutGeneration.swift
//  LegacyAutoLayout
//
//  Global mutation generation for the legacy Auto Layout engine.
//
//  The persistent solver caches its solution per layout root. Before walking the
//  item tree it now compares this monotonically increasing counter with the value
//  it consumed at the end of its last pass: if nothing that can affect the
//  constraint system has changed, the cached result is returned immediately
//  (O(1), no tree walk, no solver work).
//
//  Every mutation entry point bumps the counter:
//    * constraint add/remove and activation,
//    * constraint constant/priority changes,
//    * translatesAutoresizingMaskIntoConstraints / intrinsic size / hugging /
//      compression-resistance / baseline changes,
//    * subview insertion/removal (reparenting),
//    * bounds/center/transform changes that participate in the constraint graph.
//
//  The engine's own frame write-back and the internal autoresizing-diagnostic
//  constraint construction are suppressed so a pass does not invalidate its own
//  result.
//
//  Main-thread only, like the rest of the bridge. The counter is deliberately a
//  process-wide conservative signal: a mutation on one root makes the other
//  cached roots re-check their inputs (a diff, not necessarily a solve).
//

import Foundation

internal enum LegacyLayoutMutation {

    private static var value: Int = 0
    private static var suppressionDepth = 0

    /// The current mutation generation.
    internal static var generation: Int { value }

    /// Records a mutation that can affect a constraint system.
    internal static func bump() {
        guard suppressionDepth == 0 else { return }
        value &+= 1
    }

    /// Runs `body` without bumping the generation. Used for engine-owned work
    /// that constructs/updates constraints internally (autoresizing diagnostics)
    /// or writes frames back.
    @discardableResult
    internal static func withSuppressed<T>(_ body: () -> T) -> T {
        suppressionDepth += 1
        defer { suppressionDepth -= 1 }
        return body()
    }
}
