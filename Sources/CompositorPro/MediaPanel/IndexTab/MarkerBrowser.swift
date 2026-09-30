import SwiftUI

private extension TimelineMarker.Status {
    var titleKey: String {
        switch self {
        case .open: L10n.key("Open")
        case .review: L10n.key("Review")
        case .resolved: L10n.key("Resolved")
        }
    }
    var color: Color {
        switch self {
        case .open: AppTheme.Status.pendingColor
        case .review: AppTheme.Status.warningColor
        case .resolved: AppTheme.Status.successColor
        }
    }
}

@MainActor @ViewBuilder
private func markerStatusButtons(selected: TimelineMarker.Status?, includesAll: Bool = false,
                                 action: @escaping (TimelineMarker.Status?) -> Void) -> some View {
    if includesAll {
        Button { action(nil) } label: {
            Label(L10n.string("All Statuses"), systemImage: selected == nil ? "checkmark" : "circle")
        }
        Divider()
    }
    ForEach(TimelineMarker.Status.allCases, id: \.self) { status in
        Button { action(status) } label: {
            Label(L10n.string(key: status.titleKey),
                  systemImage: selected == status ? "checkmark" : "circle.fill")
        }
    }
}

struct MarkerBrowser: View {
    @Environment(EditorViewModel.self) private var editor
    let timeline: Timeline
    @Binding var indexSection: IndexBrowserSection
    @State private var searchQuery = ""
    @State private var statusFilter: TimelineMarker.Status?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = MarkerBrowserNavigation.sortedMarkers(
            timeline.markers, matching: query, status: statusFilter)
        VStack(spacing: AppTheme.Spacing.zero) {
            toolbar
            Rectangle().fill(AppTheme.Border.primaryColor)
                .frame(height: AppTheme.BorderWidth.hairline)
            if timeline.markers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    if markers.isEmpty {
                        Text(query.isEmpty
                            ? L10n.string("No markers match this filter.")
                            : L10n.string("No matches for “\(query)”"))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .frame(maxWidth: .infinity).padding(.top, AppTheme.Spacing.xl)
                    } else {
                        LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                            ForEach(markers) {
                                MarkerBrowserRow(marker: $0, fps: timeline.fps,
                                                 thumbnailSize: thumbnailSize,
                                                 timelineId: timeline.id)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { editor.selectPreviewTab(id: PreviewTab.timeline.id) }
    }

    private var toolbar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if editor.isMediaPanelSearchExpanded {
                ExpandablePanelSearch(text: $searchQuery, focus: $isSearchFocused)
                    .layoutPriority(1)
            } else {
                IndexModeTabs(selection: $indexSection)
                Spacer(minLength: AppTheme.Spacing.zero)
                ExpandablePanelSearch(text: $searchQuery, focus: $isSearchFocused)
                statusFilterMenu
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppTheme.Background.surfaceColor)
        .animation(.easeInOut(duration: AppTheme.Anim.transition),
                   value: editor.isMediaPanelSearchExpanded)
    }

    private var thumbnailSize: CGSize {
        MarkerThumbnailMetrics.size(
            canvas: CGSize(width: timeline.width, height: timeline.height),
            height: AppTheme.MediaPanel.markerIndexThumbnailHeight)
    }

    private var statusFilterMenu: some View {
        Menu {
            markerStatusButtons(selected: statusFilter, includesAll: true) { statusFilter = $0 }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(statusFilter?.color ?? AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
        .accessibilityLabel(L10n.string("Status Filter"))
        .accessibilityValue(statusFilter.map { L10n.string(key: $0.titleKey) }
            ?? L10n.string("All Statuses"))
        .help(L10n.string("Filter markers by status"))
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Spacer()
            TimelineMarkerShape().fill(AppTheme.Text.mutedColor)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.smMd)
            Text(L10n.string("No markers"))
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(L10n.string("Press M in the timeline to add a marker."))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MarkerBrowserRow: View {
    private enum TimingField { case time, duration }
    @Environment(EditorViewModel.self) private var editor
    let marker: TimelineMarker
    let fps: Int
    let thumbnailSize: CGSize
    let timelineId: String
    @State private var comment: String
    @State private var commentBaseline: String
    @State private var isColorPickerPresented = false
    @State private var isRemoving = false
    @FocusState private var commentFocused: Bool

    init(marker: TimelineMarker, fps: Int, thumbnailSize: CGSize, timelineId: String) {
        self.marker = marker
        self.fps = fps
        self.thumbnailSize = thumbnailSize
        self.timelineId = timelineId
        _comment = State(initialValue: marker.comment)
        _commentBaseline = State(initialValue: marker.comment)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            MarkerThumbnailView(
                timelineId: timelineId, frame: marker.startFrame, size: thumbnailSize)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        markerColorButton
                        Text(verbatim: marker.name)
                            .font(.system(size: AppTheme.FontSize.sm)).italic()
                            .foregroundStyle(AppTheme.Text.secondaryColor).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        timingField(.time)
                        timingField(.duration)
                        statusButton
                        deleteButton
                    }
                    .fixedSize()
                }
                commentField
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.Spacing.sm).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()).onTapGesture { select() }
        .hoverHighlight(
            cornerRadius: AppTheme.Radius.xs,
            isActive: editor.selectedTimelineMarkerIds.contains(marker.id)
        )
        .padding(.horizontal, AppTheme.Spacing.xxs)
        .onChange(of: marker) { _, updated in
            guard !commentFocused else { return }
            comment = updated.comment
            commentBaseline = updated.comment
        }
        .onDisappear {
            if commentFocused, !isRemoving { commitComment() }
            clearPreview()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction { select() }
    }

    private var markerColorButton: some View {
        Button {
            select(seek: false)
            isColorPickerPresented = true
        } label: {
            TimelineMarkerShape().fill(marker.color.swiftUIColor)
                .overlay {
                    TimelineMarkerShape().stroke(
                        Color(nsColor: AppTheme.Border.timelineMarker),
                        lineWidth: AppTheme.BorderWidth.thin
                    )
                }
                .frame(width: AppTheme.TimelineMarker.flagWidth,
                       height: AppTheme.TimelineMarker.flagHeight)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
        }
        .buttonStyle(.plain).focusable(false)
        .accessibilityLabel(L10n.string("Color"))
        .popover(isPresented: $isColorPickerPresented, arrowEdge: .bottom) {
            MarkerColorPicker(selection: marker.color) { color in
                change(actionName: "Change Marker Color") { $0.color = color }
                isColorPickerPresented = false
            }
            .padding(AppTheme.Spacing.md)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: remove) {
            actionIcon("trash", color: AppTheme.Text.tertiaryColor)
        }
        .buttonStyle(.plain).focusable(false)
        .help(L10n.string("Delete Marker"))
    }

    private var statusButton: some View {
        Menu {
            markerStatusButtons(selected: marker.status) {
                guard let status = $0 else { return }
                change(actionName: "Change Marker Status") { $0.status = status }
            }
        } label: {
            actionIcon("circle.fill", color: marker.status.color)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
        .help(L10n.string("Status: \(L10n.string(key: marker.status.titleKey))"))
    }

    private func actionIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(color)
            .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
    }

    private func timingField(_ field: TimingField) -> some View {
        let isDuration = field == .duration
        let keyPath: WritableKeyPath<TimelineMarker, Int> =
            isDuration ? \.durationFrames : \.startFrame
        let secondsPerFrame = fps > 0 ? 1 / Double(fps) : 1
        let label = isDuration ? L10n.string("Duration") : L10n.string("Time")
        return ScrubbableNumberField(
            value: Double(marker[keyPath: keyPath]),
            range: 0...Double(Int32.max),
            displayMultiplier: isDuration ? secondsPerFrame : 1,
            format: isDuration ? "%.1f" : "%.0f",
            valueSuffix: isDuration ? "s" : "",
            dragSensitivity: isDuration ? secondsPerFrame : 1,
            fieldWidth: isDuration ? AppTheme.MediaPanel.markerIndexDurationFieldWidth
                : AppTheme.MediaPanel.markerIndexTimeFieldWidth,
            fieldFill: AppTheme.Background.raisedColor,
            valueFontSize: AppTheme.FontSize.xs,
            dragValueAdjustment: { $0.rounded() },
            displayTextOverride: {
                if isDuration { return $0 == 0 ? "-" : nil }
                return formatTimecode(frame: Int($0), fps: fps)
            },
            parseTextOverride: isDuration ? nil
                : { parseTimecode($0, fps: fps).map(Double.init) },
            onChanged: { preview($0, at: keyPath) },
            onInteractionStart: { select(seek: false) },
            onInteractionEnd: clearPreview,
            onCommit: {
                commit($0, at: keyPath,
                       actionName: isDuration ? "Change Marker Duration" : "Move Marker")
            }
        )
        .accessibilityLabel(label).help(label)
    }

    private var commentField: some View {
        TextField(L10n.string("Add a comment"), text: $comment, axis: .vertical)
            .textFieldStyle(.plain).font(.system(size: AppTheme.FontSize.smMd))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .lineLimit(2, reservesSpace: true).frame(height: AppTheme.MediaPanel.markerIndexCommentHeight)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .editorValueField(minHeight: AppTheme.MediaPanel.markerIndexCommentHeight,
                              fill: AppTheme.Background.raisedColor)
            .focused($commentFocused).accessibilityLabel(L10n.string("Comments")).help(comment)
            .onChange(of: commentFocused) { _, focused in
                if focused {
                    syncCommentFromModel()
                    select()
                } else if !isRemoving {
                    commitComment()
                }
            }
            .onExitCommand {
                syncCommentFromModel()
                commentFocused = false
            }
            .onKeyPress(.return, phases: .down) {
                guard $0.modifiers.contains(.command) else { return .ignored }
                commitComment()
                commentFocused = false
                return .handled
            }
    }

    private func select(seek: Bool = true) {
        guard let marker = editor.timelineMarker(id: marker.id) else { return }
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        editor.selectedClipIds.removeAll()
        editor.selectedGap = nil
        editor.selectedTimelineRange = nil
        editor.selectedTimelineMarkerIds = [marker.id]
        if seek { editor.seekToFrame(marker.startFrame) }
    }
    private func preview(_ value: Double, at keyPath: WritableKeyPath<TimelineMarker, Int>) {
        let value = Int(value)
        guard var preview = editor.timelineMarker(id: marker.id) else { return }
        preview[keyPath: keyPath] = value
        editor.timelineMarkerPreview = preview
    }
    private func commit(
        _ value: Double,
        at keyPath: WritableKeyPath<TimelineMarker, Int>,
        actionName: String
    ) {
        let value = Int(value)
        change(actionName: actionName) { $0[keyPath: keyPath] = value }
    }
    private func clearPreview() {
        if editor.timelineMarkerPreview?.id == marker.id { editor.timelineMarkerPreview = nil }
    }
    private func syncCommentFromModel() {
        comment = editor.timelineMarker(id: marker.id)?.comment ?? marker.comment
        commentBaseline = comment
    }
    private func commitComment() {
        guard let current = editor.timelineMarker(id: marker.id) else { return }
        guard current.comment == commentBaseline else {
            syncCommentFromModel()
            editor.refuseWithToast(L10n.string(
                "The marker comment changed while you were editing. Review it and try again."
            ))
            return
        }
        guard current.comment != comment else { return }
        let updatedComment = comment
        change(actionName: "Change Marker Comment") { $0.comment = updatedComment }
    }
    private func change(actionName: String, update: (inout TimelineMarker) -> Void) {
        do {
            guard var updated = editor.timelineMarker(id: marker.id) else {
                throw TimelineMarkerValidationError.invalidRange
            }
            update(&updated)
            _ = try editor.changeTimelineMarkers(updates: [updated], actionName: actionName)
            syncCommentFromModel()
        } catch {
            syncCommentFromModel()
            editor.refuseWithToast(L10n.string("Couldn't change marker."))
        }
    }
    private func remove() {
        isRemoving = true
        commentFocused = false
        do {
            _ = try editor.changeTimelineMarkers(
                deleteIds: [marker.id], actionName: "Delete Marker")
        } catch {
            isRemoving = false
            editor.refuseWithToast(L10n.string("Couldn't delete marker."))
        }
    }
}

private struct MarkerThumbnailView: View {
    private struct RequestID: Hashable {
        let timelineId: String
        let frame: Int
        let compositionGeneration: Int
    }
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.displayScale) private var displayScale
    let timelineId: String
    let frame: Int
    let size: CGSize
    @State private var image: CGImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            AppTheme.MediaOverlay.backgroundColor
            if let image {
                Image(decorative: image, scale: 1).resizable()
                    .aspectRatio(contentMode: .fit)
            } else if isLoading {
                ProgressView().controlSize(.mini)
                    .tint(AppTheme.MediaOverlay.secondaryColor)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        }
        .task(id: RequestID(timelineId: timelineId, frame: frame,
                            compositionGeneration: editor.timelineCompositionGeneration)) {
            image = nil
            isLoading = true
            let maximumSize = CGSize(width: (size.width * displayScale).rounded(),
                                     height: (size.height * displayScale).rounded())
            let loaded = await editor.videoEngine?.timelineThumbnail(
                timelineId: timelineId, frame: frame, maximumSize: maximumSize)
            guard !Task.isCancelled else { return }
            image = loaded
            isLoading = false
        }
        .accessibilityHidden(true)
    }
}

enum MarkerBrowserNavigation {
    static func sortedMarkers(
        _ markers: [TimelineMarker],
        matching query: String,
        status: TimelineMarker.Status? = nil
    ) -> [TimelineMarker] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return markers.filter {
            (status == nil || $0.status == status)
                && (query.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.comment.localizedCaseInsensitiveContains(query))
        }
        .sorted { ($0.startFrame, $0.id) < ($1.startFrame, $1.id) }
    }
}

enum MarkerThumbnailMetrics {
    static func size(canvas: CGSize, height: CGFloat) -> CGSize {
        guard canvas.width > 0, canvas.height > 0, height > 0 else { return .zero }
        return CGSize(width: canvas.width * height / canvas.height, height: height)
    }
}
