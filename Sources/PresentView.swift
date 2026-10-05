import SwiftUI
import CryptoKit

/// Presents a Digital ID to the demo verifier: pick a request, approve with Face ID, see what was shared.
struct PresentView: View {
    let id: StoredID
    @StateObject private var model = PresentationModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.request == nil && model.result == nil {
                    Section {
                        purposeButton("Age check", detail: "A bar asks: are you over 21?", purpose: "age", icon: "person.badge.clock")
                        purposeButton("Identity check", detail: "A hotel asks for your photo, name and passport", purpose: "identity", icon: "building.2")
                    } header: {
                        Text("Demo verifier")
                    } footer: {
                        Text("The verifier runs on the same server here, but stands for a different company.")
                    }
                }

                if let request = model.request, model.result == nil {
                    Section {
                        ForEach(request.elements, id: \.self) { element in
                            Label(FieldName.label(element), systemImage: "checkmark.circle")
                        }
                    } header: {
                        Text("\(request.verifier) asks for")
                    } footer: {
                        Text("Nothing else is shared. The verifier can check these fields were signed by the issuer and that this iPhone holds the ID.")
                    }
                    Section {
                        Button {
                            Task { await model.share(id) }
                        } label: {
                            HStack { Spacer(); Label("Share with Face ID", systemImage: "faceid").bold(); Spacer() }
                        }
                        .disabled(model.busy)
                    }
                }

                if let result = model.result {
                    resultSections(result)
                }

                if model.busy {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Present ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// One verifier request option.
    private func purposeButton(_ title: String, detail: String, purpose: String, icon: String) -> some View {
        Button {
            Task { await model.start(purpose) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(model.busy)
    }

    /// The verifier's decision, what it received, and each check.
    @ViewBuilder
    private func resultSections(_ r: PresentResult) -> some View {
        let accepted = r.result == "ACCEPTED"
        Section {
            HStack {
                Image(systemName: accepted ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(accepted ? .green : .red)
                VStack(alignment: .leading) {
                    Text(r.result).font(.title3.bold().monospaced())
                    Text(r.issuer ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if !r.disclosed.isEmpty {
            Section("Verifier received") {
                if case .text(let b64)? = r.disclosed["portrait"], let data = Data(base64Encoded: b64), let img = UIImage(data: data) {
                    HStack { Spacer(); Image(uiImage: img).resizable().scaledToFit().frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 8)); Spacer() }
                }
                ForEach(r.disclosed.keys.filter { $0 != "portrait" }.sorted(), id: \.self) { key in
                    HStack {
                        Text(FieldName.label(key)).foregroundStyle(.secondary)
                        Spacer()
                        Text(r.disclosed[key]?.display ?? "").monospaced()
                    }
                }
            }
        }
        Section("Verifier checks") {
            ForEach(PresentationModel.checkOrder, id: \.key) { item in
                HStack {
                    Text(item.label)
                    Spacer()
                    let value = r.checks[item.key] ?? "-"
                    Text(value)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(["VALID", "MATCH", "FRESH", "YES"].contains(value) ? .green : .red)
                }
            }
        }
    }
}

/// Talks to the demo verifier and signs with the device key.
@MainActor
final class PresentationModel: ObservableObject {
    @AppStorage("serverURL") var serverURL = VerificationClient.defaultServerURL
    @Published var request: VerifierRequest?
    @Published var result: PresentResult?
    @Published var busy = false
    @Published var error: String?

    /// Checks shown on the result screen, in order.
    static let checkOrder: [(key: String, label: String)] = [
        ("issuerSignature", "Issuer signature"),
        ("validity", "Valid dates"),
        ("dataDigests", "Fields match signed hashes"),
        ("deviceSignature", "Signed by the bound iPhone"),
        ("nonce", "Fresh request"),
        ("requestedOnly", "Only requested fields"),
    ]

    /// Asks the verifier what it wants.
    func start(_ purpose: String) async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let client = try VerificationClient(baseURLString: serverURL)
            try await client.ping()
            request = try await client.verifierRequest(purpose: purpose)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Face ID, then sign the verifier's nonce and the chosen field names with the device key, and send only those fields.
    func share(_ id: StoredID) async {
        guard let request else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            let context = try await DeviceKey.authenticate(reason: "Share \(request.elements.count) field(s) with \(request.verifier)")
            let key = try DeviceKey.load(id.deviceKey, context: context)
            let chosen = id.items.filter { request.elements.contains($0.elementIdentifier) }
            guard let nonce = Data(base64Encoded: request.nonce) else { throw VerificationError.badResponse("nonce") }
            let toSign = CBOR.array([
                .text("DeviceAuthentication"), .bytes(nonce), .text(id.docType),
                .array(chosen.map { .text($0.elementIdentifier) }),
            ]).encoded()
            let signature = try DeviceKey.sign(toSign, with: key)

            let body = try JSONSerialization.data(withJSONObject: [
                "nonce": request.nonce,
                "docType": id.docType,
                "issuerAuth": id.issuerAuth.base64EncodedString(),
                "items": chosen.map { ["namespace": $0.namespace, "elementIdentifier": $0.elementIdentifier, "bytes": $0.bytes.base64EncodedString()] },
                "deviceSignature": signature.base64EncodedString(),
            ])
            let client = try VerificationClient(baseURLString: serverURL)
            result = try await client.present(try VerificationClient.seal(body))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
