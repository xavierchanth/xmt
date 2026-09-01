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

            VoiceSettingsView()
                .tabItem {
                    Label("Voice", systemImage: "waveform")
                }
        }
        .frame(width: 620, height: 560)
        .padding(20)
    }
}
