import Foundation
import Testing
@testable import CompositorPro

@Suite("Delivery platform layout")
struct DeliveryPlatformTests {
    @Test("Generic reproduces the historical caption placement exactly")
    func genericIsUnchanged() {
        let placement = DeliveryPlatform.generic.defaultCaptionPlacement()
        #expect(abs(placement.centerY - 0.90) < 1e-9)
        #expect(abs(placement.maxWidth - 0.90) < 1e-9)
        #expect(placement.centerX == 0.5)
    }

    @Test(
        "Platforms with a bottom interface lift captions clear of it",
        arguments: [DeliveryPlatform.tiktokShorts, .instagramReels]
    )
    func bottomInterfaceLiftsCaption(platform: DeliveryPlatform) {
        let placement = platform.defaultCaptionPlacement()
        #expect(
            placement.centerY < DeliveryPlatform.generic.defaultCaptionPlacement().centerY,
            "\(platform.rawValue) must sit higher than the unencumbered default"
        )
        let rect = platform.coveredArea.captionSafeRect
        #expect(placement.centerY <= rect.maxY)
        #expect(placement.centerY > rect.minY)
    }

    @Test(
        "A right-hand interface narrows the caption",
        arguments: [DeliveryPlatform.youtube, .tiktokShorts, .instagramReels]
    )
    func sideInterfaceNarrowsCaption(platform: DeliveryPlatform) {
        let area = platform.coveredArea
        let placement = platform.defaultCaptionPlacement()
        #expect(placement.maxWidth < 1 - area.left, "caption must stay inside the left inset")
        #expect(abs(placement.maxWidth - (1 - area.left - area.right)) < 1e-9)
        #expect(
            placement.maxWidth < DeliveryPlatform.generic.defaultCaptionPlacement().maxWidth,
            "\(platform.rawValue) must be narrower than the unencumbered default"
        )
    }

    @Test("Only generic is treated as exact; every real platform is flagged an estimate")
    func estimatesAreLabelled() {
        #expect(DeliveryPlatform.generic.coveredAreaIsEstimate == false)
        for platform in DeliveryPlatform.allCases where platform != .generic {
            #expect(platform.coveredAreaIsEstimate, "\(platform.rawValue) must be marked an estimate")
        }
    }

    @Test("No platform covers the whole picture")
    func coverageLeavesUsableArea() {
        for platform in DeliveryPlatform.allCases {
            let rect = platform.coveredArea.captionSafeRect
            #expect(rect.width > 0.3, "\(platform.rawValue) leaves no usable width")
            #expect(rect.height > 0.3, "\(platform.rawValue) leaves no usable height")
        }
    }

    @Test("A caption asked for at the very bottom is lifted into the safe area")
    func clampsOffScreenRequest() {
        let platform = DeliveryPlatform.tiktokShorts
        let requested = DeliveryPlatform.CaptionPlacement(centerX: 0.5, centerY: 0.98, maxWidth: 0.9)
        let clamped = requested.clamped(into: platform.coveredArea)
        let rect = platform.coveredArea.captionSafeRect
        #expect(clamped.centerY < 1 - platform.coveredArea.bottom)
        #expect(clamped.centerY <= rect.maxY)
        #expect(clamped.maxWidth <= rect.width)
    }

    @Test("A caption asked for inside the safe area is left alone")
    func leavesValidPlacementAlone() {
        let platform = DeliveryPlatform.instagramReels
        let inside = platform.defaultCaptionPlacement()
        #expect(inside.clamped(into: platform.coveredArea) == inside)
    }

    @Test("Clamping never invents width outside the safe area")
    func clampDoesNotWiden() {
        let platform = DeliveryPlatform.youtube
        let narrow = DeliveryPlatform.CaptionPlacement(centerX: 0.5, centerY: 0.7, maxWidth: 0.1)
        #expect(narrow.clamped(into: platform.coveredArea).maxWidth == 0.1)
    }

    @Test("Edge fractions outside 0...1 are clamped rather than rejected")
    func edgeFractionsStayInRange() {
        let edges = DeliveryPlatform.EdgeFractions(top: -1, bottom: 5, left: 2, right: 0.5)
        #expect(edges.top == 0)
        #expect(edges.bottom == 1)
        #expect(edges.left == 1)
        #expect(edges.right == 0.5)
        #expect(edges.captionSafeRect.width >= 0.01, "a degenerate area still yields a usable rect")
    }

    @Test("A non-finite request resolves to the safe area instead of propagating NaN")
    func nonFiniteResolves() {
        let platform = DeliveryPlatform.tiktokShorts
        let broken = DeliveryPlatform.CaptionPlacement(centerX: .nan, centerY: .infinity, maxWidth: .nan)
        let clamped = broken.clamped(into: platform.coveredArea)
        #expect(clamped.centerX.isFinite)
        #expect(clamped.centerY.isFinite)
        #expect(clamped.maxWidth.isFinite)
    }

    @Test("The caption spec width the rest of the app uses is the same number")
    func singleSourceForWidth() {
        #expect(
            AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio
                == CGFloat(DeliveryPlatform.generic.defaultCaptionPlacement().maxWidth)
        )
        #expect(
            AppTheme.Caption.defaultCenterY
                == CGFloat(DeliveryPlatform.generic.defaultCaptionPlacement().centerY)
        )
    }

    // MARK: - Export profile

    @Test("Every platform resolves to an encode profile")
    func everyPlatformHasProfile() {
        let canvas = CGSize(width: 1920, height: 1080)
        for platform in DeliveryPlatform.allCases {
            let profile = platform.exportProfile(for: canvas)
            #expect(!profile.name.isEmpty)
            #expect(profile.fps > 0)
            #expect(!profile.audioCodec.isEmpty)
            #expect((1...51).contains(profile.crf), "\(profile.name) CRF \(profile.crf) out of range")
            #expect(!profile.pixelFormat.isEmpty)
            #expect(!profile.captionFormat.isEmpty)
            #expect(!profile.notes.isEmpty)
        }
    }

    @Test("Generic uses the generic HD profile")
    func genericProfile() {
        let profile = DeliveryPlatform.generic.exportProfile(for: .zero)
        #expect(profile == .genericHD)
        #expect(profile.name == "generic_hd")
        #expect(profile.crf == 23)
        #expect(profile.fps == 30)
        #expect(profile.audioCodec == "aac")
        #expect(profile.pixelFormat == "yuv420p")
        #expect(profile.captionFormat == "srt")
        #expect(profile.maxDurationSeconds == nil)
        #expect(profile.maxFileSizeMB == nil)
    }

    @Test("YouTube uses high quality, no duration cap")
    func youtubeProfile() {
        let profile = DeliveryPlatform.youtube.exportProfile(for: .zero)
        #expect(profile.name == "youtube_landscape")
        #expect(profile.crf == 18)
        #expect(profile.maxDurationSeconds == nil)
        #expect(profile.maxFileSizeMB == nil)
    }

    @Test("TikTok Shorts imposes duration and file-size caps")
    func tiktokProfile() {
        let profile = DeliveryPlatform.tiktokShorts.exportProfile(for: .zero)
        #expect(profile.name == "tiktok")
        #expect(profile.crf == 20)
        #expect(profile.maxDurationSeconds == 600)
        #expect(profile.maxFileSizeMB == 287)
    }

    @Test("Instagram Reels imposes duration and file-size caps")
    func instagramReelsProfile() {
        let profile = DeliveryPlatform.instagramReels.exportProfile(for: .zero)
        #expect(profile.name == "instagram_reels")
        #expect(profile.crf == 20)
        #expect(profile.maxDurationSeconds == 90)
        #expect(profile.maxFileSizeMB == 250)
    }

    @Test("Profile lookup is stable across canvases")
    func profileIndependentOfCanvas() {
        let landscape = DeliveryPlatform.youtube.exportProfile(for: CGSize(width: 1920, height: 1080))
        let portrait = DeliveryPlatform.youtube.exportProfile(for: CGSize(width: 1080, height: 1920))
        #expect(landscape == portrait)
    }

    @Test("Named profiles are distinct where expected")
    func namedProfilesDistinct() {
        #expect(ExportProfile.youtubeHD != ExportProfile.youtubeShorts)
        #expect(ExportProfile.youtubeHD != ExportProfile.genericHD)
        #expect(ExportProfile.tiktok != ExportProfile.instagramReels)
    }
}