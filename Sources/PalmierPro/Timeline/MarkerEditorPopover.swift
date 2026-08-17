import SwiftUI
struct MarkerEditorPopover: View {
    @Environment(EditorViewModel.self) private var editor
    let marker: TimelineMarker
    let fps: Int
    let onPreview: (TimelineMarker) -> Void
    let onDismiss: () -> Void
    @State private var draft: TimelineMarker
    @FocusState private var commentsFocused: Bool
    init(
        marker: TimelineMarker,
        fps: Int,
        onPreview: @escaping (TimelineMarker) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.marker = marker
        self.fps = fps
        self.onPreview = onPreview
        self.onDismiss = onDismiss
        _draft = State(initialValue: marker)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Grid(alignment: .topLeading, horizontalSpacing: AppTheme.Spacing.sm, verticalSpacing: AppTheme.Spacing.md) {
                GridRow {
                    fieldLabel(L10n.string("Time"))
                    timeField(\.startFrame)
                    fieldLabel(L10n.string("Duration"))
                    timeField(\.durationFrames)
                }
                GridRow {
                    fieldLabel(L10n.string("Name"))
                    TextField(L10n.string("Marker name"), text: $draft.name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .editorValueField(fill: AppTheme.Background.raisedColor)
                        .gridCellColumns(3)
                }
                GridRow {
                    fieldLabel(L10n.string("Comments"))
                    TextField(L10n.string("Add a comment"), text: $draft.comment, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($commentsFocused)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .lineLimit(3, reservesSpace: true)
                        .frame(height: AppTheme.TimelineMarker.commentsHeight)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .editorValueField(
                            minHeight: AppTheme.TimelineMarker.commentsHeight,
                            fill: AppTheme.Background.raisedColor
                        )
                        .gridCellColumns(3)
                }
                GridRow {
                    fieldLabel(L10n.string("Color"))
                    MarkerColorPicker(selection: draft.color) { draft.color = $0; onPreview(draft) }
                    .gridCellColumns(3)
                }
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(L10n.string("Remove Marker"), role: .destructive) {
                    editor.deleteSelectedTimelineMarker()
                    onDismiss()
                }
                .buttonStyle(.capsule(.secondary, size: .small))
                Spacer()
                Button(L10n.string("Done")) { apply() }
                    .buttonStyle(.capsule(.prominent, size: .small))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: AppTheme.TimelineMarker.editorWidth)
        .task { commentsFocused = true }
    }
    private func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }
    private func timeField(_ keyPath: WritableKeyPath<TimelineMarker, Int>) -> some View {
        let update: (Double) -> Void = {
            draft[keyPath: keyPath] = Int($0)
            onPreview(draft)
        }
        return ScrubbableNumberField(
            value: Double(draft[keyPath: keyPath]),
            range: 0...Double(Int32.max),
            dragSensitivity: 1,
            fieldWidth: AppTheme.TimelineMarker.timeFieldWidth,
            fieldFill: AppTheme.Background.raisedColor,
            dragValueAdjustment: { $0.rounded() },
            displayTextOverride: { formatTimecode(frame: Int($0), fps: fps) },
            parseTextOverride: { parseTimecode($0, fps: fps).map(Double.init) },
            onChanged: update,
            onCommit: update
        )
    }
    private func apply() {
        do {
            _ = try editor.changeTimelineMarkers(
                updates: [draft],
                actionName: "Edit Marker"
            )
            editor.selectedTimelineMarkerIds = []
            onDismiss()
        } catch {
            editor.refuseWithToast(L10n.string("Check the marker name, position, and duration."))
        }
    }
}
