// Non-UI test: no windows, application, collection allocation, or event-loop registration.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PSTCollectionView.h"
#include <stdio.h>
#include <string.h>
@interface RouteProtocolSource:NSObject<PSTCollectionViewDataSource,PSTCollectionViewDelegateFlowLayout,PSTCollectionViewDataSourcePrefetching> @end
@implementation RouteProtocolSource
- (NSInteger)collectionView:(PSTCollectionView*)cv numberOfItemsInSection:(NSInteger)section{return 0;}
- (PSTCollectionViewCell*)collectionView:(PSTCollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)path{return nil;}
- (void)collectionView:(PSTCollectionView*)cv prefetchItemsAtIndexPaths:(NSArray*)paths{}
@end
#ifdef ROUTE_SWIFT_PROTOCOLS
extern id routeSwiftProtocolObject(void);
extern int32_t routeSwiftCheckProtocols(id object);
#endif
static int failures,checks;
static void check(BOOL ok,const char*s){checks++;if(!ok)failures++;printf("%s %s\n",ok?"PASS":"FAIL",s);}
int main(void){@autoreleasepool{
 setvbuf(stdout,NULL,_IONBF,0);
 Protocol *native[]={@protocol(UICollectionViewDataSource),@protocol(UICollectionViewDelegate),@protocol(UICollectionViewDelegateFlowLayout),@protocol(UICollectionViewDataSourcePrefetching)};
 Protocol *vendored[]={@protocol(PSTCollectionViewDataSource),@protocol(PSTCollectionViewDelegate),@protocol(PSTCollectionViewDelegateFlowLayout),@protocol(PSTCollectionViewDataSourcePrefetching)};
 NSObject *source=[RouteProtocolSource new];
 for(unsigned i=0;i<4;i++){
  printf("native=%s fallback=%s\n",protocol_getName(native[i]),protocol_getName(vendored[i]));
  check(protocol_isEqual(native[i],vendored[i]),"protocol runtime identities match");
  check(native[i]==vendored[i],"protocol references canonicalised");
  check([source conformsToProtocol:native[i]],"fallback-declared source conforms to native protocol");
 }
#ifdef ROUTE_SWIFT_PROTOCOLS
 check(routeSwiftCheckProtocols(source)==0,"Swift casts fallback-declared ObjC source to all native protocols");
 id swiftSource=routeSwiftProtocolObject();
 check(routeSwiftCheckProtocols(swiftSource)==0,"Swift casts Swift source to all native protocols");
 for(unsigned i=0;i<4;i++){
  check([swiftSource conformsToProtocol:native[i]],"Swift source conforms to SDK protocol");
  check([swiftSource conformsToProtocol:vendored[i]],"Swift source conforms to fallback protocol");
 }
#endif
 check([UICollectionViewController conformsToProtocol:@protocol(UICollectionViewDataSource)],"selected controller conforms to native source protocol");
 check([UICollectionViewController conformsToProtocol:@protocol(UICollectionViewDelegate)],"selected controller conforms to native delegate protocol");
 printf("RESULT %s checks=%d failures=%d\n",failures?"FAIL":"PASS",checks,failures);return failures?2:0;
}}
