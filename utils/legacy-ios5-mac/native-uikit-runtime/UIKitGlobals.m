//===----------------------------------------------------------------------===//
// This source file is part of the Swift.org open source project.
// Copyright (c) 2026 Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception.
// See https://swift.org/LICENSE.txt for license information.
//===----------------------------------------------------------------------===//

#import <CoreGraphics/CGBase.h>

// Implementation linkage only. The importer preserves Apple's declaration and
// API notes for UIViewNoIntrinsicMetric / UIView.noIntrinsicMetric. It redirects
// that absent iOS 6 symbol here, rather than importing a nil weak global on 5.
// No declaration of this private spelling is installed in the public SDK.
const CGFloat SwiftLegacyUIViewNoIntrinsicMetric = -1.0;

// Genuine UIKit attribute-name constants. Their values are the CoreText keys that
// UIKit itself uses on every iOS version ("NSFont", "NSColor", "NSUnderline"), so
// CoreText consumes a UIKit attribute dictionary unchanged.
#import <Foundation/Foundation.h>
NSString *const SwiftLegacyNSFontAttributeName = @"NSFont";
NSString *const SwiftLegacyNSForegroundColorAttributeName = @"NSColor";
NSString *const SwiftLegacyNSUnderlineStyleAttributeName = @"NSUnderline";
