//
//  UICLabelPreferredWidth.m
//  UIKitBackports (Runtime)
//
//  Bridge between the Swift `preferredMaxLayoutWidth` extension (see
//  LegacyAutoLayout/UILabel+PreferredMaxLayoutWidth.swift) and the genuine
//  Apple property.
//
//  Why this exists:
//  The Swift extension keeps the property's original name and meaning so app
//  source is identical on iOS 5 and iOS 6+. On iOS 5 the property does not
//  exist in Apple's UIKit, so the extension is the sole provider and the
//  backport engine consumes the mirrored state. On iOS 6+ Apple's UILabel
//  already implements the property, and the class method table keeps Apple's
//  implementation (a Swift extension cannot add a method the class already
//  has); an app that calls the Swift setter therefore stores its value in the
//  backport state while Apple's own intrinsic-size computation reads Apple's
//  (zero) property and never wraps. The fix: the Swift property also forwards
//  to the genuine Apple property when Apple provides one, so both readers see
//  the same value.
//
//  The gate is a system-version check, not a selector probe: on iOS 6+ the
//  property's existence is guaranteed by the platform (added in iOS 6.0),
//  and on iOS 5 no msgSend is issued at all, so neither path can recurse
//  into the extension regardless of method-table registration order.

#import <UIKit/UIKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

static BOOL UICAppleProvidesLabelPreferredWidth(void) {
    static BOOL sProvides = NO;
    static BOOL sDecided = NO;
    if (!sDecided) {
        int major = 5;
        NSScanner *scanner = [NSScanner scannerWithString:
            [[UIDevice currentDevice] systemVersion]];
        int value = 0;
        if ([scanner scanInt:&value] && value >= 0) major = value;
        sProvides = major >= 6;
        sDecided = YES;
    }
    return sProvides;
}

CGFloat UICLabelRealPreferredMaxLayoutWidth(UILabel *label) {
    if (!UICAppleProvidesLabelPreferredWidth() || label == nil) return 0;
    return label.preferredMaxLayoutWidth;
}

void UICLabelSetRealPreferredMaxLayoutWidth(UILabel *label, CGFloat value) {
    if (!UICAppleProvidesLabelPreferredWidth() || label == nil) return;
    label.preferredMaxLayoutWidth = value;
}

#pragma clang diagnostic pop
