"""Inherited optional ObjC witnesses: synthetic SDK, no installed stdlib/runtime."""
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
compiler = sys.argv[2:]
framework = root / 'sdk/System/Library/Frameworks/UIKit.framework'
(framework / 'Headers').mkdir(parents=True, exist_ok=True)
(framework / 'Modules').mkdir(parents=True, exist_ok=True)
(framework / 'Headers/UIKit.h').write_text('''#pragma once
#define AV(v) __attribute__((availability(ios,introduced=v)))
__attribute__((objc_root_class)) @interface SDKObject @end
@interface UIGestureRecognizer : SDKObject @end
@interface UIView : SDKObject
- (_Bool)gestureRecognizerShouldBegin:(UIGestureRecognizer * _Nonnull)recognizer AV(6.0);
@end
AV(3.2) @protocol UIGestureRecognizerDelegate
@optional
- (_Bool)gestureRecognizerShouldBegin:(UIGestureRecognizer * _Nonnull)recognizer;
@end
AV(3.2) @protocol RequiredGestureRecognizerDelegate
- (_Bool)gestureRecognizerShouldBegin:(UIGestureRecognizer * _Nonnull)recognizer;
@end
// The rule is about inherited optional foreign witnesses, not API-name matching.
@interface OtherBase : SDKObject
- (void)futureHook AV(7.0);
@end
@protocol OtherDelegate
@optional
- (void)futureHook;
@end
''')
(framework / 'Modules/module.modulemap').write_text(
    'framework module UIKit { umbrella header "UIKit.h" export * }\n')
# Loading Foundation permits explicit @objc Swift witnesses; no runtime or
# Foundation API declarations are needed.
foundation = root / 'sdk/System/Library/Frameworks/Foundation.framework'
(foundation / 'Headers').mkdir(parents=True, exist_ok=True)
(foundation / 'Modules').mkdir(parents=True, exist_ok=True)
(foundation / 'Headers/Foundation.h').write_text('// Empty synthetic Foundation.\n')
(foundation / 'Modules/module.modulemap').write_text(
    'framework module Foundation { umbrella header "Foundation.h" export * }\n')
# The importer's existing UIKit resource contract is orthogonal to this test.
resource = root / 'resource/legacy-collection/Headers'
resource.mkdir(parents=True, exist_ok=True)
(resource / 'UIKitLegacyCollection.h').write_text(
    '// This fixture needs no collection declarations.\n')

# A minimal Swift module permits real Bool signatures and optional dispatch,
# without depending on a cross-compiled standard library or installed SDK.
preamble = '''public struct Bool {}
public typealias Void = ()
public typealias CBool = Bool
public enum Optional<Wrapped> { case none; case some(Wrapped) }
func _diagnoseUnexpectedNilOptional(_filenameStart: Builtin.RawPointer,
    _filenameLength: Builtin.Word, _filenameIsASCII: Builtin.Int1,
    _line: Builtin.Word) {}
import UIKit
import Foundation
'''
dispatch = '''func dispatch(_ delegate: UIGestureRecognizerDelegate,
              _ recognizer: UIGestureRecognizer) -> Bool? {
  delegate.gestureRecognizerShouldBegin?(recognizer)
}
'''
optional = 'class Subclass : UIView, UIGestureRecognizerDelegate {}\n' + dispatch
direct = '''func direct(_ view: UIView, _ recognizer: UIGestureRecognizer) -> Bool {
  view.gestureRecognizerShouldBegin(recognizer)
}
'''
other = '''class OtherSubclass : OtherBase, OtherDelegate {}
func dispatchOther(_ delegate: OtherDelegate) { delegate.futureHook?() }
'''
protocol_error = ("protocol 'UIGestureRecognizerDelegate' requires "
                  "'gestureRecognizerShouldBegin' to be available in iOS 5.0 and newer")
required_error = protocol_error.replace('UIGestureRecognizerDelegate',
                                         'RequiredGestureRecognizerDelegate')
direct_error = "'gestureRecognizerShouldBegin' is only available in iOS 6.0 or newer"
results = []


def check(label, source, target='armv7-apple-ios5.0', legacy=True, error=None,
          extra=(), sil_checks=()):
    path = root / (label + '.swift')
    path.write_text(preamble + source)
    args = compiler + [str(path), '-parse-stdlib', '-module-name', 'Swift',
                       '-sdk', str(root / 'sdk'), '-resource-dir', str(root / 'resource'),
                       '-target', target, '-module-cache-path', str(root / 'cache')]
    if legacy:
        args += ['-enable-legacy-ios5-runtime']
    output = root / (label + '.sil')
    args += ['-emit-silgen', '-o', str(output)] if sil_checks else ['-typecheck']
    result = subprocess.run(args + list(extra), text=True, capture_output=True)
    (root / (label + '.log')).write_text(result.stdout + result.stderr)
    (root / (label + '.command')).write_text(repr(args + list(extra)) + '\n')
    if error:
        passed = result.returncode != 0 and error in result.stderr
    else:
        passed = result.returncode == 0
        if passed and sil_checks:
            sil = output.read_text()
            passed = all(text in sil for text in sil_checks)
    results.append((label, passed))
    print(('PASS' if passed else 'FAIL'), label)
    if not passed:
        print(result.stderr)


# Only the opted-in, actual native ARMv7 iOS 5 configurations may drop the
# unavailable inherited method. Optional invocation must still use ObjC lookup.
optional_dispatch = ('dynamic_method_br',
                     '#UIGestureRecognizerDelegate.gestureRecognizerShouldBegin!foreign')
check('legacy5', optional, sil_checks=optional_dispatch)
check('legacy51', optional, target='armv7-apple-ios5.1', sil_checks=optional_dispatch)
check('legacy_clang_v7s', optional,
      extra=('-clang-target', 'armv7s-apple-ios5.0'))
check('legacy_explicit_clang5', optional,
      extra=('-clang-target', 'armv7-apple-ios5.0'))
check('legacy_class_marking', optional, legacy=False,
      extra=('-enable-legacy-ios5-class-marking',))
check('legacy_extension', '''class Subclass : UIView {}
extension Subclass : UIGestureRecognizerDelegate {}
''' + dispatch, sil_checks=optional_dispatch)
check('legacy_other_optional', other,
      sil_checks=('dynamic_method_br', '#OtherDelegate.futureHook!foreign'))

# Keep all explicit witness and normal availability checking intact.
check('optional_dispatch5', dispatch, sil_checks=optional_dispatch)
check('required', 'class Required : UIView, RequiredGestureRecognizerDelegate {}\n',
      error=required_error)
check('direct5', direct, error=direct_error)
check('direct_guarded5', '@available(iOS 6.0, *)\n' + direct)
check('same_class', 'extension UIView : UIGestureRecognizerDelegate {}\n',
      error=protocol_error)
check('explicit_swift', '''class Explicit : SDKObject, UIGestureRecognizerDelegate {
  @available(iOS 6.0, *)
  @objc func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool { Bool() }
}
''', error=protocol_error)
check('inherited_swift', '''class SwiftBase : SDKObject {
  @available(iOS 6.0, *)
  @objc func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool { Bool() }
}
class SwiftSubclass : SwiftBase, UIGestureRecognizerDelegate {}
''', error=protocol_error)
check('available_swift', '''class Explicit : SDKObject, UIGestureRecognizerDelegate {
  @objc func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool { Bool() }
}
''')

# No global semantic change: disabled legacy mode and mismatched actual Clang
# targets retain the old conformance diagnostic, including simulator/Catalyst.
check('disabled5', optional, legacy=False, error=protocol_error)
check('disabled_explicitly', optional, legacy=False,
      extra=('-enable-legacy-ios5-class-marking',
             '-disable-legacy-ios5-class-marking'), error=protocol_error)
check('clang6', optional, extra=('-clang-target', 'armv7-apple-ios6.0'),
      error=protocol_error)
check('clang7', optional, extra=('-clang-target', 'armv7-apple-ios7.0'),
      error=protocol_error)
check('clang_simulator', optional,
      extra=('-clang-target', 'i386-apple-ios5.0-simulator'), error=protocol_error)
check('clang_catalyst', optional,
      extra=('-clang-target', 'x86_64-apple-ios13.1-macabi'), error=protocol_error)
check('clang_non_v7', optional,
      extra=('-clang-target', 'armv6-apple-ios5.0'), error=protocol_error)
check('simulator5', optional, target='i386-apple-ios5.0-simulator',
      legacy=False, error=protocol_error)

# Native iOS 6 still rejects a genuinely newer optional inherited witness.
check('native6_future', other, target='armv7-apple-ios6.0',
      error="protocol 'OtherDelegate' requires 'futureHook()' to be available in iOS 6.0 and newer")

# Native UIView methods remain inherited on iOS 6/7 with either opt-in state;
# existential optional dispatch remains dynamic and direct calls remain native.
for version in (6, 7):
    for legacy in (False, True):
        check('native%d_%s' % (version, legacy), optional + direct,
              target='armv7-apple-ios%d.0' % version, legacy=legacy,
              sil_checks=optional_dispatch + ('#UIView.gestureRecognizerShouldBegin!foreign',))

failed = [label for label, passed in results if not passed]
print('%d/%d checks passed' % (len(results) - len(failed), len(results)))
if failed:
    raise SystemExit('Failed: ' + ', '.join(failed))
