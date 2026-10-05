import Foundation
import CryptoKit
import LocalAuthentication
import Security

/// The iPhone key a Digital ID is bound to. It is made inside the Secure Enclave and never leaves it.
enum DeviceKey {
    enum KeyError: LocalizedError {
        case noSecureEnclave
        case accessControl

        var errorDescription: String? {
            switch self {
            case .noSecureEnclave: return "This device has no Secure Enclave."
            case .accessControl: return "Could not set up key protection."
            }
        }
    }

    /// Asks for Face ID (or the passcode). The returned context lets the next key use skip a second prompt.
    static func authenticate(reason: String) async throws -> LAContext {
        let context = LAContext()
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        return context
    }

    /// Makes a new key that needs Face ID or the passcode for every use, and only works on this iPhone.
    static func create(context: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else { throw KeyError.noSecureEnclave }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], nil) else {
            throw KeyError.accessControl
        }
        return try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
    }

    /// Opens a saved key blob with an already authenticated context.
    static func load(_ blob: Data, context: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
        try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
    }

    /// ES256 signature as 64 bytes (r || s), the form COSE and the server use.
    static func sign(_ data: Data, with key: SecureEnclave.P256.Signing.PrivateKey) throws -> Data {
        try key.signature(for: data).rawRepresentation
    }
}
