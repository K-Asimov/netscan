import Foundation

struct NetworkInterface: Identifiable, Equatable, Hashable {
    let id: String          // e.g. "en0"
    let displayName: String // e.g. "Ethernet"
    let macAddress: String?
    let ipAddress: String?
    let subnetMask: String?
    let gateway: String?
}
