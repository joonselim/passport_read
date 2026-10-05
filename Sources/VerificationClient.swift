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

/// Issuance answer: the passport check, and the Digital ID if it passed.
struct IssueResponse: Decodable {
    let verification: VerifyResponse
    let credential: CredentialPayload?
    let reason: String?
}

/// A Digital ID as the server sends it (all Base64).
struct CredentialPayload: Decodable {
    let docType: String
    let issuerAuth: String
    let items: [ItemPayload]
}

/// One signed field, as JSON.
struct ItemPayload: Codable {
    let namespace: String
    let elementIdentifier: String
    let bytes: String
}

/// What the verifier asks for.
struct VerifierRequest: Decodable {
    let nonce: String
    let docType: String
    let elements: [String]
    let verifier: String
    let purpose: String
}

/// The verifier's decision and the fields it received.
struct PresentResult: Decodable {
    let result: String
    let checks: [String: String]
    let issuer: String?
    let disclosed: [String: DisclosedValue]
}

/// A received field: text (Base64 for the photo) or true/false.
enum DisclosedValue: Decodable {
    case text(String)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) } else { self = .text(try c.decode(String.self)) }
    }

    /// Value for display.
    var display: String {
        switch self {
        case .text(let s): return s
        case .bool(let b): return b ? "Yes" : "No"
        }
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
    /// Placeholder address. Set the real one in the app under Advanced.
    static let defaultServerURL = "http://192.168.0.10:8080"

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

    /// POST /verify-sealed: check the passport only.
    func verify(_ sealed: SealedRequest) async throws -> VerifyResponse {
        try decodeAnswer(VerifyResponse.self, from: try await send(sealed, to: "api/v1/passport/verify-sealed"))
    }

    /// GET /issuer/challenge: a one-time value to sign with the device key.
    func challenge() async throws -> Data {
        struct Answer: Decodable { let challenge: String }
        let answer: Answer = try await getJSON("api/v1/issuer/challenge")
        guard let data = Data(base64Encoded: answer.challenge) else { throw VerificationError.badResponse("challenge") }
        return data
    }

    /// POST /issuer/issue-sealed: check the passport and get a Digital ID if it passes.
    func issue(_ sealed: SealedRequest) async throws -> IssueResponse {
        try decodeAnswer(IssueResponse.self, from: try await send(sealed, to: "api/v1/issuer/issue-sealed"))
    }

    /// GET /verifier/request?purpose=...: what the demo verifier wants.
    func verifierRequest(purpose: String) async throws -> VerifierRequest {
        try await getJSON("api/v1/verifier/request", query: [URLQueryItem(name: "purpose", value: purpose)])
    }

    /// POST /verifier/present-sealed: show the chosen fields to the verifier.
    func present(_ sealed: SealedRequest) async throws -> PresentResult {
        try decodeAnswer(PresentResult.self, from: try await send(sealed, to: "api/v1/verifier/present-sealed"))
    }

    /// Plain GET returning JSON.
    private func getJSON<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw VerificationError.unreachable(error.localizedDescription)
        }
        try Self.check(resp, data)
        return try decodeAnswer(T.self, from: data)
    }

    /// POSTs an encrypted body and returns the decrypted answer.
    private func send(_ sealed: SealedRequest, to path: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appending(path: path))
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
        try Self.check(resp, data)
        do {
            let wrapper = try JSONDecoder().decode([String: String].self, from: data)
            guard let b64 = wrapper["ciphertext"], let combined = Data(base64Encoded: b64) else {
                throw VerificationError.badResponse("no ciphertext")
            }
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: sealed.responseKey)
        } catch let e as VerificationError {
            throw e
        } catch {
            throw VerificationError.badResponse(error.localizedDescription)
        }
    }

    /// Throws the server's error message for non-2xx answers.
    private static func check(_ resp: URLResponse, _ data: Data) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let apiErr = try? JSONDecoder().decode(ApiError.self, from: data)
            let msg = apiErr?.errors?.joined(separator: "; ") ?? apiErr?.error ?? String(data: data, encoding: .utf8) ?? ""
            throw VerificationError.server(code, msg)
        }
    }

    /// JSON decoding with a readable error.
    private func decodeAnswer<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw VerificationError.badResponse(error.localizedDescription)
        }
    }
}
