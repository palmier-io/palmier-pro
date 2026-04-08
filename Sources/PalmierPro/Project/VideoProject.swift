import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

final class VideoProject: NSDocument {

    let editorViewModel = EditorViewModel()

    /// Timeline decoded in read(from:ofType:), applied on main in makeWindowControllers
    private nonisolated(unsafe) var loadedTimeline: Timeline?

    // MARK: - NSDocument overrides

    override class var autosavesInPlace: Bool { true }

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard let projectData = fileWrapper.fileWrappers?["project.json"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        loadedTimeline = try JSONDecoder().decode(Timeline.self, from: projectData)
    }

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let dir = FileWrapper(directoryWithFileWrappers: [:])
        let data = try JSONEncoder().encode(editorViewModel.timeline)
        dir.addRegularFile(withContents: data, preferredFilename: "project.json")
        // media/ folder is managed on disk alongside project.json — FileWrapper picks it up automatically
        return dir
    }

    override func makeWindowControllers() {
        if let loaded = loadedTimeline {
            editorViewModel.timeline = loaded
            loadedTimeline = nil
        }
        editorViewModel.undoManager = undoManager

        let editorView = EditorView()
            .environment(editorViewModel)

        let hostingController = NSHostingController(rootView: editorView)
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.minSize = NSSize(width: 960, height: 600)
        window.title = "Palmier Pro"
        window.setFrameAutosaveName("PalmierProWindow")
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.center()

        let exportButton = NSButton(title: "Export", target: nil, action: #selector(EditorActions.showExport(_:)))
        exportButton.bezelStyle = .recessed
        exportButton.isBordered = true
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        exportButton.imagePosition = .imageLeading
        exportButton.controlSize = .small
        exportButton.font = .systemFont(ofSize: 12, weight: .medium)
        exportButton.sizeToFit()

        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: exportButton.fittingSize.width + 16, height: 28))
        exportButton.frame.origin.x = 8
        exportButton.frame.origin.y = (wrapper.frame.height - exportButton.fittingSize.height) / 2
        wrapper.addSubview(exportButton)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = wrapper
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)

        let controller = EditorWindowController(editorViewModel: editorViewModel, window: window)
        controller.shouldCascadeWindows = true
        controller.installKeyMonitor()
        addWindowController(controller)

        if let fileURL {
            Task { @MainActor in
                await scanMedia(projectURL: fileURL)
            }
        }
    }

    // MARK: - Media scanning

    private func scanMedia(projectURL: URL) async {
        let mediaDir = projectURL.appendingPathComponent("media", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: mediaDir, includingPropertiesForKeys: nil
        ) else { return }

        for url in contents {
            guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let asset = MediaAsset(url: url, type: type, name: name)
            editorViewModel.mediaAssets.append(asset)
            await asset.loadMetadata()
        }
    }
}
