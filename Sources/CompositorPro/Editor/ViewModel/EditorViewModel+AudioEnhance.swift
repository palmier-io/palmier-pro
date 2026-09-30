import Foundation

extension EditorViewModel {
    /// Called after Settings clears disk caches: session memoization must not outlive them.
    func resetAnalysisSessionState() {
        denoiseBaked.removeAll()
        denoiseFailed.removeAll()
        breathBaked.removeAll()
        breathFailed.removeAll()
        deessBaked.removeAll()
        deessFailed.removeAll()
        mediaVisualCache.resetSessionState()
        enhancePendingEnhancements()
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

    func setDebreath(clipIds: Set<String>, enabled: Bool, amount: Double? = nil, actionName: String) {
        let clamped = amount.map { min(1, max(0, $0)) }
        if enabled {
            for id in clipIds {
                if let ref = clipFor(id: id)?.mediaRef { breathFailed.remove(ref) }
            }
        }
        mutateClips(ids: clipIds, actionName: actionName) { clip in
            var stack = clip.effects ?? []
            if let i = stack.firstIndex(where: { $0.type == Clip.debreathEffectType }) {
                stack[i].enabled = enabled
                if let clamped { stack[i].params["amount"] = EffectParam(value: clamped) }
            } else if enabled {
                stack.append(Effect(type: Clip.debreathEffectType, enabled: true, params: [
                    "amount": EffectParam(value: clamped ?? Clip.defaultDebreathAmount),
                ]))
            }
            clip.effects = stack.isEmpty ? nil : stack
        }
    }

    /// Enables the one-click chain. Enhance subsumes the standalone denoise and
    /// de-breath effects, so those are stripped to keep one owner per stage.
    func setEnhance(clipIds: Set<String>, enabled: Bool, amount: Double? = nil, deess: Double? = nil, actionName: String) {
        let clampedAmount = amount.map { min(1, max(0, $0)) }
        let clampedDeess = deess.map { min(1, max(0, $0)) }
        if enabled {
            for id in clipIds {
                if let ref = clipFor(id: id)?.mediaRef {
                    denoiseFailed.remove(ref)
                    breathFailed.remove(ref)
                    deessFailed.remove(ref)
                }
            }
        }
        mutateClips(ids: clipIds, actionName: actionName) { clip in
            var stack = clip.effects ?? []
            if enabled {
                stack.removeAll { $0.type == Clip.denoiseEffectType || $0.type == Clip.debreathEffectType }
                if let i = stack.firstIndex(where: { $0.type == Clip.enhanceEffectType }) {
                    stack[i].enabled = true
                    if let clampedAmount { stack[i].params["amount"] = EffectParam(value: clampedAmount) }
                    if let clampedDeess { stack[i].params["deess"] = EffectParam(value: clampedDeess) }
                } else {
                    stack.append(Effect(type: Clip.enhanceEffectType, enabled: true, params: [
                        "amount": EffectParam(value: clampedAmount ?? Clip.defaultEnhanceAmount),
                        "deess": EffectParam(value: clampedDeess ?? Clip.defaultEnhanceDeess),
                    ]))
                }
            } else if let i = stack.firstIndex(where: { $0.type == Clip.enhanceEffectType }) {
                stack[i].enabled = false
            }
            clip.effects = stack.isEmpty ? nil : stack
        }
    }

    /// One-click voice enhance: measures source loudness, then applies the full chain
    /// (denoise + de-breath + de-esser + loudness match) as a single undoable action.
    func enhanceVoice(clipIds: Set<String>, amount: Double, deess: Double, actionName: String) {
        let ids = clipIds
        let clampedAmount = min(1, max(0, amount))
        let clampedDeess = min(1, max(0, deess))
        loudnessInFlight.formUnion(ids)
        let targets: [(id: String, mediaRef: String, url: URL)] = ids.compactMap { id in
            guard let clip = clipFor(id: id), clip.mediaType == .audio,
                  let url = mediaResolver.resolveURL(for: clip.mediaRef)
            else { return nil }
            return (id, clip.mediaRef, url)
        }
        Task.detached(priority: .utility) { [weak self] in
            var gains: [String: Double] = [:]
            for item in targets {
                let lufs: Double
                if let cached = LoudnessAnalyzer.cachedLoudness(for: item.url, mediaRef: item.mediaRef) {
                    lufs = cached
                } else {
                    do { lufs = try await LoudnessAnalyzer.integratedLoudness(for: item.url, mediaRef: item.mediaRef) }
                    catch { continue }
                }
                gains[item.id] = min(24.0, max(-24.0, -16.0 - lufs))
            }
            await MainActor.run { [self] in
                guard let self else { return }
                self.loudnessInFlight.subtract(ids)
                self.undo.perform(actionName) {
                    self.mutateClips(ids: ids, actionName: actionName) { clip in
                        var stack = clip.effects ?? []
                        stack.removeAll { $0.type == Clip.denoiseEffectType || $0.type == Clip.debreathEffectType }
                        if let i = stack.firstIndex(where: { $0.type == Clip.enhanceEffectType }) {
                            stack[i].enabled = true
                            stack[i].params["amount"] = EffectParam(value: clampedAmount)
                            stack[i].params["deess"] = EffectParam(value: clampedDeess)
                        } else {
                            stack.append(Effect(type: Clip.enhanceEffectType, enabled: true, params: [
                                "amount": EffectParam(value: clampedAmount),
                                "deess": EffectParam(value: clampedDeess),
                            ]))
                        }
                        if let gain = gains[clip.id] {
                            if let i = stack.firstIndex(where: { $0.type == Clip.loudnessEffectType }) {
                                stack[i].enabled = true
                                stack[i].params["gainDB"] = EffectParam(value: gain)
                            } else {
                                stack.append(Effect(type: Clip.loudnessEffectType, enabled: true, params: [
                                    "gainDB": EffectParam(value: gain),
                                ]))
                            }
                        }
                        clip.effects = stack.isEmpty ? nil : stack
                    }
                }
                self.videoEngine?.rebuild()
            }
        }
    }

    /// Measures each clip's source loudness and writes a gain that lands it on targetLUFS.
    func matchLoudness(clipIds: Set<String>, targetLUFS: Double, actionName: String) {
        let ids = clipIds
        let target = min(14.0, max(-30.0, targetLUFS))
        loudnessInFlight.formUnion(ids)
        let targets: [(id: String, mediaRef: String, url: URL)] = ids.compactMap { id in
            guard let clip = clipFor(id: id), clip.mediaType == .audio,
                  let url = mediaResolver.resolveURL(for: clip.mediaRef)
            else { return nil }
            return (id, clip.mediaRef, url)
        }
        Task.detached(priority: .utility) { [weak self] in
            var gains: [String: Double] = [:]
            for item in targets {
                let lufs: Double
                if let cached = LoudnessAnalyzer.cachedLoudness(for: item.url, mediaRef: item.mediaRef) {
                    lufs = cached
                } else {
                    do { lufs = try await LoudnessAnalyzer.integratedLoudness(for: item.url, mediaRef: item.mediaRef) }
                    catch { continue }
                }
                gains[item.id] = min(24.0, max(-24.0, target - lufs))
            }
            await MainActor.run { [self] in
                guard let self else { return }
                self.loudnessInFlight.subtract(ids)
                guard !gains.isEmpty else { return }
                self.undo.perform(actionName) {
                    self.mutateClips(ids: Set(gains.keys), actionName: actionName) { clip in
                        guard let gain = gains[clip.id] else { return }
                        var stack = clip.effects ?? []
                        if let i = stack.firstIndex(where: { $0.type == Clip.loudnessEffectType }) {
                            stack[i].enabled = true
                            stack[i].params["gainDB"] = EffectParam(value: gain)
                        } else {
                            stack.append(Effect(type: Clip.loudnessEffectType, enabled: true, params: [
                                "gainDB": EffectParam(value: gain),
                            ]))
                        }
                        clip.effects = stack.isEmpty ? nil : stack
                    }
                }
                self.videoEngine?.rebuild()
            }
        }
    }

    func enhancePendingEnhancements() {
        for track in timeline.tracks {
            for clip in track.clips where clip.hasDenoiseEnabled || clip.hasDebreathEnabled || clip.hasEnhanceEnabled {
                enhanceAudioIfNeeded(for: clip)
            }
        }
    }

    func enhanceAudioIfNeeded(for clip: Clip) {
        let mediaRef = clip.mediaRef
        guard !denoiseInFlight.contains(mediaRef), !denoiseFailed.contains(mediaRef),
              !breathFailed.contains(mediaRef), !deessFailed.contains(mediaRef),
              let url = mediaResolver.resolveURL(for: mediaRef)
        else { return }
        let enhanceActive = clip.hasEnhanceEnabled && clip.enhanceAmount > 0
        let wantsDenoise = (clip.hasDenoiseEnabled && clip.denoiseAmount > 0) || enhanceActive
        let wantsBreath = clip.hasDebreathEnabled || enhanceActive
        let wantsDeess = enhanceActive
        guard wantsDenoise || wantsBreath || wantsDeess else { return }
        let denoiseDone = denoiseBaked.contains(mediaRef)
        let breathDone = breathBaked.contains(mediaRef)
        let deessDone = deessBaked.contains(mediaRef)
        guard (wantsDenoise && !denoiseDone) || (wantsBreath && !breathDone) || (wantsDeess && !deessDone) else { return }
        if wantsDenoise, AudioEnhancer.cachedDenoisedURL(for: url, mediaRef: mediaRef) != nil {
            denoiseBaked.insert(mediaRef)
        }
        if wantsBreath, BreathDetector.cachedAnalysis(for: url, mediaRef: mediaRef) != nil {
            breathBaked.insert(mediaRef)
        }
        if wantsDeess, DeEsser.cachedAnalysis(for: url, mediaRef: mediaRef) != nil {
            deessBaked.insert(mediaRef)
        }
        let needsDenoise = wantsDenoise && !denoiseBaked.contains(mediaRef)
        let needsBreath = wantsBreath && !breathBaked.contains(mediaRef)
        let needsDeess = wantsDeess && !deessBaked.contains(mediaRef)
        guard needsDenoise || needsBreath || needsDeess else { return }
        denoiseInFlight.insert(mediaRef)
        Task.detached(priority: .utility) { [weak self] in
            var failed = false
            if needsDenoise {
                do {
                    _ = try await AudioEnhancer.denoisedAudio(for: url, mediaRef: mediaRef)
                } catch {
                    failed = true
                    Log.preview.error("denoise bake failed mediaRef=\(mediaRef): \(error.localizedDescription)")
                }
            }
            if needsBreath {
                do {
                    _ = try await BreathDetector.analysis(for: url, mediaRef: mediaRef)
                } catch {
                    failed = true
                    Log.preview.error("breath detection failed mediaRef=\(mediaRef): \(error.localizedDescription)")
                }
            }
            if needsDeess {
                do {
                    _ = try await DeEsser.analysis(for: url, mediaRef: mediaRef)
                } catch {
                    failed = true
                    Log.preview.error("de-ess detection failed mediaRef=\(mediaRef): \(error.localizedDescription)")
                }
            }
            await MainActor.run { [self] in
                guard let self else { return }
                self.denoiseInFlight.remove(mediaRef)
                if failed {
                    self.denoiseFailed.insert(mediaRef)
                    self.breathFailed.insert(mediaRef)
                    self.deessFailed.insert(mediaRef)
                } else {
                    if needsDenoise { self.denoiseBaked.insert(mediaRef) }
                    if needsBreath { self.breathBaked.insert(mediaRef) }
                    if needsDeess { self.deessBaked.insert(mediaRef) }
                    self.videoEngine?.rebuild()
                }
            }
        }
    }
}
