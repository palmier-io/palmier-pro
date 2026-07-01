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
                            if model.paidOnly && !AccountService.shared.isPaid {
                                Button {
                                    SettingsWindowController.shared.show(tab: .account)
                                } label: {
                                    Label("\(model.displayName) (Paid)", systemImage: "lock.fill")
                                }
                            } else {
                                Button(model.displayName) { runUpscale(model) }
                            }
                        }
                    }
                }
                if availableActions.contains(.edit) {
                    Button("Edit…") { edit() }
                }
                if availableActions.contains(.generateMusic) {
                    Button("\(VideoToAudioEditKind.music.title)…") { videoAudio(kind: .music) }
                }
                if availableActions.contains(.generateSFX) {
                    Button("\(VideoToAudioEditKind.sfx.title)…") { videoAudio(kind: .sfx) }
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
        EditAction.available(for: asset)
    }

    private func runUpscale(_ model: UpscaleModelConfig) {
        _ = EditSubmitter.submitUpscale(asset: asset, model: model, editor: editor)
    }

    private func edit() {
        guard let stored = EditSubmitter.editSeed(for: asset) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func videoAudio(kind: VideoToAudioEditKind) {
        guard let stored = EditSubmitter.videoAudioSeed(for: asset, kind: kind) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func rerun() {
        let modelId = asset.generationInput?.model ?? ""
        if UpscaleModelConfig.allIds.contains(modelId) {
            _ = try? EditSubmitter.rerun(asset: asset, editor: editor)
        } else if let stored = asset.generationInput {
            editor.seedGenerationPanel(asset: asset, stored: stored)
        }
    }

    private func createVideo(asReference: Bool) {
        guard let stored = EditSubmitter.createVideoSeed(for: asset, asReference: asReference) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }
}
