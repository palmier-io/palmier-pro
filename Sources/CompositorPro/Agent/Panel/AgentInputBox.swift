import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentInputBox<LeadingTools: View>: View {
    @Environment(EditorViewModel.self) var editor
    let conversationID: UUID
    @Binding var draft: String
    @Binding var mentions: [AgentMention]
    let isSending: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let leadingTools: LeadingTools

    init(
        conversationID: UUID,
        draft: Binding<String>,
        mentions: Binding<[AgentMention]>,
        isSending: Bool,
        canSend: Bool,
        onSend: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder leadingTools: () -> LeadingTools
    ) {
        self.conversationID = conversationID
        self._draft = draft
        self._mentions = mentions
        self.isSending = isSending
        self.canSend = canSend
        self.onSend = onSend
        self.onCancel = onCancel
        self.leadingTools = leadingTools()
    }

    @FocusState private var focused: Bool
    @State private var mentionQuery: String? = nil
    @State private var highlightedMentionIndex: Int = 0
    @State private var mentionTab: MentionTab = .all
    @State private var mentionScrollTick: Int = 0
    @State private var isDropTargeted = false
    @State private var textEditorID = UUID()

    private var showMentionPicker: Bool { mentionQuery != nil }

    private var mentionCandidates: [MediaAsset] {
        let q = (mentionQuery ?? "").lowercased()
        let typed = mentionTab.clipType.map { t in editor.mediaAssets.filter { $0.type == t } }
            ?? editor.mediaAssets
        let matched = q.isEmpty ? typed : typed.filter { $0.mentionDisplayName.lowercased().contains(q) }
        return Array(matched.prefix(50))
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            let referencedMentions = AgentMentionContext.referencedMentions(mentions, in: draft)
            if !referencedMentions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        ForEach(referencedMentions) { mention in
                            Label {
                                Text(verbatim: mention.displayName)
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: mention.referencesTimelineContext ? "timeline.selection" : "paperclip")
                            }
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .padding(.horizontal, AppTheme.Spacing.smMd)
                            .padding(.vertical, AppTheme.Spacing.xs)
                            .background(AppTheme.Interaction.fill(AppTheme.Opacity.faint), in: RoundedRectangle(cornerRadius: AppTheme.Radius.xsSm))
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.top, AppTheme.Spacing.smMd)
            }
            textField
                .popover(isPresented: Binding(
                    get: { showMentionPicker },
                    set: { if !$0 { mentionQuery = nil } }
                ), attachmentAnchor: .point(.topLeading), arrowEdge: .top) {
                    MentionPopover(
                        query: mentionQuery ?? "",
                        candidates: mentionCandidates,
                        highlightedIndex: $highlightedMentionIndex,
                        tab: $mentionTab,
                        scrollTick: mentionScrollTick,
                        onPick: { asset in pickMention(asset) }
                    )
                }
                .onChange(of: mentionTab) { _, _ in highlightedMentionIndex = 0 }
            bottomBar
        }
        .background(AppTheme.Background.prominentColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong)
                        : focused ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium)
                        : AppTheme.Border.primaryColor,
                    lineWidth: (focused || isDropTargeted) ? AppTheme.BorderWidth.thin : AppTheme.BorderWidth.hairline
                )
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: focused)
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isDropTargeted)
        .onAppear { focused = true }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var textField: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .id(textEditorID)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.automatic)
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.top, AppTheme.Spacing.smMd)
                .padding(.bottom, AppTheme.Spacing.xs)
                .focused($focused)
                .frame(height: AppTheme.Chat.composerMinHeight)
                .onChange(of: draft) { old, new in
                    updateMentionQuery(from: new)
                    if !old.isEmpty && new.isEmpty {
                        let wasFocused = focused
                        textEditorID = UUID()
                        if wasFocused {
                            Task { @MainActor in focused = true }
                        }
                    }
                }
                .onPasteCommand(of: [.fileURL, .image, .png, .jpeg, .tiff], perform: handlePaste)
                .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
                // NSTextView eats Tab before the general onKeyPress fires.
                .onKeyPress(.tab, phases: .down) { press in
                    guard showMentionPicker else { return .ignored }
                    cycleMentionTab(reverse: press.modifiers.contains(.shift))
                    return .handled
                }

            if draft.isEmpty {
                Text(L10n.string("Ask, or type @ to reference media"))
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.top, AppTheme.Spacing.mdLg)
                    .allowsHitTesting(false)
            }
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: AppTheme.Spacing.smMd) {
            leadingTools
                .layoutPriority(1)
            Spacer(minLength: AppTheme.Spacing.zero)
            sendStopButton
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.bottom, AppTheme.Spacing.smMd)
        .padding(.top, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private var sendStopButton: some View {
        if isSending {
            Button(action: onCancel) {
                Image(systemName: "stop.fill")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.bold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                    .background(AppTheme.Interaction.fill(AppTheme.Opacity.faint), in: Circle())
                    .overlay(Circle().stroke(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel(L10n.string("Stop this chat"))
            .help(L10n.string("Stop"))
            .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.bold))
                    .foregroundStyle(canSend ? AppTheme.Background.baseColor : AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                    .background(canSend ? AppTheme.Accent.primary : AppTheme.Interaction.fill(AppTheme.Opacity.faint), in: Circle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!canSend)
            .accessibilityLabel(L10n.string("Send message"))
            .help(L10n.string("Send message"))
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func cycleMentionTab(reverse: Bool) {
        let tabs = MentionTab.allCases
        let step = reverse ? -1 : 1
        let current = tabs.firstIndex(of: mentionTab) ?? 0
        mentionTab = tabs[(current + step + tabs.count) % tabs.count]
        mentionScrollTick &+= 1
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if showMentionPicker {
            let isArrow = press.key == .upArrow || press.key == .downArrow
            if press.phase == .repeat && !isArrow { return .handled }
            let candidates = mentionCandidates
            switch press.key {
            case .upArrow:
                moveMentionHighlight(by: -1, within: candidates)
                return .handled
            case .downArrow:
                moveMentionHighlight(by: 1, within: candidates)
                return .handled
            case .return:
                if candidates.indices.contains(highlightedMentionIndex) {
                    pickMention(candidates[highlightedMentionIndex])
                }
                return .handled
            case .escape:
                mentionQuery = nil
                return .handled
            default:
                return .ignored
            }
        }

        guard press.phase == .down else { return .ignored }
        if press.key == .escape, isSending {
            onCancel()
            return .handled
        }
        if press.key == .return, !press.modifiers.contains(.shift), canSend {
            onSend()
            return .handled
        }
        return .ignored
    }

    private func moveMentionHighlight(by delta: Int, within candidates: [MediaAsset]) {
        guard !candidates.isEmpty else { return }
        let next = min(candidates.count - 1, max(0, highlightedMentionIndex + delta))
        guard next != highlightedMentionIndex else { return }
        highlightedMentionIndex = next
        mentionScrollTick &+= 1
    }

    private func updateMentionQuery(from text: String) {
        let newQuery: String? = {
            guard let lastAt = text.lastIndex(of: "@") else { return nil }
            let after = text[text.index(after: lastAt)...]
            if after.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
            if lastAt > text.startIndex {
                let prev = text[text.index(before: lastAt)]
                if !prev.isWhitespace && !prev.isNewline { return nil }
            }
            return String(after)
        }()

        guard newQuery != mentionQuery else { return }
        mentionQuery = newQuery
        highlightedMentionIndex = 0
    }

    private func pickMention(_ asset: MediaAsset) {
        let displayName = AgentService.disambiguatedMentionName(for: asset, existing: mentions)
        if let lastAt = draft.lastIndex(of: "@") {
            let prefix = draft[..<lastAt]
            draft = String(prefix) + "@\(displayName) "
        } else {
            draft += "@\(displayName) "
        }
        mentions.append(AgentMention(
            displayName: displayName,
            mediaRef: asset.id,
            type: asset.type
        ))
        mentionQuery = nil
        highlightedMentionIndex = 0
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                Task { @MainActor in
                    guard editor.agentService.containsSession(conversationID) else { return }
                    if let error {
                        editor.reportMediaImportFailure(error)
                        return
                    }
                    guard let url else {
                        editor.reportMediaImportFailure(CocoaError(.fileReadUnknown))
                        return
                    }
                    if let asset = editor.addMediaAsset(from: url) {
                        editor.agentService.attachMention(for: asset, conversationID: conversationID)
                    }
                }
            }
        }
        return handled
    }

    private func handlePaste(_: [NSItemProvider]) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            urls.compactMap { editor.addMediaAsset(from: $0) }
                .forEach { editor.agentService.attachMention(for: $0, conversationID: conversationID) }
            return
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            if let data = pb.data(forType: type) {
                Task { @MainActor in
                    guard editor.agentService.containsSession(conversationID) else { return }
                    guard let asset = await editor.importPastedImageData(data, fileExtension: ext) else { return }
                    editor.agentService.attachMention(for: asset, conversationID: conversationID)
                }
                return
            }
        }
        // onPasteCommand swallows the default paste, so echo text manually.
        if let text = pb.string(forType: .string) { draft += text }
    }
}
