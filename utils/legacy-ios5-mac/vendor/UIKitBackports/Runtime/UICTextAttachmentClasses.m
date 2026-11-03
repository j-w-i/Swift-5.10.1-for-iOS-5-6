//
//  UICTextAttachmentClasses.m
//  UIKitBackports runtime
//
//  Genuine `NSTextAttachment` and `NSTextContainer` model objects (UIKit 7) for
//  the legacy runtime. They keep their real class names, properties and method
//  signatures. What they cannot provide is the iOS 7 text system that lays
//  attachments out inside text: no NSLayoutManager/text container layout exists
//  on iOS 5, so an attachment's `attachmentBounds...` value is a model answer,
//  not proof of inline rendering. Classes are registered only when absent, so
//  real UIKit always wins.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const void *UICAttachmentImageKey = &UICAttachmentImageKey;
static const void *UICAttachmentBoundsKey = &UICAttachmentBoundsKey;
static const void *UICContainerSizeKey = &UICContainerSizeKey;

#pragma mark - NSTextContainer

@interface UICLegacyTextContainer : NSObject
- (instancetype)initWithSize:(CGSize)size;
- (CGSize)size;
- (void)setSize:(CGSize)size;
@end

@implementation UICLegacyTextContainer
- (instancetype)initWithSize:(CGSize)size {
    self = [super init];
    if (self) [self setSize:size];
    return self;
}
- (CGSize)size {
    id value = objc_getAssociatedObject(self, UICContainerSizeKey);
    return value ? [value CGSizeValue] : CGSizeZero;
}
- (void)setSize:(CGSize)size {
    objc_setAssociatedObject(self, UICContainerSizeKey, [NSValue valueWithCGSize:size],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

#pragma mark - NSTextAttachment

@interface UICLegacyTextAttachment : NSObject
- (UIImage *)image;
- (void)setImage:(UIImage *)image;
- (CGRect)bounds;
- (void)setBounds:(CGRect)bounds;
- (CGRect)attachmentBoundsForTextContainer:(id)textContainer
                      proposedLineFragment:(CGRect)lineFragment
                             glyphPosition:(CGPoint)position
                            characterIndex:(NSUInteger)characterIndex;
@end

@implementation UICLegacyTextAttachment
- (UIImage *)image { return objc_getAssociatedObject(self, UICAttachmentImageKey); }
- (void)setImage:(UIImage *)image {
    objc_setAssociatedObject(self, UICAttachmentImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (CGRect)bounds {
    id value = objc_getAssociatedObject(self, UICAttachmentBoundsKey);
    return value ? [value CGRectValue] : CGRectZero;
}
- (void)setBounds:(CGRect)bounds {
    objc_setAssociatedObject(self, UICAttachmentBoundsKey, [NSValue valueWithCGRect:bounds],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (CGRect)attachmentBoundsForTextContainer:(id)textContainer
                      proposedLineFragment:(CGRect)lineFragment
                             glyphPosition:(CGPoint)position
                            characterIndex:(NSUInteger)characterIndex {
    // UIKit's own default: the attachment bounds, or the image size.
    CGRect stored = [self bounds];
    if (!CGRectIsEmpty(stored)) return stored;
    UIImage *image = [self image];
    return image ? (CGRect){ CGPointZero, image.size } : CGRectZero;
}
@end

static Class UICRegisterClassIfAbsent(const char *name, Class superclass) {
    Class existing = objc_getClass(name);
    if (existing) return existing;
    Class created = objc_allocateClassPair(superclass, name, 0);
    if (!created) return Nil;
    objc_registerClassPair(created);
    return created;
}

static void UICAddMethod(Class cls, SEL selector, IMP implementation, const char *types) {
    if (cls && !class_getInstanceMethod(cls, selector))
        class_addMethod(cls, selector, implementation, types);
}

__attribute__((constructor)) static void UICInstallTextAttachmentClasses(void) {
    @autoreleasepool {
        Class container = UICRegisterClassIfAbsent("NSTextContainer", [NSObject class]);
        UICAddMethod(container, @selector(initWithSize:),
                     class_getMethodImplementation([UICLegacyTextContainer class], @selector(initWithSize:)),
                     "@@:{CGSize=ff}");
        UICAddMethod(container, @selector(size),
                     class_getMethodImplementation([UICLegacyTextContainer class], @selector(size)),
                     "{CGSize=ff}@:");
        UICAddMethod(container, @selector(setSize:),
                     class_getMethodImplementation([UICLegacyTextContainer class], @selector(setSize:)),
                     "v@:{CGSize=ff}");

        Class attachment = UICRegisterClassIfAbsent("NSTextAttachment", [NSObject class]);
        UICAddMethod(attachment, @selector(image),
                     class_getMethodImplementation([UICLegacyTextAttachment class], @selector(image)),
                     "@@:");
        UICAddMethod(attachment, @selector(setImage:),
                     class_getMethodImplementation([UICLegacyTextAttachment class], @selector(setImage:)),
                     "v@:@");
        UICAddMethod(attachment, @selector(bounds),
                     class_getMethodImplementation([UICLegacyTextAttachment class], @selector(bounds)),
                     "{CGRect={CGPoint=ff}{CGSize=ff}}@:");
        UICAddMethod(attachment, @selector(setBounds:),
                     class_getMethodImplementation([UICLegacyTextAttachment class], @selector(setBounds:)),
                     "v@:{CGRect={CGPoint=ff}{CGSize=ff}}");
        UICAddMethod(attachment,
                     @selector(attachmentBoundsForTextContainer:proposedLineFragment:glyphPosition:characterIndex:),
                     class_getMethodImplementation([UICLegacyTextAttachment class],
                         @selector(attachmentBoundsForTextContainer:proposedLineFragment:glyphPosition:characterIndex:)),
                     "{CGRect={CGPoint=ff}{CGSize=ff}}@:@{CGRect={CGPoint=ff}{CGSize=ff}}{CGPoint=ff}I");
    }
}
