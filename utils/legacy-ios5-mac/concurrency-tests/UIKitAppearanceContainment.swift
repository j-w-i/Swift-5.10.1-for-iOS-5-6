// appearance(whenContainedInInstancesOf:) (iOS 9) below iOS 9: UICAppearanceContainment.m forwards it to
// the variadic +appearanceWhenContainedIn:, which Swift cannot call. Run through the legacy device runner:
//   EXTRA_LIBS=UIKit bash run-on-ipod.sh UIKitAppearanceContainment.swift TOOLCHAIN
import UIKit
import Darwin

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}

// The variadic method, called the way compiled Objective-C calls it (armv7: same convention as fixed arguments).
typealias VariadicAppearance = @convention(c) (AnyObject, Selector, AnyClass?, AnyClass?, AnyClass?, AnyClass?) -> Unmanaged<AnyObject>
func variadic(_ type: AnyClass, _ containers: [AnyClass]) -> AnyObject {
    let selector = Selector(("appearanceWhenContainedIn:"))
    let imp = class_getMethodImplementation(object_getClass(type), selector)!
    let call = unsafeBitCast(imp, to: VariadicAppearance.self)
    let c = containers.map { Optional($0) } + [nil, nil, nil, nil]
    return call(type, selector, c[0], c[1], c[2], c[3]).takeUnretainedValue()
}

let arraySelector = Selector(("appearanceWhenContainedInInstancesOfClasses:"))
check(UIView.responds(to: arraySelector) && UIBarItem.responds(to: arraySelector),
      "UIView and UIBarItem respond to +appearanceWhenContainedInInstancesOfClasses:")

let buttonProxy = UIButton.appearance(whenContainedInInstancesOf: [UINavigationBar.self, UIToolbar.self])
check(buttonProxy === variadic(UIButton.self, [UINavigationBar.self, UIToolbar.self]),
      "UIButton proxy is UIKit's proxy for the same container path")
check(UIButton.appearance(whenContainedInInstancesOf: [UIToolbar.self, UINavigationBar.self]) !== buttonProxy,
      "container order is kept (a different path is a different proxy)")
let deep: [UIAppearanceContainer.Type] = [UIPopoverController.self, UINavigationController.self, UINavigationBar.self]
check(UILabel.appearance(whenContainedInInstancesOf: deep) === variadic(UILabel.self, deep.map { $0 as! AnyClass }),
      "three-container path matches")
check(UIButton.appearance(whenContainedInInstancesOf: []) === UIButton.appearance(), "empty path is the +appearance proxy")

let itemProxy = UIBarButtonItem.appearance(whenContainedInInstancesOf: [UIToolbar.self])
check(itemProxy === variadic(UIBarButtonItem.self, [UIToolbar.self]), "UIBarButtonItem proxy (UIBarItem) matches")

// Customizations recorded on the proxy are UIKit's own appearance invocations.
buttonProxy.setTitleColor(.red, for: .normal)
itemProxy.tintColor = .blue
check(itemProxy.tintColor == .blue, "customization through the proxy is recorded")

fflush(stdout)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(Int32(failures))
