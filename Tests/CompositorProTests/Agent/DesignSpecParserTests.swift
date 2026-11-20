import Foundation
import Testing
@testable import CompositorPro

@Suite("Design Spec Parser & Application")
@MainActor
struct DesignSpecParserTests {

    private let sampleYamlFrontmatter = """
    ---
    colors:
      background: "#0B0C10"
      surface: "#1F2833"
      text: "#C5C6C7"
      primary: "#66FCF1"
      accent: "#45A29E"
      border: "#1F2833"
    typography:
      display: "Montserrat"
      body: "Inter"
      baseSize: 48
    canvas:
      aspectRatio: "9:16"
      width: 1080
      height: 1920
    pacing:
      targetShotDuration: 3.5s
      minShotDuration: 1.5s
      maxShotDuration: 6.0s
    grade:
      preset: "cinematic"
    caption:
      template: "bold-pop"
      format: "shorts"
    ---

    # Product Brand Spec
    Brand guidelines and motion rules.
    """

    private let sampleCssVariablesSpec = """
    ---
    --bg: #111111;
    --surface: #222222;
    --text: #EEEEEE;
    --primary: #FF5722;
    --accent: #FF9800;
    --border: #333333;
    --font-display: 'Futura';
    --font-body: 'Helvetica';
    --font-size: 54;
    --aspect-ratio: 16:9;
    --pacing-target: 2.8s;
    ---
    """

    private let sampleMarkdownSectionsSpec = """
    # Design Specification

    ## Palette
    - **Background**: `#0B0C10`
    - **Surface**: `#1F2833`
    - **Text**: `#C5C6C7`
    - **Primary**: `#66FCF1`
    - **Accent**: `#45A29E`
    - **Border**: `#1F2833`

    ## Typography
    - **Display Font**: Anton
    - **Body Font**: Arial
    - **Base Size**: 50

    ## Canvas
    - **Aspect Ratio**: 1:1
    - **Resolution**: 1080x1080

    ## Pacing
    - **Target Shot Duration**: 4.0s
    - **Min Duration**: 2.0s
    - **Max Duration**: 8.0s

    ## Grade
    - **Preset**: documentary

    ## Caption
    - **Template**: bold-pop
    """

    @Test func parsesYamlFrontmatterDesignSpec() throws {
        let spec = try DesignSpecParser.parse(markdown: sampleYamlFrontmatter)

        #expect(spec.palette.background?.hexString.hasPrefix("#0B0C10") == true)
        #expect(spec.palette.primary?.hexString.hasPrefix("#66FCF1") == true)
        #expect(spec.palette.accent?.hexString.hasPrefix("#45A29E") == true)
        #expect(spec.palette.text?.hexString.hasPrefix("#C5C6C7") == true)

        #expect(spec.typography.displayFont == "Montserrat")
        #expect(spec.typography.bodyFont == "Inter")
        #expect(spec.typography.baseSize == 48)

        #expect(spec.canvas.aspectRatio == "9:16")
        let dims = spec.canvas.resolvedDimensions()
        #expect(dims?.width == 1080)
        #expect(dims?.height == 1920)

        #expect(spec.pacing.targetShotDurationSeconds == 3.5)
        #expect(spec.pacing.minShotDurationSeconds == 1.5)
        #expect(spec.pacing.maxShotDurationSeconds == 6.0)

        #expect(spec.grade.preset == "cinematic")
        #expect(spec.caption.templateId == "bold-pop")
        #expect(spec.caption.format == "shorts")
    }

    @Test func parsesCssVariablesFrontmatter() throws {
        let spec = try DesignSpecParser.parse(markdown: sampleCssVariablesSpec)

        #expect(spec.palette.background?.hexString.hasPrefix("#111111") == true)
        #expect(spec.palette.primary?.hexString.hasPrefix("#FF5722") == true)
        #expect(spec.palette.accent?.hexString.hasPrefix("#FF9800") == true)

        #expect(spec.typography.displayFont == "Futura")
        #expect(spec.typography.bodyFont == "Helvetica")
        #expect(spec.typography.baseSize == 54)

        #expect(spec.canvas.aspectRatio == "16:9")
        let dims = spec.canvas.resolvedDimensions()
        #expect(dims?.width == 1920)
        #expect(dims?.height == 1080)

        #expect(spec.pacing.targetShotDurationSeconds == 2.8)
    }

    @Test func parsesMarkdownSectionsWithoutFrontmatter() throws {
        let spec = try DesignSpecParser.parse(markdown: sampleMarkdownSectionsSpec)

        #expect(spec.palette.background?.hexString.hasPrefix("#0B0C10") == true)
        #expect(spec.palette.primary?.hexString.hasPrefix("#66FCF1") == true)

        #expect(spec.typography.displayFont == "Anton")
        #expect(spec.typography.bodyFont == "Arial")
        #expect(spec.typography.baseSize == 50)

        #expect(spec.canvas.aspectRatio == "1:1")
        let dims = spec.canvas.resolvedDimensions()
        #expect(dims?.width == 1080)
        #expect(dims?.height == 1080)

        #expect(spec.pacing.targetShotDurationSeconds == 4.0)
        #expect(spec.grade.preset == "documentary")
        #expect(spec.caption.templateId == "bold-pop")
    }

    @Test func exportsAndRoundTripsDesignSpec() throws {
        let original = try DesignSpecParser.parse(markdown: sampleYamlFrontmatter)
        let exported = DesignSpecParser.exportMarkdown(spec: original)
        let roundTripped = try DesignSpecParser.parse(markdown: exported)

        #expect(roundTripped.typography.displayFont == original.typography.displayFont)
        #expect(roundTripped.typography.bodyFont == original.typography.bodyFont)
        #expect(roundTripped.canvas.aspectRatio == original.canvas.aspectRatio)
        #expect(roundTripped.pacing.targetShotDurationSeconds == original.pacing.targetShotDurationSeconds)
        #expect(roundTripped.grade.preset == original.grade.preset)
        #expect(roundTripped.caption.templateId == original.caption.templateId)
        #expect(roundTripped.palette.primary?.hexString == original.palette.primary?.hexString)
    }

    @Test func appliesDesignSpecToEditorViewModel() throws {
        let editor = EditorViewModel()
        editor.applyTimelineSettings(fps: 30, width: 1920, height: 1080)

        var titleClip = Clip(
            mediaRef: "title-ref",
            mediaType: .text,
            startFrame: 0,
            durationFrames: 60,
            textStyle: TextStyle(fontName: "Helvetica", fontSize: 60)
        )
        titleClip.captionGroupId = nil

        var captionClip = Clip(
            mediaRef: "cap-ref",
            mediaType: .text,
            startFrame: 60,
            durationFrames: 60,
            textStyle: TextStyle(fontName: "Helvetica", fontSize: 40)
        )
        captionClip.captionGroupId = "cg-1"

        let videoClip = Clip(
            mediaRef: "video-ref",
            mediaType: .video,
            startFrame: 0,
            durationFrames: 120
        )

        let track = Track(type: .video, name: "Content", clips: [titleClip, captionClip, videoClip])
        editor.timeline.tracks = [track]

        let spec = try DesignSpecParser.parse(markdown: sampleYamlFrontmatter)
        let receipt = try editor.applyDesignSpec(spec)

        #expect(receipt.appliedAspectRatio == "9:16")
        #expect(receipt.newDimensions == [1080, 1920])
        #expect(editor.timeline.width == 1080)
        #expect(editor.timeline.height == 1920)

        let updatedTitle = editor.clipFor(id: titleClip.id)
        #expect(updatedTitle?.textStyle?.fontName == "Montserrat")
        #expect(updatedTitle?.textStyle?.color.hexString.hasPrefix("#66FCF1") == true)

        let updatedCaption = editor.clipFor(id: captionClip.id)
        #expect(updatedCaption?.textStyle?.fontName == "Inter")
        #expect(updatedCaption?.textStyle?.color.hexString.hasPrefix("#C5C6C7") == true)

        #expect(receipt.gradedClipsCount == 1)
        #expect(receipt.appliedGradePreset == "cinematic")
        #expect(receipt.updatedPreferences == true)
        #expect(FilmmakingStylePreferences.shared.data.pacing.targetShotDurationSeconds == 3.5)
    }

    @Test func toolExecutionAppliesAndExportsDesignSpec() async throws {
        let editor = EditorViewModel()
        let executor = ToolExecutor(editor: editor)

        let applyResult = await executor.execute(
            name: "apply_design_spec",
            args: ["specMarkdown": sampleYamlFrontmatter],
            source: "test"
        )
        #expect(!applyResult.isError)

        let exportResult = await executor.execute(
            name: "export_design_spec",
            args: [:],
            source: "test"
        )
        #expect(!exportResult.isError)
        #expect(exportResult.text.contains("aspectRatio"))

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_frame_\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try sampleYamlFrontmatter.write(to: tempURL, atomically: true, encoding: .utf8)

        let fileApplyResult = await executor.execute(
            name: "apply_design_spec",
            args: ["filePath": tempURL.path],
            source: "test"
        )
        #expect(!fileApplyResult.isError)
    }
}

