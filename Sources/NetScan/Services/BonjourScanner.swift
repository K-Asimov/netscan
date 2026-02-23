import Foundation
import Darwin

struct BonjourSignalResult: Sendable {
    var services: [String] = []
    var names: [String] = []
    var modelIdentifiers: [String] = []
    var productNames: [String] = []
}

/// Discovers Apple-relevant Bonjour/mDNS services and maps them by IPv4.
///
/// Runs NetServiceBrowser on a dedicated Thread (not a GCD pool thread) so that
/// the thread's RunLoop is properly configured and stays alive for the full
/// discovery window.  A keepalive Timer prevents the RunLoop from exiting early
/// due to having no input sources registered.
enum BonjourScanner {

    private static let appleSignalTypes = [
        "_apple-mobdev2._tcp.",    // iPhone / iPad
        "_companion-link._tcp.",   // AirDrop / Handoff (nearly all Apple devices)
        "_airplay._tcp.",          // Apple TV / AirPlay receivers
        "_raop._tcp.",             // AirPlay audio
        "_adisk._tcp.",            // AFP disk sharing (Mac)
        "_smb._tcp.",              // SMB (Mac)
        "_afpovertcp._tcp.",       // AFP (Mac)
        "_device-info._tcp.",      // Generic Apple device info
        "_workstation._tcp.",      // macOS Workgroup
        "_sleep-proxy._udp.",      // Apple Sleep Proxy
        "_homekit._tcp.",          // HomeKit accessories
        "_hap._tcp.",              // HomeKit Accessory Protocol
    ]

    /// Discover Apple-relevant Bonjour services and return a [IPv4 → result] map.
    static func discoverAppleSignals(timeout: TimeInterval = 4.0) async -> [String: BonjourSignalResult] {
        await withCheckedContinuation { continuation in
            // BonjourCollector retains itself via the Thread closure until completion.
            let collector = BonjourCollector()
            collector.start(serviceTypes: appleSignalTypes, timeout: timeout) { netServiceResult in
                let cliResult = DNSSDCollector.collect(
                    preferredServiceTypes: appleSignalTypes,
                    timeout: max(1.0, min(2.0, timeout / 2))
                )
                continuation.resume(returning: merge(base: netServiceResult, overlay: cliResult))
            }
        }
    }

    private static func merge(
        base: [String: BonjourSignalResult],
        overlay: [String: BonjourSignalResult]
    ) -> [String: BonjourSignalResult] {
        var merged = base
        for (ip, rhs) in overlay {
            if var lhs = merged[ip] {
                lhs.services = Array(Set(lhs.services).union(rhs.services)).sorted()
                lhs.names = Array(Set(lhs.names).union(rhs.names)).sorted()
                lhs.modelIdentifiers = Array(Set(lhs.modelIdentifiers).union(rhs.modelIdentifiers)).sorted()
                lhs.productNames = Array(Set(lhs.productNames).union(rhs.productNames)).sorted()
                merged[ip] = lhs
            } else {
                merged[ip] = rhs
            }
        }
        return merged
    }
}

// MARK: - BonjourCollector

private final class BonjourCollector: NSObject {

    private var browsers:  [NetServiceBrowser] = []
    private var resolvers: [String: NetServiceResolver] = [:]
    private var ipToTypes: [String: Set<String>] = [:]
    private var ipToNames: [String: Set<String>] = [:]
    private var ipToModelIdentifiers: [String: Set<String>] = [:]
    private var ipToProductNames: [String: Set<String>] = [:]
    private let lock = NSLock()

    /// Start discovery on a dedicated Thread and call `completion` when done.
    func start(serviceTypes: [String], timeout: TimeInterval,
               completion: @escaping ([String: BonjourSignalResult]) -> Void) {

        let thread = Thread { [self] in          // strong capture keeps collector alive
            // A keepalive Timer prevents RunLoop.run(until:) from returning
            // immediately when there are no input sources yet.
            let keepAlive = Timer.scheduledTimer(withTimeInterval: timeout + 1,
                                                 repeats: false) { _ in }
            for type in serviceTypes {
                let browser = NetServiceBrowser()
                browser.delegate = self
                browsers.append(browser)
                browser.searchForServices(ofType: type, inDomain: "local.")
            }

            // Run the RunLoop for the full discovery window.
            RunLoop.current.run(until: Date().addingTimeInterval(timeout))
            keepAlive.invalidate()

            // Stop browsers on the same thread that started them.
            for b in browsers { b.stop() }
            browsers.removeAll()

            // Snapshot results before stopping resolvers.
            lock.lock()
            let snapshot = buildResult()
            for r in resolvers.values { r.stop() }
            resolvers.removeAll()
            lock.unlock()

            completion(snapshot)
        }
        thread.qualityOfService = .utility
        thread.name = "BonjourCollector"
        thread.start()
    }

    // MARK: - Private helpers

    private func buildResult() -> [String: BonjourSignalResult] {
        var out: [String: BonjourSignalResult] = [:]
        let allIPs = Set(ipToTypes.keys).union(ipToNames.keys)
        for ip in allIPs {
            out[ip] = BonjourSignalResult(
                services: Array(ipToTypes[ip] ?? []).sorted(),
                names:    Array(ipToNames[ip] ?? []).sorted(),
                modelIdentifiers: Array(ipToModelIdentifiers[ip] ?? []).sorted(),
                productNames: Array(ipToProductNames[ip] ?? []).sorted()
            )
        }
        return out
    }

    fileprivate func insert(ip: String, type: String, name: String, modelIdentifier: String?) {
        lock.lock()
        defer { lock.unlock() }

        var types = ipToTypes[ip] ?? []
        types.insert(type)
        ipToTypes[ip] = types

        let normalized = normalizeName(name)
        if !normalized.isEmpty {
            var names = ipToNames[ip] ?? []
            names.insert(normalized)
            ipToNames[ip] = names
        }

        if let modelIdentifier {
            let cleanModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanModel.isEmpty {
                var models = ipToModelIdentifiers[ip] ?? []
                models.insert(cleanModel)
                ipToModelIdentifiers[ip] = models

                let product = AppleModelMapper.productName(for: cleanModel)
                if !product.isEmpty {
                    var products = ipToProductNames[ip] ?? []
                    products.insert(product)
                    ipToProductNames[ip] = products
                }
            }
        }
    }

    private static let macBracketPattern = try? NSRegularExpression(
        pattern: #"\s*\[[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}\]\s*$"#
    )

    private func normalizeName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip "MAC@" or "user@" prefix that some services include.
        if let at = s.firstIndex(of: "@") {
            s = String(s[s.index(after: at)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip trailing " [XX:XX:XX:XX:XX:XX]" MAC suffix (workstation service names).
        if let re = Self.macBracketPattern {
            let ns = s as NSString
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length),
                                            withTemplate: "").trimmingCharacters(in: .whitespaces)
        }

        // Reject IPv6-like strings (contain "::") or raw MAC-only strings.
        if s.contains("::") { return "" }
        if s.range(of: #"^[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil { return "" }

        return s
    }
}

// MARK: - NetServiceBrowserDelegate

extension BonjourCollector: NetServiceBrowserDelegate {

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        print("[Bonjour] discovered: \(service.name) | \(service.type.trimmingCharacters(in: .init(charactersIn: ".")))")
        let key = "\(service.type)|\(service.name)|\(service.domain)"
        lock.lock()
        guard resolvers[key] == nil else { lock.unlock(); return }
        let resolver = NetServiceResolver(service: service) { [weak self] ip, svcType, svcName, modelIdentifier in
            self?.insert(ip: ip, type: svcType, name: svcName, modelIdentifier: modelIdentifier)
        }
        resolvers[key] = resolver
        lock.unlock()

        // start() must be called on the RunLoop thread (we're already on it here).
        resolver.start()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        if Self.isPolicyDenied(errorDict) {
            return
        }
        print("[Bonjour] browse failed: \(errorDict)")
    }

    private static func isPolicyDenied(_ errorDict: [String: NSNumber]) -> Bool {
        let domain = errorDict["NSNetServicesErrorDomain"]?.intValue
        let code = errorDict["NSNetServicesErrorCode"]?.intValue
        // NSNetServicesErrorDomain(10) + -72008 == kDNSServiceErr_PolicyDenied
        return domain == 10 && code == -72008
    }
}

// MARK: - NetServiceResolver

private final class NetServiceResolver: NSObject, NetServiceDelegate {

    let service: NetService
    private let onResolved: (String, String, String, String?) -> Void

    init(service: NetService, onResolved: @escaping (String, String, String, String?) -> Void) {
        self.service = service
        self.onResolved = onResolved
        super.init()
    }

    /// Must be called on the thread whose RunLoop should receive delegate callbacks.
    func start() {
        service.delegate = self
        service.resolve(withTimeout: 3.0)   // generous timeout; RunLoop is alive for 4 s
    }

    func stop() {
        service.stop()
    }

    // MARK: NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else {
            print("[Bonjour] no addresses: \(sender.name)")
            return
        }
        let type = sender.type.lowercased()
        let name = sender.name
        let modelIdentifier = extractModelIdentifier(from: sender)
        var resolved = false
        for addrData in addresses {
            if let ip = extractIPv4(from: addrData) {
                print("[Bonjour] resolved: \(name) → \(ip) | svc=\(type) model=\(modelIdentifier ?? "-")")
                onResolved(ip, type, name, modelIdentifier)
                resolved = true
            }
        }
        if !resolved {
            print("[Bonjour] no IPv4: \(name) (no IPv4 among \(addresses.count) addresses)")
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("[Bonjour] resolve failed: \(sender.name) | \(sender.type) — \(errorDict)")
    }

    // MARK: - IPv4 extraction

    private func extractIPv4(from data: Data) -> String? {
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return nil }
            let sa = base.assumingMemoryBound(to: sockaddr.self)
            guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var cstr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &cstr, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: cstr)
        }
    }

    private func extractModelIdentifier(from service: NetService) -> String? {
        guard let txtData = service.txtRecordData(),
              !txtData.isEmpty else { return nil }
        let dict = NetService.dictionary(fromTXTRecord: txtData)
        let keys = ["model", "modelid", "model-id", "machine", "product"]
        for key in keys {
            if let data = dict[key], let value = String(data: data, encoding: .utf8) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

private enum AppleModelMapper {
    static func productName(for identifier: String) -> String {
        let id = identifier.lowercased()
        if id.hasPrefix("macmini") { return "Mac mini" }
        if id.hasPrefix("macbookpro") { return "MacBook Pro" }
        if id.hasPrefix("macbookair") { return "MacBook Air" }
        if id.hasPrefix("macbook") { return "MacBook" }
        if id.hasPrefix("imac") { return "iMac" }
        if id.hasPrefix("macpro") { return "Mac Pro" }
        if id.hasPrefix("macstudio") { return "Mac Studio" }
        if id.hasPrefix("iphone") { return "iPhone" }
        if id.hasPrefix("ipad") { return "iPad" }
        if id.hasPrefix("appletv") { return "Apple TV" }
        if id.hasPrefix("audioaccessory") { return "HomePod" }
        // New Apple Silicon Macs use "Mac<N>,<N>" (e.g. Mac16,11 = Mac mini M4 Pro).
        if id.hasPrefix("mac") { return "Mac" }
        return identifier
    }
}

// MARK: - dns-sd fallback

private enum DNSSDCollector {
    private static let dnsSDPath = "/usr/bin/dns-sd"

    /// Browse Apple service types via dns-sd CLI (bypasses mDNS policy restrictions on NetServiceBrowser).
    /// All service type browses run in parallel, then all instance lookups run in parallel.
    static func collect(
        preferredServiceTypes: [String],
        timeout: TimeInterval
    ) -> [String: BonjourSignalResult] {
        // Each dns-sd command gets a short timeout; results arrive in milliseconds.
        let cmdTimeout: TimeInterval = min(1.5, timeout)
        print("[DNS-SD] collect start (cmdTimeout=\(cmdTimeout), types=\(preferredServiceTypes.count))")

        // Phase 1: Browse all service types in parallel.
        let lock = NSLock()
        var pending: [(type: String, instance: String)] = []

        DispatchQueue.concurrentPerform(iterations: preferredServiceTypes.count) { i in
            let svcType = preferredServiceTypes[i]
            let out = runDNSCommand(args: ["-B", svcType, "local."], timeout: cmdTimeout)
            let found = parseInstances(fromBrowseOutput: out)
            if !found.isEmpty {
                print("[DNS-SD] \(svcType) → \(found.count) found: \(found)")
            }
            lock.lock()
            for inst in found { pending.append((type: svcType, instance: inst)) }
            lock.unlock()
        }

        // Phase 2: Resolve all instances in parallel.
        var byIP: [String: BonjourSignalResult] = [:]
        DispatchQueue.concurrentPerform(iterations: pending.count) { i in
            let (svcType, instance) = pending[i]
            let out = runDNSCommand(args: ["-L", instance, svcType, "local."], timeout: cmdTimeout)
            guard let fullHost = parseResolvedHost(out),
                  let ip = resolveIPv4(hostname: fullHost) else {
                print("[DNS-SD]   \(instance) → parse failed")
                return
            }
            let model = parseModelIdentifier(out)
            // Normalize the instance name; fall back to the mDNS hostname if the raw name is not usable.
            let displayName: String? = normalizeInstanceName(instance)
                ?? hostnameWithoutDomain(fullHost)
            print("[DNS-SD]   \(instance) → \(ip) name=\(displayName ?? "-") model=\(model ?? "-")")
            lock.lock()
            var sig = byIP[ip] ?? BonjourSignalResult()
            sig.services = Array(Set(sig.services).union([svcType])).sorted()
            if let displayName, !displayName.isEmpty {
                sig.names = Array(Set(sig.names).union([displayName])).sorted()
            }
            if let model, !model.isEmpty {
                sig.modelIdentifiers = Array(Set(sig.modelIdentifiers).union([model])).sorted()
                let product = AppleModelMapper.productName(for: model)
                if !product.isEmpty {
                    sig.productNames = Array(Set(sig.productNames).union([product])).sorted()
                }
            }
            byIP[ip] = sig
            lock.unlock()
        }

        print("[DNS-SD] collect done → \(byIP.count) devices")
        return byIP
    }

    // MARK: - Process helper

    private static func runDNSCommand(args: [String], timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dnsSDPath)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Name helpers

    private static let macBracketRegex = try? NSRegularExpression(
        pattern: #"\s*\[[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}\]\s*$"#
    )

    /// Normalize a raw Bonjour instance name to a human-readable label.
    /// Returns nil when the name is not usable (raw MAC, IPv6-like, etc.).
    private static func normalizeInstanceName(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip "MAC@" or "@prefix" (e.g. "34:ee:16@fe80::...").
        if let at = s.firstIndex(of: "@") {
            s = String(s[s.index(after: at)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip trailing " [XX:XX:XX:XX:XX:XX]" MAC bracket (workstation service names).
        if let re = macBracketRegex {
            let ns = s as NSString
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length),
                                            withTemplate: "").trimmingCharacters(in: .whitespaces)
        }
        // Reject IPv6-like strings (contain "::") or bare 12-char hex MACs.
        if s.contains("::") { return nil }
        if s.range(of: #"^[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil { return nil }
        return s.isEmpty ? nil : s
    }

    /// Strip ".local." suffix from a resolved hostname, returning just the label part.
    private static func hostnameWithoutDomain(_ fullHost: String) -> String? {
        var s = fullHost
        if s.hasSuffix(".local.") { s = String(s.dropLast(".local.".count)) }
        return s.isEmpty ? nil : s
    }

    // MARK: - Parsers

    /// Parse `dns-sd -B <type> local.` output.
    /// Line format: "timestamp  Add  flags  if  domain  serviceType  instanceParts..."
    /// e.g.: "14:46:24  Add  3  1  local.  _companion-link._tcp.  Asimov  M4  MacMini"
    private static func parseInstances(fromBrowseOutput output: String) -> [String] {
        var names: Set<String> = []
        for line in output.split(separator: "\n").map(String.init) where line.contains(" Add ") {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            // Minimum: timestamp A/R flags if domain serviceType instance(1+)
            guard tokens.count >= 7 else { continue }
            // Instance name = tokens[6..] joined with a space
            let instance = tokens[6...].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !instance.isEmpty { names.insert(instance) }
        }
        return Array(names).sorted()
    }

    /// Extract "hostname.local.:" from `dns-sd -L` output.
    private static func parseResolvedHost(_ output: String) -> String? {
        let pattern = "([A-Za-z0-9\\-\\.]+\\.local\\.):[0-9]+"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output,
                                           range: NSRange(location: 0, length: output.utf16.count)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }

    private static func resolveIPv4(hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        defer { if result != nil { freeaddrinfo(result) } }
        guard getaddrinfo(hostname, nil, &hints, &result) == 0 else { return nil }
        // Iterate the entire linked list; prefer the first non-loopback address.
        // When the app runs on the scanned host itself, macOS returns 127.0.0.1 first.
        var ptr = result
        var loopback: String? = nil
        while let current = ptr {
            defer { ptr = current.pointee.ai_next }
            var addr = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }.sin_addr
            var cstr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &cstr, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: cstr)
            if !ip.hasPrefix("127.") { return ip }
            loopback = ip
        }
        return loopback
    }

    /// Extract "model=XXX" TXT record from `dns-sd -L` output.
    private static func parseModelIdentifier(_ output: String) -> String? {
        for pattern in [#"model=([A-Za-z0-9,._-]+)"#,
                        #"modelid=([A-Za-z0-9,._-]+)"#,
                        #"model-id=([A-Za-z0-9,._-]+)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: output,
                                              range: NSRange(location: 0, length: output.utf16.count)),
                  let range = Range(match.range(at: 1), in: output) else { continue }
            let v = String(output[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return nil
    }
}
