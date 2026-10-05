import Foundation
import CryptoKit

/// JSON from POST /verify (same shape as the Java server's response).
struct VerifyResponse: Decodable {
    let overall: String                 // PASS | FAIL | UNVERIFIED
    let checks: Checks
    let details: Details?
    let errors: [String]?

    struct Checks: Decodable {
        let dataIntegrity: DataIntegrity
        let signature: SignatureCheck
        let issuerTrust: IssuerTrust
    }
    struct DataIntegrity: Decodable {
        let status: String              // MATCH | MISMATCH
        let digestAlgorithm: String?
        let dataGroups: [String: String]?
    }
    struct SignatureCheck: Decodable {
        let status: String              // VALID | INVALID
        let algorithm: String?
    }
    struct IssuerTrust: Decodable {
        let status: String              // TRUSTED | UNVERIFIED | FAILED
        let reason: String?
    }
    struct Details: Decodable {
        let documentSigner: DocumentSigner?
        let sod: Sod?
    }
    struct DocumentSigner: Decodable {
        let subject: String?
        let issuer: String?
        let notAfter: String?
        let withinValidity: Bool?
        let signatureAlgorithm: String?
    }
    struct Sod: Decodable {
        let ldsVersion: String?
        let hashedDataGroups: [Int]?
    }
}

/// GET /health answer.
struct Health: Decodable {
    let status: String
    let cscaCertificates: Int?
    let hpkeKeyId: String?
}

/// Encrypted body ready to send, plus the key that will open the server's answer.
struct SealedRequest {
    let body: Data
    let responseKey: SymmetricKey
}

/// The server's encryption key, pinned in Info.plist (HPKEServerPublicKey).
enum ServerKey {
    /// Same suite as the server: X25519 + HKDF-SHA256 + ChaCha20-Poly1305.
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    /// Context string mixed into the keys. Must match the server.
    static let info = Data("passport_validate/v1".utf8)
    /// Label for deriving the response key. Must match the server.
    static let responseLabel = Data("response".utf8)

    /// Reads the pinned public key.
    static func load() throws -> Curve25519.KeyAgreement.PublicKey {
        guard let b64 = Bundle.main.object(forInfoDictionaryKey: "HPKEServerPublicKey") as? String,
              let raw = Data(base64Encoded: b64),
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else {
            throw VerificationError.noServerKey
        }
        return key
    }

    /// Short id of a key: first 8 bytes of SHA-256, in hex. Same as the server's hpkeKeyId.
    static func id(of key: Curve25519.KeyAgreement.PublicKey) -> String {
        SHA256.hash(data: key.rawRepresentation).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Error JSON from the server (400 / 422).
private struct ApiError: Decodable {
    let error: String?
    let errors: [String]?
}

/// Errors shown to the user.
enum VerificationError: LocalizedError {
    case badURL(String)
    case unreachable(String)
    case server(Int, String)
    case noServerKey
    case keyMismatch(server: String, app: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "Invalid server URL: \(s)"
        case .unreachable(let s): return "Server unreachable: \(s)"
        case .server(let code, let msg): return "Server error \(code): \(msg)"
        case .noServerKey: return "No server key in the app. Set HPKEServerPublicKey in project.yml."
        case .keyMismatch(let server, let app): return "Server key does not match the app (server \(server), app \(app)). Update HPKEServerPublicKey."
        case .badResponse(let s): return "Could not read the server's answer: \(s)"
        }
    }
}

/// Talks to the Java server.
struct VerificationClient {
    let baseURL: URL

    /// Checks that the server address is a valid URL.
    init(baseURLString: String) throws {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw VerificationError.badURL(baseURLString)
        }
        baseURL = url
    }

    /// GET /health: is the server reachable, and does it use the key pinned in the app? (5 second timeout)
    func ping() async throws {
        var req = URLRequest(url: baseURL.appending(path: "api/v1/passport/health"))
        req.timeoutInterval = 5
        let health: Health
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw VerificationError.unreachable("unexpected status")
            }
            health = try JSONDecoder().decode(Health.self, from: data)
        } catch let e as VerificationError {
            throw e
        } catch {
            throw VerificationError.unreachable(error.localizedDescription)
        }
        let appKeyId = ServerKey.id(of: try ServerKey.load())
        guard health.hpkeKeyId == appKeyId else {
            throw VerificationError.keyMismatch(server: health.hpkeKeyId ?? "none", app: appKeyId)
        }
    }

    /// Encrypts the JSON for the server (HPKE). Only the server's private key can open it.
    static func seal(_ payload: Data) throws -> SealedRequest {
        var sender = try HPKE.Sender(recipientKey: try ServerKey.load(), ciphersuite: ServerKey.suite, info: ServerKey.info)
        let ciphertext = try sender.seal(payload)
        let responseKey = try sender.exportSecret(context: ServerKey.responseLabel, outputByteCount: 32)
        let body = try JSONSerialization.data(withJSONObject: [
            "enc": sender.encapsulatedKey.base64EncodedString(),
            "ciphertext": ciphertext.base64EncodedString(),
        ])
        return SealedRequest(body: body, responseKey: responseKey)
    }

    /// POST /verify-sealed with the encrypted body, then decrypt and decode the answer.
    func verify(_ sealed: SealedRequest) async throws -> VerifyResponse {
        var req = URLRequest(url: baseURL.appending(path: "api/v1/passport/verify-sealed"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = sealed.body
        req.timeoutInterval = 20

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw VerificationError.unreachable(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let apiErr = try? JSONDecoder().decode(ApiError.self, from: data)
            let msg = apiErr?.errors?.joined(separator: "; ") ?? apiErr?.error ?? String(data: data, encoding: .utf8) ?? ""
            throw VerificationError.server(code, msg)
        }
        do {
            let wrapper = try JSONDecoder().decode([String: String].self, from: data)
            guard let b64 = wrapper["ciphertext"], let combined = Data(base64Encoded: b64) else {
                throw VerificationError.badResponse("no ciphertext")
            }
            let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: sealed.responseKey)
            return try JSONDecoder().decode(VerifyResponse.self, from: plain)
        } catch let e as VerificationError {
            throw e
        } catch {
            throw VerificationError.badResponse(error.localizedDescription)
        }
    }
}
