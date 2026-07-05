import Foundation

extension EditorViewModel {
    /// Called after Settings clears disk caches: session memoization must not outlive them.
    func resetAnalysisSessionState() {
        denoiseBaked.removeAll()
        denoiseFailed.removeAll()
        mediaVisualCache.resetSessionState()
        enhancePendingDenoises()
    }

    func setDenoise(clipIds: Set<String>, enabled: Bool, amount: Double? = nil, actionName: String) {
        let clamped = amount.map { min(1, max(0, $0)) }
        if enabled {
            for id in clipIds {
                if let ref = clipFor(id: id)?.mediaRef { denoiseFailed.remove(ref) }
            }
        }
        mutateClips(ids: clipIds, actionName: actionName) { clip in
            var stack = clip.effects ?? []
            if let i = stack.firstIndex(where: { $0.type == Clip.denoiseEffectType }) {
                stack[i].enabled = enabled
                if let clamped { stack[i].params["amount"] = EffectParam(value: clamped) }
            } else if enabled {
                stack.append(Effect(type: Clip.denoiseEffectType, enabled: true, params: [
                    "amount": EffectParam(value: clamped ?? Clip.defaultDenoiseAmount),
                ]))
            }
            clip.effects = stack.isEmpty ? nil : stack
        }
    }

    func enhancePendingDenoises() {
        for track in timeline.tracks {
            for clip in track.clips where clip.hasDenoiseEnabled {
                enhanceAudioIfNeeded(for: clip)
            }
        }
    }

    func enhanceAudioIfNeeded(for clip: Clip) {
        let mediaRef = clip.mediaRef
        guard clip.hasDenoiseEnabled, clip.denoiseAmount > 0,
              !denoiseBaked.contains(mediaRef),
              !denoiseInFlight.contains(mediaRef), !denoiseFailed.contains(mediaRef),
              let url = mediaResolver.resolveURL(for: mediaRef)
        else { return }
        if AudioEnhancer.cachedDenoisedURL(for: url, mediaRef: mediaRef) != nil {
            denoiseBaked.insert(mediaRef)
            return
        }
        denoiseInFlight.insert(mediaRef)
        Task.detached(priority: .utility) { [weak self] in
            var failed = false
            do {
                _ = try await AudioEnhancer.denoisedAudio(for: url, mediaRef: mediaRef)
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
                    self.denoiseBaked.insert(mediaRef)
                    // Rebuild to pick up the baked audio without pausing active playback.
                    self.videoEngine?.rebuild()
                }
            }
        }
    }
}
