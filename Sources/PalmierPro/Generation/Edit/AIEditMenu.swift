import SwiftUI

// AI Edit menu for a media asset's context menu.
struct AIEditMenu: View {
    let asset: MediaAsset
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        if availableActions.isEmpty && availableAudioTransforms.isEmpty {
            EmptyView()
        } else if !aiAllowed {
            Button("AI Edit") {}.disabled(true)
        } else {
            Menu("AI Edit") {
                if !enhanceActions.isEmpty {
                    Section("AI Enhance") {
                        if enhanceActions.contains(.upscale) {
                            editActionButton("Upscale…", action: .upscale) { runUpscale() }
                        }
                        if enhanceActions.contains(.edit) {
                            editActionButton("Edit…", action: .edit) { edit() }
                        }
                        if enhanceActions.contains(.rerun) {
                            Button("Rerun") { rerun() }
                        }
                        if enhanceActions.contains(.lipSync) {
                            editActionButton("Lip Sync…", action: .lipSync) { lipSync() }
                        }
                        if enhanceActions.contains(.reframe) {
                            editActionButton("Reframe…", action: .reframe) { reframe() }
                        }
                        if enhanceActions.contains(.createVideo) {
                            Menu("Create Video") {
                                Button("Set as first frame") { createVideo(asReference: false) }
                                Button("Set as reference") { createVideo(asReference: true) }
                            }
                        }
                    }
                }
                if !audioActions.isEmpty || !availableAudioTransforms.isEmpty {
                    Section("AI Audio") {
                        if audioActions.contains(.rerun) {
                            Button("Rerun") { rerun() }
                        }
                        ForEach(availableAudioTransforms, id: \.category) { kind in
                            Button(kind.menuTitle) { audioTransform(kind: kind) }
                        }
                        if audioActions.contains(.generateMusic) {
                            Button("\(VideoToAudioEditKind.music.title)…") {
                                videoAudio(kind: .music)
                            }
                        }
                        if audioActions.contains(.generateSFX) {
                            Button("\(VideoToAudioEditKind.sfx.title)…") {
                                videoAudio(kind: .sfx)
                            }
                        }
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

    private var enhanceActions: [EditAction] {
        availableActions.filter { $0.group(for: asset.type) == .enhance }
    }

    private var audioActions: [EditAction] {
        availableActions.filter { $0.group(for: asset.type) == .audio }
    }

    private var availableAudioTransforms: [AudioTransformEditKind] {
        AudioTransformEditKind.available(for: asset)
    }

    @ViewBuilder
    private func editActionButton(
        _ title: String,
        action: EditAction,
        perform: @escaping () -> Void
    ) -> some View {
        if action.requiresPaidPlan && !AccountService.shared.isPaid {
            Button {
                SettingsWindowController.shared.show(tab: .account)
            } label: {
                Label("\(title) (Paid)", systemImage: "lock.fill")
            }
        } else {
            Button(title, action: perform)
        }
    }

    private func runUpscale() {
        guard let model = UpscaleModelConfig.models(for: asset.type).first else { return }
        let stored = EditSubmitter.upscaleSeed(for: asset, model: model)
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func edit() {
        guard let stored = EditSubmitter.editSeed(for: asset) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func reframe() {
        guard let stored = EditSubmitter.reframeSeed(for: asset) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func lipSync() {
        guard let model = VideoModelConfig.lipSync,
              let stored = EditSubmitter.lipSyncSeed(for: asset, model: model) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func videoAudio(kind: VideoToAudioEditKind) {
        guard let stored = EditSubmitter.videoAudioSeed(for: asset, kind: kind) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func audioTransform(kind: AudioTransformEditKind) {
        guard let stored = EditSubmitter.audioTransformSeed(for: asset, kind: kind) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }

    private func rerun() {
        if let stored = asset.generationInput {
            editor.seedGenerationPanel(asset: asset, stored: stored)
        }
    }

    private func createVideo(asReference: Bool) {
        guard let stored = EditSubmitter.createVideoSeed(for: asset, asReference: asReference) else { return }
        editor.seedGenerationPanel(asset: asset, stored: stored)
    }
}
