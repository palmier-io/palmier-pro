import Foundation

/// Structured brand design specification for video styling.
/// Bridges HyperFrames `frame.md` and `design.md` specifications to native timeline styling.
struct DesignSpec: Codable, Sendable, Equatable {
    struct Palette: Codable, Sendable, Equatable {
        var background: TextStyle.RGBA?
        var surface: TextStyle.RGBA?
        var text: TextStyle.RGBA?
        var primary: TextStyle.RGBA?
        var accent: TextStyle.RGBA?
        var border: TextStyle.RGBA?
        var custom: [String: TextStyle.RGBA] = [:]
    }

    struct Typography: Codable, Sendable, Equatable {
        var displayFont: String?
        var bodyFont: String?
        var baseSize: Double?
        var displayWeight: String?
        var bodyWeight: String?
    }

    struct CanvasGeometry: Codable, Sendable, Equatable {
        var aspectRatio: String?
        var width: Int?
        var height: Int?

        /// Resolves standard canvas dimensions from the aspect ratio or explicit resolution.
        func resolvedDimensions() -> (width: Int, height: Int)? {
            if let w = width, let h = height, w > 0 && h > 0 {
                return (w, h)
            }
            guard let ar = aspectRatio?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !ar.isEmpty else {
                return nil
            }
            if ar.contains("x") {
                let parts = ar.split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                    return (parts[0], parts[1])
                }
            }
            switch ar {
            case "16:9", "16/9", "landscape":
                return (1920, 1080)
            case "9:16", "9/16", "portrait", "vertical", "shorts", "reels", "tiktok":
                return (1080, 1920)
            case "1:1", "1/1", "square":
                return (1080, 1080)
            case "4:5", "4/5":
                return (1080, 1350)
            case "21:9", "21/9", "ultrawide", "cinematic":
                return (2560, 1080)
            case "4:3", "4/3":
                return (1440, 1080)
            default:
                return nil
            }
        }
    }

    struct PacingSpec: Codable, Sendable, Equatable {
        var targetShotDurationSeconds: Double?
        var minShotDurationSeconds: Double?
        var maxShotDurationSeconds: Double?
    }

    struct GradeSpec: Codable, Sendable, Equatable {
        var preset: String?
        var exposure: Double?
        var contrast: Double?
        var saturation: Double?
        var temperature: Double?
        var tint: Double?
    }

    struct CaptionSpec: Codable, Sendable, Equatable {
        var templateId: String?
        var format: String?
        var highlightColor: TextStyle.RGBA?
    }

    var palette: Palette = .init()
    var typography: Typography = .init()
    var canvas: CanvasGeometry = .init()
    var pacing: PacingSpec = .init()
    var grade: GradeSpec = .init()
    var caption: CaptionSpec = .init()
    var rawMarkdown: String? = nil
}

