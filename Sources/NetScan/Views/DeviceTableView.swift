import SwiftUI

struct DeviceTableView: View {
    @ObservedObject var viewModel: ScanViewModel
    @State private var sortOrder = [KeyPathComparator(\NetworkDevice.ipv4Address)]

    var body: some View {
        Table(
            viewModel.filteredDevices,
            selection: $viewModel.selectedDeviceID,
            sortOrder: $sortOrder
        ) {
            // Device type icon
            TableColumn("") { device in
                DeviceIcon(type: device.effectiveDeviceType)
            }
            .width(28)

            // IPv4
            TableColumn("IPv4 Address", value: \.ipv4Address) { device in
                Text(device.ipv4Address)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .width(min: 110, ideal: 125)

            // Hostname
            TableColumn("Hostname", value: \.displayHostname) { device in
                VStack(alignment: .leading, spacing: 1) {
                    let name = device.displayHostname
                    if name.isEmpty {
                        Text("—").foregroundStyle(.tertiary)
                    } else {
                        Text(name)
                            .lineLimit(1)
                        if let mdns = device.mdnsName, mdns != name {
                            Text(mdns)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .width(min: 100, ideal: 170)

            // MAC address
            TableColumn("MAC Address") { device in
                Text(device.macAddress ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(device.macAddress == nil ? .tertiary : .primary)
            }
            .width(min: 130, ideal: 148)

            // Vendor
            TableColumn("Vendor") { device in
                Text(device.displayVendor ?? "—")
                    .lineLimit(1)
                    .foregroundStyle(device.displayVendor == nil ? .tertiary : .primary)
            }
            .width(min: 80, ideal: 155)

            // RTT + Ping
            TableColumn("RTT") { device in
                RTTCell(device: device)
            }
            .width(60)

            // OS hint
            TableColumn("OS") { device in
                if let os = device.osHint {
                    Text(os)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 80, ideal: 120)
        }
        .onChange(of: sortOrder) { _, newOrder in
            let sorted = viewModel.devices.sorted(using: newOrder)
            viewModel.devices = sorted
        }
        .alternatingRowBackgrounds()
    }
}

// MARK: - Device Icon

struct DeviceIcon: View {
    let type: DeviceType

    var body: some View {
        Image(systemName: type.sfSymbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 20, height: 20)
    }

    private var iconColor: Color {
        switch type {
        case .mac, .macBook, .iphone, .ipad, .appleTV, .homePod:
            return .blue
        case .windows: return Color(red: 0.0, green: 0.47, blue: 0.84)
        case .linux:   return .orange
        case .router:  return .purple
        case .nas:     return .teal
        case .printer: return .indigo
        case .smartTV: return Color(red: 0.9, green: 0.2, blue: 0.2)
        case .iot:     return .green
        case .unknown: return .secondary
        }
    }
}

// MARK: - RTT Cell

struct RTTCell: View {
    let device: NetworkDevice

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(pingColor)
                .frame(width: 7, height: 7)
            if let rtt = device.rttFormatted {
                Text(rtt)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(pingColor)
            }
        }
    }

    private var pingColor: Color {
        guard device.pingStatus == .alive, let rtt = device.rtt else {
            return device.pingStatus == .scanning ? .yellow : .secondary
        }
        switch rtt {
        case ..<5:   return .green
        case ..<30:  return Color(red: 0.4, green: 0.8, blue: 0.2)
        case ..<100: return .yellow
        default:     return .orange
        }
    }
}
