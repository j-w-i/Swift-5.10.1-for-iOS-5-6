"""Native UIKit availability and linkage regression, without an installed SDK."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
compiler = sys.argv[2:]
headers = root / "sdk/System/Library/Frameworks/UIKit.framework/Headers"
modules = headers.parent / "Modules"
resource = root / "resource"
headers.mkdir(parents=True, exist_ok=True)
modules.mkdir(parents=True, exist_ok=True)
(resource / "legacy-collection/Headers").mkdir(parents=True, exist_ok=True)
(resource / "legacy-collection/Headers/UIKitLegacyCollection.h").write_text("// Native SDK: do not inject duplicate declarations.\n")
modules.joinpath("module.modulemap").write_text('framework module UIKit { umbrella header "UIKit.h" export * module * { export * } }\n')

# Each tuple records the original native introduction, not the backport floor.
classes = {
    "NSLayoutConstraint": (6, "NSLayoutConstraint.h", "SDKObject"),
    "NSLayoutAnchor": (9, "NSLayoutAnchor.h", "SDKObject"),
    "NSLayoutXAxisAnchor": (9, "NSLayoutAnchor.h", "NSLayoutAnchor"),
    "NSLayoutYAxisAnchor": (9, "NSLayoutAnchor.h", "NSLayoutAnchor"),
    "NSLayoutDimension": (9, "NSLayoutAnchor.h", "NSLayoutAnchor"),
    "UILayoutGuide": (9, "UILayoutGuide.h", "SDKObject"),
    "UIRefreshControl": (6, "UIRefreshControl.h", "SDKObject"),
    "UIStackView": (9, "UIStackView.h", "UIView"),
    "UICollectionViewCompositionalLayout": (13, "UICollectionViewCompositionalLayout.h", "UICollectionViewLayout"),
    "UICollectionViewCompositionalLayoutConfiguration": (13, "UICollectionViewCompositionalLayout.h", "SDKObject"),
}
for name in ("Section", "Item", "GroupCustomItem", "Dimension", "Size", "Spacing", "EdgeSpacing", "Anchor"):
    classes["NSCollectionLayout" + name] = (13, "UICollectionViewCompositionalLayout.h", "SDKObject")
for name, parent in (("Group", "Item"), ("SupplementaryItem", "Item"), ("BoundarySupplementaryItem", "SupplementaryItem"), ("DecorationItem", "Item")):
    classes["NSCollectionLayout" + name] = (13, "UICollectionViewCompositionalLayout.h", "NSCollectionLayout" + parent)

allowed = {
    "UIView": {
        "intrinsicContentSize": 6, "invalidateIntrinsicContentSize": 6,
        "contentHuggingPriorityForAxis": 6, "setContentHuggingPriority": 6,
        "contentCompressionResistancePriorityForAxis": 6, "setContentCompressionResistancePriority": 6,
        "layoutMargins": 8, "setLayoutMargins": 8, "layoutMarginsDidChange": 8,
        "addLayoutGuide": 9, "layoutMarginsGuide": 9,
        **{name + "Anchor": 9 for name in ("leading", "trailing", "top", "bottom", "left", "right", "width", "height", "centerX", "centerY")},
    },
    "UIScrollView": {"refreshControl": 10, "setRefreshControl": 10},
}
denied = {
    "UIView": {"systemLayoutSizeFittingSize": 6, "setNeedsUpdateConstraints": 6, "readableContentGuide": 9,
               "baselineAnchor": 9, "firstBaselineAnchor": 9, "lastBaselineAnchor": 9,
               "addConstraint": 6, "constraints": 6},
    "UIScrollView": {"contentLayoutGuide": 11, "frameLayoutGuide": 11},
    "UIFont": {"excludedFontAPI": 6}, "UIButton": {"excludedButtonAPI": 6},
}
# No member-level native availability here: these would otherwise leak through
# the lowered enclosing class/protocol. The compiler must add an explicit denial.
capability_denials = {
    "NSCollectionLayoutEnvironment": ["traitCollection"],
    "NSCollectionLayoutSection": ["visibleItemsInvalidationHandler", "setVisibleItemsInvalidationHandler"],
    "NSCollectionLayoutGroup": ["visualDescription"],
}

files = {"UICollectionView.h": "@interface UICollectionView : SDKObject @end\n@interface UICollectionViewLayout : SDKObject @end\n"}
def method(selector, version=None):
    availability = " AV(%d)" % version if version is not None else ""
    # Object payloads and explicit Swift names test selector matching without
    # requiring Swift.Int/Float/Void definitions in a -parse-stdlib compilation.
    return '- (SDKObject * _Nonnull)%s%s __attribute__((swift_name("probe_%s()")));\n' % (selector, availability, selector)

for owner in ("UIView", "UIScrollView", "UIFont", "UIButton"):
    text = "@interface %s : SDKObject\n" % owner
    for table in (allowed, denied):
        for selector, version in table.get(owner, {}).items():
            text += method(selector, version)
    text += "@end\n"
    files[owner + ".h"] = text
for name, (version, filename, parent) in classes.items():
    text = "AV(%d) @interface %s : %s\n" % (version, name, parent)
    text += method("familyBaseline") + method("familyFuture", version + 1)
    if name == "NSLayoutConstraint":
        text += method("priority", 6)
        text += '+ (SDKObject * _Nonnull)constraintsWithVisualFormat:(SDKObject * _Nonnull)x options:(SDKObject * _Nonnull)o metrics:(SDKObject * _Nonnull)m views:(SDKObject * _Nonnull)v AV(6) __attribute__((swift_name("visualFormat(_:options:metrics:views:)")));\n'
    for selector in capability_denials.get(name, []):
        text += method(selector)
    text += "@end\n"
    files[filename] = files.get(filename, "") + text
for protocol in ("NSCollectionLayoutContainer", "NSCollectionLayoutEnvironment", "NSCollectionLayoutVisibleItem"):
    text = "AV(13) @protocol %s\n" % protocol
    text += method("familyBaseline")
    for selector in capability_denials.get(protocol, []):
        text += method(selector)
    files["UICollectionViewCompositionalLayout.h"] += text + "@end\n"
# Explicitly excluded effects stay native, even with the backport mode enabled.
files["UIVisualEffectView.h"] = "".join("AV(8) @interface %s : SDKObject @end\n" % name for name in ("UIVisualEffectView", "UIVisualEffect", "UIBlurEffect", "UIVibrancyEffect"))
files["UIGeometry.h"] = 'typedef struct NSDirectionalEdgeInsets {} NSDirectionalEdgeInsets AV(11);\nextern const NSDirectionalEdgeInsets NSDirectionalEdgeInsetsZero AV(11);\nstatic inline SDKObject * _Nonnull directionalZeroAddress(void) { return (__bridge SDKObject *)(void *)&NSDirectionalEdgeInsetsZero; }\n'
preamble = '#pragma once\n#define AV(v) __attribute__((availability(ios,introduced=v)))\n__attribute__((objc_root_class)) @interface SDKObject @end\n'
# UIView must precede UIStackView, and base layout/item classes their subclasses.
order = ["UIView.h", "UIScrollView.h", "UIFont.h", "UIButton.h", "UICollectionView.h"]
order += [name for name in files if name not in order]
headers.joinpath("UIKit.h").write_text(preamble + "".join('#import <UIKit/%s>\n' % name for name in order))
for filename, text in files.items():
    headers.joinpath(filename).write_text("#pragma once\n" + text)
other = root / "sdk/System/Library/Frameworks/Unrelated.framework"
(other / "Headers").mkdir(parents=True, exist_ok=True)
(other / "Modules").mkdir(parents=True, exist_ok=True)
(other / "Headers/Unrelated.h").write_text('__attribute__((objc_root_class,availability(ios,introduced=9.0))) @interface UIStackView @end\n')
(other / "Modules/module.modulemap").write_text('framework module Unrelated { umbrella header "Unrelated.h" export * }\n')

runs = 0
def check(label, text, version, legacy=False, errors=(), extra=(), emit_ir=False):
    global runs
    path = root / (label + ".swift")
    path.write_text(text)
    target = ("arm64" if version >= 11 else "armv7") + "-apple-ios%d.0" % version
    args = [str(path), "-parse-stdlib", "-sdk", str(root / "sdk"), "-resource-dir", str(resource), "-target", target,
            "-module-cache-path", str(root / "cache")]
    args += ["-enable-legacy-ios5-runtime"] if legacy else []
    args += ["-emit-ir", "-disable-legacy-type-info", "-o", "-"] if emit_ir else ["-typecheck"]
    result = subprocess.run(compiler + args + list(extra), text=True, capture_output=True)
    runs += 1
    if errors:
        assert result.returncode != 0, (label, "unexpected success")
        for expected in errors:
            assert expected in result.stderr, (label, expected, result.stderr)
    else:
        assert result.returncode == 0, (label, result.stderr)
    if emit_ir:
        (root / (label + ".ll")).write_text(result.stdout)
    print("PASS", label)
    return result.stdout

def refs(names):
    return "import UIKit\n" + "".join("func type_%s(_ value: UIKit.%s) {}\n" % (name, name) for name in names)

def calls(entries):
    return "import UIKit\n" + "".join("func member_%s_%s(_ value: UIKit.%s) -> UIKit.SDKObject { value.probe_%s() }\n" % (owner, selector, owner, selector) for owner, selector in entries)

for version, legacy in ((5, True), (5, False), (6, True), (7, True), (8, True), (9, True), (13, False)):
    label = "target%d_%s" % (version, "legacy" if legacy else "native")
    enabled = legacy and version == 5
    available = [name for name, (intro, _, _) in classes.items() if enabled or intro <= version]
    if available:
        check(label + "_types", refs(available), version, legacy)
        check(label + "_baseline_members", calls([(name, "familyBaseline") for name in available]), version, legacy)
    unavailable = [name for name, (intro, _, _) in classes.items() if not enabled and intro > version]
    if unavailable: check(label + "_types_denied", refs(unavailable), version, legacy, errors=["only available in iOS"])
    yes = [(owner, member) for owner, members in allowed.items() for member, intro in members.items() if enabled or intro <= version]
    no = [(owner, member) for owner, members in allowed.items() for member, intro in members.items() if not enabled and intro > version]
    if yes: check(label + "_members", calls(yes), version, legacy)
    if no: check(label + "_members_denied", calls(no), version, legacy, errors=["only available in iOS"])
    # A future method remains unavailable in legacy mode even when its type is
    # lowered; at native targets it follows its original introduction exactly.
    future_yes = [(name, "familyFuture") for name, (intro, _, _) in classes.items() if intro + 1 <= version]
    future_no = [(name, "familyFuture") for name, (intro, _, _) in classes.items() if (enabled or intro <= version) and intro + 1 > version]
    if future_yes: check(label + "_future_native", calls(future_yes), version, legacy)
    if future_no: check(label + "_future_denied", calls(future_no), version, legacy, errors=["only available in iOS"])
# iOS 5.1 must take exactly the same backport path.
check("target51", refs(classes), 5, True, extra=["-target", "armv7-apple-ios5.1"])
# Every denied selector is tested independently so one diagnostic cannot mask a
# missing gate on another selector in an aggregate negative test.
for owner, members in denied.items():
    for selector, intro in members.items():
        diagnostic = "is unavailable" if selector in ("setNeedsUpdateConstraints", "addConstraint", "constraints") else "only available"
        check("withheld_" + selector, calls([(owner, selector)]), 5, True, errors=[diagnostic])
for owner, members in capability_denials.items():
    for selector in members:
        check("capability_" + selector, calls([(owner, selector)]), 5, True,
              errors=["not implemented by the legacy iOS 5 compositional layout runtime"])
for name in ("UIVisualEffectView", "UIVisualEffect", "UIBlurEffect", "UIVibrancyEffect"):
    check("excluded_" + name, refs([name]), 5, True, errors=["only available in iOS 8"])
check("native_withheld_members", calls([(owner, member) for owner, members in denied.items() for member in members]), 13)
check("native_capability_members", calls([(owner, member) for owner, members in capability_denials.items() for member in members]), 13)
check("native_effects", refs(["UIVisualEffectView", "UIVisualEffect", "UIBlurEffect", "UIVibrancyEffect"]), 8)
check("clang_target6", refs(["UILayoutGuide"]), 5, True, errors=["only available in iOS 9"], extra=["-clang-target", "armv7-apple-ios6.0"])
check("clang_simulator", refs(["UILayoutGuide"]), 5, True, errors=["only available in iOS 9"], extra=["-clang-target", "i386-apple-ios5.0-simulator"])
check("swift7_clang5", refs(["UILayoutGuide"]), 7, True, errors=["only available in iOS 9"], extra=["-clang-target", "armv7-apple-ios5.0"])
check("swift5_clang7", refs(["UILayoutGuide"]), 5, True, errors=["only available in iOS 9"], extra=["-clang-target", "armv7-apple-ios7.0"])
check("unrelated", "import Unrelated\nfunc f(_ x: Unrelated.UIStackView) {}\n", 5, True, errors=["only available in iOS 9"])
check("vfl", "import UIKit\nfunc f(_ x: UIKit.SDKObject) -> UIKit.SDKObject { UIKit.NSLayoutConstraint.visualFormat(x, options:x, metrics:x, views:x) }\n", 5, True)
check("priority", calls([("NSLayoutConstraint", "priority")]), 5, True)
check("directional_type", refs(["NSDirectionalEdgeInsets"]), 5, True)
check("directional_type_native5", refs(["NSDirectionalEdgeInsets"]), 5, False, errors=["only available in iOS 11"])
# Native-signature declarations still point to the exact shipped facade symbols.
# Escape the address of the empty synthetic C payload: merely returning its
# value allows IRGen to omit the constant entirely (the real SDK uses floats).
facades = {"UILayoutGuide": "UICLayoutGuide", "NSLayoutAnchor": "UICLayoutAnchor",
           "NSLayoutXAxisAnchor": "UICXAxisAnchor", "NSLayoutYAxisAnchor": "UICYAxisAnchor",
           "NSLayoutDimension": "UICLayoutDimension", "UIRefreshControl": "UICRefreshControl",
           "UIStackView": "UICStackView"}
facades.update({name: "IBP" + name for name, (intro, _, _) in classes.items() if intro == 13})
protocols = ("NSCollectionLayoutContainer", "NSCollectionLayoutEnvironment", "NSCollectionLayoutVisibleItem")
ir_source = "import UIKit\n" + "".join("class Probe_%s: UIKit.%s {}\n" % (name, name) for name in facades)
ir_source += "public func zeroAddress() -> UIKit.SDKObject { UIKit.directionalZeroAddress() }\n"
def conformances(native):
    return "".join("class Conformance_%s: UIKit.SDKObject, UIKit.%s {\nfunc probe_familyBaseline() -> UIKit.SDKObject { self }\n%s\n}\n" % (name, name, "func probe_traitCollection() -> UIKit.SDKObject { self }" if native and name == "NSCollectionLayoutEnvironment" else "") for name in protocols)
ir = check("linkage", ir_source + conformances(False), 5, True, emit_ir=True)
for runtime in facades.values():
    assert "OBJC_CLASS_$_" + runtime in ir, runtime
    assert "OBJC_METACLASS_$_" + runtime in ir, runtime
for protocol in protocols:
    assert 'c"IBP' + protocol + '\\00"' in ir, protocol
assert "_IBPNSDirectionalEdgeInsetsZero" in ir
native_ir = check("native_linkage", ir_source + conformances(True), 13, emit_ir=True)
for public in facades:
    assert "OBJC_CLASS_$_" + public in native_ir, public
for runtime in facades.values():
    assert "OBJC_CLASS_$_" + runtime not in native_ir, runtime
for protocol in protocols:
    assert 'c"' + protocol + '\\00"' in native_ir, protocol
    assert 'c"IBP' + protocol + '\\00"' not in native_ir, protocol
print("PASS: %d native UIKit family regression invocations" % runs)
