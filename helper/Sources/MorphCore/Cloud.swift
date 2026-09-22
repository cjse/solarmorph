import Foundation

/// Minimal Dyson cloud client. It gets the long-term key (LTK) that the offline
/// handshake needs. It runs one time, during pairing.
public struct DysonCloud {
    /// The `X-Dyson-ApiAuthCode` that the LTK endpoint accepts in place of a session code.
    static let ltkAuthCode = "80541406"
    /// The MyDyson Android app identifies itself with this string.
    static let userAgent = "android client"

    public struct Device {
        public let serial: String
        public let name: String
        public let category: String?
        public let connectionCategory: String?

        /// Lights that are reachable over Bluetooth.
        public var isBluetoothLight: Bool { category == "light" && connectionCategory != "wifiOnly" }
    }

    let country: String
    let culture: String

    public init(country: String, culture: String? = nil) {
        self.country = country.uppercased()
        self.culture = culture ?? Self.culture(for: self.country)
    }

    /// Dyson wants a BCP 47 culture. The country code is not a language code
    /// (`GB`, `US`), so use English except where the reference project knows better.
    static func culture(for country: String) -> String {
        let languages = ["DE": "de", "AT": "de", "CH": "de", "FR": "fr", "IT": "it", "ES": "es", "NL": "nl"]
        return "\(languages[country] ?? "en")-\(country)"
    }

    /// Start a login. Dyson emails a one-time code.
    /// - Returns: the `challengeId` for `completeLogin`.
    public func beginLogin(email: String) async throws -> String {
        // The API rejects clients that did not announce themselves recently.
        _ = try await request("GET", "/v1/provisioningservice/application/Android/version")
        _ = try await request("POST", "/v3/userregistration/email/userstatus", query: ["country": country], body: ["email": email])
        let data = try await request(
            "POST", "/v3/userregistration/email/auth",
            query: ["country": country, "culture": culture], body: ["email": email])
        guard let challengeId = (data as? [String: Any])?["challengeId"] as? String else {
            throw MorphError.cloud("Dyson did not return a challengeId. Is the email registered?")
        }
        return challengeId
    }

    public func completeLogin(email: String, password: String, challengeId: String, otpCode: String) async throws -> (token: String, accountId: String) {
        let data = try await request(
            "POST", "/v3/userregistration/email/verify",
            query: ["country": country, "culture": culture],
            body: ["challengeId": challengeId, "email": email, "otpCode": otpCode, "password": password])
        guard let dict = data as? [String: Any], let token = dict["token"] as? String, let account = dict["account"] as? String else {
            throw MorphError.cloud("The Dyson login returned no token or account.")
        }
        return (token, account)
    }

    public func devices(token: String) async throws -> [Device] {
        let data = try await request("GET", "/v3/manifest", headers: ["Authorization": "Bearer \(token)"])
        return (data as? [[String: Any]] ?? []).compactMap { entry in
            guard let serial = entry["serialNumber"] as? String else { return nil }
            return Device(
                serial: serial, name: entry["name"] as? String ?? serial,
                category: entry["category"] as? String,
                connectionCategory: entry["connectionCategory"] as? String)
        }
    }

    /// The lamp must already be registered to this account in the MyDyson app.
    /// If it is not, the endpoint returns 404.
    public func fetchLtk(serial: String, token: String) async throws -> String {
        let path = "/v1/lec/\(serial.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? serial)/ltk"
        let data = try await request("GET", path, headers: [
            "Authorization": "Bearer \(token)",
            "X-Dyson-ApiAuthCode": Self.ltkAuthCode,
        ])
        guard let ltk = (data as? [String: Any])?["ltk"] as? String, !ltk.isEmpty else {
            throw MorphError.cloud("Dyson returned no key for \(serial).")
        }
        return ltk
    }

    private func request(_ method: String, _ path: String, query: [String: String] = [:],
                         body: [String: String]? = nil, headers: [String: String] = [:]) async throws -> Any {
        // Only China has a dedicated endpoint.
        let host = country == "CN" ? "https://appapi.cp.dyson.cn" : "https://appapi.cp.dyson.com"
        var components = URLComponents(string: host + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw MorphError.cloud("Dyson API \(method) \(path) failed: \(status) \(text)")
        }
        guard !data.isEmpty else { return [String: Any]() }
        // The version endpoint returns a bare JSON string, which is a fragment.
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw MorphError.cloud("Dyson API \(method) \(path) returned a reply that is not JSON: \(text)")
        }
    }
}
