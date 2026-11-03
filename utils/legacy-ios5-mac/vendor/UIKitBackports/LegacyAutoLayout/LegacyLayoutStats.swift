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
#if canImport(Darwin)
import Darwin
#endif

/// A snapshot of the engine counters.
internal struct LegacyLayoutStatistics {
    /// Layout passes requested (each `LegacyLayoutEngine.layout` call).
    var passes: Int
    /// Passes that ran a solver update (incremental or rebuild).
    var solves: Int
    /// Passes served entirely from the persistent solver's cached result
    /// (including the O(1) mutation-generation fast path).
    var cachedPasses: Int
    /// Passes that returned the cached result without walking the item tree.
    var fastPasses: Int
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
    private static var fastPasses = 0
    private static var rebuilds = 0
    private static var constraintsInstalled = 0
    private static var constraintsRemoved = 0
    private static var variables = 0
    private static var lastPassMicroseconds: Double = 0
    private static var totalMicroseconds: Double = 0

    /// Whether per-pass statistics are printed to stderr.
    ///
    /// Read through `getenv` rather than `ProcessInfo.environment`: this flag is
    /// evaluated from the backport's image initializer, and bridging
    /// `NSDictionary` into a Swift `Dictionary` there runs Foundation bridging
    /// before the Swift runtime has finished setting up on the legacy system.
    internal static let enabled: Bool = {
        guard let raw = getenv("LEGACY_AUTOLAYOUT_STATS") else { return false }
        let value = String(cString: raw)
        return value == "1" || value == "true" || value == "YES"
    }()

    /// The current counter values.
    internal static var snapshot: LegacyLayoutStatistics {
        LegacyLayoutStatistics(passes: passes,
                               solves: solves,
                               cachedPasses: cachedPasses,
                               fastPasses: fastPasses,
                               rebuilds: rebuilds,
                               constraintsInstalled: constraintsInstalled,
                               constraintsRemoved: constraintsRemoved,
                               variables: variables,
                               lastPassMicroseconds: lastPassMicroseconds,
                               totalMicroseconds: totalMicroseconds)
    }

    /// Resets every counter (test harness isolation).
    internal static func reset() {
        passes = 0; solves = 0; cachedPasses = 0; fastPasses = 0; rebuilds = 0
        constraintsInstalled = 0; constraintsRemoved = 0
        variables = 0; lastPassMicroseconds = 0; totalMicroseconds = 0
    }

    // MARK: Recording

    /// Records an O(1) no-change pass: the mutation generation was unchanged, so
    /// the cached result was returned without walking the tree.
    internal static func noteFastPass(microseconds: Double) {
        passes += 1
        cachedPasses += 1
        fastPasses += 1
        lastPassMicroseconds = microseconds
        totalMicroseconds += microseconds
        if enabled {
            let line = "legacy-autolayout: pass=\(passes) action=fast " +
                "us=\(String(format: "%.2f", microseconds)) solves=\(solves) " +
                "cached=\(cachedPasses) fast=\(fastPasses) rebuilds=\(rebuilds)\n"
            FileHandle.standardError.write(Data(line.utf8))
            FileHandle.standardError.write(Data(LegacyBridgeStats.report().utf8))
        }
    }

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
                "cached=\(cachedPasses) fast=\(fastPasses) rebuilds=\(rebuilds)\n"
            FileHandle.standardError.write(Data(line.utf8))
            FileHandle.standardError.write(Data(LegacyBridgeStats.report().utf8))
        }
    }

    internal static func noteConstraints(installed: Int, removed: Int, variables: Int) {
        constraintsInstalled += installed
        constraintsRemoved += removed
        self.variables = variables
    }
}

/// Runtime attribution for the legacy bridge path (activation/deactivation,
/// constraint creation, injected hooks and the layout pass).
///
/// Enabled with the same `LEGACY_AUTOLAYOUT_STATS=1` environment variable as the
/// per-pass counters; when disabled every helper is a single boolean check and the
/// segments are never touched. The device stress app reads the accumulated
/// total/max/count from the `bridge=` line printed at each engine pass.
internal enum LegacyBridgeStats {

    internal struct Segment {
        internal var totalNanoseconds: UInt64 = 0
        internal var maxNanoseconds: UInt64 = 0
        internal var count: UInt64 = 0

        internal mutating func add(_ nanoseconds: UInt64) {
            totalNanoseconds &+= nanoseconds
            if nanoseconds > maxNanoseconds { maxNanoseconds = nanoseconds }
            count &+= 1
        }

        internal var microseconds: Double { Double(totalNanoseconds) / 1000.0 }
        internal var maxMicroseconds: Double { Double(maxNanoseconds) / 1000.0 }
    }

    internal static let enabled = LegacyLayoutStats.enabled

    // Constraint creation.
    internal static var create = Segment()
    internal static var anchorCreate = Segment()
    // Platform isActive setter (template on the runtime NSLayoutConstraint class).
    internal static var templateActive = Segment()
    internal static var templateActiveFirstItem = Segment()
    internal static var templateActiveDispatch = Segment()
    // Public NSLayoutConstraint.isActive shim (APIShims, what app code calls).
    internal static var extensionActive = Segment()
    internal static var extensionActiveFirstItem = Segment()
    internal static var extensionActiveTranslates = Segment()
    internal static var extensionActiveModelLookup = Segment()
    internal static var extensionActiveDispatch = Segment()
    // Injected UIView hooks and legacy storage.
    internal static var hookAdd = Segment()
    internal static var hookRemove = Segment()
    internal static var legacyAdd = Segment()
    internal static var legacyRemove = Segment()
    internal static var legacyStorage = Segment()
    internal static var containerInvalidation = Segment()
    // Layout pass (engine + recursive update walk), tracked while an activation
    // scope is open so a synchronous layout inside isVisible.
    internal static var layoutPass = Segment()
    internal static var updateWalk = Segment()

    // Counters.
    internal static var ensureCalls: UInt64 = 0
    internal static var ensureInstalls: UInt64 = 0
    internal static var registerNativeRuns: UInt64 = 0
    internal static var layoutPassesDuringActivation: UInt64 = 0
    internal static var layoutNanosDuringActivation: UInt64 = 0
    internal static var updateWalksDuringActivation: UInt64 = 0

    private static var activationDepth = 0

    @inline(__always)
    internal static func begin() -> UInt64 {
        enabled ? DispatchTime.now().uptimeNanoseconds : 0
    }

    @inline(__always)
    internal static func record(_ start: UInt64, _ segment: inout Segment) {
        guard enabled, start != 0 else { return }
        segment.add(DispatchTime.now().uptimeNanoseconds - start)
    }

    @inline(__always)
    internal static func beginActivation() {
        guard enabled else { return }
        activationDepth += 1
    }

    @inline(__always)
    internal static func endActivation() {
        guard enabled, activationDepth > 0 else { return }
        activationDepth -= 1
    }

    @inline(__always)
    internal static var isActivating: Bool { enabled && activationDepth > 0 }

    internal static func noteLayoutPass(nanoseconds: UInt64) {
        guard enabled else { return }
        layoutPass.add(nanoseconds)
        if activationDepth > 0 {
            layoutPassesDuringActivation &+= 1
            layoutNanosDuringActivation &+= nanoseconds
        }
    }

    internal static func noteUpdateWalk(nanoseconds: UInt64) {
        guard enabled else { return }
        updateWalk.add(nanoseconds)
        if activationDepth > 0 { updateWalksDuringActivation &+= 1 }
    }

    internal static func reset() {
        create = Segment()
        anchorCreate = Segment()
        templateActive = Segment()
        templateActiveFirstItem = Segment()
        templateActiveDispatch = Segment()
        extensionActive = Segment()
        extensionActiveFirstItem = Segment()
        extensionActiveTranslates = Segment()
        extensionActiveModelLookup = Segment()
        extensionActiveDispatch = Segment()
        hookAdd = Segment()
        hookRemove = Segment()
        legacyAdd = Segment()
        legacyRemove = Segment()
        legacyStorage = Segment()
        containerInvalidation = Segment()
        layoutPass = Segment()
        updateWalk = Segment()
        ensureCalls = 0
        ensureInstalls = 0
        registerNativeRuns = 0
        layoutPassesDuringActivation = 0
        layoutNanosDuringActivation = 0
        updateWalksDuringActivation = 0
        activationDepth = 0
    }

    private static func format(_ name: String, _ segment: Segment) -> String {
        guard segment.count > 0 else { return "" }
        return String(format: " %@=%.1f/%.1f us n=%llu", name,
                      segment.microseconds, segment.maxMicroseconds, segment.count)
    }

    /// Compact one-line report appended to the per-pass stderr diagnostics.
    internal static func report() -> String {
        var text = "legacy-bridge:"
        text += format("create", create)
        text += format("anchorCreate", anchorCreate)
        text += format("templateActive", templateActive)
        text += format("templateFirstItem", templateActiveFirstItem)
        text += format("extActive", extensionActive)
        text += format("extFirstItem", extensionActiveFirstItem)
        text += format("extTranslates", extensionActiveTranslates)
        text += format("extModel", extensionActiveModelLookup)
        text += format("extDispatch", extensionActiveDispatch)
        text += format("hookAdd", hookAdd)
        text += format("hookRemove", hookRemove)
        text += format("legacyAdd", legacyAdd)
        text += format("legacyRemove", legacyRemove)
        text += format("legacyStorage", legacyStorage)
        text += format("invalidation", containerInvalidation)
        text += format("layout", layoutPass)
        text += format("updateWalk", updateWalk)
        text += String(format: " ensure=%llu installs=%llu registerAPI=%llu layoutDuringActivation=%llu/%.1f us updateWalksDuringActivation=%llu",
                       ensureCalls, ensureInstalls, registerNativeRuns,
                       layoutPassesDuringActivation,
                       Double(layoutNanosDuringActivation) / 1000.0,
                       updateWalksDuringActivation)
        return text + "\n"
    }
}

/// Reads a legacy environment flag with libc only. The backport reads its
/// diagnostics switches from image initializers, where Foundation's dictionary
/// bridging is not ready yet on the legacy runtime.
internal func legacyEnvironmentFlag(_ name: String) -> Bool {
    guard let raw = getenv(name) else { return false }
    let value = String(cString: raw)
    return value == "1" || value == "true" || value == "YES"
}


// MARK: Always-on diagnostics (no environment flag, no stderr)

/// Counters the device test bridge reads through `UICLegacyLayoutDebugSummary`. Cheap enough to leave on: a dictionary
/// bump per rejected install, which only happens when a required row cannot be satisfied.
@_silgen_name("cs_work_stats") private func cs_work_stats(_ out: UnsafeMutablePointer<Int64>)

internal enum LegacyLayoutDebug {
    nonisolated(unsafe) static var rejectedInstalls = 0
    nonisolated(unsafe) static var rejectedByName: [String: Int] = [:]
    nonisolated(unsafe) static var lastRejected = ""
    nonisolated(unsafe) static var bails: [String: Int] = [:]
    nonisolated(unsafe) static var fitHits = 0, fitMisses = 0, fitMissInvalidated = 0, fitMissProposal = 0, fitMissFirst = 0
    nonisolated(unsafe) static var rebuildRoots: [String: (count: Int, rows: Int)] = [:]
    nonisolated(unsafe) static var pendingBail = "first-pass"

    static func noteRejected(name: String?, op: String, strengthIsRequired: Bool, terms: Int, constant: Double, error: String) {
        rejectedInstalls += 1
        let key = "\(name ?? "-") | \(op) | required=\(strengthIsRequired) | terms=\(terms)"
        if rejectedByName.count < 24 || rejectedByName[key] != nil { rejectedByName[key, default: 0] += 1 }
        lastRejected = "\(key) const=\(constant) error=\(error)"
    }
}

/// C ABI for the device bridge: a human-readable summary of engine counters. The caller frees the string.
@_cdecl("UICLegacyLayoutDebugSummary")
public func UICLegacyLayoutDebugSummary() -> UnsafeMutablePointer<CChar>? {
    let stats = LegacyLayoutStats.snapshot
    let replay = LegacyLayoutSolver.replayStats
    var out = "passes=\(stats.passes) solves=\(stats.solves) rebuilds=\(stats.rebuilds) cached=\(stats.cachedPasses) fast=\(stats.fastPasses)\n"
    out += "solverReplays=\(replay.total) presolvedReplays=\(replay.presolved)\n"
    var w = [Int64](repeating: 0, count: 5); cs_work_stats(&w)
    out += "solver adds=\(w[0]) pivots=\(w[1]) dualPivots=\(w[2]) rowsSubstituted=\(w[3]) cellsSubstituted=\(w[4])\n"
    out += "rejectedInstalls=\(LegacyLayoutDebug.rejectedInstalls)\n"
    for (k, v) in LegacyLayoutDebug.rejectedByName.sorted(by: { $0.value > $1.value }) { out += "  \(v)x \(k)\n" }
    out += "last: \(LegacyLayoutDebug.lastRejected)\n"
    out += "stackFitting hits=\(LegacyLayoutDebug.fitHits) misses=\(LegacyLayoutDebug.fitMisses) (first=\(LegacyLayoutDebug.fitMissFirst) invalidated=\(LegacyLayoutDebug.fitMissInvalidated) proposalChanged=\(LegacyLayoutDebug.fitMissProposal))\n"
    out += "bails:\n"
    for (k, v) in LegacyLayoutDebug.bails.sorted(by: { $0.value > $1.value }) { out += "  \(v)x \(k)\n" }
    out += "rebuild roots (count, total rows):\n"
    for (k, v) in LegacyLayoutDebug.rebuildRoots.sorted(by: { $0.value.rows > $1.value.rows }).prefix(12) { out += "  \(v.count)x \(k) rows=\(v.rows)\n" }
    return strdup(out)
}
