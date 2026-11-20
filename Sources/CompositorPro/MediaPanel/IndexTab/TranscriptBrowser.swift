import SwiftUI

struct TranscriptBrowser: View {
    @Environment(EditorViewModel.self) private var editor
    let document: EditorViewModel.TimelineTranscriptDocument
    let captionSources: [EditorViewModel.TimelineTranscriptDocument]
    @Binding var source: TranscriptIndexSource
    @Binding var indexSection: IndexBrowserSection

    @State private var searchQuery = ""
    @State private var jumpTargetId: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = TranscriptBrowserNavigation.rows(
            document.rows,
            matching: query
        )
        let timelineIndex = TranscriptBrowserTimelineIndex(
            sortedRows: document.rows
        )

        return ScrollViewReader { proxy in
            VStack(spacing: AppTheme.Spacing.zero) {
                controls(timelineIndex: timelineIndex) { rowId in
                    searchQuery = ""
                    jumpTargetId = rowId
                }
                Rectangle()
                    .fill(AppTheme.Border.primaryColor)
                    .frame(height: AppTheme.BorderWidth.hairline)
                ScrollView {
                    if rows.isEmpty {
                        Text(L10n.string("No matches for “\(query)”"))
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .frame(maxWidth: .infinity)
                            .padding(.top, AppTheme.Spacing.xl)
                    } else {
                        LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                            ForEach(rows) { row in
                                TranscriptBrowserRow(
                                    row: row,
                                    fps: document.fps,
                                    playheadState: editor.playheadState
                                )
                                .id(row.id)
                            }
                        }
                    }
                }
            }
            .task(id: jumpTargetId) {
                guard let targetId = jumpTargetId else { return }
                await Task.yield()
                guard !Task.isCancelled, jumpTargetId == targetId else { return }
                withAnimation(.easeOut(duration: AppTheme.Anim.transition)) {
                    proxy.scrollTo(targetId, anchor: .center)
                }
                jumpTargetId = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func controls(
        timelineIndex: TranscriptBrowserTimelineIndex,
        onJump: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if editor.isMediaPanelSearchExpanded {
                ExpandablePanelSearch(text: $searchQuery, focus: $isSearchFocused)
                    .layoutPriority(1)
            } else {
                IndexModeTabs(selection: $indexSection)
                Spacer(minLength: AppTheme.Spacing.zero)
                if !captionSources.isEmpty {
                    TranscriptSourceMenu(
                        document: document,
                        captionSources: captionSources,
                        source: $source
                    )
                }
                ExpandablePanelSearch(text: $searchQuery, focus: $isSearchFocused)
                TranscriptJumpToPlayheadButton(
                    timelineIndex: timelineIndex,
                    playheadState: editor.playheadState,
                    onJump: onJump
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppTheme.Background.surfaceColor)
        .animation(
            .easeInOut(duration: AppTheme.Anim.transition),
            value: editor.isMediaPanelSearchExpanded
        )
    }
}

struct TranscriptSourceMenu: View {
    @Environment(EditorViewModel.self) private var editor
    let document: EditorViewModel.TimelineTranscriptDocument?
    let captionSources: [EditorViewModel.TimelineTranscriptDocument]
    @Binding var source: TranscriptIndexSource

    var body: some View {
        Menu {
            Button {
                source = .transcript
            } label: {
                Label(
                    L10n.string("Transcript"),
                    systemImage: document?.sourceCaptionGroupId == nil ? "checkmark" : ""
                )
            }
            if !captionSources.isEmpty {
                Divider()
                ForEach(captionSources, id: \.sourceCaptionGroupId) { caption in
                    Button {
                        if let groupId = caption.sourceCaptionGroupId {
                            source = .captions(groupId)
                        }
                    } label: {
                        Label(
                            trackLabel(for: caption),
                            systemImage: document?.sourceCaptionGroupId
                                == caption.sourceCaptionGroupId ? "checkmark" : ""
                        )
                    }
                }
            }
        } label: {
            EditorMenuValue(text: document.map(trackLabel) ?? L10n.string("Transcript"), expanded: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: AppTheme.MediaPanel.transcriptSourceMenuWidth)
        .focusable(false)
    }

    private func trackLabel(
        for document: EditorViewModel.TimelineTranscriptDocument
    ) -> String {
        guard let trackId = document.sourceTrackId,
              let index = editor.timeline.tracks.firstIndex(where: { $0.id == trackId }) else {
            return L10n.string("Transcript")
        }
        let code = editor.timelineTrackDisplayLabel(at: index)
        return L10n.string("Caption \(code)")
    }
}

private struct TranscriptJumpToPlayheadButton: View {
    let timelineIndex: TranscriptBrowserTimelineIndex
    let playheadState: PreviewPlayheadState
    let onJump: (String) -> Void

    var body: some View {
        let currentRow = timelineIndex.currentRow(at: playheadState.timelineFrame)

        Button {
            if let currentRow { onJump(currentRow.id) }
        } label: {
            Image(systemName: "timeline.selection")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(
                    currentRow == nil
                        ? AppTheme.Text.mutedColor
                        : AppTheme.Text.secondaryColor
                )
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(currentRow == nil)
        .hoverTooltip(
            L10n.string("Jump to Playhead"),
            alignment: .bottomTrailing
        )
    }
}

private struct TranscriptBrowserRow: View {
    @Environment(EditorViewModel.self) private var editor
    let row: EditorViewModel.TimelineTranscriptRow
    let fps: Int
    let playheadState: PreviewPlayheadState

    var body: some View {
        let startTimecode = formatTimecode(frame: row.startFrame, fps: fps)
        let durationLabel = TranscriptBrowserMetrics.durationLabel(
            durationFrames: row.durationFrames,
            fps: fps
        )

        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text(verbatim: startTimecode)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .monospacedDigit()
                        .frame(
                            width: AppTheme.MediaPanel.captionIndexTimecodeWidth,
                            alignment: .leading
                        )
                    Text(verbatim: durationLabel ?? "")
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .monospacedDigit()
                        .frame(
                            width: AppTheme.MediaPanel.captionIndexDurationWidth,
                            alignment: .leading
                        )
                }
                .font(.system(
                    size: AppTheme.FontSize.xs,
                    weight: AppTheme.FontWeight.medium
                ))
                .lineLimit(1)

                TranscriptBrowserPlayheadText(
                    content: row.text,
                    startFrame: row.startFrame,
                    endFrame: row.endFrame,
                    playheadState: playheadState
                )
                .font(.system(size: AppTheme.FontSize.smMd))
                .lineSpacing(AppTheme.Spacing.zero)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(
            cornerRadius: AppTheme.Radius.xs,
            isActive: editor.selectedClipIds.contains(row.clipId)
        )
        .padding(.horizontal, AppTheme.Spacing.xxs)
        .accessibilityLabel(Text(verbatim: row.text))
        .accessibilityValue(Text(verbatim: accessibilityValue(
            startTimecode: startTimecode,
            durationLabel: durationLabel
        )))
    }

    private func accessibilityValue(startTimecode: String, durationLabel: String?) -> String {
        if let durationLabel {
            return "\(startTimecode), \(durationLabel)"
        }
        return startTimecode
    }

    private func select() {
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        editor.selectedGap = nil
        editor.selectedTimelineRange = nil
        editor.selectedTimelineMarkerIds = []
        editor.selectedClipIds = Set(
            [row.clipId] + editor.linkedPartnerIds(of: row.clipId)
        )
        editor.seekToFrame(row.startFrame)
    }
}

private struct TranscriptBrowserPlayheadText: View {
    let content: String
    let startFrame: Int
    let endFrame: Int
    let playheadState: PreviewPlayheadState

    var body: some View {
        let frame = playheadState.timelineFrame
        TranscriptBrowserCurrentText(
            content: content,
            isCurrent: startFrame <= frame && frame < endFrame
        )
        .equatable()
    }
}

private struct TranscriptBrowserCurrentText: View, Equatable {
    let content: String
    let isCurrent: Bool

    var body: some View {
        Text(verbatim: content)
            .foregroundStyle(
                isCurrent
                    ? AppTheme.Accent.timecodeColor
                    : AppTheme.Text.primaryColor
            )
    }
}

enum TranscriptBrowserMetrics {
    static func durationLabel(durationFrames: Int, fps: Int) -> String? {
        guard durationFrames > 0, fps > 0 else { return nil }
        let seconds = Double(durationFrames) / Double(fps)
        guard seconds.isFinite else { return nil }
        return String(format: "%.1fs", seconds)
    }
}

struct TranscriptBrowserTimelineIndex {
    private let rows: [EditorViewModel.TimelineTranscriptRow]
    private let longestEndingRowByPrefix: [Int]

    init(sortedRows rows: [EditorViewModel.TimelineTranscriptRow]) {
        self.rows = rows
        var longestEndingRowByPrefix: [Int] = []
        if !rows.isEmpty {
            var longestEndingIndex = 0
            for index in rows.indices {
                if rows[index].endFrame >= rows[longestEndingIndex].endFrame {
                    longestEndingIndex = index
                }
                longestEndingRowByPrefix.append(longestEndingIndex)
            }
        }
        self.longestEndingRowByPrefix = longestEndingRowByPrefix
    }

    func currentRow(at frame: Int) -> EditorViewModel.TimelineTranscriptRow? {
        var lowerBound = 0
        var upperBound = rows.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if rows[midpoint].startFrame <= frame {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        guard lowerBound > 0 else { return nil }
        let latestIndex = lowerBound - 1
        let latest = rows[latestIndex]
        if frame < latest.endFrame { return latest }

        guard latestIndex > 0 else { return nil }
        let fallback = rows[longestEndingRowByPrefix[latestIndex - 1]]
        return frame < fallback.endFrame ? fallback : nil
    }
}

enum TranscriptBrowserNavigation {
    static func captionFallbacks(
        in timeline: Timeline
    ) -> [EditorViewModel.TimelineTranscriptDocument] {
        let tracks = timeline.tracks.filter { !$0.hidden }
            + timeline.tracks.filter(\.hidden)
        var documents: [EditorViewModel.TimelineTranscriptDocument] = []
        for track in tracks {
            var seen: Set<String> = []
            let groupIds = track.clips.compactMap(\.captionGroupId).filter {
                seen.insert($0).inserted
            }
            for groupId in groupIds {
                let rows = track.clips.filter {
                    $0.mediaType == .text && $0.captionGroupId == groupId
                }
                .sorted { ($0.startFrame, $0.id) < ($1.startFrame, $1.id) }
                .map {
                    EditorViewModel.TimelineTranscriptRow(
                        id: $0.id,
                        clipId: $0.id,
                        text: $0.textContent ?? "",
                        startFrame: $0.startFrame,
                        endFrame: $0.endFrame
                    )
                }
                documents.append(EditorViewModel.TimelineTranscriptDocument(
                    fps: timeline.fps,
                    rows: rows,
                    sourceTrackId: track.id,
                    sourceCaptionGroupId: groupId
                ))
            }
        }
        return documents
    }

    static func rows(
        _ rows: [EditorViewModel.TimelineTranscriptRow],
        matching query: String
    ) -> [EditorViewModel.TimelineTranscriptRow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter {
            query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
        }
    }
}
