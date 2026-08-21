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
    @State private var selectionAnchor: TranscriptBrowserSelectionAnchor?
    @State private var dragAnchorIndex: Int?
    @State private var tokenFrames: [Int: CGRect] = [:]
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = TranscriptBrowserNavigation.rows(
            document.rows,
            matching: query
        )
        let tokens = TranscriptBrowserNavigation.tokens(from: rows)
        let selectedIndices = Set(
            TranscriptBrowserNavigation.intersectingIndices(
                tokens: tokens,
                range: editor.validSelectedTimelineRange
            )
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
                                    playheadState: editor.playheadState,
                                    tokens: tokens,
                                    selectedTokenIndices: selectedIndices,
                                    onSelectRow: { extending in
                                        selectRow(row.id, tokens: tokens, extending: extending)
                                    },
                                    onSelectToken: { index, extending in
                                        selectToken(index, tokens: tokens, extending: extending)
                                    },
                                    onAddMarker: {
                                        addMarker(tokens: tokens, rowId: row.id)
                                    }
                                )
                                .id(row.id)
                            }
                        }
                        .coordinateSpace(name: "transcript")
                        .onPreferenceChange(TranscriptTokenFramesKey.self) { tokenFrames = $0 }
                        .simultaneousGesture(selectionDrag(tokens: tokens))
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
        .onChange(of: editor.selectedTimelineRange) { _, range in
            if range == nil { selectionAnchor = nil }
        }
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

    private func selectionDrag(tokens: [TranscriptBrowserToken]) -> some Gesture {
        DragGesture(minimumDistance: AppTheme.Spacing.xs, coordinateSpace: .named("transcript"))
            .onChanged { value in
                updateDragSelection(at: value, tokens: tokens, seek: false)
            }
            .onEnded { value in
                updateDragSelection(at: value, tokens: tokens, seek: true)
                dragAnchorIndex = nil
            }
    }

    private func updateDragSelection(
        at value: DragGesture.Value,
        tokens: [TranscriptBrowserToken],
        seek: Bool
    ) {
        let startHit = TranscriptBrowserNavigation.tokenIndex(
            at: value.startLocation,
            frames: tokenFrames
        )
        let hit = TranscriptBrowserNavigation.tokenIndex(
            at: value.location,
            frames: tokenFrames
        ) ?? startHit
        guard let startHit, let hit else { return }
        if dragAnchorIndex == nil {
            if NSEvent.modifierFlags.contains(.shift), selectionAnchor != nil {
                dragAnchorIndex = originIndex(toward: startHit, tokens: tokens) ?? startHit
            } else {
                dragAnchorIndex = startHit
                selectionAnchor = .token(tokens[startHit].id)
            }
        }
        applySelection(from: dragAnchorIndex ?? startHit, to: hit, tokens: tokens, seek: seek)
    }

    private func selectRow(
        _ rowId: String,
        tokens: [TranscriptBrowserToken],
        extending: Bool
    ) {
        let span: (start: Int, end: Int)?
        if extending, let selectionAnchor {
            span = TranscriptBrowserNavigation.span(
                fromAnchor: selectionAnchor,
                toRowId: rowId,
                tokens: tokens
            )
        } else {
            selectionAnchor = .row(rowId)
            span = TranscriptBrowserNavigation.span(
                fromAnchor: .row(rowId),
                toRowId: rowId,
                tokens: tokens
            )
        }
        guard let span else { return }
        applySelection(from: span.start, to: span.end, tokens: tokens, seek: true)
    }

    private func selectToken(
        _ index: Int,
        tokens: [TranscriptBrowserToken],
        extending: Bool
    ) {
        guard tokens.indices.contains(index) else { return }
        if extending, let origin = originIndex(toward: index, tokens: tokens) {
            applySelection(from: origin, to: index, tokens: tokens, seek: true)
        } else {
            selectionAnchor = .token(tokens[index].id)
            applySelection(from: index, to: index, tokens: tokens, seek: true)
        }
    }

    private func addMarker(tokens: [TranscriptBrowserToken], rowId: String) {
        if editor.validSelectedTimelineRange == nil {
            selectRow(rowId, tokens: tokens, extending: false)
        }
        let intersecting = TranscriptBrowserNavigation.intersectingIndices(
            tokens: tokens,
            range: editor.validSelectedTimelineRange
        )
        let comment: String
        if let first = intersecting.first, let last = intersecting.last {
            comment = TranscriptBrowserNavigation.selectedText(
                from: tokens,
                startIndex: first,
                endIndex: last
            )
        } else {
            comment = ""
        }
        _ = editor.addTimelineMarkerAtSelection(comment: comment)
    }

    private func applySelection(
        from start: Int,
        to end: Int,
        tokens: [TranscriptBrowserToken],
        seek: Bool
    ) {
        guard let range = TranscriptBrowserNavigation.timelineRange(
            from: tokens,
            startIndex: start,
            endIndex: end
        ) else { return }
        editor.selectPreviewTab(id: PreviewTab.timeline.id)
        editor.selectedClipIds.removeAll()
        editor.selectedGap = nil
        editor.setTimelineRange(startFrame: range.startFrame, endFrame: range.endFrame)
        if seek { editor.seekToFrame(range.startFrame) }
    }

    private func originIndex(
        toward index: Int,
        tokens: [TranscriptBrowserToken]
    ) -> Int? {
        guard let selectionAnchor else { return nil }
        switch selectionAnchor {
        case .token(let id):
            return TranscriptBrowserNavigation.index(of: id, in: tokens)
        case .row(let rowId):
            guard let row = TranscriptBrowserNavigation.tokenIndices(
                inRow: rowId,
                tokens: tokens
            ) else { return nil }
            let last = row.upperBound - 1
            return abs(index - row.lowerBound) >= abs(index - last)
                ? row.lowerBound
                : last
        }
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
    let playheadState: PreviewPlayheadState
    let tokens: [TranscriptBrowserToken]
    let selectedTokenIndices: Set<Int>
    let onSelectRow: (Bool) -> Void
    let onSelectToken: (Int, Bool) -> Void
    let onAddMarker: () -> Void

    var body: some View {
        let startTimecode = formatTimecode(frame: row.startFrame, fps: fps)
        let durationLabel = TranscriptBrowserMetrics.durationLabel(
            durationFrames: row.durationFrames,
            fps: fps
        )
        let rowTokenRange = TranscriptBrowserNavigation.tokenIndices(
            inRow: row.id,
            tokens: tokens
        )
        let isRowSelected = rowTokenRange?.contains {
            selectedTokenIndices.contains($0)
        } ?? false
        let playheadFrame = playheadState.timelineFrame
        let isPlayheadRow = row.startFrame <= playheadFrame && playheadFrame < row.endFrame

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
            .onTapGesture {
                onSelectRow(NSEvent.modifierFlags.contains(.shift))
            }

            TranscriptBrowserSelectableText(
                row: row,
                tokens: tokens,
                selectedTokenIndices: selectedTokenIndices,
                playheadFrame: playheadFrame,
                isPlayheadRow: isPlayheadRow,
                onSelectToken: onSelectToken
            )
            .font(.system(size: AppTheme.FontSize.smMd))
            .lineSpacing(AppTheme.Spacing.zero)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L10n.string("Add Marker")) { onAddMarker() }
        }
        .hoverHighlight(
            cornerRadius: AppTheme.Radius.xs,
            isActive: isRowSelected
        )
        .padding(.horizontal, AppTheme.Spacing.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.text))
        .accessibilityValue(Text(verbatim: accessibilityValue(
            startTimecode: startTimecode,
            durationLabel: durationLabel
        )))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onSelectRow(false)
        }
        .accessibilityAction(named: L10n.string("Add Marker"), onAddMarker)
    }

    private func accessibilityValue(startTimecode: String, durationLabel: String?) -> String {
        if let durationLabel {
            return "\(startTimecode), \(durationLabel)"
        }
        return startTimecode
    }
}

private struct TranscriptBrowserSelectableText: View {
    let row: EditorViewModel.TimelineTranscriptRow
    let tokens: [TranscriptBrowserToken]
    let selectedTokenIndices: Set<Int>
    let playheadFrame: Int
    let isPlayheadRow: Bool
    let onSelectToken: (Int, Bool) -> Void

    var body: some View {
        let rowTokens = TranscriptBrowserNavigation.tokenIndices(
            inRow: row.id,
            tokens: tokens
        )
        if let rowTokens, !row.words.isEmpty {
            TranscriptWordWrap(spacing: AppTheme.Spacing.zero) {
                ForEach(Array(rowTokens.enumerated()), id: \.offset) { offset, tokenIndex in
                    let token = tokens[tokenIndex]
                    let isLast = offset == rowTokens.count - 1
                    TranscriptBrowserWord(
                        text: token.text,
                        trailingSpace: !isLast,
                        isSelected: selectedTokenIndices.contains(tokenIndex),
                        isCurrent: token.startFrame <= playheadFrame
                            && playheadFrame < token.endFrame,
                        tokenIndex: tokenIndex,
                        onSelect: {
                            onSelectToken(tokenIndex, NSEvent.modifierFlags.contains(.shift))
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let tokenIndex = rowTokens?.startIndex
            TranscriptBrowserCurrentText(
                content: row.text,
                isCurrent: isPlayheadRow,
                isSelected: tokenIndex.map { selectedTokenIndices.contains($0) } ?? false
            )
            .equatable()
            .background(tokenFrameReporter(tokenIndex))
            .onTapGesture {
                if let tokenIndex {
                    onSelectToken(tokenIndex, NSEvent.modifierFlags.contains(.shift))
                }
            }
        }
    }

    @ViewBuilder
    private func tokenFrameReporter(_ tokenIndex: Int?) -> some View {
        if let tokenIndex {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TranscriptTokenFramesKey.self,
                    value: [tokenIndex: geometry.frame(in: .named("transcript"))]
                )
            }
        }
    }
}

private struct TranscriptBrowserWord: View {
    let text: String
    let trailingSpace: Bool
    let isSelected: Bool
    let isCurrent: Bool
    let tokenIndex: Int
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            Text(verbatim: text)
                .foregroundStyle(
                    isCurrent
                        ? AppTheme.Accent.timecodeColor
                        : AppTheme.Text.primaryColor
                )
                .padding(.horizontal, AppTheme.Spacing.xxs)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs, style: .continuous)
                        .fill(
                            isSelected
                                ? AppTheme.Interaction.fill(AppTheme.Opacity.muted)
                                : Color.clear
                        )
                )
            if trailingSpace {
                Text(verbatim: " ")
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
        }
        .onTapGesture(perform: onSelect)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TranscriptTokenFramesKey.self,
                    value: [tokenIndex: geometry.frame(in: .named("transcript"))]
                )
            }
        )
    }
}

private struct TranscriptBrowserCurrentText: View, Equatable {
    let content: String
    let isCurrent: Bool
    var isSelected: Bool = false

    var body: some View {
        Text(verbatim: content)
            .foregroundStyle(
                isCurrent
                    ? AppTheme.Accent.timecodeColor
                    : AppTheme.Text.primaryColor
            )
            .padding(.horizontal, AppTheme.Spacing.xxs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs, style: .continuous)
                    .fill(
                        isSelected
                            ? AppTheme.Interaction.fill(AppTheme.Opacity.muted)
                            : Color.clear
                    )
            )
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
                .map {
                    EditorViewModel.TimelineTranscriptRow(
                        id: $0.id,
                        clipId: $0.id,
                        text: $0.textContent ?? "",
                        startFrame: $0.startFrame,
                        endFrame: $0.endFrame,
                        words: EditorViewModel.TimelineTranscriptWord.mapped(
                            from: $0.wordTimings,
                            timelineStartFrame: $0.startFrame
                        )
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
