import Foundation
import Network

enum PortScanner {

    static let commonPorts = [21, 22, 23, 25, 53, 80, 110, 143, 443, 445, 548, 3389, 5000, 8080, 8443, 9000]

    /// Scan a set of TCP ports on the given host. Returns the list of open ports.
    static func scan(host: String, ports: [Int] = commonPorts, timeoutSeconds: Double = 1.0) async -> [Int] {
        await withTaskGroup(of: Int?.self) { group in
            for port in ports {
                group.addTask {
                    await isPortOpen(host: host, port: port, timeout: timeoutSeconds) ? port : nil
                }
            }
            var open: [Int] = []
            for await result in group {
                if let port = result { open.append(port) }
            }
            return open.sorted()
        }
    }

    /// Returns true if the TCP port on the host is reachable within the timeout.
    static func isPortOpen(host: String, port: Int, timeout: Double = 1.0) async -> Bool {
        final class State: @unchecked Sendable {
            var resumed = false
        }
        let state = State()

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(port))!,
                using: .tcp
            )

            let queue = DispatchQueue(label: "portscan.\(host).\(port)")

            connection.stateUpdateHandler = { [state] connState in
                guard !state.resumed else { return }
                switch connState {
                case .ready:
                    state.resumed = true
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    state.resumed = true
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            // Hard timeout
            queue.asyncAfter(deadline: .now() + timeout) { [state] in
                guard !state.resumed else { return }
                state.resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }
}
