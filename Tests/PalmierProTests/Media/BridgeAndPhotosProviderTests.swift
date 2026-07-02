import Foundation
import Testing
@testable import PalmierPro

@Suite("BridgeProvider mapping")
struct BridgeProviderTests {
    private var jianying: BridgeProvider {
        BridgeProvider(id: "jianying", label: "剪映素材", baseURL: URL(string: "http://127.0.0.1:5174")!)
    }

    @Test func splitsMusicAndSfxByKind() {
        let rows: [[String: Any]] = [
            ["sha256": "a1", "rel": "music/song.mp3", "userTitle": "My Song", "durationMs": 90000],
            ["sha256": "b2", "rel": "sfx/whoosh.wav", "kind": "sfx", "name": "whoosh", "sfxCat": ["transition"]],
        ]
        let music = jianying.mapForTesting(.music, rows)
        let sfx = jianying.mapForTesting(.sfx, rows)
        #expect(music.count == 1)
        #expect(music[0].name == "My Song")
        #expect(music[0].ref == "music/song.mp3")
        #expect(music[0].type == .music)
        #expect(music[0].durationMs == 90000)
        #expect(sfx.count == 1)
        #expect(sfx[0].ref == "sfx/whoosh.wav")
        #expect(sfx[0].type == .sfx)
    }

    @Test func imageMapsRelToName() {
        let cards = jianying.mapForTesting(.image, [["rel": "images/frame_01.png", "sourceLabel": "AI"]])
        #expect(cards.count == 1)
        #expect(cards[0].name == "frame_01.png")
        #expect(cards[0].ref == "images/frame_01.png")
        #expect(cards[0].thumbnailRef == "images/frame_01.png")
    }

    @Test func fetchURLEncodesRelAsQueryParam() {
        let url = jianying.fetchURL(forRef: "music/a b.mp3")
        #expect(url?.absoluteString == "http://127.0.0.1:5174/cache-file?p=music/a%20b.mp3")
    }
}

@Suite("PhotosProvider mapping")
struct PhotosProviderTests {
    private var photos: PhotosProvider { PhotosProvider(baseURL: URL(string: "http://127.0.0.1:5374")!) }

    @Test func videoRowMapsToEndpointRefsNoExtension() {
        let row: [String: Any] = ["id": "UUID-1", "filename": "IMG_0001.mov", "durationSec": 12.4, "orientation": "portrait"]
        let c = photos.card(from: row, type: .video, fileBase: "/video/", thumbBase: "/thumb/")
        #expect(c?.ref == "/video/UUID-1")           // no extension — import relies on typeHint
        #expect(c?.thumbnailRef == "/thumb/UUID-1")
        #expect(c?.name == "IMG_0001.mov")
        #expect(c?.durationMs == 12400)
        #expect(c?.isLocal == true)
        #expect(photos.fetchURL(forRef: "/video/UUID-1")?.absoluteString == "http://127.0.0.1:5374/video/UUID-1")
    }

    @Test func iCloudOnlyOriginalIsNotLocal() {
        let row: [String: Any] = ["id": "U2", "filename": "x.heic", "local": false, "isLivePhoto": true]
        let c = photos.card(from: row, type: .image, fileBase: "/image/", thumbBase: "/image-thumb/")
        #expect(c?.isLocal == false)
        #expect(c?.description?.contains("iCloud") == true)
        #expect(c?.description?.contains("LIVE") == true)
    }
}
