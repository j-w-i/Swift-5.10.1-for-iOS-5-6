// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
#import "FoundationBackportsCore.h"
#import <objc/runtime.h>
@interface FBPTimerTarget : NSObject
@property(copy) void (^block)(NSTimer *);
- (void)fire:(NSTimer *)timer;
@end
@implementation FBPTimerTarget
- (void)fire:(NSTimer *)timer { if(_block) _block(timer); }
@end
NSTimer *FBPTimerWithFireDate(NSDate *date,NSTimeInterval interval,BOOL repeats,void (^block)(NSTimer *)) {
 if(!block) [NSException raise:NSInvalidArgumentException format:@"nil timer block"];
 FBPTimerTarget *target=[FBPTimerTarget new]; target.block=block;
 // NSTimer retains its target until invalidation; its userInfo remains nil just
 // like native block timers. No timer<->block association or recursive swizzle.
 return [[NSTimer alloc] initWithFireDate:date interval:interval target:target selector:@selector(fire:) userInfo:nil repeats:repeats];
}
NSTimer *FBPTimerWithTimeInterval(NSTimeInterval interval,BOOL repeats,void (^block)(NSTimer *)) { return FBPTimerWithFireDate([NSDate dateWithTimeIntervalSinceNow:interval],interval,repeats,block); }
NSTimer *FBPScheduledTimerWithTimeInterval(NSTimeInterval interval,BOOL repeats,void (^block)(NSTimer *)) { NSTimer *timer=FBPTimerWithTimeInterval(interval,repeats,block); [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode]; return timer; }
static NSTimer *TimerFactory(id self,SEL cmd,NSTimeInterval interval,BOOL repeats,void (^block)(NSTimer *)) { return FBPTimerWithTimeInterval(interval,repeats,block); }
static NSTimer *TimerScheduledFactory(id self,SEL cmd,NSTimeInterval interval,BOOL repeats,void (^block)(NSTimer *)) { return FBPScheduledTimerWithTimeInterval(interval,repeats,block); }
static NSTimer *TimerInitializer(id __attribute__((ns_consumed)) self,SEL cmd,NSDate *date,NSTimeInterval interval,BOOL repeats,void (^block)(NSTimer *)) __attribute__((ns_returns_retained));
static NSTimer *TimerInitializer(id __attribute__((ns_consumed)) self,SEL cmd,NSDate *date,NSTimeInterval interval,BOOL repeats,void (^block)(NSTimer *)) {
 if(!block) [NSException raise:NSInvalidArgumentException format:@"nil timer block"];
 FBPTimerTarget *target=[FBPTimerTarget new]; target.block=block;
 return [self initWithFireDate:date interval:interval target:target selector:@selector(fire:) userInfo:nil repeats:repeats];
}
@interface FBPTimerInstaller : NSObject @end
@implementation FBPTimerInstaller
+ (void)load {
 Class cls=[NSTimer class],meta=object_getClass(cls);
 // Obtain encodings from compiler-generated methods: BOOL differs armv7/x86_64.
 Method factory=class_getClassMethod(self,@selector(factory:repeats:block:));
 Method init=class_getInstanceMethod(self,@selector(initTimer:interval:repeats:block:));
 SEL a=sel_registerName("timerWithTimeInterval:repeats:block:"),b=sel_registerName("scheduledTimerWithTimeInterval:repeats:block:"),c=sel_registerName("initWithFireDate:interval:repeats:block:");
#if FBP_FORCE_TEST_RUNTIME
 // Exercise the exact installation/IMP path without replacing native methods.
 a=sel_registerName("fbp_timerWithTimeInterval:repeats:block:"); b=sel_registerName("fbp_scheduledTimerWithTimeInterval:repeats:block:"); c=sel_registerName("initFBPWithFireDate:interval:repeats:block:");
#endif
 if(!class_getClassMethod(cls,a)) class_addMethod(meta,a,(IMP)TimerFactory,method_getTypeEncoding(factory));
 if(!class_getClassMethod(cls,b)) class_addMethod(meta,b,(IMP)TimerScheduledFactory,method_getTypeEncoding(factory));
 if(!class_getInstanceMethod(cls,c)) class_addMethod(cls,c,(IMP)TimerInitializer,method_getTypeEncoding(init));
}
+ (id)factory:(NSTimeInterval)t repeats:(BOOL)r block:(void (^)(NSTimer *))b { return nil; }
- (id)initTimer:(NSDate *)d interval:(NSTimeInterval)t repeats:(BOOL)r block:(void (^)(NSTimer *))b { return nil; }
@end
