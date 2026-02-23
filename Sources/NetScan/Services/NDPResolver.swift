import Foundation

/// Reads the IPv6 Neighbor Discovery Protocol (NDP) table via `ndp -an`
/// and returns a mapping of MAC address → [IPv6 addresses].
enum NDPResolver {

    static func getNDPTable() async -> [String: [String]] {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ndp")
            process.arguments = ["-a", "-n"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = Pipe()

            process.terminationHandler = { _ in
                let data   = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: parseNDPTable(output))
            }
            do { try process.run() } catch {
                continuation.resume(returning: [:])
            }
        }
    }

    // MARK: - Parsing

    // Example ndp output:
    // Neighbor                                Linklayer Address  Netif Expire    St Flgs
    // fe80::3268:93ff:fe20:fef0%en0           30:68:93:20:fe:f0  en0   permanent S  R
    private static func parseNDPTable(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }

            let rawIPv6 = parts[0]
            let mac     = parts[1].lowercased()

            // Skip header row and invalid entries
            guard rawIPv6.contains(":"), !rawIPv6.hasPrefix("N"), mac.contains(":"), mac.count >= 11 else { continue }

            // Strip interface suffix: "fe80::1%en0" → "fe80::1"
            let ipv6 = rawIPv6.components(separatedBy: "%").first ?? rawIPv6

            var list = result[mac] ?? []
            if !list.contains(ipv6) { list.append(ipv6) }
            result[mac] = list
        }
        return result
    }

    /// Returns true if the IPv6 is link-local (fe80::)
    static func isLinkLocal(_ ipv6: String) -> Bool {
        ipv6.lowercased().hasPrefix("fe80:")
    }

    /// Returns true if the IPv6 is a global unicast address
    static func isGlobal(_ ipv6: String) -> Bool {
        let lower = ipv6.lowercased()
        return lower.hasPrefix("2") || lower.hasPrefix("3")
    }
}
