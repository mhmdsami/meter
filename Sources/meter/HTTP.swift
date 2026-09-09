import Foundation

enum ProviderError: LocalizedError {
    case http(Int, String)
    case rateLimited(retryAfter: TimeInterval?)
    case missingKey(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status)\(body.isEmpty ? "" : ": \(body)")"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "rate limited (429) — backing off \(Int(retryAfter.rounded()))s"
            }
            return "rate limited (429)"
        case .missingKey(let hint):
            return hint
        case .badResponse(let detail):
            return "unexpected response: \(detail)"
        }
    }
}

struct HTTPResponse {
    let data: Data
    let status: Int

    func json() throws -> Any {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw ProviderError.badResponse("not JSON: \(String(data: data.prefix(120), encoding: .utf8) ?? "")")
        }
        return obj
    }
}

enum HTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    static func request(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 429, let httpResp = resp as? HTTPURLResponse {
                throw ProviderError.rateLimited(retryAfter: Self.retryAfter(httpResp))
            }
            throw ProviderError.http(status, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return HTTPResponse(data: data, status: status)
    }

    /// Retry-After: delta-seconds, or an HTTP-date.
    static func retryAfter(_ resp: HTTPURLResponse) -> TimeInterval? {
        guard let value = resp.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let secs = TimeInterval(value.trimmingCharacters(in: .whitespaces)) { return secs }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = fmt.date(from: value) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }

    static func getJSON(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        try await request(url, headers: headers).json()
    }
}

func isoDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = frac.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    return plain.date(from: s)
}

/// Providers whose credentials rotate out-of-band: on 401, invalidate the cached
/// copy and retry once; a second 401 means genuinely stale auth.
func retryingOn401<T>(
    invalidate: () -> Void,
    staleMessage: String,
    _ body: () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch ProviderError.http(401, _) {
        invalidate()
        do {
            return try await body()
        } catch ProviderError.http(401, _) {
            throw ProviderError.badResponse(staleMessage)
        }
    }
}

/// JSONSerialization numbers surface as Double or NSNumber depending on the payload.
func num(_ value: Any?) -> Double {
    optNum(value) ?? 0
}

func optNum(_ value: Any?) -> Double? {
    (value as? Double) ?? ((value as? NSNumber)?.doubleValue)
}
