import Foundation
import AVFoundation
import MeetingCore

// Separate, locally run diagnostic executable. No API calls or Keychain access.
// Audio exists only in a temporary directory and is removed after each run.
@main struct CaptureChecks {
    @MainActor static func main() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("SKIP: microphone permission is not already granted to this signed diagnostic.")
            exit(2)
        }
        do {
            let devices = try AudioDevices.list().filter {
                $0.input && !$0.virtual && ($0.name.localizedCaseInsensitiveContains("AirPods") || $0.name.contains("MacBook"))
            }
            guard !devices.isEmpty else { throw MeetingError.message("No physical test microphone connected") }
            var failures = 0
            for device in devices {
                for attempt in 1...2 {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingCaptureChecks-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: folder) }
                    let capture = AudioCapture()
                    let lock = NSLock()
                    var bytes: [AudioSource: Int] = [:]
                    var firstPacket: [AudioSource: Double] = [:]
                    var errors: [String] = []
                    capture.onPacket = { packet in
                        lock.lock()
                        bytes[packet.source, default: 0] += packet.pcm.count
                        if firstPacket[packet.source] == nil { firstPacket[packet.source] = packet.time }
                        lock.unlock()
                    }
                    capture.onFailure = { message in lock.lock(); errors.append(message); lock.unlock() }
                    do {
                        try await capture.start(folder: folder, microphone: device)
                        try await Task.sleep(for: .seconds(8))
                        _ = capture.stop()
                        let result = lock.withLock { (bytes, errors) }
                        let micFrames = (result.0[.microphone] ?? 0) / 2
                        let systemFrames = (result.0[.system] ?? 0) / 2
                        let passed = micFrames > 24000 && systemFrames > 24000 && result.1.isEmpty
                        print("\(passed ? "PASS" : "FAIL"): \(device.name), attempt \(attempt), mic=\(micFrames) frames, system=\(systemFrames) frames, errors=\(result.1.count)")
                        if let firstMic = lock.withLock({ firstPacket[.microphone] }) { print("First microphone packet: \(String(format: "%.2f", firstMic)) s") }
                        for error in result.1 { print("Audio error: \(error)") }
                        if !passed { failures += 1 }
                    } catch {
                        _ = capture.stop(); failures += 1
                        print("FAIL: \(device.name), attempt \(attempt): \(error.localizedDescription)")
                        if let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] { print("Audio diagnostic: \(reason)") }
                    }
                }
            }
            exit(failures == 0 ? 0 : 1)
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
}
