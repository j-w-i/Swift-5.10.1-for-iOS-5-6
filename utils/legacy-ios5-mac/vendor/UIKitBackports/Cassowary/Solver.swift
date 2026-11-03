//
//  Solver.swift
//  Cassowary
//
//  The layout engine's solver. A thin Swift facade over the C core (CassowaryC): flat arrays, no reference counting or
//  copy-on-write in the pivot loops. The original pure-Swift implementation is kept as `SwiftReferenceSolver`
//  (SolverReference.swift); Tests/run-cassowary-c-diff.sh proves the C core bit-identical to it.
//
//  The API is exactly the one LegacyLayoutSolver and the tests used before the port.
//

import Foundation

// Declared directly with @_silgen_name: the UIKit overlay cannot depend on a C module at client compile time. The
// symbols are linked from the vendored runtime archive (CassowaryC.c), the same way UICInstallConstraintClassMethods is.
// Only pointers and Int32 cross the boundary (see CSAdd in CassowaryC.h).
@_silgen_name("cs_create") private func cs_create() -> OpaquePointer?
@_silgen_name("cs_destroy") private func cs_destroy(_ s: OpaquePointer?)
@_silgen_name("cs_reset") private func cs_reset(_ s: OpaquePointer?)
@_silgen_name("cs_reserve") private func cs_reserve(_ s: OpaquePointer?, _ constraints: Int32, _ variables: Int32)
@_silgen_name("cs_add") private func cs_add(_ s: OpaquePointer?, _ request: UnsafeMutableRawPointer) -> Int32
@_silgen_name("cs_remove_constraint") private func cs_remove_constraint(_ s: OpaquePointer?, _ handle: Int32) -> Int32
@_silgen_name("cs_has_constraint") private func cs_has_constraint(_ s: OpaquePointer?, _ handle: Int32) -> Int32
@_silgen_name("cs_update_constants_p") private func cs_update_constants_p(_ s: OpaquePointer?, _ handles: UnsafePointer<Int32>, _ constants: UnsafePointer<Double>, _ count: Int32) -> Int32
@_silgen_name("cs_begin_presolve_batch") private func cs_begin_presolve_batch(_ s: OpaquePointer?)
@_silgen_name("cs_variable_determined") private func cs_variable_determined(_ s: OpaquePointer?, _ variable: Int32) -> Int32
@_silgen_name("cs_end_presolve_batch") private func cs_end_presolve_batch(_ s: OpaquePointer?)
@_silgen_name("cs_batch_rejected_count") private func cs_batch_rejected_count(_ s: OpaquePointer?) -> Int32
@_silgen_name("cs_batch_rejected_at") private func cs_batch_rejected_at(_ s: OpaquePointer?, _ i: Int32) -> Int32
@_silgen_name("cs_presolve_active") private func cs_presolve_active(_ s: OpaquePointer?) -> Int32
@_silgen_name("cs_has_presolved_variables") private func cs_has_presolved_variables(_ s: OpaquePointer?) -> Int32
@_silgen_name("cs_is_presolved") private func cs_is_presolved(_ s: OpaquePointer?, _ variable: Int32) -> Int32
@_silgen_name("cs_update_variables") private func cs_update_variables(_ s: OpaquePointer?)
@_silgen_name("cs_value_out") private func cs_value_out(_ s: OpaquePointer?, _ variable: Int32, _ out: UnsafeMutablePointer<Double>) -> Int32
@_silgen_name("cs_variable_count") private func cs_variable_count(_ s: OpaquePointer?) -> Int32
@_silgen_name("cs_constraint_count") private func cs_constraint_count(_ s: OpaquePointer?) -> Int32
@_silgen_name("cs_replay_stats") private func cs_replay_stats(_ total: UnsafeMutablePointer<Int32>, _ presolved: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("cs_density") private func cs_density(_ s: OpaquePointer?, _ rows: UnsafeMutablePointer<Int32>, _ cells: UnsafeMutablePointer<Int32>, _ maxRow: UnsafeMutablePointer<Int32>, _ maxCol: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("cs_set_presolves_enabled") private func cs_set_presolves_enabled(_ enabled: Int32)
@_silgen_name("cs_total_presolve_applied") private func cs_total_presolve_applied() -> Int32
@_silgen_name("cs_total_presolve_fallback") private func cs_total_presolve_fallback() -> Int32
@_silgen_name("cs_reset_presolve_statistics") private func cs_reset_presolve_statistics()

private let coreUnsatisfiable: Int32 = 1, coreDuplicate: Int32 = 2, coreUnknown: Int32 = 3

/// Layout of `CSAdd` in CassowaryC.h. Kept here, in one place, so the by-pointer call stays in sync.
private struct AddRequest {
    var constant: Double
    var strength: Double
    var vars: UnsafePointer<Int32>?
    var coefs: UnsafePointer<Double>?
    var termCount: Int32
    var op: Int32
    var required: Int32
    var error: Int32
}

public final class Solver {

    private var core: OpaquePointer?
    // A Constraint can participate in independent solvers (e.g. live layout and fitting measurement).
    // Keep handles here, never on the shared constraint object. Retain the object to prevent identity reuse.
    private var handles: [ObjectIdentifier: (constraint: Constraint, handle: Int32)] = [:]

    /// Constraints currently held by the solver, in insertion order.
    public private(set) var constraints: [Constraint] = []

    private var presolveBatch: [Constraint]?
    public private(set) var batchRejectedIndices: [Int] = []

    public init() {
        core = cs_create()
    }
    deinit { cs_destroy(core) }

    // MARK: Presolve

    /// Switches the guarded presolve pass (kept in step with the C core's switch).
    public static var presolvesEnabled: Bool = true {
        didSet { cs_set_presolves_enabled(presolvesEnabled ? 1 : 0) }
    }
    public private(set) static var totalPresolveApplied: Int {
        get { Int(cs_total_presolve_applied()) }
        set { _ = newValue }
    }
    public private(set) static var totalPresolveFallback: Int {
        get { Int(cs_total_presolve_fallback()) }
        set { _ = newValue }
    }
    public static func resetPresolveStatistics() { cs_reset_presolve_statistics() }

    public var presolveActive: Bool { cs_presolve_active(core) != 0 }
    public var hasPresolvedVariables: Bool { cs_has_presolved_variables(core) != 0 }
    public func isPresolved(_ variable: Variable) -> Bool { cs_is_presolved(core, Int32(variable.id)) != 0 }
    public var presolveBatchCount: Int { presolveBatch?.count ?? 0 }
    public var isCollectingPresolveBatch: Bool { presolveBatch != nil }

    // MARK: Sizes

    public func reserveCapacity(constraintCount: Int, variableCount: Int) {
        cs_reserve(core, Int32(constraintCount), Int32(variableCount))
        constraints.reserveCapacity(constraintCount)
    }
    public var variableCount: Int { Int(cs_variable_count(core)) }
    /// Tableau density diagnostics: (basic rows, total cells, longest row, longest column list).
    public var density: (rows: Int, cells: Int, maxRow: Int, maxCol: Int) {
        var r: Int32 = 0, c: Int32 = 0, mr: Int32 = 0, mc: Int32 = 0
        _ = cs_density(core, &r, &c, &mr, &mc)
        return (Int(r), Int(c), Int(mr), Int(mc))
    }
    public var constraintCount: Int { Int(cs_constraint_count(core)) }
    /// Diagnostics: process-wide replay (failure-recovery rebuild) counts, total and with presolved variables.
    public static var replayStats: (total: Int, presolved: Int) {
        var t: Int32 = 0, p: Int32 = 0
        _ = cs_replay_stats(&t, &p)
        return (Int(t), Int(p))
    }

    // MARK: Constraints

    public func addConstraint(_ constraint: Constraint) throws {
        if presolveBatch != nil {
            presolveBatch?.append(constraint)
            _ = try submit(constraint)      // buffered by the core; installed at endPresolveBatch()
            return
        }
        if hasConstraint(constraint) { throw SolverError.duplicateConstraint }
        if try submit(constraint) { constraints.append(constraint) }
    }

    /// Hands the constraint to the core. Returns whether the core now holds it.
    private func submit(_ constraint: Constraint) throws -> Bool {
        let expression = constraint.expression
        var vars = [Int32](); var coefs = [Double]()
        vars.reserveCapacity(expression.terms.count); coefs.reserveCapacity(expression.terms.count)
        for term in expression.terms { vars.append(Int32(term.variable.id)); coefs.append(term.coefficient) }
        let op: Int32
        switch constraint.op { case .equal: op = 0; case .lessThanOrEqual: op = 1; case .greaterThanOrEqual: op = 2 }
        var request = AddRequest(constant: expression.constant, strength: constraint.strength.value, vars: nil, coefs: nil,
                                 termCount: Int32(vars.count), op: op, required: constraint.strength == .required ? 1 : 0, error: 0)
        let handle: Int32 = vars.withUnsafeBufferPointer { v in
            coefs.withUnsafeBufferPointer { c in
                request.vars = v.baseAddress; request.coefs = c.baseAddress
                return withUnsafeMutablePointer(to: &request) { cs_add(core, UnsafeMutableRawPointer($0)) }
            }
        }
        if handle == -1 {
            switch request.error {
            case coreUnsatisfiable: throw SolverError.unsatisfiableConstraint
            case coreDuplicate: throw SolverError.duplicateConstraint
            default: throw SolverError.internalInconsistency("presolved constraints conflict")
            }
        }
        if handle == -2 { return false }
        handles[ObjectIdentifier(constraint)] = (constraint, handle)
        return presolveBatch == nil
    }

    public func removeConstraint(_ constraint: Constraint) throws {
        guard hasConstraint(constraint) else { throw SolverError.unknownConstraint }
        let rc = cs_remove_constraint(core, handles[ObjectIdentifier(constraint)]!.handle)
        if rc != 0 {
            resyncAfterReplay()
            throw rc == coreUnknown ? SolverError.unknownConstraint : SolverError.internalInconsistency("failed to remove a constraint")
        }
        handles.removeValue(forKey: ObjectIdentifier(constraint))
        if let index = constraints.firstIndex(where: { $0 === constraint }) { constraints.remove(at: index) }
    }

    public func hasConstraint(_ constraint: Constraint) -> Bool {
        guard let entry = handles[ObjectIdentifier(constraint)] else { return false }
        return entry.constraint === constraint && cs_has_constraint(core, entry.handle) != 0
    }

    public func updateConstraintConstant(_ constraint: Constraint, constant: Double) throws {
        try updateConstraintConstants([(constraint, constant)])
    }

    public func updateConstraintConstants(_ updates: [(Constraint, Double)]) throws {
        guard !updates.isEmpty else { return }
        var handles = [Int32](); var constants = [Double]()
        handles.reserveCapacity(updates.count); constants.reserveCapacity(updates.count)
        for (constraint, value) in updates {
            guard hasConstraint(constraint) else { throw SolverError.unknownConstraint }
            handles.append(self.handles[ObjectIdentifier(constraint)]!.handle); constants.append(value)
        }
        let rc = handles.withUnsafeBufferPointer { h in
            constants.withUnsafeBufferPointer { c in cs_update_constants_p(core, h.baseAddress!, c.baseAddress!, Int32(updates.count)) }
        }
        if rc != 0 {
            resyncAfterReplay()
            throw rc == coreUnknown ? SolverError.unknownConstraint : SolverError.internalInconsistency("the dual simplex failed to re-optimize changed constants")
        }
        for (constraint, value) in updates { constraint.expression.constant = value }
    }

    /// After the core replayed its committed list (a failed remove/update), constraints it could not re-add are no longer
    /// held; mirror that in the public list exactly like SwiftReferenceSolver.rebuildFromConstraintList().
    private func resyncAfterReplay() {
        constraints.removeAll { !hasConstraint($0) }
        handles = handles.filter { cs_has_constraint(core, $0.value.handle) != 0 }
    }

    // MARK: Presolve batch

    public func beginPresolveBatch() {
        presolveBatch = []
        batchRejectedIndices.removeAll()
        cs_begin_presolve_batch(core)
    }

    public func endPresolveBatch() {
        guard let batch = presolveBatch else { return }
        presolveBatch = nil
        cs_end_presolve_batch(core)
        batchRejectedIndices = (0..<Int(cs_batch_rejected_count(core))).map { Int(cs_batch_rejected_at(core, Int32($0))) }
        // Constraints the core installed (possibly rewritten) are held; ones it dropped are not.
        for constraint in batch where hasConstraint(constraint) { constraints.append(constraint) }
        handles = handles.filter { cs_has_constraint(core, $0.value.handle) != 0 }
    }

    /// True when the constraints alone determine this variable (it does not depend on any free variable), so a weak stay on
    /// it could not change the solution. Conservative: false whenever that is not provable.
    public func isDetermined(_ variable: Variable) -> Bool { cs_variable_determined(core, Int32(variable.id)) != 0 }

    // MARK: Results

    public func updateVariables() { cs_update_variables(core) }

    public func value(of variable: Variable) -> Double {
        var out = 0.0
        _ = cs_value_out(core, Int32(variable.id), &out)
        return out
    }

    public func reset() {
        cs_reset(core)
        handles.removeAll()
        constraints.removeAll()
        presolveBatch = nil
        batchRejectedIndices.removeAll()
    }
}
