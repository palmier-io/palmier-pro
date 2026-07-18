// Per-project transcription routing preference, persisted in project.json.
// auto keeps today's behavior (cloud when the account can afford it, else local); cloud forces the
// higher-accuracy path and fails loudly when the account can't reach it; local always stays on-device.
import Foundation

enum TranscriptionPreference: String, Codable, Sendable, CaseIterable {
    case auto
    case cloud
    case local

    static let `default`: TranscriptionPreference = .auto
}
