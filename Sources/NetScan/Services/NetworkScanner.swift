import Foundation

private struct Callbacks: @unchecked Sendable {
    let discovered: @MainActor (NetworkDevice) -> Void
    let updated:    @MainActor (NetworkDevice) -> Void
    let progress:   @MainActor (Int, Int) -> Void
    let completed:  @MainActor () -> Void
}

/// Orchestrates the full LAN scan: ping sweep → ARP → NDP → vendor → device type.
actor NetworkScanner {

    static let shared = NetworkScanner()
    private var scanTask: Task<Void, Never>?

    // MARK: - Public API

    func startScan(
        fromIP: String,
        toIP: String,
        scanPorts: Bool,
        onDeviceDiscovered: @escaping @MainActor (NetworkDevice) -> Void,
        onDeviceUpdated: @escaping @MainActor (NetworkDevice) -> Void,
        onProgress: @escaping @MainActor (Int, Int) -> Void,
        onCompleted: @escaping @MainActor () -> Void
    ) {
        scanTask?.cancel()
        let cb = Callbacks(
            discovered: onDeviceDiscovered,
            updated: onDeviceUpdated,
            progress: onProgress,
            completed: onCompleted
        )
        scanTask = Task {
            await performScan(fromIP: fromIP, toIP: toIP, scanPorts: scanPorts, cb: cb)
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Scan

    private func performScan(fromIP: String, toIP: String, scanPorts: Bool, cb: Callbacks) async {
        let ips = NetworkUtils.generateIPRange(from: fromIP, to: toIP)
        guard !ips.isEmpty else { await MainActor.run { cb.completed() }; return }
        let total = ips.count

        // Start metadata discovery in parallel, but do not block initial IP list.
        async let arpFuture  = ArpResolver.getARPTable()
        async let ndpFuture  = NDPResolver.getNDPTable()
        async let ssdpFuture = SSDPScanner.discover(timeout: 2.0)
        async let bonjourFuture = BonjourScanner.discoverAppleSignals(timeout: 4.0)

        // Phase 1: Ping sweep in batches (show list immediately)
        let batchSize = 50
        var done = 0
        var discoveredByIP: [String: NetworkDevice] = [:]

        for batchStart in stride(from: 0, to: ips.count, by: batchSize) {
            guard !Task.isCancelled else { break }
            let batch = Array(ips[batchStart..<min(batchStart + batchSize, ips.count)])

            await withTaskGroup(of: NetworkDevice?.self) { group in
                for ip in batch {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let result = await PingScanner.ping(host: ip)
                        guard result.alive else { return nil }
                        var device = NetworkDevice(ipv4Address: ip)
                        device.pingStatus = .alive
                        device.rtt = result.rtt
                        device.ttl = result.ttl
                        return device
                    }
                }

                for await discoveredOpt in group {
                    done += 1
                    let c = done
                    if let discovered = discoveredOpt {
                        discoveredByIP[discovered.ipv4Address] = discovered
                        await MainActor.run {
                            cb.discovered(discovered)
                            cb.progress(c, total)
                        }
                    } else {
                        await MainActor.run { cb.progress(c, total) }
                    }
                }
            }
        }

        // Phase 2: Apply metadata and update rows incrementally.
        let (arpEarly, ndpEarly, ssdpTable, bonjourTable) = await (arpFuture, ndpFuture, ssdpFuture, bonjourFuture)
        // Refresh ARP/NDP after ping sweep; early snapshots are often stale.
        async let arpLateFuture = ArpResolver.getARPTable()
        async let ndpLateFuture = NDPResolver.getNDPTable()
        let (arpLate, ndpLate) = await (arpLateFuture, ndpLateFuture)
        var arpTable = arpEarly
        for (ip, mac) in arpLate { arpTable[ip] = mac }
        var ndpTable = ndpEarly
        for (mac, addrs) in ndpLate {
            let existing = Set(ndpTable[mac] ?? [])
            ndpTable[mac] = Array(existing.union(addrs)).sorted()
        }

        print("[Scan] Phase2 meta — ARP:\(arpTable.count) NDP:\(ndpTable.count) SSDP:\(ssdpTable.count) Bonjour:\(bonjourTable.count)")
        if !bonjourTable.isEmpty {
            for (ip, r) in bonjourTable.sorted(by: { $0.key < $1.key }) {
                print("[Scan]   Bonjour \(ip) → services:\(r.services) names:\(r.names) models:\(r.modelIdentifiers) products:\(r.productNames)")
            }
        }
        if arpTable.isEmpty {
            print("[Scan]   ⚠️ ARP table is empty — failed to obtain MAC addresses.")
        }

        let allIPs = Set(discoveredByIP.keys)
            .union(ssdpTable.keys)
            .union(bonjourTable.keys)
            .sorted { NetworkUtils.compareIPs($0, $1) }

        print("[Scan] Phase2 target IPs: \(allIPs.count) (ping:\(discoveredByIP.count) ssdp:\(ssdpTable.count) bonjour:\(bonjourTable.count))")

        for ip in allIPs {
            guard !Task.isCancelled else { break }
            let old = discoveredByIP[ip]
            var device = old ?? NetworkDevice(ipv4Address: ip)
            if old == nil {
                device.pingStatus = .unknown
            }

            if device.macAddress == nil {
                device.macAddress = arpTable[ip]
            }
            // Per-host ARP lookup improves vendor mapping for recently pinged hosts.
            // Skip for IPs outside the scan's /24 prefix: those are on a remote subnet
            // and `arp -n <remote-ip>` always returns "no entry" (Layer-2 boundary).
            let scanPrefix  = fromIP.split(separator: ".").prefix(3).joined(separator: ".")
            let devicePrefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
            if device.macAddress == nil, old?.pingStatus == .alive, devicePrefix == scanPrefix {
                device.macAddress = await ArpResolver.getMACAddress(for: ip)
            }

            if let bonjour = bonjourTable[ip] {
                print("[Scan] \(ip) ← Bonjour applied: services=\(bonjour.services) names=\(bonjour.names) models=\(bonjour.modelIdentifiers) products=\(bonjour.productNames)")
                if !bonjour.services.isEmpty { device.mdnsServices = bonjour.services }
                if let first = bonjour.names.first, !first.isEmpty { device.mdnsName = first }
                if let model = bonjour.modelIdentifiers.first, !model.isEmpty {
                    device.appleModelIdentifier = model
                }
                if let product = bonjour.productNames.first, !product.isEmpty {
                    device.productName = product
                    if device.identification == nil {
                        if let model = device.appleModelIdentifier, !model.isEmpty {
                            device.identification = "\(product) (\(model))"
                        } else {
                            device.identification = product
                        }
                    }
                }
            } else {
                print("[Scan] \(ip) — no Bonjour data (ping:\(old?.pingStatus == .alive ? "alive" : "miss"))")
            }

            if device.vendor == nil {
                device.vendor = MACVendorResolver.vendor(for: device.macAddress)
            }

            if let mac = device.macAddress, let addrs = ndpTable[mac] {
                device.ipv6Local = addrs.first(where: NDPResolver.isLinkLocal)
                device.ipv6Global = addrs.first(where: NDPResolver.isGlobal)
            }

            if let ssdp = ssdpTable[ip] {
                if device.vendor == nil { device.vendor = ssdp.vendor }
                if device.identification == nil { device.identification = ssdp.identification }
            }

            device.deviceType = DeviceTypeDetector.detect(device)
            if device.vendor == nil {
                device.vendor = device.deviceType.inferredVendor
            }

            print("[Scan] \(ip) → type:\(device.deviceType) vendor:\(device.vendor ?? "-") mac:\(device.macAddress ?? "-") mdnsName:\(device.mdnsName ?? "-") model:\(device.appleModelIdentifier ?? "-")")
            discoveredByIP[ip] = device

            await MainActor.run {
                if old == nil {
                    print("[Scan] \(ip) → cb.discovered (new)")
                    cb.discovered(device)
                } else if old != device {
                    print("[Scan] \(ip) → cb.updated (changed)")
                    cb.updated(device)
                } else {
                    print("[Scan] \(ip) → no changes, skipping UI update")
                }
            }
        }

        await MainActor.run { cb.completed() }
    }
}
