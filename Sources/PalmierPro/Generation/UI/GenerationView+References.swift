import SwiftUI

// Reference strips, drop zones, and the ref-pool bookkeeping behind them.
extension GenerationView {

    var allRefs: [MediaAsset] { refImages + refVideos + refAudios }
    var totalRefCount: Int { allRefs.count }

    var isRefCapReached: Bool {
        if let total = videoModel.maxTotalReferences, totalRefCount >= total { return true }
        let imgFull = videoModel.maxReferenceImages == 0 || refImages.count >= videoModel.maxReferenceImages
        let vidFull = videoModel.maxReferenceVideos == 0 || refVideos.count >= videoModel.maxReferenceVideos
        let audFull = videoModel.maxReferenceAudios == 0 || refAudios.count >= videoModel.maxReferenceAudios
        return imgFull && vidFull && audFull
    }

    var showsRefSections: Bool {
        guard selectedType == .video, videoModel.supportsReferences else { return false }
        if videoModel.requiresSourceVideo { return false }
        if videoModel.framesAndReferencesExclusive {
            return framesRefsMode == .reference
        }
        return true
    }

    var showsFrameStrip: Bool {
        guard selectedType == .video, videoModel.supportsFirstFrame else { return false }
        if videoModel.requiresSourceVideo { return false }
        if videoModel.framesAndReferencesExclusive {
            return framesRefsMode == .firstLast
        }
        return true
    }

    var showsFramesRefsPicker: Bool {
        selectedType == .video && videoModel.framesAndReferencesExclusive
    }

    private var refGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: AppTheme.GenerationPanel.referenceTileWidth), spacing: AppTheme.Spacing.xs)]
    }

    // MARK: - Video frame references

    var videoFrameStrip: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            FrameSlot(label: "First Frame", asset: firstFrame, isTargeted: $firstFrameTargeted,
                      onDrop: { firstFrame = $0 }, onClear: { firstFrame = nil }, onError: flashDropError)
            if videoModel.supportsLastFrame {
                FrameSlot(label: "Last Frame", asset: lastFrame, isTargeted: $lastFrameTargeted,
                          onDrop: { lastFrame = $0 }, onClear: { lastFrame = nil }, onError: flashDropError)
            }
        }
    }

    // MARK: - First/Last / Reference mode picker (Seedance, Grok)

    var framesRefsModePicker: some View {
        HStack(spacing: AppTheme.Spacing.lg) {
            ForEach(FramesRefsMode.allCases, id: \.self) { mode in
                Button {
                    framesRefsMode = mode
                    switch mode {
                    case .firstLast: resetRefPools()
                    case .reference: firstFrame = nil; lastFrame = nil
                    }
                } label: {
                    VStack(spacing: AppTheme.Spacing.xxs) {
                        Text(mode.rawValue)
                            .font(.system(size: AppTheme.FontSize.xs, weight: framesRefsMode == mode ? .semibold : .medium))
                            .foregroundStyle(framesRefsMode == mode
                                ? AppTheme.Text.primaryColor
                                : AppTheme.Text.tertiaryColor)
                            .fixedSize()
                        Rectangle()
                            .fill(framesRefsMode == mode ? AppTheme.Accent.primary : Color.clear)
                            .frame(height: AppTheme.BorderWidth.medium)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }

    // MARK: - Unified video references strip (Seedance/Kling/Grok reference-to-video)

    var videoReferenceSections: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("References")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(refCounterLabel)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }

            LazyVGrid(
                columns: refGridColumns,
                alignment: .leading,
                spacing: AppTheme.Spacing.xs
            ) {
                ForEach(allRefCardItems, id: \.asset.id) { item in
                    RefCard(asset: item.asset, tag: item.tag) {
                        removeRef(item.type, byId: item.asset.id)
                    }
                }
                if !isRefCapReached {
                    RefDropZone(
                        isTargeted: $refsTargeted,
                        accepting: Set(ClipType.allCases),
                        iconName: "plus"
                    ) { asset in
                        addRefAsset(asset)
                    }
                }
            }
        }
    }

    private var allRefCardItems: [(asset: MediaAsset, tag: String, type: ClipType)] {
        ClipType.allCases.flatMap { type -> [(asset: MediaAsset, tag: String, type: ClipType)] in
            let assets: [MediaAsset]
            switch type {
            case .image: assets = refImages
            case .video: assets = refVideos
            case .audio: assets = refAudios
            case .text, .lottie, .sequence: assets = []
            }
            let noun = tagNoun(for: type)
            return assets.enumerated().map {
                (asset: $1, tag: "@\(noun)\($0 + 1)", type: type)
            }
        }
    }

    func refCap(for type: ClipType) -> Int {
        switch type {
        case .image: videoModel.maxReferenceImages
        case .video: videoModel.maxReferenceVideos
        case .audio: videoModel.maxReferenceAudios
        case .text, .lottie, .sequence: 0
        }
    }

    func refCount(for type: ClipType) -> Int {
        switch type {
        case .image: refImages.count
        case .video: refVideos.count
        case .audio: refAudios.count
        case .text, .lottie, .sequence: 0
        }
    }

    /// Tag noun used in `@Image1` / `@Video1` / `@Audio1` / `@Element1` labels.
    func tagNoun(for type: ClipType) -> String {
        switch type {
        case .image: videoModel.referenceTagNoun
        case .video: "Video"
        case .audio: "Audio"
        case .text: "Text"
        case .lottie: "Lottie"
        case .sequence: "Sequence"
        }
    }

    private func addRefAsset(_ asset: MediaAsset) {
        let inflight = editor.mediaAssets.filter(\.isGenerating).count
        Log.generation.notice("addRefAsset id=\(asset.id.prefix(8)) type=\(asset.type.rawValue) existing=\(refImages.count)+\(refVideos.count)+\(refAudios.count) inflightGen=\(inflight)")
        if allRefs.contains(where: { $0.id == asset.id }) {
            flashDropError("\(asset.name) is already a reference")
            return
        }
        var selection = videoInputAssets(for: videoModel)
        switch asset.type {
        case .image: selection.imageRefs.append(asset)
        case .video: selection.videoRefs.append(asset)
        case .audio: selection.audioRefs.append(asset)
        case .text, .lottie, .sequence:
            let supported = ClipType.allCases.filter { refCap(for: $0) > 0 }.map(\.rawValue).joined(separator: " and ")
            flashDropError("\(videoModel.displayName) only accepts \(supported) references.")
            return
        }
        if let err = selection.validate(for: videoModel) {
            flashDropError(err)
            return
        }
        switch asset.type {
        case .image: refImages.append(asset)
        case .video: refVideos.append(asset)
        case .audio: refAudios.append(asset)
        case .text, .lottie, .sequence: break
        }
    }

    func flashDropError(_ message: String) {
        dropErrorTask?.cancel()
        dropError = message
        dropErrorTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { dropError = nil }
        }
    }

    private func removeRef(_ type: ClipType, byId id: MediaAsset.ID) {
        switch type {
        case .image: refImages.removeAll { $0.id == id }
        case .video: refVideos.removeAll { $0.id == id }
        case .audio: refAudios.removeAll { $0.id == id }
        case .text, .lottie, .sequence: break
        }
    }

    func resetRefPools() {
        refImages.removeAll()
        refVideos.removeAll()
        refAudios.removeAll()
    }

    func clearReferences() {
        firstFrame = nil
        lastFrame = nil
        imageReferences.removeAll()
        resetRefPools()
        sourceVideo = nil
        audioSource = nil
    }

    private var refCounterLabel: String {
        let total = totalRefCount
        if let cap = videoModel.maxTotalReferences {
            let shortLabel: (ClipType) -> String = { switch $0 { case .image: "img"; case .video: "vid"; case .audio: "aud"; case .text: "txt"; case .lottie: "lot"; case .sequence: "seq" } }
            let parts = ClipType.allCases
                .filter { refCap(for: $0) > 0 }
                .map { "\(refCount(for: $0)) \(shortLabel($0))" }
            return "\(total)/\(cap) · \(parts.joined(separator: " · "))"
        }
        let singleCap = ClipType.allCases.map(refCap(for:)).max() ?? 0
        return "\(total)/\(singleCap)"
    }

    // MARK: - Image references

    var imageReferenceStrip: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("References")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            LazyVGrid(
                columns: refGridColumns,
                alignment: .leading,
                spacing: AppTheme.Spacing.xs
            ) {
                ForEach(imageReferences) { asset in
                    RefCard(asset: asset) {
                        imageReferences.removeAll { $0.id == asset.id }
                    }
                }
                RefDropZone(
                    isTargeted: $imageRefTargeted,
                    accepting: Set(ClipType.allCases),
                    iconName: "photo.badge.plus"
                ) { asset in
                    if asset.type != .image {
                        flashDropError("Drop image here.")
                    } else if imageReferences.contains(where: { $0.id == asset.id }) {
                        flashDropError("\(asset.name) is already a reference")
                    } else {
                        imageReferences.append(asset)
                    }
                }
            }
        }
    }

    // MARK: - Edit (video-to-video) strip

    var editVideoStrip: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            FrameSlot(
                label: "Source Video",
                asset: sourceVideo,
                isTargeted: $sourceVideoTargeted,
                accepting: [.video],
                iconName: "video.badge.plus",
                onDrop: { sourceVideo = $0 },
                onClear: { sourceVideo = nil },
                onError: flashDropError
            )
            if videoModel.supportsReferences {
                FrameSlot(
                    label: "Reference Image",
                    asset: imageReferences.first,
                    isTargeted: $motionReferenceTargeted,
                    accepting: [.image],
                    iconName: "photo.badge.plus",
                    onDrop: { imageReferences = [$0] },
                    onClear: { imageReferences.removeAll() },
                    onError: flashDropError
                )
            }
        }
    }

    var audioSourceStrip: some View {
        FrameSlot(
            label: audioSourceLabel,
            asset: audioSource,
            isTargeted: $audioSourceTargeted,
            accepting: audioSourceTypes,
            iconName: audioSourceTypes == [.video] ? "video.badge.plus" : "waveform",
            onDrop: { audioSource = $0 },
            onClear: { audioSource = nil },
            onError: flashDropError
        )
    }

    private var audioSourceTypes: Set<ClipType> {
        Set([ClipType.audio, .video].filter { audioModel.acceptsSource($0) })
    }

    private var audioSourceLabel: String {
        if audioSourceTypes == [.audio] { return "Source Audio" }
        if audioSourceTypes == [.video] { return "Source Video" }
        return "Source Media"
    }
}
