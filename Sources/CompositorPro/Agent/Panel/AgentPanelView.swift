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

    private func canSend(in id: UUID) -> Bool {
        !service.isStreaming(in: id) &&
        service.canStream &&
        !service.draft(in: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @State private var isScrolledFromBottom = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            tabBar
            messageList
                .id(service.currentSessionId)
            footer
        }
        .background(AppTheme.Background.baseColor)
        .task { await service.reloadLocalAgents().value }
        .onChange(of: service.runningSessionIDs) { previous, current in
            guard !previous.subtracting(current).isEmpty else { return }
            AppNotifications.agentComplete()
        }
        .onChange(of: service.currentSessionId) { _, _ in
            isScrolledFromBottom = false
        }
    }

    private var tabBar: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Label(L10n.string("Chat"), systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if !service.runningSessionIDs.isEmpty {
                    Text(L10n.string("\(service.runningSessionIDs.count) running"))
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Accent.primary)
                        .lineLimit(1)
                }
                Spacer(minLength: AppTheme.Spacing.xs)
                ConnectAgentButton(compact: true)
                historyButton
                ViewSkillsButton()
                    .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
            }
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .frame(height: AppTheme.Chat.headerHeight)

            HStack(spacing: AppTheme.Spacing.smMd) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            ForEach(service.openSessions) { session in
                                ChatTabView(
                                    session: session,
                                    isActive: session.id == service.currentSessionId,
                                    isRunning: service.isStreaming(in: session.id),
                                    hasDraft: !service.draft(in: session.id).isEmpty,
                                    onSelect: { service.selectSession(session.id) },
                                    onClose: { service.closeTab(session.id) }
                                )
                                .id(session.id)
                            }
                        }
                    }
                    .onChange(of: service.currentSessionId) { _, new in
                        guard let new else { return }
                        withAnimation(.easeOut(duration: AppTheme.Anim.hover)) { proxy.scrollTo(new, anchor: .center) }
                    }
                    .onAppear {
                        if let id = service.currentSessionId { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                newTabButton
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.bottom, AppTheme.Spacing.smMd)
            .frame(height: AppTheme.Chat.tabHeight + AppTheme.Spacing.smMd)
        }
        .background(AppTheme.Background.surfaceColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
    }

    private var newTabButton: some View {
        Button { service.newChat() } label: {
            Image(systemName: "plus")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.Chat.tabHeight)
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(L10n.string("New chat"))
        .help(L10n.string("New chat"))
    }

    @State private var showHistory = false

    private var historyButton: some View {
        Button { showHistory.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                .contentShape(Rectangle())
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(L10n.string("Chat history"))
        .help(L10n.string("Chat history"))
        .popover(isPresented: $showHistory, arrowEdge: .top) {
            ChatHistoryList(
                sessions: service.sessions.sorted { $0.updatedAt > $1.updatedAt },
                currentId: service.currentSessionId,
                runningIDs: service.runningSessionIDs,
                onSelect: { id in
                    service.selectSession(id)
                    showHistory = false
                },
                onDelete: { service.deleteSession($0) }
            )
        }
    }

    private func reasoningEffortPicker(compact: Bool = false) -> some View {
        Menu {
            ForEach(service.supportedReasoningEfforts, id: \.self) { effort in
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
            if compact {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                    .background(AppTheme.Interaction.fill(AppTheme.Opacity.hint), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            } else {
                footerPickerLabel(L10n.string(key: service.reasoningEffort.labelKey)) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .id("reasoning-picker-\(service.model.rawValue)-\(service.reasoningEffort.rawValue)")
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(L10n.string("Reasoning effort"))
        .accessibilityValue(L10n.string(key: service.reasoningEffort.labelKey))
        .help(L10n.string("Reasoning effort for the next request"))
    }

    private func footerPickerLabel<Artwork: View>(
        _ title: String,
        @ViewBuilder artwork: () -> Artwork
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            artwork()
                .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
                .clipped()
            Text(verbatim: title)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(AppTheme.Interaction.fill(AppTheme.Opacity.hint))
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
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
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
                emptyState
            } else {
                scrollingMessages
            }
        }
    }

    private var scrollingMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.lgXl) {
                    let results = toolResults
                    let visibleMessages = service.messages.filter { message in
                        message.role != .user || message.blocks.contains { if case .text = $0 { return true }; return false }
                    }
                    ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, msg in
                        AgentMessageView(message: msg, toolResults: results,
                                         showsHeader: index == 0 || visibleMessages[index - 1].role != .assistant,
                                         onDisclosure: { isScrolledFromBottom = true })
                            .id(msg.id)
                    }
                    Color.clear
                        .frame(height: AppTheme.Spacing.xxs)
                        .id("chat-bottom")
                }
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.vertical, AppTheme.Spacing.lgXl)
                .frame(maxWidth: Layout.chatColumnMax)
                .frame(maxWidth: .infinity)
                .background(AgentOverlayScrollerStyle())
            }
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollGeometryChange(for: ChatScrollMetrics.self) { geo in
                ChatScrollMetrics(
                    contentHeight: geo.contentSize.height,
                    distanceFromBottom: geo.contentSize.height + geo.contentInsets.bottom - geo.contentOffset.y - geo.containerSize.height
                )
            } action: { previous, current in
                if previous.contentHeight == current.contentHeight {
                    withAnimation(.easeOut(duration: AppTheme.Anim.hover)) {
                        isScrolledFromBottom = current.distanceFromBottom > AppTheme.Chat.scrollBottomThreshold
                    }
                } else if !isScrolledFromBottom && (service.isStreaming || previous.contentHeight == 0) {
                    scrollToBottom(proxy, animated: false)
                }
            }
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: service.messages.count) { _, _ in
                if !isScrolledFromBottom { scrollToBottom(proxy) }
            }
            .overlay(alignment: .bottomTrailing) {
                if isScrolledFromBottom {
                    scrollToBottomButton(proxy: proxy)
                        .padding(AppTheme.Spacing.mdLg)
                        .transition(.opacity)
                }
            }
        }
    }

    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.Chat.headerHeight, height: AppTheme.Chat.headerHeight)
                .background(
                    Circle()
                        .fill(AppTheme.Background.raisedColor)
                        .overlay(
                            Circle()
                                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                        )
                )
                .shadow(AppTheme.Shadow.md)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(L10n.string("Scroll to latest"))
        .help(L10n.string("Scroll to latest"))
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = service.streamError {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Status.errorColor)
                    Text(verbatim: errorMessage(err))
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(AppTheme.Chat.errorLineLimit)
                        .textSelection(.enabled)
                }
                HStack {
                    if let cta = errorCTA(for: err) {
                        Button(action: cta.action) {
                            Text(cta.title)
                                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        }
                        .buttonStyle(.capsule(.secondary))
                        .controlSize(.small)
                    }
                    Spacer(minLength: AppTheme.Spacing.zero)
                    CopyButton(value: errorMessage(err))
                }
            }
            .padding(AppTheme.Spacing.mdLg)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(AppTheme.Status.errorColor.opacity(AppTheme.Opacity.faint))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                            .stroke(AppTheme.Status.errorColor.opacity(AppTheme.Opacity.moderate), lineWidth: AppTheme.BorderWidth.hairline)
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
        case .refusal, .stopping, .upstream, .httpError, .localAgent:
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
        case .stopping:
            L10n.string("Chat requests are stopping. Try again when they finish.")
        case .localAgent(let failure):
            failure.displayMessage
        }
    }

    private struct CopyButton: View {
        private static let feedbackDuration: Duration = .seconds(1.4)
        let value: String
        @State private var copied = false

        var body: some View {
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
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
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xlXxl) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Accent.primary)
                            .frame(width: AppTheme.Chat.welcomeArtworkSize, height: AppTheme.Chat.welcomeArtworkSize)
                            .background(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint), in: RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg))
                        Text(L10n.string("What would you like to edit?"))
                            .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(L10n.string("Describe your next edit, or choose a starting point."))
                            .font(.system(size: AppTheme.FontSize.smMd))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: AppTheme.Chat.starterCardMinWidth), spacing: AppTheme.Spacing.smMd)], spacing: AppTheme.Spacing.smMd) {
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
                .padding(AppTheme.Spacing.lgXl)
                .padding(.top, AppTheme.Spacing.mdLg)
                .frame(maxWidth: AppTheme.Chat.welcomeMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            missingKeyState
        }
    }

    @ViewBuilder
    private var missingKeyState: some View {
        let account = AccountService.shared
        ScrollView {
        VStack(spacing: AppTheme.Spacing.xl) {
            VStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: "key.slash.fill")
                    .font(.system(size: AppTheme.FontSize.title2))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.Chat.welcomeArtworkSize, height: AppTheme.Chat.welcomeArtworkSize)
                Text(missingKeyTitle(account: account))
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .multilineTextAlignment(.center)
                Text(missingKeySubtitle(account: account))
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .multilineTextAlignment(.center)
            }

            Button(action: { SettingsWindowController.shared.show(tab: .agent) }) {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    if let icon = missingKeyPrimaryIcon(account: account) {
                        Image(systemName: icon)
                    }
                    Text(missingKeyPrimaryLabel(account: account))
                }
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                .padding(.horizontal, AppTheme.Spacing.xl)
                .padding(.vertical, AppTheme.Spacing.md)
            }
            .buttonStyle(.capsule(.prominent, size: .regular))

            if HostedServices.enabled && !account.isSignedIn {
                Text(L10n.string("First-time sign-ups only"))
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }

            Button(action: { SettingsWindowController.shared.show(tab: .agent) }) {
                Text(missingKeyLinkLabel)
                    .underline()
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.horizontal, AppTheme.Spacing.mdLg)
                    .padding(.vertical, AppTheme.Spacing.sm)
            }
            .buttonStyle(.plain)
            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .padding(AppTheme.Spacing.xlXxl)
        .padding(.top, AppTheme.Spacing.xlXxl)
        .frame(maxWidth: AppTheme.Chat.welcomeMaxWidth)
        .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingKeyLinkLabel: String {
        service.model.provider.chatPresentation.missingKeyLinkTitle
    }

    private func missingKeyTitle(account: AccountService) -> String {
        if !HostedServices.enabled { return L10n.string("Connect an AI model") }
        if !account.isSignedIn { return L10n.string("Sign in to use AI chat") }
        if !account.isPaid { return L10n.string("Subscription required") }
        return L10n.string("Configure AI settings")
    }

    private func missingKeySubtitle(account: AccountService) -> String {
        if !HostedServices.enabled { return L10n.string("Add an API key or custom endpoint in Settings to start chatting.") }
        if !account.isSignedIn {
            return L10n.string("Log in with your Vercel account to get 250 free credits per month.")
        }
        if !account.isPaid {
            return L10n.string("Upgrade to a paid plan to unlock AI chat and hosted models.")
        }
        return L10n.string("Open Settings to add API keys or configure custom endpoints.")
    }

    private func missingKeyPrimaryLabel(account: AccountService) -> String {
        if !HostedServices.enabled { return L10n.string("Open Settings") }
        if !account.isSignedIn { return L10n.string("Log in for 250 free credits") }
        if !account.isPaid { return L10n.string("Subscribe") }
        return L10n.string("Open Settings")
    }

    private func missingKeyPrimaryIcon(account: AccountService) -> String? {
        if !HostedServices.enabled { return "key.fill" }
        if !account.isSignedIn { return "gift.fill" }
        if !account.isPaid { return nil }
        return "gearshape"
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let scroll = { proxy.scrollTo("chat-bottom", anchor: .bottom) }
        if animated { withAnimation(.easeOut(duration: AppTheme.Anim.hover), scroll) }
        else { scroll() }
    }

    private var footer: some View {
        VStack(spacing: AppTheme.Spacing.smMd) {
            errorBanner
            if service.queuedMessageCount > 0 {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    Image(systemName: "arrow.up.message.fill")
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Accent.primary)
                    Text(L10n.string("\(service.queuedMessageCount) queued"))
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer(minLength: AppTheme.Spacing.zero)
                }
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.vertical, AppTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let progress = service.requestProgress {
                AgentRequestProgressView(progress: progress)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let id = service.currentSessionId {
                AgentInputBox(
                    conversationID: id,
                    draft: Binding(get: { service.draft(in: id) }, set: { service.setDraft($0, in: id) }),
                    mentions: Binding(get: { service.mentions(in: id) }, set: { service.setMentions($0, in: id) }),
                    isSending: service.isStreaming(in: id),
                    canSend: canSend(in: id),
                    onSend: {
                        if service.submitDraft(in: id) { isScrolledFromBottom = false }
                    },
                    onCancel: { service.cancel(conversationID: id) }
                ) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            AgentModelPickerView(service: service, idPrefix: "footer-full")
                            reasoningEffortPicker()
                            byokIndicator
                        }
                        HStack(spacing: AppTheme.Spacing.sm) {
                            AgentModelPickerView(service: service, idPrefix: "footer-compact")
                            reasoningEffortPicker(compact: true)
                        }
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            AgentModelPickerView(service: service, idPrefix: "footer-stacked")
                            reasoningEffortPicker()
                        }
                    }
                }
                .id(id)
                Text(service.isStreaming ? L10n.string("Esc to stop") : L10n.string("↵ Send · ⇧↵ New line"))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.Spacing.xs)
                    .help(L10n.string("Return to send · Shift Return for a new line"))
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: Layout.chatColumnMax)
        .frame(maxWidth: .infinity)
        .background(AppTheme.Background.baseColor)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.Border.subtleColor)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: service.queuedMessageCount)
    }

    private func populatePrompt(_ prompt: String) {
        service.draft = prompt
        service.mentions.removeAll()
    }
}

private struct ChatScrollMetrics: Equatable {
    let contentHeight: CGFloat
    let distanceFromBottom: CGFloat
}

private struct ChatTabView: View {
    let session: ChatSession
    let isActive: Bool
    let isRunning: Bool
    let hasDraft: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.zero) {
            Button(action: onSelect) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: isRunning ? "circle.fill" : hasDraft ? "pencil" : "bubble.left")
                        .font(.system(size: isRunning ? AppTheme.FontSize.micro : AppTheme.FontSize.xs))
                        .foregroundStyle(isRunning ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
                        .frame(width: AppTheme.IconSize.xxs)
                    Text(verbatim: displayTitle)
                        .font(.system(size: AppTheme.FontSize.sm, weight: isActive ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                        .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, AppTheme.Spacing.smMd)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel(Text(verbatim: displayTitle))
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .help(displayTitle)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    .hoverHighlight(cornerRadius: AppTheme.Radius.xsSm)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .opacity(isActive || isHovering ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
            .accessibilityLabel(L10n.string("Close chat tab"))
            .help(L10n.string("Close tab; the conversation stays in history"))
            .padding(.horizontal, AppTheme.Spacing.xs)
        }
        .frame(width: AppTheme.Chat.tabWidth, height: AppTheme.Chat.tabHeight)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(isActive ? AppTheme.Background.baseColor : AppTheme.Interaction.fill(isHovering ? AppTheme.Opacity.hint : AppTheme.Opacity.transparent))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                        .stroke(isActive ? AppTheme.Border.primaryColor : .clear, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .onHover { isHovering = $0 }
    }

    private var displayTitle: String {
        session.title == "New chat" ? L10n.string("New chat") : session.title
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
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: starterPrompt.systemImage)
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                    .background(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint), in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                Text(starterPrompt.title)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AppTheme.Spacing.mdLg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .fill(AppTheme.Background.surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .hoverHighlight(cornerRadius: AppTheme.Radius.md)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("Fill prompt"))
    }
}

private struct AgentModelPickerView: View {
    let service: AgentService
    let idPrefix: String

    var body: some View {
        let _ = service.customModelsVersion
        let customModels = service.customModels
        let currentModel = service.model
        let selectedID = service.selectedCustomModelID
        let selectedHarness = service.selectedLocalHarness

        Menu {
            Section(L10n.string("Signed-in agents")) {
                ForEach(LocalAgentHarness.allCases) { harness in
                    Button { service.selectLocalHarness(harness) } label: {
                        HStack {
                            Text(verbatim: harness.name)
                            if selectedHarness == harness { Image(systemName: "checkmark") }
                        }
                    }
                    .disabled(service.localAgentExecutables[harness] == nil)
                }
            }
            Divider()
            ForEach(service.builtInModels, id: \.self) { model in
                Button {
                    service.selectAPIModel(model)
                } label: {
                    HStack {
                        Text(verbatim: service.modelTitle(model))
                        if selectedHarness == nil && currentModel == model {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(!service.canSelectModel(model))
            }
            if !customModels.isEmpty {
                Divider()
                ForEach(customModels) { model in
                    Button {
                        service.selectCustomModel(model.id)
                        service.model = .custom
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                Text(verbatim: model.displayTitle)
                                if let subtitle = model.displaySubtitle {
                                    Text(verbatim: subtitle)
                                        .font(.system(size: AppTheme.FontSize.xs))
                                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                                }
                            }
                            if selectedHarness == nil && currentModel == .custom && selectedID == model.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            footerPickerLabel(service.selectedAgentTitle) {
                if let selectedHarness {
                    switch selectedHarness {
                    case .codex: ExternalAgentLogo(agent: .codex, size: AppTheme.IconSize.xxs)
                    case .claudeCode: ExternalAgentLogo(agent: .claude, size: AppTheme.IconSize.xxs)
                    case .antigravity:
                        Image(systemName: "sparkles")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Accent.primary)
                    }
                } else {
                    switch currentModel.provider {
                case .anthropic:
                    ExternalAgentLogo(agent: .claude, size: AppTheme.IconSize.xxs)
                case .openAI:
                    ProviderLogo(iconKey: "openai", size: AppTheme.IconSize.xxs)
                case .custom:
                    Image(systemName: "server.rack")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                }
            }
        }
        .id("\(idPrefix)-model-picker-\(selectedHarness?.rawValue ?? currentModel.rawValue)-\(selectedID?.uuidString ?? "none")-\(service.customModelsVersion)")
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: AppTheme.Chat.modelPickerMaxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .accessibilityLabel(L10n.string("Agent or model"))
        .accessibilityValue(Text(verbatim: service.selectedAgentTitle))
        .help(L10n.string("Agent or model for the next request"))
    }

    private func footerPickerLabel<Artwork: View>(
        _ title: String,
        @ViewBuilder artwork: () -> Artwork
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            artwork()
            Text(verbatim: title)
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: AppTheme.Chat.modelPickerMaxWidth)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(AppTheme.Interaction.fill(AppTheme.Opacity.hint))
        )
    }
}
