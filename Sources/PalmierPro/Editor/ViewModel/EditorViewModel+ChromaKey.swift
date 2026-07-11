extension EditorViewModel {
    func toggleChromaKeySampling(clipId: String) {
        if chromaKeySamplingClipId == clipId {
            cancelChromaKeySampling()
            return
        }
        cancelChromaKeySampling()
        guard activePreviewTab == .timeline, clipFor(id: clipId)?.mediaType.isVisual == true else { return }
        pause()
        applyClipProperty(clipId: clipId) { clip in
            if let index = clip.effects?.firstIndex(where: { $0.type == "key.chroma" }) {
                clip.effects?[index].enabled = false
            }
        }
        chromaKeySamplingClipId = clipId
    }

    func cancelChromaKeySampling() {
        guard let clipId = chromaKeySamplingClipId else { return }
        chromaKeySamplingClipId = nil
        revertClipProperty(clipId: clipId)
    }

    func commitChromaKeySample(hue: Double, clipId: String) {
        guard chromaKeySamplingClipId == clipId, hue.isFinite else { return }
        chromaKeySamplingClipId = nil
        commitClipProperty(clipId: clipId) { clip in
            guard let descriptor = EffectRegistry.descriptor(id: "key.chroma") else { return }
            var effects = clip.effects ?? []
            var effect = effects.first { $0.type == descriptor.id } ?? descriptor.makeEffect()
            effect.enabled = true
            effect.params["keyHue"] = EffectParam(value: hue)
            effect.params["tolerance"] = EffectParam(value: 0.15)
            effect.params["softness"] = EffectParam(value: 0.1)
            effects.removeAll { $0.type == descriptor.id }
            effects.insert(effect, at: EffectRegistry.insertIndex(effects, for: descriptor.id))
            clip.effects = effects
        }
        undoManager?.setActionName("Sample Key Color")
    }
}
