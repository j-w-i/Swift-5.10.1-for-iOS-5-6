#!/usr/bin/env python3
"""Host-only regression for public stack class -> bootstrap facade wiring.
Uses the actual registration and facade initializer code with a minimal OA mock;
physical-device tests are still required for UIKit/layout correctness.
"""
from pathlib import Path
import subprocess
import tempfile

vendor = Path(__file__).resolve().parents[1] / 'vendor/UIKitBackports'
oa = (vendor / 'OAStackView/OAStackView.m').read_text()
registration = oa[oa.index('__attribute__((constructor)) static void OAStackViewPatchEntry'):]
runtime = (vendor / 'Runtime/UIKitBackports.m').read_text()
start = runtime.index('@implementation UICStackView')
facade = runtime[start:runtime.index('@end', start) + len('@end')]
mock = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
static BOOL installed = NO, usedBeforeInstall = NO;
static void UICEnsureSwiftBridge(void) { installed = YES; }
@interface OAStackView : NSObject
- (id)initWithArrangedSubviews:(NSArray *)views;
- (id)initWithFrame:(CGRect)frame;
- (id)initWithCoder:(NSCoder *)coder;
@end
@implementation OAStackView
- (id)initWithArrangedSubviews:(NSArray *)views { self = [super init]; if (!installed) usedBeforeInstall = YES; return self; }
- (id)initWithFrame:(CGRect)frame { return [self initWithArrangedSubviews:@[]]; }
- (id)initWithCoder:(NSCoder *)coder { return [self initWithArrangedSubviews:@[]]; }
@end
@interface UICStackView : OAStackView @end
'''
main = r'''
int main(void) { @autoreleasepool {
    Class cls = objc_getClass("UIStackView");
    id stack = [[UICStackView alloc] initWithArrangedSubviews:@[@1, @2]];
    if (!stack || !cls || !installed || usedBeforeInstall) return 5;
    if (class_getSuperclass(cls) != [UICStackView class]) return 6;
    puts("PASS public stack first-use runs facade bootstrap before arranged-subview setup");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='stack-registration-test-') as directory:
    root = Path(directory)
    for mode in ('fixed', 'old-parent'):
        code = registration if mode == 'fixed' else registration.replace('objc_allocateClassPair(base, "UIStackView", 0)', 'objc_allocateClassPair(OAStackView.class, "UIStackView", 0)')
        source = root / (mode + '.m')
        source.write_text(mock + facade + '\n' + code + main)
        binary = root / mode
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', str(source), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if mode == 'fixed':
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip())
        else:
            assert result.returncode == 5, (result.returncode, result.stdout, result.stderr)
            print('PASS negative control: direct OA parent skips bootstrap')
