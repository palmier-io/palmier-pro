import AppKit
import SwiftUI

struct AgentPanelView: View {
    @Environment(EditorViewModel.self) var editor

    private static let starterPrompts: [AgentStarterPrompt] = [
        AgentStarterPrompt(
            id: "keep_best_takes",
            title: L10n.string("Keep the best takes"),
            systemImage: "scissors",
            prompt: "Tighten this edit. Keep the strongest takes, cut filler words and long silences, and leave a clean continuous cut."
        ),
        AgentStarterPrompt(
            id: "sync_multicam",
            title: L10n.string("Sync my multicam"),
            systemImage: "rectangle.on.rectangle.angled",
            prompt: "Set up my multicam. Group the matching camera angles with their audio, verify sync, and leave it ready to switch."
        ),
        AgentStarterPrompt(
            id: "generate_broll",
            title: L10n.string("Generate B-roll"),
            systemImage: "film",
            prompt: "Generate B-roll that fits this edit. Find moments that need cutaways, create matching shots, and place them where they support the story."
        ),
        AgentStarterPrompt(
            id: "score_timeline",
            title: L10n.string("Score my timeline"),
            systemImage: "music.note",
            prompt: "Generate music for this timeline. Match the mood and length, then place it on an audio track synced to the edit."
        ),
        AgentStarterPrompt(
            id: "cut_to_beat",
            title: L10n.string("Cut to the beat"),
            systemImage: "metronome",
            prompt: "Assemble my clips to the beat of a song. Detect the beats and cut or place clips so the edit hits the rhythm."
        ),
        AgentStarterPrompt(
            id: "add_captions",
            title: L10n.string("Add captions"),
            systemImage: "captions.bubble",
            prompt: "Add captions to this timeline. Transcribe the dialogue, phrase it for readability, and place text clips locked to the speech."
        ),
        AgentStarterPrompt(
            id: "make_vertical_shorts",
            title: L10n.string("Make vertical shorts"),
            systemImage: "rectangle.portrait",
            prompt: "Find the strongest moments in this video and turn each into a short-form vertical clip. Create multiple 9:16 timelines, reframe for vertical, and keep every clip tight and self-contained."
        ),
        AgentStarterPrompt(
            id: "generate_drone",
            title: L10n.string("Generate a drone"),
            systemImage: "waveform.path",
            prompt: "Lay a tonal drone bed under the vocal. Ask me for the tonic (Sa) and the maqam flavor if I don't state them, then generate it locally on this Mac and place it on its own track under the vocal, leveled to sit beneath it."
        ),
    ]

    private var service: AgentService { editor.agentService }

    private var canSend: Bool {
        !service.isStreaming &&
        service.canStream &&
        !service.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @State private var isScrolledFromBottom = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            messageList
            footer
        }
        .background(ChatBackground())
        .onChange(of: service.isStreaming) { _, streaming in
            guard !streaming else { return }
            AppNotifications.agentComplete()
        }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(service.openSessions) { session in
                                ChatTabView(
                                    session: session,
                                    isActive: session.id == service.currentSessionId,
                                    onSelect: { service.selectSession(session.id) },
                                    onClose: { service.closeTab(session.id) }
                                )
                                .id(session.id)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: service.currentSessionId) { _, new in
                        guard let new else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    newTabButton
                    historyButton
                    ViewSkillsButton()
                    modelPicker
                    reasoningEffortPicker
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(height: 44)
            .background(
                Rectangle()
                    .fill(AppTheme.Background.surfaceColor)
                    .overlay(alignment: .bottom) {
                        Divider().foregroundStyle(AppTheme.Border.subtleColor)
                    }
            )
        }
    }

    private var newTabButton: some View {
        Button { service.newChat() } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("New chat"))
    }

    @State private var showHistory = false

    private var historyButton: some View {
        Button { showHistory.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("Chat history"))
        .popover(isPresented: $showHistory, arrowEdge: .top) {
            ChatHistoryList(
                sessions: service.sessions.sorted { $0.updatedAt > $1.updatedAt },
                currentId: service.currentSessionId,
                onSelect: { id in
                    service.selectSession(id)
                    showHistory = false
                },
                onDelete: { service.deleteSession($0) }
            )
            .frame(minWidth: 280, minHeight: 300)
        }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(service.builtInModels, id: \.self) { model in
                Button {
                    service.model = model
                } label: {
                    Text(verbatim: service.modelTitle(model))
                }
                .disabled(!service.canSelectModel(model))
            }
            if !service.customModels.isEmpty {
                Divider()
                ForEach(service.customModels) { model in
                    Button {
                        service.selectCustomModel(model.id)
                        service.model = .custom
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: model.displayTitle)
                            if let subtitle = model.displaySubtitle {
                                Text(verbatim: subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                            }
                        }
                    }
                    .disabled(!service.canSelectModel(.custom))
                }
            }
        } label: {
            footerPickerLabel(service.modelTitle(service.model)) {
                switch service.model.provider {
                case .anthropic:
                    ExternalAgentLogo(agent: .claude, size: 12)
                case .openAI:
                    ProviderLogo(iconKey: "openai", size: 12)
                case .custom:
                    Image(systemName: "server.rack")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .layoutPriority(1)
        .accessibilityLabel(L10n.string("Model"))
        .accessibilityValue(Text(verbatim: service.modelTitle(service.model)))
        .help(L10n.string("Model"))
    }

    private var reasoningEffortPicker: some View {
        Menu {
            ForEach(service.model.supportedReasoningEfforts, id: \.self) { effort in
                Button {
                    service.reasoningEffort = effort
                } label: {
                    menuOptionLabel(
                        L10n.string(key: effort.labelKey),
                        selected: effort == service.reasoningEffort
                    )
                }
            }
        } label: {
            footerPickerLabel(L10n.string(key: service.reasoningEffort.labelKey)) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(L10n.string("Reasoning effort"))
        .accessibilityValue(L10n.string(key: service.reasoningEffort.labelKey))
        .help(L10n.string("Reasoning effort"))
    }

    private func footerPickerLabel<Artwork: View>(
        _ title: String,
        @ViewBuilder artwork: () -> Artwork
    ) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
            artwork()
                .frame(width: 12, height: 12)
                .clipped()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
        )
    }

    @ViewBuilder
    private func menuOptionLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: "checkmark")
            }
        } else {
            Text(verbatim: title)
        }
    }

    @ViewBuilder
    private var byokIndicator: some View {
        if let provider = service.activeBYOKProvider {
            Image(systemName: "key.fill")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 20, height: 20)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: provider.chatPresentation.byokLabel))
                .help(provider.chatPresentation.byokHelp)
        }
    }

    private var toolResults: [String: ToolRunResult] {
        var out: [String: ToolRunResult] = [:]
        for msg in service.messages where msg.role == .user {
            for block in msg.blocks {
                if case let .toolResult(id, content, isError) = block {
                    out[id] = ToolRunResult(content: content, isError: isError)
                }
            }
        }
        return out
    }

    private var reasoningStreaming: Bool { service.messages.last?.hasIncompleteReasoning == true }

    private var messageList: some View {
        Group {
            if service.messages.isEmpty && !service.isStreaming {
                emptyState
            } else {
                scrollingMessages
            }
        }
    }

    private var scrollingMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let results = toolResults
                    ForEach(service.messages) { msg in
                        AgentMessageView(message: msg, toolResults: results)
                            .id(msg.id)
                    }
                    errorBanner
                        .padding(.vertical, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .background(AgentOverlayScrollerStyle())
            }
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollGeometryChange(for: Bool.self) { geo in
                let distance = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                return distance > 80
            } action: { _, newValue in
                withAnimation(.easeOut(duration: 0.15)) { isScrolledFromBottom = newValue }
            }
            .onChange(of: service.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: service.isStreaming) { _, _ in scrollToBottom(proxy) }
            .onChange(of: reasoningStreaming) { _, _ in scrollToBottom(proxy) }
            .overlay(alignment: .bottomTrailing) {
                if isScrolledFromBottom {
                    scrollToBottomButton(proxy: proxy)
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
        }
    }

    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(AppTheme.Background.raisedColor)
                        .overlay(
                            Circle()
                                .stroke(AppTheme.Border.subtleColor, lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("Scroll to latest"))
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = service.streamError {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                Text(verbatim: errorMessage(err))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                CopyButton(value: errorMessage(err))
                    .font(.system(size: 10))
                if let cta = errorCTA(for: err) {
                    Button(action: cta.action) {
                        Text(cta.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.capsule(.secondary))
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.red.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.red.opacity(0.2), lineWidth: 0.5)
                    )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct ErrorCTA {
        let title: String
        let action: () -> Void
    }

    private func errorCTA(for error: AgentServiceError?) -> ErrorCTA? {
        guard let error else { return nil }
        switch error {
        case .unauthenticated:
            return ErrorCTA(title: L10n.string("Open Settings")) {
                SettingsWindowController.shared.show(tab: .agent)
            }
        case .insufficientCredits:
            return ErrorCTA(title: L10n.string("Open Settings")) {
                SettingsWindowController.shared.show(tab: .agent)
            }
        case .unavailable:
            return ErrorCTA(title: L10n.string("Open Settings")) {
                SettingsWindowController.shared.show(tab: .agent)
            }
        case .refusal, .upstream, .httpError:
            return nil
        }
    }

    private func errorMessage(_ error: AgentServiceError) -> String {
        switch error {
        case .unauthenticated:
            HostedServices.enabled
                ? L10n.string("Sign in to use AI chat.")
                : L10n.string("This model needs a hosted account, which this build does not use. Add your own API key in Settings, or pick a custom endpoint.")
        case .insufficientCredits(let message), .upstream(let message), .httpError(_, _, let message):
            message
        case .unavailable(let model):
            if !HostedServices.enabled || (model.requiresPaidHostedPlan && !AccountService.shared.isPaid) {
                L10n.string("Add your own API key, or set up a custom endpoint, to use this model.")
            } else {
                model.provider.chatPresentation.unavailableMessage
            }
        case .refusal:
            L10n.string("The selected model refused this request. Revise the prompt and try again.")
        }
    }

    private struct CopyButton: View {
        private static let feedbackDuration: Duration = .seconds(1.4)
        let value: String
        @State private var copied = false

        var body: some View {
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .frame(width: 24, height: 24)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help(copied ? L10n.string("Copied") : L10n.string("Copy"))
        }

        private func copy() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: Self.feedbackDuration)
                copied = false
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.canStream {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(AppTheme.Text.tertiaryColor.opacity(0.5))
                    Text(L10n.string("Start a conversation"))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Text(L10n.string("Ask anything, or start with:"))
                        .font(.system(size: 13))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                VStack(spacing: 8) {
                    ForEach(Self.starterPrompts) { starterPrompt in
                        AgentStarterPromptButton(starterPrompt: starterPrompt) {
                            Analytics.capture(.agentStarterPromptClicked, properties: [
                                "starter_prompt": starterPrompt.id,
                            ])
                            populatePrompt(starterPrompt.prompt)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            missingKeyState
        }
    }

    @ViewBuilder
    private var missingKeyState: some View {
        let account = AccountService.shared
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "key.slash.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(AppTheme.Text.tertiaryColor.opacity(0.5))
                Text(missingKeyTitle(account: account))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text(missingKeySubtitle(account: account))
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .multilineTextAlignment(.center)
            }

            Button(action: { SettingsWindowController.shared.show(tab: .agent) }) {
                HStack(spacing: 8) {
                    if let icon = missingKeyPrimaryIcon(account: account) {
                        Image(systemName: icon)
                    }
                    Text(missingKeyPrimaryLabel(account: account))
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .buttonStyle(.capsule(.prominent, size: .regular))

            if !account.isSignedIn {
                Text(L10n.string("First-time sign-ups only"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }

            Button(action: { SettingsWindowController.shared.show(tab: .agent) }) {
                Text(missingKeyLinkLabel)
                    .underline()
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .hoverHighlight(cornerRadius: 6)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var missingKeyLinkLabel: String {
        service.model.provider.chatPresentation.missingKeyLinkTitle
    }

    private func missingKeyTitle(account: AccountService) -> String {
        if !account.isSignedIn { return L10n.string("Sign in to use AI chat") }
        if !account.isPaid { return L10n.string("Subscription required") }
        return L10n.string("Configure AI settings")
    }

    private func missingKeySubtitle(account: AccountService) -> String {
        if !account.isSignedIn {
            return L10n.string("Log in with your Vercel account to get 250 free credits per month.")
        }
        if !account.isPaid {
            return L10n.string("Upgrade to a paid plan to unlock AI chat and hosted models.")
        }
        return L10n.string("Open Settings to add API keys or configure custom endpoints.")
    }

    private func missingKeyPrimaryLabel(account: AccountService) -> String {
        if !account.isSignedIn { return L10n.string("Log in for 250 free credits") }
        if !account.isPaid { return L10n.string("Subscribe") }
        return L10n.string("Open Settings")
    }

    private func missingKeyPrimaryIcon(account: AccountService) -> String? {
        if !account.isSignedIn { return "gift.fill" }
        if !account.isPaid { return nil }
        return "gearshape"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = service.messages.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var footer: some View {
        @Bindable var service = editor.agentService
        return VStack(spacing: 0) {
            Divider()
                .foregroundStyle(AppTheme.Border.subtleColor)
            if service.queuedMessageCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.message.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Accent.primary)
                    Text("\(service.queuedMessageCount) queued")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.Accent.primary.opacity(0.08))
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let progress = service.requestProgress {
                AgentRequestProgressView(progress: progress)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 0) {
                AgentInputBox(
                    draft: $service.draft,
                    mentions: $service.mentions,
                    isSending: service.isStreaming,
                    canSend: canSend,
                    onSend: submit,
                    onCancel: { service.cancel() }
                ) {
                    HStack(spacing: 8) {
                        modelPicker
                        reasoningEffortPicker
                        byokIndicator
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppTheme.Background.baseColor)
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: service.queuedMessageCount)
        .animation(.easeOut(duration: 0.15), value: service.chatStatus)
    }

    private func submit() {
        guard canSend else { return }
        service.send(text: service.draft, mentions: service.mentions)
        service.draft = ""
        service.mentions.removeAll()
    }

    private func populatePrompt(_ prompt: String) {
        service.draft = prompt
        service.mentions.removeAll()
    }
}

private struct ChatBackground: View {
    var body: some View {
        AppTheme.Background.baseColor
    }
}

private struct ChatTabView: View {
    let session: ChatSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(verbatim: displayTitle)
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(
            Capsule()
                .fill(isActive ? AppTheme.Accent.primary.opacity(0.12) : Color.clear)
                .overlay(
                    Capsule()
                        .stroke(isActive ? AppTheme.Accent.primary.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        )
        .overlay(alignment: .trailing) {
            if isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }
        }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var displayTitle: String {
        let t = session.title
        return t.count > 24 ? String(t.prefix(24)) + "…" : t
    }
}

@MainActor
private extension AgentProvider {
    var chatPresentation: (
        byokLabel: String, byokHelp: String,
        unavailableMessage: String, missingKeyLinkTitle: String
    ) {
        switch self {
        case .anthropic:
            (
                L10n.string("using Anthropic API key"),
                L10n.string("Streaming through your Anthropic API key (BYOK)"),
                L10n.string("Add an Anthropic API key or credits to use this model."),
                L10n.string("or add your own Anthropic key")
            )
        case .openAI:
            (
                L10n.string("using OpenAI API key"),
                L10n.string("Streaming through your OpenAI API key (BYOK)"),
                L10n.string("Add an OpenAI API key or credits to use this model."),
                L10n.string("or add your own OpenAI key")
            )
        case .custom:
            (
                L10n.string("using your custom endpoint"),
                L10n.string("Streaming through your own OpenAI-compatible endpoint"),
                L10n.string("Set up your custom endpoint in Settings. Localhost needs no key; other servers do."),
                L10n.string("or set up your custom endpoint")
            )
        }
    }
}

private struct AgentOverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> AgentOverlayScrollerProbe {
        AgentOverlayScrollerProbe()
    }

    func updateNSView(_ nsView: AgentOverlayScrollerProbe, context: Context) {
        nsView.apply()
    }
}

private final class AgentOverlayScrollerProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
                return
            }
            ancestor = current.superview
        }
    }
}

private struct AgentStarterPrompt: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let prompt: String
}

private struct AgentStarterPromptButton: View {
    let starterPrompt: AgentStarterPrompt
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: starterPrompt.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: 24, height: 24)
                Text(starterPrompt.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.Border.subtleColor, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("Fill prompt"))
    }
}
