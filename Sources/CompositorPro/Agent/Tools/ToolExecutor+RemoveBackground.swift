import Foundation

extension ToolExecutor {
    private struct RemoveBackgroundInput: DecodableToolArgs {
        var mediaRef: String?
        var mode: String?
        var feather: Double?
        var fillHex: String?
        var name: String?
        var folderId: String?

        static let allowedKeys: Set<String> = [
            "mediaRef", "mode", "feather", "fillHex", "name", "folderId",
        ]
    }

    /// Lifts a subject out of a still image, on device.
    func removeImageBackground(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(
            args, allowed: RemoveBackgroundInput.allowedKeys, path: "remove_image_background"
        )
        let input: RemoveBackgroundInput = try decodeToolArgs(args, path: "remove_image_background")

        guard let mediaRef = input.mediaRef, !mediaRef.isEmpty else {
            throw ToolError("remove_image_background requires mediaRef — the image to cut out.")
        }
        let mode: BackgroundRemover.Mode
        if let raw = input.mode, !raw.isEmpty {
            guard let parsed = BackgroundRemover.Mode(rawValue: raw) else {
                let known = BackgroundRemover.Mode.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolError("remove_image_background: mode must be one of: \(known). Got '\(raw)'.")
            }
            mode = parsed
        } else {
            mode = .subject
        }
        if let feather = input.feather, !(feather.isFinite && (0 ... 8).contains(feather)) {
            throw ToolError("remove_image_background: feather must be between 0 and 8; got \(feather).")
        }
        if let fillHex = input.fillHex, !fillHex.isEmpty, TextStyle.RGBA(hex: fillHex) == nil {
            throw ToolError("remove_image_background: fillHex must look like '#RRGGBB'; got '\(fillHex)'.")
        }

        let request = EditorViewModel.RemoveBackgroundRequest(
            mediaRef: mediaRef,
            mode: mode,
            feather: input.feather ?? 1.5,
            fillHex: input.fillHex.flatMap { $0.isEmpty ? nil : $0 },
            name: input.name,
            folderId: input.folderId
        )

        let receipt: EditorViewModel.RemoveBackgroundReceipt
        do {
            receipt = try await editor.removeImageBackground(request)
        } catch let error as EditorViewModel.RemoveBackgroundError {
            throw ToolError(error.description)
        } catch let error as BackgroundRemover.RemoveError {
            throw ToolError(error.description)
        }

        var notes = [
            "Segmentation ran on this machine with Apple's Vision framework. No model was "
                + "downloaded and nothing left the device.",
            "The cutout is a normal image asset: add_clips places it, and the compositor reads "
                + "its alpha.",
        ]
        if receipt.flattenedOnto != nil {
            notes.append("Flattened onto \(receipt.flattenedOnto!), so the background is opaque.")
        } else {
            notes.append("The background is transparent. Pass fillHex to flatten onto a colour instead.")
        }
        if receipt.subjectCoverage < 0.02 {
            notes.append(
                "The subject covered only \(Int(receipt.subjectCoverage * 100))% of the frame, "
                    + "so the cutout may be wrong. Try the other mode, or a clearer background."
            )
        }
        notes.append(
            "This is subject segmentation, not a matting network. Hair and fine edges will be "
                + "rough, and it fails when there is no clear subject. For a flat or green-screen "
                + "background, chroma key is more reliable."
        )

        return .ok(Self.jsonString([
            "mediaRef": receipt.asset.id,
            "name": receipt.asset.name,
            "path": receipt.asset.url.path,
            "width": receipt.width,
            "height": receipt.height,
            "mode": receipt.mode.rawValue,
            "subjectCoverage": receipt.subjectCoverage,
            "transparent": receipt.flattenedOnto == nil,
            "inLibrary": true,
            "changed": true,
            "notes": notes,
        ]) ?? "{}")
    }
}