import Foundation

struct DeviceCode: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int
}

enum DeviceFlowError: Error, LocalizedError {
    case denied, expired, other(String)
    var errorDescription: String? {
        switch self {
        case .denied: return "You denied access."
        case .expired: return "The code expired. Try again."
        case .other(let s): return s
        }
    }
}

struct DeviceFlow {
    let clientId: String
    let host: String

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private func post(_ path: String, _ form: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)" }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: r)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func start(scopes: String = "notifications repo") async throws -> DeviceCode {
        let json = try await post("/login/device/code", ["client_id": clientId, "scope": scopes])
        let data = try JSONSerialization.data(withJSONObject: json)
        return try decoder.decode(DeviceCode.self, from: data)
    }

    func waitForToken(_ code: DeviceCode) async throws -> String {
        var interval = code.interval
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let json = try await post("/login/oauth/access_token", [
                "client_id": clientId,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = json["access_token"] as? String { return token }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied": throw DeviceFlowError.denied
            case "expired_token": throw DeviceFlowError.expired
            case let e?: throw DeviceFlowError.other(e)
            case nil: continue
            }
        }
        throw DeviceFlowError.expired
    }
}
