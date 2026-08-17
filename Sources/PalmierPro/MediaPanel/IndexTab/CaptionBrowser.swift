import SwiftUI

struct CaptionBrowserItem: Identifiable {
    let number: Int
    let clip: Clip
    var id: String { clip.id }
}

struct CaptionBrowserGroup: Identifiable {
    let id: String
    let trackIndex: Int
    let isVisible: Bool
    let captions: [Clip]
}

struct CaptionBrowser: View {
    @Environment(EditorViewModel.self) private var editor
    let groups: [CaptionBrowserGroup]
    let fps: Int
    @Binding var selectedGroupId: String?
    @Binding var indexSection: IndexBrowserSection

    @State private var searchQuery = ""
    @State private var jumpTargetId: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let captions = activeGroup?.captions ?? []
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = CaptionBrowserNavigation.numberedCaptions(captions, matching: query)
        let timelineIndex = CaptionBrowserTimelineIndex(sortedCaptions: captions)

        return ScrollViewReader { proxy in
            VStack(spacing: AppTheme.Spacing.zero) {
                controls(timelineIndex: timelineIndex) { captionId in
                    searchQuery = ""
                    jumpTargetId = captionId
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
                                CaptionBrowserRow(
                                    item: row,
                                    fps: fps,
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
        .onChange(of: groups.map(\.id), initial: true) { _, _ in
            if !groups.contains(where: { $0.id == selectedGroupId }) {
                selectedGroupId = defaultGroup?.id
            }
        }
        .onChange(of: selectedClipGroupId, initial: true) { _, groupId in
            if let groupId { selectedGroupId = groupId }
        }
    }

    private var activeGroup: CaptionBrowserGroup? {
        groups.first { $0.id == selectedGroupId } ?? defaultGroup
    }

    private var defaultGroup: CaptionBrowserGroup? {
        groups.first(where: \.isVisible) ?? groups.first
    }

    private var selectedClipGroupId: String? {
        let selectedIds = editor.selectedClipIds
        return groups.first {
            $0.captions.contains { selectedIds.contains($0.id) }
        }?.id
    }

    private func controls(
        timelineIndex: CaptionBrowserTimelineIndex,
        onJump: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if editor.isMediaPanelSearchExpanded {
                ExpandablePanelSearch(text: $searchQuery, focus: $isSearchFocused)
                    .layoutPriority(1)
            } else {
                IndexModeTabs(selection: $indexSection)
                Spacer(minLength: AppTheme.Spacing.zero)
                if groups.count > 1, let activeGroup {
                    groupPicker(activeGroup: activeGroup)
                }
                ExpandablePanelSearch(text: $searchQuery, focus: $isSearchFocused)
                CaptionJumpToPlayheadButton(
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

    private func groupPicker(activeGroup: CaptionBrowserGroup) -> some View {
        Menu {
            ForEach(groups) { group in
                Button {
                    selectedGroupId = group.id
                } label: {
                    Label(
                        groupLabel(group),
                        systemImage: group.id == activeGroup.id ? "checkmark" : ""
                    )
                }
            }
        } label: {
            EditorMenuValue(text: groupLabel(activeGroup), expanded: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: AppTheme.MediaPanel.captionIndexGroupMenuWidth)
        .layoutPriority(1)
        .focusable(false)
    }

    private func groupLabel(_ group: CaptionBrowserGroup) -> String {
        guard editor.timeline.tracks.indices.contains(group.trackIndex) else { return "" }
        let title = CaptionBrowserNavigation.groupLabel(
            code: editor.timelineTrackDisplayLabel(at: group.trackIndex),
            name: editor.timeline.tracks[group.trackIndex].name
        )
        return title
    }
}

private struct CaptionJumpToPlayheadButton: View {
    let timelineIndex: CaptionBrowserTimelineIndex
    let playheadState: PreviewPlayheadState
    let onJump: (String) -> Void

    var body: some View {
        let currentCaption = timelineIndex.currentCaption(at: playheadState.timelineFrame)

        Button {
            if let currentCaption { onJump(currentCaption.id) }
        } label: {
            Image(systemName: "timeline.selection")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(
                    currentCaption == nil
                        ? AppTheme.Text.mutedColor
                        : AppTheme.Text.secondaryColor
                )
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(currentCaption == nil)
        .hoverTooltip(
            L10n.string("Jump to Playhead"),
            alignment: .bottomTrailing
        )
    }
}

private struct CaptionBrowserRow: View {
    @Environment(EditorViewModel.self) private var editor
    let item: CaptionBrowserItem
    let fps: Int
    let playheadState: PreviewPlayheadState

    var body: some View {
        let clip = item.clip
        let content = clip.textContent ?? ""
        let startTimecode = formatTimecode(frame: clip.startFrame, fps: fps)
        let durationLabel = CaptionBrowserMetrics.durationLabel(
            durationFrames: clip.durationFrames,
            fps: fps
        )

        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text(verbatim: "\(item.number)")
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .monospacedDigit()
                        .frame(
                            width: AppTheme.MediaPanel.captionIndexNumberWidth,
                            alignment: .leading
                        )
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

                CaptionBrowserPlayheadText(
                    content: content,
                    clipStartFrame: clip.startFrame,
                    clipEndFrame: clip.endFrame,
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
            isActive: editor.selectedClipIds.contains(clip.id)
        )
        .padding(.horizontal, AppTheme.Spacing.xxs)
        .accessibilityLabel(Text(verbatim: content))
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
        editor.selectedClipIds = [item.id]
        editor.seekToFrame(item.clip.startFrame)
    }
}

private struct CaptionBrowserPlayheadText: View {
    let content: String
    let clipStartFrame: Int
    let clipEndFrame: Int
    let playheadState: PreviewPlayheadState

    var body: some View {
        let frame = playheadState.timelineFrame
        CaptionBrowserCurrentText(
            content: content,
            isCurrent: clipStartFrame <= frame && frame < clipEndFrame
        )
        .equatable()
    }
}

private struct CaptionBrowserCurrentText: View, Equatable {
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

enum CaptionBrowserMetrics {
    static func durationLabel(durationFrames: Int, fps: Int) -> String? {
        guard durationFrames > 0, fps > 0 else { return nil }
        let seconds = Double(durationFrames) / Double(fps)
        guard seconds.isFinite else { return nil }
        return String(format: "%.1fs", seconds)
    }
}

struct CaptionBrowserTimelineIndex {
    private let captions: [Clip]
    private let longestEndingCaptionByPrefix: [Int]

    init(sortedCaptions captions: [Clip]) {
        self.captions = captions
        var longestEndingCaptionByPrefix: [Int] = []
        if !captions.isEmpty {
            var longestEndingIndex = 0
            for index in captions.indices {
                if captions[index].endFrame >= captions[longestEndingIndex].endFrame {
                    longestEndingIndex = index
                }
                longestEndingCaptionByPrefix.append(longestEndingIndex)
            }
        }
        self.longestEndingCaptionByPrefix = longestEndingCaptionByPrefix
    }

    func currentCaption(at frame: Int) -> Clip? {
        var lowerBound = 0
        var upperBound = captions.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if captions[midpoint].startFrame <= frame {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        guard lowerBound > 0 else { return nil }
        let latestIndex = lowerBound - 1
        let latest = captions[latestIndex]
        if frame < latest.endFrame { return latest }

        guard latestIndex > 0 else { return nil }
        let fallback = captions[longestEndingCaptionByPrefix[latestIndex - 1]]
        return frame < fallback.endFrame ? fallback : nil
    }
}

enum CaptionBrowserNavigation {
    static func groups(in timeline: Timeline) -> [CaptionBrowserGroup] {
        var captionsByGroup: [String: [Clip]] = [:]
        var trackIndexByGroup: [String: Int] = [:]
        var visibilityByGroup: [String: Bool] = [:]

        for (trackIndex, track) in timeline.tracks.enumerated() {
            for caption in track.clips where isCaption(caption) {
                guard let groupId = caption.captionGroupId else { continue }
                captionsByGroup[groupId, default: []].append(caption)
                trackIndexByGroup[groupId] = trackIndexByGroup[groupId] ?? trackIndex
                visibilityByGroup[groupId, default: false] =
                    visibilityByGroup[groupId, default: false] || !track.hidden
            }
        }

        return captionsByGroup.compactMap { groupId, captions in
            guard let trackIndex = trackIndexByGroup[groupId] else { return nil }
            return CaptionBrowserGroup(
                id: groupId,
                trackIndex: trackIndex,
                isVisible: visibilityByGroup[groupId] ?? false,
                captions: captions.sorted(by: captionComesBefore)
            )
        }
        .sorted {
            if $0.trackIndex != $1.trackIndex {
                return $0.trackIndex < $1.trackIndex
            }
            return $0.id < $1.id
        }
    }

    static func groupLabel(code: String, name: String?) -> String {
        guard let name, !name.isEmpty else { return code }
        return "\(code) (\(name))"
    }

    static func numberedCaptions(
        _ captions: [Clip],
        matching query: String
    ) -> [CaptionBrowserItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return captions.enumerated().compactMap { index, caption in
            let matches = query.isEmpty
                || (caption.textContent ?? "").localizedCaseInsensitiveContains(query)
            guard matches else { return nil }
            return CaptionBrowserItem(number: index + 1, clip: caption)
        }
    }

    private static func isCaption(_ clip: Clip) -> Bool {
        clip.mediaType == .text && clip.captionGroupId != nil
    }

    private static func captionComesBefore(_ lhs: Clip, _ rhs: Clip) -> Bool {
        if lhs.startFrame != rhs.startFrame {
            return lhs.startFrame < rhs.startFrame
        }
        return lhs.id < rhs.id
    }
}
