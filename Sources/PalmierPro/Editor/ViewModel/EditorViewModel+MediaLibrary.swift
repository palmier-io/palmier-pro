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

    func fitTextClipToContent(clipId: String) {
        guard let loc = findClip(id: clipId) else { return }
        let clip = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard clip.mediaType == .text else { return }
        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        let natural = TextLayout.naturalSize(
            content: clip.textContent ?? " ",
            style: clip.textStyle ?? TextStyle(),
            maxWidth: CGFloat(canvasW) * 0.9
        )
        let needW = Double(natural.width) / canvasW
        let needH = Double(natural.height) / canvasH
        let currentW = clip.transform.width
        let currentH = clip.transform.height
        if abs(needW - currentW) < 0.0001 && abs(needH - currentH) < 0.0001 { return }
        let tl = clip.transform.topLeft
        let cx = tl.x + currentW / 2
        let cy = tl.y + currentH / 2
        applyClipProperty(clipId: clipId, rebuild: false) {
            $0.transform = Transform(center: (cx, cy), width: needW, height: needH)
        }
    }

    func clipDisplayLabel(for clip: Clip) -> String {
        if clip.mediaType == .text {
            let content = clip.textContent ?? ""
            if content.isEmpty { return "Text" }
            // Timeline label bar is single-line.
            return content
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        return mediaResolver.displayName(for: clip.mediaRef)
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

    /// Capture the current frame as a PNG.
    /// Text is composited via `CALayer.render` — `AVAssetImageGenerator`
    /// doesn't evaluate `animationTool` on single-frame extraction.
    func captureCurrentFrameToMedia() {
        guard let currentItem = videoEngine?.player.currentItem else {
            Log.project.error("captureCurrentFrameToMedia: no preview item")
            return
        }
        let asset = currentItem.asset
        let timelineSnapshot = timeline
        let fps = timeline.fps
        let frame = currentFrame
        let canvas = CGSize(width: timeline.width, height: timeline.height)
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))

        nonisolated(unsafe) let unsafeComposition = currentItem.videoComposition

        Task.detached {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.videoComposition = unsafeComposition
            generator.maximumSize = canvas

            let videoCG: CGImage
            do {
                videoCG = try await generator.image(at: time).image
            } catch {
                Log.project.error("captureCurrentFrameToMedia: generate failed \(error.localizedDescription)")
                return
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                let controller = TextLayerController()
                controller.sync(
                    timeline: timelineSnapshot,
                    fps: fps,
                    canvasSize: canvas,
                    videoRect: CGRect(origin: .zero, size: canvas),
                    currentFrame: frame
                )
                guard let composited = Self.compositeCapture(
                    video: videoCG, textRoot: controller.textRoot, canvas: canvas
                ) else {
                    Log.project.error("captureCurrentFrameToMedia: composite failed")
                    return
                }
                let rep = NSBitmapImageRep(cgImage: composited)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    Log.project.error("captureCurrentFrameToMedia: png encode failed")
                    return
                }
                guard let mediaAsset = self.importPastedImageData(data, fileExtension: "png") else { return }
                mediaAsset.name = "Frame \(frame)"
                if let idx = self.mediaManifest.entries.firstIndex(where: { $0.id == mediaAsset.id }) {
                    self.mediaManifest.entries[idx].name = mediaAsset.name
                }
            }
        }
    }

    private static func compositeCapture(video: CGImage, textRoot: CALayer, canvas: CGSize) -> CGImage? {
        let width = Int(canvas.width)
        let height = Int(canvas.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(video, in: CGRect(origin: .zero, size: canvas))
        // CALayer.render ignores isGeometryFlipped; flip the context to land glyphs upright.
        context.saveGState()
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        textRoot.render(in: context)
        context.restoreGState()
        return context.makeImage()
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
        case .text:
            break
        }
    }

    struct TextClipSpec {
        let trackIndex: Int
        let startFrame: Int
        let durationFrames: Int
        let content: String
        let style: TextStyle
        /// When nil the box is auto-fit to content and centered on the canvas.
        let transform: Transform?
    }

    /// Batch variant of `addTextClip` for agent flows.
    /// Caller owns undo + track creation.
    @discardableResult
    func placeTextClips(_ specs: [TextClipSpec]) -> [String] {
        guard !specs.isEmpty else { return [] }
        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        var createdIds = [String?](repeating: nil, count: specs.count)

        let indicesByTrack = Dictionary(grouping: specs.indices, by: { specs[$0].trackIndex })
        for (_, indices) in indicesByTrack {
            let ordered = indices.sorted { specs[$0].startFrame < specs[$1].startFrame }
            for i in ordered {
                let spec = specs[i]
                guard timeline.tracks.indices.contains(spec.trackIndex) else { continue }
                let start = max(0, spec.startFrame)
                let duration = max(1, spec.durationFrames)
                clearRegion(trackIndex: spec.trackIndex, start: start, end: start + duration)

                let resolved: Transform
                if let t = spec.transform {
                    resolved = t
                } else {
                    let natural = TextLayout.naturalSize(
                        content: spec.content, style: spec.style, maxWidth: CGFloat(canvasW) * 0.9
                    )
                    let w = Double(natural.width) / canvasW
                    let h = Double(natural.height) / canvasH
                    resolved = Transform(topLeft: ((1 - w) / 2, (1 - h) / 2), width: w, height: h)
                }
                var clip = Clip(
                    mediaRef: "",
                    mediaType: .text,
                    sourceClipType: .text,
                    startFrame: start,
                    durationFrames: duration,
                    transform: resolved
                )
                clip.textContent = spec.content
                clip.textStyle = spec.style
                timeline.tracks[spec.trackIndex].clips.append(clip)
                createdIds[i] = clip.id
            }
        }

        for i in Set(specs.map(\.trackIndex)) where timeline.tracks.indices.contains(i) {
            sortClips(trackIndex: i)
        }
        videoEngine?.syncTextLayers()
        return createdIds.compactMap { $0 }
    }

    @discardableResult
    func addTextClip(content: String = "Text", style: TextStyle = TextStyle()) -> String? {
        let durationFrames = max(1, secondsToFrame(seconds: Defaults.textDurationSeconds, fps: timeline.fps))

        // Index 0 is the topmost slot in the timeline UI.
        let trackIdx = insertTrack(at: 0, type: .video, label: "T\(zones.videoTrackCount + 1)")

        let canvasW = Double(timeline.width)
        let canvasH = Double(timeline.height)
        let natural = TextLayout.naturalSize(content: content, style: style, maxWidth: CGFloat(canvasW) * 0.9)
        let w = Double(natural.width) / canvasW
        let h = Double(natural.height) / canvasH
        let transform = Transform(topLeft: ((1 - w) / 2, (1 - h) / 2), width: w, height: h)

        var clip = Clip(
            mediaRef: "",
            mediaType: .text,
            sourceClipType: .text,
            startFrame: max(0, currentFrame),
            durationFrames: durationFrames,
            transform: transform
        )
        clip.textContent = content
        clip.textStyle = style
        let clipId = clip.id

        timeline.tracks[trackIdx].clips.append(clip)
        sortClips(trackIndex: trackIdx)

        undoManager?.registerUndo(withTarget: self) { vm in
            if let loc = vm.findClip(id: clipId) {
                vm.timeline.tracks[loc.trackIndex].clips.remove(at: loc.clipIndex)
                vm.videoEngine?.syncTextLayers()
            }
        }
        undoManager?.setActionName("Add Text")

        selectedClipIds = [clipId]
        videoEngine?.syncTextLayers()
        return clipId
    }
}
