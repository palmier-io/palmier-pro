import Foundation

enum BackendError: LocalizedError {
    case notConfigured
    case transport(String)
    case api(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: L10n.string("Palmier backend not configured.")
        case .transport(let message): message
        case .api(_, _, let message): message
        }
    }
}
