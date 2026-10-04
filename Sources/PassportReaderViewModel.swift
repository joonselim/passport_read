import Foundation
import SwiftUI
import NFCPassportReader
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

    /// JSON body for the server: {dg1, sod, dg2} as Base64.
    func exportJSON() -> Data {
        var dict: [String: String] = [
            "dg1": Data(dg1Bytes).base64EncodedString(),
            "sod": Data(sodBytes).base64EncodedString(),
        ]
        if !dg2Bytes.isEmpty {
            dict["dg2"] = Data(dg2Bytes).base64EncodedString()
        }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
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
    @AppStorage("serverURL") var serverURL = "http://192.168.0.10:8080"
    @Published var isVerifying = false
    @Published var verification: VerifyResponse?
    @Published var stages: [PipelineStage: StageState] = [:]

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

    /// Steps 3-7: build the JSON, ping the server, send it, show the results.
    func verify(_ res: PassportResult) async {
        isVerifying = true
        defer { isVerifying = false }
        verification = nil
        for st in [PipelineStage.buildPayload, .serverReachable, .integrity, .signature, .issuerTrust] { set(st, .pending) }

        set(.buildPayload, .running)
        let body = res.exportJSON()
        guard !body.isEmpty, !res.sodBytes.isEmpty else {
            set(.buildPayload, .failed("EMPTY"))
            fail("Nothing to verify: SOD is empty.")
            return
        }
        set(.buildPayload, .done("\(body.count) B"))

        let client: VerificationClient
        do {
            client = try VerificationClient(baseURLString: serverURL)
        } catch {
            set(.serverReachable, .failed("BAD URL"))
            fail(error.localizedDescription)
            return
        }

        set(.serverReachable, .running)
        statusMessage = "Contacting \(client.baseURL.host() ?? "server")…"
        do {
            try await client.ping()
        } catch {
            set(.serverReachable, .failed("OFFLINE"))
            fail(error.localizedDescription)
            return
        }
        set(.serverReachable, .done("OK"))

        set(.integrity, .running); set(.signature, .running); set(.issuerTrust, .running)
        statusMessage = "Verifying on server…"
        do {
            let resp = try await client.verify(body: body)
            verification = resp
            set(.integrity, resp.checks.dataIntegrity.status == "MATCH" ? .done("MATCH") : .failed(resp.checks.dataIntegrity.status))
            set(.signature, resp.checks.signature.status == "VALID" ? .done("VALID") : .failed(resp.checks.signature.status))
            switch resp.checks.issuerTrust.status {
            case "TRUSTED": set(.issuerTrust, .done("TRUSTED"))
            case "UNVERIFIED": set(.issuerTrust, .warning("UNVERIFIED"))
            default: set(.issuerTrust, .failed(resp.checks.issuerTrust.status))
            }
            statusMessage = "Overall: \(resp.overall)"
            log.info("Verification overall=\(resp.overall)")
        } catch {
            for st in [PipelineStage.integrity, .signature, .issuerTrust] { set(st, .failed("ERROR")) }
            fail(error.localizedDescription)
        }
    }

    /// Runs only the server part again with the last read.
    func reverify() async {
        guard let res = result else { return }
        await verify(res)
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
