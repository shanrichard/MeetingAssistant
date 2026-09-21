import Foundation
import Security
import MeetingCore

final class FakeCredentialStorage: CredentialStorage {
    var value: String?
    var fail = false
    var reads = 0, writes = 0, deletes = 0
    func read() throws -> String? { reads += 1; if fail { throw CredentialError.keychain(errSecAuthFailed) }; return value }
    func save(_ key: String) throws { writes += 1; if fail { throw CredentialError.keychain(errSecAuthFailed) }; value = key }
    func delete() throws { deletes += 1; if fail { throw CredentialError.keychain(errSecAuthFailed) }; value = nil }
}

func checkCredentials() throws {
    let unavailable = FakeCredentialStorage(); unavailable.fail = true
    let unsaved = CredentialSession(storage: unavailable)
    expectThrows { try unsaved.save("sk-unit-test-unsaved") }
    expectThrows { _ = try unsaved.key() } // Failed saves never become usable in-memory credentials.
    expect(unavailable.writes == 1 && unavailable.reads == 1)
    expect(unavailable.value == nil)

    let storage = FakeCredentialStorage()
    let saved = CredentialSession(storage: storage)
    expectThrows { try saved.save("not-a-key") }
    expectThrows { try saved.save("sk-broken key") }
    expect(storage.writes == 0)
    try saved.save("  sk-unit-test-persisted \n")
    expect(storage.value == "sk-unit-test-persisted")
    let relaunch = CredentialSession(storage: storage)
    expect(try relaunch.key() == "sk-unit-test-persisted")
    storage.fail = true
    expect(try relaunch.key() == "sk-unit-test-persisted") // No repeated Keychain prompts in one run.
    expectThrows { try relaunch.save("sk-unit-test-replacement") }
    expect(try relaunch.key() == "sk-unit-test-persisted") // Failed replacement preserves the working key.
    expectThrows { try relaunch.deleteSaved() }
    expect(try relaunch.key() == "sk-unit-test-persisted")
    storage.fail = false
    try relaunch.deleteSaved()
    expectThrows { _ = try relaunch.key() }
    expect(storage.deletes == 2)
    let explanation = CredentialError.keychain(errSecAuthFailed).localizedDescription
    expect(explanation.contains("重新填写并保存"))
    expect(explanation.contains("不是 OpenAI Key 验证结果"))
    expect(!explanation.contains("passphrase"))
}
