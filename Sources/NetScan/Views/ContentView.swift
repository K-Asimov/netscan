import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: ScanViewModel
    @State private var showPreferences = false
    @State private var showRangeScan   = false
    @State private var deviceToEdit: NetworkDevice? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Main split view
            HSplitView {
                DeviceTableView(viewModel: viewModel)
                    .frame(minWidth: 480)

                if viewModel.showDetailPanel {
                    DeviceDetailView(viewModel: viewModel,
                                     onEditDevice: { deviceToEdit = viewModel.selectedDevice },
                                     onStartPortScan: { viewModel.startPortScanForSelectedDevice() },
                                     onConfigurePortScan: { showPreferences = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Scan progress bar
            if viewModel.isScanning {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color(NSColor.separatorColor))
                            .frame(height: 2)
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * viewModel.scanProgress, height: 2)
                            .animation(.easeInOut(duration: 0.15), value: viewModel.scanProgress)
                    }
                }
                .frame(height: 2)
            }

            // Status bar
            HStack(spacing: 0) {
                Text(viewModel.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                Spacer()
                if !viewModel.devices.isEmpty {
                    Text("Devices seen: \(viewModel.devices.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 10)
                }
            }
            .frame(height: 22)
            .background(Material.bar)
        }
        .toolbar { toolbarContent }
        .navigationTitle(scanTitle)
        .sheet(isPresented: $showPreferences) {
            PreferencesView(viewModel: viewModel)
        }
        .sheet(isPresented: $showRangeScan) {
            RangeScanSheet(viewModel: viewModel)
        }
        .sheet(item: $deviceToEdit) { device in
            EditDeviceSheet(
                device: device,
                onSave: { name, vendor, ident, type in
                    viewModel.setCustomInfo(name: name, vendor: vendor,
                                            identification: ident, deviceType: type,
                                            for: device.id)
                },
                onClear: { viewModel.clearCustomInfo(for: device.id) }
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // Scan / Stop
            Button {
                if viewModel.isScanning { viewModel.stopScan() }
                else { viewModel.startScan() }
            } label: {
                Label(
                    viewModel.isScanning ? "Stop" : "Start Scan",
                    systemImage: viewModel.isScanning ? "stop.fill" : "play.fill"
                )
            }
            .tint(viewModel.isScanning ? .red : .accentColor)
            .help(viewModel.isScanning ? "Stop scan" : "Start network scan (⌘R)")

            // Edit device info
            Button { deviceToEdit = viewModel.selectedDevice } label: {
                Label("Edit Device", systemImage: "pencil.circle")
            }
            .disabled(viewModel.selectedDevice == nil)
            .help("Edit device name, vendor, and type")

            // Clear
            Button { viewModel.clearResults() } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(viewModel.devices.isEmpty || viewModel.isScanning)
            .help("Clear all scan results")

            // Config
            Button { showPreferences = true } label: {
                Label("Config", systemImage: "gearshape")
            }
            .help("Configure interface and scan range")

            Divider()

            // Expand: discover & ping the upstream router, append to current list
            Button { viewModel.expandToUpstreamRouter() } label: {
                Label(
                    viewModel.isDiscoveringUpstream ? "Discovering…" : "Expand",
                    systemImage: "wifi.router"
                )
            }
            .disabled(viewModel.isScanning || viewModel.isDiscoveringUpstream)
            .help("Discover the upstream router and add it to the device list")

            // Range: open the range-scan sheet
            Button { showRangeScan = true } label: {
                Label("Range…", systemImage: "scope")
            }
            .disabled(viewModel.isScanning)
            .help("Scan a custom IP range")
        }

        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $viewModel.showDetailPanel) {
                Label("Details", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .help("Toggle detail panel")
        }
    }

    private var scanTitle: String {
        viewModel.fromIP.isEmpty ? "NetScan"
            : "Scan  \(viewModel.fromIP) → \(viewModel.toIP)"
    }
}

// MARK: - Edit Device Sheet

struct EditDeviceSheet: View {
    let device: NetworkDevice
    let onSave: (String?, String?, String?, DeviceType?) -> Void
    let onClear: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var vendor: String
    @State private var identification: String
    @State private var selectedType: DeviceType?

    init(device: NetworkDevice,
         onSave: @escaping (String?, String?, String?, DeviceType?) -> Void,
         onClear: @escaping () -> Void) {
        self.device = device
        self.onSave = onSave
        self.onClear = onClear
        _name           = State(initialValue: device.customName ?? "")
        _vendor         = State(initialValue: device.customVendor ?? "")
        _identification = State(initialValue: device.customIdentification ?? "")
        _selectedType   = State(initialValue: device.customDeviceType)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: device.effectiveDeviceType.sfSymbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Device Info")
                        .font(.headline)
                    Text(device.ipv4Address)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            // Fields
            VStack(spacing: 10) {
                fieldRow(label: "Name",
                         placeholder: device.hostname ?? device.ipv4Address,
                         text: $name)
                fieldRow(label: "Vendor",
                         placeholder: device.vendor ?? "Unknown",
                         text: $vendor)
                fieldRow(label: "Description",
                         placeholder: device.identification ?? "—",
                         text: $identification)

                HStack(alignment: .center, spacing: 12) {
                    Text("Type")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                    Picker("", selection: $selectedType) {
                        Text("Auto-detect").tag(nil as DeviceType?)
                        Divider()
                        ForEach(DeviceType.allCases, id: \.self) { type in
                            Label(type.label, systemImage: type.sfSymbol)
                                .tag(type as DeviceType?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // Buttons
            HStack {
                Button("Clear All") { onClear(); dismiss() }
                    .foregroundStyle(.red)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save") {
                    onSave(
                        name.isEmpty ? nil : name,
                        vendor.isEmpty ? nil : vendor,
                        identification.isEmpty ? nil : identification,
                        selectedType
                    )
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 400)
    }

    private func fieldRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Range Scan Sheet

struct RangeScanSheet: View {
    @ObservedObject var viewModel: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var from = ""
    @State private var to   = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "scope")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Range Scan")
                        .font(.headline)
                    Text("Scan a custom IP range")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            Divider()

            VStack(spacing: 12) {
                ipRow(label: "From", text: $from)
                ipRow(label: "To",   text: $to)

                // Upstream hint row — shown only after an expand was performed
                if !viewModel.upstreamSubnetFrom.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Upstream: \(viewModel.upstreamSubnetFrom) → \(viewModel.upstreamSubnetTo)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use") {
                            from = viewModel.upstreamSubnetFrom
                            to   = viewModel.upstreamSubnetTo
                        }
                        .controlSize(.mini)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Scan") {
                    viewModel.startRangeScan(from: from, to: to)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(from.isEmpty || to.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 360)
        .onAppear {
            // Pre-fill: upstream subnet if known, otherwise current scan range
            if !viewModel.upstreamSubnetFrom.isEmpty {
                from = viewModel.upstreamSubnetFrom
                to   = viewModel.upstreamSubnetTo
            } else {
                from = viewModel.fromIP
                to   = viewModel.toIP
            }
        }
    }

    private func ipRow(label: String, text: Binding<String>) -> some View {
        HStack {
            Text("\(label):")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            TextField("e.g. 192.168.1.1", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
