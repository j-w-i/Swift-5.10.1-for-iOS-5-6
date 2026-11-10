import Foundation
func out(_ s: String) { print(s); fflush(stdout) }
Task {
    let t0 = ContinuousClock.now
    try? await Task.sleep(for: .milliseconds(50))
    let d = ContinuousClock.now - t0
    out("sleep(for:) ok, elapsed >= 40ms: \(d >= .milliseconds(40))")
    let s = SuspendingClock.now
    try? await Task.sleep(until: s.advanced(by: .milliseconds(30)), clock: .suspending)
    out("sleep(until:) ok")
    let dur: Duration = .seconds(2) + .milliseconds(500)
    out("Duration math: \(dur.components.seconds)s")
    exit(0)
}
CFRunLoopRun()
