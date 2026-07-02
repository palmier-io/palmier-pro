import Foundation

// Static list of external media sources. Adding a source is one entry (mirrors
// orca-vvcut's registry.ts). Ports are env-overridable with the documented defaults.
enum AssetProviderRegistry {
    static let providers: [any AssetProvider] = [
        GalleryProvider(
            id: "downloads", label: "下载素材",
            baseURL: envURL("DOWNLOADS_GALLERY_URL", default: "http://127.0.0.1:4617"),
            listPath: "/api/videos", kind: .downloads
        ),
        GalleryProvider(
            id: "projects", label: "自制成片",
            baseURL: envURL("PROJECTS_GALLERY_URL", default: "http://127.0.0.1:4618"),
            listPath: "/api/projects", kind: .projects
        ),
        PhotosProvider(baseURL: envURL("PHOTOS_BRIDGE_URL", default: "http://127.0.0.1:5374")),
        BridgeProvider(id: "jianying", label: "剪映素材",
                       baseURL: envURL("JIANYING_BRIDGE_URL", default: "http://127.0.0.1:5174")),
        BridgeProvider(id: "capcut", label: "CapCut 素材",
                       baseURL: envURL("CAPCUT_BRIDGE_URL", default: "http://127.0.0.1:5274")),
    ]

    static func provider(_ id: String) -> (any AssetProvider)? {
        providers.first { $0.id == id }
    }

    // A loopback URL is importable only when its host+port match a registered provider.
    static func isRegisteredLoopback(_ url: URL) -> Bool {
        guard let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host) else { return false }
        return providers.contains { $0.baseURL.host == host && $0.baseURL.port == url.port }
    }

    private static func envURL(_ key: String, default def: String) -> URL {
        let raw = ProcessInfo.processInfo.environment[key] ?? def
        return URL(string: raw) ?? URL(string: def)!
    }
}
