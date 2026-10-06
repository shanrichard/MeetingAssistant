import Foundation
import CoreAudio
import AVFoundation
import MeetingCore

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MeetingError.message(message) }
}

@MainActor private final class FakePlayback: VoicePlayback {
    var onConfigurationChange: (() -> Void)?
    var isRunning = false
    var lastObservedDevice: VoicePlaybackDevice?
    var starts: [AudioDevice] = []
    var scheduled: [Data] = []
    var completions: [@MainActor () -> Void] = []
    var failStarts = false
    var failRoute = false
    var startHook: (() -> Void)?
    func start(device: AudioDevice) throws {
        starts.append(device)
        if failStarts { throw MeetingError.message("Simulated start failure") }
        isRunning = true
        startHook?()
    }
    func validateRoute(device: AudioDevice) throws {
        lastObservedDevice = failRoute
            ? VoicePlaybackDevice(id: 91, uid: "headphones", name: "Test headphones", alive: true)
            : VoicePlaybackDevice(id: device.id, uid: device.uid, name: device.name, alive: true)
        if failRoute { throw MeetingError.message("Simulated route mismatch") }
    }
    func schedule(_ pcm: Data, completion: @escaping @MainActor () -> Void) throws {
        try require(isRunning, "Must not schedule while the engine is stopped")
        scheduled.append(pcm); completions.append(completion)
    }
    func stop() { isRunning = false }
    func change() { isRunning = false; onConfigurationChange?() }
}

@MainActor private final class Fixture {
    let device = AudioDevice(id: 82, uid: "test-virtual", name: "Virtual", input: true, output: true, virtual: true)
    let playback = FakePlayback()
    var devices: [AudioDevice] = []
    var errors: [String] = []
    lazy var voice = VoiceOutput(makePlayback: { [unowned self] in playback }, listDevices: { [unowned self] in devices })
    init() {
        devices = [device]
        voice.onError = { [weak self] in self?.errors.append($0) }
    }
    func start() throws { try voice.start(device: device) }
}

@MainActor private func waitFor(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<150 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw MeetingError.message("Timed out: " + message)
}

@MainActor private func offlineChecks() async throws {
    do {
        let f = Fixture(); try f.start()
        f.voice.enqueuePCM(Data([1, 0]))
        let staleCompletion = f.playback.completions[0]
        // The delayed notification produced by selecting the virtual output.
        f.playback.change()
        f.voice.enqueuePCM(Data([2, 0]))
        f.playback.change(); f.playback.change()
        try require(f.voice.running && f.errors.isEmpty, "Startup reconfiguration must not terminate translation")
        try await waitFor("startup recovery") { f.playback.scheduled.count == 2 }
        try require(f.playback.starts.count == 2, "Coalesce a notification burst into one restart")
        try require(f.playback.scheduled == [Data([1, 0]), Data([2, 0])], "Do not replay interrupted audio; preserve new audio")
        // Old callbacks must not reduce the new generation's queue accounting.
        staleCompletion()
        f.voice.enqueuePCM(Data(repeating: 0, count: 479_998))
        try require(f.voice.running, "Exactly ten seconds of pending PCM should fit")
        f.voice.enqueuePCM(Data([0, 0]))
        try require(!f.voice.running && f.errors.count == 1, "Stale completion must not hide queue overflow")
    }
    do {
        let f = Fixture(); try f.start()
        // Audio arrives after HAL stopped, before the notification is delivered.
        f.playback.isRunning = false
        f.voice.enqueuePCM(Data([3, 0]))
        try await waitFor("audio before notification") { f.playback.scheduled.count == 1 }
        try require(f.errors.isEmpty && f.playback.starts.count == 2, "Recover the stopped engine before scheduling")
        f.voice.stop()
    }
    do {
        let f = Fixture(); try f.start()
        f.playback.change(); f.voice.enqueuePCM(Data([4, 0]))
        let staleNotification = f.playback.onConfigurationChange
        f.voice.stop()
        try f.start()
        staleNotification?()
        try await Task.sleep(for: .milliseconds(400))
        try require(f.playback.starts.count == 2 && f.playback.scheduled.isEmpty, "Stop cancels pending restart and discards pending audio")
        try require(f.voice.running && f.errors.isEmpty, "Old session notifications must not affect the new session")
        f.voice.stop()
    }
    do {
        let f = Fixture(); try f.start(); f.playback.change()
        try await waitFor("restart entered") { f.playback.starts.count == 2 }
        f.voice.stop() // Also cancel during the post-start stabilization wait.
        try await Task.sleep(for: .milliseconds(350))
        try require(!f.playback.isRunning && f.errors.isEmpty && f.playback.starts.count == 2, "No restart after stopping during stabilization")
    }
    do {
        let f = Fixture(); try f.start()
        f.devices = [AudioDevice(id: 99, uid: "other-virtual", name: "Other", input: true, output: true, virtual: true)]
        f.playback.change()
        try await waitFor("removed device") { !f.voice.running }
        try require(f.errors.count == 1 && f.playback.starts.count == 1, "Never fall back to another virtual or default output")
    }
    do {
        let f = Fixture(); try f.start()
        f.devices = [AudioDevice(id: 83, uid: f.device.uid, name: "Virtual", input: true, output: true, virtual: true)]
        f.playback.change(); f.voice.enqueuePCM(Data([5, 0]))
        try await waitFor("new object ID") { f.playback.scheduled.count == 1 }
        try require(f.playback.starts.last?.id == 83 && f.errors.isEmpty, "Resolve the same UID again after device reconfiguration")
        f.voice.stop()
    }
    for failure in ["start", "route", "churn"] {
        let f = Fixture(); try f.start()
        if failure == "start" { f.playback.failStarts = true }
        if failure == "route" { f.playback.failRoute = true }
        if failure == "churn" { f.playback.startHook = { [weak f] in f?.playback.change() } }
        f.playback.change(); f.voice.enqueuePCM(Data([6, 0]))
        try await waitFor("bounded " + failure) { !f.voice.running }
        try require(f.playback.starts.count == 4 && f.errors.count == 1, "Recovery must stop after three attempts: " + failure)
        try require(f.playback.scheduled.isEmpty && !f.playback.isRunning, "Do not play pending audio after failed recovery")
    }
    do {
        let f = Fixture(); f.playback.failStarts = true
        do { try f.start(); throw MeetingError.message("Expected startup failure") }
        catch { try require(!f.voice.running && f.playback.onConfigurationChange == nil, "Clean up a failed initial start") }
        f.playback.failStarts = false; try f.start()
        f.voice.enqueuePCM(Data([1]))
        try require(!f.voice.running && f.errors.count == 1, "Reject incomplete Int16 PCM")
    }
    do {
        let f = Fixture(); try f.start()
        // A route can change while the engine keeps running, before (or without)
        // an AVAudioEngineConfigurationChange notification reaching the owner.
        f.playback.failRoute = true
        f.playback.startHook = { [weak f] in f?.playback.failRoute = false }
        f.voice.enqueuePCM(Data([7, 0]))
        try require(f.playback.scheduled.isEmpty, "Never enqueue translated speech on a mismatched running output")
        try await waitFor("route rebound before audio") { f.playback.scheduled.count == 1 }
        try require(f.playback.starts.count == 2 && f.playback.starts.last?.uid == f.device.uid,
                    "Rebind only the selected virtual device before playing pending speech")
        try require(f.errors.isEmpty, "A recoverable output drift must not terminate translation")
        try require(f.voice.routeDiagnostics.lastObservedDevice?.uid == f.device.uid &&
                    f.voice.routeDiagnostics.lastMismatchedDevice?.uid == "headphones",
                    "Preserve both the verified current route and evidence of the rejected headphones route")
        f.voice.stop()
    }
    do {
        let f = Fixture(); try f.start()
        f.voice.enqueuePCM(Data([8, 0]))
        // No further audio or notifications: the watchdog must still stop queued
        // playback on a bad route and bound its attempts to recover that route.
        f.playback.failRoute = true
        try await waitFor("idle route drift") { !f.voice.running }
        try require(f.playback.starts.count == 4 && f.errors.count == 1 && !f.playback.isRunning,
                    "Stop after three unsuccessful rebindings even when no new PCM arrives")
        try require(f.playback.scheduled == [Data([8, 0])], "Never replay uncertain speech during route recovery")
        let diagnostics = f.voice.routeDiagnostics
        try require(!diagnostics.running && !diagnostics.recovering && diagnostics.lastCheckedAt != nil &&
                    diagnostics.selectedDevice?.uid == f.device.uid && diagnostics.lastMismatchedDevice?.uid == "headphones",
                    "Preserve actual route evidence after a fatal output failure")
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics)) as? [String: Any]
        try require((saved?["lastMismatchedDevice"] as? [String: Any])?["name"] as? String == "Test headphones",
                    "Persist the actual device name in shareable audio diagnostics")
    }
    do {
        let f = Fixture(); try f.start()
        f.voice.stop(); f.playback.failRoute = true
        try await Task.sleep(for: .milliseconds(350))
        try require(f.playback.starts.count == 1 && f.errors.isEmpty && !f.voice.running,
                    "Stopping must cancel the route watchdog as well as recovery")
    }
    print("PASS: startup notifications, coalescing, pending audio, stale callbacks, cancellation, UID binding, bounded failures, PCM limits, unnotified route drift and route diagnostics")
}

// Hardware checks send silence only to BlackHole. No microphone, API or Keychain access.
@MainActor private final class ObservedPlayback: VoicePlayback {
    let rawEngine = AVAudioEngine()
    let engine: EngineVoicePlayback
    var onConfigurationChange: (() -> Void)?
    var isRunning: Bool { engine.isRunning }
    var lastObservedDevice: VoicePlaybackDevice? { engine.lastObservedDevice }
    var completedBytes = 0
    var starts = 0
    var notifications = 0
    var forwardNotifications = true
    init() {
        engine = EngineVoicePlayback(engine: rawEngine)
        engine.onConfigurationChange = { [weak self] in
            guard let self else { return }
            self.notifications += 1
            if self.forwardNotifications { self.onConfigurationChange?() }
        }
    }
    func start(device: AudioDevice) throws { starts += 1; try engine.start(device: device) }
    func validateRoute(device: AudioDevice) throws { try engine.validateRoute(device: device) }
    func schedule(_ pcm: Data, completion: @escaping @MainActor () -> Void) throws {
        try engine.schedule(pcm) { [weak self] in self?.completedBytes += pcm.count; completion() }
    }
    func stop() { engine.stop() }
}

@MainActor private func hardwareChecks() async throws {
    guard let device = try AudioDevices.list().first(where: { $0.uid == "BlackHole2ch_UID" && $0.output && $0.virtual }) else {
        print("SKIP: BlackHole 2ch is not available"); exit(2)
    }
    let system = AudioObjectID(kAudioObjectSystemObject)
    let originalInput = try AudioDevices.defaultInput()
    let originalDefault = try AudioDevices.value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
    for attempt in 1...10 {
        let playback = ObservedPlayback()
        let voice = VoiceOutput(makePlayback: { playback })
        var errors: [String] = []
        voice.onError = { errors.append($0) }
        defer { voice.stop() }
        try voice.start(device: device)
        try await Task.sleep(for: .milliseconds(650))
        try require(voice.running && playback.isRunning && errors.isEmpty, "BlackHole startup must stay active")
        try playback.validateRoute(device: device)
        if attempt == 1 {
            let processDevices = try AudioDevices.processOutputDeviceIDs()
            print("ROUTE: interpreter=\(playback.lastObservedDevice?.id ?? 0) \(playback.lastObservedDevice?.uid ?? "unknown"); process_output_devices=\(processDevices)")
            try require(processDevices.contains(device.id), "CoreAudio must report BlackHole in this test process's actual output devices")
        }
        voice.enqueuePCM(Data(repeating: 0, count: 9_600))
        try await waitFor("silence played") { playback.completedBytes >= 9_600 }
        // Exercise runtime recovery without changing any shared device settings.
        playback.rawEngine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: playback.rawEngine)
        voice.enqueuePCM(Data(repeating: 0, count: 9_600))
        try await waitFor("silence after recovery") { playback.completedBytes >= 19_200 }
        try require(voice.running && playback.isRunning && errors.isEmpty, "Playback must resume on the same BlackHole")
        try playback.validateRoute(device: device)
        voice.stop()
        try require(!playback.isRunning, "Stop must stop the hardware engine")
        try require(playback.notifications >= 1, "The real notification observer must receive the injected configuration event")
        print("PASS: BlackHole cycle \(attempt), starts=\(playback.starts), notifications=\(playback.notifications) (1 injected), completed=\(playback.completedBytes) silent bytes")
    }
    if originalDefault != device.id {
        let playback = ObservedPlayback()
        let voice = VoiceOutput(makePlayback: { playback })
        var errors: [String] = []
        voice.onError = { errors.append($0) }
        defer { voice.stop() }
        try voice.start(device: device)
        try await Task.sleep(for: .milliseconds(650))
        playback.forwardNotifications = false
        // Change only this test engine's output; never the system route. No
        // non-silent audio is scheduled, even on a regressed implementation.
        playback.rawEngine.stop()
        guard let unit = playback.rawEngine.outputNode.audioUnit else {
            throw MeetingError.message("Missing hardware output unit")
        }
        var wrongDevice = originalDefault
        try AudioDevices.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &wrongDevice, UInt32(MemoryLayout<AudioObjectID>.size)), "Inject test output drift")
        var rejected = false
        do { try playback.engine.schedule(Data(repeating: 0, count: 9_600)) {} }
        catch { rejected = true }
        try require(rejected, "The native player must reject PCM after its actual output drifts")
        try await waitFor("native route drift recovery without notifications") {
            voice.routeDiagnostics.lastMismatchedDevice?.id == originalDefault &&
            voice.routeDiagnostics.lastObservedDevice?.uid == device.uid && !voice.routeDiagnostics.recovering
        }
        try require(voice.running && errors.isEmpty, "The watchdog must rebind the original BlackHole after native drift")
        voice.enqueuePCM(Data(repeating: 0, count: 9_600))
        try await waitFor("silence on rebound route") { playback.completedBytes >= 9_600 }
        print("PASS: native output drift rejected; recovered \(voice.routeDiagnostics.lastMismatchedDevice?.name ?? "unknown") -> \(voice.routeDiagnostics.lastObservedDevice?.name ?? "unknown"); only silent PCM used")
    }
    let finalDefault = try AudioDevices.value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
    try require(originalDefault == finalDefault, "The system default output must not change")
    let finalInput = try AudioDevices.defaultInput()
    try require(originalInput == finalInput, "The system default input must not change")
}

@main struct VoiceOutputChecks {
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.contains("--hardware-route") { try await microphoneRouteHardwareCheck() }
            else if CommandLine.arguments.contains("--hardware") { try await hardwareChecks() }
            else { try microphoneRouteChecks(); try await offlineChecks() }
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}
