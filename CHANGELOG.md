# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).




## [0.1.0] - 2026-02-23

### Changed
- No user-facing changes recorded

## [0.1.0] - 2026-02-23

### Changed
- add GitHub Actions release workflow
- release v0.1.0
- add README, CHANGELOG, and LICENSE

## [0.1.0] - 2026-02-23

### Changed
- add README, CHANGELOG, and LICENSE

## [1.0.0] - 2025-12-01

### Added

- **Ping sweep** — concurrent ICMP ping of the full subnet (batches of 50); live device table populated as hosts respond
- **ARP / NDP** — MAC addresses via `arp -a` snapshot and per-host `arp -n`; IPv6 addresses via `ndp -a -n`
- **Bonjour / mDNS** — `NetServiceBrowser` for standard service types plus `dns-sd` subprocess fallback for Apple-proprietary types (`_airplay._tcp`, `_companion-link._tcp`, `_apple-mobdev2._tcp`, …) that are policy-denied to unsigned apps
- **SSDP / UPnP** — UDP multicast discovery on `239.255.255.250:1900` for smart-home devices, NAS units, and routers
- **HTTP banner scan** — title and content extraction from ports 80, 443, 8080, 5000, 5001 for QNAP, Synology, pfSense, and similar admin UIs
- **Reverse DNS** — hostname resolution via `getnameinfo`; mDNS `.local` names via an additional lookup pass
- **Port scanner** — optional TCP scan of ~40 common ports; can also be triggered manually per device from the detail panel
- **OUI vendor lookup** — bundled OUI database mapping MAC prefixes to vendor names
- **Apple model mapping** — `appleModelIdentifier` → human-readable product name (iPhone 16 Pro, Mac mini M4 Pro, Apple TV 4K, …)
- **Device-type classifier** — multi-signal classification into 13 types: Mac, MacBook, iPhone, iPad, Apple TV, HomePod, Windows, Linux, Router, NAS, Printer, Smart TV, IoT
- **TTL fingerprinting** — OS hints from ICMP TTL (≥250 → router/Cisco, 128 → Windows, 64 → Linux/macOS)
- **Gateway-IP heuristic** — hosts at `.1` or `.254` with no other signals classified as Router
- **Upstream network discovery** — **Expand** button runs `traceroute` to find the second-hop (upstream) router and adds it to the device list
- **Range scan** — **Range…** button opens a dialog pre-filled with the inferred upstream /24 subnet for a full upstream scan
- **Live search / filter** — real-time filter across IP, hostname, MAC, and vendor
- **Device detail panel** — per-device view showing network info, identity, open ports, and editable comments
- **Inline editing** — override name, vendor, description, and device type per device
- **Preferences panel** — interface selector with IP / mask / gateway details; configurable IP subrange; port-scan toggle
- **DMG build script** — `./scripts/build-dmg.sh <version>` produces a signed, notarized-ready DMG
- **Release script** — `./scripts/release.sh <version>` bumps version, auto-generates CHANGELOG entry from commits, creates annotated tag, and pushes
