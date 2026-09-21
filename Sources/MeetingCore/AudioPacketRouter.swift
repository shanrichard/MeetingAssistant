import Foundation

/// The capture callback and network actors must keep running while the UI is busy.
/// Each packet retains the destinations that were active when it was captured.
public final class AudioPacketRouter: @unchecked Sendable {
    public typealias Sink = @Sendable (AudioPacket) async -> Void
    private struct Delivery: Sendable {
        let packet: AudioPacket
        let sinks: [Sink]
    }
    private let lock = NSLock()
    private var routes: [AudioSource: [Sink]] = [:]
    private var dropped: [AudioSource: Int] = [:]
    private let continuation: AsyncStream<Delivery>.Continuation
    private let worker: Task<Void, Never>

    public init() {
        let (stream, continuation) = AsyncStream<Delivery>.makeStream(bufferingPolicy: .bufferingNewest(200))
        self.continuation = continuation
        worker = Task.detached(priority: .userInitiated) {
            for await delivery in stream {
                for sink in delivery.sinks { await sink(delivery.packet) }
            }
        }
    }
    public func setRoutes(_ value: [AudioSource: [Sink]]) {
        lock.lock(); defer { lock.unlock() }
        routes = value
    }
    public func append(_ packet: AudioPacket) {
        lock.lock(); defer { lock.unlock() }
        guard let sinks = routes[packet.source], !sinks.isEmpty else { return }
        if case .dropped(let delivery) = continuation.yield(Delivery(packet: packet, sinks: sinks)) {
            dropped[delivery.packet.source, default: 0] += delivery.packet.pcm.count
        }
    }
    public var droppedBytes: [AudioSource: Int] {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }
    public func finish() async {
        continuation.finish()
        await worker.value
    }
    deinit { continuation.finish(); worker.cancel() }
}

/// Report the peak once per interval, instead of invalidating a view per PCM buffer.
public struct AudioLevelThrottle {
    private var lastTime = -Double.infinity
    private var peak = 0.0
    private let interval: Double
    public init(interval: Double = 0.1) { self.interval = interval }
    public mutating func receive(_ value: Double, at time: Double) -> Double? {
        peak = max(peak, min(1, max(0, value)))
        guard time - lastTime >= interval else { return nil }
        lastTime = time
        defer { peak = 0 }
        return peak
    }
}
