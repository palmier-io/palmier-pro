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
    ]

    private var service: AgentService { editor.agentService }

    private var canSend: Bool {
        !service.isStreaming &&
        service.canStream &&
        !service.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                messageList
                floatingTabBar
            }
            footer
        }
    }

    private var floatingTabBar: some View {
        GlassEffectContainer {
            HStack(spacing: AppTheme.Spacing.xs) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppTheme.Spacing.xs) {
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
                    }
                    .onChange(of: service.currentSessionId) { _, new in
                        guard let new else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }
                newTabButton
                historyButton
                ViewSkillsButton()
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity)
            .frame(height: Layout.panelHeaderHeight)
            .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.Radius.lg))
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
    }

    private var newTabButton: some View {
        Button { service.newChat() } label: {
            Image(systemName: "plus")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("New chat"))
    }

    @State private var showHistory = false
    @State private var isScrolledFromBottom = false

    private var historyButton: some View {
        Button { showHistory.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
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
        }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(service.availableModels, id: \.self) { model in
                Button {
                    service.model = model
                } label: {
                    Text(verbatim: model.displayName)
                }
                .disabled(!service.canSelectModel(model))
            }
        } label: {
            footerPickerLabel(service.model.displayName) {
                switch service.model.provider {
                case .anthropic:
                    ExternalAgentLogo(agent: .claude, size: AppTheme.IconSize.xs)
                case .openAI:
                    ProviderLogo(iconKey: "openai", size: AppTheme.IconSize.xs)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .layoutPriority(1)
        .accessibilityLabel(L10n.string("Model"))
        .accessibilityValue(Text(verbatim: service.model.displayName))
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
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
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
        HStack(spacing: AppTheme.Spacing.xs) {
            Text(verbatim: title)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
            artwork()
                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                .clipped()
        }
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
            Image(systemName: "key")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
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

    private var messageList: some View {
        Group {
            if service.messages.isEmpty && !service.isStreaming {
                VStack(spacing: AppTheme.Spacing.smMd) {
                    emptyState
                    errorBanner
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, AppTheme.Spacing.lgXl)
            } else {
                scrollingMessages
            }
        }
    }

    private var scrollingMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    let results = toolResults
                    ForEach(service.messages) { msg in
                        AgentMessageView(message: msg, toolResults: results)
                            .id(msg.id)
                    }
                    if service.isStreaming {
                        ThinkingDots().id("streaming-indicator")
                    }
                    errorBanner
                        .padding(.top, AppTheme.Spacing.sm)
                }
                .padding(.horizontal, AppTheme.Spacing.lgXl)
                .padding(.top, Layout.panelHeaderHeight + AppTheme.Spacing.mdLg)
                .padding(.bottom, AppTheme.Spacing.smMd)
                .frame(maxWidth: Layout.chatColumnMax)
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
            .overlay(alignment: .bottomTrailing) {
                if isScrolledFromBottom {
                    scrollToBottomButton(proxy: proxy)
                        .padding(.trailing, AppTheme.Spacing.mdLg)
                        .padding(.bottom, AppTheme.Spacing.mdLg)
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
                .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("Scroll to latest"))
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = service.streamError {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(verbatim: errorMessage(err))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                if let cta = errorCTA(for: err) {
                    Button(action: cta.action) {
                        Text(cta.title)
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    }
                    .buttonStyle(.capsule(.secondary))
                    .controlSize(.small)
                }
            }
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
            return ErrorCTA(title: L10n.string("Sign in")) {
                SettingsWindowController.shared.show(tab: .account)
            }
        case .insufficientCredits:
            return ErrorCTA(title: L10n.string("View plans")) {
                SettingsWindowController.shared.show(tab: .account)
            }
        case .unavailable(let model) where model.requiresPaidHostedPlan && !AccountService.shared.isPaid:
            return ErrorCTA(title: L10n.string("View plans")) {
                SettingsWindowController.shared.show(tab: .account)
            }
        case .unavailable:
            return ErrorCTA(title: L10n.string("Open Settings")) {
                SettingsWindowController.shared.show(tab: .agent)
            }
        case .refusal, .upstream:
            return nil
        }
    }

    private func errorMessage(_ error: AgentServiceError) -> String {
        switch error {
        case .unauthenticated:
            L10n.string("Sign in to use AI chat.")
        case .insufficientCredits(let message), .upstream(let message):
            message
        case .unavailable(let model):
            if model.requiresPaidHostedPlan && !AccountService.shared.isPaid {
                L10n.string("Subscribe or add your own API key to use this model.")
            } else {
                model.provider.chatPresentation.unavailableMessage
            }
        case .refusal:
            L10n.string("The selected model refused this request. Revise the prompt and try again.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.canStream {
            VStack(spacing: AppTheme.Spacing.smMd) {
                Text(L10n.string("Ask anything, or start with:"))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .multilineTextAlignment(.center)
                VStack(spacing: AppTheme.Spacing.xs) {
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
        } else {
            missingKeyState
        }
    }

    @ViewBuilder
    private var missingKeyState: some View {
        let account = AccountService.shared
        VStack(spacing: AppTheme.Spacing.mdLg) {
            Button {
                missingKeyPrimaryAction(account: account)
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if let icon = missingKeyPrimaryIcon(account: account) {
                        Image(systemName: icon)
                    }
                    Text(missingKeyPrimaryLabel(account: account))
                }
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
            }
            .buttonStyle(.capsule(.prominent, size: .regular))

            if !account.isSignedIn {
                Text(L10n.string("First-time sign-ups only"))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }

            Button(action: { SettingsWindowController.shared.show(tab: .agent) }) {
                Text(missingKeyLinkLabel)
                    .underline()
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xxs)
            }
            .buttonStyle(.plain)
            .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
    }

    private var missingKeyLinkLabel: String {
        service.model.provider.chatPresentation.missingKeyLinkTitle
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

    private func missingKeyPrimaryAction(account: AccountService) {
        if !account.isSignedIn {
            Task { await account.signInWithGoogle() }
        } else {
            SettingsWindowController.shared.show(tab: .account)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if service.isStreaming {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("streaming-indicator", anchor: .bottom)
            }
        } else if let last = service.messages.last {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var footer: some View {
        @Bindable var service = editor.agentService
        return VStack(spacing: AppTheme.Spacing.sm) {
            if !service.canStream && !service.messages.isEmpty {
                missingKeyState
            }
            AgentInputBox(
                draft: $service.draft,
                mentions: $service.mentions,
                isSending: service.isStreaming,
                canSend: canSend,
                onSend: submit,
                onCancel: { service.cancel() }
            ) {
                modelPicker
                reasoningEffortPicker
                byokIndicator
            }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.bottom, AppTheme.Spacing.mdLg)
        .padding(.top, AppTheme.Spacing.xs)
        .frame(maxWidth: Layout.chatColumnMax)
        .frame(maxWidth: .infinity)
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
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: starterPrompt.systemImage)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                Text(starterPrompt.title)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverHighlight(cornerRadius: AppTheme.Radius.lg)
            .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.Radius.lg))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("Fill prompt"))
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
                .font(.system(
                    size: AppTheme.FontSize.xs,
                    weight: isActive ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium
                ))
                .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .documentTabChrome(isActive: isActive, isCloseable: true, onClose: onClose)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var displayTitle: String {
        let t = session.title
        return t.count > 20 ? String(t.prefix(20)) + "…" : t
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
        }
    }
}
