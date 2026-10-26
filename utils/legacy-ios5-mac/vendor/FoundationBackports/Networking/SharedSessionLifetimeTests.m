// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
#import "FBPURLSession.h"
#include <stdio.h>
#include <stdlib.h>
static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static void Turn(void) { @autoreleasepool { [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; } }
static BOOL Empty(FBPURLSession *session) {
 dispatch_semaphore_t done=dispatch_semaphore_create(0); __block BOOL empty=NO;
 [session getTasksWithCompletionHandler:^(NSArray *data,NSArray *upload,NSArray *download) { empty=!data.count&&!upload.count&&!download.count; dispatch_semaphore_signal(done); }];
 CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0);
 return empty;
}
int main(void) { @autoreleasepool {
 CHECK(NSClassFromString(@"NSURLSession")!=Nil);
 FBPURLSession *session=[FBPURLSession sharedSession];
 CHECK([session isKindOfClass:[FBPURLSession class]]);
 CHECK([session valueForKey:@"nativeSession"]!=nil); // Exercise actual native backing.
 for(unsigned kind=0;kind<3;kind++) {
  __weak FBPURLSessionTask *weakTask=nil;
  @autoreleasepool {
   NSURL *url=[NSURL URLWithString:@"unsupported-retirement-review://local/test"];
   FBPURLSessionTask *task;
   if(kind==0) task=[session dataTaskWithURL:url];
   else if(kind==1) task=[session uploadTaskWithRequest:[NSURLRequest requestWithURL:url] fromData:[@"body" dataUsingEncoding:NSUTF8StringEncoding]];
   else task=[session downloadTaskWithURL:url];
   weakTask=task; [task resume];
   NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
   while(task.state!=FBPTaskCompleted && [deadline timeIntervalSinceNow]>0) Turn();
   CHECK(task.state==FBPTaskCompleted);
   CHECK(task.error!=nil);
  }
  NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
  while(!Empty(session) && [deadline timeIntervalSinceNow]>0) Turn();
  CHECK(Empty(session));
  while(weakTask && [deadline timeIntervalSinceNow]>0) Turn();
  CHECK(weakTask==nil);
 }
 // Repeating handler-less shared work must not accumulate terminal wrappers.
 for(unsigned i=0;i<100;i++) { @autoreleasepool { [[session dataTaskWithURL:[NSURL URLWithString:@"unsupported-retirement-review://local/repeat"]] resume]; } }
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
 while(!Empty(session) && [deadline timeIntervalSinceNow]>0) Turn();
 CHECK(Empty(session));
 printf("PASS shared native handler-less data/upload/download retirement and release (%u checks)\n",checks);
 } return 0;
}
