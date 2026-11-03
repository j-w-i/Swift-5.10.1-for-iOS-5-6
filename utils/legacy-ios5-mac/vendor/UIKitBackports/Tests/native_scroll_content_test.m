#import <UIKit/UIKit.h>
#include <math.h>
int main(void) { @autoreleasepool {
 UIView *host=[[UIView alloc] initWithFrame:CGRectMake(0,0,320,480)];
 UIScrollView *scroll=[UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints=NO; [host addSubview:scroll];
 UIView *content=[UIView new]; content.translatesAutoresizingMaskIntoConstraints=NO; [scroll addSubview:content];
 [NSLayoutConstraint activateConstraints:@[
  [scroll.leadingAnchor constraintEqualToAnchor:host.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
  [scroll.topAnchor constraintEqualToAnchor:host.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
  [content.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:10],
  [content.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-10],
  [content.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:20],
  [content.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-20],
  [content.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
  [content.heightAnchor constraintEqualToConstant:1000]]];
 [host layoutIfNeeded];
 NSLog(@"viewport=%@ contentFrame=%@ contentSize=%@",NSStringFromCGRect(scroll.frame),NSStringFromCGRect(content.frame),NSStringFromCGSize(scroll.contentSize));
 if(fabs(content.frame.size.width-300)>0.01 || fabs(content.frame.size.height-1000)>0.01 || fabs(scroll.contentSize.height-1040)>0.01) return 1;
 scroll.contentOffset=CGPointMake(0,200); [host layoutIfNeeded];
 if(fabs(content.frame.origin.y-20)>0.01 || fabs(scroll.contentSize.height-1040)>0.01) return 2;
 NSLog(@"native-scroll-content: PASS (legacy edge anchors use content, centerX uses viewport; scrolling preserves content frame)");
}return 0;}
