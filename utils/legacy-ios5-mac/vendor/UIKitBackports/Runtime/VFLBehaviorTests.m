// Host-side behaviour tests for the *same* bounded parser built into the runtime.
#import "UICVisualFormat.h"
@interface UICProbeView : NSObject
@property(nonatomic, strong) id superview;
@end
@implementation UICProbeView @end
id UICMakeConstraint(id first, NSInteger attribute, NSInteger relation, id second, NSInteger secondAttribute, CGFloat multiplier, CGFloat constant) {
    return [@{@"first": first, @"attribute": @(attribute), @"relation": @(relation),
              @"second": second ?: [NSNull null], @"secondAttribute": @(secondAttribute),
              @"multiplier": @(multiplier), @"constant": @(constant)} mutableCopy];
}
static void require(BOOL condition, NSString *message) { if (!condition) [NSException raise:@"TestFailure" format:@"%@", message]; }
int main(void) { @autoreleasepool {
    UICProbeView *container = [UICProbeView new], *view = [UICProbeView new], *other = [UICProbeView new];
    view.superview = container; other.superview = container;
    NSDictionary *views = @{ @"view": view, @"previousView": other, @"other": other };
    NSDictionary *metrics = @{ @"firstMargin": @7, @"lastMargin": @9, @"gap": @12, @"priority": @750 };
    // Literal OAStackView format families (both axis choices and spacing relations).
    for (NSString *axis in @[@"H", @"V"]) {
        NSArray *formats = @[[axis stringByAppendingString:@":[view]-(lastMargin)-|"],
                             [axis stringByAppendingString:@":|-(firstMargin)-[view]"],
                             [axis stringByAppendingString:@":[previousView]-(==12.000000)-[view]"],
                             [axis stringByAppendingString:@":[previousView]-(>=12.000000)-[view]"],
                             [axis stringByAppendingString:@":|-(==firstMargin)-[view]-(>=lastMargin)-|"]];
        for (NSString *format in formats) require([UICConstraintsWithVisualFormat(format, 0, metrics, views) count] > 0, format);
    }
    NSArray *constraints = UICConstraintsWithVisualFormat(@"H:|-(gap@priority)-[view(>=40@750)]-[other(==view)]-|", 1u << 10, metrics, views);
    require([constraints count] == 6, @"size+chain+alignment constraint count");
    NSDictionary *size = [constraints objectAtIndex:0];
    require([[size objectForKey:@"attribute"] integerValue] == 7 && [[size objectForKey:@"relation"] integerValue] == 1, @"width inequality");
    require([[size objectForKey:@"constant"] doubleValue] == 40 && [[size objectForKey:@"priority"] floatValue] == 750, @"constant and priority");
    NSDictionary *gap = [constraints objectAtIndex:2];
    require([[gap objectForKey:@"constant"] doubleValue] == 12 && [[gap objectForKey:@"priority"] floatValue] == 750, @"metric spacing priority");
    require([[gap objectForKey:@"attribute"] integerValue] == 5, @"leading-to-trailing default");
    require([UICConstraintsWithVisualFormat(@"H:[view]-[other]", 1u << 11, nil, views) count] == 2, @"baseline alignment option");
    require([UICConstraintsWithVisualFormat(@"V:[view][other]", (1u << 1) | (1u << 2), nil, views) count] == 3, @"left/right alignment options");
    NSArray *unsupported = @[@"H:[view(>=40,<=60)]", @"H:[view(other*2)]", @"H:[view]-?-[other]", @"H:|[missing]|", @"H:[view(40@0)]", @"[view]", @"H:[view]-"];
    for (NSString *format in unsupported) {
        BOOL rejected = NO;
        @try { UICConstraintsWithVisualFormat(format, 0, metrics, views); }
        @catch (NSException *error) { rejected = [error.name isEqual:NSInvalidArgumentException] && [error.reason rangeOfString:format].location != NSNotFound; }
        require(rejected, [@"unsupported format not clearly rejected: " stringByAppendingString:format]);
    }
    puts("PASS: OAStackView VFL families, metrics/priorities/relations/alignment and unsupported-format exceptions");
} return 0; }
