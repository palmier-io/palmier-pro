import Foundation
import FalClient

struct AudioGenerationSubmission {
    let genInput: GenerationInput
    let model: AudioModelConfig
    let params: AudioGenerationParams
    let placeholderDuration: Double
    let name: String?
    let folderId: String?

    @MainActor
    @discardableResult
    func submit(
        service: GenerationService,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        service.generate(
            genInput: genInput,
            assetType: .audio,
            placeholderDuration: placeholderDuration,
            name: name,
            folderId: folderId,
            buildInput: { _ in
                (model.baseEndpoint, model.buildInput(params: params))
            },
            responseKeyPath: FalResponsePaths.audio,
            fileExtension: "mp3",
            projectURL: projectURL,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    static func placeholderDuration(model: AudioModelConfig, params: AudioGenerationParams) -> Double {
        if let secs = params.durationSeconds { return Double(secs) }
        return model.category == .music
            ? Defaults.audioMusicDurationSeconds
            : Defaults.audioTTSDurationSeconds
    }

    static func make(
        genInput: GenerationInput,
        model: AudioModelConfig,
        params: AudioGenerationParams,
        name: String? = nil,
        folderId: String? = nil
    ) -> AudioGenerationSubmission {
        AudioGenerationSubmission(
            genInput: genInput,
            model: model,
            params: params,
            placeholderDuration: placeholderDuration(model: model, params: params),
            name: name,
            folderId: folderId
        )
    }
}
