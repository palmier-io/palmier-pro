import Foundation
import Testing
@testable import CompositorPro

@Suite("Feature catalog")
struct FeatureCatalogTests {
    private var categories: [FeatureCatalog.Category] { FeatureCatalog.categories }

    private var features: [FeatureCatalog.Feature] { categories.flatMap(\.features) }

    @Test("Category and feature identifiers are unique, so nothing is shadowed in the UI")
    func identifiersAreUnique() {
        let categoryIDs = categories.map(\.id)
        #expect(Set(categoryIDs).count == categoryIDs.count, "duplicate category id")
        let featureIDs = features.map(\.id)
        #expect(Set(featureIDs).count == featureIDs.count, "duplicate feature id")
    }

    @Test("No feature offers the same example request as another")
    func howToIsDistinct() {
        let requests = features.map(\.howTo)
        #expect(Set(requests).count == requests.count, "duplicate example request")
    }

    @Test("Every category has something in it")
    func categoriesArePopulated() {
        #expect(!categories.isEmpty)
        for category in categories {
            #expect(!category.features.isEmpty, "\(category.id) is empty")
        }
    }

    @Test("Every feature carries copy, and the summary says something")
    func featuresAreWritten() {
        for feature in features {
            #expect(!feature.title.isEmpty, "\(feature.id) has no title")
            #expect(!feature.summary.isEmpty, "\(feature.id) has no summary")
            // A one-word "summary" is a placeholder, not documentation.
            #expect(
                feature.summary.count > 40,
                "\(feature.id) summary is too short to be useful: \(feature.summary)"
            )
            // A howTo that is not a request teaches nothing.
            let howTo = feature.howTo
            #expect(howTo.count > 20, "\(feature.id) has no usable example request")
        }
    }

    @Test("Category titles and icons are set")
    func categoriesAreLabelled() {
        for category in categories {
            #expect(!category.title.isEmpty, "\(category.id) has no title")
            #expect(!category.icon.isEmpty, "\(category.id) has no icon")
        }
    }

    /// The point of naming tools on each feature: a renamed or withdrawn tool fails here rather
    /// than leaving the page advertising something that no longer exists.
    @Test("Every tool a feature names is actually exposed by the app")
    func namedToolsAreExposed() {
        let exposed = Set(
            (ToolDefinitions.mcpServer + ToolDefinitions.inAppAgent).map(\.name)
        )
        for feature in features {
            for tool in feature.tools {
                #expect(
                    exposed.contains(tool),
                    "\(feature.id) names \(tool.rawValue), which no surface exposes"
                )
            }
        }
    }

    @Test("Every documented tool appears in exactly one feature")
    func toolsAreNotDocumentedTwice() {
        var seen: [ToolName: String] = [:]
        for feature in features {
            for tool in feature.tools {
                if let owner = seen[tool] {
                    #expect(
                        owner == feature.id,
                        "\(tool.rawValue) is documented under both \(owner) and \(feature.id)"
                    )
                }
                seen[tool] = feature.id
            }
        }
    }

}
