import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AgentInputBox<LeadingTools: View>: View {
    @Environment(EditorViewModel.self) var editor
    @Binding var draft: String
    @Binding var mentions: [AgentMention]
    let isSending: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onCancel: () -> Void
    let leadingTools: LeadingTools

    init(
        draft: Binding<String>,
        mentions: Binding<[AgentMention]>,
        isSending: Bool,
        canSend: Bool,
        onSend: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder leadingTools: () -> LeadingTools
    ) {
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
    @Namespace private var sendStopNamespace

    private var showMentionPicker: Bool { mentionQuery != nil }

    private var mentionCandidates: [MediaAsset] {
        let q = (mentionQuery ?? "").lowercased()
        let typed = mentionTab.clipType.map { t in editor.mediaAssets.filter { $0.type == t } }
            ?? editor.mediaAssets
        let matched = q.isEmpty ? typed : typed.filter { $0.mentionDisplayName.lowercased().contains(q) }
        return Array(matched.prefix(50))
    }

    var body: some View {
        VStack(spacing: 0) {
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
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor.opacity(0.6)
                        : focused ? Color.accentColor.opacity(0.45)
                        : Color.white.opacity(0.06),
                    lineWidth: (focused || isDropTargeted) ? 1 : 0.5
                )
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var textField: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .focused($focused)
                .frame(minHeight: 32, maxHeight: 64)
                .onChange(of: draft) { _, new in updateMentionQuery(from: new) }
                .onPasteCommand(of: [.fileURL, .image, .png, .jpeg, .tiff], perform: handlePaste)
                .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
                // NSTextView eats Tab before the general onKeyPress fires.
                .onKeyPress(.tab, phases: .down) { press in
                    guard showMentionPicker else { return .ignored }
                    cycleMentionTab(reverse: press.modifiers.contains(.shift))
                    return .handled
                }

            if draft.isEmpty {
                Text("Ask, or @ to reference media")
                    .font(.body)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
            HStack(spacing: 10) {
                leadingTools
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: 4) {
                    sendStopButton
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var sendStopButton: some View {
        if isSending {
            Button(action: onCancel) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(AppTheme.Text.secondaryColor)
            .glassEffectID("sendStop", in: sendStopNamespace)
            .help("Stop")
            .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .tint(.accentColor)
            .glassEffectID("sendStop", in: sendStopNamespace)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.5)
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
        let displayName = Self.disambiguatedName(for: asset, existing: mentions)
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

    private static func disambiguatedName(for asset: MediaAsset, existing: [AgentMention]) -> String {
        let base = asset.mentionDisplayName
        if !existing.contains(where: { $0.displayName == base && $0.mediaRef != asset.id }) {
            return base
        }
        let short = String(asset.id.prefix(6))
        return "\(base)#\(short)"
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if let asset = editor.addMediaAsset(from: url) {
                        insertChipForImport(asset)
                    }
                }
            }
        }
        return handled
    }

    private func handlePaste(_: [NSItemProvider]) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            urls.compactMap { editor.addMediaAsset(from: $0) }.forEach(insertChipForImport)
            return
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            if let data = pb.data(forType: type),
               let asset = editor.importPastedImageData(data, fileExtension: ext) {
                insertChipForImport(asset)
                return
            }
        }
        // onPasteCommand swallows the default paste, so echo text manually.
        if let text = pb.string(forType: .string) { draft += text }
    }

    private func insertChipForImport(_ asset: MediaAsset) {
        let displayName = Self.disambiguatedName(for: asset, existing: mentions)
        let needsSpace = !draft.isEmpty && !draft.hasSuffix(" ") && !draft.hasSuffix("\n")
        draft += (needsSpace ? " " : "") + "@\(displayName) "
        mentions.append(AgentMention(displayName: displayName, mediaRef: asset.id, type: asset.type))
    }
}
