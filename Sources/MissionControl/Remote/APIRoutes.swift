import Foundation
import CryptoKit

/// Wires the HTTP server to the live ProjectStore + ClaudeBackend.
/// Endpoints match the contract in mc-pocket/API.md.
@MainActor
final class APIRoutes {
    let server: HTTPServer
    private let store: ProjectStore
    private let settings: RemoteSettings

    init(server: HTTPServer, store: ProjectStore, settings: RemoteSettings) {
        self.server = server
        self.store = store
        self.settings = settings
        register()
    }

    private func register() {
        // No auth on healthz so a paired client can sanity-check the server.
        server.route("GET", "/healthz") { _ in
            HTTPResponse(status: 200, jsonObject: ["ok": true, "service": "mission-control"])
        }

        server.route("GET", "/projects") { @MainActor [weak self] req in
            guard let self else { return .unauthorized }
            guard self.allow(req) else { return .unauthorized }
            return .json(self.store.projects.map(ProjectDTO.init(from:)))
        }

        server.route("GET", "/sessions/:id/messages") { @MainActor [weak self] req in
            guard let self else { return .unauthorized }
            guard self.allow(req) else { return .unauthorized }
            guard let projectId = req.pathParams["id"] else { return .badRequest }
            guard let project = self.store.projects.first(where: { $0.id == projectId }),
                  let latest = project.sessions.first
            else { return HTTPResponse(status: 404, jsonObject: ["error": "session not found"]) }
            let chat = JSONLLoader.load(from: latest.url, maxMessages: 100)
            return .json(chat.map(MessageDTO.init(from:)))
        }

        server.route("POST", "/sessions/:id/send") { @MainActor [weak self] req in
            guard let self else { return .unauthorized }
            guard self.allow(req) else { return .unauthorized }
            guard let projectId = req.pathParams["id"],
                  let body = req.decodeJSON(SendBody.self)
            else { return .badRequest }
            guard let project = self.store.projects.first(where: { $0.id == projectId })
            else { return HTTPResponse(status: 404, jsonObject: ["error": "project not found"]) }

            let sessionId = project.sessions.first?.id
            ClaudeBackend.shared.send(
                prompt: body.text,
                cwd: project.originalPath,
                sessionId: sessionId,
                attachments: [],
                onChunk: { _ in },
                onError: { _ in },
                onFinish: { _, _, _ in }
            )
            return .accepted
        }

        server.route("POST", "/register-device") { @MainActor [weak self] req in
            guard let self else { return .unauthorized }
            guard self.allow(req) else { return .unauthorized }
            guard let body = req.decodeJSON(RegisterDeviceBody.self) else { return .badRequest }
            self.settings.addOrUpdateDevice(token: body.token, nickname: body.nickname ?? "iPhone")
            return .accepted
        }

        server.route("GET", "/rules") { @MainActor [weak self] req in
            guard let self else { return .unauthorized }
            guard self.allow(req) else { return .unauthorized }
            return .json(self.settings.rules)
        }

        server.route("POST", "/rules") { @MainActor [weak self] req in
            guard let self else { return .unauthorized }
            guard self.allow(req) else { return .unauthorized }
            guard let rules = req.decodeJSON(NotificationRules.self) else { return .badRequest }
            self.settings.rules = rules
            return .accepted
        }
    }

    private func allow(_ req: HTTPRequest) -> Bool {
        // Prefer HMAC; accept Bearer as a compatibility fallback for the
        // bootstrap window before mc-pocket v0.1 stabilises.
        if let auth = req.headers["authorization"], auth.hasPrefix("MC1-HMAC-SHA256") {
            return verifyHMAC(req, header: auth)
        }
        if let token = req.bearerToken {
            return token == settings.secret
        }
        return false
    }

    /// Constant-time HMAC verification with a ±300s timestamp window to limit
    /// replay. See mc-pocket/SECURITY.md for the wire format.
    private func verifyHMAC(_ req: HTTPRequest, header: String) -> Bool {
        let params = Self.parseAuthHeader(header)
        guard let tsStr = params["ts"], let sig = params["sig"],
              let ts = Int(tsStr)
        else { return false }

        let now = Int(Date().timeIntervalSince1970)
        guard abs(now - ts) < 300 else { return false }

        let bodyHash = SHA256.hash(data: req.body)
            .map { String(format: "%02x", $0) }.joined()
        let canonical = "\(req.method)\n\(req.pathOnly)\n\(tsStr)\n\(bodyHash)"
        let key = SymmetricKey(data: Data(settings.secret.utf8))
        let expected = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()

        // Constant-time compare to keep timing attacks out of scope.
        guard sig.count == expected.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(sig.utf8, expected.utf8) { diff |= a ^ b }
        return diff == 0
    }

    private static func parseAuthHeader(_ header: String) -> [String: String] {
        // "MC1-HMAC-SHA256 ts=123;sig=abc"
        guard let space = header.firstIndex(of: " ") else { return [:] }
        let payload = header[header.index(after: space)...]
        var out: [String: String] = [:]
        for pair in payload.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                out[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1])
            }
        }
        return out
    }
}

// MARK: - DTOs (mirror API.md and iOS Project / ChatMessage models)

private struct ProjectDTO: Encodable {
    let id: String
    let name: String
    let cwd: String
    let status: String
    let lastActivity: Date
    let unreadCount: Int
    let dirtyGitFiles: Int
    let openTodos: Int
    let hasError: Bool

    init(from p: Project) {
        self.id = p.id
        self.name = p.shortName
        self.cwd = p.originalPath
        self.lastActivity = p.lastActivity
        self.unreadCount = 0  // TODO: track unread per device once read-receipts land
        self.dirtyGitFiles = max(p.meta.gitDirty, 0)
        self.openTodos = max(p.meta.todoOpen, 0)
        self.hasError = p.meta.hasError

        if p.meta.hasError {
            self.status = "error"
        } else if Date().timeIntervalSince(p.lastActivity) < 60 {
            self.status = "running"
        } else if Date().timeIntervalSince(p.lastActivity) < 3600 {
            self.status = "waitingForInput"
        } else {
            self.status = "idle"
        }
    }
}

private struct MessageDTO: Encodable {
    let id: String
    let role: String
    let text: String
    let timestamp: Date
    let isError: Bool

    init(from m: ChatMessage) {
        self.id = m.id
        self.role = m.role.rawValue
        self.timestamp = m.timestamp ?? Date()
        self.isError = m.isError
        self.text = m.parts.compactMap { part -> String? in
            switch part {
            case .text(let s): return s
            case .thinking(let s): return "💭 \(s)"
            case .tool(let t): return "🔧 \(t.name): \(t.header)"
            case .image: return "[image]"
            }
        }.joined(separator: "\n")
    }
}

private struct SendBody: Decodable { let text: String }
private struct RegisterDeviceBody: Decodable {
    let token: String
    let platform: String?
    let nickname: String?
}
