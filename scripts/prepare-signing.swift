import Foundation
import Security
import CryptoKit

// Create a private, project-specific development identity. It is never added to system trust.
// Secrets are passed to Security APIs in memory, never in command-line arguments or output.
func check(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else {
        throw NSError(domain: "MeetingAssistant.Signing", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (OSStatus \(status))"])
    }
}
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "MeetingAssistant.Signing", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Development certificate generation failed"])
    }
}
do {
    guard CommandLine.arguments.count == 2 else { throw NSError(domain: "Usage: prepare-signing.swift DIRECTORY", code: 1) }
    let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let manager = FileManager.default
    try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    let passwordFile = folder.appendingPathComponent("keychain-password")
    let keychainFile = folder.appendingPathComponent("development.keychain-db")
    let certificateFile = folder.appendingPathComponent("certificate.der")
    if !manager.fileExists(atPath: passwordFile.path) {
        var bytes = [UInt8](repeating: 0, count: 32)
        try check(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes), "Generate signing password")
        try Data(Data(bytes).base64EncodedString().utf8).write(to: passwordFile, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFile.path)
    }
    let password = try Data(contentsOf: passwordFile)
    var keychain: SecKeychain?
    if manager.fileExists(atPath: keychainFile.path) {
        try check(SecKeychainOpen(keychainFile.path, &keychain), "Open development keychain")
    } else {
        try password.withUnsafeBytes { bytes in
            try check(SecKeychainCreate(keychainFile.path, UInt32(password.count), bytes.baseAddress, false, nil, &keychain), "Create development keychain")
        }
    }
    try password.withUnsafeBytes { bytes in
        try check(SecKeychainUnlock(keychain, UInt32(password.count), bytes.baseAddress, true), "Unlock development keychain")
    }
    // codesign requires its identity's keychain on the user's search list even with --keychain.
    // Preserve all existing entries; this does not change the default keychain or certificate trust.
    var existing: CFArray?
    try check(SecKeychainCopySearchList(&existing), "Read keychain search list")
    var searchList = (existing as? [SecKeychain]) ?? []
    if !searchList.contains(where: { CFEqual($0, keychain!) }) {
        searchList.append(keychain!)
        try check(SecKeychainSetSearchList(searchList as CFArray), "Register development keychain")
    }
    if !manager.fileExists(atPath: certificateFile.path) {
        let temporary = folder.appendingPathComponent("provision-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let config = temporary.appendingPathComponent("certificate.cnf")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = extensions
        prompt = no
        [dn]
        CN = MeetingAssistant Local Development
        [extensions]
        basicConstraints = critical,CA:false
        keyUsage = critical,digitalSignature
        extendedKeyUsage = critical,codeSigning
        subjectKeyIdentifier = hash
        """.write(to: config, atomically: true, encoding: .utf8)
        let privateKey = temporary.appendingPathComponent("private.pem")
        let certificate = temporary.appendingPathComponent("certificate.pem")
        let archive = temporary.appendingPathComponent("identity.p12")
        try run("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-x509", "-days", "3650",
            "-config", config.path, "-keyout", privateKey.path, "-out", certificate.path])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKey.path)
        try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", privateKey.path, "-in", certificate.path,
            "-out", archive.path, "-passout", "file:" + passwordFile.path])
        var trusted: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trusted), "Allow codesign to use development identity")
        var access: SecAccess?
        try check(SecAccessCreate("MeetingAssistant local development signing" as CFString, [trusted!] as CFArray, &access), "Create signing access")
        let options: [String: Any] = [kSecImportExportPassphrase as String: String(decoding: password, as: UTF8.self),
            kSecImportExportKeychain as String: keychain!, kSecImportExportAccess as String: access!]
        var imported: CFArray?
        try check(SecPKCS12Import(try Data(contentsOf: archive) as CFData, options as CFDictionary, &imported), "Import development identity")
        try run("/usr/bin/openssl", ["x509", "-in", certificate.path, "-outform", "DER", "-out", certificateFile.path])
    }
    let certificate = try Data(contentsOf: certificateFile)
    print(Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined())
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
