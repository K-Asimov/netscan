import Foundation

enum DeviceTypeDetector {

    /// Infer the device type from all available information about the device.
    static func detect(_ device: NetworkDevice) -> DeviceType {
        let vendor   = device.vendor?.lowercased() ?? ""
        let hostname = device.displayHostname.lowercased()
        let services = device.mdnsServices.map { $0.lowercased() }
        let ports    = device.openPorts
        let ttl      = device.ttl ?? 64
        let ident    = device.identification?.lowercased() ?? ""
        let appleModel = device.appleModelIdentifier?.lowercased() ?? ""
        let productName = device.productName?.lowercased() ?? ""
        let appleNameHint = hostname.contains("iphone")
            || hostname.contains("ipad")
            || hostname.contains("macbook")
            || hostname.contains("imac")
            || hostname.contains("mac mini") || hostname.contains("macmini")
            || hostname.contains("mac pro")  || hostname.contains("mac studio")
            || hostname.contains("apple tv") || hostname.contains("appletv")
            || hostname.contains("homepod")
            || productName.contains("iphone")
            || productName.contains("ipad")
            || productName.contains("mac")
            || productName.contains("apple tv")
            || productName.contains("homepod")
        // _apple-mobdev2: iOS-only (iPhone/iPad USB companion service)
        let hasAppleMobileService = services.contains { $0.contains("apple-mobdev2") }
        // _companion-link: ALL Apple devices (Mac, iPhone, iPad) — not mobile-specific
        let hasAppleCompanionLink  = services.contains { $0.contains("companion-link") }
        // _airplay / _raop: Apple TV, HomePod, AND Macs (AirPlay receiver)
        let hasAppleMediaService   = services.contains { $0.contains("airplay") || $0.contains("raop") }
        // Mac-specific file sharing services
        let hasAppleFileService    = services.contains {
            $0.contains("adisk") || $0.contains("afpovertcp") || $0.contains("workstation")
        }
        let hasAppleHomeService    = services.contains { $0.contains("homekit") || $0.contains("_hap._tcp") || $0.contains("sleep-proxy") }

        // ── Identification string overrides ───────────────────────────────────
        // These come from HTTP banner scanning and are quite reliable
        if ident.contains("qnap") || ident.contains("diskstation") ||
           ident.contains("rackstation") || ident.contains("synology nas") { return .nas }
        if ident.contains("pfsense") || ident.contains("opnsense") ||
           ident.contains("openwrt") || ident.contains("dd-wrt") ||
           ident.contains("routeros") || ident.contains("fritz!box") { return .router }
        if ident.contains("printer") { return .printer }
        if ident.contains("pi-hole") || ident.contains("proxmox") ||
           ident.contains("raspberry pi") { return .linux }

        // ── Apple family ──────────────────────────────────────────────────────
        // Prevent NAS/router devices that advertise _workstation._tcp or _smb
        // from being falsely classified as Apple.
        let isKnownNonApple = ["synology", "qnap", "western digital", " wd ", "netgear",
                               "tp-link", "ubiquiti", "cisco", "buffalo", "drobo"]
            .contains(where: { vendor.contains($0) })
        let isApple = !isKnownNonApple && (hasAppleMobileService || hasAppleCompanionLink
            || hasAppleMediaService || hasAppleFileService || hasAppleHomeService
            || vendor.contains("apple") || appleNameHint || !appleModel.isEmpty)
        if isApple {
            if appleModel.hasPrefix("macmini") || appleModel.hasPrefix("imac")
                || appleModel.hasPrefix("macpro") || appleModel.hasPrefix("macstudio") {
                return .mac
            }
            if appleModel.hasPrefix("macbook") {
                return .macBook
            }
            if appleModel.hasPrefix("iphone") {
                return .iphone
            }
            if appleModel.hasPrefix("ipad") {
                return .ipad
            }
            if appleModel.hasPrefix("appletv") {
                return .appleTV
            }
            if appleModel.hasPrefix("audioaccessory") {
                return .homePod
            }
            // New Apple Silicon Macs: "mac<gen>,<variant>" e.g. mac16,11 = Mac mini M4 Pro
            if appleModel.hasPrefix("mac") { return .mac }
            // 1. _apple-mobdev2 is iOS-exclusive → iPhone or iPad
            if hasAppleMobileService {
                if hostname.contains("ipad") { return .ipad }
                return .iphone
            }
            // 2. Mac-specific services (file sharing, workstation announce)
            if hasAppleFileService {
                return hostname.contains("macbook") ? .macBook : .mac
            }
            // 3. Explicit Mac hostname keywords
            if hostname.contains("macbook") { return .macBook }
            if hostname.contains("imac") || hostname.contains("mac mini")
                || hostname.contains("macmini") || hostname.contains("mac pro")
                || hostname.contains("mac studio") { return .mac }
            // 4. iOS hostname keywords
            if hostname.contains("iphone") { return .iphone }
            if hostname.contains("ipad")   { return .ipad }
            // 5. HomePod / Apple TV via media services
            if hasAppleMediaService || hasAppleHomeService {
                if hostname.contains("homepod") { return .homePod }
                if hostname.contains("appletv") || hostname.contains("apple tv") { return .appleTV }
                // AirPlay port 7000 present → likely Apple TV
                if ports.contains(7000) || ports.contains(7100) { return .appleTV }
            }
            // 6. iOS port hints
            if ports.contains(62078) || ports.contains(62080) {
                return hostname.contains("ipad") ? .ipad : .iphone
            }
            // 7. companion-link alone (without mobile service) is common on Macs
            if hasAppleCompanionLink { return .mac }
            // 8. Fallback
            return .mac
        }

        // ── Network equipment ─────────────────────────────────────────────────
        let routerVendors = ["tp-link", "netgear", "d-link", "ubiquiti", "mikrotik",
                             "cisco", "fortinet", "aruba", "juniper", "huawei",
                             "zyxel", "opengear", "buffalo"]
        if routerVendors.contains(where: { vendor.contains($0) }) {
            return .router
        }

        // ── TTL fingerprint: Cisco IOS / HPE / Juniper default TTL = 255 ─────
        // After 1–5 hops the received value is still ≥ 250.
        if ttl >= 250 { return .router }

        // ── Gateway-IP heuristic ──────────────────────────────────────────────
        // In home and SMB networks the host at .1 or .254 of any subnet is
        // almost always a router or gateway.  Only fire when no MAC/service
        // signals are present (those would already have matched above).
        let lastOctet = device.ipv4Address.split(separator: ".").last
            .flatMap { Int(String($0)) }
        if let octet = lastOctet,
           (octet == 1 || octet == 254),
           vendor.isEmpty, services.isEmpty {
            return .router
        }

        // ── NAS ───────────────────────────────────────────────────────────────
        let nasVendors = ["synology", "qnap", "western digital", "wd", "buffalo",
                          "seagate", "drobo", "netapp", "freenas", "truenas"]
        if nasVendors.contains(where: { vendor.contains($0) }) { return .nas }
        if services.contains(where: { $0.contains("afpovertcp") || $0.contains("smb") }),
           !vendor.contains("apple") { return .nas }

        // ── Printer ───────────────────────────────────────────────────────────
        let printerVendors = ["hp inc", "hewlett", "canon", "epson", "brother",
                              "lexmark", "xerox", "ricoh", "kyocera", "konica"]
        if printerVendors.contains(where: { vendor.contains($0) }) { return .printer }
        if ports.contains(9100) { return .printer }
        if services.contains(where: { $0.contains("ipp") || $0.contains("_printer") }) { return .printer }

        // ── Smart TV / Streaming ──────────────────────────────────────────────
        let tvVendors = ["roku", "vizio", "hisense", "tcl", "lg electronics"]
        if tvVendors.contains(where: { vendor.contains($0) }) { return .smartTV }
        if vendor.contains("samsung") && (hostname.contains("tv") || ports.contains(8001)) { return .smartTV }
        if services.contains(where: { $0.contains("googlecast") || $0.contains("airplay") }) { return .smartTV }

        // ── Windows (TTL ≈ 128 + SMB) ─────────────────────────────────────────
        if ports.contains(445) || ports.contains(3389) {
            if ttl > 100 { return .windows }
            // Even with lower TTL, SMB strongly suggests Windows/Samba
            if !vendor.contains("synology") && !vendor.contains("qnap") { return .windows }
        }
        if ttl > 100 && ttl <= 128 { return .windows }

        // ── Linux / server ────────────────────────────────────────────────────
        if ttl <= 64 && ports.contains(22) { return .linux }
        if ports.contains(22) && ports.contains(80) { return .linux }

        // ── IoT ───────────────────────────────────────────────────────────────
        let iotVendors = ["amazon", "google", "philips", "sonos", "ecobee",
                          "nest", "ring", "wyze", "tuya", "shelly"]
        if iotVendors.contains(where: { vendor.contains($0) }) { return .iot }

        return .unknown
    }
}
