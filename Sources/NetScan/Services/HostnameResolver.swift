import Foundation
import Darwin

enum HostnameResolver {

    /// Reverse-DNS lookup for an IPv4 address string.
    static func resolveHostname(for ipAddress: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var addr = in_addr()
                guard inet_pton(AF_INET, ipAddress, &addr) == 1 else {
                    continuation.resume(returning: nil)
                    return
                }

                var sa = sockaddr_in()
                sa.sin_family = sa_family_t(AF_INET)
                sa.sin_addr   = addr
                sa.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)

                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result: Int32 = withUnsafePointer(to: sa) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saddrPtr in
                        getnameinfo(saddrPtr,
                                    socklen_t(MemoryLayout<sockaddr_in>.size),
                                    &hostBuf, socklen_t(NI_MAXHOST),
                                    nil, 0,
                                    NI_NAMEREQD)
                    }
                }

                if result == 0 {
                    let hostname = String(cString: hostBuf)
                    // Don't return if getnameinfo returned the IP itself
                    if hostname != ipAddress {
                        continuation.resume(returning: hostname)
                        return
                    }
                }
                continuation.resume(returning: nil)
            }
        }
    }

    /// mDNS / Bonjour name: look for <hostname>.local
    static func resolveMDNSName(for hostname: String) async -> String? {
        let candidate = hostname.hasSuffix(".local") ? hostname : "\(hostname).local"
        // Try to forward-resolve the .local name as a basic reachability check
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family   = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let ret = getaddrinfo(candidate, nil, &hints, &result)
                if result != nil { freeaddrinfo(result) }
                continuation.resume(returning: ret == 0 ? candidate : nil)
            }
        }
    }
}
