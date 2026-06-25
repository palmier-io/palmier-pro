import AVFoundation

enum ExportFormat {
    case h264, h265, prores, xml

    var fileExtension: String {
        switch self {
        case .h264, .h265: "mp4"
        case .prores: "mov"
        case .xml: "xml"
        }
    }

    var utType: AVFileType? {
        switch self {
        case .h264, .h265: .mp4
        case .prores: .mov
        case .xml: nil
        }
    }
}

enum ExportResolution: String, CaseIterable, Identifiable {
    case r720p = "720p"
    case r1080p = "1080p"
    case r1440p = "2K"
    case r4k = "4K"
    case matchTimeline = "Match Timeline"

    var id: String { rawValue }

    var shortSidePixels: Int? {
        switch self {
        case .r720p: 720
        case .r1080p: 1080
        case .r1440p: 1440
        case .r4k: 2160
        case .matchTimeline: nil
        }
    }

    func renderSize(for canvas: CGSize) -> CGSize {
        guard let shortSidePixels else { return evenSize(canvas) }
        let canvasShort = min(canvas.width, canvas.height)
        guard canvasShort > 0 else { return canvas }
        let scale = Double(shortSidePixels) / Double(canvasShort)
        return evenSize(CGSize(width: canvas.width * scale, height: canvas.height * scale))
    }

    private func evenSize(_ size: CGSize) -> CGSize {
        let w = (Int(size.width.rounded()) / 2) * 2
        let h = (Int(size.height.rounded()) / 2) * 2
        return CGSize(width: max(2, w), height: max(2, h))
    }
}

enum ExportMode: String, CaseIterable, Identifiable {
    case video = "Video (.mp4)"
    case xml = "Timeline (.xml)"
    case palmierProject = "Palmier Project (.palmier)"

    var id: String { rawValue }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case h265 = "H.265"
    case prores = "ProRes"

    var id: String { rawValue }

    var exportFormat: ExportFormat {
        switch self {
        case .h264: .h264
        case .h265: .h265
        case .prores: .prores
        }
    }

    init?(exportFormat: ExportFormat) {
        switch exportFormat {
        case .h264: self = .h264
        case .h265: self = .h265
        case .prores: self = .prores
        case .xml: return nil
        }
    }
}

extension ExportFormat {
    var displayName: String {
        VideoCodec(exportFormat: self)?.rawValue ?? "XML"
    }
}
