import Foundation

enum BuildMode {
    #if PALMIER_EDITOR_ONLY
    static let isEditorOnly = true
    #else
    static let isEditorOnly = false
    #endif

    static let editorOnlyUnavailableMessage = "Unavailable in Intel editor-only build."
}
