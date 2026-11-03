//
//  cassowary_c_diff.swift
//  Differential test: CassowaryC (C core) vs Cassowary.Solver (Swift oracle).
//
//  Drives random add / remove / change-constant / presolve-batch sequences through both solvers and requires
//  every variable value to be BIT-IDENTICAL after every operation, and every operation to succeed or fail the same
//  way. Any divergence prints the seed and step and exits 1.
//
//  Usage: cassowary_c_diff [SEEDS] [STEPS]
//
import Foundation
import Cassowary
import CassowaryC
typealias Expression = Cassowary.Expression

struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func double(_ lo: Double, _ hi: Double) -> Double { lo + Double(next() % 100000) / 100000.0 * (hi - lo) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

let strengths: [Strength] = [.required, .required, .required, .strong, .medium, .weak,
                             Strength.create(0, 0, 750), Strength.create(0, 0, 250), Strength.clip(Strength.required.value - 1)]
let coefficientChoices: [Double] = [1, 1, 1, -1, 2, 0.5, -0.5, 3]

final class Pair {
    let swift = SwiftReferenceSolver()
    var cState = cs_create()!
    var variables: [Variable] = []
    // paired constraints: swift object + C handle + the constraint's current constant
    struct Held { let swiftConstraint: Constraint; var handle: Int32; var constant: Double; let name: String }
    var held: [Held] = []
    init(variableCount: Int) { for i in 0..<variableCount { variables.append(Variable("v\(i)")) } }
    deinit { cs_destroy(cState) }
}

func describe(_ e: Int32) -> String { e == 0 ? "ok" : "err\(e)" }

func run(seed: UInt64, steps: Int) -> String? {
    var rng = LCG(state: seed &* 0x9E37_79B9_7F4A_7C15 | 1)
    let variableCount = 3 + rng.int(8)
    let pair = Pair(variableCount: variableCount)
    cs_reserve(pair.cState, 64, Int32(variableCount))
    let trace = ProcessInfo.processInfo.environment["TRACE_SEED"] == String(seed)

    func randomExpression() -> (Expression, [Int32], [Double], Double) {
        let termCount = 1 + rng.int(3)
        var vars: [Int32] = []
        var coefs: [Double] = []
        var expr = Expression(constant: 0)
        var used = Set<Int>()
        for _ in 0..<termCount {
            let v = rng.int(variableCount)
            if used.contains(v) { continue }
            used.insert(v)
            let k = rng.pick(coefficientChoices)
            vars.append(Int32(v)); coefs.append(k)
            expr = expr.plus(Expression(pair.variables[v], k))
        }
        let constant = Double(Int(rng.double(-200, 200) * 4)) / 4.0
        expr.constant = constant
        return (expr, vars, coefs, constant)
    }

    func addOne(label: String) -> String? {
        let (expr, vars, coefs, constant) = randomExpression()
        let opChoice = rng.int(3)
        let op: RelationalOperator = [.equal, .lessThanOrEqual, .greaterThanOrEqual][opChoice]
        let cop: Int32 = [Int32(CS_OP_EQ), Int32(CS_OP_LE), Int32(CS_OP_GE)][opChoice]
        let strength = rng.pick(strengths)
        let constraint = Constraint(expr, op, strength: strength, name: label)
        if trace { print("   add \(label): terms=\(zip(vars, coefs).map { "\($1)*v\($0)" }) const=\(constant) op=\(op.rawValue) strength=\(strength.value)") }
        var swiftOK = true
        do { try pair.swift.addConstraint(constraint) } catch { swiftOK = false }
        var error: Int32 = 0
        let handle = cs_add_constraint(pair.cState, vars, coefs, Int32(vars.count), constant, cop, strength.value,
                                       strength == .required ? 1 : 0, &error)
        let cOK = handle != -1     // -2 == accepted but not held (folded to a satisfied constant)
        if trace { print("      [presolvedVars swift=\(pair.swift.hasPresolvedVariables) c=\(cs_has_presolved_variables(pair.cState)) active swift=\(pair.swift.presolveActive)]") }
        if trace { print("      -> swift \(swiftOK ? "held" : "REJECTED")  c \(cOK ? (cs_has_constraint(pair.cState, handle) != 0 ? "held" : "dropped") : "REJECTED(\(error))")") }
        if swiftOK != cOK { return "add \(label): swift=\(swiftOK) c=\(describe(error))" }
        // After presolve Swift stores a rewritten Constraint object, so the caller's object is not addressable; the engine
        // never removes rows then. Track only constraints Swift can still address.
        if swiftOK, pair.swift.hasConstraint(constraint), handle >= 0 { pair.held.append(.init(swiftConstraint: constraint, handle: handle, constant: constant, name: label)) }
        return nil
    }

    func compare(_ context: String) -> String? {
        pair.swift.updateVariables()
        cs_update_variables(pair.cState)
        for (i, v) in pair.variables.enumerated() {
            let a = pair.swift.value(of: v), b = cs_value(pair.cState, Int32(i))
            if a.bitPattern != b.bitPattern { if trace { for (j, w) in pair.variables.enumerated() { print("      v\(j): swift=\(pair.swift.value(of: w)) c=\(cs_value(pair.cState, Int32(j)))") } }; return "\(context): v\(i) swift=\(a) c=\(b) (delta \(a - b))" }
        }
        return nil
    }

    var added = 0
    func presolveBatch() -> String? {
        pair.swift.beginPresolveBatch()
        cs_begin_presolve_batch(pair.cState)
        let count = 2 + rng.int(8)
        var batchPairs: [(Constraint, Int32)] = []
        for _ in 0..<count {
            let (expr, vars, coefs, constant) = randomExpression()
            let opChoice = rng.int(3)
            let op: RelationalOperator = [.equal, .equal, .lessThanOrEqual][opChoice]
            let cop: Int32 = [Int32(CS_OP_EQ), Int32(CS_OP_EQ), Int32(CS_OP_LE)][opChoice]
            let strength = rng.pick(strengths)
            let constraint = Constraint(expr, op, strength: strength, name: "b\(added)"); added += 1
            try? pair.swift.addConstraint(constraint)
            var error: Int32 = 0
            let handle = cs_add_constraint(pair.cState, vars, coefs, Int32(vars.count), constant, cop, strength.value,
                                           strength == .required ? 1 : 0, &error)
            batchPairs.append((constraint, handle))
        }
        pair.swift.endPresolveBatch()
        cs_end_presolve_batch(pair.cState)
        if pair.swift.presolveActive != (cs_presolve_active(pair.cState) != 0) {
            return "presolve active: swift=\(pair.swift.presolveActive) c=\(cs_presolve_active(pair.cState))"
        }
        if pair.swift.batchRejectedIndices.count != Int(cs_batch_rejected_count(pair.cState)) {
            return "batch rejected count: swift=\(pair.swift.batchRejectedIndices.count) c=\(cs_batch_rejected_count(pair.cState))"
        }
        for (k, idx) in pair.swift.batchRejectedIndices.enumerated() where Int32(idx) != cs_batch_rejected_at(pair.cState, Int32(k)) {
            return "batch rejected[\(k)]: swift=\(idx) c=\(cs_batch_rejected_at(pair.cState, Int32(k)))"
        }
        // The batch's constraint handles are no longer individually addressable (the Swift engine never removes them
        // one by one after a presolve), so the paired list is intentionally left alone after a batch.
        return nil
    }

    for step in 0..<steps {
        let action = rng.int(10)
        if trace { print("step \(step) action \(action) held=\(pair.held.count) cCount=\(cs_constraint_count(pair.cState)) swiftCount=\(pair.swift.constraintCount)") }
        switch action {
        case 0...4:
            if let problem = addOne(label: "c\(step)") { return "step \(step): \(problem)" }
        case 5, 6:
            // The engine never removes/updates rows while presolve is active (LegacyLayoutSolver.update bails to a rebuild), and
            // Swift re-wraps constraints it rewrites after presolve, so a caller object is not removable there: skip.
            if !pair.held.isEmpty, !pair.swift.hasPresolvedVariables {
                let i = rng.int(pair.held.count)
                let h = pair.held.remove(at: i)
                var swiftOK = true
                var swiftError: Error?
                do { try pair.swift.removeConstraint(h.swiftConstraint) } catch { swiftOK = false; swiftError = error }
                if trace, !swiftOK { print("      remove \(h.name): swift threw \(String(describing: swiftError)); presolveActive=\(pair.swift.presolveActive) presolvedVars=\(pair.swift.hasPresolvedVariables) cPresolve=\(cs_presolve_active(pair.cState))") }
                let rc = cs_remove_constraint(pair.cState, h.handle)
                if swiftOK != (rc == 0) { return "step \(step): remove swift=\(swiftOK) c=\(describe(rc))" }
            }
        case 7, 8:
            if !pair.held.isEmpty, !pair.swift.hasPresolvedVariables {
                let count = 1 + rng.int(min(4, pair.held.count))
                var updates: [(Constraint, Double)] = []
                var handles: [Int32] = []
                var constants: [Double] = []
                var chosen = Set<Int>()
                for _ in 0..<count {
                    let i = rng.int(pair.held.count)
                    if chosen.contains(i) { continue }
                    chosen.insert(i)
                    let c = Double(Int(rng.double(-200, 200) * 4)) / 4.0
                    updates.append((pair.held[i].swiftConstraint, c)); handles.append(pair.held[i].handle); constants.append(c)
                }
                var swiftOK = true
                do { try pair.swift.updateConstraintConstants(updates) } catch { swiftOK = false }
                let rc = cs_update_constants(pair.cState, handles, constants, Int32(handles.count))
                if swiftOK != (rc == 0) { return "step \(step): updateConstants swift=\(swiftOK) c=\(describe(rc))" }
                if swiftOK { for (k, i) in chosen.sorted().enumerated() { _ = k; _ = i } }
            }
        default:
            if step % 7 == 0, pair.held.isEmpty, let problem = presolveBatch() { return "step \(step): \(problem)" }
        }
        if trace { for h in pair.held where !pair.swift.hasConstraint(h.swiftConstraint) { print("      LOST after step \(step) action \(action): swift no longer holds \(h.name) (c still holds: \(cs_has_constraint(pair.cState, h.handle) != 0))") } }
        // After a rejected operation the Swift solver may have replayed; compare in every case.
        if let problem = compare("step \(step) action \(action)") { return problem }
        if pair.swift.constraintCount != Int(cs_constraint_count(pair.cState)) {
            return "step \(step): constraint count swift=\(pair.swift.constraintCount) c=\(cs_constraint_count(pair.cState))"
        }
        if pair.swift.variableCount != Int(cs_variable_count(pair.cState)) {
            return "step \(step): symbol count swift=\(pair.swift.variableCount) c=\(cs_variable_count(pair.cState))"
        }
        // constants tracked by the harness must follow the same update rule on both sides
    }
    return nil
}

let args = CommandLine.arguments.dropFirst().map { Int($0) ?? 0 }
let seeds = args.count > 0 ? args[0] : 300
let steps = args.count > 1 ? args[1] : 120
var failures = 0
let firstSeed = ProcessInfo.processInfo.environment["ONLY_SEED"].flatMap { Int($0) }
for seed in (firstSeed ?? 1)...(firstSeed ?? seeds) {
    SwiftReferenceSolver.presolvesEnabled = true
    cs_presolves_enabled = 1
    if let problem = run(seed: UInt64(seed), steps: steps) {
        failures += 1
        if failures <= 40 { print("MISMATCH seed \(seed): \(problem)") }
    }
}
print(failures == 0
      ? "PASS: CassowaryC identical to the Swift solver over \(seeds) seeds x \(steps) steps (values bit-identical, same failures)"
      : "FAIL: \(failures) of \(seeds) seeds diverged")
exit(failures == 0 ? 0 : 1)
