import SwiftUI

struct DeviceDetailView: View {
    @ObservedObject var viewModel: ScanViewModel
    var onEditDevice: () -> Void
    var onStartPortScan: () -> Void = {}
    var onConfigurePortScan: () -> Void = {}

    var body: some View {
        if let device = viewModel.selectedDevice {
            ScrollView {
                VStack(spacing: 0) {
                    DeviceHeaderCard(
                        device: device,
                        onStartPortScan: onStartPortScan,
                        onConfigurePortScan: onConfigurePortScan,
                        onEdit: onEditDevice
                    )
                    Divider()
                    DetailSection(title: "NETWORK") {
                        if let rtt = device.rttFormatted {
                            InfoRow(icon: "bolt.fill", label: "RTT", value: rtt, valueColor: rttColor(device.rtt))
                        }
                        InfoRow(icon: "network", label: "IPv4 Address", value: device.ipv4Address)
                        InfoRow(icon: "network", label: "IPv6 Addresses", value: ipv6Addresses(device))
                        InfoRow(icon: "antenna.radiowaves.left.and.right", label: "MAC Address",
                                value: device.macAddress)
                        if let ttl = device.ttl {
                            InfoRow(icon: "timelapse", label: "TTL", value: "\(ttl)")
                        }
                        if let os = device.osHint {
                            InfoRow(icon: "cpu", label: "OS Hint", value: os)
                        }
                    }
                    Divider()
                    DetailSection(title: "IDENTITY") {
                        let name = device.displayHostname
                        InfoRow(icon: "tag", label: "Hostname",
                                value: name.isEmpty ? nil : name,
                                isCustom: device.customName != nil)
                        InfoRow(icon: "building", label: "Vendor",
                                value: device.displayVendor,
                                isCustom: device.customVendor != nil)
                        InfoRow(icon: "info.circle", label: "Identification",
                                value: device.displayIdentification,
                                isCustom: device.customIdentification != nil)
                        InfoRow(icon: "questionmark.circle", label: "DNS Name", value: device.dnsName)
                        InfoRow(icon: "dot.radiowaves.right", label: "mDNS Name", value: device.mdnsName)
                        InfoRow(icon: "folder.badge.person.crop", label: "SMB Name", value: device.smbName)
                        InfoRow(icon: "pc", label: "NetBIOS Name", value: device.netbiosName)
                        InfoRow(icon: "building.2", label: "SMB Domain", value: device.smbDomain)
                        InfoRow(icon: "lock.open", label: "Port Scan",
                                value: device.openPorts.isEmpty ? nil : device.formattedOpenPorts)
                    }
                    if !device.mdnsServices.isEmpty {
                        Divider()
                        DetailSection(title: "SERVICES") {
                            if !device.mdnsServices.isEmpty {
                                InfoRow(icon: "dot.radiowaves.right", label: "mDNS Services",
                                        value: device.mdnsServices.joined(separator: ", "))
                            }
                        }
                    }
                    Divider()
                    DetailSection(title: "NOTES") {
                        CommentRow(viewModel: viewModel, deviceID: device.id, comments: device.comments)
                    }
                    Spacer(minLength: 16)
                }
            }
            .frame(minWidth: 240, maxWidth: 300)
            .background(Color(NSColor.windowBackgroundColor))
        } else {
            // Empty state
            VStack(spacing: 12) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(.quaternary)
                Text("No Selection")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Select a device to view details")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minWidth: 240, maxWidth: 300)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    private func rttColor(_ rtt: Double?) -> Color? {
        guard let rtt else { return nil }
        switch rtt {
        case ..<5:   return .green
        case ..<30:  return Color(red: 0.4, green: 0.8, blue: 0.2)
        case ..<100: return .yellow
        default:     return .orange
        }
    }

    private func ipv6Addresses(_ device: NetworkDevice) -> String? {
        let addresses = [device.ipv6Local, device.ipv6Global].compactMap { $0 }.filter { !$0.isEmpty }
        guard !addresses.isEmpty else { return nil }
        return addresses.joined(separator: ", ")
    }
}

// MARK: - Device Header Card

struct DeviceHeaderCard: View {
    let device: NetworkDevice
    let onStartPortScan: () -> Void
    let onConfigurePortScan: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(iconBg)
                    .frame(width: 52, height: 52)
                Image(systemName: device.effectiveDeviceType.sfSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconFg)
                    .font(.system(size: 24, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(device.ipv4Address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(device.pingStatus == .alive ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(device.effectiveDeviceType.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            Menu {
                Button("Start Port Scan", action: onStartPortScan)
                Button("Configure Port Scan", action: onConfigurePortScan)
            } label: {
                HStack(spacing: 6) {
                    Text("Port Scan")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.borderlessButton)

            // Edit button
            Button(action: onEdit) {
                Image(systemName: "pencil.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit device info")
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var iconBg: Color {
        switch device.effectiveDeviceType {
        case .mac, .macBook, .iphone, .ipad, .appleTV, .homePod: return .blue.opacity(0.15)
        case .windows: return Color(red: 0.0, green: 0.47, blue: 0.84).opacity(0.15)
        case .linux:   return .orange.opacity(0.15)
        case .router:  return .purple.opacity(0.15)
        case .nas:     return .teal.opacity(0.15)
        case .printer: return .indigo.opacity(0.15)
        case .smartTV: return .red.opacity(0.15)
        case .iot:     return .green.opacity(0.15)
        case .unknown: return Color(NSColor.controlColor)
        }
    }

    private var iconFg: Color {
        switch device.effectiveDeviceType {
        case .mac, .macBook, .iphone, .ipad, .appleTV, .homePod: return .blue
        case .windows: return Color(red: 0.0, green: 0.47, blue: 0.84)
        case .linux:   return .orange
        case .router:  return .purple
        case .nas:     return .teal
        case .printer: return .indigo
        case .smartTV: return .red
        case .iot:     return .green
        case .unknown: return .secondary
        }
    }
}

// MARK: - Detail Section

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            content
                .padding(.bottom, 6)
        }
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String?
    var valueColor: Color? = nil
    var isCustom: Bool = false

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .frame(width: 16, alignment: .center)

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            if let val = value, !val.isEmpty {
                Text(val)
                    .font(.system(size: 11))
                    .foregroundStyle(valueColor ?? .primary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isCustom {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor.opacity(0.6))
                }

                if hovered {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(val, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                }
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .onHover { hovered = $0 }
    }
}

// MARK: - Comment Row

struct CommentRow: View {
    @ObservedObject var viewModel: ScanViewModel
    let deviceID: String
    let comments: String?

    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if editing {
                TextEditor(text: $text)
                    .font(.system(size: 11))
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1))
                    .padding(.horizontal, 14)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        editing = false
                        text = comments ?? ""
                    }
                    .controlSize(.small)
                    Button("Save") {
                        viewModel.setComments(text, for: deviceID)
                        editing = false
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 14)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                        .frame(width: 16)
                    Text("Comments")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    if let c = comments, !c.isEmpty {
                        Text(c)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Add a note…")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(action: { text = comments ?? ""; editing = true }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 3)
            }
        }
        .onChange(of: deviceID) { _, _ in
            editing = false
            text = comments ?? ""
        }
    }
}
