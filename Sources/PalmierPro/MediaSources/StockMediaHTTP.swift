import Foundation

/// Minimal JSON GET for the stock-media sources. These APIs are small, public, and answer in
/// well under a second, so this stays a plain async call rather than growing into a general
/// HTTP layer that no other feature asked for.
enum StockMediaHTTP {
    private static let timeout: TimeInterval = 20

    static func getJSON(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StockMediaError.undecodable(provider: url.host ?? "remote source")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw StockMediaError.needsAPIKey(provider: url.host ?? "remote source")
        case 429:
            throw StockMediaError.rateLimited(provider: url.host ?? "remote source")
        default:
            throw StockMediaError.badStatus(provider: url.host ?? "remote source", code: http.statusCode)
        }
    }

    /// Openverse asks callers to identify themselves; Pexels ignores it.
    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "PalmierPro/\(version) (macOS video editor)"
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, provider: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StockMediaError.undecodable(provider: provider)
        }
    }
}
