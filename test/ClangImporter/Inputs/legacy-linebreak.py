"""Synthetic SDK regression for the real UIKit line-break enum signatures.

All generated files stay below the supplied scratch directory. No SDK or runtime
is patched. Pass a frontend with ordinary target Swift standard-library modules.
"""
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
compiler = sys.argv[2:]
sdk = root / 'sdk'
frameworks = sdk / 'System/Library/Frameworks'


def framework(name, text):
    base = frameworks / (name + '.framework')
    (base / 'Headers').mkdir(parents=True, exist_ok=True)
    (base / 'Modules').mkdir(parents=True, exist_ok=True)
    (base / 'Headers' / (name + '.h')).write_text(text)
    (base / 'Modules/module.modulemap').write_text(
        'framework module %s { umbrella header "%s.h" export * }\n' % (name, name))


def enum(name, prefix, availability=''):
    # Match the actual SDK's named, fixed NSInteger NS_ENUM representation.
    names = ('ByWordWrapping', 'ByCharWrapping', 'ByClipping',
             'ByTruncatingHead', 'ByTruncatingTail', 'ByTruncatingMiddle')
    if name == 'UILineBreakMode':
        names = ('WordWrap', 'CharacterWrap', 'Clip',
                 'HeadTruncation', 'TailTruncation', 'MiddleTruncation')
    return ('typedef enum %s : NSInteger %s %s;\nenum %s : NSInteger {\n' %
            (name, name, availability, name) +
            ',\n'.join('  %s%s = %d' % (prefix, case, i)
                       for i, case in enumerate(names)) + '\n};\n')

preamble = '''#pragma once
typedef long NSInteger;
typedef struct CGSize { float width; float height; } CGSize;
__attribute__((objc_root_class)) @interface NSObject @end
@interface UIFont : NSObject @end
@interface NSString : NSObject @end
'''
legacy = enum('UILineBreakMode', 'UILineBreakMode')
modern = enum('NSLineBreakMode', 'NSLineBreak',
              '__attribute__((availability(ios,introduced=6.0)))')
api = '''@interface UILabel : NSObject
@property(nonatomic) NSLineBreakMode lineBreakMode;
@end
@interface NSString (UIStringDrawing)
- (CGSize)sizeWithFont:(UIFont *)font constrainedToSize:(CGSize)size lineBreakMode:(UILineBreakMode)mode;
@end
'''
framework('UIKit', preamble + legacy + modern + api)
framework('ExternalCategory', '''#import <UIKit/UIKit.h>
@interface NSString (ExternalStringDrawing)
- (CGSize)sizeWithFont:(UIFont *)font forWidth:(float)width lineBreakMode:(UILineBreakMode)mode;
@end
''')
framework('Lookalike', '#pragma once\ntypedef long NSInteger;\n' + legacy + modern)

runs = 0

def check(label, text, target='armv7-apple-ios5.0', legacy_mode=True,
          success=True, errors=(), extra=()):
    global runs
    path = root / (label + '.swift')
    path.write_text(text)
    args = ['-typecheck', str(path), '-sdk', str(sdk), '-target', target,
            '-module-cache-path', str(root / ('cache-' + label))]
    if legacy_mode:
        args += ['-enable-legacy-ios5-runtime']
    result = subprocess.run(compiler + args + list(extra), capture_output=True, text=True)
    (root / (label + '.stderr')).write_text(result.stderr)
    assert (result.returncode == 0) == success, (label, result.stderr)
    for error in errors:
        assert error in result.stderr, (label, error, result.stderr)
    runs += 1
    print('PASS', label)

# The call is the real SDK API: no app-side integer conversion or enum adapter.
client = '''import UIKit
import ExternalCategory
func draw(_ text: NSString, _ label: UILabel, _ font: UIFont, _ size: CGSize) {
  _ = text.size(with: font, constrainedTo: size, lineBreakMode: label.lineBreakMode)
  _ = text.size(with: font, forWidth: 10, lineBreakMode: label.lineBreakMode)
  label.lineBreakMode = .byWordWrapping
  label.lineBreakMode = .byCharWrapping
  label.lineBreakMode = .byClipping
  label.lineBreakMode = .byTruncatingHead
  label.lineBreakMode = .byTruncatingTail
  label.lineBreakMode = .byTruncatingMiddle
}
'''
check('armv7', client)
check('armv7s', client, target='armv7s-apple-ios5.1')
# Canonicalizing old method parameter types must not corrupt the genuine legacy
# enum declaration, its cases, or its own typed identity.
check('legacy-enum-identity', '''import UIKit
func identity(_ value: UILineBreakMode) -> UILineBreakMode { value }
func originalCases() -> [UILineBreakMode] {
  [.wordWrap, .characterWrap, .clip, .headTruncation, .tailTruncation, .middleTruncation]
}
''')
# Native target / opt-out retain two genuinely distinct imported enum types.
check('native6', client, target='armv7-apple-ios6.0', success=False,
      errors=('UILineBreakMode', 'NSLineBreakMode'))
check('optout', client, legacy_mode=False, success=False,
      errors=('UILineBreakMode',))
check('clang6', client, success=False, errors=('UILineBreakMode',),
      extra=('-clang-target', 'armv7-apple-ios6.0'))
# Referenced declaration ownership, not the category owner, decides the mapping.
check('lookalike', '''import Lookalike
func identity(_ value: UILineBreakMode) -> UILineBreakMode { value }
func unrelated(_ value: NSLineBreakMode) -> UILineBreakMode { value }
''', success=False, errors=('UILineBreakMode', 'NSLineBreakMode'))
# Fail closed when the SDK has no modern enum, rather than importing an Int API.
framework('UIKit', preamble + legacy + '''
@interface NSString (UIStringDrawing)
- (CGSize)sizeWithFont:(UIFont *)font constrainedToSize:(CGSize)size lineBreakMode:(UILineBreakMode)mode;
@end
''')
check('missing-modern', '''import UIKit
func draw(_ text: NSString, _ font: UIFont, _ size: CGSize, _ mode: UILineBreakMode) {
  _ = text.size(with: font, constrainedTo: size, lineBreakMode: mode)
}
''', success=False, errors=('size',))
print('PASS %d line-break importer checks' % runs)
