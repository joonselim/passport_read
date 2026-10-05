import SwiftUI
import CoreNFC

/// Main screen: scan, read the chip, show the passport, verify with the server.
struct ContentView: View {
    @StateObject private var vm = PassportReaderViewModel()
    @State private var showScanner = false
    @State private var showManualEntry = false
    @State private var showConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                if !NFCTagReaderSession.readingAvailable {
                    Section {
                        Label("NFC tag reading is not available on this device.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                // Step 1: scan the MRZ with the camera.
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        HStack {
                            Spacer()
                            if vm.isReading {
                                ProgressView().padding(.trailing, 6)
                                Text("Reading chip…").bold()
                            } else {
                                Label("Scan passport", systemImage: "camera.viewfinder").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(vm.isReading || vm.isVerifying)
                } footer: {
                    Text("Point the camera at the two MRZ lines on the photo page. The chip is read right after.")
                }

                // Chip read failed: retry with the same values.
                if vm.readFailed && vm.result == nil && !vm.isReading {
                    Section {
                        Button {
                            Task { await vm.read() }
                        } label: {
                            HStack { Spacer(); Label("Retry NFC read", systemImage: "arrow.clockwise").bold(); Spacer() }
                        }
                        .disabled(!vm.canRead)
                    } header: {
                        Text("Chip read failed (attempt \(vm.readAttempts))")
                    } footer: {
                        Text((vm.statusMessage ?? "") + "\n\nTip: remove any case, put the passport's photo page flat against the top third of the phone's back, and don't move until the sheet says it's done.")
                    }
                }

                // Step 2: passport data from the chip.
                if let result = vm.result {
                    Section("Passport") {
                        HStack(alignment: .top, spacing: 14) {
                            if let img = result.faceImage {
                                Image(uiImage: img)
                                    .resizable().scaledToFill()
                                    .frame(width: 72, height: 92)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(result.lastName) \(result.firstName)").font(.headline)
                                Text(result.documentNumber).font(.subheadline.monospaced())
                                Text("\(result.nationality) · \(result.gender)").font(.caption).foregroundStyle(.secondary)
                                Text("DOB \(result.dateOfBirth) · Exp \(result.dateOfExpiry)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        NavigationLink("All passport data") {
                            PassportDetailView(result: result)
                        }
                    }

                    // Step 3: verify on the server.
                    if vm.verification == nil && !vm.isVerifying {
                        Section {
                            Button {
                                Task { await vm.reverify() }
                            } label: {
                                HStack { Spacer(); Label("Verify with server", systemImage: "checkmark.shield").bold(); Spacer() }
                            }
                        } footer: {
                            Text("Encrypts DG1, DG2 and SOD with the server's key (HPKE) and sends them to \(vm.serverURL).")
                        }
                    }
                }

                if !vm.stages.isEmpty {
                    Section {
                        PipelineView(states: vm.stages)
                    } header: {
                        Text("Pipeline")
                    } footer: {
                        if let status = vm.statusMessage, !vm.readFailed { Text(status) }
                    }
                }

                if let v = vm.verification {
                    Section("Verification result") {
                        overallRow(v.overall)
                        checkRow("Data integrity", v.checks.dataIntegrity.status, detail: v.checks.dataIntegrity.digestAlgorithm)
                        checkRow("SOD signature", v.checks.signature.status, detail: v.checks.signature.algorithm)
                        checkRow("Issuer trust", v.checks.issuerTrust.status, detail: v.checks.issuerTrust.reason)
                        if let ds = v.details?.documentSigner {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Document signer").font(.caption).foregroundStyle(.secondary)
                                Text(ds.subject ?? "-").font(.caption.monospaced())
                                Text("issued by " + (ds.issuer ?? "-")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Button("Re-verify") { Task { await vm.reverify() } }
                            .disabled(vm.isVerifying || vm.isReading)
                    }
                }

                // Manual entry and server address.
                Section {
                    DisclosureGroup("Enter MRZ manually", isExpanded: $showManualEntry) {
                        LabeledTextField(title: "Passport number", placeholder: "e.g. M12345678", text: $vm.passportNumber, autoUppercase: true)
                        LabeledTextField(title: "Date of birth (YYMMDD)", placeholder: "e.g. 900101", text: $vm.dateOfBirth, keyboard: .numberPad)
                        LabeledTextField(title: "Expiry date (YYMMDD)", placeholder: "e.g. 301231", text: $vm.dateOfExpiry, keyboard: .numberPad)
                        Button("Read chip with these values") { Task { await vm.read() } }
                            .disabled(!vm.canRead || vm.isReading)
                    }
                    LabeledTextField(title: "Verification server", placeholder: "http://10.0.0.5:8080", text: $vm.serverURL, keyboard: .URL)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Phone and Mac must be on the same Wi-Fi.")
                }
            }
            .navigationTitle("ePassport Reader")
            .alert("Failed", isPresented: $vm.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.errorMessage ?? "Unknown error")
            }
            .sheet(isPresented: $showConfirm) {
                MRZConfirmView(
                    passportNumber: $vm.passportNumber,
                    dateOfBirth: $vm.dateOfBirth,
                    dateOfExpiry: $vm.dateOfExpiry,
                    onReadChip: {
                        showConfirm = false
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            await vm.read()
                        }
                    },
                    onRescan: {
                        showConfirm = false
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            showScanner = true
                        }
                    }
                )
                .presentationDetents([.medium])
            }
            .fullScreenCover(isPresented: $showScanner) {
                NavigationStack {
                    MRZScannerView { info in
                        vm.passportNumber = info.documentNumber
                        vm.dateOfBirth = info.dateOfBirth
                        vm.dateOfExpiry = info.dateOfExpiry
                        showScanner = false
                        // Show the confirm screen next.
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            showConfirm = true
                        }
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan MRZ")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showScanner = false }
                        }
                    }
                }
            }
        }
    }

    /// Colored PASS / FAIL / UNVERIFIED badge.
    private func overallRow(_ overall: String) -> some View {
        let color: Color = overall == "PASS" ? .green : overall == "UNVERIFIED" ? .orange : .red
        return HStack {
            Text("Overall").bold()
            Spacer()
            Text(overall)
                .font(.subheadline.weight(.bold).monospaced())
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
    }

    /// One check: name, status and detail.
    private func checkRow(_ title: String, _ status: String, detail: String?) -> some View {
        let good = ["MATCH", "VALID", "TRUSTED"].contains(status)
        let warn = status == "UNVERIFIED"
        let color: Color = good ? .green : warn ? .orange : .red
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(status).font(.caption.weight(.semibold).monospaced()).foregroundStyle(color)
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Lets the user check the scanned values before reading the chip.
private struct MRZConfirmView: View {
    @Binding var passportNumber: String
    @Binding var dateOfBirth: String
    @Binding var dateOfExpiry: String
    let onReadChip: () -> Void
    let onRescan: () -> Void

    private var valid: Bool {
        !passportNumber.isEmpty && dateOfBirth.count == 6 && dateOfExpiry.count == 6
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledTextField(title: "Passport number", placeholder: "", text: $passportNumber, autoUppercase: true)
                    LabeledTextField(title: "Date of birth (YYMMDD)", placeholder: "", text: $dateOfBirth, keyboard: .numberPad)
                    LabeledTextField(title: "Expiry date (YYMMDD)", placeholder: "", text: $dateOfExpiry, keyboard: .numberPad)
                } header: {
                    Text("Check against the passport")
                } footer: {
                    Text("Compare with the printed MRZ (bottom two lines). Fix any character that differs, then read the chip. 0/O, 5/S and 1/I are the usual mix-ups.")
                }
                Section {
                    Button {
                        onReadChip()
                    } label: {
                        HStack { Spacer(); Label("Looks right — read chip", systemImage: "wave.3.right").bold(); Spacer() }
                    }
                    .disabled(!valid)
                    Button("Rescan with camera", action: onRescan)
                }
            }
            .navigationTitle("Confirm MRZ")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Text field with a small label above it.
private struct LabeledTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var autoUppercase: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autoUppercase ? .characters : .never)
                .autocorrectionDisabled()
        }
    }
}

#Preview {
    ContentView()
}
