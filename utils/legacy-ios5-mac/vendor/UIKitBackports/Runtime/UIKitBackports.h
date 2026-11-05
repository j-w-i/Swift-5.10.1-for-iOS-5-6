// Author-owned UIKitCompatKit toolchain integration. See THIRD-PARTY-NOTICES.md.
#pragma once
#import <UIKit/UIKit.h>
#import "OAStackView.h"

@interface UICLayoutAnchor : NSObject
@property(nonatomic, weak) id item;
@property(nonatomic) NSInteger attribute;
- (id)constraintEqualToAnchor:(UICLayoutAnchor *)other;
- (id)constraintEqualToAnchor:(UICLayoutAnchor *)other constant:(CGFloat)constant;
- (id)constraintGreaterThanOrEqualToAnchor:(UICLayoutAnchor *)other;
- (id)constraintGreaterThanOrEqualToAnchor:(UICLayoutAnchor *)other constant:(CGFloat)constant;
- (id)constraintLessThanOrEqualToAnchor:(UICLayoutAnchor *)other;
- (id)constraintLessThanOrEqualToAnchor:(UICLayoutAnchor *)other constant:(CGFloat)constant;
@end
@interface UICXAxisAnchor : UICLayoutAnchor @end
@interface UICYAxisAnchor : UICLayoutAnchor @end
@interface UICLayoutDimension : UICLayoutAnchor
- (id)constraintEqualToConstant:(CGFloat)constant;
- (id)constraintGreaterThanOrEqualToConstant:(CGFloat)constant;
- (id)constraintLessThanOrEqualToConstant:(CGFloat)constant;
- (id)constraintEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier;
- (id)constraintEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier constant:(CGFloat)constant;
- (id)constraintGreaterThanOrEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier;
- (id)constraintGreaterThanOrEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier constant:(CGFloat)constant;
- (id)constraintLessThanOrEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier;
- (id)constraintLessThanOrEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier constant:(CGFloat)constant;
@end
@interface UICLayoutGuide : NSObject <NSCoding>
@property(nonatomic, weak) UIView *owningView;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, readonly) CGRect layoutFrame;
@property(nonatomic, readonly) UIView *proxyView;
@property(nonatomic, readonly) UICXAxisAnchor *leadingAnchor, *trailingAnchor, *leftAnchor, *rightAnchor, *centerXAnchor;
@property(nonatomic, readonly) UICYAxisAnchor *topAnchor, *bottomAnchor, *centerYAnchor;
@property(nonatomic, readonly) UICLayoutDimension *widthAnchor, *heightAnchor;
@end
@interface UICRefreshControl : UIControl
@property(nonatomic, readonly, getter=isRefreshing) BOOL refreshing;
@property(nonatomic, strong) NSAttributedString *attributedTitle;
@property(nonatomic, strong) UIColor *tintColor;
- (void)beginRefreshing;
- (void)endRefreshing;
@end
@interface UICStackView : OAStackView @end

// Swift engine bridge; invoked before any constraint factory uses the runtime.
void UICLegacyInitializeAutoLayout(void);
void UICInstallConstraintClassMethods(void);
NSArray *UICConstraintsWithVisualFormat(NSString *format, NSUInteger options, NSDictionary *metrics, NSDictionary *views);
id UICMakeConstraint(id first, NSInteger attribute, NSInteger relation, id second, NSInteger secondAttribute, CGFloat multiplier, CGFloat constant);
void UICAddLayoutGuide(UIView *view, UICLayoutGuide *guide);
void UICRemoveLayoutGuide(UIView *view, UICLayoutGuide *guide);
// Real-Apple preferredMaxLayoutWidth bridge (see UICLabelPreferredWidth.m).
// On iOS 6+ Apple's UILabel implements the property natively; these forward to it.
CGFloat UICLabelRealPreferredMaxLayoutWidth(UILabel *label);
void UICLabelSetRealPreferredMaxLayoutWidth(UILabel *label, CGFloat value);
