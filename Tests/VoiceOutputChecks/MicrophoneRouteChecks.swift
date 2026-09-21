import Foundation
import CoreAudio
import MeetingCore

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MeetingError.message(message) }
}

@MainActor private final class RouteFixture {
    let physical = AudioDevice(id: 10, uid: "physical", name: "Headset", input: true, output: false, virtual: false)
    let virtual = AudioDevice(id: 20, uid: "virtual", name: "BlackHole", input: true, output: true, virtual: true)
    let other = AudioDevice(id: 30, uid: "other", name: "USB Mic", input: true, output: false, virtual: false)
    var devices: [AudioDevice] = []
    var current: AudioObjectID = 10
    var writes: [String] = []
    var rejectWrite = false
    var ignoreWrite = false
    var failAfterWrite = false
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RouteChecks-" + UUID().uuidString)
    var journal: URL { folder.appendingPathComponent("route.json") }
    init() throws {
        devices = [physical, virtual, other]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func makeRoute() -> MicrophoneRoute {
        MicrophoneRoute(journal: journal, listDevices: { [unowned self] in devices },
            defaultInput: { [unowned self] in current }, setDefaultInput: { [unowned self] device in
                if rejectWrite { throw MeetingError.message("write rejected") }
                writes.append(device.uid)
                if !ignoreWrite { current = device.id }
                if failAfterWrite { failAfterWrite = false; throw MeetingError.message("post-write failure") }
            })
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
}

@MainActor func microphoneRouteChecks() throws {
    do {
        let f = try RouteFixture(), route = f.makeRoute()
        try route.start(device: f.virtual); try route.validate()
        try check(f.current == f.virtual.id && route.active, "Enabling must switch the microphone")
        try check(FileManager.default.fileExists(atPath: f.journal.path), "Recovery must be durable before switching")
        var rejected = false
        do { try route.start(device: f.virtual) } catch { rejected = true }
        try check(rejected && f.writes == [f.virtual.uid], "Double start must not overwrite original input")
        try route.restore(); try route.restore()
        try check(f.current == f.physical.id && !route.active, "Stop restores original input exactly once")
        try check(f.writes == [f.virtual.uid, f.physical.uid], "Restore is idempotent")
        try check(!FileManager.default.fileExists(atPath: f.journal.path), "Successful restoration removes journal")
    }
    do {
        let f = try RouteFixture(), route = f.makeRoute()
        try route.start(device: f.virtual); f.current = f.other.id
        var detected = false
        do { try route.validate() } catch { detected = true }
        try check(detected, "Route drift must be detected")
        try route.restore()
        try check(f.current == f.other.id && f.writes.count == 1, "Respect a newer user selection")
    }
    do {
        let f = try RouteFixture()
        try f.makeRoute().start(device: f.virtual)
        // A new object reads only the persisted journal after a simulated crash.
        f.devices[0] = AudioDevice(id: 11, uid: f.physical.uid, name: "Headset", input: true, output: false, virtual: false)
        try f.makeRoute().restore()
        try check(f.current == 11, "Crash restoration resolves UID, not stale CoreAudio IDs")
    }
    do {
        let f = try RouteFixture(), route = f.makeRoute()
        f.current = f.virtual.id
        try route.start(device: f.virtual); try route.restore()
        try check(f.writes.isEmpty && f.current == f.virtual.id, "Preselected virtual input belongs to user")
    }
    for mode in ["reject", "ignore", "partial"] {
        let f = try RouteFixture(), route = f.makeRoute()
        f.rejectWrite = mode == "reject"; f.ignoreWrite = mode == "ignore"; f.failAfterWrite = mode == "partial"
        var failed = false
        do { try route.start(device: f.virtual) } catch { failed = true }
        try check(failed && !route.active && f.current == f.physical.id, "Failed switch rolls back: " + mode)
    }
    do {
        let f = try RouteFixture(), route = f.makeRoute()
        try route.start(device: f.virtual)
        f.devices.removeAll { $0.uid == f.physical.uid }
        var failed = false
        do { try route.restore() } catch { failed = true }
        try check(failed && f.current == f.virtual.id, "No guessed replacement for disconnected headset")
        try check(FileManager.default.fileExists(atPath: f.journal.path), "Failed restoration retains journal")
        f.devices.append(f.physical); try route.restore()
        try check(f.current == f.physical.id, "Retry restoration after microphone reconnects")
    }
    do {
        let f = try RouteFixture(), route = f.makeRoute()
        try route.start(device: f.virtual); f.rejectWrite = true
        var failed = false
        do { try route.restore() } catch { failed = true }
        try check(failed && FileManager.default.fileExists(atPath: f.journal.path), "HAL restoration error preserves recovery")
        f.rejectWrite = false; try f.makeRoute().restore()
        try check(f.current == f.physical.id, "Next launch retries failed HAL restoration")
    }
    do {
        let f = try RouteFixture(), route = f.makeRoute()
        f.devices = [f.physical, AudioDevice(id: 20, uid: "virtual", name: "Output only", input: false, output: true, virtual: true)]
        var failed = false
        do { try route.start(device: f.virtual) } catch { failed = true }
        try check(failed && f.writes.isEmpty, "Output-only devices cannot be meeting microphones")
    }
    do {
        let f = try RouteFixture()
        let route = MicrophoneRoute(journal: f.folder.appendingPathComponent("missing/route.json"),
            listDevices: { f.devices }, defaultInput: { f.current }, setDefaultInput: { f.writes.append($0.uid) })
        var failed = false
        do { try route.start(device: f.virtual) } catch { failed = true }
        try check(failed && f.writes.isEmpty, "No mutation when recovery cannot be saved")
    }
    print("PASS: automatic input switch, readback, rollback, user override, crash recovery, UID rebinding and restoration failures")
}

@MainActor func microphoneRouteHardwareCheck() async throws {
    let devices = try AudioDevices.list()
    guard let device = devices.first(where: { $0.uid == "BlackHole2ch_UID" && $0.input && $0.output }) else {
        throw MeetingError.message("BlackHole 2ch unavailable")
    }
    let originalInput = try AudioDevices.defaultInput()
    let system = AudioObjectID(kAudioObjectSystemObject)
    let originalOutput = try AudioDevices.value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
    let journal = FileManager.default.temporaryDirectory.appendingPathComponent("RouteHardware-" + UUID().uuidString + ".json")
    let route = MicrophoneRoute(journal: journal)
    let voice = VoiceOutput()
    var errors: [String] = []
    voice.onError = { errors.append($0) }
    do {
        try voice.start(device: device)
        try route.start(device: device); try route.validate()
        print("ACTIVE: system microphone switched to BlackHole 2ch; no recording or API calls")
        try await Task.sleep(for: .milliseconds(650))
        voice.enqueuePCM(Data(repeating: 0, count: 9_600))
        // Bounded window for observing the call application's device label.
        try await Task.sleep(for: .seconds(CommandLine.arguments.contains("--observe-lark") ? 45 : 2))
        try route.validate()
        try check(voice.running && voice.statistics.completedBytes >= 9_600 && errors.isEmpty,
            "Translated playback must survive automatic default-input switching")
        voice.stop(); try route.restore()
    } catch {
        voice.stop()
        do { try route.restore() } catch { print("RESTORATION FAILED: \(error.localizedDescription)") }
        throw error
    }
    let input = try AudioDevices.defaultInput()
    let output = try AudioDevices.value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
    try check(input == originalInput && output == originalOutput, "Original input/output must be restored")
    print("PASS: real BlackHole input switch, 9600 silent PCM bytes played, original input restored; speaker unchanged")
}
