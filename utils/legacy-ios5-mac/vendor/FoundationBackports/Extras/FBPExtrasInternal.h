// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Installers split per domain; not part of the public runtime surface.
#import <Foundation/Foundation.h>

void FBPInstallCalendarExtras(void);
void FBPInstallStringExtras(void);
void FBPInstallCharacterSetExtras(void);

// Test hooks: install the selectors on an arbitrary class so host tests can
// verify the class_addMethod-only-when-absent behaviour even though macOS
// Foundation already provides the native methods.
void FBPInstallCalendarExtrasOnClass(Class target);
void FBPInstallStringExtrasOnClass(Class target);
void FBPInstallCharacterSetExtrasOnClass(Class target);
