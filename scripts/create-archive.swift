import Foundation

enum ArchiveError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
func codesign(_ arguments: [String], combineError: Bool = false) throws -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); process.arguments = arguments
    process.standardOutput = output
    process.standardError = combineError ? output : FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ArchiveError.message("代码签名检查失败。") }
    return String(decoding: data, as: UTF8.self)
}
do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let forCloudSigning = arguments.first == "--for-cloud-signing"
    if forCloudSigning { arguments.removeFirst() }
    guard arguments.count == 2 else {
        throw ArchiveError.message("Usage: swift scripts/create-archive.swift [--for-cloud-signing] APPLICATION.app OUTPUT.xcarchive")
    }
    let application = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    let archive = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let manager = FileManager.default
    guard !manager.fileExists(atPath: archive.path) else { throw ArchiveError.message("归档已存在，请使用新的输出路径。") }
    _ = try codesign(["--verify", "--deep", "--strict", application.path])
    let signature = try codesign(["--display", "--verbose=4", application.path], combineError: true)
    let lines = signature.components(separatedBy: .newlines)
    let authorityPrefix = forCloudSigning ? "Authority=Apple Development:" : "Authority=Developer ID Application:"
    guard let authority = lines.first(where: { $0.hasPrefix(authorityPrefix) }),
          let team = lines.first(where: { $0.hasPrefix("TeamIdentifier=") && !$0.hasSuffix("not set") }),
          signature.contains("(runtime)"), lines.contains(where: { $0.hasPrefix("Timestamp=") }) else {
        throw ArchiveError.message(forCloudSigning
            ? "待云端签名归档必须具有 Apple Development 签名、Hardened Runtime 和安全时间戳。"
            : "正式归档必须具有 Developer ID Application 签名、Hardened Runtime 和安全时间戳。")
    }
    let entitlementText = try codesign(["--display", "--entitlements", ":-", application.path])
    guard let entitlements = try PropertyListSerialization.propertyList(from: Data(entitlementText.utf8), format: nil) as? [String: Any],
          entitlements["com.apple.security.device.audio-input"] as? Bool == true,
          entitlements["com.apple.security.get-task-allow"] as? Bool != true else {
        throw ArchiveError.message("正式归档的音频权限或调试权限不符合要求。")
    }
    let infoData = try Data(contentsOf: application.appendingPathComponent("Contents/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
          let bundle = info["CFBundleIdentifier"] as? String,
          let version = info["CFBundleShortVersionString"] as? String,
          let build = info["CFBundleVersion"] as? String else { throw ArchiveError.message("应用版本信息缺失。") }
    let relativePath = "Applications/MeetingAssistant.app"
    let products = archive.appendingPathComponent("Products/Applications", isDirectory: true)
    try manager.createDirectory(at: products, withIntermediateDirectories: true)
    try manager.copyItem(at: application, to: products.appendingPathComponent("MeetingAssistant.app"))
    let metadata: [String: Any] = ["ArchiveVersion": 2, "CreationDate": Date(), "Name": "MeetingAssistant", "SchemeName": "MeetingAssistant",
        "ApplicationProperties": ["ApplicationPath": relativePath, "CFBundleIdentifier": bundle,
            "CFBundleShortVersionString": version, "CFBundleVersion": build,
            "SigningIdentity": String(authority.dropFirst("Authority=".count)), "Team": String(team.dropFirst("TeamIdentifier=".count))]]
    try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        .write(to: archive.appendingPathComponent("Info.plist"), options: .atomic)
    if forCloudSigning {
        print("Prepared for Xcode cloud signing only; Developer ID signing and notarization are still required.")
    }
    print(archive.path)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
