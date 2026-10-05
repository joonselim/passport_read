import SwiftUI

/// App entry point.
@main
struct PassportReaderApp: App {
    @StateObject private var store = WalletStore()

    var body: some Scene {
        WindowGroup {
            WalletView()
                .environmentObject(store)
        }
    }
}
