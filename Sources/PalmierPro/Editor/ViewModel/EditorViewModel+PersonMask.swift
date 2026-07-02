import AppKit
import Foundation

extension EditorViewModel {
    struct PersonMaskCandidate: Identifiable, Sendable {
        let id: Int
        let thumbnail: NSImage
    }

    enum PersonMaskError: LocalizedError {
        case noSource
        case noPeopleDetected
        var errorDescription: String? {
            switch self {
            case .noSource: "Could not find this clip's source media."
            case .noPeopleDetected: "No people detected in this clip."
            }
        }
    }

    /// In-flight (or last-failed) background-removal bake, keyed by clip id.
    struct PersonMaskJob: Sendable, Equatable {
        var progress: Double = 0
        var error: String?
    }

    /// True while a background-removal bake is running for `clipId`.
    func isRemovingBackground(clipId: String) -> Bool {
        personMaskTasks[clipId] != nil
    }

    /// Starts (or joins an already-running) one-click background-removal bake for `clipId`.
    @discardableResult
    func removeBackground(clipId: String) -> Task<Void, Error> {
        if let existing = personMaskTasks[clipId] { return existing }
        guard let clip = clipFor(id: clipId) else {
            return Task { throw PersonMaskError.noSource }
        }
        personMaskJobs[clipId] = PersonMaskJob()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.autoRemoveBackground(clip: clip) { [weak self] fraction in
                    Task { @MainActor in self?.personMaskJobs[clipId]?.progress = fraction }
                }
                self.personMaskJobs[clipId] = nil
                self.personMaskTasks[clipId] = nil
            } catch {
                self.personMaskJobs[clipId] = PersonMaskJob(error: error.localizedDescription)
                self.personMaskTasks[clipId] = nil
                throw error
            }
        }
        personMaskTasks[clipId] = task
        return task
    }

    /// Detects every person in `clip` and bakes a matte keeping them. Prefer `removeBackground(clipId:)`.
    func autoRemoveBackground(clip: Clip, progress: @escaping @Sendable (Double) -> Void) async throws {
        let candidates = try await detectPeopleForMask(clip: clip)
        guard !candidates.isEmpty else { throw PersonMaskError.noPeopleDetected }
        try await bakePersonMask(clip: clip, selected: Set(candidates.map(\.id)), progress: progress)
    }

    /// Detects people in the first frame of `clip`'s source media.
    func detectPeopleForMask(clip: Clip) async throws -> [PersonMaskCandidate] {
        guard let url = mediaResolver.resolveURL(for: clip.mediaRef) else { throw PersonMaskError.noSource }
        let candidates = try await PersonMaskAnalyzer.detectPeople(url: url)
        return candidates.map {
            PersonMaskCandidate(id: $0.id, thumbnail: NSImage(
                cgImage: $0.thumbnail, size: NSSize(width: $0.thumbnail.width, height: $0.thumbnail.height)
            ))
        }
    }

    /// Bakes a matte for `selected` people and commits it as the clip's `key.personMask`
    /// effect. `progress` is called with 0...1 on an arbitrary queue.
    func bakePersonMask(clip: Clip, selected: Set<Int>, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = mediaResolver.resolveURL(for: clip.mediaRef) else { throw PersonMaskError.noSource }
        let cacheURL = try await PersonMaskBaker.bake(
            sourceURL: url, mediaRef: clip.mediaRef, selectedLabels: selected, progress: progress
        )
        guard let descriptor = EffectRegistry.descriptor(id: "key.personMask") else { return }
        commitClipProperties(clipIds: [clip.id]) { c in
            var effects = c.effects ?? []
            if let i = effects.firstIndex(where: { $0.type == "key.personMask" }) {
                effects[i].params["maskCachePath"] = EffectParam(string: cacheURL.path)
                effects[i].enabled = true
            } else {
                var effect = descriptor.makeEffect()
                effect.params["maskCachePath"] = EffectParam(string: cacheURL.path)
                effects.insert(effect, at: EffectRegistry.insertIndex(effects, for: "key.personMask"))
            }
            c.effects = effects
        }
    }

    /// Clears the baked mask (e.g. the Adjust tab's "Remove Mask" action).
    func clearPersonMask(clipId: String) {
        commitClipProperties(clipIds: [clipId]) { c in
            c.effects?.removeAll { $0.type == "key.personMask" }
        }
    }

    func personMaskCachePath(for clip: Clip) -> String? {
        (clip.effects ?? []).first { $0.type == "key.personMask" }?.params["maskCachePath"]?.string
    }
}
