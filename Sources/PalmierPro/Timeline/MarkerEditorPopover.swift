import SwiftUI
struct MarkerEditorPopover: View {
    @Environment(EditorViewModel.self) private var editor
    let marker: TimelineMarker
    let fps: Int
    let onPreview: (TimelineMarker) -> Void
    let onDismiss: () -> Void
    @State private var name: String
    @State private var comment: String
    @State private var startFrame: Int
    @State private var durationFrames: Int
    @State private var color: TextStyle.RGBA
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
        _name = State(initialValue: marker.name)
        _comment = State(initialValue: marker.comment)
        _startFrame = State(initialValue: marker.startFrame)
        _durationFrames = State(initialValue: marker.durationFrames)
        _color = State(initialValue: marker.color)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Grid(alignment: .topLeading, horizontalSpacing: AppTheme.Spacing.sm, verticalSpacing: AppTheme.Spacing.md) {
                GridRow {
                    fieldLabel(L10n.string("Time"))
                    timeField($startFrame, isDuration: false)
                    fieldLabel(L10n.string("Duration"))
                    timeField($durationFrames, isDuration: true)
                }
                GridRow {
                    fieldLabel(L10n.string("Name"))
                    TextField(L10n.string("Marker name"), text: $name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .editorValueField(fill: AppTheme.Background.raisedColor)
                        .gridCellColumns(3)
                }
                GridRow {
                    fieldLabel(L10n.string("Notes"))
                    TextField(String(), text: $comment, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .lineLimit(3, reservesSpace: true)
                        .frame(height: AppTheme.TimelineMarker.notesHeight)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .editorValueField(
                            minHeight: AppTheme.TimelineMarker.notesHeight,
                            fill: AppTheme.Background.raisedColor
                        )
                        .gridCellColumns(3)
                }
                GridRow {
                    fieldLabel(L10n.string("Color"))
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        ForEach(Array(AppTheme.TimelineMarker.presetColors.enumerated()), id: \.offset) { _, preset in
                            Button {
                                color = preset
                                preview { $0.color = preset }
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                        .stroke(
                                            color == preset ? AppTheme.Text.primaryColor : .clear,
                                            lineWidth: AppTheme.BorderWidth.medium
                                        )
                                    TimelineMarkerShape()
                                        .fill(preset.swiftUIColor)
                                        .padding(AppTheme.Spacing.xxs)
                                }
                                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: preset.hexString))
                        }
                    }
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
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: AppTheme.TimelineMarker.editorWidth)
    }
    private func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }
    private func timeField(_ value: Binding<Int>, isDuration: Bool) -> some View {
        let update: (Double) -> Void = {
            let next = Int($0)
            value.wrappedValue = next
            preview {
                if isDuration { $0.durationFrames = next } else { $0.startFrame = next }
            }
        }
        return ScrubbableNumberField(
            value: Double(value.wrappedValue),
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
    private func preview(_ change: (inout TimelineMarker) -> Void) {
        var preview = marker
        preview.startFrame = startFrame
        preview.durationFrames = durationFrames
        preview.color = color
        change(&preview)
        onPreview(preview)
    }
    private func apply() {
        do {
            _ = try editor.changeTimelineMarkers(
                updates: [TimelineMarkerUpdateRequest(
                    id: marker.id,
                    name: name,
                    startFrame: startFrame,
                    durationFrames: durationFrames,
                    color: color,
                    comment: comment
                )],
                actionName: "Edit Marker"
            )
            editor.selectedTimelineMarkerIds = []
            onDismiss()
        } catch {
            editor.refuseWithToast(L10n.string("Check the marker name, position, and duration."))
        }
    }
}
