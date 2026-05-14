import Foundation
import Network

/// Minimal HTTP/1.1 server on top of Network.framework. Aimed at single-user
/// LAN / Tailscale traffic — no keep-alive, no chunked transfer, no TLS.
/// Auth is enforced by the route handlers (we just shuttle bytes).
final class HTTPServer {
    typealias Handler = (HTTPRequest) async -> HTTPResponse

    private struct Route { let method: String; let pattern: String; let handler: Handler }

    private let queue = DispatchQueue(label: "mc.http.server")
    private var listener: NWListener?
    private var routes: [Route] = []

    private(set) var actualPort: UInt16 = 0
    var onState: ((NWListener.State) -> Void)?

    func route(_ method: String, _ pattern: String, _ handler: @escaping Handler) {
        routes.append(Route(method: method, pattern: pattern, handler: handler))
    }

    func start(port: UInt16) throws {
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = listener.port?.rawValue {
                self?.actualPort = p
            }
            self?.onState?(state)
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        actualPort = 0
    }

    // MARK: - Connection lifecycle

    private func accept(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .failed = state { conn.cancel() }
            if case .cancelled = state { /* done */ }
        }
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }

            if let req = HTTPRequest.parse(from: buf) {
                Task { [weak self] in
                    guard let self else { conn.cancel(); return }
                    let resp = await self.dispatch(req)
                    self.send(resp, on: conn)
                }
                return
            }
            if error != nil || isComplete { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    private func send(_ resp: HTTPResponse, on conn: NWConnection) {
        conn.send(content: resp.serialize(), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - Routing

    private func dispatch(_ req: HTTPRequest) async -> HTTPResponse {
        for r in routes where r.method == req.method {
            if let params = match(pattern: r.pattern, path: req.pathOnly) {
                var injected = req
                injected.pathParams = params
                return await r.handler(injected)
            }
        }
        return HTTPResponse(status: 404, jsonObject: ["error": "not found"])
    }

    /// Matches "/sessions/:id/messages" against "/sessions/abc/messages",
    /// returning {"id": "abc"} on success or nil on miss.
    private func match(pattern: String, path: String) -> [String: String]? {
        let pp = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let xp = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard pp.count == xp.count else { return nil }
        var params: [String: String] = [:]
        for (a, b) in zip(pp, xp) {
            if a.hasPrefix(":") {
                params[String(a.dropFirst())] = b.removingPercentEncoding ?? b
            } else if a != b {
                return nil
            }
        }
        return params
    }
}

// MARK: - HTTPRequest / HTTPResponse

struct HTTPRequest {
    let method: String
    let pathOnly: String                  // without query string
    var pathParams: [String: String] = [:]
    let query: [String: String]
    let headers: [String: String]         // keys lowercased
    let body: Data

    var bearerToken: String? {
        guard let v = headers["authorization"], v.hasPrefix("Bearer ") else { return nil }
        return String(v.dropFirst(7))
    }

    func decodeJSON<T: Decodable>(_ type: T.Type) -> T? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(type, from: body)
    }

    static func parse(from data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerPart = data.subdata(in: 0..<headerEnd.lowerBound)
        guard let text = String(data: headerPart, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let fullPath = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<(bodyStart + contentLength))
            : Data()

        // Split path / query
        let pathOnly: String
        var query: [String: String] = [:]
        if let q = fullPath.firstIndex(of: "?") {
            pathOnly = String(fullPath[..<q])
            let qs = fullPath[fullPath.index(after: q)...]
            for pair in qs.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = parts.count > 1
                    ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
                    : ""
                query[key] = value
            }
        } else {
            pathOnly = fullPath
        }

        return HTTPRequest(method: method, pathOnly: pathOnly, query: query, headers: headers, body: body)
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, body: Data = Data(), contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.headers = ["Content-Type": contentType]
    }

    init(status: Int, jsonObject: Any) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: jsonObject)) ?? Data()
        self.headers = ["Content-Type": "application/json"]
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let body = (try? enc.encode(value)) ?? Data()
        return HTTPResponse(status: status, body: body, contentType: "application/json")
    }

    static let unauthorized = HTTPResponse(status: 401, jsonObject: ["error": "unauthorized"])
    static let badRequest = HTTPResponse(status: 400, jsonObject: ["error": "bad request"])
    static let accepted = HTTPResponse(status: 202, jsonObject: ["ok": true])

    func serialize() -> Data {
        var h = headers
        h["Content-Length"] = "\(body.count)"
        h["Connection"] = "close"

        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        for (k, v) in h { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
