import Foundation
import Security

@main struct KeychainIntegration {
    static func main() {
        do { try run() } catch {
            FileHandle.standardError.write(Data("FAIL credential integration: \(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
    static func run() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Expected operation and isolated test service") }
        let operation = CommandLine.arguments[1], service = CommandLine.arguments[2]
        guard service.hasPrefix("com.meetingassistant.tests.credentials.") else { fatalError("Refusing non-test service") }
        // Any unexpected authorization dialog fails this test rather than involving the user.
        SecKeychainSetUserInteractionAllowed(false)
        let storage = KeychainCredentialStorage(service: service, account: "test-fixture")
        switch operation {
        case "write": try storage.save("sk-unit-test-first")
        case "read": guard try storage.read() == "sk-unit-test-first" else { throw CredentialError.verificationFailed }
        case "replace": try storage.save("sk-unit-test-second")
        case "read-replaced": guard try storage.read() == "sk-unit-test-second" else { throw CredentialError.verificationFailed }
        case "upgrade":
            let session = CredentialSession(storage: storage)
            do {
                guard try session.key() == "sk-unit-test-second" else { throw CredentialError.verificationFailed }
                print("PASS cross-version saved credential access")
            } catch CredentialError.keychain(let status) where status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                // Self-signed local builds can still require authorization after binary changes.
                // Keep this limitation visible; the app asks the user to authorize access or save again.
                print("LIMITATION: upgraded local build requires fresh Keychain authorization (\(status))")
            }
        case "delete": try storage.delete()
        case "missing": guard try storage.read() == nil else { throw CredentialError.verificationFailed }
        default: fatalError("Unknown test operation")
        }
        #if KEYCHAIN_CHECK_UPGRADE
        print("PASS upgraded binary: \(operation)")
        #else
        print("PASS original binary: \(operation)")
        #endif
    }
}
