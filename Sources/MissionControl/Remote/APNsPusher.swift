import Foundation
import CryptoKit

/// Sends APNs notifications directly from this Mac. No middleman, no relay.
/// Reads a .p8 auth key file once on init; mints a JWT every ~50 minutes.
actor APNsPusher {
    struct Config {
        let teamId: String
        let keyId: String
        let bundleId: String
        let p8Path: String
        let useProduction: Bool

        var host: String {
            useProduction ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        }
    }

    let config: Config
    private var cachedToken: (jwt: String, mintedAt: Date)?

    init(config: Config) { self.config = config }

    struct Payload: Encodable {
        let aps: APS
        let projectId: String
        let sessionId: String?
        let kind: String        // "waitingForInput" | "completed" | "error"

        struct APS: Encodable {
            let alert: Alert
            let sound: String?
            let mutableContent: Int?
            let interruptionLevel: String?
            enum CodingKeys: String, CodingKey {
                case alert, sound
                case mutableContent = "mutable-content"
                case interruptionLevel = "interruption-level"
            }
        }
        struct Alert: Encodable { let title: String; let body: String }
    }

    enum PushError: Error, CustomStringConvertible {
        case missingKey
        case invalidKey
        case httpError(Int, String)

        var description: String {
            switch self {
            case .missingKey: "APNs p8 key file missing — set the path in Remote settings."
            case .invalidKey: "APNs p8 key could not be parsed."
            case .httpError(let s, let body): "APNs HTTP \(s): \(body)"
            }
        }
    }

    /// Push to a single device. Caller decides which devices to fan out to.
    func push(to deviceToken: String, payload: Payload) async throws {
        let jwt = try mintOrReuseJWT()
        var req = URLRequest(url: URL(string: "https://\(config.host)/3/device/\(deviceToken)")!)
        req.httpMethod = "POST"
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(config.bundleId, forHTTPHeaderField: "apns-topic")
        req.setValue("alert", forHTTPHeaderField: "apns-push-type")
        req.setValue("10", forHTTPHeaderField: "apns-priority")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PushError.httpError(http.statusCode, body)
        }
    }

    // MARK: - JWT minting (ES256 over the .p8 key)

    private func mintOrReuseJWT() throws -> String {
        // Apple recommends regenerating no more than once every 20 minutes,
        // and not letting a token age beyond an hour. 50 min is a safe middle.
        if let cached = cachedToken, Date().timeIntervalSince(cached.mintedAt) < 50 * 60 {
            return cached.jwt
        }
        let jwt = try mintJWT()
        cachedToken = (jwt, Date())
        return jwt
    }

    private func mintJWT() throws -> String {
        guard FileManager.default.fileExists(atPath: config.p8Path),
              let pem = try? String(contentsOfFile: config.p8Path, encoding: .utf8)
        else { throw PushError.missingKey }

        let key = try parseP8(pem: pem)

        let header: [String: String] = ["alg": "ES256", "kid": config.keyId, "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": config.teamId,
            "iat": Int(Date().timeIntervalSince1970),
        ]

        let headerJSON = try JSONSerialization.data(withJSONObject: header)
        let claimsJSON = try JSONSerialization.data(withJSONObject: claims)
        let headerB64 = base64URL(headerJSON)
        let claimsB64 = base64URL(claimsJSON)
        let signingInput = "\(headerB64).\(claimsB64)"

        let signature = try key.signature(for: Data(signingInput.utf8))
        let sigB64 = base64URL(signature.rawRepresentation)

        return "\(signingInput).\(sigB64)"
    }

    private func parseP8(pem: String) throws -> P256.Signing.PrivateKey {
        // Strip PEM headers/footers and whitespace
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let der = Data(base64Encoded: stripped) else { throw PushError.invalidKey }
        // SecKey-friendly DER (PKCS#8) — CryptoKit can ingest .pem directly via init(pemRepresentation:)
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) { return key }
        if let key = try? P256.Signing.PrivateKey(derRepresentation: der) { return key }
        throw PushError.invalidKey
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
