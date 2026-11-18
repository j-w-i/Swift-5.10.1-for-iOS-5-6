// Interop fixes reported while porting an Objective-C app to Swift for iOS 5. Run through the device runner:
//   SWIFT_EXTRA="-import-objc-header $PWD/LegacyInteropFixes.h" EXTRA_LIBS=UIKit bash run-on-ipod.sh LegacyInteropFixes.swift TOOLCHAIN
// * APIs deprecated in iOS 7 or earlier (stock Swift: unavailable) are callable and behave as in Objective-C.
// * NSTextAlignment / NSLineBreakMode / NSWritingDirection (iOS 6 names of iOS 2-3.2 enums) carry the iOS 5 values.
// * A @_cdecl function called through its imported C declaration (5.10 crashed in SILGen/IRGen on arm64).
// UIFont and UILabel trap in CoreFoundation outside a launched app, so text drawing and measuring
// (sizeWithFont:, drawInRect:withFont:) are covered by check-backports-api.sh, not here.
import UIKit
import AudioToolbox
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}

// Deprecated <= iOS 7
let controller = UIViewController()
controller.contentSizeForViewInPopover = CGSize(width: 320, height: 200)
check(controller.contentSizeForViewInPopover == CGSize(width: 320, height: 200), "contentSizeForViewInPopover round-trips")
let initialized = AudioSessionInitialize(nil, nil, nil, nil)
check(initialized == noErr || initialized == OSStatus(kAudioSessionAlreadyInitialized), "AudioSessionInitialize (\(initialized))")
var category = UInt32(kAudioSessionCategory_AmbientSound)
let status = AudioSessionSetProperty(AudioSessionPropertyID(kAudioSessionProperty_AudioCategory),
                                     UInt32(MemoryLayout<UInt32>.size), &category)
check(status == noErr, "AudioSessionSetProperty(AudioCategory) == noErr (\(status))")
var readBack: UInt32 = 0
var size = UInt32(MemoryLayout<UInt32>.size)
check(AudioSessionGetProperty(AudioSessionPropertyID(kAudioSessionProperty_AudioCategory), &size, &readBack) == noErr
      && readBack == UInt32(kAudioSessionCategory_AmbientSound), "AudioSessionGetProperty reads the category back")

// iOS 6 enum names at iOS 5: the raw values UIKit 5 expects
func alignment(_ a: NSTextAlignment) -> NSTextAlignment { a }
check(alignment(.left).rawValue == 0 && alignment(.center).rawValue == 1 && alignment(.right).rawValue == 2,
      "NSTextAlignment left/center/right are UITextAlignment's 0/1/2")
let modes: [NSLineBreakMode] = [.byWordWrapping, .byCharWrapping, .byClipping, .byTruncatingHead, .byTruncatingTail, .byTruncatingMiddle]
check(modes.map { $0.rawValue } == [0, 1, 2, 3, 4, 5], "NSLineBreakMode is UILineBreakMode 0...5")
let directions: [NSWritingDirection] = [.natural, .leftToRight, .rightToLeft]
check(directions.map { $0.rawValue } == [-1, 0, 1], "NSWritingDirection is UITextWritingDirection -1/0/1")

// @_cdecl definitions called through their imported declarations
var flag: Int32 = 0
@_cdecl("LegacyInteropFlagEnabled") func legacyFlagExport() -> ObjCBool { ObjCBool(flag != 0) }
@_cdecl("LegacyInteropSetFlagEnabled") func legacySetFlagExport(_ enabled: ObjCBool) { flag = enabled.boolValue ? 1 : 0 }
LegacyInteropSetFlagEnabled(true)
check(flag == 1 && LegacyInteropFlagEnabled(), "C call into @_cdecl setter/getter (true)")
LegacyInteropSetFlagEnabled(false)
check(flag == 0 && !LegacyInteropFlagEnabled(), "C call into @_cdecl setter/getter (false)")
let pointer: @convention(c) () -> ObjCBool = legacyFlagExport
LegacyInteropSetFlagEnabled(true)
check(pointer().boolValue, "C function pointer to the @_cdecl definition agrees")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(Int32(failures))
