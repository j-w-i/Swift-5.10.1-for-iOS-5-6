//
//  LegacyLinearSolver.swift
//  LegacyAutoLayout
//
//  The layout solver core is an implementation detail: LegacyLayoutSolver builds the
//  constraint graph and only calls the members of this protocol. The accepted engine is
//  Cassowary; `LEGACY_AUTOLAYOUT_SOLVER=nsis` selects a core backed by the clean-room port
//  of Apple's Foundation-993 incremental simplex (NSISC) instead.
//

import Foundation
import Cassowary

internal protocol LegacyLinearSolver: AnyObject {
    var presolveActive: Bool { get }
    var hasPresolvedVariables: Bool { get }
    func isPresolved(_ variable: Variable) -> Bool
    var presolveBatchCount: Int { get }
    var isCollectingPresolveBatch: Bool { get }
    var batchRejectedIndices: [Int] { get }
    func reserveCapacity(constraintCount: Int, variableCount: Int)
    var variableCount: Int { get }
    var constraintCount: Int { get }
    var density: (rows: Int, cells: Int, maxRow: Int, maxCol: Int) { get }
    func addConstraint(_ constraint: Constraint) throws
    func removeConstraint(_ constraint: Constraint) throws
    func hasConstraint(_ constraint: Constraint) -> Bool
    func updateConstraintConstants(_ updates: [(Constraint, Double)]) throws
    func updateVariables()
    func value(of variable: Variable) -> Double
    func reset()
    func beginPresolveBatch()
    func endPresolveBatch()
}

extension Solver: LegacyLinearSolver {}

internal enum LegacySolverBackend {
    static var selectedName: String {
        guard let raw = getenv("LEGACY_AUTOLAYOUT_SOLVER") else { return "cassowary" }
        return String(cString: raw).lowercased() == "nsis" ? "nsis" : "cassowary"
    }
    static func make() -> LegacyLinearSolver {
        if selectedName == "nsis" {
            // The NSIS backend needs the solver objects' internal identifiers, so it must be compiled into
            // the same module as Cassowary (as the integrated build does). A host parity build that links
            // Cassowary as a separate module cannot construct it; the Cassowary backend is the default.
            #if canImport(UIKit)
            return AppleNSISSolver()
            #else
            return Solver()
            #endif
        }
        return Solver()
    }
}
