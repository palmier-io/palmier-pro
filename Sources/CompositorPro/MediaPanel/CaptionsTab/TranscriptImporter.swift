import Foundation

struct TranscriptSegment: Sendable, Equatable {
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}

enum TranscriptImportError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case emptyTranscript
    case malformedTimestamp(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            "Unsupported transcript format '.\(ext)'. Import .srt, .vtt, or .txt."
        case .emptyTranscript: "The transcript file contains no text."
        case .malformedTimestamp(let value): "Malformed transcript timestamp: '\(value)'."
        }
    }
}

/// Imports SRT/VTT/plain transcripts into timed segments. Plain text without timestamps is spread
/// evenly across the timeline duration, matching the OpenCut import behavior.
enum TranscriptImporter {
    static func parse(_ text: String, fileExtension: String, durationSeconds: Double) throws -> [TranscriptSegment] {
        let ext = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch ext {
        case "srt", "vtt":
            let segments = try parseCues(text, isVTT: ext == "vtt")
            guard !segments.isEmpty else { throw TranscriptImportError.emptyTranscript }
            return segments
        case "txt", "text", "":
            let lines = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { throw TranscriptImportError.emptyTranscript }
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                return lines.enumerated().map { index, line in
                    TranscriptSegment(startSeconds: Double(index), endSeconds: Double(index + 1), text: line)
                }
            }
            let slice = durationSeconds / Double(lines.count)
            return lines.enumerated().map { index, line in
                TranscriptSegment(startSeconds: Double(index) * slice, endSeconds: Double(index + 1) * slice, text: line)
            }
        default:
            throw TranscriptImportError.unsupportedFormat(ext)
        }
    }

    /// Appends imported segments that do not duplicate an existing range.
    static func merge(_ imported: [TranscriptSegment], into existing: [TranscriptSegment],
                      tolerance: Double = 0.05) -> [TranscriptSegment] {
        var merged = existing
        for segment in imported {
            let overlaps = merged.contains {
                abs($0.startSeconds - segment.startSeconds) <= tolerance && abs($0.endSeconds - segment.endSeconds) <= tolerance
            }
            if !overlaps { merged.append(segment) }
        }
        return merged.sorted { $0.startSeconds < $1.startSeconds }
    }

    private static func parseCues(_ text: String, isVTT: Bool) throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var pendingStart: Double?
        var pendingEnd: Double?
        var pendingLines: [String] = []

        func flush() throws {
            guard let start = pendingStart, let end = pendingEnd else {
                pendingLines.removeAll()
                return
            }
            let body = pendingLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty, end > start {
                segments.append(TranscriptSegment(startSeconds: start, endSeconds: end, text: body))
            }
            pendingStart = nil
            pendingEnd = nil
            pendingLines.removeAll()
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                try flush()
                continue
            }
            if isVTT, line.uppercased().hasPrefix("WEBVTT") || line.uppercased().hasPrefix("NOTE") { continue }
            if line.contains("-->") {
                try flush()
                let pieces = line.components(separatedBy: "-->")
                guard pieces.count == 2 else { throw TranscriptImportError.malformedTimestamp(line) }
                pendingStart = try time(pieces[0])
                pendingEnd = try time(pieces[1])
                continue
            }
            if pendingStart != nil, Int(line) == nil {
                pendingLines.append(line)
            }
        }
        try flush()
        return segments
    }

    /// Accepts `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, and `MM:SS.mmm`.
    private static func time(_ raw: String) throws -> Double {
        let value = raw.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        let pieces = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count) else { throw TranscriptImportError.malformedTimestamp(raw) }
        var seconds = 0.0
        for (index, piece) in pieces.enumerated() {
            guard let number = Double(piece), number.isFinite else {
                throw TranscriptImportError.malformedTimestamp(raw)
            }
            let power = pieces.count - 1 - index
            seconds += number * pow(60, Double(power))
        }
        return seconds
    }
}
