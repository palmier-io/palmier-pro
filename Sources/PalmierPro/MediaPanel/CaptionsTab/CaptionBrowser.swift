import SwiftUI

private struct CaptionBrowserTimedWord {
    let range: NSRange
    let timing: WordTiming
}

struct CaptionBrowserItem: Identifiable {
    let number: Int
    let clip: Clip
    var id: String { clip.id }
}

struct CaptionBrowser: View {
    @Environment(EditorViewModel.self) private var editor
    let captions: [Clip]
    let fps: Int

    @State private var searchQuery = ""
    @State private var jumpTargetId: String?

    var body: some View {
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
                                Rectangle()
                                    .fill(AppTheme.Border.subtleColor)
                                    .frame(height: AppTheme.BorderWidth.hairline)
                                    .padding(.horizontal, AppTheme.Spacing.sm)
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
        timelineIndex: CaptionBrowserTimelineIndex,
        onJump: @escaping (String) -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            PanelSearchField(text: $searchQuery)
                .layoutPriority(1)
            CaptionJumpToPlayheadButton(
                timelineIndex: timelineIndex,
                playheadState: editor.playheadState,
                onJump: onJump
            )
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.sm)
        .fixedSize(horizontal: false, vertical: true)
        .background(AppTheme.Background.surfaceColor)
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
            Image(systemName: "scope")
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
        .accessibilityLabel(L10n.string("Jump to Playhead"))
        .help(L10n.string("Show the caption at the playhead"))
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
        let timeRange = "\(formatTimecode(frame: clip.startFrame, fps: fps)) – \(formatTimecode(frame: clip.endFrame, fps: fps))"
        let charactersPerSecond = CaptionBrowserMetrics.charactersPerSecond(
            content: content,
            durationFrames: clip.durationFrames,
            fps: fps
        )
        let timedWords = Self.timedWords(for: clip, content: content)

        Button(action: select) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(verbatim: "#\(item.number)")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Text(verbatim: timeRange)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Spacer(minLength: AppTheme.Spacing.xs)
                    if let charactersPerSecond {
                        Text(verbatim: "\(charactersPerSecond) CPS")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium).monospacedDigit())
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
                .lineLimit(1)

                CaptionBrowserPlayheadText(
                    content: content,
                    clipStartFrame: clip.startFrame,
                    clipDurationFrames: clip.durationFrames,
                    timedWords: timedWords,
                    playheadState: playheadState
                )
                .font(.system(size: AppTheme.FontSize.smMd))
                .lineSpacing(AppTheme.Spacing.zero)
                .fixedSize(horizontal: false, vertical: true)
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
            timeRange: timeRange,
            charactersPerSecond: charactersPerSecond
        )))
    }

    private func accessibilityValue(timeRange: String, charactersPerSecond: Int?) -> String {
        if let charactersPerSecond {
            return "\(timeRange), \(charactersPerSecond) CPS"
        }
        return timeRange
    }

    private static func timedWords(for clip: Clip, content: String) -> [CaptionBrowserTimedWord] {
        guard let words = clip.wordTimings, !words.isEmpty else { return [] }
        let tokens = TextFrameRenderer.wordTokens(in: content)
        let timings = TextFrameRenderer.tokenTimings(tokens, words, duration: clip.durationFrames)
        return zip(tokens, timings).map {
            CaptionBrowserTimedWord(range: $0.range, timing: $1)
        }
    }

    private func select() {
        editor.selectedGap = nil
        editor.selectedTimelineRange = nil
        editor.selectedClipIds = [item.id]
        editor.seekToFrame(item.clip.startFrame)
    }
}

private struct CaptionBrowserPlayheadText: View {
    let content: String
    let clipStartFrame: Int
    let clipDurationFrames: Int
    let timedWords: [CaptionBrowserTimedWord]
    let playheadState: PreviewPlayheadState

    var body: some View {
        highlightedText(at: playheadState.timelineFrame)
    }

    private func highlightedText(at timelineFrame: Int) -> Text {
        let relativeFrame = timelineFrame - clipStartFrame
        guard relativeFrame >= 0,
              relativeFrame < clipDurationFrames,
              let active = timedWords.first(where: {
                  relativeFrame >= $0.timing.startFrame && relativeFrame < $0.timing.endFrame
              }) else {
            return Text(verbatim: content)
                .foregroundColor(AppTheme.Text.primaryColor)
        }

        let text = content as NSString
        guard active.range.location >= 0,
              NSMaxRange(active.range) <= text.length else {
            return Text(verbatim: content)
                .foregroundColor(AppTheme.Text.primaryColor)
        }

        let prefix = text.substring(to: active.range.location)
        let word = text.substring(with: active.range)
        let suffix = text.substring(from: NSMaxRange(active.range))
        var highlighted = AttributedString(prefix)
        highlighted.foregroundColor = AppTheme.Text.primaryColor
        var activeWord = AttributedString(word)
        activeWord.foregroundColor = AppTheme.Accent.timecodeColor
        var remainder = AttributedString(suffix)
        remainder.foregroundColor = AppTheme.Text.primaryColor
        highlighted.append(activeWord)
        highlighted.append(remainder)
        return Text(highlighted)
    }
}

enum CaptionBrowserMetrics {
    static func charactersPerSecond(content: String, durationFrames: Int, fps: Int) -> Int? {
        guard durationFrames > 0, fps > 0 else { return nil }
        let characterCount = content.count(where: { !$0.isNewline })
        let rate = Double(characterCount) * Double(fps) / Double(durationFrames)
        guard rate.isFinite, rate <= Double(Int.max) else { return nil }
        return Int(rate.rounded())
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
    static func hasCaptions(in timeline: Timeline) -> Bool {
        timeline.tracks.contains { $0.clips.contains(where: isCaption) }
    }

    static func sortedCaptions(in timeline: Timeline) -> [Clip] {
        timeline.tracks
            .flatMap(\.clips)
            .filter(isCaption)
            .sorted {
                if $0.startFrame != $1.startFrame {
                    return $0.startFrame < $1.startFrame
                }
                return $0.id < $1.id
            }
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
}
