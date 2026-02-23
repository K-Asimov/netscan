import SwiftUI
import Combine

@MainActor
final class ScanViewModel: ObservableObject {

    // MARK: - Scan state
    @Published var devices: [NetworkDevice] = []
    @Published var isScanning = false
    @Published var scanProgress: Double = 0
    @Published var statusMessage = "Ready"

    // MARK: - Selection & search
    @Published var selectedDeviceID: String? = nil
    @Published var searchText = ""
    @Published var showDetailPanel = true

    // MARK: - Configuration
    @Published var interfaces: [NetworkInterface] = []
    @Published var selectedInterface: NetworkInterface? = nil
    @Published var fromIP = ""
    @Published var toIP = ""
    @Published var scanPortsEnabled = false
    private var enrichmentTasks: [String: Task<Void, Never>] = [:]
    private var manualPortScanTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Upstream network
    @Published var upstreamRouter: String? = nil
    @Published var upstreamSubnetFrom = ""
    @Published var upstreamSubnetTo = ""
    @Published var isDiscoveringUpstream = false

    // MARK: - Computed

    var filteredDevices: [NetworkDevice] {
        guard !searchText.isEmpty else { return devices }
        let q = searchText.lowercased()
        return devices.filter {
            $0.ipv4Address.contains(q)
            || $0.displayHostname.lowercased().contains(q)
            || ($0.macAddress?.lowercased().contains(q) ?? false)
            || ($0.vendor?.lowercased().contains(q) ?? false)
        }
    }

    var selectedDevice: NetworkDevice? {
        guard let id = selectedDeviceID else { return nil }
        return devices.first { $0.id == id }
    }

    // MARK: - Lifecycle

    init() { loadInterfaces() }

    // MARK: - Interfaces

    func loadInterfaces() {
        interfaces = InterfaceScanner.getInterfaces()
        if selectedInterface == nil {
            selectedInterface = interfaces.first { $0.ipAddress != nil }
        }
        updateIPRange()
    }

    func updateIPRange() {
        guard let iface = selectedInterface,
              let ip   = iface.ipAddress,
              let mask = iface.subnetMask,
              let range = NetworkUtils.calculateIPRange(ip: ip, mask: mask)
        else { return }
        fromIP = range.from
        toIP   = range.to
    }

    // MARK: - Scanning

    func startScan() {
        guard !isScanning else { return }
        cancelEnrichmentTasks()
        isScanning = true
        scanProgress = 0
        devices = []
        selectedDeviceID = nil
        statusMessage = "Scanning \(fromIP) → \(toIP)…"
        launchScanTask(from: fromIP, to: toIP, clearExisting: true)
    }

    func stopScan() {
        Task { await NetworkScanner.shared.stopScan() }
        cancelEnrichmentTasks()
        cancelManualPortScanTasks()
        isScanning = false
        statusMessage = "Stopped · Devices found: \(devices.count)"
    }

    func clearResults() {
        cancelEnrichmentTasks()
        cancelManualPortScanTasks()
        devices = []
        selectedDeviceID = nil
        scanProgress = 0
        statusMessage = "Ready"
    }

    /// Scan an arbitrary IP range; clears the current results first.
    func startRangeScan(from: String, to: String) {
        fromIP = from
        toIP   = to
        startScan()
    }

    /// Discover the upstream router via traceroute, then ping it and add it to the
    /// device list without clearing existing results.
    func expandToUpstreamRouter() {
        guard !isScanning, !isDiscoveringUpstream else { return }
        isDiscoveringUpstream = true
        statusMessage = "Discovering upstream router…"
        Task {
            let ip = await UpstreamDiscovery.findUpstreamRouter()
            upstreamRouter = ip
            if let ip, let range = UpstreamDiscovery.inferSubnetRange(from: ip) {
                upstreamSubnetFrom = range.from
                upstreamSubnetTo   = range.to
            }
            isDiscoveringUpstream = false
            guard let router = upstreamRouter else {
                statusMessage = "Upstream router not found"
                return
            }
            isScanning    = true
            scanProgress  = 0
            statusMessage = "Scanning upstream router \(router)…"
            launchScanTask(from: router, to: router, clearExisting: false)
        }
    }

    func startPortScanForSelectedDevice() {
        guard let selected = selectedDevice else { return }
        startManualPortScan(for: selected.id)
    }

    // MARK: - Device editing

    func setCustomInfo(name: String?, vendor: String?, identification: String?,
                       deviceType: DeviceType?, for deviceID: String) {
        updateDevice(id: deviceID) { device in
            device.customName = name
            device.customVendor = vendor
            device.customIdentification = identification
            device.customDeviceType = deviceType
        }
    }

    func clearCustomInfo(for deviceID: String) {
        updateDevice(id: deviceID) { device in
            device.customName = nil
            device.customVendor = nil
            device.customIdentification = nil
            device.customDeviceType = nil
        }
    }

    func setComments(_ comments: String, for deviceID: String) {
        updateDevice(id: deviceID) { device in
            device.comments = comments.isEmpty ? nil : comments
        }
    }

    // MARK: - Private

    private func insertDevice(_ device: NetworkDevice) {
        var updated = devices
        updated.append(device)
        updated.sort { NetworkUtils.compareIPs($0.ipv4Address, $1.ipv4Address) }
        devices = updated
    }

    private func upsertDevice(_ device: NetworkDevice) {
        var updated = devices
        if let idx = updated.firstIndex(where: { $0.id == device.id }) {
            updated[idx] = device
        } else {
            updated.append(device)
            updated.sort { NetworkUtils.compareIPs($0.ipv4Address, $1.ipv4Address) }
        }
        devices = updated
    }

    private func updateDevice(id: String, mutate: (inout NetworkDevice) -> Void) {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        var updated = devices
        mutate(&updated[idx])
        devices = updated
    }

    /// Shared Task launcher used by startScan() and expandToUpstreamRouter().
    /// clearExisting=true  → fresh scan: use insertDevice (maintains sorted order).
    /// clearExisting=false → expand scan: use upsertDevice (appends new, updates existing).
    private func launchScanTask(from: String, to: String, clearExisting: Bool) {
        Task {
            await NetworkScanner.shared.startScan(
                fromIP: from,
                toIP:   to,
                scanPorts: scanPortsEnabled,
                onDeviceDiscovered: { [weak self] device in
                    guard let self else { return }
                    if clearExisting { self.insertDevice(device) }
                    else             { self.upsertDevice(device) }
                    self.enqueueEnrichment(for: device)
                },
                onDeviceUpdated: { [weak self] device in
                    guard let self else { return }
                    self.upsertDevice(device)
                    self.enqueueEnrichment(for: device)
                },
                onProgress: { [weak self] completed, total in
                    guard let self else { return }
                    self.scanProgress = Double(completed) / Double(total)
                },
                onCompleted: { [weak self] in
                    guard let self else { return }
                    self.isScanning   = false
                    self.scanProgress = 1.0
                    self.statusMessage = "Devices found: \(self.devices.count)"
                }
            )
        }
    }

    private func cancelEnrichmentTasks() {
        for task in enrichmentTasks.values { task.cancel() }
        enrichmentTasks.removeAll()
    }

    private func cancelManualPortScanTasks() {
        for task in manualPortScanTasks.values { task.cancel() }
        manualPortScanTasks.removeAll()
    }

    private func enqueueEnrichment(for device: NetworkDevice) {
        let ip = device.ipv4Address
        guard enrichmentTasks[ip] == nil else {
            print("[Enrich] \(ip) — enrichment already in progress, skipping")
            return
        }

        print("[Enrich] \(ip) — start (ping:\(device.pingStatus == .alive ? "alive" : "miss") mdnsName:\(device.mdnsName ?? "-") vendor:\(device.vendor ?? "-"))")

        let shouldScanPorts = scanPortsEnabled
        let task = Task { [weak self] in
            guard let self else { return }

            async let hostnameTask = HostnameResolver.resolveHostname(for: ip)
            async let bannerTask: HttpBannerResult = device.pingStatus == .alive
                ? HttpBannerScanner.identify(host: ip)
                : HttpBannerResult()
            let hostname = await hostnameTask
            let banner = await bannerTask

            print("[Enrich] \(ip) — hostname:\(hostname ?? "nil") banner.vendor:\(banner.vendor ?? "nil") banner.id:\(banner.identification ?? "nil")")

            var ports: [Int] = []
            if shouldScanPorts {
                ports = await PortScanner.scan(host: ip)
            }

            await MainActor.run {
                self.updateDevice(id: ip) { current in
                    let beforeType = current.deviceType
                    let beforeVendor = current.vendor
                    if let hostname { current.hostname = hostname }
                    if !ports.isEmpty { current.openPorts = ports }
                    if current.vendor == nil, let v = banner.vendor {
                        current.vendor = v
                    }
                    if current.identification == nil, let id = banner.identification {
                        current.identification = id
                    }
                    current.deviceType = DeviceTypeDetector.detect(current)
                    if current.vendor == nil {
                        current.vendor = current.deviceType.inferredVendor
                    }
                    if current.deviceType != beforeType || current.vendor != beforeVendor {
                        print("[Enrich] \(ip) — after applying banner: type \(beforeType)→\(current.deviceType) vendor \(beforeVendor ?? "-")→\(current.vendor ?? "-")")
                    }
                }
            }

            if let hostname, !hostname.isEmpty,
               let mdns = await HostnameResolver.resolveMDNSName(for: hostname) {
                print("[Enrich] \(ip) — additional mDNS name: \(mdns)")
                await MainActor.run {
                    self.updateDevice(id: ip) { current in
                        current.mdnsName = mdns
                        current.deviceType = DeviceTypeDetector.detect(current)
                        if current.vendor == nil {
                            current.vendor = current.deviceType.inferredVendor
                        }
                    }
                }
            }

            await MainActor.run {
                self.enrichmentTasks.removeValue(forKey: ip)
                print("[Enrich] \(ip) — done")
            }
        }
        enrichmentTasks[ip] = task
    }

    private func startManualPortScan(for deviceID: String) {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        let ip = device.ipv4Address

        guard manualPortScanTasks[ip] == nil else {
            statusMessage = "Port scan already running for \(ip)"
            return
        }

        statusMessage = "Port scanning \(ip)…"
        let task = Task { [weak self] in
            guard let self else { return }
            let ports = await PortScanner.scan(host: ip)
            await MainActor.run {
                self.updateDevice(id: ip) { current in
                    current.openPorts = ports
                    current.deviceType = DeviceTypeDetector.detect(current)
                    if current.vendor == nil {
                        current.vendor = current.deviceType.inferredVendor
                    }
                }
                self.manualPortScanTasks.removeValue(forKey: ip)
                self.statusMessage = "Port scan complete: \(ip) (\(ports.count) open)"
            }
        }
        manualPortScanTasks[ip] = task
    }
}
