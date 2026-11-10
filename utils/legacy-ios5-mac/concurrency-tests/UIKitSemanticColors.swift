// Run through the legacy device runner after building the UIKit fallback.
import UIKit
import Darwin

let names = ["systemBackgroundColor", "secondarySystemBackgroundColor",
             "tertiarySystemBackgroundColor", "systemGroupedBackgroundColor",
             "secondarySystemGroupedBackgroundColor", "tertiarySystemGroupedBackgroundColor"]
var failures = 0
for name in names {
    let selector = NSSelectorFromString(name)
    let available = UIColor.responds(to: selector)
    print("\(available ? "PASS" : "FAIL") UIColor.\(name)")
    if !available { failures += 1 }
}
// Exercise the exact native selector that caused the photo app to abort.
if failures == 0 {
    // Selector invocation tests the installed fallback without bypassing SDK
    // availability. The SDK still correctly annotates the native Swift property.
    let color = UIColor.perform(NSSelectorFromString("systemBackgroundColor"))!.takeUnretainedValue() as! UIColor
    // iOS 5 getRed does not convert grayscale whiteColor to RGB components.
    let ok = color.cgColor.alpha == 1
    print("\(ok ? "PASS" : "FAIL") semantic background is opaque")
    if !ok { failures += 1 }
}
fflush(stdout)
exit(Int32(failures))
