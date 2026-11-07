//
//  OAStackView.m
//  OAStackView
//
//  Created by Omar Abdelhafith on 14/06/2015.
//  Copyright © 2015 Omar Abdelhafith. All rights reserved.
//

#import "OAStackView.h"
#import "OAStackView+Constraint.h"
#import "OAStackView+Hiding.h"
#import "OAStackView+Traversal.h"
#import "OAStackViewAlignmentStrategy.h"
#import "OAStackViewDistributionStrategy.h"
#import "OATransformLayer.h"
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>

// Private SDK bridge; uses UIKit's Objective-C CGSize ABI, not a hand-written Swift/C value ABI.
@interface UIView (UICStackFitting)
- (CGSize)uic_legacyStackFittingSize:(CGSize)proposal;
+ (BOOL)uic_beginApplyingLayoutFrames;
+ (void)uic_endApplyingLayoutFrames:(BOOL)previous;
- (void)uic_clearStackFittingCaches;
@end

@interface OAStackView ()
@property(nonatomic, strong) NSMutableArray *mutableArrangedSubviews;
@property(nonatomic) OAStackViewAlignmentStrategy *alignmentStrategy;
@property(nonatomic) OAStackViewDistributionStrategy *distributionStrategy;
@property(nonatomic) BOOL uic_directLayoutActive;
@property(nonatomic) BOOL uic_directLayoutInProgress;
@property(nonatomic) NSInteger uic_directEligibilityGeneration;

// Not implemented but needed for backward compatibility with UIStackView
@property(nonatomic,getter=isBaselineRelativeArrangement) BOOL baselineRelativeArrangement;

@property(nonatomic, getter=areNativeLayoutMarginsSupported, readonly) BOOL nativeLayoutMarginsSupported;

@end

@implementation OAStackView

+ (Class)layerClass {
  return [OATransformLayer class];
}

#pragma mark - Initialization

- (instancetype)initWithCoder:(NSCoder *)decoder {
  self = [super initWithCoder:decoder];

  if (self) {
    [self commonInitWithInitalSubviews:@[]];

    if ([NSStringFromClass([self class]) isEqualToString:@"UIStackView"]) {
      self.axis = [decoder decodeIntegerForKey:@"UIStackViewAxis"];
      self.distribution = [decoder decodeIntegerForKey:@"UIStackViewDistribution"];
      self.alignment = [decoder decodeIntegerForKey:@"UIStackViewAlignment"];
      self.spacing = [decoder decodeDoubleForKey:@"UIStackViewSpacing"];
      self.baselineRelativeArrangement = [decoder decodeBoolForKey:@"UIStackViewBaselineRelative"];
      self.layoutMarginsRelativeArrangement = [decoder decodeBoolForKey:@"UIStackViewLayoutMarginsRelative"];
    }

    [self layoutArrangedViews];
  }

  return self;
}

- (instancetype)initWithArrangedSubviews:(NSArray<__kindof UIView *> *)views {
  self = [super initWithFrame:CGRectZero];

  if (self) {
    [self commonInitWithInitalSubviews:views];
    [self layoutArrangedViews];
  }

  return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
  return [self initWithArrangedSubviews:@[]];
}

- (void)commonInitWithInitalSubviews:(NSArray *)initialSubviews {
  _nativeLayoutMarginsSupported = [UIView instancesRespondToSelector:@selector(layoutMargins)];

  _mutableArrangedSubviews = [initialSubviews mutableCopy];
  [self addViewsAsSubviews:initialSubviews];

  _axis = UILayoutConstraintAxisHorizontal;
  _alignment = OAStackViewAlignmentFill;
  _distribution = OAStackViewDistributionFill;

  _compatibilityLayoutMargins = UIEdgeInsetsMake(0, 8, 0, 8);
  _layoutMarginsRelativeArrangement = NO;

  self.alignmentStrategy = [OAStackViewAlignmentStrategy strategyWithStackView:self];
  self.distributionStrategy = [OAStackViewDistributionStrategy strategyWithStackView:self];
}

#pragma mark - Properties

- (NSArray *)arrangedSubviews {
  return self.mutableArrangedSubviews.copy;
}

- (void)setBackgroundColor:(UIColor *)backgroundColor {
  // Does not have any effect because `CATransformLayer` is not rendered.
}

- (void)setOpaque:(BOOL)opaque {
  // Does not have any effect because `CATransformLayer` is not rendered.
}

- (void)setClipsToBounds:(BOOL)clipsToBounds {
  // Does not have any effect because `CATransformLayer` is not rendered.
}

- (void)setSpacing:(CGFloat)spacing {
  if (_spacing == spacing) { return; }

  _spacing = spacing;
  if (self.uic_directLayoutActive) { [self uic_invalidateDirectLayout]; return; }

  for (NSLayoutConstraint *constraint in self.constraints) {
    BOOL isWidthOrHeight =
    (constraint.firstAttribute == NSLayoutAttributeWidth) ||
    (constraint.firstAttribute == NSLayoutAttributeHeight);

    if ([self.subviews containsObject:constraint.firstItem] &&
        [self.subviews containsObject:constraint.secondItem] &&
        !isWidthOrHeight) {
      constraint.constant = spacing;
    }
  }
}

- (void)setAxis:(UILayoutConstraintAxis)axis {
  if (_axis == axis) { return; }
  _axis = axis;
  [self layoutArrangedViews];
}

- (void)setAxisValue:(NSInteger)axisValue {
  _axisValue = axisValue;
  self.axis = self.axisValue;
}

- (void)setAlignment:(OAStackViewAlignment)alignment {
  if (_alignment == alignment) { return; }

  _alignment = alignment;
  [self layoutArrangedViews];
}

- (void)setAlignmentConstraints {
  self.alignmentStrategy = [OAStackViewAlignmentStrategy strategyWithStackView:self];

  [self.alignmentStrategy alignFirstView:self.subviews.firstObject];

  [self iterateVisibleViews:^(UIView *view, UIView *previousView) {
    [self.alignmentStrategy addConstraintsOnOtherAxis:view];
    [self.alignmentStrategy alignView:view withPreviousView:previousView];
  }];

  [self.alignmentStrategy alignLastView:self.subviews.lastObject];
}

- (void)setAlignmentStrategy:(OAStackViewAlignmentStrategy *)alignmentStrategy {
  if ([_alignmentStrategy isEqual:alignmentStrategy]) {
    return;
  }

  [_alignmentStrategy removeAddedConstraints];
  _alignmentStrategy = alignmentStrategy;
}

- (void)setDistributionStrategy:(OAStackViewDistributionStrategy *)distributionStrategy {
  if ([_distributionStrategy isEqual:distributionStrategy]) {
    return;
  }

  [_distributionStrategy removeAddedConstraints];
  _distributionStrategy = distributionStrategy;
}

- (void)removeConstraint:(NSLayoutConstraint *)constraint {
  [super removeConstraint:constraint];
}

- (void)removeConstraints:(NSArray<__kindof NSLayoutConstraint *> *)constraints {
  [super removeConstraints:constraints];
}

- (void)updateConstraints {
  [super updateConstraints];
}

// Like UIKit, a stack with nothing to show has a zero natural size; otherwise its size comes from its
// constraints. Must not call super: the backport's UIView method forwards to this override.
- (CGSize)intrinsicContentSize {
  if (self.uic_directLayoutActive) return [self sizeThatFits:CGSizeMake(CGRectGetWidth(self.bounds), -1)];
  for (UIView *view in self.arrangedSubviews) if (!view.hidden) return CGSizeMake(-1.0, -1.0) /* UIViewNoIntrinsicMetric; the extern symbol is absent on iOS 5 */;
  return CGSizeZero;
}

- (BOOL)uic_usesDirectStackLayout {
  return self.uic_directLayoutActive;
}

- (UIView *)uic_arrangedOwnerOfView:(UIView *)view {
  UIView *candidate = view;
  while (candidate && candidate.superview != self) candidate = candidate.superview;
  return [self.arrangedSubviews containsObject:candidate] ? candidate : nil;
}

- (BOOL)uic_hasExternalArrangedConstraints {
  NSMutableArray *owned = [NSMutableArray arrayWithArray:self.alignmentStrategy.addedConstraints ?: @[]];
  [owned addObjectsFromArray:self.distributionStrategy.addedConstraints ?: @[]];
  UIView *root = self;
  while (root.superview) root = root.superview;
  NSMutableArray *pending = [NSMutableArray arrayWithObject:root];
  while (pending.count) {
    UIView *owner = [pending lastObject];
    [pending removeLastObject];
    [pending addObjectsFromArray:owner.subviews];
    for (NSLayoutConstraint *constraint in owner.constraints) {
      if ([owned containsObject:constraint]) continue;
      UIView *a = [constraint.firstItem isKindOfClass:[UIView class]] ? constraint.firstItem : nil;
      UIView *b = [constraint.secondItem isKindOfClass:[UIView class]] ? constraint.secondItem : nil;
      UIView *aa = a ? [self uic_arrangedOwnerOfView:a] : nil;
      UIView *bb = b ? [self uic_arrangedOwnerOfView:b] : nil;
      if ((aa || bb) && a && b && aa != bb) return YES;
      // The simple fill allocator below does not yet model explicit required main-axis limits.
      // Keep those stacks on the constraint implementation rather than violating the requirement.
      if (constraint.priority >= 1000 &&
          ((aa == a && constraint.firstAttribute == NSLayoutAttributeHeight) ||
           (bb == b && b && constraint.secondAttribute == NSLayoutAttributeHeight))) return YES;
    }
  }
  return NO;
}

// The constraint-system generation, or -1 when the legacy engine is not linked (the check then always re-derives).
- (NSInteger)uic_constraintGeneration {
  Class cls = NSClassFromString(@"UICLegacyConstraintGeneration");
  if (!cls || ![cls respondsToSelector:@selector(current)]) return -1;
  NSInteger (*f)(id, SEL) = (NSInteger (*)(id, SEL))[cls methodForSelector:@selector(current)];
  return f(cls, @selector(current));
}

- (BOOL)uic_directLayoutEligible {
  // On by default below iOS 6 (where every stack otherwise becomes hundreds of rows in the legacy solver and long chats stop
  // loading); LEGACY_AUTOLAYOUT_DIRECT_STACK=0 switches it off. Only the simple vertical fill/fill case qualifies and any
  // constraint from outside onto an arranged view keeps the stack on the constraint implementation.
  const char *flag = getenv("LEGACY_AUTOLAYOUT_DIRECT_STACK");
  return !(flag && strcmp(flag, "0") == 0) &&
    [[[UIDevice currentDevice] systemVersion] floatValue] < 6.0 &&
    self.axis == UILayoutConstraintAxisVertical &&
    self.distribution == OAStackViewDistributionFill &&
    self.alignment == OAStackViewAlignmentFill && !self.baselineRelativeArrangement &&
    ![self uic_hasExternalArrangedConstraints];
}

- (void)uic_invalidateDirectLayout {
  [self invalidateIntrinsicContentSize];
  // The content this stack and its ancestors fit to just changed. Drop their cached fitting sizes
  // before the next local layout pass, or it reuses the pre-change height (a new bubble stays 1pt
  // tall until an unrelated ancestor pass happens to re-measure).
  if ([self respondsToSelector:@selector(uic_clearStackFittingCaches)]) [self uic_clearStackFittingCaches];
  [self setNeedsLayout];
}

- (CGSize)uic_directStackSizeForWidth:(CGFloat)width apply:(BOOL)apply {
  UIEdgeInsets margins = self.layoutMarginsRelativeArrangement ? self.layoutMargins : UIEdgeInsetsZero;
  CGFloat innerWidth = MAX(0, width - margins.left - margins.right);
  NSMutableArray *visible = [NSMutableArray array];
  NSMutableArray *heights = [NSMutableArray array];
  CGFloat natural = margins.top + margins.bottom;
  for (UIView *view in self.arrangedSubviews) {
    if (view.hidden) continue;
    CGSize fit = [view uic_legacyStackFittingSize:CGSizeMake(innerWidth, -1)];
    CGFloat height = isfinite(fit.height) ? MAX(0, fit.height) : 0;
    [visible addObject:view]; [heights addObject:@(height)];
    natural += height;
  }
  if (visible.count > 1) natural += self.spacing * (visible.count - 1);
  if (apply && visible.count) {
    CGFloat delta = CGRectGetHeight(self.bounds) - natural;
    // Fill distributes slack to the least hugging child, and compresses the least resistant first.
    // The independent fitting pass above supplies natural sizes; the parent owns the stack's actual size.
    NSMutableIndexSet *remaining = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, visible.count)];
    while (fabs(delta) > 0.0001 && remaining.count) {
      NSUInteger selected = NSNotFound; float priority = FLT_MAX;
      for (NSUInteger i = remaining.firstIndex; i != NSNotFound; i = [remaining indexGreaterThanIndex:i]) {
        UIView *view = [visible objectAtIndex:i];
        float p = delta > 0 ? [view contentHuggingPriorityForAxis:UILayoutConstraintAxisVertical]
                            : [view contentCompressionResistancePriorityForAxis:UILayoutConstraintAxisVertical];
        if (p < priority) { priority = p; selected = i; }
      }
      CGFloat height = [[heights objectAtIndex:selected] doubleValue];
      CGFloat adjustment = delta > 0 ? delta : MAX(delta, -height);
      [heights replaceObjectAtIndex:selected withObject:@(height + adjustment)];
      delta -= adjustment;
      [remaining removeIndex:selected];
    }
  }
  CGFloat y = margins.top;
  for (NSUInteger i = 0; i < visible.count; i++) {
    UIView *view = [visible objectAtIndex:i]; CGFloat height = [[heights objectAtIndex:i] doubleValue];
    if (apply) {
      CGRect frame = CGRectMake(margins.left, y, innerWidth, height);
      if (!CGRectEqualToRect(view.frame, frame)) {
        // Layout output, not an outside change: it must not invalidate the cached fitting size of this very view.
        BOOL canMark = [UIView respondsToSelector:@selector(uic_beginApplyingLayoutFrames)];   // absent when the engine is not linked
        BOOL previousApplying = canMark ? [UIView uic_beginApplyingLayoutFrames] : NO;
        view.frame = frame;
        if (canMark) [UIView uic_endApplyingLayoutFrames:previousApplying];
      }
      [view layoutIfNeeded];
    }
    y += height + (i + 1 < visible.count ? self.spacing : 0);
  }
  return CGSizeMake(width, MAX(0, natural));
}

- (CGSize)sizeThatFits:(CGSize)proposal {
  if (!self.uic_directLayoutActive) return [super sizeThatFits:proposal];
  CGFloat width = proposal.width;
  if (!isfinite(width) || width > 100000 || width <= 0) width = CGRectGetWidth(self.bounds);
  return [self uic_directStackSizeForWidth:MAX(0, width) apply:NO];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  // Eligibility walks every constraint in the window, so it is re-derived only when the constraint system changed since
  // the last check (any add/remove/constant/priority change anywhere bumps the mutation generation). A layout pass that
  // changed no constraint cannot have changed eligibility.
  if (self.uic_directLayoutActive) {
    NSInteger generation = [self uic_constraintGeneration];
    if (generation < 0 || generation != self.uic_directEligibilityGeneration) {
      self.uic_directEligibilityGeneration = generation;
      if (![self uic_directLayoutEligible]) { [self layoutArrangedViews]; return; }
    }
  }
  if (!self.uic_directLayoutActive || self.uic_directLayoutInProgress) return;
  self.uic_directLayoutInProgress = YES;
  [self uic_directStackSizeForWidth:CGRectGetWidth(self.bounds) apply:YES];
  self.uic_directLayoutInProgress = NO;
}

- (void)setAlignmentValue:(NSInteger)alignmentValue {
  _alignmentValue = alignmentValue;
  self.alignment = alignmentValue;
}

- (void)setDistribution:(OAStackViewDistribution)distribution {
  if (_distribution == distribution) { return; }

  _distribution = distribution;
  [self layoutArrangedViews];
}

- (void)setDistributionConstraints {
  self.distributionStrategy = [OAStackViewDistributionStrategy strategyWithStackView:self];

  [self iterateVisibleViews:^(UIView *view, UIView *previousView) {
    [self.distributionStrategy alignView:view afterView:previousView];
  }];

  [self.distributionStrategy alignView:nil afterView:[self lastVisibleItem]];
}

- (void)setDistributionValue:(NSInteger)distributionValue {
  _distributionValue = distributionValue;
  self.distribution = distributionValue;
}

@synthesize layoutMargins = _compatibilityLayoutMargins;

- (UIEdgeInsets)layoutMargins {
  if (self.nativeLayoutMarginsSupported) {
    return super.layoutMargins;
  }

  return _compatibilityLayoutMargins;
}

- (void)setLayoutMargins:(UIEdgeInsets)layoutMargins {
  if (self.nativeLayoutMarginsSupported) {
    [super setLayoutMargins:layoutMargins];
  } else {
    _compatibilityLayoutMargins = layoutMargins;
    [self layoutArrangedViews];
  }
}

- (void)setLayoutMarginsRelativeArrangement:(BOOL)layoutMarginsRelativeArrangement {
  _layoutMarginsRelativeArrangement = layoutMarginsRelativeArrangement;
  [self layoutArrangedViews];
}

#pragma mark - Overriden methods

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
  [self layoutArrangedViews];
}

- (void)layoutMarginsDidChange {
  [super layoutMarginsDidChange];
  [self layoutArrangedViews];
}

#pragma mark - Adding and removing

- (void)addArrangedSubview:(UIView *)view {
  [self insertArrangedSubview:view atIndex:self.subviews.count];
}

- (void)removeArrangedSubview:(UIView *)view {
  if (self.uic_directLayoutActive) {
    [self.mutableArrangedSubviews removeObject:view];
    [self uic_invalidateDirectLayout];
    return;
  }

  if (self.subviews.count == 1) {
    [self.mutableArrangedSubviews removeObject:view];
    [view removeFromSuperview];
    [self invalidateIntrinsicContentSize];
    return;
  }

  [self removeViewFromArrangedViews:view permanently:YES];
  [self invalidateIntrinsicContentSize];
}

- (void)insertArrangedSubview:(UIView *)view atIndex:(NSUInteger)stackIndex {
  [self insertArrangedSubview:view atIndex:stackIndex newItem:YES];
}

- (void)insertArrangedSubview:(UIView *)view atIndex:(NSUInteger)stackIndex newItem:(BOOL)newItem {
  if (self.uic_directLayoutActive) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    if (newItem) {
      NSUInteger index = MIN(stackIndex, self.mutableArrangedSubviews.count);
      [self.mutableArrangedSubviews insertObject:view atIndex:index];
      [self insertSubview:view atIndex:MIN(index, self.subviews.count)];
    }
    [self uic_invalidateDirectLayout];
    return;
  }

  id previousView, nextView;
  view.translatesAutoresizingMaskIntoConstraints = NO;
  BOOL isAppending = stackIndex == self.subviews.count;

  if (isAppending) {
    //Appending a new item

    previousView = [self lastVisibleItem];
    nextView = nil;

    NSArray<__kindof NSLayoutConstraint *> *constraints = [self lastConstraintAffectingView:self andView:previousView inAxis:self.axis];
    if (constraints) {
      [self removeConstraints:constraints];
    }

    if (newItem) {
      [self.mutableArrangedSubviews addObject:view];
      [self addSubview:view];
    }

  } else {
    //Item insertion

    previousView = [self visibleViewBeforeIndex:stackIndex];
    nextView = [self visibleViewAfterIndex:newItem ? stackIndex - 1: stackIndex];

    NSArray<__kindof NSLayoutConstraint *> *constraints;
    BOOL isLastVisibleItem = [self isViewLastItem:previousView excludingItem:view];
    BOOL isFirstVisibleView = previousView == nil;
    BOOL isOnlyItem = previousView == nil && nextView == nil;

    if (isLastVisibleItem) {
      constraints = @[[self lastViewConstraint]];
    } else if(isOnlyItem) {
      constraints = [self constraintsBetweenView:previousView ?: self andView:nextView ?: self inAxis:self.axis];
    } else if(isFirstVisibleView) {
      constraints = @[[self firstViewConstraint]];
    } else {
      constraints = [self constraintsBetweenView:previousView ?: self andView:nextView ?: self inAxis:self.axis];
    }

    [self removeConstraints:constraints];

    if (newItem) {
      [self.mutableArrangedSubviews insertObject:view atIndex:stackIndex];
      [self insertSubview:view atIndex:stackIndex];
    }
  }

  [self.distributionStrategy alignView:view afterView:previousView];
  [self.alignmentStrategy alignView:view withPreviousView:previousView];
  [self.alignmentStrategy addConstraintsOnOtherAxis:view];
  [self.distributionStrategy alignView:nextView afterView:view];
  [self.alignmentStrategy alignView:nextView withPreviousView:view];
  // intrinsicContentSize depends on whether any arranged view is visible (zero when empty). UIKit 6+ caches
  // content-size constraints from the last answer, so a stack that was empty keeps width/height pinned to 0
  // (at the stack's hugging/compression priorities) until told the answer changed. UIStackView does this itself.
  [self invalidateIntrinsicContentSize];
}

- (void)removeViewFromArrangedViews:(UIView*)view permanently:(BOOL)permanently {
  NSInteger index = [self.subviews indexOfObject:view];
  if (index == NSNotFound) { return; }

  id previousView = [self visibleViewBeforeView:view];
  id nextView = [self visibleViewAfterView:view];

  if (permanently) {
    [self.mutableArrangedSubviews removeObject:view];
    [view removeFromSuperview];
  } else {
    NSArray <__kindof NSLayoutConstraint *> *constraint = [self constraintsAffectingView:view];
    [self removeConstraints:constraint];
  }

  if (nextView) {
    [self.distributionStrategy alignView:nextView afterView:previousView];
  } else if(previousView) {
    [self.distributionStrategy alignView:nil afterView:[self lastVisibleItem]];
  }
}

#pragma mark - Hide and Unhide

- (void)hideView:(UIView*)view {
  if (self.uic_directLayoutActive) { [self uic_invalidateDirectLayout]; return; }
  [self removeViewFromArrangedViews:view permanently:NO];
}

- (void)unHideView:(UIView*)view {
  NSInteger index = [self.subviews indexOfObject:view];
  [self insertArrangedSubview:view atIndex:index newItem:NO];
}

#pragma mark - Align View

- (void)layoutArrangedViews {
  BOOL direct = [self uic_directLayoutEligible];
  self.uic_directEligibilityGeneration = [self uic_constraintGeneration];
  if (direct) {
    [self.alignmentStrategy removeAddedConstraints];
    [self.distributionStrategy removeAddedConstraints];
    self.uic_directLayoutActive = YES;
    [self uic_invalidateDirectLayout];
    return;
  }
  self.uic_directLayoutActive = NO;
  NSMutableArray *constraints = [NSMutableArray array];
  [constraints addObjectsFromArray:self.alignmentStrategy.addedConstraints];
  [constraints addObjectsFromArray:self.distributionStrategy.addedConstraints];
  [self removeConstraints:constraints];

  [self setAlignmentConstraints];
  [self setDistributionConstraints];
}

- (void)addViewsAsSubviews:(NSArray*)views {
  for (UIView *view in views) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:view];
  }
}

@end


#pragma mark - Runtime Injection

// Constructors are called after all classes have been loaded.
__attribute__((constructor)) static void OAStackViewPatchEntry(void) {

  if (objc_getClass("UIStackView")) {
    return;
  }

  if (objc_getClass("OAStackViewDisableForwardToUIStackViewSentinel")) {
    return;
  }

  Class class = objc_allocateClassPair(OAStackView.class, "UIStackView", 0);
  if (class) {
    objc_registerClassPair(class);
  }
}
