import Foundation

var failures = 0
func out(_ s: String) { print(s); fflush(stdout) }
func check(_ name: String, _ ok: Bool) { out((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }

actor Counter { var n = 0; func inc() -> Int { n += 1; return n } }
@MainActor final class UI { var title = "x"; func set(_ s: String) { title = s } }
struct Box: Sendable { let v: Int }
enum Oops: Error { case bad }

func fetch(_ i: Int) async throws -> Int { try await Task.sleep(nanoseconds: 5_000_000); return i }
func boom() async throws -> Int { throw Oops.bad }

func runAll() async {
    // 1 actor isolation under contention
    let c = Counter()
    await withTaskGroup(of: Void.self) { g in for _ in 0..<200 { g.addTask { _ = await c.inc() } } }
    check("actor 200 increments", await c.inc() == 201)

    // 2 throwing task group
    let sum = (try? await withThrowingTaskGroup(of: Int.self) { g -> Int in
        for i in 1...8 { g.addTask { try await fetch(i) } }
        var t = 0; for try await v in g { t += v }; return t }) ?? -1
    check("throwing group sum", sum == 36)

    // 3 async let
    async let a = fetch(10); async let b = fetch(20)
    let ab = try? await (a, b)
    check("async let", ab?.0 == 10 && ab?.1 == 20)

    // 4 checked continuation resumed from a GCD queue
    let cv: Int = await withCheckedContinuation { cont in DispatchQueue.global().async { cont.resume(returning: 7) } }
    check("checked continuation", cv == 7)
    let tv: Int? = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in DispatchQueue.global().async { cont.resume(throwing: Oops.bad) } }
    check("throwing continuation propagates", tv == nil)

    // 5 AsyncStream
    let stream = AsyncStream<Int> { cc in for i in 0..<5 { cc.yield(i) }; cc.finish() }
    var got = [Int](); for await x in stream { got.append(x) }
    check("AsyncStream", got == [0,1,2,3,4])

    // 6 error propagation
    do { _ = try await boom(); check("error propagation", false) } catch { check("error propagation", error is Oops) }

    // 7 cancellation
    let t = Task { () -> Bool in
        do { try await Task.sleep(nanoseconds: 5_000_000_000); return false } catch { return Task.isCancelled }
    }
    try? await Task.sleep(nanoseconds: 20_000_000); t.cancel()
    check("cancellation wakes sleep", await t.value)

    // 8 @MainActor hop
    let ui = await MainActor.run { UI() }
    await MainActor.run { ui.set("hopped") }
    check("MainActor.run", await ui.title == "hopped")
    let onMain: Bool = await MainActor.run { Thread.isMainThread }
    check("MainActor runs on main thread", onMain)

    // 9 detached + value + priority
    let d = await Task.detached(priority: .background) { Box(v: 99) }.value
    check("detached task value", d.v == 99)

    // 10 task local
    enum K { @TaskLocal static var id = 0 }
    let tl = await K.$id.withValue(5, operation: { await Task { K.id }.value })
    check("task-local inherited", tl == 5)

    // 11 sleep timing
    let t0 = Date(); try? await Task.sleep(nanoseconds: 100_000_000)
    let dt = Date().timeIntervalSince(t0)
    check("sleep ~100ms (\(Int(dt*1000))ms)", dt > 0.09 && dt < 0.6)

    // 12 many tasks
    var total = 0
    await withTaskGroup(of: Int.self) { g in for i in 0..<500 { g.addTask { i } }; for await v in g { total += v } }
    check("500 tasks", total == 124750)
}

Task { await runAll(); out(failures == 0 ? "ALL PASS" : "FAILURES \(failures)"); exit(Int32(failures)) }
CFRunLoopRun()
