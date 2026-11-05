//
//  UILabel+PreferredMaxLayoutWidth.swift
//  LegacyAutoLayout
//
//  Genuine UIKit API (introduced in iOS 6) that the legacy runtime does not
//  provide on iOS 5. The property keeps its original name, type and meaning:
//  during Auto Layout measurement a multiline label whose natural width
//  exceeds this value reports that width, and the height it needs at that
//  width. A value of 0 (the default) preserves the automatic behaviour.
//
//  Dual-OS storage (round 120 fix):
//  The value is ALWAYS mirrored into the backport state (the iOS 5 engine
//  reads it from there), and on iOS 6+ it is additionally forwarded to the
//  genuine Apple property through the ObjC bridge
//  (Runtime/UICLabelPreferredWidth.m). On iOS 6+ Apple's UILabel already
//  implements the property, so its method table keeps Apple's implementation
//  and Apple's own intrinsic-size computation reads the Apple property:
//  without the forward, an app written `label.preferredMaxLayoutWidth = 240`
//  would store 240 in the backport state while Apple reads its own 0 and
//  never wraps the text (long messages overflow their bubble on 6.1.6 while
//  the unpatched build wraps correctly). The getter prefers the mirrored
//  state and falls back to the Apple property, so both OSes report the last
//  value the app wrote.

import Foundation
import CoreGraphics
import UIKit

@_silgen_name("UICLabelRealPreferredMaxLayoutWidth")
private func uic_label_real_preferred_width(_ label: UILabel) -> CGFloat

@_silgen_name("UICLabelSetRealPreferredMaxLayoutWidth")
private func uic_label_set_real_preferred_width(_ label: UILabel, _ value: CGFloat)

extension UILabel {
    /// The preferred maximum width, in points, for a multiline label.
    public var preferredMaxLayoutWidth: CGFloat {
        get {
            if let state = LegacyViewState.existing(of: self)?.preferredMaxLayoutWidth {
                return state
            }
            return uic_label_real_preferred_width(self)
        }
        set {
            LegacyViewState.of(self).preferredMaxLayoutWidth = newValue
            uic_label_set_real_preferred_width(self, newValue)
            LegacyLayoutMutation.bump()
            legacySetNeedsUpdateConstraints()
        }
    }
}
