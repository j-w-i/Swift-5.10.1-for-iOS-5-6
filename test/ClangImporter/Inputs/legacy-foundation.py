"""Foundation capability regression using a synthetic native SDK, no stdlib."""
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
compiler = sys.argv[2:]
frameworks = root / 'sdk/System/Library/Frameworks'
# Each supported selector must be independently callable. Unknown selectors on
# lowered classes must not leak through inherited class availability.
allowed = {
    'NSURLComponents': (8, ['initWithString:', 'componentsWithURL:resolvingAgainstBaseURL:', 'scheme', 'setScheme:', 'queryItems', 'setQueryItems:', 'string', 'URLRelativeToURL:']),
    'NSURLQueryItem': (8, ['initWithName:value:', 'queryItemWithName:value:', 'name', 'value']),
    'NSISO8601DateFormatter': (10, ['stringFromDate:', 'dateFromString:', 'stringFromDate:timeZone:formatOptions:', 'formatOptions', 'setFormatOptions:']),
    'NSURLSessionConfiguration': (7, ['defaultSessionConfiguration', 'requestCachePolicy', 'setRequestCachePolicy:', 'HTTPAdditionalHeaders']),
    'NSURLSession': (7, ['sessionWithConfiguration:', 'sessionWithConfiguration:delegate:delegateQueue:', 'dataTaskWithRequest:completionHandler:', 'downloadTaskWithURL:', 'uploadTaskWithRequest:fromData:completionHandler:', 'invalidateAndCancel']),
    'NSURLSessionTask': (7, ['resume', 'cancel', 'state', 'taskDescription', 'setTaskDescription:']),
    'NSURLSessionDataTask': (7, []),
    'NSURLSessionUploadTask': (7, []),
    'NSURLSessionDownloadTask': (7, []),
    'NSTimer': (2, ['timerWithTimeInterval:repeats:block:', 'scheduledTimerWithTimeInterval:repeats:block:', 'initWithFireDate:interval:repeats:block:']),
    'NSCalendar': (2, ['isDateInToday:', 'isDateInYesterday:', 'isDateInTomorrow:', 'isDate:inSameDayAsDate:']),
    'NSString': (2, ['stringByAddingPercentEncodingWithAllowedCharacters:', 'stringByRemovingPercentEncoding']),
    'NSCharacterSet': (2, ['URLUserAllowedCharacterSet', 'URLPasswordAllowedCharacterSet', 'URLHostAllowedCharacterSet', 'URLPathAllowedCharacterSet', 'URLQueryAllowedCharacterSet', 'URLFragmentAllowedCharacterSet']),
}
denied = {
    'NSURLComponents': ['unknownInherited', 'percentEncodedQueryItems', 'rangeOfScheme'],
    'NSURLQueryItem': ['unknownInherited'],
    'NSISO8601DateFormatter': ['unknownInherited'],
    'NSURLSessionConfiguration': ['ephemeralSessionConfiguration', 'identifier', 'timeoutIntervalForResource', 'protocolClasses', 'HTTPCookieStorage', 'allowsCellularAccess'],
    'NSURLSession': ['uploadTaskWithRequest:fromFile:', 'downloadTaskWithResumeData:', 'unknownInherited'],
    'NSURLSessionTask': ['suspend', 'priority', 'unknownInherited'],
    'NSURLSessionDownloadTask': ['cancelByProducingResumeData:'],
}
# Fill out both accessor directions for every supported stored capability.
for owner, properties in {
    'NSURLComponents': ['scheme', 'user', 'password', 'host', 'port', 'path', 'query', 'fragment', 'percentEncodedUser', 'percentEncodedPassword', 'percentEncodedHost', 'percentEncodedPath', 'percentEncodedQuery', 'percentEncodedFragment', 'queryItems'],
    'NSISO8601DateFormatter': ['timeZone', 'formatOptions'],
    'NSURLSessionConfiguration': ['requestCachePolicy', 'timeoutIntervalForRequest', 'HTTPAdditionalHeaders', 'HTTPShouldSetCookies', 'HTTPShouldUsePipelining'],
    'NSURLSession': ['sessionDescription'],
    'NSURLSessionTask': ['taskDescription'],
}.items():
    for prop in properties:
        for selector in (prop, 'set' + prop[0].upper() + prop[1:] + ':'):
            if selector not in allowed[owner][1]:
                allowed[owner][1].append(selector)
entries = []
header = '#pragma once\n#define AV(v) __attribute__((availability(ios,introduced=v)))\n__attribute__((objc_root_class)) @interface SDKObject @end\n'
for owner, (intro, selectors) in allowed.items():
    header += 'AV(%d) @interface %s : SDKObject\n' % (intro, owner)
    for selector in selectors + denied.get(owner, []):
        if owner == 'NSURLComponents' and selector in ('host', 'setHost:'):
            continue  # Real property declarations below supply these accessors.
        index = len(entries)
        entries.append((owner, selector, selector in selectors))
        slots = selector.split(':')[:-1]
        decl = ''.join('%s:(SDKObject * _Nonnull)a%d ' % (s, i) for i, s in enumerate(slots)) if slots else selector
        # Later annotations cannot make missing facade selectors safe, even
        # inside an availability-annotated function. Other denials inherit.
        av = ' AV(11)' if selector == 'percentEncodedQueryItems' else (' AV(9)' if selector == 'rangeOfScheme' else '')
        if intro == 2:
            av = ' AV(%d)' % (10 if owner == 'NSTimer' else (8 if owner == 'NSCalendar' else 7))
        header += '- (SDKObject * _Nonnull)%s%s __attribute__((swift_name("probe%d(%s)")));\n' % (decl, av, index, ':'.join('_' for _ in slots) + (':' if slots else ''))
    # Real properties test the no-own-availability path separately from methods.
    if owner == 'NSURLComponents':
        header += '@property(readonly) SDKObject * _Nonnull host __attribute__((swift_name("probeHost")));\n@property(readonly) SDKObject * _Nonnull unsupportedProperty __attribute__((swift_name("probeUnsupported")));\n'
    header += '@end\n'
# Protocol members likewise inherit only the protocol introduction in the SDK.
protocols = {
    'NSURLSessionDelegate': ['URLSession:didBecomeInvalidWithError:'],
    'NSURLSessionTaskDelegate': ['URLSession:task:didCompleteWithError:', 'URLSession:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:'],
    'NSURLSessionDataDelegate': ['URLSession:dataTask:didReceiveData:'],
    'NSURLSessionDownloadDelegate': ['URLSession:downloadTask:didFinishDownloadingToURL:', 'URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:'],
}
for owner, selectors in protocols.items():
    header += 'AV(7) @protocol %s\n' % owner
    for selector in selectors + ['unsupportedInherited:']:
        index = len(entries)
        entries.append((owner, selector, selector in selectors))
        slots = selector.split(':')[:-1]
        decl = ''.join('%s:(SDKObject * _Nonnull)a%d ' % (s, i) for i, s in enumerate(slots))
        header += '- (SDKObject * _Nonnull)%s __attribute__((swift_name("probe%d(%s)")));\n' % (decl, index, '_:' * len(slots))
    header += '@end\n'
constants = {
    'NSISO8601DateFormatWithInternetDateTime': 10,
    'NSISO8601DateFormatWithFractionalSeconds': 11,
    'NSISO8601DateFormatWithWeekOfYear': 10,
    'NSISO8601DateFormatFutureOption': 12,
    'NSDataBase64Encoding64CharacterLineLength': 7,
    'NSDataBase64DecodingIgnoreUnknownCharacters': 7,
    'NSURLSessionTaskStateRunning': 7,
}
for name, intro in constants.items():
    header += 'extern SDKObject * _Nonnull %s AV(%d);\n' % (name, intro)
for module in ('Foundation', 'Unrelated'):
    fw = frameworks / (module + '.framework')
    (fw / 'Headers').mkdir(parents=True, exist_ok=True)
    (fw / 'Modules').mkdir(parents=True, exist_ok=True)
    (fw / 'Headers' / (module + '.h')).write_text(header)
    (fw / 'Modules/module.modulemap').write_text('framework module %s { umbrella header "%s.h" export * }\n' % (module, module))
runs = 0

def check(label, source, target='armv7-apple-ios5.0', legacy=True, error=None, extra=()):
    global runs
    path = root / (label + '.swift')
    path.write_text(source)
    args = compiler + [str(path), '-typecheck', '-parse-stdlib', '-sdk', str(root / 'sdk'), '-target', target, '-module-cache-path', str(root / 'cache')]
    if legacy:
        args += ['-enable-legacy-ios5-runtime']
    result = subprocess.run(args + list(extra), text=True, capture_output=True)
    runs += 1
    if error:
        assert result.returncode and error in result.stderr, (label, result.stderr)
    else:
        assert result.returncode == 0, (label, result.stderr)
    print('PASS', label)

def call(index, module='Foundation'):
    owner, selector, _ = entries[index]
    args = ', '.join('x' for _ in range(selector.count(':')))
    receiver = module + '.' + owner if selector.startswith('init') else 'v'
    return 'import %s\nfunc f(_ v: %s.%s, _ x: %s.SDKObject) -> %s.SDKObject { %s.probe%d(%s) }\n' % (module, module, owner, module, module, receiver, index, args)

for index, (owner, selector, supported) in enumerate(entries):
    check('member%d' % index, call(index), error=None if supported else 'not implemented by the legacy iOS 5 Foundation runtime')
    if selector in ('rangeOfScheme', 'percentEncodedQueryItems'):
        guarded = call(index).replace('func f(', '@available(iOS 13.0, *)\nfunc f(')
        check('guarded%d' % index, guarded, error='not implemented by the legacy iOS 5 Foundation runtime')
# Native later targets see their original API, including the unimplemented paths.
for index, (owner, selector, supported) in enumerate(entries):
    check('native%d' % index, call(index), target='arm64-apple-ios13.0', legacy=False)
source = 'import Foundation\nfunc f(_ x: Foundation.NSURLComponents) {}\n'
for label, target, legacy, extra in (
    ('ios51', 'armv7-apple-ios5.1', True, ()),
    ('ios6', 'armv7-apple-ios6.0', True, ()),
    ('disabled', 'armv7-apple-ios5.0', False, ()),
    ('clang6', 'armv7-apple-ios5.0', True, ('-clang-target', 'armv7-apple-ios6.0')),
    ('simulator', 'armv7-apple-ios5.0', True, ('-clang-target', 'i386-apple-ios5.0-simulator')),
):
    check(label, source, target=target, legacy=legacy, extra=extra, error=None if label == 'ios51' else 'only available')
check('unrelated', source.replace('Foundation', 'Unrelated'), error='only available')
iso_source = 'import Foundation\nfunc f(_ x: Foundation.NSISO8601DateFormatter) {}\n'
check('swift7_clang5', iso_source, target='armv7-apple-ios7.0', extra=('-clang-target', 'armv7-apple-ios5.0'), error='only available')
check('swift5_clang7', iso_source, extra=('-clang-target', 'armv7-apple-ios7.0'), error='only available')
check('clang_arm64', iso_source, extra=('-clang-target', 'arm64-apple-ios7.0'), error='only available')
check('propertyAllowed', 'import Foundation\nfunc f(_ x: Foundation.NSURLComponents) -> Foundation.SDKObject { x.probeHost }\n')
check('propertyDenied', 'import Foundation\nfunc f(_ x: Foundation.NSURLComponents) -> Foundation.SDKObject { x.probeUnsupported }\n', error='not implemented by the legacy iOS 5 Foundation runtime')
for name in constants:
    source = 'import Foundation\nfunc f() -> Foundation.SDKObject { Foundation.%s }\n' % name
    error = ('not implemented' if name.endswith('WeekOfYear') else ('only available' if name.endswith('FutureOption') else None))
    check(name, source, error=error)
    check(name + '_native', source, target='arm64-apple-ios13.0', legacy=False)
print('PASS Foundation capability checks:', runs)
