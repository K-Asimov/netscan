import Foundation

enum NetworkUtils {

    /// "192.168.0.1" → [192, 168, 0, 1]
    static func ipToComponents(_ ip: String) -> [Int]? {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return nil }
        return parts
    }

    /// [192, 168, 0, 1] → "192.168.0.1"
    static func componentsToIP(_ components: [Int]) -> String {
        components.map(String.init).joined(separator: ".")
    }

    /// Convert IP components to a single UInt32
    static func ipToUInt32(_ components: [Int]) -> UInt32 {
        UInt32(components[0]) << 24 |
        UInt32(components[1]) << 16 |
        UInt32(components[2]) << 8  |
        UInt32(components[3])
    }

    /// Convert UInt32 to IP string
    static func uint32ToIP(_ value: UInt32) -> String {
        let a = (value >> 24) & 0xFF
        let b = (value >> 16) & 0xFF
        let c = (value >> 8)  & 0xFF
        let d = value & 0xFF
        return "\(a).\(b).\(c).\(d)"
    }

    /// Given an IP and subnet mask, calculate the network range (first host to last host)
    static func calculateIPRange(ip: String, mask: String) -> (from: String, to: String)? {
        guard let ipC = ipToComponents(ip), let maskC = ipToComponents(mask) else { return nil }
        let ipInt   = ipToUInt32(ipC)
        let maskInt = ipToUInt32(maskC)
        let network = ipInt & maskInt
        let broadcast = network | (~maskInt)
        let from = uint32ToIP(network + 1)
        let to   = uint32ToIP(broadcast - 1)
        return (from, to)
    }

    /// Generate a list of all IP addresses between fromIP and toIP (inclusive), max 65534
    static func generateIPRange(from fromIP: String, to toIP: String) -> [String] {
        guard let fromC = ipToComponents(fromIP), let toC = ipToComponents(toIP) else { return [] }
        let fromInt = ipToUInt32(fromC)
        let toInt   = ipToUInt32(toC)
        guard fromInt <= toInt else { return [] }
        let count = min(Int(toInt - fromInt) + 1, 65534)
        return (0..<count).map { uint32ToIP(fromInt + UInt32($0)) }
    }

    /// Compare two IP address strings for sorting
    static func compareIPs(_ a: String, _ b: String) -> Bool {
        guard let aC = ipToComponents(a), let bC = ipToComponents(b) else { return a < b }
        for (x, y) in zip(aC, bC) {
            if x != y { return x < y }
        }
        return false
    }
}
