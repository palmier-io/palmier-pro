import Foundation
import Testing
@testable import PalmierPro

@Suite("EditorIconLoader")
struct EditorIconLoaderTests {
    @Test(
        arguments: [
            ("com.adobe.PremierePro.26", ExportEditorApplication.premierePro as ExportEditorApplication?),
            ("com.blackmagic-design.DaVinciResolve", .davinciResolve),
            ("com.apple.FinalCut", .finalCutPro),
            ("com.apple.FinalCutApp", .finalCutPro),
            ("com.example.VideoEditor", nil),
        ]
    )
    func identifiesSupportedEditor(
        bundleIdentifier: String,
        expected: ExportEditorApplication?
    ) {
        #expect(EditorIconLoader.editor(forBundleIdentifier: bundleIdentifier) == expected)
    }

    @Test func loadsIconFromNestedApplicationBundle() async throws {
        let iconData = Data("icon".utf8)
        let icons = try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("export-editor-icons-\(UUID())", isDirectory: true)
            defer { try? fileManager.removeItem(at: root) }

            let applicationURL = root
                .appendingPathComponent("Video Editors", isDirectory: true)
                .appendingPathComponent("Final Cut Pro.app", isDirectory: true)
            let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
            let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
            try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

            try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleIdentifier": "com.apple.FinalCutApp",
                    "CFBundleIconFile": "AppIcon.png",
                ],
                format: .xml,
                options: 0
            )
            .write(to: contentsURL.appendingPathComponent("Info.plist"))
            try iconData.write(to: resourcesURL.appendingPathComponent("AppIcon.png"))

            return await EditorIconLoader.loadIconData(searchDirectories: [root])
        }.value

        #expect(icons[.finalCutPro] == iconData)
    }
}
