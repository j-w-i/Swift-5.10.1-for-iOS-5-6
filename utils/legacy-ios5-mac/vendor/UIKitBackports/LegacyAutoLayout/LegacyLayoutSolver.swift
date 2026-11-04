//
//  LegacyLayoutSolver.swift
//  LegacyAutoLayout
//
//  Translates the legacy item tree + `RRLayoutConstraint`s into a Cassowary
//  system, solves it, and extracts frames/attribute values.
//
//  This is the piece that replaces RRAutoLayout's ad-hoc `CGRectAddAttribute`
//  rectangle math (see `UIView (RRConstraintBasedLayout)` in the upstream
//  sources: "This needs rewrite ... need some approach to gather all constraints
//  affecting constraint"). Auto Layout's documented model is a linear constraint
//  system, so we build exactly that:
//
//      maxX   = minX + width
//      maxY   = minY + height
//      centerX = minX + width / 2
//      centerY = minY + height / 2
//
//  and for every `RRLayoutConstraint`:
//
//      firstAttribute <relation> multiplier * secondAttribute + constant
//
//  where each attribute is mapped onto the expression for the item's edge, size
//  or center on the corresponding axis. Shared variable expressions are what make
//  the system global instead of order-dependent, which is the whole point of
//  using Cassowary here.
//
//  Attribute expansion, not special cases
//  --------------------------------------
//  Attributes are expanded algebraically: `centerX` is its own variable bound to
//  `minX + width/2`, `maxX` is bound to `minX + width`, etc. Half-own-size terms
//  therefore appear exactly where the algebra puts them (left side for the first
//  item, multiplied by `multiplier` for the second item). There is deliberately
//  **no position x size "centering" rule**: UIKit rejects such pairings at
//  constraint-creation time with `NSInvalidArgumentException`, so they never
//  reach a solver (/tmp/autolayout-semantics.md §2.1). See
//  `RRLayoutConstraint.validationError` for the legal-pairing validation.
//
//  `leading`/`trailing` map to `minX`/`maxX` in LTR and swap in RTL, per
//  /tmp/autolayout-semantics.md §2.4 (iOS 6 resolves direction application-wide).
//  `left`/`right`/`centerX` are absolute (they never swap). In RTL the constraint
//  CONSTANT is also mirrored (negated) whenever either side uses leading/trailing:
//  the directional attribute values increase towards the trailing (leftward) edge.
//  This rule was probed against UIKit on the iOS 27 simulator (parity report) for
//  pure and mixed pairings:
//
//      a.leading == c.leading + 10    ->  RTL: a.right   = c.right - 10
//      a.trailing == c.trailing - 20  ->  RTL: a.left    = c.left  + 20
//      a.leading == c.trailing + 10   ->  RTL: a.right   = c.left  - 10
//      a.leading == b.centerX + 10    ->  RTL: a.right   = b.centerX - 10
//      a.centerX == b.leading + 10    ->  RTL: a.centerX = b.right - 10
//      centerX/left/right pairings    ->  unchanged
//
//  Required/optional INEQUALITIES whose sides use leading/trailing are mirrored
//  the same way, which also reverses the relation (verified against UIKit):
//
//      RTL: a.leading >= c.leading + 40   <=>   a.maxX <= c.maxX - 40
//
//  so <= becomes >= (and vice versa) together with the constant negation;
//  equalities keep their relation.
//
//  (A "mirror around M = 2*rootMinX + rootWidth" formulation was considered; it
//  agrees with the empirical results for pure directional pairs but NOT for
//  mixed directional/centerX pairs, so the verified rule above is used.)
//
//  Coordinate space
//  ----------------
//  The solver works in the ROOT's local coordinate space: the root's origin
//  variables are pinned to (0, 0) and its size to its bounds. `layoutFrame` is,
//  however, expressed in the item's superitem coordinate space, so result
//  extraction subtracts the superitem's solved absolute origin before calling
//  `layoutSetFrame`. This matters for nested trees (a subview of a subview must
//  not inherit its parent's absolute offset) and for the frames returned in
//  `LegacyLayoutResult`, which are superitem-relative (the root's frame is
//  returned unchanged). Autoresizing-mask position equations, which UIKit
//  expresses in the superview's coordinate space, are translated accordingly
//  (they subtract the superitem's origin variables).
//
//  Stays (stability across subtree passes)
//  ---------------------------------------
//  UIKit's engine is per-window and a constraint is owned by the closest common
//  ancestor, so an ancestor-owned constraint is not part of a later pass rooted at
//  an intermediate view. Without extra information, Cassowary would leave such
//  under-constrained variables at 0 and collapse geometry that a previous pass had
//  already solved. The engine therefore adds solver-internal WEAK stay constraints
//  pinning every non-root item's position and size to its CURRENT frame (previous
//  pass result). `.weak` (weight 1) is strictly below every user priority (50 maps
//  to 50000) and below intrinsic constraints, so fully determined layouts are
//  unaffected; under-constrained ones keep their incumbent geometry, matching
//  UIKit's documented "keep the incumbent solution" behaviour. Stays are a
//  deliberate deviation from a pure "solve only the subtree" model: real UIKit has
//  a per-window engine, so ancestor-owned constraints survive later per-view
//  passes; the stays reproduce that without collecting constraints outside the
//  subtree.
//
//  Known limitations (documented, not accidental)
//  ----------------------------------------------
//  * Intrinsic content size is modelled as the two inequalities Apple documents
//    (`width >= intrinsic @ compression resistance`,
//    `width <= intrinsic @ hugging`) rather than as an edit variable. A user
//    priority between the default compression resistance (750) and 1000 can
//    therefore out-rank compression here in ways real UIKit's private
//    NSContentSizeLayoutConstraint might not; no parity fixture has shown it.
//  * The Auto Layout Guide says "you cannot use a nonidentity multiplier with
//    location attributes"; UIKit on the probed SDK does NOT enforce that
//    (leading == 2*leading, centerX == 0.5*centerX and top == 1.5*top are all
//    accepted), so neither does this engine or its validator. It is solved
//    algebraically.
//
//  Baselines
//  ---------
//  A baseline is a position attribute derived from the item's content, not from
//  its geometry: `baseline = minY + layoutFirstBaselineOffsetFromTop` for the
//  first baseline and `minY + height - layoutLastBaselineOffsetFromBottom` for the
//  last one. The implicit equation is only added when the item provides an
//  offset; an item without a baseline provider (plain `UIView`) makes baseline
//  constraints unsupported, and those constraints are recorded as broken rather
//  than being given an invented top/bottom value (spec §2.5).
//
//  Solved-vs-broken semantics (matching Auto Layout)
//  -------------------------------------------------
//    * Required constraints (priority >= 1000) are added first, one by one. If one
//      cannot be satisfied the solver throws; it is recorded in
//      `brokenConstraints` and then **re-added at the "broken" strength**
//      `Strength.clip(required.value - 1)` -- the internal level Apple documents:
//      "not required, but higher priority than anything you can externally
//      specify", so the broken constraint is the first thing the next solve tries
//      to satisfy while the rest of the layout proceeds (spec §1.4/§4.1).
//    * Optional constraints are added at their mapped strength. They never throw;
//      a conflicting optional constraint is simply not satisfied (Auto Layout does
//      not log those as broken).
//    * Structurally invalid constraints that somehow bypass creation-time
//      validation (deallocated items, non-finite multiplier/constant, a baseline
//      attribute on an item without baseline metrics) are recorded as broken and
//      skipped instead of trapping: the legacy path must never crash on legacy
//      app input.
//    * Constraints that reference an item outside the solved subtree are skipped
//      silently: that is the parent's layout pass, exactly how UIKit attaches a
//      constraint to the closest common ancestor and only solves it there.
//
//  Autoresizing-mask translation (spec §3.1)
//  ------------------------------------------
//  For an item with `layoutTranslatesAutoresizingMaskIntoConstraints` the engine
//  generates the same four required constraints UIKit's
//  `NSAutoresizingMaskLayoutConstraint` does, driven by the item's
//  `layoutAutoresizingMask` and by `layoutAutoresizingReference` (the frame and
//  superview size the constraints were last generated from). When the current
//  superview size differs from the reference size, the equations are regenerated
//  from the *reference* geometry -- that is `-_resizeWithOldSuperviewSize:` --
//  and after a successful pass `layoutUpdateAutoresizingReference` stores the
//  solved frame + current superview size. Because they are required and are
//  installed before user constraints, a conflicting explicit required constraint
//  loses to the autoresizing constraint, which is what UIKit does (verified on the
//  simulator: autoresizing width == 200 beats explicit width == 300).
//
//  Inputs of `RRLayoutConstraint` are read once per pass. A fresh `Solver` is
//  created per pass: the pass count is low enough that rebuilding is simpler than
//  edit-variable bookkeeping and cannot carry stale state.
//
//  This file is new in the Swift port; it has no upstream counterpart.
//

import Foundation
import CoreGraphics

// `Foundation.Expression` (the iOS 18 Predicate type) collides with the
// Cassowary linear-expression type of the same name. Pin the solver names at
// file scope so the translation code below reads like the constraint algebra.



/// Builds and solves the constraint system for one root item.
internal final class LegacyLayoutSolver {

    // MARK: Item variables

    /// Four variables per item: origin and size on each axis.
    ///
    /// Auto Layout's other attributes are algebraic combinations of these, and
    /// this engine now expands them inline (maxX = minX + width, centerX =
    /// minX + width/2, baselines = edge + offset) instead of allocating
    /// additional variables plus a defining equality each. That removes 6
    /// variables and 6 solver rows per item from every build; the solution set
    /// is identical because the removed equations were exact definitions.
    ///
    /// `item` is weak so a persistent solver never keeps a removed view alive
    /// between passes. During a pass every item is alive (the caller holds the
    /// root and the pass holds its subtree strongly).
    private struct ItemVariables {
        let identifier: ObjectIdentifier
        weak var item: LegacyLayoutItem?
        let isRoot: Bool
        let minX: Variable
        let minY: Variable
        let width: Variable
        let height: Variable
    }

    /// A constraint translated into solver form.
    private struct CompiledConstraint {
        let source: RRLayoutConstraint
        let expression: Expression
        let `operator`: RelationalOperator
        let strength: Strength
        let name: String?

        var isRequired: Bool {
            return strength == Strength.required
        }
    }

    /// The documented "broken constraint" strength: not required, but above every
    /// externally specifiable priority (spec §1.4). Apple lowers a member of an
    /// unsatisfiable required set to this level instead of dropping it.
    private static let brokenStrength = Strength.clip(Strength.required.value - 1)

    // MARK: State

    /// The current pass's root. Weak: a persistent solver must not keep its
    /// root (and through it the whole view tree) alive between passes.
    private weak var rootStorage: LegacyLayoutItem?
    private var root: LegacyLayoutItem { rootStorage! }
    private var direction: RRLayoutDirection
    private let solver: LegacyLinearSolver = LegacySolverBackend.make()

    /// A finite axis is fixed at required strength; nil axes seek their smallest fitting size.
    /// Used by independently measured containers without changing ordinary root layout semantics.
    internal var fittingProposal: (width: CGFloat?, height: CGFloat?)?
    internal private(set) var fittedRootSize: CGSize = .zero

    // Per-pass structure; cleared after the result is built.
    private var items: [LegacyLayoutItem] = []
    private var itemIdentifiers: Set<ObjectIdentifier> = []
    private var itemOrder: [ObjectIdentifier] = []
    private var superitemIdentifiers: [ObjectIdentifier: ObjectIdentifier] = [:]
    private var firstBaselineOffsets: [ObjectIdentifier: CGFloat] = [:]
    private var lastBaselineOffsets: [ObjectIdentifier: CGFloat] = [:]
    private var variables: [ObjectIdentifier: ItemVariables] = [:]
    private var scrollContentSizes: [ObjectIdentifier: (width: Variable, height: Variable)] = [:]
    private var brokenConstraints: [RRLayoutConstraint] = []

    // Persistent (incremental) state. Everything here is kept in sync with the
    // tableau so the next pass only adds/removes/updates what changed.
    private var isInitialized = false
    private var installedItemOrder: [ObjectIdentifier] = []
    private var installedSuperitems: [ObjectIdentifier: ObjectIdentifier] = [:]
    private var installedRootSize: CGSize = .zero
    /// The two required rows pinning the root's width/height to its frame, kept so a changed root size is an in-place
    /// constant update (valid only while presolve has not folded the root dimensions into other rows).
    private var rootSizeConstraints: (width: Constraint?, height: Constraint?) = (nil, nil)
    private var rootSizeChangedPending = false
    /// Presolve folds required one-variable rows into constants, which is what makes first builds fast, but a root whose
    /// size or required constraints keep changing (a stack view that grows with its content) can never be updated in
    /// place while presolved, so every pass rebuilds. After repeated structural bails the root is rebuilt without
    /// presolve and stays on the incremental path.
    internal var presolveAllowed = true
    internal private(set) var presolveStructuralBails = 0
    internal func inheritPresolveHistory(from previous: LegacyLayoutSolver) {
        presolveStructuralBails = previous.presolveStructuralBails
        presolveAllowed = previous.presolveAllowed
    }
    internal var wantsPresolveDemotion: Bool { presolveStructuralBails >= 2 }
    private func notePresolveStructuralBail() { if solver.presolveActive { presolveStructuralBails += 1 } }
    private var installedDirection: RRLayoutDirection = .leftToRight
    private var installedUserConstraints: [ObjectIdentifier: InstalledUserConstraint] = [:]
    private var installedIntrinsicConstraints: [ObjectIdentifier: InstalledIntrinsicConstraints] = [:]
    private var installedAutoresizingConstraints: [ObjectIdentifier: InstalledAutoresizingConstraints] = [:]
    /// User constraints classified once per build (required rows go into the
    /// presolve batch, optional rows after it).
    private var userRequiredConstraints: [CompiledConstraint] = []
    private var userOptionalConstraints: [CompiledConstraint] = []
    /// Batch index -> caller constraint for the current build, so required rows
    /// that the presolve batch had to relax can be reported as broken like the
    /// ordinary install path does.
    private var presolveBatchSourceByIndex: [Int: RRLayoutConstraint] = [:]
    private var installedStays: [ObjectIdentifier: InstalledStays] = [:]
    /// Items deliberately WITHOUT stays because the constraints alone determine their frame. Weak stays only matter for
    /// under-constrained variables (UIKit's per-window engine keeps those where they were simply because the tableau
    /// persists); everything else pays rows and pivots for nothing. Re-checked after every pass.
    private var unstayedItems: Set<ObjectIdentifier> = []

    internal static let deferredStaysEnabled: Bool = !legacyEnvironmentFlag("LEGACY_AUTOLAYOUT_NO_DEFERRED_STAYS")
    private var usesDeferredStays: Bool { LegacyLayoutSolver.deferredStaysEnabled && fittingProposal == nil }
    internal private(set) var deferredStayInstalls = 0

    /// Installs stays for every unstayed item that has a variable the constraints do not determine.
    private func installStaysWhereUndetermined() {
        guard usesDeferredStays, !unstayedItems.isEmpty else { return }
        // Variables some REAL row pulls on, recomputed from what is installed right now (a removed constraint stops
        // counting). Implicit rows (size >= 0) and stays do not count: they would mention every variable.
        var mentionedVariableIDs = Set<ObjectIdentifier>()
        func note(_ constraints: [Constraint]) {
            for constraint in constraints { for term in constraint.expression.terms { mentionedVariableIDs.insert(ObjectIdentifier(term.variable)) } }
        }
        for (_, installed) in installedUserConstraints { note(installed.solverConstraints) }
        for (_, installed) in installedIntrinsicConstraints { note(installed.solverConstraints) }
        for (_, installed) in installedAutoresizingConstraints { note(installed.solverConstraints) }
        let rootIdentifier = ObjectIdentifier(root as AnyObject)
        let stayStrength = Strength.create(0, 0, 1)
        var absoluteOrigins: [ObjectIdentifier: CGPoint] = [:]
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            if identifier == rootIdentifier { absoluteOrigins[identifier] = CGPoint(x: 0, y: 0); continue }
            let values = stayValues(for: item, absoluteOrigins: &absoluteOrigins)
            guard unstayedItems.contains(identifier), let vars = variables[identifier] else { continue }
            // A stay is only redundant for a variable some real constraint pulls on: a user, intrinsic or autoresizing row
            // that mentions it. A variable nothing mentions rests wherever the tableau left it, and only its stay keeps it
            // at the incumbent geometry (UIKit's persistent tableau does that implicitly).
            let all = [vars.minX, vars.minY, vars.width, vars.height]
            var constrained = true
            for index in 0..<4 where values[index] != nil && !mentionedVariableIDs.contains(ObjectIdentifier(all[index])) { constrained = false; break }
            if constrained { continue }
            unstayedItems.remove(identifier)
            deferredStayInstalls += 1
            installedStays[identifier] = InstalledStays(
                constraints: installStayConstraints(values, vars: vars, strength: stayStrength), values: values)
        }
    }
    /// Cumulative bookkeeping counters (diagnostics).
    internal private(set) var installedConstraintCount = 0
    internal private(set) var removedConstraintCount = 0
    /// Per-pass counters, reset at the start of every pass.
    internal private(set) var passInstalledConstraints = 0
    internal private(set) var passRemovedConstraints = 0
    /// Mutations performed by the last incremental pass.
    private var changeCount = 0
    /// Signature of every user constraint seen by the last build (installed, dropped by presolve, or skipped), so a
    /// presolved system can prove "no input changed" without a tableau diff.
    private var builtUserSignatures: [ObjectIdentifier: ConstraintSignature] = [:]
    /// Set when the last `install` row was fully presolved: it was not added to
    /// the solver, so it must not be recorded as a solver constraint.
    private var lastInstallWasDropped = false
    /// The result of the last writing pass, served unchanged when nothing moved.
    private var lastResult: LegacyLayoutResult?
    /// Set when a build declined presolve because a required row would have been
    /// relaxed. Such a system keeps rebuilding on later passes: the ordinary path
    /// relaxes the row internally, so incremental diff bookkeeping is not a
    /// faithful description of the installed tableau.
    private var rebuildOnly = false
    /// Required constraints the presolve batch had to relax. They are baked into the presolved values, so an
    /// incremental pass cannot rediscover them; they stay broken for as long as the required inputs are unchanged.
    private var presolveBrokenSources: [RRLayoutConstraint] = []
    /// The mutation generation this solver's solution reflects. The engine
    /// returns `cachedLayoutResult` directly when the global generation still
    /// matches (O(1) no-change pass, no tree walk).
    internal private(set) var consumedGeneration = 0
    /// Whether the last `update` served the cached result without solving.
    internal private(set) var lastUpdateWasCached = false

    /// The previous pass's result, valid while the mutation generation matches.
    internal var cachedLayoutResult: LegacyLayoutResult? { lastResult }

    /// A previously installed user constraint.
    private struct InstalledUserConstraint {
        weak var source: RRLayoutConstraint?
        var signature: ConstraintSignature
        var solverConstraints: [Constraint]
        var broken: Bool
    }

    /// A previously installed intrinsic-content constraint pair for one item.
    private struct InstalledIntrinsicConstraints {
        var signature: IntrinsicSignature
        var solverConstraints: [Constraint]
    }

    /// A previously installed autoresizing-mask constraint set for one item.
    private struct InstalledAutoresizingConstraints {
        var signature: AutoresizingSignature
        var solverConstraints: [Constraint]
    }

    /// A previously installed stay set for one item. `fields` is in
    /// `[minX, minY, width, height]` order; a nil value means that field had no
    /// finite geometry and therefore no stay constraint.
    private struct InstalledStays {
        var constraints: [Constraint]
        var values: [Double?]
    }

    /// The immutable configuration of an installed user constraint, plus the
    /// mutable constant/priority, used to detect what changed.
    private struct ConstraintSignature: Equatable {
        var firstItem: ObjectIdentifier?
        var secondItem: ObjectIdentifier?
        var firstAttribute: Int
        var secondAttribute: Int
        var relation: Int
        var multiplier: Double
        var constant: Double
        var priority: Float
    }

    private struct IntrinsicSignature: Equatable {
        var width: Double
        var height: Double
        var huggingX: Float
        var huggingY: Float
        var compressionX: Float
        var compressionY: Float
    }

    private struct AutoresizingSignature: Equatable {
        var mask: UInt
        var parent: ObjectIdentifier?
        var frameX: Double
        var frameY: Double
        var frameWidth: Double
        var frameHeight: Double
        var superviewWidth: Double
        var superviewHeight: Double
    }

    // MARK: Init

    internal init(root: LegacyLayoutItem, direction: RRLayoutDirection) {
        self.rootStorage = root
        self.direction = direction
        self.installedDirection = direction
    }

    // MARK: Entry point

    /// Solves the tree. When `writingFrames` is `true` every non-root item's frame
    /// is written back through `layoutSetFrame` and the autoresizing references are
    /// advanced; the returned frames are identical either way.
    internal func solve(writingFrames: Bool) -> LegacyLayoutResult {
        var tt = LegacyBridgeStats.begin(); var ph = ""
        @inline(__always) func lap(_ n: String) { if tt != 0 { let t = DispatchTime.now().uptimeNanoseconds; ph += " \(n)=\((t - tt) / 1000)"; tt = t } }
        defer { if LegacyBridgeStats.enabled { FileHandle.standardError.write(Data(("legacy-phases:" + ph + "\n").utf8)) } }
        passInstalledConstraints = 0
        passRemovedConstraints = 0
        presolveBrokenSources.removeAll(keepingCapacity: true)
        collectItems()
        lap("collect")
        createVariables()
        lap("vars")
        // Allocation hint for the build path: per item the engine installs the
        // intrinsic size guarantees (2), the weak stays (4) and typically a few
        // user constraints, over 4 variables.
        solver.reserveCapacity(constraintCount: items.count * 10 + 4,
                               variableCount: items.count * 4)
        lap("reserve")
        prepareUserConstraints()
        lap("prep")
        guard Solver.presolvesEnabled && presolveAllowed else {
            // Presolve disabled (differential tests): the ordinary rebuild path,
            // exactly as before this round.
            installImplicitConstraints()
            installAutoresizingConstraints()
            installStays()
            installUserRequiredConstraints()
            installIntrinsicContentConstraints()
            installUserOptionalConstraints()
            installStaysWhereUndetermined()
            return finishSolve(writingFrames: writingFrames)
        }
        // Required rows are buffered so the guarded presolve can substitute
        // one-free-variable equalities before any tableau row is created. The
        // weak stays / intrinsic / optional rows go in afterwards and are
        // rewritten (or dropped) with the presolved values.
        // In strict compatibility mode Solver.presolvesEnabled is false, so
        // endPresolveBatch installs the buffered rows through the ordinary path.
        if LegacyLayoutEngine.strictRebuildMode {
            Solver.presolvesEnabled = false
        }
        solver.beginPresolveBatch()
        installImplicitConstraints()
        installAutoresizingConstraints()
        installUserRequiredConstraints()
        lap("req")
        solver.endPresolveBatch()
        lap("presolve")
        if !solver.presolveActive {
            // The build declined presolve (guard failed) but the ordinary path is
            // now in use. Keep rebuilding on later passes too: this guarantees the
            // shipped engine never mixes a presolve attempt with incremental
            // tableau diffs, so reported frames/broken constraints always come
            // from one consistent rebuild.
            rebuildOnly = true
        }
        if !solver.batchRejectedIndices.isEmpty {
            // A required row had to be relaxed while installing the batch. Report
            // the caller's constraint as broken (mapped by batch index, because the
            // installed row may be a rewritten/simplified copy) instead of
            // discarding the whole (cheap) batch and rebuilding through the
            // ordinary per-constraint path. That rebuild took a full tableau
            // snapshot per required row, which made the conflicting-autoresizing
            // churn path O(n^2) on device.
            for index in solver.batchRejectedIndices {
                guard let source = presolveBatchSourceByIndex[index] else { continue }
                if !brokenConstraints.contains(where: { $0 === source }) {
                    brokenConstraints.append(source)
                }
                presolveBrokenSources.append(source)
            }
        }
        installStays()
        lap("stays")
        installIntrinsicContentConstraints()
        lap("intrinsic")
        installUserOptionalConstraints()
        installStaysWhereUndetermined()
        lap("optional")
        let r = finishSolve(writingFrames: writingFrames)
        lap("finish")
        return r
    }

    /// Shared tail of a rebuild: record the installed structure, refresh external
    /// values, extract the result and advance the stays.
    private func finishSolve(writingFrames: Bool) -> LegacyLayoutResult {
        recordInstalledStructure()
        solver.updateVariables()
        if ProcessInfo.processInfo.environment["LEGACY_LAYOUT_RESIDUAL_DEBUG"] != nil {
            var out = ""
            let rootClass = String(describing: type(of: root as AnyObject))
            let firstItemClass = items.first.map { String(describing: type(of: $0 as AnyObject)) } ?? "none"
            out += "PASS root=\(ObjectIdentifier(root as AnyObject).hashValue) rootClass=\(rootClass) items=\(items.count) firstItem=\(firstItemClass)\n"
            func eval(_ e: Expression) -> Double {
                var v = e.constant
                for t in e.terms { v += t.coefficient * solver.value(of: t.variable) }
                return v
            }
            var labels: [ObjectIdentifier: String] = [:]
            for (identifier, vars) in variables {
                let item = vars.item as? UIView
                let hv = item.map { ObjectIdentifier($0).hashValue % 100000 } ?? -1
                let base = item == nil ? "?" : "v\(hv)"
                labels[ObjectIdentifier(vars.minX)] = base + ".minX"
                labels[ObjectIdentifier(vars.minY)] = base + ".minY"
                labels[ObjectIdentifier(vars.width)] = base + ".w"
                labels[ObjectIdentifier(vars.height)] = base + ".h"
                if let sc = scrollContentSizes[identifier] {
                    labels[ObjectIdentifier(sc.width)] = base + ".scW"
                    labels[ObjectIdentifier(sc.height)] = base + ".scH"
                }
            }
            let rootId = ObjectIdentifier(root as AnyObject).hashValue
            for cc in userRequiredConstraints + userOptionalConstraints {
                let r = eval(cc.expression)
                guard abs(r) > 1e-9 else { continue }
                let op = cc.operator == .equal ? "eq" : (cc.operator == .lessThanOrEqual ? "le" : "ge")
                let terms = cc.expression.terms.map { t -> String in
                    let lbl = labels[ObjectIdentifier(t.variable)] ?? "v\(t.variable.description)"
                    return t.coefficient == 1.0 ? lbl : "\(t.coefficient)*\(lbl)"
                }.joined(separator: " ")
                out += "RESID root=\(rootId) \(op) name=\(cc.name ?? "?") r=\(String(format: "%.6f", r)) [\(terms) c=\(cc.expression.constant)]\n"
            }
            if let cass = solver as? Solver {
                for (idx, row) in cass.constraints.enumerated() {
                    let r = eval(row.expression)
                    guard abs(r) > 1e-9 else { continue }
                    let op = row.op == .equal ? "eq" : (row.op == .lessThanOrEqual ? "le" : "ge")
                    let terms = row.expression.terms.map { t -> String in
                        let lbl = labels[ObjectIdentifier(t.variable)] ?? "v\(t.variable.description)"
                        return t.coefficient == 1.0 ? lbl : "\(t.coefficient)*\(lbl)"
                    }.joined(separator: " ")
                    out += "ROW root=\(rootId) #\(idx) \(op) s=\(row.strength) r=\(String(format: "%.6f", r)) [\(terms) c=\(row.expression.constant)]\n"
                }
            }
            for (identifier, vars) in variables {
                if identifier == ObjectIdentifier(root as AnyObject) { continue }
                let item = vars.item
                guard let v = item as? UIView else { continue }
                out += String(format: "SOLVED root=%d %@ hash=%d abs=(%.4f %.4f) size=(%.4f %.4f)\n",
                              rootId, String(describing: type(of: v)), ObjectIdentifier(v).hashValue,
                              solver.value(of: vars.minX), solver.value(of: vars.minY),
                              solver.value(of: vars.width), solver.value(of: vars.height))
            }
            if !out.isEmpty { FileHandle.standardError.write(Data(out.utf8)) }
        }
        let result = extractResult(writingFrames: writingFrames)
        if writingFrames {
            // A rebuild captures next pass's stays from the frames it just wrote.
            advanceStayValues(from: result)
            lastResult = result
        }
        // Keep the solver cache cheap and leak-free: the persistent state below
        // is all identity-based; the pass-local strong references are dropped.
        clearPassState()
        consumedGeneration = LegacyLayoutMutation.generation
        return result
    }

    /// Incremental pass for a persistent solver.
    ///
    /// Returns `nil` when the pass cannot be made equivalent to a full rebuild
    /// (item tree changed, root resized, direction changed, or the solver
    /// rejected an update); the caller then rebuilds with a fresh solver. The
    /// solver is left untouched in that case.
    internal static let experimentNoStays: Bool = legacyEnvironmentFlag("LEGACY_AUTOLAYOUT_NO_STAYS")
    internal static let depthOrderedInstall: Bool = !legacyEnvironmentFlag("LEGACY_AUTOLAYOUT_NO_DEPTH_ORDER")
    internal static let reverseInstall: Bool = legacyEnvironmentFlag("LEGACY_AUTOLAYOUT_REVERSE_INSTALL")
    internal static let verifyIncremental: Bool = legacyEnvironmentFlag("LEGACY_AUTOLAYOUT_VERIFY")

    internal static func bail(_ why: String) {
        LegacyLayoutDebug.bails[why, default: 0] += 1
        LegacyLayoutDebug.pendingBail = why
        if LegacyBridgeStats.enabled { FileHandle.standardError.write(Data("legacy-bail: \(why)\n".utf8)) }
    }

    internal func update(root: LegacyLayoutItem,
                         direction: RRLayoutDirection,
                         writingFrames: Bool) -> LegacyLayoutResult? {
        guard isInitialized else { LegacyLayoutSolver.bail("uninit"); return nil }
        if rebuildOnly || !solver.presolveActive {
            if rebuildOnly { LegacyLayoutSolver.bail("rebuildOnly"); return nil }
        }
        rootStorage = root
        guard direction == installedDirection else {
            rootStorage = nil
            LegacyLayoutSolver.bail("direction")
            return nil
        }
        self.direction = direction
        collectItems()
        defer { clearPassState() }
        guard let added = structureAdditions() else {
            LegacyLayoutSolver.bail(itemOrder != installedItemOrder ? "itemOrder" : (superitemIdentifiers != installedSuperitems ? "superitems" : "rootSize"))
            return nil
        }
        guard applyRootSizeChangeInPlace() else {
            notePresolveStructuralBail(); LegacyLayoutSolver.bail("rootSize")
            let now = root.layoutFrame.size
            let key = "w \(Int(installedRootSize.width))->\(Int(now.width)) h \(Int(installedRootSize.height))->\(Int(now.height)) presolve=\(solver.presolveActive)"
            LegacyLayoutDebug.bails["  rootSize " + key, default: 0] += 1
            return nil
        }
        if solver.presolveActive {
            // Presolve substituted variables that the REQUIRED rows determine. Everything the engine adds after the
            // batch (stays, intrinsic, optional user rows) is rewritten against those values and is held as ordinary
            // rows, so those can be diffed incrementally exactly like an unpresolved system. Only a change to a
            // required input (autoresizing plan, required user constraint) invalidates the substitution.
            guard presolvedRequiredInputsUnchanged(root: root, direction: direction, added: Set(added)) else { notePresolveStructuralBail(); return nil }
        }
        if !added.isEmpty { installAddedItems(added) }

        passInstalledConstraints = 0
        passRemovedConstraints = 0
        let changesBefore = changeCount
        if rootSizeChangedPending { changeCount += 1; rootSizeChangedPending = false }
        brokenConstraints.removeAll(keepingCapacity: true)
        for source in presolveBrokenSources where !brokenConstraints.contains(where: { $0 === source }) {
            brokenConstraints.append(source)
        }
        // Stays first: rebuilds capture them from the current frames, and the
        // incremental path keeps the installed rows in sync with constants only.
        guard refreshRequiredUserConstraints() else { LegacyLayoutSolver.bail("user"); return nil }
        guard refreshStays() else { LegacyLayoutSolver.bail("stays"); return nil }
        guard refreshIntrinsicAndOptionalConstraints() else { LegacyLayoutSolver.bail("user"); return nil }
        guard refreshAutoresizingConstraints() else { LegacyLayoutSolver.bail("autoresizing"); return nil }
        let stayInstallsBefore = deferredStayInstalls
        installStaysWhereUndetermined()
        if deferredStayInstalls != stayInstallsBefore { changeCount += 1 }
        if !added.isEmpty {
            installedItemOrder = itemOrder
            installedSuperitems = superitemIdentifiers
            changeCount += 1
        }

        builtUserSignatures.removeAll(keepingCapacity: true)
        for constraint in collectConstraints() { builtUserSignatures[ObjectIdentifier(constraint)] = constraintSignature(constraint) }
        if changeCount == changesBefore, let cached = lastResult {
            // Nothing the solver depends on moved: serve the previous solution
            // without touching the tableau or allocating a new result.
            lastUpdateWasCached = true
            clearPassState()
            consumedGeneration = LegacyLayoutMutation.generation
            return cached
        }
        lastUpdateWasCached = false
        solver.updateVariables()
        if LegacyLayoutSolver.verifyIncremental && solver.presolveActive {
            // Device verification: the incremental result must equal a fresh rebuild of the same inputs.
            let probe = extractResult(writingFrames: false)
            let fresh = LegacyLayoutSolver(root: root, direction: direction).solve(writingFrames: false)
            var bad = 0
            for (k, f) in fresh.frames where probe.frames[k] != f { bad += 1 }
            FileHandle.standardError.write(Data("legacy-verify: items=\(fresh.frames.count) mismatches=\(bad)\n".utf8))
        }
        let result = extractResult(writingFrames: writingFrames)
        advanceStayValues(from: result)
        if writingFrames { lastResult = result }
        clearPassState()
        consumedGeneration = LegacyLayoutMutation.generation
        return result
    }


    private func applyRootSizeChangeInPlace() -> Bool {
        let size = root.layoutFrame.size
        if size == installedRootSize { return true }
        guard fittingProposal == nil, !solver.presolveActive,
              size.width.isFinite, size.height.isFinite, installedRootSize.width.isFinite, installedRootSize.height.isFinite,
              let w = rootSizeConstraints.width, let h = rootSizeConstraints.height,
              solver.hasConstraint(w), solver.hasConstraint(h) else { return false }
        var updates: [(Constraint, Double)] = []
        if size.width != installedRootSize.width { updates.append((w, -Double(size.width))) }
        if size.height != installedRootSize.height { updates.append((h, -Double(size.height))) }
        do { try solver.updateConstraintConstants(updates) } catch { return false }
        installedRootSize = size
        rootSizeChangedPending = true     // counted after update() captures its baseline, or the pass would look unchanged
        return true
    }

    /// Compares the freshly collected tree with the installed one. `nil` = incompatible (rebuild); otherwise the
    /// identifiers of items that were ADDED since the last pass (empty when the structure is identical). Only pure
    /// additions are incremental: removals or reparenting would have to retract rows that are not tracked per item.
    private func structureAdditions() -> [ObjectIdentifier]? {
        if itemOrder == installedItemOrder { return superitemIdentifiers == installedSuperitems ? [] : nil }
        let known = Set(installedItemOrder)
        guard itemOrder.count > installedItemOrder.count else { return nil }
        var added: [ObjectIdentifier] = []
        var kept = 0
        for identifier in itemOrder {
            if known.contains(identifier) { kept += 1 } else { added.append(identifier) }
        }
        guard kept == installedItemOrder.count else { return nil }          // something was removed
        for identifier in itemOrder where known.contains(identifier) {
            // An existing item must keep its parent, and its parent must be an existing item.
            guard superitemIdentifiers[identifier] == installedSuperitems[identifier] else { return nil }
        }
        return added
    }

    /// Creates variables and the implicit rows for items added since the last pass.
    private func installAddedItems(_ added: [ObjectIdentifier]) {
        let rootIdentifier = ObjectIdentifier(root as AnyObject)
        let addedSet = Set(added)
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            guard addedSet.contains(identifier) else { continue }
            let vars = ItemVariables(identifier: identifier, item: item, isRoot: identifier == rootIdentifier,
                                     minX: Variable(), minY: Variable(), width: Variable(), height: Variable())
            variables[identifier] = vars
            installRequired(Expression(vars.width), .greaterThanOrEqual, name: "width >= 0")
            installRequired(Expression(vars.height), .greaterThanOrEqual, name: "height >= 0")
        }
    }

    /// True when nothing a presolve substitution depends on has changed: same tree, same root size, and every
    /// autoresizing plan and required user constraint carries the signature the last build used.
    private func presolvedRequiredInputsUnchanged(root: LegacyLayoutItem, direction: RRLayoutDirection, added: Set<ObjectIdentifier>) -> Bool {
        guard isInitialized, direction == installedDirection else { LegacyLayoutSolver.bail("pi:init/direction"); return false }
        let rootIdentifier = ObjectIdentifier(root as AnyObject)
        let fallbackSuperviewSize = root.layoutFrame.size
        var translating = 0
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            if identifier == rootIdentifier { continue }
            if added.contains(identifier) { continue }
            guard let vars = variables[identifier] else { LegacyLayoutSolver.bail("pi:novars"); return false }
            if item.layoutTranslatesAutoresizingMaskIntoConstraints {
                translating += 1
                guard let installed = installedAutoresizingConstraints[identifier],
                      installed.signature == autoresizingPlan(vars: vars, item: item, fallbackSuperviewSize: fallbackSuperviewSize).signature
                else { LegacyLayoutSolver.bail("pi:autoresizing"); return false }
            } else if installedAutoresizingConstraints[identifier] != nil { LegacyLayoutSolver.bail("pi:untranslated"); return false }
        }
        guard installedAutoresizingConstraints.count == translating else { LegacyLayoutSolver.bail("pi:transcount"); return false }
        var currentIDs = Set<ObjectIdentifier>()
        for constraint in collectConstraints() {
            let id = ObjectIdentifier(constraint)
            currentIDs.insert(id)
            if let built = builtUserSignatures[id] {
                // An existing constraint whose inputs changed may have been folded into a presolved value; only a
                // non-required one can be re-installed incrementally.
                // A changed required constraint can be re-installed incrementally only when its old row is held by
                // the tableau. One that presolve folded away (installed nothing) may have fixed a presolved value.
                if built != constraintSignature(constraint),
                   (built.priority >= RRLayoutPriorityValue.required || constraint.priority >= RRLayoutPriorityValue.required) {
                    LegacyLayoutSolver.bail("pi:requser"); return false
                }
            } else if !constraintTouchesAdded(constraint, added) {
                LegacyLayoutSolver.bail("pi:newuser"); return false
            }
        }
        // A constraint that disappeared may be baked into the presolved values: retracting it is not possible.
        // Likewise a removed constraint is retractable only when a row of it is held by the tableau.
        for id in builtUserSignatures.keys where !currentIDs.contains(id) {
            LegacyLayoutSolver.bail("pi:removeduser"); return false
        }
        return true
    }

    private func constraintTouchesAdded(_ constraint: RRLayoutConstraint, _ added: Set<ObjectIdentifier>) -> Bool {
        if added.isEmpty { return false }
        if let first = constraint.firstItem as AnyObject?, added.contains(ObjectIdentifier(first)) { return true }
        if let second = constraint.secondItem as AnyObject?, added.contains(ObjectIdentifier(second)) { return true }
        return false
    }

    /// Whether this solver knows the current pass's structure (used by tests).
    internal var canUpdateIncrementally: Bool { isInitialized }

    /// Symbols known to the tableau after the last pass.
    internal var tableauVariableCount: Int { solver.variableCount }

    internal static var replayStats: (total: Int, presolved: Int) { Solver.replayStats }

    internal var tableauDensity: (rows: Int, cells: Int, maxRow: Int, maxCol: Int) { solver.density }

    /// Rows held by the tableau after the last pass.
    internal var tableauConstraintCount: Int { solver.constraintCount }

    private func clearPassState() {
        items.removeAll(keepingCapacity: true)
        itemIdentifiers.removeAll(keepingCapacity: true)
        itemOrder.removeAll(keepingCapacity: true)
        superitemIdentifiers.removeAll(keepingCapacity: true)
        firstBaselineOffsets.removeAll(keepingCapacity: true)
        lastBaselineOffsets.removeAll(keepingCapacity: true)
        passConstraintCache = nil
        passSignatureCache.removeAll(keepingCapacity: true)
        rootStorage = nil
    }

    private func recordInstalledStructure() {
        installedItemOrder = itemOrder
        installedSuperitems = superitemIdentifiers
        installedRootSize = root.layoutFrame.size
        installedDirection = direction
        isInitialized = true
    }

    // MARK: Collection

    /// Pre-order walk of the subtree. Cycles (a malformed tree) are tolerated by
    /// the visited set; each item is laid out once.
    private func collectItems() {
        var visited: Set<ObjectIdentifier> = []
        var stack: [LegacyLayoutItem] = [root]
        while let item = stack.popLast() {
            let identifier = ObjectIdentifier(item as AnyObject)
            if visited.contains(identifier) {
                continue
            }
            visited.insert(identifier)
            items.append(item)
            itemOrder.append(identifier)
            if let superitem = item.layoutSuperitem, visited.contains(ObjectIdentifier(superitem as AnyObject)) {
                superitemIdentifiers[identifier] = ObjectIdentifier(superitem as AnyObject)
            }
            if finite(item.layoutFirstBaselineOffsetFromTop) != nil {
                firstBaselineOffsets[identifier] = item.layoutFirstBaselineOffsetFromTop!
            }
            if finite(item.layoutLastBaselineOffsetFromBottom) != nil {
                lastBaselineOffsets[identifier] = item.layoutLastBaselineOffsetFromBottom!
            }
            let subitems = item.layoutSubitems
            var index = subitems.count - 1
            while index >= 0 {
                stack.append(subitems[index])
                index -= 1
            }
        }
        itemIdentifiers = visited
    }

    private func createVariables() {
        let rootIdentifier = ObjectIdentifier(root as AnyObject)
        variables.reserveCapacity(items.count)
        for item in items {
            if item.layoutHasScrollContent {
                scrollContentSizes[ObjectIdentifier(item as AnyObject)] = (Variable(), Variable())
            }
            let identifier = ObjectIdentifier(item as AnyObject)
            // Names are debug-only; empty names avoid one string allocation and
            // interpolation per variable in the build path.
            variables[identifier] = ItemVariables(
                identifier: identifier,
                item: item,
                isRoot: identifier == rootIdentifier,
                minX: Variable(),
                minY: Variable(),
                width: Variable(),
                height: Variable()
            )
        }
    }

    // MARK: Implicit (system) constraints

    private func installImplicitConstraints() {
        // The per-item geometry equations that used to define maxX/maxY/centerX/
        // centerY (and baseline variables) are gone: `expression(for:attribute:)`
        // expands those attributes algebraically from origin+size, which is the
        // same solution set without the extra variables and rows.

        // 2. Sizes can never be negative (documented UIKit behaviour, engine-level
        //    inequality rather than an NSLayoutConstraint; spec §3.3).
        for item in items {
            guard let vars = variables[ObjectIdentifier(item as AnyObject)], !vars.isRoot else {
                continue
            }
            installRequired(Expression(vars.width), .greaterThanOrEqual, name: "width >= 0")
            installRequired(Expression(vars.height), .greaterThanOrEqual, name: "height >= 0")
        }

        for (_, size) in scrollContentSizes {
            installRequired(Expression(size.width), .greaterThanOrEqual, name: "scroll content width >= 0")
            installRequired(Expression(size.height), .greaterThanOrEqual, name: "scroll content height >= 0")
            _ = install(Expression(size.width), .equal, strength: .weak, name: "scroll fitting width")
            _ = install(Expression(size.height), .equal, strength: .weak, name: "scroll fitting height")
        }

        // 3. The root is the container: fix its geometry. The solver works in the
        //    root's LOCAL coordinate space (origin 0,0 + the root's bounds size),
        //    because a subitem's `layoutFrame` is relative to its superitem. If the
        //    root's origin were pinned to its frame origin instead, every constraint
        //    inside a moved container would be offset by that origin.
        if let rootVariables = variables[ObjectIdentifier(root as AnyObject)] {
            let frame = root.layoutFrame
            installRequired(Expression(rootVariables.minX), .equal, name: "root: minX = 0")
            installRequired(Expression(rootVariables.minY), .equal, name: "root: minY = 0")
            if let proposal = fittingProposal {
                installRequired(Expression(rootVariables.width), .greaterThanOrEqual, name: "fitting width >= 0")
                installRequired(Expression(rootVariables.height), .greaterThanOrEqual, name: "fitting height >= 0")
                let fitting = RRLayoutPriorityMapping.strength(for: RRLayoutPriorityValue.fittingSizeLevel)
                _ = install(Expression(rootVariables.width).minus(Expression(constant: Double(proposal.width ?? 0))),
                            .equal, strength: proposal.width == nil ? fitting : .required, name: "fitting width")
                _ = install(Expression(rootVariables.height).minus(Expression(constant: Double(proposal.height ?? 0))),
                            .equal, strength: proposal.height == nil ? fitting : .required, name: "fitting height")
            } else {
                rootSizeConstraints = (nil, nil)
                if frame.width.isFinite {
                    rootSizeConstraints.width = install(Expression(rootVariables.width).minus(Expression(constant: Double(frame.width))),
                                                        .equal, strength: .required, name: "root: width = frame.width")
                }
                if frame.height.isFinite {
                    rootSizeConstraints.height = install(Expression(rootVariables.height).minus(Expression(constant: Double(frame.height))),
                                                         .equal, strength: .required, name: "root: height = frame.height")
                }
            }
        }
    }

    // MARK: Autoresizing-mask translation

    /// The equations for one item's autoresizing translation, plus the input
    /// signature used to detect changes in the incremental path.
    private struct AutoresizingPlan {
        var signature: AutoresizingSignature
        var expressions: [(expression: Expression, op: RelationalOperator, name: String?)]
    }

    /// Generates UIKit's autoresizing-mask constraints (spec §3.1). Runs before the
    /// user constraints so a conflicting explicit required constraint is the one
    /// that gets broken, matching UIKit. Used by a full rebuild; the incremental
    /// path diffs the same plan.
    private func installAutoresizingConstraints() {
        let fallbackSuperviewSize = root.layoutFrame.size
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            guard let vars = variables[identifier], !vars.isRoot else { continue }
            guard item.layoutTranslatesAutoresizingMaskIntoConstraints else { continue }
            let plan = autoresizingPlan(vars: vars, item: item, fallbackSuperviewSize: fallbackSuperviewSize)
            var installed: [Constraint] = []
            installed.reserveCapacity(plan.expressions.count)
            for entry in plan.expressions {
                if let constraint = install(entry.expression, entry.op, strength: .required, name: entry.name) {
                    installed.append(constraint)
                }
            }
            installedAutoresizingConstraints[identifier] =
                InstalledAutoresizingConstraints(signature: plan.signature,
                                                 solverConstraints: installed)
        }
    }

    /// The equations for one item's autoresizing translation. `x0, w0` come from
    /// the captured reference geometry, `W0` from the reference superview size:
    ///
    ///     .flexibleWidth:                      minX == x0
    ///                                          superview.width == maxX + (W0 - (x0 + w0))
    ///     .flexibleLeftMargin + rightMargin:   width == w0
    ///                                          minX == r * superview.width - r * w0   (r = x0 / (W0 - w0))
    ///     .flexibleLeftMargin only:            width == w0
    ///                                          superview.width == maxX + (W0 - (x0 + w0))
    ///     otherwise (right margin flexible/[]): width == w0; minX == x0
    private func autoresizingPlan(vars: ItemVariables,
                                  item: LegacyLayoutItem,
                                  fallbackSuperviewSize: CGSize) -> AutoresizingPlan {
        let currentFrame = item.layoutFrame
        let currentSuperviewSize = superviewSize(of: item, fallback: fallbackSuperviewSize)
        let reference: LegacyAutoresizingReference
        if let stored = item.layoutAutoresizingReference,
           isFinite(stored.frame), isFinite(stored.superviewSize) {
            reference = stored
        } else {
            // First pass (or corrupt storage): generate from the current
            // geometry; this is also where UIKit lazily creates them.
            reference = LegacyAutoresizingReference(frame: currentFrame,
                                                    superviewSize: currentSuperviewSize)
        }
        let signature = AutoresizingSignature(
            mask: item.layoutAutoresizingMask.rawValue,
            parent: superitemIdentifiers[vars.identifier],
            frameX: Double(reference.frame.minX),
            frameY: Double(reference.frame.minY),
            frameWidth: Double(reference.frame.width),
            frameHeight: Double(reference.frame.height),
            superviewWidth: Double(reference.superviewSize.width),
            superviewHeight: Double(reference.superviewSize.height)
        )
        var expressions: [(expression: Expression, op: RelationalOperator, name: String?)] = []
        expressions.reserveCapacity(4)
        guard isFinite(reference.frame), isFinite(reference.superviewSize) else {
            // Unusable geometry: fall back to pinning the current frame.
            appendPinFrame(vars, frame: currentFrame, into: &expressions)
            return AutoresizingPlan(signature: signature, expressions: expressions)
        }
        appendHorizontalAutoresizingConstraints(vars: vars,
                                                mask: item.layoutAutoresizingMask,
                                                reference: reference,
                                                superviewSize: reference.superviewSize,
                                                into: &expressions)
        appendVerticalAutoresizingConstraints(vars: vars,
                                              mask: item.layoutAutoresizingMask,
                                              reference: reference,
                                              superviewSize: reference.superviewSize,
                                              into: &expressions)
        return AutoresizingPlan(signature: signature, expressions: expressions)
    }

    private func appendHorizontalAutoresizingConstraints(
        vars: ItemVariables,
        mask: RRAutoresizingMask,
        reference: LegacyAutoresizingReference,
        superviewSize: CGSize,
        into expressions: inout [(expression: Expression, op: RelationalOperator, name: String?)]
    ) {
        let frame = reference.frame
        let x0 = frame.minX
        let w0 = frame.width
        let superviewWidth = superviewSize.width
        let rightGap = superviewWidth - (x0 + w0)
        let superviewWidthExpression = widthExpression(ofSuperviewOf: vars)
            ?? Expression(constant: Double(superviewWidth))
        // The measured UIKit constraints are expressed in the superview's
        // coordinate space (`child.minX == x0`); this engine solves in absolute
        // root-local coordinates, so absolute-position equations subtract the
        // superview's origin variable.
        let superviewMinXExpression = minXExpression(ofSuperviewOf: vars) ?? Expression(constant: 0)
        let frameMinX = Expression(vars.minX).minus(superviewMinXExpression)

        // Apple distributes the container's size delta among the flexible components (start margin,
        // size, end margin) proportionally to their lengths at reference time. Verified against UIKit:
        // container 320->400 with a 10pt left margin and 100pt width gives width 173 (80*100/110) and
        // x 17 (80*10/110). Flexible components whose lengths are all zero split the delta evenly.
        let flexibleStart = mask.contains(.flexibleLeftMargin)
        let flexibleSize = mask.contains(.flexibleWidth)
        let flexibleEnd = mask.contains(.flexibleRightMargin)
        let weight = (flexibleStart ? x0 : 0) + (flexibleSize ? w0 : 0) + (flexibleEnd ? rightGap : 0)
        let flexibleCount = [flexibleStart, flexibleSize, flexibleEnd].filter { $0 }.count
        if flexibleCount > 0 {
            let denominator = weight > 0 ? weight : 1
            let startShare: Double = flexibleStart ? (weight > 0 ? x0 / denominator : 1 / Double(flexibleCount)) : 0
            let sizeShare: Double = flexibleSize ? (weight > 0 ? w0 / denominator : 1 / Double(flexibleCount)) : 0
            let delta = superviewWidthExpression.minus(Expression(constant: Double(superviewWidth)))
            expressions.append((frameMinX.minus(delta.times(Double(startShare))).minus(Expression(constant: Double(x0))),
                                .equal, "autoresizing: proportional minX"))
            expressions.append((Expression(vars.width).minus(delta.times(Double(sizeShare))).minus(Expression(constant: Double(w0))),
                                .equal, "autoresizing: proportional width"))
        } else {
            expressions.append((Expression(vars.width).minus(Expression(constant: Double(w0))),
                                .equal, "autoresizing: width = w0"))
            expressions.append((frameMinX.minus(Expression(constant: Double(x0))),
                                .equal, "autoresizing: minX = x0"))
        }
    }


    /// Vertical axis of the autoresizing translation; symmetric to the horizontal
    /// one with `y`, `height`, `topMargin` and `bottomMargin`.
    private func appendVerticalAutoresizingConstraints(
        vars: ItemVariables,
        mask: RRAutoresizingMask,
        reference: LegacyAutoresizingReference,
        superviewSize: CGSize,
        into expressions: inout [(expression: Expression, op: RelationalOperator, name: String?)]
    ) {
        let frame = reference.frame
        let y0 = frame.minY
        let h0 = frame.height
        let superviewHeight = superviewSize.height
        let bottomGap = superviewHeight - (y0 + h0)
        let superviewHeightExpression = heightExpression(ofSuperviewOf: vars)
            ?? Expression(constant: Double(superviewHeight))
        let superviewMinYExpression = minYExpression(ofSuperviewOf: vars) ?? Expression(constant: 0)
        let frameMinY = Expression(vars.minY).minus(superviewMinYExpression)

        let flexibleStart = mask.contains(.flexibleTopMargin)
        let flexibleSize = mask.contains(.flexibleHeight)
        let flexibleEnd = mask.contains(.flexibleBottomMargin)
        let weight = (flexibleStart ? y0 : 0) + (flexibleSize ? h0 : 0) + (flexibleEnd ? bottomGap : 0)
        let flexibleCount = [flexibleStart, flexibleSize, flexibleEnd].filter { $0 }.count
        if flexibleCount > 0 {
            let denominator = weight > 0 ? weight : 1
            let startShare: Double = flexibleStart ? (weight > 0 ? y0 / denominator : 1 / Double(flexibleCount)) : 0
            let sizeShare: Double = flexibleSize ? (weight > 0 ? h0 / denominator : 1 / Double(flexibleCount)) : 0
            let delta = superviewHeightExpression.minus(Expression(constant: Double(superviewHeight)))
            expressions.append((frameMinY.minus(delta.times(Double(startShare))).minus(Expression(constant: Double(y0))),
                                .equal, "autoresizing: proportional minY"))
            expressions.append((Expression(vars.height).minus(delta.times(Double(sizeShare))).minus(Expression(constant: Double(h0))),
                                .equal, "autoresizing: proportional height"))
        } else {
            expressions.append((Expression(vars.height).minus(Expression(constant: Double(h0))),
                                .equal, "autoresizing: height = h0"))
            expressions.append((frameMinY.minus(Expression(constant: Double(y0))),
                                .equal, "autoresizing: minY = y0"))
        }
    }

    /// Pins all four attributes to `frame` (the degenerate fallback when the
    /// autoresizing geometry is unusable).
    private func appendPinFrame(_ vars: ItemVariables,
                                frame: CGRect,
                                into expressions: inout [(expression: Expression, op: RelationalOperator, name: String?)]) {
        if frame.minX.isFinite {
            expressions.append((Expression(vars.minX).minus(Expression(constant: Double(frame.minX))),
                                .equal, "fallback: minX"))
        }
        if frame.minY.isFinite {
            expressions.append((Expression(vars.minY).minus(Expression(constant: Double(frame.minY))),
                                .equal, "fallback: minY"))
        }
        if frame.width.isFinite {
            expressions.append((Expression(vars.width).minus(Expression(constant: Double(max(0, frame.width)))),
                                .equal, "fallback: width"))
        }
        if frame.height.isFinite {
            expressions.append((Expression(vars.height).minus(Expression(constant: Double(max(0, frame.height)))),
                                .equal, "fallback: height"))
        }
    }

    /// The current size of an item's superview, used for autoresizing equations
    /// and for advancing the reference after a pass.
    private func superviewSize(of item: LegacyLayoutItem, fallback: CGSize) -> CGSize {
        guard let superitem = item.layoutSuperitem else {
            return fallback
        }
        let frame = superitem.layoutFrame
        if frame.width.isFinite, frame.height.isFinite {
            return frame.size
        }
        return fallback
    }

    private func superVariables(of vars: ItemVariables) -> ItemVariables? {
        guard let superIdentifier = superitemIdentifiers[vars.identifier] else { return nil }
        return variables[superIdentifier]
    }

    private func minXExpression(ofSuperviewOf vars: ItemVariables) -> Expression? {
        guard let superVariables = superVariables(of: vars) else { return nil }
        return Expression(superVariables.minX)
    }

    private func minYExpression(ofSuperviewOf vars: ItemVariables) -> Expression? {
        guard let superVariables = superVariables(of: vars) else { return nil }
        return Expression(superVariables.minY)
    }

    private func widthExpression(ofSuperviewOf vars: ItemVariables) -> Expression? {
        guard let superVariables = superVariables(of: vars) else { return nil }
        return Expression(superVariables.width)
    }

    private func heightExpression(ofSuperviewOf vars: ItemVariables) -> Expression? {
        guard let superVariables = superVariables(of: vars) else { return nil }
        return Expression(superVariables.height)
    }

    // MARK: Stays

    /// The four stay values for one item, in `[minX, minY, width, height]` order.
    /// A nil entry has no finite geometry and gets no stay constraint.
    private typealias StayValues = [Double?]

    /// Computes one item's desired stay values and records its absolute origin
    /// for its children (the tree is walked in pre-order, parents first).
    private func stayValues(for item: LegacyLayoutItem,
                            absoluteOrigins: inout [ObjectIdentifier: CGPoint]) -> StayValues {
        let currentFrame = item.layoutFrame
        let parentAbsolute = parentAbsoluteOrigin(of: item, absoluteOrigins: absoluteOrigins)
        let absoluteX = parentAbsolute.x + (currentFrame.minX.isFinite ? currentFrame.minX : 0)
        let absoluteY = parentAbsolute.y + (currentFrame.minY.isFinite ? currentFrame.minY : 0)
        absoluteOrigins[ObjectIdentifier(item as AnyObject)] = CGPoint(x: absoluteX, y: absoluteY)
        return [currentFrame.minX.isFinite ? Double(absoluteX) : nil,
                currentFrame.minY.isFinite ? Double(absoluteY) : nil,
                currentFrame.width.isFinite ? Double(max(0, currentFrame.width)) : nil,
                currentFrame.height.isFinite ? Double(max(0, currentFrame.height)) : nil]
    }

    /// Installs the stay constraints for the values.
    private func installStayConstraints(_ values: StayValues,
                                        vars: ItemVariables,
                                        strength: Strength) -> [Constraint] {
        var installed: [Constraint] = []
        if LegacyLayoutSolver.experimentNoStays { return [] }
        installed.reserveCapacity(4)
        for index in 0..<4 {
            guard let value = values[index] else { continue }
            // `variable - value == 0` built directly: one Expression instead of
            // three (the previous minus(Expression(constant:)) form allocated a
            // constant expression plus a result per stay).
            let expression: Expression
            switch index {
            case 0: expression = Expression(vars.minX)
            case 1: expression = Expression(vars.minY)
            case 2: expression = Expression(vars.width)
            default: expression = Expression(vars.height)
            }
            expression.constant = -value
            if let constraint = install(expression, .equal, strength: strength, name: nil) {
                installed.append(constraint)
            }
        }
        return installed
    }

    /// Weak stay constraints pinning each non-root item's absolute position and
    /// size to its current geometry (root-local coordinates). See the header
    /// comment: this keeps ancestor-derived geometry stable across the per-view
    /// layout passes the UIKit bridge drives. Fully determined layouts are
    /// unaffected because `.weak` is below every user priority.
    private func installStays() {
        let rootIdentifier = ObjectIdentifier(root as AnyObject)
        let stayStrength = Strength.create(0, 0, 1)
        var absoluteOrigins: [ObjectIdentifier: CGPoint] = [:]
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            if identifier == rootIdentifier {
                absoluteOrigins[identifier] = CGPoint(x: 0, y: 0)
                continue
            }
            let values = stayValues(for: item, absoluteOrigins: &absoluteOrigins)
            guard let vars = variables[identifier] else { continue }
            if usesDeferredStays { unstayedItems.insert(identifier); continue }
            installedStays[identifier] = InstalledStays(
                constraints: installStayConstraints(values, vars: vars, strength: stayStrength),
                values: values)
        }
    }

    /// Brings the stay constraints in line with the current frames. Values are
    /// updated in place (one batched dual re-optimization) whenever the shape of
    /// the stay set is unchanged, which is the common case.
    private func refreshStays() -> Bool {
        let rootIdentifier = ObjectIdentifier(root as AnyObject)
        let stayStrength = Strength.create(0, 0, 1)
        var absoluteOrigins: [ObjectIdentifier: CGPoint] = [:]
        var updates: [(Constraint, Double)] = []
        var installedByItem: [(ObjectIdentifier, ItemVariables, StayValues, InstalledStays?)] = []
        installedByItem.reserveCapacity(items.count)
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            if identifier == rootIdentifier {
                absoluteOrigins[identifier] = CGPoint(x: 0, y: 0)
                continue
            }
            let values = stayValues(for: item, absoluteOrigins: &absoluteOrigins)
            guard let vars = variables[identifier] else { return false }
            installedByItem.append((identifier, vars, values, installedStays[identifier]))
        }

        for (identifier, vars, values, installed) in installedByItem {
            let desiredCount = values.lazy.filter { $0 != nil }.count
            if usesDeferredStays && (installed == nil || unstayedItems.contains(identifier)) {
                unstayedItems.insert(identifier)
                continue
            }
            guard let installed = installed else {
                installedStays[identifier] = InstalledStays(
                    constraints: installStayConstraints(values, vars: vars, strength: stayStrength),
                    values: values)
                continue
            }
            if installed.values == values { continue }
            if installed.constraints.count == desiredCount {
                // Same shape: move the constants only.
                var index = 0
                for field in 0..<4 {
                    guard let value = values[field] else { continue }
                    let constraint = installed.constraints[index]
                    index += 1
                    updates.append((constraint, -value))
                }
                installedStays[identifier] = InstalledStays(constraints: installed.constraints, values: values)
            } else {
                if !removeSolverConstraints(installed.constraints) { return false }
                installedStays[identifier] = InstalledStays(
                    constraints: installStayConstraints(values, vars: vars, strength: stayStrength),
                    values: values)
            }
        }

        if !updates.isEmpty {
            do { try solver.updateConstraintConstants(updates) } catch { return false }
            changeCount += 1
        }
        return true
    }

    /// After a solved pass, moves the stay targets to the solved geometry. The
    /// next dirty pass then sees frames == stay targets and does no re-solve
    /// work for the steady state. This mirrors a rebuild, which captures stays
    /// from the frames that the previous pass wrote.
    private func advanceStayValues(from result: LegacyLayoutResult) {
        let rootIdentifier = ObjectIdentifier(root as AnyObject)
        var absoluteOrigins: [ObjectIdentifier: CGPoint] = [:]
        var updates: [(Constraint, Double)] = []
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            if identifier == rootIdentifier {
                absoluteOrigins[identifier] = CGPoint(x: 0, y: 0)
                continue
            }
            guard let frame = result.frames[identifier] else { continue }
            let parentAbsolute = parentAbsoluteOrigin(of: item, absoluteOrigins: absoluteOrigins)
            let absoluteX = parentAbsolute.x + (frame.minX.isFinite ? frame.minX : 0)
            let absoluteY = parentAbsolute.y + (frame.minY.isFinite ? frame.minY : 0)
            absoluteOrigins[identifier] = CGPoint(x: absoluteX, y: absoluteY)
            guard let installed = installedStays[identifier] else { continue }
            let values: StayValues = [frame.minX.isFinite ? Double(absoluteX) : nil,
                                      frame.minY.isFinite ? Double(absoluteY) : nil,
                                      frame.width.isFinite ? Double(max(0, frame.width)) : nil,
                                      frame.height.isFinite ? Double(max(0, frame.height)) : nil]
            guard installed.values != values, installed.constraints.count == values.lazy.filter({ $0 != nil }).count else {
                continue
            }
            var index = 0
            for field in 0..<4 {
                guard let value = values[field] else { continue }
                updates.append((installed.constraints[index], -value))
                index += 1
            }
            installedStays[identifier] = InstalledStays(constraints: installed.constraints, values: values)
        }
        if !updates.isEmpty {
            _ = try? solver.updateConstraintConstants(updates)
        }
    }

    // MARK: User constraints

    /// Full rebuild of the user constraints; also records what was installed so
    /// later passes can diff against it.
    /// Classifies the subtree's user constraints once per build; the required
    /// rows are installed in the presolve batch, the optional ones afterwards.
    private func prepareUserConstraints() {
        let constraints = collectConstraints()
        builtUserSignatures.removeAll(keepingCapacity: true)
        for constraint in constraints { builtUserSignatures[ObjectIdentifier(constraint)] = constraintSignature(constraint) }
        userRequiredConstraints.removeAll(keepingCapacity: true)
        userOptionalConstraints.removeAll(keepingCapacity: true)
        userRequiredConstraints.reserveCapacity(constraints.count)
        for constraint in constraints {
            guard let compiled = compile(constraint) else {
                continue
            }
            if compiled.isRequired {
                userRequiredConstraints.append(compiled)
            } else {
                userOptionalConstraints.append(compiled)
            }
        }
    }

    /// Required user rows. A required constraint that cannot be satisfied is
    /// recorded as broken and re-added at the documented "broken" strength so it
    /// still influences the solve as the first thing to satisfy.
    private func installUserRequiredConstraints() {
        for compiled in userRequiredConstraints {
            installUserConstraint(compiled)
        }
    }

    /// Optional user rows, at their mapped strengths.
    private func installUserOptionalConstraints() {
        for compiled in userOptionalConstraints {
            installUserConstraint(compiled)
        }
    }

    /// Installs one compiled user constraint and records its bookkeeping. A
    /// required constraint the solver rejects is recorded as broken and retried
    /// at the documented "broken" strength.
    private func installUserConstraint(_ compiled: CompiledConstraint) {
        let identifier = ObjectIdentifier(compiled.source)
        if let constraint = install(compiled.expression, compiled.operator,
                                    strength: compiled.strength, name: compiled.name,
                                    source: compiled.source) {
            installedUserConstraints[identifier] = InstalledUserConstraint(
                source: compiled.source,
                signature: constraintSignature(compiled.source),
                solverConstraints: [constraint],
                broken: false)
            return
        }
        if lastInstallWasDropped {
            // Presolve reduced this row to a satisfied (optional) constant; the
            // solver never saw it, so there is nothing to record.
            return
        }
        brokenConstraints.append(compiled.source)
        // Use a distinct Expression instance for the retry so the solver never
        // sees the same row object twice.
        let relaxedExpression = compiled.expression.plus(Expression(constant: 0))
        var installed: [Constraint] = []
        if let relaxed = install(relaxedExpression, compiled.operator,
                                 strength: LegacyLayoutSolver.brokenStrength,
                                 name: compiled.name) {
            installed.append(relaxed)
        }
        installedUserConstraints[identifier] = InstalledUserConstraint(
            source: compiled.source,
            signature: constraintSignature(compiled.source),
            solverConstraints: installed,
            broken: true)
    }

    /// Incremental user-constraint diff. Returns `false` when the solver could
    /// not apply the change; the caller then rebuilds.
    /// Optional user rows deferred by `refreshRequiredUserConstraints` until stays and intrinsic rows are in, so an
    /// incremental pass installs rows in the same order as a full rebuild (required, stays, intrinsic, optional).
    private var pendingOptionalUserConstraints: [CompiledConstraint] = []


    /// Stable sort of compiled rows by the depth of the view that owns them (deepest first). Ownership = the shallowest
    /// of the constraint's items' depths is what ties it to the rest of the tree, so rows whose items are all deep go first.
    private func depthOrdered(_ rows: [CompiledConstraint]) -> [CompiledConstraint] {
        var depthCache: [ObjectIdentifier: Int] = [:]
        func depth(_ item: LegacyLayoutItem) -> Int {
            let id = ObjectIdentifier(item as AnyObject)
            if let d = depthCache[id] { return d }
            var d = 0; var cursor = item.layoutSuperitem
            while let c = cursor { d += 1; cursor = c.layoutSuperitem; if d > 200 { break } }
            depthCache[id] = d
            return d
        }
        func rank(_ row: CompiledConstraint) -> Int {
            var shallowest = Int.max
            if let a = row.source.firstItem as AnyObject? as? LegacyLayoutItem { shallowest = min(shallowest, depth(a)) }
            if let b = row.source.secondItem as AnyObject? as? LegacyLayoutItem { shallowest = min(shallowest, depth(b)) }
            return shallowest == Int.max ? 0 : shallowest
        }
        let ranked = rows.enumerated().map { (index: $0.offset, rank: rank($0.element), row: $0.element) }
        return ranked.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.index < $1.index }.map { $0.row }
    }

    private func refreshUserConstraints() -> Bool {
        guard refreshRequiredUserConstraints() else { return false }
        return refreshIntrinsicAndOptionalConstraints()
    }

    private func refreshRequiredUserConstraints() -> Bool {
        pendingOptionalUserConstraints.removeAll(keepingCapacity: true)
        let constraints = collectConstraints()
        var currentIdentifiers: Set<ObjectIdentifier> = []
        currentIdentifiers.reserveCapacity(constraints.count)
        var required: [CompiledConstraint] = []
        var optional: [CompiledConstraint] = []
        for constraint in constraints {
            let identifier = ObjectIdentifier(constraint)
            currentIdentifiers.insert(identifier)
            if let installed = installedUserConstraints[identifier],
               installed.source === constraint,
               installed.signature == constraintSignature(constraint) {
                if installed.broken { brokenConstraints.append(constraint) }
                continue
            }
            if let installed = installedUserConstraints.removeValue(forKey: identifier) {
                if !removeSolverConstraints(installed.solverConstraints) { return false }
            }
            guard let compiled = compile(constraint) else { continue }
            if compiled.isRequired {
                required.append(compiled)
            } else {
                optional.append(compiled)
            }
        }

        if !installedUserConstraints.isEmpty {
            var removed: [ObjectIdentifier] = []
            for (identifier, installed) in installedUserConstraints where !currentIdentifiers.contains(identifier) {
                removed.append(identifier)
                if !removeSolverConstraints(installed.solverConstraints) { return false }
            }
            for identifier in removed { installedUserConstraints.removeValue(forKey: identifier) }
        }

        if LegacyLayoutSolver.reverseInstall { required.reverse(); optional.reverse() }
        else if LegacyLayoutSolver.depthOrderedInstall, required.count > 1 {
            // A constraint is installed after everything inside the views it connects: a new message's internal rows go
            // in before the rows tying it to the chain, so they never pivot through the chain's long columns.
            required = depthOrdered(required); optional = depthOrdered(optional)
        }
        for compiled in required { installUserConstraint(compiled) }
        pendingOptionalUserConstraints = optional
        return true
    }

    private func refreshIntrinsicAndOptionalConstraints() -> Bool {
        guard refreshIntrinsicConstraints() else { return false }
        let optional = pendingOptionalUserConstraints
        pendingOptionalUserConstraints.removeAll(keepingCapacity: true)
        for compiled in optional { installUserConstraint(compiled) }
        return true
    }

    /// The immutable configuration plus the mutable constant/priority of a user
    /// constraint. The constraint's other inputs cannot change after creation.
    private func constraintSignature(_ constraint: RRLayoutConstraint) -> ConstraintSignature {
        let key = ObjectIdentifier(constraint)
        if let cached = passSignatureCache[key] { return cached }
        let signature = computeConstraintSignature(constraint)
        passSignatureCache[key] = signature
        return signature
    }

    private func computeConstraintSignature(_ constraint: RRLayoutConstraint) -> ConstraintSignature {
        ConstraintSignature(
            firstItem: constraint.firstItem.map { ObjectIdentifier($0 as AnyObject) },
            secondItem: constraint.secondItem.map { ObjectIdentifier($0 as AnyObject) },
            firstAttribute: constraint.firstAttribute.rawValue,
            secondAttribute: constraint.secondAttribute.rawValue,
            relation: constraint.relation.rawValue,
            multiplier: Double(constraint.multiplier),
            constant: Double(constraint.constant),
            priority: constraint.priority)
    }

    /// Removes solver rows. Returns `false` if the solver rejects a removal.
    private func removeSolverConstraints(_ constraints: [Constraint]) -> Bool {
        for constraint in constraints {
            do {
                try solver.removeConstraint(constraint)
                removedConstraintCount += 1
                passRemovedConstraints += 1
                changeCount += 1
            } catch {
                return false
            }
        }
        return true
    }

    /// Constraints owned by any item of the subtree, plus activated constraints
    /// that reference a subtree item, de-duplicated by object identity.
    /// One pass collects the subtree's constraints once; refreshRequired/presolve-guard/signature-table all share it.
    /// Cleared with the rest of the pass state, so a new pass always re-collects.
    private var passConstraintCache: [RRLayoutConstraint]?
    private var passSignatureCache: [ObjectIdentifier: ConstraintSignature] = [:]

    private func collectConstraints() -> [RRLayoutConstraint] {
        if let cached = passConstraintCache { return cached }
        let collected = collectConstraintsUncached()
        passConstraintCache = collected
        return collected
    }

    private func collectConstraintsUncached() -> [RRLayoutConstraint] {
        let activated = LegacyActiveConstraintRegistry.shared.activeConstraints()
        var result: [RRLayoutConstraint] = []
        result.reserveCapacity(items.count * 4)
        if activated.isEmpty {
            // Common build path: constraints are owned by exactly one view, so no
            // de-duplication set is needed (it was an allocation + n hashes per
            // build).
            for item in items {
                result.append(contentsOf: item.layoutConstraints)
            }
            return result
        }
        var seen: Set<ObjectIdentifier> = []
        seen.reserveCapacity(result.capacity)
        for item in items {
            for constraint in item.layoutConstraints {
                if seen.insert(ObjectIdentifier(constraint)).inserted {
                    result.append(constraint)
                }
            }
        }
        for constraint in activated {
            if seen.contains(ObjectIdentifier(constraint)) { continue }
            if constraintReferencesSubtreeItem(constraint) {
                seen.insert(ObjectIdentifier(constraint))
                result.append(constraint)
            }
        }
        return result
    }

    private func constraintReferencesSubtreeItem(_ constraint: RRLayoutConstraint) -> Bool {
        if let firstObject = constraint.firstItem as AnyObject?,
           itemIdentifiers.contains(ObjectIdentifier(firstObject)) {
            return true
        }
        if let secondObject = constraint.secondItem as AnyObject?,
           itemIdentifiers.contains(ObjectIdentifier(secondObject)) {
            return true
        }
        return false
    }

    // MARK: Constraint translation

    /// Translates one `RRLayoutConstraint`. Returns `nil` when the constraint must
    /// be skipped (outside the subtree, deallocated item, unsupported attribute);
    /// unsupported/malformed constraints are additionally recorded as broken.
    private func compile(_ constraint: RRLayoutConstraint) -> CompiledConstraint? {
        guard constraint.firstAttribute != .notAnAttribute else {
            // Creation-time validation makes this unreachable for constraints made
            // through the public initializer; keep the guard for decoded/old data.
            brokenConstraints.append(constraint)
            return nil
        }
        guard constraint.multiplier.isFinite, constraint.constant.isFinite else {
            brokenConstraints.append(constraint)
            return nil
        }
        guard let firstObject = constraint.firstItem as AnyObject?,
              let firstVariables = variables[ObjectIdentifier(firstObject)] else {
            // nil / deallocated first item or item outside the solved subtree.
            return nil
        }
        guard let firstExpression = constraintExpression(for: firstVariables, attribute: constraint.firstAttribute,
                                                        otherItem: constraint.secondItem as AnyObject?) else {
            brokenConstraints.append(constraint)
            return nil
        }

        let multiplier = Double(constraint.multiplier)
        let constant = Double(constraint.constant)

        var rhs = Expression(constant: 0)

        if let secondObject = constraint.secondItem as AnyObject? {
            guard constraint.secondAttribute != .notAnAttribute else {
                // A second item with notAnAttribute is not a valid pair.
                brokenConstraints.append(constraint)
                return nil
            }
            guard let secondVariables = variables[ObjectIdentifier(secondObject)] else {
                // The constraint belongs to an ancestor's layout pass.
                return nil
            }
            guard let secondExpression = constraintExpression(for: secondVariables,
                                                    attribute: constraint.secondAttribute, otherItem: firstObject) else {
                brokenConstraints.append(constraint)
                return nil
            }
            // Algebra only: firstAttribute <rel> multiplier * secondAttribute + constant.
            rhs = secondExpression.times(multiplier)
        } else {
            // Constant constraint (`secondItem == nil`, secondAttribute must be
            // notAnAttribute). UIKit ignores the multiplier here (spec §2.2/§2.3),
            // so the RHS stays 0 and only the constant contributes.
            guard constraint.secondAttribute == .notAnAttribute else {
                brokenConstraints.append(constraint)
                return nil
            }
        }

        // RTL: the directional attributes increase towards the trailing (leftward)
        // edge, so the constant is mirrored whenever either side uses
        // leading/trailing. The edge mapping itself already swapped leading and
        // trailing; only the constant needs the sign flip. See the header for the
        // simulator-verified table. Relation and multiplier are unchanged.
        var signedConstant = constant
        var resolvedOperator = relationalOperator(for: constraint.relation)
        if direction == .rightToLeft,
           isDirectional(constraint.firstAttribute) || isDirectional(constraint.secondAttribute) {
            signedConstant = -constant
            // Mirroring a directional inequality reverses it:
            //   a.leading >= c.leading + 40  <=>  (M-a.maxX) >= (M-c.maxX)+40
            //                                <=>  a.maxX <= c.maxX - 40
            if constraint.relation != .equal {
                resolvedOperator = (resolvedOperator == .lessThanOrEqual)
                    ? .greaterThanOrEqual
                    : .lessThanOrEqual
            }
        }

        // firstExpr - multiplier * secondExpr - constant <op> 0
        let expression = firstExpression.minus(rhs)
        expression.constant -= signedConstant

        return CompiledConstraint(source: constraint,
                                  expression: expression,
                                  operator: resolvedOperator,
                                  strength: RRLayoutPriorityMapping.strength(for: constraint.priority),
                                  name: constraint.identifier)
    }

    /// Display scale of the view being laid out (window screen scale, else main screen).
    private func extractedDisplayScale() -> Double {
        if let view = root as? UIView, let scale = view.window?.screen.scale, scale > 0 {
            return Double(scale)
        }
        let scale = UIScreen.main.scale
        return Double(scale > 0 ? scale : 1)
    }

    /// The expression for an attribute on an item, or `nil` when the item cannot
    /// provide that attribute (unsupported baseline).
    private func constraintExpression(for vars: ItemVariables, attribute: RRLayoutAttribute,
                                      otherItem: AnyObject?) -> Expression? {
        guard let size = scrollContentSizes[vars.identifier], let other = otherItem as? LegacyLayoutItem else {
            return expression(for: vars, attribute: attribute)
        }
        var ancestor = other.layoutSuperitem
        var descendant = false
        while let item = ancestor {
            if ObjectIdentifier(item as AnyObject) == vars.identifier { descendant = true; break }
            ancestor = item.layoutSuperitem
        }
        guard descendant else { return expression(for: vars, attribute: attribute) }
        switch attribute {
        case .right: return Expression(vars.minX).plus(Expression(size.width))
        case .bottom: return Expression(vars.minY).plus(Expression(size.height))
        case .trailing:
            return direction == .leftToRight ? Expression(vars.minX).plus(Expression(size.width)) : Expression(vars.minX)
        case .leading:
            return direction == .leftToRight ? Expression(vars.minX) : Expression(vars.minX).plus(Expression(size.width))
        default: return expression(for: vars, attribute: attribute)
        }
    }

    private func expression(for variables: ItemVariables, attribute: RRLayoutAttribute) -> Expression? {
        switch attribute {
        case .notAnAttribute:
            return nil
        case .left:
            return Expression(variables.minX)
        case .right:
            return maxXExpression(variables)
        case .leading:
            return direction == .leftToRight ? Expression(variables.minX) : maxXExpression(variables)
        case .trailing:
            return direction == .leftToRight ? maxXExpression(variables) : Expression(variables.minX)
        case .top:
            return Expression(variables.minY)
        case .bottom:
            return maxYExpression(variables)
        case .width:
            return Expression(variables.width)
        case .height:
            return Expression(variables.height)
        case .centerX:
            return Expression(variables.minX).plus(Expression(variables.width).times(0.5))
        case .centerY:
            return Expression(variables.minY).plus(Expression(variables.height).times(0.5))
        case .firstBaseline:
            // Only supported when the item exposes baseline metrics; a plain view
            // has no baseline (spec §2.5).
            guard let offset = firstBaselineOffsets[variables.identifier] else {
                return nil
            }
            return Expression(variables.minY).plus(Expression(constant: Double(offset)))
        case .lastBaseline:
            guard let offset = lastBaselineOffsets[variables.identifier] else {
                return nil
            }
            return maxYExpression(variables).minus(Expression(constant: Double(offset)))
        }
    }

    /// `maxX` as an expression: `minX + width`.
    private func maxXExpression(_ variables: ItemVariables) -> Expression {
        Expression(variables.minX).plus(Expression(variables.width))
    }

    /// `maxY` as an expression: `minY + height`.
    private func maxYExpression(_ variables: ItemVariables) -> Expression {
        Expression(variables.minY).plus(Expression(variables.height))
    }

    private func isDirectional(_ attribute: RRLayoutAttribute) -> Bool {
        return attribute == .leading || attribute == .trailing
    }

    private func relationalOperator(for relation: RRLayoutRelation) -> RelationalOperator {
        switch relation {
        case .lessThanOrEqual:
            return .lessThanOrEqual
        case .equal:
            return .equal
        case .greaterThanOrEqual:
            return .greaterThanOrEqual
        }
    }

    // MARK: Intrinsic content size

    /// One item's intrinsic-size constraints, plus the input signature used for
    /// diffing.
    private struct IntrinsicPlan {
        var signature: IntrinsicSignature
        var expressions: [(expression: Expression, op: RelationalOperator, strength: Strength, name: String)]
    }

    /// Builds the implicit intrinsic-size constraints at the item's content hugging
    /// and compression-resistance priorities:
    ///
    ///     width  >= intrinsicWidth  @ compression resistance (horizontal)
    ///     width  <= intrinsicWidth  @ hugging (horizontal)
    ///     height >= intrinsicHeight @ compression resistance (vertical)
    ///     height <= intrinsicHeight @ hugging (vertical)
    ///
    /// `UIViewNoIntrinsicMetric` (`-1`) means "no intrinsic size on this axis".
    private func intrinsicPlan(for item: LegacyLayoutItem, vars: ItemVariables) -> IntrinsicPlan {
        let inputs = intrinsicInputs(for: item)
        return intrinsicPlan(inputs: inputs, vars: vars)
    }

    /// Everything the plan depends on, gathered without allocating any solver expression. An unchanged view (the common
    /// case on an incremental pass) only needs this to prove its installed rows are still right.
    private struct IntrinsicInputs {
        var size: CGSize
        var huggingX: RRLayoutPriority, huggingY: RRLayoutPriority
        var compressionX: RRLayoutPriority, compressionY: RRLayoutPriority
        var signature: IntrinsicSignature {
            IntrinsicSignature(width: Double(size.width), height: Double(size.height),
                               huggingX: huggingX, huggingY: huggingY,
                               compressionX: compressionX, compressionY: compressionY)
        }
    }

    private func intrinsicInputs(for item: LegacyLayoutItem) -> IntrinsicInputs {
        return IntrinsicInputs(size: item.layoutIntrinsicContentSize,
                        huggingX: item.layoutContentHuggingPriority(for: .horizontal),
                        huggingY: item.layoutContentHuggingPriority(for: .vertical),
                        compressionX: item.layoutContentCompressionResistancePriority(for: .horizontal),
                        compressionY: item.layoutContentCompressionResistancePriority(for: .vertical))
    }

    private func intrinsicPlan(inputs: IntrinsicInputs, vars: ItemVariables) -> IntrinsicPlan {
        let intrinsicSize = inputs.size
        let huggingX = inputs.huggingX, huggingY = inputs.huggingY
        let compressionX = inputs.compressionX, compressionY = inputs.compressionY
        let signature = inputs.signature
        var expressions: [(expression: Expression, op: RelationalOperator, strength: Strength, name: String)] = []
        expressions.reserveCapacity(4)
        if intrinsicSize.width >= 0 && intrinsicSize.width.isFinite {
            let value = Double(intrinsicSize.width)
            expressions.append((Expression(vars.width).minus(Expression(constant: value)),
                                .greaterThanOrEqual,
                                RRLayoutPriorityMapping.strength(for: compressionX),
                                "intrinsic width >= \(value)"))
            expressions.append((Expression(vars.width).minus(Expression(constant: value)),
                                .lessThanOrEqual,
                                RRLayoutPriorityMapping.strength(for: huggingX),
                                "intrinsic width <= \(value)"))
        }
        if intrinsicSize.height >= 0 && intrinsicSize.height.isFinite {
            let value = Double(intrinsicSize.height)
            expressions.append((Expression(vars.height).minus(Expression(constant: value)),
                                .greaterThanOrEqual,
                                RRLayoutPriorityMapping.strength(for: compressionY),
                                "intrinsic height >= \(value)"))
            expressions.append((Expression(vars.height).minus(Expression(constant: value)),
                                .lessThanOrEqual,
                                RRLayoutPriorityMapping.strength(for: huggingY),
                                "intrinsic height <= \(value)"))
        }
        return IntrinsicPlan(signature: signature, expressions: expressions)
    }

    /// Installs one intrinsic-size row. Like a user constraint, a required row the solver rejects (a view whose
    /// required hugging/compression pins it to a size the required constraints cannot give it) is not dropped:
    /// it is kept at the "broken" strength, so the required constraints win and the intrinsic size still pulls
    /// as hard as it can (UIKit breaks the unsatisfiable required set instead of ignoring the intrinsic size).
    private func installIntrinsicRow(_ expression: Expression, _ op: RelationalOperator,
                                     strength: Strength, name: String) -> Constraint? {
        if let constraint = install(expression, op, strength: strength, name: name) { return constraint }
        guard strength == Strength.required, !lastInstallWasDropped else { return nil }
        return install(expression.plus(Expression(constant: 0)), op,
                       strength: LegacyLayoutSolver.brokenStrength, name: name)
    }

    private func installIntrinsicContentConstraints() {
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            guard let vars = variables[identifier], !vars.isRoot else {
                continue
            }
            let plan = intrinsicPlan(for: item, vars: vars)
            var installed: [Constraint] = []
            installed.reserveCapacity(plan.expressions.count)
            for entry in plan.expressions {
                if let constraint = installIntrinsicRow(entry.expression, entry.op,
                                                        strength: entry.strength, name: entry.name) {
                    installed.append(constraint)
                }
            }
            installedIntrinsicConstraints[identifier] = InstalledIntrinsicConstraints(
                signature: plan.signature, solverConstraints: installed)
        }
    }

    /// Incremental intrinsic-constraint diff. Returns `false` on a solver error.
    private func refreshIntrinsicConstraints() -> Bool {
        var seen: Set<ObjectIdentifier> = []
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            guard let vars = variables[identifier], !vars.isRoot else { continue }
            seen.insert(identifier)
            let inputs = intrinsicInputs(for: item)
            if let installed = installedIntrinsicConstraints[identifier] {
                if installed.signature == inputs.signature { continue }      // unchanged: no expressions built at all
                if !removeSolverConstraints(installed.solverConstraints) { return false }
                installedIntrinsicConstraints.removeValue(forKey: identifier)
            }
            let plan = intrinsicPlan(inputs: inputs, vars: vars)
            var installed: [Constraint] = []
            installed.reserveCapacity(plan.expressions.count)
            for entry in plan.expressions {
                if let constraint = installIntrinsicRow(entry.expression, entry.op,
                                                        strength: entry.strength, name: entry.name) {
                    installed.append(constraint)
                }
            }
            installedIntrinsicConstraints[identifier] = InstalledIntrinsicConstraints(
                signature: plan.signature, solverConstraints: installed)
        }
        if !installedIntrinsicConstraints.isEmpty {
            var removed: [ObjectIdentifier] = []
            for (identifier, installed) in installedIntrinsicConstraints where !seen.contains(identifier) {
                removed.append(identifier)
                if !removeSolverConstraints(installed.solverConstraints) { return false }
            }
            for identifier in removed { installedIntrinsicConstraints.removeValue(forKey: identifier) }
        }
        return true
    }

    // MARK: Autoresizing incremental diff

    /// Incremental autoresizing diff for the translating items. Returns `false`
    /// on a solver error.
    private func refreshAutoresizingConstraints() -> Bool {
        let fallbackSuperviewSize = root.layoutFrame.size
        var seen: Set<ObjectIdentifier> = []
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            guard let vars = variables[identifier], !vars.isRoot else { continue }
            if !item.layoutTranslatesAutoresizingMaskIntoConstraints {
                if let old = installedAutoresizingConstraints.removeValue(forKey: identifier) {
                    if !removeSolverConstraints(old.solverConstraints) { return false }
                }
                continue
            }
            seen.insert(identifier)
            let plan = autoresizingPlan(vars: vars, item: item, fallbackSuperviewSize: fallbackSuperviewSize)
            if let installed = installedAutoresizingConstraints[identifier],
               installed.signature == plan.signature {
                continue
            }
            if let old = installedAutoresizingConstraints.removeValue(forKey: identifier) {
                if !removeSolverConstraints(old.solverConstraints) { return false }
            }
            var installed: [Constraint] = []
            installed.reserveCapacity(plan.expressions.count)
            for entry in plan.expressions {
                if let constraint = install(entry.expression, entry.op,
                                            strength: .required, name: entry.name) {
                    installed.append(constraint)
                }
            }
            installedAutoresizingConstraints[identifier] = InstalledAutoresizingConstraints(
                signature: plan.signature, solverConstraints: installed)
        }
        if !installedAutoresizingConstraints.isEmpty {
            var removed: [ObjectIdentifier] = []
            for (identifier, installed) in installedAutoresizingConstraints where !seen.contains(identifier) {
                removed.append(identifier)
                if !removeSolverConstraints(installed.solverConstraints) { return false }
            }
            for identifier in removed { installedAutoresizingConstraints.removeValue(forKey: identifier) }
        }
        return true
    }

    // MARK: Solver helpers

    /// Installs a constraint that the solver must not sacrifice (implicit /
    /// system-generated). Failures are ignored: they can only happen when the
    /// system equations are violated, which the engine handles by continuing.
    @discardableResult
    private func installRequired(_ expression: Expression,
                                 _ op: RelationalOperator,
                                 name: String?) -> Bool {
        return install(expression, op, strength: .required, name: name) != nil
    }

    /// Discards the presolve attempt and every piece of build bookkeeping it
    /// produced. Called when the batch had to relax a required row: the whole
    /// system is then rebuilt through the ordinary per-constraint path so
    /// `brokenConstraints` reporting and incremental state are identical to the
    /// non-presolve engine (never a mixed state).
    private func resetBuildState() {
        solver.reset()
        brokenConstraints.removeAll(keepingCapacity: true)
        installedUserConstraints.removeAll(keepingCapacity: true)
        installedIntrinsicConstraints.removeAll(keepingCapacity: true)
        installedAutoresizingConstraints.removeAll(keepingCapacity: true)
        installedStays.removeAll(keepingCapacity: true)
        unstayedItems.removeAll(keepingCapacity: true)
        presolveBatchSourceByIndex.removeAll(keepingCapacity: true)
        installedConstraintCount = 0
        removedConstraintCount = 0
        passInstalledConstraints = 0
        passRemovedConstraints = 0
        changeCount = 0
        isInitialized = false
        installedItemOrder.removeAll(keepingCapacity: true)
        installedSuperitems.removeAll(keepingCapacity: true)
        installedRootSize = .zero
        lastResult = nil
        lastInstallWasDropped = false
        rebuildOnly = true
    }

    /// Whether every variable in the expression was eliminated by presolve, so
    /// the solver will fold the row into a constant and drop it.
    private func isFullyPresolved(_ expression: Expression) -> Bool {
        guard solver.hasPresolvedVariables else { return false }
        for term in expression.terms where !solver.isPresolved(term.variable) {
            return false
        }
        return true
    }

    /// Installs one constraint. Returns the solver constraint, or `nil` if the
    /// solver rejected it (unsatisfiable required constraint or solver error);
    /// the engine then skips it and keeps going.
    @discardableResult
    private func install(_ expression: Expression,
                         _ op: RelationalOperator,
                         strength: Strength,
                         name: String?,
                         source: RRLayoutConstraint? = nil) -> Constraint? {
        lastInstallWasDropped = false
        if isFullyPresolved(expression) {
            lastInstallWasDropped = true
            return nil
        }
        if let source = source, solver.isCollectingPresolveBatch {
            presolveBatchSourceByIndex[solver.presolveBatchCount] = source
        }
        let constraint = Constraint(expression, op, strength: strength, name: name)
        do {
            try solver.addConstraint(constraint)
            installedConstraintCount += 1
            passInstalledConstraints += 1
            changeCount += 1
            return constraint
        } catch {
            LegacyLayoutDebug.noteRejected(name: name, op: "\(op)", strengthIsRequired: strength == .required,
                                           terms: expression.terms.count, constant: expression.constant, error: "\(error)")
            return nil
        }
    }

    // MARK: Result extraction

    private func extractResult(writingFrames: Bool) -> LegacyLayoutResult {
        let rootIdentifier = ObjectIdentifier(root as AnyObject)

        // Absolute (solver / root-local) origins and solved sizes per item.
        var absoluteOrigins: [ObjectIdentifier: CGPoint] = [:]
        var solvedSizes: [ObjectIdentifier: CGSize] = [:]
        var currentFrames: [ObjectIdentifier: CGRect] = [:]

        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            if identifier == rootIdentifier {
                var rootFrame = item.layoutFrame
                if fittingProposal != nil, let vars = variables[identifier] {
                    rootFrame.size = CGSize(width: max(0, solver.value(of: vars.width)),
                                            height: max(0, solver.value(of: vars.height)))
                    fittedRootSize = rootFrame.size
                }
                absoluteOrigins[identifier] = CGPoint(x: 0, y: 0)
                solvedSizes[identifier] = CGSize(width: rootFrame.width.isFinite ? rootFrame.width : 0,
                                                 height: rootFrame.height.isFinite ? rootFrame.height : 0)
                // The root's frame is returned (and kept) unchanged: it is the
                // container and Auto Layout does not resize it in this pass.
                currentFrames[identifier] = rootFrame
                continue
            }
            guard let vars = variables[identifier] else {
                currentFrames[identifier] = item.layoutFrame
                continue
            }
            let minX = solver.value(of: vars.minX)
            let minY = solver.value(of: vars.minY)
            let width = solver.value(of: vars.width)
            let height = solver.value(of: vars.height)
            let parentAbsolute = parentAbsoluteOrigin(of: item, absoluteOrigins: absoluteOrigins)
            if minX.isFinite && minY.isFinite && width.isFinite && height.isFinite {
                // Clamp tiny negative sizes produced by floating-point error;
                // widths/heights are also required >= 0 in the system.
                let clampedWidth = max(0, width)
                let clampedHeight = max(0, height)
                absoluteOrigins[identifier] = CGPoint(x: minX, y: minY)
                solvedSizes[identifier] = CGSize(width: clampedWidth, height: clampedHeight)
                // layoutFrame is in superitem coordinates: subtract the parent's
                // solved absolute origin.
                currentFrames[identifier] = CGRect(x: minX - parentAbsolute.x,
                                                   y: minY - parentAbsolute.y,
                                                   width: clampedWidth,
                                                   height: clampedHeight)
            } else {
                // Non-finite solution: keep the current frame for this item.
                let fallback = item.layoutFrame
                absoluteOrigins[identifier] = CGPoint(x: parentAbsolute.x + fallback.minX,
                                                      y: parentAbsolute.y + fallback.minY)
                solvedSizes[identifier] = fallback.size
                currentFrames[identifier] = fallback
            }
        }

        // UIKit writes Auto Layout results on the display pixel grid: a 2x screen snaps frames to
        // 0.5pt (differential: 69.75 -> 70, 81.75 -> 82, 38.25 -> 38.5). Ties round half-up.
        let pixelScale = extractedDisplayScale()
        func snap(_ value: Double) -> Double {
            guard pixelScale > 0 else { return value }
            let scaled = value * pixelScale
            let floorValue = floor(scaled)
            if abs((scaled - floorValue) - 0.5) < 1e-9 { return (floorValue + 1) / pixelScale }
            return scaled.rounded() / pixelScale
        }

        // Write frames back (root untouched) and advance autoresizing references.
        // Both only happen for a real layout pass, not for `solve`.
        if writingFrames {
            // Final (written) absolute origins, accumulated per item: a child's snapped local
            // origin subtracts the parent's WRITTEN origin (the parent's own snap already
            // applied) rather than the parent's unsolved one. Native writes child =
            // snap(childAbs) - snapped(parentAbs), which keeps every local coordinate on the
            // pixel grid; subtracting the unsolved parent leaves 0.125–0.25pt local drift on
            // 2x displays (differential round 117: children of aspect-sized containers).
            var finalAbsolute: [ObjectIdentifier: CGPoint] = [:]
            finalAbsolute[rootIdentifier] = absoluteOrigins[rootIdentifier] ?? root.layoutFrame.origin
            for item in items {
                let identifier = ObjectIdentifier(item as AnyObject)
                if let size = scrollContentSizes[identifier] {
                    item.layoutSetScrollContentSize(CGSize(width: max(0, solver.value(of: size.width)),
                                                          height: max(0, solver.value(of: size.height))))
                }
                if identifier == rootIdentifier {
                    continue
                }
                guard let candidate = currentFrames[identifier], candidate.minX.isFinite,
                      candidate.minY.isFinite, candidate.width.isFinite, candidate.height.isFinite else {
                    continue
                }
                let parentAbsolute = parentAbsoluteOrigin(of: item, absoluteOrigins: absoluteOrigins)
                let parentFinal: CGPoint
                if let superitem = item.layoutSuperitem {
                    parentFinal = finalAbsolute[ObjectIdentifier(superitem as AnyObject)] ?? finalAbsolute[rootIdentifier] ?? parentAbsolute
                } else {
                    parentFinal = finalAbsolute[rootIdentifier] ?? parentAbsolute
                }
                let frame = CGRect(x: snap(parentAbsolute.x + Double(candidate.minX)) - parentFinal.x,
                                   y: snap(parentAbsolute.y + Double(candidate.minY)) - parentFinal.y,
                                   width: max(0, snap(Double(candidate.width))),
                                   height: max(0, snap(Double(candidate.height))))
                if ProcessInfo.processInfo.environment["LEGACY_LAYOUT_FRAME_DEBUG"] != nil, let v = item as? UIView {
                    FileHandle.standardError.write(Data(String(
                        format: "FRAMEDEBUG %d %s pre=%.4f %.4f %.4f %.4f post=%.4f %.4f %.4f %.4f\n",
                        ObjectIdentifier(v).hashValue,
                        (ObjectIdentifier(v).debugDescription as NSString).utf8String!,
                        candidate.minX, candidate.minY, candidate.width, candidate.height,
                        frame.minX, frame.minY, frame.width, frame.height).utf8))
                }
                item.layoutSetFrame(frame)
                finalAbsolute[identifier] = CGPoint(x: parentFinal.x + frame.minX,
                                                    y: parentFinal.y + frame.minY)
            }
            for item in items {
                let identifier = ObjectIdentifier(item as AnyObject)
                if identifier == rootIdentifier {
                    continue
                }
                guard item.layoutTranslatesAutoresizingMaskIntoConstraints,
                      let frame = currentFrames[identifier] else {
                    continue
                }
                let superviewSize = solvedSuperviewSize(of: item,
                                                        frames: currentFrames,
                                                        sizes: solvedSizes)
                item.layoutUpdateAutoresizingReference(LegacyAutoresizingReference(frame: frame,
                                                                                   superviewSize: superviewSize))
            }
        }

        var frames: [ObjectIdentifier: CGRect] = [:]
        var resolved: [ObjectIdentifier: LegacyResolvedFrame] = [:]
        for item in items {
            let identifier = ObjectIdentifier(item as AnyObject)
            guard let frame = currentFrames[identifier] else {
                continue
            }
            frames[identifier] = frame
            resolved[identifier] = resolvedFrame(from: frame, item: item)
        }

        return LegacyLayoutResult(frames: frames,
                                  brokenConstraints: brokenConstraints,
                                  resolvedAttributes: resolved)
    }

    /// The item's superitem origin in root-local coordinates.
    private func parentAbsoluteOrigin(of item: LegacyLayoutItem,
                                      absoluteOrigins: [ObjectIdentifier: CGPoint]) -> CGPoint {
        guard let superitem = item.layoutSuperitem else {
            return CGPoint(x: 0, y: 0)
        }
        let identifier = ObjectIdentifier(superitem as AnyObject)
        return absoluteOrigins[identifier] ?? CGPoint(x: 0, y: 0)
    }

    /// The superview size after the pass: the solved superview size when the
    /// superview was part of the subtree, else the current frame size.
    private func solvedSuperviewSize(of item: LegacyLayoutItem,
                                     frames: [ObjectIdentifier: CGRect],
                                     sizes: [ObjectIdentifier: CGSize]) -> CGSize {
        guard let superitem = item.layoutSuperitem else {
            return root.layoutFrame.size
        }
        let identifier = ObjectIdentifier(superitem as AnyObject)
        if let size = sizes[identifier], size.width.isFinite, size.height.isFinite {
            return size
        }
        let current = superitem.layoutFrame.size
        if current.width.isFinite, current.height.isFinite {
            return current
        }
        return root.layoutFrame.size
    }

    private func resolvedFrame(from frame: CGRect, item: LegacyLayoutItem) -> LegacyResolvedFrame {
        // Baselines are positions, not stored geometry; derive them from the
        // written frame and the item's content metrics (a missing provider falls
        // back to the top/bottom edge for this debug struct only -- baseline
        // CONSTRAINTS on such an item are recorded as broken and never solved).
        let firstBaseline = frame.minY + (finite(item.layoutFirstBaselineOffsetFromTop) ?? 0)
        let lastBaseline = frame.maxY - (finite(item.layoutLastBaselineOffsetFromBottom) ?? 0)
        return LegacyResolvedFrame(
            leading: frame.minX,
            trailing: frame.maxX,
            top: frame.minY,
            bottom: frame.maxY,
            width: frame.width,
            height: frame.height,
            centerX: frame.midX,
            centerY: frame.midY,
            firstBaseline: firstBaseline,
            lastBaseline: lastBaseline
        )
    }

    // MARK: Numeric helpers

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value = value, value.isFinite else {
            return nil
        }
        return value
    }

    private func isFinite(_ frame: CGRect) -> Bool {
        return frame.minX.isFinite && frame.minY.isFinite
            && frame.width.isFinite && frame.height.isFinite
    }

    private func isFinite(_ size: CGSize) -> Bool {
        return size.width.isFinite && size.height.isFinite
    }
}
