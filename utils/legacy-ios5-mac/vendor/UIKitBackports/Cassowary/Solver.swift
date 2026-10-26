//
//  Solver.swift
//  Cassowary
//
//  An incremental Cassowary constraint solver (sparse simplex tableau with
//  primal and dual optimization).
//
//  Ported from the reference `kiwi` implementation:
//    Copyright (c) 2013-2026, Nucleic Development Team.
//    Distributed under the terms of the Modified BSD License.
//    https://github.com/nucleic/kiwi (kiwi/solverimpl.h, kiwi/solver.h)
//
//  The Cassowary algorithm was created by Greg Badros and Alan Borning at the
//  University of Washington (https://constraints.cs.washington.edu/cassowary/).
//
//  Determinism: the reference implementation walks hash maps in unspecified
//  order. This port orders every traversal that can influence pivot selection by
//  numeric symbol id, so an identical sequence of calls always produces an
//  identical solution, independent of the process hash seed.
//

import Foundation

/// How a constraint is tracked in the tableau.
///
/// `marker` is the slack, error or dummy symbol that must be kept at zero for a
/// required constraint, or is penalized in the objective for an optional one.
/// `other` is the second error symbol of an equality, or the error symbol of an
/// inequality; it is `.invalid` when unused.
internal struct ConstraintTag {
    internal var marker: Symbol = .invalid
    internal var other: Symbol = .invalid
}

/// The internal state of an edit variable.
internal struct EditInfo {
    /// The symbols of the edit constraint `variable == constant`.
    internal var tag: ConstraintTag
    /// The constraint that holds the variable at `constant`.
    internal var constraint: Constraint
    /// The most recently suggested value.
    internal var constant: Double
}

/// An incremental Cassowary constraint solver.
///
/// The solver maintains a tableau of basic/non-basic variables and supports
/// adding and removing constraints, as well as edit variables for cheap
/// re-solving (used by the layout pass when a container resizes).
///
/// The solver is a reference type; all mutating methods update it in place.
/// Methods that can fail throw a `SolverError` and leave the solver in a
/// consistent state: a failed `addConstraint` restores the previous solution
/// exactly.
public final class Solver {

    /// Constraints currently held by the solver, in insertion order.
    public private(set) var constraints: [Constraint] = []

    /// The tag of every constraint in the tableau, including the internal
    /// constraints that implement edit variables. Keyed by object identity.
    private var constraintTags: [ObjectIdentifier: ConstraintTag] = [:]

    /// The basic rows of the tableau, indexed by the basic symbol's id.
    ///
    /// Symbol ids are dense per solver (allocated monotonically), so an array is
    /// a cheaper lookup than hashing on every pivot. Holes are nil; ids that are
    /// never basic stay nil.
    private var basicRows: [Row?] = []

    /// Pre-sizes the build-path containers for a system with `constraintCount`
    /// constraints and `variableCount` variables. Purely an allocation hint.
    public func reserveCapacity(constraintCount: Int, variableCount: Int) {
        constraints.reserveCapacity(constraintCount)
        constraintTags.reserveCapacity(constraintCount)
        basicRows.reserveCapacity(constraintCount * 3)
        basicSymbols.reserveCapacity(constraintCount * 3)
        variableSymbols.reserveCapacity(variableCount)
        orderedVariables.reserveCapacity(variableCount)
        externalValues.reserveCapacity(variableCount)
    }

    /// The basic symbols sorted by symbol id. Maintained on every basis change so
    /// tableau traversals never re-sort the whole basis (the dominant cost in
    /// the previous implementation).
    private var basicSymbols: [Symbol] = []

    /// Column index: for each symbol id, the basic symbols whose rows contain it,
    /// sorted by basic symbol id. Substitution and the ratio test then visit only
    /// the rows that can contain the pivot symbol instead of scanning the whole
    /// basis. Lists stay sorted so per-row processing order (and therefore every
    /// pivot tie-break) is the same as the previous full-basis scan.
    private var rowsBySymbol: [Int: [Symbol]] = [:]

    /// External variables in the order their tableau symbols were allocated.
    /// This matches the previous `variableSymbols.sorted(by: symbol id)` order,
    /// without the per-update sort.
    private var orderedVariables: [Variable] = []

    /// Maps caller-created variables to their tableau symbols. Symbols are
    /// allocated lazily, the first time a variable appears in a constraint.
    private var variableSymbols: [Int: Symbol] = [:]

    /// The objective function: the weighted sum of the error symbols of all
    /// non-required constraints.
    private var objective = Row()

    /// The artificial objective used by phase one of the two-phase method,
    /// non-nil only while `addWithArtificialVariable` is running.
    private var artificialRow: Row?

    /// Basic rows whose constant is negative; they need a dual pivot.
    private var infeasibleRows: [Symbol] = []

    /// The registered edit variables.
    private var edits: [Variable: EditInfo] = [:]

    /// The last values written back by `updateVariables()`.
    private var externalValues: [Int: Double] = [:]

    // MARK: Presolve (required-equality elimination)

    /// Switches the guarded presolve pass (required equalities with one free
    /// variable are substituted directly instead of becoming tableau rows).
    /// Tests use it to compare with and without the pass.
    public static var presolvesEnabled = true

    /// Values of variables eliminated by the presolve pass.
    public private(set) var presolvedValues: [Int: Double] = [:]

    /// Whether `variable` was eliminated by the presolve pass.
    public func isPresolved(_ variable: Variable) -> Bool {
        presolvedValues[variable.id] != nil
    }

    /// Whether a presolve pass has eliminated at least one variable.
    public var hasPresolvedVariables: Bool {
        !presolvedValues.isEmpty
    }

    /// Whether the last build used presolve (an incremental update must then
    /// rebuild, because eliminated variables are not in the tableau).
    public private(set) var presolveActive = false

    /// When non-nil, constraints are buffered for a presolve batch.
    private var presolveBatch: [Constraint]?

    /// Presolve statistics: applied builds, fallbacks, eliminated variables.
    public private(set) var presolveAppliedCount = 0
    public private(set) var presolveFallbackCount = 0
    public private(set) var presolvedVariableCount = 0

    /// Batch indices of required rows the solver could not satisfy and relaxed at
    /// the "broken" strength; the engine maps them back to the caller's
    /// constraints for `brokenConstraints` reporting.
    public private(set) var batchRejectedIndices: [Int] = []

    /// Number of constraints buffered so far in the current presolve batch.
    public var presolveBatchCount: Int { presolveBatch?.count ?? 0 }

    /// Whether a presolve batch is currently being collected.
    public var isCollectingPresolveBatch: Bool { presolveBatch != nil }

    /// Process-wide presolve counters for the differential tests.
    public private(set) static var totalPresolveApplied = 0
    public private(set) static var totalPresolveFallback = 0
    public static func resetPresolveStatistics() {
        totalPresolveApplied = 0
        totalPresolveFallback = 0
    }

    /// Variables whose external value changed since the last `fetchChanges()`.
    private var changedVariables: Set<Variable> = []

    /// The next symbol id. Ids are unique per solver and never reused except by
    /// `reset()`, which returns the solver to its initial state.
    private var idTick = 1

    public init() {}

    /// The number of symbols known to the solver, including the internal slack,
    /// error and dummy symbols.
    public var variableCount: Int {
        idTick - 1
    }

    /// The number of constraints held by the solver (edit-variable constraints
    /// are internal and not counted).
    public var constraintCount: Int {
        constraints.count
    }

    // MARK: - Constraints

    /// Adds a single constraint.
    ///
    /// - Throws: `SolverError.duplicateConstraint` if the exact constraint
    ///   object was already added.
    /// - Throws: `SolverError.unsatisfiableConstraint` if the constraint is
    ///   required and cannot be satisfied together with the constraints already
    ///   in the solver. The solver state is unchanged in that case.
    public func addConstraint(_ constraint: Constraint) throws {
        if presolveBatch != nil {
            presolveBatch?.append(constraint)
            return
        }
        var constraint = constraint
        if !presolvedValues.isEmpty {
            // A variable eliminated by presolve is a known constant: rewrite the
            // row (or drop it when it becomes constant).
            let simplifiedExpression = simplified(constraint.expression, cancelling: presolvedValues)
            if simplifiedExpression.terms.isEmpty {
                if constraint.strength == .required && !holds(simplifiedExpression.constant, constraint.op) {
                    throw SolverError.internalInconsistency("presolved constraints conflict")
                }
                return
            }
            constraint = Constraint(simplifiedExpression, constraint.op,
                                    strength: constraint.strength, name: constraint.name)
        }
        // Hot path: when no edit variables are registered, a failure can be
        // rolled back by rebuilding the tableau from the (small) constraint
        // list instead of snapshotting the whole tableau. Copying every row and
        // basis array on each add was the dominant cost of a full layout build.
        if edits.isEmpty {
            if constraint.strength == .required && presolvedValues.isEmpty {
                // Exact rollback (as in the rebuild-per-pass reference) for
                // required rows: the state after a failed required add decides
                // which later constraints the engine reports as broken.
                try addConstraintInternal(constraint)
                constraints.append(constraint)
            } else {
                do {
                    try addConstraintInternalNoSnapshot(constraint)
                    constraints.append(constraint)
                } catch {
                    rebuildFromConstraintList()
                    throw error
                }
            }
        } else {
            try addConstraintInternal(constraint)
            constraints.append(constraint)
        }
    }

    /// Adds a batch of constraints, in order.
    ///
    /// If one of the constraints fails, the ones added before it remain in the
    /// solver; the failing constraint itself leaves the solver unchanged.
    public func addConstraints(_ constraints: [Constraint]) throws {
        for constraint in constraints {
            try addConstraint(constraint)
        }
    }

    /// Removes a previously added constraint.
    ///
    /// - Throws: `SolverError.unknownConstraint` if the constraint object was
    ///   not added to this solver.
    public func removeConstraint(_ constraint: Constraint) throws {
        let identifier = ObjectIdentifier(constraint)
        guard let tag = constraintTags[identifier] else {
            throw SolverError.unknownConstraint
        }
        if edits.isEmpty {
            // No edit variables: a failure can be rolled back by replaying the
            // committed constraint list, which is far cheaper than copying the
            // whole tableau (rows are reference types).
            do {
                try removeConstraintInternal(constraint, tag: tag)
                if let index = constraints.firstIndex(where: { $0 === constraint }) {
                    constraints.remove(at: index)
                }
            } catch {
                rebuildFromConstraintList()
                throw error
            }
        } else {
            let snapshot = makeSnapshot()
            do {
                try removeConstraintInternal(constraint, tag: tag)
                if let index = constraints.firstIndex(where: { $0 === constraint }) {
                    constraints.remove(at: index)
                }
            } catch {
                restore(snapshot)
                throw error
            }
        }
    }

    /// Whether `constraint` is held by the solver.
    public func hasConstraint(_ constraint: Constraint) -> Bool {
        constraints.contains { $0 === constraint }
    }

    // MARK: - Edit variables

    /// Registers `variable` as an edit variable, i.e. a variable whose value is
    /// driven externally through `suggestValue(_:_:)` and that is continuously
    /// resolved.
    ///
    /// The variable is held at its current external value until a value is
    /// suggested, as in Cassowary.
    ///
    /// - Throws: `SolverError.duplicateEditVariable` if the variable is already
    ///   an edit variable.
    /// - Throws: `SolverError.internalInconsistency` if `strength` is required:
    ///   requiring an edit variable would make the system unsatisfiable as soon
    ///   as a different value is suggested.
    public func addEditVariable(_ variable: Variable, strength: Strength = .strong) throws {
        if edits[variable] != nil {
            throw SolverError.duplicateEditVariable
        }
        let clipped = Strength.clip(strength.value)
        guard clipped < Strength.required else {
            throw SolverError.internalInconsistency("an edit variable cannot have required strength")
        }
        let constant = externalValues[variable.id] ?? 0.0
        // The edit constraint is `variable - constant == 0`; note that
        // `Expression(variable, coefficient)` takes a coefficient, so the
        // constant has to be built explicitly.
        let editExpression = Expression(variable, 1.0).minus(Expression(constant: constant))
        let constraint = Constraint(editExpression, .equal, strength: clipped)
        try addConstraintInternal(constraint)
        guard let tag = constraintTags[ObjectIdentifier(constraint)] else {
            throw SolverError.internalInconsistency("the edit constraint was not registered")
        }
        edits[variable] = EditInfo(tag: tag, constraint: constraint, constant: constant)
    }

    /// Removes a previously registered edit variable.
    ///
    /// - Throws: `SolverError.unknownEditVariable` if the variable is not an
    ///   edit variable.
    public func removeEditVariable(_ variable: Variable) throws {
        guard let info = edits[variable] else {
            throw SolverError.unknownEditVariable
        }
        let snapshot = makeSnapshot()
        do {
            try removeConstraintInternal(info.constraint, tag: info.tag)
            edits.removeValue(forKey: variable)
        } catch {
            restore(snapshot)
            throw error
        }
    }

    /// Whether `variable` is registered as an edit variable.
    public func hasEditVariable(_ variable: Variable) -> Bool {
        edits[variable] != nil
    }

    /// Suggests a new value for an edit variable, causing the solver to
    /// re-optimize.
    ///
    /// - Throws: `SolverError.unknownEditVariable` if the variable is not an
    ///   edit variable.
    public func suggestValue(_ variable: Variable, _ value: Double) throws {
        guard var info = edits[variable] else {
            throw SolverError.unknownEditVariable
        }
        let snapshot = makeSnapshot()
        do {
            let delta = value - info.constant
            info.constant = value
            edits[variable] = info

            // The edit constraint's row holds one of its two error symbols, or
            // neither. Move the constant of the row so the suggested value is
            // reflected, and note every row that became infeasible.
            if var row = basicRow(info.tag.marker) {
                let newConstant = row.add(-delta)
                storeBasicRow(row, for: info.tag.marker)
                if newConstant < 0.0 {
                    infeasibleRows.append(info.tag.marker)
                }
            } else if var row = basicRow(info.tag.other) {
                let newConstant = row.add(delta)
                storeBasicRow(row, for: info.tag.other)
                if newConstant < 0.0 {
                    infeasibleRows.append(info.tag.other)
                }
            } else {
                for basic in basicSymbols {
                    guard var row = basicRow(basic) else { continue }
                    let coefficient = row.coefficient(for: info.tag.marker)
                    if coefficient != 0.0 {
                        let newConstant = row.add(delta * coefficient)
                        storeBasicRow(row, for: basic)
                        if newConstant < 0.0 && !basic.isExternal {
                            infeasibleRows.append(basic)
                        }
                    }
                }
            }

            guard dualOptimize() else {
                throw SolverError.internalInconsistency("the dual simplex failed to re-optimize the edited system")
            }
        } catch {
            restore(snapshot)
            throw error
        }
    }

    // MARK: - Changing constants

    /// Changes the constant term of a constraint already held by the solver.
    ///
    /// This is the incremental equivalent of removing the constraint and adding
    /// it back with a different constant: the tableau row is adjusted by the
    /// constant delta and the dual simplex restores optimality, so the constraint
    /// keeps its symbols (and therefore the deterministic pivot tie-breaks).
    ///
    /// - Throws: `SolverError.unknownConstraint` if the constraint is not held.
    public func updateConstraintConstant(_ constraint: Constraint, constant: Double) throws {
        try updateConstraintConstants([(constraint, constant)])
    }

    /// Batch form of `updateConstraintConstant(_:constant:)`. All constants are
    /// adjusted first and the system is re-optimized once, which is what the
    /// layout engine uses to advance its per-item "stay" constraints.
    ///
    /// - Throws: `SolverError.unknownConstraint` if a constraint is not held, or
    ///   `SolverError.internalInconsistency` if the tableau cannot be
    ///   re-optimized. The solver state is unchanged when this throws.
    public func updateConstraintConstants(_ updates: [(Constraint, Double)]) throws {
        guard !updates.isEmpty else { return }
        // The build/stay path has no edit variables; roll back by replaying the
        // committed constraint list instead of snapshotting the (reference-typed)
        // tableau. Edit-variable users keep the snapshot path below.
        if edits.isEmpty {
            do {
                try applyConstantUpdates(updates)
            } catch {
                rebuildFromConstraintList()
                throw error
            }
            return
        }
        let snapshot = makeSnapshot()
        do {
            try applyConstantUpdates(updates)
        } catch {
            restore(snapshot)
            throw error
        }
    }

    /// Applies a batch of constant changes and re-optimizes once. Callers own
    /// rollback (snapshot or constraint-list replay).
    private func applyConstantUpdates(_ updates: [(Constraint, Double)]) throws {
        var applied: [(Expression, Double)] = []
        applied.reserveCapacity(updates.count)
        do {
            for (constraint, newConstant) in updates {
                guard let tag = constraintTags[ObjectIdentifier(constraint)] else {
                    throw SolverError.unknownConstraint
                }
                let delta = newConstant - constraint.expression.constant
                guard delta != 0.0 else { continue }
                applied.append((constraint.expression, constraint.expression.constant))
                adjustTableauConstant(tag: tag, delta: delta)
                constraint.expression.constant = newConstant
            }
            guard dualOptimize() else {
                throw SolverError.internalInconsistency("the dual simplex failed to re-optimize changed constants")
            }
        } catch {
            for (expression, oldConstant) in applied {
                expression.constant = oldConstant
            }
            throw error
        }
    }

    /// Applies a constant delta to the tableau row(s) of a constraint, mirroring
    /// `suggestValue(_:_:)`'s use of the constraint's marker/other error symbols.
    /// Rows are reference types, so these updates mutate them in place.
    private func adjustTableauConstant(tag: ConstraintTag, delta: Double) {
        if let row = basicRow(tag.marker) {
            let newConstant = row.add(-delta)
            if newConstant < 0.0 {
                infeasibleRows.append(tag.marker)
            }
        } else if let row = basicRow(tag.other) {
            let newConstant = row.add(delta)
            if newConstant < 0.0 {
                infeasibleRows.append(tag.other)
            }
        } else {
            for basic in basicSymbols {
                guard let row = basicRow(basic) else { continue }
                let coefficient = row.coefficient(for: tag.marker)
                if coefficient != 0.0 {
                    let newConstant = row.add(delta * coefficient)
                    if newConstant < 0.0 && !basic.isExternal {
                        infeasibleRows.append(basic)
                    }
                }
            }
        }
    }

    // MARK: - External values

    /// Updates the external (user-facing) value of all variables from the
    /// current tableau.
    ///
    /// Variables that were never written to the tableau report `0`.
    public func updateVariables() {
        for variable in orderedVariables {
            guard let symbol = variableSymbols[variable.id] else { continue }
            let newValue = basicRow(symbol)?.constant ?? 0.0
            if let oldValue = externalValues[variable.id] {
                if oldValue != newValue {
                    externalValues[variable.id] = newValue
                    changedVariables.insert(variable)
                }
            } else {
                externalValues[variable.id] = newValue
                // The implicit previous value of an unknown variable is zero.
                if newValue != 0.0 {
                    changedVariables.insert(variable)
                }
            }
        }
    }

    /// Re-optimizes the system after edit-variable values changed, then
    /// refreshes the external values.
    ///
    /// Calling this after `suggestValue(_:_:)` is optional — the solver
    /// re-optimizes immediately — but it is harmless and keeps the "suggest,
    /// resolve" workflow of Cassowary available.
    public func resolve() {
        _ = dualOptimize()
        updateVariables()
    }

    /// The current value of a variable in the last solution (0 if it never
    /// appeared / was never updated).
    public func value(of variable: Variable) -> Double {
        if let presolved = presolvedValues[variable.id] { return presolved }
        return externalValues[variable.id] ?? 0.0
    }

    /// Variables whose external values changed since the previous call, with
    /// their new values.
    ///
    /// The change set is cleared by this call. Changes are reported in variable
    /// creation order.
    public func fetchChanges() -> [(Variable, Double)] {
        updateVariables()
        let sorted = changedVariables.sorted { $0.id < $1.id }
        changedVariables.removeAll()
        return sorted.map { ($0, externalValues[$0.id] ?? 0.0) }
    }

    // MARK: - Presolve batch

    /// Starts buffering constraints for a guarded presolve pass. The engine adds
    /// the required constraints (implicit, autoresizing and user required) into
    /// the batch, then calls `endPresolveBatch()`.
    public func beginPresolveBatch() {
        presolveBatch = []
        batchRejectedIndices.removeAll()
    }

    /// Runs the guarded presolve over the buffered constraints and installs the
    /// remainder into the tableau.
    ///
    /// Guards: no edit variables, required equalities only as definitions, and
    /// the whole batch falls back to the ordinary install path (in order) if a
    /// substituted constraint becomes a violated constant or the elimination does
    /// not converge.
    public func endPresolveBatch() {
        guard let batch = presolveBatch else { return }
        presolveBatch = nil
        guard !batch.isEmpty else { return }
        guard Solver.presolvesEnabled, edits.isEmpty else {
            installBatch(batch)
            return
        }

        var pending: [Expression?] = batch.map { $0.expression }
        var operations: [RelationalOperator] = batch.map { $0.op }
        var strengths: [Strength] = batch.map { $0.strength }
        var names: [String?] = batch.map { $0.name }
        var values: [Int: Double] = [:]
        var rejectedDuringElimination: [Int] = []
        var guardOK = true
        var progress = true
        var passes = 0
        while progress && guardOK && passes < 24 {
            progress = false
            passes += 1
            for index in pending.indices {
                guard let uncertain = pending[index] else { continue }
                let simplifiedExpression = simplified(uncertain, cancelling: values)
                let op = operations[index]
                let required = strengths[index] == .required
                if required && op == .equal && simplifiedExpression.terms.count == 1 {
                    let term = simplifiedExpression.terms[0]
                    let value = -simplifiedExpression.constant / term.coefficient
                    if values[term.variable.id] != nil {
                        guardOK = false
                        break
                    }
                    values[term.variable.id] = value
                    pending[index] = nil
                    progress = true
                    continue
                }
                if simplifiedExpression.terms.isEmpty {
                    if required && !holds(simplifiedExpression.constant, op) {
                        if op == .equal {
                            // The first row defined the variable, this later
                            // required equality conflicts with it: the ordinary
                            // install path marks it broken and relaxes it. Record
                            // it and keep eliminating the rest of the system.
                            rejectedDuringElimination.append(index)
                            pending[index] = nil
                            progress = true
                            continue
                        }
                        guardOK = false
                        break
                    }
                    pending[index] = nil
                    progress = true
                    continue
                }
                pending[index] = simplifiedExpression
            }
        }
        if !guardOK || progress {
            // Guard failed (conflict) or elimination did not converge: install the
            // original batch with the ordinary path, no presolve at all.
            presolveFallbackCount += 1
            Solver.totalPresolveFallback += 1
            presolvedValues.removeAll()
            presolveActive = false
            installBatch(batch)
            return
        }
        batchRejectedIndices.append(contentsOf: rejectedDuringElimination)

        // Collect the remaining rows, eliminating exact duplicate required rows.
        var remaining: [(index: Int, constraint: Constraint)] = []
        var seen: Set<PresolvedRowKey> = []
        for index in pending.indices {
            guard let uncertain = pending[index] else { continue }
            let sim = simplified(uncertain, cancelling: values)
            if sim.terms.isEmpty {
                if strengths[index] == .required && !holds(sim.constant, operations[index]) {
                    presolveFallbackCount += 1
                    Solver.totalPresolveFallback += 1
                    presolvedValues.removeAll()
                    presolveActive = false
                    installBatch(batch)
                    return
                }
                continue
            }
            let constraint = Constraint(sim, operations[index], strength: strengths[index], name: names[index])
            if strengths[index] == .required,
               !seen.insert(PresolvedRowKey(constraint)).inserted {
                continue
            }
            remaining.append((index: index, constraint: constraint))
        }

        presolvedValues = values
        presolvedVariableCount += values.count
        presolveAppliedCount += 1
        Solver.totalPresolveApplied += 1
        presolveActive = true
        for entry in remaining {
            let constraint = entry.constraint
            do {
                try addConstraintInternalNoSnapshot(constraint)
                constraints.append(constraint)
            } catch {
                if constraint.strength == .required {
                    // Match the ordinary path: a required row the solver cannot
                    // satisfy is retried at the "broken" strength.
                    batchRejectedIndices.append(entry.index)
                    let relaxed = Constraint(constraint.expression.plus(Expression(constant: 0)),
                                             constraint.op,
                                             strength: Strength.clip(Strength.required.value - 1),
                                             name: constraint.name)
                    try? addConstraintInternalNoSnapshot(relaxed)
                    constraints.append(relaxed)
                }
            }
        }
        updateVariables()
    }

    /// Installs a buffered batch through the ordinary per-constraint path.
    private func installBatch(_ batch: [Constraint]) {
        for (index, constraint) in batch.enumerated() {
            do {
                try addConstraintInternalNoSnapshot(constraint)
                constraints.append(constraint)
            } catch {
                if constraint.strength == .required {
                    batchRejectedIndices.append(index)
                    let relaxed = Constraint(constraint.expression.plus(Expression(constant: 0)),
                                             constraint.op,
                                             strength: Strength.clip(Strength.required.value - 1),
                                             name: constraint.name)
                    try? addConstraintInternalNoSnapshot(relaxed)
                    constraints.append(relaxed)
                }
            }
        }
        updateVariables()
    }

    /// Rebuilds an expression with eliminated variables folded into the constant.
    private func simplified(_ expression: Expression, cancelling values: [Int: Double]) -> Expression {
        var constant = expression.constant
        let result = Expression(constant: 0.0)
        for term in expression.terms {
            if let value = values[term.variable.id] {
                constant += term.coefficient * value
            } else {
                result.add(term, merging: true)
            }
        }
        result.constant = constant
        return result
    }

    /// Whether `constant <op> 0` holds.
    private func holds(_ constant: Double, _ op: RelationalOperator) -> Bool {
        switch op {
        case .equal:
            return nearZero(constant)
        case .lessThanOrEqual:
            return constant <= 0.0 || nearZero(constant)
        case .greaterThanOrEqual:
            return constant >= 0.0 || nearZero(constant)
        }
    }

    /// Canonical key for exact duplicate required rows.
    private struct PresolvedRowKey: Hashable {
        private let operation: Int
        private let constant: Double
        private let terms: [Int64]

        init(_ constraint: Constraint) {
            switch constraint.op {
            case .equal: operation = 0
            case .lessThanOrEqual: operation = 1
            case .greaterThanOrEqual: operation = 2
            }
            constant = constraint.expression.constant
            var encoded: [Int64] = []
            encoded.reserveCapacity(constraint.expression.terms.count)
            for term in constraint.expression.terms {
                // Pack (variable id, coefficient bits) deterministically.
                encoded.append((Int64(term.variable.id) << 32) | Int64(term.coefficient.bitPattern & 0xFFFF_FFFF))
            }
            encoded.sort()
            terms = encoded
        }
    }

    /// Removes all constraints, edit variables and external values.
    public func reset() {
        constraints.removeAll()
        constraintTags.removeAll()
        basicRows.removeAll()
        basicSymbols.removeAll()
        rowsBySymbol.removeAll()
        orderedVariables.removeAll()
        variableSymbols.removeAll()
        objective = Row()
        artificialRow = nil
        infeasibleRows.removeAll()
        edits.removeAll()
        externalValues.removeAll()
        changedVariables.removeAll()
        presolvedValues.removeAll()
        presolveActive = false
        presolveBatch = nil
        idTick = 1
    }

    // MARK: - Tableau snapshots

    /// A shallow copy of the complete solver state.
    ///
    /// The rows share their cell dictionaries with the live tableau and Swift's
    /// copy-on-write makes both taking and restoring a snapshot cheap, so every
    /// operation that can fail is transactional.
    private struct Snapshot {
        var constraints: [Constraint]
        var constraintTags: [ObjectIdentifier: ConstraintTag]
        var basicRows: [Row?]
        var basicSymbols: [Symbol]
        var orderedVariables: [Variable]
        var variableSymbols: [Int: Symbol]
        var objective: Row
        var artificialRow: Row?
        var infeasibleRows: [Symbol]
        var edits: [Variable: EditInfo]
        var externalValues: [Int: Double]
        var changedVariables: Set<Variable>
        var idTick: Int
    }

    private func makeSnapshot() -> Snapshot {
        var rowsCopy: [Row?] = []
        rowsCopy.reserveCapacity(basicRows.count)
        for row in basicRows {
            rowsCopy.append(row.map { Row(copying: $0) })
        }
        return Snapshot(
            constraints: constraints,
            constraintTags: constraintTags,
            basicRows: rowsCopy,
            basicSymbols: basicSymbols,
            orderedVariables: orderedVariables,
            variableSymbols: variableSymbols,
            objective: Row(copying: objective),
            artificialRow: artificialRow.map { Row(copying: $0) },
            infeasibleRows: infeasibleRows,
            edits: edits,
            externalValues: externalValues,
            changedVariables: changedVariables,
            idTick: idTick
        )
    }

    private func restore(_ snapshot: Snapshot) {
        constraints = snapshot.constraints
        constraintTags = snapshot.constraintTags
        basicRows = snapshot.basicRows
        basicSymbols = snapshot.basicSymbols
        orderedVariables = snapshot.orderedVariables
        variableSymbols = snapshot.variableSymbols
        objective = snapshot.objective
        artificialRow = snapshot.artificialRow
        infeasibleRows = snapshot.infeasibleRows
        edits = snapshot.edits
        externalValues = snapshot.externalValues
        changedVariables = snapshot.changedVariables
        idTick = snapshot.idTick
        rebuildSymbolIndex()
    }

    // MARK: - Adding constraints

    /// Adds a constraint to the tableau, registering its tag but not adding it
    /// to the public `constraints` list. Used for both user constraints and the
    /// internal constraints behind edit variables. Transactional: a failure
    /// restores the previous state (this path is used when edit variables are
    /// registered, where the constraint list alone cannot rebuild the tableau).
    private func addConstraintInternal(_ constraint: Constraint) throws {
        let identifier = ObjectIdentifier(constraint)
        if constraintTags[identifier] != nil {
            throw SolverError.duplicateConstraint
        }
        let snapshot = makeSnapshot()
        do {
            let tag = try createRowAndAddConstraint(constraint)
            constraintTags[identifier] = tag
        } catch {
            restore(snapshot)
            throw error
        }
    }

    /// `addConstraintInternal` for the no-edit-variable hot path. It does not
    /// snapshot the tableau; the caller rolls a failure back with
    /// `rebuildFromConstraintList`.
    private func addConstraintInternalNoSnapshot(_ constraint: Constraint) throws {
        let identifier = ObjectIdentifier(constraint)
        if constraintTags[identifier] != nil {
            throw SolverError.duplicateConstraint
        }
        let tag = try createRowAndAddConstraint(constraint)
        constraintTags[identifier] = tag
    }

    /// Rolls back a failed constraint add by rebuilding the tableau from the
    /// committed constraint list. Only used on the rare failure path, and only
    /// when there are no edit variables (they are not in the constraint list).
    private func rebuildFromConstraintList() {
        let committed = constraints
        let variableOrder = orderedVariables
        reset()
        // The committed list was consistent before the failed add, so replaying
        // it succeeds deterministically (same symbol allocation order).
        for constraint in committed {
            try? addConstraintInternalNoSnapshot(constraint)
        }
        _ = variableOrder
    }

    /// Creates the tableau row for `constraint` and brings it into the basis.
    ///
    /// Required constraints are added with the two-phase method: if the row has
    /// no valid subject, an artificial variable is introduced and phase one
    /// drives its value to zero. Non-required constraints are added as weighted
    /// error terms of the objective.
    private func createRowAndAddConstraint(_ constraint: Constraint) throws -> ConstraintTag {
        var tag = ConstraintTag()
        var row = createRow(constraint, tag: &tag)
        var subject = chooseSubject(row, tag: tag)

        // If no valid subject was found, the only remaining option is a
        // redundant constraint: an all-dummy row that must have a zero constant.
        if subject == .invalid && allDummies(row) {
            guard nearZero(row.constant) else {
                throw SolverError.unsatisfiableConstraint
            }
            subject = tag.marker
        }

        if subject == .invalid {
            guard try addWithArtificialVariable(row) else {
                throw SolverError.unsatisfiableConstraint
            }
        } else {
            try row.solveFor(subject)
            substitute(subject, row)
            setBasicRow(row, for: subject)
        }

        try optimize(objectiveRow: .main)
        return tag
    }

    /// Builds the tableau row for `constraint`.
    ///
    /// Terms of the constraint whose variables are already basic are
    /// substituted in, so the new row only contains non-basic symbols. The row
    /// is then extended with the slack/error/dummy symbols that encode the
    /// relational operator and the strength. The constant is made positive so
    /// the slack variables are non-negative.
    private func createRow(_ constraint: Constraint, tag: inout ConstraintTag) -> Row {
        var row = Row(constant: constraint.expression.constant)

        for term in constraint.expression.terms {
            if !nearZero(term.coefficient) {
                let symbol = symbol(for: term.variable)
                if let existingRow = basicRow(symbol) {
                    row.insert(existingRow, term.coefficient)
                } else {
                    row.insert(symbol, term.coefficient)
                }
            }
        }

        switch constraint.op {
        case .lessThanOrEqual, .greaterThanOrEqual:
            // expression <= 0  =>  expression + slack = 0
            // expression >= 0  =>  expression - slack = 0
            let coefficient = constraint.op == .lessThanOrEqual ? 1.0 : -1.0
            let slack = makeSymbol(.slack)
            tag.marker = slack
            row.insert(slack, coefficient)
            if !constraint.isRequired {
                let error = makeSymbol(.error)
                tag.other = error
                row.insert(error, -coefficient)
                objective.insert(error, constraint.strength.value)
            }

        case .equal:
            if constraint.isRequired {
                let dummy = makeSymbol(.dummy)
                tag.marker = dummy
                row.insert(dummy)
            } else {
                // expression == errPlus - errMinus, both penalized.
                let errorPlus = makeSymbol(.error)
                let errorMinus = makeSymbol(.error)
                tag.marker = errorPlus
                tag.other = errorMinus
                row.insert(errorPlus, -1.0)
                row.insert(errorMinus, 1.0)
                objective.insert(errorPlus, constraint.strength.value)
                objective.insert(errorMinus, constraint.strength.value)
            }
        }

        // The row must start with a positive constant; otherwise invert it.
        if row.constant < 0.0 {
            row.reverseSign()
        }
        return row
    }

    /// Chooses the subject symbol for a new row.
    ///
    /// Precedence, as in kiwi:
    /// 1. the first external variable in the row,
    /// 2. a slack or error tag symbol with a negative coefficient.
    ///
    /// Returns `.invalid` when the row needs an artificial variable.
    private func chooseSubject(_ row: Row, tag: ConstraintTag) -> Symbol {
        for symbol in row.symbols {
            if symbol.isExternal {
                return symbol
            }
        }
        if tag.marker.isPivotable && row.coefficient(for: tag.marker) < 0.0 {
            return tag.marker
        }
        if tag.other.isPivotable && row.coefficient(for: tag.other) < 0.0 {
            return tag.other
        }
        return .invalid
    }

    /// Whether the row consists solely of dummy symbols.
    private func allDummies(_ row: Row) -> Bool {
        for symbol in row.symbols {
            if !symbol.isDummy {
                return false
            }
        }
        return true
    }

    // MARK: - Artificial variables (phase one)

    /// Adds a row using the artificial-variable two-phase method.
    ///
    /// Phase one minimizes the artificial variable; the constraint is
    /// satisfiable exactly when that minimum is zero. Returns `false` when it is
    /// not (the caller rolls the tableau back).
    private func addWithArtificialVariable(_ row: Row) throws -> Bool {
        let artificialSymbol = makeSymbol(.slack)
        setBasicRow(row, for: artificialSymbol)
        // Keep the artificial objective as an independent copy: rows are
        // reference types now, and the previous value-typed implementation had
        // two independent copies here. Aliasing them would make substitution
        // operate on a row while it is being iterated.
        artificialRow = Row(copying: row)

        try optimize(objectiveRow: .artificial)

        // The artificial objective is zero exactly when the constraint is
        // satisfiable together with the ones already in the solver.
        let success = nearZero(artificialRow?.constant ?? 0.0)
        artificialRow = nil

        // If the artificial variable is still basic, pivot it out of the basis.
        if var artificialTableauRow = basicRow(artificialSymbol) {
            _ = removeBasicRow(for: artificialSymbol)
            if artificialTableauRow.isEmpty {
                return success
            }
            let entering = anyPivotableSymbol(artificialTableauRow)
            guard entering != .invalid else {
                return false
            }
            try artificialTableauRow.solveFor(artificialSymbol, entering)
            substitute(entering, artificialTableauRow)
            setBasicRow(artificialTableauRow, for: entering)
        }

        // Remove every remaining trace of the artificial variable.
        for basic in basicSymbols {
            guard var row = basicRow(basic) else { continue }
            row.remove(artificialSymbol)
            storeBasicRow(row, for: basic)
        }
        objective.remove(artificialSymbol)
        return success
    }

    // MARK: - Tableau operations

    /// Substitutes `symbol` with `row` everywhere in the tableau and objective.
    ///
    /// Newly infeasible rows are recorded so a later dual optimization can fix
    /// them.
    private func substitute(_ symbol: Symbol, _ row: Row) {
        if let containing = rowsBySymbol[symbol.id] {
            for basic in containing {
                guard let stored = basicRow(basic) else { continue }
                let previousSymbols = stored.symbols
                stored.substitute(symbol, with: row)
                unindexSymbols(previousSymbols, basic: basic)
                indexRowSymbols(stored, basic: basic)
                if !basic.isExternal && stored.constant < 0.0 {
                    infeasibleRows.append(basic)
                }
            }
        }
        objective.substitute(symbol, with: row)
        artificialRow?.substitute(symbol, with: row)
    }

    /// The objective used by `optimize(objectiveRow:)`.
    private enum ObjectiveRow {
        case main
        case artificial
    }

    /// Runs the primal simplex method on `objectiveRow` until it is optimal.
    ///
    /// - Throws: `SolverError.internalInconsistency` if the objective is
    ///   unbounded, which indicates a numerical failure.
    private func optimize(objectiveRow: ObjectiveRow) throws {
        while true {
            let context: Row
            switch objectiveRow {
            case .main:
                context = objective
            case .artificial:
                guard let artificial = artificialRow else { return }
                context = artificial
            }

            let entering = getEnteringSymbol(context)
            if entering == .invalid {
                return
            }
            guard let leaving = getLeavingRow(entering) else {
                throw SolverError.internalInconsistency("the objective is unbounded")
            }
            guard var leavingRow = basicRow(leaving) else {
                throw SolverError.internalInconsistency("the tableau lost a basic row")
            }
            _ = removeBasicRow(for: leaving)
            try leavingRow.solveFor(leaving, entering)
            substitute(entering, leavingRow)
            setBasicRow(leavingRow, for: entering)
        }
    }

    /// Runs the dual simplex method until every recorded infeasible row is
    /// feasible again. The objective is assumed to be optimal already, which is
    /// the case after a constraint is removed or an edit value is suggested.
    ///
    /// - Returns: `false` when a row could not be made feasible.
    private func dualOptimize() -> Bool {
        while !infeasibleRows.isEmpty {
            let leaving = infeasibleRows.removeLast()
            guard let row = basicRow(leaving) else { continue }
            if nearZero(row.constant) || row.constant >= 0.0 {
                continue
            }
            let entering = getDualEnteringSymbol(row)
            guard entering != .invalid else {
                return false
            }
            var leavingRow = row
            _ = removeBasicRow(for: leaving)
            do {
                try leavingRow.solveFor(leaving, entering)
            } catch {
                return false
            }
            substitute(entering, leavingRow)
            setBasicRow(leavingRow, for: entering)
        }
        return true
    }

    /// The first non-dummy symbol with a negative coefficient in the objective.
    private func getEnteringSymbol(_ objective: Row) -> Symbol {
        return objective.firstNegativePivotableSymbol() ?? .invalid
    }

    /// The symbol whose ratio `objectiveCoefficient / rowCoefficient` is
    /// smallest among the positive coefficients of an infeasible row.
    private func getDualEnteringSymbol(_ row: Row) -> Symbol {
        var ratio = Double.greatestFiniteMagnitude
        var entering = Symbol.invalid
        for symbol in row.symbols {
            let coefficient = row.coefficient(for: symbol)
            if coefficient > 0.0 && !symbol.isDummy {
                let objectiveCoefficient = objective.coefficient(for: symbol)
                let candidate = objectiveCoefficient / coefficient
                if candidate < ratio {
                    ratio = candidate
                    entering = symbol
                }
            }
        }
        return entering
    }

    /// The first slack or error symbol in the row, if any.
    private func anyPivotableSymbol(_ row: Row) -> Symbol {
        for symbol in row.symbols {
            if symbol.isPivotable {
                return symbol
            }
        }
        return .invalid
    }

    /// The basic symbol whose row has the smallest ratio of `-constant /
    /// coefficient` among rows with a negative coefficient for `entering`.
    private func getLeavingRow(_ entering: Symbol) -> Symbol? {
        var ratio = Double.greatestFiniteMagnitude
        var found: Symbol?
        if let containing = rowsBySymbol[entering.id] {
            for basic in containing {
                guard !basic.isExternal, let row = basicRow(basic) else { continue }
                let coefficient = row.coefficient(for: entering)
                if coefficient < 0.0 {
                    let candidate = -row.constant / coefficient
                    if candidate < ratio {
                        ratio = candidate
                        found = basic
                    }
                }
            }
        }
        return found
    }

    /// Chooses the row to pivot the marker of a removed constraint into.
    ///
    /// Precedence, as in kiwi:
    /// 1. a restricted row with a negative marker coefficient and the smallest
    ///    ratio `-constant / coefficient`,
    /// 2. a restricted row with the smallest ratio `constant / coefficient`,
    /// 3. the last unrestricted row containing the marker.
    private func getMarkerLeavingRow(_ marker: Symbol) -> Symbol? {
        let maximum = Double.greatestFiniteMagnitude
        var firstRatio = maximum
        var secondRatio = maximum
        var first: Symbol?
        var second: Symbol?
        var third: Symbol?

        for basic in basicSymbols {
            guard let row = basicRow(basic) else { continue }
            let coefficient = row.coefficient(for: marker)
            if coefficient == 0.0 {
                continue
            }
            if basic.isExternal {
                third = basic
            } else if coefficient < 0.0 {
                let ratio = -row.constant / coefficient
                if ratio < firstRatio {
                    firstRatio = ratio
                    first = basic
                }
            } else {
                let ratio = row.constant / coefficient
                if ratio < secondRatio {
                    secondRatio = ratio
                    second = basic
                }
            }
        }
        if let first = first {
            return first
        }
        if let second = second {
            return second
        }
        return third
    }

    // MARK: - Constraint bookkeeping

    /// Removes `constraint` from the tableau. The caller is responsible for the
    /// surrounding snapshot/restore and for removing the public bookkeeping.
    private func removeConstraintInternal(_ constraint: Constraint, tag: ConstraintTag) throws {
        // The error effects must be removed from the objective *before*
        // pivoting, or substitutions into the objective would use the wrong
        // weights.
        removeConstraintEffects(constraint, tag: tag)

        // If the marker is basic, drop its row. Otherwise pivot the marker into
        // the basis first, then drop the row it left.
        if basicRow(tag.marker) != nil {
            _ = removeBasicRow(for: tag.marker)
        } else {
            guard let leaving = getMarkerLeavingRow(tag.marker) else {
                throw SolverError.internalInconsistency("failed to find a leaving row for the removed constraint")
            }
            guard var leavingRow = basicRow(leaving) else {
                throw SolverError.internalInconsistency("the tableau lost a basic row")
            }
            // Pivot the marker into the basis, substitute it throughout the
            // tableau and then drop the row: nothing references the marker any
            // more, so keeping a dead basic row would leave the tableau
            // primal-infeasible for the next constraint that is added.
            _ = removeBasicRow(for: leaving)
            try leavingRow.solveFor(leaving, tag.marker)
            substitute(tag.marker, leavingRow)
        }

        // Re-optimize: removing a non-basic marker can make the objective
        // sub-optimal, so the primal simplex restores optimality.
        try optimize(objectiveRow: .main)
        constraintTags.removeValue(forKey: ObjectIdentifier(constraint))
    }

    /// Removes the objective contribution of a constraint's error symbols.
    private func removeConstraintEffects(_ constraint: Constraint, tag: ConstraintTag) {
        if tag.marker.kind == .error {
            removeMarkerEffects(tag.marker, strength: constraint.strength.value)
        }
        if tag.other.kind == .error {
            removeMarkerEffects(tag.other, strength: constraint.strength.value)
        }
    }

    /// Removes the objective contribution of a single error marker.
    private func removeMarkerEffects(_ marker: Symbol, strength: Double) {
        if let row = basicRow(marker) {
            objective.insert(row, -strength)
        } else {
            objective.insert(marker, -strength)
        }
    }

    // MARK: - Symbols

    /// The symbol for `variable`, allocating one on first use.
    ///
    /// Allocation order determines every symbol id, so the ids — and therefore
    /// all tie-breaks — depend only on the sequence of calls into the solver.
    private func symbol(for variable: Variable) -> Symbol {
        if let symbol = variableSymbols[variable.id] {
            return symbol
        }
        let symbol = makeSymbol(.external)
        variableSymbols[variable.id] = symbol
        orderedVariables.append(variable)
        return symbol
    }

    /// Allocates a fresh symbol of the given kind.
    private func makeSymbol(_ kind: Symbol.Kind) -> Symbol {
        let symbol = Symbol(kind, idTick)
        idTick += 1
        return symbol
    }

    // MARK: - Ordered basis maintenance

    private func basicRow(_ symbol: Symbol) -> Row? {
        let id = symbol.id
        guard id >= 0, id < basicRows.count else { return nil }
        return basicRows[id]
    }

    private func storeBasicRow(_ row: Row, for symbol: Symbol) {
        let id = symbol.id
        if id >= basicRows.count {
            basicRows.append(contentsOf: repeatElement(nil, count: id - basicRows.count + 1))
        }
        basicRows[id] = row
    }

    private func setBasicRow(_ row: Row, for symbol: Symbol) {
        if let previous = basicRow(symbol) {
            unindexRowSymbols(previous, basic: symbol)
        } else {
            insertBasicSymbol(symbol)
        }
        storeBasicRow(row, for: symbol)
        indexRowSymbols(row, basic: symbol)
    }

    @discardableResult
    private func removeBasicRow(for symbol: Symbol) -> Row? {
        guard let row = basicRow(symbol) else { return nil }
        unindexRowSymbols(row, basic: symbol)
        basicRows[symbol.id] = nil
        removeBasicSymbol(symbol)
        return row
    }

    private func insertBasicSymbol(_ symbol: Symbol) {
        var low = 0
        var high = basicSymbols.count
        while low < high {
            let middle = (low + high) / 2
            if basicSymbols[middle].id < symbol.id {
                low = middle + 1
            } else {
                high = middle
            }
        }
        basicSymbols.insert(symbol, at: low)
    }

    private func removeBasicSymbol(_ symbol: Symbol) {
        var low = 0
        var high = basicSymbols.count
        while low < high {
            let middle = (low + high) / 2
            let candidate = basicSymbols[middle]
            if candidate.id < symbol.id {
                low = middle + 1
            } else if candidate.id > symbol.id {
                high = middle
            } else {
                basicSymbols.remove(at: middle)
                return
            }
        }
    }

    // MARK: - Column index

    private func indexRowSymbols(_ row: Row, basic: Symbol) {
        for contained in row.symbols {
            var list = rowsBySymbol[contained.id] ?? []
            var low = 0
            var high = list.count
            while low < high {
                let middle = (low + high) / 2
                if list[middle].id < basic.id {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low < list.count && list[low] == basic { continue }
            list.insert(basic, at: low)
            rowsBySymbol[contained.id] = list
        }
    }

    private func unindexRowSymbols(_ row: Row, basic: Symbol) {
        unindexSymbols(row.symbols, basic: basic)
    }

    private func unindexSymbols(_ symbols: [Symbol], basic: Symbol) {
        for contained in symbols {
            guard var list = rowsBySymbol[contained.id] else { continue }
            var found = false
            for index in list.indices where list[index] == basic {
                list.remove(at: index)
                found = true
                break
            }
            if !found { continue }
            if list.isEmpty {
                rowsBySymbol.removeValue(forKey: contained.id)
            } else {
                rowsBySymbol[contained.id] = list
            }
        }
    }

    private func rebuildSymbolIndex() {
        rowsBySymbol.removeAll(keepingCapacity: true)
        for symbol in basicSymbols {
            guard let row = basicRow(symbol) else { continue }
            indexRowSymbols(row, basic: symbol)
        }
    }
}
