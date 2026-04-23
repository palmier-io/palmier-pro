import AppKit
import AVFoundation

/// Media library bookkeeping: import, rename, and manifest metadata sync for
/// the in-memory asset catalog and the persisted `MediaManifest`.
extension EditorViewModel {

    func importMediaAsset(_ asset: MediaAsset, skipAppend: Bool = false) {
        if !skipAppend {
            mediaAssets.append(asset)
        }
        let entry = asset.toManifestEntry(projectURL: projectURL)
        mediaManifest.entries.append(entry)
    }

    /// Resolve a drag pasteboard payload (one URL per line)
    func assetsFromDragPayload(_ payload: String) -> [MediaAsset] {
        payload.split(separator: "\n").compactMap { str in
            mediaAssets.first { $0.url.absoluteString == str }
        }
    }

    @discardableResult
    func addMediaAsset(from url: URL) -> MediaAsset? {
        guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let asset = MediaAsset(url: url, type: type, name: name)
        importMediaAsset(asset)
        Task { await finalizeImportedAsset(asset) }
        return asset
    }

    @discardableResult
    func importPastedImageData(_ data: Data, fileExtension: String = "png") -> MediaAsset? {
        let filename = "pasted-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        let destURL: URL
        if let projectURL {
            let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            destURL = mediaDir.appendingPathComponent(filename)
        } else {
            destURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        }
        do {
            try data.write(to: destURL)
        } catch {
            Log.project.error("importPastedImageData: write failed \(error.localizedDescription)")
            return nil
        }
        return addMediaAsset(from: destURL)
    }

    func renameMediaAsset(id: String, name: String) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        let oldName = asset.name
        asset.name = name
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            mediaManifest.entries[idx].name = name
        }
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.renameMediaAsset(id: id, name: oldName)
        }
        undoManager?.setActionName("Rename Asset")
    }

    func updateManifestMetadata(for asset: MediaAsset) {
        if let idx = mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
            mediaManifest.entries[idx].duration = asset.duration
            mediaManifest.entries[idx].sourceWidth = asset.sourceWidth
            mediaManifest.entries[idx].sourceHeight = asset.sourceHeight
            mediaManifest.entries[idx].sourceFPS = asset.sourceFPS
            mediaManifest.entries[idx].hasAudio = asset.hasAudio
        }
    }

    /// Render the current timeline frame through the preview composition and
    /// import it as a PNG in the media panel.
    func captureCurrentFrameToMedia() {
        guard let currentItem = videoEngine?.player.currentItem else {
            Log.project.error("captureCurrentFrameToMedia: no preview item")
            return
        }
        let asset = currentItem.asset
        let videoComposition = currentItem.videoComposition
        let fps = timeline.fps
        let frame = currentFrame
        let maxSize = CGSize(width: timeline.width, height: timeline.height)
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))

        Task.detached {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.videoComposition = videoComposition
            generator.maximumSize = maxSize

            let cgImage: CGImage
            do {
                cgImage = try await generator.image(at: time).image
            } catch {
                Log.project.error("captureCurrentFrameToMedia: generate failed \(error.localizedDescription)")
                return
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                Log.project.error("captureCurrentFrameToMedia: png encode failed")
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let mediaAsset = self.importPastedImageData(data, fileExtension: "png") else { return }
                mediaAsset.name = "Frame \(frame)"
                if let idx = self.mediaManifest.entries.firstIndex(where: { $0.id == mediaAsset.id }) {
                    self.mediaManifest.entries[idx].name = mediaAsset.name
                }
            }
        }
    }

    func finalizeImportedAsset(_ asset: MediaAsset) async {
        await asset.loadMetadata()
        updateManifestMetadata(for: asset)
        switch asset.type {
        case .video:
            mediaVisualCache.generateWaveform(for: asset)
            mediaVisualCache.generateThumbnails(for: asset, fps: timeline.fps)
        case .audio:
            mediaVisualCache.generateWaveform(for: asset)
        case .image:
            mediaVisualCache.generateImageThumbnail(for: asset)
        }
    }
}
