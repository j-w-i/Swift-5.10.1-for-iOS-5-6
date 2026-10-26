// Author-owned bounded VFL parser. See THIRD-PARTY-NOTICES.md.
#import "UICVisualFormat.h"
@protocol UICVFLView
- (id)superview;
@end
static void UICVFLFail(NSString *format, NSString *reason) {
    [NSException raise:NSInvalidArgumentException format:@"Unsupported visual format '%@': %@", format, reason];
}
static NSDictionary *UICVFLPredicate(NSString *source, NSString *format, NSDictionary *metrics, NSDictionary *views, BOOL allowView) {
    NSString *text = source;
    NSInteger relation = 0;
    if ([text hasPrefix:@">="]) { relation = 1; text = [text substringFromIndex:2]; }
    else if ([text hasPrefix:@"<="]) { relation = -1; text = [text substringFromIndex:2]; }
    else if ([text hasPrefix:@"=="]) text = [text substringFromIndex:2];
    NSArray *parts = [text componentsSeparatedByString:@"@"];
    if ([parts count] > 2) UICVFLFail(format, @"multiple priority suffixes");
    float priority = 1000;
    if ([parts count] == 2) {
        NSString *raw = [parts objectAtIndex:1];
        NSNumber *metric = [metrics objectForKey:raw];
        double value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:raw];
        if (metric) value = [metric doubleValue];
        else if (![scanner scanDouble:&value] || ![scanner isAtEnd]) UICVFLFail(format, @"invalid priority");
        if (value <= 0 || value > 1000) UICVFLFail(format, @"priority must be in (0,1000]");
        priority = value;
    }
    NSString *raw = [parts objectAtIndex:0];
    if (![raw length]) UICVFLFail(format, @"empty predicate");
    NSNumber *metric = [metrics objectForKey:raw];
    id other = allowView ? [views objectForKey:raw] : nil;
    double value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:raw];
    if (metric) value = [metric doubleValue];
    else if (!other && (![scanner scanDouble:&value] || ![scanner isAtEnd]))
        UICVFLFail(format, @"expected a numeric constant, metric, or view name; ranges/multipliers are not implemented");
    return @{ @"relation": @(relation), @"priority": @(priority), @"value": @(value), @"other": other ?: [NSNull null] };
}
static id UICVFLConstraint(id first, NSInteger firstAttribute, id second, NSInteger secondAttribute, NSDictionary *predicate) {
    id other = [predicate objectForKey:@"other"];
    if (other != [NSNull null]) second = other;
    id result = UICMakeConstraint(first, firstAttribute, [[predicate objectForKey:@"relation"] integerValue], second,
                                 second ? secondAttribute : 0, 1, [[predicate objectForKey:@"value"] doubleValue]);
    [result setValue:[predicate objectForKey:@"priority"] forKey:@"priority"];
    return result;
}
NSArray *UICConstraintsWithVisualFormat(NSString *format, NSUInteger options, NSDictionary *metrics, NSDictionary *views) {
    if (![format isKindOfClass:[NSString class]]) UICVFLFail(format, @"format must be a string");
    NSString *text = [[format componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
    BOOL horizontal = [text hasPrefix:@"H:"];
    if (!horizontal && ![text hasPrefix:@"V:"]) UICVFLFail(format, @"expected H: or V: direction");
    NSUInteger direction = options & (3u << 16);
    if (direction == (3u << 16) || options & ~((3u << 16) | 0xffe)) UICVFLFail(format, @"unsupported format options");
    NSInteger nearAttribute = horizontal ? (direction == 0 ? 5 : direction == (2u << 16) ? 2 : 1) : 3;
    NSInteger farAttribute = horizontal ? (direction == 0 ? 6 : direction == (2u << 16) ? 1 : 2) : 4;
    NSInteger sizeAttribute = horizontal ? 7 : 8;
    NSMutableArray *nodes = [NSMutableArray array], *gaps = [NSMutableArray array], *result = [NSMutableArray array];
    NSUInteger cursor = 2;
    BOOL expectNode = YES;
    while (cursor < [text length]) {
        unichar character = [text characterAtIndex:cursor];
        if (expectNode) {
            if (character == '|') { [nodes addObject:[NSNull null]]; cursor++; }
            else if (character == '[') {
                NSRange close = [text rangeOfString:@"]" options:0 range:NSMakeRange(cursor + 1, [text length] - cursor - 1)];
                if (close.location == NSNotFound) UICVFLFail(format, @"unterminated view");
                NSString *body = [text substringWithRange:NSMakeRange(cursor + 1, close.location - cursor - 1)];
                NSRange opening = [body rangeOfString:@"("];
                NSString *name = opening.location == NSNotFound ? body : [body substringToIndex:opening.location];
                id view = [views objectForKey:name];
                if (!view) UICVFLFail(format, [@"unknown view " stringByAppendingString:name]);
                [nodes addObject:view];
                if (opening.location != NSNotFound) {
                    if (![body hasSuffix:@")"]) UICVFLFail(format, @"unterminated size predicate");
                    NSString *raw = [body substringWithRange:NSMakeRange(opening.location + 1, [body length] - opening.location - 2)];
                    if ([raw rangeOfString:@","].location != NSNotFound) UICVFLFail(format, @"multiple predicates/ranges are not implemented");
                    NSDictionary *predicate = UICVFLPredicate(raw, format, metrics, views, YES);
                    [result addObject:UICVFLConstraint(view, sizeAttribute, nil, sizeAttribute, predicate)];
                }
                cursor = close.location + 1;
            } else UICVFLFail(format, @"expected [view] or container |");
            expectNode = NO;
        } else {
            NSString *raw = @"0";
            if (character == '-') {
                cursor++; raw = @"8";
                if (cursor < [text length] && [text characterAtIndex:cursor] == '(') {
                    NSRange close = [text rangeOfString:@")" options:0 range:NSMakeRange(cursor + 1, [text length] - cursor - 1)];
                    if (close.location == NSNotFound) UICVFLFail(format, @"unterminated spacing predicate");
                    raw = [text substringWithRange:NSMakeRange(cursor + 1, close.location - cursor - 1)];
                    cursor = close.location + 1;
                    if (cursor >= [text length] || [text characterAtIndex:cursor] != '-') UICVFLFail(format, @"spacing predicate requires trailing -");
                    cursor++;
                } else if (cursor < [text length] && [text characterAtIndex:cursor] != '[' && [text characterAtIndex:cursor] != '|') {
                    NSRange dash = [text rangeOfString:@"-" options:0 range:NSMakeRange(cursor, [text length] - cursor)];
                    if (dash.location == NSNotFound) UICVFLFail(format, @"metric spacing requires trailing -");
                    raw = [text substringWithRange:NSMakeRange(cursor, dash.location - cursor)]; cursor = dash.location + 1;
                }
            }
            [gaps addObject:UICVFLPredicate(raw, format, metrics, views, NO)];
            expectNode = YES;
        }
    }
    if (expectNode || ![nodes count] || [gaps count] + 1 != [nodes count]) UICVFLFail(format, @"incomplete view chain");
    id container = nil;
    NSMutableArray *actualViews = [NSMutableArray array];
    for (id view in nodes) if (view != [NSNull null]) {
        id candidate = [(id<UICVFLView>)view superview];
        if (candidate) { if (container && container != candidate) UICVFLFail(format, @"views must share one container"); container = candidate; }
        [actualViews addObject:view];
    }
    if (![actualViews count]) UICVFLFail(format, @"no views in format");
    for (NSUInteger index = 0; index < [gaps count]; index++) {
        id previous = [nodes objectAtIndex:index], next = [nodes objectAtIndex:index + 1];
        BOOL start = previous == [NSNull null], end = next == [NSNull null];
        if ((start && index != 0) || (end && index + 2 != [nodes count]) || (start && end)) UICVFLFail(format, @"container marker only allowed at chain ends");
        if ((start || end) && !container) UICVFLFail(format, @"container marker requires a superview");
        [result addObject:UICVFLConstraint(end ? container : next, end ? farAttribute : nearAttribute,
                                          start ? container : previous, start ? nearAttribute : farAttribute,
                                          [gaps objectAtIndex:index])];
    }
    for (NSInteger attribute = 1; attribute <= 11; attribute++) if (options & (1u << attribute)) {
        if ((horizontal && (attribute == 1 || attribute == 2 || attribute == 5 || attribute == 6 || attribute == 9)) ||
            (!horizontal && (attribute == 3 || attribute == 4 || attribute == 10 || attribute == 11)))
            UICVFLFail(format, @"alignment options must be perpendicular to the chain");
        id first = [actualViews objectAtIndex:0];
        for (NSUInteger index = 1; index < [actualViews count]; index++)
            [result addObject:UICMakeConstraint([actualViews objectAtIndex:index], attribute, 0, first, attribute, 1, 0)];
    }
    return result;
}
