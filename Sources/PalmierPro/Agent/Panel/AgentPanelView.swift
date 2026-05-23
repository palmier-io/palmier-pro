import SwiftUI

struct AgentPanelView: View {
    @Environment(EditorViewModel.self) var editor

    private var service: AgentService { editor.agentService }

    private var canSend: Bool {
        !service.isStreaming &&
        service.hasApiKey &&
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
        .background(AppTheme.Background.surfaceColor)
    }

    private var floatingTabBar: some View {
        GlassEffectContainer {
            HStack(spacing: AppTheme.Spacing.xs) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppTheme.Spacing.xxs) {
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
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity)
            .frame(height: Layout.panelHeaderHeight)
            .glassEffect(.regular, in: Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: AppTheme.BorderWidth.hairline)
            }
        }
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
        .help("New chat")
    }

    @State private var showHistory = false

    private var historyButton: some View {
        Button { showHistory.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Chat history")
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
            ForEach(AnthropicModel.allCases, id: \.self) { m in
                Button(m.displayName) { service.model = m }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(service.model.displayName)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                    if let err = service.streamError {
                        Text(err)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(.red)
                    }
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
                    if let err = service.streamError {
                        Text(err)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(.red)
                            .padding(.top, AppTheme.Spacing.sm)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.lgXl)
                .padding(.top, Layout.panelHeaderHeight + AppTheme.Spacing.sm)
                .padding(.bottom, AppTheme.Spacing.smMd)
                .frame(maxWidth: Layout.chatColumnMax)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onChange(of: service.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: service.isStreaming) { _, _ in scrollToBottom(proxy) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.hasApiKey {
            Text("Describe a change, or @ a clip to start.")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .multilineTextAlignment(.center)
        } else {
            missingKeyState
        }
    }

    private var missingKeyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            VStack(spacing: AppTheme.Spacing.xs) {
                Text("AI Chat uses your own Anthropic API key to talk to Claude.")
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
            .multilineTextAlignment(.center)

            Button(action: { SettingsWindowController.shared.show(tab: .agent) }) {
                Text("Open Settings")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
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
        return AgentInputBox(
            draft: $service.draft,
            mentions: $service.mentions,
            isSending: service.isStreaming,
            canSend: canSend,
            onSend: submit,
            onCancel: { service.cancel() }
        ) {
            modelPicker
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
}

private struct ChatTabView: View {
    let session: ChatSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: AppTheme.Spacing.xs) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(displayTitle)
                        .font(.system(size: AppTheme.FontSize.xs, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                        .lineLimit(1)
                        .fixedSize()
                    if hovering || isActive {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                                .foregroundStyle(AppTheme.Text.mutedColor)
                                .frame(width: AppTheme.Spacing.mdLg, height: AppTheme.Spacing.mdLg)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                }
                Rectangle()
                    .fill(isActive ? AppTheme.Text.primaryColor : Color.clear)
                    .frame(height: AppTheme.BorderWidth.medium)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.top, AppTheme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }

    private var displayTitle: String {
        let t = session.title
        return t.count > 20 ? String(t.prefix(20)) + "…" : t
    }
}
