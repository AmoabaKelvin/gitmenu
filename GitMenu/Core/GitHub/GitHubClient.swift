import Foundation

struct NotificationsPage {
    let threads: [NotificationThread]
    let lastModified: String?
    let hasNext: Bool
    let notModified: Bool
}

enum GitHubError: Error, LocalizedError {
    case http(Int, String)
    case unauthenticated
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "GitHub returned \(code): \(body.prefix(200))"
        case .unauthenticated: return "Not signed in."
        case .decoding(let e): return "Could not read response: \(e)"
        }
    }
}

final class GitHubClient {
    let apiBase: URL
    let webBase: URL
    var token: () -> String?

    private let session: URLSession
    private let decoder: JSONDecoder

    init(host: String = "github.com", token: @escaping () -> String?) {
        if host == "github.com" {
            apiBase = URL(string: "https://api.github.com")!
            webBase = URL(string: "https://github.com")!
        } else {
            apiBase = URL(string: "https://\(host)/api/v3")!
            webBase = URL(string: "https://\(host)")!
        }
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let iso = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = iso.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date \(s)"))
        }
    }

    private func request(_ method: String, _ url: URL, body: Data? = nil, headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("GitMenu", forHTTPHeaderField: "User-Agent")
        r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let t = token() { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 401 { throw GitHubError.unauthenticated }
        if http.statusCode >= 400 { throw GitHubError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return (data, http)
    }

    func get<T: Decodable>(_ url: URL, as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await send(request("GET", url))
        do { return try decoder.decode(T.self, from: data) } catch { throw GitHubError.decoding(error) }
    }

    func get<T: Decodable>(path: String) async throws -> T {
        try await get(apiBase.appendingPathComponent(path))
    }

    struct User: Decodable { let login: String; let avatarUrl: String; let id: Int }

    func currentUser() async throws -> User { try await get(path: "user") }

    func notifications(page: Int, all: Bool, ifModifiedSince: String?) async throws -> NotificationsPage {
        var comps = URLComponents(url: apiBase.appendingPathComponent("notifications"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "all", value: all ? "true" : "false"), .init(name: "per_page", value: "50"), .init(name: "page", value: String(page))]
        var headers: [String: String] = [:]
        if let ifModifiedSince { headers["If-Modified-Since"] = ifModifiedSince }
        let (data, http) = try await send(request("GET", comps.url!, headers: headers))
        let lm = http.value(forHTTPHeaderField: "Last-Modified")
        if http.statusCode == 304 {
            return NotificationsPage(threads: [], lastModified: lm, hasNext: false, notModified: true)
        }
        let threads: [NotificationThread]
        do { threads = try decoder.decode([NotificationThread].self, from: data) } catch { throw GitHubError.decoding(error) }
        let hasNext = http.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") ?? false
        return NotificationsPage(threads: threads, lastModified: lm, hasNext: hasNext, notModified: false)
    }

    func markRead(threadId: String) async throws {
        _ = try await send(request("PATCH", apiBase.appendingPathComponent("notifications/threads/\(threadId)")))
    }

    func markAllRead() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["read": true])
        _ = try await send(request("PUT", apiBase.appendingPathComponent("notifications"), body: body))
    }

    func markDone(threadId: String) async throws {
        _ = try await send(request("DELETE", apiBase.appendingPathComponent("notifications/threads/\(threadId)")))
    }

    func mute(threadId: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["ignored": true])
        _ = try await send(request("PUT", apiBase.appendingPathComponent("notifications/threads/\(threadId)/subscription"), body: body))
    }

    func graphql(_ query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let url = apiBase.host == "api.github.com" ? URL(string: "https://api.github.com/graphql")! : webBase.appendingPathComponent("api/graphql")
        let (data, _) = try await send(request("POST", url, body: body))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubError.decoding(NSError(domain: "graphql", code: 0)) }
        return json
    }
}
