import Foundation
import CoreAudio
import MeetingCore

private let blackHole = AudioDevice(id: 82, uid: "BlackHole2ch_UID", name: "BlackHole 2ch", input: true, output: true, virtual: true)
private let otherVirtual = AudioDevice(id: 83, uid: "other", name: "Existing virtual microphone", input: true, output: true, virtual: true)
private let microphone = AudioDevice(id: 84, uid: "physical", name: "Physical microphone", input: true, output: false, virtual: false)

@MainActor private final class Fixture {
    let suite = "MeetingBlackHoleChecks." + UUID().uuidString
    let defaults: UserDefaults
    var devices: [AudioDevice] = []
    var currentUID = ""
    var diskInstalled = false
    var busy = false
    var enumerationFails = false
    var downloadFails = false
    var verificationFails = false
    var openerFails = false
    var downloads = 0, verifications = 0, opens = 0
    var downloadGate: CheckedContinuation<Void, Never>?
    var suspendDownload = false
    var verificationGate: CheckedContinuation<Void, Never>?
    var suspendVerification = false
    lazy var setup: BlackHoleSetup = makeSetup()
    init() { defaults = UserDefaults(suiteName: suite)! }
    func makeSetup() -> BlackHoleSetup {
        let setup = BlackHoleSetup(defaults: defaults, listDevices: { [unowned self] in
            if enumerationFails { throw MeetingError.message("Synthetic device failure") }; return devices
        }, installedOnDisk: { [unowned self] in diskInstalled }, download: { [unowned self] in
            downloads += 1
            if suspendDownload { await withCheckedContinuation { downloadGate = $0 } }
            if downloadFails { throw URLError(.notConnectedToInternet) }
            return URL(fileURLWithPath: "/tmp/fake-blackhole.pkg")
        }, verify: { [unowned self] _ in
            verifications += 1
            if suspendVerification { await withCheckedContinuation { verificationGate = $0 } }
            if verificationFails { throw MeetingError.message("Synthetic signature mismatch") }
        }, openInstaller: { [unowned self] _ in
            if openerFails { throw MeetingError.message("Synthetic Installer launch failure") }
            opens += 1
        })
        setup.configureDevices = { [unowned self] devices in
            let selected = AudioDevices.preferredTranslationOutput(in: devices, currentUID: currentUID)
            if let selected { currentUID = selected.uid }; return selected
        }
        setup.meetingIsBusy = { [unowned self] in busy }
        return setup
    }
    func clean() { setup.cancelDownload(); defaults.removePersistentDomain(forName: suite) }
}

@main struct BlackHoleSetupChecks {
    @MainActor static func main() async {
        do {
            try await offline()
            if CommandLine.arguments.contains("--download") {
                let file = try await BlackHolePackage.download()
                defer { BlackHolePackage.removeDownload(file) }
                try await BlackHolePackage.verify(file)
                print("Live publisher download: production downloader, SHA-256, signer and Gatekeeper passed; Installer was NOT opened")
            }
            if let index = CommandLine.arguments.firstIndex(of: "--package"), CommandLine.arguments.count > index + 1 {
                try await BlackHolePackage.verify(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                print("Publisher package: SHA-256, signer and Gatekeeper passed; Installer was NOT opened")
            }
            if CommandLine.arguments.contains("--devices") {
                let devices = try AudioDevices.list()
                guard let selected = AudioDevices.preferredTranslationOutput(in: devices, currentUID: "") else {
                    throw MeetingError.message("No live BlackHole 2ch found")
                }
                print("Read-only device check: \(selected.name), UID \(selected.uid); no system route changed")
            }
        } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }

    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MeetingError.message("Timed out waiting for test state")
    }

    @MainActor static func offline() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            checks += 1; if !condition { throw MeetingError.message(message) }
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.devices = [otherVirtual, microphone, blackHole]; f.setup.start()
            try check(f.currentUID == blackHole.uid && f.setup.ready && !f.setup.presented, "Installed BlackHole must be auto-configured without prompting")
            f.setup.install()
            try check(f.downloads == 0 && f.opens == 0, "Installed device must skip all download/install work")
            f.currentUID = otherVirtual.uid; f.setup.refresh()
            try check(f.currentUID == otherVirtual.uid, "Preserve an existing usable virtual selection")
            f.currentUID = "removed-device"; f.setup.refresh()
            try check(f.currentUID == blackHole.uid, "Recover a stale preference with installed BlackHole")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.devices = [otherVirtual, microphone]; f.setup.start()
            try check(f.setup.presented && !f.setup.ready && f.currentUID.isEmpty, "Never auto-select another app's virtual driver")
            try check(f.downloads == 0, "First launch may prompt but must not download without the user's click")
            f.setup.presented = false; f.setup.start()
            try check(!f.setup.presented, "Do not repeat the prompt on window reappearance")
            let relaunched = f.makeSetup(); relaunched.start()
            try check(!relaunched.presented && relaunched.canInstall, "Postponing survives relaunch while manual setup remains available")
            f.setup.install(); f.setup.install()
            try await wait { f.setup.phase == .waitingForInstaller }
            try check(f.downloads == 1 && f.verifications == 1 && f.opens == 1, "One click starts exactly one verified Installer launch")
            try check(!f.setup.ready, "Opening Installer is not successful installation")
            f.diskInstalled = true; f.setup.refresh()
            try check(f.setup.phase == .restartRequired && !f.setup.canInstall, "Installed files without a HAL device require restart, not reinstall")
            f.devices.append(blackHole); f.setup.refresh()
            try check(f.setup.ready && f.currentUID == blackHole.uid, "Detect and configure the device when it appears")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.diskInstalled = true; f.setup.start(); f.setup.install()
            try check(f.setup.phase == .restartRequired && f.downloads == 0, "Already installed but unloaded driver must not be downloaded again")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.enumerationFails = true; f.setup.start(); f.setup.install()
            try check(f.downloads == 0 && !f.setup.presented, "Enumeration errors must not be treated as missing drivers")
            f.enumerationFails = false
            let relaunched = f.makeSetup(); relaunched.start()
            try check(relaunched.presented, "An enumeration failure must not consume the first-run prompt")
        }
        for failure in ["download", "verify", "open"] {
            let f = Fixture(); defer { f.clean() }
            f.downloadFails = failure == "download"; f.verificationFails = failure == "verify"; f.openerFails = failure == "open"
            f.setup.install(); try await wait { !f.setup.working }
            guard case .failed = f.setup.phase else { throw MeetingError.message("Failure was hidden") }
            try check(f.opens == 0 && !f.setup.ready, "Failed work must not report success")
            if failure == "download" {
                try check(f.verifications == 0, "Failed download must not be verified")
                try check(f.setup.status.contains("网络连接不可用") && !f.setup.status.contains("NSURLErrorDomain"), "Network failure must show actionable Chinese copy")
            }
            f.setup.refresh()
            guard case .failed = f.setup.phase else { throw MeetingError.message("Polling erased failure message") }
            f.downloadFails = false; f.verificationFails = false; f.openerFails = false
            f.setup.install(); try await wait { f.setup.phase == .waitingForInstaller }
            try check(f.opens == 1, "Failure must remain retryable")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.suspendDownload = true; f.setup.install()
            try await wait { f.downloadGate != nil }
            f.setup.cancelDownload(); f.downloadGate?.resume(); f.downloadGate = nil
            try await Task.sleep(for: .milliseconds(30))
            try check(!f.setup.working && f.verifications == 0 && f.opens == 0, "A cancelled download must not launch or verify its late result")
            f.suspendDownload = false; f.setup.install()
            try await wait { f.setup.phase == .waitingForInstaller }
            try check(f.opens == 1, "Cancellation must allow a new attempt")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.suspendVerification = true; f.setup.install()
            try await wait { f.verificationGate != nil }
            f.setup.cancelDownload(); f.verificationGate?.resume(); f.verificationGate = nil
            try await Task.sleep(for: .milliseconds(30))
            try check(f.opens == 0 && !f.setup.working, "Cancelling signature assessment prevents Installer launch")
        }
        for appeared in [true, false] {
            let f = Fixture(); defer { f.clean() }
            f.suspendDownload = true; f.setup.install()
            try await wait { f.downloadGate != nil }
            if appeared { f.devices = [blackHole] } else { f.busy = true }
            f.downloadGate?.resume(); f.downloadGate = nil
            try await wait { !f.setup.working }
            try check(f.opens == 0, "Recheck hardware and meeting state before opening Installer")
            try check(f.setup.ready == appeared, "Only an enumerated device counts as ready")
        }
        do {
            let f = Fixture(); defer { f.clean() }
            f.busy = true; f.setup.install()
            try check(f.downloads == 0, "Do not begin installation during a meeting")
            let outputOnly = AudioDevice(id: 85, uid: blackHole.uid, name: blackHole.name, input: false, output: true, virtual: true)
            try check(AudioDevices.preferredTranslationOutput(in: [outputOnly], currentUID: "") == nil, "Reject a device without microphone channels")
        }
        for url in ["http://existential.audio/downloads/test.pkg", "https://example.com/test.pkg", "https://existential.audio:8443/test.pkg", "https://user@existential.audio/test.pkg"] {
            try check(!BlackHolePackage.allows(URL(string: url)), "Reject a nonpublisher or non-HTTPS redirect")
        }
        try check(BlackHolePackage.allows(BlackHolePackage.url), "Allow the pinned publisher URL")
        for (status, url) in [(404, BlackHolePackage.url), (200, URL(string: "https://example.com/test.pkg")!)] {
            do {
                try BlackHolePackage.validateResponse(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
                throw MeetingError.message("Invalid download response was accepted")
            } catch { try check(error.localizedDescription.contains("官方下载未成功"), "Fail closed on download response errors") }
        }
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pkg")
        try Data("Not the publisher's package".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        do { try BlackHolePackage.verifyDigest(corrupt); throw MeetingError.message("Corrupt package was accepted") }
        catch { try check(error.localizedDescription.contains("校验不通过"), "Reject tampered content before signature checking or launch") }
        print("BlackHole setup: \(checks) assertions, 0 failures; no network, installer, microphone or system-route writes")
    }
}
