import Foundation
import Darwin

struct HttpBannerResult: Sendable {
    var vendor: String? = nil
    var identification: String? = nil
    var hostname: String? = nil
}

/// Identifies network devices by fetching their web administration pages.
enum HttpBannerScanner {

    // Ports + paths to probe — keep the list short to reduce noise from rejected connections
    private static let probeEndpoints: [(port: Int, scheme: String, paths: [String])] = [
        (80,   "http",  ["/"]),
        (8080, "http",  ["/", "/redirect.html"]), // QNAP default admin + redirect hint
        (5000, "http",  ["/"]),                   // Synology HTTP
        (443,  "https", ["/"]),
        (5001, "https", ["/"]),                   // Synology HTTPS
    ]

    /// Probe the host on common HTTP ports concurrently and return the best identification found.
    static func identify(host: String) async -> HttpBannerResult {
        await withTaskGroup(of: HttpBannerResult?.self) { group in
            for endpoint in probeEndpoints {
                group.addTask { await tryEndpoint(host: host, endpoint: endpoint) }
            }
            var best: HttpBannerResult? = nil
            for await result in group {
                guard let r = result else { continue }
                if r.vendor != nil || r.identification != nil {
                    if best == nil { best = r }
                }
            }
            return best ?? HttpBannerResult()
        }
    }

    // MARK: - Port probe

    private static func tryEndpoint(
        host: String,
        endpoint: (port: Int, scheme: String, paths: [String])
    ) async -> HttpBannerResult? {
        // Use POSIX socket check to avoid noisy NWConnection debug logs.
        guard isTCPReachable(host: host, port: endpoint.port, timeout: 0.5) else { return nil }

        for path in endpoint.paths {
            if let result = await tryPath(host: host, port: endpoint.port, scheme: endpoint.scheme, path: path) {
                return result
            }
        }
        return nil
    }

    private static func tryPath(host: String, port: Int, scheme: String, path: String) async -> HttpBannerResult? {
        guard let url = URL(string: "\(scheme)://\(host):\(port)\(path)") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue("NetScan/1.0", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 1.5
        config.timeoutIntervalForResource = 3
        // LAN scanning should bypass system proxy/PAC to avoid
        // loopback(proxy) failures and noisy CFNetwork logs.
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config,
                                 delegate: InsecureURLDelegate(),
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode < 500 else { return nil }

            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let key = k as? String, let val = v as? String {
                    headers[key.lowercased()] = val
                }
            }
            let body = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
            return identifyFromContent(headers: headers, body: body, port: port)
        } catch {
            // Connection reset/lost is expected during LAN probing; ignore silently.
            return nil
        }
    }

    private static func isTCPReachable(host: String, port: Int, timeout: Double) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            return false
        }
        defer { freeaddrinfo(result) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { _ = close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        let connectResult = connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
        if connectResult == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pollDesc = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let timeoutMs = Int32(max(1, Int(timeout * 1000.0)))
        let polled = poll(&pollDesc, 1, timeoutMs)
        guard polled > 0 else { return false }

        var socketError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &len) == 0 else { return false }
        return socketError == 0
    }

    // MARK: - Identification

    private static func identifyFromContent(
        headers: [String: String],
        body: String,
        port: Int
    ) -> HttpBannerResult? {
        let lower  = body.lowercased()
        let title  = extractTitle(from: body) ?? ""
        let titLow = title.lowercased()
        let server = (headers["server"] ?? "").lowercased()
        let powered = (headers["x-powered-by"] ?? "").lowercased()

        // ── QNAP ──────────────────────────────────────────────────────────────
        if lower.contains("qnap") || titLow.contains("qnap") ||
           lower.contains("qts ") || lower.contains("qts.") || lower.contains("quts") ||
           lower.contains("nas management") || headers["x-qnap-serverid"] != nil {
            let id = titLow.isEmpty ? "QNAP NAS" :
                     "QNAP \(String(title.prefix(50)).trimmingCharacters(in: .whitespaces))"
            return HttpBannerResult(vendor: "QNAP Systems", identification: id)
        }

        // ── Synology ──────────────────────────────────────────────────────────
        if lower.contains("synology") || titLow.contains("diskstation") ||
           titLow.contains("rackstation") || powered.contains("synology") {
            let id = titLow.contains("rackstation") ? "Synology RackStation"
                   : titLow.contains("diskstation")  ? "Synology DiskStation"
                   : "Synology NAS"
            return HttpBannerResult(vendor: "Synology Incorporated", identification: id)
        }

        // ── pfSense / OPNsense ────────────────────────────────────────────────
        if lower.contains("pfsense") || titLow.contains("pfsense") {
            return HttpBannerResult(vendor: "Netgate", identification: "pfSense Firewall")
        }
        if lower.contains("opnsense") || titLow.contains("opnsense") {
            return HttpBannerResult(vendor: "Deciso B.V.", identification: "OPNsense Firewall")
        }

        // ── OpenWrt / DD-WRT ──────────────────────────────────────────────────
        if lower.contains("openwrt") || titLow.contains("luci") || titLow.contains("openwrt") {
            return HttpBannerResult(vendor: nil, identification: "OpenWrt Router")
        }
        if lower.contains("dd-wrt") || titLow.contains("dd-wrt") {
            return HttpBannerResult(vendor: nil, identification: "DD-WRT Router")
        }

        // ── Ubiquiti / UniFi ──────────────────────────────────────────────────
        if lower.contains("ubiquiti") || lower.contains("unifi") || titLow.contains("unifi") {
            return HttpBannerResult(vendor: "Ubiquiti Networks", identification: "UniFi Controller")
        }
        if server.contains("ubnt") {
            return HttpBannerResult(vendor: "Ubiquiti Networks", identification: "Ubiquiti Device")
        }

        // ── MikroTik ──────────────────────────────────────────────────────────
        if lower.contains("mikrotik") || titLow.contains("routeros") || titLow.contains("mikrotik") {
            return HttpBannerResult(vendor: "MikroTik", identification: "RouterOS")
        }

        // ── Proxmox ───────────────────────────────────────────────────────────
        if lower.contains("proxmox") || titLow.contains("proxmox") {
            return HttpBannerResult(vendor: "Proxmox Server Solutions",
                                    identification: "Proxmox VE")
        }

        // ── ASUS Router ───────────────────────────────────────────────────────
        if lower.contains("asuswrt") || lower.contains("asus router") ||
           titLow.contains("asuswrt") {
            return HttpBannerResult(vendor: "ASUSTek Computer", identification: "ASUS Router")
        }

        // ── TP-Link ───────────────────────────────────────────────────────────
        if lower.contains("tp-link") || titLow.contains("tplinkwifi") ||
           lower.contains("tplink") {
            return HttpBannerResult(vendor: "TP-Link Technologies", identification: "TP-Link Device")
        }

        // ── HP / JetDirect printers ───────────────────────────────────────────
        if server.contains("jetdirect") || lower.contains("hp laserjet") ||
           lower.contains("hewlett-packard") {
            return HttpBannerResult(vendor: "HP Inc.", identification: "HP Printer")
        }

        // ── Canon / Epson / Brother printers ─────────────────────────────────
        if lower.contains("canon") && (lower.contains("printer") || lower.contains("laser")) {
            return HttpBannerResult(vendor: "Canon", identification: "Canon Printer")
        }
        if lower.contains("epson") && lower.contains("printer") {
            return HttpBannerResult(vendor: "Seiko Epson", identification: "Epson Printer")
        }
        if lower.contains("brother") && lower.contains("printer") {
            return HttpBannerResult(vendor: "Brother Industries", identification: "Brother Printer")
        }

        // ── Raspberry Pi / Pi-hole ────────────────────────────────────────────
        if lower.contains("pi-hole") || titLow.contains("pi-hole") {
            return HttpBannerResult(vendor: "Raspberry Pi Foundation", identification: "Pi-hole")
        }
        if lower.contains("raspberry pi") || lower.contains("raspbian") {
            return HttpBannerResult(vendor: "Raspberry Pi Foundation",
                                    identification: "Raspberry Pi")
        }

        // ── FritzBox ──────────────────────────────────────────────────────────
        if lower.contains("fritzbox") || lower.contains("fritz!box") ||
           lower.contains("avm gmbh") {
            return HttpBannerResult(vendor: "AVM", identification: "FRITZ!Box")
        }

        // ── Generic — use title if informative ────────────────────────────────
        let boringTitles: Set<String> = [
            "opening...", "loading...", "please wait", "redirect", "untitled",
            "index", "home", "login", "admin", "welcome", "default",
        ]
        if !title.isEmpty && title.count > 3 && title.count < 80 {
            let tl = title.lowercased()
            if !boringTitles.contains(tl) && !tl.hasSuffix("...") {
                return HttpBannerResult(vendor: nil, identification: title)
            }
        }

        return nil
    }

    // MARK: - HTML helpers

    private static func extractTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<title[^>]*>([^<]{1,200})</title>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.range(at: 1).location != NSNotFound else { return nil }
        let title = ns.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

}

// MARK: - SSL bypass delegate

private final class InsecureURLDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
