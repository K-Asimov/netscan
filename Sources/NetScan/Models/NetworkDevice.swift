import Foundation

// MARK: - DeviceType

enum DeviceType: String, Equatable, Hashable, Sendable, CaseIterable {
    case mac, macBook, iphone, ipad, appleTV, homePod
    case windows, linux
    case router, nas, printer, smartTV, iot, unknown

    var sfSymbol: String {
        switch self {
        case .mac:      return "desktopcomputer"
        case .macBook:  return "laptopcomputer"
        case .iphone:   return "iphone"
        case .ipad:     return "ipad"
        case .appleTV:  return "appletv"
        case .homePod:  return "homepod"
        case .windows:  return "pc"
        case .linux:    return "server.rack"
        case .router:   return "wifi.router.fill"
        case .nas:      return "externaldrive.connected.to.line.below"
        case .printer:  return "printer.fill"
        case .smartTV:  return "tv.fill"
        case .iot:      return "sensor.tag.radiowaves.forward.fill"
        case .unknown:  return "questionmark.circle"
        }
    }

    /// Vendor name that can be inferred purely from device type (no OUI needed).
    var inferredVendor: String? {
        switch self {
        case .mac, .macBook, .iphone, .ipad, .appleTV, .homePod: return "Apple Inc."
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .mac:      return "Mac"
        case .macBook:  return "MacBook"
        case .iphone:   return "iPhone"
        case .ipad:     return "iPad"
        case .appleTV:  return "Apple TV"
        case .homePod:  return "HomePod"
        case .windows:  return "Windows PC"
        case .linux:    return "Linux"
        case .router:   return "Router / Gateway"
        case .nas:      return "NAS"
        case .printer:  return "Printer"
        case .smartTV:  return "Smart TV"
        case .iot:      return "IoT Device"
        case .unknown:  return "Unknown"
        }
    }
}

// MARK: - NetworkDevice

struct NetworkDevice: Identifiable, Equatable, Hashable {
    var id: String { ipv4Address }

    var ipv4Address: String
    var ipv6Local: String?
    var ipv6Global: String?
    var macAddress: String?
    var hostname: String?
    var vendor: String?
    var identification: String?
    var dnsName: String?
    var mdnsName: String?
    var appleModelIdentifier: String?
    var productName: String?
    var smbName: String?
    var smbDomain: String?
    var netbiosName: String?
    var openPorts: [Int] = []
    var mdnsServices: [String] = []
    var pingStatus: PingStatus = .unknown
    var rtt: Double? = nil      // milliseconds
    var ttl: Int? = nil
    var deviceType: DeviceType = .unknown
    var customName: String?
    var customVendor: String?
    var customIdentification: String?
    var customDeviceType: DeviceType?
    var comments: String?
    var lastSeen: Date = Date()

    enum PingStatus: Equatable, Hashable {
        case unknown, alive, dead, scanning
    }

    // MARK: - Computed

    /// Device type respecting user override
    var effectiveDeviceType: DeviceType { customDeviceType ?? deviceType }

    var displayHostname: String {
        customName ?? netbiosName ?? hostname ?? mdnsName ?? dnsName ?? ""
    }

    var displayName: String {
        let h = displayHostname
        return h.isEmpty ? ipv4Address : h
    }

    /// Vendor string, user override takes priority over auto-detected value
    var displayVendor: String? {
        customVendor?.isEmpty == false ? customVendor : vendor
    }

    /// Identification string, user override takes priority
    var displayIdentification: String? {
        if customIdentification?.isEmpty == false { return customIdentification }
        if identification?.isEmpty == false { return identification }
        if let productName, !productName.isEmpty { return productName }
        return appleModelIdentifier
    }

    var formattedOpenPorts: String {
        openPorts.map { port in
            let name = wellKnownPortName(port)
            return name.isEmpty ? "\(port)" : "\(port) (\(name))"
        }.joined(separator: ", ")
    }

    var osHint: String? {
        guard let ttl else { return nil }
        switch ttl {
        case 1...64:   return "Linux / macOS / iOS"
        case 65...128: return "Windows"
        case 129...255: return "Network Equipment"
        default:       return nil
        }
    }

    var rttFormatted: String? {
        guard let rtt else { return nil }
        if rtt < 1.0 { return "<1 ms" }
        return String(format: "%.1f ms", rtt)
    }

    // MARK: - Port names

    private func wellKnownPortName(_ port: Int) -> String {
        switch port {
        case 21: return "FTP"
        case 22: return "SSH"
        case 23: return "Telnet"
        case 25: return "SMTP"
        case 53: return "DNS"
        case 80: return "HTTP"
        case 110: return "POP3"
        case 143: return "IMAP"
        case 443: return "HTTPS"
        case 445: return "SMB"
        case 548: return "AFP"
        case 3389: return "RDP"
        case 5000: return "UPnP"
        case 8080: return "HTTP-Alt"
        case 8443: return "HTTPS-Alt"
        case 9100: return "Print"
        default: return ""
        }
    }
}
