import Foundation

enum TranscriptionBackendError: LocalizedError {
    case failed(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .unavailable: "Hosted transcription is unavailable in this build."
        }
    }
}
