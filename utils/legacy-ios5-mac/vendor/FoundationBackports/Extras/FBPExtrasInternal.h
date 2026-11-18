// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Installers split per domain; not part of the public runtime surface.
#import <Foundation/Foundation.h>

void FBPInstallCalendarExtras(void);
void FBPInstallStringExtras(void);
void FBPInstallCharacterSetExtras(void);
void FBPInstallSubscriptExtras(void);

// objc_lookUpClass cache (FBPClassLookupCache.m). Scheduled from +load; installs on the main queue.
// Classes are passed as void * so ARC-compiled callers never retain them.
typedef void *(*FBPLookUpClassFunction)(const char *name);
void FBPScheduleClassLookupCache(void);
void FBPInstallClassLookupCache(void);
void *FBPCachedLookUpClass(const char *name);
void FBPClassLookupCacheStatistics(unsigned *patchedSlots, unsigned *entries);

// Test hooks: install the selectors on an arbitrary class so host tests can
// verify the class_addMethod-only-when-absent behaviour even though macOS
// Foundation already provides the native methods.
void FBPInstallCalendarExtrasOnClass(Class target);
void FBPInstallStringExtrasOnClass(Class target);
void FBPInstallCharacterSetExtrasOnClass(Class target);
void FBPInstallSubscriptExtrasOnClasses(Class array, Class mutableArray, Class dictionary,
                                        Class mutableDictionary, Class orderedSet, Class mutableOrderedSet);
// Routes cache misses to `fallback` without patching any image (host tests).
void FBPSetClassLookupFallbackForTesting(FBPLookUpClassFunction fallback);
