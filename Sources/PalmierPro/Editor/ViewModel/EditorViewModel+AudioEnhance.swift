import Foundation

extension EditorViewModel {
    func setDenoise(clipIds: Set<String>, enabled: Bool, amount: Double? = nil, actionName: String) {
        let clamped = amount.map { min(1, max(0, $0)) }
        mutateClips(ids: clipIds, actionName: actionName) { clip in
            var stack = clip.effects ?? []
            let current = stack.first { $0.type == Clip.denoiseEffectType }
            stack.removeAll { $0.type == Clip.denoiseEffectType }
            if enabled {
                let value = clamped ?? current?.params["amount"]?.value ?? Clip.defaultDenoiseAmount
                stack.append(Effect(type: Clip.denoiseEffectType, enabled: true, params: [
                    "amount": EffectParam(value: value),
                ]))
            }
            clip.effects = stack.isEmpty ? nil : stack
        }
        guard enabled else { return }
        for id in clipIds {
            guard let live = clipFor(id: id) else { continue }
            denoiseFailed.remove(live.mediaRef)
            enhanceAudioIfNeeded(for: live)
        }
    }

    func enhancePendingDenoises() {
        for track in timeline.tracks {
            for clip in track.clips where clip.hasDenoiseEnabled {
                enhanceAudioIfNeeded(for: clip)
            }
        }
    }

    /// Export can bake denoise caches the preview never got (failed bake, or a composition
    /// built before the cache landed). Clear stale failure marks and rebuild so playback
    /// matches the exported file.
    func syncDenoiseAfterExport() {
        var hasCached = false
        for track in timeline.tracks {
            for clip in track.clips where clip.hasDenoiseEnabled {
                guard let url = mediaResolver.resolveURL(for: clip.mediaRef),
                      AudioEnhancer.cachedURL(for: url, mediaRef: clip.mediaRef, amount: clip.denoiseAmount) != nil
                else { continue }
                denoiseFailed.remove(clip.mediaRef)
                hasCached = true
            }
        }
        if hasCached { videoEngine?.rebuild() }
    }

    func enhanceAudioIfNeeded(for clip: Clip) {
        guard clip.hasDenoiseEnabled,
              !denoiseInFlight.contains(clip.mediaRef), !denoiseFailed.contains(clip.mediaRef),
              let url = mediaResolver.resolveURL(for: clip.mediaRef),
              AudioEnhancer.cachedURL(for: url, mediaRef: clip.mediaRef, amount: clip.denoiseAmount) == nil
        else { return }
        denoiseInFlight.insert(clip.mediaRef)
        let mediaRef = clip.mediaRef
        let amount = clip.denoiseAmount
        Task.detached(priority: .utility) { [weak self] in
            var failed = false
            do {
                _ = try await AudioEnhancer.enhancedAudio(for: url, mediaRef: mediaRef, amount: amount)
            } catch {
                failed = true
                Log.preview.error("denoise bake failed mediaRef=\(mediaRef): \(error.localizedDescription)")
            }
            await MainActor.run { [self] in
                guard let self else { return }
                self.denoiseInFlight.remove(mediaRef)
                if failed {
                    self.denoiseFailed.insert(mediaRef)
                } else {
                    // Rebuild to pick up the baked audio without pausing active playback.
                    self.videoEngine?.rebuild()
                }
                // Bakes dedupe by mediaRef, so other clips needing a different
                // strength mix may have been skipped while this one was in flight.
                self.enhancePendingDenoises()
            }
        }
    }
}
