//
//  UILabel+PreferredMaxLayoutWidth.swift
//  LegacyAutoLayout
//
//  Genuine UIKit API (introduced in iOS 6) that the legacy runtime does not
//  provide. The property keeps its original name, type and meaning: during Auto
//  Layout measurement a multiline label whose natural width exceeds this value
//  reports this width, and the height it needs at that width. A value of 0 (the
//  default) preserves the automatic behaviour.
//

import Foundation
import CoreGraphics
import UIKit

extension UILabel {
    /// The preferred maximum width, in points, for a multiline label.
    public var preferredMaxLayoutWidth: CGFloat {
        get {
            return LegacyViewState.existing(of: self)?.preferredMaxLayoutWidth ?? 0
        }
        set {
            LegacyViewState.of(self).preferredMaxLayoutWidth = newValue
            LegacyLayoutMutation.bump()
            legacySetNeedsUpdateConstraints()
        }
    }
}
