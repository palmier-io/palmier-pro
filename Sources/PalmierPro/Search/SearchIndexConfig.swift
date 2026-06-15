import Foundation

enum SearchIndexConfig {
    static let enabledDefaultsKey = "searchIndexEnabled"
    static let visualMatchCosineFloor: Float = 0.05
    static let hostedURL = URL(string: "https://huggingface.co/palmier-io/siglip2-base-coreml/resolve/main")!

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledDefaultsKey) }
    }

    static var baseURL: URL {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "searchIndexModelBaseURL"), let url = URL(string: raw) {
            return url
        }
        #endif
        return hostedURL
    }

    static let manifest = ModelDownloader.Manifest(
        model: "siglip2-base-patch16-256",
        version: 1,
        embeddingDim: 768,
        imageSize: 256,
        contextLength: 64,
        files: .init(
            imageEncoder: .init(
                name: "ImageEncoder.mlpackage.zip",
                sha256: "426115f240ead5faf69b073e08dd1b959d850ca5c592537cd81886992283b2fb",
                bytes: 91_700_398
            ),
            textEncoder: .init(
                name: "TextEncoder.mlpackage.zip",
                sha256: "48f80e35ce40a9dcdc55bef986a104d3153e1cfa78229bb45c4724f3f3427368",
                bytes: 258_593_083
            ),
            tokenizer: .init(
                name: "tokenizer.zip",
                sha256: "c37f2a8e8555d8561109564c4f60ee962b0072abddcfcfd599d321469d6d1ef5",
                bytes: 5_460_173
            )
        )
    )
}
