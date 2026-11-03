//===--- Availability.mm - Swift Language API Availability Support --------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// Implementation of run-time API availability queries.
//
//===----------------------------------------------------------------------===//

#include "swift/Runtime/Config.h"

#if SWIFT_OBJC_INTEROP && defined(SWIFT_RUNTIME_OS_VERSIONING)
#include "swift/Basic/Lazy.h"
#include "swift/Runtime/Debug.h"
#include "swift/shims/FoundationShims.h"
#include <TargetConditionals.h>

struct os_system_version_s {
    unsigned int major;
    unsigned int minor;
    unsigned int patch;
};

// This is in libSystem, so it's OK to refer to it directly here
extern "C" int os_system_version_get_current_version(struct os_system_version_s * _Nonnull) SWIFT_RUNTIME_WEAK_IMPORT;

#if defined(SWIFT_LEGACY_IOS5)
#include <CoreFoundation/CoreFoundation.h>

// os_system_version_get_current_version does not exist before iOS 12 (the
// import is weak, so it is a null pointer on older systems). Read the same
// information from SystemVersion.plist with CoreFoundation only: this runs
// lazily from the first availability check, with no Objective-C or Swift
// bridging involved.
static bool getOSVersionFromPlist(struct os_system_version_s &vers) {
  CFURLRef url = CFURLCreateWithFileSystemPath(
      kCFAllocatorDefault,
      CFSTR("/System/Library/CoreServices/SystemVersion.plist"),
      kCFURLPOSIXPathStyle, false);
  if (!url)
    return false;

  CFDataRef data = nullptr;
  bool loaded = CFURLCreateDataAndPropertiesFromResource(
      kCFAllocatorDefault, url, &data, nullptr, nullptr, nullptr);
  CFRelease(url);
  if (!loaded || !data)
    return false;

  CFPropertyListRef plist = CFPropertyListCreateFromXMLData(
      kCFAllocatorDefault, data, kCFPropertyListImmutable, nullptr);
  CFRelease(data);
  if (!plist)
    return false;

  bool ok = false;
  if (CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
    CFTypeRef value =
        CFDictionaryGetValue((CFDictionaryRef)plist, CFSTR("ProductVersion"));
    char buffer[64];
    if (value && CFGetTypeID(value) == CFStringGetTypeID() &&
        CFStringGetCString((CFStringRef)value, buffer, sizeof(buffer),
                           kCFStringEncodingUTF8)) {
      // "x[.y[.z]]"
      unsigned parts[3] = {0, 0, 0};
      unsigned index = 0;
      for (const char *c = buffer; *c && index < 3; ++c) {
        if (*c >= '0' && *c <= '9')
          parts[index] = parts[index] * 10 + (unsigned)(*c - '0');
        else if (*c == '.')
          ++index;
        else
          break;
      }
      vers.major = parts[0];
      vers.minor = parts[1];
      vers.patch = parts[2];
      ok = parts[0] != 0;
    }
  }
  CFRelease(plist);
  return ok;
}
#endif

static os_system_version_s getOSVersion() {
  struct os_system_version_s vers = { 0, 0, 0 };
#if defined(SWIFT_LEGACY_IOS5)
  if (!SWIFT_RUNTIME_WEAK_CHECK(os_system_version_get_current_version)) {
    if (!getOSVersionFromPlist(vers))
      swift::fatalError(/* flags = */ 0,
                        "Unable to check API availability: "
                        "system version could not be determined");
    return vers;
  }
#endif
  SWIFT_RUNTIME_WEAK_USE(os_system_version_get_current_version(&vers));
  return vers;
}

using namespace swift;

/// Return the version of the operating system currently running for use in
/// API availability queries.
///
/// This is ABI and cannot be removed. Even though _stdlib_isOSVersionAtLeast()
/// is no longer inlinable, is previously was and so calls to this method
/// have been inlined into shipped apps.
_SwiftNSOperatingSystemVersion _swift_stdlib_operatingSystemVersion() {
  os_system_version_s version = SWIFT_LAZY_CONSTANT(getOSVersion());

  return { (int)version.major, (int)version.minor, (int)version.patch };
}
#endif

