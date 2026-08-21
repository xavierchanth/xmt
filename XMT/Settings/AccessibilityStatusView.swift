import SwiftUI

struct AccessibilityStatusView: View {
    private let consumerDescription: String
    @ObservedObject private var accessibility = AccessibilityService.shared

    init(
        consumerDescription: String = "Window Mover uses Accessibility to read and move the focused window."
    ) {
        self.consumerDescription = consumerDescription
    }

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

            Text(consumerDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            accessibility.refresh()
        }
    }
}
