// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
#import "FoundationBackportsExtras.h"
#import "FBPExtrasInternal.h"

@interface FBPFoundationExtrasLoader : NSObject
@end

@implementation FBPFoundationExtrasLoader
+ (void)load {
    FBPInstallFoundationExtras();
}
@end

void FBPInstallFoundationExtras(void) {
    FBPInstallCalendarExtras();
    FBPInstallStringExtras();
    FBPInstallCharacterSetExtras();
}
