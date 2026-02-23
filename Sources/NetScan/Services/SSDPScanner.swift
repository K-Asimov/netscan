import Foundation

struct SSDPResult: Sendable {
    var vendor: String? = nil
    var identification: String? = nil
}

/// Performs an SSDP multicast M-SEARCH and maps discovered device IPs to
/// vendor/identification strings derived from the UPnP SERVER header.
enum SSDPScanner {

    /// Send one multicast M-SEARCH and collect responses for `timeout` seconds.
    /// Returns a dictionary of [IPv4 → SSDPResult].
    static func discover(timeout: TimeInterval = 2.0) async -> [String: SSDPResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: discoverSync(timeout: timeout))
            }
        }
    }

    // MARK: - Synchronous UDP implementation

    private static func discoverSync(timeout: TimeInterval) -> [String: SSDPResult] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            print("[SSDP] socket() failed errno=\(errno)")
            return [:]
        }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind to ephemeral port on all interfaces
        var local = sockaddr_in()
        local.sin_family      = sa_family_t(AF_INET)
        local.sin_port        = 0
        local.sin_addr.s_addr = INADDR_ANY
        let bindRet = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindRet != 0 { print("[SSDP] bind() failed errno=\(errno)") }

        // Destination: SSDP multicast address
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port   = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)

        // Send M-SEARCH — repeat twice 500 ms apart for reliability
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n"
        sendMSearch(sock: sock, msg: msg, dest: &dest)

        // Set 1-second receive timeout so the loop can re-check the deadline
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var results: [String: SSDPResult] = [:]
        let deadline    = Date().addingTimeInterval(timeout)
        var buf         = [UInt8](repeating: 0, count: 4096)
        var rxCount     = 0
        var sentSecond  = false

        while Date() < deadline {
            // Send a second M-SEARCH halfway through to catch late responders
            if !sentSecond && Date() > deadline.addingTimeInterval(-timeout / 2) {
                sendMSearch(sock: sock, msg: msg, dest: &dest)
                sentSecond = true
            }

            var from    = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let n = withUnsafeMutablePointer(to: &from) { fromPtr in
                fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                    recvfrom(sock, &buf, buf.count, 0, addrPtr, &fromLen)
                }
            }

            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                print("[SSDP] recvfrom error errno=\(errno)")
                break
            }
            guard n > 0 else { break }

            rxCount += 1
            var ipCStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = withUnsafePointer(to: from.sin_addr) {
                inet_ntop(AF_INET, $0, &ipCStr, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: ipCStr)
            let response = String(bytes: buf[0..<n], encoding: .utf8) ?? ""

            // Log raw response for diagnostics
            let serverLine = response.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("server:") } ?? "(no SERVER header)"
            print("[SSDP] \(ip) → \(serverLine)")

            if results[ip] == nil, let parsed = parse(response) {
                results[ip] = parsed
                print("[SSDP] identified \(ip): vendor=\(parsed.vendor ?? "-"), id=\(parsed.identification ?? "-")")
            }
        }

        print("[SSDP] done — received \(rxCount) packet(s), identified \(results.count) device(s)")
        return results
    }

    @discardableResult
    private static func sendMSearch(sock: Int32, msg: String, dest: inout sockaddr_in) -> Int {
        let sent = msg.withCString { cstr in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, cstr, strlen(cstr), 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            print("[SSDP] sendto() failed errno=\(errno)")
        } else {
            print("[SSDP] M-SEARCH sent (\(sent) bytes)")
        }
        return sent
    }

    // MARK: - Response parsing

    private static func parse(_ response: String) -> SSDPResult? {
        var headers: [String: String] = [:]
        for line in response.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key   = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }

        let server = headers["server"] ?? ""
        let srvLow = server.lowercased()
        let usn    = (headers["usn"] ?? "").lowercased()
        let st     = (headers["st"] ?? headers["nt"] ?? "").lowercased()
        let all    = "\(srvLow) \(usn) \(st)"

        var result = SSDPResult()

        if all.contains("qnap") {
            result.vendor         = "QNAP Systems"
            result.identification = server.isEmpty ? "QNAP NAS" : String(server.prefix(80))
        } else if all.contains("synology") || all.contains("diskstation") || all.contains("rackstation") {
            result.vendor         = "Synology Incorporated"
            result.identification = all.contains("rackstation") ? "Synology RackStation" : "Synology DiskStation"
        } else if all.contains("sonos") {
            result.vendor         = "Sonos"
            result.identification = "Sonos Speaker"
        } else if srvLow.contains("mikrotik") || srvLow.contains("routeros") {
            result.vendor         = "MikroTik"
            result.identification = "RouterOS"
        } else if all.contains("pfsense") {
            result.vendor         = "Netgate"
            result.identification = "pfSense Firewall"
        } else if all.contains("opnsense") {
            result.vendor         = "Deciso B.V."
            result.identification = "OPNsense Firewall"
        } else if all.contains("unifi") || all.contains("ubiquiti") {
            result.vendor         = "Ubiquiti Networks"
            result.identification = "UniFi Device"
        } else if srvLow.contains("philips hue") || all.contains("philips-hue") {
            result.vendor         = "Philips Lighting (Signify)"
            result.identification = "Philips Hue Bridge"
        } else if all.contains("fritz") {
            result.vendor         = "AVM"
            result.identification = "FRITZ!Box"
        } else if !server.isEmpty {
            result.identification = String(server.prefix(80))
        } else {
            return nil
        }

        return result
    }
}
