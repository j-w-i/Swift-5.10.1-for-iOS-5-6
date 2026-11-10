//===----------------------------------------------------------------------===//
// Async/await adapters for Foundation API that stock Foundation only exposes with callbacks on the
// legacy iOS 5 runtime.  Every adapter wraps an API that already exists at the deployment floor
// (dataTask/uploadTask/downloadTask completion handlers, NotificationCenter, FileHandle, NSURLConnection
// streams) in a checked continuation or an AsyncStream, and propagates cancellation.
//
// These additions belong to the embedded Foundation overlay on every supported OS.
// They use its existing URLSession transport facade (legacy or native at runtime),
// rather than depending on the system Swift Foundation overlay's async methods.
//===----------------------------------------------------------------------===//

import CoreFoundation
import Dispatch

// MARK: - Cancellation plumbing

/// Holds a started task so `withTaskCancellationHandler` can cancel it from any thread, even if the
/// cancellation arrives before the task exists.
private final class _TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ t: URLSessionTask) {
        lock.lock(); task = t; let c = cancelled; lock.unlock()
        if c { t.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let t = task; lock.unlock()
        t?.cancel()
    }
}

// MARK: - URLSession

extension URLSession {

    /// Retrieves the contents of a URL (async/await form of `dataTask(with:completionHandler:)`).
    public func data(from url: URL) async throws -> (Data, URLResponse) {
        return try await data(for: URLRequest(url: url))
    }

    /// Retrieves the contents of a request.
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let box = _TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = self.dataTask(with: request) { data, response, error in
                    if let error = error { cont.resume(throwing: error) }
                    else if let data = data, let response = response { cont.resume(returning: (data, response)) }
                    else { cont.resume(throwing: URLError(.badServerResponse)) }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: { box.cancel() }
    }

    /// Uploads data and returns the server's response body.
    public func upload(for request: URLRequest, from bodyData: Data) async throws -> (Data, URLResponse) {
        let box = _TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = self.uploadTask(with: request, from: bodyData) { data, response, error in
                    if let error = error { cont.resume(throwing: error) }
                    else if let response = response { cont.resume(returning: (data ?? Data(), response)) }
                    else { cont.resume(throwing: URLError(.badServerResponse)) }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: { box.cancel() }
    }

    /// Downloads a request to a temporary file. The file is moved to a path the caller owns before
    /// the completion handler returns (the system deletes the original).
    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let box = _TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, URLResponse), Error>) in
                let task = self.downloadTask(with: request) { location, response, error in
                    if let error = error { cont.resume(throwing: error); return }
                    guard let location = location, let response = response else {
                        cont.resume(throwing: URLError(.badServerResponse)); return
                    }
                    let dest = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("download-" + UUID().uuidString)
                    do { try FileManager.default.moveItem(at: location, to: dest); cont.resume(returning: (dest, response)) }
                    catch { cont.resume(throwing: error) }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: { box.cancel() }
    }

    public func download(from url: URL) async throws -> (URL, URLResponse) {
        return try await download(for: URLRequest(url: url))
    }
}

// MARK: - Incremental bytes / lines

/// `URLSession.bytes` / `URL.lines` are implemented on top of a buffered download here: the transport on
/// the oldest systems only reports completion, so these deliver the complete body as a sequence rather
/// than streaming it incrementally (documented limitation).
public struct _LegacyAsyncBytes: AsyncSequence, Sendable {
    public typealias Element = UInt8
    let data: Data
    public struct AsyncIterator: AsyncIteratorProtocol {
        var index: Data.Index
        let data: Data
        public mutating func next() async -> UInt8? {
            guard index < data.endIndex else { return nil }
            defer { index = data.index(after: index) }
            return data[index]
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(index: data.startIndex, data: data) }
}

extension URLSession {
    public func bytes(from url: URL) async throws -> (_LegacyAsyncBytes, URLResponse) {
        let (d, r) = try await data(from: url); return (_LegacyAsyncBytes(data: d), r)
    }
    public func bytes(for request: URLRequest) async throws -> (_LegacyAsyncBytes, URLResponse) {
        let (d, r) = try await data(for: request); return (_LegacyAsyncBytes(data: d), r)
    }
}

public struct _LegacyAsyncLines: AsyncSequence, Sendable {
    public typealias Element = String
    let lines: [String]
    public struct AsyncIterator: AsyncIteratorProtocol {
        var i = 0
        let lines: [String]
        public mutating func next() async -> String? {
            guard i < lines.count else { return nil }
            defer { i += 1 }
            return lines[i]
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(lines: lines) }
    init(_ text: String) {
        var out = [String](); var cur = ""
        var prevCR = false
        for ch in text.unicodeScalars {
            if ch == "\n" { if !prevCR { out.append(cur); cur = "" }; prevCR = false }
            else if ch == "\r" { out.append(cur); cur = ""; prevCR = true }
            else { cur.unicodeScalars.append(ch); prevCR = false }
        }
        if !cur.isEmpty { out.append(cur) }
        lines = out
    }
}

extension URL {
    /// Lines of the resource at this URL (file or network), without line terminators.
    public var lines: _LegacyAsyncLines {
        get async throws {
            let data: Data
            if isFileURL { data = try Data(contentsOf: self) }
            else { data = try await URLSession.shared.data(from: self).0 }
            return _LegacyAsyncLines(String(decoding: data, as: UTF8.self))
        }
    }
}

extension FileHandle {
    /// Buffered remaining bytes of the handle, read off the calling thread.
    /// Unlike the native lazy sequence, this reads until EOF before returning.
    /// Cancellation does not interrupt that read: use only finite regular files,
    /// not pipes/sockets or sources which may never reach EOF.
    public var bytes: _LegacyAsyncBytes {
        get async {
            let data: Data = await withCheckedContinuation { cont in
                DispatchQueue.global().async { cont.resume(returning: self.readDataToEndOfFile()) }
            }
            return _LegacyAsyncBytes(data: data)
        }
    }
}

// MARK: - NotificationCenter

extension NotificationCenter {
    /// Notifications posted for `name`, as an unbounded async sequence. The observer
    /// is removed when the stream terminates (including cancellation while awaiting
    /// its next value). A bare `break` does not guarantee immediate observer removal.
    public func notifications(named name: Notification.Name, object: AnyObject? = nil) -> AsyncStream<Notification> {
        // Notification is not Sendable in stock Foundation either; the stream hands each value to
        // exactly one consumer, matching the SDK behaviour.
        return AsyncStream<Notification> { continuation in
            nonisolated(unsafe) let center = self
            let token = center.addObserver(forName: name, object: object, queue: nil) { note in
                continuation.yield(note)
            }
            nonisolated(unsafe) let boxedToken = token
            continuation.onTermination = { _ in center.removeObserver(boxedToken) }
        }
    }
}
