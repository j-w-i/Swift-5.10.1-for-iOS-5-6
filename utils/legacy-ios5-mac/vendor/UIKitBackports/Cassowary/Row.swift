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
/// `kiwi` implementation (`1e-8`). Values whose magnitude are below the
/// tolerance are treated as zero.
internal func nearZero(_ value: Double) -> Bool {
    let epsilon = 1.0e-8
    return value < 0.0 ? -value < epsilon : value < epsilon
}

/// A sparse row of the simplex tableau: `constant + sum(cell * symbol) == 0`.
///
/// A reference type: the tableau owns every row, pivots mutate rows in place, and
/// substitution merges the entering row straight into the target row (no
/// copy-on-write array copies, no per-substitution merge buffers). Solver
/// snapshots that must roll back take explicit `Row(copying:)` copies; the build
/// path never snapshots, so its hot loop has no row copies.
///
/// Coefficients live in two parallel arrays (symbols sorted by symbol id +
/// coefficients). Row cell counts are small, so `coefficient(for:)`/`index(of:)`
/// use a linear scan up to a small threshold and binary search above it.
internal final class Row {

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
        symbolStorage.reserveCapacity(8)
        coefficientStorage.reserveCapacity(8)
        self.constant = constant
    }

    /// Independent copy for solver snapshots. The arrays' buffers are shared
    /// copy-on-write, so a copy is cheap and the first mutation pays the copy.
    internal init(copying other: Row) {
        self.symbolStorage = other.symbolStorage
        self.coefficientStorage = other.coefficientStorage
        self.constant = other.constant
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

    /// The first non-dummy symbol with a negative coefficient, in symbol-id
    /// order. Used by the primal simplex to pick the entering column without
    /// copying the row's symbol list on every pivot.
    internal func firstNegativePivotableSymbol() -> Symbol? {
        let count = symbolStorage.count
        for index in 0..<count {
            let symbol = symbolStorage[index]
            if !symbol.isDummy && coefficientStorage[index] < 0.0 {
                return symbol
            }
        }
        return nil
    }

    /// Whether the row's sorted cells could contain `symbol` (id range check).
    /// Used to skip the per-row scan in hot tableau traversals without touching
    /// the arrays if the symbol is outside the row's id range.
    internal func mayContain(_ symbol: Symbol) -> Bool {
        let count = symbolStorage.count
        if count == 0 { return false }
        let target = symbol.id
        return target >= symbolStorage[0].id && target <= symbolStorage[count - 1].id
    }

    /// The coefficient of `symbol`, or `0` when the symbol is absent.
    internal func coefficient(for symbol: Symbol) -> Double {
        let count = symbolStorage.count
        let target = symbol.id
        if count <= 12 {
            for index in 0..<count where symbolStorage[index].id == target {
                return coefficientStorage[index]
            }
            return 0.0
        }
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            let candidate = symbolStorage[middle].id
            if candidate < target {
                low = middle + 1
            } else if candidate > target {
                high = middle
            } else {
                return coefficientStorage[middle]
            }
        }
        return 0.0
    }

    /// Adds `value` to the constant term and returns the new constant.
    @discardableResult
    internal func add(_ value: Double) -> Double {
        constant += value
        return constant
    }

    /// Sets the constant term directly (constant-only row updates).
    internal func setConstant(_ value: Double) {
        constant = value
    }

    /// Inserts `coefficient * symbol` into the row.
    ///
    /// If the symbol is already present its coefficient is accumulated. If the
    /// resulting coefficient is (close to) zero the symbol is removed, keeping
    /// the row sparse.
    internal func insert(_ symbol: Symbol, _ coefficient: Double = 1.0) {
        let count = symbolStorage.count
        let target = symbol.id
        // Linear scan for the common short row, binary search for long ones.
        if count <= 12 {
            for index in 0..<count {
                let candidate = symbolStorage[index].id
                if candidate == target {
                    let value = coefficientStorage[index] + coefficient
                    if nearZero(value) {
                        symbolStorage.remove(at: index)
                        coefficientStorage.remove(at: index)
                    } else {
                        coefficientStorage[index] = value
                    }
                    return
                }
                if candidate > target { break }
            }
        } else {
            var low = 0
            var high = count
            while low < high {
                let middle = (low + high) / 2
                if symbolStorage[middle].id < target {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low < count && symbolStorage[low].id == target {
                let value = coefficientStorage[low] + coefficient
                if nearZero(value) {
                    symbolStorage.remove(at: low)
                    coefficientStorage.remove(at: low)
                } else {
                    coefficientStorage[low] = value
                }
                return
            }
        }
        guard !nearZero(coefficient) else { return }
        let index = insertionIndex(for: symbol)
        symbolStorage.insert(symbol, at: index)
        coefficientStorage.insert(coefficient, at: index)
    }

    /// Inserts `coefficient * other` into this row.
    ///
    /// In-place linear merge of two symbol-sorted rows. When this row's arrays
    /// have spare capacity (the normal case, rows reserve 8 cells) no allocation
    /// happens at all; otherwise the merge grows the arrays once.
    internal func insert(_ other: Row, _ coefficient: Double = 1.0) {
        constant += other.constant * coefficient
        let otherCount = other.symbolStorage.count
        guard otherCount > 0 else { return }
        let count = symbolStorage.count
        if count == 0 {
            symbolStorage.reserveCapacity(otherCount)
            coefficientStorage.reserveCapacity(otherCount)
            for index in 0..<otherCount {
                symbolStorage.append(other.symbolStorage[index])
                coefficientStorage.append(other.coefficientStorage[index] * coefficient)
            }
            return
        }
        let total = count + otherCount
        if symbolStorage.capacity >= total && coefficientStorage.capacity >= total {
            // Normal case: rows reserve cells up-front, so substitute into this
            // row's own storage without allocating.
            mergeIntoStorage(&symbolStorage, &coefficientStorage, other, coefficient)
        } else {
            var mergedSymbols = symbolStorage
            var mergedCoefficients = coefficientStorage
            mergedSymbols.reserveCapacity(total)
            mergedCoefficients.reserveCapacity(total)
            mergeIntoStorage(&mergedSymbols, &mergedCoefficients, other, coefficient)
            symbolStorage = mergedSymbols
            coefficientStorage = mergedCoefficients
        }
    }

    /// Merges `other * coefficient` into the sorted parallel arrays `symbols` /
    /// `coefficients`, replacing their contents.
    ///
    /// Both destinations are grown to `count + otherCount` first, then filled from
    /// the back: the write cursor always stays ahead of the unread source entries,
    /// so this is safe when the destination is the row's own storage. Cells whose
    /// merged coefficient becomes zero are dropped and the surviving tail is
    /// moved to the front once.
    private func mergeIntoStorage(_ symbols: inout [Symbol],
                                  _ coefficients: inout [Double],
                                  _ other: Row,
                                  _ coefficient: Double) {
        let count = symbols.count
        let otherCount = other.symbolStorage.count
        let total = count + otherCount
        symbols.reserveCapacity(total)
        coefficients.reserveCapacity(total)
        for _ in 0..<otherCount {
            symbols.append(.invalid)
            coefficients.append(0.0)
        }
        var write = total - 1
        var left = count - 1
        var right = otherCount - 1
        while left >= 0 || right >= 0 {
            // The merge runs from the back, so the LARGER symbol id is placed
            // first. Taking the smaller one first is the front-merge ordering and
            // would leave the arrays unsorted.
            if right < 0 || (left >= 0 && symbols[left].id > other.symbolStorage[right].id) {
                symbols[write] = symbols[left]
                coefficients[write] = coefficients[left]
                left -= 1
                write -= 1
            } else if left < 0 || other.symbolStorage[right].id > symbols[left].id {
                symbols[write] = other.symbolStorage[right]
                coefficients[write] = other.coefficientStorage[right] * coefficient
                right -= 1
                write -= 1
            } else {
                let value = coefficients[left] + other.coefficientStorage[right] * coefficient
                if !nearZero(value) {
                    symbols[write] = symbols[left]
                    coefficients[write] = value
                    write -= 1
                }
                left -= 1
                right -= 1
            }
        }
        // Two cells can merge into one (or disappear), so the written result may
        // be shorter than `total`; the valid cells always end at `total - 1`.
        let shift = write + 1
        if shift > 0 {
            symbols.removeFirst(shift)
            coefficients.removeFirst(shift)
        }
    }

    /// Removes `symbol` from the row.
    internal func remove(_ symbol: Symbol) {
        guard let index = index(of: symbol) else { return }
        symbolStorage.remove(at: index)
        coefficientStorage.remove(at: index)
    }

    /// Reverses the sign of the constant and of every cell.
    internal func reverseSign() {
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
    internal func solveFor(_ symbol: Symbol) throws {
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
    internal func solveFor(_ lhs: Symbol, _ rhs: Symbol) throws {
        insert(lhs, -1.0)
        try solveFor(rhs)
    }

    /// Substitutes `symbol` in this row with the contents of `other`.
    ///
    /// Given `symbol = other` and this row `a * symbol + rest = 0`, the row
    /// becomes `a * other + rest = 0`. A no-op when the symbol is absent.
    internal func substitute(_ symbol: Symbol, with other: Row) {
        guard let index = index(of: symbol) else { return }
        let coefficient = coefficientStorage[index]
        symbolStorage.remove(at: index)
        coefficientStorage.remove(at: index)
        insert(other, coefficient)
    }

    // MARK: Symbol lookup

    /// Index of `symbol`, or nil when absent.
    private func index(of symbol: Symbol) -> Int? {
        let count = symbolStorage.count
        let target = symbol.id
        if count <= 12 {
            for index in 0..<count where symbolStorage[index].id == target {
                return index
            }
            return nil
        }
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            let candidate = symbolStorage[middle].id
            if candidate < target {
                low = middle + 1
            } else if candidate > target {
                high = middle
            } else {
                return middle
            }
        }
        return nil
    }

    /// The insertion position that keeps `symbolStorage` sorted by symbol id.
    private func insertionIndex(for symbol: Symbol) -> Int {
        let count = symbolStorage.count
        let target = symbol.id
        if count <= 12 {
            var index = 0
            while index < count && symbolStorage[index].id < target {
                index += 1
            }
            return index
        }
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if symbolStorage[middle].id < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
