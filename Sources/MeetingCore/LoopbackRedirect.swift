import Foundation
import Network

/// Receives the browser's OAuth redirect on 127.0.0.1 at a random port, as Google requires for desktop clients.
public final class LoopbackRedirectReceiver: @unchecked Sendable {
    public let redirectURI: URL
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private let state: String

    private init(listener: NWListener, queue: DispatchQueue, port: UInt16, state: String) {
        self.listener = listener; self.queue = queue; self.state = state
        redirectURI = URL(string: "http://127.0.0.1:\(port)/")!
    }

    /// Only a redirect carrying `state` can complete the flow.
    public static func start(state: String) async throws -> LoopbackRedirectReceiver {
        let parameters = NWParameters.tcp
        // Bind to loopback only so nothing else on the network can deliver a code.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "com.meetingassistant.oauth-redirect")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let pending = PendingContinuation(continuation)
            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready:
                    if let port = listener.port?.rawValue { pending.resume(.success(port)) }
                    else { pending.resume(.failure(GoogleError.invalidResponse)) }
                case .failed(let error): pending.resume(.failure(error))
                case .cancelled: pending.resume(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
        let receiver = LoopbackRedirectReceiver(listener: listener, queue: queue, port: port, state: state)
        listener.newConnectionHandler = { [weak receiver] connection in receiver?.accept(connection) }
        return receiver
    }

    /// Waits for the redirect, returning the authorization code.
    public func code(timeout: TimeInterval = 300) async throws -> String {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(GoogleError.timedOut)) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result); return }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: { [weak self] in self?.finish(.failure(CancellationError())) }
    }

    public func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ outcome: Result<String, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let continuation = continuation; self.continuation = nil
        lock.unlock()
        listener.cancel()
        continuation?.resume(with: outcome)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), connection: connection)
            } else if complete || error != nil || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, connection: NWConnection) {
        let target = head.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard let components = URLComponents(string: "http://127.0.0.1" + target), components.path == "/" else {
            respond(connection, status: "404 Not Found", message: "")
            return
        }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        let outcome: Result<String, Error>
        if let error = items["error"] { outcome = .failure(GoogleError.denied(error)) }
        else if state.isEmpty || items["state"] != state { outcome = .failure(GoogleError.stateMismatch) }
        else if let code = items["code"], !code.isEmpty { outcome = .success(code) }
        else { outcome = .failure(GoogleError.invalidResponse) }
        let message: String
        switch outcome {
        case .success: message = "已完成 Google 授权，可以关闭这个页面并回到 Meeting Assistant。"
        case .failure(let error): message = "授权未完成：\(error.localizedDescription) 请回到 Meeting Assistant 重试。"
        }
        respond(connection, status: "200 OK", message: message) { [weak self] in self?.finish(outcome) }
    }

    private func respond(_ connection: NWConnection, status: String, message: String, then: (() -> Void)? = nil) {
        let escaped = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let body = "<!doctype html><meta charset=\"utf-8\"><title>Meeting Assistant</title>"
            + "<body style=\"font:16px -apple-system,sans-serif;padding:48px;max-width:560px\"><p>\(escaped)</p></body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(Data(body.utf8).count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            then?()
        })
    }
}

/// Resumes a continuation at most once from callbacks that may repeat.
private final class PendingContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func resume(_ result: Result<Value, Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}
