import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 so tools (like the MCP server in /mcp) can drive the app.
/// Every request must carry the token from `~/Library/Application Support/VideoFilmer/control.json`.
final class ControlServer {
    struct Request {
        let method: String
        let route: String
        let query: [String: String]
        let body: Data

        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    struct Response {
        var status = 200
        var contentType = "application/json"
        var body = Data()

        static func json(_ object: Any, status: Int = 200) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return Response(status: status, body: data)
        }
        static func error(_ message: String, status: Int = 400) -> Response { json(["error": message], status: status) }
        static func png(_ data: Data) -> Response { Response(contentType: "image/png", body: data) }
    }

    static let port: UInt16 = 47801
    static let configURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VideoFilmer/control.json")

    var handler: (@MainActor (Request) async -> Response)?

    private let token: String
    private let queue = DispatchQueue(label: "VideoFilmer.control")
    private var listener: NWListener?

    init() {
        token = Self.loadOrCreateToken()
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.receive(on: conn, buffer: Data())
        }
        l.start(queue: queue)
        listener = l
    }

    private static func loadOrCreateToken() -> String {
        if let data = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = obj["token"] as? String, obj["port"] as? Int == Int(port) {
            return token
        }
        let token = UUID().uuidString + UUID().uuidString
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(withJSONObject: ["port": Int(port), "token": token])
        FileManager.default.createFile(atPath: configURL.path, contents: data, attributes: [.posixPermissions: 0o600])
        return token
    }

    // MARK: - HTTP

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let (request, headers) = Self.parse(buffer) {
                self.respond(to: request, headers: headers, on: conn)
            } else if isComplete || error != nil || buffer.count > 8 << 20 {
                conn.cancel()
            } else {
                self.receive(on: conn, buffer: buffer)
            }
        }
    }

    /// Returns a request once the headers and the whole body have arrived.
    private static func parse(_ data: Data) -> (Request, [String: String])? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }

        let target = String(parts[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = Request(method: String(parts[0]), route: comps?.path ?? target, query: query, body: Data(body.prefix(length)))
        return (request, headers)
    }

    private func respond(to request: Request, headers: [String: String], on conn: NWConnection) {
        guard headers["x-videofilmer-token"] == token else {
            send(.error("Missing or wrong X-VideoFilmer-Token.", status: 401), on: conn)
            return
        }
        guard let handler else {
            send(.error("Not ready.", status: 503), on: conn)
            return
        }
        Task {
            let response = await handler(request)
            self.send(response, on: conn)
        }
    }

    private func send(_ response: Response, on conn: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 503: "Service Unavailable"][response.status] ?? "Error"
        var out = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(response.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
