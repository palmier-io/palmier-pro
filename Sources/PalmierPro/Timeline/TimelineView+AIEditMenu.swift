import AppKit

/// Same as AIEditMenu, but NSMenu-based.
extension TimelineView {
    func aiEditSubmenu(for clipId: String) -> NSMenu? {
        let actions = editor.aiEditActions(clipId: clipId)
        let audioTransforms = editor.aiAudioTransformKinds(clipId: clipId)
        guard !actions.isEmpty || !audioTransforms.isEmpty else { return nil }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let aiAllowed = editor.aiEditAllowed
        let isPaid = AccountService.shared.isPaid
        for action in actions {
            switch action {
            case .upscale:
                let models = editor.aiEditUpscaleModels(clipId: clipId)
                guard !models.isEmpty else { continue }
                let upscaleItem = NSMenuItem(title: isPaid ? "Upscale" : "Upscale (Paid)", action: nil, keyEquivalent: "")
                upscaleItem.isEnabled = aiAllowed && isPaid
                let modelsMenu = NSMenu()
                modelsMenu.autoenablesItems = false
                for model in models {
                    let item = NSMenuItem(title: model.displayName, action: #selector(performAIEditUpscale(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = ["clipId": clipId, "modelId": model.id]
                    item.isEnabled = aiAllowed && isPaid
                    modelsMenu.addItem(item)
                }
                upscaleItem.submenu = modelsMenu
                submenu.addItem(upscaleItem)
            case .edit:
                let item = NSMenuItem(title: isPaid ? "Edit…" : "Edit… (Paid)", action: #selector(performAIEditEdit(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = clipId
                item.isEnabled = aiAllowed && isPaid
                submenu.addItem(item)
            case .generateMusic, .generateSFX:
                let kind: VideoToAudioEditKind = action == .generateMusic ? .music : .sfx
                let item = NSMenuItem(title: "\(kind.title)…", action: #selector(performAIEditVideoAudio(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["clipId": clipId, "kind": action == .generateMusic ? "music" : "sfx"]
                item.isEnabled = aiAllowed
                submenu.addItem(item)
            case .rerun:
                let item = NSMenuItem(title: "Rerun", action: #selector(performAIEditRerun(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = clipId
                item.isEnabled = aiAllowed
                submenu.addItem(item)
            case .createVideo:
                let createItem = NSMenuItem(title: "Create Video", action: nil, keyEquivalent: "")
                let createMenu = NSMenu()
                createMenu.autoenablesItems = false
                let mk: (String, Bool) -> NSMenuItem = { title, asReference in
                    let item = NSMenuItem(title: title, action: #selector(self.performAIEditCreateVideo(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = ["clipId": clipId, "asReference": asReference]
                    item.isEnabled = aiAllowed
                    return item
                }
                createMenu.addItem(mk("Set as first frame", false))
                createMenu.addItem(mk("Set as reference", true))
                createItem.submenu = createMenu
                submenu.addItem(createItem)
            }
        }
        if !audioTransforms.isEmpty {
            if !submenu.items.isEmpty { submenu.addItem(.separator()) }
            for kind in audioTransforms {
                let paidBlocked = kind.model?.paidOnly == true && !isPaid
                let title = paidBlocked ? "\(kind.menuTitle) (Paid)" : kind.menuTitle
                let item = NSMenuItem(
                    title: title,
                    action: #selector(performAIEditAudioTransform(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = [
                    "clipId": clipId,
                    "kind": kind == .cleanup ? "cleanup" : "dubbing",
                ]
                item.isEnabled = aiAllowed && !paidBlocked
                submenu.addItem(item)
            }
        }
        return submenu.items.isEmpty ? nil : submenu
    }

    @objc private func performAIEditEdit(_ sender: Any?) {
        guard let clipId = (sender as? NSMenuItem)?.representedObject as? String else { return }
        editor.beginAIEdit(clipId: clipId)
    }

    @objc private func performAIEditRerun(_ sender: Any?) {
        guard let clipId = (sender as? NSMenuItem)?.representedObject as? String else { return }
        editor.beginAIRerun(clipId: clipId)
    }

    @objc private func performAIEditUpscale(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let clipId = info["clipId"] as? String,
              let modelId = info["modelId"] as? String,
              let model = UpscaleModelConfig.allModels.first(where: { $0.id == modelId }) else { return }
        editor.runAIUpscale(clipId: clipId, model: model)
    }

    @objc private func performAIEditVideoAudio(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let clipId = info["clipId"] as? String,
              let kind = info["kind"] as? String else { return }
        editor.beginAIVideoAudio(clipId: clipId, kind: kind == "music" ? .music : .sfx)
    }

    @objc private func performAIEditAudioTransform(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let clipId = info["clipId"] as? String,
              let kind = info["kind"] as? String else { return }
        editor.beginAIAudioTransform(
            clipId: clipId,
            kind: kind == "cleanup" ? .cleanup : .dubbing
        )
    }

    @objc private func performAIEditCreateVideo(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let clipId = info["clipId"] as? String,
              let asReference = info["asReference"] as? Bool else { return }
        editor.beginAICreateVideo(clipId: clipId, asReference: asReference)
    }
}
