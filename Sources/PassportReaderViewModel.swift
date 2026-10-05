import Foundation
import SwiftUI
import NFCPassportReader
import CryptoKit
import OSLog

private let log = Logger(subsystem: "com.joonselim.PassportReader", category: "reader")

/// Passport data from the chip, plus the raw files for the server.
struct PassportResult {
    // Display fields (DG1)
    let documentType: String
    let documentNumber: String
    let lastName: String
    let firstName: String
    let nationality: String
    let dateOfBirth: String        // YYMMDD
    let dateOfExpiry: String       // YYMMDD
    let gender: String
    let issuingAuthority: String
    let faceImage: UIImage?        // DG2 (optional)

    /// Raw chip files sent to the server.
    let dg1Bytes: [UInt8]          // raw EF.DG1
    let sodBytes: [UInt8]          // raw EF.SOD
    let dg2Bytes: [UInt8]          // raw EF.DG2 (photo)

    /// Copies what we need from the library's result.
    init(model: NFCPassportModel) {
        documentType = model.documentType
        documentNumber = model.documentNumber
        lastName = model.lastName
        firstName = model.firstName
        nationality = model.nationality
        dateOfBirth = model.dateOfBirth
        dateOfExpiry = model.documentExpiryDate
        gender = model.gender
        issuingAuthority = model.issuingAuthority
        faceImage = model.passportImage

        dg1Bytes = model.getDataGroup(.DG1)?.data ?? []
        sodBytes = model.getDataGroup(.SOD)?.data ?? []
        dg2Bytes = model.getDataGroup(.DG2)?.data ?? []
    }

    /// The chip files as Base64: {dg1, sod, dg2}.
    func exportFields() -> [String: String] {
        var dict: [String: String] = [
            "dg1": Data(dg1Bytes).base64EncodedString(),
            "sod": Data(sodBytes).base64EncodedString(),
        ]
        if !dg2Bytes.isEmpty {
            dict["dg2"] = Data(dg2Bytes).base64EncodedString()
        }
        return dict
    }

    /// JSON body for the server: {dg1, sod, dg2} as Base64.
    func exportJSON() -> Data {
        (try? JSONSerialization.data(withJSONObject: exportFields(), options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Issuance body: the chip files, the device public key, the challenge, and the device's signature over it.
    func issuanceJSON(devicePublicKey: Data, challenge: Data, proof: Data) -> Data {
        var dict = exportFields()
        dict["devicePublicKey"] = devicePublicKey.base64EncodedString()
        dict["challenge"] = challenge.base64EncodedString()
        dict["proof"] = proof.base64EncodedString()
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    /// What the device signs to prove it holds the key: CBOR ["IssuanceRequest", challenge, SHA-256(SOD)].
    func proofInput(challenge: Data) -> Data {
        CBOR.array([.text("IssuanceRequest"), .bytes(challenge), .bytes(Data(SHA256.hash(data: Data(sodBytes))))]).encoded()
    }

    /// Saves the JSON to a temp file for the share sheet.
    func exportFileURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("passport-\(documentNumber).json")
        try? exportJSON().write(to: url, options: .atomic)
        return url
    }
}

/// Screen state, plus the read and verify logic.
@MainActor
final class PassportReaderViewModel: ObservableObject {
    // Inputs
    @Published var passportNumber = ""
    @Published var dateOfBirth = ""   // YYMMDD
    @Published var dateOfExpiry = ""  // YYMMDD

    // State
    @Published var isReading = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var result: PassportResult?
    /// True after a failed chip read (shows the Retry button).
    @Published var readFailed = false
    @Published var readAttempts = 0

    // Verification (Java server)
    @AppStorage("serverURL") var serverURL = VerificationClient.defaultServerURL
    @Published var isVerifying = false
    @Published var verification: VerifyResponse?
    @Published var stages: [PipelineStage: StageState] = [:]
    /// The Digital ID added in this session, if any.
    @Published var addedID: StoredID?

    private let reader = PassportReader()

    /// Updates one pipeline step.
    private func set(_ stage: PipelineStage, _ state: StageState) {
        stages[stage] = state
    }

    /// True when all 3 MRZ fields are filled in.
    var canRead: Bool {
        !passportNumber.trimmingCharacters(in: .whitespaces).isEmpty
            && isSixDigits(dateOfBirth)
            && isSixDigits(dateOfExpiry)
    }

    /// Lists the missing fields.
    var validationHint: String {
        var missing: [String] = []
        if passportNumber.trimmingCharacters(in: .whitespaces).isEmpty { missing.append("passport number") }
        if !isSixDigits(dateOfBirth) { missing.append("date of birth (6 digits)") }
        if !isSixDigits(dateOfExpiry) { missing.append("expiry date (6 digits)") }
        return "Enter: " + missing.joined(separator: ", ")
    }

    /// YYMMDD format check.
    private func isSixDigits(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy(\.isNumber)
    }

    /// Steps 1-2: unlock the chip with the MRZ key and read DG1, DG2 and SOD.
    func read() async {
        errorMessage = nil
        showError = false
        statusMessage = "Starting NFC session…"
        guard canRead else {
            fail("Enter the passport number, date of birth (YYMMDD) and expiry date (YYMMDD).")
            return
        }

        isReading = true
        defer { isReading = false }
        readFailed = false
        readAttempts += 1
        result = nil
        verification = nil
        addedID = nil
        stages = [:]
        set(.nfcAuth, .running)

        let mrzKey = PassportUtils.getMRZKey(
            passportNumber: passportNumber.trimmingCharacters(in: .whitespaces).uppercased(),
            dateOfBirth: dateOfBirth,
            dateOfExpiry: dateOfExpiry
        )
        log.info("Starting read, mrzKey length=\(mrzKey.count)")

        do {
            let model = try await reader.readPassport(
                mrzKey: mrzKey,
                tags: [.COM, .DG1, .DG2, .SOD],
                customDisplayMessage: { [weak self] msg in
                    let text: String?
                    switch msg {
                    case .requestPresentPassport:
                        text = "Hold the passport's photo page against the top back of the iPhone."
                    case .authenticatingWithPassport:
                        text = "Authenticating with passport chip…"
                    case .readingDataGroupProgress(let dg, let progress):
                        text = "Reading \(dg)… \(progress)%"
                        Task { @MainActor in
                            self?.set(.nfcAuth, .done("OK"))
                            self?.set(.readDataGroups, .running)
                        }
                    case .successfulRead:
                        text = "Read complete."
                    case .error:
                        text = nil
                    case .activeAuthentication:
                        text = "Verifying chip authenticity…"
                    }
                    if let text {
                        log.info("\(text)")
                        Task { @MainActor in self?.statusMessage = text }
                    }
                    return text
                }
            )
            log.info("Read succeeded")
            statusMessage = "Read complete."
            let res = PassportResult(model: model)
            self.result = res
            set(.nfcAuth, .done("OK"))
            set(.readDataGroups, .done("\(res.dg1Bytes.count + res.dg2Bytes.count + res.sodBytes.count) B"))
            // The user checks the data, then taps Verify.
        } catch {
            log.error("Read failed: \(String(describing: error))")
            if stages[.readDataGroups] == .running { set(.readDataGroups, .failed("ERROR")) }
            else { set(.nfcAuth, .failed("ERROR")) }
            readFailed = true
            // Show the error inline with a Retry button.
            statusMessage = readableError(error)
        }
    }

    /// Steps 3-10: get a challenge, make the device key, encrypt, let the server check the passport
    /// and issue a Digital ID, then save it on this iPhone.
    func verifyAndIssue(_ res: PassportResult, store: WalletStore) async {
        isVerifying = true
        defer { isVerifying = false }
        verification = nil
        addedID = nil
        for st in PipelineStage.allCases where st.rawValue >= PipelineStage.serverReachable.rawValue { set(st, .pending) }

        guard !res.sodBytes.isEmpty else {
            fail("Nothing to verify: SOD is empty.")
            return
        }
        let client: VerificationClient
        do {
            client = try VerificationClient(baseURLString: serverURL)
        } catch {
            set(.serverReachable, .failed("BAD URL"))
            fail(error.localizedDescription)
            return
        }

        // 3. Server reachable, same key as pinned, and a fresh challenge.
        set(.serverReachable, .running)
        statusMessage = "Contacting \(client.baseURL.host() ?? "server")…"
        let challenge: Data
        do {
            try await client.ping()
            challenge = try await client.challenge()
        } catch VerificationError.keyMismatch(let server, let app) {
            set(.serverReachable, .failed("KEY"))
            fail(VerificationError.keyMismatch(server: server, app: app).localizedDescription)
            return
        } catch {
            set(.serverReachable, .failed("OFFLINE"))
            fail(error.localizedDescription)
            return
        }
        set(.serverReachable, .done("OK"))

        // 4. New Secure Enclave key, protected by Face ID; sign the challenge with it.
        set(.deviceKey, .running)
        statusMessage = "Confirm with Face ID…"
        let key: SecureEnclave.P256.Signing.PrivateKey
        let proof: Data
        do {
            let context = try await DeviceKey.authenticate(reason: "Add your passport as a Digital ID on this iPhone")
            key = try DeviceKey.create(context: context)
            proof = try DeviceKey.sign(res.proofInput(challenge: challenge), with: key)
        } catch {
            set(.deviceKey, .failed("CANCELLED"))
            fail(error.localizedDescription)
            return
        }
        set(.deviceKey, .done("P-256"))

        // 5. Encrypt everything for the server.
        set(.buildPayload, .running)
        let sealed: SealedRequest
        do {
            let body = res.issuanceJSON(devicePublicKey: key.publicKey.x963Representation, challenge: challenge, proof: proof)
            sealed = try VerificationClient.seal(body)
        } catch {
            set(.buildPayload, .failed("KEY"))
            fail(error.localizedDescription)
            return
        }
        set(.buildPayload, .done("\(sealed.body.count) B"))

        // 6-9. Server checks the passport and, if it passes, signs a Digital ID.
        for st in [PipelineStage.integrity, .signature, .issuerTrust, .issueID] { set(st, .running) }
        statusMessage = "Verifying on server…"
        let resp: IssueResponse
        do {
            resp = try await client.issue(sealed)
        } catch {
            for st in [PipelineStage.integrity, .signature, .issuerTrust, .issueID] { set(st, .failed("ERROR")) }
            fail(error.localizedDescription)
            return
        }
        show(resp.verification)
        guard let credential = resp.credential else {
            set(.issueID, .failed("NOT ISSUED"))
            statusMessage = "No Digital ID: \(resp.reason ?? "passport check did not pass")."
            return
        }
        set(.issueID, .done("SIGNED"))

        // 10. Save on this iPhone.
        set(.saveID, .running)
        do {
            let stored = try StoredID(
                id: UUID(),
                docType: credential.docType,
                issuerAuth: Self.base64(credential.issuerAuth),
                items: credential.items.map {
                    StoredID.Item(namespace: $0.namespace, elementIdentifier: $0.elementIdentifier, bytes: try Self.base64($0.bytes))
                },
                deviceKey: key.dataRepresentation,
                addedAt: Date())
            try store.add(stored)
            addedID = stored
            set(.saveID, .done("KEYCHAIN"))
            statusMessage = "Digital ID added."
            log.info("Digital ID added")
        } catch {
            set(.saveID, .failed("ERROR"))
            fail("Could not save the Digital ID: \(error.localizedDescription)")
        }
    }

    /// Maps the server's three passport checks onto steps 6-8.
    private func show(_ v: VerifyResponse) {
        verification = v
        set(.integrity, v.checks.dataIntegrity.status == "MATCH" ? .done("MATCH") : .failed(v.checks.dataIntegrity.status))
        set(.signature, v.checks.signature.status == "VALID" ? .done("VALID") : .failed(v.checks.signature.status))
        switch v.checks.issuerTrust.status {
        case "TRUSTED": set(.issuerTrust, .done("TRUSTED"))
        case "UNVERIFIED": set(.issuerTrust, .warning("UNVERIFIED"))
        default: set(.issuerTrust, .failed(v.checks.issuerTrust.status))
        }
        log.info("Verification overall=\(v.overall)")
    }

    /// Base64 text to bytes, or an error.
    private static func base64(_ s: String) throws -> Data {
        guard let d = Data(base64Encoded: s) else { throw VerificationError.badResponse("bad Base64") }
        return d
    }

    /// Shows an error popup.
    private func fail(_ message: String) {
        statusMessage = nil
        errorMessage = message
        showError = true
    }

    /// Turns library errors into short messages.
    private func readableError(_ error: Error) -> String {
        let desc = "\(error)"
        if desc.contains("UserCanceled") || desc.contains("userCancelled") {
            return "Read was cancelled."
        }
        if desc.contains("ConnectionError") || desc.contains("TagNotValid") || desc.contains("tagConnectionLost")
            || desc.contains("Tag connection lost") || desc.contains("sessionTimeout") || desc.contains("Session invalidated") {
            return "Lost contact with the chip. Keep the passport still against the top back of the phone and try again."
        }
        if desc.contains("ResponseError") || desc.contains("6300") {
            return "Could not access the passport. Check the passport number, date of birth and expiry date."
        }
        if desc.contains("NFCNotSupported") {
            return "NFC is not supported on this device."
        }
        return "Read failed: \(desc)"
    }
}
