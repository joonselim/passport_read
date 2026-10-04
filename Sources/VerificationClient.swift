import Foundation

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

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "Invalid server URL: \(s)"
        case .unreachable(let s): return "Server unreachable: \(s)"
        case .server(let code, let msg): return "Server error \(code): \(msg)"
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

    /// GET /health: is the server reachable? (5 second timeout)
    func ping() async throws {
        var req = URLRequest(url: baseURL.appending(path: "api/v1/passport/health"))
        req.timeoutInterval = 5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw VerificationError.unreachable("unexpected status")
            }
        } catch let e as VerificationError {
            throw e
        } catch {
            throw VerificationError.unreachable(error.localizedDescription)
        }
    }

    /// POST /verify with the JSON body and decode the result.
    func verify(body: Data) async throws -> VerifyResponse {
        var req = URLRequest(url: baseURL.appending(path: "api/v1/passport/verify"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
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
        return try JSONDecoder().decode(VerifyResponse.self, from: data)
    }
}
