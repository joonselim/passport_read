import SwiftUI

/// Home screen: the Digital IDs on this iPhone, and a button to add a passport.
struct WalletView: View {
    @EnvironmentObject private var store: WalletStore
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if store.ids.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.text.rectangle")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                            Text("No Digital IDs yet").font(.headline)
                            Text("Add your passport to create a Digital ID bound to this iPhone.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 40)
                    }

                    ForEach(store.ids) { id in
                        NavigationLink(value: id) {
                            IDCardView(id: id)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        showAdd = true
                    } label: {
                        Label("Add passport", systemImage: "plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                }
                .padding()
            }
            .navigationTitle("Digital IDs")
            .navigationDestination(for: StoredID.self) { id in
                IDDetailView(id: id)
            }
            .fullScreenCover(isPresented: $showAdd) {
                AddPassportView()
                    .environmentObject(store)
            }
        }
    }
}

/// Card for one ID: photo, name, and a masked passport number.
struct IDCardView: View {
    let id: StoredID

    var body: some View {
        let c = id.claims
        HStack(alignment: .center, spacing: 14) {
            Portrait(image: c.portrait)
                .frame(width: 64, height: 82)
            VStack(alignment: .leading, spacing: 4) {
                Text("PASSPORT · \(c.nationality)")
                    .font(.caption2.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.7))
                Text(c.fullName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(Mask.documentNumber(c.documentNumber))
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.white.opacity(0.9))
                if let until = c.validUntil {
                    Text("Valid until \(until.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.6))
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.20, blue: 0.42), Color(red: 0.16, green: 0.38, blue: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Passport photo, or a placeholder.
struct Portrait: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").resizable().scaledToFit().padding(14).foregroundStyle(.secondary)
            }
        }
        .background(Color.white.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
