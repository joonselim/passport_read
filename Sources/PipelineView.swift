import SwiftUI

/// The 7 steps, in the order they run.
enum PipelineStage: Int, CaseIterable, Identifiable {
    case nfcAuth = 1       // BAC/PACE with the chip
    case readDataGroups    // DG1 / DG2 / SOD
    case buildPayload      // Base64 JSON
    case serverReachable   // GET /health
    case integrity         // DG hashes vs SOD
    case signature         // SOD signature vs DS cert
    case issuerTrust       // DS cert chains to CSCA

    var id: Int { rawValue }

    /// Step name.
    var title: String {
        switch self {
        case .nfcAuth: return "NFC access"
        case .readDataGroups: return "Read data groups"
        case .buildPayload: return "Build JSON"
        case .serverReachable: return "Server reachable"
        case .integrity: return "Data integrity"
        case .signature: return "SOD signature"
        case .issuerTrust: return "Issuer trust"
        }
    }

    /// Short description under the name.
    var subtitle: String {
        switch self {
        case .nfcAuth: return "BAC/PACE with MRZ key"
        case .readDataGroups: return "DG1 · DG2 · SOD"
        case .buildPayload: return "Base64 {dg1, dg2, sod}"
        case .serverReachable: return "GET /api/v1/passport/health"
        case .integrity: return "DG hashes vs SOD"
        case .signature: return "DS certificate → SOD"
        case .issuerTrust: return "DS certificate → CSCA"
        }
    }

    /// Steps 1-3 run on the phone, 4-7 on the server.
    var isServerSide: Bool { rawValue >= PipelineStage.serverReachable.rawValue }
}

/// State of one step.
enum StageState: Equatable {
    case pending
    case running
    case done(String)          // label, e.g. "OK", "MATCH", "VALID", "TRUSTED"
    case warning(String)       // e.g. "UNVERIFIED"
    case failed(String)        // e.g. "FAILED", "MISMATCH"
}

/// Shows the 7 steps with an icon and a status label.
struct PipelineView: View {
    let states: [PipelineStage: StageState]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PipelineStage.allCases) { stage in
                if stage == .serverReachable {
                    sectionLabel("Java server")
                } else if stage == .nfcAuth {
                    sectionLabel("iPhone")
                }
                row(stage, states[stage] ?? .pending)
            }
        }
    }

    /// Small "IPHONE" / "JAVA SERVER" header.
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(1)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    /// One step row.
    private func row(_ stage: PipelineStage, _ state: StageState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            indicator(state)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(stage.rawValue). \(stage.title)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                Text(stage.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            badge(state)
        }
        .padding(.vertical, 6)
    }

    /// Left icon: empty, spinner, check, warning or X.
    @ViewBuilder
    private func indicator(_ state: StageState) -> some View {
        switch state {
        case .pending:
            Circle().strokeBorder(.quaternary, lineWidth: 1.5)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title3)
        }
    }

    /// Right label like OK or MATCH.
    @ViewBuilder
    private func badge(_ state: StageState) -> some View {
        switch state {
        case .pending: EmptyView()
        case .running: Text("…").font(.caption.monospaced()).foregroundStyle(.secondary)
        case .done(let s): pill(s, .green)
        case .warning(let s): pill(s, .orange)
        case .failed(let s): pill(s, .red)
        }
    }

    /// Colored rounded label.
    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospaced())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
