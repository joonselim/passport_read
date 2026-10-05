import SwiftUI

/// One Digital ID: photo, name, masked details (Face ID to reveal), present, and remove.
struct IDDetailView: View {
    let id: StoredID
    @EnvironmentObject private var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = false
    @State private var showPresent = false
    @State private var confirmRemove = false

    var body: some View {
        let c = id.claims
        List {
            Section {
                VStack(spacing: 10) {
                    Portrait(image: c.portrait)
                        .frame(width: 120, height: 154)
                    Text(c.fullName).font(.title3.bold())
                    Text("Passport · \(c.nationality)").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                row("Passport number", revealed ? c.documentNumber : Mask.documentNumber(c.documentNumber), mono: true)
                row("Date of birth", revealed ? c.birthDate : Mask.birthDate(c.birthDate), mono: true)
                row("Expiry date", revealed ? c.expiryDate : Mask.expiryDate(c.expiryDate), mono: true)
                row("Sex", c.sex)
                Button {
                    Task { await toggleReveal() }
                } label: {
                    Label(revealed ? "Hide details" : "Show details", systemImage: revealed ? "eye.slash" : "eye")
                }
            } header: {
                Text("Details")
            } footer: {
                Text("Showing full details needs Face ID.")
            }

            Section {
                if let until = c.validUntil {
                    row("Valid until", until.formatted(date: .abbreviated, time: .omitted))
                }
                row("Bound to", "This iPhone (Secure Enclave)")
                row("Added", id.addedAt.formatted(date: .abbreviated, time: .shortened))
            } header: {
                Text("Digital ID")
            }

            Section {
                Button {
                    showPresent = true
                } label: {
                    HStack { Spacer(); Label("Present ID", systemImage: "wave.3.forward").bold(); Spacer() }
                }
            } footer: {
                Text("Share only the fields a verifier asks for, signed by this iPhone.")
            }

            Section {
                Button("Remove from this iPhone", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle("Digital ID")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPresent) {
            PresentView(id: id)
        }
        .confirmationDialog("Remove this Digital ID?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.remove(id)
                dismiss()
            }
        } message: {
            Text("You can add it again by scanning the passport.")
        }
    }

    /// Hides right away; showing asks for Face ID first.
    private func toggleReveal() async {
        if revealed {
            revealed = false
            return
        }
        if (try? await DeviceKey.authenticate(reason: "Show full passport details")) != nil {
            revealed = true
        }
    }

    /// Label on the left, value on the right.
    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "-" : value)
                .font(mono ? .body.monospaced() : .body)
                .multilineTextAlignment(.trailing)
        }
    }
}
