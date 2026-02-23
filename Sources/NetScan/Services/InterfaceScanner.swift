import Foundation
import Darwin

enum InterfaceScanner {

    static func getInterfaces() -> [NetworkInterface] {
        var interfaces: [NetworkInterface] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(first) }

        // Collect IPv4 info per interface name
        var ipv4Map: [String: (ip: String, mask: String)] = [:]
        var ptr = first
        while true {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            if let addr = ifa.ifa_addr {
                if addr.pointee.sa_family == UInt8(AF_INET) {
                    if let ip   = ipFromSockaddr(addr),
                       let mask = ipFromSockaddr(ifa.ifa_netmask) {
                        ipv4Map[name] = (ip, mask)
                    }
                }
            }
            if let next = ifa.ifa_next {
                ptr = next
            } else {
                break
            }
        }

        // Collect MAC addresses via ioctl / sysctl (parse `ifconfig` output for simplicity)
        let ifconfigOutput = runCommand("/sbin/ifconfig", arguments: ["-a"]) ?? ""
        let macMap = parseMACAddresses(from: ifconfigOutput)
        let friendlyNames = parseFriendlyNames(from: ifconfigOutput)

        // Build unique interface list (only those with IPv4)
        for (name, info) in ipv4Map {
            // Skip loopback
            guard !name.hasPrefix("lo") else { continue }

            let gateway = getDefaultGateway(for: name)
            let displayName = friendlyNames[name] ?? name

            interfaces.append(NetworkInterface(
                id: name,
                displayName: displayName,
                macAddress: macMap[name],
                ipAddress: info.ip,
                subnetMask: info.mask,
                gateway: gateway
            ))
        }

        return interfaces.sorted { $0.id < $1.id }
    }

    // MARK: - Private helpers

    private static func ipFromSockaddr(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var sa = sin.pointee.sin_addr
            guard inet_ntop(AF_INET, &sa, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
    }

    private static func parseMACAddresses(from output: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentInterface: String?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Interface line: "en0: flags=..."
            if let colonRange = line.range(of: ": "), !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                currentInterface = String(line[line.startIndex..<colonRange.lowerBound])
            }
            // MAC: "ether d0:11:e5:1c:e5:8f"
            if trimmed.hasPrefix("ether "), let iface = currentInterface {
                let mac = trimmed.replacingOccurrences(of: "ether ", with: "").trimmingCharacters(in: .whitespaces)
                result[iface] = mac
            }
        }
        return result
    }

    private static func parseFriendlyNames(from output: String) -> [String: String] {
        // Try to extract "media:" or use known mappings
        var result: [String: String] = [:]
        for line in output.components(separatedBy: "\n") {
            if !line.hasPrefix("\t") && !line.hasPrefix(" "),
               let colonRange = line.range(of: ": ") {
                let name = String(line[line.startIndex..<colonRange.lowerBound])
                result[name] = friendlyName(for: name)
            }
        }
        return result
    }

    static func friendlyName(for interfaceName: String) -> String {
        switch true {
        case interfaceName.hasPrefix("en"):
            let num = interfaceName.dropFirst(2)
            return num == "0" ? "Ethernet / Wi-Fi" : "Ethernet \(num)"
        case interfaceName.hasPrefix("utun"):
            return "VPN (utun\(interfaceName.dropFirst(4)))"
        case interfaceName.hasPrefix("bridge"):
            return "Bridge"
        case interfaceName.hasPrefix("lo"):
            return "Loopback"
        default:
            return interfaceName
        }
    }

    private static func getDefaultGateway(for interfaceName: String) -> String? {
        guard let output = runCommand("/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"]) else { return nil }
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 4, parts[0] == "default" || parts[0] == "0/0" {
                if parts.last == interfaceName || (parts.count > 3 && parts[3] == interfaceName) {
                    return parts[1]
                }
            }
        }
        // Fallback: first default gateway
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 2, parts[0] == "default" {
                return parts[1]
            }
        }
        return nil
    }

    static func runCommand(_ path: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
