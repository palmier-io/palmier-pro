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
        let mediaType = editor.clipFor(id: clipId)?.mediaType ?? .video
        let enhanceActions = actions.filter { $0.group(for: mediaType) == .enhance }
        let audioActions = actions.filter { $0.group(for: mediaType) == .audio }
        let addAction: (EditAction) -> Void = { action in
            let paidBlocked = action.requiresPaidPlan && !isPaid
            switch action {
            case .upscale:
                let upscaleItem = NSMenuItem(title: paidBlocked ? L10n.string("Upscale… (Paid)") : L10n.string("Upscale…"), action: #selector(self.performAIEditUpscale(_:)), keyEquivalent: "")
                upscaleItem.target = self
                upscaleItem.representedObject = clipId
                upscaleItem.isEnabled = aiAllowed && !paidBlocked
                submenu.addItem(upscaleItem)
            case .reframe:
                let item = NSMenuItem(title: paidBlocked ? L10n.string("Reframe… (Paid)") : L10n.string("Reframe…"), action: #selector(self.performAIEditReframe(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = clipId
                item.isEnabled = aiAllowed && !paidBlocked
                submenu.addItem(item)
            case .lipSync:
                let item = NSMenuItem(title: paidBlocked ? L10n.string("Lip Sync… (Paid)") : L10n.string("Lip Sync…"), action: #selector(self.performAIEditLipSync(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = clipId
                item.isEnabled = aiAllowed && !paidBlocked
                submenu.addItem(item)
            case .edit:
                let item = NSMenuItem(title: paidBlocked ? L10n.string("Edit… (Paid)") : L10n.string("Edit…"), action: #selector(self.performAIEditEdit(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = clipId
                item.isEnabled = aiAllowed && !paidBlocked
                submenu.addItem(item)
            case .generateMusic, .generateSFX:
                let kind: VideoToAudioEditKind = action == .generateMusic ? .music : .sfx
                let item = NSMenuItem(title: L10n.string(key: kind.menuTitle), action: #selector(self.performAIEditVideoAudio(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["clipId": clipId, "kind": action == .generateMusic ? "music" : "sfx"]
                item.isEnabled = aiAllowed
                submenu.addItem(item)
            case .rerun:
                let item = NSMenuItem(title: L10n.string("Rerun"), action: #selector(self.performAIEditRerun(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = clipId
                item.isEnabled = aiAllowed
                submenu.addItem(item)
            case .createVideo:
                let createItem = NSMenuItem(title: L10n.string("Create Video"), action: nil, keyEquivalent: "")
                let createMenu = NSMenu()
                createMenu.autoenablesItems = false
                let mk: (String, Bool) -> NSMenuItem = { title, asReference in
                    let item = NSMenuItem(title: title, action: #selector(self.performAIEditCreateVideo(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = ["clipId": clipId, "asReference": asReference]
                    item.isEnabled = aiAllowed
                    return item
                }
                createMenu.addItem(mk(L10n.string("Set as first frame"), false))
                createMenu.addItem(mk(L10n.string("Set as reference"), true))
                createItem.submenu = createMenu
                submenu.addItem(createItem)
            }
        }

        if !enhanceActions.isEmpty {
            submenu.addItem(.sectionHeader(title: L10n.string("AI Enhance")))
            enhanceActions.forEach(addAction)
        }
        if !audioActions.isEmpty || !audioTransforms.isEmpty {
            if !submenu.items.isEmpty { submenu.addItem(.separator()) }
            submenu.addItem(.sectionHeader(title: L10n.string("AI Audio")))
            audioActions.filter { $0 == .rerun }.forEach(addAction)
            for kind in audioTransforms {
                let paidBlocked = kind.model?.paidOnly == true && !isPaid
                let localizedTitle = L10n.string(key: kind.menuTitle)
                let title = paidBlocked ? L10n.string("\(localizedTitle) (Paid)") : localizedTitle
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
            audioActions.filter { $0 != .rerun }.forEach(addAction)
        }
        return submenu.items.isEmpty ? nil : submenu
    }

    @objc private func performAIEditEdit(_ sender: Any?) {
        guard let clipId = (sender as? NSMenuItem)?.representedObject as? String else { return }
        editor.beginAIEdit(clipId: clipId)
    }

    @objc private func performAIEditReframe(_ sender: Any?) {
        guard let clipId = (sender as? NSMenuItem)?.representedObject as? String else { return }
        editor.beginAIReframe(clipId: clipId)
    }

    @objc private func performAIEditLipSync(_ sender: Any?) {
        guard let clipId = (sender as? NSMenuItem)?.representedObject as? String else { return }
        editor.beginAILipSync(clipId: clipId)
    }

    @objc private func performAIEditRerun(_ sender: Any?) {
        guard let clipId = (sender as? NSMenuItem)?.representedObject as? String else { return }
        editor.beginAIRerun(clipId: clipId)
    }

    @objc private func performAIEditUpscale(_ sender: Any?) {
        guard let clipId = (sender as? NSMenuItem)?.representedObject as? String else { return }
        editor.beginAIUpscale(clipId: clipId)
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

    @objc func performCreateAITransition(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let trackIndex = info["trackIndex"] as? Int,
              let start = info["start"] as? Int,
              let end = info["end"] as? Int else { return }
        editor.beginAITransition(gap: GapSelection(trackIndex: trackIndex, range: FrameRange(start: start, end: end)))
    }

    @objc private func performAIEditCreateVideo(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let clipId = info["clipId"] as? String,
              let asReference = info["asReference"] as? Bool else { return }
        editor.beginAICreateVideo(clipId: clipId, asReference: asReference)
    }
}
