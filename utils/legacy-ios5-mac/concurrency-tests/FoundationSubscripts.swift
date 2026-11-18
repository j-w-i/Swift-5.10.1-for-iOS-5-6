// Object subscripting on iOS 5 (FBPSubscriptExtras.m in the legacy Foundation runtime, plus the importer lowering
// the iOS 6 subscript declarations). Run with run-on-ipod.sh; expect "ALL PASS".
//
// Swift: NSArray/NSMutableArray/NSOrderedSet/NSMutableOrderedSet subscripts compile for an iOS 5 target and run.
// Objective-C: the four selectors clang emits for `a[i]`, `a[i] = x`, `d[k]`, `d[k] = x` exist and behave, called
// through their implementations exactly as compiled Objective-C code calls them.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}

// Swift subscripts.
let array: NSArray = ["a", "b", "c"]
check(array[1] as? String == "b", "NSArray subscript get")
let mutable: NSMutableArray = ["a", "b"]
mutable[0] = "A"
mutable[2] = "c"  // index == count appends
check(mutable == ["A", "b", "c"] as NSArray, "NSMutableArray subscript replace and append")
let ordered = NSOrderedSet(array: ["x", "y"])
check(ordered[1] as? String == "y", "NSOrderedSet subscript get")
let mutableOrdered = NSMutableOrderedSet(array: ["x", "y"])
mutableOrdered[0] = "X"
mutableOrdered[2] = "z"
check(mutableOrdered.array as NSArray == ["X", "y", "z"] as NSArray, "NSMutableOrderedSet subscript replace and append")
let dictionary: NSMutableDictionary = ["k": 1]
dictionary["n"] = 2
dictionary["k"] = nil
check(dictionary == ["n": 2] as NSDictionary, "NSMutableDictionary subscript set and remove")

// Objective-C selectors.
let selectors: [(AnyClass, String)] = [
    (NSArray.self, "objectAtIndexedSubscript:"), (NSMutableArray.self, "setObject:atIndexedSubscript:"),
    (NSDictionary.self, "objectForKeyedSubscript:"), (NSMutableDictionary.self, "setObject:forKeyedSubscript:"),
    (NSOrderedSet.self, "objectAtIndexedSubscript:"), (NSMutableOrderedSet.self, "setObject:atIndexedSubscript:")]
for (cls, name) in selectors {
    check(cls.instancesRespond(to: Selector(name)), "-[\(cls) \(name)] present")
}

typealias IndexedGet = @convention(c) (AnyObject, Selector, UInt) -> Unmanaged<AnyObject>
typealias IndexedSet = @convention(c) (AnyObject, Selector, AnyObject, UInt) -> Void
typealias KeyedGet = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
typealias KeyedSet = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject) -> Void

func imp<T>(_ object: NSObject, _ name: String, as: T.Type) -> T {
    unsafeBitCast(object.method(for: Selector(name)), to: T.self)
}

let objcArray = NSMutableArray(array: ["p", "q"])
let get = imp(objcArray, "objectAtIndexedSubscript:", as: IndexedGet.self)
let set = imp(objcArray, "setObject:atIndexedSubscript:", as: IndexedSet.self)
check(get(objcArray, Selector("objectAtIndexedSubscript:"), 1).takeUnretainedValue() as? String == "q", "objc array[i]")
set(objcArray, Selector("setObject:atIndexedSubscript:"), "r" as NSString, 2)
set(objcArray, Selector("setObject:atIndexedSubscript:"), "P" as NSString, 0)
check(objcArray == ["P", "q", "r"] as NSArray, "objc array[i] = x (replace, append at count)")

let objcDictionary = NSMutableDictionary(dictionary: ["a": 1])
let keyedGet = imp(objcDictionary, "objectForKeyedSubscript:", as: KeyedGet.self)
let keyedSet = imp(objcDictionary, "setObject:forKeyedSubscript:", as: KeyedSet.self)
check((keyedGet(objcDictionary, Selector("objectForKeyedSubscript:"), "a" as NSString)?.takeUnretainedValue() as? NSNumber) == 1,
      "objc dict[k]")
check(keyedGet(objcDictionary, Selector("objectForKeyedSubscript:"), "missing" as NSString) == nil, "objc dict[missing] is nil")
keyedSet(objcDictionary, Selector("setObject:forKeyedSubscript:"), "v" as NSString, "b" as NSString)
keyedSet(objcDictionary, Selector("setObject:forKeyedSubscript:"), nil, "a" as NSString)
check(objcDictionary == ["b": "v"] as NSDictionary, "objc dict[k] = x and dict[k] = nil")

let objcOrdered = NSMutableOrderedSet(array: ["m", "n"])
let orderedGet = imp(objcOrdered, "objectAtIndexedSubscript:", as: IndexedGet.self)
let orderedSet = imp(objcOrdered, "setObject:atIndexedSubscript:", as: IndexedSet.self)
orderedSet(objcOrdered, Selector("setObject:atIndexedSubscript:"), "o" as NSString, 2)
check(orderedGet(objcOrdered, Selector("objectAtIndexedSubscript:"), 2).takeUnretainedValue() as? String == "o",
      "objc orderedSet[i] and orderedSet[i] = x")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
