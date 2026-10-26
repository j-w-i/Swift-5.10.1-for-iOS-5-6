// Author-owned toolchain integration. See THIRD-PARTY-NOTICES.md.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NSArray *UICConstraintsWithVisualFormat(NSString *format, NSUInteger options, NSDictionary *metrics, NSDictionary *views);
id UICMakeConstraint(id first, NSInteger attribute, NSInteger relation, id second, NSInteger secondAttribute, CGFloat multiplier, CGFloat constant);
