import Foundation

struct PingResult: Sendable {
    let alive: Bool
    let rtt: Double?    // milliseconds
    let ttl: Int?
}

enum PingScanner {

    static func ping(host: String, timeoutSeconds: Int = 1) async -> PingResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-c", "1", "-W", "\(timeoutSeconds * 1000)", "-t", "\(timeoutSeconds + 1)", host]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError  = Pipe()

            process.terminationHandler = { proc in
                let data   = outPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: PingResult(
                        alive: true,
                        rtt:   parseRTT(from: output),
                        ttl:   parseTTL(from: output)
                    ))
                } else {
                    continuation.resume(returning: PingResult(alive: false, rtt: nil, ttl: nil))
                }
            }
            do { try process.run() } catch {
                continuation.resume(returning: PingResult(alive: false, rtt: nil, ttl: nil))
            }
        }
    }

    // MARK: - Parsing

    /// "64 bytes from x.x.x.x: icmp_seq=0 ttl=64 time=1.234 ms"
    /// Also handles "time = 1.234" variant (space around =)
    private static func parseRTT(from output: String) -> Double? {
        let pattern = #"time\s*=\s*(\d+\.?\d*)"#
        for line in output.components(separatedBy: "\n") where line.contains("time") {
            guard let range = line.range(of: pattern, options: .regularExpression) else { continue }
            // Extract just the numeric part after the last '='
            let matched = String(line[range])
            if let numStr = matched.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) {
                return Double(numStr)
            }
        }
        return nil
    }

    private static func parseTTL(from output: String) -> Int? {
        for line in output.components(separatedBy: "\n") where line.lowercased().contains("ttl=") {
            if let range = line.range(of: #"[Tt][Tt][Ll]=(\d+)"#, options: .regularExpression) {
                let numStr = String(line[range]).components(separatedBy: "=").last ?? ""
                return Int(numStr)
            }
        }
        return nil
    }
}
