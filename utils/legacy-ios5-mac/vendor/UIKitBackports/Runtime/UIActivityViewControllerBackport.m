//
//  UIActivityViewControllerBackport.m
//  UIKitBackports runtime
//
//  Genuine `UIActivityViewController` (UIKit 6) for the legacy runtime. iOS 5 has
//  no activity-service framework, so the controller presents the sharing actions
//  that iOS 5 itself provides — save an image to the photo library, copy items to
//  the pasteboard, and open a URL in Safari. It is the same class name and the
//  same public initializer; it is not Apple's iOS 6+ sheet, which has no iOS 5
//  implementation (no extensions, no AirDrop, no activity services).
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const void *UIActivityItemsKey = &UIActivityItemsKey;

@interface UICLegacyActivityViewController : UIViewController <UIActionSheetDelegate>
- (instancetype)initWithActivityItems:(NSArray *)activityItems applicationActivities:(NSArray *)activities;
@end

@implementation UICLegacyActivityViewController {
    NSArray *_items;
    UIActionSheet *_sheet;
}

- (instancetype)initWithActivityItems:(NSArray *)activityItems applicationActivities:(NSArray *)activities {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        // Custom application activities belong to the iOS 6 activity framework;
        // they cannot be run here, so the sheet only offers system actions.
        _items = [activityItems copy] ?: @[];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_sheet) return;
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:nil
                                                     delegate:self
                                            cancelButtonTitle:@"Cancel"
                                       destructiveButtonTitle:nil
                                            otherButtonTitles:nil];
    BOOL hasImage = NO, hasURL = NO, hasText = NO;
    for (id item in _items) {
        if ([item isKindOfClass:[UIImage class]]) hasImage = YES;
        else if ([item isKindOfClass:[NSURL class]]) hasURL = YES;
        else if ([item isKindOfClass:[NSString class]]) hasText = YES;
    }
    if (hasImage) [sheet addButtonWithTitle:@"Save Image"];
    if (hasImage || hasText || hasURL) [sheet addButtonWithTitle:@"Copy"];
    if (hasURL) [sheet addButtonWithTitle:@"Open in Safari"];
    if (sheet.numberOfButtons <= 1) {
        // Nothing this system can do with the items; dismiss immediately.
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    _sheet = sheet;
    [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    NSString *title = [sheet buttonTitleAtIndex:index];
    if ([title isEqualToString:@"Save Image"]) {
        for (id item in _items)
            if ([item isKindOfClass:[UIImage class]])
                UIImageWriteToSavedPhotosAlbum(item, nil, NULL, NULL);
    } else if ([title isEqualToString:@"Copy"]) {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        if (_items.count == 1) pasteboard.image = nil;
        NSMutableArray *copied = [NSMutableArray array];
        for (id item in _items) {
            if ([item isKindOfClass:[UIImage class]]) pasteboard.image = item;
            else if ([item isKindOfClass:[NSURL class]]) [copied addObject:[(NSURL *)item absoluteString]];
            else if ([item isKindOfClass:[NSString class]]) [copied addObject:item];
        }
        if (copied.count) pasteboard.string = [copied componentsJoinedByString:@"\n"];
    } else if ([title isEqualToString:@"Open in Safari"]) {
        for (id item in _items)
            if ([item isKindOfClass:[NSURL class]]) { [[UIApplication sharedApplication] openURL:item]; break; }
    }
    _sheet = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionSheetCancel:(UIActionSheet *)sheet {
    _sheet = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static void UICAddMethodIfAbsent(Class cls, SEL selector, IMP implementation, const char *types) {
    if (cls && !class_getInstanceMethod(cls, selector))
        class_addMethod(cls, selector, implementation, types);
}

__attribute__((constructor)) static void UICInstallActivityViewController(void) {
    @autoreleasepool {
        // Real UIKit always wins: register only when the class is absent.
        if (objc_getClass("UIActivityViewController")) return;
        Class created = objc_allocateClassPair([UIViewController class], "UIActivityViewController", 0);
        if (!created) return;
        UICAddMethodIfAbsent(created, @selector(initWithActivityItems:applicationActivities:),
            class_getMethodImplementation([UICLegacyActivityViewController class],
                @selector(initWithActivityItems:applicationActivities:)), "@@:@@");
        UICAddMethodIfAbsent(created, @selector(viewDidAppear:),
            class_getMethodImplementation([UICLegacyActivityViewController class], @selector(viewDidAppear:)), "v@:c");
        UICAddMethodIfAbsent(created, @selector(actionSheet:clickedButtonAtIndex:),
            class_getMethodImplementation([UICLegacyActivityViewController class],
                @selector(actionSheet:clickedButtonAtIndex:)), "v@:@i");
        UICAddMethodIfAbsent(created, @selector(actionSheetCancel:),
            class_getMethodImplementation([UICLegacyActivityViewController class], @selector(actionSheetCancel:)), "v@:@");
        objc_registerClassPair(created);
    }
}
