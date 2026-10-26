//
//  Expression.swift
//  Cassowary
//
//  A linear expression: `constant + sum(coefficient_i * variable_i)`.
//

import Foundation

/// An immutable linear expression.
///
/// Expressions are value-like: `plus`, `minus`, `times` and `divide` return new
/// expressions and never mutate the receiver. The constant is the only mutable
/// component, mirroring the reference implementations where a row keeps track of
/// its constant separately.
///
/// Implementation note: terms live in a plain array and are merged with a linear
/// scan (expressions built by the layout engine have a handful of terms), instead
/// of an array plus a per-variable index dictionary. The layout build path creates
/// many short expressions per constraint; the dictionary was pure allocation and
/// hashing overhead. Term order (first-occurrence order) and coefficient merging
/// are identical to the previous implementation.
public final class Expression: CustomStringConvertible {

    /// The terms of the expression, in insertion order (deterministic).
    public private(set) var terms: [Term]

    /// The constant part of the expression.
    public var constant: Double

    public init(constant: Double = 0.0) {
        self.constant = constant
        self.terms = []
    }

    public init(_ term: Term) {
        self.constant = 0.0
        self.terms = [term]
    }

    public init(_ variable: Variable, _ coefficient: Double = 1.0) {
        self.constant = 0.0
        self.terms = [Term(variable, coefficient)]
    }

    /// Whether the expression has no variable terms.
    public var isConstant: Bool {
        terms.isEmpty
    }

    /// Returns a new expression equal to `self + other`.
    public func plus(_ other: Expression) -> Expression {
        let result = Expression(constant: constant + other.constant)
        for term in terms {
            result.add(term, merging: true)
        }
        for term in other.terms {
            result.add(term, merging: true)
        }
        return result
    }

    /// Returns a new expression equal to `self - other`.
    public func minus(_ other: Expression) -> Expression {
        plus(other.times(-1.0))
    }

    /// Returns a new expression where every coefficient (including the constant) is scaled.
    public func times(_ coefficient: Double) -> Expression {
        let result = Expression(constant: constant * coefficient)
        for term in terms {
            result.add(Term(term.variable, term.coefficient * coefficient), merging: true)
        }
        return result
    }

    /// Returns a new expression where every coefficient (including the constant) is divided.
    public func divide(by coefficient: Double) -> Expression {
        times(1.0 / coefficient)
    }

    // MARK: Operators

    public static func + (lhs: Expression, rhs: Expression) -> Expression { lhs.plus(rhs) }
    public static func - (lhs: Expression, rhs: Expression) -> Expression { lhs.minus(rhs) }
    public static func * (lhs: Expression, rhs: Double) -> Expression { lhs.times(rhs) }
    public static func * (lhs: Double, rhs: Expression) -> Expression { rhs.times(lhs) }
    public static func / (lhs: Expression, rhs: Double) -> Expression { lhs.divide(by: rhs) }
    public static prefix func - (expression: Expression) -> Expression { expression.times(-1.0) }

    // MARK: Internal

    /// Adds a term, merging coefficients for an already present variable.
    /// Internal so the solver can reuse expressions while building its rows.
    internal func add(_ term: Term, merging: Bool) {
        if merging {
            for index in terms.indices where terms[index].variable === term.variable {
                let coefficient = terms[index].coefficient + term.coefficient
                if coefficient == 0.0 {
                    terms.remove(at: index)
                } else {
                    terms[index] = Term(term.variable, coefficient)
                }
                return
            }
            if term.coefficient != 0.0 {
                terms.append(term)
            }
        } else {
            terms.append(term)
        }
    }

    /// The coefficient of `variable` in this expression, or `0` when absent.
    public func coefficient(of variable: Variable) -> Double {
        for term in terms where term.variable === variable {
            return term.coefficient
        }
        return 0.0
    }

    public var description: String {
        var parts: [String] = []
        for term in terms {
            parts.append(term.description)
        }
        if constant != 0.0 || parts.isEmpty {
            parts.append("\(constant)")
        }
        return parts.joined(separator: " + ")
    }
}
