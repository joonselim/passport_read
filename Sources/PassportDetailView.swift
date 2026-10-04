import SwiftUI

/// Full passport data, JSON export, and raw file sizes.
struct PassportDetailView: View {
    let result: PassportResult

    var body: some View {
        List {
            if let image = result.faceImage {
                Section("Face image (DG2)") {
                    HStack {
                        Spacer()
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Spacer()
                    }
                }
            }

            Section("Passport data (DG1)") {
                row("Type", result.documentType)
                row("Passport number", result.documentNumber)
                row("Last name", result.lastName)
                row("First name", result.firstName)
                row("Nationality", result.nationality)
                row("Date of birth", formatDate(result.dateOfBirth))
                row("Expiry date", formatDate(result.dateOfExpiry))
                row("Gender", result.gender)
                row("Issuing authority", result.issuingAuthority)
            }

            Section {
                ShareLink(item: result.exportFileURL()) {
                    Label("Export JSON for verification", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Shares {dg1, sod, dg2} as Base64 JSON. Send it to the Mac and POST it to passport_validate (/api/v1/passport/verify).")
            }

            Section("Raw data for next step (Java verification)") {
                row("EF.DG1 size", "\(result.dg1Bytes.count) bytes")
                row("EF.DG2 size", "\(result.dg2Bytes.count) bytes")
                row("EF.SOD size", "\(result.sodBytes.count) bytes")
                DisclosureGroup("DG1 hex preview") {
                    Text(hexPreview(result.dg1Bytes))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
                DisclosureGroup("SOD hex preview") {
                    Text(hexPreview(result.sodBytes))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Label on the left, value on the right.
    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "-" : value)
                .multilineTextAlignment(.trailing)
        }
    }

    /// YYMMDD to YYYY-MM-DD (guesses the century).
    private func formatDate(_ yymmdd: String) -> String {
        guard yymmdd.count == 6 else { return yymmdd }
        let yy = Int(yymmdd.prefix(2)) ?? 0
        let century = yy <= 50 ? 2000 : 1900   // simple guess
        let mm = yymmdd.dropFirst(2).prefix(2)
        let dd = yymmdd.suffix(2)
        return "\(century + yy)-\(mm)-\(dd)"
    }

    /// First 64 bytes as hex.
    private func hexPreview(_ bytes: [UInt8], limit: Int = 64) -> String {
        let slice = bytes.prefix(limit)
        let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > limit ? hex + " …" : hex
    }
}
