// Authored for the legacy iOS 5 toolchain; not part of the upstream backport.
//
// Clang emits Objective-C protocol metadata only when a translation unit refers
// to the protocol identity. The upstream sources declare
// IBPNSCollectionLayoutVisibleItem, but nothing in the component conforms to it,
// so without this file the protocol object would be absent from the image and
// Swift's protocol casts would have no runtime identity. The importer maps the
// public UIKit protocols onto these runtime protocol names, so make all three
// identities explicit. The functions are never called; they exist so the
// metadata is emitted and retained (the linker keeps a dead-stripped protocol
// referenced from __objc_protolist / used data).
#import <UIKit/UIKit.h>
#import "IBPNSCollectionLayoutContainer_Protocol.h"
#import "IBPNSCollectionLayoutEnvironment_Protocol.h"
#import "IBPNSCollectionLayoutVisibleItem.h"

Protocol *IBPCompositionalLayoutContainerProtocol(void) {
    return @protocol(IBPNSCollectionLayoutContainer);
}

Protocol *IBPCompositionalLayoutEnvironmentProtocol(void) {
    return @protocol(IBPNSCollectionLayoutEnvironment);
}

Protocol *IBPCompositionalLayoutVisibleItemProtocol(void) {
    return @protocol(IBPNSCollectionLayoutVisibleItem);
}
