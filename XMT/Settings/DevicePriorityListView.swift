import SwiftUI

struct DevicePriorityListView: View {
    @ObservedObject var module: VoiceTranscriptionModule

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(Array(module.devicePriority.enumerated()), id: \.offset) { index, item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Button { move(index, -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                        Button { move(index, 1) } label: { Image(systemName: "chevron.down") }.disabled(index + 1 == module.devicePriority.count)
                        Button(role: .destructive) { module.devicePriority.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    }
                }
            }.frame(minHeight: 90)
            Menu("Add input device") {
                ForEach(module.availableDevices, id: \.uid) { device in
                    Button(device.name) {
                        guard !module.devicePriority.contains(where: { $0.uid == device.uid }) else { return }
                        module.devicePriority.append(.init(name: device.name, uid: device.uid))
                    }
                }
            }
            Toggle("Fall back to the system default input", isOn: $module.fallbackToSystemDefault)
        }
    }

    private func move(_ index: Int, _ delta: Int) {
        let destination = index + delta; guard module.devicePriority.indices.contains(destination) else { return }
        module.devicePriority.swapAt(index, destination)
    }
}
