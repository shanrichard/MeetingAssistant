import Foundation
import MeetingCore

private final class PacketCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ packet: AudioPacket) {
        lock.lock(); defer { lock.unlock() }
        values.append(Int(packet.pcm.first ?? 0))
    }
    var packets: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}

private actor RoutingGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiting: Bool { !waiters.isEmpty }
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

func checkAudioRouting() async {
    let counts = PacketCounts()
    // Construct it on the UI actor, as production does. Its worker must not inherit that actor.
    let router = await MainActor.run {
        let router = AudioPacketRouter()
        router.setRoutes([.system: [{ packet in counts.append(packet) }]])
        return router
    }
    let producer = Task.detached {
        for index in 0..<100 {
            router.append(.init(source: .system, pcm: Data([UInt8(index), 0]), time: Double(index) / 1000))
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    await MainActor.run {
        // Deliberately emulate a long SwiftUI layout pass. Audio must advance during it.
        usleep(350_000)
        expect(counts.packets.count == 100)
    }
    await producer.value
    await router.finish()
    expect(counts.packets == Array(0..<100))
    expect(router.droppedBytes.isEmpty)

    let gate = RoutingGate(), before = PacketCounts(), after = PacketCounts()
    let changed = AudioPacketRouter()
    changed.setRoutes([.microphone: [{ packet in await gate.wait(); before.append(packet) }]])
    changed.append(.init(source: .microphone, pcm: Data([0, 0]), time: 0))
    while !(await gate.waiting) { await Task.yield() }
    changed.append(.init(source: .microphone, pcm: Data([1, 0]), time: 1))
    changed.setRoutes([.microphone: [{ packet in after.append(packet) }]])
    changed.append(.init(source: .microphone, pcm: Data([2, 0]), time: 2))
    await gate.release()
    await changed.finish()
    expect(before.packets == [0, 1])
    expect(after.packets == [2]) // Enabling a route never sends it earlier captured audio.

    var meter = AudioLevelThrottle()
    expect(meter.receive(0.1, at: 0) == 0.1)
    expect(meter.receive(0.8, at: 0.02) == nil)
    expect(meter.receive(0.2, at: 0.1) == 0.8)
    expect(meter.receive(0.3, at: 0.21) == 0.3)
    meter = AudioLevelThrottle()
    let updates = (0..<1000).compactMap { meter.receive(0.5, at: Double($0) / 1000) }
    expect(updates.count >= 9 && updates.count <= 11)
}
