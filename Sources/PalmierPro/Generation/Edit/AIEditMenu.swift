import SwiftUI

// AI Edit menu for a media asset's context menu.
struct AIEditMenu: View {
    let asset: MediaAsset
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if availableActions.isEmpty {
            EmptyView()
        } else if !aiAllowed {
            Button("AI Edit") {}.disabled(true)
        } else {
            Menu("AI Edit") {
                if availableActions.contains(.upscale) {
                    Menu("Upscale") {
                        ForEach(UpscaleModelConfig.models(for: asset.type)) { model in
                            Button(model.displayName) { runUpscale(model) }
                        }
                    }
                }
                if availableActions.contains(.edit) {
                    Button("Edit…") { edit() }
                }
                if availableActions.contains(.rerun) {
                    Button("Rerun") { rerun() }
                }
                if availableActions.contains(.createVideo) {
                    Menu("Create Video") {
                        Button("Set as first frame") { createVideo(asReference: false) }
                        Button("Set as reference") { createVideo(asReference: true) }
                    }
                }
            }
        }
    }

    private var aiAllowed: Bool {
        let account = AccountService.shared
        return account.isSignedIn && !account.isMisconfigured
    }

    private var availableActions: [EditAction] {
        let candidates: [EditAction] = asset.type == .image
            ? [.upscale, .edit, .rerun, .createVideo]
            : [.upscale, .edit, .rerun]
        return candidates.filter { $0.availability(for: asset).isAvailable }
    }

    private func runUpscale(_ model: UpscaleModelConfig) {
        _ = EditSubmitter.submitUpscale(asset: asset, model: model, editor: editor)
    }

    private func edit() {
        guard let stored = EditSubmitter.editSeed(for: asset) else { return }
        seedPanel(stored: stored, defaultName: "Edited \(asset.name)")
    }

    private func rerun() {
        let modelId = asset.generationInput?.model ?? ""
        if UpscaleModelConfig.allIds.contains(modelId) {
            _ = try? EditSubmitter.rerun(asset: asset, editor: editor)
        } else if let stored = asset.generationInput {
            seedPanel(stored: stored, defaultName: nil)
        }
    }

    private func createVideo(asReference: Bool) {
        guard let stored = EditSubmitter.createVideoSeed(for: asset, asReference: asReference) else { return }
        seedPanel(stored: stored, defaultName: "Video from \(asset.name)")
    }

    private func seedPanel(stored: GenerationInput, defaultName: String?) {
        editor.pendingEditReplacementClipId = nil
        editor.pendingEditTrimmedSource = nil
        editor.pendingPanelSeed = PendingPanelSeed(asset: asset, stored: stored, defaultName: defaultName)
        editor.showGenerationPanel = true
    }
}
