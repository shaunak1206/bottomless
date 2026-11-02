import SwiftUI
import BottomlessCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.configured {
            SetupNeededView()
        } else {
            TabView {
                LibraryView(mode: .all)
                    .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
                CollectionsView()
                    .tabItem { Label("Collections", systemImage: "rectangle.stack") }
                StatusView()
                    .tabItem { Label("Backup", systemImage: model.waitingCount > 0 ? "icloud.and.arrow.up" : "checkmark.icloud") }
                    .badge(model.failedCount > 0 ? Text("!") : nil)
            }
            .alert("Bottomless", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.message ?? "") }
        }
    }
}

struct SetupNeededView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Not set up", systemImage: "wrench.and.screwdriver")
        } description: {
            Text("This build has no server address or token. Run scripts/setup_cloud.sh on your Mac, then build the app again.")
        }
    }
}

/// Banner shown at the top of the library when the phone is offline.
struct OfflineBanner: View {
    var body: some View {
        Label("Offline: showing what is saved on this iPhone", systemImage: "wifi.slash")
            .font(.footnote.weight(.medium))
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(.thinMaterial, in: Capsule())
            .accessibilityIdentifier("offlineBanner")
    }
}
