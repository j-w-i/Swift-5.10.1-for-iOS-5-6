// Author-owned source-build compatibility. See THIRD-PARTY-NOTICES.md.
#pragma once
#import <UIKit/UIKit.h>
NSDictionary *UICDictionaryOfVariableBindings(NSString *names, id firstValue, ...);
// UIKit's function backing this macro was introduced in iOS 6. Avoid an absent
// native C-symbol reference even though the equivalent dictionary is safe on 5.
#undef NSDictionaryOfVariableBindings
#define NSDictionaryOfVariableBindings(...) UICDictionaryOfVariableBindings(@"" # __VA_ARGS__, __VA_ARGS__, nil)
