import Foundation

enum BuildMode {
    #if PALMIER_EDITOR_ONLY
    static let isEditorOnly = true
    #else
    static let isEditorOnly = false
    #endif

    static let editorOnlyUnavailableMessage = "This feature is unavailable in the experimental Intel editor-only build."
}
