import Foundation
import Testing
@testable import PalmierPro

// Mapping is validated against real rows captured from the live galleries so the
// field wiring can't silently drift.
@Suite("GalleryProvider")
struct GalleryProviderTests {

    private func provider(_ kind: GalleryProvider.Kind) -> GalleryProvider {
        GalleryProvider(
            id: kind == .downloads ? "downloads" : "projects",
            label: "x",
            baseURL: URL(string: "http://127.0.0.1:4617")!,
            listPath: "/api/videos",
            kind: kind
        )
    }

    @Test func downloadsRowMapsToCard() {
        let row: [String: Any] = [
            "id": "6a45b2af000000000f01e21f",
            "source": "xhs",
            "title": "如何用 Codex 自动化发布多平台视频",
            "author": "小红黍",
            "durationSec": 340.33,
            "resolution": "960x720",
            "cardAspect": "4 / 3",
            "src": "/media/xhs/6a45b2af000000000f01e21f/video.mp4",
            "poster": "/media/xhs/6a45b2af000000000f01e21f/cover.jpg",
        ]
        let p = provider(.downloads)
        let cards = p.mapRowsForTesting([row])
        #expect(cards.count == 1)
        let c = cards[0]
        #expect(c.id == "6a45b2af000000000f01e21f")
        #expect(c.type == .video)
        #expect(c.name == "如何用 Codex 自动化发布多平台视频")
        #expect(c.ref == "/media/xhs/6a45b2af000000000f01e21f/video.mp4")
        #expect(c.thumbnailRef == "/media/xhs/6a45b2af000000000f01e21f/cover.jpg")
        #expect(c.durationMs == 340330)
        #expect(c.aspect == "4 / 3")
        #expect(c.isLocal)
        #expect(c.description == "xhs · 小红黍 · 960x720")
        #expect(p.fetchURL(forRef: c.ref)?.absoluteString
            == "http://127.0.0.1:4617/media/xhs/6a45b2af000000000f01e21f/video.mp4")
    }

    @Test func projectsRowMapsAndDropsDrafts() {
        let rendered: [String: Any] = [
            "id": "ovinyl-fable5-showcase",
            "title": "ovinyl-fable5-showcase",
            "source": "hf",
            "video": "/media/ovinyl-fable5-showcase/ovinyl-showcase.mp4",
            "ratio": "9:16",
            "dims": "1080×1920",
            "cover": NSNull(),
        ]
        let draft: [String: Any] = ["id": "wip", "title": "no render yet"]
        let cards = provider(.projects).mapRowsForTesting([rendered, draft])
        #expect(cards.count == 1)
        let c = cards[0]
        #expect(c.id == "ovinyl-fable5-showcase")
        #expect(c.ref == "/media/ovinyl-fable5-showcase/ovinyl-showcase.mp4")
        #expect(c.thumbnailRef == nil)          // cover was null
        #expect(c.aspect == "9 / 16")
        #expect(c.description == "1080×1920 · hf")
    }

    @Test func keysAndMatchClientSide() {
        let rows: [[String: Any]] = [
            ["id": "1", "src": "/media/a.mp4", "title": "douyin howto", "source": "douyin"],
            ["id": "2", "src": "/media/b.mp4", "title": "cat video", "source": "xhs"],
        ]
        let p = provider(.downloads)
        #expect(p.filterForTesting(rows, keys: ["douyin"]).count == 1)
        #expect(p.filterForTesting(rows, keys: ["douyin", "howto"]).count == 1)
        #expect(p.filterForTesting(rows, keys: ["douyin", "cat"]).count == 0)
        #expect(p.filterForTesting(rows, keys: []).count == 2)
    }
}
