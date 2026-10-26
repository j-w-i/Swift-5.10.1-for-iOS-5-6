//
//  LegacyLayoutStats.swift
//  LegacyAutoLayout
//
//  Measurement counters for the legacy Auto Layout engine.
//
//  Counters are always maintained (a few integer adds per layout pass); they
//  are only printed when LEGACY_AUTOLAYOUT_STATS=1 is set in the environment, so
//  behaviour is unchanged otherwise. The internal API is also what the host test
//  harness reads to report steady-state and rebuild numbers.
//

import Foundation

/// A snapshot of the engine counters.
internal struct LegacyLayoutStatistics {
    /// Layout passes requested (each `LegacyLayoutEngine.layout` call).
    var passes: Int
    /// Passes that ran a solver update (incremental or rebuild).
    var solves: Int
    /// Passes served entirely from the persistent solver's cached result.
    var cachedPasses: Int
    /// Solver rebuilds after an incompatible change (structure, root size, direction).
    var rebuilds: Int
    /// Constraints installed into a solver (adds, including replacements).
    var constraintsInstalled: Int
    /// Constraint rows removed from a solver.
    var constraintsRemoved: Int
    /// Variables known to the persistent solver after the pass.
    var variables: Int
    /// Microseconds spent inside the last layout pass.
    var lastPassMicroseconds: Double
    /// Total microseconds spent in layout passes since the last reset.
    var totalMicroseconds: Double
}

/// Process-wide layout counters and the environment-gated reporter.
internal enum LegacyLayoutStats {

    private static var passes = 0
    private static var solves = 0
    private static var cachedPasses = 0
    private static var rebuilds = 0
    private static var constraintsInstalled = 0
    private static var constraintsRemoved = 0
    private static var variables = 0
    private static var lastPassMicroseconds: Double = 0
    private static var totalMicroseconds: Double = 0

    /// Whether per-pass statistics are printed to stderr.
    internal static let enabled: Bool = {
        let value = ProcessInfo.processInfo.environment["LEGACY_AUTOLAYOUT_STATS"]
        return value == "1" || value == "true" || value == "YES"
    }()

    /// The current counter values.
    internal static var snapshot: LegacyLayoutStatistics {
        LegacyLayoutStatistics(passes: passes,
                               solves: solves,
                               cachedPasses: cachedPasses,
                               rebuilds: rebuilds,
                               constraintsInstalled: constraintsInstalled,
                               constraintsRemoved: constraintsRemoved,
                               variables: variables,
                               lastPassMicroseconds: lastPassMicroseconds,
                               totalMicroseconds: totalMicroseconds)
    }

    /// Resets every counter (test harness isolation).
    internal static func reset() {
        passes = 0; solves = 0; cachedPasses = 0; rebuilds = 0
        constraintsInstalled = 0; constraintsRemoved = 0
        variables = 0; lastPassMicroseconds = 0; totalMicroseconds = 0
    }

    // MARK: Recording

    internal static func notePass(microseconds: Double, solved: Bool, rebuilt: Bool) {
        passes += 1
        if solved { solves += 1 } else { cachedPasses += 1 }
        if rebuilt { rebuilds += 1 }
        lastPassMicroseconds = microseconds
        totalMicroseconds += microseconds
        if enabled {
            let action = rebuilt ? "rebuild" : (solved ? "update" : "cached")
            let line = "legacy-autolayout: pass=\(passes) action=\(action) " +
                "us=\(String(format: "%.1f", microseconds)) solves=\(solves) " +
                "cached=\(cachedPasses) rebuilds=\(rebuilds)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    internal static func noteConstraints(installed: Int, removed: Int, variables: Int) {
        constraintsInstalled += installed
        constraintsRemoved += removed
        self.variables = variables
    }
}
