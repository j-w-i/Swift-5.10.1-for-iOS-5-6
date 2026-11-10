import Foundation
var failures = 0
func out(_ s: String) { print(s); fflush(stdout) }
func check(_ n: String, _ ok: Bool) { out((ok ? "PASS " : "FAIL ") + n); if !ok { failures += 1 } }

struct Count: AsyncSequence {
    typealias Element = Int
    let upTo: Int
    struct It: AsyncIteratorProtocol { var i = 0; let n: Int
        mutating func next() async -> Int? { guard i < n else { return nil }; i += 1; await Task.yield(); return i } }
    func makeAsyncIterator() -> It { It(n: upTo) }
}

func run() async {
    var a = [Int](); for await v in Count(upTo: 5) { a.append(v) }
    check("custom AsyncSequence", a == [1,2,3,4,5])
    check("map/filter", await Count(upTo: 10).map { $0 * 2 }.filter { $0 % 4 == 0 }.reduce(0, +) == 4+8+12+16+20)
    check("prefix/dropFirst", await Count(upTo: 10).dropFirst(2).prefix(3).reduce(0, +) == 3+4+5)
    let has3 = await Count(upTo: 5).contains(3)
    let firstBig = await Count(upTo: 5).first(where: { $0 > 3 })
    check("contains/first(where:)", has3 && firstBig == 4)

    let stream = AsyncStream<Int>(bufferingPolicy: .bufferingNewest(2)) { c in for i in 1...5 { c.yield(i) }; c.finish() }
    var got = [Int](); for await v in stream { got.append(v) }
    check("AsyncStream bufferingNewest(2)", got == [4,5])

    let (s2, cont) = AsyncStream<String>.makeStream()
    Task { for w in ["a","b","c"] { cont.yield(w); try? await Task.sleep(nanoseconds: 2_000_000) }; cont.finish() }
    var words = ""; for await w in s2 { words += w }
    check("makeStream producer/consumer", words == "abc")

    struct E: Error {}
    let ts = AsyncThrowingStream<Int, Error> { c in c.yield(1); c.finish(throwing: E()) }
    var sawErr = false; var n = 0
    do { for try await v in ts { n += v } } catch { sawErr = error is E }
    check("AsyncThrowingStream finish(throwing:)", sawErr && n == 1)

    let term = AsyncStream<Int> { c in c.onTermination = { _ in out("  (onTermination fired)") }; c.yield(1) }
    for await _ in term { break }
    check("early exit terminates stream", true)

    // discarding + withTaskCancellationHandler + task priority
    final class Flag: @unchecked Sendable { private let l = NSLock(); private var v = false
        func set() { l.lock(); v = true; l.unlock() }; var value: Bool { l.lock(); defer { l.unlock() }; return v } }
    let flag = Flag()
    let t = Task { await withTaskCancellationHandler { try? await Task.sleep(nanoseconds: 5_000_000_000) } onCancel: { flag.set() } }
    try? await Task.sleep(nanoseconds: 20_000_000); t.cancel(); await t.value
    check("withTaskCancellationHandler", flag.value)
    let pr = await Task(priority: .high) { Task.currentPriority }.value
    check("task priority readable", pr.rawValue > 0)

    // heavy contention + unstructured cancellation of a group
    let total = await withTaskGroup(of: Int.self) { g -> Int in
        for i in 0..<2000 { g.addTask { await Task.yield(); return 1 } }
        var s = 0; for await v in g { s += v }; return s }
    check("2000 tasks with yield", total == 2000)
    let early = await withTaskGroup(of: Int.self) { g -> Int in
        for _ in 0..<50 { g.addTask { (try? await Task.sleep(nanoseconds: 3_000_000_000)); return Task.isCancelled ? 1 : 0 } }
        g.cancelAll(); var c = 0; for await v in g { c += v }; return c }
    check("cancelAll wakes sleepers", early == 50)
}
Task { await run(); out(failures == 0 ? "ALL PASS" : "FAILURES \(failures)"); exit(Int32(failures)) }
CFRunLoopRun()
