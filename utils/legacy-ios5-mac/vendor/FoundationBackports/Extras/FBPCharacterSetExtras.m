// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Original implementation of NSCharacterSet's iOS 7 URL allowed sets.
// The membership is Apple's exact ASCII set (verified against native Foundation
// for every Unicode scalar in the host differential tests) and the sets are
// cached; no newer private C symbols are referenced.
#import "FoundationBackportsExtras.h"
#import "FBPExtrasInternal.h"
#import <objc/runtime.h>

// Per-set dispatch_once singletons. The previous shared cache slot did an
// unsynchronized strong-pointer read outside a lock while another thread could be
// publishing the value, which is a data race on armv7 (no ordering guarantee for
// the object pointer). dispatch_once gives both the publication ordering and a
// single initializer per set.
static NSCharacterSet *gFBPURLUserAllowed = nil;
static dispatch_once_t gFBPURLUserAllowedOnce;
static NSCharacterSet *gFBPURLPasswordAllowed = nil;
static dispatch_once_t gFBPURLPasswordAllowedOnce;
static NSCharacterSet *gFBPURLHostAllowed = nil;
static dispatch_once_t gFBPURLHostAllowedOnce;
static NSCharacterSet *gFBPURLPathAllowed = nil;
static dispatch_once_t gFBPURLPathAllowedOnce;
static NSCharacterSet *gFBPURLQueryAllowed = nil;
static dispatch_once_t gFBPURLQueryAllowedOnce;
static NSCharacterSet *gFBPURLFragmentAllowed = nil;
static dispatch_once_t gFBPURLFragmentAllowedOnce;

// These are the native Foundation memberships (ASCII only):
// user/password: unreserved + sub-delims + "-._~!$&'()*+,;="
static NSString *const kFBPURLUserPasswordCharacters =
    @"!$&'()*+,-.0123456789;=ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~";
static NSString *const kFBPURLHostCharacters =
    @"!$&'()*+,-.0123456789:;=ABCDEFGHIJKLMNOPQRSTUVWXYZ[]_abcdefghijklmnopqrstuvwxyz~";
static NSString *const kFBPURLPathCharacters =
    @"!$&'()*+,-./0123456789:;=@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~";
static NSString *const kFBPURLQueryFragmentCharacters =
    @"!$&'()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~";

NSCharacterSet *FBPURLUserAllowedCharacterSet(void) {
    dispatch_once(&gFBPURLUserAllowedOnce, ^{
        gFBPURLUserAllowed = [NSCharacterSet characterSetWithCharactersInString:kFBPURLUserPasswordCharacters];
    });
    return gFBPURLUserAllowed;
}
NSCharacterSet *FBPURLPasswordAllowedCharacterSet(void) {
    dispatch_once(&gFBPURLPasswordAllowedOnce, ^{
        gFBPURLPasswordAllowed = [NSCharacterSet characterSetWithCharactersInString:kFBPURLUserPasswordCharacters];
    });
    return gFBPURLPasswordAllowed;
}
NSCharacterSet *FBPURLHostAllowedCharacterSet(void) {
    dispatch_once(&gFBPURLHostAllowedOnce, ^{
        gFBPURLHostAllowed = [NSCharacterSet characterSetWithCharactersInString:kFBPURLHostCharacters];
    });
    return gFBPURLHostAllowed;
}
NSCharacterSet *FBPURLPathAllowedCharacterSet(void) {
    dispatch_once(&gFBPURLPathAllowedOnce, ^{
        gFBPURLPathAllowed = [NSCharacterSet characterSetWithCharactersInString:kFBPURLPathCharacters];
    });
    return gFBPURLPathAllowed;
}
NSCharacterSet *FBPURLQueryAllowedCharacterSet(void) {
    dispatch_once(&gFBPURLQueryAllowedOnce, ^{
        gFBPURLQueryAllowed = [NSCharacterSet characterSetWithCharactersInString:kFBPURLQueryFragmentCharacters];
    });
    return gFBPURLQueryAllowed;
}
NSCharacterSet *FBPURLFragmentAllowedCharacterSet(void) {
    dispatch_once(&gFBPURLFragmentAllowedOnce, ^{
        gFBPURLFragmentAllowed = [NSCharacterSet characterSetWithCharactersInString:kFBPURLQueryFragmentCharacters];
    });
    return gFBPURLFragmentAllowed;
}

// MARK: - Native selector installation (only when absent)

static NSCharacterSet *FBPCharacterSetUserAllowedIMP(id self, SEL _cmd) { return FBPURLUserAllowedCharacterSet(); }
static NSCharacterSet *FBPCharacterSetPasswordAllowedIMP(id self, SEL _cmd) { return FBPURLPasswordAllowedCharacterSet(); }
static NSCharacterSet *FBPCharacterSetHostAllowedIMP(id self, SEL _cmd) { return FBPURLHostAllowedCharacterSet(); }
static NSCharacterSet *FBPCharacterSetPathAllowedIMP(id self, SEL _cmd) { return FBPURLPathAllowedCharacterSet(); }
static NSCharacterSet *FBPCharacterSetQueryAllowedIMP(id self, SEL _cmd) { return FBPURLQueryAllowedCharacterSet(); }
static NSCharacterSet *FBPCharacterSetFragmentAllowedIMP(id self, SEL _cmd) { return FBPURLFragmentAllowedCharacterSet(); }

static void FBPCharacterSetInstallOnClass(Class target) {
    if (!target) return;
    Class meta = object_getClass((id)target);
    struct { const char *name; IMP imp; const char *types; } methods[] = {
        { "URLUserAllowedCharacterSet", (IMP)FBPCharacterSetUserAllowedIMP, "@#:" },
        { "URLPasswordAllowedCharacterSet", (IMP)FBPCharacterSetPasswordAllowedIMP, "@#:" },
        { "URLHostAllowedCharacterSet", (IMP)FBPCharacterSetHostAllowedIMP, "@#:" },
        { "URLPathAllowedCharacterSet", (IMP)FBPCharacterSetPathAllowedIMP, "@#:" },
        { "URLQueryAllowedCharacterSet", (IMP)FBPCharacterSetQueryAllowedIMP, "@#:" },
        { "URLFragmentAllowedCharacterSet", (IMP)FBPCharacterSetFragmentAllowedIMP, "@#:" },
    };
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        SEL selector = sel_registerName(methods[i].name);
        if (class_getClassMethod(target, selector) == nil) {
            class_addMethod(meta, selector, methods[i].imp, methods[i].types);
        }
    }
}

void FBPInstallCharacterSetExtrasOnClass(Class target) {
    FBPCharacterSetInstallOnClass(target);
}

void FBPInstallCharacterSetExtras(void) {
    FBPCharacterSetInstallOnClass([NSCharacterSet class]);
}
