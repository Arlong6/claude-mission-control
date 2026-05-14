import Foundation
import SwiftUI

/// User-controlled remote-access settings. Lives in UserDefaults — all keys
/// prefixed "mc.remote." — except `secret` which lives in the keychain.
@MainActor
final class RemoteSettings: ObservableObject {
    @AppStorage("mc.remote.enabled") var enabled: Bool = false
    @AppStorage("mc.remote.port") var port: Int = 27890

    @AppStorage("mc.remote.apns.teamId") var apnsTeamId: String = ""
    @AppStorage("mc.remote.apns.keyId") var apnsKeyId: String = ""
    @AppStorage("mc.remote.apns.bundleId") var apnsBundleId: String = "com.arlong.mcpocket"
    @AppStorage("mc.remote.apns.useProduction") var apnsUseProduction: Bool = false
    @AppStorage("mc.remote.apns.p8Path") var apnsP8Path: String = ""

    /// Comma-separated list of "token|nickname|registeredAt" rows. Lightweight;
    /// move to a proper Codable list if we ever need richer per-device state.
    @AppStorage("mc.remote.devices") var devicesRaw: String = ""

    /// Notification rules pushed from the iOS client (JSON-encoded
    /// NotificationRules). Empty string ⇒ use default rules.
    @AppStorage("mc.remote.rules") var rulesJSON: String = ""

    var rules: NotificationRules {
        get {
            guard let data = rulesJSON.data(using: .utf8),
                  !data.isEmpty,
                  let decoded = try? JSONDecoder().decode(NotificationRules.self, from: data)
            else { return .default }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                rulesJSON = str
            }
        }
    }

    // MARK: - Secret (keychain)

    private static let service = "com.arlong.missioncontrol.remote"
    private static let account = "shared-secret-v1"

    @Published private(set) var secret: String = ""

    init() {
        if let s = Self.loadSecret() {
            self.secret = s
        } else {
            self.secret = Self.generateSecret()
            try? Self.saveSecret(self.secret)
        }
    }

    func rotateSecret() {
        let new = Self.generateSecret()
        try? Self.saveSecret(new)
        secret = new
    }

    private static func loadSecret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    private static func saveSecret(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: "MC.Remote.Keychain", code: Int(status))
        }
    }

    private static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Devices

    struct Device: Identifiable, Hashable {
        let id: String        // APNs token (hex)
        let nickname: String
        let registeredAt: Date
    }

    var devices: [Device] {
        devicesRaw.split(separator: "\n").compactMap { row -> Device? in
            let parts = row.split(separator: "|", maxSplits: 2)
            guard parts.count == 3,
                  let ts = TimeInterval(parts[2])
            else { return nil }
            return Device(id: String(parts[0]),
                          nickname: String(parts[1]),
                          registeredAt: Date(timeIntervalSince1970: ts))
        }
    }

    func addOrUpdateDevice(token: String, nickname: String) {
        var list = devices.filter { $0.id != token }
        list.append(Device(id: token, nickname: nickname, registeredAt: Date()))
        devicesRaw = list.map { "\($0.id)|\($0.nickname)|\($0.registeredAt.timeIntervalSince1970)" }
            .joined(separator: "\n")
    }

    func removeDevice(token: String) {
        let list = devices.filter { $0.id != token }
        devicesRaw = list.map { "\($0.id)|\($0.nickname)|\($0.registeredAt.timeIntervalSince1970)" }
            .joined(separator: "\n")
    }
}
