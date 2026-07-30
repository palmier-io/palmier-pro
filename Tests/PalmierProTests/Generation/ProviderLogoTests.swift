import Foundation
import Testing
@testable import PalmierPro

@Suite("ProviderLogo")
@MainActor
struct ProviderLogoTests {
    @Test("Catalog entries use the backend-provided icon key")
    func decodesCatalogIconKey() throws {
        let data = Data(#"""
        {
          "id": "fixture",
          "kind": "image",
          "displayName": "Fixture",
          "providerIconKey": "google",
          "allowedEndpoints": ["opaque-endpoint"],
          "responseShape": "images",
          "uiCapabilities": {
            "resolutions": null,
            "aspectRatios": [],
            "qualities": null,
            "supportsImageReference": false,
            "maxImages": 1
          }
        }
        """#.utf8)

        let entry = try JSONDecoder().decode(CatalogEntry.self, from: data)

        #expect(entry.providerIconKey == "google")
        #expect(ProviderLogo.hasBundledLogo(for: entry.providerIconKey ?? ""))
    }

    @Test("Unknown backend icon keys fall back safely")
    func rejectsUnknownIconKey() {
        #expect(!ProviderLogo.hasBundledLogo(for: "new-provider"))
        #expect(!ProviderLogo.hasBundledLogo(for: "../google"))
    }
}
