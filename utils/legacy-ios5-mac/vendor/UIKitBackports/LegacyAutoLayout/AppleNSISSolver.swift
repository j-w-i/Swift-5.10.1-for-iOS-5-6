//
//  AppleNSISSolver.swift
//  LegacyAutoLayout
//
//  Solver core backed by the clean-room C port of Apple's Foundation-993 incremental
//  simplex engine (NSISC). Every solver object is owned by C; only indices, pointers to
//  the engine, and IEEE-754 bit patterns cross the Swift/C boundary, because the legacy
//  Swift frontend and clang disagree on mixed int/pointer/float argument marshalling
//  (verified on device: a -3787 probe arrived as 213.49).
//
//  Constraint shapes follow the port's own tests of Apple's model:
//    required:            expr + marker == 0
//    optional equality:   expr + marker - ep + en == 0, ep/en >= 0 minimised at priority
//    optional <=:         expr + marker + ep == 0
//    optional >=:         expr + marker - en == 0
//

import Foundation
import CoreGraphics
import Cassowary

@_silgen_name("NSISFacadeEngineCreate") private func f_engine_create() -> UnsafeMutableRawPointer?
@_silgen_name("NSISFacadeEngineDestroy") private func f_engine_destroy(_ h: UnsafeMutableRawPointer)
@_silgen_name("NSISFacadeVarCreate") private func f_var_create(_ h: UnsafeMutableRawPointer, _ r: Int32, _ m: Int32) -> Int32
@_silgen_name("NSISFacadeMarkerCreate") private func f_marker_create(_ h: UnsafeMutableRawPointer, _ i: Int32) -> Int32
@_silgen_name("NSISFacadeAddConstraintBits") private func f_add_constraint(_ h: UnsafeMutableRawPointer, _ marker: Int32, _ vars: UnsafePointer<Int32>, _ coefBits: UnsafePointer<UInt32>, _ n: Int32, _ constantBits: UInt32, _ priorityBits: UInt32) -> Int32
@_silgen_name("NSISFacadeAddObjectiveBits") private func f_add_objective(_ h: UnsafeMutableRawPointer, _ varIndex: Int32, _ priorityBits: UInt32) -> Int32
@_silgen_name("NSISFacadeRemoveConstraintByMarker") private func f_remove(_ h: UnsafeMutableRawPointer, _ marker: Int32) -> Int32
@_silgen_name("NSISFacadeChangeConstantByMarker") private func f_change_constant(_ h: UnsafeMutableRawPointer, _ marker: Int32, _ constantBits: UInt32) -> Int32
@_silgen_name("NSISFacadeOptimize") private func f_optimize(_ h: UnsafeMutableRawPointer)
@_silgen_name("NSISFacadeValueBits") private func f_value_bits(_ h: UnsafeMutableRawPointer, _ i: Int32) -> UInt32
@_silgen_name("NSISFacadeVariableCount") private func f_variable_count(_ h: UnsafeMutableRawPointer) -> Int32
@_silgen_name("NSISFacadeIndexCheck") private func f_index_check() -> Float

internal func legacyNSISFacadeSelfCheck() -> Float { f_index_check() }

/// Probe: one required `x == 10` through the adapter itself.
internal func legacyNSISAdapterProbe() -> Double {
    let solver = AppleNSISSolver()
    let variable = Cassowary.Variable()
    let expression = Cassowary.Expression(variable, 1).plus(Cassowary.Expression(constant: -10))
    let constraint = Constraint(expression, .equal, strength: .required)
    do { try solver.addConstraint(constraint) } catch { return -1 }
    let required = solver.value(of: variable)
    let optionalSolver = AppleNSISSolver()
    let w = Cassowary.Variable()
    let optional = Constraint(Cassowary.Expression(w, 1).plus(Cassowary.Expression(constant: -120)), .equal, strength: .strong)
    do { try optionalSolver.addConstraint(optional) } catch { return -2 }
    return required * 1000 + optionalSolver.value(of: w)
}

internal final class AppleNSISSolver: LegacyLinearSolver {
    private static var reportedFailure = false
    private(set) static var instanceCount = 0
    internal static var strengthHistogram: [String: Int] = [:]
    private var engine: UnsafeMutableRawPointer
    /// Cassowary variable id -> NSIS variable index.
    private var variableIndices: [Int: Int32] = [:]
    /// Marker index per installed constraint (object identity).
    private var markers: [ObjectIdentifier: (constraint: Constraint, marker: Int32)] = [:]
    private var dirty = true

    internal init() {
        guard let engine = f_engine_create() else {
            fatalError("NSIS engine unavailable")
        }
        self.engine = engine
        AppleNSISSolver.instanceCount += 1
    }
    deinit { f_engine_destroy(engine) }

    // MARK: Cassowary-core compatibility surface (no presolve support)

    internal var presolveActive: Bool { false }
    internal var hasPresolvedVariables: Bool { false }
    internal func isPresolved(_ variable: Variable) -> Bool { false }
    internal var presolveBatchCount: Int { 0 }
    internal var isCollectingPresolveBatch: Bool { false }
    internal var batchRejectedIndices: [Int] { [] }
    internal func reserveCapacity(constraintCount: Int, variableCount: Int) {}
    internal func beginPresolveBatch() {}
    internal func endPresolveBatch() {}
    internal var variableCount: Int { Int(f_variable_count(engine)) }
    internal var constraintCount: Int { markers.count }
    internal var density: (rows: Int, cells: Int, maxRow: Int, maxCol: Int) { (0, 0, 0, 0) }

    private func index(for id: Int) -> Int32 {
        if let existing = variableIndices[id] { return existing }
        let index = f_var_create(engine, 0 /* NSIS_UNRESTRICTED */, 0)
        variableIndices[id] = index
        return index
    }

    private func errorVariable() -> Int32 {
        f_var_create(engine, 1 /* NSIS_NONNEG */, 1 /* minimised */)
    }

    private func priorityBits(_ strength: Strength) -> UInt32 {
        // Cassowary scales a priority p as (p/1000)*1e6; Apple priorities are p.
        let value = strength.value / 1000.0
        return Float(value).bitPattern
    }

    internal func addConstraint(_ constraint: Constraint) throws {
        let id = ObjectIdentifier(constraint)
        guard markers[id] == nil else { throw SolverError.duplicateConstraint }
        let key = constraint.strength == .required ? "required" : String(format: "%.1f", constraint.strength.value / 1000.0)
        AppleNSISSolver.strengthHistogram[key, default: 0] += 1
        let expression = constraint.expression
        var vars: [Int32] = []
        var coefficients: [UInt32] = []
        vars.reserveCapacity(expression.terms.count + 3)
        coefficients.reserveCapacity(expression.terms.count + 3)
        for term in expression.terms {
            vars.append(index(for: term.variable.id))
            coefficients.append(Float(term.coefficient).bitPattern)
        }
        let marker = f_var_create(engine, 2 /* NSIS_ZERO */, 0)
        guard f_marker_create(engine, marker) != 0 else { throw SolverError.internalInconsistency("marker creation failed") }
        if constraint.strength != .required {
            let priority = priorityBits(constraint.strength)
            switch constraint.op {
            case .equal:
                let positive = errorVariable(), negative = errorVariable()
                _ = f_add_objective(engine, positive, priority)
                _ = f_add_objective(engine, negative, priority)
                vars.append(positive); coefficients.append(Float(-1).bitPattern)
                vars.append(negative); coefficients.append(Float(1).bitPattern)
            case .lessThanOrEqual:
                // expr <= 0 preferred: expr - violation + slack = 0, both non-negative, and only
                // the violation is penalised. Without the slack the row is a hard upper bound
                // (expr can never be positive), so a higher-priority desire could not win.
                let positive = errorVariable()
                _ = f_add_objective(engine, positive, priority)
                let slack = f_var_create(engine, 1 /* NSIS_NONNEG */, 0)
                vars.append(positive); coefficients.append(Float(-1).bitPattern)
                vars.append(slack); coefficients.append(Float(1).bitPattern)
            case .greaterThanOrEqual:
                let negative = errorVariable()
                _ = f_add_objective(engine, negative, priority)
                let slack = f_var_create(engine, 1 /* NSIS_NONNEG */, 0)
                vars.append(negative); coefficients.append(Float(1).bitPattern)
                vars.append(slack); coefficients.append(Float(-1).bitPattern)
            }
        }
        else if constraint.op != .equal {
            // A required inequality is not an equality: give the row a non-negative slack
            // variable so it can be violated in one direction only. Modelling it as an
            // equality pinned every implicit "size >= 0" row to zero, which hid all
            // content-driven sizes.
            let slack = f_var_create(engine, 1 /* NSIS_NONNEG */, 0)
            vars.append(slack)
            coefficients.append(constraint.op == .lessThanOrEqual ? Float(1).bitPattern : Float(-1).bitPattern)
        }
        // Every constraint row carries its marker, exactly as the port's tests do.
        vars.append(marker); coefficients.append(Float(1).bitPattern)
        let added: Int32
        if vars.isEmpty {
            added = f_add_constraint(engine, marker, [], [], 0,
                                     Float(expression.constant).bitPattern, priorityBits(constraint.strength))
        } else {
            added = vars.withUnsafeBufferPointer { v in
                coefficients.withUnsafeBufferPointer { c in
                    f_add_constraint(engine, marker, v.baseAddress!, c.baseAddress!, Int32(v.count),
                                     Float(expression.constant).bitPattern, priorityBits(constraint.strength))
                }
            }
        }
        guard added != 0 else {
            f_remove(engine, marker)
            if !AppleNSISSolver.reportedFailure {
                AppleNSISSolver.reportedFailure = true
                FileHandle.standardError.write(Data("NSIS: add rejected terms=\(vars.count) const=\(expression.constant) strength=\(constraint.strength)\n".utf8))
            }
            throw SolverError.unsatisfiableConstraint
        }
        markers[id] = (constraint, marker)
        dirty = true
    }

    internal func removeConstraint(_ constraint: Constraint) throws {
        let id = ObjectIdentifier(constraint)
        guard let entry = markers[id] else { throw SolverError.unknownConstraint }
        _ = f_remove(engine, entry.marker)
        markers.removeValue(forKey: id)
        dirty = true
    }

    internal func hasConstraint(_ constraint: Constraint) -> Bool {
        markers[ObjectIdentifier(constraint)] != nil
    }

    internal func updateConstraintConstants(_ updates: [(Constraint, Double)]) throws {
        for (constraint, constant) in updates {
            guard let entry = markers[ObjectIdentifier(constraint)] else { throw SolverError.unknownConstraint }
            _ = f_change_constant(engine, entry.marker, Float(constant).bitPattern)
        }
        dirty = true
    }

    internal func updateVariables() { if dirty { f_optimize(engine); dirty = false } }

    private static var reportedUnknown = 0
    internal func value(of variable: Variable) -> Double {
        if dirty { f_optimize(engine); dirty = false }
        guard let index = variableIndices[variable.id] else {
            if AppleNSISSolver.reportedUnknown < 3 {
                AppleNSISSolver.reportedUnknown += 1
                FileHandle.standardError.write(Data("NSIS: unknown var id=\(variable.id) constraints=\(markers.count)\n".utf8))
            }
            return 0
        }
        let value = Double(Float(bitPattern: f_value_bits(engine, index)))
        if AppleNSISSolver.reportedUnknown < 6 && AppleNSISSolver.reportedUnknown >= 3 {
            AppleNSISSolver.reportedUnknown += 1
        }
        return value
    }

    internal func reset() {
        f_engine_destroy(engine)
        guard let created = f_engine_create() else { fatalError("NSIS engine unavailable") }
        engine = created
        variableIndices.removeAll()
        markers.removeAll()
        dirty = true
    }
}

internal func legacyNSISMixedProbe() -> String {
    let solver = AppleNSISSolver()
    let a = Cassowary.Variable(), b = Cassowary.Variable()
    func required(_ e: Cassowary.Expression) { _ = try? solver.addConstraint(Constraint(e, .equal, strength: .required)) }
    required(Cassowary.Expression(b, 1).plus(Cassowary.Expression(constant: -50)))
    required(Cassowary.Expression(a, 1).minus(Cassowary.Expression(b, 1)))
    _ = try? solver.addConstraint(Constraint(Cassowary.Expression(a, 1).plus(Cassowary.Expression(constant: -120)), .equal, strength: .strong))
    _ = try? solver.addConstraint(Constraint(Cassowary.Expression(a, 1).plus(Cassowary.Expression(constant: -80)), .equal, strength: .medium))
    return "a=\(solver.value(of: a)) b=\(solver.value(of: b))"
}
