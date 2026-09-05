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

            KeyboardSettingsView()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }

            #if XMT_VOICE
            VoiceSettingsView()
                .tabItem {
                    Label("Voice", systemImage: "waveform")
                }
            #endif
        }
        .frame(width: 620, height: 560)
        .padding(20)
    }
}
