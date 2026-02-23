import Foundation

enum ArpResolver {

    /// Read the entire ARP table and return a {ipv4: mac} mapping.
    static func getARPTable() async -> [String: String] {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            process.arguments = ["-a", "-n"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = Pipe()

            process.terminationHandler = { _ in
                let data   = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: parseARPTable(output))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: [:])
            }
        }
    }

    /// Look up the MAC address for a specific IP (sends an ARP request if not cached).
    static func getMACAddress(for ip: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            process.arguments = ["-n", ip]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = Pipe()

            process.terminationHandler = { _ in
                let data   = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                // "? (192.168.0.1) at d0:11:e5:1c:e5:8f on en0 ..."
                let mac = extractMAC(from: output)
                continuation.resume(returning: mac)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - Parsing

    private static func parseARPTable(_ output: String) -> [String: String] {
        var table: [String: String] = [:]
        for line in output.components(separatedBy: "\n") {
            guard let ip  = extractIP(from: line),
                  let mac = extractMAC(from: line) else { continue }
            table[ip] = mac
        }
        return table
    }

    /// Extract first IPv4 from a string like "? (192.168.0.1) at ..."
    private static func extractIP(from line: String) -> String? {
        guard let start = line.range(of: "("),
              let end   = line.range(of: ")"),
              start.upperBound < end.lowerBound else { return nil }
        let candidate = String(line[start.upperBound..<end.lowerBound])
        return NetworkUtils.ipToComponents(candidate) != nil ? candidate : nil
    }

    /// Extract MAC address from "... at aa:bb:cc:dd:ee:ff ..."
    private static func extractMAC(from line: String) -> String? {
        // Matches xx:xx:xx:xx:xx:xx patterns (1-2 hex chars per octet)
        let pattern = "[0-9a-fA-F]{1,2}:[0-9a-fA-F]{1,2}:[0-9a-fA-F]{1,2}:[0-9a-fA-F]{1,2}:[0-9a-fA-F]{1,2}:[0-9a-fA-F]{1,2}"
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        let raw = String(line[range]).lowercased()
        // Zero-pad single-char octets: "0:8:9b:f5:f8:c7" → "00:08:9b:f5:f8:c7"
        let mac = raw.split(separator: ":").map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
        // Reject incomplete/placeholder MACs
        guard mac != "ff:ff:ff:ff:ff:ff", !mac.hasPrefix("00:00:00:00") else { return nil }
        return mac
    }
}
