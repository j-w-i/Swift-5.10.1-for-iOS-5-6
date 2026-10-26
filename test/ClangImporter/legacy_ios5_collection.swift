// REQUIRES: objc_interop
// REQUIRES: CODEGENERATOR=ARM
// REQUIRES: CODEGENERATOR=X86
// RUN: %empty-directory(%t)
// RUN: split-file %s %t
//
// A synthetic SDK and resource tree keep this test independent of an Apple SDK
// and installed legacy runtime. No bridging header, -Xcc, -I or -F is involved.
// RUN: %swift %t/client.swift -typecheck -parse-stdlib -sdk %t/sdk -resource-dir %t/resource -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -D LEGACY -module-cache-path %t/cache
// RUN: %swift %t/client.swift -typecheck -parse-stdlib -sdk %t/sdk -resource-dir %t/resource -target armv7-apple-ios5.1 -enable-legacy-ios5-runtime -D LEGACY -module-cache-path %t/cache
//
// Native targets and disabled legacy mode must not open the resource header.
// Reuse the cache to exercise target/module identity separation.
// RUN: %swift %t/client.swift -typecheck -parse-stdlib -sdk %t/sdk -resource-dir %t/resource -target armv7-apple-ios6.0 -enable-legacy-ios5-runtime -module-cache-path %t/cache
// RUN: %swift %t/client.swift -typecheck -parse-stdlib -sdk %t/sdk -resource-dir %t/resource -target armv7-apple-ios5.0 -module-cache-path %t/cache
// RUN: %swift %t/client.swift -typecheck -parse-stdlib -sdk %t/sdk -resource-dir %t/resource -target i386-apple-ios5.0-simulator -module-cache-path %t/cache
// RUN: %swift %t/client.swift -typecheck -parse-stdlib -sdk %t/sdk -resource-dir %t/resource -target armv7-apple-ios5.0 -clang-target armv7-apple-ios6.0 -enable-legacy-ios5-runtime -module-cache-path %t/cache
//
// The original iOS 5 SDK has no collection headers: augmentation still works.
// RUN: %swift %t/client.swift -typecheck -parse-stdlib -sdk %t/old-sdk -resource-dir %t/resource -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -D LEGACY -module-cache-path %t/old-cache
//
// Missing toolchain resources fail closed on importing UIKit, but must not
// break unrelated compilations. Keep the missing-resource cache separate.
// RUN: not %swift %t/client.swift -typecheck -parse-stdlib -sdk %t/sdk -resource-dir %t/missing-resource -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -D LEGACY -module-cache-path %t/missing-cache 2>&1 | %FileCheck %s --check-prefix=MISSING
// RUN: %swift %t/empty.swift -typecheck -parse-stdlib -sdk %t/sdk -resource-dir %t/missing-resource -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -module-cache-path %t/missing-cache
// MISSING: UIKitLegacyCollection.h' file not found
//
// Relax only supported iOS 6 API. Newer API availability must remain intact.
// RUN: not %swift %t/availability.swift -typecheck -parse-stdlib -sdk %t/sdk -resource-dir %t/resource -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -module-cache-path %t/cache 2>&1 | %FileCheck %s --check-prefix=FUTURE
// FUTURE: 'future()' is only available in iOS 7.0 or newer
// RUN: not %swift %t/unrelated.swift -typecheck -parse-stdlib -sdk %t/sdk -resource-dir %t/resource -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -module-cache-path %t/cache 2>&1 | %FileCheck %s --check-prefix=UNRELATED
// UNRELATED: 'UICollectionView' is only available in iOS 6.0 or newer
//
// Scanner output must be replayable as explicit PCM builds with the same
// compiler-owned VFS, despite -only-use-extra-clang-opts.
// RUN: %swift %t/client.swift -scan-dependencies -parse-stdlib -module-name CollectionClient -sdk %t/sdk -resource-dir %t/resource -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -module-cache-path %t/scan-cache > %t/deps.json
// RUN: %python %S/Inputs/legacy-collection-replay.py %t/deps.json %swift
//
// The public names stay UIKit, but subclass and constant references must bind
// directly to the runtime's real symbols. Native iOS 6 remains completely native.
// RUN: %swift %t/client.swift -emit-ir -parse-stdlib -disable-legacy-type-info -sdk %t/sdk -resource-dir %t/resource -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -D LEGACY -module-cache-path %t/cache -o - | %FileCheck %s --check-prefix=LEGACY-IR
// RUN: %swift %t/client.swift -emit-ir -parse-stdlib -disable-legacy-type-info -sdk %t/sdk -resource-dir %t/resource -target armv7-apple-ios6.0 -enable-legacy-ios5-runtime -D NATIVE_IR -module-cache-path %t/cache -o - | %FileCheck %s --check-prefix=NATIVE-IR
// LEGACY-IR-DAG: OBJC_CLASS_$_PSTCollectionView
// LEGACY-IR-DAG: OBJC_METACLASS_$_PSTCollectionView
// LEGACY-IR-DAG: _PSTCollectionElementKindSectionHeader
// NATIVE-IR: OBJC_CLASS_$_UICollectionView
// NATIVE-IR-NOT: PSTCollectionView
//
//--- unrelated.swift
import Unrelated
func mustRemainUnavailable(_ value: Unrelated.UICollectionView) {}
//--- sdk/System/Library/Frameworks/Unrelated.framework/Modules/module.modulemap
framework module Unrelated {
  umbrella header "Unrelated.h"
  export *
}
//--- sdk/System/Library/Frameworks/Unrelated.framework/Headers/Unrelated.h
__attribute__((objc_root_class,availability(ios,introduced=6.0)))
@interface UICollectionView @end
//--- availability.swift
import UIKit
func baseline(_ value: UIKit.UICollectionView) -> UIKit.SDKUnchanged { value.baseline() }
func future(_ value: UIKit.UICollectionView) -> UIKit.SDKUnchanged { value.future() }
//--- client.swift
import UIKit

// Module qualification is intentional: these must be UIKit declarations, not
// names leaking from an implicit bridging header or a separate compatibility
// module. An unrelated SDK declaration and unchanged API spelling survive.
func original(_ value: UIKit.SDKUnchanged) {}
#if LEGACY
class UserCollection : UIKit.UICollectionView {}
func collection(_ value: UIKit.UICollectionView) {}
func cell(_ value: UIKit.UICollectionViewCell) {}
func upcast(_ value: UIKit.UICollectionViewCell) -> UIKit.UICollectionReusableView { value }
func delegate(_ value: UIKit.UICollectionViewDelegate) {}
func sectionHeader() -> UIKit.SDKUnchanged { UIKit.UICollectionElementKindSectionHeader }
func unchanged(_ value: UIKit.UICollectionViewLayoutInvalidationContext) {}
#else
func native(_ value: UIKit.NativeCollectionSentinel) {}
#endif
#if NATIVE_IR
class NativeSubclass : UIKit.UICollectionView {}
#endif

//--- empty.swift
// No UIKit import.

//--- sdk/System/Library/Frameworks/UIKit.framework/Modules/module.modulemap
framework module UIKit {
  umbrella header "UIKit.h"
  export *
  module * { export * }
}
//--- sdk/System/Library/Frameworks/UIKit.framework/Headers/UIKit.h
#pragma once
__attribute__((objc_root_class)) @interface SDKUnchanged @end
#import <UIKit/UICollectionView.h>
#import <UIKit/SDKCollectionUser.h>
#import <UIKit/UICollectionViewFuture.h>
//--- sdk/System/Library/Frameworks/UIKit.framework/Headers/SDKCollectionUser.h
// This unrelated SDK header requires collection declarations BEFORE UIKit.h
// completes. Appending the resource only at the end of UIKit.h is insufficient.
@interface SDKCollectionUser : UICollectionView @end
//--- sdk/System/Library/Frameworks/UIKit.framework/Headers/UICollectionView.h
// Preserve native signatures, including later types and unrelated declarations.
__attribute__((availability(ios,introduced=6.0)))
@interface UICollectionView : SDKUnchanged
- (SDKUnchanged * _Nonnull)baseline;
- (SDKUnchanged * _Nonnull)future __attribute__((availability(ios,introduced=7.0)));
@end
__attribute__((availability(ios,introduced=6.0)))
@interface UICollectionReusableView : SDKUnchanged @end
__attribute__((availability(ios,introduced=6.0)))
@interface UICollectionViewCell : UICollectionReusableView @end
__attribute__((availability(ios,introduced=6.0)))
@protocol UICollectionViewDelegate @end
@interface UICollectionViewLayoutInvalidationContext : SDKUnchanged @end
@interface NativeCollectionSentinel : SDKUnchanged @end
extern SDKUnchanged * _Nonnull const UICollectionElementKindSectionHeader __attribute__((availability(ios,introduced=6.0)));
//--- sdk/System/Library/Frameworks/UIKit.framework/Headers/UICollectionViewFuture.h
// Modern SDK collection headers are retained unchanged.
@class UICollectionView;
//--- old-sdk/System/Library/Frameworks/UIKit.framework/Modules/module.modulemap
framework module UIKit {
  umbrella header "UIKit.h"
  export *
  module * { export * }
}
//--- old-sdk/System/Library/Frameworks/UIKit.framework/Headers/UIKit.h
#pragma once
__attribute__((objc_root_class)) @interface SDKUnchanged @end
//--- resource/legacy-collection/Headers/UIKitLegacyCollection.h
#pragma once
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 60000
#error The legacy resource must never be used for iOS 6.
#endif
__attribute__((objc_runtime_name("PSTCollectionView")))
@interface UICollectionView : SDKUnchanged @end
__attribute__((objc_runtime_name("PSTCollectionReusableView")))
@interface UICollectionReusableView : SDKUnchanged @end
__attribute__((objc_runtime_name("PSTCollectionViewCell")))
@interface UICollectionViewCell : UICollectionReusableView @end
@protocol UICollectionViewDelegate @end
typedef enum UICollectionViewScrollDirection {
  UICollectionViewScrollDirectionVertical,
  UICollectionViewScrollDirectionHorizontal
} UICollectionViewScrollDirection;
// This API deliberately has unchanged spelling, not a PST prefix replacement.
@interface UICollectionViewLayoutInvalidationContext : SDKUnchanged @end
extern SDKUnchanged * _Nonnull const UICollectionElementKindSectionHeader __asm__("_PSTCollectionElementKindSectionHeader");
