// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Original implementation of NSString's iOS 7 percent-encoding APIs.
//
// Semantics match Apple's implementation (verified against native Foundation on
// the host differential tests): the input is treated as UTF-8; only ASCII
// characters that are members of the allowed set are emitted literally, every
// other byte is percent-encoded with uppercase hex digits. Non-ASCII characters
// are always percent-encoded, even if the allowed set contains them.
#import "FoundationBackportsExtras.h"
#import "FBPExtrasInternal.h"
#import <objc/runtime.h>
#import <objc/message.h>

static inline BOOL FBPIsHexDigit(unichar c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/// Native URLHostAllowedCharacterSet contains '[', ']' and ':' but Apple's
/// percent-encoder escapes those three anyway (the system CF set takes a
/// component-aware path). Our cached FBP host set and the system host set are
/// both recognised by identity (CF object pointer), so the same rule applies to
/// the sets the overlay hands us on iOS 5 without changing behaviour for plain
/// character sets that happen to have the same membership.
static BOOL FBPIsSystemCharacterSet(NSCharacterSet *set, SEL nativeSelector, NSCharacterSet *fbpSet) {
    if (!set) return NO;
    if (set == fbpSet) return YES;
    if ((__bridge CFCharacterSetRef)set == (__bridge CFCharacterSetRef)fbpSet) return YES;
    if (class_getClassMethod([NSCharacterSet class], nativeSelector)) {
        NSCharacterSet *system = ((NSCharacterSet *(*)(id, SEL))objc_msgSend)([NSCharacterSet class], nativeSelector);
        if (system && (set == system || (__bridge CFCharacterSetRef)set == (__bridge CFCharacterSetRef)system)) return YES;
    }
    return NO;
}

static BOOL FBPIsURLHostAllowedSet(NSCharacterSet *set) {
    return FBPIsSystemCharacterSet(set, @selector(URLHostAllowedCharacterSet), FBPURLHostAllowedCharacterSet());
}

static BOOL FBPIsURLPathAllowedSet(NSCharacterSet *set) {
    return FBPIsSystemCharacterSet(set, @selector(URLPathAllowedCharacterSet), FBPURLPathAllowedCharacterSet());
}

static inline unsigned char FBPHexValue(unichar c) {
    if (c >= '0' && c <= '9') return (unsigned char)(c - '0');
    if (c >= 'a' && c <= 'f') return (unsigned char)(c - 'a' + 10);
    return (unsigned char)(c - 'A' + 10);
}

static NSString *FBPPercentEncodeBytes(NSString *string, NSCharacterSet *allowedCharacters) {
    NSData *utf8 = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8) return nil;
    const unsigned char *bytes = (const unsigned char *)utf8.bytes;
    NSUInteger length = utf8.length;
    // One allocation, mutate the bytes directly: worst case is 3 output bytes per
    // input byte and escaping dominates on URL payloads.
    unsigned char *output = malloc(length * 3 + 1);
    if (!output) return nil;
    NSUInteger used = 0;
    static const char hex[] = "0123456789ABCDEF";
    BOOL hostSet = FBPIsURLHostAllowedSet(allowedCharacters);
    BOOL pathSet = FBPIsURLPathAllowedSet(allowedCharacters);
    for (NSUInteger i = 0; i < length; i++) {
        unsigned char byte = bytes[i];
        BOOL literal = NO;
        if (byte < 0x80) {
            // Native Foundation only ever leaves ASCII characters unescaped.
            literal = [allowedCharacters characterIsMember:(unichar)byte];
            if (hostSet && (byte == '[' || byte == ']' || byte == ':')) literal = NO;
            if (pathSet && byte == ':') literal = NO;
        }
        if (literal) {
            output[used++] = byte;
        } else {
            output[used++] = '%';
            output[used++] = (unsigned char)hex[byte >> 4];
            output[used++] = (unsigned char)hex[byte & 0x0F];
        }
    }
    NSString *result = [[NSString alloc] initWithBytesNoCopy:output length:used
                                                    encoding:NSUTF8StringEncoding freeWhenDone:YES];
    if (!result) free(output);
    return result;
}

/// Strict UTF-8 validation (no overlongs, surrogates or > U+10FFFF). -initWithData:
/// with NSUTF8StringEncoding is lenient on some OS releases and substitutes
/// U+FFFD, while native -stringByRemovingPercentEncoding returns nil.
static BOOL FBPIsValidUTF8(const unsigned char *bytes, NSUInteger length) {
    NSUInteger i = 0;
    while (i < length) {
        unsigned char b = bytes[i];
        NSUInteger trailing;
        uint32_t scalar;
        if (b < 0x80) { i++; continue; }
        else if ((b & 0xE0) == 0xC0) { trailing = 1; scalar = b & 0x1F; }
        else if ((b & 0xF0) == 0xE0) { trailing = 2; scalar = b & 0x0F; }
        else if ((b & 0xF8) == 0xF0) { trailing = 3; scalar = b & 0x07; }
        else return NO;
        if (i + trailing >= length) return NO;
        for (NSUInteger j = 1; j <= trailing; j++) {
            unsigned char c = bytes[i + j];
            if ((c & 0xC0) != 0x80) return NO;
            scalar = (scalar << 6) | (c & 0x3F);
        }
        static const uint32_t minimum[4] = { 0, 0x80, 0x800, 0x10000 };
        if (scalar < minimum[trailing]) return NO;
        if (scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF)) return NO;
        i += trailing + 1;
    }
    return YES;
}

static NSString *FBPPercentDecodeUTF8(NSString *string) {
    NSData *utf8 = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8) return nil;
    const unsigned char *bytes = (const unsigned char *)utf8.bytes;
    NSUInteger length = utf8.length;
    unsigned char *output = malloc(length + 1);
    if (!output) return nil;
    NSUInteger used = 0;
    for (NSUInteger i = 0; i < length; i++) {
        unsigned char byte = bytes[i];
        if (byte != '%') {
            output[used++] = byte;
            continue;
        }
        if (i + 2 >= length) { free(output); return nil; }
        unichar hi = (unichar)bytes[i + 1];
        unichar lo = (unichar)bytes[i + 2];
        if (!FBPIsHexDigit(hi) || !FBPIsHexDigit(lo)) { free(output); return nil; }
        output[used++] = (unsigned char)((FBPHexValue(hi) << 4) | FBPHexValue(lo));
        i += 2;
    }
    // An invalid UTF-8 byte sequence makes the whole decode fail, exactly like
    // -stringByRemovingPercentEncoding.
    if (!FBPIsValidUTF8(output, used)) { free(output); return nil; }
    NSString *result = [[NSString alloc] initWithBytesNoCopy:output length:used
                                                    encoding:NSUTF8StringEncoding freeWhenDone:YES];
    if (!result) free(output);
    return result;
}

NSString * _Nullable FBPNSStringAddingPercentEncoding(NSString *string, NSCharacterSet *allowedCharacters) {
    if (!string) return nil;
    if (!allowedCharacters) return nil;
    return FBPPercentEncodeBytes(string, allowedCharacters);
}

NSString * _Nullable FBPNSStringRemovingPercentEncoding(NSString *string) {
    if (!string) return nil;
    return FBPPercentDecodeUTF8(string);
}

// MARK: - Native selector installation (only when absent)

static NSString *FBPStringAddingPercentEncodingIMP(id self, SEL _cmd, NSCharacterSet *allowedCharacters) {
    return FBPNSStringAddingPercentEncoding((NSString *)self, allowedCharacters);
}
static NSString *FBPStringRemovingPercentEncodingIMP(id self, SEL _cmd) {
    return FBPNSStringRemovingPercentEncoding((NSString *)self);
}

static void FBPStringInstallOnClass(Class target) {
    if (!target) return;
    struct { const char *name; IMP imp; const char *types; } methods[] = {
        { "stringByAddingPercentEncodingWithAllowedCharacters:", (IMP)FBPStringAddingPercentEncodingIMP, "@@:@" },
        { "stringByRemovingPercentEncoding", (IMP)FBPStringRemovingPercentEncodingIMP, "@@:" },
    };
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        SEL selector = sel_registerName(methods[i].name);
        if (class_getInstanceMethod(target, selector) == nil) {
            class_addMethod(target, selector, methods[i].imp, methods[i].types);
        }
    }
}

void FBPInstallStringExtrasOnClass(Class target) {
    FBPStringInstallOnClass(target);
}

void FBPInstallStringExtras(void) {
    FBPStringInstallOnClass([NSString class]);
}
