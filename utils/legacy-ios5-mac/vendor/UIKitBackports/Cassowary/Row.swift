//
//  Row.swift
//  Cassowary
//
//  A sparse row of the Cassowary simplex tableau.
//
//  Ported from the reference `kiwi` implementation:
//    Copyright (c) 2013-2026, Nucleic Development Team.
//    Distributed under the terms of the Modified BSD License.
//    https://github.com/nucleic/kiwi (kiwi/row.h)
//
//  The Cassowary algorithm was created by Greg Badros and Alan Borning at the
//  University of Washington (https://constraints.cs.washington.edu/cassowary/).
//

import Foundation

/// The numerical tolerance used throughout the solver, matching the reference
/// `kiwi` implementation (`1e-8`). Values whose magnitude is below the
/// tolerance are treated as zero.
internal func nearZero(_ value: Double) -> Bool {
    let epsilon = 1.0e-8
    return value < 0.0 ? -value < epsilon : value < epsilon
}

/// A sparse row of the simplex tableau: `constant + sum(cell * symbol) == 0`.
///
/// Rows have value semantics. The solver uses shallow snapshots of its tableau
/// to roll a failed `addConstraint` back; Swift's copy-on-write arrays make
/// those snapshots cheap and let the rows be restored exactly.
///
/// Implementation note: the coefficients live in two parallel arrays (symbols
/// sorted by symbol id + coefficients), not in a dictionary. Tableau rows are
/// short (usually a handful of terms), so binary search over a sorted array is
/// cheaper than hashing on every pivot, and merging two rows during
/// substitution is a linear merge instead of per-symbol dictionary inserts.
internal struct Row {

    /// The row's symbols, sorted by symbol id.
    private var symbolStorage: [Symbol]

    /// The coefficients, parallel to `symbolStorage`.
    private var coefficientStorage: [Double]

    /// The constant term of the row.
    internal private(set) var constant: Double

    internal init(constant: Double = 0.0) {
        self.symbolStorage = []
        self.coefficientStorage = []
        // Rows are built term-by-term; the typical row has a handful of cells.
        // Reserving avoids several array growths per constraint build.
        symbolStorage.reserveCapacity(8)
        coefficientStorage.reserveCapacity(8)
        self.constant = constant
    }

    /// Whether the row contains no variable terms.
    internal var isEmpty: Bool {
        symbolStorage.isEmpty
    }

    /// The number of non-zero coefficients in the row.
    internal var cellCount: Int {
        symbolStorage.count
    }

    /// The symbols with a non-zero coefficient, sorted by symbol id.
    internal var symbols: [Symbol] {
        symbolStorage
    }

    /// The coefficient of `symbol`, or `0` when the symbol is absent.
    internal func coefficient(for symbol: Symbol) -> Double {
        guard let index = index(of: symbol) else { return 0.0 }
        return coefficientStorage[index]
    }

    /// Adds `value` to the constant term and returns the new constant.
    @discardableResult
    internal mutating func add(_ value: Double) -> Double {
        constant += value
        return constant
    }

    /// Inserts `coefficient * symbol` into the row.
    ///
    /// If the symbol is already present its coefficient is accumulated. If the
    /// resulting coefficient is (close to) zero the symbol is removed, keeping
    /// the row sparse.
    internal mutating func insert(_ symbol: Symbol, _ coefficient: Double = 1.0) {
        if let index = index(of: symbol) {
            let value = coefficientStorage[index] + coefficient
            if nearZero(value) {
                symbolStorage.remove(at: index)
                coefficientStorage.remove(at: index)
            } else {
                coefficientStorage[index] = value
            }
            return
        }
        guard !nearZero(coefficient) else { return }
        let index = insertionIndex(for: symbol)
        symbolStorage.insert(symbol, at: index)
        coefficientStorage.insert(coefficient, at: index)
    }

    /// Inserts `coefficient * other` into this row.
    ///
    /// A linear merge of two symbol-sorted rows: the result is independent of
    /// iteration order, and no per-term dictionary hashing is involved.
    internal mutating func insert(_ other: Row, _ coefficient: Double = 1.0) {
        constant += other.constant * coefficient
        guard !other.symbolStorage.isEmpty else { return }
        var mergedSymbols: [Symbol] = []
        var mergedCoefficients: [Double] = []
        mergedSymbols.reserveCapacity(symbolStorage.count + other.symbolStorage.count)
        mergedCoefficients.reserveCapacity(symbolStorage.count + other.symbolStorage.count)
        var left = 0
        var right = 0
        while left < symbolStorage.count || right < other.symbolStorage.count {
            if right >= other.symbolStorage.count ||
                (left < symbolStorage.count && symbolStorage[left].id < other.symbolStorage[right].id) {
                mergedSymbols.append(symbolStorage[left])
                mergedCoefficients.append(coefficientStorage[left])
                left += 1
            } else if left >= symbolStorage.count || other.symbolStorage[right].id < symbolStorage[left].id {
                mergedSymbols.append(other.symbolStorage[right])
                mergedCoefficients.append(other.coefficientStorage[right] * coefficient)
                right += 1
            } else {
                let value = coefficientStorage[left] + other.coefficientStorage[right] * coefficient
                if !nearZero(value) {
                    mergedSymbols.append(symbolStorage[left])
                    mergedCoefficients.append(value)
                }
                left += 1
                right += 1
            }
        }
        symbolStorage = mergedSymbols
        coefficientStorage = mergedCoefficients
    }

    /// Removes `symbol` from the row.
    internal mutating func remove(_ symbol: Symbol) {
        guard let index = index(of: symbol) else { return }
        symbolStorage.remove(at: index)
        coefficientStorage.remove(at: index)
    }

    /// Reverses the sign of the constant and of every cell.
    internal mutating func reverseSign() {
        constant = -constant
        for index in coefficientStorage.indices {
            coefficientStorage[index] = -coefficientStorage[index]
        }
    }

    /// Solves the row for `symbol`.
    ///
    /// The row is assumed to be of the form `a * symbol + rest = 0`; afterwards
    /// it represents `symbol = -rest / a`. The solved-for symbol is removed and
    /// the constant and remaining cells are scaled by `-1 / a`.
    ///
    /// - Throws: `SolverError.internalInconsistency` if the symbol is absent.
    internal mutating func solveFor(_ symbol: Symbol) throws {
        guard let index = index(of: symbol) else {
            throw SolverError.internalInconsistency("row does not contain the symbol to solve for")
        }
        let coefficient = coefficientStorage[index]
        symbolStorage.remove(at: index)
        coefficientStorage.remove(at: index)
        let multiplier = -1.0 / coefficient
        constant *= multiplier
        for index in coefficientStorage.indices {
            coefficientStorage[index] *= multiplier
        }
    }

    /// Solves the row for `lhs` in terms of `rhs`.
    ///
    /// The row is assumed to be of the form `rhs = rest`; afterwards it
    /// represents `lhs = rest / rhsCoefficient`. `lhs` must not already appear
    /// in the row, `rhs` must appear in it.
    internal mutating func solveFor(_ lhs: Symbol, _ rhs: Symbol) throws {
        insert(lhs, -1.0)
        try solveFor(rhs)
    }

    /// Substitutes `symbol` in this row with the contents of `other`.
    ///
    /// Given `symbol = other` and this row `a * symbol + rest = 0`, the row
    /// becomes `a * other + rest = 0`. A no-op when the symbol is absent.
    internal mutating func substitute(_ symbol: Symbol, with other: Row) {
        guard let index = index(of: symbol) else { return }
        let coefficient = coefficientStorage[index]
        symbolStorage.remove(at: index)
        coefficientStorage.remove(at: index)
        insert(other, coefficient)
    }

    // MARK: Symbol lookup

    /// Index of `symbol`, or nil when absent. Binary search over the sorted ids.
    private func index(of symbol: Symbol) -> Int? {
        var low = 0
        var high = symbolStorage.count
        while low < high {
            let middle = (low + high) / 2
            let candidate = symbolStorage[middle].id
            if candidate < symbol.id {
                low = middle + 1
            } else if candidate > symbol.id {
                high = middle
            } else {
                return middle
            }
        }
        return nil
    }

    /// The insertion position that keeps `symbolStorage` sorted by symbol id.
    private func insertionIndex(for symbol: Symbol) -> Int {
        var low = 0
        var high = symbolStorage.count
        while low < high {
            let middle = (low + high) / 2
            if symbolStorage[middle].id < symbol.id {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
