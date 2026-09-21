import Foundation
import Security

public enum CredentialError: LocalizedError {
    case missing, invalidFormat, keychain(OSStatus), verificationFailed
    public var errorDescription: String? {
        switch self {
        case .missing: return "请在设置中填写自己的 OpenAI API Key 并保存。"
        case .invalidFormat: return "Key 格式不正确，请粘贴完整的 OpenAI API Key。"
        case .verificationFailed: return "Key 已写入，但未能确认可读取。请重试保存。"
        case .keychain(let status):
            let reason: String
            switch status {
            case errSecAuthFailed: reason = "macOS 未授权当前版本读取保存的 Key。"
            case errSecUserCanceled: reason = "你取消了 macOS 的钥匙串授权。"
            case errSecInteractionNotAllowed: reason = "钥匙串目前无法交互或处于锁定状态。"
            case errSecNotAvailable: reason = "系统钥匙串暂时不可用。"
            default: reason = "无法访问系统钥匙串（错误码 \(status)）。"
            }
            return reason + "这不是 OpenAI Key 验证结果。请完成系统授权或解锁后重试；如需更换 Key，请在设置中重新填写并保存。"
        }
    }
}

public protocol CredentialStorage {
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

public final class KeychainCredentialStorage: CredentialStorage {
    private let service: String
    private let account: String
    // Keep the ad-hoc prototype's inaccessible item untouched. Stable signed builds use a new item.
    public init(service: String = "com.meetingassistant.openai", account: String = "api-key-v2") {
        self.service = service; self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    public func read() throws -> String? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw CredentialError.verificationFailed
        }
        return key
    }
    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Meeting Assistant OpenAI API Key"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialError.keychain(added) }
        } else if status != errSecSuccess { throw CredentialError.keychain(status) }
        guard try read() == key else { throw CredentialError.verificationFailed }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.keychain(status) }
    }
}

/// Owned by the main-actor controller; caches only successfully saved or loaded credentials.
public final class CredentialSession {
    private let storage: CredentialStorage
    private var cachedKey: String?
    public init(storage: CredentialStorage) { self.storage = storage }
    private func validated(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 8, !key.contains(where: \.isWhitespace) else {
            throw CredentialError.invalidFormat
        }
        return key
    }
    public func save(_ raw: String) throws {
        let key = try validated(raw)
        try storage.save(key)
        cachedKey = key
    }
    public func key() throws -> String {
        if let cachedKey { return cachedKey }
        guard let key = try storage.read() else { throw CredentialError.missing }
        cachedKey = try validated(key)
        return key
    }
    public func deleteSaved() throws { try storage.delete(); cachedKey = nil }
}
