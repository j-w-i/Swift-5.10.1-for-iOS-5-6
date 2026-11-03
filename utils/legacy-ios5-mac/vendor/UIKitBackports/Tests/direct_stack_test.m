#import <UIKit/UIKit.h>
#import "OAStackView.h"
#include <math.h>
@interface OAStackView (TestPrivate)
- (BOOL)uic_directLayoutEligible;
- (BOOL)uic_usesDirectStackLayout;
- (BOOL)uic_hasExternalArrangedConstraints;
@end
@interface UIView (TestFitting)
- (CGSize)uic_legacyStackFittingSize:(CGSize)proposal;
@end
@implementation UIView (TestFitting)
- (CGSize)uic_legacyStackFittingSize:(CGSize)proposal {
  if ([self isKindOfClass:[UILabel class]]) {
    return [self sizeThatFits:CGSizeMake(proposal.width, 100000)];
  }
  CGSize target = CGSizeMake(proposal.width >= 0 ? proposal.width : 0, proposal.height >= 0 ? proposal.height : 0);
  return [self systemLayoutSizeFittingSize:target withHorizontalFittingPriority:proposal.width >= 0 ? 1000 : 50 verticalFittingPriority:proposal.height >= 0 ? 1000 : 50];
}
@end
@interface FixedView : UIView
@property(nonatomic) CGFloat measuredHeight;
@end
@implementation FixedView
- (CGSize)sizeThatFits:(CGSize)proposal { return CGSizeMake(proposal.width, self.measuredHeight); }
- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, self.measuredHeight); }
@end
@interface DirectTestStack : OAStackView
@end
@implementation DirectTestStack
- (BOOL)uic_directLayoutEligible {
  return self.axis == UILayoutConstraintAxisVertical && self.distribution == OAStackViewDistributionFill &&
    self.alignment == OAStackViewAlignmentFill && ![self uic_hasExternalArrangedConstraints];
}
@end
static void check(BOOL condition, NSString *message) {
  if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static void rect(UIView *view, CGRect expected) {
  check(CGRectEqualToRect(view.frame, expected), [NSString stringWithFormat:@"frame %@ expected %@", NSStringFromCGRect(view.frame), NSStringFromCGRect(expected)]);
}
int main(void) { @autoreleasepool {
  DirectTestStack *stack = [[DirectTestStack alloc] initWithFrame:CGRectZero];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 12;
  stack.frame = CGRectMake(0, 0, 300, 66);
  FixedView *a = [FixedView new]; a.measuredHeight = 21;
  FixedView *b = [FixedView new]; b.measuredHeight = 33;
  [stack addArrangedSubview:a]; [stack addArrangedSubview:b];
  [stack layoutSubviews];
  check([stack uic_usesDirectStackLayout], @"vertical fill enabled");
  rect(a, CGRectMake(0,0,300,21)); rect(b, CGRectMake(0,33,300,33));
  check([stack sizeThatFits:CGSizeMake(300,-1)].height == 66, @"fitting sum");
  b.hidden = YES; [stack layoutSubviews];
  check([stack sizeThatFits:CGSizeMake(300,-1)].height == 21, @"hidden excluded");
  b.hidden = NO; [stack layoutSubviews]; rect(b, CGRectMake(0,33,300,33));
  stack.layoutMargins = UIEdgeInsetsMake(4,8,6,10);
  stack.frame = CGRectMake(0, 0, 300, 76);
  stack.layoutMarginsRelativeArrangement = YES; [stack layoutSubviews];
  rect(a, CGRectMake(8,4,282,21)); rect(b, CGRectMake(8,37,282,33));
  check([stack sizeThatFits:CGSizeMake(300,-1)].height == 76, @"margins included");
  [stack removeArrangedSubview:a];
  check(a.superview == stack, @"removeArrangedSubview preserves subview");
  stack.frame = CGRectMake(0, 0, 300, 43);
  [stack layoutSubviews]; rect(b, CGRectMake(8,4,282,33));
  stack.frame = CGRectMake(0, 0, 300, 76);
  [stack insertArrangedSubview:a atIndex:0]; [stack layoutSubviews]; rect(b, CGRectMake(8,37,282,33));
  stack.distribution = OAStackViewDistributionFillEqually;
  check(![stack uic_usesDirectStackLayout], @"unsupported distribution falls back");
  stack.distribution = OAStackViewDistributionFill;
  check([stack uic_usesDirectStackLayout], @"can re-enter direct path");
  for (NSNumber *totalHeight in @[@66, @100, @48]) {
    for (NSNumber *favorFirst in @[@YES, @NO]) {
      DirectTestStack *direct = [DirectTestStack new]; direct.axis = UILayoutConstraintAxisVertical; direct.spacing = 12;
      UIStackView *native = [UIStackView new]; native.axis = UILayoutConstraintAxisVertical; native.spacing = 12;
      direct.frame = native.frame = CGRectMake(0,0,300,totalHeight.doubleValue);
      NSMutableArray *dv = [NSMutableArray array], *nv = [NSMutableArray array];
      for (NSUInteger i = 0; i < 2; i++) {
        FixedView *d = [FixedView new], *n = [FixedView new];
        d.measuredHeight = n.measuredHeight = i ? 33 : 21;
        float priority = ((i == 0) == favorFirst.boolValue) ? 200 : 300;
        [d setContentHuggingPriority:priority forAxis:UILayoutConstraintAxisVertical];
        [n setContentHuggingPriority:priority forAxis:UILayoutConstraintAxisVertical];
        [d setContentCompressionResistancePriority:priority + 400 forAxis:UILayoutConstraintAxisVertical];
        [n setContentCompressionResistancePriority:priority + 400 forAxis:UILayoutConstraintAxisVertical];
        [direct addArrangedSubview:d]; [native addArrangedSubview:n];
        [dv addObject:d]; [nv addObject:n];
      }
      [native setNeedsLayout]; [native layoutIfNeeded]; [direct layoutSubviews];
      for (NSUInteger i=0; i<2; i++) rect(dv[i], [(UIView *)nv[i] frame]);
    }
  }
  DirectTestStack *explicitStack = [DirectTestStack new]; explicitStack.axis = UILayoutConstraintAxisVertical;
  UIView *fixed = [UIView new]; [fixed.heightAnchor constraintEqualToConstant:42].active = YES;
  [explicitStack addArrangedSubview:fixed]; explicitStack.frame = CGRectMake(0,0,180,42); [explicitStack layoutSubviews];
  check(![explicitStack uic_usesDirectStackLayout], @"explicit required child height falls back safely");
  DirectTestStack *textStack = [DirectTestStack new]; textStack.axis = UILayoutConstraintAxisVertical;
  UILabel *text = [UILabel new]; text.numberOfLines = 0; text.text = @"A wrapping message that occupies several lines when its available width becomes narrow.";
  [textStack addArrangedSubview:text];
  CGFloat wide = [textStack sizeThatFits:CGSizeMake(240,-1)].height;
  CGFloat narrow = [textStack sizeThatFits:CGSizeMake(100,-1)].height;
  check(narrow > wide && wide > 0, @"wrapping height respects allocated width");
  NSLog(@"direct-stack: PASS (native fill priority parity, explicit size and width-dependent wrapping)");
} return 0; }
