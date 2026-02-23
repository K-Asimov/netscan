import Foundation

/// OUI-based vendor lookup for devices that don't use Bonjour/SSDP/HTTP banner.
/// Apple devices are intentionally excluded — their vendor is inferred from
/// DeviceType (via Bonjour) instead of from an always-incomplete OUI list.
enum MACVendorResolver {

    private static let ouiTable: [String: String] = {
        var t: [String: String] = [:]

        // ── NAS ───────────────────────────────────────────────────────────────
        for oui in ["00:11:32", "00:1f:a4", "08:00:27", "bc:ee:7b", "10:6f:3f"] {
            t[oui] = "Synology Incorporated"
        }
        for oui in ["00:08:9b", "24:5e:be", "00:50:43", "28:80:88", "8c:ec:4b"] {
            t[oui] = "QNAP Systems, Inc."
        }
        for oui in ["00:90:a9", "c8:60:00", "00:50:b3", "00:14:ee", "78:45:c4",
                    "a4:ba:76", "b8:ac:6f"] {
            t[oui] = "Western Digital"
        }
        for oui in ["00:10:75", "34:64:a9", "00:50:b2"] {
            t[oui] = "Seagate"
        }

        // ── Routers / Access Points ────────────────────────────────────────────
        for oui in ["14:cc:20", "18:a6:f7", "1c:61:b4", "50:3e:aa", "54:a7:03",
                    "64:70:02", "6c:19:c0", "70:4f:57", "74:da:38", "90:f6:52",
                    "a0:f3:c1", "b0:48:7a", "b4:b0:24", "c4:6e:1f", "d8:0d:17",
                    "e8:94:f6", "ec:17:2f", "30:de:4b", "50:d4:f7", "98:da:c4"] {
            t[oui] = "TP-Link Technologies"
        }
        for oui in ["00:0c:6e", "00:1a:92", "04:92:26", "08:60:6e", "0c:9d:92",
                    "10:7b:44", "2c:56:dc", "30:5a:3a", "40:16:7e", "50:46:5d",
                    "6c:72:20", "74:d0:2b", "90:48:9a", "ac:9e:17", "f8:32:e4"] {
            t[oui] = "ASUSTeK Computer"
        }
        for oui in ["00:09:5b", "00:14:6c", "00:1b:2f", "00:1e:2a", "00:26:f2",
                    "20:4e:7f", "2c:b0:5d", "30:46:9a", "30:68:93", "44:94:fc",
                    "6c:b0:ce", "84:1b:5e", "a0:40:a0", "b0:39:56", "c0:3f:0e",
                    "9c:3d:cf", "28:c6:8e"] {
            t[oui] = "Netgear"
        }
        for oui in ["00:15:6d", "00:27:22", "04:18:d6", "0c:80:63", "18:e8:29",
                    "24:a4:3c", "44:d9:e7", "68:72:51", "78:8a:20", "80:2a:a8",
                    "dc:9f:db", "e0:63:da", "f0:9f:c2", "f4:92:bf"] {
            t[oui] = "Ubiquiti Networks"
        }
        for oui in ["00:17:df", "00:21:29", "cc:46:d6", "40:a3:6b", "58:ef:68",
                    "74:83:c2", "9c:b2:b2", "e0:1c:41", "fc:ec:da"] {
            t[oui] = "D-Link"
        }
        for oui in ["00:e0:4c", "52:54:00", "00:1b:fc", "2c:fd:a1", "e0:98:61",
                    "10:7c:61", "64:09:80"] {
            t[oui] = "ASUS (Realtek)"
        }

        // ── Smart Home / IoT ──────────────────────────────────────────────────
        for oui in ["00:bb:3a", "34:d2:70", "40:b4:cd", "44:65:0d", "50:f5:da",
                    "68:37:e9", "74:75:48", "8c:85:80", "a4:08:01", "b4:7c:9c",
                    "f0:27:2d", "fc:65:de", "0c:47:c9", "f0:f0:f0"] {
            t[oui] = "Amazon Technologies"
        }
        for oui in ["00:1a:11", "08:9e:08", "3c:5a:b4", "48:d6:d5", "54:60:09",
                    "6c:ad:f8", "94:eb:2c", "a4:77:33", "f4:f5:d8"] {
            t[oui] = "Google"
        }
        for oui in ["18:b4:30", "28:6d:97", "44:61:32", "98:84:e3", "a4:da:22"] {
            t[oui] = "Nest Labs"
        }

        // ── Printers ──────────────────────────────────────────────────────────
        for oui in ["00:17:c8", "00:1e:0b", "28:80:23", "30:cd:a7", "3c:2a:f4",
                    "40:b0:34", "9c:32:ce", "b4:99:ba", "d4:e8:80"] {
            t[oui] = "HP Inc."
        }
        for oui in ["00:00:85", "00:1e:8f", "00:26:2d", "3c:13:c2",
                    "50:57:a8", "78:84:3c"] {
            t[oui] = "Canon"
        }
        for oui in ["00:26:ab", "0c:d7:c2", "44:d2:44", "64:eb:8c",
                    "ac:18:26", "e4:1f:13"] {
            t[oui] = "Epson"
        }

        return t
    }()

    static func vendor(for mac: String?) -> String? {
        guard let mac else { return nil }
        let normalized = normalize(mac)
        guard normalized.count >= 8 else { return nil }
        return ouiTable[String(normalized.prefix(8))]
    }

    /// True if the MAC uses a locally-administered (random/privacy) address.
    static func isLocallyAdministered(_ mac: String?) -> Bool {
        guard let mac else { return false }
        let n = normalize(mac)
        guard n.count >= 2, let byte = UInt8(n.prefix(2), radix: 16) else { return false }
        return (byte & 0x02) != 0
    }

    private static func normalize(_ mac: String) -> String {
        let lower = mac.lowercased().replacingOccurrences(of: "-", with: ":")
        let chunks = lower.split(separator: ":").prefix(6)
        return chunks.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
    }
}
