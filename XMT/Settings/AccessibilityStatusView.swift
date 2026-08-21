import SwiftUI

struct AccessibilityStatusView: View {
    @ObservedObject private var accessibility = AccessibilityService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: accessibility.displayedIsGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(accessibility.displayedIsGranted ? Color.green : Color.red)
                Text(accessibility.displayedIsGranted
                     ? "Accessibility access granted"
                     : "Accessibility access required")
                Spacer()
                if !accessibility.displayedIsGranted {
                    Button("Request Access") {
                        accessibility.requestIfNeeded()
                    }
                    Button("Open System Settings") {
                        accessibility.openSystemSettings()
                    }
                }
            }

            Text("Window Mover uses Accessibility to read and move the focused window.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            accessibility.refresh()
        }
    }
}
