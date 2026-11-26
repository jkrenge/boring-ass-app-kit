import SwiftUI

extension View {
    /// Asks the user to update, with a link to the App Store, when the Worker offers a newer version.
    /// Put it on your root view, so it asks once per launch.
    public func updatePrompt() -> some View { modifier(UpdatePrompt()) }
}

private struct UpdatePrompt: ViewModifier {
    @Environment(\.openURL) private var openURL
    @State private var update: AppUpdate?
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .task {
                update = await BoringKit.availableUpdate()
                showing = update != nil
            }
            .alert("Update available", isPresented: $showing, presenting: update) { update in
                Button("Update") { openURL(storeURL(update.url)) }
                Button("Not now", role: .cancel) {}
            } message: { update in
                Text("Version \(update.version) is on the App Store.")
            }
    }

    private func storeURL(_ url: URL) -> URL {
        #if os(macOS)
            // macappstore:// opens the App Store app; https would open the web page in a browser
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "macappstore"
            return components?.url ?? url
        #else
            return url
        #endif
    }
}
