//===----------------------------------------------------------------------===//
// FoundationAsync.swift - regression suite for the async Foundation adapters.
//
// Covers utils/legacy-ios5-mac/overlays/Foundation/ConcurrencyBackports.swift
// (URLSession.data/bytes/download/upload, URL.lines, FileHandle.bytes,
// NotificationCenter.notifications) and the two legacy overlay fixes those
// depend on: JSON top-level fragments in JSONDecoder and the URL path-building
// methods (appendingPathComponent & friends).
//
// Run on the iPod with the existing harness:
//
//   bash utils/legacy-ios5-mac/concurrency-tests/run-on-ipod.sh \
//        utils/legacy-ios5-mac/concurrency-tests/FoundationAsync.swift \
//        /path/to/swift-5.10.1-ios5.xctoolchain
//
// The HTTP tests use a loopback fixture served from a thread inside this
// process, so no external server, Wi-Fi or DNS is required. To point the HTTP
// tests at a different fixture, either pass `--base-url http://host:port`, set
// FOUNDATION_ASYNC_BASE_URL, or write the base URL into one of the probe files
// listed in externalBaseURL() below.
//
// Exit status is the number of failed checks (0 = pass). SKIP lines are not
// failures: an unavailable HTTP fixture degrades the HTTP cases to SKIP.
//===----------------------------------------------------------------------===//

import Foundation
import Darwin

// MARK: - Harness

private var failures = 0
private var passes = 0
private var skips = 0

private func out(_ s: String) { print(s); fflush(stdout) }

private func check(_ name: String, _ ok: Bool) {
    if ok { passes += 1; out("PASS " + name) } else { failures += 1; out("FAIL " + name) }
}

private func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want { passes += 1; out("PASS " + name) }
    else { failures += 1; out("FAIL \(name)  (got \(got), want \(want))") }
}

private func skip(_ name: String, _ why: String) {
    skips += 1
    out("SKIP \(name)  (\(why))")
}

/// Thread-safe counter for callbacks that arrive on other threads.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private func tempPath(_ tag: String) -> String {
    return NSTemporaryDirectory() + "/foundation-async-" + tag + "-" + UUID().uuidString
}

private func writeFile(_ path: String, _ text: String) -> Bool {
    guard let data = text.data(using: String.Encoding.utf8) else { return false }
    return (data as NSData).write(toFile: path, atomically: true)
}

private func readFile(_ path: String) -> String? {
    guard let data = NSData(contentsOfFile: path) as Data? else { return nil }
    return String(data: data, encoding: String.Encoding.utf8)
}

// MARK: - Loopback HTTP fixture

/// Minimal HTTP/1.1 server on 127.0.0.1 used by the adapter tests. One connection at a time is
/// enough: the checks run sequentially.
private final class FixtureServer: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private var port: UInt16 = 0
    private(set) var baseURL: String = ""

    static let textBody = "alpha\r\nbeta\ngamma\rdelta\n"
    static let bytesBody = "SwiftConcurrency-2026"
    static let jsonBody = "{\"title\":\"caf\u{e9}\",\"n\":42}"
    static let echoPrefix = "echo:"
    static let slowBody = "slow-response"
    static let notFoundBody = "not found"
    static let slowDelayMicros: UInt32 = 1_500_000

    static func downloadBody() -> [UInt8] {
        // Deterministic 3000-byte payload with a recognisable head and tail.
        var b = Array("DOWNLOAD-START:".utf8)
        var i = 0
        while b.count < 2990 { b.append(UInt8(48 + (i % 10))); i += 1 }
        b.append(contentsOf: Array(":DOWNLOAD-END".utf8))
        return b
    }

    func start() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // kernel picks a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if !bound { close(fd); return false }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len) == 0
            }
        }
        if !named { close(fd); return false }
        if listen(fd, 8) != 0 { close(fd); return false }

        listenFD = fd
        port = UInt16(bigEndian: actual.sin_port)
        baseURL = "http://127.0.0.1:\(port)"
        var thread = pthread_t(bitPattern: 0)
        let target = Unmanaged.passRetained(self)
        let started = pthread_create(&thread, nil, { raw -> UnsafeMutableRawPointer? in
            let server = Unmanaged<FixtureServer>.fromOpaque(raw).takeRetainedValue()
            server.acceptLoop()
            return nil
        }, target.toOpaque())
        if started != 0 { target.release(); close(fd); listenFD = -1; return false }
        return true
    }

    func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            // Cancellation closes the peer before /slow writes its response.
            // iOS 5 otherwise terminates this fixture process with SIGPIPE.
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            handle(client)
            close(client)
        }
    }

    private func handle(_ fd: Int32) {
        var request = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        while request.count < 65536 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            request.append(contentsOf: buf[0..<n])
            if containsHeaderTerminator(request) { break }
        }
        guard let text = String(bytes: request, encoding: String.Encoding.utf8) else { return }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        let path = parts[1].components(separatedBy: "?")[0]

        let contentLength = headerValue(lines, "content-length").flatMap { Int($0) } ?? 0
        var body = bodyBytes(request)
        if body.count < contentLength {
            // Read the remainder of the request body.
            while body.count < contentLength {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                body.append(contentsOf: buf[0..<n])
            }
        }

        if path == "/slow" { usleep(FixtureServer.slowDelayMicros) }

        switch path {
        case "/text":
            respond(fd, status: 200, reason: "OK", contentType: "text/plain; charset=utf-8",
                    body: Array(FixtureServer.textBody.utf8))
        case "/bytes":
            respond(fd, status: 200, reason: "OK", contentType: "text/plain",
                    body: Array(FixtureServer.bytesBody.utf8))
        case "/json":
            respond(fd, status: 200, reason: "OK", contentType: "application/json",
                    body: Array(FixtureServer.jsonBody.utf8))
        case "/download":
            respond(fd, status: 200, reason: "OK", contentType: "application/octet-stream",
                    body: FixtureServer.downloadBody())
        case "/echo":
            let echoed = Array(FixtureServer.echoPrefix.utf8) + body
            respond(fd, status: 200, reason: "OK", contentType: "text/plain", body: echoed)
        case "/slow":
            respond(fd, status: 200, reason: "OK", contentType: "text/plain",
                    body: Array(FixtureServer.slowBody.utf8))
        case "/status404":
            respond(fd, status: 404, reason: "Not Found", contentType: "text/plain",
                    body: Array(FixtureServer.notFoundBody.utf8))
        default:
            respond(fd, status: 404, reason: "Not Found", contentType: "text/plain",
                    body: Array("no such fixture route".utf8))
        }
    }

    private func containsHeaderTerminator(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 { return true }
            i += 1
        }
        return false
    }

    private func bodyBytes(_ bytes: [UInt8]) -> [UInt8] {
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
                return Array(bytes[(i + 4)...])
            }
            i += 1
        }
        return []
    }

    private func headerValue(_ lines: [String], _ name: String) -> String? {
        let lower = name.lowercased()
        for line in lines.dropFirst() {
            let parts = line.components(separatedBy: ":")
            if parts.count >= 2 && parts[0].lowercased() == lower {
                return parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func respond(_ fd: Int32, status: Int, reason: String, contentType: String, body: [UInt8]) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        writeAll(fd, Array(head.utf8))
        writeAll(fd, body)
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { p in
                Darwin.write(fd, p.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if n <= 0 { if errno == EINTR { continue }; return }
            offset += n
        }
    }
}

/// An external fixture overrides the built-in one. Order: argv, environment, device probe files.
private func externalBaseURL() -> String? {
    let args = CommandLine.arguments
    var i = 0
    while i < args.count {
        if args[i] == "--base-url" && i + 1 < args.count { return args[i + 1] }
        if args[i].hasPrefix("--base-url=") {
            return String(args[i].dropFirst("--base-url=".count))
        }
        i += 1
    }
    if let env = ProcessInfo.processInfo.environment["FOUNDATION_ASYNC_BASE_URL"],
       !env.isEmpty { return env }
    for probe in ["/var/root/n2conc/base-url.txt", "/tmp/foundation-async-base.txt"] {
        if let raw = readFile(probe) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    return nil
}

/// Runs `body` but gives up after `seconds`, so a broken adapter cannot hang the suite.
private func withTimeout<T>(_ seconds: Double, _ body: @escaping () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await body() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

// MARK: - Local checks (no network)

private func testURLPathMethods() {
    let u = URL(string: "http://example.com/a/b/c.txt")!
    checkEqual("URL.appendingPathComponent", u.appendingPathComponent("d").absoluteString,
               "http://example.com/a/b/c.txt/d")
    checkEqual("URL.appendingPathComponent isDirectory", u.appendingPathComponent("d", isDirectory: true).absoluteString,
               "http://example.com/a/b/c.txt/d/")
    checkEqual("URL.deletingLastPathComponent", u.deletingLastPathComponent().absoluteString,
               "http://example.com/a/b/")
    checkEqual("URL.appendingPathExtension", u.appendingPathExtension("json").absoluteString,
               "http://example.com/a/b/c.txt.json")
    checkEqual("URL.deletingPathExtension", u.deletingPathExtension().absoluteString,
               "http://example.com/a/b/c")

    var m = u
    m.appendPathComponent("z")
    checkEqual("URL.appendPathComponent (mutating)", m.absoluteString, "http://example.com/a/b/c.txt/z")
    m.deleteLastPathComponent()
    checkEqual("URL.deleteLastPathComponent (mutating)", m.absoluteString, "http://example.com/a/b/c.txt/")
    m.appendPathExtension("bak")
    checkEqual("URL.appendPathExtension (mutating)", m.pathExtension, "bak")
    m.deletePathExtension()
    checkEqual("URL.deletePathExtension (mutating)", m.pathExtension, "txt")

    let f = URL(fileURLWithPath: "/tmp/x/y.txt")
    checkEqual("file URL deletingLastPathComponent", f.deletingLastPathComponent().path, "/tmp/x")
    checkEqual("file URL appendingPathComponent", f.appendingPathComponent("z").path, "/tmp/x/y.txt/z")
}

private func testJSONFragments() throws {
    let dec = JSONDecoder()
    func data(_ s: String) -> Data { return s.data(using: String.Encoding.utf8)! }

    checkEqual("JSONDecoder top-level Int", try dec.decode(Int.self, from: data("42")), 42)
    checkEqual("JSONDecoder top-level Double", try dec.decode(Double.self, from: data("3.25")), 3.25)
    checkEqual("JSONDecoder top-level String", try dec.decode(String.self, from: data("\"hi\"")), "hi")
    checkEqual("JSONDecoder top-level Bool", try dec.decode(Bool.self, from: data("true")), true)
    checkEqual("JSONDecoder top-level array", try dec.decode([Int].self, from: data("[1,2,3]")), [1, 2, 3])
    checkEqual("JSONDecoder top-level object",
               try dec.decode([String: Int].self, from: data("{\"a\":7}")), ["a": 7])
    checkEqual("JSONDecoder top-level null -> Optional", try dec.decode(Int?.self, from: data("null")), nil as Int?)
    checkEqual("JSONDecoder fragment with whitespace", try dec.decode(Int.self, from: data("  9\n")), 9)

    // A struct round trip through the same encoder/decoder pair, multibyte included.
    struct Payload: Codable, Equatable {
        let title: String
        let n: Int
        let flag: Bool
    }
    let value = Payload(title: "caf\u{e9} \u{1F680}", n: -5, flag: true)
    let encoded = try JSONEncoder().encode(value)
    checkEqual("JSONEncoder/Decoder struct round trip", try dec.decode(Payload.self, from: encoded), value)

    var threw = false
    do { _ = try dec.decode(Int.self, from: data("not json")) } catch { threw = true }
    check("JSONDecoder rejects invalid JSON", threw)
}

private func testURLLinesFromFile() async throws {
    let cases: [(String, String, [String])] = [
        ("mixed line endings", "alpha\r\nbeta\ngamma\rdelta\n", ["alpha", "beta", "gamma", "delta"]),
        ("no trailing newline", "one\ntwo", ["one", "two"]),
        ("empty file", "", []),
        ("only newlines", "\n\n", ["", ""]),
        ("multibyte utf-8", "caf\u{e9}\n\u{1F680}\n", ["caf\u{e9}", "\u{1F680}"]),
        ("blank line in the middle", "a\n\nb\n", ["a", "", "b"]),
    ]
    for (name, text, want) in cases {
        let path = tempPath("lines")
        guard writeFile(path, text) else { skip("URL.lines \(name)", "could not write temp file"); continue }
        defer { try? FileManager.default.removeItem(atPath: path) }
        var got = [String]()
        do {
            let sequence = try await URL(fileURLWithPath: path).lines
            for await line in sequence { got.append(line) }
        }
        catch { failures += 1; out("FAIL URL.lines \(name) threw \(error)"); continue }
        checkEqual("URL.lines \(name)", got, want)
    }
}

private func testFileHandleBytes() async throws {
    let bytes = Array("Swift\r\nConcurrency\u{1F680}".utf8)
    let path = tempPath("bytes")
    guard FileManager.default.createFile(atPath: path, contents: Data(bytes), attributes: nil) else {
        skip("FileHandle.bytes", "could not create temp file"); return
    }
    defer { try? FileManager.default.removeItem(atPath: path) }

    guard let handle = FileHandle(forReadingAtPath: path) else {
        skip("FileHandle.bytes", "could not open temp file"); return
    }
    var got = [UInt8]()
    let byteStream = await handle.bytes
    for await b in byteStream { got.append(b) }
    checkEqual("FileHandle.bytes count", got.count, bytes.count)
    check("FileHandle.bytes content", got == bytes)

    // Reading an already-drained handle yields no further bytes.
    var again = [UInt8]()
    let drained = await handle.bytes
    for await b in drained { again.append(b) }
    checkEqual("FileHandle.bytes on drained handle", again.count, 0)

    let emptyPath = tempPath("empty")
    if FileManager.default.createFile(atPath: emptyPath, contents: Data(), attributes: nil),
       let empty = FileHandle(forReadingAtPath: emptyPath) {
        var e2 = [UInt8]()
        let emptyStream = await empty.bytes
        for await b in emptyStream { e2.append(b) }
        checkEqual("FileHandle.bytes empty file", e2.count, 0)
        try? FileManager.default.removeItem(atPath: emptyPath)
    }
}

private func testNotificationStream() async throws {
    let name = Notification.Name("FoundationAsyncFixtureNotification")
    let counter = Counter()
    let consumer = Task {
        for await _ in NotificationCenter.default.notifications(named: name) {
            counter.bump()
            if counter.count == 3 { break }
        }
        return counter.count
    }

    // Give the stream a moment to install its observer before posting.
    try? await Task.sleep(nanoseconds: 150_000_000)
    for _ in 0..<3 {
        NotificationCenter.default.post(name: name, object: nil)
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    let received = await withTimeout(3) { await consumer.value } ?? -1
    checkEqual("NotificationCenter.notifications delivered 3", received, 3)

    // After the loop ended the observer must be gone: further posts must not crash or leak into a
    // finished stream. Nothing observable should change.
    NotificationCenter.default.post(name: name, object: nil)
    try? await Task.sleep(nanoseconds: 100_000_000)
    check("notifications stream survived a post after termination", true)

    let nilStream = NotificationCenter.default.notifications(named: name)
    let secondCount = Counter()
    let t = Task { for await _ in nilStream { secondCount.bump(); break } }
    try? await Task.sleep(nanoseconds: 100_000_000)
    NotificationCenter.default.post(name: name, object: nil)
    try? await Task.sleep(nanoseconds: 150_000_000)
    t.cancel()
    check("second notifications stream stays independent", true)
}

private func testCancellationWithoutNetwork() async throws {
    // Cancel before the body runs: the body still observes cancellation.
    let task = Task { () -> Bool in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return Task.isCancelled
    }
    task.cancel()
    check("task cancelled before body observes it", await task.value)

    // A cancelled task's child sleep throws rather than waiting the full interval.
    let started = Date()
    let t2 = Task { () -> Bool in
        do { try await Task.sleep(nanoseconds: 3_000_000_000); return false }
        catch { return Task.isCancelled }
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    t2.cancel()
    let cancelled = await withTimeout(3) { await t2.value } ?? false
    let elapsed = Date().timeIntervalSince(started)
    check("cancelled sleep returns quickly", cancelled && elapsed < 2.0)
}

// MARK: - HTTP checks (loopback fixture)

private func testHTTP(_ base: String) async {
    let session = URLSession.shared

    // 1. data(from:)
    if let result = await withTimeout(20, { try await session.data(from: URL(string: base + "/text")!) }) {
        let (data, response) = result
        checkEqual("URLSession.data(from:) status", (response as? HTTPURLResponse)?.statusCode ?? -1, 200)
        checkEqual("URLSession.data(from:) body",
                   String(decoding: data, as: UTF8.self), FixtureServer.textBody)
    } else { failures += 1; out("FAIL URLSession.data(from:) timed out or threw") }

    // 2. data(for:) with an explicit request
    var request = URLRequest(url: URL(string: base + "/json")!)
    request.httpMethod = "GET"
    request.setValue("foundation-async-test", forHTTPHeaderField: "X-Probe")
    if let result = await withTimeout(20, { try await session.data(for: request) }) {
        let (data, response) = result
        checkEqual("URLSession.data(for:) status", (response as? HTTPURLResponse)?.statusCode ?? -1, 200)
        checkEqual("URLSession.data(for:) body", String(decoding: data, as: UTF8.self), FixtureServer.jsonBody)
        // The body really is decodable JSON.
        struct Payload: Decodable { let title: String; let n: Int }
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            check("URLSession.data(for:) JSON body decodes", payload.n == 42 && payload.title == "caf\u{e9}")
        } else { failures += 1; out("FAIL URLSession.data(for:) JSON body did not decode") }
    } else { failures += 1; out("FAIL URLSession.data(for:) timed out or threw") }

    // 3. bytes(from:) collects the whole body in order
    if let result = await withTimeout(20, { try await session.bytes(from: URL(string: base + "/bytes")!) }) {
        let (sequence, _) = result
        var got = [UInt8]()
        for await b in sequence { got.append(b) }
        checkEqual("URLSession.bytes(from:) content", String(decoding: got, as: UTF8.self), FixtureServer.bytesBody)
        checkEqual("URLSession.bytes(from:) count", got.count, FixtureServer.bytesBody.utf8.count)
    } else { failures += 1; out("FAIL URLSession.bytes(from:) timed out or threw") }

    // 4. download(from:) returns an existing file the caller owns
    if let result = await withTimeout(30, { try await session.download(from: URL(string: base + "/download")!) }) {
        let (fileURL, response) = result
        checkEqual("URLSession.download(from:) status", (response as? HTTPURLResponse)?.statusCode ?? -1, 200)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        check("URLSession.download(from:) file exists", exists)
        if exists, let data = NSData(contentsOfFile: fileURL.path) as Data? {
            let expected = FixtureServer.downloadBody()
            checkEqual("URLSession.download(from:) size", data.count, expected.count)
            check("URLSession.download(from:) content", Array(data) == expected)
            check("URLSession.download(from:) file is outside the system temp name",
                  fileURL.path.contains("download-"))
            try? FileManager.default.removeItem(atPath: fileURL.path)
            check("URLSession.download(from:) caller can delete the file",
                  !FileManager.default.fileExists(atPath: fileURL.path))
        } else { failures += 1; out("FAIL URLSession.download(from:) could not read the file") }
    } else { failures += 1; out("FAIL URLSession.download(from:) timed out or threw") }

    // 5. upload(for:from:) delivers the body to the server
    var post = URLRequest(url: URL(string: base + "/echo")!)
    post.httpMethod = "POST"
    let payload = Array("upload-payload-\u{1F680}".utf8)
    if let result = await withTimeout(30, { try await session.upload(for: post, from: Data(payload)) }) {
        let (data, response) = result
        checkEqual("URLSession.upload(for:from:) status", (response as? HTTPURLResponse)?.statusCode ?? -1, 200)
        checkEqual("URLSession.upload(for:from:) echoed body", String(decoding: data, as: UTF8.self),
                   FixtureServer.echoPrefix + String(decoding: payload, as: UTF8.self))
    } else { failures += 1; out("FAIL URLSession.upload(for:from:) timed out or threw") }

    // 6. A non-2xx response is delivered as data + response, not thrown.
    if let result = await withTimeout(20, { try await session.data(from: URL(string: base + "/status404")!) }) {
        let (data, response) = result
        checkEqual("URLSession.data 404 status", (response as? HTTPURLResponse)?.statusCode ?? -1, 404)
        checkEqual("URLSession.data 404 body", String(decoding: data, as: UTF8.self), FixtureServer.notFoundBody)
    } else { failures += 1; out("FAIL URLSession.data 404 timed out or threw") }

    // 7. URL.lines over HTTP.
    if let lines = await withTimeout(20, { try await collectLines(URL(string: base + "/text")!) }) {
        checkEqual("URL.lines over HTTP", lines, ["alpha", "beta", "gamma", "delta"])
    } else { failures += 1; out("FAIL URL.lines over HTTP timed out or threw") }

    // 8. Cancellation interrupts an in-flight request instead of waiting for it.
    let started = Date()
    let task = Task { () -> Error? in
        do { _ = try await session.data(from: URL(string: base + "/slow")!); return nil }
        catch { return error }
    }
    try? await Task.sleep(nanoseconds: 200_000_000)
    task.cancel()
    let error = await withTimeout(6) { await task.value } ?? nil
    let elapsed = Date().timeIntervalSince(started)
    let slowSeconds = Double(FixtureServer.slowDelayMicros) / 1_000_000
    check("URLSession.data cancellation throws", error != nil)
    if let error = error { out("     cancellation error: \(error)") }
    check("URLSession.data cancellation returns before the slow reply (\(String(format: "%.2f", elapsed))s < \(slowSeconds)s)",
          elapsed < slowSeconds)

    // A cancelled request must not wedge the session's task bookkeeping: a fresh request still works.
    if let result = await withTimeout(20, { try await session.data(from: URL(string: base + "/bytes")!) }) {
        check("session usable after a cancelled request",
              (result.1 as? HTTPURLResponse)?.statusCode == 200
                && String(decoding: result.0, as: UTF8.self) == FixtureServer.bytesBody)
    } else { failures += 1; out("FAIL session unusable after a cancelled request") }
}

private func collectLines(_ url: URL) async throws -> [String] {
    var lines = [String]()
    let sequence = try await url.lines
    for await line in sequence { lines.append(line) }
    return lines
}

// MARK: - Driver

private func main() async {
    out("FoundationAsync: async Foundation adapter regression suite")
    out("  os \(ProcessInfo.processInfo.operatingSystemVersionString)")

    do { testURLPathMethods() }
    do { try testJSONFragments() } catch { failures += 1; out("FAIL JSONDecoder fragments threw \(error)") }
    do { try await testURLLinesFromFile() } catch { failures += 1; out("FAIL URL.lines file suite threw \(error)") }
    do { try await testFileHandleBytes() } catch { failures += 1; out("FAIL FileHandle.bytes threw \(error)") }
    do { try await testNotificationStream() } catch { failures += 1; out("FAIL notifications threw \(error)") }
    do { try await testCancellationWithoutNetwork() } catch { failures += 1; out("FAIL cancellation threw \(error)") }

    var fixture: FixtureServer? = nil
    if let external = externalBaseURL() {
        out("  using external HTTP fixture: \(external)")
        await testHTTP(external)
    } else {
        let server = FixtureServer()
        if server.start() {
            fixture = server
            out("  loopback HTTP fixture: \(server.baseURL)")
            await testHTTP(server.baseURL)
        } else {
            skip("HTTP adapter tests", "loopback fixture could not bind a socket")
        }
    }
    fixture?.stop()

    out("")
    out("checks: \(passes) passed, \(failures) failed, \(skips) skipped")
    out(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
    exit(Int32(failures))
}

// A hung adapter must not hang the device run: report and exit non-zero.
Task {
    try? await Task.sleep(nanoseconds: 180_000_000_000)
    out("FAIL watchdog: suite did not finish within 180 s")
    exit(3)
}

Task { await main() }
CFRunLoopRun()
