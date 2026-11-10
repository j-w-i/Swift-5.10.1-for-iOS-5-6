import Foundation
import Darwin

// Run unchanged with native Foundation and the legacy overlay; compare output.
NSSetUncaughtExceptionHandler { exception in
    print("OBJC EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "unknown")")
    fflush(stdout)
    exit(86)
}
let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
let root = parent.appendingPathComponent("foundation-file-parity-" + UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: nil)
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(name)"); fflush(stdout)
    precondition(condition)
}
let payload = Data((0..<4096).map { UInt8($0 % 251) })
let file = root.appendingPathComponent("data.bin")
try payload.write(to: file)
check("plain Data.write and read", try Data(contentsOf: file) == payload)
try Data([7, 8, 9]).write(to: file)
check("overwrite truncates existing file", try Data(contentsOf: file) == Data([7, 8, 9]))
try Data().write(to: file)
check("empty write creates/truncates file", try Data(contentsOf: file).isEmpty)
try payload.write(to: file, options: .atomic)
check("atomic Data.write and read", try Data(contentsOf: file) == payload)
var refused = false
do { try Data([42]).write(to: file, options: Data.WritingOptions(rawValue: 2)) }
catch { let e = error as NSError; refused = e.domain == NSCocoaErrorDomain && e.code == 516 }
check("without-overwriting reports Cocoa file-exists", refused)
check("failed exclusive write preserves contents", try Data(contentsOf: file) == payload)
var missingParent = false
do { try payload.write(to: root.appendingPathComponent("missing/child.bin")) }
catch { let e = error as NSError; missingParent = e.domain == NSCocoaErrorDomain && e.code == 4 }
check("missing parent reports Cocoa no-such-file", missingParent)
// This exact unique directory was created above, never an arbitrary caller path.
precondition(root.deletingLastPathComponent().path == parent.path)
try FileManager.default.removeItem(at: root)
print("FILE IO PARITY PASS"); fflush(stdout)
