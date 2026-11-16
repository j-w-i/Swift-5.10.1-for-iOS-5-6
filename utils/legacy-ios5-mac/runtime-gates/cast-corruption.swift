// Gate: bridged-collection casts must not corrupt memory on any OS the runtime serves.
// Regression for: NSArray -> [[String: Any]] heap corruption when the runtime's "is Swift" class
// bit disagreed with the host objc runtime (iOS 27 vs iOS <= 12.1).
import Foundation
let json = "{\"g\":[[{\"a\":\"1\"}],[{\"a\":\"2\"}]],\"d\":{\"a\":\"1\"},\"s\":[\"x\",\"y\"],\"n\":[1,2,3]}"
let obj = try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!, options: []) as! [String: Any]
let g = obj["g"] as! [Any]
let one: Any = g[0]
let q = DispatchQueue(label: "gate")
let group = DispatchGroup()
for _ in 0..<8 {
  group.enter()
  DispatchQueue.global(priority: DispatchQueue.GlobalQueuePriority.default).async {
    for _ in 0..<2000 {
      autoreleasepool {
        precondition((one as? [[String: Any]])?.count == 1)
        precondition((one as! [[String: Any]]).count == 1)
        precondition((obj["s"] as? [String])?.count == 2)
        precondition((obj["n"] as? [Int])?.count == 3)
        precondition((obj["d"] as? [String: String])?["a"] == "1")
        let ns = NSArray(object: NSDictionary(object: "1", forKey: "a" as NSString))
        precondition(((ns as Any) as? [[String: Any]])?.count == 1)
        var bag: [Any] = []; for i in 0..<20 { bag.append(["k\(i)": [i, "v"]] as [String: Any]) }
        precondition((bag as? [[String: Any]])?.count == 20)
      }
    }
    group.leave()
  }
}
group.wait()
print("GATE cast-corruption OK")
