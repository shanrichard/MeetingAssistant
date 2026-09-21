import Foundation
import SwiftUI
import MeetingCore

@MainActor final class BlackHoleSetup: ObservableObject {
    enum Phase: Equatable {
        case missing, downloading, verifying, waitingForInstaller, restartRequired
        case ready(String), failed(String)
    }
    @Published private(set) var phase: Phase = .missing
    @Published var presented = false
    var configureDevices: ([AudioDevice]) -> AudioDevice? = { _ in nil }
    var meetingIsBusy: () -> Bool = { false }
    private let defaults: UserDefaults
    private let listDevices: () throws -> [AudioDevice]
    private let installedOnDisk: () -> Bool
    private let download: () async throws -> URL
    private let verify: (URL) async throws -> Void
    private let openInstaller: (URL) async throws -> Void
    private var started = false
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private static let promptKey = "blackHoleSetupPresentedV1"

    init(defaults: UserDefaults = .standard,
         listDevices: @escaping () throws -> [AudioDevice] = { try AudioDevices.list() },
         installedOnDisk: @escaping () -> Bool = { BlackHolePackage.installedOnDisk },
         download: @escaping () async throws -> URL = { try await BlackHolePackage.download() },
         verify: @escaping (URL) async throws -> Void = { try await BlackHolePackage.verify($0) },
         openInstaller: @escaping (URL) async throws -> Void = { try await BlackHolePackage.openInstaller($0) }) {
        self.defaults = defaults; self.listDevices = listDevices; self.installedOnDisk = installedOnDisk
        self.download = download; self.verify = verify; self.openInstaller = openInstaller
    }

    var working: Bool { phase == .downloading || phase == .verifying }
    var ready: Bool { if case .ready = phase { return true }; return false }
    var canInstall: Bool { !working && !ready && phase != .restartRequired }
    var status: String {
        switch phase {
        case .missing: return "尚未配置同传音频设备"
        case .downloading: return "正在从 BlackHole 官方网站下载安装包…"
        case .verifying: return "正在校验安装包和开发者签名…"
        case .waitingForInstaller: return "已打开系统安装器，请完成安装。若刚才取消了，可以重试。"
        case .restartRequired: return "已检测到 BlackHole 安装文件，音频设备尚未就绪。请先按安装器提示重启 Mac，再打开本应用。"
        case .ready(let name): return "已配置 \(name)，无需重复安装"
        case .failed(let message): return message
        }
    }

    func start() {
        guard !started else { return }; started = true
        // Enumeration failure is not proof that the driver is absent; allow a later retry.
        guard refresh() else { return }
        if !defaults.bool(forKey: Self.promptKey) {
            defaults.set(true, forKey: Self.promptKey)
            presented = !ready
        }
    }

    /// Reads hardware before any network request and persists a usable selection via the owner.
    @discardableResult func refresh() -> Bool {
        guard !meetingIsBusy() else { return false }
        do {
            if let device = configureDevices(try listDevices()) {
                generation = UUID(); operation?.cancel(); operation = nil
                phase = .ready(device.name)
            } else if !working {
                if installedOnDisk() { phase = .restartRequired }
                else if phase != .waitingForInstaller {
                    // Retain actionable failures until the user explicitly retries.
                    if case .failed = phase {} else { phase = .missing }
                }
            }
            return true
        } catch {
            if !working { phase = .failed("无法检测音频设备：\(error.localizedDescription)") }
            return false
        }
    }

    func install() {
        guard !working, !meetingIsBusy(), refresh(), canInstall else { return }
        let epoch = UUID(); generation = epoch
        phase = .downloading
        operation = Task { [weak self] in
            guard let self else { return }
            var package: URL?
            var opened = false
            defer {
                if let package, !opened { BlackHolePackage.removeDownload(package) }
                if generation == epoch { operation = nil }
            }
            do {
                let file = try await download(); package = file
                try Task.checkCancellation()
                guard generation == epoch else { return }
                phase = .verifying
                try await verify(file)
                try Task.checkCancellation()
                guard generation == epoch else { return }
                guard !meetingIsBusy() else { throw MeetingError.message("会议正在进行，已暂停安装。请结束会议后重试。") }
                // The user may have installed the driver while the download was in flight.
                if let device = configureDevices(try listDevices()) { phase = .ready(device.name); return }
                if installedOnDisk() { phase = .restartRequired; return }
                try await openInstaller(file)
                opened = true
                guard generation == epoch else { return }
                phase = .waitingForInstaller
                refresh()
            } catch {
                guard generation == epoch else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { phase = .missing }
                else { phase = .failed(Self.installationError(error)) }
            }
        }
    }

    private static func installationError(_ error: Error) -> String {
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "下载未完成：网络连接不可用，请连接网络后重试。"
            case .timedOut:
                return "下载超时，请检查网络后重试。"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "无法安全连接 BlackHole 官网，请稍后重试。"
            default:
                return "无法从 BlackHole 官网完成下载，请检查网络后重试。"
            }
        }
        if error is MeetingError { return "安装未完成：\(error.localizedDescription)" }
        return "无法准备或打开安装包，请稍后重试。"
    }

    func cancelDownload() {
        guard working else { return }
        generation = UUID(); operation?.cancel(); operation = nil
        phase = .missing
        refresh()
    }
}
