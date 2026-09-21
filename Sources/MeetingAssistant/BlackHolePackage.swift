import AppKit
import CryptoKit
import Foundation
import MeetingCore

/// Downloaded directly from the publisher; the application does not redistribute the package.
enum BlackHolePackage {
    // Pinned against Homebrew/homebrew-cask Casks/b/blackhole-2ch.rb on 2026-09-21.
    static let version = "0.7.1"
    static let url = URL(string: "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg")!
    static let sha256 = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"
    static let signer = "Developer ID Installer: Existential Audio Inc. (Q5C99V536K)"
    static let website = URL(string: "https://existential.audio/blackhole/")!

    static var installedOnDisk: Bool {
        let info = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver/Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return plist["CFBundleIdentifier"] as? String == "audio.existential.BlackHole2ch"
    }

    static func download() async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: OfficialDownloadDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try validateResponse(response)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingAssistant-BlackHole-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        do { try FileManager.default.moveItem(at: temporary, to: destination); return destination }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    static func allows(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == "existential.audio" && (url?.port == nil || url?.port == 443)
            && url?.user == nil && url?.password == nil
    }

    static func validateResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, allows(response.url) else {
            throw MeetingError.message("官方下载未成功，请稍后重试。")
        }
    }

    static func verifyDigest(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw MeetingError.message("安装包校验不通过，未打开安装器。请重新下载；若仍失败，请等待应用更新。")
        }
    }

    static func verify(_ file: URL) async throws {
        // Package assessment can consult Apple's services; never block the UI actor.
        try await Task.detached(priority: .userInitiated) {
            try verifyDigest(file)
            let signature = try runCheck("/usr/sbin/pkgutil", ["--check-signature", file.path])
            guard signature.contains(signer) else {
                throw MeetingError.message("安装包签名不是预期的 BlackHole 发布者，未打开安装器。")
            }
            _ = try runCheck("/usr/sbin/spctl", ["--assess", "--type", "install", file.path])
        }.value
        try Task.checkCancellation()
    }

    private static func runCheck(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment; environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = output; process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MeetingError.message("macOS 未通过安装包安全检查，未打开安装器。请检查网络后重试。")
        }
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor static func openInstaller(_ file: URL) async throws {
        _ = try await NSWorkspace.shared.open([file],
            withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }

    static func removeDownload(_ file: URL) {
        // Only remove the private directory created by this downloader.
        let folder = file.deletingLastPathComponent()
        if folder.lastPathComponent.hasPrefix("MeetingAssistant-BlackHole-") {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

private final class OfficialDownloadDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(BlackHolePackage.allows(request.url) ? request : nil)
    }
}
