//
//  UICLabelAttributedText.m
//  UIKitBackports runtime
//
//  Genuine `UILabel.attributedText` (UIKit 6) for the legacy runtime. The
//  property, its storage and the mirroring of `text` follow UIKit's documented
//  behaviour; drawing and measurement go through CoreText, which consumes the
//  same attribute-name strings UIKit uses (NSFont/NSColor/NSUnderline).
//

#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

static const void *UICAttributedTextKey = &UICAttributedTextKey;
static const void *UICUniformNativeCacheKey = &UICUniformNativeCacheKey;
static IMP UICOriginalDrawTextInRect = NULL;
static IMP UICOriginalSizeThatFits = NULL;

static NSAttributedString *UICLabelAttributedText(UILabel *label) {
    return objc_getAssociatedObject(label, UICAttributedTextKey);
}

static void UICSetLabelAttributedText(UILabel *label, NSAttributedString *text) {
    objc_setAssociatedObject(label, UICUniformNativeCacheKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(label, UICAttributedTextKey, [text copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// Paragraph style stored under UIKit's own key; CoreText reads it directly.
static CTParagraphStyleRef UICCopyParagraphStyle(NSAttributedString *text) {
    id style = nil;
    if (text.length > 0) style = [text attribute:@"NSParagraphStyle" atIndex:0 effectiveRange:NULL];
    if ([style isKindOfClass:NSClassFromString(@"NSParagraphStyle")] ||
        [style isKindOfClass:NSClassFromString(@"NSMutableParagraphStyle")]) {
        // NSParagraphStyle is toll-free with CTParagraphStyle on this runtime.
        return CTParagraphStyleCreateCopy((CTParagraphStyleRef)style);
    }
    return NULL;
}


/// CoreText on iOS 5 only understands CoreText objects: a UIFont stored under the font key, or a UIColor under the
/// colour key, is dereferenced as a CTFontRef/CGColorRef and faults (EXC_BAD_ACCESS at 0x8 inside CTFramesetter).
/// UIKit 6 accepted UIFont/UIColor there, so callers of the real API pass them. Convert every run to CoreText types
/// and drop attributes CoreText cannot consume (paragraph styles from the backport, attachments, ...). A label with a
/// missing font gets the label's own font so measuring never sees a run without one.
static NSAttributedString *UICCoreTextSafeString(NSAttributedString *source, UILabel *label) {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:source.string];
    UIFont *labelFont = label.font ?: [UIFont systemFontOfSize:17];
    [source enumerateAttributesInRange:NSMakeRange(0, source.length) options:0
                            usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
        id font = [attrs objectForKey:(id)kCTFontAttributeName] ?: [attrs objectForKey:@"NSFont"];
        id color = [attrs objectForKey:(id)kCTForegroundColorAttributeName] ?: [attrs objectForKey:@"NSColor"];
        CTFontRef ctFont = NULL;
        if ([font isKindOfClass:[UIFont class]]) {
            ctFont = CTFontCreateWithName((CFStringRef)[(UIFont *)font fontName], [(UIFont *)font pointSize], NULL);
        } else if (font && CFGetTypeID((CFTypeRef)font) == CTFontGetTypeID()) {
            ctFont = (CTFontRef)CFRetain((CFTypeRef)font);
        }
        if (!ctFont) ctFont = CTFontCreateWithName((CFStringRef)labelFont.fontName, labelFont.pointSize, NULL);
        NSMutableDictionary *safe = [NSMutableDictionary dictionaryWithCapacity:2];
        if (ctFont) { [safe setObject:(__bridge id)ctFont forKey:(id)kCTFontAttributeName]; CFRelease(ctFont); }
        CGColorRef cgColor = NULL;
        if ([color isKindOfClass:[UIColor class]]) cgColor = [(UIColor *)color CGColor];
        else if (color && CFGetTypeID((CFTypeRef)color) == CGColorGetTypeID()) cgColor = (__bridge CGColorRef)color;
        // A run without its own colour takes the label's textColor, as UIKit does (CoreText's default is black).
        if (!cgColor) cgColor = (label.textColor ?: [UIColor blackColor]).CGColor;
        if (cgColor) [safe setObject:(__bridge id)cgColor forKey:(id)kCTForegroundColorAttributeName];
        id underline = [attrs objectForKey:(id)kCTUnderlineStyleAttributeName] ?: [attrs objectForKey:@"NSUnderline"];
        if ([underline isKindOfClass:[NSNumber class]]) [safe setObject:underline forKey:(id)kCTUnderlineStyleAttributeName];
        [result setAttributes:safe range:range];
    }];
    return result;
}

static CGFloat UICLineHeight(CTLineRef line) {
    CGFloat ascent = 0, descent = 0, leading = 0;
    CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    return ascent + descent + leading;
}

// An attributed string with exactly the label's plain font/color is already
// representable by iOS5 UILabel. Keep its native wrapping, baseline rasterization,
// truncation and sizing instead of approximating those rules in CoreText. Unknown
// attributes deliberately exclude this path (including paragraph/underline/etc).
static BOOL UICCanUseNativeLabelText(UILabel *label, NSAttributedString *text) {
    if (![label.text isEqualToString:text.string]) return NO;
    __block BOOL plain = YES;
    [text enumerateAttributesInRange:NSMakeRange(0, text.length) options:0 usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
        for (id key in attrs) {
            id value = [attrs objectForKey:key];
            if ([key isEqual:@"NSFont"]) {
                if (![value isKindOfClass:[UIFont class]] || ![value isEqual:label.font]) plain = NO;
            } else if ([key isEqual:@"NSColor"]) {
                if (![value isKindOfClass:[UIColor class]] || ![value isEqual:label.textColor]) plain = NO;
            } else {
                plain = NO;
            }
        }
        if (!plain) *stop = YES;
    }];
    return plain;
}

// ISOLATED candidate: uniform effective font/color is still representable by
// plain native UIKit even when it differs from the label's default properties.
// Use an unattached reference label; never temporarily mutate the live control.
@interface UICUniformNativeCache : NSObject
@property(nonatomic,strong) NSAttributedString *source;
@property(nonatomic,strong) UIFont *defaultFont;
@property(nonatomic,strong) UIColor *defaultColor;
@property(nonatomic,strong) UILabel *reference;
@end
@implementation UICUniformNativeCache
@end

static void UICSyncUniformNativeReference(UILabel *reference, UILabel *label) {
    if (reference.numberOfLines != label.numberOfLines) reference.numberOfLines = label.numberOfLines;
    if (reference.lineBreakMode != label.lineBreakMode) reference.lineBreakMode = label.lineBreakMode;
    if (reference.textAlignment != label.textAlignment) reference.textAlignment = label.textAlignment;
    if (!CGRectEqualToRect(reference.bounds,label.bounds)) reference.bounds = label.bounds;
}

static UILabel *UICCreateUniformNativeLabel(UILabel *label, NSAttributedString *text) {
    if (!text.length || label.adjustsFontSizeToFitWidth || label.highlighted ||
        !label.enabled || label.shadowColor) return nil;
    // A plain reference cannot reproduce a subclass's custom measurement rect.
    SEL textRect = @selector(textRectForBounds:limitedToNumberOfLines:);
    if (class_getMethodImplementation(object_getClass(label),textRect) !=
        class_getMethodImplementation([UILabel class],textRect)) return nil;
    // The production setter copies its attributed string. Direct test callers
    // with mutable strings must reclassify rather than reuse a stale descriptor.
    BOOL cacheable = ![text isKindOfClass:[NSMutableAttributedString class]];
    UICUniformNativeCache *cache = cacheable ? objc_getAssociatedObject(label,UICUniformNativeCacheKey) : nil;
    if (cache.source == text &&
        (cache.defaultFont == label.font || [cache.defaultFont isEqual:label.font]) &&
        (cache.defaultColor == label.textColor || [cache.defaultColor isEqual:label.textColor])) {
        if (cache.reference) UICSyncUniformNativeReference(cache.reference,label);
        return cache.reference;
    }
    __block UIFont *uniformFont = nil;
    __block UIColor *uniformColor = nil;
    __block BOOL supported = YES;
    [text enumerateAttributesInRange:NSMakeRange(0,text.length) options:0 usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
        id font = [attrs objectForKey:@"NSFont"] ?: label.font;
        id color = [attrs objectForKey:@"NSColor"] ?: label.textColor;
        if (![font isKindOfClass:[UIFont class]] || ![color isKindOfClass:[UIColor class]] ||
            (uniformFont && ![uniformFont isEqual:font]) || (uniformColor && ![uniformColor isEqual:color])) supported = NO;
        for (id key in attrs) if (![key isEqual:@"NSFont"] && ![key isEqual:@"NSColor"]) supported = NO;
        if (!supported) { *stop = YES; return; }
        uniformFont = font; uniformColor = color;
    }];
    UILabel *reference = nil;
    if (supported && uniformFont && uniformColor) {
        reference = [UILabel new];
        reference.font = uniformFont; reference.textColor = uniformColor;
        reference.text = text.string;
        UICSyncUniformNativeReference(reference,label);
    }
    if (cacheable) {
        cache = [UICUniformNativeCache new];
        cache.source = text; cache.defaultFont = label.font; cache.defaultColor = label.textColor;
        cache.reference = reference;
        objc_setAssociatedObject(label,UICUniformNativeCacheKey,cache,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return reference;
}

/// Uses native UILabel when attributes are exactly representable. The general
/// CoreText path preserves complete frame coverage; attributed line limits,
/// paragraph styles and mixed-run baseline parity still need regression coverage.
static void UICDrawLabelAttributedText(UILabel *label, CGRect bounds, NSAttributedString *text) {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context || text.length == 0) return;
    if (UICOriginalDrawTextInRect && UICCanUseNativeLabelText(label, text)) {
        ((void (*)(id, SEL, CGRect))UICOriginalDrawTextInRect)(label, @selector(drawTextInRect:), bounds);
        return;
    }

    UILabel *uniform = UICCreateUniformNativeLabel(label,text);
    if (uniform && UICOriginalDrawTextInRect) {
        ((void (*)(id, SEL, CGRect))UICOriginalDrawTextInRect)(uniform,@selector(drawTextInRect:),bounds);
        return;
    }
    NSAttributedString *original = text;
    text = UICCoreTextSafeString(original, label);
    CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString((CFAttributedStringRef)text);
    if (!framesetter) return;

    CTParagraphStyleRef paragraph = UICCopyParagraphStyle(original);
    CTTextAlignment alignment = kCTNaturalTextAlignment;
    if (paragraph)
        CTParagraphStyleGetValueForSpecifier(paragraph, kCTParagraphStyleSpecifierAlignment,
                                             sizeof(alignment), &alignment);

    CGFloat width = CGRectGetWidth(bounds);
    CTFrameRef probe = NULL;
    CGFloat usedHeight = 0;
    {
        CGPathRef probePath = CGPathCreateWithRect(CGRectMake(0, 0, width, 100000.0), NULL);
        probe = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), probePath, NULL);
        CGPathRelease(probePath);
        if (!probe) { CFRelease(framesetter); if (paragraph) CFRelease(paragraph); return; }
        CFArrayRef lines = CTFrameGetLines(probe);
        CFIndex count = CFArrayGetCount(lines);
        if (count > 0) {
            CGPoint lastOrigin;
            CTFrameGetLineOrigins(probe, CFRangeMake(count - 1, 1), &lastOrigin);
            CGFloat descent = 0;
            CTLineGetTypographicBounds((CTLineRef)CFArrayGetValueAtIndex(lines, count - 1), NULL, &descent, NULL);
            // Frame origins include CoreText's actual inter-line advances. Summing
            // glyph typographic heights omits that spacing and can drop final lines.
            usedHeight = 100000.0 - lastOrigin.y + descent;
        }
    }

    // The frame is sized from the text, never from the label's bounds: bounds are the ceil()ed measured size (or
    // smaller when constraints compress the label), and a CoreText path shorter than the text silently drops whole
    // lines. The graphics context clips anything outside the label, which is what UILabel does too.
    CGFloat height = usedHeight;
    CGFloat top = CGRectGetMinY(bounds) + (CGRectGetHeight(bounds) - height) / 2.0;

    CGContextSaveGState(context);
    // Draw the already validated probe frame. Recreating a short frame from a
    // sum of glyph heights silently omitted lines; no guessed slack is needed.
    CGFloat pathHeight = 100000.0;
    CGContextTranslateCTM(context, CGRectGetMinX(bounds), top + pathHeight);
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);

    CTFrameRef frame = (CTFrameRef)CFRetain(probe);
    if (frame) {
        CFArrayRef lines = CTFrameGetLines(frame);
        CGPoint *origins = (CGPoint *)calloc((size_t)CFArrayGetCount(lines), sizeof(CGPoint));
        if (origins) {
            CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), origins);
            for (CFIndex i = 0; i < CFArrayGetCount(lines); i++) {
                CTLineRef line = (CTLineRef)CFArrayGetValueAtIndex(lines, i);
                if (alignment == kCTRightTextAlignment || alignment == kCTNaturalTextAlignment)
                    CGContextSetTextPosition(context, origins[i].x, origins[i].y);
                else if (alignment == kCTCenterTextAlignment)
                    CGContextSetTextPosition(context, origins[i].x, origins[i].y);
                else
                    CGContextSetTextPosition(context, origins[i].x, origins[i].y);
                CTLineDraw(line, context);
            }
            free(origins);
        }
        CFRelease(frame);
    }
    CGContextRestoreGState(context);
    CFRelease(probe);
    CFRelease(framesetter);
    if (paragraph) CFRelease(paragraph);
}

@implementation UILabel (UICLegacyAttributedText)

- (NSAttributedString *)uic_attributedText { return UICLabelAttributedText(self); }

- (void)uic_setAttributedText:(NSAttributedString *)text {
    UICSetLabelAttributedText(self, text);
    // UIKit keeps `text` in sync with the attributed string's characters.
    if (text) self.text = text.string;
    [self setNeedsDisplay];
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout];
}

- (void)uic_drawTextInRect:(CGRect)rect {
    NSAttributedString *text = UICLabelAttributedText(self);
    if (text) { UICDrawLabelAttributedText(self, rect, text); return; }
    if (UICOriginalDrawTextInRect)
        ((void (*)(id, SEL, CGRect))UICOriginalDrawTextInRect)(self, @selector(drawTextInRect:), rect);
}

- (CGSize)uic_sizeThatFits:(CGSize)size {
    NSAttributedString *text = UICLabelAttributedText(self);
    if (!text || text.length == 0) {
        if (UICOriginalSizeThatFits)
            return ((CGSize (*)(id, SEL, CGSize))UICOriginalSizeThatFits)(self, @selector(sizeThatFits:), size);
        return CGSizeZero;
    }
    if (UICOriginalSizeThatFits && UICCanUseNativeLabelText(self, text)) {
        return ((CGSize (*)(id, SEL, CGSize))UICOriginalSizeThatFits)(self, @selector(sizeThatFits:), size);
    }
    UILabel *uniform = UICCreateUniformNativeLabel(self,text);
    if (uniform && UICOriginalSizeThatFits) return ((CGSize (*)(id, SEL, CGSize))UICOriginalSizeThatFits)(uniform,@selector(sizeThatFits:),size);
    CGFloat maxWidth = size.width;
    if (maxWidth <= 0 || maxWidth == CGFLOAT_MAX) maxWidth = CGFLOAT_MAX;
    text = UICCoreTextSafeString(text, self);
    CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString((CFAttributedStringRef)text);
    if (!framesetter) return CGSizeZero;
    CGSize suggested = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRangeMake(0, 0), NULL, CGSizeMake(maxWidth, 100000.0), NULL);
    CFRelease(framesetter);
    // Draw centres the summed line heights inside the label, so the label must be at least that tall or the last
    // row (descenders) lands outside it and is clipped.
    CGFloat summed = 0;
    {
        CTFramesetterRef fs = CTFramesetterCreateWithAttributedString((CFAttributedStringRef)text);
        if (fs) {
            CGFloat probeWidth = (maxWidth == CGFLOAT_MAX) ? 100000.0 : maxWidth;
            CGPathRef path = CGPathCreateWithRect(CGRectMake(0, 0, probeWidth, 100000.0), NULL);
            CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, NULL);
            CGPathRelease(path);
            if (frame) {
                CFArrayRef lines = CTFrameGetLines(frame);
                for (CFIndex i = 0; i < CFArrayGetCount(lines); i++)
                    summed += UICLineHeight((CTLineRef)CFArrayGetValueAtIndex(lines, i));
                CFRelease(frame);
            }
            CFRelease(fs);
        }
    }
    return CGSizeMake((CGFloat)ceil(suggested.width), (CGFloat)ceil(MAX(suggested.height, summed)));
}

@end

__attribute__((constructor)) static void UICInstallLabelAttributedText(void) {
    @autoreleasepool {
        Class labelClass = [UILabel class];
        if (!labelClass) return;
        // Never replace a native implementation (iOS 6+ remains authoritative).
        if (!class_getInstanceMethod(labelClass, @selector(attributedText))) {
            class_addMethod(labelClass, @selector(setAttributedText:),
                            class_getMethodImplementation([UILabel class], @selector(uic_setAttributedText:)), "v@:@");
            class_addMethod(labelClass, @selector(attributedText),
                            class_getMethodImplementation([UILabel class], @selector(uic_attributedText)), "@@:");

            Method draw = class_getInstanceMethod(labelClass, @selector(drawTextInRect:));
            if (draw) {
                UICOriginalDrawTextInRect = method_getImplementation(draw);
                class_replaceMethod(labelClass, @selector(drawTextInRect:),
                                    class_getMethodImplementation([UILabel class], @selector(uic_drawTextInRect:)), "v@:{CGRect={CGPoint=ff}{CGSize=ff}}");
            }
            Method fit = class_getInstanceMethod(labelClass, @selector(sizeThatFits:));
            if (fit) {
                UICOriginalSizeThatFits = method_getImplementation(fit);
                class_replaceMethod(labelClass, @selector(sizeThatFits:),
                                    class_getMethodImplementation([UILabel class], @selector(uic_sizeThatFits:)), "{CGSize=ff}@:{CGSize=ff}");
            }
        }
    }
}
