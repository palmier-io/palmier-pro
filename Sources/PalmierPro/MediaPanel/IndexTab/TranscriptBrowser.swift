import AppKit
import SwiftUI

struct TranscriptBrowser: View {
    @Environment(EditorViewModel.self) private var editor
    let document: EditorViewModel.TimelineTranscriptDocument
    let captionSources: [EditorViewModel.TimelineTranscriptDocument]
    @Binding var source: TranscriptIndexSource
    @Binding var indexSection: IndexBrowserSection

    @State private var searchQuery = ""
    @State private var jumpTargetId: String?
    @State private var selectedWords: ClosedRange<Int>?
    @State private var selectionAnchor: Int?
    @State private var dragAnchor: Int?
    @State private var wordFrames: [Int: CGRect] = [:]
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = TranscriptBrowserNavigation.rows(
            document.rows,
            matching: query
        )
        let words = TranscriptBrowserNavigation.words(from: rows)
        let selected: Set<Int> = selectedWords.map { Set($0) } ?? []
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
                                    playheadFrame: editor.playheadState.timelineFrame,
                                    words: words,
                                    selectedWords: selected,
                                    onSelectRow: { selectRow(row.id, words: words) },
                                    onDragChanged: { updateDrag($0, words: words, seek: false) },
                                    onDragEnded: {
                                        updateDrag($0, words: words, seek: true)
                                        dragAnchor = nil
                                    }
                                )
                                .id(row.id)
                            }
                        }
                        .coordinateSpace(name: "transcript")
                        .onPreferenceChange(TranscriptWordFramesKey.self) { wordFrames = $0 }
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
        .onChange(of: source) { _, _ in
            selectedWords = nil
            selectionAnchor = nil
            dragAnchor = nil
        }
        .onChange(of: searchQuery) { _, _ in
            selectedWords = nil
            selectionAnchor = nil
            dragAnchor = nil
        }
    }

    private func updateDrag(
        _ value: DragGesture.Value,
        words: [TranscriptWord],
        seek: Bool
    ) {
        let start = TranscriptBrowserNavigation.wordIndex(at: value.startLocation, frames: wordFrames)
        let hit = TranscriptBrowserNavigation.wordIndex(at: value.location, frames: wordFrames) ?? start
        guard let start, let hit else { return }
        if dragAnchor == nil {
            if NSEvent.modifierFlags.contains(.shift), let selectionAnchor {
                dragAnchor = selectionAnchor
            } else {
                dragAnchor = start
                selectionAnchor = start
            }
        }
        applySelection(from: dragAnchor ?? start, to: hit, words: words, seek: seek)
    }

    private func selectRow(_ rowId: String, words: [TranscriptWord]) {
        let indices = words.indices.filter { words[$0].rowId == rowId }
        guard let first = indices.first, let last = indices.last else { return }
        selectionAnchor = first
        applySelection(from: first, to: last, words: words, seek: true)
    }

    private func applySelection(
        from start: Int,
        to end: Int,
        words: [TranscriptWord],
        seek: Bool
    ) {
        guard let range = TranscriptBrowserNavigation.timelineRange(
            from: words,
            startIndex: start,
            endIndex: end
        ) else { return }
        selectedWords = min(start, end)...max(start, end)
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        editor.selectedClipIds.removeAll()
        editor.selectedGap = nil
        editor.setTimelineRange(startFrame: range.startFrame, endFrame: range.endFrame)
        if seek { editor.seekToFrame(range.startFrame) }
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
    let row: EditorViewModel.TimelineTranscriptRow
    let fps: Int
    let playheadFrame: Int
    let words: [TranscriptWord]
    let selectedWords: Set<Int>
    let onSelectRow: () -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    var body: some View {
        let startTimecode = formatTimecode(frame: row.startFrame, fps: fps)
        let durationLabel = TranscriptBrowserMetrics.durationLabel(
            durationFrames: row.durationFrames,
            fps: fps
        )
        let rowWords = Array(words.enumerated().filter { $0.element.rowId == row.id })

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
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelectRow)

            TranscriptWordWrap(spacing: AppTheme.Spacing.zero) {
                ForEach(rowWords, id: \.offset) { index, word in
                    Text(verbatim: word.text + (index == rowWords.last?.offset ? "" : " "))
                        .foregroundStyle(
                            word.startFrame <= playheadFrame && playheadFrame < word.endFrame
                                ? AppTheme.Accent.timecodeColor
                                : AppTheme.Text.primaryColor
                        )
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs, style: .continuous)
                                .fill(
                                    selectedWords.contains(index)
                                        ? AppTheme.Interaction.fill(AppTheme.Opacity.muted)
                                        : Color.clear
                                )
                        )
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: TranscriptWordFramesKey.self,
                                    value: [index: geometry.frame(in: .named("transcript"))]
                                )
                            }
                        )
                }
            }
            .font(.system(size: AppTheme.FontSize.smMd))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("transcript"))
                    .onChanged(onDragChanged)
                    .onEnded(onDragEnded)
            )
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: AppTheme.Radius.xs)
        .padding(.horizontal, AppTheme.Spacing.xxs)
        .accessibilityLabel(Text(verbatim: row.text))
        .accessibilityValue(Text(verbatim: accessibilityValue(
            startTimecode: startTimecode,
            durationLabel: durationLabel
        )))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L10n.string("Select"), onSelectRow)
    }

    private func accessibilityValue(startTimecode: String, durationLabel: String?) -> String {
        if let durationLabel {
            return "\(startTimecode), \(durationLabel)"
        }
        return startTimecode
    }
}

private struct TranscriptWordWrap: SwiftUI.Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) -> CGSize {
        arrangement(width: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: LayoutSubviews,
        cache: inout ()
    ) {
        for (subview, frame) in zip(subviews, arrangement(width: bounds.width, subviews: subviews).frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrangement(width: CGFloat, subviews: LayoutSubviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize.unspecified)
            let nextX = cursor.x == 0 ? 0 : cursor.x + spacing
            if nextX + size.width > width, cursor.x > 0 {
                cursor.x = 0
                cursor.y += rowHeight + spacing
                rowHeight = 0
            } else {
                cursor.x = nextX
            }
            frames.append(CGRect(origin: cursor, size: size))
            cursor.x += size.width
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, cursor.x)
        }

        return (CGSize(width: contentWidth, height: cursor.y + rowHeight), frames)
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
                .map { clip in
                    EditorViewModel.TimelineTranscriptRow(
                        id: clip.id,
                        clipId: clip.id,
                        text: clip.textContent ?? "",
                        startFrame: clip.startFrame,
                        endFrame: clip.endFrame,
                        words: clip.wordTimings?.compactMap { $0.shifted(by: clip.startFrame) } ?? []
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

    static func words(from rows: [EditorViewModel.TimelineTranscriptRow]) -> [TranscriptWord] {
        rows.flatMap { row in
            let timings = row.words.isEmpty
                ? [WordTiming(text: row.text, startFrame: row.startFrame, endFrame: row.endFrame)]
                : row.words
            return timings.map {
                TranscriptWord(
                    rowId: row.id,
                    text: $0.text,
                    startFrame: $0.startFrame,
                    endFrame: $0.endFrame
                )
            }
        }
    }

    static func timelineRange(
        from words: [TranscriptWord],
        startIndex: Int,
        endIndex: Int
    ) -> TimelineRangeSelection? {
        guard words.indices.contains(startIndex), words.indices.contains(endIndex) else {
            return nil
        }
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        let start = words[lower...upper].map(\.startFrame).min() ?? words[lower].startFrame
        let end = words[lower...upper].map(\.endFrame).max() ?? words[upper].endFrame
        let range = TimelineRangeSelection(startFrame: start, endFrame: max(start + 1, end))
        return range.isValid ? range : nil
    }

    static func wordIndex(at point: CGPoint, frames: [Int: CGRect]) -> Int? {
        if let exact = frames.first(where: { $0.value.contains(point) }) {
            return exact.key
        }
        let rowHits = frames.filter { $0.value.minY <= point.y && point.y < $0.value.maxY }
        let candidates = rowHits.isEmpty ? frames : rowHits
        return candidates.min { lhs, rhs in
            distance(point, lhs.value) < distance(point, rhs.value)
        }?.key
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

struct TranscriptWord: Equatable {
    let rowId: String
    let text: String
    let startFrame: Int
    let endFrame: Int
}

enum TranscriptWordFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
