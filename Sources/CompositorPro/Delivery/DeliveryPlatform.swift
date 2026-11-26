import CoreGraphics
import Foundation

/// Where the edit is going, and therefore what the platform's own interface will cover.
///
/// This is the single owner of delivery-dependent layout. Caption placement, the preview guide
/// overlay and the agent tools all read these numbers, so a caption cannot land under TikTok's
/// buttons while the guide overlay draws a different box.
///
/// The non-`generic` figures are **conservative working areas, not published platform spec**. No
/// platform publishes exact overlay dimensions, and they change without notice. These are tuned so
/// text stays clear of the interface and legible, and they are deliberately larger than the
/// interface really needs. Treat them as a floor for safety, not as a specification.
enum DeliveryPlatform: String, CaseIterable, Sendable, Identifiable {
    /// No platform interface. This preserves the existing caption placement exactly.
    case generic
    case youtube
    case tiktokShorts
    case instagramReels

    var id: String { rawValue }

    /// Fractions of the picture the destination's own interface is expected to cover.
    var coveredArea: EdgeFractions {
        switch self {
        case .generic:
            // bottom is set so the derived caption centre is exactly the historical 0.90.
            EdgeFractions(top: 0.05, bottom: 0.08, left: 0.05, right: 0.05)
        case .youtube:
            EdgeFractions(top: 0.10, bottom: 0.10, left: 0.10, right: 0.10)
        case .tiktokShorts:
            // Right-hand action rail, and the caption plus button stack along the bottom.
            EdgeFractions(top: 0.08, bottom: 0.20, left: 0.04, right: 0.14)
        case .instagramReels:
            EdgeFractions(top: 0.07, bottom: 0.22, left: 0.04, right: 0.13)
        }
    }

    /// True when `coveredArea` is an estimate rather than a published figure.
    var coveredAreaIsEstimate: Bool { self != .generic }

    /// Where a caption goes when the caller has not asked for a specific position.
    ///
    /// Centred across the uncovered width and as low as the safe area allows, derived from
    /// `coveredArea` so there is only one set of numbers to reason about. It is exactly the
    /// clamp's upper bound, so the default is never itself "clamped".
    func defaultCaptionPlacement() -> CaptionPlacement {
        let area = coveredArea
        let rect = area.captionSafeRect
        return CaptionPlacement(
            centerX: 0.5,
            centerY: rect.maxY - Self.captionClearance,
            maxWidth: rect.width
        )
    }

    /// Breathing room between the bottom of a caption and the platform interface, as a fraction
    /// of canvas height.
    static let captionClearance: Double = 0.02

    struct EdgeFractions: Sendable, Equatable {
        var top: Double
        var bottom: Double
        var left: Double
        var right: Double

        init(top: Double, bottom: Double, left: Double, right: Double) {
            self.top = top.clampedToUnit()
            self.bottom = bottom.clampedToUnit()
            self.left = left.clampedToUnit()
            self.right = right.clampedToUnit()
        }

        /// The rectangle a caption must stay inside to clear the interface.
        var captionSafeRect: CGRect {
            CGRect(
                x: left, y: top,
                width: max(0.01, 1 - left - right),
                height: max(0.01, 1 - top - bottom)
            )
        }
    }

    /// Normalized placement for a caption block, as fractions of the canvas.
    struct CaptionPlacement: Sendable, Equatable {
        var centerX: Double
        var centerY: Double
        /// Widest the text may run, as a fraction of canvas width.
        var maxWidth: Double

        /// Pulls a placement inside the platform's covered area. A caller-supplied position is
        /// honoured unless it would land underneath the interface. The centre is bounded rather
        /// than the block, because the block's height is not known here.
        func clamped(into area: EdgeFractions) -> CaptionPlacement {
            let rect = area.captionSafeRect
            let lowerY = rect.minY + DeliveryPlatform.captionClearance
            let upperY = max(lowerY, rect.maxY - DeliveryPlatform.captionClearance)
            let width = maxWidth.isFinite ? maxWidth : rect.width
            return CaptionPlacement(
                centerX: centerX.clamped(to: rect.minX ... rect.maxX),
                centerY: centerY.clamped(to: lowerY ... upperY),
                maxWidth: width.clamped(to: 0.01 ... rect.width)
            )
        }
    }
}

private extension Double {
    func clampedToUnit() -> Double { clamped(to: 0 ... 1) }
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
/// What a platform's upload expects an export to look like.
///
/// Deliberately narrow: it bundles only the two knobs this build actually controls. Bitrate and
/// audio settings are chosen by AVFoundation's export preset internals and cannot be set here,
/// and a platform's own recommended bitrate is not a value this app can apply.
struct ExportDelivery: Sendable, Equatable {
    var codec: VideoCodec
    var resolution: ExportResolution
    /// Dimensions the export will actually produce for a given canvas.
    var outputSize: CGSize
    /// Set when the canvas orientation does not suit the destination.
    var orientationWarning: String?
}

extension DeliveryPlatform {
    /// Orientation a platform's audience expects. `generic` accepts either.
    enum PreferredOrientation: String, Sendable, Equatable {
        case landscape
        case portrait
        case either
    }

    var preferredOrientation: PreferredOrientation {
        switch self {
        case .generic: .either
        case .youtube: .landscape
        case .tiktokShorts, .instagramReels: .portrait
        }
    }

    /// Resolves this platform's export settings against a canvas.
    ///
    /// This chooses codec and size only. It does not promise a bitrate, because the SDR export
    /// path hands the encode to AVFoundation and exposes no bitrate control.
    func exportDelivery(canvas: CGSize) -> ExportDelivery {
        let codec: VideoCodec
        let resolution: ExportResolution
        switch self {
        case .generic:
            codec = .h264
            resolution = .matchTimeline
        case .youtube:
            codec = .h264
            resolution = .r1080p
        case .tiktokShorts, .instagramReels:
            codec = .h264
            resolution = .r1080p
        }
        let canvasIsPortrait = canvas.height > canvas.width
        var warning: String?
        switch (preferredOrientation, canvasIsPortrait) {
        case (.portrait, false):
            warning = "\(canvas.width)x\(canvas.height) is landscape, but \(rawValue) is delivered "
                + "portrait. Set the canvas to 9:16 with set_project_settings, or apply_layout, "
                + "or the upload will letterbox."
        case (.landscape, true):
            warning = "\(canvas.width)x\(canvas.height) is portrait, but \(rawValue) is delivered "
                + "landscape. Set the canvas with set_project_settings, or apply_layout, if that "
                + "is not what you want."
        case (.either, _), (.portrait, true), (.landscape, false):
            warning = nil
        }
        return ExportDelivery(
            codec: codec,
            resolution: resolution,
            outputSize: resolution.renderSize(for: canvas),
            orientationWarning: warning
        )
    }

    /// The encode profile for this platform: the knobs AVFoundation's preset surface does not
    /// control (CRF, audio codec, frame rate, pixel format), plus platform-imposed limits
    /// (max file size, max duration) and the caption format.
    ///
    /// This is additive to `exportDelivery(canvas:)` — that method owns codec/resolution/orientation,
    /// this owns everything else. Values follow the same platform conventions as OpenMontage's
    /// `lib/media_profiles.py`, reimplemented here; no OpenMontage source is copied.
    func exportProfile(for canvas: CGSize) -> ExportProfile {
        DeliveryPlatform.allProfiles[rawValue] ?? .genericHD
    }
}

/// Encode profile for a delivery platform: the knobs AVFoundation's preset surface does not
/// control, plus platform-imposed limits and the caption format.
///
/// `crf` is the Constant Rate Factor (0–51, lower = higher quality). It is guidance surfaced
/// in the export receipt, not a knob AVFoundation's SDR export session exposes directly.
struct ExportProfile: Sendable, Equatable {
    /// Human-readable name, mirroring OpenMontage's media profile names.
    var name: String
    /// Target frame rate in fps.
    var fps: Int
    /// Audio codec.
    var audioCodec: String
    /// Constant Rate Factor, 0–51 (lower = higher quality).
    var crf: Int
    /// Pixel format.
    var pixelFormat: String
    /// Maximum file size in MB, if the platform imposes one.
    var maxFileSizeMB: Double?
    /// Maximum duration in seconds, if the platform imposes one.
    var maxDurationSeconds: Double?
    /// Caption/subtitle format.
    var captionFormat: String
    /// One-line description of the profile's intent.
    var notes: String
}

extension ExportProfile {
    /// YouTube standard HD upload — long-form, no duration cap.
    static let youtubeHD = ExportProfile(
        name: "youtube_landscape",
        fps: 30,
        audioCodec: "aac",
        crf: 18,
        pixelFormat: "yuv420p",
        captionFormat: "srt",
        notes: "YouTube standard HD upload"
    )

    /// YouTube 4K upload.
    static let youtube4K = ExportProfile(
        name: "youtube_4k",
        fps: 30,
        audioCodec: "aac",
        crf: 18,
        pixelFormat: "yuv420p",
        captionFormat: "srt",
        notes: "YouTube 4K upload"
    )

    /// YouTube Shorts — vertical, max 60s.
    static let youtubeShorts = ExportProfile(
        name: "youtube_shorts",
        fps: 30,
        audioCodec: "aac",
        crf: 20,
        pixelFormat: "yuv420p",
        maxDurationSeconds: 60,
        captionFormat: "srt",
        notes: "YouTube Shorts (max 60s, vertical)"
    )

    /// Instagram Reels — vertical, max 90s, max 250 MB.
    static let instagramReels = ExportProfile(
        name: "instagram_reels",
        fps: 30,
        audioCodec: "aac",
        crf: 20,
        pixelFormat: "yuv420p",
        maxFileSizeMB: 250,
        maxDurationSeconds: 90,
        captionFormat: "srt",
        notes: "Instagram Reels (max 90s, vertical)"
    )

    /// Instagram feed — square, max 60s, max 250 MB.
    static let instagramFeed = ExportProfile(
        name: "instagram_feed",
        fps: 30,
        audioCodec: "aac",
        crf: 20,
        pixelFormat: "yuv420p",
        maxFileSizeMB: 250,
        maxDurationSeconds: 60,
        captionFormat: "srt",
        notes: "Instagram feed video (square)"
    )

    /// TikTok — vertical, max 10 min, max 287 MB.
    static let tiktok = ExportProfile(
        name: "tiktok",
        fps: 30,
        audioCodec: "aac",
        crf: 20,
        pixelFormat: "yuv420p",
        maxFileSizeMB: 287,
        maxDurationSeconds: 600,
        captionFormat: "srt",
        notes: "TikTok (max 10min, vertical preferred)"
    )

    /// LinkedIn — landscape, max 10 min, max 5 GB.
    static let linkedin = ExportProfile(
        name: "linkedin",
        fps: 30,
        audioCodec: "aac",
        crf: 20,
        pixelFormat: "yuv420p",
        maxFileSizeMB: 5120,
        maxDurationSeconds: 600,
        captionFormat: "srt",
        notes: "LinkedIn video (landscape preferred, max 10min)"
    )

    /// Cinematic ultra-wide — 21:9, 24 fps, high quality.
    static let cinematic = ExportProfile(
        name: "cinematic",
        fps: 24,
        audioCodec: "aac",
        crf: 16,
        pixelFormat: "yuv420p",
        captionFormat: "srt",
        notes: "Cinematic ultra-wide format"
    )

    /// Generic HD output — no platform-specific constraints.
    static let genericHD = ExportProfile(
        name: "generic_hd",
        fps: 30,
        audioCodec: "aac",
        crf: 23,
        pixelFormat: "yuv420p",
        captionFormat: "srt",
        notes: "Generic HD output (no platform-specific constraints)"
    )
}

extension DeliveryPlatform {
    /// All encode profiles, keyed by platform raw value. CompositorPro's four platforms each map
    /// to one profile; the remaining OpenMontage profiles (YouTube 4K, Instagram Feed, LinkedIn,
    /// Cinematic) are available for future platform cases.
    static let allProfiles: [String: ExportProfile] = [
        DeliveryPlatform.generic.rawValue: .genericHD,
        DeliveryPlatform.youtube.rawValue: .youtubeHD,
        DeliveryPlatform.tiktokShorts.rawValue: .tiktok,
        DeliveryPlatform.instagramReels.rawValue: .instagramReels,
    ]
}
