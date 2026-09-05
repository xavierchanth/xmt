import SwiftUI

/// Configuration surface only: the unavailable backend never acquires or discovers keyboards.
struct KeyboardSettingsView: View {
    @ObservedObject private var configuration = ConfigurationCoordinator.shared
    @State private var addingDevice = false
    @State private var profileID = ""
    @State private var vendorID = ""
    @State private var productID = ""
    @State private var serialNumber = ""
    @State private var locationID = ""
    @State private var builtIn = false
    @State private var formError: String?

    private var settings: EffectiveKeyboardCustomizationSettings { configuration.effective.keyboardCustomization }

    var body: some View {
        Form {
            Section("Backend status") {
                Label("Unavailable — keyboard backend is not installed", systemImage: "keyboard.badge.ellipsis")
                Text("These controls save requested behavior only. No keyboard is discovered, intercepted, or remapped by this build. Live use requires the signed backend and separate hardware validation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Capabilities") {
                Toggle("Hyper Caps: tap Escape, hold Hyper", isOn: Binding(
                    get: { settings.hyperEnabled.value },
                    set: { value in edit { $0.hyperEnabled = value } }
                )).disabled(settings.hyperEnabled.isManaged)
                source(settings.hyperEnabled.source)
                Toggle("Home-row modifiers", isOn: Binding(
                    get: { settings.homeRowEnabled.value },
                    set: { value in edit { $0.homeRowEnabled = value } }
                )).disabled(settings.homeRowEnabled.isManaged)
                source(settings.homeRowEnabled.source)
                Text("A / ; → Control · S / L → Shift · D / K → Option · F / J → Command")
                    .font(.caption)
                Text("Caps + another key forms Hyper immediately. Home-row holds use the configured threshold. Taps preserve your keyboard layout.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Explicitly included keyboards") {
                if settings.devices.isEmpty { Text("No keyboards included. Unlisted devices remain untouched.") }
                source(settings.devicesSource)
                ForEach(settings.devices) { device in
                    DisclosureGroup(device.id) {
                        Text("Vendor \(device.identity.vendorID) · Product \(device.identity.productID)")
                            .font(.caption).foregroundStyle(.secondary)
                        timing("Hyper hold", value: device.hyperHoldMs, range: 1...60_000) { value in
                            editDevice(device) { $0.hyperHoldMs = value }
                        }
                        timing("Home-row hold", value: device.homeRowHoldMs, range: 1...60_000) { value in
                            editDevice(device) { $0.homeRowHoldMs = value }
                        }
                        timing("Home-row quick-tap", value: device.homeRowQuickTapMs, range: 0...60_000) { value in
                            editDevice(device) { $0.homeRowQuickTapMs = value }
                        }
                        DisclosureGroup("Per-key timing overrides") {
                            ForEach(KeyboardMappedPosition.allCases, id: \.self) { key in
                                if let resolved = device.keyTiming[key] {
                                    timing("\(key.rawValue) hold", value: resolved.holdMs, range: 1...60_000) { value in
                                        editDevice(device) { local in
                                            var keys = local.keyTiming ?? [:]
                                            var entry = keys[key.rawValue] ?? .init()
                                            entry.holdMs = value; keys[key.rawValue] = entry; local.keyTiming = keys
                                        }
                                    }
                                    if key != .capsLock {
                                        timing("\(key.rawValue) quick-tap", value: resolved.quickTapMs, range: 0...60_000) { value in
                                            editDevice(device) { local in
                                                var keys = local.keyTiming ?? [:]
                                                var entry = keys[key.rawValue] ?? .init()
                                                entry.quickTapMs = value; keys[key.rawValue] = entry; local.keyTiming = keys
                                            }
                                        }
                                    }
                                    Button("Reset \(key.rawValue) overrides") { reset(device, key: key) }
                                        .disabled(resolved.holdMs.isManaged && (key == .capsLock || resolved.quickTapMs.isManaged))
                                }
                            }
                        }
                        Button("Reset unmanaged timings to defaults") { reset(device) }
                        Button("Remove keyboard profile", role: .destructive) {
                            edit { $0.devices?.removeAll { $0.id == device.id } }
                        }.disabled(settings.devicesSource == .configFile)
                    }
                }
                Button("Add keyboard profile…") { addingDevice = true }
                    .disabled(settings.devicesSource == .configFile)
                Text("Profiles use explicit device identities. Firmware-managed keyboards should stay excluded. Fn-Caps recovery has not been validated and is not available in this build.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let diagnostic = configuration.diagnostic {
                Section("Configuration issue") { Text(diagnostic).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .disabled(configuration.keyboardCommitIsActive)
        .sheet(isPresented: $addingDevice) {
            Form {
                Text("Add an explicit keyboard identity").font(.headline)
                Text("Enter known identity values; this form does not scan hardware.").font(.caption)
                TextField("Profile ID", text: $profileID)
                TextField("Vendor ID (decimal)", text: $vendorID)
                TextField("Product ID (decimal)", text: $productID)
                TextField("Serial number", text: $serialNumber)
                TextField("Location ID (decimal, optional)", text: $locationID)
                Toggle("Built-in keyboard", isOn: $builtIn)
                if let formError { Text(formError).foregroundStyle(.red) }
                HStack {
                    Button("Cancel") { addingDevice = false }
                    Button("Save profile") { addDevice() }
                }
            }.padding().frame(width: 420)
        }
    }

    private func source(_ value: SettingSource) -> some View {
        Text(value == .configFile ? "Managed by configuration file" : value == .local ? "Local preference" : "Built-in default")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func timing(_ label: String, value: ResolvedSetting<Int>, range: ClosedRange<Int>,
                        set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("Milliseconds", value: Binding(get: { value.value }, set: set), format: .number)
                .frame(width: 80).accessibilityLabel("\(label) milliseconds")
            Text("ms").foregroundStyle(.secondary)
            if value.isManaged { Image(systemName: "lock.fill").accessibilityLabel("Managed by configuration file") }
        }.disabled(value.isManaged)
    }

    private func edit(_ update: @escaping (inout KeyboardCustomizationDTO) -> Void) {
        Task { await configuration.updateKeyboardSettings(update) }
    }

    private func editDevice(_ device: EffectiveKeyboardCustomizationSettings.Device,
                            _ update: @escaping (inout KeyboardCustomizationDTO.Device) -> Void) {
        edit { settings in
            var devices = settings.devices ?? []
            let index: Int
            if let existing = devices.firstIndex(where: { $0.id == device.id && $0.identity == device.identity }) { index = existing }
            else { devices.append(.init(id: device.id, identity: device.identity)); index = devices.count - 1 }
            update(&devices[index]); settings.devices = devices
        }
    }

    private func reset(_ device: EffectiveKeyboardCustomizationSettings.Device, key: KeyboardMappedPosition? = nil) {
        editDevice(device) { local in
            if key == nil {
                if !device.hyperHoldMs.isManaged { local.hyperHoldMs = nil }
                if !device.homeRowHoldMs.isManaged { local.homeRowHoldMs = nil }
                if !device.homeRowQuickTapMs.isManaged { local.homeRowQuickTapMs = nil }
            }
            var overrides = local.keyTiming ?? [:]
            for position in key.map({ [$0] }) ?? KeyboardMappedPosition.allCases {
                guard var entry = overrides[position.rawValue], let resolved = device.keyTiming[position] else { continue }
                if !resolved.holdMs.isManaged { entry.holdMs = nil }
                if !resolved.quickTapMs.isManaged { entry.quickTapMs = nil }
                overrides[position.rawValue] = entry.holdMs == nil && entry.quickTapMs == nil ? nil : entry
            }
            local.keyTiming = overrides.isEmpty ? nil : overrides
        }
    }

    private func addDevice() {
        guard let vendor = UInt16(vendorID), let product = UInt16(productID),
              locationID.isEmpty || UInt32(locationID) != nil else {
            formError = "Enter valid decimal vendor, product, and optional location IDs."; return
        }
        let device = KeyboardCustomizationDTO.Device(id: profileID,
            identity: .init(builtIn: builtIn, vendorID: vendor, productID: product,
                            serialNumber: serialNumber.isEmpty ? nil : serialNumber,
                            locationID: UInt32(locationID), transport: nil))
        do { try KeyboardCustomizationDTO(devices: [device]).validate() }
        catch { formError = String(describing: error); return }
        edit { settings in settings.devices = (settings.devices ?? []) + [device] }
        addingDevice = false; formError = nil
    }
}
