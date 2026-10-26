// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
#import "FoundationBackportsCore.h"
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static BOOL ValidScheme(NSString *s) {
 if(!s.length) return NO;
 for(NSUInteger i=0;i<s.length;i++) { unichar c=[s characterAtIndex:i];
  if(!((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(i&&((c>='0'&&c<='9')||c=='+'||c=='-'||c=='.')))) return NO;
 } return YES;
}
// iOS 7 has NSURLComponents but lacks the iOS 8 string/queryItems surface.
// Use one complete backend, never forward a selector missing on that runtime.
static Class NativeComponentsClass(void) {
#if FBP_FORCE_TEST_RUNTIME
 return Nil;
#else
 static Class result; static dispatch_once_t once;
 dispatch_once(&once, ^{
  Class cls=objc_getClass("NSURLComponents"), item=objc_getClass("NSURLQueryItem");
  if(!cls||[cls isSubclassOfClass:[FBPURLComponents class]]||!item||[item isSubclassOfClass:[FBPURLQueryItem class]]) return;
  NSArray *selectors=@[@"init",@"initWithString:",@"initWithURL:resolvingAgainstBaseURL:",@"string",@"URL",@"URLRelativeToURL:",@"copyWithZone:",@"isEqual:",@"scheme",@"setScheme:",@"port",@"setPort:",@"queryItems",@"setQueryItems:"];
  for(NSString *s in selectors) if(![cls instancesRespondToSelector:NSSelectorFromString(s)]) return;
  for(NSString *s in @[@"user",@"password",@"host",@"path",@"query",@"fragment",@"percentEncodedUser",@"percentEncodedPassword",@"percentEncodedHost",@"percentEncodedPath",@"percentEncodedQuery",@"percentEncodedFragment"]) {
   NSString *setter=[NSString stringWithFormat:@"set%@%@:",[[s substringToIndex:1] uppercaseString],[s substringFromIndex:1]];
   if(![cls instancesRespondToSelector:NSSelectorFromString(s)]||![cls instancesRespondToSelector:NSSelectorFromString(setter)]) return;
  }
  if(![item instancesRespondToSelector:@selector(initWithName:value:)]) return;
  result=cls;
 }); return result;
#endif
}
static BOOL SameValue(id a,id b) { return a==b||[a isEqual:b]; }

static void FBPRegister(Class cls, const char *name) {
 if (!objc_getClass(name)) { Class alias=objc_allocateClassPair(cls,name,0); if(alias) objc_registerClassPair(alias); }
}
static NSString *Decode(NSString *s) { if(!s||[s rangeOfString:@"%"].location==NSNotFound) return s; return [s stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]; }
static BOOL ValidEscapes(NSString *s) {
 for(NSUInteger i=0;i<s.length;i++) if([s characterAtIndex:i]=='%') {
  if(i+2>=s.length) return NO;
  for(NSUInteger j=1;j<=2;j++) { unichar c=[s characterAtIndex:i+j]; if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F'))) return NO; } i+=2;
 } return YES;
}
static NSString *Encode(NSString *s, NSString *extra) {
 if(!s) return nil;
 NSData *data=[s dataUsingEncoding:NSUTF8StringEncoding]; if(!data) return nil; const unsigned char *b=data.bytes; const char *allowed=extra.UTF8String;
 NSMutableData *out=[NSMutableData dataWithLength:data.length*3]; unsigned char *p=out.mutableBytes; NSUInteger length=0; static const char hex[]="0123456789ABCDEF";
 for(NSUInteger i=0;i<data.length;i++) { unsigned char c=b[i];
  if(c&&((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||strchr("-._~",c)||(c<128&&strchr(allowed,c)))) p[length++]=c;
  else { p[length++]='%'; p[length++]=hex[c>>4]; p[length++]=hex[c&15]; }
 } return [[NSString alloc] initWithBytes:p length:length encoding:NSUTF8StringEncoding];
}
// Encode only raw bytes; existing validated escapes retain their spelling.
static NSString *Normalize(NSString *s, NSString *allowed) {
 if(!s) return nil;
 const unsigned char *bytes=(const unsigned char *)s.UTF8String; if(!bytes) return nil;
 NSUInteger length=[s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]; const char *extra=allowed.UTF8String;
 for(NSUInteger i=0;i<length;i++) { unsigned char c=bytes[i];
  if(!c) return Encode(s,[allowed stringByAppendingString:@"%"]);
  if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||strchr("-._~%",c)||(c<128&&strchr(extra,c)))) return Encode(s,[allowed stringByAppendingString:@"%"]);
 }
 return [s copy];
}
static NSString *ASCIIHost(NSString *host) {
 if(!host||[host canBeConvertedToEncoding:NSASCIIStringEncoding]) return host;
 // NSURL supplies the system IDNA conversion on runtimes that support it. On
 // iOS5 Unicode DNS names are intentionally unsupported (ASCII/punycode works).
 NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"http://%@/",host]];
 NSString *h=url.host;
 return h&&[h canBeConvertedToEncoding:NSASCIIStringEncoding]?h:host;
}
static void CheckEscapes(NSString *s, NSString *allowed) { if(!ValidEscapes(s)||![Normalize(s,allowed)?:@"" isEqual:s?:@""]) [NSException raise:NSInvalidArgumentException format:@"Invalid percent-encoded component: %@",s]; }
@implementation FBPURLQueryItem

+ (void)load { FBPRegister(self,"NSURLQueryItem"); }
+ (BOOL)supportsSecureCoding { return YES; }
+ (instancetype)queryItemWithName:(NSString *)name value:(NSString *)value { return [[self alloc] initWithName:name value:value]; }
- (instancetype)initWithName:(NSString *)name value:(NSString *)value { if(!name) [NSException raise:NSInvalidArgumentException format:@"nil query item name"]; if((self=[super init])) { _name=[name copy]; _value=[value copy]; } return self; }
- (instancetype)initWithCoder:(NSCoder *)c { id name,value; if(@available(iOS 6.0,*)) { name=[c decodeObjectOfClass:[NSString class] forKey:@"name"]; value=[c decodeObjectOfClass:[NSString class] forKey:@"value"]; } else { name=[c decodeObjectForKey:@"name"]; value=[c decodeObjectForKey:@"value"]; } if(![name isKindOfClass:[NSString class]]||(value&&![value isKindOfClass:[NSString class]])) [NSException raise:NSInvalidUnarchiveOperationException format:@"Invalid query item"]; return [self initWithName:name value:value]; }
- (void)encodeWithCoder:(NSCoder *)c { [c encodeObject:_name forKey:@"name"]; [c encodeObject:_value forKey:@"value"]; }
- (id)copyWithZone:(NSZone *)zone { return self; }
- (NSUInteger)hash { return _name.hash ^ _value.hash; }
- (BOOL)isEqual:(id)o { return o==self || ([o respondsToSelector:@selector(name)]&&[o respondsToSelector:@selector(value)]&&[_name isEqual:[o name]]&&(_value==[o value]||[_value isEqual:[o value]])); }
@end

@implementation FBPURLComponents {
 NSString *_scheme, *_percentEncodedUser, *_percentEncodedPassword, *_percentEncodedHost, *_percentEncodedPath, *_percentEncodedQuery, *_percentEncodedFragment;
 id _native;
 NSNumber *_port;
 BOOL _emptyPort;
}


+ (void)load { FBPRegister(self,"NSURLComponents"); }
- (instancetype)init { if((self=[super init])) {
 _percentEncodedPath=@"";
 Class native=NativeComponentsClass(); if(native) _native=[[native alloc] init];
 } return self; }
+ (instancetype)componentsWithString:(NSString *)s { return [[self alloc] initWithString:s]; }
+ (instancetype)componentsWithURL:(NSURL *)u resolvingAgainstBaseURL:(BOOL)r { return [[self alloc] initWithURL:u resolvingAgainstBaseURL:r]; }
- (instancetype)initWithURL:(NSURL *)u resolvingAgainstBaseURL:(BOOL)r {
 Class native=NativeComponentsClass();
 if(native) { if((self=[self init])) { _native=[[native alloc] initWithURL:u resolvingAgainstBaseURL:r]; if(!_native) return nil; } return self; }
 return [self initWithString:r?u.absoluteURL.absoluteString:u.relativeString];
}
- (instancetype)initWithString:(NSString *)s {
 if((self=[self init])&&_native) { _native=[[[_native class] alloc] initWithString:s]; if(!_native) return nil; return self; }
 if(!s || ![s dataUsingEncoding:NSUTF8StringEncoding] || !ValidEscapes(s)) return nil;
 if(!self) return nil;
 // RFC 3986: split delimiters before decoding; '+' is never form-decoded.
 NSString *rest=s; NSRange at=[rest rangeOfString:@"#"];
 if(at.location!=NSNotFound) { rest=[rest substringToIndex:at.location]; }
 at=[rest rangeOfString:@"?"];
 if(at.location!=NSNotFound) { _percentEncodedQuery=[[rest substringFromIndex:at.location+1] copy]; rest=[rest substringToIndex:at.location]; }
 at=[rest rangeOfString:@":"]; NSRange slash=[rest rangeOfString:@"/"];
 if(at.location!=NSNotFound&&(slash.location==NSNotFound||at.location<slash.location)) {
  NSString *candidate=[rest substringToIndex:at.location];
  if(!candidate.length) return nil;
  for(NSUInteger i=0;i<candidate.length;i++) { unichar c=[candidate characterAtIndex:i]; if(!((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(i&&((c>='0'&&c<='9')||c=='+'||c=='-'||c=='.')))) return nil; }
  _scheme=[candidate copy]; rest=[rest substringFromIndex:at.location+1];
 }
 if([rest hasPrefix:@"//"]) {
  rest=[rest substringFromIndex:2]; at=[rest rangeOfString:@"/"]; NSString *authority=at.location==NSNotFound?rest:[rest substringToIndex:at.location]; rest=at.location==NSNotFound?@"":[rest substringFromIndex:at.location];
  at=[authority rangeOfString:@"@" options:NSBackwardsSearch];
  if(at.location!=NSNotFound) { NSString *info=[authority substringToIndex:at.location]; authority=[authority substringFromIndex:at.location+1]; NSRange colon=[info rangeOfString:@":"]; _percentEncodedUser=[(colon.location==NSNotFound?info:[info substringToIndex:colon.location]) copy]; if(colon.location!=NSNotFound) _percentEncodedPassword=[[info substringFromIndex:colon.location+1] copy]; }
  NSUInteger hostEnd=authority.length;
  if([authority hasPrefix:@"["]) { NSRange close=[authority rangeOfString:@"]"]; if(close.location==NSNotFound) return nil; hostEnd=close.location+1; if(hostEnd<authority.length&&[authority characterAtIndex:hostEnd]!=':') return nil; }
  else { at=[authority rangeOfString:@":"]; if(at.location!=NSNotFound) hostEnd=at.location; }
  _percentEncodedHost=[[authority substringToIndex:hostEnd] copy];
  if(hostEnd<authority.length) { NSString *p=[authority substringFromIndex:hostEnd+1]; _emptyPort=!p.length; if(p.length) { unsigned long long value=0; for(NSUInteger i=0;i<p.length;i++){unichar c=[p characterAtIndex:i]; if(c<'0'||c>'9'||value>922337203685477580ULL) return nil; value=value*10+c-'0';} if(value>LLONG_MAX) return nil; _port=@(value); } }
 }
 _percentEncodedPath=[rest copy];
 // Do not decode/re-encode escaped delimiters; validation above is enough.
 NSRange q=[s rangeOfString:@"?"]; NSRange f=[s rangeOfString:@"#"];
 if(q.location!=NSNotFound&&(f.location==NSNotFound||q.location<f.location)) _percentEncodedQuery=[[s substringWithRange:NSMakeRange(q.location+1,(f.location==NSNotFound?s.length:f.location)-q.location-1)] copy];
 if(f.location!=NSNotFound) _percentEncodedFragment=[[s substringFromIndex:f.location+1] copy];
 _percentEncodedUser=Normalize(_percentEncodedUser,@"!$&'()*+,;=");
 _percentEncodedPassword=Normalize(_percentEncodedPassword,@"!$&'()*+,;=:");
 _percentEncodedHost=Normalize(_percentEncodedHost,@"!$&'()*+,;=[]:");
 _percentEncodedPath=Normalize(_percentEncodedPath,@"!$&'()*+,;=:@/");
 _percentEncodedQuery=Normalize(_percentEncodedQuery,@"!$&'()*+,;=:@/?");
 _percentEncodedFragment=Normalize(_percentEncodedFragment,@"!$&'()*+,;=:@/?");
 return self;
}
- (NSString *)scheme { return _native?[_native valueForKey:@"scheme"]:_scheme; }
- (void)setScheme:(NSString *)s { if(s&&!ValidScheme(s)) [NSException raise:NSInvalidArgumentException format:@"Invalid scheme"]; if(_native) { [_native setValue:s forKey:@"scheme"]; return; } _scheme=[s copy]; }
- (NSNumber *)port { return _native?[_native valueForKey:@"port"]:_port; }
- (void)setPort:(NSNumber *)p { if(_native) { [_native setValue:p forKey:@"port"]; return; } if(p&&p.longLongValue<0) [NSException raise:NSInvalidArgumentException format:@"Negative port"]; _port=[p copy]; _emptyPort=NO; }
#define COMPONENT(Name, name, Allowed) \
- (NSString *)name { return _native?[_native valueForKey:@#name]:Decode(_percentEncoded##Name); } \
- (NSString *)percentEncoded##Name { return _native?[_native valueForKey:@"percentEncoded" @#Name]:_percentEncoded##Name; } \
- (void)set##Name:(NSString *)s { if(_native) { [_native setValue:s forKey:@#name]; return; } _percentEncoded##Name=[Encode(s,Allowed) copy]; } \
- (void)setPercentEncoded##Name:(NSString *)s { if(_native) { [_native setValue:s forKey:@"percentEncoded" @#Name]; return; } CheckEscapes(s,Allowed); _percentEncoded##Name=[s copy]; }
COMPONENT(User,user,@"!$&'()*+,;=")
COMPONENT(Password,password,@"!$&'()*+,;=:")
COMPONENT(Host,host,@"!$&'()*+,;=[]:")
COMPONENT(Path,path,@"!$&'()*+,;=:@/")
COMPONENT(Query,query,@"!$&'()*+,;=:@/?")
COMPONENT(Fragment,fragment,@"!$&'()*+,;=:@/?")
#undef COMPONENT
- (NSArray *)queryItems { if(_native) { NSArray *nativeItems=[_native valueForKey:@"queryItems"]; if(!nativeItems) return nil; NSMutableArray *out=[NSMutableArray array]; for(id item in nativeItems) [out addObject:[FBPURLQueryItem queryItemWithName:[item name] value:[item value]]]; return out; } if(!_percentEncodedQuery) return nil; if(!_percentEncodedQuery.length) return @[]; NSMutableArray *items=[NSMutableArray array]; for(NSString *pair in [_percentEncodedQuery componentsSeparatedByString:@"&"]) { NSRange eq=[pair rangeOfString:@"="]; NSString *n=eq.location==NSNotFound?pair:[pair substringToIndex:eq.location]; NSString *v=eq.location==NSNotFound?nil:[pair substringFromIndex:eq.location+1]; [items addObject:[FBPURLQueryItem queryItemWithName:Decode(n)?:@"" value:Decode(v)]]; } return items; }
- (void)setQueryItems:(NSArray *)items { if(_native) { NSMutableArray *converted=items?[NSMutableArray array]:nil; Class cls=objc_getClass("NSURLQueryItem"); for(id item in items) [converted addObject:[[cls alloc] initWithName:[item name] value:[item value]]]; [_native setValue:converted forKey:@"queryItems"]; return; } if(!items) { _percentEncodedQuery=nil; return; } NSMutableArray *pairs=[NSMutableArray array]; for(id item in items) { NSString *name=Encode([item name],@"!$'()*+,;:@/?"); NSString *v=[item value]; [pairs addObject:v?[NSString stringWithFormat:@"%@=%@",name,Encode(v,@"!$'()*+,;:@/?")]:name]; } _percentEncodedQuery=[[pairs componentsJoinedByString:@"&"] copy]; }
- (NSString *)string { if(_native) return [_native valueForKey:@"string"]; BOOL authority=_percentEncodedHost!=nil||_percentEncodedUser!=nil||_port!=nil; NSString *path=_percentEncodedPath?:@""; if((authority&&path.length&&![path hasPrefix:@"/"])||(!authority&&[path hasPrefix:@"//"])) return nil;
 NSMutableString *s=[NSMutableString string]; if(_scheme) [s appendFormat:@"%@:",_scheme]; if(authority) { [s appendString:@"//"]; if(_percentEncodedUser) { [s appendString:_percentEncodedUser]; if(_percentEncodedPassword) [s appendFormat:@":%@",_percentEncodedPassword]; [s appendString:@"@"]; } [s appendString:([self.host canBeConvertedToEncoding:NSASCIIStringEncoding]?_percentEncodedHost:ASCIIHost(self.host))?:@""]; if(_port) [s appendFormat:@":%@",_port]; else if(_emptyPort) [s appendString:@":"]; } [s appendString:path]; if(_percentEncodedQuery) [s appendFormat:@"?%@",_percentEncodedQuery]; if(_percentEncodedFragment) [s appendFormat:@"#%@",_percentEncodedFragment]; return s;
}
- (NSURL *)URL { return [self URLRelativeToURL:nil]; }
- (NSURL *)URLRelativeToURL:(NSURL *)base { if(_native) return [_native URLRelativeToURL:base]; NSString *s=self.string; return s?[NSURL URLWithString:s relativeToURL:base]:nil; }
- (id)copyWithZone:(NSZone *)zone { FBPURLComponents *c=[[[self class] allocWithZone:zone] init]; if(_native) { c->_native=[_native copy]; return c; } c->_scheme=[_scheme copy]; c->_port=[_port copy]; c->_emptyPort=_emptyPort; c->_percentEncodedUser=[_percentEncodedUser copy]; c->_percentEncodedPassword=[_percentEncodedPassword copy]; c->_percentEncodedHost=[_percentEncodedHost copy]; c->_percentEncodedPath=[_percentEncodedPath copy]; c->_percentEncodedQuery=[_percentEncodedQuery copy]; c->_percentEncodedFragment=[_percentEncodedFragment copy]; return c; }
- (BOOL)isEqual:(id)o {
 if(o==self) return YES; if(![o isKindOfClass:[FBPURLComponents class]]) return NO;
 FBPURLComponents *other=o; if(_native&&other->_native) return [_native isEqual:other->_native];
 // Native compares encoded component spellings and numeric ports, ignoring an
 // empty port delimiter. Comparing serialized strings incorrectly includes it.
 return SameValue(self.scheme,other.scheme)&&SameValue(self.port,other.port)&&SameValue(self.percentEncodedUser,other.percentEncodedUser)&&SameValue(self.percentEncodedPassword,other.percentEncodedPassword)&&SameValue(self.percentEncodedHost,other.percentEncodedHost)&&SameValue(self.percentEncodedPath,other.percentEncodedPath)&&SameValue(self.percentEncodedQuery,other.percentEncodedQuery)&&SameValue(self.percentEncodedFragment,other.percentEncodedFragment);
}
- (NSUInteger)hash { return self.scheme.hash^self.port.hash^self.percentEncodedUser.hash^self.percentEncodedPassword.hash^self.percentEncodedHost.hash^self.percentEncodedPath.hash^self.percentEncodedQuery.hash^self.percentEncodedFragment.hash; }
@end
