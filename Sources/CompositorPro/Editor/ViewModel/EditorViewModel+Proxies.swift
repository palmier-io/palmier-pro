import Foundation

extension EditorViewModel {
    func proxyStoreIfPresent() -> ProxyStore? { proxyStore }

    /// Attaches the store for the open project. Call when a project finishes opening.
    func prepareProxyStore(projectDirectory: URL) {
        let store = ProxyStore(root: projectDirectory.appendingPathComponent("proxies", isDirectory: true))
        proxyStore = store
        let valid = Set(mediaAssets.map(\.id))
        Task.detached(priority: .utility) { await store.prune(validMediaRefs: valid) }
        // A reopened project starts with no overrides; the Agent regenerates or lists them.
        proxyURLOverrides = [:]
    }

    func detachProxyStore() {
        proxyStore = nil
        proxyURLOverrides = [:]
    }

    /// Media URLs for preview. Export builds its own map from the project package and therefore
    /// never sees a proxy, which is the point: a proxy must not be able to reach a master render.
    func previewURLMap() -> [String: URL] {
        guard !proxyURLOverrides.isEmpty else { return mediaResolver.expectedURLMap() }
        var resolved = mediaResolver.expectedURLMap()
        for (ref, proxy) in proxyURLOverrides { resolved[ref] = proxy }
        return resolved
    }

    /// Records a freshly validated proxy so preview picks it up on the next rebuild.
    func adoptProxy(mediaRef: String, url: URL) {
        proxyURLOverrides[mediaRef] = url
    }

    func dropProxyOverride(mediaRef: String) {
        proxyURLOverrides.removeValue(forKey: mediaRef)
    }
}
