import Foundation

/// Discovers the first-hop router beyond the local gateway (the upstream router)
/// by running a short traceroute to a well-known external host.
///
/// Typical home topology:
///   Mac (192.168.0.x) → gateway (192.168.0.1) → upstream router (192.168.1.254) → Internet
enum UpstreamDiscovery {

    /// Returns the IP of the upstream router (second traceroute hop), or nil if unreachable.
    /// Runs traceroute in a background thread; safe to call from async context.
    static func findUpstreamRouter() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // -n: skip reverse DNS, -q 1: one probe per hop,
                // -m 3: stop after 3 hops, -w 3: 3 s per-hop timeout
                let out = runCommand(
                    "/usr/sbin/traceroute",
                    arguments: ["-n", "-q", "1", "-m", "3", "-w", "3", "1.1.1.1"]
                ) ?? ""
                print("[Upstream] traceroute output:\n\(out)")
                continuation.resume(returning: parseSecondHop(from: out))
            }
        }
    }

    /// Given any host IP, returns the .1–.254 range of its /24 subnet.
    /// e.g. "192.168.1.254" → (from: "192.168.1.1", to: "192.168.1.254")
    static func inferSubnetRange(from ip: String) -> (from: String, to: String)? {
        let parts = ip.split(separator: ".").map(String.init)
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
        return (from: "\(prefix).1", to: "\(prefix).254")
    }

    // MARK: - Private helpers

    /// Parses traceroute output to extract the IP on hop 2.
    /// Line format: " 2  192.168.1.254  4.321 ms"  or  " 2  * * *"
    private static func parseSecondHop(from output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("2 ") || t.hasPrefix("2\t") else { continue }
            let tokens = t.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 2, tokens[1] != "*" else { continue }
            if isValidIPv4(tokens[1]) { return tokens[1] }
        }
        return nil
    }

    private static func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".").map(String.init)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { $0 >= 0 && $0 <= 255 } ?? false }
    }

    private static func runCommand(_ path: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            return nil
        }
    }
}
