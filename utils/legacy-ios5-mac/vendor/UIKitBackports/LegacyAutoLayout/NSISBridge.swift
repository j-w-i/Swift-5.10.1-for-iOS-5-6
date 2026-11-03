//
//  NSISBridge.swift
//  LegacyAutoLayout
//
//  Swift bridge to the clean-room C port of Apple's incremental-simplex engine
//  (Foundation-993 `NSISEngine`, vendored under NSISC/). This file only exposes the
//  engine; the layout solver backend is selected by
//  `LEGACY_AUTOLAYOUT_SOLVER=nsis` in a later change, so the accepted Cassowary
//  path stays the default and unmodified until the port is validated.
//

import Foundation
import CoreGraphics

// Opaque engine/variable handles owned by the C port.
private typealias NSISEngineRef = OpaquePointer
private typealias NSISVarRef = OpaquePointer

@_silgen_name("NSISFacadeSelfCheck") private func nsis_facade_self_check() -> Float
@_silgen_name("NSISFacadeEchoFloat") private func nsis_facade_echo(_ v: Float) -> Float
@_silgen_name("NSISFacadeEngineCreate") private func f_engine_create() -> UnsafeMutableRawPointer?
@_silgen_name("NSISFacadeEngineDestroy") private func f_engine_destroy(_ h: UnsafeMutableRawPointer)
@_silgen_name("NSISFacadeVarCreate") private func f_var_create(_ h: UnsafeMutableRawPointer, _ r: Int32, _ m: Int32) -> Int32
@_silgen_name("NSISFacadeAddConstraint") private func f_add_constraint(_ h: UnsafeMutableRawPointer, _ marker: Int32, _ vars: UnsafePointer<Int32>, _ coefs: UnsafePointer<Float>, _ n: Int32, _ constant: Float, _ priority: Float) -> Int32
@_silgen_name("NSISFacadeOptimize") private func f_optimize(_ h: UnsafeMutableRawPointer)
@_silgen_name("NSISFacadeValue") private func f_value(_ h: UnsafeMutableRawPointer, _ i: Int32) -> Float
@_silgen_name("NSISFacadeIndexCheck") private func f_index_check() -> Float
@_silgen_name("NSISFacadeAddConstraintBits") private func f_add_constraint_bits(_ h: UnsafeMutableRawPointer, _ marker: Int32, _ vars: UnsafePointer<Int32>, _ coefBits: UnsafePointer<UInt32>, _ n: Int32, _ constantBits: UInt32, _ priorityBits: UInt32) -> Int32
@_silgen_name("NSISFacadeValueBits") private func f_value_bits(_ h: UnsafeMutableRawPointer, _ i: Int32) -> UInt32
@_silgen_name("NSISFacadeArgsEcho") private func f_args_echo(_ h: UnsafeMutableRawPointer?, _ marker: Int32, _ c: UnsafePointer<Float>, _ n: Int32, _ k: Float, _ p: Float) -> Float
@_silgen_name("NSISFacadeExprNew") private func f_expr_new() -> OpaquePointer?
@_silgen_name("NSISFacadeExprAddTerm") private func f_add_term(_ e: OpaquePointer, _ v: OpaquePointer, _ c: Float)
@_silgen_name("NSISFacadeExprAddConstant") private func f_add_const(_ e: OpaquePointer, _ c: Float) -> Float
@_silgen_name("NSISFacadeExprCoefficient") private func f_coef(_ e: OpaquePointer, _ v: OpaquePointer) -> Float
@_silgen_name("NSISFacadeExprConstant") private func f_const(_ e: OpaquePointer) -> Float
@_silgen_name("nsis_engine_new") private func nsis_engine_new() -> NSISEngineRef?
@_silgen_name("nsis_engine_free") private func nsis_engine_free(_ e: NSISEngineRef)
@_silgen_name("nsis_var_new") private func nsis_var_new(_ name: UnsafePointer<CChar>?, _ restriction: Int32, _ minimized: Bool) -> NSISVarRef?
@_silgen_name("nsis_marker_new") private func nsis_marker_new(_ constraint: UnsafeMutableRawPointer?, _ restriction: Int32, _ minimized: Bool, _ allowedMagnitude: Float) -> NSISVarRef?
@_silgen_name("nsis_var_free") private func nsis_var_free(_ v: NSISVarRef)
@_silgen_name("nsis_expr_new") private func nsis_expr_new() -> NSISExprRef?
private typealias NSISExprRef = OpaquePointer
@_silgen_name("nsis_expr_add_term") private func nsis_expr_add_term(_ e: NSISExprRef, _ v: NSISVarRef, _ coefficient: Float)
@_silgen_name("nsis_expr_add_constant") private func nsis_expr_add_constant(_ e: NSISExprRef, _ c: Float) -> Float
@_silgen_name("nsis_expr_free") private func nsis_expr_free(_ e: NSISExprRef)
@_silgen_name("nsis_expr_constant") private func nsis_expr_constant(_ e: NSISExprRef) -> Float
@_silgen_name("nsis_expr_coefficient") private func nsis_expr_coefficient(_ e: NSISExprRef, _ v: NSISVarRef) -> Float
@_silgen_name("nsis_engine_try_add_constraint") private func nsis_engine_try_add_constraint(
    _ e: NSISEngineRef, _ marker: NSISVarRef, _ expr: NSISExprRef,
    _ integralizationAdjustment: Float, _ mutuallyExclusive: UnsafeMutableRawPointer?) -> Bool
@_silgen_name("nsis_engine_optimize") private func nsis_engine_optimize(_ e: NSISEngineRef)
@_silgen_name("nsis_engine_value") private func nsis_engine_value(_ e: NSISEngineRef, _ v: NSISVarRef) -> Float

/// Availability/diagnostics for the Apple-engine backend.
internal enum LegacyNSISBackend {
    /// `LEGACY_AUTOLAYOUT_SOLVER=nsis` requests Apple's engine; the accepted
    /// Cassowary path remains the default.
    internal static var isRequested: Bool {
        guard let raw = getenv("LEGACY_AUTOLAYOUT_SOLVER") else { return false }
        return String(cString: raw).lowercased() == "nsis"
    }

    /// Solves `2x = 10` and returns the value, proving the port is linked and runs on
    /// this OS. Returns nil when the engine cannot be created.
    internal static func debugTrace() -> String {
        guard let engine = nsis_engine_new() else { return "engine=nil" }
        defer { nsis_engine_free(engine) }
        guard let x = nsis_var_new("x", 0, false),
              let marker = nsis_marker_new(UnsafeMutableRawPointer(bitPattern: 1), 2, false, -1),
              let expr = nsis_expr_new() else { return "alloc=nil" }
        nsis_expr_add_term(expr, x, 1)
        _ = nsis_expr_add_constant(expr, -5)
        nsis_expr_add_term(expr, marker, 1)
        let fe = f_expr_new()!
        f_add_term(fe, x, 1)
        _ = f_add_const(fe, -5)
        f_add_term(fe, marker, 1)
        let fx = f_coef(fe, x)
        let fc = f_const(fe)
        var argsEcho: Float = 0
        do {
            var c: [Float] = [1]
            argsEcho = f_args_echo(nil, 3, &c, 2, -5, 1000)
        }
        var idxCheck: Float = -3
        if let h = f_engine_create() {
            let ix = f_var_create(h, 0, 0)
            let im = f_var_create(h, 2, 0)
            var tv: [Int32] = [ix, im]; var tc: [UInt32] = [Float(1).bitPattern, Float(1).bitPattern]
            let ok = f_add_constraint_bits(h, im, &tv, &tc, 2, Float(-5).bitPattern, Float(1000).bitPattern)
            f_optimize(h)
            idxCheck = ok != 0 ? Float(bitPattern: f_value_bits(h, ix)) : -2
            f_engine_destroy(h)
        }
        let cx = nsis_expr_coefficient(expr, x)
        let cm = nsis_expr_coefficient(expr, marker)
        let cc = nsis_expr_constant(expr)
        let added = nsis_engine_try_add_constraint(engine, marker, expr, 0, nil)
        nsis_engine_optimize(engine)
        let value = nsis_engine_value(engine, x)
        nsis_expr_free(expr); nsis_var_free(x); nsis_var_free(marker)
        return "argsEcho=\(argsEcho) idx=\(idxCheck) idxCheck=\(f_index_check()) facadeExpr=\(fx)/\(fc) cx=\(cx) cm=\(cm) cc=\(cc) add=\(added) value=\(value) facade=\(nsis_facade_self_check()) echo=\(nsis_facade_echo(2.5))"
    }

    internal static func selfCheckValue() -> Float? {
        guard let engine = nsis_engine_new() else { return nil }
        defer { nsis_engine_free(engine) }
        guard let x = nsis_var_new("x", 0 /* NSIS_UNRESTRICTED */, false),
              let marker = nsis_marker_new(UnsafeMutableRawPointer(bitPattern: 1), 2 /* NSIS_ZERO */, false, -1 /* unbounded */),
              let expr = nsis_expr_new() else { return nil }
        defer { nsis_var_free(x) }
        nsis_expr_add_term(expr, x, 1)
        nsis_expr_add_constant(expr, -5)
        nsis_expr_add_term(expr, marker, 1)
        guard nsis_engine_try_add_constraint(engine, marker, expr, 0, nil) else {
            nsis_expr_free(expr)
            return nil
        }
        nsis_engine_optimize(engine)
        let value = nsis_engine_value(engine, x)
        nsis_expr_free(expr)
        return value
    }
}

/// C entry point for the device diagnostic bridge (dlsym) proving the port runs on this OS.
@_cdecl("LegacyNSISSelfCheckValue")
public func LegacyNSISSelfCheckValue() -> Float {
    return LegacyNSISBackend.selfCheckValue() ?? -1
}

@_cdecl("LegacyNSISDebugTrace")
public func LegacyNSISDebugTrace() -> UnsafePointer<CChar>? {
    return UnsafePointer(strdup(LegacyNSISBackend.debugTrace()))
}
