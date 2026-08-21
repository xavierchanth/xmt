import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            WindowMoverSettingsView()
                .tabItem {
                    Label("Window Mover", systemImage: "rectangle.on.rectangle")
                }
        }
        .frame(width: 560, height: 360)
        .padding(20)
        .background(SettingsWindowAccessor())
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            SettingsWindowController.shared.register(window: window)
        }
    }
}
