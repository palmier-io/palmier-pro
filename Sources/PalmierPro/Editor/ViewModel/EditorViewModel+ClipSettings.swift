import Foundation

struct ClipSettingsSnapshot: Sendable {
    let sourceClipId: String
    fileprivate let clip: Clip

    var mediaType: ClipType { clip.mediaType }
}

struct ClipSettingsTransferResult: Sendable, Equatable {
    let changedClipIds, unchangedClipIds: [String]
}

enum ClipSettingsTransferError: LocalizedError, Equatable {
    case emptyTargets
    case clipNotFound(String)
    case incompatibleType(source: ClipType, targetId: String, target: ClipType)

    var errorDescription: String? {
        switch self {
        case .emptyTargets:
            "Provide at least one target clip."
        case .clipNotFound(let id):
            "Clip not found: \(id)"
        case .incompatibleType(let source, let targetId, let target):
            "Clip \(targetId) is \(target.rawValue); copied settings require \(source.rawValue) clips."
        }
    }
}

extension EditorViewModel {
    func copiedClipSettings(for mediaType: ClipType) -> ClipSettingsSnapshot? {
        let sources = clipClipboard.map(\.clip).filter { $0.mediaType == mediaType }
        guard sources.count == 1, let source = sources.first else { return nil }
        return ClipSettingsSnapshot(sourceClipId: source.id, clip: source)
    }

    func pasteClipSettingsFromClipboard(to clipIds: [String]) {
        guard let mediaType = clipIds.compactMap({ clipFor(id: $0)?.mediaType }).first,
              let settings = copiedClipSettings(for: mediaType) else {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Copy one clip of the same type and try again."))
            return
        }
        do {
            _ = try applyClipSettings(settings, to: clipIds)
        } catch {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Select compatible clips and paste settings again."))
            Log.editor.notice("paste clip settings failed: \(error)")
        }
    }

    func clipSettingsSnapshot(for clipId: String) throws -> ClipSettingsSnapshot {
        guard let clip = clipFor(id: clipId) else {
            throw ClipSettingsTransferError.clipNotFound(clipId)
        }
        return ClipSettingsSnapshot(sourceClipId: clipId, clip: clip)
    }

    func compatibleClipSettingsTargets(in clipIds: [String], for snapshot: ClipSettingsSnapshot) -> [String] {
        clipIds.filter {
            $0 != snapshot.sourceClipId && clipFor(id: $0)?.mediaType == snapshot.mediaType
        }
    }

    @discardableResult
    func applyClipSettings(
        _ snapshot: ClipSettingsSnapshot,
        to targetClipIds: [String],
        actionName: String = L10n.string("Paste Clip Settings")
    ) throws -> ClipSettingsTransferResult {
        var seen = Set<String>()
        let targetClipIds = targetClipIds.filter { seen.insert($0).inserted }
        guard !targetClipIds.isEmpty else {
            throw ClipSettingsTransferError.emptyTargets
        }

        var replacements: [String: Clip] = [:]
        for clipId in targetClipIds {
            guard let target = clipFor(id: clipId) else {
                throw ClipSettingsTransferError.clipNotFound(clipId)
            }
            guard target.mediaType == snapshot.mediaType else {
                throw ClipSettingsTransferError.incompatibleType(
                    source: snapshot.mediaType,
                    targetId: clipId,
                    target: target.mediaType
                )
            }
            replacements[clipId] = clipId == snapshot.sourceClipId
                ? target
                : applyingStaticSettings(from: snapshot.clip, to: target)
        }

        let changedClipIds = targetClipIds.filter {
            guard let current = clipFor(id: $0), let replacement = replacements[$0] else { return false }
            return current != replacement
        }
        let changed = Set(changedClipIds)
        commitClipProperties(clipIds: changedClipIds, actionName: actionName) { clip in
            if let replacement = replacements[clip.id] {
                clip = replacement
            }
        }
        return ClipSettingsTransferResult(
            changedClipIds: changedClipIds,
            unchangedClipIds: targetClipIds.filter { !changed.contains($0) }
        )
    }

    private func applyingStaticSettings(from source: Clip, to target: Clip) -> Clip {
        var result = target
        result.effects = source.effects

        switch source.mediaType {
        case .audio:
            result.volume = source.volume
        case .text:
            result.opacity = source.opacity
            result.textStyle = source.textStyle
            result.textAnimation = source.textAnimation
            result.textFillMode = source.textFillMode
            _ = fitTextClipToContentIfNeeded(
                &result,
                canvasW: Double(timeline.width),
                canvasH: Double(timeline.height)
            )
            result.transform.centerX = source.transform.centerX
            result.transform.centerY = source.transform.centerY
            result.transform.rotation = source.transform.rotation
            result.transform.flipHorizontal = source.transform.flipHorizontal
            result.transform.flipVertical = source.transform.flipVertical
        case .video, .image, .lottie, .sequence:
            result.opacity = source.opacity
            result.transform = source.transform
            result.crop = source.crop
            result.edgeRounding = source.edgeRounding
            result.edgeSoftness = source.edgeSoftness
            result.blendMode = source.blendMode
        case .subtitle:
            // Asset-only type; never a clip's mediaType.
            break
        }
        return result
    }
}
