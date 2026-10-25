// Real-device runtime fixture: compile into the existing app scaffold and call
// runGenericRuntimeSmoke() after launch. No XCTest, UIKit, entry point, or mocks.
// PASS lines describe observations from that invocation, not build-time proof.
// In particular, only execution on an actual iOS 5 device validates iOS 5.
import Foundation

private protocol GenericSmokeReadable {
    func smokeText() -> String
}

private final class GenericSmokeCounts {
    var baseDeinits = 0
    var derivedDeinits = 0
    var payloadDeinits = 0
}

private class GenericSmokeBox<Value>: NSObject, GenericSmokeReadable {
    let value: Value
    let counts: GenericSmokeCounts

    init(_ value: Value, counts: GenericSmokeCounts) {
        self.value = value
        self.counts = counts
        super.init()
    }

    func smokeText() -> String {
        return String(describing: value)
    }

    // A Swift-only generic method, deliberately not exposed to Objective-C.
    @nonobjc func echo<Other>(_ other: Other) -> Other {
        return other
    }

    deinit {
        counts.baseDeinits += 1
    }
}

private final class GenericSmokeChild<Value>: GenericSmokeBox<Value> {
    override func smokeText() -> String {
        return "child:" + super.smokeText()
    }

    deinit {
        counts.derivedDeinits += 1
    }
}

private final class GenericSmokePayload {
    let counts: GenericSmokeCounts

    init(_ counts: GenericSmokeCounts) {
        self.counts = counts
    }

    deinit {
        counts.payloadDeinits += 1
    }
}

private final class GenericSmokeWeakReference {
    weak var object: AnyObject?

    init(_ object: AnyObject) {
        self.object = object
    }
}

// Objective-C entry points live on a concrete, non-generic NSObject subclass.
private final class GenericSmokeSelectorTarget: NSObject {
    @objc func smokeSelectorValue() -> NSString {
        return "selector-ok"
    }
}

// Separate call boundary ensures all strong locals disappear before checking
// counters. The caller also drains an autorelease pool before inspecting them.
@inline(never)
private func genericSmokeMakeLifetimeProbe(
    _ counts: GenericSmokeCounts
) -> GenericSmokeWeakReference {
    let child = GenericSmokeChild(GenericSmokePayload(counts), counts: counts)
    let object: AnyObject = child
    let base: GenericSmokeBox<GenericSmokePayload> = child
    let readable: GenericSmokeReadable = base
    _ = readable.smokeText()
    _ = object as? GenericSmokeChild<GenericSmokePayload>
    return GenericSmokeWeakReference(object)
}

/// Executes real runtime operations and returns one PASS/FAIL line per check.
/// Invoke serially from the app (normally on its main thread); no global state
/// is used. A runtime crash is itself a failed smoke run, not a returned PASS.
public func runGenericRuntimeSmoke() -> [String] {
    var results: [String] = []
    func check(_ passed: Bool, _ name: String, _ detail: String = "") {
        results.append((passed ? "PASS " : "FAIL ") + name
            + (detail.isEmpty ? "" : ": " + detail))
    }

    autoreleasepool {
        let counts = GenericSmokeCounts()
        let first = GenericSmokeBox<Int>(42, counts: counts)
        let second = GenericSmokeBox<Int>(7, counts: counts)
        let text = GenericSmokeBox<String>("hello", counts: counts)
        let child = GenericSmokeChild<Int>(9, counts: counts)

        // Compare actual class metadata identities, never fixed addresses or
        // ABI offsets. Do not dereference metadata/ObjC class RO flags: their
        // layout is runtime-specific, even within 32-bit ARM deployments.
        let intClass = ObjectIdentifier(type(of: first))
        check(intClass == ObjectIdentifier(type(of: second)),
              "metadata.same-specialization")
        check(intClass != ObjectIdentifier(type(of: text)),
              "metadata.distinct-specializations")
        check(intClass != ObjectIdentifier(type(of: child)),
              "metadata.derived-class")
        check(ObjectIdentifier(type(of: first))
                == ObjectIdentifier(GenericSmokeBox<Int>.self),
              "metadata.static-dynamic-agreement")

        let object: NSObject = first
        let erased: AnyObject = object
        check((erased as? GenericSmokeBox<Int>) === first,
              "NSObject.identity-round-trip")
        check((erased as? GenericSmokeBox<String>) == nil,
              "cast.reject-wrong-generic-argument")
        let childObject: AnyObject = child
        let base = childObject as? GenericSmokeBox<Int>
        check(base === child && base?.smokeText() == "child:9",
              "inheritance.generic-base-and-override")
        let readable = childObject as? GenericSmokeReadable
        check(readable?.smokeText() == "child:9",
              "cast.protocol-and-dynamic-dispatch")
        check((childObject as? GenericSmokeChild<String>) == nil,
              "cast.reject-wrong-derived-specialization")
        check(first.echo("swift-only") == "swift-only"
                && text.echo(123) == 123,
              "method.swift-generic")

        let className = NSStringFromClass(type(of: first))
        let bridgedClassName = NSStringFromClass(type(of: object))
        let description = object.description
        check(!className.isEmpty && className == bridgedClassName
                && !description.isEmpty,
              "NSObject.class-name-and-description",
              "class=" + className + "; description=" + description)

        let array = [first, second]
        check(array.map { $0.value } == [42, 7], "collection.generic-array")
        let dictionary: [String: GenericSmokeBox<Int>] = ["answer": first]
        check(dictionary["answer"] === first, "collection.generic-dictionary")

        // Foundation collection bridging must retain the actual Swift objects,
        // not substitute stand-ins. Exercise both bridge-out and dynamic cast-in.
        let nsArray: NSArray = array as NSArray
        let arrayBack = nsArray as? [GenericSmokeBox<Int>]
        check(nsArray.count == 2 && arrayBack?.count == 2
                && arrayBack?[0] === first && arrayBack?[1] === second,
              "bridge.NSArray-generic-objects")
        let nsDictionary: NSDictionary = dictionary as NSDictionary
        let dictionaryBack = nsDictionary as? [String: GenericSmokeBox<Int>]
        check(nsDictionary.count == 1 && dictionaryBack?["answer"] === first,
              "bridge.NSDictionary-generic-objects")
        let swiftString = "iOS5-runtime"
        let nsString: NSString = swiftString as NSString
        check((nsString as String) == swiftString, "bridge.NSString")

        let target = GenericSmokeSelectorTarget()
        let selector = #selector(GenericSmokeSelectorTarget.smokeSelectorValue)
        let responds = target.responds(to: selector)
        check(responds, "objc.responds-to-selector")
        if responds {
            // perform returns an unretained (+0) result for this selector.
            let returned = target.perform(selector)?.takeUnretainedValue()
            check((returned as? NSString) == "selector-ok",
                  "objc.perform-selector")
        } else {
            check(false, "objc.perform-selector", "selector unavailable")
        }
    }

    let lifetimeCounts = GenericSmokeCounts()
    let weakReference = autoreleasepool {
        return genericSmokeMakeLifetimeProbe(lifetimeCounts)
    }
    check(weakReference.object == nil, "lifetime.weak-zeroed")
    check(lifetimeCounts.derivedDeinits == 1,
          "lifetime.derived-deinit", "count=\(lifetimeCounts.derivedDeinits)")
    check(lifetimeCounts.baseDeinits == 1,
          "lifetime.generic-base-deinit", "count=\(lifetimeCounts.baseDeinits)")
    check(lifetimeCounts.payloadDeinits == 1,
          "lifetime.generic-payload-release", "count=\(lifetimeCounts.payloadDeinits)")
    return results
}
