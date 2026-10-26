//
//  LegacyLayoutEngine.swift
//  LegacyAutoLayout
//
//  The UIKit-decoupled constraint-based layout pass for the RRAutoLayout port.
//
//  RRAutoLayout (MIT, Copyright (c) 2012 Rolandas Razma <rolandas@razma.lt>)
//  implemented `layoutSubviews` as an ad-hoc per-view walk that applied
//  `CGRectAddAttribute` arithmetic in whatever order the constraints happened to
//  be in, with the author explicitly noting it "needs rewrite" because the result
//  depended on the view hierarchy and on the order attributes were visited. This
//  engine replaces that rectangle math with a real Cassowary solve (the algorithm
//  Auto Layout itself uses), while keeping RRAutoLayout's call model: collect the
//  subtree and the constraints attached to it, solve, then write frames back.
//
//  Persistent incremental solving
//  -----------------------------
//  UIKit's layout engine keeps one incremental constraint system per window; it
//  does not rebuild the simplex tableau for every layout pass. This engine now
//  does the same: one `LegacyLayoutSolver` (and therefore one Cassowary `Solver`)
//  is kept per layout root in a small cache. A dirty pass diffs the item tree and
//  the constraint set against what is installed and only adds/removes/updates the
//  rows that changed:
//
//    * item structure change (view added/removed/reparented), root resize or
//      writing-direction change -> drop the solver and rebuild (a rebuild is the
//      known-correct path; it is also the fallback when the solver rejects an
//      incremental update);
//    * changed constraint constant/priority      -> replace only that row;
//    * changed intrinsic size / hugging priorities -> replace only that item's
//      intrinsic rows;
//    * changed autoresizing reference/mask       -> replace only that item's
//      autoresizing rows;
//    * frame changes (stays)                     -> update constants in place.
//
//  When none of the above changed, the pass returns the previous result without
//  touching the solver ("cached"). The UIKit bridge already gates the call on the
//  backported dirty flags, so in the steady state layout does no solver work at
//  all.
//
//  The public API is unchanged: `layout(_:)` writes frames, `solve(_:)` performs a
//  fresh rebuild without write-back (used by the parity tests).
//

import Foundation
import CoreGraphics

/// The direction in which `leading`/`trailing` attributes are resolved.
///
/// UIKit derives this from `UIApplication.userInterfaceLayoutDirection` (or from
/// the view's semantic content attribute); the bridge passes it to the engine.
enum RRLayoutDirection: Hashable {
    /// `leading` is the left edge, `trailing` the right edge.
    case leftToRight
    /// `leading` is the right edge, `trailing` the left edge.
    case rightToLeft
}

/// A solved frame in terms of the attributes Auto Layout exposed.
///
/// All values are physical (not direction-relative): `leading` is the minimum X
/// and `trailing` the maximum X regardless of the engine direction, matching the
/// `CGRect` the frame is written back as. Kept for tests/debugging; the frame in
/// `LegacyLayoutResult.frames` is authoritative.
struct LegacyResolvedFrame {
    var leading: CGFloat
    var trailing: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var width: CGFloat
    var height: CGFloat
    var centerX: CGFloat
    var centerY: CGFloat
    var firstBaseline: CGFloat
    var lastBaseline: CGFloat

    init(leading: CGFloat,
                trailing: CGFloat,
                top: CGFloat,
                bottom: CGFloat,
                width: CGFloat,
                height: CGFloat,
                centerX: CGFloat,
                centerY: CGFloat,
                firstBaseline: CGFloat,
                lastBaseline: CGFloat) {
        self.leading = leading
        self.trailing = trailing
        self.top = top
        self.bottom = bottom
        self.width = width
        self.height = height
        self.centerX = centerX
        self.centerY = centerY
        self.firstBaseline = firstBaseline
        self.lastBaseline = lastBaseline
    }
}

/// The result of one layout pass.
struct LegacyLayoutResult {

    /// Final frames keyed by `ObjectIdentifier(item)`. The root's frame is
    /// included unchanged (the root is the container; the engine does not resize
    /// it). These are the frames that were (or, for `solve`, would be) written.
    var frames: [ObjectIdentifier: CGRect]

    /// Constraints Auto Layout would log as broken: required constraints that
    /// could not be satisfied together with the already-installed system, or
    /// constraints that are structurally invalid (e.g. no first item, a missing
    /// second attribute, a non-finite constant). Optional constraints that lose a
    /// priority fight are *not* broken -- they are simply not satisfied.
    var brokenConstraints: [RRLayoutConstraint]

    /// Last solved value per item, for debugging/tests. Frames agree with these.
    var resolvedAttributes: [ObjectIdentifier: LegacyResolvedFrame]

    init(frames: [ObjectIdentifier: CGRect] = [:],
                brokenConstraints: [RRLayoutConstraint] = [],
                resolvedAttributes: [ObjectIdentifier: LegacyResolvedFrame] = [:]) {
        self.frames = frames
        self.brokenConstraints = brokenConstraints
        self.resolvedAttributes = resolvedAttributes
    }
}

/// The legacy constraint-based layout engine.
///
/// Usage:
///
///     let engine = LegacyLayoutEngine()
///     let result = engine.layout(rootItem)   // solves and writes frames
///     let dryRun = engine.solve(rootItem)    // solves only
///
/// The engine is not tied to UIKit and does not swizzle anything. On modern
/// systems the UIKit bridge never calls it; it exists so the legacy path (and
/// explicit `legacy*` API users) get real Auto Layout behaviour.
///
/// Coordinate space: it solves internally in the root's local coordinate space,
/// but every `CGRect` it writes through `layoutSetFrame` -- and every frame in
/// `LegacyLayoutResult.frames`/`resolvedAttributes` -- is in the item's
/// *superitem* coordinate space, exactly like `UIView.frame`. The root's frame is
/// returned unchanged.
///
/// Documented limitations (not bugs, see `LegacyLayoutSolver` for details):
/// * intrinsic content size is modelled as the two Apple-documented inequalities
///   at the hugging / compression-resistance priorities, not as an edit variable,
///   so a user priority above 750 can out-rank compression resistance in ways
///   real UIKit's private content-size constraint might not;
/// * the Auto Layout Guide's "no nonidentity multiplier with location attributes"
///   rule is not enforced (the probed UIKit SDK does not enforce it either);
/// * under-constrained geometry is kept stable across the per-view passes the
///   bridge drives by solver-internal weak "stay" constraints, mirroring UIKit's
///   per-window engine and its incumbent-solution tie-break.
final class LegacyLayoutEngine {

    /// The direction used to resolve `leading`/`trailing`. Default `.leftToRight`.
    var direction: RRLayoutDirection

    /// Set to `false` (tests only) to rebuild the solver on every pass.
    internal var usesPersistentSolver = true

    // MARK: Persistent solver cache

    /// One solver per layout root. The root is held weakly; entries whose root
    /// was deallocated are pruned on the next pass.
    private struct CacheEntry {
        weak var root: AnyObject?
        var solver: LegacyLayoutSolver
        var direction: RRLayoutDirection
        var lastUsed: Int
    }

    /// Diagnostic/strict compatibility mode: `LEGACY_AUTOLAYOUT_FORCE_REBUILD=1`
    /// disables both the persistent solver cache and the presolve batch, so every
    /// dirty pass rebuilds the system exactly like the pre-optimisation engine.
    /// Intended for A/B verification on device; it does not change the API.
    internal static let strictRebuildMode: Bool = {
        ProcessInfo.processInfo.environment["LEGACY_AUTOLAYOUT_FORCE_REBUILD"] == "1"
    }()

    private static var solverCache: [ObjectIdentifier: CacheEntry] = [:]
    private static var cacheTick = 0

    /// Bounded so an app that lays out many short-lived roots (collection-view
    /// cells, popovers) cannot accumulate unbounded solver state.
    private static let maximumCachedRoots = 16

    /// Clears all persistent solver state (tests and diagnostics).
    internal static func resetPersistentState() {
        solverCache.removeAll()
        cacheTick = 0
    }

    /// The number of live persistent solvers (diagnostics/tests).
    internal static var persistentSolverCount: Int { solverCache.count }

    init(direction: RRLayoutDirection = .leftToRight) {
        self.direction = direction
    }

    /// Builds and solves the constraint system for the whole subtree rooted at
    /// `root`, then writes each item's frame (in superitem coordinates) back via
    /// `layoutSetFrame`. The root's frame is fixed and left untouched.
    ///
    /// A persistent solver is reused across passes when the item tree and the
    /// root geometry are unchanged; otherwise this executes the full rebuild.
    @discardableResult
    func layout(_ root: LegacyLayoutItem) -> LegacyLayoutResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let rootObject = root as AnyObject
        let identifier = ObjectIdentifier(rootObject)

        if usesPersistentSolver {
            Self.pruneCacheIfNeeded()
            if var entry = Self.solverCache[identifier], entry.root === rootObject,
               !Self.strictRebuildMode {
                // O(1) no-change path: nothing that can affect the constraint
                // system has mutated since this solver's last pass, so return its
                // result without walking the item tree or touching the tableau.
                if entry.direction == direction,
                   entry.solver.consumedGeneration == LegacyLayoutMutation.generation,
                   let cached = entry.solver.cachedLayoutResult {
                    Self.cacheTick += 1
                    entry.lastUsed = Self.cacheTick
                    Self.solverCache[identifier] = entry
                    LegacyLayoutStats.noteFastPass(
                        microseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1000.0)
                    return cached
                }
                if let result = entry.solver.update(root: root,
                                                    direction: direction,
                                                    writingFrames: true) {
                    Self.cacheTick += 1
                    entry.lastUsed = Self.cacheTick
                    entry.direction = direction
                    Self.solverCache[identifier] = entry
                    Self.notePass(start: start,
                                  solver: entry.solver,
                                  cached: entry.solver.lastUpdateWasCached,
                                  rebuilt: false)
                    return result
                }
            }
        }

        // Full rebuild: the fast path could not prove equivalence (or this pass
        // is a first pass / persistence is disabled for tests).
        let solver = LegacyLayoutSolver(root: root, direction: direction)
        let result = solver.solve(writingFrames: true)
        if usesPersistentSolver {
            Self.store(solver: solver, root: rootObject, identifier: identifier, direction: direction)
        }
        Self.notePass(start: start, solver: solver, cached: false, rebuilt: true)
        return result
    }

    /// Same solve as `layout(_:)` but performs no write-back. Used by parity tests
    /// and by callers that need the frames before committing them. Always rebuilds
    /// (a dry run must not disturb the persistent solver's tableau).
    func solve(_ root: LegacyLayoutItem) -> LegacyLayoutResult {
        let solver = LegacyLayoutSolver(root: root, direction: direction)
        return solver.solve(writingFrames: false)
    }

    // MARK: Cache plumbing

    private static func store(solver: LegacyLayoutSolver,
                              root: AnyObject,
                              identifier: ObjectIdentifier,
                              direction: RRLayoutDirection) {
        cacheTick += 1
        if !Self.strictRebuildMode {
        solverCache[identifier] = CacheEntry(root: root, solver: solver,
                                            direction: direction, lastUsed: cacheTick)
        }
        if solverCache.count > maximumCachedRoots {
            evictOldest()
        }
    }

    private static func pruneCacheIfNeeded() {
        // Cheap: only walk the (bounded) cache occasionally.
        if cacheTick % 8 == 0 {
            solverCache = solverCache.filter { $0.value.root != nil }
        }
    }

    private static func evictOldest() {
        while solverCache.count > maximumCachedRoots {
            guard let oldest = solverCache.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
            solverCache.removeValue(forKey: oldest.key)
        }
    }

    private static func notePass(start: UInt64,
                                 solver: LegacyLayoutSolver,
                                 cached: Bool,
                                 rebuilt: Bool) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000.0
        LegacyLayoutStats.noteConstraints(installed: solver.passInstalledConstraints,
                                          removed: solver.passRemovedConstraints,
                                          variables: solver.tableauVariableCount)
        LegacyLayoutStats.notePass(microseconds: elapsed, solved: !cached, rebuilt: rebuilt)
    }
}
