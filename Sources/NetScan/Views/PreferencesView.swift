import SwiftUI

struct PreferencesView: View {
    @ObservedObject var viewModel: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var localFromIP: String = ""
    @State private var localToIP: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Main content
            HStack(alignment: .top, spacing: 24) {
                // Left: Interface selector
                VStack(alignment: .leading, spacing: 16) {
                    headerSection(title: "Selected Interface", icon: "network")

                    VStack(alignment: .leading, spacing: 12) {
                        Picker("", selection: $viewModel.selectedInterface) {
                            ForEach(viewModel.interfaces) { iface in
                                Text(iface.id).tag(Optional(iface))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: viewModel.selectedInterface) { _, _ in
                            viewModel.updateIPRange()
                            localFromIP = viewModel.fromIP
                            localToIP   = viewModel.toIP
                        }

                        if let iface = viewModel.selectedInterface {
                            interfaceDetails(iface)
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.05), lineWidth: 1))

                    Spacer()
                }
                .frame(minWidth: 280)

                // Right: Subrange configuration
                VStack(alignment: .leading, spacing: 16) {
                    headerSection(title: "Configure Subrange", icon: "scope")

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 10) {
                            ipFieldRow(label: "From:", text: $localFromIP)
                            ipFieldRow(label: "To:", text: $localToIP)
                        }

                        HStack {
                            Spacer()
                            Button("Reset") {
                                viewModel.updateIPRange()
                                localFromIP = viewModel.fromIP
                                localToIP   = viewModel.toIP
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Save") {
                                viewModel.fromIP = localFromIP
                                viewModel.toIP   = localToIP
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Divider().padding(.vertical, 4)

                        Toggle(isOn: $viewModel.scanPortsEnabled) {
                            Text("Scan common TCP ports")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .toggleStyle(.checkbox)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.05), lineWidth: 1))

                    Spacer()
                }
                .frame(minWidth: 280)
            }
            .padding(24)

            Divider()

            // Bottom buttons
            HStack(spacing: 12) {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                .controlSize(.large)

                Button("Start Scan") {
                    viewModel.fromIP = localFromIP
                    viewModel.toIP   = localToIP
                    dismiss()
                    viewModel.startScan()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        }
        .frame(width: 640, height: 380)
        .onAppear {
            localFromIP = viewModel.fromIP
            localToIP   = viewModel.toIP
        }
    }

    // MARK: - Components

    private func headerSection(title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
        }
        .padding(.leading, 4)
    }

    private func interfaceDetails(_ iface: NetworkInterface) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            detailRow(label: "Name", value: iface.displayName)
            detailRow(label: "MAC", value: iface.macAddress ?? "—")
            detailRow(label: "IP / Mask", value: "\(iface.ipAddress ?? "—")\n\(iface.subnetMask ?? "—")")
            detailRow(label: "Gateway", value: iface.gateway ?? "—")
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.top, 4)
    }

    private func detailRow(label: String, value: String) -> some View {
        GridRow(alignment: .top) {
            Text("\(label) :")
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ipFieldRow(label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }
}
